import Foundation
import JesseNetworking

// The associations engine: what moved together across weight, training and intake, as pure
// Foundation-only logic — no SwiftUI, no `Date()` read, every rule deterministically
// testable.
//
// This file is deliberately more restrained than it is clever, and the restraint IS the
// feature. Daily n is small (weigh-ins across a few months), the series are noisy, and a
// correlation over a dozen points will happily produce an impressive-looking coefficient
// out of nothing at all. So four guardrails sit between the arithmetic and the screen:
//
//   1. NEVER CAUSATION. Everything here is an association. The wording is fixed in this
//      file ("moved together over N days") precisely so no view can quietly upgrade it to
//      "sodium raises your weight". Both directions are equally consistent with the data,
//      and so is a third variable driving both.
//   2. A MINIMUM SAMPLE. Below `minPairs` overlapping day-pairs there is no coefficient at
//      all — not a hedged one, not a greyed-out one. The pair reports "not enough data" and
//      the number is never computed into view.
//   3. A WEAK FLOOR. Below `weakThreshold` in magnitude an association is suppressed, so
//      the screen shows only what is worth a look rather than a wall of noise around zero.
//   4. NOTHING IS SILENTLY DROPPED. Pairs cut for thin data or weakness are COUNTED and
//      reported, so a short list never reads as "these are all the relationships there are".
//
// UNKNOWN IS NOT ZERO, as everywhere else in this stack, and here it takes a specific
// form: a day missing from EITHER side is excluded from the pair rather than filled in. A
// rest day is absent from `exerciseSeries` (the bridge emits no row), and filling it with 0
// would invent training data the log never claimed; a day nobody weighed has no weight
// delta; a nutrient nobody measured has no total. Every pair is built from the dates that
// genuinely have both sides.

// MARK: - Statistics (pure)

/// The two correlation primitives, kept apart from the diet vocabulary so they can be
/// tested as arithmetic. Both return nil rather than a number when the input cannot support
/// one (fewer than two points, or a constant series with no variance to correlate).
enum Statistics {
    /// Pearson's r over paired samples: linear association, −1…1. Nil when the arrays differ
    /// in length, hold fewer than two points, or either side is constant (zero variance —
    /// r is undefined, not 0).
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, dx2 = 0.0, dy2 = 0.0
        for (x, y) in zip(xs, ys) {
            let dx = x - mx, dy = y - my
            num += dx * dy; dx2 += dx * dx; dy2 += dy * dy
        }
        guard dx2 > 0, dy2 > 0 else { return nil }
        let r = num / (dx2 * dy2).squareRoot()
        // Clamp the floating-point overshoot on a perfectly collinear pair, so a caller
        // never sees 1.0000000000000002 and no display rounds to "101%".
        return min(max(r, -1), 1)
    }

    /// Spearman's rho: Pearson's r computed over RANKS, so it measures monotone association
    /// rather than a straight line and is far less swayed by one outlier day. That
    /// robustness is why it is the headline here — a single 5,000-kcal holiday or a
    /// dehydrated post-marathon weigh-in should not be allowed to author a "finding".
    /// Tied values take their average rank, the standard correction.
    static func spearman(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        return pearson(ranks(xs), ranks(ys))
    }

    /// Fractional ranks (1-based) with ties averaged, e.g. `[10, 20, 20, 30]` → `[1, 2.5,
    /// 2.5, 4]`. Order-preserving with respect to the input positions.
    static func ranks(_ xs: [Double]) -> [Double] {
        let sortedIdx = xs.enumerated().sorted { $0.element < $1.element }
        var out = [Double](repeating: 0, count: xs.count)
        var i = 0
        while i < sortedIdx.count {
            var j = i
            // Extend over the run of equal values, then give every member the run's mean rank.
            while j + 1 < sortedIdx.count, sortedIdx[j + 1].element == sortedIdx[i].element { j += 1 }
            let meanRank = Double(i + j + 2) / 2 // (i+1 … j+1) averaged
            for k in i...j { out[sortedIdx[k].offset] = meanRank }
            i = j + 1
        }
        return out
    }
}

// MARK: - The variables being crossed

/// One daily series the engine can correlate, with the wording a finding uses for it. The
/// `lagged` flag on a PAIR (not here) decides whether it is read as "that day" or "the day
/// before"; this type only names the quantity.
enum DietVariable: String, Equatable, Sendable, CaseIterable {
    case calories, sodium, satFat, protein, carbs
    case exerciseKcal
    /// Day-over-day weight change in pounds — the right target for a daily association.
    /// Raw weight is dominated by the long cut trend, so correlating anything against it
    /// mostly rediscovers "time passed"; the DELTA is the thing a single day can move.
    case weightChange

