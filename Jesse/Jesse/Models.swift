import Foundation
import SwiftData

// SwiftData store for thread history. A `JesseThread` is one conversation; a
// `Turn` is one message in it. The class is named `JesseThread` rather than
// `Thread` so it can't be confused with `Foundation.Thread`.

enum TurnRole: String {
    case user
    case jesse
}

@Model
final class JesseThread {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    // Drives list ordering — bumped on every new turn.
    var updatedAt: Date = Date()
    // "ask" | "tell", fixed at creation.
    var mode: String = JesseMode.ask.rawValue
    // Bridge session for resume; nil until the first reply lands.
    var sessionId: String?
    // Whether this thread is starred. New property with a default, so SwiftData
    // lightweight-migrates existing stores with no migration code.
    var isFavorite: Bool = false
    // When it was starred; nil whenever `isFavorite` is false. Kept so favorites
    // could later sort by pin time rather than last activity.
    var favoritedAt: Date?
    // The bridge job_id whose reply was last delivered into this thread, used as
    // an idempotency key so a re-entry of `finish` (Re-check / resume re-polling a
    // completed job) can't append the same reply twice. New property with a
    // default, so SwiftData lightweight-migrates existing stores with no migration
    // code (matching `isFavorite`/`favoritedAt`).
    var lastDeliveredJobId: String?
    // A short conversation title minted by the bridge's /jesse/title endpoint,
    // cached so the list row reads better than the derived first-words title. nil
    // until one is generated (and stays nil forever against a bridge that lacks
    // the endpoint — the row falls back to the derived `title`). New property with
    // a default → SwiftData lightweight-migrates existing stores, no migration code.
    var aiTitle: String?
    // The content key (see `threadContentKey`) the current `aiTitle` was minted
    // from. When it no longer equals the thread's live content key, `aiTitle` is
    // stale (a turn was appended or edited) and a regeneration is due. Default nil
    // → lightweight migration, and nil reads as "no cached title yet".
    var titleSourceKey: String?

    @Relationship(deleteRule: .cascade, inverse: \Turn.thread)
    var turns: [Turn] = []

    init(title: String = "", mode: JesseMode = .ask, createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.mode = mode.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var modeValue: JesseMode { JesseMode(rawValue: mode) ?? .ask }

    /// Flip the favorite flag, stamping `favoritedAt` when starring and clearing
    /// it when unstarring. `now` is injectable so tests don't read the clock.
    func toggleFavorite(now: Date = Date()) {
        setFavorite(!isFavorite, now: now)
    }

    /// Set the favorite flag explicitly, keeping `favoritedAt` consistent.
    func setFavorite(_ value: Bool, now: Date = Date()) {
        isFavorite = value
        favoritedAt = value ? now : nil
    }

    /// Turns in chronological order — `turns` itself is an unordered relationship.
    var orderedTurns: [Turn] {
        turns.sorted { $0.createdAt < $1.createdAt }
    }

    /// The whole conversation as a role-labeled Markdown transcript, for copy /
    /// share. Uses each turn's *raw* text so any links or formatting survive,
    /// with a blank line between turns so it reads cleanly when pasted.
    var sharedTranscript: String {
        orderedTurns
            .map { "**\($0.isUser ? "You" : "Jesse"):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Max length of a derived thread title before it's truncated with an ellipsis.
    static let titleCharacterLimit = 60

    /// A short, single-line title derived from the first user message. Used when
    /// a thread is created so the list row reads sensibly before any rename.
    static func deriveTitle(from text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let limit = titleCharacterLimit
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@Model
final class Turn {
    var id: UUID = UUID()
    // "user" | "jesse".
    var role: String = TurnRole.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    var thread: JesseThread?

    init(role: TurnRole, text: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.role = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var roleValue: TurnRole { TurnRole(rawValue: role) ?? .user }
    var isUser: Bool { roleValue == .user }
}
