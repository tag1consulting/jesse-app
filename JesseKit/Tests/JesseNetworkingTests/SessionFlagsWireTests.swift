import XCTest
@testable import JesseNetworking

// The wire contract for the favorite/archive sync fields (bridge 0.25.0): the four flag
// fields decode off a `GET /jesse/sessions` summary, default cleanly when a pre-0.25.0
// bridge omits them, and the `POST .../flags` request body sends only the changed
// flag(s) under the bridge's snake_case keys.
final class SessionFlagsWireTests: XCTestCase {

    private func decodeSummary(_ json: String) throws -> SessionSummary {
        try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    func testSummaryDecodesAllFlagFields() throws {
        let s = try decodeSummary("""
        {
          "session_id": "abc",
          "last_modified": 1700000000,
          "first_message": "hi",
          "title": "Greeting",
          "favorite": true,
          "favorite_updated_ms": 1700000000123,
          "archived": true,
          "archived_updated_ms": 1700000000456
        }
        """)
        XCTAssertEqual(s.sessionId, "abc")
        XCTAssertTrue(s.favorite)
        XCTAssertEqual(s.favoriteUpdatedMs, 1_700_000_000_123)
        XCTAssertTrue(s.archived)
        XCTAssertEqual(s.archivedUpdatedMs, 1_700_000_000_456)
    }

    func testSummaryDefaultsFlagsWhenAbsent() throws {
        // A pre-0.25.0 bridge omits the flag fields entirely; the summary must still
        // decode, reading the flags as unset with zero clocks (local-only behavior).
        let s = try decodeSummary("""
        { "session_id": "abc", "last_modified": 1700000000, "first_message": null, "title": null }
        """)
        XCTAssertFalse(s.favorite)
        XCTAssertEqual(s.favoriteUpdatedMs, 0)
        XCTAssertFalse(s.archived)
        XCTAssertEqual(s.archivedUpdatedMs, 0)
    }

    func testSummaryStillRequiresCoreFields() {
        // A missing required field is still a hard decode error (the flag defaulting
        // must not weaken the rest of the contract).
        XCTAssertThrowsError(try decodeSummary(#"{ "last_modified": 1 }"#))
    }

    private func encode(_ req: JesseFlagsRequest) throws -> [String: Any] {
        let data = try JesseBridgeClient.encodeBody(req)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFavoriteOnlyRequestOmitsArchivedKeys() throws {
        let obj = try encode(JesseFlagsRequest(favorite: true, favoriteUpdatedMs: 123))
        XCTAssertEqual(obj["favorite"] as? Bool, true)
        XCTAssertEqual(obj["favorite_updated_ms"] as? UInt64, 123)
        XCTAssertNil(obj["archived"], "an unset flag omits its key so the server register is untouched")
        XCTAssertNil(obj["archived_updated_ms"])
    }

    func testArchivedOnlyRequestOmitsFavoriteKeys() throws {
        let obj = try encode(JesseFlagsRequest(archived: false, archivedUpdatedMs: 999))
        XCTAssertEqual(obj["archived"] as? Bool, false)
        XCTAssertEqual(obj["archived_updated_ms"] as? UInt64, 999)
        XCTAssertNil(obj["favorite"])
        XCTAssertNil(obj["favorite_updated_ms"])
    }
}
