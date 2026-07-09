import SwiftUI
import SwiftData

// Thread history + concurrent threads. The thread list is the root; each thread
// is a SwiftData-persisted conversation. Runs are owned by an app-scoped
// RunCoordinator so they continue across navigation and many run at once.

@main
struct JesseApp: App {
    // Owns the remote-notification + tap callbacks (see PushManager.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // App-scoped so in-flight runs outlive the view that started them. The
    // first-successful-turn hook is the moment we ask for push authorization.
    @State private var coordinator = RunCoordinator(
        onFirstSuccess: { PushManager.shared.noteSuccessfulTurn() }
    )

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(coordinator)
        }
        .modelContainer(AppModelContainer.shared)
    }
}
