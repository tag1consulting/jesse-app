import Foundation
import JesseCore

// The one bridge client both apps use. It owns the HTTP contract: endpoint/URL
// construction, the bearer-auth request builder, ETag handling, the SSE stream, and
// error mapping. Before this, the iOS `JesseClient` and the Mac `MacJesseClient`
// re-implemented all of it from scratch with slightly different names. Everything here
// is view-free and health-free; the iOS app layers the per-turn `health_context` body
// on top (see the app-side `JesseClient`), and the Mac app calls this directly.
//
// `Sendable` because a turn's stream and poll race in two concurrent child tasks, so the
// client value crosses into them; it is an immutable value of `Sendable` parts.

/// The cross-platform surface a bridge client exposes — every endpoint that needs no
/// iOS-only data. Pulled behind a protocol so a fake can exercise callers in tests.
///
/// Refines `FlagSyncing` (JesseCore) so the shared `FlagReconciler` can push a
/// local-newer favorite/archive change through any bridge client. `FlagSyncing` carries a
/// default no-op `setFlags`, so a test fake conforming to this protocol keeps compiling
/// without implementing it; the real `JesseBridgeClient` overrides it below.
public protocol BridgeClientProtocol: FlagSyncing, Sendable {
    var config: JesseConfig { get }
    func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult
    /// Send a turn. `requestId` (the bridge's idempotency key) and `conversationId` (the
    /// thread identity) are BOTH required rather than defaulted: a caller that omitted the
    /// request id disabled the bridge's own dedup for exactly the traffic that needs it, and
    /// a caller that omitted the conversation id made the bridge mint one the client would
    /// then not recognize. There is deliberately no overload that lets either be dropped.
    func send(mode: JesseMode, text: String, sessionId: String?, conversationId: String,
              voice: Bool, instructions: String?, floorOverride: String?,
              attachments: [JesseRequest.Attachment], requestId: String,
              model: String?) async throws -> JesseSendResult
    func result(jobId: String) async throws -> JesseResultState
    /// Fetch ONE returned file's bytes. The reply carries only metadata, so this is the
    /// one call content moves on. A `404` is an `ArtifactFetchError.expired` or
    /// `.unknown` — the app renders those differently, and neither is retryable.
    func artifact(id: String) async throws -> Data
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error>
    func listConversations(since: UInt64?, etag: String?) async throws -> ConversationsResult
    /// Hydrate a conversation's history across every transcript bound to it. `after` is the
    /// bridge's OPAQUE cursor (nil for the whole history); the returned `nextCursor` is
    /// echoed back next time.
    func hydrate(conversationId: String, after cursor: String?) async throws
        -> (turns: [HydratedTurn], nextCursor: String)
    func title(text: String, conversationId: String?) async -> String?
    func cancelJob(jobId: String) async throws
    func deleteConversation(_ conversationId: String) async throws
    func health() async throws -> BridgeHealth
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot
    func fetchPrompts() async throws -> PromptDefaults
}

public extension BridgeClientProtocol {
    /// Default "never stored here": a conformer that does not model the artifact channel
    /// behaves exactly like a bridge that has no such id, so an existing fake keeps
    /// compiling and renders the same empty state a bridge without the channel would.
    ///
    /// Deliberately `.unknown` and NOT `.expired` — `.expired` is the PERMANENT verdict a
    /// view writes onto the store and never revisits, and a default must never be able to
    /// reach it.
    func artifact(id: String) async throws -> Data { throw ArtifactFetchError.unknown }
}

public struct JesseBridgeClient: BridgeClientProtocol {
    public var config: JesseConfig

    /// The URLSession the **short** request/response calls go through. Defaults to the
    /// bounded production session; injectable purely so tests can supply a session
    /// backed by a custom `URLProtocol` stub.
    public let session: URLSession

    /// The URLSession the long-lived **SSE stream** goes through — a different session
    /// from the short calls, so a stalled stream can never make the completion poll wait.
    public let streamSession: URLSession

    /// The URLSession `POST /jesse` goes through — a third session, because a send is the
    /// one call whose failure LOSES something. See `sendingSession`.
    public let sendSession: URLSession

