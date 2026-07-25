import XCTest
@testable import JesseNetworking

/// The presence-based hydration cursor: absent (never hydrated) is distinct from the
/// start-of-transcript cursor, and the cursor itself is the bridge's OPAQUE
/// `"<segment>:<offset>"` string rather than a byte offset (a conversation can span several
/// transcript files, so a bare offset is not a sufficient position).
final class HydrationCursorStoreTests: XCTestCase {

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "HydrationCursorStoreTests.\(UUID().uuidString)")!
    }

    private func scratch() -> HydrationCursorStore {
        HydrationCursorStore(defaults: scratchDefaults())
    }

    func testAbsentIsNilNotTheStartCursor() {
        let store = scratch()
        XCTAssertNil(store.cursor("c1"), "an un-hydrated conversation reads nil")
    }

    func testSetAndRead() {
        let store = scratch()
        store.setCursor("c1", "0:0")
        XCTAssertEqual(store.cursor("c1"), "0:0",
                       "the start cursor is a real, PRESENT value, distinct from absent")
        store.setCursor("c1", "1:4096")
        XCTAssertEqual(store.cursor("c1"), "1:4096")
    }

    func testClearReturnsToAbsent() {
        let store = scratch()
        store.setCursor("c1", "0:100")
        store.clear("c1")
        XCTAssertNil(store.cursor("c1"), "clearing returns the conversation to never-hydrated")
    }

    func testKeysAreIsolatedPerConversation() {
        let store = scratch()
        store.setCursor("c1", "0:10")
        XCTAssertEqual(store.cursor("c1"), "0:10")
        XCTAssertNil(store.cursor("c2"))
    }

    func testLegacyByteOffsetCursorsArePurgedOnceAndV2KeysSurvive() {
        // A pre-upgrade install's cursors are BYTE OFFSETS keyed on a session id: meaningless
        // against the opaque conversation cursor, so they are purged rather than translated.
        let defaults = scratchDefaults()
        defaults.set(4096, forKey: "jesse.hydrate.cursor.sess-old")
        defaults.set(10, forKey: "jesse.hydrate.cursor.sess-other")
        defaults.set("keep me", forKey: "unrelated.key")

        let store = HydrationCursorStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "jesse.hydrate.cursor.sess-old"),
                     "the v1 cursor is purged")
        XCTAssertNil(defaults.object(forKey: "jesse.hydrate.cursor.sess-other"))
        XCTAssertEqual(defaults.string(forKey: "unrelated.key"), "keep me",
                       "an unrelated key is untouched")

        // The ordering hazard: `jesse.hydrate.cursor.` is a PREFIX of the v2 prefix, so a
        // purge that ran again after a v2 write must not delete live cursors.
        store.setCursor("c1", "0:64")
        _ = HydrationCursorStore(defaults: defaults)
        XCTAssertEqual(store.cursor("c1"), "0:64", "a v2 cursor survives the legacy purge")

        // And the purge is one-shot: re-planting a legacy key is not swept again, so the
        // scan does not run on every launch.
        defaults.set(1, forKey: "jesse.hydrate.cursor.sess-late")
        _ = HydrationCursorStore(defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: "jesse.hydrate.cursor.sess-late"),
                        "the purge ran once, guarded by its flag")
    }
}
