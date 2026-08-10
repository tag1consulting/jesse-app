import Foundation
import Observation
import SwiftData
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// How a Today action reaches a conversation ON THIS MAC.
//
// The peer of the iPhone's `TodayThreadOpener` / `TodayProcessRun`, and deliberately
// only the half that touches a coordinator and a store. WHICH prompt each action
// sends and in what mode is `TodayTurn` in JesseTodayDisplay — one definition for
// both platforms, so the Mac cannot end up sending a discussion that is missing the
// scope clause keeping it out of the morning routine.
//
// The split that remains is between EXECUTING and DISCUSSING. `run` is the Health
// tab's "Start new day" path — construct, insert, hand to `MacCoordinator.send` —
// for an action whose meaning is "do this now". `stage` is for an action whose
// meaning is "let's talk about this": it opens the thread and fires NOTHING, because
// a discussion has no content until Jeremy has said what his concern is.

@MainActor
enum MacTodayThreadOpener {
    /// EXECUTE now. The turn goes out the instant the action is taken — Propagate, and
    /// a wiki chip, whose answer is "go read this and tell me".
    ///
    /// A fresh thread every time: these prompts are scoped to ONE item, and resuming an
    /// existing session would carry unrelated context into a turn whose safety comes
    /// from its narrowness.
    @discardableResult
    static func run(_ turn: TodayTurn, coordinator: MacCoordinator,
                    context: ModelContext) -> JesseThread {
        let thread = JesseThread(mode: turn.mode)
        context.insert(thread)
        try? context.save()
        Task {
            await coordinator.send(text: turn.text, mode: turn.mode,
                                   thread: thread, context: context)
        }
        return thread
    }

    /// OPEN for discussion. A new thread carrying `turn.text` as attached context, an
    /// empty composer, and no turn at all; the first turn is Jeremy's own send, which
    /// the coordinator composes with the attachment so the item, its links and the
    /// frozen anti-routing framing still scope it.
    ///
    /// Deliberately NOT inserted into the store. A staged thread has no turns yet, so
    /// inserting it would leave a stray empty conversation in the sidebar the moment he
    /// changes his mind — and worse, `MacRootView.pruneEmptyThreads` reaps empty
    /// thread-less threads on appear, which could delete this one out from under the
    /// open sheet. `MacCoordinator.send` inserts on the first send, so a discussion that
    /// is actually had is persisted and one that is abandoned costs nothing.
    /// `JesseThread.id` is a stored UUID assigned at construction, so the attachment key
    /// is stable across that later insert.
    @discardableResult
    static func stage(_ turn: TodayTurn, coordinator: MacCoordinator) -> JesseThread {
        let thread = JesseThread(mode: turn.mode)
        coordinator.attach(context: turn.text, to: thread.id)
        return thread
    }
}

/// The Process-updates action, as a small piece of state: which turn is ours, and the
/// refetch that has to follow it.
///
/// It exists because "fire and forget" is wrong for exactly this action. The turn
/// REMOVES rows from `Today.md` and may add new ones from the Dashboard, so the screen
/// on display is stale the moment it lands — and unlike a Propagate, which leaves its
/// row checked and in place, there is no way to tell from the row itself that anything
/// happened. So the run is remembered, and the day is refetched when it settles.
///
/// The Mac awaits its own send rather than watching the coordinator's `isRunning` flip,
/// which is what the phone does. `MacCoordinator.send` is an `async` function the caller
/// holds — the Mac has no detached per-thread task registry — so the honest place to
/// learn that the batch is over is where it returns. That also closes the failure the
/// flag-watching shape has: a send REFUSED before it ever ran (unconfigured, or a turn
/// already going) never flips a flag, and would leave the run outstanding forever with
/// every later batch quietly refused.
///
/// One at a time, by construction: `start` refuses while a run is outstanding. Two
/// concurrent batches would be two turns rewriting one file with a stale idea of what
/// the other removed, which is the whole reason this is a batch rather than n
/// propagations.
@MainActor
@Observable
final class MacTodayProcessRun {
    // A @MainActor class's synthesized deinit is MainActor-isolated; releasing this off
    // the main actor (a unit-test host does) would route through the isolated-deinit
    // executor hop and abort. Same pattern as the JesseKit models.
    nonisolated deinit {}

    /// The thread the outstanding batch is running on, if any.
    private(set) var threadID: UUID?

    /// Whether a batch of ours is still out — what the toolbar's spinner reads.
    var isRunning: Bool { threadID != nil }

    /// Fire the one combined turn on a fresh Tell thread, then refetch the day when it
    /// lands. Nil when there is nothing to process or a batch is already out.
    ///
    /// The refetch is UNCONDITIONAL (`refresh`, not `load`): the turn rewrote the file,
    /// so an `If-None-Match` would be asking a question we already know the answer to,
    /// and a `304` from a bridge that had not finished flushing would leave the removed
    /// rows on screen.
    @discardableResult
    func start(items: [TodayItem], coordinator: MacCoordinator, context: ModelContext,
               day: TodayDashboardModel) -> JesseThread? {
        guard !items.isEmpty, threadID == nil else { return nil }
        let turn = TodayTurn.processUpdates(items: items)
        let thread = JesseThread(mode: turn.mode)
        context.insert(thread)
        try? context.save()
        threadID = thread.id
        Task {
            await coordinator.send(text: turn.text, mode: turn.mode,
                                   thread: thread, context: context)
            threadID = nil
            await day.refresh()
        }
        return thread
    }
}
