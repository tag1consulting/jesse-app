use crate::*;

#[derive(Deserialize)]
pub struct JesseRequest {
    mode: String, // "ask" | "tell"
    text: String,
    #[serde(default)]
    session_id: Option<String>, // set to continue a thread (a followup)
    #[serde(default)]
    voice: bool, // voice request → ask for a SPOKEN: summary line, keep it listenable
    // Optional per-request override of the active mode's wrapper instruction.
    // When present and non-empty, `build_prompt` uses it in place of the built-in
    // Ask/Tell const (the `mode` above selects which); VOICE_SUFFIX/PHONE_FORMAT
    // are still appended. Absent/empty reproduces today's behavior exactly.
    #[serde(default)]
    instructions: Option<String>,
    // Optional per-request override of the active mode's *safety floor* wording.
    // Like `instructions`, but for the always-prepended floor: non-empty replaces
    // the built-in floor text; absent/empty uses the const. The floor is still
    // prepended either way — this never removes it.
    #[serde(default)]
    floor_override: Option<String>,
    // Files the user attached. Decoded, validated, and written to a per-request
    // scratch dir the headless agent reads; empty for an ordinary turn.
    #[serde(default)]
    attachments: Vec<Attachment>,
    // Optional compact "recent workouts" block the phone attaches from Apple
    // Health, so the agent can log a workout the user refers to ("Log my swim")
    // from device-reported numbers. Absent or empty reproduces today's behavior
    // exactly (backward compatible — old app builds simply omit it). When present
    // it is capped (`MAX_HEALTH_CONTEXT_BYTES` → 413), control-stripped, and framed
    // as untrusted DEVICE DATA after the clock line by `build_prompt`. Same trust
    // class as `text`: attacker-controlled only if the phone is.
    #[serde(default)]
    health_context: Option<String>,
    // This turn is a retry answering a prior `JESSE_NEEDS_HEALTH` directive: the
    // app fetched the requested data and re-sent the SAME question with it in
    // `health_context`. Informational — the wrapper frames the attached data as
    // "requested or attached, don't ask again." Absent/false on an ordinary turn.
    #[serde(default)]
    health_context_requested: Option<bool>,
    // The app could NOT fulfill a health request this turn (Health access denied,
    // device locked, read timed out, or the feature toggle is off). The wrapper
    // then tells the agent to answer from vault data without re-requesting, so the
    // request→retry channel can never loop. Absent/false on an ordinary turn.
    #[serde(default)]
    health_context_unavailable: Option<bool>,
    // Meal-corrections ack (JESSE_MEAL_LOG v2): the highest `corrections_seq` the app has
    // APPLIED from a delivered `meal_log`. On receipt the bridge prunes every queued batch
    // at or below this seq. Absent on an ordinary turn (old app builds simply omit it);
    // redelivery of an unacked batch is harmless (app-side id+hash idempotency), so a
    // missing or stale ack only ever costs a redelivery, never correctness.
    #[serde(default)]
    meal_corrections_ack: Option<u64>,
    // Optional idempotency key for POST /jesse. A client that never saw the response
    // to a POST (socket dropped before the 202) can re-send the SAME request with the
    // SAME `request_id`; the bridge then returns the ORIGINAL job instead of spawning a
    // second turn. Validated when present (`validate_request_id`): ≤64 chars, ASCII
    // alphanumerics and hyphens only. Absent reproduces today's behavior exactly (old
    // app builds simply omit it) — every POST is a fresh turn.
    #[serde(default)]
    request_id: Option<String>,
}

/// Validate a POST /jesse idempotency `request_id`: at most 64 characters, ASCII
/// alphanumerics and hyphens only, non-empty. Returns a one-line error message on
/// rejection (the handler surfaces it as a `400`). Pure so it is unit-tested in
/// isolation from the router.
pub fn validate_request_id(id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("request_id must not be empty".to_string());
    }
    if id.len() > 64 {
        return Err("request_id must be at most 64 characters".to_string());
    }
    if !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("request_id may contain only ASCII letters, digits, and hyphens".to_string());
    }
    Ok(())
}

/// The `202 { "job_id", "status": "running" }` accept response. The SAME shape is
/// returned for a fresh turn and for an idempotent-dedup hit, so the client streams
/// or polls the returned id identically either way (a job that already finished
/// satisfies the first poll immediately).
fn accepted_running(job_id: &str) -> Response {
    (
        StatusCode::ACCEPTED,
        Json(json!({ "job_id": job_id, "status": "running" })),
    )
        .into_response()
}

/// Body of `POST /jesse/device`: the phone's APNs device token (hex string).
#[derive(Deserialize)]
pub struct DeviceRequest {
    token: String,
}

/// Body of `POST /jesse/title`: the conversation text to turn into a short title.
#[derive(Deserialize)]
pub struct TitleRequest {
    text: String,
    // Optional: when present, the minted title is persisted server-side under this
    // session_id (so `GET /jesse/sessions` can show it). Absent → today's
    // stateless behavior exactly (nothing persisted). Additive and
    // backward-compatible: old clients simply omit it.
    #[serde(default)]
    session_id: Option<String>,
}

// ---- Emergency ASK routing (Piece 4) --------------------------------------

/// The result of resolving an ASK turn's hosted attempt, possibly via the emergency
/// local fallback. Carries the delivered outcome, the badge source, the metrics shape,
/// and whether a hosted contact SUCCEEDED (which gates the diet-queue replay).
pub struct AskResult {
    pub outcome: Result<(String, Option<String>, Option<Directives>), ApiError>,
    pub badge: BadgeSource,
    pub route: MetricsRoute,
    pub model: Option<String>,
    pub emergency: bool,
    pub failclass: Option<String>,
    pub citations: Option<usize>,
    pub validator: Option<String>,
    /// The emergency answer was delivered WITHOUT a passing citation check (the
    /// advisory validator failed) — the reply carries the prepended warning and the
    /// provenance chip must show the unverified state. Always `false` off the
    /// emergency route.
    pub citations_unverified: bool,
    pub hosted_succeeded: bool,
}

/// Update the circuit breaker from a hosted attempt's outcome: a success resets it, a
/// transport-class failure counts toward tripping it. Called only when emergency armed.
fn update_breaker(
    breaker: &CircuitBreaker,
    out: &Result<(String, Option<String>, Option<Directives>), ApiError>,
    now: Instant,
) {
    match out {
        Ok(_) => breaker.record_success(),
        Err(e) => {
            if classify_hosted_failure(e).is_transport() {
                breaker.record_transport_failure(now);
            }
        }
    }
}

