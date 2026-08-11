import WidgetKit
import SwiftUI

// The Today complication: how much is left, and the one thing that matters most.
//
// It renders from `WatchTodayStore` — the app-group file the watch app writes every
// time the phone pushes a day — and from nothing else. A widget extension is its own
// process: it holds no `WCSession`, makes no network call, and has no bridge token,
// which is the same rule the watch app itself follows one level up.
//
// ## Why the timeline has two entries and no refresh policy
//
// The data changes when the PHONE says so, and the watch app calls
// `WidgetCenter.reloadAllTimelines()` the moment it does — so there is nothing for a
// polling policy to discover, and `.never` is the honest answer. The one thing that
// changes on its own is AGE: eighteen hours after the push the same data stops being
// today's. That is a known instant, so it gets its own entry rather than a timer.

struct JesseTodayEntry: TimelineEntry {
    let date: Date
    let summary: WatchTodaySummary?
    /// Whether the payload had aged past the stale window by `date`. Precomputed
    /// rather than derived in the view, so the two timeline entries differ in the
    /// data and not in how they are drawn.
    let isStale: Bool

    /// The row worth a complication: the standing lead item, else the first open Do
    /// Now row. Nil when the day has nothing in it.
    var topRow: WatchTodayRow? {
        summary?.rows.first { $0.isLead && !$0.checked }
            ?? summary?.rows.first { !$0.checked }
    }

    var count: Int { summary?.doNowOpenCount ?? 0 }
}

struct JesseTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> JesseTodayEntry {
        JesseTodayEntry(date: Date(), summary: Self.sample, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (JesseTodayEntry) -> Void) {
        let stored = WatchTodayStore.load()
        // The gallery preview must show something recognisable; a real reading only
        // once there is one.
        completion(entry(for: context.isPreview ? Self.sample : stored, at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JesseTodayEntry>) -> Void) {
        let now = Date()
        let stored = WatchTodayStore.load()
        var entries = [entry(for: stored, at: now)]
        // The moment this reading stops being today's. Only worth an entry if it is
        // still in the future — a day already past the window renders stale from the
        // first entry.
        if let pushedAt = stored?.pushedAt {
            let expires = pushedAt.addingTimeInterval(WatchTodayWire.staleAfter)
            if expires > now { entries.append(entry(for: stored, at: expires.addingTimeInterval(1))) }
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entry(for summary: WatchTodaySummary?, at date: Date) -> JesseTodayEntry {
        let stale = summary.map { date.timeIntervalSince($0.pushedAt) > WatchTodayWire.staleAfter }
            ?? false
        return JesseTodayEntry(date: date, summary: summary, isStale: stale)
    }

    private static let sample = WatchTodaySummary(
        date: nil, etag: nil, pushedAt: Date(),
        rows: [WatchTodayRow(id: "sample", lead: "Finish the rebuild", checked: false, section: "")],
        openCount: 4, doneCount: 2, doNowOpenCount: 4)
}

struct JesseTodayComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JesseTodayComplication", provider: JesseTodayProvider()) { entry in
            JesseTodayComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("How much Do Now work is left, and what's at the top of it.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner,
                            .accessoryInline, .accessoryRectangular])
    }
}

struct JesseTodayComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JesseTodayEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            // One line, system-styled, no colour of its own. Nothing but the count
            // and the lead fits, and the lead is what the glance is for.
            Text(inlineText)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: symbol)
                        .font(.caption2)
                    Text("\(entry.count)")
                        .font(.title3.weight(.semibold))
                }
            }
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .widgetLabel { Text(cornerLabel) }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label(headline, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                Text(entry.topRow?.lead ?? "Nothing waiting.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// `sunrise` when the day is current — the same glyph the phone's Today tab, the
    /// day screen's empty state and the Health tab's Start-new-day button carry, so
    /// one symbol keeps meaning one thing across all three devices. A stale reading
    /// swaps it for a clock, because the number below it is no longer about today.
    private var symbol: String { entry.isStale ? "clock.badge.exclamationmark" : "sunrise" }

    private var headline: String {
        if entry.isStale { return "Out of date" }
        return entry.count == 1 ? "1 to do now" : "\(entry.count) to do now"
    }

    private var inlineText: String {
        guard !entry.isStale else { return "Jesse: out of date" }
        guard let lead = entry.topRow?.lead else { return "Jesse: \(entry.count) to do" }
        return "\(entry.count) · \(lead)"
    }

    private var cornerLabel: String {
        entry.isStale ? "Out of date" : "\(entry.count) to do now"
    }
}
