import XCTest
@testable import JesseNetworking

/// The artifact return channel's CLIENT side: decoding the sidecar in both directions of
/// compatibility, the device cache and its LRU cap, the traversal guard on an id, and the
/// permanent-vs-transient `404` split.
final class ArtifactWireTests: XCTestCase {

    // MARK: - Decoding the sidecar

    private func decodeResult(_ json: String) throws -> JesseResultResponse {
        try JSONDecoder().decode(JesseResultResponse.self, from: Data(json.utf8))
    }

    /// A NEWER bridge with artifacts, decoded by this app.
    func testResultDecodesArtifacts() throws {
        let obj = try decodeResult("""
        {"status":"done","response":"here they are","session_id":"s1",
         "artifacts":[
           {"id":"aa11","filename":"chart.png","mime":"image/png","bytes":2048,"sha256":"ff00"},
           {"id":"bb22","filename":"data.csv","mime":"text/csv","bytes":91,"sha256":"11ee"}]}
        """)
        let arts = try XCTUnwrap(obj.artifacts)
        XCTAssertEqual(arts.count, 2)
        XCTAssertEqual(arts[0].id, "aa11")
        XCTAssertEqual(arts[0].filename, "chart.png")
        XCTAssertEqual(arts[0].mime, "image/png")
        XCTAssertEqual(arts[0].bytes, 2048)
        XCTAssertEqual(arts[0].sha256, "ff00")
        XCTAssertEqual(arts[1].filename, "data.csv")
    }

