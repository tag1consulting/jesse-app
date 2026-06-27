import Foundation
import Security

// Networking + config for the Jesse bridge. Config (host + token) lives in
// Keychain so it survives reinstalls and isn't in plaintext UserDefaults.

enum JesseMode: String, CaseIterable, Identifiable {
    case ask, tell
    var id: String { rawValue }
    var label: String { self == .ask ? "Ask Jesse" : "Tell Jesse" }
}

/// A file the user picked to send with a turn. `data` is the raw bytes; the
/// client base64-encodes it for the wire. Held in the composer as a removable
/// chip and cleared after a successful send.
struct JesseAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var mime: String
    var data: Data

    var byteCount: Int { data.count }
    var isImage: Bool { mime.hasPrefix("image/") }

    /// Detect a whitelisted MIME from the file's magic bytes — the same sniff
    /// the bridge runs — so the declared type always matches the actual bytes
    /// (a PhotosPicker item may be HEIC even when it looks like a JPEG). Returns
    /// nil for anything not on the whitelist.
    static func sniffMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        func match(_ ascii: String, at off: Int = 0) -> Bool {
            let sig = Array(ascii.utf8)
            guard b.count >= off + sig.count else { return false }
            return Array(b[off..<off + sig.count]) == sig
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if match("GIF87a") || match("GIF89a") { return "image/gif" }
        if match("%PDF-") { return "application/pdf" }
        if match("RIFF") && match("WEBP", at: 8) { return "image/webp" }
        if match("ftyp", at: 4) {
            let brand = b.count >= 12 ? Array(b[8..<12]) : []
            let brands = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
            if brands.contains(where: { Array($0.utf8) == brand }) { return "image/heic" }
        }
        return nil
    }

    /// The on-disk extension matching a whitelisted MIME (for display names).
    static func fileExtension(forMime mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }
}

/// Client-side attachment limits. Mirror the bridge's server-side caps
/// (`JESSE_MAX_ATTACHMENT*`) so a file that would be rejected is caught before
/// it's uploaded; the server still enforces them as the authority.
enum AttachmentLimits {
    static let maxCount = 4
    static let maxBytesPerFile = 10 * 1024 * 1024
    static let maxBytesTotal = 20 * 1024 * 1024

    /// MIME types the bridge will accept (magic-byte-verified server-side).
    static let allowedMimes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic",
        "application/pdf",
    ]

    /// Validate adding `candidate` to the `existing` set. Returns a
    /// user-facing error message if it should be rejected, else nil.
    static func rejectionReason(adding candidate: JesseAttachment,
                                to existing: [JesseAttachment]) -> String? {
        if existing.count >= maxCount {
            return "You can attach at most \(maxCount) files."
        }
        if !allowedMimes.contains(candidate.mime) {
            return "“\(candidate.filename)” isn’t a supported type (images or PDF only)."
        }
        if candidate.byteCount > maxBytesPerFile {
            return "“\(candidate.filename)” is too large (max \(maxBytesPerFile / 1_048_576) MB per file)."
        }
        let total = existing.reduce(0) { $0 + $1.byteCount } + candidate.byteCount
        if total > maxBytesTotal {
            return "Attachments exceed the \(maxBytesTotal / 1_048_576) MB total limit."
        }
        return nil
    }
}

struct JesseConfig {
    var host: String   // e.g. "my-laptop.tailnet-1234.ts.net" or a 100.x IP
    var port: Int
    var token: String

    /// A user-entered host, reduced to its bare components.
    struct SanitizedHost {
        var host: String   // hostname only — no scheme, port, path, or stray case
        var port: Int?     // a port lifted out of the entry ("host:1234"), if any
    }

