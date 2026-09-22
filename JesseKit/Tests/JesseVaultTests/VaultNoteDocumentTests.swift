import XCTest
@testable import JesseVault

// The reader's own model of a note: the blocks it draws, the frontmatter it folds away,
// the checkboxes it shows as glyphs, and the ceiling it stops at. Plus the inline split
// that turns `[[wiki links]]` into something a reader can follow.

final class VaultNoteDocumentTests: XCTestCase {

    // MARK: - Blocks

    func testTheBlockKindsAreRecognizedAndNothingIsDropped() {
        let note = """
            # Kiln notes

            The floor cracked.

            ## Bricks

            - soft bricks
            - [ ] order them
            - [x] measure the arch

            > the yard is closed in August

            ```
            fire schedule
            ```

            ---
            """
        let document = VaultNoteDocument.parse(path: "Workshop/Kiln.md", text: note)
        let kinds = document.blocks.map(\.kind)

        XCTAssertEqual(kinds.first, .heading(level: 1))
        XCTAssertTrue(kinds.contains(.heading(level: 2)))
        XCTAssertTrue(kinds.contains(.bullet(depth: 0)))
        XCTAssertTrue(kinds.contains(.checkbox(depth: 0, checked: false)))
        XCTAssertTrue(kinds.contains(.checkbox(depth: 0, checked: true)))
        XCTAssertTrue(kinds.contains(.quote))
        XCTAssertTrue(kinds.contains(.code))
        XCTAssertTrue(kinds.contains(.rule))
        XCTAssertTrue(document.blocks.contains { $0.text == "The floor cracked." })
    }

    /// A task box becomes a GLYPH and its marker leaves the text: this note is open
    /// read-only, and a box that looked tappable would promise a write the reader does not
    /// do.
    func testATaskBoxBecomesAGlyphAndLeavesTheText() {
        let document = VaultNoteDocument.parse(path: "A.md", text: "- [x] measure the arch\n")
        let block = document.blocks[0]

        XCTAssertEqual(block.kind, .checkbox(depth: 0, checked: true))
        XCTAssertEqual(block.text, "measure the arch")
    }

