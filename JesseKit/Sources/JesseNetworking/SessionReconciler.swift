import Foundation

// The one session-list reconciler both apps drive their cross-device conversation sync
// from. Pure and view-free (no `ModelContext`, no `JesseThread`, no live client), so it
// is unit-testable without a view host or a server: given the local session ids, the
// server session list, the server deletion tombstones, and the ids currently pending a
// local delete, it produces a `SessionSyncPlan` value the apps apply against their own
// store. Before this, the Mac adopted unknown sessions and the phone did not, and the
// two reconcile paths could drift; routing BOTH through this one function is what keeps
// their adopt / update / delete decisions identical.

/// The plan a session-list reconcile produces: which server sessions to ADOPT as new
/// local threads, which to UPDATE (title refresh + per-flag `FlagReconciler`) against an
/// existing local thread, and which local threads to DELETE because the bridge tombstoned
/// them. A value type carrying only session ids and summaries: the apps resolve ids to
/// their own `JesseThread`s and apply the plan against their own `ModelContext`.
public struct SessionSyncPlan: Sendable, Equatable {
    /// Server sessions not present locally, neither tombstoned nor pending a local delete:
    /// create a fresh local thread (a stub that hydrates its transcript on open).
    public let adopt: [SessionSummary]
    /// Server sessions matched to an existing local thread by `session_id`: refresh the
    /// server-authoritative title and reconcile the favorite/archive flags.
    public let update: [SessionSummary]
    /// `session_id`s the bridge tombstoned that still exist locally: remove the local
    /// thread (its turns cascade) and clear its hydration cursor.
    public let deleteLocalSessionIds: [String]

    public init(adopt: [SessionSummary], update: [SessionSummary], deleteLocalSessionIds: [String]) {
        self.adopt = adopt
        self.update = update
        self.deleteLocalSessionIds = deleteLocalSessionIds
    }
}

/// The pure cross-device session reconciler. `plan` is a value-in / value-out function
/// with no side effects; the apps apply its result.
public enum SessionReconciler {
    /// Decide adopt / update / delete-local for a fetched session list.
    ///
    /// - `localSessionIds`: the `session_id`s of local threads that carry one (a thread
    ///   with no `session_id` is purely local and is never passed in, so it is never
    ///   touched by the plan).
    /// - `sessions`: the server's `GET /jesse/sessions` list.
    /// - `tombstones`: the `session_id`s in the server's `deleted` array (empty against a
    ///   pre-0.26.0 bridge, making delete propagation inert).
    /// - `pendingDeletion`: `session_id`s the user deleted locally whose remote delete has
    ///   not drained yet.
    ///
    /// Rules: a tombstoned id is never adopted or updated, and is deleted locally if it
    /// still exists; a pending-local-delete id is never adopted (the resurrection guard,
    /// so a just-deleted conversation the bridge still lists is not re-created); an id
    /// matched locally is updated; any other id is adopted.
    public static func plan(localSessionIds: Set<String>,
                            sessions: [SessionSummary],
                            tombstones: Set<String>,
                            pendingDeletion: Set<String>) -> SessionSyncPlan {
        var adopt: [SessionSummary] = []
        var update: [SessionSummary] = []
        for s in sessions {
            // A tombstoned id is honored as a delete (below), never adopted or refreshed,
            // even if the bridge still lists it in `sessions`.
            if tombstones.contains(s.sessionId) { continue }
            if localSessionIds.contains(s.sessionId) {
                update.append(s)
            } else if !pendingDeletion.contains(s.sessionId) {
                // Unknown id that is not a just-deleted-locally session: adopt it.
                adopt.append(s)
            }
            // else: unknown but pending a local delete → skip (resurrection guard).
        }
        let deleteLocal = tombstones.filter { localSessionIds.contains($0) }
        return SessionSyncPlan(adopt: adopt, update: update,
                               deleteLocalSessionIds: Array(deleteLocal))
    }
}
