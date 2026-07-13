import Foundation

// Pure, Foundation-only view logic for the Health tab — the seam the view tests
// drive instead of snapshots: staleness, the "updated HH:MM" stamp, the weight
// card's same-day-vs-fallback resolution, the moving-average series for the chart,
// and per-section availability. No SwiftUI, no `Date()` reached implicitly (the
// caller injects `now`/timeZone), so each rule is deterministic.

enum HealthDisplay {

    // MARK: - Header date

    /// The navigation-title date, formatted Apple-Fitness style ("Saturday, July
    /// 12") from an ISO "yyyy-MM-dd" string. Locale-aware: the ordering and month
    /// name come from the locale via a localized template, so a non-US locale reads
    /// naturally. Returns the raw string unchanged if it doesn't parse.
    static func headerDate(_ iso: String, locale: Locale = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let inF = DateFormatter()
        inF.calendar = cal
        inF.timeZone = cal.timeZone
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.calendar = cal
        out.timeZone = cal.timeZone
        out.locale = locale
        out.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return out.string(from: d)
    }

    // MARK: - Staleness & the "updated" stamp

    /// Whether `todayDate` ("YYYY-MM-DD") is NOT the device's current local day —
    /// i.e. nothing has been logged/regenerated today yet, so the screen is showing
    /// a prior day. The banner text is the caller's; this is the decision.
    static func isStale(todayDate: String, now: Date,
                        calendar: Calendar = .current) -> Bool {
        todayDate != isoDay(now, calendar: calendar)
    }

