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
// A strand note is a NOTE: its `## Queue` is a list of checkboxes, and ticking one is
// how the next step becomes the last step. The device already has a reader that ticks a
// box through a stamped, guarded write (`VaultNoteReaderView`), so a tap opens that and
// nothing new is built. The bridge's markdown is the fallback for a device with no
// vault folder, and it is READ ONLY on purpose: a copy fetched over the network has no
// stamp to guard a write with, and a second write path to the same lines is how two
// spellings of "tick a box" end up disagreeing.

/// The Strands segment.
public struct StrandsListView: View {
    @Bindable private var model: StrandsModel

    /// The local copy of the vault, when this device holds one. `nil` in a shell with no
    /// folder story and in every preview, where a tap falls straight through to the
    /// bridge's markdown rather than being offered and inert.
    private let localNotes: (any TodayLocalNoteProviding)?

    /// What a link inside the fetched markdown does. Handed through from the shell so a
    /// chip in the fallback reader behaves as every other link chip in the app does.
    private let onOpenLink: (TodayLinkOrigin) -> Void

    /// The note currently open, if any.
    @State private var openedNote: StrandNoteSource?
    /// The strand whose slug is being resolved right now, so the row can say it is
    /// working and a second tap cannot start a second resolve.
    @State private var opening: String?
    /// The strand whose findings sheet is up.
    @State private var findingsFor: Strand?
    /// The one line answer to a tap that could not open anything.
    @State private var notice: String?
    /// Which project groups are collapsed. Only `Dormant` starts that way.
    @State private var collapsed: Set<String> = ["dormant"]

    public init(model: StrandsModel,
                localNotes: (any TodayLocalNoteProviding)? = nil,
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in }) {
        self.model = model
        self.localNotes = localNotes
        self.onOpenLink = onOpenLink
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
        .sheet(item: $openedNote) { source in
            noteSheet(source)
        }
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
            if let notice {
                TodayNoticeRow(message: notice) { self.notice = nil }
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
        } else {
            Section {
                ForEach(group.strands) { row($0) }
            }
        }
    }

    private func row(_ strand: Strand) -> some View {
        StrandRow(strand: strand,
                  referenceDay: model.referenceDay,
                  isOpening: opening == strand.slug,
                  onOpen: { open(strand) },
                  onShowFindings: { findingsFor = strand })
    }

    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    // MARK: - Opening a note

    /// **What tapping a strand means**, in one place: the note on THIS device when it is
    /// here, the bridge's copy when it is not, and an honest line when neither answered.
    private func open(_ strand: Strand) {
        guard opening == nil else { return }
        opening = strand.slug
        notice = nil
        Task {
            defer { opening = nil }
            // `Strands/<slug>` is an exact relative path, so the resolver's first step
            // settles it; the basename steps below it are what cover a vault whose
            // folder is one level in from the workspace root.
            let target = "\(Strand.directory)/\(strand.slug)"
            if let local = await localNotes?.localNote(forTargets: [target]) {
                openedNote = .local(path: local.path, title: strand.title)
                return
            }
            if let markdown = await model.markdown(forSlug: strand.slug) {
                openedNote = .remote(slug: strand.slug, title: strand.title,
                                     markdown: markdown)
                return
            }
            notice = Self.couldNotOpen(strand.title)
        }
    }

    /// What a tap says when neither the device nor the bridge could produce the note.
    /// It names both halves, because which one failed is what tells the reader what to
    /// do about it.
    static func couldNotOpen(_ title: String) -> String {
        "\(title) isn't in this copy of the vault, and the bridge couldn't be reached for it."
    }

    @ViewBuilder
    private func noteSheet(_ source: StrandNoteSource) -> some View {
        switch source {
        case .local(let path, _):
            // The reader the Vault tab pushes, in a stack of its own, so following a
            // wiki link out of a strand note PUSHES rather than replaces. Checkboxes
            // and the editor come with it.
            VaultNoteStack(path: path) { openedNote = nil }
        case .remote(_, let title, let markdown):
            StrandRemoteNoteView(title: title, markdown: markdown,
                                 onOpenLink: onOpenLink) { openedNote = nil }
        }
    }
}

// MARK: - Where the open note came from

/// The two places a strand note can be read from.
///
/// A sum type rather than a path plus a flag: the two cases carry different payloads
/// (one a path this device can write to, one a copy of the bytes it cannot) and the
/// difference is exactly what decides whether the reader offers a checkbox.
public enum StrandNoteSource: Equatable, Identifiable, Sendable {
    /// The note in the Obsidian copy on this device, by vault relative path.
    case local(path: String, title: String)
    /// The bridge's copy, read only.
    case remote(slug: String, title: String, markdown: String)

    public var id: String {
        switch self {
        case .local(let path, _): return "local:\(path)"
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
        StrandsSemantics.rowAccessibilityLabel(strand, today: referenceDay)
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
    let onOpenLink: (TodayLinkOrigin) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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

/// The board's lens, as a menu. Two entries, and neither writes anything.
public struct StrandsSortMenu: View {
    @Binding private var selection: StrandsSortKey

    public init(selection: Binding<StrandsSortKey>) {
        self._selection = selection
    }

    public var body: some View {
        Menu {
            Picker("Order", selection: $selection) {
                ForEach(StrandsSortKey.allCases) { key in
                    Label(key.label, systemImage: key.symbol).tag(key)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: selection.isGrouped
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Order the strands: \(selection.label)")
    }
}
