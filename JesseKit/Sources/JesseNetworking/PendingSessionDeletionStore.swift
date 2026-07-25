import Foundation

// Durable queue of remote conversations to delete. When a thread is deleted the local
// SwiftData delete is instant; if the thread had a bridge `conversationId` we enqueue it
// here so the bridge can reclaim every remote transcript bound to it
// (`DELETE /jesse/conversation/{id}`) AND record a deletion tombstone that converges the
// delete to the other device. The queue is persisted so a delete made while the peer/laptop
// is asleep survives app death and completes on the next drain.
//
// Shared in JesseNetworking so BOTH apps use the one store type. The client-coupled drainer
// stays per-app (each app has its own client protocol). The `UserDefaults` is injected so a
// test points it at a scratch suite.

/// One queued remote conversation deletion: the bridge `conversation_id` whose local thread
/// was deleted, and when it was enqueued (ordering / debugging). `Codable` so it persists.
public struct PendingSessionDeletion: Codable, Equatable, Sendable {
    public let conversationId: String
    public let enqueuedAt: Date
    public init(conversationId: String, enqueuedAt: Date) {
        self.conversationId = conversationId
        self.enqueuedAt = enqueuedAt
    }
}

/// A durable queue of conversations whose local thread was deleted but whose remote
/// transcripts have not been reclaimed yet. `UserDefaults`-backed (a small JSON array, so
/// no SwiftData migration), with the suite injected for tests.
public struct PendingSessionDeletionStore {
    private let defaults: UserDefaults
    /// The v2 key. The v1 array held Claude SESSION ids, which the conversation delete route
    /// cannot resolve (the bridge adopts a legacy transcript under the v5 of its session id,
    /// not under the raw id), so a v1 entry is deliberately DROPPED rather than mis-sent.
    /// The cost is bounded and self-correcting: a delete queued while offline, across the one
    /// upgrade boundary, may leave its remote transcript in place, so the conversation
    /// reappears on the next sync and can be deleted again.
    private let key = "pendingConversationDeletions"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The queued deletions, in enqueue order (oldest first).
    public var pending: [PendingSessionDeletion] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([PendingSessionDeletion].self, from: data)
        else { return [] }
        return items
    }

    /// The `conversation_id`s currently queued for remote deletion, the resurrection-guard
    /// input the conversation reconciler consumes so a just-deleted conversation the bridge
    /// still lists is not re-adopted before its remote delete drains.
    public var pendingIds: Set<String> { Set(pending.map(\.conversationId)) }

    /// Enqueue a conversation id for later remote deletion. Idempotent: an id already queued
    /// is not duplicated (it keeps its original `enqueuedAt`). A blank id is ignored: a
    /// thread the sync never bound has no remote conversation to reclaim.
    public func enqueue(_ conversationId: String, at now: Date = Date()) {
        let id = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var items = pending
        guard !items.contains(where: { $0.conversationId == id }) else { return }
        items.append(PendingSessionDeletion(conversationId: id, enqueuedAt: now))
        write(items)
    }

    /// Drop a conversation id's tombstone, called after its remote delete succeeds (including
    /// the bridge's idempotent 404). A no-op for an id not present.
    public func remove(_ conversationId: String) {
        let items = pending.filter { $0.conversationId != conversationId }
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
