import Foundation

/// What to do with a thread's Live Activity, given its current run state. Pure so
/// the turn-state → activity mapping is unit-tested without ActivityKit's runtime
/// (`Activity.request` needs a real device with Live Activities enabled).
enum TurnLiveActivityStep: Equatable {
    /// No activity yet and the turn is running → start one.
    case begin(JesseTurnActivityAttributes.ContentState)
    /// An activity is live and the turn is still running → push new content.
    case update(JesseTurnActivityAttributes.ContentState)
    /// An activity is live and the turn is no longer running → dismiss it.
    case end
    /// Nothing to do (no activity and not running, or running but no start date yet).
    case idle
}

enum TurnLiveActivity {
    /// The activity line shown before any `tool_use` event has named one.
    static let waitingLine = "Working on it…"

    /// Map a thread's run state to the single Live Activity action to take.
    ///
    /// - `isRunning`: is a turn actively in flight (RunCoordinator.isRunning).
    /// - `isLive`: does an activity already exist for this thread.
    /// - `startedAt`: the turn's start instant (nil ⇒ nothing to show yet).
    /// - `activityLine`: the coarse activity line, if any (nil/empty ⇒ waiting line).
    static func step(isRunning: Bool, isLive: Bool, startedAt: Date?,
                     activityLine: String?) -> TurnLiveActivityStep {
        switch (isRunning, isLive) {
        case (true, false):
            // Can't start an activity without a start instant for the timer.
            guard let startedAt else { return .idle }
            return .begin(content(startedAt: startedAt, activityLine: activityLine))
        case (true, true):
            guard let startedAt else { return .idle }
            return .update(content(startedAt: startedAt, activityLine: activityLine))
        case (false, true):
            return .end
        case (false, false):
            return .idle
        }
    }

    /// The content state for a running turn: the resolved activity line (falling
    /// back to the waiting line when none has arrived) plus the start instant.
    static func content(startedAt: Date, activityLine: String?) -> JesseTurnActivityAttributes.ContentState {
        let line = (activityLine?.isEmpty == false) ? activityLine! : waitingLine
        return JesseTurnActivityAttributes.ContentState(activityLine: line, startedAt: startedAt)
    }
}
