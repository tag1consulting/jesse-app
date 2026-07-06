import Foundation

// The Foundation-only seams and orchestration for writing logged meals into Apple
// Health. HealthKit itself is confined to `HealthKitMealWriter` (behind the
// `MealWriting` seam); the idempotency store is confined to
// `SwiftDataWrittenMealStore` (behind `WrittenMealStoring`); the pending-write
// queue is `PendingMealStore` (UserDefaults). This file glues them with a pure,
// fully-tested policy — gate, dedupe, write, record-or-enqueue, drain — so the
// whole reliability story is testable without HealthKit, SwiftData, or a device.

/// Writes one meal into Apple Health and reports the write-authorization posture.
/// The one production conformer is `HealthKitMealWriter`; tests inject a fake.
protocol MealWriting: Sendable {
    /// Write one meal as a food correlation. `true` on success — or when there is
    /// nothing quantitative to write (a meal with no macros is a no-op that counts
    /// as done, so it isn't retried forever). `false` on a real, retryable failure.
    func write(_ meal: Meal) async -> Bool

    /// The write posture. `false` only when the user has **explicitly denied** write
    /// access (write status is queryable, unlike read) — the feature then disables
    /// quietly and nothing is enqueued. `true` when authorized or not-yet-determined.
    func isAuthorizedToWrite() async -> Bool
}

/// The idempotency store: the set of meal ids already written to Apple Health, so a
/// re-poll / Re-check / re-opened thread / watch relay of the same reply never
/// double-writes. Main-actor because the production conformer is SwiftData-backed;
/// tests inject an in-memory set.
@MainActor protocol WrittenMealStoring {
    func isWritten(_ id: String) -> Bool
    func markWritten(_ id: String)
}

/// The persisted queue of meals whose Health write failed, drained on the next
/// foreground / next turn. Same shape (and non-`Sendable`, UserDefaults-backed) as
/// the coordinator's `InFlightStoring` — only ever used from the main actor.
protocol PendingMealStoring {
    func enqueue(_ meals: [Meal])
    func dequeueAll() -> [Meal]
}

/// UserDefaults-backed pending-write queue. Small and best-effort: a failed write
/// is held here and retried later, deduped by meal id so a repeatedly-failing meal
/// never grows the store unbounded. The backing `UserDefaults` is injectable so a
/// test uses its own suite instead of `.standard` (mirroring `InFlightStore`).
nonisolated struct PendingMealStore: PendingMealStoring {
    private static let key = "jesse.pendingMealWrites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func enqueue(_ meals: [Meal]) {
        guard !meals.isEmpty else { return }
        var all = load()
        for m in meals where !all.contains(where: { $0.id == m.id }) { all.append(m) }
        save(all)
    }

    func dequeueAll() -> [Meal] {
        let all = load()
        if !all.isEmpty { defaults.removeObject(forKey: Self.key) }
        return all
    }

    private func load() -> [Meal] {
        guard let data = defaults.data(forKey: Self.key),
              let meals = try? JSONDecoder().decode([Meal].self, from: data) else { return [] }
        return meals
    }

    private func save(_ meals: [Meal]) {
        if let data = try? JSONEncoder().encode(meals) { defaults.set(data, forKey: Self.key) }
    }
}

/// Orchestrates meal writing with the reliability guarantees: gated by the toggle
/// AND write authorization, idempotent by meal id, and durable across failure via
/// the pending queue. Pure given its injected seams, so the whole policy is tested
/// with fakes. Main-actor because it touches the (SwiftData-backed) written store.
@MainActor
struct MealHealthWriter {
    let writer: any MealWriting
    let pending: any PendingMealStoring
    /// The "Write meals to Apple Health" toggle. Off ⇒ nothing is written and
    /// nothing is enqueued (the vault-side log is unaffected).
    let isEnabled: @MainActor () -> Bool

    /// Write the meals from a completed turn. When the feature is off or write
    /// access is denied, this is a no-op. Otherwise each meal is deduped against
    /// `written`; a new meal is written and, on success, recorded; on failure it is
    /// enqueued for a later drain. Never throws — a HealthKit failure only defers
    /// the write, never disturbs the reply.
    func process(_ meals: [Meal], written: any WrittenMealStoring) async {
        guard isEnabled(), await writer.isAuthorizedToWrite() else { return }
        await writeEach(meals, written: written)
    }

    /// Retry the pending queue (foreground / next turn). Same dedupe + record /
    /// re-enqueue discipline. If the feature is off or denied when draining, the
    /// dequeued meals are put back untouched so nothing is lost.
    func drainPending(written: any WrittenMealStoring) async {
        let queued = pending.dequeueAll()
        guard !queued.isEmpty else { return }
        guard isEnabled(), await writer.isAuthorizedToWrite() else {
            pending.enqueue(queued)
            return
        }
        await writeEach(queued, written: written)
    }

    /// Shared core: for each not-yet-written meal, write it; record the successes
    /// and enqueue the failures. Marking-written happens after the awaited writes so
    /// the main-actor store mutation is a single synchronous pass.
    private func writeEach(_ meals: [Meal], written: any WrittenMealStoring) async {
        var succeeded: [String] = []
        var failed: [Meal] = []
        for meal in meals {
            if written.isWritten(meal.id) { continue }
            if await writer.write(meal) { succeeded.append(meal.id) } else { failed.append(meal) }
        }
        for id in succeeded { written.markWritten(id) }
        pending.enqueue(failed)
    }
}

/// The persisted "write meals to Apple Health" toggle. Backed by `UserDefaults` (a
/// non-secret preference), defaulting OFF until the user grants write access once,
/// then flipped on — mirroring `HealthContextSettings` for the read side. The
/// coordinator reads `isEnabled` when a turn logs a meal; the Settings `@AppStorage`
/// binds the same key.
nonisolated enum WriteMealsToHealthSettings {
    static let enabledKey = "writeMealsToHealth"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) { defaults.set(on, forKey: enabledKey) }
}
