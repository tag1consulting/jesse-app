import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// **The Mac could only run one turn, and said nothing about it.**
///
/// Three defects, one root: `MacCoordinator` kept ONE run slot for the whole app, the composer
/// gated Send on whether THIS conversation was running, and staging gated it on whether ANY
/// conversation was. So in every conversation but the busy one the button was live, Return
/// reached `send`, and staging returned nil having written nothing and said nothing — a message
/// that would not go, with no error and (if the busy conversation was scrolled out of the
/// sidebar) no spinner to explain it. And because the slot was cleared only when the stream
/// finished, a stream whose connection died without closing held it for the rest of the day:
/// every conversation on the Mac blocked until the app was relaunched.
///
/// These tests pin all three: concurrent sends, a reason on every refusal, and a silent stream
/// abandoned on a timer and resolved by the poll that already exists.
@MainActor
final class MacConcurrentRunTests: XCTestCase {

    // MARK: - Harness

    private func coordinator(_ fake: MacFakeBridgeClient,
                             config: MacConfigStore = MacTestFixtures.configured(),
                             stallWindow: TimeInterval = 60,
                             pollSpacing: TimeInterval = 1) -> MacCoordinator {
        MacCoordinator(configStore: config, makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore(),
                       streamStallWindow: stallWindow, pollSpacing: pollSpacing)
    }

    private func newThread(in context: ModelContext) throws -> JesseThread {
        let t = JesseThread(mode: .ask)
        context.insert(t)
        try context.save()
        return t
    }

