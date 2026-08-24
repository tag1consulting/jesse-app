import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The view sort, and the focus affordance that is not one.
//
// The whole design rests on a claim that has to be TESTED rather than asserted in a
// comment: sorting is a lens and changes nothing about the day, while focus is an edit
// and changes the file. So these check both halves — that a sort is a pure reordering
// with identical membership and counts, and that focus lands on exactly the move op the
// bridge would apply.

@MainActor
final class TodaySortTests: XCTestCase {

    /// A section of five items with deliberately messy projects and Added dates: two
    /// share a project (so ties are exercised), one has no Added date at all, and file
    /// order matches none of the sorted orders.
    private func messy() -> TodaySnapshot {
        TodaySnapshot(
            sections: [
                TodaySection(name: "Do Now", kind: "tasks", items: [
                    Fixt.item("a", lead: "A", section: "Do Now",
                              added: "2026-03-01", project: .perseido),
                    Fixt.item("b", lead: "B", section: "Do Now",
                              added: "2026-01-15", project: .tag1),
                    Fixt.item("c", lead: "C", section: "Do Now",
                              added: nil, project: .personal),
                    Fixt.item("d", lead: "D", section: "Do Now",
                              added: "2026-02-20", project: .tag1),
                    Fixt.item("e", lead: "E", section: "Do Now",
                              added: "2025-11-02", project: .unfiled),
                ]),
                TodaySection(name: "Errands", kind: "tasks", items: [
                    Fixt.item("f", lead: "F", section: "Errands",
                              added: "2026-03-05", project: .network),
                    Fixt.item("g", lead: "G", section: "Errands",
                              added: "2026-02-01", project: .tag1),
                ]),
            ])
    }

    private func ids(_ snap: TodaySnapshot, _ section: String) -> [String] {
        snap.sections.first { $0.name == section }?.items.map(\.id) ?? []
    }

    // MARK: - The comparators

    /// File order is the IDENTITY, not a sort that happens to agree with it. It is the
    /// default for a reason — the day file's order is the day's own argument — so it has
    /// to be provably untouched rather than merely stable.
    func testFileOrderIsTheIdentity() {
        let snap = messy()
        XCTAssertEqual(TodaySemantics.sortedForDisplay(snap, by: .fileOrder), snap)
        let items = snap.sections[0].items
        XCTAssertEqual(TodaySemantics.sorted(items, by: .fileOrder), items)
        XCTAssertFalse(TodaySortKey.fileOrder.reorders)
    }

    func testByProjectUsesDashboardOrderWithUnfiledLast() {
        let sorted = TodaySemantics.sortedForDisplay(messy(), by: .project)
        XCTAssertEqual(ids(sorted, "Do Now"), ["b", "d", "c", "a", "e"],
                       "tag1, tag1, personal, perseido, then unfiled last")
        XCTAssertEqual(sorted.sections[0].items.map(\.project),
                       [.tag1, .tag1, .personal, .perseido, .unfiled])
    }

    func testByAgePutsTheOldestFirstAndTheUndatedLast() {
        let sorted = TodaySemantics.sortedForDisplay(messy(), by: .age)
        XCTAssertEqual(ids(sorted, "Do Now"), ["e", "b", "d", "a", "c"])
        XCTAssertNil(sorted.sections[0].items.last?.addedDate,
                     "an item with no Added date has an UNKNOWN age, and unknown is not ancient")
    }

    /// Ties keep file order, and the sort is therefore a pure function of the snapshot.
    /// `Array.sorted(by:)` is not stable in Swift, so without the file-index tiebreak the
    /// tied group — on the live day file, the 45 unfiled items — would shuffle on every
    /// re-render and the screen would twitch for no reason.
    func testTiesKeepFileOrderAndTheSortIsStable() {
        let snap = messy()
        let once = TodaySemantics.sortedForDisplay(snap, by: .project)
        XCTAssertEqual(ids(once, "Do Now").prefix(2), ["b", "d"],
                       "two tag1 items keep the order the file has them in")
        for _ in 0..<20 {
            XCTAssertEqual(TodaySemantics.sortedForDisplay(snap, by: .project), once)
        }
        // Sorting an already-sorted document is idempotent, which is the same property
        // read from the other end.
        XCTAssertEqual(TodaySemantics.sortedForDisplay(once, by: .project), once)
    }

    // MARK: - A lens changes nothing

