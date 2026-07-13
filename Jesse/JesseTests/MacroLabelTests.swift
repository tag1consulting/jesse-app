import XCTest
@testable import Jesse

// The canonical macro display names and the pure macro-line formatter that every
// Health-tab row renders. These lock the words in from one source: a future
// regression back to "P"/"C"/"F"/"Fib" fails here, not on the device.

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

    // MARK: - Full form (with gram units)

    func testFullFormWithUnits() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 6)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 32g · Carbs 40g · Fat 12g · Fiber 6g")
    }

    func testProteinCarbsFatFiberOrder() {
        // Order is protein · carbs · fat · fiber (fat and carbs are NOT swapped).
        let t = MacroTotals(cal: 0, p: 1, f: 3, c: 2, fiber: 4)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 1g · Carbs 2g · Fat 3g · Fiber 4g")
    }

    // MARK: - Compact form (units dropped) and fiber omitted

    func testCompactFormDropsUnits() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 6)
        XCTAssertEqual(MacroLine.format(t, units: false),
                       "Protein 32 · Carbs 40 · Fat 12 · Fiber 6")
    }

    func testFiberAbsentOmitsTheFiberTerm() {
        let t = MacroTotals(cal: 0, p: 32, f: 12, c: 40, fiber: 0)
        XCTAssertEqual(MacroLine.format(t, includeFiber: false),
                       "Protein 32g · Carbs 40g · Fat 12g")
    }

    // MARK: - Zero values

    func testZeroValuesRenderAsZero() {
        XCTAssertEqual(MacroLine.format(MacroTotals.zero),
                       "Protein 0g · Carbs 0g · Fat 0g · Fiber 0g")
    }

    // MARK: - Rounding parity with the rest of the Health tab

    func testRoundingMatchesDietSemanticsFmt() {
        // 32.4 → 32, 39.5 → 40 (half-up), 11.6 → 12, 6.5 → 7 — identical to the
        // fmt() used everywhere else, so the caption never disagrees with the rings.
        let t = MacroTotals(cal: 0, p: 32.4, f: 11.6, c: 39.5, fiber: 6.5)
        XCTAssertEqual(MacroLine.format(t),
                       "Protein 32g · Carbs 40g · Fat 12g · Fiber 7g")
        XCTAssertEqual(DietSemantics.fmt(t.p), "32")
        XCTAssertEqual(DietSemantics.fmt(t.c), "40")
        XCTAssertEqual(DietSemantics.fmt(t.f), "12")
        XCTAssertEqual(DietSemantics.fmt(t.fiber), "7")
    }
}
