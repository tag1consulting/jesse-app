import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The drill-down share export is a pure plain-text rendition of the whole page — the
// guaranteed carrier of everything (header, sorted foods with amounts/contributions,
// and the insight when present) regardless of where on-screen text selection has
// gaps. Plain text on purpose: it pastes cleanly with no markdown scaffolding.

@MainActor
final class DrilldownShareTests: XCTestCase {

    private func item(_ name: String, c: Double? = nil, amount: String? = nil,
                      na: Double? = nil, sug: Double? = nil, k: Double? = nil,
                      ca: Double? = nil) -> DietItem {
        DietItem(item: name, amount: amount, cal: nil, p: nil, f: nil, c: c, fiber: nil,
                 na: na, satf: nil, sug: sug, k: k, ca: ca)
    }

    func testExportsHeaderFoodsAndInsight() {
        let meals = [DietMeal(name: "Lunch", time: nil, items: [
            item("Bread", c: 60, amount: "2 slices"),
            item("Rice", c: 40),
        ])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 100)
        let text = DrilldownShare.plainText(
            title: "Carbs", valueLine: "100 / 200g — need 100g more",
            breakdown: bd, insight: "Most of your carbs came from the bread.")

        // Header line joins the metric title and its live value/target/remaining.
        XCTAssertTrue(text.contains("Carbs — 100 / 200g — need 100g more"))
        // Foods, sorted by impact, with amount and contribution and share.
        XCTAssertTrue(text.contains("Bread (2 slices): 60 g — 60%"))
        XCTAssertTrue(text.contains("Rice: 40 g — 40%"))
        XCTAssertLessThan(text.range(of: "Bread")!.lowerBound,
                          text.range(of: "Rice")!.lowerBound, "sorted most-impact-first")
        // Insight, when present, is labeled and included.
        XCTAssertTrue(text.contains("On-device insight:"))
        XCTAssertTrue(text.contains("Most of your carbs came from the bread."))
        // Plain text — no markdown scaffolding.
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
    }

