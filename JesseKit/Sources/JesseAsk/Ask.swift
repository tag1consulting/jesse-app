import Foundation
import JesseCore

// "Ask about this" — the context model behind a long press (iOS) or a right click (macOS)
// on anything a screen draws.
//
// The whole feature is ONE idea: a gesture on anything the app draws opens the app's
// existing chat already knowing exactly what was being looked at. This file holds the
// shape of "exactly what was being looked at"; each SCREEN's own module builds one from
// its data (`HealthAsk` for the Health tab, `OpsAsk` for the Ops screen); `Askable.swift`
// attaches the gesture; the two app shells own the presentation. No new chat, no new UI,
// no new chrome.
//
// WHY THIS IS ITS OWN TARGET. It started inside the diet display, because the Health tab
// was the only screen that had the gesture. Extending it to Ops made the choice explicit:
// either the machinery is copied into a second module, or it moves somewhere both can
// reach. Everything here is domain-free — a tree of labelled strings, a budget, a scope,
// a range, an identity, and a menu — and every line that knew what a meal was stayed
// behind in `JesseDietDisplay`. Two screens now share one implementation; a third adds a
// serializer and a prompt and nothing else.
//
// THE SNAPSHOT IS WHAT THE SCREEN SHOWS, not a re-query. Every serializer is handed the
// values the view already holds and serializes those. A second read of the same data
// through a different code path would eventually disagree with the pixels, and a chat
// that contradicts the screen it was opened from is worse than no chat at all.
//
// COMPOSITION, NOT THREE SERIALIZERS PER AREA. An `AskFacts` is a small tree: a heading,
// some lines, some child blocks. An item is a leaf, a section is its items' blocks under
// one heading, a page is its sections'. So each unit is serialized ONCE and the wider
// scopes are unions of the narrower ones — which is also what guarantees the three scopes
// can never tell three different stories about the same number.

// MARK: - Scope

/// How much of the screen an ask covers. The three levels the gesture offers, and the
/// word the prompt uses to describe the reading.
public enum AskScope: String, Equatable, Sendable, CaseIterable {
    /// A whole page or sub-page, for the current time range.
    case page
    /// One section of a page — a group of rows, a card, a chart's surrounding block.
    case section
    /// A single thing: a meal, a food, a workout, a service row, a release, a ledger line.
    case item

    /// The word the prompt uses ("a page-level reading"). Same as the raw value today;
    /// spelled through a property so the wire-ish raw value and the prose can diverge.
    public var word: String { rawValue }
}

// MARK: - Domain

/// Which SCREEN an ask came from: the namespace its identities live in, and the frozen
/// prompt its turns are wrapped in.
///
/// A value rather than an enum, so a screen's module declares its own domain beside its
/// serializers (`AskDomain.health`, `AskDomain.ops`) and this target never has to know
/// which screens exist. The prompt rides in the domain for the reason it is frozen at
/// all: the wording is a behaviour contract with the agent, so the layer that renders the
/// numbers must not also be the layer that can quietly reword the instruction around them.
public struct AskDomain: Equatable, Sendable {
    /// The first path segment of every `scopeKey` in this domain — which is what stops an
    /// Ops key and a Health key ever colliding.
    public let key: String
    /// The domain's user-facing name, for a menu or a title that needs to say which screen.
    public let label: String
    private let build: @Sendable (_ title: String, _ scope: String,
                                  _ range: String, _ snapshot: String) -> String

    public init(key: String, label: String,
                prompt: @escaping @Sendable (_ title: String, _ scope: String,
                                             _ range: String, _ snapshot: String) -> String) {
        self.key = key
        self.label = label
        self.build = prompt
    }

    func prompt(title: String, scope: String, range: String, snapshot: String) -> String {
        build(title, scope, range, snapshot)
    }

    /// Identity is the KEY. Two domains with the same key are the same domain — closures
    /// have no equality, and a domain is a singleton per module anyway.
    public static func == (a: AskDomain, b: AskDomain) -> Bool { a.key == b.key }
}

// MARK: - Range

/// The range of time the reading covers, in the two forms it is needed in: words for the
/// prompt and the title, and a stable key for deciding whether a later ask is about the
/// SAME reading (see `AskContext.scopeKey`).
///
/// "Range" is the Health tab's word for it; an Ops reading is an instant rather than a
/// span, and it uses the same two fields — the label says when it was taken, and the key
/// is the device day, so two presses this afternoon resume one conversation and tomorrow's
/// starts another.
public struct AskTimeRange: Equatable, Sendable {
    /// How the range reads in a sentence: "today", "the last 7 days", "Saturday, July 12".
    public var label: String
    /// The stable identity of the range. Two asks match only when these are equal, so it
    /// carries the anchor date as well as the span — "the last 7 days" asked on two
    /// different days are two different readings.
    public var key: String

