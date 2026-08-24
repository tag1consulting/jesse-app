import Foundation

/// The seam a future OFFLINE INTENT QUEUE plugs into.
///
/// The day file is not queueable and the README says so: it is rewritten in full every
/// morning, so a checkbox held through an outage would replay against a document that has
/// since moved on. Some *other* intents are queueable, and when one of those queues
/// exists it will need exactly one thing from this file — to be told the moment the
/// network came back, at the same instant the in-flight jobs re-attach and the send outbox
/// drains, rather than on its own timer that races them.
///
/// So the trigger ships now and the queue does not. `RunCoordinator` calls `replayAll()`
/// on every recovery; the default conformer does nothing, so today that call is free.
/// When the queue lands it conforms and is injected, and no recovery path has to be found
/// and edited.
@MainActor
protocol IntentReplaying: AnyObject {
    /// Replay whatever is queued. Called on a network recovery and on app activation with
    /// a satisfied path. Must be idempotent and must not throw: the recovery it rides on
    /// has three other jobs to do and cannot be blocked by this one.
    func replayAll() async
}

extension IntentReplaying {
    /// The default: nothing is queued, so nothing replays.
    func replayAll() async {}
}

/// The stand-in until there is a queue. Its presence is the point — the coordinator holds
/// a non-optional `IntentReplaying`, so there is no `if let` to forget and no second code
/// path to keep in step.
@MainActor
final class NoIntentReplayer: IntentReplaying {}
