//! Integration tests: exercise the real Axum router via
//! `tower::ServiceExt::oneshot`, no socket bound. These drive the same
//! `app()` the running server uses.
#![allow(clippy::collapsible_if)]
mod common;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::*;
use jesse_bridge::*;
use serde_json::Value;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tower::ServiceExt;

// ---- Waiting for an async outcome ------------------------------------------
//
// These tests drive a real turn through the router and then wait on something the
// turn does asynchronously: a job reaching a terminal state, a permit coming back, a
// fake-`claude` child writing its pid or its transcript. Every such wait used to be a
// fixed iteration count — `for _ in 0..80 { sleep(50ms) }`, ~4s of hard wall clock —
// which made the assertion a race against machine load rather than against behavior.
// A fully-parallel `cargo test` on a busy box failed a dozen of them purely on
// scheduling, and that was briefly mistaken for a product timing limit. It never was:
// the driver waits on the real `timeout_secs` while reading stdout, so nothing in the
// bridge assumes a child schedules promptly. Only the tests did.
//
// So the budget here is WALL CLOCK, not iterations. A green run never pays it — the
// probe succeeds on its first or second pass — and only a genuinely broken test waits
// the deadline out.

/// Wall-clock budget for a wait whose assertion is THAT something happens, never how
/// fast. Deliberately far past any plausible scheduling delay.
const WAIT_DEADLINE: Duration = Duration::from_secs(60);

/// How often a wait re-probes.
const WAIT_POLL: Duration = Duration::from_millis(50);

/// Poll `probe` until it yields `Some`, or `deadline` of wall clock passes.
///
/// Takes an explicit deadline for the few tests whose MEANING is a bound — where the
/// window has to stay under some other clock for the assertion to prove anything (a run
/// limit, a child's `sleep`). Those call sites name the bound they sit under and why.
/// Everything else wants [`wait_for`].
async fn wait_for_within<T, F, Fut>(deadline: Duration, what: &str, mut probe: F) -> T
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Option<T>>,
{
    let started = std::time::Instant::now();
    loop {
        if let Some(v) = probe().await {
            return v;
        }
        assert!(
            started.elapsed() < deadline,
            "timed out after {deadline:?} waiting for {what}"
        );
        tokio::time::sleep(WAIT_POLL).await;
    }
}

/// [`wait_for_within`] at the default [`WAIT_DEADLINE`] — the right call for almost
/// every wait in this file.
async fn wait_for<T, F, Fut>(what: &str, probe: F) -> T
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Option<T>>,
{
    wait_for_within(WAIT_DEADLINE, what, probe).await
}

/// Wait for `job_id` to reach `status`, and hand back the whole result body.
async fn wait_for_status(st: &AppState, job_id: &str, status: &str) -> Value {
    wait_for_status_within(WAIT_DEADLINE, st, job_id, status).await
}

/// [`wait_for_status`] under an explicit deadline (see [`wait_for_within`]).
async fn wait_for_status_within(
    deadline: Duration,
    st: &AppState,
    job_id: &str,
    status: &str,
) -> Value {
    wait_for_within(
        deadline,
        &format!("job {job_id} to reach status {status}"),
        move || async move {
            let v = result_status(st, job_id).await;
            (v["status"] == status).then_some(v)
        },
    )
    .await
}

/// The ambient routed pick: applies no backend env, which is what every routed job
/// resolves to when `offload_order` is empty.
fn ambient_pick() -> RoutedPick {
    RoutedPick {
        id: DEFAULT_MODEL_ID.to_string(),
        harness: CLAUDE_CODE_ID.to_string(),
        level: Capability::Write,
        backend: None,
    }
}

/// Arm the local vault-QA route the way config does now: `offload_order` naming a
/// configured, healthy model at `Read` or above. Replaces the `vaultqa_backend` triple.
fn with_vaultqa_offload(mut cfg: Config) -> Config {
    let mut models = cfg.model_registry.models.clone();
    models.push(RegistryModel {
        id: "local-vaultqa".to_string(),
        label: "Local vault QA".to_string(),
        kind: ModelKind::Local,
        wire: Wire::default_for_kind(ModelKind::Local),
        backend: Some((
            "http://127.0.0.1:9100".into(),
            "vaultqa-dummy-tok".into(),
            "local-vaultqa".into(),
        )),
        subagent_model: None,
        configured: true,
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        auth_scheme: None,
        quirks: DirectQuirks::default(),
        thinking: None,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
        vision: Vec::new(),
        vision_complementary: false,
    });
    cfg.model_registry = ModelRegistry { models };
    cfg.offload_order = vec!["local-vaultqa".to_string()];
    cfg
}

#[tokio::test]
async fn health_unauthenticated_is_ok_and_leaks_no_paths() {
    // Liveness only: 200 { "ok": true }, and crucially NONE of the operator
    // paths (vault / claude binary) to an unauthenticated caller.
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
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["ok"], true);
    // The version is surfaced unconditionally (it isn't sensitive) and must
    // match the crate version — that's the whole point of the mandatory bump.
    assert_eq!(body["version"], env!("CARGO_PKG_VERSION"));
    assert!(
        body.get("vault").is_none(),
        "vault path must not leak unauthenticated"
    );
    assert!(
        body.get("claude").is_none(),
        "claude path must not leak unauthenticated"
    );
}

