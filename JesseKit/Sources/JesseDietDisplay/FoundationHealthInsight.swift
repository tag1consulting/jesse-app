import Foundation
import FoundationModels
import os

// The on-device health-insight generator — the ONLY file in the app besides the
// query expander and the health classifier that imports FoundationModels. Every
// other type (and every test) depends on the `HealthInsightGenerating` seam instead,
// so the model dependency is fully contained here.
//
// This is the app's first user-facing streamed-prose surface from the local model
// (the search expander and health classifier use guided generation for structured
// output, never streamed text). It STREAMS the insight in as cumulative snapshots so
// it appears progressively after the facts, and it degrades to an EMPTY stream —
// silently off, no error, no placeholder — when the on-device model is unavailable
// for ANY reason (device ineligible, Apple Intelligence off, model not downloaded) or
// when a call errors. Nothing leaves the device; `SystemLanguageModel` runs entirely
// on-device.

/// Package-local logger (the app's shared `Log` type stayed in the iOS target). A
/// failed insight is swallowed to an empty stream; this only records it for debugging.
private let insightLog = Logger(subsystem: "com.tag1.JesseDietDisplay", category: "health")

@MainActor
final class FoundationHealthInsight: HealthInsightGenerating {
    /// One shared instance so the prewarmed session is reused across taps.
    static let shared = FoundationHealthInsight()

    /// A reused session — cheaper than a fresh one per insight. Created lazily so an
    /// unavailable model never allocates one.
    private var session: LanguageModelSession?

    /// Keep the insight short and grounded: a low temperature and a tight token cap,
    /// so it stays one-or-two sentences and appears quickly under the facts.
    private static let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 120)

    private static let instructions = """
    You write one short, factual insight (one or two sentences) about a day's \
    nutrition metric, using only the foods and numbers the user gives you. Never \
    invent foods, amounts, or targets. Write in plain second person — no lists, no \
    markdown, no preamble.
    """

    /// Warm the on-device session so the first insight doesn't pay cold-start latency.
    /// Silent no-op when the model is unavailable.
    func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        ensureSession().prewarm()
    }

    /// Stream a grounded insight for `input`, or an empty stream when the model is
    /// unavailable or the call fails. Each yielded element is the full text so far.
    func insight(for input: HealthInsightInput) -> AsyncStream<String> {
        // Availability FIRST: any unavailable reason → empty stream (feature off).
        guard case .available = SystemLanguageModel.default.availability else {
            return AsyncStream { $0.finish() }
        }
        let prompt = HealthInsightPrompt.make(input)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    let stream = self.ensureSession().streamResponse(to: prompt, options: Self.options)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)   // cumulative text so far
                    }
                    continuation.finish()
                } catch {
                    // Timeouts, guardrail rejections, decode failures — all swallowed;
                    // the facts stand alone with no error surfaced.
                    insightLog.error("health insight failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(instructions: Self.instructions)
        session = created
        return created
    }
}
