import SwiftUI

// The app root: a two-tab shell. "Chats" hosts the existing conversation UI
// (`ContentView`) exactly as before — every Siri/push/voice entry point it owns
// keeps working, because the whole view (and its scene-phase + onChange handlers)
// lives inside the tab, which TabView keeps mounted. "Health" is the new native
// diet dashboard. Wrapping (rather than restructuring) `ContentView` is the
// non-invasive path: nothing about the old root's behavior changes.
struct RootTabView: View {
    enum Tab: Hashable { case chats, health }
    @State private var selection: Tab = .chats

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chats)

            HealthTabView(isActive: selection == .health)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag(Tab.health)
        }
    }
}

#Preview {
    RootTabView()
}
