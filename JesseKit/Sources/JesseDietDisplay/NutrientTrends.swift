import Foundation
import JesseNetworking

// The per-nutrient trend engine, as pure Foundation-only logic — no SwiftUI, no
// `Date()` read, every rule deterministically testable. It sits beside `DietSemantics`
// and `FoodContributions`: those judge ONE day; this one reasons over the
// `nutrientSeries` history (up to 90 logged days) so a chart or the coach can tell a
// standing pattern from a single binge/fast day.
//
// CORE RULE, carried verbatim from the rest of the stack: UNKNOWN IS NOT ZERO and
// unknown is not "low". A nutrient key is present in `nutrientSeries` for a day ONLY
// when at least one item that day carried a known value; an all-unknown day is a GAP
// (the key is absent). Every computation here runs ONLY over the days where the
// nutrient key is present. A gap day is NEVER treated as 0, NEVER counts as a day
// under a floor or over a ceiling, and NEVER interpolated across. Coverage
// (days known / logged days in the window) rides alongside every verdict so a thin
// reading can be hedged instead of asserted.

// MARK: - Nutrient model (single source of truth)

/// How a nutrient is judged over time. Mirrors `DietSemantics.Goal` but adds `target`
/// (a value to sit near, e.g. calories/fat/carbs) and `informational` (shown, never
/// judged — total sugars, unsaturated fat).
enum TrendKind: Equatable, Sendable {
    /// Reach it (protein, fiber, potassium, calcium, omega-3, magnesium). Rising is good.
    case floor
    /// Stay under it (sodium, saturated fat). Falling is good.
    case ceiling
    /// Sit near it, neither far under nor far over (calories, fat, carbs). Closer is good.
    case target
    /// Composition only (total sugars, unsaturated fat). A direction, never a good/bad label.
    case informational
}

/// How long a window a nutrient's PASS/FAIL COLOR is judged over. This is a THIRD
/// question, deliberately distinct from the two the model already answers: `kind` says
/// which way a nutrient is drifting, `dayGoal` says whether ONE day was good, and this
/// says how many days the gauge's color is allowed to average over before it calls today
/// a problem.
enum JudgmentWindow: Equatable, Sendable {
    /// Judged on today's number alone — the pre-existing single-day behavior.
    case daily
    /// Judged on the MEDIAN of the KNOWN days in the trailing window (a gap is never a 0,
    /// so it never counts toward the median).
    case rolling(days: Int)

    /// The window length in days, nil when daily.
    var days: Int? {
        switch self {
        case .daily: return nil
        case .rolling(let d): return d
        }
    }

    /// The short caption a rolling gauge shows ("7d"/"30d") so the color is never read as
    /// a verdict on today's number. Nil when daily — there is nothing to caption.
    var caption: String? { days.map { "\($0)d" } }

    var isRolling: Bool { days != nil }
}

/// Where a gauge's pass/fail COLOR came from. Carried on the gauge so the row can SAY it:
/// a rolling color beside today's number is only honest if the window is named.
enum JudgmentSource: Equatable, Sendable {
    /// Today's number alone — the daily-judged nutrients, and every nutrient when the
    /// bridge sends no `nutrientSeries` (the graceful-degrade path).
    case daily
    /// The median of the window's known days. `caption` is the "7d"/"30d" chip.
    case rolling(caption: String, daysKnown: Int)
    /// The window exists but carries too few known days to assert a pattern, so the color
    /// fell back to TODAY's number and the row says so rather than claiming a trend.
    case thinWindow(caption: String, daysKnown: Int)

    /// The window caption, for either rolling state; nil for a daily judgment.
    var caption: String? {
        switch self {
        case .daily: return nil
        case .rolling(let c, _), .thinWindow(let c, _): return c
        }
    }
    /// True when the color really is the window's median (not today's number).
    var isRolling: Bool { if case .rolling = self { return true } else { return false } }
    /// True when a rolling nutrient fell back to today's number for want of known days.
    var isThinWindow: Bool { if case .thinWindow = self { return true } else { return false } }
}

/// The thirteen nutrients the trend engine plots and the coach reasons over — the
/// SINGLE source of truth for each one's key, full name, unit, kind, and the curated
/// insight copy (why it matters + good sources) that grounds every health claim so the
/// model never invents one. This mirrors the `Macro`/`Micronutrient` display-name
/// enums (each spells its own names, guarded by a label test) and extends them with
/// the history-wide `nutrientSeries` key and the coaching copy.
///
/// The raw value IS the bridge's `nutrientSeries` nutrient key, so `nutrients[key]`
/// looks a day up directly.
enum TrendNutrient: String, CaseIterable, Identifiable, Sendable {
    case cal, p, f, c, fiber, na, satf, sug, k, ca, o3, mg, unsat

    var id: String { rawValue }

    /// The bridge's short nutrient key in `nutrientSeries` (identical to the raw value).
    var key: String { rawValue }

    /// The full, unabbreviated user-facing name — spelled here and nowhere else, matching
    /// the `Macro`/`Micronutrient` names for the overlapping nutrients (guarded by a test).
    var fullName: String {
        switch self {
        case .cal: return "Calories"
        case .p: return "Protein"
        case .f: return "Fat"
        case .c: return "Carbs"
        case .fiber: return "Fiber"
        case .na: return "Sodium"
        case .satf: return "Saturated Fat"
        case .sug: return "Total Sugars"
        case .k: return "Potassium"
        case .ca: return "Calcium"
        case .o3: return "Omega-3 (EPA+DHA)"
        case .mg: return "Magnesium"
        case .unsat: return "Unsaturated Fat"
        }
    }

    /// The display unit: energy in kcal, the minerals and omega-3 in milligrams, the
    /// macros/fats/sugars in grams.
    var unit: String {
        switch self {
        case .cal: return "kcal"
        case .na, .k, .ca, .o3, .mg: return "mg"
        case .p, .f, .c, .fiber, .satf, .sug, .unsat: return "g"
        }
    }

    /// How this nutrient is judged over time (see `TrendKind`).
    var kind: TrendKind {
        switch self {
        case .cal, .f, .c: return .target
        case .p, .fiber, .k, .ca, .o3, .mg: return .floor
        case .na, .satf: return .ceiling
        case .sug, .unsat: return .informational
        }
    }

