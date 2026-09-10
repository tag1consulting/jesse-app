import SwiftUI
import JesseAsk
import JesseNetworking

// The Ops screen: the sentinel's status document as cards, the eight verbs as buttons, the
// fire ledger, a way through to the schedule, and the Deploy card.
//
// Every action is behind a confirmation that NAMES THE VERB AND THE LABEL — "Restart
// com.tag1.jesse-bridge?", not "Are you sure?". These buttons restart the process the app is
// talking to and delete files; a dialog that does not say which thing it is about to act on
// is a dialog people learn to dismiss.
//
// One view, both platforms. It deliberately carries no `NavigationStack` of its own: iOS
// pushes it from Settings and macOS presents it in a stack of its own, and a view that brought
// its own stack would nest one inside the other on iOS.
//
// "ASK ABOUT THIS" runs through every card here, and it draws NOTHING at rest: `.askable`
// attaches a native `contextMenu` and no icon, badge or chip, so at rest this screen renders
// pixel for pixel as it did before the feature existed. Three rules govern where it goes:
//
//   * A CARD'S ASK SITS ON ITS ROWS, wrapped in a `Group` so one modifier covers all of them
//     — a `Group`'s modifiers apply to each of its children inside a `List`, so a long press
//     anywhere on the card offers the card. Repeating rows (a service, a ledger line, a
//     release) carry their own item-level ask instead, which is the narrower press winning.
//   * A VIEW THAT ALREADY HAD A LONG PRESS keeps it. The deploy log tail is
//     `.textSelection(.enabled)`, and a `contextMenu` takes that gesture over, so it uses
//     the `copyText:` spelling and the menu carries a Copy of its own.
//   * NOTHING STACKS ON AN EXISTING CONTEXT MENU. SwiftUI does not merge two of those; the
//     second wins and the first silently disappears. No view on this screen has one.
//
// Taps, the confirmation dialogs, the ledger's disclosure group and the Schedule navigation
// link are all untouched: a `contextMenu` composes with them rather than replacing them.

public struct OpsView: View {
    @State private var model: OpsModel
    /// The action awaiting confirmation. One piece of state for eight buttons, so there is one
    /// dialog and one place that decides what it says.
    @State private var pending: OpsAction?
    @State private var showLedger = false

    public init(configuration: OpsConfiguration) {
        _model = State(initialValue: OpsModel(configuration: configuration))
    }

    /// WHEN the reading on screen was taken. Rebuilt on each body evaluation, which is what
    /// makes an ask made now say "taken at 14:32" rather than quoting the moment the screen
    /// was opened. Its identity is only the device day, so a second press an hour later still
    /// resumes the same conversation — see `OpsAskReading`.
    private var reading: OpsAskReading { OpsAskReading() }

    /// The page-level ask: every card on screen at once, which is the scope the two
    /// questions this feature exists for are actually asked at ("is anything wrong here",
    /// "what would a deploy bring in").
    private var pageAsk: AskContext {
        OpsAsk.page(status: model.status, deploy: model.deploy,
                    refreshError: model.refreshError,
                    isSentinelPaired: model.isSentinelPaired,
                    verbs: OpsAction.allActions(labels: labelsBySlug),
                    lastVerb: model.lastVerb, isRunningVerb: model.isRunningVerb,
                    reading: reading)
    }

