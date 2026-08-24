import XCTest
@testable import JesseNetworking

/// The frugal decision table, whole. The point of `FrugalPolicy` being pure is that this
/// file can state every value the six sites read, in both states, without a radio — and
/// that the numbers cannot drift from the ones the sites actually apply.
final class FrugalPolicyTests: XCTestCase {

    private func path(satisfied: Bool = true, expensive: Bool = false,
                      constrained: Bool = false,
                      kind: NetworkInterfaceKind = .wifi) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, isExpensive: expensive,
                            isConstrained: constrained, interfaceKind: kind)
    }

    // MARK: - When it turns on

    func testWiFiWithTheToggleOffIsNotFrugal() {
        let policy = FrugalPolicy.decide(path: path(), forcedOn: false)
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.reason, .none)
    }

    func testCellularIsFrugalWithoutTheToggle() {
        let policy = FrugalPolicy.decide(path: path(expensive: true, kind: .cellular),
                                         forcedOn: false)
        XCTAssertTrue(policy.isActive)
        XCTAssertEqual(policy.reason, .expensive)
    }

    /// Low Data Mode is the USER asking for less, on a network that may not even be
    /// metered. It is reported separately from `expensive` so the explanation can say
    /// which of the two it is.
    func testLowDataModeIsFrugalAndSaysSo() {
        let policy = FrugalPolicy.decide(path: path(constrained: true), forcedOn: false)
        XCTAssertTrue(policy.isActive)
        XCTAssertEqual(policy.reason, .constrained)
    }

    func testTheToggleForcesItOnAnyNetwork() {
        let policy = FrugalPolicy.decide(path: path(), forcedOn: true)
        XCTAssertTrue(policy.isActive)
        XCTAssertEqual(policy.reason, .forced)
    }

    /// The network's own signal outranks the toggle in the REASON, because the
    /// explanation should name the thing the user can act on — turning the toggle off
    /// would not stop frugal mode on a cellular link.
    func testNetworkReasonOutranksTheToggle() {
        XCTAssertEqual(
            FrugalPolicy.decide(path: path(expensive: true, kind: .cellular), forcedOn: true).reason,
            .expensive)
        XCTAssertEqual(
            FrugalPolicy.decide(path: path(constrained: true), forcedOn: true).reason,
            .constrained)
    }

    /// An UNSATISFIED path is not by itself frugal. Frugal mode is about what bytes cost,
    /// and a path with no interface has no cost — what it has is a different problem, and
    /// one that `ConnectivityMonitor` owns.
    func testNoNetworkIsNotByItselfFrugal() {
        let policy = FrugalPolicy.decide(path: path(satisfied: false, kind: .unknown),
                                         forcedOn: false)
        XCTAssertFalse(policy.isActive)
    }

    // MARK: - The decisions themselves

    func testInactivePolicyLeavesEverySiteAtItsPreFrugalValue() {
        let off = FrugalPolicy.off
        XCTAssertEqual(off.skipDietPrefetchIfCacheYoungerThan, 0,
                       "a zero threshold can never be satisfied by an entry with a real "
                       + "age, so the cache-reuse path is off by construction")
        XCTAssertNil(off.attachmentMaxLongEdge, "nil = don't touch the image")
        XCTAssertNil(off.attachmentJPEGQuality, "nil = the downscaler's own 0.85")
        XCTAssertEqual(off.pollFloorSeconds, 0, "leaves the existing 2s → 30s backoff alone")
        XCTAssertEqual(off.sendSweepFPS, 30)
        XCTAssertTrue(off.modelListPollingEnabled)
        XCTAssertEqual(off.explanation, "", "nothing to explain when nothing is saved")
    }

    func testActivePolicyValues() {
        let on = FrugalPolicy.decide(path: path(expensive: true, kind: .cellular),
                                     forcedOn: false)
        XCTAssertEqual(on.skipDietPrefetchIfCacheYoungerThan, 12 * 3600)
        XCTAssertEqual(on.attachmentMaxLongEdge, 1280)
        XCTAssertEqual(on.attachmentJPEGQuality, 0.7)
        XCTAssertEqual(on.pollFloorSeconds, 5)
        XCTAssertEqual(on.sendSweepFPS, 1)
        XCTAssertFalse(on.modelListPollingEnabled)
    }

    /// Every active reason explains itself. A glyph that says "frugal mode" and nothing
    /// else answers no question anyone actually has.
    func testEveryActiveReasonHasAnExplanation() {
        for reason in [FrugalPolicy.Reason.expensive, .constrained, .forced] {
            let policy = FrugalPolicy(isActive: true, reason: reason)
            XCTAssertFalse(policy.explanation.isEmpty, "\(reason) has no explanation")
        }
    }

    /// Nothing frugal mode does is a refusal. Every decision makes something cheaper, and
    /// there is no value in the table that means "not allowed" — a send on one bar must
    /// still be a send.
    func testNoDecisionDisablesSending() {
        let on = FrugalPolicy.decide(path: path(constrained: true), forcedOn: false)
        XCTAssertGreaterThan(on.attachmentMaxLongEdge ?? 0, 0)
        XCTAssertGreaterThan(on.attachmentJPEGQuality ?? 0, 0)
        XCTAssertGreaterThan(on.sendSweepFPS, 0)
        XCTAssertLessThan(on.pollFloorSeconds, 30,
                          "the floor must stay under the poll ceiling, or it would slow a "
                          + "quiet turn down rather than only speeding it up less")
    }
}
