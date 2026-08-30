//! **Provider configuration** — plain values, constructed by the caller.
//!
//! NOTHING IN THIS CRATE READS THE ENVIRONMENT. Not here, not in the adapters, not in
//! [`super::http`]. The caller resolves `JESSE_*` (or a TOML block, or a test literal)
//! and hands the resolved values in. That is a decision with two reasons behind it:
//!
//!   * The bridge already owns environment resolution, with a startup gate that REFUSES
//!     certain variables and a containment record that pins others. A library reaching
//!     round that to read `std::env` itself would be a second, unaudited source of
//!     configuration for the same process — the exact shape the gate exists to prevent.
//!   * A crate that reads the environment cannot be tested against two differently
//!     configured providers in one process, which is what the conformance suite does on
//!     every case.
//!
//! The live smoke (`examples/smoke.rs`) reads env vars because it is a BINARY, not the
//! library — it resolves, then constructs, like any other caller.

use std::fmt;
use std::time::Duration;

use super::Wire;

/// How the call authenticates.
///
/// BOTH SCHEMES EXIST IN THE WILD ON THE SAME WIRE, which is why this is a choice rather
/// than a per-wire constant. Anthropic's own documented header is `x-api-key`, but the
/// Anthropic-shaped gateways this repository already talks to (`bridge/src/health.rs` and
/// `bridge/src/vision.rs` both send `authorization: Bearer …` to theirs) take a bearer
/// and ignore `x-api-key`. Hard-coding either one breaks half the deployments.
#[derive(Clone, PartialEq, Eq)]
pub enum AuthScheme {
    /// `authorization: Bearer <token>`.
    Bearer(String),
    /// `x-api-key: <token>` — Anthropic's own documented scheme.
    XApiKey(String),
    /// No auth header. For a loopback mock or a local server that wants none; a real
    /// endpoint answering `401` is [`super::ProviderError::Auth`], not a panic here.
    None,
}

impl AuthScheme {
    /// The scheme to use for `base_url` when the caller has no opinion.
    ///
    /// `x-api-key` for `api.anthropic.com` (their documented scheme), bearer everywhere
    /// else (what every gateway in this repository's deployment actually accepts). The
    /// host test is on the HOST, not a substring of the whole URL, so a gateway at
    /// `https://gw.example/proxy/api.anthropic.com` is not mistaken for the real thing.
    ///
    /// Always overridable — that is the point of it being a resolved value the caller
    /// passes in rather than something an adapter decides at call time.
    pub fn default_for(base_url: &str, token: impl Into<String>) -> Self {
        if host_of(base_url).as_deref() == Some("api.anthropic.com") {
            AuthScheme::XApiKey(token.into())
        } else {
            AuthScheme::Bearer(token.into())
        }
    }

    /// The header this scheme sets, as `(name, value)`. `None` for [`AuthScheme::None`].
    pub(crate) fn header(&self) -> Option<(&'static str, String)> {
        match self {
            AuthScheme::Bearer(t) => Some(("authorization", format!("Bearer {t}"))),
            AuthScheme::XApiKey(t) => Some(("x-api-key", t.clone())),
            AuthScheme::None => None,
        }
    }
}

/// Hand-written so a token CANNOT reach a log through a derived `Debug`.
///
/// This is not belt-and-braces. `ProviderConfig` is exactly the kind of struct that ends
/// up in an `eprintln!("{cfg:?}")` while someone debugs a 401, and a derived `Debug` here
/// would print the key at the moment a human is most likely to paste the output
/// somewhere. The variant name is kept because knowing WHICH scheme was tried is the
/// whole diagnostic value; the secret is not.
impl fmt::Debug for AuthScheme {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AuthScheme::Bearer(_) => f.write_str("Bearer(<redacted>)"),
            AuthScheme::XApiKey(_) => f.write_str("XApiKey(<redacted>)"),
            AuthScheme::None => f.write_str("None"),
        }
    }
}

/// Connect and overall budgets for one call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timeouts {
    /// TCP + TLS establishment.
    pub connect: Duration,
    /// The budget for getting RESPONSE HEADERS back — deliberately NOT a cap on the
    /// streamed body.
    ///
    /// This is the divergence from `bridge/src/vision.rs` and `bridge/src/health.rs`,
    /// which both pass `.timeout(…)` to `reqwest` and so bound the whole call. That is
    /// right for what they do: a probe and a one-shot transcription are both short, and a
    /// hung one should die. It is wrong here. An agent turn legitimately streams for
    /// minutes while the model thinks and calls tools, and a whole-call timeout would
    /// kill the longest and most valuable turns — with a `Timeout` that the retry policy
    /// would then cheerfully retry, paying for the whole thing twice.
    ///
    /// So the budget covers the phase that genuinely should be fast (connect, send,
    /// first byte of the response head) and the streaming phase is bounded by
    /// cancellation instead, which is the caller's to decide and is already a parameter
    /// of every call. A stalled mid-stream connection is therefore D2's problem, and
    /// deliberately so.
    pub overall: Duration,
}

