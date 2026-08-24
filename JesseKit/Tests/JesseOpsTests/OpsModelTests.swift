import XCTest
import JesseNetworking
@testable import JesseOps

// The two view models' stated invariants, driven through the same `URLProtocol` stub the wire
// tests use. Each of these is a claim written in a comment at the top of its model; a comment
// nobody can break is not an invariant.

@MainActor
final class OpsModelTests: XCTestCase {

    private let bridge = JesseConfig(host: "studio", port: 8765, token: "b")
    private let sentinel = SentinelConfig(host: "studio", port: 8766, token: "s")

    override func setUp() {
        super.setUp()
        StagedProtocol.reset()
    }

    private func configuration(withSentinel: Bool = true) -> OpsConfiguration {
        OpsConfiguration(bridge: bridge,
                         sentinel: withSentinel ? sentinel : SentinelConfig(host: "", token: ""),
                         session: StagedProtocol.session())
    }

    // MARK: - Ops

    /// A FAILED REFRESH NEVER BLANKS A LOADED SCREEN. The status page is read at the moment
    /// something is wrong, which is the moment a probe times out and the call fails — replacing
    /// a loaded document with an empty state then says strictly less than the stale one did.
    func testAFailedRefreshKeepsTheLastGoodStatusOnScreen() async throws {
        let model = OpsModel(configuration: configuration())

        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.healthyStatus,
                             for: "/sentinel/status")
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.deployRunning,
                             for: "/sentinel/deploy/status")
        await model.refresh()
        XCTAssertEqual(model.status?.sentinel?.version, "0.94.0")
        XCTAssertNil(model.refreshError)

        StagedProtocol.stage(status: 502, body: #"{"error":"the sentinel is not answering"}"#,
                             for: "/sentinel/status")
        StagedProtocol.stage(status: 502, body: #"{"error":"the sentinel is not answering"}"#,
                             for: "/sentinel/deploy/status")
        await model.refresh()

        XCTAssertEqual(model.status?.sentinel?.version, "0.94.0",
                       "the loaded document survives a failed refresh")
        XCTAssertNotNil(model.refreshError)
        XCTAssertTrue(try XCTUnwrap(model.refreshError).contains("not answering"),
                      "…behind the sentinel's own reason")
    }

    /// An unpaired sentinel reads NOTHING rather than failing: there is no host to ask, and the
    /// screen's answer is a call to action, not an error.
    func testAnUnpairedSentinelRefreshesToNothing() async {
        let model = OpsModel(configuration: configuration(withSentinel: false))
        await model.refresh()

        XCTAssertFalse(model.isSentinelPaired)
        XCTAssertNil(model.status)
        XCTAssertNil(model.refreshError)
        XCTAssertTrue(StagedProtocol.requests.isEmpty, "nothing was asked of nobody")
    }

    /// A VERB'S OUTCOME IS SHOWN, NOT INFERRED. For the bridge restart that means `healthy` and
    /// `version` — "is it back, and is it the build I wanted" is the question the press asked,
    /// and a green tick on a 200 answers a different one.
    func testARestartReportsHealthyAndVersion() async {
        let model = OpsModel(configuration: configuration())

        StagedProtocol.stage(status: 200,
                             body: #"{"service":"bridge","label":"com.example.jesse-bridge","restarted":true,"healthy":true,"version":"0.94.0"}"#)
        // …then the refresh the verb triggers.
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.healthyStatus,
                             for: "/sentinel/status")
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.deployRunning,
                             for: "/sentinel/deploy/status")

        await model.restart(.bridge)

        let outcome = model.lastVerb
        XCTAssertEqual(outcome?.succeeded, true)
        XCTAssertEqual(outcome?.verb, "restart bridge")
        XCTAssertEqual(outcome?.detail, "back up, healthy, running 0.94.0")
    }

    /// A restart that came back UNHEALTHY is not a success with a tick on it.
    func testARestartThatDoesNotComeBackHealthySaysSo() async {
        let model = OpsModel(configuration: configuration())

        StagedProtocol.stage(status: 200,
                             body: #"{"service":"bridge","restarted":true,"healthy":false,"version":null}"#)
        StagedProtocol.stage(status: 500, body: "{}", for: "/sentinel/status")
        StagedProtocol.stage(status: 500, body: "{}", for: "/sentinel/deploy/status")

        await model.restart(.bridge)
        XCTAssertEqual(model.lastVerb?.detail, "restarted, but it did not come back healthy")
    }

    /// A refused verb keeps the sentinel's sentence, which is the only actionable thing about
    /// a 409 here.
    func testARefusedVerbCarriesTheReason() async throws {
        let model = OpsModel(configuration: configuration())

        StagedProtocol.stage(status: 409,
                             body: #"{"removed":false,"reason":"no index.lock present"}"#)
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.healthyStatus,
                             for: "/sentinel/status")
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.deployRunning,
                             for: "/sentinel/deploy/status")

        await model.unlockGit()
        XCTAssertEqual(model.lastVerb?.succeeded, false)
        XCTAssertTrue(try XCTUnwrap(model.lastVerb?.detail).contains("no index.lock present"))
    }
}

