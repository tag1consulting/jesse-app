import Foundation
import JesseNetworking

// How the strand board is ordered on screen, and the two or three strings a row says
// about time. Pure functions over a snapshot, testable without rendering anything —
// the division `TodaySort` and `TodaySemantics` already draw.
//
// ## Why this is a different sort from the day's
//
// `TodaySortKey` has three cases and the day's default is FILE ORDER, because the day
// file's order is the day's own argument and a client must not overrule it. A strand
// board has no such argument: the bridge sorts it by `updated` descending, then by the
// note's last modification time, and that is a derived fact, not an editorial one. So
// the two lenses share nothing but the idea of grouping by project, and folding them
// into one enum would put `File order` and `Oldest first` in a menu where neither
// means anything.
//
// Neither lens here writes. There is no reorder on this screen at all — a strand's
// order is its `updated` day and when its note was last touched, and the way to change
// that is to do some work.

/// How the strand rows are ordered.
public enum StrandsSortKey: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    /// The server's order: `updated` day descending, then last modified descending,
    /// then title. The default, and the only one that answers "what has moved".
    /// `updated` is only a day, so without the bridge's mtime key an active day ties
    /// across the board and reads as alphabetical.
    case mostRecent
    /// Grouped under the five Dashboard project headings, unfiled last.
    case group
    /// Every strand under its parent, as the vault files them: top level strands in
    /// server order, each followed by its children, one indent per level. Offered only
    /// when the bridge serves `parent`.
    case tree

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mostRecent: return "Most recent"
        case .group: return "By group"
        case .tree: return "Tree"
        }
    }

    public var symbol: String {
        switch self {
        case .mostRecent: return "clock"
        case .group: return "folder"
        case .tree: return "list.bullet.indent"
        }
    }

    /// Whether this lens groups the list under headings.
    public var isGrouped: Bool { self == .group }

    /// The lenses a board can be shown in. `Tree` needs the bridge's `parent`, and a
    /// bridge that predates it would put every strand at the top level, which is the
    /// flat list again under a name that promises more; so it is not offered at all.
    public static func available(servesParents: Bool) -> [StrandsSortKey] {
        allCases.filter { $0 != .tree || servesParents }
    }
}

/// One row of the `Tree` lens: a strand, how deep it sits, and how much is under it.
public struct StrandsTreeRow: Equatable, Identifiable, Sendable {
    public var strand: Strand
    /// 0 at the top level, one more per parent above it.
    public var depth: Int
    /// Every strand under this one, at any depth. What a collapsed row's caption counts.
    public var descendants: Int

    public var id: String { strand.slug }
    /// Whether the row has a subtree to collapse.
    public var hasChildren: Bool { descendants > 0 }

    public init(strand: Strand, depth: Int, descendants: Int) {
        self.strand = strand
        self.depth = depth
        self.descendants = descendants
    }
}

/// One rendered section of the board: a heading (nil for the ungrouped list) and its
/// rows, in order.
public struct StrandsGroup: Equatable, Identifiable, Sendable {
    /// The project this group is, or nil for the flat `Most recent` list and for the
    /// dormant group (which is keyed by `isDormant` instead).
    public var project: TodayProject?
    /// The collapsed group at the bottom, which every lens has.
    public var isDormant: Bool
    public var strands: [Strand]
    /// The `Tree` lens's rows, in the same order as `strands`, with their depth. Nil
    /// under every other lens and for the dormant group, which is never nested.
    public var treeRows: [StrandsTreeRow]?

    public var id: String {
        isDormant ? "dormant" : (project?.rawValue ?? "all")
    }

    public init(project: TodayProject? = nil, isDormant: Bool = false, strands: [Strand],
                treeRows: [StrandsTreeRow]? = nil) {
        self.project = project
        self.isDormant = isDormant
        self.strands = strands
        self.treeRows = treeRows
    }

    /// What the heading says, or nil where the list has none.
    public var title: String? {
        if isDormant { return "Dormant" }
        guard let project else { return nil }
        return TodayProjectPalette.role(for: project).label
    }
}

/// The pure half of the strand board.
public enum StrandsSemantics {

