use crate::*;

// ---- What a turn amounts to, and how to drive one ---------------------------
//
// This module is the HARNESS-INDEPENDENT half: the outcome vocabulary every harness
// reports in, and the drivers that spawn a child, read its stdout line by line, stop at the
// terminal result, reap it under a bound, resolve the outcome, and retry a transient
// failure. Everything specific to the `claude` CLI — argv, containment flags, per-role env,
// `stream-json` line parsing — lives in [`crate::harness::claude_code`], behind the
// [`Harness`] trait.
//
// There are exactly TWO copies of the spawn/read/reap loop here (the retrying turn driver
// and the no-retry one-shot runner), and there must never be a third: between them they
// encode the hang when a grandchild MCP server holds the stdout pipe open, the fallback
// when a success envelope carries an empty `result`, and the byte- (not char-) based
// truncation cap. Every one of those was real debugging. A new call site takes a
// `&dyn Harness` and calls one of these.

/// What one agent run amounts to — decided from its output rather than its exit status
/// alone (see [`interpret_claude_output`]).
#[derive(Debug)]
pub enum ClaudeOutcome {
    Ok {
        result: String,
        session_id: Option<String>,
        /// Token usage recovered from the terminal `result` line's `usage` object, for
        /// the per-turn cost badge (multiplied by the active model's price deck). Empty
        /// (all-`None`) when the line carried none or the answer came from the streamed
        /// fallback rather than a `result` line. Content-free — token counts only.
        usage: ShadowUsage,
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

/// One line of a harness's output, decoded into what the bridge cares about. Produced by
/// that harness's [`TurnParser`]; most lines are `Ignore`d.
#[derive(Debug)]
pub enum StreamEvent {
    /// A chunk of the visible answer (a `text_delta` inside a `text` block).
    /// Thinking deltas carry a different delta type and are deliberately excluded.
    TextDelta(String),
    /// The agent started using a tool — surfaced as a coarse activity hint. See
    /// [`ToolActivity`] for why refusal is a field on it rather than a word in its name.
    ToolActivity(ToolActivity),
    /// The terminal `result` line: classify it exactly as the buffered path does.
    Done(ClaudeOutcome),
    /// The session this turn is running under, as the harness itself reported it —
    /// AUTHORITATIVE for which session a turn belongs to.
    ///
    /// Claude Code emits it on the `system`/`init` event, the very first line of the
    /// stream, and repeats it on every line thereafter (verified against claude 2.1.220;
    /// the id names the transcript stem exactly, and `--resume` reports the resumed id
    /// rather than a fresh one). Arriving FIRST is what makes it better than the terminal
    /// `result` line's copy: a turn that dies mid-flight has still told the bridge which
    /// session it owns.
    ///
    /// The driver keeps the first one it sees, so a harness that repeats the id per line
    /// costs nothing.
    SessionId(String),
    /// Anything else (rate-limit, message envelopes, thinking deltas, tool input
    /// deltas, …) — carries nothing the bridge needs.
    Ignore,
}

/// Every session id a turn's children reported, in spawn order — the turn's own record of
/// which sessions it owns, filled from [`StreamEvent::SessionId`] as each child starts.
///
/// A `Vec`, not a single id, because a RETRY spawns a fresh child with a fresh session and
/// a fresh transcript. All of them belong to the conversation, and binding them in order
/// leaves the LAST one current — which is what a resume targets. Ignoring the earlier ones
/// would strand their transcripts.
///
/// Recorded even when the turn goes on to fail, because the id arrives on the child's first
/// line: a turn that dies mid-flight has still said which session it owns. That is the
/// whole reason this replaces a directory diff.
#[derive(Clone, Default, Debug)]
pub struct SpawnedSessions(Arc<Mutex<Vec<String>>>);

impl SpawnedSessions {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record one reported id, ignoring blanks and repeats. Claude Code repeats the id on
    /// every line of the stream, so idempotence here is what lets the driver stay dumb.
    pub fn record(&self, session_id: &str) {
        let id = session_id.trim();
        if id.is_empty() {
            return;
        }
        let mut ids = self.0.lock_ok();
        if !ids.iter().any(|s| s == id) {
            ids.push(id.to_string());
        }
    }

    /// The reported ids, in spawn order.
    pub fn ids(&self) -> Vec<String> {
        self.0.lock_ok().clone()
    }
}

/// Decide the final outcome of a *streamed* turn from its terminal `result` line
/// (if one arrived) and the text already accumulated from the stream. The whole
/// point: a turn that produced a visible answer must never be delivered as an
/// empty bubble or discarded — the streamed text is the safety net under a
/// success envelope whose `result` field is empty/missing.
///
/// `streamed` is empty for a harness whose [`Harness::streams_text`] is false: a
/// whole-answer harness has no live text to fall back to, so its terminal outcome has to be
/// complete on its own and must not be given a phantom safety net.
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
///
/// `harness` is the id of the child that produced this outcome ([`Harness::id`]), and is
/// used ONLY to name it in a failure message. This function is shared by every harness, so a
/// hardcoded label here reports one harness's death under another's name.
pub fn resolve_stream_outcome(
    harness: &str,
    terminal: Option<ClaudeOutcome>,
    streamed: &str,
    stderr: &str,
) -> ClaudeOutcome {
    let streamed = streamed.trim();
    match terminal {
        // Success envelope: prefer the authoritative `result`, but fall back to
        // the streamed text when `result` came back empty/blank.
        Some(ClaudeOutcome::Ok {
            result,
            session_id,
            usage,
        }) => {
            if !result.trim().is_empty() {
                ClaudeOutcome::Ok {
                    result,
                    session_id,
                    usage,
                }
            } else if !streamed.is_empty() {
                ClaudeOutcome::Ok {
                    result: streamed.to_string(),
                    session_id,
                    usage,
                }
            } else {
                // Success but no answer anywhere — never deliver an empty bubble.
                ClaudeOutcome::Fatal {
                    message: format!("{harness} returned an empty result and streamed no text"),
                }
            }
        }
        // Error envelopes (Retryable / Fatal) are surfaced/retried as-is.
        Some(other) => other,
        // No terminal `result` line. If the stream nonetheless carried an answer,
        // deliver it; otherwise this is a real failure — surface it via stderr.
        None => {
            if streamed.is_empty() {
                // The no-envelope failure message is the CLI-shaped one the operator has
                // always seen, stderr and all; that is why this reaches into the harness.
                interpret_claude_output(harness, "", stderr, false)
            } else {
                ClaudeOutcome::Ok {
                    result: streamed.to_string(),
                    session_id: None,
                    usage: ShadowUsage::default(),
                }
            }
        }
    }
}

/// Spawn a pre-built stateless one-shot `Command` and return its answer text.
/// Shared by [`run_claude_oneshot`], [`run_diet_extract`], [`run_diet_verify`] and
/// [`run_vaultqa_child`]: it reuses the exact same line reading, terminal classification
/// (the harness's [`TurnParser`] + [`resolve_stream_outcome`]), and bounded-reap discipline
/// as a turn, but creates no job, pushes no stream, resumes no session, persists
/// nothing. The caller has already built the command through `harness` and layered any
/// env override (or none) on it. No retry — a one-shot is best-effort and every caller
/// degrades to the hosted path on any non-2xx. `label` names the child in the timeout
/// message.
async fn run_stateless_oneshot(
    cfg: &Config,
    harness: &dyn Harness,
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
    // `result` line — the same completion rule as a turn. One FRESH parser for this
    // spawn, so nothing from an earlier child can bleed in.
    let mut parser = harness.parser();
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
            match parser.on_line(&line) {
                StreamEvent::TextDelta(t) => {
                    if streamed.len() < MAX_OUTPUT_BYTES {
                        streamed.push_str(&t);
                    }
                }
                StreamEvent::Done(outcome) => {
                    terminal = Some(outcome);
                    break;
                }
                // A one-shot child (title / diet / vault-QA) is not a conversation, so the
                // session it names is nothing this path binds.
                StreamEvent::SessionId(_)
                | StreamEvent::ToolActivity(_)
                | StreamEvent::Ignore => {}
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
    // never delay delivery. Mirrors the turn path.
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

    match resolve_stream_outcome(harness.id(), terminal, &streamed, &stderr) {
        ClaudeOutcome::Ok { result, .. } => Ok(result),
        ClaudeOutcome::Fatal { message } | ClaudeOutcome::Retryable { message, .. } => {
            Err((StatusCode::BAD_GATEWAY, message))
        }
    }
}

/// A stateless, single agent invocation — the primitive behind `POST /jesse/title`.
/// **Stateless and NOT a turn:** no job is created, no session, nothing is persisted, no
/// live stream, and none of the jobs/streams/aborts mutexes are touched. The caller passes
/// a short `timeout_secs` (see `TITLE_TIMEOUT_SECS`).
///
/// Contained at [`Capability::Basic`] with NO MCP servers — writing a short title from a
/// transcript is a single-shot text transformation that needs no tools and no vault search
/// — and pointed at the title backend when one is configured. There is no retry loop: the
/// title path is a best-effort UI nicety the caller degrades from on any non-2xx, so a
/// single bounded attempt keeps latency tight rather than re-running on an upstream blip.
/// The streamed text is still accumulated as the empty-`result` fallback, so a success
/// envelope with a blank `result` still yields the visible answer.
pub async fn run_claude_oneshot(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
    pick: &RoutedPick,
) -> Result<String, ApiError> {
    let harness = cfg.harnesses.serving_pick(pick);
    // The title path is AMBIENT and untouched by the model switch, so it passes the ambient
    // model — the command is byte-for-byte today's, and `apply_title_env` below still layers
    // any title backend on top (the two never mix). BASIC with no MCP servers is stated at
    // the call site rather than derived from the active model, because it describes what
    // THIS CHILD DOES: naming a conversation used to resolve through the writes-on ambient
    // model, so it ran with the FULL writes-on toolset and launched the qmd server, in the
    // vault, for a job whose entire output is a handful of words the bridge then validates
    // and truncates. Nothing about the title contract wanted that.
    let ambient = ActiveModel::ambient();
    let mut cmd = harness.build_turn(cfg, &title_child_request(cfg, prompt, &ambient))?;
    // Title-only backend override: point THIS child at the configured
    // base_url/token/model when all three JESSE_TITLE_* vars are set. A no-op
    // otherwise (ambient backend). Main turns never call this.
    // The routing rule's pick for this job. `RoutedPick::log` already named the model and
    // harness that serves it (no prompt content), so there is no second provenance line.
    apply_routed_env(&mut cmd, pick);
    run_stateless_oneshot(cfg, harness, cmd, timeout_secs, "title generation").await
}

/// The stateless diet EXTRACT one-shot: parse a raw food/exercise/weigh-in
/// utterance into structured JSON entries. Runs a toolless child
/// ([`diet_child_request`]) pointed at the diet-extract backend
/// ([`apply_diet_env`]) when configured; returns the child's raw JSON text for the
/// pipeline to validate. Emits ONE provenance line (base URL + model, never the
/// token, no utterance content) so an audit can tell which backend served the
/// extraction. Any spawn/timeout/upstream failure is a non-2xx the pipeline treats
/// as ladder rung 2 (fall through to the hosted turn).
pub async fn run_diet_extract(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
    pick: &RoutedPick,
) -> Result<String, ApiError> {
    let harness = cfg.harnesses.serving_pick(pick);
    let ambient = ActiveModel::ambient();
    let mut cmd = harness.build_turn(cfg, &diet_child_request(cfg, prompt, &ambient))?;
    apply_routed_env(&mut cmd, pick);
    run_stateless_oneshot(cfg, harness, cmd, timeout_secs, "diet extraction").await
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
    pick: &RoutedPick,
) -> Result<String, ApiError> {
    // The verifier is whatever the routing rule picked at `Write`, with the extractor
    // EXCLUDED — see `RoutedJob::DietVerify`. Ambient when nothing else qualifies, which is
    // exactly the old behavior (the verify child was unconditionally ambient).
    let harness = cfg.harnesses.serving_pick(pick);
    let ambient = ActiveModel::ambient();
    let mut cmd = harness.build_turn(cfg, &diet_child_request(cfg, prompt, &ambient))?;
    apply_routed_env(&mut cmd, pick);
    run_stateless_oneshot(cfg, harness, cmd, timeout_secs, "diet verification").await
}

/// Run the contained read-only vault-QA child: a toolless-except-read one-shot
/// ([`vaultqa_child_request`]) pointed at the vault-QA backend ([`apply_vaultqa_env`])
/// when configured. Returns the child's raw answer text for the pipeline to validate. No
/// retry — a vault lookup is best-effort and the ladder degrades to the hosted turn on any
/// failure. The hard timeout is [`VAULTQA_TIMEOUT_SECS`] (passed by the caller).
pub async fn run_vaultqa_child(
    cfg: &Config,
    prompt: &str,
    timeout_secs: u64,
    pick: &RoutedPick,
) -> Result<String, ApiError> {
    let harness = cfg.harnesses.serving_pick(pick);
    let ambient = ActiveModel::ambient();
    let mut cmd = harness.build_turn(cfg, &vaultqa_child_request(cfg, prompt, &ambient))?;
    apply_routed_env(&mut cmd, pick);
    run_stateless_oneshot(cfg, harness, cmd, timeout_secs, "vault-QA lookup").await
}

/// Invoke the agent in the vault, streaming its output. Returns (reply_text,
/// session_id, usage). Pass session_id to continue a thread; the returned id is always
/// captured so the client can follow up later. Resuming keeps CLAUDE.md loaded and retains
/// filesystem access — it only adds the prior conversation on top.
///
/// Unlike the old buffered path, this reads the child's stdout LINE BY LINE as tokens
/// arrive, pushing each text delta and tool-activity hint onto the job's broadcast stream
/// (`jobs.stream_*`) so subscribers see the reply build live. The terminal result is
/// classified by the exact same Ok/Retryable/Fatal logic as before, and that classified
/// result — not the streamed deltas — is the authoritative value returned and persisted.
///
/// Retries transient upstream failures (5xx/429/529) up to 3 attempts total.
/// A retry re-runs the WHOLE prompt: a transient that lands *mid-Tell* (after an
/// action was already applied) could in principle double-apply it on the rerun.
/// Accepted, because the observed transient fails at the API before any work
/// (0 tokens, $0) — there is nothing to repeat — but the tradeoff is explicit
/// here in case that ever changes. Only `Retryable` outcomes retry; spawn/io/
/// timeout failures (which happen before any output exists) do not. `kill_on_drop`,
/// the per-attempt timeout, and the 3-attempt retry are all preserved.
///
/// `harness` names the agent program: it builds the child `Command` and supplies the
/// per-attempt line parser. Everything else here is harness-independent.
// One more than the lint's ceiling, and each is a distinct collaborator the turn needs
// (config, prompt, resume target, job store + id, model, harness, session recorder). A
// params struct would only rename the same eight.
#[allow(clippy::too_many_arguments)]
pub async fn run_claude_streaming(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
    jobs: &Arc<JobStore>,
    job_id: &str,
    active: &ActiveModel,
    harness: &dyn Harness,
    spawned: &SpawnedSessions,
) -> Result<(String, Option<String>, ShadowUsage), ApiError> {
    const MAX_ATTEMPTS: u32 = 3; // 1 try + 2 retries

    // A manual `loop` (not `for attempt in 1..=MAX_ATTEMPTS`) so the terminal
    // outcome is the loop's `break` value and the function is statically total:
    // every path breaks or `continue`s, so there is no post-loop `unreachable!()`
    // the compiler couldn't prove was dead.
    // Resume-after-sweep safety: if the requested session's transcript no longer
    // exists in THIS HARNESS's transcript dir (reclaimed by the GC sweep, or deleted
    // while the phone thread lived on), drop the `--resume` so a resume of a gone
    // session can never surface a raw CLI error — the turn runs FRESH and returns a new
    // session id (the app keeps its local transcript and stores the new id). A live real
    // id and a synthetic `local-` id pass through unchanged, as does every id under a
    // harness that keeps no transcripts (there is no file whose absence could justify
    // dropping the resume). Resolved ONCE here (not per attempt) since a mid-turn sweep
    // can't remove a session the agent is actively holding open.
    let session_id = resolve_resume_session_for_harness(cfg, harness, session_id);

    let mut attempt = 0u32;
    loop {
        attempt += 1;
        // Fresh Command per attempt — same args, including --resume if present.
        // Tool access is constrained by the capability the active model implies (C1);
        // the agent runs under the harness's own least-privilege posture.
        // A main turn deliberately does NOT call apply_title_env: the title-backend
        // override touches the title child only, never a real agent turn.
        // The active model backs this turn: for a non-ambient model the harness applies
        // its ANTHROPIC_* + CLAUDE_CODE_SUBAGENT_MODEL; for the ambient default it
        // applies nothing (byte-for-byte today's command). The capability it is granted
        // comes from the same model: writes-on → Write, read-only → Read.
        let mut cmd = harness.build_turn(
            cfg,
            &main_turn_request(
                cfg,
                prompt,
                session_id,
                active,
                turn_capability(active),
                main_mcp_config(cfg, harness),
            ),
        )?;

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

        // Drain stderr concurrently (capped), so a chatty stderr can't deadlock the stdout
        // pipe and so the no-`result` fallback below has the cause.
        //
        // LINE BY LINE, and classified as it arrives, because for some harnesses stderr is
        // not merely a failure cause — it is the only channel a whole class of events uses.
        // Codex reports a sandbox-refused tool call there and nowhere else, so a turn read off
        // stdout alone renders a refused child as an idle one. See
        // `Harness::classify_stderr_line`.
        //
        // The task owns its classifier rather than borrowing the harness: it outlives this
        // iteration's borrows, which is exactly why `stderr_classifier` returns a box.
        let classifier = harness.stderr_classifier();
        let auth_failure: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let stderr_jobs = jobs.clone();
        let stderr_job_id = job_id.to_string();
        let stderr_auth = auth_failure.clone();
        let stderr_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            let mut buf = String::new();
            while let Ok(Some(line)) = lines.next_line().await {
                match classifier.classify(&line) {
                    // The boundary refusing a tool call is not the turn failing, so it rides
                    // the ordinary activity channel — the same one a successful tool call
                    // uses. What it must never be is silent.
                    Some(StderrSignal::ToolRefused { activity }) => {
                        stderr_jobs.stream_push_activity(&stderr_job_id, activity);
                    }
                    // Recorded, not acted on here: this task cannot end the turn, and the
                    // driver below owns that decision. FIRST one wins — a dead credential
                    // produces one line per internal retry and they all say the same thing.
                    Some(StderrSignal::AuthFailed { detail }) => {
                        let mut slot = stderr_auth.lock_ok();
                        if slot.is_none() {
                            *slot = Some(detail);
                        }
                    }
                    None => {}
                }
                // Still accumulated verbatim: the no-`result` fallback surfaces this to the
                // operator as the failure cause, and classification must not eat it.
                if buf.len() < MAX_OUTPUT_BYTES {
                    buf.push_str(&line);
                    buf.push('\n');
                }
            }
            buf
        });

        // Read stdout line by line, mapping each line through a FRESH parser for THIS
        // attempt (a retry must never see the previous attempt's half-accumulated
        // state), pushing live frames, and STOPPING as soon as the terminal result is
        // parsed. Completion must be driven by that terminal event, never by stdout
        // EOF: EOF only arrives once the agent AND every grandchild that inherited its
        // stdout fd (the MCP servers it launches — QMD, Home Assistant, …) close the
        // pipe, so a single lingering subprocess would otherwise block this read until
        // the per-attempt timeout, pinning the job as Running long after the answer (and
        // its result line) already arrived. The stream contract emits exactly one
        // terminal result and it is the last meaningful line, so breaking on it still
        // satisfies "the last result line wins." The no-result fallback below (clean EOF
        // with accumulated streamed text) is preserved: that path is reached only when
        // the loop ends via `next_line() == None` without ever seeing a `Done`.
        let mut parser = harness.parser();
        let read_lines = async {
            let mut lines = BufReader::new(stdout).lines();
            let mut terminal: Option<ClaudeOutcome> = None;
            loop {
                let next = lines
                    .next_line()
                    .await
                    .map_err(|e| (StatusCode::BAD_GATEWAY, format!("claude io error: {e}")))?;
                let Some(line) = next else { break };
                match parser.on_line(&line) {
                    StreamEvent::TextDelta(t) => jobs.stream_push_delta(job_id, &t),
                    StreamEvent::ToolActivity(a) => jobs.stream_push_activity(job_id, a),
                    // The child named its session. Record it the moment it arrives, so a
                    // turn that dies after this line has still told us what it owns.
                    StreamEvent::SessionId(id) => spawned.record(&id),
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
        // child (or, more likely, a grandchild MCP server that inherited its
        // stdio) that won't exit can't pin this task. Once the result is parsed
        // the answer is authoritative; reaping is cleanup that must never delay
        // or block delivery.
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

        // Decide the outcome from the terminal result AND the text already accumulated
        // from the stream, so a turn that produced a visible answer is never delivered
        // empty or discarded: an empty/missing `result` on an otherwise-successful turn
        // falls back to the streamed text. Error envelopes (Retryable/Fatal) and the
        // genuine no-answer case are surfaced unchanged. See `resolve_stream_outcome`.
        //
        // The snapshot is taken only for a harness that STREAMS text; a whole-answer
        // harness pushed no deltas, so there is nothing to fall back to and its terminal
        // outcome stands on its own.
        let streamed = if harness.streams_text() {
            jobs.stream_snapshot(job_id).unwrap_or_default()
        } else {
            String::new()
        };
        let outcome = resolve_stream_outcome(harness.id(), terminal, &streamed, &stderr);

        // A credential failure seen on stderr overrides a FAILING outcome's message, and only
        // a failing one — a turn that produced an answer succeeded, whatever the child logged
        // on its way there. The point is what the operator is told: an expired daemon login
        // takes every turn on that harness down at once and cannot be fixed from the phone, so
        // it must not read as a generic bad gateway.
        //
        // COUPLED WITH `codex_failure`, which recognises the same failure on the terminal
        // event. This arm is the one that still works when there IS no terminal event — a
        // child killed at the timeout has written its stderr and no `turn.failed` at all.
        let outcome = match auth_failure.lock_ok().take() {
            Some(detail) if !matches!(outcome, ClaudeOutcome::Ok { .. }) => ClaudeOutcome::Fatal {
                message: auth_failure_message(harness.id(), &detail),
            },
            _ => outcome,
        };

        match outcome {
            ClaudeOutcome::Ok {
                result,
                session_id,
                usage,
            } => {
                // The cross-turn tool-id guard. A turn that succeeded is still the moment
                // the evidence exists: the transcript now holds THIS turn's ids beside every
                // earlier turn's, which is the only place a collision is visible at all.
                // Non-ambient models only — see `report_tool_id_collisions` for why. Never
                // affects what is returned; a provider regression must not become a bridge
                // outage.
                if active.is_non_ambient() {
                    if let Some(sid) = session_id.as_deref() {
                        report_tool_id_collisions(cfg, harness, &active.id, sid);
                    }
                }
                // Cap the stored reply at MAX_OUTPUT_BYTES *bytes* on a char
                // boundary (M1) — not chars, which for multibyte text could keep
                // up to ~4× the budget. This matches the byte-based stream cap.
                break Ok((
                    truncate_bytes_on_char_boundary(&result, MAX_OUTPUT_BYTES).to_string(),
                    session_id,
                    usage,
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

/// Split a streamed turn's result into the `(text, session_id)` pair the rest of the
/// pipeline (`apply_directives`, badge, provenance) already consumes, plus the token
/// `usage` peeled off for the per-turn cost badge. An error carries empty usage. This is
/// the single seam between `run_claude_streaming`'s usage-bearing return and the existing
/// `(String, Option<String>)`-shaped outcome, so nothing downstream had to change shape.
pub fn split_turn_usage(
    res: Result<(String, Option<String>, ShadowUsage), ApiError>,
) -> (Result<(String, Option<String>), ApiError>, ShadowUsage) {
    match res {
        Ok((text, session_id, usage)) => (Ok((text, session_id)), usage),
        Err(e) => (Err(e), ShadowUsage::default()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const FX_SUCCESS: &str = include_str!("../tests/fixtures/stream/success.ndjson");
    const FX_EMPTY_RESULT: &str =
        include_str!("../tests/fixtures/stream/empty_result_success.ndjson");
    const FX_MISSING_RESULT: &str = include_str!("../tests/fixtures/stream/missing_result.ndjson");
    const FX_MAX_TURNS: &str = include_str!("../tests/fixtures/stream/error_max_turns.ndjson");
    /// Replay a captured `stream-json` turn exactly as `run_claude_streaming`
    /// does: accumulate `text_delta`s, keep the last terminal `result`, then let
    /// `resolve_stream_outcome` decide. `stderr` stands in for the drained child
    /// stderr the real path passes.
    fn replay_outcome(fixture: &str, stderr: &str) -> ClaudeOutcome {
        let mut streamed = String::new();
        let mut terminal: Option<ClaudeOutcome> = None;
        let mut parser = ClaudeCode.parser();
        for line in fixture.lines() {
            match parser.on_line(line) {
                StreamEvent::TextDelta(t) => streamed.push_str(&t),
                StreamEvent::Done(o) => terminal = Some(o),
                StreamEvent::SessionId(_)
                | StreamEvent::ToolActivity(_)
                | StreamEvent::Ignore => {}
            }
        }
        resolve_stream_outcome(ClaudeCode.id(), terminal, &streamed, stderr)
    }
    #[test]
    fn real_success_turn_yields_full_result_text() {
        // Normal turn: the authoritative `result` text is delivered verbatim.
        match replay_outcome(FX_SUCCESS, "") {
            ClaudeOutcome::Ok {
                result, session_id, ..
            } => {
                assert!(
                    result.contains("This vault is") && result.len() > 600,
                    "expected the full ~693-char answer, got {} chars",
                    result.len()
                );
                assert_eq!(
                    session_id.as_deref(),
                    Some("0a61d246-062e-4910-b825-44ebd04f0bbd")
                );
            }
            other => panic!("expected Ok with full text, got {other:?}"),
        }
    }
    #[test]
    fn empty_result_success_falls_back_to_streamed_text() {
        // Success envelope but `result` is "" — must deliver the streamed answer
        // (not an empty bubble), keeping the result line's session_id.
        match replay_outcome(FX_EMPTY_RESULT, "") {
            ClaudeOutcome::Ok {
                result, session_id, ..
            } => {
                assert!(
                    result.contains("This vault is") && !result.trim().is_empty(),
                    "empty `result` should fall back to streamed text, got {result:?}"
                );
                assert_eq!(
                    session_id.as_deref(),
                    Some("0a61d246-062e-4910-b825-44ebd04f0bbd")
                );
            }
            other => panic!("expected Ok with streamed text, got {other:?}"),
        }
    }
    #[test]
    fn missing_result_line_with_streamed_text_yields_streamed_text() {
        // No terminal `result` line at all, but the turn streamed an answer →
        // deliver it (not the old unconditional Fatal). session_id is unknown.
        match replay_outcome(FX_MISSING_RESULT, "") {
            ClaudeOutcome::Ok {
                result, session_id, ..
            } => {
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
        match resolve_stream_outcome(ClaudeCode.id(), None, "", "claude: connection reset") {
            ClaudeOutcome::Fatal { message } => {
                assert!(!message.trim().is_empty(), "Fatal must carry a message");
                assert!(message.contains("connection reset"), "got {message:?}");
            }
            other => panic!("expected Fatal, got {other:?}"),
        }
    }
    /// A CODEX FAILURE MUST NAME CODEX. The no-envelope Fatal message is built in the Claude
    /// Code module, and this shared driver path reaches it for EVERY harness — so with the
    /// label hardcoded, a Codex child that died on a clap usage error reported "claude
    /// failed" directly above a `codex exec resume` usage string. That is what sent Jeremy
    /// looking for a model switch that never happened.
    ///
    /// Both no-answer messages are checked, because both were hardcoded.
    #[test]
    fn a_codex_failure_names_codex_and_never_claude() {
        // The real stderr from the resume break, verbatim.
        let stderr = "error: unexpected argument '-C' found\n\nUsage: codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]";
        match resolve_stream_outcome(Codex.id(), None, "", stderr) {
            ClaudeOutcome::Fatal { message } => {
                assert!(message.starts_with("codex failed"), "got {message:?}");
                assert!(
                    !message.contains("claude"),
                    "a Codex failure named claude: {message:?}"
                );
                // The child's own stderr still travels verbatim — the label changed, the
                // diagnostic did not.
                assert!(message.contains("unexpected argument"), "got {message:?}");
            }
            other => panic!("expected Fatal, got {other:?}"),
        }

        // The other no-answer message: a success envelope with nothing in it.
        match resolve_stream_outcome(
            Codex.id(),
            Some(ClaudeOutcome::Ok {
                result: String::new(),
                session_id: None,
                usage: ShadowUsage::default(),
            }),
            "",
            "",
        ) {
            ClaudeOutcome::Fatal { message } => {
                assert!(
                    message.starts_with("codex returned an empty result"),
                    "got {message:?}"
                );
                assert!(!message.contains("claude"), "got {message:?}");
            }
            other => panic!("expected Fatal, got {other:?}"),
        }

        // And the Claude Code path still names itself, under its registry id.
        match resolve_stream_outcome(ClaudeCode.id(), None, "", "connection reset") {
            ClaudeOutcome::Fatal { message } => {
                assert!(message.starts_with("claude-code failed"), "got {message:?}")
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
            matches!(
                replay_outcome(FX_MAX_TURNS, ""),
                ClaudeOutcome::Fatal { .. }
            ),
            "error envelope must stay Fatal, not be replaced by streamed narration"
        );
    }
    #[test]
    fn a_whole_answer_harness_gets_no_streamed_fallback() {
        // The one thing `streams_text` gates: with no live text, an empty `result` on a
        // success envelope is a genuine no-answer failure, not something a phantom
        // fallback can paper over. (The driver passes "" for such a harness.)
        match resolve_stream_outcome(
            ClaudeCode.id(),
            Some(ClaudeOutcome::Ok {
                result: String::new(),
                session_id: Some("t-1".to_string()),
                usage: ShadowUsage::default(),
            }),
            "",
            "",
        ) {
            ClaudeOutcome::Fatal { message } => assert!(!message.is_empty()),
            other => panic!("expected Fatal, got {other:?}"),
        }
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
