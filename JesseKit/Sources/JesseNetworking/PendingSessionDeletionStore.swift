import Foundation

// Durable queue of remote Claude Code sessions to delete. When a thread is deleted the
// local SwiftData delete is instant; if the thread had a bridge `sessionId` we enqueue it
// here so the bridge can reclaim the remote transcript too (`DELETE /jesse/session/{id}`)
// AND record a deletion tombstone (bridge 0.26.0) that converges the delete to the other
// device. The queue is persisted so a delete made while the peer/laptop is asleep
// survives app death and completes on the next drain.
//
// Shared in JesseNetworking so BOTH apps use the one store type (the phone had it first;
// the Mac now mirrors it). The client-coupled drainer stays per-app (each app has its own
// client protocol). The `UserDefaults` is injected so a test points it at a scratch suite.

/// One queued remote-session deletion: the bridge `session_id` whose local thread was
/// deleted, and when it was enqueued (ordering / debugging). `Codable` so it persists.
public struct PendingSessionDeletion: Codable, Equatable, Sendable {
    public let sessionId: String
    public let enqueuedAt: Date
    public init(sessionId: String, enqueuedAt: Date) {
        self.sessionId = sessionId
        self.enqueuedAt = enqueuedAt
    }
}

/// A durable queue of Claude Code sessions whose local thread was deleted but whose remote
/// transcript has not been reclaimed yet. `UserDefaults`-backed (a small JSON array, so
/// no SwiftData migration), with the suite injected for tests.
public struct PendingSessionDeletionStore {
    private let defaults: UserDefaults
    private let key = "pendingSessionDeletions"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The queued deletions, in enqueue order (oldest first).
    public var pending: [PendingSessionDeletion] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([PendingSessionDeletion].self, from: data)
        else { return [] }
        return items
    }

    /// The `session_id`s currently queued for remote deletion, the resurrection-guard
    /// input the session reconciler consumes so a just-deleted conversation the bridge
    /// still lists is not re-adopted before its remote delete drains.
    public var pendingIds: Set<String> { Set(pending.map(\.sessionId)) }

    /// Enqueue a session id for later remote deletion. Idempotent: an id already queued is
    /// not duplicated (it keeps its original `enqueuedAt`). A blank id is ignored: a
    /// thread with no `sessionId` has no remote session to reclaim.
    public func enqueue(_ sessionId: String, at now: Date = Date()) {
        let id = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var items = pending
        guard !items.contains(where: { $0.sessionId == id }) else { return }
        items.append(PendingSessionDeletion(sessionId: id, enqueuedAt: now))
        write(items)
    }

    /// Drop a session id's tombstone, called after its remote delete succeeds (including
    /// the bridge's idempotent 404). A no-op for an id not present.
    public func remove(_ sessionId: String) {
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