    /// "YYYY-MM-DD" for `date` in the calendar's time zone.
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local "HH:MM" for an RFC3339 UTC mtime string (`2026-07-09T13:34:54Z`), or
    /// nil if absent/unparseable. The bridge emits UTC; this renders it in the
    /// device's zone so "updated 15:34" matches the user's clock.
    static func updatedTime(fromMtime mtime: String?,
                            timeZone: TimeZone = .current) -> String? {
        guard let mtime, let date = rfc3339(mtime) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// Parse an RFC3339 UTC timestamp. Uses `ISO8601DateFormatter` (with and without
    /// fractional seconds) so both `…54Z` and `…54.123Z` parse.
    static func rfc3339(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }

    // MARK: - Weight card

    /// The compact weight card. `isTodayWeighIn` distinguishes a real same-day
    /// weigh-in (BF/lean shown) from a fallback to the last logged weigh-in (BF/lean
    /// deliberately suppressed — absence is the honest signal on a non-weigh-in day).
    struct WeightCard: Equatable, Sendable {
        var lbs: Double
        var kg: Double?
        var bf: Double?          // only ever set from a same-day weigh-in
        var leanLbs: Double?     // only ever set from a same-day weigh-in
        var deltaLbs: Double?    // vs the previous weigh-in in the series
        var isTodayWeighIn: Bool
        var lastWeighInDate: String?  // sublabel when falling back (nil when today)
    }

    /// Resolve the weight card from today's weigh-in (if any) and the weight series.
    /// On a weigh-in day: today's lbs/kg + BF%/lean (from `mm`) and the delta vs the
    /// previous series entry. On a non-weigh-in day: the LAST series entry's lbs/kg
    /// with a "last weigh-in <date>" sublabel and NO BF/lean carried forward. Returns
    /// nil only when there's no weight anywhere.
    static func weightCard(today: DietToday, series: [WeightPoint]?) -> WeightCard? {
        let series = series ?? []
        if let w = today.weight {
            // Same-day weigh-in: delta vs the last entry strictly before today.
            let prior = series.last { $0.date < today.date }
            return WeightCard(
                lbs: w.lbs, kg: w.kg, bf: w.bf, leanLbs: w.mm,
                deltaLbs: prior.map { w.lbs - $0.lbs },
                isTodayWeighIn: true, lastWeighInDate: nil)
        }
        // No weigh-in today: fall back to the last logged weigh-in.
        guard let last = series.last else { return nil }
        let prior = series.dropLast().last
        return WeightCard(
            lbs: last.lbs, kg: last.kg, bf: nil, leanLbs: nil,
            deltaLbs: prior.map { last.lbs - $0.lbs },
            isTodayWeighIn: false, lastWeighInDate: last.date)
    }

    // MARK: - Body-fat series availability (chart)

    /// Whether the weight series carries any body-fat reading at all. The BF chart
    /// exists iff this is true — there is no toggle; when no row has `bf`, no BF UI
    /// is rendered. Pure so the availability rule is unit-tested, not a view detail.
    static func hasBodyFat(_ series: [WeightPoint]) -> Bool {
        series.contains { $0.bf != nil }
    }

    // MARK: - Calorie-source split (food-journal summary bar)

    /// The kcal contribution of each macro to the day's intake, at the standard
    /// Atwater factors (protein 4, net-carbs 4, fiber 4, fat 9 kcal/g), with fiber
    /// carved out of carbs as its own contribution. Fiber grams are a SUBSET of carb
    /// grams (US-label total-carbohydrate convention — verified in the audit, see
    /// STATUS §Y), so the fiber slice (4 kcal/g) comes out of the carb slice:
    /// `netCarbsKcal + fiberKcal` always equals the old single carb term
    /// (`carbs * 4`), the combined carbs+fiber width equals the old carb width, and
    /// the four segments still sum to the same whole the old three did. `total` is the
    /// sum of the macro-derived calories (NOT the logged `cal`, which can differ) so
    /// the stacked bar's segments always sum to its whole. Fractions are 0 when empty.
    struct CalorieSplit: Equatable, Sendable {
        var proteinKcal: Double
        var netCarbsKcal: Double
        var fiberKcal: Double
        var fatKcal: Double
        var total: Double { proteinKcal + netCarbsKcal + fiberKcal + fatKcal }
        var proteinFraction: Double { total > 0 ? proteinKcal / total : 0 }
        var netCarbsFraction: Double { total > 0 ? netCarbsKcal / total : 0 }
        var fiberFraction: Double { total > 0 ? fiberKcal / total : 0 }
        var fatFraction: Double { total > 0 ? fatKcal / total : 0 }

        /// The width fraction for a macro's bar segment. The carbs segment carries the
        /// NET-carb width (fiber is carved out into its own adjacent segment), so the
        /// carbs + fiber segments together fill exactly the width the carb segment
        /// alone used to. Lets the bar iterate `Macro.allCases` instead of naming each
        /// segment in a fixed order.
        func fraction(for macro: Macro) -> Double {
            switch macro {
            case .protein: return proteinFraction
            case .carbs: return netCarbsFraction
            case .fiber: return fiberFraction
            case .fat: return fatFraction
            }
        }
    }

    /// Atwater kcal split of a day's macro totals, with fiber carved out of carbs.
    /// Robustness lives here, not in the view: fiber is clamped to `[0, carbs]`, so a
    /// missing or negative fiber yields no fiber segment (all carbs stay in net-carbs)
    /// and a fiber value exceeding carbs never drives the net-carb term negative.
    static func calorieSplit(_ totals: MacroTotals) -> CalorieSplit {
        let carbs = max(totals.c, 0)
        let fiber = min(max(totals.fiber, 0), carbs)   // 0 ≤ fiber ≤ carbs
        return CalorieSplit(
            proteinKcal: totals.p * 4,
            netCarbsKcal: (carbs - fiber) * 4,
            fiberKcal: fiber * 4,
            fatKcal: totals.f * 9)
    }

    // MARK: - Moving average (chart)

    /// One point on the moving-average line: the series date and the trailing
    /// N-point average of `lbs` ending at that date.
    struct AveragePoint: Equatable, Sendable {
        var date: String
        var value: Double
    }

    /// A trailing `window`-point moving average of the series' `lbs`, one output
    /// per input point (a shorter window at the start where fewer points exist).
    /// The series is already chronological; the caller filters the range first.
    static func movingAverage(_ series: [WeightPoint], window: Int = 7) -> [AveragePoint] {
        guard window > 0 else { return [] }
        var out: [AveragePoint] = []
        out.reserveCapacity(series.count)
        for i in series.indices {
            let start = max(0, i - window + 1)
            let slice = series[start...i]
            let avg = slice.reduce(0.0) { $0 + $1.lbs } / Double(slice.count)
            out.append(AveragePoint(date: series[i].date, value: avg))
        }
        return out
    }

    // MARK: - Section availability (nav rows)

    /// Whether a nav row's section is present, or unavailable (its file failed to
    /// parse bridge-side — surfaced from `errors`, not hidden, so a parse problem is
    /// visible not silent).
    enum Availability: Equatable, Sendable {
        case present
        case unavailable(String)   // the human-readable reason from `errors`
    }

    /// Resolve availability for a section: present when its value is non-nil, else
    /// unavailable with the matching `errors` line (by its `"<label>:"` prefix) or a
    /// generic reason.
    static func availability(present: Bool, label: String, errors: [String]) -> Availability {
        if present { return .present }
        if let line = errors.first(where: { $0.lowercased().hasPrefix("\(label.lowercased()):") }) {
            return .unavailable(line)
        }
        return .unavailable("\(label) unavailable")
    }
}
