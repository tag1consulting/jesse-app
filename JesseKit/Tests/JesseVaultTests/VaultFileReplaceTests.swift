import XCTest
@testable import JesseVault

// THE GUARDED WRITE, AND THE SHAPE IT GIVES BACK.
//
// `replace` is the only thing in this app that can change a byte inside somebody's note,
// so the tests that matter here are the ones that assert it DID NOT: a stale stamp leaves
// the file identical, a refused path leaves the file identical, and a CRLF note stays a
// CRLF note. Every fixture is invented; this repository is public.
final class VaultFileReplaceTests: XCTestCase {

    private var root: URL!
    private var file: VaultFile!

    override func setUp() {
        super.setUp()
        root = VaultFixture.makeDirectory()
        file = VaultFile(root: root)
    }

    override func tearDown() {
        VaultFixture.cleanUp(root)
        super.tearDown()
    }

    // MARK: - The happy path

    func testReplaceWithMatchingStampWritesAndReturnsTheNewStamp() throws {
        VaultFixture.write("# Kiln\n\nThe arch is sound.\n", to: "Notes/Kiln.md", in: root)
        let read = try file.readStamped(relativePath: "Notes/Kiln.md")

        let updated = "# Kiln\n\nThe arch is cracked.\n"
        let stamp = try file.replace(relativePath: "Notes/Kiln.md", expected: read.stamp,
                                     with: updated)

        XCTAssertEqual(try file.read(relativePath: "Notes/Kiln.md"), updated)
        XCTAssertEqual(stamp, VaultFileStamp(text: updated))
        // The returned stamp must be usable as the NEXT expectation without re-reading —
        // that is what lets the editor save twice in a row.
        XCTAssertEqual(stamp, try file.readStamped(relativePath: "Notes/Kiln.md").stamp)
    }

    func testReadStampedAndReplaceAgreeOnTheStamp() throws {
        VaultFixture.write("one\ntwo\n", to: "A.md", in: root)
        let read = try file.readStamped(relativePath: "A.md")
        XCTAssertEqual(read.stamp, VaultFileStamp(text: read.text))
        XCTAssertEqual(read.stamp.bytes, 8)
    }

    func testTheSecondWriteInARowUsesTheReturnedStamp() throws {
        VaultFixture.write("a\n", to: "A.md", in: root)
        var stamp = try file.readStamped(relativePath: "A.md").stamp
        stamp = try file.replace(relativePath: "A.md", expected: stamp, with: "b\n")
        stamp = try file.replace(relativePath: "A.md", expected: stamp, with: "c\n")
        XCTAssertEqual(try file.read(relativePath: "A.md"), "c\n")
    }

    // MARK: - The guard

    func testStaleStampThrowsAndLeavesTheFileByteIdentical() throws {
        let original = "# Kiln\n\n- [ ] order the anchors\n"
        VaultFixture.write(original, to: "Notes/Kiln.md", in: root)
        let read = try file.readStamped(relativePath: "Notes/Kiln.md")

        // Somebody else writes — the Studio's autocommit, a sync, Obsidian on the Mac.
        let theirs = "# Kiln\n\n- [ ] order the anchors\n- [ ] and the castable\n"
        VaultFixture.write(theirs, to: "Notes/Kiln.md", in: root)

        XCTAssertThrowsError(try file.replace(relativePath: "Notes/Kiln.md",
                                              expected: read.stamp,
                                              with: "# Kiln\n\n- [x] order the anchors\n")) {
            XCTAssertEqual($0 as? VaultFileError, .changedSinceRead("Notes/Kiln.md"))
        }
        // THE POINT OF THE WHOLE TYPE: their write is still there, ours is not.
        XCTAssertEqual(try file.read(relativePath: "Notes/Kiln.md"), theirs)
    }

    /// A same-LENGTH edit is the case a size check alone would wave through, and it is not
    /// hypothetical: it is exactly what ticking a box on the Studio looks like.
    func testASameLengthEditElsewhereIsStillCaught() throws {
        VaultFixture.write("- [ ] one\n- [ ] two\n", to: "T.md", in: root)
        let read = try file.readStamped(relativePath: "T.md")
        VaultFixture.write("- [ ] one\n- [x] two\n", to: "T.md", in: root)

        XCTAssertThrowsError(try file.replace(relativePath: "T.md", expected: read.stamp,
                                              with: "- [x] one\n- [ ] two\n"))
        XCTAssertEqual(try file.read(relativePath: "T.md"), "- [ ] one\n- [x] two\n")
    }

