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

    /// **Three at once, across a switch AND a cold launch.** Two conversations prove
    /// nothing leaks; three prove the store is a DICTIONARY and not a most-recent slot,
    /// and the relaunch proves every one of them reached disk rather than only the last
    /// one left.
    func testThreeConversationsHoldTheirOwnDraftsAcrossASwitchAndARelaunch() {
        let app = launched()
        let marks = ["AAA111", "BBB222", "CCC333"]
        for mark in marks {
            type(mark, into: newConversation(app))
            backToList(app)
        }

        // Before the relaunch: each of the three rows holds exactly one mark, and the
        // three marks are all different.
        XCTAssertTrue(draftRows(app).element(boundBy: 2).waitForExistence(timeout: 20),
                      "all three drafted conversations are in the list")
        var beforeRelaunch: [String] = []
        for row in 0..<3 {
            draftRows(app).element(boundBy: row).tap()
            let held = text(of: composer(app))
            beforeRelaunch.append(marks.first { held.contains($0) } ?? "none")
            XCTAssertEqual(marks.filter { held.contains($0) }.count, 1,
                           "row \(row) holds exactly one draft, never two")
            backToList(app)
        }
        XCTAssertEqual(Set(beforeRelaunch).count, 3,
                       "three conversations, three different drafts, held at the same time")

        app.terminate()
        app.launch()
        openChatsTab(app)

        XCTAssertTrue(draftRows(app).element(boundBy: 2).waitForExistence(timeout: 20),
                      "all three survived the cold launch")
        var afterRelaunch: [String] = []
        for row in 0..<3 {
            draftRows(app).element(boundBy: row).tap()
            let held = text(of: composer(app))
            afterRelaunch.append(marks.first { held.contains($0) } ?? "none")
            backToList(app)
        }
        XCTAssertEqual(afterRelaunch, beforeRelaunch,
                       "each conversation came back with its OWN draft, in its own row")

        clearNewestDrafts(app, 3)
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
    /// process. Nothing wrote anything while the text was being typed, so this is the test
    /// that the TERMINATION departure really fires and really captures — there is no
    /// "leave the screen properly or lose it" rule, and no timer standing in for one.
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

        let witness = newConversation(app)                // the witness, kept
        type("AAA111", into: witness)
        XCTAssertTrue(text(of: witness).contains("AAA111"), "precondition: the witness took its text")
        backToList(app)
        // CHECKPOINTS, so a loss names the step it happened at rather than surfacing only
        // after a relaunch. The first is the one App 1.0 (132) failed: the list appeared
        // before the witness's composer left, judged it empty, and reaped it.
        XCTAssertTrue(draftRows(app).element(boundBy: 0).waitForExistence(timeout: 10),
                      "the witness is still in the list once it is left")

        let doomed = newConversation(app)                 // newer, and emptied
        type("BBB222", into: doomed)
        XCTAssertTrue(text(of: doomed).contains("BBB222"), "precondition: typed")
        doomed.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        XCTAssertFalse(text(of: doomed).contains("BBB222"), "precondition: emptied")
        backToList(app)
        XCTAssertTrue(draftRows(app).element(boundBy: 0).waitForExistence(timeout: 10),
                      "the witness survived the emptied conversation being reaped")

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

    // MARK: - The other way a composer is destroyed

    /// The `.id(thread.id)` DETAIL-COLUMN REPLACEMENT, which is the iPad's shape and the
    /// Mac's. Switching there does not pop anything: SwiftUI throws the old view away and
    /// builds a new one, and the outgoing composer's only chance to hand its text over is
    /// the `onDisappear` that identity change fires.
    ///
    /// That path is newly load-bearing. Until this change the dictionary was already up to
    /// date on every keystroke and a timer would have written it anyway; now the departure
    /// IS the mechanism, so it needs a test of its own rather than an assumption about
    /// SwiftUI.
    ///
    /// SKIPPED on a compact-width device, which is where CI runs this suite: there is no
    /// split view on an iPhone and the same gestures would quietly measure the pop path
    /// instead. Run it on an iPad:
    ///
    ///     xcodebuild test -scheme Jesse \
    ///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
    ///       -only-testing:JesseUITests/ComposerDraftUITests/\
    ///         testTheDetailColumnReplacementCapturesTheOutgoingDraft
    func testTheDetailColumnReplacementCapturesTheOutgoingDraft() throws {
        let app = XCUIApplication()
        app.launch()
        // iPad puts the tabs in a floating bar rather than a `tabBars` element.
        let chats = app.tabBars.buttons["Chats"].exists
            ? app.tabBars.buttons["Chats"] : app.buttons["Chats"].firstMatch
        if chats.waitForExistence(timeout: 30) { chats.tap() }

        // The split view opens with its sidebar collapsed, and the sidebar is the only
        // place the compose button and the rows live. Its absence is also how this test
        // knows it is on a phone.
        let showSidebar = app.buttons["Show Sidebar"]
        try XCTSkipUnless(showSidebar.waitForExistence(timeout: 10),
                          "compact width: no split view, so no .id() replacement to test")
        showSidebar.tap()
        XCTAssertTrue(app.navigationBars.buttons["New conversation"].waitForExistence(timeout: 30),
                      "the sidebar is up")

        type("AAA111", into: newConversation(app))
        type("BBB222", into: newConversation(app))

        // Selecting a sidebar row REPLACES the detail column — no back button is involved.
        let rows = draftRows(app)
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 20),
                      "both drafted conversations are in the sidebar")
        rows.element(boundBy: 1).tap()
        let first = text(of: composer(app))
        rows.element(boundBy: 0).tap()
        let second = text(of: composer(app))

        XCTAssertNotEqual(first.contains("AAA111"), first.contains("BBB222"),
                          "a conversation holds exactly one of the two drafts — got \(first.debugDescription)")
        XCTAssertNotEqual(first.contains("AAA111"), second.contains("AAA111"),
                          "the replaced composer handed its own text over on the way out")

        clearNewestDrafts(app, 2)
    }
}
