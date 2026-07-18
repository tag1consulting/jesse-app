import XCTest
import SwiftUI
@testable import Jesse

// The nutrition-label nutrient tree: carbohydrate is the parent of fibre AND total
// sugars; fat is the parent of saturated fat; sodium and potassium are standalone
// minerals. These lock the single canonical order source, the shared sub-entry model
// across BOTH enums, the preserved gauge semantics after the move, the shared indent,
// and the fixed per-nutrient education copy — so a regression can't quietly re-flatten
// the tree, flip a gauge, or drop the teaching.

final class NutrientTreeTests: XCTestCase {
    typealias S = DietSemantics

    // MARK: - Canonical order (the single source every listing derives from)

    func testMacroAreaOrderIsProteinCarbsFiberSugarsFatSatFatUnsatFat() {
        // Under Fat: saturated fat then the derived unsaturated fat, both sub-entries.
        XCTAssertEqual(NutrientOrder.macroArea, [
            .macro(.protein),
            .macro(.carbs),
            .macro(.fiber),
            .micronutrient(.totalSugars),
            .macro(.fat),
            .micronutrient(.saturatedFat),
            .micronutrient(.unsaturatedFat),
        ])
    }

    func testMineralsAreTheStandaloneEntriesInOrder() {
        // The Micronutrients section is the standalone entries only (no macro parent) —
        // saturated/unsaturated fat and total sugars sit under their parent macro.
        XCTAssertEqual(NutrientOrder.minerals,
                       [.sodium, .potassium, .calcium, .omega3, .magnesium])
    }

    func testMacroAreaNeverContainsAMineral() {
        // Standalone entries are not a component of any macro; they never appear among
        // the macro-area rows.
        for mineral in NutrientOrder.minerals {
            XCTAssertFalse(NutrientOrder.macroArea.contains(.micronutrient(mineral)),
                           "\(mineral) is standalone and must not sit in the macro area")
        }
    }

    // MARK: - Sub-entry model (parent links across both enums)

    func testMacroParents() {
        XCTAssertEqual(Macro.fiber.parent, .carbs)
        XCTAssertTrue(Macro.fiber.isSubEntry)
        for m in [Macro.protein, .carbs, .fat] {
            XCTAssertNil(m.parent)
            XCTAssertFalse(m.isSubEntry)
        }
    }

    func testMicronutrientParents() {
        XCTAssertEqual(Micronutrient.totalSugars.parent, .carbs)
        XCTAssertEqual(Micronutrient.saturatedFat.parent, .fat)
        XCTAssertEqual(Micronutrient.unsaturatedFat.parent, .fat)
        XCTAssertTrue(Micronutrient.totalSugars.isSubEntry)
        XCTAssertTrue(Micronutrient.saturatedFat.isSubEntry)
        XCTAssertTrue(Micronutrient.unsaturatedFat.isSubEntry)
        for standalone in [Micronutrient.sodium, .potassium, .calcium, .omega3, .magnesium] {
            XCTAssertNil(standalone.parent)
            XCTAssertFalse(standalone.isSubEntry)
        }
    }

    func testNutrientEntryReportsSubEntryFromEitherEnum() {
        XCTAssertTrue(NutrientEntry.macro(.fiber).isSubEntry)
        XCTAssertTrue(NutrientEntry.micronutrient(.totalSugars).isSubEntry)
        XCTAssertTrue(NutrientEntry.micronutrient(.saturatedFat).isSubEntry)
        XCTAssertTrue(NutrientEntry.micronutrient(.unsaturatedFat).isSubEntry)
        XCTAssertFalse(NutrientEntry.macro(.carbs).isSubEntry)
        XCTAssertFalse(NutrientEntry.macro(.fat).isSubEntry)
        XCTAssertFalse(NutrientEntry.micronutrient(.sodium).isSubEntry)
        XCTAssertFalse(NutrientEntry.micronutrient(.potassium).isSubEntry)
        XCTAssertFalse(NutrientEntry.micronutrient(.calcium).isSubEntry)
        XCTAssertFalse(NutrientEntry.micronutrient(.omega3).isSubEntry)
        XCTAssertFalse(NutrientEntry.micronutrient(.magnesium).isSubEntry)
    }

    // MARK: - Preserved gauge semantics after the move

