import XCTest
@testable import Jesse

/// A scripted, call-counting `QueryExpanding` fake (item 3) so the orchestration
/// model's gating / cache / cancellation are assertable without any real model.
@MainActor
final class FakeQueryExpander: QueryExpanding {
    /// Total `expand` invocations, and the queries in call order — the gating and
    /// cache assertions read these.
    private(set) var callCount = 0
    private(set) var calledQueries: [String] = []

    /// Terms returned per query (falls back to `defaultTerms` when unlisted).
    var termsByQuery: [String: [String]] = [:]
    var defaultTerms: [String] = ["alt-term"]

    func expand(_ query: String) async -> [String] {
        callCount += 1
        calledQueries.append(query)
        return termsByQuery[query] ?? defaultTerms
    }
}

@MainActor
final class ThreadSearchModelTests: XCTestCase {

    /// Fast, deterministic model: ~zero debounce unless a test needs the window.
    private func model(_ expander: FakeQueryExpander,
                       debounce: Duration = .zero,
                       threshold: Int = 5,
                       cacheCapacity: Int = 32) -> ThreadSearchModel {
        ThreadSearchModel(expander: expander, debounce: debounce,
                          threshold: threshold, cacheCapacity: cacheCapacity)
    }

    // MARK: - Gating

    func testPlentifulBaseDoesNotCallExpander() async {
        let fake = FakeQueryExpander()
        let m = model(fake)
        // Base results already plentiful (>= threshold): no need to widen.
        m.update(query: "bridge", baseMatchCount: 10)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 0, "plentiful base → no expander call")
        XCTAssertTrue(m.activeTerms.isEmpty)
    }

    func testTrivialQueryDoesNotCallExpander() async {
        let fake = FakeQueryExpander()
        let m = model(fake)
        m.update(query: "hi", baseMatchCount: 0)   // < 3 chars
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 0)
        XCTAssertTrue(m.activeTerms.isEmpty)
    }

    // MARK: - Thin base → one call, terms published

    func testThinBaseCallsExpanderOnceAndPublishesTerms() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["bridge": ["span", "overpass"]]
        let m = model(fake)
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(m.activeTerms, ["span", "overpass"])
    }

    // MARK: - Cache

    func testSameQueryTwiceCallsExpanderOnce() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["bridge": ["span"]]
        let m = model(fake)
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        // Repeat (or backspace-then-retype): normalized key is identical → cache hit.
        m.update(query: "  Bridge ", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 1, "a repeated query is expanded at most once")
        XCTAssertEqual(m.activeTerms, ["span"])
    }

    func testLRUCacheEvictsBeyondCapacity() async {
        let fake = FakeQueryExpander()
        let m = model(fake, cacheCapacity: 2)
        for q in ["cats", "dogs", "birds"] {          // 3 distinct, capacity 2
            m.update(query: q, baseMatchCount: 0)
            await m.awaitPendingExpansion()
        }
        XCTAssertEqual(fake.callCount, 3)
        // "cats" was the least-recently-used and is evicted → re-querying it calls
        // the expander again; "birds" (most recent) is still cached.
        m.update(query: "cats", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 4, "evicted query is re-expanded")
        m.update(query: "birds", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 4, "still-cached query is not re-expanded")
    }

    // MARK: - Cancellation (stale terms never applied)

    func testQueryChangeMidFlightDropsStaleTerms() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["cat": ["feline"], "dog": ["canine"]]
        // A real debounce window so the first query is still pending when the
        // second arrives; the change must cancel the first before it calls out.
        let m = model(fake, debounce: .milliseconds(200))
        m.update(query: "cat", baseMatchCount: 0)
        m.update(query: "dog", baseMatchCount: 0)   // supersedes "cat" mid-flight
        await m.awaitPendingExpansion()
        XCTAssertEqual(m.activeTerms, ["canine"], "only the current query's terms apply")
        XCTAssertEqual(fake.calledQueries, ["dog"],
                       "the superseded query's expansion was cancelled before calling out")
    }

    // MARK: - Empty expansion (dry model) degrades cleanly

    func testEmptyExpansionPublishesEmptyWithoutCrash() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["bridge": []]
        let m = model(fake)
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertTrue(m.activeTerms.isEmpty, "an empty expansion publishes no terms")
    }

    // MARK: - Clearing the query resets published terms

    func testClearingQueryEmptiesTerms() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["bridge": ["span"]]
        let m = model(fake)
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(m.activeTerms, ["span"])
        m.update(query: "", baseMatchCount: 0)      // query cleared
        await m.awaitPendingExpansion()
        XCTAssertTrue(m.activeTerms.isEmpty, "clearing the query clears the alternate terms")
    }

    // MARK: - Master off switch (item 9)

    func testDisabledTierMakesNoExpanderCallsRegardlessOfBaseCount() async {
        let fake = FakeQueryExpander()
        let m = model(fake)
        m.isEnabled = false
        // Thin base (would normally expand) and zero base — neither may call out.
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        m.update(query: "tunnel", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 0, "a disabled tier never calls the expander")
        XCTAssertTrue(m.activeTerms.isEmpty)
    }

    func testTogglingOffClearsPublishedTerms() async {
        let fake = FakeQueryExpander()
        fake.termsByQuery = ["bridge": ["span"]]
        let m = model(fake)
        m.update(query: "bridge", baseMatchCount: 0)
        await m.awaitPendingExpansion()
        XCTAssertEqual(m.activeTerms, ["span"])
        m.isEnabled = false
        XCTAssertTrue(m.activeTerms.isEmpty, "turning the tier off clears active terms at once")
    }
}
