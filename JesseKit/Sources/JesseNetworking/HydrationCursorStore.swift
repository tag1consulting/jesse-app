import Foundation

// Per-session byte cursor into a conversation's append-only transcript jsonl, so a
// hydrate fetches only the delta appended since (`?after=`). PRESENCE-BASED on purpose:
// an ABSENT cursor ("never hydrated") is distinct from a cursor at byte 0 ("hydrated,
// nothing before the start"). That distinction is what lets the phone tell an adopted
// stub (no cursor, no local turns → import the whole transcript) apart from a
// phone-started thread (no cursor but its own turns already present → seed the cursor to
// the end and import nothing, so the phone never re-imports its own record).
//
// Kept in `UserDefaults` (small ints keyed by session id), NOT the SwiftData schema, so
// tracking sync state adds no column to the model and needs no migration, the same
// choice the Mac's `MacCursorStore` made. The backing `UserDefaults` is injected so a
// test points it at a scratch suite.
public struct HydrationCursorStore {
    private let defaults: UserDefaults
    private static let prefix = "jesse.hydrate.cursor."

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ sessionId: String) -> String { Self.prefix + sessionId }

    /// The stored cursor for a session, or `nil` if it has never been hydrated. `nil` is
    /// meaningfully different from `0`: absent means "decide by whether the thread already
    /// has local turns"; `0` means "hydrated from the very start".
    public func offset(_ sessionId: String) -> UInt64? {
        guard defaults.object(forKey: key(sessionId)) != nil else { return nil }
        return UInt64(max(0, defaults.integer(forKey: key(sessionId))))
    }

    /// Set the cursor to `value` (marks the session hydrated).
    public func setOffset(_ sessionId: String, _ value: UInt64) {
        defaults.set(Int(value), forKey: key(sessionId))
    }

    /// Forget a session's cursor (so it reads as never-hydrated again), called when its
    /// local thread is deleted, cross-device or otherwise.
    public func clear(_ sessionId: String) {
        defaults.removeObject(forKey: key(sessionId))
    }
}
