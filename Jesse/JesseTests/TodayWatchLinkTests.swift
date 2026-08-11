import XCTest
import JesseNetworking
import JesseTodayDisplay
@testable import Jesse

/// The phone half of the wrist relay: it turns the day model's snapshot into a
/// pushed context, and turns a wrist intent back into an ordinary `check` on the
/// SAME `TodayDashboardModel` the Today tab drives.
///
/// That sameness is the point of the whole class. A wrist check that took its own
/// path to the bridge would be a second implementation of the ETag handling, the
/// optimistic overlay, and the `410`/`412`/`428` recovery — and the second one is
/// always the one that writes to a document nobody is looking at.
@MainActor
final class TodayWatchLinkTests: XCTestCase {

    /// A `TodayProviding` that answers from a script and records what it was asked.
    private final class StubClient: TodayProviding {
        nonisolated(unsafe) var fetch: TodayFetchResult
        nonisolated(unsafe) var mutation: TodayMutationResult
        nonisolated(unsafe) private(set) var checked: [(id: String, checked: Bool)] = []
        nonisolated(unsafe) private(set) var fetches = 0

        init(fetch: TodayFetchResult, mutation: TodayMutationResult) {
            self.fetch = fetch
            self.mutation = mutation
        }
        func getToday(ifNoneMatch: String?) async throws -> TodayFetchResult {
            fetches += 1
            return fetch
        }
        func checkItem(id: String, checked: Bool, evidence: String?, at: Date,
                       ifMatch: String) async throws -> TodayMutationResult {
            self.checked.append((id, checked))
            return mutation
        }
        func moveItem(id: String, op: TodayMoveOp, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult { mutation }
        func postpone(id: String, deferred: Bool, at: Date,
                      ifMatch: String) async throws -> TodayMutationResult { mutation }
        func glance(id: String, at: Date, ifMatch: String) async throws -> TodayMutationResult {
            mutation
        }
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func makeLink(_ stub: StubClient) -> (TodayWatchLink, TodayDashboardModel, Box) {
        let model = TodayDashboardModel(makeClient: { stub }, now: { [now] in now })
        let box = Box()
        let link = TodayWatchLink(model: model,
                                  push: { box.pushed.append($0) },
                                  now: { [now] in now })
        return (link, model, box)
    }

    private final class Box {
        var pushed: [WatchTodaySummary] = []
    }

    // MARK: Pushing

    func testNothingIsPushedBeforeTheDayLoads() {
        let (link, _, box) = makeLink(StubClient(fetch: .notModified, mutation: .itemGone))
        link.pushCurrent()
        XCTAssertTrue(box.pushed.isEmpty)
    }

    func testALoadedDayIsPushedAsASummary() async {
        let stub = StubClient(fetch: .snapshot(Self.day()), mutation: .itemGone)
        let (link, model, box) = makeLink(stub)
        await model.load()
        link.pushCurrent()

        XCTAssertEqual(box.pushed.count, 1)
        XCTAssertEqual(box.pushed.first?.rows.map(\.id), ["lead", "open-a"])
        XCTAssertEqual(box.pushed.first?.date, "2026-08-11")
        XCTAssertEqual(box.pushed.first?.etag, "\"tag-1\"")
        XCTAssertEqual(box.pushed.first?.pushedAt, now)
    }

    /// The push carries the SERVER's document, not the optimistic overlay. The wrist
    /// keeps its own pending state; a phone that pushed its optimism too would be
    /// telling the watch a claim is settled when it is not.
    func testThePushCarriesTheServerDocumentNotTheOverlay() async {
        // The mutation answers with the day UNCHANGED — a snapshot that raced ahead
        // of the write, which is precisely when the model is holding an optimistic
        // check the server has not confirmed.
        let stub = StubClient(fetch: .snapshot(Self.day()), mutation: .snapshot(Self.day()))
        let (link, model, box) = makeLink(stub)
        await model.load()
        await model.check(id: "open-a", checked: true)
        XCTAssertTrue(model.isPending("open-a"), "the optimistic check is still in flight")

        box.pushed.removeAll()
        link.pushCurrent()

        XCTAssertEqual(box.pushed.first?.rows.map(\.id), ["lead", "open-a"])
        XCTAssertEqual(box.pushed.first?.rows.last?.checked, false)
    }

    // MARK: Applying a wrist intent

    func testAnIntentBecomesAnOrdinaryCheckOnTheDayModel() async {
        let stub = StubClient(fetch: .snapshot(Self.day()),
                              mutation: .snapshot(Self.day(checkedIds: ["open-a"])))
        let (link, model, _) = makeLink(stub)
        await model.load()

        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true))

