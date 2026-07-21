import Foundation
import JesseCore
import JesseConversations

// The Mac sidebar's pure list seam. It wraps the shared `threadListLayout` so the
// Mac list is grouped / favorited / date-sectioned by exactly the same code the
// iPhone drives its list from (never a bare @Query sort), and so the wiring is
// unit-testable without a view host: switching `scope` flips the layout between
// the full sectioned view and the flat favorites view, and `expandedFolders`
// drives month-folder disclosure through the same pure helper the tests pin.
struct MacThreadListModel {

    /// Sidebar scope. `.all` is the whole history (date-sectioned, month buckets
    /// rendered as collapsible folders); `.favorites` is just starred conversations
    /// as one flat, newest-first list; `.archived` is just the conversations the user
    /// has hidden from the main list, also flat, and the one place to restore them.
    /// `.all` and `.favorites` both EXCLUDE archived threads. Archive state is local
    /// to this device's store, never synced through the bridge, matching favorites.
    enum Scope: Hashable {
        case all
        case favorites
        case archived
    }

    var scope: Scope = .all

    /// Month folders the user has opened. Day sections (today / yesterday / the one
    /// weekday) are always expanded; month buckets default collapsed (absent here).
    var expandedFolders: Set<ThreadSection> = []

    /// Build the sidebar layout from the stored threads via the shared pure
    /// function. `.favorites` collapses to the flat starred list; `.all` is the full
    /// date-sectioned layout with collapsible month folders. `now`/`calendar` are
    /// injected so classification is deterministic in tests (and read live in the
    /// view). No search on the Mac sidebar yet, so the query list is empty.
    func layout(_ threads: [JesseThread], now: Date, calendar: Calendar) -> ThreadListLayout {
        threadListLayout(threads,
                         favoritesOnly: scope == .favorites,
                         archivedOnly: scope == .archived,
                         searchQueries: [],
                         expanded: expandedFolders,
                         now: now,
                         calendar: calendar)
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
    /// context afterwards (this only mutates the model object).
    func toggleFavorite(_ thread: JesseThread, now: Date = .now) {
        thread.toggleFavorite(now: now)
    }

    /// Archive / restore a conversation. A thin seam over `JesseThread.toggleArchived`
    /// (stamping/clearing `archivedAt`) so the view's archive action and its keyboard
    /// shortcut share one testable entry point; the view persists the context
    /// afterwards. Local only: archive state is never synced through the bridge.
    func toggleArchived(_ thread: JesseThread, now: Date = .now) {
        thread.toggleArchived(now: now)
    }
}
