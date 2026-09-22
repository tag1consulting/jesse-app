import XCTest
@testable import JesseVault

// The index, driven over a real temporary vault: what a reindex reads, what it leaves
// alone, what a search answers, and in what order.
//
// These tests use the FILESYSTEM and SQLITE on purpose. The chunker and the resolver are
// asserted purely elsewhere; what is left — "an unchanged file is not re-read", "a deleted
// file's rows go", "a title hit outranks a body hit" — is a claim about the database and a
// fake database would prove nothing about it.

final class VaultIndexTests: XCTestCase {

    private var root: URL!
    private var databaseDirectory: URL!

    override func setUp() {
        super.setUp()
        root = VaultFixture.makeDirectory()
        databaseDirectory = VaultFixture.makeDirectory()
    }

    override func tearDown() {
        VaultFixture.cleanUp(root)
        VaultFixture.cleanUp(databaseDirectory)
        super.tearDown()
    }

    private func makeIndex() throws -> VaultIndex {
        try VaultIndex(url: VaultIndex.databaseURL(forRoot: root, in: databaseDirectory))
    }

    /// Read every file the scanner finds, as the app does.
    @discardableResult
    private func reindex(_ index: VaultIndex) throws -> VaultReindexReport {
        let scan = VaultScanner().scan(root: root)
        let file = VaultFile(root: root)
        return try index.reindex(scan: scan, read: { try file.read(relativePath: $0) })
    }

    // MARK: - The platform fact the whole design rests on

    /// FTS5 IS COMPILED IN. Apple ships it on iOS and macOS, and this measures rather than
    /// believes: without it nothing below is possible, and the failure would otherwise
    /// surface as "search finds nothing" on somebody's phone.
    func testThisPlatformsSQLiteHasFTS5() {
        XCTAssertTrue(VaultIndex.fts5IsAvailable,
                      "libsqlite3 here was built without FTS5; the vault index cannot work")
    }

    /// One database per folder, and NEVER inside the vault: a 60 MB file appearing in
    /// Obsidian's own tree would be synced to every device the user owns.
    func testTheDatabaseLivesOutsideTheVaultAndIsKeyedByFolder() {
        let other = VaultFixture.makeDirectory()
        defer { VaultFixture.cleanUp(other) }
        let a = VaultIndex.databaseURL(forRoot: root, in: databaseDirectory)
        let b = VaultIndex.databaseURL(forRoot: other, in: databaseDirectory)

        XCTAssertEqual(a.lastPathComponent, "vault-index.sqlite")
        XCTAssertNotEqual(a, b, "two folders are two indexes")
        XCTAssertFalse(a.path.hasPrefix(root.path), "the index is never inside the vault")
    }

    // MARK: - Indexing

    func testAFirstIndexPassStoresEveryMarkdownFileAndSkipsDotDirectories() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()

        let report = try reindex(index)

