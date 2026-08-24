import SwiftUI
import SwiftData
import JesseCore
import JesseNetworking
import JesseTodayDisplay

// The Mac's Today tab: the SAME day-file screen the iPhone shows, rendered from the
// shared `TodayListView` (JesseTodayDisplay) with Mac chrome around it. The division is
// the one `MacHealthView` already uses for the Health tab — the portable half draws the
// document and owns every judgement about it (the optimistic overlay, the ETag, which
// moves are legal, what a drag lands as), and this file holds only what a Mac window
// knows: the toolbar, the keyboard, where a conversation opens, and when to refetch.
//
// It holds NO state of its own beyond that. There is no Mac-side copy of the day, no
// Mac-only persistence, and no second idea of which rows are checked: check, move and
// glance all go through the shared model to the same bridge endpoints the phone writes
// to, so with both apps open the later action wins on the next refresh (the glance
// flags are last-writer-wins bridge-side by construction). The one durable per-device
// thing on this screen is the badge filter, kept in this Mac's own defaults through
// `TodayViewPreferences`: the shared model holds view state but no storage, so which
// preferences survive a relaunch is each shell's own decision. The view sort is
// deliberately not one of them, on either platform.
//
// NO POLLING, exactly as on the phone. The screen refetches on the four things that can
// actually have changed it: the shared view's own load-on-appear, ⌘R, the app becoming
// active, and a turn finishing (a turn may rewrite `Today.md`).
struct MacTodayView: View {
    /// Opens the shared Settings scene (see `JesseMacApp`). This tab needs its own route
    /// for the same reason the Health tab does: an unpaired app dead-ends here with
    /// nothing to draw and no way in, and the Chats sidebar's gear is a different tab.
    @Environment(\.openSettings) private var openSettings
    @Environment(MacCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    private let configStore: MacConfigStore

    /// The day. Its client is rebuilt from the store on every call, so re-pairing in
    /// Settings is picked up on the next fetch — the same factory contract the Health
    /// tab and the iPhone both use.
    @State private var model: TodayDashboardModel

    /// The note behind whichever item is open. ONE model for the whole tab, not one per
    /// pushed screen: it holds the per-item cache, and a fresh model per push would
    /// re-read a note that was on screen thirty seconds ago.
    @State private var detailModel: TodayDetailModel

    /// The selected row, which is what the keyboard acts on. Held here rather than in
    /// the shared view because it is the shell that decided this list is selectable at
    /// all — the phone's is not.
    @State private var selection: String?

    /// The item whose note is pushed onto this tab's stack. A PUSH, not the sheet the
    /// conversation actions use: this is navigation WITHIN the day, so it belongs on the
    /// tab's own stack with a back button. A sheet is for leaving the day.
    @State private var openedItem: TodayItem?

    /// The outstanding Process-updates batch, if any.
    @State private var processRun = MacTodayProcessRun()

    /// Per-device view state for this screen. The badge filter is remembered on this
    /// Mac and never sent to the bridge, exactly as the iPhone remembers its own:
    /// which view of the day a device is showing is a fact about the device.
    @State private var viewPreferences = TodayViewPreferences()

    /// The conversation a Discuss / Propagate / wiki-chip action started.
    ///
    /// Presented MODALLY from this tab rather than selected in the Chats tab's sidebar.
    /// The two tabs are separate view trees and `MacRootView` owns its `selection`
    /// privately; reaching across would mean lifting that binding into the shell and
    /// switching tabs under the user mid-gesture. A sheet keeps them where they were,
    /// and dismissing it returns them to the row they acted on. The conversation itself
    /// is a real thread in the store, so it is in the sidebar afterwards either way.
    @State private var openedThread: JesseThread?

    /// The thread a Discuss STAGED, remembered only so its attached context can be
    /// dropped if the sheet is closed without a send. `.sheet(item:)` nils its binding
    /// before calling `onDismiss`, so the id has to be held separately.
    @State private var stagedThreadID: UUID?

    /// The Mac's half of the offline story, which until now it did not have at all: no
    /// probe, no banner, no read-only day, and no way to notice it had come back. The
    /// same shared `BridgeReachabilityModel` the phone drives.
    private let reachability = BridgeReachabilityModel.shared

    init(configStore: MacConfigStore) {
        self.configStore = configStore
        // The client CARRIES the on-disk cache (it holds the bridge's own bytes) and the
        // model READS it at launch, so a Mac opened with the Studio asleep still draws
        // the last day it was given. See `SnapshotCache`.
        _model = State(initialValue: TodayDashboardModel(makeClient: {
            JesseBridgeClient(config: configStore.config, snapshotCache: SnapshotCache.shared)
        }, cache: SnapshotCache.shared))
        _detailModel = State(initialValue: TodayDetailModel(makeClient: {
            JesseBridgeClient(config: configStore.config)
        }))
    }

    var body: some View {
        NavigationStack {
            TodayListView(model: model,
                          isProcessing: processRun.isRunning,
                          selection: $selection,
                          // A single click selects (which is what space then ticks), so
                          // opening the note is the second click — the Mac's own idiom,
                          // and the only way both gestures fit on one row.
                          opensOnDoubleTap: true,
                          onOpenLink: openLink,
                          onOpenDetail: { openedItem = $0 },
                          onDiscuss: { discuss(.discuss(item: $0)) },
                          onPropagate: { execute(.propagate(item: $0, evidence: $1)) },
                          onProcessUpdates: processUpdates)
                // DECLARATION ORDER IS LEFT-TO-RIGHT, ordered by clicks per day: Settings
                // is opened least often, Refresh far more, so Refresh sits to its right.
                // These two are the shell's half of this screen's toolbar and always
                // render to the LEFT of the shared list's own items (process updates,
                // then the sort menu), which is measured, not assumed: a toolbar declared
                // on a child view lands after the one declared on it from outside. That
                // is what keeps the process/sort pair in the same relative order here as
                // on the iPhone. See README, "UI conventions".
                .toolbar {
                    ToolbarItem {
                        Button { openSettings() } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Pair with your bridge, or change the connection")
                    }
                    ToolbarItem {
                        Button { Task { await model.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Re-read today's day file")
                    }
                }
                .navigationDestination(item: $openedItem) { item in
                    TodayDetailView(model: detailModel, item: item, onOpenLink: openLink)
                        .navigationTitle("Item")
                }
        }
        .sheet(item: $openedThread, onDismiss: dropUnsentContext) { thread in
            MacTodayConversationSheet(thread: thread) { openedThread = nil }
        }
        // A turn settled. Turns rewrite Today.md — the morning routine writes the whole
        // file, a Propagate closes one item — so this is what keeps the screen honest
        // after the agent acts. A Process-updates batch does its own unconditional
        // refetch when it lands (`MacTodayProcessRun`), and this conditional load costs
        // one round trip either way.
        .onChange(of: coordinator.isRunning) { was, now in
            guard was, !now else { return }
            Task { await model.load() }
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
        // The filter is restored once, on the first appearance, and written back on every
        // change. The model holds no storage of its own, the same line it holds for the
        // view sort, so the shell is where the preference becomes durable.
        .task { model.isBadgeFilterOn = viewPreferences.isBadgeFilterOn }
        .onChange(of: model.isBadgeFilterOn) { _, on in viewPreferences.isBadgeFilterOn = on }
        // Coming back covers the overnight case: a window left open on this tab has
        // already run its `.task`, so without this it keeps rendering yesterday's day.
        // A Mac that SLEPT never leaves `.active`, which is why this is `onReconnect`
        // and not a bare `scenePhase` check — see `MacWake`.
        .onReconnect {
            // Coming back to the window is a fresh entry into the view, so the filtered
            // list lets go of the rows it was holding from the last one.
            model.repinBadgeFilter()
            probe()
            Task { await model.load() }
        }
        .task { probe() }
        .onChange(of: reachability.state) { _, _ in applyReachability() }
    }

    // MARK: - Reachability

    private func probe() {
        reachability.refresh(config: configStore.config)
    }

    /// Feed the probe's answer to the model, which is what turns clicks into a refusal
    /// instead of a failed write. Same gate as every other screen: an UNPAIRED app is
    /// not offline, it is unconfigured, and Settings is the answer to that.
    private func applyReachability() {
        model.isNetworkUnreachable = shouldShowOfflineBanner(
            isConfigured: configStore.isConfigured,
            reachability: reachability.state)
    }

    // MARK: - Actions

    /// A link chip: the web opens in the browser, a vault note opens a conversation
    /// about the row that referenced it (there is no in-app vault viewer in v1).
    ///
    /// A chip FIRES, unlike Discuss. "Open this note" has an answer the agent can
    /// produce unprompted — it reads the file the app cannot — so the click is a
    /// request, not the opening of a conversation with nothing in it yet.
    private func openLink(_ origin: TodayLinkOrigin) {
        if let turn = TodayTurn.openLink(origin) {
            execute(turn)
        } else if let url = URL(string: origin.link.target) {
            openURL(url)
        }
    }

    /// Discuss: open a conversation about the item and start NOTHING. The item, its
    /// links and the frozen framing ride along as attached context and reach the bridge
    /// with Jeremy's own first message — see `MacTodayThreadOpener.stage`.
    private func discuss(_ turn: TodayTurn) {
        let thread = MacTodayThreadOpener.stage(turn, coordinator: coordinator)
        stagedThreadID = thread.id
        openedThread = thread
    }

    /// Propagate and wiki chips: an explicit "do this now", so the turn goes out on the
    /// click and the sheet opens onto a conversation already running.
    private func execute(_ turn: TodayTurn) {
        // Refused while the day is read-only, and NOT captured: this FIRES a turn that
        // rewrites project files, which is not a small fact about one day that a replay
        // could re-aim, and fired at an unreachable bridge it is a request that looks
        // sent and is not. Discuss is deliberately NOT gated here — it starts nothing.
        //
        // (The Mac shell wires no capture queue, so a checkbox click here still refuses
        // too. That is the honest behaviour rather than an oversight: this window has no
        // pending list to show a held change on.)
        guard !model.refuseTurnIfReadOnly() else { return }
        openedThread = MacTodayThreadOpener.run(turn, coordinator: coordinator,
                                                context: context)
    }

    /// Process updates: one combined Tell for every item ticked today.
    ///
    /// Fired only from the confirmation sheet's Process button, never from opening it,
    /// and refused while the day is read-only — the same refusal a checkbox click gets,
    /// for the same reason. The conversation opens so the turn is watchable; it is a
    /// long one.
    private func processUpdates(_ items: [TodayItem]) {
        // Never captured on any platform — the batch is the set ticked at this moment.
        guard !model.refuseTurnIfReadOnly() else { return }
        openedThread = processRun.start(items: items, coordinator: coordinator,
                                        context: context, day: model)
    }

    /// Closing a staged discussion without sending drops the context with it — a no-op
    /// once the first send has consumed it.
    private func dropUnsentContext() {
        if let id = stagedThreadID { coordinator.clearAttachedContext(for: id) }
        stagedThreadID = nil
    }
}

/// A Today conversation, in a sheet.
///
/// The same `MacThreadDetailView` the Chats tab's detail pane uses, so a discussion
/// opened from the day has the full composer — the mode picker, the per-conversation
/// model picker, and the Return-sends AppKit text view. A macOS sheet has no
/// swipe-to-dismiss, so it carries the Done button it needs to be closable at all, and
/// a minimum size, because a sheet sizes to its content and a transcript has no
/// intrinsic one.
private struct MacTodayConversationSheet: View {
    let thread: JesseThread
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            MacThreadDetailView(thread: thread)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 620)
    }
}
