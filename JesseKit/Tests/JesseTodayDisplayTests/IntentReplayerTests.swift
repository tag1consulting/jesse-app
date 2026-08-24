import XCTest
@testable import JesseTodayDisplay
import JesseCore
import JesseNetworking

// **The offline capture queue, end to end**, driven through a scripted client and a
// fixed clock with no server, no store and no view.
//
// Every test here is a way the world can have moved on between the moment someone
// checked a box and the moment the phone got to say so. That is the whole feature: the
// capture is easy, and the difficulty is entirely in deciding when a held change may
// still be applied — and in refusing out loud, with something the user can do about it,
// when it may not.

@MainActor
final class IntentReplayerTests: XCTestCase {

    // MARK: - Fakes

    /// An in-memory `PendingIntentStoring`. The seam exists precisely so these tests do
    /// not need a `ModelContainer`; `PendingIntentStore` (the SwiftData conformer) is
    /// covered by `JesseCoreTests` against a real store.
    final class FakeStore: PendingIntentStoring {
        nonisolated deinit {}
        private(set) var records: [PendingIntentRecord] = []

        init(_ records: [PendingIntentRecord] = []) { self.records = records }

        func all() -> [PendingIntentRecord] { records.sorted { $0.createdAt < $1.createdAt } }

        func append(_ record: PendingIntentRecord) {
            guard !records.contains(where: { $0.id == record.id }) else { return }
            records.append(record)
        }

        func update(_ record: PendingIntentRecord) {
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index] = record
        }

        func delete(id: UUID) { records.removeAll { $0.id == id } }

