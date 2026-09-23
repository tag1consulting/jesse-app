import XCTest
@testable import JesseVault

// The chunker: where a note is cut, what each piece is called, and which line it starts
// on. Pure — every assertion below is a string in and a value out, no filesystem.

final class VaultChunkerTests: XCTestCase {

    // MARK: - Where the cuts are

    /// `##` and deeper start a new chunk. `#` does NOT: a vault note's single `# ` line is
    /// its title, and splitting there would produce one chunk for the whole file and
    /// defeat the exercise.
    func testSectionsSplitAtLevelTwoAndDeeperButNeverAtLevelOne() {
        let note = """
            # Kiln notes

            The floor cracked.

            ## Bricks

            Forty soft bricks.

            ### Sizes

            Two inches.
            """
        let parsed = VaultChunker.parse(relativePath: "Workshop/Kiln.md", text: note)

        XCTAssertEqual(parsed.chunks.map(\.heading), ["", "Bricks", "Sizes"])
        XCTAssertTrue(parsed.chunks[0].body.contains("# Kiln notes"),
                      "the `# ` title stays in the preamble chunk rather than starting one")
        XCTAssertTrue(parsed.chunks[0].body.contains("The floor cracked."))
    }

    /// Each chunk records the 1-BASED line of its own first line, counted over the whole
    /// file — which is the number a person can type into an editor.
    func testEachChunkKnowsTheOneBasedLineItStartsOn() {
        let note = """
            # Title

            Opening.

            ## Second

            Body.
            """
        let parsed = VaultChunker.parse(relativePath: "A.md", text: note)

        XCTAssertEqual(parsed.chunks[0].lineStart, 1, "the preamble starts on line 1")
        XCTAssertEqual(parsed.chunks[1].lineStart, 5, "`## Second` is the fifth line")
    }

    /// Frontmatter is counted but never indexed, and the lines after it keep their real
    /// numbers: an offset of three would send every reader to the wrong place.
    func testFrontmatterIsNotAChunkAndDoesNotShiftLineNumbers() {
        let note = """
            ---
            title: The Kiln Rebuild
            tags: pottery
            ---
            # Kiln notes

            Body.
            """
        let parsed = VaultChunker.parse(relativePath: "Workshop/Kiln.md", text: note)

        XCTAssertEqual(parsed.frontmatterLineCount, 4)
        XCTAssertEqual(parsed.chunks.count, 1)
        XCTAssertEqual(parsed.chunks[0].lineStart, 5,
                       "the first content line is the fifth line of the file")
        XCTAssertFalse(parsed.chunks[0].body.contains("tags: pottery"),
                       "frontmatter is metadata and is never searchable body text")
    }

    /// A section over the cap is cut again, and only ever AT A BLANK LINE: a chunk that
    /// began mid-sentence would put half a thought in one hit and half in another.
    func testALongSectionIsSplitAtParagraphBoundaries() {
        let paragraph = String(repeating: "The slip bucket needs stirring. ", count: 25)
        XCTAssertGreaterThan(paragraph.count, 700, "fixture check: each paragraph is chunky")
        let note = "## Long\n\n" + Array(repeating: paragraph, count: 4).joined(separator: "\n\n")

        let chunks = VaultChunker.parse(relativePath: "A.md", text: note).chunks

        XCTAssertGreaterThan(chunks.count, 1, "a 3 KB section is more than one chunk")
        for chunk in chunks {
            XCTAssertEqual(chunk.heading, "Long", "every piece keeps the heading it is under")
            XCTAssertFalse(chunk.body.hasPrefix(" "), "no chunk begins mid-sentence")
        }
        XCTAssertEqual(chunks.map(\.lineStart), chunks.map(\.lineStart).sorted(),
                       "the pieces are in file order")
        XCTAssertEqual(Set(chunks.map(\.lineStart)).count, chunks.count,
                       "no two pieces claim the same starting line")
    }