    public var body: some View {
        List {
            if !model.isSentinelPaired {
                pairCallToAction
            } else {
                if let error = model.refreshError {
                    Section { Text(error).font(.callout).foregroundStyle(.red) }
                }
                bridgeCard
                servicesCard
                tailscaleCard
                diskCard
                gitCard
                qmdCard
                watchdogCard
                actionsSection
                ledgerSection
            }
            // THE SCHEDULE IS NOT A SENTINEL FEATURE, so it is outside the branch above. It
            // is read from the bridge and its two verbs fall back to the bridge when no
            // sentinel is paired — putting the row behind the sentinel CTA would make that
            // fallback unreachable from the app that implements it.
            scheduleSection
            if model.isSentinelPaired { deployCard }
        }
        .navigationTitle("Bridge ops")
        .askPageToolbar(pageAsk)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        // Re-armed whenever a new deploy appears, so pressing Deploy starts the poll without
        // the view having to own a timer that outlives it.
        .task(id: model.deploy?.deploy?.deployId ?? "") { await model.pollDeployWhileRunning() }
        .confirmationDialog(pending?.title ?? "",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                let chosen = action
                pending = nil
                Task { await perform(chosen) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - Not paired

    @ViewBuilder
    private var pairCallToAction: some View {
        Section {
            ContentUnavailableView {
                Label("Pair the sentinel", systemImage: "shield.lefthalf.filled")
            } description: {
                Text("The sentinel is a second process on the Studio, on its own port and its own token, that watches the bridge and can restart it. Scan a pairing QR from a bridge that has one configured, or enter its host, port and token in Settings.")
            }
        }
    }

    // MARK: - The cards

    private var bridgeCard: some View {
        Section("Bridge") {
            // The `Group` is what makes ONE `.askable` cover the whole card: its modifiers
            // apply to each child row inside a `List`, so a long press on any line of the
            // card offers the card. Same shape on the five cards below.
            Group {
                OpsProbeHeader(title: "Reachability", probe: model.status?.bridge)
                if let d = model.status?.bridge.detail {
                    LabeledContent("Version", value: d.health?.version ?? "unknown")
                    LabeledContent("Latency", value: d.latencyMs.map { "\($0) ms" } ?? "unknown")
                    LabeledContent("Profile", value: d.health?.profile ?? "home")
                    if let tz = d.health?.tz { LabeledContent("Zone", value: tz) }
                    // Only the COUNT: the drift array is a diagnostic the bridge's own log carries
                    // in full, and a status card that printed it would be unreadable on a phone.
                    LabeledContent("Drift entries", value: String(d.health?.drift?.count ?? 0))
                }
            }
            .askable(OpsAsk.bridgeCard(model.status, reading: reading))
        }
    }

    private var servicesCard: some View {
        Section("Services") {
            OpsProbeHeader(title: "launchd", probe: model.status?.services)
                .askable(OpsAsk.servicesCard(model.status, reading: reading))
            ForEach(model.status?.serviceRows ?? []) { row in
                LabeledContent {
                    Text(OpsFormat.serviceState(row))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 8) {
                        HealthDot(row.health)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.id)
                            if let label = row.label {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // A row is its own subject — "what does the lock reaper do", "is this state
                // normal for it" — so the narrower press wins here and the card's own ask
                // stays on the probe header above.
                .askable(OpsAsk.serviceRow(row, reading: reading))
            }
        }
    }


    // MARK: - Release notes

    /// What is running, and what a deploy would bring in — between the `origin/main` row and
    /// the button, which is the order the question is asked in: what have I got, what would I
    /// get, do I press it.
    ///
    /// Plain `Text`, not markdown: the sentinel already reduced each release to a title and a
    /// handful of one-sentence claims, and this module has no markdown renderer.
    @ViewBuilder
    private func releaseNotes(_ releases: DeployStatusDocument.Releases) -> some View {
        if let deployed = releases.deployed {
            releaseBlock(deployed, label: "Running release")
        }
        if !releases.undeployed.isEmpty {
            Text("Not yet deployed (\(releases.undeployed.count))")
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            // The newest few in full; the rest folded away, because a Studio twelve releases
            // behind would otherwise push the Deploy button off the screen.
            ForEach(releases.undeployed.prefix(Self.expandedReleases)) { r in
                releaseBlock(r, label: nil)
            }
            let rest = Array(releases.undeployed.dropFirst(Self.expandedReleases))
            if !rest.isEmpty {
                DisclosureGroup("\(rest.count) older release\(rest.count == 1 ? "" : "s")") {
                    ForEach(rest) { r in releaseBlock(r, label: nil) }
                }
                .font(.caption)
            }
            // Silent truncation reads as completeness, so it is said out loud.
            if releases.truncated > 0 {
                Text("\(releases.truncated) older release\(releases.truncated == 1 ? " is" : "s are") not shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let why = releases.reason {
            // The list is empty AND it is not simply "already current" — say which case.
            Text("No release list: \(why).")
                .font(.caption).foregroundStyle(.secondary)
        } else if releases.deployed != nil {
            Text("origin/main is already what is running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// How many undeployed releases are shown expanded before the rest are folded away.
    static let expandedReleases = 3

    /// One release: its title, then its claims, one `Text` each so they wrap independently.
    ///
    /// The ask goes on HERE rather than at the three call sites, so the blocks folded away
    /// inside the disclosure group are askable too — and so a press on any of them opens a
    /// chat that also knows whether that release is the one running.
    @ViewBuilder
    private func releaseBlock(_ r: DeployStatusDocument.Release, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            Text(r.title).font(.body)
            Text(r.subtitle).font(.caption2).foregroundStyle(.tertiary)
            ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if r.more > 0 {
                Text("+\(r.more) more change\(r.more == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .askable(OpsAsk.release(r, label: label, in: model.deploy, reading: reading))
    }

    private var tailscaleCard: some View {
        Section("Tailscale") {
            Group {
                OpsProbeHeader(title: "Tailnet", probe: model.status?.tailscale)
                if let d = model.status?.tailscale.detail {
                    LabeledContent("Online", value: (d.online ?? false) ? "yes" : "no")
                    if let name = d.dnsName { LabeledContent("Name", value: name) }
                    if let ips = d.ips, !ips.isEmpty {
                        LabeledContent("Addresses", value: ips.joined(separator: ", "))
                    }
                }
            }
            .askable(OpsAsk.tailscaleCard(model.status, reading: reading))
        }
    }

    private var diskCard: some View {
        Section("Disk") {
            Group {
                OpsProbeHeader(title: "Free space", probe: model.status?.disk)
                if let d = model.status?.disk.detail {
                    ForEach(d.volumes ?? []) { v in
                        LabeledContent(v.path,
                                       value: "\(OpsFormat.bytes(v.freeBytes)) free of \(OpsFormat.bytes(v.totalBytes))")
                    }
                    LabeledContent("Artifacts",
                                   value: "\(OpsFormat.bytes(d.artifactsBytes)) in \(d.artifactsFiles ?? 0) files")
                    if d.artifactsComplete == false {
                        // A partial walk must say so rather than under-report the store as small.
                        Text("The artifact walk hit its entry ceiling, so that size is a floor, not a total.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .askable(OpsAsk.diskCard(model.status, reading: reading))
        }
    }

    private var gitCard: some View {
        Section("Git") {
            Group {
                OpsProbeHeader(title: "Vault", probe: model.status?.git)
                if let d = model.status?.git.detail {
                    LabeledContent("Branch", value: d.branch ?? "unknown")
                    LabeledContent("Ahead / behind",
                                   value: "\(d.ahead.map(String.init) ?? "?") / \(d.behind.map(String.init) ?? "?")")
                    LabeledContent("Working tree", value: (d.dirty ?? false) ? "dirty" : "clean")
                    LabeledContent("Index lock",
                                   value: d.indexLockAgeSecs.map { "\($0)s old" } ?? "none")
                    if let c = d.conflicts, !c.isEmpty {
                        LabeledContent("Conflicts", value: c.joined(separator: ", "))
                            .foregroundStyle(.red)
                    }
                    if let line = d.lastAutocommitLine?.line {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last autocommit").font(.caption).foregroundStyle(.secondary)
                            Text(line).font(.callout)
                            if d.lastAutocommitLine?.published == false {
                                Text("not published").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .askable(OpsAsk.gitCard(model.status, reading: reading))
        }
    }

    private var qmdCard: some View {
        Section("QMD") {
            Group {
                OpsProbeHeader(title: "Index", probe: model.status?.qmd)
                if let d = model.status?.qmd.detail {
                    if let node = d.nodeVersion { LabeledContent("Node", value: node) }
                    if let line = d.firstStderrLine, !line.isEmpty {
                        Text(line).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .askable(OpsAsk.qmdCard(model.status, reading: reading))
        }
    }

    private var watchdogCard: some View {
        Section("Watchdog") {
            Group {
                let w = model.status?.sentinel?.watchdog
                LabeledContent("Last tick",
                               value: OpsFormat.relative(fromMs: w?.lastTickMs) ?? "never")
                LabeledContent("Kickstarts (last hour)", value: String(w?.kickstartsLastHour ?? 0))
                if let gaveUp = w?.gaveUpMs {
                    // The single most important line on the page when it is set: the difference
                    // between "the bridge is down" and "the bridge is down AND nothing is trying to
                    // fix it any more".
                    Label("Gave up \(OpsFormat.relative(fromMs: gaveUp) ?? "") — nothing is trying to restart the bridge any more",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                if let e = w?.lastError, !e.isEmpty {
                    Text(e).font(.callout).foregroundStyle(.secondary)
                }
                if let s = model.status?.sentinel {
                    LabeledContent("Sentinel", value: s.version ?? "unknown")
                }
            }
            .askable(OpsAsk.watchdogCard(model.status, reading: reading))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Group {
                ForEach(OpsAction.allActions(labels: labelsBySlug), id: \.id) { action in
                    Button(action.buttonTitle) { pending = action }
                        .disabled(model.isRunningVerb)
                }
                if model.isRunningVerb {
                    HStack { ProgressView(); Text("Running…").foregroundStyle(.secondary) }
                }
                if let outcome = model.lastVerb {
                    Label {
                        Text("\(outcome.verb): \(outcome.detail)")
                    } icon: {
                        Image(systemName: outcome.succeeded
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(outcome.succeeded ? Color.secondary : Color.red)
                }
            }
            // ONE ask for the whole section rather than one per verb. A press asks about the
            // verbs on offer and the last outcome, which is the question ("what does reloading
            // the environment actually do") — and a `contextMenu` composes with the tap, so
            // every button still opens its confirmation dialog on a plain tap.
            .askable(OpsAsk.actionsSection(verbs: OpsAction.allActions(labels: labelsBySlug),
                                           last: model.lastVerb,
                                           isRunning: model.isRunningVerb,
                                           reading: reading))
        } header: {
            Text("Actions")
        } footer: {
            Text("Each of these acts on the Studio. Restarting the bridge drops any turn in flight; reloading its environment tears the launchd job down and boots it again, which is the only way a plist change takes effect.")
        }
    }

    /// The launchd label for each slot, taken from the status document so a confirmation can
    /// name the actual job rather than a slug the operator has never typed.
    private var labelsBySlug: [String: String] {
        var out: [String: String] = [:]
        for row in model.status?.serviceRows ?? [] { out[row.id] = row.label ?? row.id }
        return out
    }

    private func perform(_ action: OpsAction) async {
        switch action {
        case .restart(let service, _): await model.restart(service)
        case .reloadEnv: await model.reloadBridgeEnv()
        case .unlockGit: await model.unlockGit()
        case .prune: await model.pruneArtifacts()
        case .deploy(let sha): await model.deploy(sha: sha)
        }
    }

    // MARK: - Ledger

    private var ledgerSection: some View {
        Section {
            // A `label:` closure rather than `DisclosureGroup("Ledger")`, so the label itself
            // can carry the section's ask. The two spellings render identically, and the
            // disclosure still expands on a plain tap.
            DisclosureGroup(isExpanded: $showLedger) {
                let rows = model.status?.ledgerRows ?? []
                if rows.isEmpty {
                    Text("The scheduler has not written a ledger line yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    LedgerRowView(row: row, reading: reading)
                }
            } label: {
                Text("Ledger")
                    .askable(OpsAsk.ledgerSection(model.status?.ledgerRows ?? [],
                                                  reading: reading))
            }
        }
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section {
            NavigationLink {
                ScheduleView(configuration: model.configuration)
            } label: {
                Label("Schedule", systemImage: "calendar.badge.clock")
            }
        }
    }

    // MARK: - Deploy

    @ViewBuilder
    private var deployCard: some View {
        Section {
            if let doc = model.deploy {
                Group {
                    LabeledContent("Running",
                                   value: "\(doc.running.version ?? "unknown") · \(OpsFormat.shortSha(doc.running.sha))")
                    LabeledContent {
                        HStack(spacing: 6) {
                            HealthDot(doc.originMain.ciHealth)
                            Text("\(doc.originMain.version ?? "unknown") · \(OpsFormat.shortSha(doc.originMain.sha))")
                        }
                    } label: {
                        Text("origin/main")
                    }
                    if let detail = doc.originMain.ciDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if doc.originMain.isStale, let why = doc.originMain.staleReason {
                        Text("This view is stale: \(why)").font(.caption).foregroundStyle(.orange)
                    }
                }
                // The card's own ask, on the two version rows and the lines about them: this
                // is the press behind "what is running, and what is on origin/main". The
                // release blocks and the progress view below carry their own.
                .askable(OpsAsk.deployCard(model.deploy, reading: reading))

                if let releases = doc.releases { releaseNotes(releases) }


                let availability = DeployAvailability.decide(doc)
                Button("Deploy origin/main") {
                    if case .ready(let sha) = availability { pending = .deploy(sha: sha) }
                }
                .disabled(!availability.isReady || model.isRunningVerb)
                if let why = availability.reason {
                    // The refusal line IS the answer to "why can I not deploy", so it carries
                    // the card. The button itself is left untouched, so nothing can come
                    // between a press and its confirmation dialog.
                    Text(why).font(.caption).foregroundStyle(.secondary)
                        .askable(OpsAsk.deployCard(model.deploy, reading: reading))
                }

                if let record = doc.deploy {
                    DeployProgressView(record: record, reading: reading)
                }
            } else {
                Text("The sentinel has not answered the deploy card yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .askable(OpsAsk.deployCard(model.deploy, reading: reading))
            }
        } header: {
            Text("Deploy")
        } footer: {
            Text("A deploy builds the commit on the Studio, swaps the binaries, restarts the bridge, and rolls back if it does not come up. It is offered only when origin/main differs from what is running and CI is green on that commit.")
        }
    }
}

// MARK: - The action vocabulary

/// The eight verbs, as data. An enum rather than eight buttons with eight dialogs, so the
/// sentence a confirmation shows is derived from the verb once and cannot drift from the call
/// the button actually makes.
enum OpsAction: Equatable, Identifiable {
    /// The label rides along so the dialog can name the launchd job as an operator would type
    /// it, not the sentinel's slug for it.
    case restart(SentinelClient.Service, label: String)
    case reloadEnv
    case unlockGit
    case prune
    case deploy(sha: String)

    var id: String {
        switch self {
        case .restart(let s, _): return "restart-\(s.rawValue)"
        case .reloadEnv: return "reload-env"
        case .unlockGit: return "git-unlock"
        case .prune: return "prune"
        case .deploy(let sha): return "deploy-\(sha)"
        }
    }

    /// The order the buttons appear in: the bridge first because it is what the screen is
    /// usually opened for, the housekeeping last.
    static func allActions(labels: [String: String]) -> [OpsAction] {
        [
            .restart(.bridge, label: labels["bridge"] ?? "the bridge"),
            .reloadEnv,
            .restart(.autocommit, label: labels["autocommit"] ?? "the autocommit job"),
            .restart(.lockReaper, label: labels["lock-reaper"] ?? "the lock reaper"),
            .restart(.qmdUpdate, label: labels["qmd-update"] ?? "the QMD index job"),
            .unlockGit,
            .prune,
        ]
    }

    var buttonTitle: String {
        switch self {
        case .restart(let s, _): return "Restart \(s.label)"
        case .reloadEnv: return "Reload bridge env"
        case .unlockGit: return "Unlock git"
        case .prune: return "Prune artifacts"
        case .deploy(let sha): return "Deploy \(OpsFormat.shortSha(sha))"
        }
    }

    /// The dialog's title — the verb and the thing, spelled out.
    var title: String {
        switch self {
        case .restart(let s, let label): return "Restart \(s.label) (\(label))?"
        case .reloadEnv: return "Reload the bridge's environment?"
        case .unlockGit: return "Remove the git index lock?"
        case .prune: return "Prune artifacts older than a week?"
        case .deploy(let sha): return "Deploy \(OpsFormat.shortSha(sha))?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .restart(let s, _): return "Restart \(s.label)"
        case .reloadEnv: return "Reload"
        case .unlockGit: return "Unlock"
        case .prune: return "Prune"
        case .deploy: return "Deploy"
        }
    }

    var message: String {
        switch self {
        case .restart(.bridge, _):
            return "Any turn in flight is dropped. The sentinel waits for the bridge to come back and reports whether it is healthy and which version it is running."
        case .restart(let s, _):
            return "Kickstarts \(s.label) through launchd."
        case .reloadEnv:
            return "Tears the bridge's launchd job down and boots it again from its plist. This is the only way an environment change takes effect — a plain restart comes back with the old environment."
        case .unlockGit:
            return "Only removes the lock when it is old enough AND no git process is running. Either condition failing is refused with the reason."
        case .prune:
            return "Deletes artifact directories older than seven days. Anything still linked from a conversation older than that stops loading."
        case .deploy(let sha):
            return "Builds \(OpsFormat.shortSha(sha)) on the Studio, swaps the binaries and restarts the bridge. It rolls back on any failure, and it takes about twenty minutes."
        }
    }

    var isDestructive: Bool {
        switch self {
        case .restart(.bridge, _), .reloadEnv, .prune, .deploy: return true
        default: return false
        }
    }
}

// MARK: - Small pieces

/// The dot. Four states, and grey is not a shade of red: it means "not known", which is what a
/// timed-out probe reports and what an operator must be able to tell from a failure.
struct HealthDot: View {
    let health: OpsHealth

    init(_ health: OpsHealth) { self.health = health }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            // The one vocabulary for the four states, shared with the ask snapshots.
            .accessibilityLabel(health.word)
    }

    private var color: Color {
        switch health {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .grey: return .gray
        }
    }
}

/// A card's first row: the dot, the probe's name, and its error line when it has one.
struct OpsProbeHeader<Detail: Decodable & Sendable>: View {
    let title: String
    let probe: Probe<Detail>?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                HealthDot(probe?.health ?? .grey)
                Text(title)
                Spacer()
                Text(probe?.state.rawValue ?? "unknown")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = probe?.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One ledger line: when, which job, what happened, and why.
struct LedgerRowView: View {
    let row: LedgerRow
    let reading: OpsAskReading

    var body: some View {
        if let raw = row.raw {
            // A line the ledger could not parse is SHOWN, not dropped: a ledger emitting
            // garbage is a thing to see.
            Text(raw).font(.caption.monospaced()).foregroundStyle(.orange)
                .askable(OpsAsk.ledgerRow(row, reading: reading))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    HealthDot(OpsFormat.outcomeHealth(row.outcome))
                    Text(row.job ?? "—")
                    Spacer()
                    Text(row.outcome ?? "—")
                        .font(.callout)
                        .foregroundStyle(OpsFormat.outcomeHealth(row.outcome) == .red ? Color.red : Color.secondary)
                }
                // The phone's zone, because the person reading it is the phone's owner and the
                // question is "was that last night".
                Text(OpsFormat.inBothZones(row.atMs, bridgeTz: nil))
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = row.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .askable(OpsAsk.ledgerRow(row, reading: reading))
        }
    }
}

/// The in-flight (or just-finished) deploy: its phase, its log tail, and its verdict.
struct DeployProgressView: View {
    let record: DeployStatusDocument.DeployRecord
    let reading: OpsAskReading

    /// What the log tail's Copy item puts on the pasteboard — the whole tail as shown, or
    /// nil when there is no tail and so no menu item.
    ///
    /// A named property rather than an expression inline in the body, so the ONE thing a
    /// later edit could silently lose (see the note at the call site) is a value a test can
    /// read. `AskableTests` pins it.
    var logTailCopy: String? {
        record.logTail.isEmpty ? nil : record.logTail.joined(separator: "\n")
    }

    /// ONE menu for the whole row, and it is one deliberately.
    ///
    /// The phase line and the log tail sit in a single `List` row, and a row presents ONE
    /// context menu: two `.askable`s inside it — one on the phase lines, one on the tail —
    /// left whichever won without a Copy item, which is exactly the affordance rule one
    /// exists to protect. So the row is askable once, and it is the `copyText:` spelling
    /// whenever there is a tail.
    ///
    /// COPY IS PRESERVED HERE ON PURPOSE. This is the one view on the Ops screen with
    /// `.textSelection(.enabled)`, and attaching a `contextMenu` takes the system's
    /// press-and-hold selection — and its Copy callout — over. Do not drop the `copyText:`
    /// in a later edit, and do not add a second `.askable` anywhere in this row.
    var body: some View {
        if let copy = logTailCopy {
            rows.askable(OpsAsk.deployProgress(record, reading: reading), copyText: copy)
        } else {
            rows.askable(OpsAsk.deployProgress(record, reading: reading))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HealthDot(record.resultHealth)
                Text(record.inFlight ? "Phase: \(record.phase)" : (record.result ?? "finished"))
                if record.inFlight { ProgressView().controlSize(.small) }
            }
            if let reason = record.reason, !reason.isEmpty {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if let copy = logTailCopy {
                ScrollView {
                    Text(copy)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
    }
}
