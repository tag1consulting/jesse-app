import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseConversations
import JesseNetworking

/// The other half of the composer's Return behavior: what the send path does with what Return
/// hands it. `ComposerTextViewTests` proves the key press reaches `send()`; these prove the gate
/// refuses an empty draft and that a hand-typed multiline message survives to the bridge with its
/// newlines intact and unescaped.
@MainActor
final class MacComposerSendGateTests: XCTestCase {

    private func coordinator(_ fake: MacFakeBridgeClient,
                             config: MacConfigStore = MacTestFixtures.configured()) -> MacCoordinator {
        MacCoordinator(configStore: config, makeClient: { _ in fake },
                       sessionDeletionStore: MacTestFixtures.deletionStore())
    }

    // MARK: - The gate

    func testEmptyAndWhitespaceOnlyDraftsSendNothing() async throws {
        for draft in ["", " ", "   \t  ", "\n", " \n \n "] {
            let context = try MacTestFixtures.context()
            let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
            let fake = MacFakeBridgeClient()
            let coord = coordinator(fake)

            await coord.send(text: draft, mode: .ask, thread: thread, context: context)

            XCTAssertTrue(fake.sentTexts.isEmpty,
                          "a draft of only whitespace must never reach the bridge (\(draft.debugDescription))")
            XCTAssertTrue(thread.orderedTurns.isEmpty, "and must not create a turn")
            XCTAssertFalse(coord.isRunning)
        }
    }

    /// While a turn is in flight the send gate is closed, so Return does exactly what the
    /// disabled send button does: nothing.
    func testASecondSendIsRefusedWhileATurnIsRunning() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let sid = "sess-\(UUID().uuidString)"; defer { MacCursorStore.clear(sid) }
        // A reply that only finishes once the test lets it, so a second send lands mid-flight.
        let gate = AsyncGate()
        let fake = MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "reply", sessionId: sid), jobId: nil,
                               conversationId: nil),
            beforeSend: { await gate.wait() })
        let coord = coordinator(fake)

        let first = Task { await coord.send(text: "first", mode: .ask, thread: thread, context: context) }
        // Let the first send get as far as the (blocked) client call.
        var spins = 0
        while !coord.isRunning && spins < 10_000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(coord.isRunning, "precondition: the first turn is in flight")

        await coord.send(text: "second", mode: .ask, thread: thread, context: context)
        XCTAssertEqual(fake.sentTexts, [], "the in-flight turn holds the gate shut")
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["first"],
                       "the refused send adds no second user turn")

        await gate.open()
        await first.value
        XCTAssertEqual(fake.sentTexts, ["first"])
    }

    // MARK: - Multiline payload

    func testAHandTypedMultilineMessageReachesTheBridgeWithItsNewlines() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let sid = "sess-\(UUID().uuidString)"; defer { MacCursorStore.clear(sid) }
        let fake = MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "ok", sessionId: sid), jobId: nil, conversationId: nil))
        let draft = "line one\nline two\nline three"

        await coordinator(fake).send(text: draft, mode: .ask, thread: thread, context: context)

        XCTAssertEqual(fake.sentTexts, [draft],
                       "the newlines reach the bridge as newlines, neither escaped nor collapsed")
        XCTAssertEqual(thread.orderedTurns.first?.text, draft,
                       "and the transcript keeps the message the user typed")
        XCTAssertEqual(thread.orderedTurns.first?.text.filter { $0 == "\n" }.count, 2)
    }

    /// Trimming is edge-only: leading and trailing whitespace goes, interior newlines stay.
    func testSurroundingWhitespaceIsTrimmedWithoutTouchingInteriorNewlines() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask); context.insert(thread); try context.save()
        let sid = "sess-\(UUID().uuidString)"; defer { MacCursorStore.clear(sid) }
        let fake = MacFakeBridgeClient(
            sendResult: .reply(JesseReply(text: "ok", sessionId: sid), jobId: nil, conversationId: nil))

        await coordinator(fake).send(text: "\n  first\n\nsecond  \n", mode: .ask, thread: thread,
                                     context: context)

        XCTAssertEqual(fake.sentTexts, ["first\n\nsecond"])
    }
}

/// A one-shot async gate, so a test can hold a fake's `send` open and observe the in-flight state.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
