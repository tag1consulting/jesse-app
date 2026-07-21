import Foundation
import JesseCore
import JesseConversations

// The iOS-only search extra that layers on top of the shared match predicate: the
// highlighted matched snippet a search row shows. The pure multi-token match
// predicate itself (`threadMatches`, `threadMatchesAny`, `significantTokens`) lives
// in the shared JesseConversations library, and the expansion-tier orchestration
// (the `shouldExpand` gate, the `ThreadSearchModel`, the on-device expander) now
// lives in the shared JesseSearch library, so iOS and macOS search the same way.
// This file keeps only the row snippet, which is iOS-specific presentation. Still
// Foundation-only and view-free so it stays unit-testable.

// MARK: - Matched snippet (search-only row aid)

/// A windowed excerpt of the text that matched, plus the ranges within `text`
/// that should be highlighted. `ranges` index into `text` (an `AttributedString`
/// built by the view highlights exactly those). Non-empty `ranges` by construction.
struct SearchSnippet: Equatable {
    let text: String
    let ranges: [Range<String.Index>]
}

/// A windowed, highlighted excerpt centered on the FIRST matched token for a row,
/// or nil when the query list is empty/blank (search inactive → no snippet).
///
/// The match is computed against the SAME `queries` the layout filters on (original
/// query + active expansion terms), so a row surfaced only via an expansion term
/// gets a snippet highlighting THAT term — the expansion explains itself. The
/// source is the title when a token matched there, else the first turn body
/// containing a match. A few words of context are kept on each side and the excerpt
/// is ellipsized when it doesn't reach the text's start/end.
func searchSnippet(for thread: JesseThread,
                   queries: [String],
                   contextWords: Int = 4) -> SearchSnippet? {
    let tokens = snippetTokens(from: queries)
    guard !tokens.isEmpty else { return nil }

    // Prefer the title as the source if any token matches there, else the first
    // turn body with a match (turns in chronological order).
    let sources = [thread.title] + thread.orderedTurns.map(\.text)
    for source in sources {
        guard let first = firstMatchRange(in: source, tokens: tokens) else { continue }
        return windowedSnippet(from: source, around: first, tokens: tokens,
                               contextWords: contextWords)
    }
    return nil
}

/// The significant tokens to highlight for a snippet: the >=2-char tokens of each
/// active query entry, or — when an entry is entirely short — that raw entry, so a
/// short search still highlights. Deduped, blanks dropped.
private func snippetTokens(from queries: [String]) -> [String] {
    var out: [String] = []
    for q in queries {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let toks = significantTokens(trimmed)
        let pieces = toks.isEmpty ? [trimmed] : toks.map(String.init)
        for p in pieces where !out.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
            out.append(p)
        }
    }
    return out
}

/// The earliest range in `text` matched by any token (case/diacritic-insensitive).
private func firstMatchRange(in text: String, tokens: [String]) -> Range<String.Index>? {
    var earliest: Range<String.Index>?
    for token in tokens {
        if let r = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
            if earliest == nil || r.lowerBound < earliest!.lowerBound {
                earliest = r
            }
        }
    }
    return earliest
}

/// Build the windowed excerpt around `match` in `source`, keeping `contextWords`
/// whole words on each side, ellipsizing when the window doesn't reach an end, and
/// re-locating every token's range within the produced excerpt for highlighting.
private func windowedSnippet(from source: String,
                             around match: Range<String.Index>,
                             tokens: [String],
                             contextWords: Int) -> SearchSnippet {
    // Word boundaries around the match, expanded by `contextWords` on each side.
    let (lo, hi, atStart, atEnd) = windowBounds(in: source, around: match,
                                                contextWords: contextWords)
    var excerpt = String(source[lo..<hi])
    if !atStart { excerpt = "…" + excerpt }
    if !atEnd { excerpt = excerpt + "…" }

    // Highlight every token occurrence within the produced excerpt.
    var ranges: [Range<String.Index>] = []
    for token in tokens {
        var searchStart = excerpt.startIndex
        while searchStart < excerpt.endIndex,
              let r = excerpt.range(of: token,
                                    options: [.caseInsensitive, .diacriticInsensitive],
                                    range: searchStart..<excerpt.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
    }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    return SearchSnippet(text: excerpt, ranges: ranges)
}

/// Compute the character bounds of a snippet window: starting from the match, walk
/// out `contextWords` whitespace-separated words on each side. Returns the bounds
/// and whether each side reached the text's true start/end (so the caller knows
/// whether to ellipsize).
private func windowBounds(in source: String,
                          around match: Range<String.Index>,
                          contextWords: Int) -> (String.Index, String.Index, Bool, Bool) {
    // Walk left from the match's lower bound over `contextWords` words.
    var lo = match.lowerBound
    var wordsLeft = contextWords
    while lo > source.startIndex {
        let prev = source.index(before: lo)
        // Skip a run of whitespace, then a run of non-whitespace = one word.
        if source[prev].isWhitespace {
            // At a whitespace boundary: consuming another word costs one budget.
            if wordsLeft == 0 { break }
            wordsLeft -= 1
            // Skip contiguous whitespace.
            var i = prev
            while i > source.startIndex && source[source.index(before: i)].isWhitespace {
                i = source.index(before: i)
            }
            lo = i
        } else {
            lo = prev
        }
    }

    // Walk right from the match's upper bound over `contextWords` words.
    var hi = match.upperBound
    var wordsRight = contextWords
    while hi < source.endIndex {
        if source[hi].isWhitespace {
            if wordsRight == 0 { break }
            wordsRight -= 1
            var i = hi
            while i < source.endIndex && source[i].isWhitespace {
                i = source.index(after: i)
            }
            hi = i
        } else {
            hi = source.index(after: hi)
        }
    }

    let atStart = lo == source.startIndex
    let atEnd = hi == source.endIndex
    return (lo, hi, atStart, atEnd)
}
