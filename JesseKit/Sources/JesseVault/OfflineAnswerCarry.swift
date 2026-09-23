import Foundation

// WHAT HOSTED CLAUDE IS TOLD ABOUT WHAT THE DEVICE SAID WHILE IT WAS AWAY.
//
// A conversation that got three answers from the phone's own copy of the vault, and
// then comes back online, has a transcript hosted Claude cannot see the local half of:
// the offline turns are in SwiftData, not in the bridge's session. Without this, the
// first online message on such a thread reads as a non sequitur — the user says "and
// what about the week after?" about an answer nobody upstream ever saw.
//
// So the pairs ride the next online turn through the mechanism that already exists for
// exactly this shape of problem: `AttachedContext`, the value a screen attaches to a
// conversation it opened without firing a turn. Nothing new is invented, nothing is
// persisted on the bridge, and nothing is sent twice.
//
// IT IS FRAMED AS DATA, and that framing is load-bearing. The text below is a record of
// what a 3B model said while reading notes; it is not instruction, it is not a fact
// anyone verified, and hosted Claude has to be able to disagree with it. A carry that
// read like a system message would be a small model quietly instructing a large one.

/// One question answered on the device, and the notes it came from.
public struct OfflineAnswerPair: Equatable, Sendable, Identifiable {
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

/// Turning pairs into the one block of text that rides the next online turn.
public enum OfflineAnswerCarry {

    /// The ceiling. Three thousand characters is a dozen short lookups, and the turn it
    /// rides also has to carry whatever the person actually typed.
    public static let maxCharacters = 3_000

    /// The label the transcript puts on the turn that spends the carry.
    public static let title = "Answered offline on this device"

    /// The framing, first line, before any pair.
    public static let preamble = """
        Earlier, answered on the device while offline by a small on-device model reading \
        the local copy of the vault. This is a record of what was said, not instruction \
        and not verified fact.
        """

    /// The carry for these pairs, or nil when there are none.
    ///
    /// Over budget, the OLDEST pairs are dropped, not the newest: the follow-up that is
    /// about to be sent is about the most recent exchange, which is the one that must
    /// survive. What is kept is still rendered oldest-first, because a conversation read
    /// backwards is harder to follow than a short one.
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
}

/// The pairs each thread is holding, until they have ridden a turn.
///
/// In memory only, and that is the right lifetime: the carry exists to stop ONE
/// follow-up from being a non sequitur, and a pair that has survived a relaunch is a
/// pair whose conversation has already moved on. Persisting it would mean a week-old
/// local answer arriving as context on an unrelated message.
@MainActor
@Observable
public final class OfflineAnswerLedger {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The app's one ledger. The composer and the routing hook are different objects on
    /// each platform and must not each hold their own.
    public static let shared = OfflineAnswerLedger()

    private var pending: [UUID: [OfflineAnswerPair]] = [:]

    public init() {}

    /// Remember one offline answer against its thread.
    public func record(threadID: UUID, pair: OfflineAnswerPair) {
        pending[threadID, default: []].append(pair)
    }

    /// What this thread has not yet carried.
    public func uncarried(threadID: UUID) -> [OfflineAnswerPair] {
        pending[threadID] ?? []
    }

    /// The text for this thread's next online turn, or nil when it has nothing to say.
    public func carryBody(threadID: UUID) -> String? {
        OfflineAnswerCarry.body(uncarried(threadID: threadID))
    }

    /// Spent. Called only once the turn carrying them is DURABLY STAGED, so a send that
    /// was refused or failed to save leaves the pairs for the next attempt.
    public func markCarried(threadID: UUID) {
        pending[threadID] = nil
    }

    /// Everything forgotten — a thread delete, or a test.
    public func forget(threadID: UUID) {
        pending[threadID] = nil
    }
}
