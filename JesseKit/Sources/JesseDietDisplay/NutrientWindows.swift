import Foundation
import JesseNetworking

// The Health tab's Day / 7d / 30d window switcher, as pure Foundation-only logic — no
// SwiftUI, no `Date()` read, every rule deterministically testable. `NutrientTrends`
// already knows how to reduce one nutrient over one window (median, coverage, the
// under/over counts); this file is the thin layer that turns that analysis into the SAME
// `MetricGauge` the day-scoped rows already render, so the switcher changes the DATA a
// gauge reads and its coverage caption, and nothing else.
//
// The doctrine carried from the rest of the stack: UNKNOWN IS NOT ZERO. Every windowed
// number is over the days the nutrient was actually measured; a gap is never a low day,
// coverage is stated on every row, and a window with too few known days says "not enough
// data" instead of picking a colour it has not earned.

// MARK: - The mode

/// Which read the Health tab is showing. `day` is the pre-existing screen, byte-for-byte:
/// today's numbers, judged the way the judgment-window work already judges them. `week`
/// and `month` reframe every nutrient to its rolling read over that window.
///
/// Deliberately NOT persisted anywhere: it lives on `HealthDashboardModel` for the life of
/// the session and a fresh launch starts on `day`. The day is the thing you can still act
/// on; a window is a review you opt into.
public enum NutrientWindowMode: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }

    /// The segmented control's label.
    public var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    /// The trailing window in days, or nil for the single-day mode.
    var days: Int? {
        switch self {
        case .day: return nil
        case .week: return 7
        case .month: return 30
        }
    }

    var isRolling: Bool { days != nil }
}

// MARK: - One nutrient's windowed read

/// The reframed read of ONE nutrient over ONE rolling window: the median of its known
/// days, how much coverage that median rests on, and whether the window has earned a
/// pass/fail verdict at all. Rides on the `MetricGauge` the row already renders so the
/// window chip and the coverage caption never have to be recomputed by a view.
struct NutrientWindowRead: Equatable, Sendable {
    let nutrient: TrendNutrient
    /// The window's length in days (7 or 30) — the chip's number.
    let windowDays: Int
    /// Days this nutrient carried a known value inside the window.
    let daysKnown: Int
    /// Logged days inside the window (the coverage denominator — see
    /// `NutrientTrend.daysInWindow`).
    let daysInWindow: Int
    /// How many of the known days were PARTIAL (a lower bound, at least one item that day
    /// carried no value).
    let partialCount: Int
    /// The median of the known days, or nil when there are none. Never a 0 stand-in.
    let median: Double?
    /// The smallest / largest known day — the distribution, which is the WHOLE story for
    /// an informational nutrient (it never gets a verdict).
    let minKnown: Double?
    let maxKnown: Double?
    /// The reference target, or nil when the day carries none.
    let target: Double?
    /// True when the median carries a real pass/fail verdict: a judged nutrient, with a
    /// usable goal, over enough known days. False for every informational nutrient (in
    /// every mode) and for a window too thin to assert a pattern.
    let hasVerdict: Bool
    /// True when the nutrient IS judged and DOES have a goal, but the window holds fewer
    /// than `NutrientTrends.minKnownForDirection` known days — so the row says "not enough
    /// data" rather than showing a colour it hasn't earned.
    let isThin: Bool

    /// The window chip beside the nutrient's name ("7d" / "30d") — so a colour standing
    /// next to a median is never read as a verdict on today.
    var chip: String { "\(windowDays)d" }

    /// The coverage caption, always stated in known-days-out-of-logged-days terms.
    /// Thin windows lead with "not enough data"; a window with no known day at all says so
    /// rather than showing a zero.
    var coverage: String {
        guard daysKnown > 0 else {
            return daysInWindow > 0
                ? "no known days in the last \(daysInWindow) logged days"
                : "no logged days in this window"
        }
        let known = "known \(daysKnown) of \(daysInWindow) logged days"
        let partial = partialCount > 0 ? " · \(partialCount) partial" : ""
        return (isThin ? "not enough data — \(known)" : known) + partial
    }
}

// MARK: - Engine

enum NutrientWindows {
    /// Analyse ONE nutrient over ONE rolling window. Everything is delegated to
    /// `NutrientTrends.analyze` (which already skips gap days, anchors the window on the
    /// nutrient's own last reading, and counts coverage) and to `NutrientTrends.bands`
    /// (the very same band helpers the daily gauge uses) — so a windowed colour and a
    /// daily colour can never come from two different sets of thresholds.
    static func read(_ nutrient: TrendNutrient, series: [NutrientDay],
                     targets: DietTargets, windowDays: Int) -> NutrientWindowRead {
        let t = NutrientTrends.analyze(series, nutrient: nutrient, targets: targets,
                                       windowDays: windowDays)
        // A nutrient with no `dayGoal` (total sugars, unsaturated fat) is informational and
        // NEVER gains a verdict from a window — a median it can't judge today is still a
        // median it can't judge over thirty days. Likewise a judged nutrient with no usable
        // goal (`.noGoal` — no target in the day's file) makes no claim.
        var hasVerdict = false
        var isThin = false
        if let median = t.median, nutrient.dayGoal != nil {
            let bands = NutrientTrends.bands(nutrient, value: median, target: t.target)
            if bands.goalStatus != .noGoal {
                if t.daysKnown >= NutrientTrends.minKnownForDirection {
                    hasVerdict = true
                } else {
                    isThin = true
                }
            }
        }
        return NutrientWindowRead(
            nutrient: nutrient, windowDays: windowDays,
            daysKnown: t.daysKnown, daysInWindow: t.daysInWindow,
            partialCount: t.partialCount, median: t.median,
            minKnown: t.minKnown, maxKnown: t.maxKnown, target: t.target,
            hasVerdict: hasVerdict, isThin: isThin)
    }

