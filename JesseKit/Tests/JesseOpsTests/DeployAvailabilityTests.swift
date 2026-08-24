import XCTest
@testable import JesseOps

// Whether the Deploy button may be pressed.
//
// The whole matrix, because this is the most consequential button in the app: it builds a
// commit on the Studio, swaps three binaries and restarts the bridge. The rule is BOTH
// conditions or nothing — a different sha AND a green CI — and the three non-green CI states
// are checked separately because "pending" is the one a permissive implementation lets
// through, and it is exactly the state in which pressing Deploy looks safe and is not.

final class DeployAvailabilityTests: XCTestCase {

    private func document(runningSha: String?, originSha: String?, ci: String,
                          deployPhase: String? = nil) throws -> DeployStatusDocument {
        let deploy = deployPhase.map {
            #"{"deploy_id":"d1","phase":"\#($0)","ref":"main","sha":"\#(originSha ?? "")","started_ms":1,"finished_ms":null,"result":null,"reason":null,"log_tail":[]}"#
        } ?? "null"
        let json = """
        {"deploy": \(deploy),
         "running": {"version": "0.93.0", "sha": \(runningSha.map { "\"\($0)\"" } ?? "null")},
         "origin_main": {"sha": \(originSha.map { "\"\($0)\"" } ?? "null"),
                         "version": "0.94.0", "ci": "\(ci)", "ci_detail": null,
                         "checked_ms": 1}}
        """
        return try DeployStatusDocument.decode(Data(json.utf8))
    }

    func testReadyWhenTheShaDiffersAndCiIsGreen() throws {
        let d = try document(runningSha: "aaa", originSha: "bbb", ci: "green")
        XCTAssertEqual(DeployAvailability.decide(d), .ready(sha: "bbb"))
    }

    func testBlockedWhenOriginMainIsAlreadyRunning() throws {
        let d = try document(runningSha: "bbb", originSha: "bbb", ci: "green")
        XCTAssertFalse(DeployAvailability.decide(d).isReady)
        XCTAssertEqual(DeployAvailability.decide(d).reason,
                       "origin/main is already what is running")
    }

    func testBlockedOnRedCi() throws {
        let d = try document(runningSha: "aaa", originSha: "bbb", ci: "red")
        XCTAssertEqual(DeployAvailability.decide(d).reason, "CI is red on that commit")
    }

    /// PENDING IS NOT GREEN. A card that treated "CI has not answered yet" as permission would
    /// deploy a commit nothing has vouched for.
    func testBlockedOnPendingCi() throws {
        let d = try document(runningSha: "aaa", originSha: "bbb", ci: "pending")
        XCTAssertEqual(DeployAvailability.decide(d).reason,
                       "CI has not finished on that commit yet")
    }

    func testBlockedWhenNoCiRunExists() throws {
        let d = try document(runningSha: "aaa", originSha: "bbb", ci: "none")
        XCTAssertEqual(DeployAvailability.decide(d).reason,
                       "no CI run vouches for that commit")
    }

    func testBlockedWhenOriginMainHasNotBeenRead() throws {
        let d = try document(runningSha: "aaa", originSha: nil, ci: "none")
        XCTAssertEqual(DeployAvailability.decide(d).reason,
                       "the sentinel has not read origin/main yet")
    }

    /// An UNKNOWN running sha does not block. A sentinel that has never deployed has no
    /// `running.sha`, and refusing the first deploy for want of a record of a deploy would be a
    /// deadlock. It is the SAME-sha case that blocks, never the unknown one.
    func testAnUnknownRunningShaStillAllowsAGreenDeploy() throws {
        let d = try document(runningSha: nil, originSha: "bbb", ci: "green")
        XCTAssertEqual(DeployAvailability.decide(d), .ready(sha: "bbb"))
    }

    /// A deploy already in flight blocks whatever else is true — including a green card, which
    /// is precisely when someone would press it twice.
    func testADeployInFlightBlocksEverything() throws {
        let d = try document(runningSha: "aaa", originSha: "bbb", ci: "green",
                             deployPhase: "build")
        XCTAssertEqual(DeployAvailability.decide(d).reason, "a deploy is already running (build)")
    }
}
