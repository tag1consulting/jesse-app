import SwiftUI
import SwiftData
import JesseCore
import JesseOps
import JesseConversations

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
                    // One payload, both halves. The three sentinel keys are ADDITIVE, so a
                    // link from a bridge with no sentinel pairs the bridge and leaves any
                    // sentinel this Mac already has alone.
                    if let payload = PairingPayload.parse(url.absoluteString) {
                        configStore.applyPairing(payload)
                    } else if let p = MacPairLink.parse(url.absoluteString) {
                        // The Mac's own `?url=` spelling, which the bridge never emits but a
                        // hand-written link may.
                        let (host, port) = JesseConfig.sanitize(p.host)
                        configStore.save(host: host, port: port ?? p.port, token: p.token)
                    }
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
        .commands {
            // A menu of its own rather than two more items under an existing one: these are
            // the only commands in the app that act on the MACHINE rather than on a
            // conversation, and burying them under File would read as a document action.
            CommandMenu("Ops") { OpsMenuItems() }
        }

        Settings {
            MacSettingsView(configStore: configStore)
        }

        // The two operations screens, as windows. They are shared with iOS
        // (`JesseOps.OpsView` / `JesseOps.AwayModeView`); the Mac contributes the window,
        // the stack, and the two configs — no second implementation of anything.
        Window("Bridge Ops", id: MacOpsWindow.ops) {
            NavigationStack { OpsView(configuration: configStore.opsConfiguration) }
                .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 620, height: 760)

        Window("Away Mode", id: MacOpsWindow.away) {
            NavigationStack { AwayModeView(configuration: configStore.opsConfiguration) }
                .frame(minWidth: 460, minHeight: 480)
        }
        .defaultSize(width: 520, height: 560)
    }

    /// The reply notification's title. The shared resolution, with this surface's own
    /// wording for a thread that has no name yet: a notification banner saying "New
    /// conversation" names nothing, where "Jesse replied" at least says what happened.
    private static func notificationTitle(_ thread: JesseThread) -> String {
        displayTitle(for: thread, placeholder: "Jesse replied")
    }
}

/// The two operations windows' scene ids. Named here rather than spelled at each call site:
/// `openWindow(id:)` takes a string, and a typo in one of the three places that opens these
/// is a menu item that silently does nothing.
enum MacOpsWindow {
    static let ops = "jesse.ops"
    static let away = "jesse.away"
}

/// The two items under the "Ops" menu.
///
/// A VIEW rather than two `Button`s written inline, because `openWindow` is a view
/// environment value: a `Commands` body cannot read it, and the only way to open a scene by
/// id from a menu is to let a view do it.
private struct OpsMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Bridge Ops…") { openWindow(id: MacOpsWindow.ops) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Away Mode…") { openWindow(id: MacOpsWindow.away) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}
