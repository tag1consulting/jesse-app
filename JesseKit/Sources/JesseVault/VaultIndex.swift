import Foundation
import SQLite3
import CryptoKit

// THE INDEX: 7,600 markdown files, searchable in under a tenth of a second, on a phone
// with no network.
//
// ## Why SQLite's own full-text engine and nothing else
//
// The alternative — walk the vault and `localizedStandardContains` every file — is what
// the conversation search does over threads, and over a vault it is not close: it means
// reading forty megabytes off disk per keystroke. FTS5 reads an inverted index instead,
// and it is already on both platforms as part of libsqlite3, which is why this target
// still depends on nothing. `fts5IsAvailable` MEASURES that rather than trusting it (see
// `VaultIndexError.noFTS5`): the whole design rests on it being compiled in.
//
// The C API is used directly. A wrapper would be a third-party dependency for the sake
// of about eighty lines of `sqlite3_bind_text`, and this app takes no third-party
// dependencies.
//
// ## Where it lives, and why not in the vault
//
// In Application Support, under a directory named by a hash of the folder it indexes —
// never inside the vault folder itself. The vault is Obsidian's, actively synced, and a
// 60 MB SQLite database appearing in it would be synced to every device the user owns
// and shown in their note tree. This prompt writes NOTHING into the vault.
//
// ## The shape of the data, and the one denormalization
//
//     files(path, mtime, size, title, basename, basename_lower)
//     chunks(id, path, heading, title, line_start, body)
//     chunk_fts(body, heading, title, path)      external content over `chunks`
//     links(from_path, target)
//
// `chunks` carries a copy of its file's `title` purely so `chunk_fts` can be an EXTERNAL
// CONTENT table (`content='chunks'`): an fts5 table that stores its own copy of the text
// would double the database, and a contentless one cannot produce a `snippet()`. External
// content keeps one copy of the bytes and still snippets, at the cost of this one
// duplicated column and the two triggers that mirror inserts and deletes into the index.
//
// ## Concurrency
//
// One connection per instance, every statement serialized by one lock, `@unchecked
// Sendable` on that basis and no other: nothing here is mutable except the connection
// and its prepared statements, all of which are reached only inside `locked`. Instances
// are deliberately CHEAP so the searching screen and the reindexing task each open their
// own — WAL lets a reader run while the writer holds a transaction, which is what keeps
// search answering while a reindex is running.

/// What can go wrong opening or driving the index.
public enum VaultIndexError: Error, CustomStringConvertible, Equatable {
    /// libsqlite3 on this platform was built WITHOUT FTS5. The whole design rests on it.
    case noFTS5
    case cannotOpen(String)
    case sql(String, String)

    public var description: String {
        switch self {
        case .noFTS5:
            return "This system's SQLite was built without FTS5, so the vault cannot be indexed."
        case .cannotOpen(let why): return "The index could not be opened: \(why)"
        case .sql(let what, let why): return "\(what) failed: \(why)"
        }
    }
}

/// One search hit: a chunk, and enough about it to draw a row and open the note.
public struct VaultSearchHit: Equatable, Sendable, Identifiable {
    /// Path relative to the vault root.
    public let path: String
    public let title: String
    /// The `##` heading the hit sits under, or empty.
    public let heading: String
    /// The 1-based line the chunk starts at.
    public let line: Int
    /// FTS5's own snippet of the body, with matched terms wrapped in
    /// `VaultSearchHit.markStart` / `markEnd`.
    public let snippet: String
    /// bm25, weighted. Lower is better (SQLite's bm25 returns negatives).
    public let score: Double
    /// The title or the path contains every query token — a NAME match, which ranks
    /// above a body-only hit.
    public var isNameMatch: Bool

    /// One row per chunk, and a chunk is identified by its file and its line.
    public var id: String { "\(path)#\(line)" }

    public init(path: String, title: String, heading: String, line: Int,
                snippet: String, score: Double, isNameMatch: Bool = false) {
        self.path = path
        self.title = title
        self.heading = heading
        self.line = line
        self.snippet = snippet
        self.score = score
        self.isNameMatch = isNameMatch
    }

    /// The markers FTS5 wraps a matched term in. Control characters on purpose: any
    /// visible pair (`**`, `<b>`) can occur in a note and would be parsed as a match
    /// that is not one.
    public static let markStart = "\u{2}"
    public static let markEnd = "\u{3}"
}

