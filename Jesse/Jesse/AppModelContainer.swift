import Foundation
import SwiftData

// One shared SwiftData container for the whole app process. Both the SwiftUI view
// tree (`JesseApp`) and the background watch-relay path
// (`PhoneWatchConnectivity`) resolve their `ModelContext` from THIS container, so a
// turn relayed from the watch lands in the same store the thread list observes —
// not a second container over the same file whose changes the UI wouldn't see.

enum AppModelContainer {
    /// The app's persistent store. Falls back to an in-memory store (with a loud log)
    /// if the on-disk store can't be opened, so a provisioning hiccup degrades to a
    /// non-persisting session rather than a crash.
    static let shared: ModelContainer = {
        if let container = try? ModelContainer(for: JesseThread.self, Turn.self) {
            return container
        }
        Log.run.error("persistent SwiftData store unavailable — falling back to in-memory (history won't persist this session)")
        if let memory = try? ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
            return memory
        }
        // Even an in-memory store failed — the app cannot function without a store.
        preconditionFailure("could not create any SwiftData container")
    }()
}
