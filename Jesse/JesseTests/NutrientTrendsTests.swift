import XCTest
@testable import Jesse

// The pure trend engine + single-source nutrient model. Every rule is unknown-aware: a
// GAP day (nutrient key absent) is never a 0, never a day under a floor/over a ceiling,
// and never plotted. Coverage (known / logged days in window) rides alongside every
// verdict. Deterministic — dates are fixtures, never `Date()`.

final class NutrientTrendsTests: XCTestCase {
    typealias N = NutrientTrends

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

    // MARK: - Unknown-aware: gaps are neither 0 nor a breach

    func testGapDayNeverCountsAsZeroOrUnderFloor() {
        // 4 logged days; magnesium known on days 1,2,4 (300, 500, 400) and a GAP on day 3
        // (that day logged food — cal is known — but no item carried magnesium).
        let d = dates(from: "2026-07-01", count: 4)
        let series = [
            NutrientDay(date: d[0], nutrients: ["cal": val(2000, known: 5), "mg": val(300, known: 3, unknown: 2)]),
            NutrientDay(date: d[1], nutrients: ["cal": val(1900, known: 5), "mg": val(500, known: 4)]),
            NutrientDay(date: d[2], nutrients: ["cal": val(2100, known: 5)]), // magnesium GAP
            NutrientDay(date: d[3], nutrients: ["cal": val(2000, known: 5), "mg": val(400, known: 4)]),
        ]
        let t = targets { $0.magnesium = 400 }
        let trend = N.analyze(series, nutrient: .mg, targets: t, windowDays: nil)

        // Median over KNOWN days only — the gap is not a phantom 0 dragging it down.
        XCTAssertEqual(trend.median, 400)
        XCTAssertEqual(trend.points.count, 3, "the gap day plots no point")
        XCTAssertFalse(trend.points.contains { $0.date == d[2] }, "gap day absent from points")
        // Coverage: known on 3 of 4 logged days.
        XCTAssertEqual(trend.daysKnown, 3)
        XCTAssertEqual(trend.daysInWindow, 4)
        // Under the floor: only 300 is under; 400 is AT target (not under); the gap is not
        // counted at all.
        XCTAssertEqual(trend.countUnderTarget, 1)
        XCTAssertEqual(trend.pctUnderTarget, 1.0 / 3.0)
        // The partial day (unknown > 0) is flagged, not dropped.
        XCTAssertTrue(trend.points.first { $0.date == d[0] }?.isPartial ?? false)
        XCTAssertEqual(trend.partialCount, 1)
    }

    // MARK: - Floor / ceiling symmetry

    func testFloorPctUnderCountsOnlyKnownDaysBelow() {
        let d = dates(from: "2026-07-01", count: 3)
        let series = d.enumerated().map { i, date in
            NutrientDay(date: date, nutrients: ["p": val([180, 190, 200][i])])
        }
        let t = targets { $0.protein = 190 }
        let trend = N.analyze(series, nutrient: .p, targets: t, windowDays: nil)
        // 180 under; 190 AT target (not under); 200 over.
        XCTAssertEqual(trend.countUnderTarget, 1)
        XCTAssertEqual(trend.pctUnderTarget, 1.0 / 3.0)
        XCTAssertNil(trend.pctOverTarget, "a floor exposes no over-ceiling pct")
    }

    func testCeilingPctOverIsSymmetric() {
        let d = dates(from: "2026-07-01", count: 3)
        let series = d.enumerated().map { i, date in
            NutrientDay(date: date, nutrients: ["na": val([2000, 2300, 2400][i])])
        }
        let t = targets { $0.sodium = 2300 }
        let trend = N.analyze(series, nutrient: .na, targets: t, windowDays: nil)
        // 2400 over; 2300 AT the ceiling (not over); 2000 under.
        XCTAssertEqual(trend.countOverTarget, 1)
        XCTAssertEqual(trend.pctOverTarget, 1.0 / 3.0)
        XCTAssertNil(trend.pctUnderTarget, "a ceiling exposes no under-floor pct")
    }

    // MARK: - Informational: never a pass/fail

    func testInformationalHasNoJudgmentAndNeutralDirection() {
        let d = dates(from: "2026-07-01", count: 8)
        // Total sugars rising over the window.
        let series = d.enumerated().map { i, date in
            NutrientDay(date: date, nutrients: ["sug": val(Double(20 + i * 5))])
        }
        let t = targets { $0.sugar = 50 } // an optional reference line only
        let trend = N.analyze(series, nutrient: .sug, targets: t, windowDays: nil)
        XCTAssertNil(trend.pctUnderTarget)
        XCTAssertNil(trend.pctOverTarget)
        // Direction is the neutral rising/falling, NEVER improving/worsening.
        XCTAssertEqual(trend.direction, .rising)
        XCTAssertNotEqual(trend.direction, .improving)
        XCTAssertNotEqual(trend.direction, .worsening)
        // The verdict states a distribution, no floor/ceiling verdict.
        let v = N.verdict(trend)
        XCTAssertFalse(v.contains("floor"))
        XCTAssertFalse(v.contains("ceiling"))
    }

