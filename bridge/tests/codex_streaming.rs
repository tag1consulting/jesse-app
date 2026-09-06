//! **DOES THE TEXT REACH THE CLIENT BEFORE THE TURN ENDS?** That is the whole question this
//! change was made to answer yes to, and it is the one question a unit test cannot settle.
//!
//! # Why a paced subprocess
//!
//! Every assertion here is about ORDER IN TIME, and the driver's own unit tests
//! (`harness::codex_app_server::tests`) cannot see time at all: they feed notifications in
//! and check what came out, which proves the mapping and proves nothing about when. A
//! synthetic stream of completed messages would pass those tests on a harness that buffered
//! the entire turn and flushed it at the end — which is exactly the behaviour that was wrong
//! before this change, so a test that cannot tell the two apart is not cover for it.
//!
//! So the fixture PAUSES: one delta, a wait, a second delta, a wait, then the completed item
//! and the turn. The waits are what make "the first delta reached the client-facing stream
//! before the turn completed" a claim with content.
//!
//! # What is real here and what is not
//!
//! Real: `Codex::command` builds the child, the shipping [`CodexAppServerDriver`] talks to
//! it, `run_claude_streaming` drives it, and a real `JobStore` carries the frames — which is
//! the same accumulator `sse.rs` snapshots for a client. Not real: the child, which is a
//! `/bin/sh` stand-in speaking the App Server's frame. It is the bridge's MODEL of codex-cli
//! and cannot be evidence for that model being right; `tests/codex_live_turn.rs` is where the
//! real binary is asked.
mod common;
use common::*;
use jesse_bridge::*;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long the fixture waits between the first delta and the second, and again before it
/// completes the turn. Long enough that a buffered implementation cannot accidentally look
/// prompt, short enough that the test costs a second and a half.
const PACE_MS: u64 = 700;

/// A fake `codex app-server` that answers ONE turn, slowly and on purpose.
///
/// POSIX `sh`: CI's `/bin/sh` is dash. No arrays, no `$RANDOM`, no `[[`.
///
/// `@MODE@` is substituted before the script is written, so the mode travels IN THE SCRIPT
/// rather than in the environment. That is not a style choice: these tests run concurrently
/// in one process, and a `set_var` would be read by whichever child happened to spawn next.
/// One fixture serves every case:
///   * `""` — the paced happy path.
///   * `auth` — a JSON-RPC error on `turn/start` naming a 401, which is what an expired
///     subscription login looks like from here.
///   * `die` — exits the moment the turn starts, which is what a crashed child looks like.
const FAKE_APP_SERVER: &str = r#"#!/bin/sh
field() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
num()   { printf '%s' "$2" | sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p"; }
mode="@MODE@"
pace="@PACE@"

while IFS= read -r line; do
  rid=$(num id "$line")
  method=$(field method "$line")
  case "$method" in
    initialize)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"userAgent\":\"fake\",\"codexHome\":\"$CODEX_HOME\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\"}}"
      ;;
    initialized) ;;
    thread/start)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"th-paced\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"thread\":{\"id\":\"th-paced\"}}}"
      ;;
    turn/start)
      if [ "$mode" = "die" ]; then exit 3; fi
      if [ "$mode" = "auth" ]; then
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"error\":{\"code\":-32000,\"message\":\"unexpected status 401 Unauthorized: token expired\"}}"
        continue
      fi
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"inProgress\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/started\",\"params\":{\"threadId\":\"th-paced\",\"turnId\":\"turn-1\",\"startedAtMs\":0,\"item\":{\"type\":\"agentMessage\",\"id\":\"msg-1\",\"text\":\"\",\"phase\":\"final_answer\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"th-paced\",\"turnId\":\"turn-1\",\"itemId\":\"msg-1\",\"delta\":\"FIRST\"}}"
      sleep "$pace"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/started\",\"params\":{\"threadId\":\"th-paced\",\"turnId\":\"turn-1\",\"startedAtMs\":0,\"item\":{\"type\":\"commandExecution\",\"id\":\"e1\",\"command\":\"ls\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"th-paced\",\"turnId\":\"turn-1\",\"itemId\":\"msg-1\",\"delta\":\" SECOND\"}}"
      sleep "$pace"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/completed\",\"params\":{\"threadId\":\"th-paced\",\"turnId\":\"turn-1\",\"completedAtMs\":0,\"item\":{\"type\":\"agentMessage\",\"id\":\"msg-1\",\"text\":\"FIRST SECOND\",\"phase\":\"final_answer\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"threadId\":\"th-paced\",\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"completed\"}}}"
      ;;
  esac
