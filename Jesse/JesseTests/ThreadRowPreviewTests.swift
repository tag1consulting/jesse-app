import XCTest
@testable import Jesse

final class ThreadRowPreviewTests: XCTestCase {

    private func thread(turns: [(TurnRole, String)]) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        return t
    }

    func testEmptyThreadHasNoPreview() {
        XCTAssertEqual(rowPreview(for: thread(turns: [])), "")
    }

    func testPreviewIsLatestTurn() {
        // The preview reflects where the conversation went — the latest turn —
        // not the first user message that seeds the title.
        let t = thread(turns: [
            (.user, "what's on today?"),
            (.jesse, "You have a dentist appointment at 3pm."),
        ])
        XCTAssertEqual(rowPreview(for: t), "You have a dentist appointment at 3pm.")
    }

    func testPreviewFallsBackToLastUserTurnWhenNoReply() {
        let t = thread(turns: [(.user, "remind me to call the plumber")])
        XCTAssertEqual(rowPreview(for: t), "remind me to call the plumber")
    }

    func testPreviewCollapsesWhitespaceToSingleLine() {
        let t = thread(turns: [
            (.user, "q"),
            (.jesse, "  line one\n\nline two\t  line three  "),
        ])
        XCTAssertEqual(rowPreview(for: t), "line one line two line three")
    }
}
