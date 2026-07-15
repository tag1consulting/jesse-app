import XCTest
@testable import Jesse

/// Model-badge v2: the app decodes structured `provenance` from the poll result and
/// the SSE `done` frame, strips the trailing text badge (and the emergency
/// citations-unverified warning) from the displayed message, and renders a native chip
/// instead. When provenance is ABSENT (older bridge / badges off) the text is shown
/// verbatim. The exact strings are pinned by the shared bridge fixture, read here from
/// disk so the app and the bridge can never drift.
final class ProvenanceTests: XCTestCase {

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h:8765/jesse")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Wire decode (poll + SSE)

    func testPollDecodeCarriesProvenanceAndStripsBadge() throws {
        let json = #"""
        {"status":"done","response":"Here is your answer.\n\n[hosted · claude-opus-4-8]","session_id":"s1","provenance":{"route":"hosted","model":"claude-opus-4-8","badge":"[hosted · claude-opus-4-8]","flags":{"hosted_verify":false,"verify_queued":false,"citations_unverified":false}}}
        """#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertEqual(reply.provenance?.route, "hosted")
        XCTAssertEqual(reply.provenance?.model, "claude-opus-4-8")
        XCTAssertEqual(reply.provenance?.badge, "[hosted · claude-opus-4-8]")
        // The bubble shows the clean body — the badge is stripped into the chip.
        XCTAssertEqual(reply.displayText, "Here is your answer.")
    }

    func testPollDecodeWithoutProvenanceShowsTextVerbatim() throws {
        // Older bridge: no `provenance`. The reply text (badge and all) is shown as-is.
        let json = #"{"status":"done","response":"Answer.\n\n[hosted]","session_id":"s1"}"#
        let s = try JesseClient.decodeResult(data: Data(json.utf8), resp: http(200))
        guard case .done(let reply) = s else { return XCTFail("expected .done") }
        XCTAssertNil(reply.provenance)
        XCTAssertEqual(reply.displayText, "Answer.\n\n[hosted]", "no provenance → verbatim fallback")
    }

    func testSSEDoneFrameCarriesProvenance() throws {
        let data = #"""
        {"response":"Logged: oatmeal, 320 kcal.\n\n[local · diet · local-oss + hosted verify]","session_id":"s","provenance":{"route":"diet-local","model":"local-oss","badge":"[local · diet · local-oss + hosted verify]","flags":{"hosted_verify":true,"verify_queued":false,"citations_unverified":false}}}
        """#
        guard let event = JesseClient.decodeStreamFrame(event: "done", data: data),
              case .done(let reply) = event else { return XCTFail("expected .done frame") }
        XCTAssertEqual(reply.provenance?.route, "diet-local")
        XCTAssertTrue(reply.provenance?.flags.hostedVerify == true)
        XCTAssertEqual(reply.displayText, "Logged: oatmeal, 320 kcal.")
    }

    // MARK: - Presentation mapping (pure)

    func testPresentationPerRoute() {
        func prov(_ route: String, hv: Bool = false, vq: Bool = false, cu: Bool = false) -> JesseProvenance {
            JesseProvenance(route: route, model: "m", badge: "[b]",
                            flags: JesseProvenanceFlags(hostedVerify: hv, verifyQueued: vq, citationsUnverified: cu))
        }
        XCTAssertEqual(prov("hosted").routeKind, .hosted)
        XCTAssertEqual(prov("hosted").label, "Hosted")
        XCTAssertEqual(prov("vaultqa-local").routeKind, .local)
        XCTAssertEqual(prov("vaultqa-local").label, "Local · vault")
        XCTAssertEqual(prov("diet-local").routeKind, .local)
        XCTAssertEqual(prov("diet-local").label, "Local · diet")
        XCTAssertEqual(prov("emergency-local").routeKind, .emergency)
        XCTAssertEqual(prov("emergency-local").label, "Emergency")
        // A queued-verify diet Tell (route emergency-local, verify_queued) reads as queued.
        XCTAssertEqual(prov("emergency-local", vq: true).label, "Queued for verify")
        // The unverified emergency answer forces the warning state regardless of route.
        let warn = prov("emergency-local", cu: true)
        XCTAssertEqual(warn.routeKind, .warning)
        XCTAssertTrue(warn.isWarning)
        XCTAssertEqual(warn.iconName, "exclamationmark.triangle.fill")
    }

    // MARK: - Persistence round-trip

    func testProvenanceJSONRoundTrips() throws {
        let p = JesseProvenance(route: "emergency-local", model: "local-oss",
                                badge: "[local · emergency · local-oss]",
                                flags: JesseProvenanceFlags(hostedVerify: false, verifyQueued: false, citationsUnverified: true))
        let json = try XCTUnwrap(p.jsonString)
        let back = try XCTUnwrap(JesseProvenance.from(json: json))
        XCTAssertEqual(back, p)
        // Malformed / nil → nil (no chip).
        XCTAssertNil(JesseProvenance.from(json: nil))
        XCTAssertNil(JesseProvenance.from(json: "not json"))
    }

    // MARK: - Shared fixture (bridge <-> app contract, read from disk)

    private struct Fixture: Decodable {
        let citationsUnverifiedWarning: String
        let cases: [Case]
        enum CodingKeys: String, CodingKey {
            case citationsUnverifiedWarning = "citations_unverified_warning"
            case cases
        }
        struct Case: Decodable {
            let name: String
            let provenance: JesseProvenance
            let replyBody: String
            let replyText: String
            enum CodingKeys: String, CodingKey {
                case name, provenance
                case replyBody = "reply_body"
                case replyText = "reply_text"
            }
        }
    }

    /// Resolve the shared fixture relative to THIS source file, so the same on-disk file
    /// the Rust bridge test asserts against is the one the app test asserts against.
    private func loadFixture(file: StaticString = #filePath) throws -> Fixture {
        // <repo>/Jesse/JesseTests/ProvenanceTests.swift → up 3 → <repo>.
        let here = URL(fileURLWithPath: "\(file)")
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("bridge/tests/fixtures/provenance.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testSharedFixtureWarningMatchesTheAppConstant() throws {
        let fx = try loadFixture()
        XCTAssertEqual(citationsUnverifiedWarning, fx.citationsUnverifiedWarning,
                       "the app's warning constant must equal the bridge's (shared fixture)")
    }

    func testSharedFixtureStripAndDisplayPerRoute() throws {
        let fx = try loadFixture()
        XCTAssertFalse(fx.cases.isEmpty, "fixture has cases")
        for c in fx.cases {
            // Direct strip: the exact bridge-assembled reply text reduces to the body.
            XCTAssertEqual(c.provenance.strip(from: c.replyText), c.replyBody,
                           "strip(\(c.name)) → body")
            // End-to-end via the real display path: a JesseReply built from the wire
            // reply_text + provenance shows the clean body in the bubble.
            let reply = JesseReply(text: c.replyText, sessionId: nil, provenance: c.provenance)
            XCTAssertEqual(reply.displayText, c.replyBody, "displayText(\(c.name)) → body")
            // The chip has a non-empty label and a sane warning flag for every case.
            XCTAssertFalse(c.provenance.label.isEmpty, "label(\(c.name))")
            XCTAssertEqual(c.provenance.isWarning, c.provenance.flags.citationsUnverified)
        }
    }
}