    /// **The list, as the screen should draw it**, under one lens.
    ///
    /// Two rules hold under EVERY lens, which is why they live here rather than in
    /// either branch:
    ///
    ///   * **Server order is the tiebreak, always.** The bridge sorts by `updated` day
    ///     descending, then last modified, then title, so decorating with the arrival index and comparing on
    ///     it last makes every lens a pure, stable function of the snapshot. Swift's
    ///     `sorted(by:)` is not stable, and a board where five strands share a group
    ///     would otherwise shuffle those five on every redraw.
    ///   * **Dormant strands sink into one collapsed group at the bottom.** A dormant
    ///     strand is work deliberately set down; leaving it interleaved with the live
    ///     rows would put the fourteen things that are moving behind the two that are
    ///     not. It still renders — a board that silently dropped rows is a board that
    ///     stops being believed — it is just out of the way.
    public nonisolated static func grouped(_ strands: [Strand],
                                           by key: StrandsSortKey) -> [StrandsGroup] {
        let live = strands.filter { !$0.state.isDormant }
        let dormant = strands.filter { $0.state.isDormant }

        var groups: [StrandsGroup] = []
        switch key {
        case .mostRecent:
            if !live.isEmpty { groups.append(StrandsGroup(strands: live)) }
        case .group:
            // Dashboard order, `unfiled` last — `TodayProject.allCases`' own order, so
            // the day screen's `by project` and this cannot disagree about where a
            // project sits.
            for project in TodayProject.allCases {
                let rows = live.filter { $0.group == project }
                if !rows.isEmpty { groups.append(StrandsGroup(project: project, strands: rows)) }
            }
        case .tree:
            let rows = tree(live)
            if !rows.isEmpty {
                groups.append(StrandsGroup(strands: rows.map(\.strand), treeRows: rows))
            }
        }
        if !dormant.isEmpty {
            groups.append(StrandsGroup(isDormant: true, strands: dormant))
        }
        return groups
    }

    /// **The `Tree` lens**: every strand once, each followed by its subtree, one level
    /// deeper per parent.
    ///
    /// Siblings, the top level included, keep server order, which is recency: a parent
    /// sits where its own `updated` puts it, never lifted by a busy child. A strand whose
    /// parent is not in `strands` (nil, unresolved by the bridge, or dormant and so
    /// sunk into its own group) is top level. A loop, which the bridge should never
    /// send, is broken where the walk would repeat: the first looping strand in server
    /// order is drawn at the top level and the rest of the loop nests under it, so
    /// every strand still appears exactly once.
    public nonisolated static func tree(_ strands: [Strand]) -> [StrandsTreeRow] {
        let slugs = Set(strands.map(\.slug))
        var children: [String: [Strand]] = [:]
        var roots: [Strand] = []
        for strand in strands {
            if let parent = strand.parent, parent != strand.slug, slugs.contains(parent) {
                children[parent, default: []].append(strand)
            } else {
                roots.append(strand)
            }
        }

        var rows: [StrandsTreeRow] = []
        var placed: Set<String> = []
        // Depth first, recursion free: the size of a subtree is only known once it has
        // been walked, so a row is appended at once and its count filled in afterwards.
        func walk(_ root: Strand) {
            var stack: [(strand: Strand, depth: Int, done: Bool)] = [(root, 0, false)]
            var open: [Int] = []
            while let (strand, depth, done) = stack.popLast() {
                if done {
                    let index = open.removeLast()
                    rows[index].descendants = rows.count - index - 1
                    continue
                }
                guard placed.insert(strand.slug).inserted else { continue }
                open.append(rows.count)
                rows.append(StrandsTreeRow(strand: strand, depth: depth, descendants: 0))
                stack.append((strand, depth, true))
                for child in (children[strand.slug] ?? []).reversed()
                where !placed.contains(child.slug) {
                    stack.append((child, depth + 1, false))
                }
            }
        }
        roots.forEach(walk)
        // Anything still unplaced sits on a loop, or under one.
        for strand in strands where !placed.contains(strand.slug) {
            walk(strand)
        }
        return rows
    }

