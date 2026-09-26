import Foundation

// THE ONE WAY A NOTE CHANGES, AND THE ONE PLACE THAT KNOWS THE WHOLE RITUAL.
//
// Ticking a box and saving an edited note are the same three steps in the same order, and
// they are written once, here, rather than twice in two screens:
//
//     1. refuse if the path is exempt        (`Today.md` is the bridge's file)
//     2. queue the record for the Studio     (`VaultWriteOutbox`: refused if it can't be)
//     3. `replace`, guarded by the stamp     (never an unguarded overwrite, ever)
//     4. reindex that one file, then log it  (so a search finds the words just typed)
//
// Step 2 is BEFORE the write and step 3 takes it back if the write fails. The device's
// folder reaches the Studio only through Obsidian, and Obsidian iOS does not sync a file
// another app changed, so a write that is not also queued for the bridge is a write that
// may exist only on this phone. Queue first, then write, is the only order in which
// neither half can be lost.
//
// Step 4 is AFTER the write and deliberately cannot fail the write. A reindex that threw
// would otherwise report "your edit did not save" about an edit that is already on disk,
// which is the worst lie this app could tell about a vault — the person would type it
// again and get two copies.
//
// A PROTOCOL, and that is not architecture for its own sake. The tick state machine and
// the editor model are where the interesting behaviour lives (stale, retry, stale again,
// conflict, overwrite) and none of it is reachable from a test if the only way to write is
// a real folder with a real security-scoped bookmark. The fake in the tests is forty lines
// and drives every branch.

/// What a write did to a file.
public enum VaultEditKind: String, Codable, Sendable, CaseIterable {
    /// A line appended into `Inbox/`. The only kind that existed before note editing, and
    /// the kind every record written by an older build decodes as.
    case capture
    case tick
    case untick
    case edit

    public var display: String {
        switch self {
        case .capture: return "captured"
        case .tick:    return "ticked"
        case .untick:  return "unticked"
        case .edit:    return "edited"
        }
    }

    /// True for the writes that changed bytes already in a file — the ones this prompt
    /// added, and the ones the diagnostics screen shows under Note writes.
    public var isInPlace: Bool { self != .capture }

    /// The kind a checkbox write is, from the state it moves to.
    public static func box(checked: Bool) -> VaultEditKind { checked ? .tick : .untick }
}

/// Reading a note for editing, and writing one back.
///
/// Both calls are `async` and neither touches the main actor: a coordinated read of a
/// quarter-megabyte note through a file provider is not a thing to do on the actor that
/// draws the frame.
public protocol VaultNoteWriting: Sendable {
    /// The note's text and the stamp of the bytes it came from.
    func readStamped(path: String) async throws -> (text: String, stamp: VaultFileStamp)

    /// Write `text` over the note, only if its bytes still match `expected`.
    func replace(path: String, expected: VaultFileStamp, with text: String,
                 kind: VaultEditKind) async throws -> VaultFileStamp
}

/// The real one: the device's vault folder, the coordinated writer, the outbox, the index
/// and the log.
public struct VaultNoteWriter: VaultNoteWriting {
    private let source: VaultIndexSource
    private let log: OfflineWriteLog
    /// Where every write is queued for the Studio. Nil only in a test that is not about it.
    private let outbox: VaultWriteOutbox?

    public init(source: VaultIndexSource = .shared, log: OfflineWriteLog = .shared,
                outbox: VaultWriteOutbox? = .shared) {
        self.source = source
        self.log = log
        self.outbox = outbox
    }

    public func readStamped(path: String) async throws -> (text: String, stamp: VaultFileStamp) {
        let source = self.source
        return try await Task.detached {
            try source.vaultFolder.withAccess { root in
                try VaultFile(root: root).readStamped(relativePath: path)
            }
        }.value
    }