    /// Where a successful read of the two BROWSABLE documents (the day file and the diet
    /// snapshot) leaves its body, so a later launch with no network has something true
    /// to draw. `nil` — the default — means this client caches nothing, which is what
    /// every client but the two tabs' own wants: a probe, a send, or a test has no
    /// business writing the screen's fallback.
    ///
    /// The WRITE lives here, at the one place the bridge's own bytes exist, rather than
    /// in the display models: the models are handed decoded values, and re-encoding them
    /// would mean a second definition of the wire format. See `SnapshotCache`.
    public let snapshotCache: SnapshotCache?

    public init(config: JesseConfig,
                session: URLSession = JesseBridgeClient.boundedSession,
                streamSession: URLSession? = nil,
                snapshotCache: SnapshotCache? = nil) {
        self.config = config
        self.session = session
        self.snapshotCache = snapshotCache
        if let streamSession {
            self.streamSession = streamSession
        } else if session === JesseBridgeClient.boundedSession {
            // Production path: short calls on the bounded session, the SSE stream on the
            // long-lived one.
            self.streamSession = JesseBridgeClient.streamingSession
        } else {
            // A test injected a stub `session` but no `streamSession`; route the stream
            // through that same stub so one stub serves all endpoints.
            self.streamSession = session
        }
        // Same rule for the send session, and for the same reason: a test that injects one
        // stub expects every endpoint — sends included — to go through it.
        self.sendSession = session === JesseBridgeClient.boundedSession
            ? JesseBridgeClient.sendingSession
            : session
        // Only a client on the PRODUCTION sessions is evidence about the real bridge. A
        // test's `URLProtocol` stub answers whatever the test scripted, so letting it
        // drive the app-wide reachability state would make one test's fixture the next
        // test's starting condition.
        self.reportsReachability = session === JesseBridgeClient.boundedSession
    }

    /// Whether this client's request outcomes feed `BridgeReachabilityModel.shared`.
    /// True only for a client built on the production session — see `init`.
    public let reportsReachability: Bool

    // The short request/response calls get a BOUNDED per-request deadline and do NOT
    // wait for connectivity, so each one always either answers or throws — the
    // completion poll loop can then do its job.
    public static let boundedSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // A SEND is the one call whose failure loses something: the reply is on the other
    // side of it, and the message is in the outbox until it is ACKed. So unlike every
    // other short call it WAITS for connectivity rather than failing fast — walking into a
    // tunnel with a message half-sent should mean the send completes on the far side, not
    // a "Not delivered" line the user has to notice and tap.
    //
    // The resource timeout is the real bound: `waitsForConnectivity` suspends the request
    // timer until there IS a path, so `timeoutIntervalForRequest` alone would never fire
    // in airplane mode. 120s caps the whole thing, after which the outbox's own backoff
    // takes over — which is the right owner of a wait measured in minutes.
    public static let sendingSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    // The SSE stream legitimately stays open for the whole turn — agent runs can exceed
    // any fixed cap. Give it a day-long ceiling and let it wait for connectivity; the
    // UI's Cancel button is the escape hatch. Used ONLY by `stream()`.
    public static let streamingSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 86_400
        c.timeoutIntervalForResource = 86_400
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    // MARK: - The device's zone

    /// The IANA zone this device is standing in, as every `/jesse` request reports it.
    ///
    /// Read fresh at each call rather than cached: `TimeZone.current` changes under a
    /// travelling phone, and a value captured at launch would keep telling the bridge where
    /// the person WAS. An unnamed zone (a raw GMT offset) yields an identifier the tz
    /// database does not know, which the bridge ignores in favour of the profile — the same
    /// path an older app build takes.
    public static var clientTimeZone: String { TimeZone.current.identifier }

    // MARK: - Request building

