import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// The classify-then-attach retry machinery in `RunCoordinator`: a reply that is a
/// JESSE_NEEDS_HEALTH directive triggers ONE fulfillment retry (same text, same
/// thread), the sentinel turn is never persisted, and a second directive on the
/// retry's reply is ignored. Driven through `JesseClientProtocol` — no server.
@MainActor
final class HealthRetryTests: XCTestCase {

    /// A fake that answers the sentinel job with a needs-health directive and the
    /// retry (via `sendFulfilling`) with a real answer. Records the fulfillment.
    @MainActor
    private final class DirectiveClient: JesseClientProtocol {
        var sentinelDirectives: JesseDirectives
        var answerText: String
        var answerDirectives: JesseDirectives?
        private(set) var sendCalls = 0
        private(set) var fulfillCalls: [(request: NeedsHealthRequest, sessionId: String?)] = []

        init(sentinel: JesseDirectives, answer: String, answerDirectives: JesseDirectives? = nil) {
            self.sentinelDirectives = sentinel
            self.answerText = answer
            self.answerDirectives = answerDirectives
        }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCalls += 1
            return .running(jobId: "job-sentinel")
        }

        func sendFulfilling(_ request: NeedsHealthRequest, mode: JesseMode, text: String,
                            sessionId: String?, voice: Bool, instructions: String?,
                            floorOverride: String?) async throws -> JesseSendResult {
            fulfillCalls.append((request, sessionId))
            return .running(jobId: "job-answer")
        }

        func result(jobId: String) async throws -> JesseResultState {
            if jobId == "job-sentinel" {
                // The sentinel reply is empty by construction (bridge stripped the
                // directive line) and carries the needs-health directive.
                return .done(JesseReply(text: "", sessionId: "s1", directives: sentinelDirectives))
            }
            return .done(JesseReply(text: answerText, sessionId: "s1", directives: answerDirectives))
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

    private let needsHealth = JesseDirectives(needsHealth: JesseNeedsHealth(
        sections: ["daily"],
        metrics: [JesseNeedsHealth.Metric(metric: "restingHeartRate", windowDays: 14)]))

    @MainActor
    func testNeedsHealthTriggersOneFulfilledRetryAndPersistsOnlyTheAnswer() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsHealth, answer: "You're doing fine.")
        let delivered = expectation(description: "the answer landed")
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            onFirstSuccess: { delivered.fulfill() })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "how am I doing?", voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        // Exactly one initial send + one fulfillment retry, carrying the validated
        // request on the SAME session.
        XCTAssertEqual(fake.sendCalls, 1)
        XCTAssertEqual(fake.fulfillCalls.count, 1, "exactly one retry per user message")
        XCTAssertEqual(fake.fulfillCalls.first?.sessionId, "s1", "retry continues the same thread")
        XCTAssertEqual(fake.fulfillCalls.first?.request.sections, [.daily])
        XCTAssertEqual(fake.fulfillCalls.first?.request.metrics,
                       [ValidatedMetricRequest(metric: .restingHeartRate, windowDays: 14)])

        // Only the user turn and the final answer persist — the empty sentinel turn
        // is never recorded.
        XCTAssertEqual(thread.turns.count, 2, "user + answer only; no empty sentinel turn")
        XCTAssertEqual(thread.orderedTurns.last?.text, "You're doing fine.")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    @MainActor
    func testSecondDirectiveOnTheRetryIsIgnored() async throws {
        let context = try makeContext()
        // The answer ALSO carries a directive — it must be ignored (one retry cap),
        // and its stripped text persisted as the answer.
        let fake = DirectiveClient(sentinel: needsHealth, answer: "Best guess from vault.",
                                   answerDirectives: needsHealth)
        let delivered = expectation(description: "the answer landed")
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            onFirstSuccess: { delivered.fulfill() })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "am I overtraining?", voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fake.fulfillCalls.count, 1, "a second directive must NOT trigger a second retry")
        XCTAssertEqual(thread.turns.count, 2)
        XCTAssertEqual(thread.orderedTurns.last?.text, "Best guess from vault.")
    }

    @MainActor
    func testAppCappedTruncatesOnCharBoundary() {
        let big = String(repeating: "🎉", count: RunCoordinator.maxPersistedAnswerBytes) // 4 bytes each
        let reply = JesseReply(text: big, sessionId: "s")
        let capped = RunCoordinator.appCapped(reply)
        XCTAssertLessThanOrEqual(capped.text.utf8.count, RunCoordinator.maxPersistedAnswerBytes)
        XCTAssertTrue(capped.text.allSatisfy { $0 == "🎉" }, "never splits a multibyte char")
        // A short reply is returned unchanged.
        let small = JesseReply(text: "hi", sessionId: "s")
        XCTAssertEqual(RunCoordinator.appCapped(small).text, "hi")
    }
}
