import Foundation

// WHAT THIS DEVICE WROTE, AND WHETHER IT IS STILL THERE.
//
// A capture that goes into the vault folder rather than into the capture queue leaves the
// app's world immediately: from the instant the append returns, the only thing that knows
// about it is a file Obsidian owns and syncs on its own schedule. That is the whole point
// of the feature and also its one risk — a sync that never happens, a folder that was
// re-picked, a file someone tidied away — and a write nobody recorded is a write nobody
// can notice the loss of.
//
// So every capture is logged: when, which file, how many bytes, and a checksum of the
// bytes appended. The log is the reason the diagnostics screen can say "verified" rather
// than "written and hoped", and the reason a capture whose line has gone can be offered
// back to be written again.
//
// IT IS NOT A QUEUE. Nothing here retries, nothing here re-appends, and the verification
// pass only ever changes a status. A line that has gone is reported to a person, who
// decides — because the one failure mode worse than a lost capture is the same capture
// appearing four times because a background pass kept fixing it.
//
// Application Support, never the vault: a JSON file inside the folder Obsidian syncs would
// show up in the note tree on every device the user owns.

/// Where one logged capture stands.
public enum OfflineWriteStatus: String, Codable, Sendable, CaseIterable {
    /// Appended. Nothing has looked at the file since.
    case written
    /// Re-read, and the checksummed bytes are still in the file.
    case verified
    /// Re-read, and they are not — or the file itself could not be read.
    case notFound = "not_found"

    public var display: String {
        switch self {
        case .written: return "written"
        case .verified: return "verified"
        case .notFound: return "not found in file"
        }
    }

    /// True for the one status that asks a person to do something.
    public var needsAttention: Bool { self == .notFound }
}

