import Foundation
import JesseCore

// "Ask about this" — the context model behind the Health tab's long-press / right-click.
//
// The whole feature is ONE idea: a gesture on anything the Health tab draws opens the
// app's existing chat already knowing exactly what was being looked at. This file holds
// the shape of "exactly what was being looked at"; `HealthAskSerializers.swift` builds
// one from each area's data; `HealthAskable.swift` attaches the gesture; the two app
// shells own the presentation. No new chat, no new UI, no new chrome.
//
// THE SNAPSHOT IS WHAT THE SCREEN SHOWS, not a re-query. Every serializer is handed the
// values the view already holds and serializes those. A second read of the same day
// through a different code path would eventually disagree with the pixels, and a chat
// that contradicts the screen it was opened from is worse than no chat at all.
//
// COMPOSITION, NOT THREE SERIALIZERS PER AREA. A `HealthAskFacts` is a small tree: a
// heading, some lines, some child blocks. An item is a leaf, a section is its items'
// blocks under one heading, a page is its sections'. So each unit is serialized ONCE and
// the wider scopes are unions of the narrower ones — which is also what guarantees the
// three scopes can never tell three different stories about the same number.

// MARK: - Scope, area, range

/// How much of the screen an ask covers. The three levels the gesture offers, and the
/// word the prompt uses to describe the reading.
public enum HealthAskScope: String, Equatable, Sendable, CaseIterable {
    /// A whole page or sub-page, for the current time range.
    case page
    /// One section of a page — a group of rows, a card, a chart's surrounding block.
    case section
    /// A single thing: a meal, a food, a workout, a nutrient row, a trend, a pattern.
    case item

    /// The word the prompt uses ("a page-level reading"). Same as the raw value today;
    /// spelled through a property so the wire-ish raw value and the prose can diverge.
    var word: String { rawValue }
}

/// Which part of the Health tab an ask came from. EXTENSIBLE by design: a new Health
/// section adds a case here and gets the whole feature by passing it to a serializer.
public enum HealthAskArea: String, Equatable, Sendable, CaseIterable {
    case day            // the Health tab root — the dashboard as a whole
    case macros         // macros & calories, the nutrient rows
    case calories       // the calorie hero / net calories
    case foodJournal
    case exercise
    case weight         // weight card + weight & trend chart
    case progress       // progress & pace
    case coach          // coach's notes
    case sources        // which foods delivered a nutrient
    case patterns       // correlations
    case consistency    // streaks
    case trends         // a per-nutrient trend chart

    /// The area's user-facing name, matching the label the tab already uses for it.
    var label: String {
        switch self {
        case .day: return "Health"
        case .macros: return "Macros & calories"
        case .calories: return "Calories"
        case .foodJournal: return "Food journal"
        case .exercise: return "Exercise"
        case .weight: return "Weight & trend"
        case .progress: return "Progress & pace"
        case .coach: return "Coach's notes"
        case .sources: return "Sources"
        case .patterns: return "Patterns"
        case .consistency: return "Consistency"
        case .trends: return "Trends"
        }
    }
}

/// The range of time the reading covers, in the two forms it is needed in: words for the
/// prompt and the title, and a stable key for deciding whether a later ask is about the
/// SAME reading (see `HealthAskContext.scopeKey`).
public struct HealthAskTimeRange: Equatable, Sendable {
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

    /// One calendar day. Today reads as "today"; any other day reads as its own date, so
    /// a paged-back reading can never be mistaken for the live one.
    static func day(_ iso: String, isToday: Bool) -> HealthAskTimeRange {
        HealthAskTimeRange(label: isToday ? "today (\(iso))" : HealthDisplay.headerDate(iso),
                           key: "d:\(iso)")
    }

    /// A trailing window of days, anchored on the day being read.
    static func trailing(days: Int, through anchor: String) -> HealthAskTimeRange {
        HealthAskTimeRange(label: "the last \(days) days", key: "w\(days):\(anchor)")
    }

