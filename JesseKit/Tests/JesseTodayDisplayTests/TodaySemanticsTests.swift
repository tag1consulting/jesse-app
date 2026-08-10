import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The pure layer: the optimistic overlay, the counts the tab badge and the section
// headers read, the re-key that survives a cross-section move, and the row
// presentation helpers. No network, no clock, no view.

final class TodaySemanticsTests: XCTestCase {

    // MARK: - Counts

    func testCountsAreRecomputedFromTheItemsActuallyPresent() {
        let counts = TodaySemantics.counts(Fixt.snapshot())
        XCTAssertEqual(counts.done, 1, "only the clamps are checked")
        XCTAssertEqual(counts.open, 5)
        XCTAssertEqual(counts.reportsUnseen, 2)
    }

    func testOpenCountsPerSection() {
        let snap = Fixt.snapshot()
        XCTAssertEqual(TodaySemantics.openCounts(snap),
                       ["Do Now": 3, "Errands": 1, "Health": 0])
    }

    /// **The tab badge.** Do Now plus the standing lead item — NOT the whole
    /// document. Errands, Done Today, the aging list and every briefing section carry
    /// task lines, and a badge counting those would show a number nobody can act on
    /// and would never reach zero.
    func testBadgeCountsDoNowPlusTheStandingLeadItemOnly() {
        let snap = Fixt.snapshot()
        XCTAssertEqual(TodaySemantics.doNowOpenCount(snap), 4,
                       "three open in Do Now, plus the open standing item")
        XCTAssertNotEqual(TodaySemantics.doNowOpenCount(snap), snap.counts.open,
                          "the badge is deliberately narrower than the document total")
    }

    func testBadgeMatchesADoNowHeadingWithASuffix() {
        var snap = Fixt.snapshot()
        snap.sections[0].name = "Do Now (today)"
        snap.sections[0].items = snap.sections[0].items.map {
            var it = $0
            it.sectionName = "Do Now (today)"
            return it
        }
        XCTAssertEqual(TodaySemantics.doNowOpenCount(snap), 4,
                       "the bridge matches the section by prefix, so this must too")
    }

    func testBadgeIsZeroWithNoDoNowSection() {
        var snap = Fixt.snapshot()
        snap.sections.removeAll { $0.name == "Do Now" }
        snap.leadItems = []
        XCTAssertEqual(TodaySemantics.doNowOpenCount(snap), 0)
    }

    // MARK: - The overlay

    func testAnEmptyOverlayIsTheIdentity() {
        let snap = Fixt.snapshot()
        XCTAssertEqual(TodaySemantics.display(snap, applying: TodayOptimism()), snap)
    }

    func testAnOptimisticCheckFlipsTheRowAndTheCounts() {
        let snap = Fixt.snapshot()
        let out = TodaySemantics.display(snap, applying:
            TodayOptimism(checks: [Fixt.thermocouple: true]))
        XCTAssertEqual(out.item(id: Fixt.thermocouple)?.checked, true)
        XCTAssertEqual(out.counts.done, 2, "the counts follow the overlay, not the server")
        XCTAssertEqual(out.counts.open, 4)
        XCTAssertEqual(TodaySemantics.doNowOpenCount(out), 3, "and so does the badge")
    }

    /// An optimistic UNCHECK must also drop the sub-line the server still reports, or
    /// the row reads "completed at 09:30" next to an empty box.
    func testAnOptimisticUncheckAlsoDropsTheServersCompletionSubLine() throws {
        var snap = Fixt.snapshot()
        snap.sections[1].items[1].appCompleted =
            TodayAppCompleted(at: "2026-03-03 08:12", evidence: "on the phone")
        let out = TodaySemantics.display(snap, applying: TodayOptimism(checks: [Fixt.clamps: false]))
        let row = try XCTUnwrap(out.item(id: Fixt.clamps))
        XCTAssertFalse(row.checked)
        XCTAssertNil(row.appCompleted)
    }