    private func micro(na: Double? = nil, satf: Double? = nil,
                       sug: Double? = nil, k: Double? = nil) -> DietItem {
        DietItem(item: "x", amount: nil, cal: 0, p: 0, f: 0, c: 0, fiber: 0,
                 na: na, satf: satf, sug: sug, k: k)
    }
    private func day(_ items: [DietItem], targets: DietTargets = DietTargets()) -> DietToday {
        DietToday(date: "2026-07-16", dayStyle: "normal", dayType: nil, weight: nil,
                  exercise: [], meals: [DietMeal(name: "all", time: "12:00", items: items)],
                  targets: targets)
    }
    private func gauge(_ today: DietToday, _ n: Micronutrient) -> MetricGauge {
        S.micronutrientGauge(n, meals: today.meals, targets: today.targets)
    }

    func testSaturatedFatStaysACeilingAndUnknownAware() {
        // Still judged as a ceiling in its new sub-entry position.
        XCTAssertEqual(Micronutrient.saturatedFat.goal, .ceiling)
        XCTAssertTrue(Micronutrient.saturatedFat.judged)

        // Under the cap → green (a ceiling judgment survives the move).
        let complete = day([micro(satf: 8), micro(satf: 6)], targets: DietTargets(satFat: 20))
        XCTAssertEqual(gauge(complete, .saturatedFat).status, .green)

        // Partial → a floor ("≥"), the unknown item excluded, with an N-not-estimated caption.
        let partial = day([micro(satf: 8), micro(satf: nil)], targets: DietTargets(satFat: 20))
        let pg = gauge(partial, .saturatedFat)
        XCTAssertEqual(pg.value, 8, "the unknown item is excluded, not summed as 0")
        XCTAssertTrue(pg.partial)
        XCTAssertEqual(S.partialCaption(unknownItemCount: pg.unknownItemCount), "1 item not estimated")

        // All-unknown → "not tracked yet", no judgment.
        let none = day([micro(na: 500)], targets: DietTargets(satFat: 20))
        XCTAssertEqual(gauge(none, .saturatedFat).remaining, S.notTrackedCaption)
        XCTAssertEqual(gauge(none, .saturatedFat).status, .suspended)
    }

    func testTotalSugarsStaysInformationalWithNoJudgment() {
        XCTAssertFalse(Micronutrient.totalSugars.judged)
        // Even far over any reference, never red/green — like suspended fiber.
        let today = day([micro(sug: 40), micro(sug: 60)], targets: DietTargets(sugar: 50))
        let g = gauge(today, .totalSugars)
        XCTAssertEqual(g.value, 100)
        XCTAssertEqual(g.status, .suspended)
        XCTAssertEqual(g.goalStatus, .noGoal)
    }

    func testMineralsKeepTheirDirections() {
        XCTAssertEqual(Micronutrient.sodium.goal, .ceiling)
        XCTAssertEqual(Micronutrient.potassium.goal, .floor)
    }

    func testNewFloorNutrientsAreJudgedFloors() {
        for n in [Micronutrient.calcium, .omega3, .magnesium] {
            XCTAssertEqual(n.goal, .floor, "\(n) is a floor to reach")
            XCTAssertTrue(n.judged, "\(n) carries a red/green judgment")
        }
    }

    func testUnsaturatedFatIsInformationalAndDerivedUnderFat() {
        // Informational (never judged), no target, and a sub-entry of fat.
        XCTAssertFalse(Micronutrient.unsaturatedFat.judged)
        XCTAssertNil(Micronutrient.unsaturatedFat.target(in: DietTargets(satFat: 20)))
        XCTAssertEqual(Micronutrient.unsaturatedFat.parent, .fat)
        // Per-item value is fat − saturated fat, but only when saturated fat is known.
        let known = DietItem(item: "x", amount: nil, cal: 0, p: 0, f: 18, c: 0, fiber: 0, satf: 5)
        XCTAssertEqual(Micronutrient.unsaturatedFat.value(in: known), 13)
        let unknown = DietItem(item: "y", amount: nil, cal: 0, p: 0, f: 18, c: 0, fiber: 0, satf: nil)
        XCTAssertNil(Micronutrient.unsaturatedFat.value(in: unknown),
                     "an item with unknown saturated fat is UNKNOWN (partial), never derived from 0")
    }

    // MARK: - Shared indent (list/row surfaces only)

    func testSubEntryIndentIsPositiveAndTopLevelIsFlush() {
        XCTAssertGreaterThan(NutrientRowLayout.indent(isSubEntry: true), 0)
        XCTAssertEqual(NutrientRowLayout.indent(isSubEntry: false), 0)
    }

