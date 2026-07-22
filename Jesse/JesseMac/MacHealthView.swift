import SwiftUI
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

    private let configStore: MacConfigStore
    @State private var model: HealthDashboardModel

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
                .toolbar {
                    ToolbarItem {
                        Button { Task { await model.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh the day on screen")
                    }
                    ToolbarItem {
                        Button { openSettings() } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Pair with your bridge, or change the connection")
                    }
                }
        }
    }
}
