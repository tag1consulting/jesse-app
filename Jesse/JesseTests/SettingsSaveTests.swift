import XCTest
import Security
@testable import Jesse

/// The Settings "Save" action used to call `ConfigStore.save` as a bare statement,
/// discard the returned `Bool`, and dismiss unconditionally — so a first-install
/// Keychain failure looked like a successful pairing while the token never
/// persisted (every later request then 401s). `settingsSaveOutcome` makes that
/// decision testable: a failed Keychain write must surface an error and NOT
/// half-commit the prompt editors; a successful write dismisses and persists.
///
/// Driven through the same injectable `addItem` seam `ConfigStoreKeychainTests`
/// uses, so no real Keychain is touched.
@MainActor
final class SettingsSaveTests: XCTestCase {

    override func tearDown() {
        ConfigStore.addItem = SecItemAdd   // restore the real Keychain add
        super.tearDown()
    }

    /// Failure path: a denied Keychain write (missing entitlement, as on a fresh
    /// install) must keep the sheet open (`.showError`) and must NOT run the
    /// prompt-editor saves — otherwise the failure hides behind a dismissed sheet.
    func testKeychainFailureShowsErrorAndDoesNotPersistPrompts() {
        ConfigStore.addItem = { _, _ in errSecMissingEntitlement }
        var promptsPersisted = false
        let outcome = settingsSaveOutcome(
            config: JesseConfig(host: "laptop", port: 8765, token: "tok")
        ) { promptsPersisted = true }

        XCTAssertEqual(outcome, .showError,
                       "a failed token save must keep the sheet up, not dismiss")
        XCTAssertFalse(promptsPersisted,
                       "a failed token save must not half-commit the prompt editors")
    }

    /// Success path: a successful Keychain write dismisses, runs the prompt-editor
    /// saves, and actually persists the token (verified via the value handed to the
    /// recording seam).
    func testKeychainSuccessDismissesPersistsPromptsAndToken() {
        var persistedToken: String?
        ConfigStore.addItem = { dict, _ in
            let ns = dict as NSDictionary
            if let account = ns[kSecAttrAccount as String] as? String, account == "token",
               let data = ns[kSecValueData as String] as? Data {
                persistedToken = String(data: data, encoding: .utf8)
            }
            return errSecSuccess
        }
        var promptsPersisted = false
        let outcome = settingsSaveOutcome(
            config: JesseConfig(host: "laptop", port: 8765, token: "tok")
        ) { promptsPersisted = true }

        XCTAssertEqual(outcome, .dismiss, "a successful save dismisses the sheet")
        XCTAssertTrue(promptsPersisted, "the prompt editors persist on the success path")
        XCTAssertEqual(persistedToken, "tok", "the token must actually be written")
    }

    /// The sentinel is written BESIDE the bridge, in the same Keychain service under one
    /// extra account holding a small JSON object — one item, because the three fields are
    /// only ever meaningful together and the Keychain gives no transaction across three.
    func testSaveWritesTheSentinelBesideTheBridge() {
        var written: [String: String] = [:]
        ConfigStore.addItem = { dict, _ in
            let ns = dict as NSDictionary
            if let account = ns[kSecAttrAccount as String] as? String,
               let data = ns[kSecValueData as String] as? Data {
                written[account] = String(data: data, encoding: .utf8)
            }
            return errSecSuccess
        }
        let outcome = settingsSaveOutcome(
            config: JesseConfig(host: "laptop", port: 8765, token: "tok"),
            sentinel: SentinelConfig(host: "laptop", port: 8766, token: "s3nt")
        ) {}

        XCTAssertEqual(outcome, .dismiss)
        XCTAssertEqual(written["token"], "tok")
        let blob = written["sentinel"] ?? ""
        XCTAssertTrue(blob.contains("\"host\":\"laptop\""), blob)
        XCTAssertTrue(blob.contains("\"port\":8766"), blob)
        XCTAssertTrue(blob.contains("\"token\":\"s3nt\""), blob)
    }

    /// A sentinel write that fails is `.showError` too, and the prompt editors do not
    /// half-commit: an ops screen pointed at a half-saved sentinel 401s on every press with
    /// nothing on screen to explain why.
    func testAFailedSentinelWriteAlsoShowsAnError() {
        // The bridge's three fields succeed; the sentinel's one item is refused.
        ConfigStore.addItem = { dict, _ in
            let ns = dict as NSDictionary
            let account = ns[kSecAttrAccount as String] as? String
            return account == "sentinel" ? errSecMissingEntitlement : errSecSuccess
        }
        var promptsPersisted = false
        let outcome = settingsSaveOutcome(
            config: JesseConfig(host: "laptop", port: 8765, token: "tok"),
            sentinel: SentinelConfig(host: "laptop", port: 8766, token: "s3nt")
        ) { promptsPersisted = true }

        XCTAssertEqual(outcome, .showError)
        XCTAssertFalse(promptsPersisted)
    }

    /// THE ADDITIVE RULE, where the app actually implements it: a scan REPLACES the three
    /// bridge fields and leaves the three sentinel ones alone unless the payload carried
    /// them. Without this, re-scanning an ordinary bridge QR would blank a paired sentinel on
    /// screen and the next Save would make that permanent.
    func testABridgeOnlyScanLeavesTheSentinelFieldsAlone() throws {
        let existing = PairingFields(host: "old", port: "8765", token: "oldtok",
                                     sentinelHost: "laptop", sentinelPort: "8766",
                                     sentinelToken: "s3nt")
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=laptop&port=8765&token=fresh"))

        let after = fieldsAfterScan(payload, existing: existing)

        XCTAssertEqual(after.host, "laptop")
        XCTAssertEqual(after.token, "fresh", "the bridge half IS replaced")
        XCTAssertEqual(after.sentinelHost, "laptop")
        XCTAssertEqual(after.sentinelPort, "8766")
        XCTAssertEqual(after.sentinelToken, "s3nt", "…and the sentinel half is untouched")
    }

    /// …and a payload that DOES carry the three keys fills both halves from the one scan.
    func testAScanWithSentinelKeysFillsBothHalves() throws {
        let payload = try XCTUnwrap(PairingPayload.parse(
            "jesse://pair?host=laptop&port=8765&token=fresh&shost=laptop&sport=8766&stoken=s3nt"))

        let after = fieldsAfterScan(payload, existing: PairingFields())

        XCTAssertEqual(after, PairingFields(host: "laptop", port: "8765", token: "fresh",
                                            sentinelHost: "laptop", sentinelPort: "8766",
                                            sentinelToken: "s3nt"))
    }
}
