import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// A hydrated turn, built at file scope (nonisolated) so it can be constructed inside the
/// fake's `hydrate` handler, which runs off the main actor.
private func ht(_ role: String, _ text: String) -> HydratedTurn {
    HydratedTurn(role: role, text: text, timestamp: nil)
}

/// Hydration on open. The path behind "old conversations show in the sidebar but clicking
/// one never loads the transcript". Two failure modes are covered: the config lockout (an
/// unconfigured coordinator silently no-ops, so nothing ever loads) and the cursor
/// lifecycle for an adopted stub (full transcript on first open, byte-delta after). The old
/// suite tested none of this because `MacCoordinator`'s send/hydrate client was built inline
/// and could not be faked.
@MainActor
final class MacHydrationTests: XCTestCase {

    private func uniqueSid() -> String { "s-\(UUID().uuidString)" }

    /// Clear a session's `.standard` cursor so tests don't contaminate each other (the
    /// coordinator reads the cursor from `.standard`, keyed by session id).
    private func clearCursor(_ sid: String) { MacCursorStore.clear(sid) }

    private func stub(sessionId: String, in context: ModelContext) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.sessionId = sessionId
        context.insert(t)
        try? context.save()
        return t
    }

    func testAdoptedStubFullHydratesOnFirstOpen() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)

        // Cursor absent -> first open fetches from offset 0 and imports the whole transcript.
        let fake = MacFakeBridgeClient(hydrate: { _, after in
            XCTAssertEqual(after, 0, "an adopted stub full-hydrates from byte 0")
            return ([ht("user", "hello"), ht("assistant", "hi there")], 200)
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["hello", "hi there"])
        XCTAssertEqual(thread.orderedTurns.map(\.isUser), [true, false])
        XCTAssertEqual(MacCursorStore.offset(sid), 200, "the cursor advances past the imported transcript")
        XCTAssertEqual(fake.hydrateCalls.count, 1)
    }

    func testSecondOpenImportsOnlyTheDelta() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, after in
            switch after {
            case 0:   return ([ht("user", "hello"), ht("assistant", "hi there")], 200)
            case 200: return ([ht("user", "more")], 260)   // only the new tail
            default:  XCTFail("unexpected cursor \(after)"); return ([], after)
            }
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)   // full
        await coordinator.hydrate(thread: thread, context: context)   // delta

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["hello", "hi there", "more"],
                       "the second open must append only the delta, not re-import")
        XCTAssertEqual(MacCursorStore.offset(sid), 260)
        XCTAssertEqual(fake.hydrateCalls.map(\.after), [0, 200])
    }

    func testUnconfiguredHydrateIsASilentNoOp() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, _ in XCTFail("must not hit the bridge"); return ([], 0) })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.unconfigured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertTrue(thread.orderedTurns.isEmpty, "an unconfigured client loads nothing (this is the lockout)")
        XCTAssertTrue(fake.hydrateCalls.isEmpty)
        XCTAssertNil(coordinator.lastError, "and it must not surface an error")
    }

    /// The lockout, end to end: a coordinator whose config was recovered by the legacy
    /// migration hydrates a transcript that an un-migrated (unconfigured) coordinator never
    /// could. This is the concrete reproduction of "the transcript never appears".
    func testMigratedConfigHydratesWhereUnconfiguredCannot() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)

        // Recover a pre-1.0(61) pairing via the migration.
        let kc = FakeKeychain()
        kc.seed(account: MacConfigStore.legacyTokenAccount, "legacy-secret")
        let d = UserDefaults(suiteName: "hy.\(UUID().uuidString)")!
        d.set("studio.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)
        let configStore = MacConfigStore(store: kc.configStore(service: MacConfigStore.keychainService),
                                         defaults: d, legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertTrue(configStore.isConfigured, "precondition: migration restored the pairing")

        let fake = MacFakeBridgeClient(hydrate: { _, _ in ([ht("assistant", "restored")], 40) })
        let coordinator = MacCoordinator(configStore: configStore, makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["restored"])
    }

    func testHydrate404LeavesTheCachedCopy() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)
        let cached = Turn(role: .jesse, text: "cached reply"); cached.thread = thread
        context.insert(cached); try? context.save()

        let fake = MacFakeBridgeClient(hydrate: { _, _ in throw JesseError.badResponse(404, "gone") })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["cached reply"], "a 404 leaves the cache intact")
        XCTAssertNil(coordinator.lastError, "a GC'd session is not a user-facing error")
    }

    func testEmptyHydrateStillAdvancesCursor() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, _ in ([], 50) })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)
        XCTAssertTrue(thread.orderedTurns.isEmpty)
        XCTAssertEqual(MacCursorStore.offset(sid), 50, "even an empty delta advances the cursor")
    }

    /// The reported double: a finalized exchange must show EXACTLY ONE assistant bubble — the
    /// optimistic one carrying the provenance chip — even when a subsequent hydrate runs with a
    /// cursor at/behind that exchange. Here the fake reproduces the bridge's transcript-flush lag:
    /// `finalize`'s cursor-advance sees only the (flushed) user turn, so the cursor lands BEFORE
    /// the assistant turn; the next on-open `hydrate` then returns that assistant turn. Without an
    /// idempotent append it would be re-imported as a second, chip-less copy.
    func testSendThenFinalizeThenHydrateYieldsOneAssistantTurnWithProvenance() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = JesseThread(mode: .ask)
        context.insert(thread); try? context.save()

        let prov = JesseProvenance(route: "hosted", model: "glm-5.2", costUsd: 0.0021,
                                   badge: "[glm-5.2 · $0.0021]",
                                   flags: JesseProvenanceFlags(hostedVerify: false, verifyQueued: false,
                                                               citationsUnverified: false))
        let reply = JesseReply(text: "hi there\n\n" + prov.badge, sessionId: sid, provenance: prov)
        let fake = MacFakeBridgeClient(
            sendResult: .reply(reply, jobId: nil),
            hydrate: { _, after in
                switch after {
                case 0:   return ([ht("user", "hello")], 100)          // flush lag: assistant not yet in the jsonl
                case 100: return ([ht("assistant", "hi there")], 200)  // on-open hydrate now sees it
                default:  return ([], after)
                }
            })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.send(text: "hello", mode: .ask, thread: thread, context: context)
        await coordinator.hydrate(thread: thread, context: context)

        let assistant = thread.orderedTurns.filter { !$0.isUser }
        XCTAssertEqual(assistant.count, 1, "a completed exchange shows exactly one assistant bubble")
        XCTAssertEqual(assistant.first?.text, "hi there", "with the badge stripped from the body")
        XCTAssertEqual(JesseProvenance.from(json: assistant.first?.provenanceJSON)?.model, "glm-5.2",
                       "and the surviving bubble keeps its provenance chip")
        XCTAssertEqual(thread.orderedTurns.filter(\.isUser).count, 1, "the user turn is not duplicated either")
    }

    /// Idempotent hydration must still backfill a genuinely-new turn produced on ANOTHER device:
    /// a hydrated turn that is NOT already present is appended (chip-less, as it carries no local
    /// provenance), while one that duplicates a local turn is skipped.
    func testHydrateStillBackfillsNewCrossDeviceTurns() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)
        // A local optimistic reply already present (as `finalize` would leave it).
        let local = Turn(role: .jesse, text: "local reply"); local.thread = thread
        context.insert(local); try? context.save()

        // The delta overlaps the local reply AND carries a new turn from the other device.
        let fake = MacFakeBridgeClient(hydrate: { _, _ in
            ([ht("assistant", "local reply"), ht("user", "from the phone")], 300)
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["local reply", "from the phone"],
                       "the overlapping turn is not duplicated; the genuinely-new turn is backfilled")
        XCTAssertEqual(MacCursorStore.offset(sid), 300)
    }

    /// A user legitimately repeating the SAME message keeps both copies — the dedup consumes each
    /// existing turn at most once, so it never collapses genuine repeats.
    func testHydrateKeepsGenuineRepeatedMessages() async throws {
        let context = try MacTestFixtures.context()
        let sid = uniqueSid(); defer { clearCursor(sid) }
        let thread = stub(sessionId: sid, in: context)
        let first = Turn(role: .user, text: "ping"); first.thread = thread
        context.insert(first); try? context.save()

        // The transcript legitimately has "ping" twice; only one is already local.
        let fake = MacFakeBridgeClient(hydrate: { _, _ in
            ([ht("user", "ping"), ht("user", "ping")], 120)
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.filter { $0.text == "ping" }.count, 2,
                       "one existing 'ping' is consumed; the second is a genuine new copy and survives")
    }

    func testCursorClearForgetsOffset() {
        let sid = uniqueSid()
        MacCursorStore.setOffset(sid, 123)
        XCTAssertEqual(MacCursorStore.offset(sid), 123)
        MacCursorStore.clear(sid)
        XCTAssertEqual(MacCursorStore.offset(sid), 0, "a cleared cursor re-hydrates from scratch")
    }
}
