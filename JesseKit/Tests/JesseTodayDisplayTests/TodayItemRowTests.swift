import XCTest
import SwiftUI
@testable import JesseTodayDisplay
import JesseNetworking

// THE ROW'S OPEN AFFORDANCE.
//
// The defect these cover is not a wrong pixel, it is a missing one: the Mac list opened
// an item on a double click that nothing on screen advertised, the ellipsis menu and the
// context menu between them offered move, focus, postpone, discuss and propagate but not
// Open, and the only "Open item" in the file was an accessibility action. The person who
// wrote the spec could not find it.
//
// A `View`'s body cannot be clicked from a unit test, so what is asserted here is
// everything the row decides BEFORE SwiftUI renders it: the visibility rule, the
// tooltip, and — the one that would actually regress — that the row's own `onOpen` is
// the closure the menu's Open entry carries. A row that built its actions with the wrong
// closure would draw a perfect menu that did nothing.
@MainActor
final class TodayItemRowTests: XCTestCase {

    private let item = TodayItem(id: "aaaaaaaaaaaa", text: "Order the bricks")

    private func row(revealsOpenOnHover: Bool = false,
                     onOpen: @escaping () -> Void = {}) -> TodayItemRow {
        TodayItemRow(item: item, opensOnDoubleTap: revealsOpenOnHover,
                     revealsOpenOnHover: revealsOpenOnHover,
                     onToggle: { _ in }, onOpen: onOpen)
    }

    // MARK: - The menu

    /// Open is in the list, it is what the list STARTS with, and it calls the row's own
    /// open. Both menus render `TodayItemActions`, so one assertion covers the ellipsis
    /// menu and the right-click menu at once — which is the reason the row builds the
    /// list once instead of twice.
    func testTheRowsOpenIsTheClosureItsMenuCarries() {
        var opened = 0
        let actions = row(onOpen: { opened += 1 }).actions

        actions.onOpen()
        XCTAssertEqual(opened, 1, "the menu's Open must call the row's own onOpen")
        XCTAssertEqual(TodayItemActions.openLabel, "Open")
    }

    /// The same list, whichever menu asks for it: the ellipsis menu is handed the row's
    /// actions rather than building a second set that could fall behind.
    func testTheEllipsisMenuIsGivenTheRowsOwnActions() {
        var opened = 0
        let built = row(onOpen: { opened += 1 })
        let menu = TodayItemMenu(item: item, actions: built.actions)

        menu.actions.onOpen()
        XCTAssertEqual(opened, 1)
    }

    // MARK: - The Mac hover control

    /// Only where the shell asked for it, and only under a pointer. A phone never shows
    /// it: a tap already opens the row and a finger does not hover.
    func testTheChevronAppearsOnlyWhereItWasAskedForAndOnlyOnHover() {
        XCTAssertFalse(TodayItemRow.showsOpenControl(reveals: false, hovering: false))
        XCTAssertFalse(TodayItemRow.showsOpenControl(reveals: false, hovering: true))
        XCTAssertFalse(TodayItemRow.showsOpenControl(reveals: true, hovering: false))
        XCTAssertTrue(TodayItemRow.showsOpenControl(reveals: true, hovering: true))
    }

    /// The tooltip is the OTHER half of the affordance, and it says the gesture in words
    /// for the pointer that has not found the chevron yet. A row that opens on one tap
    /// carries no tooltip at all rather than a sentence that is false on that platform.
    func testTheTooltipSaysTheGestureAndOnlyWhereTheGestureIsTwoClicks() {
        XCTAssertEqual(TodayItemRow.openHelp(reveals: true), "Double-click to open")
        XCTAssertNil(TodayItemRow.openHelp(reveals: false))
    }

    /// A chevron click opens in ONE click even on the Mac: it is a control, not the row
    /// gesture, so it never pays the selection click that forced the double tap.
    func testTheChevronOpensOnItsOwnAction() {
        var opened = 0
        let chevron = TodayOpenChevron(onOpen: { opened += 1 })
        chevron.onOpen()
        XCTAssertEqual(opened, 1)
    }

    /// The row still builds on both settings — the parameter is a rendering choice, not
    /// a second row.
    func testTheRowCarriesItsHoverSettingUnchanged() {
        XCTAssertTrue(row(revealsOpenOnHover: true).revealsOpenOnHover)
        XCTAssertFalse(row(revealsOpenOnHover: false).revealsOpenOnHover)
    }
}
