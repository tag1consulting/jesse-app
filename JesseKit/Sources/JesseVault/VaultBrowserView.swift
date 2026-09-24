import Foundation
import Observation
import SwiftUI

// THE VAULT AS A SCREEN: a field, a list, and a note one tap away — with the bridge off.
//
// The orchestration is the conversation list's, deliberately: debounce the typing, run the
// typed query alone first, and only ask the on-device model for alternates when the direct
// hits are thin (`SearchQueryRules.shouldExpand`). What is different is where the answer
// comes from — an FTS5 index over the folder on this device rather than a scan of rows in
// memory — and that the empty state is USEFUL: with nothing typed it shows the 30 most
// recently modified notes, which on any given morning is most of what a person wants.
//
// One view set, both platforms, for the reason the Ops screens and the day screen are
// shared: two copies are two answers to the same question.

/// The Vault tab's state.
@MainActor
@Observable
public final class VaultBrowserModel {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The live query. Bound straight to `.searchable`.
    public var query: String = ""

    /// **What the tab is looking at.** `.all` is the default and always will be: the
    /// Vault tab's promise is every note on the device, and a scope remembered across
    /// launches would be a search that silently answered a narrower question than the
    /// one that was typed. Per session, like the day screen's sort.
    public var scope: VaultSearchScope = .all {
        didSet {
            guard oldValue != scope else { return }
            refresh()
            search()
        }
    }

    public private(set) var hits: [VaultSearchHit] = []
    public private(set) var recents: [VaultIndexedFile] = []
    /// Set when expansion terms actually contributed a hit the typed query missed.
    public private(set) var expansionCaption: String?
    public private(set) var isSearching = false
    public private(set) var lastError: String?
    public private(set) var folderStatus: VaultFolderStatus = .notSet
    public private(set) var counts = VaultIndexCounts()
    /// The last base-query latency, shown on the diagnostics screen and nowhere else.
    public private(set) var lastSearchSeconds: TimeInterval = 0

    public let indexer: VaultIndexer

    private let source: VaultIndexSource
    private let expander: any VaultQueryExpanding
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    /// The query the published hits belong to, so a slow expansion for an abandoned query
    /// can never be applied.
    private var appliedQuery = ""

    /// `expander` defaults to the INERT one. Production injects the app's real on-device
    /// expander from the view, exactly as `MacRootView` does for the conversation list: a
    /// real model must never be constructible from a test-reachable default.
    public init(source: VaultIndexSource = .shared,
                indexer: VaultIndexer? = nil,
                expander: any VaultQueryExpanding = NoVaultExpansion(),
                debounce: Duration = .milliseconds(150)) {
        self.source = source
        self.indexer = indexer ?? VaultIndexer(source: source)
        self.expander = expander
        self.debounce = debounce
    }

    /// Whether a folder is held at all. Everything on the screen hangs off this.
    public var hasFolder: Bool { folderStatus.isReady }

    /// The 30 most recently modified notes, the index's counts, and the folder's status.
    /// Cheap enough to run on every appearance.
    public func refresh() {
        folderStatus = source.folderStatus
        guard folderStatus.isReady else {
            recents = []
            counts = VaultIndexCounts()
            return
        }
        do {
            guard let index = try source.index() else { return }
            // Asked for more than are shown when a scope excludes a subfolder, so the
            // thirty are thirty after `Strands/archive/` is dropped rather than before.
            let scope = self.scope
            let wanted = scope.pathPrefix == nil ? 30 : 60
            recents = Array(index.recentFiles(limit: wanted, underPrefix: scope.pathPrefix)
                .filter { scope.includes($0.path) }
                .prefix(30))
            counts = index.counts()
            lastError = nil
        } catch {
            lastError = VaultIndexer.describe(error)
            return
        }
        // A strand's own `updated:` stamp outranks its mtime — see `VaultStrandOrder`.
        // Done as a second pass rather than in the query because the stamp is inside the
        // note and the index does not hold it: fifteen small reads, off the main actor,
        // and the list is already on screen in mtime order while they happen.
        if scope.ordersByFrontmatterUpdated { applyFrontmatterOrder(for: scope) }
    }

    /// Re-sort the recents by each note's `updated:` frontmatter.
    ///
    /// Guarded on the scope it started under, so an answer for `Strands` cannot land on
    /// a list the user has since switched back to `All`.
    private func applyFrontmatterOrder(for scope: VaultSearchScope) {
        let files = recents
        guard !files.isEmpty else { return }
        let source = self.source
        Task { [weak self] in
            let stamps = await Task.detached { () -> [String: String] in
                // EVERY read inside one `withAccess`: the security scope it opens is
                // closed the moment the closure returns, so carrying the root out and
                // reading afterwards would read a folder nothing is entitled to.
                (try? source.vaultFolder.withAccess { root -> [String: String] in
                    var out: [String: String] = [:]
                    let reader = VaultFile(root: root)
                    for file in files {
                        guard let text = try? reader.read(relativePath: file.path),
                              let updated = VaultFrontmatter.value(for: "updated", in: text)
                        else { continue }
                        out[file.path] = updated
                    }
                    return out
                }) ?? [:]
            }.value
            guard let self, self.scope == scope, self.recents == files else { return }
            self.recents = VaultStrandOrder.ordered(files, updated: stamps)
        }
    }

