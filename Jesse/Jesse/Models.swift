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

    /// A short, single-line title derived from the first user message. Used when
    /// a thread is created so the list row reads sensibly before any rename.
    static func deriveTitle(from text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let limit = 60
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
