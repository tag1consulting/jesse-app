import Foundation
import SwiftData
import JesseCore

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
    /// under the current schema with automatic lightweight migration. Factored out of
    /// `shared` and
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
            // Open with SwiftData's AUTOMATIC lightweight migration (no
            // `migrationPlan:`), NOT a staged plan. This is deliberate and load-bearing.
            //
            // A staged `SchemaMigrationPlan` keys migration on each version's exact
            // model checksum and can only migrate a store whose recorded checksum
            // matches a version IN the plan. But every VersionedSchema here references
            // the same live `@Model` classes, so adding a property to an existing
            // entity (e.g. `JesseThread.isArchived`) changes that version's checksum in
            // place: a store already stamped with the OLD checksum becomes an "unknown
            // model version" and the open THROWS ("Cannot use staged migration with an
            // unknown model version"), stranding the user behind the store-error banner.
            // That is a per-additive-property break, and it shipped once already.
            //
            // Automatic migration instead infers a lightweight mapping by comparing the
            // store's entity hashes to the current schema, so an additive, defaulted
            // property (or a new entity) migrates with no plan and no per-version
            // checksum pinning. This is exactly what carried every earlier additive
            // property (`isFavorite`, `origin`, `aiTitle`, the outbox entities) before a
            // plan was ever introduced. A NON-lightweight change (renaming/retyping a
            // column, splitting an entity) is the only thing that needs a real
            // migration; reintroduce a plan with a custom stage THEN, keyed to the shape
            // at that point, not before.
            let container = try ModelContainer(
                for: schema, configurations: onDisk)
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
