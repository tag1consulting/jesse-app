import Foundation

// The bridge's own operations surface: the schedule, its two control verbs, the reload, and
// the away profile. The sentinel proxies the first two (see `SentinelClient`); the profile
// and the schedule READ are the bridge's alone.
//
// Like the sentinel client, every method here answers with raw `Data` and the decoding lives
// a layer up in `JesseOps`. The reason is the same and it is not stylistic: the schedule
// document is answered by three different endpoints (`GET`, the enable verb, the reload) and
// reached through two different processes, so a decode that lived down here would have to be
// duplicated for the proxy's `bridge_body` wrapper anyway.

public extension JesseBridgeClient {

    // MARK: - Schedule

    /// `GET /jesse/schedule` — every configured job, what it is, and what happened the last
    /// time it came due.
    func scheduleDocument() async throws -> Data {
        try await opsGet("/jesse/schedule")
    }

    /// `POST /jesse/schedule/reload` — re-read the `[[schedule]]` array from the config file.
    /// Answers `{reloaded, errors, schedule}`; a file that does not validate leaves the
    /// running schedule exactly as it was and says why.
    func reloadSchedule() async throws -> Data {
        try await opsPost("/jesse/schedule/reload", body: Optional<String>.none)
    }

    // MARK: - Profile

    /// `GET /jesse/profile` — what profile is in force, in what zone, until when.
    func profileDocument() async throws -> Data {
        try await opsGet("/jesse/profile")
    }

    /// `POST /jesse/profile` — declare an away period, or come home.
    ///
    /// `away` REQUIRES a zone and a FUTURE `until`; the bridge refuses either missing with a
    /// `400` that says which, and this passes that message straight through rather than
    /// pre-judging it locally. Going home ignores all three.
    func setProfile(name: String, tz: String?, until: Date?, note: String?) async throws -> Data {
        try await opsPost("/jesse/profile",
                          body: ProfileBody(name: name,
                                            tz: tz,
                                            until: until.map(JesseBridgeClient.isoInstant),
                                            note: note))
    }

    // MARK: - Shared plumbing

    /// Bearer-authed GET returning the body, mapping a non-2xx onto `badResponse` with the
    /// bridge's own reason text.
    internal func opsGet(_ path: String) async throws -> Data {
        guard let req = opsRequest(path, method: "GET") else { throw JesseError.notConfigured }
        return try await opsSend(req)
    }

    internal func opsPost<Body: Encodable>(_ path: String, body: Body?) async throws -> Data {
        guard var req = opsRequest(path, method: "POST") else { throw JesseError.notConfigured }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An absent body still sends `{}` rather than nothing: axum's `Json<T>` extractor
        // rejects an empty body with a 400 on the routes that take one, and one shape for
        // all of them is fewer ways to be wrong than a per-route decision.
        req.httpBody = try body.map { try JesseBridgeClient.encodeBody($0) } ?? Data("{}".utf8)
        return try await opsSend(req)
    }

    private func opsRequest(_ path: String, method: String) -> URLRequest? {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint(path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func opsSend(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            // The bridge's `ApiError` is bare text; a proxied reply is JSON. `reason(in:)`
            // reads either, so a `409 the chain headed by "overnight" is already running`
            // reaches the button that pressed it, verbatim.
            throw JesseError.badResponse(http.statusCode, SentinelClient.reason(in: data))
        }
        return data
    }
}

// MARK: - The two control verbs

extension JesseBridgeClient: ScheduleControlling {
    /// `POST /jesse/schedule/{id}/fire` — run the chain from `{id}` now. `202` on acceptance;
    /// `409` while that chain is already running.
    public func fireJob(id: String, force: Bool) async throws -> Data {
        try await opsPost("/jesse/schedule/\(JesseBridgeClient.pathEscaped(id))/fire",
                          body: FireBody(force: force))
    }

    /// `POST /jesse/schedule/{id}/enable` — turn one job on or off at runtime, optionally
    /// until a deadline. Answers the job's row.
    public func enableJob(id: String, enabled: Bool, until: Date?) async throws -> Data {
        try await opsPost("/jesse/schedule/\(JesseBridgeClient.pathEscaped(id))/enable",
                          body: EnableBody(enabled: enabled,
                                           until: until.map(JesseBridgeClient.isoInstant)))
    }
}

/// `POST /jesse/profile`'s body. `tz`, `until` and `note` omit when nil, which is exactly what
/// "come home" sends.
struct ProfileBody: Encodable {
    var name: String
    var tz: String?
    var until: String?
    var note: String?
}
