import XCTest
@testable import Jesse

/// The `directives.meal_log` decode on both terminal wire shapes (poll result +
/// SSE `done` frame) and the `JesseReply.mealsToLog` validation seam. Pins the
/// snake_case macro keys and the camelCase `consumedAt`, and that an absent block
/// decodes to nil (the common case).
@MainActor
final class MealWireDecodeTests: XCTestCase {

    private func decodeResult(_ json: String) throws -> JesseResultResponse {
        try JSONDecoder().decode(JesseResultResponse.self, from: Data(json.utf8))
    }

    func testPollResultDecodesMealLog() throws {
        let json = """
        {"status":"done","response":"Logged your lunch.","session_id":"s1",
         "directives":{"meal_log":{"meals":[
           {"id":"2026-07-04-lunch","consumedAt":"2026-07-04T12:30:00+02:00",
            "name":"Lunch: spaghetti, red sauce","kcal":385,"protein_g":13,
            "carbs_g":77,"fat_g":4.5,"fiber_g":6}]}}}
        """
        let r = try decodeResult(json)
        let meals = try XCTUnwrap(r.directives?.mealLog?.meals)
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].id, "2026-07-04-lunch")
        XCTAssertEqual(meals[0].consumedAt, "2026-07-04T12:30:00+02:00")
        XCTAssertEqual(meals[0].name, "Lunch: spaghetti, red sauce")
        XCTAssertEqual(meals[0].kcal, 385)
        XCTAssertEqual(meals[0].proteinGrams, 13)   // protein_g
        XCTAssertEqual(meals[0].carbGrams, 77)      // carbs_g
        XCTAssertEqual(meals[0].fatGrams, 4.5)      // fat_g
        XCTAssertEqual(meals[0].fiberGrams, 6)      // fiber_g
    }

    func testOmittedMacrosDecodeToNil() throws {
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"a","consumedAt":"2026-07-04T15:00:00+02:00","name":"Apple"}]}}}
        """
        let meal = try XCTUnwrap(try decodeResult(json).directives?.mealLog?.meals.first)
        XCTAssertNil(meal.kcal)
        XCTAssertNil(meal.proteinGrams)
        XCTAssertNil(meal.carbGrams)
        XCTAssertNil(meal.fatGrams)
        XCTAssertNil(meal.fiberGrams)
    }

    func testAbsentDirectivesDecodeToNil() throws {
        let json = #"{"status":"done","response":"plain answer","session_id":"s"}"#
        let r = try decodeResult(json)
        XCTAssertNil(r.directives)
    }

    func testDirectivesPresentButNoMealLogDecodesNilMealLog() throws {
        let json = """
        {"status":"done","response":"","session_id":"s",
         "directives":{"needs_health":{"sections":["daily"]}}}
        """
        let r = try decodeResult(json)
        XCTAssertNotNil(r.directives)
        XCTAssertNil(r.directives?.mealLog)
    }

    func testSSEDoneFrameDecodesMealLog() throws {
        // The SSE `done` frame carries the same directives shape as the poll result.
        let json = """
        {"response":"Logged.","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"x","consumedAt":"2026-07-04T08:00:00+02:00","name":"Oatmeal","kcal":300}]}}}
        """
        let frame = try JSONDecoder().decode(JesseStreamFrameData.self, from: Data(json.utf8))
        XCTAssertEqual(frame.directives?.mealLog?.meals.first?.id, "x")
        XCTAssertEqual(frame.directives?.mealLog?.meals.first?.kcal, 300)
    }

    // MARK: - JesseReply.mealsToLog validation seam

    func testReplyMealsToLogValidatesAndMaps() throws {
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"a","consumedAt":"2026-07-04T12:30:00+02:00","name":"Lunch","kcal":400}]}}}
        """
        let r = try decodeResult(json)
        let reply = JesseReply(text: r.response ?? "", sessionId: r.sessionId, directives: r.directives)
        let meals = try XCTUnwrap(reply.mealsToLog)
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].id, "a")
        XCTAssertEqual(meals[0].kcal, 400)
    }

    func testReplyMealsToLogIsNilForAnInvalidBlock() {
        // A block whose date can't be parsed fails the app-side validation → nil,
        // never a partial write.
        let bad = JesseMealLog(meals: [JesseMeal(id: "a", consumedAt: "nope", name: "X",
                                                 kcal: nil, proteinGrams: nil,
                                                 carbGrams: nil, fatGrams: nil,
                                                 fiberGrams: nil, sodiumMg: nil,
                                                 satFatGrams: nil, sugarGrams: nil,
                                                 potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)])
        let reply = JesseReply(text: "ok", sessionId: nil,
                               directives: JesseDirectives(needsHealth: nil, mealLog: bad))
        XCTAssertNil(reply.mealsToLog)
    }

    func testReplyMealsToLogIsNilWithoutDirective() {
        XCTAssertNil(JesseReply(text: "plain", sessionId: nil).mealsToLog)
    }

    // MARK: - v2 wire (retract + corrections_seq)

    func testPollResultDecodesRetractAndCorrectionsSeq() throws {
        let json = """
        {"status":"done","response":"Moved it.","session_id":"s",
         "directives":{"meal_log":{
           "meals":[{"id":"2026-07-04-snack-1630","consumedAt":"2026-07-04T16:30:00+02:00",
                     "name":"Snack","sodium_mg":900}],
           "retract":["2026-07-04-snack-1500"],
           "corrections_seq":42}}}
        """
        let ml = try XCTUnwrap(try decodeResult(json).directives?.mealLog)
        XCTAssertEqual(ml.meals.first?.sodiumMg, 900)
        XCTAssertEqual(ml.retract, ["2026-07-04-snack-1500"])
        XCTAssertEqual(ml.correctionsSeq, 42)
    }

    func testV1DeliveryDecodesNilRetractAndSeq() throws {
        // An older/v1 delivery omits both v2 keys → they decode to nil (backward compatible).
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"a","consumedAt":"2026-07-04T12:30:00+02:00","name":"Lunch","kcal":400}]}}}
        """
        let ml = try XCTUnwrap(try decodeResult(json).directives?.mealLog)
        XCTAssertNil(ml.retract)
        XCTAssertNil(ml.correctionsSeq)
    }

    func testReplyMealBatchValidatesV2Delivery() throws {
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{
           "meals":[{"id":"new","consumedAt":"2026-07-04T12:30:00+02:00","name":"Lunch"}],
           "retract":["old"],"corrections_seq":9}}}
        """
        let r = try decodeResult(json)
        let reply = JesseReply(text: r.response ?? "", sessionId: r.sessionId, directives: r.directives)
        let b = try XCTUnwrap(reply.mealBatch)
        XCTAssertEqual(b.upserts.map(\.id), ["new"])
        XCTAssertEqual(b.retracts, ["old"])
        XCTAssertEqual(b.correctionsSeq, 9)
    }

    func testMealBlockDecodesCalciumAndMagnesium() throws {
        // calcium_mg / magnesium_mg parse like the other HealthKit-bound micros; the meal
        // wire has NO omega-3 field (gauge-only), so `JesseMeal` never carries one.
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"a","consumedAt":"2026-07-04T12:30:00+02:00","name":"Salmon plate",
            "sodium_mg":600,"potassium_mg":800,"calcium_mg":250,"magnesium_mg":90}]}}}
        """
        let meal = try XCTUnwrap(try decodeResult(json).directives?.mealLog?.meals.first)
        XCTAssertEqual(meal.calciumMg, 250)
        XCTAssertEqual(meal.magnesiumMg, 90)
        // The other HealthKit micros still parse alongside them.
        XCTAssertEqual(meal.sodiumMg, 600)
        XCTAssertEqual(meal.potassiumMg, 800)
    }

    func testMealBlockOmittingCalciumMagnesiumDecodesToNil() throws {
        // An older bridge (or a meal with no known calcium/magnesium) omits both → nil,
        // never a summed 0.
        let json = """
        {"status":"done","response":"ok","session_id":"s",
         "directives":{"meal_log":{"meals":[
           {"id":"a","consumedAt":"2026-07-04T12:30:00+02:00","name":"Apple","kcal":95}]}}}
        """
        let meal = try XCTUnwrap(try decodeResult(json).directives?.mealLog?.meals.first)
        XCTAssertNil(meal.calciumMg)
        XCTAssertNil(meal.magnesiumMg)
    }

    func testSSEDoneFrameDecodesRetractAndSeq() throws {
        let json = """
        {"response":"Moved.","session_id":"s",
         "directives":{"meal_log":{"meals":[],"retract":["gone"],"corrections_seq":3}}}
        """
        let frame = try JSONDecoder().decode(JesseStreamFrameData.self, from: Data(json.utf8))
        XCTAssertEqual(frame.directives?.mealLog?.retract, ["gone"])
        XCTAssertEqual(frame.directives?.mealLog?.correctionsSeq, 3)
    }
}