        XCTAssertEqual(stub.checked.count, 1)
        XCTAssertEqual(stub.checked.first?.id, "open-a")
        XCTAssertEqual(stub.checked.first?.checked, true)
    }

    /// The confirming push is the watch's only way to learn the check landed, so it
    /// has to follow the mutation rather than wait for the next poll.
    func testApplyingPushesTheConfirmingContext() async {
        let stub = StubClient(fetch: .snapshot(Self.day()),
                              mutation: .snapshot(Self.day(checkedIds: ["open-a"])))
        let (link, model, box) = makeLink(stub)
        await model.load()
        box.pushed.removeAll()

        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true))

        XCTAssertEqual(box.pushed.count, 1)
        XCTAssertFalse(box.pushed.last?.rows.contains { $0.id == "open-a" } ?? true,
                       "a ticked Do Now item is no longer open, so it leaves the wrist")
        XCTAssertEqual(box.pushed.last?.doneCount, 1)
    }

    /// `transferUserInfo` redelivers. Without dedup, a queued intent that arrives
    /// twice would tick an item, then the user's later untick would be re-ticked by
    /// the redelivery.
    func testARedeliveredIntentIsAppliedOnlyOnce() async {
        let stub = StubClient(fetch: .snapshot(Self.day()),
                              mutation: .snapshot(Self.day(checkedIds: ["open-a"])))
        let (link, model, _) = makeLink(stub)
        await model.load()

        let intent = WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true)
        await link.apply(intent)
        await link.apply(intent)

        XCTAssertEqual(stub.checked.count, 1)
    }

    func testTwoDistinctIntentsForOneItemBothApply() async {
        let stub = StubClient(fetch: .snapshot(Self.day()),
                              mutation: .snapshot(Self.day(checkedIds: ["open-a"])))
        let (link, model, _) = makeLink(stub)
        await model.load()

        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true))
        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: false))

        XCTAssertEqual(stub.checked.map(\.checked), [true, false])
    }

    /// An intent that arrives before the phone has ever read the day has no ETag to
    /// write under. Fetching one first is the difference between the wrist's check
    /// landing and it being silently dropped.
    func testAnIntentArrivingBeforeTheDayIsLoadedFetchesFirst() async {
        let stub = StubClient(fetch: .snapshot(Self.day()),
                              mutation: .snapshot(Self.day(checkedIds: ["open-a"])))
        let (link, model, _) = makeLink(stub)
        XCTAssertNil(model.etag)

        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true))

        XCTAssertGreaterThanOrEqual(stub.fetches, 1)
        XCTAssertEqual(stub.checked.count, 1)
    }

    /// The day file has no such item any more. The model takes the row off its own
    /// screen; the wrist learns the same thing from the context that follows.
    func testAVanishedItemStillPushesAFreshContext() async {
        let stub = StubClient(fetch: .snapshot(Self.day()), mutation: .itemGone)
        let (link, model, box) = makeLink(stub)
        await model.load()
        box.pushed.removeAll()

        await link.apply(WatchTodayCheck(intentId: UUID(), itemId: "open-a", checked: true))

        XCTAssertFalse(box.pushed.isEmpty, "the wrist is told what the day looks like now")
    }

    // MARK: Fixtures

    private static func day(checkedIds: Set<String> = []) -> TodaySnapshot {
        TodaySnapshot(
            date: "2026-08-11",
            leadItems: [TodayItem(id: "lead", checked: checkedIds.contains("lead"),
                                  lead: "TOP PRIORITY: finish the rebuild")],
            sections: [
                TodaySection(name: "Do Now", items: [
                    TodayItem(id: "open-a", checked: checkedIds.contains("open-a"),
                              lead: "Order the thermocouple", sectionName: "Do Now"),
                ]),
            ],
            etag: "\"tag-1\"")
    }
}
