import XCTest
@testable import Jesse

// The "what fed this number" drill-down is a pure ranking over the day's meals, so
// every rule has a direct test: most-impact-first ordering, the zero/nil exclusion
// (a food with no impact on the tapped metric never appears — and nil is not zero),
// stable tie-breaking, the share math, the empty/partial states, and the
// reconciliation guard that refuses to show a list contradicting the headline.

final class FoodContributionsTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ name: String, cal: Double? = nil, p: Double? = nil,
                      f: Double? = nil, c: Double? = nil, fiber: Double? = nil,
                      amount: String? = nil) -> DietItem {
        DietItem(item: name, amount: amount, cal: cal, p: p, f: f, c: c, fiber: fiber)
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
}
