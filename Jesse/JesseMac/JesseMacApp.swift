import SwiftUI
import SwiftData
import JesseCore

// The macOS Jesse client — a thin native client that talks to the SAME bridge on the
// Studio the iPhone uses (see the JESSE-WRAP B3 plan). A SEPARATE app target from the
// iOS `Jesse` app: it shares the curated core in `JesseCore/` (the SwiftData models,
// schema, and `JesseMode`) but owns its SwiftUI shell, networking client, and config
// store. None of the iOS-only features (HealthKit, Siri, Live Activities, watch relay,
// camera) exist here — macOS has no HealthKit, and the phone stays the health feeder.

@main
struct JesseMacApp: App {
    @State private var configStore: MacConfigStore
    @State private var coordinator: MacCoordinator
    @State private var notifier = MacNotifier()
    @Environment(\.scenePhase) private var scenePhase

    /// Opened once at launch; `openFailure` is non-nil only on the in-memory fallback.
    private let store: (container: ModelContainer, openFailure: Error?)

    init() {
        let cfg = MacConfigStore()
        _configStore = State(initialValue: cfg)
        _coordinator = State(initialValue: MacCoordinator(configStore: cfg))
        store = MacModelContainer.open()
    }

    var body: some Scene {
        WindowGroup {
            MacShellView(storeError: store.openFailure)
                .environment(coordinator)
                .onAppear {
                    notifier.requestAuthorization()
                    coordinator.onTurnFinished = { thread, reply in
                        notifier.notifyTurnFinished(title: Self.notificationTitle(thread), reply: reply)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    notifier.isActive = (phase == .active)
                }
                .onOpenURL { url in
                    guard let p = MacPairLink.parse(url.absoluteString) else { return }
                    let (host, port) = JesseConfig.sanitize(p.host)
                    configStore.save(host: host, port: port ?? p.port, token: p.token)
                }
        }
        .defaultSize(width: 1000, height: 700)
        .modelContainer(store.container)

        // A first-class macOS Settings scene. This is what puts the standard "Settings…"
        // item in the app menu (with the system ⌘, shortcut) and makes bridge pairing
        // reachable from ANYWHERE: either tab, and crucially while the app is still
        // unconfigured. Without it there was no menu-bar Settings at all, so an unpaired or
        // migration-orphaned user had no way in: the Chats sidebar toolbar was the only
        // entry point, and it is useless from the Health tab or an empty window. The
        // in-window affordances (the sidebar gear, the empty-state button, the Health
        // toolbar button) all open THIS scene via `openSettings`, so there is one settings
        // surface, always available.
        Settings {
            MacSettingsView(configStore: configStore)
        }
    }

    private static func notificationTitle(_ thread: JesseThread) -> String {
        if let ai = thread.aiTitle, !ai.isEmpty { return ai }
        if !thread.title.isEmpty { return thread.title }
        return "Jesse replied"
    }
}
