import XCTest
@testable import JesseVault

// THE FILE SHAPE, AND EVERYTHING THE CAPTURE REFUSES.
//
// This is the first code in the app that writes into the vault on a person's own say-so
// rather than the bridge's, so the properties that make that safe have to be asserted
// rather than believed: it only ever appends, it only ever touches one path, a refused
// capture leaves nothing behind, and the date on the file is the DEVICE's date.
final class InboxCaptureTests: XCTestCase {

    private var root: URL!
    private var file: VaultFile!
    private var capture: InboxCapture!

    /// Rome, which is what makes the midnight test mean something: at 23:30 local on
    /// 23 September it is already 21:30 UTC — and at 00:30 local on the 24th, UTC is still
    /// on the 23rd.
    private let rome = TimeZone(identifier: "Europe/Rome")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-inbox-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = VaultFile(root: root)
        capture = InboxCapture(file: file, platform: .phone)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fixed instant: 2026-09-23 14:32 in Rome.
    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The file

    func testCreatesTheFileWithItsHeading() throws {
        let when = instant("2026-09-23T14:32:07+02:00")
        let write = try capture.capture(text: "order the bricks", device: "Jeremy-iPhone",
                                        now: when, timeZone: rome)

        XCTAssertEqual(write.relativePath, "Inbox/2026-09-23-phone.md")
        XCTAssertTrue(write.createdFile)
        XCTAssertEqual(try contents(write.relativePath), """
            # Phone captures 2026-09-23

            - 14:32 (Jeremy-iPhone): order the bricks

            """)
    }

