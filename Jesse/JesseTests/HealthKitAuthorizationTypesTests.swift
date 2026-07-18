import XCTest
import HealthKit
@testable import Jesse

/// Guards the class of bug that crashed build 20 on device: a `HKCorrelationType`
/// (the `.food` container) had been added to the HealthKit **share** set, and
/// `HKHealthStore.requestAuthorization` raises `NSInvalidArgumentException`
/// ("Authorization to share the following types is disallowed:
/// HKCorrelationTypeIdentifierFood") the moment a correlation type appears in ANY
/// authorization set — read or share. Apple's model: you authorize only the sample
/// types a correlation contains; saving the `HKCorrelation` itself needs no
/// container-level grant. These assertions run against the pure, exposed type sets
/// (`HealthKitMealWriter.shareTypes`, `HealthContextProvider.readTypes`) so the
/// mistake is caught at its own layer — the real `requestAuthorization` is
/// unexercisable in the sandbox and only ever failed on device.
final class HealthKitAuthorizationTypesTests: XCTestCase {

    /// The share (write) set is EXACTLY the eleven dietary quantity types a meal may
    /// carry — the five macros plus the six HealthKit-bound micronutrients (sodium,
    /// saturated fat, sugar, potassium, calcium, magnesium) — no more, no fewer, and
    /// specifically no correlation container, and specifically NOT omega-3 (gauge-only,
    /// no HealthKit EPA+DHA type). Every quantity type a `.food` sample uses must be
    /// authorized to share, or the save fails.
    func testShareSetIsExactlyTheElevenDietaryQuantityTypes() {
        let expected: Set<String> = Set([
            HKQuantityTypeIdentifier.dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal,
            .dietaryFiber,
            .dietarySodium,
            .dietaryFatSaturated,
            .dietarySugar,
            .dietaryPotassium,
            .dietaryCalcium,
            .dietaryMagnesium,
        ].map(\.rawValue))
        let actual = Set(HealthKitMealWriter.shareTypes.map(\.identifier))
        XCTAssertEqual(actual, expected,
                       "share set must be exactly the eleven dietary quantity types")
    }

    /// No identifier in ANY authorization set (read or share) may be a correlation
    /// type — HealthKit forbids requesting authorization for `HKCorrelationType` at
    /// all, and doing so crashes at the `requestAuthorization` call. This makes the
    /// whole class of bug unrepresentable, not just the one `.food` instance.
    func testNoAuthorizationSetContainsACorrelationType() {
        let correlationPrefix = "HKCorrelationTypeIdentifier"
        let shareIds = HealthKitMealWriter.shareTypes.map(\.identifier)
        let readIds = HealthContextProvider.readTypes.map(\.identifier)
        for id in shareIds {
            XCTAssertFalse(id.hasPrefix(correlationPrefix),
                           "share set contains a correlation type: \(id)")
        }
        for id in readIds {
            XCTAssertFalse(id.hasPrefix(correlationPrefix),
                           "read set contains a correlation type: \(id)")
        }
    }
}
