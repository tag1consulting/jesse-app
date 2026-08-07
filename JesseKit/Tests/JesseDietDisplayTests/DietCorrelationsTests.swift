import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The associations engine. These tests are mostly about what the engine REFUSES to say:
// no coefficient below the sample minimum, nothing below the weak floor, no invented day on
// either side of a pair, and no wording a reader could quote as a cause. The arithmetic is
// the easy part; the guardrails are the feature, so they get the coverage.
// Deterministic — dates are fixtures, never `Date()`.

final class DietCorrelationsTests: XCTestCase {

    // MARK: - Fixture builders

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func dates(from start: String, count: Int) -> [String] {
        let s = Self.fmt.date(from: start)!
        return (0..<count).map { Self.fmt.string(from: Self.cal.date(byAdding: .day, value: $0, to: s)!) }
    }

    /// A weigh-in per date from a list of pounds.
    private func weights(_ dates: [String], _ lbs: [Double]) -> [WeightPoint] {
        zip(dates, lbs).map { WeightPoint(date: $0, lbs: $1) }
    }

    /// One nutrient's daily totals as a `nutrientSeries`, all fully-known days.
    private func nutrients(_ dates: [String], _ key: TrendNutrient,
                           _ values: [Double], unknown: Int = 0) -> [NutrientDay] {
        zip(dates, values).map { date, v in
            NutrientDay(date: date, nutrients: [key.key: NutrientDayValue(sum: v, known: 3, unknown: unknown)])
        }
    }

    private func exercise(_ dates: [String], _ kcal: [Double]) -> [ExerciseDay] {
        zip(dates, kcal).map { ExerciseDay(date: $0, kcal: $1, sessions: 1) }
    }

    /// A weight series whose day-over-day change on day i is `deltas[i-1]`, i.e. n deltas
    /// need n+1 consecutive weigh-ins.
    private func weightsFromDeltas(_ dates: [String], start: Double, deltas: [Double]) -> [WeightPoint] {
        var lbs = [start]
        for d in deltas { lbs.append(lbs.last! + d) }
        return weights(dates, lbs)
    }

    // MARK: - Statistics primitives

