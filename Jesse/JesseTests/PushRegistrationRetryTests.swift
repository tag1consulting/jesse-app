import XCTest
@testable import Jesse
import JesseNetworking

/// Device-token registration used to be a single `try?`: one attempt, and if the laptop
/// happened to be asleep at that moment the bridge had no token until the next foreground.
///
/// That is the single worst place in the app to swallow a failure — every push this app
/// can send depends on that one write having landed — so it now retries on a backoff, and
/// remembers what the bridge ACCEPTED across launches.
@MainActor
final class PushRegistrationRetryTests: XCTestCase {

    private let suiteName = "PushRegistrationRetryTests"

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        PushRegistrationStore.defaults = defaults
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        PushRegistrationStore.defaults = .standard
        super.tearDown()
    }

    private func key(token: String = "abc", host: String = "box.ts.net",
                     port: Int = 8765) -> PushRegistrationDedupe.Key {
        PushRegistrationDedupe.Key(token: token, host: host, port: port)
    }

    // MARK: - The backoff table

    /// 1s, 10s, 60s, then hourly. Short at the start because the overwhelming case is a
    /// laptop waking up; hourly after that because everything past a minute is a laptop
    /// that is off, and there is no benefit to asking a closed lid more often.
    func testBackoffIsOneThenTenThenSixtyThenHourly() {
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 2), 10)
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 3), 60)
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 4), 3600)
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 40), 3600)
    }

    /// A nonsense attempt number still waits rather than hammering.
    func testANonsenseAttemptNumberStillWaits() {
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: 0), 1)
        XCTAssertEqual(PushRegistrationBackoff.delay(forAttempt: -5), 1)
    }

    // MARK: - The persisted record

    /// Persisted only on ACCEPTANCE. A record of a write that never landed would be worse
    /// than none: it would suppress the retry that is the whole point.
    func testTheStoreRoundTripsAnAcceptedRegistration() {
        XCTAssertNil(PushRegistrationStore.load())
        PushRegistrationStore.save(key())
        XCTAssertEqual(PushRegistrationStore.load(), key())
    }

    /// A restore from backup gives the device a NEW token while the paired bridge is
    /// unchanged — which must read as a different registration, not a repeat.
    func testADifferentTokenIsADifferentRegistration() {
        PushRegistrationStore.save(key(token: "old"))
        let restored = key(token: "new")
        XCTAssertNotEqual(PushRegistrationStore.load(), restored)
        XCTAssertTrue(PushRegistrationDedupe.shouldRegister(
            restored,
            last: (PushRegistrationStore.load()!, Date()),
            now: Date()))
    }

    /// A blank or half-written record reads as "nothing recorded" rather than as a
    /// registration nobody made.
    func testAMalformedRecordReadsAsAbsent() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["token": "", "host": "h", "port": 1], forKey: PushRegistrationStore.key)
        XCTAssertNil(PushRegistrationStore.load())
        defaults.set(["host": "h", "port": 1], forKey: PushRegistrationStore.key)
        XCTAssertNil(PushRegistrationStore.load())
    }

    // MARK: - The retry loop

    /// The failure that used to lose the registration entirely: the laptop is asleep for
    /// the first two attempts and awake for the third.
    func testItRetriesUntilTheBridgeAcceptsIt() async {
        let recorder = Recorder(failuresBeforeSuccess: 2)
        let manager = PushManager(
            register: { config, token in try await recorder.attempt(config, token) },
            sleep: { _ in await Task.yield() },
            config: { JesseConfig(host: "box.ts.net", port: 8765, token: "tok") })

        manager.didRegister(deviceToken: Data([0xab, 0xcd]))
        await waitUntil("the registration to be accepted") { recorder.succeeded }

        XCTAssertEqual(recorder.attempts, 3, "two failures, then the write lands")
        XCTAssertEqual(recorder.tokens.last, "abcd", "hex-encoded, unchanged across retries")
    }

    /// Only a THROW is retried. Anything the bridge ANSWERED is an answer, and re-POSTing
    /// a request it understood and refused would be an hourly write for the life of the
    /// pairing.
    func testASuccessfulWriteIsNotRepeated() async {
        let recorder = Recorder(failuresBeforeSuccess: 0)
        let manager = PushManager(
            register: { config, token in try await recorder.attempt(config, token) },
            sleep: { _ in await Task.yield() },
            config: { JesseConfig(host: "box.ts.net", port: 8765, token: "tok") })

        manager.didRegister(deviceToken: Data([0x01]))
        await waitUntil("the registration to be accepted") { recorder.succeeded }
        // Give a stray retry every chance to happen.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.attempts, 1)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Counts registration attempts and fails a scripted number of them.
@MainActor
private final class Recorder {
    nonisolated deinit {}
    private var failuresRemaining: Int
    private(set) var attempts = 0
    private(set) var tokens: [String] = []
    private(set) var succeeded = false

    init(failuresBeforeSuccess: Int) { self.failuresRemaining = failuresBeforeSuccess }

    func attempt(_ config: JesseConfig, _ token: String) async throws {
        attempts += 1
        tokens.append(token)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw JesseError.cannotConnect("laptop")
        }
        succeeded = true
    }
}
