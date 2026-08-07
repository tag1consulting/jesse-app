import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The Health tab's Day / 7d / 30d switcher. The contract under test is narrow on purpose:
// the switcher changes WHICH number a gauge reads (today's total vs the median of the
// window's known days) and the coverage caption, and NOTHING else — same bands, same tone
// mapping, same row. Every count is over known days; a gap is never a low day; a window
// too thin to assert a pattern says "not enough data" rather than picking a colour.
// Deterministic — dates are fixtures, never `Date()`.

@MainActor
final class NutrientWindowsTests: XCTestCase {

    // MARK: - Fixture builders

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `count` consecutive ISO dates starting at `start` (ascending).
    private func dates(from start: String, count: Int) -> [String] {
        let s = Self.fmt.date(from: start)!
        return (0..<count).map { Self.fmt.string(from: Self.cal.date(byAdding: .day, value: $0, to: s)!) }
    }

    private func val(_ sum: Double, known: Int = 1, unknown: Int = 0) -> NutrientDayValue {
        NutrientDayValue(sum: sum, known: known, unknown: unknown)
    }

    private func targets(_ t: (inout DietTargets) -> Void) -> DietTargets {
        var d = DietTargets(); t(&d); return d
    }

    /// A run of logged days that always carry calories, with one other nutrient supplied
    /// per day by `extra` (nil = a GAP for that nutrient on that day).
    private func series(days: Int, from start: String = "2026-07-01", calories: Double = 2000,
                        key: String, extra: (Int) -> Double?) -> [NutrientDay] {
        let d = dates(from: start, count: days)
        return (0..<days).map { i in
            var n: [String: NutrientDayValue] = ["cal": val(calories, known: 5)]
            if let v = extra(i) { n[key] = val(v, known: 4) }
            return NutrientDay(date: d[i], nutrients: n)
        }
    }

    // MARK: - The mode itself

    func testModeSpellsItsOwnTitlesAndWindows() {
        XCTAssertEqual(NutrientWindowMode.allCases, [.day, .week, .month])
        XCTAssertEqual(NutrientWindowMode.day.title, "Day")
        XCTAssertEqual(NutrientWindowMode.week.title, "7d")
        XCTAssertEqual(NutrientWindowMode.month.title, "30d")
        XCTAssertNil(NutrientWindowMode.day.days)
        XCTAssertEqual(NutrientWindowMode.week.days, 7)
        XCTAssertEqual(NutrientWindowMode.month.days, 30)
        XCTAssertFalse(NutrientWindowMode.day.isRolling)
        XCTAssertTrue(NutrientWindowMode.week.isRolling)
    }

    func testTrendChartOpensOnTheRangeMatchingTheMode() {
        XCTAssertEqual(NutrientTrendDetail.Range.matching(.week), .d7)
        XCTAssertEqual(NutrientTrendDetail.Range.matching(.month), .d30)
        // The Day mode has no matching rolling range, so the chart keeps its own default.
        XCTAssertEqual(NutrientTrendDetail.Range.matching(.day), .d30)
    }

    // MARK: - The headline case: red today, green over the week

    func testCaloriesOverTargetTodayReadRedOnTheDayAndGreenOverSevenDays() {
        // Calories are judged DAILY (the day's plan is judged against the day it belongs
        // to), so today's blown ceiling is red on the Day read — and stays red no matter
        // what the week looks like.
        // A week of comfortable days at 1700 (77% of the 2200 ceiling → green) behind a
        // 2600 blowout today (118% → red).
        let t = targets { $0.calories = 2200 }
        let week = series(days: 7, calories: 1700, key: "cal") { _ in nil }

        let day = NutrientTrends.judgment(for: .cal, todayValue: 2600, series: week, targets: t)
        XCTAssertEqual(day.status, .red, "today's 2600 is over the 2200 ceiling")
        XCTAssertEqual(day.source, .daily, "calories are judged on the day, never buffered")

        let rolling = NutrientWindows.gauge(.cal, series: week, targets: t, windowDays: 7)
        XCTAssertEqual(rolling.status, .green, "the week's 1700 median sits comfortably under")
        XCTAssertEqual(rolling.tone, .onTrack)
        XCTAssertEqual(rolling.value, 1700, "the rolling row shows the MEDIAN, not today")
        XCTAssertEqual(rolling.windowRead?.chip, "7d")
    }

    // MARK: - Coverage

