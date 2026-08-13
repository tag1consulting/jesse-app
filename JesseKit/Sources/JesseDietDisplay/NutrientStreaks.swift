import Foundation
import JesseNetworking

// Consistency, as pure Foundation-only logic — no SwiftUI, no `Date()` read, every rule
// deterministically testable. A window's median says how a nutrient sits on a typical
// day; a streak says whether it is being held, which is the question a median structurally
// cannot answer (four good days and three bad ones median out the same as seven middling
// ones).
//
// THE GAP RULE, and it is the whole reason this file is careful: a day the nutrient was not
// measured is a GAP. It does not BREAK a streak — you may well have hit the goal, the label
// just didn't say — and it does not EXTEND one either, because a day nobody measured is not
// a day you can claim. Same doctrine as everywhere else in the stack: unknown is not zero,
// and unknown is not a miss.
//
// A PARTIAL day (some items measured, some not) is a lower bound, so it is only allowed to
// decide the direction its lower bound already PROVES: a floor already cleared is a real
// hit, a ceiling already breached is a real miss, and every other partial day is undecided
// and behaves exactly like a gap. This mirrors `NutrientTrends.dayStatus`, which colours a
// plotted day under the same rule.

// MARK: - One day's verdict

/// What one KNOWN day did to a streak. `undecided` is the partial day whose unknowns could
/// still overturn the reading — treated exactly like a gap, so it neither breaks nor
/// extends.
enum StreakDayOutcome: Equatable, Sendable {
    case met
    case missed
    case undecided
}

// MARK: - One nutrient's streaks

/// One nutrient's consistency over the whole series. Every count is over KNOWN days;
/// `coverageNote` states how many that was, so a streak built on four measured days out of
/// forty is never read as a forty-day fact.
struct NutrientStreak: Equatable, Sendable, Identifiable {
    let nutrient: TrendNutrient
    /// Consecutive most-recent DECIDED days that met the goal. Gaps and undecided partial
    /// days are skipped over, not counted.
    let current: Int
    /// The longest such run anywhere in the series.
    let longest: Int
    /// The date of the most recent decided MISS, or nil when there is none among the known
    /// days (which is not the same as "never missed" — say so with the coverage note).
    let lastMissDate: String?
    /// Calendar days from that miss to the most recent LOGGED day in the series — the plain
    /// "days since the last miss". Nil when there is no miss to measure from.
    let calendarDaysSinceLastMiss: Int?
    /// KNOWN days since that miss — the honest companion to the calendar count, because the
    /// calendar span may contain days nobody measured.
    let knownDaysSinceLastMiss: Int?
    /// Days this nutrient carried a known value anywhere in the series.
    let daysKnown: Int
    /// Of those, how many produced a decided verdict (the rest were undecided partials).
    let daysJudged: Int
    /// Logged days in the whole series — the coverage denominator.
    let daysLogged: Int

    var id: String { nutrient.rawValue }

    /// At least one decided day to speak to. A nutrient with none carries no streak at all.
    var hasData: Bool { daysJudged > 0 }

    /// The streak rests on thin ground: too few decided days to assert a pattern, or decided
    /// on well under half the logged days. The row says so rather than dressing four days up
    /// as consistency.
    var isSparse: Bool {
        guard daysJudged > 0 else { return true }
        if daysJudged < NutrientTrends.minKnownForDirection { return true }
        guard daysLogged > 0 else { return true }
        return Double(daysJudged) / Double(daysLogged) < NutrientTrends.thinCoverageFraction
    }

    /// How much ground the numbers above actually stand on, stated on every row.
    var coverageNote: String {
        guard daysJudged > 0 else {
            return daysLogged > 0
                ? "not measured on any of the \(daysLogged) logged days yet"
                : "nothing logged yet"
        }
        let base = "over \(daysJudged) measured \(daysJudged == 1 ? "day" : "days") of \(daysLogged) logged"
        return isSparse ? base + " — thin coverage, read it as a hint" : base
    }

    /// The plain-language "days since the last miss" line, or the honest alternative when no
    /// known day missed. Never claims a clean run longer than the measurements support.
    var lastMissLine: String {
        guard let lastMissDate else {
            guard daysJudged > 0 else { return "no measured days yet" }
            return "no miss in the \(daysJudged) measured \(daysJudged == 1 ? "day" : "days")"
        }
        // The miss IS the most recent logged day — "0 days since the last miss" is a true
        // but useless sentence, so say what actually happened instead.
        guard let days = calendarDaysSinceLastMiss, days > 0 else {
            return "missed on the most recent logged day (\(lastMissDate))"
        }
        let known = knownDaysSinceLastMiss ?? 0
        return "\(days) \(days == 1 ? "day" : "days") since the last miss (\(lastMissDate)"
            + ", \(known) measured \(known == 1 ? "day" : "days") since)"
    }
}

// MARK: - Engine

enum NutrientStreaks {
    /// The gap rule, stated once wherever streaks are shown. Not decoration — a streak
    /// counted over known days is a different claim from a streak counted over calendar
    /// days, and the screen has to say which one it is making.
    static let gapRule =
        "A day a nutrient wasn't measured doesn't break a streak, but it doesn't extend one "
        + "either. Every count below is over the days that were actually measured."

    /// The whole gate for the Consistency section: a series the bridge actually sent, with
    /// at least one day in it. An older bridge (no `nutrientSeries`) hides the section
    /// rather than crashing or inventing an empty one.
    static func isAvailable(_ series: [NutrientDay]?) -> Bool {
        NutrientTrends.isAvailable(series)
    }

