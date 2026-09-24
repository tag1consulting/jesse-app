import XCTest
@testable import JesseVault

/// THE VAULT TAB'S SCOPE: what the `Strands` scope includes, what it orders by, and
/// that the predicate is in the QUERY rather than applied to its answer.
///
/// Driven over a real temporary vault for `VaultIndexTests`' reason: the claim being
/// made here is about SQL, and a fake would prove nothing about it.
final class VaultScopeTests: XCTestCase {

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

    @discardableResult
    private func reindex(_ index: VaultIndex) throws -> VaultReindexReport {
        let scan = VaultScanner().scan(root: root)
        let file = VaultFile(root: root)
        return try index.reindex(scan: scan, read: { try file.read(relativePath: $0) })
    }

    // MARK: - Membership

    func testWhatTheStrandsScopeIncludes() {
        let scope = VaultSearchScope.strands
        XCTAssertTrue(scope.includes("Strands/Kiln-Rebuild.md"))
        XCTAssertFalse(scope.includes("Projects/Kiln-Rebuild.md"))
        // A finished strand is MOVED to the archive, and a board that listed its own
        // archive would grow without bound while saying less every month.
        XCTAssertFalse(scope.includes("Strands/archive/Old-Thing.md"))
        XCTAssertTrue(VaultSearchScope.all.includes("Strands/archive/Old-Thing.md"))
        XCTAssertTrue(VaultSearchScope.all.includes("anything/at/all.md"))
    }

    // MARK: - The query

    /// **The predicate is in the SQL.** Thirty-one notes outside the folder, all newer
    /// than the one inside it: a `LIMIT 30` applied before a Swift-side filter would
    /// answer with nothing at all.
    func testRecentsUnderAPrefixAreNotJustTheUnscopedTopThirty() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        VaultFixture.write("# A strand", to: "Strands/Kiln-Rebuild.md", in: root)
        VaultFixture.touch("Strands/Kiln-Rebuild.md", in: root, date: old)
        for index in 0..<31 {
            let path = "Projects/Note-\(index).md"
            VaultFixture.write("# Note \(index)", to: path, in: root)
            VaultFixture.touch(path, in: root, date: old.addingTimeInterval(Double(index + 1) * 60))
        }

        let index = try makeIndex()
        try reindex(index)