    /// Membership, counts and the badge are identical under every key. A sort that
    /// dropped or duplicated a row would be a sort that lied about the day.
    func testASortChangesOrderAndNothingElse() {
        let snap = messy()
        for key in TodaySortKey.allCases {
            let sorted = TodaySemantics.sortedForDisplay(snap, by: key)
            XCTAssertEqual(Set(sorted.allItems.map(\.id)), Set(snap.allItems.map(\.id)), "\(key)")
            XCTAssertEqual(sorted.allItems.count, snap.allItems.count, "\(key)")
            XCTAssertEqual(TodaySemantics.counts(sorted), TodaySemantics.counts(snap), "\(key)")
            XCTAssertEqual(TodaySemantics.tabBadge(sorted), TodaySemantics.tabBadge(snap), "\(key)")
        }
    }

    /// A sort never crosses a section boundary. Sections ARE the document's structure —
    /// and a section name is part of every contained item's identity — so a global sort
    /// would dissolve the day into a list of tasks with no argument left in it.
    func testASortNeverMovesAnItemBetweenSections() {
        for key in TodaySortKey.allCases {
            let sorted = TodaySemantics.sortedForDisplay(messy(), by: key)
            XCTAssertEqual(sorted.sections.map(\.name), ["Do Now", "Errands"], "\(key)")
            XCTAssertEqual(Set(ids(sorted, "Do Now")), ["a", "b", "c", "d", "e"], "\(key)")
            XCTAssertEqual(Set(ids(sorted, "Errands")), ["f", "g"], "\(key)")
            for section in sorted.sections {
                XCTAssertTrue(section.items.allSatisfy { $0.sectionName == section.name }, "\(key)")
            }
        }
    }

    /// The standing lead item is never sorted: it sits above every heading, and the
    /// bridge refuses to move it at all.
    func testTheLeadBlockIsNeverSorted() {
        var snap = messy()
        snap.leadItems = [
            Fixt.item("lead2", lead: "Second standing", section: "", project: .tag1),
            Fixt.item("lead1", lead: "First standing", section: "", added: "2020-01-01"),
        ]
        for key in TodaySortKey.allCases {
            XCTAssertEqual(TodaySemantics.sortedForDisplay(snap, by: key).leadItems.map(\.id),
                           ["lead2", "lead1"], "\(key)")
        }
    }

    // MARK: - Moves under a lens

    /// `up` and `down` are withheld while a lens is on: they swap the item with its FILE
    /// neighbour, which under `by project` may be three rows away or on the other side of
    /// the section, so the row would move somewhere the user did not point at. The two
    /// absolute ops mean the same thing under every lens and stay.
    func testTheRelativeMovesAreWithheldWhileALensIsOn() {
        let snap = messy()
        let middle = snap.sections[0].items[2]
        XCTAssertEqual(TodaySemantics.availableMoves(for: middle, in: snap, sortedBy: .fileOrder),
                       TodaySemantics.availableMoves(for: middle, in: snap))
        let underLens = TodaySemantics.availableMoves(for: middle, in: snap, sortedBy: .project)
        XCTAssertFalse(underLens.contains(.up))
        XCTAssertFalse(underLens.contains(.down))
        XCTAssertTrue(underLens.contains(.topOfSection))
        XCTAssertTrue(underLens.contains(.toDoNow))
    }

    // MARK: - Focus

    /// **The mapping.** Focus is spelled in terms of the bridge's existing ops; a typo
    /// here would send a `400` and the button would silently do nothing.
    func testFocusMapsOntoTheTwoAbsoluteMoveOps() {
        XCTAssertEqual(TodayFocus.doNow.moveOp, .toDoNow)
        XCTAssertEqual(TodayFocus.topOfSection.moveOp, .topOfSection)
        XCTAssertEqual(Set(TodayFocus.allCases.map(\.moveOp)), [.toDoNow, .topOfSection])
        XCTAssertFalse(TodayFocus.allCases.map(\.moveOp).contains(.up))
        XCTAssertFalse(TodayFocus.allCases.map(\.moveOp).contains(.down))
        // The one that can cross a section, and therefore change the item's id.
        XCTAssertTrue(TodayFocus.doNow.moveOp.crossesSections)
        XCTAssertFalse(TodayFocus.topOfSection.moveOp.crossesSections)
    }

    /// Focus is offered only where the underlying move would do something — the same
    /// availability rules, so no button is offered that the bridge would refuse or
    /// no-op.
    func testFocusIsOfferedOnlyWhereTheMoveWouldDoSomething() {
        let snap = messy()
        let first = snap.sections[0].items[0]
        // Already at the top of Do Now: neither focus applies.
        XCTAssertEqual(TodaySemantics.availableFocus(for: first, in: snap), [])
        // Further down the same section: both do.
        XCTAssertEqual(TodaySemantics.availableFocus(for: snap.sections[0].items[3], in: snap),
                       [.doNow, .topOfSection])
        // Top of ANOTHER section: only "move to Do Now" is left.
        XCTAssertEqual(TodaySemantics.availableFocus(for: snap.sections[1].items[0], in: snap),
                       [.doNow])
        // The standing lead item is structurally immovable.
        var withLead = snap
        withLead.leadItems = [Fixt.item("lead", lead: "Standing", section: "")]
        XCTAssertEqual(TodaySemantics.availableFocus(for: withLead.leadItems[0], in: withLead), [])
    }

