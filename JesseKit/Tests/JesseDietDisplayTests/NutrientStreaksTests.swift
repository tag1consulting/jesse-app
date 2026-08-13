import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The consistency engine. The rule the whole file exists to protect: a day a nutrient
// wasn't measured is a GAP — it does NOT break a streak (you may well have hit the goal,
// the label just didn't say) and it does NOT extend one (a day nobody measured is not a day
// you can claim). A PARTIAL day only decides the direction its lower bound already proves.
// Deterministic — dates are fixtures, never `Date()`.

@MainActor
final class NutrientStreaksTests: XCTestCase {

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

    private func dates(from start: String, count: Int) -> [String] {
        let s = Self.fmt.date(from: start)!
        return (0..<count).map { Self.fmt.string(from: Self.cal.date(byAdding: .day, value: $0, to: s)!) }
    }

    private func targets(_ t: (inout DietTargets) -> Void) -> DietTargets {
        var d = DietTargets(); t(&d); return d
    }

    /// One logged day per entry in `values`. A nil entry is a GAP for that nutrient (the key
    /// is absent) while the day itself is still logged — calories are always present, which
    /// is what makes it a logged day rather than no day at all. `partialAt` marks the
    /// indices whose value is a LOWER BOUND (some items carried no value).
    private func series(_ key: String, _ values: [Double?], partialAt: Set<Int> = [],
                        from start: String = "2026-07-01") -> [NutrientDay] {
        let d = dates(from: start, count: values.count)
        return values.enumerated().map { i, v in
            var n: [String: NutrientDayValue] = ["cal": NutrientDayValue(sum: 2000, known: 5, unknown: 0)]
            if let v {
                n[key] = NutrientDayValue(sum: v, known: 4, unknown: partialAt.contains(i) ? 2 : 0)
            }
            return NutrientDay(date: d[i], nutrients: n)
        }
    }

    // MARK: - A floor held

