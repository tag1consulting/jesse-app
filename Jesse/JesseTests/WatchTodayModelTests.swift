import XCTest
@testable import Jesse

/// The wrist's Today reducer, driven with a fake sender — no WatchConnectivity, no
/// phone, no clock.
///
/// The interesting behaviour is all in the seam between a LOCAL claim and the
/// phone's later answer. The watch never talks to the bridge, so it cannot know
/// whether a check landed; all it can do is show the claim as pending and wait for
/// the next application context to either agree with it or replace it. These tests
/// pin every way that can end: agreed, vanished-because-done, still-disagreeing,
/// and queued because the phone was not there to ask.
@MainActor
final class WatchTodayModelTests: XCTestCase {

    private final class FakeSender: WatchTodaySending {
        var isReachable: Bool
        var onTodayContext: ((WatchTodaySummary) -> Void)?
        private(set) var sent: [WatchTodayCheck] = []
        init(reachable: Bool = true) { self.isReachable = reachable }
        func send(_ check: WatchTodayCheck) { sent.append(check) }
        /// Simulate the phone pushing a fresh context.
        func push(_ summary: WatchTodaySummary) { onTodayContext?(summary) }
    }

    private var clock = Date(timeIntervalSince1970: 1_786_000_000)

    private func makeModel(reachable: Bool = true) -> (WatchTodayModel, FakeSender) {
        let sender = FakeSender(reachable: reachable)
        let model = WatchTodayModel(sender: sender, now: { [self] in clock })
        return (model, sender)
    }

    // MARK: Empty state

