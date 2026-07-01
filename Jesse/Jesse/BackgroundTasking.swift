import UIKit

// A seam over `UIApplication`'s background-task API so `RunCoordinator` can be
// tested without a real `UIApplication`, and — more importantly — so the granted
// identifier is always ended even if the expiration handler fires before the
// caller has recorded it.
//
// The bug this fixes: `beginBackgroundTask`'s expiration handler used to call
// `endBackground(threadID)`, which read the id back out of a dictionary that the
// caller stored *after* `beginBackgroundTask` returned. If the handler fired
// before that store, the lookup missed and the background assertion leaked. Here
// the granted id is written into a `BackgroundTaskHandle` the handler captures, so
// the handler ends the exact id it was granted regardless of ordering.

/// A mutable box holding the granted background-task identifier. The expiration
/// handler captures the box (not a value), so it always ends the id that was
/// actually granted — even before the coordinator records the box elsewhere.
final class BackgroundTaskHandle {
    var id: UIBackgroundTaskIdentifier = .invalid
}

@MainActor
protocol BackgroundTasking: AnyObject {
    /// Begin a background task, writing the granted identifier into `handle`
    /// BEFORE the expiration handler can run. The real implementation gets this
    /// for free: `beginBackgroundTask` returns the id before the system can fire
    /// expiration, so `handle.id` is set first.
    func beginTask(name: String, handle: BackgroundTaskHandle, expiration: @escaping () -> Void)
    /// End the task. A no-op for `.invalid`, matching `UIApplication`.
    func endTask(_ id: UIBackgroundTaskIdentifier)
}

/// Owns the per-thread background-task assertions for `RunCoordinator`: begins a
/// grant for a thread's turn and ends it exactly once — even when the expiration
/// handler fires before the grant is recorded (M7). Extracted from the coordinator
/// so the bookkeeping (the handle box, the per-thread dict, and the "release
/// exactly once" rule) lives in one testable place instead of being smeared across
/// the coordinator's `send`/task-tail/`endBackground` paths.
@MainActor
final class BackgroundTaskGuard {
    private let tasker: BackgroundTasking
    // threadID → the granted handle box. A box (not a raw id) so the expiration
    // handler can end the exact id it was granted even if it fires before `begin`
    // records it here — see `BackgroundTaskHandle`.
    private var handles: [UUID: BackgroundTaskHandle] = [:]

    init(tasker: BackgroundTasking = UIKitBackgroundTasking()) {
        self.tasker = tasker
    }

    /// Begin a background grant for `threadID`'s turn. A grant lets a short turn
    /// finish after the app is backgrounded; longer turns re-attach on foreground.
    /// The expiration handler ends the id via the captured `handle`, so even if it
    /// fires before this stores the handle below, the granted assertion is always
    /// released (M7).
    func begin(_ threadID: UUID, name: String) {
        let handle = BackgroundTaskHandle()
        tasker.beginTask(name: name, handle: handle) { [weak self] in
            self?.end(threadID, handle: handle)
        }
        handles[threadID] = handle
    }

    /// End a thread's background grant. The expiration handler passes the captured
    /// `handle` directly, so the granted id is ended even if expiration fired before
    /// `begin` stored it. Other callers (the task tails) pass no handle and fall
    /// back to the stored one. Ending sets the id to `.invalid`, so a later call for
    /// the same thread is a harmless no-op — the grant is released exactly once.
    func end(_ threadID: UUID, handle: BackgroundTaskHandle? = nil) {
        if let h = handle ?? handles[threadID], h.id != .invalid {
            tasker.endTask(h.id)
            h.id = .invalid
        }
        handles[threadID] = nil
    }
}

/// Production conformer backed by the shared `UIApplication`.
final class UIKitBackgroundTasking: BackgroundTasking {
    // Nonisolated so it can be used as a default argument of `RunCoordinator.init`
    // (evaluated in the caller's context); it holds no isolated state.
    nonisolated init() {}

    func beginTask(name: String, handle: BackgroundTaskHandle, expiration: @escaping () -> Void) {
        handle.id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func endTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
