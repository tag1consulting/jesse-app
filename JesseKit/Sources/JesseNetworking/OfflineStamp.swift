import Foundation

/// How old the thing on screen is, in one short phrase, for the offline banner.
///
/// A banner that says only "showing the last day loaded" leaves the one question the
/// user actually has unanswered: is this from four minutes ago or from Tuesday? The
/// answer changes what they do with it, so it is part of the sentence rather than a
/// detail behind a tap.
///
/// PURE and injected-clock, deliberately: `RelativeDateTimeFormatter` is locale- and
/// calendar-sensitive and would make every assertion about this string a test of
/// Foundation. The vocabulary here is small and fixed because the range that matters is
/// small — anything past a few days is "a while ago" and the number stops helping.
public enum OfflineStamp {
    /// The phrase for a document fetched at `fetchedAt`, or `nil` when nothing is known
    /// about when it arrived (an in-memory snapshot from this session's own first load,
    /// which needs no stamp).
    ///
    /// A `fetchedAt` in the FUTURE reads as "just now" rather than as a negative age:
    /// the clock moving backwards (a timezone change, a corrected system time) is not
    /// something to report to the user as data about their day.
    public static func text(fetchedAt: Date?, now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 60 else { return "last updated just now" }
        let minutes = Int(age / 60)
        if minutes < 60 {
            return "last updated \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "last updated \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = hours / 24
        if days == 1 { return "last updated yesterday" }
        if days < 7 { return "last updated \(days) days ago" }
        return "last updated more than a week ago"
    }

    /// The whole banner line for a cached document: what it is, then how old.
    ///
    /// One function so the two tabs on two platforms cannot end up with four spellings
    /// of the same sentence.
    public static func cachedLine(_ lead: String, fetchedAt: Date?, now: Date) -> String {
        guard let age = text(fetchedAt: fetchedAt, now: now) else { return lead }
        return "\(lead) — \(age)."
    }
}
