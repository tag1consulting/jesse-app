import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// The location channel's half of `RunCoordinator`'s fulfilment loop: a reply that is
/// a JESSE_NEEDS_LOCATION directive triggers ONE fulfilment retry (same text, same
/// thread, same session), the sentinel turn is never persisted, a second directive on
/// the retry's reply is ignored, and a denied permission lands in the unavailable path
/// and still produces an answer. Driven through `JesseClientProtocol` — no server, no
/// CoreLocation.
///
/// The sibling of `HealthRetryTests`, plus the two cases that only exist once there are
/// two channels: the budgets must not starve each other, and each retry must land in
/// its OWN wire fields.
@MainActor
final class LocationRetryTests: XCTestCase {

    /// A fake that answers the sentinel job with whatever directive it was given and
    /// the retry (via `sendFulfilling`) with a real answer. Records every fulfilment.
    @MainActor
    private final class DirectiveClient: JesseClientProtocol {
        var sentinelDirectives: JesseDirectives
        var answerText: String
        var answerDirectives: JesseDirectives?
        /// A second sentinel: when set, the FIRST retry's job answers with this
        /// instead of prose, which is how the two-channel case is driven.
        var secondSentinel: JesseDirectives?
        private(set) var sendCalls = 0
        private(set) var fulfillCalls: [(request: DeviceContextRequest, sessionId: String?)] = []
        private var answerJobs = 0

        init(sentinel: JesseDirectives, answer: String,
             answerDirectives: JesseDirectives? = nil,
             secondSentinel: JesseDirectives? = nil) {
            self.sentinelDirectives = sentinel
            self.answerText = answer
            self.answerDirectives = answerDirectives
            self.secondSentinel = secondSentinel
        }

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            sendCalls += 1
            return .running(jobId: "job-sentinel", conversationId: nil)
        }

        func sendFulfilling(_ request: DeviceContextRequest, mode: JesseMode, text: String,
                            sessionId: String?, conversationId: String, voice: Bool,
                            instructions: String?, floorOverride: String?,
                            model: String?) async throws -> JesseSendResult {
            fulfillCalls.append((request, sessionId))
            answerJobs += 1
            return .running(jobId: "job-answer-\(answerJobs)", conversationId: nil)
        }

        func result(jobId: String) async throws -> JesseResultState {
            if jobId == "job-sentinel" {
                // The sentinel reply is empty by construction (the bridge stripped the
                // directive line) and carries the directive.
                return .done(JesseReply(text: "", sessionId: "s1", directives: sentinelDirectives))
            }
            if jobId == "job-answer-1", let second = secondSentinel {
                // A reply that carries a directive AND real prose. The prose matters:
                // a directive-only reply strips to empty, and an empty answer is never
                // persisted (the coordinator surfaces Re-check instead), so a test
                // using one would be asserting about the empty-reply path rather than
                // about the retry budget.
                return .done(JesseReply(text: answerText, sessionId: "s1", directives: second))
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

    private let needsLocation = JesseDirectives(
        needsHealth: nil,
        needsLocation: JesseNeedsLocation(fields: ["placemark", "accuracy"],
                                          precision: "coarse", maxAgeSeconds: 300))

    private let needsHealth = JesseDirectives(needsHealth: JesseNeedsHealth(
        sections: ["daily"], metrics: nil))

    private func coordinator(_ fake: DirectiveClient,
                             onDelivered: @escaping @MainActor () -> Void) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            onFirstSuccess: onDelivered)
    }

    // MARK: - One directive, one fulfilled retry

