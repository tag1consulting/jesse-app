import XCTest
@testable import JesseVault

// THE EDITOR'S STATES, INCLUDING THE FOUR THAT ONLY HAPPEN WHEN SOMEBODY ELSE IS TYPING.
@MainActor
final class VaultNoteEditorModelTests: XCTestCase {

    private var stashDirectory: URL!
    private var stash: VaultEditStash!
    private let note = "# Kiln\n\nThe arch is sound.\n"

    override func setUp() {
        super.setUp()
        stashDirectory = VaultFixture.makeDirectory()
        stash = VaultEditStash(directory: stashDirectory)
    }

    override func tearDown() {
        VaultFixture.cleanUp(stashDirectory)
        super.tearDown()
    }

    private func makeModel(_ writer: any VaultNoteWriting,
                           path: String = "Notes/Kiln.md") -> VaultNoteEditorModel {
        VaultNoteEditorModel(path: path, writer: writer, stash: stash)
    }

    // MARK: - Loading and the dirty flag

    func testLoadingPutsTheFileInTheEditor() async {
        let model = makeModel(FakeNoteWriter(text: note))
        await model.load()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.text, note)
        XCTAssertEqual(model.loaded, note)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canSave, "Save must be off until something differs")
    }

    func testSaveIsOfferedOnlyForARealDifference() async {
        let model = makeModel(FakeNoteWriter(text: note))
        await model.load()

        model.text = note + "one more line\n"
        XCTAssertTrue(model.canSave)

        // Typed and deleted again: not dirty, because it is not different.
        model.text = note
        XCTAssertFalse(model.canSave)
    }

    func testAFailedReadIsReported() async {
        let model = makeModel(FailingNoteWriter())
        await model.load()
        guard case .failed(let why) = model.phase else {
            return XCTFail("expected a failure, got \(model.phase)")
        }
        XCTAssertTrue(why.contains("not reachable"))
    }

    // MARK: - Refusals

    func testTodayIsRefusedBeforeAnythingIsRead() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer, path: "Today.md")
        await model.load()

        XCTAssertEqual(model.phase, .refused(
            "Tick items on the Today tab; this file is rewritten by the bridge."))
        XCTAssertEqual(writer.reads, 0, "an exempt note is not even opened")
    }

    func testATruncatedNoteIsRefused() async {
        let huge = String(repeating: "x", count: VaultNoteDocument.byteLimit + 1)
        let model = makeModel(FakeNoteWriter(text: huge))
        await model.load()

        XCTAssertEqual(model.phase, .refused(VaultNoteEditorModel.tooLongCaption))
        XCTAssertFalse(model.canSave)
    }

    func testANoteExactlyAtTheLimitIsStillEditable() async {
        let atLimit = String(repeating: "x", count: VaultNoteDocument.byteLimit)
        let model = makeModel(FakeNoteWriter(text: atLimit))
        await model.load()
        XCTAssertEqual(model.phase, .editing)
    }

    // MARK: - Saving

    func testSaveWritesAndClearsTheDirtyFlag() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        model.text = "# Kiln\n\nThe arch is cracked.\n"
        await model.save()

        XCTAssertTrue(model.didSave)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(writer.diskText, "# Kiln\n\nThe arch is cracked.\n")
        XCTAssertEqual(writer.writes.first?.kind, .edit)
        XCTAssertNil(model.error)
    }

    func testSaveGivesTheFileItsOwnLineEndingsBack() async {
        let writer = FakeNoteWriter(text: "# A\r\n\r\nbody\r\n")
        let model = makeModel(writer)
        await model.load()

        // A text view hands back LF whatever the file was.
        model.text = "# A\n\nbody, edited\n"
        await model.save()

        XCTAssertEqual(writer.diskText, "# A\r\n\r\nbody, edited\r\n")
    }

    func testSavingTwiceInARowWorks() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        model.text = note + "one\n"
        await model.save()
        model.text = note + "one\ntwo\n"
        await model.save()

        XCTAssertEqual(writer.diskText, note + "one\ntwo\n")
        XCTAssertEqual(writer.writes.count, 2)
    }

    // MARK: - Conflict

    func testAConflictAsksRatherThanWriting() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        // Somebody saves from the Mac while the editor is open.
        let theirs = note + "\nTheir paragraph.\n"
        writer.diskText = theirs

        model.text = note + "\nMy paragraph.\n"
        await model.save()

        XCTAssertEqual(model.prompt, .conflict)
        XCTAssertFalse(model.didSave)
        XCTAssertEqual(writer.diskText, theirs, "nothing may have been written")
    }

    func testConflictThenReloadTakesTheDiskVersion() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        let theirs = note + "\nTheir paragraph.\n"
        writer.diskText = theirs
        model.text = note + "\nMy paragraph.\n"
        await model.save()
        XCTAssertEqual(model.prompt, .conflict)

        await model.reloadFromDisk()

        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.text, theirs)
        XCTAssertFalse(model.isDirty)
        // And now a save lands, because the stamp is the fresh one.
        model.text = theirs + "Now mine.\n"
        await model.save()
        XCTAssertTrue(model.didSave)
        XCTAssertEqual(writer.diskText, theirs + "Now mine.\n")
    }

    func testConflictThenOverwriteTakesTheEditorsVersionButStillGuarded() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        writer.diskText = note + "\nTheir paragraph.\n"
        let mine = note + "\nMy paragraph.\n"
        model.text = mine
        await model.save()
        XCTAssertEqual(model.prompt, .conflict)

        // Two steps, deliberately.
        model.requestOverwrite()
        XCTAssertEqual(model.prompt, .confirmOverwrite)
        await model.overwrite()

        XCTAssertTrue(model.didSave)
        XCTAssertEqual(writer.diskText, mine)
        // It re-read to get the fresh stamp rather than writing unguarded.
        XCTAssertGreaterThan(writer.reads, 1)
    }

    /// A third write landing inside the confirmation must put the person back in front of
    /// the conflict, not through it.
    func testAThirdWriteDuringConfirmationReopensTheConflict() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()

        writer.diskText = note + "second\n"
        model.text = note + "mine\n"
        await model.save()
        model.requestOverwrite()

        // The overwrite's own guarded write fails too.
        writer.failNextWrites([VaultFileError.changedSinceRead("Notes/Kiln.md")])
        await model.overwrite()

        XCTAssertEqual(model.prompt, .conflict)
        XCTAssertFalse(model.didSave)
    }

    // MARK: - Cancel

    func testCancelWithNoChangesLeavesImmediately() async {
        let model = makeModel(FakeNoteWriter(text: note))
        await model.load()
        XCTAssertTrue(model.cancel())
        XCTAssertNil(model.prompt)
    }

    func testCancelWithChangesAsksOnce() async {
        let model = makeModel(FakeNoteWriter(text: note))
        await model.load()
        model.text = note + "unsaved\n"

        XCTAssertFalse(model.cancel(), "it must not leave while there is something to lose")
        XCTAssertEqual(model.prompt, .confirmDiscard)

        model.confirmDiscard()
        XCTAssertNil(model.prompt)
        XCTAssertNil(stash.stashed(forPath: "Notes/Kiln.md"), "and the stash goes too")
    }

    // MARK: - The background stash

    func testBackgroundingKeepsUnsavedTextAndItIsOfferedBack() async {
        let writer = FakeNoteWriter(text: note)
        let first = makeModel(writer)
        await first.load()
        first.text = note + "half a sentence"
        first.stashIfNeeded()

        XCTAssertEqual(stash.stashed(forPath: "Notes/Kiln.md")?.text, note + "half a sentence")

        // A new editor on the same note, as after a relaunch.
        let second = makeModel(writer)
        await second.load()

        guard case .restore(let entry) = second.prompt else {
            return XCTFail("expected the unsaved edit to be offered, got \(String(describing: second.prompt))")
        }
        XCTAssertEqual(entry.text, note + "half a sentence")
        // Offered, NOT applied.
        XCTAssertEqual(second.text, note)

        second.restore(entry)
        XCTAssertEqual(second.text, note + "half a sentence")
        XCTAssertNil(second.prompt)
    }

    func testBackgroundingWithNoChangesStashesNothing() async {
        let model = makeModel(FakeNoteWriter(text: note))
        await model.load()
        model.stashIfNeeded()
        XCTAssertNil(stash.stashed(forPath: "Notes/Kiln.md"))
    }

    func testSavingClearsTheStash() async {
        let writer = FakeNoteWriter(text: note)
        let model = makeModel(writer)
        await model.load()
        model.text = note + "typed\n"
        model.stashIfNeeded()
        XCTAssertNotNil(stash.stashed(forPath: "Notes/Kiln.md"))

        await model.save()
        XCTAssertNil(stash.stashed(forPath: "Notes/Kiln.md"))
    }

    /// The stash was overtaken: the same change was saved from another device. There is
    /// nothing to restore, so nothing is asked, and the stale stash is cleared.
    func testAStashThatMatchesTheDiskIsNotOffered() async {
        let writer = FakeNoteWriter(text: note)
        let first = makeModel(writer)
        await first.load()
        first.text = note + "same change\n"
        first.stashIfNeeded()

        writer.diskText = note + "same change\n"

        let second = makeModel(writer)
        await second.load()
        XCTAssertNil(second.prompt)
        XCTAssertNil(stash.stashed(forPath: "Notes/Kiln.md"))
    }

    func testDiscardingTheStashRemovesIt() async {
        let writer = FakeNoteWriter(text: note)
        let first = makeModel(writer)
        await first.load()
        first.text = note + "typed\n"
        first.stashIfNeeded()

        let second = makeModel(writer)
        await second.load()
        second.discardStash()

        XCTAssertNil(second.prompt)
        XCTAssertNil(stash.stashed(forPath: "Notes/Kiln.md"))
        XCTAssertEqual(second.text, note)
    }

    func testTheStashKeyIsPathSafeForALongNoteName() {
        let path = "Knowledge/People/Tag1/" + String(repeating: "A very long name ", count: 20) + ".md"
        let url = stash.url(forPath: path)
        XCTAssertLessThan(url.lastPathComponent.count, 80)
        XCTAssertEqual(url.lastPathComponent, stash.url(forPath: path).lastPathComponent,
                       "the same note must find its own stash")
        XCTAssertNotEqual(url, stash.url(forPath: path + "x"))
    }
}
