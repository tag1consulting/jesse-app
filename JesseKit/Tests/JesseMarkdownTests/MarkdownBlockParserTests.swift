import XCTest
@testable import JesseMarkdown

// THE BLOCK GRAMMAR, CONSTRUCT BY CONSTRUCT, over invented fixtures only: this repository
// is public and no line of a real note belongs in it.
//
// The last test in the file is the one that would catch a regression nobody thought to
// look for. Everything above it says "this construct parses the way it should"; the fuzz
// says "and whatever else you throw at it, no line disappears", which is the promise a
// reader actually depends on.
final class MarkdownBlockParserTests: XCTestCase {

    func parse(_ note: String, firstLine: Int = 1) -> [MarkdownSourceBlock] {
        MarkdownBlockParser.parse(
            lines: note.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            firstLine: firstLine)
    }

    // MARK: - Paragraphs

    /// THE HEADLINE FIX. A soft-wrapped paragraph is one paragraph, not a stack of short
    /// lines, which is how every real note in the vault is written.
    func testSoftWrappedLinesJoinIntoOneParagraph() {
        let blocks = parse("""
            The floor cracked along the back seam
            and the crack runs further
            than it did in the spring.
            """)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].text,
                       "The floor cracked along the back seam and the crack runs further than it did in the spring.")
    }

    func testABlankLineSeparatesTwoParagraphs() {
        let blocks = parse("First.\n\nSecond.")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["First.", "Second."])
    }

    /// Two trailing spaces, or a trailing backslash, is markdown for "break here" — the one
    /// way a writer can shape a paragraph, and it survives the join.
    func testATrailingDoubleSpaceOrBackslashForcesABreakInsideTheBlock() {
        XCTAssertEqual(parse("one  \ntwo")[0].text, "one\ntwo")
        XCTAssertEqual(parse("one\\\ntwo")[0].text, "one\ntwo")
        XCTAssertEqual(parse("one\ntwo")[0].text, "one two")
    }

    // MARK: - Headings

    func testHeadingsAtEveryLevel() {
        let blocks = parse("# a\n\n## b\n\n### c\n\n#### d\n\n##### e\n\n###### f")
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .heading(level: 4), .heading(level: 5), .heading(level: 6),
        ])
        XCTAssertEqual(blocks.map(\.text), ["a", "b", "c", "d", "e", "f"])
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertEqual(parse("####### deep").map(\.kind), [.paragraph])
    }

    func testAHashWithNoSpaceIsNotAHeading() {
        XCTAssertEqual(parse("#pottery").map(\.kind), [.paragraph])
    }

    // MARK: - Lists

    func testBulletsCarryTheirDepth() {
        let blocks = parse("- top\n\t- one in\n\t\t- two in\n    - also one in")
        XCTAssertEqual(blocks.map(\.kind), [
            .bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 2), .bullet(depth: 2),
        ])
    }

    func testEveryBulletMarker() {
        XCTAssertEqual(parse("- a\n* b\n+ c").map(\.kind),
                       [.bullet(depth: 0), .bullet(depth: 0), .bullet(depth: 0)])
    }

    /// A list written `1. 1. 1.` means "a numbered list", not "three items all numbered
    /// one" — markdown's own convention, and Obsidian renders it the same way.
    func testALazyNumberedListCountsUp() {
        XCTAssertEqual(parse("1. strip it back\n1. wet it down\n1. pour in two lifts").map(\.kind),
                       [.ordered(depth: 0, number: 1),
                        .ordered(depth: 0, number: 2),
                        .ordered(depth: 0, number: 3)])
    }

    /// A writer who numbered their own items meant those numbers, and renumbering them
    /// from one would be the reader overruling them.
    func testASelfNumberedListKeepsItsNumbers() {
        XCTAssertEqual(parse("3. third\n7. seventh\n9. ninth").map(\.kind),
                       [.ordered(depth: 0, number: 3),
                        .ordered(depth: 0, number: 7),
                        .ordered(depth: 0, number: 9)])
    }

    func testALazyListStartingAtFourCountsUpFromFour() {
        XCTAssertEqual(parse("4. a\n4. b").map(\.kind),
                       [.ordered(depth: 0, number: 4), .ordered(depth: 0, number: 5)])
    }

    func testDisplayNumbersDirectly() {
        XCTAssertEqual(MarkdownBlockParser.displayNumbers([1, 1, 1]), [1, 2, 3])
        XCTAssertEqual(MarkdownBlockParser.displayNumbers([3, 7, 9]), [3, 7, 9])
        XCTAssertEqual(MarkdownBlockParser.displayNumbers([2]), [2])
        XCTAssertEqual(MarkdownBlockParser.displayNumbers([]), [])
    }

    /// An indented line that is not an item belongs to the item above it — that is what
    /// the indent was for.
    func testAContinuationLineJoinsItsItem() {
        let blocks = parse("- soft brick, grade 26\n  from the yard\n- castable")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "soft brick, grade 26 from the yard")
        XCTAssertEqual(blocks[1].text, "castable")
    }

    // MARK: - Quotes and callouts

    func testAMultiLineQuoteIsOneQuote() {
        let blocks = parse("> the yard is closed\n> for the whole of August")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .quote)
        XCTAssertEqual(blocks[0].text, "the yard is closed for the whole of August")
    }

    /// A nested quote FLATTENS with its text kept. A reader gains nothing from four nested
    /// bars and loses the sentence inside them if the nesting is drawn wrong.
    func testANestedQuoteFlattensAndKeepsItsText() {
        let blocks = parse("> outer\n>> inner")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .quote)
        XCTAssertEqual(blocks[0].text, "outer inner")
    }

    func testACalloutCarriesItsTypeTitleAndBody() {
        let blocks = parse("> [!warning] Mind the arch\n> it has not been measured cold")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .callout(type: "warning", title: "Mind the arch"))
        XCTAssertEqual(blocks[0].text, "it has not been measured cold")
    }

    /// No title written, so the type is the title — capitalised, because "note" as a
    /// heading reads like a mistake.
    func testACalloutWithNoTitleUsesItsTypeCapitalised() {
        XCTAssertEqual(parse("> [!note]\n> the pallet is in the yard")[0].kind,
                       .callout(type: "note", title: "Note"))
    }

    func testACalloutTypeIsLowercasedAndAFoldMarkerIsConsumed() {
        XCTAssertEqual(parse("> [!TIP]+ Wet it down")[0].kind,
                       .callout(type: "tip", title: "Wet it down"))
        XCTAssertEqual(parse("> [!tip]- Wet it down")[0].kind,
                       .callout(type: "tip", title: "Wet it down"))
    }

    /// An unfamiliar type is still a callout. A vault grows its own notation, and a
    /// callout that vanished because its type was unfamiliar would be content lost to a
    /// spelling.
    func testAnUnknownCalloutTypeIsStillACallout() {
        XCTAssertEqual(parse("> [!kiln] Firing 4")[0].kind,
                       .callout(type: "kiln", title: "Firing 4"))
    }

    func testABracketThatIsNotACalloutMarkerLeavesAnOrdinaryQuote() {
        XCTAssertEqual(parse("> [not a callout] and text")[0].kind, .quote)
    }

    // MARK: - Code

    /// ONE BLOCK PER FENCE, not one per line — which is what the line-per-block model did,
    /// and why a code block used to be a stack of separately-boxed lines.
    func testAFenceIsOneBlockWithItsLanguageAndItsIndentation() {
        let blocks = parse("```swift\nlet ramp = 60\n    .capped()\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[0].text, "let ramp = 60\n    .capped()")
    }

    func testAFenceWithNoLanguage() {
        XCTAssertEqual(parse("```\nfire schedule\n```")[0].kind, .code(language: ""))
    }

    /// An unclosed fence runs to the end of the note. Every line is still THERE, drawn as
    /// code — the alternative is a note that ends early and does not say so.
    func testAnUnclosedFenceRunsToTheEnd() {
        let blocks = parse("```\nfire schedule\nstill code")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "fire schedule\nstill code")
    }

    /// A blank line inside a fence is part of the code, not a paragraph break.
    func testABlankLineInsideAFenceStaysInTheCode() {
        XCTAssertEqual(parse("```\na\n\nb\n```")[0].text, "a\n\nb")
    }

    func testTildeFencesWorkToo() {
        XCTAssertEqual(parse("~~~\nx\n~~~")[0].kind, .code(language: ""))
    }

    // MARK: - Rules

    func testARuleIsThreeOrMoreOfOneMarker() {
        XCTAssertEqual(parse("---").map(\.kind), [.rule])
        XCTAssertEqual(parse("***").map(\.kind), [.rule])
        XCTAssertEqual(parse("___").map(\.kind), [.rule])
        XCTAssertEqual(parse("- - -").map(\.kind), [.rule])
        XCTAssertEqual(parse("--").map(\.kind), [.paragraph], "two is not a rule")
    }

    // MARK: - Tables

    func testATableCarriesItsHeadersRowsAndAlignments() {
        let blocks = parse("""
            | Cone | Ramp |
            |:--|--:|
            | 6 | 60 C/h |
            | 10 | 80 C/h |
            """)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .table(headers: ["Cone", "Ramp"],
                                              rows: [["6", "60 C/h"], ["10", "80 C/h"]],
                                              alignments: [.leading, .trailing]))
    }

    /// Cells keep their inline markdown; the renderer, not the parser, decides what bold
    /// looks like.
    func testCellsKeepTheirInlineMarkdown() {
        let blocks = parse("| A |\n|---|\n| see **[[Firings/Log 4]]** |")
        guard case .table(_, let rows, _) = blocks[0].kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(rows, [["see **[[Firings/Log 4]]**"]])
    }

    /// A RAGGED ROW IS PADDED, NEVER DROPPED — in either direction. A short row gains
    /// empty cells; a row with an extra cell makes the whole table one column wider,
    /// because that extra cell is something somebody typed.
    func testARaggedRowIsPaddedInBothDirections() {
        let blocks = parse("""
            | A | B | C |
            | --- | --- | --- |
            | only-one |
            | w | x | y | z |
            """)
        XCTAssertEqual(blocks[0].kind, .table(
            headers: ["A", "B", "C", ""],
            rows: [["only-one", "", "", ""], ["w", "x", "y", "z"]],
            alignments: [.leading, .leading, .leading, .leading]))
    }

    func testProseWithAPipeIsNotATable() {
        XCTAssertEqual(parse("use a | b to pipe").map(\.kind), [.paragraph])
    }

    // MARK: - Images

    func testAnImageOnItsOwnLineIsAnImageBlock() {
        XCTAssertEqual(parse("![the arch](Attachments/arch.png)").map(\.kind),
                       [.image(alt: "the arch", target: "Attachments/arch.png")])
    }

    func testAnImageInsideASentenceStaysInTheParagraph() {
        XCTAssertEqual(parse("see ![the arch](arch.png) here").map(\.kind), [.paragraph])
    }

    // MARK: - Lines

    func testEveryBlockKnowsTheLineItStartsAt() {
        let blocks = parse("# One\n\nTwo\nstill two\n\n> quoted", firstLine: 1)
        XCTAssertEqual(blocks.map(\.line), [1, 3, 6])
    }

    func testFirstLineOffsetsEveryBlock() {
        XCTAssertEqual(parse("# One", firstLine: 5).map(\.line), [5])
    }

    // MARK: - Nothing is dropped, ever

    /// Every non-blank source line's words end up SOMEWHERE — in a block's text, a table
    /// cell, or a code body — in source order.
    ///
    /// Run over a fuzz of random mixes of the fixture lines below, because the shapes that
    /// break a parser are the ones nobody would think to write down: a delimiter row with
    /// no header above it, a fence opened inside a list, a callout marker in the middle of
    /// a table. A deterministic seed, so a failure is a failure anybody can reproduce.
    func testNoLineIsEverDropped() {
        var generator = SplitMix64(seed: 0x5EED_1EAF)
        for iteration in 0..<200 {
            let count = 4 + Int(generator.next() % 24)
            let lines = (0..<count).map { _ in
                Self.fixtureLines[Int(generator.next() % UInt64(Self.fixtureLines.count))]
            }
            let blocks = MarkdownBlockParser.parse(lines: lines)
            assertNothingDropped(lines: lines, blocks: blocks, iteration: iteration)
        }
    }

    func testNoLineIsDroppedFromTheWholeFixtureInOrder() {
        assertNothingDropped(lines: Self.fixtureLines,
                             blocks: MarkdownBlockParser.parse(lines: Self.fixtureLines),
                             iteration: -1)
    }

    /// Every meaningful token of every non-blank line, found in order in what the blocks
    /// actually carry.
    func assertNothingDropped(lines: [String], blocks: [MarkdownSourceBlock],
                              iteration: Int) {
        var corpus: [String] = []
        for block in blocks {
            switch block.kind {
            case .table(let headers, let rows, _):
                corpus += headers + rows.flatMap { $0 }
            case .callout(let type, let title):
                // A callout's marker becomes its TYPE and its first line's remainder
                // becomes its TITLE, so both are content that left `text`.
                corpus += [type, title, block.text]
            case .code(let language):
                corpus += [language, block.text]
            case .image(let alt, let target):
                corpus += [alt, target]
            default:
                corpus.append(block.text)
            }
        }
        var haystack = Self.tokens(corpus.joined(separator: " "))[...]

        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            for token in Self.tokens(line) {
                guard let hit = haystack.firstIndex(of: token) else {
                    return XCTFail("""
                        iteration \(iteration): the token "\(token)" from the line \
                        "\(line)" is in no block.
                        lines: \(lines)
                        blocks: \(blocks)
                        """)
                }
                haystack = haystack[haystack.index(after: hit)...]
            }
        }
    }

    /// The words of a string, with every piece of markdown PUNCTUATION flattened to
    /// whitespace.
    ///
    /// The same function is applied to the source lines and to what the blocks carry, and
    /// that symmetry is the whole trick: the parser is entitled to turn `> [!warning] x`
    /// into a type and a title, `- [x] y` into a glyph and a text, and a fence's
    /// ```` ```swift ```` into a language — and after this flattening all three read as
    /// the same words on both sides. What it cannot do, and what this catches, is lose a
    /// word.
    ///
    /// Purely numeric tokens are dropped, because a list's number is STRUCTURE: a list
    /// written `1. 1. 1.` renders `1. 2. 3.`, so the digits on the two sides legitimately
    /// differ. Every table cell's numbers are covered by the table tests directly.
    static func tokens(_ s: String) -> [String] {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "/" ? $0 : " " })
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in !token.allSatisfy(\.isNumber) }
    }

    /// Every construct the vault writes, as separate lines the fuzz can shuffle. Invented
    /// content: a pottery workshop that does not exist.
    static let fixtureLines: [String] = [
        "# Firing 4",
        "## Materials",
        "###### Cost",
        "",
        "The floor cracked along the back seam.",
        "and the crack runs further than it did.",
        "a line that ends in a break  ",
        "a line that ends in a backslash\\",
        "- soft brick, grade 26",
        "\t- the pallet is in the yard",
        "\t\t- forty two of them",
        "  a continuation of the item above",
        "- [ ] order the anchors",
        "- [x] measure the arch",
        "- [/] an unusual mark",
        "1. strip it back",
        "1. wet it down",
        "7. pour in two lifts",
        "> the yard is closed in August",
        "> [!warning] Mind the arch",
        "> [!note]",
        ">> a nested quote",
        "```swift",
        "let ramp = 60",
        "```",
        "~~~",
        "---",
        "***",
        "| Cone | Ramp | Hold |",
        "|:--|--:|:-:|",
        "| 6 | 60 C/h | 20 min |",
        "| only-one |",
        "| w | x | y | z |",
        "![the arch](Attachments/arch.png)",
        "see ![inline](x.png) here",
        "a ==highlight== and a #tag",
        "a [[wiki link]] and a [[target|alias]]",
        "an ![[embed]] of another note",
        "a `code span with [[brackets]]`",
        "see https://example.invalid/castable",
        "order the anchors (@2026-09-30)",
    ]
}

/// A tiny deterministic generator, so a fuzz failure is a failure anybody can reproduce.
/// `SystemRandomNumberGenerator` would make this test fail on someone else's machine and
/// nowhere else, which is the worst possible property for a fuzz test to have.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
