import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// Two things the Today TAB (as opposed to the Today document) rests on: the one
// number it puts on the tab item, and what a tap does when the bridge is out of
// reach.
//
// The second is the one worth stating plainly, because the tempting design is the
// wrong one. A checkbox tapped offline is NOT queued. `Today.md` is rewritten in
// full every morning and edited by the agent all day, and every mutation is gated
// on an `If-Match` ETag; a tap held through an outage would replay against a
// document that has since moved, reworded, or closed the very line it was aimed at.
// So the screen goes read-only, says so once, and asks for the tap again when it
// can honour it.

@MainActor
final class TodayReadOnlyTests: XCTestCase {

    private typealias FakeClient = TodayDashboardModelTests.FakeClient

    nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_772_530_200)

    private func loadedModel(_ fake: FakeClient) async -> TodayDashboardModel {
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        let m = TodayDashboardModel(makeClient: { fake }, now: { Self.fixedNow })
        await m.load()
        return m
    }

    // MARK: - The tab badge

    /// The badge is the two halves added up BY THE SEMANTICS: three open Do Now
    /// items plus the standing lead item (4), plus two unseen glanceables (2).
    func testTheTabBadgeIsDoNowWorkPlusUnseenReports() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)

        XCTAssertEqual(m.badgeCount, 4)
        XCTAssertEqual(m.unseenReportCount, 2)
        XCTAssertEqual(m.tabBadgeCount, 6)
        XCTAssertEqual(TodaySemantics.tabBadge(Fixt.snapshot()), 6,
                       "the sum is the semantics', not a view's")
    }

    /// Nothing loaded is a badge of zero rather than a guess, so a cold launch never
    /// shows a number it cannot justify.
    func testTheBadgeIsZeroBeforeAnythingLoads() {
        let m = TodayDashboardModel(makeClient: { FakeClient() }, now: { Self.fixedNow })
        XCTAssertEqual(m.tabBadgeCount, 0)
    }

    /// A tick moves the badge before the round trip completes — the overlay is
    /// applied, and the badge reads the overlaid document.
    func testTheBadgeFallsOnAnOptimisticCheck() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)

        await m.check(id: Fixt.ada, checked: true)

        XCTAssertEqual(m.tabBadgeCount, 5)
    }

    /// Glancing a report clears its share of the badge too, which is what makes the
    /// number reachable: briefing rows are read, not done.
    func testAGlanceLowersTheBadge() async {
        var seen = Fixt.snapshot(etag: "\"tag-2\"")
        seen.sections[2].reports[0].seen = true
        let fake = FakeClient()
        fake.glances = [.snapshot(seen)]
        let m = await loadedModel(fake)

        await m.glance(id: Fixt.runDay)

        XCTAssertEqual(m.tabBadgeCount, 5)
    }

    // MARK: - Read-only, from the shell's probe

    /// The shell's reachability probe puts the screen into read-only BEFORE any tap,
    /// and a tap made there never reaches the client at all.
    func testACheckIsRefusedNotQueuedWhileTheProbeSaysUnreachable() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)
        let callsBefore = fake.checkCount
        m.isNetworkUnreachable = true

        await m.check(id: Fixt.ada, checked: true, evidence: "did it")

        XCTAssertEqual(fake.checkCount, callsBefore, "nothing was sent")
        XCTAssertTrue(m.overlay.isEmpty, "and nothing is being held to send later")
        XCTAssertEqual(m.snapshot?.item(id: Fixt.ada)?.checked, false,
                       "the box did not flip under the user's finger")
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(m.isReadOnly)
    }

    func testAMoveAndAGlanceAreRefusedTheSameWay() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)
        m.isNetworkUnreachable = true

        await m.move(id: Fixt.glazeInErrands, op: .toDoNow)
        await m.glance(id: Fixt.runDay)

        XCTAssertEqual(fake.moveCount, 0)
        XCTAssertEqual(fake.glanceCount, 0)
        XCTAssertTrue(m.overlay.isEmpty)
        XCTAssertEqual(m.unseenReportCount, 2, "the dot stays until the bridge is told")
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
    }

    /// The view asks before it opens the evidence sheet, so a refusal never arrives
    /// after the user has typed a note.
    func testTheViewCanAskForTheRefusalBeforeStartingAFlow() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)

        XCTAssertFalse(m.refuseInteractionIfReadOnly())
        XCTAssertNil(m.notice)

        m.isNetworkUnreachable = true
        XCTAssertTrue(m.refuseInteractionIfReadOnly())
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
    }

    /// The day stays on screen while it is read-only. A snapshot the user was reading
    /// a second ago is still the best answer available — an empty state would be a
    /// worse one.
    func testTheLastDayKeepsRenderingWhileReadOnly() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)
        m.isNetworkUnreachable = true

        guard case .content(let day) = m.displayState else { return XCTFail("expected content") }
        XCTAssertEqual(day.sections.count, 3)
    }

    // MARK: - Read-only, from our own failed call

    /// One failed mutation is enough: the next tap is refused rather than sent into
    /// the same hole. (The first one is not refused — nothing had told us yet.)
    func testAFailedCallMakesTheNextTapARefusal() async {
        let throwing = TodayDashboardModelTests.ThrowingClient(
            fetch: .snapshot(Fixt.snapshot(etag: "\"tag-1\"")))
        let m = TodayDashboardModel(makeClient: { throwing }, now: { Self.fixedNow })
        await m.load()

        await m.check(id: Fixt.ada, checked: true)
        XCTAssertTrue(m.isOffline)
        XCTAssertNil(m.notice, "the first failure is an error, not a refusal")

        await m.check(id: Fixt.thermocouple, checked: true)
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(m.overlay.isEmpty)
    }

    /// A round trip that lands outranks the shell's probe: one successful refresh
    /// restores editing instead of leaving the screen read-only until the next probe.
    func testASuccessfulFetchClearsBothReadOnlySignals() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)
        m.isNetworkUnreachable = true
        await m.check(id: Fixt.ada, checked: true)
        XCTAssertNotNil(m.notice)

        await m.refresh()

        XCTAssertFalse(m.isReadOnly)
        XCTAssertFalse(m.isNetworkUnreachable)
        XCTAssertNil(m.notice)

        await m.check(id: Fixt.ada, checked: true)
        XCTAssertEqual(fake.checkCount, 1, "and taps go through again")
    }

    /// The notice is about one refused interaction, so it can be dismissed without
    /// leaving the screen, and a later action supersedes it.
    func testTheNoticeIsDismissibleAndSupersededByTheNextAction() async {
        let fake = FakeClient()
        let m = await loadedModel(fake)
        m.isNetworkUnreachable = true
        await m.check(id: Fixt.ada, checked: true)
        XCTAssertNotNil(m.notice)

        m.dismissNotice()
        XCTAssertNil(m.notice)

        m.isNetworkUnreachable = false
        await m.check(id: Fixt.ada, checked: true)
        XCTAssertNil(m.notice, "a tap that goes through clears the last refusal")
    }

    /// A `409` still surfaces the bridge's own words — as the same one-line notice
    /// the read-only refusal uses, not as a modal alert.
    func testAConflictSurfacesThroughTheSameNotice() async {
        let fake = FakeClient()
        fake.moves = [.conflict("this day file has no \"Do Now\" section")]
        let m = await loadedModel(fake)

        await m.move(id: Fixt.glazeInErrands, op: .toDoNow)

        XCTAssertEqual(m.notice, "this day file has no \"Do Now\" section")
        XCTAssertFalse(m.isReadOnly, "a refused move is not an outage")
    }
}
