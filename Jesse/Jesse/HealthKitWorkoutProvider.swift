import Foundation
import HealthKit

// The ONE file that imports HealthKit. It conforms to `WorkoutContextProviding`
// (declared in the Foundation-only `WorkoutContext.swift`) and does nothing but
// read: query recent workouts, reduce each to a pure `WorkoutSummary`, and request
// read authorization. All formatting/policy/timeout logic lives in the pure files
// with full unit tests; this file is deliberately thin so the untestable HealthKit
// surface is as small as possible. It never writes to Health.

/// Reads recent workouts from Apple Health for the per-turn `health_context`
/// block. Read-only. Every degrade path (unavailable, unauthorized, no data, a
/// query error, or the timeout) yields an empty array, so a turn is never blocked
/// or broken by health data — HealthKit read denial is invisible by design.
struct HealthKitWorkoutProvider: WorkoutContextProviding {
    /// The read types the app requests and queries — workouts plus the quantity
    /// types the block reports. No share (write) types: this feature never writes.
    static var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
    }

    /// Hard bound on the whole query — the send path waits at most this long, then
    /// proceeds with no block (`WorkoutContextTimeout`).
    private let timeout: Duration
    /// How far back to look and how many workouts to pull (the formatter re-caps).
    private let window: TimeInterval
    private let limit: Int
    /// The workout fetch, injected so tests can drive the error/timeout/empty
    /// branches without HealthKit data. Defaults to the live HealthKit query.
    private let fetch: @Sendable () async throws -> [WorkoutSummary]

    init(timeout: Duration = .seconds(1),
         window: TimeInterval = WorkoutContextFormatter.windowHours * 3600,
         limit: Int = WorkoutContextFormatter.maxWorkouts,
         fetch: (@Sendable () async throws -> [WorkoutSummary])? = nil) {
        self.timeout = timeout
        self.window = window
        self.limit = limit
        // The default fetch captures only Sendable values (window, limit) and
        // makes its own HKHealthStore inside liveFetch — HKHealthStore is not
        // Sendable, so it must never be captured by this @Sendable closure.
        self.fetch = fetch ?? {
            try await HealthKitWorkoutProvider.liveFetch(window: window, limit: limit)
        }
    }

    func recentWorkouts() async -> [WorkoutSummary] {
        await WorkoutContextTimeout.orEmpty(within: timeout, fetch)
    }

    /// Request read authorization for the workout + quantity types. Returns false
    /// if Health is unavailable or the request errors; true once the prompt has
    /// been answered (Apple deliberately hides whether READ was granted — denial
    /// just yields empty queries later, so "granted once" means "asked once").
    static func requestReadAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            Log.health.error("HealthKit authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Live HealthKit query (the only HealthKit-touching code)

    private static func liveFetch(window: TimeInterval,
                                  limit: Int) async throws -> [WorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let store = HKHealthStore()
        let start = Date().addingTimeInterval(-window)
        // Workouts that ENDED within the window, newest first.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [.strictEndDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(),
                                  predicate: predicate,
                                  limit: limit,
                                  sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        return workouts.map(summary(for:))
    }

    /// Reduce one workout to a pure `WorkoutSummary`, reading energy / distance /
    /// heart-rate from the statistics Apple Watch attaches to the workout. Any
    /// missing stat is left nil (the formatter omits that field).
    private static func summary(for w: HKWorkout) -> WorkoutSummary {
        let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hrStats = w.statistics(for: HKQuantityType(.heartRate))
        let avgHR = hrStats?.averageQuantity()?.doubleValue(for: bpm)
        let maxHR = hrStats?.maximumQuantity()?.doubleValue(for: bpm)
        return WorkoutSummary(
            activityName: activityName(w.workoutActivityType),
            start: w.startDate,
            duration: w.duration,
            distanceMeters: distanceMeters(for: w),
            activeEnergyKcal: kcal,
            averageHeartRateBPM: avgHR,
            maxHeartRateBPM: maxHR,
            source: w.sourceRevision.source.name
        )
    }

    /// First available distance statistic (swim / walk-run / cycle) in meters.
    private static func distanceMeters(for w: HKWorkout) -> Double? {
        for id in [HKQuantityTypeIdentifier.distanceSwimming,
                   .distanceWalkingRunning,
                   .distanceCycling] {
            if let m = w.statistics(for: HKQuantityType(id))?
                .sumQuantity()?.doubleValue(for: .meter()) {
                return m
            }
        }
        return nil
    }

    /// A short, stable name for the common activity types; anything else → "Workout".
    private static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .swimming: return "Swim"
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .hiking: return "Hike"
        case .yoga: return "Yoga"
        case .highIntensityIntervalTraining: return "HIIT"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .rowing: return "Row"
        case .elliptical: return "Elliptical"
        default: return "Workout"
        }
    }
}
