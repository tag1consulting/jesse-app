import Foundation
import JesseAsk
import JesseCore

// The HEALTH TAB's half of "Ask about this": which part of the tab an ask came from, how a
// diet reading's time range reads, and the domain that carries the tab's frozen prompt.
//
// Everything screen-agnostic — the facts tree, the budget and its clamp, the scope, the
// context and its identity, the gesture and the toolbar entry — lives in `JesseAsk` and is
// shared with the Ops screen. What stayed here is exactly what knows what a meal is:
// `AskFacts+Build.swift` serializes each unit, `AskContext+Areas.swift`
// composes the scopes, and `HealthAskPrompt` (in JesseCore, beside the other frozen turn
// texts) is the sentence they are wrapped in.

// MARK: - The domain

public extension AskDomain {
    /// The Health tab. `health` is the first segment of every Health `scopeKey`, which is
    /// what keeps it from ever colliding with an Ops one, and the prompt is the frozen
    /// `HealthAskPrompt` — a peer of the Ops prompt, not a parameterisation of it.
    static let health = AskDomain(key: "health", label: "Health") { title, scope, range, snapshot in
        HealthAskPrompt.prompt(title: title, scope: scope, range: range, snapshot: snapshot)
    }
}

// MARK: - Area

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

// MARK: - Range

extension AskTimeRange {
    /// One calendar day. Today reads as "today"; any other day reads as its own date, so
    /// a paged-back reading can never be mistaken for the live one.
    static func day(_ iso: String, isToday: Bool) -> AskTimeRange {
        AskTimeRange(label: isToday ? "today (\(iso))" : HealthDisplay.headerDate(iso),
                     key: "d:\(iso)")
    }

    /// A trailing window of days, anchored on the day being read.
    static func trailing(days: Int, through anchor: String) -> AskTimeRange {
        AskTimeRange(label: "the last \(days) days", key: "w\(days):\(anchor)")
    }

    /// Every day the series carries — the "All" range on a chart.
    static func all(through anchor: String) -> AskTimeRange {
        AskTimeRange(label: "the full logged history", key: "all:\(anchor)")
    }
}

// MARK: - The Health-tab context

extension AskContext {
    /// Build a Health-tab context. Every one of the forty-odd scope factories in
    /// `HealthAsk+Areas.swift` goes through here, so `domain: .health` is stated ONCE and
    /// the area arrives as this tab's own enum rather than as a bare string a typo could
    /// silently repoint at another screen's namespace.
    init(scope: AskScope, area: HealthAskArea, timeRange: AskTimeRange,
         title: String, subject: String, subjectKey: String = "",
         facts: AskFacts, related: [String] = [],
         suggestedQuestions: [String] = []) {
        self.init(domain: .health, scope: scope, area: area.rawValue, timeRange: timeRange,
                  title: title, subject: subject, subjectKey: subjectKey,
                  facts: facts, related: related, suggestedQuestions: suggestedQuestions)
    }
}
