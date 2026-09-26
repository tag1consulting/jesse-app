import Foundation

// WHAT THE DEVICE IS ALLOWED TO TRY BY ITSELF.
//
// The on-device model is about 3B parameters. On the bridge side the same class of
// workload was already measured with models forty times larger, and the finding was
// the one this gate is built on: LOOKUPS come back right, SYNTHESIS comes back
// confidently wrong. A three-billion-parameter model asked to "draft the email about
// the fiber contract" will produce an email. It will be a bad email, and nothing in
// the answer will say so.
//
// So the gate refuses the SHAPE of a request rather than judging the question, and it
// is rules only — no model, no latency, no coin flip.
//
// WHY THERE IS NO MODEL TIER ANY MORE. There was one: a second pass that asked the
// on-device model "is this a question whose answer is a fact that could be found in one
// or two personal notes? Yes or no." Measured on the phone in airplane mode it refused
// "What is Aurora's birthday?" — a lookup with the answer sitting in the vault two
// notes away — while answering "When was I born?" from the same corpus in the same
// minute. A 3B model given a bare yes/no about an abstract category is a coin flip, and
// a coin flip in FRONT of the pipeline buys nothing, because everything behind it
// already refuses what it cannot answer: retrieval returns no chunks, or
// `VaultAnswerer`'s validation (citations must be paths that were actually provided, an
// answer must share a significant word with a cited extract, zero valid citations
// forces an abstain) turns a bad answer into an honest "not found". A question the
// rules let through therefore costs, at worst, a few seconds and an abstain — which is
// exactly what a refusal cost, minus the lie that nothing was tried.
//
// The asymmetry that remains is the one worth keeping: a refusal costs one queued
// message the bridge answers properly a few minutes later, and every refusal now says
// WHICH rule fired, in words, in the transcript.
//
// WHY THERE IS A POSITIVE RULE NOW. Every rule here used to be a refusal, which means the
// gate's DEFAULT was "pass": a sentence with no listed verb in it got through whatever
// shape it was. "Track two cups of coffee. 6:50 and 7:20." got through exactly that way on
// 2026-09-26 and was answered with a café's opening hours out of a Scotland trip guide,
// while the request to log two coffees reached nobody at all. A lookup has to READ AS A
// QUESTION now — a question mark, or an interrogative first word — and everything else is
// refused and queued for the bridge, which can actually perform it.
//
// This file imports no model framework and has no dependency surface at all. Every rule
// below is a pure function over a string.

/// The gate: rules, and nothing else.
public enum LookupGate {

    /// Longer than this, in words, and it is not a lookup.
    ///
    /// Forty is not a tuned number, it is a shape: a question with a findable answer
    /// ("when is the school concert", "what did we decide about the fiber contract")
    /// is under a dozen words, and forty leaves room for a rambling one without
    /// letting a pasted paragraph through as a question.
    public static let maxWords = 40

    /// A verb that means "make me something" rather than "tell me something", together
    /// with the clause a refusal shows for it.
    ///
    /// The two travel as one value so a verb cannot be added without the words that
    /// explain its refusal — the failure mode of a verb list beside a separate phrase
    /// table is a verb that refuses with someone else's sentence.
    public struct RequestVerb: Equatable, Sendable {
        /// The infinitive. Inflections are derived, not listed.
        public let verb: String
        /// The clause that follows "Not tried on the device: ".
        public let because: String

        public init(verb: String, because: String) {
            self.verb = verb
            self.because = because
        }
    }