/// The validator string for a metrics line from an emergency outcome.
fn emergency_validator(validator_ok: bool) -> String {
    if validator_ok {
        "ok".to_string()
    } else {
        "advisory-fail".to_string()
    }
}

/// Resolve an ASK turn: attempt the hosted turn (unless the breaker is open and
/// emergency is armed, in which case go local-first), and on a TRANSPORT-class hosted
/// failure with emergency armed, serve the read-only emergency child instead. On any
/// non-transport failure, an unarmed bridge, or an emergency child failure, this
/// returns the ORIGINAL hosted outcome exactly as today. `hosted_model` is the ambient
/// `ANTHROPIC_MODEL` for the metrics/badge model field on the hosted path.
#[allow(clippy::too_many_arguments)]
pub async fn run_ask_hosted_or_emergency(
    cfg: &Config,
    prompt: &str,
    sid: Option<&str>,
    jobs: &JobStore,
    jid: &str,
    question: &str,
    health_context: Option<&str>,
    breaker: &CircuitBreaker,
    emergency_armed: bool,
    hosted_model: Option<String>,
    recent_context: Option<&str>,
) -> AskResult {
    let now = Instant::now();
    let vaultqa_model = cfg.vaultqa_backend.as_ref().map(|(_, _, m)| m.clone());
    let base_url = cfg
        .vaultqa_backend
        .as_ref()
        .map(|(b, _, _)| b.clone())
        .unwrap_or_default();

    // A small closure that runs the emergency child and packages the AskResult, or
    // returns None when the child hard-failed (caller decides the fallback).
    let emergency = |reason: String| async {
        match run_emergency_ask_pipeline(cfg, question, health_context, recent_context).await {
            EmergencyAskOutcome::Answered {
                text,
                citations,
                validator_ok,
            } => {
                if let Some(model) = &vaultqa_model {
                    eprintln!("{}", format_emergency_provenance(&base_url, model, &reason));
                }
                Some(AskResult {
                    outcome: Ok((text, None, None)),
                    badge: BadgeSource::Emergency,
                    route: MetricsRoute::EmergencyLocal,
                    model: vaultqa_model.clone(),
                    emergency: true,
                    failclass: Some(reason),
                    citations,
                    validator: Some(emergency_validator(validator_ok)),
                    // The one path that can serve unverified citations: an emergency
                    // answer whose advisory validator failed (its text already carries
                    // the prepended warning).
                    citations_unverified: !validator_ok,
                    hosted_succeeded: false,
                })
            }
            EmergencyAskOutcome::ChildFailed => None,
        }
    };

    // Local-first: the breaker is open (hosted judged down) — skip the hosted attempt
    // and serve the emergency child. If the child also fails, fall through to actually
    // attempting hosted (better a slow real answer than none).
    if emergency_armed && breaker.should_skip_hosted(now) {
        if let Some(res) = emergency("breaker-open".to_string()).await {
            return res;
        }
    }

    // Attempt hosted.
    let out = apply_directives(run_claude_streaming(cfg, prompt, sid, jobs, jid).await);
    match out {
        Ok(v) => {
            if emergency_armed {
                breaker.record_success();
            }
            AskResult {
                outcome: Ok(v),
                badge: BadgeSource::Hosted,
                route: MetricsRoute::Hosted,
                model: hosted_model,
                emergency: false,
                failclass: None,
                citations: None,
                validator: None,
                citations_unverified: false,
                hosted_succeeded: true,
            }
        }
        Err(e) => {
            let cls = classify_hosted_failure(&e);
            if emergency_armed && cls.is_transport() {
                breaker.record_transport_failure(now);
                if let Some(res) = emergency(cls.label().to_string()).await {
                    return res;
                }
                // The emergency child also failed — return the ORIGINAL hosted error
                // exactly as today, but record that emergency was attempted.
                return AskResult {
                    outcome: Err(e),
                    badge: BadgeSource::Hosted,
                    route: MetricsRoute::Hosted,
                    model: hosted_model,
                    emergency: true,
                    failclass: Some(cls.label().to_string()),
                    citations: None,
                    validator: None,
                    citations_unverified: false,
                    hosted_succeeded: false,
                };
            }
            // Not armed, or a non-transport failure → today's behavior: surface the error.
            AskResult {
                outcome: Err(e),
                badge: BadgeSource::Hosted,
                route: MetricsRoute::Hosted,
                model: hosted_model,
                emergency: false,
                failclass: if emergency_armed {
                    Some(cls.label().to_string())
                } else {
                    None
                },
                citations: None,
                validator: None,
                citations_unverified: false,
                hosted_succeeded: false,
            }
        }
    }
}

// ---- Handlers -------------------------------------------------------------

/// Liveness probe. Always returns `200 { "ok": true }` with **no auth and no
/// secrets** — a bare unauthenticated caller learns only that the bridge is up.
/// The vault and `claude` binary paths are operator detail (they leak the host's
/// filesystem layout), so they are surfaced **only to an authenticated caller**;
/// an unauthenticated probe never sees them.
pub async fn health(State(st): State<AppState>, headers: HeaderMap) -> Json<Value> {
    // The crate version is returned UNCONDITIONALLY, before the auth-gated
    // operator detail — a version string isn't sensitive, and the app shows it
    // as the running bridge version alongside its own.
    let mut body = json!({ "ok": true, "version": env!("CARGO_PKG_VERSION") });
    if check_auth(&headers, &st.cfg.token).is_ok() {
        body["vault"] = json!(st.cfg.vault);
        body["claude"] = json!(st.cfg.claude_bin);
    }
    Json(body)
}

/// Expose the built-in Ask/Tell wrapper instructions so the app can show them as
/// the editable "defaults" and reset to them, plus the fixed Ask/Tell safety
/// floors so the app can display them read-only. Returns the exact const strings
/// `build_prompt` applies for a fresh turn, so the app's default matches what the
/// bridge would use. Same bearer auth as `/jesse`.
pub async fn jesse_prompts(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    Ok(Json(json!({
        "ask": ASK_PREAMBLE,
        "tell": TELL_PREAMBLE,
        "ask_floor": ASK_FLOOR,
        "tell_floor": TELL_FLOOR,
    })))
}

