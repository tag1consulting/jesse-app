import XCTest
import JesseNetworking
@testable import JesseTodayDisplay

// **The badge-only view**: the day narrowed to exactly the items the red tab badge
// counts.
//
// The assertion that matters most is the first one, and it is really a structural
// claim rather than a behavioural one: the filtered list and the badge count come from
// the same function, so they cannot disagree. Every fixture below is another shape of
// day where that has to hold: no badge items at all, lead items only, Do Now only,
// both, a day where every candidate is postponed, and a day carrying two sections
// whose names both begin `Do Now`.
//
// The rest is about the two things a filtered list must never do: delete a row under
// the finger that acted on it, and answer "nothing left" by quietly showing the full
// day again.
@MainActor
final class TodayBadgeFilterTests: XCTestCase {

    // MARK: - Days

    /// A day with no lead items and no `Do Now` section: nothing can count.
    private func zeroBadgeDay() -> TodaySnapshot {
        TodaySnapshot(
            title: "Today: Thursday, March 5, 2026",
            date: "2026-03-05",
            leadItems: [],
            sections: [
                TodaySection(name: "Errands", kind: "tasks", items: [
                    Fixt.item("z1", lead: "Return the borrowed clamps.", section: "Errands"),
                    Fixt.item("z2", lead: "Collect the glaze order.", section: "Errands"),
                ]),
            ],
            counts: TodayCounts(open: 2, done: 0, reportsUnseen: 0),
            etag: "\"tag-z\"")
    }

    /// Only the standing item counts: there is no `Do Now` section at all.
    private func leadOnlyDay() -> TodaySnapshot {
        var day = zeroBadgeDay()
        day.leadItems = [Fixt.item("L1", lead: "TOP PRIORITY: Finish the kiln rebuild",
                                   section: "", added: "2026-01-04")]
        return day
    }

    /// Only `Do Now` counts: nothing stands above the headings.
    private func doNowOnlyDay() -> TodaySnapshot {
        var day = Fixt.snapshot()
        day.leadItems = []
        return day
    }

    /// Every candidate set aside for today. This is the day that most looks like a bug
    /// if the count and the list are computed separately: the list would still be full
    /// while the badge read zero.
    private func allPostponedDay() -> TodaySnapshot {
        var day = Fixt.snapshot()
        for i in day.leadItems.indices {
            day.leadItems[i].deferred = true
            day.leadItems[i].deferredMs = 1_772_000_000_000
        }
        for i in day.sections[0].items.indices {
            day.sections[0].items[i].deferred = true
            day.sections[0].items[i].deferredMs = 1_772_000_000_000
        }
        return day
    }

    /// Two sections whose names both begin `Do Now`. The badge counts the FIRST, so the
    /// filtered view shows the first, and the carried one stays out of both.
    private func twoDoNowSectionsDay() -> TodaySnapshot {
        var day = Fixt.snapshot()
        day.sections.insert(
            TodaySection(name: "Do Now (carried, owed replies and decisions)",
                         kind: "tasks", items: [
                             Fixt.item("c1", lead: "Answer the kiln supplier.",
                                       section: "Do Now (carried, owed replies and decisions)"),
                             Fixt.item("c2", lead: "Decide on the new shelf order.",
                                       section: "Do Now (carried, owed replies and decisions)"),
                         ]),
            at: 1)
        return day
    }

    /// The same day with one item ticked, as the SERVER would send it back.
    private func day(_ snapshot: TodaySnapshot, checking id: String) -> TodaySnapshot {
        var out = snapshot
        for s in out.sections.indices {
            for i in out.sections[s].items.indices where out.sections[s].items[i].id == id {
                out.sections[s].items[i].checked = true
            }
        }
        out.etag = "\"tag-checked\""
        return out
    }

    /// The day after the bridge moved the thermocouple item out of Do Now and into
    /// Errands. It crosses a section boundary, so it comes back under a DIFFERENT id,
    /// which is the same identity contract `to_do_now` has, in the other direction.
    private func dayAfterThermocoupleMovedToErrands() -> TodaySnapshot {
        var out = Fixt.snapshot(etag: "\"tag-moved\"")
        out.sections[0].items.removeAll { $0.id == Fixt.thermocouple }
        out.sections[1].items.insert(
            Fixt.item("6d1e3c9a0099", lead: "Order the replacement thermocouple.",
                      section: "Errands", added: "2026-03-01", updated: "2026-03-03"),
            at: 0)
        return out
    }

