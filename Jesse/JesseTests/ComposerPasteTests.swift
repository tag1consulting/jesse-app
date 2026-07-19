import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Jesse

/// Covers `ComposerPaste` — the pure decisions behind "long-press → Paste a
/// copied photo/PDF into the composer". The provider reading lives in the view
/// (`NSItemProvider` loading needs the pasteboard/UI); the byte rules it applies
/// are pinned by `PasteAttachmentTests`. These pin which pastes count as media and
/// the type-load order (concrete encodings, kept verbatim so a photo is not
/// re-encoded to a larger PNG).
@MainActor
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

    // MARK: - mediaTypes (load order)

    func testMediaTypesPreferPDFAndAreConcrete() {
        XCTAssertEqual(ComposerPaste.mediaTypes.first, .pdf, "a PDF should be preferred over its rasterization")
        // Only concrete encodings — the abstract `.image` is deliberately absent so
        // the verbatim-data loop never loads a re-encoded representation; a bare
        // bitmap is handled by the view's UIImage fallback instead.
        XCTAssertFalse(ComposerPaste.mediaTypes.contains(.image))
        // Compact photo encodings must be present so a JPEG/HEIC photo is read as
        // its own bytes (kept verbatim), not re-encoded to a larger PNG.
        XCTAssertTrue(ComposerPaste.mediaTypes.contains(.jpeg))
        XCTAssertTrue(ComposerPaste.mediaTypes.contains(.heic))
    }
}
