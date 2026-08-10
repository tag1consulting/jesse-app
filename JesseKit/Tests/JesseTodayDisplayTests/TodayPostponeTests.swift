import XCTest
import JesseNetworking
@testable import JesseTodayDisplay

// **Postponed for today** — the third state between open and done.
//
// What these tests are really pinning is the reason the feature exists. Before it,
// a day holding work that was not going to happen today could only be cleared by
// ticking the item off, which records it as DONE and which `Close it at source`
// would then propagate into the project files. So the assertions below are mostly
// about what postponing must NOT do: not mark anything done, not remove a row from
// the screen, not touch the day file, and not survive the night.
final class TodayPostponeTests: XCTestCase {

    // MARK: - The counts

    /// The whole point: the badge drops without anything being claimed as done.
    func testPostponingADoNowItemTakesItOutOfTheBadge() throws {
        let before = Fixt.snapshot()
        let after = Fixt.snapshotWithPostponed(Fixt.ada)
        XCTAssertEqual(TodaySemantics.doNowOpenCount(after),
                       TodaySemantics.doNowOpenCount(before) - 1)
        XCTAssertEqual(TodaySemantics.tabBadge(after), TodaySemantics.tabBadge(before) - 1)
        let item = try XCTUnwrap(after.item(id: Fixt.ada))
        XCTAssertFalse(item.checked, "and NOTHING was claimed to be done")
        XCTAssertTrue(item.deferred)
    }

    /// The standing lead item counts toward the badge, so it has to be dismissible
    /// too — it is also the one item no move can touch, which is why postponing it
    /// is the only way to clear it honestly.
    func testPostponingTheLeadItemTakesItOutOfTheBadgeToo() {
        let before = Fixt.snapshot()
        let after = Fixt.snapshotWithPostponed(Fixt.standing)
        XCTAssertEqual(TodaySemantics.doNowOpenCount(after),
                       TodaySemantics.doNowOpenCount(before) - 1)
        XCTAssertEqual(TodaySemantics.tabBadge(after), TodaySemantics.tabBadge(before) - 1)
    }

    /// A header that disagreed with the badge would leave the user reasoning about
    /// two numbers nobody defined.
    func testTheSectionCountAgreesWithTheBadge() {
        let before = Fixt.snapshot().sections[0]
        let after = Fixt.snapshotWithPostponed(Fixt.ada).sections[0]
        XCTAssertEqual(TodaySemantics.openCount(in: after),
                       TodaySemantics.openCount(in: before) - 1)
        XCTAssertEqual(TodaySemantics.postponedCount(in: after), 1)
        XCTAssertEqual(after.items.count, before.items.count,
                       "the row is still in the section — nothing was hidden")
    }

    /// A checked row is not also postponed, so it is counted once and reads as one
    /// thing. `isOpen` is the single predicate both counts are built from.
    func testACheckedRowIsNeverAlsoCountedAsPostponed() {
        var snap = Fixt.snapshotWithPostponed(Fixt.ada)
        snap.sections[0].items[1].checked = true
        XCTAssertEqual(TodaySemantics.postponedCount(in: snap.sections[0]), 0,
                       "done outranks postponed in the tally as well as in the row")
        XCTAssertFalse(TodaySemantics.isOpen(snap.sections[0].items[1]),
                       "and it is not open either — one row, counted once")
    }

    /// The both-flags case arrives from a SECOND device: postponed here, ticked off
    /// there. The overlay pass collapses the pair for a tap made on this device, but
    /// a snapshot can carry both — and a row struck through as done while also
    /// wearing a "Postponed" chip is two answers to one question. `isPostponed` is
    /// the single rule every reader goes through, so it holds with no overlay at all.
    func testAnItemThatArrivesBothCheckedAndDeferredReadsAsDoneOnly() {
        var snap = Fixt.snapshotWithPostponed(Fixt.ada)
        snap.sections[0].items[1].checked = true
        let item = snap.sections[0].items[1]
        XCTAssertTrue(item.deferred, "the flag is still on the wire")
        XCTAssertFalse(TodaySemantics.isPostponed(item), "but the row does not claim it")
        // And it does not sink, either: a done row belongs where the day put it.
        let drawn = TodaySemantics.sortedForDisplay(snap, by: .fileOrder)
        XCTAssertEqual(drawn.sections[0].items.map(\.id),
                       snap.sections[0].items.map(\.id))
    }

