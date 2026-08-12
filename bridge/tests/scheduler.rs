//! The built-in scheduler, driven end to end: real chains, real turns (a fake `claude`
//! child), the real job store, and the real `GET /jesse/schedule` route.
//!
//! Every test here drives [`Scheduler::tick`] with an EXPLICIT `now_ms` and an explicit
//! persisted anchor, so nothing waits on the wall clock and nothing depends on what time
//! of day the suite happens to run. The clock-math itself (day boundaries, weekday
//! filters, DST, the catch-up window) is unit-tested in `src/schedule.rs`; what is proved
//! here is the RUNTIME: ordering, serialization, single flight, persistence, and that a
//! scheduled turn really does land in the job store like any other.
mod common;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Local, TimeZone};
use common::*;
use jesse_bridge::*;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tower::ServiceExt;

/// Wall-clock budget for a wait whose assertion is THAT something happens, never how
/// fast (same discipline as `tests/integration.rs`).
const WAIT_DEADLINE: Duration = Duration::from_secs(60);

fn now_ms() -> u64 {
    system_time_to_ms(SystemTime::now())
}

/// A `"HH:MM"` local time that was `minutes_ago` minutes ago, paired with the anchor
/// (a day earlier) that makes exactly that occurrence the due one.
///
/// Deriving the time from the machine's own clock is what keeps these tests zone- and
/// hour-independent: whatever `Local` is, "five minutes ago" is due and five minutes late.
fn due_at(minutes_ago: i64) -> (String, u64) {
    let now = now_ms();
    let at_ms = now - (minutes_ago as u64) * 60_000;
    let at = Local
        .timestamp_millis_opt(at_ms as i64)
        .single()
        .expect("a representable local instant")
        .format("%H:%M")
        .to_string();
    (at, now - 24 * 60 * 60 * 1000)
}

/// The local weekday name `days_ahead` days from now — used to build a `days` filter that
/// deliberately EXCLUDES today.
fn weekday_name(days_ahead: i64) -> String {
    let t = Local
        .timestamp_millis_opt((now_ms() + (days_ahead as u64) * 86_400_000) as i64)
        .single()
        .unwrap();
    t.format("%a").to_string().to_lowercase()
}

fn entry(id: &str) -> ScheduleToml {
    ScheduleToml {
        id: Some(id.to_string()),
        prompt: Some(format!("Run the job. MARKER-{id}")),
        ..Default::default()
    }
}

fn head(id: &str, at: &str) -> ScheduleToml {
    ScheduleToml {
        at: Some(at.to_string()),
        // Wide enough that a DST-shifted "five minutes ago" is still inside it.
        catch_up_secs: Some(86_400),
        ..entry(id)
    }
}

fn link(id: &str, after: &str) -> ScheduleToml {
    ScheduleToml {
        after: Some(after.to_string()),
        ..entry(id)
    }
}

/// A fake `claude` that appends `start <marker>` / `end <marker>` around a short sleep and
/// then answers. The marker comes from the prompt (argv `$2`), so one script serves every
/// job in a chain and the log records exactly who ran, in what order, and whether any two
/// runs overlapped.
fn logging_claude(log: &std::path::Path, sleep: &str) -> PathBuf {
    write_fake_claude(&format!(
        "#!/bin/sh\n\
         m=$(printf '%s' \"$2\" | grep -o 'MARKER-[a-z0-9-]*' | head -1)\n\
         echo \"start $m\" >> '{log}'\n\
         sleep {sleep}\n\
         echo \"end $m\" >> '{log}'\n\
         printf '%s\\n' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-sched\"}}'\n",
        log = log.display(),
    ))
}

