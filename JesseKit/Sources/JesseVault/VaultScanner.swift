import Foundation

// WHAT IS IN THE VAULT, and how long it took to find out.
//
// The number this produces is the go/no-go for everything built on top: an index,
// a snippet budget and an offline Today tab are all affordable if a full walk of
// the vault costs about a second on the phone, and none of them are if it costs
// thirty. So the scan REPORTS ITS OWN WALL CLOCK rather than leaving that to be
// timed from outside, where a caller's own overhead would be folded in.
//
// The skip list is not tidiness. `.obsidian` alone holds the workspace state, the
// plugin tree and the cache, which is thousands of files that are not notes; not
// DESCENDING into it (rather than filtering its contents out afterwards) is most
// of the difference between a fast scan and a slow one.

/// One markdown file, as the scan found it.
public struct VaultFileEntry: Sendable, Equatable {
    /// Path relative to the scan root, `/`-separated, no leading slash.
    public let relativePath: String
    public let modified: Date
    public let size: Int

    public init(relativePath: String, modified: Date, size: Int) {
        self.relativePath = relativePath
        self.modified = modified
        self.size = size
    }
}

/// The result of one walk of the vault.
public struct VaultScan: Sendable {
    public let files: [VaultFileEntry]
    public let totalBytes: Int
    /// Wall clock for the walk itself, in seconds.
    public let duration: TimeInterval
    /// Entries the enumerator produced that could not be read well enough to
    /// describe (no modification date, no size). Kept as a count rather than
    /// swallowed: a scan that silently drops half the vault must not look clean.
    public let unreadableCount: Int

    public var fileCount: Int { files.count }

    public init(files: [VaultFileEntry], totalBytes: Int, duration: TimeInterval, unreadableCount: Int = 0) {
        self.files = files
        self.totalBytes = totalBytes
        self.duration = duration
        self.unreadableCount = unreadableCount
    }

    /// The `limit` most recently modified files, newest first.
    public func mostRecentlyModified(_ limit: Int) -> [VaultFileEntry] {
        Array(files.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

/// The directory-walk seam. `FileManager`'s enumerator is the only production
/// implementation; the protocol exists so the scanner's decisions can be driven
/// from a fabricated tree in a test without a temporary directory.
public protocol VaultDirectoryEnumerating: Sendable {
    /// Every entry under `root`, depth first. `skipDescendants` is the caller's way
    /// of saying "do not go into the directory you just handed me".
    func enumerate(root: URL, visit: (VaultDirectoryEntry, _ skipDescendants: () -> Void) -> Void)
}

/// One raw entry from an enumerator, before any of the scanner's rules apply.
public struct VaultDirectoryEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let modified: Date?
    public let size: Int?

    public init(url: URL, isDirectory: Bool, modified: Date?, size: Int?) {
        self.url = url
        self.isDirectory = isDirectory
        self.modified = modified
        self.size = size
    }
}

/// The production enumerator: `FileManager.enumerator(at:includingPropertiesForKeys:)`
/// pre-fetching exactly the two resource values the scan reports, so the walk does
/// not pay a separate `stat` per file.
public struct FileManagerDirectoryEnumerator: VaultDirectoryEnumerating {
    public init() {}

    public func enumerate(root: URL, visit: (VaultDirectoryEntry, _ skipDescendants: () -> Void) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],           // NOT .skipsHiddenFiles: the dot rule below is explicit on purpose
            errorHandler: { _, _ in true }   // an unreadable subtree must not end the walk
        ) else { return }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let entry = VaultDirectoryEntry(url: url,
                                            isDirectory: values?.isDirectory ?? false,
                                            modified: values?.contentModificationDate,
                                            size: values?.fileSize)
            visit(entry) { enumerator.skipDescendants() }
        }
    }
}

/// Walks a vault and reports what is in it.
public struct VaultScanner: Sendable {
    private let enumerator: any VaultDirectoryEnumerating

    public init(enumerator: any VaultDirectoryEnumerating = FileManagerDirectoryEnumerator()) {
        self.enumerator = enumerator
    }

