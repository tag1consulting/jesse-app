import Foundation

// The query-expansion seam (Tier 2, framework-agnostic half). Kept Foundation-only
// and free of any model import so the orchestration model and its tests never pull
// in FoundationModels, mirroring how JesseClientProtocol isolates the network.
//
// A `QueryExpanding` turns one search query into a handful of alternate search
// terms (synonyms, rephrasings, more/less specific variants). It is deliberately
// TOTAL: it NEVER throws to the caller. Unavailable, disabled, or failed all
// collapse to `[]`, so the search tier above can treat "no expansion" and "the
// model isn't here" identically and degrade silently to the multi-token base match.

// Under the package's MainActor-default isolation this protocol (and its
// conformers) are main-actor-isolated; `expand` is `async` so it still suspends,
// letting a query change cancel an in-flight expansion, without blocking the list.
public protocol QueryExpanding {
    /// Alternate search terms for `query`. Returns `[]` when expansion is
    /// unavailable or fails, never throws.
    func expand(_ query: String) async -> [String]

    /// Warm any expensive backing resource (e.g. an on-device model session) ahead
    /// of the first real query, called when the search field gains focus. Optional:
    /// the default does nothing, so a fake/plain expander needn't implement it.
    func prewarm()
}

extension QueryExpanding {
    public func prewarm() {}
}

/// The inert expander: always returns no alternate terms, so a `ThreadSearchModel`
/// built on it is pure Tier-1 (the typed query only). It is the safe default when a
/// real on-device expander shouldn't be constructed, e.g. SwiftUI previews and the
/// list-model unit tests, which must not instantiate the FoundationModels-backed
/// expander (a real model is unavailable there). Production injects
/// `FoundationModelExpander` explicitly.
public struct NoExpansion: QueryExpanding {
    public init() {}
    public func expand(_ query: String) async -> [String] { [] }
}
