import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// The iOS half of the composer-draft fix: the OWNERSHIP TRANSFER at send, driven through a
/// real `RunCoordinator` and a real store.
///
/// `ComposerDraftTests` (JesseCore) proves the draft persists; this file proves the one
/// moment the draft must stop existing, and every way that moment can go wrong:
///
///   * a send that STAGES drops the draft in the same save as the outbox item,
///   * a send that is REFUSED leaves it exactly as it was,
///   * a staging save that THROWS puts it back,
///   * a network failure hands delivery to the outbox and never resurrects a second
///     sendable copy,
///   * and a draft typed AFTER a send is in flight is not collected by that send's
///     completion.
///
/// Fails-before-fix: `RunCoordinator.send` returned `Void` and the composer cleared its
/// text BEFORE calling it, so `testARefusedSendLeavesTheDraftExactlyWhereItWas` and
/// `testAStagingSaveThatThrowsPutsTheDraftBack` describe behavior the old code could not
/// have — there was no draft to preserve and no return value to preserve it on.
@MainActor
final class ComposerDraftHandoffTests: XCTestCase {

    /// A client scripted per call. `.hold` never returns, which is how a test observes the
    /// state DURING a turn.
    @MainActor
    private final class DraftFakeClient: JesseClientProtocol {
        enum Behavior {
            case failPreACK(JesseError)
            case running(String)
            case reply(JesseReply)
            case hold
        }
        var behaviors: [Behavior]
        private(set) var sendCallCount = 0
        private(set) var sentTexts: [String] = []

        init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?, effort: String?) async throws -> JesseSendResult {
            sendCallCount += 1
            sentTexts.append(text)
            switch behaviors[min(sendCallCount - 1, behaviors.count - 1)] {
            case .failPreACK(let error): throw error
            case .running(let jobId): return .running(jobId: jobId, conversationId: nil)
            case .reply(let reply): return .reply(reply, jobId: nil, conversationId: nil)
            case .hold:
                try await Task.sleep(for: .seconds(600))
                throw CancellationError()
            }
        }

        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private final class MemoryInFlightStore: InFlightStoring {
        var map: [UUID: InFlightJob] = [:]
        func load() -> [UUID: InFlightJob] { map }
        func save(_ map: [UUID: InFlightJob]) { self.map = map }
    }

    private struct SaveRefused: Error {}

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            DraftAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeCoordinator(
        _ fake: DraftFakeClient,
        save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) -> RunCoordinator {
        RunCoordinator(config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
                       makeClient: { _ in fake },
                       save: save,
                       inFlightStore: MemoryInFlightStore())
    }

