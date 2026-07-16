import Foundation

// The on-device health-insight seam (framework-agnostic half). Kept Foundation-only
// and free of any model import so the view layer, the tests, and the prompt builder
// never pull in FoundationModels — mirroring how `QueryExpanding` isolates the query
// expander from its `FoundationModelExpander` conformer.
//
// A `HealthInsightGenerating` turns a grounded set of on-screen facts into a short
// natural-language insight, STREAMED as cumulative snapshots (each element is the
// full text so far). It is deliberately TOTAL: it NEVER throws and NEVER surfaces an
// error. When the on-device model is unavailable, disabled, not yet downloaded, or a
// call fails, it yields an EMPTY stream — the facts stand alone with no error noise
// and no placeholder. The consumer treats "no insight" and "model isn't here"
// identically.

/// The grounded facts an insight is written from — built purely from the numbers
/// already on screen, so the model has nothing to invent. Foundation-only and
/// Equatable so it can ride on an `Explainer` and be asserted in tests.
struct HealthInsightInput: Equatable, Sendable {
    /// The metric's display name ("Carbs", "Calories").
    let metricLabel: String
    /// The unit the total and food values are in ("g" or "cal").
    let unit: String
    /// The day total (consumed so far) for the metric — the headline being drilled into.
    let total: Double
    /// The metric's target, or nil when there's no usable one (then no goal claim is
    /// grounded).
    let goal: Double?
    /// The deterministic goal outcome, computed in code (never by the model). This is
    /// the ground truth the prompt hands over and the guard enforces — the model may
    /// NOT assert the goal was hit unless this is `.met`.
    let goalStatus: DietSemantics.GoalStatus
    /// How the metric is judged, in plain words ("a floor to hit or beat").
    let goalPhrase: String
    /// The day's style, in plain words ("carb-load day", "ordinary day").
    let dayStyle: String
    /// The top contributing foods, most impact first — the only foods/numbers the
    /// model is allowed to mention.
    let foods: [FoodFact]
    /// Micronutrient partiality: true when at least one logged item carries NO value
    /// for this nutrient, so `total` is a FLOOR (a known sum), not a complete total.
    /// The prompt hands this over as an explicit fact and the guard discards any
    /// generation that claims the total is complete. Always false for a macro/calorie.
    let partial: Bool
    /// How many items carried a value (fed `total`) and how many did not — the counts
    /// behind the "N items not estimated" caption. Both 0 for a macro/calorie.
    let knownItemCount: Int
    let unknownItemCount: Int
    /// Informational-only metric (total sugars): grounded with composition and top
    /// contributors, NEVER a judgment. The prompt forbids over/too-much language and the
    /// guard discards a generation that renders one. Always false for a macro/calorie.
    let informational: Bool

    // Defaulted memberwise init so a macro/calorie caller (and existing tests) build an
    // input without naming the micronutrient-only fields; a micronutrient caller sets them.
    init(metricLabel: String, unit: String, total: Double, goal: Double?,
         goalStatus: DietSemantics.GoalStatus, goalPhrase: String, dayStyle: String,
         foods: [FoodFact], partial: Bool = false, knownItemCount: Int = 0,
         unknownItemCount: Int = 0, informational: Bool = false) {
        self.metricLabel = metricLabel; self.unit = unit; self.total = total
        self.goal = goal; self.goalStatus = goalStatus; self.goalPhrase = goalPhrase
        self.dayStyle = dayStyle; self.foods = foods; self.partial = partial
        self.knownItemCount = knownItemCount; self.unknownItemCount = unknownItemCount
        self.informational = informational
    }

    /// The authoritative goal-status fact fed to the model — a single ground-truth line
    /// derived from the deterministic `goalStatus`, so the model states the goal exactly
    /// as computed and never guesses. Numbers are rounded the same way the screen rounds.
    var goalStatusFact: String {
        switch goalStatus {
        case .met:
            return "MET — the goal is satisfied."
        case .short(let by):
            return "NOT met — still \(DietSemantics.fmt(by))\(unit) short of the goal."
        case .over(let by):
            return "OVER — \(DietSemantics.fmt(by))\(unit) past the limit."
        case .noGoal:
            return "no target is set for this metric — do not state any goal status."
        }
    }

    /// The authoritative partiality fact fed to the model: whether the total is complete
    /// or a floor with items not estimated. Nil for a complete total (a macro/calorie,
    /// or a micronutrient where every item carried the value), so the prompt adds no
    /// partiality line at all.
    var partialFact: String? {
        guard partial else { return nil }
        let items = "\(unknownItemCount) of \(knownItemCount + unknownItemCount) logged item\(unknownItemCount + knownItemCount == 1 ? "" : "s")"
        return "This total is PARTIAL — \(items) carry no measured \(metricLabel.lowercased()) value, so \(DietSemantics.fmt(total)) \(unit) is a floor (AT LEAST this much), never the complete total. Never state or imply it is the full/complete/entire total; if you name the number, say \"at least\"."
    }
}

