import SwiftUI
import JesseNetworking

// The Today screen itself: the collapsible narrative header, the schedule block, and
// every section in FILE ORDER.
//
// File order is not a detail to be improved on. `Today.md` is written by the morning
// routine and hand-edited through the day, and its order is the day's own argument —
// what comes first is what was decided to come first. A client that sorted by
// "smart" criteria would silently overrule that every morning, so the only reordering
// here is the one the user explicitly asks for: a drag, a focus action, or a move from
// the menu, each of which changes the FILE. The view sort is a lens and says so.
//
// ## The two ways a row is dragged, and why there are two
//
// **Long-press and drag** is the primary gesture and needs no edit mode: rows are
// `.draggable` and every row (plus the Do Now heading) is a `.dropDestination`. That
// pair, rather than the List's own `.onMove` reordering, because `.onMove` cannot
// express a drag that leaves its section — and "drag it into Do Now" is the gesture
// this screen exists for.
//
// **The edit-mode grip** is the accessible fallback, and it is `.onMove`. A precise
// long drag is exactly the interaction that is hardest with a tremor, with Switch
// Control, or one-handed on a phone; the grips give the same reorder as a short,
// forgiving drag, and VoiceOver drives them directly. Both paths end in
// `model.reorder(id:to:)`, so neither can develop its own idea of what a landing means.

/// The screen. Everything it needs from the outside is the model plus a handful of
/// closures, so the same view renders on a phone, in a Mac window, and in a preview.
public struct TodayListView: View {
    @Bindable private var model: TodayDashboardModel
    /// The selected row's item id, when the shell wants a SELECTABLE list.
    ///
    /// Optional, and nil by default, because selection is not free: on iOS a `List`
    /// handed a selection binding shows selection circles in edit mode, which is
    /// exactly where this screen puts its accessible reorder grips. The phone
    /// therefore passes nothing and gets the list it had. A Mac window passes a
    /// binding, and with it comes the thing selection is FOR — a keyboard: arrow keys
    /// walk the day and space ticks the selected row, through the same code path as a
    /// click on its checkbox (`toggle`), evidence sheet and all.
    private let selection: Binding<String?>?
    private let opensOnDoubleTap: Bool
    private let onOpenLink: (TodayLinkOrigin) -> Void
    private let onOpenDetail: (TodayItem) -> Void
    private let onDiscuss: (TodayItem) -> Void
    private let onPropagate: (TodayItem, String?) -> Void
    private let onProcessUpdates: ([TodayItem]) -> Void
    private let isProcessing: Bool

    /// Which item's evidence sheet is up, if any. Held by id rather than by value so
    /// a refresh landing mid-sheet cannot leave a stale copy of the row on screen.
    @State private var evidenceFor: EvidenceTarget?

    /// Whether the Process-updates confirmation is up. The action is a TELL that
    /// rewrites project files, the Dashboard and the day file, so it fires on an
    /// explicit confirm and never on opening the sheet.
    @State private var isConfirmingProcess = false

