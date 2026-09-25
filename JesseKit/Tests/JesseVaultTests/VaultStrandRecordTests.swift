import XCTest
@testable import JesseVault

/// THE STRANDS SCOPE AS A RECORD: the archive is in it, a section chip turns results into
/// lines of that section, an empty query with a chip is the cross strand log, and one
/// strand can be held. Driven over a real temporary vault and a real index, because every
/// claim here is about what the index hands back.
@MainActor
final class VaultStrandRecordTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private var databaseDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "jesse.vault.strands.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = VaultFixture.makeDirectory()
        databaseDirectory = VaultFixture.makeDirectory()
        writeStrands()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        VaultFixture.cleanUp(root)
        VaultFixture.cleanUp(databaseDirectory)
        try await super.tearDown()
    }

    /// Two live strands and one archived, in the real note shape. `bridge` is in a
    /// decision of each live strand, in a Later line, and in the archived strand's Status.
    private func writeStrands() {
        VaultFixture.write("""
            ---
            state: active
            updated: 2026-09-25
            ---
            # Kiln

            **Now:** Firing next week.

            ## Drafts
            - [ ] **K1** Rebuild the bridge wall of the kiln.
            ### Later
            - [ ] **K9** Replace the bridge thermocouple.
            ### Done
            - [x] 2026-09-20 **K0** Ordered the soft bricks.
            - [x] 2026-09-22 **K2** Cleared the shelf.

            ## Research

            ## Vault

            ## Decisions
            - 2026-09-01 The bridge wall is rebuilt in soft brick.
            - 2026-09-18 Fire to cone 6 only.
            - 2026-09-21 The bridge stays open during the bisque.

            ## Status
            - 2026-09-24 Bricks arrived.
            """, to: "Strands/Kiln.md", in: root)
        VaultFixture.write("""
            ---
            state: waiting
            updated: 2026-09-23
            ---
            # Garden

            **Now:** Waiting on seed.

            ## Drafts
            - [ ] **G1** Plant the beans.

            ## Decisions
            - 2026-09-10 The bridge over the ditch is replaced.
            - Undated ruling carried over from the old list.

            ## Status
            - 2026-09-12 Seed ordered.
            """, to: "Strands/Garden.md", in: root)
        VaultFixture.write("""
            ---
            state: done
            updated: 2026-08-30
            ---
            # Shed

            **Now:** Finished.

            ## Decisions
            - 2026-08-15 Tin roof.

            ## Status
            - 2026-08-30 The shed is built and the bridge beam is in.
            """, to: "Strands/archive/Shed.md", in: root)
        VaultFixture.write("# Elsewhere\n\n## Decisions\n- 2026-09-30 A bridge decision outside strands.\n",
                           to: "Projects/Elsewhere.md", in: root)
    }

    private func makeSource() throws -> VaultIndexSource {
        let folder = VaultFolder(defaults: defaults, key: "test.bookmark")
        try folder.adopt(url: root)
        return VaultIndexSource(folder: folder, container: databaseDirectory)
    }

    private func makeIndex() throws -> VaultIndex {
        let index = try VaultIndex(url: VaultIndex.databaseURL(forRoot: root,
                                                               in: databaseDirectory))
        let file = VaultFile(root: root)
        try index.reindex(scan: VaultScanner().scan(root: root),
                          read: { try file.read(relativePath: $0) })
        return index
    }

    private func makeModel() async throws -> VaultBrowserModel {
        let model = VaultBrowserModel(source: try makeSource(), debounce: .zero)
        await model.indexer.reindexNow()
        model.refresh()
        return model
    }

    // MARK: - The chunker already records the subheading

    /// No chunker change was needed: a chunk under `### Done` is headed `Done`, and the
    /// `## Drafts` body above `### Later` is headed `Drafts`.
    func testTheChunkerRecordsTheInnermostHeading() {
        let parse = VaultChunker.parse(relativePath: "Strands/K.md", text: """
            # K
            ## Drafts
            - [ ] one
            ### Later
            - [ ] two
            ### Done
            - [x] 2026-09-01 three
            ## Decisions
            - 2026-09-02 four
            """)
        XCTAssertEqual(parse.chunks.map(\.heading), ["", "Drafts", "Later", "Done", "Decisions"])
        XCTAssertEqual(parse.chunks.map(\.lineStart), [1, 2, 4, 6, 8])
    }

    // MARK: - Parsing one line

    func testAnEntryLosesItsMarkerCheckboxAndDate() {
        XCTAssertEqual(VaultStrandRecord.entry("- [x] 2026-09-24 **O1** Offline")?.date,
                       "2026-09-24")
        XCTAssertEqual(VaultStrandRecord.entry("- [x] 2026-09-24 **O1** Offline")?.text,
                       "**O1** Offline")
        XCTAssertEqual(VaultStrandRecord.entry("- 2026-09-01: A ruling")?.text, "A ruling")
        XCTAssertNil(VaultStrandRecord.entry("- [ ] **U1** Upgrade")?.date)
        XCTAssertNil(VaultStrandRecord.entry("## Decisions"))
        XCTAssertNil(VaultStrandRecord.entry("   "))
    }

    func testASlugResolvesLiveBeforeArchived() {
        let paths = ["Strands/archive/Kiln.md", "Strands/Kiln.md", "Strands/archive/Shed.md"]
        XCTAssertEqual(VaultStrandRecord.path(forSlug: "kiln", among: paths), "Strands/Kiln.md")
        XCTAssertEqual(VaultStrandRecord.path(forSlug: "Shed", among: paths),
                       "Strands/archive/Shed.md")
        XCTAssertEqual(VaultStrandRecord.path(forSlug: "Strands/Kiln.md", among: paths),
                       "Strands/Kiln.md")
        XCTAssertNil(VaultStrandRecord.path(forSlug: "Nope", among: paths))
    }

    // MARK: - The archive is in scope

    func testAnArchivedNoteIsInScopeAndListedUnderArchived() async throws {
        let model = try await makeModel()
        model.scope = .strands

        XCTAssertEqual(Set(model.recents.map(\.path)), ["Strands/Kiln.md", "Strands/Garden.md"])
        XCTAssertEqual(model.archivedRecents.map(\.path), ["Strands/archive/Shed.md"])
        XCTAssertTrue(model.strandNotes.contains { $0.path == "Strands/archive/Shed.md" })

        model.scope = .all
        XCTAssertTrue(model.archivedRecents.isEmpty, "the Archived header is the Strands scope's")
    }

    func testARowCaptionsEveryStateButActive() {
        XCTAssertNil(VaultBrowserView.stateCaption("active"))
        XCTAssertNil(VaultBrowserView.stateCaption(nil))
        XCTAssertEqual(VaultBrowserView.stateCaption("dormant"), "dormant")
        XCTAssertEqual(VaultBrowserView.stateCaption("waiting"), "waiting")
        XCTAssertEqual(VaultBrowserView.stateCaption("Done"), "done")
    }

    // MARK: - Each chip keeps its own section

    func testEachChipKeepsOnlyLinesUnderItsSection() throws {
        let searcher = VaultSearcher(index: try makeIndex(), scope: .strands)
        func lines(_ section: VaultStrandSection, _ query: String = "") -> [String] {
            searcher.sectionLines(query, section: section).map(\.text)
        }

        XCTAssertEqual(Set(lines(.drafts, "bridge")), ["**K1** Rebuild the bridge wall of the kiln."],
                       "Drafts is the body above ### Later, not Later itself")
        XCTAssertEqual(lines(.later, "bridge"), ["**K9** Replace the bridge thermocouple."])
        XCTAssertEqual(lines(.done), ["**K2** Cleared the shelf.", "**K0** Ordered the soft bricks."],
                       "### Done under ## Drafts is its own section")
        XCTAssertEqual(lines(.status, "bridge"),
                       ["The shed is built and the bridge beam is in."])
        XCTAssertFalse(lines(.decisions, "bridge").contains { $0.contains("outside strands") },
                       "a note outside Strands/ is never in a section view")
    }

    // MARK: - Lines, not files

    func testSectionModeDoesNotCollapseByFile() throws {
        let searcher = VaultSearcher(index: try makeIndex(), scope: .strands)
        let found = searcher.sectionLines("bridge", section: .decisions)

        XCTAssertEqual(found.map(\.path),
                       ["Strands/Kiln.md", "Strands/Garden.md", "Strands/Kiln.md"],
                       "two lines from one note both stay, newest first")
        XCTAssertEqual(found.map(\.date), ["2026-09-21", "2026-09-10", "2026-09-01"])
        XCTAssertEqual(found.first?.title, "Kiln")
        // The line each row opens the reader at is the line the text is on.
        let kiln = try String(contentsOf: root.appendingPathComponent("Strands/Kiln.md"),
                              encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(kiln[found[0].line - 1]),
                       "- 2026-09-21 The bridge stays open during the bisque.")

        let plain = VaultSearcher(index: try makeIndex(), scope: .strands).base("bridge")
        XCTAssertEqual(plain.hits.count, Set(plain.hits.map(\.path)).count,
                       "the All chip keeps one row per note")
    }

    func testAQueryNamingTheStrandKeepsItsWholeSection() throws {
        let searcher = VaultSearcher(index: try makeIndex(), scope: .strands)
        XCTAssertEqual(searcher.sectionLines("garden", section: .decisions).map(\.text),
                       ["The bridge over the ditch is replaced.",
                        "Undated ruling carried over from the old list."])
    }

    // MARK: - The empty query log

    func testTheEmptyQueryLogIsNewestFirstAndDatedOnly() throws {
        let searcher = VaultSearcher(index: try makeIndex(), scope: .strands)
        let log = searcher.sectionLines("", section: .decisions)

        XCTAssertEqual(log.map(\.date),
                       ["2026-09-21", "2026-09-18", "2026-09-10", "2026-09-01", "2026-08-15"])
        XCTAssertFalse(log.contains { $0.text.hasPrefix("Undated") })
    }

    func testTheLogIsCappedAtFifty() {
        let body = (1...60).map { "- 2026-01-\(String(format: "%02d", ($0 % 28) + 1)) Line \($0)" }
            .joined(separator: "\n")
        let chunk = VaultStoredChunk(path: "Strands/X.md", title: "X", heading: "Decisions",
                                     lineStart: 1, body: "## Decisions\n" + body)
        XCTAssertEqual(VaultStrandRecord.log([chunk], section: .decisions).count, 50)
    }

    // MARK: - One strand

    func testTheStrandFilterNarrowsRecentsAndSearch() async throws {
        let model = try await makeModel()
        model.strand = "Strands/Kiln.md"

        XCTAssertEqual(model.scope, .strands, "holding a strand implies the scope")
        XCTAssertEqual(model.recents.map(\.path), ["Strands/Kiln.md"])
        XCTAssertTrue(model.archivedRecents.isEmpty)

        model.query = "bridge"
        model.search()
        await model.awaitPendingSearch()
        XCTAssertEqual(Set(model.hits.map(\.path)), ["Strands/Kiln.md"])

        model.section = .decisions
        await model.awaitPendingSearch()
        XCTAssertEqual(model.sectionLines.map(\.date), ["2026-09-21", "2026-09-01"])
        XCTAssertTrue(model.hits.isEmpty)

        model.scope = .all
        XCTAssertNil(model.strand, "leaving the scope drops its narrowings")
        XCTAssertEqual(model.section, .all)
    }

    func testTheEntryPointOpensAStrandAndASection() async throws {
        let model = try await makeModel()
        model.query = "something typed"

        XCTAssertTrue(model.showStrand("shed", section: .status))
        await model.awaitPendingSearch()

        XCTAssertEqual(model.strand, "Strands/archive/Shed.md")
        XCTAssertEqual(model.section, .status)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.sectionLines.map(\.text),
                       ["The shed is built and the bridge beam is in."])

        XCTAssertFalse(model.showStrand("Nope"), "an unknown slug changes nothing")
        XCTAssertEqual(model.strand, "Strands/archive/Shed.md")
    }

    func testAnEmptyQueryWithAChipShowsTheLogThroughTheModel() async throws {
        let model = try await makeModel()
        model.section = .decisions
        await model.awaitPendingSearch()

        XCTAssertEqual(model.scope, .strands)
        XCTAssertEqual(model.sectionLines.first?.date, "2026-09-21")
        XCTAssertEqual(Set(model.sectionLines.map(\.path)),
                       ["Strands/Kiln.md", "Strands/Garden.md", "Strands/archive/Shed.md"])
    }
}
