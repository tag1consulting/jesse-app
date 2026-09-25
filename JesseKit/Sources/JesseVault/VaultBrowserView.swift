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
    public var scope: VaultSearchScope {
        get { scopeStorage }
        set {
            guard newValue != scopeStorage else { return }
            scopeStorage = newValue
            // THE TWO NARROWINGS ARE EXCLUSIVE. A segment is a CURATED view — `Strands`
            // drops the archive and orders by each note's own stamp — and a picked folder
            // is the raw folder, nothing added and nothing hidden. Held together they
            // would show the intersection of two things the screen states separately,
            // and the commonest intersection is empty.
            if newValue != .all { folderStorage = nil }
            // The chips and the strand token belong to the Strands scope and are drawn
            // only under it, so leaving it drops them rather than leaving a narrowing
            // held that no control on screen admits to.
            if newValue != .strands {
                sectionStorage = .all
                strandStorage = nil
            }
            reanswer()
        }
    }

    /// **The section chip.** `.all` is the scope's ordinary one-row-per-note view; any
    /// other section turns every result into LINES of that section (`sectionLines`).
    /// Choosing one moves the tab to the Strands scope, the only one it means anything in.
    public var section: VaultStrandSection {
        get { sectionStorage }
        set {
            guard newValue != sectionStorage else { return }
            sectionStorage = newValue
            if newValue != .all { moveToStrands() }
            reanswer()
        }
    }

    /// **The one strand the scope is narrowed to**, as a vault relative path under
    /// `Strands/` (the archive included), or nil for every strand. Per launch, for
    /// `scope`'s reason.
    public var strand: String? {
        get { strandStorage }
        set {
            guard newValue != strandStorage else { return }
            strandStorage = newValue
            if newValue != nil { moveToStrands() }
            reanswer()
        }
    }

    /// Whether results are lines of one section rather than notes.
    public var isSectionMode: Bool { scopeStorage == .strands && sectionStorage != .all }

    /// **Open the tab already narrowed**: one strand by its slug (`Jesse`, or
    /// `Strands/archive/Dev-Agents-On-K3s`), and optionally one section of it. The
    /// entry point for anything outside this view that wants to show a strand's record.
    ///
    /// Returns false, and changes nothing, when no strand note has that slug, so a
    /// caller holding a stale name cannot leave the tab narrowed to nothing.
    @discardableResult
    public func showStrand(_ slug: String, section: VaultStrandSection = .all) -> Bool {
        if strandNotes.isEmpty { refresh() }
        guard let path = VaultStrandRecord.path(forSlug: slug,
                                                among: strandNotes.map(\.path)) else {
            return false
        }
        query = ""
        moveToStrands()
        sectionStorage = section
        strandStorage = path
        reanswer()
        return true
    }

    /// The scope a chip or a strand implies, set without the scope setter's own reset.
    private func moveToStrands() {
        scopeStorage = .strands
        folderStorage = nil
    }

    /// **The folder the tab is narrowed to**, or nil for the whole vault. A vault
    /// relative path with no trailing slash, as `VaultFolderTree` produces it.
    ///
    /// NOT to be confused with `folderStatus` and `hasFolder` a few lines down, which are
    /// about something else entirely: whether this device has been pointed at a vault at
    /// all. That one is the root; this one is a folder inside it.
    ///
    /// Per launch, deliberately, for `scope`'s reason: a narrowing remembered across
    /// launches is a search that silently answers a narrower question than the one that
    /// was typed, weeks after the person who chose it has forgotten choosing it.
    public var folder: String? {
        get { folderStorage }
        set {
            guard newValue != folderStorage else { return }
            folderStorage = newValue
            if newValue != nil {
                scopeStorage = .all
                sectionStorage = .all
                strandStorage = nil
            }
            reanswer()
        }
    }

    /// Every folder in the index, with its count — what the picker lists.
    ///
    /// Refilled by `refresh()`, so it follows a reindex without being asked and without a
    /// second path for the picker to go stale down. That costs one `SELECT path FROM
    /// files` and a fold over the result on every appearance, which is within the
    /// envelope `refresh()` already has: the `counts()` call beside it does three
    /// `count(*)`s, one of them over the chunks table, which is an order of magnitude
    /// more rows than there are files.
    public private(set) var folders: [VaultFolderCount] = []

    /// Every note under `Strands/`, the archive included, by title: what the strand
    /// picker lists and what `showStrand` resolves a slug against. Refilled by `refresh()`.
    public private(set) var strandNotes: [VaultIndexedFile] = []

    private var scopeStorage: VaultSearchScope = .all
    private var folderStorage: String?
    private var sectionStorage: VaultStrandSection = .all
    private var strandStorage: String?

    /// Both states re-answer at once, because both are narrowed by the same choice and a
    /// screen showing a new folder's recents beside the old folder's hits is a screen
    /// telling two stories.
    private func reanswer() {
        refresh()
        search()
    }

    /// The chosen folder as a path prefix, with the trailing slash that keeps `Work` from
    /// matching `Workshop/`.
    private var folderPrefix: String? { folderStorage.map { $0 + "/" } }

    public private(set) var hits: [VaultSearchHit] = []
    public private(set) var recents: [VaultIndexedFile] = []
    /// Under the Strands scope, the notes in `Strands/archive/`, kept out of `recents`
    /// so the screen can put them under their own collapsed header. Always empty under
    /// any other scope or folder.
    public private(set) var archivedRecents: [VaultIndexedFile] = []
    /// Each strand note's `state:` frontmatter, keyed by path, for the caption a row
    /// shows when it is not `active`. Filled by the same pass that reads `updated:`.
    public private(set) var strandStates: [String: String] = [:]
    /// Section mode's rows: the matching lines, or with nothing typed the section's log.
    public private(set) var sectionLines: [VaultSectionLine] = []
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
            archivedRecents = []
            strandNotes = []
            folders = []
            counts = VaultIndexCounts()
            return
        }
        do {
            guard let index = try source.index() else { return }
            folders = index.folders()
            counts = index.counts()
            lastError = nil
            // A FOLDER CAN GO. It was deleted or renamed in Obsidian, the reindex noticed,
            // and the tab is now narrowed to a folder that does not exist — which shows as
            // an empty screen with no reason given. Widen back to the whole vault and SAY
            // SO. Guarded on a non-empty index, because before the first pass every folder
            // is missing and none of them have gone anywhere.
            if let held = folderStorage, counts.fileCount > 0,
               !folders.contains(where: { $0.path == held }) {
                folderStorage = nil
                lastError = "\(held) is not in the vault any more, so every note is showing."
            }
            strandNotes = index.recentFiles(limit: 1_000, underPrefix: VaultStrandRecord.folder)
                .sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            // A HELD STRAND CAN GO, for a folder's reason: renamed, or deleted. Widen to
            // every strand and say so rather than show one empty row.
            if let held = strandStorage, counts.fileCount > 0,
               !strandNotes.contains(where: { $0.path == held }) {
                strandStorage = nil
                lastError = "\(VaultStrandRecord.slug(of: held)) is not in the vault any more, so every strand is showing."
            }
            let scope = self.scopeStorage
            if scope == .strands, folderStorage == nil {
                // EVERY strand, not a recent thirty: the scope is the record, and the
                // archive under its header is only useful whole. Two dozen live notes
                // and a growing archive, all from one indexed prefix query.
                let all = strandNotes.filter { note in strandStorage.map { note.path == $0 } ?? true }
                    .sorted { $0.modified > $1.modified }
                if strandStorage != nil {
                    recents = all
                    archivedRecents = []
                } else {
                    recents = all.filter { !VaultStrandRecord.isArchived($0.path) }
                    archivedRecents = all.filter { VaultStrandRecord.isArchived($0.path) }
                }
            } else {
                let prefix = folderPrefix ?? scope.pathPrefix
                recents = Array(index.recentFiles(limit: 30, underPrefix: prefix)
                    .filter { scope.includes($0.path) })
                archivedRecents = []
            }
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
        let archived = archivedRecents
        guard !(files.isEmpty && archived.isEmpty) else { return }
        let source = self.source
        Task { [weak self] in
            typealias Stamps = (updated: [String: String], state: [String: String])
            let stamps = await Task.detached { () -> Stamps in
                // EVERY read inside one `withAccess`: the security scope it opens is
                // closed the moment the closure returns, so carrying the root out and
                // reading afterwards would read a folder nothing is entitled to.
                (try? source.vaultFolder.withAccess { root -> Stamps in
                    var updated: [String: String] = [:]
                    var state: [String: String] = [:]
                    let reader = VaultFile(root: root)
                    for file in files + archived {
                        guard let text = try? reader.read(relativePath: file.path)
                        else { continue }
                        updated[file.path] = VaultFrontmatter.value(for: "updated", in: text)
                        state[file.path] = VaultFrontmatter.value(for: "state", in: text)
                    }
                    return (updated, state)
                }) ?? ([:], [:])
            }.value
            guard let self, self.scope == scope, self.recents == files,
                  self.archivedRecents == archived else { return }
            self.recents = VaultStrandOrder.ordered(files, updated: stamps.updated)
            self.archivedRecents = VaultStrandOrder.ordered(archived, updated: stamps.updated)
            self.strandStates = stamps.state
        }
    }

    /// Feed the live query. Safe to call on every keystroke.
    public func search() {
        let typed = query
        searchTask?.cancel()
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSectionMode {
            searchSection(typed)
            return
        }
        sectionLines = []
        guard !trimmed.isEmpty else {
            hits = []
            expansionCaption = nil
            isSearching = false
            appliedQuery = ""
            return
        }
        guard folderStatus.isReady else { return }
        isSearching = true
        let scope = self.scopeStorage
        let folder = self.folderStorage
        let strand = self.strandStorage
        let source = self.source
        let expander = self.expander
        let debounce = self.debounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            let outcome: VaultSearchOutcome? = await Task.detached { [scope, folder, strand] in
                guard let index = try? source.index() else { return nil }
                return await VaultSearcher(index: index, scope: scope, folder: folder,
                                           strand: strand)
                    .search(typed, expander: expander)
            }.value
            if Task.isCancelled { return }
            self?.apply(outcome, for: typed, scope: scope, folder: folder, strand: strand)
        }
    }

    /// Section mode's search, and its empty-query log, through one path: both read the
    /// same folder and both are stale the moment the section, the strand or the query
    /// moves. Not debounced when nothing is typed, because a chip tap is not typing.
    private func searchSection(_ typed: String) {
        hits = []
        expansionCaption = nil
        guard folderStatus.isReady else {
            sectionLines = []
            return
        }
        isSearching = true
        let section = sectionStorage
        let strand = strandStorage
        let source = self.source
        let debounce = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Duration.zero : self.debounce
        searchTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            if Task.isCancelled { return }
            let started = Date()
            let lines: [VaultSectionLine] = await Task.detached {
                guard let index = try? source.index() else { return [] }
                return VaultSearcher(index: index, scope: .strands, strand: strand)
                    .sectionLines(typed, section: section)
            }.value
            if Task.isCancelled { return }
            guard let self, typed == self.query, self.scopeStorage == .strands,
                  section == self.sectionStorage, strand == self.strandStorage else { return }
            self.isSearching = false
            self.appliedQuery = typed
            self.sectionLines = lines
            self.lastSearchSeconds = Date().timeIntervalSince(started)
        }
    }

    /// Await whatever search is in flight. A test hook, and the reason the model is
    /// assertable without a view host.
    public func awaitPendingSearch() async {
        await searchTask?.value
    }

    private func apply(_ outcome: VaultSearchOutcome?, for typed: String,
                       scope: VaultSearchScope, folder: String?, strand: String?) {
        // The user has typed on since this search started: its answer is about a question
        // nobody is asking any more.
        guard typed == query else { return }
        // OR HAS NARROWED SINCE. The same reasoning and a worse symptom: an in-flight
        // search for the whole vault landing on a screen that now says one folder puts
        // rows from outside that folder under a heading naming it, which reads as the
        // narrowing being broken rather than as a stale answer.
        guard scope == scopeStorage, folder == folderStorage, strand == strandStorage,
              !isSectionMode else { return }
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
    @State private var isPickingFolder = false
    /// The picker's own filter. Not the vault query: this one filters the LIST OF
    /// FOLDERS by name, and it is reset every time the sheet opens so that a sheet never
    /// opens already hiding most of what it is there to show.
    @State private var folderFilter = ""
    @State private var isPickingStrand = false
    /// The strand picker's own filter, reset on every open for `folderFilter`'s reason.
    @State private var strandFilter = ""
    /// The Archived header starts closed: the record is there when asked for, and the
    /// live strands stay the first thing on the screen.
    @State private var showsArchived = false

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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { folderButton }
                }
                .sheet(isPresented: $isPickingFolder) {
                    folderPicker
                }
                .sheet(isPresented: $isPickingStrand) {
                    strandPicker
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
                //
                // ONE narrowing widget at a time. The segmented control offers curated
                // views; a picked folder is a raw folder. Showing both at once would put
                // a control reading "All" above a list that is anything but.
                if let folder = model.folder {
                    folderScopeRow(folder)
                } else {
                    scopeControl
                    if model.scope == .strands { strandControls }
                }
                if model.isSectionMode {
                    sectionContent
                } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        if model.recents.isEmpty, let folder = model.folder {
                            // A folder with nothing in it must still say something: an
                            // empty list under a heading naming the folder reads as a
                            // broken screen rather than as an empty folder.
                            Text(Self.emptyFolderSentence(folder))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.recents, id: \.path) { file in
                            recentRow(file)
                        }
                    } header: {
                        Text(Self.recentsHeading(model.scope, folder: model.folder))
                    }
                    if !model.archivedRecents.isEmpty {
                        Section {
                            if showsArchived {
                                ForEach(model.archivedRecents, id: \.path) { file in
                                    recentRow(file)
                                }
                            }
                        } header: {
                            archivedHeader
                        }
                    }
                } else if model.hits.isEmpty {
                    Section {
                        Text(model.isSearching
                             ? "Searching…"
                             : Self.emptyResultSentence(folder: model.folder))
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

    /// Section mode: the section's lines, one row each. With nothing typed, its log.
    @ViewBuilder
    private var sectionContent: some View {
        let typed = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Section {
            if model.sectionLines.isEmpty {
                Text(model.isSearching
                     ? "Searching…"
                     : Self.emptySectionSentence(model.section, typed: typed))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sectionLines) { line in
                lineRow(line)
            }
        } header: {
            Text(Self.sectionHeading(model.section, typed: typed,
                                     count: model.sectionLines.count,
                                     strand: model.strand.map(strandTitle)))
        }
    }

    /// What a section view is called. Named for what it is: with nothing typed, the
    /// newest lines of a log; with a query, a count of lines, not of notes.
    nonisolated static func sectionHeading(_ section: VaultStrandSection, typed: Bool,
                                           count: Int, strand: String? = nil) -> String {
        let place = strand.map { "in \($0)" } ?? "across strands"
        if typed {
            let lines = count == 1 ? "1 line" : "\(count) lines"
            return "\(lines) in \(section.label) \(place)"
        }
        return "Latest \(section.label) \(place)"
    }

    nonisolated static func emptySectionSentence(_ section: VaultStrandSection,
                                                 typed: Bool) -> String {
        typed
            ? "No line under \(section.label) has all of those words."
            : "No dated line under \(section.label) yet."
    }

    /// The caption a strand row carries when its `state:` is not `active`, or nil.
    nonisolated static func stateCaption(_ state: String?) -> String? {
        guard let state = state?.trimmingCharacters(in: .whitespaces), !state.isEmpty,
              state.lowercased() != "active" else { return nil }
        return state.lowercased()
    }

    private func strandTitle(_ path: String) -> String {
        model.strandNotes.first { $0.path == path }?.title ?? VaultStrandRecord.slug(of: path)
    }

    private var archivedHeader: some View {
        Button {
            showsArchived.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsArchived ? "chevron.down" : "chevron.right")
                    .font(.caption)
                Text("Archived")
                Text("\(model.archivedRecents.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsArchived ? "Hide archived strands" : "Show archived strands")
    }

    /// The Strands scope's own row: one chip per section and the strand token. Shown
    /// only under the Strands scope, and the only controls this scope adds.
    private var strandControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(VaultStrandSection.allCases) { section in
                    chip(section.label, isOn: model.section == section) {
                        model.section = section
                    }
                    .accessibilityLabel("Section: \(section.label)")
                    .accessibilityAddTraits(model.section == section ? [.isSelected] : [])
                }
                Divider().frame(height: 18)
                if let strand = model.strand {
                    strandToken(strand)
                } else {
                    chip("Strand", systemImage: "line.3.horizontal.decrease", isOn: false) {
                        strandFilter = ""
                        isPickingStrand = true
                    }
                    .accessibilityLabel("Pick one strand")
                }
            }
            .padding(.vertical, 2)
        }
        .listRowSeparator(.hidden)
    }

    private func chip(_ title: String, systemImage: String? = nil, isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// The held strand, and the way out of it. Tapping the name reopens the picker.
    private func strandToken(_ path: String) -> some View {
        HStack(spacing: 4) {
            Button {
                strandFilter = ""
                isPickingStrand = true
            } label: {
                Text(strandTitle(path)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Strand: \(strandTitle(path)). Change")
            Button {
                model.strand = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show every strand")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(Color.white)
        .background(Capsule().fill(Color.accentColor))
    }

    private var filteredStrands: [VaultIndexedFile] {
        let filter = strandFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return model.strandNotes }
        return model.strandNotes.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.path.localizedCaseInsensitiveContains(filter)
        }
    }

    /// Every note under `Strands/`, the archive included and marked, by title.
    private var strandPicker: some View {
        NavigationStack {
            List {
                folderPickerRow(name: "All strands", count: model.strandNotes.count,
                                isSelected: model.strand == nil) {
                    model.strand = nil
                    isPickingStrand = false
                }
                ForEach(filteredStrands, id: \.path) { note in
                    strandPickerRow(note)
                }
            }
            .navigationTitle("Strand")
            .searchable(text: $strandFilter, prompt: "Filter strands")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPickingStrand = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }

    private func strandPickerRow(_ note: VaultIndexedFile) -> some View {
        let isSelected = model.strand == note.path
        let archived = VaultStrandRecord.isArchived(note.path)
        return Button {
            model.strand = note.path
            isPickingStrand = false
        } label: {
            HStack {
                Text(note.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if archived {
                    Text("archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.caption)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(archived ? "\(note.title), archived" : note.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// One line of a section: the date first, then the line, the strand as caption.
    private func lineRow(_ line: VaultSectionLine) -> some View {
        Button {
            path.append(VaultNoteRoute(path: line.path, line: line.line))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let date = line.date {
                        Text(date)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.lineText(line.text))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Text(line.title)
                    if VaultStrandRecord.isArchived(line.path) {
                        Text("·")
                        Text("archived")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(line.date.map { "\($0), " } ?? "")\(line.text), \(line.title)")
    }

    /// A line's inline markdown, rendered: a strand line is full of `**U1**` and
    /// backticks, and showing them raw would be the one unrendered text on the screen.
    nonisolated static func lineText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
    nonisolated static func recentsHeading(_ scope: VaultSearchScope,
                                           folder: String? = nil) -> String {
        // A picked folder is a plain prefix over plain mtime order, so the heading is
        // the plain one with the folder named. The scope's own wording only applies when
        // no folder is held, which is enforced by the model rather than assumed here.
        if let folder { return "Recently changed in \(folder)" }
        return scope == .strands ? "Recently updated" : "Recently changed"
    }

    /// What an empty result set says. It NAMES the folder when one is held, because
    /// "no note has all of those words" over a narrowed vault is not true of the vault
    /// and sends a person off to check a note they can see is there.
    nonisolated static func emptyResultSentence(folder: String?) -> String {
        guard let folder else {
            return "No note in this copy of the vault has all of those words."
        }
        return "No note under \(folder) has all of those words."
    }

    /// What a folder holding no notes says.
    nonisolated static func emptyFolderSentence(_ folder: String) -> String {
        "Nothing under \(folder) yet."
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

    /// The toolbar's folder button: it says what is held, so the narrowing is legible
    /// from the screen without opening anything.
    private var folderButton: some View {
        Button {
            folderFilter = ""
            isPickingFolder = true
        } label: {
            // An HStack rather than a `Label`, and not by preference: a `Label` carrying
            // a system image renders ICON ONLY in an iOS navigation bar, and keeps doing
            // so through `.labelStyle(.titleAndIcon)` — measured on the simulator, not
            // assumed. A bare glyph says "something about folders" and not WHICH folder,
            // which is the only part worth a place in the bar.
            HStack(spacing: 4) {
                Image(systemName: model.folder == nil ? "folder" : "folder.fill")
                Text(model.folder ?? "All folders")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.callout)
        }
        .disabled(!model.hasFolder)
        .accessibilityLabel(model.folder.map { "Folder: \($0)" } ?? "Pick a folder")
    }

    /// Replaces the scope control while a folder is held, and offers the way out.
    private func folderScopeRow(_ folder: String) -> some View {
        HStack {
            Label(folder, systemImage: "folder.fill")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel("Narrowed to \(folder)")
            Spacer(minLength: 8)
            Button("Clear") { model.folder = nil }
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityLabel("Show every folder")
        }
        .listRowSeparator(.hidden)
    }

    private var filteredFolders: [VaultFolderCount] {
        let filter = folderFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return model.folders }
        return model.folders.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    /// The picker. Every folder in the index, its note count, and "All folders" first
    /// because widening back is the choice a person most often comes here to make.
    private var folderPicker: some View {
        NavigationStack {
            List {
                folderPickerRow(name: "All folders", count: model.counts.fileCount,
                                isSelected: model.folder == nil) {
                    model.folder = nil
                }
                ForEach(filteredFolders) { folder in
                    folderPickerRow(name: folder.path, count: folder.noteCount,
                                    isSelected: model.folder == folder.path) {
                        model.folder = folder.path
                    }
                }
            }
            .navigationTitle("Folder")
            .searchable(text: $folderFilter, prompt: "Filter folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPickingFolder = false }
                }
            }
        }
    }

    private func folderPickerRow(name: String, count: Int, isSelected: Bool,
                                 choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            isPickingFolder = false
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "checkmark")
                    .font(.caption)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count) notes")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                    if model.scope == .strands,
                       let caption = Self.stateCaption(model.strandStates[file.path]) {
                        Text(caption)
                            .foregroundStyle(.primary)
                        Text("·")
                    }
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
