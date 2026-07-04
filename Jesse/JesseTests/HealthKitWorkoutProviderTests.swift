import XCTest
@testable import Jesse

/// Exercises the real `HealthKitWorkoutProvider` through its injected `fetch`
/// seam, so the degrade paths are proven WITHOUT depending on simulator Health
/// data. The provider must turn every failure into an empty result: a thrown
/// error (the watch-relay "HealthKit database inaccessible while the phone is
/// locked" case), an overrun of the 1-second bound, and a normal empty query all
/// yield `[]`, so a turn is never blocked or broken by health data.
final class HealthKitWorkoutProviderTests: XCTestCase {

    private func sample() -> WorkoutSummary {
        WorkoutSummary(activityName: "Swim", start: Date(timeIntervalSince1970: 1_783_146_600),
                       duration: 1800, distanceMeters: 1500, activeEnergyKcal: 420,
                       averageHeartRateBPM: 132, maxHeartRateBPM: 158, source: "Apple Watch")
    }

    func testThrownErrorYieldsEmpty() async {
        // The watch-relay degrade: a locked phone's HealthKit read throws
        // "database inaccessible" — it must hit the silent empty path, not crash
        // or break the send.
        struct DatabaseInaccessible: Error {}
        let provider = HealthKitWorkoutProvider(fetch: { throw DatabaseInaccessible() })
        let out = await provider.recentWorkouts()
        XCTAssertTrue(out.isEmpty)
    }

    func testTimeoutYieldsEmpty() async {
        // Hoist the value out so the @Sendable fetch closure captures a Sendable
        // WorkoutSummary, not the (non-Sendable) test case via `self`.
        let late = [sample()]
        let provider = HealthKitWorkoutProvider(timeout: .milliseconds(100), fetch: {
            try await Task.sleep(for: .seconds(5))
            return late
        })
        let out = await provider.recentWorkouts()
        XCTAssertTrue(out.isEmpty, "a query slower than the bound degrades to empty")
    }

    func testEmptyQueryYieldsEmpty() async {
        let provider = HealthKitWorkoutProvider(fetch: { [] })
        let out = await provider.recentWorkouts()
        XCTAssertTrue(out.isEmpty)
    }

    func testSuccessfulFetchPassesThrough() async {
        let ws = [sample()]
        let provider = HealthKitWorkoutProvider(fetch: { ws })
        let out = await provider.recentWorkouts()
        XCTAssertEqual(out, ws)
    }
}