    func testAMissingFileIsRefusedRatherThanCreated() throws {
        let stamp = VaultFileStamp(text: "")
        XCTAssertThrowsError(try file.replace(relativePath: "Gone.md", expected: stamp,
                                              with: "hello\n")) {
            XCTAssertEqual($0 as? VaultFileError, .missing("Gone.md"))
        }
        XCTAssertFalse(file.exists(relativePath: "Gone.md"))
    }

    /// The temporary file `replace` writes through must never survive a failure, and must
    /// never be left in somebody's vault for Obsidian to show as a note.
    func testNoTemporaryFileIsLeftBehind() throws {
        VaultFixture.write("a\n", to: "A.md", in: root)
        let read = try file.readStamped(relativePath: "A.md")
        _ = try file.replace(relativePath: "A.md", expected: read.stamp, with: "b\n")
        // And after a refused one.
        _ = try? file.replace(relativePath: "A.md", expected: read.stamp, with: "c\n")

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(left.filter { $0.hasPrefix(".jesse-write-") }, [])
        XCTAssertEqual(left.sorted(), ["A.md"])
    }

    /// A write that cannot land leaves the original intact — here by making the write fail
    /// at the only point it can, the replacement of a file that has become a directory's
    /// worth of trouble. The assertion that matters is the last one.
    func testAFailedReplacementLeavesTheOriginal() throws {
        let original = "the original\n"
        VaultFixture.write(original, to: "A.md", in: root)
        let read = try file.readStamped(relativePath: "A.md")

        // Make the containing directory read-only so the temporary write fails.
        let attributes = [FileAttributeKey.posixPermissions: NSNumber(value: Int16(0o500))]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: root.path)
        }

        XCTAssertThrowsError(try file.replace(relativePath: "A.md", expected: read.stamp,
                                              with: "something else\n"))
        XCTAssertEqual(try file.read(relativePath: "A.md"), original)
    }

    // MARK: - Shape

    func testCRLFInCRLFOut() throws {
        let original = "# One\r\n\r\n- [ ] two\r\n"
        VaultFixture.write(original, to: "W.md", in: root)
        let read = try file.readStamped(relativePath: "W.md")
        XCTAssertEqual(VaultTextShape.of(read.text).lineEnding, .crlf)

        let edited = VaultCheckboxEdit.setting(read.text, line: 3, checked: true)
        _ = try file.replace(relativePath: "W.md", expected: read.stamp,
                             with: try XCTUnwrap(edited))

        let after = try file.read(relativePath: "W.md")
        XCTAssertEqual(after, "# One\r\n\r\n- [x] two\r\n")
        XCTAssertTrue(after.utf8.contains(0x0D), "the file must still be CRLF")
    }

    func testLFInLFOut() throws {
        VaultFixture.write("# One\n\n- [ ] two\n", to: "U.md", in: root)
        let read = try file.readStamped(relativePath: "U.md")
        let edited = try XCTUnwrap(VaultCheckboxEdit.setting(read.text, line: 3, checked: true))
        _ = try file.replace(relativePath: "U.md", expected: read.stamp, with: edited)

        let after = try file.read(relativePath: "U.md")
        XCTAssertEqual(after, "# One\n\n- [x] two\n")
        XCTAssertFalse(after.utf8.contains(0x0D))
    }

    func testATrailingNewlineIsKeptAndNeverDoubled() throws {
        VaultFixture.write("ends with one\n", to: "N.md", in: root)
        let read = try file.readStamped(relativePath: "N.md")
        let shape = VaultTextShape.of(read.text)
        // The shape of an edit that dropped the final newline gets exactly one back.
        _ = try file.replace(relativePath: "N.md", expected: read.stamp,
                             with: shape.applied(to: "changed"))
        XCTAssertEqual(try file.read(relativePath: "N.md"), "changed\n")
    }

    func testAFileWithNoTrailingNewlineDoesNotGrowOne() throws {
        VaultFixture.write("no newline at the end", to: "N.md", in: root)
        let read = try file.readStamped(relativePath: "N.md")
        XCTAssertFalse(VaultTextShape.of(read.text).endsWithNewline)
        let shape = VaultTextShape.of(read.text)
        _ = try file.replace(relativePath: "N.md", expected: read.stamp,
                             with: shape.applied(to: "still none"))
        XCTAssertEqual(try file.read(relativePath: "N.md"), "still none")
    }

    // MARK: - Paths

    func testDotDirectoriesAndEscapesAreRefused() throws {
        let stamp = VaultFileStamp(text: "")
        for path in [".obsidian/workspace.json", "../outside.md", "/etc/passwd",
                     "~/secrets.md", "Notes/../../up.md"] {
            XCTAssertThrowsError(try file.replace(relativePath: path, expected: stamp,
                                                  with: "x"),
                                 "“\(path)” must never be writable")
        }
    }

}
