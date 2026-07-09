import XCTest
@testable import Jesse

// The Health tab view model: a successful load surfaces `.content`; each fetch
// error before the first success surfaces the matching `.empty` state; and a
// failed refresh AFTER a good load never blanks the screen (stays `.content`, with
// `refreshError` set for the subtle stamp).

final class HealthDashboardModelTests: XCTestCase {

    /// A fake whose `fetchDietSnapshot` returns scripted results in order (the last
    /// repeats). Only the diet method is exercised; the rest are unreachable.
    @MainActor
    private final class DietFakeClient: JesseClientProtocol {
        enum Outcome { case snapshot(DietSnapshot); case error(DietFetchError) }
        private var outcomes: [Outcome]
        private(set) var fetchCount = 0
        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func fetchDietSnapshot() async throws -> DietSnapshot {
            let o = outcomes[min(fetchCount, outcomes.count - 1)]
            fetchCount += 1
            switch o {
            case .snapshot(let s): return s
            case .error(let e): throw e
            }
        }
        // Unused by these tests.
        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "x")
        }
        func result(jobId: String) async throws -> JesseResultState { .running }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
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
}
