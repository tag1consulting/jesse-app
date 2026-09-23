import XCTest
@testable import JesseMarkdown

// THE INLINE SCANNER, ONE CONSTRUCT AT A TIME.
//
// Every one of these is a pure function over a string, which is the whole reason the
// reader's inline behaviour can be argued about in a test rather than in a screenshot.
//
// The test that matters most is the code-span one. `` `[[not a link]]` `` is a code span
// containing four bracket characters somebody typed on purpose, and a scanner that made it
// a link would be breaking the one construct whose entire job is "show this exactly as I
// wrote it".
final class MarkdownInlineScanTests: XCTestCase {

    // MARK: - The fast path

    func testAPlainLineIsOneSpanAndNeverScanned() {
        XCTAssertFalse(MarkdownInline.mayContainSpans("the floor cracked along the seam"))
        XCTAssertEqual(MarkdownInline.scan("the floor cracked along the seam"),
                       [.text("the floor cracked along the seam")])
    }

    func testAnEmptyLineIsNoSpansAtAll() {
        XCTAssertEqual(MarkdownInline.scan(""), [])
    }

    func testTheFastPathLetsThroughEveryConstructItMustNotMiss() {
        for line in ["a [[link]]", "a ==mark==", "a #tag", "a `span`", "see https://x.invalid"] {
            XCTAssertTrue(MarkdownInline.mayContainSpans(line), line)
        }
    }

    // MARK: - Wiki links and embeds

    func testAWikiLinkIsItsOwnSpanAndKeepsItsInnerTextRaw() {
        XCTAssertEqual(MarkdownInline.scan("Ask [[People/Marta Ruggeri|burner]] today."), [
            .text("Ask "),
            .wikiLink(inner: "People/Marta Ruggeri|burner"),
            .text(" today."),
        ])
    }

    func testAnEmbedIsAWikiLinkWithAnExclamationBeforeIt() {
        XCTAssertEqual(MarkdownInline.scan("![[Firings/Log 4]]"),
                       [.embed(inner: "Firings/Log 4")])
    }

    func testAnUnclosedWikiLinkIsText() {
        XCTAssertEqual(MarkdownInline.scan("before [[ after"), [.text("before [[ after")])
    }

    // MARK: - Code spans are opaque

    /// THE RULE THE WHOLE SCANNER IS ORDERED AROUND.
    func testADoubleBracketInsideACodeSpanIsNotALink() {
        XCTAssertEqual(MarkdownInline.scan("write `[[Projects/X]]` to link"), [
            .text("write "),
            .codeSpan("`[[Projects/X]]`"),
            .text(" to link"),
        ])
    }

    func testAHighlightAndATagInsideACodeSpanAreAlsoInert() {
        XCTAssertEqual(MarkdownInline.scan("`==x== #tag`"), [.codeSpan("`==x== #tag`")])
    }

    /// CommonMark's rule: a run of N backticks is closed by the next run of exactly N,
    /// which is what makes ``` `` a ` b `` ``` work.
    func testADoubleBacktickSpanMayContainASingleBacktick() {
        XCTAssertEqual(MarkdownInline.scan("`` a ` b ``"), [.codeSpan("`` a ` b ``")])
    }

    func testAnUnclosedCodeSpanIsText() {
        XCTAssertEqual(MarkdownInline.scan("a ` b"), [.text("a ` b")])
    }

    // MARK: - Highlights

    func testAHighlightLosesItsMarkers() {
        XCTAssertEqual(MarkdownInline.scan("the ==back seam== again"), [
            .text("the "),
            .highlight("back seam"),
            .text(" again"),
        ])
    }

    func testAnEmptyOrUnclosedHighlightIsText() {
        XCTAssertEqual(MarkdownInline.scan("===="), [.text("====")])
        XCTAssertEqual(MarkdownInline.scan("a ==b"), [.text("a ==b")])
    }

    // MARK: - Tags

    func testATagIsAWordAfterWhitespaceOrALineStart() {
        XCTAssertEqual(MarkdownInline.scan("#pottery and #kiln/repair"), [
            .tag("#pottery"),
            .text(" and "),
            .tag("#kiln/repair"),
        ])
    }

    /// An issue number is not a tag, and neither is a C# in a sentence. Both of these are
    /// things this repository's own notes contain.
    func testANumberOrAMidWordHashIsNotATag() {
        XCTAssertEqual(MarkdownInline.scan("the trap PR #33 paid for"),
                       [.text("the trap PR #33 paid for")])
        XCTAssertEqual(MarkdownInline.scan("written in C# once"),
                       [.text("written in C# once")])
        XCTAssertEqual(MarkdownInline.scan("# "), [.text("# ")])
    }

    // MARK: - Bare URLs

    func testABareUrlBecomesItsOwnSpan() {
        XCTAssertEqual(MarkdownInline.scan("see https://example.invalid/x now"), [
            .text("see "),
            .autoLink("https://example.invalid/x"),
            .text(" now"),
        ])
    }

    /// The full stop that ends the sentence is not part of the address.
    func testTrailingSentencePunctuationStaysOutOfTheUrl() {
        XCTAssertEqual(MarkdownInline.scan("see http://example.invalid/a."), [
            .text("see "),
            .autoLink("http://example.invalid/a"),
            .text("."),
        ])
    }

    /// THE BUG THE EVERY-CONSTRUCT SCREENSHOT CAUGHT. An ordinary markdown link's target
    /// sits inside parentheses, and treating it as a bare URL cuts the link in half before
    /// `AttributedString(markdown:)` ever sees it — so the reader drew the brackets and the
    /// parentheses as literal text.
    func testAMarkdownLinksTargetIsNotABareUrl() {
        XCTAssertEqual(MarkdownInline.scan("a [markdown link](https://example.invalid/x) here"),
                       [.text("a [markdown link](https://example.invalid/x) here")])
    }

    func testAUrlInParenthesesIsAlsoLeftWhole() {
        XCTAssertEqual(MarkdownInline.scan("(https://example.invalid/x)"),
                       [.text("(https://example.invalid/x)")])
    }

    // MARK: - Images

    func testAnInlineImageIsItsOwnSpan() {
        XCTAssertEqual(MarkdownInline.scan("before ![the arch](arch.png) after"), [
            .text("before "),
            .image(alt: "the arch", target: "arch.png"),
            .text(" after"),
        ])
    }

    func testAHalfWrittenImageIsText() {
        XCTAssertEqual(MarkdownInline.scan("![the arch"), [.text("![the arch")])
        XCTAssertEqual(MarkdownInline.scan("![alt] (x.png)"), [.text("![alt] (x.png)")])
    }

    // MARK: - A reminder date is left alone

    /// `(@2026-09-30)` is obsidian-reminder syntax this vault uses everywhere. It contains
    /// no construct, and the scanner must not invent one.
    func testAReminderDateIsPlainText() {
        XCTAssertEqual(MarkdownInline.scan("order the anchors (@2026-09-30)"),
                       [.text("order the anchors (@2026-09-30)")])
    }
}
