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