    /// The verbs that mean "make me something" rather than "tell me something".
    ///
    /// Every one of them names work this model cannot do well: composing prose,
    /// weighing several notes against each other, or CHANGING something. `log`,
    /// `schedule` and `remind` are in the list for that last reason and not for the
    /// first — nothing on this path writes anywhere, so a question that asks for a
    /// write must reach the bridge, which can actually perform it.
    public static let requestVerbs: [RequestVerb] = [
        RequestVerb(verb: "draft", because: "it asks for a draft"),
        RequestVerb(verb: "write", because: "it asks for something to be written"),
        RequestVerb(verb: "summarize", because: "it asks for a summary"),
        RequestVerb(verb: "summarise", because: "it asks for a summary"),
        RequestVerb(verb: "plan", because: "it asks for a plan"),
        RequestVerb(verb: "compare", because: "it asks for a comparison"),
        RequestVerb(verb: "email", because: "it asks for an email"),
        RequestVerb(verb: "message", because: "it asks for a message"),
        RequestVerb(verb: "rewrite", because: "it asks for a rewrite"),
        RequestVerb(verb: "translate", because: "it asks for a translation"),
        RequestVerb(verb: "log", because: "it asks to log something"),
        RequestVerb(verb: "schedule", because: "it asks to schedule something"),
        RequestVerb(verb: "remind", because: "it asks for a reminder"),
        // ── THE WRITES. Every one of these was missing on 2026-09-26, and the sentence
        //    that got through was "Track two cups of coffee. 6:50 and 7:20." — a write the
        //    device answered instead of queueing, with a café's opening hours. A verb here
        //    names work only the bridge can do, so it must reach the bridge.
        RequestVerb(verb: "track", because: "it asks to track something"),
        RequestVerb(verb: "add", because: "it asks to add something"),
        RequestVerb(verb: "record", because: "it asks to record something"),
        RequestVerb(verb: "note", because: "it asks for a note"),
        RequestVerb(verb: "save", because: "it asks to save something"),
        RequestVerb(verb: "remember", because: "it asks to remember something"),
        RequestVerb(verb: "set", because: "it asks to set something"),
        RequestVerb(verb: "book", because: "it asks to book something"),
        RequestVerb(verb: "buy", because: "it asks to buy something"),
        RequestVerb(verb: "cancel", because: "it asks to cancel something"),
        RequestVerb(verb: "delete", because: "it asks to delete something"),
        RequestVerb(verb: "remove", because: "it asks to remove something"),
        RequestVerb(verb: "send", because: "it asks to send something"),
        RequestVerb(verb: "move", because: "it asks to move something"),
        RequestVerb(verb: "update", because: "it asks to update something"),
        RequestVerb(verb: "create", because: "it asks to create something"),
    ]