    func testEveryMacroAreaRowIndentsExactlyWhenItIsASubEntry() {
        for entry in NutrientOrder.macroArea {
            let indent = NutrientRowLayout.indent(isSubEntry: entry.isSubEntry)
            if entry.isSubEntry {
                XCTAssertGreaterThan(indent, 0, "\(entry) is a sub-entry and must indent")
            } else {
                XCTAssertEqual(indent, 0, "\(entry) is top-level and must sit flush")
            }
        }
    }

    func testIndentIsDrivenOnlyByStructureNotGaugeState() {
        // The indent depends solely on isSubEntry — so it reads identically whether a
        // target is set, and in the partial and all-unknown states.
        XCTAssertEqual(NutrientRowLayout.indent(isSubEntry: true),
                       NutrientRowLayout.subEntryIndent)
    }

    func testRingRowStaysFourEqualMacroPeers() {
        // The ring row iterates the four Macro peers — micronutrient sub-entries never
        // join it (no shrunk or indented ring), so the tree cue lives on the listings.
        XCTAssertEqual(Macro.allCases.count, 4)
        XCTAssertEqual(Macro.allCases, [.protein, .carbs, .fiber, .fat])
    }

    // MARK: - Fixed per-nutrient education copy

    private func education(_ n: Micronutrient) -> String { n.education.lowercased() }

    func testEveryNutrientExposesExactlyOneNonEmptyExplainer() {
        for n in Micronutrient.allCases {
            XCTAssertFalse(n.education.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(n) has no education copy")
        }
    }

    func testCeilingNutrientsSayStayUnderOrCap() {
        XCTAssertTrue(education(.sodium).contains("stay under") || education(.sodium).contains("under"),
                      "sodium education must frame a ceiling")
        XCTAssertTrue(education(.saturatedFat).contains("cap") || education(.saturatedFat).contains("ceiling"),
                      "saturated fat education must frame a ceiling")
    }

    func testPotassiumSaysReach() {
        XCTAssertTrue(education(.potassium).contains("reach"),
                      "potassium education must frame a floor to reach")
    }

    func testSaturatedFatExplainerMakesTheSubBudgetPoint() {
        // The key lesson: a slice of total fat with its own cap; the rest of fat is fine.
        XCTAssertTrue(education(.saturatedFat).contains("rest of your fat is fine"),
                      "saturated fat education must say the rest of fat is fine")
        XCTAssertTrue(education(.saturatedFat).contains("slice") ||
                      education(.saturatedFat).contains("sub-budget"),
                      "saturated fat education must frame it as one slice / sub-budget of total fat")
    }

    func testTotalSugarsExplainerStatesNoTargetAndCarriesNoJudgmentWord() {
        let copy = education(.totalSugars)
        XCTAssertTrue(copy.contains("no target"), "total sugars education must state there is no target")
        // No directional verdict language — it is informational only.
        for banned in ["over limit", "ceiling", "cap", "stay under", "exceed", "too much"] {
            XCTAssertFalse(copy.contains(banned),
                           "total sugars education must not carry the judgment word \"\(banned)\"")
        }
    }

    func testMicronutrientExplainerCarriesTheEducationNote() {
        // The sheet builder surfaces the fixed teaching as the subordinate note.
        let g = gauge(day([micro(na: 900)], targets: DietTargets(sodium: 2300)), .sodium)
        XCTAssertEqual(Explainers.micronutrient(.sodium, gauge: g).note, Micronutrient.sodium.education)
    }

    // MARK: - Drill-down from the new sub-entry positions

    func testSaturatedFatAndTotalSugarsOpenTheSharedDrilldown() {
        // The SAME shared FoodDrilldown builder the macros use, wired for the relocated
        // sub-entries — so tapping saturated fat / total sugars in their new positions
        // opens the identical enriched sheet.
        let today = day([micro(satf: 6, sug: 30), micro(satf: 4, sug: 10)],
                        targets: DietTargets(satFat: 20, sugar: 50))
        for n in [Micronutrient.saturatedFat, .totalSugars] {
            let g = gauge(today, n)
            let dd = FoodDrilldown.build(meals: today.meals, metric: .micronutrient(n),
                                         gauge: g, isCarbLoad: false)
            XCTAssertEqual(dd.breakdown.metric, .micronutrient(n))
            XCTAssertFalse(dd.breakdown.contributions.isEmpty,
                           "\(n) drill-down should list its contributing foods")
            XCTAssertEqual(Explainers.micronutrient(n, gauge: g).note, n.education)
        }
    }
}
