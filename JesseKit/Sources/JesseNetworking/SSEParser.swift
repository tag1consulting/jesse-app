import Foundation

// The one SSE line→frame state machine, ported from the (identical) iOS and Mac pure
// parsers. Pure (no I/O): the client feeds it lines as `URLSession.AsyncBytes.lines`
// yields them and forwards each completed frame; tests feed hand-built line arrays via
// `framesFromLines`. Factored out so the framing — the spot the CHANGELOG's
// blank-line-swallowing bug lived — can be unit-tested directly.

public struct SSEParser: Sendable {
    private var eventName = ""
    private var dataBuf = ""

    public init() {}

    /// Feed one line; returns the frame it completes, if any.
    ///
    /// A blank line is a frame boundary. A new `event:` line ALSO flushes the previous
    /// frame, because `URLSession.AsyncBytes.lines` *swallows blank lines* — so the
    /// blank-line boundary often never arrives and the only reliable separator is the
    /// next `event:`. `:` lines are SSE comments (keep-alives) and are ignored.
    public mutating func consume(_ line: String) -> JesseStreamEvent? {
        if line.isEmpty { return flush() }          // frame boundary
        if line.hasPrefix(":") { return nil }       // keep-alive comment
        if let v = Self.field("event:", line) {
            // A new `event:` line flushes the previous frame — the boundary that
            // survives swallowed blank lines. Each bridge frame carries exactly one
            // `event:` line, so this is exact.
            let completed = eventName.isEmpty ? nil : flush()
            eventName = v
            return completed
        } else if let v = Self.field("data:", line) {
            dataBuf += v
        }
        return nil
    }

    /// Flush the final frame at end of input (no trailing blank line before EOF).
    public mutating func finish() -> JesseStreamEvent? { flush() }

    private mutating func flush() -> JesseStreamEvent? {
        defer { eventName = ""; dataBuf = "" }
        guard !eventName.isEmpty else { return nil }
        return Self.decodeStreamFrame(event: eventName, data: dataBuf)
    }

    /// Strip an SSE field prefix and its single optional leading space.
    static func field(_ prefix: String, _ line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
    }

    /// Decode one SSE frame (`event` name + JSON `data`) into a stream event. A
    /// malformed/empty `data` decodes to nil and falls back to the same defaults the
    /// old `obj?["…"] ?? …` casts used.
    public static func decodeStreamFrame(event: String, data: String) -> JesseStreamEvent? {
        let obj = try? JSONDecoder().decode(JesseStreamFrameData.self, from: Data(data.utf8))
        switch event {
        case "reset": return .reset(obj?.text ?? "")
        case "delta": return .delta(obj?.text ?? "")
        case "activity": return .activity(obj?.name ?? "")
        case "done":
            return .done(JesseReply(text: obj?.response ?? "", sessionId: obj?.sessionId,
                                    directives: obj?.directives, provenance: obj?.provenance))
        case "error": return .failed(obj?.error ?? "Jesse couldn't complete that.")
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Pure line→frame conversion over a whole sequence of SSE lines, for unit testing
    /// the framing over hand-built line arrays.
    public static func framesFromLines<S: Sequence<String>>(_ lines: S) -> [JesseStreamEvent] {
        var parser = SSEParser()
        var out: [JesseStreamEvent] = []
        for line in lines {
            if let ev = parser.consume(line) { out.append(ev) }
        }
        if let ev = parser.finish() { out.append(ev) }
        return out
    }
}
