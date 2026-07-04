import XCTest
@testable import Jesse

/// Pure-logic tests for the recent-workouts subsection renderer: the per-workout
/// line (base fields), the droppable running-dynamics suffix, and the subsection
/// header. The window/cap/ordering/composition live in `HealthContextFormatter` and
/// are covered by `HealthContextTests`. Everything here is deterministic — a fixed
/// UTC calendar — so the rendered bytes are pinned.
final class WorkoutContextTests: XCTestCase {

    // Fixed UTC calendar so date rendering is deterministic regardless of host TZ.
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func swim(start: Date, source: String = "Apple Watch") -> WorkoutSummary {
        WorkoutSummary(activityName: "Swim", start: start, duration: 1800,
                       distanceMeters: 1500, activeEnergyKcal: 420,
                       averageHeartRateBPM: 132, maxHeartRateBPM: 158, source: source)
    }

    // MARK: - Base line (unchanged from the shipped feature — verbatim format)

    func testBaseLineRendersExactFormat() {
        let line = WorkoutContextFormatter.baseLine(for: swim(start: date(2026, 7, 4, 6, 30)),
                                                    timeZone: utc)
        XCTAssertEqual(line,
            "Swim — 2026-07-04 06:30, 30m, 1.5 km, 420 kcal, avg HR 132, max HR 158 (Apple Watch)")
    }

    func testBaseLineOmitsNilFieldsAndSource() {
        let bare = WorkoutSummary(activityName: "Walk", start: date(2026, 7, 4, 8, 0),
                                  duration: 3660, distanceMeters: nil, activeEnergyKcal: nil,
                                  averageHeartRateBPM: nil, maxHeartRateBPM: nil, source: nil)
        let line = WorkoutContextFormatter.baseLine(for: bare, timeZone: utc)
        XCTAssertEqual(line, "Walk — 2026-07-04 08:00, 1h01m")
        XCTAssertFalse(line.contains("("), "no source paren when source is nil")
    }

    func testHeaderSingularAndPlural() {
        XCTAssertEqual(WorkoutContextFormatter.header(count: 1),
                       "1 recent workout from Apple Health (last 48h, newest first):")
        XCTAssertEqual(WorkoutContextFormatter.header(count: 3),
                       "3 recent workouts from Apple Health (last 48h, newest first):")
    }

    // MARK: - Running-dynamics suffix

    private func run(dynamics: Bool) -> WorkoutSummary {
        WorkoutSummary(activityName: "Run", start: date(2026, 7, 4, 7, 0), duration: 2700,
                       distanceMeters: 8000, activeEnergyKcal: 500,
                       averageHeartRateBPM: 150, maxHeartRateBPM: 172, source: "Apple Watch",
                       averageRunningPowerW: dynamics ? 245 : nil,
                       groundContactTimeMs: dynamics ? 240 : nil,
                       verticalOscillationCm: dynamics ? 8.1 : nil,
                       strideLengthM: dynamics ? 1.15 : nil)
    }

    func testDynamicsSuffixRendersAllFields() {
        XCTAssertEqual(WorkoutContextFormatter.dynamicsSuffix(for: run(dynamics: true)),
                       ", power 245 W, GCT 240 ms, vert osc 8.1 cm, stride 1.15 m")
    }

    func testDynamicsSuffixEmptyWhenNoDynamics() {
        XCTAssertEqual(WorkoutContextFormatter.dynamicsSuffix(for: run(dynamics: false)), "")
        XCTAssertFalse(run(dynamics: false).hasRunningDynamics)
        XCTAssertTrue(run(dynamics: true).hasRunningDynamics)
    }

    func testDynamicsSuffixOmitsIndividualNilFields() {
        var r = run(dynamics: true)
        r.groundContactTimeMs = nil
        r.strideLengthM = nil
        XCTAssertEqual(WorkoutContextFormatter.dynamicsSuffix(for: r),
                       ", power 245 W, vert osc 8.1 cm")
    }

    func testFullLineAppendsDynamicsAfterBase() {
        XCTAssertEqual(WorkoutContextFormatter.line(for: run(dynamics: true), timeZone: utc),
            "Run — 2026-07-04 07:00, 45m, 8.0 km, 500 kcal, avg HR 150, max HR 172 (Apple Watch)"
            + ", power 245 W, GCT 240 ms, vert osc 8.1 cm, stride 1.15 m")
    }
}
