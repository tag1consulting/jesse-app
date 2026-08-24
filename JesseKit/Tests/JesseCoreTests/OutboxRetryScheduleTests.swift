import XCTest
@testable import JesseCore

/// The automatic send-outbox retry: its delays, its cap, and the two things that make it
/// due. This is the whole of the risk in letting the outbox retry itself, which is why it
/// is a pure function with a table rather than a loop in the coordinator.
final class OutboxRetryScheduleTests: XCTestCase {

    func testDelaysAreFiveSecondsThenThirtyThenTwoMinutesThenTen() {
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 1), 5)
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 2), 30)
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 3), 120)
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 4), 600)
    }

    /// Past the end of the table the last delay repeats — it must never fall back to no
    /// wait at all, which is what a naive index would do.
    func testPastTheTableTheLastDelayRepeats() {
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 5), 600)
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 99), 600)
        XCTAssertEqual(OutboxRetrySchedule.delay(forAttempt: 0), 5, "a nonsense attempt "
                       + "number still waits, rather than sending immediately")
    }

    /// The cap is the important part: a message that retries forever against a bridge that
    /// will never answer is a flat battery and nothing to show for it.
    func testFiveAutomaticAttemptsThenTheButtonOwnsIt() {
        for spent in 0..<5 {
            XCTAssertTrue(OutboxRetrySchedule.mayRetry(automaticAttempts: spent), "\(spent)")
        }
        XCTAssertFalse(OutboxRetrySchedule.mayRetry(automaticAttempts: 5))
        XCTAssertFalse(OutboxRetrySchedule.mayRetry(automaticAttempts: 50))
    }

    func testNextDueWalksTheBackoffAndThenStops() {
        let failedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(OutboxRetrySchedule.nextDue(after: failedAt, automaticAttempts: 0),
                       failedAt.addingTimeInterval(5))
        XCTAssertEqual(OutboxRetrySchedule.nextDue(after: failedAt, automaticAttempts: 1),
                       failedAt.addingTimeInterval(30))
        XCTAssertEqual(OutboxRetrySchedule.nextDue(after: failedAt, automaticAttempts: 3),
                       failedAt.addingTimeInterval(600))
        XCTAssertNil(OutboxRetrySchedule.nextDue(after: failedAt, automaticAttempts: 5),
                     "nil is what hands the message back to the per-message Retry button")
    }

    // MARK: - What makes a message due

    func testDueOnlyOnceTheDelayHasElapsed() {
        let due = Date(timeIntervalSince1970: 1_000_030)
        XCTAssertFalse(OutboxRetrySchedule.isDue(automaticAttempts: 1, nextDue: due,
                                                 now: due.addingTimeInterval(-1),
                                                 pathJustRecovered: false))
        XCTAssertTrue(OutboxRetrySchedule.isDue(automaticAttempts: 1, nextDue: due,
                                                now: due,
                                                pathJustRecovered: false))
    }

    /// A network that just came back is exactly the case the delays exist to avoid, so
    /// they do not apply to it.
    func testAPathRecoveryIgnoresTheBackoffClock() {
        let due = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(OutboxRetrySchedule.isDue(automaticAttempts: 3, nextDue: due,
                                                now: due.addingTimeInterval(-500),
                                                pathJustRecovered: true))
    }

    /// …but it cannot be used to retry without end. A flapping connection is not a licence.
    func testAPathRecoveryStillRespectsTheCap() {
        XCTAssertFalse(OutboxRetrySchedule.isDue(automaticAttempts: 5, nextDue: nil,
                                                 now: Date(), pathJustRecovered: true))
    }

    /// A message with no due date and no recovery is not due — that is the state of a
    /// message whose budget is spent, and of one that has not failed at all.
    func testNoDueDateAndNoRecoveryIsNotDue() {
        XCTAssertFalse(OutboxRetrySchedule.isDue(automaticAttempts: 0, nextDue: nil,
                                                 now: Date(), pathJustRecovered: false))
    }
}
