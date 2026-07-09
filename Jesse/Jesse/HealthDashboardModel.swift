import Foundation
import Observation

// The Health tab's view model. Owns the last-good snapshot and the fetch state,
// and exposes a single `displayState` the views switch on. Two invariants shape it:
//
//  * A previously-rendered screen is NEVER blanked by a failed refresh — once a
//    snapshot has loaded, `displayState` stays `.content` even when the newest
//    fetch throws (the error is remembered as `refreshError` for a subtle stamp,
//    not promoted to a full-screen empty state).
//  * Every distinct failure has its own full-screen empty state — but only before
//    the first successful load, when there's nothing to keep showing.
//
// The client is injected as a factory so config changes (re-pairing) are picked up
// on the next load, and so tests/previews drive every state through the protocol
// fake. `now` is injected for deterministic staleness.
@MainActor
@Observable
final class HealthDashboardModel {
    /// The last successfully-fetched snapshot, kept across refreshes.
    private(set) var snapshot: DietSnapshot?
    /// A fetch is in flight (drives the "refreshing" affordance; the screen keeps
    /// showing the cached snapshot underneath).
    private(set) var isLoading = false
    /// The most recent fetch error, cleared on the next success. Used for the empty
    /// states (no snapshot yet) and the subtle "couldn't refresh" stamp (has one).
    private(set) var lastError: DietFetchError?

    private let makeClient: () -> any JesseClientProtocol
    let now: () -> Date

    init(makeClient: @escaping () -> any JesseClientProtocol = { JesseClient(config: ConfigStore.load()) },
         now: @escaping () -> Date = { Date() }) {
        self.makeClient = makeClient
        self.now = now
    }

    /// What the tab root renders. `.content` wins whenever a snapshot exists, so a
    /// failed refresh never blanks the screen.
    enum DisplayState: Equatable {
        case loading                 // first load, nothing cached yet
        case content(DietSnapshot)   // a snapshot to render (possibly mid-refresh)
        case empty(DietFetchError)   // no snapshot AND a fetch error → empty state
    }

    var displayState: DisplayState {
        if let snapshot { return .content(snapshot) }
        if let lastError { return .empty(lastError) }
        return .loading
    }

    /// A refresh error to surface subtly *while still showing content* — nil unless
    /// a snapshot is already on screen and the latest fetch failed.
    var refreshError: DietFetchError? {
        snapshot != nil ? lastError : nil
    }

    /// Fetch a fresh snapshot. On success it replaces the cached snapshot and clears
    /// the error; on failure it records the error but keeps the cached snapshot.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await makeClient().fetchDietSnapshot()
            lastError = nil
        } catch let e as DietFetchError {
            lastError = e
        } catch {
            lastError = .unreachable(error.localizedDescription)
        }
    }
}
