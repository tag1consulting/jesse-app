import XCTest
@testable import Jesse

@MainActor
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

    // MARK: - Multi-token, order-independent, gap-independent matching (Tier 1)

    /// "run bridge" must find a body that says "run over the bridge" — the tokens
    /// appear in order but with a gap. The old contiguous-substring matcher fails
    /// this (there is no literal "run bridge" substring anywhere).
    func testMultiTokenMatchesAcrossGaps() {
        let t = thread(title: "Deploy notes", turns: [
            (.user, "how do I run over the bridge again?"),
        ])
        XCTAssertFalse(t.turns.contains { $0.text.localizedStandardContains("run bridge") },
                       "precondition: no contiguous 'run bridge' substring exists")
        XCTAssertTrue(threadMatches(t, query: "run bridge"))
    }

    /// Every token is required: a query token absent from the whole thread makes it
    /// NOT match, even when the other token is present.
    func testAllTokensRequired() {
        let t = thread(title: "Deploy notes", turns: [
            (.user, "how do I run over the bridge again?"),
        ])
        XCTAssertTrue(threadMatches(t, query: "run bridge"))
        // Drop-in a token the thread never mentions → no match.
        XCTAssertFalse(threadMatches(t, query: "run tunnel"))
    }

    /// Token order does not matter — "bridge run" matches the same thread as
    /// "run bridge".
    func testOrderIndependence() {
        let t = thread(title: "Deploy notes", turns: [
            (.user, "how do I run over the bridge again?"),
        ])
        XCTAssertTrue(threadMatches(t, query: "bridge run"))
    }

    /// Field-agnostic: one token may match in the title while another matches a turn
    /// body — they don't have to land in the same field.
    func testTokensMayMatchAcrossTitleAndBody() {
        let t = thread(title: "Roof repair", turns: [
            (.jesse, "The roofer is scheduled for Thursday morning."),
        ])
        // "roof" only in the title, "Thursday" only in a turn body.
        XCTAssertTrue(threadMatches(t, query: "roof thursday"))
    }

    /// Tokens shorter than 2 characters are ignored when a longer token is present,
    /// so a stray "a"/"I" doesn't over-constrain the match.
    func testShortTokensIgnoredWhenAnyLongTokenPresent() {
        let t = thread(title: "Deploy notes", turns: [
            (.user, "how do I run over the bridge again?"),
        ])
        // "x" is a 1-char token that appears nowhere; it must be dropped, leaving
        // "bridge" to match. (A contiguous matcher would look for the literal
        // "bridge x" and fail — this only holds once short tokens are ignored.)
        XCTAssertTrue(threadMatches(t, query: "bridge x"))
    }

    /// …UNLESS every token is short: then a deliberate short search like "hi" still
    /// works by falling back to the raw trimmed query.
    func testShortTokenFallbackWhenAllShort() {
        let t = thread(title: "Greeting", turns: [
            (.user, "hi there"),
        ])
        XCTAssertTrue(threadMatches(t, query: "hi"))
        // And a short query that matches nothing still doesn't match.
        XCTAssertFalse(threadMatches(t, query: "zz"))
    }

    // MARK: - Union predicate (Tier 2 widen point) + gating

    /// A thread that matches ONLY a non-first query entry is still matched by the
    /// union. This is the guard that a first-only implementation fails: the typed
    /// query "vacation" doesn't appear, but the expansion term "holiday" does.
    func testMatchesNonFirstQueryEntry() {
        let t = thread(title: "Trip", turns: [
            (.user, "planning a holiday in Sicily"),
        ])
        XCTAssertFalse(threadMatches(t, query: "vacation"),
                       "precondition: the typed query does not match on its own")
        XCTAssertTrue(threadMatchesAny(t, queries: ["vacation", "holiday"]),
                      "the union matches via the second (expansion) entry")
    }

    /// An empty list — or an all-blank list — means search is inactive: everything
    /// matches, preserving today's semantics.
    func testEmptyOrBlankQueryListMatchesAll() {
        let t = thread(title: "Anything", turns: [(.user, "some text")])
        XCTAssertTrue(threadMatchesAny(t, queries: []))
        XCTAssertTrue(threadMatchesAny(t, queries: ["", "   \n"]))
    }

    /// Each union entry is itself multi-token: an entry only matches when all ITS
    /// tokens are present, but any one matching entry admits the thread.
    func testUnionEntriesAreThemselvesMultiToken() {
        let t = thread(title: "Deploy notes", turns: [
            (.user, "how do I run over the bridge again?"),
        ])
        // Neither entry's tokens all appear... except the second.
        XCTAssertFalse(threadMatchesAny(t, queries: ["quarterly budget", "run tunnel"]))
        XCTAssertTrue(threadMatchesAny(t, queries: ["quarterly budget", "run bridge"]))
    }

    func testShouldExpandGating() {
        // Trivial (short) query: never expand, regardless of base count.
        XCTAssertFalse(shouldExpand(query: "hi", baseMatchCount: 0, threshold: 5))
        XCTAssertFalse(shouldExpand(query: "  a ", baseMatchCount: 0, threshold: 5))
        // Real word but plentiful base results: no need to widen.
        XCTAssertFalse(shouldExpand(query: "bridge", baseMatchCount: 5, threshold: 5))
        XCTAssertFalse(shouldExpand(query: "bridge", baseMatchCount: 9, threshold: 5))
        // Real word, thin/zero base: expand.
        XCTAssertTrue(shouldExpand(query: "bridge", baseMatchCount: 0, threshold: 5))
        XCTAssertTrue(shouldExpand(query: "bridge", baseMatchCount: 4, threshold: 5))
    }

    // MARK: - Graceful-degradation invariant (item 8)

    /// With expansion off/unavailable the query list is exactly [query], and the
    /// union predicate must reduce to the multi-token base matcher for EVERY thread
    /// — the visible set is identical to Tier-1-only.
    func testThreadMatchesAnySingleQueryEqualsThreadMatches() {
        let threads = [
            thread(title: "Roof repair", turns: [(.jesse, "roofer comes Thursday")]),
            thread(title: "Deploy notes", turns: [(.user, "run over the bridge")]),
            thread(title: "Trip notes", turns: [(.jesse, "a café in Málaga")]),
            thread(title: "Empty", turns: []),
        ]
        for q in ["", "  ", "roof", "run bridge", "bridge run", "cafe malaga",
                  "quarterly budget", "hi", "thursday roof"] {
            for t in threads {
                XCTAssertEqual(threadMatchesAny(t, queries: [q]),
                               threadMatches(t, query: q),
                               "single-entry union must equal the base matcher for query \(q)")
            }
        }
    }
}