    private func loaded(_ snapshot: TodaySnapshot,
                        _ client: TodayDashboardModelTests.FakeClient? = nil) async
    -> (TodayDashboardModel, TodayDashboardModelTests.FakeClient) {
        let fake = client ?? TodayDashboardModelTests.FakeClient()
        if fake.fetches.isEmpty { fake.fetches = [.snapshot(snapshot)] }
        let model = TodayDashboardModel(makeClient: { fake })
        await model.load()
        return (model, fake)
    }

    // MARK: - One membership rule

    /// **The claim the whole feature rests on.** Over every shape of day: the rows the
    /// filter shows ARE the badge set, in the same order, and there are exactly
    /// `doNowOpenCount` of them.
    func testTheFilteredListIsTheBadgeSetOnEveryShapeOfDay() async {
        let days: [(String, TodaySnapshot)] = [
            ("no badge items", zeroBadgeDay()),
            ("lead items only", leadOnlyDay()),
            ("Do Now only", doNowOnlyDay()),
            ("both", Fixt.snapshot()),
            ("everything postponed", allPostponedDay()),
            ("two Do Now sections", twoDoNowSectionsDay()),
        ]
        for (name, day) in days {
            let (model, _) = await loaded(day)
            model.isBadgeFilterOn = true

            let shown = model.displaySnapshot?.allItems.map(\.id) ?? []
            XCTAssertEqual(shown, TodaySemantics.badgeItems(day).map(\.id),
                           "\(name): the list is the badge set, in the day's own order")
            XCTAssertEqual(shown.count, TodaySemantics.doNowOpenCount(day),
                           "\(name): and there are exactly as many as the badge says")
            XCTAssertEqual(shown.count, model.badgeCount, "\(name)")
        }
    }

    /// The second `Do Now…` section contributes nothing to the badge, so it contributes
    /// nothing to the view either, by the same first-match rule the bridge, the
    /// optimistic move and the count all use.
    func testOnlyTheFirstDoNowSectionSurvives() async {
        let day = twoDoNowSectionsDay()
        let (model, _) = await loaded(day)
        model.isBadgeFilterOn = true

        XCTAssertEqual(model.displaySnapshot?.sections.map(\.name), ["Do Now"])
        XCTAssertFalse(model.displaySnapshot?.allItems.contains { $0.id == "c1" } ?? true,
                       "a carried Do Now item is not in the badge, so it is not in the view")
    }

    /// Everything that is not a badge item goes: the checked row, the other sections,
    /// and the briefing glanceables. The lead block stays a block of its own, which is
    /// what keeps a standing item distinguishable from Do Now work.
    func testEverythingElseIsSuppressed() async {
        let (model, _) = await loaded(Fixt.snapshot())
        model.isBadgeFilterOn = true
        let filtered = try? XCTUnwrap(model.displaySnapshot)

        XCTAssertEqual(filtered?.leadItems.map(\.id), [Fixt.standing])
        XCTAssertEqual(filtered?.sections.count, 1)
        XCTAssertTrue(filtered?.allReports.isEmpty ?? false, "no glanceables in a to-do list")
        XCTAssertFalse(filtered?.allItems.contains { $0.id == Fixt.clamps } ?? true,
                       "a checked Errands row is not what the badge counts")
        XCTAssertEqual(filtered?.counts.open, 4, "the counts describe the rows on screen")
    }

    /// Turning the filter off gives the day back whole. It is a lens, and a lens the
    /// user cannot undo is a document they have lost.
    func testTurningItOffRestoresTheWholeDay() async {
        let day = Fixt.snapshot()
        let (model, _) = await loaded(day)
        model.isBadgeFilterOn = true
        model.isBadgeFilterOn = false

        XCTAssertEqual(model.displaySnapshot?.allItems.map(\.id), day.allItems.map(\.id))
        XCTAssertEqual(model.displaySnapshot?.sections.map(\.name), day.sections.map(\.name))
    }

