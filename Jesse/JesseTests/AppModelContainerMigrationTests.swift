import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// The store-open path that actually matters and had a dangerous coverage gap:
/// opening a **populated on-disk** store under the current schema with automatic
/// lightweight migration, and what happens when that open **fails**.
///
/// Three guarantees, each failing-first:
///
///  1. `testPopulatedOnDiskStoreSurvivesOpenUnderVersionedSchema` writes a store the
///     way the app opened it *before* the outbox entities existed (a bare model list),
///     populates it with threads/turns/attachments/favorites in their full current
///     shape, then reopens it through `AppModelContainer.load` and asserts **every
///     field survives**: favorites still favorited, `aiTitle`/`titleSourceKey`/
///     `origin`/`lastDeliveredJobId` intact, a Turn's `provenanceJSON` intact, and
///     each attachment's thumbnail bytes present. It also covers the archive fields:
///     `isArchived`/`archivedAt` read their defaults on rows written before those
///     columns existed, and an archive flip round-trips through a reopen. A naive
///     migration that dropped an entity (e.g. `TurnAttachment` missing from the model
///     list) fails this test.
///
///  1b. `testStampedStoreSurvivesAddingAnAttributeToAnExistingEntity` is the
///     regression for the shipped break: it writes a store STAMPED with a prior
///     `VersionedSchema` whose `JesseThread` lacks an attribute, then opens it under a
///     schema that adds that attribute, and asserts the open succeeds (rows intact,
///     new column defaulted). Under a staged `migrationPlan` this throws "Cannot use
///     staged migration with an unknown model version" (exactly the device failure).
///     Automatic lightweight migration makes it pass.
///
///  2. `testFailedOpenIsFlaggedAndLeavesTheOnDiskFileIntact` corrupts the on-disk
///     file and asserts the loader does NOT silently swallow the failure into an
///     empty store: `openFailure` is non-nil, the returned container is a usable
///     in-memory fallback, and the on-disk bytes are left exactly as they were
///     (never overwritten or deleted). Reintroducing the old `try?`-to-in-memory
///     swallow (which returned `openFailure == nil`) fails this test.
@MainActor
final class AppModelContainerMigrationTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // The bare model list the app opened the store with BEFORE the versioned schema —
    // i.e. a store written with no `VersionedSchema` and no migration plan.
    private let legacyBareSchema = Schema([JesseThread.self, Turn.self, TurnAttachment.self, WrittenMeal.self])

    func testPopulatedOnDiskStoreSurvivesOpenUnderVersionedSchema() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        let favThreadId = UUID()
        let favoritedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let thumbBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) // a few JPEG-ish bytes

        // ── "Before": populate an on-disk store opened the legacy (bare, unplanned) way.
        do {
            let container = try ModelContainer(
                for: legacyBareSchema, configurations: ModelConfiguration(schema: legacyBareSchema, url: url))
            let ctx = ModelContext(container)

            let fav = JesseThread(title: "Starred chat", mode: .tell)
            fav.id = favThreadId
            fav.setFavorite(true, now: favoritedAt)
            fav.aiTitle = "AI-minted title"
            fav.titleSourceKey = "content-key-1"
            fav.origin = ThreadOrigin.watch.rawValue
            fav.lastDeliveredJobId = "job-777"
            ctx.insert(fav)

            let userTurn = Turn(role: .user, text: "with a photo")
            let jesseTurn = Turn(role: .jesse, text: "here is the reply")
            jesseTurn.provenanceJSON = #"{"model":"opus","badges":["v2"]}"#
            fav.turns.append(userTurn)
            fav.turns.append(jesseTurn)

            userTurn.attachments.append(
                TurnAttachment(filename: "Photo 1.jpg", mime: "image/jpeg", thumbnail: thumbBytes))

            // A second, plain thread so the favorites predicate has something to exclude.
            let plain = JesseThread(title: "Plain chat", mode: .ask)
            ctx.insert(plain)
            plain.turns.append(Turn(role: .user, text: "no star"))

            // And a WrittenMeal row, to prove that entity survives too.
            ctx.insert(WrittenMeal(id: "2026-07-04-lunch", contentHash: "h1"))

            try ctx.save()
        }

        // ── "After": reopen through the REAL app path — versioned schema + migration plan.
        let store = AppModelContainer.load(url: url)
        XCTAssertNil(store.openFailure, "a healthy populated store opens without falling back")
        XCTAssertFalse(store.isFallback)
        let ctx = ModelContext(store.container)

        // Counts: nothing was dropped or rebuilt.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JesseThread>()), 2, "both threads survive")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Turn>()), 3, "all turns survive")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TurnAttachment>()), 1, "the attachment survives")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WrittenMeal>()), 1, "the WrittenMeal row survives")

        // Favorites survived AS favorites (a field a naive migration would silently drop).
        let favorites = try ctx.fetch(FetchDescriptor<JesseThread>(
            predicate: #Predicate { $0.isFavorite }))
        XCTAssertEqual(favorites.count, 1, "exactly one thread is still favorited")
        let fav = try XCTUnwrap(favorites.first)
        XCTAssertEqual(fav.id, favThreadId)
        XCTAssertEqual(fav.favoritedAt, favoritedAt, "favoritedAt is preserved")
        XCTAssertEqual(fav.aiTitle, "AI-minted title")
        XCTAssertEqual(fav.titleSourceKey, "content-key-1")
        XCTAssertEqual(fav.originValue, .watch, "origin is preserved")
        XCTAssertEqual(fav.lastDeliveredJobId, "job-777")

        // The archive fields are an additive-property lightweight migration: a store
        // written before those columns existed opens with `isArchived` reading its
        // `false` default and `archivedAt` nil, on EVERY row (nothing rebuilt).
        for thread in try ctx.fetch(FetchDescriptor<JesseThread>()) {
            XCTAssertFalse(thread.isArchived, "isArchived defaults to false on a pre-archive row")
            XCTAssertNil(thread.archivedAt, "archivedAt defaults to nil on a pre-archive row")
        }

        // The relationship + a Turn's provenance + the attachment's bytes all survive.
        XCTAssertEqual(fav.orderedTurns.count, 2)
        let jesseTurn = try XCTUnwrap(fav.orderedTurns.first { $0.roleValue == .jesse })
        XCTAssertEqual(jesseTurn.provenanceJSON, #"{"model":"opus","badges":["v2"]}"#)
        let userTurn = try XCTUnwrap(fav.orderedTurns.first { $0.roleValue == .user })
        XCTAssertEqual(userTurn.orderedAttachments.count, 1)
        let attachment = try XCTUnwrap(userTurn.orderedAttachments.first)
        XCTAssertEqual(attachment.filename, "Photo 1.jpg")
        XCTAssertEqual(attachment.mime, "image/jpeg")
        XCTAssertEqual(attachment.thumbnail, thumbBytes, "the thumbnail bytes survive the open")

        // The V2 outbox entities exist under the migrated schema and are usable: a
        // V1-populated store (which had no OutboxItem/OutboxAttachment table) opens
        // under V2 with the two new entities added and empty, and a fresh insert +
        // round-trip of the ORIGINAL attachment bytes works.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<OutboxItem>()), 0,
                       "a V1 store migrates to V2 with an empty outbox")
        let originalBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x11, 0x22, 0x33]) // PNG-ish
        let outbox = OutboxItem(threadID: favThreadId, turnID: userTurn.id,
                                text: "with a photo", mode: .tell, voice: false)
        outbox.attachments.append(
            OutboxAttachment(filename: "Photo 1.jpg", mime: "image/jpeg", data: originalBytes))
        ctx.insert(outbox)
        // Archive the favorite in this same save so the archive flip round-trips
        // through the reopen below (proving the additive field persists, not just
        // defaults).
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        fav.setArchived(true, now: archivedAt)
        try ctx.save()
        let reopened = AppModelContainer.load(url: url)
        let ctx2 = ModelContext(reopened.container)
        let items = try ctx2.fetch(FetchDescriptor<OutboxItem>())
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.state, .sending)
        XCTAssertEqual(item.threadID, favThreadId)

        // The archived flag + timestamp survived the reopen on exactly the one thread.
        let archived = try ctx2.fetch(
            FetchDescriptor<JesseThread>(predicate: #Predicate { $0.isArchived }))
        XCTAssertEqual(archived.map(\.id), [favThreadId], "the archived flag persists")
        XCTAssertEqual(archived.first?.archivedAt, archivedAt, "archivedAt persists")
        XCTAssertEqual(item.orderedAttachments.first?.data, originalBytes,
                       "the ORIGINAL full-resolution bytes round-trip through OutboxAttachment")
    }

    /// The regression for the shipped store-open break. A store STAMPED with a prior
    /// `VersionedSchema` (whose `JesseThread` has no archive fields, the way a shipped
    /// build stamped it) must still open after `JesseThread` gains `isArchived`/
    /// `archivedAt`. Under a staged `SchemaMigrationPlan` this throws Code 134504
    /// "Cannot use staged migration with an unknown model version", the exact device
    /// symptom (the red "Couldn't open your saved conversations" banner). Automatic
    /// lightweight migration (what `AppModelContainer.load` now uses) opens it and
    /// defaults the new column. Reintroducing a staged plan for an additive change
    /// fails this test.
    func testStampedStoreSurvivesAddingAnAttributeToAnExistingEntity() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let threadId = UUID()

        // "Before": write a store STAMPED with the legacy versioned schema (its
        // JesseThread predates the archive fields), exactly as a shipped build did.
        do {
            let schema = Schema(versionedSchema: LegacyStampedSchema.self)
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let ctx = ModelContext(container)
            let t = LegacyStampedSchema.JesseThread()
            t.id = threadId
            t.title = "pre-archive thread"
            t.isFavorite = true
            t.origin = ThreadOrigin.watch.rawValue
            ctx.insert(t)
            try ctx.save()
        }

        // "After": open under the CURRENT schema (JesseThread now has the archive
        // columns) through the real app path. Must open, not fall back.
        let store = AppModelContainer.load(url: url)
        XCTAssertNil(store.openFailure,
                     "a stamped store must open after an attribute is added to an existing entity")
        XCTAssertFalse(store.isFallback)
        let ctx = ModelContext(store.container)

        let threads = try ctx.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1, "the pre-archive row survives")
        let t = try XCTUnwrap(threads.first)
        XCTAssertEqual(t.id, threadId)
        XCTAssertTrue(t.isFavorite, "favorite survives the open")
        XCTAssertEqual(t.originValue, .watch, "origin survives the open")
        XCTAssertFalse(t.isArchived, "the added isArchived column defaults to false")
        XCTAssertNil(t.archivedAt, "the added archivedAt column defaults to nil")
    }

    func testFailedOpenIsFlaggedAndLeavesTheOnDiskFileIntact() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }

        // A file that exists at the store path but is NOT a valid store → the open throws.
        let garbage = Data("this is not a sqlite database".utf8)
        try garbage.write(to: url)

        let store = AppModelContainer.load(url: url)

        // The failure is surfaced, not swallowed into a silent empty store.
        XCTAssertNotNil(store.openFailure, "a failed on-disk open must be flagged, never silent")
        XCTAssertTrue(store.isFallback)

        // The fallback container is still usable this session (app doesn't crash-loop).
        let ctx = ModelContext(store.container)
        ctx.insert(JesseThread(title: "in-memory session", mode: .ask))
        XCTAssertNoThrow(try ctx.save())
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JesseThread>()), 1)

        // The on-disk bytes are untouched — never overwritten or deleted, so the user's
        // real data stays recoverable on the next launch.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the on-disk file is preserved")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the on-disk file is left exactly as it was")
    }
}

/// A frozen copy of a PRIOR `JesseThread` shape (no archive fields), used ONLY to
/// write a store stamped with an older schema so `testStampedStoreSurvivesAddingAn
/// AttributeToAnExistingEntity` can prove the app opens it after the attribute is
/// added. Its nested class is named `JesseThread` so its SwiftData entity name matches
/// the live model (that is what makes the added-attribute migration line up). It holds
/// only the scalar fields that existed then (no relationships), so it needs no frozen
/// copy of `Turn`; the live schema adds the `turns` relationship and the other entities
/// as an additive (lightweight) change on open. This type is never used by the app.
private enum LegacyStampedSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] { [JesseThread.self] }

    @Model
    final class JesseThread {
        var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var mode: String = "ask"
        var sessionId: String?
        var isFavorite: Bool = false
        var favoritedAt: Date?
        var lastDeliveredJobId: String?
        var aiTitle: String?
        var titleSourceKey: String?
        var origin: String = "phone"

        init() {}
    }
}
