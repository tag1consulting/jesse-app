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

    /// The detail fields ride the same seam as the eight the provider always had —
    /// including the nested `SwimDetail` — so nothing is flattened or lost between
    /// the provider and the formatter.
    func testWorkoutDetailSurvivesTheGatherSeam() async {
        let detailed = WorkoutSummary(
            activityName: "Swim", start: Date(timeIntervalSince1970: 1_783_146_600),
            duration: 3300, distanceMeters: 1650, source: "Apple Watch",
            productType: "Watch7,5", isIndoor: true, averageMETs: 7.2,
            effortScore: 6, effortScoreIsUserRated: true,
            elevationAscendedM: 12, elevationDescendedM: 10, stepCount: 0,
            weatherTemperatureC: 18, weatherHumidityPercent: 60,
            splitSecondsPerKm: [358, 361],
            swim: SwimDetail(lapLengthM: 25, location: .pool, lapCount: 66,
                             strokeCount: 1840, swimSeconds: 2890, averageSWOLF: 52,
                             waterTemperatureC: 27.5,
                             lapsByStroke: ["freestyle": 60, "breaststroke": 6]))
        var f = HealthMetricFetches.empty
        f.workouts = { [detailed] }
        let snap = await HealthContextProvider(fetches: f).snapshot()
        XCTAssertEqual(snap.workouts, [detailed])
        XCTAssertEqual(snap.workouts.first?.swim?.lapsByStroke,
                       ["freestyle": 60, "breaststroke": 6])
    }

    /// A workout read that throws still costs only the workouts, and the newer
    /// overnight signals travel on the vitals metric like the rest of them.
    func testBreathingDisturbancesRideTheVitalsMetric() async {
        var f = HealthMetricFetches.empty
        f.vitals = { OvernightVitals(respiratoryRate: 14, breathingDisturbances: 3.1) }
        let snap = await HealthContextProvider(fetches: f).snapshot()
        XCTAssertEqual(snap.daily.vitals?.breathingDisturbances, 3.1)
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
