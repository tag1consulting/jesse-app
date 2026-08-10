import SwiftUI
import JesseNetworking

// The Today screen itself: the collapsible narrative header, the schedule block, and
// every section in FILE ORDER.
//
// File order is not a detail to be improved on. `Today.md` is written by the morning
// routine and hand-edited through the day, and its order is the day's own argument —
// what comes first is what was decided to come first. A client that sorted by
// "smart" criteria would silently overrule that every morning, so the only reordering
// here is the one the user explicitly asks for through the move menu, which changes
// the FILE.

/// The screen. Everything it needs from the outside is the model plus a link handler,
/// so the same view renders on a phone, in a Mac window, and in a preview.
public struct TodayListView: View {
    @Bindable private var model: TodayDashboardModel
    private let onOpenLink: (TodayLink) -> Void
    private let onDiscuss: (TodayItem) -> Void
    private let onPropagate: (TodayItem, String?) -> Void

    /// Which item's evidence sheet is up, if any. Held by id rather than by value so
    /// a refresh landing mid-sheet cannot leave a stale copy of the row on screen.
    @State private var evidenceFor: EvidenceTarget?

    public init(model: TodayDashboardModel,
                onOpenLink: @escaping (TodayLink) -> Void = { _ in },
                onDiscuss: @escaping (TodayItem) -> Void = { _ in },
                onPropagate: @escaping (TodayItem, String?) -> Void = { _, _ in }) {
        self.model = model
        self.onOpenLink = onOpenLink
        self.onDiscuss = onDiscuss
        self.onPropagate = onPropagate
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
        .task { await model.load() }
        .refreshable { await model.refresh() }
        .sheet(item: $evidenceFor) { target in
            evidenceSheet(for: target.id)
        }
    }

    // MARK: - The document

    @ViewBuilder
    private func content(_ snapshot: TodaySnapshot) -> some View {
        List {
            if model.isOffline || model.isPendingReplay {
                TodayStatusBanner(isOffline: model.isOffline,
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
                    ForEach(snapshot.leadItems) { row($0, in: snapshot) }
                }
            }
            ForEach(snapshot.sections) { section in
                sectionView(section, in: snapshot)
            }
        }
        .listStyle(.plain)
        .navigationTitle(snapshot.title ?? "Today")
        .alert("That move isn't possible",
               isPresented: .constant(model.lastConflictMessage != nil)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastConflictMessage ?? "")
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
                ForEach(section.prose, id: \.range) { prose in
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
                ForEach(section.items) { row($0, in: snapshot) }
            }
        } header: {
            TodaySectionHeader(section: section,
                               open: TodaySemantics.openCount(in: section))
        }
    }

    private func row(_ item: TodayItem, in snapshot: TodaySnapshot) -> some View {
        TodayItemRow(
            item: item,
            pending: model.isPending(item.id),
            evidence: model.evidence(for: item),
            availableMoves: TodaySemantics.availableMoves(for: item, in: snapshot),
            onToggle: { wantsChecked in
                // Unchecking never asks for a note — there is nothing to record about
                // undoing something, and the sheet would be pure friction.
                if wantsChecked {
                    evidenceFor = EvidenceTarget(id: item.id)
                } else {
                    Task { await model.check(id: item.id, checked: false) }
                }
            },
            onMove: { op in Task { await model.move(id: item.id, op: op) } },
            onDiscuss: { onDiscuss(item) },
            onPropagate: { onPropagate(item, model.evidence(for: item)) },
            onOpenLink: onOpenLink)
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

/// A section heading with its open count. The count is shown only where it means
/// something — a briefing section's task lines are incidental, and "0" next to a
/// finished section is noise.
struct TodaySectionHeader: View {
    let section: TodaySection
    let open: Int

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
        }
    }
}

/// The schedule as one block of times. Its bullets are prose to the parser, so they
/// are rendered as lines rather than as rows with checkboxes that would not apply.
struct TodayScheduleBlock: View {
    let section: TodaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(section.prose, id: \.range) { prose in
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