/// One file as the index holds it.
public struct VaultIndexedFile: Equatable, Sendable {
    public let path: String
    public let title: String
    public let modified: Date
    public let size: Int

    public init(path: String, title: String, modified: Date, size: Int) {
        self.path = path
        self.title = title
        self.modified = modified
        self.size = size
    }
}

/// What one reindex did.
public struct VaultReindexReport: Equatable, Sendable {
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let unchanged: Int
    /// Files the reindex could not read. Counted rather than swallowed: an index that
    /// silently skipped half the vault must not look clean.
    public let failed: Int
    public let duration: TimeInterval
    /// False when the run stopped early (the app was suspended, or the screen asked it
    /// to stop). Everything committed so far stands, and the next run picks up the rest.
    public let completed: Bool

    public init(added: Int = 0, updated: Int = 0, removed: Int = 0, unchanged: Int = 0,
                failed: Int = 0, duration: TimeInterval = 0, completed: Bool = true) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.unchanged = unchanged
        self.failed = failed
        self.duration = duration
        self.completed = completed
    }

    public var changedCount: Int { added + updated + removed }

    /// One line for the diagnostics screen.
    public var summary: String {
        let core = "\(added) new, \(updated) changed, \(removed) gone, \(unchanged) unchanged"
        let failure = failed > 0 ? ", \(failed) unreadable" : ""
        let stopped = completed ? "" : " (stopped early)"
        return core + failure + String(format: " in %.2f s", duration) + stopped
    }
}

/// How big the index is.
public struct VaultIndexCounts: Equatable, Sendable {
    public let fileCount: Int
    public let chunkCount: Int
    public let linkCount: Int
    /// The database file plus its write-ahead log.
    public let databaseBytes: Int

    public init(fileCount: Int = 0, chunkCount: Int = 0, linkCount: Int = 0,
                databaseBytes: Int = 0) {
        self.fileCount = fileCount
        self.chunkCount = chunkCount
        self.linkCount = linkCount
        self.databaseBytes = databaseBytes
    }
}

public final class VaultIndex: @unchecked Sendable {

    /// The schema this build writes. A database at any other version is rebuilt rather
    /// than read: a changed chunker is a changed meaning of every row it wrote.
    static let schemaVersion: Int32 = 1

