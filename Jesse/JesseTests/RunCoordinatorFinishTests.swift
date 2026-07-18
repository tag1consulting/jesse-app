import XCTest
import SwiftData
@testable import Jesse

/// The completion→render path: `finish` must always leave the app in exactly one
/// of {reply shown, recoverable error + Re-check shown}. "Spinner stops, nothing
/// shown, no error" — the silent-drop bug — must be unreachable. These tests drive
/// a real `RunCoordinator` + a real in-memory SwiftData store through the
/// `JesseClientProtocol` seam (`.running` → poll `.done`), which the suite never
/// had an end-to-end render guard for.
final class RunCoordinatorFinishTests: XCTestCase {

    /// A fake that outruns the grace window (so the coordinator persists a job and
    /// enters the poll loop) and whose `result` outcome is switchable between
    /// phases, so a test can hold a recoverable-error state and then change what
    /// the next fetch returns before invoking Re-check. No live stream — it
    /// finishes immediately so `consume` is driven by the poll, which is the
    /// authoritative completion path these tests exercise.
    @MainActor
    private final class SwitchableClient: JesseClientProtocol {
        enum ResultPhase {
            case failRecoverable      // a transient client error (retain + Re-check)
            case done(JesseReply)     // the reply is ready
        }
        var phase: ResultPhase
        var onResult: (() -> Void)?
        var sendCount = 0

        init(phase: ResultPhase) { self.phase = phase }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCount += 1
            return .running(jobId: "job-finish")
        }

        func result(jobId: String) async throws -> JesseResultState {
            onResult?()
            switch phase {
            case .failRecoverable: throw JesseError.timedOut("laptop")
            case .done(let reply): return .done(reply)
            }
        }

        func cancelJob(jobId: String) async throws {}

        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// Records what was spoken so a test can assert the spoken line (and that the
    /// genuinely-empty path speaks nothing through the `finish` seam).
    @MainActor
    private final class SpeakSpy {
        var spoken: [String] = []
        func speak(_ s: String) { spoken.append(s) }
    }

    /// A save seam whose Nth call(s) can be forced to throw (then succeed after),
    /// to drive the save-failure paths deterministically. The seam is now used by
    /// BOTH the optimistic user-turn save (call 1 of a send) and `finish` (a later
    /// call), so tests target specific 1-based call indices rather than "the first".
    @MainActor
    private final class SaveSpy {
        struct ForcedFailure: Error {}
        var calls = 0
        var failOn: Set<Int> = []
        func save(_ context: ModelContext) throws {
            calls += 1
            if failOn.contains(calls) { throw ForcedFailure() }
            try context.save()
        }
    }

