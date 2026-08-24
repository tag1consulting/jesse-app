import Foundation

// The client for the SENTINEL — the second process, on its own host, port and bearer token,
// whose job is to be reachable when the bridge is not. It mirrors `JesseBridgeClient` in
// every structural respect (a bounded session, a bearer builder, `JesseError` mapping) and
// deliberately shares none of its state: a client that fell back to the bridge's config when
// the sentinel's was missing would silently send the sentinel's verbs at the thing they exist
// to restart.
//
// EVERY METHOD RETURNS RAW `Data`. The documents these endpoints answer with are the Ops
// screen's own vocabulary — a status page, a schedule, a deploy card — and they are decoded
// in `JesseOps`, one layer up, where the views that read them live. Keeping the decode out of
// here is what lets the schedule's two control verbs be satisfied by BOTH clients through one
// protocol (`ScheduleControlling`) without this layer knowing what a schedule row is.

/// The two schedule verbs, as a seam over "which process am I asking".
///
/// `JesseBridgeClient` and `SentinelClient` both conform. When a sentinel is paired the app
/// routes through it — the proxy is the path that still works when the bridge's own HTTP
/// surface is wedged but its process is alive — and otherwise it talks to the bridge
/// directly. Two conformances, one call site, and a test that pins which one is picked.
public protocol ScheduleControlling: Sendable {
    /// `POST …/{id}/fire`. `202` on acceptance; a `409` (the chain is already running) is a
    /// `JesseError.badResponse` carrying the bridge's reason.
    func fireJob(id: String, force: Bool) async throws -> Data
    /// `POST …/{id}/enable`. `until` is an RFC 3339 instant, or nil for "until it is changed".
    func enableJob(id: String, enabled: Bool, until: Date?) async throws -> Data
}

/// A `Sendable` value of `Sendable` parts, like `JesseBridgeClient`, so an Ops screen's
/// refresh and a verb can run in concurrent child tasks off one client.
public struct SentinelClient: Sendable {
    public var config: SentinelConfig

    /// The session the calls go through. Defaults to the sentinel's own bounded session;
    /// injectable so a test can supply a `URLProtocol`-backed stub.
    public let session: URLSession

    public init(config: SentinelConfig, session: URLSession = SentinelClient.boundedSession) {
        self.config = config
        self.session = session
    }

    /// A LONGER ceiling than the bridge client's 30 s, and the difference is deliberate.
    /// `GET /sentinel/status` runs eight probes, each with its own five-second timeout; a
    /// restart verb waits out a health poll on the process it just kicked. Those are the calls
    /// this session exists for, and a 30 s cap would time out exactly the ones that matter
    /// most — the ones made while something is wrong.
    public static let boundedSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: - Request plumbing

