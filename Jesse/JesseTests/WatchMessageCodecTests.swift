import XCTest
@testable import Jesse

/// The pure WatchConnectivity wire codec (`WatchMessage.encode`/`decode`). Proven
/// here from the iOS test target — the shared source is compiled into both the
/// phone and the watch, so this is the same codec both ends run. Asserts every
/// message kind round-trips cleanly through the `[String: Any]` WatchConnectivity
/// carries, and that a malformed or oversized dictionary is REJECTED (nil), not
/// crashed on.
@MainActor
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

    /// A turn that returned files carries their NAMES to the watch and nothing else — no
    /// id, no mime, no size, and above all no bytes. The watch link has a hard payload
    /// ceiling and a returned file can be 25 MB, so moving one would fail the whole reply
    /// rather than just the file.
    func testReplyCarriesArtifactNamesOnlyAndNothingElse() {
        let original = WatchMessage.reply(
            WatchReply(requestId: UUID(), ok: true, displayText: "here they are",
                       spokenText: "here they are", sessionId: "s1", threadId: UUID(),
                       artifactNames: ["chart.png", "data.csv"]))
        let dict = original.encode()
        XCTAssertEqual(WatchMessage.decode(dict), original)
        // The wire carries the names and only the names.
        let flat = "\(dict)"
        XCTAssertTrue(flat.contains("chart.png"))
        XCTAssertFalse(flat.contains("sha256"))
        XCTAssertFalse(flat.contains("image/png"))
    }

    /// A reply with no files encodes exactly the dictionary it always did, so an older
    /// watch is unaffected — and a missing or wrong-typed key decodes to "no files"
    /// rather than failing the whole reply, whose TEXT is the point.
    func testAbsentArtifactNamesDecodeAsNoneRatherThanFailing() {
        let plain = WatchReply(requestId: UUID(), ok: true, displayText: "just words")
        XCTAssertNil(WatchMessage.reply(plain).encode()["artifactNames"],
                     "no key at all when there are no files")
        var dict = WatchMessage.reply(plain).encode()
        dict["artifactNames"] = 42   // hostile / corrupt
        guard case let .reply(decoded)? = WatchMessage.decode(dict) else {
            return XCTFail("a malformed names field must not lose the reply")
        }
        XCTAssertEqual(decoded.displayText, "just words")
        XCTAssertTrue(decoded.artifactNames.isEmpty)
    }

    /// Names are sanitized and BOUNDED at the point they become UI: they came from the
    /// model, and a watch screen is not the place to discover that.
    func testArtifactNamesAreSanitizedAndCapped() {
        let many = (0..<8).map { "file\($0).png" }
        var dict = WatchMessage.reply(
            WatchReply(requestId: UUID(), ok: true, artifactNames: many)).encode()
        guard case let .reply(capped)? = WatchMessage.decode(dict) else { return XCTFail() }
        XCTAssertEqual(capped.artifactNames.count, WatchMessage.maxArtifactNames)

        dict["artifactNames"] = ["a\nb\rc.png", "   ", String(repeating: "x", count: 200)]
        guard case let .reply(clean)? = WatchMessage.decode(dict) else { return XCTFail() }
        XCTAssertEqual(clean.artifactNames.count, 2, "the blank name is dropped")
        XCTAssertFalse(clean.artifactNames[0].contains("\n"))
        XCTAssertFalse(clean.artifactNames[0].contains("\r"))
        XCTAssertLessThanOrEqual(clean.artifactNames[1].count, 60)
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

    // MARK: - The registration envelope (bridge acceptance)

    func testRegisteredRoundTrips() throws {
        let msg = WatchMessage.registered(
            WatchRegistered(requestId: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                            conversationId: "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84"))
        let decoded = WatchMessage.decode(msg.encode())
        XCTAssertEqual(decoded, msg)
    }

    func testRegisteredWithoutAConversationIsRejected() {
        // A registration whose whole purpose is naming the conversation is malformed without
        // one: rejected, not decoded into an empty id the watch would act on.
        var dict = WatchMessage.registered(
            WatchRegistered(requestId: UUID(), conversationId: "c")).encode()
        dict["conversationId"] = nil
        XCTAssertNil(WatchMessage.decode(dict))
        dict["conversationId"] = ""
        XCTAssertNil(WatchMessage.decode(dict))
        dict["conversationId"] = 42          // not a String
        XCTAssertNil(WatchMessage.decode(dict))
    }

    func testRegisteredCarriesOnlyPropertyListTypes() throws {
        // Every transport (sendMessage / transferUserInfo / transferFile metadata) requires
        // property-list values, so the new envelope must not smuggle anything else in.
        let dict = WatchMessage.registered(
            WatchRegistered(requestId: UUID(), conversationId: "c")).encode()
        XCTAssertTrue(PropertyListSerialization.propertyList(dict, isValidFor: .binary))
    }
}
