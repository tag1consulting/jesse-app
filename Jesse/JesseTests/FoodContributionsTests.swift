import XCTest
@testable import Jesse

// The "what fed this number" drill-down is a pure ranking over the day's meals, so
// every rule has a direct test: most-impact-first ordering, the zero/nil exclusion
// (a food with no impact on the tapped metric never appears — and nil is not zero),
// stable tie-breaking, the share math, the empty/partial states, and the
// reconciliation guard that refuses to show a list contradicting the headline.

@MainActor
final class FoodContributionsTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ name: String, cal: Double? = nil, p: Double? = nil,
                      f: Double? = nil, c: Double? = nil, fiber: Double? = nil,
                      amount: String? = nil, na: Double? = nil, satf: Double? = nil,
                      sug: Double? = nil, k: Double? = nil, ca: Double? = nil,
                      o3: Double? = nil, mg: Double? = nil) -> DietItem {
        DietItem(item: name, amount: amount, cal: cal, p: p, f: f, c: c, fiber: fiber,
                 na: na, satf: satf, sug: sug, k: k, ca: ca, o3: o3, mg: mg)
    }
    private func meal(_ name: String, _ items: [DietItem]) -> DietMeal {
        DietMeal(name: name, time: nil, items: items)
    }

    // MARK: - Metric label / unit

    func testMetricLabelAndUnit() {
        XCTAssertEqual(ContributionMetric.calories.label, "Calories")
        XCTAssertEqual(ContributionMetric.calories.unit, "cal")
        XCTAssertEqual(ContributionMetric.macro(.carbs).label, "Carbs")
        XCTAssertEqual(ContributionMetric.macro(.carbs).unit, "g")
        XCTAssertEqual(ContributionMetric.macro(.fiber).label, "Fiber")
    }

    // MARK: - Ranking

    func testRanksMostImpactFirst() {
        let meals = [meal("Lunch", [
            item("Rice", c: 40),
            item("Apple", c: 25),
            item("Bread", c: 60),
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 125)
        XCTAssertEqual(bd.contributions.map(\.name), ["Bread", "Rice", "Apple"])
        XCTAssertEqual(bd.contributions.map(\.value), [60, 40, 25])
    }

    func testCaloriesUseLoggedCal() {
        let meals = [meal("Dinner", [
            item("Steak", cal: 500, p: 40),
            item("Salad", cal: 120, c: 10),
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .calories, total: 620)
        XCTAssertEqual(bd.contributions.map(\.name), ["Steak", "Salad"])
        XCTAssertEqual(bd.contributions.map(\.value), [500, 120])
    }

    // MARK: - Zero / nil exclusion

    func testExcludesZeroNilAndNegativeImpact() {
        let meals = [meal("Mixed", [
            item("Pasta", c: 50),        // contributes
            item("Butter", c: 0),        // zero → excluded, never a 0 g row
            item("Water", c: nil),       // nil → not a contributor, excluded
            item("Oddity", c: -5),       // nonsensical negative → excluded
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 45)
        XCTAssertEqual(bd.contributions.map(\.name), ["Pasta"])
        XCTAssertFalse(bd.isEmpty)
    }

    func testFoodAppearsUnderTheMetricItCarriesNotOthers() {
        // A food with carbs but no fat appears under carbs, not fat.
        let meals = [meal("Snack", [item("Banana", c: 27)])]
        let carbs = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 27)
        let fat = FoodContributions.breakdown(meals, metric: .macro(.fat), total: 0)
        XCTAssertEqual(carbs.contributions.map(\.name), ["Banana"])
        XCTAssertTrue(fat.isEmpty)
    }

    // MARK: - Stable tie-break

    func testTiesKeepOriginalOrder() {
        let meals = [meal("Two", [
            item("First", p: 20),
            item("Second", p: 20),
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 40)
        XCTAssertEqual(bd.contributions.map(\.name), ["First", "Second"])
        // The ids are the original cross-meal item indices.
        XCTAssertEqual(bd.contributions.map(\.id), [0, 1])
    }

    func testIdsAreStableAcrossMeals() {
        let meals = [
            meal("A", [item("a0", c: 10), item("a1", c: 90)]),
            meal("B", [item("b0", c: 50)]),
        ]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 150)
        // Sorted by impact (a1=90, b0=50, a0=10) but ids are the flattened positions.
        XCTAssertEqual(bd.contributions.map(\.name), ["a1", "b0", "a0"])
        XCTAssertEqual(bd.contributions.map(\.id), [1, 2, 0])
    }

    // MARK: - Share

    func testShareIsFractionOfDayTotal() {
        let meals = [meal("Day", [item("Big", c: 75), item("Small", c: 25)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 100)
        XCTAssertEqual(bd.contributions[0].share, 0.75, accuracy: 0.0001)
        XCTAssertEqual(bd.contributions[1].share, 0.25, accuracy: 0.0001)
    }

    func testShareClampsAndZeroTotalGivesZeroShare() {
        // A defensive case: total smaller than a food's value clamps share to 1.
        let meals = [meal("Day", [item("Big", c: 75)])]
        let clamped = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 50)
        XCTAssertEqual(clamped.contributions[0].share, 1.0, accuracy: 0.0001)

        let zero = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 0)
        XCTAssertEqual(zero.contributions[0].share, 0.0, accuracy: 0.0001)
    }

    // MARK: - Empty / partial states

    func testEmptyWhenNothingLogged() {
        let bd = FoodContributions.breakdown([], metric: .macro(.protein), total: 0)
        XCTAssertTrue(bd.isEmpty)
        XCTAssertEqual(bd.itemCount, 0)
        XCTAssertFalse(bd.hasFoodButNoContributors)
    }

    func testHasFoodButNoContributorsWhenItemsLackTheMetric() {
        // Foods are logged, but none carry a protein value — distinct from an empty day.
        let meals = [meal("Carby", [item("Rice", c: 40), item("Bread", c: 30)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 0)
        XCTAssertTrue(bd.isEmpty)
        XCTAssertEqual(bd.itemCount, 2)
        XCTAssertTrue(bd.hasFoodButNoContributors)
    }

    // MARK: - Reconciliation guard

    func testReconciledWhenFoodsSumToHeadline() {
        let meals = [meal("Day", [item("A", p: 20), item("B", p: 20)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 40)
        XCTAssertNil(bd.reconciliationNote)
    }

    func testReconciliationNoteWhenHeadlineExceedsFoods() {
        // The headline claims more than the logged foods can account for → say so.
        let meals = [meal("Day", [item("A", p: 20), item("B", p: 20)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 60)
        XCTAssertNotNil(bd.reconciliationNote)
    }

    func testSmallRoundingGapIsNotFlagged() {
        let meals = [meal("Day", [item("A", p: 20), item("B", p: 20)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 40.3)
        XCTAssertNil(bd.reconciliationNote)
    }

    // MARK: - Micronutrient metric label / unit / flags

    func testMicronutrientMetricLabelUnitAndFlags() {
        XCTAssertEqual(ContributionMetric.micronutrient(.sodium).label, "Sodium")
        XCTAssertEqual(ContributionMetric.micronutrient(.sodium).unit, "mg")
        XCTAssertEqual(ContributionMetric.micronutrient(.saturatedFat).unit, "g")
        XCTAssertTrue(ContributionMetric.micronutrient(.sodium).isMicronutrient)
        XCTAssertFalse(ContributionMetric.macro(.carbs).isMicronutrient)
        // Only total sugars is informational.
        XCTAssertTrue(ContributionMetric.micronutrient(.totalSugars).isInformational)
        XCTAssertFalse(ContributionMetric.micronutrient(.sodium).isInformational)
        XCTAssertFalse(ContributionMetric.macro(.carbs).isInformational)
    }

    // MARK: - Micronutrient ranking (unknown ≠ zero, surfaced in its own group)

    func testMicronutrientRanksKnownAndCollectsUnknowns() {
        // Sodium: two known contributors (sorted desc), one measured true 0 (excluded),
        // one absent (UNKNOWN → the not-estimated group, never a 0-value contributor).
        let meals = [meal("Day", [
            item("Cheese", amount: "40g", na: 300),
            item("Bread", na: 450),
            item("Water", na: 0),        // measured 0 → non-contributor, excluded
            item("Apple", amount: "1", na: nil),  // unknown → not-estimated group
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.sodium), total: 750)
        // Known contributors, most impact first; the measured-0 and unknown excluded.
        XCTAssertEqual(bd.contributions.map(\.name), ["Bread", "Cheese"])
        XCTAssertEqual(bd.contributions.map(\.value), [450, 300])
        // The unknown item is in its own group — name + amount, never a value.
        XCTAssertEqual(bd.unknownFoods.map(\.name), ["Apple"])
        XCTAssertEqual(bd.unknownFoods.first?.amount, "1")
        XCTAssertTrue(bd.isPartial)
        // The measured-0 "Water" is NOT unknown — it never appears anywhere.
        XCTAssertFalse(bd.unknownFoods.contains { $0.name == "Water" })
        XCTAssertFalse(bd.contributions.contains { $0.name == "Water" })
    }

    func testMicronutrientAllKnownIsNotPartial() {
        let meals = [meal("Day", [item("A", na: 200), item("B", na: 300)])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.sodium), total: 500)
        XCTAssertTrue(bd.unknownFoods.isEmpty)
        XCTAssertFalse(bd.isPartial)
        XCTAssertNil(bd.reconciliationNote, "a micronutrient never trips the reconciliation note")
    }

    func testMicronutrientAllUnknownStillListsEveryItem() {
        // No item carries potassium → no contributors, but every item is surfaced in the
        // not-estimated group so the sheet opens honestly (no invented total).
        let meals = [meal("Day", [item("Rice", amount: "1 cup", k: nil), item("Egg", k: nil)])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.potassium), total: 0)
        XCTAssertTrue(bd.contributions.isEmpty)
        XCTAssertEqual(bd.unknownFoods.map(\.name), ["Rice", "Egg"])
        XCTAssertTrue(bd.isPartial)
    }

    func testMicronutrientShareIsAgainstKnownSum() {
        // Share denominator is the KNOWN sum (the total passed = knownSum), so a partial
        // day's contributors read as a share of the estimated total, not an invented one.
        let meals = [meal("Day", [
            item("Big", na: 600), item("Small", na: 200), item("Unknown", na: nil),
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.sodium), total: 800)
        XCTAssertEqual(bd.contributions[0].share, 0.75, accuracy: 0.0001)
        XCTAssertEqual(bd.contributions[1].share, 0.25, accuracy: 0.0001)
    }

    func testNewMicronutrientMetricLabelsUnitsAndFlags() {
        XCTAssertEqual(ContributionMetric.micronutrient(.calcium).unit, "mg")
        XCTAssertEqual(ContributionMetric.micronutrient(.omega3).unit, "mg")
        XCTAssertEqual(ContributionMetric.micronutrient(.magnesium).unit, "mg")
        XCTAssertEqual(ContributionMetric.micronutrient(.unsaturatedFat).unit, "g")
        XCTAssertEqual(ContributionMetric.micronutrient(.omega3).label, "Omega-3 (EPA+DHA)")
        // Unsaturated fat is informational (like total sugars); the floors are not.
        XCTAssertTrue(ContributionMetric.micronutrient(.unsaturatedFat).isInformational)
        XCTAssertFalse(ContributionMetric.micronutrient(.calcium).isInformational)
        // All are unknown-preserving micronutrients.
        for n in [Micronutrient.calcium, .omega3, .magnesium, .unsaturatedFat] {
            XCTAssertTrue(ContributionMetric.micronutrient(n).isMicronutrient)
        }
    }

    func testCalciumRanksKnownAndCollectsUnknowns() {
        let meals = [meal("Day", [
            item("Yogurt", amount: "1 cup", ca: 300),
            item("Kale", ca: 150),
            item("Water", ca: 0),                    // measured 0 → excluded
            item("Chip", amount: "1 bag", ca: nil),  // unknown → not-estimated
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.calcium), total: 450)
        XCTAssertEqual(bd.contributions.map(\.name), ["Yogurt", "Kale"])
        XCTAssertEqual(bd.unknownFoods.map(\.name), ["Chip"])
        XCTAssertTrue(bd.isPartial)
    }

    func testUnsaturatedFatRanksByDerivedValueAndCollectsUnknownSatf() {
        // Derived contribution is fat − saturated fat; an item with unknown saturated fat
        // is UNKNOWN (not-estimated group), never derived from 0.
        let meals = [meal("Day", [
            item("Olive oil", f: 14, amount: "1 tbsp", satf: 2),   // 12
            item("Salmon", f: 12, satf: 3),                        // 9
            item("Butter", f: 8, satf: nil),                       // unknown satf
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(.unsaturatedFat), total: 21)
        XCTAssertEqual(bd.contributions.map(\.name), ["Olive oil", "Salmon"])
        XCTAssertEqual(bd.contributions.map(\.value), [12, 9])
        XCTAssertEqual(bd.unknownFoods.map(\.name), ["Butter"])
        XCTAssertTrue(bd.isPartial)
    }

    func testMacroBreakdownNeverCollectsUnknowns() {
        // A macro's absent field stays a plain non-contributor — no not-estimated group.
        let meals = [meal("Day", [item("Rice", c: 40), item("Water", c: nil)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 40)
        XCTAssertTrue(bd.unknownFoods.isEmpty)
        XCTAssertFalse(bd.isPartial)
    }

    // MARK: - Shared drill-down builder (the single path both entry points use)

    func testDrilldownBuildAttachesFactsAndGroundedStatus() {
        // The builder BOTH the Today rings and the Macros detail call: it must attach
        // the ranked facts AND ground the insight with the gauge's deterministic status
        // (target + goalStatus), so tapping a metric anywhere gets the identical
        // enriched sheet — the fix for the Today screen opening the bare explainer.
        let meals = [meal("Day", [item("Chicken", p: 60), item("Yogurt", p: 33)])]
        let gauge = MetricGauge(label: "Protein", goal: .floor, value: 93, target: 140,
                                status: .yellow, remaining: "need 47g more",
                                goalStatus: .short(47), flag: nil, unit: "g", fraction: 93.0 / 140)
        let drill = FoodDrilldown.build(meals: meals, metric: .macro(.protein),
                                        gauge: gauge, isCarbLoad: false)
        // Facts: the ranked contributing foods, reconciled to the gauge's value.
        XCTAssertEqual(drill.breakdown.contributions.map(\.name), ["Chicken", "Yogurt"])
        XCTAssertEqual(drill.breakdown.total, 93)
        // Grounding: the insight is fed the gauge's target and deterministic status.
        XCTAssertEqual(drill.insightInput.goal, 140)
        XCTAssertEqual(drill.insightInput.goalStatus, .short(47))
        XCTAssertEqual(drill.insightInput.total, 93)
    }

    func testDrilldownBuildMicronutrientCarriesPartialFactsAndUnknownGroup() {
        // A partial sodium day: the builder attaches the ranked known contributors, the
        // not-estimated group, and grounds the insight with the partiality facts.
        let meals = [meal("Day", [
            item("Bread", na: 450), item("Cheese", na: 300), item("Apple", na: nil),
        ])]
        let gauge = DietSemantics.micronutrientGauge(
            .sodium, meals: meals, targets: DietTargets(sodium: 2300))
        let drill = FoodDrilldown.build(meals: meals, metric: .micronutrient(.sodium),
                                        gauge: gauge, isCarbLoad: false)
        XCTAssertEqual(drill.breakdown.contributions.map(\.name), ["Bread", "Cheese"])
        XCTAssertEqual(drill.breakdown.unknownFoods.map(\.name), ["Apple"])
        XCTAssertEqual(drill.breakdown.total, 750, "the known sum is a floor")
        // Grounding carries the partiality facts.
        XCTAssertTrue(drill.insightInput.partial)
        XCTAssertEqual(drill.insightInput.knownItemCount, 2)
        XCTAssertEqual(drill.insightInput.unknownItemCount, 1)
        XCTAssertEqual(drill.insightInput.goal, 2300)
        XCTAssertFalse(drill.insightInput.informational)
    }

    func testDrilldownBuildTotalSugarsIsInformationalWithNoTargetGrounding() {
        // Total sugars is informational: even with a reference target on the gauge, the
        // insight is grounded WITHOUT a goal so it frames no judgment.
        let meals = [meal("Day", [item("Yogurt", sug: 20), item("Berries", sug: 10)])]
        let gauge = DietSemantics.micronutrientGauge(
            .totalSugars, meals: meals, targets: DietTargets(sugar: 50))
        let drill = FoodDrilldown.build(meals: meals, metric: .micronutrient(.totalSugars),
                                        gauge: gauge, isCarbLoad: false)
        XCTAssertTrue(drill.insightInput.informational)
        XCTAssertNil(drill.insightInput.goal, "informational grounding carries no target")
        XCTAssertEqual(drill.insightInput.goalStatus, .noGoal)
    }

    func testDrilldownBuildUnsaturatedFatIsInformationalDerivedAndUnknownAware() {
        // Unsaturated fat is derived (fat − saturated fat) AND informational: the ranked
        // contributors come from the derived value, the unknown-satf item lands in the
        // not-estimated group, and the insight is grounded with no goal (no judgment).
        let meals = [meal("Day", [
            item("Olive oil", f: 14, satf: 2),   // 12
            item("Salmon", f: 12, satf: 3),      // 9
            item("Butter", f: 8, satf: nil),     // unknown satf → not estimated
        ])]
        let gauge = DietSemantics.micronutrientGauge(
            .unsaturatedFat, meals: meals, targets: DietTargets())
        let drill = FoodDrilldown.build(meals: meals, metric: .micronutrient(.unsaturatedFat),
                                        gauge: gauge, isCarbLoad: false)
        XCTAssertEqual(drill.breakdown.contributions.map(\.name), ["Olive oil", "Salmon"])
        XCTAssertEqual(drill.breakdown.unknownFoods.map(\.name), ["Butter"])
        XCTAssertEqual(drill.breakdown.total, 21, "the known derived sum is a floor")
        XCTAssertTrue(drill.insightInput.informational)
        XCTAssertNil(drill.insightInput.goal, "informational grounding carries no target")
        XCTAssertEqual(drill.insightInput.goalStatus, .noGoal)
        XCTAssertTrue(drill.insightInput.partial)
    }
}
