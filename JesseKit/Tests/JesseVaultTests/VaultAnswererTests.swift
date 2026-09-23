import XCTest
@testable import JesseVault

// The three checks that stand between a 3B model and the transcript, plus the clock.
//
// Everything here runs against a scripted generator. The real model is never called from
// a test — it is unavailable in CI and on most simulators, and a test that only passes on
// one laptop is not a test.

/// A generator that answers from a script, counts its calls, and can be told to fail.
private final class ScriptedGenerator: VaultAnswerGenerating, @unchecked Sendable {
    enum Behaviour {
        case draft(VaultAnswerDraft)
        case throwing(VaultAnswerGenerationError)
        /// Refuse the first call for size, then answer.
        case contextWindowThenDraft(VaultAnswerDraft)
        /// Never return.
        case hang
    }

    let behaviour: Behaviour
    var available = true
    private let lock = NSLock()
    private(set) var calls: [[RetrievedChunk]] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var isAvailable: Bool { available }

    func generate(question: String, chunks: [RetrievedChunk]) async throws -> VaultAnswerDraft {
        let index: Int = lock.withLock {
            calls.append(chunks)
            return calls.count - 1
        }
        switch behaviour {
        case .draft(let draft):
            return draft
        case .throwing(let error):
            throw error
        case .contextWindowThenDraft(let draft):
            if index == 0 { throw VaultAnswerGenerationError.contextWindow }
            return draft
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw VaultAnswerGenerationError.failed("never")
        }
    }
}

final class VaultAnswererTests: XCTestCase {

    private func chunk(_ path: String, line: Int = 1, text: String = "body") -> RetrievedChunk {
        RetrievedChunk(path: path, line: line, title: path, heading: "", text: text)
    }

    /// REAL-LOOKING extract text, not a placeholder, because validation now checks that
    /// the answer shares a word with what it cites — so a fixture of `"body"` would make
    /// every grounded answer fail for the wrong reason.
    private var chunks: [RetrievedChunk] {
        [chunk("Family/School-Year.md", line: 7,
               text: "The spring concert is on Thursday 14 May at 18:30 in the school hall."),
         chunk("Family/Birthdays.md", line: 3,
               text: "Marta's birthday is 3 February. Alberto's is 19 September."),
         chunk("House/Boiler.md", line: 2,
               text: "The boiler service is booked for 8 October."),
         chunk("Workshop/Glazes.md", line: 5,
               text: "Tenmoku is fired to cone ten in reduction.")]
    }

    // MARK: - Validation

