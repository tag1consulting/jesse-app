import XCTest
@testable import Jesse

/// The classify-then-attach floor: the keyword tier (pure, word-boundary aware),
/// the union of the two tiers, and the pure gate. The on-device model tier is
/// unavailable in the Simulator, so the union is tested through injected closures.
final class HealthRelevanceClassifierTests: XCTestCase {

    // MARK: - Tier 0 keyword floor

    func testKeywordHits() {
        let hits = [
            "log my swim", "I swam 1500m", "went for a run", "ran 5k this morning",
            "long walk", "hiked the ridge", "did a workout", "strength training today",
            "slept badly", "took a nap", "weighed in at 80", "check my weight",
            "what did I eat", "lunch was heavy", "protein intake", "how many calories",
            "my resting heart rate", "HRV trend", "step count", "am I recovered",
            "VO2 max", "feeling sore", "pretty tired", "is today a rest day",
        ]
        for text in hits {
            XCTAssertTrue(HealthKeywordClassifier.matches(text), "should fire: \(text)")
        }
    }

    func testKeywordMisses() {
        let misses = [
            "summarize my inbox", "what's on Today.md", "reply to that email",
            "book a flight to Berlin", "the meeting notes", "who is on call",
            // word-boundary: substrings must NOT fire a keyword
            "brunch plans",            // contains "run"? no — whole-word only
            "restaurant reservation",  // contains "rest" — must not fire
            "the rest of the report",  // bare "rest" is not a trigger (only "rest day")
            "a heartfelt note",        // contains "heart" as a substring of "heartfelt"
        ]
        for text in misses {
            XCTAssertFalse(HealthKeywordClassifier.matches(text), "should NOT fire: \(text)")
        }
    }

    func testKeywordIsCaseInsensitive() {
        XCTAssertTrue(HealthKeywordClassifier.matches("LOG MY SWIM"))
        XCTAssertTrue(HealthKeywordClassifier.matches("Hrv looks off"))
    }

    // MARK: - Gate (pure)

    func testGateOffNeverAttaches() {
        XCTAssertFalse(HealthContextGate.shouldAttach(enabled: false, relevant: true))
        XCTAssertFalse(HealthContextGate.shouldAttach(enabled: false, relevant: false))
    }

    func testGateOnDefersToRelevance() {
        XCTAssertTrue(HealthContextGate.shouldAttach(enabled: true, relevant: true))
        XCTAssertFalse(HealthContextGate.shouldAttach(enabled: true, relevant: false))
    }

    // MARK: - Union of the two tiers

    func testUnionKeywordHitShortCircuitsModel() async {
        var modelCalled = false
        let union = UnionHealthClassifier(
            keyword: { _ in true },
            model: { _ in modelCalled = true; return false })
        let relevant = await union.isRelevant("log my swim")
        XCTAssertTrue(relevant)
        XCTAssertFalse(modelCalled, "a Tier 0 hit must not consult the model")
    }

    func testUnionModelSaysYesWhenKeywordMisses() async {
        let union = UnionHealthClassifier(keyword: { _ in false }, model: { _ in true })
        let relevant = await union.isRelevant("am I overdoing it this week?")
        XCTAssertTrue(relevant, "Tier 1 yes attaches even when Tier 0 misses")
    }

    func testUnionModelUnavailableLeavesTier0Answer() async {
        // Model returns nil (unavailable / timeout / error) → Tier 0's "no" stands.
        let union = UnionHealthClassifier(keyword: { _ in false }, model: { _ in nil })
        let relevant = await union.isRelevant("book a flight")
        XCTAssertFalse(relevant)
    }

    func testUnionModelTimeoutDoesNotOverrideTier0Yes() async {
        // Tier 0 yes short-circuits, so a slow/failed model is irrelevant.
        let union = UnionHealthClassifier(keyword: { _ in true }, model: { _ in nil })
        let relevant = await union.isRelevant("logged a swim")
        XCTAssertTrue(relevant)
    }
}
