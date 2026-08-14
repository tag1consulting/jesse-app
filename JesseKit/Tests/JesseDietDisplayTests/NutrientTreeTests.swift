import XCTest
import SwiftUI
@testable import JesseDietDisplay
import JesseNetworking

// The nutrition-label nutrient tree: carbohydrate is the parent of fibre AND total
// sugars; fat is the parent of saturated fat; sodium and potassium are standalone
// minerals. These lock the single canonical order source, the shared sub-entry model
// across BOTH enums, the preserved gauge semantics after the move, the shared indent,
// and the fixed per-nutrient education copy — so a regression can't quietly re-flatten
// the tree, flip a gauge, or drop the teaching.

@MainActor
final class NutrientTreeTests: XCTestCase {
    typealias S = DietSemantics

    // MARK: - Canonical order (the single source every listing derives from)

    func testMacroAreaOrderIsTheFullTwoLevelLabelTree() {
        // Under Carbs: fiber, total sugars, and added sugar NESTED UNDER total sugars —
        // the second level, exactly as a label prints "Total Sugars / Includes Xg Added
        // Sugars". Under Fat: saturated, trans, the derived unsaturated share, cholesterol.
        XCTAssertEqual(NutrientOrder.macroArea, [
            .macro(.protein),
            .macro(.carbs),
            .macro(.fiber),
            .micronutrient(.totalSugars),
            .micronutrient(.addedSugar),
            .macro(.fat),
            .micronutrient(.saturatedFat),
            .micronutrient(.transFat),
            .micronutrient(.unsaturatedFat),
            .micronutrient(.cholesterol),
        ])
    }

    func testAddedSugarSitsOneLevelDeeperThanTotalSugars() {
        // The two-level tree, asserted at the model rather than only in the flat order:
        // added sugar's parent is a MICRONUTRIENT, and its depth is one past its parent's.
        XCTAssertEqual(Micronutrient.addedSugar.parent, .micronutrient(.totalSugars))
        XCTAssertEqual(Micronutrient.totalSugars.depth, 1)
        XCTAssertEqual(Micronutrient.addedSugar.depth, 2)
        XCTAssertEqual(NutrientEntry.micronutrient(.addedSugar).depth, 2)
        // ...and the indent follows the depth, one step per level.
        XCTAssertEqual(NutrientRowLayout.indent(depth: 2),
                       2 * NutrientRowLayout.subEntryIndent)
        XCTAssertGreaterThan(NutrientRowLayout.indent(depth: 2),
                             NutrientRowLayout.indent(depth: 1))
    }

    func testMercuryHasNoDayRowAnywhere() {
        // Mercury's limit exists only over a week, so it must not appear in the day-scoped
        // listings at all — a day row is the misreading the rolling gauge exists to prevent.
        XCTAssertFalse(Micronutrient.mercury.dayScoped)
        XCTAssertFalse(NutrientOrder.minerals.contains(.mercury))
        XCTAssertFalse(NutrientOrder.macroArea.contains(.micronutrient(.mercury)))
        XCTAssertEqual(NutrientOrder.rollingWindowed, [.omega3, .mercury])
        // Every OTHER nutrient does carry a day reading.
        for n in Micronutrient.allCases where n != .mercury {
            XCTAssertTrue(n.dayScoped, "\(n) should have a day-scoped row")
        }
    }

