import Foundation

// The macOS bridge client. Standalone (the iOS `JesseClient` is entangled with the
// HealthKit context path, which macOS has no equivalent of) and health-free: a Mac
// turn omits `health_context` entirely, which the bridge already treats as an
// ordinary turn. Covers exactly the endpoints the Mac MVP needs:
//
//   POST   /jesse                     send a turn (202 job, or inline 200)
//   GET    /jesse/stream/{job_id}     live SSE token stream for a running turn
//   GET    /jesse/result/{job_id}     poll a job (reconnect / SSE fallback)
//   GET    /jesse/sessions            list sessions, newest first (?since=, ETag)
//   GET    /jesse/sessions/{id}       hydrate a transcript (?after= byte-delta)
//   POST   /jesse/title               mint + server-persist a session title
//
// All wire structs are `nonisolated Sendable` so decoding runs off the main actor.

// MARK: - Errors

enum MacJesseError: Error, Sendable, Equatable {
    case notConfigured
    case transport(String)
    case badStatus(Int, String)
    case decoding
    case unknownSession   // 404 from hydrate — the session id is gone or was never real
}

// MARK: - Wire types

/// One session in `GET /jesse/sessions`. Matches the bridge `SessionSummary`.
nonisolated struct MacSessionSummary: Decodable, Sendable, Equatable {
    let sessionId: String
    let lastModified: UInt64
    let firstMessage: String?
    let title: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case lastModified = "last_modified"
        case firstMessage = "first_message"
        case title
    }
}

/// One hydrated transcript turn. Matches the bridge `HydratedTurn`. `role` is
/// "user" | "assistant".
nonisolated struct MacHydratedTurn: Decodable, Sendable, Equatable {
    let role: String
    let text: String
    let timestamp: String?
}

/// Result of listing sessions: either fresh data (with the ETag to send back next
/// time) or a 304 telling the caller its cache is current.
nonisolated enum MacSessionsResult: Sendable, Equatable {
    case notModified
    case sessions([MacSessionSummary], etag: String?)
}

/// Result of a `POST /jesse`. The bridge either finishes inline within its grace
/// window (200, `response`) or hands back a job id to stream/poll (202, `job_id`).
nonisolated enum MacSendResult: Sendable, Equatable {
    case reply(text: String, sessionId: String?)
    case running(jobId: String)
}

/// Terminal/poll state of a job from `GET /jesse/result/{id}`.
nonisolated enum MacJobState: Sendable, Equatable {
    case running
    case done(text: String, sessionId: String?)
    case failed(String)
    case cancelled
    case expired   // 404 — evicted past TTL, nothing left to poll
}

/// One decoded SSE frame from `GET /jesse/stream/{job_id}`. Mirrors the iOS
/// `JesseStreamEvent`: `reset` REPLACES the buffer (sent on subscribe / after lag),
/// `delta` APPENDS, the terminal frames end the turn.
nonisolated enum MacStreamEvent: Sendable, Equatable {
    case reset(String)
    case delta(String)
    case activity(String)
    case done(text: String, sessionId: String?)
    case failed(String)
    case cancelled
}

private nonisolated struct MacSendResponse: Decodable {
    let jobId: String?
    let status: String?
    let response: String?
    let sessionId: String?
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, response
        case sessionId = "session_id"
    }
}

private nonisolated struct MacResultResponse: Decodable {
    let status: String
    let response: String?
    let sessionId: String?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case status, response
        case sessionId = "session_id"
        case error
    }
}

private nonisolated struct MacSessionsBody: Decodable {
    let sessions: [MacSessionSummary]
}

private nonisolated struct MacHydrateBody: Decodable {
    let sessionId: String
    let turns: [MacHydratedTurn]
    let nextOffset: UInt64
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case turns
        case nextOffset = "next_offset"
    }
}

private nonisolated struct MacTitleBody: Decodable { let title: String? }

/// One SSE frame's `data:` payload — every field optional; which one matters depends
/// on the frame's `event:` name.
private nonisolated struct MacStreamFrameData: Decodable {
    let text: String?
    let name: String?
    let response: String?
    let sessionId: String?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case text, name, response, error
        case sessionId = "session_id"
    }
}

