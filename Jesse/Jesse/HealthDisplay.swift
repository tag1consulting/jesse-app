import Foundation

// Pure, Foundation-only view logic for the Health tab — the seam the view tests
// drive instead of snapshots: staleness, the "updated HH:MM" stamp, the weight
// card's same-day-vs-fallback resolution, the moving-average series for the chart,
// and per-section availability. No SwiftUI, no `Date()` reached implicitly (the
// caller injects `now`/timeZone), so each rule is deterministic.

enum HealthDisplay {

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
