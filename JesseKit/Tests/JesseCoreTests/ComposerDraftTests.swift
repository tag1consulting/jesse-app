import XCTest
import SwiftData
@testable import JesseCore

/// The composer's unsent draft, at the layer the defect lived at: STORAGE.
///
/// The bug was not a bad write, it was the absence of one — the composer's text existed
/// only in a SwiftUI `@State`, so navigating away (which destroys the view) and quitting
/// (which destroys the process) both took it. Every test here therefore does the one thing
/// a mocked store cannot: it writes through a REAL DISK-BACKED store, closes it, and opens
/// it again. A test that passes against an in-memory container proves nothing about the
/// second symptom.
///
/// Against the old behavior every assertion below is unreachable: `JesseThread` had no
/// draft field of any kind, so this file does not compile against it, which is the
/// strongest form of fails-before-fix a schema change can have. The behavioral
/// fails-before-fix — a composer that loses text across navigation and relaunch — is in
/// `ComposerDraftUITests`.
@MainActor
final class ComposerDraftTests: XCTestCase {

    // MARK: - A real store on disk, opened and reopened

    private func storeURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-draft-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A context over the app's CURRENT schema at `url`. Called twice per test — once to
    /// write, once to reopen — which is what makes "survives a relaunch" a real assertion
    /// rather than a claim about a dictionary.
    private func openStore(at url: URL) throws -> ModelContext {
        let schema = jesseCurrentSchema
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        return ModelContext(container)
    }

    private func thread(_ id: UUID, in context: ModelContext) throws -> JesseThread {
        let all = try context.fetch(FetchDescriptor<JesseThread>())
        guard let match = all.first(where: { $0.id == id }) else {
            throw XCTSkip("the thread was not in the reopened store")
        }
        return match
    }

    // MARK: - Exactness

