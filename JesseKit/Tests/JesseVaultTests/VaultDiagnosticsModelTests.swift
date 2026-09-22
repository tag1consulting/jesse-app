import XCTest
@testable import JesseVault

// The diagnostics screen's PURE parts: the probe file's name, the line it appends,
// and the device name it stamps into it. None of this needs a device, and all of it
// is what Jeremy's device checklist actually looks for in Obsidian afterwards — a
// file called `Inbox/<today>-phone-probe.md` with one recognisable line in it.
final class VaultDiagnosticsModelTests: XCTestCase {

    private func calendar(secondsFromGMT: Int = 0) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT) ?? .gmt
        return calendar
    }

    func testTheProbeFileIsTodayUnderInbox() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 in GMT
        XCTAssertEqual(VaultDiagnosticsModel.probeRelativePath(for: date, calendar: calendar()),
                       "Inbox/2026-09-21-phone-probe.md")
    }

    /// The file is looked for by a human opening Obsidian on the day they pressed
    /// the button, so the day is the DEVICE's day, not GMT's.
    func testTheProbeFileUsesTheDevicesOwnDay() {
        // 22:30 GMT is already the next day in Rome (GMT+2).
        let date = Date(timeIntervalSince1970: 1_790_030_000)
        let gmt = VaultDiagnosticsModel.probeRelativePath(for: date, calendar: calendar())
        let rome = VaultDiagnosticsModel.probeRelativePath(for: date, calendar: calendar(secondsFromGMT: 7_200))
        XCTAssertEqual(gmt, "Inbox/2026-09-21-phone-probe.md")
        XCTAssertEqual(rome, "Inbox/2026-09-22-phone-probe.md")
    }

    func testTheProbeFileNameIsAlwaysAMarkdownFileInsideInbox() {
        for offset in stride(from: 0.0, to: 400 * 86_400, by: 37 * 86_400) {
            let path = VaultDiagnosticsModel.probeRelativePath(for: Date(timeIntervalSince1970: offset))
            XCTAssertTrue(path.hasPrefix("Inbox/"), "the probe never writes outside Inbox/ (\(path))")
            XCTAssertTrue(path.hasSuffix("-phone-probe.md"))
            // And it must survive the same validation every other write goes through.
            XCTAssertNoThrow(try VaultFile.validatedComponents(path))
        }
    }

    func testTheAppendedLineIsOneStampedBulletEndingInANewline() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let line = VaultDiagnosticsModel.probeLine(for: date, device: "Studio", calendar: calendar())

        XCTAssertEqual(line, "- 2026-09-21 14:13 Jesse vault probe from Studio\n")
        XCTAssertTrue(line.hasSuffix("\n"),
                      "without the newline a second probe lands on the same physical line as the first")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "one line means one line")
    }

    func testTheDeviceNameHasNoTrailingLocalSuffix() {
        let name = VaultDiagnosticsModel.deviceName()
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.hasSuffix(".local"))
    }

    func testIsoDayIsZeroPadded() {
        let date = Date(timeIntervalSince1970: 1_767_312_000)   // 2026-01-02 GMT
        XCTAssertEqual(VaultDiagnosticsModel.isoDay(date, calendar: calendar()), "2026-01-02")
    }

    /// The whole probe, end to end, against a temporary folder — the same path the
    /// button takes, minus the picker.
    @MainActor
    func testTheProbeAppendsExactlyOneLineToTodaysInboxFile() throws {
        let suiteName = "jesse.vault.diagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-vault-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let folder = VaultFolder(defaults: defaults, key: "diag.bookmark")
        try folder.adopt(url: directory)
        let relativePath = VaultDiagnosticsModel.probeRelativePath(for: Date())

        try folder.withAccess { root in
            let file = VaultFile(root: root)
            try file.append(relativePath: relativePath,
                            text: VaultDiagnosticsModel.probeLine(for: Date(), device: "Test"))
            let text = try file.read(relativePath: relativePath)
            XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
            XCTAssertTrue(text.contains("Jesse vault probe from Test"))
        }
    }
}
