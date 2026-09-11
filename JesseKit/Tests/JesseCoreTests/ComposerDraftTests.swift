import XCTest
import SwiftData
@testable import JesseCore

/// The composer's unsent draft, at the layer the defects live at.
///
/// THREE defects, in order, and every one of them is still pinned below.
///
///   1. There was no durable write at all: the text lived in a SwiftUI `@State`, so
///      navigating away (which destroys the view) and quitting (which destroys the
///      process) both took it. Every persistence test therefore does the one thing an
///      in-memory fake cannot: it writes through a REAL store, drops it, and opens it
///      again.
///   2. The durable write was on `JesseThread`, so a keystroke dirtied the view's main
///      `ModelContext` and its autosave wrote sqlite on the run loop: 197 saves for 200
///      characters, measured in the simulator.
///   3. The fix for (2) still ran code on every keystroke — a dictionary assignment, a
///      dirty set, a quiet-period `Task`. Now NOTHING runs on a keystroke, because there
///      is no keystroke hook: the draft is captured at DEPARTURES.
///      `testTypingCostsNothingAndOneDepartureCostsOneWrite` is the regression for that.
@MainActor
final class ComposerDraftTests: XCTestCase {

    // MARK: - A real store on disk, opened and reopened

    private func draftDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-draft-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// A store over `dir`. Called twice per persistence test — once to write, once to
    /// reopen — which is what makes "survives a cold launch" a real assertion rather than
    /// a claim about a dictionary.
    private func store(at dir: URL) -> ComposerDraftStore {
        ComposerDraftStore(writer: ComposerDraftFileWriter(root: dir))
    }

    /// A capture, spelled the way a composer builds one.
    private func typed(_ text: String, files: [ComposerDraftFile] = [],
                       recording: String? = nil,
                       context label: String? = nil) -> ComposerDraftCapture {
        ComposerDraftCapture(text: text, files: files, pendingRecording: recording,
                             contextLabel: label)
    }

    private func file(_ name: String, _ bytes: Int, fill: UInt8 = 0x41) -> ComposerDraftFile {
        ComposerDraftFile(filename: name, mime: "image/png",
                          data: Data(repeating: fill, count: bytes))
    }

    // MARK: - THE COST REGRESSION

