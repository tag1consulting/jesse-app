import XCTest
@testable import JesseVault

// THE TICK THAT WAS WRITTEN AND NEVER ARRIVED.
//
// 2026-09-24 18:43: Family P1 ticked in the reader, `.written`, logged — and the Studio's
// note never changed, because the only carrier from the phone's copy to the Studio was
// Obsidian iOS's Sync, which never saw the write. These tests pin the fix at the layer the
// defect lived in: a written tick of a strand step is REPORTED, exactly once, and a report
// that cannot be sent is kept rather than lost.
final class StrandTickReportTests: XCTestCase {

    /// The Family note as it stood that afternoon, in the v2 layout.
    private let family = """
        ---
        group: personal
        state: active
        updated: 2026-09-24
        ---
        # Family

        **Now:** Household and family paperwork.

        ## Drafts
        - [ ] **P1** Permesso kits for Greta and Aurora. [[todo-list/Projects/drafts/2026-09-17-0856-Permesso-Kits-Greta-And-Aurora]] (waits on: you)
        - [ ] **P2** Modulo 1 transcription sheet. Launched 2026-09-20.
        ### Later
        - [ ] **B2** Banca Sella document request.
        ### Done
        - [x] 2026-09-14 **P0** Greta's ospitalità declaration.

        ## Decisions
        - [ ] a stray box that is not a step
        """

    private let v1 = """
        # Old
        ## Queue
        - [ ] **Q1** first
        ## Running
        - [ ] **R1** running
        ## Done
        - [x] 2026-09-01 **D1** done
        """

    private func line(of needle: String, in text: String) -> Int {
        let lines = VaultCheckboxEdit.lines(text)
        return (lines.firstIndex { $0.contains(needle) } ?? -1) + 1
    }

    /// A defaults suite nobody else uses, so no test sees another's queue.
    private func freshDefaults() -> String {
        let name = "StrandTickReportTests-\(UUID().uuidString)"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return name
    }

    // MARK: - Which ticks are strand steps

    func testAQueueDraftsLaterAndRunningLineIsAStep() {
        let p1 = StrandTickReport.forTick(path: "Strands/Family.md", text: family,
                                          line: line(of: "**P1**", in: family), checked: true)
        XCTAssertEqual(p1, StrandTickReport(note: "Family", id: "P1", checked: true))
        XCTAssertEqual(StrandTickReport.forTick(path: "Strands/Family.md", text: family,
                                                line: line(of: "**P2**", in: family),
                                                checked: true)?.id, "P2")
        XCTAssertEqual(StrandTickReport.forTick(path: "Strands/Family.md", text: family,
                                                line: line(of: "**B2**", in: family),
                                                checked: false),
                       StrandTickReport(note: "Family", id: "B2", checked: false))
        XCTAssertEqual(StrandTickReport.forTick(path: "Strands/Old.md", text: v1,
                                                line: line(of: "**Q1**", in: v1),
                                                checked: true)?.id, "Q1")
        XCTAssertEqual(StrandTickReport.forTick(path: "Strands/Old.md", text: v1,
                                                line: line(of: "**R1**", in: v1),
                                                checked: true)?.id, "R1")
    }

    func testDoneLinesOtherSectionsAndOtherNotesAreNotSteps() {
        for (path, text, needle) in [
            ("Strands/Family.md", family, "**P0**"),
            ("Strands/Family.md", family, "stray box"),
            ("Strands/Family.md", family, "# Family"),
            ("Strands/Old.md", v1, "**D1**"),
            ("Projects/Family.md", family, "**P1**"),
            ("Strands/archive/Family.md", family, "**P1**"),
            ("Strands/.Family.md", family, "**P1**"),
        ] {
            XCTAssertNil(StrandTickReport.forTick(path: path, text: text,
                                                  line: line(of: needle, in: text),
                                                  checked: true), "\(path) \(needle)")
        }
        XCTAssertNil(StrandTickReport.forTick(path: "Strands/X.md",
                                              text: "## Queue\n- [ ] no id here",
                                              line: 2, checked: true))
    }

    // MARK: - The regression: a written tick is reported, once

    func testATickWrittenInAStrandNoteIsReportedExactlyOnce() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        await outbox.configure { reporter }
        let writer = FakeNoteWriter(text: family)
        let ticker = VaultNoteTicker(writer: writer, strandTicks: outbox)

        let outcome = await ticker.tick(path: "Strands/Family.md",
                                        line: line(of: "**P1**", in: family), to: true,
                                        text: family, stamp: VaultFileStamp(text: family))