    /// Defensively parse whatever the user typed or pasted into the host field.
    /// People paste all sorts of things — a full URL copied from Safari
    /// ("http://host:8765/health"), an embedded ":port", a trailing path, a
    /// trailing FQDN dot, mixed case, stray whitespace. Left as-is, these make
    /// `URL(string:)` parse a *wrong* host (e.g. "http://host" → host == "http"),
    /// which then fails DNS as "hostname could not be found". Reduce any of those
    /// to a bare hostname (plus an optional port) so URL construction either
    /// yields the right host or cleanly fails to nil.
    var sanitizedHost: SanitizedHost {
        var s = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip a leading scheme ("http://", "https://") or protocol-relative "//".
        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
        } else if s.hasPrefix("//") {
            s = String(s.dropFirst(2))
        }
        // Drop any pasted credentials ("user@host").
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // Strip a path / query / fragment — everything from the first /, ?, or #.
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }
        // Split off an embedded ":port". (The tailnet host is always a name or a
        // 100.x IPv4, so a single colon is unambiguously the port — we don't
        // handle bracketed IPv6 literals here.)
        var embeddedPort: Int?
        if let colon = s.firstIndex(of: ":") {
            embeddedPort = Int(s[s.index(after: colon)...])
            s = String(s[..<colon])
        }
        // Strip leading/trailing dots (FQDN trailing dot, stray leading dot).
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return SanitizedHost(host: s, port: embeddedPort)
    }

    /// The bare hostname the request will actually target.
    var normalizedHost: String { sanitizedHost.host }

    /// Effective port: a port embedded in the host entry ("host:1234") wins over
    /// the separately-stored port, since pasting "host:1234" clearly means 1234.
    var effectivePort: Int { sanitizedHost.port ?? port }

    /// Build a request URL with URLComponents (host/port/path set explicitly) so
    /// a malformed host yields nil — a clean `notConfigured` — rather than a
    /// silently-wrong host. `path` should be a leading-slash absolute path.
    func endpoint(_ path: String) -> URL? {
        let h = normalizedHost
        guard !h.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = h
        c.port = effectivePort
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url
    }

    var baseURL: URL? { endpoint("") }

    /// Parse a `jesse://pair?host=…&port=…&token=…` pairing payload (printed as a
    /// QR by the bridge on startup). Returns nil for anything that isn't a
    /// well-formed pairing URL with a non-empty host and token. Port defaults to
    /// 8765 when absent or unparseable.
    static func fromPairing(_ raw: String) -> JesseConfig? {
        guard let c = URLComponents(string: raw),
              c.scheme == "jesse", c.host == "pair" else { return nil }
        let items = c.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let host = v("host"), let token = v("token"),
              !host.isEmpty, !token.isEmpty else { return nil }
        return JesseConfig(host: host, port: Int(v("port") ?? "") ?? 8765, token: token)
    }
}

enum JesseError: LocalizedError {
    case notConfigured
    case cannotFindHost(String)
    case cannotConnect(String)
    case timedOut(String)
    case insecureBlocked(String)   // ATS refused the cleartext HTTP load
    case connectionLost            // NSURLErrorNetworkConnectionLost (−1005)
    case transport(String)         // any other URL-loading failure
    case badResponse(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set the laptop host and token in Settings."
        case .cannotFindHost(let h):
            return "Couldn't find host “\(h)”. Check the tailnet name in Settings — just the host, no http:// and no port."
        case .cannotConnect(let h):
            return "Reached DNS but couldn't connect to “\(h)”. Is the Jesse bridge running and is the port right?"
        case .timedOut(let h):
            return "“\(h)” didn't respond in time."
        case .insecureBlocked(let h):
            return "iOS blocked the HTTP connection to “\(h)” (App Transport Security)."
        case .connectionLost:
            // The bridge keeps the turn running detached from the connection and
            // holds the finished reply, so this is recoverable while a job_id is
            // retained — tap Re-check (or just reopen Jesse) to pick it back up.
            return "The connection dropped before the reply came back. It's still being held — tap Re-check to pick it up."
        case .transport(let msg):
            return msg
        case .badResponse(let code, let body):
            return "Server error \(code): \(body)"
        case .decoding:
            return "Couldn't read Jesse's reply."
        }
    }

    /// Map a URL-loading NSError to a message that names the host we actually
    /// tried, so a failure is self-explaining instead of a bare system string.
    static func from(_ error: Error, host: String) -> JesseError {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .transport(ns.localizedDescription) }
        switch ns.code {
        case NSURLErrorCannotFindHost:
            return .cannotFindHost(host)
        case NSURLErrorCannotConnectToHost:
            return .cannotConnect(host)
        case NSURLErrorTimedOut:
            return .timedOut(host)
        case NSURLErrorAppTransportSecurityRequiresSecureConnection,
             NSURLErrorSecureConnectionFailed:
            return .insecureBlocked(host)
        case NSURLErrorNetworkConnectionLost:
            // Typically the socket dropped because the app was suspended
            // mid-turn. The bridge keeps the turn alive, so when a job_id is in
            // flight this is "re-attach on resume", not a failure.
            return .connectionLost
        default:
            return .transport(ns.localizedDescription)
        }
    }
}

