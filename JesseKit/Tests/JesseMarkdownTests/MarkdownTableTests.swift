import XCTest
@testable import JesseMarkdown

// THE TABLE PRIMITIVES, ASSERTED WHERE THEY NOW LIVE.
//
// These four declarations came out of `Jesse/Jesse/MarkdownText.swift`, where they had
// only ever been exercised THROUGH `parseMarkdownBlocks` — the iOS reply parser's own
// tests, which still pass unchanged and still cover that parser's own assembly of a table
// block. What was missing, and what a move is the moment to add, is a direct assertion of
// each primitive on its own: the delimiter test, the splitter and the alignment reader are
// now shared by two renderers, and a shared rule with no test of its own is a rule the
// next caller gets to rediscover.
final class MarkdownTableTests: XCTestCase {

    // MARK: - The delimiter row

    func testADelimiterRowIsCellsOfDashesAndColons() {
        XCTAssertTrue(isTableDelimiterRow("|---|---|"))
        XCTAssertTrue(isTableDelimiterRow("| --- | --- |"))
        XCTAssertTrue(isTableDelimiterRow("|:--|--:|"))
        XCTAssertTrue(isTableDelimiterRow("|:-:|:-:|"))
    }

    func testProseWithAPipeIsNotADelimiterRow() {
        XCTAssertFalse(isTableDelimiterRow("use a | b to pipe"))
        XCTAssertFalse(isTableDelimiterRow("| Name | Count |"))
        XCTAssertFalse(isTableDelimiterRow("-----"), "no pipe at all")
        XCTAssertFalse(isTableDelimiterRow("| | |"), "an empty cell is not a delimiter")
        XCTAssertFalse(isTableDelimiterRow("|:::|:::|"), "colons with no dash")
    }

    // MARK: - Splitting a row

    func testARowSplitsIntoTrimmedCellsWithTheOuterPipesDropped() {
        XCTAssertEqual(splitTableRow("| a | b | c |"), ["a", "b", "c"])
        XCTAssertEqual(splitTableRow("a | b"), ["a", "b"])
        XCTAssertEqual(splitTableRow("| a |"), ["a"])
    }

    /// An empty cell is a CELL. Dropping it would slide every cell after it one column to
    /// the left, which is how a table quietly starts lying about which column a number is
    /// in.
    func testAnEmptyCellKeepsItsColumn() {
        XCTAssertEqual(splitTableRow("| a |  | c |"), ["a", "", "c"])
    }

    // MARK: - Alignment

    func testAlignmentComesFromTheColons() {
        XCTAssertEqual(parseTableAlignments("|:--|--:|:-:|---|"),
                       [.leading, .trailing, .center, .leading])
    }

    func testAlignmentOfAPlainDelimiterIsLeading() {
        XCTAssertEqual(parseTableAlignments("| --- | --- |"), [.leading, .leading])
    }
}
