import XCTest
@testable import Jesse

/// (Lows) Named-constant extraction and the `JesseInbox` main-actor drain path.
@MainActor
final class LowsTests: XCTestCase {

    // MARK: - Named constants (no more scattered magic numbers)

    func testNamedConstantsHaveExpectedValues() {
        XCTAssertEqual(JesseConfig.defaultPort, 8765)
        XCTAssertEqual(JesseThread.titleCharacterLimit, 60)
    }

    /// `defaultPort` is the value used when a pairing payload omits the port.
    func testPairingWithoutPortUsesDefaultPort() {
        let cfg = JesseConfig.fromPairing("jesse://pair?host=laptop&token=tok")
        XCTAssertEqual(cfg?.port, JesseConfig.defaultPort)
    }

    /// `titleCharacterLimit` bounds a derived title's length (plus an ellipsis).
    func testDeriveTitleRespectsCharacterLimit() {
        let long = String(repeating: "a", count: JesseThread.titleCharacterLimit + 20)
        let title = JesseThread.deriveTitle(from: long)
        XCTAssertEqual(title.count, JesseThread.titleCharacterLimit + 1, "limit chars + the ellipsis")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: - JesseInbox drain (now @MainActor)

    @MainActor
    func testInboxDrainSetsPendingFromUserDefaults() {
        UserDefaults.standard.set(JesseMode.tell.rawValue, forKey: "jesse.pending.mode")
        UserDefaults.standard.set("note this for me", forKey: "jesse.pending.text")
        defer {
            UserDefaults.standard.removeObject(forKey: "jesse.pending.mode")
            UserDefaults.standard.removeObject(forKey: "jesse.pending.text")
        }

        let inbox = JesseInbox.shared
        inbox.pending = nil
        inbox.drain()
        defer { inbox.pending = nil }

        XCTAssertEqual(inbox.pending?.text, "note this for me")
        XCTAssertEqual(inbox.pending?.mode, .tell)
    }
}
