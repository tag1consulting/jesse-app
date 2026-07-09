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
