import XCTest
@testable import Jesse

/// The Today-on-the-wrist wire: the compact summary the phone pushes as an
/// application context, and the check intent the watch sends back. Pure value
/// types and a pure codec, so this drives them directly — no WatchConnectivity,
/// no phone, no watch.
///
/// The two properties worth pinning hardest are TRUNCATION (the cap is enforced by
/// the initializer, so no call site can smuggle a long lead onto a 45mm screen) and
/// REJECTION (a malformed or hostile dictionary comes back nil rather than
/// crashing, exactly as `WatchMessage.decode` does for the chat wire).
final class WatchTodayWireTests: XCTestCase {

    // MARK: Truncation

    func testLeadIsTruncatedAtConstruction() {
        let long = String(repeating: "a", count: 200)
        let row = WatchTodayRow(id: "abc", lead: long, checked: false, section: "Do Now")
        XCTAssertEqual(row.lead.count, WatchTodayWire.maxLeadCharacters)
        XCTAssertTrue(row.lead.hasSuffix("…"))
    }

    func testShortLeadIsUntouched() {
        let row = WatchTodayRow(id: "abc", lead: "Reply to Kristi", checked: false, section: "Do Now")
        XCTAssertEqual(row.lead, "Reply to Kristi")
    }

    func testLeadExactlyAtTheCapIsNotEllipsised() {
        let exact = String(repeating: "b", count: WatchTodayWire.maxLeadCharacters)
        let row = WatchTodayRow(id: "abc", lead: exact, checked: false, section: "Do Now")
        XCTAssertEqual(row.lead, exact)
    }

    /// Truncation counts CHARACTERS, not UTF-8 bytes, and must not split a grapheme
    /// cluster — the day file is full of names with accents and the occasional emoji.
    func testTruncationIsGraphemeSafe() {
        let row = WatchTodayRow(id: "abc", lead: String(repeating: "é", count: 200),
                                checked: false, section: "Do Now")
        XCTAssertEqual(row.lead.count, WatchTodayWire.maxLeadCharacters)
    }

    // MARK: Summary round trip

    func testSummaryRoundTrips() {
        let summary = WatchTodaySummary(
            date: "2026-08-11",
            etag: "W/\"deadbeef\"",
            pushedAt: Date(timeIntervalSince1970: 1_786_000_000),
            rows: [
                WatchTodayRow(id: "aaa", lead: "The standing one", checked: false, section: ""),
                WatchTodayRow(id: "bbb", lead: "Reply to Kristi", checked: true, section: "Do Now"),
            ],
            openCount: 9,
            doneCount: 4,
            doNowOpenCount: 5)
        XCTAssertEqual(WatchTodaySummary.decode(summary.encode()), summary)
    }

