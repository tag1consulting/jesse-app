import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Jesse

/// Covers `ComposerPaste` — the pure decisions behind "long-press → Paste a
/// copied photo/PDF into the composer". The `UIPasteboard` reading lives in the
/// text view; these pin which pastes count as media and how one pasteboard item
/// becomes stageable bytes (reusing the same `PasteAttachment` rules as the
/// paperclip path).
final class ComposerPasteTests: XCTestCase {

    // MARK: - isMediaPaste

    func testTextOnlyClipboardIsNotMediaPaste() {
        XCTAssertFalse(ComposerPaste.isMediaPaste(hasImages: false, hasPDF: false))
    }

    func testImageClipboardIsMediaPaste() {
        XCTAssertTrue(ComposerPaste.isMediaPaste(hasImages: true, hasPDF: false))
    }

    func testPDFClipboardIsMediaPaste() {
        XCTAssertTrue(ComposerPaste.isMediaPaste(hasImages: false, hasPDF: true))
    }

    // MARK: - mediaTypes

    func testMediaTypesPreferPDFAndExcludeAbstractImage() {
        XCTAssertEqual(ComposerPaste.mediaTypes.first, .pdf, "a PDF should be preferred over its rasterization")
        XCTAssertFalse(ComposerPaste.mediaTypes.contains(.image),
                       "the abstract .image type is handled by the UIImage fallback, not the data loop")
    }

    // MARK: - stageableData

    func testPDFDataItemKeptVerbatim() {
        let pdf = Data("%PDF-1.7\nbody".utf8)
        let item: [String: Any] = [UTType.pdf.identifier: pdf]
        XCTAssertEqual(ComposerPaste.stageableData(from: item), pdf)
    }

    func testPNGDataItemKeptVerbatim() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let item: [String: Any] = [UTType.png.identifier: png]
        XCTAssertEqual(ComposerPaste.stageableData(from: item), png)
    }

    func testUIImageItemReencodedToPNG() throws {
        let item: [String: Any] = [UTType.png.identifier: Self.solidImage()]
        let staged = try XCTUnwrap(ComposerPaste.stageableData(from: item))
        XCTAssertEqual(JesseAttachment.sniffMime(staged), "image/png")
    }

    func testTextOnlyItemYieldsNil() {
        let item: [String: Any] = [UTType.plainText.identifier: "just text"]
        XCTAssertNil(ComposerPaste.stageableData(from: item))
    }

    func testEmptyItemYieldsNil() {
        XCTAssertNil(ComposerPaste.stageableData(from: [:]))
    }

    // MARK: - Fixtures

    private static func solidImage(side: Int = 4) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}
