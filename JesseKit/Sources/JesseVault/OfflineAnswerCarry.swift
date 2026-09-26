import Foundation

// WHAT HOSTED CLAUDE IS TOLD ABOUT WHAT THE DEVICE DID WHILE IT WAS AWAY.
//
// A conversation that got three answers from the phone's own copy of the vault has a
// transcript hosted Claude cannot see the local half of: the offline turns are in
// SwiftData, not in the bridge's session. That was the first reason this existed, and it
// was not enough of one.
//
// THE REASON IT EXISTS NOW IS THAT A REQUEST CAN VANISH. "Track two cups of coffee. 6:50
// and 7:20." went to a 3B model, which answered it with a café's opening hours, and
// because the outcome was "answered" nothing was queued for anybody: the two coffees were
// logged days later, from a screenshot. The question was Jeremy's, the answer was a guess,
// and the only party able to tell them apart or act on either is upstream.
//
// So this block is a REVIEW, addressed to hosted Claude, and it is delivered by itself the
// moment the bridge is back — it does not wait for a message Jeremy happens to send next.
// It asks for three things in a fixed order: act on the requests, audit the answers, and
// write the fix for whatever the offline path got wrong. The framing is load-bearing in
// both directions: the `Q:` lines ARE Jeremy's own words and must be acted on, and the
// `A:` lines are an unverified small-model answer and must not be believed.

/// One question answered on the device, and the notes it came from.
///
/// `Codable` because a review is durable now: on the phone the pairs are stored on the
/// `OutboxItem` that carries them, on the Mac in `PendingOfflineReviewStore`, and in both
/// places the pairs are the truth and the text below is rendered from them.
public struct OfflineAnswerPair: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public let answer: String
    public let paths: [String]
    public let at: Date

    public init(id: UUID = UUID(), question: String, answer: String,
                paths: [String], at: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.paths = paths
        self.at = at
    }
}

/// Turning pairs into the one review the bridge is sent.
public enum OfflineAnswerCarry {

    /// The ceiling. Three thousand characters is the preamble plus a handful of short
    /// exchanges, and a review that grew without bound would be a review nobody reads.
    public static let maxCharacters = 3_000

    /// The label the transcript puts on the review turn. It is not a message Jeremy typed,
    /// and the transcript says so rather than putting his name on it.
    public static let title = "Answered offline on this device"

    /// The framing, and the three asks, before any pair.
    ///
    /// It opens by saying WHAT THIS IS, because the previous wording ("a record, not
    /// instruction and not verified fact") told hosted Claude to treat Jeremy's own request
    /// as inert data — so a request to log two coffees arrived upstream marked "do not act
    /// on this". The distinction the framing has to draw is between the two halves of one
    /// exchange, not between the exchange and the conversation.
    public static let preamble = """
        Automatic review and audit of what the on-device model did while the bridge was \
        unreachable. This is not a new message from Jeremy.

        Three things, in this order:

        1. ACT. The Q: lines are Jeremy's own words, sent while the bridge was unreachable, \
        and they are his real requests. Act on any the device could not perform: logging, \
        scheduling, capture, anything that writes.
        2. AUDIT. The A: lines are an unverified answer from a small on-device model reading \
        the local copy of the vault. Check each one and say plainly if it is wrong, missed \
        the point, or should never have been answered on the device.
        3. IMPROVE. If any exchange shows the offline path could be better (the gate let a \
        request through, retrieval picked the wrong notes, the answer misread the question), \
        write a coding-agent prompt for the fix in Jeremy's usual prompt format, file it in \
        his usual tracking without asking first, and name it in your reply.

        If every answer stands, nothing needed doing and nothing needs improving, reply with \
        one short line saying so.
        """

    /// The review for these pairs, or nil when there are none.
    ///
    /// Over budget, the OLDEST pairs are dropped, not the newest: a review is read newest
    /// first by the person it produces work for, and the most recent exchange is the one
    /// most likely to still need acting on. What is kept is still rendered oldest-first,
    /// because a conversation read backwards is harder to follow than a short one.
    public static func body(_ pairs: [OfflineAnswerPair],
                            limit: Int = maxCharacters) -> String? {
        guard !pairs.isEmpty else { return nil }
        let ordered = pairs.sorted { $0.at < $1.at }

        var kept: [String] = []
        var total = preamble.count
        for rendered in ordered.reversed().map(render) {
            // +2 for the blank line that joins this block to the one before it.
            guard total + rendered.count + 2 <= limit else { break }
            total += rendered.count + 2
            kept.append(rendered)
        }
        guard !kept.isEmpty else { return nil }
        return ([preamble] + kept.reversed()).joined(separator: "\n\n")
    }

    /// One pair, as three labelled lines.
    static func render(_ pair: OfflineAnswerPair) -> String {
        var out = "Q: \(pair.question.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        out += "A: \(pair.answer.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !pair.paths.isEmpty {
            out += "\nfrom: \(pair.paths.joined(separator: ", "))"
        }
        return out
    }

    // MARK: - How the pairs are stored

    /// The pairs of one pending review, as the durable blob that holds them.
    ///
    /// JSON rather than a relationship or a second entity: a review GROWS by appending a
    /// pair, so the pairs have to be readable back to render the text again, and the
    /// smallest durable place for a handful of small values is one blob beside the message
    /// they render into. Nil for an empty list, which is what "no review" is stored as.
    public static func encode(_ pairs: [OfflineAnswerPair]) -> Data? {
        guard !pairs.isEmpty else { return nil }
        return try? JSONEncoder().encode(pairs)
    }

    /// The pairs a blob holds, oldest first. An absent or unreadable blob is an empty
    /// review rather than an error: the text it rendered into is already staged, and
    /// failing the send over a blob that cannot be re-read would lose the review entirely.
    public static func decode(_ data: Data?) -> [OfflineAnswerPair] {
        guard let data,
              let pairs = try? JSONDecoder().decode([OfflineAnswerPair].self, from: data)
        else { return [] }
        return pairs.sorted { $0.at < $1.at }
    }
}
