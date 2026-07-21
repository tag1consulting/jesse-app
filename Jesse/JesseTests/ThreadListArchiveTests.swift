import XCTest
import JesseCore
import JesseConversations
@testable import Jesse

/// iOS thread-list archive wiring. The list's filtering is driven by the shared
/// `threadListLayout` exactly as `ThreadListView` calls it: a scope maps to
/// (favoritesOnly, originScope, archivedOnly), archived threads are excluded from
/// every non-archived scope, and the Archived scope shows only them. These assert
/// that behavior at the app-target layer (the shared grouping logic itself is
/// covered once in JesseConversationsTests). Archive state is local to the device:
/// there is nothing networked here, just `isArchived` filtering.
@MainActor
final class ThreadListArchiveTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date { date(2026, 6, 25) }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func thread(_ title: String, at updatedAt: Date,
                        favorite: Bool = false, archived: Bool = false) -> JesseThread {
        let t = JesseThread(mode: .ask, createdAt: updatedAt)
        t.title = title
        t.updatedAt = updatedAt
        if favorite { t.setFavorite(true, now: updatedAt) }
        if archived { t.setArchived(true, now: updatedAt) }
        return t
    }

    /// Mirror `ThreadListView`'s scope -> layout mapping so the test drives the same
    /// call the view does.
    private func layout(_ threads: [JesseThread], scope: ThreadListView.ListScope) -> ThreadListLayout {
        threadListLayout(threads,
                         favoritesOnly: scope == .favorites,
                         originScope: scope == .watch ? .watch : .all,
                         archivedOnly: scope == .archived,
                         searchQueries: [""],
                         expanded: [],
                         now: now,
                         calendar: calendar)
    }

    private func ids(_ layout: ThreadListLayout) -> Set<UUID> {
        switch layout {
        case .flat(let t): return Set(t.map(\.id))
        case .sectioned(let s): return Set(s.flatMap { $0.threads.map(\.id) })
        }
    }

    func testArchivedThreadHiddenFromAllAndFavoritesButShownInArchived() {
        let live = thread("live", at: date(2026, 6, 24))
        let archivedFav = thread("archived fav", at: date(2026, 6, 23),
                                 favorite: true, archived: true)
        let all = [live, archivedFav]

        XCTAssertEqual(ids(layout(all, scope: .all)), [live.id])
        XCTAssertEqual(ids(layout(all, scope: .favorites)), [])
        XCTAssertEqual(ids(layout(all, scope: .archived)), [archivedFav.id])
    }

    func testTogglingArchivedMovesAThreadBetweenLayouts() {
        let t = thread("dup", at: date(2026, 6, 24))
        let all = [t]

        // Live: in All, not in Archived.
        XCTAssertEqual(ids(layout(all, scope: .all)), [t.id])
        XCTAssertEqual(ids(layout(all, scope: .archived)), [])

        // Archive it (as the view's toggleArchived would): sets flag + timestamp.
        t.toggleArchived(now: date(2026, 6, 25))
        XCTAssertTrue(t.isArchived)
        XCTAssertEqual(t.archivedAt, date(2026, 6, 25))
        XCTAssertEqual(ids(layout(all, scope: .all)), [], "archived thread leaves All")
        XCTAssertEqual(ids(layout(all, scope: .archived)), [t.id], "and enters Archived")

        // Unarchive: it returns to All, out of Archived, timestamp cleared.
        t.toggleArchived(now: date(2026, 6, 26))
        XCTAssertFalse(t.isArchived)
        XCTAssertNil(t.archivedAt)
        XCTAssertEqual(ids(layout(all, scope: .all)), [t.id], "unarchiving restores it to All")
        XCTAssertEqual(ids(layout(all, scope: .archived)), [])
    }
}
