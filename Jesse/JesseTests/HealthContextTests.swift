import XCTest
@testable import Jesse

/// Pure-logic tests for the two-section health context: the daily-summary formatter
/// (each metric present/absent, nap labeling, fixed order, recency windows), the
/// composer (two-section layout, workouts-only byte-identity with the shipped
/// feature, ordering/cap/window, truncation priority, running-dynamics in a composed
/// line, max-size fit), the attach policy, the resolver, the bounded timeout, and
/// the per-metric-isolating gather. Everything is deterministic — a fixed UTC
/// calendar and a fixed `now` — so the rendered bytes are pinned.
final class HealthContextTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private lazy var now = date(2026, 7, 4, 12, 0)

    private func swim(start: Date, source: String = "Apple Watch") -> WorkoutSummary {
        WorkoutSummary(activityName: "Swim", start: start, duration: 1800,
                       distanceMeters: 1500, activeEnergyKcal: 420,
                       averageHeartRateBPM: 132, maxHeartRateBPM: 158, source: source)
    }

    // A fully-populated daily summary (all metrics present) for the maximal cases.
    private func fullDaily() -> DailySummary {
        DailySummary(
            sleep: SleepSummary(totalMinutes: 438, deepMinutes: 82, remMinutes: 95,
                                coreMinutes: 248, awakeMinutes: 18, isNap: false),
            restingHeartRateBPM: 52,
            hrvSDNNms: 68,
            hrEvents: [
                HREventSummary(kind: .high, count: 2, mostRecent: date(2026, 7, 3, 14, 22)),
                HREventSummary(kind: .irregular, count: 1, mostRecent: date(2026, 7, 1, 9, 10)),
            ],
            vo2Max: DatedValue(value: 48.2, date: date(2026, 6, 20, 8, 0)),
            hrRecovery: DatedValue(value: 32, date: date(2026, 7, 3, 7, 0)),
            vitals: OvernightVitals(respiratoryRate: 14, oxygenSaturation: 0.96,
                                    wristTemperatureDeviation: 0.3),
            mobility: MobilitySummary(steadiness: "OK", asymmetryPercent: 1.2),
            todaySteps: 8432, todayActiveKcal: 540,
            weight: DatedValue(value: 78.4, date: date(2026, 7, 3, 6, 0)))
    }

    // MARK: - Daily-summary formatter: each metric present

    func testDailyLinesFullyPopulatedInFixedOrder() {
        let lines = DailySummaryFormatter.lines(from: fullDaily(), now: now, timeZone: utc)
        XCTAssertEqual(lines, [
            "Sleep (last night): 7.3h total, 82m deep, 95m REM, 248m core, 18m awake",
            "Resting HR: 52 bpm",
            "HRV (SDNN): 68 ms",
            "HR events: 2 high (latest 2026-07-03 14:22), 1 irregular (latest 2026-07-01 09:10)",
            "VO2 max: 48.2 mL/kg·min (2026-06-20)",
            "HR recovery (1 min): 32 bpm (2026-07-03)",
            "Overnight: 14 breaths/min, SpO2 96%, wrist temp +0.3°C",
            "Mobility: steadiness OK, asymmetry 1.2%",
            "Today so far: 8432 steps, 540 kcal active",
            "Weight: 78.4 kg (2026-07-03)",
        ])
    }

    // MARK: - Daily-summary formatter: each metric absent / partial

    func testDailyEmptyYieldsNoLines() {
        XCTAssertTrue(DailySummaryFormatter.lines(from: .empty, now: now, timeZone: utc).isEmpty)
        XCTAssertTrue(DailySummary.empty.isEmpty)
    }

    func testSleepNapLabel() {
        let nap = DailySummary(sleep: SleepSummary(totalMinutes: 47, deepMinutes: nil,
                                                   remMinutes: nil, coreMinutes: 47,
                                                   awakeMinutes: nil, isNap: true))
        let line = DailySummaryFormatter.lines(from: nap, now: now, timeZone: utc).first
        XCTAssertEqual(line, "Sleep (nap): 0.8h total, 47m core")
        XCTAssertTrue(line!.contains("(nap)"))
    }

    func testHREventsOmittedWhenNoneAndWhenStale() {
        // No events → line omitted entirely (the common case).
        var d = fullDaily(); d.hrEvents = []
        XCTAssertFalse(DailySummaryFormatter.lines(from: d, now: now, timeZone: utc)
            .contains { $0.hasPrefix("HR events:") })
        // An event older than 7 days is dropped.
        d.hrEvents = [HREventSummary(kind: .high, count: 1, mostRecent: date(2026, 6, 1, 0, 0))]
        XCTAssertFalse(DailySummaryFormatter.lines(from: d, now: now, timeZone: utc)
            .contains { $0.hasPrefix("HR events:") })
    }

    func testDatedMetricsDroppedWhenOutsideRecencyWindow() {
        var d = DailySummary()
        d.vo2Max = DatedValue(value: 44, date: date(2025, 1, 1, 0, 0))       // > 180d
        d.hrRecovery = DatedValue(value: 30, date: date(2026, 6, 1, 0, 0))   // > 7d
        d.weight = DatedValue(value: 80, date: date(2026, 6, 1, 0, 0))       // > 7d
        XCTAssertTrue(DailySummaryFormatter.lines(from: d, now: now, timeZone: utc).isEmpty,
                      "all three are stale and their lines are omitted")
    }

    func testOvernightAndMobilityAndTodayPartials() {
        var d = DailySummary()
        d.vitals = OvernightVitals(respiratoryRate: nil, oxygenSaturation: 0.95,
                                   wristTemperatureDeviation: nil)
        d.mobility = MobilitySummary(steadiness: "Low", asymmetryPercent: nil)
        d.todaySteps = 1200
        let lines = DailySummaryFormatter.lines(from: d, now: now, timeZone: utc)
        XCTAssertEqual(lines, [
            "Overnight: SpO2 95%",
            "Mobility: steadiness Low",
            "Today so far: 1200 steps",
        ])
    }

    // MARK: - Classifiers

    func testSleepClassifierNapVsNight() {
        // Short + midday → nap.
        XCTAssertTrue(SleepClassifier.isNap(totalMinutes: 40,
                                            midpoint: date(2026, 7, 4, 14, 0), timeZone: utc))
        // Short but overnight window → fragmented night, not a nap.
        XCTAssertFalse(SleepClassifier.isNap(totalMinutes: 40,
                                             midpoint: date(2026, 7, 4, 3, 0), timeZone: utc))
        // Long is always the night regardless of hour.
        XCTAssertFalse(SleepClassifier.isNap(totalMinutes: 300,
                                             midpoint: date(2026, 7, 4, 14, 0), timeZone: utc))
    }

    func testWalkingSteadinessBands() {
        XCTAssertEqual(WalkingSteadiness.classify(percent: 55), "OK")
        XCTAssertEqual(WalkingSteadiness.classify(percent: 30), "Low")
        XCTAssertEqual(WalkingSteadiness.classify(percent: 10), "Very Low")
    }

    // MARK: - Composer: two-section layout

    func testTwoSectionLayoutDailyThenWorkouts() {
        let block = HealthContextFormatter.block(
            daily: fullDaily(), workouts: [swim(start: date(2026, 7, 4, 6, 30))],
            now: now, timeZone: utc)!
        let expected = """
        Daily health summary from Apple Health:
        Sleep (last night): 7.3h total, 82m deep, 95m REM, 248m core, 18m awake
        Resting HR: 52 bpm
        HRV (SDNN): 68 ms
        HR events: 2 high (latest 2026-07-03 14:22), 1 irregular (latest 2026-07-01 09:10)
        VO2 max: 48.2 mL/kg·min (2026-06-20)
        HR recovery (1 min): 32 bpm (2026-07-03)
        Overnight: 14 breaths/min, SpO2 96%, wrist temp +0.3°C
        Mobility: steadiness OK, asymmetry 1.2%
        Today so far: 8432 steps, 540 kcal active
        Weight: 78.4 kg (2026-07-03)

        1 recent workout from Apple Health (last 48h, newest first):
        Swim — 2026-07-04 06:30, 30m, 1.5 km, 420 kcal, avg HR 132, max HR 158 (Apple Watch)
        """
        XCTAssertEqual(block, expected)
    }

    /// With no daily data, the composed block is byte-identical to the shipped
    /// workouts-only block — an empty daily section adds nothing (no header, no
    /// leading blank line).
    func testWorkoutsOnlyBlockIsByteIdenticalToShippedFeature() {
        let block = HealthContextFormatter.block(
            daily: .empty, workouts: [swim(start: date(2026, 7, 4, 6, 30))],
            now: now, timeZone: utc)
        XCTAssertEqual(block, """
        1 recent workout from Apple Health (last 48h, newest first):
        Swim — 2026-07-04 06:30, 30m, 1.5 km, 420 kcal, avg HR 132, max HR 158 (Apple Watch)
        """)
    }

    func testDailyOnlyBlockWhenNoWorkouts() {
        let block = HealthContextFormatter.block(
            daily: DailySummary(restingHeartRateBPM: 52), workouts: [], now: now, timeZone: utc)
        XCTAssertEqual(block, """
        Daily health summary from Apple Health:
        Resting HR: 52 bpm
        """)
    }

    func testEmptyEverythingReturnsNil() {
        XCTAssertNil(HealthContextFormatter.block(daily: .empty, workouts: [],
                                                  now: now, timeZone: utc))
    }

    // MARK: - Composer: workouts ordering / cap / window (inherited behavior)

    func testWorkoutsNewestFirstPluralAndFiveCap() {
        let all = (0..<7).map { swim(start: date(2026, 7, 4, 4 + $0 / 60, $0 % 60), source: "W\($0)") }
        let block = HealthContextFormatter.block(daily: .empty, workouts: all, now: now, timeZone: utc)!
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("5 recent workouts from Apple Health"))
        XCTAssertEqual(lines.count, 1 + 5, "header + 5 workout lines")
        XCTAssertTrue(lines[1].contains("W6"), "newest first")
    }

    func testWorkoutsWindowExcludesOlderThan48h() {
        let old = swim(start: date(2026, 7, 2, 10, 0))   // ~49h before now
        XCTAssertNil(HealthContextFormatter.block(daily: .empty, workouts: [old],
                                                  now: now, timeZone: utc))
    }

    // MARK: - Composer: running dynamics in a composed line

    func testComposedRunLineIncludesDynamics() {
        let r = WorkoutSummary(activityName: "Run", start: date(2026, 7, 4, 7, 0), duration: 2700,
                               distanceMeters: 8000, activeEnergyKcal: 500,
                               averageHeartRateBPM: 150, maxHeartRateBPM: 172, source: "Apple Watch",
                               averageRunningPowerW: 245, groundContactTimeMs: 240,
                               verticalOscillationCm: 8.1, strideLengthM: 1.15)
        let block = HealthContextFormatter.block(daily: .empty, workouts: [r], now: now, timeZone: utc)!
        XCTAssertTrue(block.contains(", power 245 W, GCT 240 ms, vert osc 8.1 cm, stride 1.15 m"))
    }

    // MARK: - Composer: truncation priority + max-size fit

    /// The realistic maximal block — all daily metrics, 5 workouts, all with running
    /// dynamics — fits comfortably under the 3 KiB self-cap.
    func testMaximalBlockFitsUnderThreeKiB() {
        let runs = (0..<5).map { i in
            WorkoutSummary(activityName: "Run", start: date(2026, 7, 4, 5 + i, 0), duration: 3000,
                           distanceMeters: 9000, activeEnergyKcal: 560,
                           averageHeartRateBPM: 152, maxHeartRateBPM: 176,
                           source: "Apple Watch Ultra 2",
                           averageRunningPowerW: 248, groundContactTimeMs: 238,
                           verticalOscillationCm: 8.3, strideLengthM: 1.18)
        }
        let block = HealthContextFormatter.block(daily: fullDaily(), workouts: runs,
                                                 now: now, timeZone: utc)!
        XCTAssertLessThanOrEqual(block.utf8.count, 3 * 1024)
        XCTAssertTrue(block.hasPrefix("Daily health summary"))
        XCTAssertTrue(block.contains("5 recent workouts"), "all five workouts retained")
    }

    /// The daily summary is never shed; the oldest workout LINES are dropped first to
    /// fit, and no line is ever truncated mid-way.
    func testTruncationKeepsDailyAndDropsOldestWorkoutLines() {
        let long = String(repeating: "x", count: 600)
        let all = (0..<5).map { swim(start: date(2026, 7, 4, 5 + $0, 0), source: long) }
        let block = HealthContextFormatter.block(daily: fullDaily(), workouts: all,
                                                 now: now, timeZone: utc)!
        XCTAssertLessThanOrEqual(block.utf8.count, 3 * 1024, "hard 3 KiB ceiling")
        // Daily summary fully present.
        XCTAssertTrue(block.contains("Weight: 78.4 kg (2026-07-03)"))
        XCTAssertTrue(block.contains("Sleep (last night):"))
        // Some workouts dropped by the cap; every kept line is complete.
        let workoutLines = block.split(separator: "\n").map(String.init)
            .filter { $0.hasSuffix("(\(long))") }
        XCTAssertLessThan(workoutLines.count, 5, "oldest workout lines dropped")
        XCTAssertGreaterThan(workoutLines.count, 0)
        // The header count matches the workouts actually kept.
        XCTAssertTrue(block.contains(
            "\(workoutLines.count) recent workout\(workoutLines.count == 1 ? "" : "s") from Apple Health"))
    }

    /// When a boundary run's base line fits but base+dynamics would overflow, the
    /// running-dynamics suffix is dropped rather than the whole line.
    func testTruncationDropsDynamicsSuffixBeforeDroppingTheLine() {
        // Size the run's source so its base line just fits the cap but base+dynamics
        // does not, isolating the suffix-drop rung of the priority.
        let headerReserve = WorkoutContextFormatter.header(count: 1).utf8.count + 1
        let targetBase = HealthContextFormatter.maxBytes - headerReserve - 1
        // Fixed part of the base line with an empty source (no paren).
        var probe = WorkoutSummary(activityName: "Run", start: date(2026, 7, 4, 7, 0),
                                   duration: 2700, source: "",
                                   averageRunningPowerW: 245, groundContactTimeMs: 240,
                                   verticalOscillationCm: 8.1, strideLengthM: 1.15)
        let fixed = WorkoutContextFormatter.baseLine(for: probe, timeZone: utc).utf8.count
        // baseLine with source = fixed + " (" + source + ")" → +3 bytes of framing.
        probe.source = String(repeating: "x", count: targetBase - fixed - 3)

        let base = WorkoutContextFormatter.baseLine(for: probe, timeZone: utc)
        XCTAssertEqual(base.utf8.count, targetBase, "base sized to exactly fit")

        let block = HealthContextFormatter.block(daily: .empty, workouts: [probe],
                                                 now: now, timeZone: utc)!
        XCTAssertLessThanOrEqual(block.utf8.count, HealthContextFormatter.maxBytes)
        XCTAssertTrue(block.contains(base), "the base line is kept, in full")
        XCTAssertFalse(block.contains("power 245 W"), "dynamics suffix dropped to fit")
    }

    // MARK: - Policy

    func testPolicy() {
        XCTAssertFalse(HealthContextPolicy.shouldAttach(enabled: false, block: "has data"))
        XCTAssertFalse(HealthContextPolicy.shouldAttach(enabled: true, block: nil))
        XCTAssertFalse(HealthContextPolicy.shouldAttach(enabled: true, block: ""))
        XCTAssertTrue(HealthContextPolicy.shouldAttach(enabled: true, block: "x"))
    }

    // MARK: - Resolver (send-path wiring, via a fake provider)

    private struct FakeProvider: HealthContextProviding {
        let snap: HealthSnapshot
        func snapshot() async -> HealthSnapshot { snap }
    }

    func testResolveDisabledReturnsNilWithoutQuerying() async {
        let out = await HealthContextResolver.resolve(
            enabled: false,
            provider: FakeProvider(snap: HealthSnapshot(daily: fullDaily(), workouts: [])),
            now: now, timeZone: utc)
        XCTAssertNil(out)
    }

    func testResolveEnabledButNoDataReturnsNil() async {
        let out = await HealthContextResolver.resolve(
            enabled: true, provider: FakeProvider(snap: .empty), now: now, timeZone: utc)
        XCTAssertNil(out)
    }

    func testResolveEnabledWithDataReturnsBlock() async {
        let out = await HealthContextResolver.resolve(
            enabled: true,
            provider: FakeProvider(snap: HealthSnapshot(
                daily: DailySummary(restingHeartRateBPM: 52),
                workouts: [swim(start: date(2026, 7, 4, 6, 30))])),
            now: now, timeZone: utc)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Resting HR: 52 bpm"))
        XCTAssertTrue(out!.contains("Swim — 2026-07-04 06:30"))
    }

    // MARK: - Timeout

    func testTimeoutFastOperationReturnsItsValue() async {
        let snap = HealthSnapshot(daily: DailySummary(restingHeartRateBPM: 52), workouts: [])
        let out = await HealthContextTimeout.orEmpty(within: .seconds(1)) { snap }
        XCTAssertEqual(out, snap)
    }

    func testTimeoutSlowOperationYieldsEmpty() async {
        let out = await HealthContextTimeout.orEmpty(within: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
            return HealthSnapshot(daily: DailySummary(restingHeartRateBPM: 52), workouts: [])
        }
        XCTAssertEqual(out, .empty, "overrun degrades to empty, not the late value")
    }

    // MARK: - Gather: per-metric failure isolation

    func testGatherIsolatesAFailingMetric() async {
        struct Boom: Error {}
        var f = HealthMetricFetches.empty
        f.sleep = { SleepSummary(totalMinutes: 400, deepMinutes: nil, remMinutes: nil,
                                 coreMinutes: nil, awakeMinutes: nil, isNap: false) }
        f.restingHR = { 52 }
        f.hrv = { throw Boom() }                       // one read fails…
        f.workouts = { throw Boom() }                  // …and so does the workout read
        let snap = await HealthContextGather.snapshot(f)
        XCTAssertNotNil(snap.daily.sleep, "a failed HRV read must not drop the sleep line")
        XCTAssertEqual(snap.daily.restingHeartRateBPM, 52)
        XCTAssertNil(snap.daily.hrvSDNNms, "the failed metric degrades to nil")
        XCTAssertTrue(snap.workouts.isEmpty, "the failed workout read degrades to empty")
    }

    func testGatherEmptyFetchesYieldEmptySnapshot() async {
        let snap = await HealthContextGather.snapshot(.empty)
        XCTAssertEqual(snap, .empty)
    }
}