    /// The user-facing name, spelled here and nowhere else.
    var label: String {
        switch self {
        case .calories: return "calories"
        case .sodium: return "sodium"
        case .satFat: return "saturated fat"
        case .protein: return "protein"
        case .carbs: return "carbs"
        case .exerciseKcal: return "exercise calories"
        case .weightChange: return "next-morning weight change"
        }
    }

    /// The `TrendNutrient` this variable reads from `nutrientSeries`, or nil for the two
    /// variables that come from other series.
    var nutrient: TrendNutrient? {
        switch self {
        case .calories: return .cal
        case .sodium: return .na
        case .satFat: return .satf
        case .protein: return .p
        case .carbs: return .c
        case .exerciseKcal, .weightChange: return nil
        }
    }
}

// MARK: - Result types

/// Why a candidate pair produced no finding. Both reasons are REPORTED rather than silently
/// applied — a screen that hides its rejects implies the ones it shows are all there is.
enum PairRejection: Equatable, Sendable {
    /// Fewer than `minPairs` overlapping days. Carries the count so the row can say how far
    /// off it is, but NEVER a coefficient.
    case notEnoughData(pairs: Int)
    /// Enough data, but the association is below `weakThreshold` in magnitude.
    case tooWeak(coefficient: Double, pairs: Int)
    /// Enough data, but one side never varied (every value identical), so no coefficient is
    /// defined at all.
    case noVariation(pairs: Int)
}

/// One association that cleared every guardrail: which two variables, over how many days,
/// how strong, and in which direction. `title` and `sentence` are built here so no view can
/// restate a correlation as a cause.
struct DietAssociation: Equatable, Sendable, Identifiable {
    let x: DietVariable
    let y: DietVariable
    /// True when `x` is read from the PREVIOUS day (yesterday's intake against today's
    /// weight change).
    let lagged: Bool
    /// Spearman's rho over the overlapping days, −1…1.
    let coefficient: Double
    /// Overlapping day-pairs the coefficient was computed from.
    let pairs: Int

    var id: String { "\(x.rawValue)-\(y.rawValue)-\(lagged ? "lag1" : "same")" }

    /// Strength of the association regardless of sign.
    var magnitude: Double { abs(coefficient) }
    /// Whether the two moved the same way (both up) or opposite ways.
    var isPositive: Bool { coefficient > 0 }

    /// The row's heading — the two quantities and the lag, never a verb that implies one
    /// acts on the other.
    var title: String {
        lagged ? "\(x.label.capitalizedFirst) the day before, and \(y.label)"
               : "\(x.label.capitalizedFirst) and \(y.label), same day"
    }

    /// The finding in plain words. The phrasing is fixed: "moved together" / "moved in
    /// opposite directions", the sample size, and the standing reminder that this is an
    /// association. There is deliberately no sentence here that a reader could quote as a
    /// causal claim.
    var sentence: String {
        let direction = isPositive
            ? "moved together (both higher, or both lower)"
            : "moved in opposite directions (one higher, the other lower)"
        return "Over \(pairs) days with both measured, these \(direction). "
            + "That is an association, not a cause: something else may drive both."
    }

    /// The coefficient formatted for display, signed, two decimals.
    var coefficientText: String { String(format: "%+.2f", coefficient) }

    /// A coarse strength word for the row, from the same thresholds the engine ranks on.
    var strengthWord: String {
        switch magnitude {
        case DietCorrelations.strongThreshold...: return "strong"
        case DietCorrelations.moderateThreshold...: return "moderate"
        default: return "modest"
        }
    }
}

/// One candidate pair that produced no finding, kept so the screen can say so.
struct DietPairMiss: Equatable, Sendable, Identifiable {
    let x: DietVariable
    let y: DietVariable
    let lagged: Bool
    let rejection: PairRejection

    var id: String { "\(x.rawValue)-\(y.rawValue)-\(lagged ? "lag1" : "same")" }

    var title: String {
        lagged ? "\(x.label.capitalizedFirst) the day before, and \(y.label)"
               : "\(x.label.capitalizedFirst) and \(y.label), same day"
    }

    /// What to show instead of a number. A thin pair says how thin, and never hints at
    /// which way it was leaning — the whole point of the minimum is that the number is not
    /// yet meaningful.
    var reasonText: String {
        switch rejection {
        case .notEnoughData(let n):
            return "not enough data — \(n) of \(DietCorrelations.minPairs) days needed"
        case .tooWeak(_, let n):
            return "no meaningful association over \(n) days"
        case .noVariation(let n):
            return "no variation to compare over \(n) days"
        }
    }
}