pub async fn jesse(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<JesseRequest>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    // Meal-corrections ack (JESSE_MEAL_LOG v2): if this turn carries the highest
    // `corrections_seq` the app has APPLIED, prune every queued batch at/below it before
    // any work — the app has taken responsibility for those, so they must not redeliver.
    // Done here (not in the spawned task) so the prune is committed even if the turn is
    // shed/queued below. Unacked batches simply redeliver; app idempotency makes that safe.
    if let Some(acked) = req.meal_corrections_ack {
        st.meal_corrections.prune_through(acked);
    }

    // Rate limit before doing any work (C3). A per-service token bucket; bursts
    // beyond JESSE_RATE_PER_MIN are shed with 429 rather than queued.
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }

    // Idempotency (POST /jesse dedup). Auth + rate limiting above are unchanged and
    // apply first. When a valid `request_id` is present AND already maps to a live
    // job (queued, running, or a terminal result still in its retention window),
    // short-circuit here: create nothing, take no concurrency permit, enqueue
    // nothing, and hand back the EXISTING job id in the same fresh-accept shape. A
    // request_id whose job has been reaped is unmapped, so it falls through as brand
    // new. Absent request_id skips this entirely — byte-for-byte today's behavior.
    if let Some(rid) = req.request_id.as_deref() {
        if let Err(msg) = validate_request_id(rid) {
            // A one-line JSON error, distinct from a plain-text ApiError so the shape
            // matches the JSON the client already parses on every other response.
            return Ok((StatusCode::BAD_REQUEST, Json(json!({ "error": msg }))).into_response());
        }
        if let Some(existing) = st.jobs.dedup_lookup(rid) {
            return Ok(accepted_running(&existing));
        }
    }

    let mode = req.mode.trim().to_lowercase();
    // Kill switch + gate: attempt the local diet-logging pipeline only when a diet
    // backend is configured AND this is a diet-shaped Tell. With no backend this is
    // always false, so the turn takes today's hosted path byte-for-byte. Decided here
    // (before any work) but ACTED ON inside the spawned task below, so a fall-through
    // reuses the same permit/scratch/job machinery as a normal turn.
    let try_diet = should_try_local_diet(&st.cfg, &mode, &req.text);
    // Kill switch + STRICT gate: attempt the contained read-only vault-QA child only
    // when a vault-QA backend is configured AND this is a self-referential Ask that
    // carries no attachment/image and is not diet-gate-shaped (diet keeps precedence —
    // `try_diet` is Tell-only, so they never both fire, but the `!try_diet` guard makes
    // the precedence explicit). With no backend this is always false, so every Ask
    // takes today's hosted path byte-for-byte. Decided here (before any work) but ACTED
    // ON inside the spawned task below, so a fall-through reuses the same permit/job
    // machinery as a normal turn.
    let try_vaultqa = !try_diet
        && should_try_local_vaultqa(&st.cfg, &mode, &req.text, !req.attachments.is_empty());
    let is_followup = req.session_id.is_some();
    // Compute the clock header ONCE here and build the prompt from it, so the SAME
    // clock can recompute the floor boundary when the hosted catch-up block is spliced
    // in under the permit (context carry, Piece 3). `build_prompt` reads the clock
    // itself; `build_prompt_at` takes it explicitly, so we capture it.
    let clock = clock_line();
    let prompt = build_prompt_at(
        &clock,
        &mode,
        &req.text,
        is_followup,
        req.voice,
        req.instructions.as_deref(),
        req.floor_override.as_deref(),
        req.health_context.as_deref(),
        req.health_context_requested.unwrap_or(false),
        req.health_context_unavailable.unwrap_or(false),
    )?;

    // Concurrency + bounded queue: decide whether this turn runs now, waits for a
    // permit, or is shed. A free permit → run immediately (as before). No free
    // permit but the wait queue has room → QUEUE it: we still create the job and
    // return 202 below, and the permit is acquired INSIDE the spawned task, so a
    // second client's turn waits for the first to finish and then runs (the
    // single-writer default protects vault files from concurrent rewrites). Beyond
    // the queue (`max_queued`) → shed with 429, exactly as before. The admission is
    // carried into the task; on any early return below it drops cleanly (a Ready
    // permit is released, a Queued ticket frees its reserved slot).
    let admission = match st.queue.admit() {
        Some(a) => a,
        None => {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                "busy: too many turns queued".to_string(),
            ))
        }
    };

    // Decode + validate any attachments (bad input → 400; the permit drops on
    // this early return), then write them to a per-request scratch dir and name
    // the paths in the prompt so the agent reads them. The scratch dir's Drop
    // guard (moved into the turn task below) removes it on every exit path.
    let decoded = validate_and_decode_attachments(&st.cfg, &req.attachments)?;
    // Whether this turn carried attachments — the ledger records the raw text with a
    // `[attachment omitted]` marker rather than the bytes (context carry).
    let had_attachments = !decoded.is_empty();
    let (prompt, scratch) = if decoded.is_empty() {
        (prompt, None)
    } else {
        let scratch = ScratchDir::create(&st.cfg.scratch_base()).map_err(|e| {
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

    // Eviction runs on a periodic background task (`spawn_eviction_task`), NOT
    // here on the request hot path — a sweep that unlinks files must never block
    // a turn from starting (H3).
    // Create the job under the optional idempotency key. The check-and-insert is
    // atomic under the job store's one lock, so if a concurrent duplicate POST won
    // the race between our phase-1 lookup above and here, we get `Duplicate` and
    // spawn nothing — dropping the admission (releasing the permit / freeing the
    // queue slot) and the scratch dir on this early return, and handing back the
    // winner's id in the same fresh-accept shape. This is what makes two concurrent
    // duplicate POSTs collapse to exactly one job.
    let job_id = match st.jobs.create_with_request_id(req.request_id.clone()) {
        CreateOutcome::Created(id) => id,
        CreateOutcome::Duplicate(existing) => return Ok(accepted_running(&existing)),
    };
    // Open the live stream before spawning so a phone that opens
    // `GET /jesse/stream/{job_id}` immediately finds the broadcast channel.
    st.jobs.stream_register(&job_id);

    // Run the turn on its OWN task that owns the child. Dropping this request
    // future (the phone suspends, the socket drops) does not cancel a spawned
    // tokio task, so the turn always runs to completion and lands in the store.
    let cfg = st.cfg.clone();
    let jobs = st.jobs.clone();
    let jid = job_id.clone();
    let sid = req.session_id.clone();
    // The raw utterance the local diet pipeline parses (distinct from the wrapped
    // `prompt`, which the hosted path — including any diet fall-through — still uses).
    // The vault-QA child answers this same raw question.
    let raw_text = req.text.clone();
    // The phone-supplied health block, framed into the vault-QA child prompt the same
    // way the hosted turn frames it (already size-checked by `build_prompt` above).
    let health_context = req.health_context.clone();
    // Push machinery for the completion notification (no-ops when push is off).
    let apns = st.apns.clone();
    let devices = st.devices.clone();
    let notify = st.notify.clone();
    // Emergency-fallback machinery (Piece 4): the mode string (for the emergency-ASK
    // gate + metrics) and the shared circuit breaker. Both inert unless emergency is
    // armed — checked inside the task.
    let mode = mode.clone();
    let breaker = st.breaker.clone();
    // Context carry (Piece 1–3): the ledger, the title store (for a synthetic→real
    // title move), and the captured clock (so the catch-up splice recomputes the floor
    // boundary from the same header the prompt was built with). All inert when carry off.
    let context = st.context.clone();
    let titles = st.titles.clone();
    // Meal-corrections queue (JESSE_MEAL_LOG v2): merged into the delivered `meal_log` at
    // completion, so off-app corrections ride this turn's terminal result.
    let meal_corrections = st.meal_corrections.clone();
    let clock = clock.clone();
    let handle = tokio::spawn(async move {
        // Hold the scratch dir for the whole turn; its Drop removes the decoded
        // attachment files when the task ends — success, error, or timeout. The
        // files therefore survive run_claude's internal retries and are cleaned
        // exactly once, here.
        let _scratch = scratch;
        // If the body below panics — or the task is aborted (cancel) while still
        // waiting for a permit — this guard's Drop drives the job to a terminal
        // state + terminal stream frame (M2). It's write-once, so a cancel that
        // already wrote `Cancelled` wins; the guard then no-ops.
        let mut guard = TurnGuard::new(jobs.clone(), jid.clone());
        // Acquire the concurrency permit and hold it for the whole turn. A Ready
        // admission already holds one (run immediately); a Queued admission WAITS
        // here until a permit frees — a second client's turn blocks behind the
        // first. Cancelling a queued turn aborts this task while it waits: the
        // ticket's Drop frees its queue slot and no `claude` is ever spawned.
        //
        // The turn/timeout clock starts only AFTER this — `run_claude_streaming`'s
        // JESSE_TIMEOUT is measured from its own call below, never while queued.
        let _permit: OwnedSemaphorePermit = match admission {
            Admission::Ready(p) => p,
            Admission::Queued(ticket) => {
                // Reflect the wait in the live stream, reusing the activity hint
                // mechanism (no new SSE frame type). A late/reconnecting subscriber
                // sees it via the accumulated snapshot on subscribe.
                jobs.stream_push_activity(&jid, QUEUED_ACTIVITY);
                ticket.wait_for_permit().await
            }
        };

        // Turn wall clock starts here (after the permit — queued time doesn't count).
        let turn_start = Instant::now();
        // Emergency fallback (Piece 4) is armed only when JESSE_EMERGENCY_LOCAL is on
        // AND the vault-QA triple is set (it supplies the backend + read-only child).
        // With it disarmed, every branch below is byte-for-byte today's behavior.
        let emergency_armed = emergency_armed(&cfg);
        let hosted_model = env_string("ANTHROPIC_MODEL");
        let diet_queue = DietQueue::from_cfg(&cfg);

        // ---- Context carry (Piece 3 + 4): read the thread's ledger UNDER THE PERMIT
        // so two queued turns on one thread can never both carry the same pending block.
        // `pending` (for the hosted catch-up) and `recent` (for a local child) are read
        // once here; both are empty when carry is off (the ledger is inert) or the
        // thread is unknown, so every downstream splice/inject is a byte-for-byte no-op.
        let thread_key = sid.clone();
        let pending = thread_key
            .as_deref()
            .map(|k| context.pending(k))
            .unwrap_or_default();
        // Build the hosted catch-up block + the ids actually included in it (only those
        // get marked in_hosted_history on success, so an over-cap dropped-oldest entry
        // stays pending — at-least-once, never a silent drop).
        let (catchup_block, injected_ids) = match build_catchup_block(&pending) {
            Some((block, ids)) => (Some(block), ids),
            None => (None, Vec::new()),
        };
        // Splice the catch-up block into the hosted prompt (ahead of the floor, adjacent
        // to the health block). None → the prompt is byte-for-byte unchanged.
        let hosted_prompt = match &catchup_block {
            Some(block) => splice_catchup(&prompt, block, &clock, health_context.as_deref()),
            None => prompt.clone(),
        };
        // The RECENT CONVERSATION block for a local child (vault-QA / emergency), read
        // from the same thread. `None` when there is no history (fresh-turn prompts stay
        // byte-for-byte today's).
        let recent_block = thread_key
            .as_deref()
            .map(|k| context.recent(k, RECENT_MAX_TURNS))
            .and_then(|turns| build_recent_conversation_block(&turns));

        // A hosted turn: run the streamed agent turn and extract any agent-emitted
        // directive from the reply's final line. A recognized directive is stripped
        // from the text and attached under `directives`. This is today's path — and the
        // diet fall-through target. Uses `hosted_prompt` (the catch-up-spliced prompt).
        let run_hosted = || async {
            apply_directives(
                run_claude_streaming(&cfg, &hosted_prompt, sid.as_deref(), &jobs, &jid).await,
            )
        };

        // Resolve the turn. Each branch yields the outcome, the BADGE SOURCE, the
        // metrics shape, and whether a hosted contact succeeded (which gates the
        // diet-queue replay below).
        let mut route = MetricsRoute::Hosted;
        let mut m_model: Option<String> = hosted_model.clone();
        let mut m_rung: u8 = 0;
        let mut m_citations: Option<usize> = None;
        let mut m_validator: Option<String> = None;
        let mut m_emergency = false;
        let mut m_failclass: Option<String> = None;
        // The machine-readable rung-2 reason on a diet rung-2 fall-through (content-free
        // code; None on every other turn). Threaded into the metrics line so the audit
        // can separate pipeline failures from correct rejections of non-loggable turns.
        let mut m_diet_reason: Option<String> = None;
        // Provenance-only: whether an emergency answer skipped the citation check.
        // Never feeds the metrics line (which records the validator verdict directly).
        let mut m_citations_unverified = false;
        let mut hosted_succeeded = false;

        let diet_model = || cfg.diet_backend.as_ref().map(|(_, _, m)| m.clone());
        let vaultqa_model = || cfg.vaultqa_backend.as_ref().map(|(_, _, m)| m.clone());

        let (mut outcome, badge_source) = if try_diet {
            // Local diet pipeline: extract → verify → append → derive mirror.
            match run_diet_pipeline(&cfg, &raw_text).await {
                DietPipelineOutcome::Logged {
                    dashboard,
                    directives,
                } => {
                    // The blocking hosted verify succeeded → hosted is reachable.
                    hosted_succeeded = true;
                    route = MetricsRoute::DietLocal;
                    m_model = diet_model();
                    (
                        Ok((dashboard, None, Some(directives))),
                        BadgeSource::DietVerify,
                    )
                }
                DietPipelineOutcome::LoggedNoMirror { dashboard } => {
                    hosted_succeeded = true;
                    route = MetricsRoute::DietLocal;
                    m_model = diet_model();
                    (Ok((dashboard, None, None)), BadgeSource::DietVerify)
                }
                DietPipelineOutcome::VerifyUnavailable {
                    err,
                    utterance,
                    entries,
                    date,
                    offset,
                } => {
                    let cls = classify_hosted_failure(&err);
                    // Emergency: hosted verify unreachable → the BRIDGE queues the
                    // extracted entry (never a model, never the CSV) for later verify.
                    if emergency_armed && cls.is_transport() && diet_queue.is_available() {
                        let id = random_hex();
                        let item = QueuedEntry {
                            id: id.clone(),
                            queued_ts: rfc3339_utc(SystemTime::now()),
                            date,
                            offset,
                            utterance,
                            entries,
                        };
                        match diet_queue.enqueue(&item) {
                            Ok(()) => {
                                eprintln!("{}", format_queued_provenance(&id));
                                breaker.record_transport_failure(Instant::now());
                                route = MetricsRoute::EmergencyLocal;
                                m_model = diet_model();
                                m_emergency = true;
                                m_failclass = Some(cls.label().to_string());
                                (
                                    Ok((queued_reply_text(), None, None)),
                                    BadgeSource::DietQueued,
                                )
                            }
                            Err(e) => {
                                // Couldn't queue → today's behavior (run hosted).
                                eprintln!("jesse-bridge: diet queue enqueue failed: {e} — hosted fallback");
                                let out = run_hosted().await;
                                hosted_succeeded = out.is_ok();
                                if emergency_armed {
                                    update_breaker(&breaker, &out, Instant::now());
                                }
                                m_rung = DietRung::Verify.num();
                                (out, BadgeSource::Hosted)
                            }
                        }
                    } else {
                        // Not armed or a non-transport verify error → today's behavior:
                        // exactly FallThrough { rung: Verify } (run the hosted turn).
                        let out = run_hosted().await;
                        hosted_succeeded = out.is_ok();
                        if emergency_armed {
                            update_breaker(&breaker, &out, Instant::now());
                        }
                        m_rung = DietRung::Verify.num();
                        (out, BadgeSource::Hosted)
                    }
                }
                DietPipelineOutcome::FallThrough { rung, reason } => {
                    let out = run_hosted().await;
                    hosted_succeeded = out.is_ok();
                    if emergency_armed {
                        update_breaker(&breaker, &out, Instant::now());
                    }
                    m_rung = rung.num();
                    m_diet_reason = reason.map(|r| r.code());
                    (out, BadgeSource::Hosted)
                }
            }
        } else if try_vaultqa {
            // Local vault-QA lookup (routine route). On success the tokens stay local
            // and no hosted turn runs. On any ladder rung it becomes a hosted ASK
            // attempt (which, when emergency is armed, may serve the emergency child).
            match run_vaultqa_pipeline(
                &cfg,
                &raw_text,
                health_context.as_deref(),
                recent_block.as_deref(),
            )
            .await
            {
                VaultqaOutcome::Answered { text, citations } => {
                    route = MetricsRoute::VaultqaLocal;
                    m_model = vaultqa_model();
                    m_citations = Some(citations);
                    m_validator = Some("ok".to_string());
                    (Ok((text, None, None)), BadgeSource::Vault)
                }
                VaultqaOutcome::FallThrough { rung } => {
                    m_rung = rung.num();
                    let r = run_ask_hosted_or_emergency(
                        &cfg,
                        &hosted_prompt,
                        sid.as_deref(),
                        &jobs,
                        &jid,
                        &raw_text,
                        health_context.as_deref(),
                        &breaker,
                        emergency_armed,
                        hosted_model.clone(),
                        recent_block.as_deref(),
                    )
                    .await;
                    route = r.route;
                    m_model = r.model;
                    m_emergency = r.emergency;
                    m_failclass = r.failclass;
                    m_citations = r.citations;
                    m_validator = r.validator;
                    m_citations_unverified = r.citations_unverified;
                    hosted_succeeded = r.hosted_succeeded;
                    (r.outcome, r.badge)
                }
            }
        } else if mode == "ask" {
            // A plain (non-gated) ASK: emergency + breaker apply on a hosted transport
            // failure. With emergency disarmed this is byte-for-byte the old hosted path.
            let r = run_ask_hosted_or_emergency(
                &cfg,
                &hosted_prompt,
                sid.as_deref(),
                &jobs,
                &jid,
                &raw_text,
                health_context.as_deref(),
                &breaker,
                emergency_armed,
                hosted_model.clone(),
                recent_block.as_deref(),
            )
            .await;
            route = r.route;
            m_model = r.model;
            m_emergency = r.emergency;
            m_failclass = r.failclass;
            m_citations = r.citations;
            m_validator = r.validator;
            m_citations_unverified = r.citations_unverified;
            hosted_succeeded = r.hosted_succeeded;
            (r.outcome, r.badge)
        } else {
            // A non-diet TELL: no local fallback exists, so always attempt hosted (the
            // breaker never skips here). Update the breaker so a Tell's hosted health
            // still feeds it when emergency is armed.
            let out = run_hosted().await;
            hosted_succeeded = out.is_ok();
            if emergency_armed {
                update_breaker(&breaker, &out, Instant::now());
            }
            (out, BadgeSource::Hosted)
        };

        // ---- Context carry (Piece 1–3): from the SAME pre-badge outcome the badge and
        // metrics use, record the delivered turn, resolve the thread key + synthetic
        // session id, mark the injected pending entries on hosted success, re-key on a
        // new session id, and move a title from a synthetic id to the real one. A failed
        // turn (Err) records nothing. Entirely inert when carry is off (the ledger is a
        // no-op and this block skips), so every path stays byte-for-byte today's.
        if cfg.context_carry {
            if let Ok((reply_text, reply_sid, _)) = &outcome {
                let reply_text = reply_text.clone();
                let reply_sid = reply_sid.clone();
                let (_route, in_hist) = ContextRoute::from_badge_source(badge_source);
                let request_sid = sid.clone();
                let mut minted: Option<String> = None;
                let record_key: Option<String> = if in_hist {
                    // Hosted SUCCESS: the catch-up block reached the resumed session, so
                    // mark the injected pending entries and re-key to the real returned
                    // id (unconditional — a no-op when unchanged). The reply already
                    // carries the real id; the app stores it.
                    let real_id = reply_sid.clone().or_else(|| request_sid.clone());
                    if let (Some(real), Some(from)) = (&real_id, &request_sid) {
                        context.mark_in_hosted_history(from, &injected_ids);
                        if from != real {
                            context.rekey(from, real);
                            // Move any title stashed under a synthetic id to the real id.
                            if is_synthetic_session_id(from) {
                                titles.rename(from, real);
                            }
                        }
                    }
                    real_id
                } else {
                    // A LOCAL route. Record under the existing thread, or (a fresh
                    // locally-served thread with no request session) mint a synthetic id
                    // and hand it back as the reply's session id so the app stores it.
                    match &request_sid {
                        Some(k) => Some(k.clone()),
                        None => {
                            let synthetic = mint_synthetic_session_id();
                            minted = Some(synthetic.clone());
                            Some(synthetic)
                        }
                    }
                };
                // Record the delivered turn (non-empty replies only — a directive-only
                // turn strips to "" and the app retries, so it is not a delivered turn).
                if let Some(key) = &record_key {
                    if !reply_text.trim().is_empty() {
                        context.record(
                            key,
                            make_context_turn(
                                &mode,
                                badge_source,
                                &raw_text,
                                had_attachments,
                                &reply_text,
                            ),
                        );
                    }
                }
                // Hand the minted synthetic id back on the reply (through the app's
                // existing `?? sessionId` line — no app change) so the follow-up carries it.
                if let Some(synthetic) = minted {
                    if let Ok((_, s, _)) = &mut outcome {
                        *s = Some(synthetic);
                    }
                }
            }
        }

        // Build the structured provenance (v2) from the SAME pre-finalize outcome and
        // turn state that produce the text badge, so the two are always both-present or
        // both-absent. It rides on `JobState::Done` next to `directives`, reaching BOTH
        // the poll result and the SSE `done` frame; the metrics line and audit are
        // untouched. `route`/`m_model` are the resolved route + backend model (the same
        // the metrics line records); `m_citations_unverified` is the emergency advisory
        // verdict (always false off that route).
        let provenance = reply_provenance(
            &outcome,
            &cfg,
            route,
            badge_source,
            m_model.clone(),
            hosted_model.as_deref(),
            m_citations_unverified,
        );
        // Finalize the delivered reply: append the model badge (display only) at this
        // single point, so BOTH the poll result and the SSE `done` frame carry it.
        let outcome = finalize_reply_badge(outcome, &cfg, badge_source, hosted_model.as_deref());

        // Structured metrics (Piece 3): one content-free line per GATED / ROUTED /
        // EMERGENCY turn, at this same finalization seam. A no-op when JESSE_METRICS_LOG
        // is unset. Never the question/answer/tokens. Emitted before `complete` so a
        // slow disk can't delay the terminal frame? — no: keep it after we know the
        // badge string; it cannot alter `outcome`.
        let metrics_relevant = try_diet || try_vaultqa || m_emergency;
        if metrics_relevant {
            let badge = match &outcome {
                Ok((text, _, _)) if !text.trim().is_empty() => {
                    model_badge_line(&cfg, badge_source, hosted_model.as_deref())
                }
                _ => None,
            };
            append_metrics_line(
                &cfg,
                &MetricsRecord {
                    ts: rfc3339_utc(SystemTime::now()),
                    turn_id: jid.clone(),
                    mode: mode.clone(),
                    route,
                    model: m_model,
                    rung: m_rung,
                    wall_ms: turn_start.elapsed().as_millis() as u64,
                    ttft_ms: None,
                    tool_calls: None,
                    citations: m_citations,
                    validator: m_validator,
                    badge,
                    emergency: m_emergency,
                    hosted_failure_class: m_failclass,
                    diet_reason: m_diet_reason,
                },
            );
        }

        // Merge persisted off-app meal corrections (JESSE_MEAL_LOG v2) into the delivered
        // `meal_log` at this single finalization seam, BEFORE the job is stored — so BOTH
        // the poll result and the SSE `done` frame (each reads the stored `Done` state)
        // carry the identical merged value. Queued batches lead, the turn's own extracted
        // block follows, and the highest queued seq is stamped as `corrections_seq` for the
        // app to ack. A no-op when the queue is empty/unavailable, and only the Ok
        // (delivered) path carries directives — a failed turn delivers no meal_log, so its
        // corrections simply redeliver on the next successful turn (at-least-once).
        let outcome = match outcome {
            Ok((text, sid_out, directives)) => Ok((
                text,
                sid_out,
                merge_meal_corrections(directives, &meal_corrections),
            )),
            err => err,
        };

        jobs.complete_with_provenance(&jid, outcome, provenance);
        // Close the live stream with the frame matching the state that actually
        // landed. `complete` is write-once, so a cancel that won the race already
        // set `Cancelled` (and `cancel` already emitted that frame + removed the
        // stream entry, making this a no-op). Reading the post-`complete` state
        // keeps the terminal frame and the stored result perfectly consistent.
        jobs.emit_terminal_frame(&jid);
        // The job reached a terminal state cleanly — disarm the guard so its Drop
        // is a no-op (the right frame is already out).
        guard.disarm();

        // Emergency diet-queue replay (Piece 4): on a SUCCESSFUL hosted contact, drain
        // any queued diet entries oldest-first through the exact verify-then-append
        // path. Run here — INSIDE the turn task, with the concurrency permit still held
        // — so replay's vault writes respect the single-writer invariant and never race
        // another turn. The reply is already stored above, so replay only delays the
        // NEXT turn's start, never this reply. A no-op when emergency is disarmed, no
        // hosted contact succeeded, or the queue is empty.
        if emergency_armed && hosted_succeeded && diet_queue.is_available() {
            replay_diet_queue(&cfg, &diet_queue).await;
        }

        // Fire the completion push if this turn was flagged for it (the phone
        // backgrounded mid-turn). A no-op unless push is configured, the job is
        // flagged, it ended Done/Failed, and a device token is registered. Any
        // failure is logged and swallowed — the reply is already stored above, so
        // a push problem can't disturb it. Awaited (not detached) so the push
        // can't outlive the runtime on shutdown; it adds only ~one HTTP round-trip
        // to a turn that already finished.
        notify_if_complete(apns.as_deref(), &devices, &notify, &jobs, &jid).await;
    });

    // Store the task's abort handle so `POST /jesse/cancel/{id}` can stop it.
    // Aborting drops the task → drops the `Child` (kill_on_drop) → kills `claude`
    // and releases the permit held inside the task.
    st.jobs.set_abort(&job_id, handle.abort_handle());

    // Hand back the job_id IMMEDIATELY — never hold the connection. The turn runs
    // on the detached task above and lands in the job store exactly as before;
    // the phone always gets the job_id on this first response, then streams
    // (`GET /jesse/stream/{job_id}`) and/or polls (`GET /jesse/result/{job_id}`)
    // for the reply. Dropping `handle` here does NOT cancel the spawned task.
    //
    // Root cause this fixes: the old grace-hold delivered the job_id LATE (after
    // up to `JESSE_GRACE_SECS`). If the POST socket dropped during that hold —
    // phone suspended, NAT/idle timeout — the turn was already running detached
    // but the phone never received its id, so it could never poll the reply: an
    // orphaned turn. Returning the id up front shrinks the unrecoverable window
    // to the single request/response round-trip.
    //
    // Tradeoff (belt-and-suspenders): if the network drops before THIS response
    // reaches the phone, the turn was still created server-side with a job_id the
    // phone never saw — unavoidably unrecoverable without an id. That window is
    // now one round-trip instead of a multi-second hold, which is the whole point
    // of delivering the id eagerly.
    Ok(accepted_running(&job_id))
}

/// Fetch a turn's state by job id. This is what the app polls after a dropped
/// socket. Same bearer auth as `/jesse`. Unknown/expired id → 404.
pub async fn jesse_result(
    State(st): State<AppState>,
    UrlPath(job_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    // get_retrieving (not get) so a terminal result's first fetch starts the
    // short post-fetch grace; until then it's held the full TTL.
    match st.jobs.get_retrieving(&job_id) {
        Some(JobState::Running) => Ok(Json(json!({ "status": "running" }))),
        Some(JobState::Done {
            response,
            session_id,
            directives,
            provenance,
        }) => Ok(Json(json!({
            "status": "done",
            "response": response,
            "session_id": session_id,
            "directives": directives_to_value(&directives),
            "provenance": provenance_to_value(&provenance),
        }))),
        Some(JobState::Failed { error }) => Ok(Json(json!({ "status": "failed", "error": error }))),
        Some(JobState::Cancelled) => Ok(Json(json!({ "status": "cancelled" }))),
        None => Err((
            StatusCode::NOT_FOUND,
            "unknown or expired job id".to_string(),
        )),
    }
}

/// Cancel a running turn by job id (`POST /jesse/cancel/{id}`). Same bearer auth
/// as `/jesse`. Aborts the turn — killing the `claude` child and freeing the
/// concurrency slot — and marks the job `Cancelled`. **Idempotent:** an unknown
/// id, an already-finished job, or a repeat cancel all return `204`, never an
/// error; the phone fires this best-effort and may race the turn's own
/// completion. Returns no body.
pub async fn jesse_cancel(
    State(st): State<AppState>,
    UrlPath(job_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    // Drop any pending notify flag — a user who cancels is present and doesn't
    // want a push, and a Cancelled state isn't pushable anyway.
    st.notify.take(&job_id);
    match st.jobs.cancel(&job_id) {
        CancelOutcome::Cancelled => {
            eprintln!(
                "cancel: job {job_id} aborted by client — claude killed, concurrency slot freed"
            );
        }
        CancelOutcome::AlreadyTerminal => {
            eprintln!("cancel: job {job_id} already finished — no-op");
        }
        CancelOutcome::Unknown => {
            eprintln!("cancel: job {job_id} unknown — no-op (idempotent)");
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /jesse/device` — register/update this phone's APNs device token. Same
/// bearer auth as `/jesse`. Idempotent upsert: a re-register overwrites the
/// stored token. Persisted (when a state dir is configured) so it survives a
/// restart. Works even when push is disabled — the bridge just won't send. Never
/// logs the token.
pub async fn jesse_device(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<DeviceRequest>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    let token = req.token.trim().to_string();
    if token.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "missing device token".to_string()));
    }
    st.devices.set(token);
    Ok(Json(json!({ "ok": true })))
}

/// `POST /jesse/notify/{job_id}` — the phone, about to background with this turn
/// still in flight, asks to be pushed when it completes. Same bearer auth.
/// Best-effort and idempotent: flagging an unknown/finished job is harmless. If
/// the turn has ALREADY finished (it beat the phone to the background), the push
/// is fired now so the signal isn't lost. Returns 204.
pub async fn jesse_notify(
    State(st): State<AppState>,
    UrlPath(job_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    st.notify.insert(&job_id);
    // Close the race: if the turn already reached a pushable terminal state, push
    // now; otherwise the flag stays and the completion path pushes later.
    notify_if_complete(
        st.apns.as_deref(),
        &st.devices,
        &st.notify,
        &st.jobs,
        &job_id,
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /jesse/title` — turn one conversation's text into a VERY SHORT title.
/// **Stateless and NOT a turn:** no job is created, no session, nothing is
/// persisted, no live stream, no push, no eviction interaction — it touches none
/// of the jobs/streams/aborts mutexes. Same bearer auth and same rate limiter as
/// `/jesse`, reusing the same `claude` invocation discipline via
/// `run_claude_oneshot` (identical allow/deny tool posture and `kill_on_drop`).
///
/// Bounded twice: a strict input cap (`MAX_TITLE_INPUT_BYTES`) rejects an
/// oversized body with `413` BEFORE any `claude` spawn, and a short timeout
/// (`TITLE_TIMEOUT_SECS`, tighter than a turn) bounds the run. Any failure or
/// timeout is a clean non-2xx the app treats as "no title" and degrades from
/// (falling back to its derived title, never surfacing an error to the user); it
/// is never fatal to the bridge. The raw model reply is clamped to a single line
/// of at most `MAX_TITLE_CHARS` before returning `{ "title": ... }`.
pub async fn jesse_title(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TitleRequest>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    // Same rate limiter as /jesse — a title request is a first-class accepted
    // request against the per-service bucket, shed with 429 on a burst.
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }

    let text = req.text.trim();
    if text.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "missing text to title".to_string()));
    }
    // Strict input cap BEFORE any claude spawn — a title request can never make a
    // giant model call. Enforced on the trimmed byte length against the named cap.
    if text.len() > MAX_TITLE_INPUT_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("text exceeds the {MAX_TITLE_INPUT_BYTES}-byte title input cap"),
        ));
    }

    // One bounded, stateless claude call. No job store, no stream, no session.
    let raw = run_claude_oneshot(&st.cfg, &build_title_prompt(text), TITLE_TIMEOUT_SECS).await?;
    let title = sanitize_title(&raw);
    if title.is_empty() {
        // Nothing usable came back — a clean non-2xx the app degrades from.
        return Err((
            StatusCode::BAD_GATEWAY,
            "claude returned no usable title".to_string(),
        ));
    }
    // If the client named a session, persist the minted title under it before
    // returning, so `GET /jesse/sessions` can show it. No session_id → today's
    // stateless behavior (nothing stored). The store trims + clamps defensively.
    if let Some(session_id) = req.session_id.as_deref() {
        st.titles.set(session_id, &title);
    }
    Ok(Json(json!({ "title": title })))
}

