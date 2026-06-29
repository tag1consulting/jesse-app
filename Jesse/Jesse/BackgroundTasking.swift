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
