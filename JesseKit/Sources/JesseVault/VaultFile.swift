import Foundation

// READING ONE NOTE, AND ADDING ONE LINE — the only two file operations this spike
// needs, and deliberately the only two it has.
//
// Both go through `NSFileCoordinator`. That is not ceremony: the folder being read
// is Obsidian's own, actively synced, and on iOS potentially a file provider's.
// An uncoordinated read can see a half-written file mid-sync, and an uncoordinated
// write can lose against one. Coordination is how the system is told to hold still.
//
// APPEND NEVER REWRITES. It opens the file and writes at the end, or creates the
// file when it is absent. Nothing here can truncate or replace a note, which is the
// property that makes it safe to point at a real vault: the worst case is one extra
// line in one file under `Inbox/`.
//
// Every path is validated before it is touched. The rules are pure functions so
// they are asserted directly rather than inferred from whether a write happened to
// land somewhere wrong.

public enum VaultFileError: Error, CustomStringConvertible, Equatable {
    case emptyPath
    case absolutePath(String)
    case escapesRoot(String)
    case forbiddenDotDirectory(String)
    case notUTF8(String)
    case unreadable(String, String)
    case unwritable(String, String)

    public var description: String {
        switch self {
        case .emptyPath: return "No path given."
        case .absolutePath(let p): return "“\(p)” is an absolute path; only paths inside the vault are allowed."
        case .escapesRoot(let p): return "“\(p)” leads outside the vault folder."
        case .forbiddenDotDirectory(let p): return "“\(p)” is inside a dot directory, which is never read or written."
        case .notUTF8(let p): return "“\(p)” is not UTF-8 text."
        case .unreadable(let p, let why): return "Could not read “\(p)”: \(why)"
        case .unwritable(let p, let why): return "Could not write “\(p)”: \(why)"
        }
    }
}

/// What one append did: the file's size afterwards, and whether this call was the one
/// that created it.
public struct VaultAppendResult: Equatable, Sendable {
    public let size: Int
    public let created: Bool

    public init(size: Int, created: Bool) {
        self.size = size
        self.created = created
    }
}

