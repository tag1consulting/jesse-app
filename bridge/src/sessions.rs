use crate::*;

// ---- GET /jesse/sessions — the session list --------------------------------
//
// Threads are Claude Code sessions. Each session's transcript is one jsonl file
// under `~/.claude/projects/<escaped-vault-path>/<session_id>.jsonl`, where the
// filename stem IS the session_id. This endpoint enumerates those files for the
// bridge's vault, newest first by mtime, with the first user turn as a snippet and
// the stored title (if any). Read-only: it never writes a session file.

/// How many bytes of a session jsonl to scan for the first user turn. A real
/// first user turn sits at the top of the file, so a bounded prefix suffices — we
/// never read a multi-MB transcript to find it.
pub const SESSION_SCAN_BYTES: u64 = 64 * 1024;

/// The first-message snippet is truncated to this many CHARS on a char boundary.
pub const FIRST_MESSAGE_CHARS: usize = 120;

/// Escape an absolute working-directory path into the directory name Claude Code
/// uses under `~/.claude/projects/`.
///
/// VERIFIED against `claude 2.1.208` (2026-07-14) by creating a session in a
/// controlled cwd and matching the created dir: **every character that is not
/// ASCII-alphanumeric is replaced with `-`** — so `/`, `.`, and `_` all become
/// `-`, an existing `-` is kept, and runs are NOT collapsed (`/.claude` → `--claude`).
/// e.g. `/Users/u/devel/tag1/jesse-app` → `-Users-u-devel-tag1-jesse-app` and
/// `/private/tmp/jt_esc.mix-dir` → `-private-tmp-jt-esc-mix-dir`. (An older CLI
/// preserved `_`; the current one does not — this matches the current CLI.)
pub fn escape_project_path(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The `~/.claude/projects/<escaped-vault>` directory a vault's session jsonl
/// files live in. `home` is the bridge user's HOME (the projects dir is under the
/// user running the bridge, not under the vault).
pub fn vault_sessions_dir(home: &str, vault: &str) -> PathBuf {
    PathBuf::from(home)
        .join(".claude")
        .join("projects")
        .join(escape_project_path(vault))
}

/// The transcript path for one session under the vault's projects dir:
/// `<home>/.claude/projects/<escaped-vault>/<session_id>.jsonl`. Pure path
/// arithmetic — it does not check existence. Callers pass a session id that has
/// already been validated as a plain component (see [`is_plain_session_component`]).
pub fn session_transcript_path(home: &str, vault: &str, session_id: &str) -> PathBuf {
    vault_sessions_dir(home, vault).join(format!("{session_id}.jsonl"))
}

/// Whether a session id is a plain filename component that can only ever name a
/// file *inside* the vault projects dir — non-empty, not `.`/`..`, and free of
/// any path separator. This is the SAME defensive check `list_sessions` applies
/// to a listed stem; here it guards a caller-supplied id (delete / resume) so a
/// crafted `session_id` like `../../foo` can never escape the vault projects dir.
pub fn is_plain_session_component(session_id: &str) -> bool {
    !session_id.is_empty()
        && session_id != "."
        && session_id != ".."
        && !session_id.contains('/')
        && !session_id.contains('\\')
}

/// Whether a real (non-synthetic) session's transcript still exists on disk under
/// the bridge's vault projects dir. Uses the HOME captured in `cfg.home` (like
/// `AppState::sessions_dir`); an unknown HOME or a non-plain id yields `false`.
/// A synthetic `local-` id (context carry) has no transcript by construction, so
/// this reports `false` for it — callers that care special-case it first.
pub fn session_transcript_exists(cfg: &Config, session_id: &str) -> bool {
    if !is_plain_session_component(session_id) {
        return false;
    }
    session_transcript_path(&cfg.home, &cfg.vault, session_id).is_file()
}

/// The outcome of deleting one session's transcript. `Deleted` removed an existing
/// file; `AlreadyGone` found none (idempotent success — an unknown or already-gone
/// id is NOT an error, so retries and GC never choke); `Failed` is a real I/O
/// failure deleting a file that exists.
#[derive(Debug, PartialEq)]
pub enum SessionDeleteOutcome {
    Deleted,
    AlreadyGone,
    Failed(String),
}

/// Delete one session's transcript file from a projects `dir`, idempotently and
/// scoped to that dir. The `session_id` must be a plain component (the handler
/// rejects a non-plain id before calling this); the file removed is exactly
/// `<dir>/<session_id>.jsonl`. A `NotFound` error maps to `AlreadyGone` (success),
/// any other I/O error to `Failed`. Never touches anything but that one file.
pub fn delete_session_file(dir: &Path, session_id: &str) -> SessionDeleteOutcome {
    let path = dir.join(format!("{session_id}.jsonl"));
    match std::fs::remove_file(&path) {
        Ok(()) => SessionDeleteOutcome::Deleted,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => SessionDeleteOutcome::AlreadyGone,
        Err(e) => SessionDeleteOutcome::Failed(e.to_string()),
    }
}

// ---- Age-based GC sweep ----------------------------------------------------

/// How often the background session GC sweep runs (plus one run at startup). The
/// TTL is measured in days, so a several-hour cadence reclaims orphaned sessions
/// promptly without churning the disk.
pub const SESSION_GC_INTERVAL: Duration = Duration::from_secs(6 * 3600);

/// Whether a session whose transcript was last modified at `mtime_secs` is past
/// the `ttl_days` reclaim age at wall clock `now_secs` (both unix seconds). Pure,
/// so the age predicate is unit-tested against a FIXED clock (no wall-clock sleep).
/// STRICTLY older: a session exactly at the TTL boundary — or anything younger —
/// is kept. `saturating_*` keeps a clock skew (mtime in the future) from
/// underflowing to a huge age.
pub fn is_session_expired(mtime_secs: u64, now_secs: u64, ttl_days: u64) -> bool {
    let ttl_secs = ttl_days.saturating_mul(86_400);
    now_secs.saturating_sub(mtime_secs) > ttl_secs
}

/// Sweep a vault projects `dir`, deleting every `*.jsonl` session whose mtime is
/// older than `ttl_days` at wall clock `now_secs`. Returns the `(session_id,
/// age_secs)` of each reclaimed session (for logging/tests). `now_secs` is passed
/// in so the sweep is testable against a fixed clock. Robust and scoped exactly
/// like `list_sessions`:
/// - a missing/unreadable `dir` reclaims nothing (never an error);
/// - only plain `*.jsonl` regular files directly in `dir` are considered — subdirs,
///   other files, and a non-plain stem are skipped, so it can never delete outside
///   the vault projects dir;
/// - a session younger than the TTL (or exactly at it) is NEVER deleted;
/// - a per-file delete failure is logged and skipped, never aborting the sweep.
pub fn sweep_expired_sessions(dir: &Path, now_secs: u64, ttl_days: u64) -> Vec<(String, u64)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut reclaimed = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if !is_plain_session_component(stem) {
            continue;
        }
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if !is_session_expired(mtime, now_secs, ttl_days) {
            continue;
        }
        let age = now_secs.saturating_sub(mtime);
        match std::fs::remove_file(&path) {
            Ok(()) => {
                let age_days = age / 86_400;
                eprintln!(
                    "jesse-bridge: session GC reclaimed {stem} (age {age_days}d, ttl {ttl_days}d)"
                );
                reclaimed.push((stem.to_string(), age));
            }
            Err(e) => {
                eprintln!("jesse-bridge: session GC could not delete {stem}: {e} — skipped");
            }
        }
    }
    reclaimed
}

