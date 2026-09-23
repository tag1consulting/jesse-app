import Foundation

// THE ANSWER, AND THE THREE WAYS IT IS STOPPED FROM BEING A LIE.
//
// A 3B model reading four note extracts will usually find the date that is in them. It
// will also, given a question the extracts do not answer, produce a confident sentence
// and a plausible file name to hang it on. Nothing about the shape of that reply
// distinguishes it from a correct one, so three mechanical checks stand between the
// model and the transcript, none of which needs the model's cooperation:
//
//   1. THE INSTRUCTIONS SAY ABSTAIN IS AN OPTION, and the generated struct has a field
//      for it, so "I don't know" is a value the model can return rather than a sentence
//      it has to compose against its own training.
//   2. EVERY CITATION IS CHECKED against the paths that were actually supplied. A path
//      the model invented is dropped here, not surfaced.
//   3. AN ANSWER WITH NO SURVIVING CITATION BECOMES AN ABSTAIN. This is the one that
//      matters. Step 2 alone would leave a confident answer with its evidence quietly
//      deleted, which reads exactly like a well-sourced one; turning it into a visible
//      "not found" is the difference between a bug and a lie.
//
// Plus a wall clock. Twenty seconds is not a performance target, it is the point past
// which a person has already decided the app is broken — and an abstain that arrives is
// worth more than an answer that does not.
//
// This file imports no model framework. `VaultAnswerGenerating` is the whole dependency
// surface.

/// What the model produced, before anything has been checked.
public struct VaultAnswerDraft: Equatable, Sendable {
    public let answer: String
    public let citations: [String]
    public let abstain: Bool

    public init(answer: String, citations: [String], abstain: Bool) {
        self.answer = answer
        self.citations = citations
        self.abstain = abstain
    }
}

/// One note the answer actually came from, with the line to open it at.
public struct VaultCitation: Equatable, Sendable, Hashable {
    public let path: String
    public let line: Int

    public init(path: String, line: Int) {
        self.path = path
        self.line = line
    }

    public var reference: String { "\(path):\(line)" }
}

/// A checked answer: text that survived validation, and at least one real citation.
public struct VaultAnswer: Equatable, Sendable {
    public let text: String
    /// Never empty. An answer with no citation is not a `VaultAnswer` at all.
    public let citations: [VaultCitation]

    public init(text: String, citations: [VaultCitation]) {
        self.text = text
        self.citations = citations
    }
}

/// Why there is no answer. Typed, because the composer renders a different line for
/// each and because a diagnostics row that said only "failed" would be useless.
public enum VaultAnswerFailure: Equatable, Sendable {
    /// No usable on-device model. The composer behaves exactly as it did before this
    /// path existed.
    case modelUnavailable
    /// The gate's rules said this is not a lookup, and which rule said so. The reason
    /// is CARRIED rather than looked up again by the caller, because the composer that
    /// renders "Not tried on the device: …" must say the same thing the diagnostics row
    /// says, and two readers deriving a reason from a question twice is how they drift.
    case gateRefused(LookupGate.Refusal)
    /// The index found nothing outside `Inbox/`.
    case noHits
    /// Twenty seconds went by.
    case timedOut
    /// The model said the notes do not hold the answer, OR its answer failed
    /// validation, which is the same fact from the reader's side: this device does not
    /// have it.
    case abstained
    /// The generation itself failed for a reason that is none of the above. Carried
    /// rather than folded into `abstained` because "the model refused" and "the model
    /// errored" are different things to see in a diagnostics list.
    case failed(String)

    /// The word the diagnostics list shows.
    public var label: String {
        switch self {
        case .modelUnavailable: return "no model"
        case .gateRefused: return "not a lookup"
        case .noHits: return "no hits"
        case .timedOut: return "timed out"
        case .abstained: return "abstained"
        case .failed(let why): return "failed: \(why)"
        }
    }
}

/// An answered question, or the reason it was not.
public enum VaultAnswerOutcome: Equatable, Sendable {
    case answered(VaultAnswer)
    case unanswered(VaultAnswerFailure)

    public var answer: VaultAnswer? {
        if case .answered(let value) = self { return value }
        return nil
    }

    /// The word the diagnostics list shows.
    public var label: String {
        switch self {
        case .answered(let value): return "answered (\(value.citations.count) cited)"
        case .unanswered(let failure): return failure.label
        }
    }
}

