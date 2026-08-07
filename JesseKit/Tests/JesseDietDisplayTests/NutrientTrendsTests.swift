import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The pure trend engine + single-source nutrient model. Every rule is unknown-aware: a
// GAP day (nutrient key absent) is never a 0, never a day under a floor/over a ceiling,
// and never plotted. Coverage (known / logged days in window) rides alongside every
// verdict. Deterministic — dates are fixtures, never `Date()`.

@MainActor
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

    // MARK: - Per-day goal status → color (chart coloring)

    // Each plotted day colors by the SAME status band the daily gauge uses, so the trend dot
    // and the Today bar never disagree. Floor, ceiling, and window each map through their own
    // band; informational and no-target days stay neutral; a partial day only asserts the
    // breach its lower bound already proves.

    func testFloorDayStatusMatchesDailyFloorBands() {
        // Protein floor 190: <50% red, 50–80% yellow, ≥80% green (DietSemantics.floorStatus).
        let target = 190.0
        func s(_ v: Double) -> DietSemantics.Status {
            N.dayStatus(.p, value: v, isPartial: false, target: target)
        }
        XCTAssertEqual(s(90), .red, "under half the floor is a miss")
        XCTAssertEqual(s(150), .yellow, "approaching the floor is the amber band")
        XCTAssertEqual(s(190), .green, "at the floor is met")
        XCTAssertEqual(s(210), .green, "over the floor is met")
        // The color leg: the band maps through the app's shared palette.
        XCTAssertEqual(statusColor(s(90)), .red)
        XCTAssertEqual(statusColor(s(150)), .orange)
        XCTAssertEqual(statusColor(s(210)), .green)
    }

    func testCeilingDayStatusMatchesDailyCeilingBands() {
        // Sodium ceiling 2300: <80% green, 80–100% yellow, >100% red (DietSemantics.ceilingStatus).
        let target = 2300.0
        func s(_ v: Double) -> DietSemantics.Status {
            N.dayStatus(.na, value: v, isPartial: false, target: target)
        }
        XCTAssertEqual(s(1500), .green, "well under the ceiling is good")
        XCTAssertEqual(s(2000), .yellow, "nearing the ceiling is the amber band")
        XCTAssertEqual(s(2500), .red, "over the ceiling is a miss")
        XCTAssertEqual(statusColor(s(2500)), .red)
    }

    func testWindowDayStatusUsesFixedFatWindowIndependentOfTarget() {
        // Fat is the window: <50 red, 50–65 green, 65–70 yellow, >70 red — fixed grams, so a
        // nil target must NOT neutralize it (unlike floor/ceiling).
        func s(_ v: Double) -> DietSemantics.Status {
            N.dayStatus(.f, value: v, isPartial: false, target: nil)
        }
        XCTAssertEqual(s(40), .red, "under the 50 g hormonal floor")
        XCTAssertEqual(s(60), .green, "inside the 50–65 g window")
        XCTAssertEqual(s(68), .yellow, "between the working and hard cap")
        XCTAssertEqual(s(75), .red, "over the 70 g hard cap")
    }

    func testInformationalAndNoTargetDaysAreNeutral() {
        // Informational nutrients are never judged → neutral regardless of target/value.
        XCTAssertEqual(N.dayStatus(.sug, value: 80, isPartial: false, target: 50), .suspended)
        XCTAssertEqual(N.dayStatus(.unsat, value: 40, isPartial: false, target: nil), .suspended)
        // A floor/ceiling with no usable target makes no claim.
        XCTAssertEqual(N.dayStatus(.p, value: 90, isPartial: false, target: nil), .suspended)
        XCTAssertEqual(N.dayStatus(.na, value: 3000, isPartial: false, target: 0), .suspended)
    }

    func testPartialDayAssertsOnlyTheBreachItsLowerBoundProves() {
        // Floor: a partial value is a lower bound. Already-cleared reads green; still-short is
        // undecided (unknowns could lift it), so neutral — never a false "under floor".
        XCTAssertEqual(N.dayStatus(.p, value: 200, isPartial: true, target: 190), .green)
        XCTAssertEqual(N.dayStatus(.p, value: 90, isPartial: true, target: 190), .suspended)
        // Ceiling: already-breached reads red; still-under is undecided (unknowns could push
        // it over), so neutral — never a false "under ceiling".
        XCTAssertEqual(N.dayStatus(.na, value: 2500, isPartial: true, target: 2300), .red)
        XCTAssertEqual(N.dayStatus(.na, value: 1500, isPartial: true, target: 2300), .suspended)
        // Window: only a lower bound already past the hard cap is proven bad.
        XCTAssertEqual(N.dayStatus(.f, value: 75, isPartial: true, target: nil), .red)
        XCTAssertEqual(N.dayStatus(.f, value: 60, isPartial: true, target: nil), .suspended)
    }

    func testDayStatusPhraseMirrorsTheColorAndHedgesTheUndecided() {
        // The phrase carries the same under/on/over signal as the color (accessibility).
        XCTAssertEqual(N.dayStatusPhrase(.p, value: 210, isPartial: false, target: 190), "at or above floor")
        XCTAssertEqual(N.dayStatusPhrase(.p, value: 90, isPartial: false, target: 190), "under floor")
        XCTAssertEqual(N.dayStatusPhrase(.na, value: 2500, isPartial: false, target: 2300), "over ceiling")
        XCTAssertEqual(N.dayStatusPhrase(.f, value: 60, isPartial: false, target: nil), "in range")
        // No claim where the day carries none: informational, no target, undecided partial.
        XCTAssertNil(N.dayStatusPhrase(.sug, value: 80, isPartial: false, target: 50))
        XCTAssertNil(N.dayStatusPhrase(.p, value: 90, isPartial: true, target: 190))
    }

    // MARK: - Window anchors on the nutrient's own recent tail (sparse nutrients)

    // A rarely-labeled nutrient still charts its recent tail at a short range, instead of
    // reading empty because it happened not to be logged in the last calendar week. The
    // window anchors on the nutrient's OWN most recent reading, not the last day any nutrient
    // was logged.

    func testShortRangeAnchorsOnNutrientsOwnLastReadingNotGlobalLastLoggedDay() {
        // 40 logged days (calories known daily → the series' last day is the newest LOG).
        // Omega-3 is known only on days 10–17 (≈3 weeks before the last log) and never since.
        let d = dates(from: "2026-06-10", count: 40)
        var series: [NutrientDay] = []
        for (i, date) in d.enumerated() {
            var n: [String: NutrientDayValue] = ["cal": val(2000, known: 6)]
            if (10...17).contains(i) { n["o3"] = val(500, known: 2) }
            series.append(NutrientDay(date: date, nutrients: n))
        }
        let t = targets { $0.omega3 = 500 }
        // 7-day range anchors on omega-3's own last reading (day 17), so it shows its recent
        // tail (days 11–17) rather than an empty last-calendar-week window.
        let w7 = N.analyze(series, nutrient: .o3, targets: t, windowDays: 7)
        XCTAssertFalse(w7.points.isEmpty, "a sparse nutrient still charts its recent tail at 7d")
        XCTAssertEqual(w7.points.count, 7, "the 7 days ending at the last omega-3 reading")
        XCTAssertEqual(w7.points.last?.date, d[17], "the window ends at the nutrient's last reading")
        XCTAssertEqual(w7.daysInWindow, 7, "the window never spills into later nutrient-less days")
    }

    func testDenseNutrientStillAnchorsOnTheLastLoggedDay() {
        // A daily-logged nutrient's own last reading IS the last logged day, so the macros are
        // unchanged: their short ranges still end on the most recent day.
        let d = dates(from: "2026-06-10", count: 20)
        let series = d.map { NutrientDay(date: $0, nutrients: ["cal": val(2000, known: 6), "p": val(180)]) }
        let t = targets { $0.protein = 190 }
        let w7 = N.analyze(series, nutrient: .p, targets: t, windowDays: 7)
        XCTAssertEqual(w7.points.count, 7)
        XCTAssertEqual(w7.points.last?.date, d[19], "anchored on the most recent day")
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

    // MARK: - Judgment window (which nutrients buffer, and which deliberately don't)

    func testDailyNutrientsAreTheOnesAWeekWouldHide() {
        // Protein and fiber are floors in a deficit: a week's median hides the thin days
        // that are exactly the ones that cost lean mass. Calories and carbs are the day's
        // plan. None of the four may carry a window caption.
        for n in [TrendNutrient.p, .fiber, .cal, .c] {
            XCTAssertEqual(n.judgmentWindow, .daily, "\(n.fullName) must stay judged on the day")
            XCTAssertNil(n.judgmentWindow.days)
            XCTAssertNil(n.judgmentWindow.caption, "a daily gauge has no window to caption")
            XCTAssertFalse(n.judgmentWindow.isRolling)
        }
    }

    func testTheBufferedFatsAndSodiumRollOverAWeek() {
        for n in [TrendNutrient.satf, .na, .f] {
            XCTAssertEqual(n.judgmentWindow, .rolling(days: 7), "\(n.fullName) buffers over a week")
            XCTAssertEqual(n.judgmentWindow.days, 7)
            XCTAssertEqual(n.judgmentWindow.caption, "7d")
            XCTAssertTrue(n.judgmentWindow.isRolling)
        }
    }

    func testTheStoredMineralsRollOverAMonth() {
        for n in [TrendNutrient.ca, .o3, .mg, .k] {
            XCTAssertEqual(n.judgmentWindow, .rolling(days: 30), "\(n.fullName) buffers over a month")
            XCTAssertEqual(n.judgmentWindow.caption, "30d")
        }
    }

    func testEveryNutrientAnswersTheWindowQuestion() {
        // All thirteen, no gaps: the informational pair answer `.daily` because the property
        // is total, and their verdict is never consulted (they carry no `dayGoal`).
        let expected: [TrendNutrient: JudgmentWindow] = [
            .cal: .daily, .p: .daily, .c: .daily, .fiber: .daily,
            .satf: .rolling(days: 7), .na: .rolling(days: 7), .f: .rolling(days: 7),
            .ca: .rolling(days: 30), .o3: .rolling(days: 30),
            .mg: .rolling(days: 30), .k: .rolling(days: 30),
            .sug: .daily, .unsat: .daily,
        ]
        XCTAssertEqual(expected.count, TrendNutrient.allCases.count)
        for n in TrendNutrient.allCases {
            XCTAssertEqual(n.judgmentWindow, expected[n], "\(n.fullName)")
        }
        XCTAssertNil(TrendNutrient.sug.dayGoal, "informational — no verdict to window")
        XCTAssertNil(TrendNutrient.unsat.dayGoal)
    }

    // MARK: - Rolling verdict (the gauge's colour)

    /// A 7-day saturated-fat series with the given per-day values (nil = a GAP day, which
    /// still logged food). Ends on the most recent date, so the 7-day window covers it all.
    private func satfWeek(_ values: [Double?]) -> [NutrientDay] {
        let d = dates(from: "2026-07-01", count: values.count)
        return zip(d, values).map { date, v in
            var nutrients: [String: NutrientDayValue] = ["cal": val(2000, known: 5)]
            if let v { nutrients["satf"] = val(v) }
            return NutrientDay(date: date, nutrients: nutrients)
        }
    }

    func testCeilingRollingGreenEvenWhenTodayIsOver() {
        // Median of the week is 15 g against a 22 g ceiling (68% — comfortably under), while
        // TODAY sits at 34 g. The colour follows the week; the daily band would have been red.
        let series = satfWeek([10, 12, 14, 15, 16, 18, 34])
        let t = targets { $0.satFat = 22 }
        let j = N.judgment(for: .satf, todayValue: 34, series: series, targets: t)
        XCTAssertEqual(j.status, .green)
        XCTAssertEqual(j.judgedValue, 15, "the median of the known days, not today")
        XCTAssertEqual(j.daysKnown, 7)
        XCTAssertEqual(j.source, .rolling(caption: "7d", daysKnown: 7))
        XCTAssertTrue(j.source.isRolling)
        // The single-day path it replaced still reads red on today's number.
        XCTAssertEqual(DietSemantics.ceilingStatus(value: 34, target: 22), .red)
    }

    func testCeilingRollingRedEvenWhenTodayIsUnder() {
        // The mirror: a week that sits over the ceiling stays red on a good day.
        let series = satfWeek([30, 32, 28, 26, 31, 29, 10])
        let t = targets { $0.satFat = 22 }
        let j = N.judgment(for: .satf, todayValue: 10, series: series, targets: t)
        XCTAssertEqual(j.status, .red)
        XCTAssertEqual(j.judgedValue, 29)
        XCTAssertEqual(DietSemantics.ceilingStatus(value: 10, target: 22), .green,
                       "today alone would have read green")
    }

    func testRollingMedianIsOverKnownDaysOnlyAndNeverCountsAGap() {
        // Two GAP days inside the window: they are neither 0 nor a low day. The median is
        // over the five KNOWN days (28, 29, 30, 31, 32 → 30), not over seven with phantom 0s.
        let series = satfWeek([28, nil, 29, 30, nil, 31, 32])
        let t = targets { $0.satFat = 22 }
        let month = N.analyze(series, nutrient: .satf, targets: t, windowDays: 7)
        XCTAssertEqual(month.daysKnown, 5)
        XCTAssertEqual(month.daysInWindow, 7, "the gap days still logged food")
        XCTAssertEqual(month.median, 30)
        // Five known days is below the engine's floor, so no pattern may be asserted.
        let j = N.judgment(for: .satf, todayValue: 32, series: series, targets: t)
        XCTAssertEqual(j.source, .thinWindow(caption: "7d", daysKnown: 5))
    }

    func testFloorRollingIsTheMirrorOverThirtyDays() {
        // Magnesium known on 8 of 30 days, median 150 against a 400 mg floor → red, even
        // though TODAY cleared the floor outright.
        let d = dates(from: "2026-06-10", count: 30)
        let series = d.enumerated().map { i, date -> NutrientDay in
            var nutrients: [String: NutrientDayValue] = ["cal": val(2000, known: 5)]
            if i >= 22 { nutrients["mg"] = val(i == 29 ? 500 : 150) }
            return NutrientDay(date: date, nutrients: nutrients)
        }
        let t = targets { $0.magnesium = 400 }
        let j = N.judgment(for: .mg, todayValue: 500, series: series, targets: t)
        XCTAssertEqual(j.status, .red)
        XCTAssertEqual(j.judgedValue, 150)
        XCTAssertEqual(j.source, .rolling(caption: "30d", daysKnown: 8))
        XCTAssertEqual(DietSemantics.floorStatus(value: 500, target: 400), .green,
                       "today alone would have read green")
    }

    func testThinWindowFallsBackToTodayAndSaysSo() {
        // Five known days is one short of the engine's minimum, so the verdict is TODAY's
        // band and the source records that the window was too thin to speak.
        XCTAssertEqual(N.minKnownForDirection, 6)
        let series = satfWeek([10, 12, 14, 15, 16, nil, nil])
        let t = targets { $0.satFat = 22 }
        let j = N.judgment(for: .satf, todayValue: 40, series: series, targets: t)
        XCTAssertEqual(j.source, .thinWindow(caption: "7d", daysKnown: 5))
        XCTAssertTrue(j.source.isThinWindow)
        XCTAssertFalse(j.source.isRolling)
        XCTAssertEqual(j.status, DietSemantics.ceilingStatus(value: 40, target: 22))
        XCTAssertEqual(j.judgedValue, 40, "the fallback judges today's number")
    }

    func testDailyNutrientsAreUnchangedByAnySeries() {
        // A protein series that would read green over a week must not colour a thin day:
        // the daily nutrients never consult the history at all.
        let d = dates(from: "2026-07-01", count: 7)
        let series = d.map { NutrientDay(date: $0, nutrients: ["p": val(200)]) }
        let t = targets { $0.protein = 190; $0.fiber = 38 }
        let p = N.judgment(for: .p, todayValue: 40, series: series, targets: t)
        XCTAssertEqual(p.source, .daily)
        XCTAssertEqual(p.status, DietSemantics.floorStatus(value: 40, target: 190))
        XCTAssertEqual(p.status, .red)
        XCTAssertEqual(p.judgedValue, 40)
        let fiber = N.judgment(for: .fiber, todayValue: 10, series: series, targets: t)
        XCTAssertEqual(fiber.source, .daily)
        XCTAssertEqual(fiber.status, DietSemantics.floorStatus(value: 10, target: 38))
    }

    func testNoSeriesMeansEveryNutrientIsJudgedOnTheDay() {
        // An older bridge sends no `nutrientSeries` — every nutrient degrades to the
        // single-day band, with no caption and no crash.
        let t = targets { $0.satFat = 22; $0.magnesium = 400 }
        for (n, value) in [(TrendNutrient.satf, 34.0), (.mg, 150.0), (.f, 80.0)] {
            for series in [nil, []] as [[NutrientDay]?] {
                let j = N.judgment(for: n, todayValue: value, series: series, targets: t)
                XCTAssertEqual(j.source, .daily, "\(n.fullName)")
                XCTAssertNil(j.source.caption)
                XCTAssertEqual(j.judgedValue, value)
            }
        }
    }

    func testTotalFatRollsTheFixedWindowAgainstTheMedian() {
        // Total fat reuses the 50–65 g window (its hard cap at 70) against the week's
        // median: a 58 g median reads green through a single 95 g day.
        let d = dates(from: "2026-07-01", count: 7)
        let values: [Double] = [55, 57, 58, 58, 60, 62, 95]
        let series = zip(d, values).map { NutrientDay(date: $0, nutrients: ["f": val($1)]) }
        let j = N.judgment(for: .f, todayValue: 95, series: series, targets: DietTargets())
        XCTAssertEqual(j.judgedValue, 58)
        XCTAssertEqual(j.status, .green)
        XCTAssertFalse(j.hardOver, "the MEDIAN is nowhere near the 70 g cap")
        XCTAssertEqual(j.source, .rolling(caption: "7d", daysKnown: 7))
    }

    // MARK: - Same-day blow-out (a separate signal from the rolling verdict)

    func testBlowoutFiresAtTheMultiplierAndNotJustUnderIt() throws {
        let t = targets { $0.satFat = 20 }
        XCTAssertEqual(N.blowoutMultiplier, 1.5)
        let hit = try XCTUnwrap(N.blowout(.satf, todayValue: 30, targets: t))
        XCTAssertEqual(hit.multiple, 1.5)
        XCTAssertEqual(hit.value, 30)
        XCTAssertFalse(hit.overHardCap)
        XCTAssertNil(N.blowout(.satf, todayValue: 29.8, targets: t), "1.49x is not a blow-out")
    }

    func testBlowoutCatchesTheRealDayAndLeavesTheMildOneAlone() {
        // The tuning claim, asserted: against a 22 g target a 34 g day is named and a mild
        // 25 g day is not.
        let t = targets { $0.satFat = 22 }
        XCTAssertNotNil(N.blowout(.satf, todayValue: 34, targets: t))
        XCTAssertNil(N.blowout(.satf, todayValue: 25, targets: t))
    }

    func testHardCapTriggersIndependentlyOfAnyTarget() throws {
        // Total fat has no ceiling target at all — its same-day line is the 70 g hard cap.
        XCTAssertEqual(TrendNutrient.f.dailyHardCap, DietSemantics.fatHardCap)
        let hit = try XCTUnwrap(N.blowout(.f, todayValue: 78, targets: DietTargets()))
        XCTAssertTrue(hit.overHardCap)
        XCTAssertNil(hit.multiple, "fat is judged against the cap, not a multiple")
        XCTAssertNil(N.blowout(.f, todayValue: 70, targets: DietTargets()), "at the cap is not over it")
    }

    func testAFloorNutrientCanNeverBlowOut() {
        let t = targets { $0.magnesium = 400; $0.sugar = 50 }
        XCTAssertFalse(TrendNutrient.mg.hasSameDayCeiling)
        XCTAssertNil(N.blowout(.mg, todayValue: 4000, targets: t))
        XCTAssertNil(N.blowout(.sug, todayValue: 500, targets: t), "informational — no line to cross")
    }

    func testBlowoutDoesNotMoveTheRollingVerdict() {
        // The same green week as above, with today at 34 g: the verdict stays green AND the
        // blow-out is flagged. Both signals, neither overwriting the other.
        let series = satfWeek([10, 12, 14, 15, 16, 18, 34])
        let t = targets { $0.satFat = 22 }
        let j = N.judgment(for: .satf, todayValue: 34, series: series, targets: t)
        XCTAssertEqual(j.status, .green)
        XCTAssertNotNil(N.blowout(.satf, todayValue: 34, targets: t))
    }

    // MARK: - Coach grounding: the same-day line

    private func hotMeals() -> [DietMeal] {
        [DietMeal(name: "Dinner", time: "19:00", items: [
            DietItem(item: "Cheese board", na: 900, satf: 34),
            DietItem(item: "Bread"), // unknown — never a 0, never inflates the day
        ])]
    }

    func testBlowoutLineNamesTheDayAndItsMultiple() throws {
        let t = targets { $0.satFat = 22; $0.sodium = 2300 }
        let line = try XCTUnwrap(N.blowoutLine(meals: hotMeals(), targets: t))
        XCTAssertTrue(line.hasPrefix("TODAY RAN HOT"))
        XCTAssertTrue(line.contains("saturated fat 34 g (1.5x the 22 g target)"), line)
        XCTAssertFalse(line.contains("sodium"), "900 mg against a 2300 mg ceiling is not hot")
    }

    func testBlowoutLineIsAbsentOnAnOrdinaryDay() {
        let t = targets { $0.satFat = 22; $0.sodium = 2300 }
        let meals = [DietMeal(name: "Dinner", time: "19:00", items: [
            DietItem(item: "Chicken and rice", na: 700, satf: 6),
        ])]
        XCTAssertNil(N.blowoutLine(meals: meals, targets: t))
    }

    func testBlowoutLineNamesAHardCapBreachInItsOwnWords() throws {
        let meals = [DietMeal(name: "Dinner", time: nil, items: [DietItem(item: "Fry-up", f: 78, satf: 8)])]
        let t = targets { $0.satFat = 22 }
        let line = try XCTUnwrap(N.blowoutLine(meals: meals, targets: t))
        XCTAssertTrue(line.contains("total fat 78 g (over the 70 g cap)"), line)
    }

    func testCoachRollupCarriesTheSameDayLineAlongsideTheWindows() {
        let t = targets { $0.magnesium = 400; $0.satFat = 22 }
        let rollup = N.coachRollup(series: coachSeries(), targets: t, meals: hotMeals())
        XCTAssertTrue(rollup.contains("TODAY RAN HOT"))
        XCTAssertTrue(rollup.contains("Magnesium"), "the rolling rollup is still there")
        XCTAssertLessThanOrEqual(rollup.utf8.count, N.coachRollupBudget)
        // An ordinary day adds nothing.
        let calm = N.coachRollup(series: coachSeries(), targets: t, meals: [])
        XCTAssertFalse(calm.contains("TODAY RAN HOT"))
    }

    func testTightBudgetDropsInformationalLinesBeforeTheSameDayLine() {
        // A budget too small for the whole set: the one-day line survives and the
        // lower-priority nutrient lines are the ones that go.
        let t = targets { $0.magnesium = 400; $0.satFat = 22; $0.sugar = 50 }
        let series = coachSeries().map { day -> NutrientDay in
            var n = day.nutrients
            n["sug"] = val(60)
            n["unsat"] = val(30)
            return NutrientDay(date: day.date, nutrients: n)
        }
        let rollup = N.coachRollup(series: series, targets: t, meals: hotMeals(), budgetBytes: 900)
        XCTAssertTrue(rollup.contains("TODAY RAN HOT"), rollup)
        XCTAssertTrue(rollup.contains("truncated"))
        XCTAssertFalse(rollup.contains("Total Sugars"), "informational lines go first")
        XCTAssertFalse(rollup.contains("Unsaturated Fat"))
        XCTAssertLessThanOrEqual(rollup.utf8.count, 900)
    }
}
