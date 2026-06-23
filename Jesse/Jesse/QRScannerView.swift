import SwiftUI
import AVFoundation

/// A minimal QR scanner wrapping `AVCaptureSession` + `AVCaptureMetadataOutput`.
/// Calls `onScan` once with the first decoded string, then stops the session.
/// If the camera is unavailable or permission is denied, `onError` is called
/// with a readable message instead of crashing.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let parent: QRScannerView
        // Latch so we only forward the first successful decode.
        private var didScan = false

        init(_ parent: QRScannerView) { self.parent = parent }

        func scanner(_ controller: ScannerViewController, didDecode value: String) {
            guard !didScan else { return }
            didScan = true
            parent.onScan(value)
        }

        func scanner(_ controller: ScannerViewController, didFail message: String) {
            parent.onError(message)
        }
    }
}

protocol ScannerViewControllerDelegate: AnyObject {
    func scanner(_ controller: ScannerViewController, didDecode value: String)
    func scanner(_ controller: ScannerViewController, didFail message: String)
}

/// Hosts the capture session and renders the live preview. Kept deliberately
/// small: configure on appear, surface any failure through the delegate.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUpCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setUpCapture()
                    } else {
                        self.delegate?.scanner(self, didFail: "Camera access was denied. Enable it in Settings to scan the pairing QR.")
                    }
                }
            }
        default:
            delegate?.scanner(self, didFail: "Camera access is unavailable. Enable it in Settings to scan the pairing QR, or enter the host and token by hand.")
        }
    }

    private func setUpCapture() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            delegate?.scanner(self, didFail: "No usable camera was found on this device.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            delegate?.scanner(self, didFail: "Couldn't start the camera for scanning.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // Starting the session blocks; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr, let value = object.stringValue else { return }
        // Stop on the first hit so we report exactly once.
        if session.isRunning { session.stopRunning() }
        delegate?.scanner(self, didDecode: value)
    }
}
