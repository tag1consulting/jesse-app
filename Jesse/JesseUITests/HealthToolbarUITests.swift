import XCTest

/// The Health tab's navigation-bar affordances, driven through the real app.
///
/// This suite exists because PR #30's "Start new day" button shipped completely
/// non-functional on iOS while CI stayed green: the only test was a string
/// classification check, which a button that never renders as a button still
/// passes. Anything about a toolbar item's PLACEMENT is invisible to a unit test:
/// only a running app can tell you whether the item became a real navigation bar
/// button or got swallowed into an overflow menu. Hence XCUITest.
final class HealthToolbarUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Move to the Health tab and wait for the shared dashboard's today-only
    /// toolbar to be up. "Quick log" is the anchor: it is gated on exactly the
    /// same `HistoryUI.showsQuickLog` condition as "Start new day", so once it is
    /// present the gate is provably open and a missing "Start new day" is a real
    /// defect rather than a race against the first snapshot load.
    private func openHealthTabOnToday(_ app: XCUIApplication) {
        let healthTab = app.tabBars.buttons["Health"]
        XCTAssertTrue(healthTab.waitForExistence(timeout: 30), "Health tab button")
        healthTab.tap()

        XCTAssertTrue(
            app.buttons["Quick log"].waitForExistence(timeout: 30),
            "Quick log is up, so the today-only toolbar gate is open"
        )
    }

    /// The regression test for the iOS "Start new day" button: it must be a real,
    /// visible, hittable navigation bar button (NOT an item hidden behind an
    /// overflow ellipsis), and tapping it must present the confirmation.
    func testStartNewDayButtonIsVisibleAndPresentsTheConfirmation() {
        let app = XCUIApplication()
        app.launch()
        openHealthTabOnToday(app)

        // Query the NAVIGATION BAR, not the whole app: that is the part the bug broke.
        // The shipped `.secondaryAction` item produced an "OverflowBarButtonItem"
        // ellipsis here instead, so this query found nothing at all.
        let newDay = app.navigationBars.buttons["Start new day"]
        XCTAssertTrue(
            newDay.waitForExistence(timeout: 10),
            "a 'Start new day' button is in the navigation bar, not buried in an overflow menu"
        )
        XCTAssertTrue(newDay.isHittable, "'Start new day' is directly tappable")
        // Pins the affordance as the sun symbol rather than a text button.
        XCTAssertEqual(newDay.identifier, "sun.horizon", "'Start new day' shows the sun.horizon symbol")

        newDay.tap()

        // Assert on the confirmation's MESSAGE: its confirm button is also labelled
        // "Start new day", so the message is what distinguishes "the dialog presented"
        // from "the toolbar button is still sitting there".
        XCTAssertTrue(
            app.staticTexts["Audit yesterday, log your weigh-in, and refresh the dashboard?"]
                .waitForExistence(timeout: 10),
            "the Start new day confirmation presented"
        )
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.exists, "the confirmation is a presented dialog")
        XCTAssertTrue(dialog.buttons["Start new day"].exists, "the confirmation offers the confirm action")

        // Dismiss WITHOUT confirming: confirming would fire the real morning routine
        // turn. iOS 26 anchors this dialog as a popover with no explicit Cancel row
        // (tap-outside dismisses), so handle both shapes rather than assuming one.
        if dialog.buttons["Cancel"].exists {
            dialog.buttons["Cancel"].tap()
        } else {
            // A point below the anchored popover, over the inert dashboard background.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        }
        XCTAssertTrue(
            app.staticTexts["Audit yesterday, log your weigh-in, and refresh the dashboard?"]
                .waitForNonExistence(timeout: 10),
            "the confirmation dismissed without firing the routine"
        )
    }

    /// Guards the other half of the toolbar, which was working and must stay
    /// working: "+" still opens Quick log with its four options.
    func testQuickLogStillOpensItsSheet() {
        let app = XCUIApplication()
        app.launch()
        openHealthTabOnToday(app)

        app.buttons["Quick log"].tap()

        XCTAssertTrue(app.buttons["Meal"].waitForExistence(timeout: 10), "Quick log sheet is up")
        for option in ["Meal", "Snack", "Weigh-in", "Workout"] {
            XCTAssertTrue(app.buttons[option].exists, "Quick log offers \(option)")
        }
    }

    /// The toolbar is ordered by taps per day, most-used farthest right (README, "UI
    /// conventions"). Quick log runs several times a day and is cheap and repeatable, so
    /// it holds the rightmost slot; "Start new day" fires once, runs for minutes and
    /// rewrites the day file, so it sits inward, away from where a mis-tap lands. Only a
    /// running app can say which is where: order is a rendering fact, and swapping the
    /// two declarations compiles and passes every unit test either way.
    func testQuickLogSitsRightOfStartNewDay() {
        let app = XCUIApplication()
        app.launch()
        openHealthTabOnToday(app)

        let quickLog = app.navigationBars.buttons["Quick log"]
        let newDay = app.navigationBars.buttons["Start new day"]
        XCTAssertTrue(quickLog.waitForExistence(timeout: 10), "Quick log is in the navigation bar")
        XCTAssertTrue(newDay.waitForExistence(timeout: 10), "Start new day is in the navigation bar")

        XCTAssertGreaterThan(quickLog.frame.minX, newDay.frame.minX,
                             "Quick log is the rightmost item; Start new day sits inward of it")
    }
}
