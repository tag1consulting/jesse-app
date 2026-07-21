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
}