#[tokio::test]
async fn health_authenticated_returns_paths() {
    // With the bearer token, the operator detail is surfaced (same info the
    // old unconditional /health exposed, now gated).
    let st = test_state();
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["ok"], true);
    assert_eq!(body["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(body["vault"], st.cfg.vault);
    assert_eq!(body["claude"], st.cfg.claude_bin);
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
#[tokio::test]
async fn prompts_requires_auth() {
    let resp = app(test_state())
        .oneshot(
            Request::builder()
                .uri("/jesse/prompts")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn prompts_returns_both_built_in_defaults() {
    let resp = app(test_state())
        .oneshot(
            Request::builder()
                .uri("/jesse/prompts")
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    // The endpoint renders the built-in defaults through the configured persona, so
    // the app's "default" matches exactly what the bridge would build for a fresh
    // turn. test_state uses the generic default persona (owner "the user").
    let p = Persona::default();
    assert_eq!(body["ask"], p.render(ASK_PREAMBLE));
    assert_eq!(body["tell"], p.render(TELL_PREAMBLE));
    // The fixed safety floors are exposed too, so the app can show them read-only.
    assert_eq!(body["ask_floor"], p.render(ASK_FLOOR));
    assert_eq!(body["tell_floor"], p.render(TELL_FLOOR));
}
#[tokio::test]
async fn result_endpoint_returns_persisted_job_after_restart() {
    // End to end: complete a job under one AppState, then build a fresh
    // AppState over the same state dir (the restart) and GET its result.
    let state_parent = std::env::temp_dir().join(format!("jesse-state-{}", random_hex()));
    let cfg1 = Config {
        state_dir: Some(state_parent.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st1 = AppState::new(cfg1);
    let id = st1.jobs.create();
    st1.jobs.complete(
        &id,
        Ok((
            "survives reboot".to_string(),
            Some("sess-r".to_string()),
            None,
        )),
    );
    st1.jobs.flush_persistence(); // wait for the off-lock worker to write

    // New AppState over the same dir = the bridge restarting.
    let cfg2 = Config {
        state_dir: Some(state_parent.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st2 = AppState::new(cfg2);
    let resp = app(st2)
        .oneshot(
            Request::builder()
                .uri(format!("/jesse/result/{id}"))
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["status"], "done");
    assert_eq!(body["response"], "survives reboot");
    assert_eq!(body["session_id"], "sess-r");

    let _ = std::fs::remove_dir_all(&state_parent);
}
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
#[tokio::test]
async fn cancel_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(cancel_request(None, "whatever"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn cancel_wrong_token_is_401() {
    let resp = app(test_state())
        .oneshot(cancel_request(Some("Bearer wrong"), "whatever"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn cancel_unknown_id_is_idempotent_204() {
    // An id the bridge never minted (or already evicted) is a clean no-op —
    // the phone may cancel after the job is long gone.
    let resp = app(test_state())
        .oneshot(cancel_request(Some("Bearer test-token"), "does-not-exist"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}
#[tokio::test]
async fn cancel_done_job_succeeds_without_clobbering_result() {
    // Cancelling an already-finished job must return success but leave the
    // stored reply intact (the phone can still retrieve it).
    let st = test_state();
    let id = st.jobs.create();
    st.jobs.complete(
        &id,
        Ok(("keep me".to_string(), Some("sess-k".to_string()), None)),
    );

    let resp = app(st.clone())
        .oneshot(cancel_request(Some("Bearer test-token"), &id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let v = result_status(&st, &id).await;
    assert_eq!(v["status"], "done");
    assert_eq!(v["response"], "keep me");
    assert_eq!(v["session_id"], "sess-k");
}
#[tokio::test]
async fn cancel_running_turn_kills_child_and_frees_slot() {
    // End to end: a fake claude that sleeps far past the grace window and only
    // touches its marker at the very end. Start the turn (202), cancel it, and
    // assert it transitions to `cancelled`, the concurrency slot is freed (the
    // aborted task drops its permit), and the child never reached its marker.
    let marker = std::env::temp_dir().join(format!(
        "jesse-cancel-marker-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&marker);
    let script = format!(
        "#!/bin/sh\n\
             sleep 60\n\
             touch '{}'\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"too late\"}}'\n",
        marker.display()
    );
    let fake = write_fake_claude(&script);

    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]), // a freed slot is observable via available_permits
        ..test_config()
    };
    let st = AppState::new(cfg);

    // Start the long turn — it outruns the 1s grace and hands back a job id.
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"cancel me"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    // The turn holds the only permit while it runs.
    assert_eq!(st.slots.ceiling_free(), 0, "running turn holds the permit");

    // Cancel it.
    let resp = app(st.clone())
        .oneshot(cancel_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // The abort drops the task asynchronously; wait for the permit to come back.
    let slots = &st.slots;
    wait_for(
        "the aborted turn to free its concurrency slot",
        move || async move { (slots.ceiling_free() == 1).then_some(()) },
    )
    .await;

    // The job reads as cleanly cancelled, and the child never hit its marker.
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["status"], "cancelled");
    assert!(
        !marker.exists(),
        "the claude child must be killed before it finished its work"
    );

    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&fake);
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

    // The POST future is now dropped (client "disconnected"). Wait for the detached
    // turn to complete — it must, despite the dropped connection.
    let done = wait_for_status(&st, &job_id, "done").await;
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
async fn streaming_completes_on_result_line_not_child_exit() {
    // A fake claude that emits a valid stream-json sequence ending in a
    // `result` line and THEN sleeps without exiting, keeping stdout open. The
    // turn must reach Done driven by the result line — well under the (short)
    // run timeout — instead of blocking on the pipe until the timeout fires.
    //
    // FAILING-FIRST: against the pre-fix read-to-EOF loop the `sleep` holds
    // stdout open, so `next_line()` blocks until the run timeout converts the
    // turn into a GATEWAY_TIMEOUT failure — the job is never `done` inside the
    // (short, sub-timeout) poll window below, so the assertion fails.
    let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}}'\n\
             printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"the answer\",\"session_id\":\"sess-rl\"}'\n\
             sleep 600\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        // The run limit and the wait below are a PAIR: the wait must stay under this
        // limit for the test to prove anything, so both scale together. They are set
        // far above any plausible scheduling delay because a passing run never spends
        // them — Done arrives on the result line almost immediately — while a
        // regression to read-to-EOF spends the whole limit and is caught by the wait.
        timeout_secs: 60,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"answer me"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // BOUNDED ON PURPOSE: this wait must stay under the fixture's 60s run limit or it
    // proves nothing. Completion is driven by the result line (near-instant), so `done`
    // lands almost at once; if it still waited on child stdout EOF the turn would sit
    // `running` for the full 60s and this 45s wait would expire with no `done`.
    let done = wait_for_status_within(Duration::from_secs(45), &st, &job_id, "done").await;
    assert_eq!(done["response"], "the answer");
    assert_eq!(done["session_id"], "sess-rl");

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn a_turn_killed_at_the_run_limit_returns_how_far_it_got() {
    // THE BARE-ERROR-BANNER FIX. A turn that overruns its run limit used to surface as
    // nothing but `{"status":"failed","error":"Jesse hit the …s run limit"}` — everything
    // the agent had already said (and already written to disk) died with the child.
    //
    // A fake claude that says something, uses a tool, says something else, and then hangs
    // forever without a terminal result — i.e. exactly the shape of the real overrun.
    //
    // FAILING-FIRST: without the trace, the failure body has no `partial` at all.
    let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"I refactored the parser. \"}}}'\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Read\",\"input\":{}}}}'\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"text_delta\",\"text\":\"Now the tests.\"}}}'\n\
             sleep 600\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        // This test is the one place a run limit must genuinely FIRE, so the turn really
        // does spend this budget — but the child has to get its three instant lines out
        // before it does, and under a fully-parallel run the spawn itself can take
        // seconds. 12s keeps that race un-losable while keeping the test short; the
        // elapsed assertions below scale with it.
        timeout_secs: 12,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"do the big refactor"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // Well past the 5s limit — the kill converts the turn to `failed`.
    let failed = wait_for_status(&st, &job_id, "failed").await;

    // The error is UNCHANGED — same wording, same classification, so retry behavior is
    // exactly what it was. The partial rides beside it, not instead of it.
    let err = failed["error"].as_str().unwrap();
    assert!(err.contains("run limit"), "error unchanged: {err}");
    assert!(err.contains("JESSE_TIMEOUT"), "still actionable: {err}");

    let partial = &failed["partial"];
    assert!(!partial.is_null(), "a cut-off turn carries a partial");
    let text = partial["text"].as_str().unwrap();
    assert!(
        text.contains("I refactored the parser."),
        "the text it produced before the tool call: {text}"
    );
    assert!(
        text.contains("Now the tests."),
        "and the text after it: {text}"
    );
    assert_eq!(partial["tool_calls"], 1, "the tool calls observed");
    assert!(
        partial["elapsed_secs"].as_u64().unwrap() >= 10,
        "elapsed seconds, roughly the run limit: {partial}"
    );

    // And the timing record for the same turn, on the same response.
    let timing = &failed["timing"];
    assert_eq!(timing["status"], "failed");
    assert_eq!(timing["job_id"], job_id);
    assert_eq!(timing["tool_calls"], 1);
    assert_eq!(timing["tools"][0]["tool"], "Read");
    assert!(
        timing["tools"][0]["ms"].as_u64().is_some(),
        "each tool call carries its duration: {timing}"
    );
    assert!(timing["elapsed_ms"].as_u64().unwrap() >= 10_000, "{timing}");

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn every_turn_appends_a_timing_record_that_is_pruned_at_seven_days() {
    // The other half of "no record anywhere of where the hour went": one JSONL line per
    // turn under the state dir, keyed by job id, with the tool calls and their durations —
    // and a startup prune so the file can't grow without bound.
    //
    // FAILING-FIRST: with no timing log, `turn-timings.jsonl` never appears.
    let state_parent = std::env::temp_dir().join(format!("jesse-timing-state-{}", random_hex()));
    let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Grep\",\"input\":{}}}}'\n\
             printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"found it\",\"session_id\":\"sess-t\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        state_dir: Some(state_parent.to_string_lossy().into_owned()),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"find the thing"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    let done = wait_for_status(&st, &job_id, "done").await;
    assert_eq!(done["response"], "found it");
    // The record reaches the client on the existing result endpoint.
    assert_eq!(done["timing"]["status"], "done");
    assert_eq!(done["timing"]["tools"][0]["tool"], "Grep");

    // …and the same record is on disk, one line, content-free.
    let path = state_parent.join("turn-timings.jsonl");
    let path_ref = &path;
    let job_ref = job_id.as_str();
    let on_disk = wait_for(
        "the turn's timing line to reach the log on disk",
        move || async move {
            let s = std::fs::read_to_string(path_ref).unwrap_or_default();
            s.contains(job_ref).then_some(s)
        },
    )
    .await;
    assert!(on_disk.contains(&job_id), "a line for this turn: {on_disk}");
    assert_eq!(on_disk.trim().lines().count(), 1, "one line per turn");
    assert!(
        !on_disk.contains("found it") && !on_disk.contains("find the thing"),
        "the timing log carries no question or answer text: {on_disk}"
    );

    // THE PRUNE. Plant a record from 8 days ago beside the fresh one and restart the
    // bridge over the same state dir: startup drops the stale line and keeps the fresh.
    let stale = r#"{"v":1,"job_id":"job-from-last-week","started_at":"2020-01-01T00:00:00Z","ended_at":"2020-01-01T00:00:01Z","elapsed_ms":1000,"status":"done","tool_calls":0,"tools":[]}"#;
    {
        use std::io::Write as _;
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        writeln!(f, "{stale}").unwrap();
    }
    let cfg2 = Config {
        state_dir: Some(state_parent.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st2 = AppState::new(cfg2);
    let after = std::fs::read_to_string(&path).unwrap();
    assert!(
        !after.contains("job-from-last-week"),
        "older than 7 days → pruned at startup: {after}"
    );
    assert!(
        after.contains(&job_id),
        "the fresh record survives: {after}"
    );
    // The surviving record is still served after the restart.
    assert!(st2.timings.get(&job_id).is_some());

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&state_parent);
}
#[tokio::test]
async fn wrapped_prompt_carries_a_live_clock_header_end_to_end() {
    // Drive the bridge exactly as the App does (POST /jesse) and capture the
    // prompt that actually reaches `claude` — its `-p` argument, i.e. $2. Then
    // prove the wrapped prompt leads with a well-formed, live clock header:
    // day-of-week, ISO date, HH:MM, a zone abbreviation, and a colonized UTC
    // offset — the deterministic per-turn clock the phone path depends on.
    //
    // FAILING-FIRST: with the clock-prepend line in `build_prompt_at` removed,
    // the captured prompt starts with the safety floor and contains no
    // "Current date/time:" header, so the assertions below fail.
    let promptfile = std::env::temp_dir().join(format!(
        "jesse-prompt-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&promptfile);
    // $2 is the prompt (argv: -p <prompt> --output-format …). Record it, then
    // emit a valid terminal result line so the turn completes.
    let script = format!(
            "#!/bin/sh\n\
             printf '%s' \"$2\" > '{}'\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-clock\"}}'\n",
            promptfile.display()
        );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"what day is it"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // Wait for completion so the prompt has certainly been written.
    wait_for_status(&st, &job_id, "done").await;

    let prompt = std::fs::read_to_string(&promptfile).expect("fake claude must record the prompt");
    // The clock leads the whole wrapped prompt.
    let header = prompt
        .lines()
        .next()
        .expect("prompt must have a first line");
    assert!(
        header.starts_with("Current date/time: "),
        "wrapped prompt must lead with the clock header, got: {header:?}"
    );
    // Well-formed and LIVE: "<Weekday>, <YYYY-MM-DD> <HH:MM> <ABBR> (UTC±HH:MM)."
    let rest = header
        .strip_prefix("Current date/time: ")
        .unwrap()
        .strip_suffix(").")
        .expect("header must end with ').'");
    let (head, offset) = rest
        .split_once(" (UTC")
        .expect("header must carry a (UTC offset)");
    assert_eq!(offset.len(), 6, "offset must be ±HH:MM: {offset:?}");
    assert_eq!(
        offset.as_bytes()[3],
        b':',
        "offset must be colonized: {offset:?}"
    );
    let parts: Vec<&str> = head.split(' ').collect();
    assert!(
        [
            "Monday,",
            "Tuesday,",
            "Wednesday,",
            "Thursday,",
            "Friday,",
            "Saturday,",
            "Sunday,"
        ]
        .contains(&parts[0]),
        "header must open with a weekday: {head:?}"
    );
    let year: i64 = parts[1].split('-').next().unwrap().parse().expect("year");
    assert!(
        year >= 2026,
        "clock must reflect the real current year: {year}"
    );
    // The floor still follows the clock (it wasn't displaced). The endpoint renders
    // the default persona ("the user") into the floor template.
    assert!(
        prompt.contains(&Persona::default().render(ASK_FLOOR)),
        "the Ask safety floor must still follow the clock header"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&promptfile);
}
#[tokio::test]
async fn streaming_reaps_child_after_result_line() {
    // The flip side of the fix: after completing on the result line, the
    // bounded reap must actually kill a child that won't exit on its own, so
    // the fix doesn't leak a runaway `claude`. The fake records its own pid,
    // prints the result line, then sleeps far longer than the reap bound.
    let pidfile = std::env::temp_dir().join(format!(
        "jesse-reap-pid-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&pidfile);
    let script = format!(
            "#!/bin/sh\n\
             echo $$ > '{}'\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"reaped\",\"session_id\":\"sess-reap\"}}'\n\
             printf '\\n'\n\
             sleep 600\n",
            pidfile.display()
        );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        // Generous: this test is about the bounded reap, not about racing the
        // run limit (that is `streaming_completes_on_result_line`'s job). A
        // short limit only made it flaky under the concentrated process-
        // spawning load of the integration binary.
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"reap me"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // The turn lands Done on the result line (same as above).
    wait_for_status(&st, &job_id, "done").await;

    // Read the child's pid (written before it printed the result line).
    let pidfile_ref = &pidfile;
    let pid: i32 = wait_for("the fake claude to record its pid", move || async move {
        std::fs::read_to_string(pidfile_ref)
            .ok()
            .and_then(|s| s.trim().parse().ok())
    })
    .await;

    // The background reap kills the lingering child within its bound (5s).
    // Give it that bound plus a margin; the child must be gone, even though
    // its own `sleep 600` is nowhere near done.
    let mut reaped = false;
    for _ in 0..80 {
        if !pid_alive(pid) {
            reaped = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        reaped,
        "the lingering claude child must be killed by the bounded reap, not left running"
    );

    let _ = std::fs::remove_file(&pidfile);
    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn stream_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(stream_request(None, "whatever"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn stream_unknown_id_is_404() {
    let resp = app(test_state())
        .oneshot(stream_request(Some("Bearer test-token"), "does-not-exist"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
#[tokio::test]
async fn stream_running_turn_emits_deltas_then_done() {
    // A fake claude that emits two text deltas (with a pause between, so the
    // turn is still running when the phone subscribes) then a terminal result.
    let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}}'\n\
             sleep 1\n\
             printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}}'\n\
             printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Hello world\",\"session_id\":\"sess-1\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"greet me"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // Open the stream while the turn runs; collect the whole SSE body (it ends
    // when the terminal `done` frame closes the stream).
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;

    // Live "world" delta arrives over the broadcast (the turn was still
    // running at subscribe), then the authoritative done frame.
    assert!(
        sse.contains("event: delta"),
        "expected a live delta frame: {sse}"
    );
    assert!(sse.contains("world"), "delta text missing: {sse}");
    assert!(
        sse.contains("event: done"),
        "expected a terminal done frame: {sse}"
    );
    assert!(sse.contains("Hello world"), "final response missing: {sse}");
    assert!(sse.contains("sess-1"), "session id missing: {sse}");

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn stream_already_done_replays_full_text_then_done() {
    // A job that finished before the stream is opened must replay the full
    // text (a reset frame) and a done frame immediately, then close — no
    // fake claude needed.
    let st = test_state();
    let id = st.jobs.create();
    st.jobs.complete(
        &id,
        Ok((
            "the whole answer".to_string(),
            Some("sess-done".to_string()),
            None,
        )),
    );

    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(
        sse.contains("event: reset"),
        "expected a full-text reset: {sse}"
    );
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(sse.contains("the whole answer"), "full text missing: {sse}");
    assert!(sse.contains("sess-done"), "session id missing: {sse}");
}
#[tokio::test]
async fn stream_cancelled_job_emits_cancelled_frame() {
    // A cancelled job surfaces a clean `cancelled` terminal frame, not an error.
    let st = test_state();
    let id = st.jobs.create();
    st.jobs.stream_register(&id);
    assert!(matches!(st.jobs.cancel(&id), CancelOutcome::Cancelled));

    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(
        sse.contains("event: cancelled"),
        "expected a cancelled frame: {sse}"
    );
    assert!(
        !sse.contains("event: error"),
        "cancel must not look like an error: {sse}"
    );
}
#[tokio::test]
async fn post_returns_202_immediately_even_for_a_fast_turn() {
    // The grace-hold is gone: POST always returns 202 with the job_id up front,
    // even when `claude` would finish near-instantly. The reply is fetched via
    // GET /jesse/result/{job_id}. This is the fix for the orphan bug — the
    // phone always has the id before any connection drop can matter.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"quick\",\"session_id\":\"sess-fast\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
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
    assert_eq!(
        resp.status(),
        StatusCode::ACCEPTED,
        "POST never holds — always 202"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["status"], "running");
    let job_id = body["job_id"]
        .as_str()
        .expect("202 carries a job_id")
        .to_string();

    // The detached turn finishes; the reply is retrievable by id.
    let done = wait_for_status(&st, &job_id, "done").await;
    assert_eq!(done["response"], "quick");
    assert_eq!(done["session_id"], "sess-fast");

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn queue_full_sheds_with_429() {
    // Single writer, queue depth 1: the running turn holds the only permit, a
    // second turn WAITS in the queue (202), and a third — beyond the queue —
    // is shed with 429, exactly as an over-capacity request was before.
    let script = "#!/bin/sh\nsleep 2\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]), // exactly one permit
        max_queued: 1,                                           // room for exactly one waiter
        ..test_config()
    };
    let st = AppState::new(cfg);

    // First POST: acquires the only permit synchronously and holds it while the
    // fake claude sleeps.
    let first = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"one"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::ACCEPTED);

    // Second POST: no permit free, but the queue has room → QUEUED, still 202.
    let second = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"two"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::ACCEPTED,
        "a second turn queues (202), it is not rejected"
    );

    // Third POST: queue is full (one running + one waiting) → shed with 429.
    let third = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"three"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(third.status(), StatusCode::TOO_MANY_REQUESTS);

    let _ = std::fs::remove_file(&fake);
}
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
async fn jesse_accepts_instructions_field() {
    // The override field is #[serde(default)] and optional. A request that
    // carries it must still deserialize; a bad mode then returns 400, proving
    // the body (with `instructions`) parsed before build_prompt ran.
    let resp = app(test_state())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"nope","text":"hi","instructions":"my custom wrapper"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
#[tokio::test]
async fn jesse_accepts_health_context_field() {
    // The new field is #[serde(default)] and optional. A request that carries
    // it must still deserialize; a bad mode then returns 400, proving the body
    // (with `health_context`) parsed before build_prompt ran. This is the
    // byte-for-byte request decode, extended for the new optional field.
    let resp = app(test_state())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"nope","text":"hi","health_context":"Swim 30m 1500m"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
#[tokio::test]
async fn jesse_oversized_health_context_is_413_before_any_spawn() {
    // A block one byte over MAX_HEALTH_CONTEXT_BYTES must be rejected 413 by
    // build_prompt BEFORE the turn is spawned. A fake claude that touches a
    // marker the instant it runs proves no spawn happened.
    let marker = std::env::temp_dir().join(format!(
        "jesse-hc-marker-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&marker);
    let script = format!(
        "#!/bin/sh\n\
             touch '{}'\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"too late\"}}'\n",
        marker.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let oversized = "x".repeat(MAX_HEALTH_CONTEXT_BYTES + 1);
    let json = format!(r#"{{"mode":"ask","text":"hi","health_context":"{oversized}"}}"#);
    let resp = app(st)
        .oneshot(jesse_request(Some("Bearer test-token"), &json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !marker.exists(),
        "oversized health_context must be rejected before claude is ever spawned"
    );

    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn health_context_block_reaches_claude_verbatim_after_the_clock() {
    // End-to-end: drive POST /jesse with a health_context block and capture the
    // prompt that actually reaches `claude` ($2). The framed block must appear
    // verbatim right after the clock header and ahead of the safety floor; a
    // request WITHOUT the field must carry no such block.
    //
    // FAILING-FIRST: without the block-assembly line in build_prompt_at, the
    // captured prompt jumps straight from the clock to the floor and contains
    // neither the framing header nor the block, so the present-case asserts fail.
    async fn captured_prompt(json: &str) -> String {
        let promptfile = std::env::temp_dir().join(format!(
            "jesse-hc-prompt-{}-{}.txt",
            std::process::id(),
            JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&promptfile);
        let script = format!(
                "#!/bin/sh\n\
                 printf '%s' \"$2\" > '{}'\n\
                 printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-hc\"}}'\n",
                promptfile.display()
            );
        let fake = write_fake_claude(&script);
        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
            timeout_secs: 30,
            ..test_config()
        };
        let st = AppState::new(cfg);
        let resp = app(st.clone())
            .oneshot(jesse_request(Some("Bearer test-token"), json))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::ACCEPTED);
        let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        let job_id = body["job_id"].as_str().unwrap().to_string();
        wait_for_status(&st, &job_id, "done").await;
        let prompt =
            std::fs::read_to_string(&promptfile).expect("fake claude must record the prompt");
        let _ = std::fs::remove_file(&fake);
        let _ = std::fs::remove_file(&promptfile);
        prompt
    }

    let block = "Swim — 2026-07-04 06:30, 30m, 1500m, 420 kcal, avg HR 132";
    // Present: the framed block appears verbatim after the clock, before the floor.
    let with = captured_prompt(&format!(
        r#"{{"mode":"ask","text":"log my swim","health_context":"{block}"}}"#
    ))
    .await;
    assert!(
        with.contains(HEALTH_CONTEXT_HEADER),
        "framing header present"
    );
    assert!(with.contains(block), "block appears verbatim");
    let clock_end = with.find("\n\n").expect("clock line then blank line");
    let block_at = with.find(block).unwrap();
    let floor_at = with.find(&Persona::default().render(ASK_FLOOR)).unwrap();
    assert!(
        clock_end < block_at && block_at < floor_at,
        "clock < block < floor"
    );

    // Absent: no framing header, no block — today's behavior.
    let without = captured_prompt(r#"{"mode":"ask","text":"log my swim"}"#).await;
    assert!(
        !without.contains(HEALTH_CONTEXT_HEADER),
        "no health block when field absent"
    );
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
#[tokio::test]
async fn device_register_requires_auth() {
    let resp = app(test_state())
        .oneshot(device_request(None, r#"{"token":"deadbeef"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn device_register_round_trip_stores_token() {
    let st = test_state();
    let resp = app(st.clone())
        .oneshot(device_request(
            Some("Bearer test-token"),
            r#"{"token":"deadbeefcafe"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        st.devices.get().as_deref(),
        Some("deadbeefcafe"),
        "token stored"
    );

    // Idempotent upsert: a second register overwrites.
    let resp = app(st.clone())
        .oneshot(device_request(
            Some("Bearer test-token"),
            r#"{"token":"newtoken99"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(st.devices.get().as_deref(), Some("newtoken99"));
}
#[tokio::test]
async fn device_register_rejects_empty_token() {
    let resp = app(test_state())
        .oneshot(device_request(
            Some("Bearer test-token"),
            r#"{"token":"   "}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
#[tokio::test]
async fn notify_requires_auth() {
    let resp = app(test_state())
        .oneshot(notify_request(None, "some-job"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn notify_flags_and_returns_204() {
    let st = test_state();
    let id = st.jobs.create();
    let resp = app(st.clone())
        .oneshot(notify_request(Some("Bearer test-token"), &id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    // The flag was recorded (running job → not consumed by the race check).
    assert!(st.notify.take(&id), "running job keeps its notify flag");
}
#[tokio::test]
async fn notify_endpoint_pushes_when_job_already_done() {
    // The race: the turn finished before the phone backgrounded and flagged.
    // The notify endpoint must push immediately rather than lose the signal.
    let mock = MockApns::default();
    let mut st = test_state();
    st.apns = Some(test_apns(Arc::new(mock.clone())));
    st.devices.set("tok".to_string());

    let id = st.jobs.create();
    st.jobs
        .complete(&id, Ok(("already done".to_string(), None, None)));

    let resp = app(st.clone())
        .oneshot(notify_request(Some("Bearer test-token"), &id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        mock.calls.lock_ok().len(),
        1,
        "flagging an already-finished job pushes immediately"
    );
}
#[tokio::test]
async fn title_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(title_request(None, r#"{"text":"hello"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn title_wrong_token_is_401() {
    let resp = app(test_state())
        .oneshot(title_request(Some("Bearer wrong"), r#"{"text":"hello"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
#[tokio::test]
async fn title_malformed_body_is_400() {
    // Invalid JSON syntax → the Json extractor rejects with 400 before the
    // handler body runs.
    let resp = app(test_state())
        .oneshot(title_request(Some("Bearer test-token"), r#"{"text": }"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
#[tokio::test]
async fn title_happy_path_returns_clamped_short_title() {
    // A fake claude that emits a valid terminal result line carrying a clean
    // short title. The endpoint returns it verbatim (nothing to clamp).
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Weekend Trip Planning\",\"session_id\":\"x\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st)
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"a long chat about planning a trip this weekend"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["title"], "Weekend Trip Planning");

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn title_output_longer_than_cap_is_clamped_to_one_line() {
    // A verbose model reply — a run-on first line PLUS an explanatory second
    // line. The endpoint must clamp to a single line no longer than the cap.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"This is an absurdly long run on title that keeps going well past any reasonable length\\nThis line explains the title and must be dropped\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st)
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"some conversation"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let title = body["title"].as_str().unwrap();
    assert!(
        !title.contains('\n'),
        "title must be a single line: {title:?}"
    );
    assert!(
        title.chars().count() <= MAX_TITLE_CHARS,
        "title must be clamped to MAX_TITLE_CHARS, got {} chars: {title:?}",
        title.chars().count()
    );
    assert!(!title.is_empty());

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn title_oversized_input_is_rejected_before_any_claude_spawn() {
    // A fake claude that touches a marker the instant it runs. An oversized
    // body must be rejected (413) by the input cap BEFORE any spawn, so the
    // marker never appears.
    let marker = std::env::temp_dir().join(format!(
        "jesse-title-marker-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&marker);
    let script = format!(
        "#!/bin/sh\n\
             touch '{}'\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"too late\"}}'\n",
        marker.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    // One byte over the cap.
    let oversized = "x".repeat(MAX_TITLE_INPUT_BYTES + 1);
    let json = format!(r#"{{"text":"{oversized}"}}"#);
    let resp = app(st)
        .oneshot(title_request(Some("Bearer test-token"), &json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);

    // Give any (erroneously spawned) child a beat, then assert it never ran.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !marker.exists(),
        "oversized input must be rejected before claude is ever spawned"
    );

    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn title_oneshot_spawns_a_toolless_child_with_no_mcp_servers() {
    // THE TIGHTENING, proven on the argv the title child is actually spawned with (not
    // just on the builder): a title one-shot is granted Capability::Basic with no MCP
    // servers, so it holds NO tools and launches nothing. It used to resolve through the
    // ambient model, which is writes-on, and ran with the full writes-on toolset plus the
    // qmd server in the vault for a job whose whole output is a few words. A fake claude
    // records its own argv, then returns a normal result line.
    let argv_log = std::env::temp_dir().join(format!(
        "jesse-title-argv-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&argv_log);
    let script = format!(
        "#!/bin/sh\n\
             for a in \"$@\"; do printf '%s\\n' \"$a\" >> '{}'; done\n\
             printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"A Title\"}}'\n",
        argv_log.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };

    let title = run_claude_oneshot(&cfg, "title this", 30, &ambient_pick())
        .await
        .expect("the title child must still work");
    assert_eq!(title, "A Title");

    let argv: Vec<String> = std::fs::read_to_string(&argv_log)
        .expect("the fake claude must have recorded its argv")
        .lines()
        .map(str::to_string)
        .collect();
    let value_of = |flag: &str| -> Option<String> {
        argv.iter()
            .position(|a| a == flag)
            .map(|i| argv[i + 1].clone())
    };

    // The root boundary: the entire built-in toolset is gone, and no MCP server loads.
    assert_eq!(
        value_of("--tools").as_deref(),
        Some(""),
        "the title child must disable the built-in toolset: {argv:?}"
    );
    assert!(
        argv.iter().any(|a| a == "--strict-mcp-config"),
        "the title child must not discover MCP servers: {argv:?}"
    );
    let mcp = value_of("--mcp-config").expect("--mcp-config present");
    let parsed: serde_json::Value = serde_json::from_str(&mcp).expect("valid JSON");
    assert!(
        parsed
            .get("mcpServers")
            .and_then(|v| v.as_object())
            .map(|m| m.is_empty())
            .unwrap_or(false),
        "the title child must declare NO servers — not even qmd: {mcp:?}"
    );
    assert!(
        !mcp.contains("qmd"),
        "the qmd server must not be launched for a title call: {mcp:?}"
    );
    assert_eq!(
        value_of("--allowedTools").as_deref(),
        Some(""),
        "the title child must grant no tools: {argv:?}"
    );
    // And specifically NOT the writes-on allowlist it used to inherit. Checked against
    // the configured list itself, and against the grants inside it that could act.
    assert!(
        !argv.contains(&cfg.allowed_tools),
        "the configured writes-on allowlist must not appear in a title child: {argv:?}"
    );
    let allowed = value_of("--allowedTools").unwrap_or_default();
    for granted in ["Write", "Edit", "Skill(diet-logging)", "Bash(git:*)"] {
        assert!(
            !allowed.contains(granted),
            "{granted} must not be granted to a title child: {allowed:?}"
        );
    }
    // Still a single-shot with no thread to resume.
    assert!(
        !argv.iter().any(|a| a == "--resume"),
        "a title call is never part of a thread: {argv:?}"
    );

    let _ = std::fs::remove_file(&argv_log);
    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn title_oneshot_times_out_when_claude_stalls() {
    // The short timeout bound is enforced: a fake claude that stalls far past
    // the passed timeout must yield a GATEWAY_TIMEOUT error, not hang. Driven
    // at the run_claude_oneshot level so a 1s bound can be exercised directly
    // (the handler uses the fixed TITLE_TIMEOUT_SECS const).
    let script = "#!/bin/sh\nsleep 60\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"too slow\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };

    let started = std::time::Instant::now();
    let res = run_claude_oneshot(&cfg, "title this", 1, &ambient_pick()).await;
    let elapsed = started.elapsed();
    let err = res.expect_err("a stalling claude must time out, not succeed");
    assert_eq!(err.0, StatusCode::GATEWAY_TIMEOUT);
    assert!(
        elapsed < Duration::from_secs(10),
        "timeout must fire near the 1s bound, took {elapsed:?}"
    );

    let _ = std::fs::remove_file(&fake);
}
#[tokio::test]
async fn turn_completes_when_claude_eofs_but_does_not_exit() {
    // A fake claude that prints a full result line, then sleeps without
    // exiting (the grandchild-holding-the-pipe shape). The post-read
    // child.wait()/stderr drain are bounded (H4), so the turn completes and
    // frees its permit on the already-authoritative result — long before the
    // child's sleep ends. That sleep and the wait below are a PAIR (see the wait):
    // both are far longer than any real scheduling delay, and a passing run spends
    // neither.
    let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"done fast\",\"session_id\":\"sess-h4\"}'\n\
             sleep 600\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"hi"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // BOUNDED ON PURPOSE: this wait must stay under the child's `sleep 600` or it
    // proves nothing. Done AND the permit back inside 120s is the proof that the reap
    // is bounded rather than pinned by the lingering child.
    let st_ref = &st;
    let job_ref = job_id.as_str();
    wait_for_within(
        Duration::from_secs(120),
        "the turn to complete and free its permit without waiting for the child to exit",
        move || async move {
            (st_ref.slots.ceiling_free() == 1
                && result_status(st_ref, job_ref).await["status"] == "done")
                .then_some(())
        },
    )
    .await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "done fast");
    let _ = std::fs::remove_file(&fake);
}

// ---- Agent-emitted directives (JESSE_NEEDS_HEALTH) end-to-end ---------------
//
// These drive a real turn through POST /jesse with a fake `claude` that emits a
// terminal `result` line whose text ends in a directive, then assert the reply
// is stripped and the parsed directive surfaces IDENTICALLY on the poll result
// and the SSE `done` frame.

// Spawn a turn whose fake `claude` emits exactly `stdout_line` (one NDJSON line),
// poll until Done, and return `(state, job_id)`. `stdout_line` is wrapped in
// single quotes for `printf`, so it must contain no single quote (JSON uses
// double quotes) — and is concatenated, not `format!`'d, so its `{}` are literal.
async fn run_turn_emitting(req_json: &str, stdout_line: &str) -> (AppState, String) {
    let script = String::from("#!/bin/sh\nprintf '%s' '") + stdout_line + "'\n";
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), req_json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    wait_for_status(&st, &job_id, "done").await;
    let _ = std::fs::remove_file(&fake);
    (st, job_id)
}

#[tokio::test]
async fn directive_is_extracted_and_stripped_on_the_poll_result() {
    // A reply whose final line is a valid JESSE_NEEDS_HEALTH directive comes back
    // with the line STRIPPED and the parsed value under `directives.needs_health`.
    // FAILING-FIRST: without `apply_directives` between run_claude and complete,
    // the response still contains the sentinel line and `directives` is null.
    let line = r#"{"type":"result","is_error":false,"result":"Here you go.\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"],\"metrics\":[{\"metric\":\"restingHeartRate\",\"window_days\":14}]}","session_id":"sess-dir"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"ask","text":"how am I doing?"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "Here you go.",
        "directive line stripped from the reply"
    );
    assert!(!v["response"]
        .as_str()
        .unwrap()
        .contains("JESSE_NEEDS_HEALTH"));
    assert_eq!(v["directives"]["needs_health"]["sections"][0], "daily");
    assert_eq!(
        v["directives"]["needs_health"]["metrics"][0]["metric"],
        "restingHeartRate"
    );
    assert_eq!(
        v["directives"]["needs_health"]["metrics"][0]["window_days"],
        14
    );
    assert_eq!(v["session_id"], "sess-dir");
}

#[tokio::test]
async fn directive_is_extracted_on_the_sse_done_frame_consistently() {
    // The SSE `done` frame carries the SAME stripped text + directives as the
    // poll — the two terminal paths are kept consistent.
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"heartRateVariabilitySDNN\",\"window_days\":7}]}","session_id":"sess-sse"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"ask","text":"recovery?"}"#, line).await;
    // Poll: sentinel-only reply strips to empty, directive attached.
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "",
        "a sentinel-only reply strips to empty text"
    );
    assert_eq!(
        v["directives"]["needs_health"]["metrics"][0]["metric"],
        "heartRateVariabilitySDNN"
    );
    // SSE (already-terminal path): the done frame's JSON data carries directives.
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(
        sse.contains("needs_health"),
        "done frame must carry directives: {sse}"
    );
    assert!(
        sse.contains("heartRateVariabilitySDNN"),
        "metric name in done frame: {sse}"
    );
}

#[tokio::test]
async fn location_directive_is_extracted_and_stripped_on_the_poll_result() {
    // The location channel's sibling of the needs_health test above: a reply whose
    // final line is a valid JESSE_NEEDS_LOCATION directive comes back with the line
    // STRIPPED and the parsed value under `directives.needs_location` — the same
    // extractor, the same seam, so the two channels cannot diverge on delivery.
    let line = r#"{"type":"result","is_error":false,"result":"On it.\nJESSE_NEEDS_LOCATION v1 {\"fields\":[\"placemark\",\"accuracy\"],\"precision\":\"coarse\",\"max_age_seconds\":300}","session_id":"sess-loc"}"#;
    let (st, job_id) = run_turn_emitting(
        r#"{"mode":"ask","text":"anywhere for coffee near me?"}"#,
        line,
    )
    .await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "On it.",
        "directive line stripped from the reply"
    );
    assert!(!v["response"]
        .as_str()
        .unwrap()
        .contains("JESSE_NEEDS_LOCATION"));
    assert_eq!(v["directives"]["needs_location"]["fields"][0], "placemark");
    assert_eq!(v["directives"]["needs_location"]["fields"][1], "accuracy");
    assert_eq!(v["directives"]["needs_location"]["precision"], "coarse");
    assert_eq!(v["directives"]["needs_location"]["max_age_seconds"], 300);
    // The channels are separate fields, not a shared one.
    assert!(v["directives"]["needs_health"].is_null());
    assert_eq!(v["session_id"], "sess-loc");
}

#[tokio::test]
async fn location_directive_is_extracted_on_the_sse_done_frame_consistently() {
    // The SSE `done` frame carries the SAME stripped text + directives as the poll,
    // for the location channel exactly as for health.
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_NEEDS_LOCATION v1 {\"fields\":[\"coordinates\"],\"precision\":\"precise\",\"max_age_seconds\":0}","session_id":"sess-loc-sse"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"ask","text":"where am I?"}"#, line).await;
    // Poll: a sentinel-only reply strips to empty, directive attached.
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "",
        "a sentinel-only reply strips to empty text"
    );
    assert_eq!(
        v["directives"]["needs_location"]["precision"], "precise",
        "the precision the model asked for survives to the app"
    );
    // SSE (already-terminal path): the done frame's JSON data carries directives.
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(
        sse.contains("needs_location"),
        "done frame must carry directives: {sse}"
    );
    assert!(
        sse.contains("coordinates"),
        "requested field in done frame: {sse}"
    );
}

// ---- Structured provenance (v2) end-to-end ----------------------------------
//
// A delivered reply carries a machine-readable `provenance` object alongside the
// text badge, on BOTH the poll result and the SSE `done` frame. These drive a real
// hosted turn with badges ON and assert the wiring: provenance is present, its
// `badge` is byte-identical to what was appended to the text, and it is absent when
// badges are off (the older-client fallback).

// Like `run_turn_emitting`, but with the model badge switched ON so a delivered
// hosted reply carries both the text badge and structured provenance.
async fn run_badged_turn_emitting(
    req_json: &str,
    stdout_line: &str,
    model_badge: bool,
) -> (AppState, String) {
    let script = String::from("#!/bin/sh\nprintf '%s' '") + stdout_line + "'\n";
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        model_badge,
        ..test_config()
    };
    let st = AppState::new(cfg);
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), req_json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    wait_for_status(&st, &job_id, "done").await;
    let _ = std::fs::remove_file(&fake);
    (st, job_id)
}

#[tokio::test]
async fn provenance_rides_the_poll_result_and_matches_the_appended_badge() {
    // A plain hosted turn with badges on: the poll result carries `provenance` whose
    // `badge` is exactly the string appended to the end of `response` (byte-identity
    // between the structured field and the text badge older clients still read).
    let line = r#"{"type":"result","is_error":false,"result":"Here is your answer.","session_id":"sess-prov"}"#;
    let (st, job_id) =
        run_badged_turn_emitting(r#"{"mode":"ask","text":"hello"}"#, line, true).await;
    let v = result_status(&st, &job_id).await;

    let prov = &v["provenance"];
    assert!(
        prov.is_object(),
        "provenance present on a badged reply: {v}"
    );
    assert_eq!(prov["route"], "hosted", "a plain hosted turn routes hosted");
    let badge = prov["badge"].as_str().expect("badge string present");
    // The hosted main turn names the ACTIVE model (the default is opus) plus its cost.
    assert!(
        badge.starts_with("[opus"),
        "hosted badge names the active model: {badge}"
    );
    assert!(badge.contains('$'), "hosted badge carries a cost: {badge}");
    // The structured provenance carries the model + a (possibly-zero) cost.
    assert_eq!(prov["model"], "opus", "active model on the hosted route");
    assert!(
        prov["cost_usd"].is_number(),
        "cost rides the hosted provenance: {prov}"
    );
    // The structured badge is byte-identical to what was appended to the reply text.
    let response = v["response"].as_str().unwrap();
    assert!(
        response.ends_with(&format!("\n\n{badge}")),
        "response ends with the same badge: {response:?}"
    );
    assert!(
        response.starts_with("Here is your answer."),
        "answer body preserved"
    );
    // Flags are all false on a hosted turn.
    assert_eq!(prov["flags"]["hosted_verify"], false);
    assert_eq!(prov["flags"]["verify_queued"], false);
    assert_eq!(prov["flags"]["citations_unverified"], false);
}

#[tokio::test]
async fn provenance_on_the_sse_done_frame_matches_the_poll() {
    // The SSE `done` frame carries the SAME provenance as the poll — the two terminal
    // paths are kept byte-consistent (mirroring the directives contract).
    let line = r#"{"type":"result","is_error":false,"result":"Streamed answer.","session_id":"sess-prov-sse"}"#;
    let (st, job_id) =
        run_badged_turn_emitting(r#"{"mode":"ask","text":"hello"}"#, line, true).await;
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(
        sse.contains("\"provenance\""),
        "done frame carries provenance: {sse}"
    );
    assert!(
        sse.contains("\"route\":\"hosted\""),
        "route on the done frame: {sse}"
    );
}

#[tokio::test]
async fn provenance_is_null_when_badges_off_older_client_fallback() {
    // Badges off → no text badge AND no provenance object (JSON null), so an older
    // client sees exactly today's behavior: the reply text verbatim, no chip.
    let line = r#"{"type":"result","is_error":false,"result":"No badge here.","session_id":"sess-nobadge"}"#;
    let (st, job_id) =
        run_badged_turn_emitting(r#"{"mode":"ask","text":"hello"}"#, line, false).await;
    let v = result_status(&st, &job_id).await;
    assert!(
        v["provenance"].is_null(),
        "no provenance when badges are off: {v}"
    );
    assert_eq!(
        v["response"], "No badge here.",
        "reply text is unbadged and unchanged"
    );
}

#[tokio::test]
async fn unknown_directive_passes_through_visible_with_no_field() {
    // An unknown directive name is a loud contract failure: the line stays VISIBLE
    // in the reply and no `directives` field is attached. (Uses a name that is NOT
    // in the registry — both JESSE_NEEDS_HEALTH and JESSE_MEAL_LOG are known.)
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_FROBNICATE v1 {\"foo\":1}","session_id":"sess-unk"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log lunch"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "JESSE_FROBNICATE v1 {\"foo\":1}",
        "unknown directive stays visible"
    );
    assert!(
        v["directives"].is_null(),
        "no directives for an unknown name"
    );
}

// ---- Agent-emitted meal-log directive (JESSE_MEAL_LOG v1) end-to-end --------
//
// The write-direction sibling of JESSE_NEEDS_HEALTH: a diet-logging reply ends
// with a machine-readable meal line the bridge extracts + strips into
// `directives.meal_log`, which the app writes to Apple Health. Same registry,
// same seam — these mirror the needs_health end-to-end tests above.

#[tokio::test]
async fn meal_log_directive_is_extracted_and_stripped_on_the_poll_result() {
    // A reply whose final line is a valid JESSE_MEAL_LOG directive comes back with
    // the line STRIPPED and the parsed value under `directives.meal_log`.
    // FAILING-FIRST: until JESSE_MEAL_LOG is a registered directive, the sentinel
    // line stays in the reply and `directives` is null.
    let line = r#"{"type":"result","is_error":false,"result":"Logged your lunch.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-lunch\",\"consumedAt\":\"2026-07-04T12:30:00+02:00\",\"name\":\"Lunch: spaghetti, red sauce\",\"kcal\":385,\"protein_g\":13,\"carbs_g\":77,\"fat_g\":4.5}]}","session_id":"sess-meal"}"#;
    let (st, job_id) =
        run_turn_emitting(r#"{"mode":"tell","text":"log lunch: spaghetti"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "Logged your lunch.",
        "meal-log line stripped from the reply"
    );
    assert!(!v["response"].as_str().unwrap().contains("JESSE_MEAL_LOG"));
    let meal = &v["directives"]["meal_log"]["meals"][0];
    assert_eq!(meal["id"], "2026-07-04-lunch");
    assert_eq!(meal["consumedAt"], "2026-07-04T12:30:00+02:00");
    assert_eq!(meal["name"], "Lunch: spaghetti, red sauce");
    assert_eq!(meal["kcal"], 385.0);
    assert_eq!(meal["protein_g"], 13.0);
    assert_eq!(meal["carbs_g"], 77.0);
    assert_eq!(meal["fat_g"], 4.5);
    assert_eq!(v["session_id"], "sess-meal");
}

#[tokio::test]
async fn meal_log_directive_carries_micronutrients_under_their_wire_keys() {
    // A meal that carries known sodium/sugar/calcium round-trips those under the EXACT
    // wire keys the app decodes (`sodium_mg`, `sugar_g`, `calcium_mg`), while a
    // micronutrient the meal did not carry (potassium, magnesium) stays ABSENT on the
    // wire — never a null-padded 0.
    let line = r#"{"type":"result","is_error":false,"result":"Logged.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-lunch\",\"consumedAt\":\"2026-07-04T12:30:00+02:00\",\"name\":\"Lunch: prosciutto\",\"kcal\":120,\"sodium_mg\":900,\"satfat_g\":2.5,\"sugar_g\":0,\"calcium_mg\":15}]}","session_id":"sess-micro"}"#;
    let (st, job_id) =
        run_turn_emitting(r#"{"mode":"tell","text":"log lunch: prosciutto"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    let meal = &v["directives"]["meal_log"]["meals"][0];
    assert_eq!(meal["sodium_mg"], 900.0, "known sodium under `sodium_mg`");
    assert_eq!(meal["satfat_g"], 2.5, "known satfat under `satfat_g`");
    assert_eq!(
        meal["sugar_g"], 0.0,
        "measured-zero sugar carried, not dropped"
    );
    assert_eq!(meal["calcium_mg"], 15.0, "known calcium under `calcium_mg`");
    assert!(
        meal.get("potassium_mg").is_none(),
        "unknown potassium is absent on the wire, never 0"
    );
    assert!(
        meal.get("magnesium_mg").is_none(),
        "unknown magnesium is absent on the wire, never 0"
    );
}

#[tokio::test]
async fn meal_log_directive_is_extracted_on_the_sse_done_frame_consistently() {
    // The SSE `done` frame carries the SAME stripped text + meal_log as the poll —
    // the two terminal paths are kept byte-consistent (via directives_to_value).
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-snack\",\"consumedAt\":\"2026-07-04T15:00:00+02:00\",\"name\":\"Apple\"}]}","session_id":"sess-meal-sse"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log a snack"}"#, line).await;
    // Poll: sentinel-only reply strips to empty, meal_log attached.
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "",
        "a sentinel-only reply strips to empty text"
    );
    assert_eq!(
        v["directives"]["meal_log"]["meals"][0]["id"],
        "2026-07-04-snack"
    );
    // A macro that was omitted must be ABSENT on the wire (never null-padded).
    assert!(v["directives"]["meal_log"]["meals"][0]
        .get("kcal")
        .is_none());
    // SSE (already-terminal path): the done frame's JSON data carries meal_log.
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(
        sse.contains("meal_log"),
        "done frame must carry meal_log: {sse}"
    );
    assert!(
        sse.contains("2026-07-04-snack"),
        "meal id in done frame: {sse}"
    );
}

#[tokio::test]
async fn meal_log_directive_carries_a_multi_meal_array() {
    // A single reply may log several meals — the array round-trips in order.
    let line = r#"{"type":"result","is_error":false,"result":"Logged both.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-breakfast\",\"consumedAt\":\"2026-07-04T08:00:00+02:00\",\"name\":\"Oatmeal\",\"kcal\":300},{\"id\":\"2026-07-04-lunch\",\"consumedAt\":\"2026-07-04T12:30:00+02:00\",\"name\":\"Salad\",\"kcal\":250}]}","session_id":"sess-multi"}"#;
    let (st, job_id) =
        run_turn_emitting(r#"{"mode":"tell","text":"log breakfast and lunch"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Logged both.");
    let meals = v["directives"]["meal_log"]["meals"].as_array().unwrap();
    assert_eq!(meals.len(), 2);
    assert_eq!(meals[0]["id"], "2026-07-04-breakfast");
    assert_eq!(meals[1]["id"], "2026-07-04-lunch");
}

#[tokio::test]
async fn malformed_meal_log_passes_through_visible_with_no_field() {
    // A JESSE_MEAL_LOG line that fails the contract (here: an empty meals array)
    // is a loud, visible failure — the line stays in the reply, no field attached.
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_MEAL_LOG v1 {\"meals\":[]}","session_id":"sess-bad"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log nothing"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(
        v["response"], "JESSE_MEAL_LOG v1 {\"meals\":[]}",
        "malformed meal-log stays visible"
    );
    assert!(
        v["directives"].is_null(),
        "no directives for a malformed meal-log"
    );
}

#[tokio::test]
async fn meal_log_v2_directive_is_extracted_with_retract() {
    // v2 is now a REGISTERED version: a reply's final v2 line (upsert + retract, a meal
    // move) is stripped and attached under `directives.meal_log` with the retract array.
    let line = r#"{"type":"result","is_error":false,"result":"Moved it.\nJESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"2026-07-04-snack-1630\",\"consumedAt\":\"2026-07-04T16:30:00+02:00\",\"name\":\"Snack\"}],\"retract\":[\"2026-07-04-snack-1500\"]}","session_id":"sess-v2"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"move my snack"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Moved it.", "v2 line stripped");
    assert_eq!(
        v["directives"]["meal_log"]["meals"][0]["id"],
        "2026-07-04-snack-1630"
    );
    assert_eq!(
        v["directives"]["meal_log"]["retract"][0],
        "2026-07-04-snack-1500"
    );
}

#[tokio::test]
async fn meal_log_v3_and_up_passes_through_visible() {
    // An unknown VERSION (v3 and up) of a known directive must pass through untouched and
    // visible, so a future contract bump fails loudly instead of half-parsing.
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_MEAL_LOG v3 {\"meals\":[{\"id\":\"x\",\"consumedAt\":\"t\",\"name\":\"n\"}]}","session_id":"sess-v3"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log lunch"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert!(
        v["response"]
            .as_str()
            .unwrap()
            .contains("JESSE_MEAL_LOG v3"),
        "v3 stays visible"
    );
    assert!(v["directives"].is_null(), "no field for an unknown version");
}

// ---- Meal-corrections queue (POST /jesse/meal-corrections + v2 delivery) --------
//
// Off-app meal events (logged/corrected/deleted in a desktop session with no app turn)
// are POSTed to the persisted corrections queue and MERGED into the `meal_log` delivered
// on the next terminal result. Delivery is at-least-once: unacked batches redeliver; the
// app's `corrections_seq` ack prunes what it has applied. These exercise the whole seam.

/// Build a state whose corrections queue is AVAILABLE (a temp state dir) plus a fake
/// `claude` emitting `stdout_line`. Returns (state, fake_path); remove the fake when done.
fn state_with_queue(stdout_line: &str) -> (AppState, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("jesse-mcq-it-{}", random_hex()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = String::from("#!/bin/sh\nprintf '%s' '") + stdout_line + "'\n";
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        state_dir: Some(dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    (AppState::new(cfg), fake)
}

/// Fire a `POST /jesse` turn against an existing state and wait for it to reach `done`,
/// returning its job id. `req_json` is the full request body (so a caller can include a
/// `meal_corrections_ack`).
async fn run_turn_on(st: &AppState, req_json: &str) -> String {
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), req_json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    wait_for_status(st, &job_id, "done").await;
    job_id
}

/// POST a v2 batch to the corrections endpoint and return (status, body).
async fn post_corrections(st: &AppState, auth: Option<&str>, body: &str) -> (StatusCode, Value) {
    let resp = app(st.clone())
        .oneshot(meal_corrections_request(auth, body))
        .await
        .unwrap();
    let status = resp.status();
    let text = body_string(resp).await;
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    (status, v)
}

#[tokio::test]
async fn meal_corrections_endpoint_requires_auth() {
    let (st, fake) = state_with_queue("unused");
    let (status, _) = post_corrections(&st, None, r#"{"retract":["2026-07-04-snack-1500"]}"#).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "no bearer → 401");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn meal_corrections_endpoint_queues_and_returns_seq() {
    let (st, fake) = state_with_queue("unused");
    // A sodium correction — proving the micronutrient wire keys ride the endpoint too.
    let (status, v) = post_corrections(
        &st,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"2026-07-04-soup","consumedAt":"2026-07-04T12:00:00+02:00","name":"Soup","sodium_mg":900}]}"#,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(v["corrections_seq"], 1, "first batch gets seq 1");
    assert_eq!(v["status"], "queued");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn meal_corrections_endpoint_rejects_malformed_batch() {
    let (st, fake) = state_with_queue("unused");
    for bad in [
        r#"{}"#,                                                                 // empty batch
        r#"{"meals":[{"id":"a","consumedAt":"t","name":"n"}],"retract":["a"]}"#, // id in both
        r#"{"meals":[{"id":"a","consumedAt":"t","name":"n","sodium_mg":-5}]}"#,  // negative
        r#"{"retract":[5]}"#, // non-string retract
        r#"{"meals":[{"id":"a","consumedAt":"t","name":"n"}],"note":1}"#, // unknown key
    ] {
        let (status, _) = post_corrections(&st, Some("Bearer test-token"), bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "malformed rejected: {bad}");
    }
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn queued_correction_merges_into_the_next_terminal_result_with_seq() {
    // A correction posted with NO app turn is delivered on the next terminal result even
    // though that turn's own reply carries no meal_log block.
    // NB: keep the fake reply apostrophe-free — the fake `claude` wraps stdout in a
    // single-quoted shell string, so a `'` would truncate it and the turn would hang.
    let (st, fake) = state_with_queue(
        r#"{"type":"result","is_error":false,"result":"Here is your day.","session_id":"s"}"#,
    );
    post_corrections(
        &st,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"2026-07-04-soup","consumedAt":"2026-07-04T12:00:00+02:00","name":"Soup","sodium_mg":900}],"retract":["2026-07-04-gone"]}"#,
    )
    .await;
    let job_id = run_turn_on(&st, r#"{"mode":"ask","text":"how is my day?"}"#).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Here is your day.", "reply text untouched");
    let ml = &v["directives"]["meal_log"];
    assert_eq!(ml["meals"][0]["id"], "2026-07-04-soup");
    assert_eq!(
        ml["meals"][0]["sodium_mg"], 900.0,
        "micronutrient on the wire"
    );
    assert_eq!(ml["retract"][0], "2026-07-04-gone");
    assert_eq!(
        ml["corrections_seq"], 1,
        "highest queued seq stamped for ack"
    );
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn queued_corrections_merge_ahead_of_a_turn_extracted_block() {
    // The turn's OWN reply logs a fresh meal; a queued correction must precede it.
    let (st, fake) = state_with_queue(
        r#"{"type":"result","is_error":false,"result":"Logged.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-fresh\",\"consumedAt\":\"2026-07-04T19:00:00+02:00\",\"name\":\"Dinner\"}]}","session_id":"s"}"#,
    );
    post_corrections(
        &st,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"2026-07-04-queued","consumedAt":"2026-07-04T12:00:00+02:00","name":"Lunch"}]}"#,
    )
    .await;
    let job_id = run_turn_on(&st, r#"{"mode":"tell","text":"log dinner"}"#).await;
    let v = result_status(&st, &job_id).await;
    let meals = v["directives"]["meal_log"]["meals"].as_array().unwrap();
    let ids: Vec<&str> = meals.iter().map(|m| m["id"].as_str().unwrap()).collect();
    assert_eq!(
        ids,
        vec!["2026-07-04-queued", "2026-07-04-fresh"],
        "queued correction leads, this turn's own block follows"
    );
    assert_eq!(v["directives"]["meal_log"]["corrections_seq"], 1);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn unacked_corrections_redeliver_but_an_ack_prunes_them() {
    let (st, fake) =
        state_with_queue(r#"{"type":"result","is_error":false,"result":"ok","session_id":"s"}"#);
    post_corrections(
        &st,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"2026-07-04-soup","consumedAt":"2026-07-04T12:00:00+02:00","name":"Soup"}]}"#,
    )
    .await;
    // Turn 1: delivered (seq 1). No ack yet.
    let j1 = run_turn_on(&st, r#"{"mode":"ask","text":"a"}"#).await;
    let v1 = result_status(&st, &j1).await;
    assert_eq!(v1["directives"]["meal_log"]["corrections_seq"], 1);
    // Turn 2 WITHOUT ack: the unacked batch redelivers.
    let j2 = run_turn_on(&st, r#"{"mode":"ask","text":"b"}"#).await;
    let v2 = result_status(&st, &j2).await;
    assert_eq!(
        v2["directives"]["meal_log"]["meals"][0]["id"], "2026-07-04-soup",
        "unacked batch redelivers on every turn"
    );
    // Turn 3 WITH the ack: the bridge prunes seq ≤ 1, so it stops delivering.
    let j3 = run_turn_on(&st, r#"{"mode":"ask","text":"c","meal_corrections_ack":1}"#).await;
    let v3 = result_status(&st, &j3).await;
    assert!(
        v3["directives"].is_null(),
        "after ack the queue is empty → no meal_log delivered: {}",
        v3["directives"]
    );
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn queued_corrections_survive_a_bridge_restart() {
    // POST to a state over a temp dir, then build a FRESH state over the SAME dir (a
    // restart) and confirm the queued correction still delivers.
    let dir = std::env::temp_dir().join(format!("jesse-mcq-restart-{}", random_hex()));
    std::fs::create_dir_all(&dir).unwrap();
    let cfg1 = Config {
        state_dir: Some(dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st1 = AppState::new(cfg1);
    let (status, _) = post_corrections(
        &st1,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"2026-07-04-soup","consumedAt":"2026-07-04T12:00:00+02:00","name":"Soup","sodium_mg":900}]}"#,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    drop(st1); // simulate a restart

    // Fresh state + fake claude over the same state dir.
    let script = String::from(
        "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n",
    );
    let fake = write_fake_claude(&script);
    let cfg2 = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        state_dir: Some(dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st2 = AppState::new(cfg2);
    let job_id = run_turn_on(&st2, r#"{"mode":"ask","text":"after restart"}"#).await;
    let v = result_status(&st2, &job_id).await;
    assert_eq!(
        v["directives"]["meal_log"]["meals"][0]["sodium_mg"], 900.0,
        "correction persisted across the restart and delivered"
    );
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn meal_corrections_endpoint_rejects_at_cap() {
    let (st, fake) = state_with_queue("unused");
    // Fill to the cap.
    for i in 0..100 {
        let (status, _) = post_corrections(
            &st,
            Some("Bearer test-token"),
            &format!(
                r#"{{"meals":[{{"id":"m{i}","consumedAt":"2026-07-04T12:00:00+02:00","name":"n"}}]}}"#
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "batch {i} within cap");
    }
    // One past the cap is rejected loudly (429), never silently dropped.
    let (status, _) = post_corrections(
        &st,
        Some("Bearer test-token"),
        r#"{"meals":[{"id":"over","consumedAt":"2026-07-04T12:00:00+02:00","name":"n"}]}"#,
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "at cap → 429");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn plain_reply_has_null_directives() {
    // The overwhelmingly common case: an ordinary answer, unchanged, directives null.
    let line = r#"{"type":"result","is_error":false,"result":"Your inbox has three threads.","session_id":"sess-plain"}"#;
    let (st, job_id) =
        run_turn_emitting(r#"{"mode":"ask","text":"summarize my inbox"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Your inbox has three threads.");
    assert!(
        v.get("directives").is_some(),
        "the directives key is always present"
    );
    assert!(v["directives"].is_null(), "plain reply has null directives");
}

#[tokio::test]
async fn jesse_accepts_health_request_and_unavailable_fields() {
    // The two new optional flags are #[serde(default)] — a body carrying them must
    // still decode (a bad mode then 400s, proving the body parsed first).
    let resp = app(test_state())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"nope","text":"hi","health_context_requested":true,"health_context_unavailable":false}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// Capture the exact prompt that reaches `claude` for a given request body.
async fn captured_turn_prompt(req_json: &str) -> String {
    let promptfile = std::env::temp_dir().join(format!(
        "jesse-dir-prompt-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&promptfile);
    let script = format!(
        "#!/bin/sh\n\
         printf '%s' \"$2\" > '{}'\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-p\"}}'\n",
        promptfile.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), req_json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    wait_for_status(&st, &job_id, "done").await;
    let prompt = std::fs::read_to_string(&promptfile).expect("fake claude records the prompt");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&promptfile);
    prompt
}

#[tokio::test]
async fn wrapper_carries_request_instruction_without_context_and_present_note_with() {
    // No health_context → the agent is told how to ask (JESSE_NEEDS_HEALTH).
    let without = captured_turn_prompt(r#"{"mode":"ask","text":"how am I doing?"}"#).await;
    assert!(
        without.contains("JESSE_NEEDS_HEALTH v1"),
        "request instruction present: {without}"
    );
    assert!(
        !without.contains("do not emit JESSE_NEEDS_HEALTH"),
        "not the present note"
    );
    // With health_context → the present note; do not ask.
    let with = captured_turn_prompt(
        r#"{"mode":"ask","text":"log my swim","health_context":"Swim 30m 1500m"}"#,
    )
    .await;
    assert!(
        with.contains("do not emit JESSE_NEEDS_HEALTH"),
        "present note: {with}"
    );
}

#[tokio::test]
async fn health_context_cap_is_8_kib() {
    // The cap rose 4→8 KiB. Exactly at 8 KiB is accepted; one byte over is 413
    // before any spawn (the const is the single source of truth).
    assert_eq!(MAX_HEALTH_CONTEXT_BYTES, 8 * 1024, "cap is 8 KiB");
    let at_cap = "y".repeat(MAX_HEALTH_CONTEXT_BYTES);
    let json = format!(r#"{{"mode":"ask","text":"hi","health_context":"{at_cap}"}}"#);
    let resp = app(test_state())
        .oneshot(jesse_request(Some("Bearer test-token"), &json))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::ACCEPTED,
        "a block at exactly 8 KiB is accepted"
    );
}

#[tokio::test]
async fn wrapper_carries_the_location_note_matching_the_request_state() {
    // The three-state selection, end to end through a real turn.
    // 1. No location_context → the agent is told how to ask.
    let without = captured_turn_prompt(r#"{"mode":"ask","text":"anywhere for coffee?"}"#).await;
    assert!(
        without.contains("JESSE_NEEDS_LOCATION v1"),
        "request instruction present: {without}"
    );
    assert!(
        !without.contains("do not emit JESSE_NEEDS_LOCATION"),
        "not the present note"
    );
    // 2. With location_context → the present note, and the block framed as DATA.
    let with = captured_turn_prompt(
        r#"{"mode":"ask","text":"coffee near me?","location_context":"Near: Fountainbridge, Edinburgh EH3"}"#,
    )
    .await;
    assert!(
        with.contains("do not emit JESSE_NEEDS_LOCATION"),
        "present note: {with}"
    );
    assert!(
        with.contains("Near: Fountainbridge, Edinburgh EH3"),
        "the block itself rides the prompt: {with}"
    );
    assert!(
        with.contains("NOT instructions"),
        "framed as untrusted device data: {with}"
    );
    // 3. Unavailable → answer without it and do not re-request.
    let unavailable = captured_turn_prompt(
        r#"{"mode":"ask","text":"coffee near me?","location_context_unavailable":true}"#,
    )
    .await;
    assert!(
        unavailable.contains("do NOT emit JESSE_NEEDS_LOCATION again this turn"),
        "unavailable note: {unavailable}"
    );
    assert!(!unavailable.contains("do not emit JESSE_NEEDS_LOCATION."));
}

#[tokio::test]
async fn both_device_blocks_ride_one_turn_in_lead_order() {
    // A turn carrying BOTH channels: both blocks reach the prompt, health first,
    // and each channel gets its own "present" note. This is the shape the catch-up
    // splice offset had to be generalized for.
    let prompt = captured_turn_prompt(
        r#"{"mode":"ask","text":"how far is my gym?","health_context":"Run 8km","location_context":"Near: Edinburgh EH3"}"#,
    )
    .await;
    let health_at = prompt.find("Run 8km").expect("health block present");
    let location_at = prompt
        .find("Near: Edinburgh EH3")
        .expect("location block present");
    assert!(health_at < location_at, "health leads location: {prompt}");
    assert!(prompt.contains("do not emit JESSE_NEEDS_HEALTH"));
    assert!(prompt.contains("do not emit JESSE_NEEDS_LOCATION"));
}

#[tokio::test]
async fn location_context_cap_is_1_kib() {
    // Exactly at the cap is accepted; one byte over is a 413 BEFORE any spawn, and
    // the body names the field so a client knows which block it overshot on.
    assert_eq!(MAX_LOCATION_CONTEXT_BYTES, 1024, "cap is 1 KiB");
    let at_cap = "y".repeat(MAX_LOCATION_CONTEXT_BYTES);
    let json = format!(r#"{{"mode":"ask","text":"hi","location_context":"{at_cap}"}}"#);
    let resp = app(test_state())
        .oneshot(jesse_request(Some("Bearer test-token"), &json))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::ACCEPTED,
        "a block at exactly 1 KiB is accepted"
    );

    let over = "y".repeat(MAX_LOCATION_CONTEXT_BYTES + 1);
    let json = format!(r#"{{"mode":"ask","text":"hi","location_context":"{over}"}}"#);
    let resp = app(test_state())
        .oneshot(jesse_request(Some("Bearer test-token"), &json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
    let body = body_string(resp).await;
    assert!(
        body.contains("location_context"),
        "the 413 names the field it was over on: {body}"
    );
}

#[tokio::test]
async fn a_turn_that_omits_the_location_fields_is_unchanged() {
    // Backward compatibility: an app build that predates the channel sends none of
    // the three fields, and gets the same prompt as one that sends them empty.
    let old = captured_turn_prompt(r#"{"mode":"ask","text":"what is on Today.md?"}"#).await;
    let new = captured_turn_prompt(
        r#"{"mode":"ask","text":"what is on Today.md?","location_context":"","location_context_requested":false,"location_context_unavailable":false}"#,
    )
    .await;
    assert_eq!(old, new, "an omitted channel is byte-for-byte an empty one");
}

// ---- GET /jesse/diet ------------------------------------------------------
//
// Synthetic, invented fixtures (never a copy of the real personal vault) that
// exercise the file-format quirks the parser must survive: unquoted keys, single
// quotes, trailing commas, missing optional fields, embedded HTML/entities in
// coach notes, a CSV with quoted commas + blank cells, a malformed section, and
// an absent optional file.

const FIX_TODAY: &str = "// generated 2026-07-08 06:12 by generate-diet-today.js\n\
// DO NOT EDIT — regenerated on every log\n\
window.DIET_TODAY = {\n\
  date: '2026-07-08',\n\
  dayStyle: 'normal',\n\
  dayType: 'Normal training day',\n\
  weight: { lbs: 197.4, kg: 89.5, bf: 18.1, mm: 150.2, notes: 'steady' },\n\
  exercise: [\n\
    { type: 'run', time: '06:30', desc: 'easy 5', distance: 5, unit: 'mi', duration: '43:20', pace: '8:40', avgHR: 138, calories: 520 },\n\
  ],\n\
  meals: [\n\
    { name: 'Breakfast', time: '07:15', items: [\n\
      { item: 'Oatmeal', amount: '1 cup', cal: 300, p: 10, f: 5, c: 54, fiber: 8 },\n\
      { item: 'Eggs', amount: '3', cal: 210, p: 18, f: 15, c: 1, fiber: 0 },\n\
    ] },\n\
  ],\n\
  targets: { calories: 2100, protein: 190, fat: 65, carbs: 210, carbsBase: 180, fiber: 38 },\n\
};\n";

// An old-style DIET_TODAY missing the newer optional fields: no dayStyle, no
// weight (non-weigh-in day), items with no fiber, targets with no carbsBase/fiber.
const FIX_TODAY_MINIMAL: &str = "window.DIET_TODAY = {\n\
  date: '2026-07-08',\n\
  dayType: 'Rest day',\n\
  weight: null,\n\
  exercise: [],\n\
  meals: [ { name: 'Lunch', time: '12:30', items: [ { item: 'Salad', amount: '1 bowl', cal: 250, p: 8, f: 12, c: 20 } ] } ],\n\
  targets: { calories: 1900, protein: 180, fat: 60, carbs: 190 },\n\
};\n";

// Full progress fixture: the `targets` array (dated, undated with date:null,
// undated with the key omitted, and an achieved past-dated goal) is the sole
// weight-goal wire contract now that the generator no longer emits the legacy
// raceTarget/raceDate/maintTarget fields. All values invented.
const FIX_PROGRESS: &str = "window.DIET_PROGRESS = {\n\
  startWeight: 204,\n\
  troughPace: 1.4, rawPace: 1.1, fatPace: 0.9, leanPace: 0.2, paceScale: 2.0, leanScale: 1.0,\n\
  paceZone: 'good', fatZone: 'good', leanZone: 'good', barColor: '#4caf50',\n\
  raceBarFilled: 0.62, maintBarFilled: 0.88,\n\
  raceBarLabel: '24 of 39 lb', maintBarLabel: '21 of 24 lb',\n\
  paceBarLabel: '1.4 lb/wk', fatBarLabel: '0.9 lb/wk', leanBarLabel: '0.2 lb/wk',\n\
  paceSubMain: 'on pace', paceSubZone: 'target 1.0–1.5', paceSubLow: '1.0', paceSubHigh: '1.5',\n\
  fatSubMain: 'losing fat', leanSubMain: 'holding muscle',\n\
  trajectory: 'On track for the race target.',\n\
  targets: [\n\
    { id: 'bday', title: 'Birthday', short: 'Bday', weight: 180, date: '2026-08-15', daysLeft: 38, requiredPace: 2.2, achieved: false, barFilled: 11, barLabel: '13.5 / 24 lbs to 180 (56%)' },\n\
    { id: 'maint', title: 'Maintenance', short: 'Maint', weight: 165, date: null, daysLeft: null, requiredPace: null, achieved: false, barFilled: 7, barLabel: '13.5 / 39 lbs to 165 (35%)' },\n\
    { id: 'stretch', title: 'Stretch goal', short: 'Stretch', weight: 160, achieved: false, barFilled: 4, barLabel: '13.5 / 44 lbs to 160 (31%)' },\n\
    { id: 'firstcut', title: 'First cut', short: 'Cut', weight: 200, date: '2026-05-01', daysLeft: -68, requiredPace: null, achieved: true, barFilled: 20, barLabel: 'reached 200' },\n\
  ],\n\
};\n";

// A pre-array progress fixture with no `targets` key at all: a pre-rollout
// generator (or a stale cached file). Must still parse and serve 200 with
// `targets` simply absent — the app synthesizes goals locally, so bridge/app
// deploy order stays independent of the generator rollout.
const FIX_PROGRESS_LEGACY: &str = "window.DIET_PROGRESS = {\n\
  startWeight: 204,\n\
  raceBarFilled: 0.62, maintBarFilled: 0.88,\n\
  raceBarLabel: '24 of 39 lb', maintBarLabel: '21 of 24 lb',\n\
  trajectory: 'On track for the race target.',\n\
};\n";

// A progress fixture with an explicitly empty `targets: []` — the user has no
// weight goals right now. Must round-trip as an empty array (not null, not absent).
const FIX_PROGRESS_EMPTY_TARGETS: &str = "window.DIET_PROGRESS = {\n\
  startWeight: 204, troughPace: 1.4, paceZone: 'good',\n\
  targets: [],\n\
};\n";

const FIX_COACH: &str = "// coach notes\n\
window.DIET_COACH = {\n\
  date: '2026-07-08', title: 'Steady progress',\n\
  notes: [ '<strong>Great week</strong> &mdash; you hit protein every day', 'Hydration looks good' ],\n\
  ahead: [ 'Long run Saturday &ndash; carb-load Friday' ],\n\
  quote: { text: 'Discipline is choosing between what you want now and what you want most.', author: 'Abraham Lincoln' },\n\
};\n";

const FIX_PROPOSED: &str = "window.PROPOSED_DIET = {\n\
  date: '2026-07-08', source: 'coach',\n\
  ideas: [ { name: 'Afternoon snack', time: '~15:00', items: [ { item: 'Greek yogurt', amount: '1 cup', cal: 150, p: 20, f: 4, c: 9, fiber: 0 } ], notes: 'protein top-up' } ],\n\
  gapNote: 'You are ~30g short on protein.',\n\
};\n";

const FIX_WEIGHT_CSV: &str = "Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes\n\
2026-07-06,198.6,90.1,Phase 2,18.4,150.0,\"weighed after run, felt light\"\n\
2026-07-07,198.0,89.8,Phase 2,,,\n\
2026-07-08,197.4,89.5,Phase 2,18.1,150.2,steady\n";

/// Build a fully-populated synthetic vault and an AppState pointed at it.
fn diet_state_full() -> (AppState, std::path::PathBuf) {
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "vault/diet-progress.js", FIX_PROGRESS);
    write_vault_file(&vault, "vault/diet-coach-notes.js", FIX_COACH);
    write_vault_file(&vault, "vault/proposed-diet-today.js", FIX_PROPOSED);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    write_vault_file(&vault, "diet-logs/food-log.csv", FIX_FOOD_CSV);
    // The exercise log belongs in a "fully populated" vault like every other log:
    // exerciseSeries reports a missing one as an error, and this fixture asserts the
    // clean-data case carries none.
    write_vault_file(&vault, "diet-logs/exercise-log.csv", FIX_EXERCISE_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    (AppState::new(cfg), vault)
}

#[tokio::test]
async fn diet_no_auth_is_401() {
    let resp = app(test_state()).oneshot(diet_request(None)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn diet_wrong_token_is_401() {
    let resp = app(test_state())
        .oneshot(diet_request(Some("Bearer wrong")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn diet_happy_path_returns_full_normalized_snapshot() {
    let (st, vault) = diet_state_full();
    let resp = app(st)
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();

    // Envelope: RFC3339 asOf + todayMtime, empty errors.
    assert!(
        body["asOf"].as_str().unwrap().ends_with('Z'),
        "asOf is RFC3339 UTC"
    );
    assert!(
        body["todayMtime"].as_str().unwrap().ends_with('Z'),
        "todayMtime present"
    );
    assert_eq!(
        body["errors"].as_array().unwrap().len(),
        0,
        "no errors on clean data"
    );

    // today: camelCase field names passed through verbatim.
    assert_eq!(body["today"]["date"], "2026-07-08");
    assert_eq!(body["today"]["dayStyle"], "normal");
    assert_eq!(body["today"]["weight"]["bf"], 18.1);
    assert_eq!(body["today"]["exercise"][0]["avgHR"], 138);
    assert_eq!(body["today"]["meals"][0]["items"][0]["fiber"], 8);
    assert_eq!(body["today"]["targets"]["carbsBase"], 180);

    // progress: verbatim pass-through of the prerendered fields.
    assert_eq!(body["progress"]["startWeight"], 204);
    assert_eq!(body["progress"]["raceBarLabel"], "24 of 39 lb");
    assert_eq!(body["progress"]["paceZone"], "good");

    // targets: the array flows through the generic pass-through field-for-field,
    // order preserved, nulls and omitted keys intact.
    let targets = body["progress"]["targets"].as_array().unwrap();
    assert_eq!(targets.len(), 4, "four goals in declared order");
    // [0] dated goal, all fields present.
    assert_eq!(targets[0]["id"], "bday");
    assert_eq!(targets[0]["title"], "Birthday");
    assert_eq!(targets[0]["short"], "Bday");
    assert_eq!(targets[0]["weight"], 180);
    assert_eq!(targets[0]["date"], "2026-08-15");
    assert_eq!(targets[0]["daysLeft"], 38);
    assert_eq!(targets[0]["requiredPace"], 2.2);
    assert_eq!(targets[0]["achieved"], false);
    assert_eq!(targets[0]["barFilled"], 11);
    assert_eq!(targets[0]["barLabel"], "13.5 / 24 lbs to 180 (56%)");
    // [1] undated goal, `date: null` (and daysLeft/requiredPace null) preserved.
    assert_eq!(targets[1]["id"], "maint");
    assert!(
        targets[1]["date"].is_null(),
        "explicit date: null survives as null"
    );
    assert!(targets[1]["daysLeft"].is_null());
    assert!(targets[1]["requiredPace"].is_null());
    // [2] undated goal with the date key OMITTED → absent, not null.
    assert_eq!(targets[2]["id"], "stretch");
    assert!(
        targets[2].get("date").is_none(),
        "omitted date key stays omitted"
    );
    // [3] achieved goal.
    assert_eq!(targets[3]["id"], "firstcut");
    assert_eq!(targets[3]["achieved"], true);
    assert_eq!(targets[3]["daysLeft"], -68, "past date → negative daysLeft");

    // coach: HTML/entities survive verbatim (no decode/strip at the bridge).
    assert_eq!(
        body["coach"]["notes"][0],
        "<strong>Great week</strong> &mdash; you hit protein every day"
    );
    assert_eq!(body["coach"]["quote"]["author"], "Abraham Lincoln");

    // proposed: present with non-empty ideas.
    assert_eq!(body["proposed"]["ideas"][0]["name"], "Afternoon snack");
    assert_eq!(
        body["proposed"]["gapNote"],
        "You are ~30g short on protein."
    );

    // weightSeries: chronological, quoted comma preserved, blank cells → null,
    // MuscleMass_lbs → leanLbs.
    let ws = body["weightSeries"].as_array().unwrap();
    assert_eq!(ws.len(), 3);
    assert_eq!(ws[0]["date"], "2026-07-06");
    assert_eq!(ws[0]["notes"], "weighed after run, felt light");
    assert_eq!(ws[0]["leanLbs"], 150.0);
    assert!(ws[1]["bf"].is_null(), "blank bf cell → null");
    assert!(ws[1]["leanLbs"].is_null(), "blank MuscleMass cell → null");
    assert_eq!(ws[2]["lbs"], 197.4);

    // nutrientSeries: per-day, per-nutrient aggregate from the SAME food-log.csv,
    // unknown-aware. FIX_FOOD_CSV has one day (2026-04-15, four items); its header
    // stops at Fiber_g so every micro is unknown → those keys are omitted.
    let ns = body["nutrientSeries"].as_array().unwrap();
    assert_eq!(ns.len(), 1, "one day in the food log");
    assert_eq!(ns[0]["date"], "2026-04-15");
    let n = &ns[0]["nutrients"];
    // cal: Banana's Calories cell is blank → UNKNOWN (excluded from the sum, NOT 0);
    // the other three are known. This is the whole unknown-is-not-zero contract.
    assert_eq!(
        n["cal"]["sum"], 930.0,
        "300 + 450 + 180; Banana blank excluded"
    );
    assert_eq!(n["cal"]["known"], 3);
    assert_eq!(n["cal"]["unknown"], 1);
    // Macros present on every row → all-known.
    assert_eq!(n["p"]["sum"], 38.0);
    assert_eq!(n["p"]["known"], 4);
    assert_eq!(n["fiber"]["sum"], 16.0);
    assert_eq!(n["fiber"]["known"], 4);
    // No micro columns in this fixture → their keys (and derived unsat, which needs
    // SatFat_g) are omitted for the day.
    assert!(n.get("na").is_none(), "no Sodium_mg column → key omitted");
    assert!(n.get("k").is_none(), "no Potassium_mg column → key omitted");
    assert!(n.get("unsat").is_none(), "no SatFat_g → unsat omitted");

    // sourceSeries: the same food-log.csv day, but per ITEM rather than summed.
    let ss = body["sourceSeries"].as_array().unwrap();
    assert_eq!(ss.len(), 1, "one day in the food log");
    assert_eq!(ss[0]["date"], "2026-04-15");
    let items = ss[0]["items"].as_array().unwrap();
    assert_eq!(items.len(), 4, "all four rows, in file order");
    assert_eq!(items[0]["name"], "Oatmeal");
    assert_eq!(items[0]["n"]["cal"], 300.0);
    assert_eq!(items[0]["n"]["fiber"], 8.0);
    // Banana's Calories cell is blank → the key is OMITTED, never 0; its other
    // nutrients survive. Same unknown-is-not-zero contract as nutrientSeries.
    assert_eq!(items[1]["name"], "Banana");
    assert!(
        items[1]["n"].get("cal").is_none(),
        "blank Calories → cal omitted, not 0"
    );
    assert_eq!(items[1]["n"]["c"], 27.0);
    // This fixture's header stops at Fiber_g, so no item carries a micro or unsat.
    assert!(items[0]["n"].get("na").is_none());
    assert!(items[0]["n"].get("unsat").is_none());

    // exerciseSeries: the exercise log's one day, summed and counted.
    let es = body["exerciseSeries"].as_array().unwrap();
    assert_eq!(es.len(), 1, "one day in the exercise log");
    assert_eq!(es[0]["date"], "2026-04-15");
    assert_eq!(es[0]["kcal"], 740.0, "520 + 220");
    assert_eq!(es[0]["sessions"], 2);

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_missing_logs_yield_empty_series_and_recorded_errors() {
    // A vault with `today` alone: every log is absent. sourceSeries and
    // exerciseSeries must be `[]` (never null, never a panic) with one diagnostic
    // each, so the app renders an empty chart instead of failing to decode.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "missing logs are not fatal");
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();

    assert_eq!(
        body["sourceSeries"],
        serde_json::json!([]),
        "missing food-log.csv → [], not null"
    );
    assert_eq!(
        body["exerciseSeries"],
        serde_json::json!([]),
        "missing exercise-log.csv → [], not null"
    );
    let errors: Vec<&str> = body["errors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e.as_str().unwrap())
        .collect();
    assert!(
        errors.iter().any(|e| e.starts_with("sourceSeries: ")),
        "the unreadable food log is reported: {errors:?}"
    );
    assert!(
        errors.iter().any(|e| e.starts_with("exerciseSeries: ")),
        "the unreadable exercise log is reported: {errors:?}"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_empty_logs_yield_empty_series_without_errors() {
    // Present-but-header-only logs are a real state (a fresh vault): both series are
    // `[]` and, unlike the missing case, nothing is reported.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    // Header line only, taken from the fixtures themselves rather than re-typed.
    let header_of = |csv: &str| format!("{}\n", csv.lines().next().unwrap());
    write_vault_file(&vault, "diet-logs/food-log.csv", &header_of(FIX_FOOD_CSV));
    write_vault_file(
        &vault,
        "diet-logs/exercise-log.csv",
        &header_of(FIX_EXERCISE_CSV),
    );
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["sourceSeries"], serde_json::json!([]));
    assert_eq!(body["exerciseSeries"], serde_json::json!([]));
    let errors: Vec<&str> = body["errors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e.as_str().unwrap())
        .collect();
    assert!(
        !errors
            .iter()
            .any(|e| e.starts_with("sourceSeries: ") || e.starts_with("exerciseSeries: ")),
        "an empty log is not an error: {errors:?}"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_minimal_today_omits_optional_fields_cleanly() {
    // An old-style file with no dayStyle, no weigh-in, no fiber/carbsBase must
    // still parse and 200 — the absent fields simply don't appear.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY_MINIMAL);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(
        body["today"]["dayStyle"].is_null(),
        "absent dayStyle → null"
    );
    assert!(
        body["today"]["weight"].is_null(),
        "non-weigh-in day → weight null"
    );
    assert!(
        body["today"]["targets"]["carbsBase"].is_null(),
        "absent carbsBase → null"
    );
    // progress/coach files absent → null + an errors entry each (expected files).
    assert!(body["progress"].is_null());
    assert!(body["coach"].is_null());
    // proposed absent → null but NOT an error.
    assert!(body["proposed"].is_null());
    let errs = body["errors"].as_array().unwrap();
    assert!(errs
        .iter()
        .any(|e| e.as_str().unwrap().starts_with("progress:")));
    assert!(errs
        .iter()
        .any(|e| e.as_str().unwrap().starts_with("coach:")));
    assert!(
        !errs
            .iter()
            .any(|e| e.as_str().unwrap().starts_with("proposed:")),
        "absent proposed is not an error"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_missing_today_is_503() {
    // No diet-today.js at all → the screen is pointless → 503 with a JSON body.
    let vault = make_diet_vault();
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(
        body["error"].as_str().unwrap().contains("diet-today.js"),
        "JSON error body names the file"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_broken_today_is_503() {
    // diet-today.js present but unparseable → still 503.
    let vault = make_diet_vault();
    write_vault_file(
        &vault,
        "vault/diet-today.js",
        "window.DIET_TODAY = { date: , oops };",
    );
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_section_isolation_bad_progress_still_200() {
    // A broken progress file must NOT fail the endpoint: today parsed, so 200,
    // progress null, and a human-readable errors entry naming the section.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    write_vault_file(
        &vault,
        "vault/diet-progress.js",
        "window.DIET_PROGRESS = { not valid ]",
    );
    write_vault_file(&vault, "vault/diet-coach-notes.js", FIX_COACH);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "one bad section must not fail the endpoint"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["progress"].is_null(), "bad section → null");
    assert!(!body["today"].is_null(), "today still rendered");
    assert!(!body["coach"].is_null(), "sibling sections unaffected");
    let errs = body["errors"].as_array().unwrap();
    assert!(
        errs.iter()
            .any(|e| e.as_str().unwrap().starts_with("progress:")),
        "errors names the failed section: {errs:?}"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_legacy_progress_without_targets_still_serves() {
    // A pre-rollout generator emits no `targets` key. The endpoint must 200, the
    // progress block passes through, and `targets` is simply absent — the app
    // synthesizes goals locally, so deploy order is independent of the rollout.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "vault/diet-progress.js", FIX_PROGRESS_LEGACY);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(
        body["progress"]["startWeight"], 204,
        "progress passes through"
    );
    assert!(
        body["progress"].get("targets").is_none(),
        "no targets key on legacy data"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_empty_targets_round_trips_as_empty_array() {
    // `targets: []` means the user has no weight goals right now — it must survive
    // as an empty array, distinct from an absent or null field.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "vault/diet-progress.js", FIX_PROGRESS_EMPTY_TARGETS);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let targets = body["progress"]["targets"]
        .as_array()
        .expect("targets is an array");
    assert!(targets.is_empty(), "empty targets stays an empty array");
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- GET /jesse/diet?date= (day history) ----------------------------------
//
// Synthetic append-only CSV fixtures for the reconstruction path, plus a synthetic
// archive `days/<date>.js`. Dates are all in the past relative to FIX_TODAY's
// 2026-07-08, so they're valid history requests.

const FIX_FOOD_CSV: &str = "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g\n\
2026-04-15,Breakfast,Oatmeal,1,cup,,,300,10,5,54,\"cooked in water, no sugar\",07:15,Breakfast,8\n\
2026-04-15,Breakfast,Banana,1 medium (~118g),,89,118,,1,0,27,\"ripe, with spots\",07:15,Breakfast,3\n\
2026-04-15,Lunch,Sandwich,1,ea,,,450,25,18,48,\"turkey, cheese, lettuce\",12:30,Lunch,4\n\
2026-04-15,Lunch,Cookie,2,ea,,,180,2,9,24,dessert,15:00,Lunch,1\n";

const FIX_EXERCISE_CSV: &str = "Date,Type,Description,Distance_km,Duration,Pace_min_per_km,Elevation_m,Avg_HR,Cadence,Calories,Plan_Source,Notes,Start_Time\n\
2026-04-15,run,Easy morning run,8.0,56:58,7:07,45,142,168,520,plan,\"felt good, cool air\",06:30\n\
2026-04-15,strength,Upper body,,0:45:00,,,110,,220,plan,gym,17:00\n";

/// A vault whose `today` is FIX_TODAY (2026-07-08) plus the reconstruction CSVs
/// and the weight log (which carries 2026-07-06..08).
fn diet_state_history() -> (AppState, std::path::PathBuf) {
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    write_vault_file(&vault, "diet-logs/food-log.csv", FIX_FOOD_CSV);
    write_vault_file(&vault, "diet-logs/exercise-log.csv", FIX_EXERCISE_CSV);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    (AppState::new(cfg), vault)
}

#[tokio::test]
async fn diet_today_response_carries_new_history_fields() {
    // The plain today response gains availableDays / historical / fidelity, and is
    // otherwise byte-compatible (existing fields unchanged).
    let (st, vault) = diet_state_history();
    let resp = app(st)
        .oneshot(diet_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], false, "today is not historical");
    assert_eq!(body["fidelity"], "live", "today fidelity is live");
    let days = body["availableDays"].as_array().unwrap();
    assert!(
        days.iter().any(|d| d == "2026-07-08"),
        "today's own date is included"
    );
    assert!(
        days.iter().any(|d| d == "2026-04-15"),
        "a CSV date is included"
    );
    // Ascending + deduped.
    let flat: Vec<&str> = days.iter().map(|d| d.as_str().unwrap()).collect();
    let mut sorted = flat.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(flat, sorted, "availableDays sorted ascending and deduped");
    // Existing today fields unchanged.
    assert_eq!(body["today"]["dayStyle"], "normal");
    assert_eq!(body["today"]["targets"]["calories"], 2100);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_bad_date_format_is_400() {
    let (st, vault) = diet_state_history();
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-4-5"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["error"].is_string(), "400 has a JSON error body");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_unknown_date_is_404() {
    let (st, vault) = diet_state_history();
    // A valid past date with no CSV/archive data.
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-01-02"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["error"].is_string(), "404 has a JSON error body");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_future_date_is_404() {
    let (st, vault) = diet_state_history();
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2027-01-01"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_reconstructed_day_has_null_targets_and_real_logs() {
    let (st, vault) = diet_state_history();
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], true);
    assert_eq!(body["fidelity"], "reconstructed");
    assert!(
        body["today"]["targets"].is_null(),
        "reconstructed day has null targets"
    );
    assert!(body["today"]["dayStyle"].is_null());
    assert_eq!(body["today"]["date"], "2026-04-15");
    // proposed/progress/coach are null on history.
    assert!(body["proposed"].is_null());
    assert!(body["progress"].is_null());
    assert!(body["coach"].is_null());
    // Meals grouped by (Meal, Time): Breakfast@07:15, Lunch@12:30, Lunch@15:00.
    let meals = body["today"]["meals"].as_array().unwrap();
    assert_eq!(meals.len(), 3, "three meal groups: {meals:?}");
    assert_eq!(meals[0]["name"], "Breakfast");
    assert_eq!(meals[0]["time"], "07:15");
    assert_eq!(meals[0]["items"].as_array().unwrap().len(), 2);
    // Banana: blank Calories → derived from Cal_per_100g×Grams = 89*118/100 = 105.
    let banana = &meals[0]["items"][1];
    assert_eq!(banana["item"], "Banana");
    assert_eq!(banana["cal"], 105.0);
    assert_eq!(
        banana["amount"], "1 medium (~118g)",
        "amount with unit text verbatim"
    );
    // Oatmeal amount joins bare number + unit.
    assert_eq!(meals[0]["items"][0]["amount"], "1 cup");
    // Two same-named Lunch meals at different times stay separate.
    assert_eq!(meals[1]["name"], "Lunch");
    assert_eq!(meals[1]["time"], "12:30");
    assert_eq!(meals[2]["name"], "Lunch");
    assert_eq!(meals[2]["time"], "15:00");
    // Exercise reconstructed + sorted by time.
    let ex = body["today"]["exercise"].as_array().unwrap();
    assert_eq!(ex.len(), 2);
    assert_eq!(ex[0]["type"], "run");
    assert_eq!(ex[0]["time"], "06:30");
    assert_eq!(ex[0]["distance"], 8.0);
    assert_eq!(ex[0]["unit"], "km");
    assert_eq!(ex[0]["duration"], "56:58");
    assert_eq!(ex[1]["type"], "strength");
    assert!(ex[1]["distance"].is_null(), "blank distance → null");
    // No weigh-in for 2026-04-15 → weight null.
    assert!(
        body["today"]["weight"].is_null(),
        "no weigh-in that day → weight null"
    );
    // weightSeries (the historical chart) is still returned in full.
    assert_eq!(body["weightSeries"].as_array().unwrap().len(), 3);
    // sourceSeries and exerciseSeries ride along on history exactly as they do on
    // today: whole-log history, not just the requested day.
    let ss = body["sourceSeries"].as_array().unwrap();
    assert_eq!(ss[0]["date"], "2026-04-15");
    assert_eq!(ss[0]["items"].as_array().unwrap().len(), 4);
    let es = body["exerciseSeries"].as_array().unwrap();
    assert_eq!(es[0]["date"], "2026-04-15");
    assert_eq!(es[0]["kcal"], 740.0);
    assert_eq!(es[0]["sessions"], 2);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_reconstructed_day_maps_weigh_in_when_present() {
    // 2026-07-06 has a weight-log row but no food/exercise rows → reconstructed with
    // a weight object in today-weight shape (mm from MuscleMass_lbs).
    let (st, vault) = diet_state_history();
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-07-06"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["fidelity"], "reconstructed");
    assert_eq!(body["today"]["weight"]["lbs"], 198.6);
    assert_eq!(body["today"]["weight"]["bf"], 18.4);
    assert_eq!(
        body["today"]["weight"]["mm"], 150.0,
        "mm mapped from MuscleMass_lbs"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_archive_present_wins_over_reconstruction() {
    // An archive file for a date that ALSO has CSV rows: the archive is served
    // verbatim (fidelity archived, full targets), not reconstructed.
    let (st, vault) = diet_state_history();
    let archive = "// archived 2026-04-16\n\
window.DIET_TODAY = {\n\
  date: '2026-04-15', dayStyle: 'carb-load-training', dayType: 'Carb-load',\n\
  weight: null, exercise: [], meals: [ { name: 'Archived Meal', time: '09:00', items: [] } ],\n\
  targets: { calories: 2800, protein: 150, fat: 55, carbs: 400 },\n\
};\n";
    std::fs::create_dir_all(vault.join("diet-logs/days")).unwrap();
    write_vault_file(&vault, "diet-logs/days/2026-04-15.js", archive);
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], true);
    assert_eq!(
        body["fidelity"], "archived",
        "archive wins over CSV reconstruction"
    );
    assert_eq!(body["today"]["dayStyle"], "carb-load-training");
    assert_eq!(
        body["today"]["targets"]["calories"], 2800,
        "archived targets present"
    );
    assert_eq!(
        body["today"]["meals"][0]["name"], "Archived Meal",
        "served verbatim, not reconstructed"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_history_when_days_dir_absent_reconstructs_cleanly() {
    // The days/ archive directory does not exist at all → treated as no-archive, not
    // an error; the day reconstructs.
    let (st, vault) = diet_state_history();
    assert!(
        !vault.join("diet-logs/days").exists(),
        "no archive dir in this fixture"
    );
    let resp = app(st)
        .oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["fidelity"], "reconstructed");
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- Single-writer default + bounded queue ---------------------------------

#[tokio::test]
async fn two_overlapping_turns_serialize_and_both_complete() {
    // Concurrency 1: two turns submitted back-to-back must run one-at-a-time. A
    // fake claude records START on spawn and END on exit (bracketing a short
    // sleep) into a shared log. Serialized execution yields START,END,START,END —
    // never overlapping STARTs — and both turns complete.
    let log = std::env::temp_dir().join(format!(
        "jesse-serialize-{}-{}.log",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&log);
    let script = format!(
        "#!/bin/sh\n\
         printf 'START\\n' >> '{log}'\n\
         sleep 1\n\
         printf 'END\\n' >> '{log}'\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}}'\n",
        log = log.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]),
        max_queued: 4,
        ..test_config()
    };
    let st = AppState::new(cfg);

    // Fire both turns; both are accepted immediately (one Ready, one Queued).
    let mut ids = Vec::new();
    for text in ["first", "second"] {
        let resp = app(st.clone())
            .oneshot(jesse_request(
                Some("Bearer test-token"),
                &format!(r#"{{"mode":"ask","text":"{text}"}}"#),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::ACCEPTED);
        let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        ids.push(body["job_id"].as_str().unwrap().to_string());
    }

    // Wait for both to finish.
    for id in &ids {
        wait_for_status(&st, id, "done").await;
    }

    // The spawns did not overlap: the log is exactly START,END,START,END.
    let contents = std::fs::read_to_string(&log).unwrap();
    let lines: Vec<&str> = contents.lines().collect();
    assert_eq!(
        lines,
        ["START", "END", "START", "END"],
        "turns must serialize (no overlapping claude spawns): {contents:?}"
    );

    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn queued_turn_returns_202_immediately_and_stream_reflects_the_wait() {
    // A second turn is accepted (202) the instant it's submitted even though the
    // only permit is held by a still-running first turn — it is NOT held until a
    // permit frees. Its live stream reflects the wait via the activity hint.
    let script = "#!/bin/sh\nsleep 3\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]),
        max_queued: 4,
        ..test_config()
    };
    let st = AppState::new(cfg);

    // First turn takes the permit.
    let first = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"one"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::ACCEPTED);

    // Second turn: returned promptly (well under the first turn's 3s run) with
    // status running — proof the POST never blocks on a permit.
    let start = std::time::Instant::now();
    let second = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"two"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::ACCEPTED);
    assert!(
        start.elapsed() < Duration::from_secs(2),
        "202 must be immediate, not held for a permit"
    );
    let body: Value = serde_json::from_str(&body_string(second).await).unwrap();
    assert_eq!(body["status"], "running");
    let queued_id = body["job_id"].as_str().unwrap().to_string();

    // The queued turn's stream carries the "queued behind another turn" activity.
    let jobs = &st.jobs;
    let queued_ref = queued_id.as_str();
    wait_for(
        "a queued turn's stream to reflect the wait",
        move || async move {
            let (_text, activity, _rx) = jobs.stream_subscribe(queued_ref)?;
            (activity.as_ref().map(|a| a.name.as_str()) == Some(QUEUED_ACTIVITY)).then_some(())
        },
    )
    .await;

    // Clean up: cancel the queued turn so the fake claude sleep doesn't linger.
    let _ = app(st.clone())
        .oneshot(cancel_request(Some("Bearer test-token"), &queued_id))
        .await;
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn cancelling_a_queued_turn_frees_its_slot_and_never_spawns_claude() {
    // Concurrency 1, queue depth 1. Turn A holds the permit (long sleep). Turn B
    // queues behind it. Cancelling B: it goes Cancelled, its claude never spawns
    // (the shared spawn-log gains no second line), and its queue slot frees (a new
    // turn C can queue again rather than being shed).
    let log = std::env::temp_dir().join(format!(
        "jesse-qcancel-{}-{}.log",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&log);
    let script = format!(
        "#!/bin/sh\n\
         printf 'spawn\\n' >> '{log}'\n\
         sleep 8\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}}'\n",
        log = log.display()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        concurrency: ConcurrencySettings::uniform(1, &["opus"]),
        max_queued: 1,
        ..test_config()
    };
    let st = AppState::new(cfg);

    // A: takes the permit and spawns claude (writes one "spawn" line).
    let a = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"a"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(a.status(), StatusCode::ACCEPTED);

    // Wait until A's claude has actually spawned (its one "spawn" line lands), so
    // the count assertion below is deterministic rather than timing-dependent.
    let log_ref = &log;
    wait_for("the running turn A to spawn claude", move || async move {
        (std::fs::read_to_string(log_ref)
            .unwrap_or_default()
            .lines()
            .count()
            >= 1)
            .then_some(())
    })
    .await;

    // B: queued (202) behind A; it must NOT spawn claude.
    let b = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"b"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(b.status(), StatusCode::ACCEPTED);
    let b_id: Value = serde_json::from_str(&body_string(b).await).unwrap();
    let b_id = b_id["job_id"].as_str().unwrap().to_string();

    // Let B settle into the wait.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Cancel the queued turn B.
    let cancel = app(st.clone())
        .oneshot(cancel_request(Some("Bearer test-token"), &b_id))
        .await
        .unwrap();
    assert_eq!(cancel.status(), StatusCode::NO_CONTENT);

    // Let the abort propagate.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // B is cleanly cancelled.
    assert_eq!(result_status(&st, &b_id).await["status"], "cancelled");

    // Only A ever spawned claude — B's claude never ran.
    let spawns = std::fs::read_to_string(&log).unwrap_or_default();
    assert_eq!(
        spawns.lines().count(),
        1,
        "the cancelled queued turn must never spawn claude: {spawns:?}"
    );

    // The freed slot is reusable: a new turn C queues (202) rather than 429.
    let c = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"c"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        c.status(),
        StatusCode::ACCEPTED,
        "cancelling the queued turn must free its slot"
    );

    // The running turns' fake-claude sleeps are killed (kill_on_drop) when `st`
    // and its tasks drop at end of test.
    let _ = std::fs::remove_file(&log);
    let _ = std::fs::remove_file(&fake);
}

// ---- GET /jesse/sessions ----------------------------------------------------

// ---- DELETE /jesse/session/{id} --------------------------------------------

// ---- Deletion tombstones (the `deleted` array on GET /jesse/sessions) -------

// Age-based GC reclaims a session past the TTL but records NO deletion tombstone: a
// device merely offline while a session aged out must keep its local copy. Only an
// explicit user delete records one.
#[tokio::test]
async fn session_gc_records_no_tombstone() {
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    let vault = format!("/vault/{}", random_hex());
    let proj = home
        .join(".claude")
        .join("projects")
        .join(escape_project_path(&vault));
    std::fs::create_dir_all(&proj).unwrap();
    let ancient = proj.join("ancient.jsonl");
    std::fs::write(&ancient, "{\"type\":\"user\"}\n").unwrap();
    // Age it far past any TTL (mtime at the epoch).
    let epoch = std::time::UNIX_EPOCH;
    std::fs::File::open(&ancient)
        .unwrap()
        .set_modified(epoch)
        .unwrap();

    let cfg = Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        session_ttl_days: 90,
        ..test_config()
    };
    let st = AppState::new(cfg);

    run_session_gc(&st.cfg, &st.conversations, &st.titles, &st.flags);

    assert!(!ancient.exists(), "GC reclaimed the aged-out session");
    assert!(
        st.deletions.is_empty(),
        "GC must record NO deletion tombstone"
    );

    // And the conversation list shows an empty `deleted` array after GC.
    let resp = app(st)
        .oneshot(conversations_request(Some("Bearer test-token"), None, None))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(
        body["deleted"],
        serde_json::json!([]),
        "no tombstone from GC"
    );

    let _ = std::fs::remove_dir_all(&home);
}

// ---- POST /jesse/session/{id}/flags ----------------------------------------

#[tokio::test]
async fn session_flags_unknown_id_is_404() {
    // A plain but unknown id (no transcript on disk) → 404, exactly like hydrate.
    let st = test_state();
    let resp = app(st)
        .oneshot(session_flags_request(
            Some("Bearer test-token"),
            "no-such-session",
            r#"{"favorite":true,"favorite_updated_ms":1}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---- GET /jesse/sessions/{id} — transcript hydration -----------------------

/// A throwaway HOME whose escaped vault projects dir holds `session_id.jsonl` with
/// the given contents; returns `(home, cfg, AppState)`. Mirrors the pattern the
/// session-list tests use (per-test `cfg.home`, no global-env mutation).
fn hydrate_fixture(session_id: &str, jsonl: &str) -> (std::path::PathBuf, AppState) {
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    let vault = format!("/vault/{}", random_hex());
    let proj = home
        .join(".claude")
        .join("projects")
        .join(escape_project_path(&vault));
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join(format!("{session_id}.jsonl")), jsonl).unwrap();
    let cfg = Config {
        home: home.to_string_lossy().into_owned(),
        vault,
        state_dir: None,
        ..test_config()
    };
    (home, AppState::new(cfg))
}

#[tokio::test]
async fn hydrate_unknown_id_is_404() {
    let (home, st) = hydrate_fixture(
        "exists",
        "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n",
    );
    let resp = app(st)
        .oneshot(hydrate_request(
            Some("Bearer test-token"),
            "does-not-exist",
            None,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&home);
}

// ---- POST /jesse/title server-side store -----------------------------------

#[tokio::test]
async fn title_with_conversation_id_persists_and_survives_restart() {
    // A title request carrying a conversation_id persists the minted title under it; a
    // fresh store over the same state dir reloads it (restart survival). Same property
    // as before the conversation registry, now on the key the title store actually
    // uses: a session id is no longer stable, so it can no longer be that key. Uses a
    // fake claude that returns a clean title.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Roof Repair Plan\",\"session_id\":\"x\"}'\n";
    let fake = write_fake_claude(script);
    let state_dir = std::env::temp_dir().join(format!("jesse-titlestate-{}", random_hex()));
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st = AppState::new(cfg.clone());
    let cid = "9c0b7a15-3d24-4e88-b1f6-0a7c5e9d4b23";

    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            &format!(r#"{{"text":"the roofer is coming Thursday","conversation_id":"{cid}"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["title"], "Roof Repair Plan");

    // In-memory store now has it, under the conversation.
    assert_eq!(st.titles.get(cid).as_deref(), Some("Roof Repair Plan"));

    // Restart survival: a fresh store over the same state dir reloads the title.
    let reloaded = AppState::new(cfg);
    assert_eq!(
        reloaded.titles.get(cid).as_deref(),
        Some("Roof Repair Plan")
    );

    // A malformed conversation_id is a 400 and stores nothing.
    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"x","conversation_id":"NOT-A-UUID"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(st.titles.len(), 1);

    let _ = std::fs::remove_dir_all(&state_dir);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn title_with_a_deprecated_session_id_resolves_through_the_reverse_index() {
    // A pre-0.33 client names a session. The title store is conversation-keyed, so the
    // id is resolved through the reverse index and the title lands where the list reads
    // it. An id that resolves to NO conversation stores nothing, rather than writing a
    // key no read path would ever look at.
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    let vault_dir = std::env::temp_dir().join(format!("jesse-vault-{}", random_hex()));
    std::fs::create_dir_all(&vault_dir).unwrap();
    let vault = vault_dir.to_string_lossy().into_owned();
    let proj = home
        .join(".claude")
        .join("projects")
        .join(escape_project_path(&vault));
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(
        proj.join("sess-roof.jsonl"),
        "{\"type\":\"user\",\"message\":{\"content\":\"the roofer\"}}\n",
    )
    .unwrap();
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Roof Repair Plan\",\"session_id\":\"x\"}'\n";
    let fake = write_fake_claude(script);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault,
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    });
    let cid = own_transcript(&st, "sess-roof");

    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"the roofer is coming Thursday","session_id":"sess-roof"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        st.titles.get(&cid).as_deref(),
        Some("Roof Repair Plan"),
        "the title landed on the conversation the session belongs to"
    );
    assert_eq!(
        st.titles.get("sess-roof"),
        None,
        "and not on the session id"
    );

    // An unresolvable session id stores nothing.
    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"x","session_id":"local-abc"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(st.titles.len(), 1, "nothing was stored for the unknown id");

    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&vault_dir);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn title_without_a_thread_id_persists_nothing() {
    // Naming neither a conversation nor a session reproduces the stateless behavior:
    // nothing stored.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Some Title\",\"session_id\":\"x\"}'\n";
    let fake = write_fake_claude(script);
    let state_dir = std::env::temp_dir().join(format!("jesse-titlestate-{}", random_hex()));
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"a conversation"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(st.titles.is_empty(), "no thread id, nothing persisted");

    let _ = std::fs::remove_dir_all(&state_dir);
    let _ = std::fs::remove_file(&fake);
}

// ---- Local vault-QA route (POST /jesse ask, contained read-only child) ------
//
// Drive a self-referential Ask through the real handler with a prompt-sniffing
// fake `claude`: the vault-QA child prompt carries "INSTRUCTIONS:" and the hosted
// turn prompt carries the clock header, so one fake binary can emit different
// output per child and the tests can prove (a) a validated local answer SKIPS the
// hosted turn and (b) any ladder rung falls through to the hosted path.

/// A fake `claude` that answers the vault-QA child (prompt contains "INSTRUCTIONS:")
/// with `child_result` and the hosted turn with `hosted_result`, each a bare result
/// string (no single quotes — it is single-quoted for printf).
fn write_sniffing_fake(child_result: &str, hosted_result: &str) -> std::path::PathBuf {
    let script = format!(
        "#!/bin/sh\n\
         if printf '%s' \"$2\" | grep -q 'INSTRUCTIONS:'; then\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"{child_result}\",\"session_id\":\"sess-vq\"}}'\n\
         else\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"{hosted_result}\",\"session_id\":\"sess-h\"}}'\n\
         fi\n"
    );
    write_fake_claude(&script)
}

async fn run_vaultqa_turn(cfg: Config, ask_text: &str) -> Value {
    let st = AppState::new(cfg);
    let body = format!(
        r#"{{"mode":"ask","text":{}}}"#,
        serde_json::to_string(ask_text).unwrap()
    );
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let b: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = b["job_id"].as_str().unwrap().to_string();
    wait_for_status(&st, &job_id, "done").await
}

#[tokio::test]
async fn vaultqa_local_answer_is_delivered_and_skips_the_hosted_turn() {
    // A validated, cited local answer is returned verbatim and the hosted turn does
    // NOT run — proven because the hosted branch of the fake would emit the sentinel
    // HOSTED_SHOULD_NOT_RUN, which must be absent from the reply.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\nVO2 max is 52.\n");
    let fake = write_sniffing_fake(
        "Your VO2 max is 52 (vault/Today.md:2).",
        "HOSTED_SHOULD_NOT_RUN",
    );
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });
    let v = run_vaultqa_turn(cfg, "what is my VO2 max lately").await;
    assert_eq!(v["response"], "Your VO2 max is 52 (vault/Today.md:2).");
    assert!(
        !v["response"]
            .as_str()
            .unwrap()
            .contains("HOSTED_SHOULD_NOT_RUN"),
        "the hosted turn must NOT run when the local answer is delivered"
    );
    // A stateless local answer carries no session id and no directives.
    assert!(
        v["session_id"].is_null(),
        "local vault-QA answer is stateless"
    );
    assert!(v["directives"].is_null());
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn vaultqa_no_vault_answer_falls_through_to_the_hosted_turn() {
    // The child emits NO_VAULT_ANSWER (rung 3) → the turn falls through and the reply
    // is the HOSTED text, proving the ladder handed off rather than delivering the
    // sentinel to the user.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\n");
    let fake = write_sniffing_fake("NO_VAULT_ANSWER", "Hosted answered from the session.");
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });
    let v = run_vaultqa_turn(cfg, "what is my VO2 max lately").await;
    assert_eq!(
        v["response"], "Hosted answered from the session.",
        "a NO_VAULT_ANSWER child must fall through to the hosted turn"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn vaultqa_uncited_answer_falls_through_to_the_hosted_turn() {
    // The child answers but with NO citation (rung 5, validator fail) → fall through.
    let vault = make_diet_vault();
    let fake = write_sniffing_fake(
        "Your VO2 max is about 52, from memory.",
        "Hosted answered instead.",
    );
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });
    let v = run_vaultqa_turn(cfg, "what is my VO2 max lately").await;
    assert_eq!(
        v["response"], "Hosted answered instead.",
        "an uncited local answer must be rejected by the validator and fall through"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

// ---- Model badge (JESSE_MODEL_BADGE, default on) ----------------------------
//
// The display-only provenance line the bridge appends to every delivered
// /jesse/jesse reply. The test fixture defaults the badge OFF (so the exact
// response assertions above are unaffected); these tests enable it explicitly.

#[tokio::test]
async fn badge_on_hosted_turn_appends_a_hosted_badge() {
    // A plain hosted Ask (no local backends) gets a trailing badge naming the ACTIVE
    // model (the default is opus) and the turn's cost after its answer.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Your inbox has three threads.\",\"session_id\":\"sess-b\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        model_badge: true,
        timeout_secs: 30,
        ..test_config()
    };
    let v = run_vaultqa_turn(cfg, "summarize my inbox").await;
    let resp = v["response"].as_str().unwrap();
    assert!(
        resp.starts_with("Your inbox has three threads."),
        "answer preserved: {resp:?}"
    );
    assert!(
        resp.contains("\n\n[opus"),
        "a hosted badge naming the active model is appended: {resp:?}"
    );
    assert!(resp.ends_with(']'), "badge is the trailing line: {resp:?}");
    // Exactly one appended badge.
    assert_eq!(resp.matches("\n\n[opus").count(), 1, "exactly one badge");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn badge_on_vaultqa_local_answer_names_the_vault_backend() {
    // A validated local vault-QA answer gets the [local · vault · <model>] badge.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\nVO2 max is 52.\n");
    let fake = write_sniffing_fake(
        "Your VO2 max is 52 (vault/Today.md:2).",
        "HOSTED_SHOULD_NOT_RUN",
    );
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        model_badge: true,
        timeout_secs: 30,
        ..test_config()
    });
    let v = run_vaultqa_turn(cfg, "what is my VO2 max lately").await;
    let resp = v["response"].as_str().unwrap();
    assert!(
        resp.starts_with("Your VO2 max is 52 (vault/Today.md:2)."),
        "answer preserved: {resp:?}"
    );
    assert!(
        resp.ends_with("\n\n[local · vault · local-vaultqa]"),
        "vault badge: {resp:?}"
    );
    assert!(
        !resp.contains("HOSTED_SHOULD_NOT_RUN"),
        "hosted turn must not run"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn badge_never_applies_to_the_title_endpoint() {
    // The title endpoint is exempt even with the badge on: a title is not a reply.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Weekend Trip\",\"session_id\":\"sess-t\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        model_badge: true,
        ..test_config()
    };
    let st = AppState::new(cfg);
    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"planning a weekend trip to the coast"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let title = v["title"].as_str().unwrap();
    assert_eq!(title, "Weekend Trip", "title carries no badge");
    assert!(!title.contains('['), "no badge on a title: {title:?}");
    let _ = std::fs::remove_file(&fake);
}

// ---- Context carry (JESSE_CONTEXT_CARRY, default on) ------------------------
//
// The bridge-side ledger that fixes the live defect: a locally-served turn never
// entered the thread's hosted session, so a later hosted follow-up lost it. These
// drive the REAL handler end to end with a prompt-sniffing fake `claude`.

/// POST one `/jesse` turn against `st` and poll to a terminal result.
async fn carry_post_and_wait(st: &AppState, body: &str) -> Value {
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let b: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = b["job_id"].as_str().unwrap().to_string();
    wait_for_status(st, &job_id, "done").await
}

#[tokio::test]
async fn context_carry_off_local_turn_is_stateless_today() {
    // The kill switch, at the router: with carry OFF (the fixture default), a fresh
    // local vault-QA answer carries session_id: null (today's stateless behavior) and
    // the ledger records NOTHING. This is the byte-for-byte control for the ON tests.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\nVO2 max is 52.\n");
    let fake = write_sniffing_fake("Your VO2 max is 52 (vault/Today.md:2).", "HOSTED");
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        context_carry: false,
        timeout_secs: 30,
        ..test_config()
    });
    let st = AppState::new(cfg);
    let v = carry_post_and_wait(&st, r#"{"mode":"ask","text":"what is my VO2 max lately"}"#).await;
    assert_eq!(v["response"], "Your VO2 max is 52 (vault/Today.md:2).");
    assert!(
        v["session_id"].is_null(),
        "carry off → stateless, no synthetic id"
    );
    assert_eq!(st.context.thread_count(), 0, "carry off → nothing recorded");
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn context_carry_on_fresh_local_turn_mints_a_synthetic_id() {
    // Carry ON: a fresh locally-served turn (no request session) is handed a synthetic
    // `local-<hex>` session id so the app can send it back on the follow-up, and the
    // turn is recorded under that id as PENDING (not yet in any hosted session).
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\nVO2 max is 52.\n");
    let fake = write_sniffing_fake("Your VO2 max is 52 (vault/Today.md:2).", "HOSTED");
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        context_carry: true,
        timeout_secs: 30,
        ..test_config()
    });
    let st = AppState::new(cfg);
    let v = carry_post_and_wait(&st, r#"{"mode":"ask","text":"what is my VO2 max lately"}"#).await;
    let sid = v["session_id"]
        .as_str()
        .expect("carry on → a synthetic session id");
    assert!(
        sid.starts_with("local-"),
        "fresh local turn mints a synthetic id: {sid}"
    );
    assert_eq!(
        st.context.thread_len(sid),
        1,
        "recorded under the synthetic id"
    );
    assert_eq!(st.context.pending(sid).len(), 1, "a local turn is pending");
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn context_carry_records_pre_badge_reply_so_no_badge_leaks_into_a_block() {
    // The badge is display-only: the ledger stores the reply PRE-badge, so a badge
    // string can never appear in a catch-up or recent-conversation block. Proven with
    // the badge ON: the delivered response carries the trailing badge, but the recorded
    // ledger reply — and any block built from it — does not.
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", "# Today\nVO2 max is 52.\n");
    let fake = write_sniffing_fake("Your VO2 max is 52 (vault/Today.md:2).", "HOSTED");
    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        context_carry: true,
        model_badge: true,
        timeout_secs: 30,
        ..test_config()
    });
    let st = AppState::new(cfg);
    let v = carry_post_and_wait(&st, r#"{"mode":"ask","text":"what is my VO2 max lately"}"#).await;
    // The DELIVERED reply carries the display badge.
    assert!(
        v["response"]
            .as_str()
            .unwrap()
            .contains("[local · vault · local-vaultqa]"),
        "delivered reply carries the badge: {}",
        v["response"]
    );
    // The RECORDED reply is pre-badge — no badge string anywhere.
    let sid = v["session_id"].as_str().unwrap();
    let recorded = &st.context.recent(sid, 1)[0].reply;
    assert!(
        !recorded.contains("[local") && !recorded.contains("[hosted"),
        "the ledger stores pre-badge text: {recorded}"
    );
    assert_eq!(recorded, "Your VO2 max is 52 (vault/Today.md:2).");
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
}

/// A fake `claude` for the end-to-end transcript scenario. The vault-QA/emergency
/// child (prompt carries `INSTRUCTIONS:`) answers from the fixture with a citation.
/// The hosted turn FAILS transport-class on its first call (so emergency takes over)
/// and, on its second call, captures its full argv to `argv_file` and returns a real
/// session id. `count_file` distinguishes the two hosted calls.
fn write_transcript_fake(
    count_file: &std::path::Path,
    argv_file: &std::path::Path,
) -> std::path::PathBuf {
    let script = format!(
        "#!/bin/sh\n\
         if printf '%s' \"$2\" | grep -q 'INSTRUCTIONS:'; then\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"Her birthday is March 3 (people/jamie.md:1).\",\"session_id\":null}}'\n\
         exit 0\n\
         fi\n\
         n=$(cat '{count}' 2>/dev/null || echo 0)\n\
         n=$((n+1))\n\
         printf '%s' \"$n\" > '{count}'\n\
         if [ \"$n\" = \"1\" ]; then\n\
         printf 'connect ECONNREFUSED 127.0.0.1:9100\\n' >&2\n\
         exit 1\n\
         fi\n\
         printf '%s\\n' \"$@\" > '{argv}'\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"She is 40.\",\"session_id\":\"real-sess-xyz\"}}'\n",
        count = count_file.display(),
        argv = argv_file.display(),
    );
    write_fake_claude(&script)
}

#[tokio::test]
async fn context_carry_end_to_end_pins_todays_transcript() {
    // The flagship scenario from the defect report, pinned:
    //   turn 1 "What is Jamie's birthday?" — hosted is DOWN (fake transport failure),
    //     so the emergency child answers from the fixture vault; the reply carries a
    //     synthetic local- session id.
    //   turn 2 "So how old is she?" — arrives with that id, runs HOSTED (fake captures
    //     argv). The captured hosted prompt contains turn 1's question AND answer, argv
    //     has no --resume, and the ledger ends re-keyed to the real returned id.
    let vault = make_diet_vault();
    std::fs::create_dir_all(vault.join("people")).unwrap();
    write_vault_file(&vault, "people/jamie.md", "Jamie was born on March 3.\n");
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let count_file =
        std::env::temp_dir().join(format!("jesse-cc-count-{}-{}.txt", std::process::id(), n));
    let argv_file =
        std::env::temp_dir().join(format!("jesse-cc-argv-{}-{}.txt", std::process::id(), n));
    let _ = std::fs::remove_file(&count_file);
    let _ = std::fs::remove_file(&argv_file);
    let fake = write_transcript_fake(&count_file, &argv_file);

    let cfg = with_vaultqa_offload(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        emergency_local: true,
        context_carry: true,
        timeout_secs: 30,
        ..test_config()
    });
    let st = AppState::new(cfg);

    // Turn 1: emergency-served, fresh thread → synthetic id.
    let v1 = carry_post_and_wait(&st, r#"{"mode":"ask","text":"What is Jamie's birthday?"}"#).await;
    assert!(
        v1["response"].as_str().unwrap().contains("March 3"),
        "turn 1 answered from the vault by the emergency child: {}",
        v1["response"]
    );
    let synthetic = v1["session_id"]
        .as_str()
        .expect("turn 1 carries a synthetic id");
    assert!(
        synthetic.starts_with("local-"),
        "synthetic id minted: {synthetic}"
    );
    assert_eq!(st.context.pending(synthetic).len(), 1, "turn 1 is pending");

    // Turn 2: follow-up carrying the synthetic id → runs hosted.
    let body2 = format!(
        r#"{{"mode":"ask","text":"So how old is she?","session_id":{}}}"#,
        serde_json::to_string(synthetic).unwrap()
    );
    let v2 = carry_post_and_wait(&st, &body2).await;
    assert_eq!(v2["response"], "She is 40.", "turn 2 is hosted");
    assert_eq!(
        v2["session_id"], "real-sess-xyz",
        "turn 2 carries the real hosted session id"
    );

    // The captured hosted prompt carries turn 1's question AND answer, no --resume.
    let argv = std::fs::read_to_string(&argv_file).expect("turn 2 captured its argv");
    assert!(
        argv.contains("What is Jamie's birthday?"),
        "hosted catch-up carries turn 1's question: {argv}"
    );
    assert!(
        argv.contains("March 3"),
        "hosted catch-up carries turn 1's answer: {argv}"
    );
    assert!(
        argv.contains("MISSED CONVERSATION HISTORY"),
        "the catch-up block is framed as data"
    );
    assert!(
        !argv.lines().any(|l| l == "--resume"),
        "a synthetic id must never reach --resume: {argv}"
    );

    // The ledger is re-keyed from the synthetic id to the real returned id, and the
    // once-pending turn 1 is now marked in_hosted_history (absorbed by the session).
    assert_eq!(
        st.context.thread_len(synthetic),
        0,
        "synthetic thread re-keyed away"
    );
    assert!(
        st.context.thread_len("real-sess-xyz") >= 2,
        "turns live under the real id now"
    );
    assert!(
        st.context.pending("real-sess-xyz").is_empty(),
        "turn 1 was marked in_hosted_history on the hosted follow-up"
    );

    // Turn 3: another hosted turn on the SAME (now real) thread. Because turn 2 already
    // marked the pending entry in_hosted_history, there is nothing left to catch up —
    // so turn 3's captured hosted prompt carries NO catch-up block (no double-inject).
    let body3 = r#"{"mode":"ask","text":"And where does she live?","session_id":"real-sess-xyz"}"#;
    let v3 = carry_post_and_wait(&st, body3).await;
    assert_eq!(v3["response"], "She is 40.");
    let argv3 = std::fs::read_to_string(&argv_file).expect("turn 3 captured its argv");
    assert!(
        !argv3.contains("MISSED CONVERSATION HISTORY"),
        "an already-absorbed thread must not re-inject the catch-up block: {argv3}"
    );

    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&count_file);
    let _ = std::fs::remove_file(&argv_file);
}

// ---- POST /jesse idempotency (request_id dedup) ---------------------------
//
// A client that never saw the 202 for a POST can re-send the SAME request with the
// SAME `request_id`; the bridge returns the ORIGINAL job instead of spawning a
// second turn. These drive the real router end-to-end with a fake `claude` that
// records every spawn to a counter file, so "spawned exactly once" is observable.

/// A fake `claude` that appends one line to `counter` on every spawn (so a test can
/// count how many turns actually ran) and then emits a terminal result line. The
/// `sleep` keeps the turn briefly live so a duplicate POST lands while it runs.
fn spawn_counting_claude(counter: &std::path::Path, sleep_secs: u32) -> std::path::PathBuf {
    let script = format!(
        "#!/bin/sh\n\
         echo x >> '{}'\n\
         sleep {sleep_secs}\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"deduped ok\",\"session_id\":\"sess-dedup\"}}'\n",
        counter.display()
    );
    write_fake_claude(&script)
}

fn spawn_count(counter: &std::path::Path) -> usize {
    std::fs::read_to_string(counter)
        .map(|s| s.lines().filter(|l| !l.is_empty()).count())
        .unwrap_or(0)
}

fn counter_path() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "jesse-spawns-{}-{}.txt",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

async fn wait_for_done(st: &AppState, job_id: &str) -> Value {
    wait_for_status(st, job_id, "done").await
}

#[tokio::test]
async fn dedup_same_request_id_twice_returns_same_job_and_spawns_once() {
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    let fake = spawn_counting_claude(&counter, 1);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let body = r#"{"mode":"ask","text":"hi","request_id":"dup-abc"}"#;
    // First POST creates the job.
    let r1 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    assert_eq!(r1.status(), StatusCode::ACCEPTED);
    let b1: Value = serde_json::from_str(&body_string(r1).await).unwrap();
    assert_eq!(b1["status"], "running");
    let id1 = b1["job_id"].as_str().unwrap().to_string();

    // Second POST with the SAME request_id — same job id back, same fresh-accept shape.
    let r2 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    assert_eq!(r2.status(), StatusCode::ACCEPTED);
    let b2: Value = serde_json::from_str(&body_string(r2).await).unwrap();
    assert_eq!(b2["status"], "running");
    assert_eq!(
        b2["job_id"].as_str().unwrap(),
        id1,
        "a duplicate request_id must return the ORIGINAL job id"
    );

    let done = wait_for_done(&st, &id1).await;
    assert_eq!(done["response"], "deduped ok");
    assert_eq!(
        spawn_count(&counter),
        1,
        "the duplicate POST must not spawn a second claude"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dedup_two_concurrent_duplicate_posts_yield_one_job() {
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    let fake = spawn_counting_claude(&counter, 1);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        // Two permits so BOTH would run concurrently if the dedup didn't collapse them.
        concurrency: ConcurrencySettings::uniform(2, &["opus"]),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let body = r#"{"mode":"ask","text":"race","request_id":"race-key"}"#;
    // Fire both POSTs in parallel on separate tasks — the check-and-insert under the
    // job store's one lock must let exactly one win.
    let a = st.clone();
    let h1 = tokio::spawn(async move {
        app(a)
            .oneshot(jesse_request(Some("Bearer test-token"), body))
            .await
            .unwrap()
    });
    let b = st.clone();
    let h2 = tokio::spawn(async move {
        app(b)
            .oneshot(jesse_request(Some("Bearer test-token"), body))
            .await
            .unwrap()
    });
    let (r1, r2) = (h1.await.unwrap(), h2.await.unwrap());
    assert_eq!(r1.status(), StatusCode::ACCEPTED);
    assert_eq!(r2.status(), StatusCode::ACCEPTED);
    let b1: Value = serde_json::from_str(&body_string(r1).await).unwrap();
    let b2: Value = serde_json::from_str(&body_string(r2).await).unwrap();
    let id1 = b1["job_id"].as_str().unwrap();
    let id2 = b2["job_id"].as_str().unwrap();
    assert_eq!(
        id1, id2,
        "two concurrent duplicate POSTs must resolve to the SAME job id"
    );

    let done = wait_for_done(&st, id1).await;
    assert_eq!(done["response"], "deduped ok");
    assert_eq!(
        spawn_count(&counter),
        1,
        "two concurrent duplicate POSTs must spawn exactly one claude"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

#[tokio::test]
async fn dedup_against_a_completed_job_fetches_the_finished_result() {
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    // No sleep — the first turn finishes fast, so the duplicate lands on a DONE job.
    let fake = spawn_counting_claude(&counter, 0);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let body = r#"{"mode":"ask","text":"hi","request_id":"finished-key"}"#;
    let r1 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    let b1: Value = serde_json::from_str(&body_string(r1).await).unwrap();
    let id1 = b1["job_id"].as_str().unwrap().to_string();
    let done = wait_for_done(&st, &id1).await;
    assert_eq!(done["response"], "deduped ok");

    // Now re-POST the SAME request_id against the finished job.
    let r2 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    assert_eq!(r2.status(), StatusCode::ACCEPTED);
    let b2: Value = serde_json::from_str(&body_string(r2).await).unwrap();
    let id2 = b2["job_id"].as_str().unwrap().to_string();
    assert_eq!(
        id2, id1,
        "a completed job's request_id must still dedup to it"
    );
    // The returned id fetches the finished result immediately (first poll is satisfied).
    let refetch = result_status(&st, &id2).await;
    assert_eq!(refetch["status"], "done");
    assert_eq!(refetch["response"], "deduped ok");
    assert_eq!(
        spawn_count(&counter),
        1,
        "a dedup against a completed job must not spawn a second claude"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

#[tokio::test]
async fn absent_request_id_creates_a_distinct_job_each_time() {
    // Regression: with NO request_id, every POST is a fresh turn — two POSTs get two
    // different job ids and two spawns, byte-for-byte today's behavior.
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    let fake = spawn_counting_claude(&counter, 0);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    };
    let st = AppState::new(cfg);

    let body = r#"{"mode":"ask","text":"hi"}"#;
    let r1 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    let id1 = serde_json::from_str::<Value>(&body_string(r1).await).unwrap()["job_id"]
        .as_str()
        .unwrap()
        .to_string();
    let _ = wait_for_done(&st, &id1).await;
    let r2 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    let id2 = serde_json::from_str::<Value>(&body_string(r2).await).unwrap()["job_id"]
        .as_str()
        .unwrap()
        .to_string();
    let _ = wait_for_done(&st, &id2).await;

    assert_ne!(id1, id2, "no request_id → each POST is a distinct turn");
    assert_eq!(
        spawn_count(&counter),
        2,
        "two POSTs with no request_id must spawn two turns"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

#[tokio::test]
async fn invalid_request_id_is_400_json_and_spawns_nothing() {
    // A bridge whose fake claude would touch a marker if it EVER ran — an invalid
    // request_id must be rejected before any turn machinery.
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    let fake = spawn_counting_claude(&counter, 0);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    // Over-length (65 chars).
    let too_long = "a".repeat(65);
    let body_long = format!(r#"{{"mode":"ask","text":"hi","request_id":"{too_long}"}}"#);
    let r1 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), &body_long))
        .await
        .unwrap();
    assert_eq!(r1.status(), StatusCode::BAD_REQUEST);
    let e1: Value = serde_json::from_str(&body_string(r1).await).unwrap();
    assert!(
        e1["error"].as_str().unwrap().contains("64"),
        "the 400 body must be a one-line JSON error naming the length cap"
    );

    // Bad characters.
    let body_bad = r#"{"mode":"ask","text":"hi","request_id":"bad id!"}"#;
    let r2 = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body_bad))
        .await
        .unwrap();
    assert_eq!(r2.status(), StatusCode::BAD_REQUEST);
    let e2: Value = serde_json::from_str(&body_string(r2).await).unwrap();
    assert!(
        e2["error"].is_string(),
        "the bad-chars 400 must also carry a JSON error"
    );

    // Neither rejected POST spawned anything.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        spawn_count(&counter),
        0,
        "a rejected request_id must spawn no turn"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

// ===========================================================================
// Opt-in shadow comparison (JESSE_SHADOW_*)
// ===========================================================================

/// A shadow-armed config over a fake `claude` whose behavior BRANCHES on
/// `ANTHROPIC_BASE_URL` — set only on the contained shadow child (via
/// `apply_shadow_env`), never on the hosted turn — so one script drives both sides.
fn shadow_config(fake: &std::path::Path, log: &std::path::Path) -> Config {
    Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 20,
        shadow_backend: Some((
            "https://gw.example".to_string(),
            "gw-secret-token".to_string(),
            "fw-glm".to_string(),
        )),
        shadow_sample_pct: 100,
        shadow_log: log.to_string_lossy().into_owned(),
        ..test_config()
    }
}

async fn post_ask_and_wait_done(st: &AppState, text: &str) -> Value {
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            &format!(r#"{{"mode":"ask","text":"{text}"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let mut v = wait_for_status(st, &job_id, "done").await;
    v["job_id"] = Value::String(job_id);
    v
}

/// Poll the shadow log for the pair belonging to `turn_id`, up to ~4s.
fn read_pair(log: &std::path::Path, turn_id: &str) -> Option<ShadowPair> {
    let body = std::fs::read_to_string(log).ok()?;
    parse_shadow_pairs(&body)
        .into_iter()
        .find(|p| p.turn_id == turn_id)
}

#[tokio::test]
async fn shadow_disarmed_vs_armed_delivers_byte_for_byte_identical() {
    // GOLDEN: the delivered reply (text + session id) is identical whether shadow is
    // armed or not — arming shadow changes nothing on the production path.
    let script = "#!/bin/sh\n\
        if [ -n \"$ANTHROPIC_BASE_URL\" ]; then\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"shadow answer\",\"session_id\":\"s\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}'\n\
        else\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"the hosted answer\",\"session_id\":\"sess-1\"}'\n\
        fi\n";
    let fake = write_fake_claude(script);

    // Unarmed.
    let st_off = AppState::new(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 20,
        ..test_config()
    });
    let off = post_ask_and_wait_done(&st_off, "same question").await;

    // Armed (distinct log).
    let log =
        std::env::temp_dir().join(format!("jesse-shadow-golden-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let st_on = AppState::new(shadow_config(&fake, &log));
    let on = post_ask_and_wait_done(&st_on, "same question").await;

    assert_eq!(
        off["response"], on["response"],
        "delivered text must be identical"
    );
    assert_eq!(off["response"], "the hosted answer");
    assert_eq!(
        off["session_id"], on["session_id"],
        "delivered session id must be identical"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&log);
}

#[tokio::test]
async fn shadow_armed_mirrors_an_eligible_ask_and_logs_a_complete_pair() {
    let script = "#!/bin/sh\n\
        if [ -n \"$ANTHROPIC_BASE_URL\" ]; then\n\
          printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"shadow says hi\"}}}'\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"shadow says hi\",\"session_id\":\"s\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":80,\"cache_read_input_tokens\":40}}'\n\
        else\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"hosted answer text\",\"session_id\":\"sess-x\"}'\n\
        fi\n";
    let fake = write_fake_claude(script);
    let log = std::env::temp_dir().join(format!("jesse-shadow-pair-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let st = AppState::new(shadow_config(&fake, &log));

    let done = post_ask_and_wait_done(&st, "mirror me").await;
    assert_eq!(done["response"], "hosted answer text");
    let job_id = done["job_id"].as_str().unwrap().to_string();

    let log_ref = &log;
    let job_ref = job_id.as_str();
    let pair = wait_for(
        "an eligible ask to produce a shadow pair line",
        move || async move { read_pair(log_ref, job_ref) },
    )
    .await;
    assert_eq!(pair.outcome, "complete");
    // Hosted text is the delivered (pre-badge) answer, captured from the jobstore seam.
    assert_eq!(pair.hosted_text, "hosted answer text");
    assert_eq!(pair.shadow_text.as_deref(), Some("shadow says hi"));
    assert_eq!(pair.shadow_model, "fw-glm");
    let usage = pair
        .shadow_usage
        .expect("shadow usage captured from the result line");
    assert_eq!(usage.input_tokens, Some(1200));
    assert_eq!(usage.output_tokens, Some(80));
    assert!(
        !pair.write_attempt,
        "a read-only shadow child makes no write attempt"
    );
    // The delivered turn is untouched: the stored reply is still the hosted answer.
    let after = result_status(&st, &job_id).await;
    assert_eq!(after["response"], "hosted answer text");

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&log);
}

#[tokio::test]
async fn shadow_child_error_records_an_incomplete_pair_and_leaves_the_turn_intact() {
    // The shadow side returns a transport-class error envelope; the hosted turn
    // succeeds. The pair is recorded INCOMPLETE (no shadow text) and swallowed.
    let script = "#!/bin/sh\n\
        if [ -n \"$ANTHROPIC_BASE_URL\" ]; then\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":true,\"result\":\"upstream 500\",\"api_error_status\":500}'\n\
        else\n\
          printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"good hosted reply\",\"session_id\":\"sess-e\"}'\n\
        fi\n";
    let fake = write_fake_claude(script);
    let log = std::env::temp_dir().join(format!("jesse-shadow-err-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let st = AppState::new(shadow_config(&fake, &log));

    let done = post_ask_and_wait_done(&st, "mirror me too").await;
    assert_eq!(
        done["response"], "good hosted reply",
        "hosted turn unaffected by shadow failure"
    );
    let job_id = done["job_id"].as_str().unwrap().to_string();

    let log_ref = &log;
    let job_ref = job_id.as_str();
    let pair = wait_for(
        "a shadow error to still record an (incomplete) pair",
        move || async move { read_pair(log_ref, job_ref) },
    )
    .await;
    assert_eq!(pair.outcome, "error");
    assert!(
        pair.shadow_text.is_none(),
        "an errored shadow logs no answer"
    );
    assert!(pair.error.is_some());

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&log);
}

#[tokio::test]
async fn shadow_never_mirrors_a_tell() {
    // A Tell is never eligible: no pair is ever written even with shadow armed.
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"noted\",\"session_id\":\"sess-t\"}'\n";
    let fake = write_fake_claude(script);
    let log = std::env::temp_dir().join(format!("jesse-shadow-tell-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let st = AppState::new(shadow_config(&fake, &log));

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"tell","text":"remember milk"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    wait_for_status(&st, &job_id, "done").await;
    // Give any (erroneous) shadow task time to run, then assert the log is absent.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!log.exists(), "a Tell must never be mirrored");

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&log);
}

// ---- The global model switch: GET /jesse/models, POST /jesse/model,
//      POST /jesse/model/{id}/writes -----------------------------------------

/// A Config whose registry offers opus (ambient), an AVAILABLE glm-5.2 (hosted), and an
/// UNAVAILABLE `test-unarmed` — a SYNTHETIC id rather than a shipped model, so these tests
/// keep exercising the unconfigured branch no matter which real models are armed. They
/// exercise select / reject / writes over a realistic registry. Persisted to a temp state dir so a re-read AppState converges.
fn cfg_with_switch_registry(state_dir: &std::path::Path) -> Config {
    let registry = ModelRegistry {
        models: vec![
            RegistryModel {
                id: "opus".into(),
                label: "Claude Opus".into(),
                kind: ModelKind::Ambient,
                wire: Wire::default_for_kind(ModelKind::Ambient),
                backend: None,
                subagent_model: None,
                configured: true,
                level: Capability::Write,
                harness: CLAUDE_CODE_ID.to_string(),
                auth_scheme: None,
                quirks: DirectQuirks::default(),
                thinking: None,
                price: PriceDeck {
                    in_per_m: 5.0,
                    cached_per_m: 0.5,
                    out_per_m: 25.0,
                },
                health: HealthConfig::default(),
                vision: Vec::new(),
                vision_complementary: false,
            },
            RegistryModel {
                id: "glm-5.2".into(),
                label: "GLM 5.2".into(),
                kind: ModelKind::Hosted,
                wire: Wire::default_for_kind(ModelKind::Hosted),
                backend: Some((
                    "http://fireworks".into(),
                    "fw-tok".into(),
                    "glm-model".into(),
                )),
                subagent_model: Some("glm-model".into()),
                configured: true,
                level: Capability::Read,
                harness: CLAUDE_CODE_ID.to_string(),
                auth_scheme: None,
                quirks: DirectQuirks::default(),
                thinking: None,
                price: PriceDeck {
                    in_per_m: 1.4,
                    cached_per_m: 0.14,
                    out_per_m: 4.4,
                },
                health: HealthConfig::default(),
                vision: Vec::new(),
                vision_complementary: false,
            },
            RegistryModel {
                id: "test-unarmed".into(),
                label: "Unarmed Test Model".into(),
                kind: ModelKind::Hosted,
                wire: Wire::default_for_kind(ModelKind::Hosted),
                backend: None,
                subagent_model: None,
                configured: false,
                level: Capability::Read,
                harness: CLAUDE_CODE_ID.to_string(),
                auth_scheme: None,
                quirks: DirectQuirks::default(),
                thinking: None,
                price: PriceDeck::ZERO,
                health: HealthConfig::default(),
                vision: Vec::new(),
                vision_complementary: false,
            },
        ],
    };
    Config {
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        model_registry: registry,
        ..test_config()
    }
}

async fn body_value(resp: axum::response::Response) -> Value {
    serde_json::from_str(&body_string(resp).await).unwrap()
}

#[tokio::test]
async fn models_endpoint_requires_auth() {
    let st = test_state();
    let resp = app(st).oneshot(models_request(None)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn models_endpoint_lists_the_registry_and_active_selection() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st)
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_value(resp).await;
    assert_eq!(v["active"], "opus", "default active is opus");
    let models = v["models"].as_array().unwrap();
    assert_eq!(models.len(), 3);
    // opus is ambient + configured + healthy + available + writes-on.
    let opus = models.iter().find(|m| m["id"] == "opus").unwrap();
    assert_eq!(opus["kind"], "ambient");
    assert_eq!(opus["configured"], true);
    assert_eq!(opus["healthy"], true);
    assert_eq!(opus["available"], true);
    assert_eq!(opus["writes_allowed"], true);
    // glm is configured + (optimistically) healthy → available, but read-only by default.
    let glm = models.iter().find(|m| m["id"] == "glm-5.2").unwrap();
    assert_eq!(glm["kind"], "hosted");
    assert_eq!(glm["configured"], true);
    assert_eq!(
        glm["healthy"], true,
        "a configured model is seeded optimistically healthy"
    );
    assert_eq!(glm["available"], true);
    assert_eq!(glm["writes_allowed"], false);
    // the synthetic entry is present but UNCONFIGURED (no token) → not healthy, not available.
    let unarmed = models.iter().find(|m| m["id"] == "test-unarmed").unwrap();
    assert_eq!(unarmed["configured"], false);
    assert_eq!(unarmed["healthy"], false);
    assert_eq!(unarmed["available"], false);
    // No secret leaks to the client — ids, booleans, enums, and numbers only.
    let raw = v.to_string();
    assert!(
        !raw.contains("fw-tok"),
        "the token must never reach a client: {raw}"
    );
    assert!(
        !raw.contains("fireworks"),
        "the base url must never reach a client: {raw}"
    );
    assert!(
        !raw.contains("glm-model"),
        "the backend model id must never reach a client: {raw}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn set_model_on_an_unhealthy_configured_model_is_409_and_does_not_switch() {
    // Health gating (B3): a CONFIGURED model whose last probe FAILED is unhealthy, so it is
    // rejected with 409 and the active model is unchanged — the app must not switch onto a
    // model the bridge currently can't reach.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    // Mark glm unhealthy (a failed probe would do this in production).
    st.health.set(
        "glm-5.2",
        HealthStatus {
            healthy: false,
            checked_at_ms: 123,
            latency_ms: Some(3000),
            last_error_class: Some("timeout".into()),
        },
    );
    // The row now reports it configured-but-unhealthy → not available.
    let resp = app(st.clone())
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    let v = body_value(resp).await;
    let glm = v["models"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == "glm-5.2")
        .unwrap()
        .clone();
    assert_eq!(glm["configured"], true);
    assert_eq!(glm["healthy"], false);
    assert_eq!(glm["available"], false);
    assert_eq!(glm["latency_ms"], 3000);
    // And selection is rejected with 409, leaving the active model unchanged.
    let resp = app(st.clone())
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"glm-5.2"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    assert_eq!(
        st.models.active(),
        "opus",
        "an unhealthy selection must not take effect"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn set_model_accepts_a_healthy_configured_model() {
    // The positive half of the gate: a configured + healthy model IS accepted.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    // Seeded optimistic-healthy; make it explicit that a passing probe keeps it selectable.
    st.health.set(
        "glm-5.2",
        HealthStatus {
            healthy: true,
            checked_at_ms: 1,
            latency_ms: Some(40),
            last_error_class: None,
        },
    );
    let resp = app(st.clone())
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"glm-5.2"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(st.models.active(), "glm-5.2");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn set_model_switches_active_and_persists_across_a_restart() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st.clone())
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"glm-5.2"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_value(resp).await["active"], "glm-5.2");

    // A fresh AppState over the same state dir = the bridge restarting; it converges.
    let st2 = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st2)
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(
        body_value(resp).await["active"],
        "glm-5.2",
        "selection survives restart"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn set_model_unknown_id_is_400() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st)
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"no-such-model"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn set_model_unavailable_is_409_and_does_not_switch() {
    // An unavailable model (the synthetic unconfigured entry) cannot become active.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st.clone())
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"test-unarmed"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    // The active model is unchanged.
    assert_eq!(
        st.models.active(),
        "opus",
        "an unavailable selection must not take effect"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// THE MODELS-ENDPOINT SHAPE, pinned. Each entry gains exactly two fields — `level` and
/// `streams_text` — and keeps every field it had. A silently changed shape is a client
/// that renders the wrong thing, so the whole key set is asserted rather than the new
/// pair alone.
#[tokio::test]
async fn the_models_endpoint_entry_shape_is_pinned() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st)
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    let v = body_value(resp).await;
    let entry = v["models"].as_array().unwrap()[0]
        .as_object()
        .unwrap()
        .clone();
    let mut keys: Vec<&str> = entry.keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(
        keys,
        vec![
            "available",
            "configured",
            "healthy",
            "id",
            "kind",
            "label",
            "last_checked_ms",
            "latency_ms",
            "level",
            "streams_text",
            "vision",
            "wire",
            "writes_allowed",
        ],
        "the models entry shape changed — update the clients and the changelog"
    );
    // `wire` names the API surface, beside `kind`'s hosting arrangement. Every model in this
    // fixture is Anthropic-surface, which is what the kind-derived default gives them.
    for m in v["models"].as_array().unwrap() {
        assert!(
            ["messages", "chat", "responses"].contains(&m["wire"].as_str().unwrap()),
            "wire is one of the three surface names: {m}"
        );
    }
    // The two new fields carry the right types and values.
    for m in v["models"].as_array().unwrap() {
        assert!(
            ["basic", "read", "write"].contains(&m["level"].as_str().unwrap()),
            "level is one of the three capability labels: {m}"
        );
        assert!(
            m["streams_text"].is_boolean(),
            "streams_text is a boolean the client can key a spinner off: {m}"
        );
        // Every model registered today runs under Claude Code, which streams.
        assert_eq!(m["streams_text"], true);
    }
    // Unconfigured and unhealthy stay DISTINCT, exactly as before.
    let unarmed = v["models"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["configured"] == false);
    if let Some(u) = unarmed {
        assert_eq!(u["available"], false);
        assert_eq!(u["healthy"], false, "unconfigured is not 'unhealthy'");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// THE REMOVAL, asserted rather than described. `POST /jesse/model/{id}/writes` let a
/// device grant a model write access to the vault. It is gone: what a model may touch is
/// its `level`, which lives in the bridge config and is validated at startup against the
/// committed containment record. A control the phone had is a control the phone no longer
/// has, so the route must 404 rather than quietly accept and ignore.
#[tokio::test]
async fn the_per_model_writes_endpoint_is_gone() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    for (id, body) in [
        ("glm-5.2", r#"{"enabled":true}"#),
        ("opus", r#"{"enabled":false}"#),
    ] {
        let resp = app(st.clone())
            .oneshot(set_model_writes_request(
                Some("Bearer test-token"),
                id,
                body,
            ))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::NOT_FOUND,
            "the writes toggle must be gone, not merely inert, for {id}"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// …and a model's write permission now reads off its configured level, with no way for a
/// client to change it.
#[tokio::test]
async fn a_models_write_permission_comes_from_its_configured_level() {
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st)
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    let v = body_value(resp).await;
    let models = v["models"].as_array().unwrap().clone();
    let glm = models.iter().find(|m| m["id"] == "glm-5.2").unwrap();
    assert_eq!(glm["level"], "read", "a declared model defaults to Read");
    assert_eq!(glm["writes_allowed"], false, "…so it may not write");
    let opus = models.iter().find(|m| m["id"] == "opus").unwrap();
    assert_eq!(
        opus["level"], "write",
        "the ambient default is the built-in Write entry"
    );
    assert_eq!(opus["writes_allowed"], true);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Per-turn model selection (the request `model` field) -------------------
//
// A turn may name a `model` that backs ONLY that turn (retiring the global switch):
// it is validated exactly as `POST /jesse/model` (unknown → 400, unhealthy → 409),
// it badges the chosen model, it never mutates the stored global `active`, and an
// absent field falls back to the stored default (byte-for-byte today's behavior).

/// Drive one `POST /jesse` turn through `st` to completion and return its poll result.
/// Mirrors `run_turn_emitting`'s poll loop but over a caller-supplied AppState, so a test
/// can build its own switch registry + fake claude first.
async fn drive_turn_to_done(st: &AppState, req_json: &str) -> Value {
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), req_json))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED, "turn accepted");
    let job_id = body_value(resp).await["job_id"]
        .as_str()
        .unwrap()
        .to_string();
    wait_for_status(st, &job_id, "done").await
}

#[tokio::test]
async fn per_turn_model_badges_that_model_and_leaves_the_global_default_unchanged() {
    // A turn naming `glm-5.2` runs on glm and badges glm-5.2, while the stored `active`
    // stays `opus` — a per-turn selection never mutates the global default another device
    // reads from `GET /jesse/models`.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Answer from glm.\",\"session_id\":\"sess-glm\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        model_badge: true,
        timeout_secs: 30,
        ..cfg_with_switch_registry(&dir)
    };
    let st = AppState::new(cfg);

    let v = drive_turn_to_done(&st, r#"{"mode":"ask","text":"hi","model":"glm-5.2"}"#).await;
    let resp_text = v["response"].as_str().unwrap();
    assert!(
        resp_text.starts_with("Answer from glm."),
        "answer preserved: {resp_text:?}"
    );
    assert!(
        resp_text.contains("[glm-5.2"),
        "the badge names the per-turn model: {resp_text:?}"
    );
    assert_eq!(
        v["provenance"]["model"], "glm-5.2",
        "structured provenance names the per-turn model"
    );

    // The stored global default is untouched by the per-turn selection.
    let models = app(st.clone())
        .oneshot(models_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(
        body_value(models).await["active"],
        "opus",
        "a per-turn selection must not mutate the stored global default"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_turn_with_no_model_uses_the_stored_default() {
    // The fallback: with no `model` field the turn uses the stored `active`. Set the stored
    // default to glm-5.2 first, then a fieldless turn badges glm — proving absence resolves
    // to the stored default (and, for a plain opus deploy, byte-for-byte today's behavior).
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let script = "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"Default-backed answer.\",\"session_id\":\"sess-def\"}'\n";
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        model_badge: true,
        timeout_secs: 30,
        ..cfg_with_switch_registry(&dir)
    };
    let st = AppState::new(cfg);

    // Move the stored default onto glm-5.2 (the legacy global switch still works server-side
    // as the fallback default).
    let set = app(st.clone())
        .oneshot(set_model_request(
            Some("Bearer test-token"),
            r#"{"id":"glm-5.2"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(set.status(), StatusCode::OK);

    let v = drive_turn_to_done(&st, r#"{"mode":"ask","text":"hi"}"#).await;
    let resp_text = v["response"].as_str().unwrap();
    assert!(
        resp_text.contains("[glm-5.2"),
        "a fieldless turn falls back to the stored default (glm-5.2): {resp_text:?}"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn per_turn_unhealthy_model_is_409_and_spawns_nothing() {
    // An unhealthy per-turn selection is rejected with 409 BEFORE any turn starts. The fake
    // claude writes a sentinel file if it ever runs; the 409 path must leave it absent.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let sentinel = std::env::temp_dir().join(format!("jesse-spawn-sentinel-{}", random_hex()));
    let script = format!(
        "#!/bin/sh\ntouch '{}'\nprintf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"SHOULD_NOT_RUN\",\"session_id\":\"s\"}}'\n",
        sentinel.to_string_lossy()
    );
    let fake = write_fake_claude(&script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..cfg_with_switch_registry(&dir)
    };
    let st = AppState::new(cfg);
    // Mark glm unhealthy (a failed probe would do this in production).
    st.health.set(
        "glm-5.2",
        HealthStatus {
            healthy: false,
            checked_at_ms: 5,
            latency_ms: Some(3000),
            last_error_class: Some("timeout".into()),
        },
    );

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"hi","model":"glm-5.2"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CONFLICT,
        "unhealthy selection → 409"
    );
    // Give any (erroneously) spawned child a beat to touch the sentinel, then prove it never ran.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        !sentinel.exists(),
        "a rejected per-turn selection must spawn no claude child"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&sentinel);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn per_turn_unknown_model_is_400() {
    // An unknown per-turn id is a 400, exactly as `POST /jesse/model`.
    let dir = std::env::temp_dir().join(format!("jesse-model-it-{}", random_hex()));
    let st = AppState::new(cfg_with_switch_registry(&dir));
    let resp = app(st)
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"hi","model":"no-such-model"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "unknown model → 400"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Vision helper layer (mock /v1/messages backend) ----------------------
//
// These bind a REAL loopback socket (reqwest needs a URL) serving a canned Anthropic
// response, so the full helper call path — base64 image block → POST → parse — is
// exercised deterministically with no network and no live VL model.

use axum::routing::post as axum_post;
use axum::Json as AxumJson;
use axum::Router as AxumRouter;

/// A mock Anthropic `/v1/messages` helper: echoes the received image media type + whether
/// image data was present into the transcription, PROVING the encoder sent a real image
/// block, and returns a fixed usage vector.
async fn mock_vision_helper(AxumJson(body): AxumJson<Value>) -> AxumJson<Value> {
    let media = body
        .pointer("/messages/0/content/0/source/media_type")
        .and_then(|v| v.as_str())
        .unwrap_or("NONE")
        .to_string();
    let has_data = body
        .pointer("/messages/0/content/0/source/data")
        .and_then(|v| v.as_str())
        .map(|s| !s.is_empty())
        .unwrap_or(false);
    let has_instruction = body
        .pointer("/messages/0/content/1/text")
        .and_then(|v| v.as_str())
        .map(|s| !s.is_empty())
        .unwrap_or(false);
    AxumJson(serde_json::json!({
        "content": [{
            "type": "text",
            "text": format!("MOCK TRANSCRIPT media={media} data_present={has_data} instruction_present={has_instruction} GROUNDTRUTH-TOKEN"),
        }],
        "usage": { "input_tokens": 11, "output_tokens": 7 },
    }))
}

async fn start_mock_helper() -> String {
    let app = AxumRouter::new().route("/v1/messages", axum_post(mock_vision_helper));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{addr}")
}

fn chart_png_fixture() -> Vec<u8> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../eval/vision/fixtures/chart.png"
    );
    std::fs::read(path).expect("committed chart.png fixture")
}

#[tokio::test]
async fn vision_transcribes_an_image_over_a_mock_helper() {
    let base = start_mock_helper().await;
    let cfg = test_config();
    let partner = ResolvedPartner {
        id: "mock".into(),
        role: VisionRole::General,
        base_url: base,
        token: "t".into(),
        model: "m".into(),
        price: PriceDeck::ZERO,
    };
    let input = VisionInput {
        source: "chart.png".into(),
        ext: "png".into(),
        bytes: chart_png_fixture(),
    };
    let client = vision_client();
    let results = transcribe_input(&client, &cfg, &partner, &input).await;
    assert_eq!(results.len(), 1, "one image → one result");
    let r = &results[0];
    assert!(r.error.is_none(), "no error: {:?}", r.error);
    assert!(
        r.text.contains("media=image/png") && r.text.contains("data_present=true"),
        "encoder sent a real base64 image/png block: {}",
        r.text
    );
    assert!(
        r.text.contains("instruction_present=true"),
        "instruction sent"
    );
    assert_eq!(r.input_tokens, 11);
    assert_eq!(r.output_tokens, 7);
}

#[tokio::test]
async fn preprocess_pairs_and_frames_a_faithful_view() {
    let base = start_mock_helper().await;
    // A registry with the mock helper (configured) and a text model paired to it.
    let helper = RegistryModel {
        id: "mock".into(),
        label: "Mock VL".into(),
        kind: ModelKind::Hosted,
        wire: Wire::default_for_kind(ModelKind::Hosted),
        backend: Some((base, "t".into(), "m".into())),
        subagent_model: Some("m".into()),
        configured: true,
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        auth_scheme: None,
        quirks: DirectQuirks::default(),
        thinking: None,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
        vision: Vec::new(),
        vision_complementary: false,
    };
    let text = RegistryModel {
        id: "glm".into(),
        label: "GLM".into(),
        kind: ModelKind::Hosted,
        wire: Wire::default_for_kind(ModelKind::Hosted),
        backend: Some(("http://text".into(), "tt".into(), "tm".into())),
        subagent_model: Some("tm".into()),
        configured: true,
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        auth_scheme: None,
        quirks: DirectQuirks::default(),
        thinking: None,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
        vision: vec![VisionPartner {
            id: "mock".into(),
            role: VisionRole::General,
        }],
        vision_complementary: false,
    };
    let cfg = Config {
        model_registry: ModelRegistry {
            models: vec![helper, text],
        },
        ..test_config()
    };
    // The text model reports vision ENABLED (a resolvable partner).
    let glm = cfg.model_registry.get("glm").unwrap();
    assert!(
        cfg.model_registry.vision_enabled(glm),
        "paired + resolvable → enabled"
    );

    let active = ActiveModel {
        id: "glm".into(),
        kind: ModelKind::Hosted,
        env: Some(("http://text".into(), "tt".into(), "tm".into())),
        subagent_model: Some("tm".into()),
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        price: PriceDeck::ZERO,
        vision: vec![VisionPartner {
            id: "mock".into(),
            role: VisionRole::General,
        }],
        vision_complementary: false,
    };
    let inputs = vec![VisionInput {
        source: "chart.png".into(),
        ext: "png".into(),
        bytes: chart_png_fixture(),
    }];
    let outcome = jesse_bridge::preprocess(&cfg, &active, &inputs).await;
    assert_eq!(outcome.views.len(), 1);
    assert!(outcome.views[0].error.is_none());
    assert!(outcome.views[0].text.contains("GROUNDTRUTH-TOKEN"));
    assert_eq!(outcome.views[0].via, "mock");
    assert_eq!(outcome.audit.len(), 1);
    assert!(outcome.audit[0].ok);
    assert_eq!(outcome.audit[0].output_tokens, 7);

    let block = frame_views(&outcome.views);
    assert!(block.contains(VISION_HEADER));
    assert!(block.contains("<attachment_view index=\"1\""));
    assert!(block.contains("GROUNDTRUTH-TOKEN"));
    assert_eq!(
        block.matches("<attachment_view ").count(),
        block.matches("</attachment_view>").count(),
        "well-formed frames"
    );
}

#[tokio::test]
async fn unpaired_model_reports_no_vision() {
    // A configured text model with NO partners reports vision disabled — the capability
    // rule: unpaired == no-vision, surfaced, never a silent half-state.
    let text = RegistryModel {
        id: "glm".into(),
        label: "GLM".into(),
        kind: ModelKind::Hosted,
        wire: Wire::default_for_kind(ModelKind::Hosted),
        backend: Some(("http://text".into(), "tt".into(), "tm".into())),
        subagent_model: Some("tm".into()),
        configured: true,
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        auth_scheme: None,
        quirks: DirectQuirks::default(),
        thinking: None,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
        vision: Vec::new(),
        vision_complementary: false,
    };
    let registry = ModelRegistry { models: vec![text] };
    let glm = registry.get("glm").unwrap();
    assert!(!registry.vision_enabled(glm), "no partners → no vision");

    // And a model paired to a MISSING helper is also no-vision (paired but broken).
    let broken = RegistryModel {
        vision: vec![VisionPartner {
            id: "ghost".into(),
            role: VisionRole::Any,
        }],
        ..registry.get("glm").unwrap().clone()
    };
    let registry2 = ModelRegistry {
        models: vec![broken],
    };
    assert!(
        !registry2.vision_enabled(registry2.get("glm").unwrap()),
        "paired to an unregistered helper → still no vision"
    );
}

/// The full PDF path end to end: rasterize → one PNG per page → image block → mock helper
/// → one per-page view. macOS-gated because the rasterizer is macOS's own renderer and the
/// bridge's CI job is Linux; it needs NO environment variable, which is the difference from
/// the pdfium version of this test — that one was gated on `JESSE_PDFIUM_LIB` and so never
/// actually ran, anywhere.
#[tokio::test]
#[cfg(target_os = "macos")]
async fn vision_rasterizes_and_transcribes_every_page_of_a_pdf() {
    let base = start_mock_helper().await;
    let cfg = test_config();
    let partner = ResolvedPartner {
        id: "mock".into(),
        role: VisionRole::Doc,
        base_url: base,
        token: "t".into(),
        model: "m".into(),
        price: PriceDeck::ZERO,
    };
    let pdf = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../eval/vision/fixtures/multipage.pdf"
    ))
    .unwrap();
    let input = VisionInput {
        source: "multipage.pdf".into(),
        ext: "pdf".into(),
        bytes: pdf,
    };
    let client = vision_client();
    let results = transcribe_input(&client, &cfg, &partner, &input).await;
    assert_eq!(results.len(), 4, "a four-page PDF → four page results");
    for (i, r) in results.iter().enumerate() {
        assert_eq!(r.page_no, Some(i + 1));
        assert_eq!(r.total_pages, Some(4));
        assert!(!r.truncated);
        assert!(r.error.is_none(), "page {}: {:?}", i + 1, r.error);
        assert!(
            r.text.contains("media=image/png"),
            "page {} sent as PNG",
            i + 1
        );
    }
}

/// THE VISION LAYER IS KEYED TO THE MODEL, NOT TO THE HARNESS — asserted, not assumed.
///
/// The helper layer is reached on the strength of the active model's vision partners
/// alone (`attachment_route(had_attachments, vision_on)` names no harness), so a text
/// model paired with a helper gets identical PDF and HEIC handling whether its child would
/// have been a Claude Code or a Codex process. This runs the SAME multi-page PDF and the
/// SAME HEIC photo through `preprocess` twice, changing only `harness`, and requires the
/// framed blocks to be byte-identical. It is what stops a future per-harness attachment
/// branch from landing quietly: the moment one exists, these two diverge.
#[tokio::test]
#[cfg(target_os = "macos")]
async fn the_vision_path_is_identical_on_both_harnesses() {
    let base = start_mock_helper().await;
    let partner = VisionPartner {
        id: "mock".into(),
        role: VisionRole::Any,
    };
    let helper = RegistryModel {
        id: "mock".into(),
        label: "Mock VL".into(),
        kind: ModelKind::Hosted,
        wire: Wire::default_for_kind(ModelKind::Hosted),
        backend: Some((base, "t".into(), "m".into())),
        subagent_model: Some("m".into()),
        configured: true,
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        auth_scheme: None,
        quirks: DirectQuirks::default(),
        thinking: None,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
        vision: Vec::new(),
        vision_complementary: false,
    };
    let cfg = Config {
        model_registry: ModelRegistry {
            models: vec![helper],
        },
        ..test_config()
    };

    // A four-page PDF and a real HEIC photo, in one turn.
    let dir = std::env::temp_dir().join(format!("jesse-xharness-{}", random_hex()));
    std::fs::create_dir_all(&dir).unwrap();
    let heic = dir.join("photo.heic");
    let ok = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "heic"])
        .arg(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../eval/vision/fixtures/chart.png"
        ))
        .arg("--out")
        .arg(&heic)
        .output()
        .expect("run sips");
    assert!(ok.status.success(), "sips could not write a HEIC fixture");
    let inputs = vec![
        VisionInput {
            source: "multipage.pdf".into(),
            ext: "pdf".into(),
            bytes: std::fs::read(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../eval/vision/fixtures/multipage.pdf"
            ))
            .unwrap(),
        },
        VisionInput {
            source: "IMG_0001.HEIC".into(),
            ext: "heic".into(),
            bytes: std::fs::read(&heic).unwrap(),
        },
    ];
    let _ = std::fs::remove_dir_all(&dir);

    let active_on = |harness: &str| ActiveModel {
        id: "glm".into(),
        kind: ModelKind::Hosted,
        env: Some(("http://text".into(), "tt".into(), "tm".into())),
        subagent_model: Some("tm".into()),
        level: Capability::Read,
        harness: harness.to_string(),
        price: PriceDeck::ZERO,
        vision: vec![partner.clone()],
        vision_complementary: false,
    };

    let cc = jesse_bridge::preprocess(&cfg, &active_on(CLAUDE_CODE_ID), &inputs).await;
    let codex = jesse_bridge::preprocess(&cfg, &active_on(CODEX_ID), &inputs).await;

    // Five views either way: four PDF pages plus the photo, none of them an error.
    assert_eq!(cc.views.len(), 5, "four PDF pages + one photo");
    assert!(
        cc.views.iter().all(|v| v.error.is_none()),
        "{:?}",
        cc.views.iter().map(|v| &v.error).collect::<Vec<_>>()
    );
    assert_eq!(codex.views.len(), cc.views.len());
    assert_eq!(
        frame_views(&codex.views),
        frame_views(&cc.views),
        "the two harnesses must see the same attachment views"
    );
}

/// A HEIC photo reaches the helper as PNG rather than being refused. Every iPhone photo is
/// HEIC and the Anthropic image surface does not take it, so before the transcode this was
/// an error view for the single most ordinary upload the composer can produce.
#[tokio::test]
#[cfg(target_os = "macos")]
async fn vision_transcodes_a_heic_photo_and_sends_it_as_png() {
    let base = start_mock_helper().await;
    let cfg = test_config();
    let partner = ResolvedPartner {
        id: "mock".into(),
        role: VisionRole::General,
        base_url: base,
        token: "t".into(),
        model: "m".into(),
        price: PriceDeck::ZERO,
    };

    // A genuine HEIF-encoded file, made with the same `sips` that reads one back.
    let dir = std::env::temp_dir().join(format!("jesse-heic-it-{}", random_hex()));
    std::fs::create_dir_all(&dir).unwrap();
    let png_in = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../eval/vision/fixtures/chart.png"
    );
    let heic = dir.join("photo.heic");
    let ok = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "heic"])
        .arg(png_in)
        .arg("--out")
        .arg(&heic)
        .output()
        .expect("run sips");
    assert!(ok.status.success(), "sips could not write a HEIC fixture");

    let input = VisionInput {
        source: "IMG_0001.HEIC".into(),
        ext: "heic".into(),
        bytes: std::fs::read(&heic).unwrap(),
    };
    let client = vision_client();
    let results = transcribe_input(&client, &cfg, &partner, &input).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(results.len(), 1, "one image → one result");
    assert!(results[0].error.is_none(), "{:?}", results[0].error);
    assert!(
        results[0].text.contains("media=image/png"),
        "the photo reached the helper as PNG, got: {}",
        results[0].text
    );
}

// ---- The conversation registry ----------------------------------------------
//
// Every test below asserts a property of the identity model, not a smoke path.
// The headline is `in_flight_transcript_produces_no_row_then_binds_on_terminal`:
// without the in-flight claim table the design fails at exactly the problem it
// exists to solve.

/// A throwaway HOME + vault whose escaped projects dir exists, plus the dir path.
/// Nothing global is mutated: the bridge reads HOME from `cfg.home`.
fn conv_fixture() -> (std::path::PathBuf, String, std::path::PathBuf) {
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    // A REAL directory: the tests below spawn a fake claude, and the child's cwd is
    // the vault, so a nonexistent path would fail the spawn rather than the assertion.
    let vault_dir = std::env::temp_dir().join(format!("jesse-vault-{}", random_hex()));
    std::fs::create_dir_all(&vault_dir).unwrap();
    let vault = vault_dir.to_string_lossy().into_owned();
    let proj = home
        .join(".claude")
        .join("projects")
        .join(escape_project_path(&vault));
    std::fs::create_dir_all(&proj).unwrap();
    (home, vault, proj)
}

fn conv_state(home: &std::path::Path, vault: &str) -> AppState {
    AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.to_string(),
        state_dir: None,
        ..test_config()
    })
}

/// A minimal one-user-turn transcript.
fn write_transcript(proj: &std::path::Path, stem: &str, question: &str) {
    std::fs::write(
        proj.join(format!("{stem}.jsonl")),
        format!("{{\"type\":\"user\",\"message\":{{\"content\":\"{question}\"}}}}\n"),
    )
    .unwrap();
}

/// Make an on-disk transcript one the bridge OWNS, the way a real turn does: register a
/// conversation and bind the session to it.
///
/// Needed because the bridge no longer adopts transcripts it finds in a projects dir —
/// that directory is shared with every other `claude` run against the same cwd, so a
/// transcript with no record is deliberately not the bridge's. Tests that want a
/// pre-existing conversation must say so. The deterministic v5 id keeps these fixtures
/// readable and matches what the old adoption path minted.
fn own_transcript(st: &AppState, stem: &str) -> String {
    let cid = orphan_conversation_id(stem);
    st.conversations.register(&cid, None, 0);
    st.conversations.bind_session(&cid, stem);
    cid
}

/// Set a file's mtime to exactly `secs` since the unix epoch, so `last_modified`
/// and the `?since=` filter can be asserted against known values.
fn set_mtime_secs(path: &std::path::Path, secs: u64) {
    let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    f.set_modified(std::time::UNIX_EPOCH + Duration::from_secs(secs))
        .unwrap();
}

/// A fake claude that returns the given session id after an optional sleep, and
/// (like the real CLI, which writes its transcript at spawn rather than at
/// completion) creates that transcript file BEFORE it answers.
fn claude_writing_transcript(
    proj: &std::path::Path,
    sid: &str,
    sleep_secs: u32,
) -> std::path::PathBuf {
    // Mirrors the real CLI's ordering, verified against claude 2.1.220: the
    // `system`/`init` line naming the session comes out FIRST, before the transcript
    // exists, and the terminal `result` line repeats the same id.
    let script = format!(
        "#!/bin/sh\n\
         printf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"{sid}\",\"cwd\":\"/v\"}}'\n\
         printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"turn text\"}}}}' > '{}/{sid}.jsonl'\n\
         sleep {sleep_secs}\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"{sid}\"}}'\n",
        proj.display()
    );
    write_fake_claude(&script)
}

async fn post_turn(st: &AppState, body: &str) -> Value {
    let resp = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED, "turn accepted");
    serde_json::from_str(&body_string(resp).await).unwrap()
}

async fn conversation_rows(st: &AppState) -> Vec<Value> {
    let resp = app(st.clone())
        .oneshot(conversations_request(Some("Bearer test-token"), None, None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    body["conversations"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

const CID_A: &str = "11111111-2222-4333-8444-555555555555";
const CID_B: &str = "66666666-7777-4888-8999-aaaaaaaaaaaa";

#[tokio::test]
async fn post_without_a_conversation_id_mints_a_canonical_one() {
    let fake = write_fake_claude(
        "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s1\"}'\n",
    );
    let st = AppState::new(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    });
    let body = post_turn(&st, r#"{"mode":"ask","text":"hi"}"#).await;
    let cid = body["conversation_id"]
        .as_str()
        .expect("the 202 names a conversation");
    assert!(
        validate_conversation_id(cid).is_ok(),
        "the minted id is a canonical lowercase UUID: {cid}"
    );
    assert!(st.conversations.get(cid).is_some(), "and it is registered");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn post_with_a_conversation_id_echoes_it_and_creates_one_record() {
    let fake = write_fake_claude(
        "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s1\"}'\n",
    );
    let st = AppState::new(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    });
    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    assert_eq!(
        body["conversation_id"], CID_A,
        "the client's id is echoed exactly"
    );
    assert_eq!(st.conversations.len(), 1, "exactly one record");
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn two_turns_on_one_conversation_create_one_record_and_two_jobs() {
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    let fake = spawn_counting_claude(&counter, 0);
    let st = AppState::new(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    });
    let first = post_turn(
        &st,
        &format!(
            r#"{{"mode":"ask","text":"one","conversation_id":"{CID_A}","request_id":"rid-one"}}"#
        ),
    )
    .await;
    wait_for_done(&st, first["job_id"].as_str().unwrap()).await;
    let second = post_turn(
        &st,
        &format!(
            r#"{{"mode":"ask","text":"two","conversation_id":"{CID_A}","request_id":"rid-two"}}"#
        ),
    )
    .await;
    wait_for_done(&st, second["job_id"].as_str().unwrap()).await;

    assert_ne!(first["job_id"], second["job_id"], "two distinct jobs");
    assert_eq!(first["conversation_id"], CID_A);
    assert_eq!(second["conversation_id"], CID_A);
    assert_eq!(
        st.conversations.len(),
        1,
        "registration is idempotent: one conversation record"
    );
    let _ = std::fs::remove_file(&counter);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn a_deduped_repost_returns_the_same_job_and_the_same_conversation() {
    let counter = counter_path();
    let _ = std::fs::remove_file(&counter);
    // Sleeps, so the job is still live when the duplicate POST lands.
    let fake = spawn_counting_claude(&counter, 2);
    let st = AppState::new(Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });
    let body = format!(
        r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}","request_id":"rid-dup"}}"#
    );
    let first = post_turn(&st, &body).await;
    let again = post_turn(&st, &body).await;
    assert_eq!(
        first["job_id"], again["job_id"],
        "the same job is handed back"
    );
    assert_eq!(
        again["conversation_id"], CID_A,
        "a dedup hit still carries the resolved conversation"
    );
    // The 202 returns before the detached task spawns the child, so wait for the first
    // spawn to land before asserting there was only ever one.
    let counter_ref = &counter;
    wait_for("the first turn to spawn its child", move || async move {
        (spawn_count(counter_ref) >= 1).then_some(())
    })
    .await;
    assert_eq!(spawn_count(&counter), 1, "and only one turn ever spawned");
    let _ = std::fs::remove_file(&counter);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn a_malformed_conversation_id_is_a_400_with_a_json_error() {
    let st = test_state();
    for bad in [
        "11111111-2222-4333-8444-55555555555",   // one hex short
        "11111111222243338444555555555555",      // unhyphenated
        "11111111-2222-4333-8444-555555555555 ", // trailing space
        "AAAAAAAA-2222-4333-8444-555555555555",  // uppercase
        "../x",
        "",
    ] {
        let body = serde_json::to_string(&serde_json::json!({
            "mode": "ask", "text": "hi", "conversation_id": bad,
        }))
        .unwrap();
        let resp = app(st.clone())
            .oneshot(jesse_request(Some("Bearer test-token"), &body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "rejected: {bad:?}");
        let v: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        assert!(
            v["error"].as_str().is_some_and(|e| !e.is_empty()),
            "a one-line JSON error body: {v}"
        );
    }
    assert!(
        st.conversations.is_empty(),
        "a rejected id registers nothing"
    );
}

#[tokio::test]
async fn a_reply_with_a_different_session_id_appends_an_alias_not_a_new_row() {
    // The fork path. The client asks to continue `sess-old`; the reply comes back
    // naming `sess-new`. Both must belong to ONE conversation, and the list must
    // still show exactly one row.
    let (home, vault, proj) = conv_fixture();
    let fake = claude_writing_transcript(&proj, "sess-new", 0);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        ..test_config()
    });
    // The client already holds this conversation and knows `sess-old` belongs to it
    // (that is how it learned the id in the first place, from the list's `session_ids`),
    // so bind it up front — then the transcript lands under an id the conversation
    // already owns, which is the ordering a real turn has.
    st.conversations.register(CID_A, Some("phone"), 1_000);
    st.conversations.bind_session(CID_A, "sess-old");
    write_transcript(&proj, "sess-old", "the original question");
    assert_eq!(
        st.conversations
            .conversation_for_session("sess-old")
            .as_deref(),
        Some(CID_A)
    );
    let body = post_turn(
        &st,
        &format!(
            r#"{{"mode":"ask","text":"follow up","conversation_id":"{CID_A}","session_id":"sess-old"}}"#
        ),
    )
    .await;
    wait_for_done(&st, body["job_id"].as_str().unwrap()).await;

    let rec = st
        .conversations
        .get(CID_A)
        .expect("the conversation exists");
    assert_eq!(
        rec.session_ids,
        vec!["sess-old".to_string(), "sess-new".to_string()],
        "the fork APPENDS an alias, oldest first"
    );
    let rows = conversation_rows(&st).await;
    assert_eq!(
        rows.len(),
        1,
        "still exactly one conversation row: {rows:?}"
    );
    assert_eq!(rows[0]["conversation_id"], CID_A);
    assert_eq!(rows[0]["session_id"], "sess-new", "the CURRENT session");
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn binding_happens_with_context_carry_disabled() {
    // Conversation identity must never depend on a prompt feature flag. The fixture
    // already has `context_carry: false`, which is exactly the point: the same alias
    // binding as the test above must still hold.
    let (home, vault, proj) = conv_fixture();
    let fake = claude_writing_transcript(&proj, "sess-carryoff", 0);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        context_carry: false,
        ..test_config()
    });
    assert!(!st.cfg.context_carry, "the flag really is off");
    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    wait_for_done(&st, body["job_id"].as_str().unwrap()).await;
    assert_eq!(
        st.conversations.current_session(CID_A).as_deref(),
        Some("sess-carryoff"),
        "the reply's session bound even with JESSE_CONTEXT_CARRY off"
    );
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn two_bound_transcripts_yield_one_row_with_the_oldest_snippet_and_newest_mtime() {
    let (home, vault, proj) = conv_fixture();
    // The conversation owns both segments from the start. (Previously these were written
    // first, orphan-adopted at startup, and STOLEN back by `bind_session` — a steal that
    // no longer happens, and never belonged in a fixture whose subject is the list.)
    let st = conv_state(&home, &vault);
    st.conversations.register(CID_A, Some("phone"), 1_000);
    st.conversations.bind_session(CID_A, "seg-a");
    st.conversations.bind_session(CID_A, "seg-b");
    write_transcript(&proj, "seg-a", "the first question");
    write_transcript(&proj, "seg-b", "a later question");
    set_mtime_secs(&proj.join("seg-a.jsonl"), 1_000);
    set_mtime_secs(&proj.join("seg-b.jsonl"), 5_000);

    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1, "one row for two transcripts: {rows:?}");
    assert_eq!(
        rows[0]["first_message"], "the first question",
        "the snippet comes from the OLDEST segment, so a fork never changes the title"
    );
    assert_eq!(
        rows[0]["last_modified"].as_u64(),
        Some(5_000),
        "last_modified is the MAX mtime across segments"
    );
    assert_eq!(
        rows[0]["session_ids"].as_array().unwrap().len(),
        2,
        "the full alias list is exposed so a client binds its history once"
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn a_foreign_transcript_is_never_adopted_and_is_left_untouched() {
    // The defect this replaces: a projects dir is keyed only on the cwd, so a desktop
    // Claude Code run against the same vault wrote here and the bridge adopted it into a
    // conversation. On the deploy that surfaced this, 731 of 831 records were foreign
    // transcripts. A transcript with no record is now left entirely alone.
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-foreign", "a question typed at a terminal");
    let path = proj.join("sess-foreign.jsonl");
    let before = std::fs::read(&path).unwrap();
    let mtime_before = std::fs::metadata(&path).unwrap().modified().unwrap();

    let st = conv_state(&home, &vault);
    assert!(
        conversation_rows(&st).await.is_empty(),
        "a foreign transcript produces no conversation row"
    );
    assert!(st.conversations.is_empty(), "and no record");
    assert_eq!(
        st.conversations.conversation_for_session("sess-foreign"),
        None
    );

    // Listing again must not change that, and must not touch the file either way.
    assert!(conversation_rows(&st).await.is_empty());
    assert_eq!(std::fs::read(&path).unwrap(), before, "byte-identical");
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        mtime_before,
        "the bridge never writes into a transcript it did not create"
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn a_transcript_the_bridge_started_still_round_trips() {
    // The other side of the contract: ownership comes from the store, so a session the
    // bridge bound lists normally with its deterministic id.
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-ours", "an old question");
    let st = conv_state(&home, &vault);
    let cid = own_transcript(&st, "sess-ours");

    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["conversation_id"], cid);
    assert_eq!(rows[0]["session_id"], "sess-ours");
    assert_eq!(rows[0]["first_message"], "an old question");
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn a_projects_dir_full_of_foreign_stems_adopts_nothing_at_startup() {
    // The startup sweep is what bulk-adopted 708 transcripts in one go. It is gone: a
    // directory full of foreign stems must leave the registry empty.
    let (home, vault, proj) = conv_fixture();
    for i in 0..25 {
        write_transcript(&proj, &format!("sess-foreign-{i}"), "not ours");
    }
    let st = conv_state(&home, &vault);
    assert!(
        st.conversations.is_empty(),
        "the startup scan adopts nothing"
    );
    assert!(conversation_rows(&st).await.is_empty());
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn title_mint_transcripts_are_excluded_from_the_list_and_404_on_hydrate() {
    let (home, vault, proj) = conv_fixture();
    std::fs::write(
        proj.join("mint.jsonl"),
        format!(
            "{{\"type\":\"user\",\"message\":{{\"content\":{}}}}}\n",
            serde_json::to_string(&build_title_prompt("a digest")).unwrap()
        ),
    )
    .unwrap();
    write_transcript(&proj, "sess-real", "a real question");
    let st = conv_state(&home, &vault);
    own_transcript(&st, "sess-real");

    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1, "the mint transcript is not a conversation");
    assert_eq!(rows[0]["session_id"], "sess-real");
    assert_eq!(
        st.conversations.conversation_for_session("mint"),
        None,
        "and it was never even registered"
    );
    // Its would-be deterministic id is unknown, so hydrating it is a 404.
    let resp = app(st.clone())
        .oneshot(conversation_hydrate_request(
            Some("Bearer test-token"),
            &orphan_conversation_id("mint"),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn conversations_list_honors_etag_304_and_since() {
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "old", "old q");
    write_transcript(&proj, "new", "new q");
    let st = conv_state(&home, &vault);
    own_transcript(&st, "old");
    own_transcript(&st, "new");
    set_mtime_secs(&proj.join("old.jsonl"), 1_000);
    set_mtime_secs(&proj.join("new.jsonl"), 3_000);

    let resp = app(st.clone())
        .oneshot(conversations_request(Some("Bearer test-token"), None, None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let etag = resp
        .headers()
        .get("etag")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(
        etag.starts_with('"') && !etag.starts_with("W/"),
        "strong ETag"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let ids: Vec<&str> = body["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["session_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["new", "old"], "newest first");

    // The same ETag conditionally: 304 with the ETag and an empty body.
    let resp = app(st.clone())
        .oneshot(conversations_request(
            Some("Bearer test-token"),
            None,
            Some(&etag),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_MODIFIED);
    assert_eq!(resp.headers().get("etag").unwrap().to_str().unwrap(), etag);
    assert!(body_string(resp).await.is_empty(), "304 has an empty body");
    // A `*` wildcard matches too.
    let resp = app(st.clone())
        .oneshot(conversations_request(
            Some("Bearer test-token"),
            None,
            Some("*"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_MODIFIED);

    // ?since is strictly greater-than.
    let resp = app(st.clone())
        .oneshot(conversations_request(
            Some("Bearer test-token"),
            Some(1_000),
            None,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let ids: Vec<&str> = body["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["session_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["new"]);
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn conversation_delete_removes_every_transcript_tombstones_and_is_idempotent() {
    let (home, vault, proj) = conv_fixture();
    let st = conv_state(&home, &vault);
    st.conversations.register(CID_A, Some("phone"), 1_000);
    st.conversations.bind_session(CID_A, "seg-a");
    st.conversations.bind_session(CID_A, "seg-b");
    st.titles.set(CID_A, "Doomed");
    // `keep` belongs to a second conversation, so it survives the delete AND still lists.
    own_transcript(&st, "keep");
    // Written after every binding, which is the ordering a real turn has.
    write_transcript(&proj, "seg-a", "q1");
    write_transcript(&proj, "seg-b", "q2");
    write_transcript(&proj, "keep", "untouched");

    let resp = app(st.clone())
        .oneshot(conversation_delete_request(
            Some("Bearer test-token"),
            CID_A,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(
        !proj.join("seg-a.jsonl").exists(),
        "every bound transcript is gone"
    );
    assert!(!proj.join("seg-b.jsonl").exists());
    assert!(
        proj.join("keep.jsonl").exists(),
        "and nothing else is touched"
    );
    assert!(
        st.conversations.get(CID_A).is_none(),
        "the record is forgotten"
    );
    assert_eq!(st.titles.get(CID_A), None, "the title cannot resurrect");

    // The tombstone rides on the list, keyed on the conversation.
    let resp = app(st.clone())
        .oneshot(conversations_request(Some("Bearer test-token"), None, None))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let deleted: Vec<&str> = body["deleted"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["conversation_id"].as_str().unwrap())
        .collect();
    assert_eq!(
        deleted,
        vec![CID_A],
        "ONE tombstone, under the conversation id: nothing reads the session key space now"
    );
    let rows = body["conversations"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "only the untouched conversation is listed");

    // Idempotent: deleting again is still 204.
    let resp = app(st.clone())
        .oneshot(conversation_delete_request(
            Some("Bearer test-token"),
            CID_A,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    // A malformed id is a 400 and never reaches the filesystem. (A traversal attempt
    // with a slash in it cannot even match the route: the path segment splits, so axum
    // 404s it before the handler runs. The guard is what stops every other shape.)
    for bad in [
        "not-a-uuid",
        "AAAAAAAA-2222-4333-8444-555555555555",
        "..",
        "%2e%2e",
    ] {
        let resp = app(st.clone())
            .oneshot(conversation_delete_request(Some("Bearer test-token"), bad))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "rejected id {bad:?}"
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn conversation_flags_apply_lww_and_404_on_an_unknown_conversation() {
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-f", "q");
    let st = conv_state(&home, &vault);
    let cid = own_transcript(&st, "sess-f");

    let resp = app(st.clone())
        .oneshot(conversation_flags_request(
            Some("Bearer test-token"),
            &cid,
            r#"{"favorite":true,"favorite_updated_ms":200}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(v["favorite"], true);
    assert_eq!(v["favorite_updated_ms"], 200);

    // An OLDER write is ignored (strictly-newer LWW, unchanged).
    let resp = app(st.clone())
        .oneshot(conversation_flags_request(
            Some("Bearer test-token"),
            &cid,
            r#"{"favorite":false,"favorite_updated_ms":100}"#,
        ))
        .await
        .unwrap();
    let v: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(v["favorite"], true, "a stale write loses");
    assert_eq!(v["favorite_updated_ms"], 200);

    // An unknown conversation is a 404; a malformed id is a 400.
    let resp = app(st.clone())
        .oneshot(conversation_flags_request(
            Some("Bearer test-token"),
            CID_B,
            r#"{"favorite":true,"favorite_updated_ms":1}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let resp = app(st.clone())
        .oneshot(conversation_flags_request(
            Some("Bearer test-token"),
            "nope",
            r#"{"favorite":true,"favorite_updated_ms":1}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let _ = std::fs::remove_dir_all(&home);
}

/// Hydrate a conversation and return `(turns, next_cursor)`.
async fn hydrate_conv(st: &AppState, cid: &str, after: Option<&str>) -> (Vec<Value>, String) {
    let resp = app(st.clone())
        .oneshot(conversation_hydrate_request(
            Some("Bearer test-token"),
            cid,
            after,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    (
        body["turns"].as_array().cloned().unwrap_or_default(),
        body["next_cursor"].as_str().unwrap().to_string(),
    )
}

#[tokio::test]
async fn hydrate_reads_full_then_delta_then_across_a_segment_boundary_without_repeating() {
    let (home, vault, proj) = conv_fixture();
    let seg_a = concat!(
        r#"{"type":"user","message":{"content":"a1"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"r1"}]}}"#,
        "\n",
    );
    let st = conv_state(&home, &vault);
    st.conversations.register(CID_A, Some("phone"), 1_000);
    st.conversations.bind_session(CID_A, "seg-a");
    std::fs::write(proj.join("seg-a.jsonl"), seg_a).unwrap();

    // Full read.
    let (turns, cursor) = hydrate_conv(&st, CID_A, None).await;
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0]["text"], "a1");
    assert_eq!(turns[1]["text"], "r1");
    assert_eq!(cursor, format!("0:{}", seg_a.len()));

    // A caught-up delta read returns nothing and the same cursor.
    let (turns, cursor2) = hydrate_conv(&st, CID_A, Some(&cursor)).await;
    assert!(turns.is_empty(), "nothing new");
    assert_eq!(cursor2, cursor);

    // Append to segment A AND add a second segment: the delta must carry both, in
    // order, each exactly once.
    let more_a = "{\"type\":\"user\",\"message\":{\"content\":\"a2\"}}\n";
    std::fs::write(proj.join("seg-a.jsonl"), format!("{seg_a}{more_a}")).unwrap();
    let seg_b = concat!(
        r#"{"type":"user","message":{"content":"b1"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"rb"}]}}"#,
        "\n",
    );
    std::fs::write(proj.join("seg-b.jsonl"), seg_b).unwrap();
    st.conversations.bind_session(CID_A, "seg-b");

    let (turns, cursor3) = hydrate_conv(&st, CID_A, Some(&cursor)).await;
    let texts: Vec<&str> = turns.iter().map(|t| t["text"].as_str().unwrap()).collect();
    assert_eq!(
        texts,
        ["a2", "b1", "rb"],
        "the cross-boundary delta is in segment order, nothing repeated, nothing lost"
    );
    assert_eq!(cursor3, format!("1:{}", seg_b.len()));

    // And a read from that cursor is empty: no turn is ever served twice.
    let (turns, _) = hydrate_conv(&st, CID_A, Some(&cursor3)).await;
    assert!(turns.is_empty());

    // The full read from scratch sees every turn exactly once, in order.
    let (all, _) = hydrate_conv(&st, CID_A, None).await;
    let texts: Vec<&str> = all.iter().map(|t| t["text"].as_str().unwrap()).collect();
    assert_eq!(texts, ["a1", "r1", "a2", "b1", "rb"]);
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn turn_keys_are_stable_across_hydrates_and_unique_within_a_conversation() {
    let (home, vault, proj) = conv_fixture();
    // The SAME text twice in each segment: a content hash would collapse them, a key
    // that names the byte offset cannot.
    let seg = concat!(
        r#"{"type":"user","message":{"content":"same"}}"#,
        "\n",
        r#"{"type":"user","message":{"content":"same"}}"#,
        "\n",
    );
    let st = conv_state(&home, &vault);
    st.conversations.register(CID_A, Some("phone"), 1_000);
    st.conversations.bind_session(CID_A, "seg-a");
    std::fs::write(proj.join("seg-a.jsonl"), seg).unwrap();
    std::fs::write(proj.join("seg-b.jsonl"), seg).unwrap();
    st.conversations.bind_session(CID_A, "seg-b");

    let (first, _) = hydrate_conv(&st, CID_A, None).await;
    let keys: Vec<&str> = first
        .iter()
        .map(|t| t["turn_key"].as_str().unwrap())
        .collect();
    assert_eq!(keys.len(), 4, "four turns");
    let unique: std::collections::HashSet<&&str> = keys.iter().collect();
    assert_eq!(unique.len(), 4, "every key is unique: {keys:?}");
    assert_eq!(keys[0], "seg-a:0");
    assert!(
        keys[2].starts_with("seg-b:"),
        "the key names its own segment"
    );

    // Repeating the hydrate yields byte-identical keys.
    let (again, _) = hydrate_conv(&st, CID_A, None).await;
    let keys2: Vec<&str> = again
        .iter()
        .map(|t| t["turn_key"].as_str().unwrap())
        .collect();
    assert_eq!(keys, keys2, "keys are stable across hydrates");
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn hydrate_skips_a_deleted_segment_and_advances_past_it() {
    let (home, vault, proj) = conv_fixture();
    let seg_b = "{\"type\":\"user\",\"message\":{\"content\":\"survivor\"}}\n";
    let st = conv_state(&home, &vault);
    st.conversations.register(CID_A, Some("phone"), 1_000);
    // Segment 0 is bound but its file never exists (swept by GC, or deleted).
    st.conversations.bind_session(CID_A, "seg-gone");
    st.conversations.bind_session(CID_A, "seg-b");
    std::fs::write(proj.join("seg-b.jsonl"), seg_b).unwrap();

    // A cursor pointing AT the missing segment skips it and reads on.
    let (turns, cursor) = hydrate_conv(&st, CID_A, Some("0:0")).await;
    let texts: Vec<&str> = turns.iter().map(|t| t["text"].as_str().unwrap()).collect();
    assert_eq!(
        texts,
        ["survivor"],
        "the missing segment is skipped, not an error"
    );
    assert_eq!(
        cursor,
        format!("1:{}", seg_b.len()),
        "the cursor advanced past it"
    );

    // Malformed cursors are 400s, never a silent reset to zero (which would replay the
    // whole conversation and duplicate every turn on the client).
    for bad in ["abc", "0", "0:1:2", "-1:0", "0:x"] {
        let resp = app(st.clone())
            .oneshot(conversation_hydrate_request(
                Some("Bearer test-token"),
                CID_A,
                Some(bad),
            ))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "rejected cursor {bad:?}"
        );
    }
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn a_restart_reloads_the_registry_and_a_resume_still_resolves() {
    let (home, vault, proj) = conv_fixture();
    let state_dir = std::env::temp_dir().join(format!("jesse-state-{}", random_hex()));
    std::fs::create_dir_all(&state_dir).unwrap();
    let cfg = Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    {
        let st = AppState::new(cfg.clone());
        st.conversations.register(CID_A, Some("phone"), 1_000);
        st.conversations.bind_session(CID_A, "sess-live");
        st.titles.set(CID_A, "Persisted");
    }
    // Written AFTER the conversation owns it, so the second bridge's startup adoption has
    // nothing to claim — the record is what carries ownership across the restart.
    write_transcript(&proj, "sess-live", "q");
    // A fresh bridge over the same state dir.
    let st2 = AppState::new(cfg.clone());
    let rec = st2.conversations.get(CID_A).expect("the record reloaded");
    assert_eq!(rec.session_ids, vec!["sess-live".to_string()]);
    assert_eq!(rec.registered_ms, 1_000, "timestamps survive");
    assert_eq!(
        st2.conversations
            .conversation_for_session("sess-live")
            .as_deref(),
        Some(CID_A),
        "the reverse index is rebuilt from the records, not persisted"
    );
    assert_eq!(st2.titles.get(CID_A).as_deref(), Some("Persisted"));
    // And a resume after the restart still targets the right transcript.
    let resumed = resolve_conversation_resume(&st2.conversations, CID_A, None);
    assert_eq!(resumed.as_deref(), Some("sess-live"));
    assert_eq!(
        resolve_resume_session(&cfg, resumed.as_deref()),
        Some("sess-live"),
        "and the transcript is still there, so the resume is not dropped"
    );
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&state_dir);
}

#[tokio::test]
async fn the_key_migration_runs_once_and_survives_a_restart() {
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-old", "q");
    let state_dir = std::env::temp_dir().join(format!("jesse-state-{}", random_hex()));
    std::fs::create_dir_all(&state_dir).unwrap();
    // A pre-upgrade state dir: titles and flags keyed on the SESSION id.
    std::fs::write(
        state_dir.join("titles.json"),
        r#"{"v":1,"titles":{"sess-old":"Legacy Title"}}"#,
    )
    .unwrap();
    std::fs::write(
        state_dir.join("flags.json"),
        r#"{"v":1,"flags":{"sess-old":{"favorite":true,"favorite_updated_ms":777}}}"#,
    )
    .unwrap();
    let cfg = Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    // A pre-existing record for the session, which is what the migration re-keys
    // THROUGH. It used to come from the startup sweep adopting every transcript on disk;
    // that sweep is gone, so ownership has to be in the store already.
    let cid = orphan_conversation_id("sess-old");
    {
        let seed = ConversationStore::new(Some(state_dir.join("conversations.json")));
        seed.register(&cid, None, 0);
        seed.bind_session(&cid, "sess-old");
    }

    let st = AppState::new(cfg.clone());
    assert_eq!(
        st.titles.get(&cid).as_deref(),
        Some("Legacy Title"),
        "the title moved onto the conversation"
    );
    assert_eq!(st.titles.get("sess-old"), None, "and off the session id");
    let f = st.flags.get(&cid);
    assert!(
        f.favorite && f.favorite_updated_ms == 777,
        "the flag moved with its last-writer-wins clock intact"
    );
    assert!(st.conversations.migration_done());

    // A restart does NOT re-run it, and nothing regresses.
    let st2 = AppState::new(cfg);
    assert!(st2.conversations.migration_done());
    assert_eq!(st2.titles.get(&cid).as_deref(), Some("Legacy Title"));
    assert!(st2.flags.get(&cid).favorite);
    assert_eq!(st2.titles.len(), 1, "no duplicate key was created");
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&state_dir);
}

#[tokio::test]
async fn the_key_migration_drops_keys_for_sessions_the_bridge_never_owned() {
    // CONSEQUENCE of removing the startup sweep, pinned so it cannot be rediscovered by
    // accident. The one-time migration re-keys titles/flags from session id onto
    // conversation id THROUGH the reverse index. That index used to be populated by
    // adopting every transcript on disk; now it holds only what the bridge bound itself.
    //
    // So a state dir that predates conversations AND has never migrated loses the titles
    // and favorites belonging to sessions with no record — `migrate_keys_to_conversations`
    // drops an unmapped key rather than keeping it. Already-migrated deploys are
    // unaffected (the flag is persisted and the migration never re-runs), and a fresh
    // install has nothing to migrate.
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-unowned", "q");
    let state_dir = std::env::temp_dir().join(format!("jesse-state-{}", random_hex()));
    std::fs::create_dir_all(&state_dir).unwrap();
    std::fs::write(
        state_dir.join("titles.json"),
        r#"{"v":1,"titles":{"sess-unowned":"Title On A Foreign Session"}}"#,
    )
    .unwrap();

    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault,
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    });
    assert!(st.conversations.is_empty(), "nothing was adopted");
    assert_eq!(
        st.titles.get(&orphan_conversation_id("sess-unowned")),
        None,
        "there is no conversation to move it onto"
    );
    assert_eq!(
        st.titles.get("sess-unowned"),
        None,
        "and the unmapped key is dropped, not kept"
    );
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&state_dir);
}

#[tokio::test]
async fn in_flight_transcript_produces_no_row_then_binds_on_terminal() {
    // THE headline regression. A conversation is registered at accept time with no
    // bound session, and the CLI writes its transcript file WHILE the turn runs. A list
    // refresh landing in that window must NOT turn that stem into a second
    // conversation, or the client adopts a duplicate. When the turn terminates the stem
    // must belong to the conversation that produced it, and the list must show exactly
    // one row.
    let (home, vault, proj) = conv_fixture();
    // Writes its transcript immediately, then sleeps before answering: the same
    // ordering the real CLI has (verified against claude 2.1.220, where the file
    // appears within a second of spawn on a multi-second turn).
    let fake = claude_writing_transcript(&proj, "sess-mid", 2);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });

    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // Wait until the transcript really is on disk, so this test asserts the suppression
    // and not a race it happened to win.
    let proj_ref = &proj;
    wait_for(
        "the fake CLI to write its transcript mid-turn",
        move || async move { proj_ref.join("sess-mid.jsonl").exists().then_some(()) },
    )
    .await;

    // MID-TURN list refresh, twice, as backgrounding and reopening the app does.
    for _ in 0..2 {
        let rows = conversation_rows(&st).await;
        assert_eq!(
            rows.len(),
            1,
            "a mid-turn refresh must show exactly one conversation: {rows:?}"
        );
        assert_eq!(rows[0]["conversation_id"], CID_A);
        assert!(
            rows[0]["session_id"].is_null(),
            "the in-flight transcript is not yet advertised as a session"
        );
    }
    assert_eq!(
        st.conversations.len(),
        1,
        "and no second RECORD was created either"
    );
    assert_eq!(
        st.conversations.conversation_for_session("sess-mid"),
        None,
        "the suppressed stem is not bound to anything yet"
    );

    wait_for_done(&st, &job_id).await;

    assert_eq!(
        st.conversations
            .conversation_for_session("sess-mid")
            .as_deref(),
        Some(CID_A),
        "on termination the stem belongs to the conversation that produced it"
    );
    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1, "still exactly one row: {rows:?}");
    assert_eq!(rows[0]["session_id"], "sess-mid");
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn a_turn_binds_only_the_session_it_reported_not_a_stem_that_merely_appeared() {
    // THE defect this change removes. The turn's own session is `sess-mine`; while it
    // runs, a transcript the bridge did not start — a desktop Claude Code run against the
    // same vault, whose projects dir is keyed only on the cwd — appears in the same
    // directory. The old terminal step diffed the directory and bound EVERY stem that had
    // appeared, so that foreign transcript was aliased onto this live conversation and
    // became its resume target.
    //
    // Ownership now comes from the id the child reported on its `init` line, so the
    // foreign stem is simply not this turn's business.
    let (home, vault, proj) = conv_fixture();
    let script = format!(
        "#!/bin/sh\n\
         printf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-mine\",\"cwd\":\"/v\"}}'\n\
         printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"mine\"}}}}' > '{p}/sess-mine.jsonl'\n\
         printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"somebody else\\u0027s terminal run\"}}}}' > '{p}/sess-foreign.jsonl'\n\
         printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-mine\"}}'\n",
        p = proj.display()
    );
    let fake = write_fake_claude(&script);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });

    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    wait_for_done(&st, body["job_id"].as_str().unwrap()).await;

    assert_eq!(
        st.conversations
            .conversation_for_session("sess-mine")
            .as_deref(),
        Some(CID_A),
        "the reported session is bound"
    );
    assert_eq!(
        st.conversations.get(CID_A).unwrap().session_ids,
        vec!["sess-mine".to_string()],
        "and it is the ONLY session bound — the concurrent stem is not this turn's"
    );
    assert_ne!(
        st.conversations
            .conversation_for_session("sess-foreign")
            .as_deref(),
        Some(CID_A),
        "the foreign transcript is never aliased onto this conversation"
    );
    // And it cannot become this conversation's resume target, which is what made the
    // original symptom self-sustaining.
    assert_eq!(
        resolve_conversation_resume(&st.conversations, CID_A, None).as_deref(),
        Some("sess-mine")
    );
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn a_retried_turn_binds_every_attempt_and_the_last_stays_current() {
    // A retry spawns a fresh child with a fresh session and a fresh transcript. All of
    // them are this conversation's; binding them in spawn order leaves the LAST current,
    // which is what a resume targets. Ignoring the earlier ones would strand a transcript
    // that nothing else will ever claim.
    let (home, vault, proj) = conv_fixture();
    let counter = std::env::temp_dir().join(format!("jesse-retry-{}", random_hex()));
    // Attempt 1 announces `sess-try1`, writes its transcript, then returns a RETRYABLE
    // envelope. Attempt 2 announces `sess-try2` and succeeds.
    let script = format!(
        "#!/bin/sh\n\
         n=$(cat '{c}' 2>/dev/null || echo 0)\n\
         n=$((n+1)); printf '%s' \"$n\" > '{c}'\n\
         if [ \"$n\" = \"1\" ]; then\n\
           printf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-try1\",\"cwd\":\"/v\"}}'\n\
           printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"attempt one\"}}}}' > '{p}/sess-try1.jsonl'\n\
           printf '%s' '{{\"type\":\"result\",\"is_error\":true,\"subtype\":\"error_during_execution\",\"api_error_status\":503,\"result\":\"upstream 503\",\"session_id\":\"sess-try1\"}}'\n\
         else\n\
           printf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-try2\",\"cwd\":\"/v\"}}'\n\
           printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"attempt two\"}}}}' > '{p}/sess-try2.jsonl'\n\
           printf '%s' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-try2\"}}'\n\
         fi\n",
        c = counter.display(),
        p = proj.display()
    );
    let fake = write_fake_claude(&script);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });

    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    wait_for_done(&st, body["job_id"].as_str().unwrap()).await;

    assert_eq!(
        st.conversations.get(CID_A).unwrap().session_ids,
        vec!["sess-try1".to_string(), "sess-try2".to_string()],
        "both attempts' sessions belong to the conversation, in spawn order"
    );
    assert_eq!(
        resolve_conversation_resume(&st.conversations, CID_A, None).as_deref(),
        Some("sess-try2"),
        "the last attempt is what a resume continues"
    );
    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1, "one row, not one per attempt: {rows:?}");
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&counter);
}

#[tokio::test]
async fn a_failed_turn_still_binds_the_transcript_it_created() {
    // The failure variant, and the case that most justifies reading the id off the stream:
    // the CLI announces its session on the `init` line, writes its transcript, and THEN
    // dies without ever reaching a `result` line. There is no reply session id to bind and
    // no terminal envelope at all — but the child already said which session it owns, so
    // the transcript is still claimed and does not surface as a second conversation.
    //
    // The fake mirrors the real ordering (verified against claude 2.1.220: `system`/`init`
    // carrying `session_id` is the first line out, before any transcript exists).
    let (home, vault, proj) = conv_fixture();
    let script = format!(
        "#!/bin/sh\n\
         printf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-failed\",\"cwd\":\"/v\"}}'\n\
         printf '%s\\n' '{{\"type\":\"user\",\"message\":{{\"content\":\"orphaned\"}}}}' > '{}/sess-failed.jsonl'\n\
         echo 'boom' >&2\n\
         exit 1\n",
        proj.display()
    );
    let fake = write_fake_claude(&script);
    let st = AppState::new(Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.clone(),
        state_dir: None,
        claude_bin: fake.to_string_lossy().into_owned(),
        timeout_secs: 30,
        ..test_config()
    });

    let body = post_turn(
        &st,
        &format!(r#"{{"mode":"ask","text":"hi","conversation_id":"{CID_A}"}}"#),
    )
    .await;
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let st_ref = &st;
    let job_ref = job_id.as_str();
    let v = wait_for("the turn to reach a terminal state", move || async move {
        let v = result_status(st_ref, job_ref).await;
        (v["status"] != "running").then_some(v)
    })
    .await;
    assert_eq!(v["status"], "failed", "the turn really failed: {v}");

    assert_eq!(
        st.conversations
            .conversation_for_session("sess-failed")
            .as_deref(),
        Some(CID_A),
        "the id the child reported on `init` bound the transcript, with no reply session id \
         and no result line at all"
    );
    let rows = conversation_rows(&st).await;
    assert_eq!(rows.len(), 1, "one row, not two: {rows:?}");
    assert_eq!(rows[0]["conversation_id"], CID_A);
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn a_session_already_owned_is_never_reassigned_to_another_conversation() {
    // The steal is GONE, and this is what replaces it end to end. A transcript owned by
    // one conversation (here an orphan-adopted record) stays there when a different
    // conversation claims the same session.
    //
    // The steal existed to repair a transcript orphan-adopted before its owning turn
    // finished. That window is closed at the source now: a turn binds the id its child
    // reported on `init`, while the in-flight claim is still held, so no refresh can adopt
    // the stem first. What the steal ALSO did was let any conversation take over a session
    // another one already held — which is how a foreign transcript could be aliased onto a
    // live phone thread and become its resume target.
    //
    // Nothing adopts at runtime any more, so the orphan record is seeded explicitly. That
    // state is not synthetic: every store written before adoption was removed still holds
    // orphan-adopted records (731 of them on the deploy that surfaced the defect).
    let (home, vault, proj) = conv_fixture();
    write_transcript(&proj, "sess-x", "q");
    let st = conv_state(&home, &vault);
    let orphan = st.conversations.adopt_orphan_session("sess-x", 0);
    assert_eq!(orphan, orphan_conversation_id("sess-x"));
    assert_eq!(
        st.conversations
            .conversation_for_session("sess-x")
            .as_deref(),
        Some(&orphan[..]),
    );
    assert_eq!(conversation_rows(&st).await.len(), 1);

    st.conversations.register(CID_A, Some("phone"), 2_000);
    st.conversations.bind_session(CID_A, "sess-x");

    assert_eq!(
        st.conversations
            .conversation_for_session("sess-x")
            .as_deref(),
        Some(&orphan[..]),
        "the session stays with the conversation that already held it"
    );
    assert!(
        st.conversations.get(&orphan).is_some(),
        "and that record is not dropped"
    );
    assert!(
        st.conversations.get(CID_A).unwrap().session_ids.is_empty(),
        "the claimant gains nothing"
    );
    // The resume target is unaffected: CID_A owns no session, so it starts fresh rather
    // than silently continuing somebody else's transcript.
    assert_eq!(
        resolve_conversation_resume(&st.conversations, CID_A, None),
        None
    );
    let _ = std::fs::remove_dir_all(&home);
}

// ---- GET /jesse/today -----------------------------------------------------
//
// Synthetic, invented fixture (never a copy of the real personal Today.md) —
// the same file the parser's unit tests use, so the endpoint and the parser
// are asserted against one grammar.

const FIX_TODAY_MD: &str = include_str!("fixtures/today/full.md");

/// A vault containing the day file, and an AppState pointed at it.
fn today_state() -> (AppState, std::path::PathBuf) {
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", FIX_TODAY_MD);
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    (AppState::new(cfg), vault)
}

#[tokio::test]
async fn today_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(today_request(None, None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn today_wrong_token_is_401() {
    let resp = app(test_state())
        .oneshot(today_request(Some("Bearer wrong"), None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn today_happy_path_returns_the_structured_snapshot() {
    let (st, vault) = today_state();
    let resp = app(st)
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let etag_header = resp
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_string();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();

    assert_eq!(body["title"], "Today: Tuesday, March 3, 2026");
    assert_eq!(body["date"], "2026-03-03");
    assert_eq!(body["missing"], false);
    assert!(body["generatedAt"].as_str().unwrap().ends_with('Z'));
    assert_eq!(
        body["etag"].as_str().unwrap(),
        etag_header,
        "the body's etag is the one on the header"
    );
    assert!(body["narrative"]
        .as_str()
        .unwrap()
        .contains("it is a short day"));

    // Lead items sit above the sections.
    let lead = body["leadItems"].as_array().unwrap();
    assert_eq!(lead.len(), 1);
    assert!(lead[0]["lead"]
        .as_str()
        .unwrap()
        .starts_with("TOP PRIORITY"));

    // Sections carry name/kind/prose/items/reports, in file order.
    let sections = body["sections"].as_array().unwrap();
    let names: Vec<&str> = sections
        .iter()
        .map(|s| s["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        vec![
            "Schedule",
            "Do Now",
            "Errands",
            "Health",
            "Currency",
            "Still open (aging)",
            "Reminders (Mar 3 to Mar 10)",
            "Done Today",
        ]
    );
    let health = sections.iter().find(|s| s["name"] == "Health").unwrap();
    assert_eq!(health["kind"], "briefing");
    assert_eq!(health["items"].as_array().unwrap().len(), 1);
    assert_eq!(health["reports"][0]["kind"], "health");

    // Ids and values only: every item carries an id and a byte range.
    for s in sections {
        for it in s["items"].as_array().unwrap() {
            assert!(
                !it["id"].as_str().unwrap().is_empty(),
                "every item has an id"
            );
            assert!(it["range"]["end"].as_u64().unwrap() > it["range"]["start"].as_u64().unwrap());
        }
    }

    let counts = &body["counts"];
    let total_items: usize = sections
        .iter()
        .map(|s| s["items"].as_array().unwrap().len())
        .sum::<usize>()
        + lead.len();
    assert_eq!(
        counts["open"].as_u64().unwrap() + counts["done"].as_u64().unwrap(),
        total_items as u64
    );
    assert!(counts["reportsUnseen"].as_u64().unwrap() > 0);

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_etag_is_stable_and_if_none_match_gives_304() {
    let (st, vault) = today_state();
    let first = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    let etag = first
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_string();
    assert!(etag.starts_with('"'), "strong ETag is quoted: {etag}");

    // Same file state → same ETag, even though `generatedAt` moved on. The tag is
    // a pure function of the file, so a poll that changes nothing costs one 304.
    let second = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    assert_eq!(
        second.headers().get("etag").unwrap().to_str().unwrap(),
        etag,
        "the ETag must not move with the clock"
    );

    let cached = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), Some(&etag)))
        .await
        .unwrap();
    assert_eq!(cached.status(), StatusCode::NOT_MODIFIED);
    assert_eq!(
        cached.headers().get("etag").unwrap().to_str().unwrap(),
        etag
    );
    assert!(body_string(cached).await.is_empty(), "304 carries no body");

    let wildcard = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), Some("*")))
        .await
        .unwrap();
    assert_eq!(wildcard.status(), StatusCode::NOT_MODIFIED);

    // A changed file changes the tag.
    write_vault_file(&vault, "vault/Today.md", "# Today: Friday, March 6, 2026\n");
    let changed = app(st)
        .oneshot(today_request(Some("Bearer test-token"), Some(&etag)))
        .await
        .unwrap();
    assert_eq!(changed.status(), StatusCode::OK, "a stale tag re-fetches");
    assert_ne!(
        changed.headers().get("etag").unwrap().to_str().unwrap(),
        etag
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_missing_file_is_200_with_an_empty_snapshot_and_a_missing_marker() {
    let vault = make_diet_vault(); // no Today.md written
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let resp = app(AppState::new(cfg))
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a missing day file is an empty state, not an error"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["missing"], true, "the client renders an empty state");
    assert_eq!(body["title"], Value::Null);
    assert_eq!(body["date"], Value::Null);
    assert!(body["sections"].as_array().unwrap().is_empty());
    assert!(body["leadItems"].as_array().unwrap().is_empty());
    assert_eq!(body["counts"]["open"], 0);
    assert!(
        body["etag"].as_str().is_some(),
        "an empty snapshot still tags"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_items_carry_a_project_slug_read_from_the_dashboard_pages() {
    let vault = make_diet_vault();
    write_vault_file(
        &vault,
        "vault/Today.md",
        "# Today: Tuesday, March 3, 2026\n\n\
         ## Do Now\n\n\
         * [ ] **A declared home.** [[todo-list/Dashboard/Network]] (Added 2026-03-01)\n\
         * [ ] **A note the Tag1 page claims.** [[todo-list/Projects/Demo/Claimed]] (Added 2026-03-01)\n\
         * [ ] **No lineage at all.** (Added 2026-03-01)\n",
    );
    std::fs::create_dir_all(vault.join("vault/Dashboard")).unwrap();
    write_vault_file(
        &vault,
        "vault/Dashboard/Tag1.md",
        "# Tag1\n\n* [[todo-list/Projects/Demo/Claimed]]\n",
    );
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    let etag = resp
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_string();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let items = body["sections"][0]["items"].as_array().unwrap();
    assert_eq!(items[0]["project"], "network", "a declared home link");
    assert_eq!(
        items[1]["project"], "tag1",
        "a note the Tag1 Dashboard page claims rolls up to Tag1"
    );
    assert_eq!(items[2]["project"], "unfiled", "no lineage is not a guess");
    // A slug and nothing else — colour and label stay a client concern.
    assert!(items[0].get("color").is_none() && items[0].get("projectLabel").is_none());

    // Un-claiming the note in the Dashboard page re-files the item AND moves the
    // snapshot etag, so a client's cache cannot survive the re-filing.
    write_vault_file(
        &vault,
        "vault/Dashboard/Tag1.md",
        "# Tag1\n\nnothing here.\n",
    );
    let after = app(st)
        .oneshot(today_request(Some("Bearer test-token"), Some(&etag)))
        .await
        .unwrap();
    assert_eq!(
        after.status(),
        StatusCode::OK,
        "a changed project must invalidate the cached tag"
    );
    let body: Value = serde_json::from_str(&body_string(after).await).unwrap();
    assert_eq!(body["sections"][0]["items"][1]["project"], "unfiled");

    let _ = std::fs::remove_dir_all(&vault);
}

// ---- GET /jesse/today/items/{id}/detail ------------------------------------
//
// Synthetic vault, invented notes. The security half of this endpoint is unit
// tested in `todaydetail`; what is asserted here is the HTTP contract — auth,
// the strong ETag and its 304, the 410 for a vanished item, and the typed
// no-detail answer — plus one end-to-end proof that a target pointing out of the
// vault is refused through the real route rather than only in the resolver.

const FIX_DETAIL_MD: &str = "# Today: Tuesday, March 3, 2026\n\n\
     ## Do Now\n\n\
     * [ ] **The item with a note.** [[todo-list/Projects/Demo/Widget]] (Added 2026-03-01)\n\
     * [ ] **The item with no link at all.** (Added 2026-03-01)\n\
     * [ ] **The item whose link escapes the vault.** [[todo-list/../outside-secret]] (Added 2026-03-01)\n";

/// A vault with the day file above, one real note, and one secret OUTSIDE the
/// notes root that a traversal target would reach.
fn detail_state() -> (AppState, std::path::PathBuf) {
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", FIX_DETAIL_MD);
    std::fs::create_dir_all(vault.join("vault/Projects/Demo")).unwrap();
    write_vault_file(
        &vault,
        "vault/Projects/Demo/Widget.md",
        "# Widget\n\nEverything you need to know about the widget.\n",
    );
    // One level above `vault/` — inside the repo, outside the notes root.
    std::fs::write(vault.join("outside-secret.md"), "TOP SECRET\n").unwrap();
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    };
    (AppState::new(cfg), vault)
}

/// The ids of the three fixture items, in file order.
async fn detail_item_ids(st: AppState) -> Vec<String> {
    let resp = app(st)
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    body["sections"][0]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["id"].as_str().unwrap().to_string())
        .collect()
}

#[tokio::test]
async fn today_detail_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(today_detail_request("abc123", None, None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let wrong = app(test_state())
        .oneshot(today_detail_request("abc123", Some("Bearer wrong"), None))
        .await
        .unwrap();
    assert_eq!(
        wrong.status(),
        StatusCode::UNAUTHORIZED,
        "auth is checked before the id is even looked up"
    );
}

#[tokio::test]
async fn today_detail_serves_the_note_then_304s_on_the_same_tag() {
    let (st, vault) = detail_state();
    let ids = detail_item_ids(st.clone()).await;

    let resp = app(st.clone())
        .oneshot(today_detail_request(
            &ids[0],
            Some("Bearer test-token"),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let etag = resp
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_string();
    assert!(etag.starts_with('"'), "strong ETag is quoted: {etag}");
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["status"], "ok");
    assert_eq!(body["id"], ids[0]);
    assert_eq!(body["path"], "Projects/Demo/Widget.md");
    assert_eq!(body["target"], "todo-list/Projects/Demo/Widget");
    assert!(body["markdown"]
        .as_str()
        .unwrap()
        .contains("Everything you need to know"));
    assert_eq!(body["truncated"], false);
    assert_eq!(
        body["etag"].as_str().unwrap(),
        etag,
        "the body's etag is the one on the header"
    );

    // Same file state → same tag, so a poll costs one 304 with no body.
    let cached = app(st.clone())
        .oneshot(today_detail_request(
            &ids[0],
            Some("Bearer test-token"),
            Some(&etag),
        ))
        .await
        .unwrap();
    assert_eq!(cached.status(), StatusCode::NOT_MODIFIED);
    assert_eq!(
        cached.headers().get("etag").unwrap().to_str().unwrap(),
        etag
    );
    assert!(body_string(cached).await.is_empty(), "304 carries no body");

    // Editing the NOTE (not the day file) moves the tag.
    write_vault_file(
        &vault,
        "vault/Projects/Demo/Widget.md",
        "# Widget\n\nRewritten.\n",
    );
    let changed = app(st)
        .oneshot(today_detail_request(
            &ids[0],
            Some("Bearer test-token"),
            Some(&etag),
        ))
        .await
        .unwrap();
    assert_eq!(changed.status(), StatusCode::OK, "a stale tag re-fetches");
    assert_ne!(
        changed.headers().get("etag").unwrap().to_str().unwrap(),
        etag
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_detail_is_typed_no_detail_rather_than_an_error() {
    let (st, vault) = detail_state();
    let ids = detail_item_ids(st.clone()).await;

    // An item with no wiki link at all.
    let resp = app(st.clone())
        .oneshot(today_detail_request(
            &ids[1],
            Some("Bearer test-token"),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "an item with no note is an ordinary item, not a failure"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["status"], "no-detail");
    assert_eq!(body["reason"], "no-target");
    assert!(
        body["markdown"].is_null(),
        "no content on a no-detail answer"
    );
    assert!(
        body["etag"].as_str().is_some(),
        "a no-detail answer still tags"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_detail_refuses_a_target_that_escapes_the_vault_root() {
    let (st, vault) = detail_state();
    let ids = detail_item_ids(st.clone()).await;

    let resp = app(st)
        .oneshot(today_detail_request(
            &ids[2],
            Some("Bearer test-token"),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let raw = body_string(resp).await;
    let body: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(
        body["status"], "no-detail",
        "a `..` target is refused, not served"
    );
    assert_eq!(
        body["reason"], "unresolved-target",
        "…and it is indistinguishable from a note that simply is not there"
    );
    assert!(
        !raw.contains("TOP SECRET"),
        "nothing outside the vault reaches the wire: {raw}"
    );
    assert!(
        !raw.contains(vault.to_string_lossy().as_ref()),
        "no absolute vault path on the wire either: {raw}"
    );
    assert_eq!(
        std::fs::read_to_string(vault.join("outside-secret.md")).unwrap(),
        "TOP SECRET\n",
        "the file outside the vault is untouched"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_detail_for_an_unknown_id_is_410_gone() {
    let (st, vault) = detail_state();
    let resp = app(st)
        .oneshot(today_detail_request(
            "0123456789ab",
            Some("Bearer test-token"),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::GONE,
        "the client had this id from a snapshot — the item is gone, not the URL wrong"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

// ---- POST /jesse/today — the write path -----------------------------------
//
// The bridge's first writes to the agent's own working files. Same synthetic
// fixture as the read path, so one grammar is asserted end to end.

/// A vault with the day file AND a state dir, so the intent journal and the
/// glance store are both live (they degrade to nothing without one).
fn today_write_state() -> (AppState, std::path::PathBuf) {
    let vault = make_diet_vault();
    write_vault_file(&vault, "vault/Today.md", FIX_TODAY_MD);
    let state = vault.join("state");
    std::fs::create_dir_all(&state).unwrap();
    let cfg = Config {
        vault: vault.to_string_lossy().into_owned(),
        state_dir: Some(state.to_string_lossy().into_owned()),
        ..test_config()
    };
    (AppState::new(cfg), vault)
}

/// The current snapshot and its etag, through the real `GET`.
async fn today_snapshot(st: &AppState) -> (Value, String) {
    let resp = app(st.clone())
        .oneshot(today_request(Some("Bearer test-token"), None))
        .await
        .unwrap();
    let etag = resp
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_string();
    (
        serde_json::from_str(&body_string(resp).await).unwrap(),
        etag,
    )
}

/// The id of the first item whose lead starts with `lead_starts`.
fn id_of(snapshot: &Value, lead_starts: &str) -> String {
    let mut items: Vec<&Value> = snapshot["leadItems"].as_array().unwrap().iter().collect();
    for section in snapshot["sections"].as_array().unwrap() {
        items.extend(section["items"].as_array().unwrap().iter());
    }
    items
        .iter()
        .find(|i| {
            i["lead"]
                .as_str()
                .unwrap_or_default()
                .starts_with(lead_starts)
        })
        .unwrap_or_else(|| panic!("no item starting {lead_starts:?}"))
        .get("id")
        .unwrap()
        .as_str()
        .unwrap()
        .to_string()
}

/// One item's parsed state out of a snapshot body.
fn item_state(snapshot: &Value, lead_starts: &str) -> (bool, Option<String>) {
    let mut items: Vec<&Value> = snapshot["leadItems"].as_array().unwrap().iter().collect();
    for section in snapshot["sections"].as_array().unwrap() {
        items.extend(section["items"].as_array().unwrap().iter());
    }
    let it = items
        .iter()
        .find(|i| {
            i["lead"]
                .as_str()
                .unwrap_or_default()
                .starts_with(lead_starts)
        })
        .unwrap_or_else(|| panic!("no item starting {lead_starts:?}"));
    (
        it["checked"].as_bool().unwrap(),
        it["appCompleted"]["evidence"].as_str().map(str::to_string),
    )
}

#[tokio::test]
async fn today_check_no_auth_is_401() {
    let resp = app(test_state())
        .oneshot(today_check_request(
            None,
            "abc",
            Some("*"),
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn today_move_and_glance_are_401_without_a_bearer() {
    for req in [
        today_move_request(
            None,
            "abc",
            Some("*"),
            r#"{"op":"up","at":"2026-03-03T09:30:00Z"}"#,
        ),
        today_glance_request(None, Some("*"), r#"{"id":"abc","glancedAt":1}"#),
    ] {
        let resp = app(test_state()).oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }
}

/// THE CORE CYCLE: check, read it back, uncheck, read it back — and the file is
/// byte-identical to where it started.
#[tokio::test]
async fn today_check_get_uncheck_get_round_trips_the_file() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let original = std::fs::read_to_string(&day).unwrap();

    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    assert!(!item_state(&snapshot, "Reply to Ada").0);

    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"evidence":"sent Ada the date","at":"2026-03-03T09:30:00Z","client_tz":"UTC"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let posted: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(posted["pending"], false, "applied, not parked");
    assert_eq!(
        item_state(&posted, "Reply to Ada"),
        (true, Some("sent Ada the date".to_string())),
        "the mutation's own response already shows the new state"
    );

    // …and a fresh GET agrees, from the file.
    let (after_check, etag2) = today_snapshot(&st).await;
    assert_eq!(
        item_state(&after_check, "Reply to Ada"),
        (true, Some("sent Ada the date".to_string()))
    );
    assert_ne!(etag2, etag, "the etag moved with the file");
    let on_disk = std::fs::read_to_string(&day).unwrap();
    assert!(on_disk.contains("\t*(app-completed 2026-03-03 09:30: sent Ada the date)*"));

    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag2),
            r#"{"checked":false,"at":"2026-03-03T09:40:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let (after_uncheck, _) = today_snapshot(&st).await;
    assert_eq!(item_state(&after_uncheck, "Reply to Ada"), (false, None));
    assert_eq!(
        std::fs::read_to_string(&day).unwrap(),
        original,
        "check then uncheck leaves the file byte-identical"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_a_stale_if_match_is_412_and_touches_nothing() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    // Something else rewrites the file behind the client's back.
    let rewritten = format!("{FIX_TODAY_MD}\n## Late addition\n\n* [ ] Added by the agent.\n");
    std::fs::write(&day, &rewritten).unwrap();

    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PRECONDITION_FAILED);
    assert_eq!(
        std::fs::read_to_string(&day).unwrap(),
        rewritten,
        "a 412 must not write a byte"
    );
    assert!(
        !st.cfg.today_intents_file().unwrap().exists()
            || load_intents(&st.cfg.today_intents_file().unwrap()).is_empty(),
        "…and must not journal an intent either"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_a_missing_if_match_is_428() {
    let (st, vault) = today_write_state();
    let (snapshot, _) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            None,
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::PRECONDITION_REQUIRED,
        "a missing precondition is distinct from a stale one"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_an_unknown_item_id_is_410() {
    let (st, vault) = today_write_state();
    let (_, etag) = today_snapshot(&st).await;
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            "ffffffffffff",
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::GONE,
        "the item vanished in a rebuild — the client refetches"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_a_bad_at_or_op_is_400() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let bad_at = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"whenever"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(bad_at.status(), StatusCode::BAD_REQUEST);
    let bad_op = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"sideways","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(bad_op.status(), StatusCode::BAD_REQUEST);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_move_to_do_now_lifts_an_item_across_sections() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Book the annual check-up");

    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_do_now","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let (after, _) = today_snapshot(&st).await;
    let do_now = after["sections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "Do Now")
        .unwrap();
    assert!(
        do_now["items"][0]["lead"]
            .as_str()
            .unwrap()
            .starts_with("Book the annual check-up"),
        "it landed at the top of Do Now"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_moving_the_standing_lead_item_is_409() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "TOP PRIORITY");
    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_do_now","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CONFLICT,
        "the standing top-priority item is untouchable"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

/// THE RACE THIS FEATURE EXISTS FOR: a tap that lands while a turn holds the
/// write lock is journaled and parked, is visible to the app immediately, and is
/// applied to the file the instant that turn ends.
#[tokio::test]
async fn today_a_tap_during_a_turn_parks_reads_back_and_replays_at_turn_end() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let before = std::fs::read_to_string(&day).unwrap();

    // A turn takes the write lock on the day file, as its PreToolUse hook would.
    let held = st
        .broker
        .handle(HookRequest::Pre {
            turn: "turn-1".into(),
            conversation: "conv-1".into(),
            tool_use_id: "call-1".into(),
            target: Some(Some(day.to_string_lossy().into_owned())),
            git: false,
        })
        .await;
    assert!(held.allow, "the turn holds the day file's lock");

    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"evidence":"tapped mid-turn","at":"2026-03-03T09:30:00Z","client_tz":"UTC"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a tap must NEVER block on a running turn"
    );
    let posted: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(posted["pending"], true, "parked behind the turn");
    assert_eq!(
        std::fs::read_to_string(&day).unwrap(),
        before,
        "and the file is untouched while the turn owns it"
    );

    // READ-YOUR-WRITES: the app sees its own tap even though the file has not
    // changed, or the checkbox would visibly spring back open.
    let (during, _) = today_snapshot(&st).await;
    assert_eq!(
        item_state(&during, "Reply to Ada"),
        (true, Some("tapped mid-turn".to_string())),
        "the pending intent is merged into the snapshot"
    );

    // The turn now rewrites the file from the stale copy it read — the clobber.
    std::fs::write(&day, &before).unwrap();

    // Turn completion: the drop guard releases the locks and replays the journal.
    drop(TurnLockRelease {
        broker: st.broker.clone(),
        cfg: st.cfg.clone(),
        turn: "turn-1".to_string(),
        conversations: st.conversations.clone(),
    });

    let on_disk = std::fs::read_to_string(&day).unwrap();
    assert!(
        on_disk.contains("\t*(app-completed 2026-03-03 09:30: tapped mid-turn)*"),
        "the clobbered tap was re-applied at turn completion"
    );
    let (after, _) = today_snapshot(&st).await;
    assert_eq!(
        item_state(&after, "Reply to Ada"),
        (true, Some("tapped mid-turn".to_string()))
    );
    assert!(
        load_intents(&st.cfg.today_intents_file().unwrap()).is_empty(),
        "the verified intent was pruned"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

/// Two taps arriving together must both land. Without the internal mutex their
/// read-modify-write cycles interleave and one is silently lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn today_two_concurrent_taps_serialize_and_neither_is_lost() {
    let (st, vault) = today_write_state();
    let (snapshot, _) = today_snapshot(&st).await;
    let one = id_of(&snapshot, "Reply to Ada");
    let two = id_of(&snapshot, "Order the replacement thermocouple");

    // `If-Match: *` on purpose: the precondition is not what is under test here,
    // the mutex is. Both taps are admitted and must both survive.
    let a = tokio::spawn({
        let st = st.clone();
        let id = one.clone();
        async move {
            app(st)
                .oneshot(today_check_request(
                    Some("Bearer test-token"),
                    &id,
                    Some("*"),
                    r#"{"checked":true,"evidence":"tap A","at":"2026-03-03T09:30:00Z"}"#,
                ))
                .await
                .unwrap()
                .status()
        }
    });
    let b = tokio::spawn({
        let st = st.clone();
        let id = two.clone();
        async move {
            app(st)
                .oneshot(today_check_request(
                    Some("Bearer test-token"),
                    &id,
                    Some("*"),
                    r#"{"checked":true,"evidence":"tap B","at":"2026-03-03T09:31:00Z"}"#,
                ))
                .await
                .unwrap()
                .status()
        }
    });
    assert_eq!(a.await.unwrap(), StatusCode::OK);
    assert_eq!(b.await.unwrap(), StatusCode::OK);

    let (after, _) = today_snapshot(&st).await;
    assert_eq!(
        item_state(&after, "Reply to Ada"),
        (true, Some("tap A".to_string())),
        "tap A survived"
    );
    assert_eq!(
        item_state(&after, "Order the replacement thermocouple"),
        (true, Some("tap B".to_string())),
        "and so did tap B — neither read-modify-write clobbered the other"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_glance_marks_a_report_row_seen_under_a_date_scoped_key() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let unseen_before = snapshot["counts"]["reportsUnseen"].as_u64().unwrap();
    let report_id = snapshot["sections"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|s| s["reports"].as_array().unwrap().iter())
        .next()
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app(st.clone())
        .oneshot(today_glance_request(
            Some("Bearer test-token"),
            Some(&etag),
            &format!(r#"{{"id":"{report_id}","glancedAt":1772000000000}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let (after, _) = today_snapshot(&st).await;
    assert_eq!(
        after["counts"]["reportsUnseen"].as_u64().unwrap(),
        unseen_before - 1,
        "the row is seen now"
    );
    // Keyed by the SNAPSHOT's date, not by the bare id.
    let stored = std::fs::read_to_string(vault.join("state/glance.json")).unwrap();
    assert!(
        stored.contains(&format!("2026-03-03/{report_id}")),
        "the glance key is date-scoped: {stored}"
    );
    // The day file is never touched by a glance.
    assert_eq!(
        std::fs::read_to_string(vault.join("vault/Today.md")).unwrap(),
        FIX_TODAY_MD,
        "a glance writes no vault content at all"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- POST /jesse/today/items/{id}/defer — postponed for today --------------
//
// The second mutation that touches no vault content. What these pin is the part
// that makes postponement honest rather than a third checkbox state written into
// the day: the file is byte-identical afterwards, a lead item can be dismissed
// even though it can never be moved, and the flag is date-scoped so tomorrow
// carries none of it.

#[tokio::test]
async fn today_defer_flags_an_item_and_writes_no_markdown_at_all() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let before = std::fs::read_to_string(&day).unwrap();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"deferred":true,"atMs":1772000000000}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(
        deferred_state(&body, "Reply to Ada"),
        "the response is the whole fresh snapshot, with the item flagged"
    );

    // THE POINT OF THE WHOLE DESIGN: not one byte of the day file changed.
    assert_eq!(
        std::fs::read_to_string(&day).unwrap(),
        before,
        "postponing is client state about one day, never a markdown edit"
    );
    // And it is date-scoped, in its own store beside the glance store.
    let stored = std::fs::read_to_string(vault.join("state/defer.json")).unwrap();
    assert!(
        stored.contains(&format!("2026-03-03/{id}")),
        "the defer key is date-scoped: {stored}"
    );

    // A fresh GET carries the flag too, so it survives a relaunch.
    let (after, after_etag) = today_snapshot(&st).await;
    assert!(deferred_state(&after, "Reply to Ada"));

    // Toggling back clears it.
    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            Some(&after_etag),
            r#"{"deferred":false,"atMs":1772000001000}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let (back, _) = today_snapshot(&st).await;
    assert!(!deferred_state(&back, "Reply to Ada"));
    assert_eq!(std::fs::read_to_string(&day).unwrap(), before);

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_defer_accepts_the_lead_item_that_no_move_can_touch() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "TOP PRIORITY");

    // The same item, through the two endpoints: move refuses it structurally,
    // defer must not — it counts toward the badge, so it has to be dismissible
    // without ticking off work that was not done.
    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_do_now","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"deferred":true,"atMs":1772000000000}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["leadItems"][0]["deferred"].as_bool().unwrap());

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_defer_is_404_for_an_id_that_is_not_in_the_day() {
    let (st, vault) = today_write_state();
    let (_, etag) = today_snapshot(&st).await;
    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            "deadbeef1234",
            Some(&etag),
            r#"{"deferred":true,"atMs":1772000000000}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_defer_needs_a_bearer_and_a_fresh_if_match() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let body = r#"{"deferred":true,"atMs":1772000000000}"#;

    let resp = app(st.clone())
        .oneshot(today_defer_request(None, &id, Some(&etag), body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            None,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PRECONDITION_REQUIRED);

    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            Some("\"stale\""),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PRECONDITION_FAILED);
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- POST …/move with op: to_section ---------------------------------------

#[tokio::test]
async fn today_move_to_section_carries_an_item_out_of_do_now() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_section","section":"Errands","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let (after, _) = today_snapshot(&st).await;
    let errands = section_leads(&after, "Errands");
    assert!(
        errands[0].starts_with("Reply to Ada"),
        "it lands at the TOP of the destination, got {errands:?}"
    );
    assert!(
        !section_leads(&after, "Do Now")
            .iter()
            .any(|l| l.starts_with("Reply to Ada")),
        "and it left Do Now"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_move_to_section_rejects_a_missing_or_unknown_destination() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    for body in [
        r#"{"op":"to_section","at":"2026-03-03T09:30:00Z"}"#,
        r#"{"op":"to_section","section":"","at":"2026-03-03T09:30:00Z"}"#,
        r#"{"op":"to_section","section":"   ","at":"2026-03-03T09:30:00Z"}"#,
    ] {
        let resp = app(st.clone())
            .oneshot(today_move_request(
                Some("Bearer test-token"),
                &id,
                Some(&etag),
                body,
            ))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "to_section without a destination is a client mistake: {body}"
        );
        assert!(
            body_string(resp).await.contains("section"),
            "and the message names the field"
        );
    }

    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_section","section":"Someday Maybe","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_move_to_section_into_its_own_section_writes_nothing() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let before = std::fs::read_to_string(&day).unwrap();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_section","section":"Do Now","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "a no-op still answers 200");
    assert_eq!(
        std::fs::read_to_string(&day).unwrap(),
        before,
        "and writes nothing at all"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_move_to_section_on_the_lead_item_is_409() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "TOP PRIORITY");
    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"to_section","section":"Errands","at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CONFLICT,
        "the lead block stays structurally immovable, new op or not"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- The day guard (`day` on the three mutation bodies) --------------------
//
// What these pin is the one thing that makes an OFFLINE CAPTURE QUEUE safe to
// replay. `Today.md` is rewritten in full every morning and an item id is a content
// hash over `(section, lead, added date)`, so a tap captured yesterday can still
// RESOLVE today — against a line the person never saw. An `If-Match` does not close
// that: a replaying client has just refetched, so its tag is perfectly current and
// perfectly about the wrong day.
//
// So the client says which day it meant. When the file has moved on, the answer is a
// `409` carrying a machine-readable reason, and NOTHING is touched.

#[tokio::test]
async fn today_check_carries_the_requests_own_time_not_the_servers() {
    // THE REPLAY GUARANTEE. A tap captured at 07:05 and sent hours later must be
    // written into the vault as 07:05 — the stamp records when the USER acted, and
    // the morning routine reads these lines when it decides what to carry over.
    //
    // Evidence is what makes the stamp VISIBLE (a bare check writes no sub-line at
    // all — see `apply_check`), so both requests carry a note.
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T07:05:00Z","day":"2026-03-03",
                "evidence":"sent the date to Ada","client_tz":"Europe/London"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let written = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
    assert!(
        written.contains("*(app-completed 2026-03-03 07:05"),
        "the sub-line renders the request's own `at`, never the bridge's clock: {written}"
    );

    // ...and it renders in the EFFECTIVE zone, so a replay sent from another country
    // still lands on the wall clock the person was looking at. Same instant, one hour
    // later on the continent.
    let (snapshot, etag) = today_snapshot(&st).await;
    let other = id_of(&snapshot, "Order the replacement thermocouple");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &other,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T07:05:00Z","day":"2026-03-03",
                "evidence":"ordered two","client_tz":"Europe/Rome"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let written = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
    assert!(
        written.contains("*(app-completed 2026-03-03 08:05"),
        "the same instant, stamped in the zone the request named: {written}"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_check_refuses_a_day_that_moved_on_and_writes_nothing() {
    let (st, vault) = today_write_state();
    let day_file = vault.join("vault/Today.md");
    let before = std::fs::read_to_string(&day_file).unwrap();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    // A CURRENT etag — this is the case `If-Match` cannot catch, and the whole
    // reason the guard exists.
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-02T21:40:00Z","day":"2026-03-02"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["reason"], "day-mismatch");
    assert_eq!(
        body["live_date"], "2026-03-03",
        "the refusal names the day the file actually is, so the client can say so"
    );

    assert_eq!(
        std::fs::read_to_string(&day_file).unwrap(),
        before,
        "a refused replay touches not one byte of the day"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_check_with_the_live_day_is_applied_exactly_as_one_without() {
    // The guard must be INERT on the happy path: same day named, same outcome as the
    // request that names none at all.
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z","day":"2026-03-03"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(item_state(&body, "Reply to Ada").0, "the box is ticked");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_move_refuses_a_day_that_moved_on() {
    let (st, vault) = today_write_state();
    let day_file = vault.join("vault/Today.md");
    let before = std::fs::read_to_string(&day_file).unwrap();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_move_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"op":"top_of_section","at":"2026-03-02T21:40:00Z","day":"2026-03-02"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["reason"], "day-mismatch");
    assert_eq!(
        std::fs::read_to_string(&day_file).unwrap(),
        before,
        "nothing was reordered"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn today_defer_refuses_a_day_that_moved_on_and_records_nothing() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");

    let resp = app(st.clone())
        .oneshot(today_defer_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"deferred":true,"atMs":1772000000000,"day":"2026-03-02"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["reason"], "day-mismatch");

    // The defer store writes no vault markdown, so "nothing happened" is proved by
    // the store file rather than by the day file.
    assert!(
        !vault.join("state/defer.json").exists(),
        "a refused postponement records no claim"
    );
    let (after, _) = today_snapshot(&st).await;
    assert!(!deferred_state(&after, "Reply to Ada"));
    let _ = std::fs::remove_dir_all(&vault);
}

/// Whether one item of a snapshot body is flagged postponed.
fn deferred_state(snapshot: &Value, lead_starts: &str) -> bool {
    let mut items: Vec<&Value> = snapshot["leadItems"].as_array().unwrap().iter().collect();
    for section in snapshot["sections"].as_array().unwrap() {
        items.extend(section["items"].as_array().unwrap().iter());
    }
    items
        .iter()
        .find(|i| {
            i["lead"]
                .as_str()
                .unwrap_or_default()
                .starts_with(lead_starts)
        })
        .unwrap_or_else(|| panic!("no item starting {lead_starts:?}"))["deferred"]
        .as_bool()
        .unwrap()
}

/// The leads of one section's items, in file order.
fn section_leads(snapshot: &Value, name: &str) -> Vec<String> {
    snapshot["sections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == name)
        .unwrap_or_else(|| panic!("section {name:?} missing"))["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["lead"].as_str().unwrap_or_default().to_string())
        .collect()
}

/// THE OTHER HALF OF THE RACE, and the one a lock cannot catch: a turn spends
/// almost all of its life holding NO lock. It read the file early, is thinking,
/// and writes minutes later from the copy it holds. A tap in that window is
/// applied immediately — correctly — and the turn's eventual write still
/// clobbers it. The intent has to OUTLIVE its own apply for that to be repaired.
///
/// Found by a manual test against the deployed bridge, where the tap landed
/// while the turn was thinking rather than writing, and the intent had already
/// been pruned by the time the clobber came.
#[tokio::test]
async fn today_a_tap_applied_while_a_turn_thinks_is_repaired_after_the_turn_clobbers_it() {
    let (st, vault) = today_write_state();
    let day = vault.join("vault/Today.md");
    let journal = st.cfg.today_intents_file().unwrap();

    // A turn is IN FLIGHT but holds no lock — it has read the file and is
    // thinking. This is the state the broker cannot see.
    let _flight =
        st.conversations
            .claim_flight("job-1", "conv-1", Default::default(), 1_772_000_000_000);
    let stale_copy = std::fs::read_to_string(&day).unwrap();

    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"evidence":"tapped while thinking","at":"2026-03-03T09:30:00Z","client_tz":"UTC"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let posted: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(
        posted["pending"], false,
        "no lock is held, so it applies immediately rather than parking"
    );
    assert!(
        std::fs::read_to_string(&day)
            .unwrap()
            .contains("tapped while thinking"),
        "and it really is in the file"
    );
    assert_eq!(
        load_intents(&journal).len(),
        1,
        "THE FIX: the intent is RETAINED while a turn is in flight, because that \
         turn's write has not landed yet"
    );

    // The turn now writes back the copy it read before the tap. The clobber.
    std::fs::write(&day, &stale_copy).unwrap();
    assert!(!std::fs::read_to_string(&day)
        .unwrap()
        .contains("tapped while thinking"));

    // That turn ends. Its flight claim drops first (locals drop in reverse), so
    // replay sees nothing in flight and both repairs and prunes.
    drop(_flight);
    drop(TurnLockRelease {
        broker: st.broker.clone(),
        cfg: st.cfg.clone(),
        turn: "job-1".to_string(),
        conversations: st.conversations.clone(),
    });

    assert!(
        std::fs::read_to_string(&day)
            .unwrap()
            .contains("\t*(app-completed 2026-03-03 09:30: tapped while thinking)*"),
        "the clobbered tap was repaired at turn completion"
    );
    assert!(
        load_intents(&journal).is_empty(),
        "and pruned now that nothing is in flight to clobber it again"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

/// With nothing in flight the journal must go straight back to empty, or every
/// GET would pay to re-apply a growing pile of already-applied intents.
#[tokio::test]
async fn today_a_tap_with_no_turn_running_leaves_the_journal_empty() {
    let (st, vault) = today_write_state();
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"at":"2026-03-03T09:30:00Z"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        load_intents(&st.cfg.today_intents_file().unwrap()).is_empty(),
        "a spent intent is not kept: nothing is running that could clobber it"
    );
    let _ = std::fs::remove_dir_all(&vault);
}

// ---- The artifact return channel -------------------------------------------
//
// The staging directory, the sweep, the wire sidecar and the fetch route, driven
// end-to-end through the real router with a fake `claude` that writes files exactly
// where the prompt tells it to.

/// A state whose vault and state dir are both fresh temp dirs, so the channel is armed
/// (a store exists) and the staging directory has a working directory to live in.
/// Returns the state plus both paths, which the caller removes.
fn artifact_state(script: &str) -> (AppState, std::path::PathBuf, std::path::PathBuf) {
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let vault = std::env::temp_dir().join(format!("jesse-art-vault-{}-{n}", std::process::id()));
    let state_dir =
        std::env::temp_dir().join(format!("jesse-art-state-{}-{n}", std::process::id()));
    std::fs::create_dir_all(&vault).unwrap();
    std::fs::create_dir_all(&state_dir).unwrap();
    let fake = write_fake_claude(script);
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        ..test_config()
    };
    (AppState::new(cfg), vault, state_dir)
}

/// A fake `claude` that writes `files` into whatever staging directory the turn made,
/// then answers. It finds the directory by GLOB rather than by parsing the prompt, which
/// keeps the script trivial and still proves the directory is (a) there, (b) inside the
/// child's cwd, and (c) writable by the child.
fn artifact_script(files: &[(&str, &str)]) -> String {
    let mut s = String::from(
        "#!/bin/sh\n\
         dir=$(ls -d .jesse-artifacts/*/ 2>/dev/null | head -1)\n\
         if [ -z \"$dir\" ]; then \
             printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"NO STAGING DIR\"}'; \
             exit 0; \
         fi\n",
    );
    for (name, body) in files {
        s.push_str(&format!("printf '%b' '{body}' > \"$dir/{name}\"\n"));
    }
    s.push_str(
        "printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"here they are\"}'\n",
    );
    s
}

/// A minimal but genuinely valid PNG header, as a `printf '%b'` escape string.
///
/// OCTAL, not hex, and that is not a style choice: `\xNN` is a bash extension. Under
/// Linux's `/bin/sh` (dash) `printf '%b'` emits the six characters `\x89` literally, so
/// the "PNG" the fake harness wrote was plain text — which the sniffer correctly refused
/// to call an image, failing this suite on CI while passing on macOS. `\0ddd` is what
/// POSIX specifies for `%b` and it behaves identically on both.
const PNG_ESCAPES: &str = "\\0211PNG\\015\\012\\032\\012\\000\\000\\000\\015IHDR";

/// THE END-TO-END CASE: a turn writes two files, both come back on the reply, and both
/// are fetchable by id.
#[tokio::test]
async fn artifacts_a_turn_that_writes_two_files_returns_them_both() {
    let (st, vault, state_dir) = artifact_state(&artifact_script(&[
        ("chart.png", PNG_ESCAPES),
        ("data.csv", "a,b\\n1,2\\n"),
    ]));

    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"tell","text":"make me a chart"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;

    assert_eq!(
        done["response"].as_str().unwrap(),
        "here they are",
        "nothing was appended: no file was dropped, so there is no note"
    );
    let arts = done["artifacts"]
        .as_array()
        .expect("the sidecar is present");
    assert_eq!(arts.len(), 2, "both files came back: {arts:?}");
    // Stable order: the staging dir is swept sorted by name.
    assert_eq!(arts[0]["filename"], "chart.png");
    assert_eq!(arts[0]["mime"], "image/png");
    assert_eq!(arts[1]["filename"], "data.csv");
    assert_eq!(arts[1]["mime"], "text/csv");
    // NEVER THE BYTES. This is the whole point of the design.
    for a in arts {
        assert!(a.get("data").is_none() && a.get("data_base64").is_none());
        assert!(a["sha256"].as_str().unwrap().len() == 64);
    }

    // The staging directory is GONE — the turn left nothing inside the working dir.
    assert!(
        !vault.join(".jesse-artifacts").join(&job_id).exists(),
        "the per-job staging dir is removed when the turn ends"
    );

    // …and the bytes are fetchable, with the recorded mime and a hash ETag.
    let id = arts[0]["id"].as_str().unwrap();
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/jesse/artifact/{id}"))
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(resp.headers()["content-type"], "image/png");
    assert_eq!(resp.headers()["x-content-type-options"], "nosniff");
    let etag = resp.headers()["etag"].to_str().unwrap().to_string();
    assert_eq!(etag, format!("\"{}\"", arts[0]["sha256"].as_str().unwrap()));
    assert!(resp.headers()["content-disposition"]
        .to_str()
        .unwrap()
        .starts_with("attachment; filename=\"chart.png\""));
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "the real bytes");

    // A re-fetch under the same ETag costs one empty 304.
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/jesse/artifact/{id}"))
                .header("authorization", "Bearer test-token")
                .header("if-none-match", &etag)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_MODIFIED);

    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// A turn that returns nothing is byte-for-byte the turn it has always been: no
/// `artifacts` on the wire, and nothing appended to the reply.
#[tokio::test]
async fn artifacts_a_turn_that_writes_nothing_carries_no_sidecar() {
    let (st, vault, state_dir) = artifact_state(
        "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"just words\"}'\n",
    );
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"hello"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;
    assert_eq!(done["response"], "just words");
    assert!(
        done["artifacts"].is_null(),
        "an empty sidecar is null, exactly as it was before the field existed"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// A rejected file is NEVER SILENT: it comes back as a line in the reply, and the good
/// file beside it still returns.
#[tokio::test]
async fn artifacts_a_rejected_file_is_reported_in_the_reply() {
    let (st, vault, state_dir) = artifact_state(&artifact_script(&[
        ("01-bad.zip", "PK\\003\\004\\000\\000\\000\\000"),
        ("02-good.png", PNG_ESCAPES),
    ]));
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"tell","text":"zip it"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;
    let text = done["response"].as_str().unwrap();
    assert!(
        text.starts_with("here they are"),
        "the model's own answer is untouched: {text:?}"
    );
    assert!(
        text.contains("01-bad.zip") && text.contains("does not carry"),
        "the user is TOLD what was dropped: {text:?}"
    );
    assert_eq!(
        done["artifacts"].as_array().unwrap().len(),
        1,
        "and the good file still came back"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// A turn below `Capability::Write` gets no staging directory, so its model is never
/// told about a channel it cannot use. Asserted through the CHILD: the fake reports
/// whether the directory existed.
#[tokio::test]
async fn artifacts_a_read_level_turn_gets_no_staging_directory() {
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let vault = std::env::temp_dir().join(format!("jesse-art-ro-{}-{n}", std::process::id()));
    let state_dir = std::env::temp_dir().join(format!("jesse-art-ros-{}-{n}", std::process::id()));
    std::fs::create_dir_all(&vault).unwrap();
    std::fs::create_dir_all(&state_dir).unwrap();
    let fake = write_fake_claude(
        "#!/bin/sh\n\
         if ls -d .jesse-artifacts/*/ >/dev/null 2>&1; then r=STAGED; else r=NONE; fi\n\
         printf '{\"type\":\"result\",\"is_error\":false,\"result\":\"%s\"}' \"$r\"\n",
    );
    // A registry whose only model is READ level, and which is the default.
    let mut registry = ModelRegistry::opus_only();
    registry.models[0].level = Capability::Read;
    let cfg = Config {
        claude_bin: fake.to_string_lossy().into_owned(),
        vault: vault.to_string_lossy().into_owned(),
        state_dir: Some(state_dir.to_string_lossy().into_owned()),
        model_registry: registry,
        ..test_config()
    };
    let st = AppState::new(cfg);
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"read only"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;
    assert_eq!(
        done["response"], "NONE",
        "a turn that cannot write must not be offered an artifact channel"
    );
    assert!(done["artifacts"].is_null());
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// THE TRAVERSAL GUARD and the two shapes of 404, on the live route.
#[tokio::test]
async fn artifacts_the_fetch_route_guards_its_id_and_distinguishes_its_misses() {
    let (st, vault, state_dir) = artifact_state(&artifact_script(&[("c.png", PNG_ESCAPES)]));
    let fetch = |st: AppState, id: String, auth: bool| async move {
        let mut b = Request::builder().uri(format!("/jesse/artifact/{id}"));
        if auth {
            b = b.header("authorization", "Bearer test-token");
        }
        app(st)
            .oneshot(b.body(Body::empty()).unwrap())
            .await
            .unwrap()
    };

    // No token: the same bearer auth as every other route, checked before anything else.
    assert_eq!(
        fetch(st.clone(), "abc123".into(), false).await.status(),
        StatusCode::UNAUTHORIZED
    );
    // A non-hex id never reaches the filesystem.
    for bad in ["..", "%2e%2e", "not-hex", "ABCDEF", ""] {
        let resp = fetch(st.clone(), bad.to_string(), true).await;
        assert!(
            matches!(
                resp.status(),
                StatusCode::BAD_REQUEST | StatusCode::NOT_FOUND
            ),
            "{bad:?} must never be served: {}",
            resp.status()
        );
    }
    // A well-formed id that was never stored: UNKNOWN.
    let resp = fetch(st.clone(), "00112233445566ff".into(), true).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["reason"], "unknown");

    // Now store one, delete its conversation, and fetch again: EXPIRED, which the app
    // renders differently.
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"tell","text":"chart please"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let conversation_id = body["conversation_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;
    let id = done["artifacts"][0]["id"].as_str().unwrap().to_string();
    assert_eq!(
        fetch(st.clone(), id.clone(), true).await.status(),
        StatusCode::OK
    );

    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/jesse/conversation/{conversation_id}"))
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let resp = fetch(st.clone(), id, true).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(
        body["reason"], "expired",
        "the cascade tombstones it — 'gone because you deleted it' is not 'never existed'"
    );
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// A reloaded transcript still shows an older turn's artifacts. Hydration has no job id
/// to bind on, so this is the assertion that the text binding actually works end to end.
#[tokio::test]
async fn artifacts_survive_a_hydrate_of_the_conversation() {
    let (st, vault, state_dir) = artifact_state(&artifact_script(&[("c.png", PNG_ESCAPES)]));
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"tell","text":"chart please"}"#,
        ))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();
    let conversation_id = body["conversation_id"].as_str().unwrap().to_string();
    let done = wait_for_status(&st, &job_id, "done").await;
    let id = done["artifacts"][0]["id"].as_str().unwrap().to_string();

    // The fake `claude` writes no transcript, so hydration returns an empty turn list —
    // which is the documented degradation, and means the binding cannot be asserted
    // through the route here. Assert it directly against the function instead, with the
    // hydrated turn the transcript WOULD have produced (the delivered text).
    let mut turns = vec![
        HydratedTurn {
            role: "user".into(),
            text: "chart please".into(),
            timestamp: None,
            turn_key: None,
            artifacts: Vec::new(),
        },
        HydratedTurn {
            role: "assistant".into(),
            text: "here they are".into(),
            timestamp: None,
            turn_key: None,
            artifacts: Vec::new(),
        },
    ];
    attach_artifacts(&mut turns, &st.artifacts.for_conversation(&conversation_id));
    assert!(turns[0].artifacts.is_empty(), "never on a user turn");
    assert_eq!(turns[1].artifacts.len(), 1, "re-attached to its own reply");
    assert_eq!(turns[1].artifacts[0].id, id);

    // A turn whose text does not match gets nothing — the binding is the text, not
    // "whatever the conversation has".
    let mut other = vec![HydratedTurn {
        role: "assistant".into(),
        text: "something else entirely".into(),
        timestamp: None,
        turn_key: None,
        artifacts: Vec::new(),
    }];
    attach_artifacts(&mut other, &st.artifacts.for_conversation(&conversation_id));
    assert!(other[0].artifacts.is_empty());

    // And the hydrate ROUTE serves the field without breaking (no transcript → no turns).
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/jesse/conversations/{conversation_id}/transcript"))
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let _ = std::fs::remove_dir_all(&vault);
    let _ = std::fs::remove_dir_all(&state_dir);
}

/// A job file written by an OLDER bridge — no `artifacts` key at all — loads cleanly and
/// serves its reply exactly as it always did.
#[tokio::test]
async fn artifacts_an_older_job_file_with_no_field_loads_cleanly() {
    let old = serde_json::json!({
        "v": 1,
        "job_id": "old-job",
        "status": "done",
        "response": "an answer from before this field existed",
        "session_id": "sess-1",
        "directives": Value::Null,
        "provenance": Value::Null,
        "error": Value::Null,
        "completed_at_ms": 1_700_000_000_000u64,
    });
    let (id, job) = value_to_job(&old).expect("an older job file still parses");
    assert_eq!(id, "old-job");
    match &job.state {
        JobState::Done {
            response,
            artifacts,
            ..
        } => {
            assert_eq!(response, "an answer from before this field existed");
            assert!(
                artifacts.is_empty(),
                "absent reads as none, never as an error"
            );
        }
        other => panic!(
            "expected Done, got {:?}",
            matches!(other, JobState::Running)
        ),
    }
    // …and re-serializing it emits the field as null, so a NEWER app decoding it sees
    // exactly what it sees for any turn that returned nothing.
    let v = job_to_value(&id, &job).expect("serializes");
    assert!(v["artifacts"].is_null());
}

// ---- The away profile: the endpoints, and what `client_tz` moves ------------

/// `POST /jesse/profile` with a JSON body.
fn profile_post(auth: Option<&str>, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse/profile")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(body.to_string())).unwrap()
}

fn profile_get(auth: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method("GET").uri("/jesse/profile");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}

async fn post_profile(st: &AppState, body: &str) -> (StatusCode, String) {
    let resp = app(st.clone())
        .oneshot(profile_post(Some("Bearer test-token"), body))
        .await
        .unwrap();
    let status = resp.status();
    (status, body_string(resp).await)
}

/// An RFC 3339 instant a good way into the future, so these tests never rot.
fn far_future() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 14 * 86_400_000;
    chrono::DateTime::from_timestamp_millis(ms)
        .unwrap()
        .to_rfc3339()
}

#[tokio::test]
async fn profile_endpoints_require_auth() {
    let st = test_state();
    assert_eq!(
        app(st.clone())
            .oneshot(profile_get(None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app(st.clone())
            .oneshot(profile_post(None, r#"{"name":"home"}"#))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
}

/// A bridge nobody has told anything is HOME, and says so — rather than 404ing because the
/// interesting case is absent.
#[tokio::test]
async fn a_bridge_with_no_profile_reports_home() {
    let st = test_state();
    let resp = app(st.clone())
        .oneshot(profile_get(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["name"], "home");
    assert_eq!(body["effective"], false);
    assert_eq!(body["until_ms"], Value::Null);
    assert_eq!(body["note"], "");
    assert_eq!(
        body["tz"], body["process_tz"],
        "with nothing in force the effective zone IS the process zone"
    );
}

/// EVERY WAY OF GETTING `away` WRONG IS A 400 THAT NAMES THE FIELD.
#[tokio::test]
async fn setting_away_validates_the_zone_the_deadline_and_the_note() {
    let st = test_state();
    let future = far_future();

    // An unknown profile name.
    let (status, body) = post_profile(&st, r#"{"name":"holiday"}"#).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("holiday"), "{body}");

    // A zone this tz database does not know — refused rather than half-honoured, because a
    // bridge reporting "away" while deriving host-zone dates is the one wrong answer that
    // looks right.
    let (status, body) = post_profile(
        &st,
        &format!(r#"{{"name":"away","tz":"Mars/Olympus","until":"{future}"}}"#),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("IANA"), "{body}");

    // A missing zone.
    let (status, _) = post_profile(&st, &format!(r#"{{"name":"away","until":"{future}"}}"#)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A deadline that is not RFC 3339.
    let (status, body) = post_profile(
        &st,
        r#"{"name":"away","tz":"Europe/London","until":"next Tuesday"}"#,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("RFC 3339"), "{body}");

    // A deadline in the PAST — an away profile expires by itself, so it must end later
    // than it starts.
    let (status, body) = post_profile(
        &st,
        r#"{"name":"away","tz":"Europe/London","until":"2020-01-01T00:00:00Z"}"#,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("in the past"), "{body}");

    // A note past the cap — it rides on every prompt, so it is a label, not a paragraph.
    let long = "x".repeat(81);
    let (status, body) = post_profile(
        &st,
        &format!(r#"{{"name":"away","tz":"Europe/London","until":"{future}","note":"{long}"}}"#),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("81"), "{body}");

    // Nothing above changed anything.
    let resp = app(st.clone())
        .oneshot(profile_get(Some("Bearer test-token")))
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(
        body["name"], "home",
        "a rejected POST must leave the store alone"
    );
}

/// The round trip: away, seen everywhere, then home again.
#[tokio::test]
async fn an_away_profile_round_trips_through_the_endpoint_the_schedule_and_health() {
    let st = test_state();
    let future = far_future();
    let (status, body) = post_profile(
        &st,
        &format!(r#"{{"name":"away","tz":"Europe/London","until":"{future}","note":"Scotland"}}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let body: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(body["name"], "away");
    assert_eq!(body["tz"], "Europe/London");
    assert_eq!(body["note"], "Scotland");
    assert_eq!(body["effective"], true);
    assert!(body["until_ms"].as_u64().is_some());
    assert_eq!(body["returned_ms"], Value::Null, "the return is still owed");
    assert_ne!(
        body["process_tz"], "Europe/London",
        "the fixture host is not in London, which is what makes this test mean anything"
    );

    // `GET /health` carries it, so the phone and the sentinel see it without a second call.
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let health: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(health["profile"]["name"], "away");
    assert_eq!(health["profile"]["tz"], "Europe/London");
    assert!(health["profile"]["until_ms"].as_u64().is_some());

    // …and so does `GET /jesse/schedule`, whose every fire time it reinterprets.
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri("/jesse/schedule")
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let sched: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(sched["profile"]["name"], "away");
    assert_eq!(
        sched["tz"], "Europe/London",
        "the SCHEDULER's zone moved too"
    );

    // Home again, early.
    let (status, body) = post_profile(&st, r#"{"name":"home"}"#).await;
    assert_eq!(status, StatusCode::OK);
    let body: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(body["name"], "home");
    assert_eq!(body["effective"], false);
    assert_eq!(
        body["tz"], body["process_tz"],
        "dates are derived in the host's zone again"
    );
    // The record is KEPT, ended rather than erased, because `on_return` must still fire.
    assert!(
        body["since_ms"].as_u64().is_some(),
        "the ended period is still on record: {body}"
    );

    // `/health` agrees immediately.
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let health: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(health["profile"]["name"], "home");
}

/// An unauthenticated `/health` must not gain a new field that says where its owner is.
#[tokio::test]
async fn health_does_not_leak_the_profile_to_an_unauthenticated_caller() {
    let st = test_state();
    let future = far_future();
    post_profile(
        &st,
        &format!(r#"{{"name":"away","tz":"Europe/London","until":"{future}","note":"Scotland"}}"#),
    )
    .await;
    let resp = app(st.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(
        body.get("profile").is_none(),
        "where the owner is is operator detail: {body}"
    );
}

/// A `client_tz` naming a zone the tz database does not know must not fail the request —
/// a stale app build has to be able to tick a checkbox.
#[tokio::test]
async fn an_unparseable_client_tz_is_ignored_rather_than_refused() {
    let (st, vault) = today_state();
    let day = vault.join("vault/Today.md");
    let (snapshot, etag) = today_snapshot(&st).await;
    let id = id_of(&snapshot, "Reply to Ada");
    let resp = app(st.clone())
        .oneshot(today_check_request(
            Some("Bearer test-token"),
            &id,
            Some(&etag),
            r#"{"checked":true,"evidence":"tapped","at":"2026-03-03T09:30:00Z","client_tz":"Mars/Olympus"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "the tap still lands");
    assert!(std::fs::read_to_string(&day)
        .unwrap()
        .contains("app-completed 2026-03-03 "));
}

/// THE STAMP FOLLOWS THE CLIENT'S ZONE. The same UTC instant is two different dates in two
/// zones, and what goes into the vault is the wall clock the person was looking at.
#[tokio::test]
async fn the_app_completed_stamp_is_written_in_the_client_zone() {
    for (tz, expected) in [
        ("Europe/London", "2026-03-03 23:30"),
        ("Europe/Rome", "2026-03-04 00:30"),
        ("America/New_York", "2026-03-03 18:30"),
    ] {
        let (st, vault) = today_state();
        let day = vault.join("vault/Today.md");
        let (snapshot, etag) = today_snapshot(&st).await;
        let id = id_of(&snapshot, "Reply to Ada");
        let resp = app(st.clone())
            .oneshot(today_check_request(
                Some("Bearer test-token"),
                &id,
                Some(&etag),
                &format!(
                    r#"{{"checked":true,"evidence":"tapped","at":"2026-03-03T23:30:00Z","client_tz":"{tz}"}}"#
                ),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let on_disk = std::fs::read_to_string(&day).unwrap();
        assert!(
            on_disk.contains(&format!("app-completed {expected}:")),
            "{tz} must stamp {expected}, got:\n{on_disk}"
        );
    }
}

/// THE DIET PAGE'S DEFAULT DAY, when the vault file does not name one, comes from the
/// EFFECTIVE zone — because at 23:30 in London it is already tomorrow in Rome, and paging
/// the owner to a day that has not started where they are standing is the whole bug.
///
/// Pinned with two zones that are 25 hours apart, so they are on different calendar dates
/// at every instant. Asserting "23:30 London on a Rome host" directly would need the wall
/// clock frozen, which this path (a `date` child) does not offer — the property is the
/// same one either way.
#[tokio::test]
async fn the_diet_default_date_follows_the_client_zone_when_the_vault_names_none() {
    let vault = make_diet_vault();
    // The same fixture with its `date` key removed: the file no longer names a day, so the
    // clock is the fallback. (With a date present the FILE wins — it is the authority on
    // which day the page is for, and a clock date would serve a day the data is not.)
    write_vault_file(
        &vault,
        "vault/diet-today.js",
        "window.DIET_TODAY = {\n  dayStyle: 'normal',\n  meals: [],\n};\n",
    );
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let st = AppState::new(Config {
        vault: vault.to_string_lossy().into_owned(),
        ..test_config()
    });

    let day_in = |tz: &str| {
        let st = st.clone();
        let tz = tz.to_string();
        async move {
            let resp = app(st)
                .oneshot(
                    Request::builder()
                        .method("GET")
                        .uri(format!("/jesse/diet?client_tz={tz}"))
                        .header("authorization", "Bearer test-token")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
            body["availableDays"]
                .as_array()
                .unwrap()
                .last()
                .unwrap()
                .as_str()
                .unwrap()
                .to_string()
        }
    };

    // +14 and -11: never the same calendar date, at any instant.
    let east = day_in("Pacific/Kiritimati").await;
    let west = day_in("Pacific/Niue").await;
    assert_ne!(
        east, west,
        "the default day must come from the requesting zone, not the host's"
    );
    let _ = std::fs::remove_dir_all(&vault);
}