/// One write, as the log holds it.
///
/// It began as a record of CAPTURES — appends into `Inbox/`, which is all this device could
/// do to a vault. Note editing added two more ways to write, so the record grew a `kind`
/// and the two numbers an in-place write has that an append does not (the size before, and
/// the stamp of the whole file after). One log rather than two, because "what has this
/// device written into the vault" is one question a person asks, and answering it from two
/// screens that each know half would be the reason the half nobody opened went unnoticed.
public struct OfflineWriteRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let written: Date
    /// The vault-relative file it was appended to, or written over.
    public let file: String
    /// For a capture, the bytes appended. For an in-place write, the file's size AFTER it.
    public let bytes: Int
    /// SHA-256 of `text`, taken at write time.
    public let checksum: String
    /// The appended entry, verbatim.
    ///
    /// Kept so a capture the verification cannot find can be written again without the
    /// person having to remember what they wrote. It is the ONE thing here that is worth
    /// keeping and is also personal, which is why the log holds twenty of them on a screen
    /// and two hundred on disk rather than a year of them.
    public let text: String
    /// The note the capture was about, when it was about one.
    public let about: String?
    public var status: OfflineWriteStatus
    /// How this write changed the file. Absent from every record written before note
    /// editing existed, and those are all captures — see `init(from:)`.
    public let kind: VaultEditKind
    /// The file's size BEFORE an in-place write, so a row can say "4,812 B → 4,813 B" and
    /// a tick that somehow rewrote a note is visible as a number rather than a suspicion.
    /// Nil for a capture, which grew the file by `bytes` and has nothing else to say.
    public let bytesBefore: Int?

    public init(id: UUID = UUID(), written: Date, file: String, bytes: Int,
                checksum: String, text: String, about: String? = nil,
                status: OfflineWriteStatus = .written,
                kind: VaultEditKind = .capture,
                bytesBefore: Int? = nil) {
        self.id = id
        self.written = written
        self.file = file
        self.bytes = bytes
        self.checksum = checksum
        self.text = text
        self.about = about
        self.status = status
        self.kind = kind
        self.bytesBefore = bytesBefore
    }

    /// Decoded by hand for ONE reason: the two new keys are absent from every row already
    /// on disk, and a synthesized decoder treats a missing key for a non-optional property
    /// as a failure of the whole array. The log's loader turns a decode failure into an
    /// empty log, so the synthesized version would have silently erased every capture this
    /// device had ever recorded the first time the new build ran. A row without a `kind`
    /// is a capture, because when it was written that is the only thing this app could do.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        written = try container.decode(Date.self, forKey: .written)
        file = try container.decode(String.self, forKey: .file)
        bytes = try container.decode(Int.self, forKey: .bytes)
        checksum = try container.decode(String.self, forKey: .checksum)
        text = try container.decode(String.self, forKey: .text)
        about = try container.decodeIfPresent(String.self, forKey: .about)
        status = try container.decodeIfPresent(OfflineWriteStatus.self, forKey: .status) ?? .written
        kind = try container.decodeIfPresent(VaultEditKind.self, forKey: .kind) ?? .capture
        bytesBefore = try container.decodeIfPresent(Int.self, forKey: .bytesBefore)
    }

    /// The same record with a different status. The log rewrites rows this way rather than
    /// holding a mutable reference: a record is a value, and a verification pass that
    /// mutated one in place could not be a pure function.
    public func with(status: OfflineWriteStatus) -> OfflineWriteRecord {
        OfflineWriteRecord(id: id, written: written, file: file, bytes: bytes,
                           checksum: checksum, text: text, about: about, status: status,
                           kind: kind, bytesBefore: bytesBefore)
    }

    /// True for the appends into `Inbox/`. The verification pass and the Captures section
    /// both ask, because neither means anything for an in-place write: a capture is "is my
    /// line still in the file", and an edit IS the file.
    public var isCapture: Bool { kind == .capture }

    /// What the capture said, on one line, for a diagnostics row.
    public var summary: String {
        let flattened = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > 60 ? String(flattened.prefix(59)) + "…" : flattened
    }

    /// The monospaced line the diagnostics screen draws.
    ///
    /// Two shapes, because the two kinds of write have different things worth showing. A
    /// capture's interesting part is WHAT IT SAID, so the line ends with its text. An
    /// edit's interesting part is WHAT IT DID TO THE FILE, so the line carries the size
    /// either side and the stamp of the result — and never the text, which for an edit is
    /// the whole note and is not going on a diagnostics row.
    public var line: String {
        guard isCapture else {
            let before = bytesBefore.map { "\($0) B → " } ?? ""
            return "\(file) · \(kind.display) · \(before)\(bytes) B · \(String(checksum.prefix(8)))"
        }
        return "\(file) · \(bytes) B · \(status.display) · \(summary)"
    }
}

/// The last two hundred captures, on disk.
///
/// `@unchecked Sendable` on one basis, named rather than waved through: every stored
/// property is a `let`, and the file is read and rewritten only inside `lock`. There is no
/// cached array — each call reads the file — which is what makes an instance safe to hand
/// to a detached write task and to a `@MainActor` screen at the same time.
public final class OfflineWriteLog: @unchecked Sendable {

    /// The app's one log.
    public static let shared = OfflineWriteLog()

    /// Two hundred captures is months of them, and small enough (roughly 40 KB) that the
    /// whole file is read and rewritten per capture without anyone noticing.
    public static let capacity = 200

    /// What the diagnostics screen shows.
    public static let displayCount = 20

    public static let fileName = "offline-writes.json"

    public let url: URL
    private let lock = NSLock()