    func testPearsonAndSpearmanOnPerfectRelationships() {
        let xs = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Statistics.pearson(xs, [2.0, 4, 6, 8, 10])!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(Statistics.pearson(xs, [10.0, 8, 6, 4, 2])!, -1.0, accuracy: 1e-9)
        // Monotone but curved: Spearman sees a perfect relationship where Pearson does not.
        let curved = [1.0, 4, 9, 16, 25]
        XCTAssertEqual(Statistics.spearman(xs, curved)!, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(Statistics.pearson(xs, curved)!, 1.0)
    }

    /// A constant series has no variance, so there is no coefficient — nil, never 0, which
    /// would read as "measured, and unrelated".
    func testNoVarianceYieldsNoCoefficient() {
        XCTAssertNil(Statistics.pearson([1.0, 1, 1, 1], [1.0, 2, 3, 4]))
        XCTAssertNil(Statistics.spearman([5.0, 5, 5], [1.0, 2, 3]))
        XCTAssertNil(Statistics.pearson([1.0], [2.0]))
        XCTAssertNil(Statistics.pearson([1.0, 2], [3.0]))
    }

    /// Tied values take their average rank, the standard correction.
    func testRanksAverageTies() {
        XCTAssertEqual(Statistics.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
        XCTAssertEqual(Statistics.ranks([5, 5, 5]), [2, 2, 2])
        XCTAssertEqual(Statistics.ranks([3, 1, 2]), [3, 1, 2])
    }

    // MARK: - Daily series assembly

    /// A weight change needs the day BEFORE it. Weigh-ins three days apart produce no
    /// change at all rather than a delta smeared across the gap.
    func testWeightChangesOnlyAcrossConsecutiveDays() {
        let series = [
            WeightPoint(date: "2026-07-01", lbs: 200),
            WeightPoint(date: "2026-07-02", lbs: 199.4),
            WeightPoint(date: "2026-07-05", lbs: 198.0),
        ]
        let changes = DietCorrelations.weightChanges(series)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes["2026-07-02"]!, -0.6, accuracy: 1e-9)
        XCTAssertNil(changes["2026-07-05"])   // three days on from the last weigh-in
        XCTAssertNil(changes["2026-07-01"])   // nothing before it
    }

    /// A nutrient nobody measured that day has no key, and it stays absent — never a 0
    /// intake day, which would be a fast day the log never recorded.
    func testUnmeasuredNutrientDayIsAbsentNotZero() {
        let daily = DietCorrelations.nutrientDaily([
            NutrientDay(date: "2026-07-01", nutrients: ["na": NutrientDayValue(sum: 2400, known: 5, unknown: 0)]),
            NutrientDay(date: "2026-07-02", nutrients: ["cal": NutrientDayValue(sum: 2000, known: 5, unknown: 0)]),
            NutrientDay(date: "2026-07-03", nutrients: ["na": NutrientDayValue(sum: 0, known: 0, unknown: 4)]),
        ], nutrient: .na)

        XCTAssertEqual(daily["2026-07-01"], 2400)
        XCTAssertNil(daily["2026-07-02"])   // sodium not measured that day
        XCTAssertNil(daily["2026-07-03"])   // known == 0 is a gap, not a zero-sodium day
    }

    /// A rest day is absent from `exerciseSeries` and stays absent — reading it as 0 kcal
    /// would assert training data the log never carried.
    func testRestDayIsAGapNotAZero() {
        let daily = DietCorrelations.exerciseDaily([
            ExerciseDay(date: "2026-07-01", kcal: 600, sessions: 1),
            ExerciseDay(date: "2026-07-03", kcal: 400, sessions: 1),
        ])
        XCTAssertEqual(daily["2026-07-01"], 600)
        XCTAssertNil(daily["2026-07-02"])
        XCTAssertEqual(daily.count, 2)
    }

    // MARK: - Pairing and lag

    /// The lag alignment, asserted value by value: yesterday's intake lines up with TODAY's
    /// weight change, not with today's intake and not with yesterday's change.
    func testLaggedPairingAlignsYesterdayIntakeWithTodayWeightChange() {
        let x = ["2026-07-01": 1000.0, "2026-07-02": 2000.0, "2026-07-03": 3000.0]
        let y = ["2026-07-02": 0.2, "2026-07-03": 0.4, "2026-07-04": 0.6]

        let lagged = DietCorrelations.pair(x: x, y: y, lagged: true)
        // 07-02's change pairs with 07-01's intake, 07-03's with 07-02's; 07-04 has no
        // intake for 07-03… it does — 3000 — so all three pair.
        XCTAssertEqual(lagged.xs, [1000, 2000, 3000])
        XCTAssertEqual(lagged.ys, [0.2, 0.4, 0.6])

        // Same-day pairing is a different alignment, and only overlaps on two dates.
        let sameDay = DietCorrelations.pair(x: x, y: y, lagged: false)
        XCTAssertEqual(sameDay.xs, [2000, 3000])
        XCTAssertEqual(sameDay.ys, [0.2, 0.4])
    }

    /// A day missing on EITHER side is excluded from the pair rather than filled in.
    func testMissingDayOnEitherSideIsExcludedFromThePair() {
        let x = ["2026-07-01": 1000.0, /* 07-02 missing */ "2026-07-03": 3000.0]
        let y = ["2026-07-02": 0.2, "2026-07-03": 0.4, "2026-07-04": 0.6]

        let lagged = DietCorrelations.pair(x: x, y: y, lagged: true)
        // 07-03's change needs 07-02's intake, which is missing → that pair is dropped.
        XCTAssertEqual(lagged.xs, [1000, 3000])
        XCTAssertEqual(lagged.ys, [0.2, 0.6])

        // And the mirror: a target day with no value contributes nothing.
        let holed = DietCorrelations.pair(x: x, y: ["2026-07-04": 0.6], lagged: true)
        XCTAssertEqual(holed.xs, [3000])
        XCTAssertEqual(holed.ys, [0.6])
    }

    /// Pairs come out ascending by target date, so the output is stable across runs (a
    /// dictionary's own order is not).
    func testPairsAreOrderedByTargetDate() {
        let x = Dictionary(uniqueKeysWithValues: dates(from: "2026-07-01", count: 5).enumerated()
            .map { ($0.element, Double($0.offset)) })
        let y = Dictionary(uniqueKeysWithValues: dates(from: "2026-07-01", count: 5).enumerated()
            .map { ($0.element, Double($0.offset) * 2) })
        let p = DietCorrelations.pair(x: x, y: y, lagged: false)
        XCTAssertEqual(p.xs, [0, 1, 2, 3, 4])
        XCTAssertEqual(p.ys, [0, 2, 4, 6, 8])
    }

    // MARK: - The sample minimum

    /// THE guardrail. Below `minPairs` overlapping days there is NO coefficient — the
    /// outcome carries no association at all, so a view cannot reach a number to show.
    func testPairBelowTheMinimumReturnsNotEnoughDataAndNeverACoefficient() {
        // 11 consecutive weigh-ins → 10 daily changes, one short of nothing to spare.
        let d = dates(from: "2026-07-01", count: 11)
        let deltas = (1...10).map { Double($0) * 0.05 }
        let w = weightsFromDeltas(d, start: 200, deltas: deltas)
        // A perfectly monotone sodium series, so the ONLY reason to withhold is the sample.
        let n = nutrients(d, .na, (0..<11).map { 1500 + Double($0) * 100 })

        let outcome = DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: w, nutrients: n, exercise: [])

        XCTAssertNil(outcome.association, "a thin pair must never produce a coefficient")
        guard case .miss(let m) = outcome, case .notEnoughData(let pairs) = m.rejection else {
            return XCTFail("expected notEnoughData, got \(outcome)")
        }
        XCTAssertEqual(pairs, 10)
        XCTAssertLessThan(pairs, DietCorrelations.minPairs)
        // The row says how far off it is, and nothing about which way it leaned.
        XCTAssertTrue(m.reasonText.contains("not enough data"))
        XCTAssertFalse(m.reasonText.contains("+"))
        XCTAssertFalse(m.reasonText.contains("higher"))
    }

