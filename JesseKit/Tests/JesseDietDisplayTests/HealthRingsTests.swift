import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The redesigned Today screen's pure presentation logic: ring fill + clamping per
// metric type (including the carb-load flips and fiber suspension → neutral), the
// calories hero's center number/caption across left/at-limit/over/window, the net
// line, and the exercise-symbol mapping. Ring fill and neutral are driven through
// the real `DietSemantics.gauges` so a flip that the engine makes is the flip the
// ring draws — the two can never disagree.

@MainActor
final class HealthRingsTests: XCTestCase {
    typealias S = DietSemantics

    // Build a one-meal day with the given macro totals and targets.
    private func day(cal: Double, p: Double, f: Double, c: Double, fiber: Double,
                     targets: DietTargets, dayStyle: String? = nil,
                     exercise: [DietExercise] = []) -> DietToday {
        let item = DietItem(item: "x", amount: nil, cal: cal, p: p, f: f, c: c, fiber: fiber)
        return DietToday(date: "2026-07-12", dayStyle: dayStyle,
                         exercise: exercise, meals: [DietMeal(name: "m", time: nil, items: [item])],
                         targets: targets)
    }

    // MARK: - Ring fill + clamping

    func testFloorRingFillIsValueOverTargetClamped() {
        // Protein floor 100, ate 60 → 0.6; ate 130 → clamps to 1.0.
        let t = DietTargets(protein: 100, fiber: 38)
        let under = S.gauges(for: day(cal: 0, p: 60, f: 0, c: 0, fiber: 0, targets: t), hour: 9)
        XCTAssertEqual(HealthRing.fill(under.protein), 0.6, accuracy: 0.0001)
        let over = S.gauges(for: day(cal: 0, p: 130, f: 0, c: 0, fiber: 0, targets: t), hour: 9)
        XCTAssertEqual(HealthRing.fill(over.protein), 1.0, accuracy: 0.0001)
    }

    func testFatRingNormalDayFillsOverWorkingCap() {
        // Normal day: fat ring references the 65g working cap (fatCap), not a target.
        let t = DietTargets(fat: 200)   // ignored on a normal day
        let g = S.gauges(for: day(cal: 0, p: 0, f: 32.5, c: 0, fiber: 0, targets: t), hour: 9)
        XCTAssertEqual(HealthRing.fill(g.fat), 32.5 / S.fatCap, accuracy: 0.0001)
        XCTAssertFalse(HealthRing.isNeutral(g.fat))
    }

    func testCarbLoadFlipsFatToCeilingRing() {
        // Carb-load: fat flips to a ceiling against its target (100g), so 50g → 0.5.
        let t = DietTargets(fat: 100, fiber: 38)
        let g = S.gauges(for: day(cal: 0, p: 0, f: 50, c: 0, fiber: 0,
                                  targets: t, dayStyle: "carb-load-training"), hour: 9)
        XCTAssertEqual(HealthRing.fill(g.fat), 0.5, accuracy: 0.0001)
    }

    func testFiberRingNeutralOnCarbLoadDayOnly() {
        let t = DietTargets(fiber: 38)
        let normal = S.gauges(for: day(cal: 0, p: 0, f: 0, c: 0, fiber: 19, targets: t), hour: 9)
        XCTAssertFalse(HealthRing.isNeutral(normal.fiber), "fiber is judged on a normal day")

        let carb = S.gauges(for: day(cal: 0, p: 0, f: 0, c: 0, fiber: 19,
                                     targets: t, dayStyle: "carb-load-race"), hour: 9)
        XCTAssertTrue(HealthRing.isNeutral(carb.fiber), "fiber is suspended → neutral on a carb-load day")
        // A neutral ring still shows the plain grams in its center.
        XCTAssertEqual(HealthRing.centerLabel(carb.fiber), "19g")
    }

    func testRingCenterLabelCompactGrams() {
        let t = DietTargets(protein: 140)
        let g = S.gauges(for: day(cal: 0, p: 142, f: 0, c: 0, fiber: 0, targets: t), hour: 9)
        XCTAssertEqual(HealthRing.centerLabel(g.protein), "142g")
    }

    func testRingFillNilFractionReadsEmpty() {
        let gauge = MetricGauge(label: "x", goal: .floor, value: 10, target: nil,
                                status: .suspended, remaining: "", flag: nil, unit: "g", fraction: nil)
        XCTAssertEqual(HealthRing.fill(gauge), 0)
    }

