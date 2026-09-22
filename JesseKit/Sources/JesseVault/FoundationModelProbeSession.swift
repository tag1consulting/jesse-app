import Foundation
import FoundationModels

// The ONLY file in JesseVault that imports FoundationModels — the same containment
// `FoundationModelExpander` gives JesseSearch. `ModelProbe`, the report, the
// bisection and every test depend on `ProbeSessioning` instead, so the measurement
// logic is asserted against a fake and the real on-device model is never called
// from a test.
//
// NOTHING LEAVES THE DEVICE. `SystemLanguageModel` runs on-device, and this session
// is created only when the diagnostics screen's button is pressed — never on launch,
// never from a background task, never speculatively.

/// One clean `LanguageModelSession` per call.
///
/// A REUSED session would measure the wrong thing: the transcript grows with each
/// probe, so the second 1,000-character prompt is really 1,000 characters plus
/// everything before it, and the bisection would converge on a number that shrinks
/// with every attempt. A fresh session per prompt is what makes the reported figure
/// mean "a prompt of this size, by itself".
public struct FoundationModelProbeSession: ProbeSessioning {
    public init() {}

    public var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "unavailable — this device is not eligible"
            case .appleIntelligenceNotEnabled: return "unavailable — Apple Intelligence is off"
            case .modelNotReady: return "unavailable — the model is still downloading"
            @unknown default: return "unavailable — unknown reason"
            }
        @unknown default:
            return "unknown"
        }
    }

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func respond(to prompt: String) async throws -> String {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
