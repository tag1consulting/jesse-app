import SwiftUI
import SwiftData

// Thread history + concurrent threads. The thread list is the root; each thread
// is a SwiftData-persisted conversation. Runs are owned by an app-scoped
// RunCoordinator so they continue across navigation and many run at once.

@main
struct JesseApp: App {
    // Owns the remote-notification + tap callbacks (see PushManager.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The offline capture queue's replayer, held in a box because of the order things
    // are built in: the coordinator exists before any view does, and the replayer needs
    // the two dashboard models that `RootTabView` owns. See `IntentReplayerBox`.
    @State private var replayerBox: IntentReplayerBox

    // App-scoped so in-flight runs outlive the view that started them. The
    // first-successful-turn hook is the moment we ask for push authorization.
    @State private var coordinator: RunCoordinator

    // Both are built HERE rather than as property defaults, because the coordinator has
    // to be handed the SAME box the tab bar later fills — two separate defaults would
    // give it one nobody ever points at a replayer.
    init() {
        let box = IntentReplayerBox()
        _replayerBox = State(initialValue: box)
        _coordinator = State(initialValue: RunCoordinator(
            intentReplayer: box,
            onFirstSuccess: { PushManager.shared.noteSuccessfulTurn() }
        ))
    }

    // Opened once at launch. `openFailure` is non-nil only when the on-disk store
    // couldn't be opened and we're on the flagged in-memory fallback — surfaced to
    // the user rather than silently swallowed (see `AppModelStore`).
    private let store = AppModelContainer.shared

    var body: some Scene {
        WindowGroup {
            RootTabView(storeError: store.openFailure, replayerBox: replayerBox)
                .environment(coordinator)
                .task {
                    // Let the background worker reach the live coordinator, so a reply
                    // fetched while the app was in a pocket also clears the spinner and
                    // ends the Live Activity rather than waiting for the next foreground
                    // poll to discover it. A push can also launch the app straight into
                    // the background, where this never runs — which is why
                    // `BackgroundDelivery` works without a coordinator too.
                    AppDelegate.delivery.attach(coordinator: coordinator)
                }
        }
        .modelContainer(store.container)
    }
}