    func testMineralsAreTheStandaloneEntriesInOrder() {
        // The Micronutrients section is the standalone entries only (no macro parent) —
        // saturated/unsaturated fat and total sugars sit under their parent macro.
        XCTAssertEqual(NutrientOrder.minerals,
                       [.sodium, .potassium, .calcium, .omega3, .magnesium,
                        .selenium, .vitaminD, .purines])
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
        XCTAssertEqual(Micronutrient.totalSugars.parent, .macro(.carbs))
        XCTAssertEqual(Micronutrient.saturatedFat.parent, .macro(.fat))
        XCTAssertEqual(Micronutrient.unsaturatedFat.parent, .macro(.fat))
        XCTAssertEqual(Micronutrient.transFat.parent, .macro(.fat))
        XCTAssertEqual(Micronutrient.cholesterol.parent, .macro(.fat))
        for sub in [Micronutrient.totalSugars, .saturatedFat, .unsaturatedFat,
                    .transFat, .cholesterol, .addedSugar] {
            XCTAssertTrue(sub.isSubEntry, "\(sub) nests under another nutrient")
        }
        for standalone in [Micronutrient.sodium, .potassium, .calcium, .omega3, .magnesium,
                           .selenium, .vitaminD, .purines, .mercury] {
            XCTAssertNil(standalone.parent)
            XCTAssertFalse(standalone.isSubEntry)
            XCTAssertEqual(standalone.depth, 0)
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
        XCTAssertTrue(NutrientEntry.micronutrient(.addedSugar).isSubEntry)
        XCTAssertTrue(NutrientEntry.micronutrient(.transFat).isSubEntry)
        XCTAssertTrue(NutrientEntry.micronutrient(.cholesterol).isSubEntry)
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
        XCTAssertEqual(Micronutrient.unsaturatedFat.parent, .macro(.fat))
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

    // MARK: - Accuracy class in the education copy
    //
    // Every one of these numbers is an ESTIMATE, and they are not equally good estimates.
    // The copy has to say which kind each is, so a species-average figure is never read
    // with the confidence a label-derived one earns.

    func testLabelDerivedNutrientsSayTheyAreNearExact() {
        for n in [Micronutrient.addedSugar, .transFat] {
            let copy = education(n)
            XCTAssertTrue(copy.contains("near-exact"),
                          "\(n.displayName) must state it is label-derived and near-exact")
            XCTAssertTrue(copy.contains("label"), n.displayName)
        }
    }

    func testDatabaseLookupNutrientsSaySo() {
        for n in [Micronutrient.cholesterol, .vitaminD] {
            XCTAssertTrue(education(n).contains("database lookup"),
                          "\(n.displayName) must name its accuracy class")
            XCTAssertTrue(education(n).contains("solid"), n.displayName)
        }
    }

    func testSeleniumWarnsAboutItsNaturalVariance() {
        let copy = education(.selenium)
        XCTAssertTrue(copy.contains("soil"), copy)
        XCTAssertTrue(copy.contains("order of magnitude"), copy)
    }

    func testSpeciesAverageNutrientsDisclaimPrecision() {
        // Purines and mercury are species averages with a wide within-species spread. The
        // copy must say the spread is wide and that the figure is an order of magnitude —
        // never something to read to three significant figures.
        for n in [Micronutrient.purines, .mercury] {
            let copy = education(n)
            XCTAssertTrue(copy.contains("average"), "\(n.displayName): \(copy)")
            XCTAssertTrue(copy.contains("order of magnitude") || copy.contains("wide")
                          || copy.contains("varies enormously"),
                          "\(n.displayName) must disclaim precision: \(copy)")
            XCTAssertTrue(copy.contains("never a precise") || copy.contains("never the exact"),
                          "\(n.displayName) must say outright not to read the exact figure")
        }
    }

    func testCholesterolEducationMakesTheHDLLDLPointAndNamesTheRealLevers() {
        // The specific misconception this row exists to correct, and the three tracked
        // nutrients that actually move LDL — stated plainly, in one place.
        let copy = education(.cholesterol)
        XCTAssertTrue(copy.contains("no hdl and no ldl"), copy)
        XCTAssertTrue(copy.contains("saturated fat, trans fat, and fiber"), copy)
        XCTAssertTrue(copy.contains("no target"), copy)
    }

    func testInformationalRiskNutrientsCarryNoJudgmentWord() {
        // Same guard total sugars has: an informational row's teaching may not smuggle a
        // verdict in through its wording.
        for n in [Micronutrient.cholesterol, .purines] {
            let copy = education(n)
            XCTAssertFalse(n.judged, n.displayName)
            for banned in ["stay under", "exceed", "too much", "cut back"] {
                XCTAssertFalse(copy.contains(banned),
                               "\(n.displayName) education carries the judgment word \"\(banned)\"")
            }
        }
    }

    func testMercuryEducationNamesTheWindowAndNeverADailyLimit() {
        let copy = education(.mercury)
        XCTAssertTrue(copy.contains("7-day") || copy.contains("rolling"), copy)
        XCTAssertTrue(copy.contains("never on one day") || copy.contains("never on a single day"), copy)
        XCTAssertTrue(copy.contains("105µg a week"), copy)
    }

    func testTransFatEducationNamesBothKindsAndNeverClaimsZeroIsReachable() {
        // The copy that justified the unreachable ceiling told the user any reading above
        // zero was real industrial trans fat. It is not: the ruminant fraction of dairy
        // and beef is in every one of these numbers, which is why the goal is stated as
        // "no industrial trans fat" and never as a literal zero.
        let copy = education(.transFat)
        XCTAssertTrue(copy.contains("industrial"), copy)
        XCTAssertTrue(copy.contains("ruminant"), copy)
        XCTAssertTrue(copy.contains("no safe amount"), copy)
        XCTAssertTrue(copy.contains("expected"), "a small reading must read as expected: \(copy)")
        for banned in ["goal is literally none", "target is zero", "sit at zero"] {
            XCTAssertFalse(copy.contains(banned), "unreachable-goal language survives: \(banned)")
        }
    }

    func testTransFatSheetProseNamesBothKindsToo() {
        // The sheet's own paragraph, not just the teaching note — it carried the same
        // "a ceiling of zero, not a small budget" claim.
        let today = day([DietItem(item: "Greek yogurt (full-fat)", tfat: 0.05)])
        let prose = Explainers.micronutrient(.transFat, gauge: gauge(today, .transFat))
            .paragraphs.joined(separator: " ").lowercased()
        XCTAssertTrue(prose.contains("industrial"), prose)
        XCTAssertTrue(prose.contains("dairy and beef"), prose)
        XCTAssertFalse(prose.contains("ceiling of zero"), prose)
    }

    // MARK: - All seven open the SAME shared drill-down

    func testEverySevenNewNutrientOpensTheSharedSheetWithTheSameSemantics() {
        // One sheet, one ranking, one "Not estimated" group, one education note — the same
        // builder the macros use, for every one of the seven.
        let items = [
            DietItem(item: "Eggs", f: 10, satf: 3, chol: 370, tfat: 0, pur: 60, se: 30, vd: 2),
            DietItem(item: "Cola", sug: 40, asug: 40),
            DietItem(item: "Tuna", pur: 250, hg: 30, se: 90, vd: 5),
            DietItem(item: "Mystery stew"),   // measures nothing → the unknown group
        ]
        let today = day(items, targets: DietTargets(
            sugar: 80, transFat: 0, addedSugar: 40,
            selenium: DietBandTarget(floor: 55, ceiling: 300), vitaminD: 20))
        let seven: [Micronutrient] = [.cholesterol, .transFat, .addedSugar,
                                      .purines, .mercury, .selenium, .vitaminD]
        for n in seven {
            let g = S.micronutrientGauge(n, meals: today.meals, targets: today.targets, hour: 12)
            let dd = FoodDrilldown.build(meals: today.meals, metric: .micronutrient(n),
                                         gauge: g, isCarbLoad: false)
            XCTAssertEqual(dd.breakdown.metric, ContributionMetric.micronutrient(n),
                           n.displayName)
            // Contributors sorted most-impact first...
            let values: [Double] = dd.breakdown.contributions.map(\.value)
            XCTAssertEqual(values, values.sorted(by: >), "\(n.displayName) contributors unsorted")
            // ...the unmeasured item surfaced rather than dropped...
            XCTAssertTrue(dd.breakdown.unknownFoods.contains { $0.name == "Mystery stew" },
                          "\(n.displayName) dropped an unmeasured food instead of surfacing it")
            // ...the header a floor, so the sheet reads "≥"...
            XCTAssertTrue(dd.breakdown.isPartial, n.displayName)
            XCTAssertTrue(g.partial, n.displayName)
            // ...shares taken against the KNOWN total...
            for c in dd.breakdown.contributions where g.value > 0 {
                XCTAssertEqual(c.share, min(c.value / g.value, 1), accuracy: 0.0001, c.name)
            }
            // ...and the education note attached.
            XCTAssertEqual(Explainers.micronutrient(n, gauge: g).note, n.education)
        }
    }

    func testTheInformationalPairNeverGroundsAJudgment() {
        let today = day([DietItem(item: "Liver", chol: 500, pur: 900)])
        for n in [Micronutrient.cholesterol, .purines] {
            let g = S.micronutrientGauge(n, meals: today.meals, targets: today.targets, hour: 20)
            let dd = FoodDrilldown.build(meals: today.meals, metric: .micronutrient(n),
                                         gauge: g, isCarbLoad: false)
            XCTAssertTrue(dd.insightInput.informational, n.displayName)
            XCTAssertNil(dd.insightInput.goal, "\(n.displayName) must ground with no target")
            XCTAssertEqual(dd.insightInput.goalStatus, .noGoal, n.displayName)
        }
    }

    func testMercuryDrilldownListsTheWindowsFoodsNotTodays() {
        // The window row's contributors come from the trailing days of `sourceSeries`.
        // Today's meals hold a food the week does not; it must NOT appear here.
        let window = DietRollingWindow(
            days: 7, from: "2026-07-03", to: "2026-07-09",
            nutrients: ["mercury_ug": RollingNutrientTotal(known: 50, knownCount: 2,
                                                           unknownCount: 1)])
        let gauge = S.rollingWindowGauge(.mercury, window: window, targets: DietTargets())!
        let sources = [
            SourceDay(date: "2026-07-08", items: [SourceItem(name: "Tuna steak", n: ["hg": 30]),
                                                 SourceItem(name: "Bread", n: ["na": 400])]),
            SourceDay(date: "2026-07-09", items: [SourceItem(name: "Sardines", n: ["hg": 20])]),
            SourceDay(date: "2026-06-01", items: [SourceItem(name: "Ancient swordfish",
                                                             n: ["hg": 400])]),
        ]
        let dd = FoodDrilldown.buildWindow(sourceSeries: sources, nutrient: .mercury,
                                           gauge: gauge, window: gauge.rollingWindow!,
                                           through: window.to, isCarbLoad: false)
        XCTAssertEqual(dd.breakdown.contributions.map { $0.name }, ["Tuna steak", "Sardines"])
        XCTAssertFalse(dd.breakdown.contributions.contains { $0.name == "Ancient swordfish" },
                       "a day outside the 7-day window must not feed the list")
        XCTAssertEqual(dd.breakdown.unknownFoods.map { $0.name }, ["Bread"])
        // The grounding names the span, and no trend rides along (a per-day chart behind a
        // per-week number would be a different statistic).
        XCTAssertEqual(dd.insightInput.windowDays, 7)
        XCTAssertNil(dd.trend)
    }

    func testAWindowDrilldownWithNoSourceSeriesOpensHonestlyEmpty() {
        let window = DietRollingWindow(
            days: 7, from: "2026-07-03", to: "2026-07-09",
            nutrients: ["mercury_ug": RollingNutrientTotal(known: 50, knownCount: 2,
                                                           unknownCount: 0)])
        let gauge = S.rollingWindowGauge(.mercury, window: window, targets: DietTargets())!
        let dd = FoodDrilldown.buildWindow(sourceSeries: nil, nutrient: .mercury,
                                           gauge: gauge, window: gauge.rollingWindow!,
                                           through: window.to, isCarbLoad: false)
        XCTAssertTrue(dd.breakdown.isEmpty)
        XCTAssertNotNil(dd.breakdown.reconciliationNote,
                        "a header the list cannot account for says so rather than looking complete")
    }

    // MARK: - Identity colours stay distinct

    func testEveryStandaloneNutrientKeepsItsOwnIdentityHue() {
        let standalone = Micronutrient.allCases.filter { $0.parent == nil }
        let colors = standalone.map { MicronutrientColor.color(for: $0) }
        XCTAssertEqual(Set(colors.map(String.init(describing:))).count, standalone.count,
                       "two standalone nutrients share an identity colour")
    }
}
