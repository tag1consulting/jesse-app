import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// The TYPE IDENTITY of a file Jesse returned, on the device side.
//
// # The bug this exists to close
//
// The bridge sniffs a mime from the bytes and stores its own copy as `<id>.<ext>`. The
// device threw that extension away: `ArtifactCache` named every cached file with the bare
// hex id. QuickLook has no other way to decide what it is holding — it resolves a
// previewer from the file's UTI, a UTI comes from the extension, and an extensionless
// file has none. So a PDF, an HTML page, a CSV and an SVG all opened to a blank preview,
// while PNG and JPEG survived only because they never went through QuickLook at all (they
// were decoded by `UIImage`/`NSImage`, which sniff bytes themselves).
//
// # Why a fixed table and not `UTType.preferredFilenameExtension`
//
// It would be one line to ask UniformTypeIdentifiers for the extension. It would also be
// WRONG here: `UTType(mimeType: "image/jpeg")?.preferredFilenameExtension` is `jpeg`,
// while the bridge writes `jpg`. The two halves of one system disagreeing about a file's
// name is exactly the class of bug this file is closing, so the mapping is fixed, written
// down once, and mirrors `sniff_artifact` in `bridge/src/artifacts.rs` entry for entry.
//
// # What the extension is NEVER derived from
//
// Not `filename`. The model chose that string, and every layer beneath it — the bridge's
// store, the cache, the temp fallback — deliberately keeps it out of every path. An
// unrecognized or absent mime therefore falls back to NO extension, never to whatever the
// model happened to name its file.
public nonisolated enum ArtifactFileType {
    /// The mime → on-disk extension mapping, and the whole of it. Mirrors the bridge's
    /// `sniff_artifact` return values: the channel accepts exactly these nine types, and
    /// the sniffer is fail-closed, so anything absent from this table is something the
    /// bridge would not have carried in the first place.
    private static let extensionsByMIME: [String: String] = [
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/svg+xml": "svg",
        "application/pdf": "pdf",
        "text/html": "html",
        "text/csv": "csv",
        "application/json": "json",
        "text/markdown": "md",
        "text/plain": "txt",
    ]

    /// The extension a cached copy of this mime should carry, or `nil` for a mime this
    /// build does not know. `nil` means "write the bare id", which is the pre-existing
    /// behavior — a file we cannot name confidently is not a file we should guess at.
    ///
    /// Lowercased on the way in because a mime is case-insensitive by RFC 2045. Nothing
    /// more is normalized: the bridge emits one of nine string literals, never a
    /// parameterized `text/csv; charset=utf-8`, so tolerating one would be inventing a
    /// wire shape the producer cannot produce.
    public static func fileExtension(for mime: String) -> String? {
        extensionsByMIME[mime.lowercased()]
    }

    /// The system type for a mime, used where a `UTType` is genuinely load-bearing: the
    /// Mac's Save As panel, and asserting in tests that every accepted mime resolves.
    public static func contentType(for mime: String) -> UTType? {
        UTType(mimeType: mime)
    }

    /// Whether this mime is drawn INLINE in the transcript as a picture.
    ///
    /// SVG used to be excluded here, on the reasoning that it is markup and a rendering
    /// surface and so belonged behind the same explicit tap a PDF is behind. That
    /// reasoning describes a threat the sandbox already answers and cost the user the
    /// thing SVG is for. What the bridge accepts as `image/svg+xml` has already been
    /// proven to be UTF-8 text with no control characters and no `#!`, and each platform
    /// renders it with scripting off and no network reachable — macOS through `NSImage`'s
    /// vector representation, iOS through a `WKWebView` with JavaScript disabled and a
    /// `default-src 'none'` policy. A chart the model drew as vector is a picture, and it
    /// now reads as one.
    public static func isInlineImage(_ mime: String) -> Bool {
        mime == "image/png" || mime == "image/jpeg" || mime == "image/svg+xml"
    }
}

// ---- SVG, before it reaches a renderer -------------------------------------

