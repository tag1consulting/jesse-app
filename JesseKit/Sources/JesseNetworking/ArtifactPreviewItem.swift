import Foundation
import JesseCore
import UniformTypeIdentifiers
#if os(macOS)
import QuickLookUI
#else
import QuickLook
#endif

// ---- Telling QuickLook what it is holding ----------------------------------

/// One returned file, as QuickLook wants to receive it.
///
/// Both apps used to hand QuickLook a bare `URL` through SwiftUI's `.quickLookPreview`,
/// which is why the preview had two problems rather than one: it could not name the file
/// (the id is hex, so the previewer's title bar read `4f2a91c0…`), and with no extension
/// on that URL it could not type it either. This carries both facts explicitly.
///
/// # On `previewItemContentType`
///
/// There is no such property to set. `QLPreviewItem` declares exactly `previewItemURL`
/// (required), `previewItemTitle` and `previewItemDisplayState` (optional) — on iOS and on
/// macOS alike; the `contentType` in QuickLook belongs to `QLPreviewReply`, which is the
/// PROVIDER side, for an extension generating previews of its own format. A consumer
/// cannot hand QuickLook a type. The file's extension is the whole mechanism, which is
/// what makes `ArtifactFileType` above the actual fix rather than a belt to its braces.
/// The resolved `UTType` is still carried here, because the platform does accept one
/// everywhere else it matters — the Mac's Save As panel is the caller that uses it.
public final class ArtifactPreviewItem: NSObject, QLPreviewItem, Identifiable {
    private let url: URL
    private let title: String

    /// The system type for this file's mime. Not read by QuickLook (see above); used by
    /// the export paths, which do take one.
    public let contentType: UTType?

    /// - Parameter filename: the model's own filename. Safe HERE and nowhere else: a
    ///   title is drawn, never resolved, so `../../etc/passwd` is a silly caption rather
    ///   than a path. The URL it is shown beside is still named from the hex id.
    public init(url: URL, filename: String, mime: String) {
        self.url = url
        self.title = filename
        self.contentType = ArtifactFileType.contentType(for: mime)
        super.init()
    }

    public var previewItemURL: URL? { url }
    public var previewItemTitle: String? { title }

    /// `Identifiable` so a SwiftUI `.sheet(item:)` can be driven by "which file is being
    /// previewed" directly. The URL is the identity: one cached file, one preview.
    public var id: URL { url }
}
