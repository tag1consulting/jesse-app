import XCTest
@testable import Jesse

// Version surfacing: a `GET /health` version reported by the bridge is stored as
// the last-seen bridge version, via the `JesseClientProtocol` mock seam. Also
// covers the app's own bundle-read version and that a failed/blank probe never
// clobbers a known-good stored version.

/// Minimal `JesseClientProtocol` fake that returns a scripted `health()`. Every
/// other protocol method is an inert stub (this seam never drives a turn); the
/// push/title methods fall back to the protocol's default no-ops.
private final class HealthFakeClient: JesseClientProtocol, @unchecked Sendable {
    let scripted: BridgeHealth?   // nil → throw (simulate a transport failure)

    init(health: BridgeHealth?) { self.scripted = health }

    struct ProbeFailed: Error {}
    func health() async throws -> BridgeHealth {
        guard let scripted else { throw ProbeFailed() }
        return scripted
    }

    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment]) async throws -> JesseSendResult {
        .running(jobId: "unused")
    }
    func result(jobId: String) async throws -> JesseResultState { .running }
    func cancelJob(jobId: String) async throws {}
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class BridgeVersionTests: XCTestCase {
    private var scratch: UserDefaults!

    override func setUp() {
        super.setUp()
        // Point the store at a throwaway suite so tests never touch real defaults.
        scratch = UserDefaults(suiteName: "BridgeVersionTests")!
        scratch.removePersistentDomain(forName: "BridgeVersionTests")
        BridgeVersionStore.defaults = scratch
    }

    override func tearDown() {
        scratch.removePersistentDomain(forName: "BridgeVersionTests")
        BridgeVersionStore.defaults = .standard
        super.tearDown()
    }

    func testHealthVersionSurfacesAsStoredBridgeVersion() async {
        XCTAssertNil(BridgeVersionStore.current, "no version stored before any probe")
        let client = HealthFakeClient(health: BridgeHealth(version: "9.9.9"))
        let returned = await BridgeVersionStore.refresh(using: client)
        XCTAssertEqual(returned, "9.9.9")
        XCTAssertEqual(BridgeVersionStore.current, "9.9.9",
                       "the reported /health version is stored as the last-seen bridge version")
    }

    func testFailedProbeKeepsPreviousVersion() async {
        BridgeVersionStore.set("1.2.3")
        let client = HealthFakeClient(health: nil)   // throws
        let returned = await BridgeVersionStore.refresh(using: client)
        XCTAssertEqual(returned, "1.2.3", "a failed probe returns the known-good version")
        XCTAssertEqual(BridgeVersionStore.current, "1.2.3", "and never clobbers it")
    }

    func testMissingVersionKeepsPreviousVersion() async {
        BridgeVersionStore.set("1.2.3")
        // A healthy but too-old bridge reports no version.
        let client = HealthFakeClient(health: BridgeHealth(version: nil))
        _ = await BridgeVersionStore.refresh(using: client)
        XCTAssertEqual(BridgeVersionStore.current, "1.2.3")
    }

    func testAppVersionReadsFromBundle() {
        // The app version is read from the bundle, never hardcoded. The test bundle
        // may not carry the app's Info.plist keys, so assert the shape rather than a
        // literal: display is always "short (build)".
        XCTAssertEqual(AppVersion.display, "\(AppVersion.short) (\(AppVersion.build))")
    }

    func testDecodeHealthParsesVersion() throws {
        let json = #"{"ok":true,"version":"9.9.9"}"#.data(using: .utf8)!
        let resp = HTTPURLResponse(url: URL(string: "http://h/health")!, statusCode: 200,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        let health = try JesseClient.decodeHealth(data: json, resp: resp)
        XCTAssertEqual(health.version, "9.9.9")
    }
}

// Pure version-handshake logic (no I/O): SemVer ordering and the
// `BridgeCompatibility.isOutdated` decision that drives the Settings advisory.
final class BridgeCompatibilityTests: XCTestCase {

    // MARK: SemVer parsing / ordering

    func testSemVerOrdersByMajorMinorPatch() {
        XCTAssertLessThan(SemVer("0.6.9")!, SemVer("0.7.0")!)
        XCTAssertLessThan(SemVer("0.7.0")!, SemVer("0.7.1")!)
        XCTAssertLessThan(SemVer("0.9.9")!, SemVer("1.0.0")!)
        XCTAssertFalse(SemVer("0.7.0")! < SemVer("0.7.0")!, "equal versions are not <")
    }

    func testSemVerTreatsMissingComponentsAsZero() {
        XCTAssertEqual(SemVer("1"), SemVer("1.0.0"))
        XCTAssertEqual(SemVer("1.2"), SemVer("1.2.0"))
    }

    func testSemVerIgnoresPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemVer("0.7.0-rc.1"), SemVer("0.7.0"))
        XCTAssertEqual(SemVer("0.7.0+build.5"), SemVer("0.7.0"))
    }

    func testSemVerRejectsNonNumericOrOverlongVersions() {
        XCTAssertNil(SemVer("abc"))
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer("1.x.0"))
    }

    // MARK: isOutdated

    func testOutdatedWhenBridgeStrictlyBelowMinimum() {
        XCTAssertTrue(BridgeCompatibility.isOutdated(bridgeVersion: "0.6.0", minimum: "0.7.0"))
        XCTAssertTrue(BridgeCompatibility.isOutdated(bridgeVersion: "0.6.9", minimum: "0.7.0"))
    }

    func testNotOutdatedWhenBridgeAtOrAboveMinimum() {
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "0.7.0", minimum: "0.7.0"))
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "0.7.1", minimum: "0.7.0"))
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "1.0.0", minimum: "0.7.0"))
    }

    func testUnknownOrUnparseableVersionNeverWarns() {
        // No version yet, or a bridge too old to report one, or garbage: we can't
        // prove it's outdated, so we must not cry wolf.
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: nil, minimum: "0.7.0"))
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "", minimum: "0.7.0"))
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "not-a-version", minimum: "0.7.0"))
    }

    func testDefaultMinimumIsAParseableTripleTheCurrentBridgeSatisfies() {
        // The shipped floor must itself be a clean triple, and the current bridge
        // (0.7.0) must not trip its own app's warning.
        XCTAssertNotNil(SemVer(BridgeCompatibility.minimumBridgeVersion))
        XCTAssertFalse(BridgeCompatibility.isOutdated(bridgeVersion: "0.7.0"))
    }
}
