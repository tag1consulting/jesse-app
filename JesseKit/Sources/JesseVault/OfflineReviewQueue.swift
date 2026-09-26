import Foundation

// WHAT A MAC OWES THE BRIDGE, ACROSS A RELAUNCH.
//
// The phone stages an offline review as an `OutboxItem`, because the phone HAS a send
// outbox: a durable row, a retry schedule, and a reconcile pass that finds it after a
// kill. The Mac has none of those — `OutboxItem` is an iOS-only entity and the Mac's
// schema deliberately does not carry it — so a review answered on a Mac with the Studio
// asleep lived in memory and died with the process.
//
// This is the smallest durable thing that fits: the PAIRS, keyed by conversation, in
// `UserDefaults`, exactly as `PendingSessionDeletionStore` keeps the conversations whose
// remote transcripts have not been reclaimed. No schema change, no migration, and the
// text is rendered from the pairs at send time by the same `OfflineAnswerCarry.body` the
// phone renders with, so the two platforms cannot grow two ideas of what a review says.

/// The offline reviews a device has not yet delivered, one entry per conversation.
///
/// `UserDefaults`-backed (one small JSON object), with the suite injected so a test uses
/// a scratch one. A value type: it holds no state of its own, which is what lets the
/// store, the composer and a test each construct one over the same suite.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which is documented
/// as thread-safe but is not annotated `Sendable`. The same judgement `OfflineLookupSettings`
/// and every other defaults-backed store in this app makes.
public struct PendingOfflineReviewStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = "vault.offlineReview.pending") {
        self.defaults = defaults
        self.key = key
    }

    /// Every pending review, keyed by conversation.
    public var all: [UUID: [OfflineAnswerPair]] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: [OfflineAnswerPair]].self,
                                                     from: data)
        else { return [:] }
        var out: [UUID: [OfflineAnswerPair]] = [:]
        for (raw, pairs) in stored {
            // An unparseable key is dropped rather than guessed at: it can only come from
            // a hand-edited defaults plist, and a review filed against no conversation has
            // nowhere to be sent.
            guard let id = UUID(uuidString: raw), !pairs.isEmpty else { continue }
            out[id] = pairs
        }
        return out
    }

    /// What this conversation is holding, oldest first.
    public func pairs(threadID: UUID) -> [OfflineAnswerPair] {
        (all[threadID] ?? []).sorted { $0.at < $1.at }
    }

    /// Add one answered exchange to this conversation's pending review.
    ///
    /// APPENDED, never replacing: three questions answered while the Studio slept are one
    /// review with three exchanges in it, so the reconnect produces one turn and not three.
    public func append(_ pair: OfflineAnswerPair, threadID: UUID) {
        var everything = all
        everything[threadID, default: []].append(pair)
        write(everything)
    }

    /// Spent, or abandoned with its conversation. Called only once the review's turn is
    /// DURABLY STAGED, so a save that threw leaves the pairs for the next attempt.
    public func clear(threadID: UUID) {
        var everything = all
        everything[threadID] = nil
        write(everything)
    }

    private func write(_ everything: [UUID: [OfflineAnswerPair]]) {
        let stored = Dictionary(uniqueKeysWithValues:
            everything.filter { !$0.value.isEmpty }
                .map { ($0.key.uuidString, $0.value) })
        if stored.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }
}