/// What the generation seam can go wrong with, as the retry needs to tell them apart.
public enum VaultAnswerGenerationError: Error, Equatable, Sendable {
    /// The prompt did not fit. The one error worth reacting to rather than reporting.
    case contextWindow
    case failed(String)
}

/// Answering one question from some chunks, as a seam.
public protocol VaultAnswerGenerating: Sendable {
    /// Whether this device has a usable model right now.
    var isAvailable: Bool { get }
    /// Throws `VaultAnswerGenerationError.contextWindow` when the prompt was refused
    /// for size, and `.failed` for anything else.
    func generate(question: String, chunks: [RetrievedChunk]) async throws -> VaultAnswerDraft
}

/// No model on this device.
public struct NoVaultAnswerGeneration: VaultAnswerGenerating {
    public init() {}
    public var isAvailable: Bool { false }
    public func generate(question: String, chunks: [RetrievedChunk]) async throws
        -> VaultAnswerDraft {
        throw VaultAnswerGenerationError.failed("no model")
    }
}

/// The orchestration: availability, the clock, the one retry, and the validation.
/// Never throws.
public struct VaultAnswerer: Sendable {

    /// The wall clock, past which the answer is not worth waiting for.
    public static let defaultTimeLimit: TimeInterval = 20

    /// The instructions the session is created with. At most sixty words, because this
    /// model does not hold long instructions — and frozen here, beside the gate's
    /// prompt, rather than in the file that owns the framework.
    public static let instructions = """
        Answer only from the notes given. If they do not contain the answer, set \
        abstain. Cite only the paths given. At most 60 words.
        """

    /// How many citations the model may return.
    public static let maxCitations = 4

    private let generator: any VaultAnswerGenerating
    private let timeLimit: TimeInterval

    public init(generator: any VaultAnswerGenerating,
                timeLimit: TimeInterval = VaultAnswerer.defaultTimeLimit) {
        self.generator = generator
        self.timeLimit = timeLimit
    }

    /// Answer `question` from `chunks`, or say why not.
    public func answer(question: String, chunks: [RetrievedChunk]) async -> VaultAnswerOutcome {
        guard generator.isAvailable else { return .unanswered(.modelUnavailable) }
        guard !chunks.isEmpty else { return .unanswered(.noHits) }

        let generator = self.generator
        do {
            let draft = try await Self.withTimeLimit(timeLimit) {
                do {
                    return try await generator.generate(question: question, chunks: chunks)
                } catch VaultAnswerGenerationError.contextWindow {
                    // ONE retry, with half the chunks. Not a loop: if half of a measured
                    // budget still does not fit, the budget is wrong and the right
                    // outcome is an honest abstain rather than four more round trips.
                    let halved = Array(chunks.prefix(max(1, chunks.count / 2)))
                    return try await generator.generate(question: question, chunks: halved)
                }
            }
            return Self.validate(draft, chunks: chunks, question: question)
        } catch is TimedOut {
            return .unanswered(.timedOut)
        } catch VaultAnswerGenerationError.contextWindow {
            return .unanswered(.failed("prompt too large even halved"))
        } catch VaultAnswerGenerationError.failed(let why) {
            return .unanswered(.failed(why))
        } catch {
            return .unanswered(.failed(error.localizedDescription))
        }
    }

    // MARK: - Pure halves, asserted directly

    /// The prompt: the question, then each chunk under its own `NOTE path:line`
    /// header, and nothing else. No preamble, no restating of the instructions, no
    /// invented framing — every character here is a character not spent on a note.
    public static func prompt(question: String, chunks: [RetrievedChunk]) -> String {
        var out = question.trimmingCharacters(in: .whitespacesAndNewlines)
        for chunk in chunks {
            out += "\n\nNOTE \(chunk.reference)\n\(chunk.text)"
        }
        return out
    }