    /// The nutrient's NORMAL-day judged goal, used to color one plotted day with the SAME
    /// status band the daily gauge uses — so a day's dot on the trend and its bar on the
    /// Today screen never disagree (`NutrientTrends.dayStatus`). Nil for the informational
    /// nutrients (total sugars, unsaturated fat), which the daily gauge also never judges;
    /// they plot in a neutral tone. Calories read as a ceiling and carbs as a floor — the
    /// normal-day treatment, the only one history can assume (the per-day style isn't in
    /// `nutrientSeries`); fat is the 50–65 g window. This is deliberately DISTINCT from
    /// `kind`, which drives the trend DIRECTION (where calories "sit near" a target):
    /// `dayGoal` answers "was this day good?", `kind` answers "which way is it drifting?".
    var dayGoal: DietSemantics.Goal? {
        switch self {
        case .p, .fiber, .c, .k, .ca, .o3, .mg: return .floor
        case .cal, .na, .satf: return .ceiling
        case .f: return .window
        case .sug, .unsat: return nil
        }
    }

    /// The goal GLYPH a row shows for this nutrient (≥ floor, ≤ ceiling, ↕ window). For a
    /// judged nutrient it is simply `dayGoal`. The two informational nutrients carry no
    /// `dayGoal` at all — they are never judged — but a row still has to draw a glyph, so
    /// they take the direction their `Micronutrient` twin already shows: total sugars reads
    /// as a ceiling, unsaturated fat (the good-fat share) as a floor. A glyph is a
    /// direction, never a verdict; the colour is what an informational row withholds.
    var displayGoal: DietSemantics.Goal {
        switch self {
        case .sug: return .ceiling
        case .unsat: return .floor
        default: return dayGoal ?? .floor
        }
    }

    /// How long a window this nutrient's gauge COLOR is judged over (see `JudgmentWindow`).
    /// The value stays today's on every gauge; only the color's window changes.
    ///
    /// DAILY — protein, fiber, calories, carbs. Protein and fiber are daily DELIBERATELY,
    /// and the deficit is the reason: a floor averaged over a week hides the low days that
    /// are exactly the ones that matter. Three 60 g protein days and four 160 g days
    /// median out to a comfortable number while the three thin days are where lean mass
    /// and recovery are actually lost; the same argument holds for fiber's digestion and
    /// satiety. A floor you must clear TODAY cannot be paid back on Friday, so it is
    /// judged today. Calories and carbs are the day's plan, likewise judged against the
    /// day they belong to.
    ///
    /// ROLLING 7 — saturated fat, sodium, total fat. These genuinely buffer: LDL and blood
    /// pressure answer to the week, not to one cheese board or one bowl of ramen, and a
    /// single red day on a body that is otherwise fine is a false alarm that teaches the
    /// gauge to be ignored. A week is long enough to smooth a meal out and short enough
    /// that a real drift shows up while it can still be corrected.
    ///
    /// ROLLING 30 — calcium, omega-3, magnesium, potassium. Body stores and the label data
    /// both argue for the month: these are stored/regulated on a scale of weeks, and they
    /// are the nutrients food labels most often omit, so a week rarely holds enough KNOWN
    /// days to say anything. Thirty days gathers the coverage a verdict needs.
    ///
    /// The informational nutrients (total sugars, unsaturated fat) carry no verdict at all,
    /// so this is never consulted for them; they answer `.daily` only because the property
    /// is total.
    var judgmentWindow: JudgmentWindow {
        switch self {
        case .p, .fiber, .cal, .c: return .daily
        case .satf, .na, .f: return .rolling(days: 7)
        case .ca, .o3, .mg, .k: return .rolling(days: 30)
        case .sug, .unsat: return .daily // informational — never judged, never consulted
        }
    }

    /// The nutrient's HARD same-day cap in its own unit, where the daily gauge defines one:
    /// total fat's 70 g cap (`DietSemantics.fatHardCap`), the line the normal-day fat window
    /// already treats as "take note" rather than a nudge. Nil for every other nutrient —
    /// their same-day line is a multiple of the day's target instead (see
    /// `NutrientTrends.blowout`).
    var dailyHardCap: Double? { self == .f ? DietSemantics.fatHardCap : nil }

    /// Whether a SAME-DAY blow-out can be flagged for this nutrient at all: the two ceiling
    /// nutrients (sodium, saturated fat) plus total fat via its hard cap. A floor cannot be
    /// blown out — going far OVER a floor is not a problem — and an informational nutrient
    /// carries no line to cross.
    var hasSameDayCeiling: Bool { kind == .ceiling || dailyHardCap != nil }

    /// This nutrient's reference target from the day's targets object, or nil when the
    /// snapshot carries none (then the trend renders value-only, with NO judgment). Total
    /// sugars' target is an optional reference line only (informational — never a
    /// ceiling); unsaturated fat is derived and never carries a target.
    func target(in t: DietTargets) -> Double? {
        switch self {
        case .cal: return t.calories
        case .p: return t.protein
        case .f: return t.fat
        case .c: return t.carbs
        case .fiber: return t.fiber
        case .na: return t.sodium
        case .satf: return t.satFat
        case .sug: return t.sugar
        case .k: return t.potassium
        case .ca: return t.calcium
        case .o3: return t.omega3
        case .mg: return t.magnesium
        case .unsat: return nil
        }
    }

    /// This nutrient's per-item value (nil = UNKNOWN for that item, never 0), used to rank
    /// the foods that fed it over a range. Unsaturated fat is DERIVED — `fat − saturated
    /// fat`, known only when saturated fat is known — mirroring `Micronutrient`.
    func value(in item: DietItem) -> Double? {
        switch self {
        case .cal: return item.cal
        case .p: return item.p
        case .f: return item.f
        case .c: return item.c
        case .fiber: return item.fiber
        case .na: return item.na
        case .satf: return item.satf
        case .sug: return item.sug
        case .k: return item.k
        case .ca: return item.ca
        case .o3: return item.o3
        case .mg: return item.mg
        case .unsat: return item.satf.map { (item.f ?? 0) - $0 }
        }
    }

    /// The drill-down metric this nutrient maps to, so top-sources reuses the SAME
    /// contributor math the per-day drill-down uses.
    var contributionMetric: ContributionMetric {
        switch self {
        case .cal: return .calories
        case .p: return .macro(.protein)
        case .f: return .macro(.fat)
        case .c: return .macro(.carbs)
        case .fiber: return .macro(.fiber)
        case .na: return .micronutrient(.sodium)
        case .satf: return .micronutrient(.saturatedFat)
        case .sug: return .micronutrient(.totalSugars)
        case .k: return .micronutrient(.potassium)
        case .ca: return .micronutrient(.calcium)
        case .o3: return .micronutrient(.omega3)
        case .mg: return .micronutrient(.magnesium)
        case .unsat: return .micronutrient(.unsaturatedFat)
        }
    }

