import Foundation
import SwiftData
import JesseCore
import JesseTodayDisplay

/// The seam the OFFLINE CAPTURE QUEUE plugs into.
///
/// It shipped one release ahead of the queue, deliberately: the queue needed exactly one
/// thing from the rest of the app — to be told the moment the network came back, at the
/// same instant the in-flight jobs re-attach and the send outbox drains, rather than on
/// its own timer that races them. So the trigger landed first, `RunCoordinator` called
/// `replayAll()` on every recovery, and the default conformer did nothing.
///
/// The queue is here now (`IntentReplayer` in JesseTodayDisplay), and not one recovery
/// path had to be found and edited to reach it.
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

/// The stand-in for a process with no queue wired up — a preview, a test that is about
/// something else, or the window between launch and the first appearance of the tab bar
/// that builds the real one. Its presence is the point: the coordinator holds a
/// non-optional `IntentReplaying`, so there is no `if let` to forget and no second code
/// path to keep in step.
@MainActor
final class NoIntentReplayer: IntentReplaying {}

/// The app's live replayer, resolved when the tab bar builds one and read by the
/// coordinator's recovery path.
///
/// A box rather than a direct injection, and that is forced by the wiring rather than
/// chosen: `RunCoordinator` is created by `JesseApp` before any view exists, while the
/// replayer needs the day model and the diet model, which `RootTabView` owns. The
/// coordinator therefore holds this box from the start and the box is filled once the
/// models exist. A recovery that fires before then finds nothing to replay, which is
/// correct — nothing has been captured yet either.
@MainActor
final class IntentReplayerBox: IntentReplaying {
    nonisolated deinit {}

    private var replayer: IntentReplayer?

    /// Point the box at the real replayer. Idempotent: the tab bar builds one on its
    /// first appearance and calls this, and a second appearance must not replace a
    /// replayer that may be mid-run.
    func adopt(_ replayer: IntentReplayer) {
        guard self.replayer == nil else { return }
        self.replayer = replayer
    }

    /// The replayer, once there is one — for the paths that want to run it directly (a
    /// per-row Retry) rather than as part of a recovery.
    var current: IntentReplayer? { replayer }

    func replayAll() async {
        await replayer?.replayAll()
    }
}

/// Sends a queued quick log (or a Start-new-day) as a Tell on a fresh thread, through
/// the ordinary send path.
///
/// It goes through `RunCoordinator.send` rather than talking to the client directly, and
/// that is what makes a replayed log behave like a typed one: the same user turn in the
/// same transcript, the same outbox row with the same idempotency key, the same
/// per-message Retry if the send itself fails. A private path to the bridge would be a
/// second implementation of all of it, and the second one is the one that loses a meal.
@MainActor
final class CoordinatorTellSender: IntentTellSending {
    nonisolated deinit {}

    private let coordinator: RunCoordinator
    private let context: ModelContextProviding

    init(coordinator: RunCoordinator, context: ModelContextProviding) {
        self.coordinator = coordinator
        self.context = context
    }

    /// Send, and answer whether the bridge ACCEPTED it.
    ///
    /// It WAITS for that answer, which is the one thing this type is for: a quick-log
    /// replay must not send a day's second meal until the first has landed, because a log
    /// that arrives out of order reads as a different day's.
    func sendTell(_ text: String) async -> Bool {
        guard let modelContext = context.modelContext else { return false }
        let thread = JesseThread(mode: .tell)
        modelContext.insert(thread)
        return await withCheckedContinuation { continuation in
            // `onAck` fires exactly once, on the `202` or on any pre-ACK failure, and it
            // fires BEFORE the turn's answer — which is the point. Waiting for the reply
            // would put minutes between a day's meals; waiting for the ACK puts a round
            // trip between them, which is exactly enough to keep them in order.
            coordinator.send(thread: thread, text: text, voice: false,
                             context: modelContext) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}

/// The narrow way this file reaches the app's store. A protocol rather than a
/// `ModelContext` so a test can hand over nothing and get an honest `false`.
@MainActor
protocol ModelContextProviding: AnyObject {
    var modelContext: ModelContext? { get }
}

/// The app's shared container, as a `ModelContextProviding`.
@MainActor
final class AppModelContextProvider: ModelContextProviding {
    nonisolated deinit {}
    private let container: ModelContainer

    init(container: ModelContainer = AppModelContainer.shared.container) {
        self.container = container
    }

    private lazy var context = ModelContext(container)
    var modelContext: ModelContext? { context }
}
