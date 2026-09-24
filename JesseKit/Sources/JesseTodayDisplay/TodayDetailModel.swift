import Foundation
import Observation
import JesseNetworking

// The view model behind "what is this item actually about" — the note the bridge
// resolves from an item's first wiki link.
//
// It is a peer of `TodayDashboardModel` and follows the same rules: the client comes in
// as a factory so re-pairing is picked up on the next call, every outcome the endpoint
// types is a state rather than an error, and a previously-read note is NEVER blanked by
// a failed refresh. Invariants, each with a test:
//
//  * A `304` re-uses what is cached under that ETag and re-renders nothing. Re-opening
//    the same note is the common case, so this is the common path.
//  * A `410` is `.removed` — the item left the day file, so the sheet says so instead
//    of showing a note for a row that is gone.
//  * A `no-detail` answer is `.noDetail`, an ordinary empty state, never an error.
//  * A failure with something cached shows the CACHED note and raises `isOffline`; a
//    failure with nothing cached is `.unavailable`. The screen degrades; it never lies
//    about having nothing.
//
// The cache is keyed by ITEM ID and holds the ETag its entry was served under, which is
// exactly what `If-None-Match` needs. It is per-model and in memory only: a note is
// cheap to refetch and the day file is rewritten every morning, so persisting one would
// be storing vault content on the device for no gain.

