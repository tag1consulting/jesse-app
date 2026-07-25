import XCTest
@testable import JesseNetworking

/// The `GET /jesse/conversations` body: the conversation rows, the alias list a client binds
/// its pre-upgrade threads with, and the `deleted` tombstone array. Every field but
/// `conversation_id` defaults, so an added or omitted field never fails the whole decode.
final class ConversationsDeletedWireTests: XCTestCase {

    func testDecodesConversationsAndDeletedArray() throws {
        let json = """
        {
          "conversations": [
            {"conversation_id": "c1", "session_id": "s2",
             "session_ids": ["s1", "s2"],
             "last_modified": 1700000000, "first_message": "hi", "title": "Titled",
             "favorite": true, "favorite_updated_ms": 5,
             "archived": false, "archived_updated_ms": 0,
             "registered_ms": 1700000000123}
          ],
          "deleted": [
            {"conversation_id": "gone", "deleted_ms": 1700000123456}
          ]
        }
        """.data(using: .utf8)!
        let body = try JSONDecoder().decode(JesseConversationsBody.self, from: json)
        XCTAssertEqual(body.conversations.map(\.conversationId), ["c1"])
        let c = body.conversations[0]
        XCTAssertEqual(c.sessionId, "s2", "the CURRENT session")
        XCTAssertEqual(c.sessionIds, ["s1", "s2"], "the full ordered alias list, oldest first")
        XCTAssertEqual(c.title, "Titled")
        XCTAssertTrue(c.favorite)
        XCTAssertEqual(c.favoriteUpdatedMs, 5)
        XCTAssertEqual(c.registeredMs, 1700000000123)
        XCTAssertEqual(body.deleted,
                       [ConversationTombstone(conversationId: "gone", deletedMs: 1700000123456)])
    }

    func testAConversationWithNoSessionDecodesWithANilSessionId() throws {
        // The in-flight row: registered at accept time, no transcript yet. `session_id` is
        // JSON null and `session_ids` empty; both must decode rather than fail.
        let json = """
        { "conversations": [ {"conversation_id": "c-new", "session_id": null,
                              "session_ids": [], "last_modified": 1700000000,
                              "first_message": null, "title": null,
                              "registered_ms": 1700000000999} ] }
        """.data(using: .utf8)!
        let body = try JSONDecoder().decode(JesseConversationsBody.self, from: json)
        XCTAssertNil(body.conversations[0].sessionId)
        XCTAssertTrue(body.conversations[0].sessionIds.isEmpty)
        XCTAssertTrue(body.deleted.isEmpty, "an omitted `deleted` decodes to empty")
    }
}
