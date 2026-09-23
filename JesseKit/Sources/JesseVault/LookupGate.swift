import Foundation

// WHAT THE DEVICE IS ALLOWED TO ANSWER BY ITSELF.
//
// The on-device model is about 3B parameters. On the bridge side the same class of
// workload was already measured with models forty times larger, and the finding was
// the one this gate is built on: LOOKUPS come back right, SYNTHESIS comes back
// confidently wrong. A three-billion-parameter model asked to "draft the email about
// the fiber contract" will produce an email. It will be a bad email, and nothing in
// the answer will say so.
//
// So the gate is deliberately asymmetric. A refusal costs one queued message that the
// bridge answers properly a few minutes later; a wrong admission costs a fabricated
// answer in a transcript that reads exactly like a real one. Every ambiguous case
// therefore refuses, INCLUDING the case where the classifier itself fails.
//
// Two tiers, and the cheap one runs first because it is free and because it is the
// tier that cannot be talked out of its answer:
//
//   1. RULES — length, a request verb, emptiness. No model, no latency, deterministic.
//   2. THE MODEL — one boolean, guided generation, asked only about questions the
//      rules did not already refuse.
//
// This file imports no model framework. `LookupClassifying` is the whole dependency
// surface, exactly as `ProbeSessioning` is for the probe, so every rule below is
// asserted against a fake and no test ever reaches a real model.

/// The model half of the gate: one question in, one boolean out.
///
/// NEVER THROWS. A model that is unavailable, refuses, times out or returns nonsense
/// must all collapse to the same answer — `false`, not a lookup — because the caller
/// has exactly one safe move in every one of those cases and it is to queue the
/// question for the bridge.
public protocol LookupClassifying: Sendable {
    /// Whether the on-device model considers this a lookup. `false` on any failure.
    func isLookup(_ question: String) async -> Bool
}

/// The inert classifier: nothing is ever a lookup. The default for previews and for
/// any test that is not about the model tier, and the correct behaviour on a device
/// with no usable model.
public struct NoLookupClassification: LookupClassifying {
    public init() {}
    public func isLookup(_ question: String) async -> Bool { false }
}

/// A classifier that answers a fixed verdict. Exists so the composition of the two
/// tiers can be asserted without a model.
public struct FixedLookupClassification: LookupClassifying {
    private let verdict: Bool
    public init(_ verdict: Bool) { self.verdict = verdict }
    public func isLookup(_ question: String) async -> Bool { verdict }
}

/// The gate: rules first, model second, refusal by default.
public enum LookupGate {

    /// Longer than this, in words, and it is not a lookup.
    ///
    /// Forty is not a tuned number, it is a shape: a question with a findable answer
    /// ("when is the school concert", "what did we decide about the fiber contract")
    /// is under a dozen words, and forty leaves room for a rambling one without
    /// letting a pasted paragraph through as a question.
    public static let maxWords = 40

    /// The verbs that mean "make me something" rather than "tell me something".
    ///
    /// Every one of them names work this model cannot do well: composing prose,
    /// weighing several notes against each other, or CHANGING something. `log`,
    /// `schedule` and `remind` are in the list for that last reason and not for the
    /// first — nothing on this path writes anywhere, so a question that asks for a
    /// write must reach the bridge, which can actually perform it.
    public static let requestVerbs = [
        "draft", "write", "summarize", "summarise", "plan", "compare",
        "email", "message", "rewrite", "translate", "log", "schedule", "remind",
    ]

    /// Why the rule tier refused, or that it did not.
    public enum RuleVerdict: Equatable, Sendable {
        /// The rules alone settle it: not a lookup, for this reason.
        case refused(String)
        /// The rules have nothing to say; ask the model.
        case undecided
    }

    /// The deterministic tier. Pure, and the only tier that runs when there is no
    /// model on the device.
    public static func rule(_ question: String) -> RuleVerdict {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused("empty") }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count > maxWords {
            return .refused("longer than \(maxWords) words")
        }
        for word in words {
            if let verb = requestVerb(in: word) {
                return .refused("asks to \(verb)")
            }
        }
        return .undecided
    }

    /// The request verb a single word carries, or nil.
    ///
    /// Matched on the WORD, never on a substring of the question: "when is the plan
    /// meeting" has to be refused (it contains `plan` as a word), but "what is the
    /// airplane's tail number" must not be, and a substring test cannot tell those
    /// apart. Common inflections count — "drafting", "summarised", "compares" are the
    /// same request — because a gate that a gerund walks straight through is not a
    /// gate.
    static func requestVerb(in word: some StringProtocol) -> String? {
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }
        for verb in requestVerbs where inflections(of: verb).contains(cleaned) {
            return verb
        }
        return nil
    }

    /// A verb and the forms of it that mean the same request.
    static func inflections(of verb: String) -> Set<String> {
        var forms: Set<String> = [verb, verb + "s", verb + "ed", verb + "ing"]
        if verb.hasSuffix("e") {
            let stem = String(verb.dropLast())
            forms.insert(verb + "d")
            forms.insert(stem + "ing")
        }
        return forms
    }

    /// The whole gate. Rules, then the model, then refuse.
    ///
    /// The classifier is asked ONLY about questions the rules let through, which is
    /// what keeps the common refusals free: a pasted paragraph or a "draft me a…"
    /// never costs a round trip.
    public static func isLookup(_ question: String,
                                classifier: any LookupClassifying) async -> Bool {
        switch rule(question) {
        case .refused:
            return false
        case .undecided:
            return await classifier.isLookup(question)
        }
    }

    /// The question put to the classifier, frozen here rather than in the file that
    /// owns the model session — the same separation `AskDomain` makes for the hosted
    /// prompts. A reword is a behaviour change to the gate, so it does not belong in
    /// the layer that merely talks to the framework.
    public static func classifierPrompt(_ question: String) -> String {
        """
        Is this a question whose answer is a fact that could be found in one or two \
        personal notes? Yes or no.

        Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}
