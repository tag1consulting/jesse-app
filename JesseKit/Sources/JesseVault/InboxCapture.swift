import Foundation
import CryptoKit

// A THOUGHT, CAPTURED, WITH NOTHING BETWEEN IT AND THE VAULT.
//
// Every write this app has ever made went through the bridge. A tick, a meal, a quick
// log, a message: all of them are composed on the device, put in the capture queue, and
// are worth exactly what the queue is worth until the Studio comes back and spends a
// hosted turn landing them. That is the right shape for anything that needs the agent to
// do something, and the wrong shape for "remember this", because the vault itself is
// already on this device, writable, and synced by Obsidian independently of the bridge.
//
// So this writes the note directly. `Inbox/YYYY-MM-DD-<platform>.md`, appended, and the
// morning routine already reads every file under `Inbox/` — which is why there is no new
// machinery on the Studio side and no new file shape for it to learn.
//
// THE ONE PATH. `Inbox/YYYY-MM-DD-phone.md` on iOS, `-mac` on macOS, and nothing else,
// ever. Not a journal, not a project file, not `Today.md`, not a CSV. The suffix is what
// keeps two devices capturing on the same day out of each other's file rather than
// merging into one and racing.
//
// EVERY DECISION HERE IS A PURE FUNCTION over a `Date` and a `TimeZone`. The path, the
// heading, the entry and its checksum are all computable without a filesystem, which is
// what makes "the date is the DEVICE's date" and "a multi-line capture indents under its
// own bullet" assertable rather than inferred from whether a written file looked right.

/// Which device wrote a capture, as the FILE NAME sees it.
///
/// Not the device's name — that is a separate argument, and it goes in the line. This is
/// the one-word suffix that keeps the phone's captures and the Mac's captures in two
/// files on a day both of them wrote.
public enum InboxCapturePlatform: String, Sendable, CaseIterable, Codable {
    case phone
    case mac

    /// This build's own. iOS (and anything that is not macOS) is "phone".
    public static var current: InboxCapturePlatform {
        #if os(macOS)
        return .mac
        #else
        return .phone
        #endif
    }

    /// The file name suffix: `Inbox/2026-09-23-phone.md`.
    public var suffix: String { rawValue }

    /// How the file's own first line names it: "# Phone captures 2026-09-23".
    public var heading: String {
        switch self {
        case .phone: return "Phone"
        case .mac: return "Mac"
        }
    }
}

public enum InboxCaptureError: Error, Equatable, CustomStringConvertible {
    case emptyText
    case tooLong(characters: Int, limit: Int)

    public var description: String {
        switch self {
        case .emptyText:
            return "Nothing to capture."
        case .tooLong(let characters, let limit):
            return "That is \(characters) characters; a capture holds \(limit). "
                 + "Shorten it, or send it to Jesse when the Studio is back."
        }
    }
}

/// What one capture actually put on disk.
///
/// `entry` is the exact text of the appended entry — not the header — because it is what
/// the write log checksums, what the verification looks for in the file afterwards, and
/// what a re-capture writes again.
public struct InboxCaptureWrite: Equatable, Sendable {
    public let relativePath: String
    public let entry: String
    /// True when this capture is the one that created the file (and wrote its heading).
    public let createdFile: Bool
    /// Bytes this call appended: the heading too, on the call that created the file.
    public let bytesAppended: Int
    public let checksum: String
    /// The file's size afterwards, so "it only grew" is checkable by the caller.
    public let fileBytes: Int

    public init(relativePath: String, entry: String, createdFile: Bool,
                bytesAppended: Int, checksum: String, fileBytes: Int) {
        self.relativePath = relativePath
        self.entry = entry
        self.createdFile = createdFile
        self.bytesAppended = bytesAppended
        self.checksum = checksum
        self.fileBytes = fileBytes
    }
}

/// One capture, into one file, under `Inbox/`.
public struct InboxCapture: Sendable {

    /// Longer than this is refused rather than truncated: a capture that silently lost
    /// its second half is worse than one that was not taken.
    public static let characterLimit = 4_000

    /// The one directory. A capture cannot name another.
    public static let directory = "Inbox"

    public let file: VaultFile
    public let platform: InboxCapturePlatform

    public init(file: VaultFile, platform: InboxCapturePlatform = .current) {
        self.file = file
        self.platform = platform
    }