    public init(model: TodayDashboardModel,
                isProcessing: Bool = false,
                selection: Binding<String?>? = nil,
                opensOnDoubleTap: Bool = false,
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in },
                onOpenDetail: @escaping (TodayItem) -> Void = { _ in },
                onDiscuss: @escaping (TodayItem) -> Void = { _ in },
                onPropagate: @escaping (TodayItem, String?) -> Void = { _, _ in },
                onProcessUpdates: @escaping ([TodayItem]) -> Void = { _ in }) {
        self.model = model
        self.isProcessing = isProcessing
        self.selection = selection
        self.opensOnDoubleTap = opensOnDoubleTap
        self.onOpenLink = onOpenLink
        self.onOpenDetail = onOpenDetail
        self.onDiscuss = onDiscuss
        self.onPropagate = onPropagate
        self.onProcessUpdates = onProcessUpdates
    }

    public var body: some View {
        Group {
            switch model.displayState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noDayFile:
                TodayEmptyState(
                    symbol: "sun.horizon",
                    title: "No day file yet",
                    message: "Today.md is written by the morning routine. Once it has run, the day shows up here.")
            case .unavailable(let message):
                TodayEmptyState(symbol: "wifi.exclamationmark",
                                title: "Can't reach the bridge",
                                message: message)
            case .content(let snapshot):
                content(snapshot)
            }
        }
        .toolbar {
            // `.primaryAction`, not `.secondaryAction`: the latter collapses into an
            // overflow "More" ellipsis on iOS, which is where a control goes to be
            // undiscoverable.
            ToolbarItem(placement: .primaryAction) {
                TodayProcessButton(count: model.itemsToProcess.count,
                                   isProcessing: isProcessing) {
                    isConfirmingProcess = true
                }
            }
            ToolbarItem(placement: .primaryAction) {
                TodaySortMenu(selection: $model.sortKey)
            }
        }
        .task { await model.load() }
        .refreshable { await model.refresh() }
        .sheet(item: $evidenceFor) { target in
            evidenceSheet(for: target.id)
        }
        .sheet(isPresented: $isConfirmingProcess) {
            TodayProcessSheet(items: model.itemsToProcess,
                              isReadOnly: model.isReadOnly,
                              onConfirm: { items in
                                  isConfirmingProcess = false
                                  onProcessUpdates(items)
                              },
                              onCancel: { isConfirmingProcess = false })
        }
    }

    // MARK: - The document

    @ViewBuilder
    private func content(_ snapshot: TodaySnapshot) -> some View {
        List(selection: selection) {
            if let notice = model.notice {
                TodayNoticeRow(message: notice) { model.dismissNotice() }
                    .listRowSeparator(.hidden)
            }
            if model.isReadOnly || model.isPendingReplay {
                TodayStatusBanner(isOffline: model.isReadOnly,
                                  isPendingReplay: model.isPendingReplay,
                                  message: model.lastErrorMessage)
                    .listRowSeparator(.hidden)
            }
            if let narrative = snapshot.narrative, !narrative.isEmpty {
                TodayNarrativeHeader(narrative: narrative)
                    .listRowSeparator(.hidden)
            }
            if !snapshot.leadItems.isEmpty {
                Section {
                    // No `.onMove`, no `.draggable`: the standing item sits above every
                    // heading by construction and the bridge answers `409` for every op
                    // on it. An affordance that always ends in a refusal is worse than
                    // none.
                    ForEach(snapshot.leadItems) { row($0, in: snapshot) }
                        .moveDisabled(true)
                }
            }
            ForEach(snapshot.sections) { section in
                sectionView(section, in: snapshot)
            }
        }
        .listStyle(.plain)
        .navigationTitle(snapshot.title ?? "Today")
        // Space ticks the selected row — the one keyboard gesture this screen really
        // wants, and the reason the selection binding exists. It runs `toggle`, the
        // SAME function the checkbox's own tap runs, so the read-only refusal, the
        // evidence sheet and the no-note fast path are all inherited rather than
        // re-stated: a second spelling of "what checking an item means" is exactly the
        // one that would forget to ask for evidence.
        //
        // `.ignored` when nothing is selected, or when the selected row is not an item
        // (a briefing report is selectable too and has no box to tick), so space keeps
        // whatever meaning the platform gives it.
        .onKeyPress(.space) {
            guard let id = selection?.wrappedValue,
                  let item = model.snapshot?.item(id: id) else { return .ignored }
            toggle(item)
            return .handled
        }
    }

    @ViewBuilder
    private func sectionView(_ section: TodaySection, in snapshot: TodaySnapshot) -> some View {
        Section {
            if section.isSchedule {
                // A schedule is a block of times, not a checklist: its lines are prose
                // by construction (the bridge parses them as such), and rendering them
                // as one block keeps them readable as a timetable.
                TodayScheduleBlock(section: section)
            } else {
                if model.sortKey(for: section.name).reorders {
                    // Said out loud, in the section it applies to. The day file's order
                    // is the day's own argument, and a section quietly showing a
                    // different one — while its rows still drag and write — would have
                    // the user reasoning about an order nobody wrote.
                    Label(model.sortKey(for: section.name).caption,
                          systemImage: model.sortKey(for: section.name).symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                // Keyed by POSITION, not by `range`. Two prose lines with the same
                // source range are indistinguishable to `ForEach`, which then renders
                // one of them twice and silently drops the other — a real failure mode
                // for any producer whose ranges are not per-line (a synthetic snapshot,
                // a future parser that stops carrying offsets). Position is unique by
                // construction and the list is rebuilt whole on every snapshot anyway.
                ForEach(Array(section.prose.enumerated()), id: \.offset) { _, prose in
                    Text(TodaySemantics.strippedMarkdown(prose.text))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(section.reports) { report in
                    TodayReportRow(report: report,
                                   onGlance: { Task { await model.glance(id: report.id) } },
                                   onOpenLink: onOpenLink)
                }
                ForEach(section.items) { item in
                    row(item, in: snapshot)
                        .draggable(item.id)
                        .dropDestination(for: String.self) { ids, _ in
                            drop(ids, above: item)
                        }
                }
                .onMove { source, destination in
                    move(in: section, from: source, to: destination)
                }
                .moveDisabled(model.sortKey(for: section.name).reorders)
            }
        } header: {
            TodaySectionHeader(section: section,
                               open: TodaySemantics.openCount(in: section),
                               sort: model.sortKey(for: section.name),
                               onSort: { model.setSortKey($0, for: section.name) })
                // The Do Now heading is a drop target in its own right: "put this at
                // the front of the day" is the one landing whose meaning does not
                // depend on which row it was dropped near, and aiming at a heading is a
                // far easier gesture than aiming at the first row of a section.
                .dropDestination(for: String.self) { ids, _ in
                    guard section.name.hasPrefix("Do Now") else { return }
                    drop(ids, into: section.name, at: 0)
                }
        }
    }

    private func row(_ item: TodayItem, in snapshot: TodaySnapshot) -> some View {
        // Asked of the MODEL, not of the snapshot being drawn: what a move would do is a
        // fact about the day file's order, and the snapshot in hand here may be a
        // sorted lens over it. The model holds both and pairs them correctly once.
        let moves = model.availableMoves(for: item)
        let focusActions = model.availableFocus(for: item)
        return TodayItemRow(
            item: item,
            pending: model.isPending(item.id),
            evidence: model.evidence(for: item),
            availableMoves: moves,
            focusActions: focusActions,
            opensOnDoubleTap: opensOnDoubleTap,
            onToggle: { _ in toggle(item) },
            onMove: { op in Task { await model.move(id: item.id, op: op) } },
            onFocus: { focus in Task { await model.focus(id: item.id, focus) } },
            onOpen: { onOpenDetail(item) },
            onDiscuss: { onDiscuss(item) },
            onPropagate: { onPropagate(item, model.evidence(for: item)) },
            onOpenLink: onOpenLink)
        // Swipe carries the actions worth a one-handed gesture; the long-press menu
        // and the ellipsis carry the complete set including all four moves. A swipe
        // slot cannot open a submenu, so putting every move here would mean four
        // buttons competing for the width of a row.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { onDiscuss(item) } label: {
                Label("Discuss", systemImage: "bubble.left.and.text.bubble.right")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.checked {
                Button { onPropagate(item, model.evidence(for: item)) } label: {
                    Label("Close at source", systemImage: "arrow.up.forward.square")
                }
                .tint(.green)
            }
            // FOCUS, not a bare move — the same durable write, named for what the user
            // means by it. Both focus ops are absolute, so they mean the same thing
            // under every lens and are offered whatever the section is sorted by.
            ForEach(focusActions) { focus in
                Button { Task { await model.focus(id: item.id, focus) } } label: {
                    Label(focus.swipeLabel, systemImage: focus.symbol)
                }
                .tint(focus == .doNow ? .orange : .indigo)
            }
        }
    }

    /// **What ticking an item means**, in one place: the checkbox's tap and the space
    /// key both land here, so neither can develop its own idea of it.
    private func toggle(_ item: TodayItem) {
        // Read-only is answered HERE, before the sheet: the alternative is taking a
        // line of evidence off the user and then refusing to write it.
        guard !model.refuseInteractionIfReadOnly() else { return }
        // Unchecking never asks for a note — there is nothing to record about undoing
        // something, and the sheet would be pure friction.
        if item.checked {
            Task { await model.check(id: item.id, checked: false) }
        } else {
            evidenceFor = EvidenceTarget(id: item.id)
        }
    }

    // MARK: - Landing a drag

    /// A row dropped onto another row: land it where that row currently sits, in the
    /// FILE's own index — the model judges every landing against the file, and the row
    /// under the finger may be sitting somewhere a lens put it.
    private func drop(_ ids: [String], above item: TodayItem) {
        guard let file = model.snapshot,
              let section = file.sections.first(where: { $0.name == item.sectionName }),
              let index = section.items.firstIndex(where: { $0.id == item.id })
        else { return }
        drop(ids, into: item.sectionName, at: index)
    }

    /// The one place a drag becomes a write.
    ///
    /// Every judgement about whether the landing is legal — the lead block, a section
    /// no op can reach, a section on a lens, a read-only day — belongs to
    /// `model.reorder`, which answers with a plan and puts its refusal on the notice
    /// row. This function's whole job is to turn a payload into an id and a target.
    /// The one thing it decides for itself is whether the payload IS one of our rows:
    /// the drag carries a plain string, so a drop from another app arrives here too and
    /// must land nowhere rather than be interpreted.
    private func drop(_ ids: [String], into sectionName: String, at index: Int) {
        guard let id = ids.first, model.snapshot?.item(id: id) != nil else { return }
        Task {
            await model.reorder(id: id,
                                to: TodayDropTarget(sectionName: sectionName, index: index))
        }
    }

    /// The edit-mode grips. `.onMove` hands over an insertion index in the pre-removal
    /// array, which `settledIndex` converts once — see `TodayReorder.swift`.
    private func move(in section: TodaySection, from source: IndexSet, to destination: Int) {
        guard source.count == 1, let first = source.first,
              section.items.indices.contains(first)
        else { return }
        let item = section.items[first]
        let settled = TodaySemantics.settledIndex(from: first, to: destination)
        Task {
            await model.reorder(id: item.id,
                                to: TodayDropTarget(sectionName: section.name, index: settled))
        }
    }

    @ViewBuilder
    private func evidenceSheet(for id: String) -> some View {
        if let item = model.snapshot?.item(id: id) {
            EvidenceSheet(itemLead: item.lead.isEmpty ? "this item" : item.lead,
                          onComplete: { note in
                              evidenceFor = nil
                              Task { await model.check(id: id, checked: true, evidence: note) }
                          },
                          onCancel: { evidenceFor = nil })
        }
    }
}

// MARK: - The sort control

/// The view sort, as a menu.
///
/// A LENS, and it says so: every option carries the line that says whether it touches
/// the file (none of them do). The control is deliberately not called "Sort the day" —
/// sorting the day is what a drag and the move menu do, in the file.
public struct TodaySortMenu: View {
    @Binding private var selection: TodaySortKey

    public init(selection: Binding<TodaySortKey>) {
        self._selection = selection
    }

    public var body: some View {
        Menu {
            Picker("Order", selection: $selection) {
                ForEach(TodaySortKey.allCases) { key in
                    Label(key.label, systemImage: key.symbol).tag(key)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // The glyph changes with the lens, so the current order is legible from the
            // toolbar without opening the menu.
            Image(systemName: selection.reorders
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Order every section: \(selection.label)")
    }
}

// MARK: - Process updates

/// The toolbar's Process-updates button.
///
/// It carries the COUNT, and it is absent when that count is zero: the action is
/// "close everything I ticked off", so on a day with nothing ticked there is nothing
/// for it to do and a button that opens a sheet saying so is a button that lies about
/// having work. The count is also the honest warning about blast radius — the user
/// sees "6" before they see the list.
struct TodayProcessButton: View {
    let count: Int
    let isProcessing: Bool
    let action: () -> Void

    var body: some View {
        if isProcessing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing updates")
        } else if count > 0 {
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.up")
                    Text("\(count)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .accessibilityLabel(count == 1 ? "Process 1 checked item"
                                           : "Process \(count) checked items")
        }
    }
}

/// The confirmation: exactly what is about to be closed at source, and one button.
///
/// A confirmation rather than a fire-on-tap, and a LIST rather than a count. This turn
/// writes to every named project file, to the Dashboard, and to the day file, and it
/// removes the listed lines from `Today.md` — the sort of thing that must never happen
/// because a thumb brushed a toolbar. Showing the actual lines is the difference
/// between confirming a number and confirming a decision.
public struct TodayProcessSheet: View {
    /// What the sheet says when nothing is ticked. Reachable only by a caller that
    /// presents it anyway — the toolbar button hides itself at zero — but stated rather
    /// than left as an empty list, which reads as a loading failure.
    public static let nothingToProcess =
        "Nothing is checked off yet, so there's nothing to close at source."

    private let items: [TodayItem]
    private let isReadOnly: Bool
    private let onConfirm: ([TodayItem]) -> Void
    private let onCancel: () -> Void

    public init(items: [TodayItem], isReadOnly: Bool = false,
                onConfirm: @escaping ([TodayItem]) -> Void,
                onCancel: @escaping () -> Void) {
        self.items = items
        self.isReadOnly = isReadOnly
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            TodayProjectAccentBar(project: item.project)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.lead.isEmpty ? item.text : item.lead)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.sectionName.isEmpty ? "Standing item" : item.sectionName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if items.isEmpty {
                        Text(Self.nothingToProcess)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Will be closed at source")
                }
                // Not a `footer:` — a long footer ellipsises on macOS, and this is the
                // sentence that says what the turn will actually do to the vault.
                Section {
                    Label("Each item's project file and Dashboard entry are updated, then the lines leave Today.md. If that leaves the day short, it's topped up from the Dashboard.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isReadOnly {
                        Label("You're offline, so this can't run yet.",
                              systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Process updates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Process") { onConfirm(items) }
                        .disabled(items.isEmpty || isReadOnly)
                }
            }
        }
    }
}

// MARK: - Header pieces

/// The day's narrative, collapsible.
///
/// Collapsed by DEFAULT and remembered only for the session: the narrative is a
/// paragraph of context the agent wrote about the shape of the day, worth reading
/// once in the morning and pure vertical cost every time the tab is opened after
/// that. Collapsing it keeps the first actionable row above the fold, which is what
/// the screen is for.
struct TodayNarrativeHeader: View {
    let narrative: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(expanded ? "Today's note" : firstLine)
                        .font(.subheadline)
                        .fontWeight(expanded ? .semibold : .regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(TodaySemantics.strippedMarkdown(narrative))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Today's note")
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }

    private var firstLine: String {
        TodaySemantics.strippedMarkdown(
            narrative.split(separator: "\n").first.map(String.init) ?? narrative)
    }
}

/// A section heading with its open count and its own view sort. The count is shown
/// only where it means something — a briefing section's task lines are incidental, and
/// "0" next to a finished section is noise.
///
/// The sort lives HERE, per section, rather than only in the toolbar. A day file's
/// sections are not alike: `Do Now` is a short hand-ordered list whose order is the
/// point, while an aging backlog is a pile worth seeing oldest-first. One document-wide
/// answer forces those two to share a lens they do not share a need for.
struct TodaySectionHeader: View {
    let section: TodaySection
    let open: Int
    let sort: TodaySortKey
    let onSort: (TodaySortKey) -> Void

    var body: some View {
        HStack {
            Text(section.name)
            Spacer()
            if open > 0, !section.isBriefing {
                Text("\(open)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(open) open")
            }
            if !section.isSchedule, !section.items.isEmpty {
                Menu {
                    // Buttons with a checkmark rather than a `Picker`: a picker wants a
                    // `Binding`, and the binding this header could offer would be built
                    // from a closure that crosses an isolation boundary on every
                    // redraw. The rendered menu is the same either way.
                    ForEach(TodaySortKey.allCases) { key in
                        Button { onSort(key) } label: {
                            Label(key.label,
                                  systemImage: key == sort ? "checkmark" : key.symbol)
                        }
                    }
                } label: {
                    Image(systemName: sort.reorders
                          ? "arrow.up.arrow.down.circle.fill"
                          : "arrow.up.arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Order \(section.name): \(sort.label)")
            }
        }
    }
}

/// The schedule as one block of times. Its bullets are prose to the parser, so they
/// are rendered as lines rather than as rows with checkboxes that would not apply.
struct TodayScheduleBlock: View {
    let section: TodaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Position-keyed for the same reason as the prose rows above: a repeated
            // source range must not collapse two lines of the timetable into one.
            ForEach(Array(section.prose.enumerated()), id: \.offset) { _, prose in
                Label {
                    Text(TodaySemantics.strippedMarkdown(TodaySemantics.taskBody(prose.text)))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The one-line answer to an action that did not happen: a move the bridge refused
/// (`409`), a drag the day file's shape forbids, an item that vanished, or a tap made
/// while the day is read-only.
///
/// Inline at the top of the document rather than an alert, which is what this
/// started as. An alert is a modal interruption that demands a dismissal before the
/// user can look at the thing the message is about — for "that move isn't possible"
/// the useful next act is to LOOK at the list and pick another one. The row states
/// what happened, stays until the next action supersedes it, and can be dismissed
/// without moving the user off the screen.
struct TodayNoticeRow: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The stale / not-yet-on-disk strip.
///
/// Two different claims that must not be conflated. Offline means "what you are
/// reading may be out of date"; pending means "your change is recorded and WILL land,
/// a turn is mid-write". The second is reassurance, not a warning, and showing it in
/// the same red as the first would train the user to ignore both.
struct TodayStatusBanner: View {
    let isOffline: Bool
    let isPendingReplay: Bool
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isOffline {
                Label(message ?? "Showing the last day loaded.",
                      systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isPendingReplay {
                Label("Your change is saved and will land when the current turn finishes.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A full-screen empty state.
struct TodayEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// The id whose evidence sheet is up. A one-field wrapper rather than a retroactive
/// `Identifiable` on `String`: a public conformance on a standard-library type from a
/// library target leaks into every app that links it and collides with the next one
/// to have the same idea.
struct EvidenceTarget: Identifiable, Equatable {
    let id: String
}
