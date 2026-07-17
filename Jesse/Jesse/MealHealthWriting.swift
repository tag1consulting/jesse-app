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

    /// Delete the food correlation the app wrote for `id` (matched by the meal id it
    /// stored as the external-identifier metadata) **and its contained quantity samples**
    /// (correlation deletion does not cascade). `true` on success OR when nothing matched
    /// (idempotent — a retract of an already-deleted id is done); `false` on a real,
    /// retryable failure. Only ever touches samples the app itself wrote — never another
    /// source's data. A rewrite (a changed upsert) is a `delete` followed by a `write`.
    func delete(id: String) async -> Bool

    /// The write posture. `false` only when the user has **explicitly denied** write
    /// access (write status is queryable, unlike read) — the feature then disables
    /// quietly and nothing is enqueued. `true` when authorized or not-yet-determined.
    func isAuthorizedToWrite() async -> Bool
}

/// A stored record for a seen meal id: its `Meal.contentHash` at last write, and whether
/// it is tombstoned (the source retracted it). Nil from the store means "never seen".
struct WrittenMealRecord: Equatable, Sendable {
    let contentHash: String
    let tombstoned: Bool
}

/// The idempotency + correction store: what the app has written to Apple Health per meal
/// id, so a re-poll / Re-check / re-opened thread / watch relay of the same reply never
/// double-writes, a *changed* meal is rewritten exactly once (hash differs), and a
/// retracted meal is tombstoned. Main-actor because the production conformer is
/// SwiftData-backed; tests inject an in-memory dictionary.
@MainActor protocol WrittenMealStoring {
    /// The record for an id, or nil if it has never been seen.
    func record(for id: String) -> WrittenMealRecord?
    /// Record that `id` now holds `contentHash` in Health (an insert or a rewrite). Clears
    /// any tombstone — a re-logged meal is live again.
    func recordWritten(id: String, contentHash: String)
    /// Mark `id` tombstoned (its Health entry was deleted on retract). Idempotent.
    func recordTombstoned(id: String)
}

/// A batch of meal events whose Health apply failed and must be retried on the next
/// foreground / next turn: unapplied upserts AND unapplied retracts. `Codable` so it
/// persists across a relaunch (the durability half of at-least-once, alongside the
/// bridge's queue redelivery for anything that still carries a `corrections_seq`).
nonisolated struct PendingMealBatch: Codable, Equatable, Sendable {
    var upserts: [Meal]
    var retracts: [String]
    var isEmpty: Bool { upserts.isEmpty && retracts.isEmpty }
    static let empty = PendingMealBatch(upserts: [], retracts: [])
}

/// The persisted queue of meal events whose Health apply failed, drained on the next
/// foreground / next turn. UserDefaults-backed, only ever used from the main actor.
protocol PendingMealStoring {
    func enqueue(_ batch: PendingMealBatch)
    func dequeueAll() -> PendingMealBatch
}

/// UserDefaults-backed pending-apply queue. Small and best-effort: a failed apply is
/// held here and retried later, deduped (upserts by id, retracts by value) so a
/// repeatedly-failing item never grows the store unbounded. Migrates the pre-v2 `[Meal]`
/// queue (`…v1`) into `upserts` once. Backing `UserDefaults` is injectable so a test uses
/// its own suite instead of `.standard`.
nonisolated struct PendingMealStore: PendingMealStoring {
    private static let key = "jesse.pendingMealWrites.v2"
    private static let legacyKey = "jesse.pendingMealWrites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func enqueue(_ batch: PendingMealBatch) {
        guard !batch.isEmpty else { return }
        var all = load()
        for m in batch.upserts where !all.upserts.contains(where: { $0.id == m.id }) {
            all.upserts.append(m)
        }
        for r in batch.retracts where !all.retracts.contains(r) { all.retracts.append(r) }
        save(all)
    }

    func dequeueAll() -> PendingMealBatch {
        let all = load()
        if !all.isEmpty {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.legacyKey)
        }
        return all
    }

    private func load() -> PendingMealBatch {
        var batch = PendingMealBatch.empty
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PendingMealBatch.self, from: data) {
            batch = decoded
        }
        // Migrate any pre-v2 `[Meal]` queue (phase 3) into upserts, once.
        if let legacy = defaults.data(forKey: Self.legacyKey),
           let meals = try? JSONDecoder().decode([Meal].self, from: legacy) {
            for m in meals where !batch.upserts.contains(where: { $0.id == m.id }) {
                batch.upserts.append(m)
            }
        }
        return batch
    }

    private func save(_ batch: PendingMealBatch) {
        if let data = try? JSONEncoder().encode(batch) { defaults.set(data, forKey: Self.key) }
    }
}