        func record(_ id: UUID) -> PendingIntentRecord? { records.first { $0.id == id } }
    }

    /// A `TodayProviding` scripted per call, recording exactly what each write carried —
    /// which is what most of these assertions are about.
    final class ReplayClient: TodayProviding, @unchecked Sendable {
        var fetches: [TodayFetchResult] = []
        var checks: [TodayMutationResult] = []
        var moves: [TodayMutationResult] = []
        var postpones: [TodayMutationResult] = []

        private(set) var fetchCount = 0
        private(set) var checkLog: [(id: String, checked: Bool, evidence: String?,
                                     at: Date, day: String?, ifMatch: String)] = []
        private(set) var moveLog: [(id: String, op: TodayMoveOp, day: String?)] = []
        private(set) var postponeLog: [(id: String, deferred: Bool, day: String?)] = []

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            let out = fetches.isEmpty ? TodayFetchResult.notModified
                                      : fetches[min(fetchCount, fetches.count - 1)]
            fetchCount += 1
            return out
        }

        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       day: String?, ifMatch: String) async throws -> TodayMutationResult {
            checkLog.append((id, checked, evidence, at, day, ifMatch))
            return next(checks, checkLog.count - 1)
        }

        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            moveLog.append((id, op, day))
            return next(moves, moveLog.count - 1)
        }

        func postpone(id: String, deferred: Bool, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            postponeLog.append((id, deferred, day))
            return next(postpones, postponeLog.count - 1)
        }

        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(Fixt.snapshot())
        }

        private func next(_ queue: [TodayMutationResult], _ index: Int) -> TodayMutationResult {
            queue.isEmpty ? .snapshot(Fixt.snapshot()) : queue[min(index, queue.count - 1)]
        }
    }

    /// Records every Tell in order and answers from a script, so "in order" and "stops
    /// at the first failure" are both assertable.
    final class FakeTell: IntentTellSending {
        nonisolated deinit {}
        var results: [Bool] = []
        private(set) var sent: [String] = []

        func sendTell(_ text: String) async -> Bool {
            sent.append(text)
            guard !results.isEmpty else { return true }
            return results[min(sent.count - 1, results.count - 1)]
        }
    }

    // MARK: - Scaffolding

    /// 2026-03-03 07:05:00 UTC — inside the fixture's own day, and deliberately an hour
    /// that is still 07:05 in London and 08:05 in Rome, so a stamp assertion says
    /// something about the zone rather than about UTC.
    nonisolated static let capturedAt = Date(timeIntervalSince1970: 1_772_521_500)
    /// Hours later. Nothing must ever be stamped with this.
    nonisolated static let replayedAt = Date(timeIntervalSince1970: 1_772_560_000)

    private func makeDay(_ client: ReplayClient) -> TodayDashboardModel {
        TodayDashboardModel(makeClient: { client }, now: { Self.replayedAt })
    }

    private func makeReplayer(_ client: ReplayClient, _ store: FakeStore,
                              day: TodayDashboardModel? = nil,
                              tell: FakeTell? = nil,
                              dietDay: String? = nil) -> IntentReplayer {
        IntentReplayer(store: store,
                       day: day ?? makeDay(client),
                       makeClient: { client },
                       tell: tell,
                       dietDay: { dietDay },
                       now: { Self.replayedAt })
    }

    private func captured(_ kind: PendingIntentKind, id: String?, lead: String?,
                          day: String = "2026-03-03",
                          payload: PendingIntentPayload = PendingIntentPayload())
        -> PendingIntentRecord {
        PendingIntentRecord(kind: kind, dayDate: day, itemId: id, leadText: lead,
                            sectionName: "Do Now", payload: payload,
                            createdAt: Self.capturedAt, tz: "Europe/London")
    }

    // MARK: - The same day

    /// THE CENTRAL GUARANTEE. A check captured at 07:05 and replayed hours later carries
    /// the user's own instant and the day it was made against — not the replay's clock,
    /// and not a bare write against whatever the file happens to be.
    func testAQueuedCheckReplaysWithItsOwnTimeAndItsOwnDay() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-9\""))]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada about the firing schedule.",
                                        payload: PendingIntentPayload(evidence: "sent the date"))])
        let replayer = makeReplayer(client, store)

        let outcomes = await replayer.replayAll()

        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(client.checkLog.count, 1)
        let sent = try? XCTUnwrap(client.checkLog.first)
        XCTAssertEqual(sent?.id, Fixt.ada)
        XCTAssertEqual(sent?.checked, true)
        XCTAssertEqual(sent?.evidence, "sent the date")
        XCTAssertEqual(sent?.at, Self.capturedAt, "the USER's instant, never the replay's")
        XCTAssertEqual(sent?.day, "2026-03-03", "the day it was made against")
        XCTAssertEqual(sent?.ifMatch, "\"tag-9\"", "the LIVE etag, freshly fetched")
        XCTAssertEqual(store.record(store.all()[0].id)?.state, .applied)
    }

    /// The fetch is unconditional. A `304` would answer with no document, and a replay
    /// that has to compare a date and re-find a lead needs the document.
    func testTheReplayFetchIsUnconditional() async {
        let client = ReplayClient()
        client.fetches = [.notModified]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])
        let outcomes = await makeReplayer(client, store).replayAll()
        // Nothing to work against → held, not refused. The change is still true.
        XCTAssertEqual(outcomes, [.deferred])
        XCTAssertTrue(client.checkLog.isEmpty)
        XCTAssertEqual(store.all().first?.state, .queued)
    }

    /// A postponement replays the same way, through its own endpoint.
    func testAQueuedPostponementReplaysWithItsDay() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        let store = FakeStore([captured(.defer, id: Fixt.ada, lead: "Reply to Ada.")])
        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(client.postponeLog.first?.deferred, true)
        XCTAssertEqual(client.postponeLog.first?.day, "2026-03-03")
    }

    /// An item that left the file on the SAME day is a refusal, not a search: the id is
    /// still authoritative today, so its absence is an answer rather than a question.
    func testAnItemGoneFromTheSameDayRefuses() async {
        let client = ReplayClient()
        var day = Fixt.snapshot()
        day.sections[0].items.removeAll { $0.id == Fixt.ada }
        client.fetches = [.snapshot(day)]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])

        let outcomes = await makeReplayer(client, store).replayAll()

        XCTAssertEqual(outcomes, [.refused(IntentReplayer.goneNotice)])
        XCTAssertTrue(client.checkLog.isEmpty, "nothing was written")
    }

    // MARK: - The day rolled over

    /// **The morning-roll case, and the reason the queue can exist at all.** The day was
    /// rebuilt, so the captured id addresses nothing — but the task came back with the
    /// same words, and the check is re-aimed at its NEW id and the NEW day.
    func testADayChangeReResolvesTheSameLeadToItsNewId() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot(etag: "\"tag-tomorrow\"")
        tomorrow.date = "2026-03-04"
        // Same task, re-emitted under a different id — exactly what a rebuild does.
        tomorrow.sections[0].items = [
            Fixt.item("aaaa11112222", lead: "Reply to Ada about the firing schedule.",
                      section: "Do Now", added: "2026-02-27"),
        ]
        client.fetches = [.snapshot(tomorrow)]
        let store = FakeStore([captured(.check, id: Fixt.ada,
                                        lead: "Reply to Ada about the firing schedule.")])

        let outcomes = await makeReplayer(client, store).replayAll()

        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(client.checkLog.first?.id, "aaaa11112222", "re-aimed at the new id")
        XCTAssertEqual(client.checkLog.first?.day, "2026-03-04",
                       "and sent against the LIVE day, not the captured one")
        XCTAssertEqual(client.checkLog.first?.at, Self.capturedAt,
                       "the hour is still the user's")
    }

    /// The lead match tolerates exactly what a rebuild does to the words — case,
    /// re-wrapping, and a re-stamped `(Added …)` trailer — and nothing else.
    func testTheLeadMatchToleratesARebuildsCosmetics() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        tomorrow.sections[0].items = [
            Fixt.item("bbbb11112222",
                      lead: "reply to   Ada about the firing schedule. (Added 2026-03-04)",
                      section: "Do Now"),
        ]
        client.fetches = [.snapshot(tomorrow)]
        let store = FakeStore([captured(.check, id: Fixt.ada,
                                        lead: "Reply to Ada about the firing schedule.")])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(client.checkLog.first?.id, "bbbb11112222")
    }

    /// **No match is a refusal with a way out.** The words are gone, so the app cannot
    /// find the line — but the agent reads the vault and can, so the row offers a
    /// sentence rather than an apology. The exact wording is pinned because it is what
    /// the agent is asked to act on.
    func testADayChangeWithNoMatchRefusesAndOffersTheTell() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        tomorrow.sections[0].items = [
            Fixt.item("cccc11112222", lead: "Something else entirely.", section: "Do Now"),
        ]
        client.fetches = [.snapshot(tomorrow)]
        let intent = captured(.check, id: Fixt.ada,
                              lead: "Reply to Ada about the firing schedule.")
        let store = FakeStore([intent])
        let day = makeDay(client)
        // The day is claiming the check locally; a refusal must take that back.
        day.overlay.checks[Fixt.ada] = true

        let outcomes = await makeReplayer(client, store, day: day).replayAll()

        XCTAssertEqual(outcomes, [.refused(IntentReplayer.notFoundNotice)])
        XCTAssertEqual(IntentReplayer.notFoundNotice, "Today moved on; item not found.")
        XCTAssertTrue(client.checkLog.isEmpty, "nothing was written anywhere")
        XCTAssertNil(day.overlay.checks[Fixt.ada],
                     "a refused change stops the day claiming it happened")
        XCTAssertEqual(store.record(intent.id)?.state, .refused)
        XCTAssertEqual(store.record(intent.id)?.refusalReason, IntentReplayer.notFoundNotice)
        XCTAssertEqual(
            intent.tellFallback,
            "I completed \"Reply to Ada about the firing schedule.\" on 2026-03-03 at 07:05 (logged offline)")
    }

    /// Two open items worded the same are indistinguishable, so neither is chosen.
    /// Guessing between them is exactly the mis-tick the whole rule exists to prevent.
    func testAnAmbiguousLeadRefusesRatherThanGuessing() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        tomorrow.sections[0].items = [
            Fixt.item("dddd11110001", lead: "Call the vendor.", section: "Do Now"),
            Fixt.item("dddd11110002", lead: "Call the vendor.", section: "Errands"),
        ]
        client.fetches = [.snapshot(tomorrow)]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Call the vendor.")])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.notFoundNotice)])
        XCTAssertTrue(client.checkLog.isEmpty)
    }

    /// An item the morning already carried over as DONE is not re-ticked. Re-checking it
    /// would rewrite its `app-completed` stamp to the replay's time, overwriting a true
    /// record with a second one.
    func testAnAlreadyCompletedTaskIsNotReTicked() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        tomorrow.sections[0].items = [
            Fixt.item("eeee11112222", lead: "Reply to Ada.", section: "Do Now", checked: true),
        ]
        client.fetches = [.snapshot(tomorrow)]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.notFoundNotice)])
    }

    /// **A move is never re-aimed.** Ordering on a rebuilt day has no meaning — the
    /// document the order was an argument about no longer exists.
    func testAQueuedMoveRefusesWhenTheDayChanged() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        client.fetches = [.snapshot(tomorrow)]
        let store = FakeStore([captured(.move, id: Fixt.ada, lead: "Reply to Ada.",
                                        payload: PendingIntentPayload(moveOp: "to_do_now"))])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.movedOnNotice)])
        XCTAssertTrue(client.moveLog.isEmpty)
    }

    /// On the same day a move replays normally, carrying its stored op.
    func testAQueuedMoveReplaysOnTheSameDay() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        let store = FakeStore([captured(.move, id: Fixt.ada, lead: "Reply to Ada.",
                                        payload: PendingIntentPayload(moveOp: "to_do_now"))])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(client.moveLog.first?.op, .toDoNow)
        XCTAssertEqual(client.moveLog.first?.day, "2026-03-03")
    }

    // MARK: - What the bridge says back

    /// `412`: refetch once, retry once. A SECOND `412` refuses rather than going round
    /// again — an invisible retry loop is worse than a visible refusal with a Retry.
    func testAStaleTagRetriesOnceThenRefuses() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-a\"")),
                          .snapshot(Fixt.snapshot(etag: "\"tag-b\""))]
        client.checks = [.preconditionFailed, .preconditionFailed]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])

        let outcomes = await makeReplayer(client, store).replayAll()

        XCTAssertEqual(outcomes, [.refused(IntentReplayer.busyNotice)])
        XCTAssertEqual(client.checkLog.count, 2, "one retry, not a loop")
        XCTAssertEqual(client.checkLog.map(\.ifMatch), ["\"tag-a\"", "\"tag-b\""],
                       "the retry carries the FRESH tag")
        XCTAssertEqual(client.fetchCount, 2)
    }

    /// A `412` whose refetch lands on a NEW day is a day change, not a tag problem —
    /// the whole decision is re-made rather than the tag swapped underneath it.
    func testAStaleTagWhoseRefetchLandsOnANewDayRefuses() async {
        let client = ReplayClient()
        var tomorrow = Fixt.snapshot(etag: "\"tag-b\"")
        tomorrow.date = "2026-03-04"
        client.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-a\"")), .snapshot(tomorrow)]
        client.checks = [.preconditionFailed]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.movedUnderUsNotice)])
        XCTAssertEqual(client.checkLog.count, 1, "the second write was never sent")
    }

    /// **The bridge's own day guard.** It closes the race between our fetch and our
    /// write, and its `409` is a refusal rather than a retry.
    func testTheBridgesDayMismatchRefuses() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.checks = [.conflict(#"{"reason":"day-mismatch","live_date":"2026-03-04"}"#)]
        let intent = captured(.check, id: Fixt.ada, lead: "Reply to Ada.")
        let store = FakeStore([intent])

        let outcomes = await makeReplayer(client, store).replayAll()

        XCTAssertEqual(outcomes,
                       [.refused("The day file is now 2026-03-04, so that change wasn't applied to it.")])
        XCTAssertEqual(store.record(intent.id)?.state, .refused)
    }

    /// An ordinary structural `409` is still shown in the bridge's own words — the day
    /// guard's parse is total, so a body that is not a day mismatch is not read as one.
    func testAStructuralConflictKeepsTheBridgesWords() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.checks = [.conflict("the standing lead item cannot be moved")]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])

        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused("the standing lead item cannot be moved")])
    }

    /// A `410` from the write is the same answer as an id that had already gone.
    func testAGoneItemFromTheWriteRefuses() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.checks = [.itemGone]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])
        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.goneNotice)])
    }

    // MARK: - Quick logs

    /// **Order is the whole contract.** A day's meals must arrive as they were eaten,
    /// each carrying the `(eaten at …)` stamp the diet pipeline treats as authoritative
    /// — with the offset of the zone the person was standing in, not UTC.
    func testQuickLogsReplayInOrderWithTheirStamp() async {
        let client = ReplayClient()
        let tell = FakeTell()
        let store = FakeStore()
        // Deliberately appended out of order to prove the replayer sorts by creation.
        var lunch = captured(.quickLog, id: nil, lead: nil,
                             payload: PendingIntentPayload(text: "Log a meal: soup"))
        lunch.createdAt = Self.capturedAt.addingTimeInterval(3600)
        var breakfast = captured(.quickLog, id: nil, lead: nil,
                                 payload: PendingIntentPayload(text: "Log a meal: eggs"))
        breakfast.createdAt = Self.capturedAt
        store.append(lunch)
        store.append(breakfast)

        let outcomes = await makeReplayer(client, store, tell: tell).replayAll()

        XCTAssertEqual(outcomes, [.applied, .applied])
        XCTAssertEqual(tell.sent, [
            "(eaten at 2026-03-03T07:05:00Z) Log a meal: eggs",
            "(eaten at 2026-03-03T08:05:00Z) Log a meal: soup",
        ], "oldest first, each stamped with the hour it was captured")
    }

    /// The stamp carries the CAPTURING zone's offset, which is what dates a meal
    /// correctly past the diet day's 04:00 boundary from another country.
    func testTheQuickLogStampCarriesTheCapturingZonesOffset() async {
        let client = ReplayClient()
        let tell = FakeTell()
        var rome = captured(.quickLog, id: nil, lead: nil,
                            payload: PendingIntentPayload(text: "Log a meal: pasta"))
        rome.tz = "Europe/Rome"
        let store = FakeStore([rome])

        _ = await makeReplayer(client, store, tell: tell).replayAll()

        XCTAssertEqual(tell.sent, ["(eaten at 2026-03-03T08:05:00+01:00) Log a meal: pasta"])
    }

    /// A send that was not accepted STOPS the run. Sending the next meal anyway would
    /// put a day's log out of order, which is worse than a delay.
    func testAFailedQuickLogStopsTheRunAndStaysQueued() async {
        let client = ReplayClient()
        let tell = FakeTell()
        tell.results = [false]
        var first = captured(.quickLog, id: nil, lead: nil,
                             payload: PendingIntentPayload(text: "Log a meal: eggs"))
        first.createdAt = Self.capturedAt
        var second = captured(.quickLog, id: nil, lead: nil,
                              payload: PendingIntentPayload(text: "Log a meal: soup"))
        second.createdAt = Self.capturedAt.addingTimeInterval(60)
        let store = FakeStore([first, second])

        let outcomes = await makeReplayer(client, store, tell: tell).replayAll()

        XCTAssertEqual(outcomes, [.deferred], "the run stopped at the first failure")
        XCTAssertEqual(tell.sent.count, 1)
        XCTAssertEqual(store.all().map(\.state), [.queued, .queued],
                       "both are still held; neither is lost and neither is out of order")
    }

    // MARK: - Start new day

    /// A queued Start-new-day runs only if the day it was queued to open has not already
    /// opened without it.
    func testStartNewDayReplaysWhenTheDayHasNotRolled() async {
        let client = ReplayClient()
        let tell = FakeTell()
        let store = FakeStore([captured(.startNewDay, id: nil, lead: nil)])

        let outcomes = await makeReplayer(client, store, tell: tell,
                                          dietDay: "2026-03-03").replayAll()
        XCTAssertEqual(outcomes, [.applied])
        XCTAssertEqual(tell.sent, [HealthNewDay.prompt])
    }

    func testStartNewDayRefusesAfterTheDayRolled() async {
        let client = ReplayClient()
        let tell = FakeTell()
        let store = FakeStore([captured(.startNewDay, id: nil, lead: nil)])

        let outcomes = await makeReplayer(client, store, tell: tell,
                                          dietDay: "2026-03-04").replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.dayRolledNotice)])
        XCTAssertTrue(tell.sent.isEmpty)
    }

    /// Not knowing the diet day is not evidence that it changed, so the intent waits.
    func testStartNewDayWithNoKnownDietDayDefers() async {
        let client = ReplayClient()
        let tell = FakeTell()
        let store = FakeStore([captured(.startNewDay, id: nil, lead: nil)])

        let outcomes = await makeReplayer(client, store, tell: tell).replayAll()
        XCTAssertEqual(outcomes, [.deferred])
        XCTAssertTrue(tell.sent.isEmpty)
    }

    // MARK: - The run itself

    /// A re-entrant call is a no-op, not a second run: two runs would race each other's
    /// ETags and guarantee a `412` for whichever lost.
    func testASecondRunWhileOneIsInFlightIsANoOp() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        let store = FakeStore([captured(.check, id: Fixt.ada, lead: "Reply to Ada.")])
        let replayer = makeReplayer(client, store)

        async let first = replayer.replayAll()
        async let second = replayer.replayAll()
        let (a, b) = await (first, second)

        XCTAssertEqual(a.count + b.count, 1, "exactly one of the two ran the one intent")
        XCTAssertEqual(client.checkLog.count, 1)
    }

    /// Applied receipts are swept after a day; refused rows are never swept, because a
    /// change the app took and could not deliver must not disappear quietly.
    func testAppliedReceiptsAreSweptAndRefusalsAreNot() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        var old = captured(.check, id: Fixt.ada, lead: "Reply to Ada.")
        old.state = .applied
        old.createdAt = Self.replayedAt.addingTimeInterval(-2 * 24 * 3600)
        var refused = captured(.check, id: Fixt.thermocouple, lead: "Order the thermocouple.")
        refused.state = .refused
        refused.createdAt = Self.replayedAt.addingTimeInterval(-2 * 24 * 3600)
        let store = FakeStore([old, refused])

        _ = await makeReplayer(client, store).replayAll()

        XCTAssertNil(store.record(old.id), "a spent receipt goes")
        XCTAssertNotNil(store.record(refused.id), "a refusal stays until it is dismissed")
    }

    /// Process-updates is never captured, and a row of that kind from some other build
    /// is refused rather than run against today's ticked items.
    func testProcessUpdatesIsNeverReplayed() async {
        let client = ReplayClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        let store = FakeStore([captured(.processUpdates, id: nil, lead: nil)])
        let outcomes = await makeReplayer(client, store).replayAll()
        XCTAssertEqual(outcomes, [.refused(IntentReplayer.processUpdatesNotice)])
    }
}
