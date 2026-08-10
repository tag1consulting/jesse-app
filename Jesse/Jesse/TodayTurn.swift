import Foundation
import SwiftData
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// How a Today-tab gesture becomes a turn ON iOS.
//
// WHICH prompt an action sends is no longer here: `TodayTurn` moved into
// JesseTodayDisplay when the Mac grew a Today tab, because "Discuss is an Ask
// carrying the frozen discuss prompt" is a fact about the screen and not about a
// platform, and the second copy of it would have been the one that drifted.
//
// What remains is the half that touches this app's own coordinator and store: that
// starting an action creates a NEW conversation rather than appending to whatever
// was last open, and WHEN the turn is sent — on the tap for an execute action, on
// the user's own first message for a discussion (`TodayThreadOpener`).

/// Opens a Today action on a brand-new thread, in one of the two ways an action can
/// reach a conversation.
///
/// A fresh thread every time, either way: these prompts are scoped to ONE item, and
/// resuming an existing session would carry unrelated context into a turn whose
/// safety comes from its narrowness.
///
/// The split is between EXECUTING and DISCUSSING, and it is the whole point of this
/// type. `run` is the Health tab's "Start new day" path — construct, insert, hand to
/// `RunCoordinator.send` — for an action whose meaning is "do this now". `stage` is
/// for an action whose meaning is "let's talk about this": it opens the thread and
/// fires NOTHING, because a discussion has no content until the user has said what
/// their concern is, and firing on tap made them wait out a full turn before they
/// could type a word.
@MainActor
enum TodayThreadOpener {
    /// EXECUTE now. The turn is on the transcript the instant the button is tapped —
    /// Propagate, and a wiki chip, whose answer is "go read this and tell me".
    @discardableResult
    static func run(_ turn: TodayTurn, coordinator: RunCoordinator,
                    context: ModelContext) -> JesseThread {
        let thread = JesseThread(mode: turn.mode)
        context.insert(thread)
        coordinator.send(thread: thread, text: turn.text, voice: false, context: context)
        return thread
    }

    /// OPEN for discussion. A new thread carrying `turn.text` as attached context, an
    /// empty composer, and no turn at all; the first turn is the user's own send,
    /// which the coordinator composes with the attachment so the item, its links and
    /// the frozen anti-routing framing still scope it.
    ///
    /// Deliberately NOT inserted into the store. A staged thread has no turns yet, so
    /// inserting it would leave a stray empty conversation in the list the moment the
    /// user changes their mind — and worse, the Chats list's `pruneEmpty` reaps empty
    /// thread-less threads on appear, which could delete this one out from under the
    /// open sheet. `RunCoordinator.send` inserts on the first send (the same path the
    /// composer's "+ new conversation" relies on), so a discussion that is actually
    /// had is persisted and one that is abandoned costs nothing. `JesseThread.id` is a
    /// stored UUID assigned at construction, so the attachment key is stable across
    /// that later insert. (Hence no `context:` here: staging touches the store at all
    /// only through the send that may never come.)
    @discardableResult
    static func stage(_ turn: TodayTurn, coordinator: RunCoordinator) -> JesseThread {
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
/// the user is looking at is stale the moment it lands — and unlike a Propagate, which
/// leaves its row checked and in place, there is no way to tell from the row itself
/// that anything happened. So the run is remembered, and the day is refetched when it
/// settles.
///
/// One at a time, by construction: `start` refuses while a run is outstanding. Two
/// concurrent batches would be two turns rewriting one file with a stale idea of what
/// the other removed, which is the whole reason this is a batch rather than n
/// propagations.
@MainActor
@Observable
final class TodayProcessRun {
    // A @MainActor class's synthesized deinit is MainActor-isolated; releasing this off
    // the main actor (a unit-test host does) would route through the isolated-deinit
    // executor hop and abort. Same pattern as the JesseKit models.
    nonisolated deinit {}

    /// The thread the outstanding batch is running on, if any.
    private(set) var threadID: UUID?

    /// Whether our turn is still going, asked of the coordinator rather than tracked
    /// separately — a second copy of "is it running" is a second thing to get wrong.
    func isRunning(_ coordinator: RunCoordinator) -> Bool {
        guard let threadID else { return false }
        return coordinator.isRunning(threadID)
    }

    /// Fire the one combined turn on a fresh Tell thread. Nil when there is nothing to
    /// process or a batch is already out.
    @discardableResult
    func start(items: [TodayItem], coordinator: RunCoordinator,
               context: ModelContext) -> JesseThread? {
        guard !items.isEmpty, threadID == nil else { return nil }
        let thread = TodayThreadOpener.run(.processUpdates(items: items),
                                           coordinator: coordinator, context: context)
        threadID = thread.id
        return thread
    }

    /// A turn settled. If it was OURS, forget it and refetch the day.
    ///
    /// Unconditionally (`refresh`, not `load`): the turn rewrote the file, so an
    /// `If-None-Match` would be asking a question we already know the answer to, and a
    /// `304` from a bridge that had not finished flushing would leave the removed rows
    /// on screen.
    ///
    /// Returns whether it handled the settlement, so the caller knows not to also run
    /// its own generic refetch for the same event.
    @discardableResult
    func settled(coordinator: RunCoordinator, day: TodayDashboardModel) async -> Bool {
        guard let id = threadID, !coordinator.isRunning(id) else { return false }
        threadID = nil
        await day.refresh()
        return true
    }
}