    /// **The point of the whole change.** Typing runs nothing: no write, no `Task`, no
    /// model mutation. One departure then writes exactly ONCE, however much was typed.
    ///
    /// The keystroke loop below is what both composers now do — append to the view's own
    /// state and call nothing — and the counting writer proves the store never heard about
    /// it: `holdsDraft` is false for the whole burst, where 131 would have held the text,
    /// marked it dirty and armed a quiet-period `Task` from the first character. A write
    /// count of zero IS a `Task` count of zero, because `persist()` is the only place this
    /// store ever creates one and every `Task` it creates ends in a `write`.
    func testTypingCostsNothingAndOneDepartureCostsOneWrite() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting)

        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()
        XCTAssertFalse(context.hasChanges, "precondition: the context is clean")

        // Two hundred keystrokes, as the composer takes them: into its own state.
        var composer = ""
        for i in 0..<200 {
            composer.append(Character(UnicodeScalar(97 + (i % 26))!))
            XCTAssertFalse(context.hasChanges, "keystroke \(i) dirtied the model context")
            XCTAssertFalse(drafts.holdsDraft(thread.id),
                           "keystroke \(i) reached the draft store")
        }
        let duringTyping = await counting.writes
        XCTAssertEqual(duringTyping, 0, "typing wrote nothing and created no task")
        XCTAssertNil(thread.draftText, "and nothing was recorded on the thread row")
        XCTAssertTrue(thread.draftAttachments.isEmpty)

        // One departure. One write, for all two hundred characters.
        ComposerDrafts.capture(typed(composer), for: thread, in: context, store: drafts)
        await drafts.settle()
        let writeCount1 = await counting.writes
        XCTAssertEqual(writeCount1, 1, "two hundred keystrokes, one write")
        XCTAssertEqual(store(at: dir).snapshot(for: thread.id).text, composer)
    }

    /// A departure from an UNTOUCHED composer writes nothing either — otherwise every
    /// backgrounding and every conversation switch would pay for a file write for no
    /// reason.
    func testDeparturesThatChangeNothingWriteNothing() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting)
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        // Ten departures from a composer nobody ever typed in.
        for _ in 0..<10 {
            XCTAssertFalse(ComposerDrafts.capture(typed(""), for: thread, in: context,
                                                  store: drafts))
        }
        let writeCount2 = await counting.writes
        XCTAssertEqual(writeCount2, 0)
        XCTAssertNil(thread.draftText)

        // One real edit, then ten more departures with nothing changed.
        XCTAssertTrue(ComposerDrafts.capture(typed("something"), for: thread, in: context,
                                             store: drafts))
        for _ in 0..<10 {
            XCTAssertFalse(ComposerDrafts.capture(typed("something"), for: thread,
                                                  in: context, store: drafts))
        }
        await drafts.settle()
        let writeCount3 = await counting.writes
        XCTAssertEqual(writeCount3, 1, "one edit, one write, ten free departures")
    }

    /// Staging a file is not a keystroke, but it must still not touch the object graph.
    func testStagingFilesDoesNotDirtyTheModelContext() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        drafts.capture(typed("", files: [file("a.png", 3)]), for: thread.id)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "no DraftAttachment row is ever written again")
    }

    // MARK: - THE SINGLE WRITER

    /// Every route that can change a draft ends at ONE writer, and there is no other way
    /// to produce a write. The counting fake is the whole proof: if a future call site
    /// reached the file directly, this number would not move.
    func testEveryRouteThatChangesADraftGoesThroughTheOneWriter() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting)
        let a = UUID(), b = UUID()

        let writeCount4 = await counting.writes
        XCTAssertEqual(writeCount4, 0, "opening the store writes nothing")

        drafts.capture(typed("one"), for: a)              // a departure
        drafts.capture(typed("two"), for: b)              // another conversation's
        drafts.release(for: a)                            // a send
        drafts.delete(b)                                  // a conversation deleted
        drafts.capture(typed("three"), for: a)
        drafts.sweep(keeping: [])                         // the launch backstop
        await drafts.settle()
        let writeCount5 = await counting.writes
        XCTAssertEqual(writeCount5, 6, "six changes, six writes, no others")

        // And the no-ops in the same family write nothing at all.
        drafts.release(for: a)
        drafts.delete(b)
        drafts.sweep(keeping: [])
        drafts.clearNotices(for: a)
        await drafts.settle()
        let writeCount6 = await counting.writes
        XCTAssertEqual(writeCount6, 6,
                       "releasing, deleting and sweeping nothing costs nothing")
    }

    /// Writes land in the order they were asked for. Two departures a microsecond apart —
    /// `onDisappear` followed by the scene leaving the foreground — must not race, and
    /// there is no generation counter here to keep them in step.
    func testTwoDeparturesInARowLandInOrder() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        for i in 0..<40 { drafts.capture(typed("edit \(i)"), for: id) }
        await drafts.settle()

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "edit 39",
                       "the last departure is what is on disk")
    }

    // MARK: - Several conversations at once

    /// **The everyday case this is shaped for.** Three conversations, each holding its own
    /// unsent text at the same time, surviving both a switch between them and a cold
    /// launch.
    func testThreeConversationsHoldTheirOwnDraftsAcrossASwitchAndAColdLaunch() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let a = UUID(), b = UUID(), c = UUID()

        let live = store(at: dir)
        // A → B → C, each departure capturing the one being left.
        live.capture(typed("about the invoice"), for: a)
        live.capture(typed("re: Thursday\n\nsecond paragraph"), for: b)
        live.capture(typed("   "), for: c)
        // Back to A, edit, leave again. B and C are untouched by it.
        live.capture(typed("about the invoice — and the credit note"), for: a)

        XCTAssertEqual(live.snapshot(for: a).text, "about the invoice — and the credit note")
        XCTAssertEqual(live.snapshot(for: b).text, "re: Thursday\n\nsecond paragraph")
        XCTAssertEqual(live.snapshot(for: c).text, "   ")

        await live.settle()
        let coldLaunch = store(at: dir)
        XCTAssertEqual(coldLaunch.snapshot(for: a).text,
                       "about the invoice — and the credit note")
        XCTAssertEqual(coldLaunch.snapshot(for: b).text, "re: Thursday\n\nsecond paragraph")
        XCTAssertEqual(coldLaunch.snapshot(for: c).text, "   ")
    }

    /// A late departure — a picker or a transcription finishing after the user has moved
    /// on — records the conversation it belongs to, not the one on screen.
    func testALateDepartureLandsOnItsOwnConversation() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let origin = UUID(), visible = UUID()

        drafts.capture(typed("typed in the visible one"), for: visible)
        drafts.capture(typed("", files: [file("late.png", 1)]), for: origin)

        XCTAssertEqual(drafts.snapshot(for: origin).files.map(\.filename), ["late.png"])
        XCTAssertEqual(drafts.snapshot(for: visible).text, "typed in the visible one")
        XCTAssertTrue(drafts.snapshot(for: visible).files.isEmpty,
                      "and not on the one the user is looking at")
    }

    // MARK: - Exactness

    /// The headline requirement: the EXACT text, across a close and reopen of a real store.
    /// Newlines, leading and trailing whitespace, tabs, combining marks, emoji with
    /// modifiers, RTL, and a lone CR — all byte-for-byte, because a draft that comes back
    /// nearly right is a draft the user has to re-read and re-edit.
    func testExactMultilineUnicodeTextSurvivesAColdLaunch() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()
        let exact = "  line one\n\nline\ttwo — não\r\n"
            + "👩🏽‍🚀 family: 👨‍👩‍👧‍👦  e\u{301}  שלום  \u{1F1EE}\u{1F1F9}\n"
            + "  trailing spaces   "

        let first = store(at: dir)
        first.capture(typed(exact), for: id)
        await first.settle()

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, exact)
    }

    /// A composer the user deliberately EMPTIED stays empty. `""` is a state worth
    /// persisting: otherwise clearing a draft and relaunching brings it back.
    func testDeliberatelyEmptyingTheComposerPersistsTheEmptyState() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let first = store(at: dir)
        first.capture(typed("half a thought"), for: id)
        first.capture(typed(""), for: id)
        await first.settle()

        let reopened = store(at: dir)
        XCTAssertEqual(reopened.snapshot(for: id).text, "",
                       "the emptied composer stays emptied")
        XCTAssertFalse(reopened.hasDraft(id),
                       "and an emptied draft does not keep a turn-less conversation alive")
    }

    // MARK: - Staged files: in memory, and honest about it

    /// Staged files survive a SWITCH between conversations, bytes intact. That is what the
    /// dictionary is for.
    func testStagedFilesSurviveASwitchBetweenConversations() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let a = UUID(), b = UUID()
        let png = Data(repeating: 0x42, count: 4096)
        let pdf = Data(repeating: 0x25, count: 2048)

        drafts.capture(ComposerDraftCapture(text: "look at these", files: [
            ComposerDraftFile(filename: "shot.png", mime: "image/png", data: png),
            ComposerDraftFile(filename: "invoice.pdf", mime: "application/pdf", data: pdf),
        ]), for: a)
        drafts.capture(typed("something else entirely"), for: b)

        let back = drafts.snapshot(for: a)
        XCTAssertEqual(back.text, "look at these")
        XCTAssertEqual(back.files.map(\.filename), ["shot.png", "invoice.pdf"],
                       "in the order they were staged")
        XCTAssertEqual(back.files.map(\.data), [png, pdf])
        XCTAssertEqual(back.lostFiles, 0, "nothing was lost, so nothing is claimed lost")
    }

    /// **The trade, stated as a test.** Staged files do NOT survive a cold launch — they
    /// are never written to disk — and the restored composer SAYS SO rather than quietly
    /// becoming a message with no attachment.
    func testStagedFilesDoNotSurviveAColdLaunchAndTheComposerSaysSo() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let first = store(at: dir)
        first.capture(ComposerDraftCapture(text: "here are the two pages", files: [
            file("page-1.png", 4096), file("page-2.png", 4096),
        ]), for: id)
        await first.settle()

        let coldLaunch = store(at: dir).snapshot(for: id)
        XCTAssertEqual(coldLaunch.text, "here are the two pages", "the text came back")
        XCTAssertTrue(coldLaunch.files.isEmpty, "the bytes did not")
        XCTAssertEqual(coldLaunch.lostFiles, 2)
        let notice = ComposerDraftNotice.message(for: coldLaunch, contextStillAttached: false)
        XCTAssertTrue(notice?.contains("2 files") ?? false,
                      "and it is named, not silently dropped: \(notice ?? "nil")")
    }

    /// Replacing the staged set replaces what is held, and drops the loss claim with it.
    func testCapturingADifferentFileSetReplacesIt() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        drafts.capture(typed("", files: [file("a.png", 3), file("b.png", 3, fill: 0x42)]),
                       for: id)
        XCTAssertEqual(drafts.snapshot(for: id).files.count, 2)
        drafts.capture(typed("", files: [file("b.png", 3, fill: 0x42)]), for: id)
        XCTAssertEqual(drafts.snapshot(for: id).files.map(\.filename), ["b.png"])
        XCTAssertEqual(drafts.snapshot(for: id).lostFiles, 0)
    }

    /// The in-memory budget is a real bound. Staged files go first, oldest conversation
    /// first, and the conversation just captured is never the one thrown away.
    func testTheByteCapEvictsTheOldestFilesFirstAndKeepsTheText() {
        let dir = draftDirectory()
        defer { remove(dir) }
        // Room for roughly two of the three file sets below.
        let drafts = ComposerDraftStore(writer: ComposerDraftFileWriter(root: dir),
                                        byteCap: 250_000)
        let oldest = UUID(), middle = UUID(), newest = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        drafts.capture(typed("oldest text", files: [file("o.png", 100_000)]),
                       for: oldest, now: base)
        drafts.capture(typed("middle text", files: [file("m.png", 100_000)]),
                       for: middle, now: base.addingTimeInterval(60))
        drafts.capture(typed("newest text", files: [file("n.png", 100_000)]),
                       for: newest, now: base.addingTimeInterval(120))

        XCTAssertTrue(drafts.snapshot(for: oldest).files.isEmpty,
                      "the least recently updated conversation lost its files")
        XCTAssertEqual(drafts.snapshot(for: oldest).lostFiles, 1, "and says so")
        XCTAssertEqual(drafts.snapshot(for: oldest).text, "oldest text",
                       "TEXT LAST: it kept its text")
        XCTAssertEqual(drafts.snapshot(for: middle).files.count, 1, "the middle one is intact")
        XCTAssertEqual(drafts.snapshot(for: newest).files.count, 1,
                       "and the one just captured is never the one thrown away")
    }

    /// A single conversation staging more than the whole budget drops its own files rather
    /// than blowing the bound.
    func testAConversationBiggerThanTheWholeBudgetDropsItsOwnFiles() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = ComposerDraftStore(writer: ComposerDraftFileWriter(root: dir),
                                        byteCap: 50_000)
        let id = UUID()
        drafts.capture(typed("too much", files: [file("huge.png", 200_000)]), for: id)

        XCTAssertTrue(drafts.snapshot(for: id).files.isEmpty)
        XCTAssertEqual(drafts.snapshot(for: id).lostFiles, 1)
        XCTAssertEqual(drafts.snapshot(for: id).text, "too much")
    }

    // MARK: - The reaper exemption

    /// `hasDraft` is what both shells' empty-thread reapers consult, so pin its answers. It
    /// is one dictionary lookup — that is the reaper's whole cost now.
    func testHasDraftIsTheReaperExemption() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        XCTAssertFalse(drafts.hasDraft(id), "a conversation with no draft is reapable")
        XCTAssertFalse(drafts.hasDraft(UUID()), "and so is one the store has never seen")

        drafts.capture(typed("unsent"), for: id)
        XCTAssertTrue(drafts.hasDraft(id), "a typed draft exempts it")

        drafts.capture(typed(""), for: id)
        XCTAssertFalse(drafts.hasDraft(id), "a deliberately emptied draft does not")

        drafts.capture(typed("", files: [file("a.pdf", 1)]), for: id)
        XCTAssertTrue(drafts.hasDraft(id), "a staged file exempts it on its own")
    }

    /// Deleting a conversation deletes its draft — an explicit call now, not a SwiftData
    /// cascade, so it is worth pinning.
    func testDeletingAConversationDeletesItsDraft() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir)
        drafts.capture(typed("unsent", files: [file("big.png", 4096)]), for: id)
        await drafts.settle()
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "unsent")

        drafts.delete(id)
        await drafts.settle()
        XCTAssertFalse(drafts.holdsDraft(id))
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "",
                       "gone from disk too, not just from memory")
    }

    /// The backstop for a delete this store never saw — one that arrived from another
    /// device, or a path that forgot to call `delete`.
    func testSweepDropsDraftsForConversationsThatNoLongerExist() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let live = UUID(), gone = UUID()

        let first = store(at: dir)
        first.capture(typed("still here"), for: live)
        first.capture(typed("orphaned"), for: gone)
        await first.settle()

        let reopened = store(at: dir)
        reopened.sweep(keeping: [live])
        await reopened.settle()

        XCTAssertEqual(store(at: dir).snapshot(for: live).text, "still here")
        XCTAssertEqual(store(at: dir).snapshot(for: gone).text, "", "the orphan is gone")
    }

    // MARK: - The send handoff

    /// `release` takes the draft and hands back what it took.
    func testReleaseTakesTheDraftAndReportsWhatItTook() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        drafts.capture(typed("on its way", files: [file("a.png", 1)],
                             recording: "memo.m4a", context: "Lunch · Aug 22"), for: id)

        let released = drafts.release(for: id)
        XCTAssertEqual(released.text, "on its way")
        XCTAssertEqual(released.pendingRecording, "memo.m4a")
        XCTAssertEqual(released.contextLabel, "Lunch · Aug 22")
        XCTAssertEqual(released.files.map(\.filename), ["a.png"])

        XCTAssertEqual(drafts.snapshot(for: id).text, "")
        XCTAssertFalse(drafts.hasDraft(id))
        await drafts.settle()
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "",
                       "and it is gone from disk too, not just from memory")
    }

    // MARK: - Restore, as both shells call it

    /// The one shared restore: text, files and the notice, in one call.
    func testRestoreReturnsTheTextTheFilesAndTheNotice() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        drafts.capture(typed("mid sentence", files: [file("a.png", 8)],
                             recording: "memo.m4a"), for: thread.id)

        let restored = ComposerDrafts.restore(for: thread, newestUserTurn: nil,
                                              contextStillAttached: false, store: drafts)
        XCTAssertEqual(restored.text, "mid sentence")
        XCTAssertEqual(restored.files.map(\.filename), ["a.png"])
        XCTAssertTrue(restored.notice?.contains("memo.m4a") ?? false)

        // The markers are one-shot: a second restore says nothing.
        let again = ComposerDrafts.restore(for: thread, newestUserTurn: nil,
                                           contextStillAttached: false, store: drafts)
        XCTAssertEqual(again.text, "mid sentence", "the text is untouched")
        XCTAssertNil(again.notice)
    }

    /// A restore discards a draft whose message already went, and takes the file with it.
    func testRestoreDiscardsADraftTheSendAlreadySpent() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        let sent = Date()
        drafts.capture(typed("the message"), for: thread.id,
                       now: sent.addingTimeInterval(-0.2))

        let restored = ComposerDrafts.restore(
            for: thread, newestUserTurn: (text: "the message", createdAt: sent),
            contextStillAttached: false, store: drafts)
        XCTAssertEqual(restored, .nothing, "a sent message does not come back as unsent")
        XCTAssertFalse(drafts.holdsDraft(thread.id))
    }

    /// A never-saved conversation is inserted at the CAPTURE, so a draft restored after a
    /// cold launch still has a conversation to belong to — and an untouched composer still
    /// inserts nothing.
    func testCaptureInsertsANeverSavedConversationAndOnlyThen() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let staged = JesseThread(mode: .ask)
        XCTAssertNil(staged.modelContext, "precondition: not in the store")

        ComposerDrafts.capture(typed(""), for: staged, in: context, store: drafts)
        XCTAssertNil(staged.modelContext,
                     "a departure from an empty composer is still a +-then-back")

        ComposerDrafts.capture(typed("about this reading"), for: staged, in: context,
                               store: drafts)
        XCTAssertNotNil(staged.modelContext)
        XCTAssertFalse(context.hasChanges, "and the insert was SAVED, not left pending")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)
    }

    // MARK: - A draft a send already spent

    /// The replacement for the one-save atomicity the old shape had. A kill between "the
    /// turn is saved" and "the draft is released" leaves both on disk; a restore must
    /// recognise the draft as already sent rather than put the message back in the
    /// composer.
    func testADraftMatchingTheNewestUserTurnAndPredatingItIsSpent() {
        let sent = Date(timeIntervalSince1970: 1_700_000_100)
        let draft = ComposerDraftSnapshot(text: "  the message  ",
                                          updatedAt: sent.addingTimeInterval(-0.2))
        XCTAssertTrue(ComposerDraftStaleness.isSpent(
            draft, newestUserTurn: (text: "the message", createdAt: sent)),
            "the draft is the turn: it went, and must not come back as unsent")
    }

    /// The timestamp half. The user retyped the same message AFTER it was sent — that is a
    /// live draft, and eating it would be the loss this feature exists to prevent.
    func testRetypingTheSameMessageAfterSendingItIsALiveDraft() {
        let sent = Date(timeIntervalSince1970: 1_700_000_100)
        let draft = ComposerDraftSnapshot(text: "the message",
                                          updatedAt: sent.addingTimeInterval(30))
        XCTAssertFalse(ComposerDraftStaleness.isSpent(
            draft, newestUserTurn: (text: "the message", createdAt: sent)))
    }

    /// The text half. Any other draft on a thread that has been sent to is untouched.
    func testADifferentDraftOnASentThreadIsNotSpent() {
        let sent = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertFalse(ComposerDraftStaleness.isSpent(
            ComposerDraftSnapshot(text: "a different thought",
                                  updatedAt: sent.addingTimeInterval(-1)),
            newestUserTurn: (text: "the message", createdAt: sent)))
        XCTAssertFalse(ComposerDraftStaleness.isSpent(
            ComposerDraftSnapshot(text: "anything", updatedAt: sent),
            newestUserTurn: nil),
            "a conversation with no user turn can spend nothing")
        XCTAssertFalse(ComposerDraftStaleness.isSpent(
            ComposerDraftSnapshot(text: "", updatedAt: sent.addingTimeInterval(-1)),
            newestUserTurn: (text: "", createdAt: sent)),
            "an emptied composer is not 'the same as' an empty send")
    }

    // MARK: - Notices

    /// A recording still transcribing when the composer was left is NAMED on restore, once.
    func testAPendingRecordingIsReportedOnceAndThenCleared() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        drafts.capture(typed("typed while it read the audio", recording: "memo.m4a"), for: id)

        let first = drafts.snapshot(for: id)
        XCTAssertEqual(first.pendingRecording, "memo.m4a")
        XCTAssertNotNil(ComposerDraftNotice.message(for: first, contextStillAttached: false))

        drafts.clearNotices(for: id)
        let second = drafts.snapshot(for: id)
        XCTAssertEqual(second.text, "typed while it read the audio", "the text is untouched")
        XCTAssertNil(second.pendingRecording, "the marker is one-shot")
        XCTAssertNil(ComposerDraftNotice.message(for: second, contextStillAttached: false))
    }

    /// Clearing the notices writes nothing: it happens on APPEAR, which is not a departure.
    func testClearingNoticesIsNotADeparture() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting)
        let id = UUID()
        drafts.capture(typed("x", recording: "memo.m4a"), for: id)
        await drafts.settle()
        let afterCapture = await counting.writes

        drafts.clearNotices(for: id)
        await drafts.settle()
        let writeCount7 = await counting.writes
        XCTAssertEqual(writeCount7, afterCapture,
                       "appearing costs no write; the next departure records the truth")
    }

    /// The recording notice names the file and says the audio is already gone.
    func testTheRecordingNoticeNamesTheRecording() {
        let snapshot = ComposerDraftSnapshot(text: "my notes so far",
                                             pendingRecording: "standup.m4a")
        let notice = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertTrue(notice?.contains("standup.m4a") ?? false)
    }

    /// The context notice fires only when the context is really gone.
    func testTheContextNoticeFiresOnlyWhenTheContextIsGone() {
        let snapshot = ComposerDraftSnapshot(text: "why is this so high?",
                                             contextLabel: "Lunch · Aug 22")
        let gone = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertTrue(gone?.contains("Lunch · Aug 22") ?? false)
        XCTAssertNil(ComposerDraftNotice.message(for: snapshot, contextStillAttached: true),
                     "still attached, nothing was lost, nothing to say")
    }

    /// All three losses at once are reported together.
    func testEveryLossIsReportedTogether() {
        let snapshot = ComposerDraftSnapshot(text: "x", pendingRecording: "memo.m4a",
                                             contextLabel: "Lunch · Aug 22", lostFiles: 1)
        let notice = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertTrue(notice?.contains("memo.m4a") ?? false)
        XCTAssertTrue(notice?.contains("Lunch · Aug 22") ?? false)
        XCTAssertTrue(notice?.contains("attach it again") ?? false)
    }

    /// An ordinary draft says nothing at all.
    func testAnIntactDraftHasNoNotice() {
        XCTAssertNil(ComposerDraftNotice.message(for: ComposerDraftSnapshot(text: "just text"),
                                                 contextStillAttached: false))
    }

    // MARK: - The durability boundary

    /// **THE GUARANTEE.** A departure puts the text on disk with no further lifecycle
    /// event, no timer and no host autosave.
    func testADepartureIsOnDiskWithNoFurtherLifecycleEvent() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir)
        drafts.capture(typed("typed and then the phone died"), for: id)
        await drafts.settle()

        XCTAssertEqual(store(at: dir).snapshot(for: id).text,
                       "typed and then the phone died")
    }

    /// **AND THE LOSS THAT IS ACCEPTED**, pinned so nobody mistakes the guarantee for a
    /// stronger one: a kill that runs no code loses whatever was typed since the last
    /// departure. On the phone that window is effectively zero, because reaching the app
    /// switcher backgrounds the app first.
    func testTypingSinceTheLastDepartureIsLostToAKillThatRunsNoCode() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir)
        drafts.capture(typed("the first half"), for: id)
        await drafts.settle()
        // …and then the user types more, and the process is simply gone. No departure ran.

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "the first half",
                       "what reached the last departure survives; the rest does not")
    }

    /// A QUIT writes on the calling thread, so the draft is on disk by the time the
    /// handler returns — no `await`, no run-loop turn, nothing left to schedule. Fails
    /// against a terminating capture that only queues an async write.
    func testATerminatingCaptureIsOnDiskBeforeItReturns() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        drafts.capture(typed("typed, then Cmd-Q"), for: id, terminating: true)

        // No `settle()`, deliberately: the process is supposed to be able to die here.
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "typed, then Cmd-Q")
    }

    /// And nothing reaches disk after it: the terminating map is the last word, so an
    /// in-flight write carrying an older one cannot land on top of it.
    func testNothingIsWrittenAfterATerminatingCapture() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        drafts.capture(typed("the last word"), for: id, terminating: true)
        drafts.capture(typed("a ghost from a dying process"), for: id)
        await drafts.settle()

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "the last word")
    }

    // MARK: - Off the 131 shape

    /// 131 wrote one directory per conversation. Upgrading adopts what they hold and
    /// removes them, so a draft in progress is not lost and the directories do not linger.
    func testTheOneThirtyOneDirectoriesAreAdoptedAndRemoved() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()
        let legacy = dir.appendingPathComponent("ComposerDrafts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("files"), withIntermediateDirectories: true)
        let doc: [String: Any] = [
            "text": "typed on the old build",
            "pendingRecording": "memo.m4a",
            "updatedAt": Date().timeIntervalSinceReferenceDate,
            "files": [["filename": "a.png", "mime": "image/png", "storedName": "0-a.png"]],
        ]
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: legacy.appendingPathComponent("draft.json"))

        let upgraded = store(at: dir)
        let snapshot = upgraded.snapshot(for: id)
        XCTAssertEqual(snapshot.text, "typed on the old build", "the text came across")
        XCTAssertEqual(snapshot.pendingRecording, "memo.m4a")
        XCTAssertEqual(snapshot.lostFiles, 1, "and the staged file is named as lost")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ComposerDrafts").path),
            "the old directories are gone, not left to linger")

        // And the adopted draft is durable from here on.
        upgraded.capture(typed("typed on the old build, plus more"), for: id)
        await upgraded.settle()
        XCTAssertEqual(store(at: dir).snapshot(for: id).text,
                       "typed on the old build, plus more")
    }

    // MARK: - Migration off the V5 columns

    /// A store still holding a draft in the V5 SwiftData columns hands it to the file store
    /// once, and the columns are left empty afterwards.
    func testTheV5ColumnsAreMovedIntoTheFileStoreOnceAndThenEmptied() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let defaults = UserDefaults(suiteName: "draft-migration-\(UUID().uuidString)")!
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // A thread drafted the OLD way — written straight to the columns, as 129 did.
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        thread.draftText = "typed on the old build"
        thread.draftPendingRecording = "memo.m4a"
        thread.draftUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let row = DraftAttachment(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))
        row.thread = thread
        context.insert(row)
        thread.draftAttachments.append(row)
        try context.save()

        let drafts = store(at: dir)
        let moved = ComposerDraftMigration.runIfNeeded(context: context, store: drafts,
                                                       defaults: defaults)
        XCTAssertEqual(moved, 1)

        let snapshot = drafts.snapshot(for: thread.id)
        XCTAssertEqual(snapshot.text, "typed on the old build")
        XCTAssertEqual(snapshot.pendingRecording, "memo.m4a")
        XCTAssertEqual(snapshot.files.map(\.filename), ["a.png"])
        XCTAssertEqual(snapshot.files.first?.data, Data([1, 2, 3]))

        XCTAssertNil(thread.draftText, "the columns are empty afterwards")
        XCTAssertNil(thread.draftPendingRecording)
        XCTAssertTrue(thread.draftAttachments.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "and the rows are deleted, not orphaned")

        XCTAssertEqual(ComposerDraftMigration.runIfNeeded(context: context, store: drafts,
                                                         defaults: defaults), 0,
                       "the second launch does not run it again")

        // The TEXT reached disk, so the next launch reads it from there; the staged file
        // did not, and the next launch says so.
        await drafts.settle()
        let next = store(at: dir).snapshot(for: thread.id)
        XCTAssertEqual(next.text, "typed on the old build")
        XCTAssertEqual(next.lostFiles, 1)
    }

    /// The V5 entity set is still declared, so a V5 store opens under the current schema
    /// with its rows intact. Dropping `DraftAttachment` would have been a non-lightweight
    /// change, which this app's automatic-migration strategy cannot express.
    func testAV5StoreStillOpensUnderTheCurrentSchema() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let id = UUID()
        let before = Schema(versionedSchema: JesseSchemaV4.self)

        do {
            let container = try ModelContainer(
                for: before, configurations: ModelConfiguration(schema: before, url: url))
            let context = ModelContext(container)
            let thread = JesseThread(title: "Old chat", mode: .tell)
            thread.id = id
            thread.sessionId = "sess-old"
            thread.turns.append(Turn(role: .user, text: "from before"))
            context.insert(thread)
            try context.save()
        }

        let schema = jesseCurrentSchema
        let reopened = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url)))
        let all = try reopened.fetch(FetchDescriptor<JesseThread>())
        let migrated = try XCTUnwrap(all.first { $0.id == id })
        XCTAssertEqual(migrated.title, "Old chat")
        XCTAssertEqual(migrated.orderedTurns.map(\.text), ["from before"])
        XCTAssertNil(migrated.draftText, "the legacy columns are still there, and still nil")
        XCTAssertTrue(migrated.draftAttachments.isEmpty)
    }

    /// The draft is LOCAL AND UNSYNCED — and not in the object graph, so everything
    /// hydration, a title mint, a model switch and a flag reconcile write cannot reach it.
    /// Drives those real writes and asserts the draft is exactly as it was.
    func testHydrationTitlesModelSwitchesAndFlagSyncAllLeaveTheDraftAlone() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let draft = "half a sentence about the\nthing"
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        let drafts = store(at: dir)
        drafts.capture(typed(draft, files: [file("a.png", 3)]), for: thread.id)
        await drafts.settle()

        // Everything a sync, a hydration or a switch actually writes.
        thread.title = "A title derived from the first turn"
        thread.aiTitle = "A minted title"
        thread.titleSourceKey = "content-key-2"
        thread.sessionId = "sess-new"
        thread.conversationId = JesseThread.mintConversationId()
        thread.registeredAt = Date()
        thread.selectedModelID = "claude-opus-5"
        thread.selectedEffort = "high"
        thread.lastDeliveredJobId = "job-9"
        thread.setFavorite(true, now: Date())
        thread.setArchived(true, now: Date())
        thread.turns.append(Turn(role: .jesse, text: "a reply that arrived meanwhile"))
        thread.updatedAt = Date()
        try context.save()

        XCTAssertEqual(drafts.snapshot(for: thread.id).text, draft,
                       "a title mint, a model switch, a flag sync and an incoming reply do not touch the draft")
        XCTAssertEqual(drafts.snapshot(for: thread.id).files.map(\.filename), ["a.png"])
        XCTAssertEqual(store(at: dir).snapshot(for: thread.id).text, draft)
    }
}

/// A writer that counts. The only way to assert the two things this change exists for —
/// that typing writes NOTHING, and that every departure on both shells routes through this
/// one door — is to ask the back end how many times it was called.
private actor CountingWriter: ComposerDraftWriting {
    private let inner: ComposerDraftFileWriter
    private(set) var writes = 0

    init(inner: ComposerDraftFileWriter) { self.inner = inner }

    nonisolated func load() -> [UUID: ComposerDraftPersisted] { inner.load() }

    func write(_ map: [UUID: ComposerDraftPersisted]) async {
        writes += 1
        await inner.write(map)
    }

    nonisolated func writeNow(_ map: [UUID: ComposerDraftPersisted]) {
        Task { await self.countSynchronousWrite() }
        inner.writeNow(map)
    }

    private func countSynchronousWrite() { writes += 1 }
}
