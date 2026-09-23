import Foundation

// THE EDIT THAT WAS NOT SAVED WHEN THE PHONE RANG.
//
// An editor open on a phone is an editor that will be backgrounded mid-sentence, and iOS
// is free to terminate a backgrounded app without waking it again. An unsaved paragraph
// that exists only in a `TextEditor`'s binding is a paragraph that is gone, silently, and
// the person finds out by reopening the note and seeing the old text — which is worse than
// losing it, because it looks like the edit was never made.
//
// So the text is stashed on backgrounding and offered back next time that note's editor
// opens. THE STASH IS NOT A SAVE and is never written into the vault on its own: it is
// offered, and a person decides. An app that quietly wrote a three-day-old stash over a
// note somebody had since edited on the Studio would have invented a way to lose work that
// the vault did not previously have.
//
// APPLICATION SUPPORT, never the vault. A dot file inside Obsidian's folder syncs to every
// device the person owns and shows up in the note tree; and a half-finished draft of a
// note is exactly the thing that must not become a second note.
//
// Keyed by a HASH of the note's path, not by the path itself. Vault paths contain slashes
// and spaces and are up to a couple of hundred characters, and building a file name out of
// one is how you meet the filesystem's name limit on the one note with a long title.

/// One note's unsaved text, waiting to be offered back.
public struct VaultEditStashEntry: Codable, Equatable, Sendable {
    public let path: String
    public let text: String
    public let stashed: Date
    /// The stamp of the file the edit was started from, so the offer can say whether the
    /// note has moved on since.
    public let baseStamp: VaultFileStamp

    public init(path: String, text: String, stashed: Date, baseStamp: VaultFileStamp) {
        self.path = path
        self.text = text
        self.stashed = stashed
        self.baseStamp = baseStamp
    }

    /// What the restore prompt says under its title.
    public var age: String {
        "Unsaved since \(stashed.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Unsaved editor text, on disk, one file per note.
///
/// `@unchecked Sendable` on the same basis `OfflineWriteLog` states: every stored property
/// is a `let`, there is no cached state, and each call reads or writes one file under a
/// lock.
public final class VaultEditStash: @unchecked Sendable {

    public static let shared = VaultEditStash()

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                              in: .userDomainMask,
                                                              appropriateFor: nil,
                                                              create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base
            .appendingPathComponent("JesseVault", isDirectory: true)
            .appendingPathComponent("unsaved", isDirectory: true)
    }

    /// The file one note's stash lives in.
    ///
    /// A SHA-256 of the path, hex, plus `.json`. Deterministic (the same note finds its own
    /// stash next launch), collision-free in any sense that matters, and always a legal
    /// file name however the note was titled.
    public func url(forPath path: String) -> URL {
        directory.appendingPathComponent(VaultFileStamp(text: path).digest + ".json")
    }

    /// Keep this text for `path`. Replaces whatever was there: the newest unsaved version
    /// is the only one worth offering.
    public func stash(_ entry: VaultEditStashEntry) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry) else { return }
            try? data.write(to: url(forPath: entry.path), options: .atomic)
        }
    }

    /// What is being held for `path`, if anything.
    public func stashed(forPath path: String) -> VaultEditStashEntry? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url(forPath: path)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(VaultEditStashEntry.self, from: data)
        }
    }

    /// Forget it — what a save and an explicit discard both do.
    ///
    /// Called on EVERY save, including a save of text that matches the stash exactly:
    /// leaving it would mean the next open offers back an edit that is already in the file,
    /// and a restore prompt that appears when there is nothing to restore is a prompt
    /// people learn to dismiss without reading.
    public func clear(path: String) {
        lock.withLock { try? FileManager.default.removeItem(at: url(forPath: path)) }
    }

    /// Whether a stash is worth offering: there is one, and it differs from what is on
    /// disk now.
    ///
    /// Pure, so the rule is one line to assert. The case it exists for is ordinary: an
    /// edit is stashed, the app is killed, the person saves the same change from the Mac,
    /// and on reopening the phone there is nothing to restore — the text they would be
    /// offered is already the text in front of them.
    public static func isWorthOffering(_ entry: VaultEditStashEntry?, diskText: String) -> Bool {
        guard let entry else { return false }
        return entry.text != diskText
    }
}