nonisolated extension ArtifactFileType {
    /// The intrinsic size of an SVG, or `nil` if these bytes are not a usable SVG.
    ///
    /// Doubles as the PARSE CHECK. iOS draws SVG in a web view, and a web view handed
    /// malformed markup renders an empty box rather than failing — a silent blank the user
    /// cannot tell from a bug. So the markup is parsed here first, with Foundation's
    /// `XMLParser`, and anything that is not well-formed XML rooted at `<svg>` fails
    /// before a renderer ever sees it, which is what lets the view fall back to the chip.
    ///
    /// External entities stay unresolved (the parser's default). That is a security
    /// property as much as a correctness one: a resolved external entity is a network
    /// fetch, and this channel's whole contract is that a returned file reaches no
    /// network.
    ///
    /// The size comes from `viewBox` first and `width`/`height` second, because `viewBox`
    /// is the one that is always in user units — `width="100%"` is meaningless without a
    /// containing box.
    public static func svgIntrinsicSize(_ data: Data) -> CGSize? {
        let root = SVGRootReader()
        let parser = XMLParser(data: data)
        parser.delegate = root
        parser.shouldResolveExternalEntities = false
        parser.parse()
        // `parse()` returning false is expected on a well-formed document: the delegate
        // aborts the moment it has the root element, and an abort reads as a failure. The
        // root element name is the real verdict.
        guard root.rootElement == "svg" else { return nil }

        if let box = root.viewBox {
            let parts = box.split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            if parts.count == 4, parts[2] > 0, parts[3] > 0 {
                return CGSize(width: parts[2], height: parts[3])
            }
        }
        if let w = lengthInUserUnits(root.width), let h = lengthInUserUnits(root.height),
           w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        // Well-formed SVG with no usable dimensions — a legitimate document that sizes
        // itself to its container. Square is the honest default, and the caller bounds it.
        return CGSize(width: 1, height: 1)
    }

    /// A raw SVG length as a number, accepting the absolute units that mean a fixed size
    /// and rejecting `%`, which is a fraction of a box this document does not have.
    private static func lengthInUserUnits(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasSuffix("%") { return nil }
        let digits = raw.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return Double(digits)
    }

    /// Reads the root element's name and sizing attributes, then stops the parse. It only
    /// ever needs the first element, and running the parser over a 5 MB drawing to learn
    /// something contained in its first 200 bytes would be pure waste.
    private final class SVGRootReader: NSObject, XMLParserDelegate {
        var rootElement: String?
        var viewBox: String?
        var width: String?
        var height: String?

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            guard rootElement == nil else { return }
            rootElement = name.lowercased()
            viewBox = attributes["viewBox"] ?? attributes["viewbox"]
            width = attributes["width"]
            height = attributes["height"]
            parser.abortParsing()
        }
    }
}

// ---- How big an inline image is allowed to be ------------------------------

/// The frame an inline image occupies, and how it fills it.
public nonisolated struct InlineImageFrame: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    /// Whether the image must FILL this frame and be clipped, rather than being
    /// letterboxed into it. True only for the extreme aspect ratios described on
    /// `ArtifactFileType.inlineFrame(intrinsic:maxWidth:maxHeight:)`.
    public let crops: Bool

    public init(width: CGFloat, height: CGFloat, crops: Bool) {
        self.width = width
        self.height = height
        self.crops = crops
    }
}

nonisolated extension ArtifactFileType {
    /// The smallest side an inline image is allowed to render at: the HIG's minimum tap
    /// target. Below this the picture is not a picture, it is a line the user cannot hit.
    public static let minimumInlineSide: CGFloat = 44

    /// The bounded frame an inline image gets.
    ///
    /// Scaling to fit inside the bounds is right for every ordinary picture and wrong at
    /// the extremes. A 60 × 4000 image fitted into a 240-point-tall box is four points
    /// wide: technically the correct aspect ratio, and useless — a sliver the user cannot
    /// see or tap. So when fitting would take either side below `minimumInlineSide`, the
    /// frame is widened (or heightened) to that minimum and the image FILLS it instead,
    /// showing the leading part of a picture whose whole point is that it does not fit.
    /// The full-resolution file is one tap away either way.
    public static func inlineFrame(intrinsic: CGSize,
                                   maxWidth: CGFloat,
                                   maxHeight: CGFloat) -> InlineImageFrame {
        guard intrinsic.width > 0, intrinsic.height > 0, maxWidth > 0, maxHeight > 0 else {
            // No usable intrinsic size (a corrupt header, a self-sizing SVG). The bounding
            // box itself is the only honest answer.
            return InlineImageFrame(width: maxWidth, height: maxHeight, crops: true)
        }
        let scale = min(maxWidth / intrinsic.width, maxHeight / intrinsic.height)
        var width = intrinsic.width * scale
        var height = intrinsic.height * scale
        var crops = false
        if width < minimumInlineSide {
            width = min(minimumInlineSide, maxWidth)
            crops = true
        }
        if height < minimumInlineSide {
            height = min(minimumInlineSide, maxHeight)
            crops = true
        }
        return InlineImageFrame(width: width, height: height, crops: crops)
    }
}
