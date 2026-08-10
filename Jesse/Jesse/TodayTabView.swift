import SwiftUI
import SwiftData
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// The iOS Today tab: a thin shell around the SHARED day-file screen (`TodayListView`
// in JesseTodayDisplay, which the Mac will render identically when it gets one).
// Everything platform-specific stays here — the refresh triggers, the reachability
// probe, and the two conversation actions that reach `RunCoordinator` — exactly the
// division `HealthTabView` uses for the Health tab.
//
// NO POLLING. The screen refreshes on the four things that can actually have changed
// it: a pull, the tab becoming active, the app coming back to the foreground, and a
// turn finishing (a turn may rewrite `Today.md`). There is no timer and no retained
// animation subscription — the battery rules for this app stand.

struct TodayTabView: View {
    /// Whether this is the selected tab. Gates the after-turn refresh so a background
    /// turn doesn't refetch while the user is reading Chats.
    let isActive: Bool

    /// Owned by `RootTabView`, because the tab item's badge reads the same model the
    /// screen does. One model, one number, no second definition of "how many".
    @Bindable var model: TodayDashboardModel

    @Environment(RunCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    /// The same probe the Chats list's offline banner uses, asked here so the day
    /// goes read-only BEFORE a tap rather than after one fails.
    @State private var reachability = BridgeReachabilityModel()

    /// The note behind whichever item is open, if any.
    ///
    /// ONE model for the whole tab, not one per pushed screen: it holds the per-item
    /// cache, and a fresh model per push would refetch a note the user read thirty
    /// seconds ago. Injected through the same narrow seam as the day itself — the
    /// shared client, rebuilt per call so a re-pairing is picked up.
    @State private var detailModel = TodayDetailModel(
        makeClient: { JesseBridgeClient(config: ConfigStore.load()) })

    /// The item whose detail is pushed. A PUSH rather than the sheet the two
    /// conversation actions use: this is navigation WITHIN the day (the note behind a
    /// row), so it belongs on this tab's own stack, with a back button and the
    /// edge-swipe that comes with it. A sheet is for leaving the day for a
    /// conversation.
    @State private var openedItem: TodayItem?

    /// The outstanding Process-updates batch, if any.
    @State private var processRun = TodayProcessRun()

    /// The conversation a Discuss / Propagate / wiki-chip action started.
    ///
    /// Presented MODALLY from this tab rather than pushed into the Chats stack. There
    /// is no precedent in this app for one tab driving another's navigation — the
    /// Health tab's quick log and "Start new day" fire a turn and never navigate at
    /// all, and `ContentView` owns its `path` privately, including the two different
    /// shapes it takes on iPhone and iPad. Reaching across would mean a shared path
    /// binding and a tab switch mid-gesture; a sheet keeps the user where they were,
    /// and dismissing it returns them to the row they acted on.
    @State private var openedThread: JesseThread?

    /// The thread a Discuss STAGED, remembered only so its attached context can be
    /// dropped if the sheet is dismissed without a send. `.sheet(item:)` nils its
    /// binding before calling `onDismiss`, so the id has to be held separately.
    @State private var stagedThreadID: UUID?

    var body: some View {
        NavigationStack {
            TodayListView(model: model,
                          isProcessing: processRun.isRunning(coordinator),
                          onOpenLink: openLink,
                          onOpenDetail: { openedItem = $0 },
                          onDiscuss: { discuss(.discuss(item: $0)) },
                          onPropagate: { execute(.propagate(item: $0, evidence: $1)) },
                          onProcessUpdates: processUpdates)
                // The day file's own title is a sentence ("Today: Monday, August 10,
                // 2026"), which a large title truncates to "Today: Monday, Augus…" on
                // a phone. Inline fits it and buys back the vertical space the list
                // wants. Applied HERE rather than in the package because
                // `navigationBarTitleDisplayMode` is UIKit-only and that file compiles
                // for macOS too — the shell is where platform spellings belong.
                .navigationBarTitleDisplayMode(.inline)
                // The accessible reorder fallback. A long-press drag is the primary
                // gesture and needs no edit mode, but a precise long drag is exactly
                // what is hardest with a tremor, with Switch Control, or one-handed;
                // the grips give the same reorder as a short, forgiving drag, and
                // VoiceOver drives them directly. `EditButton` is UIKit-only, which is
                // why it lives in the shell and not in the shared list.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
                .navigationDestination(item: $openedItem) { item in
                    TodayDetailView(model: detailModel, item: item, onOpenLink: openLink)
                        .navigationTitle("Item")
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .sheet(item: $openedThread, onDismiss: dropUnsentContext) { thread in
            // `hidesTabBar: false`: a sheet already covers the tab bar, and asking the
            // detail view to hide it would leave the bar hidden after dismissal.
            NavigationStack { ThreadDetailView(thread: thread, hidesTabBar: false) }
        }
        // The load-on-appear and pull-to-refresh live in the shared `TodayListView`;
        // the shell adds the three triggers only the app knows about.
        .onChange(of: coordinator.inFlight.count) { old, new in
            // A turn settled. Turns rewrite Today.md — the morning routine writes the
            // whole file, a Propagate closes one item, a Process-updates batch removes
            // every ticked line — so this is the trigger that keeps the screen honest
            // after the agent acts.
            guard new < old else { return }
            Task {
                // A batch of OURS is refetched whether or not this tab is up: it
                // removed rows and may have added others, so the tab BADGE is wrong
                // until the day is re-read, and the badge is visible from every tab.
                if await processRun.settled(coordinator: coordinator, day: model) { return }
                if isActive { await model.load() }
            }
        }
        // A `410` from the detail read means the item left the day file while the list
        // was still drawing it. Pop back to the day and tell the model, which takes the
        // row off the screen and refetches — the same treatment a `410` from a mutation
        // already gets, reached from the one other place that can learn it.
        .onChange(of: detailModel.state) { _, state in
            guard state == .removed, let item = openedItem else { return }
            openedItem = nil
            Task { await model.itemVanished(id: item.id) }
        }
        // A new day file means every cached note may now resolve to a different file:
        // the item ids are content hashes, and a rebuild re-points what they link.
        .onChange(of: model.etag) { _, _ in detailModel.invalidate() }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            probe()
            Task { await model.load() }
        }
        // Foregrounding covers the overnight case: parked on this tab with the app
        // suspended, `.task` has already fired and `isActive` never changed, so
        // without this the screen keeps rendering yesterday's day file.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isActive else { return }
            probe()
            Task { await model.load() }
        }
        .task { probe() }
        .onChange(of: reachability.state) { _, _ in applyReachability() }
    }

    // MARK: - Reachability

    private func probe() {
        reachability.refresh(config: ConfigStore.load())
    }

    /// Feed the probe's answer to the model, which is what turns taps into a refusal
    /// instead of a queued write. Same gate as the Chats list's banner: an UNPAIRED
    /// app is not offline, it is unconfigured, and the pairing CTA covers that.
    private func applyReachability() {
        model.isNetworkUnreachable = shouldShowOfflineBanner(
            isConfigured: ConfigStore.load().isConfigured,
            reachability: reachability.state)
    }

    // MARK: - Actions

    /// A link chip: the web opens in the browser, a vault note opens a conversation
    /// about the row that referenced it (there is no in-app vault viewer in v1).
    ///
    /// A chip FIRES, unlike Discuss. "Open this note" has an answer the agent can
    /// produce unprompted — it reads the file the app cannot — so the tap is a
    /// request, not the opening of a conversation with nothing in it yet.
    private func openLink(_ origin: TodayLinkOrigin) {
        if let turn = TodayTurn.openLink(origin) {
            execute(turn)
        } else if let url = URL(string: origin.link.target) {
            openURL(url)
        }
    }

    /// Discuss: open a conversation about the item and start NOTHING. The item, its
    /// links and the frozen framing ride along as attached context and reach the
    /// bridge with the user's own first message — see `TodayThreadOpener.stage`.
    private func discuss(_ turn: TodayTurn) {
        let thread = TodayThreadOpener.stage(turn, coordinator: coordinator)
        stagedThreadID = thread.id
        openedThread = thread
    }

    /// Propagate and wiki chips: an explicit "do this now", so the turn goes out on
    /// the tap and the sheet opens onto a conversation already running.
    private func execute(_ turn: TodayTurn) {
        openedThread = TodayThreadOpener.run(turn, coordinator: coordinator, context: context)
    }

    /// Process updates: one combined Tell for every item ticked today.
    ///
    /// Fired only from the sheet's Confirm, never from opening it, and refused while
    /// the day is read-only — the same refusal a checkbox tap gets, for the same
    /// reason. The conversation opens so the turn is watchable; it is a long one.
    private func processUpdates(_ items: [TodayItem]) {
        guard !model.refuseInteractionIfReadOnly() else { return }
        openedThread = processRun.start(items: items, coordinator: coordinator,
                                        context: context)
    }

    /// Dismissing a staged discussion without sending drops the context with it — a
    /// no-op once the first send has consumed it.
    private func dropUnsentContext() {
        if let id = stagedThreadID { coordinator.clearAttachedContext(for: id) }
        stagedThreadID = nil
    }
}
