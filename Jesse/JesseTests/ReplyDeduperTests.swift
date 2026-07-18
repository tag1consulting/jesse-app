import XCTest
@testable import Jesse

/// Reply-dedup-by-requestId. The phone answers on two paths (reliable
/// `transferUserInfo` + immediate `sendMessage`), so the watch can see one reply
/// twice; the deduper keeps the first and drops the rest.
@MainActor
final class ReplyDeduperTests: XCTestCase {

    func testFirstDeliveryPasses() {
        var d = ReplyDeduper()
        XCTAssertTrue(d.shouldDeliver(UUID()))
    }

    func testDuplicateIsDropped() {
        var d = ReplyDeduper()
        let id = UUID()
        XCTAssertTrue(d.shouldDeliver(id), "first arrival renders")
        XCTAssertFalse(d.shouldDeliver(id), "the second arrival of the same reply is dropped")
        XCTAssertFalse(d.shouldDeliver(id), "and every later one too")
    }

    func testDistinctIdsEachPass() {
        var d = ReplyDeduper()
        XCTAssertTrue(d.shouldDeliver(UUID()))
        XCTAssertTrue(d.shouldDeliver(UUID()))
        XCTAssertTrue(d.shouldDeliver(UUID()))
    }

    func testHasDeliveredDoesNotRecord() {
        var d = ReplyDeduper()
        let id = UUID()
        XCTAssertFalse(d.hasDelivered(id))
        _ = d.shouldDeliver(id)
        XCTAssertTrue(d.hasDelivered(id))
    }

    func testTwoPathArrivalRendersOnce() {
        // Model the real scenario: the same requestId arrives via both transports.
        var d = ReplyDeduper()
        let id = UUID()
        let viaUserInfo = d.shouldDeliver(id)
        let viaMessage = d.shouldDeliver(id)
        XCTAssertEqual([viaUserInfo, viaMessage], [true, false])
    }

    func testBoundedEvictionKeepsRecentIds() {
        var d = ReplyDeduper(capacity: 2)
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(d.shouldDeliver(a))
        XCTAssertTrue(d.shouldDeliver(b))
        XCTAssertTrue(d.shouldDeliver(c)) // evicts `a`
        XCTAssertFalse(d.shouldDeliver(c), "most recent still deduped")
        XCTAssertFalse(d.shouldDeliver(b), "still within capacity")
        XCTAssertTrue(d.shouldDeliver(a), "evicted id treated as new (harmless for the retry window)")
    }
}
