import ActivityKit
import Foundation

/// The app's seam onto the turn Live Activity. RunCoordinator drives this at the
/// turn lifecycle points (start / activity-line change / finish / fail); the real
/// implementation talks to ActivityKit, and tests inject a no-op so the coordinator
/// suite never touches the (device-only) Live Activity runtime.
@MainActor
protocol TurnLiveActivityManaging {
    /// Reconcile the Live Activity for `threadID` against its current run state.
    /// `attributes` is required only when starting a fresh activity (the send path
    /// supplies it); on update/end paths it's nil and ignored. The begin/update/end
    /// decision is the pure `TurnLiveActivity.step`.
    func sync(threadID: UUID, isRunning: Bool, startedAt: Date?, activityLine: String?,
              attributes: JesseTurnActivityAttributes?)
    /// End any adopted activity whose thread isn't in `keeping` — clears a Live
    /// Activity left stranded when the app was killed mid-turn and the turn has
    /// since resolved. Called on foreground with the set of still-in-flight threads.
    func endStale(keeping: Set<UUID>)
}

/// No-op used in tests (and anywhere Live Activities are irrelevant).
@MainActor
struct NoopTurnLiveActivityManager: TurnLiveActivityManaging {
    func sync(threadID: UUID, isRunning: Bool, startedAt: Date?, activityLine: String?,
              attributes: JesseTurnActivityAttributes?) {}
    func endStale(keeping: Set<UUID>) {}
}

/// The real ActivityKit-backed manager. Keeps one `Activity` per thread, adopting
/// any that survived a relaunch so they can still be updated/ended. All ActivityKit
/// mutations are async, so update/end are fire-and-forget `Task`s off the main actor.
@MainActor
final class TurnLiveActivityController: TurnLiveActivityManaging {
    private var activities: [UUID: Activity<JesseTurnActivityAttributes>] = [:]

    init() {
        // Re-adopt activities the system kept alive across a relaunch, keyed by the
        // threadID we stamped into their attributes, so a finishing turn (or a
        // foreground reconcile) can end the right one.
        for activity in Activity<JesseTurnActivityAttributes>.activities {
            activities[activity.attributes.threadID] = activity
        }
    }

    func sync(threadID: UUID, isRunning: Bool, startedAt: Date?, activityLine: String?,
              attributes: JesseTurnActivityAttributes?) {
        switch TurnLiveActivity.step(isRunning: isRunning,
                                     isLive: activities[threadID] != nil,
                                     startedAt: startedAt,
                                     activityLine: activityLine) {
        case .begin(let content):
            guard let attributes else { return }   // can't start without the static attributes
            begin(threadID: threadID, attributes: attributes, content: content)
        case .update(let content):
            update(threadID: threadID, content: content)
        case .end:
            end(threadID: threadID)
        case .idle:
            break
        }
    }

    func endStale(keeping: Set<UUID>) {
        for threadID in activities.keys where !keeping.contains(threadID) {
            end(threadID: threadID)
        }
    }

    private func begin(threadID: UUID, attributes: JesseTurnActivityAttributes,
                       content: JesseTurnActivityAttributes.ContentState) {
        // Respect the user's system setting; never throw into the turn path.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil)
            activities[threadID] = activity
        } catch {
            Log.run.error("Live Activity start failed: \(error.localizedDescription)")
        }
    }

    private func update(threadID: UUID, content: JesseTurnActivityAttributes.ContentState) {
        guard let activity = activities[threadID] else { return }
        Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
    }

    private func end(threadID: UUID) {
        guard let activity = activities.removeValue(forKey: threadID) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
