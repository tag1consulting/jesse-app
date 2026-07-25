import Foundation

// The one conversation-list reconciler both apps drive their cross-device sync from. Pure
// and view-free (no `ModelContext`, no `JesseThread`, no live client), so it is
// unit-testable without a view host or a server: given the conversation ids held locally,
// the server list, the server deletion tombstones, and the ids currently pending a local
// delete, it produces a `ConversationSyncPlan` value the apps apply against their own
// store. Before this, the Mac adopted unknown threads and the phone did not, and the two
// reconcile paths could drift; routing BOTH through this one function is what keeps their
// adopt / update / delete decisions identical.
//
// It keys on the bridge's CONVERSATION id, not a Claude session id. That is the whole
// point: a session id is not stable (the CLI can fork it, and a dropped `--resume` mints a
// new one), and the client only learns it minutes into a turn, so keying on it meant a
// sync landing mid-turn classified a thread the client already held as unknown and adopted
// a duplicate.

/// The plan a conversation-list reconcile produces: which server conversations to ADOPT as
/// new local threads, which to UPDATE (title refresh, current session, timestamps, and the
/// per-flag `FlagReconciler`) against an existing local thread, and which local threads to
/// DELETE because the bridge tombstoned them. A value type carrying only ids and
/// summaries: the apps resolve ids to their own `JesseThread`s and apply the plan against
/// their own `ModelContext`.
public struct ConversationSyncPlan: Sendable, Equatable {
    /// Server conversations not held locally, neither tombstoned nor pending a local
    /// delete: create a fresh local thread (a stub that hydrates its transcript on open).
    public let adopt: [ConversationSummary]
    /// Server conversations matched to an existing local thread by `conversation_id`:
    /// refresh the server-authoritative title and current session, and reconcile the
    /// favorite / archive flags.
    public let update: [ConversationSummary]
    /// `conversation_id`s the bridge tombstoned that are still held locally: remove the
    /// local thread (its turns cascade) and clear its hydration cursor.
    public let deleteLocalConversationIds: [String]

    public init(adopt: [ConversationSummary], update: [ConversationSummary],
                deleteLocalConversationIds: [String]) {
        self.adopt = adopt
        self.update = update
        self.deleteLocalConversationIds = deleteLocalConversationIds
    }
}

/// The pure cross-device conversation reconciler. `plan` is a value-in / value-out
/// function with no side effects; the apps apply its result.
public enum ConversationReconciler {
    /// Decide adopt / update / delete-local for a fetched conversation list.
    ///
    /// - `heldConversationIds`: the `conversation_id`s of local threads. A thread with no
    ///   conversation id (a pre-upgrade row) is bound by the sync's legacy-bind pass
    ///   BEFORE this runs, so by the time `plan` is called every local thread that could
    ///   match is in this set. That ordering is what stops a pre-upgrade thread from being
    ///   re-adopted as a duplicate of itself.
    /// - `conversations`: the server's `GET /jesse/conversations` list.
    /// - `tombstones`: the `conversation_id`s in the server's `deleted` array.
    /// - `pendingDeletion`: ids the user deleted locally whose remote delete has not
    ///   drained yet.
    ///
    /// Rules, unchanged from the session-keyed reconciler this replaces: a tombstoned id is
    /// never adopted or updated, and is deleted locally if it is still held; a
    /// pending-local-delete id is never adopted (the resurrection guard, so a just-deleted
    /// conversation the bridge still lists is not re-created); an id matched locally is
    /// updated; any other id is adopted.
    public static func plan(heldConversationIds: Set<String>,
                            conversations: [ConversationSummary],
                            tombstones: Set<String>,
                            pendingDeletion: Set<String>) -> ConversationSyncPlan {
        var adopt: [ConversationSummary] = []
        var update: [ConversationSummary] = []
        for c in conversations {
            // A tombstoned id is honored as a delete (below), never adopted or refreshed,
            // even if the bridge still lists it.
            if tombstones.contains(c.conversationId) { continue }
            if heldConversationIds.contains(c.conversationId) {
                update.append(c)
            } else if !pendingDeletion.contains(c.conversationId) {
                // An id we do not hold and did not just delete: adopt it.
                adopt.append(c)
            }
            // else: not held but pending a local delete, so skip (resurrection guard).
        }
        let deleteLocal = tombstones.filter { heldConversationIds.contains($0) }
        return ConversationSyncPlan(adopt: adopt, update: update,
                                    deleteLocalConversationIds: Array(deleteLocal))
    }
}
