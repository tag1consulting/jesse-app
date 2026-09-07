import Foundation

/// What a transcribed recording looks like as a MESSAGE.
///
/// The bridge never receives audio — the transcript is the whole deliverable — so the
/// text has to carry the small amount of provenance a listener would otherwise have had
/// for free. Three facts, one line: which file, how long it was, and which language it
/// was read in. The last of those is not decoration: a transcript is a lossy reading of
/// a recording, and knowing it was read as Italian is what makes an odd sentence
/// diagnosable rather than mysterious.
///
/// Typed text comes FIRST, ahead of the transcript. That is the opposite order from
/// `TodayThreadContext.firstMessage`, where a pinned item precedes the question, and the
/// difference is deliberate rather than an oversight: there the attached thing is the
/// SCOPE the question is asked within, while here it is the MATERIAL the user is
/// commenting on. "Here is what the plumber said, in Italian" reads correctly before its
/// hour of transcript and absurdly after it.
///
/// Pure string composition, so the exact bytes that reach the bridge are asserted in a
/// test rather than eyeballed in a screenshot.
public enum RecordingTranscript {
    /// A compact spoken-length string: `48s`, `3m 12s`, `1h 04m 12s`.
    ///
    /// Seconds are kept at every scale on purpose. This is a provenance stamp, not a
    /// progress read-out — "1h" would leave a reader unable to tell a recording from its
    /// truncated retry, and the extra four characters cost nothing.
    public static func durationText(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    /// The one-line provenance header that sits immediately above the transcript.
    public static func header(sourceName: String, seconds: Double, language: String) -> String {
        "Recording: “\(sourceName)” · \(durationText(seconds: seconds)) · \(language)"
    }

    /// The message body: whatever the user typed, then the header, then the transcript.
    ///
    /// An empty composer yields header-plus-transcript with no leading blank line, which
    /// is the common case — the user shares a memo and sends it as it stands.
    public static func messageBody(typed: String,
                                   sourceName: String,
                                   seconds: Double,
                                   language: String,
                                   transcript: String) -> String {
        let preamble = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = header(sourceName: sourceName, seconds: seconds, language: language)
        let block = body.isEmpty ? stamp : "\(stamp)\n\n\(body)"
        return preamble.isEmpty ? block : "\(preamble)\n\n\(block)"
    }
}
