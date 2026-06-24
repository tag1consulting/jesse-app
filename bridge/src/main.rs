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
//! Security model: bind to loopback or the Tailscale/CGNAT interface only. The
//! tailnet is WireGuard-encrypted and ACL-gated; the bearer token is a second
//! factor. The headless agent runs under an explicit tool allowlist (see
//! `build_claude_args`); that allowlist is the only in-process boundary — real
//! isolation (dedicated low-privilege user, OS sandbox) is a deployment concern
//! documented in SECURITY.md.

use std::collections::HashMap;
use std::hash::BuildHasher;
use std::io::Write as _;
use std::net::IpAddr;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::{
    extract::{DefaultBodyLimit, Path as UrlPath, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::process::Command;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
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

// Hard upper bound on any single turn, regardless of JESSE_TIMEOUT. A request
// cannot pin a `claude` child (and a concurrency permit) for longer than this.
const HARD_TIMEOUT_CEILING: u64 = 3600;

// Captured agent stdout is truncated to this many bytes before parsing so one
// pathological run can't balloon the bridge's memory. The JSON envelope the
// bridge cares about is kilobytes; multiple MB is already pathological.
const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

// ---- Attachment caps (env-overridable defaults) ---------------------------
//
// Attachments are decoded from base64 in the request body, validated by
// magic-byte sniff against a MIME whitelist, written to a per-request scratch
// dir the headless agent reads, then deleted when the turn ends. These cap the
// new file-input attack surface; keep them in sync with SECURITY.md.

// Max attachments accepted on a single turn.
const DEFAULT_MAX_ATTACHMENTS: usize = 4;
// Max decoded size of any one attachment.
const DEFAULT_MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
// Max decoded size of all attachments on a turn combined.
const DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES: usize = 20 * 1024 * 1024;

// Least-privilege default tool allowlist for the headless agent. Scoped to what
// the vault's Ask/Tell workflows actually need: file read/write/search, the
// read-only QMD vault-search MCP tools, and a few scoped shell verbs (git for
// vault history, mv/ls/cat/find for file wrangling). Bare `Bash` is deliberately
// absent — only the `Bash(<verb>:*)` scopes below are allowed. Override with
// JESSE_ALLOWED_TOOLS. Keep in sync with the table in SECURITY.md.
const DEFAULT_ALLOWED_TOOLS: &str = "Read,Write,Edit,Grep,Glob,\
mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status,\
Bash(git:*),Bash(mv:*),Bash(ls:*),Bash(cat:*),Bash(find:*)";

// Defense-in-depth: tools that must never run from the bridge even if they slip
// into the allowlist. Unscoped Bash (arbitrary shell) and WebFetch (SSRF / data
// exfiltration surface the Ask/Tell workflows don't need). Override with
// JESSE_DISALLOWED_TOOLS.
const DEFAULT_DISALLOWED_TOOLS: &str = "Bash,WebFetch";

#[derive(Clone)]
struct Config {
    token: String,
    vault: String,
    bind: String,
    port: u16,
    claude_bin: String,
    timeout_secs: u64,
    // Comma-separated tool allowlist passed to `claude --allowedTools`.
    allowed_tools: String,
    // Comma-separated tool denylist passed to `claude --disallowedTools`.
    disallowed_tools: String,
    // Max concurrent turns. A request that can't get a permit immediately is
    // rejected with 429 rather than queued unboundedly.
    max_concurrency: usize,
    // Per-service rate ceiling (requests accepted per rolling minute). Bursts
    // beyond this are rejected with 429.
    rate_per_min: u32,
    // How long POST /jesse holds the connection waiting for the turn before it
    // returns 202 and lets the client poll. A few seconds catches fast turns
    // inline; everything longer is resolved via GET /jesse/result/{job_id}.
    grace_secs: u64,
    // How long a completed/failed job stays retrievable before TTL eviction.
    job_ttl_secs: u64,
    // Attachment caps (see the DEFAULT_MAX_ATTACHMENT* consts). Decoded sizes.
    max_attachments: usize,
    max_attachment_bytes: usize,
    max_attachments_total_bytes: usize,
}

/// Clamp a requested per-turn timeout into a sane, bounded range. `0` is treated
/// as "use the ceiling" rather than "unlimited" so no request can pin a child
/// forever; any value is capped at `HARD_TIMEOUT_CEILING` and floored at 1s.
/// The only "unlimited" affordance lives in `run_claude` behind
/// `#[cfg(debug_assertions)]` and is never reachable in a release build.
fn clamp_timeout_secs(raw: u64) -> u64 {
    if raw == 0 {
        return HARD_TIMEOUT_CEILING;
    }
    raw.clamp(1, HARD_TIMEOUT_CEILING)
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
            timeout_secs: clamp_timeout_secs(
                std::env::var("JESSE_TIMEOUT")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1800),
            ),
            allowed_tools: std::env::var("JESSE_ALLOWED_TOOLS")
                .ok()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| DEFAULT_ALLOWED_TOOLS.to_string()),
            disallowed_tools: std::env::var("JESSE_DISALLOWED_TOOLS")
                .ok()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| DEFAULT_DISALLOWED_TOOLS.to_string()),
            max_concurrency: std::env::var("JESSE_MAX_CONCURRENCY")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(2),
            rate_per_min: std::env::var("JESSE_RATE_PER_MIN")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(30),
            grace_secs: std::env::var("JESSE_GRACE_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(10),
            job_ttl_secs: std::env::var("JESSE_JOB_TTL_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(600), // 10 min
            max_attachments: std::env::var("JESSE_MAX_ATTACHMENTS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(DEFAULT_MAX_ATTACHMENTS),
            max_attachment_bytes: std::env::var("JESSE_MAX_ATTACHMENT_BYTES")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(DEFAULT_MAX_ATTACHMENT_BYTES),
            max_attachments_total_bytes: std::env::var("JESSE_MAX_ATTACHMENTS_TOTAL_BYTES")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES),
        }
    }
}

// ---- Bind safety (C2) -----------------------------------------------------

/// Whether the bridge may bind `addr` (the host portion, e.g. "127.0.0.1").
/// True only for loopback (127.0.0.0/8, ::1) or CGNAT/tailnet space
/// (100.64.0.0/10) — the interfaces the security model assumes — unless
/// `allow_public` is set, which permits any address. A value that doesn't parse
/// as an IP (e.g. a hostname) is treated as non-loopback/non-CGNAT and refused
/// unless overridden, since we can't prove it's private.
fn is_bind_allowed(addr: &str, allow_public: bool) -> bool {
    if allow_public {
        return true;
    }
    match addr.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => {
            // Loopback 127.0.0.0/8, or CGNAT 100.64.0.0/10.
            v4.is_loopback() || (v4.octets()[0] == 100 && (64..=127).contains(&v4.octets()[1]))
        }
        Ok(IpAddr::V6(v6)) => v6.is_loopback(),
        Err(_) => false,
    }
}

