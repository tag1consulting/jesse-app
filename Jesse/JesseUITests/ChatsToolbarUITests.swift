import XCTest

/// The Chats tab's navigation-bar affordances, driven through the real app.
///
/// The sibling of `HealthToolbarUITests`, and here for the same reason: anything about
/// a toolbar item's PLACEMENT is invisible to a unit test. PR #30's "Start new day"
/// shipped completely non-functional on iOS while CI stayed green, because a
/// `.secondaryAction` item collapses into a "More" overflow ellipsis and an overflow
/// item declared inside a conditional gets an empty menu UIKit will not present. Only a
/// running app can tell you whether "Good morning" became a real bar button or got
/// swallowed the same way.
///
/// NOTHING HERE EVER CONFIRMS THE DIALOG. Confirming would fire the real start-of-day
/// routine against whatever bridge the simulator is paired with.
final class ChatsToolbarUITests: XCTestCase {

    private let confirmationMessage = "Run the full start of day routine now?"
    private let alreadyFiredMessage =
        "Start of day already ran from this device today. Run it again for a delta?"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Move to the Chats tab and wait for its toolbar. "New conversation" is the
    /// anchor: it is unconditional, so once it is present the navigation bar is up and
    /// a missing "Good morning" is a real defect rather than a race against launch.
    private func openChatsTab(_ app: XCUIApplication) {
        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "Chats tab button")
        chats.tap()

        XCTAssertTrue(
            app.navigationBars.buttons["New conversation"].waitForExistence(timeout: 30),
            "the Chats navigation bar is up"
        )
    }

    /// Either wording is a presented dialog — which one shows depends on whether this
    /// simulator already fired the routine today, and that is not something a UI test
    /// should try to control.
    private func presentedMessage(_ app: XCUIApplication) -> XCUIElement? {
        for text in [confirmationMessage, alreadyFiredMessage] {
            let element = app.staticTexts[text]
            if element.waitForExistence(timeout: 10) { return element }
        }
        return nil
    }

    /// THE REGRESSION TEST for the overflow bug: a real, visible, hittable navigation
    /// bar button, not an item hidden behind an ellipsis.
    func testGoodMorningButtonIsVisibleInTheNavigationBar() {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)

        // Query the NAVIGATION BAR, not the whole app: that is the part the bug broke.
        // A `.secondaryAction` item produces an "OverflowBarButtonItem" here instead,
        // and this query finds nothing at all.
        let goodMorning = app.navigationBars.buttons["Good morning"]
        XCTAssertTrue(
            goodMorning.waitForExistence(timeout: 10),
            "a 'Good morning' button is in the navigation bar, not buried in an overflow menu"
        )
        XCTAssertTrue(goodMorning.isHittable, "'Good morning' is directly tappable")
        // Pins the affordance as the cup glyph — deliberately not a third sun, which
        // would collide with the Health tab's button and the Today tab's own icon.
        XCTAssertEqual(goodMorning.identifier, "cup.and.saucer",
                       "'Good morning' shows the cup.and.saucer symbol")
    }

    /// Tapping presents the confirmation, and the confirmation offers BOTH actions with
    /// start-of-day-alone leading. A dialog that lost the opt-in action, or that
    /// reordered the two so the health variant reads as the default, is what this
    /// catches — the leading action of a `confirmationDialog` is the one that reads as
    /// what the button does.
    func testTappingItPresentsBothConfirmActionsWithStartTheDayLeading() {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)

        app.navigationBars.buttons["Good morning"].tap()

        // Assert on the MESSAGE, not the confirm button: the toolbar button and the
        // dialog's title share the label "Good morning", so only the message
        // distinguishes "presented" from "still sitting in the toolbar".
        XCTAssertNotNil(presentedMessage(app), "the Good morning confirmation presented")

        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.exists, "the confirmation is a presented dialog")

        let start = dialog.buttons["Start the day"]
        let withHealth = dialog.buttons["Include health and diet first"]
        XCTAssertTrue(start.exists, "the confirmation offers start of day alone")
        XCTAssertTrue(withHealth.exists, "and the opt-in that folds the health refresh in")
        XCTAssertLessThan(start.frame.minY, withHealth.frame.minY,
                          "'Start the day' leads: it is the default, the health variant is not")

        dismiss(dialog, in: app)
    }

    /// Dismissing without confirming fires nothing and leaves no conversation behind.
    func testDismissingTheConfirmationFiresNothing() {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)

        let before = app.cells.count
        app.navigationBars.buttons["Good morning"].tap()
        guard let message = presentedMessage(app) else {
            return XCTFail("the Good morning confirmation presented")
        }

        dismiss(app.sheets.firstMatch, in: app)

        XCTAssertTrue(message.waitForNonExistence(timeout: 10),
                      "the confirmation dismissed without firing the routine")
        // Still on the list, not pushed into a conversation, and no row was added.
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].exists,
                      "a cancelled confirmation leaves the list on screen")
        XCTAssertEqual(app.cells.count, before, "and adds no conversation")
    }

    /// The other half of this toolbar, which was working and must stay working: the
    /// compose button still opens an empty conversation.
    func testNewConversationStillOpensAnEmptyConversation() {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)

        app.navigationBars.buttons["New conversation"].tap()

        // The paperclip is the conversation screen's own affordance, and the one stable
        // marker of it: the send button's label is the thread's MODE ("Ask Jesse" on a
        // fresh one, "Follow up" once it has turns), so keying on it would pin something
        // this test is not about. Its presence means a conversation was pushed rather
        // than a dialog presented.
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 10),
                      "the compose button pushed an empty conversation")
    }

    /// The toolbar is ordered by taps per day, most-used farthest right (README, "UI
    /// conventions"). New conversation is the most-tapped action on this screen and is
    /// cheap and reversible, so it holds the rightmost slot; "Good morning" fires once a
    /// day and starts a routine that runs for minutes, so it sits inward, away from
    /// where a mis-tap lands. Order is a rendering fact no unit test can see: both
    /// declaration orders compile and behave identically everywhere else.
    func testNewConversationSitsRightOfGoodMorning() {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)

        let newConversation = app.navigationBars.buttons["New conversation"]
        let goodMorning = app.navigationBars.buttons["Good morning"]
        XCTAssertTrue(goodMorning.waitForExistence(timeout: 10), "Good morning is in the navigation bar")

        XCTAssertGreaterThan(newConversation.frame.minX, goodMorning.frame.minX,
                             "New conversation is the rightmost item; Good morning sits inward of it")
    }

    /// iOS 26 anchors a `confirmationDialog` as a popover with no explicit Cancel row
    /// (tap-outside dismisses), while the sheet form has one. Handle both rather than
    /// assuming either, exactly as `HealthToolbarUITests` does.
    private func dismiss(_ dialog: XCUIElement, in app: XCUIApplication) {
        if dialog.buttons["Cancel"].exists {
            dialog.buttons["Cancel"].tap()
        } else {
            // A point low on the screen, over the inert list background.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
    }
}
