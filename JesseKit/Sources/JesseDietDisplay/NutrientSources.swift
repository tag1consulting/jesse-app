import Foundation
import JesseNetworking

// The "where is this coming from" engine, as pure Foundation-only logic — no SwiftUI, no
// `Date()` read, every rule deterministically testable. It closes the loop the rolling
// windows open: `NutrientTrends` can say saturated fat runs high on the 7-day median, and
// this says the median is mostly cheese and cured meat. The first half is a reading; the
// second is the half you can act on.
//
// It sits beside `FoodContributions`, which answers the same question for ONE day from the
// loaded day's meals. This one answers it over a RANGE from `sourceSeries`, which is the
// only place the app has per-item detail for days other than the one on screen.
//
// CORE RULE, carried verbatim from the rest of the stack: UNKNOWN IS NOT ZERO. An item in
// `sourceSeries` carries only the nutrient keys whose cell was actually known, so a food
// that was never measured for magnesium simply has no `mg` key — it is NOT a food that
// supplied 0 mg. Such a food is excluded from the ranking AND from the share denominator,
// because a share taken against a total that silently included unmeasured foods as zeros
// would overstate every listed food's contribution. A range with no known contributor
// yields NO sources at all, and the view shows nothing rather than a guess.

// MARK: - Result types

/// One food's summed contribution of a single nutrient over a range: the total it is KNOWN
/// to have delivered, its share of the range's known total, and how many separate days it
/// appeared as a contributor. The day count is what separates a staple from a single
/// blow-out — 40 g of saturated fat across twelve days is a habit, the same 40 g on one day
/// is a cheese board.
struct NutrientSourceEntry: Equatable, Sendable, Identifiable {
    /// The food's name exactly as logged (the grouping key), or `unnamedLabel` when the log
    /// row carried no name.
    let name: String
    /// Summed KNOWN contribution over the range, in the nutrient's own unit.
    let value: Double
    /// Fraction (0…1) of the range's KNOWN total. Never taken against a total that
    /// included unmeasured foods.
    let share: Double
    /// Distinct dates in the range this food contributed a known amount on.
    let days: Int

    var id: String { name }
}

/// One nutrient's sources over one range: the ranked foods, the known total they are
/// measured against, and the coverage facts a view needs to state what the ranking does and
/// does not cover. Every number is over KNOWN contributions.
struct NutrientSourceRanking: Equatable, Sendable {
    let nutrient: TrendNutrient
    /// The requested range in days (the window is `[anchor − (days − 1), anchor]`).
    let windowDays: Int
    /// Logged days present in the range — the coverage denominator.
    let daysInRange: Int
    /// Of those, days at least one food carried a known value for this nutrient.
    let daysKnown: Int
    /// The summed KNOWN contribution over the range: the share denominator, and a LOWER
    /// BOUND whenever `unmeasuredItems > 0`.
    let knownTotal: Double
    /// The ranked foods, most contribution first, capped to the caller's limit.
    let entries: [NutrientSourceEntry]
    /// Distinct contributing foods BEFORE the cap, so a truncated list can say so.
    let contributorCount: Int
    /// Logged food rows in the range that carry NO known value for this nutrient. These are
    /// the reason `knownTotal` is a floor; they are never ranked and never counted as 0.
    let unmeasuredItems: Int

    /// Nothing known contributed — the view shows nothing rather than a guess.
    var isEmpty: Bool { entries.isEmpty }
    /// Contributors the cap left out of `entries`.
    var hiddenContributors: Int { max(0, contributorCount - entries.count) }
    /// The listed foods' combined share of the known total.
    var listedShare: Double { entries.reduce(0) { $0 + $1.share } }
    /// At least one logged row in the range lacks a value for this nutrient, so the total
    /// above is a floor and the ranking covers only what was measured.
    var isPartial: Bool { unmeasuredItems > 0 }

    /// The single most-contributing food, for a one-line summary.
    var leader: NutrientSourceEntry? { entries.first }
}

// MARK: - Engine

