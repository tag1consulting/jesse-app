import SwiftUI
import JesseNetworking

// The schedule, as a screen: one section per chain, the head first and its links indented
// under it in fire order.
//
// The two things this screen exists to make possible are both one tap: turning a job off
// (with a deadline, so it comes back by itself) and running one now. Everything else on the
// row is there to answer "why did that not happen" without opening a terminal — the outcome,
// the reason, the streak, and the output the job was contracted to produce.

public struct ScheduleView: View {
    @State private var model: ScheduleModel
    @State private var pendingFire: ScheduleRow?
    /// The row whose "until" is being chosen while turning it off. Nil means no sheet.
    @State private var pendingDisable: ScheduleRow?

    public init(configuration: OpsConfiguration) {
        _model = State(initialValue: ScheduleModel(configuration: configuration))
    }

    public var body: some View {
        List {
            if let error = model.loadError {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
            headerSection
            ForEach(model.chains) { chain in
                Section {
                    ForEach(chain.members) { member in
                        ScheduleRowView(member: member,
                                        bridgeTz: model.bridgeTz,
                                        message: model.rowMessages[member.row.id],
                                        isBusy: model.busyJob == member.row.id,
                                        onToggle: { on in
                                            if on {
                                                Task { await model.setEnabled(id: member.row.id,
                                                                              enabled: true,
                                                                              until: nil) }
                                            } else {
                                                pendingDisable = member.row
                                            }
                                        },
                                        onFire: { pendingFire = member.row })
                    }
                } header: {
                    Text(chain.members.count > 1 ? "\(chain.id) chain" : chain.id)
                }
            }
            if !model.invalid.isEmpty { invalidSection }
        }
        .navigationTitle("Schedule")
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reloadConfig() }
                } label: {
                    Label("Reload config", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .confirmationDialog("Run \(pendingFire?.id ?? "") now?",
                            isPresented: Binding(get: { pendingFire != nil },
                                                 set: { if !$0 { pendingFire = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingFire) { row in
            Button("Run now") {
                let id = row.id
                pendingFire = nil
                Task { await model.fire(id: id) }
            }
            Button("Cancel", role: .cancel) { pendingFire = nil }
        } message: { row in
            Text("Runs \(row.id) and everything chained behind it, right now, on the same path a due occurrence takes. \(model.route.label).")
        }
        .sheet(item: $pendingDisable) { row in
            DisableUntilSheet(jobId: row.id) { until in
                let id = row.id
                pendingDisable = nil
                Task { await model.setEnabled(id: id, enabled: false, until: until) }
            } onCancel: {
                pendingDisable = nil
            }
        }
    }

    private var headerSection: some View {
        Section {
            if let tz = model.bridgeTz {
                LabeledContent("Bridge zone", value: tz)
            }
            if let profile = model.document?.profile {
                LabeledContent("Profile", value: profile.name ?? "home")
            }
            if model.document?.persistent == false {
                // A schedule whose state is not persisted forgets every "last fired" on
                // restart, which changes what the outcomes below mean.
                Text("The scheduler's state is not being persisted, so outcomes reset when the bridge restarts.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let report = model.reloadReport {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.reloaded ? "Config reloaded." : "Config unchanged.")
                        .font(.callout)
                    ForEach(report.errors, id: \.self) { e in
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text("Fire and enable are \(model.route.label).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var invalidSection: some View {
        Section {
            ForEach(model.invalid) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.id).foregroundStyle(.red)
                    Text(entry.reason).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Disabled by validation")
        } footer: {
            Text("These entries are in the config file and are NOT running. Each one names what is wrong with it.")
        }
    }
}

// MARK: - One row

struct ScheduleRowView: View {
    let member: ScheduleChain.Member
    let bridgeTz: String?
    let message: String?
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onFire: () -> Void

    private var row: ScheduleRow { member.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HealthDot(OpsFormat.outcomeHealth(row.lastOutcome))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.id).font(.body.weight(member.depth == 0 ? .semibold : .regular))
                    Text("\(row.kind.isEmpty ? (row.isHead ? "head" : "link") : row.kind) · \(row.whenLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let n = row.consecutiveFailures, n > 0 {
                    // The streak, not just the last outcome: "failed" says last night, this
                    // says it was the sixth night running.
                    Text("\(n)×")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(n) consecutive failures")
                }
                Toggle("", isOn: Binding(get: { row.enabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .disabled(isBusy)
            }

            detailLine("Days", row.resolvedDays)
            detailLine("Profiles", (row.profiles ?? ["home", "away"]).joined(separator: ", "))
            // BOTH ZONES, because a job fires where the bridge stands and is read where its
            // owner is, and while they are away those are not the same clock.
            detailLine("Next", OpsFormat.inBothZones(row.nextFireMs, bridgeTz: bridgeTz))
            if let outcome = row.lastOutcome {
                detailLine("Last", [outcome, OpsFormat.duration(ms: row.lastDurationMs)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if let reason = row.lastReason, !reason.isEmpty {
                detailLine("Reason", reason)
            }
            detailLine("Output", row.outputLabel)
            if let from = row.promotedFrom {
                detailLine("Promoted", "took the clock slot of \(from)")
            }
            if let ov = row.override {
                detailLine("Override", Self.overrideLine(ov))
            }
            if let retry = row.retryDueMs {
                detailLine("Retry due", OpsFormat.inBothZones(retry, bridgeTz: bridgeTz))
            }

            HStack {
                Button("Fire now", action: onFire)
                    .buttonStyle(.bordered)
                    // Disabled WHILE RUNNING: firing a chain that is already running earns a
                    // 409 from the bridge, and a button that only ever produces an error is
                    // better not offered.
                    .disabled(row.running == true || isBusy)
                if row.running == true {
                    Text("running").font(.caption).foregroundStyle(.secondary)
                }
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(member.depth) * 16)
    }

    /// "off until Sun 7 Sep, 09:00", or "off, no deadline" — and lapsed overrides say so,
    /// because "it was disabled until Sunday and Sunday has passed" is a thing someone asks.
    static func overrideLine(_ ov: ScheduleRow.EnableOverride) -> String {
        let state = ov.enabled ? "on" : "off"
        let lapsed = (ov.active == false) ? " (lapsed)" : ""
        guard let until = ov.untilMs else { return "\(state), no deadline\(lapsed)" }
        return "\(state) until \(OpsFormat.dayAndTime(OpsFormat.date(fromMs: until), in: .current))\(lapsed)"
    }

    @ViewBuilder
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Turning one off

/// Choosing a deadline while turning a job off.
///
/// The default is NO deadline, which is what the bridge's own default is, and the sheet says
/// what that costs: a disabled job is silent by design, so an override nobody remembers is a
/// job that never runs again.
struct DisableUntilSheet: View {
    let jobId: String
    let onConfirm: (Date?) -> Void
    let onCancel: () -> Void

    @State private var hasDeadline = false
    @State private var until = Date().addingTimeInterval(24 * 3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Turn back on automatically", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("At", selection: $until)
                    }
                } footer: {
                    Text(hasDeadline
                         ? "The override lapses then and the config's own setting takes over again."
                         : "Without a deadline this job stays off until you turn it back on here. A disabled job is silent, so nothing will remind you.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Turn off \(jobId)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Turn off") { onConfirm(hasDeadline ? until : nil) }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}
