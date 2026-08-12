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

    init(configStore: MacConfigStore) {
        self.configStore = configStore
        // The client is rebuilt from the store on every load, so re-pairing in Settings
        // is picked up on the next refresh (the same factory contract the iPhone uses).
        _model = State(initialValue: HealthDashboardModel(makeClient: {
            JesseBridgeClient(config: configStore.config)
        }))
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
                    }
                    ToolbarItem {
                        Button { Task { await model.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh the day on screen")
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
    }

    /// Fire the fixed morning refresh on a fresh Tell thread. The thread shows up in the
    /// Chats sidebar and the coordinator's `onTurnFinished` posts the completion
    /// notification when it lands; hit Refresh (or ⌘R) to repaint the dashboard. No tab
    /// switch.
    private func startNewDay() {
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        try? context.save()
        Task { await coordinator.send(text: HealthNewDay.prompt, mode: .tell, thread: thread, context: context) }
    }
}