    func testARunOfKnownDaysMeetingAFloorGivesTheCurrentAndLongestStreak() {
        let t = targets { $0.protein = 140 }
        // Two met, one miss, then five met — the current run is the tail, the longest is the
        // tail too (5 > 2).
        let s = series("p", [150, 160, 90, 145, 150, 155, 141, 200])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.current, 5)
        XCTAssertEqual(streak.longest, 5)
        XCTAssertEqual(streak.daysJudged, 8)
        XCTAssertEqual(streak.daysLogged, 8)
        XCTAssertTrue(streak.hasData)
        XCTAssertFalse(streak.isSparse)
    }

    func testAGapBetweenTwoMetDaysDoesNotBreakTheStreak() {
        let t = targets { $0.protein = 140 }
        // Days 1-3 met, day 4 NOT MEASURED, days 5-6 met. The gap is skipped over: the run
        // is 5 met days, not 3 then 2.
        let s = series("p", [150, 150, 150, nil, 150, 150])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.current, 5, "the unmeasured day neither breaks nor extends")
        XCTAssertEqual(streak.longest, 5)
        XCTAssertEqual(streak.daysKnown, 5)
        XCTAssertEqual(streak.daysLogged, 6, "the gap day WAS logged — it counts as coverage")
        XCTAssertNil(streak.lastMissDate)
    }

    func testAKnownMissDoesBreakTheStreak() {
        let t = targets { $0.protein = 140 }
        // Same shape as above, but day 4 was measured and came in under the floor.
        let s = series("p", [150, 150, 150, 90, 150, 150])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.current, 2, "a measured miss ends the run")
        XCTAssertEqual(streak.longest, 3)
        XCTAssertEqual(streak.lastMissDate, "2026-07-04")
    }

    // MARK: - Days since the last miss

    func testDaysSinceTheLastMissIsCorrectForAFloor() {
        let t = targets { $0.protein = 140 }
        // Miss on 2026-07-03; the series' last logged day is 2026-07-10, seven days later.
        // Two of the days between were never measured, so the measured count is smaller —
        // and both numbers are reported, because they answer different questions.
        let s = series("p", [150, 150, 90, 150, nil, 150, nil, 150, 150, 150])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.lastMissDate, "2026-07-03")
        XCTAssertEqual(streak.calendarDaysSinceLastMiss, 7)
        XCTAssertEqual(streak.knownDaysSinceLastMiss, 5)
        XCTAssertEqual(streak.current, 5)
        XCTAssertTrue(streak.lastMissLine.hasPrefix("7 days since the last miss (2026-07-03"),
                      streak.lastMissLine)
        XCTAssertTrue(streak.lastMissLine.contains("5 measured days since"), streak.lastMissLine)
    }

    func testDaysSinceTheLastMissIsCorrectForACeiling() {
        let t = targets { $0.sodium = 2300 }
        // A ceiling misses by going OVER. 2026-07-02 is the last day over 2300.
        let s = series("na", [1800, 3400, 2000, 1900, 2300, 1500])
        let streak = NutrientStreaks.streak(.na, series: s, targets: t)

        XCTAssertEqual(streak.lastMissDate, "2026-07-02")
        XCTAssertEqual(streak.calendarDaysSinceLastMiss, 4)
        XCTAssertEqual(streak.knownDaysSinceLastMiss, 4)
        XCTAssertEqual(streak.current, 4, "exactly at the ceiling still meets it")
        XCTAssertEqual(streak.longest, 4)
    }

    func testAMissOnTheMostRecentDaySaysSoInsteadOfZeroDaysSince() {
        let t = targets { $0.protein = 140 }
        // The miss IS the last logged day. "0 days since the last miss" is true and useless.
        let s = series("p", [150, 150, 90])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.current, 0)
        XCTAssertEqual(streak.calendarDaysSinceLastMiss, 0)
        XCTAssertEqual(streak.lastMissLine, "missed on the most recent logged day (2026-07-03)")
    }

    func testNoMissAmongTheKnownDaysSaysSoWithoutClaimingACleanRunItCannotSee() {
        let t = targets { $0.sodium = 2300 }
        let s = series("na", [1800, 1900, nil, 2000, 1700])
        let streak = NutrientStreaks.streak(.na, series: s, targets: t)

        XCTAssertNil(streak.lastMissDate)
        XCTAssertNil(streak.calendarDaysSinceLastMiss)
        XCTAssertEqual(streak.lastMissLine, "no miss in the 4 measured days",
                       "the claim is bounded by what was measured, not by the calendar")
    }

    // MARK: - Nothing measured

    func testASeriesWithNoKnownDaysYieldsNoStreakAndACoverageNote() {
        let t = targets { $0.calcium = 1000 }
        // Ten logged days, calcium never measured on any of them.
        let s = series("ca", Array(repeating: nil, count: 10))
        let streak = NutrientStreaks.streak(.ca, series: s, targets: t)

        XCTAssertEqual(streak.current, 0)
        XCTAssertEqual(streak.longest, 0)
        XCTAssertEqual(streak.daysKnown, 0)
        XCTAssertEqual(streak.daysJudged, 0)
        XCTAssertFalse(streak.hasData)
        XCTAssertTrue(streak.isSparse)
        XCTAssertEqual(streak.coverageNote, "not measured on any of the 10 logged days yet")
        XCTAssertEqual(streak.lastMissLine, "no measured days yet")
        // And it never reaches the list — an unmeasured nutrient is omitted, not zeroed.
        XCTAssertFalse(NutrientStreaks.all(series: s, targets: t).contains { $0.nutrient == .ca })
    }

    func testAnEmptySeriesIsSafeRatherThanACrash() {
        let streak = NutrientStreaks.streak(.p, series: [], targets: DietTargets())
        XCTAssertEqual(streak.current, 0)
        XCTAssertEqual(streak.daysLogged, 0)
        XCTAssertEqual(streak.coverageNote, "nothing logged yet")
        XCTAssertTrue(NutrientStreaks.all(series: [], targets: DietTargets()).isEmpty)
        XCTAssertNil(NutrientStreaks.subtitle([]))
    }

    // MARK: - Partial days claim only what they prove

    func testAPartialFloorDayUnderTheTargetIsUndecidedNotAMiss() {
        let t = targets { $0.protein = 140 }
        // Day 3 reads 90 g but two of its items carried no protein value — the unmeasured
        // ones could easily carry it over 140, so it proves nothing and behaves like a gap.
        let s = series("p", [150, 150, 90, 150, 150], partialAt: [2])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)

        XCTAssertEqual(streak.current, 4, "an undecided partial day neither breaks nor extends")
        XCTAssertEqual(streak.daysKnown, 5, "it WAS measured, in part")
        XCTAssertEqual(streak.daysJudged, 4, "but it produced no verdict")
        XCTAssertNil(streak.lastMissDate)
    }

    func testAPartialFloorDayAlreadyOverTheTargetIsAGenuineHit() {
        let t = targets { $0.protein = 140 }
        // The known items alone clear the floor, so the unmeasured ones cannot overturn it.
        let s = series("p", [150, 145, 150], partialAt: [1])
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)
        XCTAssertEqual(streak.current, 3)
        XCTAssertEqual(streak.daysJudged, 3)
    }

    func testAPartialCeilingDayAlreadyOverTheTargetIsAGenuineMiss() {
        let t = targets { $0.sodium = 2300 }
        // The known items alone already breach the ceiling; the unmeasured ones can only
        // push it higher, so the miss is proven.
        let s = series("na", [1500, 3000, 1600], partialAt: [1])
        let streak = NutrientStreaks.streak(.na, series: s, targets: t)
        XCTAssertEqual(streak.current, 1)
        XCTAssertEqual(streak.lastMissDate, "2026-07-02")
    }

    func testAPartialCeilingDayUnderTheTargetProvesNothing() {
        let t = targets { $0.sodium = 2300 }
        let s = series("na", [1500, 1600, 1700], partialAt: [1])
        let streak = NutrientStreaks.streak(.na, series: s, targets: t)
        XCTAssertEqual(streak.daysJudged, 2, "the partial day under the ceiling is undecided")
        XCTAssertEqual(streak.current, 2)
    }

    // MARK: - The window nutrient (total fat)

    func testTotalFatIsHeldAgainstItsFixedWindowNotTheDaysTarget() {
        let t = targets { $0.fat = 55 }
        // 50-65 g is the window; 40 is under the floor and 80 is over the hard cap.
        let s = series("f", [58, 40, 60, 62, 61, 80, 55, 57])
        let streak = NutrientStreaks.streak(.f, series: s, targets: t)
        XCTAssertEqual(streak.current, 2, "the 80 g day on 2026-07-06 broke it")
        XCTAssertEqual(streak.longest, 3, "the 60/62/61 run")
        XCTAssertEqual(streak.lastMissDate, "2026-07-06")
    }

    // MARK: - Which nutrients get a streak at all

    func testInformationalNutrientsNeverGetAStreak() {
        XCTAssertFalse(NutrientStreaks.judgedNutrients.contains(.sug))
        XCTAssertFalse(NutrientStreaks.judgedNutrients.contains(.unsat))
        XCTAssertTrue(NutrientStreaks.judgedNutrients.contains(.p))
        XCTAssertTrue(NutrientStreaks.judgedNutrients.contains(.na))
        XCTAssertTrue(NutrientStreaks.judgedNutrients.contains(.f))
        // The three risk nutrients with a single-number day goal DO hold a streak; the
        // four that carry no per-day verdict (cholesterol and purines are informational,
        // selenium's goal is a band, mercury's is weekly) never can.
        for n in [TrendNutrient.tfat, .asug, .vd] {
            XCTAssertTrue(NutrientStreaks.judgedNutrients.contains(n),
                          "\(n.fullName) has a day goal and so has a streak")
        }
        for n in [TrendNutrient.chol, .pur, .se, .hg] {
            XCTAssertFalse(NutrientStreaks.judgedNutrients.contains(n),
                           "\(n.fullName) carries no per-day verdict, so no streak")
        }
        XCTAssertEqual(NutrientStreaks.judgedNutrients.count, 14)

        // Even with a target and plenty of measured days, an informational nutrient produces
        // no decided day and so never appears in the list.
        let t = targets { $0.sugar = 60 }
        let s = series("sug", Array(repeating: 45, count: 10))
        XCTAssertEqual(NutrientStreaks.streak(.sug, series: s, targets: t).daysJudged, 0)
        XCTAssertFalse(NutrientStreaks.all(series: s, targets: t).contains { $0.nutrient == .sug })
    }

    func testANutrientWithNoUsableTargetCarriesNoStreak() {
        // Magnesium measured for ten days but the day's file carries no magnesium target:
        // there is no goal to hold, so no verdict and no streak.
        let s = series("mg", Array(repeating: 300, count: 10))
        let streak = NutrientStreaks.streak(.mg, series: s, targets: DietTargets())
        XCTAssertEqual(streak.daysKnown, 10)
        XCTAssertEqual(streak.daysJudged, 0)
        XCTAssertFalse(streak.hasData)
    }

    // MARK: - The list and its subtitle

    func testTheListRanksLiveStreaksFirstAndTheSubtitleNamesTheStrongest() {
        let t = targets { $0.protein = 140; $0.sodium = 2300 }
        let d = dates(from: "2026-07-01", count: 8)
        let s = (0..<8).map { i in
            NutrientDay(date: d[i], nutrients: [
                "cal": NutrientDayValue(sum: 2000, known: 5, unknown: 0),
                // Protein met every day (8-day run); sodium breached on the last day.
                "p": NutrientDayValue(sum: 150, known: 4, unknown: 0),
                "na": NutrientDayValue(sum: i == 7 ? 3000 : 1800, known: 4, unknown: 0),
            ])
        }
        let all = NutrientStreaks.all(series: s, targets: t)
        XCTAssertEqual(all.map(\.nutrient), [.p, .na], "the live streak sorts above the broken one")
        XCTAssertEqual(all[0].current, 8)
        XCTAssertEqual(all[1].current, 0)
        XCTAssertEqual(NutrientStreaks.subtitle(all), "Protein 8 days")
    }

    func testTheSubtitleIsHonestWhenNothingIsRunning() {
        let t = targets { $0.protein = 140 }
        // Every measured day misses the floor, so there is no run to advertise.
        let s = series("p", Array(repeating: 80, count: 8))
        let all = NutrientStreaks.all(series: s, targets: t)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(NutrientStreaks.subtitle(all), "no active streak — 1 nutrient tracked")
    }

    // MARK: - Coverage honesty

    func testAStreakBuiltOnSparseMeasurementSaysSo() {
        let t = targets { $0.magnesium = 400 }
        // Measured on 4 of 20 logged days: a four-day run is real, but it is not a
        // twenty-day fact, and the note says which.
        var values = [Double?](repeating: nil, count: 20)
        for i in 16..<20 { values[i] = 500 }
        let s = series("mg", values)
        let streak = NutrientStreaks.streak(.mg, series: s, targets: t)

        XCTAssertEqual(streak.current, 4)
        XCTAssertTrue(streak.isSparse)
        XCTAssertTrue(streak.coverageNote.contains("thin coverage"), streak.coverageNote)
        XCTAssertTrue(streak.coverageNote.hasPrefix("over 4 measured days of 20 logged"),
                      streak.coverageNote)
    }

    func testWellCoveredStreaksDropTheHedge() {
        let t = targets { $0.protein = 140 }
        let s = series("p", Array(repeating: 150, count: 12))
        let streak = NutrientStreaks.streak(.p, series: s, targets: t)
        XCTAssertFalse(streak.isSparse)
        XCTAssertEqual(streak.coverageNote, "over 12 measured days of 12 logged")
    }
}
