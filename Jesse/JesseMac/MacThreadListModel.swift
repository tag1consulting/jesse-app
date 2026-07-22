import Foundation
import JesseCore
import JesseConversations
import JesseSearch

// The Mac sidebar's pure list seam. It wraps the shared `threadListLayout` so the
// Mac list is grouped / favorited / date-sectioned by exactly the same code the
// iPhone drives its list from (never a bare @Query sort), and so the wiring is
// unit-testable without a view host: switching `scope` flips the layout between
// the full sectioned view and the flat favorites view, and `expandedFolders`
// drives month-folder disclosure through the same pure helper the tests pin.
//
// It also owns the two-tier search the iPhone has: `searchText` is the typed query
// (Tier 1, instant), and `search` is the shared `ThreadSearchModel` that widens the
// match set with on-device query expansion (Tier 2). `searchQueries` unions the two
// exactly as the iPhone does, and feeds the same `threadListLayout`, so searching
// composes with the favorites / archived scopes for free (the layout applies scope
// before the search filter). The expander is injected so tests use a fake and never
// depend on a real on-device model.
struct MacThreadListModel {

    /// Sidebar scope. `.all` is the whole history (date-sectioned, month buckets
    /// rendered as collapsible folders); `.favorites` is just starred conversations
    /// as one flat, newest-first list; `.archived` is just the conversations the user
    /// has hidden from the main list, also flat, and the one place to restore them.
    /// `.all` and `.favorites` both EXCLUDE archived threads. Archive state is
    /// local-first and converged across devices by the bridge flags, matching favorites.
    enum Scope: Hashable {
        case all
        case favorites
        case archived
    }

    var scope: Scope = .all

    /// Month folders the user has opened. Day sections (today / yesterday / the one
    /// weekday) are always expanded; month buckets default collapsed (absent here).
    var expandedFolders: Set<ThreadSection> = []

    /// The live typed query (Tier 1). Not persisted: a fresh launch starts unfiltered.
    var searchText: String = ""

    /// The shared on-device expansion orchestrator (Tier 2): debounce / gate / cache
    /// / cancel, publishing `activeTerms` the layout unions with the typed query. A
    /// reference type, so mutating `searchText`/`scope` on this struct keeps the same
    /// live instance (its `activeTerms` drive the view through Observation).
    let search: ThreadSearchModel

    /// Inject the expander (production: the FoundationModels-backed on-device model,
    /// passed by the view; tests: a fake) plus the Settings-driven enabled flag and,
    /// for tests, a shorter debounce. The default is the INERT `NoExpansion` so the
    /// scope/folder tests that call `MacThreadListModel()` never spin up the real
    /// on-device model, which is unavailable in CI (the search brief requires tests
    /// not to depend on it). This is best-practice, not a crash workaround: the abort
    /// a real expander once caused in a bare test host was the MainActor-isolated
    /// deinit, now fixed at the source (see `FoundationModelExpander` /
    /// `ThreadSearchModel`). The Mac view constructs with `FoundationModelExpander()`.
    init(searchExpander: QueryExpanding = NoExpansion(),
         searchEnabled: Bool = true,
         searchDebounce: Duration = .milliseconds(300)) {
        self.search = ThreadSearchModel(expander: searchExpander,
                                        isEnabled: searchEnabled,
                                        debounce: searchDebounce)
    }

    /// The UNION query list the layout filters on: the typed query plus any active
    /// on-device expansion terms (only while the tier is enabled). With no terms this
    /// is just `[searchText]`, which reduces to Tier-1-only; a blank typed query with
    /// no terms is "search inactive" and the layout shows everything in scope.
    var searchQueries: [String] {
        [searchText] + (search.isEnabled ? search.activeTerms : [])
    }

    /// Build the sidebar layout from the stored threads via the shared pure
    /// function. `.favorites` collapses to the flat starred list; `.archived` to the
    /// flat hidden list; `.all` is the full date-sectioned layout with collapsible
    /// month folders. The union `searchQueries` filters within the active scope
    /// (scope is applied before search), and an active query force-expands every
    /// month folder so no match hides behind a collapsed header. `now`/`calendar` are
    /// injected so classification is deterministic in tests (and read live in the view).
    func layout(_ threads: [JesseThread], now: Date, calendar: Calendar) -> ThreadListLayout {
        threadListLayout(threads,
                         favoritesOnly: scope == .favorites,
                         archivedOnly: scope == .archived,
                         searchQueries: searchQueries,
                         expanded: expandedFolders,
                         now: now,
                         calendar: calendar)
    }

    /// The threads matching the TYPED query alone within the active scope, used only
    /// to gate/feed the expansion tier's base count (mirroring the iPhone's `searched`
    /// off `visible`). Scope is applied first (archive, then favorites) so the count
    /// reflects exactly what the layout will search.
    func baseMatches(_ threads: [JesseThread]) -> [JesseThread] {
        let archiveScoped = threads.filter { scope == .archived ? $0.isArchived : !$0.isArchived }
        let scoped = scope == .favorites ? archiveScoped.filter(\.isFavorite) : archiveScoped
        return scoped.filter { threadMatches($0, query: searchText) }
    }

    /// Feed the live query into the shared expansion model: keep its master switch in
    /// sync with Settings, then debounce/gate/cache/cancel inside the model. The base
    /// count is the Tier-1 hit count for the typed query within scope, so the model
    /// only spends the on-device model when direct results are thin. When the tier is
    /// disabled this is a no-op (pure Tier-1 search, zero `expand` calls). Mutates the
    /// `search` reference, not this struct.
    func updateSearch(_ threads: [JesseThread], enabled: Bool) {
        search.isEnabled = enabled
        search.update(query: searchText, baseMatchCount: baseMatches(threads).count)
    }

    /// Flip the favorites filter (the keyboard-shortcut / segmented-control action).
    mutating func toggleFavoritesScope() {
        scope = (scope == .favorites) ? .all : .favorites
    }

    /// Flip a month folder's expanded state through the shared pure helper, so a
    /// disclosure tap does exactly what the JesseConversations tests pin.
    mutating func toggleFolder(_ section: ThreadSection) {
        expandedFolders = foldersAfterToggling(section, in: expandedFolders)
    }

    /// Star / unstar a conversation. A thin seam over `JesseThread.toggleFavorite`
    /// so the view's star action has one testable entry point; the view persists the
    /// context and best-effort pushes the change to the bridge afterwards (this only
    /// mutates the model object).
    func toggleFavorite(_ thread: JesseThread, now: Date = .now) {
        thread.toggleFavorite(now: now)
    }

    /// Archive / restore a conversation. A thin seam over `JesseThread.toggleArchived`
    /// (stamping/clearing `archivedAt`) so the view's archive action and its keyboard
    /// shortcut share one testable entry point; the view persists the context and
    /// best-effort pushes the change to the bridge afterwards. Local-first, converged
    /// across devices by the bridge flags (last-writer-wins).
    func toggleArchived(_ thread: JesseThread, now: Date = .now) {
        thread.toggleArchived(now: now)
    }
}