    private func authorized(_ path: String, method: String) -> URLRequest? {
        guard config.isConfigured, let url = config.endpoint(path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Send and map. A non-2xx is a `badResponse` carrying the REASON the sentinel gave
    /// (`{"error": …}`), not the raw JSON: every refusal here is one an operator has to read
    /// and act on — "another verb is already running", "no index.lock present", "a deploy is
    /// in flight" — and burying it in braces makes the screen useless at the moment it is
    /// needed.
    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode, SentinelClient.reason(in: data))
        }
        return data
    }

    private func get(_ path: String) async throws -> Data {
        guard let req = authorized(path, method: "GET") else { throw JesseError.notConfigured }
        return try await send(req)
    }

    /// Every verb POSTs, and every verb sends a JSON body — `{}` where the route takes none,
    /// because the sentinel's bodied routes use axum's `Json<T>` and an empty body is a 400
    /// there. One shape for all nine.
    private func post<Body: Encodable>(_ path: String, body: Body?) async throws -> Data {
        guard var req = authorized(path, method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try body.map { try JesseBridgeClient.encodeBody($0) } ?? Data("{}".utf8)
        return try await send(req)
    }

    /// The bodiless verbs, spelled once.
    private func post(_ path: String) async throws -> Data {
        try await post(path, body: Optional<FireBody>.none)
    }

    /// The human-readable half of an error body, whichever shape it arrived in: the
    /// sentinel answers `{"error": …}`, the bridge's own `ApiError` is bare text, and a
    /// proxied verb wraps the bridge's reply in `bridge_body`. Falls back to the whole body
    /// so nothing is ever swallowed.
    public static func reason(in data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return text
        }
        if let e = obj["error"] as? String { return e }
        if let e = obj["reason"] as? String { return e }
        if let inner = obj["bridge_body"] {
            if let s = inner as? String { return s }
            if let d = inner as? [String: Any], let e = (d["error"] ?? d["reason"]) as? String {
                return e
            }
        }
        return text
    }

    // MARK: - The read

    /// `GET /sentinel/status` — the whole document, probes and all.
    public func status() async throws -> Data { try await get("/sentinel/status") }

    // MARK: - The verbs

    /// The five restartable services, spelled the way the route does. An enum rather than a
    /// string because this is the one parameter that names a launchd job, and a free-text
    /// path segment is how a named-operation surface turns into a command surface.
    public enum Service: String, CaseIterable, Sendable {
        case bridge, autocommit
        case lockReaper = "lock-reaper"
        case qmdUpdate = "qmd-update"
        case miniserve

        /// What the confirmation dialog and the row call it.
        public var label: String {
            switch self {
            case .bridge: return "bridge"
            case .autocommit: return "autocommit"
            case .lockReaper: return "lock reaper"
            case .qmdUpdate: return "QMD index"
            case .miniserve: return "dashboard server"
            }
        }
    }

    /// `POST /sentinel/restart/{service}`. For `bridge` the reply also carries `healthy` and
    /// `version`, which is the answer to the question that was actually asked.
    public func restart(_ service: Service) async throws -> Data {
        try await post("/sentinel/restart/\(service.rawValue)")
    }

    /// `POST /sentinel/bridge/reload-env` — `bootout` + `bootstrap`, the ONLY way a plist
    /// environment change takes effect.
    public func reloadBridgeEnv() async throws -> Data {
        try await post("/sentinel/bridge/reload-env")
    }

    /// `POST /sentinel/git/unlock` — remove a stale `.git/index.lock`. A refusal is a `409`
    /// whose reason says which of the two conditions failed.
    public func gitUnlock() async throws -> Data { try await post("/sentinel/git/unlock") }

    /// `POST /sentinel/artifacts/prune` — delete artifact directories older than a week.
    public func pruneArtifacts() async throws -> Data {
        try await post("/sentinel/artifacts/prune")
    }

    /// `GET /sentinel/deploy/status` — the Deploy card.
    public func deployStatus() async throws -> Data { try await get("/sentinel/deploy/status") }

    /// `POST /sentinel/deploy` — build a commit, swap the binaries, restart, roll back on any
    /// failure. Answers `202 {deploy_id}`; the work itself takes twenty minutes.
    public func deploy(ref: String, force: Bool) async throws -> Data {
        try await post("/sentinel/deploy", body: DeployBody(ref: ref, force: force))
    }

    struct DeployBody: Encodable {
        var ref: String
        var force: Bool
    }
}

// MARK: - The two proxied schedule verbs

extension SentinelClient: ScheduleControlling {
    /// `POST /sentinel/jobs/{id}/fire` — proxied to the bridge, with the sentinel's own gates
    /// in front of it. The reply wraps the bridge's: `{bridge_status, bridge_body}`.
    public func fireJob(id: String, force: Bool) async throws -> Data {
        try await post("/sentinel/jobs/\(JesseBridgeClient.pathEscaped(id))/fire",
                       body: FireBody(force: force))
    }

    /// `POST /sentinel/jobs/{id}/enable` — proxied, same wrapping.
    public func enableJob(id: String, enabled: Bool, until: Date?) async throws -> Data {
        try await post("/sentinel/jobs/\(JesseBridgeClient.pathEscaped(id))/enable",
                       body: EnableBody(enabled: enabled, until: until.map(JesseBridgeClient.isoInstant)))
    }
}

/// `{"force": …}` — the fire body both processes take.
struct FireBody: Encodable {
    var force: Bool
}

/// `{"enabled": …, "until": …}` — the enable body both processes take. `until` omits when
/// nil, which the bridge reads as "until it is changed".
struct EnableBody: Encodable {
    var enabled: Bool
    var until: String?
}
