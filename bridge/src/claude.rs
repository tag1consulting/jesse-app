use crate::*;

/// What one `claude -p --output-format json` run amounts to — decided from its
/// output rather than its exit status alone (see `interpret_claude_output`).
#[derive(Debug)]
pub enum ClaudeOutcome {
    Ok {
        result: String,
        session_id: Option<String>,
    },
    /// Transient upstream failure (5xx / 429 / 529) — worth retrying.
    Retryable { message: String, status: u64 },
    /// Non-retryable failure — surface the message as-is.
    Fatal { message: String },
}

/// Truncate to `n` chars without splitting a multibyte boundary. Used ONLY for
/// the short human-facing stderr/stdout error snippets, where "first N
/// characters" is the intent; the result body is capped in BYTES — see
/// `truncate_bytes_on_char_boundary`.
pub fn truncate_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// Truncate `s` to at most `max_bytes` BYTES, ending on a valid UTF-8 char
/// boundary (the largest boundary ≤ `max_bytes`). This is the correct cap for
/// `MAX_OUTPUT_BYTES`: `truncate_chars` counts CHARACTERS, so for multibyte
/// text (CJK, emoji) it could keep up to ~4× the intended byte budget — the M1
/// bug. The stream accumulator already caps in bytes (`stream_push_delta`), so
/// this makes the final stored result agree with it.
pub fn truncate_bytes_on_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Classify a parsed terminal `result` object into the bridge's Ok/Retryable/
/// Fatal outcome — the single place that decides what a finished `claude` turn
/// amounts to. Shared by `interpret_claude_output` (whole-buffer `json` mode)
/// and `parse_stream_line` (the terminal `result` line of `stream-json` mode),
/// so both modes classify identically. `raw` is the original text to fall back
/// to as the answer when a success envelope somehow lacks a `result` field
/// (only meaningful for the buffered path; `None` in streaming).
pub fn classify_result_value(v: &Value, raw: Option<&str>) -> ClaudeOutcome {
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
            Some(code) if code >= 500 || code == 429 => ClaudeOutcome::Retryable {
                message,
                status: code,
            },
            _ => ClaudeOutcome::Fatal { message },
        };
    }
    // Success envelope — same extraction the bridge has always done.
    let result = v
        .get("result")
        .and_then(|r| r.as_str())
        .or(raw)
        .unwrap_or("")
        .trim()
        .to_string();
    let session_id = v
        .get("session_id")
        .and_then(|s| s.as_str())
        .map(|s| s.to_string());
    ClaudeOutcome::Ok { result, session_id }
}

/// One line of `claude --output-format stream-json` decoded into what the bridge
/// cares about. The stream is NDJSON (one JSON object per line); most lines we
/// ignore. A pure mapping (no I/O) so it's unit-testable against captured
/// fixtures. See `bridge/README.md` for the verified event schema.
#[derive(Debug)]
pub enum StreamEvent {
    /// A chunk of the visible answer (a `text_delta` inside a `text` block).
    /// Thinking deltas carry a different delta type and are deliberately excluded.
    TextDelta(String),
    /// The agent started using a tool — surfaced as a coarse activity hint.
    ToolActivity { name: String },
    /// The terminal `result` line: classify it exactly as the buffered path does.
    Done(ClaudeOutcome),
    /// Anything else (init/system, rate-limit, message envelopes, thinking
    /// deltas, tool input deltas, …) — carries nothing the bridge needs.
    Ignore,
}

/// Map a single NDJSON line from `stream-json` to a `StreamEvent`. Non-JSON or
/// unrecognized lines are `Ignore`d (the terminal classification still comes
/// from the `result` line, or from the no-result fallback if it never arrives).
pub fn parse_stream_line(line: &str) -> StreamEvent {
    let line = line.trim();
    if line.is_empty() {
        return StreamEvent::Ignore;
    }
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return StreamEvent::Ignore;
    };
    match v.get("type").and_then(|t| t.as_str()) {
        // The one terminal line — feeds the existing Ok/Retryable/Fatal logic.
        Some("result") => StreamEvent::Done(classify_result_value(&v, None)),
        // Token-level events (emitted under --include-partial-messages). The
        // visible answer streams as `text_delta`s inside a `text` content block;
        // tool use announces itself with a `tool_use` content-block start.
        Some("stream_event") => {
            let event = v.get("event");
            match event.and_then(|e| e.get("type")).and_then(|t| t.as_str()) {
                Some("content_block_delta") => {
                    let delta = event.and_then(|e| e.get("delta"));
                    let is_text = delta
                        .and_then(|d| d.get("type"))
                        .and_then(|t| t.as_str())
                        == Some("text_delta");
                    match delta.and_then(|d| d.get("text")).and_then(|t| t.as_str()) {
                        Some(text) if is_text => StreamEvent::TextDelta(text.to_string()),
                        _ => StreamEvent::Ignore, // thinking/signature/input deltas
                    }
                }
                Some("content_block_start") => {
                    let block = event.and_then(|e| e.get("content_block"));
                    let is_tool = block
                        .and_then(|b| b.get("type"))
                        .and_then(|t| t.as_str())
                        == Some("tool_use");
                    match block.and_then(|b| b.get("name")).and_then(|n| n.as_str()) {
                        Some(name) if is_tool => StreamEvent::ToolActivity {
                            name: name.to_string(),
                        },
                        _ => StreamEvent::Ignore,
                    }
                }
                _ => StreamEvent::Ignore,
            }
        }
        _ => StreamEvent::Ignore,
    }
}

