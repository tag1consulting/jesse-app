import XCTest
import SwiftData
@testable import Jesse

final class FavoritesTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Flag + timestamp consistency

    func testNewThreadIsNotFavorite() {
        let thread = JesseThread(mode: .ask)
        XCTAssertFalse(thread.isFavorite)
        XCTAssertNil(thread.favoritedAt)
    }

    func testToggleStarsAndStampsThenClears() {
        let thread = JesseThread(mode: .ask)
        let when = date(2026, 6, 26)

        thread.toggleFavorite(now: when)
        XCTAssertTrue(thread.isFavorite)
        XCTAssertEqual(thread.favoritedAt, when)

        // Unstarring clears the timestamp so it never lingers behind the flag.
        thread.toggleFavorite(now: date(2026, 6, 27))
        XCTAssertFalse(thread.isFavorite)
        XCTAssertNil(thread.favoritedAt)
    }

    func testSetFavoriteIsIdempotentOnTimestamp() {
        let thread = JesseThread(mode: .ask)
        thread.setFavorite(true, now: date(2026, 6, 26))
        thread.setFavorite(false, now: date(2026, 6, 26))
        XCTAssertFalse(thread.isFavorite)
        XCTAssertNil(thread.favoritedAt)
    }

    // MARK: - Old favorites stay first-class after grouping/search changes

    /// A favorite from months ago must still be surfaced by both the Favorites
    /// filter and a content search that matches one of its turns — the 3-day
    /// grouping and the new search must not hide aged, starred threads.
    func testOldFavoriteSurvivesFilterSearchAndSectioning() {
        let now = date(2026, 6, 25)

        // Starred three months back, with the match word only in a turn body.
        let fav = JesseThread(mode: .ask, createdAt: date(2026, 3, 12))
        fav.title = "Garden plans"
        fav.updatedAt = date(2026, 3, 12)
        fav.turns = [
            Turn(role: .user, text: "what should I plant?", createdAt: date(2026, 3, 12)),
            Turn(role: .jesse, text: "Tomatoes do well on the south wall.",
                 createdAt: date(2026, 3, 12)),
        ]
        fav.setFavorite(true, now: date(2026, 3, 12))

        // A recent, unstarred thread that should NOT leak into the favorites view.
        let recent = JesseThread(mode: .ask, createdAt: now)
        recent.title = "Grocery list"

        let all = [recent, fav]

        // Favorites filter still keeps the old starred thread.
        let favorites = all.filter(\.isFavorite)
        XCTAssertEqual(favorites.map(\.id), [fav.id])

        // Content search inside Favorites finds it by a turn-body word.
        XCTAssertTrue(favorites.contains { threadMatches($0, query: "tomatoes") })

        // Content search across All finds it too.
        XCTAssertTrue(all.contains { threadMatches($0, query: "tomatoes") })

        // And it still lands under its month section, not lost off the day window.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let section = threadSection(for: fav.updatedAt, now: now, calendar: cal)
        XCTAssertEqual(section, .month(cal.date(from: DateComponents(year: 2026, month: 3))!))
    }

    // MARK: - Persistence round-trip through SwiftData

    @MainActor
    func testFavoriteFlagPersists() throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        thread.toggleFavorite(now: date(2026, 6, 26))
        try context.save()

        let favorites = try context.fetch(
            FetchDescriptor<JesseThread>(predicate: #Predicate { $0.isFavorite }))
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites.first?.id, thread.id)
    }
}
