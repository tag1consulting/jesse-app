import XCTest
import JesseCore
@testable import JesseNetworking

/// The shared hydration merge. Two failure modes it exists to remove, one per platform:
/// iOS appended every hydrated turn unconditionally (a double bubble whenever a hydrate
/// overlapped turns already rendered), and macOS guarded the same path with a content-hash
/// multiset (which silently DROPPED a genuinely repeated message). The bridge's stable
/// `turn_key` replaces both with an identity.
final class TranscriptMergeTests: XCTestCase {

    private func existing(_ role: String, _ text: String, key: String? = nil) -> TranscriptMerge.Existing {
        TranscriptMerge.Existing(role: role, text: text, sourceKey: key)
    }

    private func incoming(_ role: String, _ text: String, _ key: String) -> HydratedTurn {
        HydratedTurn(role: role, text: text, timestamp: nil, turnKey: key)
    }

    func testAKeyAlreadyHeldIsSkipped() {
        // Steady state: an exact key comparison, no content involved at all.
        let plan = TranscriptMerge.plan(
            existing: [existing("user", "hello", key: "s:0")],
            incoming: [incoming("user", "hello", "s:0")])
        XCTAssertEqual(plan, [.skip])
    }

    func testAnUnkeyedOptimisticTurnIsBoundNotDuplicated() {
        // The transcript-flush-lag scenario: the local echo of a send is already rendered
        // with no key when the hydrate arrives. It must be UPGRADED, not duplicated.
        let plan = TranscriptMerge.plan(
            existing: [existing("user", "hello")],
            incoming: [incoming("user", "hello", "s:0")])
        XCTAssertEqual(plan, [.bind(existingIndex: 0)])
    }

    func testBindingIsOneTimeSoOngoingContentDedupCannotHappen() {
        // Once the key is bound, a DIFFERENT transcript line with the same text is a genuinely
        // new turn and must be inserted. This is the property that keeps the content match
        // from degenerating into content dedup.
        let plan = TranscriptMerge.plan(
            existing: [existing("user", "ok", key: "s:0")],
            incoming: [incoming("user", "ok", "s:0"), incoming("user", "ok", "s:120")])
        XCTAssertEqual(plan, [.skip, .insert])
    }

    func testRepeatedIdenticalMessagesAreBothKept() {
        // The guard against OVER-dedup: two genuinely identical messages are two turns. A
        // content hash collapses them; a key cannot.
        let plan = TranscriptMerge.plan(
            existing: [],
            incoming: [incoming("user", "same", "s:0"), incoming("user", "same", "s:64")])
        XCTAssertEqual(plan, [.insert, .insert])
    }

    func testTwoUnkeyedCopiesBindOldestFirstAndNeitherDuplicates() {
        let plan = TranscriptMerge.plan(
            existing: [existing("user", "same"), existing("user", "same")],
            incoming: [incoming("user", "same", "s:0"), incoming("user", "same", "s:64")])
        XCTAssertEqual(plan, [.bind(existingIndex: 0), .bind(existingIndex: 1)],
                       "oldest existing turn takes the earliest transcript line")
    }

    func testRoleMustMatchAndWhitespaceIsIgnored() {
        // The wire says "assistant", the store says "jesse": they are the same role. Text is
        // compared trimmed, since a local echo and the transcript line differ in trailing
        // whitespace often enough to matter.
        XCTAssertEqual(
            TranscriptMerge.plan(existing: [existing("jesse", "  an answer\n")],
                                 incoming: [incoming("assistant", "an answer", "s:0")]),
            [.bind(existingIndex: 0)])
        // A role mismatch is never a bind.
        XCTAssertEqual(
            TranscriptMerge.plan(existing: [existing("user", "an answer")],
                                 incoming: [incoming("assistant", "an answer", "s:0")]),
            [.insert])
    }

    func testAnUnkeyedIncomingTurnFromTheDeprecatedRouteStillMerges() {
        // The deprecated single-session route emits no `turn_key`. An empty key must never
        // match a held key, and must still bind onto an unkeyed local turn.
        XCTAssertEqual(
            TranscriptMerge.plan(existing: [existing("user", "hi", key: "s:0")],
                                 incoming: [incoming("user", "hi", "")]),
            [.insert], "an empty key cannot match a held key, so it is not silently skipped")
        XCTAssertEqual(
            TranscriptMerge.plan(existing: [existing("user", "hi")],
                                 incoming: [incoming("user", "hi", "")]),
            [.bind(existingIndex: 0)])
    }

    func testCrossSegmentDeltaInsertsEachTurnOnce() {
        // The delta after a fork: segment 0's tail plus all of segment 1, none of it held.
        let plan = TranscriptMerge.plan(
            existing: [existing("user", "q1", key: "s0:0"),
                       existing("jesse", "a1", key: "s0:60")],
            incoming: [incoming("user", "q1", "s0:0"),
                       incoming("jesse", "a1", "s0:60"),
                       incoming("user", "q2", "s1:0"),
                       incoming("jesse", "a2", "s1:60")])
        XCTAssertEqual(plan, [.skip, .skip, .insert, .insert])
    }

    func testRoleAndTimestampHelpers() {
        XCTAssertEqual(TranscriptMerge.role(for: "assistant"), .jesse)
        XCTAssertEqual(TranscriptMerge.role(for: "user"), .user)
        let d = TranscriptMerge.timestamp("2026-07-20T08:00:00.000Z")
        XCTAssertEqual(d.timeIntervalSince1970, 1784534400, accuracy: 1)
        let fallback = Date(timeIntervalSince1970: 42)
        XCTAssertEqual(TranscriptMerge.timestamp(nil, fallback: fallback), fallback)
        XCTAssertEqual(TranscriptMerge.timestamp("not a date", fallback: fallback), fallback)
    }
}