    // MARK: - Calories hero center label

    private func calGauge(intake: Double, target: Double, carbLoad: Bool = false,
                          exercise: [DietExercise] = []) -> MetricGauge {
        let t = DietTargets(calories: target, protein: 100, fat: 65, carbs: 300, fiber: 38)
        let d = day(cal: intake, p: 0, f: 0, c: 0, fiber: 0, targets: t,
                    dayStyle: carbLoad ? "carb-load-training" : nil, exercise: exercise)
        return S.gauges(for: d, hour: 9).calories
    }

    func testCaloriesHeroLeftState() {
        let g = calGauge(intake: 1380, target: 2000)   // 620 under a ceiling
        XCTAssertEqual(CaloriesHero.centerNumber(g), "620")
        XCTAssertEqual(CaloriesHero.centerCaption(g), "room for 620")
    }

    func testCaloriesHeroAtLimitState() {
        let g = calGauge(intake: 2000, target: 2000)
        XCTAssertEqual(CaloriesHero.centerNumber(g), "0")
        XCTAssertEqual(CaloriesHero.centerCaption(g), "right on target")
    }

    func testCaloriesHeroOverState() {
        let g = calGauge(intake: 2180, target: 2000)
        XCTAssertEqual(CaloriesHero.centerNumber(g), "180")
        XCTAssertEqual(CaloriesHero.centerCaption(g), "180 over")
    }

    func testCaloriesHeroWindowStateOnCarbLoad() {
        // Carb-load day: calories are a window. Under the 92% low edge → "X more to go".
        let g = calGauge(intake: 1500, target: 2000, carbLoad: true)
        XCTAssertEqual(CaloriesHero.centerCaption(g), "340 more to go")   // 1840 - 1500
        // In-window phrasing at, say, 96%.
        let inWin = calGauge(intake: 1920, target: 2000, carbLoad: true)
        XCTAssertEqual(CaloriesHero.centerCaption(inWin), "in window")
    }

    // MARK: - Net line

    func testNetLineGroupsAndOmitsWhenNoBurn() {
        let net = NetCalories(intake: 1840, burned: 420)
        XCTAssertEqual(CaloriesHero.netLine(net, locale: Locale(identifier: "en_US")),
                       "1,840 eaten · 420 burned · 1,420 net")
        XCTAssertNil(CaloriesHero.netLine(NetCalories(intake: 1840, burned: 0)))
    }

    // MARK: - Day-style headline

    func testDayStyleHeadline() {
        XCTAssertEqual(DayStyleExplain.headline(dayStyle: "carb-load-training", isCarbLoad: true), "Carb-load")
        XCTAssertEqual(DayStyleExplain.headline(dayStyle: "long-run", isCarbLoad: false), "Long run")
        XCTAssertEqual(DayStyleExplain.headline(dayStyle: "normal", isCarbLoad: false), "Normal")
        XCTAssertEqual(DayStyleExplain.headline(dayStyle: nil, isCarbLoad: false), "Normal")
        // isCarbLoad wins even when the dayStyle string is only a dayType-derived flag.
        XCTAssertEqual(DayStyleExplain.headline(dayStyle: nil, isCarbLoad: true), "Carb-load")
    }

    // MARK: - Exercise symbol mapping

    func testExerciseSymbolMapping() {
        XCTAssertEqual(ExerciseSymbol.name(for: "Run"), "figure.run")
        XCTAssertEqual(ExerciseSymbol.name(for: "morning trail RUN"), "figure.run")
        XCTAssertEqual(ExerciseSymbol.name(for: "Walk"), "figure.walk")
        XCTAssertEqual(ExerciseSymbol.name(for: "Open-water swim"), "figure.pool.swim")
        XCTAssertEqual(ExerciseSymbol.name(for: "Bike"), "figure.outdoor.cycle")
        XCTAssertEqual(ExerciseSymbol.name(for: "Indoor Cycling"), "figure.outdoor.cycle")
        XCTAssertEqual(ExerciseSymbol.name(for: "Strength"), "dumbbell")
        XCTAssertEqual(ExerciseSymbol.name(for: "weights session"), "dumbbell")
        XCTAssertEqual(ExerciseSymbol.name(for: "Hike"), "figure.hiking")
        XCTAssertEqual(ExerciseSymbol.name(for: "Yoga"), "figure.mixed.cardio")
        XCTAssertEqual(ExerciseSymbol.name(for: ""), "figure.mixed.cardio")
    }
}
