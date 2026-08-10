import Foundation
import JesseNetworking

// Dragging a row, resolved to writes.
//
// ## Why a drop is a PLAN and not a mutation
//
// A finger lands somewhere; the day file has four typed ops. Those two facts are not
// the same shape, and the translation between them is the whole of this file: it is
// pure, it is total (every landing has an answer, including "nothing"), and it is
// tested without a server, a view or a gesture recognizer — none of which CI can
// drive.
//
// The four ops are the only vocabulary. There is deliberately no "insert at index"
// on the wire: `Today.md` is a markdown document the agent also writes, and an
// index-addressed splice would be a write against a position nobody can see. So an
// arbitrary drag is spelled as a SEQUENCE of the ops that exist — one
// `top_of_section`, or n × `up`, or `to_do_now` then n × `down` — each of which is a
// separate ETagged write the bridge understands. That is why a plan is a LIST.
//
// ## Guards refuse; they never approximate
//
// Three landings have no honest spelling: the standing lead item cannot move (the
// bridge answers `409` for every op on it), nothing can be dropped above it, and no
// op moves an item into an arbitrary section — `to_do_now` is the only one that
// crosses a boundary at all. Each of those is `.refused` with the sentence the screen
// shows, and **nothing is written**: the row snaps back. The alternative — landing the
// row somewhere near where it was dropped — would be the screen inventing an intent
// the user did not express, in a file they cannot see.

// MARK: - Where a row was dropped

/// A drag's landing: which section, and which index within that section's items.
///
/// The index is in the DESTINATION's own file order and means "the row should end up
/// here". Callers that come from SwiftUI's `.onMove` must convert first — `onMove`
/// hands over an insertion index in the pre-removal array, which is one higher than
/// the settled index for a downward move. `TodaySemantics.settledIndex(from:to:)` is
/// that conversion, in one place, because getting it wrong is an off-by-one that only
/// shows up when dragging DOWNWARD and is invisible in every upward test.
public struct TodayDropTarget: Equatable, Hashable, Sendable {
    /// The section dropped into. The empty string is the lead block above every
    /// heading, which is never a legal destination.
    public var sectionName: String
    /// The index within that section's items the row should end up at.
    public var index: Int

    public init(sectionName: String, index: Int) {
        self.sectionName = sectionName
        self.index = index
    }
}

/// What a drop should write.
public enum TodayReorderPlan: Equatable, Sendable {
    /// The row landed where it already was. Not an error and not a refusal — there is
    /// simply nothing to say to the bridge.
    case unchanged
    /// The durable ops, in the order they must be applied. Never empty.
    case ops([TodayMoveOp])
    /// The day file's structure forbids this landing. The row snaps back, NOTHING is
    /// written, and the message is what the screen says.
    case refused(String)

    /// The ops this plan would write — empty for both non-writing cases, which is what
    /// lets a test assert "this drag wrote nothing" in one line.
    public var ops: [TodayMoveOp] {
        if case .ops(let ops) = self { return ops }
        return []
    }

    /// Whether this plan reaches the bridge at all.
    public var writes: Bool { !ops.isEmpty }
}

/// The sentences a refused drag shows. Public and named so the screen, the tests and
/// any future platform say the same thing about the same guard — a second wording for
/// "you can't drop there" is a second explanation of the same rule.
public enum TodayReorderGuard {
    /// The standing top-priority item, which the bridge refuses to move at all.
    public static let leadIsImmovable =
        "The day's standing item stays where it is — it sits above every section by design."
    /// A drop above the lead block.
    public static let aboveTheLead =
        "Nothing can move above the day's standing item."
    /// A drop into a section no op can reach.
    public static let onlyDoNowAcceptsDrops =
        "Items can only be dragged within their own section, or into Do Now."
    /// The dragged row is not in the document any more — a refresh landed mid-drag.
    public static let vanishedMidDrag =
        "That row moved while you were dragging it. Nothing was changed."
    /// A drop into a section that is on a view sort. The index the finger picked is an
    /// index in the LENS, and the file has no such position — writing it would move the
    /// row somewhere the user did not point at.
    public static let notWhileSorted =
        "This section is sorted on screen, so a drop here has no position in the file. Switch it back to file order to reorder it."
}

// MARK: - The translation

extension TodaySemantics {

