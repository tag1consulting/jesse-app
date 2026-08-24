import XCTest

/// Reaching the operations screens from Settings, driven through the real app.
///
/// The sibling of the three toolbar tests, and here for their reason rather than a new one:
/// a `NavigationLink` inside a sheet's `Form` either pushes or it does not, and a unit test
/// on the view model cannot tell you which. This one exists because the whole feature hangs
/// off two rows in a settings sheet — if those rows do not push, everything behind them is
/// unreachable and every unit test still passes.
///
/// NOTHING HERE PAIRS A SENTINEL AND NOTHING PRESSES A VERB. The screens are asserted in
/// their UNPAIRED state on purpose: that is the state a fresh simulator is in, it is the one
/// state that needs no network, and confirming any of the buttons behind these screens would
/// restart a real bridge.
final class OpsNavigationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Open the Settings sheet from the Chats tab's gear.
    private func openSettings(_ app: XCUIApplication) {
        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "Chats tab button")
        chats.tap()

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "the Settings gear is in the navigation bar")
        gear.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "the Settings sheet is up")
    }

    /// Settings → Bridge ops → Schedule. Both pushes, in one pass, because the second is
    /// only reachable through the first and asserting them separately would launch the app
    /// twice to walk the same path.
    func testSettingsPushesOpsAndOpsPushesSchedule() {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)

        let opsRow = app.buttons["Bridge ops"]
        XCTAssertTrue(opsRow.waitForExistence(timeout: 10),
                      "the Bridge ops row is in the Settings form")
        opsRow.tap()

        XCTAssertTrue(app.navigationBars["Bridge ops"].waitForExistence(timeout: 10),
                      "Bridge ops pushed onto the Settings stack")
        // Unpaired: the sentinel cards are replaced by one call to action, and it says what
        // the sentinel IS rather than just that it is missing.
        XCTAssertTrue(app.staticTexts["Pair the sentinel"].waitForExistence(timeout: 10),
                      "an unpaired sentinel shows its call to action")

        // The schedule is a BRIDGE feature and stays reachable with no sentinel paired —
        // its two verbs fall back to the bridge, so hiding the row would make that fallback
        // unreachable from the app that implements it.
        let scheduleRow = app.buttons["Schedule"]
        XCTAssertTrue(scheduleRow.waitForExistence(timeout: 10),
                      "the Schedule row is on the Ops screen even with no sentinel")
        scheduleRow.tap()

        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 10),
                      "Schedule pushed onto the same stack")
    }

    /// Away mode is the second row, and it is a BRIDGE screen: it needs no sentinel at all,
    /// so it must render its own form rather than a call to action.
    func testSettingsPushesAwayMode() {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)

        let awayRow = app.buttons["Away mode"]
        XCTAssertTrue(awayRow.waitForExistence(timeout: 10),
                      "the Away mode row is in the Settings form")
        awayRow.tap()

        XCTAssertTrue(app.navigationBars["Away mode"].waitForExistence(timeout: 10),
                      "Away mode pushed onto the Settings stack")
        XCTAssertTrue(app.switches["Away"].waitForExistence(timeout: 10),
                      "the Away toggle is the screen's one control")
    }
}
