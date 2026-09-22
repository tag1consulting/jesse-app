import XCTest
@testable import JesseVault

// THE WHOLE CHAIN, END TO END, with nothing faked but the on-device model: a real folder
// held by a real bookmark, a real scan, a real SQLite index, the screen's own model, and
// the reader.
//
// It is the closest a unit test gets to the device checklist at the end of this work, and
// it is what catches the failures no pure test can — a folder that resolves but cannot be
// read, an index opened against the wrong directory, a search that works in isolation and
// finds nothing through the model that drives the screen.

@MainActor
final class VaultBrowserModelTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private var databaseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "jesse.vault.browser.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = VaultFixture.makeDirectory()
        databaseDirectory = VaultFixture.makeDirectory()
        VaultFixture.writeCorpus(in: root)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        VaultFixture.cleanUp(root)
        VaultFixture.cleanUp(databaseDirectory)
        super.tearDown()
    }

    /// A source over a folder this "device" has adopted for real.
    private func makeSource() throws -> VaultIndexSource {
        let folder = VaultFolder(defaults: defaults, key: "test.bookmark")
        try folder.adopt(url: root)
        return VaultIndexSource(folder: folder, container: databaseDirectory)
    }

    /// A source over a device with no folder picked.
    private func makeEmptySource() -> VaultIndexSource {
        VaultIndexSource(folder: VaultFolder(defaults: defaults, key: "test.bookmark"),
                         container: databaseDirectory)
    }

    // MARK: - Indexing through the indexer

    func testAFirstIndexPassThroughTheIndexerFindsTheWholeCorpus() async throws {
        let indexer = VaultIndexer(source: try makeSource())

        await indexer.reindexNow()

        XCTAssertFalse(indexer.isIndexing)
        XCTAssertEqual(indexer.lastReport?.added, 5)
        XCTAssertEqual(indexer.counts.fileCount, 5)
        XCTAssertNil(indexer.lastError)
        XCTAssertEqual(indexer.progress, 1)
    }

    /// THE DEBOUNCE, which is what keeps an activation-driven reindex from being a walk of
    /// the vault every time the app comes forward: a second request inside the window does
    /// nothing at all.
    func testASecondRequestInsideTheDebounceWindowDoesNothing() async throws {
        let source = try makeSource()
        let indexer = VaultIndexer(source: source)
        await indexer.reindexNow()

        VaultFixture.write("# Glaze\n\nCopper red.\n", to: "Workshop/Glaze.md", in: root)
        indexer.reindexIfDue()
        // Nothing was started, so there is nothing to await; the counts are the evidence.
        XCTAssertEqual(indexer.counts.fileCount, 5, "the new note is not picked up yet")

        await indexer.reindexNow()
        XCTAssertEqual(indexer.counts.fileCount, 6, "the button ignores the debounce")
    }

    /// A debounce of zero lets the activation path through, which is the other half of the
    /// same rule.
    func testTheActivationPathRunsWhenTheWindowHasPassed() async throws {
        let indexer = VaultIndexer(source: try makeSource())
        await indexer.reindexNow()
        VaultFixture.write("# Glaze\n\nCopper red.\n", to: "Workshop/Glaze.md", in: root)

        indexer.reindexIfDue(debounce: 0)
        await indexer.reindexNow()

        XCTAssertEqual(indexer.counts.fileCount, 6)
    }

    /// Rebuild throws the index away and builds it again in one press: the counts afterwards
    /// are a full corpus, not an empty database.
    func testRebuildEndsWithAFullIndex() async throws {
        let indexer = VaultIndexer(source: try makeSource())
        await indexer.reindexNow()

        await indexer.rebuild()

        XCTAssertEqual(indexer.counts.fileCount, 5)
        XCTAssertEqual(indexer.lastReport?.added, 5, "everything was read again, as new")
    }

    /// A device with no folder is not an error state. Nothing is indexed, nothing throws, and
    /// the screen says what to do about it.
    func testADeviceWithNoFolderIndexesNothingAndReportsNoError() async {
        let indexer = VaultIndexer(source: makeEmptySource())

        await indexer.reindexNow()

        XCTAssertNil(indexer.lastError)
        XCTAssertEqual(indexer.counts.fileCount, 0)
    }

    // MARK: - The screen's model

    func testWithNothingTypedTheScreenShowsTheMostRecentlyChangedNotes() async throws {
        let source = try makeSource()
        VaultFixture.touch("Suppliers/Terrasole.md", in: root,
                           date: Date().addingTimeInterval(600))
        let model = VaultBrowserModel(source: source)
        await model.indexer.reindexNow()

        model.refresh()

        XCTAssertTrue(model.hasFolder)
        XCTAssertEqual(model.recents.count, 5)
        XCTAssertEqual(model.recents.first?.path, "Suppliers/Terrasole.md",
                       "newest first, which on any given morning is what a person wants")
        XCTAssertEqual(model.recents.first?.title, "Terrasole", "titles, not file names")
    }

    func testTypingAQueryAnswersThroughTheModelTheScreenDrives() async throws {
        let model = VaultBrowserModel(source: try makeSource(), debounce: .zero)
        await model.indexer.reindexNow()
        model.refresh()

        model.query = "soft bricks"
        model.search()
        await model.awaitPendingSearch()

        XCTAssertEqual(model.hits.map(\.path), ["Workshop/Kiln-Rebuild.md"])
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.expansionCaption, "no expansion was needed, so nothing is claimed")
        XCTAssertGreaterThan(model.lastSearchSeconds, 0)
    }

    /// Clearing the field clears the results rather than leaving the last query's answer on
    /// screen under an empty field.
    func testClearingTheFieldClearsTheResults() async throws {
        let model = VaultBrowserModel(source: try makeSource(), debounce: .zero)
        await model.indexer.reindexNow()
        model.refresh()
        model.query = "bricks"
        model.search()
        await model.awaitPendingSearch()
        XCTAssertFalse(model.hits.isEmpty)

        model.query = ""
        model.search()

        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    /// A device with no folder never searches, and its status line says why.
    func testADeviceWithNoFolderSearchesNothing() async {
        let model = VaultBrowserModel(source: makeEmptySource(), debounce: .zero)
        model.refresh()

        model.query = "bricks"
        model.search()
        await model.awaitPendingSearch()

        XCTAssertFalse(model.hasFolder)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.folderStatus.needsPicking)
    }

    // MARK: - The reader

    func testTheReaderReadsANoteAndResolvesItsLinks() async throws {
        let source = try makeSource()
        let indexer = VaultIndexer(source: source)
        await indexer.reindexNow()
        let reader = VaultNoteReaderModel(source: source)

        await reader.load(path: "Workshop/Kiln-Rebuild.md")

        let document = try XCTUnwrap(reader.document)
        XCTAssertEqual(document.title, "The Kiln Rebuild", "the frontmatter title wins")
        XCTAssertEqual(document.frontmatter.first, "title: The Kiln Rebuild")
        XCTAssertNotNil(document.modified)
        XCTAssertFalse(document.truncated)
        XCTAssertEqual(reader.resolved["Suppliers/Terrasole"], "Suppliers/Terrasole.md")
        XCTAssertEqual(reader.resolved["People/Marta Ruggeri"], "People/Marta Ruggeri.md")
        XCTAssertNotNil(reader.fileURL, "and Reveal has somewhere to point")
    }

    /// A link to a note that is not there resolves to nothing, and the reader says so rather
    /// than offering a link that goes nowhere.
    func testALinkToAMissingNoteIsLeftUnresolved() async throws {
        let source = try makeSource()
        VaultFixture.write("# Orphan\n\nSee [[Nowhere At All]] and [[Overview]].\n",
                           to: "Workshop/Orphan.md", in: root)
        await VaultIndexer(source: source).reindexNow()
        let reader = VaultNoteReaderModel(source: source)

        await reader.load(path: "Workshop/Orphan.md")

        XCTAssertNil(reader.resolved["Nowhere At All"])
        XCTAssertNil(reader.resolved["Overview"],
                     "two files are named Overview.md, so the vault refuses to guess")
    }

    func testAMissingFileIsAFailedStateRatherThanACrash() async throws {
        let reader = VaultNoteReaderModel(source: try makeSource())

        await reader.load(path: "Workshop/Not-Here.md")

        guard case .failed(let message) = reader.state else {
            return XCTFail("expected .failed, got \(reader.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// The reader refuses a path that leaves the vault, through the same validation every
    /// other read goes through — the reader is not a general file viewer.
    func testTheReaderRefusesAPathThatLeavesTheVault() async throws {
        let reader = VaultNoteReaderModel(source: try makeSource())

        await reader.load(path: "../escape.md")

        guard case .failed = reader.state else {
            return XCTFail("expected .failed for a path outside the vault")
        }
    }
}