    /// Every day the series carries — the "All" range on a chart.
    static func all(through anchor: String) -> HealthAskTimeRange {
        HealthAskTimeRange(label: "the full logged history", key: "all:\(anchor)")
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
public struct HealthAskFacts: Equatable, Sendable {
    /// The block's own heading, or nil for an unlabelled group of lines.
    public var heading: String?
    /// The block's own facts, one per line, already formatted with their units.
    public var lines: [String]
    /// Nested blocks — the items inside a section, the sections inside a page.
    public var children: [HealthAskFacts]
    /// A qualification on this block: what was summarized away, what is unknown rather
    /// than zero, what a number is a floor of. Rendered last, in parentheses.
    public var note: String?

    public init(heading: String? = nil, lines: [String] = [],
                children: [HealthAskFacts] = [], note: String? = nil) {
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
/// it is how a model concludes the user ate four things today.
enum HealthAskBudget {
    /// How many rows a list inside a snapshot may carry before it is capped. Twelve is
    /// past the length of a real meal or a real day's sessions, so the cap almost never
    /// fires on an item or a section — it exists for the page-level union.
    static let maxListItems = 12

    /// How many rows a list nested two levels down (foods inside meals inside a page) may
    /// carry. Tighter, because the page multiplies it by the number of meals.
    static let maxNestedListItems = 6

    /// The hard ceiling on a rendered snapshot, in characters. Roughly three thousand
    /// tokens: comfortably inside any turn's budget while leaving the conversation itself
    /// most of the window. A snapshot that reaches this is truncated at a block boundary
    /// and says so.
    static let maxCharacters = 12_000

    /// Take the first `limit` of `items` (the caller has already ordered them by whatever
    /// "most important" means for that list) and the sentence describing what was left.
    static func cap<T>(_ items: [T], limit: Int = maxListItems,
                       noun: String, totalsCoverAll: Bool = true) -> (kept: [T], note: String?) {
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
    static func clamp(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let head = text.prefix(maxCharacters)
        let cut = head.lastIndex(of: "\n").map { String(head[head.startIndex..<$0]) } ?? String(head)
        return cut + "\n(snapshot truncated here to fit — ask for any part of it in full)"
    }
}

// MARK: - The context

/// Everything a chat needs to be opened about one thing on the Health tab.
///
/// The public surface is deliberately narrow: the app shells read `title`, `scopeKey`,
/// `promptText` and `suggestedQuestions` and nothing else. Which numbers went in, and how
/// they were rendered, stays inside this package with the views that hold them.
public struct HealthAskContext: Equatable, Sendable, Identifiable {
    public let scope: HealthAskScope
    public let area: HealthAskArea
    public let timeRange: HealthAskTimeRange
    /// The human string the chat header and the conversation list show: "Lunch · Aug 22",
    /// "Protein, last 30 days".
    public let title: String
    /// The tail of the menu wording — "this meal", "today's macros", "this trend". Set by
    /// each serializer, because only it knows what noun the thing is.
    public let subject: String
    /// The stable identity of the SUBJECT within its area and range (a meal name, a
    /// nutrient key, a food name). Part of `scopeKey`; never shown.
    let subjectKey: String
    /// The structured snapshot of exactly what is on screen for this scope.
    public let facts: HealthAskFacts
    /// Ids the chat can use to dig further — a date, a nutrient key, a meal name. Passed
    /// to the agent as a short "if you need more" line, never as a fetch instruction.
    public let related: [String]
    /// Two to four opening questions, appropriate to the scope. Offered in the chat's
    /// empty state only.
    public let suggestedQuestions: [String]

    init(scope: HealthAskScope, area: HealthAskArea, timeRange: HealthAskTimeRange,
         title: String, subject: String, subjectKey: String = "",
         facts: HealthAskFacts, related: [String] = [],
         suggestedQuestions: [String] = []) {
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

    /// The identity of this READING — area, scope, range, subject. Two asks with the same
    /// key are about the same thing, which is what "resume today's conversation about this
    /// instead of starting a new one" is decided on.
    ///
    /// The range's key carries its anchor date, so the same question asked tomorrow is a
    /// different key and gets its own conversation.
    public var scopeKey: String {
        let subject = subjectKey.isEmpty ? "-" : HealthAskContext.slug(subjectKey)
        return "health/\(area.rawValue)/\(scope.rawValue)/\(timeRange.key)/\(subject)"
    }

    /// The rendered, budget-clamped snapshot — the block the prompt fences.
    public var snapshotText: String {
        var body = facts.render()
        if !related.isEmpty {
            body += "\n\nIf you need more than this, these name it in the log: "
                + related.joined(separator: ", ")
        }
        return HealthAskBudget.clamp(body)
    }

    /// The full turn text: the frozen `HealthAskPrompt` wrapped around the snapshot.
    /// Assembled here and nowhere else, so no shell can send a differently-scoped version.
    public var promptText: String {
        HealthAskPrompt.prompt(title: title, scope: scope.word,
                               range: timeRange.label, snapshot: snapshotText)
    }

    /// The single context-menu item's wording, adapted to what was pressed.
    public var menuLabel: String { "Ask about \(subject)" }

    /// The attachment the coordinator holds against the conversation this opens.
    public var attachment: AttachedContext {
        AttachedContext(body: promptText, title: title, starters: suggestedQuestions)
    }

    /// A filesystem-ish slug for the subject half of `scopeKey` — lowercase, spaces and
    /// punctuation collapsed to hyphens, bounded in length so a long food name cannot
    /// make the key unwieldy. Identity only; never displayed.
    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true)
        return collapsed.joined(separator: "-").prefix(48).description
    }
}
