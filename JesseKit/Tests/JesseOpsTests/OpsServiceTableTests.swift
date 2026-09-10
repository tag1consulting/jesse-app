import XCTest
import JesseNetworking
@testable import JesseOps

// The miniserve diet dashboard was RETIRED, not hidden: the Health tab renders natively from
// `GET /jesse/diet`, the HTML it served is deleted, and its launchd job is removed from the
// machine. A restart button for it would fail against a job that no longer exists, and the
// sentinel no longer accepts the slug, so the table the app builds from must not carry it.
final class OpsServiceTableTests: XCTestCase {
    func testTheRestartableServicesAreTheSentinelsFour() {
        XCTAssertEqual(SentinelClient.Service.allCases.map(\.rawValue),
                       ["bridge", "autocommit", "lock-reaper", "qmd-update"])
        XCTAssertNil(SentinelClient.Service(rawValue: "miniserve"))
    }

    func testTheStatusCardOrdersOnlyTheFourSlots() {
        XCTAssertEqual(SentinelStatusDocument.serviceOrder,
                       ["bridge", "autocommit", "lock-reaper", "qmd-update"])
    }

    func testTheOpsCardHasNoDashboardServerButton() {
        let actions = OpsAction.allActions(labels: [:])
        let restarts = actions.compactMap { action -> SentinelClient.Service? in
            if case .restart(let service, _) = action { return service }
            return nil
        }
        XCTAssertEqual(restarts, [.bridge, .autocommit, .lockReaper, .qmdUpdate])
        XCTAssertFalse(actions.map(\.buttonTitle).contains { $0.contains("dashboard") },
                       "\(actions.map(\.buttonTitle))")
    }
}
