import Foundation
import JesseCore

// Pure, SwiftUI-free search matching for the thread list. Kept Foundation-only so
// the predicates are unit-testable without a view host, mirroring ThreadSectioning.
//
// Matching is MULTI-TOKEN and order-independent (Tier 1): the trimmed query is
// split on whitespace and a thread matches when EVERY token appears somewhere in
// its title OR any turn body — case- and diacritic-insensitively
// (`localizedStandardContains`, so "cafe" finds "Café"). Tokens are matched
// field-agnostically (one token may land in the title while another lands in a
// turn) and gap-independently ("run bridge" finds "run over the bridge"). A blank
// query (empty or whitespace only) matches everything — search is inactive.
//
// On top of that sits a thin union predicate (`threadMatchesAny`) so the view can
// widen the match set with alternate query terms (the on-device expansion tier).
// It is ADDITIVE — it only ever widens the set the base matcher would return. The
// on-device expansion ORCHESTRATION (gating, the model call, snippets) lives in the
// iOS target; only the pure predicate that both apps' layouts filter on lives here.

/// Tokens (length >= 2) of a trimmed query, lowercased for length checks only —
/// matching itself stays diacritic/case-insensitive via `localizedStandardContains`.
public func significantTokens(_ trimmed: String) -> [Substring] {
    trimmed.split(whereSeparator: \.isWhitespace).filter { $0.count >= 2 }
}

/// Whether `thread` matches the search `query`, over its title and turn bodies.
///
/// The trimmed query is tokenized on whitespace; the thread matches when every
/// token (ignoring tokens shorter than 2 characters) is found — order- and
/// gap-independent, field-agnostic. If EVERY token is short (e.g. "hi"), the raw
/// trimmed query is matched instead, so a deliberate short search still works. A
/// blank query matches everything (search inactive).
public func threadMatches(_ thread: JesseThread, query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // A blank query is "search inactive": everything matches.
    guard !needle.isEmpty else { return true }

    let tokens = significantTokens(needle)
    // All tokens short → fall back to matching the raw trimmed query as one needle,
    // so a deliberate short search like "hi" isn't silently dropped.
    guard !tokens.isEmpty else {
        return fieldsContain(thread, String(needle))
    }
    // Every significant token must appear somewhere (title or any turn body).
    return tokens.allSatisfy { fieldsContain(thread, String($0)) }
}

/// Whether `needle` appears in the thread's title or any turn body,
/// case/diacritic-insensitively.
private func fieldsContain(_ thread: JesseThread, _ needle: String) -> Bool {
    if thread.title.localizedStandardContains(needle) { return true }
    return thread.turns.contains { $0.text.localizedStandardContains(needle) }
}

/// Whether `thread` matches ANY of the given `queries` via the multi-token
/// `threadMatches`. Each entry may itself be multi-word (the original query OR an
/// expansion term). Blank/empty entries are ignored; an empty list (or all-blank)
/// matches everything — search inactive, preserving today's semantics.
///
/// This is the UNION widen point for the expansion tier: with a single entry it
/// reduces exactly to `threadMatches(_:query:)`, so expansion is strictly additive.
public func threadMatchesAny(_ thread: JesseThread, queries: [String]) -> Bool {
    let active = queries.filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !active.isEmpty else { return true }
    return active.contains { threadMatches(thread, query: $0) }
}
