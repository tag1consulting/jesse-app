import XCTest
@testable import JesseNetworking

/// Direct unit tests of the one SSE line→frame state machine — the code the CHANGELOG
/// says had a blank-line-swallowing bug. These feed hand-built line arrays so the framing
/// is exercised in isolation. Consolidated here from the (identical) former iOS
/// `SSEParserTests` and macOS `MacSSEParserTests`, which tested two duplicate parsers.
final class SSEParserTests: XCTestCase {

    private func delta(_ t: String) -> String { #"data: {"text":"\#(t)"}"# }

    /// Frames separated by blank lines (the textbook SSE shape).
    func testBlankLineSeparatedFrames() {
        let lines = [
            "event: delta", delta("a"), "",
            "event: delta", delta("b"), "",
        ]
        XCTAssertEqual(SSEParser.framesFromLines(lines), [.delta("a"), .delta("b")])
    }

    /// The regression guard: `URLSession.AsyncBytes.lines` swallows blank lines, so a real
    /// body arrives as back-to-back `event:`/`data:` lines with NO blank separators. A new
    /// `event:` line must still flush the previous frame, and the last frame must flush at
    /// EOF.
    func testEventLineFlushesWithoutTrailingBlank() {
        let lines = [
            "event: delta", delta("a"),
            "event: delta", delta("b"),   // no blank lines anywhere
        ]
        XCTAssertEqual(SSEParser.framesFromLines(lines), [.delta("a"), .delta("b")])
    }

    /// Partial / incremental delivery: feeding the stateful parser one line at a time
    /// yields a frame only when it's complete (on the next `event:` and at EOF).
    func testPartialIncrementalDelivery() {
        var p = SSEParser()
        XCTAssertNil(p.consume("event: delta"))
        XCTAssertNil(p.consume(delta("part1")))
        // The next event: line completes the first frame.
        XCTAssertEqual(p.consume("event: delta"), .delta("part1"))
        XCTAssertNil(p.consume(delta("part2")))
        // EOF flushes the last frame.
        XCTAssertEqual(p.finish(), .delta("part2"))
    }

    /// A reset → deltas → done sequence decodes end to end.
    func testResetThenDeltasThenDone() {
        let lines = [
            "event: reset", #"data: {"text":"Hel"}"#, "",
            "event: delta", #"data: {"text":"lo"}"#, "",
            "event: done", #"data: {"response":"Hello","session_id":"abc"}"#, "",
        ]
        XCTAssertEqual(SSEParser.framesFromLines(lines), [
            .reset("Hel"), .delta("lo"), .done(JesseReply(text: "Hello", sessionId: "abc")),
        ])
    }

    /// `:` keep-alive comment lines are ignored, and a terminal `done` frame decodes with
    /// its response + session id.
    func testKeepAliveCommentsIgnoredAndDoneDecodes() {
        let lines = [
            "event: delta", delta("a"), "",
            ":", ": keep-alive", "",
            "event: done", #"data: {"response":"hi","session_id":"s"}"#, "",
        ]
        XCTAssertEqual(SSEParser.framesFromLines(lines),
                       [.delta("a"), .done(JesseReply(text: "hi", sessionId: "s"))])
    }

    func testActivityAndError() {
        XCTAssertEqual(
            SSEParser.framesFromLines(["event: activity", #"data: {"name":"Read"}"#, ""]),
            [.activity("Read")])
        XCTAssertEqual(
            SSEParser.framesFromLines(["event: error", #"data: {"error":"boom"}"#, ""]),
            [.failed("boom")])
    }

    func testMissingDataFieldsFallBackToDefaults() {
        // A done frame with no response yields empty text, not a crash.
        XCTAssertEqual(
            SSEParser.framesFromLines(["event: done", "data: {}", ""]),
            [.done(JesseReply(text: "", sessionId: nil))])
    }

    // MARK: - decodeStreamFrame (SSE data payloads)

    func testDecodeStreamFrames() {
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "reset", data: #"{"text":"hi"}"#), .reset("hi"))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "delta", data: #"{"text":"x"}"#), .delta("x"))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "activity", data: #"{"name":"Read"}"#), .activity("Read"))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "done", data: #"{"response":"r","session_id":"s"}"#),
                       .done(JesseReply(text: "r", sessionId: "s")))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "error", data: #"{"error":"boom"}"#), .failed("boom"))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "cancelled", data: "{}"), .cancelled)
        XCTAssertNil(SSEParser.decodeStreamFrame(event: "mystery", data: "{}"))
    }

    /// A malformed/empty `data` falls back to the same defaults the old casts used.
    func testDecodeStreamFrameMalformedDataFallsBack() {
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "reset", data: "not json"), .reset(""))
        XCTAssertEqual(SSEParser.decodeStreamFrame(event: "error", data: ""),
                       .failed("Jesse couldn't complete that."))
    }
}