        XCTAssertEqual(report.added, 5)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.unchanged, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.completed)
        XCTAssertEqual(index.counts().fileCount, 5)
        XCTAssertGreaterThan(index.counts().chunkCount, 5, "long notes are several chunks")
        XCTAssertGreaterThan(index.counts().linkCount, 0, "the corpus links between notes")
        XCTAssertFalse(index.allPaths().contains { $0.contains(".obsidian") },
                       "a dot directory is not notes and is never indexed")
    }

    /// THE POINT OF AN INCREMENTAL REINDEX: a file whose modification time and size are
    /// unchanged is not re-read, and the proof is that its chunk rows still have the same
    /// ids. A rewritten chunk gets a new rowid, so identical ids mean the rows were never
    /// touched.
    func testAnUnchangedFileIsNotRewritten() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let before = index.chunkIDs(forPath: "Workshop/Kiln-Rebuild.md")
        XCTAssertFalse(before.isEmpty)

        let second = try reindex(index)

        XCTAssertEqual(second.unchanged, 5)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(index.chunkIDs(forPath: "Workshop/Kiln-Rebuild.md"), before,
                       "same rows, same ids: nothing was re-read or rewritten")
    }

    func testAChangedFileIsReReadAndItsOldChunksReplaced() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let before = index.chunkIDs(forPath: "Suppliers/Terrasole.md")

        VaultFixture.write("# Terrasole\n\nThey moved to Foligno.\n",
                           to: "Suppliers/Terrasole.md", in: root)
        VaultFixture.touch("Suppliers/Terrasole.md", in: root, date: Date().addingTimeInterval(60))
        let report = try reindex(index)

        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.unchanged, 4)
        XCTAssertNotEqual(index.chunkIDs(forPath: "Suppliers/Terrasole.md"), before,
                          "the file was re-chunked, so its rows are new rows")
        let hits = index.search(expression: "\"foligno\"*")
        XCTAssertEqual(hits.first?.path, "Suppliers/Terrasole.md",
                       "the new words are searchable")
        XCTAssertTrue(index.search(expression: "\"perugia\"*").isEmpty,
                      "and the old ones are gone, rather than lingering in the fts index")
    }

    func testANewFileIsAddedAndADeletedFileLeavesNoRowsBehind() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)

        VaultFixture.write("# Glaze tests\n\nCopper red, second attempt.\n",
                           to: "Workshop/Glaze-Tests.md", in: root)
        let added = try reindex(index)
        XCTAssertEqual(added.added, 1)
        XCTAssertEqual(index.counts().fileCount, 6)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Workshop/Glaze-Tests.md"))
        let removed = try reindex(index)

        XCTAssertEqual(removed.removed, 1)
        XCTAssertEqual(index.counts().fileCount, 5)
        XCTAssertTrue(index.chunkIDs(forPath: "Workshop/Glaze-Tests.md").isEmpty)
        XCTAssertTrue(index.search(expression: "\"copper\"*").isEmpty,
                      "a deleted note must not keep answering searches")
        XCTAssertTrue(index.outgoingTargets(fromPath: "Workshop/Glaze-Tests.md").isEmpty)
    }

    /// A run that stops early keeps what it committed and does NOT conclude that the files
    /// it never reached are gone. That is what makes a first index resumable when iOS
    /// suspends the app in the middle of it.
    func testAStoppedRunKeepsItsProgressAndDeletesNothing() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        let scan = VaultScanner().scan(root: root)
        let file = VaultFile(root: root)
        var read = 0

        let report = try index.reindex(scan: scan,
                                       read: { path in
                                           read += 1
                                           return try file.read(relativePath: path)
                                       },
                                       batchSize: 1,
                                       isCancelled: { read >= 2 })

        XCTAssertFalse(report.completed)
        XCTAssertEqual(report.removed, 0, "an incomplete walk proves nothing about what is gone")
        XCTAssertEqual(index.counts().fileCount, 2, "the two files it did read are committed")

        let finished = try reindex(index)
        XCTAssertEqual(finished.unchanged, 2, "the next run does not repeat them")
        XCTAssertEqual(finished.added, 3)
        XCTAssertEqual(index.counts().fileCount, 5)
    }

    /// A file that cannot be read is counted, not swallowed, and its existing rows survive:
    /// a transient read failure must not empty a note out of the index.
    func testAnUnreadableFileIsCountedAndKeepsItsOldRows() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let before = index.chunkIDs(forPath: "Suppliers/Terrasole.md")

        VaultFixture.touch("Suppliers/Terrasole.md", in: root, date: Date().addingTimeInterval(120))
        let scan = VaultScanner().scan(root: root)
        let report = try index.reindex(scan: scan, read: { path in
            if path == "Suppliers/Terrasole.md" {
                throw VaultFileError.unreadable(path, "the file provider was asleep")
            }
            return try VaultFile(root: self.root).read(relativePath: path)
        })

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(index.chunkIDs(forPath: "Suppliers/Terrasole.md"), before)
    }

    /// The counts the diagnostics screen shows are real numbers off the database, including
    /// the file's own size on disk.
    func testTheCountsReportTheDatabaseSize() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)

        XCTAssertGreaterThan(index.counts().databaseBytes, 0)
    }

    /// Rebuild throws everything away. The next pass sees every file as NEW, which is the
    /// difference between "rebuild" and "reindex".
    func testRebuildEmptiesTheIndexAndTheNextPassReAddsEverything() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)

        try index.rebuild()
        XCTAssertEqual(index.counts().fileCount, 0)
        XCTAssertEqual(index.counts().chunkCount, 0)

        let report = try reindex(index)
        XCTAssertEqual(report.added, 5)
        XCTAssertEqual(report.unchanged, 0)
    }

    // MARK: - Searching

    func testEveryTokenIsRequired() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let searcher = VaultSearcher(index: index)

        XCTAssertFalse(searcher.base("soft bricks").hits.isEmpty)
        XCTAssertTrue(searcher.base("soft bricks chihuahua").hits.isEmpty,
                      "a token nothing contains means no hit, however good the rest are")
    }

    /// A half-remembered word finds the whole one: every token is a PREFIX term, which is
    /// the difference between an index and a grep.
    func testAPartialWordMatchesByPrefix() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)

        let hits = VaultSearcher(index: index).base("terras").hits
        XCTAssertEqual(hits.first?.path, "Suppliers/Terrasole.md")
    }

    /// Diacritics fold, in both directions — `unicode61 remove_diacritics 2`. "cafe" has to
    /// find "café", because that is how the word gets typed on a phone.
    func testDiacriticsFold() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let searcher = VaultSearcher(index: index)

        XCTAssertFalse(searcher.base("cafe tiles").hits.isEmpty, "cafe finds café")
        XCTAssertFalse(searcher.base("café tiles").hits.isEmpty, "and café finds itself")
    }

    /// THE RANKING CLAIM: a note NAMED after what was searched for comes first, even when
    /// another note mentions the words more often. Searching a surname in this vault means
    /// "their file", and bm25 alone does not know that.
    func testAFileWhoseNameMatchesOutranksAPassingMention() throws {
        VaultFixture.write("# Marta Ruggeri\n\nRuns the burner workshop.\n",
                           to: "People/Marta Ruggeri.md", in: root)
        VaultFixture.write("""
            # Meeting notes

            Marta said the burner was fine. Marta will call. Marta, Marta, Marta.
            Ruggeri's quote is in the drawer.
            """, to: "Workshop/Meeting-2026-03-04.md", in: root)
        let index = try makeIndex()
        try reindex(index)

        let hits = VaultSearcher(index: index).base("ruggeri").hits

        XCTAssertEqual(hits.first?.path, "People/Marta Ruggeri.md")
        XCTAssertTrue(hits.first?.isNameMatch == true, "and the row can say why it is first")
        XCTAssertEqual(hits.count, 2, "the mention is still found, just below")
    }

    /// One row per FILE. A long note with the query in six sections must not fill the list
    /// with itself and bury five other notes that answer the question too.
    func testASearchAnswersWithOneRowPerFile() throws {
        let body = (1...6).map { "## Section \($0)\n\nThe kiln again.\n" }.joined(separator: "\n")
        VaultFixture.write("# Repeats\n\n" + body, to: "Workshop/Repeats.md", in: root)
        VaultFixture.write("# Elsewhere\n\nThe kiln, once.\n", to: "Bicycle/Elsewhere.md", in: root)
        let index = try makeIndex()
        try reindex(index)

        let hits = VaultSearcher(index: index).base("kiln").hits
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.path)).count, 2)
    }

    /// A hit carries the heading it was found under and the line it starts on, because
    /// "somewhere in this 900-line file" is not an answer.
    func testAHitCarriesItsHeadingAndItsLine() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)

        // "arch" appears once in the whole corpus, in the Kiln note's Schedule section.
        let hits = VaultSearcher(index: index).base("arch").hits
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.heading, "Schedule")
        XCTAssertGreaterThan(hits.first?.line ?? 0, 1)
        XCTAssertTrue(hits.first?.snippet.contains(VaultSearchHit.markStart) == true,
                      "the matched term is marked so the row can bold it")
    }

    /// The index resolves a wiki target exactly as the pure resolver does — the two are one
    /// rule in two languages, and this is what keeps them in step.
    func testTheIndexResolvesLinksTheSameWayThePureResolverDoes() throws {
        VaultFixture.writeCorpus(in: root)
        let index = try makeIndex()
        try reindex(index)
        let paths = index.allPaths()

        for target in ["Workshop/Kiln-Rebuild", "Terrasole", "terrasole",
                       "todo-list/Suppliers/Terrasole", "Overview", "Nowhere"] {
            XCTAssertEqual(index.resolve(target: target),
                           VaultWikiLink.resolve(target: target, among: paths),
                           "target \(target)")
        }
        XCTAssertNil(index.resolve(target: "Overview"), "and the ambiguous one still refuses")
    }

    /// Reopening the same database sees what the last run wrote. Obvious, and the thing
    /// that would silently break if the schema were recreated on every open.
    func testTheIndexSurvivesBeingClosedAndReopened() throws {
        VaultFixture.writeCorpus(in: root)
        let first = try makeIndex()
        try reindex(first)

        let second = try makeIndex()
        XCTAssertEqual(second.counts().fileCount, 5)
        XCTAssertFalse(VaultSearcher(index: second).base("bricks").hits.isEmpty)
    }
}
