import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// **The one rule that decides whether a captured change survives the night.**
//
// It is deliberately narrow, and these tests are mostly about what it REFUSES. A loose
// match writes a completion into the vault about work nobody did; a strict one costs a
// re-tap and says so. Only the three things a morning rebuild actually does to the words
// are normalized away.

final class TodayLeadMatchTests: XCTestCase {

    // MARK: - What is normalized away

    /// Case. The routine re-cases leads when a carried item starts a line it did not
    /// start yesterday, and case has never told two real tasks apart.
    func testCaseIsIgnored() {
        XCTAssertTrue(TodayLeadMatch.matches("Reply to Ada", "reply to ada"))
    }

    /// Whitespace runs. A rebuild re-wraps, and a lead lifted from a re-wrapped line
    /// differs from yesterday's by a space.
    func testWhitespaceRunsCollapse() {
        XCTAssertTrue(TodayLeadMatch.matches("Reply  to\tAda", "Reply to Ada"))
        XCTAssertTrue(TodayLeadMatch.matches("  Reply to Ada  ", "Reply to Ada"))
    }

    /// A trailing `(Added …)` trailer is bookkeeping the routine rewrites, not part of
    /// what the task says.
    func testATrailingAddedTrailerIsStripped() {
        XCTAssertTrue(TodayLeadMatch.matches(
            "Order the thermocouple. (Added 2026-03-01)",
            "Order the thermocouple."))
        XCTAssertTrue(TodayLeadMatch.matches(
            "Order the thermocouple. (Added 2026-03-01, updated 2026-03-03)",
            "Order the thermocouple. (Added 2026-03-04)"))
    }

    /// Only the LAST parenthetical, and only when it is the bookkeeping one. A
    /// parenthetical inside the sentence is what the task says, and losing it would make
    /// two different tasks look alike.
    func testAParentheticalThatIsPartOfTheTaskSurvives() {
        XCTAssertEqual(
            TodayLeadMatch.strippingAddedTrailer("Order the part (TC-4417) (Added 2026-03-01)"),
            "Order the part (TC-4417)")
        XCTAssertFalse(TodayLeadMatch.matches("Order the part (TC-4417)",
                                              "Order the part (TC-9999)"))
        // Not an `Added` trailer, so it stays.
        XCTAssertEqual(TodayLeadMatch.strippingAddedTrailer("Call Ada (about the kiln)"),
                       "Call Ada (about the kiln)")
    }

    // MARK: - What is not

    /// Everything else means "this is not the task I checked off".
    func testSubstantiveDifferencesDoNotMatch() {
        XCTAssertFalse(TodayLeadMatch.matches("Reply to Ada", "Reply to Ada about the kiln"))
        XCTAssertFalse(TodayLeadMatch.matches("Reply to Ada", "Reply to Bea"))
        XCTAssertFalse(TodayLeadMatch.matches("Reply to Ada.", "Reply to Ada"))
    }

    /// **An empty lead matches nothing, ever.** The day file legitimately holds `* [ ]`
    /// — a checkbox with no words — and every one of them would otherwise match every
    /// other one, which is a mis-tick waiting to happen on the emptiest possible
    /// evidence.
    func testAnEmptyLeadMatchesNothing() {
        XCTAssertFalse(TodayLeadMatch.matches("", ""))
        XCTAssertFalse(TodayLeadMatch.matches("   ", ""))
        XCTAssertFalse(TodayLeadMatch.matches("", "Reply to Ada"))
    }

    // MARK: - Resolving against a day

    /// The happy path: one open item with those words.
    func testResolveFindsTheOneOpenMatch() {
        let snapshot = Fixt.snapshot()
        let found = TodayLeadMatch.resolve(lead: "Reply to Ada about the firing schedule.",
                                           in: snapshot)
        XCTAssertEqual(found?.id, Fixt.ada)
    }

    /// A DONE item is not a candidate. Re-ticking it would rewrite its `app-completed`
    /// stamp to the replay's time, overwriting a true record with a second one.
    func testResolveIgnoresItemsThatAreAlreadyDone() {
        let snapshot = Fixt.snapshot()
        // "Return the borrowed clamps." is checked in the fixture.
        XCTAssertNil(TodayLeadMatch.resolve(lead: "Return the borrowed clamps.", in: snapshot))
    }

    /// Two open items with the same words are indistinguishable to this rule, so it
    /// picks neither.
    func testResolveRefusesAnAmbiguousMatch() {
        var snapshot = Fixt.snapshot()
        snapshot.sections[1].items.append(
            Fixt.item("ffff11112222", lead: "Reply to Ada about the firing schedule.",
                      section: "Errands"))
        XCTAssertNil(TodayLeadMatch.resolve(lead: "Reply to Ada about the firing schedule.",
                                            in: snapshot))
    }

    /// It searches the WHOLE day, lead block included — a task carried into the standing
    /// slot is still the same task.
    func testResolveSearchesTheLeadBlockToo() {
        let snapshot = Fixt.snapshot()
        let found = TodayLeadMatch.resolve(lead: "top priority: finish the kiln rebuild",
                                           in: snapshot)
        XCTAssertEqual(found?.id, Fixt.standing)
    }
}
