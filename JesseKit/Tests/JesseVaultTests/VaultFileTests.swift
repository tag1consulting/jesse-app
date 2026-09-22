import XCTest
@testable import JesseVault

// The two file operations, and — more importantly — everything they REFUSE.
//
// The refusals are the load-bearing half. This target is pointed at a real, synced
// Obsidian vault on a real phone, so "it only ever appends, and only inside the
// folder that was picked" has to be a property that is asserted, not a property the
// code is believed to have.
final class VaultFileTests: XCTestCase {

    private var root: URL!
    private var file: VaultFile!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-vault-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = VaultFile(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func stage(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Read

    func testReadsUTF8Text() throws {
        try stage("Today.md", "# Today\n\n- something in Italian: perché\n")
        XCTAssertEqual(try file.read(relativePath: "Today.md"),
                       "# Today\n\n- something in Italian: perché\n")
    }

    func testReadsThroughASubdirectory() throws {
        try stage("Projects/Perseido/Perseido.md", "fiber")
        XCTAssertEqual(try file.read(relativePath: "Projects/Perseido/Perseido.md"), "fiber")
    }

    func testReadingAMissingFileThrowsRatherThanReturningEmpty() {
        XCTAssertThrowsError(try file.read(relativePath: "Nope.md")) { error in
            guard case VaultFileError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testNonUTF8BytesAreRefusedRatherThanMangled() throws {
        let url = root.appendingPathComponent("Binary.md")
        try Data([0xFF, 0xFE, 0xFF]).write(to: url)
        XCTAssertThrowsError(try file.read(relativePath: "Binary.md")) { error in
            XCTAssertEqual(error as? VaultFileError, .notUTF8("Binary.md"))
        }
    }

    // MARK: - The refusals

    func testRefusesParentEscape() {
        for path in ["../outside.md", "Projects/../../outside.md", "a/b/../../../outside.md"] {
            XCTAssertThrowsError(try file.resolved(path), "‘\(path)’ must be refused") { error in
                XCTAssertEqual(error as? VaultFileError, .escapesRoot(path))
            }
        }
    }

    func testRefusesAbsolutePaths() {
        for path in ["/etc/passwd", "/opt/elsewhere/vault/Today.md", "~/vault/Today.md"] {
            XCTAssertThrowsError(try file.resolved(path), "‘\(path)’ must be refused") { error in
                XCTAssertEqual(error as? VaultFileError, .absolutePath(path))
            }
        }
    }

    func testRefusesAnythingUnderADotDirectory() {
        for path in [".obsidian/workspace.json", ".obsidian/plugins/x/main.js", ".trash/note.md", "Projects/.obsidian/x.md"] {
            XCTAssertThrowsError(try file.resolved(path), "‘\(path)’ must be refused") { error in
                XCTAssertEqual(error as? VaultFileError, .forbiddenDotDirectory(path))
            }
        }
    }

    func testRefusesAnEmptyPath() {
        for path in ["", "   ", "/", "./"] {
            XCTAssertThrowsError(try file.resolved(path), "‘\(path)’ must be refused")
        }
    }

    func testRefusesASymlinkThatLeavesTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        // A link INSIDE the vault pointing at a directory outside it. Nothing in the
        // path string says so — no `..`, no leading slash — which is exactly why the
        // component rules alone are not enough.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape"),
                                                   withDestinationURL: outside)

        XCTAssertThrowsError(try file.read(relativePath: "Escape/secret.md")) { error in
            XCTAssertEqual(error as? VaultFileError, .escapesRoot("Escape/secret.md"))
        }
    }

    func testAPlainRelativePathResolvesInsideTheRoot() throws {
        let url = try file.resolved("Inbox/2026-09-22-phone-probe.md")
        XCTAssertTrue(url.path.hasPrefix(VaultScanner.normalizedDirectoryPath(root)))
        XCTAssertEqual(url.lastPathComponent, "2026-09-22-phone-probe.md")
    }

    func testLeadingDotSlashIsHarmlessRatherThanRefused() throws {
        try stage("Today.md", "hello")
        XCTAssertEqual(try file.read(relativePath: "./Today.md"), "hello")
    }

    // MARK: - Append

    func testAppendCreatesTheFileWhenItIsAbsent() throws {
        XCTAssertFalse(file.exists(relativePath: "Inbox/probe.md"))

        let size = try file.append(relativePath: "Inbox/probe.md", text: "- one\n")

        XCTAssertEqual(try file.read(relativePath: "Inbox/probe.md"), "- one\n")
        XCTAssertEqual(size, 6)
    }

    func testAppendCreatesAMissingParentDirectory() throws {
        try file.append(relativePath: "Inbox/nested/deeper/probe.md", text: "x\n")
        XCTAssertTrue(file.exists(relativePath: "Inbox/nested/deeper/probe.md"))
    }

    /// THE property that makes it safe to point this at a real vault: an append adds
    /// bytes at the end and changes none of the bytes that were already there.
    func testAppendOnlyEverGrowsAndLeavesTheExistingBytesIdentical() throws {
        let original = "# Inbox\n\n- an existing line nobody may lose\n"
        try stage("Inbox/probe.md", original)
        let before = try Data(contentsOf: root.appendingPathComponent("Inbox/probe.md"))

        let size = try file.append(relativePath: "Inbox/probe.md", text: "- appended\n")

        let after = try Data(contentsOf: root.appendingPathComponent("Inbox/probe.md"))
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertEqual(after.prefix(before.count), before,
                       "every byte that was there before must be there, unchanged, in the same place")
        XCTAssertEqual(after.count, size)
        XCTAssertEqual(try file.read(relativePath: "Inbox/probe.md"), original + "- appended\n")
    }

    func testRepeatedAppendsAccumulate() throws {
        try file.append(relativePath: "Inbox/probe.md", text: "- one\n")
        try file.append(relativePath: "Inbox/probe.md", text: "- two\n")
        try file.append(relativePath: "Inbox/probe.md", text: "- three\n")
        XCTAssertEqual(try file.read(relativePath: "Inbox/probe.md"), "- one\n- two\n- three\n")
    }

    func testAppendRefusesTheSamePathsReadDoes() {
        for path in ["../outside.md", "/etc/hosts", ".obsidian/workspace.json"] {
            XCTAssertThrowsError(try file.append(relativePath: path, text: "x"),
                                 "‘\(path)’ must be refused by append as well as by read")
        }
    }

    func testARefusedAppendWritesNothingAnywhere() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped-probe.md")
        try? FileManager.default.removeItem(at: outside)

        XCTAssertThrowsError(try file.append(relativePath: "../escaped-probe.md", text: "x"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "a refused append must not have created the file it refused to write")
    }
}
