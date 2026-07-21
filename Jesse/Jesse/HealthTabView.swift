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
    @Environment(\.modelContext) private var context
    // The display model fetches through the narrow `DietSnapshotProviding` seam; iOS
    // injects its own `JesseClient` (which layers per-turn health context on top),
    // preserving the exact client the tab used before the display layer moved out.
    @State private var model = HealthDashboardModel(makeClient: { JesseClient(config: ConfigStore.load()) })
    @State private var showQuickLog = false

    var body: some View {
        NavigationStack {
            HealthDashboardContent(model: model)
                .toolbar {
                    // Quick log is today-only (the logging path only logs today), so
                    // it's hidden while paging back through a past day.
                    if HistoryUI.showsQuickLog(isHistorical: model.snapshot?.isHistorical ?? false) {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showQuickLog = true } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Quick log")
                        }
                    }
                }
                .sheet(isPresented: $showQuickLog) {
                    QuickLogSheet { text in
                        let thread = JesseThread(mode: .tell)
                        context.insert(thread)
                        coordinator.send(thread: thread, text: text, voice: false, context: context)
                    }
                }
        }
        // Load-on-appear lives in the shared `HealthDashboardContent`; the shell adds
        // only the iOS-specific after-turn and tab-activation refresh triggers.
        .onChange(of: coordinator.inFlight.count) { old, new in
            // A turn settled (inFlight shrank) while this tab is up, so refetch so a
            // just-logged meal/weigh-in is reflected.
            if new < old && isActive { Task { await model.load() } }
        }
        .onChange(of: isActive) { _, active in
            if active { Task { await model.load() } }
        }
    }
}
