import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// The Health tab view model: a successful load surfaces `.content`; each fetch
// error before the first success surfaces the matching `.empty` state; and a
// failed refresh AFTER a good load never blanks the screen (stays `.content`, with
// `refreshError` set for the subtle stamp).

@MainActor
final class HealthDashboardModelTests: XCTestCase {

    /// A fake whose `fetchDietSnapshot` returns scripted results in order (the last
    /// repeats). Only the diet method is exercised; the rest are unreachable.
    @MainActor
    private final class DietFakeClient: DietSnapshotProviding {
        enum Outcome { case snapshot(DietSnapshot); case error(DietFetchError) }
        private var outcomes: [Outcome]
        private(set) var fetchCount = 0
        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            let o = outcomes[min(fetchCount, outcomes.count - 1)]
            fetchCount += 1
            switch o {
            case .snapshot(let s): return s
            case .error(let e): throw e
            }
        }
    }

    private func snapshot(date: String = "2026-07-09") -> DietSnapshot {
        let json = """
        { "asOf": "2026-07-09T14:00:00Z", "todayMtime": "2026-07-09T13:00:00Z",
          "today": { "date": "\(date)", "exercise": [], "meals": [], "targets": {} },
          "errors": [] }
        """
        return try! DietSnapshot.decode(from: Data(json.utf8))
    }

    @MainActor
    private func model(_ outcomes: [DietFakeClient.Outcome]) -> HealthDashboardModel {
        let fake = DietFakeClient(outcomes)
        return HealthDashboardModel(makeClient: { fake }, now: { Date() })
    }

    @MainActor
    func testInitialStateIsLoading() {
        let m = model([.snapshot(snapshot())])
        XCTAssertEqual(m.displayState, .loading)
    }

    @MainActor
    func testSuccessfulLoadShowsContent() async {
        let snap = snapshot()
        let m = model([.snapshot(snap)])
        await m.load()
        XCTAssertEqual(m.displayState, .content(snap))
        XCTAssertNil(m.refreshError)
        XCTAssertFalse(m.isLoading)
    }

    @MainActor
    func testEachErrorBeforeFirstLoadIsAnEmptyState() async {
        for e: DietFetchError in [.notConfigured, .unreachable("x"), .authFailed,
                                  .endpointMissing, .unavailable, .decodeFailed, .server(500)] {
            let m = model([.error(e)])
            await m.load()
            XCTAssertEqual(m.displayState, .empty(e), "\(e) must map to its own empty state")
        }
    }

    @MainActor
    func testFailedRefreshNeverBlanksAGoodSnapshot() async {
        let snap = snapshot()
        // First load succeeds, second (a refresh) fails.
        let m = model([.snapshot(snap), .error(.unreachable("dropped"))])
        await m.load()
        XCTAssertEqual(m.displayState, .content(snap))

        await m.load()  // the failing refresh
        XCTAssertEqual(m.displayState, .content(snap), "a failed refresh keeps showing the last-good snapshot")
        XCTAssertEqual(m.refreshError, .unreachable("dropped"), "the refresh error is remembered for the stamp")
    }

    @MainActor
    func testSuccessfulRefreshReplacesSnapshotAndClearsError() async {
        let a = snapshot(date: "2026-07-08")
        let b = snapshot(date: "2026-07-09")
        let m = model([.snapshot(a), .error(.unreachable("x")), .snapshot(b)])
        await m.load()   // a
        await m.load()   // error → still a
        XCTAssertEqual(m.refreshError, .unreachable("x"))
        await m.load()   // b
        XCTAssertEqual(m.displayState, .content(b))
        XCTAssertNil(m.refreshError, "a fresh success clears the error")
    }

    // MARK: - Day-history paging

    /// A fake that serves a distinct snapshot per requested date and records the
    /// dates it was asked for (nil → the live today snapshot).
    @MainActor
    private final class PagingFakeClient: DietSnapshotProviding {
        let today: String
        let available: [String]
        private(set) var requested: [String?] = []
        /// When set, a dated request returns this date instead of the requested one
        /// (simulates an old bridge that ignores `?date=`).
        var ignoresDateReturning: String?
        init(today: String, available: [String], ignoresDateReturning: String? = nil) {
            self.today = today; self.available = available
            self.ignoresDateReturning = ignoresDateReturning
        }
        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            requested.append(date)
            let served = date ?? today
            let effective = (date != nil ? ignoresDateReturning : nil) ?? served
            let isHistorical = effective != today
            let json = """
            { "asOf": "t", "today": { "date": "\(effective)", "exercise": [], "meals": [],
              "targets": \(isHistorical ? "null" : "{}") },
              "errors": [], "availableDays": \(availableJSON),
              "historical": \(isHistorical), "fidelity": "\(isHistorical ? "reconstructed" : "live")" }
            """
            return try! DietSnapshot.decode(from: Data(json.utf8))
        }
        private var availableJSON: String {
            "[" + available.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
    }

    @MainActor
    private func pagingModel(_ fake: PagingFakeClient) -> HealthDashboardModel {
        HealthDashboardModel(makeClient: { fake }, now: { Date() })
    }

    @MainActor
    func testGoBackAndForwardWalkAvailableDays() async {
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-04-15", "2026-07-08", "2026-07-12"])
        let m = pagingModel(fake)
        await m.load()   // today
        XCTAssertTrue(m.isViewingToday)
        XCTAssertTrue(m.canGoBack)
        XCTAssertFalse(m.canGoForward, "forward disabled on today")

        await m.goBack()  // → 2026-07-08
        XCTAssertEqual(m.currentDate, "2026-07-08")
        XCTAssertFalse(m.isViewingToday)
        XCTAssertEqual(m.snapshot?.fidelityKind, .reconstructed)

        await m.goBack()  // → 2026-04-15 (earliest)
        XCTAssertEqual(m.currentDate, "2026-04-15")
        XCTAssertFalse(m.canGoBack, "back disabled at the earliest day")

        await m.goForward()  // → 2026-07-08
        XCTAssertEqual(m.currentDate, "2026-07-08")

        await m.goForward()  // → today
        XCTAssertTrue(m.isViewingToday, "forward from the last past day lands on today")
        XCTAssertEqual(m.snapshot?.fidelityKind, .live)
    }

    @MainActor
    func testJumpToTodayFromAPastDay() async {
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-04-15", "2026-07-12"])
        let m = pagingModel(fake)
        await m.load()
        await m.goBack()  // → 2026-04-15
        XCTAssertFalse(m.isViewingToday)
        await m.goToToday()
        XCTAssertTrue(m.isViewingToday)
        XCTAssertEqual(m.currentDate, "2026-07-12")
    }

    @MainActor
    func testCachedDayRendersWithoutRefetch() async {
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-07-08", "2026-07-12"])
        let m = pagingModel(fake)
        await m.load()          // fetch today
        await m.goBack()        // fetch 2026-07-08
        await m.goForward()     // today — cache hit, no refetch
        await m.goBack()        // 2026-07-08 — cache hit, no refetch
        // Requests: nil (today), "2026-07-08" (back). The two cache hits add nothing.
        XCTAssertEqual(fake.requested, [nil, "2026-07-08"], "paging back to a cached day does not refetch")
    }

    @MainActor
    func testPullToRefreshForcesARefetchOfTheViewedDay() async {
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-07-08", "2026-07-12"])
        let m = pagingModel(fake)
        await m.load()          // nil
        await m.goBack()        // "2026-07-08"
        await m.refresh()       // forced refetch of the viewed day → "2026-07-08" again
        XCTAssertEqual(fake.requested, [nil, "2026-07-08", "2026-07-08"])
        XCTAssertEqual(m.currentDate, "2026-07-08", "refresh keeps the viewed day pinned")
    }

    @MainActor
    func testPinnedViewedDaySurvivesABackgroundRefresh() async {
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-07-08", "2026-07-12"])
        let m = pagingModel(fake)
        await m.load()
        await m.goBack()        // viewing 2026-07-08
        await m.load()          // a background refresh (onAppear/after-turn)
        XCTAssertEqual(m.currentDate, "2026-07-08", "a background refresh never yanks off the viewed day")
        XCTAssertFalse(m.isViewingToday)
    }

    @MainActor
    func testOldBridgeIgnoringDateIsDetected() async {
        // A partially-updated bridge sends availableDays but ignores ?date=, always
        // returning today. Paging back is flagged and today stays functional.
        let fake = PagingFakeClient(today: "2026-07-12",
                                    available: ["2026-07-08", "2026-07-12"],
                                    ignoresDateReturning: "2026-07-12")
        let m = pagingModel(fake)
        await m.load()
        XCTAssertFalse(m.historyUnsupported)
        await m.goBack()  // requests 2026-07-08 but bridge returns today
        XCTAssertTrue(m.historyUnsupported, "date mismatch flags the un-updated bridge")
        XCTAssertTrue(m.isViewingToday, "today stays functional; the view isn't yanked to a wrong day")
    }
}
