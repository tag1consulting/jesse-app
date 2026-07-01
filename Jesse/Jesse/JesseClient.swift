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
    /// The bridge's default port (`JESSE_PORT`), used when a pairing payload or a
    /// stored config omits/can't parse one.
    static let defaultPort = 8765

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

    /// Whether the bridge is paired: a host and token are both set. Gates push
    /// authorization (don't ask before Jesse is even configured) and registration.
    var isConfigured: Bool { !normalizedHost.isEmpty && !token.isEmpty }

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
        return JesseConfig(host: host, port: Int(v("port") ?? "") ?? JesseConfig.defaultPort, token: token)
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

struct JesseReply: Equatable {
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
    /// The turn was cancelled server-side — the bridge serializes a cancelled job
    /// as `{"status":"cancelled"}` (see bridge/README.md cancel/eviction). A clean
    /// terminal state, NOT a failure: the coordinator drops the job and returns the
    /// thread to idle, mirroring the stream's `cancelled` frame. (Before this was
    /// handled, the poll path threw `.decoding` on this status → mapped to `.failed`
    /// → a permanently stuck "Re-check" that re-polled into the same error forever.)
    case cancelled
}

/// One decoded frame from the live SSE stream (`GET /jesse/stream/{job_id}`).
/// Mirrors the bridge's wire events. `reset` carries the full text-so-far (sent
/// on subscribe and to re-sync after a lag) and REPLACES the partial buffer;
/// `delta` APPENDS. The three terminal frames mirror `JesseResultState`.
enum JesseStreamEvent: Equatable {
    case reset(String)
    case delta(String)
    case activity(String)   // coarse tool name, e.g. "Read" / "Write"
    case done(JesseReply)
    case failed(String)
    case cancelled
}

// MARK: - Wire contract (Codable)
//
// The bridge's JSON is modeled as Codable structs so each wire key
// ("job_id"/"session_id"/"response"/"status"/"error"/…) is a single CodingKey
// shared by encode and decode — not a magic string duplicated between a hand-built
// `[String: Any]` and `obj["…"] as? T` casts. Optional fields encode only when
// present (Swift's synthesized `encodeIfPresent`), so the bytes on the wire are
// unchanged from the old dictionary that omitted nil/blank fields. `InFlightJob`
// and `PromptDefaults` already use Codable; this matches them.

