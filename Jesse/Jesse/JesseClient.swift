import Foundation
import Security

// Networking + config for the Jesse bridge. Config (host + token) lives in
// Keychain so it survives reinstalls and isn't in plaintext UserDefaults.

enum JesseMode: String, CaseIterable, Identifiable {
    case ask, tell
    var id: String { rawValue }
    var label: String { self == .ask ? "Ask Jesse" : "Tell Jesse" }
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

struct JesseClient {
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
    func send(mode: JesseMode, text: String,
              sessionId: String? = nil, voice: Bool = false) async throws -> JesseReply {
        guard !config.normalizedHost.isEmpty, !config.token.isEmpty,
              let url = config.endpoint("/jesse") else { throw JesseError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["mode": mode.rawValue, "text": text]
        if let sessionId { body["session_id"] = sessionId }
        if voice { body["voice"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw JesseError.from(error, host: config.normalizedHost)
        }
        guard let http = resp as? HTTPURLResponse else { throw JesseError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw JesseError.badResponse(http.statusCode,
                                         String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = obj["response"] as? String else { throw JesseError.decoding }
        return JesseReply(text: reply, sessionId: obj["session_id"] as? String)
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
