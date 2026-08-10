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
    }

    private var cache: [String: Cached] = [:]
    private let makeClient: @MainActor () -> any TodayDetailProviding

    public init(makeClient: @escaping @MainActor () -> any TodayDetailProviding) {
        self.makeClient = makeClient
    }

    // MARK: - What the views read

    /// The note on screen, if the current state has one.
    public var note: TodayItemDetail? {
        if case .loaded(let note) = state { return note }
        return nil
    }

    /// Whether anything is cached for `id` — what a view uses to decide between opening
    /// on a spinner and opening on the note it showed last time.
    public func isCached(_ id: String) -> Bool { cache[id] != nil }

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
        let cached = cache[id]
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
        defer { isLoading = false }
        do {
            let result = try await makeClient().getItemDetail(
                id: id, ifNoneMatch: force ? nil : cached?.etag)
            apply(result, id: id, cached: cached)
        } catch {
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
            store(.loaded(note), etag: note.etag, id: id)
        case .noDetail(let none):
            store(.noDetail(none.reason), etag: none.etag, id: id)
        case .notModified(let tag):
            // Nothing changed, so nothing to re-render. The round trip still SUCCEEDED,
            // which is what clears a stale banner — and the tag is re-stored because a
            // `304` is the bridge confirming the one we sent.
            if let cached {
                cache[id] = Cached(etag: tag ?? cached.etag, state: cached.state)
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

    private func store(_ state: State, etag: String?, id: String) {
        cache[id] = Cached(etag: etag, state: state)
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
