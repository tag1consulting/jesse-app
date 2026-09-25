import SwiftUI
import JesseNetworking
import JesseVault

// THE STRAND BOARD: about fifteen long running pieces of work, newest first, each with
// where it stands and what runs next.
//
// It shares the Today tab rather than taking a fifth tab of its own, and the two
// segments answer genuinely different questions. The day answers "what am I doing
// today"; a strand answers "where does this work stand and what runs next". Those are
// the vault's own two objects, and a fifth tab would have made a board that is read
// once or twice a day as prominent as the one that is read twenty times.
//
// ## One snapshot, no per-row call
//
// Every row here is drawn from the single `GET /jesse/strands` the model holds. A row
// makes no request of its own — not for its counts, not for its findings, not for its
// next step — so the board costs one conditional round trip whether it holds two
// strands or forty.
//
// ## What a tap opens, and why it is the vault reader
//
// A tap hands the strand to the shell's `StrandOpener`, the one definition of opening a
// strand, which the Today rows and the item detail use too; the shell attaches the one
// sheet it presents (`strandNoteSheet`). A strand note is a NOTE: its `## Queue` is a list of checkboxes, and ticking one is
// how the next step becomes the last step. The device already has a reader that ticks a
// box through a stamped, guarded write (`VaultNoteReaderView`), so a tap opens that and
// nothing new is built. The bridge's markdown is the fallback for a device with no
// vault folder, and it is READ ONLY on purpose: a copy fetched over the network has no
// stamp to guard a write with, and a second write path to the same lines is how two
// spellings of "tick a box" end up disagreeing.

/// The Strands segment.
public struct StrandsListView: View {
    @Bindable private var model: StrandsModel

    /// The shell's opener: the same one a Today row's strand chip and the item detail
    /// use, so the board and the chip can never open a strand two different ways.
    @Bindable private var opener: StrandOpener

    /// How many open Today items name a strand, by slug. The count behind a row's
    /// `N on Today` caption, filtered from the day the app already holds.
    private let onTodayCount: (String) -> Int

    /// The strand whose findings sheet is up.
    @State private var findingsFor: Strand?
    /// Which project groups are collapsed. Only `Dormant` starts that way.
    @State private var collapsed: Set<String> = ["dormant"]
    /// Which `Tree` parents are collapsed, by slug, remembered on this device. Every
    /// parent starts expanded, so a new strand's subtree is never hidden by default.
    @AppStorage(StrandsListView.collapsedTreeKey) private var collapsedTreeStored = ""

    /// The stored key for the collapsed `Tree` parents.
    public static let collapsedTreeKey = "strands.tree.collapsed"

    /// The shell's two strand actions, read here and handed to every row's menu. Nil in a
    /// preview, in which case those entries are listed and inert; the shells inject both.
    @Environment(\.strandDiscuss) private var discussAction
    @Environment(\.strandRecord) private var recordAction

    public init(model: StrandsModel,
                opener: StrandOpener,
                onTodayCount: @escaping (String) -> Int = { _ in 0 }) {
        self.model = model
        self.opener = opener
        self.onTodayCount = onTodayCount
    }

