import Foundation
import Observation
import JesseCore
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
//  * A change made with no bridge to send it to is CAPTURED, not dropped — see
//    "Capture" below. The overlay is applied exactly as it would be for a live tap, so
//    the day reads as the user left it; what differs is only that the row says it is
//    waiting. Replay is `IntentReplayer`'s, and every refusal rule lives there.
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

    /// The one line about an action that could not stand: the bridge's own `409`
    /// message for a move it structurally refuses, a drag the day file's shape forbids
    /// (`TodayReorderGuard`), or a row that left the file under the user. Surfaced once
    /// and cleared on the next action.
    public private(set) var lastConflictMessage: String?

    /// Set to true by the platform shell when its own reachability probe says the
    /// bridge is unreachable, so the screen goes read-only BEFORE a tap rather than
    /// after one fails. Settable (not derived) because the probe is the shell's: iOS
    /// runs `BridgeReachabilityModel` against `GET /health`, and a library that
    /// reached for a probe of its own would be a second answer to the same question.
    public var isNetworkUnreachable = false

    /// The refusal a tap got while the screen was read-only. Distinct from
    /// `lastErrorMessage` (which describes a call that FAILED) because nothing was
    /// attempted here at all — and nothing was queued either. See `refuseIfReadOnly`.
    public private(set) var lastReadOnlyNotice: String?

    /// Whether the newest response said the change is journaled but not yet in the
    /// file — a turn is mid-write and replay will land it. Worth a quiet indicator:
    /// the tap is safe, it is just not on disk yet.
    public private(set) var isPendingReplay = false

    /// When the day on screen was last confirmed against the bridge — the fetch that
    /// produced it, or, for a document restored from disk, the fetch that produced THAT.
    /// What the stale banner's "last updated" reads.
    public private(set) var lastFetchedAt: Date?

    /// Whether what is on screen came off DISK and has not been confirmed live since.
    ///
    /// Distinct from `isReadOnly`, which is about whether a tap can be sent. A cached
    /// day may be perfectly current (the app was killed a minute ago) and a live day may
    /// be read-only (the probe just failed); the screen says both things separately
    /// because they are separately true.
    public private(set) var isShowingCachedSnapshot = false

    /// Whether the last failure was "could not reach the bridge" rather than "the bridge
    /// said no". Only the first is worth an offline empty state.
    private var lastFailureWasUnreachable = false

    private let makeClient: @MainActor () -> any TodayProviding
    private let now: @Sendable () -> Date

    /// The on-disk last-good day, or `nil` to keep the pre-cache behavior (which is what
    /// every test that does not care about caching gets).
    private let cache: SnapshotCache?

    /// **The offline capture queue**, or `nil` for the pre-queue behaviour.
    ///
    /// Optional rather than required, and defaulting to `nil`, because a screen with no
    /// store still has to work: the Mac shell, a preview, and every existing test build
    /// this model without one, and each of those must keep the honest refusal rather
    /// than silently promise to save something nowhere.
    private let pending: (any PendingIntentStoring)?

    /// The zone a captured change records. Injected for the same reason `now` is: a
    /// stamp a test cannot pin is a stamp a test cannot assert.
    private let zone: @Sendable () -> String

    public init(makeClient: @escaping @MainActor () -> any TodayProviding,
                now: @escaping @Sendable () -> Date = { Date() },
                cache: SnapshotCache? = nil,
                pending: (any PendingIntentStoring)? = nil,
                zone: @escaping @Sendable () -> String = { TimeZone.current.identifier }) {
        self.makeClient = makeClient
        self.now = now
        self.cache = cache
        self.pending = pending
        self.zone = zone
    }

    // MARK: - The cache

    /// Render the last day this device was given, before any network call.
    ///
    /// Called by the shell as the screen is built, so a COLD LAUNCH WITH NO NETWORK
    /// draws the day immediately instead of a spinner that resolves into an error. A
    /// no-op once anything has loaded — a cache must never overwrite a live answer.
    ///
    /// The cached ETag is adopted with it, which is what makes the ONLINE cold launch
    /// cheap too: the first `load()` sends `If-None-Match` and the common answer is a
    /// `304` that confirms what is already drawn.
    public func primeFromCache() {
        guard serverSnapshot == nil, let cache,
              let entry = cache.load(key: SnapshotCacheKey.today, now: now()),
              var snap = try? TodaySnapshot.decode(from: entry.body) else { return }
        if snap.etag == nil || snap.etag?.isEmpty == true { snap.etag = entry.etag }
        serverSnapshot = snap
        if let tag = snap.etag, !tag.isEmpty { etag = tag }
        // Deliberately NOT `isPendingReplay`: that flag describes a turn that was
        // mid-write when the snapshot was taken, and whether it is still mid-write now
        // is not something a file on disk can answer.
        isPendingReplay = false
        lastFetchedAt = entry.fetchedAt
        isShowingCachedSnapshot = true
    }

    // MARK: - What the views read

    /// The document to render: the server's, with the overlay applied and the counts
    /// recomputed. Nil until the first successful load.
    ///
    /// **In FILE ORDER, always.** This is the document as the day file has it, and it is
    /// what every judgement about identity and position is made against — which item is
    /// first in its section, what a move would do, whether an id still exists. The view
    /// sort is applied on top of it by `displaySnapshot` and never here; a model whose
    /// own idea of the document was reordered by a lens would compute `up` against rows
    /// the file does not have in that order.
    public var snapshot: TodaySnapshot? {
        serverSnapshot.map { TodaySemantics.display($0, applying: overlay) }
    }

    /// **The view sort.** A lens over the rows, not a change to the day: it reorders
    /// what is on screen and writes nothing, and `.fileOrder` (the default) is the
    /// identity. Durable reordering is `move(id:op:)` / `focus(id:_:)`, which change the
    /// FILE.
    ///
    /// Settable rather than derived because it is a preference about this screen, and
    /// deliberately NOT persisted here: where a per-device preference lives is the
    /// shell's business, and a library that reached for storage would be making that
    /// decision for both platforms.
    ///
    /// Setting it CLEARS every per-section override, because "order the day like this"
    /// is a statement about the whole document — a document-wide choice that left three
    /// sections quietly on an older lens would not be the choice the user made.
    public var sortKey: TodaySortKey = .fileOrder {
        didSet { if sortKey != oldValue { sectionSortKeys.removeAll() } }
    }

    /// Per-section overrides of the lens.
    ///
    /// A day file's sections are not alike: `Do Now` is a short hand-ordered list whose
    /// order IS the argument, while an aging backlog is a pile the user wants to see
    /// oldest-first without touching anything. One document-wide sort forces those two
    /// to share an answer. Overrides are still lenses — nothing here writes.
    public private(set) var sectionSortKeys: [String: TodaySortKey] = [:]

    /// The lens in effect for one section: its own override, else the document's.
    public func sortKey(for sectionName: String) -> TodaySortKey {
        sectionSortKeys[sectionName] ?? sortKey
    }

    /// Point one section at a lens of its own.
    public func setSortKey(_ key: TodaySortKey, for sectionName: String) {
        sectionSortKeys[sectionName] = key
    }

    /// Whether ANY lens is reordering anything right now — what a screen asks before
    /// saying "sorted" out loud at the document level.
    public var isSorted: Bool {
        sortKey.reorders || sectionSortKeys.values.contains(where: \.reorders)
    }

    /// **The badge-only view.** When on, the screen shows exactly the items the tab
    /// badge counts and nothing else.
    ///
    /// A LENS like the sort, not an edit: it writes nothing, it works while the day is
    /// read-only, and turning it off gives the day back whole. What it changes is which
    /// rows are drawn, which is why it is the one lens that changes membership.
    ///
    /// Settable and deliberately NOT persisted here, exactly as `sortKey` is not: where
    /// a per-device preference lives is the shell's business (both shells use
    /// `TodayViewPreferences`). Toggling drops the pins, because turning the filter on
    /// is the start of a fresh viewing.
    public var isBadgeFilterOn = false {
        didSet { if isBadgeFilterOn != oldValue { pinnedBadgeIDs = [] } }
    }

    /// Rows the filtered view is holding on screen even though they have left the
    /// badge set.
    ///
    /// A row that vanished the instant it was ticked would be a list nobody could
    /// correct: tick the wrong item and it is gone before you can untick it. So the
    /// ids on screen are pinned at the moment the user acts, and the row stays where it
    /// was, struck through or chipped as postponed exactly as the full day would draw
    /// it. The BADGE is unaffected: a pinned row has already left the count, which is
    /// the whole feedback the tap was after.
    ///
    /// Cleared by `repinBadgeFilter()`, which is the next explicit refresh or the next
    /// entry into the view.
    public private(set) var pinnedBadgeIDs: Set<String> = []

    /// Start a fresh viewing of the filtered day: everything that has left the badge
    /// set goes.
    ///
    /// Called by a pull-to-refresh (`refresh()`) and by the screen when it appears. Not
    /// by an ordinary `load()`, which fires on a tab switch, a foregrounding and every
    /// settled turn. Rows disappearing because a background turn finished is exactly
    /// the "list that edits itself under you" this pinning exists to prevent.
    public func repinBadgeFilter() {
        pinnedBadgeIDs = []
    }

    /// Hold whatever the filtered view is currently drawing, before an action changes
    /// what belongs in it. A no-op unless the filter is on.
    private func pinRowsOnScreen() {
        guard isBadgeFilterOn, let snapshot else { return }
        pinnedBadgeIDs.formUnion(TodaySemantics.badgeItems(snapshot).map(\.id))
    }

    /// The document to DRAW: `snapshot` with each section's lens applied, then narrowed
    /// to the badge set when the filter is on. Counts and membership are identical to
    /// `snapshot` under the sort alone, because a lens changes order and never what is
    /// in the day. The filter is the one exception, which is why it is applied last and
    /// says so on screen.
    public var displaySnapshot: TodaySnapshot? {
        guard let snapshot else { return nil }
        let sorted = TodaySemantics.sortedForDisplay(snapshot, by: sectionSortKeys,
                                                     default: sortKey)
        guard isBadgeFilterOn else { return sorted }
        return TodaySemantics.badgeFiltered(sorted, keeping: pinnedBadgeIDs)
    }

    /// The moves worth offering for one row, judged against the FILE order and filtered
    /// for the lens in effect. The one place a view should ask, so no shell re-derives
    /// the pairing of "which snapshot" with "which sort" and gets it half right.
    public func availableMoves(for item: TodayItem) -> [TodayMoveOp] {
        guard let snapshot else { return [] }
        return TodaySemantics.availableMoves(for: item, in: snapshot,
                                             sortedBy: sortKey(for: item.sectionName))
    }

    /// The focus actions worth offering for one row. Unaffected by the lens: both are
    /// absolute positions.
    public func availableFocus(for item: TodayItem) -> [TodayFocus] {
        guard let snapshot else { return [] }
        return TodaySemantics.availableFocus(for: item, in: snapshot)
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
        /// **Nothing cached and the bridge cannot be reached.** A fresh install on a
        /// plane. Deliberately its own state and not `unavailable`: there is no error to
        /// report and nothing to retry until the network comes back, and the honest
        /// screen says so rather than printing a URL-loading string or spinning forever.
        case offline
    }

    public var displayState: DisplayState {
        if let snap = displaySnapshot {
            return snap.missing ? .noDayFile : .content(snap)
        }
        // Order matters: "you are offline" outranks whichever transport string the
        // failed call happened to produce, and it is reachable BEFORE the first call
        // finishes (the shell's probe is faster than a 30s timeout).
        if isNetworkUnreachable || lastFailureWasUnreachable { return .offline }
        if let message = lastErrorMessage { return .unavailable(message) }
        return .loading
    }

    /// The one line a screen puts under the offline banner: what is on screen and how
    /// old it is.
    ///
    /// Present in exactly two situations, and `nil` otherwise. Either the document came
    /// off DISK and has not been confirmed live since, or the screen is read-only and the
    /// document — however it arrived — can no longer be refreshed. A live document on a
    /// reachable bridge carries no stale stamp, which is what stops the line flashing up
    /// during the ordinary online launch.
    public var stalenessLine: String? {
        guard isShowingCachedSnapshot || isReadOnly, lastFetchedAt != nil else { return nil }
        return OfflineStamp.cachedLine("Showing the last day loaded",
                                       fetchedAt: lastFetchedAt, now: now())
    }

    /// Open Do Now items plus the standing lead item: the number on the tab, and the
    /// number the badge filter shows. Read off the WHOLE day, never off the filtered
    /// view: the filtered view can be holding a pinned row the count has already let
    /// go of, and the day is the only document that can answer what is left in it.
    public var badgeCount: Int {
        snapshot.map(TodaySemantics.doNowOpenCount) ?? 0
    }

    /// The badge set, as rows. What the filter shows, from the same function the count
    /// is the size of.
    public var badgeItems: [TodayItem] {
        snapshot.map(TodaySemantics.badgeItems) ?? []
    }

    /// **Nothing is left that needs action**, with the filter on and a day loaded.
    ///
    /// The screen's cue to say so rather than draw an empty list, and deliberately not
    /// a reason to unfilter: the user asked which items the badge counts, and "none"
    /// is the useful answer to that question.
    public var isBadgeFilterEmpty: Bool {
        guard isBadgeFilterOn, let day = snapshot, !day.missing else { return false }
        return displaySnapshot?.allItems.isEmpty ?? false
    }

    /// **The checked items a Process-updates turn would close at source**, read off the
    /// document the user is looking at — overlay included, so an item ticked ten
    /// seconds ago and not yet confirmed is in the list the confirmation sheet shows.
    /// That is the honest set: the user ticked it, so it is done, and the turn is about
    /// to say so at source either way.
    public var itemsToProcess: [TodayItem] {
        snapshot.map(TodaySemantics.itemsToProcess) ?? []
    }

    /// Unseen glanceable rows across the briefing sections.
    public var unseenReportCount: Int {
        snapshot.map(TodaySemantics.unseenReportCount) ?? 0
    }

    /// **The number the tab shows** — the two counts above, added up by the semantics
    /// and never by a view. Nothing yet loaded is a badge of zero, not a guess.
    public var tabBadgeCount: Int {
        snapshot.map(TodaySemantics.tabBadge) ?? 0
    }

    /// Whether the day on screen can still be changed.
    ///
    /// Read-only means one of two things, and they deserve the same treatment: the
    /// shell's probe says the bridge is unreachable, or our own last call to it
    /// failed. In both cases the honest screen is the last snapshot, rendered and
    /// readable, with taps refused rather than queued — see `refuseIfReadOnly`.
    public var isReadOnly: Bool { isOffline || isNetworkUnreachable }

    /// Whether this item has a tap the server has not confirmed yet.
    public func isPending(_ id: String) -> Bool {
        overlay.checks[id] != nil || overlay.moves[id] != nil
    }

    /// Whether this item's change is HELD for replay rather than in flight. The two are
    /// separate questions and a row shows them differently: "sending" is a round trip
    /// nobody has answered, "queued" is a round trip nobody has started.
    public func isQueued(_ id: String) -> Bool { overlay.isQueued(id) }

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
    ///
    /// This is the EXPLICIT refresh the badge filter drops its pins on: the user asked
    /// for the day as it now stands, so the rows they have already dealt with go.
    public func refresh() async {
        repinBadgeFilter()
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
                // succeed, which is what clears a stale banner. It also CONFIRMS a
                // primed cache: the bridge was asked about this exact ETag and said the
                // document still stands, so the day on screen is live, not stale.
                confirmFresh()
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
        confirmFresh()
        clearFailure()
    }

    /// Mark what is on screen as confirmed against the bridge just now. The cache WRITE
    /// is the client's (it holds the bridge's own bytes); this is only the model's note
    /// of when that happened.
    private func confirmFresh() {
        lastFetchedAt = now()
        isShowingCachedSnapshot = false
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
        for (id, deferred) in overlay.deferrals {
            guard let item = byId[id] else {
                overlay.deferrals.removeValue(forKey: id)
                continue
            }
            // Per-field, like a check: retired only once the server's item agrees,
            // so a fetch that raced ahead of a still-in-flight postponement cannot
            // put the row back in the badge under the user's hand.
            if item.deferred == deferred { overlay.deferrals.removeValue(forKey: id) }
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
        lastFailureWasUnreachable = false
        lastErrorMessage = nil
        // A completed round trip to the day-file endpoints outranks the shell's
        // `GET /health` probe about whether the bridge is reachable: it is the same
        // question asked of the exact route this screen writes to. Clearing the
        // shell's flag here means one successful pull-to-refresh restores editing
        // immediately, instead of leaving the screen read-only until the next probe.
        isNetworkUnreachable = false
        lastReadOnlyNotice = nil
    }

    private func fail(_ error: any Error) {
        isOffline = true
        lastFailureWasUnreachable = (error as? JesseError)?.isUnreachable ?? false
        lastErrorMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    // MARK: - Mutations

    /// The wording a refused change gets when there is nothing to capture it with — no
    /// queue wired in, or no day on screen to capture it against. Public so a shell can
    /// render it without inventing a second sentence for the same situation.
    public static let readOnlyNotice =
        "You're offline, so the day is read-only. Nothing was saved and nothing is waiting to send — try again once the bridge is reachable."

    /// The wording a CAPTURED change gets. The other half of the same moment, and the
    /// difference the whole queue exists to make.
    public static let queuedNotice =
        "Saved offline, will apply when the bridge is back."

    /// Refuse a mutation while the screen is read-only, and say so.
    ///
    /// This is now the LAST resort rather than the rule. It used to be the whole
    /// policy, on the argument that `Today.md` is rewritten every morning so a held tap
    /// would replay against a document that has moved on — true of a blind replay, and
    /// not a reason to drop the capture. A change that carries the day it was made
    /// against and the identity of what it was made about can be replayed safely and
    /// refused honestly when neither still resolves (see `IntentReplayer`).
    ///
    /// So a read-only screen refuses only when it cannot capture: no queue was injected
    /// (the Mac shell, previews, most tests), or no day has loaded, in which case there
    /// is no `dayDate` to make the replay safe and a captured change would be exactly
    /// the blind promise the original argument was about.
    private func refuseIfReadOnly() -> Bool {
        guard isReadOnly else {
            lastReadOnlyNotice = nil
            return false
        }
        lastReadOnlyNotice = Self.readOnlyNotice
        return true
    }

    // MARK: - Capture

    /// The day every capture is made against: the snapshot's own `date`.
    ///
    /// `nil` disables capture entirely, and that is the point — a change with no day
    /// behind it cannot be replayed safely, so it is refused instead of promised.
    private var captureDay: String? {
        guard let date = serverSnapshot?.date, !date.isEmpty else { return nil }
        return date
    }

    /// Whether a change made right now would be held rather than sent or refused.
    /// Read by a view to decide which sentence it is about to show.
    public var capturesOffline: Bool { pending != nil && captureDay != nil }

    /// Build the record for one day-file change. `nil` when nothing can be captured.
    ///
    /// The item is looked up in the FILE-ORDER snapshot, overlay included, because the
    /// lead and section it carries are what a rebuilt day is searched by — and the row
    /// the user acted on is the row they were looking at.
    private func record(_ kind: PendingIntentKind, id: String,
                        payload: PendingIntentPayload = PendingIntentPayload(),
                        intentId: UUID = UUID()) -> PendingIntentRecord? {
        guard let day = captureDay else { return nil }
        let item = snapshot?.item(id: id) ?? serverSnapshot?.item(id: id)
        return PendingIntentRecord(id: intentId, kind: kind, dayDate: day,
                                   itemId: id,
                                   leadText: item?.lead,
                                   sectionName: item?.sectionName,
                                   payload: payload,
                                   createdAt: now(),
                                   tz: zone())
    }

    /// **Hold one change and show it as held.**
    ///
    /// The overlay is applied by the caller exactly as it would be for a live tap —
    /// the whole point is that the day reads as the user left it — and the id joins
    /// `overlay.queued` so the row can say which of the two it is.
    ///
    /// Returns whether the change was captured. `false` means the caller must fall back
    /// to the refusal.
    @discardableResult
    private func capture(_ intent: PendingIntentRecord?) -> Bool {
        guard let pending, let intent else { return false }
        pending.append(intent)
        if let id = intent.itemId { overlay.queued.insert(id) }
        lastReadOnlyNotice = Self.queuedNotice
        lastConflictMessage = nil
        refreshPending()
        return true
    }

    /// The queue as THIS screen shows it: the outstanding day-file changes, oldest first.
    ///
    /// Narrowed to its own kinds, because the two tabs share one store and one replayer
    /// and each shows the half it is about — a meal held for the Health tab has nothing
    /// to do with the day file, and a list that showed both would be telling each screen
    /// about the other's work.
    ///
    /// Mirrored into an observable property rather than read through the store on every
    /// render, because the store is a plain object and `@Observable` cannot see through
    /// it — a list bound to `pending.all()` would never redraw when a replay landed.
    public private(set) var pendingIntents: [PendingIntentRecord] = []

    /// Re-read the queue. Called after anything that can change it, and by the shell
    /// once a replay has run.
    ///
    /// `overlay.queued` is DERIVED here rather than accumulated, and that is what keeps
    /// it honest: it is exactly the ids the store is still holding an unlanded claim
    /// for, so an intent that applied, was refused, or was discarded stops its row
    /// saying "waiting" without anything having had to remember to say so.
    public func refreshPending() {
        pendingIntents = (pending?.outstanding() ?? []).filter(\.kind.isDayFileWrite)
        overlay.queued = Set(
            pendingIntents
                .filter { $0.state == .queued || $0.state == .replaying }
                .compactMap(\.itemId))
    }

    /// **Drop the local claim about one item** — what a REFUSED replay owes the day.
    ///
    /// A refusal means the change did not happen, so leaving the box ticked would be
    /// the app lying about the vault. The pending row survives (carrying its reason and
    /// its Tell-Jesse fallback); only the optimism goes.
    public func settleOptimism(itemId: String) {
        overlay.settle(itemId)
    }

    /// How many changes are waiting or were refused — the number on the pending header.
    public var pendingCount: Int { pendingIntents.count }

    /// **Forget one captured change**, at the user's word. The overlay entry goes with
    /// it, so the day snaps back to what the bridge actually holds.
    public func discardPending(id: UUID) {
        guard let pending else { return }
        let itemId = pendingIntents.first { $0.id == id }?.itemId
        pending.delete(id: id)
        if let itemId { overlay.settle(itemId) }
        refreshPending()
    }

    /// Put a refused change back in the queue so the next replay tries it again — what
    /// a per-row Retry means. A no-op for a row that is not refused.
    public func retryPending(id: UUID) {
        guard let pending, var record = pendingIntents.first(where: { $0.id == id }),
              record.state == .refused else { return }
        record.state = .queued
        record.refusalReason = nil
        pending.update(record)
        refreshPending()
    }

    /// Refuse an interaction the view has not started yet — for the interactions that
    /// END IN A CAPTURABLE CHANGE.
    ///
    /// It exists for the evidence sheet: opening one while the day was read-only used to
    /// take a note off the user and then throw it away, so the refusal had to be
    /// reachable before the flow rather than after it.
    ///
    /// **With a queue behind it, the note is no longer thrown away**, so this must NOT
    /// refuse when the change can be held — a guard that still fired would mean the tap
    /// never reached `check` and the capture never happened. It refuses only when capture
    /// is impossible, which is the situation the original wording describes.
    ///
    /// Returns whether the interaction was refused, so a caller reads as a guard.
    @discardableResult
    public func refuseInteractionIfReadOnly() -> Bool {
        guard isReadOnly, !capturesOffline else {
            if !isReadOnly { lastReadOnlyNotice = nil }
            return false
        }
        lastReadOnlyNotice = Self.readOnlyNotice
        return true
    }

    /// Refuse an action that FIRES A TURN, which is never captured.
    ///
    /// Propagate, a wiki chip and Process-updates all start a conversation that rewrites
    /// project files, and none of them is a small fact about one day that a replay could
    /// re-aim. A turn fired at an unreachable bridge is a request that looks sent and is
    /// not, so these keep the refusal they have always had — even on a screen where a
    /// checkbox is now held.
    ///
    /// A separate function rather than a flag, because the two questions genuinely
    /// differ and a caller reading `refuseInteractionIfReadOnly` at a Propagate site
    /// would silently get the wrong answer the day capture widened.
    @discardableResult
    public func refuseTurnIfReadOnly() -> Bool { refuseIfReadOnly() }

    /// Dismiss whichever one-line notice is showing. Both are transient by design:
    /// they describe one refused interaction, not a state of the document.
    public func dismissNotice() {
        lastReadOnlyNotice = nil
        lastConflictMessage = nil
    }

    /// The one notice the screen shows, if any. The read-only refusal wins: when the
    /// bridge is unreachable, a stale conflict message is about a round trip that
    /// happened in a different world.
    public var notice: String? { lastReadOnlyNotice ?? lastConflictMessage }

    /// Tick or untick an item, optionally recording one line of evidence.
    ///
    /// The box flips before the request is sent and stays flipped until the server
    /// either confirms it (the overlay entry retires) or contradicts it (the next
    /// snapshot wins). A tap on an item with no ETag in hand is dropped rather than
    /// sent: without one the bridge answers `428`, and the honest thing is to refetch.
    ///
    /// `intentId` is the id an OFFLINE CAPTURE would be stored under. It exists for one
    /// caller: a check made on the WRIST, which carries its own `intentId` and whose
    /// transport redelivers. Storing the capture under that id is what makes a
    /// redelivered wrist intent land once across a phone relaunch — the in-memory
    /// de-duper on the other side of that boundary is empty, and the queue is not.
    public func check(id: String, checked: Bool, evidence: String? = nil,
                      intentId: UUID = UUID()) async {
        // Order matters: the missing-tag path runs FIRST. With no ETag in hand there
        // is nothing to refuse against — the only useful act is to go and get one,
        // which is also a live re-test of whether the bridge is reachable at all.
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        let note = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = PendingIntentPayload(evidence: (note?.isEmpty ?? true) ? nil : note)
        let intent = record(checked ? .check : .uncheck, id: id, payload: payload,
                            intentId: intentId)

        // OFFLINE: hold it rather than refuse it. The overlay below is applied either
        // way, so the day reads the same; what a capture adds is the promise to send it.
        if isReadOnly, capture(intent) {
            applyCheckOverlay(id: id, checked: checked, note: note)
            return
        }
        if refuseIfReadOnly() { return }
        lastConflictMessage = nil
        applyCheckOverlay(id: id, checked: checked, note: note)
        await perform(id: id, capturing: intent) { client in
            try await client.checkItem(id: id, checked: checked, evidence: note,
                                       at: self.now(), day: nil, ifMatch: tag)
        }
    }

    /// The optimism a check carries, applied identically whether the tap was sent or
    /// captured. One function so the two paths cannot drift — a queued check that
    /// rendered differently from a sent one would be a second definition of what
    /// ticking a box looks like.
    private func applyCheckOverlay(id: String, checked: Bool, note: String?) {
        // Before the box flips: ticking an item takes it out of the badge set, and the
        // row must not leave the filtered view under the finger that ticked it.
        pinRowsOnScreen()
        overlay.checks[id] = checked
        if checked, let note, !note.isEmpty {
            overlay.evidence[id] = note
        } else {
            overlay.evidence.removeValue(forKey: id)
        }
    }

    /// Reorder an item.
    ///
    /// The row moves immediately under its OLD id — the new one is a hash of the
    /// destination section the client cannot compute — and the response's snapshot
    /// then decides where it really lives and under what id. See `settleMove`.
    public func move(id: String, op: TodayMoveOp, capturable: Bool = true) async {
        // Order matters: the missing-tag path runs FIRST. With no ETag in hand there
        // is nothing to refuse against — the only useful act is to go and get one,
        // which is also a live re-test of whether the bridge is reachable at all.
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        // `capturable` is false for exactly one caller: an op that is part of a DRAG's
        // multi-write plan. See `reorder`.
        let intent = capturable
            ? record(.move, id: id,
                     payload: PendingIntentPayload(moveOp: op.wireOp,
                                                   moveSection: op.destinationSection))
            : nil
        if isReadOnly, capture(intent) {
            pinRowsOnScreen()
            overlay.moves[id] = op
            return
        }
        if refuseIfReadOnly() { return }
        lastConflictMessage = nil
        let before = serverSnapshot
        let knownIds = Set(before?.allItems.map(\.id) ?? [])
        let item = snapshot?.item(id: id) ?? before?.item(id: id)
        pinRowsOnScreen()
        overlay.moves[id] = op

        await perform(id: id, capturing: intent, adopting: { [weak self] snap in
            guard let self else { return }
            self.settleMove(id: id, item: item, knownIds: knownIds, in: snap)
        }) { client in
            try await client.moveItem(id: id, op: op, at: self.now(), day: nil, ifMatch: tag)
        }
    }

    /// **Land a dragged row**, as durable move ops.
    ///
    /// The gesture is the shell's; the WRITES are here, and they are the same writes
    /// every other reorder makes. Each op goes through `move(id:op:)` — the same ETag,
    /// the same optimistic overlay, the same `409`/`410`/`412` handling, the same
    /// re-key after a cross-section landing. A drag that took a private path to the
    /// bridge would be a second implementation of all of that, and the second one is
    /// the one that reorders the file blind.
    ///
    /// Three things are refused outright, and each writes NOTHING (the row snaps back):
    /// a landing the day file's structure forbids (`TodayReorderGuard`), a read-only
    /// screen, and a drop that changed nothing. The plan is returned so a caller can
    /// tell those apart without re-deriving them.
    ///
    /// The id is RE-DERIVED between ops rather than carried: `to_do_now` changes an
    /// item's id, so the second op of a `[.toDoNow, .down]` plan would otherwise be
    /// aimed at an id the file no longer has. Same rule as `settleMove`, applied to the
    /// only other place several writes describe one intent.
    @discardableResult
    public func reorder(id: String, to target: TodayDropTarget) async -> TodayReorderPlan {
        guard let snapshot, let item = snapshot.item(id: id) else {
            let refusal = TodayReorderPlan.refused(TodayReorderGuard.vanishedMidDrag)
            lastConflictMessage = TodayReorderGuard.vanishedMidDrag
            return refusal
        }
        // The lens is the model's to know about, so the refusal is too. A landing other
        // than "the top" is an index in the SORTED rows, and the file has no such
        // position; index 0 is exempt because "the top of this section" means the same
        // thing under every lens — the same argument `availableMoves` makes for keeping
        // the two absolute ops and withholding `up`/`down`.
        if target.index != 0, sortKey(for: target.sectionName).reorders {
            lastConflictMessage = TodayReorderGuard.notWhileSorted
            return .refused(TodayReorderGuard.notWhileSorted)
        }
        let plan = TodaySemantics.reorderPlan(for: item, to: target, in: snapshot)
        switch plan {
        case .unchanged:
            return plan
        case .refused(let message):
            lastConflictMessage = message
            return plan
        case .ops(let ops):
            // Asked BEFORE the first write, not between the second and the third: a
            // multi-op plan that ran out of network halfway would leave the row in a
            // position nobody asked for.
            //
            // A DRAG IS NOT CAPTURED, unlike the single move ops the menu and the swipe
            // offer. A landing is a plan of up to two writes whose second op is aimed at
            // an id the FIRST one changes, so a captured drag would have to replay a
            // sequence against a document it has not seen yet — and ordering on a
            // rebuilt day is the one thing replay cannot mean anything about anyway
            // (see `IntentReplayer`, which refuses a queued move whose day has rolled).
            // Refusing the gesture and letting the row snap back is the honest answer.
            if refuseIfReadOnly() { return .refused(Self.readOnlyNotice) }
            var current = id
            for op in ops {
                let known = Set(serverSnapshot?.allItems.map(\.id) ?? [])
                await move(id: current, op: op, capturable: false)
                // Stop at the first op that did not land. Piling the rest on would
                // aim them at a document the bridge has already disagreed with.
                guard lastConflictMessage == nil, !isReadOnly, let snap = serverSnapshot
                else { break }
                if snap.item(id: current) != nil { continue }
                guard let next = TodaySemantics.rekeyed(item, in: snap, excluding: known)
                else { break }
                current = next
            }
            return plan
        }
    }

    /// **This item is gone** — what a `410` from somewhere OTHER than a mutation means
    /// for the list.
    ///
    /// The detail read is the case that matters: it is keyed by the same item id, so it
    /// learns the row has left the file while the list is still drawing it. Take the
    /// row off the screen now, say so once, and refetch for the rest — exactly what the
    /// mutation path already does for its own `410`, rather than leaving the list
    /// showing a row whose every tap will fail.
    public func itemVanished(id: String) async {
        overlay.settle(id)
        overlay.removed.insert(id)
        lastConflictMessage = Self.itemGoneNotice
        await fetch(conditional: false)
    }

    /// The one-line notice for a row that left the day file under the user.
    public static let itemGoneNotice =
        "That item isn't in today's day file any more — a rebuild dropped it, or its wording changed."

    /// **Focus an item** — "work on this next", as a durable edit to the day file.
    ///
    /// One line, because that is the whole of it: focus is spelled in terms of the two
    /// absolute move ops the bridge already has, so it inherits the optimistic overlay,
    /// the ETag, the re-key after a cross-section move and every `409`/`410`/`412` path
    /// that `move` already handles. A separate write path for focus would be a second
    /// implementation of all of that, and the second one is the one that gets the
    /// re-keying wrong.
    public func focus(id: String, _ focus: TodayFocus) async {
        await move(id: id, op: focus.moveOp)
    }

    /// **Postpone an item for today**, or bring it back.
    ///
    /// The third state between open and done, and the reason it exists: a day that
    /// holds work which is not going to happen today could only be cleared by
    /// ticking the item off, which records it as DONE and which `Close it at source`
    /// would then propagate into the project files. Postponing takes the row out of
    /// the badge and out of its section's open count, leaves the item otherwise
    /// untouched, and expires with the day.
    ///
    /// **Nothing is written to `Today.md`.** The bridge keeps this in a day-scoped
    /// store, so there is no markdown to unwind tomorrow and no ETag conflict with a
    /// turn mid-write — but the ETag is still sent and still checked, because the
    /// response is a whole fresh snapshot and a client editing a day it is not
    /// looking at should refetch rather than act.
    public func postpone(id: String, deferred: Bool) async {
        // Order matters, exactly as in `check`: with no ETag in hand there is
        // nothing to refuse against, and the only useful act is to go and get one.
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        let intent = record(deferred ? .defer : .undefer, id: id)
        if isReadOnly, capture(intent) {
            pinRowsOnScreen()
            overlay.deferrals[id] = deferred
            return
        }
        if refuseIfReadOnly() { return }
        lastConflictMessage = nil
        // Same reason as `check`: postponing is the other way a row leaves the badge
        // set, and it has to stay readable long enough to be undone.
        pinRowsOnScreen()
        overlay.deferrals[id] = deferred
        await perform(id: id, capturing: intent) { client in
            try await client.postpone(id: id, deferred: deferred, at: self.now(),
                                      day: nil, ifMatch: tag)
        }
    }

    /// Mark a glanceable row seen. The dot clears at once; the bridge's glance store
    /// is what makes it stay cleared across a relaunch.
    public func glance(id: String) async {
        // Order matters: the missing-tag path runs FIRST. With no ETag in hand there
        // is nothing to refuse against — the only useful act is to go and get one,
        // which is also a live re-test of whether the bridge is reachable at all.
        guard let tag = etag, !tag.isEmpty else {
            await load()
            return
        }
        if refuseIfReadOnly() { return }
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
                         capturing intent: PendingIntentRecord? = nil,
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
            // A TRANSPORT failure is the other way a change meets an absent bridge, and
            // the interesting one: the probe said reachable, the tap went out, and the
            // network died under it. Capturing here is what makes the queue cover the
            // whole outage rather than only the part the probe noticed first — without
            // it, the tap that DISCOVERS the outage is the one tap that gets lost.
            //
            // Only a transport failure. A `500` means the bridge heard us and something
            // else went wrong; replaying that is a retry loop, not a capture.
            let unreachable = (error as? JesseError)?.isUnreachable ?? false
            if unreachable, capture(intent) {
                fail(error)
                return
            }
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
        // The badge filter's pins are keyed by id too, so they follow the same rule the
        // overlay does: a pin left under the old id would hold a row that no longer
        // exists, and the row it was actually holding would be judged on membership
        // alone. A row moved OUT of Do Now still leaves the filtered view, because it is
        // not in the badge set and no longer in the section the view draws. That is the
        // honest reading of "I moved this somewhere else".
        if pinnedBadgeIDs.remove(id) != nil { pinnedBadgeIDs.insert(newId) }
    }
}
