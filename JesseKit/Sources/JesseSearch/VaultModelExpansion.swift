import Foundation
import JesseVault

// THE ONE ADAPTER, so the vault search and the conversation search share one on-device
// model session rather than opening two.
//
// `FoundationModelExpander` is this target's `QueryExpanding` — the only file in the app
// that imports FoundationModels — and the vault search asks for its alternates through
// `VaultQueryExpanding`, declared in JesseVault because that target cannot import this one
// (it depends on nothing, deliberately; see its `Package.swift` comment).
//
// This is the whole bridge between the two: a value that holds the expander and forwards.
// It is typed to the CONCRETE expander rather than to `any QueryExpanding` for a reason
// worth writing down — `QueryExpanding` is MainActor-isolated under this target's default
// isolation and its existential is therefore not `Sendable`, so an adapter over `any
// QueryExpanding` could not cross into the detached task the vault search runs in.
// `FoundationModelExpander` is a `@MainActor` class and so is `Sendable`, which is what
// makes this legal at all.

/// The app's on-device expander, as the vault search tier's seam.
public struct VaultModelExpansion: VaultQueryExpanding {
    private let expander: FoundationModelExpander

    public init(_ expander: FoundationModelExpander) {
        self.expander = expander
    }

    /// Forwards, hopping to the main actor where the session lives. Total, like the
    /// protocol it satisfies: an unavailable model comes back as `[]`, never as a throw.
    public func expand(_ query: String) async -> [String] {
        await expander.expand(query)
    }
}