/// `POST /jesse/meal-corrections` — accept a `JESSE_MEAL_LOG v2` meal-events batch from an
/// external logging agent (a Cowork/desktop session that logged, corrected, or deleted a
/// meal with no app turn to carry the block) and persist it to the corrections queue.
///
/// Same bearer auth as every other endpoint (LAN-only, single-user trust). The body is the
/// v2 payload object `{"meals":[…],"retract":[…]}`; it is validated against the EXACT same
/// contract as an in-reply `JESSE_MEAL_LOG v2` directive ([`parse_meal_batch_v2`] — required
/// meal fields, finite non-negative nutrients, caps, no id in both arrays, at least one of
/// meals/retract), so a malformed or attacker-shaped body is a loud `400`, never a partial
/// enqueue. On success the assigned monotonic `seq` is returned; the app acks it once
/// applied. At the queue cap the post is rejected `429` (a visible failure at the source
/// beats a silent drop); with persistence off it is `503`.
pub async fn jesse_meal_corrections(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    let obj = body.as_object().ok_or((
        StatusCode::BAD_REQUEST,
        "body is not a JSON object".to_string(),
    ))?;
    let (meals, retract) = parse_meal_batch_v2(obj).map_err(|reason| {
        eprintln!("meal-corrections: rejected malformed batch ({reason})");
        (
            StatusCode::BAD_REQUEST,
            format!("malformed meal batch: {reason}"),
        )
    })?;
    match st.meal_corrections.enqueue(meals, retract) {
        Ok(seq) => Ok(Json(json!({ "status": "queued", "corrections_seq": seq }))),
        Err(EnqueueError::Full) => Err((
            StatusCode::TOO_MANY_REQUESTS,
            format!("meal-corrections queue is full (cap {MAX_MEAL_CORRECTION_BATCHES}) — ack and drain first"),
        )),
        Err(EnqueueError::Unavailable) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "meal-corrections queue unavailable (no state dir configured)".to_string(),
        )),
        Err(EnqueueError::Io(e)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not persist meal batch: {e}"),
        )),
    }
}

