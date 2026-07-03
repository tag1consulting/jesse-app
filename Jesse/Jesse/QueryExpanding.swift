import Foundation

// The query-expansion seam (Tier 2, framework-agnostic half). Kept Foundation-only
// and free of any model import so the orchestration model and its tests never pull
// in FoundationModels — mirroring how JesseClientProtocol isolates the network.
//
// A `QueryExpanding` turns one search query into a handful of alternate search
// terms (synonyms, rephrasings, more/less specific variants). It is deliberately
// TOTAL: it NEVER throws to the caller. Unavailable, disabled, or failed all
// collapse to `[]`, so the search tier above can treat "no expansion" and "the
// model isn't here" identically and degrade silently to the multi-token base match.

// Under the project's MainActor-default isolation this protocol (and its
// conformers) are main-actor-isolated; `expand` is `async` so it still suspends —
// letting a query change cancel an in-flight expansion — without blocking the list.
protocol QueryExpanding {
    /// Alternate search terms for `query`. Returns `[]` when expansion is
    /// unavailable or fails — never throws.
    func expand(_ query: String) async -> [String]

    /// Warm any expensive backing resource (e.g. an on-device model session) ahead
    /// of the first real query, called when the search field gains focus. Optional —
    /// the default does nothing, so a fake/plain expander needn't implement it.
    func prewarm()
}

extension QueryExpanding {
    func prewarm() {}
}