@MainActor
final class ScheduleModelTests: XCTestCase {

    private let bridge = JesseConfig(host: "studio", port: 8765, token: "b")

    override func setUp() {
        super.setUp()
        StagedProtocol.reset()
    }

    private func loaded() async -> ScheduleModel {
        let model = ScheduleModel(configuration: OpsConfiguration(
            bridge: bridge, sentinel: SentinelConfig(host: "", token: ""),
            session: StagedProtocol.session()))
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.schedule)
        await model.refresh()
        return model
    }

    /// A FAILED REFRESH NEVER BLANKS A LOADED SCHEDULE.
    func testAFailedRefreshKeepsTheSchedule() async {
        let model = await loaded()
        XCTAssertEqual(model.document?.jobs.count, 4)

        StagedProtocol.stage(status: 503, body: "the bridge is restarting")
        await model.refresh()

        XCTAssertEqual(model.document?.jobs.count, 4, "still on screen")
        XCTAssertNotNil(model.loadError)
    }

    /// AN ENABLE APPLIES THE ROW THE BRIDGE ANSWERS WITH, not the one the toggle assumed —
    /// which is what makes an override's deadline correct without a second round trip.
    func testEnableSplicesTheAnsweredRow() async {
        let model = await loaded()
        XCTAssertEqual(model.document?.jobs.first { $0.id == "overnight" }?.enabled, true)

        StagedProtocol.stage(status: 200, body: #"""
        {"id":"overnight","enabled":false,"enabled_config":true,"kind":"head","after":null,
         "at":"03:30","override":{"enabled":false,"until_ms":1756300000000,
                                  "set_ms":1756000000000,"active":true}}
        """#)
        await model.setEnabled(id: "overnight", enabled: false,
                               until: Date(timeIntervalSince1970: 1_756_300_000))

        let row = model.document?.jobs.first { $0.id == "overnight" }
        XCTAssertEqual(row?.enabled, false)
        XCTAssertEqual(row?.override?.untilMs, 1_756_300_000_000)
        XCTAssertEqual(StagedProtocol.requests.count, 2,
                       "the answered row is enough — no follow-up GET")
    }

    /// The sentinel's proxy wraps the same row in `bridge_body`, and both shapes have to work:
    /// which one arrives depends on configuration, and a screen that understood only one would
    /// silently stop updating for half its users.
    func testEnableAlsoReadsTheProxysWrapper() async {
        let model = await loaded()
        StagedProtocol.stage(status: 200, body: #"""
        {"bridge_status":200,
         "bridge_body":{"id":"weekly","enabled":true,"kind":"head","at":"09:00"}}
        """#)
        await model.setEnabled(id: "weekly", enabled: true, until: nil)

        XCTAssertEqual(model.document?.jobs.first { $0.id == "weekly" }?.enabled, true)
    }

    /// A `409` IS NOT AN ERROR, IT IS AN ANSWER, and it belongs on the row that asked rather
    /// than in a banner over the whole screen.
    func testAConflictLandsOnTheRow() async throws {
        let model = await loaded()
        StagedProtocol.stage(status: 409,
                             body: #"the chain headed by "overnight" is already running"#)
        // …and the refresh a fire always triggers.
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.schedule)

        await model.fire(id: "overnight")

        XCTAssertTrue(try XCTUnwrap(model.rowMessages["overnight"]).contains("already running"))
        XCTAssertNil(model.loadError, "the screen itself is fine; one row was refused")
    }

    /// The reload's own report is kept apart from a load failure: a reload that REFUSED a bad
    /// file is a success of the reload and a failure of the file, and collapsing them hides
    /// which.
    func testReloadKeepsItsErrorsSeparateAndTakesTheFreshDocument() async {
        let model = await loaded()
        StagedProtocol.stage(status: 200,
                             body: #"{"reloaded":false,"errors":["entry 3: `at` must be HH:MM"],"schedule":"#
                                + OpsDocumentDecodeTests.schedule + "}")
        await model.reloadConfig()

        XCTAssertEqual(model.reloadReport?.reloaded, false)
        XCTAssertEqual(model.reloadReport?.errors, ["entry 3: `at` must be HH:MM"])
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.document?.jobs.count, 4)
    }
}

@MainActor
final class AwayModelTests: XCTestCase {

    private let bridge = JesseConfig(host: "studio", port: 8765, token: "b")

    override func setUp() {
        super.setUp()
        StagedProtocol.reset()
    }

    private func model() -> AwayModel {
        AwayModel(configuration: OpsConfiguration(
            bridge: bridge, sentinel: SentinelConfig(host: "", token: ""),
            session: StagedProtocol.session()))
    }

    /// Going away sends the zone and an RFC 3339 deadline, and takes the document the POST
    /// answers with — so the banner and the switch cannot disagree for a round trip.
    func testGoingAwayPostsTheZoneAndDeadlineAndTakesTheAnswer() async throws {
        let m = model()
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.awayProfile)

        let ok = await m.goAway(tz: "America/New_York",
                                until: Date(timeIntervalSince1970: 1_756_500_000),
                                note: "conference")

        XCTAssertTrue(ok)
        XCTAssertEqual(m.profile?.name, "away")
        XCTAssertNotNil(m.bannerText)
        let sent = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: StagedProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(sent["name"] as? String, "away")
        XCTAssertEqual(sent["tz"] as? String, "America/New_York")
        XCTAssertEqual(sent["note"] as? String, "conference")
        XCTAssertEqual(sent["until"] as? String,
                       OpsFormat.rfc3339(Date(timeIntervalSince1970: 1_756_500_000)),
                       "an RFC 3339 instant, which is what the bridge parses")
    }

    /// Coming home sends the NAME AND NOTHING ELSE. The bridge ignores zone, deadline and note
    /// for `home`, and sending them would imply they meant something.
    func testComingHomeSendsOnlyTheName() async {
        let m = model()
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.lapsedProfile)

        let ok = await m.goHome()
        XCTAssertTrue(ok)
        XCTAssertEqual(String(data: StagedProtocol.bodies[0], encoding: .utf8), #"{"name":"home"}"#)
        XCTAssertNil(m.bannerText, "nothing is in force, so no banner")
    }

    /// The bridge's own refusal is passed through verbatim rather than pre-empted locally: a
    /// client-side copy of a server-side rule is one release away from refusing something the
    /// bridge would have accepted, and the failure then looks like a bug in the phone.
    func testTheBridgesRefusalIsShownVerbatim() async throws {
        let m = model()
        StagedProtocol.stage(status: 400,
                             body: "`until` is in the past (2020-01-01T00:00:00Z) — an away profile expires by itself")

        let ok = await m.goAway(tz: "America/New_York",
                                until: Date(timeIntervalSince1970: 1_577_836_800), note: "")
        XCTAssertFalse(ok)
        XCTAssertTrue(try XCTUnwrap(m.saveError).contains("expires by itself"))
    }

    /// A lapsed period is on record but NOT in force, and the banner keys off the latter.
    func testALapsedPeriodShowsNoBanner() async {
        let m = model()
        StagedProtocol.stage(status: 200, body: OpsDocumentDecodeTests.lapsedProfile)
        await m.refresh()

        XCTAssertEqual(m.profileName, "home")
        XCTAssertNotNil(m.profile?.untilMs, "the record is still there")
        XCTAssertNil(m.bannerText)
    }
}

// MARK: - A stub that answers a queue

/// Like `CapturingProtocol`, but each request takes the NEXT staged answer rather than one
/// canned reply. The models make several calls per action — a verb and then the refresh it
/// triggers — and a single canned answer cannot express "the verb was refused and the refresh
/// then worked", which is most of what is worth testing here.
///
/// ## Why a reply may name the path it is for
///
/// Arrival order is NOT declaration order when a caller issues requests CONCURRENTLY, and
/// `OpsModel.refresh()` does exactly that (`async let statusBytes` / `async let
/// deployBytes`). A strictly first-in-first-out queue therefore hands whichever request
/// happens to reach `startLoading` first the reply meant for the other one — the status
/// document decodes the deploy card, `status` stays nil, and the test fails with a
/// `keyNotFound` for a key the fixture never had.
///
/// That is a race in the STUB, not in the model, and it passed for a long time on luck.
/// So a reply may declare the path it answers, and a request prefers a reply that names
/// its own path. Un-named replies keep the plain FIFO behaviour every sequential test
/// relies on; only the concurrent pair needs naming.
final class StagedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [(path: String?, status: Int, body: Data)] = []
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var seenBodies: [Data] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        seen = []
        seenBodies = []
    }

    /// Stage the next reply for whichever request arrives next. Correct for a sequential
    /// caller, which is most of them.
    static func stage(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append((nil, status, Data(body.utf8)))
    }

    /// Stage a reply for a NAMED path — what a concurrent caller needs, so which reply
    /// each request gets is a fact rather than a race. See the note on this type.
    static func stage(status: Int, body: String, for path: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append((path, status, Data(body.utf8)))
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return seenBodies
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StagedProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        // `URLProtocol` is handed the body as a STREAM once URLSession has taken the request,
        // so `httpBody` is nil by the time it gets here. Draining the stream is what makes the
        // body assertions below assert anything at all rather than pass on empty Data.
        Self.seenBodies.append(Self.drain(request))
        // An empty queue answers 200 `{}` rather than hanging: a test that staged too few
        // replies should fail on its assertion, not time out.
        //
        // A reply that NAMES this request's path wins over the head of the queue; that is
        // what makes a concurrently-issued pair deterministic. Nothing else changes: with
        // no named replies staged, this is the FIFO it always was.
        let path = request.url?.path ?? ""
        let index = Self.queue.firstIndex { $0.path == path }
            ?? Self.queue.firstIndex { $0.path == nil }
            ?? (Self.queue.isEmpty ? nil : 0)
        let status: Int, body: Data
        if let index {
            let staged = Self.queue.remove(at: index)
            (status, body) = (staged.status, staged.body)
        } else {
            (status, body) = (200, Data("{}".utf8))
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }
}
