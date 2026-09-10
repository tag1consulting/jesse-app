import Foundation
import JesseAsk
import JesseCore

// The OPS SCREEN's half of "Ask about this": which part of the screen an ask came from,
// when the reading was taken, and the domain that carries the screen's frozen prompt.
//
// Everything screen-agnostic — the facts tree, the budget and its clamp, the scope, the
// context and its identity, the gesture and the toolbar entry — lives in `JesseAsk` and is
// shared with the Health tab. What lives here is exactly what knows what a launchd job is:
// `OpsAskFacts.swift` serializes each unit, `OpsAskContext.swift` composes the scopes, and
// `OpsAskPrompt` (in JesseCore, beside the other frozen turn texts) is the sentence they
// are wrapped in.
//
// THE TWO QUESTIONS THIS EXISTS TO ANSWER, and they are worth writing down because they
// decide what each serializer must carry:
//
//   * "What would a deploy bring in?" — pressed on the Deploy card or a release block. So
//     the deploy serializer carries EVERY undeployed release including the ones the view
//     folded away, plus the count the sentinel truncated out of the document entirely.
//   * "What version of X is running?" — pressed on the Bridge card, a service row or the
//     Deploy card. So both halves ride along: what is up, and what `origin/main` says,
//     with the shas to dig with.

// MARK: - The domain

public extension AskDomain {
    /// The Ops screen. `ops` is the first segment of every Ops `scopeKey`, which is what
    /// keeps it from ever colliding with a Health one, and the prompt is the frozen
    /// `OpsAskPrompt` — a peer of the Health prompt, not a parameterisation of it.
    static let ops = AskDomain(key: "ops", label: "Ops") { title, scope, range, snapshot in
        OpsAskPrompt.prompt(title: title, scope: scope, range: range, snapshot: snapshot)
    }
}

// MARK: - Area

/// Which part of the Ops screen an ask came from. EXTENSIBLE by design: a new card adds a
/// case here and gets the whole feature by passing it to a serializer.
public enum OpsAskArea: String, Equatable, Sendable, CaseIterable {
    case ops        // the Bridge ops screen as a whole
    case bridge
    case services   // the launchd probe and its rows
    case tailscale
    case disk
    case git
    case qmd
    case watchdog
    case ledger
    case actions
    case deploy
    case schedule   // the Schedule sub-page, its chains and its rows
    case away       // the Away mode sub-page

    /// The area's user-facing name, matching the section header the screen already uses.
    var label: String {
        switch self {
        case .ops: return "Bridge ops"
        case .bridge: return "Bridge"
        case .services: return "Services"
        case .tailscale: return "Tailscale"
        case .disk: return "Disk"
        case .git: return "Git"
        case .qmd: return "QMD"
        case .watchdog: return "Watchdog"
        case .ledger: return "Ledger"
        case .actions: return "Actions"
        case .deploy: return "Deploy"
        case .schedule: return "Schedule"
        case .away: return "Away mode"
        }
    }
}

// MARK: - The reading

/// WHEN an Ops reading was taken, in the two forms `AskTimeRange` needs.
///
/// The Health tab's equivalent is a DAY, because a diet reading is a day's worth of
/// numbers. An Ops reading is a MOMENT: every card on it can change minute to minute, so
/// the label says what time it was taken and the identity is the device's calendar day.
///
/// That split is deliberate. The identity has to be coarse enough that two presses on the
/// same card an hour apart land in ONE conversation — a second thread per glance would be
/// useless — and fine enough that a press tomorrow starts a fresh one rather than resuming
/// a conversation about yesterday's machine. The day is that grain, and it matches what
/// the openers already enforce: a resumable conversation must have been created today.
///
/// A resumed conversation is re-attached with a FRESH snapshot before its next send, which
/// is what keeps a minute-to-minute reading honest inside a conversation that outlives it.
public struct OpsAskReading: Equatable, Sendable {
    /// When the app rendered the reading being asked about.
    public let taken: Date
    /// The zone the reading is described in — the DEVICE's, because the person reading it
    /// is holding the device. The bridge's own zone rides inside the cards that have one.
    public let zone: TimeZone

