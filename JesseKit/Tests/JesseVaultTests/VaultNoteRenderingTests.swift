import XCTest
import SwiftUI
import JesseMarkdown
@testable import JesseVault

// WHAT THE READER ADDS ON TOP OF THE GRAMMAR: the vault's own four constructs, the
// read-only task box, the chrome decisions, and the one invariant that covers all of them.
//
// `MarkdownBlockParserTests` already asserts the grammar. Nothing here re-asserts it:
// these are the rules that only make sense once you know what a vault is.
final class VaultNoteRenderingTests: XCTestCase {

    func document(_ note: String) -> VaultNoteDocument {
        VaultNoteDocument.parse(path: "Workshop/Kiln.md", text: note)
    }

    // MARK: - The vault's own block conversions

    func testANumberedListKeepsItsNumbersThroughToTheVaultBlock() {
        let blocks = document("1. strip it back\n1. wet it down").blocks
        XCTAssertEqual(blocks.map(\.kind),
                       [.ordered(depth: 0, number: 1), .ordered(depth: 0, number: 2)])
    }

    func testACalloutSurvivesAsACalloutWithItsTitleAndBody() {
        let blocks = document("> [!warning] Mind the arch\n> measure it cold").blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .callout(type: "warning", title: "Mind the arch"))
        XCTAssertEqual(blocks[0].text, "measure it cold")
    }

    func testACodeBlockCarriesItsLanguageAsAPropertyRatherThanAKind() {
        let blocks = document("```swift\nlet x = 1\n```").blocks
        XCTAssertEqual(blocks[0].kind, .code)
        XCTAssertEqual(blocks[0].language, "swift")
        XCTAssertNil(document("```\nplain\n```").blocks[0].language)
    }

    func testATableBlockCarriesItsCellsAndTheirWikiTargets() {
        let blocks = document("| A | B |\n|---|---|\n| see [[Firings/Log 4]] | x |").blocks
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let headers, let rows, _) = blocks[0].kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows, [["see [[Firings/Log 4]]", "x"]])
        XCTAssertEqual(blocks[0].wikiTargets, ["Firings/Log 4"],
                       "a link inside a cell is a link like any other")
    }

    func testAnImageBlockNamesItsTargetAndIsNeverLoaded() {
        let blocks = document("![the arch](Attachments/arch.png)").blocks
        XCTAssertEqual(blocks.map(\.kind), [.image(alt: "the arch",
                                                   target: "Attachments/arch.png")])
    }

    /// A `[x]` is a task. Any other mark is NOT, and the mark stays in the text rather
    /// than being swallowed by a glyph that would be a lie about what was written.
    func testAnUnusualTaskMarkStaysABulletWithItsMarkIntact() {
        let blocks = document("- [/] half done").blocks
        XCTAssertEqual(blocks[0].kind, .bullet(depth: 0))
        XCTAssertEqual(blocks[0].text, "[/] half done")
    }

    func testACodeBlocksBracketsAreNotWikiTargets() {
        let blocks = document("```\nsee [[Projects/X]]\n```").blocks
        XCTAssertEqual(blocks[0].wikiTargets, [],
                       "four characters in a fence are four characters")
    }

    // MARK: - Inline segments the vault owns

    func testAnEmbedIsItsOwnSegmentAndResolvesLikeALink() {
        XCTAssertEqual(VaultNoteRenderer.segments("see ![[Firings/Log 4]] for it"), [
            .text("see "),
            .embed(target: "Firings/Log 4", label: "Log 4"),
            .text(" for it"),
        ])
    }

    func testAHighlightAndATagBecomeTheirOwnSegments() {
        XCTAssertEqual(VaultNoteRenderer.segments("the ==back seam== again #pottery"), [
            .text("the "),
            .highlight("back seam"),
            .text(" again "),
            .tag("#pottery"),
        ])
    }

    func testABareUrlBecomesItsOwnSegment() {
        XCTAssertEqual(VaultNoteRenderer.segments("see https://example.invalid/x"),
                       [.text("see "), .autoLink("https://example.invalid/x")])
    }

    /// THE RULE THAT PROTECTS SOMEBODY'S TYPING. A code span is shown exactly as written,
    /// brackets and all, and it reaches the markdown pass with its backticks so it still
    /// renders as code.
    func testADoubleBracketInsideACodeSpanNeverBecomesALink() {
        XCTAssertEqual(VaultNoteRenderer.segments("write `[[Projects/X]]` in a note"),
                       [.text("write `[[Projects/X]]` in a note")])
        XCTAssertTrue(VaultNoteRenderer.unresolvedTargets(in: "write `[[Projects/X]]` here",
                                                          resolved: [:]).isEmpty)
    }

    func testAnInlineImageIsNamedNotLoaded() {
        XCTAssertEqual(VaultNoteRenderer.segments("before ![the arch](arch.png) after"), [
            .text("before "),
            .image(alt: "the arch", target: "arch.png"),
            .text(" after"),
        ])
        XCTAssertTrue(VaultNoteRenderer.imageCaption(alt: "", target: "a/b/arch.png")
            .contains("arch.png"), "an image with no alt is named by its file")
    }

    // MARK: - What the attributed string actually carries

    func testAHighlightCarriesAYellowBackgroundAndALinkDoesNot() {
        let attributed = VaultNoteRenderer.attributed("the ==back seam== again", resolved: [:])
        let backgrounds = attributed.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(backgrounds.count, 1)
        XCTAssertEqual(backgrounds.first, Color.yellow.opacity(0.3))
        XCTAssertEqual(String(attributed.characters), "the back seam again",
                       "the markers leave the text")
    }

    /// Colour only, NEVER a font: a tag can sit inside a heading, and a font attribute
    /// would leave one word of that heading at body size.
    func testATagIsColouredAndCarriesNoFontOrLink() {
        let attributed = VaultNoteRenderer.attributed("about #pottery today", resolved: [:])
        let tagRun = attributed.runs.first { $0.foregroundColor != nil }
        XCTAssertNotNil(tagRun)
        XCTAssertNil(tagRun?.font, "a font here would override the block's own")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil },
                      "there is no tag index on this device to send anybody to")
        XCTAssertEqual(String(attributed.characters), "about #pottery today")
    }

    func testAResolvedEmbedIsTappableAndCarriesTheEmbedGlyph() {
        let attributed = VaultNoteRenderer.attributed(
            "see ![[Log 4]] now", resolved: ["Log 4": "Firings/Log 4.md"])
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(VaultNoteRenderer.path(fromLinkURL: try! XCTUnwrap(links.first)),
                       "Firings/Log 4.md")
        XCTAssertTrue(String(attributed.characters)
            .contains(VaultNoteRenderer.embedGlyph + "Log 4"))
    }

    /// An ordinary markdown link keeps its shape: the brackets and parentheses leave the
    /// text and the WORDS become the link. Caught by rendering the every-construct fixture
    /// and looking at it — the bare-URL split used to steal the target out of the
    /// parentheses and leave the reader drawing punctuation.
    func testAMarkdownLinkStillRendersAsItsWords() {
        let attributed = VaultNoteRenderer.attributed(
            "a [markdown link](https://example.invalid/x) here", resolved: [:])

        XCTAssertEqual(String(attributed.characters), "a markdown link here")
        XCTAssertEqual(attributed.runs.compactMap(\.link).first?.absoluteString,
                       "https://example.invalid/x")
    }

    func testABareUrlIsTappable() {
        let attributed = VaultNoteRenderer.attributed("see https://example.invalid/x",
                                                      resolved: [:])
        XCTAssertEqual(attributed.runs.compactMap(\.link).first?.absoluteString,
                       "https://example.invalid/x")
    }

    /// The fast path must not change what a run renders as — only how long it takes.
    func testTheMarkdownFastPathAgreesWithTheSlowPath() {
        for run in ["plain words only", "no markup at all 1234", "a, b and c."] {
            XCTAssertFalse(VaultNoteRenderer.mayContainMarkdown(run))
            XCTAssertEqual(String(VaultNoteRenderer.inline(run).characters), run)
        }
        for run in ["**bold**", "a `span`", "a [link](x)", "a ~~strike~~", "an &amp;"] {
            XCTAssertTrue(VaultNoteRenderer.mayContainMarkdown(run), run)
        }
    }

    func testBoldAndStrikethroughStillComeFromTheMarkdownPass() {
        let attributed = VaultNoteRenderer.attributed("a **bold** and ~~struck~~ line",
                                                      resolved: [:])
        XCTAssertEqual(String(attributed.characters), "a bold and struck line",
                       "the markers leave the text")
    }

    // MARK: - The missing-link caption reaches into a table

    func testAnUnresolvedLinkInsideATableCellIsStillCaptioned() {
        let block = document("| A |\n|---|\n| [[Nowhere]] |").blocks[0]
        XCTAssertEqual(VaultNoteReaderView.missingCaption(block, resolved: [:]),
                       "Nowhere is not in this copy of the vault.")
    }

    // MARK: - The scroll target

    func testTheScrollTargetIsTheFirstBlockAtOrAfterTheHitsLine() {
        let blocks = document("# One\n\nTwo\n\n## Three\n\nFour").blocks
        XCTAssertEqual(blocks.map(\.line), [1, 3, 5, 7])

        XCTAssertEqual(VaultNoteDocument.blockID(forLine: 1, in: blocks), 0)
        XCTAssertEqual(VaultNoteDocument.blockID(forLine: 4, in: blocks), 2,
                       "a hit between two blocks lands on the one below it")
        XCTAssertEqual(VaultNoteDocument.blockID(forLine: 5, in: blocks), 2)
        XCTAssertEqual(VaultNoteDocument.blockID(forLine: 900, in: blocks), 3,
                       "a hit past the end lands on the last block rather than nowhere")
        XCTAssertNil(VaultNoteDocument.blockID(forLine: 1, in: []))
    }

    func testTheScrollAnchorKeepsRawLinesAndBlocksApart() {
        XCTAssertNotEqual(VaultNoteReaderView.anchorID(3, raw: true),
                          VaultNoteReaderView.anchorID(3, raw: false))
    }

    // MARK: - Raw needs the file

    func testTheDocumentKeepsItsOwnLinesForTheRawView() {
        let note = "---\ntitle: A\n---\n\n# Heading\n\nBody.\n"
        let document = self.document(note)
        XCTAssertEqual(document.rawLines.first, "---",
                       "in raw, the file is the file — frontmatter included")
        XCTAssertTrue(document.rawLines.contains("title: A"))
        XCTAssertTrue(document.rawLines.contains("# Heading"))
    }

    // MARK: - Chrome

    func testTheReaderModeToggles() {
        XCTAssertEqual(VaultReaderMode.formatted.toggled, .raw)
        XCTAssertEqual(VaultReaderMode.raw.toggled, .formatted)
        XCTAssertEqual(VaultReaderMode(showsRaw: true), .raw)
        XCTAssertEqual(VaultReaderMode(showsRaw: false), .formatted)
        XCTAssertEqual(VaultReaderMode.formatted.buttonLabel, "Raw",
                       "the button says what it will do, not where you are")
        XCTAssertEqual(VaultReaderMode.raw.buttonLabel, "Formatted")
    }

    /// FORMATTED BY DEFAULT — the whole argument of this change in one assertion — and the
    /// choice survives, because making somebody press the button again on every note is
    /// how a feature gets abandoned.
    func testThePreferenceDefaultsToFormattedAndRoundTrips() throws {
        let suite = "vault.reader.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VaultReaderPreferences(defaults: defaults)

        XCTAssertFalse(preferences.showsRaw)
        XCTAssertEqual(preferences.mode, .formatted)

        preferences.mode = .raw
        XCTAssertTrue(preferences.showsRaw)
        XCTAssertEqual(VaultReaderPreferences(defaults: defaults).mode, .raw,
                       "a second reader on this device sees the same choice")

        preferences.showsRaw = false
        XCTAssertEqual(VaultReaderPreferences(defaults: defaults).mode, .formatted)
    }

    func testEveryCalloutTypeHasASymbolAndAnUnknownOneFallsBackToNote() {
        for type in VaultCalloutStyle.knownTypes {
            XCTAssertFalse(VaultCalloutStyle.style(for: type).symbol.isEmpty, type)
            XCTAssertTrue(VaultCalloutStyle.isKnown(type))
        }
        XCTAssertEqual(VaultCalloutStyle.style(for: "kiln"),
                       VaultCalloutStyle.style(for: "note"))
        XCTAssertFalse(VaultCalloutStyle.isKnown("kiln"))
        XCTAssertEqual(VaultCalloutStyle.style(for: "WARNING"),
                       VaultCalloutStyle.style(for: "warning"))
    }

    /// A `Grid` builds every cell it is given, so one long table inside an otherwise lazy
    /// note is the whole note's frame budget spent in one block.
    func testABigTableIsWindowedAndASmallOneIsNot() {
        XCTAssertEqual(VaultTableWindow.window(rowCount: 10, expanded: false).shown, 10)
        XCTAssertEqual(VaultTableWindow.window(rowCount: 10, expanded: false).hidden, 0)

        let big = VaultTableWindow.window(rowCount: 200, expanded: false)
        XCTAssertEqual(big.shown, VaultTableWindow.initialRows)
        XCTAssertEqual(big.hidden, 200 - VaultTableWindow.initialRows)

        XCTAssertEqual(VaultTableWindow.window(rowCount: 200, expanded: true).shown, 200)
        XCTAssertEqual(VaultTableWindow.window(rowCount: 200, expanded: true).hidden, 0)
    }
}
