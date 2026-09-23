import Foundation
import CryptoKit

// WHAT THE FILE LOOKED LIKE WHEN WE READ IT, AND WHAT SHAPE TO GIVE IT BACK.
//
// Two separate jobs, both pure, both here because both are the difference between an
// edit that changes one line and an edit that quietly rewrites a note.
//
// THE STAMP is the guard on every write. `replace` is a read-modify-write, which is
// exactly the shape `append` was designed to avoid, and the only honest way to run one
// against a folder Obsidian is syncing is to prove the bytes are still the bytes you
// read. Byte count plus SHA-256: the count makes the common mismatch free to detect and
// the digest makes a same-length edit (a `[ ]` that became a `[x]` on the Studio) just as
// detectable. A modification date would have been cheaper and is not good enough — a sync
// can land bytes whose mtime is older than the read.
//
// THE SHAPE is the rule that stops an edit touching lines nobody edited. A file written
// on a machine that uses CRLF and saved back with LF is a file where every line changed,
// which is a diff nobody can review and a sync conflict waiting to happen. Same for the
// trailing newline: a note that ended without one gets no new one, and a note that ended
// with one gets exactly one back, never two.

/// A file's identity at the moment it was read.
public struct VaultFileStamp: Equatable, Sendable, Codable {
    /// UTF-8 bytes.
    public let bytes: Int
    /// Lowercase hex SHA-256 of those bytes.
    public let digest: String

    public init(bytes: Int, digest: String) {
        self.bytes = bytes
        self.digest = digest
    }

    /// The stamp of some text, taken over its UTF-8 encoding.
    ///
    /// Over the ENCODING and not over the `String`, deliberately: the thing on disk is
    /// bytes, and two Swift strings that compare equal can encode differently once
    /// normalization is involved. The digest has to mean "these bytes", or the guard is
    /// checking something other than what it is protecting.
    public init(text: String) {
        self.init(data: Data(text.utf8))
    }

    public init(data: Data) {
        bytes = data.count
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A short form for a diagnostics row. The full digest is 64 characters, which is a
    /// line of its own on a phone and tells a person nothing more than the first eight.
    public var shortDigest: String { String(digest.prefix(8)) }
}

/// The two things about a file's text that an edit must give back unchanged.
public struct VaultTextShape: Equatable, Sendable {
    public enum LineEnding: String, Equatable, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
    }

    public let lineEnding: LineEnding
    /// The file's last byte was a newline.
    public let endsWithNewline: Bool

    public init(lineEnding: LineEnding, endsWithNewline: Bool) {
        self.lineEnding = lineEnding
        self.endsWithNewline = endsWithNewline
    }

    /// The shape of `text` as read.
    ///
    /// The line ending is decided by the FIRST line break in the file, not by a count of
    /// which kind is commoner. A mixed file is already somebody's accident, and picking
    /// the majority would silently normalise the minority away — which is precisely the
    /// whole-file rewrite this type exists to prevent. The first break is what the file
    /// announced itself as, and a file with no break at all is LF, because that is what
    /// the next line added to it will be.
    ///
    /// OVER THE UTF-8 VIEW, and that is not fussiness. Swift's `Character` is a grapheme
    /// cluster and `"\r\n"` is ONE of them, so `for c in text where c == "\n"` never
    /// matches a CRLF break and `"a\r\n".hasSuffix("\n")` is FALSE. Both of those are
    /// exactly the questions being asked here, and both would have answered wrongly on
    /// precisely the files this type exists for. Bytes have no such opinion.
    public static func of(_ text: String) -> VaultTextShape {
        let utf8 = Array(text.utf8)
        var ending = LineEnding.lf
        for (offset, byte) in utf8.enumerated() where byte == 0x0A {
            ending = offset > 0 && utf8[offset - 1] == 0x0D ? .crlf : .lf
            break
        }
        return VaultTextShape(lineEnding: ending,
                              endsWithNewline: utf8.last == 0x0A)
    }

    /// `text` with every line break normalised to LF — the form every pure edit in this
    /// target works in, so no rule has to be written twice.
    ///
    /// Byte-wise, for the reason `of` gives, and with one extra consequence worth naming:
    /// a `replacingOccurrences(of: "\r\n", with: "\n")` over a pathological `"a\r\r\n"`
    /// leaves `"a\r\n"` — it turned a mixed mess into a CRLF file. Dropping every CR that
    /// precedes an LF, in one pass, cannot do that.
    public static func normalised(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.contains(0x0D) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        for (offset, byte) in utf8.enumerated() {
            if byte == 0x0D, offset + 1 < utf8.count, utf8[offset + 1] == 0x0A { continue }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `text`, which is in LF form, given this shape back.
    ///
    /// Idempotent and total: safe to hand text that already carries CRLF or already ends
    /// in a newline, because it normalises first and applies the rule at most once.
    ///
    /// THE TRAILING-NEWLINE RULE IS "ADD AT MOST ONE", NEVER "TRIM TO ONE", and the
    /// difference is the whole guarantee of this prompt. Trimming would mean a note that
    /// deliberately ends with three blank lines comes back with none — so ticking one
    /// checkbox two hundred lines above them would silently delete them, which is exactly
    /// the "nothing he did not touch is ever changed" promise broken by the very function
    /// written to keep it. So: a newline is appended only when the original had one and
    /// the new text has none. That still gives the round trip its one guarantee that
    /// matters — a save can never DOUBLE the file's final newline — while leaving every
    /// byte the caller actually produced alone.
    public func applied(to text: String) -> String {
        var bytes = Array(Self.normalised(text).utf8)
        if endsWithNewline, bytes.last != 0x0A { bytes.append(0x0A) }
        if lineEnding == .crlf {
            var crlf: [UInt8] = []
            crlf.reserveCapacity(bytes.count + bytes.count / 40)
            for byte in bytes {
                if byte == 0x0A { crlf.append(0x0D) }
                crlf.append(byte)
            }
            bytes = crlf
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
