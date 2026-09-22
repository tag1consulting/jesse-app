import XCTest
@testable import JesseVault

// The scanner, over a REAL temporary directory tree rather than a fake enumerator.
// The seam exists (and one test below uses it) but the rules being asserted here —
// what a `FileManager` enumerator hands back, what a dot directory looks like, what
// `/var` versus `/private/var` does to a relative path — are exactly the things a
// fake would get wrong in the same way the code does.
final class VaultScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-vault-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, _ contents: String = "note") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCountsEveryMarkdownFileAndTotalsItsBytes() throws {
        try write("Today.md", "abcde")
        try write("Projects/Perseido.md", "1234567890")
        try write("Knowledge/People/Someone.md", "xy")

        let scan = VaultScanner().scan(root: root)

        XCTAssertEqual(scan.fileCount, 3)
        XCTAssertEqual(scan.totalBytes, 5 + 10 + 2)
        XCTAssertEqual(Set(scan.files.map(\.relativePath)),
                       ["Today.md", "Projects/Perseido.md", "Knowledge/People/Someone.md"])
    }

    func testIgnoresEverythingThatIsNotMarkdown() throws {
        try write("Today.md")
        try write("diet-today.js")
        try write("Attachments/photo.png")
        try write("README")

        let scan = VaultScanner().scan(root: root)

        XCTAssertEqual(scan.files.map(\.relativePath), ["Today.md"])
    }

    func testSkipsDotDirectoriesIncludingObsidianAndTrash() throws {
        try write("Today.md")
        try write(".obsidian/workspace.md")
        try write(".obsidian/plugins/thing/readme.md")
        try write(".trash/deleted-note.md")
        try write(".git/COMMIT_EDITMSG.md")

        let scan = VaultScanner().scan(root: root)

        XCTAssertEqual(scan.files.map(\.relativePath), ["Today.md"],
                       "a dot directory is never walked into, however deep the markdown is")
    }

    func testSkipsFuseHiddenFiles() throws {
        try write("Today.md")
        try write(".fuse_hidden0000001500000001.md")
        try write("Projects/.fuse_hidden000000ab00000002.md")

        let scan = VaultScanner().scan(root: root)

        XCTAssertEqual(scan.files.map(\.relativePath), ["Today.md"],
                       "a .fuse_hidden entry is not a file, and a hit on one means 'not found'")
    }

    func testReportsModificationDates() throws {
        try write("Old.md")
        try write("New.md")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: root.appendingPathComponent("Old.md").path)

        let scan = VaultScanner().scan(root: root)
        let byPath = Dictionary(uniqueKeysWithValues: scan.files.map { ($0.relativePath, $0) })

        XCTAssertEqual(byPath["Old.md"]?.modified.timeIntervalSince1970 ?? 0, 1_000_000, accuracy: 1)
        XCTAssertGreaterThan(byPath["New.md"]?.modified ?? .distantPast, byPath["Old.md"]?.modified ?? .distantFuture)
    }

    func testMostRecentlyModifiedIsNewestFirstAndCapped() throws {
        for (index, name) in ["a.md", "b.md", "c.md", "d.md"].enumerated() {
            try write(name)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))],
                ofItemAtPath: root.appendingPathComponent(name).path)
        }

        let top = VaultScanner().scan(root: root).mostRecentlyModified(2)

        XCTAssertEqual(top.map(\.relativePath), ["d.md", "c.md"])
    }

    func testReportsItsOwnDurationAsAPositiveNumber() throws {
        try write("Today.md")
        let scan = VaultScanner().scan(root: root)
        XCTAssertGreaterThan(scan.duration, 0)
        XCTAssertLessThan(scan.duration, 30, "a three-file scan taking half a minute is a bug, not a slow disk")
    }

    func testAnEmptyVaultIsAnEmptyScanRatherThanAFailure() {
        let scan = VaultScanner().scan(root: root)
        XCTAssertEqual(scan.fileCount, 0)
        XCTAssertEqual(scan.totalBytes, 0)
        XCTAssertEqual(scan.unreadableCount, 0)
    }

    func testCaseInsensitiveMarkdownExtension() throws {
        try write("Shouting.MD")
        let scan = VaultScanner().scan(root: root)
        XCTAssertEqual(scan.files.map(\.relativePath), ["Shouting.MD"])
    }

    // MARK: - The rules as pure functions

    func testIsSkippedCoversEveryNamedCase() {
        XCTAssertTrue(VaultScanner.isSkipped(name: ".obsidian"))
        XCTAssertTrue(VaultScanner.isSkipped(name: ".trash"))
        XCTAssertTrue(VaultScanner.isSkipped(name: ".fuse_hidden0000001500000001"))
        XCTAssertTrue(VaultScanner.isSkipped(name: "fuse_hidden0000001500000001"),
                      "the dotless variant a FUSE mount can produce is skipped too")
        XCTAssertFalse(VaultScanner.isSkipped(name: "Today.md"))
        XCTAssertFalse(VaultScanner.isSkipped(name: "Projects"))
    }

    func testNormalizedDirectoryPathEndsInExactlyOneSlash() {
        let withSlash = VaultScanner.normalizedDirectoryPath(URL(fileURLWithPath: "/tmp/vault/"))
        let without = VaultScanner.normalizedDirectoryPath(URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(withSlash, without)
        XCTAssertTrue(withSlash.hasSuffix("/"))
        XCTAssertFalse(withSlash.hasSuffix("//"))
    }

    func testASiblingWhoseNameStartsTheSameIsNotInsideTheRoot() {
        let prefixes = VaultScanner.rootPrefixes(URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertNil(VaultScanner.relativePath(of: URL(fileURLWithPath: "/tmp/vault-backup/Today.md"),
                                               underAnyOf: prefixes),
                     "/tmp/vault-backup must never look like it is inside /tmp/vault")
        XCTAssertEqual(VaultScanner.relativePath(of: URL(fileURLWithPath: "/tmp/vault/Today.md"),
                                                 underAnyOf: prefixes),
                       "Today.md")
    }

    /// The scan's per-file path work must ask the filesystem NOTHING. A root that is
    /// itself a symlink is handled by offering both prefixes up front, once, rather
    /// than by resolving every file — which is the difference the duration measures.
    func testASymlinkedRootStillProducesRelativePathsWithoutResolvingEachFile() throws {
        try write("Today.md", "abc")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-vault-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }

        let scan = VaultScanner().scan(root: link)

        XCTAssertEqual(scan.files.map(\.relativePath), ["Today.md"])
        XCTAssertEqual(scan.unreadableCount, 0, "a symlinked root must not make every file unreadable")
    }

    func testRootPrefixesOffersBothFormsOnlyWhenTheyDiffer() {
        let plain = VaultScanner.rootPrefixes(URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertTrue(plain.allSatisfy { $0.hasSuffix("/") })
        XCTAssertLessThanOrEqual(plain.count, 2)
        XCTAssertFalse(plain.isEmpty)
    }

    // MARK: - Through the seam

    /// The one case a real directory cannot stage: an entry the enumerator produced
    /// whose attributes could not be read. It must be COUNTED, not silently dropped —
    /// a scan that loses half the vault must not look clean.
    func testEntriesWithNoAttributesAreCountedAsUnreadable() {
        let fake = FakeEnumerator(entries: [
            VaultDirectoryEntry(url: URL(fileURLWithPath: "/tmp/vault/Good.md"),
                                isDirectory: false, modified: Date(), size: 12),
            VaultDirectoryEntry(url: URL(fileURLWithPath: "/tmp/vault/Broken.md"),
                                isDirectory: false, modified: nil, size: nil),
        ])

        let scan = VaultScanner(enumerator: fake).scan(root: URL(fileURLWithPath: "/tmp/vault"))

        XCTAssertEqual(scan.fileCount, 1)
        XCTAssertEqual(scan.unreadableCount, 1)
    }

    /// A skipped DIRECTORY must be refused, not merely ignored: not descending into
    /// `.obsidian` is most of the difference between a fast scan and a slow one, and
    /// only the seam can prove the scanner actually said so.
    func testADotDirectoryIsRefusedRatherThanWalked() {
        let fake = FakeEnumerator(entries: [
            VaultDirectoryEntry(url: URL(fileURLWithPath: "/tmp/vault/.obsidian"),
                                isDirectory: true, modified: Date(), size: nil),
        ])

        _ = VaultScanner(enumerator: fake).scan(root: URL(fileURLWithPath: "/tmp/vault"))

        XCTAssertEqual(fake.skipped, ["/tmp/vault/.obsidian"])
    }
}

/// Hands back a fixed list of entries and records which of them the scanner refused
/// to descend into.
private final class FakeEnumerator: VaultDirectoryEnumerating, @unchecked Sendable {
    let entries: [VaultDirectoryEntry]
    private(set) var skipped: [String] = []

    init(entries: [VaultDirectoryEntry]) { self.entries = entries }

    func enumerate(root: URL, visit: (VaultDirectoryEntry, _ skipDescendants: () -> Void) -> Void) {
        for entry in entries {
            visit(entry) { self.skipped.append(entry.url.path) }
        }
    }
}
