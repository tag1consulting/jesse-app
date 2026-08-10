import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The detail reducer: what the sheet holds between "tapped an item" and the bridge's
// answer, and what it keeps afterwards. Driven through a scripted fake — no server, no
// clock, no view.

@MainActor
final class TodayDetailModelTests: XCTestCase {

    /// A scriptable `TodayDetailProviding`. Returns the next scripted outcome (the last
    /// repeats) and records the conditional tag it was asked with, which is the thing
    /// most worth asserting: an `If-None-Match` that never gets sent is a `304` that
    /// never happens.
    ///
    /// `@unchecked Sendable` over plain stored state, the same shape as the day-model's
    /// fake: every call is driven from the main actor by an awaited model method, so
    /// there is no concurrent access to check.
    final class FakeDetailClient: TodayDetailProviding, @unchecked Sendable {
        enum Outcome { case result(TodayDetailResult); case error(JesseError) }

        var outcomes: [Outcome] = []
        private(set) var calls: [(id: String, ifNoneMatch: String?)] = []

        func getItemDetail(id: String, ifNoneMatch: String?) async throws -> TodayDetailResult {
            calls.append((id, ifNoneMatch))
            let outcome = outcomes.isEmpty
                ? Outcome.result(.noDetail(TodayNoDetail(id: id)))
                : outcomes[min(calls.count - 1, outcomes.count - 1)]
            switch outcome {
            case .result(let r): return r
            case .error(let e): throw e
            }
        }
    }

    private let widget = TodayItemDetail(id: "aaaaaaaaaaaa", path: "Projects/Demo/Widget.md",
                                         target: "todo-list/Projects/Demo/Widget",
                                         markdown: "# Widget\n\nThe body.\n",
                                         truncated: false, etag: "\"note-1\"")

    private func model(_ client: FakeDetailClient) -> TodayDetailModel {
        TodayDetailModel(makeClient: { client })
    }

    // MARK: - Opening an item