    // MARK: - What postponing must NOT reach

    /// **A postponed item is not closed at source.** Both the row's action and the
    /// Process-updates batch are gated on `checked`, so this should hold without any
    /// new code — which is exactly why it is asserted rather than reasoned about: the
    /// failure it guards against is a postponement leaking into a turn that writes
    /// "done" into a project file for work nobody did.
    func testAPostponedItemIsNeverProposedForClosingAtSource() throws {
        let snap = Fixt.snapshotWithPostponed(Fixt.ada)
        let item = try XCTUnwrap(snap.item(id: Fixt.ada))
        XCTAssertFalse(item.checked, "which is what the Close-at-source action is gated on")
        XCTAssertFalse(TodaySemantics.itemsToProcess(snap).contains { $0.id == Fixt.ada },
                       "and it is not in the batch either")
    }

    /// Postponing the LEAD item does not sweep it into a batch either. Worth its own
    /// case because the lead item is the one row `itemsToProcess` deliberately does
    /// include when it is ticked (it cannot be moved, but it can certainly be
    /// finished), so it is the one most likely to slip through.
    func testAPostponedLeadItemIsNotSweptIntoABatch() {
        let snap = Fixt.snapshotWithPostponed(Fixt.standing)
        XCTAssertFalse(TodaySemantics.itemsToProcess(snap).contains { $0.id == Fixt.standing })
    }

    // MARK: - Tomorrow

    /// **The badge comes back by itself.** The bridge keys a postponement by day, so
    /// the same document served under a different date carries none — which is what
    /// makes this client state rather than an edit somebody has to unwind.
    func testTomorrowsSnapshotCarriesNoPostponement() {
        let today = Fixt.snapshotWithPostponed(Fixt.ada)
        // The same day file, one day on: identical ids (they hash the words, not the
        // date) and no defer flag, because the store's key expired with the day.
        var tomorrow = Fixt.snapshot()
        tomorrow.date = "2026-03-04"
        XCTAssertEqual(today.allItems.map(\.id), tomorrow.allItems.map(\.id),
                       "the item ids are unchanged: the DAY is what expires the flag")
        XCTAssertEqual(TodaySemantics.tabBadge(tomorrow),
                       TodaySemantics.tabBadge(today) + 1,
                       "so the badge is back with no user action at all")
    }

    // MARK: - The optimistic overlay

    func testAPostponementApplasesInstantlyAndMovesTheBadge() {
        let snap = Fixt.snapshot()
        let out = TodaySemantics.display(snap, applying:
            TodayOptimism(deferrals: [Fixt.ada: true]))
        XCTAssertTrue(out.item(id: Fixt.ada)?.deferred == true)
        XCTAssertEqual(TodaySemantics.tabBadge(out), TodaySemantics.tabBadge(snap) - 1)
    }

    /// `false` is a real entry, not the absence of one: "bring this back to today"
    /// has to override a server snapshot that still says deferred.
    func testBringingARowBackAppliesOptimisticallyToo() {
        let snap = Fixt.snapshotWithPostponed(Fixt.ada)
        let out = TodaySemantics.display(snap, applying:
            TodayOptimism(deferrals: [Fixt.ada: false]))
        XCTAssertEqual(out.item(id: Fixt.ada)?.deferred, false)
        XCTAssertEqual(TodaySemantics.tabBadge(out), TodaySemantics.tabBadge(snap) + 1)
    }

    /// DONE BEATS POSTPONED. A row cannot claim both, and the check is what wins:
    /// "I did it" supersedes "not today", not the other way round.
    func testCheckingAPostponedItemClearsIt() throws {
        let snap = Fixt.snapshotWithPostponed(Fixt.ada)
        let out = TodaySemantics.display(snap, applying:
            TodayOptimism(checks: [Fixt.ada: true]))
        let item = try XCTUnwrap(out.item(id: Fixt.ada))
        XCTAssertTrue(item.checked)
        XCTAssertFalse(item.deferred, "a row cannot read as both done and set aside")
    }