/// Build the axum router with its shared state. Kept separate from `main` so
/// tests can drive the same routes via `tower::ServiceExt::oneshot` without
/// binding a socket. The running server uses exactly this router.
pub fn app(state: AppState) -> Router {
    // Raise axum's default 2 MB body cap to fit base64 attachments, but no
    // higher than the attachment caps require — this is the outermost bound on
    // how much any one request can make the bridge buffer.
    let body_limit = attachment_body_limit(&state.cfg);
    Router::new()
        .route("/health", get(health))
        .route("/jesse", post(jesse))
        .route("/jesse/prompts", get(jesse_prompts))
        .route("/jesse/diet", get(jesse_diet))
        .route("/jesse/sessions", get(jesse_sessions))
        .route("/jesse/session/:session_id", axum::routing::delete(jesse_session_delete))
        .route("/jesse/title", post(jesse_title))
        .route("/jesse/meal-corrections", post(jesse_meal_corrections))
        .route("/jesse/result/:job_id", get(jesse_result))
        .route("/jesse/stream/:job_id", get(jesse_stream))
        .route("/jesse/cancel/:job_id", post(jesse_cancel))
        .route("/jesse/device", post(jesse_device))
        .route("/jesse/notify/:job_id", post(jesse_notify))
        .layer(DefaultBodyLimit::max(body_limit))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_request_id_accepts_alnum_and_hyphens_within_length() {
        assert!(validate_request_id("abc123").is_ok());
        assert!(validate_request_id("A1B2-c3d4-EF56").is_ok());
        assert!(validate_request_id("--------").is_ok());
        // Exactly 64 chars is the boundary and allowed.
        assert!(validate_request_id(&"a".repeat(64)).is_ok());
    }

    #[test]
    fn validate_request_id_rejects_empty_over_length_and_bad_chars() {
        assert!(validate_request_id("").is_err());
        // 65 chars is one past the cap.
        assert!(validate_request_id(&"a".repeat(65)).is_err());
        // Disallowed characters: underscore, dot, slash, space, unicode.
        assert!(validate_request_id("has_underscore").is_err());
        assert!(validate_request_id("has.dot").is_err());
        assert!(validate_request_id("has/slash").is_err());
        assert!(validate_request_id("has space").is_err());
        assert!(validate_request_id("café").is_err());
    }
}