/// Everything the Patterns screen needs: the findings worth a look, what was set aside and
/// why, and the coverage the whole thing stands on.
struct DietCorrelationReport: Equatable, Sendable {
    /// Associations that cleared the sample minimum and the weak floor, strongest first,
    /// capped to `maxShown`.
    let associations: [DietAssociation]
    /// Pairs that produced no finding, in candidate order.
    let misses: [DietPairMiss]
    /// Associations that cleared every guardrail but fell outside the display cap.
    let cappedOut: Int
    /// Days with a usable weight change — the sample everything lagged is built on.
    let weightChangeDays: Int

    /// Nothing to show and nothing to explain: no pair had even enough data to consider.
    var isEmpty: Bool { associations.isEmpty && misses.isEmpty }
    /// Pairs set aside for thin data.
    var thinCount: Int { misses.filter { if case .notEnoughData = $0.rejection { return true }; return false }.count }
    /// Pairs set aside as too weak (or with nothing to vary).
    var weakCount: Int { misses.count - thinCount }
}

// MARK: - Engine

enum DietCorrelations {
    /// The minimum overlapping day-pairs before ANY coefficient may be shown. Fourteen is
    /// the line the whole screen rests on: at n = 10 a Spearman rho of 0.6 arises from
    /// unrelated noise often enough to be unremarkable, and there is no honest way to
    /// present such a number to someone who will read it as a finding about their body. Two
    /// weeks of paired days is not a study either — hence every other guardrail — but it is
    /// the point below which the screen simply declines to answer.
    static let minPairs = 14

    /// Below this magnitude an association is suppressed. Around 0.3 a scatter of daily
    /// diet data looks like a cloud to the eye, and showing it would fill the screen with
    /// rows that mean nothing while burying the one or two that might.
    static let weakThreshold = 0.30
    /// The wording thresholds ("moderate" / "strong"). Display only — ranking is by
    /// magnitude alone.
    static let moderateThreshold = 0.50
    static let strongThreshold = 0.70

    /// How many findings the screen lists. Anything beyond is COUNTED and reported.
    static let maxShown = 5

    /// The standing caveat, stated once wherever findings are shown. Fixed here rather than
    /// in a view so it cannot be softened.
    static let caveat =
        "These are associations over a small number of days, not causes. Two things that "
        + "move together may both follow something else entirely — a long run, a travel "
        + "week, a salty meal that was also a big one. Read them as questions worth asking, "
        + "never as conclusions."

    /// Whether the Patterns affordance shows at all. It needs all three series: the weight
    /// history to build a daily change from, the nutrient history for intake, and the
    /// exercise history — the last is the field an older bridge omits entirely, so its
    /// absence hides the section rather than crashing or silently showing a diet-only
    /// version under a heading that promises training.
    static func isAvailable(weight: [WeightPoint]?, nutrients: [NutrientDay]?,
                            exercise: [ExerciseDay]?) -> Bool {
        guard exercise != nil else { return false }
        return (weight?.isEmpty == false) && (nutrients?.isEmpty == false)
    }

    // MARK: - Daily series assembly

    /// Day-over-day weight change by date: `weight(d) − weight(d−1)`, keyed on `d`, and only
    /// where BOTH days carry a weigh-in exactly one calendar day apart. A three-day gap is
    /// not a daily change — spreading it across the missing days would invent readings — so
    /// it produces no entry at all. Duplicate rows for a date keep the last.
    static func weightChanges(_ series: [WeightPoint]) -> [String: Double] {
        var byDate: [String: Double] = [:]
        for p in series where NutrientTrends.dayParser.date(from: p.date) != nil {
            byDate[p.date] = p.lbs
        }
        var out: [String: Double] = [:]
        for (date, lbs) in byDate {
            guard let d = NutrientTrends.dayParser.date(from: date),
                  let prev = utcCalendar.date(byAdding: .day, value: -1, to: d),
                  let prevLbs = byDate[NutrientTrends.dayParser.string(from: prev)]
            else { continue }
            out[date] = lbs - prevLbs
        }
        return out
    }

