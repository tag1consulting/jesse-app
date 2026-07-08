import XCTest
@testable import Jesse

/// The pure `JESSE_MEAL_LOG v1` validator + streaming scrubber. Matrix: valid
/// single/multi-meal, optional macros, integer/float macros, and every rejection
/// (empty, over-cap, blank field, bad date, bad macro) collapsing the WHOLE block
/// to nil (never a partial write); plus the display scrubber (strip a trailing v1
/// line, keep prose, leave an unknown version visible).
final class MealLogParserTests: XCTestCase {

    private func meal(id: String = "2026-07-04-lunch",
                      consumedAt: String = "2026-07-04T12:30:00+02:00",
                      name: String = "Lunch: spaghetti, red sauce",
                      kcal: Double? = 385, protein: Double? = 13,
                      carbs: Double? = 77, fat: Double? = 4.5,
                      fiber: Double? = 6) -> JesseMeal {
        JesseMeal(id: id, consumedAt: consumedAt, name: name,
                  kcal: kcal, proteinGrams: protein, carbGrams: carbs, fatGrams: fat,
                  fiberGrams: fiber)
    }

    // MARK: - Validation / mapping

    func testFullMealMapsEveryField() {
        let meals = MealLogParser.meals(from: JesseMealLog(meals: [meal()]))
        XCTAssertEqual(meals?.count, 1)
        let m = meals![0]
        XCTAssertEqual(m.id, "2026-07-04-lunch")
        XCTAssertEqual(m.name, "Lunch: spaghetti, red sauce")
        XCTAssertEqual(m.kcal, 385)
        XCTAssertEqual(m.proteinGrams, 13)
        XCTAssertEqual(m.carbGrams, 77)
        XCTAssertEqual(m.fatGrams, 4.5)
        XCTAssertEqual(m.fiberGrams, 6)
        // The ISO-8601 offset is parsed to the correct instant.
        XCTAssertEqual(m.consumedAt, MealLogParser.parseDate("2026-07-04T12:30:00+02:00"))
    }

    func testMissingOptionalMacrosAreNil() {
        let m = meal(kcal: nil, protein: nil, carbs: nil, fat: nil, fiber: nil)
        let meals = MealLogParser.meals(from: JesseMealLog(meals: [m]))
        XCTAssertEqual(meals?.count, 1)
        XCTAssertNil(meals?[0].kcal)
        XCTAssertNil(meals?[0].proteinGrams)
        XCTAssertNil(meals?[0].carbGrams)
        XCTAssertNil(meals?[0].fatGrams)
        XCTAssertNil(meals?[0].fiberGrams)
    }

    func testMultiMealArrayPreservesOrder() {
        let a = meal(id: "b", name: "Oatmeal")
        let b = meal(id: "l", name: "Salad")
        let meals = MealLogParser.meals(from: JesseMealLog(meals: [a, b]))
        XCTAssertEqual(meals?.map(\.id), ["b", "l"])
    }

    func testZeroIsAValidMacro() {
        let meals = MealLogParser.meals(from: JesseMealLog(meals: [meal(kcal: 0)]))
        XCTAssertEqual(meals?[0].kcal, 0)
    }

    func testZeroFiberIsAValidMacro() {
        let meals = MealLogParser.meals(from: JesseMealLog(meals: [meal(fiber: 0)]))
        XCTAssertEqual(meals?[0].fiberGrams, 0)
    }

    func testEmptyArrayIsRejected() {
        XCTAssertNil(MealLogParser.meals(from: JesseMealLog(meals: [])))
    }

    func testOverMealsCapIsRejectedWholesale() {
        let many = (0...MealLogParser.maxMeals).map { meal(id: "m\($0)") } // maxMeals + 1
        XCTAssertNil(MealLogParser.meals(from: JesseMealLog(meals: many)))
    }

    func testAtMealsCapIsAccepted() {
        let atCap = (0..<MealLogParser.maxMeals).map { meal(id: "m\($0)") }
        XCTAssertEqual(MealLogParser.meals(from: JesseMealLog(meals: atCap))?.count, MealLogParser.maxMeals)
    }

    func testOneBadMealRejectsTheWholeBlock() {
        // The second meal has a blank name — the whole block is nil, never partial.
        let good = meal(id: "ok")
        let bad = meal(id: "bad", name: "   ")
        XCTAssertNil(MealLogParser.meals(from: JesseMealLog(meals: [good, bad])))
    }

    func testBlankIdRejected() {
        XCTAssertNil(MealLogParser.meal(from: meal(id: " ")))
    }

    func testUnparseableDateRejected() {
        XCTAssertNil(MealLogParser.meal(from: meal(consumedAt: "yesterday lunchtime")))
    }

    func testDateWithoutOffsetRejected() {
        // The contract requires an offset; a bare local time is not accepted.
        XCTAssertNil(MealLogParser.parseDate("2026-07-04T12:30:00"))
    }

    func testFractionalSecondsDateParses() {
        XCTAssertNotNil(MealLogParser.parseDate("2026-07-04T12:30:00.500+02:00"))
    }

    func testNegativeMacroRejected() {
        XCTAssertNil(MealLogParser.meal(from: meal(kcal: -5)))
    }

    func testNegativeFiberRejected() {
        XCTAssertNil(MealLogParser.meal(from: meal(fiber: -1)))
    }

    func testNonFiniteMacroRejected() {
        XCTAssertNil(MealLogParser.meal(from: meal(protein: .infinity)))
        XCTAssertNil(MealLogParser.meal(from: meal(carbs: .nan)))
        XCTAssertNil(MealLogParser.meal(from: meal(fiber: .infinity)))
    }

    // MARK: - Streaming display scrubber

    func testScrubberStripsTrailingV1LineKeepingProse() {
        let text = "Logged your lunch.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\"}]}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), "Logged your lunch.")
    }

    func testScrubberStripsSentinelOnlyPartialToEmpty() {
        let text = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\","  // mid-stream, incomplete
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), "")
    }

    func testScrubberLeavesTextWithoutBlockUnchanged() {
        let text = "Here is your answer.\n\nSecond paragraph."
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    func testScrubberDoesNotStripUnknownVersion() {
        // v2 is loud by contract — never scrubbed.
        let text = "Answer.\nJESSE_MEAL_LOG v2 {\"meals\":[]}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    func testScrubberDoesNotStripV10OrV11() {
        let text = "Answer.\nJESSE_MEAL_LOG v10 {}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    func testScrubberOnlyStripsTheFinalLine() {
        // A sentinel-looking line that is NOT last is prose (matches the bridge).
        let text = "JESSE_MEAL_LOG v1 {\"meals\":[]}\nBut actually here is your answer."
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }
}
