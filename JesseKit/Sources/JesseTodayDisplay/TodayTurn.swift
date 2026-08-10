import Foundation
import JesseCore
import JesseNetworking

// WHICH turn a Today-tab gesture sends, and in which mode.
//
// Portable on purpose. This started life in the iOS target next to
// `TodayThreadOpener`, which is where it had to stay while iOS was the only shell
// with a Today tab; the Mac tab made it the second place that would have to know
// that Discuss is an Ask carrying `TodayDiscuss.prompt` and Propagate a Tell
// carrying `TodayPropagate.prompt`. A second copy of that mapping is a second thing
// to get wrong, and getting it wrong means a turn whose scope clauses are missing —
// an item discussion that trips the morning routine, or a propagation that closes
// work nobody did.
//
// What stayed behind in each app target is everything that touches a coordinator or
// a store: how a turn is DISPATCHED (fire now, or hold for the user's first
// message), and on what thread. That half is genuinely per-platform; this half is
// not.
//
// The prompt text is never assembled here either. `TodayDiscuss.prompt`,
// `TodayPropagate.prompt` and `TodayProcessUpdates.prompt` (JesseCore) are frozen
// wordings whose scope clauses are what keep those turns bounded — see their file.
// This type only chooses between them and picks the mode.

/// One Today action, resolved to the turn it sends.
public struct TodayTurn: Equatable, Sendable {
    public let mode: JesseMode
    public let text: String

    public init(mode: JesseMode, text: String) {
        self.mode = mode
        self.text = text
    }

    /// "Discuss this item with me."
    ///
    /// Its text is ATTACHED, not fired: a discussion opens on an empty composer and
    /// sends this with the user's own first message (see `TodayThreadContext`).
    ///
    /// ASK, not Tell. The turn's purpose is a conversation, and Ask carries the
    /// floor that forbids task-work Jeremy did not request — which is exactly the
    /// protection wanted around a screen whose whole content is a list of tasks. The
    /// discuss prompt still asks, explicitly and in its own words, for Today.md and
    /// the item's home to be updated IF the discussion changes the item; that is a
    /// request, so the Ask floor does not stand in its way.
    public static func discuss(item: TodayItem) -> TodayTurn {
        TodayTurn(mode: .ask, text: TodayDiscuss.prompt(item: item.text))
    }

    /// "I finished this — close it at source."
    ///
    /// TELL: it writes to the project file and the Dashboard. `evidence` is the line
    /// the completion recorded (the user's own words, or the file's); nil produces
    /// the builder's "none", never an empty quotation.
    public static func propagate(item: TodayItem, evidence: String?) -> TodayTurn {
        TodayTurn(mode: .tell, text: TodayPropagate.prompt(item: item.text, evidence: evidence))
    }

    /// "Process the updates" — every item ticked today, closed at source in ONE turn.
    ///
    /// TELL, and the largest one this screen can send: it writes to each item's project
    /// file, to the Dashboard, and to `Today.md` itself, from which the processed lines
    /// are removed. Which is exactly why it is confirmed against a list of the actual
    /// rows before it fires (`TodayProcessSheet`) and never on a toolbar tap.
    ///
    /// The RAW markdown of each item, like the two single-item prompts: the links are
    /// how the agent finds each home and the `(Added …)` trailers are how it tells two
    /// similarly-worded lines apart.
    public static func processUpdates(items: [TodayItem]) -> TodayTurn {
        TodayTurn(mode: .tell, text: TodayProcessUpdates.prompt(items: items.map(\.text)))
    }

    /// What a tapped link chip should do, when the answer is "a conversation".
    ///
    /// A URL is not one — it opens in the browser through the system's own handling,
    /// so this answers nil for it. A `[[wiki]]` target has no in-app viewer in v1
    /// (noted as a follow-on), and the honest fallback is a discussion seeded with
    /// the row that referenced the note: the agent can read the file, which the app
    /// cannot. It reuses `TodayDiscuss.prompt` rather than introducing a second
    /// wording for the same act.
    public static func openLink(_ origin: TodayLinkOrigin) -> TodayTurn? {
        guard origin.link.isWiki else { return nil }
        return TodayTurn(mode: .ask, text: TodayDiscuss.prompt(item: origin.sourceText))
    }
}
