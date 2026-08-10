import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The note renderer's two pure halves: the block split and the link extraction.
//
// The link half matters most. A chip the detail view shows has to name the SAME target
// the bridge would resolve, or tapping it starts a conversation about a different file
// — so these assert the rules `bridge/src/today.rs`'s `extract_links` documents, on the
// spellings the vault actually uses.

final class TodayNoteMarkdownTests: XCTestCase {

    private func links(_ line: String) -> [String] {
        TodayNoteMarkdown.links(in: line).map(\.target)
    }

    // MARK: - Links

    /// `[[target|alias]]` keeps the TARGET, `[[target#heading]]` keeps the heading — a
    /// link to a section of a note is a link to that note, and the bridge resolves it by
    /// dropping the heading itself.
    func testWikiLinksKeepTheirTargetAndDropTheAlias() {
        XCTAssertEqual(links("See [[todo-list/Projects/Tag1/HR-Finance]] for the rest."),
                       ["todo-list/Projects/Tag1/HR-Finance"])
        XCTAssertEqual(links("See [[todo-list/Dashboard/Tag1|the Tag1 board]]."),
                       ["todo-list/Dashboard/Tag1"])
        XCTAssertEqual(links("See [[todo-list/Projects/Demo#This-Week]]."),
                       ["todo-list/Projects/Demo#This-Week"])
    }

    func testMarkdownAndBareUrlsBothComeOut() {
        XCTAssertEqual(links("[the agenda](https://example.invalid/a) and more"),
                       ["https://example.invalid/a"])
        XCTAssertEqual(links("Ask about https://example.invalid/kiln/schedule, then stop."),
                       ["https://example.invalid/kiln/schedule"],
                       "sentence punctuation clings to a bare URL; it is not part of it")
        XCTAssertEqual(links("(see https://example.invalid/x)"), ["https://example.invalid/x"])
    }

    func testKindsAreTaggedAndDuplicatesCollapse() {
        let both = TodayNoteMarkdown.links(in: "[[todo-list/A]] and https://example.invalid/x "
                                           + "and [[todo-list/A]] again")
        XCTAssertEqual(both.map(\.kind), ["wiki", "url"])
        XCTAssertEqual(both.map(\.target), ["todo-list/A", "https://example.invalid/x"])
        XCTAssertTrue(both[0].isWiki)
        XCTAssertEqual(both[0].chipLabel, "A", "a wiki chip shows its leaf")
        XCTAssertEqual(both[1].chipLabel, "example.invalid", "a URL chip shows its host")
    }

    func testALineWithNoLinksYieldsNone() {
        XCTAssertTrue(links("Plain prose with brackets [like this] and none of the rest.").isEmpty)
        XCTAssertTrue(links("").isEmpty)
        XCTAssertTrue(links("[[]]").isEmpty, "an empty target is not a link")
    }

    // MARK: - Blocks

    private let note = """
    # Widget

    Everything you need to know about **the widget**, per [[todo-list/Projects/Demo/Other]].

    ## Wiring

    - First, the [thing](https://example.invalid/thing)
    - Second
    \t- Nested under second
    1. A numbered step

    > A quotation from the manual.

    ```
    let x = **not bold**
    ```

    ---

    Closing prose.
    """

    func testEveryLineOfTheNoteBecomesExactlyOneBlock() {
        let blocks = TodayNoteMarkdown.blocks(note)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1),
            .paragraph,
            .heading(level: 2),
            .bullet(depth: 0), .bullet(depth: 0), .bullet(depth: 1),
            .bullet(depth: 0),
            .quote,
            .code,
            .rule,
            .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.id), Array(0..<blocks.count),
                       "position IS the identity: two identical lines are two blocks")
    }

    /// Text is stripped with the same function the day rows use, so a note and the row
    /// that links it read alike — `**bold**` loses its markers, a wiki link becomes its
    /// alias or leaf text, and nothing is dropped.
    func testBlockTextIsStrippedTheSameWayARowIs() throws {
        let blocks = TodayNoteMarkdown.blocks(note)
        XCTAssertEqual(blocks[0].text, "Widget")
        XCTAssertTrue(blocks[1].text.contains("the widget"))
        XCTAssertFalse(blocks[1].text.contains("**"))
        XCTAssertFalse(blocks[1].text.contains("[["))
        XCTAssertEqual(blocks[4].text, "Second")
        XCTAssertEqual(blocks[6].text, "A numbered step")
        XCTAssertEqual(blocks[7].text, "A quotation from the manual.")
    }

    /// A code block is VERBATIM. Stripping it would be stripping the code.
    func testCodeIsNeverStrippedAndNeverLinkScanned() {
        let blocks = TodayNoteMarkdown.blocks("```\nlet a = [[not a link]] ** \n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code)
        XCTAssertEqual(blocks[0].text, "let a = [[not a link]] ** ")
        XCTAssertTrue(blocks[0].links.isEmpty)
    }

    /// A block's links are its own, and its `source` is the RAW line — which is what a
    /// link tap carries, because a conversation about a linked note needs the line that
    /// referenced it, verbatim.
    func testBlocksCarryTheirLinksAndTheirRawSource() throws {
        let blocks = TodayNoteMarkdown.blocks(note)
        let paragraph = try XCTUnwrap(blocks.first { $0.kind == .paragraph })
        XCTAssertEqual(paragraph.links.map(\.target), ["todo-list/Projects/Demo/Other"])
        XCTAssertTrue(paragraph.source.contains("[[todo-list/Projects/Demo/Other]]"),
                      "the source is raw markdown, not the stripped text")
        XCTAssertEqual(blocks[3].links.map(\.target), ["https://example.invalid/thing"])
        XCTAssertTrue(blocks[0].links.isEmpty)
    }

    /// Blank lines separate; they never become blocks of their own. An empty note is no
    /// blocks at all, which is what the view's empty state hangs off.
    func testBlankLinesAreSeparatorsAndAnEmptyNoteHasNoBlocks() {
        XCTAssertTrue(TodayNoteMarkdown.blocks("").isEmpty)
        XCTAssertTrue(TodayNoteMarkdown.blocks("\n\n   \n").isEmpty)
        XCTAssertEqual(TodayNoteMarkdown.blocks("one\n\n\n\ntwo").count, 2)
    }

    /// A construct the model does not know survives as a paragraph rather than
    /// vanishing. A vault note is a hand-written page, and dropping the parts of it this
    /// does not understand would be dropping the note.
    func testUnknownConstructsSurviveAsParagraphs() {
        let blocks = TodayNoteMarkdown.blocks("| a | table |\n####### seven hashes\n")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertTrue(blocks[0].text.contains("table"))
        XCTAssertTrue(blocks[1].text.contains("seven hashes"))
    }

    /// A note's own checkboxes belong to the note. They are drawn as text, never as
    /// something tappable — the day file's items are the only things this app checks off.
    func testANotesOwnCheckboxesStayText() {
        let blocks = TodayNoteMarkdown.blocks("- [ ] a task in the note\n")
        XCTAssertEqual(blocks.first?.kind, .bullet(depth: 0))
        XCTAssertEqual(blocks.first?.text, "[ ] a task in the note")
    }
}
