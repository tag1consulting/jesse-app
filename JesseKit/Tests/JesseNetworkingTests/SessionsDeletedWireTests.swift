import XCTest
@testable import JesseNetworking

/// The `deleted` tombstone array on `GET /jesse/sessions` (bridge 0.26.0): decoded when
/// present, defaulted to empty against a pre-0.26.0 bridge that omits it.
final class SessionsDeletedWireTests: XCTestCase {

    func testDecodesDeletedArray() throws {
        let json = """
        {
          "sessions": [
            {"session_id": "s1", "last_modified": 1700000000, "first_message": "hi", "title": null}
          ],
          "deleted": [
            {"session_id": "gone", "deleted_ms": 1700000123456}
          ]
        }
        """.data(using: .utf8)!
        let body = try JSONDecoder().decode(JesseSessionsBody.self, from: json)
        XCTAssertEqual(body.sessions.map(\.sessionId), ["s1"])
        XCTAssertEqual(body.deleted, [SessionTombstone(sessionId: "gone", deletedMs: 1700000123456)])
    }

    func testMissingDeletedDefaultsEmpty() throws {
        // A pre-0.26.0 bridge omits `deleted` entirely: it must decode to empty, not fail.
        let json = """
        { "sessions": [] }
        """.data(using: .utf8)!
        let body = try JSONDecoder().decode(JesseSessionsBody.self, from: json)
        XCTAssertTrue(body.deleted.isEmpty)
    }
}
