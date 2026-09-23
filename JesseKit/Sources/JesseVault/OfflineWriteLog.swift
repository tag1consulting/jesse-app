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

/// One capture, as the log holds it.
public struct OfflineWriteRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let written: Date
    /// The vault-relative file it was appended to.
    public let file: String
    /// Bytes this capture appended, the file's heading included when it created the file.
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

    public init(id: UUID = UUID(), written: Date, file: String, bytes: Int,
                checksum: String, text: String, about: String? = nil,
                status: OfflineWriteStatus = .written) {
        self.id = id
        self.written = written
        self.file = file
        self.bytes = bytes
        self.checksum = checksum
        self.text = text
        self.about = about
        self.status = status
    }

    /// The same record with a different status. The log rewrites rows this way rather than
    /// holding a mutable reference: a record is a value, and a verification pass that
    /// mutated one in place could not be a pure function.
    public func with(status: OfflineWriteStatus) -> OfflineWriteRecord {
        OfflineWriteRecord(id: id, written: written, file: file, bytes: bytes,
                           checksum: checksum, text: text, about: about, status: status)
    }

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
    public var line: String {
        "\(file) · \(bytes) B · \(status.display) · \(summary)"
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
        for record in records {
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
