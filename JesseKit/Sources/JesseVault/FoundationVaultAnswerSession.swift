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

    // MARK: - Reading an error without naming its type
    //
    // The context-window condition is reported two different ways by two different SDK
    // vintages: `LanguageModelError.contextSizeExceeded` from 27, and the older
    // `LanguageModelSession.GenerationError.exceededContextWindowSize` before it. NEITHER
    // can be spelled here, for opposite reasons:
    //
    // - Every case of the older enum is `@available(deprecated: 27.0)`, so pattern
    //   matching one is a deprecation warning under the 27 SDK, and shipping code builds
    //   with warnings as errors.
    // - `LanguageModelError` does not exist before the 27 SDK, and an
    //   `if #available(iOS 27.0, macOS 27.0, *)` around it does not help: that is a
    //   RUNTIME check, and the compiler must still resolve every name inside it. Naming
    //   the type broke `swift build` under SDK 26.2 (the Studio) and 26.6 (the hosted
    //   runner's `latest-stable`) alike.
    //
    // A compile-time SDK check is not available either. Swift has no `#if sdk(>=27)`;
    // `#if compiler(...)` tracks the Swift version, which moves within an SDK major, and
    // `canImport(FoundationModels, _version:)` needs a module version for the 27 SDK that
    // no toolchain this repository builds with can show.
    //
    // So both are read by NAME: the case label from `Mirror` (or, for a case without an
    // associated value, its default description), and for the newer spelling the type's
    // name too. Nothing here names a type an SDK might lack or deprecate, so this file
    // compiles identically on every SDK and loses the retry on none.

    /// Whether `error` is the model saying the prompt did not fit.
    static func isContextWindow(_ error: any Error) -> Bool {
        let name = caseName(of: error)
        if name == "exceededContextWindowSize" { return true }
        return name == "contextSizeExceeded"
            && String(describing: type(of: error)) == "LanguageModelError"
    }

    /// The case name of an enum error, or nil.
    ///
    /// A case with an associated value puts its name in its single child's label. A case
    /// without one has no child, and its default description is the bare case name. That
    /// description is trusted only when it is a bare identifier, since a type may replace
    /// it with a sentence of its own. (Asking whether the type conforms to
    /// `CustomStringConvertible` cannot answer that: every error on Darwin bridges to
    /// `NSError`, which does.)
    static func caseName(of error: any Error) -> String? {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return nil }
        if let label = mirror.children.first?.label { return label }
        guard mirror.children.isEmpty else { return nil }
        let described = String(describing: error)
        let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard let first = described.unicodeScalars.first,
              !CharacterSet.decimalDigits.contains(first),
              described.unicodeScalars.allSatisfy(identifier.contains) else { return nil }
        return described
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
