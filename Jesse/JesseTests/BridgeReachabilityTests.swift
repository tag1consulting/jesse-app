import XCTest
@testable import Jesse

/// The pure "show the offline banner?" gate. The banner mirrors the watch's
/// `.queued` state — it warns that the bridge is unreachable *before* the user
/// composes — so it must appear only when the app is actually paired AND a health
/// probe has come back unreachable, never on an unpaired install or before the
/// first probe resolves.
@MainActor
final class BridgeReachabilityTests: XCTestCase {

    func testUnreachableWhilePairedShowsBanner() {
        XCTAssertTrue(shouldShowOfflineBanner(isConfigured: true, reachability: .unreachable))
    }

    func testReachableHidesBanner() {
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: .reachable))
    }

    func testUnknownHidesBanner() {
        // Before the first probe resolves — don't flash a banner on cold launch.
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: .unknown))
    }

    func testUnpairedNeverShowsBanner() {
        // An unpaired install shows the pairing CTA, not an "offline" warning —
        // even if a stale probe somehow read unreachable.
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: false, reachability: .unreachable))
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: false, reachability: .unknown))
    }
}
