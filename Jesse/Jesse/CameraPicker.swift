import SwiftUI
import UIKit
import AVFoundation

// In-app camera capture. SwiftUI has no native camera-capture view (PhotosPicker /
// PHPicker are photo-library only), so this bridges UIKit's UIImagePickerController.
// The pure decision helpers (`CameraCapture`) are split out so the authorization
// branching and the generated filename are unit-testable without the UI or a
// device camera.

/// What to do when the user taps "Take Photo", decided from the current camera
/// authorization status. Pure and testable.
enum CameraCaptureAction: Equatable {
    /// Already authorized — present the camera.
    case present
    /// Not asked yet — request access, then present iff granted.
    case request
    /// Denied or restricted — surface a settings hint; never present (a `.camera`
    /// picker with no permission just shows a black screen).
    case denied
}

enum CameraCapture {
    /// JPEG quality for a captured photo before it's staged (then bounded by
    /// `AttachmentLimits` like every other attachment).
    static let jpegQuality: CGFloat = 0.85

    /// The action to take for a camera authorization status.
    static func action(for status: AVAuthorizationStatus) -> CameraCaptureAction {
        switch status {
        case .authorized:            return .present
        case .notDetermined:         return .request
        case .denied, .restricted:   return .denied
        @unknown default:            return .denied
        }
    }

    /// A generated, sortable filename for a captured photo, e.g.
    /// `photo-20260703-141530.jpg`. POSIX locale + fixed format so it's stable and
    /// testable.
    static func photoFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "photo-\(formatter.string(from: date)).jpg"
    }

    /// The message shown when the camera is denied/restricted.
    static let deniedMessage = "Camera access is off — enable it in Settings to take photos."
}

/// SwiftUI wrapper over `UIImagePickerController`'s camera. On capture it
/// JPEG-encodes the image and hands the bytes back through `onCapture`; cancel (or
/// a missing image) calls `onCancel`. Only present this when
/// `UIImagePickerController.isSourceTypeAvailable(.camera)` is true.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: CameraCapture.jpegQuality) {
                parent.onCapture(data)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
