import Foundation
import UIKit
import ImageIO

// Fit an oversized IMAGE under the per-file attachment cap by re-encoding it as a
// smaller JPEG, so a >10 MB photo can still attach instead of being rejected with
// "… is too large (max 10 MB per file)".
//
// The byte-verbatim invariant PR #51 restored is preserved BY CONSTRUCTION: the
// very first thing `fitToCap` checks is whether the bytes are already under the
// cap — if so it returns nil and the caller stages the ORIGINAL bytes untouched.
// Nothing under the cap is ever decoded, re-encoded, or inspected. Only a
// decodable image OVER the cap is re-encoded; a PDF or any other non-image is
// left alone (rasterizing PDFs is out of scope) and the existing size cap rejects
// it exactly as before.
//
// Pure/stateless and `nonisolated` (ImageIO + CPU only), so it's safe off the
// main actor and is driven by synthetic images in tests. Mirrors
// `AttachmentThumbnail`'s ImageIO approach, which decodes a reduced image and
// honors EXIF orientation via `kCGImageSourceCreateThumbnailWithTransform`.
nonisolated enum AttachmentDownscaler {
    /// JPEG quality for the re-encode. High enough to stay visually clean, low
    /// enough to make a real dent in byte size.
    static let jpegQuality: CGFloat = 0.85
    /// Aim under the raw cap (not exactly at it) so a boundary result doesn't flap
    /// around the limit.
    static let targetFraction = 0.9
    /// Shrink the longest side to this fraction each iteration when a re-encode at
    /// the current size still doesn't fit.
    static let scaleStep = 0.8
    /// Longest-side floor, in pixels — a termination backstop only. A real over-cap
    /// photo fits at multi-megapixel sizes and never approaches this; the floor
    /// just guarantees the loop can't run forever on a pathological input (we
    /// return the best effort and let the caps reject it if it's somehow still too
    /// big).
    static let minLongEdge = 64

    /// Downscaled JPEG bytes when `data` is a decodable image whose size exceeds
    /// `cap`; otherwise `nil` — meaning "don't touch it, stage/reject the original".
    /// `nil` covers the three cases the caller already handles unchanged:
    ///   * under-cap input   → staged byte-verbatim (the PR #51 invariant),
    ///   * a non-image over the cap (PDF, etc.) → rejected by the existing size cap,
    ///   * undecodable bytes → rejected by the existing caps.
    /// The output is always JPEG regardless of input format (an over-cap HEIC/PNG
    /// becomes a JPEG); use `jpegFilename(from:)` to fix up the display name.
    ///
    /// `cap` is passed in (not defaulted to `AttachmentLimits.maxBytesPerFile`)
    /// because this unit is `nonisolated` and that constant is MainActor-isolated —
    /// a default argument would evaluate in a nonisolated context and not compile.
    /// The production caller (`addAttachment`, on the main actor) supplies the cap.
    static func fitToCap(_ data: Data, cap: Int) -> Data? {
        guard data.count > cap else { return nil }                                    // under cap → verbatim, never decoded
        guard let mime = JesseAttachment.sniffMime(data), mime.hasPrefix("image/") else { return nil } // non-image → leave to caps
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let longEdge = pixelLongEdge(source) else { return nil }                 // undecodable → leave to caps

        let target = Int(Double(cap) * targetFraction)
        var maxPixel = longEdge                     // first pass: full resolution, re-encode only (never upscales)
        while true {
            guard let jpeg = encode(source, maxPixel: maxPixel) else { return nil }
            if jpeg.count <= target || maxPixel <= minLongEdge { return jpeg }
            maxPixel = max(Int(Double(maxPixel) * scaleStep), minLongEdge)
        }
    }

    /// The display name for a downscaled attachment: the original base name with a
    /// `.jpg` extension, since the output is always JPEG regardless of input format.
    static func jpegFilename(from name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "image.jpg" : "\(base).jpg"
    }

    /// Longest side of the source image in pixels. Orientation doesn't change the
    /// max of the two axes, so the raw pixel dimensions are fine here. `nil` if the
    /// dimensions can't be read.
    private static func pixelLongEdge(_ source: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return max(width, height)
    }

    /// Re-encode `source` as a JPEG whose longest side is at most `maxPixel`,
    /// applying EXIF orientation so the result is upright. ImageIO decodes only the
    /// reduced image. `maxPixel` never exceeds the source's own size, so this never
    /// upscales.
    private static func encode(_ source: CGImageSource, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: jpegQuality)
    }
}
