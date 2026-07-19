import XCTest
@testable import Jesse

// The pure day-history logic: paging over availableDays, the end-of-day engine-hour
// injection for a past day, the neutral-mode labels, and the past-day chrome
// visibility rules. No SwiftUI, no networking — the seams the view relies on.

@MainActor
final class HealthHistoryTests: XCTestCase {

    // MARK: - DietPaging

    private let days = ["2026-03-30", "2026-04-15", "2026-07-07", "2026-07-08", "2026-07-12"]

    func testNearestEarlierDay() {
        let p = DietPaging(days: days, today: "2026-07-12")
        XCTAssertEqual(p.earlier(than: "2026-07-12"), "2026-07-08")
        XCTAssertEqual(p.earlier(than: "2026-07-08"), "2026-07-07")
        XCTAssertEqual(p.earlier(than: "2026-04-15"), "2026-03-30")
        XCTAssertNil(p.earlier(than: "2026-03-30"), "earliest day has no earlier")
    }

    func testNearestLaterDayForwardFromYesterdayLandsOnToday() {
        let p = DietPaging(days: days, today: "2026-07-12")
        XCTAssertEqual(p.later(than: "2026-07-08"), "2026-07-12", "forward from the last past day lands on today")
        XCTAssertEqual(p.later(than: "2026-03-30"), "2026-04-15")
        XCTAssertNil(p.later(than: "2026-07-12"), "today has no later")
    }

    func testEndsDisableChevrons() {
        let p = DietPaging(days: days, today: "2026-07-12")
        XCTAssertFalse(p.canGoBack(from: "2026-03-30"), "back disabled at the earliest day")
        XCTAssertTrue(p.canGoForward(from: "2026-03-30"))
        XCTAssertTrue(p.canGoBack(from: "2026-07-12"))
        XCTAssertFalse(p.canGoForward(from: "2026-07-12"), "forward disabled on today")
    }

    func testTodayIsAlwaysAvailableEvenIfPayloadOmitsIt() {
        // A degraded availableDays that doesn't list today still lets you page.
        let p = DietPaging(days: ["2026-07-07", "2026-07-08"], today: "2026-07-12")
        XCTAssertEqual(p.later(than: "2026-07-08"), "2026-07-12")
        XCTAssertFalse(p.canGoForward(from: "2026-07-12"))
    }

    func testPagingSortsAndDedupesDefensively() {
        let p = DietPaging(days: ["2026-07-08", "2026-03-30", "2026-07-08"], today: "2026-07-12")
        XCTAssertEqual(p.days, ["2026-03-30", "2026-07-08", "2026-07-12"])
    }

    // MARK: - HistoryRender (engine hour)

    func testEndOfDayHourForHistoricalDay() {
        // A past day resolves time-gated flags fully — hour 24, regardless of clock.
        XCTAssertEqual(HistoryRender.engineHour(isHistorical: true, clockHour: 9), 24)
        XCTAssertEqual(HistoryRender.engineHour(isHistorical: true, clockHour: 23), 24)
    }

    func testTodayUsesTheRealClockHour() {
        XCTAssertEqual(HistoryRender.engineHour(isHistorical: false, clockHour: 9), 9)
        XCTAssertEqual(HistoryRender.engineHour(isHistorical: false, clockHour: 23), 23)
    }

    func testEndOfDayHourResolvesTheAfterFourGate() {
        // Sanity: hour 24 is >= DietSemantics.nagHour (16), so a low-protein day
        // surfaces its flag when viewed historically even though the render clock
        // might be morning.
        let today = DietToday(date: "2026-04-15",
                              meals: [DietMeal(name: "B", time: "08:00",
                                               items: [DietItem(item: "toast", p: 5)])],
                              targets: DietTargets(protein: 190))
        let hour = HistoryRender.engineHour(isHistorical: true, clockHour: 8)
        let g = DietSemantics.gauges(for: today, hour: hour)
        XCTAssertNotNil(g.protein.flag, "the after-4pm protein nag resolves at end-of-day")
    }

    // MARK: - NeutralMode labels

    private let en = Locale(identifier: "en_US")

    func testNeutralCaloriesCenterIsEatenTotal() {
        let totals = MacroTotals(cal: 1840, p: 120, f: 60, c: 190, fiber: 20)
        XCTAssertEqual(NeutralMode.caloriesCenter(totals, locale: en), "1,840 eaten")
    }

    func testNeutralCaloriesCaptionOnlyWhenBurnExists() {
        XCTAssertNil(NeutralMode.caloriesCaption(net: NetCalories(intake: 1840, burned: 0), locale: en),
                     "no burn → no caption")
        XCTAssertEqual(NeutralMode.caloriesCaption(net: NetCalories(intake: 1840, burned: 420), locale: en),
                       "420 burned · 1,420 net")
    }

    func testNeutralMacroCenter() {
        XCTAssertEqual(NeutralMode.macroCenter(142), "142g")
        XCTAssertEqual(NeutralMode.macroCenter(0), "0g")
    }

    // MARK: - HistoryUI visibility rules

    func testModePerFidelity() {
        XCTAssertEqual(HistoryUI.mode(fidelity: .live), .full)
        XCTAssertEqual(HistoryUI.mode(fidelity: .archived), .full)
        XCTAssertEqual(HistoryUI.mode(fidelity: .reconstructed), .neutral)
    }

    func testPastDaySuppressesStaleBannerAndHidesRowsAndQuickLog() {
        XCTAssertTrue(HistoryUI.suppressesStaleBanner(isHistorical: true))
        XCTAssertFalse(HistoryUI.suppressesStaleBanner(isHistorical: false))
        XCTAssertFalse(HistoryUI.showsCurrentStateRows(isHistorical: true), "Coach/Progress hidden on a past day")
        XCTAssertTrue(HistoryUI.showsCurrentStateRows(isHistorical: false))
        XCTAssertFalse(HistoryUI.showsQuickLog(isHistorical: true), "quick log hidden on a past day")
        XCTAssertTrue(HistoryUI.showsQuickLog(isHistorical: false))
    }

    func testFooterTextPerFidelity() {
        XCTAssertEqual(HistoryUI.footer(isHistorical: false, fidelity: .live, updated: "15:34"), "Updated 15:34")
        XCTAssertEqual(HistoryUI.footer(isHistorical: true, fidelity: .archived, updated: nil), "Archived day")
        XCTAssertEqual(HistoryUI.footer(isHistorical: true, fidelity: .reconstructed, updated: nil), "Rebuilt from logs")
        XCTAssertNil(HistoryUI.footer(isHistorical: false, fidelity: .live, updated: nil), "no mtime → no footer today")
    }
}
