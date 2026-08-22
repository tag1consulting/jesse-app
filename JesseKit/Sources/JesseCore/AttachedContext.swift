import Foundation

/// Context a SCREEN attached to a conversation it opened without firing a turn.
///
/// This is the generalization of the plain `String` the coordinators used to hold. The
/// Today tab's Discuss needed only a body — one item's markdown, riding the first
/// message — so a string was the whole story. The Health tab's "Ask about this" needs
/// two more things the string could not carry, and neither is worth a second mechanism:
///
///   * `title` — the scope the conversation is ABOUT ("Lunch · Aug 22"), so the chat can
///     say what "this" refers to without pasting the snapshot into the transcript, and
///     so the transcript can label the turn that spent it.
///   * `starters` — the two-to-four opening questions the empty state offers. They exist
///     only until the user types or taps one, so they live in memory beside the body and
///     are never persisted.
///
/// `body` keeps its exact old meaning and its exact old composition rule: it rides the
/// next message through `TodayThreadContext.firstMessage`, ahead of whatever was typed,
/// and an empty composer sends it alone ("just look at it"). Nothing about the Today
/// tab's behavior changes — a Discuss simply attaches a title-less, starter-less value.
///
/// Value type, deliberately: an attachment is a fact about a thread at a moment, held in
/// a dictionary on the coordinator, and it is dropped whole when the screen that made it
/// goes away.
public nonisolated struct AttachedContext: Equatable, Sendable {
    /// The text that rides the next message, composed ahead of whatever the user typed.
    public var body: String
    /// The human scope this conversation is about, for the chat's pinned line and the
    /// transcript's context label. Nil for an attachment with no scope to name (the
    /// Today tab's Discuss), which then reads as the generic "context attached".
    public var title: String?
    /// Opening questions offered in the EMPTY state only. Never persisted.
    public var starters: [String]

    public init(body: String, title: String? = nil, starters: [String] = []) {
        self.body = body
        self.title = title
        self.starters = starters
    }

    /// The label the transcript puts on the turn that spent this attachment, and the
    /// pinned line the composer shows before it is spent. Named here so the phone, the
    /// Mac, and any later shell cannot each invent their own wording.
    public var contextLabel: String {
        guard let title, !title.isEmpty else { return "Context attached" }
        return title
    }
}
