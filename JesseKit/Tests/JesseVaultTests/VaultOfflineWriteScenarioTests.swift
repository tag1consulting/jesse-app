import XCTest
@testable import JesseVault

// THE WHOLE OFFLINE AFTERNOON, ON THE PHONE'S WRITE PATH.
//
// Airplane mode: an edit to one note, a checkbox ticked in another (not a strand), a line
// captured into the Inbox, a CriticMarkup comment typed into a third. Force quit. Back
// online. Every one of those must reach the Studio, in the order it was made, without
// Obsidian and without the person doing anything — and each must also be in the device's
// own folder, exactly as before. Through the real writers, a real folder and a real outbox
// file; only the bridge is scripted.
@MainActor
final class VaultOfflineWriteScenarioTests: XCTestCase {

    private var root: URL!
    private var container: URL!
    private var support: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        root = VaultFixture.makeDirectory()
        container = VaultFixture.makeDirectory()
        support = VaultFixture.makeDirectory()
        suiteName = "jesse.offline.scenario.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        for url in [root, container, support] { VaultFixture.cleanUp(url!) }
        try await super.tearDown()
    }

    func testFourOfflineWritesReachTheStudioInOrderAfterARelaunch() async throws {
        VaultFixture.write("# Plan\n\nThe first draft.\n", to: "Projects/Plan.md", in: root)
        VaultFixture.write("# Errands\n\n- [ ] Post office\n- [ ] Bank\n",
                           to: "Personal/Errands.md", in: root)
        VaultFixture.write("# Essay\n\nA paragraph worth a question.\n",
                           to: "Writing/Essay.md", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"),
                                                withIntermediateDirectories: true)
        let folder = VaultFolder(defaults: defaults, key: "scenario.bookmark")
        try folder.adopt(url: root)
        let source = VaultIndexSource(folder: folder, container: container)
        let log = OfflineWriteLog(directory: support)

        // Offline.
        let bridge = FakeVaultBridge()
        bridge.reachable = false
        let outbox = scratchOutbox(support)
        await outbox.configure { bridge }
        let writer = VaultNoteWriter(source: source, log: log, outbox: outbox)

        // 1. An edit.
        let editor = VaultNoteEditorModel(path: "Projects/Plan.md", writer: writer)
        await editor.load()
        editor.text = "# Plan\n\nThe second draft.\n"
        await editor.save()
        XCTAssertTrue(editor.didSave)

        // 2. A checkbox in a note that is not a strand.
        let errands = try await writer.readStamped(path: "Personal/Errands.md")
        let ticked = await VaultNoteTicker(writer: writer)
            .tick(path: "Personal/Errands.md", line: 3, to: true,
                  text: errands.text, stamp: errands.stamp)
        XCTAssertTrue(ticked.didWrite)

        // 3. A capture into the Inbox.
        let capture = InboxCaptureService(source: source, log: log, platform: .phone,
                                          deviceName: { "Phone" },
                                          now: { Date(timeIntervalSince1970: 1_790_400_000) },
                                          timeZone: { TimeZone(identifier: "Europe/Rome")! },
                                          outbox: outbox)
        guard case .success(let captured) = await capture.capture("call the plumber") else {
            return XCTFail("the capture should land")
        }

        // 4. A CriticMarkup comment, which is an edit of a third note.
        let commenter = VaultNoteEditorModel(path: "Writing/Essay.md", writer: writer)
        await commenter.load()
        commenter.text = "# Essay\n\nA paragraph worth a question.{>>Is this true?<<}\n"
        await commenter.save()
        XCTAssertTrue(commenter.didSave)

        // Nothing reached the bridge; everything reached the folder.
        XCTAssertTrue(bridge.received.isEmpty)
        let file = VaultFile(root: root)
        XCTAssertEqual(try file.read(relativePath: "Projects/Plan.md"), "# Plan\n\nThe second draft.\n")
        XCTAssertTrue(try file.read(relativePath: "Personal/Errands.md").contains("- [x] Post office"))
        XCTAssertTrue(try file.read(relativePath: captured.relativePath).contains("call the plumber"))
        XCTAssertTrue(try file.read(relativePath: "Writing/Essay.md").contains("{>>Is this true?<<}"))

        // Force quit, relaunch, back online. Nobody presses anything.
        let relaunched = scratchOutbox(support)
        bridge.reachable = true
        await relaunched.configure { bridge }
        await relaunched.flush()

        let received = bridge.received
        XCTAssertEqual(received.map { $0["kind"] as? String }, ["edit", "tick", "capture", "edit"])
        XCTAssertEqual(received.map { $0["path"] as? String },
                       ["Projects/Plan.md", "Personal/Errands.md", captured.relativePath,
                        "Writing/Essay.md"])
        XCTAssertEqual(received[1]["line"] as? Int, 3)
        XCTAssertEqual(received[2]["text"] as? String, captured.entry)
        let left = await relaunched.entries
        XCTAssertEqual(left, [], "all four applied, and the outbox is empty")

        // The write log's rows are the outbox's records, so the diagnostics screen can say
        // each one was delivered.
        let delivered = await relaunched.delivered(among: log.records.map(\.id))
        XCTAssertEqual(delivered.count, 4)
    }
}