/// Interpret one `claude -p --output-format json` run. `claude` can exit
/// non-zero while still writing a JSON envelope whose `is_error` /
/// `api_error_status` carry the real cause (e.g. a transient upstream 500), so
/// parse stdout regardless of exit status and key off that — falling back to
/// exit status + stderr only when stdout isn't JSON.
pub fn interpret_claude_output(stdout: &str, stderr: &str, exit_success: bool) -> ClaudeOutcome {
    if let Ok(v) = serde_json::from_str::<Value>(stdout) {
        // The parsed envelope is the `result` object; classify it the one way,
        // shared with the streaming parser's terminal `result` line.
        return classify_result_value(&v, Some(stdout));
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

/// Decide the final outcome of a *streamed* turn from its terminal `result` line
/// (if one arrived) and the text already accumulated from the stream. The whole
/// point: a turn that produced a visible answer must never be delivered as an
/// empty bubble or discarded — the streamed text is the safety net under a
/// success envelope whose `result` field is empty/missing.
///
/// Captured `stream-json` shapes this handles (see `bridge/README.md`):
///   * `Ok` with real `result` text → that authoritative answer (the normal case;
///     verified that `--include-partial-messages` does NOT empty this field).
///   * `Ok` but `result` is empty/blank, yet tokens streamed → `Ok` with the
///     streamed text, keeping the result line's `session_id`. The answer already
///     reached the client live; an empty `result` field must not erase it.
///   * No terminal `result` line at all but tokens streamed → `Ok` with the
///     streamed text (claude emitted an answer, then exited without an error
///     envelope). `session_id` is unknown here, so `None`.
///   * `Retryable` / `Fatal` error envelope (`is_error: true`, e.g. an upstream
///     5xx or `error_max_turns`) → unchanged: still retried / surfaced. A real
///     failure is never papered over with mid-turn narration.
///   * No `result` line AND no streamed text → `Fatal` over stderr — a genuine
///     failure, surfaced (never a silent empty success).
pub fn resolve_stream_outcome(
    terminal: Option<ClaudeOutcome>,
    streamed: &str,
    stderr: &str,
) -> ClaudeOutcome {
    let streamed = streamed.trim();
    match terminal {
        // Success envelope: prefer the authoritative `result`, but fall back to
        // the streamed text when `result` came back empty/blank.
        Some(ClaudeOutcome::Ok { result, session_id }) => {
            if !result.trim().is_empty() {
                ClaudeOutcome::Ok { result, session_id }
            } else if !streamed.is_empty() {
                ClaudeOutcome::Ok {
                    result: streamed.to_string(),
                    session_id,
                }
            } else {
                // Success but no answer anywhere — never deliver an empty bubble.
                ClaudeOutcome::Fatal {
                    message: "claude returned an empty result and streamed no text"
                        .to_string(),
                }
            }
        }
        // Error envelopes (Retryable / Fatal) are surfaced/retried as-is.
        Some(other) => other,
        // No terminal `result` line. If the stream nonetheless carried an answer,
        // deliver it; otherwise this is a real failure — surface it via stderr.
        None => {
            if streamed.is_empty() {
                interpret_claude_output("", stderr, false)
            } else {
                ClaudeOutcome::Ok {
                    result: streamed.to_string(),
                    session_id: None,
                }
            }
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
pub fn build_claude_args(cfg: &Config, prompt: &str, session_id: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "-p".to_string(),
        prompt.to_string(),
        // Stream the turn as NDJSON so the bridge can read tokens as they arrive
        // and forward them live. `--verbose` is REQUIRED by `claude` whenever
        // `-p`/`--print` is combined with `--output-format stream-json` (it errors
        // out otherwise). `--include-partial-messages` upgrades the stream from
        // whole-message events to token-level `text_delta`s for true live output.
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
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

/// Build the base `claude` child `Command` shared by BOTH a main turn and a
/// title one-shot: the least-privilege args (`build_claude_args`), the vault cwd
/// (so CLAUDE.md auto-loads), piped stdio, and `kill_on_drop`. It sets NO
/// environment overrides — the child inherits the bridge's process env unchanged,
/// exactly as before. The title path layers its backend override on top via
/// `apply_title_env`; the main-turn path never does, which is the isolation
/// guarantee (proven by a dedicated test). Factored out so both paths stay
/// byte-identical except for that one deliberate difference.
pub fn build_claude_command(cfg: &Config, prompt: &str, session_id: Option<&str>) -> Command {
    let mut cmd = Command::new(&cfg.claude_bin);
    cmd.args(build_claude_args(cfg, prompt, session_id))
        .current_dir(&cfg.vault) // cwd = vault → CLAUDE.md auto-loads
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true); // killed if the timeout fires or the task is dropped
    cmd
}

/// Layer the title-backend override onto a TITLE child's `Command`. When the
/// override is configured (all three `JESSE_TITLE_*` vars set → `cfg.title_backend`
/// is `Some`), set `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL`
/// on THIS child only, so the title one-shot talks to the override backend while
/// every main-turn child keeps inheriting the ambient process env. A no-op when
/// unset — the title child then inherits the process env byte-for-byte, exactly as
/// before this feature. Call this ONLY on the title path; a main turn must never
/// invoke it (that is the main-turn isolation property).
pub fn apply_title_env(cmd: &mut Command, cfg: &Config) {
    if let Some((base_url, auth_token, model)) = &cfg.title_backend {
        cmd.env("ANTHROPIC_BASE_URL", base_url)
            .env("ANTHROPIC_AUTH_TOKEN", auth_token)
            .env("ANTHROPIC_MODEL", model);
    }
}

/// Layer the DIET-extract backend override onto the stateless extract child's
/// `Command`. Exact analogue of [`apply_title_env`], keyed off `cfg.diet_backend`
/// (all three `JESSE_DIET_*` vars set → `Some`). When configured, the extract
/// child — and ONLY that child — talks to the override backend; every main turn
/// and the hosted verify child keep inheriting the ambient process env. A no-op
/// when unset. Call this ONLY on the extract path; a main turn or the verify child
/// must never invoke it (the main-turn isolation property, mirrored from title).
pub fn apply_diet_env(cmd: &mut Command, cfg: &Config) {
    if let Some((base_url, auth_token, model)) = &cfg.diet_backend {
        cmd.env("ANTHROPIC_BASE_URL", base_url)
            .env("ANTHROPIC_AUTH_TOKEN", auth_token)
            .env("ANTHROPIC_MODEL", model);
    }
}

/// Tools DENIED to the stateless diet children (extract + verify). The empty
/// allowlist below already denies everything under `--permission-mode default`
/// (an unlisted tool raises a permission prompt a headless `-p` child cannot
/// answer, so it is denied — the same reasoning as the main allowlist in
/// `config.rs`). This explicit class-level denylist is belt-and-suspenders: it
/// removes the mutation / execution / network tool CLASSES outright regardless of
/// how a given `claude` build interprets an empty `--allowedTools`, so a diet child
/// can never write, run a shell, or reach the network. It receives its whole
/// contract inline in the prompt and returns JSON text only.
pub const DIET_CHILD_DISALLOWED_TOOLS: &str =
    "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task";

/// Build the base `Command` for a stateless diet CHILD (extract or verify): the
/// same `stream-json` + `--permission-mode default` posture as every other child,
/// but with an EMPTY `--allowedTools` (the child holds no tools at all) plus the
/// class-level [`DIET_CHILD_DISALLOWED_TOOLS`] denylist. Unlike a turn or a title
/// call it does NOT set the vault as cwd — the extract/verify contract is inlined
/// in the prompt, so the child needs no vault context and must not auto-load the
/// large vault `CLAUDE.md`; cwd is the neutral scratch base. Sets NO env overrides
/// (callers layer `apply_diet_env` for extract, nothing for the ambient verify).
pub fn build_diet_child_command(cfg: &Config, prompt: &str) -> Command {
    let mut cmd = Command::new(&cfg.claude_bin);
    // Empty allowlist — the diet children hold NO tools (see the module const and
    // the reasoning above). Ignore cfg.allowed_tools entirely.
    let allowed = String::new();
    cmd.args([
        "-p".to_string(),
        prompt.to_string(),
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
        "--permission-mode".to_string(),
        "default".to_string(),
        "--allowedTools".to_string(),
        allowed,
        "--disallowedTools".to_string(),
        DIET_CHILD_DISALLOWED_TOOLS.to_string(),
    ])
    .current_dir(cfg.scratch_base()) // neutral cwd → no vault CLAUDE.md auto-load
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .kill_on_drop(true);
    cmd
}

/// Spawn a pre-built stateless one-shot `Command` and return its answer text.
/// Shared by [`run_diet_extract`] and [`run_diet_verify`]: it reuses the exact same
/// `stream-json` line reading, terminal-`result` classification
/// (`parse_stream_line` + `resolve_stream_outcome`), and bounded-reap discipline as
/// a turn, but creates no job, pushes no stream, resumes no session, persists
/// nothing. The caller has already layered any env override (or none) and set the
/// tool posture on `cmd`. No retry loop — a diet one-shot is best-effort and the
/// pipeline degrades to the hosted path on any non-2xx. `label` names the child in
/// the timeout message.
async fn run_stateless_oneshot(
    cfg: &Config,
    mut cmd: Command,
    timeout_secs: u64,
    label: &str,
) -> Result<String, ApiError> {
    let mut child = cmd.spawn().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to spawn {}: {e}", cfg.claude_bin),
        )
    })?;
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "claude child stdout/stderr pipe was not captured".to_string(),
        ));
    };

    // Drain stderr concurrently (capped) so a chatty stderr can't deadlock stdout
    // and the no-`result` fallback has the failure cause.
    let stderr_task = tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf).await;
        let cap = buf.len().min(MAX_OUTPUT_BYTES);
        String::from_utf8_lossy(&buf[..cap]).into_owned()
    });

    // Read stdout line by line into a LOCAL buffer, stopping at the terminal
    // `result` line — the same completion rule as a turn.
    let read_lines = async {
        let mut lines = BufReader::new(stdout).lines();
        let mut terminal: Option<ClaudeOutcome> = None;
        let mut streamed = String::new();
        loop {
            let next = lines
                .next_line()
                .await
                .map_err(|e| (StatusCode::BAD_GATEWAY, format!("claude io error: {e}")))?;
            let Some(line) = next else { break };
            match parse_stream_line(&line) {
                StreamEvent::TextDelta(t) => {
                    if streamed.len() < MAX_OUTPUT_BYTES {
                        streamed.push_str(&t);
                    }
                }
                StreamEvent::Done(outcome) => {
                    terminal = Some(outcome);
                    break;
                }
                StreamEvent::ToolActivity { .. } | StreamEvent::Ignore => {}
            }
        }
        Ok::<(Option<ClaudeOutcome>, String), ApiError>((terminal, streamed))
    };

    let (terminal, streamed) = match timeout(Duration::from_secs(timeout_secs), read_lines).await {
        Ok(r) => r?,
        Err(_) => {
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                format!("{label} exceeded the {timeout_secs}s limit"),
            ));
        }
    };

    // Bounded reap — once the authoritative result is in, a lingering child must
    // never delay delivery. Mirrors the turn / title paths.
    const REAP_TIMEOUT: Duration = Duration::from_secs(5);
    let stderr = if terminal.is_some() {
        tokio::spawn(async move {
            if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
                let _ = child.start_kill();
            }
            stderr_task.abort();
        });
        String::new()
    } else {
        if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
            let _ = child.start_kill();
        }
        match timeout(REAP_TIMEOUT, stderr_task).await {
            Ok(joined) => joined.unwrap_or_default(),
            Err(_) => String::new(),
        }
    };

    match resolve_stream_outcome(terminal, &streamed, &stderr) {
        ClaudeOutcome::Ok { result, .. } => Ok(result),
        ClaudeOutcome::Fatal { message } | ClaudeOutcome::Retryable { message, .. } => {
            Err((StatusCode::BAD_GATEWAY, message))
        }
    }
}

