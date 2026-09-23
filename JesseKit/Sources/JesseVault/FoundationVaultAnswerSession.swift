import Foundation
import FoundationModels
import os

// THE ONE FILE IN THIS PACKAGE THAT IMPORTS FoundationModels FOR AN ANSWER.
//
// It used to be two seams in one object: a yes/no classifier for the gate and the
// answer's generator. The classifier is gone — the gate is rules now, for the reason
// written at the top of `LookupGate` — and what is left is one job, one session.
//
// NOTHING LEAVES THE DEVICE. `SystemLanguageModel` is on-device inference; there is no
// network call on this path and no analytics. The notes put in front of it are read
// from the folder the user picked and go nowhere else.
//
// The session is REUSED rather than created per call, which is the opposite of what
// `FoundationModelProbeSession` does, and both are right: the probe is measuring how
// much a session can hold, so a transcript would contaminate the measurement; this is
// answering questions, where the cold start is the dominant cost and the transcript is
// harmless because each `respond` is a complete, self-contained prompt.

private let vaultLog = Logger(subsystem: "com.tag1.jesse", category: "vault-answer")

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

/// The on-device model, as the answerer needs it.
///
/// `@unchecked Sendable` with a lock, the same shape `VaultIndex` uses in this target:
/// `LanguageModelSession` is itself `@unchecked Sendable`, and the only mutable state
/// here is the lazily created session.
public final class FoundationVaultAnswerSession: VaultAnswerGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var answerSession: LanguageModelSession?

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
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
