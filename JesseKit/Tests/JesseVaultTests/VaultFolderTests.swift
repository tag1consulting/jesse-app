import XCTest
@testable import JesseVault

// The bookmark round trip, against a real temporary directory and an isolated
// `UserDefaults` suite.
//
// It is a real bookmark, taken and resolved through the same two platform-
// conditional calls the app uses, which is the only way this can be evidence for the
// claim being tested. What it CANNOT prove is the one thing only the device can:
// that a document-picker URL's bookmark survives a reboot. That is why this prompt
// ends with a checklist for a phone rather than with this file.
final class VaultFolderTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "jesse.vault.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-vault-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolder() -> VaultFolder {
        VaultFolder(defaults: defaults, key: "test.bookmark")
    }

    func testAFreshDeviceHasNoFolder() {
        let folder = makeFolder()
        XCTAssertFalse(folder.hasBookmark)
        guard case .notSet = folder.status else {
            return XCTFail("expected .notSet, got \(folder.status.display)")
        }
    }

    func testAdoptThenResolveReturnsTheSameDirectory() throws {
        let folder = makeFolder()
        try folder.adopt(url: directory)

        XCTAssertTrue(folder.hasBookmark)
        let resolved = try XCTUnwrap(folder.resolve().url)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().standardizedFileURL.path,
                       directory.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// The whole point of a bookmark rather than a remembered path: a SECOND,
    /// independently constructed `VaultFolder` — which is what the next launch is —
    /// finds the same folder with nothing handed to it but `UserDefaults`.
    func testASecondInstanceFindsTheFolderWithNothingButTheStoredBookmark() throws {
        try makeFolder().adopt(url: directory)

        let nextLaunch = VaultFolder(defaults: defaults, key: "test.bookmark")

        let resolved = try XCTUnwrap(nextLaunch.resolve().url)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path,
                       directory.resolvingSymlinksInPath().path)
    }

    func testWithAccessHandsOverAUsableDirectory() throws {
        try "# Today\n".write(to: directory.appendingPathComponent("Today.md"),
                              atomically: true, encoding: .utf8)
        let folder = makeFolder()
        try folder.adopt(url: directory)

        let text = try folder.withAccess { root in
            try VaultFile(root: root).read(relativePath: "Today.md")
        }

        XCTAssertEqual(text, "# Today\n")
    }

    func testWithAccessScansThroughTheBookmark() throws {
        try "a".write(to: directory.appendingPathComponent("One.md"), atomically: true, encoding: .utf8)
        try "bb".write(to: directory.appendingPathComponent("Two.md"), atomically: true, encoding: .utf8)
        let folder = makeFolder()
        try folder.adopt(url: directory)

        let scan = try folder.withAccess { VaultScanner().scan(root: $0) }

        XCTAssertEqual(scan.fileCount, 2)
        XCTAssertEqual(scan.totalBytes, 3)
    }

    func testWithAccessThrowsWhenNoFolderWasEverPicked() {
        XCTAssertThrowsError(try makeFolder().withAccess { _ in 1 }) { error in
            guard case VaultFolderError.noFolderHeld = error else {
                return XCTFail("expected .noFolderHeld, got \(error)")
            }
        }
    }

    func testAThrowInsideWithAccessPropagatesRatherThanBeingSwallowed() throws {
        let folder = makeFolder()
        try folder.adopt(url: directory)

        XCTAssertThrowsError(try folder.withAccess { root in
            try VaultFile(root: root).read(relativePath: "DoesNotExist.md")
        })
    }

    func testForgetClearsTheBookmarkAndLeavesTheFolderAlone() throws {
        try "x".write(to: directory.appendingPathComponent("Today.md"), atomically: true, encoding: .utf8)
        let folder = makeFolder()
        try folder.adopt(url: directory)

        folder.forget()

        XCTAssertFalse(folder.hasBookmark)
        guard case .notSet = folder.status else {
            return XCTFail("expected .notSet after forget, got \(folder.status.display)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Today.md").path),
                      "forgetting the bookmark must never touch the vault")
    }

    func testAFolderThatHasBeenDeletedReportsStaleRatherThanReady() throws {
        let folder = makeFolder()
        try folder.adopt(url: directory)
        try FileManager.default.removeItem(at: directory)

        switch folder.resolve() {
        case .ready(let url):
            XCTFail("a deleted folder must not report ready (\(url.path))")
        case .notSet:
            XCTFail("the bookmark is still stored; this is not .notSet")
        case .stale, .unreadable:
            break   // either is an honest answer to "the folder is gone"
        }
    }

    func testTwoFoldersUnderDifferentKeysDoNotSeeEachOther() throws {
        let a = VaultFolder(defaults: defaults, key: "key.a")
        let b = VaultFolder(defaults: defaults, key: "key.b")
        try a.adopt(url: directory)

        XCTAssertTrue(a.hasBookmark)
        XCTAssertFalse(b.hasBookmark)
    }

    /// A bookmark that cannot be resolved — on macOS most often because the app's
    /// code identity changed, not because the bytes rotted — must tell the reader what
    /// to DO, not quote a Foundation error and stop.
    func testEveryFailingStatusNamesTheSameActionAndAsksToBePicked() {
        let states: [VaultFolderStatus] = [
            .notSet,
            .stale,
            .unreadable("The file couldn’t be opened because it isn’t in the correct format."),
        ]
        for state in states {
            XCTAssertTrue(state.needsPicking, "\(state.display) is not a state anything can be read in")
            XCTAssertFalse(state.isReady)
        }
        XCTAssertTrue(VaultFolderStatus.stale.display.contains("pick the folder again"))
        XCTAssertTrue(VaultFolderStatus.unreadable("whatever").display.hasPrefix("Pick the folder again"))
        XCTAssertFalse(VaultFolderStatus.ready(URL(fileURLWithPath: "/tmp/v")).needsPicking)
    }

    func testStatusDisplayNamesTheFolder() throws {
        let folder = makeFolder()
        try folder.adopt(url: directory)
        XCTAssertTrue(folder.status.display.hasPrefix("Ready — "))
        XCTAssertTrue(folder.status.isReady)
    }
}