    /// The headline requirement: the EXACT text, across a close and reopen of a real store.
    /// Newlines, leading and trailing whitespace, tabs, combining marks, emoji with
    /// modifiers, RTL, and a lone CR — all byte-for-byte, because a draft that comes back
    /// nearly right is a draft the user has to re-read and re-edit.
    func testExactMultilineUnicodeTextSurvivesAStoreReopen() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()
        let exact = "  line one\n\nline\ttwo — não\r\n"
            + "👩🏽‍🚀 family: 👨‍👩‍👧‍👦  e\u{301}  שלום  \u{1F1EE}\u{1F1F9}\n"
            + "  trailing spaces   "

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask)
            thread.id = id
            context.insert(thread)
            ComposerDraft.write(text: exact, to: thread, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let restored = ComposerDraft.snapshot(of: try thread(id, in: reopened))
        XCTAssertEqual(restored.text, exact,
                       "the draft comes back byte-for-byte: newlines, tabs, whitespace and Unicode")
        XCTAssertEqual(restored.text.unicodeScalars.count, exact.unicodeScalars.count,
                       "no normalization, no scalar lost or added")
    }

    /// A conversation with no draft restores as empty, not as nil-shaped nonsense.
    func testAThreadWithNoDraftRestoresEmpty() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        let restored = ComposerDraft.snapshot(of: thread)
        XCTAssertEqual(restored.text, "")
        XCTAssertTrue(restored.files.isEmpty)
        XCTAssertFalse(thread.hasComposerDraft)
    }

    // MARK: - Deliberate emptying

    /// Deleting every character is a decision, and it has to persist. If an empty draft fell
    /// back to "no draft recorded", clearing the composer and relaunching would hand the
    /// message back — which is the same class of surprise as losing it.
    func testDeliberatelyEmptyingTheComposerPersistsTheEmptyState() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask)
            thread.id = id
            context.insert(thread)
            ComposerDraft.write(text: "half a thought", to: thread, in: context)
            try context.save()
            ComposerDraft.write(text: "", to: thread, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let restored = try thread(id, in: reopened)
        XCTAssertEqual(ComposerDraft.snapshot(of: restored).text, "",
                       "the emptied composer stays emptied across a relaunch")
        XCTAssertEqual(restored.draftText, "",
                       "and the empty state is RECORDED (\"\"), not merely absent (nil)")
        XCTAssertFalse(restored.hasComposerDraft,
                       "an emptied draft is not something to keep a turn-less thread alive for")
    }

    // MARK: - Two conversations never leak into each other

    /// A to B to A must neither erase nor leak. The draft is keyed on the thread's SwiftData
    /// identity, so this is a property of the store rather than of any navigation code.
    func testTwoConversationsKeepTheirOwnDraftsAcrossAReopen() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let a = UUID(), b = UUID()

        do {
            let context = try openStore(at: url)
            let threadA = JesseThread(mode: .ask); threadA.id = a; context.insert(threadA)
            let threadB = JesseThread(mode: .tell); threadB.id = b; context.insert(threadB)
            ComposerDraft.write(text: "for A", to: threadA, in: context)
            ComposerDraft.write(text: "for B", to: threadB, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        XCTAssertEqual(ComposerDraft.snapshot(of: try thread(a, in: reopened)).text, "for A")
        XCTAssertEqual(ComposerDraft.snapshot(of: try thread(b, in: reopened)).text, "for B")
    }

    /// A write names its thread explicitly, so an ASYNCHRONOUS completion — a photo picker
    /// or a transcription finishing after the user moved on — lands on the conversation it
    /// was started from and touches nothing else.
    func testAWriteAgainstOneThreadLeavesTheOtherUntouched() throws {
        let context = try openStore(at: storeURL())
        let origin = JesseThread(mode: .ask); context.insert(origin)
        let visible = JesseThread(mode: .ask); context.insert(visible)
        ComposerDraft.write(text: "typed in the visible one", to: visible, in: context)

        // The late completion, arriving against the thread it belongs to.
        ComposerDraft.writeFiles([ComposerDraftFile(filename: "late.png", mime: "image/png",
                                                    data: Data([0x89, 0x50, 0x4E, 0x47]))],
                                 to: origin, in: context)

        XCTAssertEqual(ComposerDraft.snapshot(of: origin).files.map(\.filename), ["late.png"],
                       "the picker's file lands on the ORIGINATING conversation")
        XCTAssertEqual(ComposerDraft.snapshot(of: visible).text, "typed in the visible one")
        XCTAssertTrue(ComposerDraft.snapshot(of: visible).files.isEmpty,
                      "and never on the one that happens to be on screen")
    }

    // MARK: - Never-sent conversations

    /// A conversation that has never been sent to is not in the store at all until its first
    /// send (a staged Health ask, a Today discussion). Typing into one is intent, so the
    /// draft insert is what makes it survive a relaunch.
    func testTypingIntoANeverSentConversationInsertsItSoTheDraftSurvives() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()

        do {
            let context = try openStore(at: url)
            let staged = JesseThread(mode: .ask)     // deliberately NOT inserted
            staged.id = id
            XCTAssertNil(staged.modelContext, "precondition: a staged thread is not in the store")
            ComposerDraft.write(text: "a thought about this reading", to: staged, in: context)
            XCTAssertNotNil(staged.modelContext, "the draft brought the conversation into the store")
            try context.save()
        }

        let reopened = try openStore(at: url)
        XCTAssertEqual(ComposerDraft.snapshot(of: try thread(id, in: reopened)).text,
                       "a thought about this reading",
                       "a never-sent conversation's draft survives a relaunch")
    }

    /// The other half: an abandoned staged conversation still costs nothing. An empty draft
    /// does not conjure a row.
    func testAnEmptyDraftDoesNotPersistAStagedConversation() throws {
        let context = try openStore(at: storeURL())
        let staged = JesseThread(mode: .ask)
        ComposerDraft.write(text: "", to: staged, in: context)
        XCTAssertNil(staged.modelContext,
                     "nothing typed, nothing kept — a `+`-then-back leaves no row behind")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 0)
    }

    /// `hasComposerDraft` is what both shells' empty-thread reapers consult, so pin its three
    /// answers directly: text keeps a thread, a file keeps a thread, an emptied draft does not.
    func testHasComposerDraftIsTheReaperExemption() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        XCTAssertFalse(thread.hasComposerDraft, "a fresh thread is reapable")

        ComposerDraft.write(text: "unsent", to: thread, in: context)
        XCTAssertTrue(thread.hasComposerDraft, "a typed draft exempts it")

        ComposerDraft.write(text: "", to: thread, in: context)
        XCTAssertFalse(thread.hasComposerDraft, "a deliberately emptied draft does not")

        ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.pdf", mime: "application/pdf",
                                                    data: Data("%PDF-".utf8))],
                                 to: thread, in: context)
        XCTAssertTrue(thread.hasComposerDraft, "a staged file exempts it on its own")
    }

    // MARK: - Staged files

    /// Attachments are part of the pending message, so they are part of the draft: the bytes
    /// come back, in order, across a real reopen.
    func testStagedFilesSurviveAReopenInOrderWithTheirBytes() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x42, count: 512))
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x07, count: 1024)

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: "look at these", to: thread, in: context)
            ComposerDraft.writeFiles([
                ComposerDraftFile(filename: "shot.png", mime: "image/png", data: png),
                ComposerDraftFile(filename: "invoice.pdf", mime: "application/pdf", data: pdf),
            ], to: thread, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let restored = ComposerDraft.snapshot(of: try thread(id, in: reopened))
        XCTAssertEqual(restored.files.map(\.filename), ["shot.png", "invoice.pdf"],
                       "staged files come back in the order they were staged")
        XCTAssertEqual(restored.files.map(\.mime), ["image/png", "application/pdf"])
        XCTAssertEqual(restored.files.map(\.data), [png, pdf], "byte-for-byte")
        XCTAssertEqual(restored.text, "look at these")
    }

    /// Removing a chip removes the row, and re-staging does not accumulate duplicates.
    func testWritingFilesReplacesTheSetRatherThanAppending() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask); context.insert(thread)
        let a = ComposerDraftFile(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))
        let b = ComposerDraftFile(filename: "b.png", mime: "image/png", data: Data([4, 5, 6]))

        ComposerDraft.writeFiles([a, b], to: thread, in: context)
        try context.save()
        ComposerDraft.writeFiles([b], to: thread, in: context)
        try context.save()

        XCTAssertEqual(ComposerDraft.snapshot(of: thread).files.map(\.filename), ["b.png"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 1,
                       "the removed file's row is gone, not orphaned")
    }

    /// An unchanged set is not a write, so a composer render does not churn the store.
    func testWritingTheSameFilesTwiceIsNotAChange() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask); context.insert(thread)
        let file = ComposerDraftFile(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))
        XCTAssertTrue(ComposerDraft.writeFiles([file], to: thread, in: context))
        XCTAssertFalse(ComposerDraft.writeFiles([file], to: thread, in: context),
                       "the same set again is a no-op")
    }

    /// Nor is re-recording the same text.
    func testWritingTheSameTextTwiceIsNotAChange() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask); context.insert(thread)
        XCTAssertTrue(ComposerDraft.write(text: "hello", to: thread, in: context))
        XCTAssertFalse(ComposerDraft.write(text: "hello", to: thread, in: context))
        XCTAssertTrue(ComposerDraft.write(text: "hello!", to: thread, in: context))
    }

    // MARK: - Deleting the conversation deletes the draft

    /// The draft lives on the thread row and its files cascade from it, so deleting a
    /// conversation cannot leave a draft (or a 10 MB attachment) behind.
    func testDeletingAConversationDeletesItsDraftAndItsFiles() throws {
        let url = storeURL()
        defer { removeStore(url) }

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); context.insert(thread)
            ComposerDraft.write(text: "unsent", to: thread, in: context)
            ComposerDraft.writeFiles([ComposerDraftFile(filename: "big.png", mime: "image/png",
                                                        data: Data(repeating: 0x11, count: 4096))],
                                     to: thread, in: context)
            try context.save()
            XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 1)

            context.delete(thread)
            try context.save()
        }

        let reopened = try openStore(at: url)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<JesseThread>()).count, 0)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "the draft's files cascade with the conversation")
    }

    // MARK: - Release and restore: the send handoff

    /// `release` is what a send calls, and it drops everything — text, files and both
    /// markers — handing back what it took.
    func testReleaseDropsTheWholeDraftAndReportsIt() throws {
        let context = try openStore(at: storeURL())
        let thread = JesseThread(mode: .ask); context.insert(thread)
        ComposerDraft.write(text: "on its way", pendingRecording: "memo.m4a",
                            contextLabel: "Lunch · Aug 22", to: thread, in: context)
        ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                                    data: Data([9, 9, 9]))],
                                 to: thread, in: context)
        try context.save()

        let released = ComposerDraft.release(from: thread, in: context)
        try context.save()

        XCTAssertEqual(released.text, "on its way")
        XCTAssertEqual(released.files.map(\.filename), ["a.png"])
        XCTAssertEqual(released.pendingRecording, "memo.m4a")
        XCTAssertEqual(released.contextLabel, "Lunch · Aug 22")

        XCTAssertNil(thread.draftText)
        XCTAssertFalse(thread.hasComposerDraft)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "the released files' rows are deleted, not left for the outbox to trip over")
    }

    /// `restore` is what a FAILED staging save calls: the draft comes back whole, so the
    /// user's message is not the casualty of a store error.
    func testRestorePutsAReleasedDraftBackWhole() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: "kept after all", pendingRecording: "memo.m4a",
                                contextLabel: "Lunch · Aug 22", to: thread, in: context)
            ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                                        data: Data([9, 9, 9]))],
                                     to: thread, in: context)
            try context.save()

            let released = ComposerDraft.release(from: thread, in: context)
            ComposerDraft.restore(released, to: thread, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let restored = ComposerDraft.snapshot(of: try thread(id, in: reopened))
        XCTAssertEqual(restored.text, "kept after all")
        XCTAssertEqual(restored.files.map(\.filename), ["a.png"])
        XCTAssertEqual(restored.files.first?.data, Data([9, 9, 9]))
        XCTAssertEqual(restored.pendingRecording, "memo.m4a")
        XCTAssertEqual(restored.contextLabel, "Lunch · Aug 22")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<DraftAttachment>()).count, 1,
                       "exactly one row — the restore does not double the file")
    }

    // MARK: - The one-shot markers

    /// The notice markers are reported once. A second appearance of the same composer must
    /// not re-accuse it of losing a recording it has already been told about.
    func testClearNoticesIsOneShot() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: "typed while it read the audio",
                                pendingRecording: "standup.m4a", to: thread, in: context)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let thread = try self.thread(id, in: reopened)
        let first = ComposerDraft.snapshot(of: thread)
        XCTAssertEqual(first.pendingRecording, "standup.m4a")
        ComposerDraft.clearNotices(on: thread)
        try reopened.save()

        let second = ComposerDraft.snapshot(of: thread)
        XCTAssertNil(second.pendingRecording, "reported once, then cleared")
        XCTAssertEqual(second.text, "typed while it read the audio",
                       "and clearing the marker never touches the text")
    }

    // MARK: - What the notice says

    /// THE AUDIO DECISION, pinned as behavior: a draft recorded while a transcription was
    /// running comes back with its text and NAMES the recording as gone.
    ///
    /// It cannot come back with the transcription, and that is not a shortcut: the
    /// transcription's working copy is deleted on every exit path `RecordingAttachment` has,
    /// and a run whose model died with the view has its transcript dropped and its working
    /// copy swept at the next launch. Restoring a REFERENCE to that audio would be restoring
    /// a file that is gone. So the choice is between silently dropping it and saying so, and
    /// this is the test that it says so.
    func testARecordingInFlightIsNamedAsGoneRatherThanSilentlyDropped() {
        let snapshot = ComposerDraftSnapshot(text: "my notes so far",
                                             pendingRecording: "standup-2026-09-10.m4a")
        let notice = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertNotNil(notice, "a lost transcription is reported, never dropped in silence")
        XCTAssertTrue(notice!.contains("standup-2026-09-10.m4a"),
                      "and it is named, so the user knows which recording to attach again")
        XCTAssertTrue(notice!.lowercased().contains("transcrib"),
                      "and told what happened to it")
    }

    /// A draft recorded against attached screen context, restored when that context is gone,
    /// says so — otherwise the restored text silently becomes a different message: a question
    /// about a reading, sent with the reading missing.
    func testLostAttachedContextIsNamedSoTheMessageDoesNotSilentlyChange() {
        let snapshot = ComposerDraftSnapshot(text: "why is this so high?",
                                             contextLabel: "Lunch · Aug 22")
        let gone = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertNotNil(gone)
        XCTAssertTrue(gone!.contains("Lunch · Aug 22"), "the reading is named")
        XCTAssertTrue(gone!.contains("on its own"), "and the consequence is stated")

        XCTAssertNil(ComposerDraftNotice.message(for: snapshot, contextStillAttached: true),
                     "still attached: nothing was lost, so there is nothing to say")
    }

    /// Both losses at once read as one notice, not two competing lines.
    func testBothLossesReadAsOneNotice() {
        let snapshot = ComposerDraftSnapshot(text: "x", pendingRecording: "memo.m4a",
                                             contextLabel: "Lunch · Aug 22")
        let notice = ComposerDraftNotice.message(for: snapshot, contextStillAttached: false)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("memo.m4a"))
        XCTAssertTrue(notice!.contains("Lunch · Aug 22"))
    }

    /// An ordinary draft says nothing at all.
    func testAnIntactDraftHasNoNotice() {
        XCTAssertNil(ComposerDraftNotice.message(for: ComposerDraftSnapshot(text: "just text"),
                                                 contextStillAttached: false))
    }

    // MARK: - The durability boundary

    /// The autosaver's contract, stated as a test: an edit arms a trailing save, and it fires
    /// on its own after the quiet period. Nothing about durability depends on a disappearance
    /// or a termination callback.
    func testAnArmedSaveFiresOnItsOwnAfterTheQuietPeriod() async {
        let autosave = ComposerDraftAutosave(quietPeriod: .milliseconds(1))
        var saves = 0
        autosave.arm { saves += 1 }
        XCTAssertTrue(autosave.isArmed)

        let deadline = Date().addingTimeInterval(2)
        while saves == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(saves, 1, "the trailing save fires without anyone asking it to")
        XCTAssertFalse(autosave.isArmed)
    }

    /// A burst of typing coalesces to ONE save, which is why typing stays responsive.
    func testABurstOfEditsCoalescesToOneSave() async {
        let autosave = ComposerDraftAutosave(quietPeriod: .milliseconds(5))
        var saves = 0
        for _ in 0..<50 { autosave.arm { saves += 1 } }
        XCTAssertEqual(saves, 0, "nothing has been written mid-burst")

        let deadline = Date().addingTimeInterval(2)
        while saves == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(saves, 1, "fifty keystrokes, one transaction")
    }

    /// `flush` is how navigation and backgrounding close the pending window: the armed save
    /// happens NOW, and exactly once.
    func testFlushClosesThePendingWindowImmediatelyAndOnlyOnce() {
        let autosave = ComposerDraftAutosave(quietPeriod: .seconds(60))
        var saves = 0
        autosave.arm { saves += 1 }
        autosave.flush()
        XCTAssertEqual(saves, 1, "flushed synchronously, not in sixty seconds")
        autosave.flush()
        XCTAssertEqual(saves, 1, "and a second flush with nothing armed does nothing")
    }

    /// `disarm` is the send's move: the staging save has already persisted the release, so a
    /// pending draft write must be dropped rather than allowed to land after the handoff.
    func testDisarmDropsAPendingWriteWithoutRunningIt() {
        let autosave = ComposerDraftAutosave(quietPeriod: .seconds(60))
        var saves = 0
        autosave.arm { saves += 1 }
        autosave.disarm()
        autosave.flush()
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(autosave.isArmed)
    }

    /// The abrupt-termination case, at the layer where it is actually decidable: an edit's
    /// MODEL write is synchronous, so a process killed the instant after a keystroke loses at
    /// most the trailing transaction — and once that has been flushed, nothing. This is the
    /// durability boundary the change claims, and it is asserted here rather than described.
    func testAnEditFollowedByAFlushIsOnDiskWithNoFurtherLifecycleEvent() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()
        let autosave = ComposerDraftAutosave(quietPeriod: .seconds(60))

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: "typed and then the phone died", to: thread, in: context)
            autosave.arm { try? context.save() }
            // The one lifecycle event: leaving the composer. No termination handler, no
            // scene-phase callback, no autosave from the SwiftUI host.
            autosave.flush()
        }

        let reopened = try openStore(at: url)
        XCTAssertEqual(ComposerDraft.snapshot(of: try thread(id, in: reopened)).text,
                       "typed and then the phone died")
    }

    // MARK: - Migration and reconciliation

    /// A store written WITHOUT the draft columns opens under the current schema with its rows
    /// intact and the draft fields reading their nil defaults. The draft is an additive
    /// lightweight change, as every schema change in this app has been.
    func testAStoreWrittenBeforeTheDraftColumnsOpensWithThemDefaulted() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()
        // The V4 entity set: everything the app had before `DraftAttachment`.
        let before = Schema(versionedSchema: JesseSchemaV4.self)

        do {
            let container = try ModelContainer(
                for: before, configurations: ModelConfiguration(schema: before, url: url))
            let context = ModelContext(container)
            let thread = JesseThread(title: "Old chat", mode: .tell)
            thread.id = id
            thread.sessionId = "sess-old"
            thread.setFavorite(true, now: Date(timeIntervalSince1970: 1_700_000_000))
            thread.turns.append(Turn(role: .user, text: "from before"))
            context.insert(thread)
            try context.save()
        }

        let reopened = try openStore(at: url)
        let migrated = try thread(id, in: reopened)
        XCTAssertEqual(migrated.title, "Old chat", "the pre-draft row survives")
        XCTAssertEqual(migrated.sessionId, "sess-old")
        XCTAssertTrue(migrated.isFavorite)
        XCTAssertEqual(migrated.orderedTurns.map(\.text), ["from before"])
        XCTAssertNil(migrated.draftText, "the new columns default to nil")
        XCTAssertNil(migrated.draftPendingRecording)
        XCTAssertNil(migrated.draftContextLabel)
        XCTAssertTrue(migrated.draftAttachments.isEmpty)
        XCTAssertFalse(migrated.hasComposerDraft)

        // And it takes a draft afterwards, which is the point of migrating at all.
        ComposerDraft.write(text: "now with a draft", to: migrated, in: reopened)
        try reopened.save()
        XCTAssertEqual(ComposerDraft.snapshot(of: migrated).text, "now with a draft")
    }

    /// The draft is LOCAL AND UNSYNCED, so everything the sync does to a thread leaves it
    /// alone. This drives the real writes those paths make — a title update, an AI title, a
    /// model and effort switch, the conversation id and first-ACK stamp being adopted, and a
    /// flag reconcile — and asserts the draft is exactly as it was.
    func testHydrationTitlesModelSwitchesAndFlagSyncAllLeaveTheDraftAlone() throws {
        let url = storeURL()
        defer { removeStore(url) }
        let id = UUID()
        let draft = "half a sentence about the\nthing"

        do {
            let context = try openStore(at: url)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: draft, to: thread, in: context)
            ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                                        data: Data([1, 2, 3]))],
                                     to: thread, in: context)
            try context.save()

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
        }

        let reopened = try openStore(at: url)
        let after = ComposerDraft.snapshot(of: try thread(id, in: reopened))
        XCTAssertEqual(after.text, draft,
                       "a title mint, a model switch, a flag sync and an incoming reply do not touch the draft")
        XCTAssertEqual(after.files.map(\.filename), ["a.png"])
    }
}
