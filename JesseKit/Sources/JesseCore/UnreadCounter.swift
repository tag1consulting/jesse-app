import Foundation
import SwiftData

// THE BADGE'S NUMBER, AS A COUNT QUERY.
//
// The number on the Chats tab, the app icon and the Dock tile is "how many conversations
// hold a reply nobody has seen". `jesseUnreadCount` is the rule, and it stays the rule —
// but the way the number was OBTAINED is what made the app hitch: each shell read it from
// a `@Query` over every conversation, declared on the shell's own root view.
//
// A root-level query is the expensive part, and it is expensive for a reason that has
// nothing to do with how fast the rule runs:
//
//   * A `@Query` is refetched whenever ANY save touches its entity, and a save that
//     touches a thread is ordinary — a reply landing, a conversation being marked read, a
//     sync pass adopting or refreshing rows, an archive, a title arriving.
//   * Each refetch materializes every row and then re-evaluates the view's body. On the
//     ROOT view, that body is the whole tab shell, so all three tabs are rebuilt. The
//     Health and Today screens were re-evaluating while the user was in Chats.
//   * The saves arrive in BURSTS. A conversation-sync pass mutates many threads and awaits
//     a flag reconcile per thread, so the main context's autosave gets several turns inside
//     one sync.
//
// This class is the badge's number without any of that. It holds one observable `Int`,
// recomputes it with `fetchCount` over a `#Predicate` (so no thread object is materialized
// and no `turns` relationship is faulted), coalesces a burst of saves into one recount, and
// ASSIGNS ONLY WHEN THE VALUE CHANGES — so a save that does not change the badge
// invalidates nothing at all.
//
// ONE IMPLEMENTATION FOR BOTH SHELLS. iOS reads it for the tab badge and the icon, macOS
// for the Dock tile; the rule, the coalescing and the change-detection are shared, because
// two copies of "how many" is how the icon and the list came to disagree before.
@Observable
public final class UnreadCounter {

    /// How long a burst of saves is allowed to collapse into one recount.
    ///
    /// TRAILING EDGE, deliberately: the recount happens at the END of the window, not at
    /// its start, so a burst of twenty saves that ends with one more unread conversation
    /// produces exactly one recount carrying the final answer. A leading-edge recount would
    /// publish the count as it stood mid-burst and then publish again at the boundary.
    ///
    /// 250 ms because the badge is a number in a corner: nobody can tell a quarter of a
    /// second, and the transcript's own dot (which the list's query owns) is instant either
    /// way.
    public static let coalescingWindow: TimeInterval = 0.25

    /// Conversations holding a reply nobody has seen. The ONLY observed property here:
    /// reading it in a view body makes that view depend on the NUMBER and on nothing else
    /// about the store.
    public private(set) var unreadCount: Int = 0

    /// How many times `unreadCount` was actually assigned a new value — the count of
    /// invalidations this object has caused. A test asserts it stays at 0 across saves that
    /// cannot change the badge, and reads 1 for a burst that changes it once. Production
    /// ignores it. (The same instrumentation shape as `RunCoordinator.partialPublishCount`.)
    @ObservationIgnored public private(set) var publishCount = 0

    /// How many times the count was recomputed, published or not. The coalescing win is
    /// the gap between this and the number of saves.
    @ObservationIgnored public private(set) var recountCount = 0

    /// True once the `#Predicate` path has failed and the property-fetch fallback has been
    /// used (see `recount`). Reported rather than hidden: the two paths must agree, and if
    /// the platform ever stops translating a two-key-path comparison we want that stated in
    /// a test failure rather than discovered as a wrong badge.
    @ObservationIgnored public private(set) var didFallBackToPropertyFetch = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let window: TimeInterval
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void