    /// One short, curated sentence on the consequence of chronically missing (a floor) or
    /// exceeding (a ceiling) this nutrient — grounding so neither the chart summary nor the
    /// coach invents a health claim. Tuned for a 51-year-old marathon runner in a calorie
    /// deficit; first-pass copy, meant to be reviewed and adjusted later.
    var whyItMatters: String {
        switch self {
        case .p: return "Falling short in a deficit costs lean mass and slows recovery."
        case .fiber: return "Low fiber hurts digestion, satiety, and cholesterol."
        case .na: return "Chronically high sodium raises blood pressure and urinary calcium loss, though a heavy-sweat runner needs some."
        case .satf: return "Sustained high saturated fat raises LDL and cardiovascular risk."
        case .sug: return "Fruit and dairy sugar is fine; added sugar drives energy swings."
        case .k: return "Low potassium worsens blood pressure, cramps, and recovery."
        case .ca: return "Low calcium risks bone loss, which matters under high-impact running at 51."
        case .o3: return "Low marine omega-3 means less anti-inflammatory and cardiovascular support."
        case .mg: return "Low magnesium worsens cramps, sleep, and energy metabolism."
        case .cal: return "Too far under stalls recovery and performance; too far over stalls the cut."
        case .f: return "Too low hurts hormones and satiety; keep most of it unsaturated."
        case .c: return "Carbs are the endurance runner's fuel; too low tanks long runs."
        case .unsat: return "The good-fat share of total fat; a higher share is better."
        }
    }

    /// A short list of real foods rich in this nutrient — grounding so improvement ideas
    /// name actual high-nutrient foods, not a guess. For the two informational nutrients
    /// this is context, not a to-do.
    var goodSources: [String] {
        switch self {
        case .p: return ["meat", "fish", "eggs", "dairy", "legumes", "tofu"]
        case .fiber: return ["whole grains", "legumes", "vegetables", "fruit", "nuts"]
        case .na: return ["salt", "cured meats", "cheese", "bread", "packaged food"]
        case .satf: return ["fatty meat", "butter", "cheese", "cream", "coconut and palm oil"]
        case .sug: return ["fruit", "dairy", "sweets", "sweetened drinks"]
        case .k: return ["potatoes", "beans", "leafy greens", "banana", "yogurt", "tomato"]
        case .ca: return ["dairy", "leafy greens", "sardines", "tofu", "fortified foods"]
        case .o3: return ["oily fish (salmon, sardines, mackerel, anchovy)", "roe"]
        case .mg: return ["pumpkin seeds", "dark chocolate", "nuts", "legumes", "leafy greens", "whole grains"]
        case .cal: return ["balance to the day's plan"]
        case .f: return ["olive oil", "nuts", "avocado", "fish", "seeds"]
        case .c: return ["grains", "potatoes", "fruit", "legumes"]
        case .unsat: return ["olive oil", "nuts", "avocado", "oily fish"]
        }
    }

    /// The good-sources list as a single comma-joined phrase for a one-line hint.
    var goodSourcesText: String { goodSources.joined(separator: ", ") }

    /// The trend nutrient a drill-down metric maps to — the inverse of
    /// `contributionMetric`, so a tapped gauge can push its own trend. Total across every
    /// metric (calories, the four macros, the eight micronutrients), so it never fails.
    init(metric: ContributionMetric) {
        switch metric {
        case .calories: self = .cal
        case .macro(.protein): self = .p
        case .macro(.fat): self = .f
        case .macro(.carbs): self = .c
        case .macro(.fiber): self = .fiber
        case .micronutrient(.sodium): self = .na
        case .micronutrient(.saturatedFat): self = .satf
        case .micronutrient(.totalSugars): self = .sug
        case .micronutrient(.potassium): self = .k
        case .micronutrient(.calcium): self = .ca
        case .micronutrient(.omega3): self = .o3
        case .micronutrient(.magnesium): self = .mg
        case .micronutrient(.unsaturatedFat): self = .unsat
        }
    }
}

/// Everything `NutrientTrendDetail` needs to draw and summarize one nutrient behind a
/// drill-down tap: which nutrient, the whole history series, the day's targets, and the
/// per-day food detail the app has (the loaded day) for the top-sources line. Rides on
/// `FoodDrilldown` so the trend lives one tap deeper, exactly like the weight trend lives
/// behind the weight card.
struct NutrientTrendContext: Equatable, Sendable {
    let nutrient: TrendNutrient
    let series: [NutrientDay]
    let targets: DietTargets
    let meals: [DietMeal]
}

// MARK: - Trend direction

/// The direction a nutrient is moving over a window, already classified RELATIVE TO the
/// nutrient's kind. For a judged nutrient (floor/ceiling/target) it is `improving` /
/// `worsening` / `flat`; for an informational one it is the neutral `rising` / `falling`
/// / `flat` with no good/bad label. Below the minimum known-day count it is
/// `notEnoughData` — no direction may be asserted.
enum TrendDirection: Equatable, Sendable {
    case improving
    case worsening
    case rising
    case falling
    case flat
    case notEnoughData

    /// The plain-language label for a verdict line.
    var label: String {
        switch self {
        case .improving: return "improving"
        case .worsening: return "worsening"
        case .rising: return "rising"
        case .falling: return "falling"
        case .flat: return "flat"
        case .notEnoughData: return "not enough data"
        }
    }
}

// MARK: - Result types

/// One plottable day: a known value on a date, and whether the day was PARTIAL (at least
/// one item that day lacked the value, so `value` is a lower bound). Gap days are simply
/// absent from the points list — never a point at 0.
struct NutrientTrendPoint: Equatable, Sendable, Identifiable {
    /// The ISO `yyyy-MM-dd` date — unique within a series, so a stable `ForEach` identity.
    let date: String
    let value: Double
    let isPartial: Bool
    var id: String { date }
}

/// One food that fed a nutrient over the visible range, with its summed KNOWN
/// contribution. Ranked most-impact first; unknown/zero items never appear.
struct NutrientSource: Equatable, Sendable, Identifiable {
    let name: String
    let value: Double
    var id: String { name }
}

/// The full analysis of one nutrient over one window: the plottable points, coverage,
/// the distribution, the floor/ceiling counts, and the kind-relative direction. Every
/// field is computed over KNOWN days only.
struct NutrientTrend: Equatable, Sendable {
    let nutrient: TrendNutrient
    let kind: TrendKind
    /// The reference target, or nil when the snapshot carries none (value-only, no judgment).
    let target: Double?
    let unit: String
    /// The window in days, or nil for "all available".
    let windowDays: Int?
    /// Known days in the window, ascending by date, gap days absent.
    let points: [NutrientTrendPoint]
    /// Days this nutrient was known in the window.
    let daysKnown: Int
    /// Logged days in the window (any food that day), the coverage denominator. Because
    /// the bridge omits a day with no known nutrient at all, this is the count of
    /// `nutrientSeries` entries inside the window — the documented proxy for "days with
    /// food logged", so coverage reflects logging gaps too.
    let daysInWindow: Int
    /// Median of the known values (resists a single binge/fast day). Nil when no known days.
    let median: Double?
    /// Smallest / largest known value — the distribution edges (the whole story for an
    /// informational nutrient). Nil when no known days.
    let minKnown: Double?
    let maxKnown: Double?
    /// How many known days were partial (a lower bound).
    let partialCount: Int
    /// Known days strictly under the target (the floor stat; 0 without a target).
    let countUnderTarget: Int
    /// Known days strictly over the target (the ceiling stat; 0 without a target).
    let countOverTarget: Int
    /// The kind-relative direction over the window (see `TrendDirection`).
    let direction: TrendDirection

