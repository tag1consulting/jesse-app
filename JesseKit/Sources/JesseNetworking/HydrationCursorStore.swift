import Foundation

// Per-conversation cursor into a conversation's transcript, so a hydrate fetches only what
// was appended since. The cursor is the bridge's OPAQUE `"<segment>:<offset>"` string, not a
// byte offset: a conversation can span several transcript files (a CLI session fork, or a
// dropped `--resume` after a sweep), so a bare offset is not a sufficient position. The
// client never parses it, only echoes it back.
//
// PRESENCE-BASED on purpose: an ABSENT cursor ("never hydrated") is distinct from a cursor at
// the very beginning ("hydrated, nothing before the start"). That distinction is what lets a
// client tell an adopted stub (no cursor, no local turns, so import the whole transcript)
// apart from a locally-started thread (no cursor but its own turns already present, so seed
// the cursor to the end and import nothing).
//
// Kept in `UserDefaults` (small strings keyed by conversation id), NOT the SwiftData schema,
// so tracking sync state adds no column to the model and needs no migration. The backing
// `UserDefaults` is injected so a test points it at a scratch suite.
public struct HydrationCursorStore {
    private let defaults: UserDefaults
    /// The v2 prefix. The v1 keys held BYTE OFFSETS against a single session's transcript,
    /// which are meaningless against the opaque conversation cursor and are keyed on a
    /// session id rather than a conversation id, so they are purged rather than translated.
    private static let prefix = "jesse.hydrate.cursor.v2."
    /// The pre-conversation prefix, purged once on first use after the upgrade.
    private static let legacyPrefix = "jesse.hydrate.cursor."
    /// One-shot marker so the purge runs once rather than on every launch.
    private static let purgedFlag = "jesse.hydrate.cursor.v1purged"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        purgeLegacyCursorsOnce()
    }

    private func key(_ conversationId: String) -> String { Self.prefix + conversationId }

    /// Drop every v1 byte-offset cursor, once. Note the ordering hazard this avoids:
    /// `jesse.hydrate.cursor.` is a PREFIX of `jesse.hydrate.cursor.v2.`, so a purge that
    /// ran after any v2 key had been written would delete live cursors. Filtering the v2
    /// prefix out explicitly makes that safe regardless of when it runs.
    private func purgeLegacyCursorsOnce() {
        guard !defaults.bool(forKey: Self.purgedFlag) else { return }
        for k in defaults.dictionaryRepresentation().keys
        where k.hasPrefix(Self.legacyPrefix) && !k.hasPrefix(Self.prefix) && k != Self.purgedFlag {
            defaults.removeObject(forKey: k)
        }
        defaults.set(true, forKey: Self.purgedFlag)
    }

    /// The stored cursor for a conversation, or `nil` if it has never been hydrated. `nil` is
    /// meaningfully different from the start-of-transcript cursor: absent means "decide by
    /// whether the thread already has local turns".
    public func cursor(_ conversationId: String) -> String? {
        guard let value = defaults.string(forKey: key(conversationId)), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Set the cursor (marks the conversation hydrated).
    public func setCursor(_ conversationId: String, _ value: String) {
        defaults.set(value, forKey: key(conversationId))
    }

    /// Forget a conversation's cursor (so it reads as never-hydrated again), called when its
    /// local thread is deleted, cross-device or otherwise.
    public func clear(_ conversationId: String) {
        defaults.removeObject(forKey: key(conversationId))
    }
}
