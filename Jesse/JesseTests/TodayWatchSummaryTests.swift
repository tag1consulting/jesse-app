import XCTest
import JesseNetworking
@testable import Jesse

/// What the phone chooses to put on the wrist, as a pure function of the day file.
///
/// The selection rule is the whole feature: a watch face is four lines, so the
/// summary is the standing lead item, then OPEN Do Now work capped at ten, then
/// numbers for everything else. Every assertion here is about that rule holding
/// under a day file that is bigger, emptier, or stranger than the happy one.
final class TodayWatchSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: Selection and order

    func testLeadItemComesFirst() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: "\"t\"", at: now)
        XCTAssertEqual(summary.rows.first?.id, "lead")
        XCTAssertEqual(summary.rows.first?.section, "")
    }

    func testOpenDoNowItemsFollowInFileOrder() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        XCTAssertEqual(summary.rows.map(\.id), ["lead", "open-a", "open-b"])
    }

    /// Done work is not glanceable work. A ticked Do Now row is off the wrist and
    /// counted in `doneCount` instead.
    func testCheckedDoNowItemsAreNotShipped() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        XCTAssertFalse(summary.rows.contains { $0.id == "done-a" })
    }

    /// Postponing exists precisely to take a row out of today's attention, so it must
    /// take it off the wrist too — otherwise the watch is the one screen where
    /// postponing does nothing.
    func testPostponedItemsAreNotShipped() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        XCTAssertFalse(summary.rows.contains { $0.id == "postponed-a" })
    }

    /// Only the FIRST `Do Now…` section, matched by prefix, exactly as the tab badge
    /// and every optimistic move already resolve it.
    func testOnlyTheFirstDoNowSectionIsShipped() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        XCTAssertFalse(summary.rows.contains { $0.section == "Do Now (carried)" })
        XCTAssertFalse(summary.rows.contains { $0.section == "Waiting on others" })
    }

    /// A checked LEAD item still ships. It is the standing top-priority item, the one
    /// row that is always on the wrist, and hiding it the moment it is ticked would
    /// also remove the only way to untick it from there.
    func testACheckedLeadItemStillShips() {
        var day = Self.day()
        day.leadItems[0].checked = true
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.first?.id, "lead")
        XCTAssertEqual(summary.rows.first?.checked, true)
    }

    /// A POSTPONED lead item does not ship, for the same reason a postponed Do Now
    /// item does not: it is not today's work any more.
    func testAPostponedLeadItemDoesNotShip() {
        var day = Self.day()
        day.leadItems[0].deferred = true
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertFalse(summary.rows.contains { $0.id == "lead" })
    }

    // MARK: The cap

    func testOpenDoNowItemsAreCappedAtTen() {
        let many = (0..<25).map {
            TodayItem(id: "many-\($0)", lead: "Item \($0)", sectionName: "Do Now")
        }
        let day = TodaySnapshot(date: "2026-08-11",
                                leadItems: [Self.leadItem],
                                sections: [TodaySection(name: "Do Now", items: many)])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        // Ten Do Now rows plus the standing lead item, which is not part of the cap:
        // it is one row and it is the point of the screen.
        XCTAssertEqual(summary.rows.count, TodayWatchSummary.maxDoNowRows + 1)
        XCTAssertEqual(summary.rows.dropFirst().map(\.id).last, "many-9")
    }

    func testTheCapNeverExceedsTheWireLimit() {
        XCTAssertLessThanOrEqual(TodayWatchSummary.maxDoNowRows + 4, WatchTodayWire.maxDecodedRows)
    }

    // MARK: Counts

    /// "Open" on the wrist means ACTIONABLE — not done and not postponed — so the
    /// footer count agrees with the rows above it rather than with a tally that
    /// silently includes work the user already set aside.
    func testOpenCountExcludesDoneAndPostponed() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        // lead, open-a, open-b, carried-a, waiting-a = 5 actionable across the day.
        XCTAssertEqual(summary.openCount, 5)
    }

    /// The complication's number: open `Do Now` work plus open lead items, which is
    /// exactly what the phone's tab badge means. Not `openCount` (the whole day) and
    /// not the row count (capped at ten).
    func testDoNowOpenCountIsTheBadgeNumber() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        // open-a, open-b and the lead item; the carried section is a different one.
        XCTAssertEqual(summary.doNowOpenCount, 3)
    }

    /// And it is NOT clipped by the row cap, which is the whole reason it is carried
    /// rather than counted on the watch.
    func testDoNowOpenCountSurvivesTheRowCap() {
        let many = (0..<25).map {
            TodayItem(id: "many-\($0)", lead: "Item \($0)", sectionName: "Do Now")
        }
        let day = TodaySnapshot(date: "2026-08-11",
                                sections: [TodaySection(name: "Do Now", items: many)])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.count, TodayWatchSummary.maxDoNowRows)
        XCTAssertEqual(summary.doNowOpenCount, 25)
    }

    func testDoneCountIsEveryTickedItemInTheDay() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        // done-a plus the one in the carried section.
        XCTAssertEqual(summary.doneCount, 2)
    }

    func testDateAndEtagAreCarried() {
        let summary = TodayWatchSummary.build(from: Self.day(), etag: nil, at: now)
        XCTAssertEqual(summary.date, "2026-08-11")
        XCTAssertEqual(summary.etag, "\"tag-1\"")
        XCTAssertEqual(summary.pushedAt, now)
    }

    /// The snapshot's own ETag wins when it has one — it is the tag that describes
    /// the very document being summarised, where the caller's is merely the newest
    /// one the model happens to hold.
    func testTheSnapshotsOwnEtagWins() {
        var day = Self.day()
        day.etag = "\"from-body\""
        XCTAssertEqual(TodayWatchSummary.build(from: day, etag: "\"from-model\"", at: now).etag,
                       "\"from-body\"")
    }

    /// A snapshot with no ETag of its own (an older bridge, a body rewritten by a
    /// proxy) falls back to the one the model is holding.
    func testTheCallersEtagIsTheFallback() {
        var day = Self.day()
        day.etag = nil
        XCTAssertEqual(TodayWatchSummary.build(from: day, etag: "\"from-model\"", at: now).etag,
                       "\"from-model\"")
    }

    // MARK: Degenerate days

    func testAMissingDayFileSummarisesToNothing() {
        let summary = TodayWatchSummary.build(
            from: TodaySnapshot(date: "2026-08-11", missing: true), etag: nil, at: now)
        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.openCount, 0)
        XCTAssertEqual(summary.doneCount, 0)
    }

    func testADayWithNoDoNowSectionStillShipsTheLeadItem() {
        let day = TodaySnapshot(date: "2026-08-11",
                                leadItems: [Self.leadItem],
                                sections: [TodaySection(name: "Waiting on others")])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.map(\.id), ["lead"])
    }

    /// The leads are truncated on the way out, so the wire cap is enforced by the
    /// producer as well as by the row initializer.
    func testLongLeadsAreTruncated() {
        let day = TodaySnapshot(
            date: "2026-08-11",
            sections: [TodaySection(name: "Do Now", items: [
                TodayItem(id: "long", lead: String(repeating: "w", count: 300),
                          sectionName: "Do Now"),
            ])])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.first?.lead.count, WatchTodayWire.maxLeadCharacters)
    }

    /// An item whose lead the bridge could not derive falls back to its first line,
    /// so the wrist never renders a blank row with a checkbox on it.
    func testAnItemWithNoLeadFallsBackToItsText() {
        let day = TodaySnapshot(
            date: "2026-08-11",
            sections: [TodaySection(name: "Do Now", items: [
                TodayItem(id: "bare", lead: "",
                          text: "* [ ] Chase the invoice\n  more detail here",
                          sectionName: "Do Now"),
            ])])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.first?.lead, "Chase the invoice")
    }

    func testAnItemWithNeitherLeadNorTextIsDropped() {
        let day = TodaySnapshot(
            date: "2026-08-11",
            sections: [TodaySection(name: "Do Now", items: [
                TodayItem(id: "empty", lead: "", text: "   ", sectionName: "Do Now"),
                TodayItem(id: "real", lead: "Real work", sectionName: "Do Now"),
            ])])
        let summary = TodayWatchSummary.build(from: day, etag: nil, at: now)
        XCTAssertEqual(summary.rows.map(\.id), ["real"])
    }

    // MARK: Fixtures

    private static let leadItem = TodayItem(
        id: "lead", lead: "TOP PRIORITY: finish the rebuild",
        text: "* [ ] **TOP PRIORITY: finish the rebuild**")

    /// A day with a lead item, a Do Now section holding two open / one done / one
    /// postponed, a second `Do Now…` section, and a non-Do-Now section.
    private static func day() -> TodaySnapshot {
        TodaySnapshot(
            title: "Today: Tuesday, August 11, 2026",
            date: "2026-08-11",
            leadItems: [leadItem],
            sections: [
                TodaySection(name: "Do Now", items: [
                    TodayItem(id: "open-a", lead: "Order the thermocouple", sectionName: "Do Now"),
                    TodayItem(id: "done-a", checked: true, lead: "Return the clamps",
                              sectionName: "Do Now"),
                    TodayItem(id: "open-b", lead: "Reply to Ada", sectionName: "Do Now"),
                    TodayItem(id: "postponed-a", lead: "Book the flights",
                              sectionName: "Do Now", deferred: true, deferredMs: 1),
                ]),
                TodaySection(name: "Do Now (carried)", items: [
                    TodayItem(id: "carried-a", lead: "Owed reply to Michael",
                              sectionName: "Do Now (carried)"),
                    TodayItem(id: "carried-done", checked: true, lead: "Signed the lease",
                              sectionName: "Do Now (carried)"),
                ]),
                TodaySection(name: "Waiting on others", items: [
                    TodayItem(id: "waiting-a", lead: "Hear back from the notary",
                              sectionName: "Waiting on others"),
                ]),
            ],
            etag: "\"tag-1\"")
    }
}
