import XCTest
@testable import Jesse
import JesseCore

/// Item 3 — the Watch scope filter. Tests the pure `threadMatchesOrigin` predicate
/// directly and its composition with search + Favorites through the same
/// `threadListLayout` the view drives, mirroring `ThreadFoldersTests`. At least one
/// case here fails if the filter ignores origin (see `testWatchScopeExcludesPhoneThread`
/// / `testWatchScopeComposesWithSearch`).
@MainActor
final class ThreadOriginFilterTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date { date(2026, 6, 25, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func thread(origin: ThreadOrigin, at updatedAt: Date? = nil,
                        favorite: Bool = false, title: String = "",
                        turns: [(TurnRole, String)] = []) -> JesseThread {
        let when = updatedAt ?? now
        let t = JesseThread(mode: .ask)
        t.origin = origin.rawValue
        t.title = title
        t.updatedAt = when
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1, createdAt: when.addingTimeInterval(TimeInterval(i)))
        }
        if favorite { t.setFavorite(true, now: when) }
        return t
    }

    private func allThreads(_ l: ThreadListLayout) -> [JesseThread] {
        switch l {
        case .flat(let t): return t
        case .sectioned(let s): return s.flatMap(\.threads)
        }
    }

    private func layout(_ threads: [JesseThread], favoritesOnly: Bool = false,
                        origin: ThreadOriginScope = .all, search: String = "") -> ThreadListLayout {
        threadListLayout(threads, favoritesOnly: favoritesOnly, originScope: origin,
                         searchQueries: [search], expanded: [], now: now, calendar: calendar)
    }

    // MARK: - The pure predicate

    func testAllScopeMatchesEverything() {
        XCTAssertTrue(threadMatchesOrigin(thread(origin: .phone), scope: .all))
        XCTAssertTrue(threadMatchesOrigin(thread(origin: .watch), scope: .all))
    }

    func testWatchScopeMatchesWatchThread() {
        XCTAssertTrue(threadMatchesOrigin(thread(origin: .watch), scope: .watch))
    }

    /// The guard that fails if the predicate ignores origin: a phone thread must
    /// NOT match the Watch scope.
    func testWatchScopeExcludesPhoneThread() {
        XCTAssertFalse(threadMatchesOrigin(thread(origin: .phone), scope: .watch))
    }

    // MARK: - Composition through the layout

    /// The Watch scope narrows the layout to watch threads only — and stays
    /// date-sectioned (not flattened like Favorites).
    func testWatchScopeLayoutShowsOnlyWatchThreads() {
        let watch = thread(origin: .watch, title: "watch one")
        let phone = thread(origin: .phone, title: "phone one")
        let shown = allThreads(layout([watch, phone], origin: .watch))
        XCTAssertEqual(shown.map(\.title), ["watch one"])
    }

    /// Search inside the Watch scope only ever searches watch threads: a phone
    /// thread whose body matches the query must not surface. This fails if the
    /// origin filter is dropped (the phone thread would match "bridge").
    func testWatchScopeComposesWithSearch() {
        let watchHit = thread(origin: .watch, title: "watch", turns: [(.user, "run the bridge")])
        let phoneHit = thread(origin: .phone, title: "phone", turns: [(.user, "run the bridge")])
        let watchMiss = thread(origin: .watch, title: "watch other", turns: [(.user, "something else")])

        let shown = allThreads(layout([watchHit, phoneHit, watchMiss],
                                      origin: .watch, search: "bridge"))
        XCTAssertEqual(shown.map(\.title), ["watch"])
    }

    /// The Watch scope composes with Favorites too: a non-favorite watch thread is
    /// excluded when both filters are active, a favorite watch thread is kept.
    func testWatchScopeComposesWithFavorites() {
        let favWatch = thread(origin: .watch, favorite: true, title: "fav watch")
        let plainWatch = thread(origin: .watch, title: "plain watch")
        let favPhone = thread(origin: .phone, favorite: true, title: "fav phone")

        let shown = allThreads(layout([favWatch, plainWatch, favPhone],
                                      favoritesOnly: true, origin: .watch))
        XCTAssertEqual(shown.map(\.title), ["fav watch"])
    }

    /// The default `.all` scope leaves both origins visible (no regression to the
    /// existing All tab).
    func testAllScopeLayoutKeepsBothOrigins() {
        let watch = thread(origin: .watch, title: "w")
        let phone = thread(origin: .phone, title: "p")
        let shown = allThreads(layout([watch, phone], origin: .all))
        XCTAssertEqual(Set(shown.map(\.title)), ["w", "p"])
    }
}
