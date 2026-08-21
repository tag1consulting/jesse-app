import XCTest
@testable import JesseDietDisplay
import JesseNetworking

// **Health, offline, from a cold launch** — the Today tab's story told for the dashboard.
//
// Health had it worse than Today: no reachability at all on either platform, so the tab
// could not go read-only before a tap, and the two turn actions (Quick log, Start new
// day) fired into a void with nothing on screen to say so. And, like Today, the snapshot
// lived in memory only, so a cold launch offline had nothing to draw.
//
// The choice recorded here, deliberately: the turn actions are DISABLED offline, not
// queued. See the CHANGELOG entry for why the chat outbox is not reused for them.

@MainActor
final class HealthOfflineCacheTests: XCTestCase {

    /// Scripts one outcome per fetch (the last repeats), and remembers what it was asked.
    private final class DietFakeClient: DietSnapshotProviding, @unchecked Sendable {
        enum Outcome { case snapshot(DietSnapshot); case error(DietFetchError) }
        private var outcomes: [Outcome]
        private(set) var fetchCount = 0
        private(set) var requestedDates: [String?] = []
        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            requestedDates.append(date)
            let o = outcomes[min(fetchCount, outcomes.count - 1)]
            fetchCount += 1
            switch o {
            case .snapshot(let s): return s
            case .error(let e): throw e
            }
        }
    }

    private var dir: URL!
    private var cache: SnapshotCache!
    private let now = Date(timeIntervalSince1970: 1_772_530_200)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthOffline-\(UUID().uuidString)", isDirectory: true)
        cache = SnapshotCache(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The bridge's own wire shape for one day, so the cache holds what the endpoint
    /// would really have put there.
    private func body(date: String = "2026-08-21", calories: Int = 250,
                      historical: Bool = false,
                      availableDays: [String] = ["2026-08-19", "2026-08-21"]) -> Data {
        let days = availableDays.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {"asOf":"\(date)T14:00:00Z","todayMtime":"\(date)T13:00:00Z",
         "today":{"date":"\(date)","exercise":[],
           "meals":[{"name":"Lunch","time":"12:30","items":[
             {"item":"Salad","cal":\(calories),"p":8,"f":12,"c":20,"fiber":5}]}],
           "targets":{"calories":2100,"protein":190,"fat":65,"carbs":210}},
         "availableDays":[\(days)],"historical":\(historical),
         "errors":[]}
        """.utf8)
    }

    private func snapshot(date: String = "2026-08-21", calories: Int = 250) -> DietSnapshot {
        try! DietSnapshot.decode(from: body(date: date, calories: calories))
    }

    private func decoded(_ data: Data) -> DietSnapshot { try! DietSnapshot.decode(from: data) }

    private func model(_ outcomes: [DietFakeClient.Outcome])
        -> (HealthDashboardModel, DietFakeClient) {
        modelWithCache(outcomes, cache)
    }

    /// The same, with the cache stated explicitly — including `nil`, which is the device
    /// that has no Application Support directory at all.
    private func modelWithCache(_ outcomes: [DietFakeClient.Outcome], _ c: SnapshotCache?)
        -> (HealthDashboardModel, DietFakeClient) {
        let fake = DietFakeClient(outcomes)
        return (HealthDashboardModel(makeClient: { fake }, now: { self.now }, cache: c), fake)
    }

    private let unreachable = DietFetchError.unreachable("Couldn't reach “laptop”.")

    // MARK: - Cold launch, offline, with a cache

    /// **The headline case.** A populated cache and a bridge that cannot be reached: the
    /// dashboard renders, the tab is read-only, and the banner says how old it is.
    func testAColdLaunchWithNoNetworkRendersTheCachedDashboard() async {
        cache.store(body(calories: 640), key: SnapshotCacheKey.liveDiet,
                    fetchedAt: now.addingTimeInterval(-45 * 60))
        let (m, fake) = model([.error(unreachable)])

        m.primeFromCache()
        XCTAssertNotNil(m.snapshot, "the cached dashboard must be on screen before any fetch")

        await m.load()

        guard case .content(let snap) = m.displayState else {
            return XCTFail("expected the cached dashboard, got \(m.displayState)")
        }
        XCTAssertEqual(snap.today.meals.first?.items.first?.cal, 640)
        XCTAssertEqual(fake.fetchCount, 1, "it still tried")
        XCTAssertTrue(m.isReadOnly, "and its failure is what disables the turn actions")
        XCTAssertTrue(m.isShowingCachedSnapshot)
        XCTAssertEqual(m.stalenessLine,
                       "Showing the last dashboard loaded — last updated 45 minutes ago.")
    }

    /// Priming teaches the model which day is live, so the paging controls are usable on
    /// a cached dashboard instead of dead.
    func testPrimingLearnsTheLiveDayFromTheCachedDocument() {
        cache.store(body(), key: SnapshotCacheKey.liveDiet, fetchedAt: now)
        let (m, _) = model([.error(unreachable)])
        m.primeFromCache()

        XCTAssertEqual(m.todayDate, "2026-08-21")
        XCTAssertTrue(m.isViewingToday)
        XCTAssertEqual(m.currentDate, "2026-08-21")
    }

    func testPrimingIsANoOpOnceSomethingHasLoaded() async {
        cache.store(body(calories: 1), key: SnapshotCacheKey.liveDiet,
                    fetchedAt: now.addingTimeInterval(-3600))
        let (m, _) = model([.snapshot(snapshot(calories: 999))])

        await m.load()
        m.primeFromCache()

        XCTAssertEqual(m.snapshot?.today.meals.first?.items.first?.cal, 999)
        XCTAssertFalse(m.isShowingCachedSnapshot)
    }

    /// Paging back while offline is served from disk when a past day was cached — but the
    /// LIVE day never is, because `primeFromCache` has already offered it and a second
    /// read would put a stale day back on screen after a good one.
    func testAPastDayIsRestoredFromDiskWhileOffline() async {
        // Both days were cached in an earlier, online session: the live one (which is
        // what teaches the model where paging can go) and the day before it.
        cache.store(body(), key: SnapshotCacheKey.liveDiet,
                    fetchedAt: now.addingTimeInterval(-3600))
        cache.store(body(date: "2026-08-19", calories: 111, historical: true),
                    key: "diet-2026-08-19", fetchedAt: now.addingTimeInterval(-2 * 3600))
        let (m, fake) = model([.error(unreachable)])
        m.primeFromCache()
        m.isNetworkUnreachable = true
        XCTAssertTrue(m.canGoBack, "the cached live day is what makes paging possible at all")

        await m.goBack()

        XCTAssertEqual(m.snapshot?.today.date, "2026-08-19")
        XCTAssertEqual(m.snapshot?.today.meals.first?.items.first?.cal, 111)
        XCTAssertTrue(m.isShowingCachedSnapshot)
        XCTAssertEqual(fake.fetchCount, 0, "served from disk, with no round trip attempted")
    }

    /// A past day that was never cached is a miss, not a blank screen: the day on screen
    /// stays, exactly as a failed refresh has always been handled.
    func testPagingToAnUncachedDayOfflineKeepsWhatIsOnScreen() async {
        cache.store(body(), key: SnapshotCacheKey.liveDiet,
                    fetchedAt: now.addingTimeInterval(-3600))
        let (m, _) = model([.error(unreachable)])
        m.primeFromCache()
        m.isNetworkUnreachable = true

        await m.goBack()

        XCTAssertEqual(m.snapshot?.today.date, "2026-08-21",
                       "the live day is still what is drawn")
    }

    // MARK: - Fresh install, offline

    /// No cache and no network: the "can't reach the bridge" empty state, reached from
    /// the PROBE, before the fetch's own timeout can resolve. Not a spinner, and never
    /// the pairing prompt — this user is paired, they are just offline.
    func testAFreshInstallOfflineShowsTheOfflineEmptyStateAndNotASpinner() async {
        let (m, _) = model([.error(unreachable)])
        m.isNetworkUnreachable = true

        m.primeFromCache()
        XCTAssertEqual(m.displayState, .empty(.unreachable(HealthDashboardModel.offlineEmptyNote)))

        await m.load()
        guard case .empty(.unreachable) = m.displayState else {
            return XCTFail("expected the unreachable empty state, got \(m.displayState)")
        }
        XCTAssertNil(m.snapshot)
    }

    /// An UNPAIRED app still gets the pairing prompt. Offline and unconfigured are
    /// different problems with different answers, and this is the one that must not
    /// regress: the Mac Health tab's historic dead end was exactly this state.
    func testAnUnpairedAppStillGetsThePairingStateAndNotTheOfflineOne() async {
        let (m, _) = model([.error(.notConfigured)])
        await m.load()
        XCTAssertEqual(m.displayState, .empty(.notConfigured))
        XCTAssertFalse(m.isReadOnly, "unconfigured is not offline")
    }

    /// A bridge that ANSWERS is not an offline bridge: a `503` keeps its own state and
    /// does not disable the turn actions.
    func testAServerErrorIsNotTreatedAsOffline() async {
        let (m, _) = model([.error(.unavailable)])
        await m.load()
        XCTAssertEqual(m.displayState, .empty(.unavailable))
        XCTAssertFalse(m.isReadOnly)
    }

    // MARK: - Reconnect

    func testReconnectingReplacesTheCachedDashboardAndClearsTheBanner() async {
        cache.store(body(calories: 111), key: SnapshotCacheKey.liveDiet,
                    fetchedAt: now.addingTimeInterval(-3600))
        let (m, _) = model([.error(unreachable), .snapshot(snapshot(calories: 999))])

        m.primeFromCache()
        await m.load()
        XCTAssertTrue(m.isReadOnly)
        XCTAssertTrue(m.isShowingCachedSnapshot)

        m.isNetworkUnreachable = true
        await m.load()

        XCTAssertEqual(m.snapshot?.today.meals.first?.items.first?.cal, 999)
        XCTAssertFalse(m.isShowingCachedSnapshot)
        XCTAssertFalse(m.isReadOnly, "one successful refresh re-enables the turn actions")
        XCTAssertFalse(m.isNetworkUnreachable,
                       "a real round trip outranks a stale probe, exactly as on the day tab")
    }

    // MARK: - Turn actions

    /// The read-only notice is the SAME sentence the day tab uses for a refused tap, and
    /// it says plainly that nothing is waiting to send.
    func testTheReadOnlyNoticePromisesNoQueue() {
        XCTAssertTrue(HealthDashboardModel.readOnlyNotice.contains("nothing is waiting to send"))
    }

    /// The shell's probe alone is enough to put the tab read-only, before any fetch has
    /// had a chance to fail — which is what stops a Quick log being fired into a void.
    func testTheProbeAloneDisablesTheTurnActions() {
        let (m, _) = model([.snapshot(snapshot())])
        XCTAssertFalse(m.isReadOnly)
        m.isNetworkUnreachable = true
        XCTAssertTrue(m.isReadOnly)
    }

    // MARK: - Degrading

    func testWithNoCacheThePrimeIsSilentlyANoOp() {
        let (m, _) = modelWithCache([.error(unreachable)], nil)
        m.primeFromCache()
        XCTAssertNil(m.snapshot)
        XCTAssertNil(m.stalenessLine)
    }

    func testAnUndecodableCachedBodyIsAMiss() {
        cache.store(Data("not json".utf8), key: SnapshotCacheKey.liveDiet, fetchedAt: now)
        let (m, _) = model([.error(unreachable)])
        m.primeFromCache()
        XCTAssertNil(m.snapshot)
    }
}