        XCTAssertTrue(outcome.didWrite)
        XCTAssertTrue(writer.diskText.contains("- [x] **P1**"))
        await outbox.flush()
        XCTAssertEqual(reporter.sent, [StrandTickReport(note: "Family", id: "P1", checked: true)])
        let left = await outbox.queued
        XCTAssertEqual(left, [])
    }

    func testATickThatWinsOnTheRetryIsReportedToo() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        await outbox.configure { reporter }
        let writer = FakeNoteWriter(text: family)
        writer.diskText = family + "\n- a line somebody else added\n"

        let outcome = await VaultNoteTicker(writer: writer, strandTicks: outbox)
            .tick(path: "Strands/Family.md", line: line(of: "**P1**", in: family), to: true,
                  text: family, stamp: VaultFileStamp(text: family))

        XCTAssertTrue(outcome.didWrite)
        await outbox.flush()
        XCTAssertEqual(reporter.sent.map(\.id), ["P1"])
    }

    func testATickThatDidNotWriteReportsNothing() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        await outbox.configure { reporter }
        let writer = FakeNoteWriter(text: family)
        writer.failNextWrites([VaultFileError.unwritable("Strands/Family.md", "disk full")])

        let outcome = await VaultNoteTicker(writer: writer, strandTicks: outbox)
            .tick(path: "Strands/Family.md", line: line(of: "**P1**", in: family), to: true,
                  text: family, stamp: VaultFileStamp(text: family))

        XCTAssertFalse(outcome.didWrite)
        await outbox.flush()
        XCTAssertEqual(reporter.sent, [])
    }

    func testATickOutsideAStrandNoteReportsNothing() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        await outbox.configure { reporter }
        let writer = FakeNoteWriter(text: family)

        _ = await VaultNoteTicker(writer: writer, strandTicks: outbox)
            .tick(path: "Projects/Family.md", line: line(of: "**P1**", in: family), to: true,
                  text: family, stamp: VaultFileStamp(text: family))

        await outbox.flush()
        XCTAssertEqual(reporter.sent, [])
    }

    // MARK: - The outbox

    func testAReportThatCannotBeSentIsKeptAndSentInOrderLater() async throws {
        let suite = freshDefaults()
        let outbox = StrandTickOutbox(suiteName: suite)
        let reporter = FakeTickReporter()
        reporter.reachable = false
        await outbox.configure { reporter }
        let tick = StrandTickReport(note: "Family", id: "P1", checked: true)
        let untick = StrandTickReport(note: "Family", id: "P1", checked: false)

        await outbox.enqueue(tick)
        await outbox.enqueue(untick)
        await outbox.flush()
        XCTAssertEqual(reporter.sent, [])

        // A relaunch: a new outbox over the same defaults still holds both, in order.
        let relaunched = StrandTickOutbox(suiteName: suite)
        await relaunched.configure { reporter }
        let kept = await relaunched.queued
        XCTAssertEqual(kept, [tick, untick])

        reporter.reachable = true
        await relaunched.flush()
        XCTAssertEqual(reporter.sent, [tick, untick])
        let left = await relaunched.queued
        XCTAssertEqual(left, [])
    }

    func testAReportTheBridgeRefusesLeavesTheOutbox() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        reporter.answer = .refused
        await outbox.configure { reporter }
        await outbox.enqueue(StrandTickReport(note: "Gone", id: "Z9", checked: true))
        await outbox.flush()
        let left = await outbox.queued
        XCTAssertEqual(left, [])
        XCTAssertEqual(reporter.sent.count, 1)
    }

    func testTwoFlushesAtOnceSendEachReportOnce() async throws {
        let outbox = StrandTickOutbox(suiteName: freshDefaults())
        let reporter = FakeTickReporter()
        await outbox.configure { reporter }
        await outbox.enqueue(StrandTickReport(note: "Family", id: "P1", checked: true))
        await outbox.enqueue(StrandTickReport(note: "Family", id: "P2", checked: true))

        async let first: Void = outbox.flush()
        async let second: Void = outbox.flush()
        _ = await (first, second)

        XCTAssertEqual(reporter.sent.map(\.id), ["P1", "P2"])
    }
}

/// The bridge, as far as a report is concerned.
final class FakeTickReporter: StrandTickReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [StrandTickReport] = []
    private var _reachable = true
    private var _answer = StrandTickDelivery.delivered

    var sent: [StrandTickReport] { lock.withLock { _sent } }
    var reachable: Bool {
        get { lock.withLock { _reachable } }
        set { lock.withLock { _reachable = newValue } }
    }
    var answer: StrandTickDelivery {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func reportStrandTick(_ report: StrandTickReport) async throws -> StrandTickDelivery {
        try lock.withLock {
            guard _reachable else { throw URLError(.notConnectedToInternet) }
            _sent.append(report)
            return _answer
        }
    }
}