    /// Let the main actor run until `condition` holds, then assert it.
    private func settles(_ label: String, within seconds: TimeInterval = 4,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), label)
    }

    /// A fake whose two conversations get two job ids, so their streams are driven apart.
    private struct TwoStreams {
        let a = AsyncThrowingStream<JesseStreamEvent, Error>.makeStream()
        let b = AsyncThrowingStream<JesseStreamEvent, Error>.makeStream()
    }

    private func fake(_ streams: TwoStreams, textInA: String) -> MacFakeBridgeClient {
        MacFakeBridgeClient(
            sendHandler: { text in
                .running(jobId: text == textInA ? "job-A" : "job-B", conversationId: nil)
            },
            streamHandler: { jobId in jobId == "job-A" ? streams.a.stream : streams.b.stream })
    }

    private func forgetCursors(_ threads: JesseThread...) {
        for t in threads where !(t.conversationId ?? "").isEmpty {
            MacCursorStore.clear(t.conversationId!)
        }
    }

    // MARK: - Two conversations at once

    /// THE REPORTED SYMPTOM. A turn is answering in one conversation; a message typed in
    /// another will not send, with nothing on screen to say why. It must send.
    func testASecondConversationSendsWhileTheFirstIsStillRunning() async throws {
        let context = try MacTestFixtures.context()
        let a = try newThread(in: context)
        let b = try newThread(in: context)
        defer { forgetCursors(a, b) }
        let streams = TwoStreams()
        let client = fake(streams, textInA: "in A")
        let coord = coordinator(client)

        XCTAssertTrue(coord.stageAndSend(text: "in A", mode: .ask, thread: a, context: context))
        await settles("A's turn is accepted and streaming") { coord.phase(a.id) == .accepted }

        // The defect, in one line: this used to return false, persist nothing, and set no error.
        XCTAssertTrue(coord.stageAndSend(text: "in B", mode: .ask, thread: b, context: context),
                      "a send in another conversation is durably staged while A is answering")
        XCTAssertEqual(b.orderedTurns.map(\.text), ["in B"], "B's user turn is on disk")
        await settles("B's text reached the bridge") { client.sentTexts.contains("in B") }
        XCTAssertTrue(coord.isRunning(a.id), "and both conversations are running")
        XCTAssertTrue(coord.isRunning(b.id))

        // Each conversation settles on its OWN terminal frame. The old single slot meant the
        // first turn to finish cleared the spinner and reopened the gate for every other.
        streams.a.continuation.yield(.done(JesseReply(text: "answered A", sessionId: nil)))
        streams.a.continuation.finish()
        await settles("A settled") { !coord.isRunning(a.id) }
        XCTAssertTrue(coord.isRunning(b.id), "B's turn is untouched by A finishing")

        streams.b.continuation.yield(.done(JesseReply(text: "answered B", sessionId: nil)))
        streams.b.continuation.finish()
        await settles("B settled") { !coord.isRunning(b.id) }

        XCTAssertEqual(a.orderedTurns.map(\.text), ["in A", "answered A"])
        XCTAssertEqual(b.orderedTurns.map(\.text), ["in B", "answered B"])
    }

    /// Two live turns, two live texts. One shared `streamingText` would have rendered whichever
    /// conversation spoke last into both transcripts.
    func testTheTwoConversationsLiveTextNeverMixes() async throws {
        let context = try MacTestFixtures.context()
        let a = try newThread(in: context)
        let b = try newThread(in: context)
        defer { forgetCursors(a, b) }
        let streams = TwoStreams()
        let client = fake(streams, textInA: "in A")
        let coord = coordinator(client)

        XCTAssertTrue(coord.stageAndSend(text: "in A", mode: .ask, thread: a, context: context))
        await settles("A is streaming") { coord.phase(a.id) == .accepted }
        XCTAssertTrue(coord.stageAndSend(text: "in B", mode: .ask, thread: b, context: context))
        await settles("B is streaming") { coord.phase(b.id) == .accepted }

        streams.a.continuation.yield(.delta("A's half"))
        streams.b.continuation.yield(.delta("B's half"))
        streams.b.continuation.yield(.activity(ToolActivity(name: "Read", refused: false)))
        await settles("both live texts arrived") {
            !coord.streamingText(for: a.id).isEmpty && !coord.streamingText(for: b.id).isEmpty
        }

        XCTAssertEqual(coord.streamingText(for: a.id), "A's half")
        XCTAssertEqual(coord.streamingText(for: b.id), "B's half")
        XCTAssertTrue(coord.activity(for: a.id).isEmpty,
                      "and an activity line belongs to the conversation that reported it")
        XCTAssertFalse(coord.activity(for: b.id).isEmpty)

        streams.a.continuation.finish()
        streams.b.continuation.finish()
        await settles("both settled") { !coord.isRunning(a.id) && !coord.isRunning(b.id) }
    }

    // MARK: - No refusal without a reason

    /// The refusal that REMAINS after the change — a second send in the conversation that is
    /// already answering — now says so. Silence was the whole bug; keeping the refusal and
    /// losing the silence is the fix.
    func testASecondSendInTheSameConversationIsRefusedOutLoud() async throws {
        let context = try MacTestFixtures.context()
        let a = try newThread(in: context)
        defer { forgetCursors(a) }
        let streams = TwoStreams()
        let client = fake(streams, textInA: "first")
        let coord = coordinator(client)

        XCTAssertTrue(coord.stageAndSend(text: "first", mode: .ask, thread: a, context: context))
        await settles("the first turn is in flight") { coord.phase(a.id) == .accepted }

        XCTAssertFalse(coord.stageAndSend(text: "second", mode: .ask, thread: a, context: context),
                       "the same conversation still takes one turn at a time")
        XCTAssertEqual(coord.error(for: a.id), MacSendGate.Refusal.alreadyRunning.message,
                       "and the refusal is on screen, not silent")
        XCTAssertEqual(a.orderedTurns.map(\.text), ["first"], "no second user turn")
        XCTAssertEqual(client.sentTexts, ["first"])

        streams.a.continuation.finish()
        await settles("settled") { !coord.isRunning(a.id) }
    }

    /// The other refusal that can reach an enabled-looking button: an unpaired Mac.
    func testAnUnpairedMacSaysSoRatherThanDoingNothing() throws {
        let context = try MacTestFixtures.context()
        let t = try newThread(in: context)
        let coord = coordinator(MacFakeBridgeClient(), config: MacTestFixtures.unconfigured())

        XCTAssertFalse(coord.stageAndSend(text: "hello", mode: .ask, thread: t, context: context))
        XCTAssertEqual(coord.error(for: t.id), MacSendGate.Refusal.notPaired.message)
        XCTAssertTrue(t.orderedTurns.isEmpty)
    }

    /// An empty composer is the ONE silent refusal, and stays silent: nothing was typed, so
    /// there is nothing to report and the button is already disabled.
    func testAnEmptyComposerIsRefusedWithoutAnError() throws {
        let context = try MacTestFixtures.context()
        let t = try newThread(in: context)
        let coord = coordinator(MacFakeBridgeClient())

        XCTAssertFalse(coord.stageAndSend(text: "   \n ", mode: .ask, thread: t, context: context))
        XCTAssertNil(coord.error(for: t.id), "nothing typed is not an error")
    }

    /// **The two gates are one function.** The composer's `canSend` and the coordinator's
    /// staging read `MacSendGate` for the same conversation, so they cannot disagree — the
    /// disagreement (live button, silent refusal) being exactly what shipped.
    func testTheComposerGateAgreesWithTheStagingGateInEveryState() async throws {
        /// `MacThreadDetailView.canSend`, spelled the way the view spells it.
        func composerEnablesSend(_ coord: MacCoordinator, _ t: JesseThread,
                                 typed: String) -> Bool {
            MacSendGate.refusal(typed: typed,
                                hasAttachment: coord.attachedContext(for: t.id) != nil,
                                isConfigured: coord.configStore.isConfigured,
                                isRunningInThisConversation: coord.isRunning(t.id)) == nil
        }

        /// Ask both gates about the SAME state, in that order, and report what they said.
        func bothGates(_ coord: MacCoordinator, _ t: JesseThread, typed: String,
                       _ context: ModelContext) -> (composer: Bool, staging: Bool) {
            let composer = composerEnablesSend(coord, t, typed: typed)
            let staging = coord.stageAndSend(text: typed, mode: .ask, thread: t,
                                             context: context)
            return (composer, staging)
        }

        // 1. Idle and paired: both say go.
        var context = try MacTestFixtures.context()
        var target = try newThread(in: context)
        defer { forgetCursors(target) }
        var streams = TwoStreams()
        var coord = coordinator(fake(streams, textInA: "other"))
        var said = bothGates(coord, target, typed: "go", context)
        XCTAssertEqual(said.composer, said.staging, "idle and paired: the gates agree")
        XCTAssertTrue(said.composer, "and they agree on GO")
        streams.b.continuation.finish()
        await settles("settled") { !coord.isRunning(target.id) }

        // 2. Nothing typed: both refuse, and silently.
        said = bothGates(coord, target, typed: "  ", context)
        XCTAssertEqual(said.composer, said.staging, "an empty composer: the gates agree")
        XCTAssertFalse(said.composer)

        // 3. THIS conversation is running: both refuse.
        context = try MacTestFixtures.context()
        target = try newThread(in: context)
        streams = TwoStreams()
        coord = coordinator(fake(streams, textInA: "busy"))
        XCTAssertTrue(coord.stageAndSend(text: "busy", mode: .ask, thread: target,
                                         context: context))
        await settles("running") { coord.isRunning(target.id) }
        said = bothGates(coord, target, typed: "again", context)
        XCTAssertEqual(said.composer, said.staging, "already answering: the gates agree")
        XCTAssertFalse(said.composer, "and they agree on NO")

        // 4. ANOTHER conversation is running — this is where the two used to part company:
        //    the composer said go, staging refused, and nothing was written or said.
        let other = try newThread(in: context)
        defer { forgetCursors(other) }
        said = bothGates(coord, other, typed: "meanwhile", context)
        XCTAssertEqual(said.composer, said.staging, "another conversation busy: the gates agree")
        XCTAssertTrue(said.composer, "and they agree on GO")
        streams.a.continuation.finish()
        streams.b.continuation.finish()
        await settles("both settled") {
            !coord.isRunning(target.id) && !coord.isRunning(other.id)
        }

        // 5. Unpaired: both refuse.
        context = try MacTestFixtures.context()
        target = try newThread(in: context)
        coord = coordinator(MacFakeBridgeClient(), config: MacTestFixtures.unconfigured())
        said = bothGates(coord, target, typed: "go", context)
        XCTAssertEqual(said.composer, said.staging, "unpaired: the gates agree")
        XCTAssertFalse(said.composer, "and they agree on NO")
    }

    // MARK: - A dead stream is abandoned

    /// **The reason it lasted for hours.** A stream whose connection dies without closing yields
    /// nothing and never finishes, and the stream session's ceiling is a DAY. The bridge comments
    /// every 15 seconds, so silence is evidence: after the stall window the read is abandoned,
    /// the job is resolved through the poll that already existed, and this conversation's gate
    /// opens.
    func testASilentStreamIsAbandonedAndTheTurnResolvedByPolling() async throws {
        let context = try MacTestFixtures.context()
        let t = try newThread(in: context)
        defer { forgetCursors(t) }
        let silent = AsyncThrowingStream<JesseStreamEvent, Error>.makeStream()
        let client = MacFakeBridgeClient(
            sendResult: .running(jobId: "job-silent", conversationId: nil),
            streamHandler: { _ in silent.stream },
            resultHandler: { _ in
                .done(JesseReply(text: "the bridge had it all along", sessionId: nil))
            })
        let coord = coordinator(client, stallWindow: 0.05)

        XCTAssertTrue(coord.stageAndSend(text: "a question", mode: .ask, thread: t,
                                         context: context))
        await settles("the turn is streaming") { coord.phase(t.id) == .accepted }
        // One frame arrives, and then the connection dies: no frames, no keep-alives, no close.
        silent.continuation.yield(.activity(ToolActivity(name: "Read", refused: false)))

        await settles("the stalled turn settled instead of hanging until tomorrow") {
            !coord.isRunning(t.id)
        }
        XCTAssertEqual(client.resultCalls, ["job-silent"],
                       "and it settled through the poll path, not by guessing")
        XCTAssertEqual(t.orderedTurns.map(\.text),
                       ["a question", "the bridge had it all along"],
                       "the reply the bridge actually produced is in the transcript")
        XCTAssertNil(coord.error(for: t.id),
                     "a stall the poll resolved is not something to put on screen")
    }

    /// A stall is only abandoned when the stream is TRULY silent. The bridge's keep-alive
    /// comments carry no frame at all, so a turn that is merely thinking must not be abandoned
    /// on their strength — which is why the client reports them as liveness.
    func testKeepAlivesHoldAQuietTurnOpen() async throws {
        let context = try MacTestFixtures.context()
        let t = try newThread(in: context)
        defer { forgetCursors(t) }
        let live = AsyncThrowingStream<JesseStreamItem, Error>.makeStream()
        let client = MacLivenessFakeClient(jobId: "job-quiet", items: live.stream)
        let liveCoord = MacCoordinator(configStore: MacTestFixtures.configured(),
                                       makeClient: { _ in client },
                                       sessionDeletionStore: MacTestFixtures.deletionStore(),
                                       streamStallWindow: 0.15)

        XCTAssertTrue(liveCoord.stageAndSend(text: "think about it", mode: .ask, thread: t,
                                             context: context))
        await settles("the turn is streaming") { liveCoord.phase(t.id) == .accepted }

        // Five keep-alives over more than two stall windows, and not one frame.
        for _ in 0..<5 {
            live.continuation.yield(.alive)
            try? await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertTrue(liveCoord.isRunning(t.id),
                      "a quiet but live stream is still a running turn")
        XCTAssertTrue(client.resultCalls.isEmpty, "and nothing fell back to the poll")

        live.continuation.yield(.event(.done(JesseReply(text: "here it is", sessionId: nil))))
        live.continuation.finish()
        await settles("settled on its own terminal frame") { !liveCoord.isRunning(t.id) }
        XCTAssertEqual(t.orderedTurns.map(\.text), ["think about it", "here it is"])
    }

    /// The poll's own silence, closed too: when its 600-attempt budget runs out it used to
    /// return having set nothing, so the spinner stopped with no turn appended and nothing on
    /// screen. The spacing is compressed here; the budget is the production one.
    func testAPollThatRunsOutOfPatienceSaysSo() async throws {
        let context = try MacTestFixtures.context()
        let t = try newThread(in: context)
        defer { forgetCursors(t) }
        let silent = AsyncThrowingStream<JesseStreamEvent, Error>.makeStream()
        let client = MacFakeBridgeClient(
            sendResult: .running(jobId: "job-forever", conversationId: nil),
            streamHandler: { _ in silent.stream },
            resultHandler: { _ in .running })
        let coord = coordinator(client, stallWindow: 0.02, pollSpacing: 0.0005)

        XCTAssertTrue(coord.stageAndSend(text: "a question", mode: .ask, thread: t,
                                         context: context))

        await settles("the poll gave up", within: 20) { !coord.isRunning(t.id) }
        XCTAssertEqual(client.resultCalls.count, 600, "the whole budget was spent")
        XCTAssertEqual(coord.error(for: t.id),
                       "Still waiting on the bridge. The reply will appear when this conversation next syncs.",
                       "and an expired wait is never silent either")
        XCTAssertEqual(t.orderedTurns.map(\.text), ["a question"])
    }
}