/// The stateless diet EXTRACT one-shot: parse a raw food/exercise/weigh-in
/// utterance into structured JSON entries. Runs a toolless child
/// ([`build_diet_child_command`]) pointed at the diet-extract backend
/// ([`apply_diet_env`]) when configured; returns the child's raw JSON text for the
/// pipeline to validate. Emits ONE provenance line (base URL + model, never the
/// token, no utterance content) so an audit can tell which backend served the
/// extraction. Any spawn/timeout/upstream failure is a non-2xx the pipeline treats
/// as ladder rung 2 (fall through to the hosted turn).
pub async fn run_diet_extract(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
) -> Result<String, ApiError> {
    let mut cmd = build_diet_child_command(cfg, prompt);
    apply_diet_env(&mut cmd, cfg);
    match &cfg.diet_backend {
        Some((base_url, _token, model)) => eprintln!(
            "jesse-bridge: diet extract → override backend base_url={base_url} model={model}"
        ),
        None => eprintln!("jesse-bridge: diet extract → ambient backend (no JESSE_DIET_* override)"),
    }
    run_stateless_oneshot(cfg, cmd, timeout_secs, "diet extraction").await
}

/// The stateless diet VERIFY one-shot: a hosted judgment call that never touches
/// the diet (or title) backend. Runs a toolless child with NO env override, so it
/// uses the AMBIENT credentials — that is the whole point of the verify gate: the
/// candidate entries came from a cheap local model, and a trusted hosted model
/// checks them before anything is written. Returns the child's raw JSON verdicts.
pub async fn run_diet_verify(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
) -> Result<String, ApiError> {
    // Deliberately NO apply_diet_env / apply_title_env — the verify child is ambient.
    let cmd = build_diet_child_command(cfg, prompt);
    run_stateless_oneshot(cfg, cmd, timeout_secs, "diet verification").await
}

