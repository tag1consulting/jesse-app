import XCTest
@testable import Jesse

@MainActor
final class FolderSummaryTests: XCTestCase {

    // Fixed UTC/Gregorian/POSIX calendar+locale so month abbreviations and the
    // range formatting never read the wall clock or the host locale.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return calendar.date(from: comps)!
    }

    /// A thread whose only relevant field is its last-activity date.
    private func thread(at updatedAt: Date) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.updatedAt = updatedAt
        return t
    }

    private func summary(_ dates: [Date]) -> String {
        folderSummary(for: dates.map(thread(at:)), calendar: calendar, locale: locale)
    }

    // MARK: - Guard

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(folderSummary(for: [], calendar: calendar, locale: locale), "")
    }

    // MARK: - Count formatting (incl. the singular)

    func testSingleConversationIsSingular() {
        XCTAssertEqual(summary([date(2026, 6, 3)]), "1 conversation · Jun 3")
    }

    func testMultipleConversationsArePlural() {
        // Three conversations, all on the same day → plural noun, single-day range.
        let s = summary([date(2026, 6, 3, 9), date(2026, 6, 3, 14), date(2026, 6, 3, 20)])
        XCTAssertEqual(s, "3 conversations · Jun 3")
    }

    // MARK: - Date range

    func testMultiDaySameMonthRange() {
        // min–max within one month collapses to "Jun 3–28" (month + year stated once).
        let s = summary([date(2026, 6, 28), date(2026, 6, 3), date(2026, 6, 15)])
        XCTAssertEqual(s, "3 conversations · Jun 3–28")
    }

    func testSingleDayRange() {
        // Every thread on the same day → just that day, no dash.
        let s = summary([date(2026, 6, 3, 8), date(2026, 6, 3, 17)])
        XCTAssertEqual(s, "2 conversations · Jun 3")
    }

    func testCrossMonthSameYearRange() {
        // Robustness beyond a single month bucket: month named on both sides.
        let s = summary([date(2026, 6, 28), date(2026, 7, 3)])
        XCTAssertEqual(s, "2 conversations · Jun 28–Jul 3")
    }

    func testCrossYearRangeSpellsBothYears() {
        let s = summary([date(2025, 12, 28), date(2026, 1, 3)])
        XCTAssertEqual(s, "2 conversations · Dec 28 2025–Jan 3 2026")
    }
}
