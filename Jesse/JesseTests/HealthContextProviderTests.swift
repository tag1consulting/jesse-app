import XCTest
@testable import Jesse

/// Exercises the real `HealthContextProvider` through its injected
/// `HealthMetricFetches` seam, so the degrade paths are proven WITHOUT depending on
/// simulator Health data. The provider must turn every failure into an empty result
/// and isolate a single failing metric: a thrown read (the watch-relay "HealthKit
/// database inaccessible while the phone is locked" case), an overrun of the ~1.5s
/// bound, and a normal empty gather all keep a turn sending; one failed metric never
/// drops another.
@MainActor
final class HealthContextProviderTests: XCTestCase {

    private func swim() -> WorkoutSummary {
        WorkoutSummary(activityName: "Swim", start: Date(timeIntervalSince1970: 1_783_146_600),
                       duration: 1800, distanceMeters: 1500, activeEnergyKcal: 420,
                       averageHeartRateBPM: 132, maxHeartRateBPM: 158, source: "Apple Watch")
    }

    func testThrownReadsIsolateAndYieldEmpty() async {
        // The watch-relay degrade: a locked phone's HealthKit read throws
        // "database inaccessible" — it must hit the silent empty path per metric,
        // not crash or break the send.
        struct DatabaseInaccessible: Error {}
        var f = HealthMetricFetches.empty
        f.workouts = { throw DatabaseInaccessible() }
        f.sleep = { throw DatabaseInaccessible() }
        f.restingHR = { 50 }                          // one metric still succeeds
        let provider = HealthContextProvider(fetches: f)
        let snap = await provider.snapshot()
        XCTAssertTrue(snap.workouts.isEmpty)
        XCTAssertNil(snap.daily.sleep)
        XCTAssertEqual(snap.daily.restingHeartRateBPM, 50, "a sibling read is unaffected")
    }

    func testTimeoutYieldsEmptySnapshot() async {
        // Hoist the value out so the @Sendable closure captures a Sendable value.
        let late = swim()
        var f = HealthMetricFetches.empty
        f.workouts = {
            try await Task.sleep(for: .seconds(5))
            return [late]
        }
        let provider = HealthContextProvider(timeout: .milliseconds(100), fetches: f)
        let snap = await provider.snapshot()
        XCTAssertEqual(snap, .empty, "a gather slower than the bound degrades to empty")
    }

    func testEmptyFetchesYieldEmptySnapshot() async {
        let snap = await HealthContextProvider(fetches: .empty).snapshot()
        XCTAssertEqual(snap, .empty)
    }

    func testSuccessfulFetchesPassThrough() async {
        var f = HealthMetricFetches.empty
        // Build the (Sendable) workout on the main actor, then capture the value — the
        // `@Sendable` fetch closure must not capture `self` (the non-Sendable test case).
        let workout = swim()
        f.workouts = { [workout] }
        f.restingHR = { 52 }
        let snap = await HealthContextProvider(fetches: f).snapshot()
        XCTAssertEqual(snap.workouts, [swim()])
        XCTAssertEqual(snap.daily.restingHeartRateBPM, 52)
    }
}
