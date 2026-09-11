import XCTest
import SwiftData
@testable import JesseCore

/// The composer's unsent draft, at the layer the defect lives at: STORAGE.
///
/// Two defects, in order. The FIRST was the absence of a durable write at all — the text
/// lived in a SwiftUI `@State`, so navigating away (which destroys the view) and quitting
/// (which destroys the process) both took it. Every persistence test below therefore does
/// the one thing an in-memory fake cannot: it writes through a REAL store, drops it, and
/// opens it again.
///
/// The SECOND was what that durable write cost. Putting the draft on `JesseThread` meant a
/// keystroke dirtied the view's main `ModelContext`, whose autosave then wrote sqlite on
/// the run loop whatever the debounce in front of `save()` intended: 197 saves for 200
/// characters, measured in the simulator. `testTypingProducesNoModelMutationAndNoWrite` is
/// the regression for that, and it FAILS against the shape that shipped in 129 — there,
/// every keystroke left `context.hasChanges` true.
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
    /// reopen — which is what makes "survives a relaunch" a real assertion rather than a
    /// claim about a dictionary. `observesAppLifecycle: false` so a test's store does not
    /// answer the host process's own notifications.
    private func store(at dir: URL, quietPeriod: Duration = .seconds(60)) -> ComposerDraftStore {
        ComposerDraftStore(writer: ComposerDraftFileWriter(root: dir),
                           quietPeriod: quietPeriod,
                           observesAppLifecycle: false)
    }

    /// The store hands its writes to an actor, so a test that asserts what reached disk has
    /// to let that actor run. Polls rather than sleeps a fixed amount.
    private func settle(_ dir: URL, expecting ids: [UUID] = [],
                        timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stored = ComposerDraftFileWriter(root: dir).storedIDs()
            if ids.allSatisfy(stored.contains) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        // One more turn, so a delete or an overwrite that has no id to wait on has landed.
        try? await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - THE COST REGRESSION

    /// **The point of the whole change.** Two hundred keystrokes mutate no model, dirty no
    /// `ModelContext`, and write nothing to disk.
    ///
    /// Fails against App 1.0 (129): there `ComposerDraft.write` set four properties on the
    /// thread, so `context.hasChanges` was true after the first character and the view's
    /// autosaving main context turned that into a sqlite transaction per keystroke.
    func testTypingProducesNoModelMutationAndNoWrite() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting, quietPeriod: .seconds(60),
                                        observesAppLifecycle: false)

        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()
        XCTAssertFalse(context.hasChanges, "precondition: the context is clean")

        var typed = ""
        for i in 0..<200 {
            typed.append(Character(UnicodeScalar(97 + (i % 26))!))
            drafts.write(text: typed, for: thread.id)
            XCTAssertFalse(context.hasChanges,
                           "keystroke \(i) dirtied the model context")
        }

        let writesDuringTyping = await counting.writes
        XCTAssertEqual(writesDuringTyping, 0, "typing wrote nothing to disk")
        XCTAssertNil(thread.draftText, "and nothing was recorded on the thread row")
        XCTAssertTrue(thread.draftAttachments.isEmpty)
        XCTAssertTrue(drafts.hasUnwrittenChanges, "the text is held, waiting for a flush")

        // And the flush that follows is ONE write for the whole burst, not two hundred.
        drafts.flush(thread.id)
        await settle(dir, expecting: [thread.id])
        let writesAfterFlush = await counting.writes
        XCTAssertEqual(writesAfterFlush, 1, "two hundred keystrokes, one write")
    }

    /// The same guarantee for the picker: staging files is not a keystroke, but it must
    /// still not touch the object graph.
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

        drafts.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                             data: Data([1, 2, 3]))], for: thread.id)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "no DraftAttachment row is ever written again")
    }

    // MARK: - Exactness

    /// The headline requirement: the EXACT text, across a close and reopen of a real store.
    /// Newlines, leading and trailing whitespace, tabs, combining marks, emoji with
    /// modifiers, RTL, and a lone CR — all byte-for-byte, because a draft that comes back
    /// nearly right is a draft the user has to re-read and re-edit.
    func testExactMultilineUnicodeTextSurvivesAStoreReopen() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()
        let exact = "  line one\n\nline\ttwo — não\r\n"
            + "👩🏽‍🚀 family: 👨‍👩‍👧‍👦  e\u{301}  שלום  \u{1F1EE}\u{1F1F9}\n"
            + "  trailing spaces   "

        let first = store(at: dir)
        for prefix in stride(from: 0, to: exact.count, by: 7) {
            first.write(text: String(exact.prefix(prefix)), for: id)
        }
        first.write(text: exact, for: id)
        first.flush(id)
        await settle(dir, expecting: [id])

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, exact)
    }

    /// A composer the user deliberately EMPTIED stays empty. `""` is a state worth
    /// persisting: otherwise clearing a draft and relaunching brings it back.
    func testDeliberatelyEmptyingTheComposerPersistsTheEmptyState() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let first = store(at: dir)
        first.write(text: "half a thought", for: id)
        first.write(text: "", for: id)
        first.flush(id)
        await settle(dir, expecting: [id])

        let reopened = store(at: dir)
        XCTAssertEqual(reopened.snapshot(for: id).text, "",
                       "the emptied composer stays emptied")
        XCTAssertFalse(reopened.hasDraft(id),
                       "and an emptied draft does not keep a turn-less conversation alive")
    }

    /// Two conversations, two drafts, no bleed. A → B → A is the navigation this exists for.
    func testTwoConversationsKeepTheirOwnDrafts() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let a = UUID(), b = UUID()

        let first = store(at: dir)
        first.write(text: "for A", for: a)
        first.write(text: "for B", for: b)
        first.flushAll()
        await settle(dir, expecting: [a, b])

        let reopened = store(at: dir)
        XCTAssertEqual(reopened.snapshot(for: a).text, "for A")
        XCTAssertEqual(reopened.snapshot(for: b).text, "for B")
    }

    /// A picker or a transcription that completes AFTER the user has navigated away writes
    /// to the conversation it was started from, not the one on screen.
    func testAnAsynchronousWriteLandsOnItsOwnConversation() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let origin = UUID(), visible = UUID()

        drafts.write(text: "typed in the visible one", for: visible)
        drafts.writeFiles([ComposerDraftFile(filename: "late.png", mime: "image/png",
                                             data: Data([9]))], for: origin)

        XCTAssertEqual(drafts.snapshot(for: origin).files.map(\.filename), ["late.png"],
                       "the late picker landed on the conversation it was started from")
        XCTAssertEqual(drafts.snapshot(for: visible).text, "typed in the visible one")
        XCTAssertTrue(drafts.snapshot(for: visible).files.isEmpty,
                      "and not on the one the user is looking at")
    }

    // MARK: - Attachments

    /// Staged files survive a reopen with their bytes intact — and the bytes live in their
    /// own files, not base64'd into the document that gets rewritten every quiet period.
    func testStagedFilesSurviveAReopenWithTheirBytes() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()
        let png = Data(repeating: 0x42, count: 4096)
        let pdf = Data(repeating: 0x25, count: 2048)

        let first = store(at: dir)
        first.write(text: "look at these", for: id)
        first.writeFiles([
            ComposerDraftFile(filename: "shot.png", mime: "image/png", data: png),
            ComposerDraftFile(filename: "invoice.pdf", mime: "application/pdf", data: pdf),
        ], for: id)
        first.flush(id)
        await settle(dir, expecting: [id])

        let restored = store(at: dir).snapshot(for: id)
        XCTAssertEqual(restored.text, "look at these")
        XCTAssertEqual(restored.files.map(\.filename), ["shot.png", "invoice.pdf"],
                       "in the order they were staged")
        XCTAssertEqual(restored.files.map(\.data), [png, pdf])

        let json = try Data(contentsOf: dir.appendingPathComponent(id.uuidString)
            .appendingPathComponent("draft.json"))
        XCTAssertLessThan(json.count, 1024,
                          "the document names the files; it does not carry their bytes")
    }

    /// Replacing the staged set removes what is no longer staged.
    func testWritingFilesReplacesTheStagedSet() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        let a = ComposerDraftFile(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))
        let b = ComposerDraftFile(filename: "b.png", mime: "image/png", data: Data([4, 5, 6]))

        drafts.writeFiles([a, b], for: id)
        XCTAssertEqual(drafts.snapshot(for: id).files.count, 2)
        drafts.writeFiles([b], for: id)
        XCTAssertEqual(drafts.snapshot(for: id).files.map(\.filename), ["b.png"])
    }

    /// Both writers report whether anything changed, so a caller can skip work for an edit
    /// that was not one.
    func testWritesReportWhetherAnythingChanged() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        let file = ComposerDraftFile(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))

        XCTAssertTrue(drafts.write(text: "hello", for: id))
        XCTAssertFalse(drafts.write(text: "hello", for: id), "the same text is not an edit")
        XCTAssertTrue(drafts.write(text: "hello!", for: id))
        XCTAssertTrue(drafts.writeFiles([file], for: id))
        XCTAssertFalse(drafts.writeFiles([file], for: id),
                       "the same file, by name, type and length, is not a change")
    }

    // MARK: - The reaper exemption

    /// `hasDraft` is what both shells' empty-thread reapers consult, so pin its three
    /// answers. A conversation the store has never heard of must answer false without
    /// touching the disk at all — that is the reaper's whole cost now.
    func testHasDraftIsTheReaperExemption() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()

        XCTAssertFalse(drafts.hasDraft(id), "a conversation with no draft is reapable")
        XCTAssertFalse(drafts.hasDraft(UUID()), "and so is one the store has never seen")

        drafts.write(text: "unsent", for: id)
        XCTAssertTrue(drafts.hasDraft(id), "a typed draft exempts it")

        drafts.write(text: "", for: id)
        XCTAssertFalse(drafts.hasDraft(id), "a deliberately emptied draft does not")

        drafts.writeFiles([ComposerDraftFile(filename: "a.pdf", mime: "application/pdf",
                                             data: Data([1]))], for: id)
        XCTAssertTrue(drafts.hasDraft(id), "a staged file exempts it on its own")
    }

    /// Deleting a conversation deletes its draft and its staged bytes — which is now an
    /// explicit call rather than a SwiftData cascade, so it is worth pinning.
    func testDeletingAConversationDeletesItsDraftAndItsFiles() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir)
        drafts.write(text: "unsent", for: id)
        drafts.writeFiles([ComposerDraftFile(filename: "big.png", mime: "image/png",
                                             data: Data(repeating: 0x11, count: 4096))],
                          for: id)
        drafts.flush(id)
        await settle(dir, expecting: [id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(id.uuidString).path))

        drafts.delete(id)
        await settle(dir)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(id.uuidString).path),
            "the draft and its bytes are gone from disk")
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "")
    }

    /// The backstop for a delete this store never saw — one that arrived from another
    /// device, or a path that forgot to call `delete`.
    func testSweepDropsDraftsForConversationsThatNoLongerExist() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let live = UUID(), gone = UUID()

        let first = store(at: dir)
        first.write(text: "still here", for: live)
        first.write(text: "orphaned", for: gone)
        first.flushAll()
        await settle(dir, expecting: [live, gone])

        let reopened = store(at: dir)
        reopened.sweep(keeping: [live])
        await settle(dir)

        XCTAssertEqual(store(at: dir).snapshot(for: live).text, "still here")
        XCTAssertEqual(store(at: dir).snapshot(for: gone).text, "",
                       "the orphan is gone")
    }

    // MARK: - The send handoff

    /// `release` takes the draft and hands back what it took.
    func testReleaseTakesTheDraftAndReportsWhatItTook() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        drafts.write(text: "on its way", pendingRecording: "memo.m4a",
                     contextLabel: "Lunch · Aug 22", for: id)
        drafts.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                             data: Data([1]))], for: id)

        let released = drafts.release(for: id)
        XCTAssertEqual(released.text, "on its way")
        XCTAssertEqual(released.pendingRecording, "memo.m4a")
        XCTAssertEqual(released.contextLabel, "Lunch · Aug 22")
        XCTAssertEqual(released.files.map(\.filename), ["a.png"])

        XCTAssertEqual(drafts.snapshot(for: id).text, "")
        XCTAssertFalse(drafts.hasDraft(id))
        await settle(dir)
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "",
                       "and it is gone from disk too, not just from memory")
    }

    /// A released draft can be put back whole.
    func testRestorePutsAReleasedDraftBackWhole() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let first = store(at: dir)
        first.write(text: "kept after all", pendingRecording: "memo.m4a",
                    contextLabel: "Lunch · Aug 22", for: id)
        first.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                            data: Data([1, 2, 3]))], for: id)
        let released = first.release(for: id)
        first.restore(released, for: id)
        first.flush(id)
        await settle(dir, expecting: [id])

        let restored = store(at: dir).snapshot(for: id)
        XCTAssertEqual(restored.text, "kept after all")
        XCTAssertEqual(restored.pendingRecording, "memo.m4a")
        XCTAssertEqual(restored.contextLabel, "Lunch · Aug 22")
        XCTAssertEqual(restored.files.map(\.filename), ["a.png"])
        XCTAssertEqual(restored.files.first?.data, Data([1, 2, 3]))
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

    /// A recording still transcribing when the composer was lost is NAMED on restore, once.
    func testAPendingRecordingIsReportedOnceAndThenCleared() {
        let dir = draftDirectory()
        defer { remove(dir) }
        let drafts = store(at: dir)
        let id = UUID()
        drafts.write(text: "typed while it read the audio", pendingRecording: "memo.m4a",
                     for: id)

        let first = drafts.snapshot(for: id)
        XCTAssertEqual(first.pendingRecording, "memo.m4a")
        XCTAssertNotNil(ComposerDraftNotice.message(for: first, contextStillAttached: false))

        drafts.clearNotices(for: id)
        let second = drafts.snapshot(for: id)
        XCTAssertEqual(second.text, "typed while it read the audio", "the text is untouched")
        XCTAssertNil(second.pendingRecording, "the marker is one-shot")
        XCTAssertNil(ComposerDraftNotice.message(for: second, contextStillAttached: false))
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

    /// Both losses at once are reported together.
    func testBothLossesAreReportedTogether() {
        let snapshot = ComposerDraftSnapshot(text: "x", pendingRecording: "memo.m4a",
                                             contextLabel: "Lunch · Aug 22")
        let notice = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertTrue(notice?.contains("memo.m4a") ?? false)
        XCTAssertTrue(notice?.contains("Lunch · Aug 22") ?? false)
    }

    /// An ordinary draft says nothing at all.
    func testAnIntactDraftHasNoNotice() {
        XCTAssertNil(ComposerDraftNotice.message(for: ComposerDraftSnapshot(text: "just text"),
                                                 contextStillAttached: false))
    }

    // MARK: - The durability boundary

    /// The quiet period fires on its own. Nothing about durability depends on a
    /// disappearance or a termination callback — those only make the window ZERO.
    func testAnIdleDraftReachesDiskOnItsOwnAfterTheQuietPeriod() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()
        let drafts = store(at: dir, quietPeriod: .milliseconds(20))
        drafts.write(text: "left alone for a moment", for: id)
        XCTAssertTrue(drafts.hasUnwrittenChanges)

        await settle(dir, expecting: [id], timeout: 4)
        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "left alone for a moment",
                       "the trailing write fires without anyone asking it to")
        XCTAssertFalse(drafts.hasUnwrittenChanges)
    }

    /// A burst of typing coalesces to ONE write. That is the difference between this shape
    /// and the one it replaces, stated at the store's own layer.
    func testABurstOfEditsCoalescesToOneWrite() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let counting = CountingWriter(inner: ComposerDraftFileWriter(root: dir))
        let drafts = ComposerDraftStore(writer: counting, quietPeriod: .milliseconds(20),
                                        observesAppLifecycle: false)
        let id = UUID()
        for i in 0..<50 { drafts.write(text: String(repeating: "x", count: i + 1), for: id) }
        let midBurst = await counting.writes
        XCTAssertEqual(midBurst, 0, "nothing has been written mid-burst")

        await settle(dir, expecting: [id], timeout: 4)
        let afterBurst = await counting.writes
        XCTAssertEqual(afterBurst, 1, "fifty keystrokes, one write")
    }

    /// **THE DURABILITY BOUNDARY THE TESTS ACTUALLY DEMONSTRATE.** An edit followed by the
    /// one lifecycle event that really happens — leaving the composer — is on disk, with no
    /// termination handler, no scene-phase callback and no host autosave. The quiet period
    /// here is sixty seconds, so nothing but the explicit flush can have written it.
    func testAnEditFollowedByAFlushIsOnDiskWithNoFurtherLifecycleEvent() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir, quietPeriod: .seconds(60))
        drafts.write(text: "typed and then the phone died", for: id)
        drafts.flush(id)
        await settle(dir, expecting: [id])

        XCTAssertEqual(store(at: dir).snapshot(for: id).text,
                       "typed and then the phone died")
    }

    /// And the loss that IS accepted, pinned so nobody mistakes the guarantee for a
    /// stronger one: a process that dies inside the quiet period, with no flush, loses that
    /// window's typing. Two seconds in the app.
    func testTextTypedAndNeverFlushedInsideTheQuietPeriodIsLost() async throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let id = UUID()

        let drafts = store(at: dir, quietPeriod: .seconds(60))
        drafts.write(text: "the last few seconds", for: id)
        // No flush, no lifecycle event: the process is simply gone.

        XCTAssertEqual(store(at: dir).snapshot(for: id).text, "",
                       "a hard kill inside the quiet period loses that window — by design")
        XCTAssertTrue(drafts.hasUnwrittenChanges)
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

        // It reached disk, so the next launch reads it from there.
        await settle(dir, expecting: [thread.id])
        XCTAssertEqual(store(at: dir).snapshot(for: thread.id).text, "typed on the old build")
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

    /// The draft is LOCAL AND UNSYNCED — and now it is not even in the object graph, so
    /// everything hydration, a title mint, a model switch and a flag reconcile write cannot
    /// reach it. Drives those real writes and asserts the draft is exactly as it was.
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
        drafts.write(text: draft, for: thread.id)
        drafts.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                             data: Data([1, 2, 3]))], for: thread.id)
        drafts.flush(thread.id)
        await settle(dir, expecting: [thread.id])

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

        let after = store(at: dir).snapshot(for: thread.id)
        XCTAssertEqual(after.text, draft,
                       "a title mint, a model switch, a flag sync and an incoming reply do not touch the draft")
        XCTAssertEqual(after.files.map(\.filename), ["a.png"])
    }

    // MARK: - Inserting a staged conversation

    /// A conversation not yet in the store is inserted by its FIRST character, and by
    /// nothing else — a bare `+`-then-back still costs nothing.
    func testTypingInsertsAStagedConversation() throws {
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(schema: jesseCurrentSchema,
                                               isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let staged = JesseThread(mode: .ask)
        XCTAssertNil(staged.modelContext, "precondition: not in the store")

        XCTAssertFalse(ComposerDraftThreadInsertion.persistIfNeeded(
            staged, in: context, hasSomethingToKeep: false),
            "an empty composer does not insert an abandoned +-then-back")
        XCTAssertNil(staged.modelContext)

        XCTAssertTrue(ComposerDraftThreadInsertion.persistIfNeeded(
            staged, in: context, hasSomethingToKeep: true),
            "the first character inserts it")
        XCTAssertNotNil(staged.modelContext)
        XCTAssertFalse(context.hasChanges, "and the insert was SAVED, not left pending")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)
    }

    /// The regression `ComposerDraftUITests.testTheDraftSurvivesARelaunch` caught: a
    /// conversation the `+` button INSERTED but nobody saved. The draft used to ride a
    /// debounced `context.save()`, and that save was what quietly persisted the pending
    /// insert as well; with the draft out of the graph there is no such save, so a
    /// brand-new conversation stayed in memory and vanished on relaunch — taking the
    /// draft's only way back with it.
    func testAnInsertedButUnsavedConversationIsPersistedForItsDraft() throws {
        let dir = draftDirectory()
        defer { remove(dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let schema = jesseCurrentSchema
        let id = UUID()

        do {
            let context = ModelContext(try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: url)))
            // Exactly what the `+` button does: insert, and save nothing.
            let fresh = JesseThread(mode: .ask)
            fresh.id = id
            context.insert(fresh)
            XCTAssertNotNil(fresh.modelContext, "inserted…")
            XCTAssertTrue(context.hasChanges, "…but not on disk")

            XCTAssertTrue(ComposerDraftThreadInsertion.persistIfNeeded(
                fresh, in: context, hasSomethingToKeep: true),
                "the first character puts it on disk")
            XCTAssertFalse(context.hasChanges)
        }

        let reopened = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url)))
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "the conversation the draft belongs to outlived the process")
    }
}

/// A writer that counts. The only way to assert the thing this change exists for — that
/// typing writes NOTHING — is to ask the back end how many times it was called.
private actor CountingWriter: ComposerDraftWriting {
    private let inner: ComposerDraftFileWriter
    private(set) var writes = 0

    init(inner: ComposerDraftFileWriter) { self.inner = inner }

    nonisolated func storedIDs() -> Set<UUID> { inner.storedIDs() }
    nonisolated func load(_ id: UUID) -> ComposerDraftRecord? { inner.load(id) }

    func write(_ record: ComposerDraftRecord, for id: UUID, generation: UInt64) async {
        writes += 1
        await inner.write(record, for: id, generation: generation)
    }

    func delete(_ id: UUID, generation: UInt64) async {
        await inner.delete(id, generation: generation)
    }
}
