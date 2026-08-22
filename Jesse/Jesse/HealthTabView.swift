import SwiftUI
import SwiftData
import JesseCore
import JesseDietDisplay

// The iOS Health tab: a thin shell around the SHARED dashboard (`HealthDashboardContent`
// in JesseDietDisplay, rendered identically on the Mac). Everything platform-specific
// stays here: the quick-log affordance that opens a Tell turn through `RunCoordinator`,
// and the after-turn refresh gated on this tab being active. The dashboard render, the
// paging, the model, and the semantics live in the package so iOS and macOS share one
// source; the Mac shell has no RunCoordinator and no quick log.

struct HealthTabView: View {
    /// Whether the Health tab is the selected tab; gates the after-turn refresh so
    /// a background turn doesn't refetch while the user is in Chats.
    let isActive: Bool

    @Environment(RunCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    // The display model fetches through the narrow `DietSnapshotProviding` seam; iOS
    // injects its own `JesseClient` (which layers per-turn health context on top),
    // preserving the exact client the tab used before the display layer moved out.
    @State private var model = HealthDashboardModel(
        makeClient: { JesseClient(config: ConfigStore.load(), snapshotCache: SnapshotCache.shared) },
        cache: SnapshotCache.shared)
    @State private var showQuickLog = false
    @State private var confirmNewDay = false

    /// The conversation an "Ask about this" opened.
    ///
    /// Presented MODALLY from this tab rather than pushed into the Chats stack, for the
    /// reasons the Today tab already writes down: there is no precedent for one tab
    /// driving another's navigation, `ContentView` owns its `path` privately (and in two
    /// different shapes on iPhone and iPad), and a sheet keeps the user where they were —
    /// dismissing it returns them to the card they pressed.
    @State private var askThread: JesseThread?
    /// The thread an ask STAGED, remembered only so its attached context can be dropped if
    /// the sheet is dismissed without a send. `.sheet(item:)` nils its binding before
    /// calling `onDismiss`, so the id has to be held separately.
    @State private var stagedAskID: UUID?

    /// The same probe the Today tab and the Chats list use, asked here so the dashboard
    /// goes read-only BEFORE a tap rather than after a turn is fired into a void.
    @State private var reachability = BridgeReachabilityModel()

    var body: some View {
        NavigationStack {
            HealthDashboardContent(model: model)
                // DECLARATION ORDER IS LEFT-TO-RIGHT, and the trailing items are ordered
                // by how often they are tapped: quick log runs several times a day and is
                // cheap and repeatable, so it is declared LAST and sits farthest right.
                // "Start new day" fires once a day, runs for minutes and rewrites the day
                // file, so it moves inward and away from the mis-tap slot. See README,
                // "UI conventions".
                .toolbar {
                    // "Ask" is declared FIRST, so it sits innermost — farthest from the
                    // rightmost slot a mis-tap lands in, which belongs to quick log. It is
                    // declared HERE rather than inside the dashboard because a toolbar item
                    // declared on a child view lands AFTER the ones declared on it from
                    // outside, which would have put Ask in exactly that slot. See README,
                    // "UI conventions", and `HealthDashboardModel.pageAskContext`.
                    //
                    // Present on every day, past or live: reading a past day is precisely
                    // when a question comes up, and an ask starts no turn and writes
                    // nothing, so it is not gated on reachability either — the composer it
                    // opens is the one screen with a visible outbox and a per-message Retry.
                    //
                    // The context is built INSIDE the action, not beside the label: a
                    // page context is the union of every section on the day, and building
                    // one on every render of a screen nobody has asked about yet is work
                    // for nothing. The button's presence is gated on the cheap question
                    // (is anything loaded?) instead.
                    if model.snapshot != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                if let ask = model.pageAskContext { openAsk(ask) }
                            } label: {
                                Image(systemName: "text.bubble")
                            }
                            .accessibilityLabel("Ask about this page")
                        }
                    }
                    // Quick log and "Start new day" are both today-only (they act on
                    // today), so they're hidden while paging back through a past day.
                    //
                    // Both are DISABLED, not queued, while the bridge is unreachable.
                    // Each fires a fresh `.tell` turn on a thread this tab never
                    // navigates to, so a failure offline lands as a `.failed` outbox row
                    // carrying a manual Retry the user is never shown — a log that looks
                    // sent and is not. The offline strip on the dashboard says why. See
                    // the CHANGELOG entry for why the chat outbox is not reused here.
                    if HistoryUI.showsQuickLog(isHistorical: model.snapshot?.isHistorical ?? false) {
                        // BOTH items must be `.primaryAction`. `.secondaryAction` (which
                        // this one shipped as) does NOT mean "the second button" on iOS:
                        // UIKit collapses secondary items into a "More" overflow ellipsis.
                        // Worse, an overflow item declared inside a conditional like this
                        // `if` gets an EMPTY menu, and UIKit won't present an empty menu,
                        // so the ellipsis rendered but was inert: no icon, no confirmation,
                        // while the Mac (plain `ToolbarItem`, no conditional) was fine.
                        ToolbarItem(placement: .primaryAction) {
                            Button { confirmNewDay = true } label: { Image(systemName: "sun.horizon") }
                                .accessibilityLabel("Start new day")
                                .disabled(model.isReadOnly)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { showQuickLog = true } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Quick log")
                                .disabled(model.isReadOnly)
                        }
                    }
                }
                .sheet(item: $askThread, onDismiss: dropUnsentAsk) { thread in
                    // `hidesTabBar: false`: a sheet already covers the tab bar, and asking
                    // the detail view to hide it would leave it hidden after dismissal.
                    NavigationStack { ThreadDetailView(thread: thread, hidesTabBar: false) }
                }
                .sheet(isPresented: $showQuickLog) {
                    QuickLogSheet { text in
                        // Belt and braces with the disabled button above: the sheet may
                        // have been opened while the bridge was still reachable.
                        guard !model.isReadOnly else { return }
                        let thread = JesseThread(mode: .tell)
                        context.insert(thread)
                        coordinator.send(thread: thread, text: text, voice: false, context: context)
                    }
                }
                // A tap could kick off the long morning routine, so confirm first.
                .confirmationDialog("Start new day", isPresented: $confirmNewDay) {
                    Button("Start new day") { startNewDay() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Audit yesterday, log your weigh-in, and refresh the dashboard?")
                }
        }
        // Every askable card, row and chart on the dashboard AND ON ITS PUSHED SUB-PAGES
        // reaches the chat through this one injection.
        //
        // It sits on the NavigationStack rather than on its root content, and that is the
        // whole point: a view pushed by a `NavigationLink` is presented BY the stack, not
        // rendered as a child of the root, so an environment value attached to the root
        // does not reliably reach it. Attached here it covers the root and every
        // destination alike — Macros & calories, Food journal, Exercise, the charts, and
        // anything pushed later.
        .environment(\.healthAsk, HealthAskAction { openAsk($0) })
        // Load-on-appear lives in the shared `HealthDashboardContent`; the shell adds
        // only the iOS-specific after-turn and tab-activation refresh triggers.
        .onChange(of: coordinator.inFlight.count) { old, new in
            // A turn settled (inFlight shrank) while this tab is up, so refetch so a
            // just-logged meal/weigh-in is reflected.
            if new < old && isActive { Task { await model.load() } }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            probe()
            Task { await model.load() }
        }
        // Foregrounding is the third trigger, and the one that covers the overnight
        // case: parked on this tab, the app suspended, `.task` already fired and
        // `isActive` never changed — so without this the screen keeps rendering the
        // snapshot it loaded yesterday, meals and all, until a manual pull-to-refresh.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isActive else { return }
            probe()
            Task { await model.load() }
        }
        .task { probe() }
        .onChange(of: reachability.state) { _, _ in applyReachability() }
    }

    // MARK: - Reachability

    private func probe() {
        reachability.refresh(config: ConfigStore.load())
    }

    /// Feed the probe's answer to the model, which is what turns the two turn actions
    /// off and the offline strip on. Same gate as every other screen's banner: an
    /// UNPAIRED app is not offline, it is unconfigured, and the pairing empty state
    /// covers that.
    private func applyReachability() {
        model.isNetworkUnreachable = shouldShowOfflineBanner(
            isConfigured: ConfigStore.load().isConfigured,
            reachability: reachability.state)
    }

    // MARK: - Ask about this

    /// Open the chat about whatever was pressed: today's conversation about that exact
    /// reading if there is one, else a fresh one carrying the snapshot.
    private func openAsk(_ context: HealthAskContext) {
        let thread = HealthAskOpener.open(context, coordinator: coordinator,
                                          modelContext: self.context)
        // Only a STAGED thread has an attachment worth dropping on dismissal; a resumed
        // one is already in the store and its re-attachment is spent by the next send.
        stagedAskID = thread.modelContext == nil ? thread.id : nil
        askThread = thread
    }

    /// Dismissing an ask without sending drops its context with it — a no-op once the
    /// first send has consumed it.
    private func dropUnsentAsk() {
        if let id = stagedAskID { coordinator.clearAttachedContext(for: id) }
        stagedAskID = nil
    }

    /// Fire the fixed morning refresh on a fresh Tell thread, then return — the
    /// long-running routine runs in the background and the after-turn refresh above
    /// repaints the dashboard when it lands. Mirrors the Quick log send path.
    private func startNewDay() {
        guard !model.isReadOnly else { return }
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        coordinator.send(thread: thread, text: HealthNewDay.prompt, voice: false, context: context)
    }
}
