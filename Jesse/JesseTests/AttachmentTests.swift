import XCTest
import Foundation
@testable import Jesse

/// Covers the share transcript and the client-side attachment logic — the parts
/// that are pure and testable without a server or the UI. The bridge re-runs the
/// same validation as the authority; these guard the client's mirror of it.
@MainActor
final class AttachmentTests: XCTestCase {

    // MARK: - Share transcript

    @MainActor
    func testSharedTranscriptIsRoleLabeledMarkdown() {
        let thread = JesseThread(title: "t", mode: .ask)
        let t0 = Date(timeIntervalSince1970: 0)
        thread.turns.append(Turn(role: .user, text: "what's up?",
                                 createdAt: t0))
        thread.turns.append(Turn(role: .jesse, text: "Not much.",
                                 createdAt: t0.addingTimeInterval(1)))
        let s = thread.sharedTranscript
        XCTAssertEqual(s, "**You:** what's up?\n\n**Jesse:** Not much.")
    }

    @MainActor
    func testSharedTranscriptEmptyThreadIsEmptyString() {
        let thread = JesseThread(title: "t", mode: .ask)
        XCTAssertEqual(thread.sharedTranscript, "")
    }

    // MARK: - Magic-byte sniff

    func testSniffMimeDetectsWhitelistedTypes() {
        XCTAssertEqual(JesseAttachment.sniffMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
                       "image/png")
        XCTAssertEqual(JesseAttachment.sniffMime(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(JesseAttachment.sniffMime(Data("GIF89a....".utf8)), "image/gif")
        XCTAssertEqual(JesseAttachment.sniffMime(Data("%PDF-1.7\n".utf8)), "application/pdf")
        XCTAssertEqual(JesseAttachment.sniffMime(Data("RIFF\u{24}\u{00}\u{00}\u{00}WEBPVP8 ".utf8)),
                       "image/webp")
        XCTAssertEqual(JesseAttachment.sniffMime(Data("\u{00}\u{00}\u{00}\u{18}ftypheic\u{00}\u{00}\u{00}\u{00}".utf8)),
                       "image/heic")
    }

    func testSniffMimeRejectsUnknownAndShort() {
        XCTAssertNil(JesseAttachment.sniffMime(Data("plain text".utf8)))
        XCTAssertNil(JesseAttachment.sniffMime(Data()))
        XCTAssertNil(JesseAttachment.sniffMime(Data([0xFF, 0xD8]))) // too short for JPEG
        XCTAssertNil(JesseAttachment.sniffMime(Data("PK\u{03}\u{04}".utf8))) // zip not allowed
    }

    // MARK: - Caps

    private func attachment(mime: String, bytes: Int) -> JesseAttachment {
        JesseAttachment(filename: "f.\(JesseAttachment.fileExtension(forMime: mime))",
                        mime: mime, data: Data(count: bytes))
    }

    func testRejectionReasonAllowsAWellFormedFile() {
        let ok = attachment(mime: "image/png", bytes: 1024)
        XCTAssertNil(AttachmentLimits.rejectionReason(adding: ok, to: []))
    }

    func testRejectionReasonRejectsUnsupportedType() {
        let bad = JesseAttachment(filename: "a.zip", mime: "application/zip", data: Data(count: 10))
        XCTAssertNotNil(AttachmentLimits.rejectionReason(adding: bad, to: []))
    }

    func testRejectionReasonRejectsOverCount() {
        let existing = (0..<AttachmentLimits.maxCount).map { _ in attachment(mime: "image/png", bytes: 10) }
        let extra = attachment(mime: "image/png", bytes: 10)
        XCTAssertNotNil(AttachmentLimits.rejectionReason(adding: extra, to: existing))
    }

    func testRejectionReasonRejectsOverPerFileSize() {
        let big = attachment(mime: "application/pdf", bytes: AttachmentLimits.maxBytesPerFile + 1)
        let reason = AttachmentLimits.rejectionReason(adding: big, to: [])
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("too large") ?? false)
    }

    func testRejectionReasonRejectsOverTotalSize() {
        // Each file is under the per-file cap, but together they exceed the total.
        let half = AttachmentLimits.maxBytesTotal / 2
        let perFile = min(half + 1, AttachmentLimits.maxBytesPerFile)
        let existing = [attachment(mime: "image/jpeg", bytes: perFile)]
        let next = attachment(mime: "image/jpeg", bytes: perFile)
        // Only meaningful if a single file can't already blow the total.
        if perFile * 2 > AttachmentLimits.maxBytesTotal {
            XCTAssertNotNil(AttachmentLimits.rejectionReason(adding: next, to: existing))
        }
    }
}
