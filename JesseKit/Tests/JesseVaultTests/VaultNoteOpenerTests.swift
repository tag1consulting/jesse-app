import XCTest
@testable import JesseVault

// A NOTE OPENED BY NAME IS THE STUDIO'S WHENEVER THE DEVICE IS BEHIND.
//
// The defect: every by-name open read the phone's Obsidian folder first and trusted it,
// and that folder syncs only while Obsidian is in the foreground. One test per branch of
// the decision, through the real opener against a scripted bridge, and then the reader
// itself, which is where the decision is acted on.
final class VaultNoteOpenerTests: XCTestCase {

    private let current = "# Family\n\n- [ ] **P1** Kits.\n- [ ] **P2** Sheet.\n"
    private let stale = "# Family\n\n- [ ] **P1** Kits.\n"

    private func opener(_ bridge: FakeVaultBridge,
                        reachability: BridgeReachabilityState = .reachable) -> VaultNoteOpener {
        VaultNoteOpener(client: bridge, reachability: reachability)
    }

    func testEqualHashesOpenTheLocalCopy() async {
        let bridge = FakeVaultBridge()
        bridge.setNote("Strands/Family.md", current)
        let opening = await opener(bridge).open(localPath: "Strands/Family.md",
                                                localStamp: VaultFileStamp(text: current))
        XCTAssertEqual(opening, .local)
        XCTAssertEqual(bridge.fetches.first?.ifNoneMatch, VaultFileStamp(text: current).digest,
                       "one conditional request, carrying the device's own hash")
    }

    func testDifferingHashesOpenTheStudiosCopy() async {
        let bridge = FakeVaultBridge()
        bridge.setNote("Strands/Family.md", current)
        let opening = await opener(bridge).open(localPath: "Strands/Family.md",
                                                localStamp: VaultFileStamp(text: stale))
        guard case .bridge(let note) = opening else { return XCTFail("\(opening)") }
        XCTAssertEqual(note.markdown, current)
        XCTAssertEqual(note.sha256, VaultFileStamp(text: current).digest)
        XCTAssertTrue(VaultNoteOpener.behindCaption(modified: note.modified)
            .hasPrefix("The Obsidian copy on this device is behind. Showing the Studio's copy, saved "))
    }

    func testAMissingLocalCopyOpensTheStudiosCopy() async {
        let bridge = FakeVaultBridge()
        bridge.setNote("Strands/Renamed/Family.md", current)
        let opening = await opener(bridge).open(localPath: "Strands/Renamed/Family.md",
                                                localStamp: nil)
        guard case .bridge(let note) = opening else { return XCTFail("\(opening)") }
        XCTAssertEqual(note.path, "Strands/Renamed/Family.md")
    }

    func testAnOlderBridgeWithoutTheRouteFallsBackToTheLocalCopy() async {
        let bridge = FakeVaultBridge()
        bridge.noteRouteMissing = true
        let opening = await opener(bridge).open(localPath: "Strands/Family.md",
                                                localStamp: VaultFileStamp(text: stale))
        XCTAssertEqual(opening, .offline)
    }

    func testAnUnreachableBridgeFallsBackToTheLocalCopy() async {
        let bridge = FakeVaultBridge()
        bridge.reachable = false
        let opening = await opener(bridge).open(localPath: "Strands/Family.md",
                                                localStamp: VaultFileStamp(text: stale))
        XCTAssertEqual(opening, .offline)

        // Already known to be unreachable: no request at all, no timeout spent proving it.
        let quiet = FakeVaultBridge()
        let offline = await opener(quiet, reachability: .unreachable)
            .open(localPath: "Strands/Family.md", localStamp: VaultFileStamp(text: stale))
        XCTAssertEqual(offline, .offline)
        XCTAssertTrue(quiet.fetches.isEmpty)
    }

