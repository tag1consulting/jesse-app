import XCTest
import SwiftData
@testable import Jesse

final class RunCoordinatorCancelTests: XCTestCase {

    /// Drives the coordinator's poll loop without a server: `send` reports the
    /// turn outran the grace window (202 → `.running`), and `result` parks on a
    /// continuation the test resolves by hand — so the run can be held in the
    /// poll phase, cancelled, and then handed a late `.done`.
    @MainActor
    private final class FakeClient: JesseClientProtocol {
        var onResultCalled: (() -> Void)?
        private var continuation: CheckedContinuation<JesseResultState, Error>?

        /// Job ids passed to `cancelJob`, in call order, plus an optional hook so
        /// a test can await the detached best-effort cancel.
        var cancelledJobIds: [String] = []
        var onCancelJob: ((String) -> Void)?

        func send(mode: JesseMode, text: String,
                  sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-test")
        }

        func result(jobId: String) async throws -> JesseResultState {
            try await withCheckedThrowingContinuation { c in
                continuation = c
                onResultCalled?()
            }
        }

        func cancelJob(jobId: String) async throws {
            cancelledJobIds.append(jobId)
            onCancelJob?(jobId)
        }

        // No live stream in these cancel tests — finish immediately so `consume`
        // falls straight through to the poll loop the tests drive by hand.
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        /// Resolve the parked `result` call with a completed reply.
        func resolveDone(_ text: String) {
            continuation?.resume(returning: .done(JesseReply(text: text, sessionId: nil)))
            continuation = nil
        }
    }

    @MainActor
    func testCancelDuringPollClearsRunAndIgnoresLateDone() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let fake = FakeClient()
        let entered = expectation(description: "poll reached client.result")
        fake.onResultCalled = { entered.fulfill() }

        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a long-running question", voice: false, context: context)

        // The 202 lands, the job is persisted, and poll parks in `result`.
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(coordinator.isRunning(thread.id))
        XCTAssertNotNil(coordinator.inFlight[thread.id])
        XCTAssertEqual(thread.turns.count, 1) // just the optimistic user turn

        // Cancel mid-poll: the thread must be idle immediately.
        coordinator.cancel(thread.id)
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.inFlight[thread.id])
        XCTAssertNil(coordinator.startDate(for: thread.id))

        // A `.done` that resolves *after* the cancel must be dropped on the floor.
        fake.resolveDone("reply that should never appear")
        // Let the parked poll continuation resume and take its cancelled exit.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(thread.turns.count, 1, "no Jesse turn may be appended for a cancelled run")
        XCTAssertNil(coordinator.error(for: thread.id), "a user cancel must not surface an error")

        // A cancelled thread has no persisted job, so resume has nothing to re-attach.
        coordinator.resume(context: context)
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(thread.turns.count, 1)
    }

    /// Cancelling a thread with an in-flight job must fire the bridge's
    /// server-side cancel for *that* job id (best-effort, detached) so the
    /// `claude` turn actually stops — on top of the instant local teardown.
    @MainActor
    func testCancelInvokesBridgeCancelWithInFlightJobId() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let fake = FakeClient()
        let entered = expectation(description: "poll reached client.result")
        fake.onResultCalled = { entered.fulfill() }
        let cancelled = expectation(description: "bridge cancel fired")
        fake.onCancelJob = { _ in cancelled.fulfill() }

        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a long-running question", voice: false, context: context)

        // The 202 lands and poll parks; the job id is now in flight.
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(coordinator.inFlight[thread.id]?.jobId, "job-test")

        coordinator.cancel(thread.id)
        // Local teardown is synchronous and instant.
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.inFlight[thread.id])

        // The detached best-effort cancel reaches the bridge with the right id.
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(fake.cancelledJobIds, ["job-test"])
    }

    /// A thread with no in-flight job (nothing was ever sent) must NOT call the
    /// bridge cancel — there's no server-side turn to stop.
    @MainActor
    func testCancelWithoutInFlightJobDoesNotCallBridge() async throws {
        let fake = FakeClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        coordinator.cancel(UUID())
        // Give any (erroneously) spawned detached task a chance to run.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fake.cancelledJobIds.isEmpty)
    }
}
