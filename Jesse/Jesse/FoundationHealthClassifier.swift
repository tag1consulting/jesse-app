import Foundation
import FoundationModels

// Tier 1 of the health-relevance classifier — the ONLY classifier file that
// imports FoundationModels. `UnionHealthClassifier` depends on the `classify`
// closure, not this type, so the model dependency is fully contained here and the
// rest of the app (and every test) stays model-free.
//
// Everything degrades to `nil` (Tier 0's answer stands) when the on-device model
// is unavailable for ANY reason — device ineligible, Apple Intelligence off, model
// not downloaded — or when the call errors or exceeds the tight latency bound.
// Nothing leaves the device; `SystemLanguageModel` runs entirely on-device.

/// Guided-generation output: a single boolean. `@Generable` constrains the model
/// to return exactly this shape, so there is nothing to parse.
@Generable
private struct HealthRelevanceAnswer {
    @Guide(description: "true if the message relates to the user's health, fitness, sleep, diet, or exercise; false otherwise")
    var relevant: Bool
}

@MainActor
final class FoundationHealthClassifier {
    /// One shared instance so the prewarmed session is reused across turns.
    static let shared = FoundationHealthClassifier()

    /// A reused session (prewarmed on composer focus) — cheaper than a fresh
    /// session per classification. Created lazily so an unavailable model never
    /// allocates one.
    private var session: LanguageModelSession?

    /// Tight bound: this sits in the send path ahead of the network turn, so a slow
    /// model must never delay the turn. On overrun the keyword floor's answer stands.
    private static let timeout: Duration = .milliseconds(300)

    private static let instructions = """
    You classify whether a short message from the user relates to their health, \
    fitness, sleep, diet, or exercise — logging or asking about workouts, runs, \
    swims, walks, sleep, weight, meals, calories, heart rate, recovery, steps, or \
    how they physically feel. Answer with the boolean only.
    """

    /// Warm the on-device session when the composer appears, so the first real
    /// classification doesn't pay cold-start latency. Silent no-op when unavailable.
    func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        ensureSession().prewarm()
    }

    /// Whether `text` is health-related per the on-device model, or `nil` when the
    /// model is unavailable, the call fails, or it exceeds the 300 ms bound. Never
    /// throws — the union treats `nil` as "no Tier 1 answer" and keeps Tier 0's.
    func classify(_ text: String) async -> Bool? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Race the model against the latency bound; whichever finishes first wins.
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in
                do {
                    let prompt = """
                    Does this message relate to the user's health, fitness, sleep, \
                    diet, or exercise? Message: "\(trimmed)"
                    """
                    let response = try await self.ensureSession().respond(
                        to: prompt, generating: HealthRelevanceAnswer.self)
                    return response.content.relevant
                } catch {
                    // Timeouts, guardrail rejections, decode failures — all → nil.
                    Log.health.error("health classification failed: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil   // the bound elapsed → no Tier 1 answer
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(instructions: Self.instructions)
        session = created
        return created
    }
}