/// Parse a truthy env flag (1/true/yes/on, case-insensitive).
fn env_truthy(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            v == "1" || v == "true" || v == "yes" || v == "on"
        })
        .unwrap_or(false)
}

// ---- Rate limit (C3) ------------------------------------------------------
//
// A single-token bridge needs only one bucket. A classic token bucket: capacity
// == refill == `rate_per_min` tokens, refilled continuously over a 60s window.
// One Mutex around two small numbers — lock-light, no background task.

struct RateLimiter {
    capacity: f64,
    // Tokens added per second (capacity / 60).
    refill_per_sec: f64,
    inner: Mutex<RateState>,
}

struct RateState {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    fn new(per_min: u32) -> Self {
        let capacity = per_min.max(1) as f64;
        RateLimiter {
            capacity,
            refill_per_sec: capacity / 60.0,
            inner: Mutex::new(RateState {
                tokens: capacity,
                last: Instant::now(),
            }),
        }
    }

    /// Try to consume one token. Returns true if allowed, false if the caller
    /// should be rejected with 429.
    fn allow(&self) -> bool {
        let now = Instant::now();
        let mut s = self.inner.lock().unwrap();
        let elapsed = now.saturating_duration_since(s.last).as_secs_f64();
        s.tokens = (s.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        s.last = now;
        if s.tokens >= 1.0 {
            s.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

// ---- Job store — keeps a turn alive past the client connection ------------
//
// The phone may suspend (socket drops) mid-turn. The turn runs on its own
// detached task and lands its result here, keyed by an opaque job id, so a
// later GET /jesse/result/{job_id} can fetch it. Entries are evicted on a TTL
// after completion so the map can't grow unbounded. In-memory only — a bridge
// restart drops in-flight jobs (acceptable for a single-user bridge; the
// escalation path, if durability is ever needed, is a disk/queue-backed store).

#[derive(Clone)]
enum JobState {
    Running,
    Done {
        response: String,
        session_id: Option<String>,
    },
    Failed {
        error: String,
    },
}

struct Job {
    state: JobState,
    // Set when the job reaches a terminal state; drives TTL eviction.
    completed_at: Option<Instant>,
}

struct JobStore {
    jobs: Mutex<HashMap<String, Job>>,
    ttl: Duration,
}

// Monotonic counter guarantees per-process uniqueness; the random high half
// (a fresh OS-seeded RandomState per id) makes the id opaque. The endpoint is
// bearer-auth gated, so the id is not itself a security boundary.
static JOB_COUNTER: AtomicU64 = AtomicU64::new(0);

fn new_job_id() -> String {
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let r = std::collections::hash_map::RandomState::new().hash_one(n);
    format!("{r:016x}{n:016x}")
}

impl JobStore {
    fn new(ttl: Duration) -> Self {
        JobStore {
            jobs: Mutex::new(HashMap::new()),
            ttl,
        }
    }

    /// Register a new running job and return its opaque id.
    fn create(&self) -> String {
        let id = new_job_id();
        self.jobs.lock().unwrap().insert(
            id.clone(),
            Job {
                state: JobState::Running,
                completed_at: None,
            },
        );
        id
    }

    /// Land a turn's outcome onto its job. A Fatal/io error becomes Failed.
    fn complete(&self, id: &str, outcome: Result<(String, Option<String>), ApiError>) {
        let state = match outcome {
            Ok((response, session_id)) => JobState::Done {
                response,
                session_id,
            },
            Err((_code, error)) => JobState::Failed { error },
        };
        if let Some(job) = self.jobs.lock().unwrap().get_mut(id) {
            job.state = state;
            job.completed_at = Some(Instant::now());
        }
    }

    fn get(&self, id: &str) -> Option<JobState> {
        self.jobs.lock().unwrap().get(id).map(|j| j.state.clone())
    }

    /// Drop completed/failed jobs older than the TTL. Running jobs are kept.
    fn evict_expired(&self) {
        let ttl = self.ttl;
        self.jobs.lock().unwrap().retain(|_, j| match j.completed_at {
            Some(t) => t.elapsed() < ttl,
            None => true,
        });
    }
}

/// Shared, cheaply-clonable handler state: read-only config, the job store, the
/// concurrency semaphore, and the rate limiter.
#[derive(Clone)]
struct AppState {
    cfg: Arc<Config>,
    jobs: Arc<JobStore>,
    // Bounds concurrent turns (C3). A permit is held for the life of a turn.
    sem: Arc<Semaphore>,
    // Per-service request rate ceiling (C3).
    limiter: Arc<RateLimiter>,
}

impl AppState {
    /// Build shared state from a config, sizing the semaphore and rate limiter
    /// from it. Used by both `main` and the tests so they exercise the same
    /// wiring.
    fn new(cfg: Config) -> Self {
        let job_ttl = Duration::from_secs(cfg.job_ttl_secs);
        let sem = Arc::new(Semaphore::new(cfg.max_concurrency.max(1)));
        let limiter = Arc::new(RateLimiter::new(cfg.rate_per_min));
        AppState {
            cfg: Arc::new(cfg),
            jobs: Arc::new(JobStore::new(job_ttl)),
            sem,
            limiter,
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
    // Files the user attached. Decoded, validated, and written to a per-request
    // scratch dir the headless agent reads; empty for an ordinary turn.
    #[serde(default)]
    attachments: Vec<Attachment>,
}

/// One inbound attachment: a base64 blob with a client-declared name and MIME.
/// All three fields are untrusted — the filename is never used as an on-disk
/// name (path traversal), and the MIME is cross-checked against a magic-byte
/// sniff (see `validate_and_decode_attachments`) rather than believed.
#[derive(Deserialize)]
struct Attachment {
    #[allow(dead_code)] // accepted for forward-compat; on-disk names are randomized
    #[serde(default)]
    filename: String,
    mime: String,
    data_base64: String,
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

/// Build the argument vector for one `claude` invocation (everything after the
/// binary name). Pure and side-effect-free so it can be unit-tested without
/// spawning a process. Enforces the C1 least-privilege boundary:
///   * `--permission-mode default` (never `acceptEdits`/`bypassPermissions`)
///   * an explicit `--allowedTools` list (always present)
///   * a `--disallowedTools` denylist as defense-in-depth
///
/// A `session_id` adds `--resume <id>` to continue a thread.
fn build_claude_args(cfg: &Config, prompt: &str, session_id: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "-p".to_string(),
        prompt.to_string(),
        "--output-format".to_string(),
        "json".to_string(),
        // Default permission mode: tools are gated by the allow/deny lists
        // below rather than auto-accepted. Never acceptEdits/bypassPermissions.
        "--permission-mode".to_string(),
        "default".to_string(),
        "--allowedTools".to_string(),
        cfg.allowed_tools.clone(),
    ];
    if !cfg.disallowed_tools.trim().is_empty() {
        args.push("--disallowedTools".to_string());
        args.push(cfg.disallowed_tools.clone());
    }
    if let Some(sid) = session_id {
        args.push("--resume".to_string());
        args.push(sid.to_string());
    }
    args
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
        // Tool access is constrained by the explicit allow/deny lists in
        // build_claude_args (C1); the agent runs under --permission-mode default.
        let mut cmd = Command::new(&cfg.claude_bin);
        cmd.args(build_claude_args(cfg, prompt, session_id))
            .current_dir(&cfg.vault) // cwd = vault → CLAUDE.md auto-loads
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true); // killed if the timeout below fires

        let child = cmd.spawn().map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to spawn {}: {e}", cfg.claude_bin),
            )
        })?;

        // "Unlimited" (timeout_secs == 0) is a debug-only affordance and never
        // compiled into a release build; Config::from_env clamps 0 to the
        // ceiling, so in release timeout_secs is always >= 1 and bounded.
        #[cfg(debug_assertions)]
        let unlimited = cfg.timeout_secs == 0;
        #[cfg(not(debug_assertions))]
        let unlimited = false;

        let output = if unlimited {
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

        // Cap captured output so one pathological run can't bloat memory. The
        // envelope the bridge parses is kilobytes; truncating multi-MB stdout
        // before the lossy decode is safe (a split multibyte char becomes U+FFFD).
        let stdout_cap = output.stdout.len().min(MAX_OUTPUT_BYTES);
        let stderr_cap = output.stderr.len().min(MAX_OUTPUT_BYTES);
        let stdout = String::from_utf8_lossy(&output.stdout[..stdout_cap]);
        let stderr = String::from_utf8_lossy(&output.stderr[..stderr_cap]);
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

// ---- Attachments ----------------------------------------------------------
//
// New file-input attack surface, so everything here is defensive: the body is
// size-bounded before it's buffered (`attachment_body_limit`), each blob is
// decoded and its real type sniffed from magic bytes and cross-checked against
// a MIME whitelist, the client filename is never used on disk, files land in a
// per-request 0700 scratch dir with randomized 0600 names, and that dir is
// removed by a Drop guard on every exit path (success, error, timeout).

/// Decode standard (RFC 4648) base64. Tolerates ASCII whitespace between
/// groups; rejects any other invalid character, data after padding, over-long
/// padding, or a truncated final group. Hand-rolled to keep the bridge
/// dependency-light — the magic-byte sniff downstream is the real content gate,
/// so this only has to be correct, not trusting.
fn base64_decode(s: &str) -> Result<Vec<u8>, &'static str> {
    fn sextet(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(s.len() / 4 * 3 + 3);
    let mut quad = [0u8; 4];
    let mut n = 0usize; // sextets buffered in `quad` (data or padding slots)
    let mut pad = 0usize; // '=' seen in the current group
    let mut done = false; // a full padded group ended the stream
    for &c in s.as_bytes() {
        if matches!(c, b'\n' | b'\r' | b' ' | b'\t') {
            continue;
        }
        if done {
            return Err("base64: trailing data after padding");
        }
        if c == b'=' {
            quad[n] = 0;
            n += 1;
            pad += 1;
        } else if pad > 0 {
            return Err("base64: data after padding");
        } else {
            match sextet(c) {
                Some(v) => {
                    quad[n] = v;
                    n += 1;
                }
                None => return Err("base64: invalid character"),
            }
        }
        if n == 4 {
            if pad > 2 {
                return Err("base64: over-long padding");
            }
            out.push((quad[0] << 2) | (quad[1] >> 4));
            if pad < 2 {
                out.push((quad[1] << 4) | (quad[2] >> 2));
            }
            if pad < 1 {
                out.push((quad[2] << 6) | quad[3]);
            }
            if pad > 0 {
                done = true;
            }
            n = 0;
            pad = 0;
        }
    }
    if n != 0 {
        return Err("base64: truncated group (length not a multiple of 4)");
    }
    Ok(out)
}

/// Sniff the real content type from leading bytes. Returns `(canonical_mime,
/// on_disk_extension)` for whitelisted types only, or `None` for anything
/// unrecognized. This — not the client's declared MIME — decides what a file is.
fn sniff_attachment(b: &[u8]) -> Option<(&'static str, &'static str)> {
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some(("image/png", "png"));
    }
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(("image/jpeg", "jpg"));
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some(("image/gif", "gif"));
    }
    if b.starts_with(b"%PDF-") {
        return Some(("application/pdf", "pdf"));
    }
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return Some(("image/webp", "webp"));
    }
    // HEIC/HEIF: an ISO-BMFF `ftyp` box carrying a HEIF-family major brand.
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        let brand: &[u8] = &b[8..12];
        const HEIF_BRANDS: [&[u8]; 8] = [
            b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1",
        ];
        if HEIF_BRANDS.contains(&brand) {
            return Some(("image/heic", "heic"));
        }
    }
    None
}

