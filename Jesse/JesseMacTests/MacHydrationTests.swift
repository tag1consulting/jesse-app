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

    func testCursorClearForgetsOffset() {
        let sid = uniqueSid()
        MacCursorStore.setOffset(sid, 123)
        XCTAssertEqual(MacCursorStore.offset(sid), 123)
        MacCursorStore.clear(sid)
        XCTAssertEqual(MacCursorStore.offset(sid), 0, "a cleared cursor re-hydrates from scratch")
    }
}
