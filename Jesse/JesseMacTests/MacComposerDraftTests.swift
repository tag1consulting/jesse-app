import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// The macOS half of the composer-draft change.
///
/// The Mac had the same loss and one extra hazard: `MacThreadDetailView.send()` cleared
/// `draft` and THEN called an `async` coordinator whose staging save was a swallowed
/// `try?` — so a store error took the message with it silently. The coordinator's send is
/// split into a synchronous `stage` (guards, insert, a REAL save) and an async `deliver`,
/// and the composer calls `stageAndSend`, which returns whether the message is durably on
/// disk.
///
/// What changed with the draft moving out of the object graph: the release no longer rides
/// the staging save. It is ORDERED AFTER it and runs only on a true return, which is what
/// these tests assert. The Mac has no outbox, so the persisted user turn IS the durable
/// record; the handoff is measured against that.
@MainActor
final class MacComposerDraftTests: XCTestCase {

    private struct SaveRefused: Error {}

    private var directory: URL!
    private var drafts: ComposerDraftStore!
    private var previousShared: ComposerDraftStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-mac-draft-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        drafts = ComposerDraftStore(writer: ComposerDraftFileWriter(root: directory),
                                    quietPeriod: .seconds(60), observesAppLifecycle: false)
        previousShared = ComposerDraftStore.shared
        ComposerDraftStore.shared = drafts
    }

    override func tearDown() {
        ComposerDraftStore.shared = previousShared
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// `MacThreadDetailView.send()`'s handoff rule, in one place: stage, and release ONLY on
    /// a true return.
    @discardableResult
    private func composerSend(_ coord: MacCoordinator, text: String, mode: JesseMode = .ask,
                              thread: JesseThread, context: ModelContext) -> Bool {
        guard coord.stageAndSend(text: text, mode: mode, thread: thread, context: context) else {
            drafts.flush(thread.id)
            return false
        }
        drafts.release(for: thread.id)
        return true
    }

    private func coordinator(
        _ fake: MacFakeBridgeClient,
        config: MacConfigStore = MacTestFixtures.configured(),
        save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) -> MacCoordinator {
        MacCoordinator(configStore: config, makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore(),
                       save: save)
    }

    private func ackingClient() -> MacFakeBridgeClient {
        MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "ok", sessionId: "sess-\(UUID().uuidString)"),
                               jobId: nil, conversationId: nil))
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    // MARK: - Persistence on this platform

    /// The Mac's own reopen test: the draft is written through the shared
    /// `ComposerDraftStore`, so a relaunch of this app finds it exactly as the phone would.
    func testTheDraftSurvivesAReopenOnThisPlatform() async throws {
        let id = UUID()
        let exact = "an unsent reply\n\nwith a blank line and a — no, an em space\u{2003}kept"

        drafts.write(text: exact, for: id)
        drafts.flush(id)
        await settle()

        let relaunched = ComposerDraftStore(
            writer: ComposerDraftFileWriter(root: directory), observesAppLifecycle: false)
        XCTAssertEqual(relaunched.snapshot(for: id).text, exact)
    }

    /// And typing costs the Mac nothing either: the composer's own path leaves the model
    /// context clean.
    func testTypingDoesNotDirtyTheModelContextOnThisPlatform() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        XCTAssertFalse(context.hasChanges)

        var typed = ""
        for i in 0..<100 {
            typed.append(Character(UnicodeScalar(97 + (i % 26))!))
            drafts.write(text: typed, for: thread.id)
        }
        XCTAssertFalse(context.hasChanges, "a hundred keystrokes dirtied nothing")
        XCTAssertNil(thread.draftText)
    }

    // MARK: - The handoff

    /// `stageAndSend` persists the user turn and reports true — the only condition on which
    /// the composer may clear itself or release the draft. At the moment it returns, the
    /// turn is on disk and the draft is still whole: that ORDER is the guarantee.
    func testTheTurnIsOnDiskBeforeTheDraftIsReleased() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let coord = coordinator(ackingClient())
        drafts.write(text: "the message", for: thread.id)

        let staged = coord.stageAndSend(text: "the message", mode: .ask, thread: thread,
                                        context: context)

        XCTAssertTrue(staged, "durably staged")
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["the message"],
                       "the persisted user turn is the Mac's durable record of the message")
        XCTAssertFalse(context.hasChanges, "and it is SAVED")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "the message",
                       "the draft is still intact AT THIS INSTANT — the turn went first")
        XCTAssertTrue(coord.isRunning(thread.id),
                      "the run gate closed synchronously, so a second click cannot double-stage")

        drafts.release(for: thread.id)
        XCTAssertFalse(drafts.hasDraft(thread.id), "and only now is it given up")
    }

    /// The window between the two: a kill after the save and before the release leaves the
    /// turn and the draft both on disk, and a restore must recognise the draft as sent.
    func testAKillBetweenTheSaveAndTheReleaseDoesNotResurrectTheSentMessage() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let coord = coordinator(ackingClient())
        drafts.write(text: "the message", for: thread.id,
                     now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(coord.stageAndSend(text: "the message", mode: .ask, thread: thread,
                                         context: context))
        // …and the process dies here, before `release`.

        let orphan = drafts.snapshot(for: thread.id)
        let newest = try XCTUnwrap(thread.orderedTurns.last { $0.isUser })
        XCTAssertTrue(
            ComposerDraftStaleness.isSpent(orphan,
                                           newestUserTurn: (newest.visibleText, newest.createdAt)),
            "a restore discards it rather than putting the sent message back on screen")
    }

    /// A refused send costs nothing. Empty, whitespace-only and unconfigured all return
    /// false and leave the draft alone.
    func testARefusedSendLeavesTheDraftExactlyWhereItWas() throws {
        for (label, text, config) in [
            ("empty", "", MacTestFixtures.configured()),
            ("whitespace only", "  \n ", MacTestFixtures.configured()),
            ("not paired", "a real message", MacTestFixtures.unconfigured()),
        ] as [(String, String, MacConfigStore)] {
            let context = try MacTestFixtures.context()
            let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
            let fake = ackingClient()
            let coord = coordinator(fake, config: config)
            drafts.write(text: text.isEmpty ? "kept" : text, for: thread.id)
            let recorded = drafts.snapshot(for: thread.id).text

            XCTAssertFalse(composerSend(coord, text: text, thread: thread, context: context),
                           "\(label): refused")
            XCTAssertEqual(drafts.snapshot(for: thread.id).text, recorded,
                           "\(label): the draft is untouched")
            XCTAssertTrue(thread.orderedTurns.isEmpty, "\(label): and no turn was created")
            XCTAssertTrue(fake.sentTexts.isEmpty, "\(label): and nothing reached the bridge")
        }
    }

    /// The bug the `try?` hid: a staging save that fails must not clear the composer. With
    /// the release ordered after the save, the draft is simply never taken.
    func testAStagingSaveThatThrowsLeavesTheDraftAndSaysSo() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let fake = ackingClient()
        let coord = coordinator(fake, save: { _ in throw SaveRefused() })
        drafts.write(text: "please don't lose this", pendingRecording: "memo.m4a",
                     for: thread.id)

        XCTAssertFalse(composerSend(coord, text: "please don't lose this", thread: thread,
                                    context: context))
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "please don't lose this",
                       "the draft is still there")
        XCTAssertEqual(drafts.snapshot(for: thread.id).pendingRecording, "memo.m4a",
                       "with its marker")
        XCTAssertNotNil(coord.lastError, "and the store failure is surfaced, not swallowed")
        XCTAssertTrue(fake.sentTexts.isEmpty, "nothing was transmitted on an unsaved turn")
        XCTAssertFalse(coord.isRunning, "and the run gate never opened")
    }

    /// A failed staging save puts the SCREEN CONTEXT back, so a retry is the same message
    /// and not a bare question about a reading that is no longer attached.
    func testAStagingSaveThatThrowsPutsTheAttachedContextBack() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let coord = coordinator(ackingClient(), save: { _ in throw SaveRefused() })
        coord.attach(AttachedContext(body: "a page of numbers", title: "Lunch · Aug 22"),
                     to: thread.id)
        drafts.write(text: "why is this so high?", contextLabel: "Lunch · Aug 22",
                     for: thread.id)

        XCTAssertFalse(composerSend(coord, text: "why is this so high?", thread: thread,
                                    context: context))
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "why is this so high?",
                       "the draft is still there")
        XCTAssertEqual(coord.attachedContext(for: thread.id), "a page of numbers",
                       "and so is the reading it is about")
        XCTAssertEqual(coord.attachment(for: thread.id)?.title, "Lunch · Aug 22")
    }

    /// The reason staging is synchronous: the draft's fate is decided in the same
    /// main-actor turn as the click. Nothing about it waits on the network, so a delivery
    /// failure afterwards cannot come back for the composer's copy.
    func testADeliveryFailureAfterStagingDoesNotResurrectTheDraft() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let fake = MacFakeBridgeClient(sendError: JesseError.cannotConnect("offline"))
        let coord = coordinator(fake)
        drafts.write(text: "goes out later", for: thread.id)

        XCTAssertTrue(composerSend(coord, text: "goes out later", thread: thread,
                                   context: context))
        let deadline = Date().addingTimeInterval(4)
        while coord.lastError == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNotNil(coord.lastError, "the send failed")
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["goes out later"],
                       "the message is still in the transcript")
        XCTAssertFalse(drafts.hasDraft(thread.id),
                       "and there is exactly one copy of it, not a second in the composer")
    }

    /// Text typed while a turn is in flight belongs to the NEXT message, and the running
    /// turn's completion must not take it.
    func testTextTypedDuringATurnSurvivesThatTurnsCompletion() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let gate = AsyncGate()
        let fake = MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "answered", sessionId: "sess-\(UUID().uuidString)"),
                               jobId: nil, conversationId: nil),
            beforeSend: { await gate.wait() })
        let coord = coordinator(fake)

        XCTAssertTrue(composerSend(coord, text: "first message", thread: thread,
                                   context: context))
        XCTAssertFalse(drafts.hasDraft(thread.id), "the staged send took the draft with it")

        // The user starts the next message while the first is still being answered.
        drafts.write(text: "meanwhile, a newer thought", for: thread.id)

        await gate.open()
        let deadline = Date().addingTimeInterval(4)
        while coord.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(coord.isRunning, "precondition: the turn finished")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "meanwhile, a newer thought",
                       "an earlier send's completion never clears newer text")
    }

    /// A never-sent conversation on this platform too: typing brings it into the store, and
    /// the send stages onto that same row.
    func testADraftInsertsAStagedConversationAndTheSendUsesTheSameRow() throws {
        let context = try MacTestFixtures.context()
        let coord = coordinator(ackingClient())
        let staged = JesseThread(mode: .ask)
        XCTAssertNil(staged.modelContext)

        ComposerDraftThreadInsertion.persistIfNeeded(staged, in: context,
                                                     hasSomethingToKeep: true)
        drafts.write(text: "about this item", for: staged.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)

        XCTAssertTrue(composerSend(coord, text: "about this item", thread: staged,
                                   context: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "no second conversation")
        XCTAssertFalse(drafts.hasDraft(staged.id))
    }

    /// `MacRootView.pruneEmptyThreads`' predicate, mirroring `MacPruneEmptyTests`: a
    /// turn-less conversation holding a draft is spared, an abandoned ⌘N is not.
    func testTheEmptyThreadReaperSparesAConversationHoldingADraft() throws {
        let context = try MacTestFixtures.context()
        let coord = coordinator(ackingClient())

        let drafted = JesseThread(mode: .ask); context.insert(drafted)
        drafts.write(text: "unsent", for: drafted.id)
        let abandoned = JesseThread(mode: .ask); context.insert(abandoned)
        let emptied = JesseThread(mode: .ask); context.insert(emptied)
        drafts.write(text: "", for: emptied.id)
        try context.save()

        func reapable(_ t: JesseThread) -> Bool {
            t.turns.isEmpty && (t.sessionId ?? "").isEmpty && t.registeredAt == nil
                && !ComposerDraftStore.shared.hasDraft(t.id)
                && !(coord.isRunning && coord.activeThreadID == t.id)
        }

        XCTAssertFalse(reapable(drafted), "a conversation with an unsent draft is spared")
        XCTAssertTrue(reapable(abandoned), "an abandoned ⌘N is still reaped")
        XCTAssertTrue(reapable(emptied), "and so is one whose draft was deliberately emptied")
    }
}