    func testCoverageCaptionCountsKnownDaysOutOfLoggedDays() {
        // 30 logged days; magnesium measured on the last 22 of them (so its own last
        // reading anchors the window across the whole 30).
        let t = targets { $0.magnesium = 400 }
        let s = series(days: 30, key: "mg") { i in i >= 8 ? 250 : nil }

        let read = NutrientWindows.read(.mg, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(read.daysKnown, 22)
        XCTAssertEqual(read.daysInWindow, 30)
        XCTAssertEqual(read.coverage, "known 22 of 30 logged days")
        XCTAssertEqual(read.median, 250)
        XCTAssertTrue(read.hasVerdict)
        XCTAssertFalse(read.isThin)

        let g = NutrientWindows.gauge(.mg, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(g.remaining, "known 22 of 30 logged days", "coverage is the row's caption")
        XCTAssertEqual(g.value, 250)
        XCTAssertEqual(g.target, 400)
        XCTAssertEqual(g.status, .yellow, "250 is 62% of the 400 floor")
        XCTAssertEqual(g.windowRead?.chip, "30d")
    }

    func testAPartialDayIsCountedInTheCaptionSoAMedianOfLowerBoundsSaysSo() {
        let t = targets { $0.magnesium = 400 }
        let d = dates(from: "2026-07-01", count: 8)
        let s = (0..<8).map { i in
            NutrientDay(date: d[i], nutrients: [
                "cal": val(2000, known: 5),
                "mg": val(300, known: 3, unknown: i < 2 ? 2 : 0),
            ])
        }
        let read = NutrientWindows.read(.mg, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(read.partialCount, 2)
        XCTAssertEqual(read.coverage, "known 8 of 8 logged days · 2 partial")
    }

    // MARK: - Thin coverage claims nothing

    func testAThinWindowSaysNotEnoughDataInsteadOfShowingAColour() {
        // Omega-3 measured on 3 of 30 logged days — below the minimum known-day count, so
        // there is no pattern to assert and no colour to claim.
        let t = targets { $0.omega3 = 500 }
        let s = series(days: 30, key: "o3") { i in i >= 27 ? 100 : nil }

        let read = NutrientWindows.read(.o3, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(read.daysKnown, 3)
        XCTAssertFalse(read.hasVerdict)
        XCTAssertTrue(read.isThin)
        XCTAssertEqual(read.coverage, "not enough data — known 3 of 30 logged days")

        let g = NutrientWindows.gauge(.o3, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(g.status, .suspended, "no band is claimed on a thin window")
        XCTAssertEqual(g.tone, .inProgress, "and therefore no colour")
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertTrue(g.remaining.hasPrefix("not enough data"))
    }

    func testAWindowWithNoKnownDayShowsNoValueAtAllRatherThanAZero() {
        // Calcium never measured inside the window: unknown is not zero, so the row shows
        // the row's "nothing measured" state with a window-specific caption, never a 0 bar.
        let t = targets { $0.calcium = 1000 }
        let s = series(days: 30, key: "ca") { _ in nil }

        let g = NutrientWindows.gauge(.ca, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(g.knownItemCount, 0, "the row's 'nothing measured' state")
        XCTAssertNil(g.fraction, "no bar fill — a 0 bar would read as 'ate none'")
        XCTAssertEqual(g.status, .suspended)
        // The window that found nothing is named, so it isn't confused with "not tracked".
        XCTAssertEqual(g.windowRead?.coverage, "no known days in the last 30 logged days")
        XCTAssertEqual(g.remaining, "no known days in the last 30 logged days")
    }

    // MARK: - Informational nutrients never gain a verdict

    func testInformationalNutrientsShowDistributionAndNeverAVerdictInAnyWindow() {
        // Total sugars carries a reference target and 30 measured days — every ingredient a
        // verdict would need. It still gets none: it is informational in every mode.
        let t = targets { $0.sugar = 60 }
        let d = dates(from: "2026-07-01", count: 30)
        let s = (0..<30).map { i in
            NutrientDay(date: d[i], nutrients: [
                "cal": val(2000, known: 5),
                "sug": val(i % 2 == 0 ? 40 : 90, known: 4),
                "unsat": val(30, known: 4),
            ])
        }
        for window in [7, 30] {
            for nutrient in [TrendNutrient.sug, .unsat] {
                let read = NutrientWindows.read(nutrient, series: s, targets: t, windowDays: window)
                XCTAssertFalse(read.hasVerdict, "\(nutrient.fullName) is never judged")
                XCTAssertFalse(read.isThin, "an informational nutrient is not 'thin', it is unjudged")
                let g = NutrientWindows.gauge(nutrient, series: s, targets: t, windowDays: window)
                XCTAssertEqual(g.status, .suspended, "\(nutrient.fullName) at \(window)d")
                XCTAssertEqual(g.tone, .inProgress, "\(nutrient.fullName) at \(window)d")
                XCTAssertEqual(g.goalStatus, .noGoal)
            }
        }
        // Distribution IS what an informational row is allowed to say, so it leads with it.
        let sugar = NutrientWindows.gauge(.sug, series: s, targets: t, windowDays: 30)
        XCTAssertTrue(sugar.remaining.hasPrefix("range 40–90 g · known "), sugar.remaining)
    }

    func testInformationalNutrientsKeepADirectionGlyphButNeverAColour() {
        // A glyph is a direction, never a verdict: total sugars reads as a ceiling and
        // unsaturated fat as a floor, matching their `Micronutrient` twins.
        XCTAssertEqual(TrendNutrient.sug.displayGoal, .ceiling)
        XCTAssertEqual(TrendNutrient.unsat.displayGoal, .floor)
        XCTAssertEqual(TrendNutrient.p.displayGoal, .floor)
        XCTAssertEqual(TrendNutrient.na.displayGoal, .ceiling)
        XCTAssertEqual(TrendNutrient.f.displayGoal, .window)
    }

    // MARK: - Total fat keeps its own bar reference

    func testTotalFatDrawsAgainstTheSameWorkingCapTheDailyGaugeUses() {
        // The daily fat gauge draws against the fixed 65 g working cap, not the day's fat
        // target. The rolling row must not quietly switch references.
        let t = targets { $0.fat = 55 }
        let s = series(days: 10, key: "f") { _ in 58 }
        let g = NutrientWindows.gauge(.f, series: s, targets: t, windowDays: 7)
        XCTAssertEqual(g.target, DietSemantics.fatCap)
        XCTAssertEqual(g.status, .green, "58 g sits inside the 50–65 g window")
        XCTAssertEqual(g.goal, .window)
    }

    // MARK: - A rolling verdict is judged as a SETTLED reading

    func testARollingShortfallIsNotSoftenedAsIfTheDayWereStillYoung() {
        // A daily floor short before 16:00 reads neutral ("still in progress"). A month-long
        // shortfall is not still in progress, so the rolling tone is a nudge regardless.
        let t = targets { $0.magnesium = 400 }
        let s = series(days: 30, key: "mg") { _ in 150 }
        let g = NutrientWindows.gauge(.mg, series: s, targets: t, windowDays: 30)
        XCTAssertEqual(g.status, .red, "150 is 38% of the 400 floor")
        XCTAssertEqual(g.tone, .nudge, "judged at the settled hour, not softened by nagHour")
    }

    // MARK: - Graceful degrade

    func testNoHistoryMeansNoRollingRowsAndNoConsistencySection() {
        // The gate both the switcher and the Consistency row hang off. An older bridge sends
        // no series at all; the modes simply aren't offered.
        XCTAssertFalse(NutrientTrends.isAvailable(nil))
        XCTAssertFalse(NutrientTrends.isAvailable([]))
        XCTAssertFalse(NutrientStreaks.isAvailable(nil))
        XCTAssertTrue(NutrientWindows.trackedNutrients([]).isEmpty)
        XCTAssertTrue(NutrientWindows.gauges(series: [], targets: DietTargets(), windowDays: 7).isEmpty)
    }

    func testOnlyMeasuredNutrientsGetARollingRow() {
        // Sodium measured, magnesium never: a nutrient the bridge has never carried a value
        // for is omitted rather than shown as a permanent blank.
        let t = targets { $0.sodium = 2300; $0.magnesium = 400 }
        let s = series(days: 10, key: "na") { _ in 1800 }
        let tracked = NutrientWindows.trackedNutrients(s)
        XCTAssertTrue(tracked.contains(.na))
        XCTAssertTrue(tracked.contains(.cal), "calories are measured on every logged day")
        XCTAssertFalse(tracked.contains(.mg))
        // Canonical order is preserved (calories before sodium).
        XCTAssertEqual(tracked, [.cal, .na])

        let rows = NutrientWindows.gauges(series: s, targets: t, windowDays: 7)
        XCTAssertEqual(rows.map(\.nutrient), [.cal, .na])
        XCTAssertEqual(rows.first(where: { $0.nutrient == .na })?.gauge.label, "Sodium")
    }
}
