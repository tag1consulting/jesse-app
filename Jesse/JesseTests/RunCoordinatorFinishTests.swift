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

        init(phase: ResultPhase) { self.phase = phase }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-finish")
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
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: SwitchableClient) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })
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

    // MARK: - helpers

    @MainActor
    private func fetch(_ id: UUID, _ context: ModelContext) -> JesseThread? {
        var d = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
