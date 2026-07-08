import XCTest
@testable import Jesse

/// The `directives.meal_log` decode on both terminal wire shapes (poll result +
/// SSE `done` frame) and the `JesseReply.mealsToLog` validation seam. Pins the
/// snake_case macro keys and the camelCase `consumedAt`, and that an absent block
/// decodes to nil (the common case).
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
                                                 fiberGrams: nil)])
        let reply = JesseReply(text: "ok", sessionId: nil,
                               directives: JesseDirectives(needsHealth: nil, mealLog: bad))
        XCTAssertNil(reply.mealsToLog)
    }

    func testReplyMealsToLogIsNilWithoutDirective() {
        XCTAssertNil(JesseReply(text: "plain", sessionId: nil).mealsToLog)
    }
}
