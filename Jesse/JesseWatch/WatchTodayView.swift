import SwiftUI

// Today on the wrist: one list, one gesture.
//
// The standing lead item, then open Do Now work, then a footer line for everything
// that stayed on the phone. Tapping a row checks it off — no evidence field, no
// move menu, no Discuss, no Propagate. Those are phone and Mac affordances, and an
// evidence-less check is fully valid downstream, so the wrist gets the one action a
// wrist is actually good for.
//
// Nothing here reaches the network. Every row's state comes from `WatchTodayModel`,
// which is fed by the phone's pushed application context and knows nothing about a
// bridge — the same rule the chat screen follows.

struct WatchTodayView: View {
    @Bindable var model: WatchTodayModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if model.isStale { staleBanner }

            if model.hasDay {
                ForEach(model.rows) { row in
                    rowView(row)
                }
                footer
            } else {
                emptyState
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Today")
        // The stale guard's trigger, and the reason there is no timer on this
        // screen. A wrist is glanced at, not watched: the only moments the answer
        // to "is this still today's?" can change under the user are a fresh push
        // (which the model handles itself) and the app coming back to the front
        // after a night. Both are covered; neither costs a running clock.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.refreshFreshness() }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: WatchTodayModel.Row) -> some View {
        Button {
            model.toggle(row.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(row.state))
                    .foregroundStyle(tint(row.state))
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.lead)
                        .font(row.isLead ? .body.weight(.semibold) : .body)
                        .strikethrough(row.state == .done || row.state == .confirmed)
                        .foregroundStyle(row.isSettled ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    // Said out loud only for the state a user could otherwise
                    // mistake for a failure: the phone was not there, so the check is
                    // on the reliable queue rather than gone.
                    if row.state == .queued {
                        Text("Waiting for your phone")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        // A settled receipt is a record, not a control: the item is no longer part of
        // the day's open work, so there is nothing left here to tick.
        .disabled(row.isSettled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.lead)
        .accessibilityValue(accessibilityValue(row.state))
        .accessibilityHint(row.isSettled ? "" : "Double tap to check off")
    }

    private func symbol(_ state: WatchTodayModel.RowState) -> String {
        switch state {
        case .open: return "circle"
        case .done: return "checkmark.circle.fill"
        case .pending: return "checkmark.circle"
        case .queued: return "arrow.up.circle"
        case .confirmed: return "checkmark.circle.fill"
        }
    }

    private func tint(_ state: WatchTodayModel.RowState) -> Color {
        switch state {
        case .open: return .secondary
        case .done: return .accentColor
        case .pending: return .accentColor.opacity(0.5)
        case .queued: return .orange
        case .confirmed: return .secondary
        }
    }

    private func accessibilityValue(_ state: WatchTodayModel.RowState) -> String {
        switch state {
        case .open: return "Not done"
        case .done: return "Done"
        case .pending: return "Checked off, sending"
        case .queued: return "Checked off, waiting for your phone"
        case .confirmed: return "Done, confirmed by your phone"
        }
    }

    // MARK: Furniture

    /// What did not fit. Two numbers on one line, because "everything else" is a
    /// count on a wrist and a list on a phone.
    @ViewBuilder
    private var footer: some View {
        if model.moreOnPhone > 0 || model.doneCount > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if model.moreOnPhone > 0 {
                    Text("\(model.moreOnPhone) more on your phone")
                }
                if model.doneCount > 0 {
                    Text("\(model.doneCount) done today")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
        }
    }

    /// The stale guard's face. A day the phone pushed more than eighteen hours ago
    /// renders under this rather than passing quietly for today — the failure being
    /// prevented is a wrist that shows yesterday's list, perfectly formatted.
    private var staleBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(model.dayLabel.map { "From \($0)" } ?? "Out of date",
                  systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Open Jesse on your phone to refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No day yet")
                .font(.body.weight(.semibold))
            Text("Open Jesse on your phone and your day will appear here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