    /// The index a row ENDS UP at, from SwiftUI's `.onMove` pair.
    ///
    /// `onMove` gives the insertion point in the array BEFORE the row is taken out, so
    /// a downward move names an index one past where the row will settle. Upward moves
    /// are already settled indices. One function, because this is the kind of
    /// arithmetic that is re-derived slightly differently at each call site.
    public nonisolated static func settledIndex(from source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }

    /// What dropping `item` at `target` should write, judged against the FILE order.
    ///
    /// `snapshot` must be the model's file-order document, never a sorted lens: every
    /// judgement here is about positions in the day file, and a lens moves rows without
    /// moving anything the bridge can address.
    public nonisolated static func reorderPlan(for item: TodayItem,
                                               to target: TodayDropTarget,
                                               in snapshot: TodaySnapshot) -> TodayReorderPlan {
        // The lead block, both ways round: its item cannot leave, and nothing can join
        // it. Both are structural — the bridge has no op that addresses it.
        if item.isLeadItem { return .refused(TodayReorderGuard.leadIsImmovable) }
        if target.sectionName.isEmpty { return .refused(TodayReorderGuard.aboveTheLead) }

        guard let from = snapshot.sections.first(where: { $0.name == item.sectionName }),
              let index = from.items.firstIndex(where: { $0.id == item.id }),
              let to = snapshot.sections.first(where: { $0.name == target.sectionName })
        else { return .refused(TodayReorderGuard.vanishedMidDrag) }

        guard to.name != from.name else {
            return withinSection(from: index, to: target.index, count: from.items.count)
        }
        return intoDoNow(target, in: snapshot)
    }

    /// A drag that stays inside one section, as `top_of_section` or as repeated
    /// `up`/`down`.
    ///
    /// `top_of_section` rather than n × `up` when the landing is 0: it is one write
    /// instead of n, and — more to the point — it is the op that MEANS what the user
    /// did. A row dragged to the top of its section should read as "top of section" in
    /// whatever ledger records the day, not as a run of swaps.
    private nonisolated static func withinSection(from index: Int, to landing: Int,
                                                  count: Int) -> TodayReorderPlan {
        let settled = max(0, min(landing, count - 1))
        if settled == index { return .unchanged }
        if settled == 0 { return .ops([.topOfSection]) }
        if settled < index { return .ops(Array(repeating: .up, count: index - settled)) }
        return .ops(Array(repeating: .down, count: settled - index))
    }

    /// A drag that crosses a section boundary.
    ///
    /// `to_do_now` is the ONLY op that crosses one, and it lands the row at the top of
    /// the FIRST section named `Do Now…` — matched here exactly as the bridge matches
    /// it, so a day file with a heading like "Do Now (today)" behaves the same on both
    /// sides. A drop into any other section is refused rather than approximated: there
    /// is no op that would put the row there, and moving it somewhere else instead is
    /// not a smaller version of the same act.
    private nonisolated static func intoDoNow(_ target: TodayDropTarget,
                                              in snapshot: TodaySnapshot) -> TodayReorderPlan {
        guard let doNow = snapshot.sections.first(where: { $0.name.hasPrefix("Do Now") }),
              doNow.name == target.sectionName
        else { return .refused(TodayReorderGuard.onlyDoNowAcceptsDrops) }
        // The op lands at the top; the `down`s walk it to where the finger actually
        // was. Clamped to the section's own length so a drop past the last row settles
        // at the end rather than sending writes at nothing.
        let landing = max(0, min(target.index, doNow.items.count))
        return .ops([.toDoNow] + Array(repeating: .down, count: landing))
    }

    // MARK: - Processing the day's completions

    /// The checked items a "process updates" turn would close at source.
    ///
    /// Every ticked item EXCEPT those already parked in a `Done…` section: that section
    /// is where processed work goes, so re-proposing it would ask the agent to close
    /// the same thing twice — and on a day file that has been running a while, it is
    /// most of the ticked lines. Lead items count: the standing item cannot be MOVED,
    /// but it can certainly be finished.
    public nonisolated static func itemsToProcess(_ snapshot: TodaySnapshot) -> [TodayItem] {
        snapshot.leadItems.filter(\.checked)
            + snapshot.sections
                .filter { !$0.name.lowercased().hasPrefix("done") }
                .flatMap { $0.items.filter(\.checked) }
    }
}