// MARK: - Client

nonisolated struct MacJesseClient: Sendable {
    let config: MacBridgeConfig

    /// A URLSession with no resource timeout for the long-lived SSE stream (a turn can
    /// run for minutes); the default session governs the short JSON calls.
    private static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private func authed(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func jsonDecoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Send

    /// `POST /jesse`. Health-free body: mode + text (+ optional resume `session_id`
    /// and idempotency `request_id`). Returns the inline reply (200) or a job id (202).
    func send(mode: JesseMode, text: String, sessionId: String?,
              requestId: String? = nil) async throws -> MacSendResult {
        guard config.isConfigured, let url = config.endpoint("/jesse") else {
            throw MacJesseError.notConfigured
        }
        var body: [String: Any] = ["mode": mode.rawValue, "text": text]
        if let sessionId, !sessionId.isEmpty { body["session_id"] = sessionId }
        if let requestId, !requestId.isEmpty { body["request_id"] = requestId }

        var req = authed(url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await dataCall(req)
        guard let http = resp as? HTTPURLResponse else { throw MacJesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw MacJesseError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try decode(MacSendResponse.self, data)
        if let jobId = decoded.jobId, decoded.response == nil {
            return .running(jobId: jobId)
        }
        return .reply(text: decoded.response ?? "", sessionId: decoded.sessionId)
    }

    // MARK: Poll

    /// `GET /jesse/result/{job_id}`. A 404 is `.expired` (evicted past TTL), not an error.
    func result(jobId: String) async throws -> MacJobState {
        guard config.isConfigured, let url = config.endpoint("/jesse/result/\(jobId)") else {
            throw MacJesseError.notConfigured
        }
        let (data, resp) = try await dataCall(authed(url, method: "GET"))
        guard let http = resp as? HTTPURLResponse else { throw MacJesseError.decoding }
        if http.statusCode == 404 { return .expired }
        guard (200..<300).contains(http.statusCode) else {
            throw MacJesseError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let r = try decode(MacResultResponse.self, data)
        switch r.status {
        case "running", "queued": return .running
        case "done": return .done(text: r.response ?? "", sessionId: r.sessionId)
        case "cancelled": return .cancelled
        case "failed": return .failed(r.error ?? "Jesse couldn't complete that.")
        default: return .failed(r.error ?? "Unexpected status: \(r.status)")
        }
    }

    // MARK: Sessions list

    /// `GET /jesse/sessions`. `since` narrows to sessions modified after that unix
    /// second; `etag` is the caller's last ETag (a 304 → `.notModified`).
    func listSessions(since: UInt64? = nil, etag: String? = nil) async throws -> MacSessionsResult {
        guard config.isConfigured else { throw MacJesseError.notConfigured }
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = config.host; comps.port = config.port
        comps.path = "/jesse/sessions"
        if let since { comps.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        guard let url = comps.url else { throw MacJesseError.notConfigured }

        var req = authed(url, method: "GET")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await dataCall(req)
        guard let http = resp as? HTTPURLResponse else { throw MacJesseError.decoding }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw MacJesseError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let newETag = http.value(forHTTPHeaderField: "Etag")
        let body = try decode(MacSessionsBody.self, data)
        return .sessions(body.sessions, etag: newETag)
    }

    // MARK: Hydrate

    /// `GET /jesse/sessions/{id}`. `after` returns only the byte-delta appended since;
    /// returns the ordered turns and the `nextOffset` for the next round trip. A 404
    /// (unknown id / title-mint transcript) surfaces as `.unknownSession`.
    func hydrate(sessionId: String, after: UInt64 = 0) async throws
        -> (turns: [MacHydratedTurn], nextOffset: UInt64) {
        guard config.isConfigured else { throw MacJesseError.notConfigured }
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = config.host; comps.port = config.port
        comps.path = "/jesse/sessions/\(sessionId)"
        if after > 0 { comps.queryItems = [URLQueryItem(name: "after", value: String(after))] }
        guard let url = comps.url else { throw MacJesseError.notConfigured }

        let (data, resp) = try await dataCall(authed(url, method: "GET"))
        guard let http = resp as? HTTPURLResponse else { throw MacJesseError.decoding }
        if http.statusCode == 404 { throw MacJesseError.unknownSession }
        guard (200..<300).contains(http.statusCode) else {
            throw MacJesseError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let body = try decode(MacHydrateBody.self, data)
        return (body.turns, body.nextOffset)
    }

    // MARK: Title

    /// `POST /jesse/title`. Mints a short title for `text`; passing `sessionId`
    /// persists it in the server's authoritative title store (so every client agrees).
    /// Returns nil for ANY failure — titling is best-effort.
    func title(for text: String, sessionId: String?) async -> String? {
        guard config.isConfigured, let url = config.endpoint("/jesse/title") else { return nil }
        var body: [String: Any] = ["text": text]
        if let sessionId, !sessionId.isEmpty { body["session_id"] = sessionId }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = authed(url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, resp) = try? await dataCall(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? Self.jsonDecoder().decode(MacTitleBody.self, from: data),
              let title = decoded.title, !title.isEmpty
        else { return nil }
        return title
    }

    // MARK: Stream

    /// `GET /jesse/stream/{job_id}` as a `text/event-stream`. Yields each decoded frame
    /// live; a transport/HTTP failure finishes the stream with a throw so the caller can
    /// fall back to polling. The inner task is cancelled when the stream is torn down.
    func stream(jobId: String) -> AsyncThrowingStream<MacStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard config.isConfigured, let url = config.endpoint("/jesse/stream/\(jobId)") else {
                        throw MacJesseError.notConfigured
                    }
                    var req = authed(url, method: "GET")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await Self.streamSession.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw MacJesseError.decoding }
                    guard (200..<300).contains(http.statusCode) else {
                        throw MacJesseError.badStatus(http.statusCode, "")
                    }
                    var parser = MacSSEParser()
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

    // MARK: Helpers

    private func dataCall(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: req) }
        catch { throw MacJesseError.transport(error.localizedDescription) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.jsonDecoder().decode(type, from: data) }
        catch { throw MacJesseError.decoding }
    }
}

// MARK: - SSE framing

/// Stateful SSE line→frame state machine, ported from the iOS `JesseClient.SSEParser`.
/// A blank line is a frame boundary, but `URLSession.AsyncBytes.lines` SWALLOWS blank
/// lines, so a new `event:` line also flushes the previous frame — the boundary that
/// survives. `:` lines are keep-alive comments. Pure, so it's unit-testable directly.
nonisolated struct MacSSEParser {
    private var eventName = ""
    private var dataBuf = ""

    mutating func consume(_ line: String) -> MacStreamEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        if let v = Self.field("event:", line) {
            let completed = eventName.isEmpty ? nil : flush()
            eventName = v
            return completed
        } else if let v = Self.field("data:", line) {
            dataBuf += v
        }
        return nil
    }

    mutating func finish() -> MacStreamEvent? { flush() }

    private mutating func flush() -> MacStreamEvent? {
        defer { eventName = ""; dataBuf = "" }
        guard !eventName.isEmpty else { return nil }
        return Self.decodeFrame(event: eventName, data: dataBuf)
    }

    /// Strip an SSE field prefix and its single optional leading space.
    static func field(_ prefix: String, _ line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
    }

    static func decodeFrame(event: String, data: String) -> MacStreamEvent? {
        let obj = try? JSONDecoder().decode(MacStreamFrameData.self, from: Data(data.utf8))
        switch event {
        case "reset": return .reset(obj?.text ?? "")
        case "delta": return .delta(obj?.text ?? "")
        case "activity": return .activity(obj?.name ?? "")
        case "done": return .done(text: obj?.response ?? "", sessionId: obj?.sessionId)
        case "error": return .failed(obj?.error ?? "Jesse couldn't complete that.")
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Pure whole-sequence conversion, for unit-testing the framing over line arrays.
    static func frames<S: Sequence<String>>(_ lines: S) -> [MacStreamEvent] {
        var parser = MacSSEParser()
        var out: [MacStreamEvent] = []
        for line in lines { if let ev = parser.consume(line) { out.append(ev) } }
        if let ev = parser.finish() { out.append(ev) }
        return out
    }
}