    func testOmitsInsightSectionWhenAbsent() {
        let meals = [DietMeal(name: "Lunch", time: nil, items: [item("Rice", c: 40)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.carbs), total: 40)
        let text = DrilldownShare.plainText(title: "Carbs", valueLine: "40g", breakdown: bd, insight: nil)
        XCTAssertFalse(text.contains("On-device insight:"))
        XCTAssertTrue(text.contains("Rice: 40 g — 100%"))
    }

    func testEmptyStateExportsHonestMessage() {
        // Foods logged, but none carry protein → the "no detail" wording, not a 0 row.
        let meals = [DietMeal(name: "Carby", time: nil, items: [item("Rice", c: 40)])]
        let bd = FoodContributions.breakdown(meals, metric: .macro(.protein), total: 0)
        let text = DrilldownShare.plainText(title: "Protein", valueLine: "0g", breakdown: bd, insight: nil)
        XCTAssertTrue(text.contains("No logged food lists its protein yet."))
    }

    // MARK: - Micronutrient export (unknown-aware, honest ≥)

    // The sheet header and the export both come from the same gauge → Explainers line,
    // so a partial day exports the "≥" notation, never a bare complete-looking number.
    private func microExport(_ meals: [DietMeal], _ nutrient: Micronutrient,
                             targets: DietTargets = DietTargets()) -> String {
        let gauge = DietSemantics.micronutrientGauge(nutrient, meals: meals, targets: targets)
        let ex = Explainers.micronutrient(nutrient, gauge: gauge)
        let bd = FoodContributions.breakdown(meals, metric: .micronutrient(nutrient), total: gauge.value)
        return DrilldownShare.plainText(title: ex.title, valueLine: ex.valueLine,
                                        breakdown: bd, insight: nil)
    }

    func testPartialSodiumExportsFloorNotationCaptionAndNotEstimated() {
        let meals = [DietMeal(name: "Day", time: nil, items: [
            item("Bread", amount: "2 slices", na: 450),
            item("Cheese", na: 300),
            item("Apple", amount: "1", na: nil),   // unknown
        ])]
        let text = microExport(meals, .sodium, targets: DietTargets(sodium: 2300))
        // Header carries the ≥ floor notation — not a bare complete number.
        XCTAssertTrue(text.contains("≥750"), "partial header must show the ≥ floor: \(text)")
        // The contributors, sorted, with amounts.
        XCTAssertTrue(text.contains("Bread (2 slices): 450 mg"))
        // The not-estimated group with its caption and the unknown item, no number.
        XCTAssertTrue(text.contains("1 item not estimated"))
        XCTAssertTrue(text.contains("Not estimated"))
        XCTAssertTrue(text.contains("• Apple (1)"))
        XCTAssertFalse(text.contains("Apple (1): 0"), "an unknown is never exported as a 0")
    }

    func testAllKnownExportsPlainTotalNoFloorNotation() {
        let meals = [DietMeal(name: "Day", time: nil, items: [
            item("Bread", na: 450), item("Cheese", na: 300),
        ])]
        let text = microExport(meals, .sodium, targets: DietTargets(sodium: 2300))
        XCTAssertFalse(text.contains("≥"), "a complete total shows no floor notation")
        XCTAssertTrue(text.contains("750 / 2300mg"))
        XCTAssertFalse(text.contains("Not estimated"))
    }

    func testPartialCalciumFloorExportsFloorNotationAndNotEstimated() {
        // A new floor nutrient exports the same unknown-aware shape: a ≥ floor header, the
        // sorted known contributors, and the not-estimated group with no numbers.
        let meals = [DietMeal(name: "Day", time: nil, items: [
            item("Yogurt", amount: "1 cup", ca: 300),
            item("Kale", ca: 150),
            item("Chips", amount: "1 bag", ca: nil),   // unknown
        ])]
        let text = microExport(meals, .calcium, targets: DietTargets(calcium: 1200))
        XCTAssertTrue(text.contains("≥450"), "partial header must show the ≥ floor: \(text)")
        XCTAssertTrue(text.contains("Yogurt (1 cup): 300 mg"))
        XCTAssertTrue(text.contains("1 item not estimated"))
        XCTAssertTrue(text.contains("• Chips (1 bag)"))
        XCTAssertFalse(text.contains("Chips (1 bag): 0"), "an unknown is never exported as a 0")
    }

    func testAllUnknownExportsNotTrackedAndListsEveryItem() {
        let meals = [DietMeal(name: "Day", time: nil, items: [
            item("Rice", amount: "1 cup", k: nil), item("Egg", k: nil),
        ])]
        let text = microExport(meals, .potassium, targets: DietTargets(potassium: 3500))
        XCTAssertTrue(text.contains("not tracked yet"), "header is the not-tracked state")
        XCTAssertTrue(text.contains("2 items not estimated"))
        XCTAssertTrue(text.contains("• Rice (1 cup)"))
        XCTAssertTrue(text.contains("• Egg"))
    }

    // MARK: - A rolling-window row's export

    func testWindowRowExportsRangeContributorsAndNeverAZeroForAnUnmeasuredFood() {
        // The same plain-text carrier, over a WINDOW's foods: summed per food across the
        // range, and the unmeasured ones listed by name with no number at all — which is
        // what makes the "≥" in the header honest when it is pasted somewhere else.
        let days = [
            SourceDay(date: "2026-07-08", items: [
                SourceItem(name: "Tuna steak", n: ["hg": 30]),
                SourceItem(name: "Bread", n: ["na": 400]),
            ]),
            SourceDay(date: "2026-07-09", items: [
                SourceItem(name: "Tuna steak", n: ["hg": 20]),
            ]),
        ]
        let bd = FoodContributions.breakdown(sourceDays: days,
                                             metric: .micronutrient(.mercury),
                                             key: "hg", total: 50)
        let out = DrilldownShare.plainText(title: "Mercury (7-day)",
                                           valueLine: "≥50 / 105µg — room for 55µg",
                                           breakdown: bd, insight: nil)
        XCTAssertTrue(out.hasPrefix("Mercury (7-day) — ≥50 / 105µg — room for 55µg"), out)
        XCTAssertTrue(out.contains("• Tuna steak: 50 µg — 100%"), out)
        XCTAssertTrue(out.contains("Not estimated (1 item not estimated):"), out)
        XCTAssertTrue(out.contains("• Bread"), out)
        XCTAssertFalse(out.contains("Bread: 0"), "an unmeasured food is never exported as a 0")
    }

    func testBandRowExportsItsPartialHeaderVerbatim() {
        // A partial band under its floor exports the "at least ... so far" wording rather
        // than a shortfall it never established.
        let today = DietToday(date: "2026-07-09", meals: [DietMeal(
            name: "all", time: nil,
            items: [DietItem(item: "Eggs", se: 30), DietItem(item: "Soup")])],
            targets: DietTargets(selenium: DietBandTarget(floor: 55, ceiling: 300)))
        let g = DietSemantics.micronutrientGauge(.selenium, meals: today.meals,
                                                 targets: today.targets, hour: 20)
        let ex = Explainers.micronutrient(.selenium, gauge: g)
        let bd = FoodContributions.breakdown(today.meals, metric: .micronutrient(.selenium),
                                             total: g.value)
        let out = DrilldownShare.plainText(title: ex.title, valueLine: ex.valueLine,
                                           breakdown: bd, insight: nil)
        XCTAssertTrue(out.contains("at least 30µg so far"), out)
        XCTAssertFalse(out.lowercased().contains("short"), out)
        XCTAssertTrue(out.contains("• Soup"), "the unmeasured food is named, with no number")
    }
}