/// Normalize a client-declared MIME for comparison: lowercased, parameters
/// (`; charset=…`) stripped, and the common `image/jpg` spelling folded to the
/// canonical `image/jpeg`.
fn normalize_mime(m: &str) -> String {
    let base = m.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    if base == "image/jpg" {
        "image/jpeg".to_string()
    } else {
        base
    }
}

/// A decoded, validated attachment ready to write: raw bytes plus the canonical
/// extension chosen from the sniffed type.
#[derive(Debug)]
struct DecodedAttachment {
    bytes: Vec<u8>,
    ext: &'static str,
}

/// Decode and validate every attachment, enforcing the count / per-file / total
/// caps and the MIME-whitelist-plus-magic-byte-match rule. Any failure is a
/// `400` — bad input, never a server fault. Nothing is written to disk here.
fn validate_and_decode_attachments(
    cfg: &Config,
    atts: &[Attachment],
) -> Result<Vec<DecodedAttachment>, ApiError> {
    if atts.len() > cfg.max_attachments {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "too many attachments: {} (max {})",
                atts.len(),
                cfg.max_attachments
            ),
        ));
    }
    let mut decoded = Vec::with_capacity(atts.len());
    let mut total = 0usize;
    for (i, a) in atts.iter().enumerate() {
        let label = i + 1;
        // Reject before decoding if the base64 length alone already implies an
        // over-cap file (4 base64 chars per 3 bytes); avoids decoding a blob we
        // would only throw away.
        if a.data_base64.len() / 4 * 3 > cfg.max_attachment_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label} exceeds the per-file cap of {} bytes",
                    cfg.max_attachment_bytes
                ),
            ));
        }
        let bytes = base64_decode(&a.data_base64)
            .map_err(|e| (StatusCode::BAD_REQUEST, format!("attachment {label}: {e}")))?;
        if bytes.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("attachment {label} is empty"),
            ));
        }
        if bytes.len() > cfg.max_attachment_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label} is {} bytes (per-file cap {})",
                    bytes.len(),
                    cfg.max_attachment_bytes
                ),
            ));
        }
        let (sniffed, ext) = sniff_attachment(&bytes).ok_or((
            StatusCode::BAD_REQUEST,
            format!("attachment {label}: unsupported or unrecognized file type"),
        ))?;
        let claimed = normalize_mime(&a.mime);
        if claimed != sniffed {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label}: declared type {:?} does not match detected type {:?}",
                    a.mime, sniffed
                ),
            ));
        }
        total += bytes.len();
        if total > cfg.max_attachments_total_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachments exceed the combined cap of {} bytes",
                    cfg.max_attachments_total_bytes
                ),
            ));
        }
        decoded.push(DecodedAttachment { bytes, ext });
    }
    Ok(decoded)
}