    private func outbox(_ context: ModelContext) -> [OutboxItem] {
        (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - A successful stage takes ownership, atomically

    /// The handoff: after `send` returns true the message is an `OutboxItem` and the draft
    /// is gone — and both facts were written by ONE save, so there is no instant in which a
    /// kill would leave the message in neither place or in both.
    func testAStagedSendDropsTheDraftInTheSameSaveAsTheOutboxItem() async throws {
        let context = try makeContext()
        var saveCount = 0
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake, save: { saveCount += 1; try $0.save() })

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        ComposerDraft.write(text: "the message", to: thread, in: context)
        ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                                    data: Data([1, 2, 3]))],
                                 to: thread, in: context)
        try context.save()
        let savesBefore = saveCount

        let attachments = [JesseAttachment(filename: "a.png", mime: "image/png", data: Data([1, 2, 3]))]
        let staged = coordinator.send(thread: thread, text: "the message", voice: false,
                                      context: context, attachments: attachments)

        XCTAssertTrue(staged, "the message was durably staged")
        XCTAssertEqual(saveCount - savesBefore, 1,
                       "ONE save carried the outbox item and the draft release together")
        XCTAssertEqual(outbox(context).count, 1, "the outbox owns the message now")
        XCTAssertEqual(outbox(context).first?.orderedAttachments.map(\.filename), ["a.png"],
                       "including its bytes")
        XCTAssertNil(thread.draftText, "and the draft has stopped being an owner")
        XCTAssertFalse(thread.hasComposerDraft)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DraftAttachment>()).count, 0,
                       "the draft's file rows are gone, not duplicated alongside the outbox's")

        coordinator.cancel(thread.id)
    }

    /// A send on a conversation that never had a draft (an opening starter is written and
    /// sent in one turn, before any edit is recorded) stages perfectly well. `release` is
    /// unconditional and does not need the draft to match the text being sent.
    func testASendWithNoRecordedDraftStillStages() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        XCTAssertTrue(coordinator.send(thread: thread, text: "an opening starter",
                                       voice: false, context: context))
        XCTAssertEqual(outbox(context).first?.text, "an opening starter")
        coordinator.cancel(thread.id)
    }

    // MARK: - A refused send preserves the draft

    /// An empty composer is refused, and refusal must cost nothing: the draft is untouched,
    /// no turn is created, and the caller is told so it can keep the text on screen.
    func testARefusedSendLeavesTheDraftExactlyWhereItWas() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        ComposerDraft.write(text: "   ", to: thread, in: context)
        try context.save()

        XCTAssertFalse(coordinator.send(thread: thread, text: "   ", voice: false, context: context),
                       "whitespace only is refused")
        XCTAssertEqual(thread.draftText, "   ", "and the draft is exactly as it was")
        XCTAssertTrue(thread.turns.isEmpty)
        XCTAssertTrue(outbox(context).isEmpty)
    }

    /// A second send while a turn is running is refused too — and the draft the user was
    /// mid-way through typing is still there afterwards.
    func testASendRefusedBecauseATurnIsRunningPreservesTheDraft() async throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        XCTAssertTrue(coordinator.send(thread: thread, text: "first", voice: false, context: context))
        XCTAssertTrue(coordinator.isRunning(thread.id), "precondition: a turn is in flight")

        // The user keeps typing while it runs — that text is a draft, not a send.
        ComposerDraft.write(text: "and another thought", to: thread, in: context)
        try context.save()

        XCTAssertFalse(coordinator.send(thread: thread, text: "and another thought",
                                        voice: false, context: context),
                       "the in-flight turn holds the gate shut")
        XCTAssertEqual(thread.draftText, "and another thought",
                       "the refused send did not spend the draft")
        XCTAssertEqual(outbox(context).count, 1, "and created no second message")

        coordinator.cancel(thread.id)
    }

    // MARK: - A staging save that fails preserves the draft

    /// The store refuses the write. Nothing is on disk, so the draft was never really
    /// spent — it comes back whole, files included, and `send` reports false so the
    /// composer keeps its text.
    func testAStagingSaveThatThrowsPutsTheDraftBack() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake, save: { _ in throw SaveRefused() })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        ComposerDraft.write(text: "please don't lose this", pendingRecording: "memo.m4a",
                            contextLabel: "Lunch · Aug 22", to: thread, in: context)
        ComposerDraft.writeFiles([ComposerDraftFile(filename: "a.png", mime: "image/png",
                                                    data: Data([7, 7, 7]))],
                                 to: thread, in: context)
        try context.save()

        let staged = coordinator.send(thread: thread, text: "please don't lose this",
                                      voice: false, context: context)

        XCTAssertFalse(staged, "a staging save that throws is not a durable stage")
        XCTAssertEqual(thread.draftText, "please don't lose this", "the draft came back")
        XCTAssertEqual(thread.draftPendingRecording, "memo.m4a", "with its markers")
        XCTAssertEqual(thread.draftContextLabel, "Lunch · Aug 22")
        XCTAssertEqual(ComposerDraft.snapshot(of: thread).files.map(\.filename), ["a.png"],
                       "and its staged files")
        XCTAssertEqual(ComposerDraft.snapshot(of: thread).files.first?.data, Data([7, 7, 7]))
        XCTAssertNotNil(coordinator.error(for: thread.id), "and the failure is surfaced, not swallowed")
        XCTAssertEqual(fake.sendCallCount, 0, "nothing was transmitted")
    }

    /// A failed staging save must put the SCREEN CONTEXT back as well as the draft. The
    /// attachment is spent early (so a send refused mid-turn leaves it for the send that
    /// does go through), and leaving it spent after a save failure would mean the preserved
    /// draft, sent again, went without the reading the conversation was opened about.
    func testAStagingSaveThatThrowsPutsTheAttachedContextBackToo() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake, save: { _ in throw SaveRefused() })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        coordinator.attach(AttachedContext(body: "a page of numbers", title: "Lunch · Aug 22"),
                           to: thread.id)
        ComposerDraft.write(text: "why is this so high?", contextLabel: "Lunch · Aug 22",
                            to: thread, in: context)

        XCTAssertFalse(coordinator.send(thread: thread, text: "why is this so high?",
                                        voice: false, context: context))
        XCTAssertEqual(thread.draftText, "why is this so high?", "the draft came back")
        XCTAssertEqual(coordinator.attachedContext(for: thread.id), "a page of numbers",
                       "and so did the reading it is about, so a retry is the SAME message")
        XCTAssertEqual(coordinator.attachment(for: thread.id)?.title, "Lunch · Aug 22")
    }

    // MARK: - Retry without duplication

    /// A pre-ACK network failure hands the message to the outbox's own Retry. The draft
    /// stays gone, so the composer cannot offer a second copy of the same message — one
    /// sendable copy, in the outbox, whatever the network does.
    func testANetworkFailureLeavesOneSendableCopyInTheOutboxAndNoDraft() async throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.failPreACK(.cannotConnect("offline")), .running("job-1")])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        ComposerDraft.write(text: "goes out later", to: thread, in: context)
        try context.save()

        XCTAssertTrue(coordinator.send(thread: thread, text: "goes out later",
                                       voice: false, context: context))
        await waitUntil("the pre-ACK failure to mark the item failed") {
            self.outbox(context).first?.state == .failed
        }

        XCTAssertEqual(outbox(context).count, 1, "exactly one sendable copy")
        XCTAssertNil(thread.draftText, "the composer's copy is not resurrected by a failure")
        XCTAssertFalse(thread.hasComposerDraft)
        XCTAssertEqual(thread.turns.filter(\.isUser).count, 1, "and one user bubble, not two")

        // The retry the outbox owns: same message, still one copy, still no draft.
        let item = try XCTUnwrap(outbox(context).first)
        coordinator.retry(itemID: item.id, context: context)
        await waitUntil("the retry to ACK") { self.outbox(context).isEmpty }
        XCTAssertNil(thread.draftText)
        XCTAssertEqual(thread.turns.filter(\.isUser).count, 1,
                       "the retry reuses the same user turn — never a second message")
        coordinator.cancel(thread.id)
    }

    // MARK: - A newer draft survives an older send

    /// The composer is cleared at STAGE time, synchronously, and never by a completion. So
    /// text typed while a turn is in flight is still there when that turn finishes — the
    /// classic "my next message vanished when the last reply landed" bug cannot occur,
    /// because nothing in the completion path touches the draft.
    func testTextTypedDuringATurnSurvivesThatTurnsCompletion() async throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.reply(JesseReply(text: "answered", sessionId: "sess-1"))])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        XCTAssertTrue(coordinator.send(thread: thread, text: "first message",
                                       voice: false, context: context))
        XCTAssertNil(thread.draftText, "the staged send took the draft with it")

        // The user starts the NEXT message while the first is still being answered.
        ComposerDraft.write(text: "meanwhile, a newer thought", to: thread, in: context)
        try context.save()

        await waitUntil("the first turn to finish") { !coordinator.isRunning(thread.id) }
        XCTAssertTrue(thread.orderedTurns.contains { !$0.isUser }, "precondition: the reply landed")
        XCTAssertEqual(thread.draftText, "meanwhile, a newer thought",
                       "an earlier send's completion never clears newer text")
    }

    // MARK: - A never-sent conversation

    /// The staged-thread path: a conversation that is not in the store until its first send.
    /// A draft inserts it, and the send then stages onto that same row rather than a second
    /// one.
    func testADraftInsertsAStagedThreadAndTheSendStagesOntoTheSameRow() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let staged = JesseThread(mode: .ask)   // as AskOpener / TodayTurn stage one
        XCTAssertNil(staged.modelContext)
        ComposerDraft.write(text: "about this reading", to: staged, in: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)

        XCTAssertTrue(coordinator.send(thread: staged, text: "about this reading",
                                       voice: false, context: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "the send did not insert a second conversation")
        XCTAssertNil(staged.draftText)
        coordinator.cancel(staged.id)
    }

    // MARK: - The reaper

    /// `ThreadListView.pruneEmpty`'s predicate, over the real fields it reads. A turn-less
    /// conversation holding a draft must survive it, or the fix destroys the very thing it
    /// exists to protect.
    func testTheEmptyThreadReaperSparesAConversationHoldingADraft() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let drafted = JesseThread(mode: .ask); context.insert(drafted)
        ComposerDraft.write(text: "unsent", to: drafted, in: context)
        let abandoned = JesseThread(mode: .ask); context.insert(abandoned)
        let emptied = JesseThread(mode: .ask); context.insert(emptied)
        ComposerDraft.write(text: "", to: emptied, in: context)
        try context.save()

        // The predicate from `ThreadListView.pruneEmpty`, over the same properties.
        func reapable(_ t: JesseThread) -> Bool {
            t.turns.isEmpty && t.sessionId == nil && !t.hasComposerDraft
                && !coordinator.isRunning(t.id)
        }

        XCTAssertFalse(reapable(drafted), "a conversation with an unsent draft is spared")
        XCTAssertTrue(reapable(abandoned), "a bare +-then-back is still reaped")
        XCTAssertTrue(reapable(emptied), "and so is one whose draft was deliberately emptied")
    }
}
