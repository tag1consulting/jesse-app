import Foundation
import JesseNetworking

// The badge-only view of the day: exactly the items the red tab badge counts, and
// nothing else.
//
// ## Why it exists
//
// The badge says there is work without saying what it is. On a full day the counted
// rows are scattered through eight sections of open work, postponed work, done work
// and briefing lines, and there is no way to see which of them are the ones keeping
// the number red. This narrows the document to that set so the number and the rows
// are the same answer.
//
// ## One membership rule, not two
//
// Membership comes from `TodaySemantics.badgeItems`, which is also what
// `doNowOpenCount` is the size of. Nothing here re-derives "open work in the first
// Do Now section plus the standing lead items". A filter that carried its own copy of
// that rule would be a second definition of the badge, and the two would drift apart
// the first time either one changed.
//
// ## Pinned rows
//
// A filter that deleted rows as they were tapped would be a list nobody could
// correct: tick the wrong item and it is gone before you can untick it. So the model
// hands over the ids it is holding on screen for this viewing, and they stay
// rendered, struck through as done or chipped as postponed exactly as the full day
// would draw them, until the next explicit refresh or the next entry into the view.
// The badge itself is not affected: a pinned row has already left the count.

extension TodaySemantics {

    /// The day narrowed to the badge set, plus any `pinned` ids still in the
    /// document.
    ///
    /// What survives: the lead block, and the first `Do Now…` section. Every other
    /// section is dropped because none of it can contribute a badge item, including a
    /// SECOND section whose name also begins `Do Now`: the badge counts the first one,
    /// so the view shows the first one. The retained section keeps its heading
    /// (which is what tells the user the rows below it are Do Now work rather than
    /// standing items) and loses its prose and glanceable rows, which are not items
    /// and are not counted.
    ///
    /// Order, grouping and row content are untouched. This is a filter and nothing
    /// else: rows arrive in whatever order the caller's lens already put them in, and
    /// leave in the same one.
    ///
    /// The counts are recomputed over the result so a section header describes the
    /// rows under it. The tab badge is NOT read from here. It is read from the whole
    /// day, which is the only document that can answer it.
    public nonisolated static func badgeFiltered(_ snapshot: TodaySnapshot,
                                                 keeping pinned: Set<String> = [])
    -> TodaySnapshot {
        let badge = Set(badgeItems(snapshot).map(\.id))
        let keep = { (item: TodayItem) in badge.contains(item.id) || pinned.contains(item.id) }

        var out = snapshot
        out.leadItems = snapshot.leadItems.filter(keep)
        out.sections = []
        if let doNow = snapshot.sections.first(where: { $0.name.hasPrefix("Do Now") }) {
            var section = doNow
            section.items = doNow.items.filter(keep)
            section.prose = []
            section.reports = []
            if !section.items.isEmpty { out.sections = [section] }
        }
        out.counts = counts(out)
        return out
    }
}

// MARK: - Per-device view state

/// The Today screen's per-device view preferences, in `UserDefaults`.
///
/// One tiny store rather than the same key spelled out in both shells. The shells own
/// the DECISION to persist (the model deliberately holds no storage, the same line it
/// holds for the view sort), but the key and its default are one fact, and two
/// hand-written copies of a string are one typo away from a Mac and a phone that
/// disagree about which preference they are reading.
///
/// `UserDefaults`, because that is where this app already keeps small per-device view
/// state and a boolean does not deserve a schema. The suite is injectable so a test
/// drives a scratch domain rather than the machine's own.
///
/// Not `Sendable`, and not made so with an `@unchecked`: `UserDefaults` is a class the
/// compiler cannot vouch for, and this store is read and written from the two shells'
/// MainActor views and nowhere else. Claiming more than that would be a claim nobody
/// needs.
public struct TodayViewPreferences {
    /// The stored key. Public so a shell can bind `@AppStorage` to the same fact if it
    /// ever wants to, rather than inventing a second spelling.
    public static let badgeFilterKey = "today.badgeFilter"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the day opens filtered to the badge set. Off by default: the full day
    /// is what the screen has always shown, and a launch into a filtered view would
    /// be the app deciding the user's morning for them.
    public var isBadgeFilterOn: Bool {
        get { defaults.bool(forKey: Self.badgeFilterKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.badgeFilterKey) }
    }
}
