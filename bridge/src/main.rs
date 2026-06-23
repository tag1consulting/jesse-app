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
    }
    Ok(p)
}

/// Invoke headless Claude Code in the vault. Returns (reply_text, session_id).
/// Pass session_id to continue a thread; the returned id is always captured so
/// the client can follow up later. Resuming keeps CLAUDE.md loaded and retains
/// filesystem access — it only adds the prior conversation on top.
async fn run_claude(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
) -> Result<(String, Option<String>), ApiError> {
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
            Ok(Err(e)) => return Err((StatusCode::BAD_GATEWAY, format!("claude io error: {e}"))),
            Err(_) => {
                return Err((
                    StatusCode::GATEWAY_TIMEOUT,
                    format!("Jesse timed out after {}s", cfg.timeout_secs),
                ))
            }
        }
    };

    if !output.status.success() {
        let err: String = String::from_utf8_lossy(&output.stderr)
            .chars()
            .take(500)
            .collect();
        return Err((StatusCode::BAD_GATEWAY, format!("claude failed: {err}")));
    }

    // `--output-format json` returns a JSON envelope with `result` + `session_id`.
    let out = String::from_utf8_lossy(&output.stdout);
    match serde_json::from_str::<Value>(&out) {
        Ok(v) => {
            let result = v
                .get("result")
                .and_then(|r| r.as_str())
                .unwrap_or(&out)
                .trim()
                .to_string();
            let sid = v
                .get("session_id")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());
            Ok((result, sid))
        }
        Err(_) => Ok((out.trim().to_string(), None)),
    }
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

    let app = Router::new()
        .route("/health", get(health))
        .route("/jesse", post(jesse))
        .with_state(state.clone());

    println!("Jesse Bridge → http://{addr}  (vault: {})", state.vault);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    axum::serve(listener, app).await.expect("server error");
}
