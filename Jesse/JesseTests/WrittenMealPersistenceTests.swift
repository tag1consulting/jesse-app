import XCTest
import SwiftData
@testable import Jesse

/// Covers the `WrittenMeal` idempotency store: it round-trips through a real store,
/// `SwiftDataWrittenMealStore` records + dedupes ids, and — the migration guard —
/// a store written before the entity existed reopens under the new schema without
/// crashing or losing data (the additive, lightweight-migration-compatible change).
@MainActor
final class WrittenMealPersistenceTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-meal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testWrittenMealStoreRecordsAndDedupes() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let container = try ModelContainer(
            for: Schema([JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self]),
            configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let store = SwiftDataWrittenMealStore(context: ctx)

        XCTAssertFalse(store.isWritten("2026-07-04-lunch"))
        store.markWritten("2026-07-04-lunch")
        XCTAssertTrue(store.isWritten("2026-07-04-lunch"))
        // A second mark of the same id is a no-op (unique) — exactly one row.
        store.markWritten("2026-07-04-lunch")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 1)
    }

    func testWrittenMealIdSurvivesContainerReopen() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let schema = Schema([JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self])
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            SwiftDataWrittenMealStore(context: ctx).markWritten("2026-07-04-dinner")
        }
        // Reopen (the "relaunch"): the recorded id is still present, so a re-check
        // of the same reply won't double-write.
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        XCTAssertTrue(SwiftDataWrittenMealStore(context: ctx).isWritten("2026-07-04-dinner"))
    }

    func testPreWrittenMealStoreSurvivesTheAdditiveMigration() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        // "Before": threads + turns via the pre-WrittenMeal model list.
        let oldSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self])
        do {
            let container = try ModelContainer(for: oldSchema,
                configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            for i in 0..<3 {
                let thread = JesseThread(title: "t\(i)", mode: .ask)
                ctx.insert(thread)
                thread.turns.append(Turn(role: .user, text: "u\(i)"))
            }
            try ctx.save()
        }

        // "After": reopen with WrittenMeal added — existing rows survive, and the
        // new entity starts empty.
        let newSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self])
        let container = try ModelContainer(for: newSchema,
            configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JesseThread>()), 3,
                       "existing threads survive the additive migration")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Turn>()), 3, "existing turns survive")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 0,
                       "the new WrittenMeal entity starts empty")
    }
}
