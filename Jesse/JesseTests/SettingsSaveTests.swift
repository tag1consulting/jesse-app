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
}
