import XCTest
@testable import Jesse

// The order-consuming surfaces derive their macro order from the canonical
// `Macro.allCases`, not from hand-written rows. These lock the two seams the rings
// row and the Macros screen iterate (`DietGauges.orderedMacros`) and the calorie
// bar iterates (`CalorieSplit.fraction(for:)`), so the shipped Fat-before-Fiber
// order can't come back through a view body.

final class MacroOrderTests: XCTestCase {
    typealias S = DietSemantics

    private func day(p: Double, f: Double, c: Double, fiber: Double) -> DietToday {
        let item = DietItem(item: "x", amount: nil, cal: 0, p: p, f: f, c: c, fiber: fiber)
        return DietToday(date: "2026-07-12", dayStyle: nil, exercise: [],
                         meals: [DietMeal(name: "m", time: nil, items: [item])],
                         targets: DietTargets(protein: 100, fat: 65, carbs: 300, fiber: 38))
    }

    func testOrderedMacrosIsCanonicalAndMapsEachGauge() {
        let g = S.gauges(for: day(p: 30, f: 20, c: 40, fiber: 6), hour: 9)
        XCTAssertEqual(g.orderedMacros.map(\.macro), Macro.allCases)   // Protein, Carbs, Fiber, Fat
        // Each slot carries that macro's own gauge — not a shuffled one.
        XCTAssertEqual(g.orderedMacros.map(\.gauge), [g.protein, g.carbs, g.fiber, g.fat])
        XCTAssertEqual(g.gauge(for: .protein), g.protein)
        XCTAssertEqual(g.gauge(for: .carbs), g.carbs)
        XCTAssertEqual(g.gauge(for: .fiber), g.fiber)
        XCTAssertEqual(g.gauge(for: .fat), g.fat)
    }

    func testFiberSitsImmediatelyAfterCarbsInOrderedMacros() {
        let g = S.gauges(for: day(p: 30, f: 20, c: 40, fiber: 6), hour: 9)
        let order = g.orderedMacros.map(\.macro)
        let carbsIndex = order.firstIndex(of: .carbs)!
        XCTAssertEqual(order[carbsIndex + 1], .fiber, "fiber must sit immediately after carbs")
    }

    func testCalorieSplitFractionMapsCarbsToNetAndFiberSeparately() {
        // Carbs 40g (6g of it fiber) → carbs segment carries NET carbs, fiber its own.
        let split = HealthDisplay.calorieSplit(MacroTotals(cal: 0, p: 30, f: 20, c: 40, fiber: 6))
        XCTAssertEqual(split.fraction(for: .protein), split.proteinFraction)
        XCTAssertEqual(split.fraction(for: .carbs), split.netCarbsFraction)
        XCTAssertEqual(split.fraction(for: .fiber), split.fiberFraction)
        XCTAssertEqual(split.fraction(for: .fat), split.fatFraction)
        // Carbs segment is net (excludes fiber), fiber is its own non-zero slice.
        XCTAssertGreaterThan(split.fraction(for: .fiber), 0)
        XCTAssertLessThan(split.fraction(for: .carbs), split.fraction(for: .protein) + 1)
    }
}
