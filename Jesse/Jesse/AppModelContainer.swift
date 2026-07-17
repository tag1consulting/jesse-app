import Foundation
import SwiftData

// One shared SwiftData container for the whole app process. Both the SwiftUI view
// tree (`JesseApp`) and the background watch-relay path
// (`PhoneWatchConnectivity`) resolve their `ModelContext` from THIS container, so a
// turn relayed from the watch lands in the same store the thread list observes —
// not a second container over the same file whose changes the UI wouldn't see.

/// The outcome of opening the app's persistent store: the container the app runs
/// against, plus a NON-nil `openFailure` iff the on-disk store could not be opened
/// and `container` is therefore a non-persisting in-memory *fallback*.
///
/// The container is always usable so the app never crash-loops on a store hiccup,
/// but a fallback is never silent: `openFailure` is the signal the UI MUST surface
/// (see `JesseApp`), because in the fallback case this session's history is not
/// being saved. The on-disk file is **left untouched** — an in-memory
/// `ModelConfiguration` opens a separate store and never reads, rewrites, or
/// deletes the on-disk sqlite — so the user's history stays recoverable and a later
/// launch (or an OS/schema update) can open it for real.
struct AppModelStore {
    let container: ModelContainer
    /// nil on a normal on-disk open; the underlying error when `container` is the
    /// flagged in-memory fallback. Drives the "couldn't open your conversation
    /// store" UI. Never silently nil on failure — that is the whole point.
    let openFailure: Error?

    var isFallback: Bool { openFailure != nil }
}

enum AppModelContainer {
    /// The app's shared store, opened once at process start.
    static let shared: AppModelStore = load()

    /// Open the store at `url` (nil → the default Application-Support location),
    /// under the versioned schema + migration plan. Factored out of `shared` and
    /// `url`-injectable so the populated-store migration test and the
    /// fallback-flag test drive the exact same code path the app does.
    ///
    /// On success: `AppModelStore(container:, openFailure: nil)`.
    /// On failure to open the on-disk store: we do NOT silently substitute an empty
    /// persistent store and we do NOT touch the on-disk file. We log loudly, fall
    /// back to a fresh in-memory store so the app can still run this session, and
    /// carry the error in `openFailure` so the UI flags it. Only if even the
    /// in-memory store can't be built — the app truly cannot function — do we trap.
    static func load(url: URL? = nil) -> AppModelStore {
        let schema = jesseCurrentSchema
        let onDisk = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema)
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: JesseMigrationPlan.self, configurations: onDisk)
            return AppModelStore(container: container, openFailure: nil)
        } catch {
            Log.run.error(
                "persistent SwiftData store could not be opened — running on a flagged in-memory fallback this session; the on-disk file is left intact and NOT overwritten. Error: \(error)")
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: memory) else {
                // Even an in-memory store failed — the app cannot function without one.
                preconditionFailure("could not create any SwiftData container: \(error)")
            }
            return AppModelStore(container: fallback, openFailure: error)
        }
    }
}
