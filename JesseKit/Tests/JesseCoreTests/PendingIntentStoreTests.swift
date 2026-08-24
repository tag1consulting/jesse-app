import XCTest
import SwiftData
@testable import JesseCore

// The offline capture queue's STORAGE half: the schema step that lets it exist at all,
// and the store that reads and writes it.
//
// The migration test is the load-bearing one. This app has already shipped a store-open
// break once — a staged `SchemaMigrationPlan` pinned each migration to a model checksum,
// and the first additive change after it stranded users behind the "couldn't open your
// conversations" banner (see the long note at the top of `JesseSchema.swift`). Adding an
// entity is exactly the shape of change that broke, so it is proved rather than assumed.

@MainActor
final class PendingIntentStoreTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-pending-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - The migration

    /// **A V3 store opens under V4 with everything intact and the new entity empty.**
    ///
    /// Written the way a shipped build stamped it — `Schema(versionedSchema:)` over the
    /// V3 model list, which has no `PendingIntent` — then reopened under the live schema.
    /// A staged plan would throw "unknown model version" here; automatic lightweight
    /// migration infers the addition and opens.
    func testAV3StoreOpensUnderV4WithItsRowsIntact() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let threadId = UUID()

        // "Before": a populated store that has never heard of the capture queue.
        do {
            let schema = Schema(versionedSchema: JesseSchemaV3.self)
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let thread = JesseThread(mode: .tell)
            thread.id = threadId
            thread.title = "pre-queue thread"
            thread.isFavorite = true
            context.insert(thread)
            context.insert(OutboxItem(threadID: threadId, turnID: UUID(), text: "held",
                                      mode: .tell, voice: false))
            try context.save()
        }

        // "After": the live schema, which adds `PendingIntent` and nothing else.
        let schema = jesseCurrentSchema
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)

        let threads = try context.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1, "the pre-queue row survives")
        XCTAssertEqual(threads.first?.id, threadId)
        XCTAssertEqual(threads.first?.isFavorite, true)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 1,
                       "and so does everything it was stored alongside")
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingIntent>()).isEmpty,
                      "the new entity opens empty rather than failing the open")
    }

    /// The live schema really is V4, and really does list the new entity — a check that
    /// costs nothing and catches the one-line mistake of adding a version enum and
    /// forgetting to point `jesseCurrentSchema` at it.
    func testTheLiveSchemaIsTheOneThatCarriesTheQueue() {
        XCTAssertTrue(JesseSchemaV4.models.contains { $0 == PendingIntent.self })
        XCTAssertFalse(JesseSchemaV3.models.contains { $0 == PendingIntent.self })
        let names = jesseCurrentSchema.entities.map(\.name)
        XCTAssertTrue(names.contains("PendingIntent"),
                      "jesseCurrentSchema must be derived from the version that has it")
    }

    // MARK: - The store

    private func makeStore(_ url: URL) throws -> PendingIntentStore {
        let schema = jesseCurrentSchema
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        return PendingIntentStore(context: ModelContext(container))
    }

    private func record(_ kind: PendingIntentKind = .check, id: UUID = UUID(),
                        at: Date = Date(timeIntervalSince1970: 1_772_521_500),
                        state: PendingIntentState = .queued) -> PendingIntentRecord {
        PendingIntentRecord(id: id, kind: kind, dayDate: "2026-03-03", itemId: "abc123",
                            leadText: "Reply to Ada.", sectionName: "Do Now",
                            payload: PendingIntentPayload(evidence: "sent it"),
                            createdAt: at, tz: "Europe/London", state: state)
    }

    /// A record round-trips through disk unchanged — including the payload, which is the
    /// one field that goes through a second encoding.
    func testARecordRoundTripsThroughTheStore() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        let original = record()

        store.append(original)

        let back = try XCTUnwrap(store.all().first)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.kind, .check)
        XCTAssertEqual(back.dayDate, "2026-03-03")
        XCTAssertEqual(back.itemId, "abc123")
        XCTAssertEqual(back.leadText, "Reply to Ada.")
        XCTAssertEqual(back.payload.evidence, "sent it")
        XCTAssertEqual(back.createdAt, original.createdAt)
        XCTAssertEqual(back.tz, "Europe/London")
        XCTAssertEqual(back.state, .queued)
        XCTAssertNil(store.lastSaveError)
    }

    /// **Appending the same id twice keeps one row.** This is what makes a redelivered
    /// watch intent land once: the queue is keyed by the WATCH's own `intentId`, and
    /// `transferUserInfo` redelivers across the relaunch that empties the in-memory
    /// de-duper on the other side.
    func testAppendingTheSameIdTwiceKeepsOneRow() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        let id = UUID()

        store.append(record(id: id))
        store.append(record(id: id))

        XCTAssertEqual(store.all().count, 1)
    }

    /// Order is creation order, and it is load-bearing: a day's meals must replay as they
    /// were eaten.
    func testRowsComeBackOldestFirst() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        let early = record(at: Date(timeIntervalSince1970: 1_000))
        let late = record(at: Date(timeIntervalSince1970: 2_000))

        store.append(late)
        store.append(early)

        XCTAssertEqual(store.all().map(\.id), [early.id, late.id])
    }

    /// `replayable` picks up a row left `replaying` by a kill mid-run. Nothing else ever
    /// would, and the bridge's `If-Match` and day guard make the second attempt safe.
    func testReplayableIncludesARowLeftMidReplay() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        store.append(record(at: Date(timeIntervalSince1970: 1_000), state: .queued))
        store.append(record(at: Date(timeIntervalSince1970: 2_000), state: .replaying))
        store.append(record(at: Date(timeIntervalSince1970: 3_000), state: .applied))
        store.append(record(at: Date(timeIntervalSince1970: 4_000), state: .refused))

        XCTAssertEqual(store.replayable().map(\.state), [.queued, .replaying])
        XCTAssertEqual(store.outstanding().map(\.state), [.queued, .replaying, .refused],
                       "an applied receipt wants no attention; a refusal does")
    }

    /// **Receipts expire; refusals do not.** A change the app took from the user and
    /// could not deliver must never disappear quietly.
    func testTheSweepDropsSpentReceiptsAndKeepsRefusals() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        let now = Date(timeIntervalSince1970: 1_772_600_000)
        let oldApplied = record(id: UUID(), at: now.addingTimeInterval(-48 * 3600),
                                state: .applied)
        let freshApplied = record(id: UUID(), at: now.addingTimeInterval(-60), state: .applied)
        let oldRefused = record(id: UUID(), at: now.addingTimeInterval(-48 * 3600),
                                state: .refused)
        store.append(oldApplied)
        store.append(freshApplied)
        store.append(oldRefused)

        store.prune(now: now)

        let left = Set(store.all().map(\.id))
        XCTAssertFalse(left.contains(oldApplied.id))
        XCTAssertTrue(left.contains(freshApplied.id), "a receipt from a minute ago is still news")
        XCTAssertTrue(left.contains(oldRefused.id))
    }

    /// An update overwrites in place, keyed by id — the shape the replayer needs to move
    /// a row from `queued` to `applied` without ever creating a second one.
    func testUpdateOverwritesInPlace() throws {
        let url = tempStoreURL()
        defer { removeStore(url) }
        let store = try makeStore(url)
        var row = record()
        store.append(row)

        row.state = .refused
        row.refusalReason = "Today moved on; item not found."
        row.attempts = 1
        store.update(row)

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.state, .refused)
        XCTAssertEqual(store.all().first?.refusalReason, "Today moved on; item not found.")
        XCTAssertEqual(store.all().first?.attempts, 1)
    }

    // MARK: - The value type

    /// The two stamps are deliberately different spellings, and each is what its consumer
    /// takes: an instant for the day-file writes, an offset-carrying RFC3339 for the diet
    /// pipeline's `(eaten at …)` stamp — which does not recognise a value with no offset.
    func testTheTwoStampsAreTheSpellingsTheirConsumersTake() {
        let row = PendingIntentRecord(kind: .quickLog, dayDate: "2026-03-03",
                                      createdAt: Date(timeIntervalSince1970: 1_772_521_500),
                                      tz: "Europe/Rome")
        XCTAssertEqual(row.createdAtStamp, "2026-03-03T08:05:00+01:00")
        XCTAssertEqual(row.createdAtInstant, "2026-03-03T07:05:00Z")
        XCTAssertEqual(row.createdAtClock, "08:05", "the wall clock the person read")
    }

    /// A zone this tz database has never heard of falls back to the device's own rather
    /// than to UTC: a stored row is still a row about a person, and the nearest true
    /// offset beats a confident wrong one.
    func testAnUnknownZoneFallsBackRatherThanClaimingUTC() {
        let row = PendingIntentRecord(kind: .quickLog, dayDate: "2026-03-03",
                                      createdAt: Date(timeIntervalSince1970: 1_772_521_500),
                                      tz: "Mars/Olympus_Mons")
        XCTAssertFalse(row.createdAtStamp.isEmpty)
        // Whatever this machine is, the stamp is rendered in ITS zone.
        let expected = ISO8601DateFormatter()
        expected.timeZone = TimeZone.current
        expected.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(row.createdAtStamp,
                       expected.string(from: Date(timeIntervalSince1970: 1_772_521_500)))
    }

    /// An undecodable payload reads as empty rather than losing the intent. Detail is
    /// worth less than the fact that something was captured.
    func testAnUndecodablePayloadDoesNotLoseTheIntent() {
        XCTAssertEqual(PendingIntentPayload.decode("not json"), PendingIntentPayload())
        XCTAssertEqual(PendingIntentPayload.decode(""), PendingIntentPayload())
    }

    /// A stored `kind` or `state` a newer build wrote reads as the safest interpretation
    /// rather than being dropped.
    func testAnUnknownStoredKindReadsAsTheSafestInterpretation() {
        let row = PendingIntent(record: record())
        row.kind = "somethingNewerShipped"
        row.state = "alsoNewer"
        XCTAssertEqual(row.record.kind, .check)
        XCTAssertEqual(row.record.state, .queued)
    }

    /// Process-updates is the one kind that is never captured, and the enum says so in a
    /// way the replayer can read rather than in a comment only.
    func testOnlyTheDayFileKindsClaimToBeDayFileWrites() {
        XCTAssertTrue(PendingIntentKind.check.isDayFileWrite)
        XCTAssertTrue(PendingIntentKind.defer.isDayFileWrite)
        XCTAssertTrue(PendingIntentKind.move.isDayFileWrite)
        XCTAssertFalse(PendingIntentKind.quickLog.isDayFileWrite)
        XCTAssertFalse(PendingIntentKind.startNewDay.isDayFileWrite)
        XCTAssertFalse(PendingIntentKind.processUpdates.isDayFileWrite)
    }
}
