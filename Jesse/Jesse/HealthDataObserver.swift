import Foundation
import HealthKit
import JesseCore

// The HealthKit half of the automatic health turns: two observer queries (body mass and
// workouts), background delivery for both, and the anchored queries that say what actually
// arrived. Deliberately thin, like `HealthContextProvider`: it reduces each arrival to plain
// dates and identifiers and hands them to `HealthAutoTrigger`, which decides everything.
//
// What HealthKit's own documentation says, and what this is built around:
//
//  * Observer queries that should receive background delivery must be set up in
//    `application(_:didFinishLaunchingWithOptions:)`, so they exist when HealthKit relaunches
//    the app to deliver. `HealthAutoTrigger.startIfEnabled` is called from there.
//  * The observer's completion handler must be called on EVERY path. An app that fails to
//    call it three times is assumed unable to receive data and stops being woken.
//  * Background delivery needs `com.apple.developer.healthkit.background-delivery` (iOS 15+);
//    without it `enableBackgroundDelivery` fails with `errorAuthorizationDenied`.
//  * The system wakes the app at most once per the requested frequency, and some types have
//    an HOURLY maximum it enforces silently (the docs name `stepCount` on iOS as an example,
//    and give no list for body mass or workouts). `.immediate` is requested; nothing here
//    depends on getting it. The ledger and the day stamp persist, so an hourly delivery is
//    only later, never wrong.
//  * Background delivery does not run on the Simulator at all.
//
// Deleted objects come back from an anchored query too. They are counted and logged, never
// acted on: the app's job ends at sending a turn, and a row for a deleted or edited workout
// is the morning export reconcile's to correct.

/// What one anchored query found, as plain values. `isBaseline` marks the FIRST query for a
/// type (no stored anchor): what it returns was already in HealthKit, not news.
nonisolated struct HealthArrivals<Item: Sendable>: Sendable {
    var items: [Item]
    var isBaseline: Bool
    /// The new anchor, archived, to store once the arrivals have been recorded.
    var anchor: Data?
    var deletedCount: Int
}

@MainActor
final class HealthDataObserver {
    nonisolated deinit {}

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// How far back a body-mass sample is worth looking at. Only today's diet day can fire, so
    /// two days covers the boundary with room to spare and keeps the first query small.
    nonisolated static let bodyMassWindow: TimeInterval = 2 * 24 * 3600

    private enum Kind: String {
        case bodyMass, workouts
        var anchorKey: String { "healthAnchor.\(rawValue)" }
    }

    private let store = HKHealthStore()
    private var queries: [HKObserverQuery] = []
    private let defaults: UserDefaults
    private let onBodyMass: (HealthArrivals<Date>) -> Void
    private let onWorkouts: (HealthArrivals<ObservedWorkout>) -> Void

    init(defaults: UserDefaults,
         onBodyMass: @escaping (HealthArrivals<Date>) -> Void,
         onWorkouts: @escaping (HealthArrivals<ObservedWorkout>) -> Void) {
        self.defaults = defaults
        self.onBodyMass = onBodyMass
        self.onWorkouts = onWorkouts
    }

    /// Register both observers and ask for background delivery. Idempotent.
    func start() {
        guard queries.isEmpty, Self.isAvailable else { return }
        register(HKQuantityType(.bodyMass), kind: .bodyMass)
        register(HKObjectType.workoutType(), kind: .workouts)
    }

    /// Stop both observers and every background delivery this app asked for.
    func stop() {
        for query in queries { store.stop(query) }
        queries = []
        store.disableAllBackgroundDelivery { _, error in
            if let error { Log.health.error("disable background delivery failed: \(error.localizedDescription)") }
        }
    }

    private func register(_ type: HKSampleType, kind: Kind) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            let done = ObserverCompletion(completion)
            if let error {
                Log.health.error("\(kind.rawValue) observer error: \(error.localizedDescription)")
                done.call()
                return
            }
            Task { @MainActor [weak self] in
                await self?.drain(kind)
                done.call()
            }
        }
        queries.append(query)
        store.execute(query)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { enabled, error in
            if !enabled {
                Log.health.error("\(kind.rawValue) background delivery not enabled: \(error?.localizedDescription ?? "no error given")")
            }
        }
    }

    /// Fetch what arrived since the stored anchor, hand it over, and only THEN store the new
    /// anchor — so a process killed in between re-reads the same samples next time, which the
    /// trigger's day stamp and workout ledger make harmless.
    private func drain(_ kind: Kind) async {
        let stored = defaults.data(forKey: kind.anchorKey)
        do {
            let anchor: Data?
            switch kind {
            case .bodyMass:
                let arrivals = try await Self.fetchBodyMass(anchor: stored, now: Date())
                log(kind, arrivals)
                onBodyMass(arrivals)
                anchor = arrivals.anchor
            case .workouts:
                let arrivals = try await Self.fetchWorkouts(anchor: stored, now: Date())
                log(kind, arrivals)
                onWorkouts(arrivals)
                anchor = arrivals.anchor
            }
            if let anchor { defaults.set(anchor, forKey: kind.anchorKey) }
        } catch {
            Log.health.error("\(kind.rawValue) anchored query failed: \(error.localizedDescription)")
        }
    }

    private func log<Item>(_ kind: Kind, _ arrivals: HealthArrivals<Item>) {
        Log.health.notice("\(kind.rawValue): \(arrivals.items.count) added, \(arrivals.deletedCount) deleted\(arrivals.isBaseline ? " (baseline)" : "")")
    }

    // MARK: - The anchored queries (nonisolated: each makes its own store, as the provider does)

    private nonisolated static func fetchBodyMass(anchor: Data?, now: Date) async throws
        -> HealthArrivals<Date> {
        let recent = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-bodyMassWindow),
                                                 end: nil, options: [])
        return try await fetch(.quantitySample(type: HKQuantityType(.bodyMass), predicate: recent),
                               anchor: anchor) { $0.startDate }
    }

    private nonisolated static func fetchWorkouts(anchor: Data?, now: Date) async throws
        -> HealthArrivals<ObservedWorkout> {
        let recent = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-WorkoutAutoLog.horizon),
                                                 end: nil, options: [])
        return try await fetch(.workout(recent), anchor: anchor) {
            ObservedWorkout(id: $0.uuid.uuidString, end: $0.endDate)
        }
    }

    private nonisolated static func fetch<Sample: HKSample, Item: Sendable>(
        _ predicate: HKSamplePredicate<Sample>, anchor: Data?, map: (Sample) -> Item
    ) async throws -> HealthArrivals<Item> {
        let previous = anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [predicate], anchor: previous)
        let result = try await descriptor.result(for: HKHealthStore())
        let archived = try? NSKeyedArchiver.archivedData(withRootObject: result.newAnchor,
                                                         requiringSecureCoding: true)
        return HealthArrivals(items: result.addedSamples.map(map), isBaseline: previous == nil,
                              anchor: archived, deletedCount: result.deletedObjects.count)
    }
}

/// Carries an observer query's completion handler into the task that finishes the work, and
/// makes calling it more than once harmless. Unchecked because the guarantee is HealthKit's:
/// the handler is documented to be callable from any thread. `nonisolated` because it is built
/// and called from HealthKit's own background queue, not the main actor this target defaults to.
private nonisolated final class ObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func call() {
        lock.lock()
        let pending = handler
        handler = nil
        lock.unlock()
        pending?()
    }
}
