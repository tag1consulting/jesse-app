import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The diet semantics engine is the heart of the Health tab, so every rule has a
// direct test — the status bands and their boundaries, the remaining wording, the
// carb-load flips, fiber suspension, the dayStyle→dayType fallback, the 4pm gate,
// totals, and chronological sorting.

@MainActor
final class DietSemanticsTests: XCTestCase {
    typealias S = DietSemantics

    // MARK: - Day-style resolution

    func testDayStyleWinsOverDayType() {
        // An explicit non-carb dayStyle beats a "CARB-LOAD" dayType string.
        XCTAssertFalse(S.isCarbLoad(dayStyle: "normal", dayType: "CARB-LOAD prep"))
        XCTAssertTrue(S.isCarbLoad(dayStyle: "carb-load-training", dayType: "whatever"))
        XCTAssertTrue(S.isCarbLoad(dayStyle: "carb-load-race", dayType: nil))
    }

    func testDayTypeFallbackWhenStyleAbsent() {
        // No dayStyle → fall back to a case-insensitive CARB-LOAD substring.
        XCTAssertTrue(S.isCarbLoad(dayStyle: nil, dayType: "Race-week Carb-Load day 2"))
        XCTAssertTrue(S.isCarbLoad(dayStyle: "", dayType: "CARB-LOAD"))
        XCTAssertFalse(S.isCarbLoad(dayStyle: nil, dayType: "Normal training day"))
        XCTAssertFalse(S.isCarbLoad(dayStyle: nil, dayType: nil))
    }

    // MARK: - FLOOR band (protein / carbs / fiber)

    func testFloorStatusBands() {
        XCTAssertEqual(S.floorStatus(value: 49, target: 100), .red)     // under 50%
        XCTAssertEqual(S.floorStatus(value: 50, target: 100), .yellow)  // exactly 50%
        XCTAssertEqual(S.floorStatus(value: 79, target: 100), .yellow)
        XCTAssertEqual(S.floorStatus(value: 80, target: 100), .green)   // exactly 80%
        XCTAssertEqual(S.floorStatus(value: 120, target: 100), .green)
        XCTAssertEqual(S.floorStatus(value: 10, target: 0), .suspended) // no target
    }

    func testFloorRemaining() {
        XCTAssertEqual(S.floorRemaining(value: 80, target: 100), "20g to go")
        XCTAssertEqual(S.floorRemaining(value: 100, target: 100), "there — nice")
        XCTAssertEqual(S.floorRemaining(value: 130, target: 100), "there — nice")
    }

    // MARK: - CEILING band (calories on a normal day)

    func testCeilingStatusBands() {
        XCTAssertEqual(S.ceilingStatus(value: 79, target: 100), .green)   // under 80%
        XCTAssertEqual(S.ceilingStatus(value: 80, target: 100), .yellow)  // 80%
        XCTAssertEqual(S.ceilingStatus(value: 100, target: 100), .yellow) // at limit
        XCTAssertEqual(S.ceilingStatus(value: 101, target: 100), .red)    // over
    }

    func testCeilingRemaining() {
        XCTAssertEqual(S.ceilingRemaining(value: 1800, target: 2100), "room for 300")
        XCTAssertEqual(S.ceilingRemaining(value: 2100, target: 2100), "right on target")
        XCTAssertEqual(S.ceilingRemaining(value: 2300, target: 2100), "200 over")
        // With a unit (fat-as-ceiling on a carb-load day).
        XCTAssertEqual(S.ceilingRemaining(value: 40, target: 65, unit: "g"), "room for 25g")
    }

    // MARK: - FAT WINDOW (normal day)

    func testFatWindowStatusBands() {
        XCTAssertEqual(S.fatWindowStatus(grams: 49), .red)    // under floor — too LOW
        XCTAssertEqual(S.fatWindowStatus(grams: 50), .green)  // floor
        XCTAssertEqual(S.fatWindowStatus(grams: 65), .green)  // cap edge
        XCTAssertEqual(S.fatWindowStatus(grams: 66), .yellow) // over working cap
        XCTAssertEqual(S.fatWindowStatus(grams: 70), .yellow) // hard cap edge
        XCTAssertEqual(S.fatWindowStatus(grams: 71), .red)    // over hard cap
    }

    func testFatWindowRemaining() {
        XCTAssertEqual(S.fatWindowRemaining(grams: 40), "10g to the 50g floor")
        XCTAssertEqual(S.fatWindowRemaining(grams: 55), "in range")
        XCTAssertEqual(S.fatWindowRemaining(grams: 72), "7g above the range")
    }

    // MARK: - CALORIE WINDOW (carb-load day)

    func testCalorieWindowStatusBands() {
        XCTAssertEqual(S.calorieWindowStatus(value: 91, target: 100), .red)   // under 92%
        XCTAssertEqual(S.calorieWindowStatus(value: 92, target: 100), .green) // in window
        XCTAssertEqual(S.calorieWindowStatus(value: 100, target: 100), .green)
        XCTAssertEqual(S.calorieWindowStatus(value: 101, target: 100), .red)  // over
    }

    func testCalorieWindowRemaining() {
        XCTAssertEqual(S.calorieWindowRemaining(value: 2000, target: 3000), "760 more to go") // to 92%
        XCTAssertEqual(S.calorieWindowRemaining(value: 2800, target: 3000), "in window")
        XCTAssertEqual(S.calorieWindowRemaining(value: 3200, target: 3000), "200 over")
    }

    // MARK: - After-4pm gated flags

    func testProteinLowFlagGatedByHour() {
        // Under 25% of target: flagged at/after 16:00, silent before.
        XCTAssertNil(S.proteinLowFlag(protein: 20, target: 190, hour: 15))
        XCTAssertNotNil(S.proteinLowFlag(protein: 20, target: 190, hour: 16))
        // At/after 16:00 but not low → no flag (colors, not this nag).
        XCTAssertNil(S.proteinLowFlag(protein: 100, target: 190, hour: 18))
        // No target → nothing to judge.
        XCTAssertNil(S.proteinLowFlag(protein: 0, target: nil, hour: 20))
    }

    func testFatLowFlagGatedByHour() {
        XCTAssertNil(S.fatLowFlag(fat: 30, hour: 15))
        XCTAssertNotNil(S.fatLowFlag(fat: 30, hour: 16))   // under 50g floor, after 4pm
        XCTAssertNil(S.fatLowFlag(fat: 60, hour: 20))      // not low
    }

    // MARK: - Tone (the one-meaning display signal)

    func testToneMetIsOnTrackAndNoGoalIsNeutral() {
        XCTAssertEqual(S.tone(goalStatus: .met, hour: 9, target: 100), .onTrack)
        XCTAssertEqual(S.tone(goalStatus: .met, hour: 20, target: 100), .onTrack)
        // No usable target → neutral, never a judgment.
        XCTAssertEqual(S.tone(goalStatus: .noGoal, hour: 20, target: nil), .inProgress)
    }

    func testToneShortIsNeutralEarlyThenNudgeLate() {
        // The morning fix: a floor merely unfinished early is neutral, NOT a problem.
        XCTAssertEqual(S.tone(goalStatus: .short(80), hour: 9, target: 140), .inProgress)
        XCTAssertEqual(S.tone(goalStatus: .short(80), hour: 15, target: 140), .inProgress)
        // At/after the wind-down hour a still-short floor earns a gentle nudge.
        XCTAssertEqual(S.tone(goalStatus: .short(80), hour: 16, target: 140), .nudge)
        XCTAssertEqual(S.tone(goalStatus: .short(80), hour: 20, target: 140), .nudge)
    }

