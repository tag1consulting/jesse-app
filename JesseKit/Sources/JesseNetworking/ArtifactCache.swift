import Foundation

/// The DEVICE's own budget for files Jesse returned.
///
/// The bridge bounds what it stores (a per-turn cap, a 30-day TTL, a 2 GB high-water
/// mark). None of that bounds the phone: a device that opens every chart in a busy month
/// would accumulate them forever, in a cache directory nobody ever looks at. So this is
/// the third budget, and it is deliberately not derived from the other two — a phone has
/// far less room than the laptop running the bridge, and the numbers should be allowed to
/// differ.
///
/// # Why the bytes live here and not in SwiftData
///
/// `TurnArtifact` stores metadata plus this cache's file name, never the content. A 20 MB
/// PDF inside the store would be loaded into memory on every fetch of the turn that owns
/// it — including every scroll that touches the row — which is exactly the cost the
/// bridge's metadata-only wire was designed to avoid, undone one layer down. A cache
/// directory is also the right *lifetime*: the OS may reclaim it under storage pressure,
/// and every file in it is re-fetchable from the bridge by id.
///
/// # Eviction
///
/// Least-recently-used, evaluated after every download. "Recently used" is the file's
/// modification date, which [`touch`](Self.touch(_:)) bumps on every cache hit — so a
/// file the user keeps opening survives and one they downloaded once in March does not.
public struct ArtifactCache: Sendable {
    /// Where cached bytes live. One flat directory: the file name IS the bridge's
    /// artifact id, which the bridge guarantees is lowercase hex and this type
    /// re-validates, so no name can escape the directory.
    public let directory: URL

    /// The device-side high-water mark. Over it, least-recently-used files are removed
    /// until the total is back under.
    public let maxBytes: Int

    /// 256 MB. Large enough that a normal week of charts and exports never evicts, small
    /// enough that it cannot become the reason a phone runs out of room.
    public static let defaultMaxBytes = 256 * 1024 * 1024

    public init(directory: URL, maxBytes: Int = ArtifactCache.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// The cache in the platform caches directory. `nil` only if the OS gives us no
    /// caches directory at all, in which case the app degrades to "download every time"
    /// rather than failing — the bytes are always re-fetchable.
    public static func standard(maxBytes: Int = ArtifactCache.defaultMaxBytes) -> ArtifactCache? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return ArtifactCache(directory: base.appendingPathComponent("JesseArtifacts", isDirectory: true),
                             maxBytes: maxBytes)
    }

    /// Whether an id is safe as a file name: non-empty lowercase hex within a sane
    /// length. THE SAME GUARD THE BRIDGE APPLIES, applied again here rather than trusted,
    /// because this one is what turns a string into a path on this device.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The on-disk location for an id, or `nil` if the id is not a safe file name.
    public func url(for id: String) -> URL? {
        guard Self.isValidID(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: false)
    }

    /// A cached copy, if there is one whose size matches what the metadata says.
    ///
    /// The size check is not paranoia about the bridge — it catches a **truncated write**,
    /// which is what a cache file left behind by a crash or a full disk looks like.
    /// Hashing would be stronger and is deliberately not done on this path: it would mean
    /// reading every byte of a 20 MB file on every appearance of the row, to re-verify
    /// bytes this device itself wrote.
    ///
    /// A hit bumps the file's modification date, which is what makes eviction LRU rather
    /// than "oldest download first".
    public func cached(id: String, expectedBytes: Int) -> URL? {
        guard let url = url(for: id) else { return nil }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == expectedBytes else { return nil }
        touch(url)
        return url
    }

    /// Write bytes for an id and return where they landed, then bring the cache back
    /// under its cap. Throws only if the directory or the file cannot be written.
    @discardableResult
    public func store(id: String, data: Data) throws -> URL {
        guard let url = url(for: id) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        evictIfNeeded()
        return url
    }

    /// Remove one cached file (a no-op if it was never there).
    public func remove(id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Total bytes currently held.
    public func totalBytes() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Bring the cache under `maxBytes` by removing least-recently-used files first.
    /// Called after every download; safe to call at any time.
    public func evictIfNeeded() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        // Oldest access first, so the file the user keeps opening is the last to go.
        all.sort { $0.accessed < $1.accessed }
        for entry in all {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Every cached file with its size and last-use date.
    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize else { return nil }
            return Entry(url: url, size: size, accessed: v.contentModificationDate ?? .distantPast)
        }
    }