/// Run one GC sweep over the bridge vault's projects dir at the current wall
/// clock. Uses the HOME captured in `cfg.home` (mirroring `AppState::sessions_dir`)
/// so the sweep stays scoped to exactly the vault project. Titles AND flags for
/// reclaimed sessions are dropped from their stores so a reclaimed id can't linger
/// in `titles.json` / `flags.json` and resurrect a stale title or favorite.
pub fn run_session_gc(cfg: &Config, titles: &TitleStore, flags: &FlagStore) {
    let dir = vault_sessions_dir(&cfg.home, &cfg.vault);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let reclaimed = sweep_expired_sessions(&dir, now, cfg.session_ttl_days);
    for (id, _age) in &reclaimed {
        titles.remove(id);
        flags.remove(id);
    }
    if !reclaimed.is_empty() {
        eprintln!(
            "jesse-bridge: session GC swept {} orphaned session(s) older than {} days",
            reclaimed.len(),
            cfg.session_ttl_days
        );
    }
}

/// Spawn the background session GC sweep: one run immediately at startup, then
/// every `SESSION_GC_INTERVAL`, for the life of the process. A missing session
/// TTL / projects dir is handled gracefully by `run_session_gc` (it reclaims
/// nothing). Mirrors `spawn_eviction_task`'s shape.
pub fn spawn_session_gc_task(cfg: Arc<Config>, titles: Arc<TitleStore>, flags: Arc<FlagStore>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(SESSION_GC_INTERVAL);
        // `interval` fires the first tick IMMEDIATELY, so this is the "one run at
        // startup" the spec asks for; subsequent ticks are the periodic sweep.
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            run_session_gc(&cfg, &titles, &flags);
        }
    });
}

// ---- Resume-after-sweep safety ---------------------------------------------

/// Decide the session id to actually pass to `claude --resume`, given whether the
/// requested session's transcript still exists. Pure, so the decision is
/// unit-tested against a fixed bool.
///   * `None` → `None` (a fresh turn — unchanged).
///   * a synthetic `local-` id → passed through unchanged (`build_claude_args`
///     already never resumes it; the existence bool is irrelevant here).
///   * a real id whose transcript is PRESENT → resume it (today's behavior).
///   * a real id whose transcript is MISSING (swept by GC, or deleted) → `None`:
///     run FRESH rather than let `claude --resume <gone>` surface a raw CLI error.
///     The turn returns a new session id and the app keeps its local transcript.
pub fn effective_resume_id(session_id: Option<&str>, transcript_exists: bool) -> Option<&str> {
    match session_id {
        None => None,
        Some(sid) if is_synthetic_session_id(sid) => Some(sid),
        Some(sid) if transcript_exists => Some(sid),
        Some(_) => None,
    }
}

/// Resolve the effective `--resume` session for a hosted turn: drop the resume
/// when the requested real session's transcript no longer exists on disk (swept
/// by GC or deleted while the phone thread lived on), so a stale resume becomes a
/// clean FRESH session instead of a crash or a raw system error string. Reads HOME
/// via `session_transcript_exists`; logs a named line when it drops a resume so the
/// fall-to-fresh is visible, never silent. A synthetic id and a live real id pass
/// through unchanged.
pub fn resolve_resume_session<'a>(cfg: &Config, session_id: Option<&'a str>) -> Option<&'a str> {
    let sid = session_id?;
    // Synthetic ids never have a transcript and must not trigger a (false) fs miss
    // log — they are handled (never resumed) downstream in `build_claude_args`.
    if is_synthetic_session_id(sid) {
        return Some(sid);
    }
    let exists = session_transcript_exists(cfg, sid);
    let effective = effective_resume_id(Some(sid), exists);
    if effective.is_none() {
        eprintln!(
            "jesse-bridge: session {sid} has no transcript (swept by GC or deleted) — \
             starting a fresh session for this thread"
        );
    }
    effective
}

/// One session summary in the response, newest-first ordered by the caller. The
/// four flag fields (`favorite`, `favorite_updated_ms`, `archived`,
/// `archived_updated_ms`) are additive: they default to false/0 for a session with
/// no flags row, and an older app that predates them simply ignores them.
#[derive(serde::Serialize, PartialEq, Debug)]
pub struct SessionSummary {
    pub session_id: String,
    pub last_modified: u64,
    pub first_message: Option<String>,
    pub title: Option<String>,
    pub favorite: bool,
    pub favorite_updated_ms: u64,
    pub archived: bool,
    pub archived_updated_ms: u64,
}

/// Pull the user text out of a `{"type":"user","message":{...}}` transcript line.
/// Handles both shapes seen in real transcripts: `message.content` as a plain
/// string, and as an array of content blocks (the `text` of each `{"type":"text"}`
/// block, joined). Returns `None` for a non-user line or one with no text.
pub fn extract_user_text(v: &Value) -> Option<String> {
    if v.get("type").and_then(|t| t.as_str()) != Some("user") {
        return None;
    }
    let content = v.get("message")?.get("content")?;
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                        parts.push(t);
                    }
                }
            }
            (!parts.is_empty()).then(|| parts.join("\n"))
        }
        _ => None,
    }
}

/// Pull the assistant text out of a `{"type":"assistant","message":{...}}`
/// transcript line — the visible answer only. Content is an array of blocks in a
/// real transcript (occasionally a plain string); the `text` of each `{"type":"text"}`
/// block is joined, and every non-text block (`thinking`, `tool_use`) is dropped, so
/// hydrated assistant turns carry exactly what a live SSE turn streams. Returns
/// `None` for a non-assistant line or one with no visible text (a tool-use-only turn).
pub fn extract_assistant_text(v: &Value) -> Option<String> {
    if v.get("type").and_then(|t| t.as_str()) != Some("assistant") {
        return None;
    }
    let content = v.get("message")?.get("content")?;
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                        parts.push(t);
                    }
                }
            }
            (!parts.is_empty()).then(|| parts.join("\n"))
        }
        _ => None,
    }
}

