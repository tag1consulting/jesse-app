import XCTest
@testable import Jesse
import JesseVault

/// THE ONE THING ONLY iOS CAN ANSWER: does the SQLite this phone links have FTS5 in it?
///
/// The whole offline search design rests on `sqlite3_compileoption_used("ENABLE_FTS5")`
/// being true in the libsqlite3 the app actually loads. Apple ships it on both platforms,
/// and the package's own tests measure that on macOS — but a macOS answer is a macOS
/// answer. This file is the same measurement inside the iOS simulator runtime, where the
/// iOS libsqlite3 is the one being linked, so a future OS that dropped FTS5 would fail a
/// test rather than quietly turn the Vault tab into a screen that finds nothing.
///
/// It is deliberately a real index over a real temporary folder rather than a flag check:
/// a compile option that is set and a virtual table that can be created and queried are
/// two different claims, and the second is the one the app depends on.
final class VaultIndexPlatformTests: XCTestCase {

    private var root: URL!
    private var container: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-ios-\(UUID().uuidString)", isDirectory: true)
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-ios-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: container)
        super.tearDown()
    }

    func testThisPlatformsSQLiteHasFTS5() {
        XCTAssertTrue(VaultIndex.fts5IsAvailable,
                      "iOS libsqlite3 has no FTS5 here; the vault index cannot be built")
    }

    /// Index two invented notes and search them, on iOS, end to end — including the
    /// diacritic folding and the prefix matching the tokenizer is configured for.
    func testAVaultCanBeIndexedAndSearchedOnThisPlatform() throws {
        let kiln = root.appendingPathComponent("Kiln.md")
        try "# Kiln notes\n\nThe café tiles came from Perugia.\n"
            .write(to: kiln, atomically: true, encoding: .utf8)
        let bike = root.appendingPathComponent("Bicycle.md")
        try "# Bicycle\n\nThe bottom bracket creaks.\n"
            .write(to: bike, atomically: true, encoding: .utf8)

        let index = try VaultIndex(url: VaultIndex.databaseURL(forRoot: root, in: container))
        let file = VaultFile(root: root)
        let report = try index.reindex(scan: VaultScanner().scan(root: root),
                                       read: { try file.read(relativePath: $0) })

        XCTAssertEqual(report.added, 2)
        let searcher = VaultSearcher(index: index)
        XCTAssertEqual(searcher.base("cafe tiles").hits.first?.path, "Kiln.md",
                       "diacritics fold on iOS too")
        XCTAssertEqual(searcher.base("brack").hits.first?.path, "Bicycle.md",
                       "and a prefix term matches a whole word")
        XCTAssertTrue(searcher.base("kiln bracket").hits.isEmpty,
                      "every token is still required")
    }
}
