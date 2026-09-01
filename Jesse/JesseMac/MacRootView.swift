import SwiftUI
import JesseOps
import SwiftData
import JesseCore
import JesseConversations
import JesseSearch

// The Mac shell: a NavigationSplitView with the thread list on the left and the
// selected conversation on the right — the big-screen affordance the plan calls for
// (list + detail, full keyboard, wide layout). The list renders from the local store
// (cache-first: instant paint, works offline) and reconciles from `GET /jesse/sessions`
// in the background; phone-started threads appear via that server list.
//
// The sidebar is driven by the shared `threadListLayout` (via `MacThreadListModel`),
// not a bare @Query sort, so grouping / favorites / origin are computed by exactly
// the same code the iPhone uses. A scope control (all vs favorites) flips between the
// full date-sectioned layout and the flat favorites list, and each row can be starred.

// The window's top-level shell: a three-tab split between the existing Chats
// experience (the NavigationSplitView, with all its selection / ⌘N / ⌘R / ⌘, /
// favorites / archive / search behavior unchanged), the vault's day file
// (`MacTodayView`) and the bridge-fed Health tab. Only this tab chrome is
// Mac-specific; each tab's content is otherwise exactly what it was.
//
// CHATS LEADS, TODAY IS SECOND, matching the iPhone's tab bar exactly
// (`RootTabView.Tab.allCases`). The order is one decision for both platforms and is
// asserted on the iPhone side, where the tabs are an enum a test can read; this
// window is a hand-written list and must be kept in step with it by hand. The
// glyphs are the iPhone's too — `sunrise` for Today, which is where the day gets
// started. Each tab owns its own ⌘R, which is unambiguous because only the selected
// tab's toolbar is live — the Health tab has worked that way since it landed.
struct MacShellView: View {
    @Environment(MacCoordinator.self) private var coordinator
    /// Store-open failure banner, threaded down to the Chats tab.
    var storeError: Error?

    var body: some View {
        TabView {
            MacRootView(storeError: storeError)
                .safeAreaInset(edge: .top, spacing: 0) {
                    AwayProfileBanner(configuration: coordinator.configStore.opsConfiguration)
                }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            MacTodayView(configStore: coordinator.configStore)
                // The profile the day is derived in, above the day itself — the same shared
                // banner the phone shows, from the same model.
                .safeAreaInset(edge: .top, spacing: 0) {
                    AwayProfileBanner(configuration: coordinator.configStore.opsConfiguration,
                                      alwaysShowName: true)
                }
                .tabItem { Label("Today", systemImage: "sunrise") }
            MacHealthView(configStore: coordinator.configStore)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
        }
    }
}

