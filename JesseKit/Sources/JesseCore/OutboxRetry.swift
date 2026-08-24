import Foundation

/// When a failed outbox message is next allowed to retry itself, and when it stops.
///
/// # Why this is a pure type and not a loop in the coordinator
///
/// Until now the send outbox retried only when a human tapped Retry. Adding an automatic
/// retry adds exactly one thing that can go wrong and it is the important one: a message
/// that retries forever against a bridge that will never answer, burning radio on a phone
/// with one bar. So the schedule — the delays, the cap, and the handover back to the
/// manual button — is a function of two integers, tested as a table, and the coordinator
/// only asks it questions.
///
/// The cap is the load-bearing part. After `maxAutomaticAttempts` the message is left
/// `.failed` with its existing per-message Retry showing, exactly as it was before any of
/// this existed: the automatic path is a convenience laid over the manual one, never a
/// replacement for it.
public nonisolated enum OutboxRetrySchedule {
    /// The backoff, in seconds: 5s, 30s, 2min, 10min. Four waits, and therefore four
    /// automatic sends after the first failure.
    ///
    /// It starts short because the overwhelming case is a tunnel or a lift — back inside
    /// thirty seconds — and ends long because everything past that is the laptop being
    /// asleep, which is measured in hours and is not worth waking the radio for.
    public static let delays: [TimeInterval] = [5, 30, 120, 600]

    /// The most automatic sends one message gets before it is handed back to the button.
    /// Five: the four backed-off retries above, plus a fifth immediately on the next path
    /// recovery — coming back onto Wi-Fi is new information, not another tick of a timer.
    public static let maxAutomaticAttempts = 5

    /// How long to wait before automatic attempt number `attempt` (1-based: `1` is the
    /// first automatic retry after the original send failed).
    ///
    /// Past the end of `delays` the last delay repeats, which matters only for the fifth
    /// attempt — the one a path recovery grants — so a recovery that lands during a
    /// backoff does not get to skip ahead to no wait at all.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return delays[0] }
        return delays[min(attempt, delays.count) - 1]
    }

    /// Whether a message that has already been sent `automaticAttempts` times
    /// automatically may be sent again.
    public static func mayRetry(automaticAttempts: Int) -> Bool {
        automaticAttempts < maxAutomaticAttempts
    }

    /// When automatic attempt number `automaticAttempts + 1` becomes due, measured from
    /// the failure at `failedAt`. `nil` once the cap is reached — the message is the
    /// button's from then on.
    public static func nextDue(after failedAt: Date, automaticAttempts: Int) -> Date? {
        guard mayRetry(automaticAttempts: automaticAttempts) else { return nil }
        return failedAt.addingTimeInterval(delay(forAttempt: automaticAttempts + 1))
    }

    /// Whether this message should be transmitted right now.
    ///
    /// `pathJustRecovered` is the second trigger and it deliberately IGNORES the clock:
    /// the delays exist to avoid hammering a network that is not there, and a network
    /// that just came back is precisely the case that reasoning does not apply to. The
    /// attempt CAP still applies, so "recovered" cannot be used to retry forever.
    public static func isDue(automaticAttempts: Int, nextDue: Date?, now: Date,
                             pathJustRecovered: Bool) -> Bool {
        guard mayRetry(automaticAttempts: automaticAttempts) else { return false }
        if pathJustRecovered { return true }
        guard let nextDue else { return false }
        return now >= nextDue
    }
}
