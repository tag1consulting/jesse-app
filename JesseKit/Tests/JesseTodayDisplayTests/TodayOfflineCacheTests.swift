import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// **Today, offline, from a cold launch.**
//
// The bug this closes: the day was kept in memory only, so a failed REFRESH never blanked
// the screen but a failed LAUNCH had nothing to keep. Kill the app on a plane and a day
// the device had already been given was gone — a spinner, then an error.
//
// The four things asserted here are the four the feature is: a populated cache renders
// before any network call; an empty one offline says so honestly rather than spinning or
// asking the user to pair again; reconnecting replaces the cache with live data and takes
// the banner down; and a tap while offline is still refused and still queues nothing.

@MainActor
final class TodayOfflineCacheTests: XCTestCase {

    private typealias FakeClient = TodayDashboardModelTests.FakeClient

    private var dir: URL!
    private var cache: SnapshotCache!

    /// A Friday afternoon. Everything here is relative to it so no assertion depends on
    /// the wall clock.
    private let now = Date(timeIntervalSince1970: 1_772_530_200)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayOffline-\(UUID().uuidString)", isDirectory: true)
        cache = SnapshotCache(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The bridge's own wire shape for a one-item day, so the cache holds what the
    /// endpoint would really have put there.
    private func cachedDayBody(title: String = "Today: Friday, August 21, 2026",
                               lead: String = "Fire the bisque load") -> Data {
        Data("""
        {"title":"\(title)","date":"2026-08-21","narrative":"A quiet one.",
         "leadItems":[],
         "sections":[{"name":"Do Now","items":[
            {"id":"6d1e3c9a0001","checked":false,"lead":"\(lead)",
             "text":"* [ ] **\(lead)**","links":[],"sectionName":"Do Now"}],
           "reports":[]}],
         "counts":{},"missing":false,"etag":"\\"cached-tag\\""}
        """.utf8)
    }

    private func model(_ fake: FakeClient, cache: SnapshotCache? = nil) -> TodayDashboardModel {
        // `now` is `@Sendable`, so the instant is captured as a value rather than read
        // back off the (non-Sendable) test case.
        let fixed = now
        return TodayDashboardModel(makeClient: { fake }, now: { fixed },
                                   cache: cache ?? self.cache)
    }

    private var unreachable: FakeClient {
        let f = FakeClient()
        f.fetches = [.error(.cannotConnect("laptop"))]
        return f
    }

    // MARK: - Cold launch, offline, with a cache

    /// **The headline case.** A populated cache and a bridge that cannot be reached: the
    /// day renders, the screen is read-only, and the banner says how old it is.
    func testAColdLaunchWithNoNetworkRendersTheCachedDay() async {
        cache.store(cachedDayBody(), key: SnapshotCacheKey.today, etag: "\"cached-tag\"",
                    fetchedAt: now.addingTimeInterval(-12 * 60))
        let fake = unreachable
        let m = model(fake)

        // What the screen does on appear: draw the cache first, THEN ask the bridge.
        m.primeFromCache()
        XCTAssertNotNil(m.snapshot, "the cached day must be on screen before any network call")

        await m.load()

        guard case .content(let day) = m.displayState else {
            return XCTFail("expected the cached day, got \(m.displayState)")
        }
        XCTAssertEqual(day.allItems.first?.lead, "Fire the bisque load")
        XCTAssertTrue(m.isReadOnly, "a day nobody can reach the bridge about is read-only")
        XCTAssertTrue(m.isShowingCachedSnapshot)
        XCTAssertEqual(m.stalenessLine,
                       "Showing the last day loaded — last updated 12 minutes ago.")
    }

    /// The cached ETag is adopted with the document, which is what makes the ONLINE cold
    /// launch cheap: the first fetch is conditional and the common answer is a `304`.
    func testPrimingAdoptsTheCachedETagSoTheFirstFetchIsConditional() async {
        cache.store(cachedDayBody(), key: SnapshotCacheKey.today, etag: "\"cached-tag\"",
                    fetchedAt: now.addingTimeInterval(-60))
        let fake = FakeClient()
        fake.fetches = [.notModified]
        let m = model(fake)

        m.primeFromCache()
        XCTAssertEqual(m.etag, "\"cached-tag\"")
        await m.load()

        XCTAssertEqual(fake.lastIfNoneMatch, .some("\"cached-tag\""))
        // A 304 CONFIRMS the cached document: it is live, not stale, and it therefore
        // carries NO staleness line — which is what stops the stamp flashing up during
        // the ordinary online launch.
        XCTAssertFalse(m.isShowingCachedSnapshot)
        XCTAssertFalse(m.isReadOnly)
        XCTAssertNil(m.stalenessLine)
    }

    /// A day fetched live in this session carries no stale stamp either, until the bridge
    /// goes out of reach — at which point the same line says how old it now is.
    func testALiveDayGainsItsStalenessLineOnlyOnceTheBridgeGoesAway() async {
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"live\""))]
        let m = model(fake)
        await m.load()
        XCTAssertNil(m.stalenessLine)

        m.isNetworkUnreachable = true
        XCTAssertEqual(m.stalenessLine,
                       "Showing the last day loaded — last updated just now.")
    }

    /// A cache must never overwrite a live answer, whatever order the shell calls in.
    func testPrimingIsANoOpOnceSomethingHasLoaded() async {
        cache.store(cachedDayBody(lead: "Stale row"), key: SnapshotCacheKey.today,
                    etag: "\"cached-tag\"", fetchedAt: now.addingTimeInterval(-3600))
        let fake = FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"live\""))]
        let m = model(fake)

        await m.load()
        m.primeFromCache()

        XCTAssertEqual(m.etag, "\"live\"")
        XCTAssertFalse(m.isShowingCachedSnapshot)
        XCTAssertNil(m.snapshot?.allItems.first { $0.lead == "Stale row" })
    }

    // MARK: - Fresh install, offline

    /// No cache and no network: an honest empty-offline state. NOT a spinner, and NOT the
    /// pairing prompt — this user is paired, they are just on a plane.
    func testAFreshInstallOfflineShowsTheOfflineEmptyStateAndNotASpinner() async {
        let m = model(unreachable)
        m.isNetworkUnreachable = true

        m.primeFromCache()
        XCTAssertEqual(m.displayState, .offline,
                       "before the fetch even resolves, the probe's answer is enough")

        await m.load()
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertNil(m.snapshot)
    }

    /// The same state is reached from the FAILURE alone, so a device whose probe has not
    /// come back yet still never spins forever on a dead network.
    func testATransportFailureAloneReachesTheOfflineEmptyState() async {
        let m = model(unreachable)
        await m.load()
        XCTAssertEqual(m.displayState, .offline)
    }

    /// A bridge that ANSWERS is not an offline bridge, and a `500` must not be reported
    /// as one — the device has a network and the problem is a different one.
    func testAServerErrorIsReportedAsAnErrorAndNotAsOffline() async {
        let fake = FakeClient()
        fake.fetches = [.error(.badResponse(500, "boom"))]
        let m = model(fake)
        await m.load()

        guard case .unavailable = m.displayState else {
            return XCTFail("expected .unavailable, got \(m.displayState)")
        }
    }

    // MARK: - Reconnect

    /// Offline with a cache, then the bridge comes back: live data replaces the cached
    /// document and the banner goes.
    func testReconnectingReplacesTheCachedDayAndClearsTheBanner() async {
        cache.store(cachedDayBody(lead: "Cached row"), key: SnapshotCacheKey.today,
                    etag: "\"cached-tag\"", fetchedAt: now.addingTimeInterval(-3600))
        let fake = FakeClient()
        fake.fetches = [.error(.cannotConnect("laptop")),
                        .snapshot(Fixt.snapshot(etag: "\"live-tag\""))]
        let m = model(fake)

        m.primeFromCache()
        await m.load()
        XCTAssertTrue(m.isReadOnly)
        XCTAssertTrue(m.isShowingCachedSnapshot)

        // The probe had also gone red; a successful round trip to the day route outranks
        // it, which is what restores editing without waiting for the next probe.
        m.isNetworkUnreachable = true
        await m.load()

        XCTAssertFalse(m.isReadOnly, "one successful pull restores editing")
        XCTAssertFalse(m.isNetworkUnreachable)
        XCTAssertFalse(m.isShowingCachedSnapshot)
        XCTAssertEqual(m.etag, "\"live-tag\"")
        XCTAssertNil(m.snapshot?.allItems.first { $0.lead == "Cached row" },
                     "the live document replaces the cached one outright")
    }

    // MARK: - Edits stay blocked

    /// A tap while offline mutates nothing, sends nothing, and QUEUES nothing — the
    /// notice says so in as many words, because a queued check would be a promise about a
    /// document that gets rewritten in full every morning.
    func testATapOnACachedDayIsRefusedAndNothingIsQueued() async {
        cache.store(cachedDayBody(), key: SnapshotCacheKey.today, etag: "\"cached-tag\"",
                    fetchedAt: now.addingTimeInterval(-60))
        let fake = unreachable
        let m = model(fake)
        m.primeFromCache()
        m.isNetworkUnreachable = true

        let before = m.snapshot
        await m.check(id: "6d1e3c9a0001", checked: true)

        XCTAssertEqual(fake.checkCount, 0, "nothing was sent")
        XCTAssertEqual(m.snapshot, before, "and nothing on screen moved")
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(m.notice?.contains("nothing is waiting to send") ?? false,
                      "the notice must say plainly that nothing was queued")
    }

    /// The same refusal reaches an interaction that has not started yet, so a screen can
    /// ask BEFORE opening a flow that would end in a write.
    func testAnInteractionIsRefusedBeforeItStarts() {
        let m = model(unreachable)
        m.isNetworkUnreachable = true
        XCTAssertTrue(m.refuseInteractionIfReadOnly())
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
    }

    // MARK: - Degrading

    /// With no cache at all (a device with no Application Support directory) the model
    /// behaves exactly as it did before this feature existed.
    func testWithNoCacheThePrimeIsSilentlyANoOp() {
        let fixed = now
        let fake = unreachable
        let m = TodayDashboardModel(makeClient: { fake }, now: { fixed }, cache: nil)
        m.primeFromCache()
        XCTAssertNil(m.snapshot)
        XCTAssertNil(m.stalenessLine)
    }

    /// A cached body this build cannot decode is a miss, never a crash and never a
    /// half-drawn day.
    func testAnUndecodableCachedBodyIsAMiss() {
        cache.store(Data("not json".utf8), key: SnapshotCacheKey.today, fetchedAt: now)
        let m = model(unreachable)
        m.primeFromCache()
        XCTAssertNil(m.snapshot)
    }

    /// An entry older than the cache's own limit is not served: past a month it is
    /// history, and the honest screen is the empty one.
    func testAnExpiredCacheEntryIsNotRendered() {
        cache.store(cachedDayBody(), key: SnapshotCacheKey.today, etag: "\"cached-tag\"",
                    fetchedAt: now.addingTimeInterval(-SnapshotCache.defaultMaxAge - 60))
        let m = model(unreachable)
        m.primeFromCache()
        XCTAssertNil(m.snapshot)
    }
}