/// A fake `claude` that FAILS non-retryably (a 400 is `Fatal`, so the driver does not
/// retry it) for the job whose marker is `fail_marker`, and succeeds for everyone else.
fn failing_claude(log: &std::path::Path, fail_marker: &str) -> PathBuf {
    write_fake_claude(&format!(
        "#!/bin/sh\n\
         m=$(printf '%s' \"$2\" | grep -o 'MARKER-[a-z0-9-]*' | head -1)\n\
         echo \"start $m\" >> '{log}'\n\
         echo \"end $m\" >> '{log}'\n\
         if [ \"$m\" = 'MARKER-{fail}' ]; then\n\
           printf '%s\\n' '{{\"type\":\"result\",\"is_error\":true,\"api_error_status\":400,\"result\":\"deliberate test failure\"}}'\n\
         else\n\
           printf '%s\\n' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-sched\"}}'\n\
         fi\n",
        log = log.display(),
        fail = fail_marker,
    ))
}

/// A fake `claude` for the interleave test: a SLOW turn for a chain member and a fast one
/// for the interactive turn, so the interactive child can start, finish, and be asserted on
/// while a chain member is provably still in flight.
fn interleave_claude(log: &std::path::Path) -> PathBuf {
    write_fake_claude(&format!(
        "#!/bin/sh\n\
         m=$(printf '%s' \"$2\" | grep -o 'MARKER-[a-z0-9-]*' | head -1)\n\
         echo \"start $m\" >> '{log}'\n\
         if [ \"$m\" = 'MARKER-interactive' ]; then sleep 0.05; else sleep 3; fi\n\
         echo \"end $m\" >> '{log}'\n\
         printf '%s\\n' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-sched\"}}'\n",
        log = log.display(),
    ))
}

fn log_lines(log: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect()
}

