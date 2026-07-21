import SwiftUI
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

// The window's top-level shell: a two-tab split between the existing Chats experience
// (the NavigationSplitView, with all its selection / ⌘N / ⌘R / ⌘, / favorites / archive /
// search behavior unchanged) and the new bridge-fed Health tab. Only this tab chrome is
// Mac-specific; each tab's content is otherwise exactly what it was.
struct MacShellView: View {
    @Environment(MacCoordinator.self) private var coordinator
    /// Store-open failure banner, threaded down to the Chats tab.
    var storeError: Error?

    var body: some View {
        TabView {
            MacRootView(storeError: storeError)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
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

    @State private var selection: UUID?
    @State private var showingSettings = false
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
                        showingSettings = true
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if storeError != nil { MacStoreErrorBanner() }
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsView(configStore: coordinator.configStore)
        }
        .task {
            await coordinator.refreshSessions(context: context)
        }
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
        .toolbar {
            ToolbarItemGroup {
                Button { newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!coordinator.configStore.isConfigured)
                Button { Task { await coordinator.refreshSessions(context: context) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                // Toggle the favorites filter. ⌘⇧F flips scope even with no visible
                // control focused; the segmented picker below mirrors the same state.
                Button { listModel.toggleFavoritesScope() } label: {
                    Label("Show Favorites",
                          systemImage: listModel.scope == .favorites ? "star.fill" : "star")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
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
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
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
    }

    /// Archive / restore one conversation through the shared seam, then persist. Local
    /// only: it flips `isArchived` so the shared layout hides or re-shows the row;
    /// nothing is deleted and nothing is synced to the bridge.
    private func toggleArchived(_ thread: JesseThread) {
        listModel.toggleArchived(thread)
        try? context.save()
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

    private var displayTitle: String {
        if let ai = thread.aiTitle, !ai.isEmpty { return ai }
        if !thread.title.isEmpty { return thread.title }
        return "New conversation"
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayTitle).font(.body).lineLimit(1)
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
