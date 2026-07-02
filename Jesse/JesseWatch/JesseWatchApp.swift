import SwiftUI
import WatchKit

// The Jesse Watch App entry point. Wires the real recorder, WatchConnectivity
// client, and speaker into the talk model, and activates the session at launch so
// replies can arrive in the background.

@main
struct JesseWatchApp: App {
    @State private var model: WatchTalkModel = {
        WatchConnectivityClient.shared.activate()
        return WatchTalkModel(
            recorder: WatchAudioRecorder(),
            sender: WatchConnectivityClient.shared,
            speaker: WatchSpeaker(),
            haptic: { WKInterfaceDevice.current().play(.notification) })
    }()

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
        }
    }
}