enum NutrientSources {
    /// How many foods a Sources list shows. Ten is long enough that a real staple cannot hide
    /// below the fold and short enough to read; whatever the cap leaves out is COUNTED and
    /// stated rather than silently dropped (`hiddenContributors`).
    static let defaultLimit = 10

    /// The ranges offered. Capped at 30 deliberately: the bridge sends the most recent 45
    /// dates of `sourceSeries`, so a 90-day option would silently show 45 days of data under a
    /// 90-day label. 7d reads the recent tail (what changed this week), 30d the habit.
    static let ranges: [Int] = [7, 30]

    /// The label a log row with no name is grouped under. It is still a real known
    /// contribution, so dropping it would understate the denominator; it is named honestly
    /// instead.
    static let unnamedLabel = "Unnamed item"

    /// The rule stated wherever a Sources list is shown. Not decoration: a ranking over
    /// measured foods is a different claim from a ranking over all foods, and the screen has
    /// to say which one it is making.
    static let unknownRule =
        "Only foods with a measured value for this nutrient are ranked. A food the log "
        + "never measured is unknown, not zero, so it is left out of both the list and the "
        + "total the shares are taken against."

    /// Whether the Sources affordance shows at all: the field is present and carries at least
    /// one day. An older bridge (absent/empty `sourceSeries`) hides it rather than crashing or
    /// inventing an empty screen.
    static func isAvailable(_ series: [SourceDay]?) -> Bool {
        (series?.isEmpty == false)
    }

    /// The series sorted ascending by date, dropping any row whose date doesn't parse —
    /// mirroring `NutrientTrends.sorted` so both engines window the same history the same way.
    static func sorted(_ series: [SourceDay]) -> [SourceDay] {
        series
            .filter { NutrientTrends.dayParser.date(from: $0.date) != nil }
            .sorted { $0.date < $1.date }
    }

    /// The days inside the most-recent `windowDays` CALENDAR days, anchored on the LAST day in
    /// the series. `series` must be ascending.
    ///
    /// The anchor is deliberately the last LOGGED day, not (as in `NutrientTrends.analyze`) the
    /// nutrient's own last known day. The trend chart anchors per nutrient so a rarely-labeled
    /// nutrient still shows its recent tail; here that would quietly slide the window backwards
    /// in time and print "last 7 days" over a fortnight-old fortnight of food. A range with
    /// nothing known in it is a real and useful answer — the view says so — and it is a more
    /// honest one than a shifted window.
    static func windowed(_ series: [SourceDay], windowDays: Int) -> [SourceDay] {
        guard let anchor = series.last.flatMap({ NutrientTrends.dayParser.date(from: $0.date) }),
              let cutoff = utcCalendar.date(byAdding: .day, value: -(windowDays - 1), to: anchor)
        else { return series }
        return series.filter {
            guard let d = NutrientTrends.dayParser.date(from: $0.date) else { return false }
            return d >= cutoff && d <= anchor
        }
    }

    /// One food row's KNOWN contribution of a nutrient, or nil when this row never measured
    /// it. A key ABSENT from `n` is unknown; a key PRESENT with 0 is a measured zero, which
    /// contributes nothing to a sum and is therefore not a source either. A negative value is
    /// log noise (the bridge already clamps the one derived key it computes) and is treated
    /// the same way — neither ranked nor summed — so a share can never exceed the total it is
    /// taken against.
    static func contribution(_ item: SourceItem, nutrient: TrendNutrient) -> Double? {
        guard let v = item.n[nutrient.key] else { return nil }
        return v > 0 ? v : nil
    }

    /// Whether this row measured the nutrient at all — the distinction between a food that
    /// contributed nothing (a measured 0) and one nobody measured. Only the latter makes the
    /// total a floor.
    static func measured(_ item: SourceItem, nutrient: TrendNutrient) -> Bool {
        item.n[nutrient.key] != nil
    }

