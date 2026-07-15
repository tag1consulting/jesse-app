import XCTest
@testable import Jesse

// Decoding the `GET /jesse/diet` snapshot: a full populated body, a degraded body
// (null sections + a non-empty errors array), unknown-key tolerance, and the
// status→error mapping in `JesseClient.decodeDiet`.

final class DietSnapshotDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> DietSnapshot {
        try DietSnapshot.decode(from: Data(json.utf8))
    }

    // A realistic, fully-populated snapshot (invented data).
    private let full = """
    {
      "asOf": "2026-07-09T14:50:55Z",
      "todayMtime": "2026-07-09T13:34:54Z",
      "today": {
        "date": "2026-07-09",
        "dayStyle": "normal",
        "dayType": "Normal training day",
        "weight": { "lbs": 197.4, "kg": 89.5, "bf": 18.1, "mm": 150.2, "notes": "steady" },
        "exercise": [
          { "type": "run", "time": "06:30", "desc": "easy 5", "distance": 5, "unit": "mi",
            "duration": "43:20", "pace": "8:40", "avgHR": 138, "calories": 520 }
        ],
        "meals": [
          { "name": "Breakfast", "time": "07:15", "items": [
            { "item": "Oatmeal", "amount": "1 cup", "cal": 300, "p": 10, "f": 5, "c": 54, "fiber": 8 },
            { "item": "Eggs", "amount": "3", "cal": 210, "p": 18, "f": 15, "c": 1, "fiber": 0 }
          ] }
        ],
        "targets": { "calories": 2100, "protein": 190, "fat": 65, "carbs": 210, "carbsBase": 180, "fiber": 38 }
      },
      "proposed": {
        "date": "2026-07-09", "source": "coach",
        "ideas": [ { "name": "Snack", "time": "~15:00",
          "items": [ { "item": "Yogurt", "amount": "1 cup", "cal": 150, "p": 20, "f": 4, "c": 9, "fiber": 0 } ],
          "notes": "protein top-up" } ],
        "gapNote": "30g short on protein."
      },
      "progress": {
        "startWeight": 204, "raceTarget": 165, "maintTarget": 180, "raceDate": "2026-10-11",
        "troughPace": 1.4, "rawPace": 1.1, "paceZone": "good", "barColor": "#4caf50",
        "raceBarLabel": "24 of 39 lb", "maintBarLabel": "21 of 24 lb", "trajectory": "On track."
      },
      "coach": {
        "date": "2026-07-09", "title": "Steady progress",
        "notes": [ "<strong>Great week</strong> &mdash; protein every day" ],
        "ahead": [ "Long run Saturday" ],
        "quote": { "text": "Discipline.", "author": "Lincoln" }
      },
      "weightSeries": [
        { "date": "2026-07-07", "lbs": 198.0, "kg": 89.8, "phase": "Phase 2", "bf": null, "leanLbs": null, "notes": null },
        { "date": "2026-07-08", "lbs": 197.4, "kg": 89.5, "phase": "Phase 2", "bf": 18.1, "leanLbs": 150.2, "notes": "weighed after run, felt light" }
      ],
      "errors": []
    }
    """

    func testDecodesFullSnapshot() throws {
        let s = try decode(full)
        XCTAssertEqual(s.asOf, "2026-07-09T14:50:55Z")
        XCTAssertEqual(s.todayMtime, "2026-07-09T13:34:54Z")
        XCTAssertEqual(s.today.date, "2026-07-09")
        XCTAssertEqual(s.today.dayStyle, "normal")
        XCTAssertEqual(s.today.weight?.bf, 18.1)
        XCTAssertEqual(s.today.exercise.first?.avgHR, 138)
        XCTAssertEqual(s.today.meals.first?.items.count, 2)
        XCTAssertEqual(s.today.meals.first?.items.first?.fiber, 8)
        XCTAssertEqual(s.today.targets.carbsBase, 180)
        XCTAssertEqual(s.proposed?.ideas.first?.name, "Snack")
        XCTAssertEqual(s.progress?.raceBarLabel, "24 of 39 lb")
        XCTAssertEqual(s.coach?.notes.first, "<strong>Great week</strong> &mdash; protein every day")
        XCTAssertEqual(s.coach?.quote?.author, "Lincoln")
        XCTAssertEqual(s.weightSeries?.count, 2)
        // Blank CSV cells decoded to null → nil optionals.
        XCTAssertNil(s.weightSeries?.first?.bf)
        XCTAssertEqual(s.weightSeries?.last?.leanLbs, 150.2)
        XCTAssertEqual(s.weightSeries?.last?.notes, "weighed after run, felt light")
        XCTAssertTrue(s.errors.isEmpty)
    }

    // A degraded snapshot: today present (the endpoint's 200 floor), every other
    // section null, and a non-empty errors array. Old-style today with no dayStyle
    // and no weigh-in.
    private let degraded = """
    {
      "asOf": "2026-07-09T14:50:55Z",
      "todayMtime": null,
      "today": {
        "date": "2026-07-09",
        "dayType": "Rest day",
        "weight": null,
        "exercise": [],
        "meals": [ { "name": "Lunch", "time": "12:30", "items": [ { "item": "Salad", "cal": 250, "p": 8, "f": 12, "c": 20 } ] } ],
        "targets": { "calories": 1900, "protein": 180, "fat": 60, "carbs": 190 }
      },
      "proposed": null,
      "progress": null,
      "coach": null,
      "weightSeries": null,
      "errors": ["progress: json5 parse error at 1:14", "coach: cannot read diet-coach-notes.js"]
    }
    """

    func testDecodesDegradedSnapshot() throws {
        let s = try decode(degraded)
        XCTAssertNil(s.todayMtime)
        XCTAssertNil(s.today.dayStyle, "absent dayStyle → nil")
        XCTAssertNil(s.today.weight, "non-weigh-in day → nil weight")
        XCTAssertNil(s.today.targets.carbsBase, "absent carbsBase → nil")
        XCTAssertNil(s.today.targets.fiber, "absent fiber → nil (defaults to 38 downstream)")
        // Item with no fiber decodes to nil (not zero-padded).
        XCTAssertNil(s.today.meals.first?.items.first?.fiber)
        XCTAssertNil(s.proposed)
        XCTAssertNil(s.progress)
        XCTAssertNil(s.coach)
        XCTAssertNil(s.weightSeries)
        XCTAssertEqual(s.errors.count, 2)
        XCTAssertTrue(s.errors[0].hasPrefix("progress:"))
    }

    // MARK: - Day-history additive fields (bridge ≥ 0.7.0)

    func testTodayResponseCarriesLiveHistoryFields() throws {
        // The plain today `full` body now also carries availableDays/historical/
        // fidelity — decoded here as live + not historical (they're absent above, so
        // this asserts the defaults an OLD bridge produces are correct too).
        let s = try decode(full)
        XCTAssertFalse(s.isHistorical, "absent historical → today")
        XCTAssertEqual(s.fidelityKind, .live, "absent fidelity → live")
        XCTAssertFalse(s.isNeutral)
        XCTAssertNil(s.availableDays, "old payload without availableDays decodes to nil")
    }

    // A full archived past day: targets present, judged like today, plus the three
    // history fields.
    private let archived = """
    {
      "asOf": "2026-07-12T09:00:00Z", "todayMtime": "2026-04-16T06:10:00Z",
      "today": {
        "date": "2026-04-15", "dayStyle": "carb-load-training", "dayType": "Carb-load",
        "weight": null, "exercise": [],
        "meals": [ { "name": "Dinner", "time": "19:00", "items": [
          { "item": "Pasta", "amount": "2 cups", "cal": 600, "p": 20, "f": 8, "c": 110, "fiber": 6 } ] } ],
        "targets": { "calories": 2800, "protein": 150, "fat": 55, "carbs": 400 }
      },
      "proposed": null, "progress": null, "coach": null,
      "weightSeries": [ { "date": "2026-04-15", "lbs": 200.8 } ],
      "errors": [],
      "availableDays": ["2026-03-30", "2026-04-15", "2026-07-12"],
      "historical": true, "fidelity": "archived"
    }
    """

    func testDecodesArchivedPastDay() throws {
        let s = try decode(archived)
        XCTAssertTrue(s.isHistorical)
        XCTAssertEqual(s.fidelityKind, .archived)
        XCTAssertFalse(s.isNeutral, "an archived day is judged, not neutral")
        XCTAssertEqual(s.today.targets.calories, 2800, "archived targets present")
        XCTAssertEqual(s.today.dayStyle, "carb-load-training")
        XCTAssertEqual(s.availableDays, ["2026-03-30", "2026-04-15", "2026-07-12"])
        // History requests carry null proposed/progress/coach.
        XCTAssertNil(s.proposed); XCTAssertNil(s.progress); XCTAssertNil(s.coach)
    }

    // A reconstructed past day: targets null → neutral rendering.
    private let reconstructed = """
    {
      "asOf": "2026-07-12T09:00:00Z", "todayMtime": null,
      "today": {
        "date": "2026-04-15", "dayStyle": null, "dayType": null,
        "weight": { "lbs": 200.8, "kg": 91.1, "bf": 28.5, "mm": 136.2, "notes": "backfilled" },
        "exercise": [ { "type": "run", "time": "06:30", "distance": 8.0, "unit": "km", "duration": "56:58" } ],
        "meals": [ { "name": "Lunch", "time": null, "items": [
          { "item": "Sandwich", "amount": "1 ea", "cal": 450, "p": 25, "f": 18, "c": 48, "fiber": 4 } ] } ],
        "targets": null
      },
      "proposed": null, "progress": null, "coach": null,
      "weightSeries": [], "errors": [],
      "availableDays": ["2026-04-15", "2026-07-12"],
      "historical": true, "fidelity": "reconstructed"
    }
    """

    func testDecodesReconstructedPastDayWithNullTargets() throws {
        let s = try decode(reconstructed)
        XCTAssertTrue(s.isHistorical)
        XCTAssertEqual(s.fidelityKind, .reconstructed)
        XCTAssertTrue(s.isNeutral, "reconstructed → neutral (no judgment)")
        // targets: null decodes to the empty DietTargets (all nil), never crashes.
        XCTAssertNil(s.today.targets.calories, "reconstructed day has no recorded targets")
        XCTAssertNil(s.today.dayStyle)
        XCTAssertEqual(s.today.meals.first?.items.first?.item, "Sandwich")
        XCTAssertNil(s.today.meals.first?.time, "null meal time decodes to nil")
        XCTAssertEqual(s.today.exercise.first?.unit, "km")
        XCTAssertEqual(s.today.weight?.mm, 136.2)
    }

    func testLegacyPayloadWithoutNewFieldsStillDecodes() throws {
        // A pre-0.7.0 bridge omits all three fields entirely → today, live, no paging.
        let s = try decode(degraded)
        XCTAssertFalse(s.isHistorical)
        XCTAssertEqual(s.fidelityKind, .live)
        XCTAssertNil(s.availableDays)
    }

    // MARK: - Micronutrients (na / satf / sug / k) — unknown ≠ zero

    // A day where one item carries all four micronutrients and a second carries none,
    // plus the four optional day targets.
    private let micros = """
    {
      "asOf": "2026-07-09T14:50:55Z",
      "today": {
        "date": "2026-07-09", "exercise": [],
        "meals": [ { "name": "Lunch", "time": "12:30", "items": [
          { "item": "Soup", "cal": 200, "p": 8, "f": 6, "c": 20, "fiber": 3,
            "na": 900, "satf": 2.5, "sug": 4, "k": 300 },
          { "item": "Bread", "cal": 150, "p": 5, "f": 2, "c": 28, "fiber": 2 }
        ] } ],
        "targets": { "calories": 2100, "protein": 190, "fat": 65, "carbs": 210,
          "sodium": 2300, "satFat": 20, "potassium": 3500, "sugar": 50 }
      },
      "errors": []
    }
    """

    func testDecodesMicronutrientsWhenPresent() throws {
        let s = try decode(micros)
        let items = try XCTUnwrap(s.today.meals.first?.items)
        // First item carries all four.
        XCTAssertEqual(items[0].na, 900)
        XCTAssertEqual(items[0].satf, 2.5)
        XCTAssertEqual(items[0].sug, 4)
        XCTAssertEqual(items[0].k, 300)
        // Second item lacks all four → nil (UNKNOWN), never zero-padded.
        XCTAssertNil(items[1].na)
        XCTAssertNil(items[1].satf)
        XCTAssertNil(items[1].sug)
        XCTAssertNil(items[1].k)
        // The four optional day targets decode.
        XCTAssertEqual(s.today.targets.sodium, 2300)
        XCTAssertEqual(s.today.targets.satFat, 20)
        XCTAssertEqual(s.today.targets.potassium, 3500)
        XCTAssertEqual(s.today.targets.sugar, 50)
    }

    func testItemLackingMicronutrientsDecodesToNil() throws {
        // The `full` body carries none of the four new item keys → all nil, and the
        // whole payload still decodes cleanly (no key is required).
        let s = try decode(full)
        let item = try XCTUnwrap(s.today.meals.first?.items.first)
        XCTAssertNil(item.na)
        XCTAssertNil(item.satf)
        XCTAssertNil(item.sug)
        XCTAssertNil(item.k)
        // Absent target keys → nil.
        XCTAssertNil(s.today.targets.sodium)
        XCTAssertNil(s.today.targets.satFat)
        XCTAssertNil(s.today.targets.potassium)
        XCTAssertNil(s.today.targets.sugar)
    }

    func testUnknownKeysAreIgnored() throws {
        // A future generator field we don't model must not break decode.
        let json = """
        { "asOf": "t", "today": { "date": "2026-07-09", "exercise": [], "meals": [],
          "targets": {}, "futureField": {"nested": 1} }, "errors": [], "brandNewTopLevel": 42 }
        """
        let s = try decode(json)
        XCTAssertEqual(s.today.date, "2026-07-09")
    }

    // MARK: - decodeDiet status mapping

    private func resp(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://laptop:8765/jesse/diet")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testDecodeDietMapsHappyPath() throws {
        let s = try JesseClient.decodeDiet(data: Data(full.utf8), resp: resp(200))
        XCTAssertEqual(s.today.date, "2026-07-09")
    }

    func testDecodeDietMaps401ToAuthFailed() {
        assertDietError(code: 401, data: Data(), expected: .authFailed)
    }

    func testDecodeDietMaps404ToEndpointMissing() {
        assertDietError(code: 404, data: Data(), expected: .endpointMissing)
    }

    func testDecodeDietMaps503ToUnavailable() {
        assertDietError(code: 503, data: Data(#"{"error":"broken"}"#.utf8), expected: .unavailable)
    }

    func testDecodeDietMapsGarbageBodyToDecodeFailed() {
        assertDietError(code: 200, data: Data("not json".utf8), expected: .decodeFailed)
    }

    func testDecodeDietMapsOther5xxToServer() {
        assertDietError(code: 500, data: Data(), expected: .server(500))
    }

    private func assertDietError(code: Int, data: Data, expected: DietFetchError,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try JesseClient.decodeDiet(data: data, resp: resp(code)),
                             file: file, line: line) { err in
            XCTAssertEqual(err as? DietFetchError, expected, file: file, line: line)
        }
    }
}
