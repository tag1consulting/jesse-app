import XCTest
@testable import Jesse

@MainActor
final class JesseConfigTests: XCTestCase {

    private func config(host: String, port: Int = 8765, token: String = "t") -> JesseConfig {
        JesseConfig(host: host, port: port, token: token)
    }

    // MARK: - sanitizedHost / normalizedHost

    func testFullURLPastedAsHost() {
        let c = config(host: "http://host:8765/health")
        XCTAssertEqual(c.normalizedHost, "host")
        XCTAssertEqual(c.effectivePort, 8765)
    }

    func testProtocolRelativePrefix() {
        XCTAssertEqual(config(host: "//host").normalizedHost, "host")
    }

    func testCredentialsAreDropped() {
        XCTAssertEqual(config(host: "user@host").normalizedHost, "host")
    }

    func testMixedCaseLowercased() {
        XCTAssertEqual(config(host: "HOST").normalizedHost, "host")
    }

    func testTrailingFQDNDotStripped() {
        XCTAssertEqual(config(host: "host.").normalizedHost, "host")
    }

    func testSurroundingWhitespaceTrimmed() {
        XCTAssertEqual(config(host: "  host  ").normalizedHost, "host")
    }

    // MARK: - effectivePort

    func testEmbeddedPortOverridesStoredPort() {
        // "host:1234" with a different stored port → the embedded one wins.
        let c = config(host: "host:1234", port: 9999)
        XCTAssertEqual(c.effectivePort, 1234)
        XCTAssertEqual(c.normalizedHost, "host")
    }

    func testNoEmbeddedPortFallsBackToStored() {
        XCTAssertEqual(config(host: "host", port: 8765).effectivePort, 8765)
    }

    // MARK: - endpoint

    func testEndpointBuildsURL() {
        let url = config(host: "host", port: 8765).endpoint("/jesse")
        XCTAssertEqual(url?.absoluteString, "http://host:8765/jesse")
    }

    func testEndpointWithEmbeddedPort() {
        let url = config(host: "host:1234", port: 8765).endpoint("/jesse")
        XCTAssertEqual(url?.absoluteString, "http://host:1234/jesse")
    }

    func testEndpointEmptyHostIsNil() {
        XCTAssertNil(config(host: "").endpoint("/jesse"))
    }

    // MARK: - fromPairing

    func testFromPairingValid() {
        let c = JesseConfig.fromPairing("jesse://pair?host=100.64.0.1&port=8765&token=abc123")
        XCTAssertEqual(c?.host, "100.64.0.1")
        XCTAssertEqual(c?.port, 8765)
        XCTAssertEqual(c?.token, "abc123")
    }

    func testFromPairingMissingPortDefaults8765() {
        let c = JesseConfig.fromPairing("jesse://pair?host=host&token=abc123")
        XCTAssertEqual(c?.port, 8765)
        XCTAssertEqual(c?.host, "host")
    }

    func testFromPairingMissingTokenIsNil() {
        XCTAssertNil(JesseConfig.fromPairing("jesse://pair?host=host&port=8765"))
    }

    func testFromPairingMissingHostIsNil() {
        XCTAssertNil(JesseConfig.fromPairing("jesse://pair?port=8765&token=abc123"))
    }

    func testFromPairingWrongSchemeIsNil() {
        XCTAssertNil(JesseConfig.fromPairing("https://pair?host=host&token=abc123"))
    }

    func testFromPairingWrongHostIsNil() {
        XCTAssertNil(JesseConfig.fromPairing("jesse://connect?host=host&token=abc123"))
    }

    func testFromPairingEmptyHostIsNil() {
        XCTAssertNil(JesseConfig.fromPairing("jesse://pair?host=&token=abc123"))
    }
}
