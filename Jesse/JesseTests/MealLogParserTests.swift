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
                      fiber: Double? = 6, sodium: Double? = nil,
                      satFat: Double? = nil, sugar: Double? = nil,
                      potassium: Double? = nil, calcium: Double? = nil,
                      magnesium: Double? = nil) -> JesseMeal {
        JesseMeal(id: id, consumedAt: consumedAt, name: name,
                  kcal: kcal, proteinGrams: protein, carbGrams: carbs, fatGrams: fat,
                  fiberGrams: fiber, sodiumMg: sodium, satFatGrams: satFat,
                  sugarGrams: sugar, potassiumMg: potassium,
                  calciumMg: calcium, magnesiumMg: magnesium)
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

    func testMicronutrientsPassThroughToTheDomainMeal() {
        // The four wire micronutrients validate and thread onto the domain Meal; an
        // absent one stays nil (never null-padded to 0).
        let wire = meal(sodium: 900, satFat: 3.5, sugar: 12, potassium: nil)
        let m = MealLogParser.meal(from: wire)
        XCTAssertEqual(m?.sodiumMg, 900)
        XCTAssertEqual(m?.satFatGrams, 3.5)
        XCTAssertEqual(m?.sugarGrams, 12)
        XCTAssertNil(m?.potassiumMg, "an absent micronutrient stays nil")
    }

    func testNegativeMicronutrientRejectsTheWholeMeal() {
        // A negative micronutrient is as invalid as a negative macro → nil (no partial).
        XCTAssertNil(MealLogParser.meal(from: meal(sodium: -1)))
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

    // (v2 is now a KNOWN version and IS scrubbed — see testScrubberStripsV2LineToo /
    // testScrubberDoesNotStripV3 below for the current unknown-version boundary.)

    func testScrubberDoesNotStripV10OrV11() {
        let text = "Answer.\nJESSE_MEAL_LOG v10 {}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    func testScrubberOnlyStripsTheFinalLine() {
        // A sentinel-looking line that is NOT last is prose (matches the bridge).
        let text = "JESSE_MEAL_LOG v1 {\"meals\":[]}\nBut actually here is your answer."
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    func testScrubberStripsV2LineToo() {
        // v2 is now a known version — its trailing line IS scrubbed from partial text.
        let text = "Moved it.\nJESSE_MEAL_LOG v2 {\"meals\":[],\"retract\":[\"a\"]}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), "Moved it.")
    }

    func testScrubberDoesNotStripV3() {
        // v3 and up stay visible (loud by contract).
        let text = "Answer.\nJESSE_MEAL_LOG v3 {\"meals\":[]}"
        XCTAssertEqual(MealLogParser.scrubbedStreamingText(text), text)
    }

    // MARK: - v2 batch (upserts + retracts + seq)

    private func log(_ meals: [JesseMeal] = [], retract: [String]? = nil,
                     seq: Int? = nil) -> JesseMealLog {
        JesseMealLog(meals: meals, retract: retract, correctionsSeq: seq)
    }

    func testV1DeliveryIsAnAllUpsertBatch() {
        // A v1 block (no retract, no seq) validates to an all-upsert batch — one seam,
        // both versions.
        let b = MealLogParser.batch(from: log([meal()]))
        XCTAssertEqual(b?.upserts.count, 1)
        XCTAssertTrue(b?.retracts.isEmpty ?? false)
        XCTAssertNil(b?.correctionsSeq)
    }

    func testV2BatchCarriesUpsertsRetractsAndSeq() {
        let b = MealLogParser.batch(from: log([meal(id: "new")], retract: ["old"], seq: 7))
        XCTAssertEqual(b?.upserts.map(\.id), ["new"])
        XCTAssertEqual(b?.retracts, ["old"])
        XCTAssertEqual(b?.correctionsSeq, 7)
    }

    func testRetractOnlyBatchIsValid() {
        let b = MealLogParser.batch(from: log(retract: ["a", "b"], seq: 3))
        XCTAssertTrue(b?.upserts.isEmpty ?? false)
        XCTAssertEqual(b?.retracts, ["a", "b"])
    }

    func testEmptyBatchNeitherMealsNorRetractIsRejected() {
        XCTAssertNil(MealLogParser.batch(from: log()), "nothing to do → malformed")
    }

    func testSameIdInBothMealsAndRetractIsRejected() {
        // A move uses DIFFERENT ids; the same id in both arrays is malformed → whole batch nil.
        XCTAssertNil(MealLogParser.batch(from: log([meal(id: "x")], retract: ["x"])))
    }

    func testBlankRetractIdRejectsTheWholeBatch() {
        XCTAssertNil(MealLogParser.batch(from: log([meal()], retract: ["  "])))
    }

    func testOverRetractCapIsRejectedWholesale() {
        let many = (0...MealLogParser.maxRetract).map { "r\($0)" } // maxRetract + 1
        XCTAssertNil(MealLogParser.batch(from: log(retract: many)))
    }

    func testAtRetractCapIsAccepted() {
        let atCap = (0..<MealLogParser.maxRetract).map { "r\($0)" }
        XCTAssertEqual(MealLogParser.batch(from: log(retract: atCap))?.retracts.count, MealLogParser.maxRetract)
    }

    func testBatchReusesPerMealValidation() {
        // A bad meal inside a v2 batch fails the whole batch (reuses meal(from:)).
        XCTAssertNil(MealLogParser.batch(from: log([meal(sodium: -1)], retract: ["a"])))
    }

    // MARK: - Content hash (absent ≠ 0, field-agnostic, order-stable)

    private func domain(kcal: Double? = 100, sodium: Double? = nil) -> Meal {
        Meal(id: "id", consumedAt: Date(timeIntervalSince1970: 1_780_000_000), name: "N",
             kcal: kcal, proteinGrams: nil, carbGrams: nil, fatGrams: nil, fiberGrams: nil,
             sodiumMg: sodium, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
    }

    func testIdenticalContentHashesEqual() {
        XCTAssertEqual(domain().contentHash, domain().contentHash)
    }

    func testAbsentAndZeroHashDifferently() {
        // The unknown ≠ zero law: a nil sodium and a 0 sodium must NOT hash the same.
        XCTAssertNotEqual(domain(sodium: nil).contentHash, domain(sodium: 0).contentHash)
    }

    func testAFirstSodiumEstimateChangesTheHash() {
        // A meal gaining its first sodium value hashes differently → triggers one rewrite.
        XCTAssertNotEqual(domain(sodium: nil).contentHash, domain(sodium: 900).contentHash)
    }

    func testADifferentSodiumValueChangesTheHash() {
        XCTAssertNotEqual(domain(sodium: 600).contentHash, domain(sodium: 900).contentHash)
    }

    func testNameChangeChangesTheHash() {
        let a = Meal(id: "id", consumedAt: Date(timeIntervalSince1970: 1_780_000_000), name: "A",
                     kcal: 100, proteinGrams: nil, carbGrams: nil, fatGrams: nil, fiberGrams: nil,
                     sodiumMg: nil, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
        let b = Meal(id: "id", consumedAt: Date(timeIntervalSince1970: 1_780_000_000), name: "B",
                     kcal: 100, proteinGrams: nil, carbGrams: nil, fatGrams: nil, fiberGrams: nil,
                     sodiumMg: nil, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    func testIdIsNotPartOfTheHash() {
        // The hash answers "did the CONTENT change?" — id is the store key, not content.
        let a = Meal(id: "id-1", consumedAt: Date(timeIntervalSince1970: 1_780_000_000), name: "N",
                     kcal: 100, proteinGrams: nil, carbGrams: nil, fatGrams: nil, fiberGrams: nil,
                     sodiumMg: nil, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
        let b = Meal(id: "id-2", consumedAt: Date(timeIntervalSince1970: 1_780_000_000), name: "N",
                     kcal: 100, proteinGrams: nil, carbGrams: nil, fatGrams: nil, fiberGrams: nil,
                     sodiumMg: nil, satFatGrams: nil, sugarGrams: nil, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
        XCTAssertEqual(a.contentHash, b.contentHash)
    }
}
