import XCTest
@testable import Jesse

/// (M6) The bridge wire contract is now Codable structs with shared CodingKeys
/// instead of hand-built `[String: Any]` + `obj["…"] as? T` casts. These tests pin
/// (a) the exact request bytes on the wire — so the bridge contract is unchanged —
/// and (b) the decode of every response shape, including the omit-when-default
/// behavior the old conditionally-built dictionary had.
@MainActor
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
                                        conversationId: nil,
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
                                        conversationId: nil,
                                        voice: true, instructions: "WRAP",
                                        floorOverride: "FLOOR", attachments: [att])
        let expected = #"{"attachments":[{"data_base64":"AQID","filename":"a.png","mime":"image/png"}],"floor_override":"FLOOR","instructions":"WRAP","mode":"tell","session_id":"sess-1","text":"note","voice":true}"#
        XCTAssertEqual(try body(r), expected)
    }

    /// "Use the bridge default" (blank override, false voice) drops the field from
    /// the bytes — same as the old conditional insert.
    func testBlankOverridesAndFalseVoiceAreOmittedFromBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil,
                                        conversationId: nil,
                                        voice: false, instructions: "  ",
                                        floorOverride: "\n\t", attachments: [])
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A present `health_context` block encodes to the `health_context` wire key,
    /// in sorted position, with the newline escaped — byte-for-byte.
    func testHealthContextEncodesToExactBytes() throws {
        let r = JesseClient.makeRequest(mode: .tell, text: "log my swim", sessionId: nil,
                                        conversationId: nil,
                                        voice: false, instructions: nil, floorOverride: nil,
                                        attachments: [], healthContext: "Swim 30m\nWalk 45m")
        XCTAssertEqual(try body(r),
            #"{"health_context":"Swim 30m\nWalk 45m","mode":"tell","text":"log my swim"}"#)
    }

    /// A nil or blank `health_context` drops the field — an ordinary turn (feature
    /// off, no data, or an old build) is byte-for-byte unchanged.
    func testNilAndBlankHealthContextOmittedFromBytes() throws {
        let none = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                           instructions: nil, floorOverride: nil, attachments: [])
        XCTAssertEqual(try body(none), #"{"mode":"ask","text":"hi"}"#)
        let blank = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                            instructions: nil, floorOverride: nil,
                                            attachments: [], healthContext: "  \n\t")
        XCTAssertEqual(try body(blank), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A fulfillment retry carries `health_context` + `health_context_requested`;
    /// an unfulfillable retry carries only `health_context_unavailable`. Both flags
    /// are true-or-omitted (a false flag would be meaningless to the bridge).
    func testHealthRequestFlagsEncodeToExactBytes() throws {
        let fulfilled = JesseClient.makeRequest(
            mode: .ask, text: "how am I doing?", sessionId: "s1", conversationId: nil, voice: false,
            instructions: nil, floorOverride: nil, attachments: [],
            healthContext: "RHR 58", healthContextRequested: true)
        XCTAssertEqual(try body(fulfilled),
            #"{"health_context":"RHR 58","health_context_requested":true,"mode":"ask","session_id":"s1","text":"how am I doing?"}"#)

        let unavailable = JesseClient.makeRequest(
            mode: .ask, text: "how am I doing?", sessionId: "s1", conversationId: nil, voice: false,
            instructions: nil, floorOverride: nil, attachments: [],
            healthContextUnavailable: true)
        XCTAssertEqual(try body(unavailable),
            #"{"health_context_unavailable":true,"mode":"ask","session_id":"s1","text":"how am I doing?"}"#)
    }

    /// A false/nil flag drops out — an ordinary turn never carries the retry flags.
    func testFalseHealthFlagsOmittedFromBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                        instructions: nil, floorOverride: nil, attachments: [],
                                        healthContextRequested: false, healthContextUnavailable: false)
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// A positive `meal_corrections_ack` (JESSE_MEAL_LOG v2) encodes to the wire key in
    /// sorted position; a nil/zero ack drops the field (an ordinary turn is unchanged).
    func testMealCorrectionsAckEncodesToExactBytes() throws {
        let acked = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                            instructions: nil, floorOverride: nil, attachments: [],
                                            mealCorrectionsAck: 42)
        XCTAssertEqual(try body(acked),
            #"{"meal_corrections_ack":42,"mode":"ask","text":"hi"}"#)

        for absent in [nil, 0] as [Int?] {
            let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                            instructions: nil, floorOverride: nil, attachments: [],
                                            mealCorrectionsAck: absent)
            XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#,
                           "a nil/zero ack drops the field")
        }
    }

    /// The outbox idempotency key encodes to the `request_id` wire key (as the
    /// UUID's string form), in sorted position — byte-for-byte.
    func testRequestIdEncodesToExactBytes() throws {
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                        instructions: nil, floorOverride: nil, attachments: [],
                                        requestId: id)
        XCTAssertEqual(try body(r),
            #"{"mode":"ask","request_id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","text":"hi"}"#)
    }

    /// A nil `requestId` drops the field — every non-outbox call (watch relay,
    /// health-context retry) is byte-for-byte unchanged.
    func testNilRequestIdOmittedFromBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                        instructions: nil, floorOverride: nil, attachments: [],
                                        requestId: nil)
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#)
    }

    /// The per-turn `model` selection encodes the bridge's `model` key in sorted position.
    func testModelEncodesToExactBytes() throws {
        let r = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                        instructions: nil, floorOverride: nil, attachments: [],
                                        requestId: nil, model: "glm-5.2")
        // `.sortedKeys` orders the keys: "mode" < "model" (a prefix) < "text".
        XCTAssertEqual(try body(r), #"{"mode":"ask","model":"glm-5.2","text":"hi"}"#)
    }

    /// A nil or blank `model` drops the field — a thread with no selection (and no device
    /// default) sends byte-for-byte today's request, so the bridge uses its stored default.
    func testNilAndBlankModelOmittedFromBytes() throws {
        let none = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                           instructions: nil, floorOverride: nil, attachments: [],
                                           requestId: nil, model: nil)
        XCTAssertEqual(try body(none), #"{"mode":"ask","text":"hi"}"#)
        let blank = JesseClient.makeRequest(mode: .ask, text: "hi", sessionId: nil, conversationId: nil, voice: false,
                                            instructions: nil, floorOverride: nil, attachments: [],
                                            requestId: nil, model: "   ")
        XCTAssertEqual(try body(blank), #"{"mode":"ask","text":"hi"}"#)
    }

    /// Response decoding is unchanged by the request_id addition: a 202 still yields
    /// a running job id (the bridge ignores an unknown `request_id`; nothing about
    /// the response shape changed).
    func testResponseDecodingUnchangedWithRequestId() throws {
        let json = Data(#"{"job_id":"job-idem","status":"running"}"#.utf8)
        guard case .running(let id, let conversationId) =
                try JesseClient.decodeSend(data: json, resp: http(202)) else {
            return XCTFail("expected .running")
        }
        XCTAssertEqual(id, "job-idem")
        XCTAssertNil(conversationId,
                     "a bridge that omits conversation_id decodes cleanly to nil, so the local id stands")
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

    // MARK: - location channel wire contract

    /// A location retry's exact bytes: the block plus the `requested` flag, and
    /// NOTHING from the health channel — the two channels never bleed into each
    /// other's fields, which is what stops one retry's flags being read as the
    /// other's.
    func testLocationContextRequestEncodesToExactBytes() throws {
        let r = JesseClient.makeRequest(
            mode: .ask, text: "coffee near me?", sessionId: "s1",
            conversationId: "c1", voice: false, instructions: nil,
            floorOverride: nil, attachments: [],
            locationContext: "Near: Edinburgh EH3",
            locationContextRequested: true)
        XCTAssertEqual(
            try body(r),
            #"{"conversation_id":"c1","location_context":"Near: Edinburgh EH3","location_context_requested":true,"mode":"ask","session_id":"s1","text":"coffee near me?"}"#)
    }

    /// The unavailable terminator's bytes: no block, the flag alone. This is the
    /// shape a denied permission produces, and it is what makes the bridge append
    /// "answer without it and do not ask again this turn".
    func testLocationUnavailableEncodesTheFlagAlone() throws {
        let r = JesseClient.makeRequest(
            mode: .ask, text: "coffee near me?", sessionId: nil,
            conversationId: nil, voice: false, instructions: nil,
            floorOverride: nil, attachments: [],
            locationContextUnavailable: true)
        XCTAssertEqual(
            try body(r),
            #"{"location_context_unavailable":true,"mode":"ask","text":"coffee near me?"}"#)
    }

    /// A blank block and `false` flags all drop out, so a build that sets them to
    /// their defaults is byte-for-byte one that predates the channel.
    func testLocationDefaultsAreOmittedEntirely() throws {
        let r = JesseClient.makeRequest(
            mode: .ask, text: "hi", sessionId: nil, conversationId: nil,
            voice: false, instructions: nil, floorOverride: nil, attachments: [],
            locationContext: "   ",
            locationContextRequested: false,
            locationContextUnavailable: false)
        XCTAssertEqual(try body(r), #"{"mode":"ask","text":"hi"}"#,
                       "a blank block and false flags produce the pre-location bytes")
    }

    /// A `done` result carrying `directives.needs_location` decodes to a validated
    /// `NeedsLocationRequest` on the reply.
    func testDecodeResultDoneWithLocationDirective() throws {
        let json = #"{"status":"done","response":"","session_id":"s1","directives":{"needs_location":{"fields":["placemark","accuracy"],"precision":"coarse","max_age_seconds":300}}}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        let needs = reply.needsLocationRequest
        XCTAssertEqual(needs?.fields, [.placemark, .accuracy])
        XCTAssertEqual(needs?.precision, .coarse)
        XCTAssertEqual(needs?.maxAgeSeconds, 300)
        // And it dispatches as the LOCATION channel, not health.
        XCTAssertEqual(reply.deviceContextRequest, .location(needs!))
        XCTAssertNil(reply.needsHealthRequest)
    }

    /// No `directives` at all → nil on both channels. Backward compatible with a
    /// bridge that predates the location channel.
    func testDecodeResultWithoutLocationDirective() throws {
        let json = #"{"status":"done","response":"the answer","session_id":"s1"}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertNil(reply.directives)
        XCTAssertNil(reply.needsLocationRequest)
        XCTAssertNil(reply.deviceContextRequest)
    }

    /// A `directives` object carrying only `needs_health` leaves `needs_location`
    /// nil — an older bridge's shape decodes cleanly rather than throwing.
    func testDecodeResultHealthOnlyDirectivesLeavesLocationNil() throws {
        let json = #"{"status":"done","response":"","session_id":"s1","directives":{"needs_health":{"sections":["daily"]}}}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertNotNil(reply.needsHealthRequest)
        XCTAssertNil(reply.directives?.needsLocation)
        XCTAssertNil(reply.needsLocationRequest)
    }

    /// Invalid payloads DECODE (so one bad directive never throws away the whole
    /// turn) and then validate to nil — never a partially-valid request, and in
    /// particular never a reading at a precision the reply did not name.
    func testDecodeResultInvalidLocationDirectiveValidatesToNil() throws {
        let cases = [
            (#"{"fields":["altitude"],"precision":"coarse","max_age_seconds":60}"#, "off-whitelist field"),
            (#"{"fields":["placemark"],"precision":"exact","max_age_seconds":60}"#, "unknown precision"),
            (#"{"fields":["placemark"],"precision":"coarse","max_age_seconds":901}"#, "age over the ceiling"),
            (#"{"fields":["placemark"],"precision":"coarse","max_age_seconds":-1}"#, "negative age"),
            (#"{"fields":[],"precision":"coarse","max_age_seconds":60}"#, "empty fields"),
            (#"{"fields":["placemark"],"max_age_seconds":60}"#, "missing precision"),
            (#"{"fields":["placemark"],"precision":"coarse"}"#, "missing age"),
            (#"{"precision":"coarse","max_age_seconds":60}"#, "missing fields"),
        ]
        for (payload, why) in cases {
            let json = #"{"status":"done","response":"","session_id":"s1","directives":{"needs_location":"# + payload + "}}"
            let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
            guard case .done(let reply) = s else { return XCTFail("expected .done (\(why))") }
            XCTAssertNotNil(reply.directives?.needsLocation, "decoded, but… (\(why))")
            XCTAssertNil(reply.needsLocationRequest, "validation rejects: \(why)")
            XCTAssertNil(reply.deviceContextRequest, "and it never dispatches: \(why)")
        }
    }

    /// The device-registration body — one key, matching the old `["token": …]`.
    func testDeviceRegistrationEncodesToExactBytes() throws {
        let data = try JesseClient.encodeBody(JesseDeviceRegistration(token: "apns-tok"))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"token":"apns-tok"}"#)
    }

    // MARK: - decodeSend (POST /jesse response)

    func testDecodeSend202ReturnsRunningJobId() throws {
        let json = Data(#"{"job_id":"job-1","status":"running"}"#.utf8)
        guard case .running(let id, _) = try JesseClient.decodeSend(data: json, resp: http(202)) else {
            return XCTFail("expected .running")
        }
        XCTAssertEqual(id, "job-1")
    }

    /// The 202 carries the AUTHORITATIVE conversation the bridge registered, which is what
    /// closes the window where the server knew a thread identifier the client did not.
    func testDecodeSend202CarriesTheRegisteredConversationId() throws {
        let json = Data(#"{"job_id":"job-1","conversation_id":"0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84","status":"running"}"#.utf8)
        guard case .running(let id, let conversationId) =
                try JesseClient.decodeSend(data: json, resp: http(202)) else {
            return XCTFail("expected .running")
        }
        XCTAssertEqual(id, "job-1")
        XCTAssertEqual(conversationId, "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84")
    }

    func testDecodeSend200ReturnsReplyWithSessionAndJobId() throws {
        let json = Data(#"{"response":"hello","session_id":"s","job_id":"j","conversation_id":"0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84"}"#.utf8)
        guard case .reply(let reply, let jobId, let conversationId) =
                try JesseClient.decodeSend(data: json, resp: http(200)) else {
            return XCTFail("expected .reply")
        }
        XCTAssertEqual(reply.text, "hello")
        XCTAssertEqual(reply.sessionId, "s")
        XCTAssertEqual(jobId, "j")
        XCTAssertEqual(conversationId, "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84")
    }

    /// `conversation_id` rides the request body on EVERY turn.
    func testRequestCarriesTheConversationId() throws {
        let req = JesseClient.makeRequest(
            mode: .ask, text: "hi", sessionId: nil,
            conversationId: "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84", voice: false,
            instructions: nil, floorOverride: nil, attachments: [])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JesseClient.encodeBody(req)) as? [String: Any])
        XCTAssertEqual(obj["conversation_id"] as? String, "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84")
        // A blank id omits the key, which is the OLDER-client shape (the bridge then mints
        // one), never what a current caller should produce.
        let blank = JesseClient.makeRequest(
            mode: .ask, text: "hi", sessionId: nil, conversationId: "  ", voice: false,
            instructions: nil, floorOverride: nil, attachments: [])
        let blankObj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JesseClient.encodeBody(blank)) as? [String: Any])
        XCTAssertNil(blankObj["conversation_id"])
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
        XCTAssertEqual(JesseClient.decodeStreamFrame(event: "activity", data: #"{"name":"Read"}"#), .activity(ToolActivity(name: "Read")))
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