    public func replace(path: String, expected: VaultFileStamp, with text: String,
                        kind: VaultEditKind) async throws -> VaultFileStamp {
        // THE EXEMPTION, ENFORCED HERE rather than only captioned in the reader. A screen
        // that declines to show a control is a convention; a writer that refuses the path
        // is the guarantee, and it holds for the editor's Save and the tick alike.
        guard !VaultWriteExemption.isReadOnly(path: path) else {
            throw VaultFileError.unwritable(path, "Today.md is written by the bridge, not by this app.")
        }
        let source = self.source
        let log = self.log
        let outbox = self.outbox
        // The BASE: the bytes the stamp names, which the record carries so the Studio can
        // merge against them. A file that has already moved is refused here exactly as the
        // guarded replace would refuse it.
        let base = try await readStamped(path: path)
        guard base.stamp == expected else { throw VaultFileError.changedSinceRead(path) }
        let record = VaultWriteRecord.replacing(localPath: path, base: base.text,
                                                baseStamp: expected, new: text, kind: kind)
        if let outbox {
            do {
                try await outbox.enqueue(record)
            } catch {
                throw VaultFileError.unwritable(
                    path, "It couldn't be queued for the Studio, so it wasn't written: \(error.localizedDescription)")
            }
        }
        let stamp: VaultFileStamp
        do {
            stamp = try await Task.detached {
                try source.vaultFolder.withAccess { root -> VaultFileStamp in
                    try VaultFile(root: root).replace(relativePath: path, expected: expected,
                                                      with: text)
                }
            }.value
        } catch {
            // Never written, so never a write: the Studio must not hear of it either.
            await outbox?.remove(id: record.id)
            throw error
        }
        // Everything from here on is BEST EFFORT and cannot fail the write, which has
        // already happened. See the file comment.
        await Task.detached {
            Self.reindex(path: path, source: source)
            log.record(OfflineWriteRecord(id: record.id,
                                          written: Date(), file: path,
                                          bytes: stamp.bytes,
                                          checksum: stamp.digest,
                                          text: "",
                                          about: nil,
                                          status: .written,
                                          kind: kind,
                                          bytesBefore: expected.bytes))
        }.value
        if let outbox { Task { await outbox.flush() } }
        return stamp
    }

    /// Re-read and re-chunk this ONE file, debounce ignored.
    ///
    /// Not `reindexIfDue`: the debounce exists so that coming back to the app does not walk
    /// the vault every time, and it is exactly wrong here. A person who just typed a
    /// sentence and searched for it within thirty seconds is the normal case, not the
    /// unusual one, and a search that cannot find what you have just written is a search
    /// you stop trusting.
    static func reindex(path: String, source: VaultIndexSource) {
        guard let index = try? source.index() else { return }
        try? source.vaultFolder.withAccess { root in
            try? index.reindex(file: path, root: root)
        }
    }
}

/// A write to the STUDIO'S copy of a note, shown because the device's copy is behind.
///
/// It never touches the Obsidian folder. That folder is behind the Studio, and writing a
/// changed copy of an older version into it is precisely the conflict this app must not
/// create for Obsidian to find later. The write goes into the outbox with the Studio's
/// hash as its base, is sent at once, and the reader then shows the Studio's copy again.
public struct VaultBridgeCopyWriter: VaultNoteWriting {
    private let localPath: String
    private let text: String
    private let stamp: VaultFileStamp
    private let outbox: VaultWriteOutbox
    private let opener: VaultNoteOpener?

    /// `text` and `stamp` are the Studio's copy as the reader holds it now.
    public init(localPath: String, text: String, stamp: VaultFileStamp,
                outbox: VaultWriteOutbox = .shared, opener: VaultNoteOpener? = .shared) {
        self.localPath = localPath
        self.text = text
        self.stamp = stamp
        self.outbox = outbox
        self.opener = opener
    }

    public func readStamped(path: String) async throws -> (text: String, stamp: VaultFileStamp) {
        (text, stamp)
    }

    public func replace(path: String, expected: VaultFileStamp, with new: String,
                        kind: VaultEditKind) async throws -> VaultFileStamp {
        guard !VaultWriteExemption.isReadOnly(path: path) else {
            throw VaultFileError.unwritable(path, "Today.md is written by the bridge, not by this app.")
        }
        guard expected == stamp else { throw VaultFileError.changedSinceRead(path) }
        let record = VaultWriteRecord.replacing(localPath: localPath, base: text,
                                                baseStamp: expected, new: new, kind: kind)
        do {
            try await outbox.enqueue(record)
        } catch {
            throw VaultFileError.unwritable(
                path, "It couldn't be queued for the Studio: \(error.localizedDescription)")
        }
        // Sent now and awaited, so the reader that reloads next reads the Studio's answer.
        await outbox.flush()
        await opener?.forget(path: localPath)
        return VaultFileStamp(text: new)
    }
}