/// Read a bounded prefix of a session jsonl and return the RAW (un-stripped) text of
/// its first user turn. `None` when no user turn with text is found within the
/// prefix, or the file can't be read — never an error. Unparseable lines are
/// skipped. Shared by the list snippet AND the title-mint check, so both see exactly
/// the same first-user text (the mint check must run on the raw text, before any
/// wrapper stripping).
pub fn first_user_raw(path: &Path) -> Option<String> {
    use std::io::Read;
    let file = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    file.take(SESSION_SCAN_BYTES).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue; // skip an unparseable (or trailing partial) line
        };
        if let Some(t) = extract_user_text(&v) {
            let t = t.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
    }
    None
}

/// Turn a RAW first-user turn into the list snippet: strip the bridge wrapper (or
/// interactive caveat framing) so the user's actual words show, then truncate to
/// `FIRST_MESSAGE_CHARS` chars on a char boundary. `None` when nothing renderable
/// remains after stripping (e.g. a bare `/clear`).
fn snippet_from_raw(raw: &str) -> Option<String> {
    let stripped = strip_prompt_wrapper(raw);
    let t = stripped.trim();
    (!t.is_empty()).then(|| truncate_chars(t, FIRST_MESSAGE_CHARS))
}

/// Read a bounded prefix of a session jsonl and return its first user turn as the
/// list snippet — wrapper-stripped and truncated to `FIRST_MESSAGE_CHARS`. `None`
/// when no renderable user turn is found within the prefix or the file can't be
/// read (the session then shows `first_message: null`, never an error).
pub fn first_user_message(path: &Path) -> Option<String> {
    first_user_raw(path).as_deref().and_then(snippet_from_raw)
}

/// Enumerate the session jsonl files in `dir`, newest first by mtime, filling each
/// summary's `first_message` and `title`. Robust by contract:
/// - a missing/unreadable `dir` → an empty list (the bridge may run before any
///   session exists), never an error;
/// - only `*.jsonl` regular files directly in `dir` are considered — subdirs and
///   other files are ignored;
/// - a filename stem that isn't a plain component (empty, `.`/`..`, or containing a
///   path separator) is skipped defensively, so a listing can never reach outside
///   `dir`;
/// - `since` (unix seconds), when set, keeps only sessions with mtime STRICTLY
///   greater — the delta-poll filter.
///
/// Each summary's four flag fields are filled from the `flags` store, defaulting to
/// false/0 for a session with no row. The flags are part of the serialized body, so
/// they are folded into the list's ETag automatically (see `jesse_sessions`):
/// flipping a flag changes the body and therefore invalidates a cached 304.
pub fn list_sessions(
    dir: &Path,
    since: Option<u64>,
    titles: &TitleStore,
    flags: &FlagStore,
) -> Vec<SessionSummary> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        // Defensive: the stem must be a plain filename component. It comes from a
        // directory listing (so this is belt-and-suspenders), but a name that could
        // escape the dir must never become a session_id.
        if stem.is_empty()
            || stem == "."
            || stem == ".."
            || stem.contains('/')
            || stem.contains('\\')
        {
            continue;
        }
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Some(s) = since {
            if mtime <= s {
                continue;
            }
        }
        // Wart 1: a `POST /jesse/title` one-shot mints its own transcript whose
        // first user turn is the fixed title instruction. Those are not real
        // conversations — exclude them from the list entirely.
        let raw = first_user_raw(&path);
        if raw.as_deref().map(is_title_mint_prompt).unwrap_or(false) {
            continue;
        }
        let f = flags.get(stem);
        out.push(SessionSummary {
            session_id: stem.to_string(),
            last_modified: mtime,
            // Wart 2: strip the bridge wrapper so the snippet is the user's words.
            first_message: raw.as_deref().and_then(snippet_from_raw),
            title: titles.get(stem),
            favorite: f.favorite,
            favorite_updated_ms: f.favorite_updated_ms,
            archived: f.archived,
            archived_updated_ms: f.archived_updated_ms,
        });
    }
    // Newest first; break ties on session_id for a stable, deterministic order
    // (so the ETag is stable across calls with unchanged inputs).
    out.sort_by(|a, b| {
        b.last_modified
            .cmp(&a.last_modified)
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    out
}

/// Compute a strong ETag over the serialized response body: a quoted lowercase hex
/// SHA-256. Strong (no `W/` prefix) because it's an exact hash of the exact bytes.
pub fn strong_etag(body: &str) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, body.as_bytes());
    let mut hex = String::with_capacity(2 + digest.as_ref().len() * 2);
    hex.push('"');
    for b in digest.as_ref() {
        hex.push_str(&format!("{b:02x}"));
    }
    hex.push('"');
    hex
}

/// Whether an `If-None-Match` header value matches our ETag. Honors the `*`
/// wildcard and a comma-separated list of candidates (RFC 7232).
pub fn if_none_match_matches(header: &str, etag: &str) -> bool {
    header
        .split(',')
        .map(str::trim)
        .any(|candidate| candidate == "*" || candidate == etag)
}

/// Query params for `GET /jesse/sessions`.
#[derive(Deserialize)]
pub struct SessionsQuery {
    /// Only sessions with mtime strictly greater than this (unix seconds).
    #[serde(default)]
    pub since: Option<u64>,
}

