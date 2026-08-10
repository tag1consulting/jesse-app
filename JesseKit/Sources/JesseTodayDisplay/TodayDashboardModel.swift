import Foundation
import Observation
import JesseNetworking

// The Today tab's view model: it owns the server snapshot, the ETag every mutation
// must carry, and the optimistic overlay that makes a checkbox respond before the
// round trip. Invariants, each of which has a test:
//
//  * A previously-rendered day is NEVER blanked by a failed refresh. Once a snapshot
//    has loaded it stays on screen and the failure surfaces as `isOffline`.
//  * A tap is reflected IMMEDIATELY and reconciled on the server's answer — the
//    overlay entry is dropped only when the response carries the truth it stood for.
//  * `410` removes the row; `412` refetches instead of retrying blind, because a
//    stale ETag means the file was rewritten and the user's tap was aimed at a
//    document that no longer exists.
//  * A `to_do_now` move can change an item's id (the id hashes the section name).
//    The response is authoritative: the overlay is re-keyed onto the new id and the
//    old one is left holding nothing, so the row never renders twice or as a ghost.
//
// The client is injected as a factory, like `HealthDashboardModel`, so re-pairing is
// picked up on the next call and tests drive every path through a fake. `now` is
// injected so the stamps a mutation sends are deterministic under test.

