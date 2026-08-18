import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking

/// Covers the `TurnArtifact` schema change — files Jesse RETURNED, the other direction
/// from `TurnAttachment`.
///
/// Three properties, and the third is the one that has broken before: it round-trips
/// through a real store, it cascade-deletes with its `Turn` and its `JesseThread`, and a
/// store written under the PREVIOUS schema (V2, with no artifact entity at all) reopens
/// under the current one with every prior row intact — the lightweight migration the
/// schema header insists on.
@MainActor
final class TurnArtifactPersistenceTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-artifact-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The V2 entity set — the schema as it stood BEFORE `TurnArtifact` existed. Written
    /// here explicitly rather than referenced, so this test keeps describing "the old
    /// store" even after the live version list moves on again.
    private let previousSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self,
                                         WrittenMeal.self, OutboxItem.self, OutboxAttachment.self])

    // MARK: - Round trip

    func testArtifactPersistsAndReloadsAcrossContainerReopen() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        do {
            let container = try ModelContainer(for: jesseCurrentSchema,
                                               configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            let thread = JesseThread(title: "t", mode: .ask)
            ctx.insert(thread)
            let turn = Turn(role: .jesse, text: "here they are")
            thread.turns.append(turn)
            turn.artifacts.append(TurnArtifact(artifactID: "aa11", filename: "chart.png",
                                               mime: "image/png", byteCount: 2048,
                                               sha256: "ff00", sortIndex: 0))
            turn.artifacts.append(TurnArtifact(artifactID: "bb22", filename: "data.csv",
                                               mime: "text/csv", byteCount: 91,
                                               sha256: "11ee", sortIndex: 1))
            try ctx.save()
        }

        let container = try ModelContainer(for: jesseCurrentSchema,
                                           configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let threads = try ctx.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1)
        let arts = threads[0].orderedTurns[0].orderedArtifacts
        // ORDER is the reply's order, held by `sortIndex` — every row here was created in
        // the same save, so `createdAt` alone can tie.
        XCTAssertEqual(arts.map(\.filename), ["chart.png", "data.csv"])
        XCTAssertEqual(arts[0].artifactID, "aa11")
        XCTAssertEqual(arts[0].byteCount, 2048)
        XCTAssertEqual(arts[0].sha256, "ff00")
        XCTAssertTrue(arts[0].isInlineImage)
        XCTAssertFalse(arts[1].isInlineImage)
        XCTAssertFalse(arts[0].isExpired, "a fresh row is not expired")
    }

    /// `sortIndex` survives a shuffled relationship: SwiftData gives no ordering
    /// guarantee, which is exactly why the field exists.
    func testOrderedArtifactsUsesSortIndexNotInsertionOrder() throws {
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let turn = Turn(role: .jesse, text: "x")
        ctx.insert(turn)
        turn.artifacts.append(TurnArtifact(artifactID: "cc", filename: "third.png",
                                           mime: "image/png", byteCount: 1, sha256: "c",
                                           sortIndex: 2))
        turn.artifacts.append(TurnArtifact(artifactID: "aa", filename: "first.png",
                                           mime: "image/png", byteCount: 1, sha256: "a",
                                           sortIndex: 0))
        turn.artifacts.append(TurnArtifact(artifactID: "bb", filename: "second.png",
                                           mime: "image/png", byteCount: 1, sha256: "b",
                                           sortIndex: 1))
        try ctx.save()
        XCTAssertEqual(turn.orderedArtifacts.map(\.filename),
                       ["first.png", "second.png", "third.png"])
    }

    // MARK: - Cascade

    func testArtifactsCascadeDeleteWithTheirTurnAndThread() throws {
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        let thread = JesseThread(title: "t", mode: .ask)
        ctx.insert(thread)
        let turn = Turn(role: .jesse, text: "here")
        thread.turns.append(turn)
        turn.artifacts.append(TurnArtifact(artifactID: "aa", filename: "a.png",
                                           mime: "image/png", byteCount: 1, sha256: "a"))
        turn.artifacts.append(TurnArtifact(artifactID: "bb", filename: "b.pdf",
                                           mime: "application/pdf", byteCount: 2, sha256: "b"))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 2)

        // Deleting the TURN takes its artifacts.
        ctx.delete(turn)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 0,
                       "artifacts cascade with their turn")

        // …and so does deleting the whole THREAD, through the turn's own cascade.
        let turn2 = Turn(role: .jesse, text: "again")
        thread.turns.append(turn2)
        turn2.artifacts.append(TurnArtifact(artifactID: "cc", filename: "c.png",
                                            mime: "image/png", byteCount: 1, sha256: "c"))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 1)
        ctx.delete(thread)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 0,
                       "and with the whole thread")
    }

    // MARK: - The migration guard

    /// THE ONE THAT HAS BROKEN BEFORE. A store written under the PREVIOUS schema — no
    /// artifact entity, no relationship — must reopen under the current schema with every
    /// prior row intact and the new relationship simply empty. If this ever needs
    /// migration code, the change was not additive and the schema header's rules apply.
    func testAStoreWrittenBeforeArtifactsExistedReopensCleanly() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        do {
            let container = try ModelContainer(for: previousSchema,
                                               configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            let thread = JesseThread(title: "old thread", mode: .tell)
            thread.isFavorite = true
            ctx.insert(thread)
            let user = Turn(role: .user, text: "make me a chart")
            thread.turns.append(user)
            let reply = Turn(role: .jesse, text: "here you go")
            reply.provenanceJSON = #"{"route":"hosted"}"#
            thread.turns.append(reply)
            user.attachments.append(
                TurnAttachment(filename: "photo.jpg", mime: "image/jpeg", thumbnail: Data([0xFF])))
            try ctx.save()
        }

        let container = try ModelContainer(for: jesseCurrentSchema,
                                           configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let threads = try ctx.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1, "the old store still opens")
        XCTAssertEqual(threads[0].title, "old thread")
        XCTAssertTrue(threads[0].isFavorite, "every prior field survives")
        let turns = threads[0].orderedTurns
        XCTAssertEqual(turns.map(\.text), ["make me a chart", "here you go"])
        XCTAssertEqual(turns[1].provenanceJSON, #"{"route":"hosted"}"#)
        XCTAssertEqual(turns[0].orderedAttachments.map(\.filename), ["photo.jpg"],
                       "the OTHER direction's rows are untouched")
        XCTAssertTrue(turns[1].artifacts.isEmpty, "the new relationship reads empty")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 0)

        // And the migrated store accepts a new artifact, so the entity is really live.
        turns[1].artifacts.append(TurnArtifact(artifactID: "aa", filename: "late.png",
                                               mime: "image/png", byteCount: 3, sha256: "a"))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 1)
    }

    // MARK: - Delivery

    /// `TurnWriter` persists a delivered reply's artifacts as metadata rows, in the wire's
    /// order — and persists NOTHING for the overwhelming majority of turns.
    func testTurnWriterPersistsDeliveredArtifacts() throws {
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let thread = JesseThread(title: "t", mode: .ask)
        ctx.insert(thread)

        let reply = JesseReply(
            text: "here they are", sessionId: "s1",
            artifacts: [
                JesseArtifact(id: "aa11", filename: "chart.png", mime: "image/png",
                              bytes: 2048, sha256: "ff00"),
                JesseArtifact(id: "bb22", filename: "data.csv", mime: "text/csv",
                              bytes: 91, sha256: "11ee"),
            ])
        let outcome = TurnWriter().write(threadID: thread.id, thread: thread, reply: reply,
                                         jobId: "job-1", context: ctx)
        XCTAssertEqual(outcome, .delivered(saved: true))
        let arts = thread.orderedTurns.last!.orderedArtifacts
        XCTAssertEqual(arts.map(\.filename), ["chart.png", "data.csv"])
        XCTAssertEqual(arts.map(\.sortIndex), [0, 1], "the wire's order is preserved")
        XCTAssertEqual(arts[0].artifactID, "aa11")

        // A plain reply persists no rows at all.
        let plain = JesseReply(text: "just words", sessionId: "s1")
        _ = TurnWriter().write(threadID: thread.id, thread: thread, reply: plain,
                               jobId: "job-2", context: ctx)
        XCTAssertTrue(thread.orderedTurns.last!.artifacts.isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnArtifact>()), 2)
    }
}
