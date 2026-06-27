import XCTest
import SwiftData
@testable import Jesse

/// Part 3: a turn that fails recoverably must RETAIN its bridge job_id and offer
/// a manual "Re-check" that re-attaches to the same job — delivering the reply if
/// it's now ready, or resuming the poll if it's still running. Driven entirely
/// through `JesseClientProtocol` so no server is needed.
final class RunCoordinatorRecheckTests: XCTestCase {

    /// A fake whose `result` outcome is switchable between phases, so a test can
    /// hold the run in a recoverable-error state and then change what the next
    /// fetch returns before invoking Re-check.
    @MainActor
    private final class ProgrammableClient: JesseClientProtocol {
        enum ResultPhase {
            case failRecoverable   // a transient client error (retain + Re-check)
            case running           // bridge says the turn is still going
            case done(String)      // the reply is ready
        }
        var phase: ResultPhase = .failRecoverable
        var onResult: (() -> Void)?

        func send(mode: JesseMode, text: String,
                  sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            // Always outruns the grace window so the coordinator persists a job
            // and enters the poll loop (where recoverable failures are retained).
            .running(jobId: "job-recheck")
        }

        func result(jobId: String) async throws -> JesseResultState {
            onResult?()
            switch phase {
            case .failRecoverable: throw JesseError.timedOut("laptop")
            case .running: return .running
            case .done(let text): return .done(JesseReply(text: text, sessionId: nil))
            }
        }

        func cancelJob(jobId: String) async throws {}

        // No live stream — finishes immediately so `consume` falls back to poll,
        // which is what these tests exercise.
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
    private func makeCoordinator(_ fake: ProgrammableClient) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })
    }

    /// error-shown → job retained → Re-check → ready result delivered.
    @MainActor
    func testRecheckDeliversReadyReplyAfterRecoverableError() async throws {
        let context = try makeContext()
        let fake = ProgrammableClient()
        fake.phase = .failRecoverable

        let firstFetch = expectation(description: "poll hit the recoverable error")
        fake.onResult = { firstFetch.fulfill() }

        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        await fulfillment(of: [firstFetch], timeout: 2)
        try await Task.sleep(for: .milliseconds(50)) // let failRecoverable run

        // The turn is idle-with-Re-check: not running, error shown, job retained.
        XCTAssertFalse(coordinator.isRunning(thread.id), "an errored turn is idle, not running")
        XCTAssertTrue(coordinator.canRecheck(thread.id), "the retained job_id must offer Re-check")
        XCTAssertNotNil(coordinator.inFlight[thread.id], "job_id retained through the error")
        XCTAssertNotNil(coordinator.error(for: thread.id))
        XCTAssertEqual(thread.turns.count, 1, "only the optimistic user turn so far")

        // The reply is now ready; Re-check must drop it into the thread.
        fake.phase = .done("here is the answer")
        let delivered = expectation(description: "re-check fetched the ready reply")
        fake.onResult = { delivered.fulfill() }
        coordinator.recheck(thread.id, context: context)
        await fulfillment(of: [delivered], timeout: 2)
        try await Task.sleep(for: .milliseconds(50)) // let finish() append the turn

        XCTAssertEqual(thread.turns.count, 2, "the ready reply dropped into the thread")
        XCTAssertEqual(thread.orderedTurns.last?.text, "here is the answer")
        XCTAssertNil(coordinator.error(for: thread.id), "a delivered reply clears the error")
        XCTAssertNil(coordinator.inFlight[thread.id], "a delivered reply clears the retained job")
        XCTAssertFalse(coordinator.canRecheck(thread.id))
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    /// error-shown → Re-check → still-running → poll resumes.
    @MainActor
    func testRecheckResumesPollWhenStillRunning() async throws {
        let context = try makeContext()
        let fake = ProgrammableClient()
        fake.phase = .failRecoverable

        let firstFetch = expectation(description: "poll hit the recoverable error")
        fake.onResult = { firstFetch.fulfill() }

        let coordinator = makeCoordinator(fake)
        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a long one", voice: false, context: context)

        await fulfillment(of: [firstFetch], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(coordinator.canRecheck(thread.id))
        XCTAssertNotNil(coordinator.inFlight[thread.id])

        // The bridge now reports still-running; Re-check must resume the poll.
        fake.phase = .running
        let resumed = expectation(description: "re-check resumed polling")
        resumed.assertForOverFulfill = false // the poll loops every 2s; the first fetch is enough
        fake.onResult = { resumed.fulfill() }
        coordinator.recheck(thread.id, context: context)
        await fulfillment(of: [resumed], timeout: 2)

        XCTAssertTrue(coordinator.isRunning(thread.id), "poll resumed → the thread is running again")
        XCTAssertNil(coordinator.error(for: thread.id), "Re-check cleared the stale error")
        XCTAssertNotNil(coordinator.inFlight[thread.id], "the job stays retained while polling")
        XCTAssertFalse(coordinator.canRecheck(thread.id), "no Re-check button while actively polling")

        coordinator.cancel(thread.id) // stop the 2s poll loop
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    /// A genuinely-gone (past-TTL) reply is the one terminal case: the 404/`.expired`
    /// clears the retained job and shows a final error — no lingering Re-check.
    /// A client whose job has already been evicted (the bridge 404s → `.expired`).
    @MainActor
    private final class ExpiringClient: JesseClientProtocol {
        var onResult: (() -> Void)?
        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-gone")
        }
        func result(jobId: String) async throws -> JesseResultState {
            onResult?()
            return .expired
        }

        func cancelJob(jobId: String) async throws {}

        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    func testExpiredResultIsTerminalAndDropsJob() async throws {
        let context = try makeContext()
        let expiring = ExpiringClient()
        let fetched = expectation(description: "poll fetched the expired job")
        expiring.onResult = { fetched.fulfill() }

        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in expiring })
        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "too late", voice: false, context: context)

        await fulfillment(of: [fetched], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(coordinator.error(for: thread.id), "the gone reply surfaces a terminal error")
        XCTAssertNil(coordinator.inFlight[thread.id], "an expired job is dropped, not retained")
        XCTAssertFalse(coordinator.canRecheck(thread.id), "nothing left to Re-check once expired")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(thread.turns.count, 1, "no Jesse turn for an expired reply")
    }
}
