import Foundation
import HealthKit

/// Errors from the windowed metric-series reads. Caught and degraded to `[]` by
/// `series(for:windowDays:)`, so they never surface — a failed read just means
/// "no data" for that metric.
private enum HealthSeriesError: Error {
    case noResults
}

// The ONE file that imports HealthKit. It conforms to `HealthContextProviding`
// (declared in the Foundation-only `HealthContext.swift`) and does nothing but
// read: gather recent workouts plus the daily-summary metrics, reduce each to a
// pure value type, and request read authorization. All formatting/policy/timeout
// logic lives in the pure files with full unit tests; this file is deliberately
// thin so the untestable HealthKit surface is as small as possible. It never
// writes to Health.

/// Reads recent workouts and daily-summary metrics from Apple Health for the
/// per-turn `health_context` block. Read-only. Every degrade path (unavailable,
/// unauthorized, no data, a per-metric query error, or the timeout) yields empty
/// values, so a turn is never blocked or broken by health data — HealthKit read
/// denial is invisible by design. The whole gather runs concurrently under one
/// bound; a single failing metric never drops another.
nonisolated struct HealthContextProvider: HealthContextProviding {
    /// The read types the app requests and queries — workouts plus the quantity and
    /// category types the block reports. No share (write) types: this never writes.
    /// Requested as a union so HealthKit prompts only for the delta on re-request.
    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
        for id in quantityReadIdentifiers { types.insert(HKQuantityType(id)) }
        for id in categoryReadIdentifiers { types.insert(HKCategoryType(id)) }
        return types
    }

    /// New daily-summary + running-dynamics quantity reads (on top of the workout set).
    private static let quantityReadIdentifiers: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max, .respiratoryRate,
        .oxygenSaturation, .appleSleepingWristTemperature, .heartRateRecoveryOneMinute,
        .stepCount, .bodyMass, .runningPower, .runningGroundContactTime,
        .runningVerticalOscillation, .runningStrideLength, .walkingAsymmetryPercentage,
        .appleWalkingSteadiness,
    ]
    private static let categoryReadIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .lowHeartRateEvent, .highHeartRateEvent, .irregularHeartRhythmEvent,
    ]

    /// Hard bound on the whole combined gather — the send path waits at most this
    /// long, then proceeds with no block (`HealthContextTimeout`).
    private let timeout: Duration
    /// How far back to look and how many workouts to pull (the formatter re-caps).
    private let window: TimeInterval
    private let limit: Int
    /// The best-effort metric reads, injected so tests drive the isolation/timeout
    /// branches without HealthKit data. Defaults to the live HealthKit queries.
    private let fetches: HealthMetricFetches

    init(timeout: Duration = .milliseconds(1500),
         window: TimeInterval = WorkoutContextFormatter.windowHours * 3600,
         limit: Int = WorkoutContextFormatter.maxWorkouts,
         fetches: HealthMetricFetches? = nil) {
        self.timeout = timeout
        self.window = window
        self.limit = limit
        // The default fetches capture only Sendable values (window, limit) and make
        // their own HKHealthStore inside each live query — HKHealthStore is not
        // Sendable, so it must never be captured by these @Sendable closures.
        self.fetches = fetches ?? HealthContextProvider.liveFetches(window: window, limit: limit)
    }

    func snapshot() async -> HealthSnapshot {
        await HealthContextTimeout.orEmpty(within: timeout) {
            await HealthContextGather.snapshot(fetches)
        }
    }

    /// A windowed daily series for one whitelisted metric (to fulfill a
    /// `JESSE_NEEDS_HEALTH` metrics request). Best-effort: any failure yields `[]`.
    /// `windowDays` is pre-validated to 1...31. Quantity metrics use a daily
    /// `HKStatisticsCollectionQuery` (sum for step/energy, average otherwise);
    /// sleep buckets samples per night; workouts return one point each.
    func series(for metric: RequestableMetric, windowDays: Int) async -> [MetricSeriesPoint] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        do {
            switch metric {
            case .restingHeartRate:
                return try await Self.dailyQuantity(.restingHeartRate, unit: bpm,
                                                    options: .discreteAverage, days: windowDays)
            case .heartRate:
                return try await Self.dailyQuantity(.heartRate, unit: bpm,
                                                    options: .discreteAverage, days: windowDays)
            case .heartRateVariabilitySDNN:
                return try await Self.dailyQuantity(.heartRateVariabilitySDNN,
                                                    unit: .secondUnit(with: .milli),
                                                    options: .discreteAverage, days: windowDays)
            case .stepCount:
                return try await Self.dailyQuantity(.stepCount, unit: .count(),
                                                    options: .cumulativeSum, days: windowDays)
            case .activeEnergyBurned:
                return try await Self.dailyQuantity(.activeEnergyBurned, unit: .kilocalorie(),
                                                    options: .cumulativeSum, days: windowDays)
            case .bodyMass:
                return try await Self.dailyQuantity(.bodyMass, unit: .gramUnit(with: .kilo),
                                                    options: .discreteAverage, days: windowDays)
            case .vo2Max:
                return try await Self.dailyQuantity(.vo2Max, unit: HKUnit(from: "ml/kg*min"),
                                                    options: .discreteAverage, days: windowDays)
            case .sleepAnalysis:
                return try await Self.dailySleepMinutes(days: windowDays)
            case .workouts:
                return try await Self.workoutPoints(days: windowDays)
            }
        } catch {
            Log.health.error("metric series read failed for \(metric.rawValue): \(error.localizedDescription)")
            return []
        }
    }

    /// Daily-bucketed statistics for a quantity type over the last `days` days.
    private static func dailyQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                      options: HKStatisticsOptions, days: Int)
        async throws -> [MetricSeriesPoint] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }
        var interval = DateComponents(); interval.day = 1
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let store = HKHealthStore()
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: HKQuantityType(id),
                                                quantitySamplePredicate: predicate,
                                                options: options, anchorDate: start,
                                                intervalComponents: interval)
            q.initialResultsHandler = { _, results, error in
                if let error { cont.resume(throwing: error); return }
                guard let results else {
                    cont.resume(throwing: HealthSeriesError.noResults); return
                }
                cont.resume(returning: results)
            }
            store.execute(q)
        }
        var points: [MetricSeriesPoint] = []
        collection.enumerateStatistics(from: start, to: now) { stat, _ in
            let quantity = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
            if let value = quantity?.doubleValue(for: unit) {
                points.append(MetricSeriesPoint(date: stat.startDate, value: value))
            }
        }
        return points
    }

    /// Total asleep minutes per night over the last `days` days (one point/day).
    private static func dailySleepMinutes(days: Int) async throws -> [MetricSeriesPoint] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let store = HKHealthStore()
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        var byDay: [Date: Double] = [:]
        for s in samples where asleep.contains(s.value) {
            let day = cal.startOfDay(for: s.endDate)
            byDay[day, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60
        }
        return byDay.map { MetricSeriesPoint(date: $0.key, value: $0.value) }
    }

    /// One point per workout over the last `days` days (value = duration minutes).
    private static func workoutPoints(days: Int) async throws -> [MetricSeriesPoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [.strictEndDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let store = HKHealthStore()
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        return workouts.map { MetricSeriesPoint(date: $0.startDate, value: $0.duration / 60) }
    }

    /// Request authorization for the workout + quantity + category READ types and
    /// the dietary WRITE (share) types (`HealthKitMealWriter.shareTypes`), in one
    /// prompt. Returns false if Health is unavailable or the request errors; true
    /// once the prompt has been answered. Apple hides whether READ was granted
    /// (denial just yields empty queries), but WRITE status IS queryable — the
    /// caller checks `HealthKitMealWriter.isWriteDenied()` to decide the meal toggle.
    static func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await HKHealthStore().requestAuthorization(
                toShare: HealthKitMealWriter.shareTypes, read: readTypes)
            return true
        } catch {
            Log.health.error("HealthKit authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Live HealthKit queries (the only HealthKit-touching code)

    /// Build the live metric fetches. Each closure runs one bounded read and throws
    /// on failure; `HealthContextGather` isolates a throw to that one metric.
    private static func liveFetches(window: TimeInterval, limit: Int) -> HealthMetricFetches {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return HealthMetricFetches(
            workouts: { try await liveWorkouts(window: window, limit: limit) },
            sleep: { try await liveSleep() },
            restingHR: { try await latest(.restingHeartRate, unit: bpm, within: 48 * 3600)?.value },
            hrv: { try await latest(.heartRateVariabilitySDNN,
                                    unit: .secondUnit(with: .milli))?.value },
            hrEvents: { try await liveHREvents() },
            vo2Max: { try await latest(.vo2Max, unit: HKUnit(from: "ml/kg*min")) },
            hrRecovery: { try await latest(.heartRateRecoveryOneMinute, unit: bpm) },
            vitals: { try await liveVitals() },
            mobility: { try await liveMobility() },
            todaySteps: { try await sumToday(.stepCount, unit: .count()) },
            todayActiveKcal: { try await sumToday(.activeEnergyBurned, unit: .kilocalorie()) },
            weight: { try await latest(.bodyMass, unit: .gramUnit(with: .kilo)) })
    }

    // MARK: Workouts (+ running dynamics)

    private static func liveWorkouts(window: TimeInterval, limit: Int) async throws -> [WorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let store = HKHealthStore()
        let start = Date().addingTimeInterval(-window)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [.strictEndDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: limit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        var out: [WorkoutSummary] = []
        for w in workouts {
            var s = summary(for: w)
            if w.workoutActivityType == .running {
                s = await addingRunningDynamics(to: s, workout: w, store: store)
            }
            out.append(s)
        }
        return out
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
            source: w.sourceRevision.source.name)
    }

    /// Add average running-dynamics (power / GCT / vertical oscillation / stride) to
    /// a run's summary, each read as a discrete-average statistic over the workout
    /// window. A missing series stays nil and its field is omitted downstream.
    private static func addingRunningDynamics(to s: WorkoutSummary, workout w: HKWorkout,
                                              store: HKHealthStore) async -> WorkoutSummary {
        var s = s
        s.averageRunningPowerW = (try? await avg(.runningPower, unit: .watt(),
                                                 from: w.startDate, to: w.endDate, store: store)) ?? nil
        s.groundContactTimeMs = (try? await avg(.runningGroundContactTime,
                                                unit: .secondUnit(with: .milli),
                                                from: w.startDate, to: w.endDate, store: store)) ?? nil
        s.verticalOscillationCm = (try? await avg(.runningVerticalOscillation,
                                                  unit: .meterUnit(with: .centi),
                                                  from: w.startDate, to: w.endDate, store: store)) ?? nil
        s.strideLengthM = (try? await avg(.runningStrideLength, unit: .meter(),
                                          from: w.startDate, to: w.endDate, store: store)) ?? nil
        return s
    }

    // MARK: Sleep (last night)

    private static func liveSleep() async throws -> SleepSummary? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        // Look back 36h and take the most recent contiguous session (the last night).
        let start = Date().addingTimeInterval(-36 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        return Self.reduceSleep(samples)
    }

    /// Reduce raw sleep-stage samples to the most recent session's stage minutes.
    /// Samples are newest-first; a gap over an hour ends the session. Only "asleep"
    /// and "awake" stages count (bare "in bed" is ignored). Returns nil when the
    /// session holds no actual sleep.
    private static func reduceSleep(_ samples: [HKCategorySample]) -> SleepSummary? {
        // Group the newest contiguous run (gap ≤ 1h between adjacent samples).
        var session: [HKCategorySample] = []
        var boundary: Date?
        for s in samples { // newest-first
            if let b = boundary, b.timeIntervalSince(s.endDate) > 3600 { break }
            session.append(s)
            boundary = min(boundary ?? s.startDate, s.startDate)
        }
        guard !session.isEmpty else { return nil }

        func minutes(_ values: Set<Int>) -> Double {
            session.filter { values.contains($0.value) }
                .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 60
        }
        let deep = minutes([HKCategoryValueSleepAnalysis.asleepDeep.rawValue])
        let rem = minutes([HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let core = minutes([HKCategoryValueSleepAnalysis.asleepCore.rawValue])
        let unspecified = minutes([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue])
        let awake = minutes([HKCategoryValueSleepAnalysis.awake.rawValue])
        let asleep = deep + rem + core + unspecified
        guard asleep > 0 else { return nil }

        let sStart = session.map(\.startDate).min() ?? Date()
        let sEnd = session.map(\.endDate).max() ?? Date()
        let midpoint = Date(timeIntervalSince1970:
            (sStart.timeIntervalSince1970 + sEnd.timeIntervalSince1970) / 2)
        let isNap = SleepClassifier.isNap(totalMinutes: asleep, midpoint: midpoint, timeZone: .current)
        return SleepSummary(
            totalMinutes: asleep,
            deepMinutes: deep > 0 ? deep : nil,
            remMinutes: rem > 0 ? rem : nil,
            coreMinutes: core > 0 ? core : nil,
            awakeMinutes: awake > 0 ? awake : nil,
            isNap: isNap)
    }

    // MARK: HR events (last 7 days)

    private static func liveHREvents() async throws -> [HREventSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [HREventSummary] = []
        let map: [(HKCategoryTypeIdentifier, HREventKind)] = [
            (.lowHeartRateEvent, .low), (.highHeartRateEvent, .high),
            (.irregularHeartRhythmEvent, .irregular),
        ]
        for (id, kind) in map {
            if let e = try await eventSummary(id, kind: kind) { out.append(e) }
        }
        return out
    }

    private static func eventSummary(_ id: HKCategoryTypeIdentifier,
                                     kind: HREventKind) async throws -> HREventSummary? {
        let store = HKHealthStore()
        let start = Date().addingTimeInterval(-7 * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(id), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: s ?? [])
            }
            store.execute(q)
        }
        guard let newest = samples.first else { return nil }
        return HREventSummary(kind: kind, count: samples.count, mostRecent: newest.endDate)
    }

    // MARK: Overnight vitals + mobility

    private static func liveVitals() async throws -> OvernightVitals? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let resp = try? await latest(.respiratoryRate, unit: bpm, within: 24 * 3600)?.value
        let spo2 = try? await latest(.oxygenSaturation, unit: .percent(), within: 24 * 3600)?.value
        let temp = try? await latest(.appleSleepingWristTemperature,
                                     unit: .degreeCelsius(), within: 24 * 3600)?.value
        let v = OvernightVitals(respiratoryRate: resp ?? nil,
                                oxygenSaturation: spo2 ?? nil,
                                wristTemperatureDeviation: temp ?? nil)
        return v.isEmpty ? nil : v
    }

    private static func liveMobility() async throws -> MobilitySummary? {
        let steady = try? await latest(.appleWalkingSteadiness, unit: .percent(),
                                       within: 7 * 86_400)?.value
        let asym = try? await latest(.walkingAsymmetryPercentage, unit: .percent(),
                                     within: 7 * 86_400)?.value
        let m = MobilitySummary(
            steadiness: (steady ?? nil).map { WalkingSteadiness.classify(percent: $0 * 100) },
            asymmetryPercent: (asym ?? nil).map { $0 * 100 })
        return m.isEmpty ? nil : m
    }

    // MARK: Generic quantity reads

    /// Most recent sample of a quantity type (value + date), optionally restricted to
    /// the last `within` seconds. nil when there is no qualifying sample.
    private static func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                               within: TimeInterval? = nil) async throws -> DatedValue? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let predicate = within.map {
            HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-$0), end: nil, options: [])
        }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
                                  limit: 1, sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: s?.first as? HKQuantitySample)
            }
            store.execute(q)
        }
        guard let sample else { return nil }
        return DatedValue(value: sample.quantity.doubleValue(for: unit), date: sample.endDate)
    }

    /// Cumulative sum of a quantity type from local midnight to now.
    private static func sumToday(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let midnight = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: midnight, end: nil, options: [.strictStartDate])
        let stats: HKStatistics? = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats)
            }
            store.execute(q)
        }
        return stats?.sumQuantity()?.doubleValue(for: unit)
    }

    /// Discrete average of a quantity type over a window (for running dynamics).
    private static func avg(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                            from: Date, to: Date, store: HKHealthStore) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let stats: HKStatistics? = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                      quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats)
            }
            store.execute(q)
        }
        return stats?.averageQuantity()?.doubleValue(for: unit)
    }

    // MARK: Distance / activity naming

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