    /// A lens does not change which focus actions apply: both are absolute positions.
    func testFocusAvailabilityIsUnaffectedByTheLens() {
        let snap = messy()
        let item = snap.sections[0].items[3]
        let expected = TodaySemantics.availableFocus(for: item, in: snap)
        let model = TodayDashboardModel(makeClient: { FakeStatic(snapshot: snap) })
        for key in TodaySortKey.allCases {
            model.sortKey = key
            XCTAssertEqual(TodaySemantics.availableFocus(for: item, in: snap), expected, "\(key)")
        }
    }

    // MARK: - Through the model

    /// The model draws the LENS and reasons about the FILE. Both at once is the pairing
    /// a shell would get wrong if it had to make it itself.
    func testTheModelDrawsSortedAndJudgesMovesAgainstFileOrder() async {
        let snap = messy()
        let model = TodayDashboardModel(makeClient: { FakeStatic(snapshot: snap) })
        await model.load()

        XCTAssertEqual(model.sortKey, .fileOrder, "the day opens as the file has it")
        XCTAssertEqual(model.displaySnapshot?.sections[0].items.map(\.id),
                       ["a", "b", "c", "d", "e"])

        model.sortKey = .project
        XCTAssertEqual(model.displaySnapshot?.sections[0].items.map(\.id),
                       ["b", "d", "c", "a", "e"], "the lens reorders what is drawn")
        XCTAssertEqual(model.snapshot?.sections[0].items.map(\.id),
                       ["a", "b", "c", "d", "e"],
                       "and the model's own document stays in file order")
        XCTAssertEqual(model.badgeCount, TodaySemantics.doNowOpenCount(snap),
                       "a lens cannot change the badge")

        let item = try! XCTUnwrap(model.snapshot?.sections[0].items[3])
        XCTAssertFalse(model.availableMoves(for: item).contains(.up))
        XCTAssertEqual(model.availableFocus(for: item), [.doNow, .topOfSection])
    }

    /// **Focus emits the move op**, through the same ETagged, optimistic path as every
    /// other move — which is the whole reason it is spelled as one.
    func testFocusSendsTheMappedMoveOpWithTheCurrentEtag() async {
        for focus in TodayFocus.allCases {
            let client = TodayDashboardModelTests.FakeClient()
            client.fetches = [.snapshot(Fixt.snapshot(etag: "\"tag-1\""))]
            client.moves = [.snapshot(Fixt.snapshotAfterGlazeMovedToDoNow())]
            let model = TodayDashboardModel(makeClient: { client })
            await model.load()

            await model.focus(id: Fixt.glazeInErrands, focus)

            XCTAssertEqual(client.moveCount, 1, "\(focus)")
            XCTAssertEqual(client.lastMove?.id, Fixt.glazeInErrands, "\(focus)")
            XCTAssertEqual(client.lastMove?.op, focus.moveOp, "\(focus)")
            XCTAssertEqual(client.lastIfMatch, "\"tag-1\"", "\(focus)")
        }
    }

    /// And a focus refused while the day is read-only is refused the same way a move is:
    /// nothing sent, nothing queued, and the screen says so.
    func testFocusIsRefusedWhileTheDayIsReadOnly() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        let model = TodayDashboardModel(makeClient: { client })
        await model.load()
        model.isNetworkUnreachable = true

        await model.focus(id: Fixt.glazeInErrands, .doNow)

        XCTAssertEqual(client.moveCount, 0)
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
        XCTAssertTrue(model.overlay.moves.isEmpty, "nothing is queued for later")
    }
}

/// A `TodayProviding` that answers one fixed day and refuses to be surprised. The
/// scriptable fake lives in `TodayDashboardModelTests`; this is for the cases that only
/// need a loaded model.
private struct FakeStatic: TodayProviding {
    let snapshot: TodaySnapshot

    func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult { .snapshot(snapshot) }
    func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                   day: String?, ifMatch: String) async throws -> TodayMutationResult { .snapshot(snapshot) }
    func moveItem(id: String, op: TodayMoveOp, at: Date,
                  day: String?, ifMatch: String) async throws -> TodayMutationResult { .snapshot(snapshot) }
    func postpone(id: String, deferred: Bool, at: Date,
                  day: String?, ifMatch: String) async throws -> TodayMutationResult { .snapshot(snapshot) }
    func glance(id: String, at: Date,
                ifMatch: String) async throws -> TodayMutationResult { .snapshot(snapshot) }
}