    // Both are touched by `deinit`, which must be `nonisolated` (a MainActor-isolated
    // deinit aborts when the last reference is dropped off the main actor — see
    // `ComposerDraftStore`). They are only ever read and written on the main actor
    // otherwise, and `deinit` runs when nothing else holds this object.
    @ObservationIgnored private nonisolated(unsafe) var pending: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - container: the app's store. The counter reads it on a context of its OWN (never
    ///     a view's), because it is answering a question about the store rather than about
    ///     anything on screen.
    ///   - coalescingWindow: overridable so a test can state the window it is driving.
    ///   - sleep: how the coalescing window is waited out. Injected for the same reason
    ///     `RunCoordinator.flushSleep` is: a test drives the cadence deterministically
    ///     instead of sleeping.
    public init(container: ModelContainer,
                coalescingWindow: TimeInterval = UnreadCounter.coalescingWindow,
                sleep: @escaping (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                }) {
        self.container = container
        self.window = coalescingWindow
        self.sleep = sleep
        // The count at launch, before any save: a cold launch must paint the right badge
        // without waiting for something to change.
        unreadCount = recount()

        // EVERY CONTEXT COUNTS. `ModelContext.didSave` is posted for every context on every
        // container in the process, which is exactly the reach the badge needs: a reply
        // delivered on the background delivery context, a read mark converging from the Mac
        // through a sync, an archive made in the list — all of them are saves, and none of
        // them is the one context a view happens to hold.
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            // The saving context, reduced to a SENDABLE identity before the main-actor hop.
            // A `Notification` — and the `ModelContext` it carries — is not Sendable, and
            // handing either across an isolation boundary is a data race the compiler
            // rightly refuses; an `ObjectIdentifier` is a number. `nil` means the
            // notification named no context at all, which `isOurs` treats as ours.
            let saved = (note.object as? ModelContext).map { ObjectIdentifier($0.container) }
            // The block is delivered on the main queue, which is the main actor; the hop is
            // an assertion rather than a suspension, so a save's recount is scheduled in the
            // same turn it is announced.
            MainActor.assumeIsolated {
                guard let self, self.isOurs(saved) else { return }
                self.noteStoreChanged()
            }
        }
    }

    nonisolated deinit {
        pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Note that something in the store changed, and arrange ONE recount at the end of the
    /// coalescing window. Calls inside an open window are free: they neither reschedule the
    /// recount nor add a second one.
    ///
    /// Public because it is also the direct seam a test drives (a burst of twenty, with the
    /// window held open), and because any future writer that bypasses `save()` has
    /// somewhere to say so.
    public func noteStoreChanged() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.window)
            self.pending = nil
            guard !Task.isCancelled else { return }
            self.recountAndPublish()
        }
    }

    /// Recount now, synchronously, cancelling any window in flight. For the moments that
    /// cannot wait for a notification — a fresh count on demand — and for tests.
    public func recountNow() {
        pending?.cancel()
        pending = nil
        recountAndPublish()
    }

    /// The fetch the count is made with: a predicate and nothing else — no sort, no
    /// `propertiesToFetch`, and above all no relationship key path, so a conversation's
    /// `turns` are never faulted to paint a badge. Exposed so a test can assert that.
    public static func unreadDescriptor() -> FetchDescriptor<JesseThread> {
        FetchDescriptor<JesseThread>(predicate: #Predicate<JesseThread> {
            $0.isArchived == false && $0.lastReplyMs > $0.readThroughMs
        })
    }

    /// The only three columns the fallback reads — the same three (plus `isArchived`) that
    /// `jesseUnreadCount` reads, and none of them a relationship.
    public static let countedProperties: [PartialKeyPath<JesseThread>] =
        [\JesseThread.isArchived, \JesseThread.lastReplyMs, \JesseThread.readThroughMs]

    // MARK: - Internals

    /// Whether a `didSave` came from this counter's own container. A process with one store
    /// only ever sees its own, but a test host runs many at once, and a counter that
    /// recounted on another store's save would spend a count query on a store nobody is
    /// looking at. A notification carrying no context at all is treated as ours, because a
    /// missed recount is a stale badge and a redundant one costs a count query.
    private func isOurs(_ savedContainer: ObjectIdentifier?) -> Bool {
        guard let savedContainer else { return true }
        return savedContainer == ObjectIdentifier(container)
    }

    private func recountAndPublish() {
        recountCount += 1
        let fresh = recount()
        // THE WHOLE POINT. Assigning an unchanged value would invalidate every view reading
        // it, which is the behavior this class exists to remove: most saves that touch a
        // conversation do not change how many of them are unread.
        guard fresh != unreadCount else { return }
        unreadCount = fresh
        publishCount += 1
    }

    /// Count the unread conversations in the store.
    ///
    /// A FRESH CONTEXT each time, on purpose: the count must reflect what is COMMITTED,
    /// including a save made a moment ago by another context (the background delivery
    /// context, a sync). A long-lived context can answer from rows it has already seen; a
    /// new one cannot, and it costs nothing — a `ModelContext` is a bookkeeping object, not
    /// a store open.
    ///
    /// `fetchCount` rather than `fetch`: it returns an `Int` from the store and materializes
    /// no model at all, so counting 300 conversations pulls neither 300 objects nor any of
    /// their turns into memory. If the predicate's two-key-path comparison is ever rejected,
    /// the fallback fetches ONLY the three scalar columns and applies the shared rule to
    /// them, which is the same answer by a more expensive road.
    private func recount() -> Int {
        let context = ModelContext(container)
        do {
            return try context.fetchCount(Self.unreadDescriptor())
        } catch {
            didFallBackToPropertyFetch = true
            var descriptor = FetchDescriptor<JesseThread>()
            descriptor.propertiesToFetch = Self.countedProperties
            let rows = (try? context.fetch(descriptor)) ?? []
            return jesseUnreadCount(rows)
        }
    }
}

extension UnreadCounter {

    /// One counter per store per process, so both shells can ask for "the" counter from
    /// wherever they happen to hold a container.
    ///
    /// Keyed on the container's identity rather than held in a single `shared` slot because
    /// a test host legitimately opens many stores, and each deserves its own answer. The
    /// app opens exactly one, so in production this is a single object created on the first
    /// body evaluation that reads the badge and kept for the life of the process.
    private static var instances: [ObjectIdentifier: UnreadCounter] = [:]

    public static func shared(for container: ModelContainer) -> UnreadCounter {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let made = UnreadCounter(container: container)
        instances[key] = made
        return made
    }
}
