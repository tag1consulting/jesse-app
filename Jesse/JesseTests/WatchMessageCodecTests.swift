import XCTest
@testable import Jesse

/// The pure WatchConnectivity wire codec (`WatchMessage.encode`/`decode`). Proven
/// here from the iOS test target — the shared source is compiled into both the
/// phone and the watch, so this is the same codec both ends run. Asserts every
/// message kind round-trips cleanly through the `[String: Any]` WatchConnectivity
/// carries, and that a malformed or oversized dictionary is REJECTED (nil), not
/// crashed on.
final class WatchMessageCodecTests: XCTestCase {

    // MARK: - Round-trips

    func testRequestWithInlineAudioRoundTrips() {
        let audio = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let original = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, audio: audio))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    func testRequestViaFileRoundTrips() {
        // A large clip travels by transferFile: no inline bytes, audioViaFile set.
        let original = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .tell, audio: nil, audioViaFile: true))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    func testRequestWithTranscriptFallbackRoundTrips() {
        let original = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, transcript: "what is on today"))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    func testReplyRoundTrips() {
        let original = WatchMessage.reply(
            WatchReply(requestId: UUID(), ok: true,
                       displayText: "Milk, eggs, bread.",
                       spokenText: "You need milk, eggs, and bread.",
                       sessionId: "sess-1", threadId: UUID()))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    func testFailureReplyRoundTrips() {
        let original = WatchMessage.reply(
            WatchReply(requestId: UUID(), ok: false, error: "Couldn't reach your phone."))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    func testAckRoundTrips() {
        let original = WatchMessage.ack(WatchAck(requestId: UUID(), accepted: true))
        let decoded = WatchMessage.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Rejection (malformed / oversized), never a crash

    func testEmptyDictionaryRejected() {
        XCTAssertNil(WatchMessage.decode([:]))
    }

    func testWrongVersionRejected() {
        var dict = WatchMessage.ack(WatchAck(requestId: UUID(), accepted: true)).encode()
        dict["v"] = 999
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testUnknownTypeRejected() {
        var dict = WatchMessage.ack(WatchAck(requestId: UUID(), accepted: true)).encode()
        dict["type"] = "bogus"
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testBadRequestIdRejected() {
        var dict = WatchMessage.ack(WatchAck(requestId: UUID(), accepted: true)).encode()
        dict["requestId"] = "not-a-uuid"
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testRequestWithNoAudioSourceRejected() {
        // No inline audio, no file flag, no transcript — nothing to relay.
        var dict = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, audio: Data([1, 2, 3]))).encode()
        dict.removeValue(forKey: "audio")
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testOversizedInlineAudioRejected() {
        let tooBig = Data(count: WatchMessage.maxInlineAudioBytes + 1)
        let dict = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, audio: tooBig)).encode()
        XCTAssertNil(WatchMessage.decode(dict), "an oversized inline clip must be rejected, not carried")
    }

    func testAudioAtCapAccepted() {
        let atCap = Data(count: WatchMessage.maxInlineAudioBytes)
        let dict = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, audio: atCap)).encode()
        XCTAssertNotNil(WatchMessage.decode(dict))
    }

    func testOverlongTranscriptRejected() {
        let huge = String(repeating: "a", count: WatchMessage.maxTextBytes + 1)
        var dict = WatchMessage.request(
            WatchRequest(requestId: UUID(), mode: .ask, transcript: "ok")).encode()
        dict["transcript"] = huge
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testWrongTypedFieldRejectedNotCrashed() {
        // requestId carried as a number, audio as a string — hostile shapes must be
        // rejected without trapping.
        XCTAssertNil(WatchMessage.decode(["v": 1, "type": "reply", "requestId": 42, "ok": true]))
        XCTAssertNil(WatchMessage.decode(["v": 1, "type": "request", "requestId": UUID().uuidString,
                                          "mode": "ask", "audio": "not-data"]))
    }
}
