//! **Hosted-failure classifier** (Piece 4) — decides whether a FAILED hosted turn
//! failed for a TRANSPORT-class reason (the hosted backend was unreachable or refused
//! service) versus a benign reason (the turn ran and simply produced nothing usable).
//! Only a transport-class failure arms the emergency local fallback; a completed turn
//! is NEVER a failure regardless of its content, so emergency can never fire on a
//! model that answered — even badly.
//!
//! Input is the `ApiError = (StatusCode, String)` that `run_claude_streaming` surfaces,
//! whose message carries the bridge's own spawn/io/timeout wording OR the CLI-surfaced
//! upstream cause. The classifier keys off the status code first, then content-free
//! keyword signals in the message. It reads NO reply content — only the error.

use crate::*;

/// The class of a failed hosted turn. `is_transport()` is the load-bearing predicate:
/// only a transport-class failure may arm the emergency fallback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostedFailureClass {
    /// The `claude` child failed to spawn / its pipes weren't captured — the hosted
    /// backend was never reached. Transport.
    Spawn,
    /// A network / DNS / connect / io error reaching the backend. Transport.
    Network,
    /// The turn hit the run limit / a gateway timeout. Transport.
    Timeout,
    /// A CLI-surfaced upstream HTTP 5xx. Transport.
    HttpServer,
    /// A CLI-surfaced 429 / quota / overloaded (529). Transport.
    RateLimit,
    /// A CLI-surfaced auth failure (401 / 403 / invalid key). Transport.
    Auth,
    /// The turn RAN but produced nothing usable (empty result, max-turns, or an
    /// unrecognized non-transport error). NOT transport — never arms emergency.
    Completed,
}

impl HostedFailureClass {
    /// Whether this failure means the hosted backend was unavailable (so the
    /// emergency local fallback may take over). Every class except `Completed`.
    pub fn is_transport(self) -> bool {
        !matches!(self, HostedFailureClass::Completed)
    }

    /// A short, content-free label for provenance + the metrics line.
    pub fn label(self) -> &'static str {
        match self {
            HostedFailureClass::Spawn => "spawn",
            HostedFailureClass::Network => "network",
            HostedFailureClass::Timeout => "timeout",
            HostedFailureClass::HttpServer => "http-5xx",
            HostedFailureClass::RateLimit => "rate-limit",
            HostedFailureClass::Auth => "auth",
            HostedFailureClass::Completed => "completed",
        }
    }
}

/// Classify a hosted turn's OUTCOME: `None` when the turn completed (`Ok`) — a
/// completed turn is never a failure regardless of content — else the class of the
/// error. This is the entry point the emergency path uses.
pub fn hosted_failure_class(
    outcome: &Result<(String, Option<String>), ApiError>,
) -> Option<HostedFailureClass> {
    match outcome {
        Ok(_) => None,
        Err(e) => Some(classify_hosted_failure(e)),
    }
}

