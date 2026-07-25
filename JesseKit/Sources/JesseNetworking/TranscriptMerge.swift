import Foundation
import JesseCore

// The one hydration merge both apps use, so the phone and the Mac cannot disagree about
// what counts as "a turn I already have".
//
// Two things used to be wrong here, one on each platform. iOS appended every hydrated turn
// unconditionally, so any hydrate that overlapped turns already rendered locally produced a
// double bubble. macOS guarded the same path with a content-hash multiset, which is a
// different failure: two genuinely identical messages ("ok", "thanks", the same question
// asked twice) are indistinguishable by content, so the guard silently dropped the second
// one. Neither is fixable by tuning a hash.
//
// The fix is an identity, not a heuristic. The bridge stamps every hydrated turn with a
// `turn_key` of `"<session_id>:<byte offset of the jsonl line it came from>"`, which is
// unique within a conversation and byte-identical across repeated hydrates. Steady state is
// then an exact key comparison. The content match survives only as a ONE-TIME upgrade: a
// turn created optimistically (the local echo of a send, or a reply delivered live) has no
// key yet, so the first hydrate that sees it BINDS the key onto that existing turn instead
// of inserting a second copy. Each such turn is bound at most once, tracked by a consumable
// multiset, which is what keeps the content match from degenerating back into ongoing
// content dedup.

/// What one incoming hydrated turn resolved to.
public enum TranscriptMergeAction: Equatable, Sendable {
    /// Already held under this exact `turn_key`: skip it. The steady-state path.
    case skip
    /// An existing UNKEYED turn matches on role and text: bind the key onto it rather than
    /// inserting anything. The one-time upgrade of an optimistically created turn.
    case bind(existingIndex: Int)
    /// Genuinely new: insert a turn carrying the key.
    case insert
}

/// The pure hydration merge. Value-in / value-out over the turns a thread already holds, so
/// the ordering and binding rules are unit-testable without SwiftData or a server; the apps
/// apply the actions against their own `ModelContext`.
public enum TranscriptMerge {
    /// One existing turn, reduced to just what the merge needs.
    public struct Existing: Equatable, Sendable {
        public let role: String      // "user" | "assistant"
        public let text: String
        public let sourceKey: String?
        public init(role: String, text: String, sourceKey: String?) {
            self.role = role
            self.text = text
            self.sourceKey = sourceKey
        }
    }

    /// Decide, for each incoming turn in order, whether to skip it, bind its key onto an
    /// existing unkeyed turn, or insert it.
    ///
    /// `existing` must be in the thread's chronological order: an unkeyed turn is matched
    /// OLDEST first, so when a thread holds the same message twice the earlier bubble takes
    /// the earlier transcript line and the ordering of the two keys matches the ordering of
    /// the two bubbles.
    ///
    /// A returned `bind(existingIndex:)` indexes into `existing`. Each existing turn can be
    /// bound at most once across the whole call, and a turn the caller will insert is
    /// deliberately NOT a candidate for a later bind: only turns that were already there
    /// before this hydrate can be upgraded.
    public static func plan(existing: [Existing], incoming: [HydratedTurn]) -> [TranscriptMergeAction] {
        // Keys already held. An empty key means "unkeyed" and is never a match.
        var heldKeys = Set(existing.compactMap { key in
            key.sourceKey.flatMap { $0.isEmpty ? nil : $0 }
        })
        // Consumable candidates for the one-time bind: the indices of unkeyed turns, oldest
        // first, grouped by their (role, trimmed text) identity.
        var unkeyed: [String: [Int]] = [:]
        for (i, e) in existing.enumerated() where (e.sourceKey ?? "").isEmpty {
            unkeyed[matchKey(role: e.role, text: e.text), default: []].append(i)
        }

        var actions: [TranscriptMergeAction] = []
        actions.reserveCapacity(incoming.count)
        for t in incoming {
            let key = t.turnKey
            if !key.isEmpty, heldKeys.contains(key) {
                actions.append(.skip)
                continue
            }
            let identity = matchKey(role: t.role, text: t.text)
            if var candidates = unkeyed[identity], let index = candidates.first {
                candidates.removeFirst()
                unkeyed[identity] = candidates.isEmpty ? nil : candidates
                if !key.isEmpty { heldKeys.insert(key) }
                actions.append(.bind(existingIndex: index))
                continue
            }
            if !key.isEmpty { heldKeys.insert(key) }
            actions.append(.insert)
        }
        return actions
    }

    /// The identity a content match uses: the role plus the text with surrounding
    /// whitespace stripped. Deliberately NOT a hash of anything else (no timestamp, no
    /// index): an optimistic turn's timestamp is the local clock and the transcript's is the
    /// CLI's, so they never agree.
    static func matchKey(role: String, text: String) -> String {
        // Normalize the two role vocabularies: the wire says "assistant", the store says
        // "jesse".
        let normalized = (role == "assistant" || role == "jesse") ? "jesse" : "user"
        return normalized + "\u{1F}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The store role a hydrated turn's wire role maps to.
    public static func role(for wireRole: String) -> TurnRole {
        wireRole == "assistant" ? .jesse : .user
    }

    /// Parse a transcript ISO-8601 timestamp, falling back to `fallback` so ordering stays
    /// stable when the line carries none. Shared so the phone and the Mac date a hydrated
    /// turn identically.
    public static func timestamp(_ s: String?, fallback: Date = Date()) -> Date {
        guard let s else { return fallback }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s) ?? fallback
    }
}
