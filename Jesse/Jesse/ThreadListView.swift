import SwiftUI
import SwiftData
import JesseCore

// Root screen: the list of conversations, newest first. Tapping one opens it;
// `+` starts a fresh one. Starting several and letting them run at once is just
// "compose, swipe back, compose again" — nothing blocks.
struct ThreadListView: View {
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator
    @Query(sort: \JesseThread.updatedAt, order: .reverse) private var threads: [JesseThread]
    // Every persisted outbox record; used only to badge rows with an undelivered
    // (`.failed`) message. Small and observed, so a badge appears/clears live.
    @Query private var outbox: [OutboxItem]

    @Binding var path: [JesseThread]
    @Binding var config: JesseConfig
    @Binding var showSettings: Bool
    // Set alongside `showSettings` by the first-run pairing CTA so Settings opens
    // straight to the Scan-to-pair sheet; the gear button leaves it false.
    @Binding var pairViaScanner: Bool
    // The selected conversation, bridged to the root navigation. On iPad/regular
    // width it drives the detail column of the `NavigationSplitView`; on
    // iPhone/compact the row's `NavigationLink` still owns the push, so this just
    // tracks the current thread and changes nothing about that behavior.
    @Binding var selection: JesseThread?
    // When true, a "can't reach the bridge" banner sits atop the list so the phone
    // signals offline before the user composes — mirroring the watch's `.queued`
    // state. The reachability probe lives in `ContentView`; the decision is the
    // pure `shouldShowOfflineBanner`.
    var showOfflineBanner = false

    // Which scope the list is showing, remembered across launches. All is the
    // default; Favorites narrows to starred threads; Watch narrows to threads
    // relayed from an Apple Watch. Stored as the raw string so it lightweight-adds
    // over the old boolean-favorites default (an unknown value reads as `.all`).
    enum ListScope: String, CaseIterable {
        case all, favorites, watch
        var label: String {
            switch self {
            case .all: return "All"
            case .favorites: return "Favorites"
            case .watch: return "Watch"
            }
        }
    }
    @AppStorage("threadListScope") private var scopeRaw = ListScope.all.rawValue
    private var scope: ListScope { ListScope(rawValue: scopeRaw) ?? .all }

    /// The two orthogonal filters the current scope maps to, so the pure
    /// `threadListLayout` and the empty-state checks stay expressed in the same
    /// favorites/origin terms they always were.
    private var favoritesOnly: Bool { scope == .favorites }
    private var originScope: ThreadOriginScope { scope == .watch ? .watch : .all }

    /// Thread ids with at least one undelivered (`.failed`) outbox message — drives
    /// the small orange badge on those rows.
    private var threadsWithFailedOutbox: Set<UUID> {
        Set(outbox.filter { $0.state == .failed }.map(\.threadID))
    }

    // Whether the on-device query-expansion tier is enabled (Settings toggle,
    // default ON). Off → no `expand` calls, pure Tier-1 multi-token search.
    @AppStorage("searchExpansionEnabled") private var searchExpansionEnabled = true

    // Live search text. Not persisted — a fresh launch starts with the full list.
    @State private var searchText = ""

    // Orchestrates the on-device expansion tier (debounce / gate / cache / cancel).
    // Injects the FoundationModels-backed expander in production; degrades silently
    // to Tier-1 when the model is unavailable or disabled.
    @State private var searchModel = ThreadSearchModel(expander: FoundationModelExpander())
    // Prewarm the model once per search session (on the first keystroke), reset
    // when the query clears — SwiftUI's `.searchable` focus isn't directly
    // observable here, and prewarm is idempotent.
    @State private var didPrewarm = false

    // Which month folders the user has opened, keyed by section identity. Month
    // folders default collapsed (absent here); day sections never fold. Reset on
    // launch, so old history opens closed every time.
    @State private var expandedFolders: Set<ThreadSection> = []

