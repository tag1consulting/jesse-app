import Foundation

// Pure, SwiftUI-free presentation model for the thread list's collapsible month
// folders. Kept Foundation-only so folding/expansion is unit-testable without a
// view host, mirroring ThreadSectioning / ThreadSearch / ThreadRowPreview.
//
// Older date buckets (the month sections from `threadSection`) render as
// FOLDERS: collapsed by default, their conversation rows hidden behind a header
// that shows a deterministic count + date-range summary, so the list actually
// shrinks for old history instead of just gaining a header. Recent day buckets
// (today / yesterday / the single weekday) stay as loose, always-expanded rows.
// The Favorites tab is always a flat newest-first list, and any active search
// force-expands every folder so no match can hide behind a collapsed header.

extension ThreadSection {
    /// Month buckets fold; day buckets (today / yesterday / weekday) stay loose.
    var isFolder: Bool {
        if case .month = self { return true }
        return false
    }
}

/// One date section as it should render: its members, whether it's a collapsible
/// folder (month bucket), and whether it's currently expanded. `visibleThreads`
/// is what's actually on screen — empty for a collapsed folder.
struct RenderedThreadSection: Identifiable {
    let section: ThreadSection
    let threads: [JesseThread]
    let isFolder: Bool
    let isExpanded: Bool

    var id: ThreadSection { section }

    /// Rows on screen now: the members when loose or expanded, none when a folder
    /// is collapsed (the whole point — collapse hides the rows, not just chrome).
    var visibleThreads: [JesseThread] { isExpanded ? threads : [] }
}

/// The two shapes the list takes. Favorites is a single flat list (no folders);
/// the All tab is date sections, month buckets rendered as collapsible folders.
enum ThreadListLayout {
    case flat([JesseThread])
    case sectioned([RenderedThreadSection])
}

/// Build the list presentation from raw threads. Pure — no wall clock, no view —
/// so callers pass a fixed `now`/`calendar` in tests and `.now`/`.current` in the
/// view.
///
/// - `favoritesOnly` collapses to a single flat, newest-first list of starred
///   threads with no folder chrome (the "jump straight back" tab).
/// - A non-empty `searchQuery` filters (title + turn bodies, via `threadMatches`)
///   BEFORE grouping and force-expands every month folder, so a match never hides
///   behind a collapsed header; clearing the query restores collapsed folders.
/// - `expanded` is the set of month sections the user has opened. Month folders
///   default collapsed (absent from the set); day sections are always expanded.
func threadListLayout(_ threads: [JesseThread],
                      favoritesOnly: Bool,
                      searchQuery: String,
                      expanded: Set<ThreadSection>,
                      now: Date,
                      calendar: Calendar) -> ThreadListLayout {
    let scoped = favoritesOnly ? threads.filter(\.isFavorite) : threads
    let matched = scoped.filter { threadMatches($0, query: searchQuery) }
    let searchActive = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    // Favorites tab: always one flat, newest-first list. Favorites are few and
    // this is the direct path back to them — folders would only add friction.
    if favoritesOnly {
        return .flat(matched.sorted { $0.updatedAt > $1.updatedAt })
    }

    let grouped = Dictionary(grouping: matched) {
        threadSection(for: $0.updatedAt, now: now, calendar: calendar)
    }
    let sections = grouped
        .map { section, members -> RenderedThreadSection in
            let folder = section.isFolder
            // Day sections are always expanded. Month folders default collapsed;
            // an active search force-expands them so every match stays visible.
            let expandedNow = !folder || searchActive || expanded.contains(section)
            return RenderedThreadSection(
                section: section,
                threads: members.sorted { $0.updatedAt > $1.updatedAt },
                isFolder: folder,
                isExpanded: expandedNow)
        }
        .sorted { $0.section.sortKey > $1.section.sortKey }
    return .sectioned(sections)
}

/// A short, deterministic folder-summary label for a collapsed month folder:
/// `"<N> conversations · <date range>"`, where N is the thread count (singular
/// "1 conversation") and the range spans the min–max last-activity date in the
/// bucket, formatted compactly. No AI, no network — purely count + date range.
///
/// Foundation-only and deterministic given a fixed `calendar`/`locale`. Empty
/// input returns "" (the view never renders a folder for an empty bucket, but the
/// guard keeps the function total).
func folderSummary(for threads: [JesseThread], calendar: Calendar, locale: Locale) -> String {
    guard !threads.isEmpty else { return "" }
    let count = threads.count
    let noun = count == 1 ? "conversation" : "conversations"
    let dates = threads.map(\.updatedAt)
    let range = compactDateRange(from: dates.min()!, to: dates.max()!,
                                 calendar: calendar, locale: locale)
    return "\(count) \(noun) · \(range)"
}

/// Compact rendering of a date span. Single day → "Jun 3"; same month →
/// "Jun 3–28"; same year, different months → "Jun 28–Jul 3"; different years →
/// "Dec 28 2025–Jan 3 2026". `lo`/`hi` are the earlier/later instants.
private func compactDateRange(from lo: Date, to hi: Date,
                              calendar: Calendar, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone

    let loParts = calendar.dateComponents([.year, .month, .day], from: lo)
    let hiParts = calendar.dateComponents([.year, .month, .day], from: hi)

    func string(_ date: Date, _ format: String) -> String {
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // Same calendar day → a single date, no range.
    if loParts == hiParts {
        return string(lo, "MMM d")
    }
    let sameYear = loParts.year == hiParts.year
    let sameMonth = sameYear && loParts.month == hiParts.month
    if sameMonth {
        // "Jun 3–28" — repeat neither the month nor the year.
        return "\(string(lo, "MMM d"))–\(string(hi, "d"))"
    }
    if sameYear {
        // "Jun 28–Jul 3" — month on both sides, year still implied.
        return "\(string(lo, "MMM d"))–\(string(hi, "MMM d"))"
    }
    // "Dec 28 2025–Jan 3 2026" — spell out both years across a boundary.
    return "\(string(lo, "MMM d yyyy"))–\(string(hi, "MMM d yyyy"))"
}