    /// Mark a file as just used, so LRU eviction reflects reading and not only writing.
    /// Best-effort: a cache whose dates cannot be updated evicts by write order instead,
    /// which is a worse policy but never a wrong one.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private struct Entry {
        let url: URL
        let size: Int
        let accessed: Date
    }
}

// ---- Resolving one artifact to bytes on disk -------------------------------
//
// The cache lookup, the download, and the PERMANENT expired verdict, in one place both
// apps share. They cannot share a loader type — each holds a different client protocol
// (the Mac's `BridgeClientProtocol`, the iPhone's `JesseClientProtocol`) — but the RULES
// are identical, and rules duplicated across two apps are rules that drift.

/// What a view needs to render one returned file.
public enum ArtifactLoadState: Equatable, Sendable {
    /// Not asked for yet. The download is lazy — on first display, never on delivery —
    /// because a thread may hold dozens of files the user never opens, each a real
    /// network round trip.
    case idle
    case loading
    /// Bytes are on disk at this URL, ready for an image, QuickLook, or a share sheet.
    case ready(URL)
    /// PERMANENTLY gone from the bridge. Renders as "expired" and is NEVER retried.
    case expired
    /// A transient failure, with something the user can act on. Retryable.
    case failed(String)
}

public enum ArtifactResolver {
    /// Resolve one artifact to bytes on disk: cache first, `fetch` second.
    ///
    /// # Why the expired verdict has to stick
    ///
    /// The bridge's store is bounded — a 30-day TTL, a 2 GB high-water mark, and a
    /// cascade when a conversation is deleted — so an artifact in an old thread WILL
    /// eventually stop existing. The route says so precisely: a `404` whose reason is
    /// `expired` means "this was stored and is gone", and no retry brings it back.
    ///
    /// A caller that treats that as an ordinary failure re-downloads on every appearance
    /// of the row: every scroll into view, every relaunch, forever, for a file that will
    /// never be there. So `.expired` comes back exactly once from a live fetch, and the
    /// caller is expected to persist it and pass `isExpired: true` from then on.
    ///
    /// `unknown` is deliberately NOT sticky: it can also mean the device is pointed at a
    /// different bridge, which is a configuration problem the user can fix rather than a
    /// fact about the file.
    ///
    /// - Parameter isExpired: whether the caller has already recorded the permanent
    ///   verdict for this artifact. A cached copy still wins over it — the file is right
    ///   here, and "the bridge no longer has it" is no reason to refuse to show what this
    ///   device already downloaded.
    public static func resolve(
        id: String,
        byteCount: Int,
        filename: String,
        isExpired: Bool,
        cache: ArtifactCache?,
        // `@Sendable` because both callers are `@MainActor` and this function is not:
        // the closure crosses that boundary. It only ever captures the app's client,
        // which is itself `Sendable`, so this costs nothing and states the fact.
        fetch: @Sendable (String) async throws -> Data
    ) async -> ArtifactLoadState {
        if let url = cache?.cached(id: id, expectedBytes: byteCount) {
            return .ready(url)
        }
        if isExpired { return .expired }
        do {
            let data = try await fetch(id)
            guard let cache else {
                // No caches directory at all: write to a temporary file so the viewer
                // still has a URL. Reclaimed by the OS like any other temp file, and the
                // bytes are always re-fetchable.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(sanitizedTempName(id), isDirectory: false)
                try data.write(to: tmp, options: .atomic)
                return .ready(tmp)
            }
            return .ready(try cache.store(id: id, data: data))
        } catch ArtifactFetchError.expired {
            return .expired
        } catch let error as ArtifactFetchError {
            return .failed(message(for: error, filename: filename))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A one-line, actionable reason. Never a bare status code: the user's question is
    /// always "can I do something about this?"
    public static func message(for error: ArtifactFetchError, filename: String) -> String {
        switch error {
        case .notConfigured:
            return "Set the bridge host and token in Settings."
        case .unreachable(let host):
            return "Couldn't reach \(host)."
        case .authFailed:
            return "The bridge rejected the token — check it in Settings."
        case .unknown:
            return "The bridge doesn't have \(filename). It may have been produced by a different bridge."
        case .expired:
            return "\(filename) is no longer stored on the bridge."
        case .decodeFailed:
            return "Couldn't read \(filename)."
        case .server(let code):
            return "The bridge returned \(code) for \(filename)."
        }
    }

    /// The no-cache fallback still turns an id into a path, so it gets the same guard the
    /// cache applies rather than trusting the id because it came from the bridge.
    private static func sanitizedTempName(_ id: String) -> String {
        ArtifactCache.isValidID(id) ? id : "jesse-artifact"
    }
}
