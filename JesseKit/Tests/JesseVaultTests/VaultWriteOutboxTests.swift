import XCTest
@testable import JesseVault

// EVERY WRITE REACHES THE STUDIO, AND NOTHING IS LOST ON THE WAY.
//
// 2026-09-24: a tick of Family P1 was written into the phone's Obsidian folder and never
// reached the Studio, because Obsidian iOS does not sync a file another app changed. Only
// strand ticks were then reported to the bridge; an edit, a comment, any other checkbox
// and an offline capture were written and hoped. These pin the fix at its layer: every
// write is a record, queued before it is sent, sent in order, kept across a relaunch,
// removed only by an answer, and never dropped on a conflict.
final class VaultWriteOutboxTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = VaultFixture.makeDirectory()
    }

    override func tearDown() {
        VaultFixture.cleanUp(directory)
        super.tearDown()
    }

    private let note = "# Note\n\none\ntwo\n- [ ] a box\n"

    private func edit(_ path: String = "Projects/A.md", to new: String = "# Note\n\nuno\n")
        -> VaultWriteRecord {
        VaultWriteRecord.replacing(localPath: path, base: note,
                                   baseStamp: VaultFileStamp(text: note), new: new, kind: .edit)
    }

    private func tick(_ path: String = "Projects/B.md") -> VaultWriteRecord {
        VaultWriteRecord.replacing(localPath: path, base: note,
                                   baseStamp: VaultFileStamp(text: note),
                                   new: note.replacingOccurrences(of: "- [ ]", with: "- [x]"),
                                   kind: .tick)
    }

    private func capture() -> VaultWriteRecord {
        VaultWriteRecord.capture(localPath: "Inbox/2026-09-26-phone.md",
                                 entry: "- 09:00 (phone): a thought\n",
                                 prologue: "# Phone captures 2026-09-26\n\n")
    }

    private func ids(_ received: [[String: Any]]) -> [String] {
        received.compactMap { $0["id"] as? String }
    }

    // MARK: - Queued before sent

    func testAWriteIsQueuedBeforeAnythingIsSent() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        let record = edit()
        let seen = SeenAtSend()
        bridge.onSend = { [outbox] in await seen.set(await outbox.entries.map(\.id)) }
        await outbox.configure { bridge }

        try await outbox.enqueue(record)
        let waiting = await outbox.entries.map(\.id)
        XCTAssertEqual(waiting, [record.id], "queued, and nothing sent yet")
        XCTAssertEqual(bridge.sends, 0)

        await outbox.flush()
        let atSend = await seen.value
        XCTAssertEqual(atSend, [record.id], "the record was in the outbox when it was sent")
        let left = await outbox.entries
        XCTAssertEqual(left, [], "applied removes it")
        let delivered = await outbox.isDelivered(record.id)
        XCTAssertTrue(delivered)
    }

    func testOrderIsPreservedAcrossKinds() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        await outbox.configure { bridge }
        let records = [edit(), tick(), capture(), edit("Projects/C.md")]
        for record in records { try await outbox.enqueue(record) }
        await outbox.flush()
        XCTAssertEqual(ids(bridge.received), records.map { $0.id.uuidString.lowercased() })
        XCTAssertEqual(bridge.received.map { $0["kind"] as? String },
                       ["edit", "tick", "capture", "edit"])
        XCTAssertEqual(bridge.sends, 1, "one request, in order")
    }

    func testTheWireCarriesWhatTheBridgeNeedsAndNothingOfTheDevices() async throws {
        let body = try VaultWriteRecord.wireBody([tick(), edit(), capture()])
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(list[0]["line"] as? Int, 5)
        XCTAssertEqual(list[0]["text"] as? String, "- [ ] a box")
        XCTAssertEqual(list[0]["checked"] as? Bool, true)
        XCTAssertEqual(list[0]["base_sha256"] as? String, VaultFileStamp(text: note).digest)
        XCTAssertEqual(list[1]["base_text"] as? String, note)
        XCTAssertEqual(list[2]["prologue"] as? String, "# Phone captures 2026-09-26\n\n")
        XCTAssertNotNil(list[0]["made_at"] as? String)
        for item in list {
            XCTAssertNil(item["deviceText"])
            XCTAssertNil(item["strandTick"])
        }
    }

    func testARelaunchKeepsTheQueue() async throws {
        let bridge = FakeVaultBridge()
        bridge.reachable = false
        let first = scratchOutbox(directory)
        await first.configure { bridge }
        let records = [edit(), tick(), capture()]
        for record in records { try await first.enqueue(record) }
        await first.flush()
        let kept = await first.entries.map(\.id)
        XCTAssertEqual(kept, records.map(\.id), "unreachable: everything stays")

        let relaunched = scratchOutbox(directory)
        let reloaded = await relaunched.entries.map(\.id)
        XCTAssertEqual(reloaded, records.map(\.id))
        bridge.reachable = true
        await relaunched.configure { bridge }
        await relaunched.flush()
        XCTAssertEqual(ids(bridge.received), records.map { $0.id.uuidString.lowercased() })
        let left = await relaunched.entries
        XCTAssertEqual(left, [])
    }

    // MARK: - Answers

    func testAConflictIsKeptMarkedAndSurfaced() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.answer { record in
            ["id": record["id"] ?? "", "status": "conflict",
             "current_text": "the Studio's", "current_sha256": "abc"]
        }
        await outbox.configure { bridge }
        let record = edit()
        try await outbox.enqueue(record)
        await outbox.flush()

        let conflicts = await outbox.conflicts
        XCTAssertEqual(conflicts.map(\.id), [record.id])
        let forNote = await outbox.entries(forPath: "Projects/A.md")
        XCTAssertEqual(forNote.first?.studioVersion, "the Studio's")
        XCTAssertEqual(forNote.first?.record.deviceVersion, "# Note\n\nuno\n")

        // A conflicted record is not resent on its own.
        await outbox.flush()
        XCTAssertEqual(bridge.sends, 1)
    }

    func testKeepMineResendsTheSameIdWithForceOverTheStudiosHash() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.answer { record in
            (record["force"] as? Bool) == true
                ? ["id": record["id"] ?? "", "status": "applied", "sha256": "new"]
                : ["id": record["id"] ?? "", "status": "conflict",
                   "current_text": "the Studio's", "current_sha256": "abc"]
        }
        await outbox.configure { bridge }
        let editRecord = edit()
        let tickRecord = tick()
        try await outbox.enqueue(editRecord)
        try await outbox.enqueue(tickRecord)
        await outbox.flush()

        await outbox.keepMine(id: editRecord.id)
        await outbox.keepMine(id: tickRecord.id)
        let resent = Array(bridge.received.suffix(2))
        XCTAssertEqual(ids(resent), [editRecord, tickRecord].map { $0.id.uuidString.lowercased() })
        for item in resent {
            XCTAssertEqual(item["force"] as? Bool, true)
            XCTAssertEqual(item["base_sha256"] as? String, "abc")
            XCTAssertEqual(item["kind"] as? String, "edit",
                           "a tick is kept as the whole note it left behind")
        }
        XCTAssertEqual(resent[1]["text"] as? String,
                       note.replacingOccurrences(of: "- [ ]", with: "- [x]"))
        let left = await outbox.entries
        XCTAssertEqual(left, [])
    }

    func testTakeTheStudiosDropsTheRecord() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.answer { record in
            ["id": record["id"] ?? "", "status": "conflict",
             "current_text": "x", "current_sha256": "abc"]
        }
        await outbox.configure { bridge }
        let record = edit()
        try await outbox.enqueue(record)
        await outbox.flush()
        await outbox.takeStudios(id: record.id)
        let left = await outbox.entries
        XCTAssertEqual(left, [])
        await outbox.flush()
        XCTAssertEqual(bridge.sends, 1, "and it is never sent again")
    }

    func testARefusalIsShownOnceAndDropped() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.answer { record in
            ["id": record["id"] ?? "", "status": "refused", "reason": "Today.md is the bridge's"]
        }
        await outbox.configure { bridge }
        try await outbox.enqueue(edit("Today.md"))
        await outbox.flush()
        let left = await outbox.entries
        XCTAssertEqual(left, [])
        let shown = try await outbox.takeRefusals()
        XCTAssertEqual(shown.map(\.reason), ["Today.md is the bridge's"])
        let again = try await outbox.takeRefusals()
        XCTAssertEqual(again, [])
    }

    func testABusyBridgeKeepsEverything() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.busy = true
        await outbox.configure { bridge }
        try await outbox.enqueue(edit())
        await outbox.flush()
        let left = await outbox.entries.count
        XCTAssertEqual(left, 1)
    }

    // MARK: - An older bridge

    func testARouteMissingKeepsEverythingAndStillSendsStrandTicksTheOldWay() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        bridge.writeRouteMissing = true
        await outbox.configure { bridge }
        let strand = "# S\n\n## Drafts\n- [ ] **P1** Kits.\n"
        let strandTick = VaultWriteRecord.replacing(
            localPath: "Strands/Family.md", base: strand, baseStamp: VaultFileStamp(text: strand),
            new: strand.replacingOccurrences(of: "- [ ]", with: "- [x]"), kind: .tick)
        let records = [edit(), strandTick, capture()]
        for record in records { try await outbox.enqueue(record) }

        await outbox.flush()
        await outbox.flush()
        XCTAssertEqual(bridge.ticks, [StrandTickReport(note: "Family", id: "P1", checked: true)],
                       "the strand tick goes the old way, once")
        let kept = await outbox.entries.map(\.id)
        XCTAssertEqual(kept, records.map(\.id), "and every record waits for the new route")

        // The bridge is upgraded: everything goes, in order.
        bridge.writeRouteMissing = false
        await outbox.flush()
        XCTAssertEqual(ids(bridge.received), records.map { $0.id.uuidString.lowercased() })
        let left = await outbox.entries
        XCTAssertEqual(left, [])
    }

    func testTheOldStrandTickQueueIsMovedInAndSentTheOldWay() async throws {
        let suite = "VaultWriteOutboxTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = [StrandTickReport(note: "Family", id: "P1", checked: true)]
        defaults.set(try JSONEncoder().encode(old), forKey: VaultWriteOutbox.legacyTickKey)

        let outbox = VaultWriteOutbox(fileURL: directory.appendingPathComponent("outbox.json"),
                                      legacySuite: suite)
        let bridge = FakeVaultBridge()
        await outbox.configure { bridge }
        await outbox.flush()
        XCTAssertEqual(bridge.ticks, old)
        XCTAssertNil(defaults.data(forKey: VaultWriteOutbox.legacyTickKey), "moved, not copied")
    }

    // MARK: - Reading answers

    func testResponsesAreReadByStatus() {
        let id = UUID()
        let body = Data("""
            [{"id":"\(id.uuidString.lowercased())","status":"conflict","current_text":"t","current_sha256":"s","sha256":"s"}]
            """.utf8)
        XCTAssertEqual(VaultWriteSendOutcome.interpret(status: 200, body: body),
                       .answered([id: .conflict(currentText: "t", currentSHA256: "s")]))
        XCTAssertEqual(VaultWriteSendOutcome.interpret(status: 404, body: Data()), .routeMissing)
        XCTAssertEqual(VaultWriteSendOutcome.interpret(status: 503, body: Data()), .busy)
        if case .failed = VaultWriteSendOutcome.interpret(status: 500, body: Data()) {} else {
            XCTFail("a 500 is a failure, and everything stays")
        }
    }

    func testTwoFlushesAtOnceSendEachRecordOnce() async throws {
        let outbox = scratchOutbox(directory)
        let bridge = FakeVaultBridge()
        await outbox.configure { bridge }
        try await outbox.enqueue(edit())
        try await outbox.enqueue(tick())
        async let first: Void = outbox.flush()
        async let second: Void = outbox.flush()
        _ = await (first, second)
        XCTAssertEqual(bridge.received.count, 2)
    }
}

/// What the outbox held at the moment a send began.
actor SeenAtSend {
    private(set) var value: [UUID] = []
    func set(_ ids: [UUID]) { value = ids }
}