    /// At least one known day to speak to.
    var hasData: Bool { daysKnown > 0 }

    /// Coverage as a fraction (known / logged days in window), nil when no logged days.
    var coverageFraction: Double? {
        daysInWindow > 0 ? Double(daysKnown) / Double(daysInWindow) : nil
    }

    /// Fraction of known days under the floor — only meaningful for a floor with a target.
    var pctUnderTarget: Double? {
        guard kind == .floor, target != nil, daysKnown > 0 else { return nil }
        return Double(countUnderTarget) / Double(daysKnown)
    }

    /// Fraction of known days over the ceiling — only meaningful for a ceiling with a target.
    var pctOverTarget: Double? {
        guard kind == .ceiling, target != nil, daysKnown > 0 else { return nil }
        return Double(countOverTarget) / Double(daysKnown)
    }

    /// Signed distance of the median from the target (median − target; negative = under) —
    /// the headline stat for a target-kind nutrient. Nil without a median or target.
    var medianDistanceFromTarget: Double? {
        guard let median, let target else { return nil }
        return median - target
    }

    /// A STANDING problem: a judged floor under target (or ceiling over it) on MOST known
    /// days, with enough coverage to say so. Drives the coach's per-problem consequence +
    /// sources + fix guidance. Informational and target-kind nutrients are never "problems".
    var isStandingProblem: Bool {
        guard daysKnown >= NutrientTrends.minKnownForDirection else { return false }
        if let pct = pctUnderTarget { return pct >= 0.5 }
        if let pct = pctOverTarget { return pct >= 0.5 }
        return false
    }
}

// MARK: - Engine

public enum NutrientTrends {
    /// The minimum known-day count before a direction may be asserted or a standing
    /// problem called — below it, "not enough data".
    static let minKnownForDirection = 6

    /// A UTC gregorian `yyyy-MM-dd` parser, matching `WeightTrendDetail`'s so the window
    /// math lines up across the app.
    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Whether the trend affordance should show at all: the field is present and carries at
    /// least one day. On an older bridge (absent/empty) the affordance hides — no crash.
    public static func isAvailable(_ series: [NutrientDay]?) -> Bool {
        (series?.isEmpty == false)
    }

    /// The series sorted ascending by date, dropping any row whose date doesn't parse.
    static func sorted(_ series: [NutrientDay]) -> [NutrientDay] {
        series
            .filter { dayParser.date(from: $0.date) != nil }
            .sorted { ($0.date) < ($1.date) }
    }

    /// The `nutrientSeries` entries inside the most-recent `windowDays` CALENDAR days, anchored
    /// on `anchor` (a nil `anchor` falls back to the last logged day; a nil `windowDays` = all).
    /// The window is `[anchor − (windowDays − 1), anchor]`, INCLUSIVE on both ends — the upper
    /// bound matters when the anchor is a nutrient's OWN last reading, which can sit before the
    /// last logged day, so the window must not spill into later nutrient-less days. `series`
    /// must be ascending.
    static func windowed(_ series: [NutrientDay], windowDays: Int?, anchor: Date? = nil) -> [NutrientDay] {
        guard let windowDays,
              let anchorDate = anchor ?? series.last.flatMap({ dayParser.date(from: $0.date) }),
              let cutoff = utcCalendar.date(byAdding: .day, value: -(windowDays - 1), to: anchorDate)
        else { return series }
        return series.filter {
            guard let d = dayParser.date(from: $0.date) else { return false }
            return d >= cutoff && d <= anchorDate
        }
    }

    /// The median of a set of values, or nil when empty. The even-count median averages
    /// the two middle values.
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Classify the direction of the ascending known values RELATIVE TO the nutrient's kind
    /// by comparing the median of the earlier half to the later half. Below the minimum
    /// known-day count → `.notEnoughData`. A change within 5% of the target (or, absent a
    /// target, 5% of the overall median magnitude) reads as `.flat`.
    static func direction(for nutrient: TrendNutrient, values: [Double], target: Double?) -> TrendDirection {
        guard values.count >= minKnownForDirection else { return .notEnoughData }
        let mid = values.count / 2
        let earlier = Array(values.prefix(mid))
        let later = Array(values.suffix(values.count - mid))
        guard let em = median(earlier), let lm = median(later) else { return .notEnoughData }

        let scale = target ?? (median(values).map(abs) ?? 0)
        let epsilon = scale * 0.05

        switch nutrient.kind {
        case .floor, .ceiling:
            let delta = lm - em
            if abs(delta) <= epsilon { return .flat }
            let rising = delta > 0
            if nutrient.kind == .floor { return rising ? .improving : .worsening }
            return rising ? .worsening : .improving
        case .informational:
            let delta = lm - em
            if abs(delta) <= epsilon { return .flat }
            return delta > 0 ? .rising : .falling
        case .target:
            guard let target else {
                // No target to sit near → report the neutral direction only.
                let delta = lm - em
                if abs(delta) <= epsilon { return .flat }
                return delta > 0 ? .rising : .falling
            }
            // Closer to target is improving; farther is worsening.
            let dd = abs(lm - target) - abs(em - target)
            if abs(dd) <= epsilon { return .flat }
            return dd < 0 ? .improving : .worsening
        }
    }

