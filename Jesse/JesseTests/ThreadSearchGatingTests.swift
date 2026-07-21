import XCTest
@testable import Jesse

// The Tier-2 expansion GATING decision (`shouldExpand`) is iOS-only: it decides
// when the on-device query-expansion tier is worth invoking, orchestration that
// lives in the app target, not in the shared JesseConversations predicate. The
// pure multi-token match tests moved to JesseConversationsTests/ThreadMatchingTests
// when `threadMatches`/`threadMatchesAny` were extracted; this keeps the gating
// coverage next to the code it guards.
@MainActor
final class ThreadSearchGatingTests: XCTestCase {

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
