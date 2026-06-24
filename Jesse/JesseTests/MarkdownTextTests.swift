import XCTest
@testable import Jesse

final class MarkdownTextTests: XCTestCase {

    func testHeadingLevels() {
        XCTAssertEqual(parseMarkdownBlocks("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parseMarkdownBlocks("## Sub"), [.heading(level: 2, text: "Sub")])
        XCTAssertEqual(parseMarkdownBlocks("### x"), [.heading(level: 3, text: "x")])
    }

    func testHeadingBeyondLevelThreeIsParagraph() {
        // Four '#' is not a supported heading — stays a paragraph.
        XCTAssertEqual(parseMarkdownBlocks("#### deep"), [.paragraph("#### deep")])
    }

    func testBulletMarkers() {
        XCTAssertEqual(parseMarkdownBlocks("- a"), [.bullet(text: "a")])
        XCTAssertEqual(parseMarkdownBlocks("* a"), [.bullet(text: "a")])
        XCTAssertEqual(parseMarkdownBlocks("+ a"), [.bullet(text: "a")])
    }

    func testNumberedItem() {
        XCTAssertEqual(parseMarkdownBlocks("1. a"), [.numbered(number: 1, text: "a")])
        XCTAssertEqual(parseMarkdownBlocks("42. answer"), [.numbered(number: 42, text: "answer")])
    }

    func testFencedCodeBlock() {
        let raw = "```\nlet x = 1\nlet y = 2\n```"
        XCTAssertEqual(parseMarkdownBlocks(raw), [.code("let x = 1\nlet y = 2")])
    }

    func testFencedCodeWithLanguageHint() {
        // A language hint after the opening fence is still treated as a fence.
        let raw = "```swift\nprint(1)\n```"
        XCTAssertEqual(parseMarkdownBlocks(raw), [.code("print(1)")])
    }

    func testTwoParagraphsSeparatedByBlankLine() {
        let raw = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(parseMarkdownBlocks(raw),
                       [.paragraph("First paragraph."), .paragraph("Second paragraph.")])
    }

    func testConsecutiveLinesCollapseIntoOneParagraph() {
        let raw = "line one\nline two"
        XCTAssertEqual(parseMarkdownBlocks(raw), [.paragraph("line one\nline two")])
    }

    func testInlineMarkupSurvivesParsing() {
        // The parser must NOT strip inline markup — rendering handles that.
        let raw = "This is **bold** and a [link](https://example.com)."
        XCTAssertEqual(parseMarkdownBlocks(raw),
                       [.paragraph("This is **bold** and a [link](https://example.com).")])
    }

    func testTableWithAlignmentDelimiters() {
        let raw = """
        | Name | Count |
        |:--|--:|
        | apples | 3 |
        | pears | 10 |
        """
        XCTAssertEqual(parseMarkdownBlocks(raw), [
            .table(
                headers: ["Name", "Count"],
                rows: [["apples", "3"], ["pears", "10"]],
                alignments: [.leading, .trailing]
            ),
        ])
    }

    func testPipeLineWithoutDelimiterStaysParagraph() {
        // Prose containing a pipe but no delimiter row must NOT become a table.
        let raw = "use a | b to pipe"
        XCTAssertEqual(parseMarkdownBlocks(raw), [.paragraph("use a | b to pipe")])
    }

    func testRaggedTableRowPadsAndTruncates() {
        // A short row (fewer cells than headers) and a long row (extra cells)
        // both parse without crashing; rendering pads/truncates to header count.
        let raw = """
        | A | B | C |
        | --- | --- | --- |
        | only-one |
        | w | x | y | z |
        """
        XCTAssertEqual(parseMarkdownBlocks(raw), [
            .table(
                headers: ["A", "B", "C"],
                rows: [["only-one"], ["w", "x", "y", "z"]],
                alignments: [.leading, .leading, .leading]
            ),
        ])
    }

    func testMixedDocument() {
        let raw = """
        # Heading

        A paragraph here.

        - first
        - second

        1. one
        2. two
        """
        XCTAssertEqual(parseMarkdownBlocks(raw), [
            .heading(level: 1, text: "Heading"),
            .paragraph("A paragraph here."),
            .bullet(text: "first"),
            .bullet(text: "second"),
            .numbered(number: 1, text: "one"),
            .numbered(number: 2, text: "two"),
        ])
    }
}
