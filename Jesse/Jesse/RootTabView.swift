import SwiftUI
import SwiftData
import UserNotifications
import JesseCore
import JesseDietDisplay
import JesseNetworking
import JesseSearch
import JesseTodayDisplay
import JesseVault

// The app root: a four-tab shell. "Chats" leads and hosts the existing conversation
// UI (`ContentView`) exactly as before — every Siri/push/voice entry point it owns
// keeps working, because the whole view (and its scene-phase + onChange handlers)
// lives inside the tab, which TabView keeps mounted. "Today" is the vault's day file,
// one tap away. "Health" is the native diet dashboard. "Vault" is every note on this
// device, searchable with the bridge off. Wrapping (rather than restructuring)
// `ContentView` is the non-invasive path: nothing about the old root's behavior changes.
//
// TWO tabs carry a badge, and they count different things: Today's is open Do Now work
// plus unseen briefing rows, Chats' is conversations holding a reply nobody has seen.
// Chats' number is also the one that reaches the app icon (see `applyIconBadge`), because
// it is the one that is true whether or not the app is open.
struct RootTabView: View {
    /// The tabs, as data. A `CaseIterable` enum the body ITERATES rather than a
    /// hand-written list of `.tabItem`s: the set of tabs, their order, and
    /// their labels then have exactly one definition, which is also the one a test
    /// can assert against.
    ///
    /// CASE ORDER IS BAR ORDER. The body iterates `allCases`, so moving a case moves
    /// the tab, and there is no second list to keep in step.
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case chats, today, health, vault

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .health: return "Health"
            case .today: return "Today"
            case .vault: return "Vault"
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
            // A CLOSED BOOK, and last on the bar. The vault is the thing the other three
            // tabs are about rather than a fourth kind of work, and it is the tab a person
            // goes to deliberately — to look something up — which is exactly the tab that
            // should not be in the way of the three they open by reflex.
            case .vault: return "text.book.closed"
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

    /// The tab that is up. `defaultTab` at launch — unless a UI test has armed the
    /// thread-landing seam, which starts the app on the tab it names so the push it then
    /// fires arrives from somewhere other than Chats. Nil, and so `defaultTab`, in every
    /// ordinary launch; see `ThreadLandingUITestSeam`.
    @State private var selection: Tab = ThreadLandingUITestSeam.startTab ?? RootTabView.defaultTab

    /// Read twice below: to repaint the icon badge on the way to the background, and to
    /// settle a workout burst whose window ran out while the app was suspended.
    @Environment(\.scenePhase) private var scenePhase

    /// Read for ONE thing: the container the unread counter is resolved from (see
    /// `unread`). Nothing here fetches, inserts or saves — the shell owns no model objects.
    @Environment(\.modelContext) private var context

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

    /// **The strand board's model**, beside the day's and for the same reason: the
    /// Today tab hosts both segments, so both have to survive a tab switch. It reads
    /// nothing the day model reads and writes nothing at all, so the two are entirely
    /// independent apart from sharing the on-disk cache.
    @State private var strandsModel = StrandsModel(
        makeClient: {
            JesseBridgeClient(config: ConfigStore.load(), snapshotCache: SnapshotCache.shared)
        },
        cache: SnapshotCache.shared)

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

    /// The Vault tab's model, and with it the index.
    ///
    /// Built HERE rather than inside the tab for the reason `todayModel` is: the indexer it
    /// owns is driven by app ACTIVATION, which is a fact about the app and not about
    /// whichever tab happens to be on screen. The on-device expander is injected at this
    /// one point, exactly as `MacRootView` does for the conversation list — the package's
    /// own default is the inert one, and a real model must never be reachable from a test.
    @State private var vaultModel = VaultBrowserModel(
        expander: VaultModelExpansion(FoundationModelExpander()))

    /// The replayer, built once the two models exist and handed to the box the
    /// coordinator already holds.
    @State private var replayer: IntentReplayer?

    /// The Health tab's model. It lives HERE rather than in `HealthTabView` for the one
    /// reason the day model does: the replayer needs it (to read the live diet day) and
    /// the replayer must outlive whichever tab happens to be on screen.
    @State private var healthModel = RootTabView.sharedHealthModel

