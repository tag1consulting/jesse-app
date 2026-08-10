import Foundation
import JesseNetworking

// The view-level sort, and the focus affordance that is deliberately NOT one.
//
// ## Two different things that look alike
//
// **Sorting is a lens.** It reorders rows on screen and writes nothing. `Today.md` is
// written by the morning routine and hand-edited through the day, and its order is the
// day's own argument — what comes first is what was decided to come first. Nothing here
// may quietly overrule that, so every sort is non-destructive by construction: these
// are pure functions from a snapshot to a snapshot, no client, no ETag, no mutation.
// Close the sort and the day is exactly as the file has it.
//
// **Focus is an edit.** "Put this at the top" is a claim about the DAY, not about this
// screen, and it belongs in the file where the agent and every other device can see it.
// So focus maps onto the two absolute move ops the bridge already has —
// `top_of_section` and `to_do_now` — and goes through the same optimistic, ETagged
// mutation path as every other move.
//
// Keeping them apart in the type system is the point: a lens that silently rewrote the
// file, or a reorder that only this device could see, would each be a different kind of
// lie about what the day says.
//
// A sort never crosses a section boundary. Sections ARE the document's structure (and
// a section name is part of every contained item's identity), so a "global" sort would
// dissolve the day into a list of tasks with no argument left in it.

// MARK: - The lens

/// How the rows of each section are ordered on screen.
public enum TodaySortKey: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    /// The day file's own order. The default, and the only one that shows the day as
    /// its author wrote it.
    case fileOrder
    /// Grouped by project, in Dashboard order, `unfiled` last.
    case project
    /// Oldest `(Added …)` first — what has been sitting there longest.
    case age

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fileOrder: return "File order"
        case .project: return "By project"
        case .age: return "Oldest first"
        }
    }

    public var symbol: String {
        switch self {
        case .fileOrder: return "list.bullet"
        case .project: return "folder"
        case .age: return "clock.arrow.circlepath"
        }
    }

    /// One line saying what the lens does, and — for the two that reorder — saying out
    /// loud that it does not touch the file.
    public var caption: String {
        switch self {
        case .fileOrder: return "The day as the file has it."
        case .project: return "Grouped by project, on screen only — the file is unchanged."
        case .age: return "Longest-waiting first, on screen only — the file is unchanged."
        }
    }

    /// Whether this lens reorders anything. Views use it to say "sorted" out loud, and
    /// to keep the relative moves out of a menu that would be lying about direction.
    public var reorders: Bool { self != .fileOrder }
}

// MARK: - The focus affordance

/// The two "make this the next thing" actions, each of which is a real, durable move.
///
/// Distinct from `TodayMoveOp` on purpose even though it maps straight onto two of its
/// cases: a move is a direction ("up", "down"), a focus is an INTENT ("work on this
/// next"), and the second is what a user actually wants from a row. The mapping is one
/// function, below, so the two can never drift.
public enum TodayFocus: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    /// Top of the first `Do Now…` section — the day's front page. The only focus that
    /// can cross a section boundary, and therefore the only one that can change the
    /// item's id.
    case doNow
    /// Top of the item's own section, leaving it where it belongs.
    case topOfSection

    public var id: String { rawValue }

    /// **The mapping.** Focus is spelled in terms of the bridge's existing ops; no new
    /// wire verb, no new write path.
    public var moveOp: TodayMoveOp {
        switch self {
        case .doNow: return .toDoNow
        case .topOfSection: return .topOfSection
        }
    }

    public var label: String {
        switch self {
        case .doNow: return "Focus — move to Do Now"
        case .topOfSection: return "Focus — top of this section"
        }
    }

    /// The same action in the width of a swipe slot. A menu row can afford the clause
    /// that says which of the two positions it means; a swipe button is about four
    /// characters wide, and a truncated "Focus — move to Do N…" says less than "Do Now"
    /// does.
    public var swipeLabel: String {
        switch self {
        case .doNow: return "Do Now"
        case .topOfSection: return "Top"
        }
    }

    public var symbol: String {
        switch self {
        case .doNow: return "bolt.fill"
        case .topOfSection: return "arrow.up.to.line"
        }
    }
}

// MARK: - The functions

extension TodaySemantics {