done
exit 0
"#;

/// A scratch vault, a `JobStore`, and a `Config` pointing `codex_bin` at the fixture.
struct Rig {
    _dir: std::path::PathBuf,
    bin: std::path::PathBuf,
    cfg: Config,
    jobs: Arc<JobStore>,
    jid: String,
}

impl Rig {
    fn new(tag: &str, mode: &str) -> Rig {
        let script = FAKE_APP_SERVER
            .replace("@MODE@", mode)
            .replace("@PACE@", &format!("{:.3}", PACE_MS as f64 / 1000.0));
        let bin = write_fake_claude(&script);
        let dir = std::env::temp_dir().join(format!(
            "jesse-codex-stream-{tag}-{}-{}",
            std::process::id(),
            random_hex()
        ));
        std::fs::create_dir_all(dir.join("state")).expect("the scratch state dir");
        std::fs::create_dir_all(dir.join("vault")).expect("the scratch vault");
        let mut cfg = test_config();
        cfg.state_dir = Some(dir.join("state").to_string_lossy().into_owned());
        cfg.home = dir.to_string_lossy().into_owned();
        cfg.vault = dir.join("vault").to_string_lossy().into_owned();
        cfg.codex_bin = bin.to_string_lossy().into_owned();
        cfg.timeout_secs = 30;
        cfg.harnesses = Arc::new(HarnessRegistry::for_models(
            KNOWN_HARNESS_IDS.iter().copied(),
        ));
        let jobs = Arc::new(JobStore::new(
            Duration::from_secs(cfg.job_ttl_secs),
            Duration::from_secs(cfg.retrieval_grace_secs),
            None,
        ));
        let jid = format!("stream-{tag}");
        jobs.stream_register(&jid);
        Rig {
            _dir: dir,
            bin,
            cfg,
            jobs,
            jid,
        }
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.bin);
        let _ = std::fs::remove_dir_all(&self._dir);
    }
}

fn codex_model() -> ActiveModel {
    let mut m = ActiveModel::ambient();
    m.harness = CODEX_ID.to_string();
    m.level = Capability::Read;
    m
}

