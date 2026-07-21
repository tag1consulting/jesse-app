import XCTest
@testable import JesseSearch

// The Tier-2 expansion GATING decision (`shouldExpand`): when the on-device query
// expansion tier is worth invoking. Pure and deterministic, so it is asserted
// directly with no model and no view host. Shared by iOS and macOS via JesseSearch.
final class SearchGatingTests: XCTestCase {

    func testShouldExpandGating() {
        // Trivial (short) query: never expand, regardless of base count.
        XCTAssertFalse(shouldExpand(query: "hi", baseMatchCount: 0, threshold: 5))
        XCTAssertFalse(shouldExpand(query: "  a ", baseMatchCount: 0, threshold: 5))
        // Real word but plentiful base results: no need to widen.
        XCTAssertFalse(shouldExpand(query: "bridge", baseMatchCount: 5, threshold: 5))
        XCTAssertFalse(shouldExpand(query: "bridge", baseMatchCount: 9, threshold: 5))
        // Real word, thin/zero base: expand.
        XCTAssertTrue(shouldExpand(query: "bridge", baseMatchCount: 0, threshold: 5))
        XCTAssertTrue(shouldExpand(query: "bridge", baseMatchCount: 4, threshold: 5))
    }
}
