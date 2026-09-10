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
///
/// The Ask entry is asserted here for the same reason the three toolbar tests exist: a
/// toolbar item's PLACEMENT is invisible to a unit test, and this repo has already shipped a
/// completely non-functional one — a `.secondaryAction` collapses into an overflow ellipsis,
/// and an overflow item declared inside a conditional gets an empty menu UIKit will not
/// present. Tapping it is safe and needs no bridge: an ask STAGES a conversation and never
/// fires a turn.
final class OpsNavigationUITests: XCTestCase {

    /// The page-level Ask entry's accessibility label, kept in step with
    /// `JesseAsk.AskPageToolbarModifier`.
    private let askButton = "Ask about this page"
    /// Kept in step with `ComposerInput.accessibilityIdentifier`.
    private let composerID = "composer.input"

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

        // The Schedule screen already had a `.primaryAction` (Reload config), so this is
        // also the assertion that a SECOND one lands beside it rather than collapsing.
        XCTAssertTrue(app.navigationBars.buttons[askButton].waitForExistence(timeout: 10),
                      "Schedule's Ask entry is a real navigation-bar button")
        XCTAssertTrue(app.navigationBars.buttons["Reload config"].exists,
                      "and it did not push Reload config into an overflow")
    }

    /// THE ASK ENTRY, on the screen it matters most: a visible, hittable navigation-bar
    /// button, and a tap that really opens a conversation.
    ///
    /// It taps. That is safe and deliberate: an ask stages a thread with an attachment and
    /// an empty composer, and fires nothing — so this contacts no bridge, and the staged
    /// thread is never inserted into the store because it is never sent.
    func testOpsCarriesAnAskEntryThatOpensAConversation() {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)

        let opsRow = app.buttons["Bridge ops"]
        XCTAssertTrue(opsRow.waitForExistence(timeout: 10), "the Bridge ops row")
        opsRow.tap()
        XCTAssertTrue(app.navigationBars["Bridge ops"].waitForExistence(timeout: 10),
                      "Bridge ops pushed onto the Settings stack")

        // In the NAVIGATION BAR, not merely somewhere in the app: an overflow item answers
        // the second query and not this one.
        let ask = app.navigationBars.buttons[askButton]
        XCTAssertTrue(ask.waitForExistence(timeout: 10),
                      "the Ask entry is a real navigation-bar button")
        XCTAssertTrue(ask.isHittable, "and it is hittable rather than collapsed")
        ask.tap()

        // A conversation, with a composer to type into — which is the whole promise: the
        // chat opens already carrying the reading, and waits for a question.
        XCTAssertTrue(app.textViews[composerID].waitForExistence(timeout: 20),
                      "the ask opened a conversation with an empty composer")
    }

    /// Away mode's Ask entry. Its screen has no other toolbar item, so this is the plain
    /// case — and the one that would break if the placement were platform-wrong.
    func testAwayModeCarriesAnAskEntry() {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)

        let awayRow = app.buttons["Away mode"]
        XCTAssertTrue(awayRow.waitForExistence(timeout: 10), "the Away mode row")
        awayRow.tap()
        XCTAssertTrue(app.navigationBars["Away mode"].waitForExistence(timeout: 10),
                      "Away mode pushed onto the Settings stack")
        XCTAssertTrue(app.navigationBars.buttons[askButton].waitForExistence(timeout: 10),
                      "Away mode's Ask entry is a real navigation-bar button")
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
