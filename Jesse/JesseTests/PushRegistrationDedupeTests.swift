import XCTest
@testable import Jesse

/// The pure rule behind "don't re-POST the same device token to the same bridge once per
/// foreground".
///
/// The defect: `ContentView` calls `PushManager.refreshRegistration()` on every
/// `scenePhase == .active`, and each one ends in `POST /jesse/device`. Measured against a
/// stub bridge, eight background/foreground toggles in 36 seconds produced eight identical
/// registrations — same token, same host — every one after the first a server-side no-op.
///
/// The write itself is NOT waste: it is how a bridge restart, a rotated APNs token, or a
/// changed host gets covered, so it must still happen. Only the *repeat within seconds* is
/// waste, because nothing it could detect can have changed in that window. These tests pin
/// both halves so a future edit cannot silently turn push registration off.
final class PushRegistrationDedupeTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func key(token: String = "abc123", host: String = "box.tailnet.ts.net",
                     port: Int = 8765) -> PushRegistrationDedupe.Key {
        PushRegistrationDedupe.Key(token: token, host: host, port: port)
    }

    func testFirstRegistrationAlwaysGoes() {
        XCTAssertTrue(PushRegistrationDedupe.shouldRegister(key(), last: nil, now: t0),
                      "with nothing recorded there is nothing to dedupe against")
    }

    func testAnIdenticalRepeatInsideTheWindowIsSkipped() {
        let k = key()
        XCTAssertFalse(
            PushRegistrationDedupe.shouldRegister(k, last: (k, t0), now: t0.addingTimeInterval(1)),
            "a foreground one second later cannot have anything new to tell the bridge")
    }

    func testEightRapidTogglesCostExactlyOneWrite() {
        // The measured scenario, replayed: toggling in and out every 4 seconds.
        let k = key()
        var last: (key: PushRegistrationDedupe.Key, at: Date)?
        var writes = 0
        for i in 0..<8 {
            let now = t0.addingTimeInterval(Double(i) * 4)
            if PushRegistrationDedupe.shouldRegister(k, last: last, now: now) {
                writes += 1
                last = (k, now)
            }
        }
        XCTAssertEqual(writes, 1, "eight toggles inside the window are one registration")
    }

    func testARealReturnToTheAppReRegisters() {
        let k = key()
        let later = t0.addingTimeInterval(PushRegistrationDedupe.window)
        XCTAssertTrue(PushRegistrationDedupe.shouldRegister(k, last: (k, t0), now: later),
                      "past the window the bridge may have restarted — register again")
    }

    func testARotatedTokenAlwaysReRegistersImmediately() {
        XCTAssertTrue(
            PushRegistrationDedupe.shouldRegister(key(token: "new"),
                                                  last: (key(token: "old"), t0),
                                                  now: t0.addingTimeInterval(1)),
            "a new APNs token must reach the bridge at once, window or not")
    }

    func testARepairedOrChangedBridgeAlwaysReRegistersImmediately() {
        XCTAssertTrue(
            PushRegistrationDedupe.shouldRegister(key(host: "other.tailnet.ts.net"),
                                                  last: (key(), t0),
                                                  now: t0.addingTimeInterval(1)),
            "a different host has never seen this token")
        XCTAssertTrue(
            PushRegistrationDedupe.shouldRegister(key(port: 9000),
                                                  last: (key(), t0),
                                                  now: t0.addingTimeInterval(1)),
            "a different port is a different bridge")
    }

    func testTheWindowIsShortEnoughToStayCorrect() {
        // The dedupe trades a tiny amount of push-recovery latency for the repeat writes.
        // Keep that trade small and visible.
        XCTAssertLessThanOrEqual(PushRegistrationDedupe.window, 120,
                                 "a bridge restart is covered by the next foreground, soon")
    }
}