impl Default for Timeouts {
    fn default() -> Self {
        Timeouts {
            connect: Duration::from_secs(10),
            // Generous: this covers a cold gateway and a long prefill, both of which are
            // real on the hosts here — a ~31.8k-token prompt has been measured at ~70s of
            // prefill on a local gateway before a single byte comes back.
            overall: Duration::from_secs(120),
        }
    }
}

/// The retry policy's numbers. The policy itself — which classes retry, and the rule that
/// a retry may only happen before the caller has seen an event — is in [`super::http`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retries {
    /// TOTAL attempts, not retries-after-the-first. `1` disables retrying.
    pub max_attempts: u32,
    /// First backoff step; doubles per attempt, capped at `max_backoff`, then jittered.
    pub base_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for Retries {
    fn default() -> Self {
        Retries {
            max_attempts: 3,
            base_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(20),
        }
    }
}

/// PER-HOST TOGGLES. Each one exists because a specific host rejected the thing it
/// controls; each is documented with that host, because a quirk whose motivation is lost
/// is a quirk nobody dares delete.
///
/// These are all NEGATIVE capabilities — "this host does not accept the extra field" —
/// and they are configuration rather than probes because there is no way to ask. A host
/// that rejects an unknown field answers `400` with prose, and discovering that at call
/// time means the first real turn of every new deployment fails.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Quirks {
    /// Send `reasoning_effort` on the Chat wire when [`super::Thinking`] is not `Off`.
    ///
    /// MOTIVATING HOST: `api.fireworks.ai`. It serves OpenAI-shaped chat for models that
    /// have no reasoning-effort concept and rejects the unknown field, so a request that
    /// merely asked for thinking would fail outright rather than degrade. Default ON for
    /// `api.openai.com`, OFF everywhere else; when off, the level is dropped and one note
    /// is logged so a caller who asked for thinking and did not get it can find out why.
    pub reasoning_effort_supported: bool,

    /// Emit the system prefix as SEVERAL leading `system` messages instead of one
    /// concatenated message on the Chat wire.
    ///
    /// MOTIVATING HOST: OpenAI-shaped servers that accept only one system message —
    /// vLLM-style local servers and several of the Fireworks-hosted OSS chat templates,
    /// which either error or silently drop all but the first. Concatenation is accepted
    /// by every host tested including `api.openai.com`, so the DEFAULT IS OFF EVERYWHERE
    /// — including OpenAI's own endpoint, deliberately: a default that is correct on one
    /// host and broken on three is not a default, it is a trap for whoever deploys the
    /// fourth. The toggle exists so a host that benefits from separate blocks (finer
    /// cache granularity, if a Chat-wire host ever offers it) can have them.
    pub multiple_system_messages: bool,

    /// Pass a tool's [`super::ToolSpec::strict`] flag through to the wire.
    ///
    /// MOTIVATING HOST: `api.fireworks.ai` again, and local OpenAI-shaped servers.
    /// `strict` is an OpenAI structured-outputs feature; hosts that merely imitate the
    /// chat schema reject `function.strict` as an unknown field. Default ON for
    /// `api.openai.com`, OFF elsewhere. When off, `strict` is dropped with one logged
    /// note — never silently, because a caller that set it believed the arguments would
    /// be schema-constrained.
    pub strict_tools_supported: bool,
}

impl Default for Quirks {
    /// The CONSERVATIVE posture: assume the host accepts nothing beyond the common
    /// schema. Chosen over defaulting to OpenAI's full feature set because the failure
    /// modes are not symmetric — an unsent optional field costs a little quality on a
    /// host that would have taken it, while an unaccepted field costs the entire call on
    /// a host that will not.
    fn default() -> Self {
        Quirks {
            reasoning_effort_supported: false,
            multiple_system_messages: false,
            strict_tools_supported: false,
        }
    }
}

impl Quirks {
    /// The toggles for `base_url` when the caller has no opinion: OpenAI's own endpoint
    /// gets the two features it defines, everything else gets [`Quirks::default`].
    pub fn default_for(base_url: &str) -> Self {
        if host_of(base_url).as_deref() == Some("api.openai.com") {
            Quirks {
                reasoning_effort_supported: true,
                multiple_system_messages: false,
                strict_tools_supported: true,
            }
        } else {
            Quirks::default()
        }
    }
}

/// Everything one provider needs, resolved.
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    pub wire: Wire,
    /// The API root. Trailing slashes are tolerated; the adapter appends its own path
    /// (`/v1/messages`, `/chat/completions`).
    pub base_url: String,
    pub auth: AuthScheme,
    pub model: String,
    pub timeouts: Timeouts,
    pub retries: Retries,
    /// Extra headers sent verbatim on every request — a gateway's routing header, an
    /// org id, a beta opt-in. Never inspected by the adapter.
    pub extra_headers: Vec<(String, String)>,
    pub quirks: Quirks,
    /// The model's context window, surfaced as [`super::Capabilities::max_context_tokens`].
    /// Configuration-only: neither wire reports it.
    pub max_context_tokens: Option<u32>,
}

