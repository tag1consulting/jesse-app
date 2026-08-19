import XCTest
import UniformTypeIdentifiers
import JesseCore
@testable import JesseNetworking

/// The TYPE IDENTITY of a returned file: the extension its cached copy carries, the
/// QuickLook item that names it, the inline-image rule, and the SVG parse check that keeps
/// a broken drawing out of the transcript.
///
/// The bug all of this closes: the cache named every file with the bare hex id, QuickLook
/// types a file from its extension and had none to read, and so every artifact that was
/// not a PNG or JPEG opened to a blank preview.
final class ArtifactFileTypeTests: XCTestCase {

    /// Every mime the bridge's `sniff_artifact` can return, mapped to the extension the
    /// bridge itself writes. These two tables are one contract in two languages; if this
    /// test and `bridge/src/artifacts.rs` ever disagree, the device is the one that is
    /// wrong.
    func testEveryAcceptedMimeMapsToTheBridgesExtension() {
        let expected = [
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
        for (mime, ext) in expected {
            XCTAssertEqual(ArtifactFileType.fileExtension(for: mime), ext, mime)
        }
        // NOT `jpeg`, which is what `UTType(mimeType:).preferredFilenameExtension` would
        // have given us. The bridge writes `jpg`, and the two halves of one system must
        // agree about a file's name.
        XCTAssertEqual(ArtifactFileType.fileExtension(for: "image/jpeg"), "jpg")
        // A mime is case-insensitive by RFC 2045.
        XCTAssertEqual(ArtifactFileType.fileExtension(for: "IMAGE/PNG"), "png")
    }

    /// An unrecognized or absent mime gets NO extension — never one guessed from anywhere
    /// else. This is the fallback that keeps the rule "the extension comes from the
    /// mapping and from nowhere else" true even for a bridge newer than this app.
    func testUnknownOrAbsentMimeMapsToNoExtension() {
        XCTAssertNil(ArtifactFileType.fileExtension(for: ""))
        XCTAssertNil(ArtifactFileType.fileExtension(for: "application/zip"))
        XCTAssertNil(ArtifactFileType.fileExtension(for: "image/webp"))
        XCTAssertNil(ArtifactFileType.fileExtension(for: "text/csv; charset=utf-8"),
                     "the bridge emits bare literals; tolerating a parameter would invent "
                     + "a wire shape the producer cannot produce")
    }

    /// SVG joins the two raster types. It used to be excluded as "markup and a rendering
    /// surface"; each platform now draws it inside a sandbox instead.
    func testInlineImageCoversTheThreeImageTypesAndNothingElse() {
        for mime in ["image/png", "image/jpeg", "image/svg+xml"] {
            XCTAssertTrue(ArtifactFileType.isInlineImage(mime), mime)
        }
        for mime in ["application/pdf", "text/html", "text/csv",
                     "application/json", "text/markdown", "text/plain"] {
            XCTAssertFalse(ArtifactFileType.isInlineImage(mime), mime)
        }
    }

    // MARK: - The QuickLook item

    /// Every accepted mime resolves to a system type, and the item carries the file's
    /// DISPLAY name rather than the hex id the URL is named with.
    ///
    /// Note what is NOT asserted: that QuickLook reads this type. It does not — there is
    /// no `previewItemContentType` in `QLPreviewItem` on either platform (see
    /// `ArtifactPreviewItem`). The extension is the mechanism; this `UTType` is what the
    /// export paths take.
    func testPreviewItemCarriesATypeAndATitleForEveryAcceptedMime() {
        let mimes = ["image/png", "image/jpeg", "image/svg+xml", "application/pdf",
                     "text/html", "text/csv", "application/json", "text/markdown",
                     "text/plain"]
        for mime in mimes {
            let url = URL(fileURLWithPath: "/tmp/aa11")
            let item = ArtifactPreviewItem(url: url, filename: "chart.png", mime: mime)
            XCTAssertNotNil(item.contentType, mime)
            XCTAssertEqual(item.previewItemURL, url)
            XCTAssertEqual(item.previewItemTitle, "chart.png")
        }
        XCTAssertEqual(ArtifactFileType.contentType(for: "image/svg+xml"), UTType.svg)
        XCTAssertEqual(ArtifactFileType.contentType(for: "text/csv"), UTType.commaSeparatedText)
        // Every accepted mime resolves to a DECLARED type, not to the `dyn.…` placeholder
        // UniformTypeIdentifiers synthesizes for a mime the system has never heard of.
        // That distinction is the one worth asserting: a dynamic type would satisfy
        // "non-nil" and tell the Save As panel nothing.
        for mime in mimes {
            XCTAssertEqual(ArtifactFileType.contentType(for: mime)?.isDynamic, false, mime)
        }
        XCTAssertEqual(ArtifactFileType.contentType(for: "application/x-not-a-type")?.isDynamic,
                       true, "an unregistered mime gets a placeholder, and it is legible as one")
    }

    // MARK: - SVG, before it reaches a renderer

    /// The parse check that gives the chip fallback its condition. A web view handed
    /// malformed markup renders an empty box rather than failing, so the markup is parsed
    /// here first and anything that is not well-formed XML rooted at `<svg>` never reaches
    /// a renderer.
    func testSVGSizeParsesGoodMarkupAndRejectsEverythingElse() {
        let viewBox = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 60"><rect width="10" height="10"/></svg>
        """.utf8)
        XCTAssertEqual(ArtifactFileType.svgIntrinsicSize(viewBox), CGSize(width: 120, height: 60))

        // `viewBox` wins over width/height: it is the one always in user units.
        let both = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="999" height="999" viewBox="0 0 40 20"/>
        """.utf8)
        XCTAssertEqual(ArtifactFileType.svgIntrinsicSize(both), CGSize(width: 40, height: 20))

        // Absolute width/height when there is no viewBox, units and all.
        let sized = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="200px" height="100px"/>"#.utf8)
        XCTAssertEqual(ArtifactFileType.svgIntrinsicSize(sized), CGSize(width: 200, height: 100))

        // A percentage sizes against a container this document does not have, so it is not
        // a size. Well-formed all the same, so it renders — the caller bounds it.
        let relative = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"/>"#.utf8)
        XCTAssertEqual(ArtifactFileType.svgIntrinsicSize(relative), CGSize(width: 1, height: 1))

        // An XML declaration and a leading comment are ordinary, valid SVG.
        let declared = Data("""
        <?xml version="1.0" encoding="UTF-8"?><!-- drawn by jesse -->
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4"/>
        """.utf8)
        XCTAssertEqual(ArtifactFileType.svgIntrinsicSize(declared), CGSize(width: 8, height: 4))

        // And the rejections, each of which must reach the chip rather than an empty box.
        XCTAssertNil(ArtifactFileType.svgIntrinsicSize(Data("<svg broken".utf8)))
        XCTAssertNil(ArtifactFileType.svgIntrinsicSize(Data()))
        XCTAssertNil(ArtifactFileType.svgIntrinsicSize(Data("not markup at all".utf8)))
        XCTAssertNil(ArtifactFileType.svgIntrinsicSize(Data("<html><body/></html>".utf8)),
                     "well-formed XML that is not an SVG is not an SVG")
        XCTAssertNil(ArtifactFileType.svgIntrinsicSize(Data([0xFF, 0xD8, 0xFF, 0x00])))
    }