@MainActor
@Observable
public final class TodayDashboardModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the model off the main actor, which would route through the
    // isolated-deinit executor hop and abort. Same pattern as JesseDietDisplay's and
    // JesseSearch's models.
    nonisolated deinit {}

    /// The last snapshot the server sent, WITHOUT the optimistic overlay. Kept raw so
    /// reconciliation always compares against what the bridge actually said.
    public private(set) var serverSnapshot: TodaySnapshot?

    /// The ETag every mutation must send back. Refreshed by each `200`.
    public private(set) var etag: String?

    /// The local state layered on top of `serverSnapshot`. Settable within the
    /// package so tests can stage a half-completed interaction (a check still in
    /// flight when a move lands) without racing two real calls to produce it.
    public internal(set) var overlay = TodayOptimism()

    /// A fetch or mutation is in flight.
    public private(set) var isLoading = false

    /// The last network call failed. The screen keeps rendering what it has and shows
    /// a stale banner rather than an empty state, because a day file the user was
    /// reading a second ago is still the best answer available.
    public private(set) var isOffline = false

    /// The most recent failure's message, for the banner. Cleared by the next success.
    public private(set) var lastErrorMessage: String?

    /// The bridge's `409` message for a move it structurally refuses, surfaced once
    /// and cleared on the next action.
    public private(set) var lastConflictMessage: String?

    /// Whether the newest response said the change is journaled but not yet in the
    /// file — a turn is mid-write and replay will land it. Worth a quiet indicator:
    /// the tap is safe, it is just not on disk yet.
    public private(set) var isPendingReplay = false

    private let makeClient: @MainActor () -> any TodayProviding
    private let now: @Sendable () -> Date

    public init(makeClient: @escaping @MainActor () -> any TodayProviding,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.makeClient = makeClient
        self.now = now
    }

    // MARK: - What the views read

    /// The document to render: the server's, with the overlay applied and the counts
    /// recomputed. Nil until the first successful load.
    public var snapshot: TodaySnapshot? {
        serverSnapshot.map { TodaySemantics.display($0, applying: overlay) }
    }

    /// What the tab root shows.
    public enum DisplayState: Equatable {
        /// First load, nothing to show yet.
        case loading
        /// A day to render (possibly mid-refresh, possibly stale).
        case content(TodaySnapshot)
        /// The bridge answered, and there is no day file yet — the morning routine
        /// has not run. An empty day, not an error.
        case noDayFile
        /// Nothing loaded and the last attempt failed.
        case unavailable(String)
    }

    public var displayState: DisplayState {
        if let snap = snapshot {
            return snap.missing ? .noDayFile : .content(snap)
        }
        if let message = lastErrorMessage { return .unavailable(message) }
        return .loading
    }

    /// The tab badge: open Do Now items plus the standing lead item.
    public var badgeCount: Int {
        snapshot.map(TodaySemantics.doNowOpenCount) ?? 0
    }

    /// Unseen glanceable rows across the briefing sections.
    public var unseenReportCount: Int {
        snapshot.map(TodaySemantics.unseenReportCount) ?? 0
    }

    /// Whether this item has a tap the server has not confirmed yet.
    public func isPending(_ id: String) -> Bool {
        overlay.checks[id] != nil || overlay.moves[id] != nil
    }

    /// The evidence to show under a row — the pending note, else the file's.
    public func evidence(for item: TodayItem) -> String? {
        TodaySemantics.evidenceText(item, pending: overlay.evidence[item.id])
    }

    // MARK: - Loading

    /// Fetch the day, conditionally. A `304` costs one round trip and changes
    /// nothing on screen — the common answer when the screen is polled.
    public func load() async {
        await fetch(conditional: true)
    }

    /// Pull-to-refresh: fetch unconditionally, so a user who suspects the screen is
    /// wrong can force a full answer rather than be told nothing changed.
    public func refresh() async {
        await fetch(conditional: false)
    }

    private func fetch(conditional: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await makeClient().getToday(ifNoneMatch: conditional ? etag : nil)
            switch result {
            case .notModified:
                // Nothing changed, so nothing to reconcile — but the round trip DID
                // succeed, which is what clears a stale banner.
                clearFailure()
            case .snapshot(let snap):
                adopt(snap)
            }
        } catch {
            fail(error)
        }
    }

    /// Take a server snapshot as the new truth and drop every overlay entry it has
    /// now accounted for.
    ///
    /// "Accounted for" is per-id and per-field: a pending check is dropped once the
    /// server's item agrees with it, and NOT before — otherwise a fetch that raced
    /// ahead of a still-in-flight mutation would revert the box under the user's
    /// finger. A pending move is dropped as soon as the item is gone from the id it
    /// was queued under, because that id is exactly what a completed cross-section
    /// move destroys.
    private func adopt(_ snap: TodaySnapshot) {
        serverSnapshot = snap
        if let tag = snap.etag, !tag.isEmpty { etag = tag }
        isPendingReplay = snap.pending ?? false
        reconcile(against: snap)
        clearFailure()
    }

    private func reconcile(against snap: TodaySnapshot) {
        let byId = Dictionary(snap.allItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, checked) in overlay.checks {
            guard let item = byId[id] else {
                // The item is gone from the document entirely. Nothing is left to
                // confirm, and holding the entry would keep it out of a later re-key.
                overlay.settle(id)
                continue
            }
            if item.checked == checked { overlay.settle(id) }
        }
        for id in overlay.moves.keys where byId[id] == nil {
            overlay.moves.removeValue(forKey: id)
        }
        let reportIds = Set(snap.allReports.filter(\.seen).map(\.id))
        overlay.seen.subtract(reportIds)
        overlay.removed.formIntersection(Set(byId.keys).union(Set(snap.allReports.map(\.id))))
    }

    private func clearFailure() {
        isOffline = false
        lastErrorMessage = nil
    }

    private func fail(_ error: any Error) {
        isOffline = true
        lastErrorMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    // MARK: - Mutations

    /// Tick or untick an item, optionally recording one line of evidence.
    ///
    /// The box flips before the request is sent and stays flipped until the server
    /// either confirms it (the overlay entry retires) or contradicts it (the next
    /// snapshot wins). A tap on an item with no ETag in hand is dropped rather than
    /// sent: without one the bridge answers `428`, and the honest thing is to refetch.
    public func check(id: String, checked: Bool, evidence: String? = nil) async {
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        lastConflictMessage = nil
        overlay.checks[id] = checked
        let note = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if checked, let note, !note.isEmpty {
            overlay.evidence[id] = note
        } else {
            overlay.evidence.removeValue(forKey: id)
        }
        await perform(id: id) { client in
            try await client.checkItem(id: id, checked: checked, evidence: note,
                                       at: self.now(), ifMatch: tag)
        }
    }

    /// Reorder an item.
    ///
    /// The row moves immediately under its OLD id — the new one is a hash of the
    /// destination section the client cannot compute — and the response's snapshot
    /// then decides where it really lives and under what id. See `settleMove`.
    public func move(id: String, op: TodayMoveOp) async {
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        lastConflictMessage = nil
        let before = serverSnapshot
        let knownIds = Set(before?.allItems.map(\.id) ?? [])
        let item = snapshot?.item(id: id) ?? before?.item(id: id)
        overlay.moves[id] = op

        await perform(id: id, adopting: { [weak self] snap in
            guard let self else { return }
            self.settleMove(id: id, item: item, knownIds: knownIds, in: snap)
        }) { client in
            try await client.moveItem(id: id, op: op, at: self.now(), ifMatch: tag)
        }
    }

    /// Mark a glanceable row seen. The dot clears at once; the bridge's glance store
    /// is what makes it stay cleared across a relaunch.
    public func glance(id: String) async {
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        overlay.seen.insert(id)
        await perform(id: id) { client in
            try await client.glance(id: id, at: self.now(), ifMatch: tag)
        }
    }

    /// Run one mutation and fold its typed result back into state.
    ///
    /// `adopting` runs BEFORE the snapshot is adopted, on the response's own
    /// document, because a re-key has to happen while the client still remembers
    /// which id it queued the work under.
    private func perform(id: String,
                         adopting extra: ((TodaySnapshot) -> Void)? = nil,
                         _ call: @escaping (any TodayProviding) async throws -> TodayMutationResult
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch try await call(makeClient()) {
            case .snapshot(let snap):
                extra?(snap)
                adopt(snap)
            case .itemGone:
                // `410`: the item left the file — a rebuild dropped it, or its lead was
                // re-worded into a different id. Take it off the screen now rather than
                // leave a row whose every tap will fail, and refetch for the rest.
                overlay.settle(id)
                overlay.removed.insert(id)
                clearFailure()
                await fetch(conditional: false)
            case .preconditionFailed:
                // `412`: our ETag is stale, so this tap was aimed at a document that no
                // longer exists. Drop the optimism and refetch — re-sending against a
                // fresh tag would apply the user's intent to a line they never saw.
                overlay.settle(id)
                clearFailure()
                await fetch(conditional: false)
            case .preconditionRequired:
                // `428`: we sent no If-Match at all. A client bug, not a race — the
                // only honest recovery is to go get a tag.
                overlay.settle(id)
                await fetch(conditional: false)
            case .conflict(let message):
                // `409`: structurally impossible (the lead item, or no Do Now section).
                // The menu should not have offered it; surface the bridge's own words.
                overlay.settle(id)
                lastConflictMessage = message
            }
        } catch {
            overlay.settle(id)
            fail(error)
        }
    }

    /// Migrate every overlay entry keyed by the id a move was queued under onto the
    /// id the server's snapshot now carries that item under.
    ///
    /// This is the whole of the re-keying contract, and it runs for EVERY move rather
    /// than only for `to_do_now`: the op that crosses sections is the one that changes
    /// an id today, but the rule is "the response is authoritative about identity",
    /// and a rule applied conditionally is one that breaks the first time the
    /// condition changes. When nothing moved, `rekeyed` returns the same id and
    /// `rekey` is a no-op.
    private func settleMove(id: String, item: TodayItem?, knownIds: Set<String>,
                            in snap: TodaySnapshot) {
        overlay.moves.removeValue(forKey: id)
        guard let item,
              let newId = TodaySemantics.rekeyed(item, in: snap, excluding: knownIds),
              newId != id
        else { return }
        overlay.rekey(from: id, to: newId)
    }
}