    func testTheMacWritesItsOwnFileAndItsOwnHeading() throws {
        let mac = InboxCapture(file: file, platform: .mac)
        let when = instant("2026-09-23T14:32:07+02:00")
        let write = try mac.capture(text: "order the bricks", device: "studio",
                                    now: when, timeZone: rome)

        XCTAssertEqual(write.relativePath, "Inbox/2026-09-23-mac.md")
        XCTAssertTrue(try contents(write.relativePath).hasPrefix("# Mac captures 2026-09-23"))
        // The phone's file for the same day is a DIFFERENT file, which is the whole reason
        // the suffix exists: two devices capturing on one day must never append into one
        // file and race.
        _ = try capture.capture(text: "and the arch", device: "phone",
                                now: when, timeZone: rome)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("Inbox/2026-09-23-phone.md").path))
    }

    func testASecondCaptureONLYGrowsTheFile() throws {
        let when = instant("2026-09-23T14:32:07+02:00")
        let first = try capture.capture(text: "order the bricks", device: "phone",
                                        now: when, timeZone: rome)
        let before = try Data(contentsOf: root.appendingPathComponent(first.relativePath))

        let second = try capture.capture(text: "measure the arch", device: "phone",
                                         now: instant("2026-09-23T16:05:00+02:00"),
                                         timeZone: rome)
        XCTAssertFalse(second.createdFile)
        XCTAssertEqual(second.relativePath, first.relativePath)

        let after = try Data(contentsOf: root.appendingPathComponent(first.relativePath))
        // BYTE COMPARE, not a line count: the property being asserted is that the first
        // capture's bytes are still there, unchanged, at the front of the file.
        XCTAssertEqual(after.prefix(before.count), before)
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertEqual(second.fileBytes, after.count)
        // The heading was written once.
        XCTAssertEqual(try contents(first.relativePath)
            .components(separatedBy: "# Phone captures").count - 1, 1)
    }

    // MARK: - The entry

    func testEntryFormat() throws {
        XCTAssertEqual(
            try InboxCapture.entry(text: "  order the bricks  ", device: "Jeremy-iPhone",
                                   now: instant("2026-09-23T09:05:00+02:00"), timeZone: rome),
            "- 09:05 (Jeremy-iPhone): order the bricks\n")
    }

    func testEntryWithAboutCarriesThePathInACodeSpan() throws {
        let entry = try InboxCapture.entry(text: "the bricks were never ordered",
                                           about: "Workshop/Kiln-Rebuild.md",
                                           device: "phone",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry,
            "- 09:05 (phone): `Workshop/Kiln-Rebuild.md` the bricks were never ordered\n")
    }

    func testAnAboutThatIsNotAVaultPathIsDroppedRatherThanWritten() throws {
        for bad in ["/etc/passwd", "../outside/Note.md", ".obsidian/workspace.md",
                    "Note`with-a-backtick.md", "   "] {
            let entry = try InboxCapture.entry(text: "a thought", about: bad, device: "phone",
                                               now: instant("2026-09-23T09:05:00+02:00"),
                                               timeZone: rome)
            XCTAssertEqual(entry, "- 09:05 (phone): a thought\n",
                           "\(bad) should not reach the line")
        }
    }

    func testMultiLineTextIndentsUnderItsOwnBullet() throws {
        let entry = try InboxCapture.entry(text: "kiln notes\nbricks: forty\nburner: Marta",
                                           device: "phone",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, """
            - 09:05 (phone): kiln notes
              bricks: forty
              burner: Marta

            """)
    }

    func testABlankLineInsideACaptureStaysBlankRatherThanBecomingWhitespace() throws {
        let entry = try InboxCapture.entry(text: "first\n\nsecond", device: "phone",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, "- 09:05 (phone): first\n\n  second\n")
    }

    /// "Blank" means whitespace-only, not merely empty. A pasted line of spaces indented by
    /// two more would be trailing whitespace in somebody's vault — exactly the litter the
    /// empty-line rule exists to avoid.
    func testAWhitespaceONLYLineInsideACaptureIsWrittenEmptyToo() throws {
        let entry = try InboxCapture.entry(text: "first\n   \t \nsecond", device: "phone",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, "- 09:05 (phone): first\n\n  second\n")
        for line in entry.components(separatedBy: "\n") {
            XCTAssertEqual(line, line.replacingOccurrences(of: " +$", with: "",
                                                           options: .regularExpression),
                           "no line ends in whitespace")
        }
    }

    func testWindowsLineEndingsAreNormalized() throws {
        let entry = try InboxCapture.entry(text: "first\r\nsecond", device: "phone",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, "- 09:05 (phone): first\n  second\n")
    }

    func testADeviceNameCannotBreakTheLine() throws {
        let entry = try InboxCapture.entry(text: "a thought",
                                           device: "Jeremy's\n(iPhone)  15",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, "- 09:05 (Jeremy's iPhone 15): a thought\n")
        XCTAssertEqual(entry.components(separatedBy: "\n").count, 2)
    }

    func testAnEmptyDeviceNameStillNamesSomething() throws {
        let entry = try InboxCapture.entry(text: "a thought", device: "   ",
                                           now: instant("2026-09-23T09:05:00+02:00"),
                                           timeZone: rome)
        XCTAssertEqual(entry, "- 09:05 (unknown device): a thought\n")
    }

    // MARK: - Refusals

    func testEmptyTextIsRefusedAndNoFileIsCreated() {
        for empty in ["", "   ", "\n\n\t "] {
            XCTAssertThrowsError(try capture.capture(text: empty, device: "phone",
                                                     now: instant("2026-09-23T09:05:00+02:00"),
                                                     timeZone: rome)) { error in
                XCTAssertEqual(error as? InboxCaptureError, .emptyText)
            }
        }
        // The refusal happens BEFORE the file is touched, so not even a heading-only file
        // is left behind.
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("Inbox").path))
    }

    func testOversizeTextIsRefusedWithItsRealLength() {
        let long = String(repeating: "x", count: InboxCapture.characterLimit + 1)
        XCTAssertThrowsError(try capture.capture(text: long, device: "phone",
                                                 now: instant("2026-09-23T09:05:00+02:00"),
                                                 timeZone: rome)) { error in
            XCTAssertEqual(error as? InboxCaptureError,
                           .tooLong(characters: InboxCapture.characterLimit + 1,
                                    limit: InboxCapture.characterLimit))
            XCTAssertTrue("\(error)".contains("4001"), "the message names the real length")
        }
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("Inbox").path))
    }

    func testExactlyTheLimitIsAccepted() throws {
        let atLimit = String(repeating: "x", count: InboxCapture.characterLimit)
        let write = try capture.capture(text: atLimit, device: "phone",
                                        now: instant("2026-09-23T09:05:00+02:00"),
                                        timeZone: rome)
        XCTAssertTrue(write.entry.contains(atLimit))
    }

    func testARefusedCaptureLeavesAnEXISTINGFileExactlyAsItWas() throws {
        let when = instant("2026-09-23T09:05:00+02:00")
        let first = try capture.capture(text: "order the bricks", device: "phone",
                                        now: when, timeZone: rome)
        let before = try Data(contentsOf: root.appendingPathComponent(first.relativePath))
        XCTAssertThrowsError(try capture.capture(text: "  ", device: "phone",
                                                 now: when, timeZone: rome))
        let after = try Data(contentsOf: root.appendingPathComponent(first.relativePath))
        XCTAssertEqual(after, before)
    }

    // MARK: - The device's own day

    func testTheDateIsTheDEVICESDateAcrossMidnight() {
        // 23:30 in Rome on the 23rd is 21:30 UTC on the 23rd — same day either way.
        XCTAssertEqual(
            InboxCapture.relativePath(platform: .phone,
                                      now: instant("2026-09-23T23:30:00+02:00"),
                                      timeZone: rome),
            "Inbox/2026-09-23-phone.md")
        // 00:30 in Rome on the 24th is 22:30 UTC on the 23rd. The DEVICE's day is the 24th,
        // and that is the file a person opens Obsidian looking for.
        XCTAssertEqual(
            InboxCapture.relativePath(platform: .phone,
                                      now: instant("2026-09-24T00:30:00+02:00"),
                                      timeZone: rome),
            "Inbox/2026-09-24-phone.md")
        XCTAssertEqual(
            InboxCapture.relativePath(platform: .phone,
                                      now: instant("2026-09-24T00:30:00+02:00"),
                                      timeZone: TimeZone(identifier: "UTC")!),
            "Inbox/2026-09-23-phone.md")
        // And the heading agrees with the name it is under.
        XCTAssertEqual(
            InboxCapture.heading(platform: .phone,
                                 now: instant("2026-09-24T00:30:00+02:00"),
                                 timeZone: rome),
            "# Phone captures 2026-09-24")
        XCTAssertEqual(InboxCapture.clock(instant("2026-09-24T00:30:00+02:00"), timeZone: rome),
                       "00:30")
    }

    func testTheClockIs24HourWhateverTheLocale() {
        XCTAssertEqual(InboxCapture.clock(instant("2026-09-23T19:05:00+02:00"), timeZone: rome),
                       "19:05")
    }

    // MARK: - Reading a capture file's own name

    func testDescribeReadsTheDayAndPlatformBackOutOfTheName() {
        let described = InboxCapture.describe(relativePath: "Inbox/2026-09-23-mac.md")
        XCTAssertEqual(described?.day, "2026-09-23")
        XCTAssertEqual(described?.platform, .mac)
        for notOurs in ["Inbox/2026-09-23-watch.md", "Inbox/notes.md",
                        "Projects/2026-09-23-phone.md", "Inbox/2026-9-3-phone.md",
                        "Inbox/2026-09-23-phone.txt", "Inbox/sub/2026-09-23-phone.md"] {
            XCTAssertNil(InboxCapture.describe(relativePath: notOurs), notOurs)
        }
    }

    func testRewritePutsTheSAMELineBackInTheSAMEFile() throws {
        let when = instant("2026-09-23T09:05:00+02:00")
        let first = try capture.capture(text: "order the bricks", device: "phone",
                                        now: when, timeZone: rome)
        // The file goes away entirely — a tidy-up, a sync that lost it.
        try FileManager.default.removeItem(at: root.appendingPathComponent(first.relativePath))

        // Re-captured a day later: the file it belongs to is recreated, with ITS OWN day in
        // the heading, and the line keeps its original timestamp and checksum.
        let again = try capture.rewrite(entry: first.entry, relativePath: first.relativePath,
                                        now: instant("2026-09-24T11:00:00+02:00"),
                                        timeZone: rome)
        XCTAssertEqual(again.checksum, first.checksum)
        XCTAssertEqual(try contents(first.relativePath), """
            # Phone captures 2026-09-23

            - 09:05 (phone): order the bricks

            """)
    }

    // MARK: - The badge

    func testTheBadgeNamesTheFile() throws {
        let write = try capture.capture(text: "order the bricks", device: "phone",
                                        now: instant("2026-09-23T09:05:00+02:00"),
                                        timeZone: rome)
        XCTAssertEqual(InboxCaptureReply.badge(path: write.relativePath),
                       "[captured offline · Inbox/2026-09-23-phone.md]")
        XCTAssertEqual(InboxCaptureReply.body(write), """
            [captured offline · Inbox/2026-09-23-phone.md]

            - 09:05 (phone): order the bricks
            """)
    }

    // MARK: - Nothing else in the vault is reachable

    func testTheONLYPathACaptureEverWritesIsTheDatedInboxFile() throws {
        VaultFixture.writeCorpus(in: root)
        let before = try snapshot()
        _ = try capture.capture(text: "a thought", device: "phone",
                                now: instant("2026-09-23T09:05:00+02:00"), timeZone: rome)
        let after = try snapshot()
        let added = Set(after.keys).subtracting(before.keys)
        XCTAssertEqual(added, ["Inbox/2026-09-23-phone.md"])
        // And not one existing file changed.
        for (path, bytes) in before {
            XCTAssertEqual(after[path], bytes, "\(path) changed")
        }
    }

    /// Every file under the root, with its bytes.
    ///
    /// The prefix is stripped against the RESOLVED root: on macOS the temporary directory is
    /// `/var/...`, a symlink to `/private/var/...`, and the enumerator answers with the
    /// resolved side.
    private func snapshot() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            out[String(resolved.dropFirst(resolved.hasPrefix(prefix) ? prefix.count : 0))] =
                try Data(contentsOf: url)
        }
        return out
    }
}
