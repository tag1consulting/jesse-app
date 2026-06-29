import XCTest
@testable import Jesse

/// (H4-app) Direct unit tests of the SSE line→frame state machine — the code the
/// CHANGELOG says had a blank-line-swallowing bug, previously covered only by a
/// single end-to-end test that delivered the whole body as one chunk. These feed
/// hand-built line arrays so the framing is exercised in isolation.
final class SSEParserTests: XCTestCase {

    private func delta(_ t: String) -> String { #"data: {"text":"\#(t)"}"# }

    /// Frames separated by blank lines (the textbook SSE shape).
    func testBlankLineSeparatedFrames() {
        let lines = [
            "event: delta", delta("a"), "",
            "event: delta", delta("b"), "",
        ]
        XCTAssertEqual(JesseClient.framesFromLines(lines), [.delta("a"), .delta("b")])
    }

    /// The regression guard: `URLSession.AsyncBytes.lines` swallows blank lines, so
    /// a real body arrives as back-to-back `event:`/`data:` lines with NO blank
    /// separators. A new `event:` line must still flush the previous frame, and the
    /// last frame must flush at EOF. This case FAILS if the blank-line handling
    /// regresses to relying on the (absent) blank-line boundary.
    func testEventLineFlushesWithoutTrailingBlank() {
        let lines = [
            "event: delta", delta("a"),
            "event: delta", delta("b"),   // no blank lines anywhere
        ]
        XCTAssertEqual(JesseClient.framesFromLines(lines), [.delta("a"), .delta("b")])
    }

    /// Partial / incremental delivery: feeding the stateful parser one line at a
    /// time yields a frame only when it's complete (on the next `event:` and at EOF).
    func testPartialIncrementalDelivery() {
        var p = JesseClient.SSEParser()
        XCTAssertNil(p.consume("event: delta"))
        XCTAssertNil(p.consume(delta("part1")))
        // The next event: line completes the first frame.
        XCTAssertEqual(p.consume("event: delta"), .delta("part1"))
        XCTAssertNil(p.consume(delta("part2")))
        // EOF flushes the last frame.
        XCTAssertEqual(p.finish(), .delta("part2"))
    }

    /// `:` keep-alive comment lines are ignored, and a terminal `done` frame decodes
    /// with its response + session id.
    func testKeepAliveCommentsIgnoredAndDoneDecodes() {
        let lines = [
            "event: delta", delta("a"), "",
            ":", ": keep-alive", "",
            "event: done", #"data: {"response":"hi","session_id":"s"}"#, "",
        ]
        XCTAssertEqual(JesseClient.framesFromLines(lines),
                       [.delta("a"), .done(JesseReply(text: "hi", sessionId: "s"))])
    }
}
