import Foundation
import JesseNetworking
import JesseTodayDisplay

// What the phone chooses to put on the wrist: a pure function from the day file to
// the compact `WatchTodaySummary` the watch renders.
//
// Phone-side on purpose. The watch target imports no JesseKit, because the watch
// never talks to the bridge and must not carry a type that knows how — so the
// SELECTION happens here, where `TodaySnapshot` and `TodaySemantics` live, and only
// the result crosses.
//
// ## The selection rule, and why it is this one
//
// A watch face is three or four legible lines. The day file routinely has forty
// items across eight sections. So the rule is the same one a person uses when
// glancing at their wrist:
//
//   1. **The standing lead item**, whatever its state. It is the day's one
//      top-priority line and it sits above every heading; it is also the only row
//      that can arrive already ticked, which is what makes unticking possible from
//      the wrist at all.
//   2. **Open `Do Now` work**, in file order, capped at ten. The same first-section
//      prefix match the tab badge and every optimistic move already use, so the
//      wrist and the phone never disagree about which section "Do Now" means.
//   3. **Numbers for the rest.** Everything else in the day is one line of footer.
//
// Done work and postponed work are both absent, for the same reason: neither is
// something to do now. Postponing in particular exists to take a row out of today's
// attention, and a watch that kept showing it would be the one screen where
// postponing did nothing.

// `nonisolated` because this is a pure function over value types and the app target
// defaults to MainActor isolation. The same reason `TodaySemantics` spells it out:
// the summary is built from the day model (on the main actor) and asserted against
// from tests that are not, and a MainActor default would silently make one an await.
nonisolated enum TodayWatchSummary {

    /// How many open `Do Now` rows make the trip. The standing lead item is NOT part
    /// of this cap — it is one row and it is the point of the screen.
    ///
    /// Ten is a scroll or two on the largest watch. Past that the list stops being a
    /// glance and the footer's "n more on your phone" is the better answer.
    static let maxDoNowRows = 10

    /// Summarise one day file for the wrist.
    ///
    /// `etag` is the caller's newest tag, used only when the snapshot carries none of
    /// its own. `at` is the phone's clock, and it becomes the stamp the watch's stale
    /// guard measures against — deliberately the PHONE's, because the phone is the
    /// one that knows when it last heard from the bridge.
    ///
    /// The row selection below is DELIBERATELY not `TodaySemantics.badgeItems`, which
    /// is the one definition of what the badge counts and what the phone's badge filter
    /// shows. The wrist wants a different set for a stated reason: it carries the
    /// standing lead item even when it is already ticked (unticking from the wrist is
    /// the point), and it caps the Do Now rows at ten. The one number that must agree
    /// with the phone, `doNowOpenCount`, is read from that function below, so the two
    /// devices cannot disagree about how much is left.
    static func build(from snapshot: TodaySnapshot, etag: String?, at now: Date) -> WatchTodaySummary {
        let leadRows = snapshot.leadItems
            .filter { !TodaySemantics.isPostponed($0) }
            .compactMap(row(for:))

        // The cap is applied AFTER unrenderable items are dropped, so a day whose
        // Do Now section holds a blank line still ships ten readable rows.
        let doNow = snapshot.sections.first { $0.name.hasPrefix("Do Now") }
        let doNowRows = (doNow?.items ?? [])
            .filter(TodaySemantics.isOpen)
            .compactMap(row(for:))
            .prefix(maxDoNowRows)

        let rows = leadRows + doNowRows
        let all = snapshot.allItems
        return WatchTodaySummary(
            date: snapshot.date,
            etag: (snapshot.etag?.isEmpty == false) ? snapshot.etag : etag,
            pushedAt: now,
            rows: rows,
            // "Open" here means ACTIONABLE — not done, not postponed — the same
            // predicate the section headers and the tab badge use. A footer counting
            // work the user already set aside would disagree with the rows above it.
            openCount: all.filter(TodaySemantics.isOpen).count,
            doneCount: all.filter(\.checked).count,
            // The complication's number, and deliberately the SAME function the
            // phone's tab badge calls. Two devices that disagreed about how much is
            // left today would each be answering a question nobody asked.
            doNowOpenCount: TodaySemantics.doNowOpenCount(snapshot))
    }

    /// One row, or nil for an item with no words to show.
    ///
    /// The bridge computes `lead` (the bold segment, else the first sentence) for
    /// almost every item, but not for all of them — a bare task line with no bold and
    /// no sentence break can come through empty. Falling back to the stripped first
    /// line is what stops the wrist rendering a checkbox next to nothing; an item
    /// with neither is dropped, because a row the user cannot read is a row they
    /// cannot decide about.
    private static func row(for item: TodayItem) -> WatchTodayRow? {
        let parts = TodaySemantics.leadAndDetail(item)
        let words = (parts.lead.isEmpty ? parts.detail : parts.lead)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        return WatchTodayRow(id: item.id, lead: words, checked: item.checked,
                             section: item.sectionName)
    }
}
