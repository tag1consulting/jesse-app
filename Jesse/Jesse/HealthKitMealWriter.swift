import Foundation
import HealthKit

// The SECOND (and only other) file that imports HealthKit, alongside
// `HealthContextProvider` — the write half of the read/write split. Per the
// confinement rule, HealthKit types never leak out of these provider files: this
// conforms to the Foundation-only `MealWriting` seam and hands back only `Bool`s.
// The standing ownership split holds — this only ever creates a `.food`
// correlation of dietary energy + macros; weight and workouts stay read-only.

/// Writes a logged meal into Apple Health as one food correlation: a `.food`
/// `HKCorrelation` whose start/end are the meal time, carrying the food name and
/// the meal `id` (as the external identifier) in metadata, and containing one
/// `HKQuantitySample` per present macro (kcal in kilocalories, macros in grams).
/// HealthKit saves succeed even while the device is locked (journal staging), so
/// the watch-relay path works with the phone locked. Best-effort: a failed save
/// returns `false` and the caller enqueues it for a later retry.
nonisolated struct HealthKitMealWriter: MealWriting {
    /// The dietary quantity types this writes — also the app's HealthKit **share**
    /// (write) set, requested at connect time and queried for the write posture.
    /// The `.food` correlation type is included so authorization covers the
    /// container as well as its samples.
    static let shareTypes: Set<HKSampleType> = [
        HKQuantityType(.dietaryEnergyConsumed),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryFatTotal),
        HKCorrelationType(.food),
    ]

    /// The representative type whose share status stands for "meal writing" (they
    /// are all requested together, so one is enough to read the user's decision).
    private static let statusType = HKQuantityType(.dietaryEnergyConsumed)

    func write(_ meal: Meal) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        var samples: Set<HKSample> = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double?) {
            guard let value, value.isFinite, value >= 0 else { return }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            samples.insert(HKQuantitySample(type: HKQuantityType(id), quantity: quantity,
                                            start: meal.consumedAt, end: meal.consumedAt))
        }
        add(.dietaryEnergyConsumed, .kilocalorie(), meal.kcal)
        add(.dietaryProtein, .gram(), meal.proteinGrams)
        add(.dietaryCarbohydrates, .gram(), meal.carbGrams)
        add(.dietaryFatTotal, .gram(), meal.fatGrams)

        // A meal with no macros has nothing quantitative to store — a correlation
        // needs at least one sample. Treat it as done (so it's recorded and never
        // retried) rather than a failure.
        guard !samples.isEmpty else { return true }

        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: meal.name,
            HKMetadataKeyExternalUUID: meal.id,
        ]
        let food = HKCorrelation(type: HKCorrelationType(.food),
                                 start: meal.consumedAt, end: meal.consumedAt,
                                 objects: samples, metadata: metadata)
        do {
            try await HKHealthStore().save(food)
            return true
        } catch {
            Log.health.error("meal write failed for \(meal.id): \(error.localizedDescription)")
            return false
        }
    }

    func isAuthorizedToWrite() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        // Denied ⇒ the user turned meal writing off ⇒ disable quietly. `.notDetermined`
        // is treated as authorized-enough: the connect-time request already prompted,
        // and a genuine denial surfaces distinctly as `.sharingDenied`.
        return HKHealthStore().authorizationStatus(for: Self.statusType) != .sharingDenied
    }

    /// Whether write access is explicitly DENIED — for the Settings row, which
    /// reports it and disables the toggle. `false` when authorized, not-determined,
    /// or Health is unavailable.
    static func isWriteDenied() -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return HKHealthStore().authorizationStatus(for: statusType) == .sharingDenied
    }
}