    /// **One tap, one read.** Opening a row asks the bridge for that row's note exactly
    /// once — the detail view's `.task(id:)` is keyed to the item, so a redraw (a
    /// refreshed day, a rotation, a re-render while the note is on screen) must not
    /// re-fetch. The failure this rules out is a detail screen that hammers the vault
    /// once per layout pass.
    func testOpeningAnItemReadsItsNoteExactlyOnce() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget))]
        let m = model(client)

        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls.first?.id, "aaaaaaaaaaaa", "the tapped row's id, not another")
        XCTAssertEqual(m.itemID, "aaaaaaaaaaaa")
    }

    /// Opening a DIFFERENT row asks about that row, and never leaves the previous note
    /// on screen under the new title while it loads.
    func testOpeningASecondItemAsksAboutTheSecondItem() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")

        client.outcomes = [.result(.noDetail(TodayNoDetail(id: "bbbbbbbbbbbb")))]
        await m.load(id: "bbbbbbbbbbbb")

        XCTAssertEqual(client.calls.map(\.id), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        XCTAssertEqual(m.itemID, "bbbbbbbbbbbb")
        XCTAssertNil(m.note, "the first item's note did not follow the second item's title")
    }

    // MARK: - Loading

    func testALoadedNoteIsHeldWithItsItem() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget))]
        let m = model(client)

        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(m.state, .loaded(widget))
        XCTAssertEqual(m.note?.path, "Projects/Demo/Widget.md")
        XCTAssertEqual(m.itemID, "aaaaaaaaaaaa")
        XCTAssertFalse(m.isLoading)
        XCTAssertFalse(m.isOffline)
        XCTAssertEqual(client.calls.first?.ifNoneMatch, nil, "the first load has no tag to send")
    }

    /// **The `304` path, which is the common one.** A re-open sends the tag the note came
    /// under and re-uses what is cached — the whole reason the ETag is carried at all.
    func testASecondLoadSendsTheEtagAndReusesTheCachedNoteOnA304() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.notModified(etag: "\"note-1\""))]
        let m = model(client)

        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].ifNoneMatch, "\"note-1\"")
        XCTAssertEqual(m.state, .loaded(widget), "a 304 re-renders nothing and loses nothing")
        XCTAssertFalse(m.isOffline)
    }

    /// A forced refresh drops the conditional header: "answer me properly" is what
    /// pull-to-refresh means, and a `304` in response to it would be useless.
    func testAForcedRefreshSendsNoConditionalTag() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget))]
        let m = model(client)

        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "aaaaaaaaaaaa", force: true)

        XCTAssertEqual(client.calls[1].ifNoneMatch, nil)
    }

    /// A cached note re-opens INSTANTLY rather than through a spinner: the conditional
    /// request only confirms what is already on screen.
    func testReopeningACachedItemNeverFlashesThroughLoading() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.notModified(etag: "\"note-1\""))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")
        m.clear()
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.isCached("aaaaaaaaaaaa"))

        await m.load(id: "aaaaaaaaaaaa")
        XCTAssertEqual(m.state, .loaded(widget))
    }

    // MARK: - The typed non-answers

    /// An item with no note is an ORDINARY item — an empty state, never an error. Both
    /// reasons are kept, because "nothing is linked" and "what is linked isn't there" are
    /// different facts about the vault and the second is actionable.
    func testNoDetailIsAnEmptyStateAndKeepsItsReason() async {
        for reason in [TodayNoDetailReason.noTarget, .unresolvedTarget, .unknown] {
            let client = FakeDetailClient()
            client.outcomes = [.result(.noDetail(TodayNoDetail(id: "b", reason: reason,
                                                               etag: "\"none-1\"")))]
            let m = model(client)
            await m.load(id: "b")
            XCTAssertEqual(m.state, .noDetail(reason))
            XCTAssertNil(m.note)
            XCTAssertFalse(m.isOffline, "\(reason) is not a failure")
            XCTAssertFalse(TodayDetailModel.noDetailMessage(reason).isEmpty)
        }
        XCTAssertNotEqual(TodayDetailModel.noDetailMessage(.noTarget),
                          TodayDetailModel.noDetailMessage(.unresolvedTarget))
    }

    /// A no-detail answer is cached under its own tag too, so re-opening an item that
    /// will never have a note costs one `304` rather than a body.
    func testANoDetailAnswerIsCachedAndPolledConditionally() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.noDetail(TodayNoDetail(id: "b", reason: .noTarget,
                                                           etag: "\"none-1\""))),
                           .result(.notModified(etag: "\"none-1\""))]
        let m = model(client)
        await m.load(id: "b")
        await m.load(id: "b")

        XCTAssertEqual(client.calls[1].ifNoneMatch, "\"none-1\"")
        XCTAssertEqual(m.state, .noDetail(.noTarget))
    }

    /// **`410`**: the item left the day file, so a cached note for it is about something
    /// that no longer exists and is dropped with it.
    func testGoneIsRemovedAndClearsTheCache() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.itemGone)]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(m.state, .removed)
        XCTAssertFalse(m.isCached("aaaaaaaaaaaa"))
        XCTAssertFalse(m.isOffline, "the bridge answered; it just answered 'gone'")
    }

    // MARK: - Failure

    /// A previously-read note is never blanked by a failed refresh: it stays on screen
    /// and the failure surfaces as `isOffline`. A note the user was reading a second ago
    /// is still the best answer available.
    func testAFailedRefreshKeepsTheCachedNoteAndFlagsItStale() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)),
                           .error(.badResponse(500, "kaboom"))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(m.state, .loaded(widget))
        XCTAssertTrue(m.isOffline)
        XCTAssertNotNil(m.lastErrorMessage)
    }

    /// With nothing cached there is nothing to keep, so the failure IS the state.
    func testAFirstLoadThatFailsIsUnavailable() async {
        let client = FakeDetailClient()
        client.outcomes = [.error(.notConfigured)]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")

        guard case .unavailable(let message) = m.state else {
            return XCTFail("expected unavailable, got \(m.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(m.isOffline)
    }

    /// A success after a failure clears the banner — including a `304`, which IS a
    /// completed round trip.
    func testASuccessfulPollClearsTheStaleBanner() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)),
                           .error(.badResponse(500, "kaboom")),
                           .result(.notModified(etag: "\"note-1\""))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "aaaaaaaaaaaa")
        XCTAssertTrue(m.isOffline)

        await m.load(id: "aaaaaaaaaaaa")
        XCTAssertFalse(m.isOffline)
        XCTAssertNil(m.lastErrorMessage)
        XCTAssertEqual(m.state, .loaded(widget))
    }

    // MARK: - Switching items

    /// Switching to an uncached item must not leave the previous note on screen: a note
    /// under the wrong title is worse than a spinner.
    func testSwitchingItemsNeverShowsThePreviousNote() async {
        let other = TodayItemDetail(id: "bbbbbbbbbbbb", path: "Projects/Demo/Other.md",
                                    markdown: "other", etag: "\"note-2\"")
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.detail(other))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")

        await m.load(id: "bbbbbbbbbbbb")
        XCTAssertEqual(m.itemID, "bbbbbbbbbbbb")
        XCTAssertEqual(m.note?.path, "Projects/Demo/Other.md")
        XCTAssertEqual(client.calls[1].ifNoneMatch, nil, "a different item has no tag of ours")
    }

    /// And when the new item's load FAILS, the screen says so rather than showing the
    /// previous item's note under the new item's title — which is the way the previous
    /// state would leak if switching did not reset it.
    func testSwitchingToAnItemWhoseLoadFailsShowsTheFailureNotTheOldNote() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .error(.badResponse(500, "kaboom"))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")

        await m.load(id: "bbbbbbbbbbbb")

        XCTAssertEqual(m.itemID, "bbbbbbbbbbbb")
        XCTAssertNil(m.note, "the previous item's note must not survive the switch")
        guard case .unavailable = m.state else {
            return XCTFail("expected unavailable, got \(m.state)")
        }
    }

    /// Each item keeps its own cache entry and its own tag.
    func testTheCacheIsKeyedByItem() async {
        let other = TodayItemDetail(id: "bbbbbbbbbbbb", path: "Other.md", markdown: "other",
                                    etag: "\"note-2\"")
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.detail(other)),
                           .result(.notModified(etag: "\"note-1\""))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")
        await m.load(id: "bbbbbbbbbbbb")
        await m.load(id: "aaaaaaaaaaaa")

        XCTAssertEqual(client.calls[2].ifNoneMatch, "\"note-1\"", "the FIRST item's tag")
        XCTAssertEqual(m.state, .loaded(widget))
        XCTAssertTrue(m.isCached("bbbbbbbbbbbb"))
    }

    /// The day file changed under the screen, so an item's note may now resolve to a
    /// different file entirely — every cached tag is about a document that is gone.
    func testInvalidateDropsEveryCachedTag() async {
        let client = FakeDetailClient()
        client.outcomes = [.result(.detail(widget)), .result(.detail(widget))]
        let m = model(client)
        await m.load(id: "aaaaaaaaaaaa")

        m.invalidate()
        XCTAssertFalse(m.isCached("aaaaaaaaaaaa"))
        await m.load(id: "aaaaaaaaaaaa")
        XCTAssertEqual(client.calls[1].ifNoneMatch, nil)
    }
}