    func testPendingEvidenceShowsBeforeTheServerEchoesIt() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(checks: [Fixt.ada: true], evidence: [Fixt.ada: "sent the date"]))
        XCTAssertEqual(out.item(id: Fixt.ada)?.appCompleted?.evidence, "sent the date")
    }

    func testARemovedItemLeavesTheDocument() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(removed: [Fixt.ada]))
        XCTAssertNil(out.item(id: Fixt.ada))
        XCTAssertEqual(out.counts.open, 4)
    }

    func testALocalGlanceClearsTheUnseenDotAndTheCount() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(seen: [Fixt.runDay]))
        XCTAssertEqual(out.allReports.first { $0.id == Fixt.runDay }?.seen, true)
        XCTAssertEqual(TodaySemantics.unseenReportCount(out), 1)
    }

    // MARK: - Optimistic moves

    func testOptimisticUpAndDownSwapWithinTheSection() {
        let snap = Fixt.snapshot()
        let up = TodaySemantics.display(snap, applying: TodayOptimism(moves: [Fixt.ada: .up]))
        XCTAssertEqual(up.sections[0].items.map(\.id),
                       [Fixt.ada, Fixt.thermocouple, Fixt.plain])
        let down = TodaySemantics.display(snap, applying: TodayOptimism(moves: [Fixt.ada: .down]))
        XCTAssertEqual(down.sections[0].items.map(\.id),
                       [Fixt.thermocouple, Fixt.plain, Fixt.ada])
    }

    func testOptimisticUpOnTheFirstItemAndDownOnTheLastAreNoOps() {
        let snap = Fixt.snapshot()
        XCTAssertEqual(TodaySemantics.display(snap, applying:
            TodayOptimism(moves: [Fixt.thermocouple: .up])).sections[0].items.map(\.id),
                       snap.sections[0].items.map(\.id))
        XCTAssertEqual(TodaySemantics.display(snap, applying:
            TodayOptimism(moves: [Fixt.plain: .down])).sections[0].items.map(\.id),
                       snap.sections[0].items.map(\.id))
    }

    func testOptimisticTopOfSectionLiftsTheRow() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(moves: [Fixt.plain: .topOfSection]))
        XCTAssertEqual(out.sections[0].items.map(\.id),
                       [Fixt.plain, Fixt.thermocouple, Fixt.ada])
    }

    /// The optimistic cross-section move: exactly one copy of the row, in the
    /// destination, under the id the client still knows it by. Rendering it in both
    /// sections — or leaving a stub behind — is the ghost this whole design is about.
    func testOptimisticToDoNowMovesTheRowExactlyOnceAndKeepsTheOldIdForNow() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(moves: [Fixt.glazeInErrands: .toDoNow]))
        XCTAssertEqual(out.sections[0].items.first?.id, Fixt.glazeInErrands)
        XCTAssertFalse(out.sections[1].items.contains { $0.id == Fixt.glazeInErrands },
                       "and it left Errands — no duplicate")
        XCTAssertEqual(out.allItems.filter { $0.lead == Fixt.glazeLead }.count, 1)
        XCTAssertEqual(out.item(id: Fixt.glazeInErrands)?.sectionName, "Do Now",
                       "the section name follows the row, so a re-key matches on the right pair")
    }

    /// The other cross-section op, and the one that names where it is going. Same
    /// landing (the top) and same id rule (unchanged until the server answers) as
    /// `to_do_now`, because they are one splice with two ways of choosing a section.
    func testOptimisticToSectionLandsTheRowAtTheTopOfTheNamedSection() {
        let out = TodaySemantics.display(Fixt.snapshot(), applying:
            TodayOptimism(moves: [Fixt.ada: .toSection("Errands")]))
        XCTAssertEqual(out.sections[1].items.first?.id, Fixt.ada,
                       "a demotion to the bottom of a long section is a demotion to "
                       + "invisibility")
        XCTAssertFalse(out.sections[0].items.contains { $0.id == Fixt.ada },
                       "and it left Do Now — no duplicate")
        XCTAssertEqual(out.item(id: Fixt.ada)?.sectionName, "Errands",
                       "the section name follows the row, so a re-key matches on the right pair")
    }

    /// The destination is matched EXACTLY, as the bridge matches it. A day file
    /// carries both a `Do Now` and a `Do Now (carried…)`, and a prefix match would
    /// land the row optimistically in one and really in the other.
    func testOptimisticToSectionMatchesTheHeadingExactly() {
        let snap = Fixt.snapshot()
        let out = TodaySemantics.display(snap, applying:
            TodayOptimism(moves: [Fixt.ada: .toSection("Do No")]))
        XCTAssertEqual(out.sections.map { $0.items.map(\.id) },
                       snap.sections.map { $0.items.map(\.id) },
                       "a name that is only a prefix moves nothing")
    }

    /// The op crosses a boundary, so the id changes and the client's state has to
    /// follow the server's answer — the same re-key `to_do_now` already relies on,
    /// reached through the identity that survives a move rather than through the id.
    func testAToSectionMoveIsRekeyedFromTheServersSnapshot() throws {
        let before = Fixt.snapshot()
        let item = try XCTUnwrap(before.item(id: Fixt.glazeInErrands))
        let after = Fixt.snapshotAfterGlazeMovedToDoNow()
        let known = Set(before.allItems.map(\.id))
        XCTAssertEqual(TodaySemantics.rekeyed(item, in: after, excluding: known),
                       Fixt.glazeInDoNow)
    }

    func testAMoveOfALeadItemIsNeverAppliedOptimistically() {
        let snap = Fixt.snapshot()
        for op in [TodayMoveOp.up, .down, .topOfSection, .toDoNow, .toSection("Errands")] {
            let out = TodaySemantics.display(snap, applying:
                TodayOptimism(moves: [Fixt.standing: op]))
            XCTAssertEqual(out.leadItems.map(\.id), [Fixt.standing],
                           "the lead block is structurally immovable; \(op) must not fake it")
            XCTAssertEqual(out.sections[0].items.count, 3)
        }
    }

    // MARK: - Re-keying

    /// The core of the contract: after a cross-section move the id is the one thing
    /// that did NOT survive, so the lookup matches on `(lead, addedDate)` — the pair
    /// a byte-splicing move cannot change.
    func testRekeyFindsTheItemUnderItsNewIdAfterACrossSectionMove() throws {
        let before = Fixt.snapshot()
        let after = Fixt.snapshotAfterGlazeMovedToDoNow()
        let moved = try XCTUnwrap(before.item(id: Fixt.glazeInErrands))
        let known = Set(before.allItems.map(\.id))

        XCTAssertEqual(TodaySemantics.rekeyed(moved, in: after, excluding: known),
                       Fixt.glazeInDoNow)
    }

    /// An in-section move changes nothing about identity, so the re-key is the
    /// identity function. The model runs it for every op anyway — a rule applied
    /// conditionally breaks the first time the condition changes.
    func testRekeyIsAnIdentityWhenTheIdDidNotChange() throws {
        let snap = Fixt.snapshot()
        let item = try XCTUnwrap(snap.item(id: Fixt.ada))
        XCTAssertEqual(TodaySemantics.rekeyed(item, in: snap,
                                              excluding: Set(snap.allItems.map(\.id))),
                       Fixt.ada)
    }

    /// Two items sharing a lead AND an Added date are disambiguated by the bridge
    /// with `-2`; preferring an id the client has not seen is what stops the re-key
    /// landing on the sibling that was already sitting in the destination.
    func testRekeyPrefersAnIdTheClientHasNotSeenBefore() throws {
        let before = Fixt.snapshot()
        var after = Fixt.snapshotAfterGlazeMovedToDoNow()
        // A pre-existing twin in the destination, worded identically.
        after.sections[0].items.append(
            Fixt.item("aaaaaaaaaaaa", lead: Fixt.glazeLead, section: "Do Now",
                      added: Fixt.glazeAdded))
        var known = Set(before.allItems.map(\.id))
        known.insert("aaaaaaaaaaaa")

        let moved = try XCTUnwrap(before.item(id: Fixt.glazeInErrands))
        XCTAssertEqual(TodaySemantics.rekeyed(moved, in: after, excluding: known),
                       Fixt.glazeInDoNow,
                       "the sibling was already known; the fresh id is the moved row")
    }

    func testRekeyReturnsNilWhenTheItemIsGoneEntirely() throws {
        let before = Fixt.snapshot()
        var after = Fixt.snapshot()
        after.sections[1].items.removeAll { $0.id == Fixt.glazeInErrands }
        let moved = try XCTUnwrap(before.item(id: Fixt.glazeInErrands))
        XCTAssertNil(TodaySemantics.rekeyed(moved, in: after,
                                            excluding: Set(before.allItems.map(\.id))))
    }

    // MARK: - The overlay's own re-key

    func testOverlayRekeyCarriesEveryFieldAndLeavesNothingBehind() {
        var overlay = TodayOptimism(checks: ["old": true], evidence: ["old": "note"],
                                    moves: ["old": .toDoNow], removed: ["old"], seen: ["old"])
        overlay.rekey(from: "old", to: "new")
        XCTAssertEqual(overlay.checks, ["new": true])
        XCTAssertEqual(overlay.evidence, ["new": "note"])
        XCTAssertEqual(overlay.moves, ["new": .toDoNow])
        XCTAssertEqual(overlay.removed, ["new"])
        XCTAssertEqual(overlay.seen, ["new"])
        XCTAssertNil(overlay.checks["old"], "nothing may be left under the old id")
    }

    func testOverlayRekeyToItselfIsANoOp() {
        var overlay = TodayOptimism(checks: ["x": true])
        overlay.rekey(from: "x", to: "x")
        XCTAssertEqual(overlay.checks, ["x": true])
    }

    func testOverlaySettleForgetsOneIdEntirely() {
        var overlay = TodayOptimism(checks: ["x": true], evidence: ["x": "n"], moves: ["x": .up])
        overlay.settle("x")
        XCTAssertTrue(overlay.isEmpty)
    }

    // MARK: - Move availability

    func testAvailableMovesMirrorTheBridgesNoOpRules() throws {
        let snap = Fixt.snapshot()
        /// The REORDERINGS only — the destination submenu is asserted separately
        /// below, and it is offered for every row alike, so repeating it in each of
        /// these four expectations would say nothing about the no-op rules.
        func moves(_ id: String) throws -> [TodayMoveOp] {
            TodaySemantics.availableMoves(for: try XCTUnwrap(snap.item(id: id)), in: snap)
                .filter { $0.destinationSection == nil }
        }
        XCTAssertEqual(try moves(Fixt.thermocouple), [.down],
                       "first in Do Now: no up, no top, no to-Do-Now")
        XCTAssertEqual(try moves(Fixt.ada), [.up, .down, .topOfSection, .toDoNow])
        XCTAssertEqual(try moves(Fixt.plain), [.up, .topOfSection, .toDoNow],
                       "last in Do Now: no down")
        XCTAssertEqual(try moves(Fixt.glazeInErrands), [.down, .toDoNow],
                       "first in Errands, and Do Now is elsewhere")
    }

    /// **Every section but the item's own**, in file order.
    ///
    /// Not filtered down to "sensible" destinations, because there is no such
    /// judgement to make from here: which section a piece of work belongs in is the
    /// thing only the user knows. The item's own section is left out because moving
    /// to where you already are writes nothing (the bridge treats it as a no-op) and
    /// reads as a broken button.
    func testTheDestinationSubmenuOffersEverySectionButTheItemsOwn() throws {
        let snap = Fixt.snapshot()
        func destinations(_ id: String) throws -> [String] {
            TodaySemantics.availableMoves(for: try XCTUnwrap(snap.item(id: id)), in: snap)
                .compactMap(\.destinationSection)
        }
        XCTAssertEqual(try destinations(Fixt.ada), ["Errands", "Health"])
        XCTAssertEqual(try destinations(Fixt.glazeInErrands), ["Do Now", "Health"])
        // And the full names, verbatim: a menu that shortened them would show two
        // entries reading "Do Now" on a day file that carries both headings.
        XCTAssertEqual(
            try destinations(Fixt.ada).map { TodaySemantics.label(for: .toSection($0)) },
            ["Errands", "Health"])
    }

    /// The standing lead item gets NO menu rather than four buttons that each answer
    /// `409`.
    func testTheStandingLeadItemHasNoMovesAtAll() {
        let snap = Fixt.snapshot()
        XCTAssertEqual(TodaySemantics.availableMoves(for: snap.leadItems[0], in: snap), [])
    }

    func testToDoNowIsNotOfferedWhenThereIsNoDoNowSection() throws {
        var snap = Fixt.snapshot()
        snap.sections.removeAll { $0.name == "Do Now" }
        let item = try XCTUnwrap(snap.item(id: Fixt.glazeInErrands))
        XCTAssertFalse(TodaySemantics.availableMoves(for: item, in: snap).contains(.toDoNow))
    }

    // MARK: - Row presentation

    func testLeadAndDetailSplitTheFirstLineAtTheBoldSegment() {
        let item = TodayItem(
            id: "x", lead: "Order the replacement thermocouple.",
            text: "* [ ] **Order the replacement thermocouple.** Part number TC-4417, two of them. (Added 2026-03-01)",
            sectionName: "Do Now")
        let (lead, detail) = TodaySemantics.leadAndDetail(item)
        XCTAssertEqual(lead, "Order the replacement thermocouple.")
        XCTAssertEqual(detail, "Part number TC-4417, two of them.",
                       "the trailer is caption material, not sentence material")
    }

    func testLeadAndDetailLeaveNoDetailWhenTheLineIsOnlyItsLead() {
        let item = TodayItem(id: "x", lead: "Reply to Ada.",
                             text: "* [ ] **Reply to Ada.**", sectionName: "Do Now")
        XCTAssertEqual(TodaySemantics.leadAndDetail(item).detail, "")
    }

    func testLeadAndDetailStripMarkdownFromTheDetail() {
        let item = TodayItem(
            id: "x", lead: "Reply to Ada.",
            text: "* [ ] **Reply to Ada.** See [[notes/Dashboard/Workshop|the board]] and `TC-4417`.",
            sectionName: "Do Now")
        XCTAssertEqual(TodaySemantics.leadAndDetail(item).detail,
                       "See the board and TC-4417.")
    }

    func testContinuationsExcludeTheAppsOwnSubLine() {
        let item = TodayItem(
            id: "x", lead: "Collect the glaze order.",
            text: """
            * [x] **Collect the glaze order.**
            \t*(app-completed 2026-03-03 08:12: on the phone)*
            \tPicked up first thing.
            """,
            sectionName: "Errands")
        XCTAssertEqual(TodaySemantics.continuationLines(item), ["Picked up first thing."],
                       "the sub-line is rendered as evidence, not as body text")
    }

    func testDateCaption() {
        XCTAssertEqual(TodaySemantics.dateCaption(
            Fixt.item("x", lead: "l", section: "s", added: "2026-03-01", updated: "2026-03-03")),
                       "Added 2026-03-01 · updated 2026-03-03")
        XCTAssertEqual(TodaySemantics.dateCaption(
            Fixt.item("x", lead: "l", section: "s", added: "2026-03-01")),
                       "Added 2026-03-01")
        XCTAssertNil(TodaySemantics.dateCaption(Fixt.item("x", lead: "l", section: "s")))
    }

    func testEvidenceTextPrefersThePendingNote() {
        let item = Fixt.item("x", lead: "l", section: "s",
                             appCompleted: TodayAppCompleted(at: "t", evidence: "from the file"))
        XCTAssertEqual(TodaySemantics.evidenceText(item, pending: "just typed"), "just typed")
        XCTAssertEqual(TodaySemantics.evidenceText(item, pending: nil), "from the file")
        XCTAssertNil(TodaySemantics.evidenceText(Fixt.item("x", lead: "l", section: "s"),
                                                 pending: nil))
    }

    /// Underscores survive stripping, for the bridge's own reason: `snake_case`
    /// identifiers are all over this vault and `_emphasis_` is not a spelling it uses.
    func testStrippedMarkdownKeepsSnakeCaseIdentifiersIntact() {
        XCTAssertEqual(TodaySemantics.strippedMarkdown("check **today_id** in `today.rs`"),
                       "check today_id in today.rs")
        XCTAssertEqual(TodaySemantics.strippedMarkdown("[the text](https://example.invalid/x)"),
                       "the text")
        XCTAssertEqual(TodaySemantics.strippedMarkdown("~~gone~~ and *emph*"), "gone and emph")
    }

    func testTaskBodyStripsEitherMarkerAndEitherBoxSpelling() {
        XCTAssertEqual(TodaySemantics.taskBody("* [ ] a thing"), "a thing")
        XCTAssertEqual(TodaySemantics.taskBody("- [x] a thing"), "a thing")
        XCTAssertEqual(TodaySemantics.taskBody("* [X] a thing"), "a thing")
        XCTAssertEqual(TodaySemantics.taskBody("not a task"), "not a task")
        XCTAssertEqual(TodaySemantics.taskBody("- [] malformed"), "- [] malformed")
    }

    func testStripTrailersOnlyRemovesBookkeeping() {
        XCTAssertEqual(TodaySemantics.stripTrailers("Do the thing (Added 2026-03-01)"),
                       "Do the thing")
        XCTAssertEqual(TodaySemantics.stripTrailers("Do it (Added 2026-03-01) (updated 2026-03-03)"),
                       "Do it")
        XCTAssertEqual(TodaySemantics.stripTrailers("Do the thing (the important one)"),
                       "Do the thing (the important one)",
                       "a real parenthetical is content, not bookkeeping")
    }

    func testReportSymbolsCoverEveryKindAndDegradeGracefully() {
        XCTAssertEqual(TodaySemantics.reportSymbol(kind: "currency"),
                       "chart.line.uptrend.xyaxis")
        XCTAssertEqual(TodaySemantics.reportSymbol(kind: "health"), "heart")
        XCTAssertEqual(TodaySemantics.reportSymbol(kind: "something the bridge added later"),
                       "doc.text", "an unknown kind still renders")
    }
}
