import Foundation

// De-duplicates reply delivery by `requestId`. The phone answers a relayed turn on
// TWO paths on purpose — `transferUserInfo` (reliable, background-delivered source
// of truth) and, when reachable, `sendMessage` (immediate) — so the watch may see
// the same reply twice. This keeps the first and drops the rest, so the two paths
// can't double-render or double-speak.
//
// Pure and value-typed: no WatchConnectivity, no timers. The watch session manager
// owns one and calls `shouldDeliver` before rendering; the tests drive it directly.

/// Tracks which `requestId`s have already been delivered, bounded so it can't grow
/// without limit over a long session (the dedup window only needs to cover a
/// reply's two near-simultaneous arrivals, not all history).
public nonisolated struct ReplyDeduper: Sendable {
    private var seen: Set<UUID> = []
    private var order: [UUID] = []
    private let capacity: Int

    public nonisolated init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// True the FIRST time a `requestId` is seen (render/speak it); false for every
    /// later arrival of the same id (a duplicate — drop it). Bounded FIFO eviction
    /// keeps the set small; an id evicted long after its reply landed would simply be
    /// treated as new again, which is harmless for the retry-burst window this covers.
    public nonisolated mutating func shouldDeliver(_ requestId: UUID) -> Bool {
        if seen.contains(requestId) { return false }
        seen.insert(requestId)
        order.append(requestId)
        if order.count > capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }
        return true
    }

    /// Whether an id has already been delivered, without recording anything.
    public nonisolated func hasDelivered(_ requestId: UUID) -> Bool {
        seen.contains(requestId)
    }
}
