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
        .stepCount, .bodyMass, .bodyFatPercentage, .leanBodyMass, .runningPower,
        .runningGroundContactTime, .runningVerticalOscillation, .runningStrideLength,
        .walkingAsymmetryPercentage, .appleWalkingSteadiness,
        // Workout detail + the overnight signals newer watch hardware writes.
        .swimmingStrokeCount, .waterTemperature, .workoutEffortScore,
        .estimatedWorkoutEffortScore, .appleSleepingBreathingDisturbances,
    ]
    private static let categoryReadIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .lowHeartRateEvent, .highHeartRateEvent, .irregularHeartRhythmEvent,
        .sleepApneaEvent, .hypertensionEvent,
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
    /// The per-day totals go through the same `SleepReducer` union as last night's
    /// summary — this series had the identical double count, once per extra writer.
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
        return SleepReducer.dailyMinutes(samples.map(sleepSample(from:)), calendar: cal)
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

    /// Re-request authorization ONLY when the requested type set has grown since the
    /// user last answered the prompt. An app updated with new read types is still
    /// "authorized" for the old set, so HealthKit never asks again on its own and
    /// every new type reads empty forever — silently, because read denial and
    /// "never asked" are indistinguishable by design.
    /// `statusForAuthorizationRequest` is the one signal that says the set has
    /// grown; anything but `.shouldRequest` (including an error, which reports
    /// `.unknown`) leaves the user alone. Returns true only when a prompt was
    /// actually shown and answered without error.
    static func requestAuthorizationIfTypesGrew() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let status = try? await HKHealthStore().statusForAuthorizationRequest(
            toShare: HealthKitMealWriter.shareTypes, read: readTypes)
        guard status == .shouldRequest else { return false }
        return await requestAuthorization()
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
            weight: { try await latest(.bodyMass, unit: .gramUnit(with: .kilo)) },
            // Body fat comes off HealthKit as a 0…1 fraction (HKUnit.percent()); the
            // formatter scales it to a percent. Same 7-day recency window as weight,
            // re-checked at format time.
            bodyFat: { try await latest(.bodyFatPercentage, unit: .percent()) },
            leanBodyMass: { try await latest(.leanBodyMass, unit: .gramUnit(with: .kilo)) })
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
        // Enrich every workout CONCURRENTLY — the query-backed detail below is
        // several reads per workout, and the whole gather shares one ~1.5s bound.
        // (The shipped code walked the workouts serially, so this is strictly less
        // wall clock than before even with the added reads.) Order is restored
        // from the index because a task group completes out of order.
        var enriched: [(Int, WorkoutSummary)] = await withTaskGroup(
            of: (Int, WorkoutSummary).self
        ) { group in
            for (i, w) in workouts.enumerated() {
                group.addTask {
                    let enriched = await enrich(summary(for: w), workout: w)
                    return (i, enriched)
                }
            }
            var acc: [(Int, WorkoutSummary)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }
        enriched.sort { $0.0 < $1.0 }
        return enriched.map(\.1)
    }

    /// Fill the fields that need their own query, each independently best-effort:
    /// a failed, denied or empty read leaves its field nil and the formatter omits
    /// it, exactly as the running dynamics have always degraded. The reads inside
    /// one workout run concurrently too.
    private static func enrich(_ base: WorkoutSummary, workout w: HKWorkout) async -> WorkoutSummary {
        let isSwim = base.swim != nil
        let needsStrokes = isSwim && base.swim?.strokeCount == nil
        let onFoot = base.isFootDistance
        let isRun = w.workoutActivityType == .running

        // Each of these makes its own HKHealthStore inside the query: the store is
        // not Sendable and must never be captured across a task boundary.
        async let effort = effortScore(for: w)
        async let dynamics: WorkoutSummary? = when(isRun) {
            await addingRunningDynamics(to: base, workout: w)
        }
        async let strokes: Double? = when(needsStrokes) {
            try await sumOverWorkout(.swimmingStrokeCount, unit: .count(), workout: w)
        }
        async let water: Double? = when(isSwim) {
            try await avgOverWorkout(.waterTemperature, unit: .degreeCelsius(), workout: w)
        }
        async let steps: Double? = when(onFoot) {
            try await sumOverWorkout(.stepCount, unit: .count(), workout: w)
        }
        async let splits: [Double]? = when(onFoot) { try await perKmSplits(for: w) }

        var s = await dynamics ?? base
        if let e = await effort {
            s.effortScore = e.score
            s.effortScoreIsUserRated = e.userRated
        }
        if let strokes = await strokes { s.swim?.strokeCount = strokes }
        if let water = await water { s.swim?.waterTemperatureC = water }
        s.stepCount = await steps
        if let splits = await splits, !splits.isEmpty { s.splitSecondsPerKm = splits }
        return s
    }

    /// Run one read and flatten every failure to nil, so a thrown, denied or empty
    /// read costs exactly its own field and nothing else.
    private static func bestEffort<T>(_ read: () async throws -> T?) async -> T? {
        (try? await read()) ?? nil
    }

    /// `bestEffort`, but only when the field applies to this activity at all — a
    /// cycle never asks for a swim's water temperature.
    private static func when<T>(_ condition: Bool, _ read: () async throws -> T?) async -> T? {
        condition ? await bestEffort(read) : nil
    }

    /// The workout's effort score and whether it is the user's own rating. The
    /// user-rated score wins over the watch's estimate when both exist.
    ///
    /// The association is read with `predicateForWorkoutEffortSamplesRelated`, the
    /// predicate the SDK provides for exactly this, rather than
    /// `HKWorkoutEffortRelationshipQuery`: that query is LONG-RUNNING (its handler
    /// fires again on every later change, and it must be stopped on the same store
    /// that executed it), which means capturing a non-Sendable `HKHealthStore` in a
    /// `@Sendable` handler and hand-guarding the continuation against a second
    /// resume. A one-shot sample query has neither hazard and answers the same
    /// question.
    private static func effortScore(for w: HKWorkout) async -> (score: Double, userRated: Bool)? {
        if let rated = await bestEffort({ try await effortSample(.workoutEffortScore, for: w) }) {
            return (rated, true)
        }
        if let est = await bestEffort({ try await effortSample(.estimatedWorkoutEffortScore, for: w) }) {
            return (est, false)
        }
        return nil
    }

    private static func effortSample(_ id: HKQuantityTypeIdentifier,
                                     for w: HKWorkout) async throws -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: w, activity: nil)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
                                  limit: 1, sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: s?.first as? HKQuantitySample)
            }
            store.execute(q)
        }
        return sample?.quantity.doubleValue(for: .appleEffortScore())
    }

    /// Per-kilometer splits from the walking/running distance samples the workout
    /// owns. `SplitReducer` does the interpolation; this only lifts the samples out.
    private static func perKmSplits(for w: HKWorkout) async throws -> [Double] {
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForObjects(from: w)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.distanceWalkingRunning),
                                  predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: sort) { _, s, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        return SplitReducer.splitSeconds(samples.map {
            DistanceSample(start: $0.startDate, end: $0.endDate,
                           meters: $0.quantity.doubleValue(for: .meter()))
        })
    }

    /// Reduce one workout to a pure `WorkoutSummary`, reading energy / distance /
    /// heart-rate from the statistics Apple Watch attaches to the workout and the
    /// rest from its metadata, its source revision and its events — all of which
    /// are already in hand, so none of this costs a query. Any missing stat is left
    /// nil (the formatter omits that field).
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
            source: w.sourceRevision.source.name,
            productType: w.sourceRevision.productType,
            isIndoor: metaBool(w.metadata, HKMetadataKeyIndoorWorkout),
            averageMETs: metaQuantity(w.metadata, HKMetadataKeyAverageMETs,
                                      HKUnit(from: "kcal/(kg*hr)")),
            elevationAscendedM: metaQuantity(w.metadata, HKMetadataKeyElevationAscended, .meter()),
            elevationDescendedM: metaQuantity(w.metadata, HKMetadataKeyElevationDescended, .meter()),
            weatherTemperatureC: metaQuantity(w.metadata, HKMetadataKeyWeatherTemperature,
                                              .degreeCelsius()),
            // Apple's Workout app stores the weather humidity so that reading it in
            // HKUnit.percent() returns 0…100, while the unit is DOCUMENTED as a 0…1
            // fraction and a third-party app may write it that way. Neither reading
            // can be assumed, so the raw value goes to the pure normalizer, which
            // accepts both and rejects what cannot be a humidity. The provider
            // decides nothing.
            weatherHumidityPercent: metaQuantity(w.metadata, HKMetadataKeyWeatherHumidity,
                                                 .percent())
                .flatMap { WorkoutContextFormatter.humidityPercent(fromRaw: $0) },
            swim: swimDetail(for: w))
    }

    /// The swim aggregates that need no query: pool length and location from the
    /// workout's metadata, the lap roll-up from its events, and the stroke count
    /// from the statistics it already carries. nil for a non-swim, and for a swim
    /// that recorded none of it.
    private static func swimDetail(for w: HKWorkout) -> SwimDetail? {
        guard w.workoutActivityType == .swimming else { return nil }
        var d = SwimDetail()
        d.lapLengthM = metaQuantity(w.metadata, HKMetadataKeyLapLength, .meter())
        if let raw = metaNumber(w.metadata, HKMetadataKeySwimmingLocationType)
            .map({ HKWorkoutSwimmingLocationType(rawValue: Int($0)) }) ?? nil {
            switch raw {
            case .pool: d.location = .pool
            case .openWater: d.location = .openWater
            default: break
            }
        }
        d.strokeCount = w.statistics(for: HKQuantityType(.swimmingStrokeCount))?
            .sumQuantity()?.doubleValue(for: .count())

        // The lap events, mapped to plain values — every rule about what they mean
        // belongs to SwimLapReducer, the way SleepReducer owns the sleep rules.
        let laps = (w.workoutEvents ?? [])
            .filter { $0.type == .lap }
            .map { e in
                SwimLap(start: e.dateInterval.start,
                        end: e.dateInterval.end,
                        strokeStyleRawValue: metaNumber(e.metadata,
                                                        HKMetadataKeySwimmingStrokeStyle).map { Int($0) },
                        swolf: metaNumber(e.metadata, HKMetadataKeySWOLFScore))
            }
        if let r = SwimLapReducer.reduce(laps) {
            d.lapCount = r.lapCount
            d.swimSeconds = r.swimSeconds
            d.averageSWOLF = r.averageSWOLF
            d.lapsByStroke = r.lapsByStroke
        }
        return d.isEmpty ? nil : d
    }

    // MARK: Metadata accessors

    /// An `HKQuantity`-valued metadata entry in `unit`. The compatibility check is
    /// load-bearing: `doubleValue(for:)` raises an ObjC exception (which Swift
    /// cannot catch) on a mismatched unit, so a writer storing, say, a temperature
    /// under a length key would take the app down rather than render nothing.
    private static func metaQuantity(_ metadata: [String: Any]?, _ key: String,
                                     _ unit: HKUnit) -> Double? {
        guard let q = metadata?[key] as? HKQuantity, q.is(compatibleWith: unit) else { return nil }
        return q.doubleValue(for: unit)
    }

    private static func metaNumber(_ metadata: [String: Any]?, _ key: String) -> Double? {
        (metadata?[key] as? NSNumber)?.doubleValue
    }

    private static func metaBool(_ metadata: [String: Any]?, _ key: String) -> Bool? {
        (metadata?[key] as? NSNumber)?.boolValue
    }

    /// Add average running-dynamics (power / GCT / vertical oscillation / stride) to
    /// a run's summary, each read as a discrete-average statistic over the workout
    /// window. A missing series stays nil and its field is omitted downstream.
    private static func addingRunningDynamics(to s: WorkoutSummary,
                                              workout w: HKWorkout) async -> WorkoutSummary {
        let store = HKHealthStore()
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

    /// Map HealthKit's samples into the pure `SleepSample` value type and hand them
    /// to `SleepReducer`, which owns every rule (session grouping, the interval
    /// union that stops two writers double-counting the same night, and the
    /// single-source stage breakdown). Nothing is decided here.
    private static func reduceSleep(_ samples: [HKCategorySample]) -> SleepSummary? {
        SleepReducer.reduce(samples.map(sleepSample(from:)), timeZone: .current)
    }

    /// The one HealthKit-shaped step: a category sample's span, stage value, and the
    /// bundle identifier of the app that wrote it.
    private static func sleepSample(from s: HKCategorySample) -> SleepSample {
        SleepSample(start: s.startDate, end: s.endDate, value: s.value,
                    sourceID: s.sourceRevision.source.bundleIdentifier)
    }

    // MARK: HR events (last 7 days)

    private static func liveHREvents() async throws -> [HREventSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var out: [HREventSummary] = []
        let map: [(HKCategoryTypeIdentifier, HREventKind)] = [
            (.lowHeartRateEvent, .low), (.highHeartRateEvent, .high),
            (.irregularHeartRhythmEvent, .irregular),
            (.sleepApneaEvent, .sleepApnea), (.hypertensionEvent, .hypertension),
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
        // Hardware dependent — absent on a watch that does not measure it, which
        // simply leaves the segment off the line.
        let breathing = try? await latest(.appleSleepingBreathingDisturbances,
                                          unit: .count(), within: 24 * 3600)?.value
        let v = OvernightVitals(respiratoryRate: resp ?? nil,
                                oxygenSaturation: spo2 ?? nil,
                                wristTemperatureDeviation: temp ?? nil,
                                breathingDisturbances: breathing ?? nil)
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

    /// Cumulative sum of a quantity type over one workout's window.
    private static func sumOverWorkout(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                       workout w: HKWorkout) async throws -> Double? {
        try await stat(id, unit: unit, workout: w, options: .cumulativeSum)
    }

    /// Discrete average of a quantity type over one workout's window.
    private static func avgOverWorkout(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                       workout w: HKWorkout) async throws -> Double? {
        try await stat(id, unit: unit, workout: w, options: .discreteAverage)
    }

    private static func stat(_ id: HKQuantityTypeIdentifier, unit: HKUnit, workout w: HKWorkout,
                             options: HKStatisticsOptions) async throws -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate,
                                                    options: [])
        let stats: HKStatistics? = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                      quantitySamplePredicate: predicate,
                                      options: options) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats)
            }
            store.execute(q)
        }
        guard let stats else { return nil }
        let q = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
        return q?.doubleValue(for: unit)
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

    /// A short, stable name for every activity type a person plausibly records on a
    /// watch. `Workout` is the true default only — an unnamed type used to swallow
    /// `.other`, `.mixedCardio` and `.coreTraining` alike, so three different
    /// sessions read identically in the block.
    ///
    /// "Swim" is load-bearing beyond display: the pure formatter reads it to decide
    /// the whole-meter distance format and the swim detail segments.
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
        case .other: return "Other"
        case .mixedCardio: return "Mixed cardio"
        case .crossTraining: return "Cross training"
        case .coreTraining: return "Core"
        case .cooldown: return "Cooldown"
        case .flexibility: return "Flexibility"
        case .pilates: return "Pilates"
        case .barre: return "Barre"
        case .stairClimbing, .stairs: return "Stairs"
        case .stepTraining: return "Step"
        case .jumpRope: return "Jump rope"
        case .paddleSports: return "Paddle"
        case .swimBikeRun: return "Triathlon"
        case .transition: return "Transition"
        case .cardioDance: return "Cardio dance"
        case .socialDance: return "Dance"
        case .mindAndBody: return "Mind and body"
        case .preparationAndRecovery: return "Recovery"
        case .taiChi: return "Tai chi"
        case .martialArts: return "Martial arts"
        case .kickboxing: return "Kickboxing"
        case .boxing: return "Boxing"
        case .climbing: return "Climbing"
        case .golf: return "Golf"
        case .tennis: return "Tennis"
        case .pickleball: return "Pickleball"
        case .tableTennis: return "Table tennis"
        case .badminton: return "Badminton"
        case .squash: return "Squash"
        case .racquetball: return "Racquetball"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .volleyball: return "Volleyball"
        case .baseball: return "Baseball"
        case .americanFootball: return "Football"
        case .rugby: return "Rugby"
        case .hockey: return "Hockey"
        case .crossCountrySkiing: return "XC ski"
        case .downhillSkiing: return "Downhill ski"
        case .snowboarding: return "Snowboard"
        case .skatingSports: return "Skating"
        case .surfingSports: return "Surfing"
        case .sailing: return "Sailing"
        case .equestrianSports: return "Equestrian"
        case .fishing: return "Fishing"
        case .archery: return "Archery"
        case .bowling: return "Bowling"
        case .discSports: return "Disc sports"
        case .fitnessGaming: return "Fitness gaming"
        case .gymnastics: return "Gymnastics"
        case .handCycling: return "Hand cycling"
        case .underwaterDiving: return "Diving"
        case .waterFitness: return "Water fitness"
        case .waterPolo: return "Water polo"
        case .waterSports: return "Water sports"
        case .wheelchairWalkPace: return "Wheelchair walk"
        case .wheelchairRunPace: return "Wheelchair run"
        case .play: return "Play"
        case .trackAndField: return "Track and field"
        default: return "Workout"
        }
    }
}
