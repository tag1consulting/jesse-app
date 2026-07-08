import XCTest
@testable import Jesse

/// The persisted pending-write queue (UserDefaults-backed, injectable suite,
/// mirroring `InFlightStore`). Enqueue/dequeue round-trips a `Meal` across what
/// would be a relaunch; dequeue clears; enqueue dedupes by id so a repeatedly-
/// failing meal never grows the store.
final class PendingMealStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.pendingmeals.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func meal(_ id: String, kcal: Double? = 100, fiber: Double? = nil) -> Meal {
        Meal(id: id, consumedAt: Date(timeIntervalSince1970: 1_780_000_000),
             name: "Meal \(id)", kcal: kcal, proteinGrams: nil, carbGrams: nil,
             fatGrams: nil, fiberGrams: fiber)
    }

    func testEnqueueThenDequeueRoundTrips() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue([meal("a"), meal("b")])
        // A fresh store over the SAME defaults is the "relaunch": the queue survives.
        let reloaded = PendingMealStore(defaults: defaults)
        let out = reloaded.dequeueAll()
        XCTAssertEqual(out.map(\.id), ["a", "b"])
        XCTAssertEqual(out.first?.kcal, 100)
    }

    func testFiberRoundTripsAcrossRelaunch() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue([meal("a", fiber: 6)])
        // A fresh store over the SAME defaults is the "relaunch": fiber survives.
        let reloaded = PendingMealStore(defaults: defaults)
        let out = reloaded.dequeueAll()
        XCTAssertEqual(out.map(\.id), ["a"])
        XCTAssertEqual(out.first?.fiberGrams, 6)
    }

    func testDequeueClearsTheStore() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue([meal("a")])
        XCTAssertEqual(store.dequeueAll().count, 1)
        XCTAssertTrue(store.dequeueAll().isEmpty, "a second dequeue is empty — the queue was cleared")
    }

    func testEnqueueDedupesById() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue([meal("a")])
        store.enqueue([meal("a", kcal: 999)]) // same id — must not duplicate
        let out = store.dequeueAll()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kcal, 100, "the first-enqueued meal is kept; the duplicate is dropped")
    }

    func testEnqueueEmptyIsNoOp() {
        let store = PendingMealStore(defaults: defaults)
        store.enqueue([])
        XCTAssertTrue(store.dequeueAll().isEmpty)
    }
}
