import Foundation

/// The last-good body of a read endpoint, on disk, so a COLD LAUNCH WITH NO NETWORK
/// still has something true to draw.
///
/// # Why this exists at all
///
/// Today and Health are pure renders of two `GET`s. Before this, both kept their last
/// answer in memory only: a refresh that failed never blanked the screen, but a launch
/// that failed had nothing to keep. Kill the app on a plane and the day you read an hour
/// ago is gone — a spinner, or an error, for data the device had already been given.
/// This is the one thing that fixes that, and it fixes it for both tabs and both
/// platforms at once.
///
/// # Why it stores BYTES and not the decoded models
///
/// `TodaySnapshot` and `DietSnapshot` are `Decodable` only, and deliberately so: nearly
/// every type in them has a hand-written `init(from:)` that tolerates a missing or
/// renamed field rather than failing the whole document. Adding `Encodable` would mean
/// hand-writing the mirror of each of those and keeping the two in step forever — a
/// second, silent definition of the wire format, which is exactly the class of drift
/// this package was carved out to end. Storing the bridge's own response body means the
/// cached document is decoded by the SAME decoder the live one is, so a cache hit and a
/// `200` cannot disagree about what the day says.
///
/// # Why Application Support and not the caches directory
///
/// `ArtifactCache` lives in `.cachesDirectory` because every byte in it is re-fetchable
/// on demand and the OS is welcome to reclaim it. This one is the opposite: it is only
/// ever read when the bridge CANNOT be reached, so the moment the OS reclaims it is the
/// moment it was needed. It is small (two documents), self-evicting, and excluded from
/// backup — but it is not disposable.
///
/// # Eviction
///
/// Age first, then count, least-recently-written first, evaluated after every write. A
/// day file older than `maxAge` is not "stale data to label", it is a different month;
/// it is dropped rather than rendered behind a banner.
public struct SnapshotCache: Sendable {
    /// Where the cached bodies live.
    public let directory: URL

    /// The most entries to keep. Today is one, the live diet day is one, and the rest
    /// are days the user paged back to — a handful, and no reason for more.
    public let maxEntries: Int

    /// How old an entry may be before it is dropped unread.
    public let maxAge: TimeInterval

    /// 12 entries: the two live documents plus ten paged-back days.
    public static let defaultMaxEntries = 12

    /// 30 days. Past that, a cached day is history rather than "the last thing you were
    /// looking at", and the honest screen is the empty one.
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60

    public init(directory: URL,
                maxEntries: Int = SnapshotCache.defaultMaxEntries,
                maxAge: TimeInterval = SnapshotCache.defaultMaxAge) {
        self.directory = directory
        self.maxEntries = maxEntries
        self.maxAge = maxAge
    }

