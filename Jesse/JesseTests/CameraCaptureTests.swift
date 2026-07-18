import XCTest
import AVFoundation
@testable import Jesse

/// Covers `CameraCapture` — the pure decision helpers behind in-app camera capture
/// (the UI/`UIImagePickerController` bridge itself isn't unit-testable and needs a
/// device camera).
@MainActor
final class CameraCaptureTests: XCTestCase {

    func testAuthorizedPresents() {
        XCTAssertEqual(CameraCapture.action(for: .authorized), .present)
    }

    func testNotDeterminedRequests() {
        XCTAssertEqual(CameraCapture.action(for: .notDetermined), .request)
    }

    func testDeniedAndRestrictedDoNotPresent() {
        XCTAssertEqual(CameraCapture.action(for: .denied), .denied)
        XCTAssertEqual(CameraCapture.action(for: .restricted), .denied)
    }

    func testPhotoFilenameFormatAndDeterminism() {
        // 2026-07-03 14:15:30 UTC, formatted in the local calendar/POSIX locale.
        let date = Date(timeIntervalSince1970: 1_751_552_130)
        let name = CameraCapture.photoFilename(date: date)
        XCTAssertTrue(name.hasPrefix("photo-"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
        // Same input → same output (no clock read hidden inside).
        XCTAssertEqual(name, CameraCapture.photoFilename(date: date))
        // Shape: photo-YYYYMMDD-HHMMSS.jpg
        XCTAssertNotNil(name.range(of: #"^photo-\d{8}-\d{6}\.jpg$"#, options: .regularExpression),
                        "unexpected filename shape: \(name)")
    }

    func testGeneratedNameSniffsAsAcceptableImageWhenPairedWithJPEGBytes() {
        // The camera path hands JPEG bytes to addAttachment with this name; confirm
        // the JPEG magic bytes still sniff as image/jpeg (so the caps apply).
        let jpegMagic = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(JesseAttachment.sniffMime(jpegMagic), "image/jpeg")
        XCTAssertTrue(CameraCapture.photoFilename().hasSuffix(".jpg"))
    }
}