/// The persisted meal-corrections ack high-water: the highest `corrections_seq` the app
/// has taken responsibility for. Monotonic — it only ever advances. Read by `JesseClient`
/// at send time (attached as `meal_corrections_ack`), advanced by `MealHealthWriter` once
/// a delivered batch is fully applied (or skipped because the mirror is off). Re-sending
/// the same value every turn is harmless (the bridge's prune is idempotent).
nonisolated enum MealCorrectionsAckStore {
    static let key = "jesse.mealCorrectionsAckSeq"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static var pendingSeq: Int? {
        let v = defaults.integer(forKey: key)
        return v > 0 ? v : nil
    }
    /// Advance the high-water to at least `seq` (never regresses).
    static func recordApplied(seq: Int) {
        guard seq > defaults.integer(forKey: key) else { return }
        defaults.set(seq, forKey: key)
    }
}

/// Orchestrates meal apply with the reliability guarantees: gated by the toggle AND write
/// authorization, idempotent + correction-aware by meal id + content hash, durable across
/// failure via the pending queue, and it advances the corrections ack only when a delivered
/// batch is FULLY applied. Pure given its injected seams, so the whole policy is tested with
/// fakes. Main-actor because it touches the (SwiftData-backed) written store.
@MainActor
struct MealHealthWriter {
    let writer: any MealWriting
    let pending: any PendingMealStoring
    /// The "Write meals to Apple Health" toggle. Off ⇒ nothing is written; the delivery is
    /// still acked (Health is a mirror only while on), so the bridge stops redelivering.
    let isEnabled: @MainActor () -> Bool
    /// Advance the corrections ack high-water once a delivered batch is fully applied (or
    /// skipped because the mirror is off). Withheld on a HealthKit failure. Defaults to the
    /// persisted store; a test injects a capture.
    let recordAck: @MainActor (Int) -> Void

    init(writer: any MealWriting,
         pending: any PendingMealStoring,
         isEnabled: @escaping @MainActor () -> Bool,
         recordAck: @escaping @MainActor (Int) -> Void = { MealCorrectionsAckStore.recordApplied(seq: $0) }) {
        self.writer = writer
        self.pending = pending
        self.isEnabled = isEnabled
        self.recordAck = recordAck
    }

    /// Apply a delivered v2 batch: **upserts first, then retracts** (contract order),
    /// transactional per batch. When the mirror is off (toggle off or write DENIED) nothing
    /// is written but the delivery IS acked, so the bridge prunes it (a mirror only while
    /// on). On a HealthKit failure the unapplied remainder is enqueued and the ack is
    /// **withheld**, so the bridge redelivers; app-side idempotency makes redelivery
    /// harmless. On full success the ack advances to the batch's `correctionsSeq`. Never
    /// throws — a HealthKit failure only defers, never disturbs the reply.
    func apply(_ batch: MealBatch, written: any WrittenMealStoring) async {
        guard !batch.isEmpty else { return }
        // Split the guard: `await` cannot appear inside `&&`'s short-circuit autoclosure.
        let canWrite: Bool
        if isEnabled() { canWrite = await writer.isAuthorizedToWrite() } else { canWrite = false }
        guard canWrite else {
            // Mirror off: ack (prune the bridge queue) but touch nothing in Health.
            if let seq = batch.correctionsSeq { recordAck(seq) }
            return
        }
        let remainder = await applyItems(upserts: batch.upserts, retracts: batch.retracts,
                                         written: written)
        if remainder.isEmpty {
            if let seq = batch.correctionsSeq { recordAck(seq) }
        } else {
            pending.enqueue(remainder) // withhold the ack → the bridge redelivers
        }
    }

