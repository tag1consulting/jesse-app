import XCTest
@testable import JesseNetworking

// The WRITE half of the offline cache, driven through the real `JesseBridgeClient` over
// a `URLProtocol` stub.
//
// The write lives in the client rather than in the display models because the client is
// the one place the bridge's own bytes exist — see `SnapshotCache`. That makes this the
// test that matters: the assertion is not "the model called a method", it is "after a
// real 200 over a real URLSession, the exact response body is on disk under the right
// key, with the ETag the next conditional GET has to send".

/// Answers whatever the test scripts, per path, and remembers what it was asked.
final class CacheStubURLProtocol: URLProtocol {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    /// Keyed by request path (`/jesse/today`, `/jesse/diet`).
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    nonisolated(unsafe) static var isEnabled = false

    override class func canInit(with request: URLRequest) -> Bool { isEnabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        Self.requestedURLs.append(url)
        guard let reply = Self.replies[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let http = HTTPURLResponse(url: url, statusCode: reply.status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func reset() {
        replies = [:]
        requestedURLs = []
        isEnabled = false
    }
}

final class SnapshotCacheWriteTests: XCTestCase {

    private var dir: URL!
    private var cache: SnapshotCache!
    private let cfg = JesseConfig(host: "laptop", port: 8765, token: "tok")

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotCacheWrite-\(UUID().uuidString)", isDirectory: true)
        cache = SnapshotCache(directory: dir)
        CacheStubURLProtocol.reset()
        CacheStubURLProtocol.isEnabled = true
    }

    override func tearDown() {
        CacheStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func client(cache: SnapshotCache?) -> JesseBridgeClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [CacheStubURLProtocol.self]
        return JesseBridgeClient(config: cfg, session: URLSession(configuration: c),
                                 snapshotCache: cache)
    }

    private let todayBody = Data("""
    {"title":"Today: Friday, August 21, 2026","date":"2026-08-21","narrative":"A quiet one.",
     "leadItems":[],"sections":[],"counts":{},"missing":false}
    """.utf8)

    private let dietBody = Data("""
    {"asOf":"2026-08-21T14:00:00Z","todayMtime":"2026-08-21T13:00:00Z",
     "today":{"date":"2026-08-21","exercise":[],"meals":[],"targets":{}},"errors":[]}
    """.utf8)

    // MARK: - Today

    /// The exact bytes, under the day key, with the ETag lifted from the HEADER — which
    /// is the case that would otherwise be lost, because `decodeToday` reads the tag from
    /// the header when the JSON omits it and the body alone cannot reconstruct it.
    func testASuccessfulDayFetchCachesTheBodyAndTheHeaderETag() async throws {
        CacheStubURLProtocol.replies["/jesse/today"] =
            .init(status: 200, body: todayBody, headers: ["Etag": "\"day-7\""])

        _ = try await client(cache: cache).getToday(ifNoneMatch: nil)

        let entry = try XCTUnwrap(cache.load(key: SnapshotCacheKey.today))
        XCTAssertEqual(entry.body, todayBody)
        XCTAssertEqual(entry.etag, "\"day-7\"")
    }

    /// A client with no cache writes nothing at all. This is the default, and it is what
    /// keeps a probe, a send, or a per-turn context read from writing the screen's
    /// offline fallback.
    func testAClientWithNoCacheWritesNothing() async throws {
        CacheStubURLProtocol.replies["/jesse/today"] = .init(status: 200, body: todayBody)

        _ = try await client(cache: nil).getToday(ifNoneMatch: nil)

        XCTAssertEqual(cache.keys(), [])
    }

    /// A `304` carries no document, so it must not overwrite the one on disk with an
    /// empty body — the failure mode that would turn a cheap poll into a wiped cache.
    func testANotModifiedLeavesTheCachedDayAlone() async throws {
        cache.store(todayBody, key: SnapshotCacheKey.today, etag: "\"day-7\"",
                    fetchedAt: Date(timeIntervalSince1970: 1_772_530_200))
        CacheStubURLProtocol.replies["/jesse/today"] = .init(status: 304, body: Data())

        let result = try await client(cache: cache).getToday(ifNoneMatch: "\"day-7\"")

        XCTAssertEqual(result, .notModified)
        XCTAssertEqual(cache.load(key: SnapshotCacheKey.today)?.body, todayBody)
    }

    /// A mutation answers with the WHOLE fresh day, and it is the write that matters
    /// most: a kill right after a tick would otherwise leave the cache one tap behind.
    func testAMutationAlsoRefreshesTheCachedDay() async throws {
        cache.store(Data(#"{"title":"stale","date":"2026-08-20"}"#.utf8),
                    key: SnapshotCacheKey.today, etag: "\"day-6\"",
                    fetchedAt: Date(timeIntervalSince1970: 1_772_530_200))
        CacheStubURLProtocol.replies["/jesse/today/items/abc123/check"] =
            .init(status: 200, body: todayBody, headers: ["Etag": "\"day-8\""])

        _ = try await client(cache: cache).checkItem(id: "abc123", checked: true,
                                                     evidence: nil, at: Date(),
                                                     ifMatch: "\"day-6\"")

        let entry = try XCTUnwrap(cache.load(key: SnapshotCacheKey.today))
        XCTAssertEqual(entry.body, todayBody)
        XCTAssertEqual(entry.etag, "\"day-8\"")
    }

    /// A non-2xx is not a document. Nothing is written and whatever was cached stands.
    func testAFailedDayFetchDoesNotTouchTheCache() async {
        cache.store(todayBody, key: SnapshotCacheKey.today, etag: "\"day-7\"",
                    fetchedAt: Date(timeIntervalSince1970: 1_772_530_200))
        CacheStubURLProtocol.replies["/jesse/today"] =
            .init(status: 500, body: Data("boom".utf8))

        _ = try? await client(cache: cache).getToday(ifNoneMatch: nil)

        XCTAssertEqual(cache.load(key: SnapshotCacheKey.today)?.body, todayBody)
        XCTAssertEqual(cache.load(key: SnapshotCacheKey.today)?.etag, "\"day-7\"")
    }

    // MARK: - Diet

    func testASuccessfulLiveDietFetchCachesUnderTheLiveKey() async throws {
        CacheStubURLProtocol.replies["/jesse/diet"] = .init(status: 200, body: dietBody)

        _ = try await client(cache: cache).fetchDietSnapshot(date: nil)

        XCTAssertEqual(cache.load(key: SnapshotCacheKey.liveDiet)?.body, dietBody)
        XCTAssertEqual(cache.keys(), [SnapshotCacheKey.liveDiet])
    }

    /// The key is the REQUESTED date, not the snapshot's own. A bridge too old to honour
    /// the query parameter answers with today; keying off the response would let that
    /// copy overwrite the live day's entry with itself under a past day's name.
    func testADatedDietFetchCachesUnderTheRequestedDate() async throws {
        CacheStubURLProtocol.replies["/jesse/diet"] = .init(status: 200, body: dietBody)

        _ = try await client(cache: cache).fetchDietSnapshot(date: "2026-08-19")

        XCTAssertEqual(cache.keys(), ["diet-2026-08-19"])
        XCTAssertEqual(cache.load(key: "diet-2026-08-19")?.body, dietBody)
    }

    func testAFailedDietFetchDoesNotTouchTheCache() async {
        CacheStubURLProtocol.replies["/jesse/diet"] =
            .init(status: 503, body: Data("nope".utf8))

        _ = try? await client(cache: cache).fetchDietSnapshot(date: nil)

        XCTAssertEqual(cache.keys(), [])
    }
}