    /// The bar reference a windowed row draws its fill and its "/ target" against. Total fat
    /// is the one nutrient whose gauge reference is not the day's target: the daily fat
    /// gauge draws against the fixed 65 g working cap (`DietSemantics.fatCap`), and the
    /// windowed row uses the same one so the two never disagree.
    static func displayTarget(_ nutrient: TrendNutrient, read: NutrientWindowRead) -> Double? {
        nutrient == .f ? DietSemantics.fatCap : read.target
    }

    /// ONE nutrient's windowed row, as the very same `MetricGauge` the day-scoped rows
    /// render. What changes versus the day gauge: `value` is the window's MEDIAN rather
    /// than today's total, `remaining` carries the coverage caption rather than a
    /// to-go/room-for phrase, and `windowRead` supplies the chip. What does NOT change:
    /// the band helpers, the tone mapping, and the row view.
    ///
    /// The tone is derived at `DietSemantics.settledHour` on purpose. A rolling read speaks
    /// to days that are already over, so the day-in-progress softening `nagHour` provides
    /// must not apply: a month-long shortfall is not "still in progress, come back later".
    ///
    /// A row with NO verdict — informational, no usable goal, or a window too thin — is
    /// `.suspended` / `.noGoal` / `.inProgress`: shown plain, no colour claimed. A window
    /// with no known day at all sets `knownItemCount` to 0, which is the row's existing
    /// "nothing measured" state, captioned from the read instead of showing a phantom zero.
    static func gauge(_ nutrient: TrendNutrient, series: [NutrientDay],
                      targets: DietTargets, windowDays: Int) -> MetricGauge {
        let read = read(nutrient, series: series, targets: targets, windowDays: windowDays)
        let reference = displayTarget(nutrient, read: read)
        let median = read.median ?? 0

        var g = MetricGauge(
            label: nutrient.fullName, goal: nutrient.displayGoal, value: median,
            target: reference, status: .suspended, remaining: caption(read),
            goalStatus: .noGoal, tone: .inProgress, flag: nil, unit: nutrient.unit,
            fraction: read.median.flatMap { m in reference.flatMap { DietSemantics.fraction(m, $0) } },
            windowRead: read)

        // No known day in the window → the row's "nothing measured" state, captioned by
        // the read. Never a 0 bar, because unknown is not zero.
        if read.daysKnown == 0 {
            g.knownItemCount = 0
            g.fraction = nil
            return g
        }
        guard read.hasVerdict, let m = read.median else { return g }

        let bands = NutrientTrends.bands(nutrient, value: m, target: read.target)
        g.status = bands.status
        g.goalStatus = bands.goalStatus
        g.tone = DietSemantics.tone(goalStatus: bands.goalStatus,
                                    hour: DietSemantics.settledHour,
                                    target: reference, nearGoal: bands.status == .green,
                                    hardOver: bands.hardOver)
        return g
    }

    /// The row's caption. A judged nutrient states coverage; an informational one states
    /// its DISTRIBUTION first (that is the only thing it is allowed to say) and coverage
    /// after, so a reader is never left looking for a verdict that will not come.
    private static func caption(_ read: NutrientWindowRead) -> String {
        guard read.nutrient.dayGoal == nil, let lo = read.minKnown, let hi = read.maxKnown,
              lo != hi else { return read.coverage }
        return "range \(NutrientTrends.fmt(lo))–\(NutrientTrends.fmt(hi)) \(read.nutrient.unit) · \(read.coverage)"
    }

    /// The nutrients a rolling mode lists, in canonical `TrendNutrient` order: every
    /// nutrient measured on at least one day of the whole series. A nutrient the bridge has
    /// never carried a value for is omitted entirely rather than shown as a permanent
    /// blank — the same gate the day screen applies to an untracked micronutrient.
    static func trackedNutrients(_ series: [NutrientDay]) -> [TrendNutrient] {
        TrendNutrient.allCases.filter { n in
            series.contains { ($0.nutrients[n.key]?.known ?? 0) >= 1 }
        }
    }

    /// Every tracked nutrient's windowed row for one window, in canonical order.
    static func gauges(series: [NutrientDay], targets: DietTargets,
                       windowDays: Int) -> [(nutrient: TrendNutrient, gauge: MetricGauge)] {
        trackedNutrients(series).map {
            ($0, gauge($0, series: series, targets: targets, windowDays: windowDays))
        }
    }

    /// The one-line footnote under a rolling list, spelling out what a median over known
    /// days does and does not claim. Stated once per screen rather than per row.
    static let coverageFootnote =
        "Each row is the median of the days this nutrient was actually measured. "
        + "A day it wasn't measured is a gap, never a zero, so it neither lowers the median "
        + "nor counts against the goal."
}