    public init(label: String, key: String) {
        self.label = label
        self.key = key
    }
}

// MARK: - The facts tree

/// A compact, structured snapshot of one scope: a heading, some lines, and the blocks of
/// whatever sits inside it.
///
/// Deliberately a TREE of plain strings rather than a typed payload per area. What the
/// model needs is the numbers with their labels and units in the order the screen shows
/// them; what a typed payload would buy is validation nobody performs. The tree is what
/// makes composition trivial — a section is `children: items.map(serialize)` — and it is
/// what lets one renderer produce the whole snapshot.
public struct AskFacts: Equatable, Sendable {
    /// The block's own heading, or nil for an unlabelled group of lines.
    public var heading: String?
    /// The block's own facts, one per line, already formatted with their units.
    public var lines: [String]
    /// Nested blocks — the items inside a section, the sections inside a page.
    public var children: [AskFacts]
    /// A qualification on this block: what was summarized away, what is unknown rather
    /// than zero, what a number is a floor of. Rendered last, in parentheses.
    public var note: String?

    public init(heading: String? = nil, lines: [String] = [],
                children: [AskFacts] = [], note: String? = nil) {
        self.heading = heading
        self.lines = lines
        self.children = children
        self.note = note
    }

    /// Whether this block carries nothing at all, so a composer can drop it rather than
    /// emit an empty heading.
    public var isEmpty: Bool {
        lines.isEmpty && note == nil && children.allSatisfy(\.isEmpty)
    }

    /// Render to the plain indented text the prompt carries.
    ///
    /// Plain text, not JSON: the block is read by a language model, and a page of
    /// `{"key": value}` spends a third of its tokens on punctuation that means nothing to
    /// the reader. Indentation carries the nesting; a leading `- ` marks a fact.
    public func render(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        if let heading, !heading.isEmpty { out.append(pad + heading) }
        let inner = heading == nil ? pad : pad + "  "
        for line in lines where !line.isEmpty { out.append(inner + "- " + line) }
        for child in children where !child.isEmpty {
            out.append(child.render(indent: heading == nil ? indent : indent + 2))
        }
        if let note, !note.isEmpty { out.append(inner + "(" + note + ")") }
        return out.joined(separator: "\n")
    }
}

// MARK: - Budget

/// What keeps an aggregate ask from blowing the prompt budget.
///
/// The rule everywhere is the same and it is stated in the snapshot rather than applied
/// silently: keep the TOTALS (which are computed over everything) and the top N rows by
/// magnitude, then say how many rows were left out. A truncated list that does not admit
/// it is how a model concludes the user ate four things today — or that a Studio is one
/// release behind when it is twelve.
public enum AskBudget {
    /// How many rows a list inside a snapshot may carry before it is capped. Twelve is
    /// past the length of a real meal or a real day's sessions, so the cap almost never
    /// fires on an item or a section — it exists for the page-level union.
    public static let maxListItems = 12

    /// How many rows a list nested two levels down (foods inside meals inside a page) may
    /// carry. Tighter, because the page multiplies it by the number of meals.
    public static let maxNestedListItems = 6

    /// The hard ceiling on a rendered snapshot, in characters. Roughly three thousand
    /// tokens: comfortably inside any turn's budget while leaving the conversation itself
    /// most of the window. A snapshot that reaches this is truncated at a block boundary
    /// and says so.
    public static let maxCharacters = 12_000

    /// Take the first `limit` of `items` (the caller has already ordered them by whatever
    /// "most important" means for that list) and the sentence describing what was left.
    public static func cap<T>(_ items: [T], limit: Int = maxListItems,
                              noun: String,
                              totalsCoverAll: Bool = true) -> (kept: [T], note: String?) {
        guard items.count > limit else { return (items, nil) }
        let hidden = items.count - limit
        let tail = totalsCoverAll
            ? " — the totals above still count all of them"
            : ""
        return (Array(items.prefix(limit)),
                "\(hidden) more \(noun) not listed\(tail)")
    }