    /// Every `.md` file under `root`, with its modification time and size.
    ///
    /// Caller's responsibility: `root` must already be inside a security-scope
    /// bracket (`VaultFolder.withAccess`). This type does not manage access — a
    /// scanner that silently opened a scope would be a second, unbalanced owner of
    /// something already reference counted.
    public func scan(root: URL) -> VaultScan {
        let started = Date()
        var files: [VaultFileEntry] = []
        var totalBytes = 0
        var unreadable = 0
        // WALK THE RESOLVED ROOT, not the root as handed over. `FileManager`'s
        // enumerator does not follow a symlinked root DIRECTORY: pointed at one it
        // yields nothing at all and reports no error, so a vault reached through a
        // link would have scanned clean at zero files. One resolution here, before
        // the walk, costs a single syscall and is not the same thing as resolving
        // every file — which is what the duration below is actually measuring.
        let walkRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        // BOTH prefixes, computed ONCE, because an entry's path may carry either the
        // form the enumerator was given or the form the filesystem standardizes to.
        let rootPaths = Self.rootPrefixes(root) + Self.rootPrefixes(walkRoot)

        enumerator.enumerate(root: walkRoot) { entry, skipDescendants in
            let name = entry.url.lastPathComponent
            if Self.isSkipped(name: name) {
                // Do not merely ignore a skipped DIRECTORY — refuse to walk into it.
                // `.obsidian` is thousands of files that are not notes.
                if entry.isDirectory { skipDescendants() }
                return
            }
            guard !entry.isDirectory else { return }
            guard name.lowercased().hasSuffix(".md") else { return }
            guard let modified = entry.modified, let size = entry.size else {
                unreadable += 1
                return
            }
            guard let relative = Self.relativePath(of: entry.url, underAnyOf: rootPaths) else {
                unreadable += 1
                return
            }
            files.append(VaultFileEntry(relativePath: relative, modified: modified, size: size))
            totalBytes += size
        }

        return VaultScan(files: files,
                         totalBytes: totalBytes,
                         duration: Date().timeIntervalSince(started),
                         unreadableCount: unreadable)
    }

    // MARK: - The rules, pure and separately assertable

    /// Everything the scan refuses to look at, by NAME alone.
    ///
    /// `.obsidian`, `.trash` and `.fuse_hidden*` are all instances of one rule —
    /// a leading dot — and the rule is written that way rather than as a list of
    /// three, because the list would go stale the first time Obsidian or a FUSE
    /// mount invented a fourth. The `.fuse_hidden` prefix is checked separately
    /// anyway: a mount that produced the name without its dot would otherwise walk
    /// straight through (`~/jesse` is such a mount, and those files are not files).
    public static func isSkipped(name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if name.hasPrefix("fuse_hidden") { return true }
        return false
    }

    /// `url`'s path relative to a directory path, or nil when it is not under it.
    /// PURE STRING ARITHMETIC over the standardized path: no filesystem call, because
    /// this runs once per file in the vault.
    public static func relativePath(of url: URL, underDirectoryPath directoryPath: String) -> String? {
        relativePath(of: url, underAnyOf: [directoryPath])
    }

    /// The same, against any of several acceptable root prefixes — which is how a
    /// symlinked root (`/var` → `/private/var`) is handled without asking the
    /// filesystem about every single file.
    public static func relativePath(of url: URL, underAnyOf directoryPaths: [String]) -> String? {
        let full = url.standardizedFileURL.path
        for directoryPath in directoryPaths where full.hasPrefix(directoryPath) {
            let relative = String(full.dropFirst(directoryPath.count))
            if !relative.isEmpty { return relative }
        }
        return nil
    }

    /// The prefixes an entry under `root` may legitimately start with: the root as
    /// given, and the root with its symlinks resolved. Both end in exactly one slash.
    /// Computed once per scan, never per file.
    public static func rootPrefixes(_ root: URL) -> [String] {
        let plain = root.standardizedFileURL.path
        let resolved = normalizedDirectoryPath(root)
        let plainWithSlash = plain.hasSuffix("/") ? plain : plain + "/"
        return plainWithSlash == resolved ? [resolved] : [plainWithSlash, resolved]
    }

    /// A directory's standardized path with exactly one trailing slash, so a prefix
    /// comparison against it cannot match a SIBLING whose name merely starts the
    /// same way (`/vault-backup` must never look like it is inside `/vault`).
    public static func normalizedDirectoryPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