        XCTAssertEqual(index.recentFiles(limit: 30, underPrefix: "Strands/").map(\.path),
                       ["Strands/Kiln-Rebuild.md"])
        XCTAssertFalse(index.recentFiles(limit: 30).contains { $0.path.hasPrefix("Strands/") },
                       "the unscoped top thirty is all the newer notes, which is the point")
    }

    /// A search, likewise: the word is in a note inside the folder and in fifty outside
    /// it, and the scoped query finds the one.
    func testSearchUnderAPrefix() throws {
        VaultFixture.write("# Kiln\n\nThe bisque schedule.", to: "Strands/Kiln.md", in: root)
        for i in 0..<50 {
            VaultFixture.write("# Other \(i)\n\nThe bisque schedule.",
                               to: "Projects/Other-\(i).md", in: root)
        }
        let index = try makeIndex()
        try reindex(index)

        let scoped = index.search(expression: "bisque", limit: 50, underPrefix: "Strands/")
        XCTAssertEqual(scoped.map(\.path), ["Strands/Kiln.md"])
        XCTAssertTrue(index.search(expression: "bisque", limit: 200).count > 1)
    }

    /// The searcher carries the scope into the query and drops the archive from what
    /// comes back.
    func testTheSearcherHonoursTheScope() throws {
        VaultFixture.write("# Live\n\nThe bisque schedule.", to: "Strands/Live.md", in: root)
        VaultFixture.write("# Done\n\nThe bisque schedule.",
                           to: "Strands/archive/Done.md", in: root)
        VaultFixture.write("# Elsewhere\n\nThe bisque schedule.",
                           to: "Projects/Elsewhere.md", in: root)
        let index = try makeIndex()
        try reindex(index)

        let scoped = VaultSearcher(index: index, scope: .strands).base("bisque")
        XCTAssertEqual(scoped.hits.map(\.path), ["Strands/Live.md"])

        let all = VaultSearcher(index: index, scope: .all).base("bisque")
        XCTAssertEqual(Set(all.hits.map(\.path)),
                       ["Strands/Live.md", "Strands/archive/Done.md", "Projects/Elsewhere.md"])
    }

    /// A folder name carrying a `%` or a `_` must not widen the `LIKE`.
    func testAWildcardInAPrefixIsEscaped() {
        XCTAssertEqual(VaultIndex.likePrefix("Strands/"), "Strands/%")
        XCTAssertEqual(VaultIndex.likePrefix("a_b%/"), "a\\_b\\%/%")
    }

    // MARK: - The order

    /// **A strand's own `updated:` outranks its mtime.** On a synced folder the mtime is
    /// routinely a lie — a sync that rewrites a note stamps it today without a word of it
    /// having changed — and the frontmatter is a claim somebody made about the work.
    func testStrandsAreOrderedByTheirFrontmatterStamp() {
        let recent = Date(timeIntervalSince1970: 1_790_000_000)
        let files = [
            VaultIndexedFile(path: "Strands/Touched-By-Sync.md", title: "Touched",
                             modified: recent, size: 10),
            VaultIndexedFile(path: "Strands/Actually-Moved.md", title: "Moved",
                             modified: recent.addingTimeInterval(-86_400 * 30), size: 10),
        ]
        let ordered = VaultStrandOrder.ordered(files, updated: [
            "Strands/Touched-By-Sync.md": "2026-01-02",
            "Strands/Actually-Moved.md": "2026-09-24",
        ])
        XCTAssertEqual(ordered.map(\.path),
                       ["Strands/Actually-Moved.md", "Strands/Touched-By-Sync.md"])
    }

    /// A note with no stamp, or an unusable one, falls back to its mtime rather than
    /// sinking to the bottom: "no stamp" is a bookkeeping gap the audit already reports,
    /// not a claim that the work is ancient.
    func testANoteWithNoUsableStampFallsBackToItsModificationTime() {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        let files = [
            VaultIndexedFile(path: "Strands/Stamped.md", title: "S",
                             modified: newest.addingTimeInterval(-86_400 * 400), size: 10),
            VaultIndexedFile(path: "Strands/Unstamped.md", title: "U", modified: newest, size: 10),
            VaultIndexedFile(path: "Strands/Broken.md", title: "B",
                             modified: newest.addingTimeInterval(-60), size: 10),
        ]
        let ordered = VaultStrandOrder.ordered(files, updated: [
            "Strands/Stamped.md": "2026-01-02",
            "Strands/Broken.md": "soon",
        ])
        XCTAssertEqual(ordered.map(\.path),
                       ["Strands/Unstamped.md", "Strands/Broken.md", "Strands/Stamped.md"])
    }

    /// Stable: two notes stamped the same day keep one order rather than swapping on
    /// every redraw.
    func testTheOrderIsStable() {
        let same = Date(timeIntervalSince1970: 1_790_000_000)
        let files = (0..<5).map {
            VaultIndexedFile(path: "Strands/N\($0).md", title: "N\($0)", modified: same, size: 1)
        }
        let updated = Dictionary(uniqueKeysWithValues: files.map { ($0.path, "2026-09-24") })
        XCTAssertEqual(VaultStrandOrder.ordered(files, updated: updated).map(\.path),
                       VaultStrandOrder.ordered(files.reversed(), updated: updated).map(\.path))
    }

    // MARK: - Reading the stamp

    func testFrontmatterValue() {
        let note = """
        ---
        title: The Kiln Rebuild
        group: personal
        updated: 2026-09-24
        state: "active"
        ---

        # Kiln notes

        updated: 1999-01-01
        """
        XCTAssertEqual(VaultFrontmatter.value(for: "updated", in: note), "2026-09-24")
        XCTAssertEqual(VaultFrontmatter.value(for: "state", in: note), "active",
                       "quotes are dropped")
        XCTAssertEqual(VaultFrontmatter.value(for: "Updated", in: note), "2026-09-24",
                       "the key match folds case, as the vault writes it both ways")
        XCTAssertNil(VaultFrontmatter.value(for: "missing", in: note))
        // A line after the closing fence is BODY, not frontmatter. A scanner that read
        // on would take a sentence out of the note as the note's own stamp.
        XCTAssertNil(VaultFrontmatter.value(for: "updated", in: "# No frontmatter\n\nupdated: x"))
        XCTAssertNil(VaultFrontmatter.value(for: "updated", in: ""))
    }

    /// The heading says what the list is actually ordered by. A `Recently changed` over
    /// a list sorted by frontmatter would be the one line on the screen that lies.
    func testTheRecentsHeadingNamesTheOrder() {
        XCTAssertEqual(VaultBrowserView.recentsHeading(.all), "Recently changed")
        XCTAssertEqual(VaultBrowserView.recentsHeading(.strands), "Recently updated")
    }
}
