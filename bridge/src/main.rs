//! Jesse Bridge — a tiny HTTP server that turns "Ask Jesse" / "Tell Jesse"
//! requests from the phone into headless Claude Code (`claude -p`) runs against
//! the vault. Cowork is not scriptable; Claude Code is, and it loads the same
//! CLAUDE.md, so you get the same "Jesse" brain.
//!
//! Run:
//!     export JESSE_TOKEN="$(openssl rand -hex 24)"
//!     export JESSE_VAULT="$HOME/devel/tag1/jesse"
//!     export JESSE_BIND="$(tailscale ip -4 | head -1)"   # or 127.0.0.1 to test
//!     cargo run --release
//!
//! Security model: bind to the Tailscale interface only. The tailnet is
//! WireGuard-encrypted and ACL-gated; the bearer token is a second factor.
//! Never bind to 0.0.0.0 on an untrusted network.

use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::process::Command;
use tokio::time::timeout;

// ---- Prompt wrappers — the ONLY difference between Ask and Tell ------------
//
// "Ask" means don't take ACTION he didn't request — NOT "don't write".
// Recording a durable fact that surfaces is never an action; it's the standing
// CLAUDE.md rule and must happen in every mode, or facts surfaced mid-thread
// are lost when the session ages out (the thread is not the vault).

const ASK_PREAMBLE: &str = "Jeremy is ASKING you a question from his phone. \
Answer concisely and directly; read the vault as needed. Don't do task-work he \
didn't ask for — no new drafts, TODOs, or edits to act on something. BUT if this \
exchange surfaces a durable fact, correction, or status change, record it to the \
right vault file immediately per CLAUDE.md — that is never optional and never \
needs his permission. Keep the answer short enough to read on a phone screen.\n\n\
Question: ";

const TELL_PREAMBLE: &str = "Jeremy is TELLING you something from his phone — a \
fact, an instruction, or something to capture. Act on it per CLAUDE.md: log it, \
file it, or update the vault as appropriate. Record durable facts immediately. \
Reply with a one or two sentence confirmation of what you did.\n\nMessage: ";

// On a resumed thread the framing is already established — keep it light, but
// still require fact-capture (a followup often carries a fact, not just an
// answer to a clarifying question).
const ASK_FOLLOWUP: &str = "Jeremy follows up (still asking, keep it short; still \
record any durable fact that surfaces, per CLAUDE.md): ";

const TELL_FOLLOWUP: &str = "Jeremy follows up (capture/act per CLAUDE.md): ";

// Appended when the request arrived by voice — the reply will be read aloud, so
// we ask Jesse to end with a plain-prose SPOKEN: line the app can hand to TTS.
const VOICE_SUFFIX: &str = "\n\n(This request came in by voice and the reply will \
be read aloud. Keep it concise and listenable. After your full answer, add a final \
line beginning exactly with 'SPOKEN: ' containing a one- or two-sentence spoken \
summary for text-to-speech — plain prose, no markdown, no lists, no URLs.)";

// Appended to non-voice prompts so replies stay readable on a narrow phone
// screen. Mutually exclusive with VOICE_SUFFIX (voice forbids markdown entirely).
const PHONE_FORMAT: &str = "\n\n(Formatting: this reply is shown on a narrow phone \
screen. Prefer short paragraphs and bullet lists. Use Markdown. If a table is the \
clearest form, keep it to 2–3 narrow columns; otherwise avoid tables.)";

// ---- Config (env-driven) --------------------------------------------------

#[derive(Clone)]
struct Config {
    token: String,
    vault: String,
    bind: String,
    port: u16,
    claude_bin: String,
    timeout_secs: u64,
}