    /// Append one entry, creating the file with its heading when it is absent.
    ///
    /// THE ENTRY IS BUILT BEFORE THE FILE IS TOUCHED. An empty or oversize capture throws
    /// here, which is what guarantees a refused capture cannot leave a newly created,
    /// heading-only file behind.
    @discardableResult
    public func capture(text: String,
                        about: String? = nil,
                        device: String,
                        now: Date = Date(),
                        timeZone: TimeZone = .current) throws -> InboxCaptureWrite {
        let entry = try Self.entry(text: text, about: about, device: device,
                                  now: now, timeZone: timeZone)
        let path = Self.relativePath(platform: platform, now: now, timeZone: timeZone)
        let heading = Self.fileHeader(platform: platform, now: now, timeZone: timeZone)
        // The existence test happens INSIDE the same coordination bracket as the write
        // (see `VaultFile.appendCreating`). Asking `exists` here and appending afterwards
        // would leave a window in which Obsidian's sync creates the file and the heading
        // lands in the middle of it.
        let result = try file.appendCreating(relativePath: path, prologue: heading, text: entry)
        return InboxCaptureWrite(
            relativePath: path,
            entry: entry,
            createdFile: result.created,
            bytesAppended: (result.created ? heading.utf8.count : 0) + entry.utf8.count,
            checksum: Self.checksum(entry),
            fileBytes: result.size)
    }

    /// Write an already-formed entry back into the file it belongs to.
    ///
    /// What a Re-capture does. It appends the ORIGINAL entry, with its original timestamp,
    /// into the file the write log says it was meant to be in — not a new entry in today's
    /// file. Re-stamping it would make one capture look like two on two different days, and
    /// appending the original line to today's file would put yesterday's `HH:MM` under
    /// today's heading.
    ///
    /// Its checksum is therefore unchanged, which is what lets the verification pass
    /// confirm the re-capture rather than leaving the row "not found" forever.
    @discardableResult
    public func rewrite(entry: String, relativePath: String,
                        now: Date = Date(),
                        timeZone: TimeZone = .current) throws -> InboxCaptureWrite {
        let heading = Self.fileHeader(forRelativePath: relativePath, fallbackNow: now,
                                     timeZone: timeZone)
        let result = try file.appendCreating(relativePath: relativePath,
                                            prologue: heading, text: entry)
        return InboxCaptureWrite(
            relativePath: relativePath,
            entry: entry,
            createdFile: result.created,
            bytesAppended: (result.created ? heading.utf8.count : 0) + entry.utf8.count,
            checksum: Self.checksum(entry),
            fileBytes: result.size)
    }

    // MARK: - The pure half

    /// `Inbox/2026-09-23-phone.md`, with the date in the DEVICE's own time zone: the file
    /// is looked for by a person opening Obsidian on the day they captured, and a UTC date
    /// puts an evening thought in Italy into tomorrow's file.
    public static func relativePath(platform: InboxCapturePlatform,
                                    now: Date,
                                    timeZone: TimeZone = .current) -> String {
        "\(directory)/\(isoDay(now, timeZone: timeZone))-\(platform.suffix).md"
    }

    /// The file's first line.
    public static func heading(platform: InboxCapturePlatform,
                               now: Date,
                               timeZone: TimeZone = .current) -> String {
        "# \(platform.heading) captures \(isoDay(now, timeZone: timeZone))"
    }

    /// The heading and the blank line under it — everything written ahead of the first
    /// entry, and only on the call that creates the file.
    public static func fileHeader(platform: InboxCapturePlatform,
                                  now: Date,
                                  timeZone: TimeZone = .current) -> String {
        heading(platform: platform, now: now, timeZone: timeZone) + "\n\n"
    }