    func testANoteTheStudioDoesNotHaveIsShownLocalOnly() async {
        let bridge = FakeVaultBridge()
        let opening = await opener(bridge).open(localPath: "Projects/Gone.md",
                                                localStamp: VaultFileStamp(text: stale))
        XCTAssertEqual(opening, .localOnly)
        let nothing = await opener(bridge).open(localPath: "Projects/Gone.md", localStamp: nil)
        XCTAssertEqual(nothing, .notOnStudio)
    }

    func testAnUnconfiguredOpenerIsTheLocalCopyAsBefore() async {
        let opener = VaultNoteOpener()
        let opening = await opener.open(localPath: "A.md", localStamp: VaultFileStamp(text: "a"))
        XCTAssertEqual(opening, .local)
    }

    func testTheDevicesVaultPrefixIsNotTheBridges() {
        XCTAssertEqual(VaultBridgePath.bridge(fromLocal: "vault/Strands/Family.md"),
                       "Strands/Family.md")
        XCTAssertEqual(VaultBridgePath.bridge(fromLocal: "Strands/Family.md"), "Strands/Family.md")
    }

    // MARK: - Wiki targets

    func testATargetTheStudioHasOpensItsPathEvenWhenTheDeviceHasNone() async {
        let bridge = FakeVaultBridge()
        bridge.setNote("Projects/New.md", "made an hour ago\n")
        let opener = opener(bridge)
        let resolved = await opener.resolve(target: "Projects/New", localPath: nil)
        XCTAssertEqual(resolved, .path("Projects/New.md"))
        // The open that follows reuses that answer rather than asking again.
        let opening = await opener.open(localPath: "Projects/New.md", localStamp: nil)
        guard case .bridge = opening else { return XCTFail("\(opening)") }
        XCTAssertEqual(bridge.fetches.count, 1)
    }

    func testATargetFallsBackToTheLocalIndexWhenTheStudioCannotBeAsked() async {
        let bridge = FakeVaultBridge()
        bridge.reachable = false
        let resolved = await opener(bridge).resolve(target: "Projects/A", localPath: "Projects/A.md")
        XCTAssertEqual(resolved, .path("Projects/A.md"))
        let missing = await opener(bridge).resolve(target: "Projects/A", localPath: nil)
        guard case .missing = missing else { return XCTFail("\(missing)") }
    }