    /// A cross-section move re-hashes the id, so a postponement queued under the old
    /// one would be a ghost — the row would spring back into the badge.
    func testADeferralIsCarriedOntoTheNewIdByARekey() {
        var overlay = TodayOptimism(deferrals: [Fixt.glazeInErrands: true])
        overlay.rekey(from: Fixt.glazeInErrands, to: Fixt.glazeInDoNow)
        XCTAssertNil(overlay.deferrals[Fixt.glazeInErrands])
        XCTAssertEqual(overlay.deferrals[Fixt.glazeInDoNow], true)
    }

    func testSettlingAnIdForgetsItsDeferral() {
        var overlay = TodayOptimism(deferrals: ["x": true])
        XCTAssertFalse(overlay.isEmpty, "a pending postponement is state to apply")
        overlay.settle("x")
        XCTAssertTrue(overlay.isEmpty)
    }

    // MARK: - Where a postponed row is drawn

    /// Sunk to the bottom of its OWN section, under every lens including file order,
    /// and never moved to another section: crossing a boundary would change the
    /// item's id and its project rollup, and the whole claim of this feature is that
    /// nothing about the item changes.
    func testPostponedRowsSinkToTheBottomOfTheirOwnSection() {
        let snap = Fixt.snapshotWithPostponed(Fixt.thermocouple)
        for key in TodaySortKey.allCases {
            let out = TodaySemantics.sortedForDisplay(snap, by: key)
            let doNow = out.sections[0]
            XCTAssertEqual(doNow.items.last?.id, Fixt.thermocouple,
                           "postponed sinks under \(key.label)")
            XCTAssertEqual(doNow.items.count, 3, "and it is still on screen")
            XCTAssertEqual(doNow.name, "Do Now",
                           "in its own section: a move would change its id")
        }
    }

    // MARK: - The model

    @MainActor
    func testAPostponeIsRefusedWhileTheDayIsReadOnly() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot())]
        let model = TodayDashboardModel(makeClient: { fake })
        await model.load()
        model.isNetworkUnreachable = true

        await model.postpone(id: Fixt.ada, deferred: true)
        XCTAssertEqual(fake.postponeCount, 0, "nothing was sent")
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(model.overlay.deferrals.isEmpty,
                      "and nothing is queued for later: an ETag captured before an "
                      + "outage is worthless after it")
    }

    @MainActor
    func testAPostponeIsOptimisticThenSettledByTheServersAnswer() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot())]
        fake.postpones = [.snapshot(Fixt.snapshotWithPostponed(Fixt.ada, etag: "\"tag-2\""))]
        let model = TodayDashboardModel(makeClient: { fake })
        await model.load()
        let badgeBefore = model.tabBadgeCount

        await model.postpone(id: Fixt.ada, deferred: true)
        XCTAssertEqual(fake.lastPostpone?.id, Fixt.ada)
        XCTAssertEqual(fake.lastPostpone?.deferred, true)
        XCTAssertEqual(fake.lastIfMatch, "\"tag-1\"", "every mutation carries the tag")
        XCTAssertEqual(model.tabBadgeCount, badgeBefore - 1)
        XCTAssertTrue(model.overlay.deferrals.isEmpty,
                      "the server agreed, so the overlay entry retires")
        XCTAssertEqual(model.etag, "\"tag-2\"")
    }

    /// A `410` is not reachable for this endpoint (the bridge answers `404`, which
    /// the client maps to the notice row) — but a failed round trip must still drop
    /// the optimism rather than leave the badge lying.
    @MainActor
    func testAFailedPostponeDropsTheOptimismAndSaysSo() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.fetches = [.snapshot(Fixt.snapshot())]
        fake.postpones = [.conflict("no item with that id in today's day file")]
        let model = TodayDashboardModel(makeClient: { fake })
        await model.load()
        let badgeBefore = model.tabBadgeCount

        await model.postpone(id: Fixt.ada, deferred: true)
        XCTAssertTrue(model.overlay.deferrals.isEmpty)
        XCTAssertEqual(model.tabBadgeCount, badgeBefore, "the badge tells the truth again")
        XCTAssertEqual(model.notice, "no item with that id in today's day file")
    }
}
