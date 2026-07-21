import XCTest
import JesseNetworking
import JesseDietDisplay

// The Mac Health tab's seam (not pixels): the shared `HealthDashboardModel` the Mac's
// `MacHealthView` owns, driven through a fake `DietSnapshotProviding` that returns a
// canned snapshot, the same seam the iPhone uses. Proves the Mac target links the
// shared display layer and that a bridge-fed load reaches `.content` and day paging
// moves the viewed date. The rich render/semantics are covered once in the package
// suite (JesseDietDisplayTests); this asserts only the Mac's wiring on top of it.
@MainActor
final class MacHealthDashboardTests: XCTestCase {

    /// A fake bridge client serving a distinct snapshot per requested date (nil = today),
    /// with a fixed `availableDays` set so paging has somewhere to go.
    private final class FakeDietClient: DietSnapshotProviding {
        let today: String
        let available: [String]
        init(today: String, available: [String]) {
            self.today = today
            self.available = available
        }
        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            let served = date ?? today
            let isHistorical = served != today
            let days = "[" + available.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            let json = """
            { "asOf": "t", "today": { "date": "\(served)", "exercise": [], "meals": [],
              "targets": \(isHistorical ? "null" : "{}") },
              "errors": [], "availableDays": \(days),
              "historical": \(isHistorical), "fidelity": "\(isHistorical ? "reconstructed" : "live")" }
            """
            return try! DietSnapshot.decode(from: Data(json.utf8))
        }
    }

    private func model(today: String, available: [String]) -> HealthDashboardModel {
        let fake = FakeDietClient(today: today, available: available)
        return HealthDashboardModel(makeClient: { fake }, now: { Date() })
    }

    func testBridgeFedLoadReachesContent() async {
        let m = model(today: "2026-07-12", available: ["2026-07-08", "2026-07-12"])
        XCTAssertEqual(m.displayState, .loading)
        await m.load()
        guard case .content(let snap) = m.displayState else {
            return XCTFail("a successful bridge load must reach .content")
        }
        XCTAssertEqual(snap.today.date, "2026-07-12")
        XCTAssertTrue(m.isViewingToday)
    }

    func testPagingBackMovesTheViewedDate() async {
        let m = model(today: "2026-07-12", available: ["2026-07-08", "2026-07-12"])
        await m.load()
        XCTAssertEqual(m.currentDate, "2026-07-12")
        XCTAssertTrue(m.canGoBack)

        await m.goBack()
        XCTAssertEqual(m.currentDate, "2026-07-08", "paging back moves the viewed day")
        XCTAssertFalse(m.isViewingToday)

        await m.goToToday()
        XCTAssertTrue(m.isViewingToday, "jump-to-today returns to the live day")
        XCTAssertEqual(m.currentDate, "2026-07-12")
    }
}
