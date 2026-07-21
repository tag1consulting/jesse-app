import Foundation
import JesseNetworking

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
/// calorie total, one of the four macros, or one of the four micronutrients. Carries
/// its own display label and unit so no view hardcodes either.
///
/// A micronutrient behaves differently from a macro in ONE crucial way: an item that
/// lacks the value is UNKNOWN, not a non-contributor — `isMicronutrient` tells the
/// breakdown to surface those unknowns in their own group rather than silently drop
/// them (see `FoodContributions.breakdown`). Total sugars is additionally
/// `isInformational` — composition only, never a judgment.
enum ContributionMetric: Equatable, Sendable {
    case calories
    case macro(Macro)
    case micronutrient(Micronutrient)

    /// The user-facing name of the metric ("Calories", "Carbs", "Sodium").
    var label: String {
        switch self {
        case .calories: return "Calories"
        case .macro(let m): return m.displayName
        case .micronutrient(let n): return n.displayName
        }
    }

    /// The unit a contribution is measured in: kcal for calories, grams for a macro,
    /// the nutrient's own unit (mg/g) for a micronutrient. Uses the app's "cal"
    /// convention rather than "kcal" for parity with the rest of the Health tab.
    var unit: String {
        switch self {
        case .calories: return "cal"
        case .macro: return "g"
        case .micronutrient(let n): return n.unit
        }
    }

    /// Whether this metric preserves unknowns: a micronutrient's absent per-item value
    /// is UNKNOWN (surfaced in a "Not estimated" group), never coalesced to a
    /// non-contributor. False for calories/macros, whose per-item fields are treated as
    /// "not a contributor" when absent.
    var isMicronutrient: Bool {
        if case .micronutrient = self { return true }
        return false
    }

    /// Whether this metric is informational only — shown and grounded without any
    /// red/green or over/under judgment. True for total sugars alone.
    var isInformational: Bool {
        if case .micronutrient(let n) = self { return !n.judged }
        return false
    }
}

extension DietItem {
    /// This item's raw contribution to a metric, or nil when the backing field is
    /// absent. Nil is deliberately NOT zero: for a macro/calorie it means "this food
    /// doesn't carry this detail" (a non-contributor); for a micronutrient it means the
    /// value is UNKNOWN for this item — either way never a zero-impact row.
    func contribution(to metric: ContributionMetric) -> Double? {
        switch metric {
        case .calories: return cal
        case .macro(.protein): return p
        case .macro(.carbs): return c
        case .macro(.fiber): return fiber
        case .macro(.fat): return f
        case .micronutrient(let n): return n.value(in: self)
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

/// One food that lacks a value for the tapped micronutrient — surfaced in its own
/// "Not estimated" group, name and amount only, NEVER a number. These rows are why a
/// partial total reads "≥"; they must never be silently omitted or shown as a 0.
/// Empty for a calorie/macro breakdown (whose absent items are plain non-contributors).
struct UnknownFood: Equatable, Sendable, Identifiable {
    /// The item's original cross-meal index — a stable, durable `ForEach` identity.
    let id: Int
    let name: String
    let amount: String?
}

/// The ranked foods behind one metric for a day, plus the context a view needs to
/// render the facts honestly (the headline total, the metric, the empty/partial
/// wording, any reconciliation note, and — for a micronutrient — the items that carry
/// no value for it).
struct FoodBreakdown: Equatable, Sendable {
    let metric: ContributionMetric
    /// The day total the screen shows for this metric (the number being drilled into).
    /// For a micronutrient this is the KNOWN sum — a floor when `unknownFoods` is
    /// non-empty — and it is the denominator every contributor's share is taken against.
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
    /// The day's items that carry NO value for a micronutrient — the "Not estimated"
    /// group, in logged order. Always empty for a calorie/macro breakdown. When
    /// non-empty the total above is a floor (rendered "≥"), and this many items are the
    /// "N items not estimated" caption.
    let unknownFoods: [UnknownFood]

    /// No food contributed to this metric (either nothing logged, or nothing carrying
    /// this detail).
    var isEmpty: Bool { contributions.isEmpty }
    /// True when items were logged but none carry this metric — distinct from an empty
    /// day, for accurate empty-state wording.
    var hasFoodButNoContributors: Bool { itemCount > 0 && contributions.isEmpty }
    /// True when at least one logged item lacks a value for this micronutrient, so the
    /// total is a floor and the "Not estimated" group must show. Always false for a
    /// calorie/macro breakdown.
    var isPartial: Bool { !unknownFoods.isEmpty }
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
        // stable tie-break and a durable ForEach identity. For a micronutrient, an item
        // whose value is ABSENT is UNKNOWN — collected into its own group rather than
        // dropped — while a measured true 0 is a plain non-contributor, excluded from
        // both (never a "0 mg" row, never an "unknown" row).
        var kept: [(index: Int, item: DietItem, value: Double)] = []
        var unknowns: [UnknownFood] = []
        for (index, item) in items.enumerated() {
            if let v = item.contribution(to: metric) {
                if v > 0 { kept.append((index, item, v)) }
            } else if metric.isMicronutrient {
                unknowns.append(UnknownFood(id: index, name: item.item, amount: item.amount))
            }
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
        // out loud rather than paper over. A micronutrient never trips this — its `total`
        // IS the sum of the known contributors, and its unknowns are surfaced in their
        // own group instead of hidden inside a reconciliation gap.
        let listedSum = kept.reduce(0.0) { $0 + $1.value }
        let note: String?
        if !metric.isMicronutrient, total > 0, total - listedSum > reconcileTolerance {
            note = "Some logged foods are missing this detail, so the list above may not add up to the total."
        } else {
            note = nil
        }

        return FoodBreakdown(metric: metric, total: total, itemCount: items.count,
                             contributions: contributions, reconciliationNote: note,
                             unknownFoods: unknowns)
    }
}
