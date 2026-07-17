import Foundation
import SwiftData

/// SwiftData-backed idempotency store for written meal ids (the production
/// `WrittenMealStoring`). Wraps the per-call `ModelContext` the coordinator already
/// holds — the shared app container — so a recorded id survives relaunch. Confined
/// here so the pure orchestration (`MealHealthWriter`) never depends on SwiftData:
/// a test injects an in-memory set instead.
@MainActor
struct SwiftDataWrittenMealStore: WrittenMealStoring {
    let context: ModelContext

    private func fetch(_ id: String) -> WrittenMeal? {
        var descriptor = FetchDescriptor<WrittenMeal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func record(for id: String) -> WrittenMealRecord? {
        guard let row = fetch(id) else { return nil }
        return WrittenMealRecord(contentHash: row.contentHash, tombstoned: row.tombstoned)
    }

    func recordWritten(id: String, contentHash: String) {
        if let row = fetch(id) {
            row.contentHash = contentHash
            row.tombstoned = false
            row.writtenAt = Date()
        } else {
            context.insert(WrittenMeal(id: id, contentHash: contentHash))
        }
        // Best-effort persist — a failed save just means the record isn't durable this
        // session; the meal was already written to Health, and the id+hash idempotency
        // recovers on the next sight.
        try? context.save()
    }

    func recordTombstoned(id: String) {
        if let row = fetch(id) {
            row.tombstoned = true
            row.writtenAt = Date()
        } else {
            // A retract of an id we never wrote still records a tombstone, so a later
            // stale insert of the same content is ignored.
            context.insert(WrittenMeal(id: id, tombstoned: true))
        }
        try? context.save()
    }
}
