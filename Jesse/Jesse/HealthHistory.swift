import Foundation

// Pure, Foundation-only logic for paging the Health tab back through earlier days
// (bridge ≥ 0.7.0). NOTHING here touches SwiftUI. Three concerns, each unit-tested:
//
//  * DietPaging — the nearest earlier/later available day and the end-of-range
//    disabled state, over the bridge's `availableDays` list.
//  * HistoryRender — the current-hour the DietSemantics engine gets for a day: the
//    real clock for today, end-of-day (24) for a past day so time-gated flags are
//    fully resolved rather than suppressed by the render-time clock.
//  * NeutralMode / HistoryUI — the neutral (no-judgment) rendering selection for a
//    reconstructed day, and which chrome (stale banner, current-state nav rows,
//    quick log, footer text) a past day shows.

/// Navigation over the bridge's `availableDays` (sorted ascending, deduped). The
/// "current" date is either a past day being viewed or today; forward from the last
/// past day lands on today because today is itself in `availableDays`.
struct DietPaging: Equatable, Sendable {
    /// Ascending, deduped available days. Defensive: re-sorted/deduped on init so a
    /// malformed payload can't break the nearest-neighbour math.
    let days: [String]
    /// The live day (today's date). Always treated as available even if a
    /// degraded payload omitted it.
    let today: String

    init(days: [String], today: String) {
        var set = Set(days)
        set.insert(today)
        self.days = set.sorted()
        self.today = today
    }

    /// The nearest available day strictly before `date`, or nil if `date` is the
    /// earliest (the back chevron is then disabled).
    func earlier(than date: String) -> String? { days.last { $0 < date } }

    /// The nearest available day strictly after `date`, or nil if `date` is the
    /// latest (which is today — the forward chevron is then disabled).
    func later(than date: String) -> String? { days.first { $0 > date } }

    func canGoBack(from date: String) -> Bool { earlier(than: date) != nil }
    func canGoForward(from date: String) -> Bool { later(than: date) != nil }
}

enum HistoryRender {
    /// The hour to feed `DietSemantics.gauges(for:hour:)`. Today uses the real
    /// clock; any past day uses end-of-day (24) so the after-4pm gated flags
    /// (protein/fat "low" nags) are fully resolved for a completed day rather than
    /// suppressed by whatever time it happens to be when the user pages back.
    static let endOfDayHour = 24
    static func engineHour(isHistorical: Bool, clockHour: Int) -> Int {
        isHistorical ? endOfDayHour : clockHour
    }
}

/// The neutral (no-judgment) center labels + captions for a reconstructed day,
/// where targets were never recorded. Grouping is the locale's thousands separator,
/// injected for deterministic tests.
enum NeutralMode {
    static let noTargetsCaption = "No targets recorded for this day"

    /// The calories hero center on a neutral day: the eaten total, e.g. "1,840
    /// eaten".
    static func caloriesCenter(_ totals: MacroTotals, locale: Locale = .current) -> String {
        "\(CaloriesHero.grouped(totals.cal, locale: locale)) eaten"
    }

    /// The caption under the neutral calories hero: the burned/net line when a burn
    /// exists, else nil (no target to talk about, so nothing when there's no burn).
    static func caloriesCaption(net: NetCalories, locale: Locale = .current) -> String? {
        guard net.burned > 0 else { return nil }
        return "\(CaloriesHero.grouped(net.burned, locale: locale)) burned · \(CaloriesHero.grouped(net.net, locale: locale)) net"
    }

    /// A macro ring's center on a neutral day: the plain gram total, e.g. "142g".
    static func macroCenter(_ grams: Double) -> String {
        "\(DietSemantics.fmt(grams))g"
    }
}

/// Which rendering mode a day uses, and which chrome a past day hides. All pure so
/// the visibility rules are unit-tested, never a scattered view guess.
enum HistoryUI {
    enum Mode: Equatable, Sendable { case full, neutral }

    /// A reconstructed day renders neutral (no judgment); live/archived render full.
    static func mode(fidelity: DietFidelity) -> Mode {
        fidelity == .reconstructed ? .neutral : .full
    }

    /// The stale ("nothing logged today yet") banner is suppressed on a past day —
    /// a completed day is not "stale".
    static func suppressesStaleBanner(isHistorical: Bool) -> Bool { isHistorical }

    /// Coach / Progress & pace nav rows are current-state only (the bridge returns
    /// them null on history), so they are hidden on a past day.
    static func showsCurrentStateRows(isHistorical: Bool) -> Bool { !isHistorical }

    /// Quick log ("+") is hidden on a past day — the logging path only logs today.
    static func showsQuickLog(isHistorical: Bool) -> Bool { !isHistorical }

    /// The footer line under the day: the "Updated HH:MM" mtime stamp for today, or
    /// a fidelity label ("Archived day" / "Rebuilt from logs") for a past day.
    static func footer(isHistorical: Bool, fidelity: DietFidelity, updated: String?) -> String? {
        if isHistorical {
            switch fidelity {
            case .archived: return "Archived day"
            case .reconstructed: return "Rebuilt from logs"
            case .live: return updated.map { "Updated \($0)" }
            }
        }
        return updated.map { "Updated \($0)" }
    }
}