impl Config {
    fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        Config {
            token: std::env::var("JESSE_TOKEN").unwrap_or_default(),
            vault: std::env::var("JESSE_VAULT")
                .unwrap_or_else(|_| format!("{home}/devel/tag1/jesse")),
            bind: std::env::var("JESSE_BIND").unwrap_or_else(|_| "127.0.0.1".to_string()),
            port: std::env::var("JESSE_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(8765),
            claude_bin: std::env::var("JESSE_CLAUDE_BIN")
                .unwrap_or_else(|_| "claude".to_string()),
            timeout_secs: std::env::var("JESSE_TIMEOUT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(1800), // was 120; 0 = unlimited (see run_claude)
        }
    }
}

// ---- Request / response shapes --------------------------------------------

#[derive(Deserialize)]
struct JesseRequest {
    mode: String,                 // "ask" | "tell"
    text: String,
    #[serde(default)]
    session_id: Option<String>,   // set to continue a thread (a followup)
    #[serde(default)]
    voice: bool, // voice request → ask for a SPOKEN: summary line, keep it listenable
}

#[derive(Serialize)]
struct JesseResponse {
    mode: String,
    response: String,
    session_id: Option<String>,
}

type ApiError = (StatusCode, String);

// ---- Core logic -----------------------------------------------------------

fn check_auth(headers: &HeaderMap, token: &str) -> Result<(), ApiError> {
    if token.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server misconfigured: JESSE_TOKEN not set".to_string(),
        ));
    }
    let expected = format!("Bearer {token}");
    let got = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if got != expected {
        return Err((StatusCode::UNAUTHORIZED, "Unauthorized".to_string()));
    }
    Ok(())
}

fn build_prompt(mode: &str, text: &str, is_followup: bool, voice: bool) -> Result<String, ApiError> {
    let preamble = match (mode, is_followup) {
        ("ask", false) => ASK_PREAMBLE,
        ("ask", true) => ASK_FOLLOWUP,
        ("tell", false) => TELL_PREAMBLE,
        ("tell", true) => TELL_FOLLOWUP,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Unknown mode: {mode:?} (use 'ask' or 'tell')"),
            ))
        }
    };
    let mut p = format!("{preamble}{text}");
    if voice {
        p.push_str(VOICE_SUFFIX);
    } else {
        p.push_str(PHONE_FORMAT);
    }
    Ok(p)
}

/// What one `claude -p --output-format json` run amounts to — decided from its
/// output rather than its exit status alone (see `interpret_claude_output`).
#[derive(Debug)]
enum ClaudeOutcome {
    Ok {
        result: String,
        session_id: Option<String>,
    },
    /// Transient upstream failure (5xx / 429 / 529) — worth retrying.
    Retryable { message: String, status: u64 },
    /// Non-retryable failure — surface the message as-is.
    Fatal { message: String },
}

/// Truncate to `n` chars without splitting a multibyte boundary.
fn truncate_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// Interpret one `claude -p --output-format json` run. `claude` can exit
/// non-zero while still writing a JSON envelope whose `is_error` /
/// `api_error_status` carry the real cause (e.g. a transient upstream 500), so
/// parse stdout regardless of exit status and key off that — falling back to
/// exit status + stderr only when stdout isn't JSON.
fn interpret_claude_output(stdout: &str, stderr: &str, exit_success: bool) -> ClaudeOutcome {
    if let Ok(v) = serde_json::from_str::<Value>(stdout) {
        let is_error = v.get("is_error").and_then(|e| e.as_bool()).unwrap_or(false);
        if is_error {
            let status = v.get("api_error_status").and_then(|s| s.as_u64());
            // `result` holds the human-readable cause; synthesize one if absent.
            let message = v
                .get("result")
                .and_then(|r| r.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| match status {
                    Some(code) => format!("claude API error (status {code})"),
                    None => "claude reported an error with no detail".to_string(),
                });
            return match status {
                // 5xx and 429 are transient upstream conditions (529 is >= 500).
                Some(code) if code >= 500 || code == 429 => {
                    ClaudeOutcome::Retryable { message, status: code }
                }
                _ => ClaudeOutcome::Fatal { message },
            };
        }
        // Success envelope — same extraction the bridge has always done.
        let result = v
            .get("result")
            .and_then(|r| r.as_str())
            .unwrap_or(stdout)
            .trim()
            .to_string();
        let session_id = v
            .get("session_id")
            .and_then(|s| s.as_str())
            .map(|s| s.to_string());
        return ClaudeOutcome::Ok { result, session_id };
    }

    // stdout wasn't JSON. On a clean exit, treat it as the raw answer (the
    // bridge's long-standing fallback). On a failure, surface stderr AND stdout
    // so a non-JSON failure is never reported blank again.
    if exit_success {
        ClaudeOutcome::Ok {
            result: stdout.trim().to_string(),
            session_id: None,
        }
    } else {
        let err = truncate_chars(stderr.trim(), 500);
        let out = truncate_chars(stdout.trim(), 500);
        ClaudeOutcome::Fatal {
            message: format!("claude failed (no JSON envelope) — stderr: {err} | stdout: {out}"),
        }
    }
}

