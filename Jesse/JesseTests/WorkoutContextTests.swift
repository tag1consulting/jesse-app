import XCTest
@testable import Jesse

/// Pure-logic tests for the recent-workouts context: the formatter (ordering,
/// caps, window, byte-truncation, singular/plural, determinism), the attach
/// policy, the async timeout helper, and the resolver that wires them for the send
/// path. Everything here is deterministic — a fixed UTC calendar and a fixed
/// `now`, never the wall clock or host locale — so the rendered bytes are pinned.
final class WorkoutContextTests: XCTestCase {

    // Fixed UTC calendar so date rendering is deterministic regardless of host TZ.
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

    // MARK: - Formatter

    func testEmptyInputReturnsNil() {
        XCTAssertNil(WorkoutContextFormatter.block(from: [], now: now, timeZone: utc))
    }

    func testSingleWorkoutRendersSingularHeaderAndExactLine() {
        let block = WorkoutContextFormatter.block(
            from: [swim(start: date(2026, 7, 4, 6, 30))], now: now, timeZone: utc)
        XCTAssertEqual(block, """
        1 recent workout from Apple Health (last 48h, newest first):
        Swim — 2026-07-04 06:30, 30m, 1.5 km, 420 kcal, avg HR 132, max HR 158 (Apple Watch)
        """)
    }

