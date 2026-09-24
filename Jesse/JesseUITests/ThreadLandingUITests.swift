import XCTest

/// THE BUG, DRIVEN END TO END: a notification tap that arrives while another tab is up.
///
/// `ThreadDetailView` hides the root TabView's bar, and it hides it for the SHELL, not for
/// one tab. So a conversation pushed into the Chats stack while the user is looking at
/// Today used to take the tab bar away under Today — no conversation on screen, no bar to
/// leave with, and no back swipe, because the pushed detail is on a stack nobody can see.
/// A force quit was the only recovery.
///
/// This runs the REAL routing rather than the landing function: the app's own seam seeds
/// one local conversation, starts on the named tab, and posts a `PushRouter.pendingTap`
/// for it, which goes through `ContentView.openThread(for:)` and
/// `RunCoordinator.thread(forTap:liveThreadID:context:)` exactly as a tapped notification
/// does. Nothing here touches `ThreadLanding` — a test that called it directly would pass
/// against the broken app.
///
/// WHAT IS ASSERTED, AND IN WHICH ORDER, is itself a consequence of the design: a
/// conversation is SUPPOSED to hide the tab bar, so "Chats is the selected tab" is not
/// assertable while one is open — there is no bar to ask. The sequence is therefore: the
/// conversation is on screen, then back out of it, then the bar is there with Chats
/// selected. On the broken app the first of those already fails from Today, because the
/// push landed on a tab nobody was looking at.
final class ThreadLandingUITests: XCTestCase {

    /// What the seeded conversation is called, in the list row and in the navigation bar.
    /// Duplicated from `ThreadLandingUITestSeam.threadTitle` because a UI test runs in its
    /// own process and cannot import the app.
    private static let threadTitle = "Landing Probe"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// THE REGRESSION. Start on Today, take the tap, and the conversation must be the
    /// thing on screen — which it can only be if the landing selected Chats first.
    func testATapThatArrivesOnTheTodayTabLandsOnChats() {
        landAndReturn(startingOn: "today")
    }

    /// The cold-launch path, where Chats is already selected: selecting it again is a
    /// no-op and everything downstream must behave identically. This is the case that
    /// worked before the fix, kept so the fix cannot break it.
    func testATapThatArrivesOnTheChatsTabStillLands() {
        landAndReturn(startingOn: nil)
    }

    /// Launch with the seam armed on `tab` (nil = no override, so the app's own default
    /// Chats), then assert the whole sequence: the conversation open, and a back swipe
    /// that lands on the thread list with the tab bar present and Chats selected.
    private func landAndReturn(startingOn tab: String?) {
        let app = XCUIApplication()
        // Named `chats` rather than omitted when there is no override, because the seam's
        // seeding and its tap are armed by the SAME variable: without it there would be no
        // conversation to land on at all.
        app.launchEnvironment["JESSE_UITEST_THREAD_LANDING"] = tab ?? "chats"
        app.launch()

        // 1. THE ASSERTION THE BUG FAILS. The tapped conversation is what is on screen,
        //    identified by its own navigation bar. From Today, on the broken app, the push
        //    went into a stack behind an unselected tab and nothing here ever appeared.
        let conversation = app.navigationBars[Self.threadTitle]
        XCTAssertTrue(conversation.waitForExistence(timeout: 60),
                      "the tapped conversation must be the screen the user is looking at")

        // 2. Back out of it. The swipe is the gesture the bug destroyed; the button is the
        //    fallback for a simulator that swallows the edge pan.
        goBack(in: app)

        // 3. The thread list, with the bar, and the bar on Chats. "The bar is back" is the
        //    whole point: it is what the user had no way to recover before.
        let list = app.navigationBars["Jesse"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the thread list after going back")
        let today = app.tabBars.buttons["Today"]
        XCTAssertTrue(today.waitForExistence(timeout: 30), "the tab bar is back")
        XCTAssertTrue(today.isHittable, "and it can actually be tapped")
        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(waitFor(timeout: 10) { chats.isSelected },
                      "the landing selected Chats, so backing out of the conversation lands there")
    }

    /// Pop the conversation: the interactive back swipe, falling back to the navigation
    /// bar's own back button when the gesture does not take.
    private func goBack(in app: XCUIApplication) {
        let list = app.navigationBars["Jesse"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        if list.waitForExistence(timeout: 10) { return }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap() }
    }

    /// Poll a condition XCUITest has no expectation for (`isSelected` on a tab button is
    /// not an existence question). No `sleep`: this is the same wait-until-or-fail shape
    /// `waitForExistence` uses, over a predicate of our own.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().tabBars.firstMatch.waitForExistence(timeout: 0.25)
        }
        return condition()
    }
}