/// One grounding fact: a food, its rounded contribution, and its share of the day's
/// total for the metric.
struct FoodFact: Equatable, Sendable {
    let name: String
    let value: Double
    let sharePct: Int
}

// Under the project's MainActor-default isolation this protocol (and its conformers)
// are main-actor-isolated; `insight` returns synchronously and does its work in a
// detached stream task, so it never blocks the caller and the facts never wait on it.
protocol HealthInsightGenerating {
    /// A short, grounded insight about the metric, streamed as cumulative snapshots
    /// (each element is the full text so far). Yields an empty stream — no elements,
    /// immediate finish — when the model is unavailable or the call fails. Never throws.
    func insight(for input: HealthInsightInput) -> AsyncStream<String>
}

enum HealthInsight {
    /// The app's live on-device insight generator. Behind this factory so the view
    /// layer names the seam, not the concrete FoundationModels conformer (which is the
    /// only type that imports the model framework).
    @MainActor static func live() -> HealthInsightGenerating { FoundationHealthInsight.shared }

    /// The number of top foods handed to the model — enough to ground a one-or-two
    /// sentence insight without burying it.
    static let groundingFoodCount = 4

    /// Build the grounded input for a metric's drill-down from the ranked foods and
    /// the live gauge context. Pure, so the grounding is testable without the model.
    /// `goal` and `goalStatus` are the deterministic target and outcome (from the same
    /// gauge the title shows), so the insight is fed a computed status rather than left
    /// to infer one.
    static func input(metric: ContributionMetric, total: Double, goal: Double?,
                      goalStatus: DietSemantics.GoalStatus, goalPhrase: String,
                      dayStyle: String,
                      contributions: [FoodContribution],
                      partial: Bool = false, knownItemCount: Int = 0,
                      unknownItemCount: Int = 0, informational: Bool = false) -> HealthInsightInput {
        let foods = contributions.prefix(groundingFoodCount).map {
            FoodFact(name: $0.name, value: $0.value, sharePct: Int(($0.share * 100).rounded()))
        }
        return HealthInsightInput(
            metricLabel: metric.label, unit: metric.unit, total: total,
            goal: goal, goalStatus: goalStatus, goalPhrase: goalPhrase,
            dayStyle: dayStyle, foods: Array(foods),
            partial: partial, knownItemCount: knownItemCount,
            unknownItemCount: unknownItemCount, informational: informational)
    }

    /// How a metric is judged, in plain words for the insight grounding — the shared
    /// source both drill-down entry points use, so the Today rings and the Macros
    /// screen ground the model identically.
    static func goalPhrase(_ goal: DietSemantics.Goal) -> String {
        switch goal {
        case .floor: return "a floor to hit or beat"
        case .ceiling: return "a ceiling to stay under"
        case .window: return "a target window"
        }
    }
}

/// Builds the grounded prompt handed to the on-device model. Pure and unit-tested:
/// it names only the foods and numbers in the input and instructs the model to
/// invent nothing, which is the guard against hallucinated foods or figures.
enum HealthInsightPrompt {
    static func make(_ input: HealthInsightInput) -> String {
        let metric = input.metricLabel.lowercased()
        let foodLines: String
        if input.foods.isEmpty {
            foodLines = "- (none logged)"
        } else {
            foodLines = input.foods.map {
                "- \($0.name): \(DietSemantics.fmt($0.value)) \(input.unit) (\($0.sharePct)% of the day's \(metric))"
            }.joined(separator: "\n")
        }
        let goalLine = input.goal.map { "Target: \(DietSemantics.fmt($0)) \(input.unit)." }
            ?? "Target: none set."
        // An authoritative partiality line, present only when the total is a floor, so
        // the model states "at least" and never claims completeness.
        let partialLine = input.partialFact.map { "\nPARTIALITY (authoritative): \($0)" } ?? ""
        // For an informational metric (total sugars) the closing instruction forbids
        // any judgment — composition and top contributors only.
        let judgmentRule = input.informational
            ? "This metric is INFORMATIONAL ONLY: describe composition and the top contributors, and NEVER judge the amount — no \"over\", \"too much\", \"too high\", \"excessive\", \"cut back\", \"reduce\", or any good/bad language about the quantity."
            : "State the goal status EXACTLY as given above: never say they hit, met, reached, or are on track to hit their goal or target unless the GOAL STATUS line says MET."
        let completenessRule = input.partial
            ? " Never call this the full, complete, or total amount — it is a floor; say \"at least\" if you cite the number."
            : ""
        return """
        Day type: \(input.dayStyle).
        Metric: \(input.metricLabel) — \(input.goalPhrase).
        Consumed so far: \(DietSemantics.fmt(input.total)) \(input.unit). \(goalLine)
        GOAL STATUS (authoritative — treat this as ground truth and never contradict \
        it): \(input.goalStatusFact)\(partialLine)
        Top contributing foods:
        \(foodLines)

        In one or two short sentences, tell the user something useful about their \
        \(metric) for the day. \(judgmentRule)\(completenessRule) Use ONLY the foods and \
        numbers listed above — do not invent foods, amounts, or targets. Second person, \
        plain text, no lists, no markdown.
        """
    }
}

