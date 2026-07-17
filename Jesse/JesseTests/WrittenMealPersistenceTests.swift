import XCTest
import SwiftData
@testable import Jesse

/// Covers the `WrittenMeal` idempotency + correction store: it round-trips through a real
/// store, `SwiftDataWrittenMealStore` records content hashes + tombstones and dedupes ids,
/// and — the migration guards — a store written before the entity existed, and a row
/// written before the `contentHash`/`tombstoned` fields existed, both reopen under the new
/// schema without crashing or losing data (the additive, lightweight-migration change). A
/// migrated row reads as hash-unknown (empty hash), which triggers exactly one rewrite on
/// next sight.
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

    private let schema = Schema([JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self])

    func testStoreRecordsHashTombstoneAndDedupes() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let store = SwiftDataWrittenMealStore(context: ctx)

        XCTAssertNil(store.record(for: "2026-07-04-lunch"), "unseen id has no record")
        store.recordWritten(id: "2026-07-04-lunch", contentHash: "h1")
        XCTAssertEqual(store.record(for: "2026-07-04-lunch"),
                       WrittenMealRecord(contentHash: "h1", tombstoned: false))
        // A rewrite updates the hash in place — still exactly one row.
        store.recordWritten(id: "2026-07-04-lunch", contentHash: "h2")
        XCTAssertEqual(store.record(for: "2026-07-04-lunch")?.contentHash, "h2")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 1)
        // Tombstone flips the flag, keeps the row.
        store.recordTombstoned(id: "2026-07-04-lunch")
        XCTAssertEqual(store.record(for: "2026-07-04-lunch")?.tombstoned, true)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 1)
        // A later write clears the tombstone (revival).
        store.recordWritten(id: "2026-07-04-lunch", contentHash: "h3")
        XCTAssertEqual(store.record(for: "2026-07-04-lunch")?.tombstoned, false)
    }

    func testRecordSurvivesContainerReopen() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            SwiftDataWrittenMealStore(context: ModelContext(container))
                .recordWritten(id: "2026-07-04-dinner", contentHash: "abc")
        }
        // Reopen (the "relaunch"): the record + its hash are still present.
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let rec = SwiftDataWrittenMealStore(context: ModelContext(container)).record(for: "2026-07-04-dinner")
        XCTAssertEqual(rec?.contentHash, "abc")
        XCTAssertEqual(rec?.tombstoned, false)
    }

    func testPreWrittenMealStoreSurvivesTheAdditiveMigration() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        // "Before": threads + turns via the pre-WrittenMeal model list.
        let oldSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self])
        do {
            let container = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            for i in 0..<3 {
                let thread = JesseThread(title: "t\(i)", mode: .ask)
                ctx.insert(thread)
                thread.turns.append(Turn(role: .user, text: "u\(i)"))
            }
            try ctx.save()
        }

        // "After": reopen with WrittenMeal added — existing rows survive, new entity empty.
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JesseThread>()), 3,
                       "existing threads survive the additive migration")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Turn>()), 3, "existing turns survive")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 0,
                       "the new WrittenMeal entity starts empty")
    }

    func testMigratedRowReadsAsHashUnknownAndUnTombstoned() throws {
        // A row written the pre-v2 way (id only) carries the DEFAULTED new fields — exactly
        // what SwiftData's lightweight migration produces for a pre-existing row. It reads as
        // hash-unknown (""), so on the next sight of the id the hashes differ → one rewrite.
        let url = tempStoreURL()
        defer { removeStore(url) }
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            ctx.insert(WrittenMeal(id: "2026-07-04-legacy")) // no hash / tombstone specified
            try ctx.save()
        }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let rec = SwiftDataWrittenMealStore(context: ModelContext(container)).record(for: "2026-07-04-legacy")
        XCTAssertEqual(rec?.contentHash, "", "a migrated row is hash-unknown")
        XCTAssertEqual(rec?.tombstoned, false)
    }

    func testTombstoneSurvivesReopen() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let store = SwiftDataWrittenMealStore(context: ModelContext(container))
            store.recordWritten(id: "x", contentHash: "h")
            store.recordTombstoned(id: "x")
        }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        XCTAssertEqual(SwiftDataWrittenMealStore(context: ModelContext(container)).record(for: "x")?.tombstoned, true)
    }
}
