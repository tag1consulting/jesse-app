import XCTest

/// The Today tab's navigation-bar affordances, driven through the real app.
///
/// The sibling of `ChatsToolbarUITests` and `HealthToolbarUITests`, and here for the
/// same reason: a toolbar item's PLACEMENT is invisible to a unit test. A
/// `.secondaryAction` item collapses into a "More" overflow ellipsis, and the badge
/// filter is exactly the sort of control that would be useless there: its whole job
/// is to be one tap away from the number on the tab.
///
/// Nothing here needs a paired bridge. The toolbar is declared outside the screen's
/// content switch, so it renders whether or not a day file ever loads, and the filter
/// button carries a count of zero until one does.
final class TodayToolbarUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Move to the Today tab and wait for its navigation bar. The sort control is the
    /// anchor: it is unconditional, so once it is present the bar is up and a missing
    /// filter button is a real defect rather than a race against launch.
    private func openTodayTab(_ app: XCUIApplication) {
        let today = app.tabBars.buttons["Today"]
        XCTAssertTrue(today.waitForExistence(timeout: 30), "Today tab button")
        today.tap()

        XCTAssertTrue(
            app.navigationBars.buttons["Order every section: File order"]
                .waitForExistence(timeout: 30),
            "the Today navigation bar is up"
        )
    }

    /// A real, visible, hittable navigation bar button carrying the badge's own number.
    /// It is not an item buried in an overflow menu, and not a bare glyph the count has
    /// to be inferred from.
    func testTheBadgeFilterIsAVisibleNavigationBarButton() {
        let app = XCUIApplication()
        app.launch()
        openTodayTab(app)

        let filter = app.navigationBars.buttons["Needs action, 0 items"]
        XCTAssertTrue(
            filter.waitForExistence(timeout: 10),
            "the badge filter is in the navigation bar, not buried in an overflow menu"
        )
        XCTAssertTrue(filter.isHittable, "the badge filter is directly tappable")
        XCTAssertEqual(filter.value as? String, "Filter off",
                       "and it says which state it is in")
    }

    /// Declaration order is left to right, and the filter is declared last: it is the
    /// most-tapped of the Today toolbar's controls, so it takes the rightmost slot. The
    /// sort menu sits to its left. See README, "UI conventions".
    func testTheBadgeFilterSitsRightOfTheSortMenu() {
        let app = XCUIApplication()
        app.launch()
        openTodayTab(app)

        let sort = app.navigationBars.buttons["Order every section: File order"]
        let filter = app.navigationBars.buttons["Needs action, 0 items"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))

        XCTAssertGreaterThan(filter.frame.minX, sort.frame.minX,
                             "the badge filter is to the right of the sort menu")
    }

    /// Tapping toggles the view and says so. Nothing is written by either state: the
    /// filter is a lens over the day, which is asserted in the package's own tests.
    func testTappingItTogglesTheFilterAndAnnouncesTheState() {
        let app = XCUIApplication()
        app.launch()
        openTodayTab(app)

        let filter = app.navigationBars.buttons["Needs action, 0 items"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.tap()

        XCTAssertEqual(filter.value as? String, "Filter on")

        filter.tap()
        XCTAssertEqual(filter.value as? String, "Filter off")
    }
}
