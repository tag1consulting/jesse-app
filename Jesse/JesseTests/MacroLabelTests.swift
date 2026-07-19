import XCTest
@testable import Jesse

// The canonical macro display names and the pure macro-line formatter that every
// Health-tab row renders. These lock the words in from one source: a future
// regression back to "P"/"C"/"F"/"Fib" fails here, not on the device.

@MainActor
final class MacroLabelTests: XCTestCase {

    // MARK: - Canonical names

    func testDisplayNamesAreFullWords() {
        XCTAssertEqual(Macro.protein.displayName, "Protein")
        XCTAssertEqual(Macro.carbs.displayName, "Carbs")
        XCTAssertEqual(Macro.fat.displayName, "Fat")
        XCTAssertEqual(Macro.fiber.displayName, "Fiber")
    }

    func testNoAbbreviationSurvivesInAnyName() {
        // No single-letter label and no "Fib" — ever. Guards the whole set at once.
        let banned: Set<String> = ["P", "C", "F", "Fib", "fib"]
        for macro in Macro.allCases {
            XCTAssertFalse(banned.contains(macro.displayName),
                           "\(macro) still renders the abbreviation \(macro.displayName)")
            XCTAssertGreaterThan(macro.displayName.count, 1)
        }
    }

    // MARK: - Micronutrient names (the second single-source label set)

    func testMicronutrientDisplayNamesAreFullAndUnabbreviated() {
        XCTAssertEqual(Micronutrient.sodium.displayName, "Sodium")
        XCTAssertEqual(Micronutrient.saturatedFat.displayName, "Saturated Fat")
        XCTAssertEqual(Micronutrient.unsaturatedFat.displayName, "Unsaturated Fat")
        XCTAssertEqual(Micronutrient.totalSugars.displayName, "Total Sugars")
        XCTAssertEqual(Micronutrient.potassium.displayName, "Potassium")
        XCTAssertEqual(Micronutrient.calcium.displayName, "Calcium")
        XCTAssertEqual(Micronutrient.omega3.displayName, "Omega-3 (EPA+DHA)")
        XCTAssertEqual(Micronutrient.magnesium.displayName, "Magnesium")
    }

    func testMicronutrientNamesCarryNoAbbreviation() {
        // No wire key or chemical symbol ever surfaces as a user-facing name.
        let banned: Set<String> = ["Na", "K", "SatFat", "Sat Fat", "Sugars", "Sugar", "na", "satf", "sug", "k"]
        for n in Micronutrient.allCases {
            XCTAssertFalse(banned.contains(n.displayName),
                           "\(n) still renders the abbreviation \(n.displayName)")
            XCTAssertGreaterThan(n.displayName.count, 3)
        }
    }

    func testMicronutrientCanonicalOrderAndUnits() {
        XCTAssertEqual(Micronutrient.allCases.map(\.displayName),
                       ["Sodium", "Saturated Fat", "Unsaturated Fat", "Total Sugars",
                        "Potassium", "Calcium", "Omega-3 (EPA+DHA)", "Magnesium"])
        // Minerals and omega-3 in mg, the fats and sugars in g.
        XCTAssertEqual(Micronutrient.allCases.map(\.unit),
                       ["mg", "g", "g", "g", "mg", "mg", "mg", "mg"])
    }

    // MARK: - Canonical display order (fiber is a subset of carbs → sits after it)

    func testCanonicalDisplayOrderIsProteinCarbsFiberFat() {
        // The one source of truth for macro order. Fiber is a subset of carbs, so it
        // sits immediately after carbs — never as a fourth peer after fat. Every
        // user-facing listing derives its order from this.
        XCTAssertEqual(Macro.allCases.map(\.displayName),
                       ["Protein", "Carbs", "Fiber", "Fat"])
    }

    func testFiberIsTheSubEntryOfCarbs() {
        // Fiber is a subset of carbs → a sub-entry of it; the other three are peers.
        XCTAssertEqual(Macro.fiber.parent, .carbs)
        XCTAssertTrue(Macro.fiber.isSubEntry)
        for macro in [Macro.protein, .carbs, .fat] {
            XCTAssertNil(macro.parent)
            XCTAssertFalse(macro.isSubEntry)
        }
    }

    // MARK: - Segments (the ordering source the styled caption view derives from)

    func testSegmentsAreInCanonicalOrderWithFiberFlagged() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 6)
        let segs = MacroLine.segments(t)
        XCTAssertEqual(segs.map(\.macro), Macro.allCases)   // Protein, Carbs, Fiber, Fat
        XCTAssertEqual(segs.map(\.text),
                       ["Protein 32g", "Carbs 40g", "Fiber 6g", "Fat 12g"])
        // Exactly the fiber segment is the sub-entry.
        XCTAssertEqual(segs.filter { $0.macro.isSubEntry }.map(\.macro), [.fiber])
    }

    func testSegmentsOmitFiberWhenExcluded() {
        let segs = MacroLine.segments(MacroTotals(cal: 0, p: 1, f: 3, c: 2, fiber: 4),
                                      includeFiber: false)
        XCTAssertEqual(segs.map(\.macro), [.protein, .carbs, .fat])
    }

    func testGramsForMacroMapsEachField() {
        let t = MacroTotals(cal: 999, p: 1, f: 2, c: 3, fiber: 4)
        XCTAssertEqual(t.grams(for: .protein), 1)
        XCTAssertEqual(t.grams(for: .fat), 2)
        XCTAssertEqual(t.grams(for: .carbs), 3)
        XCTAssertEqual(t.grams(for: .fiber), 4)
    }

    // MARK: - Full form (with gram units)

    func testFullFormWithUnits() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 6)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 32g · Carbs 40g · Fiber 6g · Fat 12g")
    }

    func testProteinCarbsFiberFatOrder() {
        // Order is protein · carbs · fiber · fat (fiber sits right after carbs).
        let t = MacroTotals(cal: 0, p: 1, f: 3, c: 2, fiber: 4)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 1g · Carbs 2g · Fiber 4g · Fat 3g")
    }

    // MARK: - Compact form (units dropped) and fiber omitted

    func testCompactFormDropsUnits() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 6)
        XCTAssertEqual(MacroLine.format(t, units: false),
                       "Protein 32 · Carbs 40 · Fiber 6 · Fat 12")
    }

    func testFiberAbsentOmitsTheFiberTerm() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 0)
        XCTAssertEqual(MacroLine.format(t, includeFiber: false),
                       "Protein 32g · Carbs 40g · Fat 12g")
    }

    // MARK: - Zero values

    func testZeroValuesRenderAsZero() {
        XCTAssertEqual(MacroLine.format(MacroTotals.zero),
                       "Protein 0g · Carbs 0g · Fiber 0g · Fat 0g")
    }

    // MARK: - Rounding parity with the rest of the Health tab

    func testRoundingMatchesDietSemanticsFmt() {
        // 32.4 → 32, 39.5 → 40 (half-up), 11.6 → 12, 6.5 → 7 — identical to the
        // fmt() used everywhere else, so the caption never disagrees with the rings.
        let t = MacroTotals(cal: 0, p: 32.4, f: 11.6, c: 39.5, fiber: 6.5)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 32g · Carbs 40g · Fiber 7g · Fat 12g")
        XCTAssertEqual(DietSemantics.fmt(t.p), "32")
        XCTAssertEqual(DietSemantics.fmt(t.c), "40")
        XCTAssertEqual(DietSemantics.fmt(t.f), "12")
        XCTAssertEqual(DietSemantics.fmt(t.fiber), "7")
    }
}