struct JesseReply {
    let text: String         // raw response from the bridge
    let sessionId: String?   // carry into the next call to continue the thread

    private static let marker = "SPOKEN:"

    /// Full answer for the screen, with the SPOKEN: line removed.
    var displayText: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(Self.marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to read aloud: the SPOKEN: line if present, else a short fallback.
    var spokenText: String {
        if let line = text.split(separator: "\n")
            .first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(Self.marker) }) {
            let s = line.trimmingCharacters(in: .whitespaces)
            return String(s.dropFirst(Self.marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }
}

/// What `GET /jesse/prompts` returns: the two editable wrapper defaults plus the
/// two fixed safety floors. The floors are display-only — the bridge always
/// prepends them and a custom wrapper can't drop them — so the app shows them
/// read-only rather than seeding an editor from them.
struct PromptDefaults: Equatable {
    let ask: String
    let tell: String
    let askFloor: String
    let tellFloor: String
}

/// Outcome of a `POST /jesse`. The bridge either finishes within its grace
/// window (inline reply, 200) or hands back a job id to poll (202).
enum JesseSendResult {
    case reply(JesseReply, jobId: String?)
    case running(jobId: String)
}

/// State of a job fetched via `GET /jesse/result/{job_id}`.
enum JesseResultState {
    case running
    case done(JesseReply)
    case failed(String)
    /// The bridge no longer has this job (404 — evicted past its TTL). Terminal
    /// and distinct from `.failed`: there is nothing left to re-check, so the
    /// coordinator drops the retained job_id and shows the one genuinely-final
    /// "expired" state. Anything short of this keeps the reply re-checkable.
    case expired
}

/// One decoded frame from the live SSE stream (`GET /jesse/stream/{job_id}`).
/// Mirrors the bridge's wire events. `reset` carries the full text-so-far (sent
/// on subscribe and to re-sync after a lag) and REPLACES the partial buffer;
/// `delta` APPENDS. The three terminal frames mirror `JesseResultState`.
enum JesseStreamEvent {
    case reset(String)
    case delta(String)
    case activity(String)   // coarse tool name, e.g. "Read" / "Write"
    case done(JesseReply)
    case failed(String)
    case cancelled
}

/// The two bridge calls the coordinator drives a turn with. Pulled behind a
/// protocol purely so a fake can exercise the poll loop in tests without a
/// server; `JesseClient` is the only production conformer.
protocol JesseClientProtocol {
    func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment]) async throws -> JesseSendResult
    func result(jobId: String) async throws -> JesseResultState
    /// Best-effort request to stop an in-flight turn server-side. Idempotent.
    func cancelJob(jobId: String) async throws
    /// Live token stream for a running turn (`GET /jesse/stream/{job_id}`). Yields
    /// `reset`/`delta`/`activity` frames as the reply builds, then exactly one
    /// terminal frame (`done`/`failed`/`cancelled`). Throws on a transport/auth
    /// failure or a dropped connection — the coordinator then falls back to
    /// polling `result`. The 202/poll/persist/resume path is the fallback for
    /// this; streaming never replaces it.
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error>
}

struct JesseClient: JesseClientProtocol {
    var config: JesseConfig