    /// One nutrient's daily KNOWN total by date, from `nutrientSeries`. A day the nutrient
    /// was never measured has no key at all — a gap, never a 0.
    ///
    /// A PARTIAL day (some foods measured, some not) IS included, and it is worth being
    /// explicit about why: its total is a lower bound, so including it adds measurement
    /// noise. Noise of that kind ATTENUATES a correlation — it pushes a coefficient toward
    /// zero, and can only cost a real association its place on the screen, never manufacture
    /// a false one. Excluding partial days instead would drop most of the sample for exactly
    /// the label-sparse nutrients this screen is most interesting for. Erring toward the
    /// conservative side is the whole posture of this file, so partial days stay in.
    static func nutrientDaily(_ series: [NutrientDay], nutrient: TrendNutrient) -> [String: Double] {
        var out: [String: Double] = [:]
        for day in series where NutrientTrends.dayParser.date(from: day.date) != nil {
            guard let v = day.nutrients[nutrient.key], v.known >= 1 else { continue }
            out[day.date] = v.sum
        }
        return out
    }

    /// Daily exercise calories by date. A date with no logged session is ABSENT — the bridge
    /// emits no row for it — and it stays absent here. Reading a missing day as 0 kcal would
    /// assert a rest day the log never recorded, and would quietly stuff the sample with
    /// invented zeros that any correlation against training would then be mostly measuring.
    static func exerciseDaily(_ series: [ExerciseDay]) -> [String: Double] {
        var out: [String: Double] = [:]
        for day in series where NutrientTrends.dayParser.date(from: day.date) != nil {
            out[day.date] = day.kcal
        }
        return out
    }

    /// Pair two date-keyed series into aligned samples, ascending by the TARGET date.
    /// `lagged` reads `x` from the day BEFORE each `y` date — yesterday's intake against
    /// today's weight change, which is the only ordering in which the question is even
    /// well-posed. A date missing on either side yields no pair.
    static func pair(x: [String: Double], y: [String: Double],
                     lagged: Bool) -> (xs: [Double], ys: [Double]) {
        var xs: [Double] = [], ys: [Double] = []
        for date in y.keys.sorted() {
            let lookup: String?
            if lagged {
                lookup = NutrientTrends.dayParser.date(from: date)
                    .flatMap { utcCalendar.date(byAdding: .day, value: -1, to: $0) }
                    .map { NutrientTrends.dayParser.string(from: $0) }
            } else {
                lookup = date
            }
            guard let key = lookup, let xv = x[key], let yv = y[date] else { continue }
            xs.append(xv); ys.append(yv)
        }
        return (xs, ys)
    }

    // MARK: - Candidate pairs

    /// One question the engine asks. Kept as an explicit, ordered list rather than a
    /// combinatorial sweep of every variable against every other: a sweep over a dozen
    /// series is a multiple-comparisons machine that will always hand back a "finding",
    /// and most of the pairs it would test are meaningless anyway (protein against carbs
    /// is mostly a restatement of calories). These are the questions worth asking.
    struct Candidate: Equatable, Sendable {
        let x: DietVariable
        let y: DietVariable
        /// `x` is read from the previous day.
        let lagged: Bool
    }

    /// The candidate pairs, in the order a tie between equal magnitudes resolves.
    ///
    /// The lagged block asks what yesterday did to this morning's scale reading — sodium and
    /// carbs first, since water weight is the one daily mechanism plausible enough to be
    /// worth measuring. The same-day block asks a different question entirely: whether
    /// training days are also bigger eating days, which is about behavior rather than
    /// physiology and needs no lag.
    static let candidates: [Candidate] = [
        Candidate(x: .sodium, y: .weightChange, lagged: true),
        Candidate(x: .carbs, y: .weightChange, lagged: true),
        Candidate(x: .calories, y: .weightChange, lagged: true),
        Candidate(x: .exerciseKcal, y: .weightChange, lagged: true),
        Candidate(x: .satFat, y: .weightChange, lagged: true),
        Candidate(x: .protein, y: .weightChange, lagged: true),
        Candidate(x: .exerciseKcal, y: .calories, lagged: false),
        Candidate(x: .exerciseKcal, y: .carbs, lagged: false),
    ]

    /// The date-keyed daily series for one variable, from whichever history holds it.
    static func series(for variable: DietVariable, weight: [WeightPoint],
                       nutrients: [NutrientDay], exercise: [ExerciseDay]) -> [String: Double] {
        switch variable {
        case .weightChange: return weightChanges(weight)
        case .exerciseKcal: return exerciseDaily(exercise)
        default:
            guard let n = variable.nutrient else { return [:] }
            return nutrientDaily(nutrients, nutrient: n)
        }
    }

