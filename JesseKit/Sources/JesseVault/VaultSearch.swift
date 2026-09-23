import Foundation

// WHAT A TYPED QUERY MEANS, over 7,600 notes.
//
// The rule is the conversation list's rule, because a person searching this app should
// not have to hold two of them: the query is split on whitespace, every token must
// appear, and order does not matter (`SearchQueryRules.significantTokens`). Two things
// are added here, and both are about a vault rather than a chat log:
//
//   * EVERY TOKEN IS A PREFIX TERM. Notes are written in whole words that a searcher
//     half-remembers — "perse" has to find Perseido, and "andrew" has to find Andrews —
//     and an inverted index can answer a prefix without a scan, which a substring match
//     cannot.
//   * A NAME MATCH OUTRANKS A BODY MATCH. Searching a person's surname in this vault
//     means "their file", and bm25 alone will happily rank a passing mention in a long
//     meeting note above the file named after them. The rule is stated over the tokens
//     as typed, which is why it is applied here and not in SQL.
//
// The expansion tier is the SAME one the conversation list uses, gated by the same
// `shouldExpand`, and it is strictly ADDITIVE: alternate terms can only add hits, never
// remove or reorder the ones the typed query found. A caption says when they contributed,
// because a result nobody can account for reads as a bug.

/// The pure query rules: what goes to FTS5, and how what comes back is ordered.
public enum VaultSearchQuery {

    /// The FTS5 MATCH expression for a query, or nil when there is nothing to search for.
    ///
    /// Every token becomes a quoted prefix term joined by `AND`, so all of them are
    /// required. Quoting is what makes an apostrophe, a hyphen or a slash in a token
    /// harmless: unquoted, FTS5 would read them as its own operators and answer a syntax
    /// error for a perfectly reasonable search.
    public static func matchExpression(_ query: String) -> String? {
        let terms = tokens(query)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\(escaped($0))\"*" }.joined(separator: " AND ")
    }

    /// The tokens of a query, as FTS5 can use them.
    ///
    /// `SearchQueryRules.significantTokens` first, so the vault and the chat list agree on
    /// what a token is, then two vault-specific filters: punctuation is trimmed off each
    /// end, and a token with no letter or digit left in it is dropped. A query of `--`
    /// must come back as "nothing to search for" rather than as an FTS5 syntax error.
    public static func tokens(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = SearchQueryRules.significantTokens(trimmed).map(String.init)
        // A query whose every token is shorter than two characters still deserves an
        // answer, exactly as it does in the conversation list.
        if raw.isEmpty, !trimmed.isEmpty { raw = [trimmed] }
        return raw.compactMap { token in
            let cleaned = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return cleaned
        }
    }

    /// A double quote inside a quoted FTS5 term is escaped by doubling it.
    static func escaped(_ token: String) -> String {
        token.replacingOccurrences(of: "\"", with: "\"\"")
    }

    /// Whether a hit's own file NAMES what was searched for: its title or its path
    /// contains every token.
    ///
    /// `localizedStandardContains`, so it folds case and diacritics the same way the
    /// conversation matcher does and the same way the index's own tokenizer does.
    public static func isNameMatch(title: String, path: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy {
            title.localizedStandardContains($0) || path.localizedStandardContains($0)
        }
    }

    /// The final order: name matches first, each group by weighted bm25 (lower is
    /// better), ties broken by path so the order is stable between two runs.
    ///
    /// `isNameMatch` is stamped onto each hit on the way through, so the row can say why
    /// it is at the top.
    public static func ranked(_ hits: [VaultSearchHit], tokens: [String],
                              limit: Int = 50) -> [VaultSearchHit] {
        let stamped = hits.map { hit -> VaultSearchHit in
            var copy = hit
            copy.isNameMatch = isNameMatch(title: hit.title, path: hit.path, tokens: tokens)
            return copy
        }
        let ordered = stamped.sorted { a, b in
            if a.isNameMatch != b.isNameMatch { return a.isNameMatch }
            if a.score != b.score { return a.score < b.score }
            if a.path != b.path { return a.path < b.path }
            return a.line < b.line
        }
        return Array(ordered.prefix(limit))
    }

    /// One hit per FILE, keeping its best-ranked chunk.
    ///
    /// A long note with the query in six sections would otherwise fill the whole result
    /// list with itself and bury five other notes that also answer the question.
    public static func collapsedByFile(_ hits: [VaultSearchHit]) -> [VaultSearchHit] {
        var seen = Set<String>()
        var out: [VaultSearchHit] = []
        for hit in hits where !seen.contains(hit.path) {
            seen.insert(hit.path)
            out.append(hit)
        }
        return out
    }
}

