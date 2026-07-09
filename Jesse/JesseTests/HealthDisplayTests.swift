import XCTest
@testable import Jesse

// The pure view-logic seam: staleness, the updated-stamp, the weight card's
// same-day-vs-fallback resolution (BF/lean never carried forward), the
// moving-average builder, and per-section availability.

final class HealthDisplayTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        HealthDisplay.rfc3339(iso)!
    }

    // MARK: - Staleness

    func testNotStaleWhenTodayMatchesDeviceDay() {
        let now = date("2026-07-09T09:00:00Z")
        XCTAssertFalse(HealthDisplay.isStale(todayDate: "2026-07-09", now: now, calendar: utc))
    }

    func testStaleWhenTodayIsAPriorDay() {
        let now = date("2026-07-10T09:00:00Z")
        XCTAssertTrue(HealthDisplay.isStale(todayDate: "2026-07-09", now: now, calendar: utc))
    }

    // MARK: - Updated stamp

    func testUpdatedTimeRendersLocalHHMM() {
        // 13:34 UTC → 15:34 in a +02:00 zone.
        let tz = TimeZone(secondsFromGMT: 2 * 3600)!
        XCTAssertEqual(HealthDisplay.updatedTime(fromMtime: "2026-07-09T13:34:54Z", timeZone: tz), "15:34")
    }

    func testUpdatedTimeNilForAbsentOrGarbage() {
        XCTAssertNil(HealthDisplay.updatedTime(fromMtime: nil))
        XCTAssertNil(HealthDisplay.updatedTime(fromMtime: "not-a-date"))
    }

    // MARK: - Weight card

    private func wp(_ d: String, _ lbs: Double, kg: Double? = nil, bf: Double? = nil,
                    lean: Double? = nil) -> WeightPoint {
        WeightPoint(date: d, lbs: lbs, kg: kg, phase: nil, bf: bf, leanLbs: lean, notes: nil)
    }

    func testWeightCardSameDayWeighInShowsBfLeanAndDelta() {
        let today = DietToday(date: "2026-07-09",
                              weight: DietWeight(lbs: 197.4, kg: 89.5, bf: 18.1, mm: 150.2, notes: "steady"))
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0),
                      wp("2026-07-09", 197.4, bf: 18.1, lean: 150.2)]
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertTrue(card.isTodayWeighIn)
        XCTAssertEqual(card.lbs, 197.4)
        XCTAssertEqual(card.bf, 18.1)
        XCTAssertEqual(card.leanLbs, 150.2, "lean comes from today's muscle-mass field")
        XCTAssertEqual(card.deltaLbs!, 197.4 - 198.0, accuracy: 0.001, "delta vs the prior weigh-in")
        XCTAssertNil(card.lastWeighInDate)
    }

    func testWeightCardFallbackHidesBfLeanAndLabelsLastWeighIn() {
        // No weigh-in today → fall back to the last series entry; BF/lean must NOT
        // be carried forward even though the last entry has them.
        let today = DietToday(date: "2026-07-09", weight: nil)
        let series = [wp("2026-07-07", 199.0), wp("2026-07-08", 198.0, bf: 18.4, lean: 150.0)]
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertFalse(card.isTodayWeighIn)
        XCTAssertEqual(card.lbs, 198.0)
        XCTAssertNil(card.bf, "BF is never carried forward to a non-weigh-in day")
        XCTAssertNil(card.leanLbs, "lean is never carried forward either")
        XCTAssertEqual(card.lastWeighInDate, "2026-07-08")
        XCTAssertEqual(card.deltaLbs!, 198.0 - 199.0, accuracy: 0.001)
    }

    func testWeightCardNilWhenNoWeightAnywhere() {
        let today = DietToday(date: "2026-07-09", weight: nil)
        XCTAssertNil(HealthDisplay.weightCard(today: today, series: []))
        XCTAssertNil(HealthDisplay.weightCard(today: today, series: nil))
    }

    func testWeightCardSameDayWithNoPriorHasNilDelta() {
        let today = DietToday(date: "2026-07-09", weight: DietWeight(lbs: 197.4))
        let series = [wp("2026-07-09", 197.4)]   // only today's entry
        let card = HealthDisplay.weightCard(today: today, series: series)!
        XCTAssertNil(card.deltaLbs, "no prior weigh-in → no delta")
    }

    // MARK: - Moving average

    func testMovingAverageTrailingWindow() {
        let series = [wp("d1", 200), wp("d2", 198), wp("d3", 196), wp("d4", 202)]
        let ma = HealthDisplay.movingAverage(series, window: 3)
        XCTAssertEqual(ma.count, 4)
        XCTAssertEqual(ma[0].value, 200, accuracy: 0.001)                 // [200]
        XCTAssertEqual(ma[1].value, 199, accuracy: 0.001)                 // [200,198]
        XCTAssertEqual(ma[2].value, (200 + 198 + 196) / 3, accuracy: 0.001)
        XCTAssertEqual(ma[3].value, (198 + 196 + 202) / 3, accuracy: 0.001) // trailing 3
        XCTAssertEqual(ma[3].date, "d4")
    }

    func testMovingAverageEmpty() {
        XCTAssertTrue(HealthDisplay.movingAverage([], window: 7).isEmpty)
    }

    // MARK: - Availability

    func testAvailabilityPresent() {
        XCTAssertEqual(HealthDisplay.availability(present: true, label: "Progress", errors: []), .present)
    }

    func testAvailabilityUnavailableUsesMatchingErrorLine() {
        let errors = ["progress: json5 parse error at 1:14", "coach: cannot read file"]
        XCTAssertEqual(
            HealthDisplay.availability(present: false, label: "Progress", errors: errors),
            .unavailable("progress: json5 parse error at 1:14"))
    }

    func testAvailabilityUnavailableGenericWhenNoMatchingError() {
        XCTAssertEqual(
            HealthDisplay.availability(present: false, label: "Coach", errors: []),
            .unavailable("Coach unavailable"))
    }
}
