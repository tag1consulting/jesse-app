import XCTest
@testable import JesseWatch

/// Proves the SHARED pure logic (the wire codec, the silence detector, and reply
/// dedup) is correct when compiled into the WATCH build specifically — the same
/// source the phone tests exercise, here validated against the watchOS module so a
/// watchOS-only compilation or behavior difference would be caught. Pure value
/// types only (no audio, WatchConnectivity, or the `@Observable` talk model), so it
/// runs cleanly in the watch simulator's hosted test runner.
final class WatchSharedLogicTests: XCTestCase {

    // MARK: Codec

    func testRequestRoundTripsOnWatch() {
        let original = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, audio: Data([1, 2, 3])))
        XCTAssertEqual(WatchMessage.decode(original.encode()), original)
    }

    func testReplyRoundTripsOnWatch() {
        let original = WatchMessage.reply(
            WatchReply(requestId: UUID(), ok: true, displayText: "hi", spokenText: "hi",
                       sessionId: "s", threadId: UUID()))
        XCTAssertEqual(WatchMessage.decode(original.encode()), original)
    }

    func testOversizedInlineAudioRejectedOnWatch() {
        let tooBig = Data(count: WatchMessage.maxInlineAudioBytes + 1)
        let dict = WatchMessage.request(WatchRequest(requestId: UUID(), mode: .ask, audio: tooBig)).encode()
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testMalformedRejectedNotCrashedOnWatch() {
        XCTAssertNil(WatchMessage.decode([:]))
        XCTAssertNil(WatchMessage.decode(["v": 1, "type": "reply", "requestId": 7, "ok": true]))
    }

    // MARK: Silence detector

    func testSilenceStopBoundaryOnWatch() {
        let det = SilenceDetector(speechThreshold: -30, trailingSilence: 1.5, maxDuration: 12)
        let stops = det.decide(samples: [MeterSample(t: 1.0, power: -10), MeterSample(t: 2.6, power: -55)])
        XCTAssertEqual(stops, .stopSilence(at: 2.6))
        let keeps = det.decide(samples: [MeterSample(t: 1.0, power: -10), MeterSample(t: 1.5, power: -55)])
        XCTAssertEqual(keeps, .listening)
    }

    // MARK: Reply dedup

    func testReplyDedupOnWatch() {
        var d = ReplyDeduper()
        let id = UUID()
        XCTAssertTrue(d.shouldDeliver(id))
        XCTAssertFalse(d.shouldDeliver(id))
    }
}
