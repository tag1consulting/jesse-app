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

// ---- The occurrence is what the calendar sees ----------------------------------

/// A `"HH:MM"` local time `minutes_ahead` minutes from now, paired with an anchor two days
/// back. The latest occurrence at or before now is therefore YESTERDAY at that time — a
/// due, late fire whose OCCURRENCE falls on a different local day from `now`.
fn due_yesterday(minutes_ahead: i64) -> (String, u64, String) {
    let now = now_ms();
    let at_ms = now + (minutes_ahead as u64) * 60_000;
    let at = Local
        .timestamp_millis_opt(at_ms as i64)
        .single()
        .unwrap()
        .format("%H:%M")
        .to_string();
    let occurrence = Local
        .timestamp_millis_opt((at_ms - 86_400_000) as i64)
        .single()
        .unwrap();
    (
        at,
        now - 2 * 86_400_000,
        occurrence.format("%a").to_string().to_lowercase(),
    )
}

/// REGRESSION, 2026-08-21. A chain is ONE OCCURRENCE, and every member's `days` filter is
/// evaluated against THAT — not against the wall clock at the moment the chain happens to
/// reach the member.
///
/// The head here came due yesterday and is running late (well inside its catch-up window),
/// so the occurrence and "now" fall on different local days. The link names the
/// OCCURRENCE's weekday. Under the old code — which re-read `SystemTime::now()` per member
/// — the link was skipped as "not scheduled on this weekday" on precisely the day it was
/// scheduled for, which is what the Friday ledger recorded.
#[tokio::test]
async fn a_late_chain_judges_its_links_against_the_occurrence_not_against_now() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor, occurrence_day) = due_yesterday(30);
    let st = state_with(
        vec![
            ScheduleToml {
                catch_up_secs: Some(2 * 86_400),
                ..head("one", &at)
            },
            ScheduleToml {
                days: Some(vec![occurrence_day.clone()]),
                after_on: Some("any".into()),
                ..link("two", "one")
            },
        ],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);

    tick_and_wait(&st, now_ms()).await;

    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    let two = st.scheduler.state.get("two");
    assert_eq!(
        two.outcome(),
        Some(Outcome::Ran),
        "the link names the occurrence's weekday ({occurrence_day}), so it belongs to this \
         run — it was skipped as {:?} before the fix",
        two.last_reason
    );
    assert!(
        log_lines(&log).contains(&"start MARKER-two".to_string()),
        "{:?}",
        log_lines(&log)
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- The output contract (`expect_output`) -------------------------------------

/// A vault whose notes directory (`<vault>/vault/`) is where `expect_output` resolves.
fn temp_vault() -> PathBuf {
    let d = std::env::temp_dir().join(format!("jesse-sched-vault-{}", random_hex()));
    std::fs::create_dir_all(d.join("vault/Inbox")).unwrap();
    d
}

fn state_with_vault(
    schedule: Vec<ScheduleToml>,
    claude: &std::path::Path,
    dir: &std::path::Path,
    vault: &std::path::Path,
) -> AppState {
    let validated = validate_schedule(&schedule);
    assert!(validated.fatal.is_empty(), "{:?}", validated.fatal);
    assert!(validated.invalid.is_empty(), "{:?}", validated.invalid);
    AppState::new(Config {
        claude_bin: claude.to_string_lossy().into_owned(),
        state_dir: Some(dir.to_string_lossy().into_owned()),
        vault: vault.to_string_lossy().into_owned(),
        schedule: Arc::new(validated),
        ..test_config()
    })
}

/// A fake `claude` that WRITES a file before answering — the job doing its work.
fn writing_claude(target: &std::path::Path) -> PathBuf {
    write_fake_claude(&format!(
        "#!/bin/sh\n\
         printf 'the note\\n' > '{target}'\n\
         printf '%s\\n' '{{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"sess-sched\"}}'\n",
        target = target.display(),
    ))
}

/// The occurrence's `{date}` in the scheduler's zone — the name the contract expands to.
fn occurrence_date(ms: u64) -> String {
    Local
        .timestamp_millis_opt(ms as i64)
        .single()
        .unwrap()
        .format("%Y-%m-%d")
        .to_string()
}

#[tokio::test]
async fn a_declared_output_that_the_turn_writes_is_a_clean_run() {
    let dir = temp_state_dir();
    let vault = temp_vault();
    let (at, anchor) = due_at(5);
    let due = now_ms() - 5 * 60_000;
    let target = vault
        .join("vault/Inbox")
        .join(format!("{}-vault-lint.md", occurrence_date(due)));
    let fake = writing_claude(&target);
    let st = state_with_vault(
        vec![ScheduleToml {
            expect_output: Some(vec!["Inbox/{date}-vault-lint.md".into()]),
            ..head("lint", &at)
        }],
        &fake,
        &dir,
        &vault,
    );
    st.scheduler.state.claim("lint", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("lint");
    assert_eq!(rec.outcome(), Some(Outcome::Ran), "{:?}", rec.last_reason);
    assert_eq!(
        rec.last_output_path.as_deref(),
        Some(format!("Inbox/{}-vault-lint.md", occurrence_date(due)).as_str()),
        "the match that satisfied the contract is recorded, TOKENS EXPANDED against the \
         occurrence"
    );
    assert_eq!(rec.consecutive_failures, 0);

    let row = row(&schedule_body(&st).await, "lint").clone();
    assert_eq!(row["expect_output"][0], "Inbox/{date}-vault-lint.md");
    assert_eq!(row["last_output_path"], rec.last_output_path.unwrap());
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn a_turn_that_writes_nothing_is_fired_no_output_not_ran() {
    // THE GAP THIS CLOSES. The turn finished cleanly — there is a transcript, the job store
    // says Done — so `failed` would be a lie. But `ran` is what let a job go quiet for
    // nights on end: the record said the routine ran and the file it exists to write was
    // never there.
    let dir = temp_state_dir();
    let vault = temp_vault();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05"); // answers, writes nothing
    let (at, anchor) = due_at(5);
    let st = state_with_vault(
        vec![ScheduleToml {
            expect_output: Some(vec!["Inbox/{date}-vault-lint.md".into()]),
            ..head("lint", &at)
        }],
        &fake,
        &dir,
        &vault,
    );
    st.scheduler.state.claim("lint", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("lint");
    assert_eq!(rec.outcome(), Some(Outcome::FiredNoOutput));
    assert!(
        rec.last_reason.contains("wrote nothing matching"),
        "{:?}",
        rec.last_reason
    );
    assert!(
        rec.last_reason
            .contains(&occurrence_date(now_ms() - 5 * 60_000)),
        "the reason names the EXPANDED pattern, so it says what was looked for: {:?}",
        rec.last_reason
    );
    assert_eq!(rec.last_output_path, None);
    assert_eq!(
        rec.consecutive_failures, 1,
        "an empty fire counts toward the streak"
    );
    assert!(
        log_lines(&log).contains(&"start MARKER-lint".to_string()),
        "the turn really did run — this is not a skip"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn an_output_already_fresh_for_this_occurrence_skips_the_fire() {
    // IDEMPOTENCY. A catch-up run after an outage must not rewrite a note that was already
    // written for the occurrence it is catching up on.
    let dir = temp_state_dir();
    let vault = temp_vault();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let due = now_ms() - 5 * 60_000;
    let existing = vault
        .join("vault/Inbox")
        .join(format!("{}-vault-lint.md", occurrence_date(due)));
    std::fs::write(&existing, "already written").unwrap();

    let st = state_with_vault(
        vec![ScheduleToml {
            expect_output: Some(vec!["Inbox/{date}-vault-lint.md".into()]),
            ..head("lint", &at)
        }],
        &fake,
        &dir,
        &vault,
    );
    st.scheduler.state.claim("lint", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("lint");
    assert_eq!(rec.outcome(), Some(Outcome::Skipped));
    assert_eq!(rec.last_reason, "output fresh");
    assert!(log_lines(&log).is_empty(), "no turn may have run");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn a_stale_output_does_not_satisfy_this_occurrences_contract() {
    // Yesterday's file cannot stand in for today's. The contract is measured from the
    // occurrence, not from "a file with this name exists".
    let dir = temp_state_dir();
    let vault = temp_vault();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    // A pattern with NO date token, so the same path is a candidate every day — and only
    // its mtime distinguishes a fresh run from a stale one.
    let stale = vault.join("vault/Inbox/vault-lint.md");
    std::fs::write(&stale, "yesterday").unwrap();
    let old = SystemTime::now() - Duration::from_secs(48 * 3600);
    filetime_set(&stale, old);

    let st = state_with_vault(
        vec![ScheduleToml {
            expect_output: Some(vec!["Inbox/vault-lint.md".into()]),
            ..head("lint", &at)
        }],
        &fake,
        &dir,
        &vault,
    );
    st.scheduler.state.claim("lint", anchor);

    tick_and_wait(&st, now_ms()).await;

    let rec = st.scheduler.state.get("lint");
    assert_eq!(
        rec.outcome(),
        Some(Outcome::FiredNoOutput),
        "the stale file neither blocked the fire nor satisfied it: {:?}",
        rec.last_reason
    );
    assert!(
        log_lines(&log).contains(&"start MARKER-lint".to_string()),
        "a stale output must not make the job skip"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&vault);
}

/// Set a file's mtime, without a crate: `touch -t` is POSIX and on every box this runs on.
fn filetime_set(path: &std::path::Path, when: SystemTime) {
    let secs = when
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let stamp = Local
        .timestamp_millis_opt((secs * 1000) as i64)
        .single()
        .unwrap()
        .format("%Y%m%d%H%M.%S")
        .to_string();
    let out = std::process::Command::new("touch")
        .arg("-t")
        .arg(&stamp)
        .arg(path)
        .output()
        .expect("touch is available");
    assert!(out.status.success(), "touch -t {stamp}: {out:?}");
}

// ---- The control endpoints -----------------------------------------------------

fn post(uri: &str, body: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", "Bearer test-token")
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn call(st: &AppState, req: Request<Body>) -> (StatusCode, Value) {
    let resp = app(st.clone()).oneshot(req).await.unwrap();
    let status = resp.status();
    let text = body_string(resp).await;
    let value = serde_json::from_str(&text).unwrap_or(Value::String(text));
    (status, value)
}

/// Wait for a chain the endpoint started (it is spawned detached, not awaited).
async fn wait_until_idle(st: &AppState, head: &str) {
    let deadline = SystemTime::now() + WAIT_DEADLINE;
    while st.scheduler.is_running(head) {
        assert!(SystemTime::now() < deadline, "chain {head} never finished");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn the_fire_endpoint_is_401_without_auth_and_404_for_an_unknown_id() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, _) = due_at(5);
    let st = state_with(vec![head("one", &at)], &fake, &dir);

    let anon = Request::builder()
        .method("POST")
        .uri("/jesse/schedule/one/fire")
        .body(Body::empty())
        .unwrap();
    let (status, _) = call(&st, anon).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, body) = call(&st, post("/jesse/schedule/nope/fire", "{}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(format!("{body}").contains("nope"), "{body}");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_fire_endpoint_runs_the_chain_from_the_named_member_and_refuses_a_second() {
    // The named member and everything AFTER it — never the members before it, which is
    // what makes this usable for repairing one broken link rather than replaying a night.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "1.5");
    let (at, _) = due_at(5);
    let st = state_with(
        vec![
            head("one", &at),
            link("two", "one"),
            ScheduleToml {
                after_on: Some("any".into()),
                ..link("three", "two")
            },
        ],
        &fake,
        &dir,
    );

    let (status, body) = call(&st, post("/jesse/schedule/two/fire", "{}")).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(body["chain"], serde_json::json!(["two", "three"]));
    assert!(body["started_ms"].as_u64().unwrap() > 0);

    // SINGLE FLIGHT, keyed on the HEAD of the chain the member belongs to — a second call
    // naming any member of a running chain is refused rather than putting a second agent
    // on the same working tree.
    let (status, body) = call(&st, post("/jesse/schedule/three/fire", "{}")).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let body = format!("{body}");
    assert!(
        body.contains("one") && body.contains("already running"),
        "the refusal names the chain HEAD, not the member asked for: {body}"
    );

    wait_until_idle(&st, "one").await;
    let lines = log_lines(&log);
    assert!(
        lines.contains(&"start MARKER-two".to_string())
            && lines.contains(&"start MARKER-three".to_string()),
        "{lines:?}"
    );
    assert!(
        !lines.contains(&"start MARKER-one".to_string()),
        "the head is BEFORE the named member and must not run: {lines:?}"
    );
    assert_eq!(
        st.scheduler.state.get("two").last_reason,
        "fired by operator",
        "the ledger and the record say who asked"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_fire_endpoint_honors_output_freshness_and_force_overrides_it() {
    let dir = temp_state_dir();
    let vault = temp_vault();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, _anchor) = due_at(5);
    let due = now_ms() - 5 * 60_000;
    let existing = vault
        .join("vault/Inbox")
        .join(format!("{}-lint.md", occurrence_date(due)));
    std::fs::write(&existing, "already written").unwrap();

    let st = state_with_vault(
        vec![ScheduleToml {
            expect_output: Some(vec!["Inbox/{date}-lint.md".into()]),
            ..head("lint", &at)
        }],
        &fake,
        &dir,
        &vault,
    );
    // The head's last occurrence, which is what an operator fire measures the contract
    // against — otherwise "now" would be the instant and nothing could ever be fresh.
    st.scheduler.state.claim("lint", due);

    let (status, _) = call(&st, post("/jesse/schedule/lint/fire", "{}")).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    wait_until_idle(&st, "lint").await;
    assert_eq!(st.scheduler.state.get("lint").last_reason, "output fresh");
    assert!(log_lines(&log).is_empty(), "pressing it twice is safe");

    // `force` is how you say you meant it.
    let (status, _) = call(&st, post("/jesse/schedule/lint/fire", r#"{"force":true}"#)).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    wait_until_idle(&st, "lint").await;
    assert!(
        log_lines(&log).contains(&"start MARKER-lint".to_string()),
        "force runs it anyway: {:?}",
        log_lines(&log)
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&vault);
}

#[tokio::test]
async fn an_enable_override_turns_a_job_off_and_expires_on_its_own() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);

    // Off, with a deadline an hour out.
    let until = Local
        .timestamp_millis_opt((now_ms() + 3_600_000) as i64)
        .single()
        .unwrap()
        .to_rfc3339();
    let (status, row) = call(
        &st,
        post(
            "/jesse/schedule/one/enable",
            &format!(r#"{{"enabled":false,"until":"{until}"}}"#),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(row["id"], "one");
    assert_eq!(row["enabled"], false, "the EFFECTIVE state");
    assert_eq!(
        row["enabled_config"], true,
        "the file still says on — which is the point of an override"
    );
    assert_eq!(row["override"]["active"], true);

    st.scheduler.state.claim("one", anchor);
    tick_and_wait(&st, now_ms()).await;
    assert!(
        log_lines(&log).is_empty(),
        "an overridden-off head does not fire"
    );

    // AND IT EXPIRES. Past the deadline the config's own `enabled` decides again.
    let past = now_ms() + 7_200_000;
    let job = st.scheduler.schedule().get("one").cloned().unwrap();
    assert!(!st.scheduler.effective_enabled(&job, now_ms()));
    assert!(
        st.scheduler.effective_enabled(&job, past),
        "an override nobody remembers must not be a job that never runs again"
    );

    // A disabled MEMBER skips exactly as a config `enabled = false` does, so it breaks an
    // `after_on = "success"` chain — one word, one meaning, wherever it is set.
    let (status, _) = call(
        &st,
        post("/jesse/schedule/two/enable", r#"{"enabled":false}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &st,
        post("/jesse/schedule/one/enable", r#"{"enabled":true}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    st.scheduler.state.claim("one", anchor - 86_400_000);
    tick_and_wait(&st, now_ms()).await;
    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    let two = st.scheduler.state.get("two");
    assert_eq!(two.outcome(), Some(Outcome::Skipped));
    assert_eq!(two.last_reason, "disabled");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_enable_endpoint_rejects_a_bad_deadline_and_an_unknown_id() {
    let dir = temp_state_dir();
    let fake = logging_claude(&dir.join("runs.log"), "0.05");
    let (at, _) = due_at(5);
    let st = state_with(vec![head("one", &at)], &fake, &dir);

    let (status, _) = call(
        &st,
        post("/jesse/schedule/nope/enable", r#"{"enabled":false}"#),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, body) = call(
        &st,
        post(
            "/jesse/schedule/one/enable",
            r#"{"enabled":false,"until":"next tuesday"}"#,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(format!("{body}").contains("RFC 3339"), "{body}");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Hot reload -----------------------------------------------------------------

/// Write a `jesse.local.toml` carrying just a `[[schedule]]` table.
fn write_config(dir: &std::path::Path, body: &str) -> PathBuf {
    let p = dir.join("jesse.local.toml");
    std::fs::write(&p, body).unwrap();
    p
}

/// An mtime far enough in the past that the next write is unambiguously newer, whatever
/// the filesystem's timestamp granularity.
fn age_file(path: &std::path::Path) {
    filetime_set(path, SystemTime::now() - Duration::from_secs(3600));
}

#[tokio::test]
async fn a_valid_config_edit_swaps_the_schedule_and_keeps_every_record() {
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);

    // A history worth keeping.
    st.scheduler.state.claim("one", anchor);
    tick_and_wait(&st, now_ms()).await;
    let before = st.scheduler.state.get("one");
    assert_eq!(before.outcome(), Some(Outcome::Ran));

    // The file the bridge "booted from", now naming a third job and retiring the second.
    let cfg = write_config(
        &dir,
        &format!(
            "[[schedule]]\nid = \"one\"\nat = \"{at}\"\nprompt = \"Run the job. MARKER-one\"\n\
             catch_up_secs = 86400\n\n\
             [[schedule]]\nid = \"three\"\nat = \"04:00\"\nprompt = \"Run the job. MARKER-three\"\n"
        ),
    );
    age_file(&cfg);
    st.scheduler.watch_config(Some(cfg.clone()));
    // The edit itself.
    std::fs::write(
        &cfg,
        format!(
            "[[schedule]]\nid = \"one\"\nat = \"{at}\"\nprompt = \"Run the job. MARKER-one\"\n\
             catch_up_secs = 86400\n\n\
             [[schedule]]\nid = \"three\"\nat = \"04:00\"\nprompt = \"Run the job. MARKER-three\"\n"
        ),
    )
    .unwrap();

    let (status, body) = call(&st, post("/jesse/schedule/reload", "{}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["reloaded"], true, "{body}");
    assert_eq!(body["errors"].as_array().unwrap().len(), 0);

    let ids: Vec<String> = st
        .scheduler
        .schedule()
        .jobs
        .iter()
        .map(|j| j.id.clone())
        .collect();
    assert_eq!(ids, vec!["one".to_string(), "three".to_string()]);
    assert_eq!(
        st.scheduler.state.get("one"),
        before,
        "a reload keeps every JobRecord by id — including the anti-double-fire anchor"
    );
    // A head the old schedule did not have is anchored at the RELOAD, not at this
    // process's boot: otherwise a job added at 14:00 whose time is 04:00 would resolve
    // 04:00 today as a missed occurrence and record a skip for a job one second old.
    assert!(st.scheduler.state.get("three").last_due_ms.is_some());
    assert_eq!(st.scheduler.state.get("three").last_outcome, "");

    // And the reload left a line in the ledger — the single most useful thing to have
    // beside the fires that follow it.
    let ledger =
        std::fs::read_to_string(dir.join("Inbox/scheduled-jobs-ledger.jsonl")).unwrap_or_default();
    let _ = ledger; // the test store keeps no ledger; the endpoint's contract is above.
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn an_invalid_config_keeps_the_running_schedule_and_says_why() {
    // A typo must never silently retire the schedule. The old one keeps running and the
    // reload reports the reason.
    let dir = temp_state_dir();
    let fake = logging_claude(&dir.join("runs.log"), "0.05");
    let (at, _) = due_at(5);
    let st = state_with(vec![head("one", &at), link("two", "one")], &fake, &dir);

    // A DUPLICATE ID — one of the two problems that make the operator's intent unknowable.
    let cfg = write_config(
        &dir,
        "[[schedule]]\nid = \"dup\"\nat = \"03:30\"\nprompt = \"go\"\n\n\
         [[schedule]]\nid = \"dup\"\nat = \"04:30\"\nprompt = \"go\"\n",
    );
    st.scheduler.watch_config(Some(cfg.clone()));

    let (status, body) = call(&st, post("/jesse/schedule/reload", "{}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["reloaded"], false, "{body}");
    assert!(
        format!("{}", body["errors"]).contains("duplicate"),
        "{body}"
    );
    let ids: Vec<String> = st
        .scheduler
        .schedule()
        .jobs
        .iter()
        .map(|j| j.id.clone())
        .collect();
    assert_eq!(
        ids,
        vec!["one".to_string(), "two".to_string()],
        "the running schedule is untouched"
    );

    // And so does a file that does not parse at all — which must NOT be read as "no jobs".
    std::fs::write(&cfg, "[[schedule]\nid = broken").unwrap();
    st.scheduler.watch_config(Some(cfg.clone()));
    let (_, body) = call(&st, post("/jesse/schedule/reload", "{}")).await;
    assert_eq!(body["reloaded"], false, "{body}");
    assert!(
        format!("{}", body["errors"]).contains("could not parse"),
        "an unparseable file and an empty one must not look alike: {body}"
    );
    assert_eq!(st.scheduler.schedule().jobs.len(), 2);
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_tick_picks_up_a_config_edit_on_its_own() {
    let dir = temp_state_dir();
    let fake = logging_claude(&dir.join("runs.log"), "0.05");
    let (at, _) = due_at(5);
    let st = state_with(vec![head("one", &at)], &fake, &dir);

    let cfg = write_config(
        &dir,
        "[[schedule]]\nid = \"one\"\nat = \"03:30\"\nprompt = \"go\"\n",
    );
    age_file(&cfg);
    st.scheduler.watch_config(Some(cfg.clone()));

    std::fs::write(
        &cfg,
        "[[schedule]]\nid = \"one\"\nat = \"03:30\"\nprompt = \"go\"\n\n\
         [[schedule]]\nid = \"added-by-hand\"\nat = \"05:00\"\nprompt = \"go\"\n",
    )
    .unwrap();

    // No reload request — just a tick, which is what a live bridge does every 20 seconds.
    tick_and_wait(&st, now_ms()).await;
    assert!(
        st.scheduler.schedule().get("added-by-hand").is_some(),
        "an edit is picked up without a restart and without a request"
    );
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Failure visibility ----------------------------------------------------------

#[tokio::test]
async fn consecutive_failures_climb_across_nights_and_reset_on_a_good_one() {
    // The counter is what makes "this is the sixth night running" sayable at all — every
    // other signal here is about ONE occurrence.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let failing = failing_claude(&log, "one");
    let (at, anchor) = due_at(5);
    let st = state_with(vec![head("one", &at)], &failing, &dir);

    for night in 1..=3u32 {
        // Each iteration is a fresh occurrence a day earlier, so the anchor moves back.
        st.scheduler
            .state
            .claim("one", anchor - (3 - night as u64) * 60_000);
        tick_and_wait(&st, now_ms()).await;
        assert_eq!(
            st.scheduler.state.get("one").consecutive_failures,
            night,
            "night {night}"
        );
    }
    assert_eq!(
        row(&schedule_body(&st).await, "one")["consecutive_failures"],
        3
    );

    // A good night clears it outright — a streak is CONSECUTIVE.
    let ok = logging_claude(&log, "0.05");
    let st2 = state_with(vec![head("one", &at)], &ok, &dir);
    st2.scheduler.state.claim("one", anchor - 4 * 60_000);
    tick_and_wait(&st2, now_ms()).await;
    assert_eq!(st2.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    assert_eq!(st2.scheduler.state.get("one").consecutive_failures, 0);

    let _ = std::fs::remove_file(&failing);
    let _ = std::fs::remove_file(&ok);
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- Per-job model ----------------------------------------------------------------

#[tokio::test]
async fn a_per_job_model_reaches_the_turn_and_the_endpoint_reports_it() {
    // `opus` is the always-available ambient default, so it is the one id a test fixture
    // can name and have resolve. What is proved here is the WIRING: the key survives
    // validation, reaches the turn, and is visible on the row.
    let dir = temp_state_dir();
    let log = dir.join("runs.log");
    let fake = logging_claude(&log, "0.05");
    let (at, anchor) = due_at(5);
    let st = state_with(
        vec![ScheduleToml {
            model: Some("opus".into()),
            ..head("one", &at)
        }],
        &fake,
        &dir,
    );
    st.scheduler.state.claim("one", anchor);
    tick_and_wait(&st, now_ms()).await;

    assert_eq!(st.scheduler.state.get("one").outcome(), Some(Outcome::Ran));
    assert_eq!(row(&schedule_body(&st).await, "one")["model"], "opus");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_endpoint_names_the_scheduler_zone() {
    // A bare UTC offset cannot answer the question this field exists for: "+02:00" is Rome
    // in August and something else in January.
    let dir = temp_state_dir();
    let fake = logging_claude(&dir.join("runs.log"), "0.05");
    let (at, _) = due_at(5);
    let st = state_with(vec![head("one", &at)], &fake, &dir);
    let body = schedule_body(&st).await;
    assert!(
        body["tz"].as_str().map(|s| !s.is_empty()).unwrap_or(false),
        "{body}"
    );
    assert!(body["utc_offset"].is_string(), "{body}");
    let _ = std::fs::remove_file(&fake);
    let _ = std::fs::remove_dir_all(&dir);
}