    /// One entry, with its trailing newline.
    ///
    /// `- HH:MM (<device>): <text>` on one line. A multi-line capture keeps its shape by
    /// indenting every line after the first by two spaces, which is what makes it one
    /// list item in Obsidian rather than a bullet followed by loose paragraphs.
    ///
    /// When `about` names a note, the text begins with that path in a code span, so the
    /// triage can file the thought against the note without guessing which note it meant.
    public static func entry(text: String,
                             about: String? = nil,
                             device: String,
                             now: Date,
                             timeZone: TimeZone = .current) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InboxCaptureError.emptyText }
        guard trimmed.count <= characterLimit else {
            throw InboxCaptureError.tooLong(characters: trimmed.count, limit: characterLimit)
        }
        var head = "- \(clock(now, timeZone: timeZone)) (\(label(device: device))): "
        if let path = normalizedAbout(about) {
            head += "`\(path)` "
        }
        let lines = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out = head + (lines.first ?? "")
        for line in lines.dropFirst() {
            // A blank line inside a capture is written as a TRULY empty line, never as two
            // spaces: trailing whitespace in someone's vault is litter, and the indented
            // line after it is what keeps the list item together anyway. "Blank" means
            // whitespace-only, not just empty — a pasted line of spaces would otherwise
            // land as five spaces and be exactly the litter this avoids.
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            out += "\n" + (blank ? "" : "  " + line)
        }
        return out + "\n"
    }

    /// The path a capture is ABOUT, normalized, or nil when there is nothing usable.
    ///
    /// A bad path is dropped rather than refused. The capture is the thing being saved;
    /// losing a thought because the note it referred to had an odd path would be the
    /// wrong trade, and a bogus path in a code span is worse than none — the triage would
    /// file the line against a note that does not exist.
    public static func normalizedAbout(_ about: String?) -> String? {
        guard let about, !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // A backtick would close the code span early and turn the rest of the line into
        // markup; there is no escaping it inside a span, so such a path is simply dropped.
        guard !about.contains("`") else { return nil }
        guard let components = try? VaultFile.validatedComponents(about) else { return nil }
        return components.joined(separator: "/")
    }

    /// The device's own name, reduced to something that cannot break a one-line entry.
    static func label(device: String) -> String {
        let flattened = device
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Parentheses would close the entry's own bracket early.
        let cleaned = flattened.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return cleaned.isEmpty ? "unknown device" : cleaned
    }

    /// `HH:MM` in the device's zone, 24-hour, independent of locale — this is a file
    /// format, not a presentation.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `YYYY-MM-DD` in the device's zone.
    public static func isoDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The day and the platform a capture file's own name carries, or nil when the name is
    /// not one this type would have produced.
    ///
    /// Used only to rebuild the right heading for a file that has to be recreated. Refusing
    /// to guess is the point: a name we did not write gets today's heading rather than a
    /// fabricated one.
    public static func describe(relativePath: String) -> (day: String, platform: InboxCapturePlatform)? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == directory else { return nil }
        let name = components[1]
        guard name.hasSuffix(".md") else { return nil }
        let stem = String(name.dropLast(3))
        // `YYYY-MM-DD-<platform>`: four fields, the first three numeric.
        let fields = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields[0].allSatisfy(\.isNumber),
              fields[1].allSatisfy(\.isNumber),
              fields[2].allSatisfy(\.isNumber),
              let platform = InboxCapturePlatform(rawValue: String(fields[3]))
        else { return nil }
        return ("\(fields[0])-\(fields[1])-\(fields[2])", platform)
    }

    /// The heading a given capture file should carry, read from its own name where possible
    /// and from the clock otherwise.
    public static func fileHeader(forRelativePath path: String,
                                  fallbackNow: Date,
                                  timeZone: TimeZone = .current) -> String {
        guard let described = describe(relativePath: path) else {
            return fileHeader(platform: .current, now: fallbackNow, timeZone: timeZone)
        }
        return "# \(described.platform.heading) captures \(described.day)\n\n"
    }

    /// SHA-256 of the entry's UTF-8 bytes, hex.
    ///
    /// It is what the write log records, and what the verification pass re-derives and
    /// compares before saying a capture is still in its file. CryptoKit is already linked
    /// here (the index names its database with it), so this costs nothing new.
    public static func checksum(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a person reads in the transcript when a capture went to the vault instead of to
/// the bridge.
///
/// The wording lives here, in one place, for the reason `OfflineLookupReply`'s does: "this
/// is in your vault on this device" and "Jesse has this" are two different promises, and
/// two composers each writing their own version of that sentence is how they stop being
/// distinguishable.
public enum InboxCaptureReply {

    /// `[captured offline · Inbox/2026-09-23-phone.md]` — the same bracketed, middle-dot
    /// shape every other local-route badge in the app uses.
    public static func badge(path: String) -> String {
        "[captured offline · \(path)]"
    }

    /// The local turn's whole text: the badge, then the entry exactly as it was written.
    public static func body(_ write: InboxCaptureWrite) -> String {
        badge(path: write.relativePath) + "\n\n"
            + write.entry.trimmingCharacters(in: .newlines)
    }
}
