import XCTest
@testable import Jesse

@MainActor
final class TranscriptScrollTests: XCTestCase {

    // MARK: - shouldAutoScroll: trigger × position

    /// Sending a turn always scrolls — the user just spoke, show it — regardless
    /// of where they'd scrolled to.
    func testUserSentTurnAlwaysScrolls() {
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: true, trigger: .userSentTurn))
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: false, trigger: .userSentTurn))
    }

    /// Opening a thread always lands at the newest message.
    func testAppearedAlwaysScrolls() {
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: true, trigger: .appeared))
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: false, trigger: .appeared))
    }

    /// A streamed delta follows only when the user is parked at the bottom. This
    /// is the core regression guard: the pre-fix view scrolled on every delta
    /// unconditionally, yanking a user who'd scrolled up back down.
    func testStreamDeltaFollowsOnlyWhenAtBottom() {
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: true, trigger: .streamDelta))
        XCTAssertFalse(TranscriptScroll.shouldAutoScroll(isAtBottom: false, trigger: .streamDelta))
    }

    /// An appended finished reply follows only when at the bottom.
    func testJesseTurnAppendedFollowsOnlyWhenAtBottom() {
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: true, trigger: .jesseTurnAppended))
        XCTAssertFalse(TranscriptScroll.shouldAutoScroll(isAtBottom: false, trigger: .jesseTurnAppended))
    }

    /// A running-flag flip follows only when at the bottom.
    func testRunningChangedFollowsOnlyWhenAtBottom() {
        XCTAssertTrue(TranscriptScroll.shouldAutoScroll(isAtBottom: true, trigger: .runningChanged))
        XCTAssertFalse(TranscriptScroll.shouldAutoScroll(isAtBottom: false, trigger: .runningChanged))
    }

    // MARK: - isAtBottom: geometry threshold

    /// Exactly at the end counts as at the bottom.
    func testAtExactBottom() {
        XCTAssertTrue(TranscriptScroll.isAtBottom(
            contentOffsetY: 900, contentHeight: 1000, containerHeight: 100, threshold: 40))
    }

    /// Within the threshold of the end still counts (rubber-banding / growing partial).
    func testWithinThresholdIsAtBottom() {
        // maxOffset = 1000 - 100 = 900; offset 870 is 30 short, inside the 40pt band.
        XCTAssertTrue(TranscriptScroll.isAtBottom(
            contentOffsetY: 870, contentHeight: 1000, containerHeight: 100, threshold: 40))
    }

    /// Just past the threshold counts as scrolled up.
    func testBeyondThresholdIsNotAtBottom() {
        // maxOffset = 900; offset 859 is 41 short, just outside the 40pt band.
        XCTAssertFalse(TranscriptScroll.isAtBottom(
            contentOffsetY: 859, contentHeight: 1000, containerHeight: 100, threshold: 40))
    }

    /// The exact boundary (maxOffset - threshold) is inclusive.
    func testThresholdBoundaryIsInclusive() {
        // maxOffset = 900; 900 - 40 = 860 exactly → at bottom.
        XCTAssertTrue(TranscriptScroll.isAtBottom(
            contentOffsetY: 860, contentHeight: 1000, containerHeight: 100, threshold: 40))
        XCTAssertFalse(TranscriptScroll.isAtBottom(
            contentOffsetY: 859.9, contentHeight: 1000, containerHeight: 100, threshold: 40))
    }

    /// Content shorter than the viewport is trivially at the bottom (nothing to scroll).
    func testContentShorterThanViewportIsAtBottom() {
        XCTAssertTrue(TranscriptScroll.isAtBottom(
            contentOffsetY: 0, contentHeight: 50, containerHeight: 100, threshold: 40))
    }
}
