import Foundation

/// What a transcribed recording looks like as a MESSAGE.
///
/// The transcript is the whole deliverable — the audio is deleted on the Studio and here
/// once the text exists — so the text has to carry the provenance a listener would
/// otherwise have had for free. One line: which file, how long it was, which language it
/// was read in, and WHERE it was transcribed. The last two are not decoration: a transcript
/// is a lossy reading of a recording, and knowing it was read as Italian, by the Studio's
/// large model or by this phone's small one, is what makes an odd sentence diagnosable
/// rather than mysterious.
///
/// When two engines read it, the places they disagreed follow the transcript as their own
/// block, so whoever reads the message next — a person, or the model it is sent to — can
/// resolve a date or a name the way a listener would, and can say when it cannot. The
/// transcript itself is never edited by that block: it keeps the primary reading.
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

    /// A position in the recording, as a player shows it: `3:12`, `1:04:12`.
    public static func timestamp(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The one-line provenance header that sits immediately above the transcript.
    public static func header(sourceName: String, seconds: Double, language: String,
                              engine: String? = nil) -> String {
        let stamp = "Recording: “\(sourceName)” · \(durationText(seconds: seconds)) · \(language)"
        guard let engine, !engine.isEmpty else { return stamp }
        return "\(stamp) · transcribed on \(engine)"
    }

    /// The block that follows the transcript when the reading is uncertain anywhere: the
    /// disagreements, each with where to find it, then any notes. Nil when there is none.
    public static func uncertaintyBlock(disagreements: [TranscriptDisagreement],
                                        notes: [String]) -> String? {
        var parts: [String] = []
        if !disagreements.isEmpty {
            let lines = disagreements.map { d -> String in
                let other = d.alternative.isEmpty ? "nothing" : "“\(d.alternative)”"
                return "[\(timestamp(seconds: d.startSeconds))] “\(d.primary)” — or \(other)"
            }
            parts.append((["Uncertain passages — two engines heard these differently; the transcript above follows the first reading:"] + lines)
                .joined(separator: "\n"))
        }
        let kept = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !kept.isEmpty {
            parts.append((["Transcription notes:"] + kept.map { "- \($0)" }).joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The message body: whatever the user typed, then the header, then the transcript,
    /// then — only when there is one — the uncertainty block.
    ///
    /// An empty composer yields header-plus-transcript with no leading blank line, which
    /// is the common case — the user shares a memo and sends it as it stands.
    public static func messageBody(typed: String,
                                   sourceName: String,
                                   seconds: Double,
                                   language: String,
                                   transcript: String,
                                   engine: String? = nil,
                                   disagreements: [TranscriptDisagreement] = [],
                                   notes: [String] = []) -> String {
        let preamble = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = header(sourceName: sourceName, seconds: seconds, language: language, engine: engine)
        var block = body.isEmpty ? stamp : "\(stamp)\n\n\(body)"
        if let uncertain = uncertaintyBlock(disagreements: disagreements, notes: notes) {
            block += "\n\n\(uncertain)"
        }
        return preamble.isEmpty ? block : "\(preamble)\n\n\(block)"
    }
}