    /// THE BACKWARD DIRECTION: an OLDER bridge with no `artifacts` key at all, and a newer
    /// bridge whose turn returned nothing (`null`). Both must decode cleanly to "none" —
    /// a throw here would break every ordinary reply.
    func testResultDecodesWithoutArtifacts() throws {
        let absent = try decodeResult(#"{"status":"done","response":"just words"}"#)
        XCTAssertNil(absent.artifacts)
        XCTAssertEqual(absent.response, "just words")

        let null = try decodeResult(#"{"status":"done","response":"x","artifacts":null}"#)
        XCTAssertNil(null.artifacts)
    }

    /// The same two directions through the SSE `done` frame, which is the path a live turn
    /// actually takes.
    func testStreamDoneFrameCarriesArtifactsAndToleratesTheirAbsence() {
        let withArts = SSEParser.decodeStreamFrame(event: "done", data: """
        {"response":"here","session_id":"s1",
         "artifacts":[{"id":"aa11","filename":"c.png","mime":"image/png","bytes":9,"sha256":"ab"}]}
        """)
        guard case let .done(reply)? = withArts else {
            return XCTFail("expected a done frame, got \(String(describing: withArts))")
        }
        XCTAssertEqual(reply.artifacts.count, 1)
        XCTAssertEqual(reply.artifacts[0].filename, "c.png")

        let without = SSEParser.decodeStreamFrame(
            event: "done", data: #"{"response":"here","session_id":"s1"}"#)
        guard case let .done(plain)? = without else {
            return XCTFail("expected a done frame")
        }
        XCTAssertTrue(plain.artifacts.isEmpty,
                      "absent means none — a pre-artifact bridge must decode unchanged")
    }

    /// A hydrated turn carries its re-attached files, and one from a bridge that predates
    /// the field decodes with none rather than failing the whole hydrate.
    func testHydratedTurnDecodesArtifactsAndDefaultsWhenAbsent() throws {
        let with = try JSONDecoder().decode(HydratedTurn.self, from: Data("""
        {"role":"assistant","text":"here","turn_key":"s1:42",
         "artifacts":[{"id":"aa","filename":"r.pdf","mime":"application/pdf",
                       "bytes":10,"sha256":"cd"}]}
        """.utf8))
        XCTAssertEqual(with.artifacts.count, 1)
        XCTAssertEqual(with.artifacts[0].mime, "application/pdf")

        let without = try JSONDecoder().decode(
            HydratedTurn.self, from: Data(#"{"role":"user","text":"hi"}"#.utf8))
        XCTAssertTrue(without.artifacts.isEmpty)
        XCTAssertEqual(without.turnKey, "", "the pre-existing default still holds")
    }

    /// A `JesseArtifact` renders as an inline image for the three IMAGE types, SVG now
    /// among them, and for nothing else.
    func testImageMimesRenderInline() {
        func art(_ mime: String) -> JesseArtifact {
            JesseArtifact(id: "a", filename: "f", mime: mime, bytes: 1, sha256: "x")
        }
        XCTAssertTrue(art("image/png").isInlineImage)
        XCTAssertTrue(art("image/jpeg").isInlineImage)
        XCTAssertTrue(art("image/svg+xml").isInlineImage)
        XCTAssertFalse(art("application/pdf").isInlineImage)
        XCTAssertFalse(art("text/html").isInlineImage)
    }

    // MARK: - The 404 split

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h/jesse/artifact/aa")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// The load-bearing distinction: `expired` is PERMANENT (the app records it and never
    /// asks again), `unknown` is not.
    func testArtifactFetchSplitsTheTwoShapesOf404() {
        XCTAssertThrowsError(try JesseBridgeClient.decodeArtifact(
            data: Data(#"{"error":"gone","reason":"expired"}"#.utf8), resp: response(404))
        ) { XCTAssertEqual($0 as? ArtifactFetchError, .expired) }

        XCTAssertThrowsError(try JesseBridgeClient.decodeArtifact(
            data: Data(#"{"error":"no such artifact","reason":"unknown"}"#.utf8), resp: response(404))
        ) { XCTAssertEqual($0 as? ArtifactFetchError, .unknown) }

        // A 404 whose body we cannot read is treated as UNKNOWN, never expired: `expired`
        // is the permanent verdict, and reaching it by guessing would strand a file that
        // is actually still there.
        XCTAssertThrowsError(try JesseBridgeClient.decodeArtifact(
            data: Data("not json".utf8), resp: response(404))
        ) { XCTAssertEqual($0 as? ArtifactFetchError, .unknown) }

        XCTAssertThrowsError(try JesseBridgeClient.decodeArtifact(data: Data(), resp: response(401))
        ) { XCTAssertEqual($0 as? ArtifactFetchError, .authFailed) }
        XCTAssertThrowsError(try JesseBridgeClient.decodeArtifact(data: Data(), resp: response(503))
        ) { XCTAssertEqual($0 as? ArtifactFetchError, .server(503)) }

        let ok = try? JesseBridgeClient.decodeArtifact(data: Data([1, 2, 3]), resp: response(200))
        XCTAssertEqual(ok, Data([1, 2, 3]))
    }

    // MARK: - The device cache

    private func tempCache(maxBytes: Int = ArtifactCache.defaultMaxBytes) -> ArtifactCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-artifact-cache-\(UUID().uuidString)", isDirectory: true)
        return ArtifactCache(directory: dir, maxBytes: maxBytes)
    }

    /// THE TRAVERSAL GUARD, applied again on the device because this is what turns a
    /// string into a path here.
    func testCacheRejectsAnythingButLowercaseHex() {
        XCTAssertTrue(ArtifactCache.isValidID("00ff11aa"))
        XCTAssertFalse(ArtifactCache.isValidID(""))
        XCTAssertFalse(ArtifactCache.isValidID(".."))
        XCTAssertFalse(ArtifactCache.isValidID("../../etc/passwd"))
        XCTAssertFalse(ArtifactCache.isValidID("aa/bb"))
        XCTAssertFalse(ArtifactCache.isValidID("AABB"))
        XCTAssertFalse(ArtifactCache.isValidID(String(repeating: "a", count: 65)))

        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        XCTAssertNil(cache.url(for: "../escape", mime: "image/png"))
        XCTAssertThrowsError(try cache.store(id: "../escape", mime: "image/png", data: Data([1])))
    }

    /// Store, hit, and the size check that catches a truncated write rather than trusting
    /// a file because it exists.
    func testCacheStoresAndValidatesBySize() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let bytes = Data(repeating: 7, count: 100)
        let url = try cache.store(id: "aa11", mime: "image/png", data: bytes)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(cache.cached(id: "aa11", mime: "image/png", expectedBytes: 100))
        XCTAssertNil(cache.cached(id: "aa11", mime: "image/png", expectedBytes: 99),
                     "a size mismatch is a truncated write, not a cache hit")
        XCTAssertNil(cache.cached(id: "bb22", mime: "image/png", expectedBytes: 100))
        cache.remove(id: "aa11", mime: "image/png")
        XCTAssertNil(cache.cached(id: "aa11", mime: "image/png", expectedBytes: 100))
    }

    /// THE DEVICE BUDGET: least-recently-used files go first, and a file the user keeps
    /// opening survives one they downloaded once.
    func testCacheEvictsLeastRecentlyUsedOverItsCap() throws {
        let cache = tempCache(maxBytes: 250)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        for id in ["aa", "bb", "cc"] {
            try cache.store(id: id, mime: "image/png", data: Data(repeating: 1, count: 100))
            // Distinct modification dates, so "least recently used" is a real order.
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Three 100-byte files = 300 > 250, so the store above already evicted one — and
        // it must be the oldest.
        XCTAssertLessThanOrEqual(cache.totalBytes(), 250)
        XCTAssertNil(cache.cached(id: "aa", mime: "image/png", expectedBytes: 100),
                     "the oldest went first")
        XCTAssertNotNil(cache.cached(id: "cc", mime: "image/png", expectedBytes: 100),
                        "the newest survives")

        // A HIT on "bb" makes it the most recent, so the next arrival evicts "cc".
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertNotNil(cache.cached(id: "bb", mime: "image/png", expectedBytes: 100))
        Thread.sleep(forTimeInterval: 0.02)
        try cache.store(id: "dd", mime: "image/png", data: Data(repeating: 1, count: 100))
        XCTAssertNotNil(cache.cached(id: "bb", mime: "image/png", expectedBytes: 100),
                        "reading a file counts as using it — that is what makes this LRU")
        XCTAssertNil(cache.cached(id: "cc", mime: "image/png", expectedBytes: 100))
    }

    // MARK: - The resolver

    /// A cache hit is served without touching the network, and it wins even for an
    /// artifact already known to be expired: the file is right here.
    func testResolverPrefersTheCacheAndHonoursTheStickyVerdict() async throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try cache.store(id: "aa11", mime: "image/png", data: Data(repeating: 3, count: 40))

        let hit = await ArtifactResolver.resolve(
            id: "aa11", mime: "image/png", byteCount: 40, filename: "c.png",
            isExpired: false, cache: cache,
            fetch: { _ in XCTFail("a cache hit must not fetch"); return Data() })
        guard case let .ready(url) = hit else { return XCTFail("expected ready, got \(hit)") }
        XCTAssertEqual(try Data(contentsOf: url).count, 40)

        let expiredButCached = await ArtifactResolver.resolve(
            id: "aa11", mime: "image/png", byteCount: 40, filename: "c.png",
            isExpired: true, cache: cache,
            fetch: { _ in XCTFail("must not fetch"); return Data() })
        guard case .ready = expiredButCached else {
            return XCTFail("a cached copy still shows: the bridge's TTL is not this device's")
        }

        // No cached copy AND already expired: the permanent verdict, with NO network call.
        // This is the check that stops the retry loop.
        let expired = await ArtifactResolver.resolve(
            id: "bb22", mime: "image/png", byteCount: 10, filename: "c.png",
            isExpired: true, cache: cache,
            fetch: { _ in XCTFail("an expired artifact must never reach the network"); return Data() })
        XCTAssertEqual(expired, .expired)
    }

    /// A miss downloads, caches, and maps each failure onto something the user can act on.
    func testResolverDownloadsCachesAndReportsFailures() async throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let fetched = await ArtifactResolver.resolve(
            id: "cc33", mime: "image/png", byteCount: 5, filename: "c.png",
            isExpired: false, cache: cache,
            fetch: { _ in Data([1, 2, 3, 4, 5]) })
        guard case .ready = fetched else { return XCTFail("expected ready, got \(fetched)") }
        XCTAssertNotNil(cache.cached(id: "cc33", mime: "image/png", expectedBytes: 5),
                        "and it was cached")

        let expired = await ArtifactResolver.resolve(
            id: "dd44", mime: "image/png", byteCount: 5, filename: "c.png",
            isExpired: false, cache: cache,
            fetch: { _ in throw ArtifactFetchError.expired })
        XCTAssertEqual(expired, .expired)

        let unknown = await ArtifactResolver.resolve(
            id: "ee55", mime: "image/png", byteCount: 5, filename: "chart.png",
            isExpired: false, cache: cache,
            fetch: { _ in throw ArtifactFetchError.unknown })
        guard case let .failed(message) = unknown else {
            return XCTFail("unknown is TRANSIENT — it must not become the permanent verdict")
        }
        XCTAssertTrue(message.contains("chart.png"), message)
    }
}
