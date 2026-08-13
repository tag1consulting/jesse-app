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
    /// a meal may carry (the five macros plus the nine HealthKit-bound micronutrients)
    /// must be in this set. The gauge-only nutrients are absent here because HealthKit has
    /// no type that means the same thing: omega-3 (no EPA+DHA type), trans fat, purines,
    /// mercury, and added sugar (`dietarySugar` is TOTAL sugar, not the added share).
    /// Guarded by `HealthKitAuthorizationTypesTests`.
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
        HKQuantityType(.dietaryCholesterol),
        HKQuantityType(.dietarySelenium),
        HKQuantityType(.dietaryVitaminD),
    ]

    /// The representative type whose share status stands for "meal writing" (they
    /// are all requested together, so one is enough to read the user's decision).
    private static let statusType = HKQuantityType(.dietaryEnergyConsumed)

    /// Build the HealthKit quantity samples for a meal — one per present macro AND per
    /// present micronutrient — as a pure function so the sample set is unit-testable
    /// without a save (`MealHealthWriterTests`). A nil / negative / non-finite value
    /// writes NO sample (never a zero), so a micronutrient with no known value across
    /// the meal (nil on the `Meal`) is simply omitted. A genuine measured 0 DOES
    /// write a sample — it is a fact ("this meal supplied none"), not an absence of data,
    /// and the two are told apart upstream by nil vs 0. The existing five macro samples
    /// are unchanged; the nine micronutrients are additive — sodium/potassium/calcium/
    /// magnesium/cholesterol in milligrams (`HKUnit` gram-milli), saturated fat and sugars
    /// in grams, selenium and vitamin D in micrograms.
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
        add(.dietaryCholesterol, .gramUnit(with: .milli), meal.cholesterolMg)
        add(.dietarySelenium, .gramUnit(with: .micro), meal.seleniumUg)
        add(.dietaryVitaminD, .gramUnit(with: .micro), meal.vitaminDUg)
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

    /// The clause that picks the meal: the external id stored as
    /// `HKMetadataKeyExternalUUID` when the correlation was saved. Selection by this
    /// clause ALONE would rest on a value that arrives in agent output and is validated
    /// only as a non-empty string, so it is never used on its own — see
    /// `deletePredicate(id:scopedTo:)`.
    static func externalIDPredicate(id: String) -> NSPredicate {
        HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id])
    }

    /// The app's own-source scope, and the reason the delete path is safe regardless of
    /// what id it is handed.
    ///
    /// **Never call this from a test.** `HKSource.default()` derives the client's
    /// identity from the process's code-signing ENTITLEMENTS — not from `Info.plist`,
    /// whose `CFBundleIdentifier` is present either way. A process built with
    /// `CODE_SIGNING_ALLOWED=NO`, which is exactly how CI builds and tests this app, has
    /// no entitlements, so this raises `NSGenericException` ("Unable to create default
    /// source from entitlements") and, being an uncaught ObjC exception, terminates the
    /// host. The shipping app is signed and carries the HealthKit entitlement, so the
    /// production path is unaffected. This is why the composition below is factored out
    /// and tested separately from the scope itself.
    static func ownSourceScope() -> NSPredicate {
        HKQuery.predicateForObjects(from: HKSource.default())
    }

    /// The predicate selecting what `delete(id:)` may remove: `sourceScope` AND the
    /// external-id match. Both clauses are load-bearing, and the source clause is what
    /// makes the scoping a property of this code rather than an inherited one.
    ///
    /// Two platform behaviours would otherwise have to hold for the id clause alone to
    /// be safe — that HealthKit refuses to delete objects the app did not write, and
    /// that an app with no dietary READ authorization can only see its own food samples.
    /// Both are Apple-documented, neither is asserted anywhere, and the second stops
    /// holding the moment a dietary type is added to `HealthContextProvider.readTypes`
    /// (say, to show intake across all sources).
    ///
    /// Pure, and takes the scope as a parameter rather than building it, so the
    /// conjunction is unit-testable in an unsigned test host where `ownSourceScope()`
    /// cannot be constructed at all. The one caller passes `ownSourceScope()`; that the
    /// call site still does so is checked by `scripts/ci-guards.sh`, since no test in an
    /// unsigned process can observe it.
    static func deletePredicate(id: String, scopedTo sourceScope: NSPredicate) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            externalIDPredicate(id: id),
            sourceScope,
        ])
    }

    /// Delete the app's `.food` correlation for `id` and its contained quantity samples.
    /// Selection is `deletePredicate(id:)` — this app's own food correlations carrying
    /// that external id — and each match is deleted **together with its `.objects`** (the
    /// contained samples), because correlation deletion does not cascade and there are up
    /// to fourteen quantity types per meal, so we enumerate the present samples rather than
    /// assume a count. Enumeration — not a count — is what makes this additive: every
    /// nutrient added since has flowed through `correlation.objects` with no change here,
    /// and the three newest do too. A correlation's contained samples were saved with it, so scoping
    /// the correlation to this app's source scopes its objects too.
    ///
    /// Idempotent by contract: an id matching nothing returns `true` (already absent), so
    /// a retract of an id this app never wrote is a no-op success and never a retry loop.
    func delete(id: String) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let store = HKHealthStore()
        let predicate = Self.deletePredicate(id: id, scopedTo: Self.ownSourceScope())
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
