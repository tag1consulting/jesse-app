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
    @State private var model = HealthDashboardModel(makeClient: { JesseClient(config: ConfigStore.load()) })
    @State private var showQuickLog = false
    @State private var confirmNewDay = false

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
                    // Quick log and "Start new day" are both today-only (they act on
                    // today), so they're hidden while paging back through a past day.
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
                        }
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
                // A tap could kick off the long morning routine, so confirm first.
                .confirmationDialog("Start new day", isPresented: $confirmNewDay) {
                    Button("Start new day") { startNewDay() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Audit yesterday, log your weigh-in, and refresh the dashboard?")
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
        // Foregrounding is the third trigger, and the one that covers the overnight
        // case: parked on this tab, the app suspended, `.task` already fired and
        // `isActive` never changed — so without this the screen keeps rendering the
        // snapshot it loaded yesterday, meals and all, until a manual pull-to-refresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isActive { Task { await model.load() } }
        }
    }

    /// Fire the fixed morning refresh on a fresh Tell thread, then return — the
    /// long-running routine runs in the background and the after-turn refresh above
    /// repaints the dashboard when it lands. Mirrors the Quick log send path.
    private func startNewDay() {
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        coordinator.send(thread: thread, text: HealthNewDay.prompt, voice: false, context: context)
    }
}
