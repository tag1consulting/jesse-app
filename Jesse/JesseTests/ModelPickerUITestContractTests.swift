import XCTest
@testable import Jesse
import JesseNetworking

/// The two things `ModelPickerMenuUITests` (a UI-test target, which links no app code and
/// so has to hardcode both) depends on. Neither is exercised by the UI test failing loudly:
/// if either drifts, the UI test keeps passing while silently testing something else.
@MainActor
final class ModelPickerUITestContractTests: XCTestCase {

    /// The UI test sets the per-device default model with a launch argument,
    /// `-jesse.lastUsedModelID glm`, which lands in `NSArgumentDomain` and is read by
    /// `LastUsedModelStore`. Rename the key and the argument goes to a domain nothing
    /// reads: the menu would resolve to the ambient default instead of `glm`, and the
    /// harness-detail and three-value-effort assertions would stop covering what they name.
    func testTheDeviceDefaultKeyIsTheOneTheUITestPassesAsALaunchArgument() {
        XCTAssertEqual(LastUsedModelStore.defaultsKey, "jesse.lastUsedModelID")
    }

    /// The UI test points the app at its stub with `JESSE_UITEST_BRIDGE=host,port,token`,
    /// because an unsigned build cannot write the Keychain and so cannot be paired through
    /// Settings. This pins the parse: the wrong shape returns nil, and nil means the app
    /// falls back to the Keychain and the picker never loads.
    func testTheUITestBridgeOverrideParsesHostPortToken() {
        setenv("JESSE_UITEST_BRIDGE", "127.0.0.1,54321,stub-token", 1)
        defer { unsetenv("JESSE_UITEST_BRIDGE") }

        let cfg = ConfigStore.load()
        XCTAssertEqual(cfg.host, "127.0.0.1")
        XCTAssertEqual(cfg.port, 54321)
        XCTAssertEqual(cfg.token, "stub-token")
        XCTAssertTrue(cfg.isConfigured, "an overridden config must read as paired")
    }

    /// A token containing commas survives: `maxSplits: 2` means only the first two commas
    /// separate fields. Worth pinning because a bearer token is opaque.
    func testTheOverrideKeepsCommasInTheToken() {
        setenv("JESSE_UITEST_BRIDGE", "host,8765,a,b,c", 1)
        defer { unsetenv("JESSE_UITEST_BRIDGE") }
        XCTAssertEqual(ConfigStore.load().token, "a,b,c")
    }

    /// A malformed value is ignored rather than half-applied, so a typo in a test cannot
    /// silently point the app at port 0 or an empty host.
    func testAMalformedOverrideIsIgnored() {
        setenv("JESSE_UITEST_BRIDGE", "not-a-triple", 1)
        defer { unsetenv("JESSE_UITEST_BRIDGE") }
        // Falls through to the Keychain-backed store, whose value this test does not
        // control — the point is only that the malformed spec was not adopted.
        XCTAssertNotEqual(ConfigStore.load().host, "not-a-triple")
    }
}
