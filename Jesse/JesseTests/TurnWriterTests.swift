import XCTest
import SwiftData
@testable import Jesse

/// Direct unit tests for `TurnWriter` — the SwiftData append + save +
/// idempotency-on-jobId concern extracted from `RunCoordinator.finish`. The
/// coordinator's `RunCoordinatorFinishTests` cover the end-to-end render/run-state
/// path; these pin the extracted type's `Outcome` contract in isolation.
@MainActor
final class TurnWriterTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func jesseTurns(_ t: JesseThread) -> [Turn] { t.turns.filter { !$0.isUser } }

    func testDeliveredAppendsTurnSetsSessionAndKey() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let outcome = TurnWriter().write(threadID: thread.id, thread: thread,
                                         reply: JesseReply(text: "hello", sessionId: "s1"),
                                         jobId: "job-1", context: ctx)
        XCTAssertEqual(outcome, .delivered(saved: true))
        XCTAssertEqual(jesseTurns(thread).map(\.text), ["hello"])
        XCTAssertEqual(thread.sessionId, "s1")
        XCTAssertEqual(thread.lastDeliveredJobId, "job-1", "the idempotency key is set on the thread")
    }

    func testSpokenOnlyReplyRecordsTheSpokenLine() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let outcome = TurnWriter().write(threadID: thread.id, thread: thread,
                                         reply: JesseReply(text: "SPOKEN: noted", sessionId: nil),
                                         jobId: "j", context: ctx)
        XCTAssertEqual(outcome, .delivered(saved: true))
        XCTAssertEqual(jesseTurns(thread).map(\.text), ["noted"],
                       "a spoken-only reply records the spoken line, not 'empty'")
    }

    func testGenuinelyEmptyReplyReturnsEmptyAndAppendsNothing() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let outcome = TurnWriter().write(threadID: thread.id, thread: thread,
                                         reply: JesseReply(text: "  \n ", sessionId: nil),
                                         jobId: "j", context: ctx)
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(jesseTurns(thread).isEmpty, "no blank turn for a genuinely empty reply")
    }

    func testUnresolvableThreadReturnsUnresolvable() throws {
        let ctx = try makeContext()
        // No held ref and nothing in the store with this id → the by-id fetch fails.
        let outcome = TurnWriter().write(threadID: UUID(), thread: nil,
                                         reply: JesseReply(text: "x", sessionId: nil),
                                         jobId: "j", context: ctx)
        XCTAssertEqual(outcome, .unresolvableThread)
    }

    func testIdempotentReentryDoesNotAppendSecondTurn() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let writer = TurnWriter()
        _ = writer.write(threadID: thread.id, thread: thread,
                         reply: JesseReply(text: "first", sessionId: "s"), jobId: "job-x", context: ctx)
        // The same job id again must NOT append a second turn.
        let outcome = writer.write(threadID: thread.id, thread: thread,
                                   reply: JesseReply(text: "first", sessionId: "s"), jobId: "job-x", context: ctx)
        XCTAssertEqual(outcome, .alreadyDelivered(saved: true))
        XCTAssertEqual(jesseTurns(thread).count, 1, "idempotent on jobId — no duplicate turn")
    }

    func testSaveFailureReturnsDeliveredNotSavedButStillAppends() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        struct Boom: Error {}
        let writer = TurnWriter(save: { _ in throw Boom() })
        let outcome = writer.write(threadID: thread.id, thread: thread,
                                   reply: JesseReply(text: "shown", sessionId: nil), jobId: "j", context: ctx)
        XCTAssertEqual(outcome, .delivered(saved: false))
        XCTAssertEqual(jesseTurns(thread).map(\.text), ["shown"],
                       "the in-memory append still shows despite the save failure")
    }
}
