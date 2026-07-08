import XCTest
@testable import Jesse

/// The reliability core of meal write-back, driven entirely with fakes (no
/// HealthKit, no SwiftData): the gate (toggle + write auth), idempotency by meal
/// id, the pending-queue enqueue on failure, and the drain that retries it. Proves
/// the guarantees the on-device path relies on without a device.
@MainActor
final class MealHealthWriterTests: XCTestCase {

    /// Records writes; each meal id can be forced to fail; auth is togglable.
    private actor FakeMealWriter: MealWriting {
        private(set) var wrote: [String] = []
        private var failIds: Set<String> = []
        private var authorized = true
        func setFailing(_ ids: Set<String>) { failIds = ids }
        func setAuthorized(_ on: Bool) { authorized = on }
        func writtenIds() -> [String] { wrote }
        func write(_ meal: Meal) async -> Bool {
            if failIds.contains(meal.id) { return false }
            wrote.append(meal.id)
            return true
        }
        func isAuthorizedToWrite() async -> Bool { authorized }
    }

    private final class InMemoryWrittenStore: WrittenMealStoring {
        var ids: Set<String> = []
        func isWritten(_ id: String) -> Bool { ids.contains(id) }
        func markWritten(_ id: String) { ids.insert(id) }
    }

    private final class InMemoryPending: PendingMealStoring {
        private var meals: [Meal] = []
        func enqueue(_ m: [Meal]) { for x in m where !meals.contains(where: { $0.id == x.id }) { meals.append(x) } }
        func dequeueAll() -> [Meal] { let out = meals; meals = []; return out }
        func peek() -> [Meal] { meals }
    }

    private func meal(_ id: String, fiber: Double? = nil) -> Meal {
        Meal(id: id, consumedAt: Date(timeIntervalSince1970: 1_780_000_000),
             name: "Meal \(id)", kcal: 100, proteinGrams: nil, carbGrams: nil,
             fatGrams: nil, fiberGrams: fiber)
    }

    private func writer(_ w: FakeMealWriter, _ p: InMemoryPending,
                        enabled: Bool = true) -> MealHealthWriter {
        MealHealthWriter(writer: w, pending: p, isEnabled: { enabled })
    }

    func testWritesNewMealsAndRecordsThem() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p).process([meal("a"), meal("b")], written: store)
        let wrote = await w.writtenIds()
        XCTAssertEqual(wrote.sorted(), ["a", "b"])
        XCTAssertEqual(store.ids, ["a", "b"])
        XCTAssertTrue(p.peek().isEmpty, "successful writes leave the pending queue empty")
    }

    func testWritesAMealCarryingFiber() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p).process([meal("f", fiber: 6)], written: store)
        let wrote = await w.writtenIds()
        XCTAssertEqual(wrote, ["f"], "a meal carrying fiber writes and is recorded")
        XCTAssertEqual(store.ids, ["f"])
        XCTAssertTrue(p.peek().isEmpty)
    }

    func testAlreadyWrittenMealIsSkipped() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let store = InMemoryWrittenStore()
        store.ids = ["a"] // already written on a prior delivery
        await writer(w, p).process([meal("a"), meal("b")], written: store)
        let wrote = await w.writtenIds()
        XCTAssertEqual(wrote, ["b"], "the deduped meal is not written again")
    }

    func testFailedWriteIsEnqueuedNotRecorded() async {
        let w = FakeMealWriter(); await w.setFailing(["b"])
        let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p).process([meal("a"), meal("b")], written: store)
        XCTAssertEqual(store.ids, ["a"], "only the successful write is recorded")
        XCTAssertEqual(p.peek().map(\.id), ["b"], "the failed write is queued for retry")
    }

    func testDrainRetriesPendingAndClearsOnSuccess() async {
        let w = FakeMealWriter(); await w.setFailing(["b"])
        let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p).process([meal("a"), meal("b")], written: store)
        XCTAssertEqual(p.peek().map(\.id), ["b"])
        // The transient failure clears; a drain now succeeds and empties the queue.
        await w.setFailing([])
        await writer(w, p).drainPending(written: store)
        XCTAssertEqual(store.ids, ["a", "b"])
        XCTAssertTrue(p.peek().isEmpty, "a successful drain clears the pending queue")
    }

    func testDrainReEnqueuesWhenStillFailing() async {
        let w = FakeMealWriter(); await w.setFailing(["b"])
        let p = InMemoryPending(); let store = InMemoryWrittenStore()
        p.enqueue([meal("b")])
        await writer(w, p).drainPending(written: store)
        XCTAssertEqual(p.peek().map(\.id), ["b"], "a still-failing meal stays queued")
    }

    func testFeatureOffWritesNothing() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p, enabled: false).process([meal("a")], written: store)
        let wrote = await w.writtenIds()
        XCTAssertTrue(wrote.isEmpty, "toggle off ⇒ nothing written")
        XCTAssertTrue(store.ids.isEmpty)
        XCTAssertTrue(p.peek().isEmpty, "toggle off ⇒ nothing queued either")
    }

    func testUnauthorizedWritesNothing() async {
        let w = FakeMealWriter(); await w.setAuthorized(false)
        let p = InMemoryPending(); let store = InMemoryWrittenStore()
        await writer(w, p).process([meal("a")], written: store)
        let wrote = await w.writtenIds()
        XCTAssertTrue(wrote.isEmpty, "write denied ⇒ nothing written")
        XCTAssertTrue(p.peek().isEmpty)
    }

    func testDrainWhileOffPutsPendingBack() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let store = InMemoryWrittenStore()
        p.enqueue([meal("a")])
        await writer(w, p, enabled: false).drainPending(written: store)
        XCTAssertEqual(p.peek().map(\.id), ["a"], "draining while off must not lose the queued meal")
    }
}