    func testAValidAnswerKeepsItsCitationAndTheLineToOpenItAt() {
        let draft = VaultAnswerDraft(answer: "Thursday 14 May at 18:30.",
                                     citations: ["Family/School-Year.md"], abstain: false)
        guard case .answered(let answer) = VaultAnswerer.validate(draft, chunks: chunks) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer.text, "Thursday 14 May at 18:30.")
        XCTAssertEqual(answer.citations,
                       [VaultCitation(path: "Family/School-Year.md", line: 7)])
    }

    /// An invented path is DROPPED. Not surfaced, not corrected, not guessed at.
    func testACitationThatWasNeverSuppliedIsDropped() {
        let draft = VaultAnswerDraft(
            answer: "Thursday.",
            citations: ["Family/School-Year.md", "Family/Concerts-2026.md"],
            abstain: false)
        guard case .answered(let answer) = VaultAnswerer.validate(draft, chunks: chunks) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer.citations.map(\.path), ["Family/School-Year.md"])
    }

    /// THE CHECK THIS FILE EXISTS FOR. An answer whose every citation was invented has no
    /// evidence at all, and becomes a visible "not found" rather than a plausible lie.
    func testAnAnswerWithNoValidCitationBecomesAnAbstain() {
        let draft = VaultAnswerDraft(answer: "Thursday 14 May, definitely.",
                                     citations: ["Family/Concerts-2026.md"], abstain: false)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: chunks),
                       .unanswered(.abstained))
    }

    func testAnEmptyCitationListIsAnAbstain() {
        let draft = VaultAnswerDraft(answer: "Thursday.", citations: [], abstain: false)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: chunks),
                       .unanswered(.abstained))
    }

    func testTheAbstainFlagWinsOverAnyText() {
        let draft = VaultAnswerDraft(answer: "Possibly Thursday.",
                                     citations: ["Family/School-Year.md"], abstain: true)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: chunks),
                       .unanswered(.abstained))
    }

    func testAnEmptyAnswerIsAnAbstain() {
        let draft = VaultAnswerDraft(answer: "   \n ",
                                     citations: ["Family/School-Year.md"], abstain: false)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: chunks),
                       .unanswered(.abstained))
    }

    func testDuplicateCitationsCollapseAndFourIsTheCeiling() {
        let draft = VaultAnswerDraft(
            answer: "Concert Thursday, birthday February, boiler October, tenmoku cone ten.",
            citations: ["Family/School-Year.md", "Family/School-Year.md",
                        "Family/Birthdays.md", "House/Boiler.md", "Workshop/Glazes.md",
                        "Family/School-Year.md"],
            abstain: false)
        guard case .answered(let answer) = VaultAnswerer.validate(draft, chunks: chunks) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer.citations.count, 4)
        XCTAssertEqual(Set(answer.citations.map(\.path)).count, 4)
    }

    /// A model that copies the `NOTE path:line` header back has still cited a real file.
    /// Tidying that is not leniency: the result is still matched exactly.
    func testACitationCopiedBackWithItsHeaderStillMatches() {
        XCTAssertEqual(VaultAnswerer.normalizeCitation("NOTE Family/School-Year.md:7"),
                       "Family/School-Year.md")
        XCTAssertEqual(VaultAnswerer.normalizeCitation("  [Family/School-Year.md]  "),
                       "Family/School-Year.md")
        XCTAssertEqual(VaultAnswerer.normalizeCitation("\"Family/School-Year.md\""),
                       "Family/School-Year.md")
        // …and a colon that is part of a name is not a line number.
        XCTAssertEqual(VaultAnswerer.normalizeCitation("Notes/Re: bricks.md"),
                       "Notes/Re: bricks.md")
    }

    // MARK: - Grounding

    /// MEASURED, not anticipated. Asked "what colour is the studio door" over notes that
    /// never mention a door, the on-device model answered "white" and cited the studio
    /// note it had been handed — a REAL path, so the citation check passed it. This is
    /// the check that turns that into an abstain.
    func testAnAnswerSharingNoWordWithWhatItCitesIsAnAbstain() {
        let rent = chunk("Workshop/Studio-Rent.md", line: 1,
                         text: "The studio rent is 340 euro a month, paid on the first.")
        let draft = VaultAnswerDraft(answer: "white",
                                     citations: ["Workshop/Studio-Rent.md"], abstain: false)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: [rent]),
                       .unanswered(.abstained))
    }

    func testAnExtractiveAnswerIsGrounded() {
        let rent = chunk("Workshop/Studio-Rent.md", line: 1,
                         text: "The studio rent is 340 euro a month, paid on the first.")
        let draft = VaultAnswerDraft(answer: "340 euro a month.",
                                     citations: ["Workshop/Studio-Rent.md"], abstain: false)
        XCTAssertNotNil(VaultAnswerer.validate(draft, chunks: [rent]).answer)
    }

    /// A bare affirmation has nothing in it to check, and reads as sourced when it is not.
    func testAnAnswerWithNoSignificantWordsIsNotGrounded() {
        let rent = chunk("Workshop/Studio-Rent.md", line: 1,
                         text: "The studio rent is 340 euro a month.")
        XCTAssertFalse(VaultAnswerer.isGrounded("yes, it is", in: [rent]))
        XCTAssertFalse(VaultAnswerer.isGrounded("", in: [rent]))
        XCTAssertFalse(VaultAnswerer.isGrounded("340", in: []))
    }

    /// Grounding is checked against the CITED extracts only. A word that appears in some
    /// other retrieved note is not evidence for the note the answer names.
    func testGroundingIsCheckedAgainstTheCitedExtractOnly() {
        let rent = chunk("Workshop/Studio-Rent.md", line: 1,
                         text: "The studio rent is 340 euro a month.")
        let glazes = chunk("Workshop/Glazes.md", line: 3,
                           text: "Tenmoku is fired to cone ten in reduction.")
        let draft = VaultAnswerDraft(answer: "Tenmoku, cone ten.",
                                     citations: ["Workshop/Studio-Rent.md"], abstain: false)
        XCTAssertEqual(VaultAnswerer.validate(draft, chunks: [rent, glazes]),
                       .unanswered(.abstained))
    }

    /// The second measured failure: asked "what is the name of the kiln repair company in
    /// Florence" over a vault that has no such thing, the model answered "Kiln repair
    /// company in Florence" and cited the kiln note. Every word of it IS in the extract,
    /// so the extract check alone passed it — and it had answered nothing.
    func testAnAnswerMadeOnlyOfTheQuestionsOwnWordsIsAnAbstain() {
        let kiln = chunk("Workshop/Kiln-Rebuild.md", line: 5,
                         text: "The kiln repair company quoted for forty soft bricks.")
        let draft = VaultAnswerDraft(answer: "Kiln repair company in Florence",
                                     citations: ["Workshop/Kiln-Rebuild.md"], abstain: false)
        XCTAssertEqual(
            VaultAnswerer.validate(
                draft, chunks: [kiln],
                question: "what is the name of the kiln repair company in Florence"),
            .unanswered(.abstained))
        // …and the same answer to a question that did NOT already contain those words is
        // a perfectly good one.
        XCTAssertNotNil(
            VaultAnswerer.validate(draft, chunks: [kiln],
                                   question: "who did the work").answer)
    }

    /// Case and diacritics fold, the same way the index's own tokenizer folds them.
    func testGroundingFoldsCaseAndDiacritics() {
        let cafe = chunk("Workshop/Cafe.md", line: 1, text: "The café tiles came from Terrasole.")
        XCTAssertTrue(VaultAnswerer.isGrounded("The cafe tiles.", in: [cafe]))
        XCTAssertTrue(VaultAnswerer.isGrounded("TERRASOLE", in: [cafe]))
    }

    // MARK: - The prompt

    func testThePromptIsTheQuestionAndTheNotesAndNothingElse() {
        let prompt = VaultAnswerer.prompt(question: "  when is the concert  ",
                                          chunks: [chunk("A.md", line: 4, text: "on Thursday")])
        XCTAssertEqual(prompt, "when is the concert\n\nNOTE A.md:4\non Thursday")
    }

    func testTheInstructionsAreShortEnoughForThisModel() {
        let words = VaultAnswerer.instructions.split(whereSeparator: \.isWhitespace)
        XCTAssertLessThanOrEqual(words.count, 60)
        XCTAssertTrue(VaultAnswerer.instructions.contains("Answer only from the notes given."))
        XCTAssertTrue(VaultAnswerer.instructions.contains("abstain"))
    }

    // MARK: - Orchestration

    func testAnUnavailableModelIsItsOwnOutcome() async {
        let generator = ScriptedGenerator(.draft(
            VaultAnswerDraft(answer: "x", citations: [], abstain: false)))
        generator.available = false
        let outcome = await VaultAnswerer(generator: generator)
            .answer(question: "q", chunks: chunks)
        XCTAssertEqual(outcome, .unanswered(.modelUnavailable))
        XCTAssertTrue(generator.calls.isEmpty, "an unavailable model is never called")
    }

    func testNoChunksIsNoHits() async {
        let generator = ScriptedGenerator(.draft(
            VaultAnswerDraft(answer: "x", citations: [], abstain: false)))
        let outcome = await VaultAnswerer(generator: generator)
            .answer(question: "q", chunks: [])
        XCTAssertEqual(outcome, .unanswered(.noHits))
        XCTAssertTrue(generator.calls.isEmpty)
    }

    /// The window retry: ONE more attempt, with half the chunks, and then no more.
    func testAContextWindowRefusalRetriesOnceWithHalfTheChunks() async {
        let draft = VaultAnswerDraft(answer: "Thursday.",
                                     citations: ["Family/School-Year.md"], abstain: false)
        let generator = ScriptedGenerator(.contextWindowThenDraft(draft))
        let outcome = await VaultAnswerer(generator: generator)
            .answer(question: "q", chunks: chunks)
        XCTAssertNotNil(outcome.answer)
        XCTAssertEqual(generator.calls.count, 2)
        XCTAssertEqual(generator.calls[0].count, 4)
        XCTAssertEqual(generator.calls[1].count, 2)
    }

    func testAContextWindowRefusalThatSurvivesTheRetryIsReported() async {
        let generator = ScriptedGenerator(.throwing(.contextWindow))
        let outcome = await VaultAnswerer(generator: generator)
            .answer(question: "q", chunks: chunks)
        XCTAssertEqual(outcome, .unanswered(.failed("prompt too large even halved")))
        XCTAssertEqual(generator.calls.count, 2, "one retry, not a loop")
    }

    func testAGenerationFailureCarriesItsReason() async {
        let generator = ScriptedGenerator(.throwing(.failed("the model declined")))
        let outcome = await VaultAnswerer(generator: generator)
            .answer(question: "q", chunks: chunks)
        XCTAssertEqual(outcome, .unanswered(.failed("the model declined")))
    }

    /// The clock. An abstain that arrives beats an answer that does not.
    func testAGenerationThatNeverReturnsTimesOut() async {
        let generator = ScriptedGenerator(.hang)
        let started = Date()
        let outcome = await VaultAnswerer(generator: generator, timeLimit: 0.15)
            .answer(question: "q", chunks: chunks)
        XCTAssertEqual(outcome, .unanswered(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the limit is a limit, not a suggestion")
    }

    func testTheShippedTimeLimitIsTwentySeconds() {
        XCTAssertEqual(VaultAnswerer.defaultTimeLimit, 20)
    }
}
