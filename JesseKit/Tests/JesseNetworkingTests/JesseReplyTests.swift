import XCTest
@testable import JesseNetworking

/// The reply's display/spoken text derivation (SPOKEN: line handling). Moved here from the
/// iOS target with `JesseReply`.
final class JesseReplyTests: XCTestCase {

    private func reply(_ text: String) -> JesseReply {
        JesseReply(text: text, sessionId: nil)
    }

    func testDisplayTextStripsSpokenLine() {
        let r = reply("Answer line one\nAnswer line two\nSPOKEN: a spoken summary")
        XCTAssertEqual(r.displayText, "Answer line one\nAnswer line two")
    }

    func testSpokenTextReturnsSpokenContent() {
        let r = reply("Full answer here.\nSPOKEN: read this aloud")
        XCTAssertEqual(r.spokenText, "read this aloud")
    }

    func testSpokenMarkerIsCaseInsensitive() {
        let r = reply("Full answer.\nspoken: lower-case marker")
        XCTAssertEqual(r.spokenText, "lower-case marker")
        // The lower-case marker line is still stripped from the display text.
        XCTAssertEqual(r.displayText, "Full answer.")
    }

    func testSpokenFallbackShortAnswer() {
        let r = reply("Just a short answer.")
        XCTAssertEqual(r.spokenText, "Just a short answer.")
    }

    func testSpokenFallbackTruncatesTo240() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(reply(long).spokenText.count, 240)
    }

    func testMultiLineDisplayPreservesNonSpokenLines() {
        let r = reply("Line 1\nLine 2\nLine 3\nSPOKEN: summary")
        XCTAssertEqual(r.displayText, "Line 1\nLine 2\nLine 3")
        XCTAssertEqual(r.spokenText, "summary")
    }

    func testNoSpokenLineDisplayUnchanged() {
        let r = reply("Line A\nLine B")
        XCTAssertEqual(r.displayText, "Line A\nLine B")
    }
}
