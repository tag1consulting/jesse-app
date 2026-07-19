import XCTest
@testable import Jesse

/// The persisted pending-apply queue (UserDefaults-backed, injectable suite). Now a v2
/// `PendingMealBatch` (upserts + retracts): enqueue/dequeue round-trips across a relaunch;
/// dequeue clears; enqueue dedupes (upserts by id, retracts by value); and the pre-v2
/// `[Meal]` queue migrates once into upserts.
@MainActor
final class PendingMealStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.pendingmeals.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func meal(_ id: String, kcal: Double? = 100, sodium: Double? = nil) -> Meal {
        Meal(id: id, consumedAt: Date(timeIntervalSince1970: 1_780_000_000),
             name: "Meal \(id)", kcal: kcal, proteinGrams: nil, carbGrams: nil,
             fatGrams: nil, fiberGrams: nil,
             sodiumMg: sodium, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
    }

    private func batch(_ upserts: [Meal] = [], retract: [String] = []) -> PendingMealBatch {
        PendingMealBatch(upserts: upserts, retracts: retract)
    }

    func testEnqueueThenDequeueRoundTripsBothArms() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue(batch([meal("a", sodium: 900), meal("b")], retract: ["gone"]))
        // A fresh store over the SAME defaults is the "relaunch": the batch survives.
        let out = PendingMealStore(defaults: defaults).dequeueAll()
        XCTAssertEqual(out.upserts.map(\.id), ["a", "b"])
        XCTAssertEqual(out.upserts.first?.sodiumMg, 900, "the micronutrient survives the relaunch")
        XCTAssertEqual(out.retracts, ["gone"])
    }

    func testDequeueClearsTheStore() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue(batch([meal("a")], retract: ["r"]))
        XCTAssertFalse(store.dequeueAll().isEmpty)
        XCTAssertTrue(store.dequeueAll().isEmpty, "a second dequeue is empty — the queue was cleared")
    }

    func testEnqueueDedupesUpsertsByIdAndRetractsByValue() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue(batch([meal("a")], retract: ["r"]))
        store.enqueue(batch([meal("a", kcal: 999)], retract: ["r"])) // both dups
        let out = store.dequeueAll()
        XCTAssertEqual(out.upserts.count, 1)
        XCTAssertEqual(out.upserts.first?.kcal, 100, "the first-enqueued upsert is kept")
        XCTAssertEqual(out.retracts, ["r"], "the duplicate retract is dropped")
    }

    func testEnqueueEmptyIsNoOp() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue(.empty)
        XCTAssertTrue(store.dequeueAll().isEmpty)
    }

    func testLegacyV1QueueMigratesIntoUpsertsOnce() {
        // A pre-v2 store wrote a bare `[Meal]` under the `…v1` key. The v2 store reads it
        // as upserts (once), then clears it on dequeue so it never re-migrates.
        let legacy = [meal("old-a"), meal("old-b")]
        if let data = try? JSONEncoder().encode(legacy) {
            defaults.set(data, forKey: "jesse.pendingMealWrites.v1")
        }
        let out = PendingMealStore(defaults: defaults).dequeueAll()
        XCTAssertEqual(out.upserts.map(\.id), ["old-a", "old-b"], "the legacy queue migrates into upserts")
        // Drained: a second read finds nothing (both keys cleared).
        XCTAssertTrue(PendingMealStore(defaults: defaults).dequeueAll().isEmpty)
    }
}