/// The deterministic backstop for the goal-status bug: even with the ground-truth
/// facts in the prompt, a free-text model can still assert the goal was hit. This
/// scans a generated insight for a goal-completion claim that the computed
/// `GoalStatus` contradicts; when it does, the caller discards the insight and lets
/// the facts stand alone (a wrong insight is worse than none).
enum HealthInsightGuard {
    /// Words that negate a nearby completion claim — so "you have NOT met your goal"
    /// (a correct not-met insight) is never mistaken for "you met your goal". Checked
    /// in the short window of text before the claim.
    private static let negators = [
        " not ", "n't ", " never ", " without ", " no ", " short of", " far from",
        " yet to ", " below ", " under ", " haven ", " hasn ",
    ]

    /// Whether `text` AFFIRMATIVELY asserts the goal/target was reached. Case- and
    /// apostrophe-insensitive, and negation-aware — a claim preceded by a negator in
    /// the same clause is not a completion claim. Tuned for precision: a false positive
    /// only costs one insight, which the feature is designed to drop silently.
    static func claimsGoalReached(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let patterns = [
            #"\byou'?ve\s+(already\s+)?(hit|met|reached|achieved|nailed|smashed|crushed)\b"#,
            #"\b(hit|met|reached|achieved|nailed|smashed|crushed)(\s+\w+){0,4}\s+(goal|target)\b"#,
            #"\bon\s+track\s+to\s+(hit|meet|reach)\b"#,
            #"\b(goal|target)(\s+\w+){0,3}\s+(met|reached|achieved|hit|done|complete)\b"#,
        ]
        for p in patterns {
            guard let r = t.range(of: p, options: .regularExpression) else { continue }
            // Ignore a claim that a negator precedes ("have not met your goal").
            let windowStart = t.index(r.lowerBound, offsetBy: -40, limitedBy: t.startIndex) ?? t.startIndex
            let preceding = " " + t[windowStart..<r.lowerBound] + " "
            if Self.negators.contains(where: preceding.contains) { continue }
            return true
        }
        return false
    }

    /// True when `text` makes a goal-completion claim the deterministic `status`
    /// contradicts — the signal to discard the insight. A genuinely met goal is never
    /// flagged; every other status (short, over, or no goal at all) is.
    static func contradicts(_ text: String, status: DietSemantics.GoalStatus) -> Bool {
        guard !status.isMet else { return false }
        return claimsGoalReached(text)
    }

    /// Phrases that assert a total is COMPLETE — flagged on a partial day, where the
    /// total is only a floor. Tuned for precision (a false positive drops one insight):
    /// each names the whole, not a running tally.
    private static let completenessClaims = [
        " in total", " altogether", " a total of", " total of ", " in all",
        " all told", " adds up to", " sums to", " your total ", " the total ",
        " complete total", " full total", " entire ", " all of your ",
    ]

    /// Judgment words an informational metric (total sugars) must never render.
    private static let judgmentWords = [
        " over ", " too much", " too high", " excessive", " cut back", " cut down",
        " reduce ", " lower your", " limit ", " way too", " overdid",
    ]

    /// Whether `text` asserts the total is a complete amount — the signal to discard on
    /// a partial day, where the number is only a floor. Negation-unaware on purpose: a
    /// partial total is never complete, so any completeness phrasing is wrong here.
    static func claimsCompleteTotal(_ text: String) -> Bool {
        let t = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        return completenessClaims.contains(where: t.contains)
    }

    /// Whether `text` renders a good/bad judgment about the amount — the signal to
    /// discard for an informational metric (total sugars), which is composition-only.
    static func rendersJudgment(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        return judgmentWords.contains(where: t.contains)
    }

    /// The full discard decision for a generation, given the grounded `input`: a
    /// generation is discarded when it (a) claims the goal was reached against a
    /// non-met status, (b) claims the total is complete on a partial day, or (c)
    /// renders a judgment for an informational metric. Any one is enough — a wrong
    /// insight is worse than none.
    static func contradicts(_ text: String, input: HealthInsightInput) -> Bool {
        if contradicts(text, status: input.goalStatus) { return true }
        if input.partial, claimsCompleteTotal(text) { return true }
        if input.informational, rendersJudgment(text) { return true }
        return false
    }
}

/// A `HealthInsightGenerating` that always yields an empty stream. The default for a
/// context that wants the facts with no insight (previews, or a caller that opts out),
/// and the shape every unavailable/error path collapses to.
struct NoHealthInsight: HealthInsightGenerating {
    func insight(for input: HealthInsightInput) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
