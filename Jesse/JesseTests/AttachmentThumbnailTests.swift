import XCTest
import UIKit
import PDFKit
@testable import Jesse

/// Covers `AttachmentThumbnail` — the storage-optimized preview generator. Asserts
/// the output is a downscaled JPEG (not the original bytes), capped at the max
/// dimension, for both images and PDFs, and nil for junk.
final class AttachmentThumbnailTests: XCTestCase {

    // MARK: - Helpers

    /// A solid PNG of the given pixel size (two quadrants so it isn't uniform).
    @MainActor
    private func makePNG(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 1 point == 1 pixel, so size is in pixels
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        return image.pngData()!
    }

    /// A one-page PDF at US-Letter size with some drawn text.
    private func makePDF() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            UIColor.white.setFill()
            ctx.fill(bounds)
            ("Hello PDF" as NSString).draw(
                at: CGPoint(x: 50, y: 50),
                withAttributes: [.font: UIFont.systemFont(ofSize: 48)])
        }
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    private func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// Pixel dimensions of an encoded image.
    private func pixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        return (cg.width, cg.height)
    }

    // MARK: - Images

    @MainActor
    func testImageThumbnailIsJPEGCappedToMaxDimension() {
        let input = makePNG(width: 1000, height: 600)
        guard let out = AttachmentThumbnail.make(data: input, mime: "image/png") else {
            return XCTFail("expected a thumbnail")
        }
        XCTAssertTrue(isJPEG(out), "thumbnail must be re-encoded as JPEG")
        guard let (w, h) = pixelSize(out) else { return XCTFail("undecodable thumbnail") }
        let maxSide = max(w, h)
        XCTAssertLessThanOrEqual(CGFloat(maxSide), AttachmentThumbnail.maxDimension)
        XCTAssertGreaterThan(maxSide, 0)
        // Landscape source → width is the longest side and hits the cap.
        XCTAssertGreaterThan(w, h)
    }

    @MainActor
    func testImageThumbnailPortraitCapsHeight() {
        let input = makePNG(width: 400, height: 1000)
        guard let out = AttachmentThumbnail.make(data: input, mime: "image/png"),
              let (w, h) = pixelSize(out) else {
            return XCTFail("expected a decodable thumbnail")
        }
        XCTAssertLessThanOrEqual(CGFloat(max(w, h)), AttachmentThumbnail.maxDimension)
        XCTAssertGreaterThan(h, w, "portrait source → height is the longest side")
    }

    @MainActor
    func testThumbnailIsAFreshJPEGNotTheOriginalBytes() {
        // Original is a large PNG; the thumbnail must be a distinct, smaller JPEG —
        // i.e. the original bytes are never echoed back or retained.
        let input = makePNG(width: 1200, height: 1200)
        XCTAssertTrue(isPNG(input))
        guard let out = AttachmentThumbnail.make(data: input, mime: "image/png") else {
            return XCTFail("expected a thumbnail")
        }
        XCTAssertFalse(isPNG(out), "must not be the original PNG bytes")
        XCTAssertTrue(isJPEG(out))
        XCTAssertNotEqual(out, input)
        XCTAssertLessThan(out.count, input.count, "a 320px thumbnail must be smaller than a 1200px original")
    }

    // MARK: - PDFs

    func testPDFThumbnailRendersFirstPageAsCappedJPEG() {
        let input = makePDF()
        guard let out = AttachmentThumbnail.make(data: input, mime: "application/pdf") else {
            return XCTFail("expected a PDF thumbnail")
        }
        XCTAssertTrue(isJPEG(out))
        guard let (w, h) = pixelSize(out) else { return XCTFail("undecodable thumbnail") }
        XCTAssertLessThanOrEqual(CGFloat(max(w, h)), AttachmentThumbnail.maxDimension)
        // US-Letter is portrait, so height is the longest side.
        XCTAssertGreaterThan(h, w)
    }

    // MARK: - Failure cases

    func testGarbageBytesYieldNil() {
        XCTAssertNil(AttachmentThumbnail.make(data: Data("not an image".utf8), mime: "image/png"))
        XCTAssertNil(AttachmentThumbnail.make(data: Data("not a pdf".utf8), mime: "application/pdf"))
        XCTAssertNil(AttachmentThumbnail.make(data: Data(), mime: "image/jpeg"))
    }
}
