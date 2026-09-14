import XCTest
import SwiftData
@testable import Jesse
import JesseCore

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

    // MARK: - The reply clock (unread replies)

    /// A delivered reply stores the BRIDGE's finalize time, not this device's clock, so
    /// both sides of the unread comparison come off one clock.
    func testDeliveredReplyStoresTheBridgeClock() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let deviceNow = Date(timeIntervalSince1970: 9_999)
        _ = TurnWriter().write(threadID: thread.id, thread: thread,
                               reply: JesseReply(text: "hi", sessionId: "s1", lastReplyMs: 1_234),
                               jobId: "job-1", context: ctx, now: deviceNow)
        XCTAssertEqual(thread.lastReplyMs, 1_234, "the bridge's stamp, not the device's")
        XCTAssertTrue(thread.hasUnreadReply)
    }

    /// Against a bridge too old to send `last_reply_ms` the device clock stands in, so the
    /// dot still appears rather than the feature silently doing nothing.
    func testAnOlderBridgeFallsBackToTheDeviceClock() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let deviceNow = Date(timeIntervalSince1970: 9.999)  // ms 9_999
        _ = TurnWriter().write(threadID: thread.id, thread: thread,
                               reply: JesseReply(text: "hi", sessionId: "s1"),  // lastReplyMs: 0
                               jobId: "job-1", context: ctx, now: deviceNow)
        XCTAssertEqual(thread.lastReplyMs, JesseThread.unixMillis(deviceNow))
        XCTAssertTrue(thread.hasUnreadReply)
    }

    /// RE-DELIVERY MUST NOT MOVE THE STAMP. A Re-check (or a resume re-polling a completed
    /// job) runs `write` again for a job already delivered; if that bumped `lastReplyMs`, a
    /// conversation the user had already read would silently go unread again — and would do
    /// so every time the app re-polled.
    func testRedeliveryOfTheSameJobDoesNotMoveTheReplyStamp() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let writer = TurnWriter()
        _ = writer.write(threadID: thread.id, thread: thread,
                         reply: JesseReply(text: "first", sessionId: "s", lastReplyMs: 1_000),
                         jobId: "job-x", context: ctx)
        XCTAssertTrue(thread.markRead(nowMs: 1), "the user read it")
        XCTAssertFalse(thread.hasUnreadReply)

        // The same job, re-polled, carrying a LATER bridge stamp (a fresh finalize time on
        // the same job) and a later device clock. Neither may move anything.
        let outcome = writer.write(threadID: thread.id, thread: thread,
                                   reply: JesseReply(text: "first", sessionId: "s", lastReplyMs: 9_000),
                                   jobId: "job-x", context: ctx,
                                   now: Date(timeIntervalSince1970: 90))
        XCTAssertEqual(outcome, .alreadyDelivered(saved: true))
        XCTAssertEqual(thread.lastReplyMs, 1_000, "the stamp did not move")
        XCTAssertFalse(thread.hasUnreadReply, "and the conversation stayed read")
    }

    /// A genuinely NEW reply on a conversation already read makes it unread again.
    func testANewReplyAfterReadingMakesItUnreadAgain() throws {
        let ctx = try makeContext()
        let thread = JesseThread(mode: .ask); ctx.insert(thread)
        let writer = TurnWriter()
        _ = writer.write(threadID: thread.id, thread: thread,
                         reply: JesseReply(text: "one", sessionId: "s", lastReplyMs: 1_000),
                         jobId: "job-1", context: ctx)
        thread.markRead(nowMs: 1)
        _ = writer.write(threadID: thread.id, thread: thread,
                         reply: JesseReply(text: "two", sessionId: "s", lastReplyMs: 2_000),
                         jobId: "job-2", context: ctx)
        XCTAssertEqual(thread.lastReplyMs, 2_000)
        XCTAssertTrue(thread.hasUnreadReply)
    }
}
