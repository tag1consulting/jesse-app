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
    /// The day total for the metric (the headline being drilled into).
    let total: Double
    /// How the metric is judged, in plain words ("a floor to hit or beat").
    let goalPhrase: String
    /// The live remaining/status wording ("need 40g more", "12g over cap").
    let statusLine: String
    /// The day's style, in plain words ("carb-load day", "ordinary day").
    let dayStyle: String
    /// The top contributing foods, most impact first — the only foods/numbers the
    /// model is allowed to mention.
    let foods: [FoodFact]
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
    static func input(metric: ContributionMetric, total: Double, goalPhrase: String,
                      statusLine: String, dayStyle: String,
                      contributions: [FoodContribution]) -> HealthInsightInput {
        let foods = contributions.prefix(groundingFoodCount).map {
            FoodFact(name: $0.name, value: $0.value, sharePct: Int(($0.share * 100).rounded()))
        }
        return HealthInsightInput(
            metricLabel: metric.label, unit: metric.unit, total: total,
            goalPhrase: goalPhrase, statusLine: statusLine, dayStyle: dayStyle,
            foods: Array(foods))
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
        return """
        Day type: \(input.dayStyle).
        Metric: \(input.metricLabel) — \(input.goalPhrase).
        Total so far: \(DietSemantics.fmt(input.total)) \(input.unit) (\(input.statusLine)).
        Top contributing foods:
        \(foodLines)

        In one or two short sentences, tell the user something useful about their \
        \(metric) for the day. Use ONLY the foods and numbers listed above — do not \
        invent foods, amounts, or targets. Second person, plain text, no lists, no \
        markdown.
        """
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
