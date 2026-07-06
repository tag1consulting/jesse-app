import XCTest
@testable import Jesse

/// The app half of the JESSE_NEEDS_HEALTH channel: request validation (whitelist,
/// window range, metric cap — reject the WHOLE request, never partially fulfill),
/// the pure series formatter, and the fulfillment assembler's 6 KiB cap.
final class RequestableMetricTests: XCTestCase {

    // MARK: - Validation

    func testValidRequestParses() {
        let r = NeedsHealthRequest.validated(
            sections: ["daily", "workouts"],
            metrics: [(metric: "restingHeartRate", windowDays: 14),
                      (metric: "stepCount", windowDays: 7)])
        XCTAssertEqual(r?.sections, [.daily, .workouts])
        XCTAssertEqual(r?.metrics, [
            ValidatedMetricRequest(metric: .restingHeartRate, windowDays: 14),
            ValidatedMetricRequest(metric: .stepCount, windowDays: 7),
        ])
    }

    func testSectionsOnlyOrMetricsOnlyAreValid() {
        XCTAssertNotNil(NeedsHealthRequest.validated(sections: ["daily"], metrics: []))
        XCTAssertNotNil(NeedsHealthRequest.validated(
            sections: [], metrics: [(metric: "vo2Max", windowDays: 30)]))
    }

    func testEmptyRequestIsRejected() {
        XCTAssertNil(NeedsHealthRequest.validated(sections: [], metrics: []))
    }

    func testUnknownSectionRejectsWholeRequest() {
        XCTAssertNil(NeedsHealthRequest.validated(
            sections: ["daily", "weather"], metrics: [(metric: "stepCount", windowDays: 3)]))
    }

    func testUnknownMetricRejectsWholeRequest() {
        // Even with a valid section present, one bad metric fails the whole request.
        XCTAssertNil(NeedsHealthRequest.validated(
            sections: ["daily"], metrics: [(metric: "bloodPressure", windowDays: 7)]))
    }

    func testWindowOutOfRangeRejected() {
        XCTAssertNil(NeedsHealthRequest.validated(
            sections: [], metrics: [(metric: "stepCount", windowDays: 0)]))
        XCTAssertNil(NeedsHealthRequest.validated(
            sections: [], metrics: [(metric: "stepCount", windowDays: 32)]))
        // Boundaries are accepted.
        XCTAssertNotNil(NeedsHealthRequest.validated(
            sections: [], metrics: [(metric: "stepCount", windowDays: 1)]))
        XCTAssertNotNil(NeedsHealthRequest.validated(
            sections: [], metrics: [(metric: "stepCount", windowDays: 31)]))
    }

    func testMoreThanFourMetricsRejected() {
        let five = (0..<5).map { _ in (metric: "stepCount", windowDays: 7) }
        XCTAssertNil(NeedsHealthRequest.validated(sections: [], metrics: five))
        let four = (0..<4).map { _ in (metric: "stepCount", windowDays: 7) }
        XCTAssertNotNil(NeedsHealthRequest.validated(sections: [], metrics: four))
    }

    // MARK: - Series formatter

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    func testSeriesFormatterNewestFirstWithUnits() {
        let series = [
            MetricSeriesPoint(date: day("2026-07-01"), value: 58),
            MetricSeriesPoint(date: day("2026-07-03"), value: 60),
            MetricSeriesPoint(date: day("2026-07-02"), value: 59),
        ]
        let lines = MetricSeriesFormatter.lines(for: .restingHeartRate, series: series,
                                                timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines.first, "Resting heart rate (last 3 days):")
        // Newest first, bpm unit.
        XCTAssertEqual(lines[1], "  2026-07-03: 60 bpm")
        XCTAssertEqual(lines[2], "  2026-07-02: 59 bpm")
        XCTAssertEqual(lines[3], "  2026-07-01: 58 bpm")
    }

    func testSeriesFormatterEmptyReportsNoData() {
        let lines = MetricSeriesFormatter.lines(for: .stepCount, series: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("no data"))
    }

    func testSeriesFormatterUnitsPerMetric() {
        let one = [MetricSeriesPoint(date: day("2026-07-01"), value: 72.4)]
        func value(_ m: RequestableMetric) -> String {
            MetricSeriesFormatter.lines(for: m, series: one,
                                        timeZone: TimeZone(identifier: "UTC")!)[1]
        }
        XCTAssertTrue(value(.bodyMass).hasSuffix("72.4 kg"))
        XCTAssertTrue(value(.stepCount).hasSuffix("72 steps"))
        XCTAssertTrue(value(.sleepAnalysis).hasSuffix("72 min"))
        XCTAssertTrue(value(.vo2Max).hasSuffix("72.4 ml/kg·min"))
    }

    // MARK: - Fulfiller cap (whole-line truncation)

    func testCapTruncatesOnWholeLines() {
        let line = String(repeating: "x", count: 100)
        let many = Array(repeating: line, count: 200).joined(separator: "\n") // ~20 KiB
        let capped = HealthRequestFulfiller.capWholeLines(many, maxBytes: 6 * 1024)
        XCTAssertLessThanOrEqual(capped.utf8.count, 6 * 1024)
        // Never a partial line: every kept line is the full 100 chars.
        for l in capped.split(separator: "\n") {
            XCTAssertEqual(l.count, 100, "cap must not split a line")
        }
    }

    func testCapNoOpUnderBudget() {
        let s = "one\ntwo\nthree"
        XCTAssertEqual(HealthRequestFulfiller.capWholeLines(s, maxBytes: 6 * 1024), s)
    }
}
