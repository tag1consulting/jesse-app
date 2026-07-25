import Foundation

// Durable remote-conversation deletion. When the user deletes a thread, the local
// SwiftData delete is instant (unchanged), and if the thread had a bridge
// `conversationId` we enqueue that id so the bridge can reclaim EVERY remote transcript
// bound to it (`DELETE /jesse/conversation/{id}`) and record a deletion tombstone that
// converges the delete to the Mac. The durable queue itself
// (`PendingSessionDeletionStore`) is shared in JesseNetworking so both apps use one
// store type; this file keeps the iOS-specific drainer, which is coupled to
// `JesseClientProtocol`. The queue is drained on enqueue and on `scenePhase → .active`.

/// Drains the durable pending-deletions queue by calling the bridge's
/// `DELETE /jesse/conversation/{id}` for each tombstone. Success (including the bridge's
/// idempotent 404) clears the tombstone; a network failure leaves it queued for the
/// next drain (on enqueue, or on `scenePhase → .active`). One failure never blocks
/// draining the rest. `drain()` is directly awaitable so tests drive it without
/// fire-and-forget; `RunCoordinator` wraps it in a detached `Task`.
@MainActor
struct SessionDeletionDrainer {
    let store: PendingSessionDeletionStore
    /// Builds the client for the current config (the same seam `RunCoordinator` uses
    /// for every other bridge call), injected so a test supplies a fake.
    let makeClient: () -> any JesseClientProtocol

    func drain() async {
        let pending = store.pending
        guard !pending.isEmpty else { return }
        let client = makeClient()
        for item in pending {
            do {
                try await client.deleteConversation(item.conversationId)
                store.remove(item.conversationId)
            } catch {
                // Transport/auth/5xx failure — leave the tombstone; the next enqueue
                // or foreground retries. Draining continues with the rest.
                Log.run.error(
                    "remote conversation delete failed for \(item.conversationId): \(error.localizedDescription)")
            }
        }
    }
}