/// One vault root, and the two things that may be done inside it.
public struct VaultFile: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The whole file as UTF-8 text, through a coordinated read.
    public func read(relativePath: String) throws -> String {
        let url = try resolved(relativePath)
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                let data = try Data(contentsOf: readURL)
                guard let text = String(data: data, encoding: .utf8) else {
                    result = .failure(VaultFileError.notUTF8(relativePath))
                    return
                }
                result = .success(text)
            } catch {
                result = .failure(VaultFileError.unreadable(relativePath, error.localizedDescription))
            }
        }
        if let coordinationError {
            throw VaultFileError.unreadable(relativePath, coordinationError.localizedDescription)
        }
        guard let result else {
            throw VaultFileError.unreadable(relativePath, "the coordinated read never ran")
        }
        return try result.get()
    }

    /// Append `text` to the file, creating it (and any missing parent directory)
    /// when it is absent. Existing bytes are never rewritten.
    ///
    /// Returns the file's size afterwards, which is what makes "it only grew"
    /// checkable by the caller rather than a claim.
    @discardableResult
    public func append(relativePath: String, text: String) throws -> Int {
        let url = try resolved(relativePath)
        guard let payload = text.data(using: .utf8) else {
            throw VaultFileError.notUTF8(relativePath)
        }
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                let manager = FileManager.default
                let parent = writeURL.deletingLastPathComponent()
                if !manager.fileExists(atPath: parent.path) {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                if !manager.fileExists(atPath: writeURL.path) {
                    try payload.write(to: writeURL, options: .atomic)
                    return
                }
                // The APPEND proper. `seekToEnd` then `write` cannot touch a byte
                // that is already there; a read-modify-write would have been the
                // shape that can lose a concurrent Obsidian edit.
                let handle = try FileHandle(forWritingTo: writeURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                thrown = VaultFileError.unwritable(relativePath, error.localizedDescription)
            }
        }
        if let coordinationError {
            throw VaultFileError.unwritable(relativePath, coordinationError.localizedDescription)
        }
        if let thrown { throw thrown }
        // The size AFTER the write, which is what makes "it only grew" something the
        // caller can check rather than something this function claims.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Append `text`, writing `prologue` first IF AND ONLY IF the file did not already
    /// exist — with that decision made inside the same coordination bracket as the write.
    ///
    /// This exists because "create it with a heading, otherwise just append" cannot be
    /// spelled as `exists()` followed by `append()`: the folder is Obsidian's and actively
    /// synced, so between those two calls the file can appear, and the heading would land
    /// in the middle of it. One bracket, one decision, and `created` reports which branch
    /// was taken so the caller can count the bytes it actually wrote.
    ///
    /// Like `append`, it can only ever grow the file. `prologue` is written only to a file
    /// this call is itself creating, so no existing byte is reachable from here either.
    @discardableResult
    public func appendCreating(relativePath: String,
                               prologue: String,
                               text: String) throws -> VaultAppendResult {
        let url = try resolved(relativePath)
        guard let body = text.data(using: .utf8), let head = prologue.data(using: .utf8) else {
            throw VaultFileError.notUTF8(relativePath)
        }
        var coordinationError: NSError?
        var thrown: Error?
        var created = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                let manager = FileManager.default
                let parent = writeURL.deletingLastPathComponent()
                if !manager.fileExists(atPath: parent.path) {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                if !manager.fileExists(atPath: writeURL.path) {
                    created = true
                    try (head + body).write(to: writeURL, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: writeURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: body)
            } catch {
                thrown = VaultFileError.unwritable(relativePath, error.localizedDescription)
            }
        }
        if let coordinationError {
            throw VaultFileError.unwritable(relativePath, coordinationError.localizedDescription)
        }
        if let thrown { throw thrown }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return VaultAppendResult(size: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                                 created: created)
    }

    /// True when the file exists. Used by the diagnostics screen to say what it is
    /// about to do before it does it.
    public func exists(relativePath: String) -> Bool {
        guard let url = try? resolved(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Path validation

    /// The absolute URL a relative path names, or a throw saying exactly why not.
    public func resolved(_ relativePath: String) throws -> URL {
        let components = try Self.validatedComponents(relativePath)
        // Build from the ROOT'S OWN RESOLVED PATH, not from the root as handed over.
        // On macOS the temporary directory is `/var/...`, a symlink to `/private/var/...`,
        // and resolving only one side of the comparison is how a legitimate path ends up
        // looking like an escape.
        var url = URL(fileURLWithPath: String(Self.rootPrefix(root).dropLast()), isDirectory: true)
        for component in components { url.appendPathComponent(component) }
        // The LAST line of defence, and the only one that catches a symlink: compare
        // the resolved paths. A component may be a link pointing anywhere, and the
        // component-level rules above cannot see that.
        try Self.assertInside(url, root: root, describedAs: relativePath)
        return url
    }

    /// Split a relative path into components, refusing everything that is not a
    /// plain path inside the vault. Pure: no file has to exist for this to decide.
    public static func validatedComponents(_ relativePath: String) throws -> [String] {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultFileError.emptyPath }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw VaultFileError.absolutePath(relativePath)
        }
        let raw = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !raw.isEmpty else { throw VaultFileError.emptyPath }
        for component in raw {
            if component == ".." { throw VaultFileError.escapesRoot(relativePath) }
            if component == "." { continue }
            // The dot rule, the same one the scanner applies: `.obsidian` and every
            // other dot directory is neither read nor written, ever.
            if component.hasPrefix(".") { throw VaultFileError.forbiddenDotDirectory(relativePath) }
        }
        let components = raw.filter { $0 != "." }
        guard !components.isEmpty else { throw VaultFileError.emptyPath }
        return components
    }

    /// Throw unless `url` really is inside `root` once every symlink that actually
    /// exists has been resolved on BOTH sides.
    ///
    /// The subtlety that a first attempt got wrong: the file being appended to may
    /// not exist yet, and neither may its directory, and `resolvingSymlinksInPath()`
    /// on a path that does not exist resolves NOTHING. So a perfectly legal
    /// `Inbox/…-phone-probe.md` under a `/var/folders/…` root compared a resolved
    /// `/private/var/…` root against an unresolved `/var/…` candidate and was refused.
    /// The fix is to resolve the deepest ancestor that DOES exist — which is the only
    /// part that can carry a symlink anyway — and judge the rest by the component
    /// rules, which have already refused `..`.
    public static func assertInside(_ url: URL, root: URL, describedAs description: String) throws {
        let rootPrefix = rootPrefix(root)
        let resolvedAncestor = deepestExistingAncestorPath(of: url)
        let ancestorWithSlash = resolvedAncestor.hasSuffix("/") ? resolvedAncestor : resolvedAncestor + "/"
        guard ancestorWithSlash.hasPrefix(rootPrefix) else {
            throw VaultFileError.escapesRoot(description)
        }
    }

    /// The root's standardized, symlink-resolved path with exactly one trailing
    /// slash — the prefix every path inside the vault must start with.
    static func rootPrefix(_ root: URL) -> String {
        VaultScanner.normalizedDirectoryPath(root)
    }

    /// `url`'s own resolved path when it exists, else the resolved path of its
    /// nearest existing ancestor with the missing components appended back on.
    static func deepestExistingAncestorPath(of url: URL) -> String {
        let manager = FileManager.default
        var missing: [String] = []
        var candidate = url.standardizedFileURL
        while !manager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            // `/` is its own parent; without this a path under a missing root loops.
            if parent.path == candidate.path { return candidate.path }
            missing.insert(candidate.lastPathComponent, at: 0)
            candidate = parent
        }
        var resolved = candidate.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }
}
