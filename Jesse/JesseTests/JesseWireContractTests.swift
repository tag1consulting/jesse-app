import XCTest
@testable import Jesse

/// (M6) The bridge wire contract is now Codable structs with shared CodingKeys
/// instead of hand-built `[String: Any]` + `obj["…"] as? T` casts. These tests pin
/// (a) the exact request bytes on the wire — so the bridge contract is unchanged —
/// and (b) the decode of every response shape, including the omit-when-default
/// behavior the old conditionally-built dictionary had.
final class JesseWireContractTests: XCTestCase {

    private func http(_ status: Int, path: String = "/jesse") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h:8765\(path)")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func body(_ r: JesseRequest) throws -> String {
        String(data: try JesseClient.encodeBody(r), encoding: .utf8)!
    }

    // MARK: - POST /jesse request bytes (byte-for-byte against a captured body)

    /// An ordinary turn carries ONLY mode + text — every optional field omitted,
    /// exactly as the old dictionary built it.
    func testMinimalRequestEncodesToExactBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: nil,
                                        floorOverride: nil, attachments: [])
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// Every field present, including an attachment. Keys are sorted (the encoder's
    /// `.sortedKeys`) and slashes unescaped, so the bytes are stable and readable
    /// for the bridge's serde, which accepts any key order.
    func testFullRequestEncodesToExactBytes() throws {
        let att = JesseAttachment(filename: "a.png", mime: "image/png",
                                  data: Data([0x01, 0x02, 0x03]))
        let r = JesseClient.makeRequest(mode: .tell, text: "note", sessionId: "sess-1",
                                        voice: true, instructions: "WRAP",
                                        floorOverride: "FLOOR", attachments: [att])
        let expected = #"{"attachments":[{"data_base64":"AQID","filename":"a.png","mime":"image/png"}],"floor_override":"FLOOR","instructions":"WRAP","mode":"tell","session_id":"sess-1","text":"note","voice":true}"#
        XCTAssertEqual(try body(r), expected)
    }

    /// "Use the bridge default" (blank override, false voice) drops the field from
    /// the bytes — same as the old conditional insert.
    func testBlankOverridesAndFalseVoiceAreOmittedFromBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: "  ",
                                        floorOverride: "\n\t", attachments: [])
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A present `health_context` block encodes to the `health_context` wire key,
    /// in sorted position, with the newline escaped — byte-for-byte.
    func testHealthContextEncodesToExactBytes() throws {
        let r = JesseClient.makeRequest(mode: .tell, text: "log my swim", sessionId: nil,
                                        voice: false, instructions: nil, floorOverride: nil,
                                        attachments: [], healthContext: "Swim 30m\nWalk 45m")
        XCTAssertEqual(try body(r),
            #"{"health_context":"Swim 30m\nWalk 45m","mode":"tell","text":"log my swim"}"#)
    }

    /// A nil or blank `health_context` drops the field — an ordinary turn (feature
    /// off, no data, or an old build) is byte-for-byte unchanged.
    func testNilAndBlankHealthContextOmittedFromBytes() throws {
        let none = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, voice: false,
                                           instructions: nil, floorOverride: nil, attachments: [])
        XCTAssertEqual(try body(none), #"{"mode":"ask","text":"hi"}"#)
        let blank = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, voice: false,
                                            instructions: nil, floorOverride: nil,
                                            attachments: [], healthContext: "  \n\t")
        XCTAssertEqual(try body(blank), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A fulfillment retry carries `health_context` + `health_context_requested`;
    /// an unfulfillable retry carries only `health_context_unavailable`. Both flags
    /// are true-or-omitted (a false flag would be meaningless to the bridge).
    func testHealthRequestFlagsEncodeToExactBytes() throws {
        let fulfilled = JesseClient.makeRequest(
            mode: .ask, text: "how am I doing?", sessionId: "s1", voice: false,
            instructions: nil, floorOverride: nil, attachments: [],
            healthContext: "RHR 58", healthContextRequested: true)
        XCTAssertEqual(try body(fulfilled),
            #"{"health_context":"RHR 58","health_context_requested":true,"mode":"ask","session_id":"s1","text":"how am I doing?"}"#)

        let unavailable = JesseClient.makeRequest(
            mode: .ask, text: "how am I doing?", sessionId: "s1", voice: false,
            instructions: nil, floorOverride: nil, attachments: [],
            healthContextUnavailable: true)
        XCTAssertEqual(try body(unavailable),
            #"{"health_context_unavailable":true,"mode":"ask","session_id":"s1","text":"how am I doing?"}"#)
    }

    /// A false/nil flag drops out — an ordinary turn never carries the retry flags.
    func testFalseHealthFlagsOmittedFromBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, voice: false,
                                        instructions: nil, floorOverride: nil, attachments: [],
                                        healthContextRequested: false, healthContextUnavailable: false)
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A positive `meal_corrections_ack` (JESSE_MEAL_LOG v2) encodes to the wire key in
    /// sorted position; a nil/zero ack drops the field (an ordinary turn is unchanged).
    func testMealCorrectionsAckEncodesToExactBytes() throws {
        let acked = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, voice: false,
                                            instructions: nil, floorOverride: nil, attachments: [],
                                            mealCorrectionsAck: 42)
        XCTAssertEqual(try body(acked),
            #"{"meal_corrections_ack":42,"mode":"ask","text":"hi"}"#)

        for absent in [nil, 0] as [Int?] {
            let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, voice: false,
                                            instructions: nil, floorOverride: nil, attachments: [],
                                            mealCorrectionsAck: absent)
            XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#,
                           "a nil/zero ack drops the field")
        }
    }

    // MARK: - directives decode (poll result)

    /// A `done` result carrying `directives.needs_health` decodes to a validated
    /// `NeedsHealthRequest` on the reply.
    func testDecodeResultDoneWithDirectives() throws {
        let json = #"{"status":"done","response":"","session_id":"s1","directives":{"needs_health":{"sections":["daily"],"metrics":[{"metric":"restingHeartRate","window_days":14}]}}}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        let needs = reply.needsHealthRequest
        XCTAssertEqual(needs?.sections, [.daily])
        XCTAssertEqual(needs?.metrics, [ValidatedMetricRequest(metric: .restingHeartRate, windowDays: 14)])
    }

    /// A `done` result with no `directives` (an ordinary reply) decodes to nil —
    /// backward compatible with a bridge/turn that emits none.
    func testDecodeResultDoneWithoutDirectives() throws {
        let json = #"{"status":"done","response":"the answer","session_id":"s1"}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertNil(reply.directives)
        XCTAssertNil(reply.needsHealthRequest)
    }

    /// An invalid directive (window out of range) decodes but the validated request
    /// is nil — the app never partially fulfills an invalid request.
    func testDecodeResultInvalidDirectiveValidatesToNil() throws {
        let json = #"{"status":"done","response":"","session_id":"s1","directives":{"needs_health":{"metrics":[{"metric":"stepCount","window_days":99}]}}}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertNotNil(reply.directives?.needsHealth, "decoded, but…")
        XCTAssertNil(reply.needsHealthRequest, "…validation rejects the out-of-range window")
    }

    /// The device-registration body — one key, matching the old `["token": …]`.
    func testDeviceRegistrationEncodesToExactBytes() throws {
        let data = try JesseClient.encodeBody(JesseDeviceRegistration(token: "apns-tok"))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"token":"apns-tok"}"#)
    }

    // MARK: - decodeSend (POST /jesse response)

    func testDecodeSend202ReturnsRunningJobId() throws {
        let json = Data(#"{"job_id":"job-1","status":"running"}"#.utf8)
        guard case .running(let id) = try JesseClient.decodeSend(data: json, resp: http(202)) else {
            return XCTFail("expected .running")
        }
        XCTAssertEqual(id, "job-1")
    }

    func testDecodeSend200ReturnsReplyWithSessionAndJobId() throws {
        let json = Data(#"{"response":"hello","session_id":"s","job_id":"j"}"#.utf8)
        guard case .reply(let reply, let jobId) = try JesseClient.decodeSend(data: json, resp: http(200)) else {
            return XCTFail("expected .reply")
        }
        XCTAssertEqual(reply.text, "hello")
        XCTAssertEqual(reply.sessionId, "s")
        XCTAssertEqual(jobId, "j")
    }

    func testDecodeSend202WithoutJobIdThrows() {
        let json = Data(#"{"status":"running"}"#.utf8)
        XCTAssertThrowsError(try JesseClient.decodeSend(data: json, resp: http(202)))
    }

    func testDecodeSendNon2xxThrowsBadResponse() {
        XCTAssertThrowsError(try JesseClient.decodeSend(data: Data("boom".utf8), resp: http(500)))
    }

    // MARK: - decodeResult (GET /jesse/result/{id})

    func testDecodeResultRunning() throws {
        let s = try JesseClient.decodeResult(data: Data(#"{"status":"running"}"#.utf8), resp: http(200))
        guard case .running = s else { return XCTFail("expected .running") }
    }

    func testDecodeResultDone() throws {
        let json = Data(#"{"status":"done","response":"the answer","session_id":"s2"}"#.utf8)
        guard case .done(let reply) = try JesseClient.decodeResult(data: json, resp: http(200)) else {
            return XCTFail("expected .done")
        }
        XCTAssertEqual(reply.text, "the answer")
        XCTAssertEqual(reply.sessionId, "s2")
    }

    func testDecodeResultFailedCarriesMessage() throws {
        let json = Data(#"{"status":"failed","error":"snag"}"#.utf8)
        guard case .failed(let msg) = try JesseClient.decodeResult(data: json, resp: http(200)) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(msg, "snag")
    }

    func testDecodeResultCancelled() throws {
        let json = Data(#"{"status":"cancelled"}"#.utf8)
        guard case .cancelled = try JesseClient.decodeResult(data: json, resp: http(200)) else {
            return XCTFail("expected .cancelled")
        }
    }

    func testDecodeResult404IsExpired() throws {
        guard case .expired = try JesseClient.decodeResult(data: Data(), resp: http(404)) else {
            return XCTFail("expected .expired")
        }
    }

    func testDecodeResultUnknownStatusThrows() {
        let json = Data(#"{"status":"weird"}"#.utf8)
        XCTAssertThrowsError(try JesseClient.decodeResult(data: json, resp: http(200)))
    }

    // MARK: - decodePrompts (GET /jesse/prompts)

    func testDecodePromptsValid() throws {
        let json = Data(#"{"ask":"A","tell":"T","ask_floor":"AF","tell_floor":"TF"}"#.utf8)
        let p = try JesseClient.decodePrompts(data: json, resp: http(200, path: "/jesse/prompts"))
        XCTAssertEqual(p.ask, "A")
        XCTAssertEqual(p.tell, "T")
        XCTAssertEqual(p.askFloor, "AF")
        XCTAssertEqual(p.tellFloor, "TF")
    }

    func testDecodePromptsMissingFloorThrows() {
        let json = Data(#"{"ask":"A","tell":"T"}"#.utf8)
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(200, path: "/jesse/prompts")))
    }

    // MARK: - decodeStreamFrame (SSE data payloads)

    func testDecodeStreamFrames() {
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "reset", data: #"{"text":"hi"}"#), .reset("hi"))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "delta", data: #"{"text":"x"}"#), .delta("x"))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "activity", data: #"{"name":"Read"}"#), .activity("Read"))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "done", data: #"{"response":"r","session_id":"s"}"#),
                       .done(JesseReply(text: "r", sessionId: "s")))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "error", data: #"{"error":"boom"}"#), .failed("boom"))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "cancelled", data: "{}"), .cancelled)
        XCTAssertNil(JesseClient.decodeStreamFrame(event: "mystery", data: "{}"))
    }

    /// A malformed/empty `data` falls back to the same defaults the old casts used.
    func testDecodeStreamFrameMalformedDataFallsBack() {
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "reset", data: "not json"), .reset(""))
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "error", data: ""),
                       .failed("Jesse couldn't complete that."))
    }
}
