import UIKit
import UniformTypeIdentifiers

// The pure core of "paste a copied photo or PDF into the composer".
//
// The composer's text view offers the native Paste edit-menu item, and when the
// clipboard holds an image or a PDF we stage it as an attachment (the same chip +
// send flow the paperclip menu uses) instead of dropping raw bytes into the text.
// The clipboard I/O lives in the view; these are the side-effect-free decisions,
// so they're unit-tested without touching the global `UIPasteboard`.
enum ComposerPaste {
    /// Type identifiers tried, in order, when reading a pasted item provider's
    /// ORIGINAL bytes. The loop is keyed on `hasItemConformingToTypeIdentifier`, so
    /// a JPEG/HEIC photo (which does not conform to `public.png`) loads its own
    /// compact bytes verbatim and is never re-encoded to a much larger PNG — the
    /// regression that made pasted photos trip the per-file size cap. A bare bitmap
    /// with no concrete encoding falls back to a re-encoded `UIImage` in the view.
    static let mediaTypes: [UTType] = [.pdf, .png, .jpeg, .heic, .heif, .gif, .webP, .tiff, .bmp]

    /// Whether the composer should treat a paste as *media* (stage an attachment)
    /// rather than let the text view paste text. True when the clipboard carries an
    /// image or a PDF; a text-only clipboard pastes as text as usual.
    static func isMediaPaste(hasImages: Bool, hasPDF: Bool) -> Bool {
        hasImages || hasPDF
    }
}