/// Max request body axum will buffer for `/jesse`. Sized to the total decoded
/// attachment cap inflated for base64 (~4/3) plus headroom for the JSON
/// envelope and prompt text. This is the outermost bound on memory per request.
fn attachment_body_limit(cfg: &Config) -> usize {
    cfg.max_attachments_total_bytes / 3 * 4 + 256 * 1024
}

/// A short, OS-seeded random hex string for scratch dir / file names. Not a
/// security boundary (the dir is 0700 and single-user); `create_new` below is
/// what actually guarantees no collision.
fn random_hex() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let r = std::collections::hash_map::RandomState::new().hash_one(n);
    format!("{r:016x}")
}

/// A per-request scratch directory under the system temp dir (NOT the vault, so
/// attachments never pollute it; verified that headless `claude` reads paths
/// here via its Read tool with no `--add-dir`). Removed by `Drop` on every exit
/// path — success, error, or timeout — so decoded files never outlive the turn.
struct ScratchDir {
    path: PathBuf,
}

impl ScratchDir {
    fn create() -> std::io::Result<ScratchDir> {
        let path = std::env::temp_dir().join(format!("jesse-attach-{}", random_hex()));
        std::fs::DirBuilder::new()
            .recursive(false)
            .mode(0o700)
            .create(&path)?;
        Ok(ScratchDir { path })
    }

    /// Write each decoded attachment under a randomized, sniffed-extension name
    /// (the client filename is deliberately ignored) and return the on-disk
    /// paths to name in the prompt.
    fn write_all(&self, decoded: &[DecodedAttachment]) -> std::io::Result<Vec<PathBuf>> {
        let mut paths = Vec::with_capacity(decoded.len());
        for (i, d) in decoded.iter().enumerate() {
            let p = self
                .path
                .join(format!("{:02}-{}.{}", i + 1, random_hex(), d.ext));
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&p)?;
            f.write_all(&d.bytes)?;
            paths.push(p);
        }
        Ok(paths)
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// The prompt fragment that points the agent at the written attachment paths.
/// Names the on-disk paths only (never the untrusted client filename) so a
/// crafted filename can't ride into the prompt.
fn attachment_prompt_suffix(paths: &[PathBuf]) -> String {
    let list = paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "\n\n(The user attached {} file(s) with this message, saved at these \
         path(s) — read them with the Read tool as needed to answer: {list})",
        paths.len()
    )
}

// ---- Handlers -------------------------------------------------------------

async fn health(State(st): State<AppState>) -> Json<Value> {
    Json(json!({ "ok": true, "vault": st.cfg.vault, "claude": st.cfg.claude_bin }))
}

async fn jesse(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<JesseRequest>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    // Rate limit before doing any work (C3). A per-service token bucket; bursts
    // beyond JESSE_RATE_PER_MIN are shed with 429 rather than queued.
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }

    let mode = req.mode.trim().to_lowercase();
    let is_followup = req.session_id.is_some();
    let prompt = build_prompt(&mode, &req.text, is_followup, req.voice)?;

    // Concurrency cap (C3): take a permit before spawning the turn. If none is
    // immediately available, shed load with 429 instead of queuing unboundedly.
    // The permit is moved into the spawned task and held for the life of the
    // turn, so the cap reflects in-flight turns, not just connected clients.
    let permit = match st.sem.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                "busy: too many concurrent turns".to_string(),
            ))
        }
    };

    // Decode + validate any attachments (bad input → 400; the permit drops on
    // this early return), then write them to a per-request scratch dir and name
    // the paths in the prompt so the agent reads them. The scratch dir's Drop
    // guard (moved into the turn task below) removes it on every exit path.
    let decoded = validate_and_decode_attachments(&st.cfg, &req.attachments)?;
    let (prompt, scratch) = if decoded.is_empty() {
        (prompt, None)
    } else {
        let scratch = ScratchDir::create().map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("could not create attachment scratch dir: {e}"),
            )
        })?;
        let paths = scratch.write_all(&decoded).map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("could not write attachment: {e}"),
            )
        })?;
        (
            format!("{prompt}{}", attachment_prompt_suffix(&paths)),
            Some(scratch),
        )
    };

    // Opportunistic sweep so the map can't grow unbounded between requests.
    st.jobs.evict_expired();
    let job_id = st.jobs.create();

    // Run the turn on its OWN task that owns the child. Dropping this request
    // future (the phone suspends, the socket drops) does not cancel a spawned
    // tokio task, so the turn always runs to completion and lands in the store.
    let cfg = st.cfg.clone();
    let jobs = st.jobs.clone();
    let jid = job_id.clone();
    let sid = req.session_id.clone();
    let mut handle = tokio::spawn(async move {
        // Hold the permit for the whole turn, releasing it on task exit.
        let _permit: OwnedSemaphorePermit = permit;
        // Hold the scratch dir for the whole turn; its Drop removes the decoded
        // attachment files when the task ends — success, error, or timeout. The
        // files therefore survive run_claude's internal retries and are cleaned
        // exactly once, here.
        let _scratch = scratch;
        let outcome = run_claude(&cfg, &prompt, sid.as_deref()).await;
        jobs.complete(&jid, outcome);
    });

    // Hold the connection up to the grace window for the fast path.
    let grace = Duration::from_secs(st.cfg.grace_secs);
    match timeout(grace, &mut handle).await {
        // Turn finished within grace — return the reply inline as before,
        // plus the job_id (additive; existing callers ignore the extra field).
        Ok(join_res) => {
            if let Err(e) = join_res {
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("job task failed: {e}"),
                ));
            }
            match st.jobs.get(&job_id) {
                Some(JobState::Done {
                    response,
                    session_id,
                }) => Ok((
                    StatusCode::OK,
                    Json(json!({
                        "mode": req.mode,
                        "response": response,
                        "session_id": session_id,
                        "job_id": job_id,
                    })),
                )
                    .into_response()),
                Some(JobState::Failed { error }) => Err((StatusCode::BAD_GATEWAY, error)),
                // The task joined, so it must have written a terminal state.
                _ => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "job finished without a result".to_string(),
                )),
            }
        }
        // Still running at grace expiry — hand back a job id to poll. The
        // detached task keeps running; dropping `handle` does not cancel it.
        Err(_) => Ok((
            StatusCode::ACCEPTED,
            Json(json!({ "job_id": job_id, "status": "running" })),
        )
            .into_response()),
    }
}