    /// `directory` nil means Application Support, which is what the app uses; a test
    /// passes its own temporary directory. The `JesseVault` subdirectory is shared with
    /// the search index, so the vault's local state is one directory rather than two.
    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                              in: .userDomainMask,
                                                              appropriateFor: nil,
                                                              create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base
            .appendingPathComponent("JesseVault", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    /// Newest first.
    public var records: [OfflineWriteRecord] {
        lock.withLock { load() }
    }

    /// The rows a screen shows.
    public var recent: [OfflineWriteRecord] {
        Array(records.prefix(Self.displayCount))
    }

    /// The last `displayCount` captures, and the last `displayCount` in-place writes.
    ///
    /// Filtered THEN cut, never cut then filtered: twenty ticks in an afternoon would
    /// otherwise push every capture off a screen whose whole job is to show them.
    public var recentCaptures: [OfflineWriteRecord] {
        Array(records.filter(\.isCapture).prefix(Self.displayCount))
    }

    public var recentEdits: [OfflineWriteRecord] {
        Array(records.filter { !$0.isCapture }.prefix(Self.displayCount))
    }

    /// Log one capture, dropping the oldest if the cap is reached.
    public func record(_ entry: OfflineWriteRecord) {
        lock.withLock {
            var all = load()
            all.insert(entry, at: 0)
            if all.count > Self.capacity {
                all.removeLast(all.count - Self.capacity)
            }
            save(all)
        }
    }

    /// Apply a verification pass's verdicts. Rows the pass did not look at are untouched,
    /// and a row that has since been dropped by the cap is simply not there to update.
    public func apply(statuses: [UUID: OfflineWriteStatus]) {
        guard !statuses.isEmpty else { return }
        lock.withLock {
            let all = load()
            let updated = all.map { record -> OfflineWriteRecord in
                guard let status = statuses[record.id], status != record.status else {
                    return record
                }
                return record.with(status: status)
            }
            guard updated != all else { return }
            save(updated)
        }
    }

    public func clear() {
        lock.withLock { save([]) }
    }

    // MARK: - The file

    /// The encoder and decoder both carry `.iso8601`, so the file on disk is readable by a
    /// person looking at it and does not depend on Foundation's reference-date default.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Must be called inside `lock`.
    private func load() -> [OfflineWriteRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A log that cannot be decoded is an empty log, not a crash: it is a diagnostics
        // aid, and the next capture rewrites it.
        return (try? Self.makeDecoder().decode([OfflineWriteRecord].self, from: data)) ?? []
    }

    /// Must be called inside `lock`.
    private func save(_ records: [OfflineWriteRecord]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let data = try? Self.makeEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Re-reading the capture files and saying whether each logged capture is still in one.
///
/// Pure over a `read` closure. That is the whole reason this is a type of its own rather
/// than a method on the service: "the file is there and the entry is in it", "the file is
/// there and the entry has gone" and "the file itself has gone" are three cases a test
/// states in three lines, and none of them needs a vault, a bookmark or an app.
public enum OfflineWriteVerifier {

    /// The verdict for each record, keyed by id. Records already `verified` are checked
    /// again — a line can be deleted after it was confirmed, and a status that is only
    /// ever written once is a status that goes stale silently.
    ///
    /// Each file is read ONCE however many records name it: twenty captures on one day is
    /// the normal case, and twenty coordinated reads of the same file would be twenty
    /// times the work for one answer.
    public static func statuses(for records: [OfflineWriteRecord],
                                read: (String) throws -> String) -> [UUID: OfflineWriteStatus] {
        var contents: [String: String?] = [:]
        var verdicts: [UUID: OfflineWriteStatus] = [:]
        // CAPTURES ONLY. "Is the line still in the file" is a question about an append; an
        // in-place write replaced the file, so its logged checksum is of the whole note and
        // `contains` would be asking whether a file contains itself — via a record whose
        // `text` is empty, which every file trivially contains. Left in, every edit would
        // have been reported `not found` the moment somebody pressed Check.
        for record in records where record.isCapture {
            let text: String?
            if let cached = contents[record.file] {
                text = cached
            } else {
                text = try? read(record.file)
                contents[record.file] = text
            }
            guard let text else {
                // The file could not be read at all: deleted, renamed, or the folder is
                // gone. Not found, and the log still holds the text.
                verdicts[record.id] = .notFound
                continue
            }
            // BOTH halves. The checksum proves the log's own copy of the entry is the one
            // that was written, and `contains` proves those bytes are still in the file.
            // Either alone would be satisfiable by a record nobody should trust.
            let intact = InboxCapture.checksum(record.text) == record.checksum
            verdicts[record.id] = (intact && text.contains(record.text)) ? .verified : .notFound
        }
        return verdicts
    }
}
