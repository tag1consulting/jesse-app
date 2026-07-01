use crate::*;

#[derive(Deserialize)]
pub struct JesseRequest {
    mode: String,                 // "ask" | "tell"
    text: String,
    #[serde(default)]
    session_id: Option<String>,   // set to continue a thread (a followup)
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
}

/// Body of `POST /jesse/device`: the phone's APNs device token (hex string).
#[derive(Deserialize)]
pub struct DeviceRequest {
    token: String,
}

// ---- Handlers -------------------------------------------------------------

/// Liveness probe. Always returns `200 { "ok": true }` with **no auth and no
/// secrets** — a bare unauthenticated caller learns only that the bridge is up.
/// The vault and `claude` binary paths are operator detail (they leak the host's
/// filesystem layout), so they are surfaced **only to an authenticated caller**;
/// an unauthenticated probe never sees them.
pub async fn health(State(st): State<AppState>, headers: HeaderMap) -> Json<Value> {
    let mut body = json!({ "ok": true });
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
    let prompt = build_prompt(
        &mode,
        &req.text,
        is_followup,
        req.voice,
        req.instructions.as_deref(),
        req.floor_override.as_deref(),
    )?;

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
    let job_id = st.jobs.create();
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
    // Push machinery for the completion notification (no-ops when push is off).
    let apns = st.apns.clone();
    let devices = st.devices.clone();
    let notify = st.notify.clone();
    let handle = tokio::spawn(async move {
        // Hold the permit for the whole turn, releasing it on task exit.
        let _permit: OwnedSemaphorePermit = permit;
        // Hold the scratch dir for the whole turn; its Drop removes the decoded
        // attachment files when the task ends — success, error, or timeout. The
        // files therefore survive run_claude's internal retries and are cleaned
        // exactly once, here.
        let _scratch = scratch;
        // If the body below panics, this guard's Drop still drives the job to a
        // terminal Failed + terminal stream frame (M2) — a panicking turn can
        // never strand the job in Running forever.
        let mut guard = TurnGuard::new(jobs.clone(), jid.clone());

        let outcome = run_claude_streaming(&cfg, &prompt, sid.as_deref(), &jobs, &jid).await;
        jobs.complete(&jid, outcome);
        // Close the live stream with the frame matching the state that actually
        // landed. `complete` is write-once, so a cancel that won the race already
        // set `Cancelled` (and `cancel` already emitted that frame + removed the
        // stream entry, making this a no-op). Reading the post-`complete` state
        // keeps the terminal frame and the stored result perfectly consistent.
        jobs.emit_terminal_frame(&jid);
        // The job reached a terminal state cleanly — disarm the guard so its Drop
        // is a no-op (the right frame is already out).
        guard.disarm();

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
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({ "job_id": job_id, "status": "running" })),
    )
        .into_response())
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
        }) => Ok(Json(json!({
            "status": "done",
            "response": response,
            "session_id": session_id,
        }))),
        Some(JobState::Failed { error }) => {
            Ok(Json(json!({ "status": "failed", "error": error })))
        }
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
            eprintln!("cancel: job {job_id} aborted by client — claude killed, concurrency slot freed");
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
        .route("/jesse/result/:job_id", get(jesse_result))
        .route("/jesse/stream/:job_id", get(jesse_stream))
        .route("/jesse/cancel/:job_id", post(jesse_cancel))
        .route("/jesse/device", post(jesse_device))
        .route("/jesse/notify/:job_id", post(jesse_notify))
        .layer(DefaultBodyLimit::max(body_limit))
        .with_state(state)
}
