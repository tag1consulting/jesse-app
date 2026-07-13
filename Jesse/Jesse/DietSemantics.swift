import Foundation

// The diet dashboard's rules, as pure Foundation-only functions — a faithful port
// of the browser dashboard's logic. NOTHING here touches SwiftUI: a `Status` maps
// to a color in the view, never here; the current hour is always injected, never
// read from `Date()`, so every rule is deterministically testable.
//
// The shape of a day: on ordinary/deficit days calories are a CEILING (don't
// exceed) and fat is a WINDOW (a hormonal floor at 50g, a working cap at 65g, a
// hard cap at 70g). On carb-load days those flip — calories become a WINDOW
// (UNDER-eating fails a carb-load) and fat becomes a minimize-it CEILING to leave
// calorie room for carbs — and fiber is suspended (low-residue eating before a
// long run is deliberate).

enum DietSemantics {
    /// Default fiber floor when `targets.fiber` is absent in an old file.
    static let defaultFiberTarget = 38.0
    /// Fat window edges (grams): hormonal floor, working cap, hard cap.
    static let fatFloor = 50.0
    static let fatCap = 65.0
    static let fatHardCap = 70.0
    /// Carb-load calorie window: the low edge as a fraction of target.
    static let carbLoadLowFraction = 0.92
    /// The after-hour at/after which the nagging "low" flags surface.
    static let nagHour = 16

    /// A metric's status band. `suspended` = shown plain, no judgment (fiber on a
    /// carb-load day), and also the "no usable target" fallback.
    enum Status: Equatable, Sendable { case red, yellow, green, suspended }

    /// How a metric is judged, for its glyph and explainer.
    enum Goal: Equatable, Sendable {
        case floor, ceiling, window
        /// The goal glyph shown on a gauge: floor ≥, ceiling ≤, window ↕.
        var glyph: String {
            switch self {
            case .floor: return "≥"
            case .ceiling: return "≤"
            case .window: return "↕"
            }
        }
    }

    // MARK: - Day-style profile

