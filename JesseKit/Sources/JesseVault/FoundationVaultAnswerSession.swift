import Foundation
import FoundationModels
import os

// THE ONE NEW FILE IN THIS PACKAGE THAT IMPORTS FoundationModels.
//
// It is two seams in one object for one reason: both of them talk to the same model on
// the same device within the same second, and two objects would open two sessions and
// pay the cold start twice for what is, from the model's side, one conversation about
// one question.
//
// NOTHING LEAVES THE DEVICE. `SystemLanguageModel` is on-device inference; there is no
// network call on this path and no analytics. The notes put in front of it are read
// from the folder the user picked and go nowhere else.
//
// The sessions are REUSED rather than created per call, which is the opposite of what
// `FoundationModelProbeSession` does, and both are right: the probe is measuring how
// much a session can hold, so a transcript would contaminate the measurement; this is
// answering questions, where the cold start is the dominant cost and the transcript is
// harmless because each `respond` is a complete, self-contained prompt.

private let vaultLog = Logger(subsystem: "com.tag1.jesse", category: "vault-answer")

/// The classifier's output: one boolean, guided, so "yes or no" cannot come back as a
/// paragraph about how it depends.
@Generable
private struct LookupVerdict {
    @Guide(description: "true when the question asks for a fact that one or two personal notes could contain, false when it asks for something to be written, planned, compared or changed")
    var isLookup: Bool
}

/// The answer's shape, guided. The `abstain` field is what makes "I don't know" a value
/// the model returns rather than a sentence it has to invent.
@Generable
private struct GeneratedVaultAnswer {
    @Guide(description: "The answer in at most 60 words, taken only from the notes given. Empty when abstaining.")
    var answer: String
    @Guide(description: "The exact note paths the answer came from, copied from the NOTE headers",
           .count(0...4))
    var citations: [String]
    @Guide(description: "true when the notes given do not contain the answer")
    var abstain: Bool
}

/// The on-device model, as the gate and the answerer need it.
///
/// `@unchecked Sendable` with a lock, the same shape `VaultIndex` uses in this target:
/// `LanguageModelSession` is itself `@unchecked Sendable`, and the only mutable state
/// here is the two lazily created sessions.
public final class FoundationVaultAnswerSession: LookupClassifying, VaultAnswerGenerating,
                                                 @unchecked Sendable {
    private let lock = NSLock()
    private var answerSession: LanguageModelSession?

    /// The classifier gets its own one-line instruction rather than the answerer's, so
    /// neither session ever carries the other's.
    private static let classifierInstructions = """
        You decide whether a question can be answered by looking up a fact in personal \
        notes. Answer with the boolean only.
        """

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: - LookupClassifying

    /// Never throws, and every failure is `false`: an unavailable model, a guardrail
    /// refusal and a decode failure all mean the same thing to the caller, which is
    /// that this question goes to the bridge.
    public func isLookup(_ question: String) async -> Bool {
        guard isAvailable else { return false }
        do {
            // A FRESH SESSION EVERY TIME, and this one is measured rather than assumed.
            // Reusing it was the first thing tried and it produced a classifier that
            // drifted: over a run of questions the transcript fills with "Question: …/
            // isLookup: true" pairs and the model starts answering the PATTERN instead of
            // the question, refusing "what is the tenmoku glaze recipe" as not a lookup a
            // few calls after accepting its twin. The same reason `ModelProbe` refuses to
            // reuse a session — a transcript is state, and a boolean asked about one
            // question must not depend on the questions before it.
            //
            // The answering session below is REUSED, and that is not a contradiction: its
            // prompt is a complete, self-contained question plus its notes, and the cold
            // start it avoids is the dominant cost of an answer.
            let response = try await LanguageModelSession(
                instructions: Self.classifierInstructions)
                .respond(to: LookupGate.classifierPrompt(question),
                         generating: LookupVerdict.self)
            return response.content.isLookup
        } catch {
            vaultLog.error("lookup classification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - VaultAnswerGenerating

    public func generate(question: String, chunks: [RetrievedChunk]) async throws
        -> VaultAnswerDraft {
        do {
            let response = try await session(&answerSession,
                                             instructions: VaultAnswerer.instructions)
                .respond(to: VaultAnswerer.prompt(question: question, chunks: chunks),
                         generating: GeneratedVaultAnswer.self)
            let content = response.content
            return VaultAnswerDraft(answer: content.answer,
                                    citations: content.citations,
                                    abstain: content.abstain)
        } catch {
            // THE ONE ERROR WORTH REACTING TO rather than reporting. A window overflow
            // means the budget was wrong for this device, and half the chunks is a real
            // second chance; every other generation error is terminal for this turn.
            if Self.isContextWindow(error) {
                // The session's transcript is part of what overflowed, so the retry gets
                // a clean one. Keeping it would make the second attempt smaller by
                // exactly nothing.
                lock.withLock { answerSession = nil }
                throw VaultAnswerGenerationError.contextWindow
            }
            vaultLog.error("vault answer failed: \(error.localizedDescription, privacy: .public)")
            throw VaultAnswerGenerationError.failed(Self.describe(error))
        }
    }

    // MARK: - Reading an error without naming a deprecated case
    //
    // The context-window condition is reported two different ways by two different SDK
    // vintages: `LanguageModelError.contextSizeExceeded` from 27, and the older
    // `LanguageModelSession.GenerationError.exceededContextWindowSize` before it. Every
    // case of that older enum is `@available(deprecated: 27.0)`, so PATTERN MATCHING one
    // is a deprecation warning — and this repository builds shipping code with warnings
    // as errors, with the app's deployment target raised to the newest runtime by the
    // local gate. Naming the case is therefore not available, and dropping the older
    // spelling would silently lose the retry on a device running 26.
    //
    // So the new enum is matched properly when it exists, and the old one by its CASE
    // NAME through `Mirror`, which is what an enum with an associated value puts in its
    // single child's label. Reflection for a string is not elegant; it is the honest way
    // to read a case the compiler will not let this file spell.

    /// Whether `error` is the model saying the prompt did not fit.
    static func isContextWindow(_ error: any Error) -> Bool {
        if #available(iOS 27.0, macOS 27.0, *) {
            if let modern = error as? LanguageModelError,
               case .contextSizeExceeded = modern {
                return true
            }
        }
        return caseName(of: error) == "exceededContextWindowSize"
    }

    /// The case name of an enum error with an associated value, or nil.
    static func caseName(of error: any Error) -> String? {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return nil }
        return mirror.children.first?.label
    }

    /// One short line for an error whose `localizedDescription` is routinely empty.
    static func describe(_ error: any Error) -> String {
        let localized = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty { return localized }
        return caseName(of: error) ?? "generation failed"
    }

    // MARK: - Sessions

    /// The session for one role, created on first use under the lock.
    private func session(_ storage: inout LanguageModelSession?,
                         instructions: String) -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage { return existing }
        let created = LanguageModelSession(instructions: instructions)
        storage = created
        return created
    }

    /// Warm the answering session, so the first offline question does not pay the cold
    /// start on top of its own latency. Silent no-op when the model is unavailable, and
    /// never speculative — a caller presses something first.
    public func prewarm() {
        guard isAvailable else { return }
        session(&answerSession, instructions: VaultAnswerer.instructions).prewarm()
    }
}