/// A throwaway state dir, so the persisted schedule record is real (and never the
/// developer's own `~/.jesse-bridge`).
fn temp_state_dir() -> PathBuf {
    let d = std::env::temp_dir().join(format!("jesse-sched-it-{}", random_hex()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn state_with(
    schedule: Vec<ScheduleToml>,
    claude: &std::path::Path,
    dir: &std::path::Path,
) -> AppState {
    let validated = validate_schedule(&schedule);
    assert!(validated.fatal.is_empty(), "{:?}", validated.fatal);
    AppState::new(Config {
        claude_bin: claude.to_string_lossy().into_owned(),
        state_dir: Some(dir.to_string_lossy().into_owned()),
        schedule: Arc::new(validated),
        ..test_config()
    })
}

/// Drive one tick and wait for every chain it started.
async fn tick_and_wait(st: &AppState, now: u64) {
    for h in st.scheduler.tick(st, now) {
        h.await.expect("a chain task must not panic");
    }
}

fn schedule_request(auth: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method("GET").uri("/jesse/schedule");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}

async fn schedule_body(st: &AppState) -> Value {
    let resp = app(st.clone())
        .oneshot(schedule_request(Some("Bearer test-token")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    serde_json::from_str(&body_string(resp).await).unwrap()
}

fn row<'a>(body: &'a Value, id: &str) -> &'a Value {
    body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == id)
        .unwrap_or_else(|| panic!("no row for {id}"))
}

// ---- The chain ---------------------------------------------------------------

#[tokio::test]
async fn a_chain_runs_strictly_in_order_and_never_overlaps() {
    // THE PROPERTY THE WHOLE FEATURE RESTS ON: these jobs all write the same working
    // tree, so a link starts only once its predecessor's turn has FULLY completed. The
    // log interleaves start/end markers, so an overlap is visible as `start a start b`.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.3");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![head("one", &at), link("two", "one"), link("three", "two")],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(
        log_lines(&log),
        vec![
            "start MARKER-one",
            "end MARKER-one",
            "start MARKER-two",
            "end MARKER-two",
            "start MARKER-three",
            "end MARKER-three",
        ],
        "the chain must run in order with no two turns in flight at once"
    );
    for id in ["one", "two", "three"] {
        assert_eq!(st.scheduler.state.get(id).outcome(), Some(Outcome::Ran));
    }
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn after_on_success_stops_the_chain_and_names_the_job_that_broke_it() {
    // The head fails. Both links behind it are recorded as SKIPPED, and both name the
    // job that actually broke the chain — not merely the link above them, which for
    // `three` would point at `two` and send someone looking in the wrong place.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = failing_claude(&log, "one");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![head("one", &at), link("two", "one"), link("three", "two")],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(
        log_lines(&log),
        vec!["start MARKER-one", "end MARKER-one"],
        "nothing behind the break may run"
    );
    let head_rec = st.scheduler.state.get("one");
    assert_eq!(head_rec.outcome(), Some(Outcome::Failed));
    assert!(
        head_rec.last_reason.contains("deliberate test failure"),
        "{head_rec:?}"
    );
    for id in ["two", "three"] {
        let rec = st.scheduler.state.get(id);
        assert_eq!(rec.outcome(), Some(Outcome::Skipped), "{id}");
        assert!(
            rec.last_reason.contains("\"one\""),
            "{id} must name the job that broke the chain, got {:?}",
            rec.last_reason
        );
        assert_eq!(rec.last_job_id, None, "a skipped link has no turn");
    }
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn after_on_any_runs_even_though_its_predecessor_failed() {
    // The cleanup/report link that is most needed exactly when the step before it broke.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = failing_claude(&log, "one");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![
            head("one", &at),
            ScheduleToml {
                after_on: Some("any".to_string()),
                ..link("two", "one")
            },
        ],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(
        log_lines(&log),
        vec![
            "start MARKER-one",
            "end MARKER-one",
            "start MARKER-two",
            "end MARKER-two",
        ],
        "after_on = \"any\" runs regardless of the predecessor's outcome"
    );
    assert_eq!(
        st.scheduler.state.get("one").outcome(),
        Some(Outcome::Failed)
    );
    assert_eq!(st.scheduler.state.get("two").outcome(), Some(Outcome::Ran));
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_days_filtered_link_is_skipped_on_a_day_it_does_not_name() {
    // `days` applies to links as much as to heads — a Monday-only job hanging off a
    // daily chain is the whole reason it is not a head-only key. Today is deliberately
    // excluded (the filter names tomorrow), so the link is skipped and the chain
    // behind it does not run, while the head still does.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![
            head("one", &at),
            ScheduleToml {
                days: Some(vec![weekday_name(1)]),
                ..link("two", "one")
            },
            link("three", "two"),
        ],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(log_lines(&log), vec!["start MARKER-one", "end MARKER-one"]);
    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    let two = st.scheduler.state.get("two");
    assert_eq!(two.outcome(), Some(Outcome::Skipped));
    assert!(two.last_reason.contains("weekday"), "{:?}", two.last_reason);
    // And its own tail is skipped naming IT, since it is what broke the chain.
    let three = st.scheduler.state.get("three");
    assert_eq!(three.outcome(), Some(Outcome::Skipped));
    assert!(
        three.last_reason.contains("\"two\""),
        "{:?}",
        three.last_reason
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Global serialization + single flight ------------------------------------

#[tokio::test]
async fn a_second_chain_waits_for_the_first_rather_than_overlapping_it() {
    // TWO INDEPENDENT CHAINS, both due on the same tick. The scheduler's own lock — not
    // the request concurrency limit, which has two free slots here — is what keeps them
    // off each other: whichever wins, its chain must complete before the other starts.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.25");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![
            head("a1", &at),
            link("a2", "a1"),
            head("b1", &at),
            link("b2", "b1"),
        ],
        &fake,
        &dir,
    );
    assert!(
        st.slots.free_for("opus") >= 2,
        "the fixture must have spare request slots, so only the scheduler's lock can serialize"
    );
    st.scheduler.state.claim("a1", anchor);
    st.scheduler.state.claim("b1", anchor);

    tick_and_wait(&st, now_ms()).await;

    let lines = log_lines(&log);
    assert_eq!(lines.len(), 8, "all four jobs ran: {lines:?}");
    // No overlap anywhere: every `start x` is immediately followed by `end x`.
    for pair in lines.chunks(2) {
        assert_eq!(
            pair[0].replace("start ", ""),
            pair[1].replace("end ", ""),
            "two scheduled turns overlapped: {lines:?}"
        );
    }
    // And the two chains did not interleave with each other.
    let order: Vec<&str> = lines
        .iter()
        .filter(|l| l.starts_with("start "))
        .map(|l| l.trim_start_matches("start MARKER-"))
        .collect();
    assert!(
        order == ["a1", "a2", "b1", "b2"] || order == ["b1", "b2", "a1", "a2"],
        "a chain must complete before another begins, got {order:?}"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_still_running_chain_skips_its_next_fire_instead_of_queueing_it() {
    // SINGLE FLIGHT. The chain is still going when its head comes due again a day later;
    // the new fire is skipped and recorded, never queued — queueing would eventually run
    // two of them back to back at entirely the wrong time of day.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "2");
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at)], &fake, &dir);
    st.scheduler.state.claim("one", anchor);

    let handles = st.scheduler.tick(&st, now_ms());
    assert_eq!(handles.len(), 1, "the first fire started a chain");

    // Wait until the chain is genuinely in flight, then fire the NEXT day's occurrence.
    let started = std::time::Instant::now();
    while !st.scheduler.is_running("one") {
        assert!(started.elapsed() < WAIT_DEADLINE, "chain never started");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let tomorrow = now_ms() + 25 * 60 * 60 * 1000;
    let second = st.scheduler.tick(&st, tomorrow);
    assert!(second.is_empty(), "the second fire must not start a chain");

    // The skip is recorded THE MOMENT it is decided — read it before the long first run
    // finishes and writes its own (later) outcome into the same one-slot record.
    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert!(
        rec.last_reason.contains("still in progress"),
        "{:?}",
        rec.last_reason
    );

    for h in handles {
        h.await.unwrap();
    }
    assert_eq!(
        log_lines(&log),
        vec!["start MARKER-one", "end MARKER-one"],
        "the skipped fire must never have spawned a second turn"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn an_interactive_turn_runs_mid_chain_without_waiting_on_the_scheduler_lock() {
    // THE TWO LOCKS ARE NOT THE SAME LOCK, and this is the assertion that says so.
    //
    // `Scheduler::turn_lock` is held for a whole chain and serializes CHAIN AGAINST CHAIN.
    // A person's turn never touches it — it is admitted by the ordinary `SlotTable`, the
    // same gate every turn passes — so a chain running at 03:00 must not make an
    // interactive turn wait for the chain, or even for the member in flight.
    //
    // FAILING-FIRST: were the scheduler serializing on the shared turn-admission path
    // instead, the POST below could not be admitted `Ready` while a member holds it, and
    // the interactive turn could not finish before the chain does.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = interleave_claude(&log);
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);
    st.scheduler.state.claim("one", anchor);

    // Start the chain, but do NOT wait for it — the point is to act while it runs.
    let handles = st.scheduler.tick(&st, now_ms());
    assert_eq!(handles.len(), 1);

    // Wait until a chain member's turn is genuinely in flight (its child has started and
    // is inside its 3s sleep), so what follows is measured against a busy chain.
    let started = std::time::Instant::now();
    while !log_lines(&log).iter().any(|l| l == "start MARKER-one") {
        assert!(started.elapsed() < WAIT_DEADLINE, "the chain never started");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        st.scheduler.is_running("one"),
        "the chain holds the scheduler lock for its whole life"
    );
    assert!(
        st.slots.free_for("opus") >= 1,
        "a scheduled turn takes ONE ordinary slot, not the whole table"
    );

    // The interactive turn. Admission must be immediate — `Ready`, not queued behind the
    // chain — so the POST returns its 202 without waiting out the 3s member.
    let posted = std::time::Instant::now();
    let resp = app(st.clone())
        .oneshot(jesse_request(
            Some("Bearer test-token"),
            r#"{"mode":"ask","text":"answer me now MARKER-interactive"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::ACCEPTED);
    let admit = posted.elapsed();
    assert!(
        admit < Duration::from_secs(2),
        "admission took {admit:?} — an interactive turn must not queue behind a chain member"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let job_id = body["job_id"].as_str().unwrap().to_string();

    // It must COMPLETE while the chain is still running. That is the property: the
    // interactive turn neither waited for the chain nor for the member in flight.
    let done = std::time::Instant::now();
    loop {
        let v = result_status(&st, &job_id).await;
        if v["status"] == "done" {
            assert_eq!(v["response"], "ok");
            break;
        }
        assert!(
            done.elapsed() < WAIT_DEADLINE,
            "the interactive turn never finished"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        st.scheduler.is_running("one"),
        "the interactive turn finished while the chain was still running — it never waited \
         on the scheduler's lock"
    );
    // And it really did overlap the member in flight, rather than slipping into a gap:
    // its child started before that member's child finished.
    let lines = log_lines(&log);
    let interactive_start = lines.iter().position(|l| l == "start MARKER-interactive");
    let member_end = lines.iter().position(|l| l == "end MARKER-one");
    assert!(
        interactive_start.is_some() && (member_end.is_none() || interactive_start < member_end),
        "the interactive turn must run CONCURRENTLY with the in-flight chain member: {lines:?}"
    );

    // THE CHAIN RESUMES CORRECTLY after an interactive turn ran alongside it.
    for h in handles {
        h.await.unwrap();
    }
    let chain: Vec<String> = log_lines(&log)
        .into_iter()
        .filter(|l| l.ends_with("MARKER-one") || l.ends_with("MARKER-two"))
        .collect();
    assert_eq!(
        chain,
        vec![
            "start MARKER-one",
            "end MARKER-one",
            "start MARKER-two",
            "end MARKER-two"
        ],
        "the chain must still run in order, with no member overlapping another"
    );
    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    assert_eq!(st.scheduler.state.get("two").outcome(), Some(Outcome::Ran));
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_saturated_request_limit_makes_a_scheduled_turn_skip_rather_than_starve_a_client() {
    // A scheduled turn must never starve an interactive one. With every model slot held
    // by client turns, the scheduled job waits briefly and then SKIPS — it does not
    // queue behind the person who is using the bridge right now.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let mut st = state_with(vec![head("one", &at)], &fake, &dir);
    // A one-second patience, so the test proves the behavior without spending the
    // shipped 60s waiting for it.
    st.scheduler = Scheduler::new_with(
        st.cfg.schedule.clone(),
        st.cfg.schedule_file(),
        Duration::from_secs(1),
    );
    st.scheduler.state.claim("one", anchor);

    // Hold every slot the way a client turn does.
    let mut held = Vec::new();
    while st.slots.free_for("opus") > 0 {
        match st.slots.admit("opus", false) {
            Some(TurnAdmission::Ready { model, ceiling, .. }) => held.push((model, ceiling)),
            _ => panic!("a free slot must admit Ready"),
        }
    }
    assert_eq!(st.slots.free_for("opus"), 0);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert!(
        rec.last_reason.contains("saturated"),
        "the reason must say why: {:?}",
        rec.last_reason
    );
    assert!(
        log_lines(&log).is_empty(),
        "no child may be spawned for a skipped run"
    );
    drop(held);
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_saturation_skip_stays_eligible_and_the_next_tick_runs_it() {
    // A TRANSIENT collision must cost minutes, not the day's run. The slots were busy for
    // one tick; the occurrence never went stale, so it stays eligible and the next tick
    // runs it — the same occurrence, not tomorrow's.
    //
    // FAILING-FIRST: before the retry existed, the occurrence was consumed by the skip
    // and the second tick below started nothing at all.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    // Due ~now, with a wide window so the retry is unambiguously inside it.
    let (at, anchor) = due_at(0);
    let mut st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);
    st.scheduler = Scheduler::new_with(
        st.cfg.schedule.clone(),
        st.cfg.schedule_file(),
        Duration::from_secs(1),
    );
    st.scheduler.state.claim("one", anchor);

    // Tick 1: every slot held by "client turns" → the scheduled turn yields.
    let mut held = Vec::new();
    while st.slots.free_for("opus") > 0 {
        match st.slots.admit("opus", false) {
            Some(TurnAdmission::Ready { model, ceiling, .. }) => held.push((model, ceiling)),
            _ => panic!("a free slot must admit Ready"),
        }
    }
    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert!(
        rec.last_reason.contains("saturated"),
        "{:?}",
        rec.last_reason
    );
    let armed = rec.retry_due_ms.expect("the occurrence must stay eligible");
    assert_eq!(
        rec.last_due_ms,
        Some(armed),
        "the anti-double-fire anchor must not have moved backwards"
    );
    assert!(
        log_lines(&log).is_empty(),
        "nothing ran on the skipped tick"
    );
    // It is visible as pending on the endpoint, not merely in the record.
    assert_eq!(row(&schedule_body(&st).await, "one")["retry_due_ms"], armed);

    // Tick 2: the person is done, the slots are free again.
    drop(held);
    tick_and_wait(&st, now_ms()).await;

    assert_eq!(
        log_lines(&log),
        vec![
            "start MARKER-one",
            "end MARKER-one",
            "start MARKER-two",
            "end MARKER-two",
        ],
        "the retried occurrence runs the whole chain"
    );
    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Ran));
    assert_eq!(
        rec.retry_due_ms, None,
        "a completed retry must not stay armed and fire a third time"
    );
    assert_eq!(st.scheduler.state.get("two").outcome(), Some(Outcome::Ran));

    // And a third tick does nothing — the occurrence really is consumed.
    tick_and_wait(&st, now_ms()).await;
    assert_eq!(log_lines(&log).len(), 4, "no double fire after the retry");

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_pending_retry_stops_at_the_edge_of_the_catch_up_window() {
    // The retry is bounded by the same window a missed fire is. Past it, the occurrence
    // is skipped with the delay named — a transient collision buys minutes, not licence
    // to run the morning routine at lunchtime.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(0);
    let mut st = state_with(
        vec![ScheduleToml {
            catch_up_secs: Some(300), // five minutes of eligibility
            ..head("one", &at)
        }],
        &fake,
        &dir,
    );
    st.scheduler = Scheduler::new_with(
        st.cfg.schedule.clone(),
        st.cfg.schedule_file(),
        Duration::from_secs(1),
    );
    st.scheduler.state.claim("one", anchor);

    // Tick 1 with the slots held → transient skip, retry armed.
    let mut held = Vec::new();
    while st.slots.free_for("opus") > 0 {
        match st.slots.admit("opus", false) {
            Some(TurnAdmission::Ready { model, ceiling, .. }) => held.push((model, ceiling)),
            _ => panic!("a free slot must admit Ready"),
        }
    }
    tick_and_wait(&st, now_ms()).await;
    assert!(st.scheduler.state.get("one").retry_due_ms.is_some());

    // Tick 2 TEN MINUTES LATER, with the slots free again: the window has closed, so the
    // retry must not run even though a slot is now available.
    drop(held);
    tick_and_wait(&st, now_ms() + 10 * 60_000).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert!(
        rec.last_reason.contains("missed by") && rec.last_reason.contains("catch_up_secs = 300s"),
        "the expiry must name the delay and the window: {:?}",
        rec.last_reason
    );
    assert_eq!(
        rec.retry_due_ms, None,
        "an expired retry must be dropped, not left pending forever"
    );
    assert!(
        log_lines(&log).is_empty(),
        "nothing may run past the catch-up window"
    );

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Catch-up + persistence ---------------------------------------------------

#[tokio::test]
async fn a_fire_missed_beyond_the_catch_up_window_is_skipped_with_the_delay_named() {
    // Inside the window it runs late; outside it, it does NOT run — and the skip says
    // how late it was, because "nothing happened and nobody said why" is the exact
    // failure this feature exists to end.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![
            ScheduleToml {
                catch_up_secs: Some(60), // five minutes late is well past this
                ..head("one", &at)
            },
            link("two", "one"),
        ],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert!(
        rec.last_reason.contains("missed by") && rec.last_reason.contains("catch_up_secs = 60s"),
        "{:?}",
        rec.last_reason
    );
    assert!(
        log_lines(&log).is_empty(),
        "nothing may run past the window"
    );
    // The rest of the chain is recorded too — never silently nothing.
    let two = st.scheduler.state.get("two");
    assert_eq!(two.outcome(), Some(Outcome::Skipped));
    assert!(two.last_reason.contains("\"one\""), "{:?}", two.last_reason);
    // And the occurrence is CLAIMED, so the next tick does not reconsider it.
    assert!(st.scheduler.tick(&st, now_ms()).is_empty());
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_fire_inside_the_catch_up_window_runs_late_rather_than_not_at_all() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5); // `head` sets a 24h catch-up window
    let st = state_with(vec![head("one", &at)], &fake, &dir);
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    assert_eq!(log_lines(&log), vec!["start MARKER-one", "end MARKER-one"]);
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn persisted_state_survives_a_restart_without_double_firing() {
    // The bridge restarts moments after a fire. The occurrence is already claimed on
    // disk, so the fresh process must NOT run it again.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let schedule = vec![head("one", &at), link("two", "one")];

    let st = state_with(schedule.clone(), &fake, &dir);
    st.scheduler.state.claim("one", anchor);
    let now = now_ms();
    tick_and_wait(&st, now).await;
    let before = log_lines(&log);
    assert_eq!(before.len(), 4, "head + link ran once: {before:?}");
    let recorded = st.scheduler.state.get("one");

    // THE RESTART: a brand-new AppState over the same state dir.
    drop(st);
    let restarted = state_with(schedule, &fake, &dir);
    assert_eq!(
        restarted.scheduler.state.get("one"),
        recorded,
        "the record must be read back from disk, not rebuilt"
    );
    tick_and_wait(&restarted, now).await;
    tick_and_wait(&restarted, now + 60_000).await;
    assert_eq!(
        log_lines(&log),
        before,
        "a restart must never replay an occurrence that already ran"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Safety + observability ---------------------------------------------------

#[tokio::test]
async fn a_malformed_entry_is_disabled_individually_and_its_neighbours_still_run() {
    // A scheduler misconfiguration must not take the service down — or its neighbours
    // with it. The offender is reported by name on the endpoint rather than merely
    // vanishing from the list.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![
            head("one", &at),
            // Both `at` and `after`: intent unknowable, so this ONE entry is disabled.
            ScheduleToml {
                after: Some("one".to_string()),
                ..head("broken", &at)
            },
            // An `at` that is not a time.
            head("bad-time", "half past two"),
            link("two", "one"),
        ],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(
        log_lines(&log),
        vec![
            "start MARKER-one",
            "end MARKER-one",
            "start MARKER-two",
            "end MARKER-two",
        ],
        "the healthy chain runs exactly as if the bad entries were not there"
    );
    let body = schedule_body(&st).await;
    let invalid = body["invalid"].as_array().unwrap();
    assert_eq!(invalid.len(), 2, "{invalid:?}");
    let ids: Vec<&str> = invalid.iter().map(|e| e["id"].as_str().unwrap()).collect();
    assert!(
        ids.contains(&"broken") && ids.contains(&"bad-time"),
        "{ids:?}"
    );
    assert!(invalid.iter().any(|e| e["reason"]
        .as_str()
        .unwrap()
        .contains("exactly one is required")));
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_missing_prompt_file_is_a_failed_run_with_that_reason_not_a_panic() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![ScheduleToml {
            prompt: None,
            prompt_file: Some("prompts/absent.md".to_string()),
            ..head("one", &at)
        }],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Failed));
    assert!(
        rec.last_reason.contains("could not read prompt_file"),
        "{:?}",
        rec.last_reason
    );
    assert!(log_lines(&log).is_empty());
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_endpoint_answers_did_it_run_today_and_how_long_in_one_request() {
    // THE WHOLE POINT OF THE OBSERVABILITY ENDPOINT. One authenticated request must
    // answer it — no file timestamps, no log archaeology.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.2");
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);
    st.scheduler.state.claim("one", anchor);

    // Unauthenticated callers learn nothing.
    let resp = app(st.clone())
        .oneshot(schedule_request(None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Before the run: the shape is already there, with no outcome yet.
    let before = schedule_body(&st).await;
    assert_eq!(before["persistent"], true);
    let r = row(&before, "one");
    assert_eq!(r["kind"], "head");
    assert_eq!(r["at"], at);
    assert!(r["next_fire_ms"].is_u64(), "a head reports its next fire");
    assert!(r["last_outcome"].is_null());
    let l = row(&before, "two");
    assert_eq!(l["kind"], "link");
    assert_eq!(l["after"], "one");
    assert_eq!(l["after_on"], "success");
    assert!(l["next_fire_ms"].is_null(), "a link has no clock time");

    tick_and_wait(&st, now_ms()).await;

    let after = schedule_body(&st).await;
    let r = row(&after, "one");
    assert_eq!(r["last_outcome"], "ran");
    assert!(r["last_fire_ms"].is_u64());
    assert!(r["last_completion_ms"].is_u64());
    let took = r["last_duration_ms"].as_u64().unwrap();
    assert!(
        took >= 200,
        "the recorded duration is the real one: {took}ms"
    );
    assert_eq!(r["running"], false);

    // And the turn ITSELF is one more request away, on the ordinary result endpoint —
    // a scheduled turn is a turn like any other.
    let job_id = r["last_job_id"].as_str().unwrap();
    let v = result_status(&st, job_id).await;
    assert_eq!(v["status"], "done");
    assert_eq!(v["response"], "ok");

    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_disabled_job_never_fires_and_says_so() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![ScheduleToml {
            enabled: Some(false),
            ..head("one", &at)
        }],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert!(log_lines(&log).is_empty());
    assert_eq!(st.scheduler.state.get("one").outcome(), None);
    let body = schedule_body(&st).await;
    let r = row(&body, "one");
    assert_eq!(r["enabled"], false);
    assert!(
        r["next_fire_ms"].is_null(),
        "a disabled job is not waiting for anything"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_per_job_timeout_override_is_applied_and_clamped() {
    // The long-running link's own run limit backs its turn. A value past the hard
    // ceiling is clamped rather than honored.
    assert_eq!(clamp_timeout_secs(900), 900);
    assert_eq!(clamp_timeout_secs(u64::MAX), HARD_TIMEOUT_CEILING);

    let dir = temp_state_dir();
    // A child that outlives a ONE SECOND limit: the turn must die at the limit, which
    // is how we can see that the per-job override was the limit actually applied.
    let fake = write_fake_claude(
        "#!/bin/sh\n\
         sleep 30\n\
         printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"too late\"}'\n",
    );
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![ScheduleToml {
            timeout_secs: Some(1),
            ..head("one", &at)
        }],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("one");
    assert_eq!(rec.outcome(), Some(Outcome::Failed));
    assert!(
        rec.last_reason.contains("1s run limit"),
        "the job's own limit backed the turn, not the global {}s: {:?}",
        st.cfg.timeout_secs,
        rec.last_reason
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}
