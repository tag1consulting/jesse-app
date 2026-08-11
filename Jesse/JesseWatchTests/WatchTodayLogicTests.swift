import XCTest
@testable import JesseWatch

/// The Today-on-the-wrist logic, validated against the WATCH build specifically —
/// same source as the phone's `WatchTodayWireTests` / `WatchTodayModelTests`, here
/// compiled for watchOS so a platform difference is caught where it would actually
/// bite. `Int` is 32 bits on arm64_32, which is exactly the kind of thing a
/// simulator-only test on the phone would never find.
///
/// Deliberately not a line-for-line copy of the phone suites: this covers the wire,
/// the reducer's three endings for a local claim, the unreachable path, and the
/// stale guard — the behaviour the watch is solely responsible for.
@MainActor
final class WatchTodayLogicTests: XCTestCase {

    private final class FakeSender: WatchTodaySending {
        var isReachable: Bool
        var onTodayContext: ((WatchTodaySummary) -> Void)?
        private(set) var sent: [WatchTodayCheck] = []
        init(reachable: Bool = true) { self.isReachable = reachable }
        func send(_ check: WatchTodayCheck) { sent.append(check) }
        func push(_ summary: WatchTodaySummary) { onTodayContext?(summary) }
    }

    private var clock = Date(timeIntervalSince1970: 1_786_000_000)

    private func makeModel(reachable: Bool = true) -> (WatchTodayModel, FakeSender) {
        let sender = FakeSender(reachable: reachable)
        return (WatchTodayModel(sender: sender, now: { [self] in clock }), sender)
    }

    // MARK: Wire

    func testSummaryRoundTripsOnWatch() {
        let summary = Self.day()
        XCTAssertEqual(WatchTodaySummary.decode(summary.encode()), summary)
    }

    func testCheckRoundTripsOnWatch() {
        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc123", checked: true)
        XCTAssertEqual(WatchTodayCheck.decode(check.encode()), check)
    }

    func testLeadIsTruncatedOnWatch() {
        let row = WatchTodayRow(id: "a", lead: String(repeating: "x", count: 400),
                                checked: false, section: "Do Now")
        XCTAssertEqual(row.lead.count, WatchTodayWire.maxLeadCharacters)
    }

    func testMalformedContextRejectedNotCrashedOnWatch() {
        XCTAssertNil(WatchTodaySummary.decode([:]))
        XCTAssertNil(WatchTodaySummary.decode(["v": 1, "type": "todayContext"]))
        XCTAssertNil(WatchTodayCheck.decode(["v": 1, "type": "todayCheck", "itemId": "a"]))
    }

    /// arm64_32 (Apple Watch Series 4 through 8) has a 32-bit `Int`. A far-future
    /// stamp that survives here proves the wire is not carrying milliseconds in one.
    func testAFarFutureStampSurvivesOnWatch() {
        let far = Date(timeIntervalSince1970: 4_102_444_800)
        let summary = WatchTodaySummary(date: nil, etag: nil, pushedAt: far,
                                        rows: [], openCount: 0, doneCount: 0)
        XCTAssertEqual(WatchTodaySummary.decode(summary.encode())?.pushedAt, far)
    }

    // MARK: The reducer's three endings

    func testPendingThenAgreed() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("lead")
        XCTAssertEqual(model.rows.first?.state, .pending)

        sender.push(Self.day(leadChecked: true))
        XCTAssertEqual(model.rows.first?.state, .done)
    }

    func testPendingThenConfirmedWhenTheRowLeaves() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("open-a")
        sender.push(Self.day(rowIds: ["lead"]))

        XCTAssertEqual(model.rows.last?.id, "open-a")
        XCTAssertEqual(model.rows.last?.state, .confirmed)
    }

    func testPendingSurvivesAContextThatStillDisagrees() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        model.toggle("lead")
        sender.push(Self.day())
        XCTAssertEqual(model.rows.first?.state, .pending)
    }

    // MARK: Unreachable phone

    func testUnreachablePhoneQueuesOnWatch() {
        let (model, sender) = makeModel(reachable: false)
        sender.push(Self.day())
        model.toggle("open-a")

        XCTAssertEqual(model.rows.first { $0.id == "open-a" }?.state, .queued)
        XCTAssertEqual(sender.sent.count, 1)
    }

    // MARK: Stale guard

    func testStaleAfterEighteenHoursOnWatch() {
        let (model, sender) = makeModel()
        sender.push(Self.day())
        clock = clock.addingTimeInterval(17 * 3600)
        model.refreshFreshness()
        XCTAssertFalse(model.isStale)
        clock = clock.addingTimeInterval(2 * 3600)
        model.refreshFreshness()
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.dayLabel, "2026-08-11")
    }

    // MARK: Fixtures

    private static func day(leadChecked: Bool = false,
                            rowIds: [String] = ["lead", "open-a"]) -> WatchTodaySummary {
        let all: [String: WatchTodayRow] = [
            "lead": WatchTodayRow(id: "lead", lead: "TOP PRIORITY: finish the rebuild",
                                  checked: leadChecked, section: ""),
            "open-a": WatchTodayRow(id: "open-a", lead: "Order the thermocouple",
                                    checked: false, section: "Do Now"),
        ]
        return WatchTodaySummary(date: "2026-08-11", etag: "\"tag\"",
                                 pushedAt: Date(timeIntervalSince1970: 1_786_000_000),
                                 rows: rowIds.compactMap { all[$0] },
                                 openCount: 3, doneCount: 1)
    }
}
