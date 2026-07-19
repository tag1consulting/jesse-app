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

    /// Non-nil only when the on-disk conversation store couldn't be opened and the
    /// app is running on the in-memory fallback (see `AppModelStore`). When set, a
    /// persistent banner tells the user their saved history couldn't be opened and
    /// this session won't be saved — so a store failure is never silent.
    var storeError: Error?

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chats)

            HealthTabView(isActive: selection == .health)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag(Tab.health)
        }
        .safeAreaInset(edge: .top) {
            if storeError != nil {
                StoreErrorBanner()
            }
        }
    }
}

/// The visible flag for a failed store open. Deliberately non-dismissible: while
/// the app is on the in-memory fallback, nothing is being persisted, and the user
/// needs to know that for the whole session. It reassures that the on-disk data is
/// untouched (we never overwrite it) and that relaunching retries the real open.
struct StoreErrorBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t open your saved conversations")
                    .font(.footnote.weight(.semibold))
                Text("Your history is safe on disk and wasn’t changed. This session won’t be saved — reopen the app to try again.")
                    .font(.caption)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red, in: .rect)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RootTabView()
}

#Preview("Store error") {
    RootTabView(storeError: NSError(domain: "preview", code: 1))
}
