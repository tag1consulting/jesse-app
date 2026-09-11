import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// The iOS half of the composer-draft change: the OWNERSHIP TRANSFER at send, driven
/// through a real `RunCoordinator` and a real store.
///
/// `ComposerDraftTests` (JesseCore) proves the draft persists and that typing costs
/// nothing; this file proves the one moment the draft must stop existing, and every way
/// that moment can go wrong:
///
///   * a send that STAGES persists the turn FIRST and only then releases the draft,
///   * a send that is REFUSED leaves it exactly as it was,
///   * a staging save that THROWS leaves it exactly as it was — there is nothing to put
///     back, because nothing was taken,
///   * a network failure hands delivery to the outbox and never resurrects a second
///     sendable copy,
///   * a draft typed AFTER a send is in flight is not collected by that send's completion,
///   * and the window the two stores DO leave open — a kill after the save and before the
///     release — is closed on restore rather than papered over.
///
/// The draft no longer rides the staging save, so "atomic" is not claimed anywhere here.
/// What is claimed, and tested, is the ORDER.
@MainActor
final class ComposerDraftHandoffTests: XCTestCase {

    private var directory: URL!
    private var drafts: ComposerDraftStore!
    private var previousShared: ComposerDraftStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-handoff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        drafts = ComposerDraftStore(writer: ComposerDraftFileWriter(root: directory))
        previousShared = ComposerDraftStore.shared
        // The reapers and the delete paths reach for `shared` by name.
        ComposerDraftStore.shared = drafts
    }

    override func tearDown() {
        ComposerDraftStore.shared = previousShared
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// `ThreadDetailView.send`'s handoff rule, in one place so every test drives the real
    /// one: stage, and release ONLY on a true return.
    @discardableResult
    ///
    /// `recording` and `contextLabel` are the two situational markers the real view reads
    /// off its own state at the departure; they are passed here for the same reason, so a
    /// refused send captures the WHOLE composer and not just its text.
    private func composerSend(_ coordinator: RunCoordinator, thread: JesseThread,
                              text: String, context: ModelContext,
                              attachments: [JesseAttachment] = [],
                              recording: String? = nil,
                              contextLabel: String? = nil) -> Bool {
        guard coordinator.send(thread: thread, text: text, voice: false, context: context,
                               attachments: attachments) else {
            // A refused send is a departure: capture what is still on screen.
            capture(text, files: attachments, recording: recording,
                    contextLabel: contextLabel, for: thread, in: context)
            return false
        }
        ComposerDrafts.release(for: thread, store: drafts)
        return true
    }

    /// A DEPARTURE, spelled exactly as both composers spell it: build the capture from
    /// what is on screen and hand it to the one shared function. Every test below leaves a
    /// draft this way, because that is the only way the app leaves one.
    @discardableResult
    private func capture(_ text: String, files: [JesseAttachment] = [],
                         recording: String? = nil, contextLabel: String? = nil,
                         for thread: JesseThread, in context: ModelContext,
                         now: Date = Date()) -> Bool {
        ComposerDrafts.capture(
            ComposerDraftCapture(
                text: text,
                files: files.map {
                    ComposerDraftFile(filename: $0.filename, mime: $0.mime, data: $0.data)
                },
                pendingRecording: recording, contextLabel: contextLabel),
            for: thread, in: context, store: drafts, now: now)
    }

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

    // MARK: - A successful stage takes ownership, in that order

    /// The handoff: after `send` returns true the message is an `OutboxItem`, and the
    /// composer then drops the draft. The ORDER is the guarantee — the turn is on disk
    /// before anything is given up — and it is asserted here by observing the store at the
    /// moment `send` returns, before the release runs.
    func testTheTurnIsOnDiskBeforeTheDraftIsReleased() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        let attachments = [JesseAttachment(filename: "a.png", mime: "image/png",
                                           data: Data([1, 2, 3]))]
        capture("the message", files: attachments, for: thread, in: context)
        let staged = coordinator.send(thread: thread, text: "the message", voice: false,
                                      context: context, attachments: attachments)

        XCTAssertTrue(staged, "the message was durably staged")
        XCTAssertEqual(outbox(context).count, 1, "the outbox owns the message now")
        XCTAssertEqual(outbox(context).first?.orderedAttachments.map(\.filename), ["a.png"],
                       "including its bytes")
        XCTAssertFalse(context.hasChanges, "and it is SAVED, not merely staged in memory")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "the message",
                       "the draft is still intact AT THIS INSTANT — the turn went first")

        // Only now, on the true return, does the composer give it up.
        ComposerDrafts.release(for: thread, store: drafts)
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "")
        XCTAssertFalse(drafts.hasDraft(thread.id))

        coordinator.cancel(thread.id)
    }

    /// The window the two stores leave open, and the rule that closes it: a kill after the
    /// staging save and before the release leaves the turn on disk AND the draft file
    /// beside it. On restore the draft is recognised as already sent and discarded, rather
    /// than handed back as an unsent message the user would send twice.
    func testAKillBetweenTheSaveAndTheReleaseDoesNotResurrectTheSentMessage() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        capture("the message", for: thread, in: context,
                now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(coordinator.send(thread: thread, text: "the message", voice: false,
                                       context: context))
        // …and the process dies here, before `release`.

        let orphan = drafts.snapshot(for: thread.id)
        XCTAssertEqual(orphan.text, "the message", "precondition: the draft outlived the send")
        let newest = try XCTUnwrap(thread.orderedTurns.last { $0.isUser })
        XCTAssertTrue(
            ComposerDraftStaleness.isSpent(orphan,
                                           newestUserTurn: (newest.visibleText, newest.createdAt)),
            "a restore discards it rather than putting the sent message back on screen")

        coordinator.cancel(thread.id)
    }

    /// A send on a conversation that never had a draft (an opening starter is written and
    /// sent in one turn, before any edit is recorded) stages perfectly well.
    func testASendWithNoRecordedDraftStillStages() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        XCTAssertTrue(composerSend(coordinator, thread: thread, text: "an opening starter",
                                   context: context))
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
        capture("   ", for: thread, in: context)

        XCTAssertFalse(composerSend(coordinator, thread: thread, text: "   ", context: context),
                       "whitespace only is refused")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "   ",
                       "and the draft is exactly as it was")
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

        XCTAssertTrue(composerSend(coordinator, thread: thread, text: "first", context: context))
        XCTAssertTrue(coordinator.isRunning(thread.id), "precondition: a turn is in flight")

        // The user keeps typing while it runs — that text is a draft, not a send.
        capture("and another thought", for: thread, in: context)

        XCTAssertFalse(composerSend(coordinator, thread: thread, text: "and another thought",
                                    context: context),
                       "the in-flight turn holds the gate shut")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "and another thought",
                       "the refused send did not spend the draft")
        XCTAssertEqual(outbox(context).count, 1, "and created no second message")

        coordinator.cancel(thread.id)
    }

    // MARK: - A staging save that fails preserves the draft

    /// The store refuses the write. Nothing is on disk — and because the release is ORDERED
    /// AFTER the save, nothing was taken, so there is nothing to put back. The draft is
    /// simply still there, files and markers included, and `send` reports false so the
    /// composer keeps its text.
    func testAStagingSaveThatThrowsLeavesTheDraftUntouched() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake, save: { _ in throw SaveRefused() })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        capture("please don't lose this",
                files: [JesseAttachment(filename: "a.png", mime: "image/png",
                                        data: Data([7, 7, 7]))],
                recording: "memo.m4a", contextLabel: "Lunch · Aug 22",
                for: thread, in: context)

        let staged = composerSend(coordinator, thread: thread, text: "please don't lose this",
                                  context: context,
                                  attachments: [JesseAttachment(filename: "a.png",
                                                                mime: "image/png",
                                                                data: Data([7, 7, 7]))],
                                  recording: "memo.m4a", contextLabel: "Lunch · Aug 22")

        XCTAssertFalse(staged, "a staging save that throws is not a durable stage")
        let after = drafts.snapshot(for: thread.id)
        XCTAssertEqual(after.text, "please don't lose this", "the draft is still there")
        XCTAssertEqual(after.pendingRecording, "memo.m4a", "with its markers")
        XCTAssertEqual(after.contextLabel, "Lunch · Aug 22")
        XCTAssertEqual(after.files.map(\.filename), ["a.png"], "and its staged files")
        XCTAssertEqual(after.files.first?.data, Data([7, 7, 7]))
        XCTAssertNotNil(coordinator.error(for: thread.id),
                        "and the failure is surfaced, not swallowed")
        XCTAssertEqual(fake.sendCallCount, 0, "nothing was transmitted")
    }

    /// A failed staging save must put the SCREEN CONTEXT back. The attachment is spent
    /// early (so a send refused mid-turn leaves it for the send that does go through), and
    /// leaving it spent after a save failure would mean the preserved draft, sent again,
    /// went without the reading the conversation was opened about.
    func testAStagingSaveThatThrowsPutsTheAttachedContextBack() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake, save: { _ in throw SaveRefused() })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        coordinator.attach(AttachedContext(body: "a page of numbers", title: "Lunch · Aug 22"),
                           to: thread.id)
        capture("why is this so high?", contextLabel: "Lunch · Aug 22",
                for: thread, in: context)

        XCTAssertFalse(composerSend(coordinator, thread: thread, text: "why is this so high?",
                                    context: context, contextLabel: "Lunch · Aug 22"))
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "why is this so high?",
                       "the draft is still there")
        XCTAssertEqual(coordinator.attachedContext(for: thread.id), "a page of numbers",
                       "and so is the reading it is about, so a retry is the SAME message")
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
        capture("goes out later", for: thread, in: context)

        XCTAssertTrue(composerSend(coordinator, thread: thread, text: "goes out later",
                                   context: context))
        await waitUntil("the pre-ACK failure to mark the item failed") {
            self.outbox(context).first?.state == .failed
        }

        XCTAssertEqual(outbox(context).count, 1, "exactly one sendable copy")
        XCTAssertFalse(drafts.hasDraft(thread.id),
                       "the composer's copy is not resurrected by a failure")
        XCTAssertEqual(thread.turns.filter(\.isUser).count, 1, "and one user bubble, not two")

        // The retry the outbox owns: same message, still one copy, still no draft.
        let item = try XCTUnwrap(outbox(context).first)
        coordinator.retry(itemID: item.id, context: context)
        await waitUntil("the retry to ACK") { self.outbox(context).isEmpty }
        XCTAssertFalse(drafts.hasDraft(thread.id))
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

        XCTAssertTrue(composerSend(coordinator, thread: thread, text: "first message",
                                   context: context))
        XCTAssertFalse(drafts.hasDraft(thread.id), "the staged send took the draft with it")

        // The user starts the NEXT message while the first is still being answered.
        capture("meanwhile, a newer thought", for: thread, in: context)

        await waitUntil("the first turn to finish") { !coordinator.isRunning(thread.id) }
        XCTAssertTrue(thread.orderedTurns.contains { !$0.isUser }, "precondition: the reply landed")
        XCTAssertEqual(drafts.snapshot(for: thread.id).text, "meanwhile, a newer thought",
                       "an earlier send's completion never clears newer text")
    }

    // MARK: - A never-sent conversation

    /// The staged-thread path: a conversation that is not in the store until its first
    /// send. Typing inserts it, and the send then stages onto that same row rather than a
    /// second one.
    func testADraftInsertsAStagedThreadAndTheSendStagesOntoTheSameRow() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let staged = JesseThread(mode: .ask)   // as AskOpener / TodayTurn stage one
        XCTAssertNil(staged.modelContext)
        // The capture is what inserts it — that is the whole of the insertion rule now.
        capture("about this reading", for: staged, in: context)
        XCTAssertNotNil(staged.modelContext, "the departure put it on disk")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)

        XCTAssertTrue(composerSend(coordinator, thread: staged, text: "about this reading",
                                   context: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1,
                       "the send did not insert a second conversation")
        XCTAssertFalse(drafts.hasDraft(staged.id))
        coordinator.cancel(staged.id)
    }

    // MARK: - The reaper

    /// `ThreadListView.pruneEmpty`'s predicate, over the real store it now reads. A
    /// turn-less conversation holding a draft must survive it, or the change destroys the
    /// very thing it exists to protect.
    func testTheEmptyThreadReaperSparesAConversationHoldingADraft() throws {
        let context = try makeContext()
        let fake = DraftFakeClient([.hold])
        let coordinator = makeCoordinator(fake)

        let drafted = JesseThread(mode: .ask); context.insert(drafted)
        capture("unsent", for: drafted, in: context)
        let abandoned = JesseThread(mode: .ask); context.insert(abandoned)
        let emptied = JesseThread(mode: .ask); context.insert(emptied)
        capture("half a thought", for: emptied, in: context)
        capture("", for: emptied, in: context)
        try context.save()

        // The predicate from `ThreadListView.pruneEmpty`, over the same store.
        func reapable(_ t: JesseThread) -> Bool {
            t.turns.isEmpty && t.sessionId == nil
                && !ComposerDraftStore.shared.hasDraft(t.id)
                && !coordinator.isRunning(t.id)
        }

        XCTAssertFalse(reapable(drafted), "a conversation with an unsent draft is spared")
        XCTAssertTrue(reapable(abandoned), "a bare +-then-back is still reaped")
        XCTAssertTrue(reapable(emptied), "and so is one whose draft was deliberately emptied")
    }
}
