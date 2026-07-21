import XCTest
import JesseCore
import JesseConversations
@testable import Jesse_Mac

// Mac sidebar list-model wiring. These test the pure seam (`MacThreadListModel`),
// not pixels: that starring a thread updates `isFavorite`/`favoritedAt`, and that
// switching scope changes which threads the shared `threadListLayout` yields (flat
// favorites vs. the full date-sectioned layout). The grouping/date-bucketing logic
// itself is covered once in JesseConversationsTests; here we assert only the Mac
// model's wiring on top of it.
@MainActor
final class MacThreadListModelTests: XCTestCase {

    // Fixed UTC/Gregorian/POSIX calendar + `now` (2026-06-25 12:00 UTC), matching the
    // shared tests, so bucketing never reads the wall clock.
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

    private func thread(at updatedAt: Date, favorite: Bool = false, title: String = "") -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.updatedAt = updatedAt
        if favorite { t.setFavorite(true, now: updatedAt) }
        return t
    }

    /// Membership ids across a layout (folder members included, even when collapsed).
    private func memberIDs(_ layout: ThreadListLayout) -> [UUID] {
        switch layout {
        case .flat(let t): return t.map(\.id)
        case .sectioned(let s): return s.flatMap { $0.threads.map(\.id) }
        }
    }

    private func section(_ layout: ThreadListLayout, _ s: ThreadSection) -> RenderedThreadSection? {
        guard case .sectioned(let sections) = layout else { return nil }
        return sections.first { $0.section == s }
    }

    // MARK: - Scope switches the layout shape and its members

    func testScopeSwitchesBetweenSectionedAllAndFlatFavorites() {
        var model = MacThreadListModel()
        let favRecent = thread(at: date(2026, 6, 25), favorite: true, title: "fav recent")
        let favOld = thread(at: date(2026, 3, 12), favorite: true, title: "fav old")
        let plain = thread(at: date(2026, 6, 24), title: "plain")
        let all = [plain, favRecent, favOld]

        // All scope: sectioned, every thread present.
        model.scope = .all
        let allLayout = model.layout(all, now: now, calendar: calendar)
        guard case .sectioned = allLayout else { return XCTFail("all scope must be sectioned") }
        XCTAssertEqual(Set(memberIDs(allLayout)), Set([plain.id, favRecent.id, favOld.id]))

        // Favorites scope: flat, only starred threads, newest-first, no unstarred leak.
        model.scope = .favorites
        let favLayout = model.layout(all, now: now, calendar: calendar)
        guard case .flat(let flat) = favLayout else { return XCTFail("favorites scope must be flat") }
        XCTAssertEqual(flat.map(\.id), [favRecent.id, favOld.id])
        XCTAssertFalse(flat.contains { $0.id == plain.id })
    }

    func testToggleFavoritesScopeFlipsBackAndForth() {
        var model = MacThreadListModel()
        XCTAssertEqual(model.scope, .all)
        model.toggleFavoritesScope()
        XCTAssertEqual(model.scope, .favorites)
        model.toggleFavoritesScope()
        XCTAssertEqual(model.scope, .all)
    }

    // MARK: - Starring a thread updates the model object and the favorites layout

    func testToggleFavoriteStampsThenClearsAndDrivesFavoritesLayout() {
        let model = MacThreadListModel()
        let t = thread(at: date(2026, 6, 25), title: "x")
        XCTAssertFalse(t.isFavorite)
        XCTAssertNil(t.favoritedAt)

        // Star: flag set, timestamp stamped.
        let starred = date(2026, 6, 26)
        model.toggleFavorite(t, now: starred)
        XCTAssertTrue(t.isFavorite)
        XCTAssertEqual(t.favoritedAt, starred)

        // The favorites scope now surfaces it.
        var favModel = MacThreadListModel()
        favModel.scope = .favorites
        guard case .flat(let flat) = favModel.layout([t], now: now, calendar: calendar) else {
            return XCTFail("favorites scope must be flat")
        }
        XCTAssertEqual(flat.map(\.id), [t.id])

        // Unstar: flag cleared, timestamp cleared, and it drops out of favorites.
        model.toggleFavorite(t, now: date(2026, 6, 27))
        XCTAssertFalse(t.isFavorite)
        XCTAssertNil(t.favoritedAt)
        guard case .flat(let empty) = favModel.layout([t], now: now, calendar: calendar) else {
            return XCTFail("favorites scope must be flat")
        }
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Archive scope + toggling drives the shared layout

    func testArchivedScopeShowsOnlyArchivedAndAllExcludesThem() {
        var model = MacThreadListModel()
        let live = thread(at: date(2026, 6, 25), title: "live")
        let archivedOld = thread(at: date(2026, 3, 12), title: "archived old")
        let archivedNew = thread(at: date(2026, 6, 20), title: "archived new")
        archivedOld.setArchived(true, now: date(2026, 3, 12))
        archivedNew.setArchived(true, now: date(2026, 6, 20))
        let all = [live, archivedOld, archivedNew]

        // All scope: sectioned, and the archived threads are hidden from it.
        model.scope = .all
        let allLayout = model.layout(all, now: now, calendar: calendar)
        XCTAssertEqual(Set(memberIDs(allLayout)), [live.id],
                       "the All scope excludes archived threads")

        // Archived scope: flat, only archived, newest-first, no live leak.
        model.scope = .archived
        let archivedLayout = model.layout(all, now: now, calendar: calendar)
        guard case .flat(let flat) = archivedLayout else {
            return XCTFail("archived scope must be flat")
        }
        XCTAssertEqual(flat.map(\.id), [archivedNew.id, archivedOld.id])
        XCTAssertFalse(flat.contains { $0.id == live.id })
    }

    func testToggleArchivedRemovesFromActiveLayoutThenRestores() {
        let model = MacThreadListModel()
        let t = thread(at: date(2026, 6, 25), title: "dup")
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)

        // Archive: flag set, timestamp stamped.
        let archivedAt = date(2026, 6, 26)
        model.toggleArchived(t, now: archivedAt)
        XCTAssertTrue(t.isArchived)
        XCTAssertEqual(t.archivedAt, archivedAt)

        // It drops out of the All layout and appears in the Archived layout.
        var allModel = MacThreadListModel(); allModel.scope = .all
        XCTAssertTrue(memberIDs(allModel.layout([t], now: now, calendar: calendar)).isEmpty,
                      "an archived thread is gone from the All layout")
        var archivedModel = MacThreadListModel(); archivedModel.scope = .archived
        guard case .flat(let flat) = archivedModel.layout([t], now: now, calendar: calendar) else {
            return XCTFail("archived scope must be flat")
        }
        XCTAssertEqual(flat.map(\.id), [t.id])

        // Unarchive: flag + timestamp cleared, and it returns to the All layout.
        model.toggleArchived(t, now: date(2026, 6, 27))
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)
        XCTAssertEqual(memberIDs(allModel.layout([t], now: now, calendar: calendar)), [t.id],
                       "unarchiving restores it to the All layout")
    }

    // MARK: - Folder expansion routes through the shared pure helper

    func testToggleFolderRevealsMonthRows() {
        var model = MacThreadListModel()   // .all
        let old = thread(at: date(2026, 3, 12), title: "old")
        let march = ThreadSection.month(calendar.date(from: DateComponents(year: 2026, month: 3))!)

        // Collapsed by default: the month folder hides its rows.
        let collapsed = section(model.layout([old], now: now, calendar: calendar), march)
        XCTAssertNotNil(collapsed)
        XCTAssertTrue(collapsed!.isFolder)
        XCTAssertFalse(collapsed!.isExpanded)
        XCTAssertTrue(collapsed!.visibleThreads.isEmpty)

        // Toggle open: the row is now visible.
        model.toggleFolder(march)
        let opened = section(model.layout([old], now: now, calendar: calendar), march)!
        XCTAssertTrue(opened.isExpanded)
        XCTAssertEqual(opened.visibleThreads.map(\.id), [old.id])
    }
}
