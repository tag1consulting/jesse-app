import XCTest
import JesseCore
import JesseConversations
import JesseSearch
@testable import Jesse_Mac

// Mac sidebar SEARCH wiring, not pixels: with a fake `QueryExpanding` injected,
// typing a query narrows the shared `threadListLayout` to the Tier-1 matches
// immediately, and once the on-device expansion terms arrive the layout WIDENS to
// include a thread surfaced only by an expansion term. The debounce/gate/cache
// behavior itself is covered once in JesseSearchTests; here we assert only the Mac
// model's union of typed query + `activeTerms` and that it feeds the same layout.
@MainActor
final class MacThreadSearchTests: XCTestCase {

    /// A scripted fake so the test never depends on a real on-device model (which is
    /// unavailable in CI). `@MainActor` to satisfy the main-actor-isolated seam.
    final class FakeExpander: QueryExpanding {
        var termsByQuery: [String: [String]] = [:]
        private(set) var callCount = 0
        func expand(_ query: String) async -> [String] {
            callCount += 1
            return termsByQuery[query.lowercased()] ?? []
        }
    }

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 12))! }

    private func thread(_ title: String) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.updatedAt = now   // same day, so all land in a loose (always-expanded) section
        return t
    }

    private func memberIDs(_ layout: ThreadListLayout) -> Set<UUID> {
        switch layout {
        case .flat(let t): return Set(t.map(\.id))
        case .sectioned(let s): return Set(s.flatMap { $0.threads.map(\.id) })
        }
    }

    // Typing narrows to Tier-1 immediately, then WIDENS when expansion terms arrive.
    func testTypingNarrowsThenExpansionWidens() async {
        let fake = FakeExpander()
        fake.termsByQuery = ["dog": ["canine"]]   // "canine" reaches the second thread

        let dog = thread("dog walk plan")
        let canine = thread("canine companion notes")   // matches only the expansion term
        let grocery = thread("grocery list")             // matches neither
        let all = [dog, canine, grocery]

        var model = MacThreadListModel(searchExpander: fake, searchEnabled: true,
                                       searchDebounce: .zero)
        model.searchText = "dog"
        model.updateSearch(all, enabled: true)

        // Tier 1, synchronously: only the typed query applies, list narrows to "dog".
        XCTAssertEqual(model.searchQueries, ["dog"])
        XCTAssertEqual(memberIDs(model.layout(all, now: now, calendar: calendar)), [dog.id],
                       "before expansion, only the direct match shows")

        // Tier 2 settles: the expansion term joins the union and the list widens.
        await model.search.awaitPendingExpansion()
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(model.searchQueries, ["dog", "canine"])
        XCTAssertEqual(memberIDs(model.layout(all, now: now, calendar: calendar)),
                       [dog.id, canine.id],
                       "the expansion term surfaces the related thread; the unrelated one stays out")
    }

    // With the tier disabled (Settings toggle off), the expander is never called and
    // the list stays at the Tier-1 match set.
    func testDisabledTierStaysTierOne() async {
        let fake = FakeExpander()
        fake.termsByQuery = ["dog": ["canine"]]
        let dog = thread("dog walk plan")
        let canine = thread("canine companion notes")
        let all = [dog, canine]

        var model = MacThreadListModel(searchExpander: fake, searchEnabled: false,
                                       searchDebounce: .zero)
        model.searchText = "dog"
        model.updateSearch(all, enabled: false)
        await model.search.awaitPendingExpansion()

        XCTAssertEqual(fake.callCount, 0, "a disabled tier never calls the expander")
        XCTAssertEqual(model.searchQueries, ["dog"])
        XCTAssertEqual(memberIDs(model.layout(all, now: now, calendar: calendar)), [dog.id],
                       "disabled tier -> pure Tier-1, no widening")
    }

    // Search composes with scope: within Favorites, an expansion match that is not a
    // favorite must NOT appear (scope is applied before the search filter).
    func testSearchComposesWithFavoritesScope() async {
        let fake = FakeExpander()
        fake.termsByQuery = ["dog": ["canine"]]
        let dog = thread("dog walk plan"); dog.setFavorite(true, now: now)
        let canine = thread("canine companion notes")   // matches expansion but NOT a favorite
        let all = [dog, canine]

        var model = MacThreadListModel(searchExpander: fake, searchEnabled: true,
                                       searchDebounce: .zero)
        model.scope = .favorites
        model.searchText = "dog"
        model.updateSearch(all, enabled: true)
        await model.search.awaitPendingExpansion()

        XCTAssertEqual(model.searchQueries, ["dog", "canine"])
        XCTAssertEqual(memberIDs(model.layout(all, now: now, calendar: calendar)), [dog.id],
                       "the non-favorite expansion match is excluded by the Favorites scope")
    }
}
