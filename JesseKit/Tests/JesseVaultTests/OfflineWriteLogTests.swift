import XCTest
@testable import JesseVault

// THE LOG, ITS CAP, AND THE THREE ANSWERS THE VERIFICATION CAN GIVE.
//
// The log exists so a capture that never synced is VISIBLE rather than silently gone, and
// the only way that claim holds is if "present", "the line has gone" and "the file has
// gone" are three distinguishable outcomes. All three are asserted here, through a fake
// folder, so none of them needs a device or a sync to happen.
final class OfflineWriteLogTests: XCTestCase {

    private var directory: URL!
    private var log: OfflineWriteLog!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-write-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = OfflineWriteLog(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ text: String,
                        file: String = "Inbox/2026-09-23-phone.md",
                        status: OfflineWriteStatus = .written,
                        written: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> OfflineWriteRecord {
        OfflineWriteRecord(written: written, file: file, bytes: text.utf8.count,
                           checksum: InboxCapture.checksum(text), text: text, status: status)
    }

    // MARK: - The list

    func testStartsEmptyAndIsNewestFirst() {
        XCTAssertTrue(log.records.isEmpty)
        log.record(record("- 09:05 (phone): first\n"))
        log.record(record("- 10:05 (phone): second\n"))
        XCTAssertEqual(log.records.map(\.summary), ["- 10:05 (phone): second",
                                                    "- 09:05 (phone): first"])
    }

    func testItSurvivesANewInstance() {
        log.record(record("- 09:05 (phone): first\n"))
        XCTAssertEqual(OfflineWriteLog(directory: directory).records.count, 1)
    }

    func testTheCapDropsTheOLDEST() {
        for i in 0..<(OfflineWriteLog.capacity + 5) {
            log.record(record("- 09:05 (phone): entry \(i)\n"))
        }
        let all = log.records
        XCTAssertEqual(all.count, OfflineWriteLog.capacity)
        // Newest kept, oldest gone.
        XCTAssertEqual(all.first?.summary, "- 09:05 (phone): entry \(OfflineWriteLog.capacity + 4)")
        XCTAssertEqual(all.last?.summary, "- 09:05 (phone): entry 5")
    }

    func testRecentIsTheScreensTwenty() {
        for i in 0..<40 { log.record(record("- 09:05 (phone): entry \(i)\n")) }
        XCTAssertEqual(log.recent.count, OfflineWriteLog.displayCount)
        XCTAssertEqual(log.recent.first?.summary, "- 09:05 (phone): entry 39")
    }

    func testAnUndecodableFileReadsAsAnEmptyLogRatherThanFailing() throws {
        try FileManager.default.createDirectory(
            at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: log.url)
        XCTAssertTrue(log.records.isEmpty)
        // And the next capture rewrites it.
        log.record(record("- 09:05 (phone): first\n"))
        XCTAssertEqual(log.records.count, 1)
    }

    func testApplyingStatusesRewritesOnlyWhatChanged() {
        let one = record("- 09:05 (phone): first\n")
        let two = record("- 10:05 (phone): second\n")
        log.record(one)
        log.record(two)
        log.apply(statuses: [one.id: .verified])
        let after = log.records
        XCTAssertEqual(after.first(where: { $0.id == one.id })?.status, .verified)
        XCTAssertEqual(after.first(where: { $0.id == two.id })?.status, .written)
        // An id that is no longer in the log is simply not there to update.
        log.apply(statuses: [UUID(): .notFound])
        XCTAssertEqual(log.records.count, 2)
    }

    func testClear() {
        log.record(record("- 09:05 (phone): first\n"))
        log.clear()
        XCTAssertTrue(log.records.isEmpty)
    }

    func testStatusDisplayAndAttention() {
        XCTAssertEqual(OfflineWriteStatus.written.display, "written")
        XCTAssertEqual(OfflineWriteStatus.verified.display, "verified")
        XCTAssertEqual(OfflineWriteStatus.notFound.display, "not found in file")
        XCTAssertFalse(OfflineWriteStatus.written.needsAttention)
        XCTAssertFalse(OfflineWriteStatus.verified.needsAttention)
        XCTAssertTrue(OfflineWriteStatus.notFound.needsAttention)
    }

    func testASummaryFlattensAndTruncates() {
        let long = record("- 09:05 (phone): " + String(repeating: "brick ", count: 40))
        XCTAssertEqual(long.summary.count, 60)
        XCTAssertTrue(long.summary.hasSuffix("…"))
        XCTAssertEqual(record("- 09:05 (phone): kiln\n  bricks: forty\n").summary,
                       "- 09:05 (phone): kiln bricks: forty")
    }

    // MARK: - The verification pass, through a fake folder

    func testPresentAbsentAndUnreadable() {
        let present = record("- 09:05 (phone): still here\n")
        let gone = record("- 10:05 (phone): tidied away\n")
        let deleted = record("- 11:05 (phone): its file is gone\n",
                             file: "Inbox/2026-09-22-phone.md")

        let files = [
            "Inbox/2026-09-23-phone.md": """
                # Phone captures 2026-09-23

                - 09:05 (phone): still here

                """,
        ]
        let statuses = OfflineWriteVerifier.statuses(for: [present, gone, deleted]) { path in
            guard let text = files[path] else {
                struct Missing: Error {}
                throw Missing()
            }
            return text
        }
        XCTAssertEqual(statuses[present.id], .verified)
        XCTAssertEqual(statuses[gone.id], .notFound)
        XCTAssertEqual(statuses[deleted.id], .notFound)
    }

    func testAnAlreadyVerifiedRecordIsCHECKEDAGAIN() {
        // A line can be deleted after it was confirmed. A status written once is a status
        // that goes stale without anyone noticing.
        let stale = record("- 09:05 (phone): confirmed, then deleted\n", status: .verified)
        let statuses = OfflineWriteVerifier.statuses(for: [stale]) { _ in
            "# Phone captures 2026-09-23\n\n"
        }
        XCTAssertEqual(statuses[stale.id], .notFound)
    }

    func testATAMPEREDLogRowIsNotFoundEvenIfTheTextIsInTheFile() {
        // The checksum is what makes the row trustworthy. A row whose text was changed after
        // the fact must not verify, even when that text happens to be in the file.
        let honest = record("- 09:05 (phone): real line\n")
        let tampered = OfflineWriteRecord(id: honest.id, written: honest.written,
                                          file: honest.file, bytes: honest.bytes,
                                          checksum: honest.checksum,
                                          text: "- 09:05 (phone): a different line\n")
        let statuses = OfflineWriteVerifier.statuses(for: [tampered]) { _ in
            "- 09:05 (phone): a different line\n"
        }
        XCTAssertEqual(statuses[tampered.id], .notFound)
    }

    func testEachFileIsReadONCEHoweverManyRecordsNameIt() {
        let records = (0..<20).map { record("- 09:0\($0 % 10) (phone): entry \($0)\n") }
        var reads = 0
        _ = OfflineWriteVerifier.statuses(for: records) { _ in
            reads += 1
            return records.map(\.text).joined()
        }
        XCTAssertEqual(reads, 1)
    }

    func testAnEmptyPassIsNoWork() {
        var reads = 0
        let statuses = OfflineWriteVerifier.statuses(for: []) { _ in
            reads += 1
            return ""
        }
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(reads, 0)
    }
}
