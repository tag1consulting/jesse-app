import Foundation

// The "what fed this number" drill-down, as pure Foundation-only logic. Given the
// day's meals and a tapped metric (the calorie total or one macro), it ranks the
// foods that contributed to THAT metric, most impact first, with the zero/absent
// contributors excluded entirely. NOTHING here touches SwiftUI — the macros screen
// renders whatever this returns, and every rule is unit-tested.
//
// Impact is a food's own contribution to the tapped metric: kcal for calories,
// grams for a macro. A nil/absent field is NOT zero — it means the food is not a
// contributor to that metric, so it is omitted (never rendered as a 0 g / 0 kcal
// row). The headline total the screen shows and the summed contributions come from
// the same per-item fields, so they reconcile by construction; the reconciliation
// guard is a defensive backstop that flags any divergence rather than silently
// showing a list that contradicts the headline.

/// A metric whose daily total can be broken down into the foods that fed it: the
/// calorie total, or one of the four macros. Carries its own display label and unit
/// so no view hardcodes either.
enum ContributionMetric: Equatable, Sendable {
    case calories
    case macro(Macro)

    /// The user-facing name of the metric ("Calories", "Carbs").
    var label: String {
        switch self {
        case .calories: return "Calories"
        case .macro(let m): return m.displayName
        }
    }

    /// The unit a contribution is measured in: kcal for calories, grams for a macro.
    /// Uses the app's "cal" convention rather than "kcal" for parity with the rest of
    /// the Health tab.
    var unit: String {
        switch self {
        case .calories: return "cal"
        case .macro: return "g"
        }
    }
}

extension DietItem {
    /// This item's raw contribution to a metric, or nil when the backing field is
    /// absent. Nil is deliberately NOT zero: an absent field means "this food doesn't
    /// carry this detail", which the ranking treats as "not a contributor", never as a
    /// zero-impact row.
    func contribution(to metric: ContributionMetric) -> Double? {
        switch metric {
        case .calories: return cal
        case .macro(.protein): return p
        case .macro(.carbs): return c
        case .macro(.fiber): return fiber
        case .macro(.fat): return f
        }
    }
}

/// One food's contribution to a single tapped metric, ready to render. `value` is
/// kcal for calories, grams for a macro; `share` is the food's fraction (0…1) of the
/// day's total for that metric.
struct FoodContribution: Equatable, Sendable, Identifiable {
    /// The item's original position across the day's meals — stable and unique, so
    /// `ForEach` has a durable identity even after the list is re-sorted by impact.
    let id: Int
    let name: String
    let amount: String?
    let value: Double
    let share: Double
}

/// The ranked foods behind one metric for a day, plus the context a view needs to
/// render the facts honestly (the headline total, the metric, the empty/partial
/// wording, and any reconciliation note).
struct FoodBreakdown: Equatable, Sendable {
    let metric: ContributionMetric
    /// The day total the screen shows for this metric (the number being drilled into).
    let total: Double
    /// How many food items were logged across all meals — lets the empty state tell
    /// "nothing logged yet" apart from "logged, but none carry this metric".
    let itemCount: Int
    /// Contributing foods, most impact first, zero/absent contributors excluded.
    let contributions: [FoodContribution]
    /// Set only when the listed contributions don't add up to `total` (missing
    /// per-item detail or odd values), so the UI can say so rather than present a list
    /// that silently contradicts the headline. Nil in the common, fully-reconciled case.
    let reconciliationNote: String?

    /// No food contributed to this metric (either nothing logged, or nothing carrying
    /// this detail).
    var isEmpty: Bool { contributions.isEmpty }
    /// True when items were logged but none carry this metric — distinct from an empty
    /// day, for accurate empty-state wording.
    var hasFoodButNoContributors: Bool { itemCount > 0 && contributions.isEmpty }
}

enum FoodContributions {
    /// Below this a shortfall between the summed foods and the headline is treated as
    /// rounding noise, not a real gap.
    static let reconcileTolerance = 0.5

    /// The foods that fed `metric` for a day, most impact first, zero/absent
    /// contributors excluded. `total` is the headline the screen is showing for the
    /// metric (the day total), used as the share denominator and reconciled against
    /// the summed foods. Ties break by original meal/item order (stable), matching how
    /// the food journal lists them.
    static func breakdown(_ meals: [DietMeal], metric: ContributionMetric, total: Double) -> FoodBreakdown {
        let items = meals.flatMap(\.items)

        // Keep only positive contributors, tagged with their original index for a
        // stable tie-break and a durable ForEach identity.
        var kept: [(index: Int, item: DietItem, value: Double)] = []
        for (index, item) in items.enumerated() {
            guard let v = item.contribution(to: metric), v > 0 else { continue }
            kept.append((index, item, v))
        }
        // Most impact first; equal impact keeps original order.
        kept.sort { a, b in a.value != b.value ? a.value > b.value : a.index < b.index }

        let denom = total > 0 ? total : 0
        let contributions = kept.map { k in
            FoodContribution(id: k.index, name: k.item.item, amount: k.item.amount,
                             value: k.value,
                             share: denom > 0 ? min(k.value / denom, 1) : 0)
        }

        // Reconcile: the listed foods should add up to the headline. In practice they
        // do (both derive from the same per-item fields); a material shortfall means
        // some of the total came from items missing this per-item detail, which we say
        // out loud rather than paper over.
        let listedSum = kept.reduce(0.0) { $0 + $1.value }
        let note: String?
        if total > 0, total - listedSum > reconcileTolerance {
            note = "Some logged foods are missing this detail, so the list above may not add up to the total."
        } else {
            note = nil
        }

        return FoodBreakdown(metric: metric, total: total, itemCount: items.count,
                             contributions: contributions, reconciliationNote: note)
    }
}
