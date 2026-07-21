import Foundation

// The plain-language day summary that LEADS the Health tab: one line answering
// "how am I doing", one answering "what would help next". It's the antidote to a
// wall of gauges — a supportive coach's opening sentence, not a grade.
//
// Pure and Foundation-only (nothing here touches SwiftUI), derived entirely from the
// same `DietGauges` the rings draw and the injected hour, so the summary can never
// tell a different story than the detail below it. Generic and personal-free: it
// addresses "you", names macros by their display name, and hardcodes no personal
// target numbers. Deterministic, so it's unit-tested.

struct DaySummary: Equatable, Sendable {
    /// "How am I doing" — a short, kind read of the day so far.
    var headline: String
    /// "What would help next" — the single most useful action, phrased action-first.
    var nextAction: String
    /// The overall tone, for the summary card's accent (the same one-meaning tone the
    /// rings use).
    var tone: DietSemantics.Tone

    /// Build the summary from today's gauges and the current hour. `hasFood` is false
    /// only when nothing has been logged yet, which gets its own gentle empty state.
    static func make(gauges g: DietGauges, hour: Int, hasFood: Bool) -> DaySummary {
        let carbLoad = g.isCarbLoad

        // Nothing logged yet — a calm invitation, never a scolding blank.
        guard hasFood else {
            return DaySummary(
                headline: carbLoad ? "Carb-load day — let's get fuelling." : "Nothing logged yet today.",
                nextAction: "Log a meal and the day starts to take shape.",
                tone: .inProgress)
        }

        // The five gauges that drive the read. Fiber on a carb-load day is suspended, so
        // it contributes `.noGoal`/`.inProgress` and never a judgment.
        let all = [g.calories, g.protein, g.carbs, g.fat, g.fiber]
        let overall = overallTone(all)

        // The short floors (things still to reach), worst-first, for the "what next" line.
        let shorts = shortItems(g)
        let names = shorts.map(\.name)

        // --- What would help next (priority order) ---
        let nextAction: String
        if carbLoad, case .short = g.calories.goalStatus {
            // Under-fuelling a carb-load: the helpful direction is MORE, said plainly.
            nextAction = "You're a bit under the fuel window — lean on carbs to top off the tank."
        } else if !carbLoad, case .over = g.calories.goalStatus {
            nextAction = g.calories.tone == .takeNote
                ? "You're well over on calories — worth easing back the rest of the evening."
                : "A little over on calories — easy to ease back tomorrow."
        } else if carbLoad, case .over = g.fat.goalStatus {
            nextAction = "A bit high on fat — ease back to leave calorie room for carbs."
        } else if !names.isEmpty {
            if hour < DietSemantics.nagHour && overall != .nudge && overall != .takeNote {
                // Early: an unfinished floor is normal, not a task.
                nextAction = "Nothing needed yet — eat when you're hungry; there's plenty of room to fuel training."
            } else {
                nextAction = "To round out the day: \(actionPhrase(names)) this evening."
            }
        } else {
            nextAction = carbLoad ? "Well fuelled — carry on." : "Nicely balanced — carry on."
        }

        // --- How am I doing ---
        let headline: String
        switch overall {
        case .takeNote:
            headline = "Worth a quick look."
        case .nudge:
            headline = carbLoad ? "Carb-load day — keep the fuel coming." : "Solid day."
        case .onTrack:
            headline = carbLoad ? "Carb-load day — nicely fuelled." : "You're on track today."
        case .inProgress:
            headline = carbLoad ? "Carb-load day — just getting going." : "Good start — the day's just getting going."
        }

        return DaySummary(headline: headline, nextAction: nextAction, tone: overall)
    }

    // MARK: - Helpers

    /// The overall tone: the most attention-worthy present, but "on track" only when every
    /// judged metric is either good or making no claim (suspended / no target) — a day with
    /// floors still filling early reads as `inProgress`, not a premature "on track".
    private static func overallTone(_ gauges: [MetricGauge]) -> DietSemantics.Tone {
        if gauges.contains(where: { $0.tone == .takeNote }) { return .takeNote }
        if gauges.contains(where: { $0.tone == .nudge }) { return .nudge }
        let allSettled = gauges.allSatisfy { $0.tone == .onTrack || $0.goalStatus == .noGoal }
        return allSettled ? .onTrack : .inProgress
    }

    /// A named, ranked list of the floors still short of their mark (worst-first by
    /// fraction of the goal remaining), for the "what would help next" line. Includes fat
    /// on a normal day when it's below its 50g floor. Excludes anything met, suspended, or
    /// over.
    private struct ShortItem { let name: String; let fraction: Double }
    private static func shortItems(_ g: DietGauges) -> [(name: String, fraction: Double)] {
        var out: [ShortItem] = []
        // A floor that's already "basically there" (onTrack tone) is not something to round
        // out — only genuinely-short floors get named.
        func addFloor(_ gauge: MetricGauge, base: Double) {
            if case .short(let by) = gauge.goalStatus, base > 0, gauge.tone != .onTrack {
                out.append(ShortItem(name: gauge.label.lowercased(), fraction: by / base))
            }
        }
        addFloor(g.protein, base: g.protein.target ?? 0)
        addFloor(g.carbs, base: g.carbs.target ?? 0)
        // Fat is a floor concern only on a normal day (below the 50g hormonal floor).
        if !g.isCarbLoad, case .short(let by) = g.fat.goalStatus, g.fat.tone != .onTrack {
            out.append(ShortItem(name: "fat", fraction: by / DietSemantics.fatFloor))
        }
        // Fiber only when it's actually judged (not suspended on a carb-load day).
        if g.fiber.goalStatus != .noGoal { addFloor(g.fiber, base: g.fiber.target ?? 0) }

        return out.sorted { $0.fraction > $1.fraction }.map { ($0.name, $0.fraction) }
    }

    /// "some protein and some fiber" — the top two short floors, kindly phrased. One item
    /// reads "a little more protein"; three or more are trimmed to the two that help most.
    private static func actionPhrase(_ names: [String]) -> String {
        switch names.count {
        case 0: return "a little more"
        case 1: return "a little more \(names[0])"
        default: return "some \(names[0]) and some \(names[1])"
        }
    }
}
