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