    /// Whether this system's libsqlite3 has FTS5 compiled in.
    ///
    /// Apple ships it on both platforms, and this asks anyway. It costs one call, and
    /// the alternative is a design resting on a fact nobody on this device has checked.
    public static var fts5IsAvailable: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") != 0
    }

    public let databaseURL: URL
    private let db: OpaquePointer
    private let lock = NSLock()

    /// The statements a reindex runs once per file or per chunk. Prepared once and reset,
    /// because preparing them per row is most of the cost of indexing 7,600 files.
    private var insertFile: OpaquePointer?
    private var deleteChunks: OpaquePointer?
    private var deleteLinks: OpaquePointer?
    private var insertChunk: OpaquePointer?
    private var insertLink: OpaquePointer?
    private var deleteFile: OpaquePointer?

    /// Open (or create) the index at `url`.
    ///
    /// Throws `.noFTS5` before touching the filesystem when the platform cannot support
    /// the design at all.
    public init(url: URL) throws {
        guard Self.fts5IsAvailable else { throw VaultIndexError.noFTS5 }
        databaseURL = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw VaultIndexError.cannotOpen(why)
        }
        db = opened
        do {
            try configure()
            try migrate()
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        for statement in [insertFile, deleteChunks, deleteLinks, insertChunk, insertLink,
                          deleteFile] {
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
    }

    /// The per-folder database location: Application Support, a directory named by a
    /// hash of the folder's own path, and `vault-index.sqlite` inside it.
    ///
    /// Keyed on the FOLDER rather than on the bookmark's bytes, deliberately. A
    /// security-scoped bookmark is re-minted whenever the system reports it stale, which
    /// on a file provider is not rare; keying on those bytes would throw away a complete
    /// index and re-read 7,600 files because a bookmark was refreshed. The folder is what
    /// the index is actually about.
    public static func databaseURL(forRoot root: URL,
                                  in container: URL? = nil) -> URL {
        let base = container ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                             in: .userDomainMask,
                                                             appropriateFor: nil,
                                                             create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("JesseVault", isDirectory: true)
            .appendingPathComponent(fingerprint(forRoot: root), isDirectory: true)
            .appendingPathComponent("vault-index.sqlite")
    }

    /// A short, stable name for one folder.
    public static func fingerprint(forRoot root: URL) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading

    /// The `limit` most recently modified files, newest first — what the Vault tab shows
    /// before anything is typed.
    public func recentFiles(limit: Int = 30) -> [VaultIndexedFile] {
        recentFiles(limit: limit, underPrefix: nil)
    }

    /// The same, limited to one folder.
    ///
    /// The predicate is SQL rather than a filter over the unscoped answer, and that is
    /// not an optimization: `LIMIT 30` applied before a Swift-side filter would return
    /// the thirty most recent files in the whole vault and then keep whichever of them
    /// happened to be in the folder, which on any busy morning is none. The prefix is
    /// bound as a parameter and matched with `LIKE … ESCAPE`, so a folder name carrying
    /// a `%` or a `_` cannot widen the query.
    public func recentFiles(limit: Int = 30, underPrefix prefix: String?) -> [VaultIndexedFile] {
        locked {
            var out: [VaultIndexedFile] = []
            let sql = prefix == nil
                ? "SELECT path, title, mtime, size FROM files ORDER BY mtime DESC LIMIT ?;"
                : "SELECT path, title, mtime, size FROM files WHERE path LIKE ? ESCAPE '\\' ORDER BY mtime DESC LIMIT ?;"
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let prefix {
                bind(stmt, 1, Self.likePrefix(prefix))
                sqlite3_bind_int(stmt, 2, Int32(limit))
            } else {
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(VaultIndexedFile(
                    path: text(stmt, 0), title: text(stmt, 1),
                    modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    size: Int(sqlite3_column_int64(stmt, 3))))
            }
            return out
        }
    }

    /// One prefix as a `LIKE` pattern whose wildcards are escaped, so only the trailing
    /// `%` this adds is one.
    static func likePrefix(_ prefix: String) -> String {
        var out = ""
        for character in prefix {
            if character == "%" || character == "_" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out + "%"
    }

    public func counts() -> VaultIndexCounts {
        let numbers: (Int, Int, Int) = locked {
            (scalar("SELECT count(*) FROM files;"),
             scalar("SELECT count(*) FROM chunks;"),
             scalar("SELECT count(*) FROM links;"))
        }
        var bytes = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = suffix.isEmpty
                ? databaseURL
                : URL(fileURLWithPath: databaseURL.path + suffix)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            bytes += (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        return VaultIndexCounts(fileCount: numbers.0, chunkCount: numbers.1,
                                linkCount: numbers.2, databaseBytes: bytes)
    }

    /// One file's row, or nil when it is not indexed.
    public func file(at path: String) -> VaultIndexedFile? {
        locked {
            guard let stmt = try? prepare(
                "SELECT path, title, mtime, size FROM files WHERE path = ?;") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return VaultIndexedFile(
                path: text(stmt, 0), title: text(stmt, 1),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                size: Int(sqlite3_column_int64(stmt, 3)))
        }
    }

    /// Every indexed path. Small enough to hold (7,600 strings) and what the pure
    /// resolver is driven from in a test.
    public func allPaths() -> [String] {
        locked {
            var out: [String] = []
            guard let stmt = try? prepare("SELECT path FROM files ORDER BY path;") else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
            return out
        }
    }

    /// Every folder in the vault, with the number of notes under each.
    ///
    /// Derived from `allPaths()` rather than stored — see `VaultFolderTree` for why a
    /// `folders` table would be the expensive answer to a cheap question.
    public func folders() -> [VaultFolderCount] {
        VaultFolderTree.folders(fromPaths: allPaths())
    }

    /// The chunk ids recorded for one file, in order.
    ///
    /// Exists for the incremental reindex's test: "an unchanged file is not touched" is
    /// only a real claim if the rows it would have rewritten can be shown not to have
    /// been rewritten, and a rewritten chunk gets a new rowid.
    public func chunkIDs(forPath path: String) -> [Int64] {
        locked {
            var out: [Int64] = []
            guard let stmt = try? prepare(
                "SELECT id FROM chunks WHERE path = ? ORDER BY id;") else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
            return out
        }
    }

    /// One chunk's FULL body, by the file and line that identify it.
    ///
    /// A `VaultSearchHit` carries an fts5 `snippet()` — fifteen words around the match,
    /// with the match markers in it — which is the right thing to draw a result row with
    /// and the wrong thing to put in front of a model: the answer to "when is the school
    /// concert" is routinely the sentence AFTER the one the query matched. This is the
    /// read that turns a hit back into the paragraph it came from.
    ///
    /// `line_start` rather than the chunk's rowid because that is what a hit carries and
    /// what survives a reindex as a stable name for the same passage; the pair is unique
    /// by construction (the chunker emits one chunk per start line per file).
    public func chunkText(path: String, line: Int) -> String? {
        locked {
            guard let stmt = try? prepare(
                "SELECT body FROM chunks WHERE path = ? AND line_start = ? LIMIT 1;")
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            sqlite3_bind_int64(stmt, 2, Int64(line))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return text(stmt, 0)
        }
    }

    /// The wiki targets one file links to, in the order they were found.
    public func outgoingTargets(fromPath path: String) -> [String] {
        locked {
            var out: [String] = []
            guard let stmt = try? prepare(
                "SELECT target FROM links WHERE from_path = ? ORDER BY rowid;") else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, path)
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
            return out
        }
    }

    /// The relative path a wiki target names, by the same three steps as
    /// `VaultWikiLink.resolve(target:among:)` — exact path, unique basename, unique
    /// case-folded basename — as SQL rather than over an array of 7,600 strings.
    public func resolve(target rawTarget: String) -> String? {
        // The same prefix rule as `VaultWikiLink.resolve`: the workspace name comes off,
        // and a stray note under a literal `todo-list/` folder is never an answer.
        let target = VaultWikiLink.withoutWorkspacePrefix(VaultWikiLink.normalized(rawTarget))
        guard !target.isEmpty else { return nil }
        return locked {
            if exists(path: target + ".md") { return target + ".md" }
            let wanted = VaultWikiLink.fileName(for: target)
            let exact = paths(whereColumn: "basename", equals: wanted)
                .filter { !VaultWikiLink.isStrayWorkspacePath($0) }
            if exact.count == 1 { return exact[0] }
            if exact.count > 1 { return nil }
            let folded = paths(whereColumn: "basename_lower", equals: wanted.lowercased())
                .filter { !VaultWikiLink.isStrayWorkspacePath($0) }
            return folded.count == 1 ? folded[0] : nil
        }
    }

    /// Run one FTS5 query. `expression` is a MATCH expression, already built and
    /// sanitized by `VaultSearchQuery.matchExpression`.
    ///
    /// Ordered by weighted bm25 (title 4, heading 2, body 1, path 1) — the ORDER the
    /// caller then refines with the name-match rule, which SQL cannot express because it
    /// is about the tokens as the user typed them.
    public func search(expression: String, limit: Int = 50) -> [VaultSearchHit] {
        search(expression: expression, limit: limit, underPrefix: nil)
    }

    /// The same, limited to one folder — the Vault tab's scope control. The predicate
    /// is in the query for `recentFiles(limit:underPrefix:)`'s reason: filtering after
    /// `LIMIT 50` would answer a scoped question with an unscoped top fifty.
    public func search(expression: String, limit: Int = 50,
                       underPrefix prefix: String?) -> [VaultSearchHit] {
        locked {
            var out: [VaultSearchHit] = []
            let scope = prefix == nil ? "" : "   AND c.path LIKE ? ESCAPE '\\'\n"
            let sql = """
                SELECT c.path, c.title, c.heading, c.line_start,
                       snippet(chunk_fts, 0, ?, ?, '…', 14),
                       bm25(chunk_fts, 1.0, 2.0, 4.0, 1.0)
                  FROM chunk_fts
                  JOIN chunks c ON c.id = chunk_fts.rowid
                 WHERE chunk_fts MATCH ?
                \(scope) ORDER BY bm25(chunk_fts, 1.0, 2.0, 4.0, 1.0)
                 LIMIT ?;
                """
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, VaultSearchHit.markStart)
            bind(stmt, 2, VaultSearchHit.markEnd)
            bind(stmt, 3, expression)
            if let prefix {
                bind(stmt, 4, Self.likePrefix(prefix))
                sqlite3_bind_int(stmt, 5, Int32(limit))
            } else {
                sqlite3_bind_int(stmt, 4, Int32(limit))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(VaultSearchHit(path: text(stmt, 0),
                                          title: text(stmt, 1),
                                          heading: text(stmt, 2),
                                          line: Int(sqlite3_column_int64(stmt, 3)),
                                          snippet: text(stmt, 4),
                                          score: sqlite3_column_double(stmt, 5)))
            }
            return out
        }
    }

    /// Every chunk under one path prefix, bodies included, in file and line order: what
    /// the Strands scope's section view splits into lines. Unranked and unlimited on
    /// purpose, so it is only asked of a small folder; `Strands/` is a few hundred chunks.
    public func chunks(underPrefix prefix: String) -> [VaultStoredChunk] {
        locked {
            var out: [VaultStoredChunk] = []
            let sql = """
                SELECT path, title, heading, line_start, body FROM chunks
                 WHERE path LIKE ? ESCAPE '\\'
                 ORDER BY path, line_start;
                """
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Self.likePrefix(prefix))
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(VaultStoredChunk(path: text(stmt, 0), title: text(stmt, 1),
                                            heading: text(stmt, 2),
                                            lineStart: Int(sqlite3_column_int64(stmt, 3)),
                                            body: text(stmt, 4)))
            }
            return out
        }
    }

    // MARK: - Writing

    /// Bring the index into line with `scan`, reading only what changed.
    ///
    /// A file is considered unchanged when its modification time AND its size both match
    /// the row already stored, which is the same pair `VaultScanner` reports and costs no
    /// read at all. Everything else is re-read and re-chunked, and rows for files that
    /// have gone are deleted.
    ///
    /// RESUMABLE, and that is why the writes are batched rather than wrapped in one
    /// transaction: a first index of a large vault takes tens of seconds, iOS can suspend
    /// the app in the middle of it, and one giant transaction would roll all of it back.
    /// Each batch that commits is progress the next run does not repeat. The deletion pass
    /// runs only when every file was visited — a run that stopped early has not seen the
    /// files it would otherwise conclude are gone.
    @discardableResult
    public func reindex(scan: VaultScan,
                        read: (String) throws -> String,
                        batchSize: Int = 250,
                        progress: ((Double) -> Void)? = nil,
                        isCancelled: () -> Bool = { false }) throws -> VaultReindexReport {
        let started = Date()
        var added = 0, updated = 0, unchanged = 0, failed = 0, removed = 0
        var seen = Set<String>()
        var pending = 0
        var completed = true

        let existing = knownFiles()
        try begin()
        var didCommit = false
        defer { if !didCommit { try? commit() } }

        for (offset, entry) in scan.files.enumerated() {
            if isCancelled() {
                completed = false
                break
            }
            seen.insert(entry.relativePath)
            let stamp = entry.modified.timeIntervalSince1970
            if let known = existing[entry.relativePath],
               abs(known.mtime - stamp) < 0.000_001, known.size == entry.size {
                unchanged += 1
                continue
            }
            let isNew = existing[entry.relativePath] == nil
            do {
                let text = try read(entry.relativePath)
                let parsed = VaultChunker.parse(relativePath: entry.relativePath, text: text)
                try store(entry: entry, parsed: parsed)
                if isNew { added += 1 } else { updated += 1 }
            } catch {
                // A file that cannot be read is COUNTED and skipped, and its old rows are
                // left alone: a transient read failure must not empty a note out of the
                // index.
                failed += 1
            }
            pending += 1
            if pending >= batchSize {
                try commit()
                try begin()
                pending = 0
            }
            if let progress, scan.files.count > 0 {
                progress(Double(offset + 1) / Double(scan.files.count))
            }
        }

        if completed {
            for path in existing.keys where !seen.contains(path) {
                try remove(path: path)
                removed += 1
            }
        }
        try commit()
        didCommit = true
        progress?(1)

        return VaultReindexReport(added: added, updated: updated, removed: removed,
                                  unchanged: unchanged, failed: failed,
                                  duration: Date().timeIntervalSince(started),
                                  completed: completed)
    }

    /// Re-read and re-chunk ONE file, whatever its modification time says.
    ///
    /// The debounce and the mtime/size diff that make a whole-vault reindex affordable are
    /// both exactly wrong for a file this app has just written: the diff would frequently
    /// skip it (a one-character tick changes no size, and on a filesystem with coarse
    /// timestamps not always the mtime either), and the debounce would mean a search for
    /// the sentence you just typed finds the version before it for the next half minute. A
    /// search that cannot find what you just wrote is a search you stop trusting.
    ///
    /// A file that has GONE is removed from the index rather than left: the same call
    /// serves "this note changed" and "this note is no longer there", and a stale row is
    /// how a search offers a hit that opens onto nothing.
    ///
    /// One file, so one transaction: none of `reindex`'s resumable batching applies.
    public func reindex(file relativePath: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            try remove(path: relativePath)
            return
        }
        let text = try VaultFile(root: root).read(relativePath: relativePath)
        let entry = VaultFileEntry(relativePath: relativePath, modified: modified, size: size)
        try store(entry: entry,
                  parsed: VaultChunker.parse(relativePath: relativePath, text: text))
    }

    /// Throw every row away and recreate the schema — the Rebuild button.
    ///
    /// Not a `DELETE FROM`: a rebuild exists precisely for the case where what is stored
    /// is not trusted, and dropping the tables is the only version of that which also
    /// discards an fts5 index that has gone out of step with its content table.
    public func rebuild() throws {
        try locked {
            try execute(Self.dropSQL)
            try execute(Self.schemaSQL)
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            // The prepared statements point at tables that no longer exist.
            finalizeStatements()
        }
    }

    // MARK: - Schema

    private static let dropSQL = """
        DROP TRIGGER IF EXISTS chunks_after_insert;
        DROP TRIGGER IF EXISTS chunks_after_delete;
        DROP TABLE IF EXISTS chunk_fts;
        DROP TABLE IF EXISTS chunks;
        DROP TABLE IF EXISTS files;
        DROP TABLE IF EXISTS links;
        """

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS files (
            path           TEXT PRIMARY KEY,
            mtime          REAL NOT NULL,
            size           INTEGER NOT NULL,
            title          TEXT NOT NULL,
            basename       TEXT NOT NULL,
            basename_lower TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS files_basename ON files(basename);
        CREATE INDEX IF NOT EXISTS files_basename_lower ON files(basename_lower);
        CREATE INDEX IF NOT EXISTS files_mtime ON files(mtime DESC);

        CREATE TABLE IF NOT EXISTS chunks (
            id         INTEGER PRIMARY KEY,
            path       TEXT NOT NULL,
            heading    TEXT NOT NULL,
            title      TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            body       TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);

        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
            body, heading, title, path,
            content='chunks', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER IF NOT EXISTS chunks_after_insert AFTER INSERT ON chunks BEGIN
            INSERT INTO chunk_fts(rowid, body, heading, title, path)
            VALUES (new.id, new.body, new.heading, new.title, new.path);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_after_delete AFTER DELETE ON chunks BEGIN
            INSERT INTO chunk_fts(chunk_fts, rowid, body, heading, title, path)
            VALUES ('delete', old.id, old.body, old.heading, old.title, old.path);
        END;

        CREATE TABLE IF NOT EXISTS links (
            from_path TEXT NOT NULL,
            target    TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS links_from ON links(from_path);
        CREATE INDEX IF NOT EXISTS links_target ON links(target);
        """

    private func configure() throws {
        // WAL so a search can read while a reindex writes, and a busy timeout so the two
        // never surface as an error to the screen.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 5000;")
        try execute("PRAGMA foreign_keys = OFF;")
    }

    private func migrate() throws {
        let version = Int32(scalar("PRAGMA user_version;"))
        if version != 0, version != Self.schemaVersion {
            // A database written by a different chunker is not stale data, it is data
            // whose meaning this build does not know. Start again.
            try execute(Self.dropSQL)
        }
        try execute(Self.schemaSQL)
        try execute("PRAGMA user_version = \(Self.schemaVersion);")
    }

    // MARK: - The write statements

    private func store(entry: VaultFileEntry, parsed: VaultNoteParse) throws {
        try locked {
            let basename = VaultWikiLink.basename(entry.relativePath)
            if insertFile == nil {
                insertFile = try prepare("""
                    INSERT OR REPLACE INTO files(path, mtime, size, title, basename, basename_lower)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """)
            }
            if deleteChunks == nil {
                deleteChunks = try prepare("DELETE FROM chunks WHERE path = ?;")
            }
            if deleteLinks == nil {
                deleteLinks = try prepare("DELETE FROM links WHERE from_path = ?;")
            }
            if insertChunk == nil {
                insertChunk = try prepare("""
                    INSERT INTO chunks(path, heading, title, line_start, body)
                    VALUES (?, ?, ?, ?, ?);
                    """)
            }
            if insertLink == nil {
                insertLink = try prepare("INSERT INTO links(from_path, target) VALUES (?, ?);")
            }

            try run(deleteChunks) { bind($0, 1, entry.relativePath) }
            try run(deleteLinks) { bind($0, 1, entry.relativePath) }
            try run(insertFile) { stmt in
                bind(stmt, 1, entry.relativePath)
                sqlite3_bind_double(stmt, 2, entry.modified.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, Int64(entry.size))
                bind(stmt, 4, parsed.title)
                bind(stmt, 5, basename)
                bind(stmt, 6, basename.lowercased())
            }
            for chunk in parsed.chunks {
                try run(insertChunk) { stmt in
                    bind(stmt, 1, entry.relativePath)
                    bind(stmt, 2, chunk.heading)
                    bind(stmt, 3, parsed.title)
                    sqlite3_bind_int64(stmt, 4, Int64(chunk.lineStart))
                    bind(stmt, 5, chunk.body)
                }
            }
            for target in parsed.linkTargets {
                try run(insertLink) { stmt in
                    bind(stmt, 1, entry.relativePath)
                    bind(stmt, 2, target)
                }
            }
        }
    }

    private func remove(path: String) throws {
        try locked {
            if deleteChunks == nil {
                deleteChunks = try prepare("DELETE FROM chunks WHERE path = ?;")
            }
            if deleteLinks == nil {
                deleteLinks = try prepare("DELETE FROM links WHERE from_path = ?;")
            }
            if deleteFile == nil {
                deleteFile = try prepare("DELETE FROM files WHERE path = ?;")
            }
            try run(deleteChunks) { bind($0, 1, path) }
            try run(deleteLinks) { bind($0, 1, path) }
            try run(deleteFile) { bind($0, 1, path) }
        }
    }

    /// Every indexed file's modification stamp and size — the whole diff basis, read in
    /// one pass because 7,600 separate lookups is a different order of cost.
    private func knownFiles() -> [String: (mtime: Double, size: Int)] {
        locked {
            var out: [String: (mtime: Double, size: Int)] = [:]
            guard let stmt = try? prepare("SELECT path, mtime, size FROM files;") else { return [:] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[text(stmt, 0)] = (sqlite3_column_double(stmt, 1),
                                      Int(sqlite3_column_int64(stmt, 2)))
            }
            return out
        }
    }

    private func begin() throws { try locked { try execute("BEGIN IMMEDIATE;") } }

    private func commit() throws {
        try locked {
            guard sqlite3_get_autocommit(db) == 0 else { return }
            try execute("COMMIT;")
        }
    }

    // MARK: - The C API, wrapped once

    /// Everything that touches the connection goes through here. One lock, not an actor,
    /// because every caller is already on a task of its own and an actor would make even
    /// a 2 ms search `await`.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let why = error.map { String(cString: $0) } ?? "code \(rc)"
            sqlite3_free(error)
            throw VaultIndexError.sql(String(sql.prefix(60)), why)
        }
        sqlite3_free(error)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VaultIndexError.sql(String(sql.prefix(60)), String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    /// Bind, step to completion, and reset a prepared statement for its next use.
    private func run(_ stmt: OpaquePointer?, _ binder: (OpaquePointer) -> Void) throws {
        guard let stmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        binder(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw VaultIndexError.sql("write", String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_reset(stmt)
    }

    private func finalizeStatements() {
        for statement in [insertFile, deleteChunks, deleteLinks, insertChunk, insertLink,
                          deleteFile] {
            sqlite3_finalize(statement)
        }
        insertFile = nil
        deleteChunks = nil
        deleteLinks = nil
        insertChunk = nil
        insertLink = nil
        deleteFile = nil
    }

    private func scalar(_ sql: String) -> Int {
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func exists(path: String) -> Bool {
        guard let stmt = try? prepare("SELECT 1 FROM files WHERE path = ? LIMIT 1;") else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// At most three paths whose `column` equals `value` — three because the only
    /// question asked of this is "exactly one, or more than one".
    private func paths(whereColumn column: String, equals value: String) -> [String] {
        guard let stmt = try? prepare(
            "SELECT path FROM files WHERE \(column) = ? LIMIT 3;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, value)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT (-1) is not exposed to Swift: it tells SQLite to COPY the
        // bytes, which is what makes it safe to hand it a Swift String whose buffer
        // lives only for the duration of this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, column) else { return "" }
        return String(decodingCString: raw, as: UTF8.self)
    }
}
