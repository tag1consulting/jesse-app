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

    func isWritten(_ id: String) -> Bool {
        var descriptor = FetchDescriptor<WrittenMeal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func markWritten(_ id: String) {
        guard !isWritten(id) else { return }
        context.insert(WrittenMeal(id: id))
        // Best-effort persist — a failed save just means the id isn't durable this
        // session; the meal was already written to Health, and `.unique` prevents a
        // duplicate WrittenMeal row if the same id is inserted again.
        try? context.save()
    }
}