    /// The cache in this app's Application Support directory. `nil` only if the OS
    /// gives us no such directory, in which case both tabs degrade to exactly the
    /// behavior they had before this existed rather than failing.
    public static func standard(maxEntries: Int = SnapshotCache.defaultMaxEntries,
                               maxAge: TimeInterval = SnapshotCache.defaultMaxAge) -> SnapshotCache? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return SnapshotCache(directory: base.appendingPathComponent("JesseSnapshots", isDirectory: true),
                             maxEntries: maxEntries, maxAge: maxAge)
    }

    /// The one cache the app's two browsable tabs share, resolved once.
    ///
    /// A single instance rather than a `standard()` call at each use site so the writer
    /// (the client, inside a fetch) and the reader (the display model, at launch) cannot
    /// end up pointed at different directories after a refactor. `nil` on a device with
    /// no Application Support directory, which degrades both tabs to their pre-cache
    /// behavior rather than failing.
    public static let shared: SnapshotCache? = .standard()

    // MARK: - Keys

    /// Whether a key is safe as a file name. Keys are ours (`today`, `diet-2026-08-21`),
    /// never the bridge's, but this is the function that turns one into a path on this
    /// device, so it is checked here rather than trusted.
    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64
            && key.allSatisfy { $0.isASCII && ($0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The on-disk location for a key, or `nil` if the key is not a safe file name.
    public func url(for key: String) -> URL? {
        guard Self.isValidKey(key) else { return nil }
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    // MARK: - Read / write

    /// Write one response body, stamped with when it was fetched and the ETag that came
    /// with it. Best-effort: a cache that cannot be written is a feature that does not
    /// work, never a fetch that fails, so this reports success rather than throwing.
    @discardableResult
    public func store(_ body: Data, key: String, etag: String? = nil,
                      fetchedAt: Date) -> Bool {
        guard let url = url(for: key) else { return false }
        let envelope = Envelope(version: Envelope.currentVersion, fetchedAt: fetchedAt,
                                etag: etag, body: body)
        guard let encoded = try? JSONEncoder().encode(envelope) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: url, options: .atomic)
        } catch {
            return false
        }
        excludeFromBackup()
        evictIfNeeded(now: fetchedAt)
        return true
    }

    /// The cached body for a key, or `nil` if there is none, it cannot be read, it was
    /// written by a future build, or it is older than `maxAge`.
    ///
    /// An entry too old to serve is DELETED here rather than merely skipped: it will
    /// never be served again, and leaving it holding a slot would evict a live one.
    public func load(key: String, now: Date = Date()) -> CachedSnapshotBody? {
        guard let url = url(for: key),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Envelope.currentVersion else { return nil }
        guard now.timeIntervalSince(envelope.fetchedAt) <= maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return CachedSnapshotBody(body: envelope.body, etag: envelope.etag,
                                  fetchedAt: envelope.fetchedAt)
    }

    /// Forget one entry (a no-op if it was never there).
    public func remove(key: String) {
        guard let url = url(for: key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop everything. The one caller is a re-pairing: bodies fetched from a DIFFERENT
    /// bridge describe a different vault, and showing them under a new pairing would be
    /// a lie the banner cannot qualify.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bring the cache back within its age and count limits, oldest write first.
    public func evictIfNeeded(now: Date = Date()) {
        var all = entries()
        // Age first: an entry past `maxAge` is dropped whether or not there is room.
        all.removeAll { entry in
            guard now.timeIntervalSince(entry.written) > maxAge else { return false }
            try? FileManager.default.removeItem(at: entry.url)
            return true
        }
        guard all.count > maxEntries else { return }
        all.sort { $0.written < $1.written }
        for entry in all.prefix(all.count - maxEntries) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Every key currently held, for diagnostics and tests.
    public func keys() -> [String] {
        entries().map { $0.url.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func entries() -> [Entry] {
        let wanted: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: wanted, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let written = (try? url.resourceValues(forKeys: Set(wanted)))?.contentModificationDate
            return Entry(url: url, written: written ?? .distantPast)
        }
    }

    /// Keep two documents that are re-fetchable in one round trip out of every backup
    /// and every device transfer. Best-effort, and never a reason a write fails.
    private func excludeFromBackup() {
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private struct Entry {
        let url: URL
        let written: Date
    }

    /// The on-disk record. The body is a `Data`, which `JSONEncoder` writes as base64 —
    /// 33% larger than the raw bytes, and worth it: the alternative is re-serializing
    /// the parsed JSON, which is where a `1.0` quietly becomes a `1`.
    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let fetchedAt: Date
        let etag: String?
        let body: Data
    }
}

/// One cached response body and what is known about when it arrived.
public struct CachedSnapshotBody: Equatable, Sendable {
    /// The bridge's own response body, byte for byte.
    public let body: Data
    /// The ETag that came with it, when the endpoint has one. Today's does, and it is
    /// what lets a cold launch that IS online answer with a `304` instead of a refetch.
    public let etag: String?
    /// When the body was fetched — the "last updated" a stale banner reads.
    public let fetchedAt: Date

    public init(body: Data, etag: String?, fetchedAt: Date) {
        self.body = body
        self.etag = etag
        self.fetchedAt = fetchedAt
    }
}

/// The cache keys the two tabs use, named once so a writer and a reader on opposite
/// sides of the app cannot disagree about where a document lives.
public enum SnapshotCacheKey {
    /// The day file. One key, not one per date: `GET /jesse/today` is always "today".
    public static let today = "today"

    /// The live diet day — the un-dated `GET /jesse/diet`.
    public static let liveDiet = "diet-live"

    /// The diet snapshot for one day; `nil` is the live day.
    ///
    /// A date that is not a plain ISO day yields `nil` rather than a sanitized guess: a
    /// key that had to be repaired is a key two callers can derive differently.
    public static func diet(date: String?) -> String? {
        guard let date else { return liveDiet }
        guard isISODay(date) else { return nil }
        return "diet-\(date)"
    }

    /// `yyyy-MM-dd`, checked structurally. The bridge's own spelling for every date on
    /// these two endpoints.
    static func isISODay(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