    public init(taken: Date = Date(), zone: TimeZone = .current) {
        self.taken = taken
        self.zone = zone
    }

    /// "the reading on screen, taken at Thu 10 Sep, 14:32" — and the device day as the key.
    public var range: AskTimeRange {
        AskTimeRange(label: "the reading on screen, taken at \(OpsFormat.dayAndTime(taken, in: zone))",
                     key: "at:\(Self.dayKey(taken, in: zone))")
    }

    /// `yyyy-MM-dd` in `zone`. Spelled with a fixed-format formatter rather than
    /// `OpsFormat.dayAndTime`, which is localized: this string is an IDENTITY, and a key
    /// that changed with the device's locale would silently stop resuming.
    static func dayKey(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Starters

/// The two-to-four opening questions each scope offers.
///
/// They are SUGGESTIONS, not a menu: the chat is the ordinary one and the question can be
/// anything. They exist because an empty composer under a page of probe output is a worse
/// prompt than three concrete questions, and because they teach what the scope can answer.
/// The deploy ones are the brief's own two questions, spelled as they would be asked.
enum OpsAskStarters {
    static let page = ["Is anything wrong here?",
                       "What would a deploy bring in?",
                       "What is running, and what is on origin/main?"]
    static let bridge = ["What version is this, and is it current?",
                         "Is this latency normal?",
                         "What does the drift count mean?"]
    static let services = ["Is any of these unhealthy?",
                           "What does this job do?",
                           "Should I restart anything?"]
    static let service = ["What does this job do?",
                          "Is this state normal for it?",
                          "What would restarting it cost?"]
    static let deploy = ["What would this deploy bring in?",
                         "What is running against origin/main?",
                         "Is it safe to press Deploy?"]
    static let release = ["What did this release change?",
                          "Does this affect the app or just the bridge?",
                          "Is there anything risky in it?"]
    static let deployProgress = ["What phase is this and what is left?",
                                 "Does this log tail look healthy?",
                                 "What happens if it fails?"]
    static let disk = ["Is there enough room here?",
                       "What is taking up the artifact space?",
                       "Is pruning worth it?"]
    static let git = ["Is the vault in a good state?",
                      "What does this ahead/behind mean?",
                      "Do I need to do anything about this?"]
    static let watchdog = ["Is the watchdog healthy?",
                           "What do these kickstarts mean?",
                           "Should I be worried?"]
    static let ledger = ["Did everything run last night?",
                         "What failed, and why?",
                         "Which of these matters?"]
    static let ledgerRow = ["What is this job, and what does this outcome mean?",
                            "Why would it have ended this way?",
                            "Does this need fixing?"]
    static let generic = ["What is this telling me?",
                          "Is anything wrong here?",
                          "What would you look at next?"]
    static let schedule = ["Did everything run when it should have?",
                           "Which jobs are off, and why?",
                           "What is due next?"]
    static let scheduleRow = ["What does this job do?",
                              "Why did it last end this way?",
                              "When does it run next?"]
    static let away = ["What is this profile doing to my dates?",
                       "Is an away period in force?",
                       "What happens when I come home?"]
}

// MARK: - The Ops context

extension AskContext {
    /// Build an Ops context. Every one of the scope factories in `OpsAskContext.swift`
    /// goes through here, so `domain: .ops` is stated ONCE and the area arrives as this
    /// screen's own enum rather than as a bare string a typo could silently repoint at
    /// another screen's namespace.
    init(scope: AskScope, area: OpsAskArea, reading: OpsAskReading,
         title: String, subject: String, subjectKey: String = "",
         facts: AskFacts, related: [String] = [],
         suggestedQuestions: [String] = OpsAskStarters.generic) {
        self.init(domain: .ops, scope: scope, area: area.rawValue, timeRange: reading.range,
                  title: title, subject: subject, subjectKey: subjectKey,
                  facts: facts, related: related, suggestedQuestions: suggestedQuestions)
    }
}