/// A fake that answers `streamItems` DIRECTLY — the only way to hand the coordinator a stream
/// that is alive but silent, because the shared fake goes through the protocol's default
/// `streamItems`, which can only report frames.
private final class MacLivenessFakeClient: BridgeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let jobId: String
    private let items: AsyncThrowingStream<JesseStreamItem, Error>
    private var _resultCalls: [String] = []

    var resultCalls: [String] { lock.withLock { _resultCalls } }

    init(jobId: String, items: AsyncThrowingStream<JesseStreamItem, Error>) {
        self.jobId = jobId
        self.items = items
    }

    nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }

    nonisolated func send(mode: JesseMode, text: String, sessionId: String?,
                          conversationId: String, voice: Bool, instructions: String?,
                          floorOverride: String?, attachments: [JesseRequest.Attachment],
                          requestId: String, model: String?,
                          effort: String?) async throws -> JesseSendResult {
        .running(jobId: jobId, conversationId: conversationId)
    }
    nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult {
        .running(jobId: jobId, conversationId: nil)
    }
    nonisolated func result(jobId: String) async throws -> JesseResultState {
        lock.withLock { _resultCalls.append(jobId) }
        return .cancelled
    }
    nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func streamItems(jobId: String) -> AsyncThrowingStream<JesseStreamItem, Error> {
        items
    }
    nonisolated func listConversations(since: UInt64?, etag: String?) async throws
        -> ConversationsResult { .notModified }
    nonisolated func hydrate(conversationId: String, after cursor: String?) async throws
        -> (turns: [HydratedTurn], nextCursor: String) { ([], cursor ?? "0:0") }
    nonisolated func title(text: String, conversationId: String?) async -> String? { nil }
    nonisolated func cancelJob(jobId: String) async throws {}
    nonisolated func deleteConversation(_ conversationId: String) async throws {}
    nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
    nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
        throw DietFetchError.notConfigured
    }
    nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
}