    // MARK: - Direction relative to kind

    func testFloorRisingIsImproving() {
        let d = dates(from: "2026-07-01", count: 8)
        let values = [200.0, 210, 220, 230, 300, 310, 320, 330]
        let series = zip(d, values).map { NutrientDay(date: $0, nutrients: ["mg": val($1)]) }
        let t = targets { $0.magnesium = 400 }
        let trend = N.analyze(series, nutrient: .mg, targets: t, windowDays: nil)
        XCTAssertEqual(trend.direction, .improving, "a rising floor is improving")
    }

    func testCeilingRisingIsWorsening() {
        let d = dates(from: "2026-07-01", count: 8)
        let values = [1000.0, 1100, 1200, 1300, 2000, 2100, 2200, 2300]
        let series = zip(d, values).map { NutrientDay(date: $0, nutrients: ["na": val($1)]) }
        let t = targets { $0.sodium = 2300 }
        let trend = N.analyze(series, nutrient: .na, targets: t, windowDays: nil)
        XCTAssertEqual(trend.direction, .worsening, "a rising ceiling is worsening")
    }

    func testBelowMinimumKnownDaysReportsNotEnoughData() {
        let d = dates(from: "2026-07-01", count: 5)
        let series = d.map { NutrientDay(date: $0, nutrients: ["mg": val(250)]) }
        let t = targets { $0.magnesium = 400 }
        let trend = N.analyze(series, nutrient: .mg, targets: t, windowDays: nil)
        XCTAssertEqual(trend.daysKnown, 5)
        XCTAssertEqual(trend.direction, .notEnoughData, "under 6 known days asserts no direction")
    }

    // MARK: - Window coverage

    func testWindowCountsLoggedDaysAsCoverageDenominator() {
        // 30 consecutive logged days; magnesium known every day.
        let d = dates(from: "2026-06-10", count: 30)
        let series = d.map { NutrientDay(date: $0, nutrients: ["cal": val(2000, known: 5), "mg": val(250)]) }
        let t = targets { $0.magnesium = 400 }
        let sevenDay = N.analyze(series, nutrient: .mg, targets: t, windowDays: 7)
        XCTAssertEqual(sevenDay.daysInWindow, 7, "7 calendar days of logs in the window")
        XCTAssertEqual(sevenDay.daysKnown, 7)
        let all = N.analyze(series, nutrient: .mg, targets: t, windowDays: nil)
        XCTAssertEqual(all.daysInWindow, 30)
    }

    // MARK: - Labels (all thirteen, unabbreviated)

    func testAllThirteenFullNamesPresentAndUnabbreviated() {
        let names = Dictionary(uniqueKeysWithValues: TrendNutrient.allCases.map { ($0, $0.fullName) })
        XCTAssertEqual(TrendNutrient.allCases.count, 13)
        XCTAssertEqual(names[.cal], "Calories")
        XCTAssertEqual(names[.p], "Protein")
        XCTAssertEqual(names[.f], "Fat")
        XCTAssertEqual(names[.c], "Carbs")
        XCTAssertEqual(names[.fiber], "Fiber")
        XCTAssertEqual(names[.na], "Sodium")
        XCTAssertEqual(names[.satf], "Saturated Fat")
        XCTAssertEqual(names[.sug], "Total Sugars")
        XCTAssertEqual(names[.k], "Potassium")
        XCTAssertEqual(names[.ca], "Calcium")
        XCTAssertEqual(names[.o3], "Omega-3 (EPA+DHA)")
        XCTAssertEqual(names[.mg], "Magnesium")
        XCTAssertEqual(names[.unsat], "Unsaturated Fat")
        // None is a bare abbreviation.
        for n in TrendNutrient.allCases {
            XCTAssertGreaterThan(n.fullName.count, 2, "\(n.rawValue) name must be a real word")
        }
    }

    // MARK: - Insight content

    func testInsightContentPresentForAllThirteen() {
        for n in TrendNutrient.allCases {
            XCTAssertFalse(n.whyItMatters.isEmpty, "\(n.fullName) missing whyItMatters")
            XCTAssertFalse(n.goodSources.isEmpty, "\(n.fullName) missing goodSources")
            XCTAssertTrue(n.goodSources.allSatisfy { !$0.isEmpty }, "\(n.fullName) has an empty source")
            XCTAssertFalse(n.goodSourcesText.isEmpty)
        }
    }

    // MARK: - Top sources

    func testTopSourcesRankKnownContributorsOnly() {
        let meals = [DietMeal(name: "Dinner", time: "19:00", items: [
            DietItem(item: "Salmon", o3: 500),
            DietItem(item: "Sardines", o3: 300),
            DietItem(item: "Bread"), // no omega-3 → UNKNOWN, never a source
        ])]
        let sources = N.topSources(.o3, meals: meals, limit: 3)
        XCTAssertEqual(sources.map(\.name), ["Salmon", "Sardines"])
        XCTAssertFalse(sources.contains { $0.name == "Bread" }, "an unknown item is never a source")
    }

