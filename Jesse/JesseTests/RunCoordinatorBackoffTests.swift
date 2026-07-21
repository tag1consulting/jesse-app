import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// A main-actor holder that breaks the coordinator↔pollSleep construction cycle: a
/// `let` box the injected closure captures, whose `coordinator` is filled in once the
/// coordinator exists. Main-actor-isolated (hence `Sendable`) and only ever touched
/// on the main actor.
@MainActor private final class CoordinatorBox {
    weak var coordinator: RunCoordinator?
}

/// (H6) The poll loop must back off geometrically toward a ceiling instead of
/// hammering `GET /jesse/result` every 2s forever, and snap back to the fast
/// cadence when the live stream shows the turn is still producing tokens. Driven
/// through an injected sleep seam so the delays are observed without real waiting.
@MainActor
final class RunCoordinatorBackoffTests: XCTestCase {

    /// A client whose `result` returns `.running` for the first `runningCount`
    /// polls, then `.done` — so the poll loop sleeps exactly `runningCount` times.
    @MainActor
    private final class CountingClient: JesseClientProtocol {
        let runningCount: Int
        private(set) var resultCalls = 0
        init(runningCount: Int) { self.runningCount = runningCount }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-backoff")
        }
        func result(jobId: String) async throws -> JesseResultState {
            resultCalls += 1
            return resultCalls <= runningCount ? .running
                                               : .done(JesseReply(text: "done", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // MARK: - The pure interval-growth function

    func testNextPollIntervalGrowsAndCaps() {
        let i0 = RunCoordinator.pollInterval
        let i1 = RunCoordinator.nextPollInterval(after: i0)
        let i2 = RunCoordinator.nextPollInterval(after: i1)
        let i3 = RunCoordinator.nextPollInterval(after: i2)
        XCTAssertEqual(i0, 2, accuracy: 0.0001)
        XCTAssertEqual(i1, 10, accuracy: 0.0001, "2 grows to 10")
        XCTAssertEqual(i2, 30, accuracy: 0.0001, "10 grows to 30 (capped at the ceiling)")
        XCTAssertEqual(i3, 30, accuracy: 0.0001, "stays at the ceiling")
        XCTAssertEqual(i2, RunCoordinator.pollIntervalCeiling, accuracy: 0.0001)
    }

    // MARK: - The loop delays grow and cap

    @MainActor
    func testPollDelaysGrowAndCap() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = ModelContext(container)

        var recorded: [TimeInterval] = []
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in CountingClient(runningCount: 0) },
            pollSleep: { interval in recorded.append(interval) })

        // Four `.running` polls → four sleeps, then `.done`.
        let client = CountingClient(runningCount: 4)
        let threadID = UUID()
        let outcome = await coordinator.pollForOutcome(threadID: threadID, jobId: "job-backoff",
                                                       client: client)
        guard case .done = outcome else { return XCTFail("expected .done") }
        XCTAssertEqual(recorded, [2, 10, 30, 30],
                       "idle polls back off geometrically and cap at the ceiling")
    }

    // MARK: - Reset to the fast cadence on stream activity

    @MainActor
    func testPollDelayResetsOnStreamActivity() async throws {
        var recorded: [TimeInterval] = []
        let threadID = UUID()
        // The pollSleep closure needs the coordinator that owns it — a construction
        // cycle. Hold it in a main-actor box assigned once after init, so the closure
        // captures a stable `let` reference rather than a `var` reassigned after
        // capture (which the Swift 6 sending check flags).
        let box = CoordinatorBox()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in CountingClient(runningCount: 0) },
            pollSleep: { interval in
                recorded.append(interval)
                // After the 2nd (already backed-off) sleep, simulate the live stream
                // delivering a delta — the next poll must snap back to the fast cadence.
                if recorded.count == 2 { box.coordinator?.noteStreamActivity(threadID) }
            })
        box.coordinator = coordinator

        let client = CountingClient(runningCount: 4)
        let outcome = await coordinator.pollForOutcome(threadID: threadID, jobId: "job-backoff",
                                                       client: client)
        guard case .done = outcome else { return XCTFail("expected .done") }
        XCTAssertEqual(recorded, [2, 10, 2, 10],
                       "stream activity resets the backoff to the fast cadence")
    }
}