/// `GET /jesse/sessions` — list the vault's Claude Code sessions, newest first.
/// Same bearer auth and rate limiter as `/jesse`. `?since=<unix seconds>` returns
/// only sessions modified after that. Honors `If-None-Match` with a strong ETag
/// over the body (`304 Not Modified`, empty body, when it matches). A missing
/// projects dir yields an empty list, not an error.
pub async fn jesse_sessions(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SessionsQuery>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }

    let dir = st.sessions_dir();
    let sessions = list_sessions(&dir, params.since, &st.titles, &st.flags);
    let body = serde_json::to_string(&json!({ "sessions": sessions }))
        .unwrap_or_else(|_| r#"{"sessions":[]}"#.to_string());
    let etag = strong_etag(&body);

    // If-None-Match → 304 with the ETag and no body.
    if let Some(inm) = headers
        .get(axum::http::header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    {
        if if_none_match_matches(inm, &etag) {
            return Ok(
                (StatusCode::NOT_MODIFIED, [(axum::http::header::ETAG, etag)]).into_response(),
            );
        }
    }

    Ok((
        StatusCode::OK,
        [
            (axum::http::header::ETAG, etag),
            (
                axum::http::header::CONTENT_TYPE,
                "application/json".to_string(),
            ),
        ],
        body,
    )
        .into_response())
}

// ---- GET /jesse/sessions/{id} — transcript hydration -----------------------
//
// A client that never saw a session's earlier turns hydrates its history here. The
// full transcript is the session's `<session_id>.jsonl`; this endpoint returns the
// ordered, client-renderable turns (user utterances + visible assistant text),
// wrapper-stripped exactly like the list snippet and shaped like a live SSE turn.
// `?after=<byte offset>` returns only the bytes appended since — the jsonl is
// append-only, so a reconnecting client re-syncs in one small round trip.

/// One hydrated turn: a role, the visible text, and the transcript timestamp when
/// present. `timestamp` is omitted from the JSON when a line carries none.
#[derive(serde::Serialize, PartialEq, Debug)]
pub struct HydratedTurn {
    pub role: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
}

/// Shape one transcript jsonl line into a renderable turn, or `None` to skip it.
/// Mirrors the live SSE convention — user utterances (wrapper-stripped) and visible
/// assistant TEXT only — so hydrated history and live turns look the same. Skipped:
/// tool-use / thinking-only turns and `tool_result` carriers (no visible text),
/// subagent (`isSidechain`) traffic and CLI `isMeta` plumbing (e.g. the caveat line),
/// non-turn line types (`system`, `summary`, …), and blank / malformed lines.
fn shape_turn_line(line: &str) -> Option<HydratedTurn> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let v: Value = serde_json::from_str(line).ok()?; // skip a malformed/partial line
    if v.get("isSidechain").and_then(|b| b.as_bool()) == Some(true) {
        return None;
    }
    if v.get("isMeta").and_then(|b| b.as_bool()) == Some(true) {
        return None;
    }
    let ts = v
        .get("timestamp")
        .and_then(|t| t.as_str())
        .map(str::to_string);
    match v.get("type").and_then(|t| t.as_str()) {
        Some("user") => {
            let stripped = strip_prompt_wrapper(extract_user_text(&v)?.trim());
            let text = stripped.trim();
            (!text.is_empty()).then(|| HydratedTurn {
                role: "user".to_string(),
                text: text.to_string(),
                timestamp: ts,
            })
        }
        Some("assistant") => {
            let text = extract_assistant_text(&v)?;
            let text = text.trim();
            (!text.is_empty()).then(|| HydratedTurn {
                role: "assistant".to_string(),
                text: text.to_string(),
                timestamp: ts,
            })
        }
        _ => None,
    }
}

/// Parse jsonl `bytes` — which begin at absolute file offset `base` — into ordered
/// turns, plus the absolute byte offset immediately after the last NEWLINE-terminated
/// line consumed. A trailing line with no `\n` (an append-only file caught
/// mid-write) is left UNCONSUMED: `next_offset` points at its start, so the next
/// `?after=` call returns it once the writer finishes it. A complete-but-malformed
/// line is skipped and still advances the offset (it is gone, not replayed forever).
/// Pure, so the offset math is unit-tested directly.
pub fn parse_turns(bytes: &[u8], base: u64) -> (Vec<HydratedTurn>, u64) {
    let mut turns = Vec::new();
    let mut pos = 0usize;
    let mut consumed = 0usize;
    while let Some(rel) = bytes[pos..].iter().position(|&b| b == b'\n') {
        let end = pos + rel; // index of the '\n'
        if let Ok(s) = std::str::from_utf8(&bytes[pos..end]) {
            if let Some(t) = shape_turn_line(s) {
                turns.push(t);
            }
        }
        pos = end + 1; // step past the newline
        consumed = pos;
    }
    (turns, base + consumed as u64)
}

/// Read a transcript from byte offset `after` to EOF and shape the new turns,
/// returning them with the next offset. `after` at or past EOF (a caught-up client,
/// or a stale over-large offset) yields no turns and the current length. Append-only,
/// so the offset math is exact.
pub fn hydrate_from_file(path: &Path, after: u64) -> std::io::Result<(Vec<HydratedTurn>, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path)?;
    let len = file.metadata()?.len();
    if after >= len {
        return Ok((Vec::new(), len));
    }
    file.seek(SeekFrom::Start(after))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(parse_turns(&buf, after))
}

/// Query params for `GET /jesse/sessions/{id}`.
#[derive(Deserialize)]
pub struct HydrateQuery {
    /// Return only content appended after this byte offset (the append-only delta
    /// sync). Absent → the full transcript from offset 0.
    #[serde(default)]
    pub after: Option<u64>,
}

/// `GET /jesse/sessions/{session_id}` — hydrate one session's transcript into
/// ordered, client-renderable turns. Same bearer auth and rate limiter as
/// `/jesse/sessions`. `?after=<byte offset>` returns only the turns appended since,
/// with `next_offset` for the next round trip (the jsonl is append-only, so the
/// offset math is exact and a reconnecting client syncs in one small call).
///
/// - **`404`** for an unknown id, and for a title-mint transcript (Wart 1 — a
///   `POST /jesse/title` one-shot is not a real conversation; it is excluded from
///   the list AND rejected here, identically to an unknown id).
/// - **`400`** for a structurally-invalid id (not a plain filename component):
///   path-traversal defense, rejected before the filesystem is touched, so a
///   crafted id can never resolve outside the vault projects dir.
/// - **Malformed / partial lines never 500** — they are skipped (a partial trailing
///   line is returned on the next `?after=` call once complete).
pub async fn jesse_session_hydrate(
    State(st): State<AppState>,
    UrlPath(session_id): UrlPath<String>,
    headers: HeaderMap,
    Query(params): Query<HydrateQuery>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    // Path-traversal defense: a non-plain component can never name a file INSIDE the
    // projects dir; reject it before the filesystem is touched (same posture as the
    // DELETE endpoint), so a crafted id like `../../foo` can't escape the vault.
    if !is_plain_session_component(&session_id) {
        return Err((StatusCode::BAD_REQUEST, "invalid session id".to_string()));
    }
    let path = session_transcript_path(&st.cfg.home, &st.cfg.vault, &session_id);
    if !path.is_file() {
        return Err((StatusCode::NOT_FOUND, "unknown session".to_string()));
    }
    // Wart 1: a title-mint transcript is not a real conversation — 404 it, exactly as
    // it is excluded from GET /jesse/sessions. Checked on the RAW first user turn.
    if first_user_raw(&path)
        .as_deref()
        .map(is_title_mint_prompt)
        .unwrap_or(false)
    {
        return Err((StatusCode::NOT_FOUND, "unknown session".to_string()));
    }
    let after = params.after.unwrap_or(0);
    let (turns, next_offset) = hydrate_from_file(&path, after).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not read session transcript: {e}"),
        )
    })?;
    let body = serde_json::to_string(&json!({
        "session_id": session_id,
        "turns": turns,
        "next_offset": next_offset,
    }))
    .unwrap_or_else(|_| r#"{"turns":[]}"#.to_string());
    Ok((
        StatusCode::OK,
        [(
            axum::http::header::CONTENT_TYPE,
            "application/json".to_string(),
        )],
        body,
    )
        .into_response())
}

