import XCTest
@testable import Jesse

// Integration tests driving the REAL `JesseClient.fetchDietSnapshot()` over a
// URLProtocol stub for `GET /jesse/diet` — the HTTP path the unit tests skip.
// Covers the happy path plus the three failure shapes the Health tab distinguishes
// (an older bridge's 404, a 503, and a 2xx with garbage JSON), and that the bearer
// header is actually sent.

/// A URLProtocol that answers `GET /jesse/diet` from a per-test (status, body).
final class DietStubURLProtocol: URLProtocol {
    struct Response { var status: Int; var body: Data }
    nonisolated(unsafe) static var response: Response?
    nonisolated(unsafe) static var lastAuthHeader: String?

    override class func canInit(with request: URLRequest) -> Bool { response != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        DietStubURLProtocol.lastAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        guard let r = DietStubURLProtocol.response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class DietSnapshotIntegrationTests: XCTestCase {

    private let cfg = JesseConfig(host: "laptop", port: 8765, token: "tok")

    override func tearDown() {
        DietStubURLProtocol.response = nil
        DietStubURLProtocol.lastAuthHeader = nil
        super.tearDown()
    }

    private func client() -> JesseClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [DietStubURLProtocol.self]
        return JesseClient(config: cfg, session: URLSession(configuration: c))
    }

    private let happyBody = """
    { "asOf": "2026-07-09T14:50:55Z", "todayMtime": "2026-07-09T13:34:54Z",
      "today": { "date": "2026-07-09", "dayStyle": "normal", "exercise": [],
        "meals": [ { "name": "Lunch", "time": "12:30", "items": [
          { "item": "Salad", "cal": 250, "p": 8, "f": 12, "c": 20, "fiber": 5 } ] } ],
        "targets": { "calories": 2100, "protein": 190, "fat": 65, "carbs": 210 } },
      "proposed": null, "progress": null, "coach": null, "weightSeries": [], "errors": [] }
    """

    func testHappyPathDecodesAndSendsBearer() async throws {
        DietStubURLProtocol.response = .init(status: 200, body: Data(happyBody.utf8))
        let snap = try await client().fetchDietSnapshot()
        XCTAssertEqual(snap.today.date, "2026-07-09")
        XCTAssertEqual(snap.today.meals.first?.items.first?.item, "Salad")
        XCTAssertEqual(DietStubURLProtocol.lastAuthHeader, "Bearer tok", "the bearer token must be sent")
    }

    func testOldBridge404IsEndpointMissing() async {
        DietStubURLProtocol.response = .init(status: 404, body: Data())
        await assertThrows(.endpointMissing)
    }

    func test503IsUnavailable() async {
        DietStubURLProtocol.response = .init(status: 503, body: Data(#"{"error":"diet-today.js unavailable"}"#.utf8))
        await assertThrows(.unavailable)
    }

    func testGarbageJSONIsDecodeFailed() async {
        DietStubURLProtocol.response = .init(status: 200, body: Data("<html>not json</html>".utf8))
        await assertThrows(.decodeFailed)
    }

    func test401IsAuthFailed() async {
        DietStubURLProtocol.response = .init(status: 401, body: Data("Unauthorized".utf8))
        await assertThrows(.authFailed)
    }

    private func assertThrows(_ expected: DietFetchError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client().fetchDietSnapshot()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as DietFetchError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("expected DietFetchError.\(expected), got \(error)", file: file, line: line)
        }
    }
}
