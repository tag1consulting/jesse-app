import Foundation
import Observation
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

    /// In-memory cache keyed by each snapshot's own `today.date`, so a paged-back
    /// day renders instantly on return.
    private var cache: [String: DietSnapshot] = [:]

    private let makeClient: @MainActor () -> any DietSnapshotProviding
    public let now: () -> Date

    /// The client is a required injection (no iOS-specific default now that the model
    /// lives in the shared package): iOS passes its `JesseClient`, the Mac a
    /// `JesseBridgeClient`, tests/previews a fake. Both concrete clients satisfy the
    /// narrow `DietSnapshotProviding` seam.
    public init(makeClient: @escaping @MainActor () -> any DietSnapshotProviding,
                now: @escaping () -> Date = { Date() }) {
        self.makeClient = makeClient
        self.now = now
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
        return .loading
    }

    /// A refresh error to surface subtly *while still showing content* — nil unless
    /// a snapshot is already on screen and the latest fetch failed.
    public var refreshError: DietFetchError? {
        snapshot != nil ? lastError : nil
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
        } catch let e as DietFetchError {
            lastError = e
        } catch {
            lastError = .unreachable(error.localizedDescription)
        }
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