    /// Rank the foods that delivered `nutrient` over the most recent `windowDays` days of
    /// `series`. Same-named foods are summed across meals AND across days; ties break by first
    /// appearance in the range, so equal contributions keep a stable, explainable order.
    ///
    /// Everything runs over KNOWN contributions: an unmeasured row is neither ranked nor
    /// summed into `knownTotal`, so no listed food's share is inflated by a food the log never
    /// measured. When nothing known contributed, `entries` is empty — the caller shows nothing
    /// rather than a guess.
    static func rank(_ series: [SourceDay], nutrient: TrendNutrient,
                     windowDays: Int, limit: Int = defaultLimit) -> NutrientSourceRanking {
        let window = windowed(sorted(series), windowDays: windowDays)

        var totals: [String: Double] = [:]
        var dayCounts: [String: Set<String>] = [:]
        var order: [String] = []
        var knownTotal = 0.0
        var unmeasured = 0
        var daysKnown = 0

        for day in window {
            var dayHadKnown = false
            for item in day.items {
                guard let v = contribution(item, nutrient: nutrient) else {
                    // A measured zero contributed nothing and leaves the total exact; only a
                    // row that never measured the nutrient makes the total a floor.
                    if !measured(item, nutrient: nutrient) { unmeasured += 1 }
                    continue
                }
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = name.isEmpty ? unnamedLabel : name
                if totals[key] == nil { order.append(key) }
                totals[key, default: 0] += v
                dayCounts[key, default: []].insert(day.date)
                knownTotal += v
                dayHadKnown = true
            }
            if dayHadKnown { daysKnown += 1 }
        }

        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let ranked = order
            .map { (name: $0, value: totals[$0]!, days: dayCounts[$0]?.count ?? 0) }
            .sorted { a, b in a.value != b.value ? a.value > b.value : rank[a.name]! < rank[b.name]! }

        let entries = ranked.prefix(limit).map { r in
            NutrientSourceEntry(name: r.name, value: r.value,
                                share: knownTotal > 0 ? r.value / knownTotal : 0,
                                days: r.days)
        }

        return NutrientSourceRanking(
            nutrient: nutrient, windowDays: windowDays, daysInRange: window.count,
            daysKnown: daysKnown, knownTotal: knownTotal, entries: Array(entries),
            contributorCount: ranked.count, unmeasuredItems: unmeasured)
    }

    /// Every nutrient that has at least one known contributor in the range, in canonical
    /// nutrient order, each with its own ranking. A nutrient nothing measured simply isn't in
    /// the list — the overview shows what the log can actually answer.
    static func overview(_ series: [SourceDay], windowDays: Int,
                         limit: Int = defaultLimit) -> [NutrientSourceRanking] {
        TrendNutrient.allCases
            .map { rank(series, nutrient: $0, windowDays: windowDays, limit: limit) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Plain-language lines

    /// The one-line "mostly X and Y" summary for a nutrient's row, naming the foods that carry
    /// the top of the list. Deliberately says "of the measured total" — the shares are over
    /// what was measured, and the row that shows them should not pretend otherwise. Nil when
    /// there is nothing known to summarize.
    static func summaryLine(_ r: NutrientSourceRanking) -> String? {
        guard let leader = r.leader else { return nil }
        let named = r.entries.prefix(2)
        let names = named.map(\.name).joined(separator: " and ")
        let share = named.reduce(0) { $0 + $1.share }
        return "mostly \(names) — \(pct(share)) of the measured total"
            + (leader.days > 1 ? "" : ", from a single day")
    }

    /// The coverage line every Sources list carries: how many days the range actually held,
    /// how many of them measured this nutrient, and (when any row didn't) that the total is a
    /// floor. Never presents a gap as a zero day.
    static func coverageLine(_ r: NutrientSourceRanking) -> String {
        var out = "Known on \(r.daysKnown) of \(r.daysInRange) logged "
            + "\(r.daysInRange == 1 ? "day" : "days") in this range."
        if r.isPartial {
            out += " \(r.unmeasuredItems) logged \(r.unmeasuredItems == 1 ? "food" : "foods") "
                + "in the range carry no measured value, so the total is at least this much."
        }
        if r.hiddenContributors > 0 {
            out += " \(r.hiddenContributors) smaller "
                + "\(r.hiddenContributors == 1 ? "contributor is" : "contributors are") not listed."
        }
        return out
    }

    /// A whole-number percentage, matching the drill-down's share formatting.
    static func pct(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