    // MARK: - Nothing is written

    /// **The filter writes nothing.** Not a request, not an ETagged mutation, and not a
    /// byte of the day file: the raw server document, including every item's raw
    /// markdown, is identical after toggling the filter both ways.
    func testTogglingTheFilterWritesNothing() async {
        let (model, client) = await loaded(Fixt.snapshot())
        let before = model.serverSnapshot
        let beforeMarkdown = before?.allItems.map(\.text)
        let fetchesBefore = client.fetchCount

        model.isBadgeFilterOn = true
        model.isBadgeFilterOn = false
        model.isBadgeFilterOn = true

        XCTAssertEqual(model.serverSnapshot, before, "the day is untouched")
        XCTAssertEqual(model.serverSnapshot?.allItems.map(\.text), beforeMarkdown,
                       "including every line of markdown, byte for byte")
        XCTAssertEqual(client.checkCount, 0)
        XCTAssertEqual(client.moveCount, 0)
        XCTAssertEqual(client.postponeCount, 0)
        XCTAssertEqual(client.glanceCount, 0)
        XCTAssertEqual(client.fetchCount, fetchesBefore, "and nothing was even re-read")
    }

    /// A view is a view: the filter works while the day is read-only, and the write
    /// actions inside it refuse exactly as they already refuse.
    func testTheFilterWorksWhileTheDayIsReadOnly() async {
        let (model, client) = await loaded(Fixt.snapshot())
        model.isNetworkUnreachable = true
        model.isBadgeFilterOn = true

        XCTAssertEqual(model.displaySnapshot?.allItems.count, 4, "the view still narrows")

        await model.check(id: Fixt.ada, checked: true)
        XCTAssertEqual(client.checkCount, 0, "and the tap is still refused")
        XCTAssertEqual(model.notice, TodayDashboardModel.readOnlyNotice)
    }

    // MARK: - Rows that leave the badge set

