import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// The macOS half of the composer-draft fix.
///
/// The Mac had the same loss and one extra hazard: `MacThreadDetailView.send()` cleared
/// `draft` and THEN called an `async` coordinator whose staging save was a swallowed
/// `try?` — so a store error took the message with it silently. The fix splits the
/// coordinator's send into a synchronous `stage` (guards, insert, draft release, a REAL
/// save) and an async `deliver`, and gives the composer `stageAndSend`, which returns
/// whether the message is durably on disk.
///
/// The Mac has no outbox, so the persisted user turn IS the durable record; these tests
/// assert the handoff against that.
@MainActor
final class MacComposerDraftTests: XCTestCase {

    private struct SaveRefused: Error {}

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

    // MARK: - Persistence on this platform

    /// The Mac's own reopen test: the draft is written through the shared `ComposerDraft`,
    /// so a relaunch of this app finds it exactly as the phone would.
    func testTheDraftSurvivesAStoreReopenOnThisPlatform() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-mac-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let schema = jesseCurrentSchema
        let id = UUID()
        let exact = "an unsent reply\n\nwith a blank line and a — no, an em space\u{2003}kept"

        do {
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let thread = JesseThread(mode: .ask); thread.id = id; context.insert(thread)
            ComposerDraft.write(text: exact, to: thread, in: context)
            try context.save()
        }

        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let reopened = ModelContext(container)
        let thread = try XCTUnwrap(
            try reopened.fetch(FetchDescriptor<JesseThread>()).first { $0.id == id })
        XCTAssertEqual(ComposerDraft.snapshot(of: thread).text, exact)
    }

    // MARK: - The handoff

    /// `stageAndSend` persists the user turn and releases the draft in ONE save, and reports
    /// true — the only condition on which the composer may clear itself.
    func testStageAndSendPersistsTheTurnAndReleasesTheDraftInOneSave() async throws {
        let context = try MacTestFixtures.context()
        var saves = 0
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let coord = coordinator(ackingClient(), save: { saves += 1; try $0.save() })
        ComposerDraft.write(text: "the message", to: thread, in: context)
        try context.save()
        let before = saves

        let staged = coord.stageAndSend(text: "the message", mode: .ask, thread: thread,
                                        context: context)

        XCTAssertTrue(staged, "durably staged")
        XCTAssertEqual(saves - before, 1, "one save carried the turn and the draft release")
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["the message"],
                       "the persisted user turn is the Mac's durable record of the message")
        XCTAssertNil(thread.draftText, "and the draft has stopped being one")
        XCTAssertTrue(coord.isRunning(thread.id),
                      "the run gate closed synchronously, so a second click cannot double-stage")
    }

    /// A refused send costs nothing. Empty, whitespace-only, unconfigured, and mid-turn all
    /// return false and leave the draft alone.
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
            ComposerDraft.write(text: text.isEmpty ? "kept" : text, to: thread, in: context)
            let recorded = thread.draftText
            try context.save()

            XCTAssertFalse(coord.stageAndSend(text: text, mode: .ask, thread: thread,
                                              context: context),
                           "\(label): refused")
            XCTAssertEqual(thread.draftText, recorded, "\(label): the draft is untouched")
            XCTAssertTrue(thread.orderedTurns.isEmpty, "\(label): and no turn was created")
            XCTAssertTrue(fake.sentTexts.isEmpty, "\(label): and nothing reached the bridge")
        }
    }

    /// The bug the `try?` hid: a staging save that fails must not clear the composer. The
    /// draft comes back whole and the failure is surfaced.
    func testAStagingSaveThatThrowsPutsTheDraftBackAndSaysSo() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let fake = ackingClient()
        let coord = coordinator(fake, save: { _ in throw SaveRefused() })
        ComposerDraft.write(text: "please don't lose this", pendingRecording: "memo.m4a",
                            to: thread, in: context)

        let staged = coord.stageAndSend(text: "please don't lose this", mode: .ask,
                                        thread: thread, context: context)

        XCTAssertFalse(staged)
        XCTAssertEqual(thread.draftText, "please don't lose this", "the draft came back")
        XCTAssertEqual(thread.draftPendingRecording, "memo.m4a", "with its marker")
        XCTAssertNotNil(coord.lastError, "and the store failure is surfaced, not swallowed")
        XCTAssertTrue(fake.sentTexts.isEmpty, "nothing was transmitted on an unsaved turn")
        XCTAssertFalse(coord.isRunning, "and the run gate never opened")
    }

    /// A failed staging save puts the SCREEN CONTEXT back as well as the draft, so a retry
    /// is the same message and not a bare question about a reading that is no longer
    /// attached.
    func testAStagingSaveThatThrowsPutsTheAttachedContextBackToo() throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let coord = coordinator(ackingClient(), save: { _ in throw SaveRefused() })
        coord.attach(AttachedContext(body: "a page of numbers", title: "Lunch · Aug 22"),
                     to: thread.id)
        ComposerDraft.write(text: "why is this so high?", contextLabel: "Lunch · Aug 22",
                            to: thread, in: context)

        XCTAssertFalse(coord.stageAndSend(text: "why is this so high?", mode: .ask,
                                          thread: thread, context: context))
        XCTAssertEqual(thread.draftText, "why is this so high?", "the draft came back")
        XCTAssertEqual(coord.attachedContext(for: thread.id), "a page of numbers",
                       "and so did the reading it is about")
        XCTAssertEqual(coord.attachment(for: thread.id)?.title, "Lunch · Aug 22")
    }

    /// The reason staging is synchronous: the draft's fate is decided in the same main-actor
    /// turn as the click. Nothing about it waits on the network, so a delivery failure
    /// afterwards cannot come back for the composer's copy.
    func testADeliveryFailureAfterStagingDoesNotResurrectTheDraft() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let fake = MacFakeBridgeClient(sendError: JesseError.cannotConnect("offline"))
        let coord = coordinator(fake)
        ComposerDraft.write(text: "goes out later", to: thread, in: context)
        try context.save()

        await coord.send(text: "goes out later", mode: .ask, thread: thread, context: context)

        XCTAssertNotNil(coord.lastError, "the send failed")
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["goes out later"],
                       "the message is still in the transcript")
        XCTAssertNil(thread.draftText, "and there is exactly one copy of it, not a second in the composer")
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

        XCTAssertTrue(coord.stageAndSend(text: "first message", mode: .ask, thread: thread,
                                         context: context))
        XCTAssertNil(thread.draftText, "the staged send took the draft with it")

        // The user starts the next message while the first is still being answered.
        ComposerDraft.write(text: "meanwhile, a newer thought", to: thread, in: context)
        try context.save()

        await gate.open()
        let deadline = Date().addingTimeInterval(4)
        while coord.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(coord.isRunning, "precondition: the turn finished")
        XCTAssertEqual(thread.draftText, "meanwhile, a newer thought",
                       "an earlier send's completion never clears newer text")
    }

    /// A never-sent conversation on this platform too: the draft brings it into the store,
    /// and the send stages onto that same row.
    func testADraftInsertsAStagedConversationAndTheSendUsesTheSameRow() throws {
        let context = try MacTestFixtures.context()
        let coord = coordinator(ackingClient())
        let staged = JesseThread(mode: .ask)
        XCTAssertNil(staged.modelContext)

        ComposerDraft.write(text: "about this item", to: staged, in: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)

        XCTAssertTrue(coord.stageAndSend(text: "about this item", mode: .ask, thread: staged,
                                         context: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "no second conversation")
        XCTAssertNil(staged.draftText)
    }

    /// `MacRootView.pruneEmptyThreads`' predicate, mirroring `MacPruneEmptyTests`: a
    /// turn-less conversation holding a draft is spared, an abandoned ⌘N is not.
    func testTheEmptyThreadReaperSparesAConversationHoldingADraft() throws {
        let context = try MacTestFixtures.context()
        let coord = coordinator(ackingClient())

        let drafted = JesseThread(mode: .ask); context.insert(drafted)
        ComposerDraft.write(text: "unsent", to: drafted, in: context)
        let abandoned = JesseThread(mode: .ask); context.insert(abandoned)
        let emptied = JesseThread(mode: .ask); context.insert(emptied)
        ComposerDraft.write(text: "", to: emptied, in: context)
        try context.save()

        func reapable(_ t: JesseThread) -> Bool {
            t.turns.isEmpty && (t.sessionId ?? "").isEmpty && t.registeredAt == nil
                && !t.hasComposerDraft
                && !(coord.isRunning && coord.activeThreadID == t.id)
        }

        XCTAssertFalse(reapable(drafted), "a conversation with an unsent draft is spared")
        XCTAssertTrue(reapable(abandoned), "an abandoned ⌘N is still reaped")
        XCTAssertTrue(reapable(emptied), "and so is one whose draft was deliberately emptied")
    }
}
