import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Jesse

/// Covers `PasteAttachment` — the pure paste→bytes core behind the composer's
/// native paste (long-press → Paste of a copied image/PDF). The `UIPasteboard`
/// reading itself needs the pasteboard/UI and isn't unit-testable; these pin the
/// byte handling that decides what gets staged, and that a pasted item runs the
/// SAME `sniffMime`/`AttachmentLimits` caps as the pickers.
@MainActor
final class PasteAttachmentTests: XCTestCase {

    // MARK: - Generated filename

    func testFilenameShapeAndDeterminism() {
        let date = Date(timeIntervalSince1970: 1_751_552_130)
        let name = PasteAttachment.filename(ext: "png", date: date)
        XCTAssertTrue(name.hasPrefix("pasted-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        // Same input → same output (no hidden clock read).
        XCTAssertEqual(name, PasteAttachment.filename(ext: "png", date: date))
        XCTAssertNotNil(name.range(of: #"^pasted-\d{8}-\d{6}\.png$"#, options: .regularExpression),
                        "unexpected filename shape: \(name)")
    }

    // MARK: - Lossless passthrough

    func testWhitelistedBytesKeptVerbatim() {
        // A copied PDF / PNG already carries whitelisted magic bytes — stage the
        // original bytes, don't re-encode.
        let pdf = Data("%PDF-1.7\nbody".utf8)
        XCTAssertEqual(PasteAttachment.stageableBytes(from: pdf), pdf)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        XCTAssertEqual(PasteAttachment.stageableBytes(from: png), png)
    }

    // MARK: - Re-encode a bitmap with no lossless original

    func testNonWhitelistedBitmapReencodedToPNG() throws {
        // TIFF decodes as a bitmap but isn't a whitelisted sniff type — so it must
        // be re-encoded to PNG, whose magic bytes the caps recognize.
        let tiff = try XCTUnwrap(Self.tiffBytes())
        XCTAssertNil(JesseAttachment.sniffMime(tiff), "TIFF should not sniff as a whitelisted type")
        XCTAssertNotNil(UIImage(data: tiff), "TIFF should decode as a bitmap")

        let staged = try XCTUnwrap(PasteAttachment.stageableBytes(from: tiff))
        XCTAssertEqual(JesseAttachment.sniffMime(staged), "image/png")
    }

    func testPngDataReencodeSniffsAsPng() throws {
        let png = try XCTUnwrap(PasteAttachment.pngData(from: Self.solidImage()))
        XCTAssertEqual(JesseAttachment.sniffMime(png), "image/png")
    }

    // MARK: - Rejection (via the existing caps, exactly like the pickers)

    func testNonWhitelistedNonImagePasteIsRejectedBeforeStaging() {
        // Neither a whitelisted type nor a decodable bitmap → nil, surfaced by the
        // caller's attachError; never crash, never silently stage.
        XCTAssertNil(PasteAttachment.stageableBytes(from: Data("plain text, not an image".utf8)))
        XCTAssertNil(PasteAttachment.stageableBytes(from: Data("PK\u{03}\u{04}zip-not-allowed".utf8)))
    }

    func testOversizedPastedImageIsRejectedByCaps() throws {
        // A whitelisted-but-oversized paste is kept by stageableBytes, then caught
        // by the SAME per-file cap the pickers enforce.
        var big = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
        big.append(Data(count: AttachmentLimits.maxBytesPerFile + 1))
        let staged = try XCTUnwrap(PasteAttachment.stageableBytes(from: big))
        let mime = try XCTUnwrap(JesseAttachment.sniffMime(staged))
        let att = JesseAttachment(
            filename: PasteAttachment.filename(ext: JesseAttachment.fileExtension(forMime: mime)),
            mime: mime, data: staged)
        let reason = AttachmentLimits.rejectionReason(adding: att, to: [])
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("too large") ?? false)
    }

    func testPastedItemBeyondCountCapIsRejected() {
        // The 5th pasted item hits the same count cap the pickers do.
        let staged = PasteAttachment.stageableBytes(from: Data("%PDF-1.7\n".utf8))!
        let att = JesseAttachment(filename: "pasted.pdf", mime: "application/pdf", data: staged)
        let full = (0..<AttachmentLimits.maxCount).map { _ in
            JesseAttachment(filename: "f.pdf", mime: "application/pdf", data: staged)
        }
        XCTAssertNotNil(AttachmentLimits.rejectionReason(adding: att, to: full))
    }

    // MARK: - Fixtures

    /// A tiny solid-color image rendered in-memory (no asset dependency).
    private static func solidImage(side: Int = 4) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// TIFF-encoded bytes of a tiny image — a decodable bitmap that is deliberately
    /// NOT one of the whitelisted sniff types, to exercise the re-encode branch.
    private static func tiffBytes(side: Int = 4) -> Data? {
        guard let cg = solidImage(side: side).cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