struct MacRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(MacCoordinator.self) private var coordinator

    /// The raw store rows. Sort order here is immaterial; `threadListLayout` groups
    /// and orders them, and the @Query just keeps the set live as the store changes.
    @Query(sort: \JesseThread.updatedAt, order: .reverse) private var threads: [JesseThread]

    /// Opens the macOS Settings scene (see `JesseMacApp`). Used for every in-window route
    /// to Settings so there is a single settings surface, reachable even when the sidebar
    /// toolbar is not (an unconfigured window, or the Health tab).
    @Environment(\.openSettings) private var openSettings

    @State private var selection: UUID?
    @State private var confirmMorningRoutine = false
    // The last local day (`yyyy-MM-dd`) this device fired the morning routine. Same key
    // as the phone's, so the two spell "today" the same way; it changes the
    // confirmation's wording only, never whether either action is offered.
    @AppStorage(MorningRoutine.lastFiredDayKey) private var morningRoutineLastFiredDay = ""
    /// Scope (all / favorites / archived) + folder-expansion state + the two-tier
    /// search, wrapping the shared layout. The production on-device expander is
    /// injected HERE, in the view, on purpose: the view model defaults to the inert
    /// `NoExpansion` so unit tests never spin up the real on-device model. Do not
    /// push `FoundationModelExpander()` down into a test-reachable default. The
    /// Settings toggle drives the tier's enabled flag each keystroke.
    @State private var listModel = MacThreadListModel(searchExpander: FoundationModelExpander())

    // Whether the on-device query-expansion tier is enabled (Settings toggle, default
    // ON). Off -> no `expand` calls, pure Tier-1 multi-token search. Same key and
    // default as the iPhone's Settings toggle.
    @AppStorage("searchExpansionEnabled") private var searchExpansionEnabled = true
    // Prewarm the model once per search session (on the first keystroke), reset when
    // the query clears. `.searchable` focus isn't directly observable, and prewarm is
    // an idempotent no-op when the model is unavailable.
    @State private var didPrewarm = false

    /// Store-open failure banner (in-memory fallback — history not being saved).
    var storeError: Error?

    private var selectedThread: JesseThread? {
        threads.first { $0.id == selection }
    }

    /// The sidebar shape, computed by the shared pure function so the Mac matches iOS.
    /// Reads `listModel.searchQueries`, which reads the shared model's `activeTerms`,
    /// so the list widens automatically when on-device expansion terms arrive.
    private var layout: ThreadListLayout {
        listModel.layout(threads, now: .now, calendar: .current)
    }

    /// Whether a search is active (the typed query is non-blank).
    private var isSearching: Bool {
        !listModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the resolved layout has no rows at all (used only to show the search
    /// no-results state; grouping never yields empty sections).
    private var layoutIsEmpty: Bool {
        switch layout {
        case .flat(let t): return t.isEmpty
        case .sectioned(let s): return s.allSatisfy { $0.threads.isEmpty }
        }
    }

    /// Feed the live query into the shared expansion model: prewarm once per session
    /// on the first keystroke, then let the model debounce/gate/cache/cancel. The
    /// base-match count is the Tier-1 hit count within the current scope, so the model
    /// only spends the on-device model when direct results are thin. A no-op for the
    /// tier when Settings has it off (pure Tier-1 search, zero `expand` calls).
    private func driveSearch() {
        if !searchExpansionEnabled || listModel.searchText.isEmpty {
            didPrewarm = false
        } else if !didPrewarm {
            listModel.search.prewarm()
            didPrewarm = true
        }
        listModel.updateSearch(threads, enabled: searchExpansionEnabled)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            Group {
                if let thread = selectedThread {
                    MacThreadDetailView(thread: thread)
                        .id(thread.id)
                } else {
                    MacEmptyDetail(configured: coordinator.configStore.isConfigured) {
                        openSettings()
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if storeError != nil { MacStoreErrorBanner() }
        }
        .task {
            // Prune abandoned ⌘N threads BEFORE syncing, so an empty stub never reaches the
            // merge or the list. `newChat` inserts AND SAVES immediately (the Mac has no
            // deferred-insert path), so an unused new chat is a persisted empty row, and they
            // accumulate and read exactly like duplicates. The phone already prunes on its
            // list appear; this is the Mac's half.
            pruneEmptyThreads()
            await coordinator.refreshSessions(context: context)
        }
        // The sidebar's half of the wake story. A Mac that slept holds a dead socket and
        // a `lastError` from the first request that noticed; without a re-pull on wake
        // the list stays stale and the window stays red until someone hits the refresh
        // button. See `MacWake`.
        .onReconnect {
            Task { await coordinator.refreshSessions(context: context) }
        }
    }

    /// Delete never-used empty threads: no turns, never sent (no session), and not the one
    /// currently running. Deliberately narrow, so it can never take a thread whose turn is in
    /// flight or one that holds any history.
    private func pruneEmptyThreads() {
        var pruned = 0
        for t in threads where t.turns.isEmpty
            && (t.sessionId ?? "").isEmpty
            && t.registeredAt == nil
            && !(coordinator.isRunning && coordinator.activeThreadID == t.id) {
            if selection == t.id { selection = nil }
            if let cid = t.conversationId, !cid.isEmpty { MacCursorStore.clear(cid) }
            context.delete(t)
            pruned += 1
        }
        if pruned > 0 { try? context.save() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            switch layout {
            case .flat(let threads):
                // Favorites scope: one flat, newest-first list, no folder chrome.
                ForEach(threads) { row($0) }
            case .sectioned(let sections):
                ForEach(sections) { rendered in
                    if rendered.isFolder {
                        folderSection(rendered)
                    } else {
                        // Loose day rows: today / yesterday / the one weekday.
                        Section(rendered.section.title()) {
                            ForEach(rendered.threads) { row($0) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) { scopePicker }
        .overlay { emptyState }
        // Live sidebar search, matching the iPhone: instant Tier-1 token matching,
        // widened by Tier-2 on-device query expansion when available. On the first
        // keystroke the model is prewarmed; every keystroke re-drives it.
        .searchable(text: $listModel.searchText, placement: .sidebar,
                    prompt: "Search conversations")
        .onChange(of: listModel.searchText) { _, _ in driveSearch() }
        .onChange(of: searchExpansionEnabled) { _, _ in driveSearch() }
        .navigationTitle("Jesse")
        // DECLARATION ORDER IS LEFT-TO-RIGHT, ordered by taps per day exactly as on the
        // iPhone: New Chat is the most-used action here so it is declared LAST and sits
        // farthest right, the morning routine is next, and the rest work inward through
        // Refresh, the favorites filter, Archive, and Settings, which is opened least of
        // all. See README, "UI conventions".
        //
        // ONE MAC-ONLY CONSEQUENCE, measured rather than assumed: this group renders
        // above the SIDEBAR, so its width is the sidebar's, not the window's, and at the
        // default sidebar width only three of the six items are laid out. The rest go
        // into the "more toolbar items" overflow, and NSToolbar clips from the trailing
        // end. Every keyboard shortcut in this group still works while clipped, and
        // widening the sidebar reveals more items.
        .toolbar {
            ToolbarItemGroup {
                // Opens the shared Settings scene. The scene owns the standard ⌘, shortcut
                // globally, so this button carries none of its own (a second ⌘, binding
                // would just shadow the system one).
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                // Archive / restore the selected conversation. ⌘⇧A works with only a
                // sidebar selection (no visible control focused); the row's context
                // menu and trailing swipe mirror the same action. Disabled with no
                // selection so the shortcut is a no-op then.
                Button { archiveSelected() } label: {
                    Label(selectedThread?.isArchived == true ? "Unarchive" : "Archive",
                          systemImage: selectedThread?.isArchived == true
                              ? "tray.and.arrow.up" : "archivebox")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(selectedThread == nil)
                // Toggle the favorites filter. ⌘⇧F flips scope even with no visible
                // control focused; the segmented picker below mirrors the same state.
                Button { listModel.toggleFavoritesScope() } label: {
                    Label("Show Favorites",
                          systemImage: listModel.scope == .favorites ? "star.fill" : "star")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button { Task { await coordinator.refreshSessions(context: context) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                // The morning routine, as a button — the Mac half of the phone's Chats
                // toolbar item, sending the same bytes from the same shared constant.
                // `cup.and.saucer` because both sun glyphs are spoken for: `sun.horizon`
                // is the Health tab's "Start new day" and `sunrise` is the Today tab.
                //
                // NO KEYBOARD SHORTCUT, unlike every other button in this group. The
                // other four are cheap and reversible (a new chat, a refresh, a filter
                // flip, an archive toggle); this one starts a routine that runs for
                // minutes and rewrites the day file, and a shortcut is exactly how it
                // would get fired by a mistyped ⌘-something. Being heavy is also why it
                // sits inward of New Chat rather than in the rightmost, mis-click slot.
                Button { confirmMorningRoutine = true } label: {
                    Label(MorningRoutine.dialogTitle, systemImage: "cup.and.saucer")
                }
                .help("Run the full start of day routine")
                .disabled(!coordinator.configStore.isConfigured)
                Button { newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!coordinator.configStore.isConfigured)
            }
        }
        // Same confirmation as the phone, from the same shared copy: a click starts a
        // routine that runs for minutes. Start-of-day alone leads and reads as the
        // default; the health and diet refresh is the explicit second choice.
        .confirmationDialog(MorningRoutine.dialogTitle, isPresented: $confirmMorningRoutine) {
            Button(MorningRoutine.startAction) { startMorningRoutine(includeHealth: false) }
            Button(MorningRoutine.includeHealthAction) { startMorningRoutine(includeHealth: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MorningRoutine.confirmationMessage(lastFiredDay: morningRoutineLastFiredDay.isEmpty
                                                        ? nil : morningRoutineLastFiredDay,
                                                    now: .now))
        }
    }

    /// Fire the morning routine and SELECT the conversation, so the briefing streams
    /// into the detail column while it runs. `MacHealthView.startNewDay()` deliberately
    /// does not select — its output is a dashboard on another tab — but this turn's
    /// output IS the conversation, and it is the thing Jeremy is waiting to read.
    private func startMorningRoutine(includeHealth: Bool) {
        // `newChat()`'s insert-and-save, plus the Health tab's detached send. Selecting
        // after the save keeps the sidebar row and the detail column agreeing on one
        // identity. `pruneEmptyThreads` cannot take this thread: it runs once from the
        // shell's `.task`, and it already excludes the thread whose turn is in flight.
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        try? context.save()
        selection = thread.id
        let text = MorningRoutine.prompt(now: .now, includeHealthNewDay: includeHealth)
        Task { await coordinator.send(text: text, mode: .tell, thread: thread, context: context) }
        morningRoutineLastFiredDay = MorningRoutine.dayStamp(.now)
    }

    /// The scope control: a segmented picker matching the iPhone's tabs. All and
    /// Favorites exclude archived threads; Archived shows only hidden conversations.
    private var scopePicker: some View {
        Picker("Scope", selection: $listModel.scope) {
            Text("All").tag(MacThreadListModel.Scope.all)
            Text("Favorites").tag(MacThreadListModel.Scope.favorites)
            Text("Archived").tag(MacThreadListModel.Scope.archived)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Empty-state overlays: nothing at all, or the favorites scope with no stars yet.
    @ViewBuilder
    private var emptyState: some View {
        if threads.isEmpty {
            ContentUnavailableView(
                "No conversations yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(coordinator.configStore.isConfigured
                    ? "Start one with the compose button, or pull your phone’s threads with Refresh."
                    : "Connect to your bridge in Settings to begin."))
        } else if isSearching && layoutIsEmpty {
            // A search is active but nothing in this scope matches, neither the typed
            // query nor any expansion term. Clearing the field restores the list.
            ContentUnavailableView.search(text: listModel.searchText)
        } else if listModel.scope == .favorites, case .flat(let list) = layout, list.isEmpty {
            ContentUnavailableView(
                "No favorites yet",
                systemImage: "star",
                description: Text("Star a conversation to keep it here."))
        } else if listModel.scope == .archived, case .flat(let list) = layout, list.isEmpty {
            ContentUnavailableView(
                "No archived conversations",
                systemImage: "archivebox",
                description: Text("Archive a conversation to hide it from your list. It stays here until you restore it, and never leaves this Mac."))
        }
    }

    /// One sidebar row, with a star affordance plus context-menu and swipe toggles,
    /// mirroring the iPhone. Selection stays tagged by thread id so restoring the
    /// selected conversation across relaunches keeps working.
    private func row(_ thread: JesseThread) -> some View {
        MacThreadRow(thread: thread,
                     running: coordinator.isRunning(thread.id),
                     onToggleFavorite: { toggleFavorite(thread) })
            .tag(thread.id)
            .contextMenu {
                Button { toggleFavorite(thread) } label: {
                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: thread.isFavorite ? "star.slash" : "star")
                }
                Button { toggleArchived(thread) } label: {
                    Label(thread.isArchived ? "Unarchive" : "Archive",
                          systemImage: thread.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                Divider()
                Button(role: .destructive) { delete(thread) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button { toggleFavorite(thread) } label: {
                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: thread.isFavorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
            // Archive / restore via a trailing swipe (distinct from the leading
            // favorite swipe and from Delete in the context menu). Hides the thread
            // from All / Favorites, or restores it from Archived. Local only.
            .swipeActions(edge: .trailing) {
                Button { toggleArchived(thread) } label: {
                    Label(thread.isArchived ? "Unarchive" : "Archive",
                          systemImage: thread.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                .tint(.indigo)
            }
    }

    /// A month bucket as a collapsible folder, mirroring the iPhone: a DisclosureGroup
    /// whose chevron reflects/toggles the shared `expandedFolders` state (collapsed by
    /// default hides the rows), with the deterministic count · date-range summary.
    @ViewBuilder
    private func folderSection(_ rendered: RenderedThreadSection) -> some View {
        let header = folderHeader(for: rendered, calendar: .current, locale: .current)
        Section {
            DisclosureGroup(isExpanded: folderBinding(for: rendered)) {
                ForEach(rendered.threads) { row($0) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.title).font(.headline)
                        Text(header.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(header.title), \(header.summary)")
            }
        }
    }

    /// Binding the folder's DisclosureGroup reads/writes: the getter reflects the
    /// resolved layout, the setter routes the toggle through the pure helper so a tap
    /// does exactly what the JesseConversations tests pin.
    private func folderBinding(for rendered: RenderedThreadSection) -> Binding<Bool> {
        Binding(
            get: { rendered.isExpanded },
            set: { open in
                if open != rendered.isExpanded {
                    listModel.toggleFolder(rendered.section)
                }
            })
    }

    private func toggleFavorite(_ thread: JesseThread) {
        listModel.toggleFavorite(thread)
        try? context.save()
        // Best-effort mirror to the bridge so the phone converges; self-healing if it
        // fails (see MacCoordinator.pushFavoriteChange).
        coordinator.pushFavoriteChange(for: thread)
    }

    /// Archive / restore one conversation through the shared seam, then persist and
    /// best-effort mirror the change to the bridge so the phone converges. Nothing is
    /// deleted; the flip just hides or re-shows the row locally.
    private func toggleArchived(_ thread: JesseThread) {
        listModel.toggleArchived(thread)
        try? context.save()
        coordinator.pushArchivedChange(for: thread)
    }

    /// The ⌘⇧A action: archive / restore whatever thread is selected in the sidebar.
    /// No-op with no selection (the toolbar button is disabled then).
    private func archiveSelected() {
        guard let thread = selectedThread else { return }
        toggleArchived(thread)
    }

    private func newChat() {
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try? context.save()
        selection = thread.id
    }

    private func delete(_ thread: JesseThread) {
        if selection == thread.id { selection = nil }
        // Durably enqueue the CONVERSATION's remote deletion BEFORE the local delete reads
        // it: the local delete stays instant; reclaiming every remote transcript bound to the
        // conversation (and the cross-device tombstone that converges the delete to the phone)
        // is best-effort and retried on the next list pull if the Studio is asleep now.
        if let cid = thread.conversationId, !cid.isEmpty {
            coordinator.enqueueSessionDeletion(cid)
            MacCursorStore.clear(cid)
        }
        context.delete(thread)
        try? context.save()
    }
}

/// One sidebar row: the best title we have (server AI title > derived first-message),
/// with a subtitle preview, a running spinner, and a star affordance reflecting and
/// toggling its favorite state.
struct MacThreadRow: View {
    let thread: JesseThread
    let running: Bool
    /// Star / unstar this conversation (the parent persists the context).
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayTitle(for: thread)).font(.body).lineLimit(1)
                    if running {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                if let last = thread.orderedTurns.last {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Filled star when starred, outline otherwise; a click toggles it.
            Button(action: onToggleFavorite) {
                Image(systemName: thread.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(thread.isFavorite ? .yellow : .secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(thread.isFavorite ? "Unfavorite" : "Favorite")
            .accessibilityLabel(thread.isFavorite ? "Unfavorite" : "Favorite")
        }
        .padding(.vertical, 2)
    }
}

/// The right pane before a thread is chosen.
struct MacEmptyDetail: View {
    let configured: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Jesse for Mac").font(.title2.weight(.semibold))
            if configured {
                Text("Pick a conversation, or start a new one with ⌘N.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect to your bridge to begin.").foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MacStoreErrorBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t open your saved conversations").font(.footnote.weight(.semibold))
                Text("This session won’t be saved. Your on-disk data wasn’t changed — relaunch to retry.")
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red)
    }
}