    public var body: some View {
        Group {
            switch model.displayState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                TodayEmptyState(symbol: "point.3.connected.trianglepath.dotted",
                                title: Self.emptyTitle,
                                message: Self.emptyMessage)
            case .unavailable(let message):
                TodayEmptyState(symbol: "wifi.exclamationmark",
                                title: "Can't reach the bridge",
                                message: message)
            case .offline:
                TodayEmptyState(
                    symbol: "wifi.slash",
                    title: "You're offline",
                    message: "This device hasn't loaded the strands yet, so there's nothing to show. They'll be here the next time the bridge is reachable.")
            case .content(let groups):
                list(groups)
            }
        }
        .task {
            // The last board this device was given, drawn BEFORE the fetch. On a
            // reachable launch the conditional GET it primes the ETag for answers
            // `304` and nothing redraws; on an unreachable one it is the whole feature.
            model.primeFromCache()
            await model.load()
        }
        .refreshable { await model.refresh() }
        .sheet(item: $findingsFor) { strand in
            StrandFindingsSheet(strand: strand) { findingsFor = nil }
        }
    }

    /// The empty board, in two sentences that say it is a real answer rather than a
    /// failure: the bridge replied, and it had nothing to list.
    static let emptyTitle = "No strands yet."
    static let emptyMessage =
        "A strand is one long running piece of work, with a status note under Strands in the vault. None are active right now."

    // MARK: - The list

    @ViewBuilder
    private func list(_ groups: [StrandsGroup]) -> some View {
        List {
            if let notice = opener.notice {
                TodayNoticeRow(message: notice) { opener.notice = nil }
                    .listRowSeparator(.hidden)
            }
            if model.isReadOnly {
                TodayStatusBanner(isOffline: true,
                                  isPendingReplay: false,
                                  message: model.lastErrorMessage,
                                  staleness: model.stalenessLine)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups) { group in
                section(group)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func section(_ group: StrandsGroup) -> some View {
        if let title = group.title {
            Section {
                if !collapsed.contains(group.id) {
                    ForEach(group.strands) { row($0) }
                }
            } header: {
                StrandsGroupHeader(title: title,
                                   count: group.strands.count,
                                   isCollapsible: group.isDormant,
                                   isCollapsed: collapsed.contains(group.id)) {
                    withAnimation(.snappy) { toggleCollapsed(group.id) }
                }
            }
        } else if let treeRows = group.treeRows {
            let folded = StrandsSemantics.decodeCollapsed(collapsedTreeStored)
            Section {
                ForEach(StrandsSemantics.visibleTreeRows(treeRows, collapsed: folded)) {
                    treeRow($0, isCollapsed: folded.contains($0.strand.slug))
                }
            }
        } else {
            Section {
                ForEach(group.strands) { row($0) }
            }
        }
    }

    /// A `Tree` row: indented by depth, with a disclosure control of its own OUTSIDE the
    /// row's combined accessibility element, so the chevron stays a separate control and
    /// the row's tap still opens the note.
    private func treeRow(_ tree: StrandsTreeRow, isCollapsed: Bool) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Group {
                if tree.hasChildren {
                    Button {
                        withAnimation(.snappy) { toggleTree(tree.strand.slug) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                            .frame(width: 20, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(tree.strand.title)
                    .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
                } else {
                    Color.clear.frame(width: 20, height: 24)
                }
            }
            .padding(.leading, CGFloat(tree.depth) * Self.treeIndent)
            row(tree.strand,
                insideCaption: tree.hasChildren && isCollapsed
                    ? StrandsSemantics.insideCaption(tree.descendants) : nil)
        }
    }

    /// One level of the tree, in points.
    static let treeIndent: CGFloat = 16

    private func toggleTree(_ slug: String) {
        var folded = StrandsSemantics.decodeCollapsed(collapsedTreeStored)
        if folded.contains(slug) { folded.remove(slug) } else { folded.insert(slug) }
        collapsedTreeStored = StrandsSemantics.encodeCollapsed(folded)
    }

    private func row(_ strand: Strand, insideCaption: String? = nil) -> some View {
        StrandRow(strand: strand,
                  referenceDay: model.referenceDay,
                  onTodayCaption: StrandOnToday.caption(count: onTodayCount(strand.slug)),
                  insideCaption: insideCaption,
                  isOpening: opener.opening == strand.slug,
                  onOpen: { opener.open(slug: strand.slug, title: strand.title) },
                  onShowFindings: { findingsFor = strand })
            // A long press (a secondary click on the Mac) on ANY board row — live, dormant
            // or nested — offers the same five things the Vault tab's Strands rows offer.
            // Attached here rather than inside `StrandRow` so every group gets it from the
            // one place every group is built, and so the row keeps its tap unchanged.
            .strandContextMenu(Self.menu(for: strand, opener: opener,
                                         discuss: discussAction, record: recordAction))
    }

    /// **The menu one board row carries.** Static and handed everything it needs, so the
    /// test that compares this surface's menu with the Vault tab's can build the same value
    /// the row renders without a screen.
    ///
    /// `Open note` is the opener the row's own tap uses, not a second way in. `Search` and
    /// `Decisions` go through the shell, because the record lives in another tab.
    static func menu(for strand: Strand, opener: StrandOpener,
                     discuss: StrandDiscussAction?,
                     record: StrandRecordAction?) -> StrandMenu {
        // `notePath` is the wire model's own spelling of `Strands/<slug>.md`, so the
        // convention lives in one place rather than being re-derived here.
        let target = StrandMenuTarget(slug: strand.slug, title: strand.title,
                                      path: strand.notePath)
        return StrandMenu(
            target: target,
            onOpenNote: { opener.open(slug: strand.slug, title: strand.title) },
            onDiscuss: discuss.map { action in { action.start(target) } },
            onShowRecord: { section in record?.show(strand.slug, section: section) })
    }

    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

// MARK: - Where the open note came from

/// The two places a strand note can be read from.
///
/// A sum type rather than a path plus a flag: the two cases carry different payloads
/// (one a path this device can write to, one a copy of the bytes it cannot) and the
/// difference is exactly what decides whether the reader offers a checkbox.
public enum StrandNoteSource: Equatable, Identifiable, Sendable {
    /// The note in the Obsidian copy on this device, by vault relative path. The slug
    /// rides along because the sheet's `On Today` block filters by it.
    case local(path: String, slug: String, title: String)
    /// The bridge's copy, read only.
    case remote(slug: String, title: String, markdown: String)

    public var id: String {
        switch self {
        case .local(let path, _, _): return "local:\(path)"
        case .remote(let slug, _, _): return "remote:\(slug)"
        }
    }
}

// MARK: - The row

/// One strand: its group, its title, where it stands, and what runs next.
struct StrandRow: View {
    let strand: Strand
    /// The day every `updated` stamp is measured against.
    let referenceDay: String
    /// `N on Today`, or nil when no open Today item names this strand.
    var onTodayCaption: String? = nil
    /// `N inside`, on a collapsed `Tree` parent only.
    var insideCaption: String? = nil
    let isOpening: Bool
    let onOpen: () -> Void
    let onShowFindings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The SAME accent the day rows carry, from the same palette, because it
            // stands for the same five topics. A second colour table for the same
            // taxonomy is the fork that disagrees with itself in the dark.
            TodayProjectAccentBar(project: strand.group)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    header
                    if let now = strand.now, !now.isEmpty {
                        Text(now)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let next = StrandsSemantics.nextLine(strand) {
                        Label(next, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let onTodayCaption {
                        Label(onTodayCaption, systemImage: "checklist")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let insideCaption {
                        Label(insideCaption, systemImage: "list.bullet.indent")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if strand.isWaitingOnYou {
                        // The one gate the reader can clear personally, said out loud.
                        Label(StrandsWording.waitingOnYou,
                              systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the strand's note")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(strand.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isOpening {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 4)
            if !strand.findings.isEmpty {
                // A BUTTON of its own, not part of the row's tap: the findings are about
                // the note's bookkeeping and the row's tap is about the work, and one
                // gesture that did both would open whichever the user did not mean.
                Button(action: onShowFindings) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strand.findings.count == 1
                                    ? "1 audit finding"
                                    : "\(strand.findings.count) audit findings")
            }
            if let age = StrandsSemantics.relativeUpdated(strand.updated,
                                                          today: referenceDay) {
                Text(age)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// One sentence for a screen reader — the row's content, computed where a test can
    /// reach it.
    private var accessibilityLabel: String {
        let sentence = StrandsSemantics.rowAccessibilityLabel(strand, today: referenceDay)
        guard let insideCaption else { return sentence }
        return "\(sentence), \(insideCaption)"
    }
}

// MARK: - A group heading

/// A project heading, or the collapsible `Dormant` one.
struct StrandsGroupHeader: View {
    let title: String
    let count: Int
    let isCollapsible: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            if isCollapsible {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        Text(title)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
            } else {
                Text(title)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - The findings sheet

/// What the nightly audit said about one note, one line each.
///
/// A sheet rather than rows in the list: a finding is about the note's bookkeeping
/// rather than about the work, and fifteen strands with two findings each would bury
/// the board in its own maintenance.
struct StrandFindingsSheet: View {
    let strand: Strand
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(strand.findings) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.message)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text(finding.code)
                                    .font(.caption2)
                                    .monospaced()
                                if let line = finding.line {
                                    Text("line \(line)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(strand.findings.count == 1 ? "1 finding" : "\(strand.findings.count) findings")
                } footer: {
                    Text("Found by the nightly audit of the Strands notes. Each one names something in the note that is no longer true.")
                }
            }
            .navigationTitle(strand.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

// MARK: - The off-device reader

/// The bridge's copy of a note, read only.
///
/// Rendered through `TodayNoteView`, which is the same block model and the same link
/// chips the item detail sheet uses, so a note read over the network and a note read
/// off disk are not two different looking screens. It offers no checkbox: these bytes
/// came with no stamp, and a guarded write needs one.
struct StrandRemoteNoteView: View {
    let title: String
    let markdown: String
    /// The `On Today` block, above the provenance line.
    var onToday: AnyView? = nil
    let onOpenLink: (TodayLinkOrigin) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let onToday {
                        onToday
                    }
                    Label(Self.provenance, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TodayNoteView(markdown: markdown, onOpenLink: onOpenLink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    static let provenance =
        "Read from the bridge, because this device has no copy of the vault holding this note. Point Jesse at the Obsidian folder in Settings to tick its boxes here."
}

// MARK: - The sort control

/// The board's lens, as a menu. Up to three entries, and none writes anything.
public struct StrandsSortMenu: View {
    @Binding private var selection: StrandsSortKey
    /// The lenses this board offers. `Tree` is absent from an older bridge's board.
    private let available: [StrandsSortKey]

    public init(selection: Binding<StrandsSortKey>,
                available: [StrandsSortKey] = StrandsSortKey.allCases) {
        self._selection = selection
        self.available = available
    }

    public var body: some View {
        Menu {
            Picker("Order", selection: $selection) {
                ForEach(available) { key in
                    Label(key.label, systemImage: key.symbol).tag(key)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: selection != .mostRecent
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Order the strands: \(selection.label)")
    }
}
