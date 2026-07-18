import Foundation

// Durable remote-session deletion. When the user deletes a thread, the local
// SwiftData delete is instant (unchanged), and if the thread had a bridge
// `sessionId` we enqueue that id here so the bridge can reclaim the remote Claude
// Code transcript too (`DELETE /jesse/session/{id}`). The queue is persisted so a
// delete made while the laptop is asleep survives app death and completes on the
// next drain — on enqueue and on `scenePhase → .active`.

/// One queued remote-session deletion: the bridge `session_id` whose local thread
/// was deleted, and when it was enqueued (ordering / debugging). Persisted so the
/// delete survives app death and an offline laptop.
struct PendingSessionDeletion: Codable, Equatable {
    let sessionId: String
    let enqueuedAt: Date
}

/// A durable queue of Claude Code sessions whose local thread was deleted but whose
/// remote transcript hasn't been reclaimed yet. UserDefaults-backed — a small JSON
/// array, so it needs no SwiftData schema migration — with the `UserDefaults`
/// injected so a test can point it at a scratch suite (mirroring `BridgeVersionStore`).
struct PendingSessionDeletionStore {
    private let defaults: UserDefaults
    private let key = "pendingSessionDeletions"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The queued deletions, in enqueue order (oldest first).
    var pending: [PendingSessionDeletion] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([PendingSessionDeletion].self, from: data)
        else { return [] }
        return items
    }

    /// Enqueue a session id for later remote deletion. Idempotent: an id already
    /// queued is not duplicated (it keeps its original `enqueuedAt`). A blank id is
    /// ignored — a thread with no `sessionId` has no remote session to reclaim.
    func enqueue(_ sessionId: String, at now: Date = Date()) {
        let id = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var items = pending
        guard !items.contains(where: { $0.sessionId == id }) else { return }
        items.append(PendingSessionDeletion(sessionId: id, enqueuedAt: now))
        write(items)
    }

    /// Drop a session id's tombstone — called after its remote delete succeeds
    /// (including the bridge's idempotent 404). A no-op for an id not present.
    func remove(_ sessionId: String) {
        let items = pending.filter { $0.sessionId != sessionId }
        write(items)
    }

    private func write(_ items: [PendingSessionDeletion]) {
        if items.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Drains the durable pending-deletions queue by calling the bridge's
/// `DELETE /jesse/session/{id}` for each tombstone. Success (including the bridge's
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
                try await client.deleteSession(item.sessionId)
                store.remove(item.sessionId)
            } catch {
                // Transport/auth/5xx failure — leave the tombstone; the next enqueue
                // or foreground retries. Draining continues with the rest.
                Log.run.error(
                    "remote session delete failed for \(item.sessionId): \(error.localizedDescription)")
            }
        }
    }
}
