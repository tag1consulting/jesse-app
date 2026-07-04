import XCTest
@testable import Jesse

/// Locks the composer input's multi-line floor. The field is layout-only (no
/// runtime logic to drive from a test), but the floor is exactly the regression
/// being fixed — the input must never collapse to one line — so these assert the
/// invariant a careless edit would reopen.
final class ComposerLayoutTests: XCTestCase {

    func testInputReservesAtLeastThreeLines() {
        // The reported bug was a one-line collapse; the floor must stay multi-line.
        XCTAssertGreaterThanOrEqual(ComposerLayout.inputMinLines, 3)
    }

    func testInputStillGrows() {
        // A sane upper bound above the floor: the field grows with content, then
        // scrolls internally rather than eating the whole transcript.
        XCTAssertGreaterThan(ComposerLayout.inputMaxLines, ComposerLayout.inputMinLines)
    }

    func testLineLimitRangeMatchesBounds() {
        XCTAssertEqual(ComposerLayout.inputLineLimit.lowerBound, ComposerLayout.inputMinLines)
        XCTAssertEqual(ComposerLayout.inputLineLimit.upperBound, ComposerLayout.inputMaxLines)
    }
}
