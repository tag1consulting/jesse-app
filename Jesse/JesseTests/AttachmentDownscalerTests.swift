import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Jesse

/// Covers `AttachmentDownscaler` — the pure decision+transform unit that lets an
/// oversized IMAGE attach by re-encoding it under the per-file cap, while leaving
/// every under-cap input byte-verbatim (the PR #51 invariant) and every non-image
/// to the existing caps. Driven by synthetic in-memory images; no asset or UI.
@MainActor
final class AttachmentDownscalerTests: XCTestCase {

    // MARK: - Under-cap inputs are never touched (byte-verbatim invariant)

    func testUnderCapImageReturnsNil() throws {
        // Below the cap → nothing to do; the caller stages the original bytes. The
        // guard runs before any decode, so under-cap images are never re-encoded.
        let jpeg = try XCTUnwrap(Self.solidJPEG(side: 32))
        XCTAssertNil(AttachmentDownscaler.fitToCap(jpeg, cap: jpeg.count + 1))
        XCTAssertNil(AttachmentDownscaler.fitToCap(jpeg, cap: jpeg.count), "== cap is not over the cap")
    }

    func testUnderCapNonImageReturnsNil() {
        // The verbatim guard is type-agnostic: anything at or under the cap is left
        // untouched, PDF included.
        let pdf = Data("%PDF-1.7\nbody".utf8)
        XCTAssertNil(AttachmentDownscaler.fitToCap(pdf, cap: pdf.count + 1))
    }

    // MARK: - Over-cap non-images are left to the existing caps

    func testOverCapPdfNotDownscaled() {
        // Over the (tiny) cap but a PDF — rasterizing is out of scope, so `nil` and
        // the existing size cap rejects it downstream, unchanged.
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(Data(count: 4096))
        XCTAssertNil(AttachmentDownscaler.fitToCap(pdf, cap: 1024))
    }

    func testOverCapUndecodableImageReturnsNil() {
        // Whitelisted PNG magic but not a real decodable image → can't downscale;
        // leave it to the caps rather than crash.
        var bogus = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bogus.append(Data(count: 4096))
        XCTAssertNil(AttachmentDownscaler.fitToCap(bogus, cap: 1024))
    }

    // MARK: - Over-cap image is downscaled to fit, valid, and smaller

    func testOverCapImageDownscaledUnderCap() throws {
        let big = try XCTUnwrap(Self.noisePNG(side: 1024))
        let cap = 300_000
        XCTAssertGreaterThan(big.count, cap, "fixture must exceed the cap to exercise downscaling")

        let fitted = try XCTUnwrap(AttachmentDownscaler.fitToCap(big, cap: cap))
        XCTAssertLessThanOrEqual(fitted.count, cap, "downscaled bytes must fit the cap")
        XCTAssertEqual(JesseAttachment.sniffMime(fitted), "image/jpeg", "output is always JPEG")

        let decoded = try XCTUnwrap(UIImage(data: fitted), "downscaled bytes must decode")
        let longEdge = max(decoded.size.width, decoded.size.height) * decoded.scale
        XCTAssertLessThan(longEdge, 1024,
                          "a noise image this large can't fit at full resolution → it must have stepped down")
    }

    // MARK: - EXIF orientation is applied (baked upright), not dropped

    func testOrientationApplied() throws {
        // An 80×40 landscape raw bitmap tagged orientation 6 displays as a 40×80
        // portrait. A correct downscale renders it upright — so the decoded result
        // is taller than wide. If orientation were ignored, the raw 80×40 landscape
        // would come back instead.
        let oriented = try XCTUnwrap(Self.orientedJPEG(width: 80, height: 40, orientation: 6))
        let fitted = try XCTUnwrap(AttachmentDownscaler.fitToCap(oriented, cap: 64), "cap forces the transform path")
        let decoded = try XCTUnwrap(UIImage(data: fitted))
        XCTAssertGreaterThan(decoded.size.height * decoded.scale,
                             decoded.size.width * decoded.scale,
                             "orientation 6 must render upright (portrait), not the raw landscape")
    }

    // MARK: - Filename becomes .jpg regardless of the input extension

    func testJpegFilenameSwapsExtension() {
        XCTAssertEqual(AttachmentDownscaler.jpegFilename(from: "IMG_1234.HEIC"), "IMG_1234.jpg")
        XCTAssertEqual(AttachmentDownscaler.jpegFilename(from: "pasted-20260704-141530.png"), "pasted-20260704-141530.jpg")
        XCTAssertEqual(AttachmentDownscaler.jpegFilename(from: "no-extension"), "no-extension.jpg")
        XCTAssertEqual(AttachmentDownscaler.jpegFilename(from: ""), "image.jpg")
    }

    // MARK: - Fixtures

    /// A small solid-color JPEG (no asset dependency).
    private static func solidJPEG(side: Int) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    /// A high-entropy noise image, PNG-encoded so it stays large (noise doesn't
    /// compress) — big enough to force the downscale loop to step dimensions down.
    private static func noisePNG(side: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return encode(cg, as: UTType.png)
    }

    /// A solid `width`×`height` raw bitmap written to JPEG with an explicit EXIF
    /// orientation tag, to exercise the orientation-applying decode path.
    private static func orientedJPEG(width: Int, height: Int, orientation: Int) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        return encode(cg, as: UTType.jpeg, properties: [kCGImagePropertyOrientation: orientation])
    }

    private static func encode(_ cg: CGImage, as type: UTType,
                               properties: [CFString: Any]? = nil) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
