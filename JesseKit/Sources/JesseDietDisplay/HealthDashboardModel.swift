import Foundation
import Observation
import JesseCore
import JesseNetworking

// The Health tab's view model. Owns the currently-viewed snapshot, the fetch state,
// day-history paging, and an in-memory per-date cache. Invariants:
//
//  * A previously-rendered screen is NEVER blanked by a failed refresh — once a
//    snapshot has loaded, `displayState` stays `.content` even when the newest
//    fetch throws (the error is remembered as `refreshError` for a subtle stamp).
//  * Every distinct failure has its own full-screen empty state — but only before
//    the first successful load, when there's nothing to keep showing.
//  * The VIEWED date is pinned: a background refresh or day rollover refreshes the
//    day the user is reading, never yanks them to a different one.
//  * A day already fetched this session renders instantly when paged back to
//    (cache hit); pull-to-refresh forces a refetch.
//
// The client is injected as a factory so config changes (re-pairing) are picked up
// on the next load, and so tests/previews drive every state through the protocol
// fake. `now` is injected for deterministic staleness.
@MainActor
@Observable
public final class HealthDashboardModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the model off the main actor, which would route through the isolated-deinit
    // executor hop and abort. An explicit nonisolated deinit keeps teardown off-actor safe
    // (there is nothing to clean up). Same pattern as JesseSearch's models.
    nonisolated deinit {}

    /// The snapshot currently on screen (today or a paged-back day), kept across
    /// refreshes.
    public private(set) var snapshot: DietSnapshot?
    /// A fetch is in flight (drives the "refreshing" affordance; the screen keeps
    /// showing the cached snapshot underneath).
    private(set) var isLoading = false
    /// The most recent fetch error, cleared on the next success.
    private(set) var lastError: DietFetchError?

    /// The date currently being viewed; nil = today (the live day). Pinned — a
    /// background refresh never changes which day this is.
    private(set) var viewedDate: String?
    /// Set when a dated request comes back from an un-updated bridge that ignored
    /// the query parameter (its `today.date` != the requested date). The paged view
    /// surfaces "bridge update needed"; today stays fully functional.
    private(set) var historyUnsupported = false
    /// The union of days the app can page to (from the latest snapshot), ascending.
    private(set) var availableDays: [String] = []
    /// The live day's date, learned from the most recent non-historical snapshot.
    private(set) var todayDate: String?

    /// Which read the Health tab is showing: today's numbers, or the rolling 7/30-day
    /// reframe of every nutrient. Session-scoped ON PURPOSE — it lives here for as long as
    /// the app is running and is written nowhere, so a fresh launch always opens on the
    /// day. The day is what you can still act on; a window is a review you opt into.
    ///
    /// It sits on the model rather than in a view's `@State` so paging, a refresh, or a
    /// transient loading state can't silently reset the mode out from under the user.
    public var nutrientWindow: NutrientWindowMode = .day

    /// In-memory cache keyed by each snapshot's own `today.date`, so a paged-back
    /// day renders instantly on return.
    private var cache: [String: DietSnapshot] = [:]

    /// Set by the platform shell when its reachability probe says the bridge is
    /// unreachable, so the tab goes read-only — and its turn actions go quiet — BEFORE a
    /// tap rather than after one fails. Settable and not derived for exactly the reason
    /// `TodayDashboardModel.isNetworkUnreachable` is: the probe belongs to the shell,
    /// and a library that reached for one of its own would be a second answer to the
    /// same question.
    public var isNetworkUnreachable = false

    /// When the day on screen was last confirmed against the bridge. For a document
    /// restored from disk this is when the fetch that produced it happened, which is
    /// what the "last updated" line reads.
    public private(set) var lastFetchedAt: Date?

    /// Whether what is on screen came off DISK and has not been confirmed live since.
    public private(set) var isShowingCachedSnapshot = false

    /// Whether this tab can still start anything. Read-only means either the shell's
    /// probe came back unreachable or our own last fetch could not reach the bridge; in
    /// both cases the honest screen is the last snapshot, rendered and readable, with
    /// the turn actions disabled rather than fired into a void. NOTHING IS QUEUED —
    /// see `readOnlyNotice`.
    public var isReadOnly: Bool {
        if isNetworkUnreachable { return true }
        if case .unreachable = lastError { return true }
        return false
    }

    /// The wording a refused action gets when there is nothing to capture it with —
    /// no queue wired in, or no diet day on screen to date it against. Matches the day
    /// tab's word for word so the two tabs cannot describe the same situation two ways.
    public static let readOnlyNotice =
        "You're offline, so logging is paused. Nothing was sent and nothing is waiting to send — try again once the bridge is reachable."

    /// The wording a CAPTURED action gets. Identical to the day tab's, for the same
    /// reason the refusal is.
    public static let queuedNotice =
        "Saved offline, will apply when the bridge is back."

    /// The message shown under an empty Health tab that has never been able to load.
    /// Carried as `DietFetchError.unreachable`'s payload so it reaches the SAME empty
    /// state a failed fetch would, rather than a second one that has to be kept in step.
    public static let offlineEmptyNote =
        "This device hasn't loaded your dashboard yet, so there's nothing to show. It'll be here the next time the bridge is reachable."

    /// The one line a screen puts under the offline banner.
    ///
    /// Present in exactly two situations, and `nil` otherwise — the same rule the day tab
    /// applies. Either the dashboard came off DISK and has not been confirmed live since,
    /// or the tab is read-only and what is on screen can no longer be refreshed. A live
    /// dashboard on a reachable bridge carries no stale stamp.
    public var stalenessLine: String? {
        guard isShowingCachedSnapshot || isReadOnly, lastFetchedAt != nil else { return nil }
        return OfflineStamp.cachedLine("Showing the last dashboard loaded",
                                       fetchedAt: lastFetchedAt, now: now())
    }

    private let makeClient: @MainActor () -> any DietSnapshotProviding
    public let now: () -> Date

    /// The on-disk last-good dashboard, or `nil` to keep the pre-cache behavior.
    private let snapshotCache: SnapshotCache?

    /// **The offline capture queue**, or `nil` for the pre-queue behaviour. Optional for
    /// the same reason `TodayDashboardModel`'s is: a shell with no store must keep the
    /// honest refusal rather than promise to save something nowhere.
    private let pending: (any PendingIntentStoring)?

    /// The zone a captured log records. It is not decoration — a quick log replays with
    /// a `(eaten at <RFC3339 with offset>)` stamp, and the offset that means anything is
    /// the one the person was living in when they ate.
    private let zone: @Sendable () -> String

    /// The client is a required injection (no iOS-specific default now that the model
    /// lives in the shared package): iOS passes its `JesseClient`, the Mac a
    /// `JesseBridgeClient`, tests/previews a fake. Both concrete clients satisfy the
    /// narrow `DietSnapshotProviding` seam.
    public init(makeClient: @escaping @MainActor () -> any DietSnapshotProviding,
                now: @escaping () -> Date = { Date() },
                cache: SnapshotCache? = nil,
                pending: (any PendingIntentStoring)? = nil,
                zone: @escaping @Sendable () -> String = { TimeZone.current.identifier }) {
        self.makeClient = makeClient
        self.now = now
        self.snapshotCache = cache
        self.pending = pending
        self.zone = zone
    }

    // MARK: - Capture

    /// **The day a log written right now belongs to**, as the bridge resolved it.
    ///
    /// `dietDay` and not `today.date`, and the difference is the whole reason the field
    /// exists: the diet day runs to 04:00 local, so a snack at 01:00 belongs to
    /// yesterday's log even though the calendar has turned over. A capture dated by the
    /// calendar would put it on the wrong day, and the replay's start-new-day guard
    /// would then compare the wrong two things.
    ///
    /// `nil` on a bridge too old to send it — capture is off rather than guessing, for
    /// the same reason `TodayDashboardModel.captureDay` is nil without a snapshot date.
    public var captureDay: String? {
        guard let day = snapshot?.dietDay, !day.isEmpty else { return nil }
        return day
    }

    /// Whether an action taken right now would be held rather than sent or refused.
    public var capturesOffline: Bool { pending != nil && captureDay != nil }

    /// The queue as this tab shows it — its OWN kinds only.
    ///
    /// The two tabs share one store and one replayer, and each shows the half it is
    /// about: a checkbox held for the day file has nothing to do with the Health tab,
    /// and a list that showed both would be telling each screen about the other's work.
    public private(set) var pendingIntents: [PendingIntentRecord] = []

    /// Re-read the queue. Called after a capture and by the shell once a replay has run.
    public func refreshPending() {
        pendingIntents = (pending?.outstanding() ?? [])
            .filter { $0.kind == .quickLog || $0.kind == .startNewDay }
    }

    /// **Hold a quick log.** Returns whether it was captured; `false` means the caller
    /// must fall back to the refusal.
    ///
    /// A quick log is the SAFEST thing in the whole queue to hold, and it is worth
    /// saying why: it names no item id and depends on no document. Replay sends it as an
    /// ordinary Tell carrying a leading `(eaten at …)` stamp, which the diet pipeline
    /// treats as authoritative — so a lunch captured on a boat is dated when it was
    /// eaten, whenever it eventually arrives.
    @discardableResult
    public func captureQuickLog(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pending, let day = captureDay, !trimmed.isEmpty else { return false }
        pending.append(PendingIntentRecord(kind: .quickLog, dayDate: day,
                                           payload: PendingIntentPayload(text: trimmed),
                                           createdAt: now(), tz: zone()))
        refreshPending()
        return true
    }

    /// **Hold a Start-new-day.** Returns whether it was captured.
    ///
    /// At most ONE is ever held. The routine is not additive — it audits yesterday and
    /// builds today — so two of them queued is one of them running against a day the
    /// other just created, and a second tap during an outage means "did that go?" rather
    /// than "do it twice".
    @discardableResult
    public func captureStartNewDay() -> Bool {
        guard let pending, let day = captureDay else { return false }
        let alreadyHeld = pending.outstanding().contains {
            $0.kind == .startNewDay && $0.state != .refused
        }
        guard !alreadyHeld else {
            refreshPending()
            return true
        }
        pending.append(PendingIntentRecord(kind: .startNewDay, dayDate: day,
                                           createdAt: now(), tz: zone()))
        refreshPending()
        return true
    }

    /// Forget one captured action, at the user's word.
    public func discardPending(id: UUID) {
        pending?.delete(id: id)
        refreshPending()
    }

    /// Put a refused action back in the queue so the next replay tries it again.
    public func retryPending(id: UUID) {
        guard let pending, var record = pendingIntents.first(where: { $0.id == id }),
              record.state == .refused else { return }
        record.state = .queued
        record.refusalReason = nil
        pending.update(record)
        refreshPending()
    }

    /// Render the last dashboard this device was given, before any network call, so a
    /// COLD LAUNCH WITH NO NETWORK draws it immediately instead of a spinner that
    /// resolves into an error. A no-op once anything has loaded.
    ///
    /// Only the LIVE day is primed. A paged-back day is a deliberate navigation, and
    /// restoring one on launch would open the tab on a day the user last looked at
    /// three weeks ago; the dated entries in the cache serve `goBack()` instead.
    public func primeFromCache() {
        guard snapshot == nil, let snapshotCache,
              let entry = snapshotCache.load(key: SnapshotCacheKey.liveDiet, now: now()),
              let snap = try? DietSnapshot.decode(from: entry.body) else { return }
        apply(snap, date: nil)
        lastFetchedAt = entry.fetchedAt
        isShowingCachedSnapshot = true
    }

    /// What the tab root renders. `.content` wins whenever a snapshot exists, so a
    /// failed refresh never blanks the screen.
    public enum DisplayState: Equatable {
        case loading                 // first load, nothing cached yet
        case content(DietSnapshot)   // a snapshot to render (possibly mid-refresh)
        case empty(DietFetchError)   // no snapshot AND a fetch error → empty state
    }

    public var displayState: DisplayState {
        if let snapshot { return .content(snapshot) }
        if let lastError { return .empty(lastError) }
        // Nothing cached and the shell's probe already says the bridge is unreachable.
        // Reported as the SAME `.unreachable` empty state a failed fetch produces
        // ("Can't reach the bridge", never the pairing CTA), reached before the fetch's
        // own 30s timeout can resolve — otherwise a cold launch on a plane spins.
        if isNetworkUnreachable { return .empty(.unreachable(Self.offlineEmptyNote)) }
        return .loading
    }

    /// A refresh error to surface subtly *while still showing content* — nil unless
    /// a snapshot is already on screen and the latest fetch failed.
    public var refreshError: DietFetchError? {
        snapshot != nil ? lastError : nil
    }

    // MARK: - "Ask about this"

    /// The whole-page ask context for whatever this model currently has on screen, or nil
    /// before anything has loaded.
    ///
    /// It lives HERE rather than on `TodayScreen` because of where the tab's Ask BUTTON
    /// has to sit. The Health tab's trailing toolbar group is ordered left-to-right by how
    /// often each item is tapped (see README, "UI conventions"), and a toolbar item
    /// declared on a child view lands AFTER the ones declared on it from outside — so an
    /// Ask declared inside the dashboard would land in the rightmost slot, which belongs
    /// to quick log. Declaring it in the shell keeps that order intact, and the shell has
    /// the model but not the dashboard's derivations. This is that seam.
    ///
    /// Every derivation below mirrors `TodayScreen`'s own, line for line — the engine
    /// hour, the past-day judging rule, and the window clamp — so the page-level ask and
    /// the screen it describes cannot come from two different readings of the same day.
    public var pageAskContext: HealthAskContext? {
        guard let snapshot else { return nil }
        let clockHour = Calendar.current.component(.hour, from: now())
        let hour = HistoryRender.engineHour(isHistorical: snapshot.isHistorical,
                                            clockHour: clockHour)
        // A past day judges on its own numbers alone, never on a window ending after it.
        let judgeSeries = snapshot.isHistorical ? nil : snapshot.nutrientSeries
        let gauges = DietSemantics.gauges(for: snapshot.today, hour: hour, series: judgeSeries)
        let mode = NutrientTrends.isAvailable(judgeSeries) ? nutrientWindow : .day
        return HealthAsk.day(
            snapshot: snapshot, gauges: gauges, hour: hour, windowMode: mode,
            day: HealthAskDay(iso: snapshot.today.date, isToday: !snapshot.isHistorical))
    }

    // MARK: - Paging surface (all derived from availableDays + the viewed date)

    /// Whether the user is on today (vs a paged-back day).
    public var isViewingToday: Bool { viewedDate == nil }

    /// The date currently being viewed, resolved to a concrete string.
    public var currentDate: String { viewedDate ?? todayDate ?? snapshot?.today.date ?? "" }

    /// Paging over the available days, or nil until we know today's date. Internal: the
    /// paging *decisions* are exposed through `canGoBack` / `goBack` etc., but the
    /// `DietPaging` value itself stays a package detail.
    var paging: DietPaging? {
        guard let todayDate else { return nil }
        return DietPaging(days: availableDays, today: todayDate)
    }

    public var canGoBack: Bool { paging?.canGoBack(from: currentDate) ?? false }
    public var canGoForward: Bool { paging?.canGoForward(from: currentDate) ?? false }

    // MARK: - Loading

    /// Refresh the currently-viewed day (forced refetch). Called on first appear
    /// (viewing today) and on background triggers — the pinned view is preserved.
    public func load() async { await fetch(date: viewedDate, force: true) }

    /// Pull-to-refresh: force a refetch of the day currently on screen.
    public func refresh() async { await fetch(date: viewedDate, force: true) }

    /// Page to the nearest earlier available day (cache hit renders instantly).
    public func goBack() async {
        guard let target = paging?.earlier(than: currentDate) else { return }
        await fetch(date: pagingDate(target), force: false)
    }

    /// Page to the nearest later available day; forward from the last past day lands
    /// on today.
    public func goForward() async {
        guard let target = paging?.later(than: currentDate) else { return }
        await fetch(date: pagingDate(target), force: false)
    }

    /// Jump straight back to today.
    public func goToToday() async { await fetch(date: nil, force: false) }

    /// A paging target equal to today's date is the live day — request it un-dated
    /// so it renders with full live semantics.
    private func pagingDate(_ target: String) -> String? {
        target == todayDate ? nil : target
    }

    /// Fetch (or, for paging, reuse the cache for) `date` (nil = today). Pins the
    /// viewed date on success. A failed refresh never blanks an existing snapshot.
    private func fetch(date: String?, force: Bool) async {
        // Instant cache hit for paging (never for a forced refresh, and NEVER for the
        // live day). The cache is keyed by each snapshot's own date, so after a day
        // rollover `todayDate` still names yesterday — serving `date == nil` from it
        // would render yesterday's meals as today. The live day is always refetched.
        if !force, let key = date, let cached = cache[key] {
            snapshot = cached
            viewedDate = date
            lastError = nil
            historyUnsupported = false
            return
        }
        // Offline, and the day being asked for is not in memory. A dated day may still
        // be on disk from a previous session; the LIVE day never is served this way,
        // because `primeFromCache` has already offered it and a second read would put a
        // stale day back on screen after a successful one.
        if isReadOnly, let restored = restoreFromDisk(date: date) {
            apply(restored.snapshot, date: date)
            lastFetchedAt = restored.fetchedAt
            isShowingCachedSnapshot = true
            historyUnsupported = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await makeClient().fetchDietSnapshot(date: date)
            // Old-bridge detection: a dated request the bridge ignored (returned
            // today). Flag it and leave the current view untouched — today works.
            if let date, snap.today.date != date {
                historyUnsupported = true
                return
            }
            historyUnsupported = false
            apply(snap, date: date)
            lastError = nil
            lastFetchedAt = now()
            isShowingCachedSnapshot = false
            // A completed round trip to the diet endpoint outranks a `GET /health` probe
            // from thirty seconds ago about whether the bridge is reachable — the same
            // precedence the day tab applies, so one successful refresh restores the
            // tab's actions instead of leaving them disabled until the next probe.
            isNetworkUnreachable = false
        } catch let e as DietFetchError {
            lastError = e
        } catch {
            lastError = .unreachable(error.localizedDescription)
        }
    }

    /// A dated day held on disk from an earlier session, when there is no way to fetch
    /// one now. The live day is deliberately excluded — see the call site.
    private func restoreFromDisk(date: String?) -> (snapshot: DietSnapshot, fetchedAt: Date)? {
        guard let date, let snapshotCache,
              let key = SnapshotCacheKey.diet(date: date),
              let entry = snapshotCache.load(key: key, now: now()),
              let snap = try? DietSnapshot.decode(from: entry.body) else { return nil }
        return (snap, entry.fetchedAt)
    }

    /// Commit a fetched snapshot: pin the view, cache it, and learn today/available.
    private func apply(_ snap: DietSnapshot, date: String?) {
        snapshot = snap
        viewedDate = date
        cache[snap.today.date] = snap
        if let days = snap.availableDays { availableDays = days }
        if !snap.isHistorical { todayDate = snap.today.date }
    }
}