    // MARK: - Bounded frames

    /// An ordinary picture is scaled to fit, and both bounds are respected.
    func testInlineFrameFitsOrdinaryPictures() {
        let wide = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 800, height: 400),
                                                maxWidth: 300, maxHeight: 240)
        XCTAssertEqual(wide, InlineImageFrame(width: 300, height: 150, crops: false))

        let tall = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 400, height: 800),
                                                maxWidth: 300, maxHeight: 240)
        XCTAssertEqual(tall, InlineImageFrame(width: 120, height: 240, crops: false))

        // Smaller than the bounds: scaled UP to fill one of them, never left tiny.
        let small = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 30, height: 15),
                                                 maxWidth: 300, maxHeight: 240)
        XCTAssertEqual(small, InlineImageFrame(width: 300, height: 150, crops: false))
    }

    /// THE SLIVER CASE. A 60 × 4000 drawing fitted into a 240-point box is four points
    /// wide: the correct aspect ratio and completely useless. It gets a frame the user can
    /// see and hit, and fills it instead.
    func testInlineFrameRefusesToProduceASliver() {
        let sliver = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 60, height: 4000),
                                                  maxWidth: 300, maxHeight: 240)
        XCTAssertTrue(sliver.crops)
        XCTAssertEqual(sliver.width, ArtifactFileType.minimumInlineSide)
        XCTAssertEqual(sliver.height, 240)

        let ribbon = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 4000, height: 20),
                                                  maxWidth: 300, maxHeight: 240)
        XCTAssertTrue(ribbon.crops)
        XCTAssertEqual(ribbon.width, 300)
        XCTAssertEqual(ribbon.height, ArtifactFileType.minimumInlineSide)

        // A degenerate intrinsic size (a corrupt header, a self-sizing drawing) falls back
        // to the bounding box rather than to zero.
        let unknown = ArtifactFileType.inlineFrame(intrinsic: .zero,
                                                   maxWidth: 300, maxHeight: 240)
        XCTAssertEqual(unknown, InlineImageFrame(width: 300, height: 240, crops: true))
    }

    /// The minimum can never exceed the bound it sits inside — a narrow bubble gets a
    /// narrow picture, not one that overflows it.
    func testInlineFrameNeverExceedsItsBounds() {
        let cramped = ArtifactFileType.inlineFrame(intrinsic: CGSize(width: 10, height: 4000),
                                                   maxWidth: 20, maxHeight: 240)
        XCTAssertLessThanOrEqual(cramped.width, 20)
        XCTAssertLessThanOrEqual(cramped.height, 240)
    }
}
