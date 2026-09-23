import XCTest
@testable import JesseVault

// THE WHOLE RITUAL, THROUGH THE REAL WRITER: a real folder, a real index, a real log.
//
// The unit tests above prove each rule in isolation; this one proves they are wired
// together — in particular that a search finds the words just typed, which is the single
// user-visible consequence of the single-file reindex and would otherwise be a claim.
@MainActor
final class VaultNoteWriteIntegrationTests: XCTestCase {

    private var root: URL!
    private var container: URL!
    private var logDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        root = VaultFixture.makeDirectory()
        container = VaultFixture.makeDirectory()
        logDirectory = VaultFixture.makeDirectory()
        suiteName = "jesse.vault.write.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        VaultFixture.cleanUp(root)
        VaultFixture.cleanUp(container)
        VaultFixture.cleanUp(logDirectory)
        try await super.tearDown()
    }

    private func makeSource() throws -> VaultIndexSource {
        let folder = VaultFolder(defaults: defaults, key: "write.bookmark")
        try folder.adopt(url: root)
        return VaultIndexSource(folder: folder, container: container)
    }

    // MARK: - The single-file reindex

    /// A `replace` followed by the single-file reindex makes the new words a search hit
    /// and removes the old ones. This is the reason the reindex exists.
    func testAWriteThenAReindexChangesWhatSearchFinds() async throws {
        VaultFixture.write("""
            # The kiln

            The chamber floor cracked along the backseam in spring.
            """, to: "Notes/Kiln.md", in: root)
        let source = try makeSource()
        await VaultIndexer(source: source).reindexNow()
        let index = try XCTUnwrap(try source.index())

        XCTAssertFalse(index.search(expression: "backseam").isEmpty,
                       "the fixture's own word must be findable to begin with")
        XCTAssertTrue(index.search(expression: "pyrometer").isEmpty)

        // Write, through the real path.
        let writer = VaultNoteWriter(source: source, log: OfflineWriteLog(directory: logDirectory))
        let read = try await writer.readStamped(path: "Notes/Kiln.md")
        _ = try await writer.replace(path: "Notes/Kiln.md", expected: read.stamp,
                                     with: """
                                     # The kiln

                                     The pyrometer reads forty degrees low at cone six.
                                     """,
                                     kind: .edit)

        // The new words are findable and the old ones are gone — with NO whole-vault
        // reindex in between, and no thirty-second debounce waited out.
        XCTAssertFalse(index.search(expression: "pyrometer").isEmpty,
                       "the words just written must be findable at once")
        XCTAssertTrue(index.search(expression: "backseam").isEmpty,
                      "and the words just removed must not be")
    }

    func testTheIndexerFacadeReindexesOneFile() async throws {
        VaultFixture.write("# A\n\nOriginal wording.\n", to: "A.md", in: root)
        let source = try makeSource()
        let indexer = VaultIndexer(source: source)
        await indexer.reindexNow()
        let index = try XCTUnwrap(try source.index())

        VaultFixture.write("# A\n\nCompletely different quernstone.\n", to: "A.md", in: root)
        let ok = await indexer.reindex(path: "A.md")

        XCTAssertTrue(ok)
        XCTAssertFalse(index.search(expression: "quernstone").isEmpty)
        XCTAssertTrue(index.search(expression: "Original").isEmpty)
    }

    /// A file that has gone is removed rather than left as a hit that opens onto nothing.
    func testReindexingADeletedFileRemovesItsRows() async throws {
        VaultFixture.write("# Gone\n\nEphemeral quernstone.\n", to: "Gone.md", in: root)
        let source = try makeSource()
        let indexer = VaultIndexer(source: source)
        await indexer.reindexNow()
        let index = try XCTUnwrap(try source.index())
        XCTAssertFalse(index.search(expression: "quernstone").isEmpty)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone.md"))
        _ = await indexer.reindex(path: "Gone.md")

        XCTAssertTrue(index.search(expression: "quernstone").isEmpty)
    }

    // MARK: - The exemption, enforced by the writer

    func testTheWriterRefusesTodayEvenWhenAskedDirectly() async throws {
        let original = "- [ ] a thing the bridge owns\n"
        VaultFixture.write(original, to: "Today.md", in: root)
        let source = try makeSource()
        let writer = VaultNoteWriter(source: source, log: OfflineWriteLog(directory: logDirectory))
        let read = try await writer.readStamped(path: "Today.md")

        do {
            _ = try await writer.replace(path: "Today.md", expected: read.stamp,
                                         with: "- [x] a thing the bridge owns\n", kind: .tick)
            XCTFail("Today.md must never be written by this app")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try VaultFile(root: root).read(relativePath: "Today.md"), original)
    }

    // MARK: - The log

    func testAWriteIsLoggedWithItsKindAndItsSizes() async throws {
        VaultFixture.write("- [ ] one\n", to: "T.md", in: root)
        let source = try makeSource()
        let log = OfflineWriteLog(directory: logDirectory)
        let writer = VaultNoteWriter(source: source, log: log)

        let read = try await writer.readStamped(path: "T.md")
        let after = try await writer.replace(path: "T.md", expected: read.stamp,
                                             with: "- [x] one\n", kind: .tick)

        let record = try XCTUnwrap(log.recentEdits.first)
        XCTAssertEqual(record.file, "T.md")
        XCTAssertEqual(record.kind, .tick)
        XCTAssertEqual(record.bytesBefore, read.stamp.bytes)
        XCTAssertEqual(record.bytes, after.bytes)
        XCTAssertEqual(record.checksum, after.digest)
        XCTAssertFalse(record.isCapture)
        // And it shows the sizes rather than the note's text.
        XCTAssertTrue(record.line.contains("ticked"))
        XCTAssertTrue(record.line.contains("→"))
    }

    func testEditsAndCapturesAreKeptApart() throws {
        let log = OfflineWriteLog(directory: logDirectory)
        log.record(OfflineWriteRecord(written: Date(), file: "Inbox/2026-09-23.md", bytes: 40,
                                      checksum: "abc", text: "a thought"))
        log.record(OfflineWriteRecord(written: Date(), file: "T.md", bytes: 10,
                                      checksum: "def", text: "", kind: .tick, bytesBefore: 10))

        XCTAssertEqual(log.recentCaptures.count, 1)
        XCTAssertEqual(log.recentEdits.count, 1)
        XCTAssertEqual(log.recentCaptures.first?.file, "Inbox/2026-09-23.md")
        XCTAssertEqual(log.recentEdits.first?.file, "T.md")

        // The verification pass must ignore the edit: it has no line to look for.
        let verdicts = OfflineWriteVerifier.statuses(for: log.records) { _ in "a thought" }
        XCTAssertEqual(verdicts.count, 1, "only the capture is verifiable")
    }

    /// Twenty ticks in an afternoon must not push the captures off the screen that exists
    /// to show them.
    func testManyEditsDoNotHideTheCaptures() throws {
        let log = OfflineWriteLog(directory: logDirectory)
        log.record(OfflineWriteRecord(written: Date(), file: "Inbox/one.md", bytes: 10,
                                      checksum: "a", text: "the only capture"))
        for i in 0..<40 {
            log.record(OfflineWriteRecord(written: Date(), file: "N\(i).md", bytes: 10,
                                          checksum: "b", text: "", kind: .edit, bytesBefore: 9))
        }
        XCTAssertEqual(log.recentCaptures.count, 1)
        XCTAssertEqual(log.recentEdits.count, OfflineWriteLog.displayCount)
    }

    func testTheLogIsCapped() throws {
        let log = OfflineWriteLog(directory: logDirectory)
        for i in 0..<(OfflineWriteLog.capacity + 25) {
            log.record(OfflineWriteRecord(written: Date(), file: "N\(i).md", bytes: 1,
                                          checksum: "c", text: "", kind: .edit, bytesBefore: 1))
        }
        XCTAssertEqual(log.records.count, OfflineWriteLog.capacity)
        // Newest kept, oldest dropped.
        XCTAssertEqual(log.records.first?.file, "N\(OfflineWriteLog.capacity + 24).md")
        XCTAssertFalse(log.records.contains { $0.file == "N0.md" })
    }

    /// A row written by a build that had never heard of `kind` must still decode — and as
    /// a capture, which is what it was. Getting this wrong would have emptied the log.
    func testARecordFromBeforeNoteEditingDecodesAsACapture() throws {
        let legacy = """
            [
              {
                "id": "\(UUID().uuidString)",
                "written": "2026-09-01T09:14:00Z",
                "file": "Inbox/2026-09-01.md",
                "bytes": 42,
                "checksum": "deadbeef",
                "text": "an older thought",
                "status": "written"
              }
            ]
            """
        let log = OfflineWriteLog(directory: logDirectory)
        try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: log.url)

        let records = log.records
        XCTAssertEqual(records.count, 1, "an old log must not decode to nothing")
        XCTAssertEqual(records.first?.kind, .capture)
        XCTAssertTrue(records.first?.isCapture == true)
        XCTAssertNil(records.first?.bytesBefore)
        XCTAssertEqual(records.first?.text, "an older thought")
    }

    // MARK: - End to end, the case the device checklist reproduces by hand

    func testTickingAnArchiveFooterChangesOnlyThatLine() async throws {
        let draft = """
            # A draft about the yard

            Some body text that must not move.

            ---

            - [ ] Archive only
            - [ ] Archive and extract to the knowledge base
            """
        VaultFixture.write(draft, to: "Projects/drafts/2026-09-23-1200-yard.md", in: root)
        let source = try makeSource()
        let writer = VaultNoteWriter(source: source,
                                     log: OfflineWriteLog(directory: logDirectory))
        let path = "Projects/drafts/2026-09-23-1200-yard.md"
        let read = try await writer.readStamped(path: path)

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: path, line: 7, to: true, text: read.text, stamp: read.stamp)
        XCTAssertTrue(outcome.didWrite)

        let after = try VaultFile(root: root).read(relativePath: path)
        XCTAssertEqual(after, draft.replacingOccurrences(of: "- [ ] Archive only",
                                                         with: "- [x] Archive only"))
        // Line by line, exactly one differs.
        let before = draft.split(separator: "\n", omittingEmptySubsequences: false)
        let now = after.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(before.count, now.count)
        XCTAssertEqual(zip(before, now).filter { $0 != $1 }.count, 1)
    }
}
