import Foundation
import JesseCore
import JesseNetworking

// The iPhone's binding of one `TurnArtifact` to bytes on disk.
//
// Everything that decides anything — the cache lookup, the download, the PERMANENT
// expired verdict, and the wording of every failure — lives in `ArtifactResolver`
// (JesseNetworking), shared with the Mac. This type is the two things that genuinely
// differ per app: WHICH client protocol does the fetch, and the fact that iOS records the
// verdict on a SwiftData row.

/// Resolves a `TurnArtifact` to bytes on disk, through the cache first and the bridge
/// second.
@MainActor
struct ArtifactLoader {
    /// Where bytes are cached, with the device-side LRU cap. `nil` (no caches directory
    /// at all) degrades to downloading every time rather than failing — the bytes are
    /// always re-fetchable.
    let cache: ArtifactCache?
    /// Builds the bridge client for the current configuration, or `nil` when the app is
    /// not paired. The iOS client seam, not the shared one, so a test can inject the same
    /// fake every other coordinator test uses.
    let makeClient: @MainActor () -> (any JesseClientProtocol)?

    init(cache: ArtifactCache? = ArtifactCache.standard(),
         makeClient: @escaping @MainActor () -> (any JesseClientProtocol)?) {
        self.cache = cache
        self.makeClient = makeClient
    }

    /// Resolve one artifact.
    ///
    /// On the permanent verdict this WRITES `artifact.isExpired`, which is what stops the
    /// next render from re-fetching a dead id. The caller persists it.
    func load(_ artifact: TurnArtifact) async -> ArtifactLoadState {
        guard let client = makeClient() else {
            // Not paired. Still go through the resolver, so a file this device already
            // downloaded is shown from the cache rather than hidden behind a settings
            // error it has no need for.
            return await ArtifactResolver.resolve(
                id: artifact.artifactID, mime: artifact.mime, byteCount: artifact.byteCount,
                filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
                fetch: { _ in throw ArtifactFetchError.notConfigured })
        }
        let state = await ArtifactResolver.resolve(
            id: artifact.artifactID, mime: artifact.mime, byteCount: artifact.byteCount,
            filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
            fetch: { try await client.artifact(id: $0) })
        if case .expired = state { artifact.isExpired = true }
        return state
    }
}
