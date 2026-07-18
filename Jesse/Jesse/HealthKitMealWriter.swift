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
    /// These are ONLY dietary quantity types (never an `HKCorrelationType`): HealthKit
    /// forbids requesting authorization for the `.food` container at all, and raises
    /// `NSInvalidArgumentException` at the `requestAuthorization` call if one appears
    /// here. Saving the `.food` `HKCorrelation` needs no container grant — share
    /// authorization for every sample it contains is sufficient, so each quantity type
    /// a meal may carry (the five macros plus the six HealthKit-bound micronutrients)
    /// must be in this set. Omega-3 is gauge-only (no HealthKit EPA+DHA type) and so is
    /// absent here. Guarded by `HealthKitAuthorizationTypesTests`.
    static let shareTypes: Set<HKSampleType> = [
        HKQuantityType(.dietaryEnergyConsumed),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryFatTotal),
        HKQuantityType(.dietaryFiber),
        HKQuantityType(.dietarySodium),
        HKQuantityType(.dietaryFatSaturated),
        HKQuantityType(.dietarySugar),
        HKQuantityType(.dietaryPotassium),
        HKQuantityType(.dietaryCalcium),
        HKQuantityType(.dietaryMagnesium),
    ]

    /// The representative type whose share status stands for "meal writing" (they
    /// are all requested together, so one is enough to read the user's decision).
    private static let statusType = HKQuantityType(.dietaryEnergyConsumed)

    /// Build the HealthKit quantity samples for a meal — one per present macro AND per
    /// present micronutrient — as a pure function so the sample set is unit-testable
    /// without a save (`MealHealthWriterTests`). A nil / negative / non-finite value
    /// writes NO sample (never a zero), so a micronutrient with no known value across
    /// the meal (nil on the `Meal`) is simply omitted. The existing five macro samples
    /// are unchanged; the six micronutrients are additive — sodium/potassium/calcium/
    /// magnesium in milligrams (`HKUnit` gram-milli), saturated fat and sugars in grams.
    static func samples(for meal: Meal) -> Set<HKSample> {
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
        add(.dietaryFiber, .gram(), meal.fiberGrams)
        add(.dietarySodium, .gramUnit(with: .milli), meal.sodiumMg)
        add(.dietaryFatSaturated, .gram(), meal.satFatGrams)
        add(.dietarySugar, .gram(), meal.sugarGrams)
        add(.dietaryPotassium, .gramUnit(with: .milli), meal.potassiumMg)
        add(.dietaryCalcium, .gramUnit(with: .milli), meal.calciumMg)
        add(.dietaryMagnesium, .gramUnit(with: .milli), meal.magnesiumMg)
        return samples
    }

    func write(_ meal: Meal) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        let samples = Self.samples(for: meal)

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

    /// Delete the app's `.food` correlation for `id` and its contained quantity samples.
    /// The meal id was stored as `HKMetadataKeyExternalUUID` on the correlation, so we
    /// query for `.food` correlations with that value, then delete each correlation
    /// **together with its `.objects`** (the contained samples) — correlation deletion
    /// does not cascade, and there are now up to eleven quantity types per meal, so we
    /// enumerate the present samples rather than assume a count. HealthKit only lets the
    /// app delete objects IT wrote,
    /// so another source's data is never touched even if it shared the external id.
    func delete(id: String) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id])
        do {
            let correlations = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[HKCorrelation], Error>) in
                let query = HKCorrelationQuery(
                    type: HKCorrelationType(.food), predicate: predicate, samplePredicates: nil
                ) { _, results, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
                }
                store.execute(query)
            }
            // Nothing matched → the id is already absent (idempotent retract/rewrite).
            guard !correlations.isEmpty else { return true }
            // Delete each correlation AND the quantity samples it contains (no cascade).
            var toDelete: [HKObject] = []
            for correlation in correlations {
                toDelete.append(correlation)
                toDelete.append(contentsOf: correlation.objects)
            }
            try await store.delete(toDelete)
            return true
        } catch {
            Log.health.error("meal delete failed for \(id): \(error.localizedDescription)")
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