    func testToneOverIsNudgeUntilWellOverLate() {
        // A little over is a nudge at any hour.
        XCTAssertEqual(S.tone(goalStatus: .over(50), hour: 20, target: 2000), .nudge)
        // Well over (≥10% of target) AND late escalates to the firmer take-note tone.
        XCTAssertEqual(S.tone(goalStatus: .over(250), hour: 20, target: 2000), .takeNote)
        // Same magnitude, but early in the day → still just a nudge (you can course-correct).
        XCTAssertEqual(S.tone(goalStatus: .over(250), hour: 11, target: 2000), .nudge)
    }

    func testToneHardOverIsAlwaysTakeNote() {
        // A hard-cap breach (fat > 70g) is the firmer line regardless of hour.
        XCTAssertEqual(S.tone(goalStatus: .over(6), hour: 9, target: 65, hardOver: true), .takeNote)
    }

    func testGaugesMorningFloorsAreNeutralNotAlarming() {
        // ~9am, only breakfast logged: floors are far short but it's EARLY, so every macro
        // ring reads as calmly in progress — never the old red "failure" at 9am.
        let meals = [DietMeal(name: "breakfast", time: "08:00", items: [item(520, 30, 18, 68, 6)])]
        let targets = DietTargets(calories: 2600, protein: 140, fat: 65, carbs: 300, carbsBase: 300, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 9)
        XCTAssertEqual(g.protein.tone, .inProgress)
        XCTAssertEqual(g.carbs.tone, .inProgress)
        XCTAssertEqual(g.fiber.tone, .inProgress)
        XCTAssertEqual(g.fat.tone, .inProgress)     // 18g on the way to the 50g floor, early
        XCTAssertEqual(g.calories.tone, .onTrack)   // comfortably under the ceiling
    }

    func testGaugesEveningShortFloorBecomesGentleNudge() {
        // Same shortfall, but at 20:00 a still-low floor becomes a gentle nudge (amber),
        // with the action carried by the words — never red.
        let meals = [DietMeal(name: "day", time: "12:00", items: [item(2180, 100, 58, 295, 20)])]
        let targets = DietTargets(calories: 2600, protein: 140, fat: 65, carbs: 300, carbsBase: 300, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 20)
        XCTAssertEqual(g.protein.tone, .nudge)   // 100/140, late
        XCTAssertEqual(g.fiber.tone, .nudge)     // 20/38, late
        XCTAssertEqual(g.carbs.tone, .onTrack)   // 295/300 → met
        XCTAssertEqual(g.fat.tone, .onTrack)     // 58g in the 50–65 range
    }

    // MARK: - Totals & sorting

    private func item(_ cal: Double, _ p: Double, _ f: Double, _ c: Double, _ fiber: Double) -> DietItem {
        DietItem(item: "x", amount: nil, cal: cal, p: p, f: f, c: c, fiber: fiber)
    }

    func testDayTotalsSumAcrossMeals() {
        let meals = [
            DietMeal(name: "A", time: "08:00", items: [item(300, 10, 5, 40, 6), item(200, 20, 10, 5, 1)]),
            DietMeal(name: "B", time: "12:00", items: [item(500, 30, 20, 50, 8)]),
        ]
        let t = S.dayTotals(meals)
        XCTAssertEqual(t.cal, 1000)
        XCTAssertEqual(t.p, 60)
        XCTAssertEqual(t.f, 35)
        XCTAssertEqual(t.c, 95)
        XCTAssertEqual(t.fiber, 15)
    }

    func testSubtotalPerMeal() {
        let meal = DietMeal(name: "A", time: nil, items: [item(300, 10, 5, 40, 6), item(200, 20, 10, 5, 1)])
        let s = S.subtotal(of: meal)
        XCTAssertEqual(s.cal, 500)
        XCTAssertEqual(s.p, 30)
    }

    func testChronologicalSortMissingTimeFirst() {
        let meals = [
            DietMeal(name: "noon", time: "12:00", items: []),
            DietMeal(name: "dawn", time: "06:30", items: []),
            DietMeal(name: "untimed", time: nil, items: []),
            DietMeal(name: "evening", time: "18:15", items: []),
        ]
        XCTAssertEqual(S.sortedMeals(meals).map(\.name), ["untimed", "dawn", "noon", "evening"])
    }

    func testMinutesOfDayParsing() {
        XCTAssertEqual(S.minutesOfDay("06:30"), 390)
        XCTAssertEqual(S.minutesOfDay("00:00"), 0)
        XCTAssertEqual(S.minutesOfDay(nil), -1)
        XCTAssertEqual(S.minutesOfDay("bogus"), -1)
        XCTAssertEqual(S.minutesOfDay("25:00"), -1)
    }

    func testBurnedCalories() {
        let ex = [
            DietExercise(type: "run", calories: 520),
            DietExercise(type: "swim", calories: 300),
            DietExercise(type: "walk", calories: nil),
        ]
        XCTAssertEqual(S.burnedCalories(ex), 820)
    }

    // MARK: - Assembled gauges: the carb-load flips

    private func todayNormal(meals: [DietMeal], targets: DietTargets, dayStyle: String? = "normal") -> DietToday {
        DietToday(date: "2026-07-09", dayStyle: dayStyle, dayType: nil,
                  weight: nil, exercise: [], meals: meals, targets: targets)
    }