@MainActor
@Observable
public final class TodayDetailModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the model off the main actor, which would route through the
    // isolated-deinit executor hop and abort. Same pattern as the other JesseKit models.
    nonisolated deinit {}

    /// What the detail surface shows.
    public enum State: Equatable, Sendable {
        /// Nothing asked for yet.
        case idle
        /// First load for this item, nothing to show yet.
        case loading
        /// The note.
        case loaded(TodayItemDetail)
        /// The item is fine and simply has no note behind it — most items, in practice.
        case noDetail(TodayNoDetailReason)
        /// `410`: the item is no longer in the day file.
        case removed
        /// Nothing cached and the call failed.
        case unavailable(String)
        /// The bridge could not be reached and nothing was cached, but the note the item
        /// links IS in the Obsidian copy of the vault on this device. The sheet shows it
        /// with a badge saying so, and without a brief — nobody wrote one offline.
        case localCopy(LocalVaultNote)
    }

    public private(set) var state: State = .idle

    /// The item the current state is about, so a view that outlives one selection never
    /// renders the previous item's note under the new item's title.
    public private(set) var itemID: String?

    /// A call is in flight. A refresh of an already-loaded note keeps the note on screen
    /// and raises this, rather than flashing back through `.loading`.
    public private(set) var isLoading = false

    /// The last call failed and what is showing (if anything) came from the cache.
    public private(set) var isOffline = false

    /// The most recent failure's message, for a stale banner. Cleared by the next
    /// success — including by a `304`, which IS a completed round trip.
    public private(set) var lastErrorMessage: String?

    /// One cached answer, and the tag it was served under.
    private struct Cached {
        var etag: String?
        var state: State
        /// The seven answers, cached beside the note because they arrive on the same
        /// response and share its ETag — a `304` confirms both or neither.
        var brief: TodayBriefEnvelope?
    }

    private var cache: [String: Cached] = [:]
    private let makeClient: @MainActor () -> any TodayDetailProviding
    /// The LOCAL copy of the vault, when this device holds one. Nil is the honest default
    /// and preserves the previous behaviour exactly: a shell that passes nothing gets the
    /// bridge and only the bridge.
    private let localNotes: (any TodayLocalNoteProviding)?

    public init(makeClient: @escaping @MainActor () -> any TodayDetailProviding,
                localNotes: (any TodayLocalNoteProviding)? = nil) {
        self.makeClient = makeClient
        self.localNotes = localNotes
    }

    // MARK: - What the views read

    /// The note on screen, if the current state has one.
    public var note: TodayItemDetail? {
        if case .loaded(let note) = state { return note }
        return nil
    }

    /// The note on screen when it came from the LOCAL copy of the vault rather than from
    /// the bridge. Never both: one of the two is nil at any moment.
    public var localNote: LocalVaultNote? {
        if case .localCopy(let note) = state { return note }
        return nil
    }

    /// The seven answers for the item on screen, if the bridge sent any.
    ///
    /// Read from the CACHE rather than from `state`, because an item with no note is
    /// still an item with a brief — `.noDetail` carries only the reason, and the answers
    /// about those items are exactly the ones that were previously unreachable.
    public var brief: TodayBriefEnvelope? {
        guard let id = itemID else { return nil }
        return cache[id]?.brief
    }

    /// Whether anything is cached for `id` — what a view uses to decide between opening
    /// on a spinner and opening on the note it showed last time.
    public func isCached(_ id: String) -> Bool { cache[id] != nil }

    /// Whether the brief on screen is one the bridge is still working on.
    ///
    /// `TodayBriefEnvelope.status` is the BRIDGE's word, captured at the moment the
    /// response was written, and a `pending` status cached at that moment stays `pending`
    /// for as long as the entry lives. Offline, the sheet re-shows that cached entry, and
    /// a view that trusts the status alone spins "Writing the summary…" over a dead
    /// network for as long as it is open — claiming work nobody is doing.
    ///
    /// The seam is the LAST REQUEST, not the status: a brief is live when the most recent
    /// round trip for this item completed, which is exactly what `isOffline` already
    /// tracks (it is raised by `fail`, by a local-copy fallback, and cleared by every
    /// success including a `304`). A view asks this, never `isOffline` directly, so the
    /// question it is really asking has a name.
    public var briefIsLive: Bool { !isOffline }

    /// The wording for a no-detail answer. Public so every platform says the same thing
    /// about the same situation, and so the two reasons stay distinguishable: "nothing
    /// is linked" and "what is linked isn't there" are different facts about the vault
    /// and a user can act on the second.
    public static func noDetailMessage(_ reason: TodayNoDetailReason) -> String {
        switch reason {
        case .noTarget:
            return "This item doesn't link a note, so there's nothing more to read."
        case .unresolvedTarget:
            return "This item links a note that isn't in the vault yet."
        case .unknown:
            return "There's no note behind this item."
        }
    }

    // MARK: - Loading

    /// Load (or re-load) the note for one item.
    ///
    /// Opens on whatever is cached for that id rather than on a spinner, so re-opening a
    /// note is instant and the conditional request just confirms it. `force` skips the
    /// `If-None-Match`, which is what a pull-to-refresh means: answer me properly, even
    /// if you think nothing changed.
    public func load(id: String, force: Bool = false) async {
        await load(item: TodayItem(id: id), force: force)
    }

    /// Load the note for one item, with the item itself in hand.
    ///
    /// The item is needed for one reason: its wiki links. When the bridge cannot answer,
    /// the links are how the same note is found in the local copy of the vault — the
    /// endpoint is keyed by item id, and an id means nothing to a folder full of markdown.
    ///
    /// `isReadOnly` is the day screen's own verdict (`TodayDashboardModel.isReadOnly`).
    /// When it is already true the local copy is tried FIRST and no request is made at all:
    /// a screen that has just told the user it cannot reach the bridge should not then
    /// spend a timeout proving it again.
    public func load(item: TodayItem, force: Bool = false, isReadOnly: Bool = false) async {
        let id = item.id
        if isReadOnly, cache[id] == nil, itemID != id || stateIsEmpty {
            // Adopt the item BEFORE the read, exactly as `fetch` does when the selection
            // changes: a sheet that kept the previous row's note on screen while reading a
            // file would be showing a note under the wrong title.
            itemID = id
            state = .loading
            isOffline = false
            lastErrorMessage = nil
            if await presentLocalCopy(for: item) { return }
        }
        await fetch(id: id, item: item, force: force, cached: cache[id])
    }

    /// Whether the current state has nothing on screen worth keeping — used to decide
    /// whether a read-only re-open should go looking at the local copy again.
    private var stateIsEmpty: Bool {
        switch state {
        case .idle, .loading, .unavailable: return true
        case .loaded, .noDetail, .removed, .localCopy: return false
        }
    }

    /// Resolve and show the item's note from the local copy. True when it found one.
    private func presentLocalCopy(for item: TodayItem) async -> Bool {
        guard let localNotes else { return false }
        let targets = TodayLocalTargets.targets(for: item)
        guard !targets.isEmpty else { return false }
        isLoading = true
        defer { isLoading = false }
        guard let note = await localNotes.localNote(forTargets: targets) else { return false }
        // Only if the sheet is still about this item: a slow read of a synced file must
        // never land a note under a different row's title.
        guard itemID == item.id else { return false }
        state = .localCopy(note)
        isOffline = true
        return true
    }

    private func fetch(id: String, item: TodayItem, force: Bool, cached: Cached?) async {
        // Switching items must not leave the previous note on screen while the new one
        // loads — a note under the wrong title is worse than a spinner.
        if itemID != id {
            itemID = id
            state = cached?.state ?? .loading
            isOffline = false
            lastErrorMessage = nil
        } else if cached == nil, case .idle = state {
            state = .loading
        }

        isLoading = true
        do {
            let result = try await makeClient().getItemDetail(
                id: id, ifNoneMatch: force ? nil : cached?.etag)
            apply(result, id: id, cached: cached)
            isLoading = false
        } catch {
            isLoading = false
            // Nothing cached and the bridge unreachable is exactly the case the local copy
            // exists for. It is tried BEFORE `.unavailable` is published, so the screen
            // never shows "can't reach the bridge" about a note this device is holding.
            if cached == nil, await presentLocalCopy(for: item) {
                lastErrorMessage = nil
                return
            }
            fail(error, cached: cached)
        }
    }

    /// Forget everything cached — what a shell calls when the day file itself changed
    /// under the screen (a fresh snapshot with a new ETag), since an item's note may now
    /// resolve to a different file entirely.
    public func invalidate() {
        cache.removeAll()
    }

    /// Drop the current selection, leaving the cache intact for the next open.
    public func clear() {
        itemID = nil
        state = .idle
        isOffline = false
        lastErrorMessage = nil
    }

    private func apply(_ result: TodayDetailResult, id: String, cached: Cached?) {
        switch result {
        case .detail(let note):
            store(.loaded(note), etag: note.etag, id: id, brief: note.brief)
        case .noDetail(let none):
            store(.noDetail(none.reason), etag: none.etag, id: id, brief: none.brief)
        case .notModified(let tag):
            // Nothing changed, so nothing to re-render. The round trip still SUCCEEDED,
            // which is what clears a stale banner — and the tag is re-stored because a
            // `304` is the bridge confirming the one we sent.
            if let cached {
                cache[id] = Cached(etag: tag ?? cached.etag, state: cached.state,
                                   brief: cached.brief)
                if itemID == id { state = cached.state }
            }
            clearFailure()
        case .itemGone:
            // The id is not in the day file any more, so a cached note for it is about
            // an item that no longer exists.
            cache.removeValue(forKey: id)
            if itemID == id { state = .removed }
            clearFailure()
        }
    }

    private func store(_ state: State, etag: String?, id: String,
                       brief: TodayBriefEnvelope? = nil) {
        cache[id] = Cached(etag: etag, state: state, brief: brief)
        if itemID == id { self.state = state }
        clearFailure()
    }

    private func clearFailure() {
        isOffline = false
        lastErrorMessage = nil
    }

    private func fail(_ error: any Error, cached: Cached?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastErrorMessage = message
        if let cached {
            // Something is cached: keep showing it and say it may be stale. A note the
            // user was reading a second ago is still the best answer available.
            isOffline = true
            state = cached.state
        } else {
            isOffline = true
            state = .unavailable(message)
        }
    }
}