    /// A context from a phone that predates the complication carries no Do Now count.
    /// Zero is the right reading of that, not a decode failure — the list still
    /// renders and only the complication's number is missing.
    func testAPayloadWithoutADoNowCountDecodesToZero() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 3, doneCount: 1,
                                     doNowOpenCount: 2).encode()
        dict["doNowOpen"] = nil
        XCTAssertEqual(WatchTodaySummary.decode(dict)?.doNowOpenCount, 0)
        XCTAssertEqual(WatchTodaySummary.decode(dict)?.openCount, 3)
    }

    func testSummaryWithNoDayRoundTrips() {
        let summary = WatchTodaySummary(date: nil, etag: nil,
                                        pushedAt: Date(timeIntervalSince1970: 1_786_000_000),
                                        rows: [], openCount: 0, doneCount: 0)
        XCTAssertEqual(WatchTodaySummary.decode(summary.encode()), summary)
    }

    /// The encoded form must be property-list types only — WatchConnectivity rejects
    /// an application context that holds anything else, and it rejects it at RUNTIME,
    /// which is exactly the failure a codec test should catch instead.
    func testEncodedSummaryIsPropertyListSafe() {
        let summary = WatchTodaySummary(
            date: "2026-08-11", etag: "e",
            pushedAt: Date(timeIntervalSince1970: 1_786_000_000),
            rows: [WatchTodayRow(id: "aaa", lead: "x", checked: false, section: "Do Now")],
            openCount: 1, doneCount: 0)
        XCTAssertTrue(PropertyListSerialization.propertyList(summary.encode(),
                                                             isValidFor: .binary))
    }

    /// `pushedAt` is a `Double`, not an `Int`, and this is the test that says why:
    /// `Int` is 32 bits on arm64_32 (Apple Watch Series 4 through 8), where a
    /// milliseconds-since-epoch stamp overflows. Seconds-as-Double is exact well past
    /// any date this app will see.
    func testPushedAtSurvivesAFarFutureDate() {
        let far = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01
        let summary = WatchTodaySummary(date: "2100-01-01", etag: nil, pushedAt: far,
                                        rows: [], openCount: 0, doneCount: 0)
        XCTAssertEqual(WatchTodaySummary.decode(summary.encode())?.pushedAt, far)
    }

    // MARK: Summary rejection

    func testEmptyDictionaryIsRejected() {
        XCTAssertNil(WatchTodaySummary.decode([:]))
    }

    func testWrongVersionIsRejected() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["v"] = 99
        XCTAssertNil(WatchTodaySummary.decode(dict))
    }

    func testWrongTypeIsRejected() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["type"] = "todayCheck"
        XCTAssertNil(WatchTodaySummary.decode(dict))
    }

    func testMissingPushedAtIsRejected() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["pushedAt"] = nil
        XCTAssertNil(WatchTodaySummary.decode(dict))
    }

    /// A row with no id is not a row: every piece of watch state is keyed by it.
    func testRowWithoutAnIdIsRejected() {
        var dict = WatchTodaySummary(
            date: nil, etag: nil, pushedAt: Date(),
            rows: [WatchTodayRow(id: "aaa", lead: "x", checked: false, section: "s")],
            openCount: 1, doneCount: 0).encode()
        dict["rows"] = [["lead": "x", "checked": false, "section": "s"]]
        XCTAssertNil(WatchTodaySummary.decode(dict))
    }

    /// A hostile payload cannot force a pathological render: rows past the cap are
    /// dropped on decode rather than the whole context being thrown away, because a
    /// too-long list is still a usable list once it is bounded.
    func testOverlongRowListIsClamped() {
        let rows = (0..<200).map { ["id": "id\($0)", "lead": "x", "checked": false, "section": "s"] as [String: Any] }
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["rows"] = rows
        let decoded = WatchTodaySummary.decode(dict)
        XCTAssertEqual(decoded?.rows.count, WatchTodayWire.maxDecodedRows)
    }

    /// An over-long lead that arrives on the wire is clamped by the same rule the
    /// sender applies, so the two ends can never disagree about what fits.
    func testDecodedLeadIsClampedToo() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["rows"] = [["id": "a", "lead": String(repeating: "z", count: 500),
                         "checked": false, "section": "s"] as [String: Any]]
        XCTAssertEqual(WatchTodaySummary.decode(dict)?.rows.first?.lead.count,
                       WatchTodayWire.maxLeadCharacters)
    }

    /// Negative counts are nonsense a renderer would happily turn into "-3 more on
    /// your phone". Clamped at zero rather than rejected: the rows are still good.
    func testNegativeCountsAreClamped() {
        var dict = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                     rows: [], openCount: 0, doneCount: 0).encode()
        dict["open"] = -5
        dict["done"] = -1
        let decoded = WatchTodaySummary.decode(dict)
        XCTAssertEqual(decoded?.openCount, 0)
        XCTAssertEqual(decoded?.doneCount, 0)
    }

    // MARK: The check intent

    func testCheckRoundTrips() {
        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc123def456", checked: true)
        XCTAssertEqual(WatchTodayCheck.decode(check.encode()), check)
    }

    func testUncheckRoundTrips() {
        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc123def456", checked: false)
        XCTAssertEqual(WatchTodayCheck.decode(check.encode()), check)
    }

    func testCheckWithABadUUIDIsRejected() {
        var dict = WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true).encode()
        dict["intentId"] = "not-a-uuid"
        XCTAssertNil(WatchTodayCheck.decode(dict))
    }

    func testCheckWithAnEmptyItemIdIsRejected() {
        var dict = WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true).encode()
        dict["itemId"] = ""
        XCTAssertNil(WatchTodayCheck.decode(dict))
    }

    // MARK: The two codecs do not answer for each other

    /// Both ride `transferUserInfo` alongside the chat wire, so each decoder must
    /// refuse the other's dictionaries — otherwise the receiver's try-in-order
    /// dispatch would hand a summary to the check handler.
    func testTheCodecsRejectEachOther() {
        let summary = WatchTodaySummary(date: nil, etag: nil, pushedAt: Date(),
                                        rows: [], openCount: 0, doneCount: 0).encode()
        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true).encode()
        XCTAssertNil(WatchTodayCheck.decode(summary))
        XCTAssertNil(WatchTodaySummary.decode(check))
        XCTAssertNil(WatchMessage.decode(summary))
        XCTAssertNil(WatchMessage.decode(check))
    }

    /// And the CHAT codec's dictionaries must not decode as Today ones either — the
    /// phone tries the Today decoders first on `didReceiveUserInfo`.
    func testTheChatWireIsNotMistakenForTheTodayWire() {
        let reply = WatchMessage.reply(WatchReply(requestId: UUID(), ok: true)).encode()
        XCTAssertNil(WatchTodaySummary.decode(reply))
        XCTAssertNil(WatchTodayCheck.decode(reply))
    }
}
