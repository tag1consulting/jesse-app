import SwiftUI
import SwiftData
import JesseCore

// The Mac shell: a NavigationSplitView with the thread list on the left and the
// selected conversation on the right — the big-screen affordance the plan calls for
// (list + detail, full keyboard, wide layout). The list renders from the local store
// (cache-first: instant paint, works offline) and reconciles from `GET /jesse/sessions`
// in the background; phone-started threads appear via that server list.

struct MacRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(MacCoordinator.self) private var coordinator

    /// Threads newest-first. Favorites could sort first later; MVP is by activity.
    @Query(sort: \JesseThread.updatedAt, order: .reverse) private var threads: [JesseThread]

    @State private var selection: UUID?
    @State private var showingSettings = false

    /// Store-open failure banner (in-memory fallback — history not being saved).
    var storeError: Error?

    private var selectedThread: JesseThread? {
        threads.first { $0.id == selection }
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
            ForEach(threads) { thread in
                MacThreadRow(thread: thread, running: coordinator.isRunning(thread.id))
                    .tag(thread.id)
            }
            .onDelete(perform: deleteThreads)
        }
        .overlay {
            if threads.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(coordinator.configStore.isConfigured
                        ? "Start one with the compose button, or pull your phone’s threads with Refresh."
                        : "Connect to your bridge in Settings to begin."))
            }
        }
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
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func newChat() {
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try? context.save()
        selection = thread.id
    }

    private func deleteThreads(_ offsets: IndexSet) {
        for index in offsets { context.delete(threads[index]) }
        try? context.save()
    }
}

/// One sidebar row: the best title we have (server AI title > derived first-message),
/// with a subtitle preview and a running spinner.
struct MacThreadRow: View {
    let thread: JesseThread
    let running: Bool

    private var displayTitle: String {
        if let ai = thread.aiTitle, !ai.isEmpty { return ai }
        if !thread.title.isEmpty { return thread.title }
        return "New conversation"
    }

    var body: some View {
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