    func testIndentedBulletsCarryTheirDepth() {
        let note = "- top\n\t- one in\n\t\t- two in\n"
        let kinds = VaultNoteDocument.parse(path: "A.md", text: note).blocks.map(\.kind)
        XCTAssertEqual(kinds, [.bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 2)])
    }

    /// Code is verbatim, indentation included: a code block stripped of its markdown is a
    /// code block that no longer compiles.
    func testCodeIsKeptVerbatim() {
        let note = "```\n    indented = true\n```\n"
        let document = VaultNoteDocument.parse(path: "A.md", text: note)
        XCTAssertEqual(document.blocks.map(\.text), ["    indented = true"])
    }

    func testFrontmatterIsHeldSeparatelyAndTheTitleComesFromIt() {
        let note = "---\ntitle: The Kiln Rebuild\ntags: pottery\n---\n\nBody.\n"
        let document = VaultNoteDocument.parse(path: "Workshop/Kiln.md", text: note)

        XCTAssertEqual(document.frontmatter, ["title: The Kiln Rebuild", "tags: pottery"])
        XCTAssertEqual(document.title, "The Kiln Rebuild")
        XCTAssertFalse(document.blocks.contains { $0.text.contains("tags:") },
                       "frontmatter is folded away, not drawn as content")
    }

    func testEveryBlockKnowsItsLine() {
        let note = "# One\n\nTwo.\n\n## Three\n"
        let document = VaultNoteDocument.parse(path: "A.md", text: note)
        XCTAssertEqual(document.blocks.map(\.line), [1, 3, 5])
    }

    // MARK: - The ceiling

    /// A note over the cap renders its first 256 KB and SAYS SO. Silently showing two
    /// thirds of a note is the kind of quiet lie that costs a reader an afternoon.
    func testALongNoteIsTruncatedAndSaysSo() {
        let long = String(repeating: "brick ", count: 400)
        let document = VaultNoteDocument.parse(path: "A.md", text: long, byteLimit: 100)

        XCTAssertTrue(document.truncated)
        XCTAssertLessThanOrEqual(document.blocks.map(\.text).joined().utf8.count, 100)
    }

    func testAShortNoteIsNotTruncated() {
        XCTAssertFalse(VaultNoteDocument.parse(path: "A.md", text: "short\n").truncated)
    }

    /// The cut lands on a CHARACTER boundary. Cutting on a byte boundary is how a reader
    /// gets a replacement glyph in the middle of an Italian street name.
    func testTheCutNeverSplitsACharacter() {
        let text = String(repeating: "caffè ", count: 50)
        let (cut, truncated) = VaultNoteDocument.truncate(text, byteLimit: 25)

        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(cut.utf8.count, 25)
        XCTAssertFalse(cut.contains("\u{FFFD}"))
        XCTAssertTrue(text.hasPrefix(cut))
    }

    // MARK: - Inline links

    func testALineSplitsIntoPlainRunsAndLinkRuns() {
        let segments = VaultNoteRenderer.segments(
            "Ask [[Suppliers/Terrasole]] about the [[People/Marta Ruggeri|burner]] quote.")

        XCTAssertEqual(segments, [
            .text("Ask "),
            .wikiLink(target: "Suppliers/Terrasole", label: "Terrasole"),
            .text(" about the "),
            .wikiLink(target: "People/Marta Ruggeri", label: "burner"),
            .text(" quote."),
        ])
    }

    /// An alias is what the writer chose to read well in the sentence, so it is what shows;
    /// without one, the file name shows rather than four folder names.
    func testTheLabelIsTheAliasElseTheLeafName() {
        XCTAssertEqual(VaultNoteRenderer.displayLabel("A/B/C"), "C")
        XCTAssertEqual(VaultNoteRenderer.displayLabel("A/B/C|see this"), "see this")
        XCTAssertEqual(VaultNoteRenderer.displayLabel("A/B/C|"), "C",
                       "an empty alias is not an alias")
    }

    /// An unclosed `[[` is text, and the rest of the line survives it.
    func testAnUnclosedLinkKeepsTheRestOfTheLine() {
        XCTAssertEqual(VaultNoteRenderer.segments("before [[ after"),
                       [.text("before [[ after")])
    }

    /// The link URL round trips, and only OUR scheme is claimed — an `https` link in a note
    /// still belongs to the system.
    func testTheLinkUrlRoundTripsAndClaimsOnlyItsOwnScheme() throws {
        let url = try XCTUnwrap(VaultNoteRenderer.linkURL(forPath: "People/Marta Ruggeri.md"))
        XCTAssertEqual(VaultNoteRenderer.path(fromLinkURL: url), "People/Marta Ruggeri.md")
        XCTAssertNil(VaultNoteRenderer.path(fromLinkURL: try XCTUnwrap(URL(string: "https://tag1.com"))))
    }

    /// A target the vault cannot resolve is named in a caption rather than rendered as a
    /// link that goes nowhere.
    func testUnresolvedTargetsAreReported() {
        let line = "See [[Suppliers/Terrasole]] and [[Nowhere]]."
        let resolved = ["Suppliers/Terrasole": "Suppliers/Terrasole.md"]

        XCTAssertEqual(VaultNoteRenderer.unresolvedTargets(in: line, resolved: resolved),
                       ["Nowhere"])
        XCTAssertEqual(VaultNoteRenderer.unresolvedTargets(in: line,
                                                          resolved: resolved.merging(
                                                            ["Nowhere": "N.md"]) { a, _ in a }),
                       [])
    }

    /// The resolved link carries a URL and the unresolved one does not — the whole
    /// difference, asserted on the attributed string the reader actually draws.
    func testOnlyResolvedLinksCarryAUrl() {
        let attributed = VaultNoteRenderer.attributed(
            "See [[Terrasole]] and [[Nowhere]].",
            resolved: ["Terrasole": "Suppliers/Terrasole.md"])

        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(VaultNoteRenderer.path(fromLinkURL: try! XCTUnwrap(links.first)),
                       "Suppliers/Terrasole.md")
        XCTAssertTrue(String(attributed.characters).contains("Nowhere"),
                      "the unresolved link still reads as its own words")
    }

    /// FTS5's markers become bold runs and leave the text — a snippet that showed control
    /// characters would be a snippet nobody could read.
    func testSnippetMarkersBecomeBoldAndLeaveTheText() {
        let raw = "the \(VaultSearchHit.markStart)kiln\(VaultSearchHit.markEnd) is rebuilt"
        let attributed = VaultNoteRenderer.snippet(raw)
        let plain = String(attributed.characters)

        XCTAssertEqual(plain, "the kiln is rebuilt")
        let bolded = attributed.runs.filter {
            $0.inlinePresentationIntent == .stronglyEmphasized
        }
        XCTAssertEqual(bolded.count, 1)
    }

    /// An unterminated marker (a snippet cut mid-highlight) loses NO text: the marker
    /// disappears and every word around it survives, which is the only acceptable outcome
    /// for a control character that was never meant to be seen.
    func testAnUnterminatedMarkerLosesNoText() {
        let raw = "the \(VaultSearchHit.markStart)kiln"
        let rendered = String(VaultNoteRenderer.snippet(raw).characters)

        XCTAssertEqual(rendered, "the kiln")
        XCTAssertFalse(rendered.contains(VaultSearchHit.markStart))
    }

    // MARK: - The provenance line

    /// Every note says where it came from, whether or not it is stale: a badge that appears
    /// sometimes is a badge nobody reads.
    func testTheProvenanceLineNamesTheLocalCopyAlways() {
        XCTAssertTrue(VaultNoteReaderView.provenance(nil).contains("Local copy"))
        XCTAssertTrue(VaultNoteReaderView.provenance(Date()).contains("Local copy"))
        XCTAssertTrue(VaultNoteReaderView.provenance(Date()).contains("modified"))
    }

    func testTheMissingLinkCaptionNamesTheFileRatherThanThePath() {
        let block = VaultNoteBlock(id: 0, kind: .paragraph,
                                   text: "See [[Projects/Deep/Nowhere]].")
        let caption = VaultNoteReaderView.missingCaption(block, resolved: [:])

        XCTAssertEqual(caption, "Nowhere is not in this copy of the vault.")
        XCTAssertNil(VaultNoteReaderView.missingCaption(
            VaultNoteBlock(id: 0, kind: .paragraph, text: "no links here"), resolved: [:]))
    }
}
