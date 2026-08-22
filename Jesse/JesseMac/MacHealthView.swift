import SwiftUI
import SwiftData
import JesseCore
import JesseNetworking
import JesseDietDisplay

// The Mac's Health tab: the SAME diet/health dashboard the iPhone shows, rendered from
// the shared `HealthDashboardContent` (JesseDietDisplay) with a Mac-only chrome. It is
// fed entirely by the bridge (GET /jesse/diet through the Mac's own `JesseBridgeClient`,
// built from the same `MacConfigStore` host/token the Chats side already uses); there
// is NO HealthKit on the Mac; HealthKit is the iPhone's per-turn enrichment and meal
// write, neither of which the dashboard display needs.
//
// Everything the iPhone surfaces comes for free from the shared layer: today, day paging
// (back / forward / today), macro & micronutrient totals, trends, rings, insights, the
// old-bridge `historyUnsupported` banner, and the "couldn't refresh, showing the last
// update" stamp that never blanks a loaded screen. The Mac adds only a manual refresh.
struct MacHealthView: View {
    /// Opens the shared Settings scene (see `JesseMacApp`). The Health tab needs its own
    /// route because its empty state, when the bridge is unconfigured, tells the user to
    /// pair "in Settings" but has no button of its own (the shared `notConfigured` state
    /// deliberately shows no retry), and the Chats sidebar toolbar is a different tab. This
    /// is the "nowhere to log in" fix: a Settings button that is always present on the tab.
    @Environment(\.openSettings) private var openSettings
    // The Health tab needs a way to fire the morning refresh turn, like the Chats side.
    // The model container is applied at the WindowGroup, so both reach this tab.
    @Environment(MacCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context

    private let configStore: MacConfigStore
    @State private var model: HealthDashboardModel
    @State private var confirmNewDay = false

    /// The conversation an "Ask about this" opened.
    ///
    /// Presented MODALLY from this tab rather than selected in the Chats tab's sidebar,
    /// for the reason the Mac's Today tab already writes down: the two tabs are separate
    /// view trees and `MacRootView` owns its `selection` privately, so reaching across
    /// would mean lifting that binding into the shell and switching tabs under the user
    /// mid-gesture. The conversation is a real thread in the store, so it is in the
    /// sidebar afterwards either way.
    @State private var askThread: JesseThread?
    /// The thread an ask STAGED, remembered only so its attached context can be dropped if
    /// the sheet is closed without a send.
    @State private var stagedAskID: UUID?

    /// The Mac's reachability probe — the same shared model the phone drives, and the
    /// thing this tab previously had no version of.
    @State private var reachability = BridgeReachabilityModel()

    init(configStore: MacConfigStore) {
        self.configStore = configStore
        // The client is rebuilt from the store on every load, so re-pairing in Settings
        // is picked up on the next refresh (the same factory contract the iPhone uses).
        // It also carries the on-disk cache it writes; the model reads that cache at
        // launch, so a Mac opened with the Studio asleep still draws the last dashboard.
        _model = State(initialValue: HealthDashboardModel(makeClient: {
            JesseBridgeClient(config: configStore.config, snapshotCache: SnapshotCache.shared)
        }, cache: SnapshotCache.shared))
    }

    var body: some View {
        NavigationStack {
            HealthDashboardContent(model: model)
                // DECLARATION ORDER IS LEFT-TO-RIGHT, ordered by clicks per day. Refresh
                // is the cheap, safe, repeatable one and takes the rightmost slot, which
                // is the slot a mis-click lands in; "Start new day" runs for minutes and
                // rewrites the day file, so it sits inward, in the same position it holds
                // on the iPhone (there the rightmost item is quick log, which this shell
                // does not have); Settings is opened least often and is farthest inward.
                // See README, "UI conventions".
                .toolbar {
                    // Declared FIRST, so Ask sits leftmost — inward of Refresh, which is
                    // the cheap repeatable one that owns the rightmost slot. It is declared
                    // in the shell rather than inside the dashboard because a toolbar item
                    // declared on a child view lands AFTER the ones declared from outside,
                    // which would have put Ask in exactly that slot. Mirrors the phone.
                    // The context is built INSIDE the action — see the phone's note.
                    if model.snapshot != nil {
                        ToolbarItem {
                            Button {
                                if let ask = model.pageAskContext { openAsk(ask) }
                            } label: {
                                Label("Ask", systemImage: "text.bubble")
                            }
                            .help("Ask Jesse about this page")
                        }
                    }
                    ToolbarItem {
                        Button { openSettings() } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Pair with your bridge, or change the connection")
                    }
                    ToolbarItem {
                        Button { confirmNewDay = true } label: {
                            Label("Start new day", systemImage: "sun.horizon")
                        }
                        .help("Start a new health day")
                        // Disabled, not queued, while the bridge is unreachable: this
                        // fires a `.tell` turn, and a turn fired at nothing is a morning
                        // routine that looks started and never ran. The dashboard's
                        // offline strip says why.
                        .disabled(model.isReadOnly)
                    }
                    ToolbarItem {
                        Button { Task { await model.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh the day on screen")
                    }
                }
                // Every askable card, row and chart on the dashboard and its sub-pages
                // reaches the chat through this one injection — the environment carries it
                // down the whole navigation stack.
                .environment(\.healthAsk, HealthAskAction { openAsk($0) })
                .sheet(item: $askThread, onDismiss: dropUnsentAsk) { thread in
                    MacHealthAskSheet(thread: thread) { askThread = nil }
                }
                // A tap could kick off the long morning routine, so confirm first.
                .confirmationDialog("Start new day", isPresented: $confirmNewDay) {
                    Button("Start new day") { startNewDay() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Audit yesterday, log your weigh-in, and refresh the dashboard?")
                }
        }
        // A Mac that slept never leaves `.active`, so the scene phase alone would never
        // re-probe after a lid-open — see `MacWake`.
        .onReconnect {
            probe()
            Task { await model.load() }
        }
        .task { probe() }
        .onChange(of: reachability.state) { _, _ in applyReachability() }
    }

    // MARK: - Reachability

    private func probe() {
        reachability.refresh(config: configStore.config)
    }

    private func applyReachability() {
        model.isNetworkUnreachable = shouldShowOfflineBanner(
            isConfigured: configStore.isConfigured,
            reachability: reachability.state)
    }

    // MARK: - Ask about this

    /// Open the chat about whatever was right-clicked: today's conversation about that
    /// exact reading if there is one, else a fresh one carrying the snapshot.
    private func openAsk(_ ask: HealthAskContext) {
        let thread = MacHealthAskOpener.open(ask, coordinator: coordinator,
                                             modelContext: context)
        // Only a STAGED thread has an attachment worth dropping on dismissal.
        stagedAskID = thread.modelContext == nil ? thread.id : nil
        askThread = thread
    }

    /// Closing an ask without sending drops its context with it — a no-op once the first
    /// send has consumed it.
    private func dropUnsentAsk() {
        if let id = stagedAskID { coordinator.clearAttachedContext(for: id) }
        stagedAskID = nil
    }

    /// Fire the fixed morning refresh on a fresh Tell thread. The thread shows up in the
    /// Chats sidebar and the coordinator's `onTurnFinished` posts the completion
    /// notification when it lands; hit Refresh (or ⌘R) to repaint the dashboard. No tab
    /// switch.
    private func startNewDay() {
        guard !model.isReadOnly else { return }
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        try? context.save()
        Task { await coordinator.send(text: HealthNewDay.prompt, mode: .tell, thread: thread, context: context) }
    }
}


/// The conversation an ask opens, in a sheet sized like the Today tab's — one window
/// shape for "a conversation opened from a tab", not two.
private struct MacHealthAskSheet: View {
    let thread: JesseThread
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            MacThreadDetailView(thread: thread)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 620)
    }
}
