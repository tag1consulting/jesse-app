import XCTest
@testable import JesseVault

/// The gate's two tiers. Every assertion here is about a REFUSAL being reliable, because
/// a refusal costs one queued message and an admission costs a fabricated answer.
final class LookupGateTests: XCTestCase {

    // MARK: - The rule tier

    func testEmptyQuestionIsRefused() {
        XCTAssertEqual(LookupGate.rule(""), .refused("empty"))
        XCTAssertEqual(LookupGate.rule("   \n\t "), .refused("empty"))
    }

    func testAnOrdinaryLookupReachesTheModel() {
        XCTAssertEqual(LookupGate.rule("when is the school concert"), .undecided)
        XCTAssertEqual(LookupGate.rule("what did we decide about the fiber contract"),
                       .undecided)
    }

    func testQuestionLongerThanFortyWordsIsRefused() {
        let forty = Array(repeating: "word", count: 40).joined(separator: " ")
        XCTAssertEqual(LookupGate.rule(forty), .undecided,
                       "exactly forty words is still a question")
        let fortyOne = Array(repeating: "word", count: 41).joined(separator: " ")
        XCTAssertEqual(LookupGate.rule(fortyOne), .refused("longer than 40 words"))
    }

    /// EVERY verb, individually. A list like this is the kind that grows a typo and loses
    /// one entry silently.
    func testEveryRequestVerbIsRefused() {
        for verb in LookupGate.requestVerbs {
            XCTAssertEqual(LookupGate.rule("please \(verb) the thing for me"),
                           .refused("asks to \(verb)"),
                           "\(verb) should refuse")
        }
        XCTAssertEqual(LookupGate.requestVerbs.count, 13,
                       "the list is the contract; a change here is a behaviour change")
    }

    func testInflectionsOfARequestVerbAreRefused() {
        XCTAssertEqual(LookupGate.rule("drafting the note about bricks"),
                       .refused("asks to draft"))
        XCTAssertEqual(LookupGate.rule("summarised the kiln thread"),
                       .refused("asks to summarise"))
        XCTAssertEqual(LookupGate.rule("compares the two quotes"),
                       .refused("asks to compare"))
        XCTAssertEqual(LookupGate.rule("writing to Marta"), .refused("asks to write"))
    }

    /// The reason the match is on WORDS. A substring test would refuse this, and it is a
    /// perfectly ordinary lookup.
    func testAVerbInsideAnotherWordIsNotAVerb() {
        XCTAssertEqual(LookupGate.rule("what is the airplane tail number"), .undecided)
        XCTAssertEqual(LookupGate.rule("where is the emailbox key"), .undecided)
    }

    func testPunctuationAroundAVerbStillCounts() {
        XCTAssertEqual(LookupGate.rule("can you (draft) something"),
                       .refused("asks to draft"))
        XCTAssertEqual(LookupGate.rule("plan, then tell me"), .refused("asks to plan"))
    }

    // MARK: - The two tiers together

    func testRuleRefusalNeverReachesTheModel() async {
        // A classifier that would say yes to anything: the rules must win anyway.
        let saysYes = FixedLookupClassification(true)
        let verdict = await LookupGate.isLookup("draft me an email", classifier: saysYes)
        XCTAssertFalse(verdict)
    }

    func testTheModelDecidesWhatTheRulesDoNot() async {
        let question = "when is the school concert"
        let yes = await LookupGate.isLookup(question,
                                            classifier: FixedLookupClassification(true))
        let no = await LookupGate.isLookup(question,
                                           classifier: FixedLookupClassification(false))
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
    }

    /// A model failure IS a refusal — the whole point of `LookupClassifying` never
    /// throwing.
    func testAnAbsentModelRefuses() async {
        let verdict = await LookupGate.isLookup("when is the school concert",
                                                classifier: NoLookupClassification())
        XCTAssertFalse(verdict)
    }

    func testClassifierPromptCarriesTheQuestionAndTheYesNoFraming() {
        let prompt = LookupGate.classifierPrompt("  when is the concert  ")
        XCTAssertTrue(prompt.contains("one or two personal notes"))
        XCTAssertTrue(prompt.contains("Yes or no."))
        XCTAssertTrue(prompt.contains("Question: when is the concert"))
    }
}
