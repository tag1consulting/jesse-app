import Foundation

/// Which empty state the thread list shows in its "no conversations yet" slot.
/// Pure so the first-run pairing gate is unit-tested without standing up a view.
enum ThreadListEmptyState: Equatable {
    /// Not yet paired with a bridge — show the "Pair with your Jesse bridge" CTA
    /// instead of "Tap + to start", because an unpaired user's first send just
    /// errors. Tapping it opens Settings straight to Scan-to-pair.
    case pairBridge
    /// Paired but no conversations yet — the ordinary first-conversation prompt.
    case noConversations
}

/// The first-run gate: an unpaired user (missing host or token) sees the pairing
/// CTA; a paired one sees the ordinary empty state. Keyed off the same
/// `isConfigured` the send path and push registration use, so "configured" means
/// exactly one thing across the app — a half-paired config (host but no bearer
/// token) still can't send, so it reads as unpaired here.
func threadListEmptyState(for config: JesseConfig) -> ThreadListEmptyState {
    config.isConfigured ? .noConversations : .pairBridge
}
