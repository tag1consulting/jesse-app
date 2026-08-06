import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// A hydrated turn, built at file scope (nonisolated) so it can be constructed inside the
/// fake's `hydrate` handler, which runs off the main actor. `key` is the bridge's stable
/// `turn_key`; an empty key means "unkeyed", which the merge treats as never matching a held
/// key.
private func ht(_ role: String, _ text: String, _ key: String = "") -> HydratedTurn {
    HydratedTurn(role: role, text: text, timestamp: nil, turnKey: key)
}

/// Hydration on open. The path behind "old conversations show in the sidebar but clicking one
/// never loads the transcript". Three failure modes are covered: the config lockout (an
/// unconfigured coordinator silently no-ops, so nothing ever loads), the cursor lifecycle for
/// an adopted stub (full history on first open, delta after), and the double-bubble the
/// transcript-flush lag used to produce.
///
/// The cursor is the bridge's OPAQUE `"<segment>:<offset>"` string now, keyed on the
/// CONVERSATION, and it is PRESENCE-based: an absent cursor is distinct from the start of the
/// transcript, which the old `offset` returning 0 could not express.
@MainActor
final class MacHydrationTests: XCTestCase {

    private func uniqueCid() -> String { "c-\(UUID().uuidString)" }

    /// Clear a conversation's `.standard` cursor so tests don't contaminate each other (the
    /// coordinator reads the cursor from `.standard`, keyed by conversation id).
    private func clearCursor(_ cid: String) { MacCursorStore.clear(cid) }