    @MainActor
    private func makeCoordinator(_ fake: SwitchableClient,
                                 speak: SpeakSpy? = nil,
                                 save: SaveSpy? = nil) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            speak: { s in if let speak { speak.speak(s) } },
            save: { ctx in if let save { try save.save(ctx) } else { try ctx.save() } })
    }

    @MainActor
    private func jesseTurns(_ thread: JesseThread) -> [Turn] {
        thread.turns.filter { !$0.isUser }
    }

    /// Poll `condition` on the main actor until true or a bounded timeout (so a
    /// regression fails rather than hangs).
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - The happy-path render guard

    /// The end-to-end render guard the suite never had: a turn driven to `.done`
    /// must append a `jesse` `Turn` (with the reply text) and set the thread's
    /// `sessionId`.
    ///
    /// To prove the fix — `finish` delivers against the live `thread` reference,
    /// not a by-id re-fetch — the thread lives in its own store while the
    /// coordinator's run context is a SEPARATE store, so a by-id fetch resolves to
    /// nothing. Pre-fix `finish` re-fetched by id, found nil, and silently cleared
    /// the run (spinner stops, no turn); post-fix it appends to the held reference.
    @MainActor
    func testCompletedTurnAppendsJesseTurnToThread() async throws {
        let threadStore = try makeContext()
        let runContext = try makeContext()   // a different in-memory store

        let thread = JesseThread(mode: .ask)
        threadStore.insert(thread)
        try threadStore.save()

        let fake = SwitchableClient(phase: .done(JesseReply(text: "the answer", sessionId: "sess-1")))
        let coordinator = makeCoordinator(fake)
        coordinator.send(thread: thread, text: "a question", voice: false, context: runContext)

        await waitUntil("the reply to render as a jesse turn") { !self.jesseTurns(thread).isEmpty }

        XCTAssertEqual(jesseTurns(thread).count, 1, "exactly one jesse turn for one completed turn")
        XCTAssertEqual(thread.orderedTurns.last?.text, "the answer")
        XCTAssertEqual(thread.orderedTurns.last?.roleValue, .jesse)
        XCTAssertEqual(thread.sessionId, "sess-1", "the reply's session id is carried into the thread")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
        XCTAssertNil(coordinator.inFlight[thread.id], "a delivered reply clears the retained job")
    }

    // MARK: - The optimistic user-turn save (M5: no silently-swallowed save)

    /// (M5) The optimistic user-turn `context.save()` in `send` was `try?` — a
    /// throw left the user message shown but unpersisted and let the turn proceed
    /// to attach a reply to a possibly-doomed thread. It must now surface the
    /// failure (recoverable, like `finish`) and NOT start the bridge turn.
    @MainActor
    func testOptimisticUserTurnSaveFailureSurfacesAndStopsTurn() async throws {
        let context = try makeContext()
        let fake = SwitchableClient(phase: .done(JesseReply(text: "unreached", sessionId: nil)))
        let save = SaveSpy()
        save.failOn = [1]   // the optimistic user-turn save is call 1 of the send
        let coordinator = makeCoordinator(fake, save: save)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        await waitUntil("the optimistic save failure to surface") {
            coordinator.error(for: thread.id) != nil
        }
        try await Task.sleep(for: .milliseconds(50)) // let any spawned task unwind

        XCTAssertNotNil(coordinator.error(for: thread.id),
                        "an optimistic-turn save failure must be surfaced, not swallowed")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.inFlight[thread.id], "no job — the turn never started")
        XCTAssertEqual(save.calls, 1, "only the optimistic save was attempted before aborting")
        XCTAssertEqual(fake.sendCount, 0,
                       "the bridge turn is not started after a failed optimistic save")
    }

    // MARK: - The unresolvable-thread guard (no silent drop)

    /// On the resume/recheck path there's no live reference, so `finish` re-fetches
    /// by id. When that fetch finds nothing, the reply must NOT be dropped: the job
    /// stays retained and a recoverable error + Re-check is surfaced, never a
    /// cleared run with no turn.
    @MainActor
    func testFinishWithUnresolvableThreadSurfacesRecheckNotSilentDrop() async throws {
        let context = try makeContext()
        let fake = SwitchableClient(phase: .failRecoverable)
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        // Drive to a recoverable error so the job_id is retained and the run is idle.
        await waitUntil("the turn to settle into idle-with-Re-check") {
            coordinator.canRecheck(thread.id) && !coordinator.isRunning(thread.id)
        }
        try await Task.sleep(for: .milliseconds(50)) // let the send task fully unwind
        XCTAssertNotNil(coordinator.inFlight[thread.id])

        // Make the thread unresolvable: delete it from the store so the recheck
        // path's by-id re-fetch returns nil — and make the reply ready.
        context.delete(thread)
        try context.save()
        let threadID = thread.id
        XCTAssertNil(fetch(threadID, context), "precondition: the thread no longer resolves by id")
        fake.phase = .done(JesseReply(text: "an answer with nowhere to land", sessionId: "sess-x"))

        coordinator.recheck(threadID, context: context)

        await waitUntil("the unresolvable reply to surface a recoverable state") {
            coordinator.error(for: threadID) != nil && !coordinator.isRunning(threadID)
        }

        // Recoverable, NOT a silent drop: error shown, job retained, Re-check on.
        XCTAssertNotNil(coordinator.error(for: threadID), "an unattachable reply surfaces an error")
        XCTAssertNotNil(coordinator.inFlight[threadID], "the job_id is retained — the reply isn't dropped")
        XCTAssertTrue(coordinator.canRecheck(threadID), "Re-check stays available")
        XCTAssertFalse(coordinator.isRunning(threadID))
    }

    // MARK: - The empty-reply guard (no blank turn)

    /// A reply whose `displayText` is empty must surface a recoverable state, not
    /// append a blank `jesse` turn and clear the run.
    @MainActor
    func testEmptyDisplayTextDoesNotAppendBlankTurn() async throws {
        let context = try makeContext()
        // Whitespace-only text → `displayText` trims to "".
        let fake = SwitchableClient(phase: .done(JesseReply(text: "   \n  ", sessionId: "sess-e")))
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        await waitUntil("the empty reply to settle") {
            coordinator.error(for: thread.id) != nil || !self.jesseTurns(thread).isEmpty
        }

        XCTAssertTrue(jesseTurns(thread).isEmpty, "no blank jesse turn for an empty reply")
        XCTAssertNotNil(coordinator.error(for: thread.id), "an empty reply surfaces a recoverable state")
        XCTAssertTrue(coordinator.canRecheck(thread.id), "the job is retained so Re-check can retry")
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    // MARK: - The spoken-only reply guard (spoken AND recorded, never dropped)

    /// A reply whose content lives ONLY in the `SPOKEN:` line (empty `displayText`,
    /// non-empty `spokenText`) is a real reply — not "empty." With voice on it must
    /// be recorded as a `jesse` turn (so the transcript/history aren't blank) AND
    /// spoken. Pre-fix `finish` saw the empty `displayText` and surfaced Re-check,
    /// leaving the voice turn both blank and silent.
    @MainActor
    func testVoiceOnlySpokenReplyIsSpokenAndRecorded() async throws {
        let context = try makeContext()
        let reply = JesseReply(text: "SPOKEN: the roof guy comes Thursday", sessionId: "sess-v")
        let fake = SwitchableClient(phase: .done(reply))
        let speak = SpeakSpy()
        let coordinator = makeCoordinator(fake, speak: speak)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: true, context: context)

        await waitUntil("the spoken-only reply to render as a jesse turn") {
            !self.jesseTurns(thread).isEmpty
        }

        XCTAssertEqual(jesseTurns(thread).count, 1, "exactly one jesse turn for a spoken-only reply")
        XCTAssertEqual(thread.orderedTurns.last?.text, "the roof guy comes Thursday",
                       "the spoken line is recorded as the turn's text — not lost as 'empty'")
        XCTAssertEqual(thread.orderedTurns.last?.roleValue, .jesse)
        XCTAssertEqual(thread.sessionId, "sess-v")
        XCTAssertEqual(speak.spoken, ["the roof guy comes Thursday"], "the reply is spoken aloud")
        XCTAssertNil(coordinator.error(for: thread.id), "a spoken-only reply is not an error")
        XCTAssertNil(coordinator.inFlight[thread.id], "a delivered reply clears the retained job")
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    /// Only when a reply is *genuinely* empty — both `displayText` and `spokenText`
    /// trim to "" — does `finish` keep the recoverable error + Re-check, and it
    /// speaks nothing through the `finish` seam.
    @MainActor
    func testGenuinelyEmptyReplyStillSurfacesRecheck() async throws {
        let context = try makeContext()
        // Whitespace only → both displayText and spokenText are empty.
        let fake = SwitchableClient(phase: .done(JesseReply(text: "   \n  ", sessionId: "sess-e")))
        let speak = SpeakSpy()
        let coordinator = makeCoordinator(fake, speak: speak)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: true, context: context)

        await waitUntil("the genuinely-empty reply to settle into Re-check") {
            coordinator.error(for: thread.id) != nil
        }

        XCTAssertTrue(jesseTurns(thread).isEmpty, "no turn for a genuinely empty reply")
        XCTAssertNotNil(coordinator.error(for: thread.id), "an empty reply surfaces a recoverable state")
        XCTAssertTrue(coordinator.canRecheck(thread.id), "the job is retained so Re-check can retry")
        XCTAssertEqual(speak.spoken, [], "a genuinely empty reply speaks nothing through the finish seam")
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    /// The same spoken-only reply with voice OFF still records the content as a
    /// turn (so it isn't lost) but speaks nothing.
    @MainActor
    func testNonVoiceSpokenOnlyReplyRecordsTurnButDoesNotSpeak() async throws {
        let context = try makeContext()
        let reply = JesseReply(text: "SPOKEN: noted for later", sessionId: "sess-n")
        let fake = SwitchableClient(phase: .done(reply))
        let speak = SpeakSpy()
        let coordinator = makeCoordinator(fake, speak: speak)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        await waitUntil("the spoken-only reply to render as a jesse turn") {
            !self.jesseTurns(thread).isEmpty
        }

        XCTAssertEqual(jesseTurns(thread).count, 1, "the spoken-only content is recorded, not lost")
        XCTAssertEqual(thread.orderedTurns.last?.text, "noted for later")
        XCTAssertEqual(speak.spoken, [], "voice off speaks nothing")
        XCTAssertNil(coordinator.error(for: thread.id))
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    // MARK: - Idempotent delivery (a re-entry of finish can't double-append)

    /// A save failure shows the reply (in-memory turn) and retains the job for
    /// Re-check. A subsequent Re-check that re-polls the SAME completed job must
    /// NOT append the reply a second time — it sees the idempotency key and only
    /// retries the (now-succeeding) save, then clears the run.
    @MainActor
    func testSaveFailureRetainsRecheckAndRecheckDoesNotDuplicate() async throws {
        let context = try makeContext()
        let reply = JesseReply(text: "the durable answer", sessionId: "sess-s")
        let fake = SwitchableClient(phase: .done(reply))
        let save = SaveSpy()
        // Optimistic user-turn save (call 1) succeeds; the `finish` save (call 2)
        // throws; the Re-check's retry save (call 3) succeeds.
        save.failOn = [2]
        let coordinator = makeCoordinator(fake, save: save)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        // First delivery: the save throws → reply shown in memory, error + Re-check,
        // job retained.
        await waitUntil("the save failure to surface Re-check") {
            coordinator.error(for: thread.id) != nil
        }
        try await Task.sleep(for: .milliseconds(50)) // let the send task fully unwind

        XCTAssertEqual(jesseTurns(thread).count, 1, "the reply is shown once despite the save failure")
        XCTAssertEqual(thread.orderedTurns.last?.text, "the durable answer")
        XCTAssertNotNil(coordinator.error(for: thread.id), "the save failure is surfaced, not swallowed")
        XCTAssertTrue(coordinator.canRecheck(thread.id), "the job is retained for Re-check")
        XCTAssertNotNil(coordinator.inFlight[thread.id])

        // Re-check: same completed job, save now succeeds. The idempotency key
        // (lastDeliveredJobId, set on the live object) makes finish retry the save
        // only — no second turn.
        coordinator.recheck(thread.id, context: context)

        await waitUntil("the Re-check to clear the run") {
            coordinator.inFlight[thread.id] == nil && coordinator.error(for: thread.id) == nil
        }

        XCTAssertEqual(jesseTurns(thread).count, 1, "Re-check does NOT duplicate the reply")
        XCTAssertNil(coordinator.error(for: thread.id), "the retried save succeeds and clears the error")
        XCTAssertNil(coordinator.inFlight[thread.id], "the run is cleared")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(thread.lastDeliveredJobId, "job-finish", "the delivered job is keyed on the thread")
    }

    /// The narrow idempotency guard via the public surface: once a job's reply is
    /// delivered, the run is cleared (no retained job), so a follow-up `recheck` is
    /// a no-op and can never append a second turn. (`finish` is private — callers
    /// can't re-enter it directly, only the send/consume/recheck paths can.)
    @MainActor
    func testRecheckAfterDeliveryDoesNotDuplicate() async throws {
        let context = try makeContext()
        let reply = JesseReply(text: "answered once", sessionId: "sess-i")
        let fake = SwitchableClient(phase: .done(reply))
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        await waitUntil("the reply to render") { !self.jesseTurns(thread).isEmpty }
        XCTAssertEqual(jesseTurns(thread).count, 1)
        XCTAssertEqual(thread.lastDeliveredJobId, "job-finish")
        XCTAssertNil(coordinator.inFlight[thread.id], "a delivered reply clears the retained job")

        // A re-check after delivery: no retained job → a no-op, no second turn.
        coordinator.recheck(thread.id, context: context)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(jesseTurns(thread).count, 1, "re-check after delivery appends no second turn")
    }

    // MARK: - helpers

    @MainActor
    private func fetch(_ id: UUID, _ context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
