import Foundation

// Cross-device convergence for a thread's favorite / archived flags. The local
// SwiftData store stays the render source (cache-first, offline-tolerant); the bridge
// is the sync source. The two are reconciled per flag by last-writer-wins on a
// never-cleared unix-millis clock (`favoriteUpdatedMs` / `archivedUpdatedMs`), the
// exact rule the bridge's flagstore applies server-side (strictly-newer wins, a tie is
// a no-op). This file is view-free and unit-testable without a view host or a server:
// the pure `decide` is a value-in / value-out function, and `reconcile` drives a real
// `JesseThread` plus a fake `FlagSyncing` client.

/// One flag's value plus its unix-millis change clock, the payload pushed to the bridge
/// when the local change is the newer writer.
///
/// `nonisolated`: this module defaults to MainActor isolation (for the `@Model` layer),
/// but these sync value/logic types are plain Sendable data used off the main actor (the
/// networking client, the reconciler's push, unit tests), so they opt out of it.
public nonisolated struct FlagWrite: Sendable, Equatable {
    public let value: Bool
    public let updatedMs: Int
    public init(value: Bool, updatedMs: Int) {
        self.value = value
        self.updatedMs = updatedMs
    }
}

/// The narrow bridge seam the reconciler pushes a local-newer flag change through
/// (`POST /jesse/session/{id}/flags`, sending only the flag(s) that changed with their
/// millis timestamps). Both apps' clients adopt it — the shared `BridgeClientProtocol`
/// refines it, and the iOS `JesseClientProtocol` conforms — and a test fake records the
/// calls. The default no-op keeps older conformers (test fakes) and any pre-0.25.0 path
/// compiling and degrading cleanly: against a bridge without the endpoint the push is a
/// best-effort no-op.
public protocol FlagSyncing: Sendable {
    // `nonisolated`: the witness is the nonisolated networking client (and test fakes),
    // called from the MainActor reconciler across an await. Marking it here keeps the
    // requirement isolation-agnostic so any Sendable conformer satisfies it.
    nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws
}

public extension FlagSyncing {
    nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {}
}

/// The per-flag last-writer-wins outcome.
public nonisolated enum FlagDecision: Equatable, Sendable {
    /// The clocks are equal: nothing to do (already converged).
    case noChange
    /// The server clock is strictly newer: adopt its value + clock locally.
    case adoptServer(value: Bool, updatedMs: Int)
    /// The local clock is strictly newer: push this value + clock up.
    case pushLocal(FlagWrite)
}

/// The cross-device flag reconciler. Pure decision + a thin async apply/push.
public enum FlagReconciler {
    /// Pure last-writer-wins for one flag: a strictly-newer server clock adopts the
    /// server value; a strictly-newer local clock pushes the local value; equal clocks
    /// do nothing. The strict comparison (never flipping on a tie) matches the bridge's
    /// `apply_favorite` / `apply_archived`, so a client and the server converge on the
    /// same winner regardless of the order writes arrive.
    public nonisolated static func decide(localValue: Bool, localMs: Int,
                                          serverValue: Bool, serverMs: Int) -> FlagDecision {
        if serverMs > localMs { return .adoptServer(value: serverValue, updatedMs: serverMs) }
        if localMs > serverMs { return .pushLocal(FlagWrite(value: localValue, updatedMs: localMs)) }
        return .noChange
    }

    /// Reconcile one thread's favorite + archived flags against the server summary,
    /// last-writer-wins per flag. Adopts a strictly-newer server value into the local
    /// thread (the caller saves the context), pushes a strictly-newer local value up via
    /// `client`, and leaves a tie alone. Returns whether the local thread was mutated so
    /// the caller can decide to save.
    ///
    /// A thread with no `session_id` is skipped: it is purely local and cannot sync until
    /// its first reply lands (then it acquires an id and syncs on the next pass). At most
    /// one `setFlags` call is made, carrying ONLY the flag(s) whose local clock is newer.
    ///
    /// Best-effort and self-healing: a failed push is swallowed. Because the local clock
    /// stayed strictly newer than the server's, the NEXT sessions-sync reconcile decides
    /// `pushLocal` again and retries — so no durable retry queue is needed, and a push
    /// failure never surfaces as a user error. An unreachable or pre-0.25.0 bridge is the
    /// same: the local value simply wins locally and re-pushes later.
    @discardableResult
    public static func reconcile(thread: JesseThread,
                                 serverFavorite: Bool, serverFavoriteUpdatedMs: Int,
                                 serverArchived: Bool, serverArchivedUpdatedMs: Int,
                                 client: any FlagSyncing) async -> Bool {
        guard let sid = thread.sessionId, !sid.isEmpty else { return false }

        let favorite = decide(localValue: thread.isFavorite, localMs: thread.favoriteUpdatedMs,
                              serverValue: serverFavorite, serverMs: serverFavoriteUpdatedMs)
        let archived = decide(localValue: thread.isArchived, localMs: thread.archivedUpdatedMs,
                              serverValue: serverArchived, serverMs: serverArchivedUpdatedMs)

        var localChanged = false
        var favoritePush: FlagWrite?
        var archivedPush: FlagWrite?

        switch favorite {
        case let .adoptServer(value, ms):
            thread.applyFavoriteFromSync(value, updatedMs: ms)
            localChanged = true
        case let .pushLocal(write):
            favoritePush = write
        case .noChange:
            break
        }
        switch archived {
        case let .adoptServer(value, ms):
            thread.applyArchivedFromSync(value, updatedMs: ms)
            localChanged = true
        case let .pushLocal(write):
            archivedPush = write
        case .noChange:
            break
        }

        if favoritePush != nil || archivedPush != nil {
            try? await client.setFlags(sessionId: sid, favorite: favoritePush, archived: archivedPush)
        }
        return localChanged
    }
}
