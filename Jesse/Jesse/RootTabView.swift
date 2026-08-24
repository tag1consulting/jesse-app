import SwiftUI
import SwiftData
import JesseCore
import JesseDietDisplay
import JesseNetworking
import JesseTodayDisplay

// The app root: a three-tab shell. "Chats" leads and hosts the existing conversation
// UI (`ContentView`) exactly as before — every Siri/push/voice entry point it owns
// keeps working, because the whole view (and its scene-phase + onChange handlers)
// lives inside the tab, which TabView keeps mounted. "Today" is the vault's day file,
// one tap away and carrying the only badge on the bar. "Health" is the native diet
// dashboard. Wrapping (rather than restructuring) `ContentView` is the non-invasive
// path: nothing about the old root's behavior changes.
struct RootTabView: View {
    /// The tabs, as data. A `CaseIterable` enum the body ITERATES rather than a
    /// hand-written list of three `.tabItem`s: the set of tabs, their order, and
    /// their labels then have exactly one definition, which is also the one a test
    /// can assert against.
    ///
    /// CASE ORDER IS BAR ORDER. The body iterates `allCases`, so moving a case moves
    /// the tab, and there is no second list to keep in step.
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case chats, today, health

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .health: return "Health"
            case .today: return "Today"
            }
        }

        /// `sunrise` for Today, replacing the flat `sun.max` that used to sit here.
        ///
        /// The old comment reserved `sun.horizon` for the idea of starting the
        /// morning, on the grounds that a tab icon should not also mean "run the
        /// morning routine". That reservation is void: the Today tab IS where the day
        /// gets started — it is the day's work and the entry point to it — so the
        /// glyph should say so rather than say "daytime". It still collides with
        /// nothing on the bar, because Chats is a speech bubble and Health a heart.
        ///
        /// It does share its meaning with the day screen's "no day file yet" empty
        /// state and with the Health tab's Start-new-day button, and that is the
        /// point rather than an oversight: all three are about the beginning of the
        /// day, and one glyph carrying one claim in three places is what a symbol is
        /// for.
        var systemImage: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .health: return "heart.text.square"
            case .today: return "sunrise"
            }
        }
    }

    /// What the app launches on. Chats: the conversation is what the app is opened
    /// FOR most of the time — a question, a log, a dictated note — and the day is one
    /// tap away with a badge that says whether it wants attention, which a landing
    /// tab cannot say about itself. Named rather than written inline so the launch
    /// tab and the bar's leading tab stay one decision a test can hold to
    /// (`Tab.allCases.first`).
    static let defaultTab: Tab = .chats

    @State private var selection: Tab = RootTabView.defaultTab

    /// The app-scoped coordinator, read here only to build the replayer's Tell sender.
    @Environment(RunCoordinator.self) private var coordinator

    /// The Today screen's model lives HERE, not in `TodayTabView`, because the tab
    /// item's badge and the screen must read the same number. Injected through the
    /// same narrow `TodayProviding` seam the Health tab uses for diet data — the
    /// shared `JesseBridgeClient`, rebuilt per call so a re-pairing is picked up.
    /// The client CARRIES the cache (it holds the bridge's own response bytes, so it is
    /// where a successful read is written) and the model READS it (at launch, before any
    /// network call). Two halves of one feature, wired at the one place that owns the
    /// day model — see `SnapshotCache`.
    @State private var todayModel = TodayDashboardModel(
        makeClient: {
            JesseBridgeClient(config: ConfigStore.load(), snapshotCache: SnapshotCache.shared)
        },
        cache: SnapshotCache.shared,
        pending: RootTabView.pendingStore)

    /// **The offline capture queue**, one per process.
    ///
    /// One store, shared by both tabs and the replayer, because it is one queue: the
    /// Today tab shows its day-file half, the Health tab its diet half, and the replayer
    /// drains the whole thing oldest-first. Two stores would mean two replay runs racing
    /// each other's ETags.
    ///
    /// It runs on its OWN `ModelContext` over the app's shared container, not on the
    /// view's `@Environment(\.modelContext)`, for the same reason `PhoneWatchConnectivity`
    /// resolves its own: this store is written from a Siri intent and from a watch
    /// message, neither of which has a view hierarchy to read one from.
    @MainActor static let pendingStore = PendingIntentStore(
        context: ModelContext(AppModelContainer.shared.container))

    /// The replayer, built once the two models exist and handed to the box the
    /// coordinator already holds.
    @State private var replayer: IntentReplayer?

    /// The Health tab's model. It lives HERE rather than in `HealthTabView` for the one
    /// reason the day model does: the replayer needs it (to read the live diet day) and
    /// the replayer must outlive whichever tab happens to be on screen.
    @State private var healthModel = HealthDashboardModel(
        makeClient: { JesseClient(config: ConfigStore.load(), snapshotCache: SnapshotCache.shared) },
        cache: SnapshotCache.shared,
        pending: RootTabView.pendingStore)

    /// The wrist's half of the day, built the first time this view appears.
    ///
    /// It lives HERE for the same reason `todayModel` does: there must be exactly one
    /// day model, and the watch has to write through it rather than around it. Built
    /// in `.task` rather than as an initialized `@State` because it needs
    /// `todayModel`, and one `@State` cannot be initialized from another.
    @State private var watchLink: TodayWatchLink?

    /// Non-nil only when the on-disk conversation store couldn't be opened and the
    /// app is running on the in-memory fallback (see `AppModelStore`). When set, a
    /// persistent banner tells the user their saved history couldn't be opened and
    /// this session won't be saved — so a store failure is never silent.
    var storeError: Error?

    /// The box `RunCoordinator` already holds. Filled here, on the first appearance,
    /// because this is the first moment both dashboard models exist.
    var replayerBox: IntentReplayerBox?

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
        .task {
            // The badge is read from every tab, so the day has to be restored at LAUNCH
            // rather than when the Today tab is first opened — otherwise a cold launch
            // with no network shows a badge of zero for a day the device already has.
            // A no-op once anything has loaded, so it cannot fight a live fetch.
            todayModel.primeFromCache()
            connectTheWatch()
            buildTheReplayer()
            todayModel.refreshPending()
            healthModel.refreshPending()
        }
        // EVERY successful fetch and every mutation lands a new server snapshot, and
        // each one is pushed. Not gated on the Today tab being selected: the wrist's
        // list has to be right whichever tab the phone happens to be showing, and a
        // context push is a dictionary written to a mailbox, not a network call.
        .onChange(of: todayModel.serverSnapshot) { _, _ in
            watchLink?.pushCurrent()
            // A fetch that produced a document is the strongest evidence there is that
            // the bridge is reachable — better than the probe, and earlier than the next
            // path event. It is one of the four replay triggers for that reason.
            if !todayModel.isReadOnly { replayNow() }
        }
    }

    /// Build the wrist link once and point the WatchConnectivity delegate at it.
    ///
    /// The delegate is an app-lifetime singleton created at launch, long before this
    /// view exists, so the wiring is done from here — the one place that holds the
    /// day model the wrist must write through.
    /// Build the replayer and point the coordinator's box at it.
    ///
    /// It is built HERE, and not in `JesseApp`, because it needs both dashboard models —
    /// the day model to write through and the diet model to read the live diet day from —
    /// and this view is the one place that owns both.
    private func buildTheReplayer() {
        guard replayer == nil, let replayerBox else { return }
        let built = IntentReplayer(
            store: Self.pendingStore,
            day: todayModel,
            makeClient: { JesseBridgeClient(config: ConfigStore.load(),
                                            snapshotCache: SnapshotCache.shared) },
            tell: CoordinatorTellSender(coordinator: coordinator,
                                        context: AppModelContextProvider()),
            dietDay: { healthModel.captureDay })
        replayer = built
        replayerBox.adopt(built)
    }

    /// Drain the queue now and repaint both tabs. Called on the two triggers this view
    /// owns — a fetch that proved the bridge is back, and a per-row Retry — while the
    /// path-satisfied event and the background task reach the same replayer through the
    /// coordinator's box.
    private func replayNow() {
        guard let replayer, !replayer.isReplaying else { return }
        Task {
            await replayer.replayAll()
            todayModel.refreshPending()
            healthModel.refreshPending()
        }
    }

    private func connectTheWatch() {
        guard watchLink == nil else { return }
        let link = TodayWatchLink(model: todayModel,
                                  pending: Self.pendingStore,
                                  push: { PhoneWatchConnectivity.shared.pushToday($0) })
        watchLink = link
        PhoneWatchConnectivity.shared.onTodayCheck = { check in
            Task { await link.apply(check) }
        }
        // A watch that has been waiting since before this launch gets the day as soon
        // as there is one; if nothing is loaded yet this is a no-op and the `onChange`
        // above covers the first fetch.
        link.pushCurrent()
    }

    @ViewBuilder
    private func view(for tab: Tab) -> some View {
        switch tab {
        case .chats:
            ContentView()
        case .health:
            HealthTabView(isActive: selection == .health, model: healthModel,
                          onReplay: replayNow)
        case .today:
            TodayTabView(isActive: selection == .today, model: todayModel,
                         onReplay: replayNow)
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
        .environment(RunCoordinator())
}

#Preview("Store error") {
    RootTabView(storeError: NSError(domain: "preview", code: 1))
        .environment(RunCoordinator())
}
