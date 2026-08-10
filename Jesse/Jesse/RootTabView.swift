import SwiftUI
import JesseNetworking
import JesseTodayDisplay

// The app root: a three-tab shell. "Chats" hosts the existing conversation UI
// (`ContentView`) exactly as before — every Siri/push/voice entry point it owns
// keeps working, because the whole view (and its scene-phase + onChange handlers)
// lives inside the tab, which TabView keeps mounted. "Health" is the native diet
// dashboard; "Today" is the vault's day file. Wrapping (rather than restructuring)
// `ContentView` is the non-invasive path: nothing about the old root's behavior
// changes.
struct RootTabView: View {
    /// The tabs, as data. A `CaseIterable` enum the body ITERATES rather than a
    /// hand-written list of three `.tabItem`s: the set of tabs, their order, and
    /// their labels then have exactly one definition, which is also the one a test
    /// can assert against.
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case chats, health, today

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .health: return "Health"
            case .today: return "Today"
            }
        }

        /// `sun.max` for Today: it reads as "the day", and it collides with nothing
        /// on the bar (Chats is a speech bubble, Health a heart). It is deliberately
        /// NOT `sun.horizon`, which the day-file screen already uses for its own
        /// "the morning routine hasn't run yet" empty state and for the Health tab's
        /// Start-new-day button — a tab icon that also means "start the morning"
        /// would be one glyph carrying two claims.
        var systemImage: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .health: return "heart.text.square"
            case .today: return "sun.max"
            }
        }
    }

    @State private var selection: Tab = .chats

    /// The Today screen's model lives HERE, not in `TodayTabView`, because the tab
    /// item's badge and the screen must read the same number. Injected through the
    /// same narrow `TodayProviding` seam the Health tab uses for diet data — the
    /// shared `JesseBridgeClient`, rebuilt per call so a re-pairing is picked up.
    @State private var todayModel = TodayDashboardModel(
        makeClient: { JesseBridgeClient(config: ConfigStore.load()) })

    /// Non-nil only when the on-disk conversation store couldn't be opened and the
    /// app is running on the in-memory fallback (see `AppModelStore`). When set, a
    /// persistent banner tells the user their saved history couldn't be opened and
    /// this session won't be saved — so a store failure is never silent.
    var storeError: Error?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                view(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(badge(for: tab))
                    .tag(tab)
            }
        }
        .safeAreaInset(edge: .top) {
            if storeError != nil {
                StoreErrorBanner()
            }
        }
    }

    @ViewBuilder
    private func view(for tab: Tab) -> some View {
        switch tab {
        case .chats:
            ContentView()
        case .health:
            HealthTabView(isActive: selection == .health)
        case .today:
            TodayTabView(isActive: selection == .today, model: todayModel)
        }
    }

    /// Only Today carries a number, and the number is the semantics' — open Do Now
    /// work plus unseen briefing rows. `0` renders as no badge at all.
    private func badge(for tab: Tab) -> Int {
        tab == .today ? todayModel.tabBadgeCount : 0
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