    /// Ticking a row in the filtered view drops the badge AND leaves the row where it
    /// was. A list that deletes rows as you tap them is a list you cannot correct.
    func testCheckingKeepsTheRowUntilAnExplicitRefresh() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot()),
                          .snapshot(day(Fixt.snapshot(), checking: Fixt.ada))]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true
        XCTAssertEqual(model.badgeCount, 4)

        await model.check(id: Fixt.ada, checked: true)

        XCTAssertEqual(model.badgeCount, 3, "the badge drops on the tap")
        let row = model.displaySnapshot?.item(id: Fixt.ada)
        XCTAssertNotNil(row, "and the row stays on screen")
        XCTAssertEqual(row?.checked, true, "rendered as done, exactly as the full day draws it")

        await model.refresh()

        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.ada),
                     "the explicit refresh is what lets it go")
        XCTAssertEqual(model.badgeCount, 3)
    }

    /// Postponing behaves the same way, for the same reason, and it is the case that
    /// matters more: postponing is one flick and easy to aim wrong.
    func testPostponingKeepsTheRowUntilAnExplicitRefresh() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot()),
                          .snapshot(Fixt.snapshotWithPostponed(Fixt.ada))]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true

        await model.postpone(id: Fixt.ada, deferred: true)

        XCTAssertEqual(model.badgeCount, 3, "the badge drops on the flick")
        let row = model.displaySnapshot?.item(id: Fixt.ada)
        XCTAssertNotNil(row, "and the row stays, chipped as postponed")
        XCTAssertEqual(row?.deferred, true)

        await model.refresh()

        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.ada))
    }

    /// Entering the screen is the other moment the held rows go. A row kept from a
    /// viewing an hour ago would be a day that never settles.
    func testEnteringTheViewLetsHeldRowsGo() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot()),
                          .snapshot(day(Fixt.snapshot(), checking: Fixt.ada))]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true
        await model.check(id: Fixt.ada, checked: true)
        await model.load()
        XCTAssertNotNil(model.displaySnapshot?.item(id: Fixt.ada),
                        "an ordinary background load holds the row")

        model.repinBadgeFilter()

        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.ada))
    }

    /// Turning the filter on is a fresh viewing, so it starts from the badge set alone.
    func testTogglingTheFilterStartsAFreshViewing() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.checks = [.snapshot(day(Fixt.snapshot(), checking: Fixt.ada))]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true
        await model.check(id: Fixt.ada, checked: true)
        XCTAssertNotNil(model.displaySnapshot?.item(id: Fixt.ada))

        model.isBadgeFilterOn = false
        model.isBadgeFilterOn = true

        XCTAssertTrue(model.pinnedBadgeIDs.isEmpty)
        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.ada))
    }

    // MARK: - The overlay, inside the filter

    /// The overlay is applied BEFORE the filter, so a not-yet-confirmed tap decides
    /// membership: bringing a postponed row back puts it in the filtered view at once,
    /// without waiting for the round trip.
    func testTheOverlayDecidesMembershipInTheFilteredView() async {
        let (model, _) = await loaded(Fixt.snapshotWithPostponed(Fixt.ada))
        model.isBadgeFilterOn = true
        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.ada), "postponed, so not counted")

        model.overlay.deferrals[Fixt.ada] = false

        XCTAssertEqual(model.badgeCount, 4)
        XCTAssertNotNil(model.displaySnapshot?.item(id: Fixt.ada),
                        "and back in the view on the tap, not on the answer")
    }

    /// The holding of a departed row belongs to the ACTION, not to the overlay. An
    /// overlay entry that arrived some other way, a staged interaction or a second
    /// device's postponement folded in, takes the row out of the view, which is what
    /// the filter is for.
    func testAnUnactedRowThatLeavesTheBadgeSetLeavesTheView() async {
        let (model, _) = await loaded(Fixt.snapshot())
        model.isBadgeFilterOn = true

        model.overlay.checks[Fixt.thermocouple] = true

        XCTAssertEqual(model.badgeCount, 3)
        XCTAssertTrue(model.pinnedBadgeIDs.isEmpty)
        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.thermocouple))
    }

    /// A move INTO Do Now brings the row into the filtered view under the id the server
    /// gave it, and the overlay settles rather than leaving a ghost.
    func testAMoveIntoDoNowLandsInTheFilteredView() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.moves = [.snapshot(Fixt.snapshotAfterGlazeMovedToDoNow())]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true
        XCTAssertNil(model.displaySnapshot?.item(id: Fixt.glazeInErrands),
                     "an Errands row is not in the badge set")

        await model.move(id: Fixt.glazeInErrands, op: .toDoNow)

        XCTAssertNotNil(model.displaySnapshot?.item(id: Fixt.glazeInDoNow),
                        "and now it is, under the id the server answered with")
        XCTAssertTrue(model.overlay.moves.isEmpty, "the overlay settled")
        XCTAssertEqual(model.badgeCount, 5)
    }

    /// **The re-key path.** A held row that crosses a section boundary comes back under
    /// a new id, and the hold follows it. A pin left under the old id would be holding
    /// a row that no longer exists.
    func testAHeldRowIsRekeyedWhenItCrossesASection() async {
        let client = TodayDashboardModelTests.FakeClient()
        client.fetches = [.snapshot(Fixt.snapshot())]
        client.moves = [.snapshot(dayAfterThermocoupleMovedToErrands())]
        let (model, _) = await loaded(Fixt.snapshot(), client)
        model.isBadgeFilterOn = true

        await model.move(id: Fixt.thermocouple, op: .toSection("Errands"))

        XCTAssertFalse(model.pinnedBadgeIDs.contains(Fixt.thermocouple),
                       "nothing is held under the id the move destroyed")
        XCTAssertTrue(model.pinnedBadgeIDs.contains("6d1e3c9a0099"),
                      "the hold moved to the id the row now has")
        XCTAssertNil(model.displaySnapshot?.item(id: "6d1e3c9a0099"),
                     "and the row leaves the view, because it left Do Now")
        XCTAssertEqual(model.badgeCount, 3)
    }

    // MARK: - Nothing left

    /// The empty state is an answer, and the day is NOT silently unfiltered underneath
    /// it: the rows are still there, the filter is still on, and the screen says so.
    func testTheEmptyStateIsShownRatherThanTheWholeDay() async {
        let day = allPostponedDay()
        let (model, _) = await loaded(day)
        model.isBadgeFilterOn = true

        XCTAssertTrue(model.isBadgeFilterEmpty)
        XCTAssertEqual(model.badgeCount, 0)
        XCTAssertTrue(model.displaySnapshot?.allItems.isEmpty ?? false)
        XCTAssertTrue(model.isBadgeFilterOn, "the filter was not turned off behind the user")
        XCTAssertFalse(model.snapshot?.allItems.isEmpty ?? true,
                       "and the day itself still has every row in it")
    }

    /// The accomplishment reading belongs to the FILTER, not to an empty day. With the
    /// filter off there is nothing to say.
    func testTheEmptyStateIsOnlyForTheFilteredView() async {
        let (model, _) = await loaded(allPostponedDay())
        XCTAssertFalse(model.isBadgeFilterEmpty)

        let (blank, _) = await loaded(TodaySnapshot(missing: true))
        blank.isBadgeFilterOn = true
        XCTAssertFalse(blank.isBadgeFilterEmpty,
                       "a day file that does not exist is not an accomplishment")
    }

    // MARK: - What it says

    /// The three controls share their wording, and the filtered list counts the rows it
    /// is HOLDING separately from the rows that still need action. "4 need action" over
    /// a list whose fourth row is struck through would be the one number on this screen
    /// that lies.
    func testTheWordingCarriesTheCountAndSeparatesHeldRows() {
        XCTAssertEqual(TodayBadgeFilterWording.label(3), "Needs action (3)")
        XCTAssertEqual(TodayBadgeFilterWording.accessibilityLabel(1), "Needs action, 1 item")
        XCTAssertEqual(TodayBadgeFilterWording.accessibilityLabel(3), "Needs action, 3 items")
        XCTAssertEqual(TodayBadgeFilterWording.showing(1), "Showing 1 item that needs action")
        XCTAssertEqual(TodayBadgeFilterWording.showing(3), "Showing 3 items that need action")
        XCTAssertEqual(TodayBadgeFilterWording.showing(3, held: 1),
                       "Showing 3 items that need action, plus 1 you just handled")
        XCTAssertEqual(TodayBadgeFilterWording.showing(3, held: 2),
                       "Showing 3 items that need action, plus 2 you just handled")
    }

    // MARK: - Across a relaunch

    /// The filter is a per-device preference, so it survives a relaunch. A fresh store
    /// over the same defaults domain is exactly what the next launch reads.
    func testTheFilterStateSurvivesARelaunch() throws {
        let name = "today-badge-filter-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertFalse(TodayViewPreferences(defaults: defaults).isBadgeFilterOn,
                       "the day opens whole, which is what it has always done")

        TodayViewPreferences(defaults: defaults).isBadgeFilterOn = true

        let afterRelaunch = TodayViewPreferences(defaults: defaults)
        XCTAssertTrue(afterRelaunch.isBadgeFilterOn)

        let model = TodayDashboardModel(makeClient: { FakeNever() })
        model.isBadgeFilterOn = afterRelaunch.isBadgeFilterOn
        XCTAssertTrue(model.isBadgeFilterOn, "and the shell hands it straight to the model")

        TodayViewPreferences(defaults: defaults).isBadgeFilterOn = false
        XCTAssertFalse(TodayViewPreferences(defaults: defaults).isBadgeFilterOn)
    }
}

/// A `TodayProviding` for a model that is never asked anything.
private struct FakeNever: TodayProviding {
    func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult { .notModified }
    func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                   day: String?, ifMatch: String) async throws -> TodayMutationResult { .itemGone }
    func moveItem(id: String, op: TodayMoveOp, at: Date,
                  day: String?, ifMatch: String) async throws -> TodayMutationResult { .itemGone }
    func postpone(id: String, deferred: Bool, at: Date,
                  day: String?, ifMatch: String) async throws -> TodayMutationResult { .itemGone }
    func glance(id: String, at: Date,
                ifMatch: String) async throws -> TodayMutationResult { .itemGone }
}
