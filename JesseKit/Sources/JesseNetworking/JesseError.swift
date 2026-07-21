import Foundation

// Error taxonomy for the bridge client. `JesseError` maps URL-loading and HTTP
// failures to self-explaining messages that name the host actually tried;
// `DietFetchError` distinguishes the `GET /jesse/diet` failure modes so the Health tab
// can show the matching empty state.

public enum JesseError: LocalizedError, Sendable {
    case notConfigured
    case cannotFindHost(String)
    case cannotConnect(String)
    case timedOut(String)
    case insecureBlocked(String)   // ATS refused the cleartext HTTP load
    case connectionLost            // NSURLErrorNetworkConnectionLost (−1005)
    case transport(String)         // any other URL-loading failure
    case badResponse(Int, String)
    case decoding

    public var errorDescription: String? {
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
    public static func from(_ error: Error, host: String) -> JesseError {
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

/// Why a `GET /jesse/diet` fetch failed, distinguished so the Health tab can show
/// the right full-screen empty state instead of one generic error. Each case maps
/// to a distinct recovery hint (pair, check the bridge, update the bridge, retry).
public enum DietFetchError: Error, Equatable, Sendable {
    case notConfigured          // no host/token — never paired
    case unreachable(String)    // offline / DNS / connection dropped (message names the host)
    case authFailed             // 401 — token wrong
    case endpointMissing        // 404 — a bridge too old to have /jesse/diet
    case unavailable            // 503 — bridge up but diet-today.js is broken
    case decodeFailed           // 2xx but the body didn't decode
    case server(Int)            // any other non-2xx
}
