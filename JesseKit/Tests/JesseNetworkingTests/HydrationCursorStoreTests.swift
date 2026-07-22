import XCTest
@testable import JesseNetworking

/// The presence-based hydration cursor: absent (never hydrated) is distinct from 0.
final class HydrationCursorStoreTests: XCTestCase {

    private func scratch() -> HydrationCursorStore {
        let defaults = UserDefaults(suiteName: "HydrationCursorStoreTests.\(UUID().uuidString)")!
        return HydrationCursorStore(defaults: defaults)
    }

    func testAbsentIsNilNotZero() {
        let store = scratch()
        XCTAssertNil(store.offset("s1"), "an un-hydrated session reads nil, not 0")
    }

    func testSetAndRead() {
        let store = scratch()
        store.setOffset("s1", 0)
        XCTAssertEqual(store.offset("s1"), 0, "0 is a real, present cursor (distinct from absent)")
        store.setOffset("s1", 4096)
        XCTAssertEqual(store.offset("s1"), 4096)
    }

    func testClearReturnsToAbsent() {
        let store = scratch()
        store.setOffset("s1", 100)
        store.clear("s1")
        XCTAssertNil(store.offset("s1"), "clearing returns the session to never-hydrated")
    }

    func testKeysAreIsolatedPerSession() {
        let store = scratch()
        store.setOffset("s1", 10)
        XCTAssertEqual(store.offset("s1"), 10)
        XCTAssertNil(store.offset("s2"))
    }
}