    func testStartsWithNothing() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.hasDay)
        XCTAssertFalse(model.isStale)
    }

    // MARK: Rendering a context

    func testRendersRowsInPayloadOrder() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        XCTAssertEqual(model.rows.map(\.id), ["lead", "open-a", "open-b"])
        XCTAssertTrue(model.hasDay)
    }

    func testAnUncheckedRowIsOpenAndACheckedRowIsDone() {
        let (model, sender) = makeModel()
        sender.push(Self.day(leadChecked: true))
        XCTAssertEqual(model.rows.first?.state, .done)
        XCTAssertEqual(model.rows.last?.state, .open)
    }

    func testFooterCountsTheWorkLeftOnThePhone() {
        let (model, sender) = makeModel()
        // Three rows ship, two of them open; the day has nine open in total.
        sender.push(Self.day(openCount: 9, doneCount: 4))
        XCTAssertEqual(model.moreOnPhone, 6)
        XCTAssertEqual(model.doneCount, 4)
    }

    /// A day whose open work all fits on the wrist has nothing "more on your phone",
    /// and the footer must say nothing rather than say zero.
    func testFooterIsZeroWhenEverythingFits() {
        let (model, sender) = makeModel()
        sender.push(Self.day(openCount: 2, doneCount: 0))
        XCTAssertEqual(model.moreOnPhone, 0)
    }

    /// A count that disagrees with the rows (a phone mid-write, a clamped payload)
    /// must never produce a negative footer.
    func testFooterNeverGoesNegative() {
        let (model, sender) = makeModel()
        sender.push(Self.day(openCount: 0, doneCount: 0))
        XCTAssertEqual(model.moreOnPhone, 0)
    }

    // MARK: Checking off

    func testTogglingAnOpenRowMarksItPendingAndSendsTheIntent() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")

        XCTAssertEqual(model.rows.first { $0.id == "open-a" }?.state, .pending)
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent.first?.itemId, "open-a")
        XCTAssertEqual(sender.sent.first?.checked, true)
    }

    func testTogglingACheckedRowSendsAnUncheck() {
        let (model, sender) = makeModel()
        sender.push(Self.day(leadChecked: true))
        model.toggle("lead")

        XCTAssertEqual(model.rows.first?.state, .pending)
        XCTAssertEqual(sender.sent.first?.checked, false)
    }

    func testEachIntentCarriesItsOwnId() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        model.toggle("open-a")
        XCTAssertEqual(sender.sent.count, 2)
        XCTAssertNotEqual(sender.sent[0].intentId, sender.sent[1].intentId)
    }

    func testTogglingAnUnknownRowSendsNothing() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("not-here")
        XCTAssertTrue(sender.sent.isEmpty)
    }

    /// The phone is not there, so the intent rides the reliable queue and the row
    /// says so — the same promise the watch's chat path makes with its "queued"
    /// state, rather than a check that silently evaporates.
    func testAnUnreachablePhoneQueuesTheIntentAndSaysSo() {
        let (model, sender) = makeModel(reachable: false)
        sender.push(Self.day())
        model.toggle("open-a")

        XCTAssertEqual(model.rows.first { $0.id == "open-a" }?.state, .queued)
        XCTAssertEqual(sender.sent.count, 1, "a queued intent is still handed to the transport")
    }

    // MARK: Reconciling with the phone's answer

    /// The item is still on the wrist and the phone now agrees it is checked, so the
    /// local claim retires and the row renders from the payload.
    func testAnAgreeingContextRetiresThePendingClaim() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("lead")
        sender.push(Self.day(leadChecked: true))

        XCTAssertEqual(model.rows.first?.state, .done)
        XCTAssertFalse(model.isPending("lead"))
    }

    /// A context that still shows the row open — a fetch that raced ahead of the
    /// write — must NOT spring the box back open under the user's finger.
    func testADisagreeingContextKeepsTheClaimPending() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("lead")
        sender.push(Self.day())

        XCTAssertEqual(model.rows.first?.state, .pending)
        XCTAssertTrue(model.isPending("lead"))
    }

    /// The ordinary case: a ticked Do Now item stops being open, so the phone stops
    /// shipping it. Without this the row would simply VANISH, which reads exactly
    /// like a failure. It stays as a settled receipt at the foot of the list.
    func testAnItemThatLeavesThePayloadAfterACheckBecomesAConfirmedReceipt() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        sender.push(Self.day(rowIds: ["lead", "open-b"]))

        XCTAssertFalse(model.isPending("open-a"))
        let row = model.rows.first { $0.id == "open-a" }
        XCTAssertEqual(row?.state, .confirmed)
        XCTAssertEqual(row?.lead, "Order the thermocouple", "the receipt keeps its words")
        XCTAssertEqual(model.rows.map(\.id).last, "open-a", "receipts sit at the foot")
    }

    /// An UNCHECK that removes the row (it was the lead item and the day rebuilt) has
    /// no receipt to show: the claim simply retires.
    func testAnUncheckThatLeavesThePayloadJustRetires() {
        let (model, sender) = makeModel()
        sender.push(Self.day(leadChecked: true))
        model.toggle("lead")
        sender.push(Self.day(rowIds: ["open-a", "open-b"]))

        XCTAssertFalse(model.isPending("lead"))
        XCTAssertFalse(model.rows.contains { $0.id == "lead" })
    }

    /// A row the user re-opened on the phone comes back as a real row, so its receipt
    /// must go — two rows for one item is the one thing the tail must never do.
    func testAReceiptIsDroppedIfTheRowComesBack() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        sender.push(Self.day(rowIds: ["lead", "open-b"]))
        XCTAssertEqual(model.rows.filter { $0.id == "open-a" }.count, 1)

        sender.push(Self.day())
        XCTAssertEqual(model.rows.filter { $0.id == "open-a" }.count, 1)
        XCTAssertEqual(model.rows.first { $0.id == "open-a" }?.state, .open)
    }

    func testAConfirmedReceiptCannotBeToggled() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        sender.push(Self.day(rowIds: ["lead", "open-b"]))

        model.toggle("open-a")
        XCTAssertEqual(sender.sent.count, 1, "no second intent for a settled row")
    }

    /// Yesterday's receipts are not today's. A payload for a new day clears the tail.
    func testANewDayClearsTheReceipts() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        sender.push(Self.day(rowIds: ["lead", "open-b"]))
        XCTAssertTrue(model.rows.contains { $0.state == .confirmed })

        sender.push(Self.day(date: "2026-08-12", rowIds: ["lead"]))
        XCTAssertFalse(model.rows.contains { $0.state == .confirmed })
    }

    // MARK: The stale guard

    func testAFreshContextIsNotStale() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(17 * 3600)
        model.refreshFreshness()
        XCTAssertFalse(model.isStale)
    }

    func testAContextOlderThanEighteenHoursIsStale() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(18 * 3600 + 1)
        model.refreshFreshness()
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.dayLabel, "2026-08-11")
    }

    /// A phone whose clock is ahead of the watch's would otherwise produce a
    /// NEGATIVE age; that is not stale, it is merely odd.
    func testAContextFromTheFutureIsNotStale() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(-3600)
        model.refreshFreshness()
        XCTAssertFalse(model.isStale)
    }

    /// A fresh push clears the banner without the app having to be reactivated.
    func testAFreshPushUnstalesTheScreen() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(20 * 3600)
        model.refreshFreshness()
        XCTAssertTrue(model.isStale)

        sender.push(Self.day(pushedAt: clock))
        XCTAssertFalse(model.isStale)
    }

    /// **The regression test for a guard that read correctly and never fired.**
    /// `isStale` was computed over `now()`, so the answer changed as the night
    /// passed but nothing published — SwiftUI had no reason to redraw and the banner
    /// stayed hidden. Time passing must NOT flip it on its own; re-activating must.
    func testTimePassingAloneDoesNotFlipTheBannerButReactivatingDoes() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(19 * 3600)
        XCTAssertFalse(model.isStale, "nothing has asked the question yet")

        model.refreshFreshness()
        XCTAssertTrue(model.isStale, "the app becoming active asks it")
    }

    /// With no day at all there is nothing to be stale about — the screen shows its
    /// "no day yet" state, not a banner over an empty list.
    func testRefreshingWithNoDayIsNotStale() {
        let (model, _) = makeModel()
        clock = clock.addingTimeInterval(48 * 3600)
        model.refreshFreshness()
        XCTAssertFalse(model.isStale)
    }

    // MARK: Fixtures

    private static func day(date: String = "2026-08-11",
                            leadChecked: Bool = false,
                            rowIds: [String] = ["lead", "open-a", "open-b"],
                            openCount: Int = 3,
                            doneCount: Int = 0,
                            pushedAt: Date = Date(timeIntervalSince1970: 1_786_000_000))
        -> WatchTodaySummary {
        let all: [String: WatchTodayRow] = [
            "lead": WatchTodayRow(id: "lead", lead: "TOP PRIORITY: finish the rebuild",
                                  checked: leadChecked, section: ""),
            "open-a": WatchTodayRow(id: "open-a", lead: "Order the thermocouple",
                                    checked: false, section: "Do Now"),
            "open-b": WatchTodayRow(id: "open-b", lead: "Reply to Ada",
                                    checked: false, section: "Do Now"),
        ]
        return WatchTodaySummary(date: date, etag: "\"tag\"", pushedAt: pushedAt,
                                 rows: rowIds.compactMap { all[$0] },
                                 openCount: openCount, doneCount: doneCount)
    }
}
