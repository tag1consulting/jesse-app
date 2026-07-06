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
    async fn second_concurrent_turn_is_429() {
        // A fake claude that sleeps long enough that the first turn is still
        // in-flight (holding the only permit) when the second POST arrives.
        let script = "#!/bin/sh\nsleep 2\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n";
        let fake = write_fake_claude(script);
        let cfg = Config {
            claude_bin: fake.to_string_lossy().into_owned(),
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
