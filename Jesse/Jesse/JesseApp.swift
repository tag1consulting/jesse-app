import SwiftUI
import SwiftData

// Thread history + concurrent threads. The thread list is the root; each thread
// is a SwiftData-persisted conversation. Runs are owned by an app-scoped
// RunCoordinator so they continue across navigation and many run at once.

@main
struct JesseApp: App {
    // App-scoped so in-flight runs outlive the view that started them.
    @State private var coordinator = RunCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
        }
        .modelContainer(for: [JesseThread.self, Turn.self])
    }
}
