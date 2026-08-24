import XCTest
@testable import JesseTodayDisplay
import JesseCore
import JesseNetworking

// **The capture half**: what happens at the moment of the tap, when there is no bridge
// to send it to.
//
// The rule these pin is one sentence long and everything else follows from it: an
// offline change renders EXACTLY as an online one, and the only difference is that the
// row says it is waiting. A queued check whose box did not flip would be a queue nobody
// trusts; a queued check that looked identical to a sent one would be a queue nobody
// knows about.

@MainActor
final class TodayOfflineCaptureTests: XCTestCase {

    // MARK: - Fakes

    final class FakeStore: PendingIntentStoring {
        nonisolated deinit {}
        private(set) var records: [PendingIntentRecord] = []
        func all() -> [PendingIntentRecord] { records.sorted { $0.createdAt < $1.createdAt } }
        func append(_ record: PendingIntentRecord) {
            guard !records.contains(where: { $0.id == record.id }) else { return }
            records.append(record)
        }
        func update(_ record: PendingIntentRecord) {
            guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[i] = record
        }
        func delete(id: UUID) { records.removeAll { $0.id == id } }
    }

    /// Reachable for the fetch, then dead for every write — the shape of "the network
    /// died under the tap", which is the case the probe cannot see coming.
    final class DyingClient: TodayProviding, @unchecked Sendable {
        var writeError: JesseError = .cannotConnect("laptop.example")
        private(set) var writeAttempts = 0

        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            .snapshot(Fixt.snapshot())
        }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       day: String?, ifMatch: String) async throws -> TodayMutationResult {
            writeAttempts += 1
            throw writeError
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            writeAttempts += 1
            throw writeError
        }
        func postpone(id: String, deferred: Bool, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            writeAttempts += 1
            throw writeError
        }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            throw writeError
        }
    }

    /// Answers everything, so a write that reaches it proves the model did NOT capture.
    final class LiveClient: TodayProviding, @unchecked Sendable {
        private(set) var checkCount = 0
        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            .snapshot(Fixt.snapshot())
        }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       day: String?, ifMatch: String) async throws -> TodayMutationResult {
            checkCount += 1
            return .snapshot(Fixt.snapshot())
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(Fixt.snapshot())
        }
        func postpone(id: String, deferred: Bool, at: Date,
                      day: String?, ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(Fixt.snapshot())
        }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            .snapshot(Fixt.snapshot())
        }
    }

    nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_772_521_500)

    /// A model with a day already loaded, a queue wired in, and the bridge unreachable.
    private func offlineModel(_ store: FakeStore,
                              client: any TodayProviding = LiveClient())
        async -> TodayDashboardModel {
        let model = TodayDashboardModel(makeClient: { client },
                                        now: { Self.fixedNow },
                                        pending: store,
                                        zone: { "Europe/London" })
        await model.load()
        model.isNetworkUnreachable = true
        return model
    }

    // MARK: - Capture

    /// THE HEADLINE. A tap with no bridge is held, the box flips anyway, and the notice
    /// says so — instead of the old refusal that dropped it on the floor.
    func testAnOfflineCheckIsHeldAndTheBoxStillFlips() async {
        let store = FakeStore()
        let client = LiveClient()
        let model = await offlineModel(store, client: client)

        await model.check(id: Fixt.ada, checked: true, evidence: "sent the date")

        XCTAssertEqual(client.checkCount, 0, "nothing was sent")
        XCTAssertEqual(store.all().count, 1)
        let held = store.all()[0]
        XCTAssertEqual(held.kind, .check)
        XCTAssertEqual(held.itemId, Fixt.ada)
        XCTAssertEqual(held.dayDate, "2026-03-03", "the day it was made against")
        XCTAssertEqual(held.leadText, "Reply to Ada about the firing schedule.",
                       "the words, so a rebuilt day can be searched for them")
        XCTAssertEqual(held.payload.evidence, "sent the date")
        XCTAssertEqual(held.createdAt, Self.fixedNow)
        XCTAssertEqual(held.tz, "Europe/London")

        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.checked, true,
                       "the day renders exactly as it would have online")
        XCTAssertTrue(model.isQueued(Fixt.ada), "and the row says it is waiting")
        XCTAssertEqual(model.notice, TodayDashboardModel.queuedNotice)
        XCTAssertEqual(model.pendingCount, 1)
    }

    /// **The badge already agrees.** An item checked offline is done from the user's
    /// point of view, so it leaves the count — which falls out of applying the overlay
    /// rather than being a second rule anyone has to remember.
    func testAnOfflineCheckLeavesTheBadgeCount() async {
        let store = FakeStore()
        let model = await offlineModel(store)
        let before = model.badgeCount

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertEqual(model.badgeCount, before - 1)
    }

    /// A postponement is held the same way, and greys its row the same way.
    func testAnOfflinePostponementIsHeld() async {
        let store = FakeStore()
        let model = await offlineModel(store)

        await model.postpone(id: Fixt.ada, deferred: true)

        XCTAssertEqual(store.all().first?.kind, .defer)
        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.deferred, true)
        XCTAssertTrue(model.isQueued(Fixt.ada))
    }

    /// A single move op is held with the spelling the bridge parses.
    func testAnOfflineMoveIsHeldWithItsOp() async {
        let store = FakeStore()
        let model = await offlineModel(store)

        await model.move(id: Fixt.glazeInErrands, op: .toSection("Do Now"))

        XCTAssertEqual(store.all().first?.kind, .move)
        XCTAssertEqual(store.all().first?.payload.moveOp, "to_section")
        XCTAssertEqual(store.all().first?.payload.moveSection, "Do Now")
    }

    /// **The tap that DISCOVERS the outage is not the one tap that gets lost.** The probe
    /// still said reachable, the write went out, and the network died under it.
    func testATransportFailureMidTapIsCaptured() async {
        let store = FakeStore()
        let client = DyingClient()
        let model = TodayDashboardModel(makeClient: { client }, now: { Self.fixedNow },
                                        pending: store, zone: { "Europe/London" })
        await model.load()

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertEqual(client.writeAttempts, 1, "it really was attempted")
        XCTAssertEqual(store.all().count, 1, "and then held rather than dropped")
        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.checked, true,
                       "the box does not spring back open")
        XCTAssertTrue(model.isQueued(Fixt.ada))
    }

    /// A `500` is the bridge answering, not an outage. Replaying it would be a retry
    /// loop rather than a capture.
    func testAServerErrorIsNotCaptured() async {
        let store = FakeStore()
        let client = DyingClient()
        client.writeError = .badResponse(500, "boom")
        let model = TodayDashboardModel(makeClient: { client }, now: { Self.fixedNow },
                                        pending: store, zone: { "Europe/London" })
        await model.load()

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertTrue(store.all().isEmpty, "nothing was held")
        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.checked, false,
                       "and the optimism was taken back")
    }

    // MARK: - When capture is NOT possible

    /// **No queue, no promise.** A shell that wired no store keeps the honest refusal
    /// rather than silently saving something nowhere.
    func testWithNoQueueTheOldRefusalStands() async {
        let client = LiveClient()
        let model = TodayDashboardModel(makeClient: { client }, now: { Self.fixedNow })
        await model.load()
        model.isNetworkUnreachable = true

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertEqual(client.checkCount, 0)
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.checked, false,
                       "a refused tap leaves the day alone")
        XCTAssertFalse(model.capturesOffline)
    }

    /// **No day, no capture.** Without a `date` there is nothing to make the replay safe,
    /// and a change held against no day is exactly the blind promise the whole design
    /// argues against.
    func testWithNoDayDateTheOldRefusalStands() async {
        let store = FakeStore()
        var dateless = Fixt.snapshot()
        dateless.date = nil
        final class DatelessClient: TodayProviding, @unchecked Sendable {
            let snap: TodaySnapshot
            init(_ s: TodaySnapshot) { snap = s }
            func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult { .snapshot(snap) }
            func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                           day: String?, ifMatch: String) async throws -> TodayMutationResult {
                .snapshot(snap)
            }
            func moveItem(id: String, op: TodayMoveOp, at: Date, day: String?,
                          ifMatch: String) async throws -> TodayMutationResult { .snapshot(snap) }
            func postpone(id: String, deferred: Bool, at: Date, day: String?,
                          ifMatch: String) async throws -> TodayMutationResult { .snapshot(snap) }
            func glance(id: String, at: Date,
                        ifMatch: String) async throws -> TodayMutationResult { .snapshot(snap) }
        }
        let model = TodayDashboardModel(makeClient: { DatelessClient(dateless) },
                                        now: { Self.fixedNow }, pending: store)
        await model.load()
        model.isNetworkUnreachable = true

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertFalse(model.capturesOffline)
    }

    /// **A drag is refused, not captured.** A landing is a plan of up to two writes whose
    /// second op is aimed at an id the first one changes; capturing half of one is worse
    /// than refusing the gesture and letting the row snap back.
    func testAnOfflineDragIsRefusedRatherThanHeld() async {
        let store = FakeStore()
        let model = await offlineModel(store)

        let plan = await model.reorder(id: Fixt.glazeInErrands,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 0))

        XCTAssertEqual(plan, .refused(TodayDashboardModel.readOnlyNotice))
        XCTAssertTrue(store.all().isEmpty, "nothing was held")
    }

    // MARK: - Managing what is held

    /// Discard takes the local claim back with the row: the day must stop showing a
    /// change nobody is going to make.
    func testDiscardingAHeldChangeTakesTheDayBackWithIt() async {
        let store = FakeStore()
        let model = await offlineModel(store)
        await model.check(id: Fixt.ada, checked: true)
        let held = try? XCTUnwrap(store.all().first)

        model.discardPending(id: held!.id)

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(model.snapshot?.item(id: Fixt.ada)?.checked, false)
        XCTAssertFalse(model.isQueued(Fixt.ada))
        XCTAssertEqual(model.pendingCount, 0)
    }

    /// Retry puts a refusal back in the queue and clears its reason, so the next replay
    /// treats it as new work.
    func testRetryingARefusalRequeuesIt() async {
        let store = FakeStore()
        let model = await offlineModel(store)
        await model.check(id: Fixt.ada, checked: true)
        var held = store.all()[0]
        held.state = .refused
        held.refusalReason = "Today moved on; item not found."
        store.update(held)
        model.refreshPending()

        model.retryPending(id: held.id)

        XCTAssertEqual(store.all().first?.state, .queued)
        XCTAssertNil(store.all().first?.refusalReason)
    }

    /// A refused row stops the day claiming the change, but stays on the pending list —
    /// it is the one thing in the queue that needs a person.
    func testARefusedRowStaysAndStopsTheRowSayingQueued() async {
        let store = FakeStore()
        let model = await offlineModel(store)
        await model.check(id: Fixt.ada, checked: true)
        var held = store.all()[0]
        held.state = .refused
        store.update(held)

        model.refreshPending()

        XCTAssertEqual(model.pendingCount, 1, "still listed")
        XCTAssertFalse(model.isQueued(Fixt.ada), "but no longer described as waiting")
    }

    /// The overlay's `queued` set follows a re-key, like every other field: an entry left
    /// under an id the bridge has replaced would describe a row that no longer exists.
    func testTheQueuedMarkerFollowsARekey() {
        var overlay = TodayOptimism()
        overlay.checks["old"] = true
        overlay.queued.insert("old")

        overlay.rekey(from: "old", to: "new")

        XCTAssertFalse(overlay.isQueued("old"))
        XCTAssertTrue(overlay.isQueued("new"))
    }

    /// Settling one id forgets its queued marker too — otherwise a confirmed round trip
    /// would leave the row still claiming to be waiting.
    func testSettlingClearsTheQueuedMarker() {
        var overlay = TodayOptimism()
        overlay.checks["a"] = true
        overlay.queued.insert("a")
        overlay.settle("a")
        XCTAssertFalse(overlay.isQueued("a"))
    }
}