    /// Analyze ONE nutrient over ONE window from the decoded `nutrientSeries` and the day's
    /// targets. Everything is computed over the days the nutrient is PRESENT — a gap is
    /// never a 0, never an under-floor/over-ceiling day.
    static func analyze(_ series: [NutrientDay], nutrient: TrendNutrient,
                        targets: DietTargets, windowDays: Int?) -> NutrientTrend {
        let ordered = sorted(series)
        // Anchor the window on THIS nutrient's most recent known day — not the last day ANY
        // nutrient was logged. A rarely-labeled nutrient (omega-3, magnesium, calcium…) is
        // known only occasionally, so anchoring on the global last log would read empty at a
        // short range whenever it wasn't logged in the last calendar week; anchoring on its
        // own last reading always shows its recent tail. This mirrors the weight chart, whose
        // series is weigh-ins only and so already anchors on its own data. Falls back to the
        // last logged day when the nutrient is never known (then the window has no points
        // regardless).
        let anchor = ordered.last { ($0.nutrients[nutrient.key]?.known ?? 0) >= 1 }
            .flatMap { dayParser.date(from: $0.date) }
        let window = windowed(ordered, windowDays: windowDays, anchor: anchor)
        let target = nutrient.target(in: targets)

        var points: [NutrientTrendPoint] = []
        for day in window {
            // A nutrient ABSENT from the day's map is a GAP — skip it entirely (never a 0).
            guard let v = day.nutrients[nutrient.key], v.known >= 1 else { continue }
            points.append(NutrientTrendPoint(date: day.date, value: v.sum, isPartial: v.unknown > 0))
        }

        let values = points.map(\.value)
        let daysKnown = points.count
        let med = median(values)

        var countUnder = 0, countOver = 0
        if let target {
            for v in values {
                if v < target { countUnder += 1 }
                if v > target { countOver += 1 }
            }
        }

        return NutrientTrend(
            nutrient: nutrient, kind: nutrient.kind, target: target, unit: nutrient.unit,
            windowDays: windowDays, points: points,
            daysKnown: daysKnown, daysInWindow: window.count,
            median: med, minKnown: values.min(), maxKnown: values.max(),
            partialCount: points.filter(\.isPartial).count,
            countUnderTarget: countUnder, countOverTarget: countOver,
            direction: direction(for: nutrient, values: values, target: target))
    }

    // MARK: - Per-day goal status (chart coloring)

    /// The color-status band for ONE plotted day, delegating to the daily gauge's own band
    /// functions (`DietSemantics.floorStatus`/`ceilingStatus`/`fatWindowStatus`) so a trend
    /// dot matches the color the Today bar would give that value. The nutrient's `dayGoal`
    /// picks the band; an informational nutrient (no `dayGoal`) or a missing/zero target is
    /// neutral (`.suspended`), never a red/green claim.
    ///
    /// A PARTIAL day's `value` is a lower bound (unknown contributors weren't counted), so a
    /// judgment is asserted ONLY in the direction the lower bound already PROVES — a floor
    /// already cleared reads good, a ceiling already breached reads bad — and every other
    /// partial day stays neutral rather than claim a band its unknowns could overturn.
    static func dayStatus(_ nutrient: TrendNutrient, value: Double, isPartial: Bool,
                          target: Double?) -> DietSemantics.Status {
        guard let goal = nutrient.dayGoal else { return .suspended }
        switch goal {
        case .floor:
            guard let target, target > 0 else { return .suspended }
            let s = DietSemantics.floorStatus(value: value, target: target)
            // A partial floor is only PROVEN once the known-only floor already clears target.
            return isPartial ? (s == .green ? .green : .suspended) : s
        case .ceiling:
            guard let target, target > 0 else { return .suspended }
            let s = DietSemantics.ceilingStatus(value: value, target: target)
            // A partial ceiling is only PROVEN once the known-only floor already exceeds it.
            return isPartial ? (s == .red ? .red : .suspended) : s
        case .window:
            // The fat window is fixed grams (50–65 green, to 70 yellow), independent of the
            // day's target — matching the normal-day fat gauge. A partial day can only be
            // proven bad when even the known-only floor already clears the hard cap.
            let s = DietSemantics.fatWindowStatus(grams: value)
            return isPartial ? (value > DietSemantics.fatHardCap ? .red : .suspended) : s
        }
    }

    /// A short under/on/over phrase for a plotted day's scrub readout — the SAME judgment the
    /// color encodes, in words, so color is never the only signal (accessibility). Nil when
    /// the day carries no judgment: an informational nutrient, no usable target, or a partial
    /// day whose unknowns leave the band undecided.
    static func dayStatusPhrase(_ nutrient: TrendNutrient, value: Double, isPartial: Bool,
                                target: Double?) -> String? {
        guard let goal = nutrient.dayGoal else { return nil }
        switch dayStatus(nutrient, value: value, isPartial: isPartial, target: target) {
        case .suspended:
            return nil
        case .green:
            switch goal { case .floor: return "at or above floor"
                          case .ceiling: return "under ceiling"; case .window: return "in range" }
        case .yellow:
            switch goal { case .floor: return "near floor"
                          case .ceiling: return "near ceiling"; case .window: return "near cap" }
        case .red:
            switch goal { case .floor: return "under floor"
                          case .ceiling: return "over ceiling"; case .window: return "out of range" }
        }
    }

    // MARK: - Rolling gauge verdict (the gauge's COLOR)

    /// The gauge judgment for one nutrient: the band its color comes from, the goal outcome
    /// behind that band (so the caller derives the display tone through the SAME
    /// `DietSemantics.tone` path every daily gauge uses), and where the color came from.
    ///
    /// The judged VALUE here is not necessarily today's: on a rolling nutrient it is the
    /// window's median. The gauge still DISPLAYS today's number — only the color moves.
    struct NutrientJudgment: Equatable, Sendable {
        /// The band the gauge colors from.
        let status: DietSemantics.Status
        /// The goal outcome behind that band (met / short / over / no-goal).
        let goalStatus: DietSemantics.GoalStatus
        /// Whether the judged value breached a hard cap (the 70 g total-fat cap).
        let hardOver: Bool
        /// Where the color came from — today, the window's median, or today because the
        /// window was too thin to assert a pattern.
        let source: JudgmentSource
        /// The value that was judged: the window median, or today's total otherwise.
        let judgedValue: Double
        /// Known days in the rolling window (0 on a daily judgment).
        let daysKnown: Int
    }

    /// The band + goal outcome for ONE value under a nutrient's `dayGoal`, straight through
    /// the daily gauge's own helpers. This is the single place the rolling verdict and the
    /// daily one meet: both call this, so the thresholds exist once and the two can never
    /// drift apart. A nutrient with no `dayGoal` (informational) or no usable target makes
    /// NO claim.
    static func bands(_ nutrient: TrendNutrient, value: Double, target: Double?)
        -> (status: DietSemantics.Status, goalStatus: DietSemantics.GoalStatus, hardOver: Bool) {
        guard let goal = nutrient.dayGoal else { return (.suspended, .noGoal, false) }
        switch goal {
        case .floor:
            guard let target, target > 0 else { return (.suspended, .noGoal, false) }
            return (DietSemantics.floorStatus(value: value, target: target),
                    DietSemantics.floorGoalStatus(value: value, target: target), false)
        case .ceiling:
            guard let target, target > 0 else { return (.suspended, .noGoal, false) }
            return (DietSemantics.ceilingStatus(value: value, target: target),
                    DietSemantics.ceilingGoalStatus(value: value, target: target), false)
        case .window:
            // Total fat: the fixed 50–65 g window with its 70 g hard cap, independent of the
            // day's target — the same band the normal-day fat gauge uses.
            return (DietSemantics.fatWindowStatus(grams: value),
                    DietSemantics.fatWindowGoalStatus(grams: value),
                    value > DietSemantics.fatHardCap)
        }
    }