    /// Order one section's items for display. Stable, and the identity function for
    /// `.fileOrder`.
    ///
    /// Stability is not a nicety here. `Array.sorted(by:)` is not a stable sort in
    /// Swift, and an unstable sort over a key with many ties — `by project` on a day
    /// where 45 of 94 items are `unfiled` — would shuffle the rows of the tied group
    /// every time the snapshot was re-rendered, which reads as the screen twitching for
    /// no reason. Decorating with the file index and comparing on it last makes the
    /// order a pure function of the snapshot.
    public nonisolated static func sorted(_ items: [TodayItem],
                                          by key: TodaySortKey) -> [TodayItem] {
        guard key.reorders else { return items }
        return items.enumerated()
            .sorted { a, b in
                let (l, r) = (rank(a.element, key), rank(b.element, key))
                if l != r { return l < r }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// One section's items as the screen should draw them: the lens applied, then
    /// every postponed row sunk to the bottom.
    ///
    /// **Postponed rows sink under EVERY lens, `.fileOrder` included**, which is why
    /// this is not simply a fourth sort key. Setting something aside for today is a
    /// statement about what is left to do, and a row that stays interleaved with the
    /// live work keeps costing attention it was explicitly told to stop costing. It
    /// still renders — hiding it would be a day silently dropping rows — it just
    /// stops being in the way.
    ///
    /// The sink is stable for the same reason the lens is: `partition`-style
    /// reordering with the file index as the tiebreak, so two postponed rows keep
    /// their relative order instead of swapping on every redraw.
    public nonisolated static func orderedForDisplay(_ items: [TodayItem],
                                                     by key: TodaySortKey) -> [TodayItem] {
        let sorted = sorted(items, by: key)
        guard sorted.contains(where: isPostponed) else { return sorted }
        return sorted.filter { !isPostponed($0) } + sorted.filter(isPostponed)
    }

    /// The whole day, ordered for display: each section's items sorted, everything else
    /// untouched.
    ///
    /// Sections stay in file order, prose and report rows stay where they are, and the
    /// lead block is never sorted — it holds the standing top-priority item, which is
    /// above the sections by definition and which the bridge refuses to move at all.
    /// Counts are unaffected: a lens changes order, never membership.
    public nonisolated static func sortedForDisplay(_ snapshot: TodaySnapshot,
                                                    by key: TodaySortKey) -> TodaySnapshot {
        var out = snapshot
        out.sections = out.sections.map { section in
            var s = section
            s.items = orderedForDisplay(s.items, by: key)
            return s
        }
        return out
    }

    /// The whole day, ordered for display, with **each section free to be on its own
    /// lens**: `keys[sectionName]` when it has one, `default` otherwise.
    ///
    /// The per-section overload rather than a second sorting routine: everything that
    /// makes the single-key version correct (stability, sections never crossing, the
    /// lead block never sorted, counts untouched) has to hold here too, and the way to
    /// guarantee that is to route both through the same per-section call.
    public nonisolated static func sortedForDisplay(_ snapshot: TodaySnapshot,
                                                    by keys: [String: TodaySortKey],
                                                    default key: TodaySortKey) -> TodaySnapshot {
        var out = snapshot
        out.sections = out.sections.map { section in
            var s = section
            s.items = orderedForDisplay(s.items, by: keys[section.name] ?? key)
            return s
        }
        return out
    }

    /// The sort key of one item: a comparable Int for `.project`, a comparable String
    /// for `.age`. Ties fall through to file order at the call site.
    private nonisolated static func rank(_ item: TodayItem, _ key: TodaySortKey) -> String {
        switch key {
        case .fileOrder:
            return ""
        case .project:
            // Dashboard order, zero-padded so it compares as a number rather than as
            // "10" < "2".
            return String(format: "%02d", item.project.displayOrder)
        case .age:
            // ISO dates compare lexicographically, so the string IS the ordering.
            // An item with no `(Added …)` trailer sorts LAST rather than first: its age
            // is unknown, and "unknown" is not "ancient" — putting undated items at the
            // top of an oldest-first list would promote exactly the items nobody has
            // dated, which on this vault is a large group.
            return item.addedDate ?? "9999-99-99"
        }
    }

    /// The moves worth offering while `sort` is in effect.
    ///
    /// `up` and `down` name a position the user can no longer see once a lens is on:
    /// they swap the item with its FILE neighbour, and under `by project` that neighbour
    /// may be three rows away or on the other side of the section. Rather than move a
    /// row somewhere surprising, they are withheld while a lens is active; the two
    /// absolute ops (`top_of_section`, `to_do_now`) mean the same thing under every
    /// lens and stay.
    public nonisolated static func availableMoves(for item: TodayItem,
                                                  in snapshot: TodaySnapshot,
                                                  sortedBy sort: TodaySortKey) -> [TodayMoveOp] {
        let all = availableMoves(for: item, in: snapshot)
        guard sort.reorders else { return all }
        return all.filter { $0 != .up && $0 != .down }
    }

    /// The focus actions that would actually do something for this item — the same
    /// availability rules as the underlying moves, so a button is never offered that the
    /// bridge would answer `409` (or a no-op) for.
    ///
    /// Deliberately computed from `availableMoves(for:in:)` — the FILE-order answer — and
    /// not from the lens-filtered list: both focus ops are absolute, so a lens has no
    /// bearing on whether they apply.
    public nonisolated static func availableFocus(for item: TodayItem,
                                                  in snapshot: TodaySnapshot) -> [TodayFocus] {
        let moves = Set(availableMoves(for: item, in: snapshot))
        return TodayFocus.allCases.filter { moves.contains($0.moveOp) }
    }
}