    /// The three checks, over a draft and the chunks it was given.
    public static func validate(_ draft: VaultAnswerDraft,
                                chunks: [RetrievedChunk],
                                question: String = "") -> VaultAnswerOutcome {
        // The line to open each cited path at: the highest-ranked chunk from that file,
        // which is the first one in `chunks`.
        var lineFor: [String: Int] = [:]
        for chunk in chunks where lineFor[chunk.path] == nil {
            lineFor[chunk.path] = chunk.line
        }

        var citations: [VaultCitation] = []
        for raw in draft.citations {
            let path = normalizeCitation(raw)
            guard let line = lineFor[path] else { continue }
            guard !citations.contains(where: { $0.path == path }) else { continue }
            citations.append(VaultCitation(path: path, line: line))
            if citations.count == maxCitations { break }
        }

        let text = draft.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Abstain wins over everything: a model that set the flag AND produced a
        // sentence is a model hedging, and the flag is the half that was asked for.
        guard !draft.abstain else { return .unanswered(.abstained) }
        guard !text.isEmpty else { return .unanswered(.abstained) }
        // THE CHECK THIS FILE EXISTS FOR. An answer whose every citation was invented
        // is not an answer with a formatting problem, it is an answer with no evidence,
        // and it becomes a visible "not found" rather than a plausible sentence.
        guard !citations.isEmpty else { return .unanswered(.abstained) }
        // …and the answer has to be ABOUT what it cites, and has to SAY something the
        // question did not already say.
        let cited = Set(citations.map(\.path))
        guard isGrounded(text, in: chunks.filter { cited.contains($0.path) },
                         question: question) else {
            return .unanswered(.abstained)
        }
        return .answered(VaultAnswer(text: text, citations: citations))
    }

    /// Whether `answer` carries at least one significant word that is in an extract it
    /// cites AND was not already in the question.
    ///
    /// "Significant" is `LookupQuery`'s rule — the question tokenizer's stop list, so the
    /// vault has exactly one idea of which words carry meaning — plus a three-character
    /// floor, because a two-letter coincidence is not evidence of anything. The
    /// comparison folds case and diacritics through `localizedStandardContains`, the same
    /// way the index's own tokenizer does.
    ///
    /// BOTH HALVES WERE MEASURED, on this corpus, with the real on-device model:
    ///
    ///   * Without the extract check, "what colour is the studio door" — over notes that
    ///     never mention a door — came back "white", citing the studio note it had been
    ///     handed. A REAL path, so the citation check passed it.
    ///   * Without the question check, "what is the name of the kiln repair company in
    ///     Florence" came back "Kiln repair company in Florence", citing the kiln note:
    ///     every word of it appears in the extract, so the extract check passed it. An
    ///     answer made only of the question's own words has answered nothing.
    ///
    /// An answer with no significant words at all ("yes", "it is") fails for the same
    /// reason: there is nothing in it to check, and a bare affirmation with a citation is
    /// precisely the shape that reads as sourced and is not.
    ///
    /// It is a floor, not a proof. A wrong answer assembled out of words that ARE in the
    /// extract still gets through, which is why the badge and the citations are on every
    /// one of these replies.
    public static func isGrounded(_ answer: String, in chunks: [RetrievedChunk],
                                  question: String = "") -> Bool {
        guard !chunks.isEmpty else { return false }
        let asked = Set(LookupQuery.keywords(question).map { $0.lowercased() })
        let words = LookupQuery.keywords(answer)
            .filter { $0.count >= 3 && !asked.contains($0.lowercased()) }
        guard !words.isEmpty else { return false }
        return words.contains { word in
            chunks.contains { $0.text.localizedStandardContains(word) }
        }
    }

    /// A cited path as the model is likely to have written it back.
    ///
    /// The prompt names each note `NOTE path:line`, and a model that copies the whole
    /// header, or wraps the path in quotes or brackets, has still cited a real file.
    /// Trimming those is not leniency about invented paths — the result is still
    /// matched exactly against the supplied set.
    static func normalizeCitation(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("NOTE ") { value = String(value.dropFirst(5)) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]()<> "))
        // `path.md:12` back to `path.md`.
        if let colon = value.lastIndex(of: ":"),
           value[value.index(after: colon)...].allSatisfy(\.isNumber),
           value.index(after: colon) < value.endIndex {
            value = String(value[value.startIndex..<colon])
        }
        return value
    }

    // MARK: - The clock

    /// Thrown by the racing task, and caught by exactly one place.
    struct TimedOut: Error {}

    /// Run `work`, or throw `TimedOut` when `seconds` go by first.
    ///
    /// A task group rather than a `Task` plus a cancel, because the group is what
    /// guarantees the loser is cancelled on every exit path including a throw — and a
    /// leaked on-device inference is minutes of the neural engine nobody is waiting for.
    static func withTimeLimit<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