    /// THE gauge verdict for one nutrient under its `judgmentWindow`.
    ///
    /// * A DAILY nutrient (protein, fiber, calories, carbs) is judged on `todayValue`
    ///   through the very same helpers as before — byte-identical to the single-day path.
    /// * A ROLLING nutrient is judged on the MEDIAN of the known days in its window: a
    ///   ceiling reads green when the median sits comfortably under target, yellow near it,
    ///   red over; a floor is the mirror; total fat reuses the fat window against the
    ///   median. Gaps are never counted (see `analyze`).
    /// * A rolling nutrient with FEWER than `minKnownForDirection` known days in the window
    ///   has no pattern to assert, so it falls back to today's number and is marked
    ///   `.thinWindow` — the UI says "not enough days yet" instead of claiming a trend.
    /// * No `nutrientSeries` at all (an older bridge) → every nutrient is daily. No crash,
    ///   no caption, no behavior change.
    static func judgment(for nutrient: TrendNutrient, todayValue: Double,
                         series: [NutrientDay]?, targets: DietTargets) -> NutrientJudgment {
        let target = nutrient.target(in: targets)
        let today = bands(nutrient, value: todayValue, target: target)
        func daily(_ source: JudgmentSource, daysKnown: Int = 0) -> NutrientJudgment {
            NutrientJudgment(status: today.status, goalStatus: today.goalStatus,
                             hardOver: today.hardOver, source: source,
                             judgedValue: todayValue, daysKnown: daysKnown)
        }
        // A nutrient that makes no claim today (informational, or no usable target) makes
        // none over a window either — a caption there would advertise a verdict that isn't.
        guard case .rolling(let days) = nutrient.judgmentWindow,
              today.goalStatus != .noGoal,
              let series, isAvailable(series),
              let caption = nutrient.judgmentWindow.caption
        else { return daily(.daily) }

        let t = analyze(series, nutrient: nutrient, targets: targets, windowDays: days)
        guard t.daysKnown >= minKnownForDirection, let median = t.median else {
            return daily(.thinWindow(caption: caption, daysKnown: t.daysKnown),
                         daysKnown: t.daysKnown)
        }
        let rolling = bands(nutrient, value: median, target: target)
        return NutrientJudgment(status: rolling.status, goalStatus: rolling.goalStatus,
                                hardOver: rolling.hardOver,
                                source: .rolling(caption: caption, daysKnown: t.daysKnown),
                                judgedValue: median, daysKnown: t.daysKnown)
    }

    // MARK: - Same-day blow-out (a separate signal, never the verdict)

    /// Today's total at or above this multiple of a ceiling nutrient's DAILY target is a
    /// blow-out: a single day loud enough to name even when the rolling color is green.
    ///
    /// 1.5 is the tuned line, not an arbitrary one. Against a 22 g saturated-fat target it
    /// catches a 34 g day (a cheese board, a fatty cut) and leaves a mild 25 g day alone —
    /// which is the whole point of buffering the color in the first place: if every 25 g day
    /// raised a marker, the marker would mean "most days" and be ignored. The multiplier is
    /// deliberately one number in one place, so it can be tuned after living with it.
    static let blowoutMultiplier = 1.5

    /// One nutrient's same-day blow-out: what it was, today's KNOWN total, and which line it
    /// crossed. This NEVER feeds the rolling verdict — it is a parallel signal, so a green
    /// 7-day color and a blow-out marker can (and should) coexist on the same row.
    struct NutrientBlowout: Equatable, Sendable {
        let nutrient: TrendNutrient
        /// Today's KNOWN total (an unknown item is never a 0, so this is a lower bound).
        let value: Double
        /// The day's target the multiple is measured against, when the day carries one.
        let target: Double?
        /// `value / target`, nil for a nutrient judged only against a hard cap.
        let multiple: Double?
        /// True when a defined daily hard cap (total fat's 70 g) was crossed.
        let overHardCap: Bool
    }

    /// Today's blow-out for one nutrient, or nil. Two independent triggers, either sufficient:
    /// at/over `blowoutMultiplier` × the day's target (ceiling nutrients), or over a defined
    /// daily hard cap (total fat's 70 g). A floor nutrient can never blow out.
    static func blowout(_ nutrient: TrendNutrient, todayValue: Double,
                        targets: DietTargets) -> NutrientBlowout? {
        guard nutrient.hasSameDayCeiling else { return nil }
        let target = nutrient.target(in: targets)
        let overHardCap = nutrient.dailyHardCap.map { todayValue > $0 } ?? false
        // The multiple is a CEILING nutrient's rule. Total fat's same-day line is its hard
        // cap (a multiple of the fat target would sit far above it and never fire first).
        let multiple: Double? = (nutrient.kind == .ceiling && (target ?? 0) > 0)
            ? todayValue / target! : nil
        guard overHardCap || (multiple ?? 0) >= blowoutMultiplier else { return nil }
        return NutrientBlowout(nutrient: nutrient, value: todayValue, target: target,
                               multiple: multiple, overHardCap: overHardCap)
    }

    /// Today's KNOWN total for one nutrient across the day's meals — the same unknown-aware
    /// aggregate the daily gauges use (an item without the value is UNKNOWN, never a 0).
    static func todayTotal(_ nutrient: TrendNutrient, meals: [DietMeal]) -> MicronutrientTotal {
        DietSemantics.micronutrientTotal(for: meals, nutrient.value(in:))
    }

    /// Every nutrient that blew out TODAY, in canonical nutrient order. An untracked
    /// nutrient (no item carried a value) never appears — unknown is not a blow-out.
    static func blowouts(meals: [DietMeal], targets: DietTargets) -> [NutrientBlowout] {
        TrendNutrient.allCases.compactMap { n in
            guard n.hasSameDayCeiling else { return nil }
            let agg = todayTotal(n, meals: meals)
            guard agg.tracked else { return nil }
            return blowout(n, todayValue: agg.knownSum, targets: targets)
        }
    }