    private func stub(conversationId: String, in context: ModelContext) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.conversationId = conversationId
        t.sessionId = "sess-\(conversationId)"
        context.insert(t)
        try? context.save()
        return t
    }

    func testAdoptedStubFullHydratesOnFirstOpen() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)

        // Cursor ABSENT -> first open fetches the whole history. `nil` is the meaningful
        // value here: it is what distinguishes "never hydrated" from "hydrated from the start".
        let fake = MacFakeBridgeClient(hydrate: { _, after in
            XCTAssertNil(after, "an adopted stub full-hydrates with NO cursor")
            return ([ht("user", "hello", "s:0"), ht("assistant", "hi there", "s:60")], "0:200")
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["hello", "hi there"])
        XCTAssertEqual(thread.orderedTurns.map(\.isUser), [true, false])
        XCTAssertEqual(thread.orderedTurns.compactMap(\.sourceKey), ["s:0", "s:60"],
                       "each imported turn carries its stable transcript key")
        XCTAssertEqual(MacCursorStore.cursor(cid), "0:200",
                       "the cursor advances past the imported history")
        XCTAssertEqual(fake.hydrateCalls.count, 1)
    }

    func testSecondOpenImportsOnlyTheDelta() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, after in
            switch after {
            case nil:      return ([ht("user", "hello", "s:0"), ht("assistant", "hi there", "s:60")], "0:200")
            case "0:200":  return ([ht("user", "more", "s:200")], "0:260")   // only the new tail
            default:       XCTFail("unexpected cursor \(after ?? "nil")"); return ([], after ?? "0:0")
            }
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)   // full
        await coordinator.hydrate(thread: thread, context: context)   // delta

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["hello", "hi there", "more"],
                       "the second open must append only the delta, not re-import")
        XCTAssertEqual(MacCursorStore.cursor(cid), "0:260")
        XCTAssertEqual(fake.hydrateCalls.map(\.after), [nil, "0:200"])
    }

    func testUnconfiguredHydrateIsASilentNoOp() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, _ in
            XCTFail("must not hit the bridge"); return ([], "0:0")
        })
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
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)

        // Recover a pre-1.0(61) pairing via the migration.
        let kc = FakeKeychain()
        kc.seed(account: MacConfigStore.legacyTokenAccount, "legacy-secret")
        let d = UserDefaults(suiteName: "hy.\(UUID().uuidString)")!
        d.set("studio.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)
        let configStore = MacConfigStore(store: kc.configStore(service: MacConfigStore.keychainService),
                                         defaults: d, legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertTrue(configStore.isConfigured, "precondition: migration restored the pairing")

        let fake = MacFakeBridgeClient(hydrate: { _, _ in ([ht("assistant", "restored", "s:0")], "0:40") })
        let coordinator = MacCoordinator(configStore: configStore, makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["restored"])
    }

    func testHydrate404LeavesTheCachedCopy() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)
        let cached = Turn(role: .jesse, text: "cached reply"); cached.thread = thread
        context.insert(cached); try? context.save()

        let fake = MacFakeBridgeClient(hydrate: { _, _ in throw JesseError.badResponse(404, "gone") })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["cached reply"], "a 404 leaves the cache intact")
        XCTAssertNil(coordinator.lastError, "a GC'd conversation is not a user-facing error")
    }

    func testEmptyHydrateStillAdvancesCursor() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)

        let fake = MacFakeBridgeClient(hydrate: { _, _ in ([], "0:50") })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)
        XCTAssertTrue(thread.orderedTurns.isEmpty)
        XCTAssertEqual(MacCursorStore.cursor(cid), "0:50", "even an empty delta advances the cursor")
    }

    /// The reported double: a finalized exchange must show EXACTLY ONE assistant bubble, the
    /// optimistic one carrying the provenance chip, even when a subsequent hydrate returns that
    /// same turn. Here the fake reproduces the bridge's transcript-flush lag: the cursor lands
    /// BEFORE the assistant turn, so the next on-open hydrate returns it.
    ///
    /// The turn is now BOUND to its transcript key rather than skipped by content, which is the
    /// stronger property: it holds even when two turns are textually identical.
    func testSendThenFinalizeThenHydrateYieldsOneAssistantTurnWithProvenance() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask)
        let cid = try XCTUnwrap(thread.conversationId); defer { clearCursor(cid) }
        context.insert(thread); try? context.save()

        let prov = JesseProvenance(route: "hosted", model: "glm-5.2", costUsd: 0.0021,
                                   badge: "[glm-5.2 · $0.0021]",
                                   flags: JesseProvenanceFlags(hostedVerify: false, verifyQueued: false,
                                                               citationsUnverified: false))
        let reply = JesseReply(text: "hi there\n\n" + prov.badge, sessionId: "sess-1", provenance: prov)
        let fake = MacFakeBridgeClient(
            sendResult: .reply(reply, jobId: nil, conversationId: nil),
            hydrate: { _, after in
                switch after {
                // Flush lag: the assistant turn is not in the jsonl yet.
                case nil:     return ([ht("user", "hello", "s:0")], "0:100")
                // The on-open hydrate now sees it.
                case "0:100": return ([ht("assistant", "hi there", "s:100")], "0:200")
                default:      return ([], after ?? "0:0")
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
        XCTAssertEqual(assistant.first?.sourceKey, "s:100",
                       "the optimistic bubble was BOUND to its transcript key, not replaced")
        XCTAssertEqual(thread.orderedTurns.filter(\.isUser).count, 1, "the user turn is not duplicated either")
    }

    /// The other half of the double-bubble contract, from the app's end: a voice turn that
    /// also logged a meal. The bridge delivers the SPOKEN: line (the watch and TTS need it)
    /// and appends the badge, and the app stores neither — `displayText` drops both. So the
    /// string the app holds for this reply is "Logged it.", and that is exactly the string
    /// the transcript route has to return for the turn to bind.
    ///
    /// This test pins the TARGET; `sessions.rs` pins that the bridge produces it. The
    /// directive line is deliberately absent from the delivered reply — the bridge strips it
    /// before delivery — while the transcript keeps it, which is the asymmetry that made this
    /// turn render twice. The app is not asked to know that: it is harness-blind, and there
    /// is no strip on this side to compensate with.
    func testAVoiceTurnThatAlsoLoggedAMealShowsExactlyOneBubble() async throws {
        let context = try MacTestFixtures.context()
        let thread = JesseThread(mode: .ask)
        let cid = try XCTUnwrap(thread.conversationId); defer { clearCursor(cid) }
        context.insert(thread); try? context.save()

        let prov = JesseProvenance(route: "hosted", model: "opus", costUsd: 0.004,
                                   badge: "[opus · $0.0040]",
                                   flags: JesseProvenanceFlags(hostedVerify: false, verifyQueued: false,
                                                               citationsUnverified: false))
        // As delivered: directive already stripped, SPOKEN: line kept, badge appended.
        let reply = JesseReply(text: "Logged it.\nSPOKEN: Logged it.\n\n" + prov.badge,
                               sessionId: "sess-v", provenance: prov)
        let fake = MacFakeBridgeClient(
            sendResult: .reply(reply, jobId: nil, conversationId: nil),
            hydrate: { _, after in
                switch after {
                case nil:     return ([ht("user", "log the kefir", "s:0")], "0:100")
                // What a normalizing bridge returns for that reply: no SPOKEN: line, no
                // sentinel — the same string the app stored.
                case "0:100": return ([ht("assistant", "Logged it.", "s:100")], "0:200")
                default:      return ([], after ?? "0:0")
                }
            })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.send(text: "log the kefir", mode: .ask, thread: thread, context: context)
        await coordinator.hydrate(thread: thread, context: context)

        let assistant = thread.orderedTurns.filter { !$0.isUser }
        XCTAssertEqual(assistant.count, 1, "a voice turn must not render twice")
        XCTAssertEqual(assistant.first?.text, "Logged it.",
                       "the stored body drops the SPOKEN: line and the badge")
        XCTAssertEqual(assistant.first?.sourceKey, "s:100", "and it BOUND rather than inserting")
    }

    /// Idempotent hydration must still backfill a genuinely-new turn produced on ANOTHER device:
    /// a hydrated turn that is NOT already present is appended (chip-less, as it carries no local
    /// provenance), while one matching an unkeyed local turn is bound to it.
    func testHydrateStillBackfillsNewCrossDeviceTurns() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)
        // A local optimistic reply already present (as `finalize` would leave it), unkeyed.
        let local = Turn(role: .jesse, text: "local reply"); local.thread = thread
        context.insert(local); try? context.save()

        // The delta overlaps the local reply AND carries a new turn from the other device.
        let fake = MacFakeBridgeClient(hydrate: { _, _ in
            ([ht("assistant", "local reply", "s:0"), ht("user", "from the phone", "s:60")], "0:300")
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.map(\.text), ["local reply", "from the phone"],
                       "the overlapping turn is not duplicated; the genuinely-new turn is backfilled")
        XCTAssertEqual(local.sourceKey, "s:0", "and the overlapping local turn acquired its key")
        XCTAssertEqual(MacCursorStore.cursor(cid), "0:300")
    }

    /// A user legitimately repeating the SAME message keeps both copies. This is the case the
    /// old content-hash guard got WRONG in the other direction (it dropped the second one); a
    /// key-based identity cannot.
    func testHydrateKeepsGenuineRepeatedMessages() async throws {
        let context = try MacTestFixtures.context()
        let cid = uniqueCid(); defer { clearCursor(cid) }
        let thread = stub(conversationId: cid, in: context)
        let first = Turn(role: .user, text: "ping"); first.thread = thread
        context.insert(first); try? context.save()

        // The transcript legitimately has "ping" twice; only one is already local.
        let fake = MacFakeBridgeClient(hydrate: { _, _ in
            ([ht("user", "ping", "s:0"), ht("user", "ping", "s:60")], "0:120")
        })
        let coordinator = MacCoordinator(configStore: MacTestFixtures.configured(),
                                         makeClient: { _ in fake },
                                         sessionDeletionStore: MacTestFixtures.deletionStore())

        await coordinator.hydrate(thread: thread, context: context)

        XCTAssertEqual(thread.orderedTurns.filter { $0.text == "ping" }.count, 2,
                       "the existing 'ping' is bound to the first key; the second is a genuine new copy")
    }

    func testCursorClearForgetsTheCursorAndAbsentIsNotTheStart() {
        let cid = uniqueCid()
        MacCursorStore.setCursor(cid, "1:123")
        XCTAssertEqual(MacCursorStore.cursor(cid), "1:123")
        MacCursorStore.clear(cid)
        XCTAssertNil(MacCursorStore.cursor(cid),
                     "a cleared cursor reads ABSENT, which is what distinguishes never-hydrated "
                     + "from hydrated-from-the-start (the old `offset` returned 0 for both)")
    }
}
