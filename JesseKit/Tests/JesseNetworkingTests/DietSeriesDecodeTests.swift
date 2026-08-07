import XCTest
@testable import JesseNetworking

// Decoding the two additive per-day history arrays on `GET /jesse/diet`:
// `sourceSeries` (per-ITEM food detail, most recent 45 days) and `exerciseSeries`
// (per-day kcal + session count, most recent 90). Both are optional, so an OLDER
// BRIDGE — which omits them entirely — must still decode the whole snapshot cleanly and
// simply report the fields absent. That is the graceful-degrade contract the affordances
// are gated on, and it is asserted here rather than assumed.
//
// The rule these shapes carry, and the one the assertions below are really about: an
// item's `n` holds ONLY the nutrient keys whose cell was known. A missing key is UNKNOWN,
// never 0, and nothing in decoding may quietly fill one in.

final class DietSeriesDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> DietSnapshot {
        try DietSnapshot.decode(from: Data(json.utf8))
    }

    /// The smallest valid snapshot: `today` alone. Extra top-level JSON is spliced in by
    /// the callers below.
    private func snapshot(extra: String) -> String {
        """
        {
          "asOf": "2026-08-07T09:00:00Z",
          "today": { "date": "2026-08-07", "meals": [], "exercise": [], "targets": {} },
          "errors": []\(extra.isEmpty ? "" : ",\n  " + extra)
        }
        """
    }

    // MARK: - sourceSeries

    func testSourceSeriesDecodes() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [
          { "date": "2026-08-06", "items": [
              { "name": "Pecorino", "n": { "cal": 110, "f": 9, "satf": 6, "na": 340 } },
              { "name": "Bread", "n": { "cal": 180, "c": 34, "fiber": 2 } }
          ] },
          { "date": "2026-08-07", "items": [
              { "name": "Pecorino", "n": { "cal": 110, "satf": 6 } }
          ] }
        ]
        """))

        let series = try XCTUnwrap(s.sourceSeries)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.map(\.date), ["2026-08-06", "2026-08-07"])
        XCTAssertEqual(series[0].items.map(\.name), ["Pecorino", "Bread"])
        XCTAssertEqual(series[0].items[0].n["satf"], 6)
        XCTAssertEqual(series[0].items[0].n["na"], 340)
    }

    /// The core rule at decode granularity: a nutrient the row never measured has NO key,
    /// and reading it back gives nil rather than 0. An item that knows some keys decodes
    /// exactly those.
    func testItemCarriesOnlyItsKnownKeys() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [
          { "date": "2026-08-07", "items": [
              { "name": "Leftover stew", "n": { "cal": 400, "p": 28 } }
          ] }
        ]
        """))

        let item = try XCTUnwrap(s.sourceSeries?.first?.items.first)
        XCTAssertEqual(item.n.count, 2)
        XCTAssertEqual(item.n["cal"], 400)
        XCTAssertEqual(item.n["p"], 28)
        // The unmeasured micros are ABSENT, not zero — the whole point of the shape.
        XCTAssertNil(item.n["satf"])
        XCTAssertNil(item.n["na"])
        XCTAssertNil(item.n["mg"])
    }

    /// A written 0 is a KNOWN zero and must survive decoding as a present key, so a
    /// downstream reader can tell "measured, contributed nothing" from "never measured".
    func testAWrittenZeroIsAKnownValueNotAMissingKey() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [
          { "date": "2026-08-07", "items": [ { "name": "Rice", "n": { "cal": 200, "satf": 0 } } ] }
        ]
        """))

        let item = try XCTUnwrap(s.sourceSeries?.first?.items.first)
        XCTAssertEqual(item.n["satf"], 0)
        XCTAssertNotNil(item.n.index(forKey: "satf"))
    }

    /// The bridge sends `[]` (never null) when the food log is missing, with a diagnostic
    /// in `errors`. An empty array decodes as present-but-empty, which the affordance gate
    /// treats as "nothing to show" rather than "old bridge" — either way it hides.
    func testEmptySourceSeriesDecodesAsPresentAndEmpty() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [], "exerciseSeries": []
        """))
        XCTAssertEqual(s.sourceSeries, [])
        XCTAssertEqual(s.exerciseSeries, [])
    }

    /// A day with no items at all still decodes (defaulted to empty) rather than failing
    /// the whole snapshot.
    func testSourceDayWithoutItemsDecodesEmpty() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [ { "date": "2026-08-07" } ]
        """))
        XCTAssertEqual(s.sourceSeries?.first?.items, [])
    }

    // MARK: - exerciseSeries

    func testExerciseSeriesDecodes() throws {
        let s = try decode(snapshot(extra: """
        "exerciseSeries": [
          { "date": "2026-08-05", "kcal": 812.5, "sessions": 2 },
          { "date": "2026-08-07", "kcal": 430, "sessions": 1 }
        ]
        """))

        let series = try XCTUnwrap(s.exerciseSeries)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0], ExerciseDay(date: "2026-08-05", kcal: 812.5, sessions: 2))
        XCTAssertEqual(series[1], ExerciseDay(date: "2026-08-07", kcal: 430, sessions: 1))
        // 2026-08-06 is simply ABSENT — a rest day is a gap, never an invented 0-kcal row.
        XCTAssertFalse(series.contains { $0.date == "2026-08-06" })
    }

    // MARK: - Graceful degrade (an older bridge)

    /// An older bridge omits BOTH fields. The snapshot must decode completely — every
    /// pre-existing section intact — with the two new fields nil, so the app hides the two
    /// new affordances and changes nothing else.
    func testOlderBridgeSnapshotOmittingBothFieldsStillDecodes() throws {
        let s = try decode("""
        {
          "asOf": "2026-08-07T09:00:00Z",
          "today": { "date": "2026-08-07", "meals": [], "exercise": [], "targets": { "calories": 2100 } },
          "weightSeries": [ { "date": "2026-08-06", "lbs": 191.2 } ],
          "nutrientSeries": [ { "date": "2026-08-06", "nutrients": { "cal": { "sum": 2050, "known": 9, "unknown": 1 } } } ],
          "errors": []
        }
        """)

        XCTAssertNil(s.sourceSeries)
        XCTAssertNil(s.exerciseSeries)
        // Everything that was already there is untouched.
        XCTAssertEqual(s.today.date, "2026-08-07")
        XCTAssertEqual(s.today.targets.calories, 2100)
        XCTAssertEqual(s.weightSeries?.count, 1)
        XCTAssertEqual(s.nutrientSeries?.count, 1)
    }

    /// Each field degrades INDEPENDENTLY: a bridge that sends one and not the other decodes
    /// with exactly one present, so only the affected affordance hides.
    func testEitherFieldMayBeAbsentOnItsOwn() throws {
        let sourcesOnly = try decode(snapshot(extra: """
        "sourceSeries": [ { "date": "2026-08-07", "items": [ { "name": "Eggs", "n": { "p": 18 } } ] } ]
        """))
        XCTAssertNotNil(sourcesOnly.sourceSeries)
        XCTAssertNil(sourcesOnly.exerciseSeries)

        let exerciseOnly = try decode(snapshot(extra: """
        "exerciseSeries": [ { "date": "2026-08-07", "kcal": 500, "sessions": 1 } ]
        """))
        XCTAssertNil(exerciseOnly.sourceSeries)
        XCTAssertNotNil(exerciseOnly.exerciseSeries)
    }

    /// A future bridge adding fields inside either shape decodes and ignores them, the same
    /// tolerance every other section has.
    func testUnknownKeysInsideTheNewShapesAreIgnored() throws {
        let s = try decode(snapshot(extra: """
        "sourceSeries": [ { "date": "2026-08-07", "meal": "Lunch",
                            "items": [ { "name": "Eggs", "amount": "3", "n": { "p": 18 } } ] } ],
        "exerciseSeries": [ { "date": "2026-08-07", "kcal": 500, "sessions": 1, "minutes": 42 } ]
        """))
        XCTAssertEqual(s.sourceSeries?.first?.items.first?.n["p"], 18)
        XCTAssertEqual(s.exerciseSeries?.first?.sessions, 1)
    }
}
