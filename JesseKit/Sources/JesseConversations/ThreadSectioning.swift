import Foundation

// Pure, SwiftUI-free date bucketing for the thread list. Kept in its own file
// (Foundation only) so the classifier is unit-testable without a view host.
//
// The window is the last 3 calendar days at day granularity, with everything
// older rolled up by month and no gap between the two:
//   • Today / Yesterday          — 0 / 1 days ago
//   • a weekday section          — 2 days ago (titled "Monday", etc.)
//   • a month section each        — 3+ days ago (titled "June 2026")
// A thread exactly 3 days old, or 3+ days old in the current month, lands in
// its month section even while more-recent threads of that month sit under day
// headers — that's intended.

public enum ThreadSection: Hashable {
    case today
    case yesterday
    case weekday(Date)   // start-of-day for 2 days ago
    case month(Date)     // start-of-month for anything 3+ days ago

    /// Representative instant for ordering sections newest-first (sort
    /// descending). Today and Yesterday carry no date of their own, so they get
    /// sentinels that always outrank the real past dates of weekday/month
    /// sections — Today is the newest possible, Yesterday just behind it.
    public var sortKey: Date {
        switch self {
        case .today: return .distantFuture
        case .yesterday: return .distantFuture.addingTimeInterval(-1)
        case .weekday(let day): return day
        case .month(let month): return month
        }
    }

    /// Localized header text. Weekday → full name ("Monday"); month →
    /// "MMMM yyyy" ("June 2026"). Takes the calendar so the formatter's locale
    /// and time zone match the bucketing (and so tests stay deterministic).
    public func title(calendar: Calendar = .current) -> String {
        switch self {
        case .today:
            return String(localized: "Today")
        case .yesterday:
            return String(localized: "Yesterday")
        case .weekday(let day):
            return Self.formatted(day, format: "EEEE", calendar: calendar)
        case .month(let month):
            return Self.formatted(month, format: "MMMM yyyy", calendar: calendar)
        }
    }

    private static func formatted(_ date: Date, format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// Classify a thread's `updatedAt` into its list section, relative to `now`.
/// Pure — reads no wall clock — so callers pass a fixed `now`/`calendar` in
/// tests and `.now`/`.current` in the view.
public func threadSection(for date: Date, now: Date, calendar: Calendar) -> ThreadSection {
    let startOfToday = calendar.startOfDay(for: now)
    let startOfDate = calendar.startOfDay(for: date)
    let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0

    switch daysAgo {
    case ..<1:        // today, or a stray future timestamp
        return .today
    case 1:
        return .yesterday
    case 2:
        return .weekday(startOfDate)
    default:          // 3+ days ago
        let comps = calendar.dateComponents([.year, .month], from: date)
        return .month(calendar.date(from: comps) ?? startOfDate)
    }
}
