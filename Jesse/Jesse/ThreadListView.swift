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
                    ForEach(threads) { thread in
                        NavigationLink(value: thread) {
                            ThreadRow(thread: thread, running: coordinator.isRunning(thread.id))
                        }
                    }
                    .onDelete(perform: delete)
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

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let thread = threads[index]
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
