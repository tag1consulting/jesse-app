import XCTest
@testable import Jesse

/// Pure-logic tests for the recent-workouts subsection renderer: the per-workout
/// line (base fields), the three droppable suffixes (running dynamics, workout
/// detail, per-km splits), the two reducers that feed them, and the subsection
/// header. The window/cap/ordering/composition live in `HealthContextFormatter` and
/// are covered by `HealthContextTests`. Everything here is deterministic — a fixed
/// UTC calendar — so the rendered bytes are pinned.
@MainActor
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

    // MARK: - Base line

    func testBaseLineRendersExactFormat() {
        let line = WorkoutContextFormatter.baseLine(for: swim(start: date(2026, 7, 4, 6, 30)),
                                                    timeZone: utc)
        XCTAssertEqual(line,
            "Swim — 2026-07-04 06:30, 30m, 1500 m, 420 kcal, avg HR 132, max HR 158 (Apple Watch)")
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

    /// The segments concatenate in the order the byte cap sheds them from the right:
    /// base, dynamics, detail, splits. This run has no splits, and the only detail
    /// it can produce is the pace its distance and duration imply.
    func testFullLineAppendsDynamicsThenDetailAfterBase() {
        XCTAssertEqual(WorkoutContextFormatter.line(for: run(dynamics: true), timeZone: utc),
            "Run — 2026-07-04 07:00, 45m, 8.00 km, 500 kcal, avg HR 150, max HR 172 (Apple Watch)"
            + ", power 245 W, GCT 240 ms, vert osc 8.1 cm, stride 1.15 m"
            + ", pace 5:38/km (computed)")
    }

    // MARK: - Distance format (the rounding that used to eat a swim's pace)

    /// A swim prints whole meters at any length. `1650 m` rounded to `1.6 km` put a
    /// 14-second band on any per-100m pace computed from it — the reason for the
    /// split format rather than one rule for everything.
    func testSwimDistanceIsWholeMetersAtAnyLength() {
        var s = swim(start: date(2026, 7, 4, 6, 30))
        s.distanceMeters = 1650
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: s, timeZone: utc)
            .contains(", 1650 m,"))
        s.distanceMeters = 800
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: s, timeZone: utc)
            .contains(", 800 m,"))
    }

    /// Everything else keeps kilometers, but to two decimals — 10 m of resolution,
    /// enough that a per-km pace is exact to the second.
    func testNonSwimDistanceIsTwoDecimalKilometers() {
        var r = run(dynamics: false)
        r.distanceMeters = 7840
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: r, timeZone: utc)
            .contains(", 7.84 km,"))
        r.distanceMeters = 850
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: r, timeZone: utc)
            .contains(", 850 m,"), "under a kilometer stays whole meters")
    }

    /// The recording device's model rides inside the existing source parentheses,
    /// so a hardware change is visible in the data.
    func testProductTypeJoinsTheSourceParenthetical() {
        var r = run(dynamics: false)
        r.productType = "Watch7,5"
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: r, timeZone: utc)
            .hasSuffix(" (Apple Watch, Watch7,5)"))
        r.source = nil
        XCTAssertTrue(WorkoutContextFormatter.baseLine(for: r, timeZone: utc)
            .hasSuffix(" (Watch7,5)"), "product type alone still parenthesizes")
    }

    // MARK: - Swim lap reducer

    private func lap(_ minute: Int, seconds: Double, stroke: Int?, swolf: Double?) -> SwimLap {
        let start = date(2026, 7, 4, 6, 30).addingTimeInterval(Double(minute) * 60)
        return SwimLap(start: start, end: start.addingTimeInterval(seconds),
                       strokeStyleRawValue: stroke, swolf: swolf)
    }

    func testLapReducerMixedStrokes() {
        let laps = [
            lap(0, seconds: 45, stroke: 2, swolf: 52),   // freestyle
            lap(1, seconds: 44, stroke: 2, swolf: 50),
            lap(2, seconds: 60, stroke: 4, swolf: 66),   // breaststroke
            lap(3, seconds: 46, stroke: 2, swolf: 54),
        ]
        let r = SwimLapReducer.reduce(laps)!
        XCTAssertEqual(r.lapCount, 4)
        XCTAssertEqual(r.swimSeconds, 195, accuracy: 0.001)
        XCTAssertEqual(r.averageSWOLF!, 55.5, accuracy: 0.001)
        XCTAssertEqual(r.lapsByStroke, ["freestyle": 3, "breaststroke": 1])
    }

    /// A lap with no SWOLF still counts toward the lap count and the swim time; it
    /// only narrows the average's base.
    func testLapReducerMissingSWOLFOnSomeLaps() {
        let laps = [
            lap(0, seconds: 45, stroke: 2, swolf: 52),
            lap(1, seconds: 45, stroke: 2, swolf: nil),
            lap(2, seconds: 45, stroke: 2, swolf: 58),
        ]
        let r = SwimLapReducer.reduce(laps)!
        XCTAssertEqual(r.lapCount, 3, "the scoreless lap is still a lap")
        XCTAssertEqual(r.swimSeconds, 135, accuracy: 0.001)
        XCTAssertEqual(r.averageSWOLF!, 55, accuracy: 0.001, "averaged over the two scores")
        XCTAssertEqual(r.lapsByStroke, ["freestyle": 3])
    }

    func testLapReducerNoSWOLFAtAllAndUnknownStrokes() {
        let laps = [lap(0, seconds: 45, stroke: nil, swolf: nil),
                    lap(1, seconds: 45, stroke: 99, swolf: nil)]
        let r = SwimLapReducer.reduce(laps)!
        XCTAssertEqual(r.lapCount, 2)
        XCTAssertNil(r.averageSWOLF, "no score anywhere → no average, not a zero")
        XCTAssertTrue(r.lapsByStroke.isEmpty, "an unmapped raw value is uncounted")
    }

    func testLapReducerZeroLapsIsNil() {
        XCTAssertNil(SwimLapReducer.reduce([]))
    }

    /// The stroke names are pinned to HealthKit's `HKSwimmingStrokeStyle` raw
    /// values 0…6; out-of-range values map to nothing.
    func testStrokeNameRawValueMapping() {
        XCTAssertEqual((0...6).map { SwimLapReducer.strokeName($0) },
                       ["unknown", "mixed", "freestyle", "backstroke",
                        "breaststroke", "butterfly", "kickboard"])
        XCTAssertNil(SwimLapReducer.strokeName(7))
        XCTAssertNil(SwimLapReducer.strokeName(-1))
    }

    // MARK: - Split reducer

    private func sample(_ offset: Double, _ length: Double, _ meters: Double) -> DistanceSample {
        let base = date(2026, 7, 4, 7, 0)
        return DistanceSample(start: base.addingTimeInterval(offset),
                              end: base.addingTimeInterval(offset + length), meters: meters)
    }

    /// A km boundary inside a sample is interpolated, not attributed to the whole
    /// sample: 600 m in 60 s then 800 m in 80 s crosses 1000 m 40 s into the second.
    func testSplitReducerInterpolatesABoundaryInsideASample() {
        let splits = SplitReducer.splitSeconds([sample(0, 60, 600), sample(60, 80, 800)])
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0], 100, accuracy: 0.001)
    }

    /// The last, incomplete kilometer produces no split at all.
    func testSplitReducerPartialFinalKmProducesNoSplit() {
        // 1400 m in 7 even 200 m samples of 60 s each.
        let samples = (0..<7).map { sample(Double($0) * 60, 60, 200) }
        let splits = SplitReducer.splitSeconds(samples)
        XCTAssertEqual(splits.count, 1, "only the completed kilometer")
        XCTAssertEqual(splits[0], 300, accuracy: 0.001)
    }

    func testSplitReducerEmptyInput() {
        XCTAssertEqual(SplitReducer.splitSeconds([]), [])
        XCTAssertEqual(SplitReducer.splitSeconds([sample(0, 60, 0)]), [],
                       "a zero-distance sample contributes nothing")
    }

    /// Several boundaries inside ONE sample all come out, and a gap between samples
    /// (a pause) lands in the split that contains it — an elapsed pace, by design.
    func testSplitReducerMultipleBoundariesAndAGap() {
        XCTAssertEqual(SplitReducer.splitSeconds([sample(0, 900, 3000)]),
                       [300, 300, 300])
        // 1000 m in 300 s, a 60 s gap, then 1000 m in 300 s.
        let gapped = SplitReducer.splitSeconds([sample(0, 300, 1000), sample(360, 300, 1000)])
        XCTAssertEqual(gapped.count, 2)
        XCTAssertEqual(gapped[0], 300, accuracy: 0.001)
        XCTAssertEqual(gapped[1], 360, accuracy: 0.001, "the pause is inside the second km")
    }

    // MARK: - Detail suffix

    /// Every new field nil → the line is byte-identical to the base line and
    /// nothing more. This is the guarantee that absent data renders nothing.
    func testAllNewFieldsNilRendersExactlyTheBaseLine() {
        let bare = WorkoutSummary(activityName: "Workout", start: date(2026, 7, 4, 9, 0),
                                  duration: 1200, distanceMeters: nil,
                                  activeEnergyKcal: 130, source: "iPhone")
        let base = WorkoutContextFormatter.baseLine(for: bare, timeZone: utc)
        XCTAssertEqual(WorkoutContextFormatter.detailSuffix(for: bare), "")
        XCTAssertEqual(WorkoutContextFormatter.splitsSuffix(for: bare), "")
        XCTAssertEqual(WorkoutContextFormatter.dynamicsSuffix(for: bare), "")
        XCTAssertEqual(WorkoutContextFormatter.line(for: bare, timeZone: utc), base)
        XCTAssertEqual(base, "Workout — 2026-07-04 09:00, 20m, 130 kcal (iPhone)")
    }

    func testDetailSuffixCommonFields() {
        var w = run(dynamics: false)
        w.isIndoor = true
        w.effortScore = 6
        w.effortScoreIsUserRated = true
        w.averageMETs = 7.2
        w.weatherTemperatureC = 18
        w.weatherHumidityPercent = 60
        w.stepCount = nil
        XCTAssertEqual(WorkoutContextFormatter.detailSuffix(for: w),
                       ", indoor, effort 6/10 (rated), avg METs 7.2, temp 18 C, humidity 60%"
                       + ", pace 5:38/km (computed)")
        w.isIndoor = false
        w.effortScoreIsUserRated = false
        XCTAssertTrue(WorkoutContextFormatter.detailSuffix(for: w)
            .hasPrefix(", outdoor, effort 6/10 (est), "))
    }

    /// The fixture swim: every `SwimDetail` field set, asserted verbatim.
    private func fullSwim() -> WorkoutSummary {
        WorkoutSummary(activityName: "Swim", start: date(2026, 7, 4, 6, 30), duration: 3300,
                       distanceMeters: 1650, activeEnergyKcal: 430,
                       averageHeartRateBPM: 132, maxHeartRateBPM: 158,
                       source: "Apple Watch", productType: "Watch7,5",
                       isIndoor: true, averageMETs: 7.2,
                       effortScore: 6, effortScoreIsUserRated: true,
                       weatherTemperatureC: 18, weatherHumidityPercent: 60,
                       swim: SwimDetail(lapLengthM: 25, location: .pool, lapCount: 66,
                                        strokeCount: 1840, swimSeconds: 2890,
                                        averageSWOLF: 52, waterTemperatureC: 27.5,
                                        lapsByStroke: ["freestyle": 60, "breaststroke": 6]))
    }

    func testFullSwimLineRendersExactly() {
        XCTAssertEqual(WorkoutContextFormatter.line(for: fullSwim(), timeZone: utc),
            "Swim — 2026-07-04 06:30, 55m, 1650 m, 430 kcal, avg HR 132, max HR 158"
            + " (Apple Watch, Watch7,5)"
            + ", indoor, effort 6/10 (rated), avg METs 7.2, temp 18 C, humidity 60%"
            + ", pool 25 m, 66 laps, 1840 strokes, swim time 48m10s"
            + ", pace 2:55/100m (computed, swim time), SWOLF 52, water 27.5 C"
            + ", strokes: freestyle 60, breaststroke 6")
    }

    /// Without lap times the swim pace falls back to the elapsed duration and says
    /// so, and open water has no pool length.
    func testSwimPaceFallsBackToElapsedAndOpenWaterHasNoLength() {
        var w = fullSwim()
        w.swim?.swimSeconds = nil
        w.swim?.location = .openWater
        w.swim?.lapLengthM = nil
        let detail = WorkoutContextFormatter.detailSuffix(for: w)
        XCTAssertTrue(detail.contains(", open water, "))
        XCTAssertTrue(detail.contains("pace 3:20/100m (computed)"),
                      "elapsed 3300s over 16.5 hundreds, and marked plain (computed)")
        XCTAssertFalse(detail.contains("swim time"))
    }

    /// Stroke counts are ordered by lap count then name, so the bytes never depend
    /// on dictionary ordering.
    func testStrokeBreakdownIsSortedByCountThenName() {
        var w = fullSwim()
        w.swim?.lapsByStroke = ["butterfly": 4, "backstroke": 4, "freestyle": 20]
        XCTAssertTrue(WorkoutContextFormatter.detailSuffix(for: w)
            .contains("strokes: freestyle 20, backstroke 4, butterfly 4"))
    }

    /// The fixture run: dynamics, detail and eight splits, asserted verbatim.
    private func fullRun() -> WorkoutSummary {
        WorkoutSummary(activityName: "Run", start: date(2026, 7, 4, 7, 0), duration: 2894,
                       distanceMeters: 8000, activeEnergyKcal: 500,
                       averageHeartRateBPM: 150, maxHeartRateBPM: 172,
                       source: "Apple Watch", averageRunningPowerW: 245,
                       groundContactTimeMs: 240, verticalOscillationCm: 8.1,
                       strideLengthM: 1.15, productType: "Watch7,5", isIndoor: false,
                       averageMETs: 9.4, effortScore: 8, effortScoreIsUserRated: false,
                       elevationAscendedM: 84, elevationDescendedM: 80, stepCount: 7910,
                       weatherTemperatureC: 14, weatherHumidityPercent: 72,
                       splitSecondsPerKm: [358, 361, 364, 359, 360, 362, 357, 363])
    }

    func testFullRunLineRendersExactly() {
        XCTAssertEqual(WorkoutContextFormatter.line(for: fullRun(), timeZone: utc),
            "Run — 2026-07-04 07:00, 48m, 8.00 km, 500 kcal, avg HR 150, max HR 172"
            + " (Apple Watch, Watch7,5)"
            + ", power 245 W, GCT 240 ms, vert osc 8.1 cm, stride 1.15 m"
            + ", outdoor, effort 8/10 (est), avg METs 9.4, temp 14 C, humidity 72%"
            + ", pace 6:02/km (computed), cadence 164 spm (computed)"
            + ", ascent 84 m, descent 80 m"
            + ", splits/km 5:58 6:01 6:04 5:59 6:00 6:02 5:57 6:03")
    }

    // MARK: - Splits suffix

    func testSplitsSuffixEmptyAndCapped() {
        var w = fullRun()
        w.splitSecondsPerKm = nil
        XCTAssertEqual(WorkoutContextFormatter.splitsSuffix(for: w), "")
        w.splitSecondsPerKm = []
        XCTAssertEqual(WorkoutContextFormatter.splitsSuffix(for: w), "")
        w.splitSecondsPerKm = Array(repeating: 361, count: 42)
        let shown = WorkoutContextFormatter.splitsSuffix(for: w)
            .replacingOccurrences(of: ", splits/km ", with: "")
            .split(separator: " ")
        XCTAssertEqual(shown.count, WorkoutContextFormatter.maxSplits, "capped at 30")
    }

    /// Pace and cadence are arithmetic done here, not device readings, and the
    /// block says so — the marker is what lets an agent tell the two apart.
    func testComputedFieldsAreMarkedComputed() {
        let detail = WorkoutContextFormatter.detailSuffix(for: fullRun())
        XCTAssertTrue(detail.contains("pace 6:02/km (computed)"))
        XCTAssertTrue(detail.contains("cadence 164 spm (computed)"))
        XCTAssertFalse(detail.contains("ascent 84 m (computed)"), "a read value is unmarked")
    }

    /// A cycle is neither a swim nor a foot distance, so it gets no pace, no cadence
    /// and — deliberately, per the rendering spec, which scopes ascent/descent to
    /// runs, walks and hikes — no elevation either, even when HealthKit recorded it.
    /// Only the conditions common to every workout render.
    func testNonFootNonSwimActivityGetsOnlyTheCommonSegments() {
        var c = WorkoutSummary(activityName: "Cycle", start: date(2026, 7, 4, 7, 0),
                               duration: 3600, distanceMeters: 30000, source: "Apple Watch")
        c.stepCount = 500
        c.elevationAscendedM = 320
        c.isIndoor = false
        XCTAssertEqual(WorkoutContextFormatter.detailSuffix(for: c), ", outdoor")
    }
}