/// Invoke headless Claude Code in the vault. Returns (reply_text, session_id).
/// Pass session_id to continue a thread; the returned id is always captured so
/// the client can follow up later. Resuming keeps CLAUDE.md loaded and retains
/// filesystem access — it only adds the prior conversation on top.
///
/// Retries transient upstream failures (5xx/429/529) up to 3 attempts total.
/// A retry re-runs the WHOLE prompt: a transient that lands *mid-Tell* (after an
/// action was already applied) could in principle double-apply it on the rerun.
/// Accepted, because the observed transient fails at the API before any work
/// (0 tokens, $0) — there is nothing to repeat — but the tradeoff is explicit
/// here in case that ever changes. Only `Retryable` outcomes retry; spawn/io/
/// timeout failures (which happen before any output exists) do not.
async fn run_claude(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
) -> Result<(String, Option<String>), ApiError> {
    const MAX_ATTEMPTS: u32 = 3; // 1 try + 2 retries

    for attempt in 1..=MAX_ATTEMPTS {
        // Fresh Command per attempt — same args, including --resume if present.
        let mut cmd = Command::new(&cfg.claude_bin);
        cmd.arg("-p")
            .arg(prompt)
            .arg("--output-format")
            .arg("json")
            // Non-interactive: let edits/tools through without a TTY prompt.
            // PoC-only on a trusted tailnet. Tighten with --allowedTools later.
            .arg("--permission-mode")
            .arg("acceptEdits")
            .current_dir(&cfg.vault) // cwd = vault → CLAUDE.md auto-loads
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true); // killed if the timeout below fires

        if let Some(sid) = session_id {
            cmd.arg("--resume").arg(sid);
        }

        let child = cmd.spawn().map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to spawn {}: {e}", cfg.claude_bin),
            )
        })?;

        let output = if cfg.timeout_secs == 0 {
            // Unlimited: some agent runs legitimately exceed any fixed cap.
            // kill_on_drop still reaps the child if this future is dropped.
            match child.wait_with_output().await {
                Ok(o) => o,
                Err(e) => return Err((StatusCode::BAD_GATEWAY, format!("claude io error: {e}"))),
            }
        } else {
            match timeout(Duration::from_secs(cfg.timeout_secs), child.wait_with_output()).await {
                Ok(Ok(o)) => o,
                Ok(Err(e)) => {
                    return Err((StatusCode::BAD_GATEWAY, format!("claude io error: {e}")))
                }
                Err(_) => {
                    return Err((
                        StatusCode::GATEWAY_TIMEOUT,
                        format!("Jesse timed out after {}s", cfg.timeout_secs),
                    ))
                }
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        match interpret_claude_output(&stdout, &stderr, output.status.success()) {
            ClaudeOutcome::Ok { result, session_id } => return Ok((result, session_id)),
            ClaudeOutcome::Fatal { message } => return Err((StatusCode::BAD_GATEWAY, message)),
            ClaudeOutcome::Retryable { message, status } => {
                if attempt < MAX_ATTEMPTS {
                    eprintln!(
                        "claude transient failure (status {status}, attempt \
                         {attempt}/{MAX_ATTEMPTS}): {message} — retrying"
                    );
                    // Short linear backoff: 1s after attempt 1, 2s after attempt 2.
                    tokio::time::sleep(Duration::from_secs(attempt as u64)).await;
                    continue;
                }
                // Out of attempts — surface the real upstream message.
                return Err((StatusCode::BAD_GATEWAY, message));
            }
        }
    }

    // The loop returns on the last attempt regardless of outcome.
    unreachable!("run_claude exhausted its loop without returning")
}

// ---- Handlers -------------------------------------------------------------

async fn health(State(cfg): State<Arc<Config>>) -> Json<Value> {
    Json(json!({ "ok": true, "vault": cfg.vault, "claude": cfg.claude_bin }))
}

