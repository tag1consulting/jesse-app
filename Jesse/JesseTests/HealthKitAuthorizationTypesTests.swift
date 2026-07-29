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
@MainActor
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

    /// The READ set must contain no dietary type. This is NOT what makes the meal
    /// delete path safe — `HealthKitMealWriter.deletePredicate(id:)` scopes deletion
    /// to this app's own source, and holds whatever the read set says. This is a
    /// tripwire on a specific future change: adding a dietary read type is what
    /// "show the user their intake across all sources" looks like, and that widens
    /// what a `.food` correlation query can see. It should be a decision taken
    /// deliberately and reviewed against the delete path, not one that lands
    /// silently inside an unrelated feature. Failing here is the prompt to do that.
    func testReadSetContainsNoDietaryType() {
        let dietaryPrefix = "HKQuantityTypeIdentifierDietary"
        for id in HealthContextProvider.readTypes.map(\.identifier) {
            XCTAssertFalse(id.hasPrefix(dietaryPrefix),
                           "read set contains a dietary type (\(id)) — this widens what a "
                           + "food-correlation query can see; review HealthKitMealWriter.delete")
        }
    }

    /// The meal delete predicate must be a CONJUNCTION of the external-id match and the
    /// scope it is given. Dropping either clause would leave selection resting on the
    /// metadata id alone, which comes from agent output and is validated only as a
    /// non-empty string.
    ///
    /// The scope is passed in rather than built here for a reason worth stating: the
    /// real scope, `HealthKitMealWriter.ownSourceScope()`, calls `HKSource.default()`,
    /// which reads the process's code-signing entitlements and raises
    /// `NSGenericException` when there are none. CI builds and tests this app with
    /// `CODE_SIGNING_ALLOWED=NO`, so calling it here would terminate the test host — it
    /// did, before this was split. Composition is therefore tested with a stand-in
    /// scope, and the fact that the caller passes the real one is checked by
    /// `scripts/ci-guards.sh`, which is a source-level pattern check rather than a
    /// behavioural test. That is the honest division: an unsigned process cannot observe
    /// the real scope at all.
    func testDeletePredicateAndsTheIDClauseWithTheGivenScope() {
        let scope = NSPredicate(format: "%K == %@", "stand_in_scope", "own-source")
        let predicate = HealthKitMealWriter.deletePredicate(id: "2026-07-29-lunch",
                                                           scopedTo: scope)
        guard let compound = predicate as? NSCompoundPredicate else {
            return XCTFail("delete predicate is not a compound predicate: \(predicate)")
        }
        XCTAssertEqual(compound.compoundPredicateType, .and,
                       "delete predicate must AND its clauses, never OR them")
        XCTAssertEqual(compound.subpredicates.count, 2,
                       "delete predicate must carry exactly the id clause and the scope")
        XCTAssertTrue(compound.subpredicates.contains { ($0 as? NSPredicate) == scope },
                      "delete predicate dropped the scope it was given — deletion would rest "
                      + "on the agent-supplied external id alone")
        let idClause = HealthKitMealWriter.externalIDPredicate(id: "2026-07-29-lunch")
        XCTAssertTrue(compound.subpredicates.contains { ($0 as? NSPredicate) == idClause },
                      "delete predicate dropped the external-id clause")
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
