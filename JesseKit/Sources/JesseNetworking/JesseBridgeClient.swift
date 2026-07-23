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
    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseRequest.Attachment], requestId: String?) async throws -> JesseSendResult
    func result(jobId: String) async throws -> JesseResultState
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error>
    func listSessions(since: UInt64?, etag: String?) async throws -> SessionsResult
    func hydrate(sessionId: String, after: UInt64) async throws -> (turns: [HydratedTurn], nextOffset: UInt64)
    func title(text: String, sessionId: String?) async -> String?
    func cancelJob(jobId: String) async throws
    func deleteSession(_ sessionId: String) async throws
    func health() async throws -> BridgeHealth
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot
    func fetchPrompts() async throws -> PromptDefaults
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

    public init(config: JesseConfig,
                session: URLSession = JesseBridgeClient.boundedSession,
                streamSession: URLSession? = nil) {
        self.config = config
        self.session = session
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
    }

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

    // MARK: - Send

    /// Send a health-free turn. The bridge treats an omitted `health_context` as an
    /// ordinary turn, so this is exactly what the Mac uses; the iOS layer builds a
    /// health-laden `JesseRequest` and calls `sendPrepared`.
    public func send(mode: JesseMode, text: String, sessionId: String? = nil,
                     voice: Bool = false, instructions: String? = nil,
                     floorOverride: String? = nil,
                     attachments: [JesseRequest.Attachment] = [],
                     requestId: String? = nil) async throws -> JesseSendResult {
        let request = Self.makeRequest(mode: mode, text: text, sessionId: sessionId,
                                       voice: voice, instructions: instructions,
                                       floorOverride: floorOverride, attachments: attachments,
                                       requestId: requestId)
        return try await sendPrepared(request)
    }

    /// Encode + POST a fully-built `/jesse` request body and decode the send result. The
    /// seam the iOS layer uses to send a turn carrying the `health_context` block.
    public func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult {
        guard var req = authorized("/jesse", method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(request)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodeSend(data: data, resp: resp)
    }

    // MARK: - Poll

    /// Poll a job started by `send`. Used after a dropped socket (or while the turn
    /// outran the grace window) to fetch the completed reply by id.
    public func result(jobId: String) async throws -> JesseResultState {
        guard let req = authorized("/jesse/result/\(jobId)", method: "GET") else {
            throw JesseError.notConfigured
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodeResult(data: data, resp: resp)
    }

    // MARK: - Health

    /// Probe `GET /health` and parse the bridge's reported version. The version is
    /// returned unconditionally, but we still send the bearer (when set) so this reuses
    /// the same auth shape as every other call.
    public func health() async throws -> BridgeHealth {
        guard let req = authorized("/health", method: "GET", requireToken: false) else {
            throw JesseError.notConfigured
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodeHealth(data: data, resp: resp)
    }

    // MARK: - Cancel / delete / notify

    /// Best-effort cancel of an in-flight turn (`POST /jesse/cancel/{job_id}`). The
    /// bridge is idempotent — unknown/finished/already-cancelled all return 204 — so a
    /// 404 is treated as success too.
    public func cancelJob(jobId: String) async throws {
        try await idempotentCall("/jesse/cancel/\(jobId)", method: "POST")
    }

    /// Delete a thread's remote Claude Code session (`DELETE /jesse/session/{id}`).
    /// Idempotent-404 like `cancelJob`: a missing session is a success.
    public func deleteSession(_ sessionId: String) async throws {
        try await idempotentCall("/jesse/session/\(sessionId)", method: "DELETE")
    }

    // MARK: - Flags

    /// Push a favorite/archive change up (`POST /jesse/session/{id}/flags`), sending ONLY
    /// the flag(s) that changed with their unix-millis clocks so the bridge applies each
    /// last-writer-wins. Best-effort: a 2xx (the bridge echoes the resulting flags) and a
    /// 404 (an unknown id, or a pre-0.25.0 bridge with no such route) both count as
    /// success, so degrading against an older bridge is a clean no-op. Only a genuine
    /// transport/auth/5xx failure throws, and the caller (`FlagReconciler`) swallows even
    /// that, because the local clock stays newer and the next reconcile re-pushes.
    public func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
        guard var req = authorized("/jesse/session/\(sessionId)/flags", method: "POST") else {
            throw JesseError.notConfigured
        }
        let body = JesseFlagsRequest(
            favorite: favorite?.value,
            favoriteUpdatedMs: favorite.map { UInt64(max(0, $0.updatedMs)) },
            archived: archived?.value,
            archivedUpdatedMs: archived.map { UInt64(max(0, $0.updatedMs)) })
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(body)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
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
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
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

    /// `POST /jesse/model/{id}/writes` — set a model's write permission (Phase 2 wires the
    /// effect). The bridge rejects the ambient default (400) and unknown/unavailable ids;
    /// those surface as `badResponse`.
    public func setWrites(id: String, enabled: Bool) async throws {
        guard var req = authorized("/jesse/model/\(id)/writes", method: "POST") else {
            throw JesseError.notConfigured
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encodeBody(SetWritesBody(enabled: enabled))
        try await Self.expect2xx(session: session, req: req, host: config.normalizedHost)
    }

    /// Fire a request and require a 2xx, mapping transport/HTTP failures to `JesseError`.
    /// Shared by the two model-switch mutators (unlike the idempotent 404-is-ok calls, an
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
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
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
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Sessions list

    /// `GET /jesse/sessions`. `since` narrows to sessions modified after that unix
    /// second; `etag` is the caller's last ETag (a 304 → `.notModified`).
    public func listSessions(since: UInt64? = nil, etag: String? = nil) async throws -> SessionsResult {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/sessions") else { throw JesseError.notConfigured }
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

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let newETag = http.value(forHTTPHeaderField: "Etag")
        guard let body = try? JSONDecoder().decode(JesseSessionsBody.self, from: data) else {
            throw JesseError.decoding
        }
        return .sessions(body.sessions, deleted: body.deleted, etag: newETag)
    }

    // MARK: - Hydrate

    /// `GET /jesse/sessions/{id}`. `after` returns only the byte-delta appended since;
    /// returns the ordered turns and the `nextOffset` for the next round trip. A 404
    /// (unknown id / title-mint transcript) surfaces as `JesseError.badResponse(404, …)`.
    public func hydrate(sessionId: String, after: UInt64 = 0) async throws
        -> (turns: [HydratedTurn], nextOffset: UInt64) {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/sessions/\(sessionId)") else {
            throw JesseError.notConfigured
        }
        let url: URL
        if after > 0 {
            guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw JesseError.notConfigured
            }
            comps.queryItems = [URLQueryItem(name: "after", value: String(after))]
            guard let u = comps.url else { throw JesseError.notConfigured }
            url = u
        } else {
            url = base
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let body = try? JSONDecoder().decode(JesseHydrateBody.self, from: data) else {
            throw JesseError.decoding
        }
        return (body.turns, body.nextOffset)
    }

    // MARK: - Title

    /// Mint a short conversation title (`POST /jesse/title`). Passing `sessionId`
    /// persists it in the server's authoritative title store. Deliberately *total*:
    /// EVERY failure mode collapses to `nil`, so a caller on the list path can fire it
    /// without a `try` and the row simply keeps its derived title.
    public func title(text: String, sessionId: String? = nil) async -> String? {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/title"),
              let body = try? Self.encodeBody(JesseTitleRequest(digest: text, sessionId: sessionId)) else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        guard let (data, resp) = try? await session.data(for: req),
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
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodePrompts(data: data, resp: resp)
    }

    // MARK: - Diet

    /// Fetch the diet snapshot (`GET /jesse/diet`). Maps failures onto the richer
    /// `DietFetchError` the Health tab needs.
    public func fetchDietSnapshot(date: String? = nil) async throws -> DietSnapshot {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let base = config.endpoint("/jesse/diet") else { throw DietFetchError.notConfigured }
        let url: URL
        if let date {
            guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw DietFetchError.notConfigured
            }
            comps.queryItems = [URLQueryItem(name: "date", value: date)]
            guard let dated = comps.url else { throw DietFetchError.notConfigured }
            url = dated
        } else {
            url = base
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            let je = JesseError.from(error, host: config.normalizedHost)
            throw DietFetchError.unreachable(je.errorDescription ?? "Couldn't reach the bridge.")
        }
        return try Self.decodeDiet(data: data, resp: resp)
    }

    // MARK: - Pure encode/decode (unit-testable without a server)

    /// Build the `POST /jesse` request. "Use the bridge default" collapses to a nil
    /// field that drops out of the encoded body: `voice == false`, a blank
    /// `instructions`/`floorOverride`, and an empty `attachments` all become nil.
    public static func makeRequest(mode: JesseMode, text: String, sessionId: String?,
                                   voice: Bool, instructions: String?,
                                   floorOverride: String?,
                                   attachments: [JesseRequest.Attachment],
                                   healthContext: String? = nil,
                                   healthContextRequested: Bool? = nil,
                                   healthContextUnavailable: Bool? = nil,
                                   mealCorrectionsAck: Int? = nil,
                                   requestId: String? = nil) -> JesseRequest {
        func nonBlank(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return JesseRequest(
            mode: mode.rawValue,
            text: text,
            sessionId: sessionId,
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
            // Only a positive seq is meaningful (0/absent → nothing acked yet).
            mealCorrectionsAck: (mealCorrectionsAck ?? 0) > 0 ? mealCorrectionsAck : nil,
            // The outbox idempotency key; nil drops the field.
            requestId: requestId)
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
            return .running(jobId: jobId)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONDecoder().decode(JesseSendResponse.self, from: data),
              let reply = obj.response else { throw JesseError.decoding }
        return .reply(JesseReply(text: reply, sessionId: obj.sessionId), jobId: obj.jobId)
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
                                    directives: obj.directives, provenance: obj.provenance))
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
