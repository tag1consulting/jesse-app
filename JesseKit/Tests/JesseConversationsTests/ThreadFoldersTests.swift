import XCTest
import JesseConversations
import JesseCore

@MainActor
final class ThreadFoldersTests: XCTestCase {

    // Fixed calendar + `now` (2026-06-25 12:00 UTC), matching ThreadSectioningTests,
    // so day/month bucketing and folding never read the wall clock.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date { date(2026, 6, 25, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return calendar.date(from: comps)!
    }

    private func thread(at updatedAt: Date, favorite: Bool = false,
                        title: String = "", turns: [(TurnRole, String)] = []) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.updatedAt = updatedAt
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1,
                 createdAt: updatedAt.addingTimeInterval(TimeInterval(i)))
        }
        if favorite { t.setFavorite(true, now: updatedAt) }
        return t
    }

    private func monthStart(_ y: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m))!
    }

    private func layout(_ threads: [JesseThread], favoritesOnly: Bool = false,
                        search: String = "",
                        expanded: Set<ThreadSection> = []) -> ThreadListLayout {
        threadListLayout(threads, favoritesOnly: favoritesOnly, searchQueries: [search],
                         expanded: expanded, now: now, calendar: calendar)
    }

    private func sections(_ l: ThreadListLayout) -> [RenderedThreadSection] {
        guard case .sectioned(let s) = l else {
            XCTFail("expected a sectioned layout, got flat"); return []
        }
        return s
    }

    private func section(_ l: ThreadListLayout, _ s: ThreadSection) -> RenderedThreadSection? {
        sections(l).first { $0.section == s }
    }

    // MARK: - Month folders collapse by default; day sections never fold

    func testMonthFoldersStartCollapsedAndHideRows() {
        let today = thread(at: date(2026, 6, 25))
        let oldA = thread(at: date(2026, 6, 3))     // June bucket (3+ days ago)
        let oldB = thread(at: date(2026, 6, 10))    // June bucket

        let l = layout([today, oldA, oldB])
        let june = section(l, .month(monthStart(2026, 6)))
        XCTAssertNotNil(june)
        XCTAssertTrue(june!.isFolder, "month buckets are folders")
        XCTAssertFalse(june!.isExpanded, "folders start collapsed")
        // The point of collapsing: the member rows are NOT on screen.
        XCTAssertTrue(june!.visibleThreads.isEmpty,
                      "a collapsed folder shows none of its rows")
        // Membership is still tracked (for the summary + toggling), just hidden.
        XCTAssertEqual(Set(june!.threads.map(\.id)), Set([oldA.id, oldB.id]))
    }

    func testDaySectionsAreNeverFolded() {
        let today = thread(at: date(2026, 6, 25))
        let yest = thread(at: date(2026, 6, 24))
        let weekday = thread(at: date(2026, 6, 23))   // 2 days ago

        let l = layout([today, yest, weekday])
        for sec: ThreadSection in [.today, .yesterday, .weekday(calendar.startOfDay(for: date(2026, 6, 23)))] {
            let rendered = section(l, sec)
            XCTAssertNotNil(rendered, "expected day section \(sec)")
            XCTAssertFalse(rendered!.isFolder, "day sections do not fold")
            XCTAssertTrue(rendered!.isExpanded, "day sections are always expanded")
            XCTAssertEqual(rendered!.visibleThreads.count, 1,
                           "loose day rows are always on screen")
        }
    }

    // MARK: - Toggling a folder reveals/hides its rows

    func testTogglingFolderRevealsRows() {
        let old = thread(at: date(2026, 6, 3))
        let june = ThreadSection.month(monthStart(2026, 6))

        let collapsed = section(layout([old]), june)!
        XCTAssertTrue(collapsed.visibleThreads.isEmpty)

        // Expanding = adding the section id to the expansion set.
        let expanded = section(layout([old], expanded: [june]), june)!
        XCTAssertTrue(expanded.isExpanded)
        XCTAssertEqual(expanded.visibleThreads.map(\.id), [old.id],
                       "an expanded folder reveals its rows")
    }

    // MARK: - Favorites tab is flat — no folders

    func testFavoritesTabIsFlatWithNoFolders() {
        // Two starred threads of very different ages + an unstarred recent one.
        let oldFav = thread(at: date(2026, 3, 12), favorite: true)
        let recentFav = thread(at: date(2026, 6, 25), favorite: true)
        let unstarred = thread(at: date(2026, 6, 24))

        let l = layout([unstarred, oldFav, recentFav], favoritesOnly: true)
        guard case .flat(let list) = l else {
            return XCTFail("favorites tab must be a flat list, not sectioned")
        }
        // All starred threads regardless of age, newest-first, no month chrome.
        XCTAssertEqual(list.map(\.id), [recentFav.id, oldFav.id])
        XCTAssertFalse(list.contains { $0.id == unstarred.id })
    }

    func testAllTabHasMonthFolders() {
        let l = layout([thread(at: date(2026, 6, 25)), thread(at: date(2026, 3, 12))])
        let folders = sections(l).filter(\.isFolder)
        XCTAssertFalse(folders.isEmpty, "the All tab groups old history into month folders")
    }

    // MARK: - Active search flattens (force-expands) collapsed folders

    func testSearchForceExpandsCollapsedFolderSoMatchIsVisible() {
        // A match that lives in a month bucket collapsed-by-default.
        let buried = thread(at: date(2026, 3, 12), title: "Garden plans",
                            turns: [(.user, "what to plant?"),
                                    (.jesse, "Tomatoes do well here.")])
        let march = ThreadSection.month(monthStart(2026, 3))

        // Idle search: folder collapsed, match hidden.
        let idle = section(layout([buried]), march)!
        XCTAssertFalse(idle.isExpanded)
        XCTAssertTrue(idle.visibleThreads.isEmpty)

        // Active search matching a turn body: folder force-expanded, match visible.
        let searching = section(layout([buried], search: "tomatoes"), march)!
        XCTAssertTrue(searching.isExpanded, "search must force folders open")
        XCTAssertEqual(searching.visibleThreads.map(\.id), [buried.id],
                       "a match in a collapsed-by-default folder is visible while searching")

        // Clearing the query returns the folder to collapsed.
        let cleared = section(layout([buried], search: ""), march)!
        XCTAssertFalse(cleared.isExpanded, "clearing search restores collapsed folders")
        XCTAssertTrue(cleared.visibleThreads.isEmpty)
    }

    // MARK: - Union of query + expansion terms (Tier 2 widen at the layout level)

    /// Drive the layout with an explicit query LIST (typed query + alternate terms).
    private func layout(_ threads: [JesseThread], queries: [String],
                        expanded: Set<ThreadSection> = []) -> ThreadListLayout {
        threadListLayout(threads, favoritesOnly: false, searchQueries: queries,
                         expanded: expanded, now: now, calendar: calendar)
    }

    /// A thread that matches ONLY an alternate expansion term (not the typed query)
    /// is visible while searching, and its month folder is force-expanded — exactly
    /// as a direct match would be. Clearing the query restores the collapsed folder.
    func testExpansionTermSurfacesBuriedThreadAndForceExpands() {
        let buried = thread(at: date(2026, 3, 12), title: "Trip",
                            turns: [(.user, "planning a holiday in Sicily")])
        let march = ThreadSection.month(monthStart(2026, 3))

        // Typed query "vacation" matches nothing; folder stays collapsed, row hidden.
        let typedOnly = section(layout([buried], queries: ["vacation"]), march)
        XCTAssertNil(typedOnly, "no section when nothing matches the typed query")

        // Add the expansion term "holiday": the buried thread surfaces and its
        // month folder force-expands so the match is visible.
        let widened = section(layout([buried], queries: ["vacation", "holiday"]), march)!
        XCTAssertTrue(widened.isExpanded, "an expansion match force-expands its folder")
        XCTAssertEqual(widened.visibleThreads.map(\.id), [buried.id],
                       "a thread matched only via an expansion term is visible")

        // Clearing the query restores the collapsed folder.
        let cleared = section(layout([buried], queries: []), march)!
        XCTAssertFalse(cleared.isExpanded)
        XCTAssertTrue(cleared.visibleThreads.isEmpty)
    }

    /// Set semantics: a thread matching BOTH the typed query and an alternate term
    /// appears exactly once — expansion never double-counts a row.
    func testUnionDoesNotDoubleCountAThread() {
        let t = thread(at: date(2026, 3, 12), title: "Deploy notes",
                       turns: [(.user, "run over the bridge")])
        let march = ThreadSection.month(monthStart(2026, 3))
        // "bridge" (typed) and "run bridge" (alternate) BOTH match this thread; it
        // must still be listed once.
        let sec = section(layout([t], queries: ["bridge", "run bridge"]), march)!
        XCTAssertEqual(sec.threads.filter { $0.id == t.id }.count, 1,
                       "a thread matching multiple entries is listed once")
    }

    /// Graceful degradation (item 8): with no expansion terms (a single-entry list —
    /// what a dry/disabled expander produces), the visible layout is byte-identical
    /// to Tier-1-only, and adding an alternate term that matches NOTHING changes
    /// nothing (expansion only ever ADDS).
    func testLayoutDegradesToTier1WhenExpansionInactive() {
        let a = thread(at: date(2026, 6, 25), title: "Roof", turns: [(.user, "roofer Thursday")])
        let b = thread(at: date(2026, 3, 12), title: "Deploy", turns: [(.user, "run over the bridge")])
        let march = ThreadSection.month(monthStart(2026, 3))

        func visibleIDs(_ l: ThreadListLayout) -> [[UUID]] {
            sections(l).sorted { $0.section.sortKey > $1.section.sortKey }
                .map { $0.threads.map(\.id) }
        }
        let base = layout([a, b], queries: ["roof"], expanded: [march])
        let widenedWithDeadTerm = layout([a, b], queries: ["roof", "zzzznomatch"], expanded: [march])
        XCTAssertEqual(visibleIDs(base), visibleIDs(widenedWithDeadTerm),
                       "an expansion term that matches nothing leaves the layout unchanged")
    }

    // MARK: - Folder tap toggles expand/collapse (the dead-tap fix)

    // The month folder header was a bare `Section(isExpanded:)` whose header isn't
    // tappable in this grouped list style, so tapping it did nothing. The fix
    // routes the tap through the pure `foldersAfterToggling`, wired to a
    // DisclosureGroup's tappable chevron. These drive that expansion-state model
    // through `threadListLayout` (no UI snapshotting), proving a tap now flips the
    // folder's expanded state AND the rows on screen.

    func testTogglingFolderFlipsExpandedStateAndVisibleRows() {
        let old = thread(at: date(2026, 6, 3))
        let june = ThreadSection.month(monthStart(2026, 6))

        // Collapsed by default: rows hidden.
        var expanded: Set<ThreadSection> = []
        let collapsed = section(layout([old], expanded: expanded), june)!
        XCTAssertFalse(collapsed.isExpanded)
        XCTAssertTrue(collapsed.visibleThreads.isEmpty)

        // Tap → expanded, the row is now on screen.
        expanded = foldersAfterToggling(june, in: expanded)
        let opened = section(layout([old], expanded: expanded), june)!
        XCTAssertTrue(opened.isExpanded, "a tap opens the folder")
        XCTAssertEqual(opened.visibleThreads.map(\.id), [old.id],
                       "opening reveals the member rows")

        // Tap again → collapsed, rows hidden once more.
        expanded = foldersAfterToggling(june, in: expanded)
        let reclosed = section(layout([old], expanded: expanded), june)!
        XCTAssertFalse(reclosed.isExpanded, "a second tap collapses the folder")
        XCTAssertTrue(reclosed.visibleThreads.isEmpty)
    }

    func testToggleOnlyAffectsTheTappedFolder() {
        let june = thread(at: date(2026, 6, 3))
        let march = thread(at: date(2026, 3, 12))
        let juneSec = ThreadSection.month(monthStart(2026, 6))
        let marchSec = ThreadSection.month(monthStart(2026, 3))

        let expanded = foldersAfterToggling(juneSec, in: [])
        let l = layout([june, march], expanded: expanded)
        XCTAssertTrue(section(l, juneSec)!.isExpanded, "the tapped folder opens")
        XCTAssertFalse(section(l, marchSec)!.isExpanded, "other folders stay collapsed")
    }

    // MARK: - Folder header exposes the chevron + count/date label

    func testFolderHeaderExposesChevronAndSummary() {
        let a = thread(at: date(2026, 6, 3))
        let b = thread(at: date(2026, 6, 10))
        let june = ThreadSection.month(monthStart(2026, 6))

        // Collapsed: right-pointing chevron, month name, deterministic summary.
        let collapsed = section(layout([a, b]), june)!
        let header = folderHeader(for: collapsed, calendar: calendar, locale: calendar.locale ?? .current)
        XCTAssertEqual(header.title, "June 2026", "the month name")
        XCTAssertEqual(header.summary,
                       folderSummary(for: collapsed.threads, calendar: calendar,
                                     locale: calendar.locale ?? .current),
                       "the deterministic count · date-range label (PR #20)")
        XCTAssertTrue(header.summary.contains("2 conversations"))
        XCTAssertFalse(header.isExpanded)
        XCTAssertEqual(header.chevronSystemImage, "chevron.right",
                       "collapsed folders read as closed containers")

        // Expanded: the chevron flips to reflect the open state.
        let opened = section(layout([a, b], expanded: [june]), june)!
        let openHeader = folderHeader(for: opened, calendar: calendar,
                                      locale: calendar.locale ?? .current)
        XCTAssertTrue(openHeader.isExpanded)
        XCTAssertEqual(openHeader.chevronSystemImage, "chevron.down",
                       "the chevron reflects the expanded state")
    }
}