    func testNeedsLocationTriggersOneFulfilledRetryAndPersistsOnlyTheAnswer() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsLocation, answer: "There's a café on Fountainbridge.")
        let delivered = expectation(description: "the answer landed")
        let coordinator = coordinator(fake) { delivered.fulfill() }

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "anywhere for coffee near me?",
                         voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        // Exactly one initial send + one fulfilment retry, carrying the VALIDATED
        // request on the SAME session — a fresh session would start a second thread.
        XCTAssertEqual(fake.sendCalls, 1)
        XCTAssertEqual(fake.fulfillCalls.count, 1, "exactly one retry per user message")
        XCTAssertEqual(fake.fulfillCalls.first?.sessionId, "s1", "retry continues the same thread")
        guard case .location(let request)? = fake.fulfillCalls.first?.request else {
            return XCTFail("the retry must be dispatched on the LOCATION channel")
        }
        XCTAssertEqual(request.fields, [.placemark, .accuracy])
        XCTAssertEqual(request.precision, .coarse)
        XCTAssertEqual(request.maxAgeSeconds, 300)

        // Only the user turn and the final answer persist — the empty sentinel turn
        // is never recorded.
        XCTAssertEqual(thread.turns.count, 2, "user + answer only; no empty sentinel turn")
        XCTAssertEqual(thread.orderedTurns.last?.text, "There's a café on Fountainbridge.")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    /// ANTI-LOOP GUARD: the retry's own reply carries a directive too. It must be
    /// ignored and its stripped text persisted as the answer — otherwise a model that
    /// keeps asking turns one message into an unbounded exchange.
    func testASecondLocationDirectiveOnTheRetryIsIgnored() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsLocation,
                                   answer: "I don't know where you are, so: no idea.",
                                   answerDirectives: needsLocation)
        let delivered = expectation(description: "the answer landed")
        let coordinator = coordinator(fake) { delivered.fulfill() }

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "how far is the gym?", voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fake.fulfillCalls.count, 1,
                       "a second directive must NOT trigger a second retry")
        XCTAssertEqual(thread.turns.count, 2)
        XCTAssertEqual(thread.orderedTurns.last?.text, "I don't know where you are, so: no idea.")
    }

    // MARK: - The unavailable path

    /// A client whose fulfilment always fails — the shape a DENIED permission
    /// produces. It must still re-send (marked unavailable) so an answer lands.
    @MainActor
    private final class DenyingClient: JesseClientProtocol {
        private(set) var fulfillCalls = 0
        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            .running(jobId: "job-sentinel", conversationId: nil)
        }
        func sendFulfilling(_ request: DeviceContextRequest, mode: JesseMode, text: String,
                            sessionId: String?, conversationId: String, voice: Bool,
                            instructions: String?, floorOverride: String?,
                            model: String?) async throws -> JesseSendResult {
            // What the real client does when the channel cannot be fulfilled: it does
            // NOT throw and does NOT return early — it re-sends the turn marked
            // unavailable, and the bridge answers it.
            fulfillCalls += 1
            return .running(jobId: "job-answer", conversationId: nil)
        }
        func result(jobId: String) async throws -> JesseResultState {
            if jobId == "job-sentinel" {
                return .done(JesseReply(
                    text: "", sessionId: "s1",
                    directives: JesseDirectives(
                        needsHealth: nil,
                        needsLocation: JesseNeedsLocation(fields: ["placemark"],
                                                          precision: "coarse",
                                                          maxAgeSeconds: 300))))
            }
            return .done(JesseReply(text: "I can't tell where you are right now.",
                                    sessionId: "s1"))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A denied permission (and equally: Location Services off, a timed-out fix, a
    /// device with no fix, a simulator with no location set — they all reduce to the
    /// same empty reading) produces an ANSWER through the unavailable path. Never a
    /// hang, never a second directive.
    func testDeniedPermissionProducesAnAnswerThroughTheUnavailablePath() async throws {
        let context = try makeContext()
        let fake = DenyingClient()
        let delivered = expectation(description: "an answer landed anyway")
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            onFirstSuccess: { delivered.fulfill() })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what's near me?", voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fake.fulfillCalls, 1, "it re-sent rather than giving up")
        XCTAssertEqual(thread.turns.count, 2, "user + answer; the sentinel is not persisted")
        XCTAssertEqual(thread.orderedTurns.last?.text, "I can't tell where you are right now.")
        XCTAssertFalse(coordinator.isRunning(thread.id), "the run is not left spinning")
        XCTAssertNil(coordinator.error(for: thread.id), "and it is not an error, it is an answer")
    }

    /// `fulfillDeviceContext` is the one place the unavailable terminator lives, for
    /// every channel. A channel that is switched off, and one that gathers nothing,
    /// both land on `.unavailable` — never on the "no block, no flag" shape, which is
    /// an ordinary turn and would put the agent back on the request instruction.
    func testFulfilPolicyAlwaysTerminatesRatherThanReturningAnOrdinaryTurn() async {
        struct OffChannel: DeviceContextFulfilling {
            func mayFulfill() async -> Bool { false }
            func block(for request: NeedsLocationRequest) async -> String? { "unreachable" }
        }
        struct EmptyChannel: DeviceContextFulfilling {
            func mayFulfill() async -> Bool { true }
            func block(for request: NeedsLocationRequest) async -> String? { nil }
        }
        struct BlankChannel: DeviceContextFulfilling {
            func mayFulfill() async -> Bool { true }
            func block(for request: NeedsLocationRequest) async -> String? { "" }
        }
        struct GoodChannel: DeviceContextFulfilling {
            func mayFulfill() async -> Bool { true }
            func block(for request: NeedsLocationRequest) async -> String? { "Near: Edinburgh" }
        }
        let request = NeedsLocationRequest(fields: [.placemark], precision: .coarse,
                                           maxAgeSeconds: 300)
        for (channelName, outcome) in [
            ("off", await fulfillDeviceContext(request, through: OffChannel())),
            ("empty", await fulfillDeviceContext(request, through: EmptyChannel())),
            ("blank", await fulfillDeviceContext(request, through: BlankChannel())),
        ] {
            XCTAssertNil(outcome.block, "\(channelName): no block")
            XCTAssertFalse(outcome.requested, "\(channelName): not marked requested")
            XCTAssertTrue(outcome.unavailable,
                          "\(channelName): MUST carry the unavailable terminator")
        }
        let good = await fulfillDeviceContext(request, through: GoodChannel())
        XCTAssertEqual(good.block, "Near: Edinburgh")
        XCTAssertTrue(good.requested)
        XCTAssertFalse(good.unavailable)
    }

    // MARK: - Two channels on one turn

    /// THE REASON THE BUDGET IS KEYED BY CHANNEL. A turn asks for health, gets it, and
    /// the answer then asks for location. With one budget per thread the second
    /// directive would have been starved by the first and could never be answered on
    /// that message, no matter what the agent asked for.
    func testEachChannelHasItsOwnRetryBudget() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsHealth,
                                   answer: "You ran 8km, and the gym is 900m away.",
                                   secondSentinel: needsLocation)
        let delivered = expectation(description: "the answer landed")
        let coordinator = coordinator(fake) { delivered.fulfill() }

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "how far did I run and how far is the gym?",
                         voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fake.fulfillCalls.count, 2,
                       "health spent its budget; location must still have its own")
        guard case .health? = fake.fulfillCalls.first?.request.channel.asCase,
              case .location? = fake.fulfillCalls.last?.request.channel.asCase else {
            return XCTFail("expected health then location, got "
                           + fake.fulfillCalls.map { "\($0.request.channel)" }.joined(separator: ", "))
        }
        // Still exactly ONE persisted answer — two retries, one answer turn.
        XCTAssertEqual(thread.turns.count, 2)
        XCTAssertEqual(thread.orderedTurns.last?.text, "You ran 8km, and the gym is 900m away.")
    }

    /// …and each channel's budget really is one-shot: a thread that asks for location
    /// twice in a row gets one retry, then the directive is ignored.
    func testTheSameChannelStillOnlyGetsOneRetry() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsLocation,
                                   answer: "Best I can do without knowing where you are.",
                                   secondSentinel: needsLocation)
        let delivered = expectation(description: "the answer landed")
        let coordinator = coordinator(fake) { delivered.fulfill() }

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what's near me?", voice: false, context: context)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fake.fulfillCalls.count, 1,
                       "the location budget is spent; the repeat directive is ignored")
        XCTAssertEqual(thread.turns.count, 2)
    }

    /// A NEW user message refills both budgets, so the channel keeps working past the
    /// first question on a thread.
    func testANewMessageRefillsTheBudget() async throws {
        let context = try makeContext()
        let fake = DirectiveClient(sentinel: needsLocation, answer: "Sure.")
        let first = expectation(description: "first answer")
        // `onFirstSuccess` fires per delivered answer, and this test deliberately sends
        // TWO messages — so the expectation must tolerate the second, or XCTest traps
        // on the over-fulfil and takes the whole test host down with it.
        first.assertForOverFulfill = false
        let coordinator = coordinator(fake) { first.fulfill() }

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what's near me?", voice: false, context: context)
        await fulfillment(of: [first], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.fulfillCalls.count, 1)

        coordinator.send(thread: thread, text: "and how far is the station?",
                         voice: false, context: context)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.fulfillCalls.count, 2,
                       "a new user message gets a fresh one-shot budget")
    }
}

/// A tiny helper so the channel of a `DeviceContextRequest` can be pattern-matched in
/// the assertion above without re-deriving it.
private extension DeviceContextChannel {
    enum Case { case health, location }
    var asCase: Case { self == .health ? .health : .location }
}