    func testTopSourcesEmptyWhenNoKnownContributor() {
        let meals = [DietMeal(name: "Lunch", time: nil, items: [DietItem(item: "Bread")])]
        XCTAssertTrue(N.topSources(.o3, meals: meals, limit: 3).isEmpty, "no guess when nothing known")
    }

    // MARK: - Coach multi-window rollup

    /// A 30-day series: magnesium under its floor every day (a standing problem), calcium
    /// known on only 3 recent days (thin coverage).
    private func coachSeries() -> [NutrientDay] {
        let d = dates(from: "2026-06-10", count: 30)
        return d.enumerated().map { i, date in
            var nutrients: [String: NutrientDayValue] = ["cal": val(2000, known: 5), "mg": val(250)]
            if i >= 27 { nutrients["ca"] = val(500) } // last 3 days only
            return NutrientDay(date: date, nutrients: nutrients)
        }
    }

    func testCoachLineCountsAcrossWindows() {
        let t = targets { $0.magnesium = 400 }
        let line = N.coachLine(coachSeries(), nutrient: .mg, targets: t)
        XCTAssertEqual(line,
            "Magnesium (floor 400 mg): 7d median 250 known 7/7 under 7/7; "
            + "30d median 250 known 30/30 under 30/30; all median 250 known 30/30 under 30/30.")
    }

    func testCoachLineThinCoverageSaysInsufficientData() {
        let t = targets { $0.calcium = 1200 }
        let line = try? XCTUnwrap(N.coachLine(coachSeries(), nutrient: .ca, targets: t))
        // Calcium known on only 3 days → every window is under the minimum coverage.
        XCTAssertEqual(line, "Calcium (floor 1200 mg): 7d insufficient data; 30d insufficient data; all insufficient data.")
    }

    func testCoachRollupCarriesStandingProblemGrounding() {
        let t = targets { $0.magnesium = 400; $0.calcium = 1200 }
        let meals = [DietMeal(name: "Snack", time: nil, items: [
            DietItem(item: "Pumpkin seeds", mg: 150),
            DietItem(item: "Spinach", mg: 80),
            DietItem(item: "Cracker"), // unknown magnesium — never a source
        ])]
        let rollup = N.coachRollup(series: coachSeries(), targets: t, meals: meals)
        // The framing sentence sets the intent and the daily instruction.
        XCTAssertTrue(rollup.contains("known days only"))
        XCTAssertTrue(rollup.contains("standing problem"))
        // Magnesium is a standing shortfall → its consequence, real sources, and good
        // sources all ride along.
        XCTAssertTrue(rollup.contains(TrendNutrient.mg.whyItMatters))
        XCTAssertTrue(rollup.contains("Pumpkin seeds"))
        XCTAssertFalse(rollup.contains("Cracker"), "an unknown item never appears as a source")
        XCTAssertTrue(rollup.contains(TrendNutrient.mg.goodSourcesText))
        // Stays within budget.
        XCTAssertLessThanOrEqual(rollup.utf8.count, N.coachRollupBudget)
    }

    func testCoachRollupTruncatesUnderTightBudget() {
        let t = targets { $0.magnesium = 400 }
        // A budget above the framing but too small for every block → truncation note, and
        // the standing problem is retained.
        let rollup = N.coachRollup(series: coachSeries(), targets: t, meals: [], budgetBytes: 800)
        XCTAssertTrue(rollup.contains("truncated"), "an oversized set says it was truncated")
        XCTAssertTrue(rollup.contains("Magnesium"), "the standing problem is kept, not dropped")
    }

    func testCoachRollupEmptyWhenNoSeries() {
        XCTAssertEqual(N.coachRollup(series: [], targets: DietTargets(), meals: []), "")
    }

    // MARK: - Verdict

    func testVerdictReadsSensiblyForAShortFloor() {
        let t = targets { $0.magnesium = 400 }
        let trend = N.analyze(coachSeries(), nutrient: .mg, targets: t, windowDays: 30)
        let v = N.verdict(trend)
        XCTAssertTrue(v.hasPrefix("Magnesium: known on 30 of the last 30 logged days."))
        XCTAssertTrue(v.contains("400 mg floor"))
        XCTAssertTrue(v.contains("Under the floor on 30 of 30 known days"))
        XCTAssertTrue(v.contains("consistent gap"))
    }

    func testVerdictHandlesEmptyRange() {
        let series = [NutrientDay(date: "2026-07-01", nutrients: ["cal": val(2000)])]
        let trend = N.analyze(series, nutrient: .mg, targets: DietTargets(), windowDays: 30)
        XCTAssertFalse(trend.hasData)
        XCTAssertTrue(N.verdict(trend).contains("no known"))
    }
}
