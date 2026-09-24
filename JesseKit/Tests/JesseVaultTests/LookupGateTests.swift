import XCTest
@testable import JesseVault

/// The gate, which is now rules and only rules.
///
/// Every assertion is about a REFUSAL being reliable AND about an ordinary question
/// getting through, and the second half is the half this file used to be missing. The
/// three questions measured on the phone in airplane mode are in here by name: the
/// model tier refused the first of them and answered the third, from the same vault, in
/// the same minute, which is what a deterministic gate exists to make impossible.
final class LookupGateTests: XCTestCase {

    // MARK: - What passes

    /// The three questions measured on the device. All three must reach the vault: two
    /// have an answer there and one does not, and telling those apart is the answerer's
    /// job, not the gate's.
    func testTheThreeMeasuredQuestionsAllPass() {
        for question in ["What is Aurora's birthday?",
                         "When was I born?",
                         "What's my favorite cheese?"] {
            XCTAssertEqual(LookupGate.rule(question), .passed, question)
            XCTAssertTrue(LookupGate.isLookup(question), question)
        }
    }

    func testAnOrdinaryLookupPasses() {
        XCTAssertEqual(LookupGate.rule("when is the school concert"), .passed)
        XCTAssertEqual(LookupGate.rule("what did we decide about the fiber contract"),
                       .passed)
        XCTAssertEqual(LookupGate.rule("Aurora?"), .passed)
    }

    /// The reason the match is on WORDS. A substring test would refuse these, and they
    /// are perfectly ordinary lookups.
    func testAVerbInsideAnotherWordIsNotAVerb() {
        XCTAssertEqual(LookupGate.rule("what is the airplane tail number"), .passed)
        XCTAssertEqual(LookupGate.rule("where is the emailbox key"), .passed)
    }

    /// A question about an address is a question. Only a LONE link is refused.
    func testAQuestionContainingAnAddressIsStillAQuestion() {
        XCTAssertEqual(LookupGate.rule("what is the router login at 192.168.1.1"), .passed)
        XCTAssertEqual(LookupGate.rule("is https://terrasole.example the right site"),
                       .passed)
    }

    // MARK: - What the rules refuse

    func testEmptyQuestionIsRefused() {
        XCTAssertEqual(LookupGate.rule(""), .refused(.empty))
        XCTAssertEqual(LookupGate.rule("   \n\t "), .refused(.empty))
        XCTAssertEqual(LookupGate.Refusal.empty.because, "it is empty")
    }

    /// The rule this prompt added: a bare link, and anything with no letters in it at
    /// all, is a send rather than a question.
    func testALoneLinkOrTextWithNoLettersIsRefused() {
        XCTAssertEqual(LookupGate.rule("https://terrasole.example/bricks"),
                       .refused(.noWords))
        XCTAssertEqual(LookupGate.rule("  www.terrasole.example  "), .refused(.noWords))
        XCTAssertEqual(LookupGate.rule("42"), .refused(.noWords))
        XCTAssertEqual(LookupGate.rule("???"), .refused(.noWords))
        XCTAssertEqual(LookupGate.Refusal.noWords.because, "it has no words to look up")
    }

    func testQuestionLongerThanFortyWordsIsRefused() {
        let forty = Array(repeating: "word", count: 40).joined(separator: " ")
        XCTAssertEqual(LookupGate.rule(forty), .passed,
                       "exactly forty words is still a question")
        let fortyOne = Array(repeating: "word", count: 41).joined(separator: " ")
        XCTAssertEqual(LookupGate.rule(fortyOne), .refused(.tooLong))
        XCTAssertEqual(LookupGate.Refusal.tooLong.because, "it is longer than a lookup")
    }

    /// EVERY verb, individually. A list like this is the kind that grows a typo and loses
    /// one entry silently.
    func testEveryRequestVerbIsRefusedAndCarriesItsOwnClause() {
        for verb in LookupGate.requestVerbs {
            XCTAssertEqual(LookupGate.rule("please \(verb.verb) the thing for me"),
                           .refused(.request(verb)),
                           "\(verb.verb) should refuse")
            XCTAssertTrue(verb.because.hasPrefix("it asks "),
                          "\(verb.verb): '\(verb.because)' must read as a reason")
        }
        XCTAssertEqual(LookupGate.requestVerbs.count, 13,
                       "the list is the contract; a change here is a behaviour change")
    }

    /// The device checklist's own sentence, end to end: this exact question must refuse
    /// with this exact clause, because the reply body quotes it verbatim.
    func testTheDraftQuestionRefusesWithTheClauseTheReplyShows() {
        let verdict = LookupGate.rule("Draft an email to Jamie about the school concert")
        guard case .refused(let refusal) = verdict else {
            return XCTFail("a draft request must be refused")
        }
        XCTAssertEqual(refusal.because, "it asks for a draft")
        XCTAssertEqual(refusal.rule, "request verb: draft")
    }

    func testInflectionsOfARequestVerbAreRefused() {
        for question in ["drafting the note about bricks",
                         "summarised the kiln thread",
                         "compares the two quotes",
                         "writing to Marta"] {
            XCTAssertNotEqual(LookupGate.rule(question), .passed, question)
        }
    }

    func testPunctuationAroundAVerbStillCounts() {
        XCTAssertNotEqual(LookupGate.rule("can you (draft) something"), .passed)
        XCTAssertNotEqual(LookupGate.rule("plan, then tell me"), .passed)
    }

    // MARK: - What a refusal is for

    /// Two registers, never one: the diagnostics row prints `rule`, the transcript
    /// prints `because`, and a refusal that filled only one of them would leave one
    /// reader with nothing.
    func testEveryRefusalNamesItsRuleAndItsReason() {
        let refusals = [LookupGate.rule(""),
                        LookupGate.rule("https://example.test"),
                        LookupGate.rule(Array(repeating: "word", count: 41)
                            .joined(separator: " ")),
                        LookupGate.rule("draft it")]
        for verdict in refusals {
            guard case .refused(let refusal) = verdict else {
                return XCTFail("expected a refusal, got \(verdict)")
            }
            XCTAssertFalse(refusal.rule.isEmpty)
            XCTAssertFalse(refusal.because.isEmpty)
            XCTAssertFalse(refusal.because.hasSuffix("."),
                           "the renderer adds the full stop")
        }
    }
}