/// Invoke headless Claude Code in the vault, streaming its output. Returns
/// (reply_text, session_id). Pass session_id to continue a thread; the returned
/// id is always captured so the client can follow up later. Resuming keeps
/// CLAUDE.md loaded and retains filesystem access — it only adds the prior
/// conversation on top.
///
/// Unlike the old buffered path, this reads `claude`'s `stream-json` stdout LINE
/// BY LINE as tokens arrive, pushing each text delta and tool-activity hint onto
/// the job's broadcast stream (`jobs.stream_*`) so subscribers see the reply
/// build live. The terminal `result` line is classified by the exact same
/// Ok/Retryable/Fatal logic as before, and that classified result — not the
/// streamed deltas — is the authoritative value returned and persisted.
///
/// Retries transient upstream failures (5xx/429/529) up to 3 attempts total.
/// A retry re-runs the WHOLE prompt: a transient that lands *mid-Tell* (after an
/// action was already applied) could in principle double-apply it on the rerun.
/// Accepted, because the observed transient fails at the API before any work
/// (0 tokens, $0) — there is nothing to repeat — but the tradeoff is explicit
/// here in case that ever changes. Only `Retryable` outcomes retry; spawn/io/
/// timeout failures (which happen before any output exists) do not. `kill_on_drop`,
/// the per-attempt timeout, and the 3-attempt retry are all preserved.
pub async fn run_claude_streaming(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
    jobs: &JobStore,
    job_id: &str,
) -> Result<(String, Option<String>), ApiError> {
    const MAX_ATTEMPTS: u32 = 3; // 1 try + 2 retries

    // A manual `loop` (not `for attempt in 1..=MAX_ATTEMPTS`) so the terminal
    // outcome is the loop's `break` value and the function is statically total:
    // every path breaks or `continue`s, so there is no post-loop `unreachable!()`
    // the compiler couldn't prove was dead.
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        // Fresh Command per attempt — same args, including --resume if present.
        // Tool access is constrained by the explicit allow/deny lists in
        // build_claude_args (C1); the agent runs under --permission-mode default.
        // A main turn deliberately does NOT call apply_title_env: the title-backend
        // override touches the title child only, never a real agent turn.
        let mut cmd = build_claude_command(cfg, prompt, session_id);

        let mut child = cmd.spawn().map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to spawn {}: {e}", cfg.claude_bin),
            )
        })?;
        // Map a missing pipe to an error rather than `.expect()` (M2): a panic
        // here on the spawned turn task would otherwise leave the job stuck
        // Running forever (complete never called). Both are configured
        // `Stdio::piped()` above, so this is belt-and-suspenders.
        let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "claude child stdout/stderr pipe was not captured".to_string(),
            ));
        };

        // Drain stderr concurrently (capped), so a chatty stderr can't deadlock
        // the stdout pipe and so the no-`result` fallback below has the cause.
        let stderr_task = tokio::spawn(async move {
            let mut reader = BufReader::new(stderr);
            let mut buf = Vec::new();
            // Bounded by `claude`'s own stderr volume, then truncated for storage.
            let _ = reader.read_to_end(&mut buf).await;
            let cap = buf.len().min(MAX_OUTPUT_BYTES);
            String::from_utf8_lossy(&buf[..cap]).into_owned()
        });

        // Read stdout line by line, mapping each NDJSON line and pushing live
        // frames, and STOP as soon as the terminal `result` line is parsed.
        // Completion must be driven by that result line, never by stdout EOF:
        // EOF only arrives once `claude` AND every grandchild that inherited its
        // stdout fd (the MCP servers it launches — QMD, Home Assistant, …) close
        // the pipe, so a single lingering subprocess would otherwise block this
        // read until the per-attempt timeout, pinning the job as Running long
        // after the answer (and its `result` line) already arrived. The
        // stream-json contract emits exactly one terminal `result` line and it is
        // the last meaningful line, so breaking on it still satisfies "the last
        // result line wins." The no-`result` fallback below (clean EOF with
        // accumulated streamed text) is preserved: that path is reached only when
        // the loop ends via `next_line() == None` without ever seeing a `Done`.
        let read_lines = async {
            let mut lines = BufReader::new(stdout).lines();
            let mut terminal: Option<ClaudeOutcome> = None;
            loop {
                let next = lines.next_line().await.map_err(|e| {
                    (StatusCode::BAD_GATEWAY, format!("claude io error: {e}"))
                })?;
                let Some(line) = next else { break };
                match parse_stream_line(&line) {
                    StreamEvent::TextDelta(t) => jobs.stream_push_delta(job_id, &t),
                    StreamEvent::ToolActivity { name } => jobs.stream_push_activity(job_id, &name),
                    StreamEvent::Done(outcome) => {
                        terminal = Some(outcome);
                        break;
                    }
                    StreamEvent::Ignore => {}
                }
            }
            Ok::<Option<ClaudeOutcome>, ApiError>(terminal)
        };

        // "Unlimited" (timeout_secs == 0) is a debug-only affordance and never
        // compiled into a release build; Config::from_env clamps 0 to the
        // ceiling, so in release timeout_secs is always >= 1 and bounded.
        #[cfg(debug_assertions)]
        let unlimited = cfg.timeout_secs == 0;
        #[cfg(not(debug_assertions))]
        let unlimited = false;

        // kill_on_drop reaps the child if this future is dropped (timeout / task abort).
        let terminal = if unlimited {
            read_lines.await?
        } else {
            match timeout(Duration::from_secs(cfg.timeout_secs), read_lines).await {
                Ok(r) => r?,
                Err(_) => {
                    return Err((
                        StatusCode::GATEWAY_TIMEOUT,
                        format!(
                            "Jesse hit the {}s run limit. Raise JESSE_TIMEOUT to allow longer turns.",
                            cfg.timeout_secs
                        ),
                    ))
                }
            }
        };

        // Reap the child and collect its stderr — but BOUND both waits so a
        // child (or, more likely, a grandchild MCP server that inherited
        // claude's stdio) that won't exit can't pin this task. Once the result
        // line is parsed the answer is authoritative; reaping is cleanup that
        // must never delay or block delivery.
        const REAP_TIMEOUT: Duration = Duration::from_secs(5);
        let stderr = if terminal.is_some() {
            // We already have the authoritative `result` line, so stderr is
            // irrelevant to the outcome (it only feeds the no-`result` Fatal
            // cause). Don't wait on the child tree at all here — a lingering
            // grandchild holding the pipe open is exactly the hang this fixes.
            // Reap in the background, bounded, with an explicit kill; abandon
            // the stderr drain so a held-open stderr fd can't leak the task.
            tokio::spawn(async move {
                if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
                    // kill_on_drop is the backstop; make the kill explicit.
                    let _ = child.start_kill();
                }
                stderr_task.abort();
            });
            String::new()
        } else {
            // No `result` line: clean EOF after streaming (or a genuine
            // failure). stdout already hit EOF, so the process is finishing and
            // these waits normally return at once — but bound them anyway so a
            // grandchild holding a pipe open can't block the fallback path.
            if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
                let _ = child.start_kill();
            }
            match timeout(REAP_TIMEOUT, stderr_task).await {
                Ok(joined) => joined.unwrap_or_default(),
                Err(_) => String::new(),
            }
        };

        // Decide the outcome from the terminal `result` line AND the text already
        // accumulated from the stream, so a turn that produced a visible answer is
        // never delivered empty or discarded: an empty/missing `result` on an
        // otherwise-successful turn falls back to the streamed text. Error
        // envelopes (Retryable/Fatal) and the genuine no-answer case are surfaced
        // unchanged. See `resolve_stream_outcome`.
        let streamed = jobs.stream_snapshot(job_id).unwrap_or_default();
        let outcome = resolve_stream_outcome(terminal, &streamed, &stderr);

        match outcome {
            ClaudeOutcome::Ok { result, session_id } => {
                // Cap the stored reply at MAX_OUTPUT_BYTES *bytes* on a char
                // boundary (M1) — not chars, which for multibyte text could keep
                // up to ~4× the budget. This matches the byte-based stream cap.
                break Ok((
                    truncate_bytes_on_char_boundary(&result, MAX_OUTPUT_BYTES).to_string(),
                    session_id,
                ));
            }
            ClaudeOutcome::Fatal { message } => break Err((StatusCode::BAD_GATEWAY, message)),
            ClaudeOutcome::Retryable { message, status } => {
                if attempt < MAX_ATTEMPTS {
                    eprintln!(
                        "claude transient failure (status {status}, attempt \
                         {attempt}/{MAX_ATTEMPTS}): {message} — retrying"
                    );
                    // The whole prompt re-runs; clear any partial accumulation so
                    // a reconnecting subscriber doesn't see a doubled buffer.
                    jobs.stream_reset(job_id);
                    // Short linear backoff: 1s after attempt 1, 2s after attempt 2.
                    tokio::time::sleep(Duration::from_secs(attempt as u64)).await;
                    continue;
                }
                // Out of attempts — surface the real upstream message. This is the
                // last attempt (`attempt == MAX_ATTEMPTS`), so the loop always
                // breaks here and never spins past its budget.
                break Err((StatusCode::BAD_GATEWAY, message));
            }
        }
    }
}