    /// The `Tree` rows left on screen once the collapsed parents have folded away their
    /// subtrees. A collapsed row itself stays, and so does everything outside it.
    public nonisolated static func visibleTreeRows(_ rows: [StrandsTreeRow],
                                                   collapsed: Set<String>) -> [StrandsTreeRow] {
        var out: [StrandsTreeRow] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            out.append(row)
            let folded = row.hasChildren && collapsed.contains(row.strand.slug)
            index += folded ? row.descendants + 1 : 1
        }
        return out
    }

    /// A collapsed parent's caption: how many strands it holds, at every depth.
    public nonisolated static func insideCaption(_ descendants: Int) -> String {
        "\(descendants) inside"
    }

    /// The collapsed parents as stored on the device: slugs joined by newlines, which a
    /// file stem cannot contain. `@AppStorage` holds a string, not a set.
    public nonisolated static func decodeCollapsed(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    public nonisolated static func encodeCollapsed(_ slugs: Set<String>) -> String {
        slugs.sorted().joined(separator: "\n")
    }

    /// The `Next:` line of a row, or nil when the strand has no next step.
    ///
    /// The id leads because it is what a prompt is named by (`A1d`, `P3`) and what
    /// Jeremy says out loud; the gate follows the text because it qualifies the step
    /// rather than replacing it.
    public nonisolated static func nextLine(_ strand: Strand) -> String? {
        guard let next = strand.next else { return nil }
        let head = next.id.isEmpty ? next.text
                                   : (next.text.isEmpty ? next.id : "\(next.id) \(next.text)")
        guard !head.isEmpty else { return nil }
        guard let waits = next.waitsOn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !waits.isEmpty else { return head }
        // A MIDDLE DOT, not a dash. Every user facing string in this app spells a
        // separator this way.
        return "\(head) · waits on \(waits)"
    }

    /// How long ago the note was touched, in the width of a label: `today`,
    /// `3d`, `2w`.
    ///
    /// Pure, and taking `today` as an argument rather than reading a clock, because a
    /// stamp a test cannot pin is a stamp a test cannot assert. An `updated` value that
    /// is not a plain ISO day yields nil rather than a guess — the audit already has a
    /// finding for that, and inventing an age for it here would hide the thing the
    /// finding is trying to say.
    public nonisolated static func relativeUpdated(_ updated: String,
                                                   today: String) -> String? {
        guard let days = dayGap(from: updated, to: today) else { return nil }
        switch days {
        case ..<0: return nil            // stamped in the future: say nothing, not "-2d".
        case 0: return "today"
        case 1: return "1d"
        case 2..<14: return "\(days)d"
        default: return "\(days / 7)w"
        }
    }

    /// **What one row says**, as one sentence, in the order the row reads it: the
    /// project, the title, where it stands, what runs next, the gate, and how long it
    /// has been.
    ///
    /// Here rather than in the view because it is the row's CONTENT, and content a test
    /// cannot reach is content nobody checks. The view draws the same pieces in the same
    /// order; this is what a screen reader hears, and what the row test asserts.
    public nonisolated static func rowAccessibilityLabel(_ strand: Strand,
                                                         today: String) -> String {
        var parts = [TodayProjectPalette.role(for: strand.group).accessibilityLabel,
                     strand.title]
        if let now = strand.now, !now.isEmpty { parts.append(now) }
        if let next = nextLine(strand) { parts.append("Next: \(next)") }
        if strand.isWaitingOnYou { parts.append(StrandsWording.waitingOnYou) }
        if let age = relativeUpdated(strand.updated, today: today) {
            parts.append(age == "today" ? "updated today" : "updated \(age) ago")
        }
        return parts.joined(separator: ", ")
    }

    /// Whole days between two `YYYY-MM-DD` strings, or nil when either is not one.
    ///
    /// Arithmetic over the proleptic Gregorian day number rather than `DateComponents`,
    /// for the reason every date in this package is handled as a string: these values
    /// are the vault's own spelling, they carry no zone, and routing them through a
    /// `Calendar` would attach this device's zone to a fact that has none.
    nonisolated static func dayGap(from: String, to: String) -> Int? {
        guard let a = dayNumber(from), let b = dayNumber(to) else { return nil }
        return b - a
    }

    /// A `YYYY-MM-DD` as a day number, or nil when it is not one.
    nonisolated static func dayNumber(_ iso: String) -> Int? {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        // Howard Hinnant's days-from-civil: exact, branch free, and valid for every
        // year this vault will ever hold.
        let year = m <= 2 ? y - 1 : y
        let era = (year >= 0 ? year : year - 399) / 400
        let yoe = year - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}


/// The board's own wording, in one place.
///
/// Three surfaces now say "Waiting on you" (the row, the row's accessibility label, and
/// the test that asserts both), and a phrase written out three times is three phrases
/// the next edit can leave disagreeing. The same reason `TodayBadgeFilterWording` exists.
public enum StrandsWording {
    /// The caption on a strand whose gate is one the reader can clear personally.
    public static let waitingOnYou = "Waiting on you"
}
