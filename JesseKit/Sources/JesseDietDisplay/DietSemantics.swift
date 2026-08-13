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
    /// Methylmercury's ceiling over a rolling 7 days, in micrograms — the standing weekly
    /// reference for an adult of Jeremy's body weight. A WEEK's number, deliberately never
    /// divided into a per-day one: methylmercury's clearance half-life is what makes the
    /// week the meaningful unit, so a daily seventh would judge a tuna steak as a failure
    /// and a week of them as fine.
    ///
    /// A FALLBACK, not the source of truth. The day's own `targets.mercury_weekly` wins
    /// when it carries one (the generator emits it); this is what a day that recorded none
    /// is read against, on the same principle as `defaultFiberTarget` — the weekly
    /// reference is a standing physiological number rather than a per-day plan, so losing
    /// it should not silently drop the only judgment this row makes.
    static let mercuryWeeklyCeiling = 105.0

    /// The purine level, in milligrams for one day, above which the row adds a NEUTRAL
    /// note. NOT a ceiling: purines carry no judgment here, because the uric-acid response
    /// is individual and the body's own production dwarfs the dietary share for most
    /// people. This is the line above which the number is worth a glance — a fallback for
    /// a day whose `targets.purines` says nothing.
    static let purineNoteThreshold = 500.0

    /// The after-hour at/after which a still-unfinished floor turns from the neutral
    /// "coming along" tone into a gentle "worth a nudge" — and the gated "low" flags
    /// surface. Before this hour an unfilled floor is simply in progress, never a problem.
    static let nagHour = 16

    /// The hour a SETTLED reading is judged at. A rolling verdict speaks to days that are
    /// already finished, so the day-in-progress softening `nagHour` provides must not apply
    /// to it: a week-long shortfall is not "still in progress, come back later". Numerically
    /// the same end-of-day hour a past day is rendered at (`HistoryRender.endOfDayHour`).
    static let settledHour = 24

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
    ///
    /// `window` and `band` are deliberately DISTINCT despite drawing the same glyph. A
    /// `window` is total fat's fixed 50–65 g range, judged on a complete sum. A `band` is
    /// a floor-and-ceiling pair whose two edges are NOT symmetric under partial data: a
    /// known-only sum is a LOWER BOUND, so it can prove a ceiling was crossed but can
    /// never prove a floor was missed (see `bandGoalStatus`). Collapsing the two would put
    /// that asymmetry back in the view, which is exactly where it must not live.
    enum Goal: Equatable, Sendable {
        case floor, ceiling, window, band
        /// The goal glyph shown on a gauge: floor ≥, ceiling ≤, window and band ↕ (both
        /// mean "keep it inside a range" to a reader; the difference is in the math).
        var glyph: String {
            switch self {
            case .floor: return "≥"
            case .ceiling: return "≤"
            case .window, .band: return "↕"
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

    /// ZERO CEILING: the ceiling whose target is literally 0 — trans fat, where "none" is
    /// the goal rather than "some amount is fine". It needs its own entry point because
    /// `ceilingGoalStatus` treats a 0 target as NO usable target, and that is right for
    /// every other metric: a missing calorie target arrives as `t.calories ?? 0`, and
    /// reading that as "over by everything you ate" would be a lie. Only a nutrient that
    /// DECLARES zero is its goal (`Micronutrient.zeroIsTheGoal`) routes here, so a
    /// stray/absent 0 elsewhere keeps its old, safe meaning.
    ///
    /// A genuine 0 is `met` — you ate none, which is the goal reached, not an absence of
    /// data. Anything above is over by the whole amount.
    static func zeroCeilingGoalStatus(value: Double) -> GoalStatus {
        value <= 0 ? .met : .over(value)
    }

    /// BAND: a floor to reach AND a ceiling to stay under, unknown-aware.
    ///
    /// THE ASYMMETRY, which is the whole reason this is not two calls to the floor and
    /// ceiling helpers. `value` is the sum of the KNOWN contributors only, so on a partial
    /// day it is a LOWER BOUND, and a lower bound proves exactly one direction:
    ///
    /// * ABOVE THE CEILING is PROVEN. Unmeasured items can only add more, so a
    ///   known-only sum already past the ceiling is past it whatever the unknowns hold.
    ///   A partial day therefore CAN legitimately trip the ceiling.
    /// * BELOW THE FLOOR is NOT PROVEN on a partial day. The unmeasured items could carry
    ///   it over the floor several times, so calling it `short` would assert a shortfall
    ///   nobody measured — the same error as reading a gap as a zero. It resolves to
    ///   `noGoal`: no claim, and the row says "at least X so far" rather than "short".
    ///   A COMPLETE day below the floor is a real, measured shortfall and reads `short`.
    /// * INSIDE THE BAND is proven on a partial day too — the lower bound has already
    ///   cleared the floor — but note it can still rise past the ceiling later, which is
    ///   what makes this `met` for the day so far and not a promise about the day's end.
    static func bandGoalStatus(value: Double, floor: Double, ceiling: Double,
                               partial: Bool) -> GoalStatus {
        guard floor > 0, ceiling > floor else { return .noGoal }
        if value > ceiling { return .over(value - ceiling) }   // proven by the lower bound
        if value >= floor { return .met }                      // proven by the lower bound
        return partial ? .noGoal : .short(floor - value)       // provable only when complete
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

    /// ZERO CEILING (trans fat): a measured 0 is green, anything above it is red. There is
    /// no yellow — there is no "nearly none".
    static func zeroCeilingStatus(value: Double) -> Status {
        value <= 0 ? .green : .red
    }

    /// BAND (selenium): green inside the band, red above the ceiling, and BELOW the floor
    /// the floor's own three-step band (under 50% red, 50–79% yellow, 80%+ green — the
    /// same "basically there" softening every floor gets). A PARTIAL day below the floor
    /// is `suspended`: the lower bound proves nothing there, so no colour is claimed —
    /// the mirror of `bandGoalStatus`'s `noGoal`.
    static func bandStatus(value: Double, floor: Double, ceiling: Double,
                           partial: Bool) -> Status {
        guard floor > 0, ceiling > floor else { return .suspended }
        if value > ceiling { return .red }
        if value >= floor { return .green }
        return partial ? .suspended : floorStatus(value: value, target: floor)
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

    /// zero ceiling (trans fat): "none — ideal" at a measured zero, else the amount, said
    /// plainly. No "room for X" language: there is no room, and no headroom to spend.
    static func zeroCeilingRemaining(value: Double, unit: String = "") -> String {
        value <= 0 ? "none — ideal" : "\(fmt(value))\(unit) logged"
    }

    /// band: "Xu to the Yu floor" / "in the Y–Zu range" / "Xu above the range" — and, on a
    /// PARTIAL day whose known-only sum sits under the floor, "at least Xu so far".
    ///
    /// That last phrase is the words half of `bandGoalStatus`'s asymmetry, and it is the
    /// point of this function: an unfinished, partly-unmeasured day under the floor has
    /// not been shown to be short of anything, so it says what IS known ("at least this
    /// much") instead of a shortfall that was never measured.
    static func bandRemaining(value: Double, floor: Double, ceiling: Double,
                              partial: Bool, unit: String = "") -> String {
        guard floor > 0, ceiling > floor else { return "" }
        if value > ceiling { return "\(fmt(value - ceiling))\(unit) above the range" }
        if value >= floor { return "in the \(fmt(floor))–\(fmt(ceiling))\(unit) range" }
        if partial { return "at least \(fmt(value))\(unit) so far" }
        return "\(fmt(floor - value))\(unit) to the \(fmt(floor))\(unit) floor"
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
    ///
    /// `series` is the decoded `nutrientSeries` history. Of the five, ONLY total fat on a
    /// normal day is buffered by it (a 7-day window): calories, protein, carbs and fiber are
    /// judged on today, deliberately. Absent → every gauge keeps the single-day behavior.
    static func gauges(for today: DietToday, hour: Int, series: [NutrientDay]? = nil) -> DietGauges {
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

        // Fat: window on a normal day, minimize-it ceiling on a carb-load day. The carb-load
        // branch stays judged on TODAY: it is a deliberate one-day goal (leave calorie room
        // for carbs), and the history carries no day styles, so a rolling median there would
        // judge a carb-load day by a week of normal ones.
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
            // Total fat is BUFFERED: the color is the 7-day median's band against the same
            // 50–65 g window, while the grams, the remaining phrase, the goal outcome and the
            // after-4pm "under the 50 g floor" flag all stay today's. The 70 g hard cap is
            // still the firmer line — a breach of it by the JUDGED value reads "take note",
            // not a nudge; a breach by TODAY's value is the separate blow-out marker below.
            let fJudged = NutrientTrends.judgment(for: .f, todayValue: sum.f,
                                                  series: series, targets: t)
            fat = MetricGauge(
                label: Macro.fat.displayName, goal: .window, value: sum.f, target: fatCap,
                status: fJudged.status,
                remaining: fatWindowRemaining(grams: sum.f),
                goalStatus: fGoal,
                tone: tone(goalStatus: fJudged.goalStatus,
                           hour: fJudged.source.isRolling ? settledHour : hour,
                           target: fatCap, hardOver: fJudged.hardOver),
                flag: fatLowFlag(fat: sum.f, hour: hour),
                unit: "g", fraction: fraction(sum.f, fatCap),
                judgment: fJudged.source,
                blowout: NutrientTrends.blowout(.f, todayValue: sum.f, targets: t) != nil)
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
    /// Mercury is absent: its limit exists only over a rolling week, so it has no day
    /// gauge at all (see `Micronutrient.dayScoped` and `rollingWindowGauge`).
    static func micronutrientGauges(for today: DietToday, hour: Int = 12,
                                    series: [NutrientDay]? = nil) -> [MetricGauge] {
        Micronutrient.allCases.filter(\.dayScoped).map {
            micronutrientGauge($0, meals: today.meals, targets: today.targets,
                               hour: hour, series: series)
        }
    }

    /// Build one micronutrient gauge from the day's items and targets. `hour` feeds the
    /// display tone the same way the macro gauges use it (a floor short before `nagHour`
    /// reads neutral, not as a problem).
    ///
    /// `series` is the decoded `nutrientSeries` history. When present, a BUFFERED nutrient
    /// (sodium and saturated fat over 7 days; potassium, calcium, omega-3 and magnesium over
    /// 30) takes its `status`/`tone` from that window's median instead of today alone, while
    /// `value`, `remaining` and `goalStatus` stay today's — see `MetricGauge.judgment`.
    /// Absent (an older bridge, or a past day) every nutrient keeps the single-day behavior.
    static func micronutrientGauge(_ n: Micronutrient, meals: [DietMeal], targets: DietTargets,
                                   hour: Int = 12, series: [NutrientDay]? = nil) -> MetricGauge {
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

        // An informational nutrient (total sugars, unsaturated fat, cholesterol, purines)
        // shows the value — and a reference bar if a target is present — but NEVER a
        // red/green judgment, modeled like suspended fiber. Purines add their neutral
        // above-500mg note here, which is a note and not a verdict: it changes no colour,
        // no goal status, and no bar.
        if !n.judged {
            g.fraction = fraction(value, target ?? 0)
            g.remaining = target == nil ? "" : "reference \(fmt(target!))\(unit)"
            g.note = informationalNote(n, value: value, unit: unit, targets: targets)
            return g
        }

        // BAND (selenium): a floor AND a ceiling, and the one shape where partiality is
        // ASYMMETRIC — see `bandGoalStatus`. A half-recorded band (one edge only) is not a
        // band and stays value-only rather than judging against whichever edge it happens
        // to have. Returns here rather than falling through to the rolling-window buffer
        // below: a band has no defined median semantics, and borrowing the single-number
        // ones would judge a range against a point.
        if n.goal == .band {
            guard let edges = n.band(in: targets)?.edges else { return g }
            g.target = edges.ceiling
            g.fraction = fraction(value, edges.ceiling)
            g.status = bandStatus(value: value, floor: edges.floor,
                                  ceiling: edges.ceiling, partial: agg.partial)
            g.remaining = bandRemaining(value: value, floor: edges.floor,
                                        ceiling: edges.ceiling, partial: agg.partial,
                                        unit: unit)
            g.goalStatus = bandGoalStatus(value: value, floor: edges.floor,
                                          ceiling: edges.ceiling, partial: agg.partial)
            g.tone = tone(goalStatus: g.goalStatus, hour: hour, target: edges.ceiling,
                          nearGoal: g.status == .green)
            return g
        }

        // ZERO CEILING (trans fat): "none" is the goal, so a 0 target is a real ceiling
        // here and not the no-usable-target state the guard below treats it as everywhere
        // else. Also returns early — a rolling median of a zero ceiling says nothing a
        // day's number doesn't already say, and the buffered path would read the 0 target
        // as "no goal" and wipe the verdict out.
        if n.zeroIsTheGoal, let zero = n.target(in: targets), zero == 0 {
            g.status = zeroCeilingStatus(value: value)
            g.remaining = zeroCeilingRemaining(value: value, unit: unit)
            g.goalStatus = zeroCeilingGoalStatus(value: value)
            // Any amount pegs the bar: against a ceiling of none there is no headroom to
            // draw a proportion of.
            g.fraction = value > 0 ? 1 : 0
            // No target passed to `tone`: the late-day escalation is a fraction OF the
            // target, and a fraction of zero would make every trace reading "take note".
            g.tone = tone(goalStatus: g.goalStatus, hour: hour, target: nil)
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
        case .window, .band:
            break // handled above (band) / not used by any micronutrient (window)
        }
        // The buffered nutrients' COLOR comes from their trailing window's median; the
        // number, the remaining phrase and the goal outcome above stay today's. A daily
        // nutrient, a thin window, or no series at all leaves this exactly as it was.
        let trend = TrendNutrient(metric: .micronutrient(n))
        let judged = NutrientTrends.judgment(for: trend, todayValue: value,
                                             series: series, targets: targets)
        g.status = judged.status
        g.judgment = judged.source
        g.blowout = NutrientTrends.blowout(trend, todayValue: value, targets: targets) != nil
        g.tone = tone(goalStatus: judged.goalStatus,
                      hour: judged.source.isRolling ? settledHour : hour,
                      target: target, nearGoal: judged.status == .green,
                      hardOver: judged.hardOver)
        return g
    }

    /// The neutral caption for a nutrient no item that day carried a value for.
    static let notTrackedCaption = "not tracked yet"

    /// The neutral note an INFORMATIONAL nutrient may add beside its value, or nil. It is
    /// a note and never a verdict: it changes no colour, no goal status and no bar, and
    /// the wording carries no good/bad language. Only purines has one — above
    /// `purineNoteThreshold` the number is worth a glance and nothing more.
    static func informationalNote(_ n: Micronutrient, value: Double, unit: String,
                                  targets: DietTargets) -> String? {
        guard n == .purines else { return nil }
        let line = targets.purines ?? purineNoteThreshold
        guard line > 0, value > line else { return nil }
        return "above \(fmt(line))\(unit) for the day — worth a glance, not a limit"
    }

    // MARK: - Rolling-window gauges (a limit defined over days, not a day)

    /// ONE nutrient's aggregate over the snapshot's trailing window, or nil when nothing in
    /// the window measured it (the row then does not render at all, rather than showing a
    /// phantom zero week). Reads the window's own `days` rather than assuming 7, and takes
    /// the nutrient's series key from `TrendNutrient` so there is no second key table.
    static func rollingWindowTotal(_ n: Micronutrient,
                                   in window: DietRollingWindow) -> RollingWindowTotal? {
        // Keyed by LOG COLUMN key, not the short app key — see `Micronutrient.logKey`.
        guard let v = window.nutrients[n.logKey], v.knownCount >= 1 else { return nil }
        return RollingWindowTotal(days: window.days, knownSum: v.known,
                                  knownItemCount: v.knownCount,
                                  unknownItemCount: v.unknownCount,
                                  from: window.from, to: window.to)
    }

    /// ONE nutrient's trailing-WINDOW gauge, or nil when the window measured nothing for
    /// it. The number is the window's KNOWN SUM — never a median, and never today's total
    /// wearing a week's label — and it is judged against the nutrient's own window ceiling
    /// (mercury's 105 µg per 7 days). A nutrient with no window ceiling (omega-3) renders
    /// the same row with NO verdict: the window is context beside its day row, not a
    /// second judgment competing with it.
    ///
    /// Partiality reads exactly as it does on the daily gauges: unmeasured items are never
    /// summed as 0, so `partial` makes the number a floor the row renders "≥". Note that
    /// for a ceiling this cuts the honest way round without any special case — a lower
    /// bound already past the ceiling is past it, and a lower bound under it has simply
    /// not been shown to breach.
    ///
    /// The tone is derived at `settledHour` because a window speaks to days already over:
    /// a week's excess is not "still in progress, come back later".
    static func rollingWindowGauge(_ n: Micronutrient, window: DietRollingWindow,
                                   targets: DietTargets) -> MetricGauge? {
        guard let total = rollingWindowTotal(n, in: window) else { return nil }
        let ceiling = n.rollingWindowCeiling(in: targets)
        var g = MetricGauge(
            label: rollingWindowLabel(n, days: total.days),
            goal: n.goal, value: total.knownSum, target: ceiling,
            status: .suspended, remaining: "", goalStatus: .noGoal,
            flag: nil, unit: n.unit,
            fraction: ceiling.flatMap { fraction(total.knownSum, $0) },
            partial: total.partial, unknownItemCount: total.unknownItemCount,
            knownItemCount: total.knownItemCount,
            rollingWindow: total)

        // No window ceiling → the context row: the week's total, stated, judged by nothing.
        guard let ceiling, ceiling > 0 else {
            g.remaining = "\(total.days)-day total"
            return g
        }
        g.status = ceilingStatus(value: total.knownSum, target: ceiling)
        g.remaining = ceilingRemaining(value: total.knownSum, target: ceiling, unit: n.unit)
        g.goalStatus = ceilingGoalStatus(value: total.knownSum, target: ceiling)
        g.tone = tone(goalStatus: g.goalStatus, hour: settledHour, target: ceiling)
        return g
    }

    /// The label a window row carries. The window length is IN THE NAME, not only in the
    /// chip beside it, because this is the one row on the screen whose number is not
    /// today's and misreading it as today's is the specific failure to design against.
    static func rollingWindowLabel(_ n: Micronutrient, days: Int) -> String {
        "\(n.displayName) (\(days)-day)"
    }

    /// The one-line footnote under a window row, spelling out what the number is and is
    /// not — so the label and the chip are not the only signals (accessibility, and plain
    /// honesty). Names the coverage the window rests on.
    static func rollingWindowNote(_ total: RollingWindowTotal) -> String {
        let span = total.range.map { "\(total.days)-day total, \($0)" }
            ?? "\(total.days)-day total"
        return total.partial
            ? "\(span) — not today's number. \(total.unknownItemCount) "
                + "\(total.unknownItemCount == 1 ? "food is" : "foods are") not estimated, "
                + "so this is a floor."
            : "\(span) — not today's number."
    }

    /// The one-line footnote under the window section, said once per screen rather than
    /// per row: what these numbers are, and the fact that they are totals rather than the
    /// medians every OTHER window on the Health tab shows.
    static let rollingWindowFootnote =
        "These are running totals over the last several days, not today's numbers — some "
        + "limits are defined over a week rather than a day. A food that wasn't measured is "
        + "a gap, never a zero, so a total with gaps is a floor."

    /// Every rolling-window gauge the snapshot can build, in canonical order. Empty when
    /// the generator sends no `rolling7` block at all, which is the graceful-degrade path.
    static func rollingWindowGauges(for today: DietToday) -> [(nutrient: Micronutrient, gauge: MetricGauge)] {
        guard let window = today.rolling7 else { return [] }
        return NutrientOrder.rollingWindowed.compactMap { n in
            rollingWindowGauge(n, window: window, targets: today.targets).map { (n, $0) }
        }
    }

    /// The window chip a BUFFERED row shows beside its label — "7d" / "30d". Present only
    /// when the color really is that window's median, so a green color sitting next to a
    /// number that looks high explains itself at a glance. Nil on a daily-judged row and on
    /// a thin window (which is showing today's color and must not imply a pattern).
    static func rollingChip(_ source: JudgmentSource) -> String? {
        source.isRolling ? source.caption : nil
    }

    /// The one-line footnote under a buffered row, spelling out what the color means so the
    /// chip is never the only signal (accessibility, and plain honesty about the split
    /// between a rolling color and today's number). Nil on a daily-judged row.
    static func judgmentNote(_ source: JudgmentSource) -> String? {
        switch source {
        case .daily:
            return nil
        case .rolling(let caption, let days):
            return "color: \(caption) median of \(days) logged \(days == 1 ? "day" : "days") · number: today"
        case .thinWindow(let caption, let days):
            return "only \(days) logged \(days == 1 ? "day" : "days") — not enough for a \(caption) read, so this is today's"
        }
    }

    /// The same-day blow-out marker's words. Shown alongside (never instead of) the rolling
    /// color: the point is that one loud day is visible even when the window is fine.
    static let blowoutCaption = "today ran hot — well past the day's line"

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

/// One nutrient's aggregate over a TRAILING WINDOW of days rather than a single day —
/// the shape the `rolling7` block decodes into. Structurally the same unknown-preserving
/// bargain as `MicronutrientTotal` (a sum over only the items that carried a value, plus
/// the counts behind it), at a different scale: the counts are items across the whole
/// window, not items in one day.
///
/// Deliberately NOT a median, and deliberately not derived from a day: a weekly limit is
/// a limit on the WEEK'S TOTAL, so a median would answer a question nobody asked and a
/// single day multiplied by seven would be a fabrication.
struct RollingWindowTotal: Equatable, Sendable {
    /// The window's length in days, taken from the payload rather than assumed.
    var days: Int
    var knownSum: Double
    var knownItemCount: Int
    var unknownItemCount: Int
    /// The window's first and last day, when the generator names them.
    var from: String?
    var to: String?

    /// The span in words ("Aug 7–13"), or nil when the payload named no dates.
    var range: String? {
        guard let from = DietSemantics.displayDate(from),
              let to = DietSemantics.displayDate(to) else { return nil }
        return "\(from)–\(to)"
    }

    /// True when at least one item in the window lacked the value, making `knownSum` a
    /// floor the row must render "≥".
    var partial: Bool { unknownItemCount > 0 }
    /// True when at least one item in the window carried the value.
    var tracked: Bool { knownItemCount > 0 }
    /// The window chip beside the label ("7d").
    var chip: String { "\(days)d" }
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
    // Case order IS the canonical display order, and it drives BOTH the sub-entry order
    // under a parent and the standalone order in the Micronutrients section. The fat
    // sub-entries run in US-label order (saturated, trans, then the derived unsaturated
    // share, then cholesterol); added sugar sits under total sugars the way a label reads
    // "Total Sugars / Includes Xg Added Sugars".
    case sodium
    case saturatedFat, transFat, unsaturatedFat, cholesterol
    case totalSugars, addedSugar
    case potassium, calcium, omega3, magnesium, selenium, vitaminD, purines, mercury

    /// The full, unabbreviated user-facing name — the ONLY place these are spelled.
    var displayName: String {
        switch self {
        case .sodium: return "Sodium"
        case .saturatedFat: return "Saturated Fat"
        case .transFat: return "Trans Fat"
        case .unsaturatedFat: return "Unsaturated Fat"
        case .cholesterol: return "Cholesterol"
        case .totalSugars: return "Total Sugars"
        case .addedSugar: return "Added Sugar"
        case .potassium: return "Potassium"
        case .calcium: return "Calcium"
        case .omega3: return "Omega-3 (EPA+DHA)"
        case .magnesium: return "Magnesium"
        case .selenium: return "Selenium"
        case .vitaminD: return "Vitamin D"
        case .purines: return "Purines"
        case .mercury: return "Mercury"
        }
    }

    /// The display unit: the bulk minerals and omega-3 in milligrams, the fats and sugars
    /// in grams, and the trace nutrients (selenium, vitamin D, mercury) in micrograms —
    /// they are dosed three orders of magnitude below the others, so milligrams would
    /// render every one of them as "0".
    var unit: String {
        switch self {
        case .sodium, .potassium, .calcium, .omega3, .magnesium, .cholesterol, .purines:
            return "mg"
        case .saturatedFat, .transFat, .unsaturatedFat, .totalSugars, .addedSugar:
            return "g"
        case .selenium, .vitaminD, .mercury:
            return "µg"
        }
    }

    /// How the nutrient is judged: sodium, saturated fat, trans fat and added sugar are
    /// ceilings (don't exceed); potassium, calcium, magnesium, omega-3 and vitamin D are
    /// floors (reach them); selenium is a BAND (a floor AND a ceiling, close enough
    /// together that one number cannot express the goal); total sugars, unsaturated fat,
    /// cholesterol and purines are informational (a directional glyph but NEVER a colour
    /// judgment — see `judged`); mercury reads as a ceiling because that is what its
    /// weekly limit is, but it is judged only over the rolling window, never on one day.
    ///
    /// A glyph is a DIRECTION, never a verdict — the same rule total sugars has always
    /// followed. Cholesterol and purines draw ≤ because down is the direction anyone
    /// reading them cares about, and withhold every colour, which is where the absence of
    /// judgment actually lives.
    var goal: DietSemantics.Goal {
        switch self {
        case .sodium, .saturatedFat, .transFat, .addedSugar, .mercury: return .ceiling
        case .totalSugars, .cholesterol, .purines: return .ceiling
        case .selenium: return .band
        case .potassium, .calcium, .omega3, .magnesium, .vitaminD, .unsaturatedFat:
            return .floor
        }
    }

    /// Whether the nutrient carries a red/green judgment. Total sugars, unsaturated fat,
    /// cholesterol and purines are informational only — shown plain like suspended fiber,
    /// never judged. Mercury IS judged, but only by the rolling-window gauge; its
    /// day-scoped self is never rendered (see `dayScoped`).
    var judged: Bool {
        switch self {
        case .totalSugars, .unsaturatedFat, .cholesterol, .purines: return false
        default: return true
        }
    }

    /// The one nutrient whose target is legitimately ZERO — trans fat, where "none" is the
    /// goal rather than a budget to spend. Everywhere else a 0 target means "no usable
    /// target" and shows the value with no judgment, and that default must stay: a missing
    /// calorie target arrives as 0 and reading it as a ceiling would be a lie. Only a
    /// nutrient that declares this routes to `DietSemantics.zeroCeilingGoalStatus`.
    var zeroIsTheGoal: Bool { self == .transFat }

    /// Whether this nutrient renders a DAY-scoped row at all. False for mercury alone: its
    /// limit is defined over a week, so a daily row would invite exactly the reading —
    /// "today's mercury is fine / too high" — that the rolling gauge exists to prevent.
    /// Mercury's day total is still aggregated (the drill-down and the window need it); it
    /// simply never gets a day gauge of its own.
    var dayScoped: Bool { self != .mercury }

    /// Whether this nutrient ALSO renders a trailing-window row built from the snapshot's
    /// `rolling7` block. Mercury, because that is the only scale its limit exists at; and
    /// omega-3 as a SECONDARY display — its verdict already lives on the day row's 30-day
    /// buffered colour, so the window row there is context, never a second judgment.
    var showsRollingWindow: Bool { self == .mercury || self == .omega3 }

    /// This nutrient's ceiling over the rolling window, in its own unit, or nil when the
    /// window row is context only (omega-3). Mercury reads the day's own
    /// `targets.mercury_weekly` and falls back to the standing weekly reference — a WEEK's
    /// number either way, never divided into a daily one.
    func rollingWindowCeiling(in t: DietTargets) -> Double? {
        guard self == .mercury else { return nil }
        return t.mercuryWeekly ?? DietSemantics.mercuryWeeklyCeiling
    }

    /// This nutrient's LOG COLUMN key — the generator's own column name, which is the
    /// namespace the `rolling7` block is keyed by (`mercury_ug`, `omega3_mg`). Distinct
    /// from the short app key (`hg`, `o3`) that every per-item field and every
    /// `nutrientSeries` day uses: same nutrient, different spelling per surface, and
    /// looking one up with the other finds nothing at all.
    var logKey: String {
        switch self {
        case .sodium: return "sodium_mg"
        case .saturatedFat: return "satfat_g"
        case .transFat: return "trans_fat_g"
        case .unsaturatedFat: return "unsat_g"   // derived; the log has no column for it
        case .cholesterol: return "cholesterol_mg"
        case .totalSugars: return "sugar_g"
        case .addedSugar: return "added_sugar_g"
        case .potassium: return "potassium_mg"
        case .calcium: return "calcium_mg"
        case .omega3: return "omega3_mg"
        case .magnesium: return "magnesium_mg"
        case .selenium: return "selenium_ug"
        case .vitaminD: return "vitamin_d_ug"
        case .purines: return "purines_mg"
        case .mercury: return "mercury_ug"
        }
    }

    /// This nutrient's per-item value (nil = unknown for that item). Unsaturated fat is
    /// DERIVED — `fat − saturated fat`, but only for an item whose saturated fat is known;
    /// an item with unknown saturated fat returns nil (unknown → partial, never zero).
    func value(in item: DietItem) -> Double? {
        switch self {
        case .sodium: return item.na
        case .saturatedFat: return item.satf
        case .transFat: return item.tfat
        case .unsaturatedFat: return item.satf.map { (item.f ?? 0) - $0 }
        case .cholesterol: return item.chol
        case .totalSugars: return item.sug
        case .addedSugar: return item.asug
        case .potassium: return item.k
        case .calcium: return item.ca
        case .omega3: return item.o3
        case .magnesium: return item.mg
        case .selenium: return item.se
        case .vitaminD: return item.vd
        case .purines: return item.pur
        case .mercury: return item.hg
        }
    }

    /// This nutrient's SINGLE day target, or nil when the day carries no reference for it.
    /// Unsaturated fat is informational and derived; cholesterol and purines carry no
    /// target by design; selenium's goal is a band and lives in `band(in:)`, not here;
    /// mercury's is a weekly window ceiling, not a day number.
    func target(in t: DietTargets) -> Double? {
        switch self {
        case .sodium: return t.sodium
        case .saturatedFat: return t.satFat
        case .transFat: return t.transFat
        case .unsaturatedFat: return nil
        case .cholesterol: return nil
        case .totalSugars: return t.sugar
        case .addedSugar: return t.addedSugar
        case .potassium: return t.potassium
        case .calcium: return t.calcium
        case .omega3: return t.omega3
        case .magnesium: return t.magnesium
        case .selenium: return nil
        case .vitaminD: return t.vitaminD
        case .purines: return nil
        case .mercury: return nil
        }
    }

    /// This nutrient's BAND target (a floor and a ceiling), or nil for every nutrient
    /// whose goal is a single number. Selenium alone: its floor and its upper limit sit
    /// close enough together that either edge on its own would be the wrong goal.
    func band(in t: DietTargets) -> DietBandTarget? {
        self == .selenium ? t.selenium : nil
    }

    /// The nutrient this one hangs off as a nutrition-label sub-entry, or nil for a
    /// standalone entry. A food label declares "of which sugars" and "of which fibre"
    /// under Carbohydrate and "of which saturates" under Fat, so total sugars renders as a
    /// sub-entry of carbs (beside fiber), and the fat components as sub-entries of fat.
    ///
    /// The parent may itself be a micronutrient, which is what added sugar needs: a label
    /// reads "Total Sugars / Includes Xg Added Sugars", so added sugar is a sub-entry of
    /// total sugars, one level deeper than total sugars is under carbs. Drives the
    /// sub-entry identity colour, the label type treatment, and the leading indent —
    /// exactly as `Macro.parent` does for fiber, now over two levels rather than one.
    var parent: NutrientParent? {
        switch self {
        case .totalSugars: return .macro(.carbs)
        case .addedSugar: return .micronutrient(.totalSugars)
        case .saturatedFat, .transFat, .unsaturatedFat, .cholesterol: return .macro(.fat)
        case .sodium, .potassium, .calcium, .omega3, .magnesium,
             .selenium, .vitaminD, .purines, .mercury:
            return nil
        }
    }

    /// True when this micronutrient renders as an indented sub-entry beneath another
    /// nutrient, rather than standalone in the Micronutrients section.
    var isSubEntry: Bool { parent != nil }

    /// How many levels deep this row sits in the nutrition-label tree: 0 standalone,
    /// 1 under a macro, 2 under a micronutrient that is itself under a macro (added
    /// sugar). Drives the leading indent, and only that — the type treatment stays
    /// binary (sub-entry or not), because a third type step would fall off the ramp.
    var depth: Int {
        switch parent {
        case .none: return 0
        case .macro: return 1
        case .micronutrient(let p): return p.depth + 1
        }
    }

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
        case .cholesterol:
            return "Food contains no HDL and no LDL — those are the carriers your blood makes, not something on a plate, so no meal is \"good\" or \"bad\" cholesterol. Dietary cholesterol moves blood cholesterol far less than we once thought, which is why there's no target here and no red or green. The levers that do move your LDL are the three already tracked: saturated fat, trans fat, and fiber. This number comes from a solid database lookup, so it's a good estimate, and it's here for context only."
        case .transFat:
            return "Trans fat has no safe amount — the goal is literally none, which is why the target is zero rather than a budget to spend. It raises LDL and lowers HDL at once, the only fat that does both. It's declared on labels and near-exact when it's there, so a reading above zero is real: partially hydrogenated oil, some fried food, a few baked goods."
        case .addedSugar:
            return "This is the added share ONLY — the sugar put in, not the sugar that came with the fruit or the milk. That's what makes it judgeable where total sugars isn't: 40g is a real ceiling, and there's no natural-sugar confusion hiding inside it. It's label-derived and near-exact, so what you see is close to what you ate."
        case .selenium:
            return "Selenium is a range, not a floor: 55µg is the amount to reach, and 300µg is a real upper limit — one of the few nutrients where more is genuinely worse, not just wasted. Two Brazil nuts can clear the whole day. Read the number loosely: selenium in food tracks the selenium in the soil it grew in, and that varies by an order of magnitude between regions, so a database figure is the right ballpark and not a measurement of what you actually ate."
        case .vitaminD:
            return "Vitamin D is a floor to reach — it's what lets you absorb the calcium you eat, and it matters more under high-impact running. Oily fish, egg yolk, and fortified milk carry most of the dietary share; sun does the rest, and none of that sun shows up here. The food number is a solid database lookup, so a low reading means low intake FROM FOOD, which is not the same as a low blood level."
        case .purines:
            return "Purines break down into uric acid, which is what gout is about. There's no target and no red or green here: the response is individual, and for most people the diet share is a fraction of what the body makes on its own. Above roughly 500mg in a day the number is worth a glance, nothing more. Treat it as a rough species average — organ meat, anchovies, sardines, and some shellfish are high, but the spread WITHIN any one food is wide, so read the order of magnitude, never the exact figure."
        case .mercury:
            return "Mercury is judged over a rolling 7-day window, never on one day, because that's the timescale your body clears it on — one tuna steak isn't a problem, one every day is. The reference is 105µg a week. Treat the number as a rough species average: mercury varies enormously between individual fish of the same species, by size and by where it was caught, so this is the order of magnitude and never a precise figure. Big predators (swordfish, king mackerel, bigeye tuna) carry the most; salmon, sardines, and shrimp carry very little."
        }
    }
}

/// The nutrient a sub-entry hangs off in the nutrition-label tree — either a macro or
/// another micronutrient. The second case is what a two-level tree needs: added sugar is
/// a sub-entry of total sugars, which is itself a sub-entry of carbs, exactly as a label
/// prints "Total Sugars / Includes Xg Added Sugars".
enum NutrientParent: Equatable, Hashable, Sendable {
    case macro(Macro)
    case micronutrient(Micronutrient)
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

    /// Whether this row renders as an indented sub-entry of a parent nutrient — driven by
    /// the same `parent`/`isSubEntry` model on both enums.
    var isSubEntry: Bool {
        switch self {
        case .macro(let m): return m.isSubEntry
        case .micronutrient(let n): return n.isSubEntry
        }
    }

    /// How deep the row sits in the tree (0 top-level, 1 under a macro, 2 under a
    /// micronutrient). Drives the leading indent alone; the type treatment stays binary.
    var depth: Int {
        switch self {
        case .macro(let m): return m.isSubEntry ? 1 : 0
        case .micronutrient(let n): return n.depth
        }
    }
}

/// The single canonical ordering of the nutrient tree, derived from the `parent` links
/// on `Macro` and `Micronutrient` — no view hand-orders the rows. This is the one source
/// the order tests assert against.
enum NutrientOrder {
    /// The macro area's rows in canonical nutrition-label order: each top-level macro
    /// followed immediately by its sub-entries — macro sub-entries first (fiber), then
    /// micronutrient sub-entries, each of which is itself followed by ITS sub-entries.
    /// For the current tree that is Protein, Carbs, Fiber, Total Sugars, Added Sugar,
    /// Fat, Saturated Fat, Trans Fat, Unsaturated Fat, Cholesterol. Standalone
    /// micronutrients are NOT here — they live in the Micronutrients section.
    ///
    /// The recursion is what carries the second level: added sugar is discovered as a
    /// child of total sugars rather than listed by hand, so a future third level costs
    /// nothing and no view keeps an order of its own.
    static let macroArea: [NutrientEntry] = {
        var out: [NutrientEntry] = []
        func appendChildren(of parent: NutrientParent) {
            for n in Micronutrient.allCases where n.parent == parent {
                out.append(.micronutrient(n))
                appendChildren(of: .micronutrient(n))
            }
        }
        for macro in Macro.allCases where macro.parent == nil {
            out.append(.macro(macro))
            for sub in Macro.allCases where sub.parent == macro {
                out.append(.macro(sub))
            }
            appendChildren(of: .macro(macro))
        }
        return out
    }()

    /// The standalone micronutrients shown in the Micronutrients section — those with no
    /// parent, in canonical order, minus the ones that carry no day-scoped reading at all
    /// (mercury, whose limit exists only over a week — see `Micronutrient.dayScoped`).
    static let minerals: [Micronutrient] =
        Micronutrient.allCases.filter { $0.parent == nil && $0.dayScoped }

    /// The nutrients that render a trailing-window row from the snapshot's `rolling7`
    /// block, in canonical order: mercury (whose only meaningful scale is the week) and
    /// omega-3 (context alongside its day row, never a second verdict).
    static let rollingWindowed: [Micronutrient] =
        Micronutrient.allCases.filter(\.showsRollingWindow)
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
    /// A NEUTRAL note beside the row — currently purines' above-500mg line. Distinct from
    /// `flag` in both meaning and rendering: a flag is a gentle nudge to act and draws
    /// attention, a note is context on a row that is judging nothing, and it never carries
    /// a colour or an alert glyph.
    var note: String? = nil
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
    /// Where this row's COLOR came from (see `JudgmentSource`). `.daily` — today's number,
    /// which is every gauge on an older bridge and always protein/fiber/calories/carbs.
    /// `.rolling` — the buffered nutrients (saturated fat, sodium, total fat over 7 days;
    /// calcium, omega-3, magnesium, potassium over 30), where the color is the window
    /// median's band and the caption names the window.
    ///
    /// `value`, `remaining`, `goalStatus`, `partial` and the flags ALWAYS stay TODAY's, on
    /// every gauge — only `status` and `tone` follow the window. That split is the whole
    /// design: the number you ate today, colored by the pattern it belongs to.
    var judgment: JudgmentSource = .daily
    /// Set ONLY on a row the Health tab's window switcher reframed to a rolling read (7d /
    /// 30d): the window's median, its coverage, and whether that median earned a verdict.
    /// Nil on every day-scoped gauge, which then renders exactly as it always has. The row
    /// uses it for two things and no more — the window chip beside the label, and the
    /// caption on a window with nothing measured in it.
    ///
    /// Distinct from `judgment`, deliberately: `judgment` describes a row whose NUMBER is
    /// today's and whose COLOUR came from a window, which is the buffered-nutrient design.
    /// This describes a row where the number is the window's too.
    var windowRead: NutrientWindowRead? = nil
    /// Set ONLY on a row built from the snapshot's `rolling7` block, where BOTH the number
    /// and the goal belong to a trailing window of days rather than to today (mercury's
    /// weekly ceiling; omega-3's context row).
    ///
    /// A third window-ish field, and the distinctions are load-bearing. `judgment` is a row
    /// whose NUMBER is today's and whose COLOUR came from a window's median.
    /// `windowRead` is the window switcher's row, whose number is that window's MEDIAN.
    /// This is a row whose number is the window's SUM — a different statistic answering a
    /// different question, and the only one of the three that can be compared against a
    /// weekly limit.
    var rollingWindow: RollingWindowTotal? = nil
    /// Today blew through a ceiling: at/over `NutrientTrends.blowoutMultiplier` × the day's
    /// target, or over a defined daily hard cap (total fat's 70 g). A SEPARATE signal that
    /// never touches `status`/`tone` — a green rolling color and this marker coexist by
    /// design, because that is precisely the day the rolling median hides.
    var blowout: Bool = false
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
