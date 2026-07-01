import XCTest
@testable import Jesse

/// (M8) The streaming partial reply re-parsed the whole growing string on every
/// delta — O(n²) over a long stream. `MarkdownStreamRenderer` coalesces the parse
/// to ~10Hz. These inject a parse-call counter and assert that N deltas produce far
/// fewer than N parses while the final rendered blocks are identical to a full
/// parse.
@MainActor
final class MarkdownStreamRendererTests: XCTestCase {

    func testManyDeltasCoalesceIntoFarFewerParses() {
        var parseCount = 0
        let renderer = MarkdownStreamRenderer(interval: 0.1) { text in
            parseCount += 1
            return parseMarkdownBlocks(text)
        }

        let base = Date(timeIntervalSinceReferenceDate: 0)
        var full = ""
        let n = 100
        // 100 deltas arriving within a single 100ms window (1ms apart).
        for i in 0..<n {
            full += "word\(i) "
            _ = renderer.blocks(for: full, now: base.addingTimeInterval(Double(i) * 0.001))
        }
        // A tick past the interval renders whatever the current (full) text is.
        let finalBlocks = renderer.blocks(for: full, now: base.addingTimeInterval(0.2))

        XCTAssertLessThan(parseCount, 10,
                          "\(n) deltas must coalesce into far fewer than \(n) parses (got \(parseCount))")
        XCTAssertEqual(finalBlocks, parseMarkdownBlocks(full),
                       "the final rendered text is identical to a full parse")
    }

    func testUnchangedTextNeverReParses() {
        var parseCount = 0
        let renderer = MarkdownStreamRenderer(interval: 0.1) { text in
            parseCount += 1
            return parseMarkdownBlocks(text)
        }
        let base = Date(timeIntervalSinceReferenceDate: 0)
        _ = renderer.blocks(for: "hello", now: base)
        // Same text, even well past the interval → no second parse.
        _ = renderer.blocks(for: "hello", now: base.addingTimeInterval(1))
        _ = renderer.blocks(for: "hello", now: base.addingTimeInterval(2))
        XCTAssertEqual(parseCount, 1, "identical text is served from cache, never re-parsed")
    }

    func testTextChangesAcrossIntervalsEachReParse() {
        var parseCount = 0
        let renderer = MarkdownStreamRenderer(interval: 0.1) { text in
            parseCount += 1
            return parseMarkdownBlocks(text)
        }
        let base = Date(timeIntervalSinceReferenceDate: 0)
        // Three changes, each a full interval apart → three parses (the cadence cap
        // doesn't suppress genuinely-spaced updates).
        _ = renderer.blocks(for: "a", now: base)
        _ = renderer.blocks(for: "ab", now: base.addingTimeInterval(0.1))
        let last = renderer.blocks(for: "abc", now: base.addingTimeInterval(0.2))
        XCTAssertEqual(parseCount, 3)
        XCTAssertEqual(last, parseMarkdownBlocks("abc"))
    }
}