    /// The words that open a question.
    ///
    /// A LOOKUP IS A QUESTION, and until this list existed the gate had no way to say so.
    /// Every rule above it is a REFUSAL, so anything with no listed verb in it passed by
    /// default — and on 2026-09-26 "Track two cups of coffee. 6:50 and 7:20." passed that
    /// way and was answered with a café's opening hours. A write dressed as a statement is
    /// the common shape of that mistake, and a statement is what this rule catches.
    ///
    /// Interrogatives, plus the auxiliaries that open a yes/no question. It is a SHAPE test
    /// and not a meaning test, which is what keeps it a rule: the alternative is asking a
    /// 3B model "is this a question", which is the coin flip this whole file exists instead
    /// of.
    public static let interrogatives: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "which", "why", "how",
        "is", "are", "am", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "should", "has", "have", "had",
    ]

    /// A refusal, in the two registers the two readers need.
    ///
    /// `rule` is for the diagnostics list, where the question is "which rule fired";
    /// `because` is for the transcript, where the question is "why did my phone not even
    /// look". The same refusal, never two independently worded ones.
    public struct Refusal: Equatable, Sendable {
        /// The rule's name, as the diagnostics row prints it.
        public let rule: String
        /// The clause the reply puts after "Not tried on the device: ", with no
        /// terminating full stop — the renderer adds it.
        public let because: String

        public init(rule: String, because: String) {
            self.rule = rule
            self.because = because
        }

        static let empty = Refusal(rule: "empty", because: "it is empty")
        static let noWords = Refusal(rule: "no words",
                                     because: "it has no words to look up")
        static let tooLong = Refusal(rule: "too long",
                                     because: "it is longer than a lookup")

        static let notAQuestion = Refusal(rule: "not a question",
                                          because: "it is not a question")

        static func request(_ verb: RequestVerb) -> Refusal {
            Refusal(rule: "request verb: \(verb.verb)", because: verb.because)
        }
    }

    /// What the rules decided.
    public enum RuleVerdict: Equatable, Sendable {
        /// Not a lookup, for this reason.
        case refused(Refusal)
        /// A lookup. There is no second opinion to ask.
        case passed
    }

    /// The whole gate. Pure, deterministic, and the same on a device with no model as on
    /// one with a warm session.
    public static func rule(_ question: String) -> RuleVerdict {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(.empty) }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        // A PASTED LINK is the common case here, and it is a send rather than a
        // question: nothing in a URL is a word the index holds, so retrieval would
        // return either nothing or whatever happens to share a slug with it. The same
        // guard catches a bare number, an emoji, or a stray punctuation mark.
        guard trimmed.contains(where: \.isLetter), !isSingleURL(words) else {
            return .refused(.noWords)
        }
        if words.count > maxWords {
            return .refused(.tooLong)
        }
        // THE VERB RULE RUNS FIRST, and that order is the point: "it asks to track
        // something" tells the reader what happens next, and "it is not a question" does
        // not. Both refuse the same sentence; the verb's own reason wins.
        for word in words {
            if let verb = requestVerb(in: word) {
                return .refused(.request(verb))
            }
        }
        guard readsAsAQuestion(trimmed, words: words) else {
            return .refused(.notAQuestion)
        }
        return .passed
    }

    /// Whether this text asks something.
    ///
    /// Two ways to qualify and no third: it ENDS with a question mark, or its FIRST word is
    /// an interrogative. "Aurora?" has only the first, "when is the concert" only the
    /// second, and "the kiln reached 1240 this morning" has neither.
    static func readsAsAQuestion(_ trimmed: String, words: [some StringProtocol]) -> Bool {
        if trimmed.hasSuffix("?") { return true }
        guard let first = words.first else { return false }
        return interrogatives.contains(firstWordStem(first))
    }

    /// The first word as the interrogative list spells it: lowercased, stripped of
    /// surrounding punctuation, and cut at an apostrophe so "What's" is "what".
    static func firstWordStem(_ word: some StringProtocol) -> String {
        let cleaned = word.lowercased()
            .trimmingCharacters(in: CharacterSet.letters.inverted)
        guard let cut = cleaned.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) else {
            return cleaned
        }
        return String(cleaned[cleaned.startIndex..<cut])
    }

    /// Whether this send is a lookup at all.
    public static func isLookup(_ question: String) -> Bool {
        rule(question) == .passed
    }

    /// Whether the whole text is one bare link.
    ///
    /// Deliberately narrow: only a lone token with a scheme or a `www.` prefix. "where
    /// is the router at 192.168.1.1" is a question about a note and must not be caught,
    /// and neither must a one-word question like "Aurora?".
    static func isSingleURL(_ words: [some StringProtocol]) -> Bool {
        guard words.count == 1, let only = words.first?.lowercased() else { return false }
        return only.hasPrefix("http://") || only.hasPrefix("https://")
            || only.hasPrefix("www.")
    }

    /// The request verb a single word carries, or nil.
    ///
    /// Matched on the WORD, never on a substring of the question: "when is the plan
    /// meeting" has to be refused (it contains `plan` as a word), but "what is the
    /// airplane's tail number" must not be, and a substring test cannot tell those
    /// apart. Common inflections count — "drafting", "summarised", "compares" are the
    /// same request — because a gate that a gerund walks straight through is not a
    /// gate.
    static func requestVerb(in word: some StringProtocol) -> RequestVerb? {
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }
        for verb in requestVerbs where inflections(of: verb.verb).contains(cleaned) {
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
}
