import Foundation
import JesseCore

// Pure, SwiftUI-free origin scoping for the thread list. Kept in its own file
// (Foundation only) so the predicate is unit-testable without a view host,
// mirroring ThreadSectioning / ThreadSearch.
//
// The list can be scoped by where a thread originated. `.all` is the default —
// every thread shows, the scope is inactive. `.watch` narrows to conversations
// relayed from an Apple Watch (`origin == .watch`), so watch-originated turns can
// be found on their own. The scope is an ADDITIVE filter: it composes with the
// Favorites filter and the search query (each narrows further) and is applied
// BEFORE date grouping, so results stay date-sectioned exactly like the others.

/// Which origin the list is scoped to. `.all` matches everything (scope inactive);
/// `.watch` matches only watch-originated threads.
enum ThreadOriginScope {
    case all
    case watch
}

/// Whether `thread` belongs in `scope`. `.all` always matches (the scope is
/// inactive — show everything, like a blank search query); `.watch` matches only a
/// thread whose `originValue` is `.watch`. Pure and Foundation-only so it composes
/// before grouping and is tested directly, mirroring `threadMatches`.
func threadMatchesOrigin(_ thread: JesseThread, scope: ThreadOriginScope) -> Bool {
    switch scope {
    case .all:
        return true
    case .watch:
        return thread.originValue == .watch
    }
}