    /// Retry the pending queue (foreground / next turn). Same per-item discipline; no ack is
    /// advanced (pending items carry no seq — the bridge redelivers anything that does). If
    /// the mirror is off, the dequeued batch is put back untouched so nothing is lost.
    func drainPending(written: any WrittenMealStoring) async {
        let queued = pending.dequeueAll()
        guard !queued.isEmpty else { return }
        // Split the guard: `await` cannot appear inside `&&`'s short-circuit autoclosure.
        let canWrite: Bool
        if isEnabled() { canWrite = await writer.isAuthorizedToWrite() } else { canWrite = false }
        guard canWrite else {
            pending.enqueue(queued)
            return
        }
        let remainder = await applyItems(upserts: queued.upserts, retracts: queued.retracts,
                                         written: written)
        if !remainder.isEmpty { pending.enqueue(remainder) }
    }

    /// Apply upserts then retracts; attempt every item (each independent + idempotent) and
    /// return the UNAPPLIED remainder (empty on full success). A transient failure on one
    /// item never blocks a later one; the whole remainder is enqueued and the ack withheld.
    private func applyItems(upserts: [Meal], retracts: [String],
                            written: any WrittenMealStoring) async -> PendingMealBatch {
        var failedUpserts: [Meal] = []
        var failedRetracts: [String] = []
        for meal in upserts {
            if await applyUpsert(meal, written: written) == false { failedUpserts.append(meal) }
        }
        for id in retracts {
            if await applyRetract(id, written: written) == false { failedRetracts.append(id) }
        }
        return PendingMealBatch(upserts: failedUpserts, retracts: failedRetracts)
    }

    /// Apply one upsert. Returns true if applied or a no-op skip; false on a retryable
    /// HealthKit failure. Cases: unseen id → insert; live id same hash → skip; live id
    /// changed hash → rewrite (delete + write, one Health entry); tombstoned id same hash →
    /// ignore (stale replay); tombstoned id changed hash → re-log (write, clears tombstone).
    private func applyUpsert(_ meal: Meal, written: any WrittenMealStoring) async -> Bool {
        let hash = meal.contentHash
        guard let rec = written.record(for: meal.id) else {
            // Unseen → insert.
            guard await writer.write(meal) else { return false }
            written.recordWritten(id: meal.id, contentHash: hash)
            return true
        }
        if rec.tombstoned {
            // Same content that was retracted → stale replay, ignore. Different → re-log.
            if rec.contentHash == hash { return true }
            guard await writer.write(meal) else { return false }
            written.recordWritten(id: meal.id, contentHash: hash)
            return true
        }
        // Live id: identical content → idempotent skip; changed → delete-then-rewrite.
        if rec.contentHash == hash { return true }
        guard await writer.delete(id: meal.id) else { return false }
        guard await writer.write(meal) else { return false }
        written.recordWritten(id: meal.id, contentHash: hash)
        return true
    }

    /// Apply one retract: delete the app's Health entry for `id` and tombstone it. A
    /// retract of an already-tombstoned id is a no-op (its entry is gone). A retract of an
    /// unknown id still tombstones (so a later stale insert of that content is ignored) —
    /// the delete is idempotent (a no-match is success). Returns false on a retryable
    /// HealthKit failure.
    private func applyRetract(_ id: String, written: any WrittenMealStoring) async -> Bool {
        if let rec = written.record(for: id), rec.tombstoned { return true }
        guard await writer.delete(id: id) else { return false }
        written.recordTombstoned(id: id)
        return true
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