async fn jesse(
    State(cfg): State<Arc<Config>>,
    headers: HeaderMap,
    Json(req): Json<JesseRequest>,
) -> Result<Json<JesseResponse>, ApiError> {
    check_auth(&headers, &cfg.token)?;
    let mode = req.mode.trim().to_lowercase();
    let is_followup = req.session_id.is_some();
    let prompt = build_prompt(&mode, &req.text, is_followup, req.voice)?;
    let (response, session_id) = run_claude(&cfg, &prompt, req.session_id.as_deref()).await?;
    Ok(Json(JesseResponse {
        mode: req.mode,
        response,
        session_id,
    }))
}

// ---- Startup --------------------------------------------------------------

/// Percent-encode a query-parameter value, keeping only RFC 3986 unreserved
/// characters literal. Host/port/token are simple today, but encoding keeps the
/// payload well-formed for whatever a future advertise-host might contain.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build the `jesse://pair?…` payload the app scans. MUST match the app's
/// `JesseConfig.fromPairing` parser exactly.
fn pairing_payload(host: &str, port: u16, token: &str) -> String {
    format!(
        "jesse://pair?host={}&port={}&token={}",
        percent_encode(host),
        port,
        percent_encode(token)
    )
}

fn binary_exists(bin: &str) -> bool {
    let p = Path::new(bin);
    if p.is_absolute() || bin.contains('/') {
        return p.is_file();
    }
    if let Ok(path) = std::env::var("PATH") {
        return path.split(':').any(|dir| Path::new(dir).join(bin).is_file());
    }
    false
}

/// Build the axum router with its shared state. Kept separate from `main` so
/// tests can drive the same routes via `tower::ServiceExt::oneshot` without
/// binding a socket. The running server uses exactly this router.
fn app(state: Arc<Config>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/jesse", post(jesse))
        .with_state(state)
}

