import Foundation
import JesseNetworking

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
    /// The after-hour at/after which a still-unfinished floor turns from the neutral
    /// "coming along" tone into a gentle "worth a nudge" — and the gated "low" flags
    /// surface. Before this hour an unfilled floor is simply in progress, never a problem.
    static let nagHour = 16

    /// How far over a ceiling (as a fraction of its target), late in the day, escalates
    /// a nudge into the firmer "take note" tone — e.g. well over the calorie ceiling in
    /// the evening. Deliberately gentle: this is a heads-up, never an alarm.
    static let takeNoteOverFraction = 0.10

    /// A metric's status band. `suspended` = shown plain, no judgment (fiber on a
    /// carb-load day), and also the "no usable target" fallback.
    ///
    /// This is the raw band math (kept for the trend chart, which colors a single
    /// nutrient over time where a band is unambiguous). The Health tab itself colors
    /// from `Tone`, which means ONE thing on every row; see `tone(for:hour:)`.
    enum Status: Equatable, Sendable { case red, yellow, green, suspended }

    /// The single display signal the Health tab colors from. Unlike `Status` — where red
    /// means "too low" on a floor but "too high" on a ceiling — a `Tone` means the SAME
    /// thing on every row, so a color can be read at a glance without decoding the row.
    /// Direction (too low vs too high) is carried by the words and the goal glyph, never
    /// the color.
    ///
    /// `onTrack` — you're in a good place (a floor reached, inside a window, comfortably
    /// under a ceiling). `inProgress` — simply not finished yet, which is normal
    /// (an unfilled floor early in the day), and also the no-judgment look (suspended
    /// fiber, no usable target). `nudge` — one gentle, specific action would help
    /// (a floor still low late in the day, over a ceiling, outside a window). `takeNote` —
    /// genuinely worth attention (well over a ceiling late in the day, or a hard-cap
    /// breach), delivered as a heads-up, not an alarm.
    enum Tone: Equatable, Sendable { case onTrack, inProgress, nudge, takeNote }

    /// Derive the one-meaning display `Tone` from a metric's deterministic goal outcome,
    /// the hour, and (for a window's hard edge) whether a hard cap was breached. Pure and
    /// unit-tested, so the color a row shows can never disagree with its words.
    ///
    /// - `.met` → `onTrack` (good, on every row).
    /// - `.short` (below a floor / a window's low edge): `onTrack` when it's already
    ///   basically there (`nearGoal` — the band reads good, e.g. a floor ≥ 80%); else
    ///   `inProgress` before `nagHour` (unfinished early is normal), then `nudge` once the
    ///   day is winding down.
    /// - `.over` (past a ceiling / a window's high edge) → `nudge`, escalating to
    ///   `takeNote` when a hard cap is breached, or when it's well over (≥
    ///   `takeNoteOverFraction` of target) AND late in the day.
    /// - `.noGoal` → `inProgress` (shown plain, no judgment).
    static func tone(goalStatus: GoalStatus, hour: Int, target: Double?,
                     nearGoal: Bool = false, hardOver: Bool = false) -> Tone {
        switch goalStatus {
        case .noGoal:
            return .inProgress
        case .met:
            return .onTrack
        case .short:
            if nearGoal { return .onTrack }   // basically there — don't nag over the last bit
            // Unfinished. Neutral while the day is young; a gentle nudge once it's late.
            return hour >= nagHour ? .nudge : .inProgress
        case .over(let by):
            if hardOver { return .takeNote }
            if hour >= nagHour, let target, target > 0, by >= target * takeNoteOverFraction {
                return .takeNote
            }
            return .nudge
        }
    }

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

    /// The deterministic goal outcome for a metric, computed in code so the on-device
    /// insight never has to guess it (the source of the "you hit your goal" bug when it
    /// did). Its thresholds mirror the `*Remaining` strings exactly, so the discrete
    /// status and the human wording can never disagree.
    ///
    /// `met` — the goal is satisfied: a floor reached, within a window, or under a
    /// ceiling. `short(by:)` — below a floor / a window's low edge by that many
    /// grams/cal (the amount still needed). `over(by:)` — past a ceiling / a window's
    /// high edge by that amount. `noGoal` — no usable target, so NO goal claim may be
    /// made at all.
    enum GoalStatus: Equatable, Sendable {
        case met
        case short(Double)
        case over(Double)
        case noGoal

        /// Whether the goal is satisfied — the only state under which an insight may
        /// assert the goal was hit/met.
        var isMet: Bool { self == .met }
    }

    // MARK: - Discrete goal status (deterministic, mirrors the remaining strings)

    /// FLOOR: met at or above target, else short by the shortfall.
    static func floorGoalStatus(value: Double, target: Double) -> GoalStatus {
        guard target > 0 else { return .noGoal }
        return value >= target ? .met : .short(target - value)
    }

    /// CEILING: met at or under target, else over by the excess.
    static func ceilingGoalStatus(value: Double, target: Double) -> GoalStatus {
        guard target > 0 else { return .noGoal }
        return value <= target ? .met : .over(value - target)
    }

    /// FAT WINDOW (normal day): short of the 50g floor below it, met inside 50–65g,
    /// over the 65g working cap above it.
    static func fatWindowGoalStatus(grams: Double) -> GoalStatus {
        if grams < fatFloor { return .short(fatFloor - grams) }
        if grams <= fatCap { return .met }
        return .over(grams - fatCap)
    }

    /// CALORIE WINDOW (carb-load day): short of the 92% low edge below it, met inside
    /// 92–100%, over target above it.
    static func calorieWindowGoalStatus(value: Double, target: Double) -> GoalStatus {
        guard target > 0 else { return .noGoal }
        let low = target * carbLoadLowFraction
        if value < low { return .short(low - value) }
        if value <= target { return .met }
        return .over(value - target)
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

    // MARK: - Micronutrient aggregation (unknown ≠ zero)

    /// Aggregate ONE optional per-item nutrient across a set of items, PRESERVING the
    /// unknowns: the sum of only the items that carried a value, how many items were
    /// unknown (absent value), and how many were known. This is deliberately NOT the
    /// `total(of:)` path — a nil here is UNKNOWN, never coalesced to 0, so a partial
    /// total is never passed off as complete.
    static func micronutrientTotal(of items: [DietItem], _ value: (DietItem) -> Double?) -> MicronutrientTotal {
        var knownSum = 0.0, known = 0, unknown = 0
        for it in items {
            if let v = value(it) { knownSum += v; known += 1 } else { unknown += 1 }
        }
        return MicronutrientTotal(knownSum: knownSum, unknownItemCount: unknown, knownItemCount: known)
    }

    /// The day's aggregate of one nutrient across every item in every meal.
    static func micronutrientTotal(for meals: [DietMeal], _ value: (DietItem) -> Double?) -> MicronutrientTotal {
        micronutrientTotal(of: meals.flatMap(\.items), value)
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

    /// floor: "Xg to go" / "there — nice". Action-first and kind: what's left, not what's
    /// missing. The tone (color) says whether that's a calm "coming along" or a gentle
    /// evening nudge; these words just carry the amount and direction.
    static func floorRemaining(value: Double, target: Double, unit: String = "g") -> String {
        guard target > 0 else { return "" }
        if value >= target { return "there — nice" }
        return "\(fmt(target - value))\(unit) to go"
    }

    /// ceiling: "room for X" / "right on target" / "X over". Frames headroom as room to
    /// use, not a limit to fear; "over" without "limit"/"breach" — the tone carries how
    /// much it matters.
    static func ceilingRemaining(value: Double, target: Double, unit: String = "") -> String {
        guard target > 0 else { return "" }
        if value < target { return "room for \(fmt(target - value))\(unit)" }
        if value == target { return "right on target" }
        return "\(fmt(value - target))\(unit) over"
    }

    /// fat window: "Xg to the 50g floor" / "in range" / "Xg above the range" (working
    /// range 50–65g). No "cap" language — inside the range simply reads "in range".
    static func fatWindowRemaining(grams: Double) -> String {
        if grams < fatFloor { return "\(fmt(fatFloor - grams))g to the 50g floor" }
        if grams <= fatCap { return "in range" }
        return "\(fmt(grams - fatCap))g above the range"
    }

    /// calorie window (carb-load day): "X more to go" / "in window" / "X over". "X more to
    /// go" is the amount up to the window's low edge (92%) — under-fuelling a carb-load
    /// wants MORE food, and the word says so; "X over" the amount past target.
    static func calorieWindowRemaining(value: Double, target: Double) -> String {
        guard target > 0 else { return "" }
        let low = target * carbLoadLowFraction
        if value < low { return "\(fmt(low - value)) more to go" }
        if value <= target { return "in window" }
        return "\(fmt(value - target)) over"
    }

    // MARK: - After-4pm gated flags

    /// The protein "low" heads-up: only at/after 16:00, only under 25% of target. A gentle,
    /// action-first nudge (never gated colors — that's the tone's job).
    static func proteinLowFlag(protein: Double, target: Double?, hour: Int) -> String? {
        guard hour >= nagHour, let target, target > 0 else { return nil }
        return protein / target * 100 < 25 ? "some protein would help before the day's out" : nil
    }

    /// The fat "low" heads-up: only at/after 16:00, only under the 50g hormonal floor.
    static func fatLowFlag(fat: Double, hour: Int) -> String? {
        guard hour >= nagHour else { return nil }
        return fat < fatFloor ? "a little fat would help — you're under the 50g floor" : nil
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
            let gs = calorieWindowGoalStatus(value: sum.cal, target: calTarget)
            calories = MetricGauge(
                label: "Calories", goal: .window, value: sum.cal, target: t.calories,
                status: calorieWindowStatus(value: sum.cal, target: calTarget),
                remaining: calorieWindowRemaining(value: sum.cal, target: calTarget),
                goalStatus: gs, tone: tone(goalStatus: gs, hour: hour, target: t.calories),
                flag: nil, unit: "", fraction: fraction(sum.cal, calTarget))
        } else {
            let gs = ceilingGoalStatus(value: sum.cal, target: calTarget)
            calories = MetricGauge(
                label: "Calories", goal: .ceiling, value: sum.cal, target: t.calories,
                status: ceilingStatus(value: sum.cal, target: calTarget),
                remaining: ceilingRemaining(value: sum.cal, target: calTarget),
                goalStatus: gs, tone: tone(goalStatus: gs, hour: hour, target: t.calories),
                flag: nil, unit: "", fraction: fraction(sum.cal, calTarget))
        }

        // Protein: always a floor.
        let pTarget = t.protein ?? 0
        let pGoal = floorGoalStatus(value: sum.p, target: pTarget)
        let pStatus = floorStatus(value: sum.p, target: pTarget)
        let protein = MetricGauge(
            label: Macro.protein.displayName, goal: .floor, value: sum.p, target: t.protein,
            status: pStatus,
            remaining: floorRemaining(value: sum.p, target: pTarget),
            goalStatus: pGoal,
            tone: tone(goalStatus: pGoal, hour: hour, target: t.protein, nearGoal: pStatus == .green),
            flag: proteinLowFlag(protein: sum.p, target: t.protein, hour: hour),
            unit: "g", fraction: fraction(sum.p, pTarget))

        // Carbs: floor vs carbsBase (falling back to carbs).
        let cTarget = t.carbsBase ?? t.carbs ?? 0
        let cGoal = floorGoalStatus(value: sum.c, target: cTarget)
        let cStatus = floorStatus(value: sum.c, target: cTarget)
        let carbs = MetricGauge(
            label: Macro.carbs.displayName, goal: .floor, value: sum.c, target: (t.carbsBase ?? t.carbs),
            status: cStatus,
            remaining: floorRemaining(value: sum.c, target: cTarget),
            goalStatus: cGoal,
            tone: tone(goalStatus: cGoal, hour: hour, target: (t.carbsBase ?? t.carbs), nearGoal: cStatus == .green),
            flag: nil, unit: "g", fraction: fraction(sum.c, cTarget))

        // Fat: window on a normal day, minimize-it ceiling on a carb-load day.
        let fat: MetricGauge
        if carbLoad {
            let fTarget = t.fat ?? 0
            let fGoal = ceilingGoalStatus(value: sum.f, target: fTarget)
            fat = MetricGauge(
                label: Macro.fat.displayName, goal: .ceiling, value: sum.f, target: t.fat,
                status: ceilingStatus(value: sum.f, target: fTarget),
                remaining: ceilingRemaining(value: sum.f, target: fTarget, unit: "g"),
                goalStatus: fGoal, tone: tone(goalStatus: fGoal, hour: hour, target: t.fat),
                flag: nil, unit: "g", fraction: fraction(sum.f, fTarget))
        } else {
            let fGoal = fatWindowGoalStatus(grams: sum.f)
            // The 70g hard cap is the firmer line: a breach reads "take note", not a nudge.
            let fatHardOver = sum.f > fatHardCap
            fat = MetricGauge(
                label: Macro.fat.displayName, goal: .window, value: sum.f, target: fatCap,
                status: fatWindowStatus(grams: sum.f),
                remaining: fatWindowRemaining(grams: sum.f),
                goalStatus: fGoal,
                tone: tone(goalStatus: fGoal, hour: hour, target: fatCap, hardOver: fatHardOver),
                flag: fatLowFlag(fat: sum.f, hour: hour),
                unit: "g", fraction: fraction(sum.f, fatCap))
        }

        // Fiber: floor, but suspended (shown plain) on a carb-load day.
        let fiberTarget = t.fiber ?? defaultFiberTarget
        let fiber: MetricGauge
        if carbLoad {
            fiber = MetricGauge(
                label: Macro.fiber.displayName, goal: .floor, value: sum.fiber, target: fiberTarget,
                status: .suspended, remaining: "resting today (carb-load)",
                goalStatus: .noGoal, tone: .inProgress,
                flag: nil, unit: "g", fraction: fraction(sum.fiber, fiberTarget))
        } else {
            let fbGoal = floorGoalStatus(value: sum.fiber, target: fiberTarget)
            let fbStatus = floorStatus(value: sum.fiber, target: fiberTarget)
            fiber = MetricGauge(
                label: Macro.fiber.displayName, goal: .floor, value: sum.fiber, target: fiberTarget,
                status: fbStatus,
                remaining: floorRemaining(value: sum.fiber, target: fiberTarget),
                goalStatus: fbGoal,
                tone: tone(goalStatus: fbGoal, hour: hour, target: fiberTarget, nearGoal: fbStatus == .green),
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

    // MARK: - Micronutrient gauges

    /// The micronutrient gauges for a day, in `Micronutrient.allCases` order. Each
    /// preserves unknowns: any item without the value makes the total PARTIAL (`value` is
    /// a floor, the view renders "≥"), and a day with zero known values is the neutral
    /// "not tracked yet" state. Sodium and saturated fat are ceilings; potassium, calcium,
    /// magnesium, and omega-3 are floors; total sugars and unsaturated fat are
    /// informational (never judged); an absent target shows the value only, with no
    /// judgment.
    static func micronutrientGauges(for today: DietToday, hour: Int = 12) -> [MetricGauge] {
        Micronutrient.allCases.map { micronutrientGauge($0, meals: today.meals, targets: today.targets, hour: hour) }
    }

    /// Build one micronutrient gauge from the day's items and targets. `hour` feeds the
    /// display tone the same way the macro gauges use it (a floor short before `nagHour`
    /// reads neutral, not as a problem).
    static func micronutrientGauge(_ n: Micronutrient, meals: [DietMeal], targets: DietTargets,
                                   hour: Int = 12) -> MetricGauge {
        let agg = micronutrientTotal(for: meals, n.value(in:))
        let value = agg.knownSum
        let target = n.target(in: targets)
        let unit = n.unit

        // Base gauge shared by every branch — value-only, no judgment. The branches
        // below layer a status/remaining/goalStatus on top when there's a real target.
        var g = MetricGauge(
            label: n.displayName, goal: n.goal, value: value, target: target,
            status: .suspended, remaining: "", goalStatus: .noGoal,
            flag: nil, unit: unit, fraction: nil,
            partial: agg.partial, unknownItemCount: agg.unknownItemCount,
            knownItemCount: agg.knownItemCount)

        // No item that day carried the nutrient → the neutral "not tracked yet" state,
        // regardless of whether a target exists.
        guard agg.tracked else {
            g.remaining = notTrackedCaption
            return g
        }

        // Total sugars is informational only: show the value (and a reference bar if a
        // target is present) but NEVER a red/green judgment — modeled like suspended
        // fiber.
        if !n.judged {
            g.fraction = fraction(value, target ?? 0)
            g.remaining = target == nil ? "" : "reference \(fmt(target!))\(unit)"
            return g
        }

        // Judged nutrients (ceiling / floor) need a usable target; without one they
        // stay value-only.
        guard let target, target > 0 else { return g }
        g.fraction = fraction(value, target)
        switch n.goal {
        case .ceiling:
            g.status = ceilingStatus(value: value, target: target)
            g.remaining = ceilingRemaining(value: value, target: target, unit: unit)
            g.goalStatus = ceilingGoalStatus(value: value, target: target)
        case .floor:
            g.status = floorStatus(value: value, target: target)
            g.remaining = floorRemaining(value: value, target: target, unit: unit)
            g.goalStatus = floorGoalStatus(value: value, target: target)
        case .window:
            break // not used by any micronutrient
        }
        g.tone = tone(goalStatus: g.goalStatus, hour: hour, target: target, nearGoal: g.status == .green)
        return g
    }

    /// The neutral caption for a nutrient no item that day carried a value for.
    static let notTrackedCaption = "not tracked yet"

    /// The "N items not estimated" caption for a partial micronutrient total, or nil
    /// when the total is complete (every contributing item carried the value).
    static func partialCaption(unknownItemCount: Int) -> String? {
        guard unknownItemCount > 0 else { return nil }
        return "\(unknownItemCount) item\(unknownItemCount == 1 ? "" : "s") not estimated"
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

    /// One-decimal format for a pace ("needs 2.2 lb/wk") — rounding a required
    /// pace to a whole number would lie, so this keeps the tenths.
    static func fmt1(_ x: Double) -> String { String(format: "%.1f", x) }

    // MARK: - Weight targets

    /// The effective display targets for a progress payload. When the generator
    /// emits `targets`, use it verbatim (its `achieved`/`daysLeft`/`requiredPace`
    /// are authoritative). Otherwise synthesize the legacy two-target shape so the
    /// UI renders through one code path during the transition — this keeps the app
    /// deploy independent of the vault-side rollout.
    ///
    /// Synthesis: `raceTarget`/`raceDate` → a dated goal, `maintTarget` → an
    /// undated "Maintenance" goal. Bar fields come straight from the legacy
    /// `*BarFilled`/`*BarLabel`; `daysLeft` is computed from the date relative to
    /// `today`; `achieved` from `currentWeight`. Legacy data has no required pace.
    static func displayTargets(_ progress: DietProgress, currentWeight: Double?, today: String?) -> [DietTarget] {
        if let targets = progress.targets { return targets }
        var out: [DietTarget] = []
        if let w = progress.raceTarget {
            let days = progress.raceDate.flatMap { d in today.flatMap { daysBetween(from: $0, to: d) } }
            out.append(DietTarget(
                id: "race", title: "Target \(fmt(w))", short: fmt(w), weight: w,
                date: progress.raceDate, daysLeft: days, requiredPace: nil,
                achieved: currentWeight.map { $0 <= w },
                barFilled: progress.raceBarFilled, barLabel: progress.raceBarLabel))
        }
        if let w = progress.maintTarget {
            out.append(DietTarget(
                id: "maint", title: "Maintenance", short: "Maint", weight: w,
                date: nil, daysLeft: nil, requiredPace: nil,
                achieved: currentWeight.map { $0 <= w },
                barFilled: progress.maintBarFilled, barLabel: progress.maintBarLabel))
        }
        return out
    }

    /// The dated goal a countdown should speak to: the nearest upcoming one
    /// (smallest non-negative `daysLeft`), or — when every dated goal is already
    /// past — the least-past one (largest, i.e. closest-to-zero, negative). Nil when
    /// no goal carries a usable date/`daysLeft`, so the countdown section hides.
    static func countdownTarget(_ targets: [DietTarget]) -> DietTarget? {
        let dated = targets.filter { $0.date != nil && $0.daysLeft != nil }
        if let upcoming = dated.filter({ ($0.daysLeft ?? -1) >= 0 })
            .min(by: { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }) {
            return upcoming
        }
        return dated.max(by: { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) })
    }

    /// The countdown phrasing for a dated goal: "N days to <title>" when the date is
    /// in the future/today, "N days past <title>" when it has slipped by — never a
    /// negative count. Nil when the goal has no `daysLeft`.
    static func countdownText(_ t: DietTarget) -> String? {
        guard let days = t.daysLeft else { return nil }
        let n = abs(days)
        let unit = n == 1 ? "day" : "days"
        return days < 0 ? "\(n) \(unit) past \(t.title)" : "\(n) \(unit) to \(t.title)"
    }

    /// Whole days from one `yyyy-MM-dd` day to another (UTC, calendar days), or nil
    /// if either doesn't parse. Positive = `to` is in the future of `from`.
    static func daysBetween(from: String, to: String) -> Int? {
        guard let a = isoDayParser.date(from: from), let b = isoDayParser.date(from: to) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day
    }

    /// A short human date ("Aug 15") from a `yyyy-MM-dd` string, falling back to the
    /// raw string if it doesn't parse and to nil when absent.
    static func displayDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        guard let d = isoDayParser.date(from: iso) else { return iso }
        return monthDayFormatter.string(from: d)
    }

    /// Parses/renders the `yyyy-MM-dd` day strings deterministically (UTC, gregorian),
    /// so target dates format identically regardless of device locale/zone.
    private static let isoDayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f
    }()
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

    /// Grams of a given macro — the seam that lets listings iterate `Macro.allCases`
    /// instead of hand-reading each field in a fixed order.
    func grams(for macro: Macro) -> Double {
        switch macro {
        case .protein: return p
        case .carbs: return c
        case .fiber: return fiber
        case .fat: return f
        }
    }
}

/// A day's aggregate of one optional per-item nutrient, preserving unknowns: the sum
/// of ONLY the items that carried a value, how many were unknown, and how many were
/// known. Because a missing value is UNKNOWN (never 0), a total with any unknown
/// contributor is PARTIAL (`knownSum` is a floor, not a complete sum), and a total
/// with zero known contributors is the neutral "not tracked yet" state.
struct MicronutrientTotal: Equatable, Sendable {
    var knownSum: Double
    var unknownItemCount: Int
    var knownItemCount: Int

    /// True when at least one contributing item lacked the value — `knownSum` is a
    /// floor, and the view must render it "≥" with the "N items not estimated" caption.
    var partial: Bool { unknownItemCount > 0 }
    /// True when at least one item carried the value; false is the "not tracked yet"
    /// state (distinct from a real zero).
    var tracked: Bool { knownItemCount > 0 }
}

/// The micronutrients shown alongside the macros. The single source of truth for their
/// user-facing display names — full, unabbreviated, spelled in one place so no view
/// invents a short form (guarded by `MacroLabelTests`). Case order is the canonical
/// display order (and drives the sub-entry order under a parent macro and the mineral
/// order in the Micronutrients section — see `NutrientOrder`).
///
/// `unsaturatedFat` is DERIVED, not a stored field: its per-item value is `fat − saturated
/// fat` for items whose saturated fat is KNOWN (an unknown-satf item makes the day
/// partial, never zero). Like total sugars it is informational — a value only, never a
/// red/green judgment (see `judged`).
enum Micronutrient: CaseIterable {
    case sodium, saturatedFat, unsaturatedFat, totalSugars, potassium, calcium, omega3, magnesium

    /// The full, unabbreviated user-facing name — the ONLY place these are spelled.
    var displayName: String {
        switch self {
        case .sodium: return "Sodium"
        case .saturatedFat: return "Saturated Fat"
        case .unsaturatedFat: return "Unsaturated Fat"
        case .totalSugars: return "Total Sugars"
        case .potassium: return "Potassium"
        case .calcium: return "Calcium"
        case .omega3: return "Omega-3 (EPA+DHA)"
        case .magnesium: return "Magnesium"
        }
    }

    /// The display unit: the minerals and omega-3 in milligrams, the fats and sugars in grams.
    var unit: String {
        switch self {
        case .sodium, .potassium, .calcium, .omega3, .magnesium: return "mg"
        case .saturatedFat, .unsaturatedFat, .totalSugars: return "g"
        }
    }

    /// How the nutrient is judged: sodium and saturated fat are ceilings (don't exceed);
    /// potassium, calcium, magnesium, and omega-3 are floors (reach them); total sugars
    /// and unsaturated fat are informational (a directional glyph but NEVER a color
    /// judgment — see `judged`). Unsaturated fat is the healthy fat, so it reads as a
    /// floor glyph (≥) even though it carries no judgment.
    var goal: DietSemantics.Goal {
        switch self {
        case .sodium, .saturatedFat: return .ceiling
        case .totalSugars: return .ceiling
        case .potassium, .calcium, .omega3, .magnesium, .unsaturatedFat: return .floor
        }
    }

    /// Whether the nutrient carries a red/green judgment. Total sugars and unsaturated
    /// fat are informational only — shown plain like suspended fiber, never judged.
    var judged: Bool { self != .totalSugars && self != .unsaturatedFat }

    /// This nutrient's per-item value (nil = unknown for that item). Unsaturated fat is
    /// DERIVED — `fat − saturated fat`, but only for an item whose saturated fat is known;
    /// an item with unknown saturated fat returns nil (unknown → partial, never zero).
    func value(in item: DietItem) -> Double? {
        switch self {
        case .sodium: return item.na
        case .saturatedFat: return item.satf
        case .unsaturatedFat: return item.satf.map { (item.f ?? 0) - $0 }
        case .totalSugars: return item.sug
        case .potassium: return item.k
        case .calcium: return item.ca
        case .omega3: return item.o3
        case .magnesium: return item.mg
        }
    }

    /// This nutrient's day target, or nil when the day carries no reference for it.
    /// Unsaturated fat is informational and derived — it never carries a target.
    func target(in t: DietTargets) -> Double? {
        switch self {
        case .sodium: return t.sodium
        case .saturatedFat: return t.satFat
        case .unsaturatedFat: return nil
        case .totalSugars: return t.sugar
        case .potassium: return t.potassium
        case .calcium: return t.calcium
        case .omega3: return t.omega3
        case .magnesium: return t.magnesium
        }
    }

    /// The macro this micronutrient hangs off as a nutrition-label sub-entry, or nil for
    /// a standalone entry. A food label declares "of which sugars" and "of which fibre"
    /// under Carbohydrate and "of which saturates" under Fat, so total sugars renders as
    /// a sub-entry of carbs (beside fiber), and saturated fat AND the derived unsaturated
    /// fat as sub-entries of fat. Sodium, potassium, calcium, magnesium, and omega-3 have
    /// no parent and stay in the Micronutrients section (omega-3 is a fat but, like the
    /// minerals, is tracked as a standalone floor). Drives the sub-entry identity color,
    /// the label type treatment, and the leading indent, exactly as `Macro.parent` does
    /// for fiber.
    var parent: Macro? {
        switch self {
        case .totalSugars: return .carbs
        case .saturatedFat, .unsaturatedFat: return .fat
        case .sodium, .potassium, .calcium, .omega3, .magnesium: return nil
        }
    }

    /// True when this micronutrient renders as an indented sub-entry beneath a macro
    /// (total sugars, saturated fat), rather than standalone in the Micronutrients section.
    var isSubEntry: Bool { parent != nil }

    /// A short, FIXED, plain-language teaching blurb — what the nutrient is and how to
    /// read its gauge — surfaced subordinately in the drill-down sheet. Editorial copy,
    /// deterministic and unit-tested, distinct from the streamed on-device insight (which
    /// is about today's foods) and never a number. Ceiling vs floor vs informational is
    /// stated correctly per nutrient; total sugars carries no judgment.
    var education: String {
        switch self {
        case .sodium:
            return "Sodium is the part of salt that pushes blood pressure up when it stays high over time — about 400 mg of it in every gram of salt. Stay under most days. A long or hot run sweats sodium out, so those days can run higher on purpose."
        case .saturatedFat:
            return "Saturated fat is just one slice of your total fat — a sub-budget with its own cap, not a limit on fat overall. The rest of your fat is fine: olive oil, fish, nuts, and egg yolks are unsaturated and can run high. Only this saturated slice has a ceiling to stay under."
        case .potassium:
            return "Potassium is the counterweight to sodium and helps pull blood pressure down. It's a floor to reach, not a limit. Labels often leave it out, so a low or \"not tracked yet\" reading usually means it couldn't be measured, not that you ate none — bananas, potatoes, beans, and salmon are loaded with it."
        case .totalSugars:
            return "This is every sugar in your food — the natural sugar in fruit, milk, and yogurt plus any added, all summed. Labels can't split the two, so there's no target here and no red or green. It's healthy from fruit and dairy; use the food list below to see whether it's those or added sugar worth trimming."
        case .unsaturatedFat:
            return "This is the rest of your fat once the saturated slice is set aside — the olive oil, nuts, avocado, and fish fats that are good for your heart. It's shown for composition only: no target, no red or green. A high number here just means most of your fat is the healthy kind."
        case .calcium:
            return "Calcium is a floor to reach, not a limit — it builds bone and keeps muscles and nerves firing. Dairy, fortified plant milks, tofu, and leafy greens carry most of it. Labels often leave it out, so a low or \"not tracked yet\" reading usually means it couldn't be measured, not that you ate none."
        case .omega3:
            return "Omega-3 here is the marine EPA and DHA in oily fish, shellfish, and roe — the heart- and brain-supporting fats, counted as a floor to reach. It does NOT include the plant ALA in flax, walnuts, or chia. Most foods leave it off the label, so a low or \"not tracked yet\" reading usually means it couldn't be measured."
        case .magnesium:
            return "Magnesium is a floor to reach, not a limit — it supports muscle and nerve function, blood sugar, and sleep. Nuts, seeds, beans, whole grains, and leafy greens are loaded with it. Labels often leave it out, so a low or \"not tracked yet\" reading usually means it couldn't be measured, not that you ate none."
        }
    }
}

/// The four macronutrients the Health tab tracks. The single source of truth for
/// their user-facing display names — no view spells a macro out or abbreviates it
/// on its own. There is no approved short form: never a single letter, never
/// "Fib". A future edit that reintroduces one fails `MacroLabelTests`, not a human
/// reviewer's eyes.
enum Macro: CaseIterable {
    // Case order IS the canonical user-facing display order: Protein, Carbs, Fiber,
    // Fat. Fiber is a subset of carbs (its grams are counted inside the carb grams,
    // US-label convention), so it sits immediately after carbs — never as a fourth
    // peer after fat. Every listing derives its order from `allCases`; no view spells
    // an order of its own. A regression that reorders these fails `MacroLabelTests`.
    case protein, carbs, fiber, fat

    var displayName: String {
        switch self {
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fiber: return "Fiber"
        case .fat: return "Fat"
        }
    }

    /// The macro this one is nutritionally a subset of, or nil for a top-level macro.
    /// Fiber's grams are a subset of carbohydrate grams, so it renders as a sub-entry
    /// of carbs — smaller and secondary — the way a nutrition label indents Dietary
    /// Fiber under Total Carbohydrate. Drives both the identity color (a shade of the
    /// parent's) and the label type treatment.
    var parent: Macro? {
        switch self {
        case .fiber: return .carbs
        default: return nil
        }
    }

    /// True when this macro renders as a sub-entry of another (currently fiber under
    /// carbs), rather than as one of the top-level peers.
    var isSubEntry: Bool { parent != nil }
}

/// One row in the nutrition-label nutrient tree: either a macro (protein, carbs, fiber,
/// fat) or a micronutrient that hangs off a macro as a sub-entry (total sugars and
/// saturated fat). The single type the Macros screen iterates, so a macro row and a
/// micronutrient sub-entry row share one ordered sequence and one sub-entry treatment
/// instead of two hand-kept lists.
enum NutrientEntry: Equatable, Hashable {
    case macro(Macro)
    case micronutrient(Micronutrient)

    /// Whether this row renders as an indented sub-entry of a parent macro — driven by
    /// the same `parent`/`isSubEntry` model on both enums.
    var isSubEntry: Bool {
        switch self {
        case .macro(let m): return m.isSubEntry
        case .micronutrient(let n): return n.isSubEntry
        }
    }
}

/// The single canonical ordering of the nutrient tree, derived from the `parent` links
/// on `Macro` and `Micronutrient` — no view hand-orders the rows. This is the one source
/// the order tests assert against.
enum NutrientOrder {
    /// The macro area's rows in canonical nutrition-label order: each top-level macro
    /// followed immediately by its sub-entries — macro sub-entries first (fiber), then
    /// micronutrient sub-entries (total sugars, saturated fat). For the current tree that
    /// is Protein, Carbs, Fiber, Total Sugars, Fat, Saturated Fat. Standalone minerals
    /// (sodium, potassium) are NOT here — they live in the Micronutrients section.
    static let macroArea: [NutrientEntry] = {
        var out: [NutrientEntry] = []
        for macro in Macro.allCases where macro.parent == nil {
            out.append(.macro(macro))
            for sub in Macro.allCases where sub.parent == macro {
                out.append(.macro(sub))
            }
            for n in Micronutrient.allCases where n.parent == macro {
                out.append(.micronutrient(n))
            }
        }
        return out
    }()

    /// The standalone minerals shown in the Micronutrients section — the micronutrients
    /// with no macro parent (sodium, potassium), in canonical order.
    static let minerals: [Micronutrient] = Micronutrient.allCases.filter { $0.parent == nil }
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
    /// One rendered term of the macro line, tagged with its macro so a view can style
    /// the sub-entry (fiber) run differently from the top-level runs.
    struct Segment: Equatable {
        let macro: Macro
        let text: String
    }

    /// The ordered terms of a totals line, in the canonical `Macro.allCases` order
    /// (Protein, Carbs, Fiber, Fat). `includeFiber: false` drops the fiber term. This
    /// is the single ordering source both `format` (plain string) and the styled
    /// caption view derive from.
    static func segments(_ t: MacroTotals, includeFiber: Bool = true, units: Bool = true) -> [Segment] {
        let u = units ? "g" : ""
        return Macro.allCases.compactMap { macro in
            if macro == .fiber && !includeFiber { return nil }
            return Segment(macro: macro, text: "\(macro.displayName) \(DietSemantics.fmt(t.grams(for: macro)))\(u)")
        }
    }

    static func format(_ t: MacroTotals, includeFiber: Bool = true, units: Bool = true) -> String {
        segments(t, includeFiber: includeFiber, units: units).map(\.text).joined(separator: " · ")
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
    /// The deterministic goal outcome (met / short / over / no-goal), computed
    /// alongside `remaining` so the insight is fed a ground-truth status instead of
    /// guessing one. Defaults to `.noGoal` so a gauge built without it makes no claim.
    var goalStatus: DietSemantics.GoalStatus = .noGoal
    /// The one-meaning display tone the Health tab colors from (see `DietSemantics.Tone`).
    /// Defaults to `.inProgress` (neutral) so a gauge built without it never invents a
    /// judgment; the engine sets it from `goalStatus` + the hour for every real gauge.
    var tone: DietSemantics.Tone = .inProgress
    /// The gated "low" nag (protein/fat), surfaced only at/after 16:00. Nil otherwise.
    var flag: String?
    var unit: String
    /// Bar fill fraction (value/target-ish), nil when there's no usable reference.
    var fraction: Double?
    /// Micronutrient partiality (the five macro gauges leave these at the defaults,
    /// their values being complete sums). `partial` is true when at least one
    /// contributing item lacked a value, so `value` is a FLOOR — the view renders it
    /// "≥value", never as a complete total. `unknownItemCount` drives the "N items not
    /// estimated" caption. `knownItemCount` is nil for a non-micronutrient gauge; for a
    /// micronutrient it's how many items carried the value, and a value of 0 is the
    /// neutral "not tracked yet" state (distinct from a real zero).
    var partial: Bool = false
    var unknownItemCount: Int = 0
    var knownItemCount: Int? = nil
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

    /// The gauge for a given macro — the seam that lets the rings row and the Macros
    /// screen iterate `Macro.allCases` in canonical order instead of listing the four
    /// gauges by hand (which is how the Fat-before-Fiber order slipped in).
    func gauge(for macro: Macro) -> MetricGauge {
        switch macro {
        case .protein: return protein
        case .carbs: return carbs
        case .fiber: return fiber
        case .fat: return fat
        }
    }

    /// The four macro gauges in canonical display order (Protein, Carbs, Fiber, Fat).
    var orderedMacros: [(macro: Macro, gauge: MetricGauge)] {
        Macro.allCases.map { ($0, gauge(for: $0)) }
    }
}