    /// Feed the live query. Safe to call on every keystroke.
    public func search() {
        let typed = query
        searchTask?.cancel()
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            expansionCaption = nil
            isSearching = false
            appliedQuery = ""
            return
        }
        guard folderStatus.isReady else { return }
        isSearching = true
        let scope = self.scope
        let source = self.source
        let expander = self.expander
        let debounce = self.debounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            let outcome: VaultSearchOutcome? = await Task.detached { [scope] in
                guard let index = try? source.index() else { return nil }
                return await VaultSearcher(index: index, scope: scope)
                    .search(typed, expander: expander)
            }.value
            if Task.isCancelled { return }
            self?.apply(outcome, for: typed)
        }
    }

    /// Await whatever search is in flight. A test hook, and the reason the model is
    /// assertable without a view host.
    public func awaitPendingSearch() async {
        await searchTask?.value
    }

    private func apply(_ outcome: VaultSearchOutcome?, for typed: String) {
        // The user has typed on since this search started: its answer is about a question
        // nobody is asking any more.
        guard typed == query else { return }
        isSearching = false
        appliedQuery = typed
        guard let outcome else {
            hits = []
            expansionCaption = nil
            return
        }
        hits = outcome.hits
        expansionCaption = outcome.expansionCaption
        lastSearchSeconds = outcome.baseDuration
    }
}

/// The Vault screen: search, results, and the reader.
public struct VaultBrowserView: View {
    @State private var model: VaultBrowserModel
    @State private var path: [VaultNoteRoute] = []

    public init(model: VaultBrowserModel = VaultBrowserModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Vault")
                // INSIDE the stack, on the root's own content: a `.searchable` hung on the
                // `NavigationStack` itself is a field whose placement depends on what is
                // pushed, which is not what a search field should do.
                .searchable(text: $model.query, prompt: "Search every note")
                .navigationDestination(for: VaultNoteRoute.self) { route in
                    VaultNoteReaderView(route: route) { next in
                        path.append(next)
                    }
                }
        }
        .onChange(of: model.query) { _, _ in model.search() }
        .task {
            model.refresh()
            // The one automatic reindex: coming to this screen is the strongest signal
            // there is that the index is about to be read. Debounced, so arriving twice in
            // a minute costs one walk.
            model.indexer.reindexIfDue()
        }
        // ON EVERY RETURN TO THE TAB, not only the first. A tab bar keeps its tabs mounted,
        // so `.task` runs once per launch — and the folder is picked in SETTINGS, which is a
        // different tab. Without this, a user who picks the folder and comes back here is
        // told there is no folder until the next launch. It costs a bookmark resolve and two
        // COUNT queries.
        .onAppear { model.refresh() }
        // An index that finished has both new counts AND new answers: a query typed while
        // the first index was still running must not be left showing the empty result it
        // legitimately had thirty seconds ago.
        .onChange(of: model.indexer.lastReport) { _, _ in
            model.refresh()
            model.search()
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if !model.hasFolder {
                noFolder
            } else {
                if model.indexer.isIndexing {
                    indexingRow
                } else if model.counts.fileCount == 0 {
                    emptyIndexRow
                }
                if let caption = model.expansionCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // UNDER the search field, above everything it narrows, because it
                // qualifies both lists below it and not only the typed one: with
                // nothing typed it says which notes the recents are drawn from.
                scopeControl
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        ForEach(model.recents, id: \.path) { file in
                            recentRow(file)
                        }
                    } header: {
                        Text(Self.recentsHeading(model.scope))
                    }
                } else if model.hits.isEmpty {
                    Section {
                        Text(model.isSearching
                             ? "Searching…"
                             : "No note in this copy of the vault has all of those words.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(model.hits) { hit in
                            hitRow(hit)
                        }
                    } header: {
                        Text(Self.resultsHeading(model.hits.count))
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
    }

    static func resultsHeading(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }

    /// What the recents section is called under each scope. The Strands scope says
    /// "Recently updated" rather than "Recently changed" because it is ordered by the
    /// notes' own `updated:` stamps and not by when the files were touched, and a
    /// heading that claimed otherwise would be the one line on the screen that lies.
    /// `nonisolated` because it is a pure function of its argument and a test has no
    /// business hopping to the main actor to ask what a heading says.
    nonisolated static func recentsHeading(_ scope: VaultSearchScope) -> String {
        scope == .strands ? "Recently updated" : "Recently changed"
    }

    /// The scope control: two segments, and no folder picker.
    private var scopeControl: some View {
        Picker("Scope", selection: Bindable(model).scope) {
            ForEach(VaultSearchScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Search scope")
    }

    private var noFolder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No vault folder yet", systemImage: "folder.badge.questionmark")
                .font(.headline)
            Text("Point Jesse at the Obsidian copy of your vault in Settings, and every note becomes searchable on this device — with or without the bridge.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.folderStatus.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var indexingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                Text("Indexing the vault…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.indexer.progress)
        }
        .listRowSeparator(.hidden)
    }

    private var emptyIndexRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing is indexed yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Index the vault now") {
                Task { await model.indexer.reindexNow() }
            }
        }
        .listRowSeparator(.hidden)
    }

    private func recentRow(_ file: VaultIndexedFile) -> some View {
        Button {
            path.append(VaultNoteRoute(path: file.path))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("·")
                    Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func hitRow(_ hit: VaultSearchHit) -> some View {
        Button {
            path.append(VaultNoteRoute(path: hit.path, line: hit.line))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !hit.heading.isEmpty {
                        Text(hit.heading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(hit.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(VaultNoteRenderer.snippet(hit.snippet))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hit.title), line \(hit.line)")
    }
}
