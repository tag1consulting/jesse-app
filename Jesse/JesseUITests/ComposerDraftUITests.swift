import XCTest

/// The composer's unsent draft, through the running app: real typing into the real
/// `UITextView`, real navigation that really destroys the view, and a real relaunch.
///
/// THIS IS THE ONLY LAYER THE ORIGINAL BUG WAS VISIBLE AT. The text lived in a SwiftUI
/// `@State`, and no unit test can observe what the platform does to view state: the iPhone
/// POPS this view when you go back, and a relaunch is a new process. A test of a string, or
/// of a fake coordinator, passes against the broken code. Every test below fails against
/// it — leaving and re-entering, A → B → A, backgrounding and a relaunch all returned an
/// empty composer.
///
/// No send happens anywhere in this file, so nothing here needs (or contacts) a bridge.
final class ComposerDraftUITests: XCTestCase {

    /// Kept in step with `ComposerInput.accessibilityIdentifier`.
    private let composerID = "composer.input"

    /// All-caps alphanumeric marks: iOS autocapitalization and autocorrect leave them
    /// alone, so what comes back can be compared to what was typed. The newline between
    /// them is the multiline half of the requirement.
    private var typedText: String { "MARKONE9\nMARKTWO4" }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Driving the app

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        openChatsTab(app)
        return app
    }

    private func openChatsTab(_ app: XCUIApplication) {
        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "the Chats tab button")
        chats.tap()
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].waitForExistence(timeout: 30),
                      "the Chats navigation bar is up")
    }

    /// Open a brand-new conversation and return its composer.
    private func newConversation(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons["New conversation"].tap()
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 20),
                      "the conversation opened (its paperclip is up)")
        return composer(app)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews[composerID]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the composer field")
        return field
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(text)
    }

    /// The text the composer is currently holding. A `UITextView`'s `value` is its text,
    /// and reading it is also the round trip that proves the field really took the input.
    private func text(of field: XCUIElement) -> String {
        (field.value as? String) ?? ""
    }

    /// Back out of the conversation to the list. This is the destruction path: on the
    /// iPhone it POPS `ThreadDetailView`, which is exactly what used to take the draft.
    private func backToList(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Jesse"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the back button to the Chats list")
        back.tap()
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].waitForExistence(timeout: 20),
                      "back on the Chats list")
    }

    /// The list's rows for conversations that have never been sent to, newest first.
    ///
    /// Deliberately NOT `app.cells`: a SwiftUI `List`'s SECTION HEADERS are cells too, so
    /// `cells.element(boundBy: 0)` is the "Today" header and tapping it opens nothing. Each
    /// row is a button whose label is the title plus its relative time ("New conversation,
    /// 2 minutes ago"), and the trailing comma is what distinguishes a row from the
    /// navigation bar's "New conversation" button.
    ///
    /// Every conversation in these tests is unsent, so they all carry the placeholder
    /// title. That is fine: a turn-less conversation with no draft is reaped on the list's
    /// appearance, so what is left under this query is exactly the drafted ones, newest
    /// first — and the newest is always the one the test just created.
    private func draftRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New conversation,"))
    }

    /// Empty the drafts this test created, from the list, so a simulator these tests run
    /// against repeatedly does not accumulate drafted conversations forever — an emptied
    /// draft no longer holds a turn-less conversation, so the reaper takes it on the next
    /// list appearance. Best-effort and assertion-free: it is housekeeping, not a check.
    private func clearNewestDrafts(_ app: XCUIApplication, _ count: Int) {
        for _ in 0..<count {
            let row = draftRows(app).element(boundBy: 0)
            guard row.exists else { return }
            row.tap()
            guard app.buttons["Add attachment"].waitForExistence(timeout: 20) else { return }
            let field = app.textViews[composerID]
            guard field.waitForExistence(timeout: 20) else { return }
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: max(text(of: field).count + 2, 4)))
            let back = app.navigationBars.buttons["Jesse"]
            guard back.waitForExistence(timeout: 10) else { return }
            back.tap()
            _ = app.navigationBars.buttons["New conversation"].waitForExistence(timeout: 20)
        }
    }

    /// Open the newest unsent conversation.
    private func openNewestDraftedConversation(_ app: XCUIApplication) {
        let rows = draftRows(app)
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 20),
                      "the drafted conversation is still in the list")
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 20),
                      "the conversation reopened")
    }

    // MARK: - Symptom one: switching conversations

    /// Leaving a conversation and coming back keeps the exact unfinished text.
    func testTheDraftSurvivesLeavingAndReenteringTheConversation() {
        let app = launched()
        type(typedText, into: newConversation(app))
        XCTAssertTrue(text(of: composer(app)).contains(typedText),
                      "precondition: the composer took the text")

        backToList(app)
        // The row is still there at all only because the empty-thread reaper spares a
        // conversation holding a draft.
        openNewestDraftedConversation(app)

        let restored = text(of: composer(app))
        XCTAssertTrue(restored.contains(typedText),
                      "the exact multiline text is back, newline included — got \(restored.debugDescription)")

        backToList(app)
        clearNewestDrafts(app, 1)
    }

    /// A → B → A neither erases A's draft nor leaks B's into it.
    ///
    /// Both rows carry the placeholder title (neither has been sent), so the test never
    /// assumes which row is which: it learns each row's draft by opening it, then re-opens
    /// the first and asserts it still holds ITS OWN text and nothing of the other's.
    func testSwitchingFromAToBAndBackKeepsEachConversationsOwnDraft() {
        let app = launched()

        type("AAA111", into: newConversation(app))
        backToList(app)
        type("BBB222", into: newConversation(app))
        backToList(app)

        let rows = draftRows(app)
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 20),
                      "both drafted conversations are in the list")

        rows.element(boundBy: 0).tap()
        let firstDraft = text(of: composer(app))
        backToList(app)

        draftRows(app).element(boundBy: 1).tap()
        let secondDraft = text(of: composer(app))
        backToList(app)

        XCTAssertNotEqual(firstDraft.contains("AAA111"), firstDraft.contains("BBB222"),
                          "a conversation holds exactly one of the two drafts, never both")
        XCTAssertNotEqual(firstDraft.contains("AAA111"), secondDraft.contains("AAA111"),
                          "the two conversations hold different drafts — nothing leaked")

        // Back to the first: still its own text, still not the other's.
        draftRows(app).element(boundBy: 0).tap()
        XCTAssertEqual(text(of: composer(app)), firstDraft,
                       "A → B → A returns A's draft unchanged")

        backToList(app)
        clearNewestDrafts(app, 2)
    }

    // MARK: - Symptom two: leaving the app

    /// A relaunch — a genuinely new process, not a re-render — finds the draft.
    func testTheDraftSurvivesARelaunch() {
        let app = launched()
        type(typedText, into: newConversation(app))
        XCTAssertTrue(text(of: composer(app)).contains(typedText), "precondition: typed")
        backToList(app)

        app.terminate()
        app.launch()
        openChatsTab(app)

        openNewestDraftedConversation(app)
        XCTAssertTrue(text(of: composer(app)).contains(typedText),
                      "the draft outlived the process")

        backToList(app)
        clearNewestDrafts(app, 1)
    }

    /// Termination with NO navigation first: straight from the last keystroke to a dead
    /// process. This is the boundary the coalesced write claims — the model-side write is
    /// synchronous on the keystroke and the trailing save follows the last one closely, so
    /// there is no "leave the screen properly or lose it" rule.
    func testTheDraftSurvivesTerminationImmediatelyAfterAnEdit() {
        let app = launched()
        let field = newConversation(app)
        type(typedText, into: field)
        // The one round trip: reading the field back. No back navigation, no tab switch,
        // nothing that would let a disappearance handler do the work.
        XCTAssertTrue(text(of: field).contains(typedText), "precondition: typed")

        app.terminate()
        app.launch()
        openChatsTab(app)

        openNewestDraftedConversation(app)
        XCTAssertTrue(text(of: composer(app)).contains(typedText),
                      "killed mid-conversation, the draft is still there")

        backToList(app)
        clearNewestDrafts(app, 1)
    }

    /// Backgrounding and returning — the "leaving the app for long enough" report, in its
    /// milder form where the process survives.
    func testTheDraftSurvivesBackgroundingAndReturning() {
        let app = launched()
        let field = newConversation(app)
        type(typedText, into: field)

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(composer(app).waitForExistence(timeout: 20))
        XCTAssertTrue(text(of: composer(app)).contains(typedText),
                      "the draft is still in the composer after a trip to the background")

        backToList(app)
        clearNewestDrafts(app, 1)
    }

    // MARK: - Deliberately emptying

    /// Clearing the composer on purpose persists as cleared. Coming back to find the text
    /// resurrected would be the same class of surprise as losing it.
    ///
    /// Asserted INDIRECTLY, because for a conversation that has never been sent to
    /// "persisted as empty" and "reaped" are the same observable state: an emptied draft no
    /// longer holds a turn-less conversation alive. So the test keeps a second, non-empty
    /// draft as the witness. Two conversations are made — the older keeps its text, the
    /// NEWER is emptied — and after a relaunch the newest surviving drafted conversation
    /// must be the older one, holding its own text. If the emptying had not persisted, the
    /// emptied conversation would still be there, still newest, still holding "BBB222".
    ///
    /// (The direct assertion — `draftText == ""` after a real store reopen — is
    /// `ComposerDraftTests.testDeliberatelyEmptyingTheComposerPersistsTheEmptyState`.)
    func testDeliberatelyEmptyingTheComposerPersistsAsEmpty() {
        let app = launched()

        type("AAA111", into: newConversation(app))       // the witness, kept
        backToList(app)

        let doomed = newConversation(app)                 // newer, and emptied
        type("BBB222", into: doomed)
        XCTAssertTrue(text(of: doomed).contains("BBB222"), "precondition: typed")
        doomed.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        XCTAssertFalse(text(of: doomed).contains("BBB222"), "precondition: emptied")
        backToList(app)

        app.terminate()
        app.launch()
        openChatsTab(app)

        openNewestDraftedConversation(app)
        let newest = text(of: composer(app))
        XCTAssertFalse(newest.contains("BBB222"),
                       "the emptied composer stayed empty — its text did not come back")
        XCTAssertTrue(newest.contains("AAA111"),
                      "and the newest surviving draft is the one that was never emptied")

        backToList(app)
        clearNewestDrafts(app, 1)
    }
}