/// `DELETE /jesse/session/{session_id}` — delete one Claude Code session for the
/// bridge's vault, scoped to the vault project only. Same bearer auth as `/jesse`.
///
/// **Idempotent**, mirroring `POST /jesse/cancel`: an unknown or already-gone id
/// returns `204` (success), never an error — the app's durable delete-drainer
/// retries and the GC sweep must never choke on a missing id. A real failure to
/// delete a file that *exists* is a `500`. A structurally-invalid id (one that
/// isn't a plain filename component — empty, `.`/`..`, or containing a path
/// separator) is a `400`: it can only be a traversal attempt, never a real session
/// id, so it must never reach the filesystem.
pub async fn jesse_session_delete(
    State(st): State<AppState>,
    UrlPath(session_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    // Defensive: a non-plain component can never name a session inside the projects
    // dir; reject it up front so it can't reach `remove_file` (path traversal).
    if !is_plain_session_component(&session_id) {
        return Err((StatusCode::BAD_REQUEST, "invalid session id".to_string()));
    }
    let dir = st.sessions_dir();
    match delete_session_file(&dir, &session_id) {
        SessionDeleteOutcome::Deleted => {
            // Drop any stashed title AND flags so the reclaimed id can't linger in
            // titles.json / flags.json and resurrect a stale title or favorite.
            st.titles.remove(&session_id);
            st.flags.remove(&session_id);
            eprintln!("jesse-bridge: deleted session {session_id}");
            Ok(StatusCode::NO_CONTENT)
        }
        SessionDeleteOutcome::AlreadyGone => {
            // Idempotent: unknown / already-gone is success, not an error.
            st.titles.remove(&session_id);
            st.flags.remove(&session_id);
            eprintln!("jesse-bridge: session {session_id} already gone — no-op (idempotent)");
            Ok(StatusCode::NO_CONTENT)
        }
        SessionDeleteOutcome::Failed(msg) => {
            eprintln!("jesse-bridge: failed to delete session {session_id}: {msg}");
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("could not delete session: {msg}"),
            ))
        }
    }
}

