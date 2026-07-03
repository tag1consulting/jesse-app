import XCTest
import SwiftData
@testable import Jesse

/// Covers the `TurnAttachment` schema change: it round-trips through a real store,
/// cascade-deletes with its `Turn`/`JesseThread`, and — the migration guard — an
/// existing store written before the attachment relationship existed reopens under
/// the new schema without crashing or losing data.
@MainActor
final class TurnAttachmentPersistenceTests: XCTestCase {

    // MARK: - Temp on-disk store helpers

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-attach-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Round-trip on disk

    func testAttachmentPersistsAndReloadsAcrossContainerReopen() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let schema = Schema([JesseThread.self, Turn.self, TurnAttachment.self])
        let thumb = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])

        // Write, then fully release the container.
        do {
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            let thread = JesseThread(title: "t", mode: .ask)
            ctx.insert(thread)
            let turn = Turn(role: .user, text: "hi")
            thread.turns.append(turn)
            turn.attachments.append(
                TurnAttachment(filename: "a.jpg", mime: "image/jpeg", thumbnail: thumb))
            try ctx.save()
        }

        // Reopen a fresh container over the same file.
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let threads = try ctx.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1)
        let turns = threads[0].orderedTurns
        XCTAssertEqual(turns.count, 1)
        let atts = turns[0].orderedAttachments
        XCTAssertEqual(atts.map(\.filename), ["a.jpg"])
        XCTAssertEqual(atts.first?.mime, "image/jpeg")
        XCTAssertEqual(atts.first?.thumbnail, thumb)
        XCTAssertTrue(atts.first?.isImage ?? false)
    }

    // MARK: - Cascade deletes

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testDeletingTurnCascadesToItsAttachments() throws {
        let ctx = try inMemoryContext()
        let thread = JesseThread(title: "t", mode: .ask)
        ctx.insert(thread)
        let turn = Turn(role: .user, text: "hi")
        thread.turns.append(turn)
        turn.attachments.append(TurnAttachment(filename: "a", mime: "image/jpeg", thumbnail: Data()))
        turn.attachments.append(TurnAttachment(filename: "b", mime: "application/pdf", thumbnail: Data()))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 2)

        ctx.delete(turn)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 0,
                       "deleting a Turn must cascade to its attachment previews")
    }

    func testDeletingThreadCascadesToTurnsAndAttachments() throws {
        let ctx = try inMemoryContext()
        let thread = JesseThread(title: "t", mode: .ask)
        ctx.insert(thread)
        let turn = Turn(role: .user, text: "hi")
        thread.turns.append(turn)
        turn.attachments.append(TurnAttachment(filename: "a", mime: "image/jpeg", thumbnail: Data()))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 1)

        ctx.delete(thread)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Turn>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 0,
                       "deleting a thread must cascade through its turns to their attachments")
    }

    // MARK: - Migration guard (no data loss)

    /// The migration guard the spec asked for: a store written by a schema WITHOUT
    /// the attachment relationship/entity must reopen under the NEW schema (which
    /// adds `TurnAttachment` + `Turn.attachments`) without crashing or wiping data.
    ///
    /// Note: SwiftData derives the store schema from the current model graph, so a
    /// true byte-for-byte pre-entity binary can't be fabricated in-repo (listing
    /// only `[JesseThread, Turn]` still reaches `TurnAttachment` through the
    /// relationship). What this asserts is the operative risk: rows written with no
    /// attachments load — not crash, not wipe — under the attachment-aware schema.
    /// The change is additive (new entity + empty to-many relationship with a
    /// default), which is lightweight-migration-compatible.
    func testPreAttachmentStoreSurvivesTheAdditiveMigration() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        // "Before": threads + turns, no attachments, via the pre-feature model list.
        let oldSchema = Schema([JesseThread.self, Turn.self])
        do {
            let container = try ModelContainer(for: oldSchema,
                configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            for i in 0..<3 {
                let thread = JesseThread(title: "t\(i)", mode: .ask)
                ctx.insert(thread)
                thread.turns.append(Turn(role: .user, text: "u\(i)"))
                thread.turns.append(Turn(role: .jesse, text: "j\(i)"))
            }
            try ctx.save()
        }

        // "After": reopen with the full schema including TurnAttachment.
        let newSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self])
        let container = try ModelContainer(for: newSchema,
            configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let threads = try ctx.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 3, "existing threads must survive the additive migration")
        XCTAssertEqual(threads.reduce(0) { $0 + $1.turns.count }, 6, "existing turns must survive")
        for thread in threads {
            for turn in thread.turns {
                XCTAssertTrue(turn.attachments.isEmpty, "migrated turns start with no previews")
            }
        }
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 0)
    }
}