    func testPluralHeaderAndNewestFirstOrdering() {
        let older = swim(start: date(2026, 7, 3, 18, 0), source: "Watch A")
        let newer = swim(start: date(2026, 7, 4, 7, 0), source: "Watch B")
        // Deliberately pass oldest-first; the formatter must sort newest-first.
        let block = WorkoutContextFormatter.block(from: [older, newer], now: now, timeZone: utc)!
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("2 recent workouts from Apple Health"))
        XCTAssertTrue(lines[1].contains("Watch B"), "newest first")
        XCTAssertTrue(lines[2].contains("Watch A"))
    }

    func testWindowExcludesWorkoutsOlderThan48h() {
        // Ended ~49h before `now` → outside the window → dropped → nil.
        let old = swim(start: date(2026, 7, 2, 10, 0))
        XCTAssertNil(WorkoutContextFormatter.block(from: [old], now: now, timeZone: utc))
        // One inside + one outside → only the inside one renders.
        let fresh = swim(start: date(2026, 7, 4, 6, 0))
        let block = WorkoutContextFormatter.block(from: [old, fresh], now: now, timeZone: utc)!
        XCTAssertTrue(block.hasPrefix("1 recent workout "))
    }

    func testCapsAtFiveWorkouts() {
        // Seven distinct, all within the window; only the five newest render.
        let all = (0..<7).map { swim(start: date(2026, 7, 4, 4 + $0 / 60, $0 % 60), source: "W\($0)") }
        let block = WorkoutContextFormatter.block(from: all, now: now, timeZone: utc)!
        let lines = block.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("5 recent workouts from Apple Health"))
        XCTAssertEqual(lines.count, 1 + 5, "header + 5 workout lines")
    }

    func testByteCapTruncatesWholeLinesNeverMidLine() {
        // Long sources make each line big; not all five fit under the 2 KiB cap.
        let long = String(repeating: "x", count: 500)
        let all = (0..<5).map { swim(start: date(2026, 7, 4, 5 + $0, 0), source: long) }
        let block = WorkoutContextFormatter.block(from: all, now: now, timeZone: utc)!
        XCTAssertLessThanOrEqual(block.utf8.count, 2 * 1024, "hard 2 KiB ceiling")
        let lines = block.split(separator: "\n").map(String.init)
        XCTAssertLessThan(lines.count - 1, 5, "some workouts dropped by the byte cap")
        // Every included workout line is complete (ends with its full source paren).
        for line in lines.dropFirst() {
            XCTAssertTrue(line.hasSuffix("(\(long))"), "never truncated mid-line: \(line.prefix(40))…")
        }
        // Header count matches the number of lines actually kept.
        XCTAssertTrue(lines[0].hasPrefix("\(lines.count - 1) recent workout"))
    }

    func testOmitsNilFields() {
        let bare = WorkoutSummary(activityName: "Walk", start: date(2026, 7, 4, 8, 0),
                                  duration: 3660, distanceMeters: nil, activeEnergyKcal: nil,
                                  averageHeartRateBPM: nil, maxHeartRateBPM: nil, source: nil)
        let block = WorkoutContextFormatter.block(from: [bare], now: now, timeZone: utc)!
        // Assert on the workout LINE (the header legitimately carries "(last 48h…)").
        let workoutLine = block.split(separator: "\n").map(String.init)[1]
        // Duration formats as 1h01m; no distance/kcal/HR/source segments present.
        XCTAssertEqual(workoutLine, "Walk — 2026-07-04 08:00, 1h01m")
        XCTAssertFalse(workoutLine.contains("kcal"))
        XCTAssertFalse(workoutLine.contains("HR"))
        XCTAssertFalse(workoutLine.contains("("), "no source paren when source is nil")
    }

    func testDeterministicAcrossCalls() {
        let ws = [swim(start: date(2026, 7, 4, 6, 30)), swim(start: date(2026, 7, 4, 9, 0))]
        let a = WorkoutContextFormatter.block(from: ws, now: now, timeZone: utc)
        let b = WorkoutContextFormatter.block(from: ws, now: now, timeZone: utc)
        XCTAssertEqual(a, b)
    }

    // MARK: - Policy

    func testPolicyDisabledNeverAttaches() {
        XCTAssertFalse(WorkoutContextPolicy.shouldAttach(enabled: false, block: "has data"))
    }
    func testPolicyEnabledButNoBlock() {
        XCTAssertFalse(WorkoutContextPolicy.shouldAttach(enabled: true, block: nil))
        XCTAssertFalse(WorkoutContextPolicy.shouldAttach(enabled: true, block: ""))
    }
    func testPolicyEnabledWithBlockAttaches() {
        XCTAssertTrue(WorkoutContextPolicy.shouldAttach(enabled: true, block: "1 recent workout…"))
    }

    // MARK: - Timeout helper

    func testTimeoutFastOperationReturnsItsValue() async {
        let ws = [swim(start: date(2026, 7, 4, 6, 30))]
        let out = await WorkoutContextTimeout.orEmpty(within: .seconds(1)) { ws }
        XCTAssertEqual(out, ws)
    }
    func testTimeoutThrowingOperationYieldsEmpty() async {
        struct Boom: Error {}
        let out = await WorkoutContextTimeout.orEmpty(within: .seconds(1)) { throw Boom() }
        XCTAssertTrue(out.isEmpty)
    }
    func testTimeoutSlowOperationYieldsEmpty() async {
        let ws = [swim(start: date(2026, 7, 4, 6, 30))]
        let out = await WorkoutContextTimeout.orEmpty(within: .milliseconds(100)) {
            try await Task.sleep(for: .seconds(5))
            return ws
        }
        XCTAssertTrue(out.isEmpty, "overrun degrades to empty, not the late value")
    }

    // MARK: - Resolver (send-path wiring, via a fake provider)

    private struct FakeProvider: WorkoutContextProviding {
        let summaries: [WorkoutSummary]
        func recentWorkouts() async -> [WorkoutSummary] { summaries }
    }

    func testResolveDisabledReturnsNilWithoutQuerying() async {
        let out = await WorkoutContextResolver.resolve(
            enabled: false,
            provider: FakeProvider(summaries: [swim(start: date(2026, 7, 4, 6, 30))]),
            now: now, timeZone: utc)
        XCTAssertNil(out)
    }
    func testResolveEnabledButNoDataReturnsNil() async {
        let out = await WorkoutContextResolver.resolve(
            enabled: true, provider: FakeProvider(summaries: []), now: now, timeZone: utc)
        XCTAssertNil(out)
    }
    func testResolveEnabledWithDataReturnsBlock() async {
        let out = await WorkoutContextResolver.resolve(
            enabled: true,
            provider: FakeProvider(summaries: [swim(start: date(2026, 7, 4, 6, 30))]),
            now: now, timeZone: utc)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Swim — 2026-07-04 06:30"))
    }
}
