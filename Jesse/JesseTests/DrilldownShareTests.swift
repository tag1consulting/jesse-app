import XCTest
@testable import Jesse

// The drill-down share export is a pure plain-text rendition of the whole page — the
// guaranteed carrier of everything (header, sorted foods with amounts/contributions,
// and the insight when present) regardless of where on-screen text selection has
// gaps. Plain text on purpose: it pastes cleanly with no markdown scaffolding.

final class DrilldownShareTests: XCTestCase {

    private func item(_ name: String, c: Double? = nil, amount: String? = nil) -> DietItem {
        DietItem(item: name, amount: amount, cal: nil, p: nil, f: nil, c: c, fiber: nil)
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
}