    func testGaugesNormalDayCaloriesCeilingFatWindow() {
        let meals = [DietMeal(name: "all", time: "12:00",
                              items: [item(2000, 150, 55, 200, 30)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210, carbsBase: 180, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        XCTAssertFalse(g.isCarbLoad)
        XCTAssertEqual(g.calories.goal, .ceiling)
        XCTAssertEqual(g.fat.goal, .window)
        XCTAssertEqual(g.fat.status, .green)          // 55g in the 50–65 window
        XCTAssertEqual(g.protein.goal, .floor)
        XCTAssertEqual(g.fiber.status, .yellow)       // 30/38 = 79% → yellow (50–79%)
    }

    func testGaugesCarbLoadFlipsCaloriesToWindowAndFatToCeiling() {
        let meals = [DietMeal(name: "all", time: "12:00",
                              items: [item(2800, 120, 30, 400, 5)])]
        let targets = DietTargets(calories: 3000, protein: 140, fat: 50, carbs: 450, carbsBase: 450, fiber: 38)
        let today = DietToday(date: "2026-07-09", dayStyle: "carb-load-training", dayType: nil,
                              weight: nil, exercise: [], meals: meals, targets: targets)
        let g = S.gauges(for: today, hour: 12)
        XCTAssertTrue(g.isCarbLoad)
        XCTAssertEqual(g.calories.goal, .window)
        XCTAssertEqual(g.calories.status, .green)     // 2800/3000 = 93% in window
        XCTAssertEqual(g.fat.goal, .ceiling)          // fat is now a ceiling vs 50g
        XCTAssertEqual(g.fat.status, .green)          // 30/50 = 60% under 80%
    }

    func testGaugesCarbLoadSuspendsFiber() {
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2800, 120, 30, 400, 3)])]
        let targets = DietTargets(calories: 3000, protein: 140, fat: 50, carbs: 450, carbsBase: 450, fiber: 38)
        let today = DietToday(date: "2026-07-09", dayStyle: "carb-load-race", dayType: nil,
                              weight: nil, exercise: [], meals: meals, targets: targets)
        let g = S.gauges(for: today, hour: 12)
        XCTAssertEqual(g.fiber.status, .suspended, "fiber is not judged on a carb-load day")
    }

    func testFiberDefaultsTo38WhenTargetAbsent() {
        // No targets.fiber → the 38g default is used for the floor judgment.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(1000, 100, 55, 100, 40)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210)  // no fiber
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        XCTAssertEqual(g.fiber.status, .green, "40g ≥ 38g default floor → green")
    }

    func testCarbsFloorFallsBackToCarbsWhenNoBase() {
        // No carbsBase → the floor is judged against targets.carbs.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(1000, 100, 55, 200, 40)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210)  // no carbsBase
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        XCTAssertEqual(g.carbs.target, 210)
        XCTAssertEqual(g.carbs.status, .green)   // 200/210 = 95%
    }

    // MARK: - Carbs bonus (the exercise add-back)

    func testCarbsBonusWhenOverBaseOnNormalDay() throws {
        // carbsBase 180, carbs pool 210 → 30g bonus pool. Consumed 200 → 20g of bonus.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2000, 150, 55, 200, 30)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210, carbsBase: 180, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        let bonus = try XCTUnwrap(g.carbsBonus)
        XCTAssertEqual(bonus.consumed, 20)
        XCTAssertEqual(bonus.pool, 30)
    }

    func testNoCarbsBonusWhenUnderBase() {
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2000, 150, 55, 150, 30)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210, carbsBase: 180, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        XCTAssertNil(g.carbsBonus, "no bonus until carbs exceed carbsBase")
    }

    func testNoCarbsBonusOnCarbLoadDay() {
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2800, 120, 30, 500, 5)])]
        let targets = DietTargets(calories: 3000, protein: 140, fat: 50, carbs: 450, carbsBase: 400, fiber: 38)
        let today = DietToday(date: "2026-07-09", dayStyle: "carb-load-training", dayType: nil,
                              weight: nil, exercise: [], meals: meals, targets: targets)
        let g = S.gauges(for: today, hour: 12)
        XCTAssertNil(g.carbsBonus, "the bonus concept doesn't apply on a carb-load day")
    }

    // MARK: - Net calories

    func testNetCaloriesTwoPart() {
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2500, 150, 55, 200, 30)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210)
        var today = todayNormal(meals: meals, targets: targets)
        today.exercise = [DietExercise(type: "run", calories: 520),
                          DietExercise(type: "swim", calories: 300)]
        let g = S.gauges(for: today, hour: 12)
        XCTAssertEqual(g.net.intake, 2500)
        XCTAssertEqual(g.net.burned, 820)
        XCTAssertEqual(g.net.net, 1680)
    }

    // MARK: - Gated flag flows through the gauge only after 4pm

    func testGaugeFlagGatedAt4pmBoundary() {
        // Low protein + low fat, before and after 16:00.
        let meals = [DietMeal(name: "all", time: "08:00", items: [item(600, 20, 30, 60, 10)])]
        let targets = DietTargets(calories: 2100, protein: 190, fat: 65, carbs: 210, carbsBase: 180, fiber: 38)
        let before = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 15)
        XCTAssertNil(before.protein.flag, "no nag before 16:00")
        XCTAssertNil(before.fat.flag)
        // Colors are NOT gated — protein 20/190 is red regardless of hour.
        XCTAssertEqual(before.protein.status, .red)

        let after = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 16)
        XCTAssertNotNil(after.protein.flag, "nag surfaces at 16:00")
        XCTAssertNotNil(after.fat.flag)
        XCTAssertEqual(after.protein.status, .red, "color unchanged by the gate")
    }

    // MARK: - Deterministic goal status (the insight grounding)

    func testFloorGoalStatus() {
        XCTAssertEqual(S.floorGoalStatus(value: 93, target: 140), .short(47)) // below → short by the gap
        XCTAssertEqual(S.floorGoalStatus(value: 140, target: 140), .met)      // exactly at → met
        XCTAssertEqual(S.floorGoalStatus(value: 160, target: 140), .met)      // above → met
        XCTAssertEqual(S.floorGoalStatus(value: 50, target: 0), .noGoal)      // no target → no claim
    }

    func testCeilingGoalStatus() {
        XCTAssertEqual(S.ceilingGoalStatus(value: 1800, target: 2100), .met)  // under limit → met
        XCTAssertEqual(S.ceilingGoalStatus(value: 2100, target: 2100), .met)  // at limit → met
        XCTAssertEqual(S.ceilingGoalStatus(value: 2200, target: 2100), .over(100)) // over → over
        XCTAssertEqual(S.ceilingGoalStatus(value: 500, target: 0), .noGoal)
    }

    func testFatWindowGoalStatus() {
        XCTAssertEqual(S.fatWindowGoalStatus(grams: 40), .short(10)) // below the 50g floor
        XCTAssertEqual(S.fatWindowGoalStatus(grams: 60), .met)       // inside 50–65
        XCTAssertEqual(S.fatWindowGoalStatus(grams: 72), .over(7))   // past the 65g cap
    }

    func testCalorieWindowGoalStatus() {
        // Window low edge is 92% of target; met inside 92–100%, over above.
        XCTAssertEqual(S.calorieWindowGoalStatus(value: 2500, target: 3000), .short(260)) // 2760 low edge
        XCTAssertEqual(S.calorieWindowGoalStatus(value: 2900, target: 3000), .met)
        XCTAssertEqual(S.calorieWindowGoalStatus(value: 3100, target: 3000), .over(100))
        XCTAssertEqual(S.calorieWindowGoalStatus(value: 100, target: 0), .noGoal)
    }

    // MARK: - Micronutrient aggregation (unknown ≠ zero)

    /// An item carrying an explicit set of the micronutrients (any may be nil). `f` is
    /// set so the derived unsaturated-fat gauge (fat − saturated fat) has a fat total.
    private func micro(na: Double? = nil, satf: Double? = nil,
                       sug: Double? = nil, k: Double? = nil, ca: Double? = nil,
                       o3: Double? = nil, mg: Double? = nil, f: Double = 0) -> DietItem {
        DietItem(item: "x", amount: nil, cal: 0, p: 0, f: f, c: 0, fiber: 0,
                 na: na, satf: satf, sug: sug, k: k, ca: ca, o3: o3, mg: mg)
    }

    func testMicronutrientTotalAllKnownIsNotPartial() {
        // Every item has sodium → a complete, non-partial total that is the exact sum.
        let items = [micro(na: 500), micro(na: 300), micro(na: 200)]
        let agg = S.micronutrientTotal(of: items, \.na)
        XCTAssertEqual(agg.knownSum, 1000)
        XCTAssertEqual(agg.unknownItemCount, 0)
        XCTAssertEqual(agg.knownItemCount, 3)
        XCTAssertFalse(agg.partial)
        XCTAssertTrue(agg.tracked)
    }

    func testMicronutrientTotalOneUnknownIsPartialAndExcludesIt() {
        // One of three items lacks sodium → partial, unknownItemCount 1, and the sum
        // EXCLUDES the unknown (it is not treated as 0).
        let items = [micro(na: 500), micro(na: nil), micro(na: 300)]
        let agg = S.micronutrientTotal(of: items, \.na)
        XCTAssertEqual(agg.knownSum, 800, "the unknown item is excluded, not summed as 0")
        XCTAssertEqual(agg.unknownItemCount, 1)
        XCTAssertEqual(agg.knownItemCount, 2)
        XCTAssertTrue(agg.partial)
        XCTAssertTrue(agg.tracked)
    }

    func testMicronutrientTotalZeroKnownIsNotTracked() {
        // No item carries potassium → the "not tracked yet" state, not a zero total.
        let items = [micro(na: 500), micro(na: 300)]
        let agg = S.micronutrientTotal(of: items, \.k)
        XCTAssertEqual(agg.knownSum, 0)
        XCTAssertEqual(agg.knownItemCount, 0)
        XCTAssertFalse(agg.tracked, "zero known → not tracked yet, distinct from a real zero")
    }

    // MARK: - Micronutrient gauges

    private func microDay(_ items: [DietItem], targets: DietTargets = DietTargets()) -> DietToday {
        DietToday(date: "2026-07-09", dayStyle: "normal", dayType: nil, weight: nil,
                  exercise: [], meals: [DietMeal(name: "all", time: "12:00", items: items)],
                  targets: targets)
    }

    private func gauge(_ today: DietToday, _ n: Micronutrient) -> MetricGauge {
        S.micronutrientGauges(for: today).first { $0.label == n.displayName }!
    }

    func testSodiumGaugeCompleteUnderCeilingIsGreen() {
        let today = microDay([micro(na: 500), micro(na: 300)],
                             targets: DietTargets(sodium: 2300))
        let g = gauge(today, .sodium)
        XCTAssertEqual(g.value, 800)
        XCTAssertFalse(g.partial)
        XCTAssertEqual(g.goal, .ceiling)
        XCTAssertEqual(g.status, .green)      // 800/2300 under 80%
        XCTAssertEqual(g.unit, "mg")
    }

    func testSodiumGaugePartialCarriesFlagAndCount() {
        let today = microDay([micro(na: 500), micro(na: nil), micro(na: 300)],
                             targets: DietTargets(sodium: 2300))
        let g = gauge(today, .sodium)
        XCTAssertEqual(g.value, 800, "partial sum excludes the unknown item")
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.unknownItemCount, 1)
        XCTAssertEqual(g.knownItemCount, 2)
        XCTAssertEqual(S.partialCaption(unknownItemCount: g.unknownItemCount), "1 item not estimated")
    }

    func testMicronutrientGaugeNotTrackedWhenNoneKnown() {
        let today = microDay([micro(na: 500)], targets: DietTargets(potassium: 3500))
        let g = gauge(today, .potassium)
        XCTAssertEqual(g.knownItemCount, 0)
        XCTAssertEqual(g.remaining, S.notTrackedCaption)
        XCTAssertEqual(g.status, .suspended, "not-tracked shows no judgment")
    }

    func testPotassiumGaugeIsAFloor() {
        let today = microDay([micro(k: 2000), micro(k: 1800)],
                             targets: DietTargets(potassium: 3500))
        let g = gauge(today, .potassium)
        XCTAssertEqual(g.goal, .floor)
        XCTAssertEqual(g.value, 3800)
        XCTAssertEqual(g.status, .green)      // 3800 ≥ 3500 floor
    }

    func testTotalSugarsIsInformationalNeverJudged() {
        // Even far "over" any reference, sugars never turns red/green — like suspended
        // fiber. A reference target only feeds the bar, not a status.
        let today = microDay([micro(sug: 40), micro(sug: 60)],
                             targets: DietTargets(sugar: 50))
        let g = gauge(today, .totalSugars)
        XCTAssertEqual(g.value, 100)
        XCTAssertEqual(g.status, .suspended, "total sugars is never judged")
        XCTAssertEqual(g.goalStatus, .noGoal)
    }

    func testMicronutrientNoTargetShowsValueOnly() {
        // Sodium present but no target → value only, no judgment, no bar reference.
        let today = microDay([micro(na: 900)], targets: DietTargets())
        let g = gauge(today, .sodium)
        XCTAssertEqual(g.value, 900)
        XCTAssertEqual(g.status, .suspended)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertNil(g.fraction)
    }

    func testGaugesCarryGoalStatus() {
        // Protein under target → short; a met floor → met; suspended fiber → no goal.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(1200, 93, 40, 300, 20)])]
        let targets = DietTargets(calories: 2100, protein: 140, fat: 65, carbs: 210, carbsBase: 180, fiber: 38)
        let g = S.gauges(for: todayNormal(meals: meals, targets: targets), hour: 12)
        XCTAssertEqual(g.protein.goalStatus, .short(47))   // 93 of 140 → the defect case
        XCTAssertEqual(g.carbs.goalStatus, .met)           // 300 ≥ 180 base
        XCTAssertEqual(g.fiber.goalStatus, .short(18))     // 20 of 38 on a normal day

        // Fiber on a carb-load day is suspended → it makes no goal claim.
        let clTargets = DietTargets(calories: 3000, protein: 140, fat: 50, carbs: 450, carbsBase: 450, fiber: 38)
        let cl = S.gauges(for: DietToday(date: "2026-07-09", dayStyle: "carb-load-training",
                                         dayType: nil, weight: nil, exercise: [], meals: meals,
                                         targets: clTargets), hour: 12)
        XCTAssertEqual(cl.fiber.goalStatus, .noGoal)
    }

    // MARK: - New floor micronutrients (calcium / omega-3 / magnesium)

    func testCalciumGaugeIsAFloorMetWhenAtOrOverTarget() {
        let today = microDay([micro(ca: 700), micro(ca: 600)],
                             targets: DietTargets(calcium: 1200))
        let g = gauge(today, .calcium)
        XCTAssertEqual(g.goal, .floor)
        XCTAssertEqual(g.value, 1300)
        XCTAssertEqual(g.unit, "mg")
        XCTAssertEqual(g.status, .green)               // 1300 ≥ 1200 floor
        XCTAssertEqual(g.goalStatus, .met)
    }

    func testMagnesiumGaugeShortByTheShortfall() {
        let today = microDay([micro(mg: 100), micro(mg: 120)],
                             targets: DietTargets(magnesium: 400))
        let g = gauge(today, .magnesium)
        XCTAssertEqual(g.goal, .floor)
        XCTAssertEqual(g.value, 220)
        XCTAssertEqual(g.goalStatus, .short(180))      // 400 − 220
    }

    func testOmega3GaugeIsAFloorInMilligrams() {
        let today = microDay([micro(o3: 300), micro(o3: 250)],
                             targets: DietTargets(omega3: 500))
        let g = gauge(today, .omega3)
        XCTAssertEqual(g.goal, .floor)
        XCTAssertEqual(g.value, 550)
        XCTAssertEqual(g.unit, "mg")
        XCTAssertEqual(g.status, .green)               // 550 ≥ 500 floor
    }

    func testCalciumPartialIsAFloorExcludingTheUnknown() {
        // One of three items lacks calcium → partial, the unknown excluded (not 0).
        let today = microDay([micro(ca: 400), micro(ca: nil), micro(ca: 300)],
                             targets: DietTargets(calcium: 1200))
        let g = gauge(today, .calcium)
        XCTAssertEqual(g.value, 700, "the unknown calcium item is excluded, not summed as 0")
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.unknownItemCount, 1)
        XCTAssertEqual(S.partialCaption(unknownItemCount: g.unknownItemCount), "1 item not estimated")
    }

    func testCalciumAllUnknownIsNotTracked() {
        let today = microDay([micro(na: 500)], targets: DietTargets(calcium: 1200))
        let g = gauge(today, .calcium)
        XCTAssertEqual(g.knownItemCount, 0)
        XCTAssertEqual(g.remaining, S.notTrackedCaption)
        XCTAssertEqual(g.status, .suspended)
    }

    func testNewFloorNutrientNoTargetShowsValueOnly() {
        let today = microDay([micro(ca: 600)], targets: DietTargets())
        let g = gauge(today, .calcium)
        XCTAssertEqual(g.value, 600)
        XCTAssertEqual(g.status, .suspended)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertNil(g.fraction)
    }

    // MARK: - Derived unsaturated fat (informational, unknown-aware)

    func testUnsaturatedFatDerivedFromFatMinusSaturated() {
        // Every item has known saturated fat → a complete total = Σ(f − satf).
        let today = microDay([micro(satf: 5, f: 20), micro(satf: 3, f: 10)])
        let g = gauge(today, .unsaturatedFat)
        XCTAssertEqual(g.value, 22)                     // (20−5) + (10−3)
        XCTAssertFalse(g.partial)
        XCTAssertEqual(g.unit, "g")
        XCTAssertEqual(g.status, .suspended, "unsaturated fat is informational — never judged")
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertNil(g.target, "unsaturated fat has no target")
    }

    func testUnsaturatedFatPartialWhenASaturatedFatIsUnknown() {
        // The middle item has unknown saturated fat → it's UNKNOWN (partial), excluded
        // from the sum, never derived from a 0.
        let today = microDay([micro(satf: 5, f: 20), micro(satf: nil, f: 12),
                              micro(satf: 4, f: 14)])
        let g = gauge(today, .unsaturatedFat)
        XCTAssertEqual(g.value, 25, "(20−5) + (14−4); the unknown-satf item is excluded")
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.unknownItemCount, 1)
        XCTAssertEqual(g.knownItemCount, 2)
    }

    func testUnsaturatedFatShareVsKnownTotal() {
        // The drill-down share is each contributor's fraction of the KNOWN unsaturated sum.
        let meals = [DietMeal(name: "all", time: "12:00",
                              items: [micro(satf: 5, f: 20), micro(satf: 3, f: 10)])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.unsaturatedFat), total: 22)
        XCTAssertEqual(bd.contributions.map(\.value), [15, 7])     // sorted most-impact-first
        XCTAssertEqual(bd.contributions.first?.share ?? 0, 15.0 / 22.0, accuracy: 0.0001)
        XCTAssertTrue(bd.unknownFoods.isEmpty)
    }

    // MARK: - Buffered gauges: today's number, the window's colour

    /// `count` consecutive ISO dates ending on the day the `microDay` fixture uses, so a
    /// window anchored on the series' last known day covers exactly these days.
    private func historyDates(_ count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let end = f.date(from: "2026-07-09")!
        return (0..<count).reversed().map { f.string(from: cal.date(byAdding: .day, value: -$0, to: end)!) }
    }

    /// A history where one nutrient key carries `values` on consecutive days.
    private func history(_ key: String, _ values: [Double]) -> [NutrientDay] {
        zip(historyDates(values.count), values).map {
            NutrientDay(date: $0, nutrients: ["cal": NutrientDayValue(sum: 2000, known: 5, unknown: 0),
                                              key: NutrientDayValue(sum: $1, known: 1, unknown: 0)])
        }
    }

    func testSaturatedFatShowsTodayButColoursFromTheWeek() {
        // Today is 34 g against a 22 g ceiling — red on its own. The week's median is 15 g,
        // so the row reads green, still showing today's 34 and captioned "7d".
        let today = microDay([micro(satf: 34)], targets: DietTargets(satFat: 22))
        let series = history("satf", [10, 12, 14, 15, 16, 18, 34])
        let g = S.micronutrientGauge(.saturatedFat, meals: today.meals, targets: today.targets,
                                     hour: 20, series: series)
        XCTAssertEqual(g.value, 34, "the displayed number is TODAY's")
        XCTAssertEqual(g.remaining, "12g over", "the words stay today's too")
        XCTAssertEqual(g.goalStatus, .over(12), "the goal outcome is today's")
        XCTAssertEqual(g.status, .green, "the colour is the week's median")
        XCTAssertEqual(g.tone, .onTrack)
        XCTAssertEqual(S.rollingChip(g.judgment), "7d")
        XCTAssertEqual(S.judgmentNote(g.judgment), "color: 7d median of 7 logged days · number: today")
    }

    func testABlowoutDayCoexistsWithAGreenRollingColour() {
        // The same day: green over the week AND flagged as a blow-out, which is the whole
        // point — the median is what hides it.
        let today = microDay([micro(satf: 34)], targets: DietTargets(satFat: 22))
        let series = history("satf", [10, 12, 14, 15, 16, 18, 34])
        let g = S.micronutrientGauge(.saturatedFat, meals: today.meals, targets: today.targets,
                                     hour: 20, series: series)
        XCTAssertEqual(g.status, .green)
        XCTAssertTrue(g.blowout, "34 g is 1.5x the 22 g target")

        // A mild day over the same week is neither red nor flagged.
        let mild = microDay([micro(satf: 25)], targets: DietTargets(satFat: 22))
        let m = S.micronutrientGauge(.saturatedFat, meals: mild.meals, targets: mild.targets,
                                     hour: 20, series: series)
        XCTAssertFalse(m.blowout, "1.14x is not a blow-out")
    }

    func testMagnesiumColoursFromTheMonth() {
        let today = microDay([micro(mg: 500)], targets: DietTargets(magnesium: 400))
        let series = history("mg", Array(repeating: 150, count: 7) + [500])
        let g = S.micronutrientGauge(.magnesium, meals: today.meals, targets: today.targets,
                                     hour: 20, series: series)
        XCTAssertEqual(g.value, 500)
        XCTAssertEqual(g.goalStatus, .met, "today did clear the floor")
        XCTAssertEqual(g.status, .red, "the month's median is 150 of a 400 mg floor")
        XCTAssertEqual(S.rollingChip(g.judgment), "30d")
    }

    func testThinWindowKeepsTheDailyColourAndSaysWhy() {
        // Four known days is under the engine's minimum: the colour is today's and the row
        // says so rather than claiming a pattern.
        let today = microDay([micro(satf: 34)], targets: DietTargets(satFat: 22))
        let series = history("satf", [10, 12, 14, 34])
        let g = S.micronutrientGauge(.saturatedFat, meals: today.meals, targets: today.targets,
                                     hour: 20, series: series)
        XCTAssertEqual(g.status, .red, "today's band, unchanged")
        XCTAssertNil(S.rollingChip(g.judgment), "a thin window claims no pattern")
        XCTAssertEqual(S.judgmentNote(g.judgment),
                       "only 4 logged days — not enough for a 7d read, so this is today's")
    }

    func testProteinAndFiberAreByteIdenticalToTheSingleDayPath() {
        // The regression guard: a history that would read comfortably over a week must not
        // touch the two floors that are judged daily on purpose.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(1200, 60, 40, 300, 12)])]
        let targets = DietTargets(calories: 2100, protein: 140, fat: 65, carbs: 210,
                                  carbsBase: 180, fiber: 38)
        let day = todayNormal(meals: meals, targets: targets)
        var series = history("p", Array(repeating: 200, count: 30))
        for (i, d) in series.enumerated() {
            var n = d.nutrients
            n["fiber"] = NutrientDayValue(sum: 50, known: 1, unknown: 0)
            series[i] = NutrientDay(date: d.date, nutrients: n)
        }
        for hour in [9, 20] {
            let plain = S.gauges(for: day, hour: hour)
            let withHistory = S.gauges(for: day, hour: hour, series: series)
            XCTAssertEqual(withHistory.protein, plain.protein, "protein at \(hour)h")
            XCTAssertEqual(withHistory.fiber, plain.fiber, "fiber at \(hour)h")
            XCTAssertEqual(withHistory.calories, plain.calories, "calories at \(hour)h")
            XCTAssertEqual(withHistory.carbs, plain.carbs, "carbs at \(hour)h")
            XCTAssertEqual(withHistory.protein.judgment, .daily)
            XCTAssertEqual(withHistory.fiber.judgment, .daily)
        }
    }

    func testTotalFatRingBuffersOverTheWeekAndFlagsAHardCapDay() {
        // 78 g today: red on the day's window, but a 58 g weekly median colours it green —
        // and the same-day flame marks the 70 g cap breach.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(2000, 120, 78, 200, 30)])]
        let targets = DietTargets(calories: 2600, protein: 140, fat: 65, carbs: 300,
                                  carbsBase: 300, fiber: 38)
        let day = todayNormal(meals: meals, targets: targets)
        let series = history("f", [55, 57, 58, 58, 60, 62, 78])
        let g = S.gauges(for: day, hour: 20, series: series)
        XCTAssertEqual(g.fat.value, 78, "today's grams")
        XCTAssertEqual(g.fat.remaining, "13g above the range")
        XCTAssertEqual(g.fat.status, .green, "the 58 g median sits inside the 50–65 window")
        XCTAssertEqual(S.rollingChip(g.fat.judgment), "7d")
        XCTAssertTrue(g.fat.blowout, "78 g is over the 70 g hard cap")
        // Without the history it is the pre-change single-day red.
        XCTAssertEqual(S.gauges(for: day, hour: 20).fat.status, .red)
    }

    func testCarbLoadFatStaysJudgedOnTheDay() {
        // A carb-load day's fat ceiling is a one-day goal the history cannot know about.
        let meals = [DietMeal(name: "all", time: "12:00", items: [item(3000, 140, 78, 450, 20)])]
        let targets = DietTargets(calories: 3000, protein: 140, fat: 50, carbs: 450,
                                  carbsBase: 450, fiber: 38)
        let day = todayNormal(meals: meals, targets: targets, dayStyle: "carb-load-training")
        let series = history("f", [55, 57, 58, 58, 60, 62, 78])
        let g = S.gauges(for: day, hour: 20, series: series)
        XCTAssertEqual(g.fat.goal, .ceiling)
        XCTAssertEqual(g.fat.status, .red, "78 g against a 50 g carb-load ceiling, today")
        XCTAssertEqual(g.fat.judgment, .daily)
    }

    func testNoSeriesRevertsEveryGaugeToSingleDayBehaviour() {
        // An older bridge sends no `nutrientSeries`: every gauge is the pre-change one, with
        // no caption, no crash.
        let meals = [DietMeal(name: "all", time: "12:00",
                              items: [micro(na: 4000, satf: 34, k: 900, ca: 200, o3: 50, mg: 100, f: 78)])]
        let targets = DietTargets(calories: 2100, protein: 140, fat: 65, carbs: 210,
                                  carbsBase: 180, fiber: 38, sodium: 2300, satFat: 22,
                                  potassium: 3500, sugar: 50, calcium: 1200, omega3: 500,
                                  magnesium: 400)
        let day = todayNormal(meals: meals, targets: targets)
        for g in S.micronutrientGauges(for: day, hour: 20, series: nil) {
            XCTAssertEqual(g.judgment, .daily, g.label)
            XCTAssertNil(S.judgmentNote(g.judgment), g.label)
        }
        XCTAssertEqual(S.micronutrientGauges(for: day, hour: 20, series: nil),
                       S.micronutrientGauges(for: day, hour: 20))
        XCTAssertEqual(S.micronutrientGauges(for: day, hour: 20, series: []),
                       S.micronutrientGauges(for: day, hour: 20))
        // Sodium at 4000 mg against a 2300 mg ceiling is still red, and still a blow-out.
        let na = S.micronutrientGauges(for: day, hour: 20, series: nil).first { $0.label == "Sodium" }!
        XCTAssertEqual(na.status, .red)
        XCTAssertTrue(na.blowout, "1.7x the ceiling — a same-day signal that needs no history")
    }

    // MARK: - BAND gauge (selenium): three states, and the partial-day asymmetry
    //
    // The asymmetry is the point of the whole shape and is tested in BOTH directions: a
    // partial day CAN prove a ceiling breach (unknowns only add), and can NEVER prove a
    // floor miss (unknowns could carry it over).

    private func seleniumDay(_ items: [DietItem], floor: Double? = 55,
                             ceiling: Double? = 300) -> DietToday {
        microDay(items, targets: DietTargets(
            selenium: DietBandTarget(floor: floor, ceiling: ceiling)))
    }
    private func se(_ value: Double?) -> DietItem { DietItem(item: "food", se: value) }
    private func seleniumGauge(_ today: DietToday) -> MetricGauge {
        S.micronutrientGauge(.selenium, meals: today.meals, targets: today.targets, hour: 20)
    }

    func testBandGaugeInsideTheRangeIsMet() {
        let g = seleniumGauge(seleniumDay([se(60), se(50)]))   // 110 µg
        XCTAssertEqual(g.goal, .band)
        XCTAssertEqual(g.value, 110)
        XCTAssertEqual(g.goalStatus, .met)
        XCTAssertEqual(g.status, .green)
        XCTAssertEqual(g.tone, .onTrack)
        XCTAssertEqual(g.remaining, "in the 55–300µg range")
        XCTAssertEqual(g.unit, "µg")
    }

    func testBandGaugeCompleteDayBelowTheFloorIsShort() {
        // Every item measured, so the shortfall is REAL and is stated as one.
        let g = seleniumGauge(seleniumDay([se(20), se(10)]))   // 30 µg
        XCTAssertEqual(g.goalStatus, .short(25))
        XCTAssertEqual(g.remaining, "25µg to the 55µg floor")
        XCTAssertEqual(g.status, .yellow, "30/55 is 55% — the floor band's middle step")
        XCTAssertFalse(g.partial)
    }

    func testBandGaugeAboveTheCeilingIsOver() {
        let g = seleniumGauge(seleniumDay([se(300), se(90)]))  // 390 µg — Brazil nuts
        XCTAssertEqual(g.goalStatus, .over(90))
        XCTAssertEqual(g.status, .red)
        XCTAssertEqual(g.remaining, "90µg above the range")
    }

    // --- The asymmetry, direction 1: a partial day CAN trip the ceiling ---

    func testPartialBandDayStillProvesACeilingBreach() {
        // Two measured items already clear 300 µg on their own. Whatever the unmeasured
        // item holds, it can only ADD — so the breach is proven and IS asserted.
        let g = seleniumGauge(seleniumDay([se(300), se(90), se(nil)]))
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.value, 390, "the unknown item is excluded, never summed as 0")
        XCTAssertEqual(g.goalStatus, .over(90), "a lower bound past the ceiling IS past it")
        XCTAssertEqual(g.status, .red)
        XCTAssertEqual(g.remaining, "90µg above the range")
    }

    // --- The asymmetry, direction 2: a partial day can NEVER prove a floor miss ---

    func testPartialBandDayUnderTheFloorClaimsNoShortfall() {
        // 30 µg known, one item unmeasured. That item could hold 200 µg, so "short" would
        // assert a shortfall nobody measured. No claim, no colour, and the words say what
        // IS known.
        let g = seleniumGauge(seleniumDay([se(20), se(10), se(nil)]))
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.value, 30)
        XCTAssertEqual(g.goalStatus, .noGoal, "a lower bound under a floor proves nothing")
        XCTAssertEqual(g.status, .suspended, "and so claims no colour")
        XCTAssertEqual(g.tone, .inProgress)
        XCTAssertEqual(g.remaining, "at least 30µg so far")
        XCTAssertFalse(g.remaining.contains("short"),
                       "an unproven shortfall must never be worded as one")
    }

    func testTheSameNumberReadsDifferentlyCompleteVersusPartial() {
        // The single clearest statement of the asymmetry: identical known sum, identical
        // floor, opposite verdicts — because one day measured everything and one did not.
        let complete = seleniumGauge(seleniumDay([se(30)]))
        let partial = seleniumGauge(seleniumDay([se(30), se(nil)]))
        XCTAssertEqual(complete.value, partial.value)
        XCTAssertEqual(complete.goalStatus, .short(25))
        XCTAssertEqual(partial.goalStatus, .noGoal)
    }

    func testBandEvaluatorDirectlyAtItsEdges() {
        // The boundaries, straight through the evaluator: at the floor and at the ceiling
        // are both INSIDE (inclusive), and partiality changes only the below-floor case.
        XCTAssertEqual(S.bandGoalStatus(value: 55, floor: 55, ceiling: 300, partial: false), .met)
        XCTAssertEqual(S.bandGoalStatus(value: 300, floor: 55, ceiling: 300, partial: false), .met)
        XCTAssertEqual(S.bandGoalStatus(value: 301, floor: 55, ceiling: 300, partial: true), .over(1))
        XCTAssertEqual(S.bandGoalStatus(value: 54, floor: 55, ceiling: 300, partial: false), .short(1))
        XCTAssertEqual(S.bandGoalStatus(value: 54, floor: 55, ceiling: 300, partial: true), .noGoal)
        // A nonsense band makes no claim rather than judging against one edge.
        XCTAssertEqual(S.bandGoalStatus(value: 100, floor: 0, ceiling: 300, partial: false), .noGoal)
        XCTAssertEqual(S.bandGoalStatus(value: 100, floor: 300, ceiling: 55, partial: false), .noGoal)
    }

    func testHalfARecordedBandIsNotJudgedAtAll() {
        // One edge recorded is not a band. The row shows the value and judges nothing,
        // rather than silently treating the edge it has as the whole goal.
        for day in [seleniumDay([se(500)], ceiling: nil), seleniumDay([se(10)], floor: nil)] {
            let g = seleniumGauge(day)
            XCTAssertEqual(g.goalStatus, .noGoal)
            XCTAssertEqual(g.status, .suspended)
        }
    }

    func testBandAllUnknownIsNotTracked() {
        let g = seleniumGauge(seleniumDay([se(nil), se(nil)]))
        XCTAssertEqual(g.knownItemCount, 0)
        XCTAssertEqual(g.remaining, S.notTrackedCaption)
        XCTAssertEqual(g.status, .suspended)
    }

    // MARK: - TRANS FAT: an ordinary ceiling, at sub-gram precision

    private func tfatGauge(_ items: [DietItem], target: Double? = 0) -> MetricGauge {
        let today = microDay(items, targets: DietTargets(transFat: target))
        return S.micronutrientGauge(.transFat, meals: today.meals, targets: today.targets, hour: 20)
    }

    /// The unreachable-ceiling fix: a target of 0 is NO USABLE TARGET here, exactly as it
    /// is for every other nutrient. It used to be a real ceiling of "none", which the
    /// ruminant trans fat in any dairy day failed by construction, forever.
    func testAZeroTransFatTargetIsNoUsableTargetNotAPermanentFailure() {
        let g = tfatGauge([DietItem(item: "Greek yogurt (full-fat)", tfat: 0.05)])
        XCTAssertEqual(g.value, 0.05)
        XCTAssertEqual(g.goalStatus, .noGoal, "a 0 ceiling judges nothing — it cannot be met")
        XCTAssertEqual(g.status, .suspended)
        XCTAssertEqual(g.tone, .inProgress, "shown plain, never a standing red")
        XCTAssertNil(g.fraction, "no usable target, so no proportion to draw")
    }

    /// A historical day whose archived targets carry a 0 must degrade the same way — this
    /// is the case that rendered as a permanently failed goal on 2026-08-14.
    func testAMeasuredZeroWithNoUsableTargetStillJudgesNothing() {
        let g = tfatGauge([DietItem(item: "oats", tfat: 0)])
        XCTAssertEqual(g.value, 0)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertEqual(g.status, .suspended)
    }

    /// With a real, reachable ceiling it is an ordinary ceiling in every respect.
    func testTransFatWithARealCeilingIsJudgedLikeAnyOtherCeiling() {
        let under = tfatGauge([DietItem(item: "Greek yogurt (full-fat)", tfat: 0.05)], target: 2)
        XCTAssertEqual(under.goalStatus, .met)
        XCTAssertEqual(under.status, .green)
        XCTAssertEqual(under.remaining, "room for 1.95g")

        let over = tfatGauge([DietItem(item: "pastry", tfat: 2.5)], target: 2)
        XCTAssertEqual(over.goalStatus, .over(0.5))
        XCTAssertEqual(over.status, .red)
        XCTAssertEqual(over.remaining, "0.50g over")
    }

    /// The precision half of the 2026-08-14 defect: the day's one logged food carries
    /// 0.05 g, and NOTHING the row renders may state a zero.
    func testTransFatRendersItsRealMagnitudeNeverAZero() {
        let g = tfatGauge([DietItem(item: "Greek yogurt (full-fat)", amount: "2 tbsp (~30g)",
                                    tfat: 0.05)])
        XCTAssertEqual(g.decimals, 2, "trans fat's working range is below a gram")
        XCTAssertEqual(S.fmt(g.value, decimals: g.decimals), "0.05")
        XCTAssertNotEqual(S.fmt(g.value, decimals: g.decimals), "0")
    }

    func testAZeroTargetStaysNoGoalForEveryOtherNutrient() {
        // A 0 target means "no usable target" on every nutrient without exception now —
        // reading it as a ceiling would call an untargeted day a failure.
        let today = microDay([micro(na: 1500)], targets: DietTargets(sodium: 0))
        let g = S.micronutrientGauge(.sodium, meals: today.meals, targets: today.targets, hour: 20)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertEqual(g.status, .suspended)
    }

    func testTransFatWithNoTargetAtAllShowsValueOnly() {
        let g = tfatGauge([DietItem(item: "pastry", tfat: 1.5)], target: nil)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertEqual(g.status, .suspended)
    }

    // MARK: - Display precision (the never-a-false-zero formatter)

    func testTransFatIsTheOnlyNutrientNeedingSubUnitPrecision() {
        XCTAssertEqual(Micronutrient.transFat.displayDecimals, 2)
        for n in Micronutrient.allCases where n != .transFat {
            XCTAssertEqual(n.displayDecimals, 0,
                           "\(n) is dosed above 1 in its own unit — whole numbers are right")
        }
    }

    func testANonzeroValueIsNeverFormattedAsZero() {
        // The rule that outlives trans fat: any precision, any nutrient, a real amount
        // rounded away says it is below the threshold rather than claiming none.
        XCTAssertEqual(S.fmt(0.004, decimals: 2), "<0.01")
        XCTAssertEqual(S.fmt(0.4, decimals: 0), "<1")
        XCTAssertEqual(S.fmt(0, decimals: 2), "0.00", "a measured none is not a false zero")
        XCTAssertEqual(S.fmt(0.05, decimals: 2), "0.05")
        XCTAssertEqual(S.fmt(2.5, decimals: 0), "3", "rounds half away from zero, like fmt")
        XCTAssertEqual(S.fmt(-0.004, decimals: 2), ">-0.01")
    }

    // MARK: - Cholesterol and purines: informational, never a judgment

    func testCholesterolIsInformationalWithNoTargetAndNoJudgment() {
        XCTAssertFalse(Micronutrient.cholesterol.judged)
        let today = microDay([DietItem(item: "eggs", chol: 400),
                              DietItem(item: "liver", chol: 500)])
        let g = S.micronutrientGauge(.cholesterol, meals: today.meals,
                                     targets: today.targets, hour: 20)
        XCTAssertEqual(g.value, 900)
        XCTAssertNil(g.target)
        XCTAssertEqual(g.status, .suspended, "however high, never red or green")
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertNil(g.note)
    }

    func testPurinesAddANeutralNoteAboveTheThresholdOnly() {
        XCTAssertFalse(Micronutrient.purines.judged)
        let under = microDay([DietItem(item: "chicken", pur: 500)])
        let over = microDay([DietItem(item: "sardines", pur: 400),
                             DietItem(item: "liver", pur: 200)])   // 600
        let gUnder = S.micronutrientGauge(.purines, meals: under.meals,
                                          targets: under.targets, hour: 20)
        let gOver = S.micronutrientGauge(.purines, meals: over.meals,
                                         targets: over.targets, hour: 20)
        XCTAssertNil(gUnder.note, "exactly at the threshold is not above it")
        XCTAssertEqual(S.informationalNote(.purines, value: 600, unit: "mg",
                                           targets: DietTargets(purines: 900)), nil,
                       "the DAY's own line wins over the standing fallback")
        XCTAssertEqual(gOver.note, "above 500mg for the day — worth a glance, not a limit")
        // The note is context, NOT a verdict: it moves no colour and no goal status.
        for g in [gUnder, gOver] {
            XCTAssertEqual(g.status, .suspended)
            XCTAssertEqual(g.goalStatus, .noGoal)
            XCTAssertEqual(g.tone, .inProgress)
        }
    }

    // MARK: - ROLLING WINDOW gauge (mercury; omega-3 as context)

    /// Keyed by LOG COLUMN key (`mercury_ug`), the namespace `rolling7` actually uses —
    /// NOT the short app key the per-item fields use.
    private func window(_ nutrients: [String: RollingNutrientTotal], days: Int = 7,
                        from: String? = "2026-07-03",
                        to: String? = "2026-07-09") -> DietRollingWindow {
        DietRollingWindow(days: days, from: from, to: to, nutrients: nutrients)
    }
    private func windowDay(_ w: DietRollingWindow, targets: DietTargets = DietTargets()) -> DietToday {
        DietToday(date: "2026-07-09", meals: [], targets: targets, rolling7: w)
    }

    func testMercuryWindowUnderTheWeeklyCeilingIsMet() {
        let w = window(["mercury_ug": RollingNutrientTotal(known: 62, knownCount: 9, unknownCount: 0)])
        let g = S.rollingWindowGauge(.mercury, window: w, targets: DietTargets())!
        XCTAssertEqual(g.label, "Mercury (7-day)", "the span is in the name, not only the chip")
        XCTAssertEqual(g.value, 62, "the window's SUM, never a median and never today's")
        XCTAssertEqual(g.target, S.mercuryWeeklyCeiling)
        XCTAssertEqual(g.goalStatus, .met)
        XCTAssertEqual(g.tone, .onTrack)
        XCTAssertEqual(g.rollingWindow?.chip, "7d")
        XCTAssertFalse(g.partial)
    }

    func testMercuryWindowOverTheWeeklyCeiling() {
        let w = window(["mercury_ug": RollingNutrientTotal(known: 150, knownCount: 12, unknownCount: 0)])
        let g = S.rollingWindowGauge(.mercury, window: w, targets: DietTargets())!
        XCTAssertEqual(g.goalStatus, .over(45))
        XCTAssertEqual(g.status, .red)
        XCTAssertEqual(g.tone, .takeNote,
                       "a settled week well past the ceiling is judged at the settled hour")
    }

    func testPartialMercuryWindowIsAFloorAndSaysSo() {
        let w = window(["mercury_ug": RollingNutrientTotal(known: 40, knownCount: 5, unknownCount: 6)])
        let g = S.rollingWindowGauge(.mercury, window: w, targets: DietTargets())!
        XCTAssertTrue(g.partial)
        XCTAssertEqual(g.value, 40, "unmeasured foods are never summed as 0")
        XCTAssertEqual(g.unknownItemCount, 6)
        let note = S.rollingWindowNote(g.rollingWindow!)
        XCTAssertTrue(note.contains("not today's number"), note)
        XCTAssertTrue(note.contains("6 foods are not estimated"), note)
        XCTAssertTrue(note.contains("floor"), note)
    }

    func testACompleteWindowNoteStillNamesTheSpan() {
        let w = window(["mercury_ug": RollingNutrientTotal(known: 40, knownCount: 5, unknownCount: 0)])
        let g = S.rollingWindowGauge(.mercury, window: w, targets: DietTargets())!
        let note = S.rollingWindowNote(g.rollingWindow!)
        XCTAssertEqual(note, "7-day total, Jul 3–Jul 9 — not today's number.")
    }

    func testOmega3WindowIsContextWithNoVerdict() {
        // Omega-3's verdict already lives on its day row's 30-day colour; the window row
        // beside it states the week and claims nothing.
        let w = window(["omega3_mg": RollingNutrientTotal(known: 2400, knownCount: 4, unknownCount: 2)])
        let g = S.rollingWindowGauge(.omega3, window: w, targets: DietTargets())!
        XCTAssertEqual(g.label, "Omega-3 (EPA+DHA) (7-day)")
        XCTAssertNil(g.target)
        XCTAssertNil(g.fraction)
        XCTAssertEqual(g.goalStatus, .noGoal)
        XCTAssertEqual(g.status, .suspended)
        XCTAssertEqual(g.remaining, "7-day total")
    }

    func testAWindowThatMeasuredNothingRendersNoRow() {
        // Absent key, and a key present with zero known contributors, are both "nothing
        // measured" — a hidden row, never a phantom zero week.
        XCTAssertNil(S.rollingWindowGauge(.mercury, window: window([:]), targets: DietTargets()))
        XCTAssertNil(S.rollingWindowGauge(.mercury, window: window(
            ["mercury_ug": RollingNutrientTotal(known: 0, knownCount: 0, unknownCount: 4)]),
            targets: DietTargets()))
    }

    func testNoRollingBlockAtAllYieldsNoWindowRows() {
        // The graceful-degrade path: a generator that sends no `rolling7` simply has no
        // window section.
        XCTAssertTrue(S.rollingWindowGauges(for: DietToday(date: "d")).isEmpty)
        XCTAssertTrue(S.rollingWindowGauges(for: windowDay(window([:]))).isEmpty)
        let both = S.rollingWindowGauges(for: windowDay(window([
            "mercury_ug": RollingNutrientTotal(known: 60, knownCount: 3, unknownCount: 0),
            "omega3_mg": RollingNutrientTotal(known: 900, knownCount: 2, unknownCount: 1),
        ])))
        XCTAssertEqual(both.map(\.nutrient), [.omega3, .mercury], "canonical order")
    }

    func testTheWindowLengthComesFromThePayloadNotAConstant() {
        let w = window(["mercury_ug": RollingNutrientTotal(known: 20, knownCount: 2, unknownCount: 0)], days: 14)
        let g = S.rollingWindowGauge(.mercury, window: w, targets: DietTargets())!
        XCTAssertEqual(g.label, "Mercury (14-day)")
        XCTAssertEqual(g.rollingWindow?.chip, "14d")
    }

    // MARK: - Vitamin D: an ordinary floor, in micrograms

    func testVitaminDIsAFloorInMicrograms() {
        let today = microDay([DietItem(item: "salmon", vd: 12),
                              DietItem(item: "egg", vd: 2)],
                             targets: DietTargets(vitaminD: 20))
        let g = S.micronutrientGauge(.vitaminD, meals: today.meals,
                                     targets: today.targets, hour: 20)
        XCTAssertEqual(g.goal, .floor)
        XCTAssertEqual(g.value, 14)
        XCTAssertEqual(g.unit, "µg")
        XCTAssertEqual(g.goalStatus, .short(6))
        XCTAssertEqual(g.remaining, "6µg to go")
    }

    // MARK: - Added sugar: a real ceiling, distinct from the total-sugars reference

    func testAddedSugarIsJudgedWhereTotalSugarsIsNot() {
        let today = microDay([DietItem(item: "cola", sug: 60, asug: 60),
                              DietItem(item: "apple", sug: 20, asug: 0)],
                             targets: DietTargets(sugar: 80, addedSugar: 40))
        let added = S.micronutrientGauge(.addedSugar, meals: today.meals,
                                         targets: today.targets, hour: 20)
        let total = S.micronutrientGauge(.totalSugars, meals: today.meals,
                                         targets: today.targets, hour: 20)
        XCTAssertEqual(added.value, 60)
        XCTAssertEqual(added.goalStatus, .over(20), "the ADDED share carries a real ceiling")
        XCTAssertEqual(added.status, .red)
        XCTAssertEqual(total.value, 80)
        XCTAssertEqual(total.goalStatus, .noGoal, "the total stays informational")
        XCTAssertEqual(total.status, .suspended)
    }

    func testInformationalNutrientsNeverGainAWindow() {
        let today = microDay([micro(satf: 5, sug: 200, f: 40)], targets: DietTargets(sugar: 50))
        let series = history("sug", Array(repeating: 200, count: 30))
        for n in [Micronutrient.totalSugars, .unsaturatedFat] {
            let g = S.micronutrientGauge(n, meals: today.meals, targets: today.targets,
                                         hour: 20, series: series)
            XCTAssertEqual(g.status, .suspended, n.displayName)
            XCTAssertEqual(g.judgment, .daily, n.displayName)
            XCTAssertFalse(g.blowout, n.displayName)
        }
    }
}