    /// Clamp a rendered snapshot to `maxCharacters`, cutting at the last whole line and
    /// stating that it was cut. Never silently truncates mid-number.
    public static func clamp(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let head = text.prefix(maxCharacters)
        let cut = head.lastIndex(of: "\n").map { String(head[head.startIndex..<$0]) } ?? String(head)
        return cut + "\n(snapshot truncated here to fit — ask for any part of it in full)"
    }
}

// MARK: - The context

/// Everything a chat needs to be opened about one thing on one screen.
///
/// The public surface the app shells use is deliberately narrow: they read `title`,
/// `scopeKey`, `attachment` and nothing else. Which numbers went in, and how they were
/// rendered, stays inside the module that holds the view they came from.
public struct AskContext: Equatable, Sendable, Identifiable {
    /// Which screen this came from — the key namespace and the frozen prompt.
    public let domain: AskDomain
    public let scope: AskScope
    /// The domain's own area, as its raw value ("macros", "deploy"). A string here rather
    /// than a generic parameter: every consumer of it either prints it or concatenates it
    /// into an identity, and making the context generic over each screen's enum would
    /// spread that generic through the environment action and both shells for nothing.
    public let area: String
    public let timeRange: AskTimeRange
    /// The human string the chat header and the conversation list show: "Lunch · Aug 22",
    /// "Deploy · Ops".
    public let title: String
    /// The tail of the menu wording — "this meal", "today's macros", "this release". Set
    /// by each serializer, because only it knows what noun the thing is.
    public let subject: String
    /// The stable identity of the SUBJECT within its area and range (a meal name, a
    /// nutrient key, a service id, a release sha). Part of `scopeKey`; never shown.
    let subjectKey: String
    /// The structured snapshot of exactly what is on screen for this scope.
    public let facts: AskFacts
    /// Ids the chat can use to dig further — a date, a nutrient key, a commit sha. Passed
    /// to the agent as a short "if you need more" line, NEVER as a fetch instruction: they
    /// name the thing, and whether looking it up is worth a tool call is the agent's call.
    public let related: [String]
    /// Two to four opening questions, appropriate to the scope. Offered in the chat's
    /// empty state only.
    public let suggestedQuestions: [String]

    public init(domain: AskDomain, scope: AskScope, area: String, timeRange: AskTimeRange,
                title: String, subject: String, subjectKey: String = "",
                facts: AskFacts, related: [String] = [],
                suggestedQuestions: [String] = []) {
        self.domain = domain
        self.scope = scope
        self.area = area
        self.timeRange = timeRange
        self.title = title
        self.subject = subject
        self.subjectKey = subjectKey
        self.facts = facts
        self.related = related
        self.suggestedQuestions = suggestedQuestions
    }

    public var id: String { scopeKey }

    /// The identity of this READING — domain, area, scope, range, subject. Two asks with
    /// the same key are about the same thing, which is what "resume today's conversation
    /// about this instead of starting a new one" is decided on.
    ///
    /// The DOMAIN leads, so a Health key and an Ops key can never collide however their
    /// area names evolve. The range's key carries its anchor date, so the same question
    /// asked tomorrow is a different key and gets its own conversation.
    public var scopeKey: String {
        let subject = subjectKey.isEmpty ? "-" : AskContext.slug(subjectKey)
        return "\(domain.key)/\(area)/\(scope.rawValue)/\(timeRange.key)/\(subject)"
    }

    /// The rendered, budget-clamped snapshot — the block the prompt fences.
    public var snapshotText: String {
        var body = facts.render()
        if !related.isEmpty {
            body += "\n\nIf you need more than this, these are what it goes by: "
                + related.joined(separator: ", ")
        }
        return AskBudget.clamp(body)
    }

    /// The full turn text: the domain's frozen prompt wrapped around the snapshot.
    /// Assembled here and nowhere else, so no shell can send a differently-scoped version.
    public var promptText: String {
        domain.prompt(title: title, scope: scope.word,
                      range: timeRange.label, snapshot: snapshotText)
    }

    /// The single context-menu item's wording, adapted to what was pressed.
    public var menuLabel: String { "Ask about \(subject)" }

    /// The attachment the coordinator holds against the conversation this opens.
    public var attachment: AttachedContext {
        AttachedContext(body: promptText, title: title, starters: suggestedQuestions)
    }

    /// A filesystem-ish slug for the subject half of `scopeKey` — lowercase, spaces and
    /// punctuation collapsed to hyphens, bounded in length so a long food name or a long
    /// commit title cannot make the key unwieldy. Identity only; never displayed.
    public static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true)
        return collapsed.joined(separator: "-").prefix(48).description
    }
}
