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

    // MARK: - The regression: a written strand tick reaches the bridge, once
    //
    // The outbox that used to carry only these is gone; every write is now a record in
    // `VaultWriteOutbox`, and a strand tick's record carries its step so a bridge without
    // the write route still hears of it the old way. See `VaultWriteOutboxTests`.

    func testATickWrittenInAStrandNoteCarriesItsStep() throws {
        let at = line(of: "**P1**", in: family)
        let ticked = try XCTUnwrap(VaultCheckboxEdit.setting(family, line: at, checked: true))
        let record = VaultWriteRecord.replacing(localPath: "Strands/Family.md", base: family,
                                                baseStamp: VaultFileStamp(text: family),
                                                new: ticked, kind: .tick)
        XCTAssertEqual(record.kind, .tick)
        XCTAssertEqual(record.line, at)
        XCTAssertEqual(record.checked, true)
        XCTAssertEqual(record.strandTick, StrandTickReport(note: "Family", id: "P1", checked: true))
        XCTAssertEqual(record.text, VaultCheckboxEdit.lines(family)[at - 1],
                       "the line as the device saw it, so the bridge can find it by content")
        XCTAssertNil(record.baseText, "a tick sends its line, not the whole note")
    }

    func testATickOutsideAStrandStepCarriesNoStep() throws {
        let at = line(of: "stray box", in: family)
        let ticked = try XCTUnwrap(VaultCheckboxEdit.setting(family, line: at, checked: true))
        let record = VaultWriteRecord.replacing(localPath: "Strands/Family.md", base: family,
                                                baseStamp: VaultFileStamp(text: family),
                                                new: ticked, kind: .tick)
        XCTAssertEqual(record.kind, .tick)
        XCTAssertNil(record.strandTick)
    }
}