    /// The coach's SAME-DAY blow-out line, or nil on an ordinary day. Deliberately short and
    /// distinct from the rolling rollup: the rollup is about persistent patterns, and a
    /// median's whole job is to smooth a single loud day away — which is exactly the day the
    /// coach should be able to mention. E.g.
    /// "TODAY RAN HOT (one day, not a pattern): saturated fat 34 g (1.5x the 22 g target)."
    static func blowoutLine(meals: [DietMeal], targets: DietTargets) -> String? {
        let hits = blowouts(meals: meals, targets: targets)
        guard !hits.isEmpty else { return nil }
        let parts = hits.map { b -> String in
            // "Fat" alone would read as a macro row; the same-day cap is on the TOTAL.
            let name = b.nutrient == .f ? "total fat" : b.nutrient.fullName.lowercased()
            let amount = "\(name) \(fmt(b.value)) \(b.nutrient.unit)"
            if let m = b.multiple, m >= blowoutMultiplier, let t = b.target {
                return "\(amount) (\(String(format: "%.1f", m))x the \(fmt(t)) \(b.nutrient.unit) target)"
            }
            if let cap = b.nutrient.dailyHardCap, b.overHardCap {
                return "\(amount) (over the \(fmt(cap)) \(b.nutrient.unit) cap)"
            }
            return amount
        }
        return "TODAY RAN HOT (one day, not a pattern — the medians below smooth it away): "
            + parts.joined(separator: "; ") + "."
    }

    // MARK: - Top sources

