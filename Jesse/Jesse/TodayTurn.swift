import Foundation
import SwiftData
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// How a Today-tab gesture becomes a turn.
//
// Two small pieces, kept out of the view because both are things a test should be
// able to state: WHICH prompt an action sends (`TodayTurn`), and that starting one
// creates a NEW conversation rather than appending to whatever was last open
// (`TodayThreadOpener`).
//
// The prompt text is never assembled here. `TodayDiscuss.prompt` and
// `TodayPropagate.prompt` (JesseCore) are frozen wordings whose scope clauses are
// what keep an item discussion from tripping the morning routine and a propagation
// from closing work nobody did — see their file. This layer only chooses between
// them and picks the mode.

/// One Today action, resolved to the turn it sends.
struct TodayTurn: Equatable {
    let mode: JesseMode
    let text: String

    /// "Discuss this item with me."
    ///
    /// ASK, not Tell. The turn's purpose is a conversation, and Ask carries the
    /// floor that forbids task-work Jeremy did not request — which is exactly the
    /// protection wanted around a screen whose whole content is a list of tasks. The
    /// discuss prompt still asks, explicitly and in its own words, for Today.md and
    /// the item's home to be updated IF the discussion changes the item; that is a
    /// request, so the Ask floor does not stand in its way.
    static func discuss(item: TodayItem) -> TodayTurn {
        TodayTurn(mode: .ask, text: TodayDiscuss.prompt(item: item.text))
    }

    /// "I finished this — close it at source."
    ///
    /// TELL: it writes to the project file and the Dashboard. `evidence` is the line
    /// the completion recorded (the user's own words, or the file's); nil produces
    /// the builder's "none", never an empty quotation.
    static func propagate(item: TodayItem, evidence: String?) -> TodayTurn {
        TodayTurn(mode: .tell, text: TodayPropagate.prompt(item: item.text, evidence: evidence))
    }

    /// What a tapped link chip should do, when the answer is "a conversation".
    ///
    /// A URL is not one — it opens in the browser through the system's own handling,
    /// so this answers nil for it. A `[[wiki]]` target has no in-app viewer in v1
    /// (noted as a follow-on), and the honest fallback is a discussion seeded with
    /// the row that referenced the note: the agent can read the file, which the app
    /// cannot. It reuses `TodayDiscuss.prompt` rather than introducing a second
    /// wording for the same act.
    static func openLink(_ origin: TodayLinkOrigin) -> TodayTurn? {
        guard origin.link.isWiki else { return nil }
        return TodayTurn(mode: .ask, text: TodayDiscuss.prompt(item: origin.sourceText))
    }
}

/// Starts a Today action's turn on a brand-new thread.
///
/// The same path the Health tab's "Start new day" button takes — construct the
/// thread, insert it, hand it to `RunCoordinator.send` — and for the same reason:
/// the coordinator owns the optimistic user turn, the background task, the poll
/// loop and the re-attach on foreground, so a turn started from a tab behaves
/// exactly like one typed in the composer. A fresh thread every time is deliberate:
/// these prompts are scoped to ONE item, and resuming an existing session would
/// carry unrelated context into a turn whose safety comes from its narrowness.
@MainActor
enum TodayThreadOpener {
    @discardableResult
    static func open(_ turn: TodayTurn, coordinator: RunCoordinator,
                     context: ModelContext) -> JesseThread {
        let thread = JesseThread(mode: turn.mode)
        context.insert(thread)
        coordinator.send(thread: thread, text: turn.text, voice: false, context: context)
        return thread
    }
}