    /// Build a bearer-authed request for `path`. Returns nil for an unconfigured/invalid
    /// host so the caller can throw a clean `notConfigured`.
    private func authorized(_ path: String, method: String,
                            requireToken: Bool = true) -> URLRequest? {
        guard !config.normalizedHost.isEmpty, !(requireToken && config.token.isEmpty),
              let url = config.endpoint(path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !config.token.isEmpty {
            req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Performing a request

    /// Perform one short call, map a transport failure to a `JesseError` naming the host,
    /// and tell the shared reachability model what just happened.
    ///
    /// The twelve endpoints below each used to spell this out for themselves. Collapsing
    /// them is not tidying: "the last request outcome" only means anything if EVERY
    /// request reports it, and twelve copies is twelve chances for the next endpoint to
    /// be the one that does not.
    private func perform(_ req: URLRequest, on session: URLSession? = nil) async throws
        -> (Data, URLResponse) {
        do {
            let out = try await (session ?? self.session).data(for: req)
            noteReachability(true)
            return out
        } catch {
            noteReachability(reachedBridge: false, error: error)
            throw JesseError.from(error, host: config.normalizedHost)
        }
    }

    /// Report a completed exchange. `true` means THE BRIDGE ANSWERED — not that it liked
    /// the request. A `404` for an unknown job id is as good a proof of reachability as a
    /// reply, so status codes are deliberately not consulted here.
    private func noteReachability(_ reachedBridge: Bool) {
        guard reportsReachability else { return }
        Task { @MainActor in
            BridgeReachabilityModel.shared.noteRequestOutcome(succeeded: reachedBridge)
        }
    }

    /// The failure half, which has one exception: a CANCELLED load says nothing about the
    /// network. The user tapped Cancel, or a racing sibling task won — treating that as
    /// "the bridge is unreachable" would put an offline banner on the screen every time
    /// someone stops a turn.
    private func noteReachability(reachedBridge: Bool, error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        noteReachability(reachedBridge)
    }

    // MARK: - Send

    /// Send a health-free turn. The bridge treats an omitted `health_context` as an
    /// ordinary turn, so this is exactly what the Mac uses; the iOS layer builds a
    /// health-laden `JesseRequest` and calls `sendPrepared`.
    ///
    /// `conversationId` and `requestId` are required, with no overload that drops them: the
    /// conversation is the thread identity the 202 echoes back, and the request id is the
    /// bridge's idempotency key. A nil/blank `model` omits that field, so the bridge uses
    /// its stored default.
    public func send(mode: JesseMode, text: String, sessionId: String?, conversationId: String,
                     voice: Bool, instructions: String?, floorOverride: String?,
                     attachments: [JesseRequest.Attachment],
                     requestId: String, model: String?) async throws -> JesseSendResult {
        let request = Self.makeRequest(mode: mode, text: text, sessionId: sessionId,
                                       conversationId: conversationId,
                                       voice: voice, instructions: instructions,
                                       floorOverride: floorOverride, attachments: attachments,
                                       requestId: requestId, model: model)
        return try await sendPrepared(request)
    }

    /// Encode + POST a fully-built `/jesse` request body and decode the send result. The
    /// seam the iOS layer uses to send a turn carrying the `health_context` block.
    ///
    /// # The device stamps
    ///
    /// THE ONE PLACE a turn's `client_tz` and `sent_at` are set. Stamped here rather than
    /// by each caller: the iOS layer builds its own health-laden `JesseRequest` and calls
    /// straight into this method, so a per-caller stamp would be one build away from a
    /// turn whose dates are derived in the wrong zone — or from the wrong instant.
    ///
    /// `sent_at` is stamped ONCE, before the first attempt, and the re-send below reuses
    /// it. That is the whole point of the field: an entry the message gave no time for is
    /// dated from when the phone SENT it, so a turn that waited two minutes for a tunnel
    /// to end must not be dated from the far side of the tunnel.
    ///
    /// # The re-send
    ///
    /// A transport failure here is ambiguous in the one way that matters: the body may
    /// already have reached the bridge, and a turn may already be running. Retrying is
    /// safe BY CONSTRUCTION rather than by hope — the request carries a `request_id`, the
    /// bridge dedups on it, and a re-send of a POST that landed returns the SAME job id
    /// with no second turn spawned (see "Idempotency key" in `bridge/README.md`). One
    /// retry, not a loop: past that the send outbox owns it, on a schedule measured in
    /// minutes rather than in socket timeouts.
    ///
    /// A request with NO `request_id` is not retried. There is no such caller today, and
    /// if one ever appears, a duplicate turn is a worse outcome than a surfaced error.
    public func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult {
        guard var req = authorized("/jesse", method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let stamped = request.stamped(clientTz: Self.clientTimeZone, sentAt: Self.sentAtStamp())
        req.httpBody = try Self.encodeBody(stamped)
        do {
            let (data, resp) = try await perform(req, on: sendSession)
            return try Self.decodeSend(data: data, resp: resp)
        } catch let error as JesseError where Self.isResendable(error, request: stamped) {
            let (data, resp) = try await perform(req, on: sendSession)
            return try Self.decodeSend(data: data, resp: resp)
        }
    }

    /// Whether a failed send may be re-sent on the same `request_id`.
    ///
    /// Only a TRANSPORT failure: the bridge either never saw the request or saw it and
    /// could not answer, and its dedup covers both. A `badResponse` is the bridge
    /// answering — a 401, a 429, a 413 — and re-sending it would repeat a request that was
    /// understood and refused. `notConfigured` and `decoding` never reached the wire.
    static func isResendable(_ error: JesseError, request: JesseRequest) -> Bool {
        guard let id = request.requestId, !id.isEmpty else { return false }
        switch error {
        case .cannotFindHost, .cannotConnect, .timedOut, .connectionLost, .transport:
            return true
        // ATS refused the load locally; the bytes never left the device and never will,
        // so a retry is a second identical refusal.
        case .insecureBlocked, .notConfigured, .badResponse, .decoding:
            return false
        }
    }

    /// The instant this device says it sent the turn: RFC3339 with the DEVICE's offset,
    /// not UTC.
    ///
    /// The offset is the load-bearing half. The bridge derives a diet day from
    /// `sent_at` minus four hours in the effective zone, and an offset-less stamp would
    /// hand it an instant with no statement about which clock the person was reading.
    /// `.withInternetDateTime` already includes the colon separator RFC3339 requires.
    static func sentAtStamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Poll

    /// Poll a job started by `send`. Used after a dropped socket (or while the turn
    /// outran the grace window) to fetch the completed reply by id.
    public func result(jobId: String) async throws -> JesseResultState {
        guard let req = authorized("/jesse/result/\(jobId)", method: "GET") else {
            throw JesseError.notConfigured
        }
        let (data, resp) = try await perform(req)
        return try Self.decodeResult(data: data, resp: resp)
    }

    // MARK: - Artifacts

    /// `GET /jesse/artifact/{id}` — the bytes of one file a turn returned.
    public func artifact(id: String) async throws -> Data {
        guard let req = authorized("/jesse/artifact/\(id)", method: "GET") else {
            throw JesseError.notConfigured
        }
        let (data, resp) = try await perform(req)
        return try Self.decodeArtifact(data: data, resp: resp)
    }

    /// Map an artifact fetch response to its bytes, or to the error the UI renders.
    ///
    /// The `404` split is the load-bearing part. `expired` is PERMANENT — the file is
    /// gone from the server and no amount of retrying brings it back — so the caller
    /// records it once and never asks again. Anything else may be transient.
    public static func decodeArtifact(data: Data, resp: URLResponse) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { throw ArtifactFetchError.decodeFailed }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ArtifactFetchError.authFailed
        case 404:
            // The body names which of the two it is. A body we cannot read is treated as
            // `unknown` rather than `expired`: `expired` is the permanent verdict, and
            // reaching it by guessing would strand a file that is actually still there.
            let reason = (try? JSONDecoder().decode(ArtifactMissBody.self, from: data))?.reason
            throw reason == "expired" ? ArtifactFetchError.expired : ArtifactFetchError.unknown
        default:
            throw ArtifactFetchError.server(http.statusCode)
        }
    }

    // MARK: - Health

    /// Probe `GET /health` and parse the bridge's reported version. The version is
    /// returned unconditionally, but we still send the bearer (when set) so this reuses
    /// the same auth shape as every other call.
    public func health() async throws -> BridgeHealth {
        guard let req = authorized("/health", method: "GET", requireToken: false) else {
            throw JesseError.notConfigured
        }
        let (data, resp) = try await perform(req)
        return try Self.decodeHealth(data: data, resp: resp)
    }

    // MARK: - Cancel / delete / notify

    /// Best-effort cancel of an in-flight turn (`POST /jesse/cancel/{job_id}`). The
    /// bridge is idempotent — unknown/finished/already-cancelled all return 204 — so a
    /// 404 is treated as success too.
    public func cancelJob(jobId: String) async throws {
        try await idempotentCall("/jesse/cancel/\(jobId)", method: "POST")
    }

    /// Delete a thread's remote conversation, every transcript bound to it
    /// (`DELETE /jesse/conversation/{id}`). Idempotent-404 like `cancelJob`: a conversation
    /// the bridge no longer knows is a success.
    public func deleteConversation(_ conversationId: String) async throws {
        try await idempotentCall("/jesse/conversation/\(conversationId)", method: "DELETE")
    }

    // MARK: - Flags

    /// Push a favorite/archive change up (`POST /jesse/conversation/{id}/flags`), sending
    /// ONLY the flag(s) that changed with their unix-millis clocks so the bridge applies each
    /// last-writer-wins. Best-effort: a 2xx (the bridge echoes the resulting flags) and a
    /// 404 (a conversation the bridge does not know, or a bridge with no such route) both
    /// count as success, so degrading against an older bridge is a clean no-op. Only a
    /// genuine transport/auth/5xx failure throws, and the caller (`FlagReconciler`) swallows
    /// even that, because the local clock stays newer and the next reconcile re-pushes.
    public func setFlags(conversationId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
        guard var req = authorized("/jesse/conversation/\(conversationId)/flags", method: "POST") else {
            throw JesseError.notConfigured
        }
        let body = JesseFlagsRequest(
            favorite: favorite?.value,
            favoriteUpdatedMs: favorite.map { UInt64(max(0, $0.updatedMs)) },
            archived: archived?.value,
            archivedUpdatedMs: archived.map { UInt64(max(0, $0.updatedMs)) })
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(body)
        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Global model switch

    /// `GET /jesse/models` — the selectable models + the active selection. The bridge is the
    /// source of truth, so the app fetches this on open and after any change rather than
    /// caching an authoritative copy. Throws on a transport/auth/HTTP failure so the caller
    /// can surface it; a bridge too old to expose the route returns 404 → `badResponse`.
    public func fetchModels() async throws -> ModelSwitchState {
        guard let req = authorized("/jesse/models", method: "GET") else {
            throw JesseError.notConfigured
        }
        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let state = try? JSONDecoder().decode(ModelSwitchState.self, from: data) else {
            throw JesseError.decoding
        }
        return state
    }

    /// `POST /jesse/model` — make `id` the active model. The bridge rejects an unknown (400)
    /// or unavailable (409) id; both surface as `badResponse` so the caller can show a clear
    /// message and re-fetch the authoritative state.
    public func setActiveModel(_ id: String) async throws {
        guard var req = authorized("/jesse/model", method: "POST") else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(SetModelBody(id: id))
        try await Self.expect2xx(session: session, req: req, host: config.normalizedHost)
    }

    /// Fire a request and require a 2xx, mapping transport/HTTP failures to `JesseError`.
    /// Shared by the model-switch mutator (unlike the idempotent 404-is-ok calls, an
    /// unknown/unavailable model is a real 4xx the caller must see).
    static func expect2xx(session: URLSession, req: URLRequest, host: String) async throws {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: host)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Register (idempotent upsert) a device's APNs token with the bridge
    /// (`POST /jesse/device`) so it can push when a backgrounded turn finishes. Strict:
    /// throws on a transport/auth/HTTP failure so the caller can retry (this is the one
    /// iOS push concern that rides the shared client; the bridge call itself needs no
    /// iOS-only data).
    public func registerDevice(token: String) async throws {
        guard var req = authorized("/jesse/device", method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(JesseDeviceRegistration(token: token))
        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Ask the bridge to push when `jobId` completes (`POST /jesse/notify/{job_id}`).
    /// Fired as the app backgrounds with that turn in flight. Idempotent-404 like
    /// `cancelJob`: a bridge that no longer knows the id is a success.
    public func notifyOnComplete(jobId: String) async throws {
        try await idempotentCall("/jesse/notify/\(jobId)", method: "POST")
    }

    /// Shared shape for the idempotent best-effort calls (cancel, delete, notify): a
    /// bearer-authed request where 2xx (the bridge replies 204) or 404 (nothing left to
    /// act on) both mean success, and only a genuine transport/auth/5xx failure throws.
    func idempotentCall(_ path: String, method: String) async throws {
        guard let req = authorized(path, method: method) else { throw JesseError.notConfigured }
        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Sessions list

    /// `GET /jesse/conversations`. `since` narrows to conversations touched after that unix
    /// second; `etag` is the caller's last ETag (a 304 becomes `.notModified`).
    public func listConversations(since: UInt64? = nil, etag: String? = nil) async throws
        -> ConversationsResult {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/conversations") else { throw JesseError.notConfigured }
        let url: URL
        if let since {
            guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw JesseError.notConfigured
            }
            comps.queryItems = [URLQueryItem(name: "since", value: String(since))]
            guard let u = comps.url else { throw JesseError.notConfigured }
            url = u
        } else {
            url = base
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let newETag = http.value(forHTTPHeaderField: "Etag")
        guard let body = try? JSONDecoder().decode(JesseConversationsBody.self, from: data) else {
            throw JesseError.decoding
        }
        return .conversations(body.conversations, deleted: body.deleted, etag: newETag)
    }

    // MARK: - Hydrate

    /// `GET /jesse/conversations/{id}/transcript`. `after` is the bridge's OPAQUE cursor
    /// (nil/empty for the whole history); returns the ordered turns appended since and the
    /// `nextCursor` to echo back next time. A 404 (a conversation the bridge does not know)
    /// surfaces as `JesseError.badResponse(404, …)`, which callers treat as "leave the
    /// cached copy alone".
    public func hydrate(conversationId: String, after cursor: String? = nil) async throws
        -> (turns: [HydratedTurn], nextCursor: String) {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/conversations/\(conversationId)/transcript") else {
            throw JesseError.notConfigured
        }
        let url: URL
        if let cursor, !cursor.isEmpty {
            guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw JesseError.notConfigured
            }
            comps.queryItems = [URLQueryItem(name: "after", value: cursor)]
            guard let u = comps.url else { throw JesseError.notConfigured }
            url = u
        } else {
            url = base
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await perform(req)
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let body = try? JSONDecoder().decode(JesseConversationHydrateBody.self, from: data) else {
            throw JesseError.decoding
        }
        return (body.turns, body.nextCursor)
    }

    // MARK: - Title

    /// Mint a short conversation title (`POST /jesse/title`). Passing `conversationId`
    /// persists it in the server's authoritative (conversation-keyed) title store.
    /// Deliberately *total*: EVERY failure mode collapses to `nil`, so a caller on the list
    /// path can fire it without a `try` and the row simply keeps its derived title.
    public func title(text: String, conversationId: String? = nil) async -> String? {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/title"),
              let body = try? Self.encodeBody(
                JesseTitleRequest(digest: text, conversationId: conversationId)) else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        // A title that cannot be minted is not an error the user is ever shown, so this
        // still swallows everything — but the round trip is real, so it is reported like
        // any other (and a CANCELLED one is not, which is why this is a `catch` and no
        // longer a `try?`).
        var attempt: (Data, URLResponse)?
        do {
            attempt = try await session.data(for: req)
            noteReachability(true)
        } catch {
            noteReachability(reachedBridge: false, error: error)
        }
        guard let (data, resp) = attempt,
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONDecoder().decode(JesseTitleResponse.self, from: data),
              let title = obj.title else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Stream

    /// Open the live SSE stream for a running turn and decode each frame. Reads
    /// `text/event-stream` with `URLSession.bytes(for:)`, feeding the pure `SSEParser`.
    /// The inner URL task is cancelled when the returned stream is torn down. Any
    /// transport/HTTP failure finishes the stream with a throw, signalling the
    /// coordinator to fall back to polling.
    public func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard var req = authorized("/jesse/stream/\(jobId)", method: "GET") else {
                        throw JesseError.notConfigured
                    }
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let bytes: URLSession.AsyncBytes, resp: URLResponse
                    do {
                        (bytes, resp) = try await streamSession.bytes(for: req)
                    } catch {
                        throw JesseError.from(error, host: config.normalizedHost)
                    }
                    guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
                    guard (200..<300).contains(http.statusCode) else {
                        // Includes 404 (unknown/expired) — the coordinator's poll
                        // fallback resolves what actually happened to the job.
                        throw JesseError.badResponse(http.statusCode, "")
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let ev = parser.consume(line) { continuation.yield(ev) }
                    }
                    if let ev = parser.finish() { continuation.yield(ev) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompts

    /// Fetch the bridge's built-in Ask/Tell wrapper defaults (`GET /jesse/prompts`).
    public func fetchPrompts() async throws -> PromptDefaults {
        guard let req = authorized("/jesse/prompts", method: "GET") else { throw JesseError.notConfigured }
        let (data, resp) = try await perform(req)
        return try Self.decodePrompts(data: data, resp: resp)
    }

    // MARK: - Diet

    /// Fetch the diet snapshot (`GET /jesse/diet`). Maps failures onto the richer
    /// `DietFetchError` the Health tab needs.
    public func fetchDietSnapshot(date: String? = nil) async throws -> DietSnapshot {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/diet") else { throw DietFetchError.notConfigured }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DietFetchError.notConfigured
        }
        // `client_tz` rides on every read as well as every write: a diet day starts at 04:00
        // in the zone the eater is standing in, so which day this answers for depends on it.
        var items = [URLQueryItem(name: "client_tz", value: Self.clientTimeZone)]
        if let date { items.insert(URLQueryItem(name: "date", value: date), at: 0) }
        comps.queryItems = items
        guard let url = comps.url else { throw DietFetchError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
            noteReachability(true)
        } catch {
            // Its own error taxonomy (the Health tab renders each case differently), but
            // the same reachability report — this is a real round trip like any other.
            noteReachability(reachedBridge: false, error: error)
            let je = JesseError.from(error, host: config.normalizedHost)
            throw DietFetchError.unreachable(je.errorDescription ?? "Couldn't reach the bridge.")
        }
        let snapshot = try Self.decodeDiet(data: data, resp: resp)
        // Only a decoded 2xx reaches here, so the cache never holds a body the display
        // could not render. The key is the REQUESTED date (nil = the live day), not the
        // snapshot's own, so a bridge that ignores the query parameter cannot overwrite
        // the live day's entry with a copy of itself.
        if let cache = snapshotCache, let key = SnapshotCacheKey.diet(date: date) {
            cache.store(data, key: key, fetchedAt: Date())
        }
        return snapshot
    }

    // MARK: - Pure encode/decode (unit-testable without a server)

    /// Build the `POST /jesse` request. "Use the bridge default" collapses to a nil
    /// field that drops out of the encoded body: `voice == false`, a blank
    /// `instructions`/`floorOverride`, and an empty `attachments` all become nil.
    public static func makeRequest(mode: JesseMode, text: String, sessionId: String?,
                                   conversationId: String?,
                                   voice: Bool, instructions: String?,
                                   floorOverride: String?,
                                   attachments: [JesseRequest.Attachment],
                                   healthContext: String? = nil,
                                   healthContextRequested: Bool? = nil,
                                   healthContextUnavailable: Bool? = nil,
                                   locationContext: String? = nil,
                                   locationContextRequested: Bool? = nil,
                                   locationContextUnavailable: Bool? = nil,
                                   locationContextUnavailableReason: String? = nil,
                                   mealCorrectionsAck: Int? = nil,
                                   requestId: String? = nil,
                                   model: String? = nil) -> JesseRequest {
        func nonBlank(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return JesseRequest(
            mode: mode.rawValue,
            text: text,
            sessionId: sessionId,
            // The thread identity. Blank collapses to nil, which makes the bridge mint one:
            // that is the older-client shape, never what a current caller should produce.
            conversationId: nonBlank(conversationId),
            voice: voice ? true : nil,
            instructions: nonBlank(instructions),
            floorOverride: nonBlank(floorOverride),
            attachments: attachments.isEmpty ? nil : attachments,
            // Blank collapses to nil so the field drops out (the bridge treats
            // absent/blank identically — today's behavior).
            healthContext: nonBlank(healthContext),
            // Only ever `true` or omitted — a `false` flag is meaningless to the bridge.
            healthContextRequested: healthContextRequested == true ? true : nil,
            healthContextUnavailable: healthContextUnavailable == true ? true : nil,
            // The location channel, normalized exactly as the health one is: a blank
            // block drops the field, and a `false` flag is meaningless to the bridge
            // so it drops too. An app that never sets any of the three produces the
            // pre-location bytes.
            locationContext: nonBlank(locationContext),
            locationContextRequested: locationContextRequested == true ? true : nil,
            locationContextUnavailable: locationContextUnavailable == true ? true : nil,
            // The reason rides ONLY with the flag it explains. A reason on a turn that
            // is not marked unavailable would be a contradiction on the wire, and a
            // blank one is the same as none.
            locationContextUnavailableReason: locationContextUnavailable == true
                ? nonBlank(locationContextUnavailableReason) : nil,
            // Only a positive seq is meaningful (0/absent → nothing acked yet).
            mealCorrectionsAck: (mealCorrectionsAck ?? 0) > 0 ? mealCorrectionsAck : nil,
            // The outbox idempotency key; nil drops the field.
            requestId: requestId,
            // The per-turn model selection; blank collapses to nil so the field drops out
            // (the bridge then uses its stored default, today's behavior).
            model: nonBlank(model))
    }

    /// Encode a wire body. Optional fields omit when nil. `sortedKeys` makes the byte
    /// order deterministic and `withoutEscapingSlashes` keeps `image/png` and base64
    /// readable; the bridge's serde accepts any key order.
    public static func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decodeSend(data: Data, resp: URLResponse) throws -> JesseSendResult {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // 202 = still running; hand back the job id to poll. Checked before the 2xx
        // success branch since 202 is itself a success code.
        if http.statusCode == 202 {
            guard let obj = try? JSONDecoder().decode(JesseSendResponse.self, from: data),
                  let jobId = obj.jobId else { throw JesseError.decoding }
            return .running(jobId: jobId, conversationId: obj.conversationId)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONDecoder().decode(JesseSendResponse.self, from: data),
              let reply = obj.response else { throw JesseError.decoding }
        return .reply(JesseReply(text: reply, sessionId: obj.sessionId), jobId: obj.jobId,
                      conversationId: obj.conversationId)
    }

    public static func decodeResult(data: Data, resp: URLResponse) throws -> JesseResultState {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // An unknown/evicted id is the one genuinely terminal "gone" state.
        if http.statusCode == 404 {
            return .expired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONDecoder().decode(JesseResultResponse.self, from: data) else {
            throw JesseError.decoding
        }
        switch obj.status {
        case "running", "queued":
            return .running
        case "done":
            guard let text = obj.response else { throw JesseError.decoding }
            return .done(JesseReply(text: text, sessionId: obj.sessionId,
                                    directives: obj.directives, provenance: obj.provenance,
                                    artifacts: obj.artifacts ?? []))
        case "failed":
            return .failed(obj.error ?? "Jesse couldn't complete that.")
        case "cancelled":
            // A clean terminal status, not a failure — mirrors the stream's `cancelled`.
            return .cancelled
        default:
            throw JesseError.decoding
        }
    }

    public static func decodeHealth(data: Data, resp: URLResponse) throws -> BridgeHealth {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONDecoder().decode(JesseHealthResponse.self, from: data) else {
            throw JesseError.decoding
        }
        // Normalize a blank version to nil so "unknown" is shown, not an empty row.
        let v = obj.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeHealth(version: (v?.isEmpty ?? true) ? nil : v)
    }

    public static func decodePrompts(data: Data, resp: URLResponse) throws -> PromptDefaults {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        // All four keys are required: a bridge too old to expose the fixed floors can't
        // enforce them, so fail rather than silently show none.
        guard let obj = try? JSONDecoder().decode(JessePromptsResponse.self, from: data) else {
            throw JesseError.decoding
        }
        return PromptDefaults(ask: obj.ask, tell: obj.tell,
                              askFloor: obj.askFloor, tellFloor: obj.tellFloor)
    }

    /// Map a `GET /jesse/diet` response to a snapshot or the matching `DietFetchError`.
    public static func decodeDiet(data: Data, resp: URLResponse) throws -> DietSnapshot {
        guard let http = resp as? HTTPURLResponse else { throw DietFetchError.decodeFailed }
        switch http.statusCode {
        case 401:
            throw DietFetchError.authFailed
        case 404:
            throw DietFetchError.endpointMissing
        case 503:
            throw DietFetchError.unavailable
        case 200..<300:
            do { return try DietSnapshot.decode(from: data) }
            catch { throw DietFetchError.decodeFailed }
        default:
            throw DietFetchError.server(http.statusCode)
        }
    }
}
