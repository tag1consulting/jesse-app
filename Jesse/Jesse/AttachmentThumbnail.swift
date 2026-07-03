import Foundation
import UIKit
import ImageIO
import PDFKit

// Storage-optimized preview generation for attachments. Turns a picked image or
// PDF (potentially many MB) into a small downscaled JPEG (a few KB) that history
// can persist per turn without unbounded growth. The full-resolution bytes are
// used only to produce the thumbnail and are never returned or retained here.
//
// Pure and stateless so it's unit-testable (assert output format/size and that
// the original bytes aren't echoed back) and safe to run off the main actor.

// `nonisolated` so the whole generator opts out of the module's MainActor-default
// isolation — it's pure CPU/ImageIO/PDFKit work and is called from a detached task.
nonisolated enum AttachmentThumbnail {
    /// Longest-side pixel cap for a stored preview. Small on purpose — the preview
    /// only needs to be recognizable in a history row, not sharp.
    static let maxDimension: CGFloat = 320
    /// JPEG quality for the re-encoded preview. Modest, since it's a thumbnail —
    /// keeps a typical preview in the low-KB range.
    static let jpegQuality: CGFloat = 0.6

    /// A downscaled JPEG preview of `data` (an image or a PDF), or nil if the bytes
    /// can't be rendered. `nonisolated`/pure — ImageIO + PDFKit + CPU only, so it's
    /// safe to call off the main actor. The result is a freshly re-encoded JPEG; the
    /// original bytes are never returned or held beyond this call.
    static func make(data: Data, mime: String) -> Data? {
        if mime == "application/pdf" {
            return pdfThumbnail(data)
        }
        return imageThumbnail(data)
    }

    /// Downsample an image to `maxDimension` on its longest side using ImageIO —
    /// which decodes only the reduced thumbnail, never the full-resolution image —
    /// then JPEG-encode. Handles PNG/JPEG/GIF/WebP/HEIC (the sniffed whitelist) and
    /// respects EXIF orientation.
    private static func imageThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: jpegQuality)
    }

    /// Render the first page of a PDF into an image no larger than `maxDimension`
    /// on its longest side, then JPEG-encode. The first page is enough to
    /// recognize the document in history.
    private static func pdfThumbnail(_ data: Data) -> Data? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        return page.thumbnail(of: size, for: .mediaBox).jpegData(compressionQuality: jpegQuality)
    }
}