    /// Whether today is a carb-load day. `dayStyle` wins; if absent, fall back to a
    /// case-insensitive "CARB-LOAD" substring in `dayType`; else it's a normal day.
    static func isCarbLoad(dayStyle: String?, dayType: String?) -> Bool {
        if let s = dayStyle?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s == "carb-load-training" || s == "carb-load-race"
        }
        if let t = dayType?.uppercased(), t.contains("CARB-LOAD") { return true }
        return false
    }

    // MARK: - Totals & sorting

    /// Sum cal/p/f/c/fiber across a set of items.
    static func total(of items: [DietItem]) -> MacroTotals {
        var t = MacroTotals.zero
        for it in items {
            t.cal += it.cal ?? 0
            t.p += it.p ?? 0
            t.f += it.f ?? 0
            t.c += it.c ?? 0
            t.fiber += it.fiber ?? 0
        }
        return t
    }

    /// Per-meal subtotal.
    static func subtotal(of meal: DietMeal) -> MacroTotals { total(of: meal.items) }

    /// Grand total across all meals.
    static func dayTotals(_ meals: [DietMeal]) -> MacroTotals {
        meals.reduce(.zero) { $0 + subtotal(of: $1) }
    }

    /// Summed exercise calories (the day's burn).
    static func burnedCalories(_ exercise: [DietExercise]) -> Double {
        exercise.reduce(0) { $0 + ($1.calories ?? 0) }
    }

    /// Minutes-since-midnight sort key for an `HH:MM` string; a missing/unparseable
    /// time returns -1 so it sorts FIRST (the browser dashboard's convention).
    static func minutesOfDay(_ time: String?) -> Int {
        guard let time else { return -1 }
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return -1 }
        return h * 60 + m
    }

    /// Meals in chronological order (missing time first), stable within equal times.
    static func sortedMeals(_ meals: [DietMeal]) -> [DietMeal] {
        meals.enumerated()
            .sorted { a, b in
                let ka = minutesOfDay(a.element.time), kb = minutesOfDay(b.element.time)
                return ka != kb ? ka < kb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Exercise sessions in chronological order (missing time first), stable.
    static func sortedExercise(_ exercise: [DietExercise]) -> [DietExercise] {
        exercise.enumerated()
            .sorted { a, b in
                let ka = minutesOfDay(a.element.time), kb = minutesOfDay(b.element.time)
                return ka != kb ? ka < kb : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Status bands

    /// FLOOR (protein, carbs, fiber): under 50% red, 50–79% yellow, 80%+ green.
    static func floorStatus(value: Double, target: Double) -> Status {
        guard target > 0 else { return .suspended }
        let pct = value / target * 100
        if pct < 50 { return .red }
        if pct < 80 { return .yellow }
        return .green
    }

    /// CEILING (calories on a normal day; fat on a carb-load day): under 80% green,
    /// 80–100% yellow, over 100% red.
    static func ceilingStatus(value: Double, target: Double) -> Status {
        guard target > 0 else { return .suspended }
        let pct = value / target * 100
        if pct < 80 { return .green }
        if pct <= 100 { return .yellow }
        return .red
    }

    /// FAT WINDOW (normal day): under 50g red (too LOW — deliberate), 50–65g green,
    /// 65–70g yellow, over 70g red.
    static func fatWindowStatus(grams: Double) -> Status {
        if grams < fatFloor { return .red }
        if grams <= fatCap { return .green }
        if grams <= fatHardCap { return .yellow }
        return .red
    }

    /// CALORIE WINDOW (carb-load day): under 92% red, 92–100% green, over 100% red.
    static func calorieWindowStatus(value: Double, target: Double) -> Status {
        guard target > 0 else { return .suspended }
        let pct = value / target * 100
        if pct < carbLoadLowFraction * 100 { return .red }
        if pct <= 100 { return .green }
        return .red
    }

    // MARK: - Remaining annotations

    /// floor: "need Xg more" / "target hit".
    static func floorRemaining(value: Double, target: Double, unit: String = "g") -> String {
        guard target > 0 else { return "" }
        if value >= target { return "target hit" }
        return "need \(fmt(target - value))\(unit) more"
    }

    /// ceiling: "X left" / "at limit" / "X over limit".
    static func ceilingRemaining(value: Double, target: Double, unit: String = "") -> String {
        guard target > 0 else { return "" }
        if value < target { return "\(fmt(target - value))\(unit) left" }
        if value == target { return "at limit" }
        return "\(fmt(value - target))\(unit) over limit"
    }

    /// fat window: "need Xg to floor" / "Xg to cap" / "Xg over cap" (cap = 65g).
    static func fatWindowRemaining(grams: Double) -> String {
        if grams < fatFloor { return "need \(fmt(fatFloor - grams))g to floor" }
        if grams <= fatCap { return "\(fmt(fatCap - grams))g to cap" }
        return "\(fmt(grams - fatCap))g over cap"
    }

    /// calorie window: "need X more" / "in window" / "X over". "need X more" is the
    /// amount to reach the window's low edge (92%); "X over" the amount past target.
    static func calorieWindowRemaining(value: Double, target: Double) -> String {
        guard target > 0 else { return "" }
        let low = target * carbLoadLowFraction
        if value < low { return "need \(fmt(low - value)) more" }
        if value <= target { return "in window" }
        return "\(fmt(value - target)) over"
    }

    // MARK: - After-4pm gated flags

    /// The protein "low" nag: only at/after 16:00, only under 25% of target.
    /// Colors and over-cap flags are never gated — this is the one gated text.
    static func proteinLowFlag(protein: Double, target: Double?, hour: Int) -> String? {
        guard hour >= nagHour, let target, target > 0 else { return nil }
        return protein / target * 100 < 25 ? "still under 25% of protein" : nil
    }

    /// The fat "low" nag: only at/after 16:00, only under the 50g hormonal floor.
    static func fatLowFlag(fat: Double, hour: Int) -> String? {
        guard hour >= nagHour else { return nil }
        return fat < fatFloor ? "under the 50g fat floor" : nil
    }

    // MARK: - Assembled gauges

    /// Build the five macro/calorie gauges plus the optional carbs-bonus line and
    /// the net-calorie split, from today's snapshot and the injected hour. This is
    /// what the screens render; no view recomputes any of it.
    static func gauges(for today: DietToday, hour: Int) -> DietGauges {
        let carbLoad = isCarbLoad(dayStyle: today.dayStyle, dayType: today.dayType)
        let t = today.targets
        let sum = dayTotals(today.meals)

        // Calories: ceiling on a normal day, window on a carb-load day.
        let calTarget = t.calories ?? 0
        let calories: MetricGauge
        if carbLoad {
            calories = MetricGauge(
                label: "Calories", goal: .window, value: sum.cal, target: t.calories,
                status: calorieWindowStatus(value: sum.cal, target: calTarget),
                remaining: calorieWindowRemaining(value: sum.cal, target: calTarget),
                flag: nil, unit: "", fraction: fraction(sum.cal, calTarget))
        } else {
            calories = MetricGauge(
                label: "Calories", goal: .ceiling, value: sum.cal, target: t.calories,
                status: ceilingStatus(value: sum.cal, target: calTarget),
                remaining: ceilingRemaining(value: sum.cal, target: calTarget),
                flag: nil, unit: "", fraction: fraction(sum.cal, calTarget))
        }

        // Protein: always a floor.
        let pTarget = t.protein ?? 0
        let protein = MetricGauge(
            label: Macro.protein.displayName, goal: .floor, value: sum.p, target: t.protein,
            status: floorStatus(value: sum.p, target: pTarget),
            remaining: floorRemaining(value: sum.p, target: pTarget),
            flag: proteinLowFlag(protein: sum.p, target: t.protein, hour: hour),
            unit: "g", fraction: fraction(sum.p, pTarget))

        // Carbs: floor vs carbsBase (falling back to carbs).
        let cTarget = t.carbsBase ?? t.carbs ?? 0
        let carbs = MetricGauge(
            label: Macro.carbs.displayName, goal: .floor, value: sum.c, target: (t.carbsBase ?? t.carbs),
            status: floorStatus(value: sum.c, target: cTarget),
            remaining: floorRemaining(value: sum.c, target: cTarget),
            flag: nil, unit: "g", fraction: fraction(sum.c, cTarget))

        // Fat: window on a normal day, minimize-it ceiling on a carb-load day.
        let fat: MetricGauge
        if carbLoad {
            let fTarget = t.fat ?? 0
            fat = MetricGauge(
                label: Macro.fat.displayName, goal: .ceiling, value: sum.f, target: t.fat,
                status: ceilingStatus(value: sum.f, target: fTarget),
                remaining: ceilingRemaining(value: sum.f, target: fTarget, unit: "g"),
                flag: nil, unit: "g", fraction: fraction(sum.f, fTarget))
        } else {
            fat = MetricGauge(
                label: Macro.fat.displayName, goal: .window, value: sum.f, target: fatCap,
                status: fatWindowStatus(grams: sum.f),
                remaining: fatWindowRemaining(grams: sum.f),
                flag: fatLowFlag(fat: sum.f, hour: hour),
                unit: "g", fraction: fraction(sum.f, fatCap))
        }

        // Fiber: floor, but suspended (shown plain) on a carb-load day.
        let fiberTarget = t.fiber ?? defaultFiberTarget
        let fiber: MetricGauge
        if carbLoad {
            fiber = MetricGauge(
                label: Macro.fiber.displayName, goal: .floor, value: sum.fiber, target: fiberTarget,
                status: .suspended, remaining: "suspended (carb-load)",
                flag: nil, unit: "g", fraction: fraction(sum.fiber, fiberTarget))
        } else {
            fiber = MetricGauge(
                label: Macro.fiber.displayName, goal: .floor, value: sum.fiber, target: fiberTarget,
                status: floorStatus(value: sum.fiber, target: fiberTarget),
                remaining: floorRemaining(value: sum.fiber, target: fiberTarget),
                flag: nil, unit: "g", fraction: fraction(sum.fiber, fiberTarget))
        }

        // Carbs bonus (the exercise add-back): only off a carb-load day, only when
        // carbsBase is present AND carbs consumed exceed it.
        var bonus: CarbsBonus?
        if !carbLoad, let base = t.carbsBase, let full = t.carbs, sum.c > base {
            let pool = max(full - base, 0)
            bonus = CarbsBonus(consumed: sum.c - base, pool: pool,
                               fraction: fraction(sum.c - base, pool))
        }

        let net = NetCalories(intake: sum.cal, burned: burnedCalories(today.exercise))
        return DietGauges(calories: calories, protein: protein, carbs: carbs,
                          fat: fat, fiber: fiber, carbsBonus: bonus, net: net,
                          isCarbLoad: carbLoad)
    }

    // MARK: - Helpers

    /// A bar fill fraction (value / target), 0 when there's no usable target. Not
    /// clamped — the view clamps to [0, 1] for the bar but may show >100%.
    static func fraction(_ value: Double, _ target: Double) -> Double? {
        guard target > 0 else { return nil }
        return value / target
    }

    /// Round to a whole number and drop the decimal point ("need 12g more").
    static func fmt(_ x: Double) -> String { String(Int(x.rounded())) }
}

/// Summed macros (cal + protein/fat/carbs/fiber grams). `+` and `.zero` make
/// folding meals trivial.
struct MacroTotals: Equatable, Sendable {
    var cal: Double
    var p: Double
    var f: Double
    var c: Double
    var fiber: Double

    static let zero = MacroTotals(cal: 0, p: 0, f: 0, c: 0, fiber: 0)
    static func + (a: MacroTotals, b: MacroTotals) -> MacroTotals {
        MacroTotals(cal: a.cal + b.cal, p: a.p + b.p, f: a.f + b.f,
                    c: a.c + b.c, fiber: a.fiber + b.fiber)
    }
}

/// The four macronutrients the Health tab tracks. The single source of truth for
/// their user-facing display names — no view spells a macro out or abbreviates it
/// on its own. There is no approved short form: never a single letter, never
/// "Fib". A future edit that reintroduces one fails `MacroLabelTests`, not Jeremy's
/// eyes.
enum Macro: CaseIterable {
    case protein, carbs, fat, fiber

    var displayName: String {
        switch self {
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        case .fiber: return "Fiber"
        }
    }
}

/// Builds the labeled macro line shown under food-journal items, meal subtotals,
/// the day-summary card, and planned meals — always from the canonical `Macro`
/// names, in protein · carbs · fat · fiber order. Pure and unit-tested; the view
/// bodies only render its output.
///
/// `units: true` is the full form ("Protein 32g · Carbs 40g · Fat 12g · Fiber 6g");
/// `units: false` is the compact fallback that drops the gram unit for tight rows
/// ("Protein 32 · Carbs 40 · Fat 12 · Fiber 6"). `includeFiber: false` omits the
/// fiber term entirely. Rounding matches the rest of the Health tab via
/// `DietSemantics.fmt`, so the displayed numbers never change.
enum MacroLine {
    static func format(_ t: MacroTotals, includeFiber: Bool = true, units: Bool = true) -> String {
        let u = units ? "g" : ""
        var parts = [
            "\(Macro.protein.displayName) \(DietSemantics.fmt(t.p))\(u)",
            "\(Macro.carbs.displayName) \(DietSemantics.fmt(t.c))\(u)",
            "\(Macro.fat.displayName) \(DietSemantics.fmt(t.f))\(u)",
        ]
        if includeFiber {
            parts.append("\(Macro.fiber.displayName) \(DietSemantics.fmt(t.fiber))\(u)")
        }
        return parts.joined(separator: " · ")
    }
}

/// One assembled gauge for a macro or calories.
struct MetricGauge: Equatable, Sendable {
    var label: String
    var goal: DietSemantics.Goal
    var value: Double
    /// The target being judged against, or nil when there's no usable target /
    /// the metric is a window with no single target (fat on a normal day uses the
    /// 65g cap as its bar reference; see `fraction`).
    var target: Double?
    var status: DietSemantics.Status
    var remaining: String
    /// The gated "low" nag (protein/fat), surfaced only at/after 16:00. Nil otherwise.
    var flag: String?
    var unit: String
    /// Bar fill fraction (value/target-ish), nil when there's no usable reference.
    var fraction: Double?
}

/// The exercise carb add-back — extra carb budget earned by exercise, optional
/// fuel rather than an obligation.
struct CarbsBonus: Equatable, Sendable {
    var label = "exercise fuel (optional)"
    var consumed: Double
    var pool: Double
    var fraction: Double?
}

/// Intake minus exercise burn, for the two-part net-calorie bar.
struct NetCalories: Equatable, Sendable {
    var intake: Double
    var burned: Double
    var net: Double { intake - burned }
}

/// Everything the macro/calorie screens render for a day.
struct DietGauges: Equatable, Sendable {
    var calories: MetricGauge
    var protein: MetricGauge
    var carbs: MetricGauge
    var fat: MetricGauge
    var fiber: MetricGauge
    var carbsBonus: CarbsBonus?
    var net: NetCalories
    var isCarbLoad: Bool
}