    /// One paragraph longer than the cap stays whole. The cap is a target; cutting inside
    /// a sentence is worse than an oversized chunk.
    ///
    /// It also pins the `minChunkCharacters` rule: the heading and the blank line after it
    /// are a paragraph boundary, so without that floor this note would be cut into "## Big"
    /// and the rest — a chunk that is nothing but a heading, which answers no question.
    func testASingleOversizedParagraphIsNotCutInHalf() {
        let giant = String(repeating: "brick ", count: VaultChunker.maxChunkCharacters / 3)
        let chunks = VaultChunker.parse(relativePath: "A.md", text: "## Big\n\n" + giant).chunks

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].body.hasPrefix("## Big"))
        XCTAssertGreaterThan(chunks[0].body.count, VaultChunker.maxChunkCharacters)
    }

    /// A section with nothing but blank lines in it is not a chunk. An index full of empty
    /// rows matches nothing and costs space.
    func testAnEmptySectionProducesNoChunk() {
        let parsed = VaultChunker.parse(relativePath: "A.md", text: "## Empty\n\n\n## Full\n\nx\n")
        XCTAssertEqual(parsed.chunks.map(\.heading), ["Empty", "Full"],
                       "a heading with no body is still the heading's own line, which is content")
        XCTAssertEqual(VaultChunker.parse(relativePath: "A.md", text: "\n\n\n").chunks.count, 0,
                       "a file of blank lines has nothing to index")
    }

    // MARK: - The title

    func testTheTitleComesFromFrontmatterFirst() {
        let note = "---\ntitle: The Kiln Rebuild\n---\n# Something else\n"
        XCTAssertEqual(VaultChunker.parse(relativePath: "Workshop/Kiln.md", text: note).title,
                       "The Kiln Rebuild")
    }

    func testTheTitleFallsBackToTheFirstLevelOneHeading() {
        XCTAssertEqual(VaultChunker.parse(relativePath: "Workshop/Kiln.md",
                                          text: "# Kiln notes\n\nBody.\n").title,
                       "Kiln notes")
    }

    func testTheTitleFallsBackToTheFileNameWithoutItsExtension() {
        XCTAssertEqual(VaultChunker.parse(relativePath: "Workshop/Kiln-Rebuild.md",
                                          text: "Just a body.\n").title,
                       "Kiln-Rebuild")
    }

    /// A quoted YAML title is one value, not a value with quotes in it.
    func testAQuotedFrontmatterTitleIsUnquoted() {
        let note = "---\ntitle: \"A Note\"\n---\nbody\n"
        XCTAssertEqual(VaultChunker.parse(relativePath: "A.md", text: note).title, "A Note")
    }

    /// An unclosed `---` is a horizontal rule, not frontmatter. Reading it as frontmatter
    /// would swallow the whole note as metadata.
    func testAnUnclosedFrontmatterFenceIsTreatedAsContent() {
        let parsed = VaultChunker.parse(relativePath: "A.md", text: "---\nnot metadata\n")
        XCTAssertEqual(parsed.frontmatterLineCount, 0)
        XCTAssertEqual(parsed.chunks.count, 1)
    }

    /// The note's links come out with it, so the index's `links` table is filled by the
    /// same pass that fills its chunks.
    func testParsingAlsoCollectsEveryWikiTarget() {
        let note = """
            # Kiln

            See [[Suppliers/Terrasole]] and [[People/Marta Ruggeri|Marta]].

            ## Again

            [[Suppliers/Terrasole]] once more, and [[Workshop/Overview#Benches]].
            """
        let parsed = VaultChunker.parse(relativePath: "A.md", text: note)

        XCTAssertEqual(parsed.linkTargets,
                       ["Suppliers/Terrasole", "People/Marta Ruggeri", "Workshop/Overview"],
                       "aliases and headings are dropped, duplicates collapse, order is kept")
    }
}