    // Agent runs can exceed any fixed cap — that's the point. Raise both timeouts
    // to a day; the UI's Cancel button is the escape hatch, not a timer. Keep
    // these >= the bridge's JESSE_TIMEOUT so a server timeout (if set) wins.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 86_400
        c.timeoutIntervalForResource = 86_400
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// Pass `sessionId` to continue a thread; `voice` asks for a SPOKEN: summary.
    /// A non-empty `instructions` overrides the bridge's built-in wrapper for the
    /// active mode; a non-empty `floorOverride` rewords the always-prepended safety
    /// floor (blank/nil leaves the bridge's built-in floor, which is never removed).
    /// The bridge still appends its voice/phone suffix. Returns either the inline
    /// reply (with the job id the bridge assigned) or, if the turn outran the grace
    /// window, a `running` job id to poll.
    func send(mode: JesseMode, text: String,
              sessionId: String? = nil, voice: Bool = false,
              instructions: String? = nil,
              floorOverride: String? = nil,
              attachments: [JesseAttachment] = []) async throws -> JesseSendResult {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse") else { throw JesseError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let body = Self.requestBody(mode: mode, text: text, sessionId: sessionId,
                                    voice: voice, instructions: instructions,
                                    floorOverride: floorOverride,
                                    attachments: attachments)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodeSend(data: data, resp: resp)
    }

    /// Poll a job started by `send`. Used after a dropped socket (or while the
    /// turn outran the grace window) to fetch the completed reply by id.
    func result(jobId: String) async throws -> JesseResultState {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/result/\(jobId)") else {
            throw JesseError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodeResult(data: data, resp: resp)
    }

    /// Best-effort cancel of an in-flight turn (`POST /jesse/cancel/{job_id}`).
    /// Mirrors `result`'s URL build + bearer auth. The bridge is idempotent — an
    /// unknown, already-finished, or already-cancelled job all return `204` — so a
    /// `404` (a bridge that no longer knows the id) is treated as success too:
    /// there's nothing left to stop. Throws only on a genuine transport/auth
    /// failure, which the caller fires-and-forgets (the orphan, if any, is reaped
    /// by the bridge's job TTL).
    func cancelJob(jobId: String) async throws {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/cancel/\(jobId)") else {
            throw JesseError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // 2xx (the bridge replies 204) or 404 (nothing left to cancel) → success.
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode,
                                     String(data: data, encoding: .utf8) ?? "")
    }

    /// Open the live SSE stream for a running turn and decode each frame. Reads
    /// `text/event-stream` with `URLSession.bytes(for:)`, splits on blank-line
    /// frame boundaries, and maps `event:`/`data:` pairs to `JesseStreamEvent`.
    /// Comment lines (`:` keep-alives) are skipped. The inner URL task is
    /// cancelled when the returned stream is torn down (the consumer's task is
    /// cancelled, e.g. on user Cancel) — which drops the SSE connection so no
    /// subscriber dangles. Any transport/HTTP failure finishes the stream with a
    /// throw, signalling the coordinator to fall back to polling.
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
                          let url = config.endpoint("/jesse/stream/\(jobId)") else {
                        throw JesseError.notConfigured
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let bytes: URLSession.AsyncBytes, resp: URLResponse
                    do {
                        (bytes, resp) = try await Self.session.bytes(for: req)
                    } catch {
                        throw JesseError.from(error, host: config.normalizedHost)
                    }
                    guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
                    guard (200..<300).contains(http.statusCode) else {
                        // Includes 404 (unknown/expired) — the coordinator's poll
                        // fallback resolves what actually happened to the job.
                        throw JesseError.badResponse(http.statusCode, "")
                    }

                    var eventName = ""
                    var dataBuf = ""
                    func flush() {
                        defer { eventName = ""; dataBuf = "" }
                        guard !eventName.isEmpty,
                              let ev = Self.decodeStreamFrame(event: eventName, data: dataBuf)
                        else { return }
                        continuation.yield(ev)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty { flush(); continue }     // frame boundary
                        if line.hasPrefix(":") { continue }       // keep-alive comment
                        if let v = Self.sseField("event:", line) {
                            eventName = v
                        } else if let v = Self.sseField("data:", line) {
                            dataBuf += v
                        }
                    }
                    flush() // a final frame not followed by a blank line before EOF
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Strip an SSE field prefix and its single optional leading space.
    nonisolated private static func sseField(_ prefix: String, _ line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
    }

    /// Decode one SSE frame (`event` name + JSON `data`) into a stream event.
    nonisolated static func decodeStreamFrame(event: String, data: String) -> JesseStreamEvent? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
        switch event {
        case "reset": return .reset(obj?["text"] as? String ?? "")
        case "delta": return .delta(obj?["text"] as? String ?? "")
        case "activity": return .activity(obj?["name"] as? String ?? "")
        case "done":
            return .done(JesseReply(text: obj?["response"] as? String ?? "",
                                    sessionId: obj?["session_id"] as? String))
        case "error": return .failed(obj?["error"] as? String ?? "Jesse couldn't complete that.")
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Fetch the bridge's built-in Ask/Tell wrapper defaults (`GET /jesse/prompts`).
    /// Mirrors `send`'s URL building and bearer auth. Used by Settings to populate
    /// the editors and to reset a field to the current bridge default.
    func fetchPrompts() async throws -> PromptDefaults {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/prompts") else { throw JesseError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodePrompts(data: data, resp: resp)
    }

    // Body encode/decode split out as pure, static functions so the wire contract
    // can be unit-tested without standing up a server.

    /// Build the `POST /jesse` JSON body. Optional fields are included only when
    /// they carry content: `instructions` and `floor_override` are omitted when nil
    /// or blank (so an empty override means "use the bridge default" — for the floor,
    /// the bridge's built-in floor, which it never drops), matching the bridge's
    /// `#[serde(default)]` shape so omitting a field reproduces today's behavior.
    static func requestBody(mode: JesseMode, text: String, sessionId: String?,
                            voice: Bool, instructions: String?,
                            floorOverride: String?,
                            attachments: [JesseAttachment]) -> [String: Any] {
        var body: [String: Any] = ["mode": mode.rawValue, "text": text]
        if let sessionId { body["session_id"] = sessionId }
        if voice { body["voice"] = true }
        if let instructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = instructions
        }
        if let floorOverride,
           !floorOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["floor_override"] = floorOverride
        }
        if !attachments.isEmpty {
            // Base64-in-JSON: matches the existing JSONSerialization path. The
            // bridge re-validates type and size; these are sent as-is.
            body["attachments"] = attachments.map { a in
                [
                    "filename": a.filename,
                    "mime": a.mime,
                    "data_base64": a.data.base64EncodedString(),
                ]
            }
        }
        return body
    }

    static func decodeSend(data: Data, resp: URLResponse) throws -> JesseSendResult {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // 202 = still running; hand back the job id to poll. Checked before the
        // 2xx success branch since 202 is itself a success code.
        if http.statusCode == 202 {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobId = obj["job_id"] as? String else { throw JesseError.decoding }
            return .running(jobId: jobId)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = obj["response"] as? String else { throw JesseError.decoding }
        return .reply(JesseReply(text: reply, sessionId: obj["session_id"] as? String),
                      jobId: obj["job_id"] as? String)
    }

    static func decodeResult(data: Data, resp: URLResponse) throws -> JesseResultState {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // An unknown/evicted id is the one genuinely terminal "gone" state: the
        // bridge held the reply for its TTL and it's now past. Distinct from a
        // `.failed` (which stays re-checkable) — the coordinator clears the job.
        if http.statusCode == 404 {
            return .expired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { throw JesseError.decoding }
        switch status {
        case "running":
            return .running
        case "done":
            guard let text = obj["response"] as? String else { throw JesseError.decoding }
            return .done(JesseReply(text: text, sessionId: obj["session_id"] as? String))
        case "failed":
            return .failed(obj["error"] as? String ?? "Jesse couldn't complete that.")
        default:
            throw JesseError.decoding
        }
    }

    static func decodePrompts(data: Data, resp: URLResponse) throws -> PromptDefaults {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
        // All four keys are required: a bridge too old to expose the fixed floors
        // can't enforce them, so fail rather than silently show none.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ask = obj["ask"] as? String, let tell = obj["tell"] as? String,
              let askFloor = obj["ask_floor"] as? String,
              let tellFloor = obj["tell_floor"] as? String else {
            throw JesseError.decoding
        }
        return PromptDefaults(ask: ask, tell: tell,
                              askFloor: askFloor, tellFloor: tellFloor)
    }
}

// MARK: - Keychain-backed config store

enum ConfigStore {
    private static let service = "com.tag1.jesse"

    static func load() -> JesseConfig {
        JesseConfig(
            host: read("host") ?? "",
            port: Int(read("port") ?? "") ?? 8765,
            token: read("token") ?? ""
        )
    }

    static func save(_ c: JesseConfig) {
        write("host", c.host)
        write("port", String(c.port))
        write("token", c.token)
    }

    private static func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
