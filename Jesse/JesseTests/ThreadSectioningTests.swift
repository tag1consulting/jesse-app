import XCTest
@testable import Jesse

@MainActor
final class ThreadSectioningTests: XCTestCase {

    // A fixed UTC/Gregorian/POSIX calendar and a fixed `now` so classification
    // never reads the wall clock and month/weekday titles are deterministic.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Fixed reference instant: 2026-06-25 12:00 UTC.
    private var now: Date { date(2026, 6, 25, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return calendar.date(from: comps)!
    }

    private func section(_ d: Date) -> ThreadSection {
        threadSection(for: d, now: now, calendar: calendar)
    }

    private func monthStart(_ y: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m))!
    }

    // MARK: - Bucketing

    func testToday() {
        XCTAssertEqual(section(date(2026, 6, 25, 3)), .today)
        // Same day, even hours after `now`, still Today.
        XCTAssertEqual(section(date(2026, 6, 25, 23)), .today)
    }

    func testYesterday() {
        XCTAssertEqual(section(date(2026, 6, 24, 23)), .yesterday)
    }

    func testTwoDaysAgoIsWeekdaySection() {
        // The only day-granular weekday section in the 3-day window: 2 days ago.
        let d = date(2026, 6, 23)
        XCTAssertEqual(section(d), .weekday(calendar.startOfDay(for: d)))
    }

    func testThreeDayBoundaryLandsInMonth() {
        // Exactly 3 days ago → month section, not a weekday section. This is the
        // 3-day-window boundary: days 0/1/2 get individual headers, 3+ roll up.
        XCTAssertEqual(section(date(2026, 6, 22)), .month(monthStart(2026, 6)))
    }

    func testTwoVsThreeDayBoundary() {
        // Assert both sides of the 2/3-day boundary against the fixed `now`.
        XCTAssertEqual(section(date(2026, 6, 23)),
                       .weekday(calendar.startOfDay(for: date(2026, 6, 23))),
                       "2 days ago is the last individual weekday section")
        XCTAssertEqual(section(date(2026, 6, 22)), .month(monthStart(2026, 6)),
                       "3 days ago rolls up into its month")
    }

    func testFourDaysAgoSameMonthRollsIntoMonth() {
        XCTAssertEqual(section(date(2026, 6, 21)), .month(monthStart(2026, 6)))
    }

    func testSevenDaysAgoStillLandsInMonth() {
        XCTAssertEqual(section(date(2026, 6, 18)), .month(monthStart(2026, 6)))
    }

    func testPriorMonth() {
        XCTAssertEqual(section(date(2026, 5, 10)), .month(monthStart(2026, 5)))
    }

    func testPriorYear() {
        XCTAssertEqual(section(date(2025, 12, 10)), .month(monthStart(2025, 12)))
    }

    // MARK: - Ordering (newest-first)

    func testSectionsSortNewestFirst() {
        let dates = [
            date(2026, 5, 10),    // May (month)
            date(2025, 12, 10),   // Dec 2025 (month)
            date(2026, 6, 25, 3), // today
            date(2026, 6, 22),    // 3 days ago → June (month)
            date(2026, 6, 17),    // June (month)
            date(2026, 6, 24),    // yesterday
            date(2026, 6, 23),    // 2 days ago (weekday)
        ]
        let ordered = dates.map(section).sorted { $0.sortKey > $1.sortKey }
        XCTAssertEqual(ordered, [
            .today,
            .yesterday,
            .weekday(calendar.startOfDay(for: date(2026, 6, 23))),
            .month(monthStart(2026, 6)),
            .month(monthStart(2026, 6)),   // 6/22 and 6/17 share the June bucket
            .month(monthStart(2026, 5)),
            .month(monthStart(2025, 12)),
        ])
    }

    // MARK: - Titles

    func testTitles() {
        XCTAssertEqual(ThreadSection.today.title(calendar: calendar), "Today")
        XCTAssertEqual(ThreadSection.yesterday.title(calendar: calendar), "Yesterday")
        XCTAssertEqual(ThreadSection.month(monthStart(2026, 6)).title(calendar: calendar), "June 2026")
        XCTAssertEqual(ThreadSection.month(monthStart(2026, 5)).title(calendar: calendar), "May 2026")
        XCTAssertEqual(ThreadSection.month(monthStart(2025, 12)).title(calendar: calendar), "December 2025")
        // 2026-06-23 is a Tuesday.
        XCTAssertEqual(
            ThreadSection.weekday(calendar.startOfDay(for: date(2026, 6, 23))).title(calendar: calendar),
            "Tuesday")
    }
}
