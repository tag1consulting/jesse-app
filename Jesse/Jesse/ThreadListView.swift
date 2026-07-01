import SwiftUI
import SwiftData

// Root screen: the list of conversations, newest first. Tapping one opens it;
// `+` starts a fresh one. Starting several and letting them run at once is just
// "compose, swipe back, compose again" — nothing blocks.
struct ThreadListView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Query(sort: \JesseThread.updatedAt, order: .reverse) private var threads: [JesseThread]

    @Binding var path: [JesseThread]
    @Binding var config: JesseConfig
    @Binding var showSettings: Bool

    // Remembered across launches: false = All, true = Favorites only.
    @AppStorage("threadListFavoritesOnly") private var favoritesOnly = false

    // Live search text. Not persisted — a fresh launch starts with the full list.
    @State private var searchText = ""

    // Which month folders the user has opened, keyed by section identity. Month
    // folders default collapsed (absent here); day sections never fold. Reset on
    // launch, so old history opens closed every time.
    @State private var expandedFolders: Set<ThreadSection> = []

    /// Threads the active tab shows, before search. The All view keeps date order
    /// untouched; Favorites simply narrows to starred threads (no reordering or
    /// pinning).
    private var visible: [JesseThread] {
        favoritesOnly ? threads.filter(\.isFavorite) : threads
    }

    /// `visible` narrowed by the search query (title + turn bodies). A blank
    /// query matches everything, so this is just `visible` when search is idle.
    /// Applied before grouping, so results stay date-sectioned and compose with
    /// the All/Favorites tab.
    private var searched: [JesseThread] {
        visible.filter { threadMatches($0, query: searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Only meaningful once there's at least one conversation to filter.
            if !threads.isEmpty {
                Picker("Filter", selection: $favoritesOnly) {
                    Text("All").tag(false)
                    Text("Favorites").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            content
        }
        .searchable(text: $searchText, prompt: "Search conversations")
        .navigationTitle("Jesse")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: newThread) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .onAppear(perform: pruneEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if threads.isEmpty {
            ContentUnavailableView {
                Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Tap + to start one.")
            }
        } else if visible.isEmpty {
            // Favorites filter on, nothing starred yet. The picker above stays
            // visible so you can switch back to All.
            ContentUnavailableView {
                Label("No favorites yet", systemImage: "star")
            } description: {
                Text("Swipe a conversation and tap Favorite to star it.")
            }
        } else if searched.isEmpty {
            // Search is active (a blank query would keep `visible`) but nothing
            // in this tab matches. Clearing the query restores the full list.
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                switch layout {
                case .flat(let threads):
                    // Favorites tab: one flat, newest-first list, no folder chrome.
                    rows(threads)
                case .sectioned(let sections):
                    ForEach(sections) { rendered in
                        if rendered.isFolder {
                            folderSection(rendered)
                        } else {
                            // Loose day rows: today / yesterday / the one weekday.
                            Section(rendered.section.title()) {
                                rows(rendered.threads)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A month bucket as a collapsible folder. Rendered as a `DisclosureGroup`
    /// (not a bare `Section(isExpanded:)`, whose header isn't tappable in this
    /// grouped list style — that was the dead-tap bug) so it has a built-in,
    /// reliably-tappable disclosure chevron that reflects the open/closed state.
    /// Collapsed by default; collapsed hides the member rows entirely. The header
    /// reads as a light grouped container (a folder glyph + month name + the
    /// deterministic count/date-range summary), not a flat dark section bar.
    @ViewBuilder
    private func folderSection(_ rendered: RenderedThreadSection) -> some View {
        let header = folderHeader(for: rendered, calendar: .current, locale: .current)
        Section {
            DisclosureGroup(isExpanded: folderBinding(for: rendered)) {
                rows(rendered.threads)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                        .imageScale(.medium)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.title)
                            .font(.headline)
                        Text(header.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(header.title), \(header.summary)")
            }
        }
    }

    /// The shared row list for a set of threads — used by both the flat Favorites
    /// list and each date section, so swipe-to-favorite and delete behave the same.
    @ViewBuilder
    private func rows(_ threads: [JesseThread]) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread) {
                ThreadRow(thread: thread, running: coordinator.isRunning(thread.id))
            }
            // Lazily mint/refresh this visible row's AI title. Idempotent and
            // non-blocking: it no-ops when the cached title is current or a
            // generation is already running, and degrades to the derived title
            // when the bridge has no /jesse/title.
            .onAppear { coordinator.ensureTitle(for: thread, context: context) }
            .swipeActions(edge: .leading) {
                Button { toggleFavorite(thread) } label: {
                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: thread.isFavorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
        }
        .onDelete { delete($0, in: threads) }
    }

    /// Binding a collapsible `Section` reads for its expanded state. The getter
    /// reflects the resolved layout (so an active search shows folders open); the
    /// setter records the user's manual toggle in `expandedFolders`.
    private func folderBinding(for rendered: RenderedThreadSection) -> Binding<Bool> {
        Binding(
            get: { rendered.isExpanded },
            // Route the toggle through the pure `foldersAfterToggling` so the tap
            // behavior is exactly what the unit tests pin. `open` is what the
            // disclosure control wants; flip membership only when it actually
            // differs from the current state.
            set: { open in
                if open != rendered.isExpanded {
                    expandedFolders = foldersAfterToggling(rendered.section, in: expandedFolders)
                }
            })
    }

    private func toggleFavorite(_ thread: JesseThread) {
        thread.toggleFavorite()
        do {
            try context.save()
        } catch {
            Log.run.error("favorite toggle save failed: \(error.localizedDescription)")
        }
    }

    private func newThread() {
        // Insert before pushing so the thread's identity is stable across the
        // first send (a not-yet-inserted model's id changes on insert, which
        // would confuse the navigation path). Abandoned empties — opened via +
        // but never sent to — are reaped by `pruneEmpty` on return.
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        path.append(thread)
    }

    /// The list's presentation: flat for the Favorites tab, date-sectioned with
    /// collapsible month folders for All. Pure `threadListLayout` does the
    /// grouping/folding; `now` is read once here so every thread is classified
    /// against the same instant. Favorite-filtering and search happen inside the
    /// pure function, so `visible`/`searched` above just feed the empty-state
    /// checks.
    private var layout: ThreadListLayout {
        threadListLayout(threads,
                         favoritesOnly: favoritesOnly,
                         searchQuery: searchText,
                         expanded: expandedFolders,
                         now: Date.now,
                         calendar: .current)
    }

    private func delete(_ offsets: IndexSet, in sectionThreads: [JesseThread]) {
        for index in offsets {
            let thread = sectionThreads[index]
            coordinator.cancel(thread.id)
            context.delete(thread)
        }
        do {
            try context.save()
        } catch {
            Log.run.error("thread delete save failed: \(error.localizedDescription)")
        }
    }

    /// Drop threads that were opened but never sent to (no turns) so the list
    /// doesn't accumulate empties from `+`-then-back.
    private func pruneEmpty() {
        var changed = false
        for thread in threads where thread.turns.isEmpty && !coordinator.isRunning(thread.id) {
            context.delete(thread)
            changed = true
        }
        if changed {
            do {
                try context.save()
            } catch {
                Log.run.error("pruneEmpty save failed: \(error.localizedDescription)")
            }
        }
    }
}

/// A list row: one primary line (the resolved title) and the relative
/// last-activity time — nothing else. The title is `displayTitle`: the cached AI
/// title when present (even mid-refresh — the last good title, never blank), else
/// the derived first-words title. A live spinner shows while the turn runs.
struct ThreadRow: View {
    let thread: JesseThread
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if thread.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(displayTitle(for: thread))
                        .lineLimit(1)
                }
                Text(thread.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
