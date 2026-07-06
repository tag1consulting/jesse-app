import ActivityKit
import Foundation

/// The Live Activity that surfaces an in-flight Jesse turn on the Lock Screen and
/// in the Dynamic Island. Compiled into BOTH the app (which starts/updates/ends it
/// via ActivityKit) and the widget extension (which renders it) — ActivityKit
/// matches the two by this type, so the source is shared, not duplicated.
///
/// The static `attributes` are fixed for the life of the activity (which thread,
/// its title, the turn's mode); the dynamic `ContentState` carries the human
/// activity line plus the turn's start instant, so the widget renders a
/// self-ticking elapsed timer without the app pushing an update every second.
struct JesseTurnActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The coarse "what Jesse is doing" line (from `RunCoordinator.activityLabel`),
        /// e.g. "Reading the vault…". Falls back to a generic waiting line.
        var activityLine: String
        /// When the turn started — the widget renders elapsed from this with a
        /// self-updating timer, so no per-second updates cross the process boundary.
        var startedAt: Date
    }

    /// The thread this turn belongs to — lets the app re-adopt a live activity by
    /// id after a relaunch (ActivityKit hands back `Activity.activities` with their
    /// attributes, but not our own keys) so a stale one can be reconciled/ended.
    var threadID: UUID
    /// The conversation's title (or a placeholder for a brand-new thread).
    var threadTitle: String
    /// A short mode label — "Ask" or "Tell".
    var modeLabel: String
}
