import XCTest
@testable import JesseVault

// THE FIVE WAYS A TAP ON A CHECKBOX ENDS.
//
// tap → success; tap → stale → retry → success; tap → stale → stale; tap → the line is not
// a checkbox any more; tap → some other failure. Each one is a state a person meets in
// ordinary use of a synced vault, and each one is two lines to stage here.
final class VaultNoteTickerTests: XCTestCase {

    private let note = """
        # Kiln

        - [ ] order the anchors
        - [x] measure the arch
        """

    // MARK: - tap → success

    func testATickWrites() async throws {
        let writer = FakeNoteWriter(text: note)
        let ticker = VaultNoteTicker(writer: writer)

        let outcome = await ticker.tick(path: "K.md", line: 3, to: true,
                                        text: note, stamp: VaultFileStamp(text: note))

        guard case .written(let text, let stamp) = outcome else {
            return XCTFail("expected a write, got \(outcome)")
        }
        XCTAssertTrue(text.contains("- [x] order the anchors"))
        XCTAssertEqual(stamp, VaultFileStamp(text: text))
        XCTAssertEqual(writer.diskText, text)
        XCTAssertEqual(writer.writes.count, 1)
        XCTAssertEqual(writer.writes.first?.kind, .tick)
        XCTAssertNil(outcome.message)
    }

    func testAnUntickWritesAndIsLoggedAsAnUntick() async throws {
        let writer = FakeNoteWriter(text: note)
        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 4, to: false,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertTrue(outcome.didWrite)
        XCTAssertEqual(writer.writes.first?.kind, .untick)
        XCTAssertTrue(writer.diskText.contains("- [ ] measure the arch"))
    }

    // MARK: - tap → stale → retry → success

    /// The ordinary case on a synced vault: somebody changed a DIFFERENT line while the
    /// note was open. The tick reloads, finds its own box still waiting, and lands.
    func testStaleThenRetrySucceeds() async throws {
        let writer = FakeNoteWriter(text: note)
        // Their edit, to a line this tap has nothing to do with.
        writer.diskText = note + "\n- [ ] and the castable\n"

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        guard case .written(let text, _) = outcome else {
            return XCTFail("expected the retry to land, got \(outcome)")
        }
        XCTAssertTrue(text.contains("- [x] order the anchors"))
        // THEIR LINE SURVIVED. A retry that had written the stale text would have removed
        // it, which is the silent data loss this whole design exists to prevent.
        XCTAssertTrue(text.contains("- [ ] and the castable"))
        XCTAssertEqual(writer.diskText, text)
    }

    // MARK: - tap → stale → stale

    func testStaleTwiceRevertsAndSaysSo() async throws {
        let writer = FakeNoteWriter(text: note)
        // Both the first write and the retry fail as stale.
        writer.failNextWrites([VaultFileError.changedSinceRead("K.md"),
                               VaultFileError.changedSinceRead("K.md")])

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertEqual(outcome, .stale)
        XCTAssertFalse(outcome.didWrite)
        XCTAssertEqual(outcome.message,
                       "This note changed while it was open; reload and try again.")
        XCTAssertEqual(writer.diskText, note, "nothing may have been written")
    }

    /// Somebody else ticked the same box. The retry must NOT write: the tap meant "move
    /// this from unticked to ticked" and that has already happened.
    func testARetryDoesNotUndoSomebodyElsesTick() async throws {
        let writer = FakeNoteWriter(text: note)
        let theirs = note.replacingOccurrences(of: "- [ ] order the anchors",
                                               with: "- [x] order the anchors")
        writer.diskText = theirs

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(writer.diskText, theirs)
        XCTAssertTrue(writer.writes.isEmpty)
    }

    /// The line is no longer a checkbox at all — somebody rewrote that part of the note.
    func testARetryOnALineThatIsNoLongerACheckboxStops() async throws {
        let writer = FakeNoteWriter(text: note)
        writer.diskText = "# Kiln\n\nThe anchors are ordered.\n- [x] measure the arch"

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertEqual(outcome, .stale)
        XCTAssertTrue(writer.writes.isEmpty)
    }

    // MARK: - tap → not a checkbox

    func testTappingALineThatIsNotACheckboxWritesNothing() async throws {
        let writer = FakeNoteWriter(text: note)
        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 1, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertEqual(outcome, .notACheckbox)
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertEqual(writer.reads, 0, "it must not even re-read")
    }

    // MARK: - tap → some other failure

    func testAnOtherErrorRevertsAndShowsTheErrorText() async throws {
        let writer = FakeNoteWriter(text: note)
        writer.failNextWrites([VaultFileError.unwritable("K.md", "the disk is full")])

        let outcome = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))

        XCTAssertFalse(outcome.didWrite)
        XCTAssertEqual(outcome.message, VaultFileError.unwritable("K.md", "the disk is full").description)
        XCTAssertEqual(writer.diskText, note)
        // An "other" error is NOT retried — only a stale stamp is.
        XCTAssertEqual(writer.reads, 0)
    }

    func testAFailureIsNotRetriedIntoASecondWrite() async throws {
        let writer = FakeNoteWriter(text: note)
        writer.failNextWrites([VaultFileError.unwritable("K.md", "nope")])
        _ = await VaultNoteTicker(writer: writer)
            .tick(path: "K.md", line: 3, to: true,
                  text: note, stamp: VaultFileStamp(text: note))
        XCTAssertTrue(writer.writes.isEmpty)
    }
}