    /// The foods that contributed the most of a nutrient over the meals the app has for the
    /// visible range, most impact first, KNOWN contributions only. Reuses the drill-down's
    /// `DietItem.contribution(to:)` so an unknown item is never a source and a true zero is
    /// never a row. Same-named foods across days/meals are summed. Empty when nothing known
    /// contributed — the caller shows nothing rather than a guess.
    static func topSources(_ nutrient: TrendNutrient, meals: [DietMeal], limit: Int = 3) -> [NutrientSource] {
        var totals: [String: Double] = [:]
        var order: [String] = []
        for item in meals.flatMap(\.items) {
            guard let v = item.contribution(to: nutrient.contributionMetric), v > 0 else { continue }
            if totals[item.item] == nil { order.append(item.item) }
            totals[item.item, default: 0] += v
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return order
            .map { NutrientSource(name: $0, value: totals[$0]!) }
            .sorted { a, b in a.value != b.value ? a.value > b.value : rank[a.name]! < rank[b.name]! }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Formatting helpers

    /// Round to a whole number (matching `DietSemantics.fmt`), so displayed values never
    /// disagree with the rest of the Health tab.
    static func fmt(_ x: Double) -> String { String(Int(x.rounded())) }

    // MARK: - Plain-language verdict (chart summary band)

    /// A thin reading below this coverage fraction is hedged as a hint, not a pattern.
    static let thinCoverageFraction = 0.5
    /// A judged floor/ceiling breached on at least this fraction of known days reads as a
    /// standing pattern, not a one-off.
    static let standingPatternFraction = 0.7

    /// The plain-language verdict for the chart summary band, straight from the analysis —
    /// coverage always stated first, a judgment only where the kind allows one, and a
    /// hedge when coverage is thin. Never asserts a gap as a low day; every count is over
    /// known days. Example: "Magnesium: known on 22 of the last 30 logged days. Median 250
    /// mg vs a 400 mg floor. Under the floor on 20 of 22 known days. Trend: flat. This is a
    /// consistent gap, not a one-off."
    static func verdict(_ t: NutrientTrend) -> String {
        let name = t.nutrient.fullName
        let window = t.windowDays.map { "the last \($0) logged days" } ?? "all \(t.daysInWindow) logged days"

        guard t.hasData, let median = t.median else {
            return "\(name): no known days in \(t.windowDays == nil ? "the series" : "this range") yet."
        }

        var out = "\(name): known on \(t.daysKnown) of \(window)."

        // Distribution / target line.
        switch t.kind {
        case .floor where t.target != nil:
            out += " Median \(fmt(median)) \(t.unit) vs a \(fmt(t.target!)) \(t.unit) floor."
        case .ceiling where t.target != nil:
            out += " Median \(fmt(median)) \(t.unit) vs a \(fmt(t.target!)) \(t.unit) ceiling."
        case .target where t.target != nil:
            out += " Median \(fmt(median)) \(t.unit) vs a \(fmt(t.target!)) \(t.unit) target."
        default:
            if let lo = t.minKnown, let hi = t.maxKnown, lo != hi {
                out += " Median \(fmt(median)) \(t.unit) (range \(fmt(lo))–\(fmt(hi)) \(t.unit))."
            } else {
                out += " Median \(fmt(median)) \(t.unit)."
            }
        }

        // Count line — only where a floor/ceiling judgment applies.
        if t.kind == .floor, t.target != nil {
            out += " Under the floor on \(t.countUnderTarget) of \(t.daysKnown) known days."
        } else if t.kind == .ceiling, t.target != nil {
            out += " Over the ceiling on \(t.countOverTarget) of \(t.daysKnown) known days."
        }

        // Trend line.
        if t.direction == .notEnoughData {
            out += " Not enough logged days yet to call a trend."
        } else {
            out += " Trend: \(t.direction.label)."
        }

        // Closing hedge / pattern note.
        let thin = (t.coverageFraction.map { $0 < thinCoverageFraction } ?? false)
            || t.daysKnown < minKnownForDirection
        if thin {
            out += " Coverage is thin here, so read this as a hint, not a pattern."
        } else if let pct = t.pctUnderTarget, pct >= standingPatternFraction {
            out += " This is a consistent gap, not a one-off."
        } else if let pct = t.pctOverTarget, pct >= standingPatternFraction {
            out += " This is a standing pattern, not a one-off."
        }

        return out
    }

    // MARK: - Coach multi-window rollup (health_context grounding)

    /// The three coaching windows: the last week, the last month, and all available.
    static let coachWindows: [Int?] = [7, 30, nil]

    /// A comfortable byte budget for the diet rollup on its own. It rides alongside the
    /// HealthKit block inside the bridge's `MAX_HEALTH_CONTEXT_BYTES` (8 KiB) cap; the
    /// HealthKit block self-limits to 3 KiB, so 2.5 KiB here keeps the combined context
    /// well under the hard cap with headroom.
    public static let coachRollupBudget = 2560

    private static func windowLabel(_ days: Int?) -> String { days.map { "\($0)d" } ?? "all" }

    private static func kindLabel(_ kind: TrendKind) -> String {
        switch kind {
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .target: return "target"
        case .informational: return "info"
        }
    }

    /// One nutrient's rollup line across the 7/30/all windows, e.g.
    /// "Magnesium (floor 400 mg): 7d median 260 known 5/6 under 5/5; 30d median 250 known
    /// 22/28 under 20/22; all median 255 known 61/80 under 55/61." A window without enough
    /// known-day coverage says "insufficient data" rather than a misleading number; counts
    /// are ALWAYS over known days, and the coverage (known/logged) is stated so the model
    /// can hedge. Returns nil when the nutrient has no data in any window.
    static func coachLine(_ series: [NutrientDay], nutrient: TrendNutrient,
                          targets: DietTargets) -> String? {
        let analyses = coachWindows.map { analyze(series, nutrient: nutrient, targets: targets, windowDays: $0) }
        guard analyses.contains(where: { $0.hasData }) else { return nil }

        let prefix: String
        if let target = nutrient.target(in: targets), nutrient.kind != .informational {
            prefix = "\(nutrient.fullName) (\(kindLabel(nutrient.kind)) \(fmt(target)) \(nutrient.unit))"
        } else {
            prefix = "\(nutrient.fullName) (\(kindLabel(nutrient.kind)) \(nutrient.unit))"
        }

        let segments = analyses.map { t -> String in
            let w = windowLabel(t.windowDays)
            guard t.daysKnown >= minKnownForDirection, let median = t.median else {
                return "\(w) insufficient data"
            }
            var s = "\(w) median \(fmt(median)) known \(t.daysKnown)/\(t.daysInWindow)"
            if t.kind == .floor, t.target != nil {
                s += " under \(t.countUnderTarget)/\(t.daysKnown)"
            } else if t.kind == .ceiling, t.target != nil {
                s += " over \(t.countOverTarget)/\(t.daysKnown)"
            }
            return s
        }
        return "\(prefix): \(segments.joined(separator: "; "))."
    }

    /// The primary window's analysis for standing-problem detection: the 30-day view when
    /// it has enough coverage, else the all-available view.
    static func primaryAnalysis(_ series: [NutrientDay], nutrient: TrendNutrient,
                                targets: DietTargets) -> NutrientTrend {
        let month = analyze(series, nutrient: nutrient, targets: targets, windowDays: 30)
        if month.daysKnown >= minKnownForDirection { return month }
        return analyze(series, nutrient: nutrient, targets: targets, windowDays: nil)
    }

    /// The breach fraction used to rank standing problems worst-first (pct under a floor or
    /// over a ceiling); 0 for a nutrient that isn't a standing problem.
    private static func breachPct(_ t: NutrientTrend) -> Double {
        t.pctUnderTarget ?? t.pctOverTarget ?? 0
    }

    /// The compact, plain-text multi-window nutrient rollup the coach receives on a
    /// diet-related turn, so it can reason over the week and month instead of a single day.
    /// A framing sentence states the intent and the daily instruction; then — on a day that
    /// blew a ceiling — the one same-day line the medians cannot show (`blowoutLine`); then
    /// one terse line per nutrient across 7/30/all; then, for each STANDING problem, its consequence
    /// (`whyItMatters`), the real top-contributing foods over the range, and its
    /// good-source foods so the coach grounds a fix in real foods. Everything is over KNOWN
    /// days only — a gap is never a low day.
    ///
    /// Budget-aware: when the full set would exceed `budgetBytes`, it keeps the framing,
    /// the standing problems (worst first) and the macros, drops the informational
    /// nutrients first, and states that it was truncated. `meals` is the per-day food
    /// detail the app has (typically the loaded day) used for the top-sources lines;
    /// unknown items never appear as a source. Returns "" when the series is empty.
    public static func coachRollup(series: [NutrientDay], targets: DietTargets,
                                   meals: [DietMeal], ownerName: String = "the user",
                                   budgetBytes: Int = coachRollupBudget) -> String {
        guard isAvailable(series) else { return "" }

        // Primary-window analysis per nutrient, for standing-problem detection + ranking.
        let primary = Dictionary(uniqueKeysWithValues:
            TrendNutrient.allCases.map { ($0, primaryAnalysis(series, nutrient: $0, targets: targets)) })
        func isStanding(_ n: TrendNutrient) -> Bool { primary[n]!.isStandingProblem }

        // Ranking: standing problems worst-first, then macros, then other judged nutrients,
        // then the informational ones (dropped first under budget pressure).
        func tier(_ n: TrendNutrient) -> Int {
            if isStanding(n) { return 0 }
            if [.cal, .p, .f, .c].contains(n) { return 1 }
            if n.kind == .informational { return 3 }
            return 2
        }
        let ranked = TrendNutrient.allCases.enumerated().sorted { a, b in
            let ta = tier(a.element), tb = tier(b.element)
            if ta != tb { return ta < tb }
            if ta == 0 { return breachPct(primary[a.element]!) > breachPct(primary[b.element]!) }
            return a.offset < b.offset
        }.map(\.element)

        let framing = "NUTRIENT WINDOWS (known days only — a gap is never a low day). "
            + "Use these to tell a persistent pattern from a single day: call out what is "
            + "consistently on-track and what is a standing problem across 7/30/all. For each "
            + "standing problem below, EVERY day: say what the level is doing to \(ownerName) "
            + "(the consequence), where they are getting or missing it (the real top sources), "
            + "and one or two concrete fixes from their good-source foods — favoring what is in "
            + "season and already in their kitchen, and fitting the calorie deficit. Never "
            + "present a coverage gap as a low day."

        // The same-day blow-out line rides at the FRONT of the greedy fit, ahead of every
        // rolling line. It carries the one thing the windows structurally cannot: a single
        // day loud enough to matter, which every median below is designed to smooth away.
        // Under budget pressure the informational nutrient lines are dropped and this stays.
        let hotLine = blowoutLine(meals: meals, targets: targets)

        // Build every candidate block, in priority order, then greedily fit the budget.
        var blocks: [String] = []
        for n in ranked {
            guard let line = coachLine(series, nutrient: n, targets: targets) else { continue }
            blocks.append(line)
        }
        // Standing-problem detail blocks come after the terse lines, worst-first.
        var details: [String] = []
        for n in ranked where isStanding(n) {
            let verb = primary[n]!.kind == .floor ? "shortfall" : "excess"
            var d = "\(n.fullName): standing \(verb) — \(n.whyItMatters)"
            let sources = topSources(n, meals: meals, limit: 3).map(\.name)
            if !sources.isEmpty { d += " Top sources (logged): \(sources.joined(separator: ", "))." }
            d += " \(primary[n]!.kind == .floor ? "Raise it with" : "Cut it from"): \(n.goodSourcesText)."
            details.append(d)
        }

        // Greedy fit: framing is mandatory; then the terse lines and detail blocks in order.
        // A dropped block flips the truncation note on.
        var kept: [String] = [framing]
        var truncated = false
        func byteLen(_ parts: [String]) -> Int { parts.joined(separator: "\n").utf8.count }
        let reserve = 80 // room for the truncation note if we need it
        for block in (hotLine.map { [$0] } ?? []) + blocks + details {
            if byteLen(kept + [block]) + reserve <= budgetBytes {
                kept.append(block)
            } else {
                truncated = true
            }
        }
        if truncated {
            kept.append("(Rollup truncated to fit — lower-priority nutrients omitted, informational first.)")
        }
        return kept.joined(separator: "\n")
    }
}
