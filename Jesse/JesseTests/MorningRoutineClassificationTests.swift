import XCTest
import JesseCore
@testable import Jesse

/// The Chats "Good morning" prompt, seen by the iOS health-context classifier.
///
/// The prompt's own wording is pinned in `JesseCoreTests/MorningRoutineTests`. What is
/// only true on iOS is this: a Tell turn whose text reads as health-related gets this
/// morning's weigh-in block attached before it goes out. The morning routine's health
/// check-in wants that block, and neither body asks for it explicitly — both simply
/// happen to clear the keyword floor.
///
/// WHAT BREAKS IF THIS GOES FALSE. Nothing crashes and no test but this one fails. The
/// turn goes out without the weigh-in, the agent reaches the health part of the
/// briefing with no data, and it either answers from yesterday's numbers or spends a
/// round trip asking for them (`JESSE_NEEDS_HEALTH`) — a silently worse morning, from a
/// reword that looked purely editorial. The words carrying it are "health" in both
/// bodies, plus "log" and "weigh" in the opt-in one.
final class MorningRoutineClassificationTests: XCTestCase {

    /// Any Monday; the date is not what the classifier reads.
    private let instant = Date(timeIntervalSince1970: 1_786_343_400)

    func testTheDefaultBodyClassifiesAsHealthRelated() {
        let prompt = MorningRoutine.prompt(now: instant)
        XCTAssertTrue(HealthKeywordClassifier.matches(prompt),
                      "the weigh-in block must still attach to the plain start-of-day turn")
    }

    func testTheOptInBodyClassifiesAsHealthRelated() {
        let prompt = MorningRoutine.prompt(now: instant, includeHealthNewDay: true)
        XCTAssertTrue(HealthKeywordClassifier.matches(prompt),
                      "the body that ASKS for the weigh-in must be sent the weigh-in")
    }
}