impl ProviderConfig {
    /// A configuration with per-host defaults for [`Quirks`] and the standard timeouts
    /// and retries. The auth scheme is explicit — see [`AuthScheme::default_for`] for the
    /// per-host default when the caller has no opinion there either.
    pub fn new(
        wire: Wire,
        base_url: impl Into<String>,
        model: impl Into<String>,
        auth: AuthScheme,
    ) -> Self {
        let base_url = base_url.into();
        let quirks = Quirks::default_for(&base_url);
        ProviderConfig {
            wire,
            base_url,
            auth,
            model: model.into(),
            timeouts: Timeouts::default(),
            retries: Retries::default(),
            extra_headers: Vec::new(),
            quirks,
            max_context_tokens: None,
        }
    }

    /// `base_url` with any trailing slashes removed, so joining a leading-slash path
    /// cannot produce `//`. Mirrors the bridge's own `join_url` behaviour.
    pub(crate) fn endpoint(&self, path: &str) -> String {
        format!("{}{}", self.base_url.trim_end_matches('/'), path)
    }
}

/// The host component of a URL, lowercased, without port or userinfo.
///
/// Hand-rolled rather than pulling `url`: this needs the host and nothing else, and the
/// two call sites both compare it against a literal. Returns `None` for anything that
/// does not look like `scheme://host…`, which makes an unparseable URL fall through to
/// the conservative default rather than matching a well-known host by accident.
fn host_of(url: &str) -> Option<String> {
    let after_scheme = url.split_once("://")?.1;
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .filter(|s| !s.is_empty())?;
    // Strip userinfo (`user:pass@host`) — take what follows the LAST '@'.
    let hostport = authority.rsplit('@').next()?;
    // Strip the port. Bracketed IPv6 literals keep their brackets, which is fine: they
    // will never equal one of the two literal hosts this is compared against.
    let host = if let Some(rest) = hostport.strip_prefix('[') {
        rest.split_once(']').map(|(h, _)| h)?
    } else {
        hostport.split(':').next()?
    };
    Some(host.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_parsing_is_on_the_host_not_the_whole_url() {
        assert_eq!(
            host_of("https://api.openai.com/v1").as_deref(),
            Some("api.openai.com")
        );
        assert_eq!(
            host_of("https://API.OpenAI.com").as_deref(),
            Some("api.openai.com")
        );
        assert_eq!(
            host_of("https://api.openai.com:443/v1").as_deref(),
            Some("api.openai.com")
        );
        assert_eq!(
            host_of("http://127.0.0.1:8080/v1").as_deref(),
            Some("127.0.0.1")
        );
        // A path that merely CONTAINS a well-known host is not that host.
        assert_eq!(
            host_of("https://gw.example/proxy/api.anthropic.com").as_deref(),
            Some("gw.example")
        );
        assert_eq!(host_of("not a url"), None);
    }

    #[test]
    fn auth_defaults_to_x_api_key_only_on_anthropics_own_host() {
        assert!(matches!(
            AuthScheme::default_for("https://api.anthropic.com", "t"),
            AuthScheme::XApiKey(_)
        ));
        assert!(matches!(
            AuthScheme::default_for("https://gateway.example/anthropic", "t"),
            AuthScheme::Bearer(_)
        ));
    }

    #[test]
    fn quirks_default_to_the_conservative_posture_off_openai() {
        let openai = Quirks::default_for("https://api.openai.com/v1");
        assert!(openai.reasoning_effort_supported);
        assert!(openai.strict_tools_supported);
        // Even on OpenAI, the system prefix is concatenated — see the field's doc.
        assert!(!openai.multiple_system_messages);

        let fw = Quirks::default_for("https://api.fireworks.ai/inference/v1");
        assert!(!fw.reasoning_effort_supported);
        assert!(!fw.strict_tools_supported);
        assert!(!fw.multiple_system_messages);
    }

    #[test]
    fn debug_never_prints_a_token() {
        let cfg = ProviderConfig::new(
            Wire::Messages,
            "https://api.anthropic.com",
            "m",
            AuthScheme::XApiKey("SUPER-SECRET-VALUE".into()),
        );
        let printed = format!("{cfg:?}");
        assert!(
            !printed.contains("SUPER-SECRET-VALUE"),
            "a token reached Debug output: {printed}"
        );
        assert!(printed.contains("XApiKey(<redacted>)"));
    }

    #[test]
    fn endpoint_joining_tolerates_a_trailing_slash() {
        let mut cfg = ProviderConfig::new(Wire::Chat, "http://h/v1/", "m", AuthScheme::None);
        assert_eq!(
            cfg.endpoint("/chat/completions"),
            "http://h/v1/chat/completions"
        );
        cfg.base_url = "http://h/v1".into();
        assert_eq!(
            cfg.endpoint("/chat/completions"),
            "http://h/v1/chat/completions"
        );
    }
}
