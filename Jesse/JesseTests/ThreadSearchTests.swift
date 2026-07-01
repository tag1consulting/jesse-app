import XCTest
@testable import Jesse

final class ThreadSearchTests: XCTestCase {

    /// Build an in-memory thread (no SwiftData container needed) with a title
    /// and a list of (role, text) turns.
    private func thread(title: String, turns: [(TurnRole, String)]) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        return t
    }

    func testMatchesTitle() {
        let t = thread(title: "Roof repair schedule", turns: [])
        XCTAssertTrue(threadMatches(t, query: "roof"))
        XCTAssertTrue(threadMatches(t, query: "SCHEDULE"))
    }

    func testMatchesWordOnlyInTurnBodyNotTitle() {
        // The title says nothing about "Thursday"; only a turn body does. A
        // title-only predicate fails this — it's the turn-body regression guard.
        let t = thread(title: "Roof repair", turns: [
            (.user, "when is the roofer coming?"),
            (.jesse, "The roofer is scheduled for Thursday morning."),
        ])
        XCTAssertFalse(t.title.localizedStandardContains("Thursday"),
                       "precondition: the match word must not be in the title")
        XCTAssertTrue(threadMatches(t, query: "Thursday"))
    }

    func testCaseAndDiacriticInsensitive() {
        let t = thread(title: "Trip notes", turns: [
            (.jesse, "We stopped at a café in Málaga."),
        ])
        XCTAssertTrue(threadMatches(t, query: "cafe"))
        XCTAssertTrue(threadMatches(t, query: "MALAGA"))
    }

    func testEmptyOrWhitespaceQueryMatchesEverything() {
        let t = thread(title: "Anything", turns: [(.user, "some text")])
        XCTAssertTrue(threadMatches(t, query: ""))
        XCTAssertTrue(threadMatches(t, query: "   \n\t "))
    }

    func testNoMatchReturnsFalse() {
        let t = thread(title: "Roof repair", turns: [
            (.jesse, "The roofer is scheduled for Thursday."),
        ])
        XCTAssertFalse(threadMatches(t, query: "quarterly budget"))
    }
}
