import Foundation

// Pure, SwiftUI-free search matching for the thread list. Kept in its own file
// (Foundation only) so the predicate is unit-testable without a view host,
// mirroring ThreadSectioning.
//
// A conversation matches a query when the query appears in its title OR in the
// text of any of its turns. Matching is case- and diacritic-insensitive
// (`localizedStandardContains`), so "cafe" finds "Café". A blank query (empty
// or whitespace only) matches everything — search is inactive, the full list
// shows.

/// Whether `thread` matches the search `query`, over its title and turn bodies.
func threadMatches(_ thread: JesseThread, query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // A blank query is "search inactive": everything matches.
    guard !needle.isEmpty else { return true }
    if thread.title.localizedStandardContains(needle) { return true }
    return thread.turns.contains { $0.text.localizedStandardContains(needle) }
}
