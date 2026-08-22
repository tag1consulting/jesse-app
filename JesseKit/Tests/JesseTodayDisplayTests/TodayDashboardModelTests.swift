import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The reducer: what happens between a tap and the server's answer, and what the
// screen holds afterwards. These are the tests the whole design exists to make
// possible — every path below is driven through a scripted fake with no server, no
// clock and no view.

@MainActor
final class TodayDashboardModelTests: XCTestCase {

    // MARK: - The fake

    /// A scriptable `TodayProviding`. Each method returns the next scripted outcome
    /// for its own queue (the last repeats) and records what it was asked.
    ///
    /// `@unchecked Sendable` over plain stored state, the same shape as the Mac
    /// target's `MacFakeBridgeClient`: every call in these tests is driven from the
    /// main actor by an awaited model method, so there is no concurrent access to
    /// check — the annotation says "this fake is single-threaded by construction",
    /// not "the compiler was argued with".
    final class FakeClient: TodayProviding, @unchecked Sendable {
        enum Fetch { case snapshot(TodaySnapshot); case notModified; case error(JesseError) }

        var fetches: [Fetch] = []
        var checks: [TodayMutationResult] = []
        var moves: [TodayMutationResult] = []
        var postpones: [TodayMutationResult] = []
        var glances: [TodayMutationResult] = []

        private(set) var fetchCount = 0
        private(set) var checkCount = 0
        private(set) var moveCount = 0
        private(set) var postponeCount = 0
        private(set) var glanceCount = 0