/// What one search produced, and what it took to get there.
public struct VaultSearchOutcome: Equatable, Sendable {
    public let hits: [VaultSearchHit]
    /// The expansion terms that actually contributed a hit the typed query did not find.
    /// Empty when the tier was gated off, dry, or unnecessary.
    public let expansionTerms: [String]
    /// The base query's own latency, which is the number the target is stated against.
    public let baseDuration: TimeInterval

    public init(hits: [VaultSearchHit], expansionTerms: [String] = [],
                baseDuration: TimeInterval = 0) {
        self.hits = hits
        self.expansionTerms = expansionTerms
        self.baseDuration = baseDuration
    }

    /// The caption a screen shows under the field when expansion widened the results.
    /// Nil when nothing was added, so the row can be hidden rather than emptied.
    public var expansionCaption: String? {
        guard !expansionTerms.isEmpty else { return nil }
        return "Also searched: " + expansionTerms.joined(separator: ", ")
    }
}

/// Search over one index. A value, so a caller holds it wherever it holds the index.
public struct VaultSearcher: Sendable {
    private let index: VaultIndex
    /// The hit count at or above which the expansion tier is not worth spending. Five,
    /// the conversation list's own threshold.
    private let expansionThreshold: Int
    private let limit: Int

    public init(index: VaultIndex, expansionThreshold: Int = 5, limit: Int = 50) {
        self.index = index
        self.expansionThreshold = expansionThreshold
        self.limit = limit
    }

    /// The typed query alone — no model, no expansion. This is the call whose latency the
    /// under-100-ms target is about.
    public func base(_ query: String) -> VaultSearchOutcome {
        let started = Date()
        let tokens = VaultSearchQuery.tokens(query)
        guard let expression = VaultSearchQuery.matchExpression(query) else {
            return VaultSearchOutcome(hits: [], baseDuration: 0)
        }
        // Ask for more rows than will be shown, because collapsing to one hit per file
        // and re-ranking both happen after SQL: taking exactly `limit` from SQLite would
        // mean a file's second-best chunk crowding out another file's only one.
        let raw = index.search(expression: expression, limit: limit * 4)
        let ranked = VaultSearchQuery.ranked(VaultSearchQuery.collapsedByFile(raw),
                                             tokens: tokens, limit: limit)
        return VaultSearchOutcome(hits: ranked,
                                  baseDuration: Date().timeIntervalSince(started))
    }

    /// The typed query, widened by the on-device expander when — and only when — the
    /// gate says it is worth it.
    ///
    /// The union is ordered so that nothing the typed query found can be displaced: base
    /// hits keep their order, expansion hits follow.
    public func search(_ query: String, expander: any VaultQueryExpanding) async
        -> VaultSearchOutcome {
        let outcome = base(query)
        guard SearchQueryRules.shouldExpand(query: query,
                                            baseMatchCount: outcome.hits.count,
                                            threshold: expansionThreshold) else {
            return outcome
        }
        let alternates = await expander.expand(query)
        guard !alternates.isEmpty else { return outcome }

        var seen = Set(outcome.hits.map(\.path))
        var added: [VaultSearchHit] = []
        var contributed: [String] = []
        for term in alternates {
            let widened = base(term).hits.filter { !seen.contains($0.path) }
            guard !widened.isEmpty else { continue }
            contributed.append(term)
            for hit in widened {
                seen.insert(hit.path)
                added.append(hit)
            }
        }
        return VaultSearchOutcome(hits: Array((outcome.hits + added).prefix(limit)),
                                  expansionTerms: contributed,
                                  baseDuration: outcome.baseDuration)
    }
}