    /// Threads the active scope shows, before search. The All view keeps date order
    /// untouched; Favorites narrows to starred threads; Watch narrows to
    /// watch-relayed threads (no reordering or pinning in any). The two filters
    /// stack so the empty-state checks below see exactly what the layout will.
    private var visible: [JesseThread] {
        (favoritesOnly ? threads.filter(\.isFavorite) : threads)
            .filter { threadMatchesOrigin($0, scope: originScope) }
    }

    /// Base (Tier-1) matches for the TYPED query alone — used only to gate and feed
    /// the expansion tier's base count. A blank query matches everything.
    private var searched: [JesseThread] {
        visible.filter { threadMatches($0, query: searchText) }
    }

    /// The active alternate terms, or none when the tier is disabled.
    private var activeTerms: [String] {
        searchExpansionEnabled ? searchModel.activeTerms : []
    }

    /// The UNION query list the layout and row snippets filter on: the typed query
    /// plus any active expansion terms. With no terms this is just `[searchText]`,
    /// which reduces to Tier-1-only.
    private var activeQueries: [String] { [searchText] + activeTerms }

    /// Whether search is active (the typed query is non-blank).
    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The union match set (query + terms) — what actually shows; drives the
    /// no-results empty state so an expansion-only match still counts as a result.
    private var unionMatched: [JesseThread] {
        visible.filter { threadMatchesAny($0, queries: activeQueries) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showOfflineBanner {
                offlineBanner
            }
            // Only meaningful once there's at least one conversation to filter.
            if !threads.isEmpty {
                Picker("Filter", selection: $scopeRaw) {
                    ForEach(ListScope.allCases, id: \.rawValue) { scope in
                        Text(scope.label).tag(scope.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            // When the on-device tier widens the search, explain the extra rows:
            // a related conversation containing none of the typed words is here
            // because of these alternate terms. Clears with the query / no terms.
            if searchActive && !activeTerms.isEmpty {
                Text("Also searching: \(activeTerms.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            content
        }
        .searchable(text: $searchText, prompt: "Search conversations")
        .onChange(of: searchText) { _, newValue in
            driveSearchExpansion(for: newValue)
        }
        .onChange(of: searchExpansionEnabled) { _, _ in
            // Toggling the tier re-drives the model (which clears itself when off).
            driveSearchExpansion(for: searchText)
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

    /// "Can't reach the bridge" bar atop the list — the phone's echo of the watch's
    /// `.queued` state, warning offline before the user composes. Warning-orange to
    /// match the recoverable-error styling in the transcript.
    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Can’t reach your Jesse bridge — check that your Mac is on and connected.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        if threads.isEmpty {
            // First-run gate: an unpaired user's first send would just error, so
            // steer them to pairing instead of "Tap + to start". The decision is
            // the pure, unit-tested `threadListEmptyState(for:)`.
            switch threadListEmptyState(for: config) {
            case .pairBridge:
                ContentUnavailableView {
                    Label("Pair with your Jesse bridge", systemImage: "qrcode.viewfinder")
                } description: {
                    Text("Jesse runs on your Mac. Scan the pairing code it prints on startup to connect — your first message needs a paired bridge.")
                } actions: {
                    Button {
                        pairViaScanner = true
                        showSettings = true
                    } label: {
                        Label("Scan to pair", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .noConversations:
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tap + to start one.")
                }
            }
        } else if visible.isEmpty {
            // A scope filter is on but nothing matches it yet. The picker above
            // stays visible so you can switch back to All.
            switch scope {
            case .watch:
                ContentUnavailableView {
                    Label("No watch conversations yet", systemImage: "applewatch")
                } description: {
                    Text("Turns relayed from your Apple Watch will appear here.")
                }
            default:
                ContentUnavailableView {
                    Label("No favorites yet", systemImage: "star")
                } description: {
                    Text("Swipe a conversation and tap Favorite to star it.")
                }
            }
        } else if unionMatched.isEmpty {
            // Search is active (a blank query would keep `visible`) but nothing
            // in this tab matches — not the typed query nor any expansion term.
            // Clearing the query restores the full list.
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $selection) {
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
                // Pass the active query list ONLY while searching, so the row shows
                // its matched-snippet second line during search and reverts to
                // title+time when idle (the search-only exception to #22).
                ThreadRow(thread: thread,
                          running: coordinator.isRunning(thread.id),
                          hasFailedOutbox: threadsWithFailedOutbox.contains(thread.id),
                          searchQueries: searchActive ? activeQueries : [])
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
                         originScope: originScope,
                         searchQueries: activeQueries,
                         expanded: expandedFolders,
                         now: Date.now,
                         calendar: .current)
    }

    /// Feed the live query into the expansion model: prewarm once per session on
    /// the first keystroke, then debounce/gate/cache/cancel inside the model. The
    /// base-match count is the Tier-1 hit count for the typed query, so the model
    /// only spends the on-device model when direct results are thin. When the tier
    /// is disabled this is a no-op (pure Tier-1 search, zero `expand` calls).
    private func driveSearchExpansion(for query: String) {
        // Keep the model's master switch in sync with Settings; when off it clears
        // itself and `update` becomes a no-op (zero expander calls).
        searchModel.isEnabled = searchExpansionEnabled
        guard searchExpansionEnabled else { didPrewarm = false; return }
        if query.isEmpty {
            didPrewarm = false
        } else if !didPrewarm {
            searchModel.prewarm()
            didPrewarm = true
        }
        searchModel.update(query: query, baseMatchCount: searched.count)
    }

    private func delete(_ offsets: IndexSet, in sectionThreads: [JesseThread]) {
        for index in offsets {
            let thread = sectionThreads[index]
            coordinator.cancel(thread.id)
            // If the thread had a bridge session, durably enqueue its remote deletion
            // (DELETE /jesse/session/{id}) BEFORE the local delete reads it — the
            // local SwiftData delete stays instant; the remote reclaim is best-effort
            // and retried on the next foreground if the laptop is asleep now.
            if let sessionId = thread.sessionId, !sessionId.isEmpty {
                coordinator.enqueueSessionDeletion(sessionId)
            }
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

/// A list row. Idle, it's one primary line (the resolved title) and the relative
/// last-activity time — nothing else (PR #22). While a search is active
/// (`searchQueries` non-empty) the second line becomes a matched-text SNIPPET with
/// the matched range(s) highlighted, so a hit — including one surfaced only by an
/// expansion term — explains itself; this is a deliberate search-only exception,
/// not a permanent preview line. The title is `displayTitle`: the cached AI title
/// when present (even mid-refresh — the last good title, never blank), else the
/// derived first-words title. A live spinner shows while the turn runs.
struct ThreadRow: View {
    let thread: JesseThread
    let running: Bool
    /// Whether this thread has any undelivered (`.failed`) outbox message — shows a
    /// small orange badge so the list surfaces "something didn't send" at a glance.
    var hasFailedOutbox: Bool = false
    /// The active query list (typed query + expansion terms) while searching; empty
    /// when search is idle. Non-empty switches the second line to the snippet.
    var searchQueries: [String] = []

    private var snippet: SearchSnippet? {
        searchSnippet(for: thread, queries: searchQueries)
    }

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
                if let snippet {
                    // Search-only: the matched excerpt, matched terms emphasized.
                    Text(highlighted(snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(thread.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasFailedOutbox {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Undelivered message")
            }
            if running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// Build an `AttributedString` from a snippet, emphasizing the matched range(s)
    /// (bold + accent tint) so the term that caused the match stands out.
    private func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.text)
        for range in snippet.ranges {
            guard let lo = AttributedString.Index(range.lowerBound, within: attributed),
                  let hi = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            attributed[lo..<hi].font = .caption.bold()
            attributed[lo..<hi].foregroundColor = .accentColor
        }
        return attributed
    }
}