/// `POST /jesse/session/{session_id}/flags` sets this session's favorite / archived
/// flags, so the bridge (not one device) is the source of truth and every device
/// converges. Same bearer auth, rate limiter, and id validation as the other
/// per-session routes.
///
/// The body carries any subset of `{ favorite, favorite_updated_ms, archived,
/// archived_updated_ms }`; each provided flag is applied **last-writer-wins** by its
/// client-supplied change timestamp (unix millis): a strictly newer timestamp wins,
/// an equal or older write is ignored, so out-of-order writes from different devices
/// converge deterministically. A partial body (one flag only) leaves the other flag
/// untouched. The resulting `SessionFlags` is returned.
///
/// - **`400`** for a structurally-invalid id (not a plain filename component):
///   path-traversal defense, rejected before the filesystem is touched.
/// - **`404`** for an unknown id (a session with no transcript on disk; a synthetic
///   `local-` id has none by construction), identical to the hydrate route.
pub async fn jesse_session_flags(
    State(st): State<AppState>,
    UrlPath(session_id): UrlPath<String>,
    headers: HeaderMap,
    Json(update): Json<FlagUpdate>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    // Path-traversal defense: a non-plain component can never name a file inside the
    // projects dir; reject it before the filesystem is touched (same as delete/hydrate).
    if !is_plain_session_component(&session_id) {
        return Err((StatusCode::BAD_REQUEST, "invalid session id".to_string()));
    }
    // Unknown id is a 404, exactly like the hydrate route: the session must have a
    // transcript on disk. (A synthetic `local-` id has none, so it 404s here; the
    // app syncs flags only for real sessions.)
    let path = session_transcript_path(&st.cfg.home, &st.cfg.vault, &session_id);
    if !path.is_file() {
        return Err((StatusCode::NOT_FOUND, "unknown session".to_string()));
    }
    let result = st.flags.apply(&session_id, &update);
    Ok(Json(json!({
        "favorite": result.favorite,
        "favorite_updated_ms": result.favorite_updated_ms,
        "archived": result.archived,
        "archived_updated_ms": result.archived_updated_ms,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_matches_the_verified_convention() {
        // Pinned against the real dirs verified on this machine (claude 2.1.208):
        // every non-alphanumeric char → '-', existing '-' kept, no run-collapsing.
        assert_eq!(
            escape_project_path("/Users/u/devel/tag1/jesse-app"),
            "-Users-u-devel-tag1-jesse-app"
        );
        // '_' and '.' both map to '-'.
        assert_eq!(
            escape_project_path("/private/tmp/jt_esc.mix-dir"),
            "-private-tmp-jt-esc-mix-dir"
        );
        // '/.' becomes '--' (no collapsing).
        assert_eq!(escape_project_path("/a/.claude/x"), "-a--claude-x");
    }

    #[test]
    fn vault_sessions_dir_joins_home_projects_and_escaped_vault() {
        let d = vault_sessions_dir("/home/bob", "/vault/notes");
        assert_eq!(d, PathBuf::from("/home/bob/.claude/projects/-vault-notes"));
    }

    #[test]
    fn extract_user_text_handles_string_and_block_array() {
        // Plain string content.
        let v: Value =
            serde_json::from_str(r#"{"type":"user","message":{"content":"hello there"}}"#).unwrap();
        assert_eq!(extract_user_text(&v).as_deref(), Some("hello there"));

        // Array-of-blocks content: join text blocks, ignore non-text blocks.
        let v: Value = serde_json::from_str(
            r#"{"type":"user","message":{"content":[
                 {"type":"text","text":"first"},
                 {"type":"tool_result","content":"noise"},
                 {"type":"text","text":"second"}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_user_text(&v).as_deref(), Some("first\nsecond"));

        // A non-user line yields None.
        let v: Value =
            serde_json::from_str(r#"{"type":"assistant","message":{"content":"hi"}}"#).unwrap();
        assert_eq!(extract_user_text(&v), None);

        // A user line with only non-text blocks yields None.
        let v: Value = serde_json::from_str(
            r#"{"type":"user","message":{"content":[{"type":"image","source":{}}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_user_text(&v), None);
    }

    fn temp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-sessions-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn write(dir: &Path, name: &str, contents: &str) {
        std::fs::write(dir.join(name), contents).unwrap();
    }

    #[test]
    fn missing_dir_lists_empty_not_error() {
        let missing = std::env::temp_dir().join(format!("jesse-nope-{}", random_hex()));
        let titles = TitleStore::new(None);
        let flags = FlagStore::new(None);
        assert!(list_sessions(&missing, None, &titles, &flags).is_empty());
    }

    #[test]
    fn first_user_message_reads_first_user_turn_only() {
        let dir = temp_dir();
        // A system line, then two user turns — the FIRST user turn is the snippet.
        let jsonl = concat!(
            r#"{"type":"system","subtype":"init","cwd":"/v"}"#,
            "\n",
            r#"{"type":"user","message":{"content":"the very first question"}}"#,
            "\n",
            r#"not valid json — must be skipped"#,
            "\n",
            r#"{"type":"user","message":{"content":"a later turn"}}"#,
            "\n",
        );
        write(&dir, "sess-1.jsonl", jsonl);
        let got = first_user_message(&dir.join("sess-1.jsonl"));
        assert_eq!(got.as_deref(), Some("the very first question"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn first_message_truncates_on_char_boundary_at_120() {
        let dir = temp_dir();
        let long = "é".repeat(200); // multibyte, well over 120 chars
        let line = format!(r#"{{"type":"user","message":{{"content":"{long}"}}}}"#);
        write(&dir, "s.jsonl", &format!("{line}\n"));
        let got = first_user_message(&dir.join("s.jsonl")).unwrap();
        assert_eq!(got.chars().count(), FIRST_MESSAGE_CHARS);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn no_user_turn_within_bound_is_null_not_error() {
        let dir = temp_dir();
        // Only non-user lines → first_message None, never an error.
        write(
            &dir,
            "s.jsonl",
            "{\"type\":\"system\"}\n{\"type\":\"assistant\",\"message\":{\"content\":\"hi\"}}\n",
        );
        assert_eq!(first_user_message(&dir.join("s.jsonl")), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn list_orders_newest_first_fills_titles_and_honors_since() {
        let dir = temp_dir();
        // Three sessions. Set distinct mtimes via filetime-free approach: write in
        // order and then bump mtimes explicitly.
        for (name, content) in [
            (
                "old.jsonl",
                r#"{"type":"user","message":{"content":"old q"}}"#,
            ),
            (
                "mid.jsonl",
                r#"{"type":"user","message":{"content":"mid q"}}"#,
            ),
            (
                "new.jsonl",
                r#"{"type":"user","message":{"content":"new q"}}"#,
            ),
        ] {
            write(&dir, name, &format!("{content}\n"));
        }
        // Also a non-jsonl file and a subdir — both must be ignored.
        write(&dir, "notes.txt", "ignore me");
        std::fs::create_dir_all(dir.join("subdir.jsonl")).unwrap();

        // Force a strict mtime ordering old < mid < new.
        set_mtime(&dir.join("old.jsonl"), 1_000);
        set_mtime(&dir.join("mid.jsonl"), 2_000);
        set_mtime(&dir.join("new.jsonl"), 3_000);

        let titles = TitleStore::new(None);
        titles.set("mid", "Middle Session");
        // Flags filled from the store; a session with no row lists false/0.
        let flags = FlagStore::new(None);
        flags.apply(
            "mid",
            &FlagUpdate {
                favorite: Some(true),
                favorite_updated_ms: Some(1_700),
                archived: Some(true),
                archived_updated_ms: Some(1_800),
            },
        );

        let all = list_sessions(&dir, None, &titles, &flags);
        let ids: Vec<&str> = all.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(
            ids,
            ["new", "mid", "old"],
            "newest first, non-jsonl/subdir ignored"
        );
        // Titles filled from the store; absent ones are null.
        let mid = all.iter().find(|s| s.session_id == "mid").unwrap();
        assert_eq!(mid.title.as_deref(), Some("Middle Session"));
        assert_eq!(mid.first_message.as_deref(), Some("mid q"));
        // Flags filled for the flagged session.
        assert!(mid.favorite && mid.favorite_updated_ms == 1_700);
        assert!(mid.archived && mid.archived_updated_ms == 1_800);
        let new = all.iter().find(|s| s.session_id == "new").unwrap();
        assert!(new.title.is_none());
        // An unflagged session defaults to false/0 on all four flag fields.
        assert!(!new.favorite && new.favorite_updated_ms == 0);
        assert!(!new.archived && new.archived_updated_ms == 0);

        // ?since strictly greater: since=2000 keeps only "new" (mtime 3000).
        let delta = list_sessions(&dir, Some(2_000), &titles, &flags);
        let ids: Vec<&str> = delta.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, ["new"], "since is strictly greater-than");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn etag_is_stable_and_input_sensitive() {
        let a = strong_etag(r#"{"sessions":[]}"#);
        let b = strong_etag(r#"{"sessions":[]}"#);
        let c = strong_etag(r#"{"sessions":[{"session_id":"x"}]}"#);
        assert_eq!(a, b, "same body → same strong ETag");
        assert_ne!(a, c, "different body → different ETag");
        assert!(
            a.starts_with('"') && a.ends_with('"'),
            "strong ETag is quoted"
        );
        assert!(!a.starts_with("W/"), "strong, not weak");
    }

    #[test]
    fn if_none_match_honors_exact_and_wildcard() {
        let tag = strong_etag("body");
        assert!(if_none_match_matches(&tag, &tag));
        assert!(if_none_match_matches("*", &tag));
        assert!(if_none_match_matches(&format!("\"other\", {tag}"), &tag));
        assert!(!if_none_match_matches("\"nope\"", &tag));
    }

    #[test]
    fn is_plain_session_component_rejects_traversal() {
        assert!(is_plain_session_component("0a61d246-abc"));
        assert!(is_plain_session_component("local-deadbeef"));
        // Rejected: empty, dot-dirs, and anything with a separator.
        assert!(!is_plain_session_component(""));
        assert!(!is_plain_session_component("."));
        assert!(!is_plain_session_component(".."));
        assert!(!is_plain_session_component("../secrets"));
        assert!(!is_plain_session_component("a/b"));
        assert!(!is_plain_session_component("a\\b"));
    }

    #[test]
    fn delete_session_file_is_idempotent_and_scoped() {
        let dir = temp_dir();
        write(&dir, "sess-1.jsonl", "{\"type\":\"user\"}\n");
        // First delete removes the existing file.
        assert_eq!(
            delete_session_file(&dir, "sess-1"),
            SessionDeleteOutcome::Deleted
        );
        assert!(!dir.join("sess-1.jsonl").exists(), "file is gone");
        // Second delete of the same (now-missing) id is idempotent success.
        assert_eq!(
            delete_session_file(&dir, "sess-1"),
            SessionDeleteOutcome::AlreadyGone
        );
        // An unknown id is idempotent success too.
        assert_eq!(
            delete_session_file(&dir, "never-existed"),
            SessionDeleteOutcome::AlreadyGone
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn is_session_expired_uses_a_strict_ttl_boundary() {
        let day = 86_400u64;
        let ttl_days = 90u64;
        let ttl = ttl_days * day;
        let now = 1_000 * day; // an arbitrary fixed clock, well past the epoch
                               // Younger than the TTL: kept.
        assert!(!is_session_expired(now - ttl + day, now, ttl_days));
        // EXACTLY at the TTL: kept (strictly-older only).
        assert!(!is_session_expired(now - ttl, now, ttl_days));
        // One second past the TTL: reclaimed.
        assert!(is_session_expired(now - ttl - 1, now, ttl_days));
        // A future mtime (clock skew) saturates to age 0 → never expired.
        assert!(!is_session_expired(now + day, now, ttl_days));
    }

    #[test]
    fn sweep_reclaims_only_sessions_older_than_the_ttl() {
        let dir = temp_dir();
        let day = 86_400u64;
        let now = 1_000 * day;
        let ttl_days = 90u64;
        // Three sessions at known ages; a non-jsonl file and a subdir to ignore.
        write(&dir, "fresh.jsonl", "{}\n"); // touched today
        write(&dir, "old.jsonl", "{}\n"); // 200 days old
        write(&dir, "borderline.jsonl", "{}\n"); // exactly at the TTL — kept
        write(&dir, "notes.txt", "ignore");
        std::fs::create_dir_all(dir.join("subdir.jsonl")).unwrap();
        set_mtime(&dir.join("fresh.jsonl"), now);
        set_mtime(&dir.join("old.jsonl"), now - 200 * day);
        set_mtime(&dir.join("borderline.jsonl"), now - ttl_days * day);

        let reclaimed = sweep_expired_sessions(&dir, now, ttl_days);
        let ids: Vec<&str> = reclaimed.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["old"], "only the >90d session is reclaimed");
        // The reclaimed session's age is reported (200 days).
        assert_eq!(reclaimed[0].1, 200 * day);
        // The kept ones survive; the sweep never touches the non-jsonl file or subdir.
        assert!(dir.join("fresh.jsonl").exists());
        assert!(dir.join("borderline.jsonl").exists());
        assert!(!dir.join("old.jsonl").exists());
        assert!(dir.join("notes.txt").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn sweep_missing_dir_reclaims_nothing() {
        let missing = std::env::temp_dir().join(format!("jesse-nogc-{}", random_hex()));
        assert!(sweep_expired_sessions(&missing, 1_000_000, 90).is_empty());
    }

    #[test]
    fn run_session_gc_reclaims_old_sessions_and_drops_their_titles() {
        // Wiring test over the cfg.home path (no global-env mutation): an ancient
        // session (mtime at the epoch, far past any TTL) is reclaimed and its stashed
        // title dropped; a fresh one survives.
        let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
        let vault = "/vault/gc";
        let dir = home
            .join(".claude")
            .join("projects")
            .join(escape_project_path(vault));
        std::fs::create_dir_all(&dir).unwrap();
        write(&dir, "ancient.jsonl", "{}\n");
        write(&dir, "fresh.jsonl", "{}\n");
        set_mtime(&dir.join("ancient.jsonl"), 0); // epoch → older than any TTL
                                                  // `fresh.jsonl` keeps its just-written (now) mtime.

        let mut cfg = crate::testutil::test_config();
        cfg.home = home.to_string_lossy().into_owned();
        cfg.vault = vault.to_string();
        cfg.session_ttl_days = 90;

        let titles = TitleStore::new(None);
        titles.set("ancient", "Old Title");
        titles.set("fresh", "New Title");
        // Flags for both sessions: the reclaimed one's row must be dropped too.
        let flags = FlagStore::new(None);
        flags.apply(
            "ancient",
            &FlagUpdate {
                favorite: Some(true),
                favorite_updated_ms: Some(1),
                ..FlagUpdate::default()
            },
        );
        flags.apply(
            "fresh",
            &FlagUpdate {
                favorite: Some(true),
                favorite_updated_ms: Some(1),
                ..FlagUpdate::default()
            },
        );

        run_session_gc(&cfg, &titles, &flags);

        assert!(
            !dir.join("ancient.jsonl").exists(),
            "ancient session reclaimed"
        );
        assert!(dir.join("fresh.jsonl").exists(), "fresh session kept");
        assert_eq!(titles.get("ancient"), None, "reclaimed title dropped");
        assert_eq!(
            titles.get("fresh").as_deref(),
            Some("New Title"),
            "kept title stays"
        );
        // The reclaimed session's flags row is dropped; the kept one's survives.
        assert_eq!(
            flags.get("ancient"),
            SessionFlags::default(),
            "reclaimed flags dropped"
        );
        assert!(flags.get("fresh").favorite, "kept flags stay");
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn effective_resume_id_drops_a_missing_real_session() {
        // Fresh turn: unchanged.
        assert_eq!(effective_resume_id(None, false), None);
        assert_eq!(effective_resume_id(None, true), None);
        // Synthetic id: passed through regardless of the existence bool.
        assert_eq!(
            effective_resume_id(Some("local-abc"), false),
            Some("local-abc")
        );
        // Real id, transcript present → resume it.
        assert_eq!(effective_resume_id(Some("real-1"), true), Some("real-1"));
        // Real id, transcript MISSING (swept/deleted) → fresh (None).
        assert_eq!(effective_resume_id(Some("real-1"), false), None);
    }

    #[test]
    fn resolve_resume_drops_a_deleted_session_end_to_end() {
        // Drive the whole cfg.home-based path (no global-env mutation): a present
        // transcript resumes; after it is deleted the same id is no longer resumable
        // (falls to a fresh session).
        let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
        let vault = "/vault/notes";
        let dir = home
            .join(".claude")
            .join("projects")
            .join(escape_project_path(vault));
        std::fs::create_dir_all(&dir).unwrap();

        let mut cfg = crate::testutil::test_config();
        cfg.home = home.to_string_lossy().into_owned();
        cfg.vault = vault.to_string();

        // No transcript yet → a real id is NOT resumable (fresh).
        assert_eq!(resolve_resume_session(&cfg, Some("sess-1")), None);
        // Create the transcript → the id resumes.
        write(&dir, "sess-1.jsonl", "{\"type\":\"user\"}\n");
        assert!(session_transcript_exists(&cfg, "sess-1"));
        assert_eq!(resolve_resume_session(&cfg, Some("sess-1")), Some("sess-1"));
        // Delete it (the DELETE endpoint's core op) → no longer resumable.
        assert_eq!(
            delete_session_file(&dir, "sess-1"),
            SessionDeleteOutcome::Deleted
        );
        assert!(!session_transcript_exists(&cfg, "sess-1"));
        assert_eq!(resolve_resume_session(&cfg, Some("sess-1")), None);
        // A synthetic id passes through untouched (never resumed downstream).
        assert_eq!(
            resolve_resume_session(&cfg, Some("local-abc")),
            Some("local-abc")
        );

        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn session_transcript_path_lands_under_the_projects_dir() {
        let p = session_transcript_path("/home/bob", "/vault/notes", "sess-9");
        assert_eq!(
            p,
            PathBuf::from("/home/bob/.claude/projects/-vault-notes/sess-9.jsonl")
        );
    }

    #[test]
    fn extract_assistant_text_joins_text_and_skips_tool_and_thinking() {
        // The real transcript shape: a content array of thinking/text/tool_use.
        let v: Value = serde_json::from_str(
            r#"{"type":"assistant","message":{"content":[
                 {"type":"thinking","thinking":"pondering"},
                 {"type":"text","text":"first"},
                 {"type":"tool_use","name":"Read","input":{}},
                 {"type":"text","text":"second"}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_assistant_text(&v).as_deref(), Some("first\nsecond"));
        // A tool-use-only assistant turn has no visible text.
        let v: Value = serde_json::from_str(
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_assistant_text(&v), None);
        // A user line yields None.
        let v: Value =
            serde_json::from_str(r#"{"type":"user","message":{"content":"hi"}}"#).unwrap();
        assert_eq!(extract_assistant_text(&v), None);
    }

    #[test]
    fn parse_turns_orders_turns_and_reports_the_full_offset() {
        let jsonl = concat!(
            r#"{"type":"system","subtype":"init"}"#,
            "\n",
            r#"{"type":"user","message":{"content":"first question"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"an answer"}]}}"#,
            "\n",
        );
        let (turns, offset) = parse_turns(jsonl.as_bytes(), 0);
        assert_eq!(offset, jsonl.len() as u64, "all complete lines consumed");
        assert_eq!(turns.len(), 2, "system line skipped");
        assert_eq!(turns[0].role, "user");
        assert_eq!(turns[0].text, "first question");
        assert_eq!(turns[1].role, "assistant");
        assert_eq!(turns[1].text, "an answer");
    }

    #[test]
    fn parse_turns_skips_noise_malformed_and_tool_results() {
        let jsonl = concat!(
            r#"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            "\n",
            r#"not valid json at all"#,
            "\n",
            r#"{"type":"user","isSidechain":true,"message":{"content":"subagent chatter"}}"#,
            "\n",
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"noise"}]}}"#,
            "\n",
            r#"{"type":"user","message":{"content":"a real question"}}"#,
            "\n",
        );
        let (turns, offset) = parse_turns(jsonl.as_bytes(), 0);
        assert_eq!(offset, jsonl.len() as u64);
        assert_eq!(turns.len(), 1, "only the real user turn survives");
        assert_eq!(turns[0].text, "a real question");
    }

    #[test]
    fn parse_turns_leaves_a_partial_trailing_line_unconsumed() {
        let complete = concat!(
            r#"{"type":"user","message":{"content":"q1"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"a1"}]}}"#,
            "\n",
        );
        // A partial line: no terminating newline yet (append-only file mid-write).
        let partial = r#"{"type":"user","message":{"content":"q2 in"#;
        let full = format!("{complete}{partial}");

        let (turns, offset) = parse_turns(full.as_bytes(), 0);
        assert_eq!(turns.len(), 2, "the partial line is NOT returned yet");
        assert_eq!(
            offset,
            complete.len() as u64,
            "offset points at the START of the partial line"
        );

        // The writer finishes the line; the next `?after=` call returns it.
        let rest = "complete\"}}\n";
        let appended = format!("{partial}{rest}");
        let (turns2, offset2) = parse_turns(appended.as_bytes(), offset);
        assert_eq!(turns2.len(), 1);
        assert_eq!(turns2[0].text, "q2 incomplete");
        // The whole appended line is now consumed, from where the partial started.
        assert_eq!(offset2, offset + appended.len() as u64);
    }

    #[test]
    fn hydrate_from_file_reads_the_delta_from_an_offset() {
        let dir = temp_dir();
        let path = dir.join("h.jsonl");
        let first = concat!(
            r#"{"type":"user","message":{"content":"q1"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"a1"}]}}"#,
            "\n",
        );
        std::fs::write(&path, first).unwrap();

        let (turns, offset) = hydrate_from_file(&path, 0).unwrap();
        assert_eq!(turns.len(), 2);
        assert_eq!(offset, first.len() as u64);

        // A caught-up client (after == len) gets nothing new, offset unchanged.
        let (none_yet, off2) = hydrate_from_file(&path, offset).unwrap();
        assert!(none_yet.is_empty());
        assert_eq!(off2, offset);

        // Append a turn; hydrating from the prior offset returns only the new one.
        let more = "{\"type\":\"user\",\"message\":{\"content\":\"q2\"}}\n";
        std::fs::write(&path, format!("{first}{more}")).unwrap();
        let (delta, off3) = hydrate_from_file(&path, offset).unwrap();
        assert_eq!(delta.len(), 1);
        assert_eq!(delta[0].text, "q2");
        assert_eq!(off3, (first.len() + more.len()) as u64);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn list_excludes_title_mint_transcripts() {
        let dir = temp_dir();
        // A title-mint transcript: its first user turn is the fixed instruction.
        let mint = format!(
            "{{\"type\":\"user\",\"message\":{{\"content\":{}}}}}\n",
            serde_json::to_string(&build_title_prompt("some conversation digest")).unwrap()
        );
        write(&dir, "mint.jsonl", &mint);
        // A real session.
        write(
            &dir,
            "real.jsonl",
            "{\"type\":\"user\",\"message\":{\"content\":\"what is on Today.md?\"}}\n",
        );
        let titles = TitleStore::new(None);
        let flags = FlagStore::new(None);
        let listed = list_sessions(&dir, None, &titles, &flags);
        let ids: Vec<&str> = listed.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(
            ids,
            ["real"],
            "title-mint transcript excluded from the list"
        );
        assert_eq!(
            listed[0].first_message.as_deref(),
            Some("what is on Today.md?")
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn first_message_strips_the_bridge_wrapper() {
        let dir = temp_dir();
        // A realistic wrapped first user turn (built by the real prompt builder).
        let wrapped = build_prompt_at(
            "Current date/time: Sunday, 2026-07-20 08:00 CEST (UTC+02:00).",
            "ask",
            "what is on Today.md?",
            false,
            false,
            None,
            None,
            None,
            false,
            false,
            &Persona::default(),
        )
        .unwrap();
        let line = format!(
            "{{\"type\":\"user\",\"message\":{{\"content\":{}}}}}\n",
            serde_json::to_string(&wrapped).unwrap()
        );
        write(&dir, "s.jsonl", &line);
        assert_eq!(
            first_user_message(&dir.join("s.jsonl")).as_deref(),
            Some("what is on Today.md?"),
            "the snippet is the user's words, not the wrapper"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Set a file's mtime to exactly `secs` since the unix epoch, dependency-free,
    /// via `std::fs::File::set_modified` — so the `since` filter and `last_modified`
    /// field can be asserted against known values.
    fn set_mtime(path: &Path, secs: u64) {
        let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs(secs))
            .unwrap();
    }
}