    /// The nutrients consistency is computed for: every nutrient that carries a VERDICT —
    /// the floors and the ceilings (plus total fat's window). The two informational
    /// nutrients (total sugars, unsaturated fat) have no goal to hold, so they have no
    /// streak, in this section or anywhere else.
    static var judgedNutrients: [TrendNutrient] {
        TrendNutrient.allCases.filter { $0.dayGoal != nil }
    }

    /// What one KNOWN day did to the streak, under the nutrient's own day goal and the SAME
    /// band helpers the gauges use. A partial day only decides the direction its lower bound
    /// already proves; everything else is `undecided` and behaves like a gap.
    static func outcome(_ nutrient: TrendNutrient, value: Double, isPartial: Bool,
                        target: Double?) -> StreakDayOutcome {
        guard let goal = nutrient.dayGoal else { return .undecided }
        switch goal {
        case .floor:
            guard let target, target > 0 else { return .undecided }
            if value >= target { return .met }
            // Below the floor on the KNOWN items alone — the unmeasured ones could still
            // carry it over, so a partial day makes no claim.
            return isPartial ? .undecided : .missed
        case .ceiling:
            guard let target, target > 0 else { return .undecided }
            if value > target { return .missed }
            // Under the ceiling on the known items alone proves nothing on a partial day:
            // the unmeasured ones can only push it up.
            return isPartial ? .undecided : .met
        case .window:
            // Total fat's fixed 50–65 g window with its 70 g hard cap — the same band the
            // daily fat gauge uses. A partial day is only PROVEN bad once the known-only
            // floor already clears the hard cap; below that, the unknowns leave it open.
            if isPartial { return value > DietSemantics.fatHardCap ? .missed : .undecided }
            return DietSemantics.fatWindowGoalStatus(grams: value).isMet ? .met : .missed
        case .band:
            // Unreachable today (no nutrient answers `.band` from `dayGoal`) and left
            // deliberately undecided rather than guessed: a band needs BOTH edges, and
            // `nutrientSeries` carries one target number per nutrient per day.
            return .undecided
        }
    }

    /// One nutrient's decided days, ascending, as `(date, outcome)` — gap days absent (the
    /// nutrient key is not in the day's map) and undecided partial days dropped, which is
    /// precisely what makes them neither break nor extend a run.
    static func decidedDays(_ nutrient: TrendNutrient, series: [NutrientDay],
                            targets: DietTargets) -> [(date: String, outcome: StreakDayOutcome)] {
        let target = nutrient.target(in: targets)
        return NutrientTrends.sorted(series).compactMap { day in
            guard let v = day.nutrients[nutrient.key], v.known >= 1 else { return nil }
            let o = outcome(nutrient, value: v.sum, isPartial: v.unknown > 0, target: target)
            return o == .undecided ? nil : (day.date, o)
        }
    }

    /// ONE nutrient's streaks over the whole series. A nutrient with no decided day comes
    /// back zeroed, with a coverage note that says why — never a phantom streak of 0 that
    /// reads like a broken run.
    static func streak(_ nutrient: TrendNutrient, series: [NutrientDay],
                       targets: DietTargets) -> NutrientStreak {
        let ordered = NutrientTrends.sorted(series)
        let daysKnown = ordered.filter { ($0.nutrients[nutrient.key]?.known ?? 0) >= 1 }.count
        let decided = decidedDays(nutrient, series: series, targets: targets)

        var current = 0
        for entry in decided.reversed() {
            guard entry.outcome == .met else { break }
            current += 1
        }
        var longest = 0, run = 0
        for entry in decided {
            if entry.outcome == .met { run += 1; longest = max(longest, run) } else { run = 0 }
        }

        // The most recent decided miss, and how far back it sits — in calendar days from the
        // last LOGGED day (the plain reading) and in measured days (the honest one).
        var lastMissDate: String?
        var calendarSince: Int?
        var knownSince: Int?
        if let missIndex = decided.lastIndex(where: { $0.outcome == .missed }) {
            lastMissDate = decided[missIndex].date
            knownSince = decided.count - 1 - missIndex
            if let missDate = NutrientTrends.dayParser.date(from: decided[missIndex].date),
               let lastLogged = ordered.last.flatMap({ NutrientTrends.dayParser.date(from: $0.date) }) {
                calendarSince = utcCalendar.dateComponents([.day], from: missDate, to: lastLogged).day
            }
        }

        return NutrientStreak(
            nutrient: nutrient, current: current, longest: longest,
            lastMissDate: lastMissDate, calendarDaysSinceLastMiss: calendarSince,
            knownDaysSinceLastMiss: knownSince, daysKnown: daysKnown,
            daysJudged: decided.count, daysLogged: ordered.count)
    }

    /// Every judged nutrient that has at least one decided day, in canonical order, ranked
    /// by the current streak (longest first) so what is being held reads before what isn't.
    /// A nutrient never measured simply isn't in the list.
    static func all(series: [NutrientDay], targets: DietTargets) -> [NutrientStreak] {
        judgedNutrients
            .map { streak($0, series: series, targets: targets) }
            .filter(\.hasData)
            .enumerated()
            .sorted { a, b in
                a.element.current != b.element.current
                    ? a.element.current > b.element.current : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The Consistency nav row's subtitle: the strongest active streak, or an honest
    /// "nothing running" when none is. Nil when there is nothing to show at all, so the
    /// row can hide.
    static func subtitle(_ streaks: [NutrientStreak]) -> String? {
        guard let best = streaks.first, best.hasData else { return nil }
        guard best.current > 0 else {
            return "no active streak — \(streaks.count) \(streaks.count == 1 ? "nutrient" : "nutrients") tracked"
        }
        return "\(best.nutrient.fullName) \(best.current) \(best.current == 1 ? "day" : "days")"
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