/// Fetch a turn's state by job id. This is what the app polls after a dropped
/// socket. Same bearer auth as `/jesse`. Unknown/expired id → 404.
async fn jesse_result(
    State(st): State<AppState>,
    UrlPath(job_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    st.jobs.evict_expired();
    match st.jobs.get(&job_id) {
        Some(JobState::Running) => Ok(Json(json!({ "status": "running" }))),
        Some(JobState::Done {
            response,
            session_id,
        }) => Ok(Json(json!({
            "status": "done",
            "response": response,
            "session_id": session_id,
        }))),
        Some(JobState::Failed { error }) => {
            Ok(Json(json!({ "status": "failed", "error": error })))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            "unknown or expired job id".to_string(),
        )),
    }
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
fn app(state: AppState) -> Router {
    // Raise axum's default 2 MB body cap to fit base64 attachments, but no
    // higher than the attachment caps require — this is the outermost bound on
    // how much any one request can make the bridge buffer.
    let body_limit = attachment_body_limit(&state.cfg);
    Router::new()
        .route("/health", get(health))
        .route("/jesse", post(jesse))
        .route("/jesse/result/:job_id", get(jesse_result))
        .layer(DefaultBodyLimit::max(body_limit))
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

    // Refuse an unsafe bind (C2) before opening a socket. Only loopback or
    // CGNAT/tailnet space is allowed unless JESSE_ALLOW_PUBLIC_BIND is set.
    let allow_public = env_truthy("JESSE_ALLOW_PUBLIC_BIND");
    if !is_bind_allowed(&cfg.bind, allow_public) {
        eprintln!(
            "Refusing to bind {}: not a loopback or tailnet/CGNAT (100.64.0.0/10) \
             address. This would expose the bridge on an untrusted network. Set \
             JESSE_BIND to a safe address, or JESSE_ALLOW_PUBLIC_BIND=1 to override.",
            cfg.bind
        );
        std::process::exit(1);
    }

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let state = AppState::new(cfg);

    // Pairing QR — scan it from the app's Settings to fill in host/port/token.
    // The advertised host defaults to the bound IP (reliably reachable on the
    // tailnet; the ts.net name has DNS quirks per STATUS.md). Override with
    // JESSE_ADVERTISE_HOST to force the MagicDNS name into the QR instead.
    let advertise_host =
        std::env::var("JESSE_ADVERTISE_HOST").unwrap_or_else(|_| state.cfg.bind.clone());
    let payload = pairing_payload(&advertise_host, state.cfg.port, &state.cfg.token);
    let code = qrcode::QrCode::new(payload.as_bytes()).expect("qr encode");
    let art = code
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .build();
    println!("{art}");
    println!("Pair by scanning the QR above, or enter manually:");
    println!(
        "  host={advertise_host}  port={}  token={}",
        state.cfg.port, state.cfg.token
    );

    println!("Jesse Bridge → http://{addr}  (vault: {})", state.cfg.vault);
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
            "JESSE_MAX_ATTACHMENTS",
            "JESSE_MAX_ATTACHMENT_BYTES",
            "JESSE_MAX_ATTACHMENTS_TOTAL_BYTES",
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
        assert_eq!(cfg.max_attachments, DEFAULT_MAX_ATTACHMENTS);
        assert_eq!(cfg.max_attachment_bytes, DEFAULT_MAX_ATTACHMENT_BYTES);
        assert_eq!(
            cfg.max_attachments_total_bytes,
            DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES
        );

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    // ---- integration via app() router ------------------------------------

    fn test_config() -> Config {
        Config {
            token: "test-token".to_string(),
            // Any existing directory works — most tests never reach run_claude.
            vault: std::env::temp_dir().to_string_lossy().into_owned(),
            bind: "127.0.0.1".to_string(),
            port: 8765,
            claude_bin: "claude".to_string(),
            timeout_secs: 1800,
            allowed_tools: DEFAULT_ALLOWED_TOOLS.to_string(),
            disallowed_tools: DEFAULT_DISALLOWED_TOOLS.to_string(),
            max_concurrency: 2,
            rate_per_min: 30,
            grace_secs: 10,
            job_ttl_secs: 600,
            max_attachments: DEFAULT_MAX_ATTACHMENTS,
            max_attachment_bytes: DEFAULT_MAX_ATTACHMENT_BYTES,
            max_attachments_total_bytes: DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
        }
    }

    fn test_state() -> AppState {
        AppState::new(test_config())
    }

    async fn body_string(resp: axum::response::Response) -> String {
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    #[tokio::test]
    async fn health_returns_config() {
        let st = test_state();
        let resp = app(st.clone())
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
        assert!(body.contains(&st.cfg.vault));
        assert!(body.contains(&st.cfg.claude_bin));
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
        let resp = app(test_state())
            .oneshot(jesse_request(None, r#"{"mode":"ask","text":"hi"}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn jesse_wrong_token_is_401() {
        let resp = app(test_state())
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
        let resp = app(test_state())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"shout","text":"hi"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    // ---- job store unit tests ---------------------------------------------

    #[test]
    fn job_ids_are_unique() {
        let store = JobStore::new(Duration::from_secs(600));
        let a = store.create();
        let b = store.create();
        assert_ne!(a, b);
        // Both start Running.
        assert!(matches!(store.get(&a), Some(JobState::Running)));
        assert!(matches!(store.get(&b), Some(JobState::Running)));
        // Unknown id is None.
        assert!(store.get("nope").is_none());
    }

    #[test]
    fn job_complete_records_done_and_failed() {
        let store = JobStore::new(Duration::from_secs(600));
        let ok = store.create();
        store.complete(&ok, Ok(("hi".to_string(), Some("sess-1".to_string()))));
        match store.get(&ok) {
            Some(JobState::Done {
                response,
                session_id,
            }) => {
                assert_eq!(response, "hi");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
            }
            other => panic!("expected Done, got {:?}", other.map(|_| ())),
        }

        let bad = store.create();
        store.complete(
            &bad,
            Err((StatusCode::BAD_GATEWAY, "upstream boom".to_string())),
        );
        match store.get(&bad) {
            Some(JobState::Failed { error }) => assert!(error.contains("boom")),
            other => panic!("expected Failed, got {:?}", other.map(|_| ())),
        }
    }

    #[tokio::test]
    async fn job_ttl_evicts_completed_only() {
        let store = JobStore::new(Duration::from_millis(50));
        let old = store.create();
        store.complete(&old, Ok(("done".to_string(), None)));
        let running = store.create(); // never completes — must survive eviction
        // Wait past the TTL, then complete a fresh one that must NOT be evicted.
        tokio::time::sleep(Duration::from_millis(80)).await;
        let fresh = store.create();
        store.complete(&fresh, Ok(("fresh".to_string(), None)));

        store.evict_expired();
        assert!(store.get(&old).is_none(), "stale completed job should evict");
        assert!(
            matches!(store.get(&running), Some(JobState::Running)),
            "running job must never evict"
        );
        assert!(
            matches!(store.get(&fresh), Some(JobState::Done { .. })),
            "recently completed job must survive"
        );
    }

    // ---- GET /jesse/result auth + 404 -------------------------------------

    #[tokio::test]
    async fn result_no_auth_is_401() {
        let resp = app(test_state())
            .oneshot(
                Request::builder()
                    .uri("/jesse/result/whatever")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn result_unknown_id_is_404() {
        let resp = app(test_state())
            .oneshot(
                Request::builder()
                    .uri("/jesse/result/does-not-exist")
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    // ---- disconnect survival (the load-bearing regression) ----------------
    //
    // A fake `claude` that sleeps past the grace window, then prints the canned
    // result envelope and touches a marker file. POST returns 202 (its request
    // future is then dropped — the disconnect analog). The detached turn must
    // still run to completion: the marker appears and GET result → done.

    fn write_fake_claude(script: &str) -> std::path::PathBuf {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;
        let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
        // A pid+counter name keeps parallel test runs from colliding.
        let path = std::env::temp_dir().join(format!(
            "jesse-fake-claude-{}-{}.sh",
            std::process::id(),
            n
        ));
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(script.as_bytes()).unwrap();
        let mut perms = f.metadata().unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    async fn result_status(app_state: &AppState, job_id: &str) -> Value {
        let resp = app(app_state.clone())
            .oneshot(
                Request::builder()
                    .uri(format!("/jesse/result/{job_id}"))
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        serde_json::from_str(&body_string(resp).await).unwrap()
    }

    #[tokio::test]
    async fn turn_survives_client_disconnect() {
        let marker = std::env::temp_dir().join(format!(
            "jesse-marker-{}-{}.txt",
            std::process::id(),
            JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&marker);
        // Sleeps 2s (past the 1s grace), prints the result envelope, then marks
        // completion. If the child were killed on disconnect the marker never
        // appears and the job never reaches Done.
        let script = format!(
            "#!/bin/sh\n\
             sleep 2\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"slow ok\",\"session_id\":\"sess-slow\"}}'\n\
             touch '{}'\n",
            marker.display()
        );
        let fake = write_fake_claude(&script);

        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
            grace_secs: 1, // force the 202 path
            ..test_config()
        };
        let st = AppState::new(cfg);

        // POST — should hit grace expiry and return 202 with a job_id.
        let resp = app(st.clone())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"ask","text":"slow one"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::ACCEPTED);
        let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        assert_eq!(body["status"], "running");
        let job_id = body["job_id"].as_str().unwrap().to_string();

        // The POST future is now dropped (client "disconnected"). Poll until the
        // detached turn completes — it must, despite the dropped connection.
        let mut done = None;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let v = result_status(&st, &job_id).await;
            if v["status"] == "done" {
                done = Some(v);
                break;
            }
        }
        let done = done.expect("turn must complete despite client disconnect");
        assert_eq!(done["response"], "slow ok");
        assert_eq!(done["session_id"], "sess-slow");
        assert!(
            marker.exists(),
            "fake claude ran to completion (not killed on disconnect)"
        );

        let _ = std::fs::remove_file(&marker);
        let _ = std::fs::remove_file(&fake);
    }

    #[tokio::test]
    async fn fast_turn_returns_inline_200_with_job_id() {
        // A fake claude that returns immediately → completes within grace → 200
        // inline, now carrying job_id alongside the unchanged fields.
        let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"quick\",\"session_id\":\"sess-fast\"}'\n";
        let fake = write_fake_claude(script);
        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
            grace_secs: 10,
            ..test_config()
        };
        let st = AppState::new(cfg);

        let resp = app(st.clone())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"ask","text":"quick one"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        assert_eq!(body["response"], "quick");
        assert_eq!(body["session_id"], "sess-fast");
        assert!(body["job_id"].as_str().is_some(), "200 carries a job_id");

        let _ = std::fs::remove_file(&fake);
    }

    // ---- C1: build_claude_args --------------------------------------------

    #[test]
    fn build_claude_args_enforces_least_privilege() {
        let cfg = test_config();
        let args = build_claude_args(&cfg, "hello", None);

        // --allowedTools is always present, with the configured list as its value.
        let idx = args
            .iter()
            .position(|a| a == "--allowedTools")
            .expect("--allowedTools must always be present");
        let allow = &args[idx + 1];
        assert_eq!(allow, &cfg.allowed_tools);

        // Permission mode is default — never an auto-accept / bypass mode.
        let pidx = args
            .iter()
            .position(|a| a == "--permission-mode")
            .expect("--permission-mode present");
        assert_eq!(args[pidx + 1], "default");

        // acceptEdits / bypassPermissions never appear anywhere in the args.
        for a in &args {
            assert!(!a.contains("acceptEdits"), "acceptEdits must not appear: {a}");
            assert!(
                !a.contains("bypassPermissions"),
                "bypassPermissions must not appear: {a}"
            );
        }

        // Unscoped `Bash` is not in the allowlist — only scoped Bash(...) verbs.
        let tools: Vec<&str> = allow.split(',').map(|t| t.trim()).collect();
        assert!(
            !tools.contains(&"Bash"),
            "unscoped Bash must not be allowed: {tools:?}"
        );
        assert!(
            tools.iter().any(|t| t.starts_with("Bash(")),
            "expected scoped Bash(...) entries: {tools:?}"
        );

        // Defense-in-depth denylist is passed and contains bare Bash.
        let didx = args
            .iter()
            .position(|a| a == "--disallowedTools")
            .expect("--disallowedTools present");
        assert!(args[didx + 1].split(',').any(|t| t.trim() == "Bash"));
    }

    #[test]
    fn build_claude_args_resume_when_session() {
        let cfg = test_config();
        let args = build_claude_args(&cfg, "hi", Some("sess-42"));
        let ridx = args.iter().position(|a| a == "--resume").expect("--resume");
        assert_eq!(args[ridx + 1], "sess-42");
        // No --resume without a session id.
        let none = build_claude_args(&cfg, "hi", None);
        assert!(!none.iter().any(|a| a == "--resume"));
    }

    // ---- C2: is_bind_allowed ----------------------------------------------

    #[test]
    fn bind_allows_loopback_and_tailnet_only() {
        // Loopback (v4 + v6) and CGNAT/tailnet space are allowed.
        assert!(is_bind_allowed("127.0.0.1", false));
        assert!(is_bind_allowed("127.5.6.7", false)); // all of 127.0.0.0/8
        assert!(is_bind_allowed("::1", false));
        assert!(is_bind_allowed("100.64.0.1", false)); // tailnet (100.64/10)
        assert!(is_bind_allowed("100.64.0.0", false));
        assert!(is_bind_allowed("100.127.255.255", false));

        // Public / private-LAN / wildcard / hostname are all refused.
        assert!(!is_bind_allowed("0.0.0.0", false));
        assert!(!is_bind_allowed("192.168.1.10", false));
        assert!(!is_bind_allowed("10.0.0.5", false));
        assert!(!is_bind_allowed("8.8.8.8", false));
        assert!(!is_bind_allowed("100.128.0.1", false)); // just past 100.64/10
        assert!(!is_bind_allowed("100.63.255.255", false)); // just before
        assert!(!is_bind_allowed("example.com", false)); // hostname, not an IP
    }

    #[test]
    fn bind_allow_public_permits_everything() {
        for a in ["0.0.0.0", "192.168.1.10", "8.8.8.8", "example.com", "127.0.0.1"] {
            assert!(is_bind_allowed(a, true), "{a} should be allowed when public");
        }
    }

    // ---- C3: timeout clamp -------------------------------------------------

    #[test]
    fn timeout_clamp_treats_zero_as_ceiling() {
        // 0 means "ceiling", never unlimited.
        assert_eq!(clamp_timeout_secs(0), HARD_TIMEOUT_CEILING);
        // Over-ceiling is capped; in-range is unchanged; 1 is the floor.
        assert_eq!(clamp_timeout_secs(HARD_TIMEOUT_CEILING + 10), HARD_TIMEOUT_CEILING);
        assert_eq!(clamp_timeout_secs(1800), 1800);
        assert_eq!(clamp_timeout_secs(1), 1);
    }

    #[test]
    fn config_zero_timeout_clamps_to_ceiling() {
        let _guard = ENV_LOCK.lock().unwrap();
        let saved = std::env::var("JESSE_TIMEOUT").ok();
        std::env::set_var("JESSE_TIMEOUT", "0");
        let cfg = Config::from_env();
        assert_eq!(cfg.timeout_secs, HARD_TIMEOUT_CEILING);
        match saved {
            Some(v) => std::env::set_var("JESSE_TIMEOUT", v),
            None => std::env::remove_var("JESSE_TIMEOUT"),
        }
    }

    // ---- C3: concurrency cap ----------------------------------------------

    #[tokio::test]
    async fn second_concurrent_turn_is_429() {
        // A fake claude that sleeps long enough that the first turn is still
        // in-flight (holding the only permit) when the second POST arrives.
        let script = "#!/bin/sh\nsleep 2\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n";
        let fake = write_fake_claude(script);
        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
            grace_secs: 1,        // first POST returns 202 while the turn runs on
            max_concurrency: 1,   // exactly one permit
            ..test_config()
        };
        let st = AppState::new(cfg);

        // First POST: occupies the only permit, returns 202 at grace expiry; the
        // detached turn keeps the permit while the fake claude sleeps.
        let first = app(st.clone())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"ask","text":"one"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(first.status(), StatusCode::ACCEPTED);

        // Second POST while the first turn still holds the permit → 429.
        let second = app(st.clone())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"ask","text":"two"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);

        let _ = std::fs::remove_file(&fake);
    }

    // ---- C3: rate limiter --------------------------------------------------

    #[test]
    fn rate_limiter_sheds_burst_beyond_capacity() {
        // Capacity 3: first three allowed, fourth shed.
        let rl = RateLimiter::new(3);
        assert!(rl.allow());
        assert!(rl.allow());
        assert!(rl.allow());
        assert!(!rl.allow(), "burst beyond capacity must be rejected");
    }

    // ---- Attachments -------------------------------------------------------

    // Minimal magic-byte fixtures — enough leading bytes for `sniff_attachment`.
    const PNG_BYTES: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
    const JPEG_BYTES: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F'];
    const PDF_BYTES: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";
    const GIF_BYTES: &[u8] = b"GIF89a\x01\x00\x01\x00\x00\x00\x00";
    const WEBP_BYTES: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";
    const HEIC_BYTES: &[u8] = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00";

    /// A standalone base64 *encoder* used only by the tests, so the decoder is
    /// exercised against an independent implementation rather than itself.
    fn b64(data: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in data.chunks(3) {
            let b0 = chunk[0];
            let b1 = *chunk.get(1).unwrap_or(&0);
            let b2 = *chunk.get(2).unwrap_or(&0);
            out.push(T[(b0 >> 2) as usize] as char);
            out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            out.push(if chunk.len() > 1 {
                T[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                T[(b2 & 0x3F) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    fn attachment_json(mime: &str, bytes: &[u8]) -> String {
        format!(
            r#"{{"filename":"x","mime":"{mime}","data_base64":"{}"}}"#,
            b64(bytes)
        )
    }

    #[test]
    fn base64_round_trips_against_independent_encoder() {
        // Cover all three tail lengths (0/1/2 trailing bytes) plus all byte values.
        for len in [0usize, 1, 2, 3, 4, 5, 6, 255, 256, 257] {
            let data: Vec<u8> = (0..len).map(|i| (i * 7 % 256) as u8).collect();
            let enc = b64(&data);
            let dec = base64_decode(&enc).expect("valid base64 decodes");
            assert_eq!(dec, data, "round trip failed at len {len}");
        }
        // Known vectors.
        assert_eq!(base64_decode("TWFu").unwrap(), b"Man");
        assert_eq!(base64_decode("TWE=").unwrap(), b"Ma");
        assert_eq!(base64_decode("TQ==").unwrap(), b"M");
        // Whitespace between groups is tolerated.
        assert_eq!(base64_decode("TW\nFu").unwrap(), b"Man");
    }

    #[test]
    fn base64_rejects_malformed_input() {
        assert!(base64_decode("TWF").is_err(), "truncated group");
        assert!(base64_decode("****").is_err(), "invalid character");
        assert!(base64_decode("TQ==X").is_err(), "trailing data after padding");
        assert!(base64_decode("T=Fu").is_err(), "data after padding mid-group");
        assert!(base64_decode("====").is_err(), "over-long padding");
    }

    #[test]
    fn sniff_identifies_whitelisted_types() {
        assert_eq!(sniff_attachment(PNG_BYTES), Some(("image/png", "png")));
        assert_eq!(sniff_attachment(JPEG_BYTES), Some(("image/jpeg", "jpg")));
        assert_eq!(sniff_attachment(PDF_BYTES), Some(("application/pdf", "pdf")));
        assert_eq!(sniff_attachment(GIF_BYTES), Some(("image/gif", "gif")));
        assert_eq!(sniff_attachment(WEBP_BYTES), Some(("image/webp", "webp")));
        assert_eq!(sniff_attachment(HEIC_BYTES), Some(("image/heic", "heic")));
    }

    #[test]
    fn sniff_rejects_unknown_and_short_input() {
        assert_eq!(sniff_attachment(b"not a real file"), None);
        assert_eq!(sniff_attachment(b""), None);
        assert_eq!(sniff_attachment(&[0xFF, 0xD8]), None); // too short for JPEG
        // A ZIP/Office doc is deliberately NOT on the whitelist.
        assert_eq!(sniff_attachment(b"PK\x03\x04"), None);
    }

    #[test]
    fn normalize_mime_folds_jpg_and_strips_params() {
        assert_eq!(normalize_mime("image/jpg"), "image/jpeg");
        assert_eq!(normalize_mime("IMAGE/PNG"), "image/png");
        assert_eq!(normalize_mime("application/pdf; charset=binary"), "application/pdf");
    }

    #[test]
    fn validate_accepts_well_formed_attachments() {
        let cfg = test_config();
        let atts = vec![
            Attachment {
                filename: "shot.png".into(),
                mime: "image/png".into(),
                data_base64: b64(PNG_BYTES),
            },
            Attachment {
                filename: "doc.pdf".into(),
                mime: "application/pdf".into(),
                data_base64: b64(PDF_BYTES),
            },
        ];
        let decoded = validate_and_decode_attachments(&cfg, &atts).expect("valid");
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0].ext, "png");
        assert_eq!(decoded[1].ext, "pdf");
        assert_eq!(decoded[0].bytes, PNG_BYTES);
    }

    #[test]
    fn validate_rejects_mime_magic_mismatch() {
        let cfg = test_config();
        // PDF bytes declared as a PNG — the classic extension/MIME lie.
        let atts = vec![Attachment {
            filename: "evil.png".into(),
            mime: "image/png".into(),
            data_base64: b64(PDF_BYTES),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("does not match"));
    }

    #[test]
    fn validate_rejects_unknown_type() {
        let cfg = test_config();
        let atts = vec![Attachment {
            filename: "a.bin".into(),
            mime: "application/octet-stream".into(),
            data_base64: b64(b"PK\x03\x04 zip not allowed"),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("unsupported or unrecognized"));
    }

    #[test]
    fn validate_rejects_too_many() {
        let mut cfg = test_config();
        cfg.max_attachments = 2;
        let one = Attachment {
            filename: "p.png".into(),
            mime: "image/png".into(),
            data_base64: b64(PNG_BYTES),
        };
        let atts: Vec<Attachment> = (0..3)
            .map(|_| Attachment {
                filename: one.filename.clone(),
                mime: one.mime.clone(),
                data_base64: one.data_base64.clone(),
            })
            .collect();
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("too many"));
    }

    #[test]
    fn validate_enforces_per_file_and_total_caps() {
        // Per-file cap: a 4 KB JPEG against a 1 KB cap.
        let mut cfg = test_config();
        cfg.max_attachment_bytes = 1024;
        let mut big = JPEG_BYTES.to_vec();
        big.resize(4096, 0);
        let atts = vec![Attachment {
            filename: "big.jpg".into(),
            mime: "image/jpeg".into(),
            data_base64: b64(&big),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("per-file cap"));

        // Total cap: two 600-byte files against a 1000-byte total cap. Per-file
        // is left high so only the *combined* size trips.
        let mut cfg = test_config();
        cfg.max_attachment_bytes = 10_000;
        cfg.max_attachments_total_bytes = 1000;
        let mut mid = JPEG_BYTES.to_vec();
        mid.resize(600, 0);
        let atts = vec![
            Attachment {
                filename: "a.jpg".into(),
                mime: "image/jpeg".into(),
                data_base64: b64(&mid),
            },
            Attachment {
                filename: "b.jpg".into(),
                mime: "image/jpeg".into(),
                data_base64: b64(&mid),
            },
        ];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("combined cap"));
    }

    #[test]
    fn validate_rejects_empty_and_bad_base64() {
        let cfg = test_config();
        let empty = vec![Attachment {
            filename: "e.png".into(),
            mime: "image/png".into(),
            data_base64: String::new(),
        }];
        assert_eq!(
            validate_and_decode_attachments(&cfg, &empty).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        let bad = vec![Attachment {
            filename: "b.png".into(),
            mime: "image/png".into(),
            data_base64: "not base64 !!!".into(),
        }];
        assert_eq!(
            validate_and_decode_attachments(&cfg, &bad).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
    }

    #[test]
    fn scratch_dir_writes_randomized_files_and_cleans_up_on_drop() {
        use std::os::unix::fs::PermissionsExt;
        let decoded = vec![
            DecodedAttachment {
                bytes: PNG_BYTES.to_vec(),
                ext: "png",
            },
            DecodedAttachment {
                bytes: PDF_BYTES.to_vec(),
                ext: "pdf",
            },
        ];
        let dir_path;
        let file_paths;
        {
            let scratch = ScratchDir::create().expect("create scratch");
            dir_path = scratch.path.clone();
            // Dir is owner-only (0700).
            let mode = std::fs::metadata(&dir_path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);

            file_paths = scratch.write_all(&decoded).expect("write");
            assert_eq!(file_paths.len(), 2);
            for (p, d) in file_paths.iter().zip(&decoded) {
                assert!(p.exists());
                // On-disk name is NOT the client filename; it carries the
                // sniffed extension and a random component.
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                assert!(name.ends_with(&format!(".{}", d.ext)));
                assert!(!name.contains("shot") && !name.contains("doc"));
                assert_eq!(std::fs::read(p).unwrap(), d.bytes);
                let fmode = std::fs::metadata(p).unwrap().permissions().mode();
                assert_eq!(fmode & 0o777, 0o600);
            }
            // The two random names differ.
            assert_ne!(file_paths[0], file_paths[1]);
        } // scratch dropped here

        assert!(!dir_path.exists(), "scratch dir must be removed on Drop");
        for p in &file_paths {
            assert!(!p.exists(), "scratch files must be gone with the dir");
        }
    }

    #[test]
    fn attachment_prompt_suffix_names_paths_only() {
        let paths = vec![PathBuf::from("/tmp/jesse-attach-ab/01-cd.png")];
        let s = attachment_prompt_suffix(&paths);
        assert!(s.contains("/tmp/jesse-attach-ab/01-cd.png"));
        assert!(s.contains("Read tool"));
        assert!(s.contains("1 file"));
    }

    #[test]
    fn body_limit_exceeds_total_cap_for_base64_inflation() {
        let cfg = test_config();
        // Must hold the base64-inflated total (4/3) with room to spare.
        assert!(attachment_body_limit(&cfg) > cfg.max_attachments_total_bytes);
        assert!(
            attachment_body_limit(&cfg) >= cfg.max_attachments_total_bytes / 3 * 4,
            "body limit must fit base64-encoded attachments"
        );
    }

    // Integration: a bad attachment is rejected at the door — 400 BEFORE the
    // turn task spawns, so `claude` is never invoked (these run in CI without it).

    #[tokio::test]
    async fn jesse_rejects_mismatched_attachment_with_400() {
        let att = attachment_json("image/png", PDF_BYTES); // PDF bytes claimed as PNG
        let json = format!(r#"{{"mode":"ask","text":"hi","attachments":[{att}]}}"#);
        let resp = app(test_state())
            .oneshot(jesse_request(Some("Bearer test-token"), &json))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn jesse_rejects_too_many_attachments_with_400() {
        let att = attachment_json("image/png", PNG_BYTES);
        let many = std::iter::repeat_n(att.as_str(), DEFAULT_MAX_ATTACHMENTS + 1)
            .collect::<Vec<_>>()
            .join(",");
        let json = format!(r#"{{"mode":"ask","text":"hi","attachments":[{many}]}}"#);
        let resp = app(test_state())
            .oneshot(jesse_request(Some("Bearer test-token"), &json))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn jesse_without_attachments_field_still_works() {
        // The field is #[serde(default)] — existing clients omit it entirely.
        // A bad mode still reaches build_prompt and returns 400, proving the
        // request deserialized fine without `attachments`.
        let resp = app(test_state())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                r#"{"mode":"nope","text":"hi"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}
