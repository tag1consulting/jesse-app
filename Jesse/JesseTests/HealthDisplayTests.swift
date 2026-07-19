import XCTest
@testable import Jesse

// The pure view-logic seam: staleness, the updated-stamp, the weight card's
// same-day-vs-fallback resolution (BF/lean never carried forward), the
// moving-average builder, and per-section availability.

@MainActor
final class HealthDisplayTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        HealthDisplay.rfc3339(iso)!
    }

    // MARK: - Header date

    func testHeaderDateFormatsAppleFitnessStyle() {
        // "yyyy-MM-dd" → "EEEE, MMMM d" in en_US, no time-zone shift on the
        // date-only value (2026-07-12 is a Sunday; 2026-01-01 a Thursday).
        XCTAssertEqual(HealthDisplay.headerDate("2026-07-12", locale: Locale(identifier: "en_US")),
                       "Sunday, July 12")
        XCTAssertEqual(HealthDisplay.headerDate("2026-01-01", locale: Locale(identifier: "en_US")),
                       "Thursday, January 1")
    }

    func testHeaderDateReturnsRawStringWhenUnparseable() {
        XCTAssertEqual(HealthDisplay.headerDate("not-a-date", locale: Locale(identifier: "en_US")),
                       "not-a-date")
    }

    // MARK: - Body-fat availability

    func testHasBodyFatTrueWhenAnyRowHasBf() {
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0, bf: 18.4)]
        XCTAssertTrue(HealthDisplay.hasBodyFat(series))
    }

    func testHasBodyFatFalseWhenNoRowHasBf() {
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0)]
        XCTAssertFalse(HealthDisplay.hasBodyFat(series))
        XCTAssertFalse(HealthDisplay.hasBodyFat([]))
    }

    // MARK: - Calorie-source split (four segments: protein / net-carbs / fiber / fat)

    /// The old single carb term (`carbs * 4`) for a set of totals — the invariant the
    /// four-segment carve-out must preserve: net-carbs + fiber kcal == this.
    private func oldCarbsKcal(_ t: MacroTotals) -> Double { t.c * 4 }
    private func oldTotal(_ t: MacroTotals) -> Double { t.p * 4 + t.c * 4 + t.f * 9 }

    func testCalorieSplitUsesAtwaterFactorsWithFiber() {
        // 100g protein, 200g carbs (of which 30g fiber), 50g fat.
        // protein 400, net-carbs (200-30)*4 = 680, fiber 30*4 = 120, fat 450 → 1650.
        let t = MacroTotals(cal: 0, p: 100, f: 50, c: 200, fiber: 30)
        let split = HealthDisplay.calorieSplit(t)
        XCTAssertEqual(split.proteinKcal, 400, accuracy: 0.001)
        XCTAssertEqual(split.netCarbsKcal, 680, accuracy: 0.001)
        XCTAssertEqual(split.fiberKcal, 120, accuracy: 0.001)
        XCTAssertEqual(split.fatKcal, 450, accuracy: 0.001)
        XCTAssertEqual(split.total, 1650, accuracy: 0.001)
        XCTAssertEqual(split.proteinFraction, 400.0 / 1650.0, accuracy: 0.0001)
        XCTAssertEqual(split.netCarbsFraction, 680.0 / 1650.0, accuracy: 0.0001)
        XCTAssertEqual(split.fiberFraction, 120.0 / 1650.0, accuracy: 0.0001)
        XCTAssertEqual(split.fatFraction, 450.0 / 1650.0, accuracy: 0.0001)
        // Carbs+fiber occupy exactly the old single carb slice.
        XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001)
    }

    func testCalorieSplitEmptyHasZeroFractions() {
        let split = HealthDisplay.calorieSplit(.zero)
        XCTAssertEqual(split.total, 0)
        XCTAssertEqual(split.proteinFraction, 0)
        XCTAssertEqual(split.netCarbsFraction, 0)
        XCTAssertEqual(split.fiberFraction, 0)
        XCTAssertEqual(split.fatFraction, 0)
    }

    func testCalorieSplitZeroFiberRendersNoFiberSegment() {
        // Zero fiber: no fiber slice, all carbs stay in net-carbs — byte-identical to
        // the old three-segment behavior.
        let t = MacroTotals(cal: 0, p: 100, f: 50, c: 200, fiber: 0)
        let split = HealthDisplay.calorieSplit(t)
        XCTAssertEqual(split.fiberKcal, 0)
        XCTAssertEqual(split.fiberFraction, 0)
        XCTAssertEqual(split.netCarbsKcal, 800, accuracy: 0.001)
        XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001)
    }

    func testCalorieSplitMissingNegativeFiberTreatedAsZero() {
        // A negative fiber value (a corrupt/"missing" sentinel) is treated as zero:
        // no fiber segment, net-carbs never inflated past the carb total.
        let t = MacroTotals(cal: 0, p: 40, f: 20, c: 120, fiber: -5)
        let split = HealthDisplay.calorieSplit(t)
        XCTAssertEqual(split.fiberKcal, 0)
        XCTAssertEqual(split.netCarbsKcal, 480, accuracy: 0.001)
        XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001)
    }

    func testCalorieSplitFiberEqualToCarbsEmptiesNetCarbs() {
        // All carbohydrate is fiber: net-carbs is zero, fiber takes the whole carb
        // slice, nothing goes negative.
        let t = MacroTotals(cal: 0, p: 0, f: 0, c: 30, fiber: 30)
        let split = HealthDisplay.calorieSplit(t)
        XCTAssertEqual(split.netCarbsKcal, 0, accuracy: 0.001)
        XCTAssertEqual(split.fiberKcal, 120, accuracy: 0.001)
        XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001)
    }

    func testCalorieSplitFiberExceedingCarbsIsClamped() {
        // Fiber greater than carbs (bad data) clamps to carbs: net-carbs stays at
        // zero (never negative), fiber caps at the carb slice, total is unchanged.
        let t = MacroTotals(cal: 0, p: 10, f: 5, c: 20, fiber: 50)
        let split = HealthDisplay.calorieSplit(t)
        XCTAssertGreaterThanOrEqual(split.netCarbsKcal, 0)
        XCTAssertEqual(split.netCarbsKcal, 0, accuracy: 0.001)
        XCTAssertEqual(split.fiberKcal, 80, accuracy: 0.001)   // clamped to carbs 20 * 4
        XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001)
        XCTAssertEqual(split.total, oldTotal(t), accuracy: 0.001)
    }

    func testCalorieSplitFourSegmentsSumToOldThreeSegmentTotal() {
        // Property-style: across a spread of realistic days (including zero, missing,
        // equal, and excess fiber), the four segments always sum to the old
        // three-segment total, and net-carbs+fiber always equals the old carb term.
        let days: [MacroTotals] = [
            MacroTotals(cal: 0, p: 140, f: 65, c: 300, fiber: 38),
            MacroTotals(cal: 0, p: 90, f: 40, c: 210, fiber: 0),
            MacroTotals(cal: 0, p: 0, f: 0, c: 25, fiber: 4),
            MacroTotals(cal: 0, p: 6, f: 14, c: 6, fiber: 3),
            MacroTotals(cal: 0, p: 30, f: 12, c: 45, fiber: 45),
            MacroTotals(cal: 0, p: 10, f: 5, c: 20, fiber: 50),   // fiber > carbs
        ]
        for t in days {
            let split = HealthDisplay.calorieSplit(t)
            XCTAssertEqual(split.total, oldTotal(t), accuracy: 0.001,
                           "four segments must sum to the old three-segment total for \(t)")
            XCTAssertEqual(split.netCarbsKcal + split.fiberKcal, oldCarbsKcal(t), accuracy: 0.001,
                           "carbs+fiber must equal the old carb slice for \(t)")
            XCTAssertGreaterThanOrEqual(split.netCarbsKcal, 0, "net-carbs never negative for \(t)")
        }
    }

    func testCalorieSplitFractionsSumToOneWhenNonEmpty() {
        // Rounding/parity with the display: the four fractions fill the whole bar, so
        // it still visually sums to the day's calories.
        let t = MacroTotals(cal: 0, p: 140, f: 65, c: 300, fiber: 38)
        let split = HealthDisplay.calorieSplit(t)
        let sum = split.proteinFraction + split.netCarbsFraction + split.fiberFraction + split.fatFraction
        XCTAssertEqual(sum, 1.0, accuracy: 0.0001)
    }

    func testCalorieSplitDisplayGramsUnchangedByCarveOut() {
        // Rounding parity with the current display: carving fiber out of carbs must
        // not change any displayed gram figure. Carbs still shows the TOTAL carb
        // grams (not net) and fiber shows fiber grams, both via the shared formatter.
        let t = MacroTotals(cal: 1650, p: 140, f: 65, c: 301, fiber: 38)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 140g · Carbs 301g · Fiber 38g · Fat 65g")
    }

    // MARK: - Staleness

    func testNotStaleWhenTodayMatchesDeviceDay() {
        let now = date("2026-07-09T09:00:00Z")
        XCTAssertFalse(HealthDisplay.isStale(todayDate: "2026-07-09", now: now, calendar: utc))
    }

    func testStaleWhenTodayIsAPriorDay() {
        let now = date("2026-07-10T09:00:00Z")
        XCTAssertTrue(HealthDisplay.isStale(todayDate: "2026-07-09", now: now, calendar: utc))
    }

    // MARK: - Updated stamp

    func testUpdatedTimeRendersLocalHHMM() {
        // 13:34 UTC → 15:34 in a +02:00 zone.
        let tz = TimeZone(secondsFromGMT: 2 * 3600)!
        XCTAssertEqual(HealthDisplay.updatedTime(fromMtime: "2026-07-09T13:34:54Z", timeZone: tz), "15:34")
    }

    func testUpdatedTimeNilForAbsentOrGarbage() {
        XCTAssertNil(HealthDisplay.updatedTime(fromMtime: nil))
        XCTAssertNil(HealthDisplay.updatedTime(fromMtime: "not-a-date"))
    }

    // MARK: - Weight card

    private func wp(_ d: String, _ lbs: Double, kg: Double? = nil, bf: Double? = nil,
                    lean: Double? = nil) -> WeightPoint {
        WeightPoint(date: d, lbs: lbs, kg: kg, phase: nil, bf: bf, leanLbs: lean, notes: nil)
    }

    func testWeightCardSameDayWeighInShowsBfLeanAndDelta() {
        let today = DietToday(date: "2026-07-09",
                              weight: DietWeight(lbs: 197.4, kg: 89.5, bf: 18.1, mm: 150.2, notes: "steady"))
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0),
                      wp("2026-07-09", 197.4, bf: 18.1, lean: 150.2)]
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertTrue(card.isTodayWeighIn)
        XCTAssertEqual(card.lbs, 197.4)
        XCTAssertEqual(card.bf, 18.1)
        XCTAssertEqual(card.leanLbs, 150.2, "lean comes from today's muscle-mass field")
        XCTAssertEqual(card.deltaLbs!, 197.4 - 198.0, accuracy: 0.001, "delta vs the prior weigh-in")
        XCTAssertNil(card.lastWeighInDate)
    }

    func testWeightCardFallbackHidesBfLeanAndLabelsLastWeighIn() {
        // No weigh-in today → fall back to the last series entry; BF/lean must NOT
        // be carried forward even though the last entry has them.
        let today = DietToday(date: "2026-07-09", weight: nil)
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0, bf: 18.4, lean: 150.0)]
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertFalse(card.isTodayWeighIn)
        XCTAssertEqual(card.lbs, 198.0)
        XCTAssertNil(card.bf, "BF is never carried forward to a non-weigh-in day")
        XCTAssertNil(card.leanLbs, "lean is never carried forward either")
        XCTAssertEqual(card.lastWeighInDate, "2026-07-08")
        XCTAssertEqual(card.deltaLbs!, 198.0 - 199.0, accuracy: 0.001)
    }

    func testWeightCardNilWhenNoWeightAnywhere() {
        let today = DietToday(date: "2026-07-09", weight: nil)
        XCTAssertNil(HealthDisplay.weightCard(today: today, series: []))
        XCTAssertNil(HealthDisplay.weightCard(today: today, series: nil))
    }

    func testWeightCardSameDayWithNoPriorHasNilDelta() {
        let today = DietToday(date: "2026-07-09", weight: DietWeight(lbs: 197.4))
        let series = [wp("2026-07-09", 197.4)]   // only today's entry
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertNil(card.deltaLbs, "no prior weigh-in → no delta")
    }

    // MARK: - Moving average

    func testMovingAverageTrailingWindow() {
        let series = [wp("d1", 200), wp("d2", 198), wp("d3", 196), wp("d4", 202)]
        let ma = HealthDisplay.movingAverage(series, window: 3)
        XCTAssertEqual(ma.count, 4)
        XCTAssertEqual(ma[0].value, 200, accuracy: 0.001)                 // [200]
        XCTAssertEqual(ma[1].value, 199, accuracy: 0.001)                 // [200,198]
        XCTAssertEqual(ma[2].value, (200 + 198 + 196) / 3, accuracy: 0.001)
        XCTAssertEqual(ma[3].value, (198 + 196 + 202) / 3, accuracy: 0.001) // trailing 3
        XCTAssertEqual(ma[3].date, "d4")
    }

    func testMovingAverageEmpty() {
        XCTAssertTrue(HealthDisplay.movingAverage([], window: 7).isEmpty)
    }

    // MARK: - Availability

    func testAvailabilityPresent() {
        XCTAssertEqual(HealthDisplay.availability(present: true, label: "Progress", errors: []), .present)
    }

    func testAvailabilityUnavailableUsesMatchingErrorLine() {
        let errors = ["progress: json5 parse error at 1:14", "coach: cannot read file"]
        XCTAssertEqual(
            HealthDisplay.availability(present: false, label: "Progress", errors: errors),
            .unavailable("progress: json5 parse error at 1:14"))
    }

    func testAvailabilityUnavailableGenericWhenNoMatchingError() {
        XCTAssertEqual(
            HealthDisplay.availability(present: false, label: "Coach", errors: []),
            .unavailable("Coach unavailable"))
    }
}