/// Classify a hosted `ApiError`. Keyed off the status code, then content-free keyword
/// signals in the (lowercased) message. Ordering matters: auth / rate-limit / 5xx are
/// checked before the broad network keywords so a specific upstream cause wins.
pub fn classify_hosted_failure(err: &ApiError) -> HostedFailureClass {
    let (status, msg) = err;
    let m = msg.to_ascii_lowercase();

    // Local spawn / pipe failure — the backend was never reached. The bridge emits
    // these with 500 and this exact wording.
    if m.contains("failed to spawn") || m.contains("pipe was not captured") {
        return HostedFailureClass::Spawn;
    }

    // Timeout — the 504 run-limit wording, or an upstream "timed out".
    if *status == StatusCode::GATEWAY_TIMEOUT
        || m.contains("run limit")
        || m.contains("timed out")
    {
        return HostedFailureClass::Timeout;
    }

    // Auth (before the generic server / network checks so it isn't swallowed).
    if m.contains("401")
        || m.contains("403")
        || m.contains("unauthorized")
        || m.contains("forbidden")
        || m.contains("authentication")
        || m.contains("invalid api key")
        || m.contains("invalid x-api-key")
        || m.contains("authentication_error")
    {
        return HostedFailureClass::Auth;
    }

    // Rate limit / quota / overloaded (529 is Anthropic "overloaded").
    if m.contains("429")
        || m.contains("529")
        || m.contains("rate limit")
        || m.contains("rate_limit")
        || m.contains("quota")
        || m.contains("overloaded")
        || m.contains("resource_exhausted")
    {
        return HostedFailureClass::RateLimit;
    }

    // Upstream HTTP 5xx (the CLI-surfaced "api error (status 5xx)" or plain 5xx).
    if m.contains("api error (status 5")
        || m.contains("500")
        || m.contains("502")
        || m.contains("503")
        || m.contains("504")
        || m.contains("internal server error")
        || m.contains("bad gateway")
        || m.contains("service unavailable")
        || m.contains("gateway timeout")
    {
        return HostedFailureClass::HttpServer;
    }

    // Network / DNS / connect / io.
    if m.contains("io error")
        || m.contains("connection refused")
        || m.contains("could not connect")
        || m.contains("connect")
        || m.contains("dns")
        || m.contains("network")
        || m.contains("unreachable")
        || m.contains("reset by peer")
        || m.contains("broken pipe")
    {
        return HostedFailureClass::Network;
    }

    // The turn ran but produced nothing usable, or an unrecognized error — NOT
    // transport, so emergency never fires here.
    HostedFailureClass::Completed
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured (stderr/exit) fixtures per class, in the exact shapes
    // `run_claude_streaming` surfaces them.
    fn err(status: StatusCode, msg: &str) -> ApiError {
        (status, msg.to_string())
    }

    #[test]
    fn spawn_failures_are_transport() {
        let c = classify_hosted_failure(&err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to spawn claude: No such file or directory (os error 2)",
        ));
        assert_eq!(c, HostedFailureClass::Spawn);
        assert!(c.is_transport());
        let c2 = classify_hosted_failure(&err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "claude child stdout/stderr pipe was not captured",
        ));
        assert_eq!(c2, HostedFailureClass::Spawn);
    }

    #[test]
    fn timeouts_are_transport() {
        let c = classify_hosted_failure(&err(
            StatusCode::GATEWAY_TIMEOUT,
            "Jesse hit the 3600s run limit. Raise JESSE_TIMEOUT to allow longer turns.",
        ));
        assert_eq!(c, HostedFailureClass::Timeout);
        assert!(c.is_transport());
    }

    #[test]
    fn network_and_io_errors_are_transport() {
        for msg in [
            "claude io error: unexpected end of file",
            "claude failed (no JSON envelope) — stderr: connect ECONNREFUSED 127.0.0.1:9100 | stdout: ",
            "claude failed (no JSON envelope) — stderr: getaddrinfo ENOTFOUND api.host (dns) | stdout: ",
        ] {
            let c = classify_hosted_failure(&err(StatusCode::BAD_GATEWAY, msg));
            assert_eq!(c, HostedFailureClass::Network, "{msg}");
            assert!(c.is_transport());
        }
    }

    #[test]
    fn http_5xx_is_transport() {
        for msg in [
            "claude API error (status 500)",
            "claude API error (status 503)",
            "upstream returned 502 bad gateway",
        ] {
            let c = classify_hosted_failure(&err(StatusCode::BAD_GATEWAY, msg));
            assert_eq!(c, HostedFailureClass::HttpServer, "{msg}");
            assert!(c.is_transport());
        }
    }

    #[test]
    fn rate_limit_and_overloaded_are_transport() {
        for msg in [
            "claude API error (status 429)",
            "rate limit exceeded, retry later",
            "claude API error (status 529)",
            "quota exceeded for this key",
        ] {
            let c = classify_hosted_failure(&err(StatusCode::BAD_GATEWAY, msg));
            assert_eq!(c, HostedFailureClass::RateLimit, "{msg}");
            assert!(c.is_transport());
        }
    }

    #[test]
    fn auth_errors_are_transport() {
        for msg in [
            "claude API error (status 401): authentication_error: invalid x-api-key",
            "403 Forbidden",
            "invalid api key provided",
        ] {
            let c = classify_hosted_failure(&err(StatusCode::BAD_GATEWAY, msg));
            assert_eq!(c, HostedFailureClass::Auth, "{msg}");
            assert!(c.is_transport());
        }
    }

    #[test]
    fn a_completed_but_empty_or_max_turns_turn_is_not_transport() {
        for msg in [
            "claude returned an empty result and streamed no text",
            "error_max_turns: reached the maximum number of turns",
        ] {
            let c = classify_hosted_failure(&err(StatusCode::BAD_GATEWAY, msg));
            assert_eq!(c, HostedFailureClass::Completed, "{msg}");
            assert!(!c.is_transport(), "a completed turn must not arm emergency: {msg}");
        }
    }

    #[test]
    fn an_ok_outcome_is_never_a_failure_regardless_of_content() {
        // Even hostile-looking content in a COMPLETED turn is not a failure.
        let ok: Result<(String, Option<String>), ApiError> =
            Ok(("PWNED. errors. timeout. 500. connection refused.".to_string(), None));
        assert_eq!(hosted_failure_class(&ok), None);
        // An Err maps to Some(class).
        let e: Result<(String, Option<String>), ApiError> =
            Err(err(StatusCode::GATEWAY_TIMEOUT, "Jesse hit the 60s run limit."));
        assert_eq!(hosted_failure_class(&e), Some(HostedFailureClass::Timeout));
    }
}