#[tokio::main]
async fn main() {
    let cfg = Config::from_env();

    if cfg.token.is_empty() {
        eprintln!("JESSE_TOKEN is not set — refusing to start.");
        std::process::exit(1);
    }
    if !Path::new(&cfg.vault).is_dir() {
        eprintln!("Vault not found: {} — set JESSE_VAULT.", cfg.vault);
        std::process::exit(1);
    }
    if !binary_exists(&cfg.claude_bin) {
        eprintln!(
            "claude binary not found: {} — set JESSE_CLAUDE_BIN.",
            cfg.claude_bin
        );
        std::process::exit(1);
    }

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let state = Arc::new(cfg);

    // Pairing QR — scan it from the app's Settings to fill in host/port/token.
    // The advertised host defaults to the bound IP (reliably reachable on the
    // tailnet; the ts.net name has DNS quirks per STATUS.md). Override with
    // JESSE_ADVERTISE_HOST to force the MagicDNS name into the QR instead.
    let advertise_host =
        std::env::var("JESSE_ADVERTISE_HOST").unwrap_or_else(|_| state.bind.clone());
    let payload = pairing_payload(&advertise_host, state.port, &state.token);
    let code = qrcode::QrCode::new(payload.as_bytes()).expect("qr encode");
    let art = code
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .build();
    println!("{art}");
    println!("Pair by scanning the QR above, or enter manually:");
    println!(
        "  host={advertise_host}  port={}  token={}",
        state.port, state.token
    );

    println!("Jesse Bridge → http://{addr}  (vault: {})", state.vault);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    axum::serve(listener, app(state)).await.expect("server error");
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use std::sync::Mutex;
    use tower::ServiceExt; // for `oneshot`

    // Several tests mutate process-global env (PATH) or read defaults from it.
    // The default test runner is multi-threaded, so serialize those behind a
    // lock to keep them from racing each other.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn header_map(auth: Option<&str>) -> HeaderMap {
        let mut h = HeaderMap::new();
        if let Some(v) = auth {
            h.insert("authorization", v.parse().unwrap());
        }
        h
    }

    // ---- check_auth -------------------------------------------------------

    #[test]
    fn check_auth_empty_token_is_500() {
        let err = check_auth(&header_map(Some("Bearer anything")), "").unwrap_err();
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[test]
    fn check_auth_matching_bearer_ok() {
        assert!(check_auth(&header_map(Some("Bearer s3cret")), "s3cret").is_ok());
    }

    #[test]
    fn check_auth_wrong_token_is_401() {
        let err = check_auth(&header_map(Some("Bearer nope")), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn check_auth_missing_header_is_401() {
        let err = check_auth(&header_map(None), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn check_auth_token_without_bearer_prefix_is_401() {
        // Correct token value but no "Bearer " prefix → still rejected.
        let err = check_auth(&header_map(Some("s3cret")), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }

    // ---- build_prompt -----------------------------------------------------

    #[test]
    fn build_prompt_ask_fresh_wraps_with_ask_preamble() {
        let p = build_prompt("ask", "what is on Today.md", false, false).unwrap();
        assert!(p.starts_with(ASK_PREAMBLE));
        assert!(p.contains("what is on Today.md"));
        // Non-voice replies get the phone-formatting hint, not the voice suffix.
        assert!(p.ends_with(PHONE_FORMAT));
        assert!(!p.contains(VOICE_SUFFIX));
    }

    #[test]
    fn build_prompt_ask_followup_uses_followup_preamble() {
        let p = build_prompt("ask", "and the second?", true, false).unwrap();
        assert!(p.starts_with(ASK_FOLLOWUP));
        assert!(p.contains("and the second?"));
        assert!(p.ends_with(PHONE_FORMAT));
    }

    #[test]
    fn build_prompt_tell_fresh_and_followup() {
        let fresh = build_prompt("tell", "remember this", false, false).unwrap();
        assert!(fresh.starts_with(TELL_PREAMBLE));
        assert!(fresh.contains("remember this"));
        assert!(fresh.ends_with(PHONE_FORMAT));
        let followup = build_prompt("tell", "also this", true, false).unwrap();
        assert!(followup.starts_with(TELL_FOLLOWUP));
        assert!(followup.ends_with(PHONE_FORMAT));
    }

    #[test]
    fn build_prompt_unknown_mode_is_400() {
        let err = build_prompt("shout", "hey", false, false).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }

    #[test]
    fn build_prompt_voice_appends_suffix() {
        let with_voice = build_prompt("ask", "q", false, true).unwrap();
        assert!(with_voice.ends_with(VOICE_SUFFIX));
        // Voice and phone formatting are mutually exclusive.
        assert!(!with_voice.contains(PHONE_FORMAT));
        let without = build_prompt("ask", "q", false, false).unwrap();
        assert!(!without.contains(VOICE_SUFFIX));
    }

    // ---- interpret_claude_output ------------------------------------------

    #[test]
    fn interpret_real_500_envelope_is_retryable() {
        // The observed cold-start failure: non-zero exit, real cause in stdout.
        let stdout = r#"{"type":"result","is_error":true,"api_error_status":500,"result":"API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment.","session_id":"sess-x"}"#;
        match interpret_claude_output(stdout, "", false) {
            ClaudeOutcome::Retryable { status, message } => {
                assert_eq!(status, 500);
                assert!(message.contains("500"));
            }
            other => panic!("expected Retryable, got {other:?}"),
        }
    }

    #[test]
    fn interpret_400_envelope_is_fatal() {
        let stdout = r#"{"is_error":true,"api_error_status":400,"result":"bad request"}"#;
        match interpret_claude_output(stdout, "", false) {
            ClaudeOutcome::Fatal { message } => assert!(message.contains("bad request")),
            other => panic!("expected Fatal, got {other:?}"),
        }
    }

    #[test]
    fn interpret_success_envelope_is_ok() {
        let stdout = r#"{"type":"result","is_error":false,"result":"OK","session_id":"sess-1"}"#;
        match interpret_claude_output(stdout, "", true) {
            ClaudeOutcome::Ok { result, session_id } => {
                assert_eq!(result, "OK");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
            }
            other => panic!("expected Ok, got {other:?}"),
        }
    }

    #[test]
    fn interpret_non_json_success_is_raw_ok() {
        match interpret_claude_output("  just plain text  ", "", true) {
            ClaudeOutcome::Ok { result, session_id } => {
                assert_eq!(result, "just plain text");
                assert!(session_id.is_none());
            }
            other => panic!("expected Ok, got {other:?}"),
        }
    }

    #[test]
    fn interpret_non_json_failure_is_fatal_and_nonblank() {
        // The old bug: a non-JSON failure reported nothing. Now both streams show.
        match interpret_claude_output("partial stdout", "stderr detail", false) {
            ClaudeOutcome::Fatal { message } => {
                assert!(!message.is_empty());
                assert!(message.contains("stderr detail"));
                assert!(message.contains("partial stdout"));
            }
            other => panic!("expected Fatal, got {other:?}"),
        }
    }

    // ---- binary_exists ----------------------------------------------------

    #[test]
    fn binary_exists_absolute_path() {
        assert!(binary_exists("/bin/sh"));
        assert!(!binary_exists("/no/such/bin"));
    }

    #[test]
    fn binary_exists_searches_path() {
        let _guard = ENV_LOCK.lock().unwrap();
        let saved = std::env::var("PATH").ok();
        std::env::set_var("PATH", "/bin");
        assert!(binary_exists("sh"));
        match saved {
            Some(p) => std::env::set_var("PATH", p),
            None => std::env::remove_var("PATH"),
        }
    }

    // ---- pairing payload --------------------------------------------------

    #[test]
    fn pairing_payload_matches_app_format() {
        let p = pairing_payload("100.64.0.1", 8765, "deadbeef");
        assert_eq!(p, "jesse://pair?host=100.64.0.1&port=8765&token=deadbeef");
    }

    #[test]
    fn pairing_payload_percent_encodes_reserved() {
        // A host with a reserved char must be escaped, not left raw.
        let p = pairing_payload("a b/c", 80, "t&k");
        assert!(p.contains("host=a%20b%2Fc"));
        assert!(p.contains("token=t%26k"));
    }

    // ---- Config::from_env -------------------------------------------------

    #[test]
    fn config_from_env_defaults() {
        let _guard = ENV_LOCK.lock().unwrap();
        let saved: Vec<(&str, Option<String>)> = [
            "JESSE_TOKEN",
            "JESSE_VAULT",
            "JESSE_BIND",
            "JESSE_PORT",
            "JESSE_CLAUDE_BIN",
            "JESSE_TIMEOUT",
        ]
        .iter()
        .map(|k| (*k, std::env::var(k).ok()))
        .collect();
        for (k, _) in &saved {
            std::env::remove_var(k);
        }

        let cfg = Config::from_env();
        assert_eq!(cfg.token, "");
        assert_eq!(cfg.bind, "127.0.0.1");
        assert_eq!(cfg.port, 8765);
        assert_eq!(cfg.claude_bin, "claude");
        assert_eq!(cfg.timeout_secs, 1800);

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    // ---- integration via app() router ------------------------------------

    fn test_config() -> Arc<Config> {
        Arc::new(Config {
            token: "test-token".to_string(),
            // Any existing directory works — these tests never reach run_claude.
            vault: std::env::temp_dir().to_string_lossy().into_owned(),
            bind: "127.0.0.1".to_string(),
            port: 8765,
            claude_bin: "claude".to_string(),
            timeout_secs: 1800,
        })
    }

    async fn body_string(resp: axum::response::Response) -> String {
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    #[tokio::test]
    async fn health_returns_config() {
        let cfg = test_config();
        let resp = app(cfg.clone())
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_string(resp).await;
        assert!(body.contains(&cfg.vault));
        assert!(body.contains(&cfg.claude_bin));
    }

    fn jesse_request(auth: Option<&str>, json: &str) -> Request<Body> {
        let mut b = Request::builder()
            .method("POST")
            .uri("/jesse")
            .header("content-type", "application/json");
        if let Some(a) = auth {
            b = b.header("authorization", a);
        }
        b.body(Body::from(json.to_string())).unwrap()
    }

    #[tokio::test]
    async fn jesse_no_auth_is_401() {
        let resp = app(test_config())
            .oneshot(jesse_request(None, r#"{"mode":"ask","text":"hi"}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn jesse_wrong_token_is_401() {
        let resp = app(test_config())
            .oneshot(jesse_request(
                Some("Bearer wrong"),
                r#"{"mode":"ask","text":"hi"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn jesse_bad_mode_is_400() {
        // Correct token, but build_prompt rejects the mode before run_claude.
        let resp = app(test_config())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"shout","text":"hi"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}
