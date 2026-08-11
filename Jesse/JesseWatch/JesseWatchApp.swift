import SwiftUI
import WatchKit

// The Jesse Watch App entry point. Wires the real recorder, WatchConnectivity
// client, and speaker into the talk model, and activates the session at launch so
// replies can arrive in the background.
//
// TWO PAGES, one session. Talk leads — it is what the watch app was built for and
// what a raised wrist most often wants — and Today is one swipe away. Both are fed
// by the same `WatchConnectivityClient`, which is the app's only link to anything:
// the watch never talks to the bridge and holds no auth token, so a page that wants
// data gets it from the phone or does without.

@main
struct JesseWatchApp: App {
    @State private var talk: WatchTalkModel = {
        // Activated here, before either model is built, because activation also
        // replays the retained application context — so the Today page has the day
        // in hand on the first frame instead of showing its empty state and then
        // filling in.
        WatchConnectivityClient.shared.activate()
        return WatchTalkModel(
            recorder: WatchAudioRecorder(),
            sender: WatchConnectivityClient.shared,
            speaker: WatchSpeaker(),
            haptic: { WKInterfaceDevice.current().play(.notification) })
    }()

    @State private var today = WatchTodayModel(sender: WatchConnectivityClient.shared)

    var body: some Scene {
        WindowGroup {
            TabView {
                WatchContentView(model: talk)
                NavigationStack { WatchTodayView(model: today) }
            }
        }
    }
}