    func testTheRoutesAnswersAreReadByStatusAndBody() {
        XCTAssertEqual(VaultBridgeNoteFetch.interpret(status: 304, body: Data()), .notModified)
        XCTAssertEqual(VaultBridgeNoteFetch.interpret(
            status: 404, body: Data(#"{"error":"note_not_found"}"#.utf8)), .noteNotFound)
        XCTAssertEqual(VaultBridgeNoteFetch.interpret(status: 404, body: Data()), .routeMissing,
                       "an older bridge's unknown route carries no error word")
    }
}

// MARK: - The reader acting on it

@MainActor
final class VaultNoteReaderBridgeFirstTests: XCTestCase {

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
        suiteName = "jesse.reader.bridge.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        for url in [root, container, support] { VaultFixture.cleanUp(url!) }
        try await super.tearDown()
    }

    private func makeSource() throws -> VaultIndexSource {
        let folder = VaultFolder(defaults: defaults, key: "reader.bookmark")
        try folder.adopt(url: root)
        return VaultIndexSource(folder: folder, container: container)
    }

    private let current = "# Family\n\n- [ ] **P1** Kits.\n- [ ] **P2** Sheet.\n"
    private let stale = "# Family\n\n- [ ] **P1** Kits.\n"

    func testACurrentLocalCopyOpensEditableAndLocal() async throws {
        VaultFixture.write(current, to: "Strands/Family.md", in: root)
        let bridge = FakeVaultBridge()
        bridge.setNote("Strands/Family.md", current)
        let reader = VaultNoteReaderModel(source: try makeSource(),
                                          opener: VaultNoteOpener(client: bridge),
                                          outbox: scratchOutbox(support))
        await reader.load(path: "Strands/Family.md")
        XCTAssertEqual(reader.origin, .local)
        XCTAssertNotNil(reader.fileURL)
        XCTAssertNil(reader.bridgeWriter, "the device's own copy writes through the usual writer")
        XCTAssertTrue(reader.canWrite)
    }

    func testAStaleLocalCopyOpensTheStudiosAndATickNeverTouchesTheFolder() async throws {
        VaultFixture.write(stale, to: "Strands/Family.md", in: root)
        let bridge = FakeVaultBridge()
        bridge.setNote("Strands/Family.md", current)
        let outbox = scratchOutbox(support)
        await outbox.configure { bridge }
        let reader = VaultNoteReaderModel(source: try makeSource(),
                                          opener: VaultNoteOpener(client: bridge),
                                          outbox: outbox)
        await reader.load(path: "Strands/Family.md")
        guard case .bridge = reader.origin else { return XCTFail("\(reader.origin)") }
        XCTAssertEqual(reader.text, current)
        XCTAssertNil(reader.fileURL, "nothing to reveal: the Studio's copy is not a file here")

        // Tick P2, which only the Studio's copy has.
        let block = try XCTUnwrap(reader.document?.blocks.first { block in
            if case .checkbox = block.kind { return block.line == 4 }
            return false
        })
        await reader.tick(block: block, to: true)

        XCTAssertEqual(try VaultFile(root: root).read(relativePath: "Strands/Family.md"), stale,
                       "the Obsidian folder is never written from the Studio's copy")
        let sent = try XCTUnwrap(bridge.received.first)
        XCTAssertEqual(sent["kind"] as? String, "tick")
        XCTAssertEqual(sent["path"] as? String, "Strands/Family.md")
        XCTAssertEqual(sent["line"] as? Int, 4)
        XCTAssertEqual(sent["base_sha256"] as? String, VaultFileStamp(text: current).digest)
    }

    func testAnEditOfTheStudiosCopyGoesToTheOutboxWithItsHash() async throws {
        let bridge = FakeVaultBridge()
        bridge.setNote("Projects/New.md", current)
        let outbox = scratchOutbox(support)
        await outbox.configure { bridge }
        let reader = VaultNoteReaderModel(source: try makeSource(),
                                          opener: VaultNoteOpener(client: bridge),
                                          outbox: outbox)
        await reader.load(path: "Projects/New.md")
        guard case .bridge = reader.origin else { return XCTFail("\(reader.origin)") }
        let writer = try XCTUnwrap(reader.bridgeWriter)
        let editor = VaultNoteEditorModel(path: "Projects/New.md", writer: writer)
        await editor.load()
        editor.text = current + "{>>a comment<<}\n"
        await editor.save()
        XCTAssertTrue(editor.didSave)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Projects/New.md").path))
        let sent = try XCTUnwrap(bridge.received.first)
        XCTAssertEqual(sent["kind"] as? String, "edit")
        XCTAssertEqual(sent["base_sha256"] as? String, VaultFileStamp(text: current).digest)
        XCTAssertEqual(sent["base_text"] as? String, current)
        XCTAssertEqual(sent["text"] as? String, current + "{>>a comment<<}\n")
    }

    func testAnUnreachableBridgeOpensTheLocalCopyOffline() async throws {
        VaultFixture.write(stale, to: "Strands/Family.md", in: root)
        let bridge = FakeVaultBridge()
        bridge.reachable = false
        let reader = VaultNoteReaderModel(source: try makeSource(),
                                          opener: VaultNoteOpener(client: bridge),
                                          outbox: scratchOutbox(support))
        await reader.load(path: "Strands/Family.md")
        XCTAssertEqual(reader.origin, .offline)
        XCTAssertEqual(reader.text, stale)
    }

    func testANoteTheStudioLacksIsShownAsLocalOnly() async throws {
        VaultFixture.write(stale, to: "Projects/Only-Here.md", in: root)
        let reader = VaultNoteReaderModel(source: try makeSource(),
                                          opener: VaultNoteOpener(client: FakeVaultBridge()),
                                          outbox: scratchOutbox(support))
        await reader.load(path: "Projects/Only-Here.md")
        XCTAssertEqual(reader.origin, .localOnly)
    }
}
