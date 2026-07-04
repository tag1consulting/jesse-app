import UIKit

/// Turning a pasted/clipboard payload into stageable attachment bytes.
///
/// The `NSItemProvider` loading itself is I/O and lives in the view; these are the
/// pure, testable core:
///
/// * A copied PNG / JPEG / GIF / WebP / HEIC / PDF that already carries whitelisted
///   magic bytes is kept **verbatim** (lossless — the original bytes are what we
///   stage).
/// * A bitmap with no lossless original (e.g. a copied screenshot the pasteboard
///   only offers as TIFF/BMP) is re-encoded to PNG, because `JesseAttachment.sniffMime`
///   keys off magic bytes — whatever we hand it must actually be a whitelisted type.
/// * Anything that is neither a whitelisted type nor a decodable bitmap → `nil`,
///   which the caller surfaces through the existing `attachError` UI.
///
/// The staged bytes then flow through the SAME `addAttachment(...)` path the pickers
/// use, so they inherit `sniffMime`, `AttachmentLimits`, the chip UI, and send.
enum PasteAttachment {
    /// A generated, sortable filename for a pasted item, e.g.
    /// `pasted-20260704-141530.png`. POSIX locale + fixed format so it's stable
    /// and testable (no hidden clock read).
    static func filename(ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pasted-\(formatter.string(from: date)).\(ext)"
    }

    /// Stageable bytes for a raw pasted payload, or `nil` if it can't be
    /// represented as a whitelisted type. Whitelisted input is returned verbatim;
    /// a decodable bitmap with a non-whitelisted encoding is re-encoded to PNG.
    static func stageableBytes(from data: Data) -> Data? {
        if JesseAttachment.sniffMime(data) != nil { return data }
        if let image = UIImage(data: data) { return pngData(from: image) }
        return nil
    }

    /// Re-encode a decoded image (e.g. a bitmap pasted with no lossless original)
    /// to PNG bytes, so its magic bytes sniff as a whitelisted `image/png`.
    static func pngData(from image: UIImage) -> Data? { image.pngData() }
}