        /// Double-optional on purpose: the outer says "a fetch happened", the inner
        /// says whether it carried a tag. `.some(nil)` is an unconditional fetch.
        private(set) var lastIfNoneMatch: String??
        private(set) var lastIfMatch: String?
        private(set) var lastCheck: (id: String, checked: Bool, evidence: String?)?
        private(set) var lastMove: (id: String, op: TodayMoveOp)?
        private(set) var lastPostpone: (id: String, deferred: Bool)?
        /// EVERY move, in order. One drag can be several ops (a row dragged three
        /// places up is three `up`s), and "which ops, in what order, under which id"
        /// is the whole assertion for a drag — `lastMove` cannot express it.
        private(set) var moveLog: [(id: String, op: TodayMoveOp)] = []
        private(set) var lastGlanceId: String?
        private(set) var lastAt: Date?

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            lastIfNoneMatch = .some(ifNoneMatch)
            let outcome = fetches.isEmpty ? Fetch.notModified
                                          : fetches[min(fetchCount, fetches.count - 1)]
            fetchCount += 1
            switch outcome {
            case .snapshot(let s): return .snapshot(s)
            case .notModified: return .notModified
            case .error(let e): throw e
            }
        }

        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       ifMatch: String) async throws -> TodayMutationResult {
            lastCheck = (id, checked, evidence)
            lastIfMatch = ifMatch
            lastAt = at
            let out = outcome(checks, checkCount)
            checkCount += 1
            return out
        }

        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            lastMove = (id, op)
            moveLog.append((id, op))
            lastIfMatch = ifMatch
            lastAt = at
            let out = outcome(moves, moveCount)
            moveCount += 1
            return out
        }

        func postpone(id: String, deferred: Bool, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            lastPostpone = (id, deferred)
            lastIfMatch = ifMatch
            lastAt = at
            let out = outcome(postpones, postponeCount)
            postponeCount += 1
            return out
        }

        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            lastGlanceId = id
            lastIfMatch = ifMatch
            lastAt = at
            let out = outcome(glances, glanceCount)
            glanceCount += 1
            return out
        }

        private func outcome(_ queue: [TodayMutationResult], _ index: Int) -> TodayMutationResult {
            queue.isEmpty ? .snapshot(Fixt.snapshot()) : queue[min(index, queue.count - 1)]
        }
    }

    /// A fixed clock, so the stamps a mutation sends are assertable. `nonisolated
    /// static` because the model's `now` is a `@Sendable` closure and this test case
    /// is a @MainActor class — neither an instance property nor a MainActor static
    /// can be read from inside one.
    nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_772_530_200)
    private var fixedNow: Date { Self.fixedNow }

    private func model(_ fake: FakeClient) -> TodayDashboardModel {
        TodayDashboardModel(makeClient: { fake }, now: { Self.fixedNow })
    }

    // MARK: - Loading

    func testFirstLoadAdoptsTheSnapshotAndItsEtag() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        let m = model(fake)
        XCTAssertEqual(m.displayState, .loading)

        await m.load()

        XCTAssertEqual(m.etag, "\"tag-1\"")
        XCTAssertFalse(m.isOffline)
        XCTAssertEqual(m.badgeCount, 4)
        guard case .content = m.displayState else { return XCTFail("expected content") }
    }

    /// The second load sends `If-None-Match`; pull-to-refresh deliberately does not,
    /// so a user who suspects the screen is wrong gets a full answer instead of being
    /// told nothing changed.
    func testLoadIsConditionalAndRefreshIsNot() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\"")), .notModified]
        let m = model(fake)

        await m.load()
        XCTAssertEqual(fake.lastIfNoneMatch, .some(nil), "nothing to send on the first load")
        await m.load()
        XCTAssertEqual(fake.lastIfNoneMatch, .some("\"tag-1\""))
        await m.refresh()
        XCTAssertEqual(fake.lastIfNoneMatch, .some(nil), "refresh is unconditional")
    }

    func testA304ChangesNothingOnScreenButStillClearsAStaleBanner() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot()), .error(.timedOut("studio")), .notModified]
        let m = model(fake)

        await m.load()
        let rendered = m.snapshot
        await m.load()
        XCTAssertTrue(m.isOffline)
        await m.load()

        XCTAssertFalse(m.isOffline, "a 304 IS a successful round trip")
        XCTAssertNil(m.lastErrorMessage)
        XCTAssertEqual(m.snapshot, rendered, "and it changed nothing")
    }

    /// A failed refresh never blanks a day already on screen — what the user was
    /// reading a second ago is still the best answer available.
    func testAFailedRefreshKeepsTheDayAndSetsOffline() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot()), .error(.cannotConnect("studio"))]
        let m = model(fake)

        await m.load()
        await m.load()

        XCTAssertTrue(m.isOffline)
        XCTAssertNotNil(m.lastErrorMessage)
        guard case .content = m.displayState else {
            return XCTFail("a failed refresh must not blank the screen")
        }
    }

    /// A failure before anything has loaded is an empty state — and WHICH empty state
    /// now depends on whether the bridge answered.
    ///
    /// A transport failure means the device could not reach it, and the honest screen
    /// says "you're offline" rather than printing a URL-loading string at someone who
    /// already knows they are on a plane. This used to be `.unavailable` too; it was
    /// split when the tabs learned to render from an on-disk cache, because "nothing
    /// cached AND no network" is a distinct thing to say.
    func testAnUnreachableBridgeBeforeAnyLoadIsTheOfflineState() async {
        let fake = FakeClient()
        fake.fetches = [.error(.cannotFindHost("studio"))]
        let m = model(fake)
        await m.load()
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertEqual(m.badgeCount, 0)
    }

    /// A bridge that ANSWERS is not an offline bridge: the device has a network and the
    /// problem is a different one, so its message is shown rather than swallowed.
    func testABridgeThatAnsweredBadlyBeforeAnyLoadIsStillUnavailable() async {
        let fake = FakeClient()
        fake.fetches = [.error(.badResponse(500, "boom"))]
        let m = model(fake)
        await m.load()
        guard case .unavailable = m.displayState else { return XCTFail("expected unavailable") }
        XCTAssertEqual(m.badgeCount, 0)
    }

    /// A day file that has not been written yet is an empty day, not an error — the
    /// morning routine simply has not run.
    func testAMissingDayFileIsItsOwnState() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(TodaySnapshot(missing: true, etag: "\"t\""))]
        let m = model(fake)
        await m.load()
        XCTAssertEqual(m.displayState, .noDayFile)
        XCTAssertFalse(m.isOffline)
    }

    // MARK: - Check: optimistic → confirm → reconcile

    /// THE CORE LOOP. The box flips before the request is sent, stays flipped while
    /// it is in flight, and the overlay entry retires only once the server's own
    /// snapshot agrees — so the row never blinks back and never diverges.
    func testOptimisticCheckThenServerConfirmThenReconcile() async {
        var confirmed = Fixt.snapshot(etag: "\"tag-2\"")
        confirmed.sections[0].items[0].checked = true
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.checks = [.snapshot(confirmed)]
        let m = model(fake)
        await m.load()
        XCTAssertEqual(m.snapshot?.item(id: Fixt.thermocouple)?.checked, false)

        await m.check(id: Fixt.thermocouple, checked: true, evidence: "ordered two")

        // The wire call carried what the user did, under the ETag we held.
        XCTAssertEqual(fake.lastCheck?.id, Fixt.thermocouple)
        XCTAssertEqual(fake.lastCheck?.checked, true)
        XCTAssertEqual(fake.lastCheck?.evidence, "ordered two")
        XCTAssertEqual(fake.lastIfMatch, "\"tag-1\"")
        XCTAssertEqual(fake.lastAt, fixedNow)

        // And the state settled: the server agrees, so nothing optimistic is left.
        XCTAssertEqual(m.snapshot?.item(id: Fixt.thermocouple)?.checked, true)
        XCTAssertFalse(m.isPending(Fixt.thermocouple), "the overlay retires on agreement")
        XCTAssertTrue(m.overlay.isEmpty)
        XCTAssertEqual(m.etag, "\"tag-2\"", "the fresh tag the next mutation must carry")
        XCTAssertEqual(m.badgeCount, 3)
    }

    /// A pending check must SURVIVE a snapshot that does not yet reflect it —
    /// otherwise a poll racing ahead of an in-flight mutation would revert the box
    /// under the user's finger.
    func testAPendingCheckSurvivesASnapshotThatDoesNotYetAgree() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        // The server answers the check with a snapshot where the box is still open —
        // the write is journaled behind a running turn.
        fake.checks = [.snapshot(Fixt.snapshot(etag: "\"tag-2\"", pending: true))]
        let m = model(fake)
        await m.load()

        await m.check(id: Fixt.thermocouple, checked: true)

        XCTAssertTrue(m.isPending(Fixt.thermocouple))
        XCTAssertEqual(m.snapshot?.item(id: Fixt.thermocouple)?.checked, true,
                       "the screen keeps showing what the user did")
        XCTAssertTrue(m.isPendingReplay, "and says why it is not on disk yet")
    }

    func testUncheckingClearsAnyPendingEvidence() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.checks = [.snapshot(Fixt.snapshot(etag: "\"tag-2\"", pending: true))]
        let m = model(fake)
        await m.load()

        await m.check(id: Fixt.thermocouple, checked: true, evidence: "a note")
        XCTAssertEqual(m.overlay.evidence[Fixt.thermocouple], "a note")
        await m.check(id: Fixt.thermocouple, checked: false)
        XCTAssertNil(m.overlay.evidence[Fixt.thermocouple])
    }

    /// A tap with no ETag in hand is not sent at all — the bridge would answer `428`
    /// — so the model goes and gets one instead.
    func testATapWithNoEtagRefetchesInsteadOfSendingA428() async {
        let fake = FakeClient()
        fake.fetches = [.error(.cannotConnect("studio")), .snapshot(Fixt.snapshot())]
        let m = model(fake)
        await m.load()
        XCTAssertNil(m.etag)

        await m.check(id: Fixt.thermocouple, checked: true)

        XCTAssertEqual(fake.checkCount, 0, "no request without a tag")
        XCTAssertEqual(fake.fetchCount, 2, "it went to get one")
    }

    // MARK: - Move: optimistic → new id → reconcile

    /// **THE RE-KEY.** An optimistic `to_do_now`, then a server snapshot carrying the
    /// item under a DIFFERENT id (the id hashes the section name). What must come out
    /// the other side: exactly one row, under the new id, with every piece of overlay
    /// state carried over and nothing at all left under the old one.
    func testOptimisticToDoNowThenServerReturnsANewIdThenReconcileLeavesExactlyOneRow() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.moves = [.snapshot(Fixt.snapshotAfterGlazeMovedToDoNow(etag: "\"tag-2\""))]
        let m = model(fake)
        await m.load()

        // A check the server has not confirmed yet, so there is real state to carry.
        m.overlay.checks[Fixt.glazeInErrands] = true
        m.overlay.evidence[Fixt.glazeInErrands] = "picked it up"

        await m.move(id: Fixt.glazeInErrands, op: .toDoNow)

        let snap = m.snapshot
        // 1. Exactly one row for that item, and it is in the destination.
        let matches = snap?.allItems.filter { $0.lead == Fixt.glazeLead } ?? []
        XCTAssertEqual(matches.count, 1, "no ghost, no duplicate")
        XCTAssertEqual(matches.first?.id, Fixt.glazeInDoNow)
        XCTAssertEqual(matches.first?.sectionName, "Do Now")
        // 2. Nothing renders under the old id.
        XCTAssertNil(snap?.item(id: Fixt.glazeInErrands))
        // 3. The overlay moved with it, wholesale.
        XCTAssertEqual(m.overlay.checks[Fixt.glazeInDoNow], true)
        XCTAssertEqual(m.overlay.evidence[Fixt.glazeInDoNow], "picked it up")
        XCTAssertNil(m.overlay.checks[Fixt.glazeInErrands], "nothing left under the old id")
        XCTAssertNil(m.overlay.evidence[Fixt.glazeInErrands])
        XCTAssertNil(m.overlay.moves[Fixt.glazeInErrands], "and the move itself retired")
        XCTAssertNil(m.overlay.moves[Fixt.glazeInDoNow],
                     "a completed move must not be re-applied under the new id")
        // 4. The optimistic check is still showing, under its new key.
        XCTAssertEqual(snap?.item(id: Fixt.glazeInDoNow)?.checked, true)
        XCTAssertTrue(m.isPending(Fixt.glazeInDoNow))
    }

    /// The same reconciliation for a move that does NOT cross a section: the id is
    /// unchanged, so the re-key is the identity function and nothing is disturbed.
    func testAnInSectionMoveLeavesTheIdAlone() async {
        var reordered = Fixt.snapshot(etag: "\"tag-2\"")
        reordered.sections[0].items.swapAt(0, 1)
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.moves = [.snapshot(reordered)]
        let m = model(fake)
        await m.load()
        m.overlay.checks[Fixt.ada] = true

        await m.move(id: Fixt.ada, op: .up)

        XCTAssertEqual(fake.lastMove?.op, .up)
        XCTAssertEqual(m.snapshot?.sections[0].items.first?.id, Fixt.ada)
        XCTAssertEqual(m.overlay.checks[Fixt.ada], true, "state stays where it was")
        XCTAssertTrue(m.overlay.moves.isEmpty)
    }

    /// The optimistic half, observed before the response lands: the row is already in
    /// Do Now, once, under the id the client still knows it by.
    func testTheOptimisticMoveIsVisibleBeforeTheResponse() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        let m = model(fake)
        await m.load()

        m.overlay.moves[Fixt.glazeInErrands] = .toDoNow

        let snap = m.snapshot
        XCTAssertEqual(snap?.sections[0].items.first?.id, Fixt.glazeInErrands)
        XCTAssertEqual(snap?.allItems.filter { $0.lead == Fixt.glazeLead }.count, 1)
    }

    // MARK: - 410 and 412

    /// `410`: the item left the file — a rebuild dropped it, or its lead was re-worded
    /// into a different id. Take the row off the screen now, rather than leave one
    /// whose every tap will fail, and refetch for the rest.
    func testA410RemovesTheItemAndRefetches() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.checks = [.itemGone]
        let m = model(fake)
        await m.load()
        let before = m.snapshot?.allItems.count ?? 0

        await m.check(id: Fixt.ada, checked: true)

        XCTAssertNil(m.snapshot?.item(id: Fixt.ada), "the row is gone from the screen")
        XCTAssertEqual(m.snapshot?.allItems.count, before - 1)
        XCTAssertTrue(m.overlay.removed.contains(Fixt.ada))
        XCTAssertFalse(m.isPending(Fixt.ada), "and nothing optimistic survives it")
        XCTAssertEqual(fake.fetchCount, 2, "it refetched the rest of the day")
        XCTAssertFalse(m.isOffline, "a 410 is an answer, not a failure")
    }

    /// The SAME `410`, learned somewhere else. The detail read is keyed by the same item
    /// id, so it finds out the row has left the file while the list is still drawing it —
    /// and the list must not need a failed tap of its own to catch up. One method, so the
    /// two ways of learning it cannot diverge.
    func testAnItemThatVanishedElsewhereIsRemovedSaidOutLoudAndRefetched() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        let m = model(fake)
        await m.load()
        let before = m.snapshot?.allItems.count ?? 0

        await m.itemVanished(id: Fixt.ada)

        XCTAssertNil(m.snapshot?.item(id: Fixt.ada))
        XCTAssertEqual(m.snapshot?.allItems.count, before - 1)
        XCTAssertEqual(m.notice, TodayDashboardModel.itemGoneNotice,
                       "a row that disappears under the user is worth one sentence")
        XCTAssertEqual(fake.fetchCount, 2, "and the rest of the day is re-read")
        XCTAssertFalse(m.isOffline, "a 410 is an answer, not a failure")
    }

    /// `412`: our ETag is stale, so the tap was aimed at a document that no longer
    /// exists. Drop the optimism and refetch — re-sending against a fresh tag would
    /// apply the user's intent to a line they never saw.
    func testA412DropsTheOptimismAndRefetchesWithoutRetrying() async {
        var rewritten = Fixt.snapshot(etag: "\"tag-9\"")
        rewritten.sections[0].items[1].lead = "Reply to Ada — rewritten by the agent."
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\"")), .snapshot(rewritten)]
        fake.checks = [.preconditionFailed]
        let m = model(fake)
        await m.load()

        await m.check(id: Fixt.ada, checked: true, evidence: "done")

        XCTAssertEqual(fake.checkCount, 1, "the tap is NOT retried against the fresh tag")
        XCTAssertEqual(fake.fetchCount, 2, "it refetched instead")
        XCTAssertEqual(m.etag, "\"tag-9\"", "and adopted the tag the refetch carried")
        XCTAssertFalse(m.isPending(Fixt.ada))
        XCTAssertTrue(m.overlay.isEmpty, "no optimistic state survives a stale precondition")
        XCTAssertEqual(m.snapshot?.item(id: Fixt.ada)?.checked, false,
                       "the box is back where the file says it is")
        XCTAssertFalse(m.isOffline)
    }

    func testA428DropsTheOptimismAndRefetches() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.checks = [.preconditionRequired]
        let m = model(fake)
        await m.load()

        await m.check(id: Fixt.ada, checked: true)

        XCTAssertTrue(m.overlay.isEmpty)
        XCTAssertEqual(fake.fetchCount, 2)
    }

    /// `409`: structurally impossible (the lead item, or no Do Now section). The menu
    /// should never have offered it, so it surfaces as the bridge's own words rather
    /// than as a silent nothing.
    func testA409SurfacesTheBridgesMessageAndRevertsTheOptimisticMove() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.moves = [.conflict("this day file has no \"Do Now\" section")]
        let m = model(fake)
        await m.load()

        await m.move(id: Fixt.glazeInErrands, op: .toDoNow)

        XCTAssertEqual(m.lastConflictMessage, "this day file has no \"Do Now\" section")
        XCTAssertTrue(m.overlay.isEmpty, "the optimistic move is rolled back")
        XCTAssertEqual(m.snapshot?.sections[1].items.first?.id, Fixt.glazeInErrands,
                       "and the row is back where it was")
    }

    /// A transport failure rolls the tap back and says so, rather than leaving a box
    /// ticked that nothing will ever confirm.
    func testATransportFailureRollsTheTapBack() async {
        let throwing = ThrowingClient(fetch: .snapshot(Fixt.snapshot(etag: "\"tag-1\"")))
        let m = TodayDashboardModel(makeClient: { throwing }, now: { Self.fixedNow })
        await m.load()

        await m.check(id: Fixt.ada, checked: true)

        XCTAssertTrue(m.isOffline)
        XCTAssertNotNil(m.lastErrorMessage)
        XCTAssertTrue(m.overlay.isEmpty, "a tap that never reached the bridge is rolled back")
        XCTAssertEqual(m.snapshot?.item(id: Fixt.ada)?.checked, false)
    }

    // MARK: - Glance

    func testAGlanceClearsTheDotAtOnceAndRetiresWhenTheServerAgrees() async {
        var seen = Fixt.snapshot(etag: "\"tag-2\"")
        seen.sections[2].reports[0].seen = true
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        fake.glances = [.snapshot(seen)]
        let m = model(fake)
        await m.load()
        XCTAssertEqual(m.unseenReportCount, 2)

        await m.glance(id: Fixt.runDay)

        XCTAssertEqual(fake.lastGlanceId, Fixt.runDay)
        XCTAssertEqual(fake.lastIfMatch, "\"tag-1\"")
        XCTAssertEqual(m.unseenReportCount, 1)
        XCTAssertFalse(m.overlay.seen.contains(Fixt.runDay),
                       "the server now says seen, so the local flag retires")
    }

    // MARK: - A throwing client, for the failure path

    /// Fetches fine, and every mutation throws — the shape of a bridge that went away
    /// between the load and the tap.
    struct ThrowingClient: TodayProviding {
        let fetch: TodayFetchResult
        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult { fetch }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       ifMatch: String) async throws -> TodayMutationResult {
            throw JesseError.connectionLost
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            throw JesseError.connectionLost
        }
        func postpone(id: String, deferred: Bool, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult {
            throw JesseError.connectionLost
        }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            throw JesseError.connectionLost
        }
    }
}
