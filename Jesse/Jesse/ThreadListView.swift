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

    var body: some View {
        Group {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tap + to start one.")
                }
            } else {
                List {
                    ForEach(groupedSections) { group in
                        Section(group.section.title()) {
                            ForEach(group.threads) { thread in
                                NavigationLink(value: thread) {
                                    ThreadRow(thread: thread, running: coordinator.isRunning(thread.id))
                                }
                            }
                            .onDelete { delete($0, in: group.threads) }
                        }
                    }
                }
            }
        }
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
        let grouped = Dictionary(grouping: threads) {
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
        try? context.save()
    }

    /// Drop threads that were opened but never sent to (no turns) so the list
    /// doesn't accumulate empties from `+`-then-back.
    private func pruneEmpty() {
        var changed = false
        for thread in threads where thread.turns.isEmpty && !coordinator.isRunning(thread.id) {
            context.delete(thread)
            changed = true
        }
        if changed { try? context.save() }
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
                Text(thread.title.isEmpty ? "New conversation" : thread.title)
                    .lineLimit(1)
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