    /// What one candidate produced. Deliberately its own type rather than a `Result`: a pair
    /// with too few days is not an ERROR, it is a perfectly good answer ("not enough data
    /// yet") that the screen is expected to show.
    enum PairOutcome: Equatable, Sendable {
        case association(DietAssociation)
        case miss(DietPairMiss)

        /// The association, when the pair produced one — nil for a miss, so a caller can
        /// never reach a coefficient the guardrails withheld.
        var association: DietAssociation? {
            if case .association(let a) = self { return a }
            return nil
        }
        var miss: DietPairMiss? {
            if case .miss(let m) = self { return m }
            return nil
        }
    }

    /// Evaluate ONE candidate: either an association that cleared every guardrail, or the
    /// reason it produced none. The sample minimum is checked BEFORE the coefficient is
    /// computed at all, so a thin pair's number never exists to be leaked to a caller.
    static func evaluate(_ c: Candidate, weight: [WeightPoint], nutrients: [NutrientDay],
                         exercise: [ExerciseDay]) -> PairOutcome {
        let xs = series(for: c.x, weight: weight, nutrients: nutrients, exercise: exercise)
        let ys = series(for: c.y, weight: weight, nutrients: nutrients, exercise: exercise)
        let (a, b) = pair(x: xs, y: ys, lagged: c.lagged)

        func miss(_ r: PairRejection) -> PairOutcome {
            .miss(DietPairMiss(x: c.x, y: c.y, lagged: c.lagged, rejection: r))
        }
        guard a.count >= minPairs else { return miss(.notEnoughData(pairs: a.count)) }
        guard let rho = Statistics.spearman(a, b) else { return miss(.noVariation(pairs: a.count)) }
        guard abs(rho) >= weakThreshold else { return miss(.tooWeak(coefficient: rho, pairs: a.count)) }
        return .association(DietAssociation(x: c.x, y: c.y, lagged: c.lagged,
                                            coefficient: rho, pairs: a.count))
    }

    /// The whole report: every candidate evaluated, the survivors ranked strongest first and
    /// capped, everything else counted and kept so the screen can say what it set aside.
    /// Ties in magnitude keep candidate order, so the output is stable and explainable.
    static func report(weight: [WeightPoint]?, nutrients: [NutrientDay]?,
                       exercise: [ExerciseDay]?, limit: Int = maxShown) -> DietCorrelationReport {
        let w = weight ?? [], n = nutrients ?? [], e = exercise ?? []
        var found: [(offset: Int, association: DietAssociation)] = []
        var misses: [DietPairMiss] = []
        for (i, c) in candidates.enumerated() {
            switch evaluate(c, weight: w, nutrients: n, exercise: e) {
            case .association(let a): found.append((i, a))
            case .miss(let m): misses.append(m)
            }
        }
        let ranked = found
            .sorted { a, b in
                a.association.magnitude != b.association.magnitude
                    ? a.association.magnitude > b.association.magnitude
                    : a.offset < b.offset
            }
            .map(\.association)

        return DietCorrelationReport(
            associations: Array(ranked.prefix(limit)),
            misses: misses,
            cappedOut: max(0, ranked.count - limit),
            weightChangeDays: weightChanges(w).count)
    }

    /// The Patterns nav row's subtitle: the strongest finding, or an honest statement that
    /// there isn't one yet. Nil when there is nothing at all to show, so the row can hide.
    static func subtitle(_ report: DietCorrelationReport) -> String? {
        if let best = report.associations.first {
            return "\(best.x.label) and \(best.y.label) — \(best.strengthWord), \(best.pairs) days"
        }
        guard !report.misses.isEmpty else { return nil }
        return report.thinCount == report.misses.count
            ? "not enough paired days yet"
            : "nothing worth flagging yet"
    }

    /// The one-line summary of what was set aside, so a short list is never read as the
    /// complete picture. Nil when nothing was dropped.
    static func droppedLine(_ report: DietCorrelationReport) -> String? {
        var parts: [String] = []
        if report.thinCount > 0 {
            parts.append("\(report.thinCount) \(report.thinCount == 1 ? "pair" : "pairs") "
                         + "without \(minPairs) paired days yet")
        }
        if report.weakCount > 0 {
            parts.append("\(report.weakCount) too weak to be worth a look")
        }
        if report.cappedOut > 0 {
            parts.append("\(report.cappedOut) beyond the \(maxShown) shown")
        }
        guard !parts.isEmpty else { return nil }
        return "Not shown: " + parts.joined(separator: ", ") + "."
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension String {
    /// First character uppercased, the rest untouched — for sentence-leading a variable
    /// label without `capitalized`'s habit of title-casing every word.
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}