/// A stateless, single `claude -p` invocation — the primitive behind
/// `POST /jesse/title`. It reuses the exact same least-privilege args
/// (`build_claude_args`, so identical `--permission-mode`/allow/deny posture),
/// the same `kill_on_drop`, the same terminal-`result`-line classification
/// (`parse_stream_line` + `resolve_stream_outcome`), and the same bounded-reap
/// discipline as a turn — but creates NO job, pushes NO live stream, resumes NO
/// session, persists NOTHING, and touches none of the jobs/streams/aborts
/// mutexes. The caller passes a short `timeout_secs` (see `TITLE_TIMEOUT_SECS`).
///
/// Unlike `run_claude_streaming` there is no retry loop: the title path is a
/// best-effort UI nicety the caller degrades from on any non-2xx, so a single
/// bounded attempt keeps latency tight rather than re-running on an upstream blip.
/// The streamed text is still accumulated locally as the empty-`result` fallback,
/// so a success envelope with a blank `result` still yields the visible answer.
pub async fn run_claude_oneshot(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
) -> Result<String, ApiError> {
    // Same args as a turn (stream-json + the least-privilege allow/deny lists),
    // no --resume: a title call is never part of a thread.
    let mut cmd = build_claude_command(cfg, prompt, None);
    // Title-only backend override: point THIS child at the configured
    // base_url/token/model when all three JESSE_TITLE_* vars are set. A no-op
    // otherwise (ambient backend). Main turns never call this.
    apply_title_env(&mut cmd, cfg);
    // Provenance trail: one line per title call naming which backend served it
    // (base URL + model, never the token; no prompt content) so a production
    // audit can tell whether a title went to the override or the ambient backend.
    match &cfg.title_backend {
        Some((base_url, _token, model)) => {
            eprintln!("jesse-bridge: title call → override backend base_url={base_url} model={model}")
        }
        None => eprintln!("jesse-bridge: title call → ambient backend (no JESSE_TITLE_* override)"),
    }

    let mut child = cmd.spawn().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to spawn {}: {e}", cfg.claude_bin),
        )
    })?;
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "claude child stdout/stderr pipe was not captured".to_string(),
        ));
    };

    // Drain stderr concurrently (capped) so a chatty stderr can't deadlock the
    // stdout pipe and so the no-`result` fallback has the failure cause.
    let stderr_task = tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf).await;
        let cap = buf.len().min(MAX_OUTPUT_BYTES);
        String::from_utf8_lossy(&buf[..cap]).into_owned()
    });

    // Read stdout line by line, accumulating text deltas into a LOCAL buffer
    // (not a job store) and stopping the instant the terminal `result` line is
    // parsed — the same completion rule as a turn.
    let read_lines = async {
        let mut lines = BufReader::new(stdout).lines();
        let mut terminal: Option<ClaudeOutcome> = None;
        let mut streamed = String::new();
        loop {
            let next = lines
                .next_line()
                .await
                .map_err(|e| (StatusCode::BAD_GATEWAY, format!("claude io error: {e}")))?;
            let Some(line) = next else { break };
            match parse_stream_line(&line) {
                StreamEvent::TextDelta(t) => {
                    if streamed.len() < MAX_OUTPUT_BYTES {
                        streamed.push_str(&t);
                    }
                }
                StreamEvent::Done(outcome) => {
                    terminal = Some(outcome);
                    break;
                }
                StreamEvent::ToolActivity { .. } | StreamEvent::Ignore => {}
            }
        }
        Ok::<(Option<ClaudeOutcome>, String), ApiError>((terminal, streamed))
    };

    let (terminal, streamed) = match timeout(Duration::from_secs(timeout_secs), read_lines).await {
        Ok(r) => r?,
        Err(_) => {
            // Timed out — kill_on_drop reaps the child as this future drops.
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                format!("title generation exceeded the {timeout_secs}s limit"),
            ));
        }
    };

    // Bounded reap — once we have the authoritative result the child (or a
    // lingering grandchild) must never delay delivery. Mirrors the turn path.
    const REAP_TIMEOUT: Duration = Duration::from_secs(5);
    let stderr = if terminal.is_some() {
        tokio::spawn(async move {
            if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
                let _ = child.start_kill();
            }
            stderr_task.abort();
        });
        String::new()
    } else {
        if timeout(REAP_TIMEOUT, child.wait()).await.is_err() {
            let _ = child.start_kill();
        }
        match timeout(REAP_TIMEOUT, stderr_task).await {
            Ok(joined) => joined.unwrap_or_default(),
            Err(_) => String::new(),
        }
    };

    // Same Ok/Retryable/Fatal classification as a turn. No retry: a Retryable
    // upstream blip is surfaced as a non-2xx the caller degrades from.
    match resolve_stream_outcome(terminal, &streamed, &stderr) {
        ClaudeOutcome::Ok { result, .. } => Ok(result),
        ClaudeOutcome::Fatal { message } | ClaudeOutcome::Retryable { message, .. } => {
            Err((StatusCode::BAD_GATEWAY, message))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    const FX_SUCCESS: &str = include_str!("../tests/fixtures/stream/success.ndjson");
    const FX_EMPTY_RESULT: &str =
        include_str!("../tests/fixtures/stream/empty_result_success.ndjson");
    const FX_MISSING_RESULT: &str =
        include_str!("../tests/fixtures/stream/missing_result.ndjson");
    const FX_MAX_TURNS: &str = include_str!("../tests/fixtures/stream/error_max_turns.ndjson");
    /// Replay a captured `stream-json` turn exactly as `run_claude_streaming`
    /// does: accumulate `text_delta`s, keep the last terminal `result`, then let
    /// `resolve_stream_outcome` decide. `stderr` stands in for the drained child
    /// stderr the real path passes.
    fn replay_outcome(fixture: &str, stderr: &str) -> ClaudeOutcome {
        let mut streamed = String::new();
        let mut terminal: Option<ClaudeOutcome> = None;
        for line in fixture.lines() {
            match parse_stream_line(line) {
                StreamEvent::TextDelta(t) => streamed.push_str(&t),
                StreamEvent::Done(o) => terminal = Some(o),
                StreamEvent::ToolActivity { .. } | StreamEvent::Ignore => {}
            }
        }
        resolve_stream_outcome(terminal, &streamed, stderr)
    }
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
    #[test]
    fn parse_text_delta_is_extracted() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}},"session_id":"s"}"#;
        match parse_stream_line(line) {
            StreamEvent::TextDelta(t) => assert_eq!(t, "Hello "),
            other => panic!("expected TextDelta, got {other:?}"),
        }
    }
    #[test]
    fn parse_thinking_delta_is_ignored() {
        // Thinking streams as `thinking_delta`/`signature_delta`, never as the
        // visible answer — it must NOT be accumulated.
        let thinking = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}}"#;
        assert!(matches!(parse_stream_line(thinking), StreamEvent::Ignore));
        let sig = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}}"#;
        assert!(matches!(parse_stream_line(sig), StreamEvent::Ignore));
    }
    #[test]
    fn parse_tool_use_start_is_activity() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}}"#;
        match parse_stream_line(line) {
            StreamEvent::ToolActivity { name } => assert_eq!(name, "Read"),
            other => panic!("expected ToolActivity, got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_ok() {
        let line = r#"{"type":"result","subtype":"success","is_error":false,"result":"the answer","session_id":"sess-9"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Ok { result, session_id }) => {
                assert_eq!(result, "the answer");
                assert_eq!(session_id.as_deref(), Some("sess-9"));
            }
            other => panic!("expected Done(Ok), got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_5xx_is_retryable() {
        let line = r#"{"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"overloaded"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Retryable { status, .. }) => assert_eq!(status, 529),
            other => panic!("expected Done(Retryable), got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_4xx_is_fatal() {
        let line = r#"{"type":"result","is_error":true,"api_error_status":400,"result":"bad request"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Fatal { message }) => assert!(message.contains("bad request")),
            other => panic!("expected Done(Fatal), got {other:?}"),
        }
    }
    #[test]
    fn parse_non_json_and_noise_lines_are_ignored() {
        assert!(matches!(parse_stream_line("not json at all"), StreamEvent::Ignore));
        assert!(matches!(parse_stream_line("   "), StreamEvent::Ignore));
        let init = r#"{"type":"system","subtype":"init","session_id":"s","tools":[]}"#;
        assert!(matches!(parse_stream_line(init), StreamEvent::Ignore));
        let rate = r#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#;
        assert!(matches!(parse_stream_line(rate), StreamEvent::Ignore));
    }
    #[test]
    fn build_claude_args_requests_partial_stream_json() {
        // The streaming contract: stream-json + the two flags `claude` requires
        // for token-level deltas under `-p`.
        let args = build_claude_args(&test_config(), "hi", None);
        let pos = |needle: &str| args.iter().position(|a| a == needle);
        let of = pos("--output-format").expect("--output-format present");
        assert_eq!(args[of + 1], "stream-json");
        assert!(pos("--verbose").is_some(), "stream-json + -p requires --verbose");
        assert!(
            pos("--include-partial-messages").is_some(),
            "token-level deltas require --include-partial-messages"
        );
    }
    #[test]
    fn real_success_turn_yields_full_result_text() {
        // Normal turn: the authoritative `result` text is delivered verbatim.
        match replay_outcome(FX_SUCCESS, "") {
            ClaudeOutcome::Ok { result, session_id } => {
                assert!(
                    result.contains("This vault is") && result.len() > 600,
                    "expected the full ~693-char answer, got {} chars",
                    result.len()
                );
                assert_eq!(session_id.as_deref(), Some("0a61d246-062e-4910-b825-44ebd04f0bbd"));
            }
            other => panic!("expected Ok with full text, got {other:?}"),
        }
    }
    #[test]
    fn empty_result_success_falls_back_to_streamed_text() {
        // Success envelope but `result` is "" — must deliver the streamed answer
        // (not an empty bubble), keeping the result line's session_id.
        match replay_outcome(FX_EMPTY_RESULT, "") {
            ClaudeOutcome::Ok { result, session_id } => {
                assert!(
                    result.contains("This vault is") && !result.trim().is_empty(),
                    "empty `result` should fall back to streamed text, got {result:?}"
                );
                assert_eq!(session_id.as_deref(), Some("0a61d246-062e-4910-b825-44ebd04f0bbd"));
            }
            other => panic!("expected Ok with streamed text, got {other:?}"),
        }
    }
    #[test]
    fn missing_result_line_with_streamed_text_yields_streamed_text() {
        // No terminal `result` line at all, but the turn streamed an answer →
        // deliver it (not the old unconditional Fatal). session_id is unknown.
        match replay_outcome(FX_MISSING_RESULT, "") {
            ClaudeOutcome::Ok { result, session_id } => {
                assert!(result.contains("This vault is"), "got {result:?}");
                assert!(session_id.is_none(), "no result line → no session_id");
            }
            other => panic!("expected Ok with streamed text, got {other:?}"),
        }
    }
    #[test]
    fn no_result_and_no_text_is_fatal_with_message() {
        // The genuine failure: nothing streamed and no result line. Must be a
        // Fatal carrying the stderr cause — never a blank Ok.
        match resolve_stream_outcome(None, "", "claude: connection reset") {
            ClaudeOutcome::Fatal { message } => {
                assert!(!message.trim().is_empty(), "Fatal must carry a message");
                assert!(message.contains("connection reset"), "got {message:?}");
            }
            other => panic!("expected Fatal, got {other:?}"),
        }
    }
    #[test]
    fn error_envelope_with_streamed_text_stays_fatal() {
        // A real error envelope (error_max_turns, is_error: true, result: null)
        // must still surface as a failure even though narration text streamed —
        // mid-turn narration is not the answer and must not masquerade as one.
        assert!(
            matches!(replay_outcome(FX_MAX_TURNS, ""), ClaudeOutcome::Fatal { .. }),
            "error envelope must stay Fatal, not be replaced by streamed narration"
        );
    }
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

        // `node` is granted ONLY for the three named diet-cache scripts — never a
        // bare `Bash(node:*)`, which would permit `node -e "<arbitrary JS>"` (RCE
        // from a phone request). Pin both the presence of the scoped scripts and
        // the absence of any broader node scope.
        for script in [
            "Bash(node todo-list/generate-diet-today.js:*)",
            "Bash(node todo-list/validate-diet-today.js:*)",
            "Bash(node todo-list/verify-diet-consistency.js:*)",
        ] {
            assert!(
                tools.contains(&script),
                "expected scoped node script {script:?} in: {tools:?}"
            );
        }
        assert!(
            !tools.iter().any(|t| *t == "Bash(node:*)" || *t == "Bash(node)"),
            "a bare node scope (arbitrary-JS RCE) must never be allowed: {tools:?}"
        );

        // The Skill tool is granted ONLY for the named `diet-logging` skill — never
        // a bare `Skill`, which would let any future vault skill run from a phone
        // request. The Skill tool loads instruction text only; real actions still
        // go through the scoped Read/Write/Edit + node scripts above.
        assert!(
            tools.contains(&"Skill(diet-logging)"),
            "expected scoped Skill(diet-logging) in: {tools:?}"
        );
        assert!(
            !tools.contains(&"Skill"),
            "a bare Skill scope (any-skill from a phone request) must never be allowed: {tools:?}"
        );

        // The scoped read-only helpers backing the clock header + file inspection
        // are present, and each is the `Bash(<verb>:*)` scoped form — never a bare
        // verb or unscoped Bash. These are read-only / pure-compute (no write, no
        // network), so they widen the read surface only.
        for verb in ["date", "cal", "head", "tail", "wc"] {
            assert!(
                tools.contains(&format!("Bash({verb}:*)").as_str()),
                "expected scoped Bash({verb}:*) in: {tools:?}"
            );
        }

        // Denylist posture: WebFetch is denied; bare `Bash` MUST NOT be.
        // Empirically (claude 2.1.199, verified on the Studio 2026-07-04) listing
        // bare `Bash` in --disallowedTools removes the entire Bash tool class,
        // shadowing EVERY scoped `Bash(<verb>:*)` allow entry above (git, node
        // diet scripts, date/cal, …) — they become unavailable, not merely the
        // unscoped form. Unscoped/unmatched Bash is already blocked without the
        // deny entry: under --permission-mode default a Bash command that matches
        // no scoped allow entry is denied (a phone request cannot answer the
        // permission prompt), so default-deny + the scoped allowlist is the real
        // boundary. Denying the class only breaks the scoped grants. So the
        // denylist keeps WebFetch and drops bare Bash.
        let didx = args
            .iter()
            .position(|a| a == "--disallowedTools")
            .expect("--disallowedTools present");
        let deny: Vec<&str> = args[didx + 1].split(',').map(|t| t.trim()).collect();
        assert!(deny.contains(&"WebFetch"), "WebFetch must be denied: {deny:?}");
        assert!(
            !deny.contains(&"Bash"),
            "bare Bash must NOT be in the denylist — it disables the whole Bash \
             tool class and kills every scoped Bash(...) grant: {deny:?}"
        );
    }
    /// The three env vars the title-backend override sets on the title child.
    const TITLE_ENV_KEYS: [&str; 3] =
        ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"];

    /// Read the env OVERRIDES a `Command` carries (what `.env()` added), as a
    /// map. `get_envs()` yields only the explicit per-command overrides, not the
    /// inherited process env, so this sees exactly what the builder set.
    fn cmd_env_overrides(cmd: &Command) -> std::collections::HashMap<String, String> {
        cmd.as_std()
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect()
    }

    fn cfg_with_title_backend() -> Config {
        let mut cfg = test_config();
        cfg.title_backend = Some((
            "http://127.0.0.1:9100".to_string(),
            "dsv4-local-dummy".to_string(),
            "local-title".to_string(),
        ));
        cfg
    }

    #[test]
    fn title_command_applies_env_triple_when_configured() {
        // With the override configured, the TITLE child's Command carries exactly
        // ANTHROPIC_BASE_URL / _AUTH_TOKEN / _MODEL set to the configured values.
        let cfg = cfg_with_title_backend();
        let mut cmd = build_claude_command(&cfg, "hi", None);
        apply_title_env(&mut cmd, &cfg);
        let env = cmd_env_overrides(&cmd);
        assert_eq!(env.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("http://127.0.0.1:9100"));
        assert_eq!(env.get("ANTHROPIC_AUTH_TOKEN").map(String::as_str), Some("dsv4-local-dummy"));
        assert_eq!(env.get("ANTHROPIC_MODEL").map(String::as_str), Some("local-title"));
    }

    #[test]
    fn title_command_applies_nothing_when_unconfigured() {
        // With no override (the default), the title child sets NONE of the three
        // vars — it inherits the ambient process env byte-for-byte, exactly as
        // before this feature existed.
        let cfg = test_config();
        assert!(cfg.title_backend.is_none(), "test_config must default to no override");
        let mut cmd = build_claude_command(&cfg, "hi", None);
        apply_title_env(&mut cmd, &cfg);
        let env = cmd_env_overrides(&cmd);
        for k in TITLE_ENV_KEYS {
            assert!(!env.contains_key(k), "unconfigured title child must not set {k}");
        }
    }

    #[test]
    fn main_turn_command_is_unaffected_by_title_backend() {
        // THE SAFETY PROPERTY, tested directly: even when the title-backend
        // override IS configured, a MAIN-TURN command carries none of the three
        // ANTHROPIC_* overrides. The main-turn builder never calls apply_title_env,
        // so a title-only redirect can never leak onto a real agent turn.
        let cfg = cfg_with_title_backend();
        assert!(cfg.title_backend.is_some(), "precondition: override is set");
        // A resumed turn and a fresh turn are both built the main-turn way.
        for sid in [None, Some("sess-1")] {
            let cmd = build_claude_command(&cfg, "do the thing", sid);
            let env = cmd_env_overrides(&cmd);
            for k in TITLE_ENV_KEYS {
                assert!(
                    !env.contains_key(k),
                    "main-turn command must NOT carry {k} even when title backend is set"
                );
            }
        }
    }

    // ---- Diet extract/verify children --------------------------------------

    fn cfg_with_diet_backend() -> Config {
        let mut cfg = test_config();
        cfg.diet_backend = Some((
            "http://127.0.0.1:9100".to_string(),
            "dsv4-diet-dummy".to_string(),
            "local-diet".to_string(),
        ));
        cfg
    }

    /// Extract the value following a flag in a Command's argv, or `None`.
    fn cmd_arg_value(cmd: &Command, flag: &str) -> Option<String> {
        let args: Vec<String> = cmd
            .as_std()
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        args.iter().position(|a| a == flag).map(|i| args[i + 1].clone())
    }

    #[test]
    fn diet_extract_command_applies_env_triple_when_configured() {
        // With the override configured, the EXTRACT child's Command carries exactly
        // the three ANTHROPIC_* vars set to the diet-backend values.
        let cfg = cfg_with_diet_backend();
        let mut cmd = build_diet_child_command(&cfg, "hi");
        apply_diet_env(&mut cmd, &cfg);
        let env = cmd_env_overrides(&cmd);
        assert_eq!(env.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("http://127.0.0.1:9100"));
        assert_eq!(env.get("ANTHROPIC_AUTH_TOKEN").map(String::as_str), Some("dsv4-diet-dummy"));
        assert_eq!(env.get("ANTHROPIC_MODEL").map(String::as_str), Some("local-diet"));
    }

    #[test]
    fn diet_extract_command_applies_nothing_when_unconfigured() {
        // No override → the extract child sets none of the three; it inherits the
        // ambient process env, exactly as if the feature were absent.
        let cfg = test_config();
        assert!(cfg.diet_backend.is_none());
        let mut cmd = build_diet_child_command(&cfg, "hi");
        apply_diet_env(&mut cmd, &cfg);
        let env = cmd_env_overrides(&cmd);
        for k in TITLE_ENV_KEYS {
            assert!(!env.contains_key(k), "unconfigured extract child must not set {k}");
        }
    }

    #[test]
    fn diet_verify_command_is_ambient_even_when_diet_backend_set() {
        // THE POINT of the verify gate: it NEVER uses the diet backend. Even with the
        // override configured, a verify child (built the ambient way — no
        // apply_diet_env) carries none of the three ANTHROPIC_* overrides.
        let cfg = cfg_with_diet_backend();
        assert!(cfg.diet_backend.is_some());
        let cmd = build_diet_child_command(&cfg, "verify this"); // no env layering
        let env = cmd_env_overrides(&cmd);
        for k in TITLE_ENV_KEYS {
            assert!(
                !env.contains_key(k),
                "the verify child must be ambient — must NOT carry {k}"
            );
        }
    }

    #[test]
    fn diet_child_holds_no_tools() {
        // The diet children hold NO tools: an EMPTY --allowedTools, plus the
        // class-level denylist removing the mutation/exec/network tool classes.
        let cfg = cfg_with_diet_backend();
        let cmd = build_diet_child_command(&cfg, "hi");
        let allow = cmd_arg_value(&cmd, "--allowedTools").expect("--allowedTools present");
        assert_eq!(allow, "", "the diet child's allowlist must be EMPTY (no tools)");
        let deny = cmd_arg_value(&cmd, "--disallowedTools").expect("--disallowedTools present");
        for class in ["Bash", "Write", "Edit", "WebFetch", "WebSearch", "Task"] {
            assert!(
                deny.split(',').any(|t| t.trim() == class),
                "denylist must remove the {class} class: {deny:?}"
            );
        }
    }

    #[test]
    fn main_turn_command_is_unaffected_by_diet_backend() {
        // THE SAFETY / KILL-SWITCH PROPERTY, tested directly (clone of the title
        // isolation test): even when the diet-backend override IS configured, a
        // MAIN-TURN command carries none of the three ANTHROPIC_* overrides, because
        // the main-turn builder never calls apply_diet_env. A diet-only redirect can
        // never leak onto a real agent turn.
        let cfg = cfg_with_diet_backend();
        assert!(cfg.diet_backend.is_some(), "precondition: override is set");
        for sid in [None, Some("sess-1")] {
            let cmd = build_claude_command(&cfg, "do the thing", sid);
            let env = cmd_env_overrides(&cmd);
            for k in TITLE_ENV_KEYS {
                assert!(
                    !env.contains_key(k),
                    "main-turn command must NOT carry {k} even when diet backend is set"
                );
            }
        }
    }

    #[test]
    fn main_turn_command_is_byte_identical_whether_diet_backend_set_or_not() {
        // The kill switch, proven byte-for-byte on the SPAWNED command: unsetting the
        // triple must reproduce today's exact main-turn invocation. The argv, the
        // cwd, and the env overrides must all match between a config with the diet
        // backend set and one without.
        let with = cfg_with_diet_backend();
        let mut without = with.clone();
        without.diet_backend = None;
        for sid in [None, Some("sess-42")] {
            let a = build_claude_command(&with, "log a banana", sid);
            let b = build_claude_command(&without, "log a banana", sid);
            let argv = |c: &Command| -> Vec<String> {
                c.as_std().get_args().map(|s| s.to_string_lossy().into_owned()).collect()
            };
            assert_eq!(argv(&a), argv(&b), "argv must be identical (kill switch)");
            assert_eq!(
                a.as_std().get_current_dir(),
                b.as_std().get_current_dir(),
                "cwd must be identical"
            );
            assert_eq!(
                cmd_env_overrides(&a),
                cmd_env_overrides(&b),
                "env overrides must be identical (none, either way)"
            );
        }
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
    #[test]
    fn truncate_bytes_caps_multibyte_on_char_boundary() {
        // A >4 MB reply of 4-byte chars (emoji). `truncate_chars` keeps
        // MAX_OUTPUT_BYTES *characters* (~16 MB) — ~4× the intended byte budget,
        // the M1 bug. The byte-aware cap keeps ≤ MAX_OUTPUT_BYTES bytes on a valid
        // UTF-8 boundary.
        let s = "🎉".repeat(2_000_000); // 4 bytes each → ~8 MB
        assert!(s.len() > MAX_OUTPUT_BYTES);

        // Documents the bug: char-count truncation overshoots the byte cap.
        assert!(
            truncate_chars(&s, MAX_OUTPUT_BYTES).len() > MAX_OUTPUT_BYTES,
            "char-count truncation overshoots the byte cap for multibyte text"
        );

        let t = truncate_bytes_on_char_boundary(&s, MAX_OUTPUT_BYTES);
        assert!(t.len() <= MAX_OUTPUT_BYTES, "byte cap respected");
        assert!(
            MAX_OUTPUT_BYTES - t.len() < 4,
            "kept the largest char boundary ≤ the cap"
        );
        assert!(t.chars().all(|c| c == '🎉'), "no multibyte char was split");
        // A string already within the cap is returned unchanged.
        assert_eq!(
            truncate_bytes_on_char_boundary("hello", MAX_OUTPUT_BYTES),
            "hello"
        );
    }
}
