//! Integration tests: exercise the real Axum router via
//! `tower::ServiceExt::oneshot`, no socket bound. These drive the same
//! `app()` the running server uses.
#![allow(clippy::collapsible_if)]
mod common;
use common::*;
use jesse_bridge::*;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tower::ServiceExt;

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
        assert!(body.get("vault").is_none(), "vault path must not leak unauthenticated");
        assert!(body.get("claude").is_none(), "claude path must not leak unauthenticated");
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
        // The exact const strings build_prompt applies, so the app's "default"
        // matches what the bridge would use for a fresh turn.
        assert_eq!(body["ask"], ASK_PREAMBLE);
        assert_eq!(body["tell"], TELL_PREAMBLE);
        // The fixed safety floors are exposed too, so the app can show them read-only.
        assert_eq!(body["ask_floor"], ASK_FLOOR);
        assert_eq!(body["tell_floor"], TELL_FLOOR);
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
        st1.jobs
            .complete(&id, Ok(("survives reboot".to_string(), Some("sess-r".to_string()), None)));
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
        st.jobs
            .complete(&id, Ok(("keep me".to_string(), Some("sess-k".to_string()), None)));

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
            max_concurrency: 1,   // a freed slot is observable via available_permits
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
        assert_eq!(st.sem.available_permits(), 0, "running turn holds the permit");

        // Cancel it.
        let resp = app(st.clone())
            .oneshot(cancel_request(Some("Bearer test-token"), &job_id))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NO_CONTENT);

        // The abort drops the task asynchronously; wait for the permit to come back.
        let mut freed = false;
        for _ in 0..50 {
            if st.sem.available_permits() == 1 {
                freed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(freed, "aborting the turn must free its concurrency slot");

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
            // Generous run limit so CPU starvation under a fully-parallel test run
            // can't race the wall clock; the poll window below is what proves Done
            // comes from the result line (near-instant) and not the child exiting.
            timeout_secs: 20,
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

        // Poll up to ~3s — far under the 20s run limit. Completion is driven by
        // the result line (near-instant), so `done` lands well inside this window;
        // if completion still waited on child stdout EOF the turn would sit
        // `running` for the full 20s and this window would expire with no `done`.
        let mut done = None;
        for _ in 0..60 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let v = result_status(&st, &job_id).await;
            if v["status"] == "done" {
                done = Some(v);
                break;
            }
        }
        let done =
            done.expect("turn must reach done on the result line, not block on child stdout EOF");
        assert_eq!(done["response"], "the answer");
        assert_eq!(done["session_id"], "sess-rl");

        let _ = std::fs::remove_file(&fake);
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
        let mut done = false;
        for _ in 0..60 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            if result_status(&st, &job_id).await["status"] == "done" {
                done = true;
                break;
            }
        }
        assert!(done, "turn must complete");

        let prompt =
            std::fs::read_to_string(&promptfile).expect("fake claude must record the prompt");
        // The clock leads the whole wrapped prompt.
        let header = prompt.lines().next().expect("prompt must have a first line");
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
        let (head, offset) = rest.split_once(" (UTC").expect("header must carry a (UTC offset)");
        assert_eq!(offset.len(), 6, "offset must be ±HH:MM: {offset:?}");
        assert_eq!(offset.as_bytes()[3], b':', "offset must be colonized: {offset:?}");
        let parts: Vec<&str> = head.split(' ').collect();
        assert!(
            [
                "Monday,", "Tuesday,", "Wednesday,", "Thursday,", "Friday,", "Saturday,", "Sunday,"
            ]
            .contains(&parts[0]),
            "header must open with a weekday: {head:?}"
        );
        let year: i64 = parts[1].split('-').next().unwrap().parse().expect("year");
        assert!(year >= 2026, "clock must reflect the real current year: {year}");
        // The floor still follows the clock (it wasn't displaced).
        assert!(
            prompt.contains(ASK_FLOOR),
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
        let mut done = false;
        for _ in 0..60 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            if result_status(&st, &job_id).await["status"] == "done" {
                done = true;
                break;
            }
        }
        assert!(done, "turn must reach done on the result line");

        // Read the child's pid (written before it printed the result line).
        let pid: i32 = {
            let mut p = None;
            for _ in 0..20 {
                if let Ok(s) = std::fs::read_to_string(&pidfile) {
                    if let Ok(n) = s.trim().parse() {
                        p = Some(n);
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            p.expect("fake claude must record its pid")
        };

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
        assert!(sse.contains("event: delta"), "expected a live delta frame: {sse}");
        assert!(sse.contains("world"), "delta text missing: {sse}");
        assert!(sse.contains("event: done"), "expected a terminal done frame: {sse}");
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
            Ok(("the whole answer".to_string(), Some("sess-done".to_string()), None)),
        );

        let resp = app(st.clone())
            .oneshot(stream_request(Some("Bearer test-token"), &id))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let sse = body_string(resp).await;
        assert!(sse.contains("event: reset"), "expected a full-text reset: {sse}");
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
        assert!(sse.contains("event: cancelled"), "expected a cancelled frame: {sse}");
        assert!(!sse.contains("event: error"), "cancel must not look like an error: {sse}");
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
        assert_eq!(resp.status(), StatusCode::ACCEPTED, "POST never holds — always 202");
        let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
        assert_eq!(body["status"], "running");
        let job_id = body["job_id"].as_str().expect("202 carries a job_id").to_string();

        // The detached turn finishes; the reply is retrievable by id.
        let mut done = None;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let v = result_status(&st, &job_id).await;
            if v["status"] == "done" {
                done = Some(v);
                break;
            }
        }
        let done = done.expect("a fast turn still lands in the job store, fetchable by id");
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
            max_concurrency: 1, // exactly one permit
            max_queued: 1,      // room for exactly one waiter
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
            let mut done = false;
            for _ in 0..60 {
                tokio::time::sleep(Duration::from_millis(50)).await;
                if result_status(&st, &job_id).await["status"] == "done" {
                    done = true;
                    break;
                }
            }
            assert!(done, "turn must complete");
            let prompt =
                std::fs::read_to_string(&promptfile).expect("fake claude must record the prompt");
            let _ = std::fs::remove_file(&fake);
            let _ = std::fs::remove_file(&promptfile);
            prompt
        }

        let block = "Swim — 2026-07-04 06:30, 30m, 1500m, 420 kcal, avg HR 132";
        // Present: the framed block appears verbatim after the clock, before the floor.
        let with = captured_prompt(
            &format!(r#"{{"mode":"ask","text":"log my swim","health_context":"{block}"}}"#),
        )
        .await;
        assert!(with.contains(HEALTH_CONTEXT_HEADER), "framing header present");
        assert!(with.contains(block), "block appears verbatim");
        let clock_end = with.find("\n\n").expect("clock line then blank line");
        let block_at = with.find(block).unwrap();
        let floor_at = with.find(ASK_FLOOR).unwrap();
        assert!(clock_end < block_at && block_at < floor_at, "clock < block < floor");

        // Absent: no framing header, no block — today's behavior.
        let without = captured_prompt(r#"{"mode":"ask","text":"log my swim"}"#).await;
        assert!(!without.contains(HEALTH_CONTEXT_HEADER), "no health block when field absent");
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
            .oneshot(device_request(Some("Bearer test-token"), r#"{"token":"deadbeefcafe"}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(st.devices.get().as_deref(), Some("deadbeefcafe"), "token stored");

        // Idempotent upsert: a second register overwrites.
        let resp = app(st.clone())
            .oneshot(device_request(Some("Bearer test-token"), r#"{"token":"newtoken99"}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(st.devices.get().as_deref(), Some("newtoken99"));
    }
    #[tokio::test]
    async fn device_register_rejects_empty_token() {
        let resp = app(test_state())
            .oneshot(device_request(Some("Bearer test-token"), r#"{"token":"   "}"#))
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
        st.jobs.complete(&id, Ok(("already done".to_string(), None, None)));

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
        assert!(!title.contains('\n'), "title must be a single line: {title:?}");
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
        let res = run_claude_oneshot(&cfg, "title this", 1).await;
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
        // child's 60s sleep ends.
        let script = "#!/bin/sh\n\
             printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"done fast\",\"session_id\":\"sess-h4\"}'\n\
             sleep 60\n";
        let fake = write_fake_claude(script);
        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
            max_concurrency: 1,
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

        // Within a few seconds (≪ the 60s sleep) the turn is Done and the permit
        // is back — proof the reap is bounded, not pinned by the lingering child.
        let mut done = false;
        for _ in 0..50 {
            if st.sem.available_permits() == 1 {
                if result_status(&st, &job_id).await["status"] == "done" {
                    done = true;
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(
            done,
            "turn must complete and free its permit without waiting for the child to exit"
        );
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
    for _ in 0..80 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if result_status(&st, &job_id).await["status"] == "done" {
            let _ = std::fs::remove_file(&fake);
            return (st, job_id);
        }
    }
    let _ = std::fs::remove_file(&fake);
    panic!("turn did not complete");
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
    assert_eq!(v["response"], "Here you go.", "directive line stripped from the reply");
    assert!(!v["response"].as_str().unwrap().contains("JESSE_NEEDS_HEALTH"));
    assert_eq!(v["directives"]["needs_health"]["sections"][0], "daily");
    assert_eq!(v["directives"]["needs_health"]["metrics"][0]["metric"], "restingHeartRate");
    assert_eq!(v["directives"]["needs_health"]["metrics"][0]["window_days"], 14);
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
    assert_eq!(v["response"], "", "a sentinel-only reply strips to empty text");
    assert_eq!(v["directives"]["needs_health"]["metrics"][0]["metric"], "heartRateVariabilitySDNN");
    // SSE (already-terminal path): the done frame's JSON data carries directives.
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(sse.contains("needs_health"), "done frame must carry directives: {sse}");
    assert!(sse.contains("heartRateVariabilitySDNN"), "metric name in done frame: {sse}");
}

#[tokio::test]
async fn unknown_directive_passes_through_visible_with_no_field() {
    // An unknown directive name is a loud contract failure: the line stays VISIBLE
    // in the reply and no `directives` field is attached. (Uses a name that is NOT
    // in the registry — both JESSE_NEEDS_HEALTH and JESSE_MEAL_LOG are known.)
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_FROBNICATE v1 {\"foo\":1}","session_id":"sess-unk"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log lunch"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "JESSE_FROBNICATE v1 {\"foo\":1}", "unknown directive stays visible");
    assert!(v["directives"].is_null(), "no directives for an unknown name");
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
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log lunch: spaghetti"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Logged your lunch.", "meal-log line stripped from the reply");
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
async fn meal_log_directive_is_extracted_on_the_sse_done_frame_consistently() {
    // The SSE `done` frame carries the SAME stripped text + meal_log as the poll —
    // the two terminal paths are kept byte-consistent (via directives_to_value).
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-snack\",\"consumedAt\":\"2026-07-04T15:00:00+02:00\",\"name\":\"Apple\"}]}","session_id":"sess-meal-sse"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log a snack"}"#, line).await;
    // Poll: sentinel-only reply strips to empty, meal_log attached.
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "", "a sentinel-only reply strips to empty text");
    assert_eq!(v["directives"]["meal_log"]["meals"][0]["id"], "2026-07-04-snack");
    // A macro that was omitted must be ABSENT on the wire (never null-padded).
    assert!(v["directives"]["meal_log"]["meals"][0].get("kcal").is_none());
    // SSE (already-terminal path): the done frame's JSON data carries meal_log.
    let resp = app(st.clone())
        .oneshot(stream_request(Some("Bearer test-token"), &job_id))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sse = body_string(resp).await;
    assert!(sse.contains("event: done"), "expected a done frame: {sse}");
    assert!(sse.contains("meal_log"), "done frame must carry meal_log: {sse}");
    assert!(sse.contains("2026-07-04-snack"), "meal id in done frame: {sse}");
}

#[tokio::test]
async fn meal_log_directive_carries_a_multi_meal_array() {
    // A single reply may log several meals — the array round-trips in order.
    let line = r#"{"type":"result","is_error":false,"result":"Logged both.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-breakfast\",\"consumedAt\":\"2026-07-04T08:00:00+02:00\",\"name\":\"Oatmeal\",\"kcal\":300},{\"id\":\"2026-07-04-lunch\",\"consumedAt\":\"2026-07-04T12:30:00+02:00\",\"name\":\"Salad\",\"kcal\":250}]}","session_id":"sess-multi"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log breakfast and lunch"}"#, line).await;
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
    assert_eq!(v["response"], "JESSE_MEAL_LOG v1 {\"meals\":[]}", "malformed meal-log stays visible");
    assert!(v["directives"].is_null(), "no directives for a malformed meal-log");
}

#[tokio::test]
async fn meal_log_v2_passes_through_visible() {
    // An unknown VERSION of a known directive must pass through untouched and
    // visible, so a future contract bump fails loudly instead of half-parsing.
    let line = r#"{"type":"result","is_error":false,"result":"JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"x\",\"consumedAt\":\"t\",\"name\":\"n\"}]}","session_id":"sess-v2"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"tell","text":"log lunch"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert!(v["response"].as_str().unwrap().contains("JESSE_MEAL_LOG v2"), "v2 stays visible");
    assert!(v["directives"].is_null(), "no field for an unknown version");
}

#[tokio::test]
async fn plain_reply_has_null_directives() {
    // The overwhelmingly common case: an ordinary answer, unchanged, directives null.
    let line = r#"{"type":"result","is_error":false,"result":"Your inbox has three threads.","session_id":"sess-plain"}"#;
    let (st, job_id) = run_turn_emitting(r#"{"mode":"ask","text":"summarize my inbox"}"#, line).await;
    let v = result_status(&st, &job_id).await;
    assert_eq!(v["response"], "Your inbox has three threads.");
    assert!(v.get("directives").is_some(), "the directives key is always present");
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
    for _ in 0..80 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if result_status(&st, &job_id).await["status"] == "done" {
            break;
        }
    }
    let prompt = std::fs::read_to_string(&promptfile).expect("fake claude records the prompt");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_file(&promptfile);
    prompt
}

#[tokio::test]
async fn wrapper_carries_request_instruction_without_context_and_present_note_with() {
    // No health_context → the agent is told how to ask (JESSE_NEEDS_HEALTH).
    let without = captured_turn_prompt(r#"{"mode":"ask","text":"how am I doing?"}"#).await;
    assert!(without.contains("JESSE_NEEDS_HEALTH v1"), "request instruction present: {without}");
    assert!(!without.contains("do not emit JESSE_NEEDS_HEALTH"), "not the present note");
    // With health_context → the present note; do not ask.
    let with = captured_turn_prompt(
        r#"{"mode":"ask","text":"log my swim","health_context":"Swim 30m 1500m"}"#,
    )
    .await;
    assert!(with.contains("do not emit JESSE_NEEDS_HEALTH"), "present note: {with}");
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
    assert_eq!(resp.status(), StatusCode::ACCEPTED, "a block at exactly 8 KiB is accepted");
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

// Full progress fixture: the new `targets` array (dated, undated with date:null,
// undated with the key omitted, and an achieved past-dated goal) ALONGSIDE the
// legacy race/maint fields, which stay during the transition. All values invented.
const FIX_PROGRESS: &str = "window.DIET_PROGRESS = {\n\
  startWeight: 204, raceTarget: 165, maintTarget: 180, raceDate: '2026-10-11',\n\
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

// A legacy-only progress fixture (no `targets` key at all): a pre-rollout generator.
// Must still parse and serve, with the legacy fields intact and `targets` absent.
const FIX_PROGRESS_LEGACY: &str = "window.DIET_PROGRESS = {\n\
  startWeight: 204, raceTarget: 165, maintTarget: 180, raceDate: '2026-10-11',\n\
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
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "todo-list/diet-progress.js", FIX_PROGRESS);
    write_vault_file(&vault, "todo-list/diet-coach-notes.js", FIX_COACH);
    write_vault_file(&vault, "todo-list/proposed-diet-today.js", FIX_PROPOSED);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
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
    let resp = app(st).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();

    // Envelope: RFC3339 asOf + todayMtime, empty errors.
    assert!(body["asOf"].as_str().unwrap().ends_with('Z'), "asOf is RFC3339 UTC");
    assert!(body["todayMtime"].as_str().unwrap().ends_with('Z'), "todayMtime present");
    assert_eq!(body["errors"].as_array().unwrap().len(), 0, "no errors on clean data");

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

    // Legacy race/maint fields still pass through while present (real data keeps
    // them during the transition).
    assert_eq!(body["progress"]["raceTarget"], 165);
    assert_eq!(body["progress"]["raceDate"], "2026-10-11");
    assert_eq!(body["progress"]["maintTarget"], 180);

    // targets: the new array flows through the generic pass-through field-for-field,
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
    assert!(targets[1]["date"].is_null(), "explicit date: null survives as null");
    assert!(targets[1]["daysLeft"].is_null());
    assert!(targets[1]["requiredPace"].is_null());
    // [2] undated goal with the date key OMITTED → absent, not null.
    assert_eq!(targets[2]["id"], "stretch");
    assert!(targets[2].get("date").is_none(), "omitted date key stays omitted");
    // [3] achieved goal.
    assert_eq!(targets[3]["id"], "firstcut");
    assert_eq!(targets[3]["achieved"], true);
    assert_eq!(targets[3]["daysLeft"], -68, "past date → negative daysLeft");

    // coach: HTML/entities survive verbatim (no decode/strip at the bridge).
    assert_eq!(body["coach"]["notes"][0], "<strong>Great week</strong> &mdash; you hit protein every day");
    assert_eq!(body["coach"]["quote"]["author"], "Abraham Lincoln");

    // proposed: present with non-empty ideas.
    assert_eq!(body["proposed"]["ideas"][0]["name"], "Afternoon snack");
    assert_eq!(body["proposed"]["gapNote"], "You are ~30g short on protein.");

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

    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_minimal_today_omits_optional_fields_cleanly() {
    // An old-style file with no dayStyle, no weigh-in, no fiber/carbsBase must
    // still parse and 200 — the absent fields simply don't appear.
    let vault = make_diet_vault();
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY_MINIMAL);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["today"]["dayStyle"].is_null(), "absent dayStyle → null");
    assert!(body["today"]["weight"].is_null(), "non-weigh-in day → weight null");
    assert!(body["today"]["targets"]["carbsBase"].is_null(), "absent carbsBase → null");
    // progress/coach files absent → null + an errors entry each (expected files).
    assert!(body["progress"].is_null());
    assert!(body["coach"].is_null());
    // proposed absent → null but NOT an error.
    assert!(body["proposed"].is_null());
    let errs = body["errors"].as_array().unwrap();
    assert!(errs.iter().any(|e| e.as_str().unwrap().starts_with("progress:")));
    assert!(errs.iter().any(|e| e.as_str().unwrap().starts_with("coach:")));
    assert!(!errs.iter().any(|e| e.as_str().unwrap().starts_with("proposed:")), "absent proposed is not an error");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_missing_today_is_503() {
    // No diet-today.js at all → the screen is pointless → 503 with a JSON body.
    let vault = make_diet_vault();
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["error"].as_str().unwrap().contains("diet-today.js"), "JSON error body names the file");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_broken_today_is_503() {
    // diet-today.js present but unparseable → still 503.
    let vault = make_diet_vault();
    write_vault_file(&vault, "todo-list/diet-today.js", "window.DIET_TODAY = { date: , oops };");
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_section_isolation_bad_progress_still_200() {
    // A broken progress file must NOT fail the endpoint: today parsed, so 200,
    // progress null, and a human-readable errors entry naming the section.
    let vault = make_diet_vault();
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "todo-list/diet-progress.js", "window.DIET_PROGRESS = { not valid ]");
    write_vault_file(&vault, "todo-list/diet-coach-notes.js", FIX_COACH);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "one bad section must not fail the endpoint");
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["progress"].is_null(), "bad section → null");
    assert!(!body["today"].is_null(), "today still rendered");
    assert!(!body["coach"].is_null(), "sibling sections unaffected");
    let errs = body["errors"].as_array().unwrap();
    assert!(errs.iter().any(|e| e.as_str().unwrap().starts_with("progress:")), "errors names the failed section: {errs:?}");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_legacy_progress_without_targets_still_serves() {
    // A pre-rollout generator emits no `targets` key. The endpoint must 200, the
    // legacy race/maint fields pass through, and `targets` is simply absent — the
    // app synthesizes it locally, so deploy order is independent of the rollout.
    let vault = make_diet_vault();
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "todo-list/diet-progress.js", FIX_PROGRESS_LEGACY);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["progress"]["raceTarget"], 165, "legacy fields intact");
    assert_eq!(body["progress"]["maintTarget"], 180);
    assert!(body["progress"].get("targets").is_none(), "no targets key on legacy data");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_empty_targets_round_trips_as_empty_array() {
    // `targets: []` means the user has no weight goals right now — it must survive
    // as an empty array, distinct from an absent or null field.
    let vault = make_diet_vault();
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "todo-list/diet-progress.js", FIX_PROGRESS_EMPTY_TARGETS);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    let resp = app(AppState::new(cfg)).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let targets = body["progress"]["targets"].as_array().expect("targets is an array");
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
    write_vault_file(&vault, "todo-list/diet-today.js", FIX_TODAY);
    write_vault_file(&vault, "diet-logs/weight-log.csv", FIX_WEIGHT_CSV);
    write_vault_file(&vault, "diet-logs/food-log.csv", FIX_FOOD_CSV);
    write_vault_file(&vault, "diet-logs/exercise-log.csv", FIX_EXERCISE_CSV);
    let cfg = Config { vault: vault.to_string_lossy().into_owned(), ..test_config() };
    (AppState::new(cfg), vault)
}

#[tokio::test]
async fn diet_today_response_carries_new_history_fields() {
    // The plain today response gains availableDays / historical / fidelity, and is
    // otherwise byte-compatible (existing fields unchanged).
    let (st, vault) = diet_state_history();
    let resp = app(st).oneshot(diet_request(Some("Bearer test-token"))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], false, "today is not historical");
    assert_eq!(body["fidelity"], "live", "today fidelity is live");
    let days = body["availableDays"].as_array().unwrap();
    assert!(days.iter().any(|d| d == "2026-07-08"), "today's own date is included");
    assert!(days.iter().any(|d| d == "2026-04-15"), "a CSV date is included");
    // Ascending + deduped.
    let flat: Vec<&str> = days.iter().map(|d| d.as_str().unwrap()).collect();
    let mut sorted = flat.clone(); sorted.sort(); sorted.dedup();
    assert_eq!(flat, sorted, "availableDays sorted ascending and deduped");
    // Existing today fields unchanged.
    assert_eq!(body["today"]["dayStyle"], "normal");
    assert_eq!(body["today"]["targets"]["calories"], 2100);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_bad_date_format_is_400() {
    let (st, vault) = diet_state_history();
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-4-5")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["error"].is_string(), "400 has a JSON error body");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_unknown_date_is_404() {
    let (st, vault) = diet_state_history();
    // A valid past date with no CSV/archive data.
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-01-02")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert!(body["error"].is_string(), "404 has a JSON error body");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_future_date_is_404() {
    let (st, vault) = diet_state_history();
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2027-01-01")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_reconstructed_day_has_null_targets_and_real_logs() {
    let (st, vault) = diet_state_history();
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], true);
    assert_eq!(body["fidelity"], "reconstructed");
    assert!(body["today"]["targets"].is_null(), "reconstructed day has null targets");
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
    assert_eq!(banana["amount"], "1 medium (~118g)", "amount with unit text verbatim");
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
    assert!(body["today"]["weight"].is_null(), "no weigh-in that day → weight null");
    // weightSeries (the historical chart) is still returned in full.
    assert_eq!(body["weightSeries"].as_array().unwrap().len(), 3);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_reconstructed_day_maps_weigh_in_when_present() {
    // 2026-07-06 has a weight-log row but no food/exercise rows → reconstructed with
    // a weight object in today-weight shape (mm from MuscleMass_lbs).
    let (st, vault) = diet_state_history();
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-07-06")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["fidelity"], "reconstructed");
    assert_eq!(body["today"]["weight"]["lbs"], 198.6);
    assert_eq!(body["today"]["weight"]["bf"], 18.4);
    assert_eq!(body["today"]["weight"]["mm"], 150.0, "mm mapped from MuscleMass_lbs");
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
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["historical"], true);
    assert_eq!(body["fidelity"], "archived", "archive wins over CSV reconstruction");
    assert_eq!(body["today"]["dayStyle"], "carb-load-training");
    assert_eq!(body["today"]["targets"]["calories"], 2800, "archived targets present");
    assert_eq!(body["today"]["meals"][0]["name"], "Archived Meal", "served verbatim, not reconstructed");
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn diet_history_when_days_dir_absent_reconstructs_cleanly() {
    // The days/ archive directory does not exist at all → treated as no-archive, not
    // an error; the day reconstructs.
    let (st, vault) = diet_state_history();
    assert!(!vault.join("diet-logs/days").exists(), "no archive dir in this fixture");
    let resp = app(st).oneshot(diet_request_date(Some("Bearer test-token"), "2026-04-15")).await.unwrap();
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
        max_concurrency: 1,
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
        let mut done = false;
        for _ in 0..80 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            if result_status(&st, id).await["status"] == "done" {
                done = true;
                break;
            }
        }
        assert!(done, "both queued turns must complete");
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
        max_concurrency: 1,
        max_queued: 4,
        ..test_config()
    };
    let st = AppState::new(cfg);

    // First turn takes the permit.
    let first = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), r#"{"mode":"ask","text":"one"}"#))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::ACCEPTED);

    // Second turn: returned promptly (well under the first turn's 3s run) with
    // status running — proof the POST never blocks on a permit.
    let start = std::time::Instant::now();
    let second = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), r#"{"mode":"ask","text":"two"}"#))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::ACCEPTED);
    assert!(start.elapsed() < Duration::from_secs(2), "202 must be immediate, not held for a permit");
    let body: Value = serde_json::from_str(&body_string(second).await).unwrap();
    assert_eq!(body["status"], "running");
    let queued_id = body["job_id"].as_str().unwrap().to_string();

    // The queued turn's stream carries the "queued behind another turn" activity.
    let mut saw_queue_activity = false;
    for _ in 0..30 {
        if let Some((_text, activity, _rx)) = st.jobs.stream_subscribe(&queued_id) {
            if activity.as_deref() == Some(QUEUED_ACTIVITY) {
                saw_queue_activity = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(saw_queue_activity, "a queued turn's stream must reflect the wait");

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
        max_concurrency: 1,
        max_queued: 1,
        ..test_config()
    };
    let st = AppState::new(cfg);

    // A: takes the permit and spawns claude (writes one "spawn" line).
    let a = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), r#"{"mode":"ask","text":"a"}"#))
        .await
        .unwrap();
    assert_eq!(a.status(), StatusCode::ACCEPTED);

    // Wait until A's claude has actually spawned (its one "spawn" line lands), so
    // the count assertion below is deterministic rather than timing-dependent.
    let mut a_spawned = false;
    for _ in 0..50 {
        if std::fs::read_to_string(&log).unwrap_or_default().lines().count() >= 1 {
            a_spawned = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(a_spawned, "the running turn A must spawn claude");

    // B: queued (202) behind A; it must NOT spawn claude.
    let b = app(st.clone())
        .oneshot(jesse_request(Some("Bearer test-token"), r#"{"mode":"ask","text":"b"}"#))
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
        .oneshot(jesse_request(Some("Bearer test-token"), r#"{"mode":"ask","text":"c"}"#))
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

#[tokio::test]
async fn sessions_requires_auth() {
    let st = test_state();
    let resp = app(st).oneshot(sessions_request(None, None, None)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn sessions_empty_when_projects_dir_absent_with_stable_etag_and_304() {
    // Point the vault at a path whose escaped projects dir does not exist → an
    // empty list (never an error), a strong ETag, and a matching If-None-Match 304.
    let cfg = Config {
        vault: format!("/no/such/vault/{}", random_hex()),
        ..test_config()
    };
    let st = AppState::new(cfg);

    let resp = app(st.clone()).oneshot(sessions_request(Some("Bearer test-token"), None, None)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let etag = resp.headers().get("etag").unwrap().to_str().unwrap().to_string();
    assert!(etag.starts_with('"') && !etag.starts_with("W/"), "strong etag: {etag}");
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["sessions"], serde_json::json!([]), "absent projects dir → empty list");

    // Same request with the ETag → 304 Not Modified, empty body.
    let resp = app(st).oneshot(sessions_request(Some("Bearer test-token"), None, Some(&etag))).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_MODIFIED);
    assert!(body_string(resp).await.is_empty(), "304 has an empty body");
}

// Serialize the HOME-mutating session tests against each other.
static HOME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

// The guard is intentionally held across the awaited request: HOME is a process
// global, so it must stay pinned to this test's throwaway value for the whole
// request (the sessions handler reads it mid-await). Only this one test mutates
// HOME, so holding the lock across the await cannot deadlock.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn sessions_lists_a_real_transcript_with_first_message_and_title() {
    let _g = HOME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let saved_home = std::env::var("HOME").ok();

    // A throwaway HOME with a vault whose escaped projects dir holds one session.
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    let vault = format!("/vault/{}", random_hex());
    let proj = home.join(".claude").join("projects").join(escape_project_path(&vault));
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(
        proj.join("sess-42.jsonl"),
        "{\"type\":\"system\"}\n{\"type\":\"user\",\"message\":{\"content\":\"what is on Today.md?\"}}\n",
    )
    .unwrap();

    std::env::set_var("HOME", &home);
    let cfg = Config {
        vault: vault.clone(),
        state_dir: None,
        ..test_config()
    };
    let st = AppState::new(cfg);
    // Store a title for the session (as POST /jesse/title would).
    st.titles.set("sess-42", "Today Overview");

    let resp = app(st).oneshot(sessions_request(Some("Bearer test-token"), None, None)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();

    // Restore HOME before asserting (so a panic can't leak the override).
    match saved_home {
        Some(h) => std::env::set_var("HOME", h),
        None => std::env::remove_var("HOME"),
    }

    let sessions = body["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["session_id"], "sess-42");
    assert_eq!(sessions[0]["first_message"], "what is on Today.md?");
    assert_eq!(sessions[0]["title"], "Today Overview");
    assert!(sessions[0]["last_modified"].as_u64().is_some());

    let _ = std::fs::remove_dir_all(&home);
}

// ---- POST /jesse/title server-side store -----------------------------------

#[tokio::test]
async fn title_with_session_id_persists_and_survives_restart() {
    // A title request carrying a session_id persists the minted title under it; a
    // fresh store over the same state dir reloads it (restart survival). Uses a
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

    let resp = app(st.clone())
        .oneshot(title_request(
            Some("Bearer test-token"),
            r#"{"text":"the roofer is coming Thursday","session_id":"sess-roof"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["title"], "Roof Repair Plan");

    // In-memory store now has it.
    assert_eq!(st.titles.get("sess-roof").as_deref(), Some("Roof Repair Plan"));

    // Restart survival: a fresh store over the same state dir reloads the title.
    let reloaded = AppState::new(cfg);
    assert_eq!(reloaded.titles.get("sess-roof").as_deref(), Some("Roof Repair Plan"));

    let _ = std::fs::remove_dir_all(&state_dir);
    let _ = std::fs::remove_file(&fake);
}

#[tokio::test]
async fn title_without_session_id_persists_nothing() {
    // Omitting session_id reproduces today's stateless behavior — nothing stored.
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
        .oneshot(title_request(Some("Bearer test-token"), r#"{"text":"a conversation"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(st.titles.is_empty(), "no session_id → nothing persisted");

    let _ = std::fs::remove_dir_all(&state_dir);
    let _ = std::fs::remove_file(&fake);
}
