import XCTest
@testable import JesseVault

// THE WHOLE CAPTURE, THROUGH A REAL FOLDER AND A REAL LOG.
//
// The pieces are asserted on their own elsewhere; what this file is for is the joins —
// that a capture reaches a real file through a real security-scoped bookmark, that the row
// the log gets describes the bytes that were actually appended, that the verification pass
// changes a status and NEVER re-appends, and that Re-capture makes a missing line good
// again without inventing a second row.
@MainActor
final class InboxCaptureServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var vault: URL!
    private var support: URL!
    private var log: OfflineWriteLog!
    private var service: InboxCaptureService!
    /// 2026-09-23 14:32 in Rome.
    private let when = Date(timeIntervalSince1970: 1_790_166_720)
    private let rome = TimeZone(identifier: "Europe/Rome")!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "jesse.capture.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-capture-vault-\(UUID().uuidString)")
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-capture-support-\(UUID().uuidString)")
        for url in [vault, support] {
            try FileManager.default.createDirectory(at: url!, withIntermediateDirectories: true)
        }
        log = OfflineWriteLog(directory: support)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: vault)
        try? FileManager.default.removeItem(at: support)
        try await super.tearDown()
    }

    /// A service pointed at the temporary vault, with a folder bookmark really taken.
    private func makeService(holdingFolder: Bool = true) throws -> InboxCaptureService {
        let folder = VaultFolder(defaults: defaults, key: "test.bookmark")
        // One bookmark key per suite, so `holdingFolder: false` really is a device with no
        // folder rather than one whose bookmark an earlier call in the same test took.
        if holdingFolder { try folder.adopt(url: vault) } else { folder.forget() }
        let source = VaultIndexSource(folder: folder, container: support)
        let stamp = when
        let zone = rome
        return InboxCaptureService(source: source, log: log, platform: .phone,
                                   deviceName: { "Jeremy-iPhone" },
                                   now: { stamp }, timeZone: { zone },
                                   outbox: VaultWriteOutbox(
                                       fileURL: support.appendingPathComponent("outbox.json"),
                                       migrateLegacy: false))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: vault.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Capture

    func testACaptureLandsInTheFileAndInTheLog() async throws {
        let service = try makeService()
        let outcome = await service.capture("order the bricks")
        guard case .success(let write) = outcome else {
            return XCTFail("expected a capture, got \(outcome)")
        }
        XCTAssertEqual(write.relativePath, "Inbox/2026-09-23-phone.md")
        XCTAssertEqual(try contents(write.relativePath), """
            # Phone captures 2026-09-23

            - 14:32 (Jeremy-iPhone): order the bricks

            """)
        let row = try XCTUnwrap(log.records.first)
        XCTAssertEqual(row.file, write.relativePath)
        XCTAssertEqual(row.status, .written)
        XCTAssertEqual(row.text, write.entry)
        XCTAssertEqual(row.checksum, InboxCapture.checksum(write.entry))
        // The byte count is what THIS call appended: the heading too, because this call
        // created the file.
        XCTAssertEqual(row.bytes, try contents(write.relativePath).utf8.count)
        XCTAssertNil(row.about)
    }

    func testTheSECONDCapturesRowCountsOnlyItsOwnBytes() async throws {
        let service = try makeService()
        _ = await service.capture("order the bricks")
        guard case .success(let second) = await service.capture("measure the arch") else {
            return XCTFail("expected a second capture")
        }
        let row = try XCTUnwrap(log.records.first)
        XCTAssertFalse(second.createdFile)
        XCTAssertEqual(row.bytes, second.entry.utf8.count)
        XCTAssertEqual(log.records.count, 2)
    }

    func testACaptureAboutANoteRecordsTheNote() async throws {
        let service = try makeService()
        guard case .success(let write) = await service.capture(
            "the bricks were never ordered", about: "Workshop/Kiln-Rebuild.md") else {
            return XCTFail("expected a capture")
        }
        XCTAssertTrue(write.entry.contains("`Workshop/Kiln-Rebuild.md`"))
        XCTAssertEqual(log.records.first?.about, "Workshop/Kiln-Rebuild.md")
    }

    func testARefusedCaptureIsNOTLOGGED() async throws {
        let service = try makeService()
        guard case .failure(let failure) = await service.capture("   ") else {
            return XCTFail("empty text must be refused")
        }
        XCTAssertEqual(failure, .refused(InboxCaptureError.emptyText.description))
        XCTAssertTrue(log.records.isEmpty)
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: vault.appendingPathComponent("Inbox").path))
    }

    func testWithNoFolderNothingIsWrittenAndNothingIsClaimed() async throws {
        let service = try makeService(holdingFolder: false)
        XCTAssertFalse(service.hasVaultFolder)
        guard case .failure(let failure) = await service.capture("order the bricks") else {
            return XCTFail("a device with no folder cannot capture")
        }
        XCTAssertEqual(failure, .noFolder)
        XCTAssertTrue(log.records.isEmpty)
    }

    // MARK: - The offer

    func testTheOfferAsksAboutTheFolderOnlyWhenTheBridgeIsUnreachable() async throws {
        let service = try makeService()
        XCTAssertEqual(service.offer(reachability: .unreachable), .offered)
        XCTAssertEqual(service.offer(reachability: .reachable), .hidden)
        XCTAssertEqual(service.offer(reachability: .unknown), .hidden)

        let none = try makeService(holdingFolder: false)
        XCTAssertEqual(none.offer(reachability: .unreachable), .hidden)
    }

    // MARK: - Verification

    func testVerificationMarksAPRESENTCaptureVerified() async throws {
        let service = try makeService()
        _ = await service.capture("order the bricks")
        let statuses = await service.verifyRecent()
        let row = try XCTUnwrap(log.records.first)
        XCTAssertEqual(statuses[row.id], .verified)
        XCTAssertEqual(row.status, .verified)
    }

    func testVerificationMarksADELETEDLineNotFoundAndNEVERREAPPENDSIT() async throws {
        let service = try makeService()
        guard case .success(let write) = await service.capture("order the bricks") else {
            return XCTFail("expected a capture")
        }
        // Somebody tidied the line away in Obsidian.
        let url = vault.appendingPathComponent(write.relativePath)
        try "# Phone captures 2026-09-23\n\n".write(to: url, atomically: true, encoding: .utf8)

        _ = await service.verifyRecent()
        XCTAssertEqual(log.records.first?.status, .notFound)
        // THE FILE IS UNTOUCHED. The verification pass reads; it does not repair.
        XCTAssertEqual(try contents(write.relativePath), "# Phone captures 2026-09-23\n\n")
        // And the text is still in the log, so it can be written again.
        XCTAssertEqual(log.records.first?.text, write.entry)
    }

    func testVerificationMarksAMISSINGFILENotFound() async throws {
        let service = try makeService()
        guard case .success(let write) = await service.capture("order the bricks") else {
            return XCTFail("expected a capture")
        }
        try FileManager.default.removeItem(at: vault.appendingPathComponent(write.relativePath))
        _ = await service.verifyRecent()
        XCTAssertEqual(log.records.first?.status, .notFound)
    }

    /// A stale bookmark is a Settings problem, not evidence that captures were lost.
    func testVerificationWithNoFolderLeAVESEveryRowAlone() async throws {
        let service = try makeService()
        _ = await service.capture("order the bricks")
        _ = await service.verifyRecent()
        XCTAssertEqual(log.records.first?.status, .verified)

        let none = try makeService(holdingFolder: false)
        let statuses = await none.verifyRecent()
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(log.records.first?.status, .verified)
    }

    // MARK: - Re-capture

    func testRecaptureWritesTheSAMELineBackAndItVerifies() async throws {
        let service = try makeService()
        guard case .success(let write) = await service.capture("order the bricks") else {
            return XCTFail("expected a capture")
        }
        try FileManager.default.removeItem(at: vault.appendingPathComponent(write.relativePath))
        _ = await service.verifyRecent()
        let missing = try XCTUnwrap(log.records.first)
        XCTAssertEqual(missing.status, .notFound)

        guard case .success(let again) = await service.recapture(missing) else {
            return XCTFail("expected the re-capture to land")
        }
        XCTAssertEqual(again.checksum, missing.checksum)
        // ONE row, not two: this is the same capture being made good.
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records.first?.status, .written)

        _ = await service.verifyRecent()
        XCTAssertEqual(log.records.first?.status, .verified)
        XCTAssertEqual(try contents(write.relativePath), """
            # Phone captures 2026-09-23

            - 14:32 (Jeremy-iPhone): order the bricks

            """)
    }

    // MARK: - The sheet's model

    func testTheSheetRefusesAnEmptyFieldAndReportsWhereItWent() async throws {
        let service = try makeService()
        let model = VaultCaptureModel(about: "Workshop/Kiln-Rebuild.md", service: service)
        XCTAssertFalse(model.canSave)
        model.text = "   "
        XCTAssertFalse(model.canSave)
        await model.save()
        XCTAssertNil(model.written)
        XCTAssertTrue(log.records.isEmpty)

        model.text = "the bricks were never ordered"
        XCTAssertTrue(model.canSave)
        await model.save()
        XCTAssertEqual(model.written?.relativePath, "Inbox/2026-09-23-phone.md")
        XCTAssertNil(model.error)
        XCTAssertTrue(model.subtitle.contains("Workshop/Kiln-Rebuild.md"))
    }

    func testTheSheetKeepsTheTextWhenTheCaptureFails() async throws {
        let service = try makeService(holdingFolder: false)
        let model = VaultCaptureModel(service: service)
        model.text = "order the bricks"
        await model.save()
        XCTAssertNil(model.written)
        XCTAssertEqual(model.text, "order the bricks")
        XCTAssertEqual(model.error, InboxCaptureFailure.noFolder.description)
        // With no note, the subtitle says where it goes rather than naming one.
        XCTAssertTrue(model.subtitle.contains("Inbox"))
    }
}
