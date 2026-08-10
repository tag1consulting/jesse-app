import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// Dragging a row: what a landing MEANS, and what actually reaches the bridge.
//
// The gesture is untestable in CI — there is no finger — so the tests are split at the
// seam the design was built around. `reorderPlan` is a pure function from (item,
// landing, document) to a list of ops and is exercised directly; `model.reorder` is
// driven through the same scripted fake every other mutation test uses, so "this drag
// wrote exactly these ops, under these ids" is one assertion.
//
// The assertions that matter most are the NEGATIVE ones. A guard that merely logs, or
// that lands the row "close enough", is indistinguishable from a working one until it
// silently rewrites the day file — so every refusal below asserts `moveCount == 0`.

@MainActor
final class TodayReorderTests: XCTestCase {

    private func model(_ fake: TodayDashboardModelTests.FakeClient) -> TodayDashboardModel {
        TodayDashboardModel(makeClient: { fake },
                            now: { TodayDashboardModelTests.fixedNow })
    }

    private func loaded(_ fake: TodayDashboardModelTests.FakeClient) async -> TodayDashboardModel {
        fake.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
        let m = model(fake)
        await m.load()
        return m
    }

    private func ops(_ log: [(id: String, op: TodayMoveOp)]) -> [TodayMoveOp] { log.map(\.op) }

    // MARK: - The index SwiftUI hands over

    /// `.onMove` names an insertion point in the array BEFORE the row is taken out, so
    /// a downward move is one higher than where the row settles. Upward moves are
    /// already settled indices. The off-by-one this converts is invisible in every
    /// upward test, which is why it has one of its own.
    func testADownwardMovesDestinationIsOneAheadOfWhereItLands() {
        XCTAssertEqual(TodaySemantics.settledIndex(from: 0, to: 3), 2)
        XCTAssertEqual(TodaySemantics.settledIndex(from: 2, to: 0), 0)
        XCTAssertEqual(TodaySemantics.settledIndex(from: 2, to: 1), 1)
        XCTAssertEqual(TodaySemantics.settledIndex(from: 1, to: 1), 1)
    }

    // MARK: - Within one section

    func testDraggingOneRowUpIsASingleUp() {
        let snap = Fixt.snapshot()
        let ada = snap.item(id: Fixt.ada)!
        let plan = TodaySemantics.reorderPlan(
            for: ada, to: TodayDropTarget(sectionName: "Do Now", index: 0), in: snap)
        // Index 0 is the TOP of the section, which has an op of its own — one write
        // instead of n, and it names what the user did.
        XCTAssertEqual(plan, .ops([.topOfSection]))
    }