    /// **The one Health model, per process.** Static for the reason `pendingStore` is: it is
    /// also driven with no view hierarchy at all — HealthKit relaunches the app into the
    /// background to deliver a new weigh-in or workout, and `HealthAutoTrigger` must send
    /// that turn through the same model (and so the same offline capture) the button uses.
    @MainActor static let sharedHealthModel = HealthDashboardModel(
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
        let _ = RenderProbe.body("RootTabView")
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
            // A no-op unless a UI test armed it (see `ThreadLandingUITestSeam`): seeds one
            // conversation and posts the tap that must land on it. Here because this is the
            // first moment the shell exists, which is what a tapped notification meets.
            ThreadLandingUITestSeam.arm(context: context)
            buildTheReplayer()
            todayModel.refreshPending()
            healthModel.refreshPending()
        }
        // A workout burst whose settle window ran out while the app was suspended fires
        // the moment the app is back, rather than waiting for a background wake.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await HealthAutoTrigger.shared.settleWorkouts() }
            // The vault index's ONE automatic trigger. Debounced to once per 30 seconds by
            // the indexer itself, off the main actor, and never on a timer: an activation is
            // the moment the local copy may have been resynced behind the app's back. The
            // folder's status is re-read with it, because it may have been picked (or
            // forgotten) in Settings while this app was in the background.
            vaultModel.refresh()
            vaultModel.indexer.reindexIfDue()
            // AND the captures. An activation is the moment the local copy may have been
            // resynced behind the app's back, which is exactly when a capture written here
            // either reached the Studio or quietly did not. It re-reads only the files the
            // write log names, and it NEVER re-appends: a missing line becomes a row on the
            // diagnostics screen, and a person decides.
            Task { await InboxCaptureService.shared.verifyRecent() }
        }
        // EVERY successful fetch and every mutation lands a new server snapshot, and
        // each one is pushed. Not gated on the Today tab being selected: the wrist's
        // list has to be right whichever tab the phone happens to be showing, and a
        // context push is a dictionary written to a mailbox, not a network call.
        // THE ICON FOLLOWS THE LIST. Repainted whenever the count changes — a reply
        // landing, a thread being read here or converging from the Mac — and again on the
        // way to the background, which is the last chance to leave the home screen
        // truthful before the app stops running.
        .onChange(of: unreadCount, initial: true) { _, count in applyIconBadge(count) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { applyIconBadge(unreadCount) }
            // COMING BACK, recount from the store. Every in-process write announces itself
            // (see `UnreadCounter`), but a suspended process announces nothing: a push may
            // have stamped the icon with the bridge's own number while this app was not
            // running to agree or disagree with it. One count query per activation settles
            // that, and publishes nothing unless the number really moved.
            if phase == .active { unread.recountNow() }
        }
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

    /// THE `.equatable()` IS LOAD-BEARING, on both tabs that take a closure.
    ///
    /// This body re-evaluates for reasons that have nothing to do with the Health or Today
    /// screens: a tab switch, a scene-phase change, the Chats badge's number moving. Each
    /// time, it hands both tabs a NEW `onReplay` closure — `replayNow` is a method
    /// reference, so the value differs every build — and SwiftUI cannot prove two closures
    /// equal, so it has to assume the view changed and re-evaluate it. Both screens were
    /// therefore rebuilding while the user was somewhere else entirely.
    ///
    /// `.equatable()` makes the comparison the views' own (`isActive` and which model they
    /// are showing, closure excluded — see their `Equatable` conformances), so a rebuild of
    /// this shell that changes nothing about a tab costs nothing in that tab. Their own
    /// `@State` and observed models still invalidate them exactly as before: equality only
    /// decides whether a NEW value from the parent is worth re-rendering.
    ///
    /// ONE MEASURED CONSEQUENCE, and it is the intended one: an UNSELECTED tab's body is no
    /// longer evaluated at launch at all (it used to be, four times, purely because the
    /// shell kept rebuilding). Its `.task` and `.onChange` handlers are therefore installed
    /// when the tab is first shown rather than at launch, which costs nothing here because
    /// nothing either screen does OFF SCREEN depends on them:
    ///
    ///  * Both tabs' `.task { probe() }` only refreshes the SHARED reachability model, which
    ///    `ContentView` probes on appear and on every foreground anyway.
    ///  * The Today tab's after-turn refresh deliberately runs whether or not the tab is up
    ///    (a Process-updates batch rewrites the day file, so the BADGE is wrong until it is
    ///    re-read) — and it still does, because a batch can only be STARTED from that
    ///    screen, so its body has been evaluated and its handlers installed before there is
    ///    ever anything to settle.
    ///  * The Today badge itself is `todayModel.tabBadgeCount`, primed from cache by THIS
    ///    view's `.task` at launch, never by the tab's.
    ///  * A weigh-in or workout that arrives with no view hierarchy at all goes through the
    ///    static `sharedHealthModel`, never through the tab.
    @ViewBuilder
    private func view(for tab: Tab) -> some View {
        switch tab {
        case .chats:
            // The binding is the whole of the tab-landing plumbing: a conversation opened
            // from a notification, Siri, the wake capture or a shared recording selects
            // this tab before it pushes, because the pushed detail hides the bar below.
            ContentView(selectedTab: $selection)
        case .health:
            HealthTabView(isActive: selection == .health, model: healthModel,
                          onReplay: replayNow)
                .equatable()
        case .today:
            TodayTabView(isActive: selection == .today, model: todayModel,
                         strands: strandsModel,
                         onReplay: replayNow)
                .equatable()
        case .vault:
            VaultBrowserView(model: vaultModel)
        }
    }

    /// The number on each tab. `0` renders as no badge at all.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .today: return todayModel.tabBadgeCount
        case .chats: return unreadCount
        case .health: return 0
        case .vault: return 0
        }
    }

    /// Conversations holding a reply nobody has seen — the Chats badge, and the number the
    /// app icon carries.
    ///
    /// THE SHELL NO LONGER HOLDS THE CONVERSATIONS. This used to be
    /// `jesseUnreadCount(threads)` over a `@Query` of every row, declared right here on the
    /// app's root view, and that one line was the app's worst render dependency: a `@Query`
    /// is refetched on every save that touches its entity, each refetch re-evaluated THIS
    /// body, and this body builds all three tabs — so a title arriving, a star, or any of
    /// the several saves one sync pass makes rebuilt the Health and Today screens while the
    /// user was in Chats.
    ///
    /// `UnreadCounter` answers the same question with a count query, coalesces bursts, and
    /// publishes only when the number actually changes; the rule it counts by is still
    /// `jesseUnreadCount`'s (see `UnreadCounter.unreadDescriptor`). The per-row dot and the
    /// semibold title are untouched — `ThreadListView` has its own query, and the list is
    /// the one view that SHOULD re-render when a conversation changes.
    private var unreadCount: Int { unread.unreadCount }

    /// The one counter for this store. Resolved from the container rather than held in
    /// `@State` so the iPhone and the Mac shell reach the same object the same way, and so
    /// it survives this struct being rebuilt (which it is, on every tab switch).
    private var unread: UnreadCounter { UnreadCounter.shared(for: context.container) }

    /// Paint (or clear) the app-icon badge.
    ///
    /// THREE THINGS IT WILL NOT DO. It never asks for permission — that is
    /// `PushManager.noteSuccessfulTurn`'s single prompt, at the moment the app has earned
    /// one. It checks `badgeSetting` first and returns silently when badges are off, so a
    /// user who has turned them off in Settings is not fought with. And a failure is
    /// swallowed: a badge is not worth an error banner.
    private func applyIconBadge(_ count: Int) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.badgeSetting == .enabled else { return }
            Task { @MainActor in
                try? await UNUserNotificationCenter.current().setBadgeCount(count)
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
        .environment(RunCoordinator())
}

#Preview("Store error") {
    RootTabView(storeError: NSError(domain: "preview", code: 1))
        .environment(RunCoordinator())
}