/// The `POST /jesse` request body. A nil `sessionId`/`voice`/`instructions`/
/// `floorOverride`/`attachments` omits its field, reproducing the old
/// conditionally-built dictionary byte-for-byte and matching the bridge's
/// `#[serde(default)]` shape. Build it with `JesseClient.makeRequest`, which
/// normalizes "use the default" (blank override, false voice, no attachments) to
/// nil so the field drops out.
nonisolated struct JesseRequest: Encodable, Equatable {
    let mode: String
    let text: String
    let sessionId: String?
    let voice: Bool?
    let instructions: String?
    let floorOverride: String?
    let attachments: [Attachment]?

    nonisolated struct Attachment: Encodable, Equatable {
        let filename: String
        let mime: String
        let dataBase64: String
        enum CodingKeys: String, CodingKey {
            case filename, mime
            case dataBase64 = "data_base64"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, text
        case sessionId = "session_id"
        case voice, instructions
        case floorOverride = "floor_override"
        case attachments
    }
}

/// Decoded `POST /jesse` response. The 200 carries `response` (+`session_id`,
/// +`job_id`); the 202 carries `job_id`+`status`. One all-optional shape covers
/// both; `decodeSend` picks the arm by status code and required field.
nonisolated struct JesseSendResponse: Decodable {
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

/// Decoded `GET /jesse/result/{id}` body: `status` plus the fields that status
/// implies (`response`/`session_id` for done, `error` for failed).
nonisolated struct JesseResultResponse: Decodable {
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

/// Decoded `GET /jesse/prompts` body — all four fields required.
nonisolated struct JessePromptsResponse: Decodable {
    let ask: String
    let tell: String
    let askFloor: String
    let tellFloor: String
    enum CodingKeys: String, CodingKey {
        case ask, tell
        case askFloor = "ask_floor"
        case tellFloor = "tell_floor"
    }
}

/// Decoded `data:` payload of one SSE frame. Every field is optional — which one
/// is meaningful depends on the frame's `event:` name (see `decodeStreamFrame`).
nonisolated struct JesseStreamFrameData: Decodable {
    let text: String?
    let name: String?
    let response: String?
    let sessionId: String?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case text, name, response
        case sessionId = "session_id"
        case error
    }
}

/// The `POST /jesse/device` body — register this phone's APNs token.
nonisolated struct JesseDeviceRegistration: Encodable {
    let token: String
}

/// The `POST /jesse/title` request body: a bounded, whitespace-collapsed digest
/// of the conversation (see `titleDigest`) the bridge summarizes into a short
/// title. The bridge's field is `text` (it caps input at 16 KiB and sanitizes the
/// result); our `digest` property maps to that wire key. Our digest is capped well
/// under the bridge's input limit.
nonisolated struct JesseTitleRequest: Encodable, Equatable {
    let digest: String
    enum CodingKeys: String, CodingKey {
        case digest = "text"
    }
}

/// Decoded `POST /jesse/title` body — a single short title string. Any other
/// shape (or a missing endpoint) decodes to nil upstream, so the row keeps its
/// derived title.
nonisolated struct JesseTitleResponse: Decodable {
    let title: String
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
    /// Register (idempotent upsert) this phone's APNs device token with the bridge
    /// (`POST /jesse/device`) so it can push when a backgrounded turn finishes.
    func registerDevice(token: String) async throws
    /// Ask the bridge to push when `jobId` completes (`POST /jesse/notify/{job_id}`).
    /// Fired when the app backgrounds with that turn still in flight — "I'm
    /// leaving, ping me." Best-effort and idempotent.
    func notifyOnComplete(jobId: String) async throws
    /// Ask the bridge to mint a short conversation title from `digest`
    /// (`POST /jesse/title`). Returns the title, or nil for ANY failure — offline,
    /// a bridge with no such endpoint (404), a timeout, a non-2xx, or an empty
    /// title. It NEVER throws to the UI: a missing title just leaves the row's
    /// derived title in place. See `title(forDigest:)` on `JesseClient`.
    func title(forDigest digest: String) async -> String?
}

extension JesseClientProtocol {
    // Default no-ops so existing conformers (the test fakes) need not implement
    // the push methods; only the production `JesseClient` does the real calls.
    func registerDevice(token: String) async throws {}
    func notifyOnComplete(jobId: String) async throws {}
    // Default "no title": a fake that doesn't opt into titling degrades exactly
    // like a bridge without the endpoint (the row keeps its derived title).
    func title(forDigest digest: String) async -> String? { nil }
}

struct JesseClient: JesseClientProtocol {
    var config: JesseConfig

    /// The URLSession the **short** request/response calls go through — `send`,
    /// `result`, `cancelJob`, `registerDevice`, `notifyOnComplete`. Defaults to the
    /// bounded production session (`boundedSession`); injectable purely so the
    /// integration tests can supply a session backed by a custom `URLProtocol` stub.
    let session: URLSession

    /// The URLSession the long-lived **SSE stream** (`stream`) goes through. The
    /// stream connection legitimately stays open for the whole turn, so it keeps a
    /// high resource timeout; it is deliberately a *different* session from the
    /// short calls, so a stalled stream can never make the completion poll wait.
    /// Defaults to `streamingSession`. When a test injects its own `session` (a
    /// `URLProtocol` stub) without naming `streamSession`, the stream follows that
    /// same injected session, so a single stub still serves every endpoint.
    let streamSession: URLSession

    init(config: JesseConfig,
         session: URLSession = JesseClient.boundedSession,
         streamSession: URLSession? = nil) {
        self.config = config
        self.session = session
        if let streamSession {
            self.streamSession = streamSession
        } else if session === JesseClient.boundedSession {
            // Production path: short calls on the bounded session, the SSE stream
            // on the long-lived one.
            self.streamSession = JesseClient.streamingSession
        } else {
            // A test injected a stub `session` but no `streamSession`; route the
            // stream through that same stub so one stub serves all endpoints.
            self.streamSession = session
        }
    }

    // The short request/response calls (poll, send, cancel, register, notify) get a
    // BOUNDED per-request deadline and do NOT wait for connectivity, so each one
    // always either answers or throws — the completion poll loop can then do its
    // job. (Before, every call shared one 86_400s / waitsForConnectivity session:
    // if the bridge went unreachable mid-turn the poll GET neither returned nor
    // threw for up to 24h, parking the turn forever.) None of these requests
    // legitimately runs for minutes — only the SSE stream does, and it has its own
    // session below.
    static let boundedSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // The SSE stream legitimately stays open for the whole turn — agent runs can
    // exceed any fixed cap, which is the point. Give it a day-long resource ceiling
    // and let it wait for connectivity; the UI's Cancel button is the escape hatch.
    // This session is used ONLY by `stream()`, so its long timeouts can never delay
    // a short call or the completion poll.
    static let streamingSession: URLSession = {
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
        let request = Self.makeRequest(mode: mode, text: text, sessionId: sessionId,
                                       voice: voice, instructions: instructions,
                                       floorOverride: floorOverride,
                                       attachments: attachments)
        req.httpBody = try Self.encodeBody(request)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
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
            (data, resp) = try await session.data(for: req)
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
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // 2xx (the bridge replies 204) or 404 (nothing left to cancel) → success.
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode,
                                     String(data: data, encoding: .utf8) ?? "")
    }

    /// Register this phone's APNs device token with the bridge
    /// (`POST /jesse/device`). Idempotent upsert server-side. Bearer auth like
    /// every other call. Throws on a transport/auth/HTTP failure so the caller
    /// can retry (registration is fired on first authorization, on token change,
    /// and on each foreground).
    func registerDevice(token: String) async throws {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/device") else { throw JesseError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try Self.encodeBody(JesseDeviceRegistration(token: token))

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Ask the bridge to push when `jobId` completes (`POST /jesse/notify/{job_id}`).
    /// Fired as the app backgrounds with that turn in flight. Mirrors `cancelJob`'s
    /// shape: a `404` (bridge no longer knows the id) is fine — nothing to ping —
    /// so only a genuine transport/auth/5xx error throws (the caller fires this
    /// best-effort).
    func notifyOnComplete(jobId: String) async throws {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/notify/\(jobId)") else {
            throw JesseError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        throw JesseError.badResponse(http.statusCode,
                                     String(data: data, encoding: .utf8) ?? "")
    }

    /// Mint a short conversation title from `digest` (`POST /jesse/title`). Mirrors
    /// the other calls' URL build + bearer auth + bounded session, but is
    /// deliberately *total*: EVERY failure mode — not configured, an encode
    /// failure, a transport error (offline/timeout/dropped), a non-2xx (a bridge
    /// that predates the endpoint answers 404), an undecodable body, or a
    /// blank/whitespace title — collapses to `nil`. It never throws, so a caller on
    /// the list path can fire it without a `try` and the row simply keeps its
    /// derived title when no AI title comes back. AI titles therefore only populate
    /// against a bridge that actually has /jesse/title deployed.
    func title(forDigest digest: String) async -> String? {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse/title"),
              let body = try? Self.encodeBody(JesseTitleRequest(digest: digest)) else {
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
              let obj = try? JSONDecoder().decode(JesseTitleResponse.self, from: data) else {
            return nil
        }
        let trimmed = obj.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

                    // The line→frame framing is factored into the pure `SSEParser`
                    // (unit-tested directly via `framesFromLines`); here we just feed
                    // it lines as they arrive and yield each completed frame live.
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

    /// Strip an SSE field prefix and its single optional leading space.
    nonisolated private static func sseField(_ prefix: String, _ line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
    }

    /// Decode one SSE frame (`event` name + JSON `data`) into a stream event. A
    /// malformed/empty `data` decodes to nil and falls back to the same defaults the
    /// old `obj?["…"] ?? …` casts used.
    nonisolated static func decodeStreamFrame(event: String, data: String) -> JesseStreamEvent? {
        let obj = try? JSONDecoder().decode(JesseStreamFrameData.self, from: Data(data.utf8))
        switch event {
        case "reset": return .reset(obj?.text ?? "")
        case "delta": return .delta(obj?.text ?? "")
        case "activity": return .activity(obj?.name ?? "")
        case "done":
            return .done(JesseReply(text: obj?.response ?? "", sessionId: obj?.sessionId))
        case "error": return .failed(obj?.error ?? "Jesse couldn't complete that.")
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Stateful SSE line→frame state machine. Pure (no I/O): `stream` feeds it lines
    /// as `URLSession.AsyncBytes.lines` yields them and forwards each completed
    /// frame; tests feed hand-built line arrays via `framesFromLines`. Factored out
    /// so the framing — the spot the CHANGELOG's blank-line-swallowing bug lived —
    /// can be unit-tested directly. `nonisolated` so the SSE-reading Task (which runs
    /// off the main actor) can drive it without an actor hop per line.
    nonisolated struct SSEParser {
        private var eventName = ""
        private var dataBuf = ""

        /// Feed one line; returns the frame it completes, if any.
        ///
        /// A blank line is a frame boundary. A new `event:` line ALSO flushes the
        /// previous frame, because `URLSession.AsyncBytes.lines` *swallows blank
        /// lines* — so the blank-line boundary often never arrives and the only
        /// reliable separator is the next `event:`. `:` lines are SSE comments
        /// (keep-alives) and are ignored.
        mutating func consume(_ line: String) -> JesseStreamEvent? {
            if line.isEmpty { return flush() }          // frame boundary
            if line.hasPrefix(":") { return nil }       // keep-alive comment
            if let v = JesseClient.sseField("event:", line) {
                // A new `event:` line flushes the previous frame — the boundary that
                // survives swallowed blank lines. Each bridge frame carries exactly
                // one `event:` line, so this is exact.
                let completed = eventName.isEmpty ? nil : flush()
                eventName = v
                return completed
            } else if let v = JesseClient.sseField("data:", line) {
                dataBuf += v
            }
            return nil
        }

        /// Flush the final frame at end of input (no trailing blank line before EOF).
        mutating func finish() -> JesseStreamEvent? { flush() }

        private mutating func flush() -> JesseStreamEvent? {
            defer { eventName = ""; dataBuf = "" }
            guard !eventName.isEmpty else { return nil }
            return JesseClient.decodeStreamFrame(event: eventName, data: dataBuf)
        }
    }

    /// Pure line→frame conversion over a whole sequence of SSE lines, for unit
    /// testing the framing over hand-built line arrays.
    nonisolated static func framesFromLines<S: Sequence<String>>(_ lines: S) -> [JesseStreamEvent] {
        var parser = SSEParser()
        var out: [JesseStreamEvent] = []
        for line in lines {
            if let ev = parser.consume(line) { out.append(ev) }
        }
        if let ev = parser.finish() { out.append(ev) }
        return out
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
            (data, resp) = try await session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        return try Self.decodePrompts(data: data, resp: resp)
    }

    // Body encode/decode split out as pure, static functions so the wire contract
    // can be unit-tested without standing up a server.

    /// Build the `POST /jesse` request. "Use the bridge default" collapses to a nil
    /// field that drops out of the encoded body: `voice == false`, a blank
    /// `instructions`/`floorOverride`, and an empty `attachments` all become nil. The
    /// floor's nil means the bridge keeps its built-in floor, which it never drops.
    static func makeRequest(mode: JesseMode, text: String, sessionId: String?,
                            voice: Bool, instructions: String?,
                            floorOverride: String?,
                            attachments: [JesseAttachment]) -> JesseRequest {
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
            // Base64-in-JSON, re-validated by the bridge for type and size.
            attachments: attachments.isEmpty ? nil : attachments.map {
                JesseRequest.Attachment(filename: $0.filename, mime: $0.mime,
                                        dataBase64: $0.data.base64EncodedString())
            })
    }

    /// Encode a wire body. Optional fields omit when nil (synthesized
    /// `encodeIfPresent`), so the keys present match the old hand-built dictionary
    /// that conditionally inserted them. `sortedKeys` makes the byte order
    /// deterministic (so the wire shape can be pinned in a test) and
    /// `withoutEscapingSlashes` keeps `image/png` and base64 readable; the bridge's
    /// serde accepts any key order, so the contract is unchanged either way.
    static func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decodeSend(data: Data, resp: URLResponse) throws -> JesseSendResult {
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        // 202 = still running; hand back the job id to poll. Checked before the
        // 2xx success branch since 202 is itself a success code.
        if http.statusCode == 202 {
            guard let obj = try? JSONDecoder().decode(JesseSendResponse.self, from: data),
                  let jobId = obj.jobId else { throw JesseError.decoding }
            return .running(jobId: jobId)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONDecoder().decode(JesseSendResponse.self, from: data),
              let reply = obj.response else { throw JesseError.decoding }
        return .reply(JesseReply(text: reply, sessionId: obj.sessionId), jobId: obj.jobId)
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
        guard let obj = try? JSONDecoder().decode(JesseResultResponse.self, from: data) else {
            throw JesseError.decoding
        }
        switch obj.status {
        case "running":
            return .running
        case "done":
            guard let text = obj.response else { throw JesseError.decoding }
            return .done(JesseReply(text: text, sessionId: obj.sessionId))
        case "failed":
            return .failed(obj.error ?? "Jesse couldn't complete that.")
        case "cancelled":
            // The bridge's terminal state for a cancelled turn. A clean status, not
            // a failure — mirrors the stream's `cancelled` frame (decodeStreamFrame).
            // Without this case it fell through to `default` → `.decoding`, which the
            // poll loop turned into a permanently stuck "Re-check".
            return .cancelled
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
        guard let obj = try? JSONDecoder().decode(JessePromptsResponse.self, from: data) else {
            throw JesseError.decoding
        }
        return PromptDefaults(ask: obj.ask, tell: obj.tell,
                              askFloor: obj.askFloor, tellFloor: obj.tellFloor)
    }
}

// MARK: - Keychain-backed config store

enum ConfigStore {
    private static let service = "com.tag1.jesse"

    /// Seams for the three Keychain primitives so a test can force an `OSStatus` or
    /// supply an in-memory backend without a real Keychain (the test bundle often
    /// lacks Keychain entitlements). Production uses the `SecItem*` functions
    /// directly. `addItem` and `copyItem` take the same (query, result) shape as
    /// `SecItemAdd`/`SecItemCopyMatching`; `deleteItem` mirrors `SecItemDelete`.
    nonisolated(unsafe) static var addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    nonisolated(unsafe) static var copyItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    nonisolated(unsafe) static var deleteItem: (CFDictionary) -> OSStatus = SecItemDelete

    static func load() -> JesseConfig {
        JesseConfig(
            host: read("host") ?? "",
            port: Int(read("port") ?? "") ?? JesseConfig.defaultPort,
            token: read("token") ?? ""
        )
    }

    /// Persist the config. Returns `false` if any field's write failed (e.g. the
    /// Keychain was locked), so a caller can surface "couldn't save the token"
    /// rather than silently losing it.
    @discardableResult
    static func save(_ c: JesseConfig) -> Bool {
        let okHost = write("host", c.host)
        let okPort = write("port", String(c.port))
        let okToken = write("token", c.token)
        return okHost && okPort && okToken
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
        guard copyItem(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func write(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        _ = deleteItem(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        let status = addItem(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Surface, don't swallow: a locked Keychain (or missing entitlement)
            // would otherwise lose the token with no trace. The status code is not
            // a secret (the value itself is never logged).
            Log.keychain.error("SecItemAdd failed for key \(key): OSStatus \(status)")
            return false
        }
        return true
    }
}
