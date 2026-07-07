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
    /// Pasteboard type identifiers we try to read as attachment bytes, best first:
    /// PDF (kept as a document), then the lossless/whitelisted image encodings.
    /// `.image` is deliberately absent — a concrete encoding is tried first, and a
    /// bare bitmap falls back to a re-encoded `UIImage` in the view.
    static let mediaTypes: [UTType] = [.pdf, .png, .jpeg, .heic, .heif, .gif, .webP, .tiff, .bmp]

    /// Whether the composer should treat a paste as *media* (stage an attachment)
    /// rather than let the text view paste text. True when the clipboard carries an
    /// image or a PDF; a text-only clipboard pastes as text as usual.
    static func isMediaPaste(hasImages: Bool, hasPDF: Bool) -> Bool {
        hasImages || hasPDF
    }

    /// Stageable attachment bytes for one `UIPasteboard` item (a `[typeId: value]`
    /// dictionary), or `nil` if it carries no readable image/PDF. Whitelisted bytes
    /// are returned verbatim; a decodable bitmap with a non-whitelisted encoding is
    /// re-encoded to PNG. Mirrors the paperclip path's `PasteAttachment` rules.
    static func stageableData(from item: [String: Any]) -> Data? {
        for type in mediaTypes {
            if let data = item[type.identifier] as? Data,
               let staged = PasteAttachment.stageableBytes(from: data) {
                return staged
            }
            if let image = item[type.identifier] as? UIImage,
               let png = PasteAttachment.pngData(from: image) {
                return png
            }
        }
        return nil
    }
}
