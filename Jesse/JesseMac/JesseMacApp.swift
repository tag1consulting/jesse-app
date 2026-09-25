import SwiftUI
import SwiftData
import JesseCore
import JesseNetworking
import JesseOps
import JesseConversations
import JesseSpeech
import JesseTodayDisplay
import JesseVault

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
    /// The note a citation link in an offline answer asked for, shown as a sheet.
    @State private var citedNote: VaultNoteRoute?
    /// A `[[wiki link]]` tapped in a reply. Its own object because it has a step the
    /// citation does not: a target has to be resolved and may not be on this Mac.
    @State private var wiki = VaultWikiOpener()
    @Environment(\.scenePhase) private var scenePhase

    /// Opened once at launch; `openFailure` is non-nil only on the in-memory fallback.
    private let store: (container: ModelContainer, openFailure: Error?)

    init() {
        // Crash recovery for an interrupted transcription: the composer's scratch
        // directory holds nothing but working copies of recordings, and nothing is
        // legitimately in flight at launch. Same rule, same reasoning, as the phone's.
        RecordingWorkingCopy.standard().purge()

        let cfg = MacConfigStore()
        _configStore = State(initialValue: cfg)
        _coordinator = State(initialValue: MacCoordinator(configStore: cfg))
        store = MacModelContainer.open()

        // A tick of a strand step in the vault reader is reported to the bridge, the
        // phone's rule and the phone's reason; see `StrandTickReport`.
        Task {
            await StrandTickOutbox.shared.configure { @MainActor in
                JesseBridgeClient(config: cfg.config)
            }
            await StrandTickOutbox.shared.flush()
        }
    }

    var body: some Scene {
        WindowGroup {
            MacShellView(storeError: store.openFailure)
                .environment(coordinator)
                // Every vault reader in this window, the two note sheets below included,
                // gets the one thing it cannot own: a way to ask for a marked up note to be
                // reviewed. Injected here rather than inside `MacShellView` because those
                // two sheets are attached OUTSIDE it, and a sheet inherits the environment
                // of the view it is attached to.
                .environment(\.vaultReview, VaultReviewAction(
                    reachability: { MacCoordinator.reachabilityState() },
                    start: { sentence in startReview(sentence) }))
                .task {
                    // The draft store's launch chores, in order and before any composer
                    // can restore: move anything still in the V5 SwiftData columns into
                    // the file store (once, ever), then drop stored drafts for
                    // conversations that no longer exist — the backstop for a delete this
                    // store never saw, such as one that arrived from another device.
                    let context = store.container.mainContext
                    ComposerDraftMigration.runIfNeeded(context: context,
                                                       store: .shared)
                    if let live = try? context.fetch(FetchDescriptor<JesseThread>()) {
                        ComposerDraftStore.shared.sweep(keeping: Set(live.map(\.id)))
                    }
                }
                .onAppear {
                    notifier.requestAuthorization()
                    coordinator.onTurnFinished = { thread, reply in
                        notifier.notifyTurnFinished(title: Self.notificationTitle(thread), reply: reply)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    notifier.isActive = (phase == .active)
                    // No draft handling here. Only the composer knows what it is holding,
                    // so the scene-phase departure belongs to `MacThreadDetailView` and is
                    // wired there, beside the other three.
                }
                .onOpenURL { url in
                    // A citation in an offline answer opens the note it came from. Checked
                    // FIRST because it is the narrow shape (`jesse://note?path=…`) and the
                    // pairing parsers below are the broad ones.
                    if let route = VaultNoteRoute.parse(url) {
                        citedNote = route
                        return
                    }
                    // A `[[wiki link]]` in a reply, resolved against the copy of the
                    // vault on this Mac. Narrow shape too, and checked before the broad
                    // pairing parsers below.
                    if let route = VaultWikiRoute.parse(url) {
                        Task { await wiki.follow(route) }
                        return
                    }
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
                .sheet(item: $citedNote) { route in
                    NavigationStack {
                        VaultNoteStack(path: route.path, line: route.line) {
                            citedNote = nil
                        }
                    }
                    .frame(width: 620, height: 680)
                }
                // The SAME reader a citation opens: a link is a link.
                .sheet(item: $wiki.opened) { route in
                    NavigationStack {
                        VaultNoteStack(path: route.path, line: route.line) {
                            wiki.opened = nil
                        }
                    }
                    .frame(width: 620, height: 680)
                }
                .alert("Can't open that note",
                       isPresented: Binding(get: { wiki.missing != nil },
                                            set: { if !$0 { wiki.missing = nil } })) {
                    Button("OK", role: .cancel) { wiki.missing = nil }
                } message: {
                    Text(wiki.missing ?? "")
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
        //
        // The COORDINATOR and the MODEL CONTAINER are handed to each of these scenes
        // explicitly, because a `Window` scene inherits neither from the `WindowGroup`
        // above: "Ask about this" on an Ops card stages a real conversation in the store
        // and hands it to the coordinator, so both windows need both. `MacOpsWindowShell`
        // is where the stack, the ask injection and the ask's sheet live.
        Window("Bridge Ops", id: MacOpsWindow.ops) {
            MacOpsWindowShell { OpsView(configuration: configStore.opsConfiguration) }
                .frame(minWidth: 520, minHeight: 640)
                .environment(coordinator)
        }
        .defaultSize(width: 620, height: 760)
        .modelContainer(store.container)

        Window("Away Mode", id: MacOpsWindow.away) {
            MacOpsWindowShell { AwayModeView(configuration: configStore.opsConfiguration) }
                .frame(minWidth: 460, minHeight: 480)
                .environment(coordinator)
        }
        .defaultSize(width: 520, height: 560)
        .modelContainer(store.container)
    }

    /// Ask for a note's marks to be answered, on a conversation of its own.
    ///
    /// A TELL, and sent on the spot: the sentence is the whole request, and what it asks
    /// for is work on the vault rather than a discussion, which is why a Propagate is a
    /// Tell too. The shape is `MacTodayThreadOpener.run`'s, and for the same reason: a
    /// fresh thread per request, so one narrow turn cannot inherit another's context.
    ///
    /// Nothing is presented. The reader it was tapped in may itself be a sheet on this
    /// window, and the answer arrives in the sidebar like any other conversation's.
    private func startReview(_ sentence: String) {
        let context = store.container.mainContext
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        try? context.save()
        Task {
            await coordinator.send(text: sentence, mode: .tell, thread: thread,
                                   context: context)
        }
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