    func testDraggingSeveralPlacesIsThatManySteps() {
        let snap = Fixt.snapshot()
        let plain = snap.item(id: Fixt.plain)!   // Do Now index 2
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: plain,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 1),
                                       in: snap),
            .ops([.up]))
        let thermo = snap.item(id: Fixt.thermocouple)!  // Do Now index 0
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: thermo,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 2),
                                       in: snap),
            .ops([.down, .down]))
    }

    /// A drop where the row already is says nothing to the bridge. Not a refusal —
    /// there is simply nothing to write.
    func testADropWhereTheRowAlreadyIsWritesNothing() {
        let snap = Fixt.snapshot()
        let ada = snap.item(id: Fixt.ada)!
        let plan = TodaySemantics.reorderPlan(
            for: ada, to: TodayDropTarget(sectionName: "Do Now", index: 1), in: snap)
        XCTAssertEqual(plan, .unchanged)
        XCTAssertFalse(plan.writes)
    }

    /// A drop past the end settles at the last row rather than sending writes at
    /// nothing — a finger below the last row means "put it at the bottom".
    func testADropPastTheEndSettlesAtTheBottom() {
        let snap = Fixt.snapshot()
        let thermo = snap.item(id: Fixt.thermocouple)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: thermo,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 99),
                                       in: snap),
            .ops([.down, .down]))
    }

    // MARK: - Across sections

    /// `to_do_now` is the ONLY op that crosses a boundary, and it lands at the top.
    func testDraggingIntoDoNowIsToDoNow() {
        let snap = Fixt.snapshot()
        let glaze = snap.item(id: Fixt.glazeInErrands)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: glaze,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 0),
                                       in: snap),
            .ops([.toDoNow]))
    }

    /// Dropped part-way down Do Now: the op puts it at the top, and the `down`s walk it
    /// to where the finger actually was.
    func testDroppingPartWayDownDoNowWalksItThere() {
        let snap = Fixt.snapshot()
        let glaze = snap.item(id: Fixt.glazeInErrands)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: glaze,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 2),
                                       in: snap),
            .ops([.toDoNow, .down, .down]))
    }

    // MARK: - The guards

    func testTheStandingItemCannotBeDragged() {
        let snap = Fixt.snapshot()
        let standing = snap.item(id: Fixt.standing)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: standing,
                                       to: TodayDropTarget(sectionName: "Do Now", index: 0),
                                       in: snap),
            .refused(TodayReorderGuard.leadIsImmovable))
    }

    func testNothingCanBeDroppedAboveTheStandingItem() {
        let snap = Fixt.snapshot()
        let ada = snap.item(id: Fixt.ada)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: ada,
                                       to: TodayDropTarget(sectionName: "", index: 0),
                                       in: snap),
            .refused(TodayReorderGuard.aboveTheLead))
    }

    /// There is no "move to an arbitrary section" op, so a drop into one is refused
    /// rather than approximated. Landing the row somewhere else instead would be the
    /// screen inventing an intent the user did not express.
    func testDroppingIntoASectionNoOpCanReachIsRefused() {
        let snap = Fixt.snapshot()
        let ada = snap.item(id: Fixt.ada)!
        XCTAssertEqual(
            TodaySemantics.reorderPlan(for: ada,
                                       to: TodayDropTarget(sectionName: "Errands", index: 0),
                                       in: snap),
            .refused(TodayReorderGuard.onlyDoNowAcceptsDrops))
    }

    // MARK: - What reaches the bridge

    func testADragWithinASectionSendsTheOpsUnderTheSameId() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)

        await m.reorder(id: Fixt.thermocouple,
                        to: TodayDropTarget(sectionName: "Do Now", index: 2))

        XCTAssertEqual(ops(fake.moveLog), [.down, .down])
        XCTAssertEqual(fake.moveLog.map(\.id), [Fixt.thermocouple, Fixt.thermocouple],
                       "nothing re-keyed: a within-section move cannot change an id")
        XCTAssertEqual(fake.lastIfMatch, "\"tag-1\"", "every write carries the ETag")
    }

    /// The cross-section case, end to end: one `to_do_now`, and the overlay follows the
    /// item onto the NEW id the bridge answered with.
    func testADragIntoDoNowSendsToDoNowAndReKeys() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.moves = [.snapshot(Fixt.snapshotAfterGlazeMovedToDoNow())]
        let m = await loaded(fake)

        await m.reorder(id: Fixt.glazeInErrands,
                        to: TodayDropTarget(sectionName: "Do Now", index: 0))

        XCTAssertEqual(ops(fake.moveLog), [.toDoNow])
        XCTAssertEqual(fake.moveLog.first?.id, Fixt.glazeInErrands)
        XCTAssertEqual(m.snapshot?.sections[0].items.first?.id, Fixt.glazeInDoNow,
                       "the row is in Do Now under the id the bridge gave it")
        XCTAssertNil(m.snapshot?.item(id: Fixt.glazeInErrands),
                     "and nothing is left behind under the old one")
        XCTAssertTrue(m.overlay.isEmpty)
    }

    /// A multi-op plan across a boundary is where re-keying stops being theoretical:
    /// the SECOND op has to be aimed at the id the first one created, or it addresses a
    /// line the file no longer has.
    func testAMultiStepDragReAimsEachOpAtTheIdTheLastOneProduced() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let moved = Fixt.snapshotAfterGlazeMovedToDoNow()
        fake.moves = [.snapshot(moved), .snapshot(moved)]
        let m = await loaded(fake)

        await m.reorder(id: Fixt.glazeInErrands,
                        to: TodayDropTarget(sectionName: "Do Now", index: 1))

        XCTAssertEqual(ops(fake.moveLog), [.toDoNow, .down])
        XCTAssertEqual(fake.moveLog.map(\.id), [Fixt.glazeInErrands, Fixt.glazeInDoNow])
    }

    // MARK: - A refused drag writes NOTHING

    func testDraggingTheStandingItemWritesNothing() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)

        let plan = await m.reorder(id: Fixt.standing,
                                   to: TodayDropTarget(sectionName: "Do Now", index: 0))

        XCTAssertEqual(plan, .refused(TodayReorderGuard.leadIsImmovable))
        XCTAssertEqual(fake.moveCount, 0)
        XCTAssertEqual(m.notice, TodayReorderGuard.leadIsImmovable)
        XCTAssertTrue(m.overlay.isEmpty)
    }

    func testDraggingIntoAnUnreachableSectionWritesNothing() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)

        let plan = await m.reorder(id: Fixt.ada,
                                   to: TodayDropTarget(sectionName: "Errands", index: 0))

        XCTAssertEqual(plan, .refused(TodayReorderGuard.onlyDoNowAcceptsDrops))
        XCTAssertEqual(fake.moveCount, 0)
    }

    /// A drop into a SORTED section: the index the finger picked is an index in the
    /// lens, and the file has no such position. Refused rather than written somewhere
    /// approximate.
    func testADropIntoASortedSectionWritesNothing() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)
        m.setSortKey(.age, for: "Do Now")

        let plan = await m.reorder(id: Fixt.plain,
                                   to: TodayDropTarget(sectionName: "Do Now", index: 1))

        XCTAssertEqual(plan, .refused(TodayReorderGuard.notWhileSorted))
        XCTAssertEqual(fake.moveCount, 0)
    }

    /// Index 0 is exempt: "the top of this section" means the same thing under every
    /// lens, which is the same argument that keeps the two absolute ops in the menu
    /// while a sort is on.
    func testTheTopOfASortedSectionIsStillAValidLanding() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)
        m.setSortKey(.age, for: "Do Now")

        await m.reorder(id: Fixt.plain, to: TodayDropTarget(sectionName: "Do Now", index: 0))

        XCTAssertEqual(ops(fake.moveLog), [.topOfSection])
    }

    /// Offline is answered BEFORE the first write, not between the second and the
    /// third: a multi-op plan that ran out of network halfway would leave the row
    /// somewhere nobody asked for.
    func testADragWhileOfflineIsRefusedAndNotQueued() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)
        m.isNetworkUnreachable = true

        await m.reorder(id: Fixt.thermocouple,
                        to: TodayDropTarget(sectionName: "Do Now", index: 2))

        XCTAssertEqual(fake.moveCount, 0)
        XCTAssertEqual(m.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(m.overlay.isEmpty)
    }

    /// The bridge disagreed on the first op of a multi-op plan. The rest are NOT sent:
    /// they would be aimed at a document the bridge has already said no to.
    func testAConflictStopsTheRestOfThePlan() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.moves = [.conflict("nope")]
        let m = await loaded(fake)

        await m.reorder(id: Fixt.thermocouple,
                        to: TodayDropTarget(sectionName: "Do Now", index: 2))

        XCTAssertEqual(fake.moveCount, 1, "the second `down` never left")
        XCTAssertEqual(m.notice, "nope")
    }

    // MARK: - The view sort is still a lens

    /// The headline property of the sort, re-asserted now that a section can carry one
    /// of its own AND its rows can be dragged: choosing a lens writes NOTHING, and the
    /// file-order document the model reasons about is untouched.
    func testAPerSectionSortEmitsNoMoveOpAndLeavesTheFileAlone() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)
        let before = m.snapshot

        m.setSortKey(.age, for: "Do Now")

        XCTAssertEqual(fake.moveCount, 0, "a lens is not a write")
        XCTAssertEqual(fake.checkCount, 0)
        XCTAssertEqual(m.snapshot, before, "the document the model reasons about is unchanged")
        XCTAssertEqual(m.snapshot?.sections[0].items.map(\.id),
                       [Fixt.thermocouple, Fixt.ada, Fixt.plain])
        XCTAssertEqual(m.displaySnapshot?.sections[0].items.map(\.id),
                       [Fixt.ada, Fixt.thermocouple, Fixt.plain],
                       "on screen: oldest Added first, undated last")
    }

    /// One section on a lens leaves its neighbours in file order — the whole point of
    /// making the sort per-section.
    func testASectionsLensDoesNotReachItsNeighbours() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)

        m.setSortKey(.age, for: "Do Now")

        XCTAssertEqual(m.sortKey(for: "Do Now"), .age)
        XCTAssertEqual(m.sortKey(for: "Errands"), .fileOrder)
        XCTAssertEqual(m.displaySnapshot?.sections[1].items.map(\.id),
                       [Fixt.glazeInErrands, Fixt.clamps])
        XCTAssertTrue(m.isSorted)
    }

    /// Setting the document-wide order MEANS it: a choice that left three sections
    /// quietly on an older lens would not be the choice the user made.
    func testTheDocumentWideOrderClearsPerSectionOverrides() async {
        let fake = TodayDashboardModelTests.FakeClient()
        let m = await loaded(fake)
        m.setSortKey(.age, for: "Do Now")

        m.sortKey = .project

        XCTAssertEqual(m.sortKey(for: "Do Now"), .project)
        XCTAssertTrue(m.sectionSortKeys.isEmpty)
    }

    // MARK: - What a Process-updates turn would close

    /// Every ticked line except the ones already parked in Done — that section is where
    /// processed work goes, and re-proposing it would ask the agent to close the same
    /// thing twice.
    func testItemsToProcessSkipsWhatIsAlreadyInDone() async {
        var day = Fixt.snapshot()
        day.sections.append(TodaySection(name: "Done Today", kind: "tasks", items: [
            Fixt.item("6d1e3c9a0009", lead: "Already closed at source.",
                      section: "Done Today", checked: true),
        ]))
        day.leadItems[0].checked = true
        let fake = TodayDashboardModelTests.FakeClient()
        fake.fetches = [.snapshot(day)]
        let m = model(fake)
        await m.load()

        XCTAssertEqual(m.itemsToProcess.map(\.id), [Fixt.standing, Fixt.clamps],
                       "the standing item can't be MOVED, but it can certainly be finished")
    }

    /// The list is what the user is LOOKING at, overlay included: an item ticked ten
    /// seconds ago and not yet confirmed is about to be closed at source either way.
    func testItemsToProcessIncludesATickThatIsStillInFlight() async {
        let fake = TodayDashboardModelTests.FakeClient()
        fake.moves = []
        let m = await loaded(fake)
        XCTAssertEqual(m.itemsToProcess.map(\.id), [Fixt.clamps])

        m.overlay.checks[Fixt.ada] = true

        XCTAssertEqual(m.itemsToProcess.map(\.id), [Fixt.ada, Fixt.clamps])
    }
}
