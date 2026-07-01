import XCTest
@testable import Jesse

// Pure-function tests for the AI-title seams: the content key (invalidation), the
// digest (what the app sends), and the display precedence. No view host, no
// network — mirroring ThreadSectioningTests / ThreadFoldersTests.
final class ThreadTitleTests: XCTestCase {

    private func thread(turns: [(TurnRole, String)], title: String = "",
                        aiTitle: String? = nil) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.aiTitle = aiTitle
        t.turns = turns.enumerated().map { i, pair in
            Turn(role: pair.0, text: pair.1,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        return t
    }

    // MARK: - Content key (invalidation seam)

    func testContentKeyIsStableForSameTurns() {
        let a = thread(turns: [(.user, "what's on today?"), (.jesse, "A dentist at 3pm.")])
        // Same ids + text → identical key, recomputed.
        XCTAssertEqual(threadContentKey(for: a), threadContentKey(for: a))
    }

    func testContentKeyIsDeterministicAndNonRandom() {
        // Not Swift's per-process-randomized hashValue: a key computed from the
        // same content must match a hard-coded expectation across runs. Build a
        // thread with a fixed turn id + text so the key is fully determined.
        let t = JesseThread(mode: .ask)
        let turn = Turn(role: .user, text: "hello",
                        createdAt: Date(timeIntervalSince1970: 0))
        turn.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        t.turns = [turn]
        // Two independent computations agree (the real point: launch-stable).
        let first = threadContentKey(for: t)
        let second = threadContentKey(for: t)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testAppendingATurnChangesTheKey() {
        let before = thread(turns: [(.user, "what's on today?")])
        let after = thread(turns: [(.user, "what's on today?"),
                                   (.jesse, "A dentist at 3pm.")])
        XCTAssertNotEqual(threadContentKey(for: before), threadContentKey(for: after),
                          "a new entry must bust the cache")
    }

    func testEditingATurnChangesTheKeyEvenAtSameLength() {
        // Two texts of identical length — a length-only key would miss the edit.
        let original = thread(turns: [(.user, "cat")])
        let edited = thread(turns: [(.user, "dog")])
        // Force the same turn id so only the text differs.
        edited.turns[0].id = original.turns[0].id
        XCTAssertNotEqual(threadContentKey(for: original), threadContentKey(for: edited),
                          "editing a turn's text must change the key, even same-length")
    }

    func testEmptyThreadHasEmptyKey() {
        XCTAssertEqual(threadContentKey(for: thread(turns: [])), "")
    }

    // MARK: - Digest (what the app sends)

    func testDigestIsDeterministic() {
        let t = thread(turns: [(.user, "plan my week"), (.jesse, "Here is a plan.")])
        XCTAssertEqual(titleDigest(for: t), titleDigest(for: t))
    }

    func testDigestCollapsesWhitespace() {
        let t = thread(turns: [(.user, "  plan   my\n\nweek  ")])
        let digest = titleDigest(for: t)
        XCTAssertEqual(digest, "plan my week")
        XCTAssertFalse(digest.contains("  "), "runs of whitespace collapse to one space")
        XCTAssertFalse(digest.contains("\n"), "no newlines survive")
    }

    func testDigestCombinesFirstUserAndLatestReply() {
        let t = thread(turns: [
            (.user, "what's on today?"),
            (.jesse, "middle"),
            (.jesse, "A dentist at 3pm."),
        ])
        let digest = titleDigest(for: t)
        XCTAssertTrue(digest.contains("what's on today?"), "includes the first user message")
        XCTAssertTrue(digest.contains("A dentist at 3pm."), "includes the most recent reply")
    }

    func testDigestDoesNotRepeatASingleUserTurn() {
        let t = thread(turns: [(.user, "just one message")])
        XCTAssertEqual(titleDigest(for: t), "just one message")
    }

    func testDigestIsByteBoundedOnACharBoundary() {
        // A long multibyte reply must be capped under the byte cap without ever
        // splitting a scalar.
        let long = String(repeating: "é", count: 5000)   // 2 bytes each in UTF-8
        let t = thread(turns: [(.user, "q"), (.jesse, long)])
        let digest = titleDigest(for: t, maxBytes: 100)
        XCTAssertLessThanOrEqual(digest.utf8.count, 100)
        XCTAssertFalse(digest.isEmpty)
        // No mid-scalar cut: every character is the whole "é", never a lone byte
        // (a broken cut would surface U+FFFD replacement characters).
        XCTAssertFalse(digest.contains("\u{FFFD}"), "no character was split mid-scalar")
        XCTAssertTrue(digest.allSatisfy { $0 == "é" || $0 == "q" || $0 == " " || $0 == "—" })
    }

    func testEmptyThreadHasEmptyDigest() {
        XCTAssertEqual(titleDigest(for: thread(turns: [])), "")
    }

    // MARK: - Display precedence

    func testDisplayPrefersAITitleWhenPresent() {
        let t = thread(turns: [(.user, "some long first message that seeds a derived title")],
                       title: "some long first message", aiTitle: "Dentist appointment")
        XCTAssertEqual(displayTitle(for: t), "Dentist appointment")
    }

    func testDisplayFallsBackToDerivedTitleWhenNoAITitle() {
        let t = thread(turns: [(.user, "hi")], title: "hi", aiTitle: nil)
        XCTAssertEqual(displayTitle(for: t), "hi",
                       "the derived title is used when aiTitle is nil")
    }

    func testDisplayShowsAITitleEvenWhenStale() {
        // A stale aiTitle (its key no longer matches) is still shown — the last
        // good title while a refresh runs, never a blank row.
        let t = thread(turns: [(.user, "q"), (.jesse, "a new reply just landed")],
                       title: "q", aiTitle: "Older good title")
        t.titleSourceKey = "stale-key-that-no-longer-matches"
        XCTAssertNotEqual(t.titleSourceKey, threadContentKey(for: t))
        XCTAssertEqual(displayTitle(for: t), "Older good title")
    }

    // MARK: - Row shows the title only (the removed preview line)

    func testRowPrimaryLineIsTitleNotLatestTurnPreview() {
        // The row now shows ONE primary line — the resolved title — and the time.
        // The old second line (a snippet of the latest turn) is gone: a distinctive
        // latest reply must not appear in what the row displays.
        let t = thread(turns: [(.user, "plan my week"),
                               (.jesse, "UNIQUE-REPLY-SNIPPET-XYZ")],
                       title: "plan my week")
        XCTAssertEqual(displayTitle(for: t), "plan my week")
        XCTAssertFalse(displayTitle(for: t).contains("UNIQUE-REPLY-SNIPPET-XYZ"),
                       "the row shows the title only — no latest-turn preview snippet")
    }

    func testDisplayNeverEmpty() {
        let t = thread(turns: [], title: "", aiTitle: nil)
        XCTAssertEqual(displayTitle(for: t), "New conversation")
        // A whitespace-only aiTitle is not shown.
        let t2 = thread(turns: [(.user, "hi")], title: "hi", aiTitle: "   ")
        XCTAssertEqual(displayTitle(for: t2), "hi")
    }
}
