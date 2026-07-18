import XCTest
@testable import Jesse

// The coach-notes HTML formatter: only <strong> becomes bold, the known entities
// decode, every other tag is stripped, and unknown markup passes through without
// crashing. Asserted on the tokenizer's `segments` seam (the AttributedString
// assembly is a thin wrapper over it).

@MainActor
final class CoachHTMLTests: XCTestCase {

    func testStrongBecomesBoldRun() {
        let segs = CoachHTML.segments("<strong>Great week</strong> keep going")
        XCTAssertEqual(segs, [
            .init(text: "Great week", bold: true),
            .init(text: " keep going", bold: false),
        ])
    }

    func testEntitiesDecode() {
        XCTAssertEqual(CoachHTML.plainText("down 1.5 &mdash; a new low"), "down 1.5 \u{2014} a new low")
        XCTAssertEqual(CoachHTML.plainText("it&rsquo;s good"), "it\u{2019}s good")
        XCTAssertEqual(CoachHTML.plainText("A &ndash; B"), "A \u{2013} B")
        XCTAssertEqual(CoachHTML.plainText("Tom &amp; Jerry"), "Tom & Jerry")
    }

    func testUnknownTagIsStripped() {
        // A tag we don't handle (<em>, <span>) is removed, its text kept.
        XCTAssertEqual(CoachHTML.plainText("a <em>b</em> <span class=\"x\">c</span> d"), "a b c d")
    }

    func testUnknownEntityPassesThroughLiterally() {
        // Not in the table → kept verbatim, never dropped.
        XCTAssertEqual(CoachHTML.plainText("100&percnt; effort"), "100&percnt; effort")
        // A bare ampersand with no terminating ; stays literal too.
        XCTAssertEqual(CoachHTML.plainText("a & b"), "a & b")
    }

    func testCombinedStrongAndEntities() {
        let segs = CoachHTML.segments("<strong>188.1 &mdash; down</strong> today")
        XCTAssertEqual(segs, [
            .init(text: "188.1 \u{2014} down", bold: true),
            .init(text: " today", bold: false),
        ])
    }

    func testAdjacentSameEmphasisCoalesces() {
        // <b> and <strong> both mean bold; a stripped tag between two bold spans
        // must not split them into separate runs of the same emphasis.
        let segs = CoachHTML.segments("<strong>one</strong><strong>two</strong>")
        XCTAssertEqual(segs, [.init(text: "onetwo", bold: true)])
    }

    func testUnterminatedTagIsTreatedLiterally() {
        // A stray '<' with no '>' must not swallow the rest of the string.
        XCTAssertEqual(CoachHTML.plainText("2 < 3 is true"), "2 < 3 is true")
    }

    func testPlainTextWithNoMarkup() {
        XCTAssertEqual(CoachHTML.plainText("just text"), "just text")
        XCTAssertEqual(CoachHTML.segments("just text"), [.init(text: "just text", bold: false)])
    }

    func testAttributedStringHasBoldIntentOnStrongRun() {
        let attr = CoachHTML.attributed("<strong>bold</strong> plain")
        // The bold run carries the strong inline presentation intent.
        var sawBold = false
        for run in attr.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            sawBold = true
            XCTAssertEqual(String(attr[run.range].characters), "bold")
        }
        XCTAssertTrue(sawBold, "the <strong> span must carry a bold intent")
    }
}