    /// Exactly at the minimum, the same relationship IS reported — the boundary is
    /// inclusive, and the sample size is stated.
    func testExactlyAtTheMinimumTheAssociationIsReported() throws {
        let d = dates(from: "2026-07-01", count: 15)   // 15 weigh-ins → 14 daily changes
        let deltas = (1...14).map { Double($0) * 0.05 }
        let w = weightsFromDeltas(d, start: 200, deltas: deltas)
        let n = nutrients(d, .na, (0..<15).map { 1500 + Double($0) * 100 })

        let outcome = DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: w, nutrients: n, exercise: [])

        let a = try XCTUnwrap(outcome.association)
        XCTAssertEqual(a.pairs, DietCorrelations.minPairs)
        XCTAssertEqual(a.coefficient, 1.0, accuracy: 1e-9)
    }

    // MARK: - Strength

    /// A strong synthetic pair is detected, with the right sign and the right sample size.
    func testStrongSyntheticPairIsDetectedWithSignAndSampleSize() throws {
        let d = dates(from: "2026-06-01", count: 21)   // 21 weigh-ins → 20 daily changes
        // Yesterday's sodium rises with i; today's weight change rises with i too.
        let n = nutrients(d, .na, (0..<21).map { 1500 + Double($0) * 80 })
        let up = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * 0.03 })

        let positive = try XCTUnwrap(DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: up, nutrients: n, exercise: []).association)
        XCTAssertEqual(positive.pairs, 20)
        XCTAssertEqual(positive.coefficient, 1.0, accuracy: 1e-9)
        XCTAssertTrue(positive.isPositive)
        XCTAssertEqual(positive.strengthWord, "strong")

        // The mirror: the same sodium series against a weight change that FALLS as sodium
        // rises (each successive delta more negative) comes back with the same magnitude
        // and the opposite sign.
        let down = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * -0.03 })
        let negative = try XCTUnwrap(DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: down, nutrients: n, exercise: []).association)
        XCTAssertEqual(negative.pairs, 20)
        XCTAssertEqual(negative.coefficient, -1.0, accuracy: 1e-9)
        XCTAssertFalse(negative.isPositive)
    }

    /// A pair with plenty of days but no real relationship is SUPPRESSED, so the screen
    /// shows only what is worth a look.
    func testPairBelowTheWeakThresholdIsSuppressed() {
        let d = dates(from: "2026-06-01", count: 21)
        let n = nutrients(d, .na, (0..<21).map { 1500 + Double($0) * 80 })
        // A weight change that simply alternates has no monotone relationship to sodium.
        let zigzag = weightsFromDeltas(d, start: 200,
                                       deltas: (1...20).map { $0.isMultiple(of: 2) ? 0.2 : -0.2 })

        let outcome = DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: zigzag, nutrients: n, exercise: [])

        XCTAssertNil(outcome.association)
        guard case .miss(let m) = outcome, case .tooWeak(let rho, let pairs) = m.rejection else {
            return XCTFail("expected tooWeak, got \(outcome)")
        }
        XCTAssertEqual(pairs, 20)
        XCTAssertLessThan(abs(rho), DietCorrelations.weakThreshold)
        XCTAssertTrue(m.reasonText.contains("no meaningful association"))
    }

    /// A side that never varies has no coefficient at all, and is reported as such rather
    /// than as a zero association.
    func testNoVariationIsReportedDistinctly() {
        let d = dates(from: "2026-06-01", count: 21)
        let n = nutrients(d, .na, Array(repeating: 2000, count: 21))   // identical every day
        let w = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * 0.03 })

        let outcome = DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: w, nutrients: n, exercise: [])
        XCTAssertNil(outcome.association)
        guard case .miss(let m) = outcome, case .noVariation = m.rejection else {
            return XCTFail("expected noVariation, got \(outcome)")
        }
        XCTAssertTrue(m.reasonText.contains("no variation"))
    }

    // MARK: - The report

    /// Findings are ordered by strength, capped, and everything set aside is counted — a
    /// short list never implies it is the whole picture.
    func testReportRanksByStrengthAndCountsWhatItSetAside() throws {
        let d = dates(from: "2026-06-01", count: 21)
        let w = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * 0.03 })
        // Sodium rises monotonically with the weight change (perfect); calories rise too but
        // with one inversion, so it is strong yet strictly weaker.
        var calValues = (0..<21).map { 2000 + Double($0) * 25 }
        calValues.swapAt(0, 20)
        // Both nutrients on the SAME day entry — a day carries every nutrient it measured.
        let merged = d.enumerated().map { i, date in
            NutrientDay(date: date, nutrients: [
                "na": NutrientDayValue(sum: 1500 + Double(i) * 80, known: 3, unknown: 0),
                "cal": NutrientDayValue(sum: calValues[i], known: 3, unknown: 0),
            ])
        }

        let report = DietCorrelations.report(weight: w, nutrients: merged, exercise: [], limit: 1)
        let best = try XCTUnwrap(report.associations.first)
        XCTAssertEqual(report.associations.count, 1)
        XCTAssertEqual(best.x, .sodium)
        XCTAssertEqual(best.coefficient, 1.0, accuracy: 1e-9)
        // Calories cleared the guardrails too but fell outside the cap — counted, not lost.
        XCTAssertGreaterThanOrEqual(report.cappedOut, 1)
        // The exercise pairs had no data at all: thin, and reported as thin.
        XCTAssertGreaterThan(report.thinCount, 0)
        let dropped = try XCTUnwrap(DietCorrelations.droppedLine(report))
        XCTAssertTrue(dropped.hasPrefix("Not shown:"))
        XCTAssertTrue(dropped.contains("beyond the"))
    }

    /// With nothing to go on, the report is honest and empty rather than inventive, and the
    /// nav-row subtitle says so.
    func testEmptyHistoriesProduceThinMissesAndAnHonestSubtitle() {
        let report = DietCorrelations.report(weight: [], nutrients: [], exercise: [])
        XCTAssertTrue(report.associations.isEmpty)
        XCTAssertEqual(report.misses.count, DietCorrelations.candidates.count)
        XCTAssertEqual(report.thinCount, DietCorrelations.candidates.count)
        XCTAssertEqual(DietCorrelations.subtitle(report), "not enough paired days yet")
    }

    /// Every candidate pair is either a finding or a reported miss — none is ever dropped
    /// on the floor.
    func testEveryCandidateIsAccountedFor() {
        let d = dates(from: "2026-06-01", count: 21)
        let w = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * 0.03 })
        let n = nutrients(d, .na, (0..<21).map { 1500 + Double($0) * 80 })
        let e = exercise(d, (0..<21).map { 300 + Double($0) * 10 })

        let report = DietCorrelations.report(weight: w, nutrients: n, exercise: e)
        XCTAssertEqual(report.associations.count + report.cappedOut + report.misses.count,
                       DietCorrelations.candidates.count)
    }

    // MARK: - Availability (graceful degrade)

    /// The section is hidden when the bridge sends no `exerciseSeries` at all — the field
    /// an older bridge omits — and when either other history is empty.
    func testAvailabilityRequiresAllThreeHistories() {
        let w = [WeightPoint(date: "2026-07-01", lbs: 200)]
        let n = [NutrientDay(date: "2026-07-01",
                             nutrients: ["cal": NutrientDayValue(sum: 2000, known: 4, unknown: 0)])]
        let e = [ExerciseDay(date: "2026-07-01", kcal: 500, sessions: 1)]

        XCTAssertTrue(DietCorrelations.isAvailable(weight: w, nutrients: n, exercise: e))
        // An older bridge: the field is absent entirely.
        XCTAssertFalse(DietCorrelations.isAvailable(weight: w, nutrients: n, exercise: nil))
        // Present but empty (nothing logged) still allows the diet-side pairs to be tried.
        XCTAssertTrue(DietCorrelations.isAvailable(weight: w, nutrients: n, exercise: []))
        // No weight or no nutrient history means there is nothing to cross.
        XCTAssertFalse(DietCorrelations.isAvailable(weight: nil, nutrients: n, exercise: e))
        XCTAssertFalse(DietCorrelations.isAvailable(weight: [], nutrients: n, exercise: e))
        XCTAssertFalse(DietCorrelations.isAvailable(weight: w, nutrients: nil, exercise: e))
        XCTAssertFalse(DietCorrelations.isAvailable(weight: w, nutrients: [], exercise: e))
    }

    // MARK: - Wording: association, never cause

    /// The fixed wording. Every finding says "moved together" and says out loud that it is
    /// not a cause; no causal verb appears anywhere in the rendered strings.
    func testFindingWordingClaimsAssociationAndNeverCausation() throws {
        let d = dates(from: "2026-06-01", count: 21)
        let w = weightsFromDeltas(d, start: 200, deltas: (1...20).map { Double($0) * 0.03 })
        let n = nutrients(d, .na, (0..<21).map { 1500 + Double($0) * 80 })

        let a = try XCTUnwrap(DietCorrelations.evaluate(
            DietCorrelations.Candidate(x: .sodium, y: .weightChange, lagged: true),
            weight: w, nutrients: n, exercise: []).association)

        XCTAssertTrue(a.sentence.contains("moved together"))
        XCTAssertTrue(a.sentence.contains("association, not a cause"))
        XCTAssertTrue(a.sentence.contains("Over 20 days"))
        XCTAssertEqual(a.coefficientText, "+1.00")
        // The lag is named in the title, so "the day before" is never left to be inferred.
        XCTAssertTrue(a.title.contains("the day before"))

        // No causal verb anywhere in a FINDING's own strings. The standing caveat is
        // excluded on purpose: it is the one place the word "causes" belongs, and it only
        // ever appears there negated ("not causes"), asserted separately below.
        let banned = ["causes", "caused", "leads to", "makes you", "because of", "raises your"]
        for text in [a.title, a.sentence] {
            for word in banned {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(word)\" must not appear in: \(text)")
            }
        }
        for word in banned where word != "causes" {
            XCTAssertFalse(DietCorrelations.caveat.lowercased().contains(word))
        }
    }

    /// The standing caveat names the risk it is guarding against rather than gesturing at
    /// it, and it is the same text everywhere because it lives in the engine.
    func testCaveatIsStatedInTheEngine() {
        XCTAssertTrue(DietCorrelations.caveat.contains("not causes"))
        XCTAssertTrue(DietCorrelations.caveat.contains("never as conclusions"))
    }

    /// The guardrail constants are what the screen rests on, so they are asserted rather
    /// than left to drift silently.
    func testGuardrailConstants() {
        XCTAssertEqual(DietCorrelations.minPairs, 14)
        XCTAssertEqual(DietCorrelations.weakThreshold, 0.30, accuracy: 1e-9)
        XCTAssertLessThan(DietCorrelations.weakThreshold, DietCorrelations.moderateThreshold)
        XCTAssertLessThan(DietCorrelations.moderateThreshold, DietCorrelations.strongThreshold)
        XCTAssertEqual(DietCorrelations.maxShown, 5)
    }
}
