import XCTest
import SwiftUI
@testable import Jesse

/// Renders the real `ProvenanceChip` in every state to PNGs, as visual evidence of
/// each chip variant for the PR. Not a pass/fail contract test — it renders the actual
/// SwiftUI view (via `ImageRenderer`) and writes the images under the derived-data
/// tmp dir, printing the paths. Always passes; skips silently if rendering is
/// unavailable (e.g. a headless CI without a display).
@MainActor
final class ProvenanceChipSnapshotTests: XCTestCase {

    private func chip(_ route: String, model: String?, badge: String,
                      hv: Bool = false, vq: Bool = false, cu: Bool = false) -> JesseProvenance {
        JesseProvenance(route: route, model: model, badge: badge,
                        flags: JesseProvenanceFlags(hostedVerify: hv, verifyQueued: vq, citationsUnverified: cu))
    }

    func testRenderEveryChipState() throws {
        let states: [(String, JesseProvenance)] = [
            ("hosted", chip("hosted", model: "claude-opus-4-8", badge: "[hosted · claude-opus-4-8]")),
            ("vault-local", chip("vaultqa-local", model: "local-oss", badge: "[local · vault · local-oss]")),
            ("diet-local-hosted-verify", chip("diet-local", model: "local-oss", badge: "[local · diet · local-oss + hosted verify]", hv: true)),
            ("diet-verify-queued", chip("emergency-local", model: "local-oss", badge: "[local · diet · local-oss + verify queued]", vq: true)),
            ("emergency-verified", chip("emergency-local", model: "local-oss", badge: "[local · emergency · local-oss]")),
            ("emergency-citations-unverified", chip("emergency-local", model: "local-oss", badge: "[local · emergency · local-oss]", cu: true)),
        ]

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("provenance-chips", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for (name, prov) in states {
            for (scheme, suffix) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
                let view = ProvenanceChip(provenance: prov)
                    .padding(10)
                    .background(scheme == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                guard let img = renderer.uiImage, let png = img.pngData() else {
                    throw XCTSkip("ImageRenderer produced no image (headless environment)")
                }
                let url = outDir.appendingPathComponent("\(name)-\(suffix).png")
                try png.write(to: url)
                print("CHIP_SNAPSHOT \(url.path)")
            }
        }
        print("CHIP_SNAPSHOT_DIR \(outDir.path)")
    }
}