/// Poll the job's stream accumulator — the SAME snapshot `sse.rs` hands a client — until it
/// contains `needle`, or give up. Returns how long it took.
async fn wait_for_snapshot(jobs: &Arc<JobStore>, jid: &str, needle: &str) -> Option<Duration> {
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(10) {
        if jobs
            .stream_snapshot(jid)
            .is_some_and(|s| s.contains(needle))
        {
            return Some(started.elapsed());
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    None
}

/// **THE ACCEPTANCE PROPERTY.** The first chunk of the answer is readable by a client while
/// the turn is still running, and the second chunk is not yet — which is what "the reply
/// grows on the phone" means, stated as something a test can fail.
#[tokio::test(flavor = "multi_thread")]
async fn the_first_delta_reaches_the_client_before_the_turn_completes() {
    let rig = Rig::new("first-delta", "");
    let cfg = rig.cfg.clone();
    let jobs = rig.jobs.clone();
    let jid = rig.jid.clone();

    let turn = tokio::spawn(async move {
        let spawned = SpawnedSessions::new();
        run_claude_streaming(
            &cfg,
            "count",
            None,
            &jobs,
            &jid,
            &codex_model(),
            &Codex,
            &spawned,
            None,
            None,
            None,
            &TurnTrace::from_cfg(&cfg),
        )
        .await
    });

    wait_for_snapshot(&rig.jobs, &rig.jid, "FIRST")
        .await
        .expect("the first delta must reach the stream");
    let saw_first_at = Instant::now();

    // THE TURN IS STILL RUNNING. Without this the test would pass on an implementation that
    // delivered everything at the end and simply happened to be polled afterwards.
    assert!(
        !turn.is_finished(),
        "the first delta arrived only after the turn had already finished — that is \
         whole-answer delivery, not streaming"
    );
    // AND THE SECOND CHUNK HAS NOT ARRIVED YET, which is what says the client is seeing the
    // answer BUILD rather than seeing it complete a moment early.
    let snapshot = rig.jobs.stream_snapshot(&rig.jid).unwrap_or_default();
    assert!(
        !snapshot.contains("SECOND"),
        "the whole answer was already there: {snapshot:?}"
    );

    let (text, session, _usage) = turn.await.expect("the turn task").expect("a turn");
    // **THE LEAD IS REAL, AND MEASURED THE ONLY WAY THAT IS NOT FLAKY.** Not "the delta
    // arrived within N milliseconds of the test starting" — that clock includes a process
    // spawn and a handshake, and it fails on a loaded machine for reasons that have nothing
    // to do with buffering. What has content is the gap BETWEEN the client seeing the text
    // and the answer existing: the fixture pauses twice, so a client that is genuinely being
    // fed early is ahead by at least one of those pauses.
    let lead = saw_first_at.elapsed();
    assert!(
        lead >= Duration::from_millis(PACE_MS),
        "the client saw the first chunk only {lead:?} before the turn finished — the \
         fixture pauses {PACE_MS}ms twice after that chunk, so anything less means the \
         stream was not being fed as the child produced it"
    );
    assert_eq!(text, "FIRST SECOND", "the completed item is authoritative");
    assert_eq!(session.as_deref(), Some("th-paced"));

    // **NO DOUBLED TEXT.** The accumulator is what a reconnecting client replays, so a driver
    // that pushed the completed item as another delta would show the answer twice on a
    // reconnect and once live — the hardest kind of bug to see and the easiest to ship.
    assert_eq!(
        rig.jobs.stream_snapshot(&rig.jid).unwrap_or_default(),
        "FIRST SECOND",
        "the replayed stream must be the deltas and nothing else"
    );
}

/// Tool activity and answer text INTERLEAVE, and both reach the client in the order they
/// happened. The fixture opens a `commandExecution` between the two deltas.
#[tokio::test(flavor = "multi_thread")]
async fn tool_activity_and_text_interleave_in_order() {
    let rig = Rig::new("interleave", "");
    let (_text, _activity, mut rx) = rig
        .jobs
        .stream_subscribe(&rig.jid)
        .expect("subscribed before the turn starts");
    let watcher = tokio::spawn(async move {
        let mut seen = Vec::new();
        while let Ok(frame) = rx.recv().await {
            match frame {
                StreamFrame::Delta(d) => seen.push(format!("text:{d}")),
                StreamFrame::Activity(a) => seen.push(format!("tool:{}", a.name)),
                StreamFrame::Done { .. } | StreamFrame::Error(_) | StreamFrame::Cancelled => break,
            }
        }
        seen
    });

    let cfg = rig.cfg.clone();
    let jobs = rig.jobs.clone();
    let jid = rig.jid.clone();
    let spawned = SpawnedSessions::new();
    let out = run_claude_streaming(
        &cfg,
        "count",
        None,
        &jobs,
        &jid,
        &codex_model(),
        &Codex,
        &spawned,
        None,
        None,
        None,
        &TurnTrace::from_cfg(&cfg),
    )
    .await;
    assert!(out.is_ok(), "{out:?}");
    rig.jobs.stream_finish(&rig.jid, StreamFrame::Cancelled);
    let seen = watcher.await.expect("the watcher");
    assert_eq!(
        seen,
        vec!["text:FIRST", "tool:Bash", "text: SECOND"],
        "the client's frames must be in the order the child produced them"
    );
}

/// A CANCELLED TURN KEEPS WHAT IT HAD SAID AND DOES NOT CLAIM TO HAVE FINISHED.
///
/// Cancellation on this path is a task abort: the future is dropped, its pipes close, and
/// `kill_on_drop` reaps the child. What must survive is the text the client already saw —
/// visibly incomplete, never promoted to an answer.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_turn_leaves_its_partial_text_visibly_unfinished() {
    let rig = Rig::new("cancel", "");
    let cfg = rig.cfg.clone();
    let jobs = rig.jobs.clone();
    let jid = rig.jid.clone();

    let turn = tokio::spawn(async move {
        let spawned = SpawnedSessions::new();
        run_claude_streaming(
            &cfg,
            "count",
            None,
            &jobs,
            &jid,
            &codex_model(),
            &Codex,
            &spawned,
            None,
            None,
            None,
            &TurnTrace::from_cfg(&cfg),
        )
        .await
    });

    wait_for_snapshot(&rig.jobs, &rig.jid, "FIRST")
        .await
        .expect("the first delta");
    turn.abort();
    assert!(
        turn.await.is_err(),
        "an aborted task must not return a turn"
    );

    let snapshot = rig.jobs.stream_snapshot(&rig.jid).unwrap_or_default();
    assert_eq!(
        snapshot, "FIRST",
        "a cancelled turn keeps exactly what the client already saw — no more, and not \
         rounded up to the whole answer"
    );
}

/// A child that dies mid-turn fails the turn rather than returning the partial text as an
/// answer. The distinction is the one `resolve_stream_outcome` exists to make: an answer that
/// reached the client is not the same as a turn that succeeded.
#[tokio::test(flavor = "multi_thread")]
async fn a_child_that_exits_mid_turn_fails_the_turn() {
    let rig = Rig::new("die", "die");
    let spawned = SpawnedSessions::new();
    let out = run_claude_streaming(
        &rig.cfg,
        "count",
        None,
        &rig.jobs,
        &rig.jid,
        &codex_model(),
        &Codex,
        &spawned,
        None,
        None,
        None,
        &TurnTrace::from_cfg(&rig.cfg),
    )
    .await;
    let Err((_status, message)) = out else {
        panic!("a child that exited before completing the turn must fail it: {out:?}");
    };
    assert!(
        message.contains("codex app server"),
        "the failure should name where it came from: {message}"
    );
    // The thread it bound before dying is still recorded — a turn that dies mid-flight has
    // still said which session it owns.
    assert_eq!(spawned.ids(), vec!["th-paced".to_string()]);
}

/// **AN EXHAUSTED OR EXPIRED SUBSCRIPTION IS FATAL AND SAYS SO, AND IS NEVER RETRIED.**
///
/// There is no interactive `codex login` on a bridge host, so retrying dead credentials
/// spends the turn budget three times to say the same thing. The classification travels
/// through the same `codex_failure` the stderr channel uses, so both spellings of the failure
/// reach the operator in one wording.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_subscription_login_is_fatal_and_names_the_remedy() {
    let rig = Rig::new("auth", "auth");
    let spawned = SpawnedSessions::new();
    let out = run_claude_streaming(
        &rig.cfg,
        "count",
        None,
        &rig.jobs,
        &rig.jid,
        &codex_model(),
        &Codex,
        &spawned,
        None,
        None,
        None,
        &TurnTrace::from_cfg(&rig.cfg),
    )
    .await;
    let Err((_status, message)) = out else {
        panic!("a 401 must fail the turn: {out:?}");
    };
    assert!(message.contains(CODEX_ID), "{message}");
    assert!(message.contains("re-authenticate"), "{message}");
    assert!(
        message.contains("other harnesses are unaffected"),
        "{message}"
    );
    // NOT an API key, not another provider: the bridge has no automatic fallback and this is
    // the test that says so. The message names the operator's remedy and nothing else.
    assert!(
        !message.to_lowercase().contains("api key"),
        "an expired subscription must never suggest a billed fallback: {message}"
    );
}
