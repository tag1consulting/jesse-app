import XCTest
import SwiftData
@testable import Jesse

// Behavioral tests for AI-title generation: the REAL `JesseClient.title` over a
// URLProtocol stub (404 / timeout / empty → nil, a 200 → the title), and
// `RunCoordinator.ensureTitle`'s cache/invalidation/dedup logic via an injected
// counting client (zero calls on a cache hit, exactly one on a key change, and no
// per-appearance re-hit when the bridge has no endpoint).

// MARK: - Minimal URLProtocol stub for POST /jesse/title

final class TitleStubURLProtocol: URLProtocol {
    enum Behavior {
        case status(Int, Data)     // reply with this status + body
        case failTransport         // a transport error (timeout/offline)
    }
    nonisolated(unsafe) static var behavior: Behavior = .status(404, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch Self.behavior {
        case .status(let code, let body):
            let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failTransport:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
}

// MARK: - Counting fake client for the coordinator-level tests

/// Counts `title` calls and returns a scripted result. All other protocol methods
/// are inert stubs (the title path never drives a turn).
final class TitleCountingClient: JesseClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _titleCalls = 0
    private var _lastDigest: String?
    private let scripted: String?

    init(returns scripted: String?) { self.scripted = scripted }

    var titleCalls: Int { lock.lock(); defer { lock.unlock() }; return _titleCalls }
    var lastDigest: String? { lock.lock(); defer { lock.unlock() }; return _lastDigest }

    func title(forDigest digest: String) async -> String? {
        lock.lock(); _titleCalls += 1; _lastDigest = digest; lock.unlock()
        return scripted
    }

    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment]) async throws -> JesseSendResult {
        .running(jobId: "unused")
    }
    func result(jobId: String) async throws -> JesseResultState { .running }
    func cancelJob(jobId: String) async throws {}
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class AITitleTests: XCTestCase {

    private let cfg = JesseConfig(host: "laptop", port: 8765, token: "tok")

    override func setUp() {
        super.setUp()
        TitleStubURLProtocol.behavior = .status(404, Data())
    }

    private func stubSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [TitleStubURLProtocol.self]
        return URLSession(configuration: c)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func insertedThread(_ context: ModelContext, title: String = "derived first words")
        -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        context.insert(t)
        t.turns = [
            Turn(role: .user, text: "what's on today?", createdAt: Date(timeIntervalSince1970: 0)),
            Turn(role: .jesse, text: "A dentist at 3pm.", createdAt: Date(timeIntervalSince1970: 1)),
        ]
        return t
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Wire contract

    /// The bridge's `/jesse/title` body field is `text` (it caps + sanitizes). Our
    /// `digest` property must serialize to that key, byte-for-byte.
    func testTitleRequestBodyUsesTextKey() throws {
        let body = try JesseClient.encodeBody(JesseTitleRequest(digest: "hello world"))
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"text":"hello world"}"#)
    }

    // MARK: - Real client over the stub

    func testRealClient404YieldsNilNotThrow() async {
        TitleStubURLProtocol.behavior = .status(404, Data())
        let client = JesseClient(config: cfg, session: stubSession())
        let title = await client.title(forDigest: "some digest")
        XCTAssertNil(title, "a bridge without /jesse/title (404) yields no title, never an error")
    }

    func testRealClientTimeoutYieldsNil() async {
        TitleStubURLProtocol.behavior = .failTransport
        let client = JesseClient(config: cfg, session: stubSession())
        let title = await client.title(forDigest: "some digest")
        XCTAssertNil(title, "a timeout/offline yields nil, not a thrown error")
    }

    func testRealClientDecodesTitleOn200() async {
        let body = try! JSONSerialization.data(withJSONObject: ["title": "Weekend plans"])
        TitleStubURLProtocol.behavior = .status(200, body)
        let client = JesseClient(config: cfg, session: stubSession())
        let title = await client.title(forDigest: "digest")
        XCTAssertEqual(title, "Weekend plans")
    }

    func testRealClientEmptyTitleYieldsNil() async {
        let body = try! JSONSerialization.data(withJSONObject: ["title": "   "])
        TitleStubURLProtocol.behavior = .status(200, body)
        let client = JesseClient(config: cfg, session: stubSession())
        let title = await client.title(forDigest: "digest")
        XCTAssertNil(title, "a blank title is treated as no title")
    }

    // MARK: - Coordinator cache / invalidation / dedup

    /// A cache hit — the cached title's key already matches the live content —
    /// makes ZERO network calls.
    @MainActor
    func testCacheHitWithMatchingKeyMakesZeroCalls() async throws {
        let context = try makeContext()
        let client = TitleCountingClient(returns: "should not be requested")
        let coordinator = RunCoordinator(config: { self.cfg }, makeClient: { _ in client })
        let thread = insertedThread(context)
        thread.aiTitle = "Cached title"
        thread.titleSourceKey = threadContentKey(for: thread)   // current

        coordinator.ensureTitle(for: thread, context: context)
        try await Task.sleep(for: .milliseconds(100))   // let any stray task run
        XCTAssertEqual(client.titleCalls, 0, "a current cached title triggers no request")
        XCTAssertEqual(thread.aiTitle, "Cached title")
    }

    /// A key change (a new/edited turn) triggers EXACTLY ONE regeneration even
    /// under repeated row-appearance triggers, and none afterwards.
    @MainActor
    func testKeyChangeTriggersExactlyOneRegeneration() async throws {
        let context = try makeContext()
        let client = TitleCountingClient(returns: "Fresh title")
        let coordinator = RunCoordinator(config: { self.cfg }, makeClient: { _ in client })
        let thread = insertedThread(context)
        thread.aiTitle = "Old title"
        thread.titleSourceKey = "old-key-that-does-not-match"   // stale

        // onAppear can fire many times; the coordinator must dedupe to one call.
        coordinator.ensureTitle(for: thread, context: context)
        coordinator.ensureTitle(for: thread, context: context)
        coordinator.ensureTitle(for: thread, context: context)

        await waitUntil("the fresh title to land") { thread.aiTitle == "Fresh title" }
        XCTAssertEqual(client.titleCalls, 1, "exactly one generation despite repeated triggers")
        XCTAssertEqual(thread.titleSourceKey, threadContentKey(for: thread),
                       "the minted title records the key it came from")
        XCTAssertEqual(client.lastDigest, titleDigest(for: thread),
                       "the app sends the bounded digest")

        // Now current — further triggers are no-ops.
        coordinator.ensureTitle(for: thread, context: context)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.titleCalls, 1)
    }

    /// A nil result (a bridge with no /jesse/title) leaves the derived title in
    /// place, surfaces no error, and is NOT re-requested on every appearance.
    @MainActor
    func testNilResultKeepsDerivedTitleAndDoesNotRetryPerAppearance() async throws {
        let context = try makeContext()
        let client = TitleCountingClient(returns: nil)   // no endpoint
        let coordinator = RunCoordinator(config: { self.cfg }, makeClient: { _ in client })
        let thread = insertedThread(context, title: "derived first words")

        coordinator.ensureTitle(for: thread, context: context)
        await waitUntil("the one attempt to complete") { client.titleCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(thread.aiTitle, "no title cached when the bridge returns nil")
        XCTAssertEqual(displayTitle(for: thread), "derived first words",
                       "the row shows the derived title, no error, no spinner")

        // Repeated appearances must not re-hit the bridge for the same content.
        coordinator.ensureTitle(for: thread, context: context)
        coordinator.ensureTitle(for: thread, context: context)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.titleCalls, 1,
                       "a missing endpoint isn't re-requested per row appearance")
    }

    /// An empty thread (no turns) is never titled.
    @MainActor
    func testEmptyThreadIsNeverTitled() async throws {
        let context = try makeContext()
        let client = TitleCountingClient(returns: "nope")
        let coordinator = RunCoordinator(config: { self.cfg }, makeClient: { _ in client })
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        coordinator.ensureTitle(for: thread, context: context)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(client.titleCalls, 0)
    }
}
