import XCTest
@testable import Jesse

// Pure tests for `searchSnippet(for:queries:)` — the windowed, highlighted excerpt
// shown on a row while a search is active. No UI: the snippet is a plain value
// (text + highlight ranges), asserted directly.
final class SearchSnippetTests: XCTestCase {

    private func thread(title: String, turns: [(TurnRole, String)]) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        return t
    }

    /// The highlighted substrings of a snippet, for readable assertions.
    private func highlights(_ s: SearchSnippet) -> [String] {
        s.ranges.map { String(s.text[$0]) }
    }

    func testEmptyOrBlankQueryListReturnsNil() {
        let t = thread(title: "Roof", turns: [(.user, "the roofer comes Thursday")])
        XCTAssertNil(searchSnippet(for: t, queries: []))
        XCTAssertNil(searchSnippet(for: t, queries: ["", "   "]))
    }

    func testWindowCentersOnFirstMatchWithHighlightRange() {
        let t = thread(title: "Notes", turns: [
            (.user, "we talked about the quarterly budget review meeting next week"),
        ])
        let snippet = searchSnippet(for: t, queries: ["budget"])
        let s = try! XCTUnwrap(snippet)
        XCTAssertTrue(s.text.localizedCaseInsensitiveContains("budget"))
        // The matched token is highlighted, case-preserved from the source.
        XCTAssertEqual(highlights(s), ["budget"])
        // Every highlight range indexes into the snippet text.
        for r in s.ranges {
            XCTAssertTrue(r.lowerBound >= s.text.startIndex && r.upperBound <= s.text.endIndex)
        }
    }

    func testTitleSourcePreferredWhenTitleMatches() {
        // "roof" matches the title; the snippet is sourced from the title.
        let t = thread(title: "Roof repair schedule", turns: [
            (.jesse, "the roofer comes Thursday morning"),
        ])
        let s = try! XCTUnwrap(searchSnippet(for: t, queries: ["roof"]))
        XCTAssertTrue(s.text.contains("Roof"), "title is the snippet source when it matches")
        XCTAssertEqual(highlights(s).map { $0.lowercased() }, ["roof"])
    }

    func testBodySourceWhenOnlyBodyMatches() {
        let t = thread(title: "Roof repair", turns: [
            (.jesse, "the roofer is scheduled for Thursday morning at nine"),
        ])
        // "Thursday" is only in the body → snippet sourced from the body.
        let s = try! XCTUnwrap(searchSnippet(for: t, queries: ["thursday"]))
        XCTAssertTrue(s.text.localizedCaseInsensitiveContains("thursday"))
        XCTAssertFalse(s.text.contains("Roof repair"))
    }

    /// A row surfaced ONLY by an expansion term gets a snippet that highlights that
    /// expansion term — not the typed query (which doesn't appear). This is what
    /// makes an expansion result explain itself.
    func testHighlightsExpansionTermNotTypedQuery() {
        let t = thread(title: "Trip", turns: [
            (.user, "planning a holiday in Sicily this summer"),
        ])
        // Typed "vacation" (absent) + expansion "holiday" (present).
        let s = try! XCTUnwrap(searchSnippet(for: t, queries: ["vacation", "holiday"]))
        XCTAssertEqual(highlights(s).map { $0.lowercased() }, ["holiday"],
                       "the expansion term that actually matched is highlighted")
    }

    func testMatchAtStartEllipsizesOnlyTheEnd() {
        let t = thread(title: "", turns: [
            (.user, "budget planning for the next several fiscal quarters ahead"),
        ])
        let s = try! XCTUnwrap(searchSnippet(for: t, queries: ["budget"]))
        XCTAssertFalse(s.text.hasPrefix("…"), "a match at the very start has no leading ellipsis")
        XCTAssertTrue(s.text.hasSuffix("…"), "the far end is elided")
        XCTAssertEqual(highlights(s), ["budget"])
    }

    func testMatchAtEndEllipsizesOnlyTheStart() {
        let t = thread(title: "", turns: [
            (.user, "the whole point of this long note was the final word budget"),
        ])
        let s = try! XCTUnwrap(searchSnippet(for: t, queries: ["budget"]))
        XCTAssertTrue(s.text.hasPrefix("…"), "the leading context is elided")
        XCTAssertFalse(s.text.hasSuffix("…"), "a match at the very end has no trailing ellipsis")
        XCTAssertEqual(highlights(s), ["budget"])
    }

    func testShortTextNoMatchReturnsNil() {
        let t = thread(title: "Hi", turns: [(.user, "hello")])
        XCTAssertNil(searchSnippet(for: t, queries: ["budget"]))
    }
}
