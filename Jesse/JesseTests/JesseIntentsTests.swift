import XCTest
@testable import Jesse

/// The Siri hand-off had zero coverage. `JesseInbox` is the cross-launch queue
/// (UserDefaults for cold launch, `@Published` for a warm hand-off) that
/// `AskJesseIntent`/`TellJesseIntent` write and `ContentView` drains. These pin the
/// enqueue/drain round-trip and that each intent enqueues the right mode + text.
@MainActor
final class JesseIntentsTests: XCTestCase {

    // The persistence keys `JesseInbox` uses (private there; mirrored here only to
    // give each test a clean slate on the shared UserDefaults store).
    private let dMode = "jesse.pending.mode"
    private let dText = "jesse.pending.text"

    override func setUp() {
        super.setUp()
        clear()
    }

    override func tearDown() {
        clear()
        super.tearDown()
    }

    private func clear() {
        UserDefaults.standard.removeObject(forKey: dMode)
        UserDefaults.standard.removeObject(forKey: dText)
        JesseInbox.shared.pending = nil
    }

    /// `enqueue` schedules its warm-path drain on a `Task { @MainActor … }`. The
    /// async XCTest harness doesn't pump that task within a test, so tests assert the
    /// deterministic contract instead: the request is persisted synchronously (the
    /// cold-launch path), and `drain()` reconstitutes it. In the running app the
    /// scheduled task lands `pending` directly; here we drive `drain()` ourselves if
    /// it hasn't, so the round-trip is verified either way.
    private func drainIfNeeded() {
        if JesseInbox.shared.pending == nil { JesseInbox.shared.drain() }
    }

    // MARK: - drain

    func testDrainWithNothingQueuedLeavesPendingNil() {
        JesseInbox.shared.drain()
        XCTAssertNil(JesseInbox.shared.pending)
    }

    /// The cold-launch path: the defaults survive a launch and a fresh drain picks
    /// them up, then clears them so a second drain doesn't re-fire.
    func testDrainPicksUpPersistedRequestAndClearsIt() {
        UserDefaults.standard.set("tell", forKey: dMode)
        UserDefaults.standard.set("water the plants Saturday", forKey: dText)

        JesseInbox.shared.drain()
        XCTAssertEqual(JesseInbox.shared.pending?.mode, .tell)
        XCTAssertEqual(JesseInbox.shared.pending?.text, "water the plants Saturday")

        // Drained → defaults cleared.
        XCTAssertNil(UserDefaults.standard.string(forKey: dMode))
        XCTAssertNil(UserDefaults.standard.string(forKey: dText))

        // A second drain finds nothing new (pending is unchanged, not re-set).
        JesseInbox.shared.pending = nil
        JesseInbox.shared.drain()
        XCTAssertNil(JesseInbox.shared.pending, "a consumed request does not re-fire")
    }

    func testDrainIgnoresEmptyText() {
        UserDefaults.standard.set("ask", forKey: dMode)
        UserDefaults.standard.set("", forKey: dText)
        JesseInbox.shared.drain()
        XCTAssertNil(JesseInbox.shared.pending, "empty text is not a valid pending request")
    }

    // MARK: - enqueue → drain round-trip

    func testEnqueuePersistsRequestSynchronously() {
        JesseInbox.shared.enqueue(mode: .ask, text: "what's on Today")
        // Synchronously after enqueue (before the deferred warm drain), the request
        // is persisted so a cold launch can reconstitute it.
        XCTAssertEqual(UserDefaults.standard.string(forKey: dMode), "ask")
        XCTAssertEqual(UserDefaults.standard.string(forKey: dText), "what's on Today")
    }

    func testEnqueueThenDrainYieldsPendingRequest() {
        JesseInbox.shared.enqueue(mode: .ask, text: "what's on Today")
        drainIfNeeded()
        XCTAssertEqual(JesseInbox.shared.pending?.mode, .ask)
        XCTAssertEqual(JesseInbox.shared.pending?.text, "what's on Today")
    }

    // MARK: - the intents

    func testAskJesseIntentEnqueuesAskMode() async throws {
        var intent = AskJesseIntent()
        intent.text = "a question"
        _ = try await intent.perform()
        drainIfNeeded()
        XCTAssertEqual(JesseInbox.shared.pending?.mode, .ask)
        XCTAssertEqual(JesseInbox.shared.pending?.text, "a question")
    }

    func testTellJesseIntentEnqueuesTellMode() async throws {
        var intent = TellJesseIntent()
        intent.text = "note the roof guy comes Thursday"
        _ = try await intent.perform()
        drainIfNeeded()
        XCTAssertEqual(JesseInbox.shared.pending?.mode, .tell)
        XCTAssertEqual(JesseInbox.shared.pending?.text, "note the roof guy comes Thursday")
    }
}
