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
                ForEach(groupedSections) { group in
                    Section(group.section.title()) {
                        ForEach(group.threads) { thread in
                            NavigationLink(value: thread) {
                                ThreadRow(thread: thread, running: coordinator.isRunning(thread.id))
                            }
                            .swipeActions(edge: .leading) {
                                Button { toggleFavorite(thread) } label: {
                                    Label(thread.isFavorite ? "Unfavorite" : "Favorite",
                                          systemImage: thread.isFavorite ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                            }
                        }
                        .onDelete { delete($0, in: group.threads) }
                    }
                }
            }
        }
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

    /// Threads bucketed into date sections, sections newest-first. Threads keep
    /// the `@Query`'s `updatedAt`-descending order within each section because
    /// `Dictionary(grouping:)` preserves source order per group. `now` is read
    /// once here so every thread is classified against the same instant.
    private var groupedSections: [ThreadGroup] {
        let now = Date.now
        let grouped = Dictionary(grouping: searched) {
            threadSection(for: $0.updatedAt, now: now, calendar: .current)
        }
        return grouped
            .map { ThreadGroup(section: $0.key, threads: $0.value) }
            .sorted { $0.section.sortKey > $1.section.sortKey }
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

/// One date-bucketed section of the list. `ThreadSection` is its stable
/// identity, so SwiftUI re-renders correctly as threads move between buckets.
private struct ThreadGroup: Identifiable {
    let section: ThreadSection
    let threads: [JesseThread]
    var id: ThreadSection { section }
}

/// A list row: title, relative last-activity time, and a live dot while running.
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
                    Text(thread.title.isEmpty ? "New conversation" : thread.title)
                        .lineLimit(1)
                }
                // Second line: where the conversation actually went — a snippet
                // of the latest turn. The derived title (line 1) is never touched;
                // this only augments it. Hidden when empty (no turns) or when it
                // would just repeat the title (a single, untruncated user turn).
                let preview = rowPreview(for: thread)
                if !preview.isEmpty && preview != thread.title {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
