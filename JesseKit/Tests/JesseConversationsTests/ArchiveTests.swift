import XCTest
import SwiftData
import JesseConversations
import JesseCore

// Archive scoping in the shared list presentation. Archiving hides a conversation
// from the main list (All / Favorites / Watch) and surfaces it only in a dedicated
// Archived view, from which it can be restored. These pin that the archive filter
// composes additively with favorites/origin and runs before grouping, exactly like
// the other scopes: the same one source of truth both apps drive their list from.
// Archive state is local to each device's store (never bridge-synced), so there is
// nothing networked to test here: it is pure filtering over `isArchived`.
@MainActor
final class ArchiveTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
    private var now: Date { date(2026, 6, 25) }

    private func thread(_ title: String, at updatedAt: Date,
                        favorite: Bool = false, archived: Bool = false) -> JesseThread {
        let t = JesseThread(mode: .ask, createdAt: updatedAt)
        t.title = title
        t.updatedAt = updatedAt
        if favorite { t.setFavorite(true, now: updatedAt) }
        if archived { t.setArchived(true, now: updatedAt) }
        return t
    }

    /// All ids a layout renders (folder members counted even when collapsed), so an
    /// archived thread hidden behind a collapsed folder would still be caught here.
    private func memberIDs(_ layout: ThreadListLayout) -> Set<UUID> {
        switch layout {
        case .flat(let t): return Set(t.map(\.id))
        case .sectioned(let s): return Set(s.flatMap { $0.threads.map(\.id) })
        }
    }

    // MARK: - Model helper: flag + timestamp consistency

    func testNewThreadIsNotArchived() {
        let t = JesseThread(mode: .ask)
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)
    }

    func testToggleArchivesAndStampsThenClears() {
        let t = JesseThread(mode: .ask)
        t.toggleArchived(now: date(2026, 6, 26))
        XCTAssertTrue(t.isArchived)
        XCTAssertEqual(t.archivedAt, date(2026, 6, 26))

        // Unarchiving clears the timestamp so it never lingers behind the flag.
        t.toggleArchived(now: date(2026, 6, 27))
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)
    }

    func testSetArchivedFalseClearsTimestamp() {
        let t = JesseThread(mode: .ask)
        t.setArchived(true, now: date(2026, 6, 26))
        t.setArchived(false, now: date(2026, 6, 26))
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)
    }

    // MARK: - Archived threads are hidden from the default and favorites layouts

    func testArchivedThreadHiddenFromDefaultAndFavoritesLayouts() {
        let live = thread("live", at: date(2026, 6, 24))
        let archived = thread("archived", at: date(2026, 6, 23), archived: true)
        let archivedFav = thread("archived fav", at: date(2026, 6, 22),
                                 favorite: true, archived: true)
        let all = [live, archived, archivedFav]

        // Default (All) layout excludes every archived thread.
        let allLayout = threadListLayout(all, favoritesOnly: false, searchQueries: [""],
                                         expanded: [], now: now, calendar: calendar)
        XCTAssertEqual(memberIDs(allLayout), [live.id],
                       "archived threads are hidden from the All layout")

        // Favorites layout excludes an archived favorite too.
        let favLayout = threadListLayout(all, favoritesOnly: true, searchQueries: [""],
                                         expanded: [], now: now, calendar: calendar)
        XCTAssertEqual(memberIDs(favLayout), [],
                       "an archived favorite is hidden from the Favorites layout")
    }

    // MARK: - The Archived view returns only archived threads

    func testArchivedLayoutReturnsOnlyArchivedNewestFirst() {
        let live = thread("live", at: date(2026, 6, 24))
        let oldArchived = thread("old archived", at: date(2026, 3, 12), archived: true)
        let newArchived = thread("new archived", at: date(2026, 6, 20), archived: true)
        let all = [live, oldArchived, newArchived]

        let layout = threadListLayout(all, favoritesOnly: false, archivedOnly: true,
                                      searchQueries: [""], expanded: [],
                                      now: now, calendar: calendar)
        // Flat, like Favorites, newest-first, and only the archived threads.
        guard case .flat(let list) = layout else {
            return XCTFail("the Archived view must be flat")
        }
        XCTAssertEqual(list.map(\.id), [newArchived.id, oldArchived.id],
                       "the Archived view shows only archived threads, newest-first")
    }

    // MARK: - Archiving a favorite removes it from favorites until unarchived

    func testArchivingAFavoriteRemovesItFromFavoritesUntilUnarchived() {
        let fav = thread("garden", at: date(2026, 6, 24), favorite: true)
        let all = [fav]

        func favIDs() -> Set<UUID> {
            memberIDs(threadListLayout(all, favoritesOnly: true, searchQueries: [""],
                                       expanded: [], now: now, calendar: calendar))
        }
        func archivedIDs() -> Set<UUID> {
            memberIDs(threadListLayout(all, favoritesOnly: false, archivedOnly: true,
                                       searchQueries: [""], expanded: [],
                                       now: now, calendar: calendar))
        }

        // Starred and live: in Favorites, not in Archived.
        XCTAssertEqual(favIDs(), [fav.id])
        XCTAssertEqual(archivedIDs(), [])

        // Archive it: it leaves Favorites and enters the Archived view, still starred.
        fav.setArchived(true, now: date(2026, 6, 25))
        XCTAssertTrue(fav.isFavorite, "archiving does not unstar")
        XCTAssertEqual(favIDs(), [], "an archived favorite is not in Favorites")
        XCTAssertEqual(archivedIDs(), [fav.id])

        // Unarchive it: it returns to Favorites, out of the Archived view.
        fav.setArchived(false, now: date(2026, 6, 26))
        XCTAssertEqual(favIDs(), [fav.id], "unarchiving restores it to Favorites")
        XCTAssertEqual(archivedIDs(), [])
    }

    // MARK: - Persistence round-trip through SwiftData

    func testArchiveFlagPersists() throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let t = JesseThread(mode: .ask)
        context.insert(t)
        t.toggleArchived(now: date(2026, 6, 26))
        try context.save()

        let archived = try context.fetch(
            FetchDescriptor<JesseThread>(predicate: #Predicate { $0.isArchived }))
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.id, t.id)
        XCTAssertEqual(archived.first?.archivedAt, date(2026, 6, 26))
    }
}
