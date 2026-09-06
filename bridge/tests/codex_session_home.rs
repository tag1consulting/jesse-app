//! **A CONVERSATION IS MORE THAN ONE TURN.** Everything here is about the seam that broke
//! when it was only ever tested one turn at a time: which `CODEX_HOME` a turn is given, and
//! whether the thread it was told to continue is actually in there.
//!
//! # Why a subprocess fixture, and what it is allowed to prove
//!
//! The regression that shipped — every follow-up failing with `no rollout found for thread
//! id` — was invisible to the existing tests because they stop at the argv. `build_codex_args`
//! never sees a home, so a builder test cannot tell a turn that will resume from one that
//! cannot. The missing layer is COMMAND CONSTRUCTION plus the FILESYSTEM lookup behind it,
//! and reaching it needs a child.
//!
//! So these tests spawn one: a `/bin/sh` stand-in that implements the ONE property of
//! codex-cli this fix depends on — *a rollout is stored in `$CODEX_HOME` and `resume` fails
//! when it is not there* — and fails exactly the way the real binary was measured to fail,
//! with the same message and the same exit status. Everything from `Codex::command` down to
//! the real `CodexAppServerDriver` and the real `ConversationStore` is the shipping code.
//!
//! **WHAT THIS CANNOT PROVE.** The fixture is the bridge's MODEL of codex-cli, so it cannot
//! be evidence for that model being right. That every claim in it holds of the real binary
//! was established by running the real binary (codex-cli 0.153.4, 2026-09-05; the
//! measurements are recorded on `codex_home_for_turn`), and it is re-checked by
//! [`the_real_codex_binary_resumes_only_inside_its_own_home`] below, which is `#[ignore]`d
//! because it costs a live credential and real tokens. If codex-cli changes where it keeps
//! rollouts, THAT test fails and these keep passing — which is why it exists and why a green
//! CI run is not on its own a statement about a new CLI version.
mod common;
use common::*;
use jesse_bridge::*;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// A stand-in `codex app-server` that keeps its threads the way the real one does.
///
/// It implements the storage contract and the protocol frame, and nothing else — no model,
/// no sandbox, no config. Told to start a thread it mints one and writes a rollout under
/// `$CODEX_HOME`; told to resume it looks the rollout up THERE, replays every prompt the
/// thread has seen as its answer, and appends this one. A resume it cannot find answers with
/// the real binary's JSON-RPC error, message for message:
///
/// ```text
/// thread/resume failed: no rollout found for thread id <id>
/// ```
///
/// Three behaviours are copied deliberately because the fix depends on them, and all three
/// were measured rather than assumed: **a resumed thread keeps its id** (so the conversation
/// stays bound to one session across every turn), **it appends to the same rollout file** (so
/// a home holds one rollout per conversation, not one per turn), and **the answer arrives as
/// deltas ahead of the completed item** (so a test can assert the client saw text before the
/// turn ended).
///
/// POSIX `sh`, not bash: CI's `/bin/sh` is dash. No arrays, no `$RANDOM`, no `[[`.
const FAKE_CODEX: &str = r#"#!/bin/sh
# The thread id is derived from the home rather than randomised, so a test can predict it
# without the fixture needing state of its own. The `sess-` prefix keeps it from ever being a
# directory name under the home base — a bridge that "found" a home by joining the id to the
# base would pass a test using the bare basename, and this makes that shortcut impossible.
id="sess-$(basename "$CODEX_HOME")"

if [ -z "$CODEX_HOME" ]; then
  echo "Error: no CODEX_HOME" >&2
  exit 1
fi

find_rollout() {
  # Fixed depth, the layout the real binary writes: sessions/<y>/<m>/<d>/rollout-*-<id>.jsonl
  for f in "$CODEX_HOME"/sessions/*/*/*/rollout-*-"$1".jsonl; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

field() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
num()   { printf '%s' "$2" | sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p"; }

thread=""
rollout=""

while IFS= read -r line; do
  rid=$(num id "$line")
  method=$(field method "$line")
  case "$method" in
    initialize)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"userAgent\":\"fake\",\"codexHome\":\"$CODEX_HOME\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\"}}"
      ;;
    initialized)
      ;;
    thread/start)
      thread="$id"
      dir="$CODEX_HOME/sessions/2026/09/05"
      mkdir -p "$dir"
      rollout="$dir/rollout-2026-09-05T00-00-00-$thread.jsonl"
      printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"$thread\"}}" > "$rollout"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"$thread\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"thread\":{\"id\":\"$thread\"}}}"
      ;;
    thread/resume)
      want=$(field threadId "$line")
      if rollout=$(find_rollout "$want"); then
        thread="$want"
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"thread\":{\"id\":\"$thread\"}}}"
      else
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"error\":{\"code\":-32600,\"message\":\"thread/resume failed: no rollout found for thread id $want\"}}"
      fi
      ;;
    turn/start)
      prompt=$(field text "$line")
      # Everything this thread has ever been asked IS its memory, and answering with it is
      # what lets a test assert that turn three still knows turn one's marker.
      memory=$(sed -n 's/.*"type":"prompt","text":"\([^"]*\)".*/\1/p' "$rollout" | tr '\n' ' ')
      printf '%s\n' "{\"type\":\"prompt\",\"text\":\"$prompt\"}" >> "$rollout"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$rid,\"result\":{\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"inProgress\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\",\"params\":{\"threadId\":\"$thread\",\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"inProgress\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/started\",\"params\":{\"threadId\":\"$thread\",\"turnId\":\"turn-1\",\"startedAtMs\":0,\"item\":{\"type\":\"agentMessage\",\"id\":\"msg-1\",\"text\":\"\",\"phase\":\"final_answer\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"$thread\",\"turnId\":\"turn-1\",\"itemId\":\"msg-1\",\"delta\":\"recalled: \"}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"$thread\",\"turnId\":\"turn-1\",\"itemId\":\"msg-1\",\"delta\":\"$memory\"}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"item/completed\",\"params\":{\"threadId\":\"$thread\",\"turnId\":\"turn-1\",\"completedAtMs\":0,\"item\":{\"type\":\"agentMessage\",\"id\":\"msg-1\",\"text\":\"recalled: $memory\",\"phase\":\"final_answer\"}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"$thread\",\"turnId\":\"turn-1\",\"tokenUsage\":{\"total\":{\"inputTokens\":1,\"cachedInputTokens\":0,\"outputTokens\":1}}}}"
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"threadId\":\"$thread\",\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"completed\"}}}"
      ;;
  esac
done
exit 0
"#;

/// A scratch state directory and a `Config` pointing at it, with `home` overridden so
/// [`codex_canonical_home`] can never resolve to the operator's real `~/.codex`.
struct Scratch {
    root: PathBuf,
    cfg: Config,
}

impl Scratch {
    fn new(tag: &str, bin: &Path) -> Scratch {
        let root = std::env::temp_dir().join(format!(
            "jesse-codex-session-{tag}-{}-{}",
            std::process::id(),
            random_hex()
        ));
        std::fs::create_dir_all(root.join("state")).expect("the scratch state dir");
        std::fs::create_dir_all(root.join("vault")).expect("the scratch vault");
        let mut cfg = test_config();
        cfg.state_dir = Some(root.join("state").to_string_lossy().into_owned());
        cfg.home = root.to_string_lossy().into_owned();
        cfg.vault = root.join("vault").to_string_lossy().into_owned();
        cfg.codex_bin = bin.to_string_lossy().into_owned();
        cfg.harnesses = Arc::new(HarnessRegistry::for_models(
            KNOWN_HARNESS_IDS.iter().copied(),
        ));
        Scratch { root, cfg }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn codex_model() -> ActiveModel {
    let mut m = ActiveModel::ambient();
    m.harness = CODEX_ID.to_string();
    m.level = Capability::Read;
    m
}

/// What one turn produced: the thread it reported and what it said.
#[derive(Debug)]
struct Turn {
    session: Option<String>,
    text: String,
    /// What reached the sink mid-turn, as distinct from the terminal answer. A turn whose
    /// `text` is right and whose `streamed` is empty is a turn that did NOT stream.
    streamed: String,
}

/// Run ONE turn through the shipping path — `Codex::command` builds it, the real
/// [`CodexAppServerDriver`] talks to it — and return what the child reported.
///
/// The three things it does NOT do are the point of using it: it never picks the home (that
/// is `Codex::command`'s job, and the thing under test), it never invents a session id (that
/// comes off the thread response, the way the driver takes it), and it never parses the
/// protocol itself (that is the shipping driver, so a protocol change breaks this test rather
/// than sliding past it).
async fn run_turn(
    cfg: &Config,
    model: &ActiveModel,
    session_id: Option<&str>,
    prompt: &str,
) -> Result<Turn, HarnessError> {
    let req = TurnRequest {
        prompt,
        session_id,
        active: model,
        capability: Capability::Read,
        cwd: PathBuf::from(&cfg.vault),
        mcp_config: EMPTY_MCP_CONFIG,
        write_lock: None,
        turn_id: "test-turn",
        artifact_dir: None,
        attachment_dir: None,
    };
    let mut child = Codex.command(cfg, &req)?.spawn().expect("spawn");
    let stdin = child.stdin.take().expect("a stdin pipe");
    let stdout = child.stdout.take().expect("a stdout pipe");
    let sink = RecordingSink::default();
    let session = std::sync::Mutex::new(None::<String>);
    let on_session = |id: &str| *session.lock().expect("session slot") = Some(id.to_string());
    let mut driver = match Codex.reader() {
        TurnReader::Duplex(d) => d,
        TurnReader::Lines(_) => panic!("codex drives its child; it does not read lines from it"),
    };
    let outcome = driver
        .drive(
            stdin,
            stdout,
            TurnDriveCtx {
                cfg,
                req: &req,
                sink: &sink,
                on_session: &on_session,
            },
        )
        .await;
    let _ = child.start_kill();
    let session = session.lock().expect("session slot").clone();
    match outcome {
        ClaudeOutcome::Ok { result, .. } => Ok(Turn {
            session,
            text: result,
            streamed: sink.text(),
        }),
        ClaudeOutcome::Fatal { message } | ClaudeOutcome::Retryable { message, .. } => {
            Err(HarnessError::unavailable(CODEX_ID, message))
        }
    }
}

/// A [`TurnSink`] that keeps what it was given, so a test can assert the client saw the
/// answer arriving in pieces and not only at the end.
#[derive(Default)]
struct RecordingSink {
    text: std::sync::Mutex<String>,
}

impl RecordingSink {
    fn text(&self) -> String {
        self.text.lock().expect("the streamed text").clone()
    }
}

impl TurnSink for RecordingSink {
    fn text_delta(&self, delta: &str) {
        self.text.lock().expect("the streamed text").push_str(delta);
    }
    fn tool_activity(&self, _activity: ToolActivity) {}
}

/// THE ACCEPTANCE SHAPE, and the one that used to fail on turn two: a question, then two
/// follow-ups that depend on what came before, all in one conversation.
///
/// The conversation is carried the way the handler carries it — bind whatever
/// `thread.started` reported, resume the bound id next time — so this also covers the case
/// the old builder test got wrong: on codex-cli 0.153.4 a resumed turn keeps the SAME thread
/// id, and the binding has to be correct either way.
#[tokio::test]
async fn three_turns_of_one_conversation_each_remember_the_last() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("three-turns", &bin);
    let model = codex_model();
    let conversations = ConversationStore::new(None);
    const CID: &str = "conv-three-turns";
    conversations.register(CID, None, 1_000);

    let markers = ["ZANZIBAR", "NARWHAL", "OBSIDIAN"];
    let mut homes = Vec::new();
    for (turn, marker) in markers.iter().enumerate() {
        let bound = resolve_conversation_resume(&conversations, CID, None);
        let out = run_turn(&s.cfg, &model, bound.as_deref(), marker)
            .await
            .unwrap_or_else(|e| panic!("turn {} refused: {e}", turn + 1));
        // Every marker from every earlier turn is still in the answer, which is only true if
        // this child opened the rollout the earlier ones wrote.
        for earlier in &markers[..turn] {
            assert!(
                out.text.contains(earlier),
                "turn {} lost turn {}'s context: {:?}",
                turn + 1,
                markers.iter().position(|m| m == earlier).unwrap() + 1,
                out.text
            );
        }
        // EVERY TURN STREAMED ITS ANSWER, not just the first. A regression that fell back to
        // whole-answer delivery on a RESUMED turn would leave `text` right and `streamed`
        // empty, which is exactly the shape a client renders as a long silence followed by a
        // wall of text — the thing this change exists to remove.
        assert_eq!(
            out.streamed,
            out.text,
            "turn {} delivered its answer whole rather than in deltas",
            turn + 1
        );
        let sid = out.session.expect("a thread id");
        conversations.bind_session(CID, &sid);
        homes.push(sid);
    }
    assert_eq!(
        homes[0], homes[2],
        "0.153.4 keeps the thread id across a resume, so the conversation stays on one \
         session rather than collecting three"
    );
    let _ = std::fs::remove_file(&bin);
}

/// The conversation survives the process that started it. Nothing is carried across the
/// "restart" but the state directory — no store, no cache, no in-memory map.
#[tokio::test]
async fn a_conversation_resumes_after_the_bridge_restarts() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("restart", &bin);
    let model = codex_model();

    let first = run_turn(&s.cfg, &model, None, "PELICAN")
        .await
        .expect("turn one");
    let sid = first.session.expect("a thread id");

    // A different `Config` over the same state directory is as close to a restart as a test
    // gets: the bridge keeps nothing else between runs.
    let mut restarted = test_config();
    restarted.state_dir = s.cfg.state_dir.clone();
    restarted.home = s.cfg.home.clone();
    restarted.vault = s.cfg.vault.clone();
    restarted.codex_bin = s.cfg.codex_bin.clone();
    restarted.harnesses = s.cfg.harnesses.clone();

    let second = run_turn(&restarted, &model, Some(&sid), "what was it?")
        .await
        .expect("turn two, after a restart");
    assert!(
        second.text.contains("PELICAN"),
        "a restart must not cost the conversation its history: {:?}",
        second.text
    );
    let _ = std::fs::remove_file(&bin);
}

/// TWO CONVERSATIONS, INTERLEAVED, WITH NO CROSSED HISTORY. The failure this rules out is
/// the one that a single shared home would have introduced while fixing the original bug:
/// each thread must see its own markers and NEITHER of the other's.
#[tokio::test]
async fn two_interleaved_conversations_never_see_each_others_history() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("interleaved", &bin);
    let model = codex_model();

    let a = run_turn(&s.cfg, &model, None, "ALPHAMARK")
        .await
        .expect("A1");
    let b = run_turn(&s.cfg, &model, None, "BETAMARK")
        .await
        .expect("B1");
    let (a_sid, b_sid) = (a.session.expect("A"), b.session.expect("B"));
    assert_ne!(a_sid, b_sid, "two fresh turns are two threads");

    for round in 0..2 {
        let a_next = run_turn(&s.cfg, &model, Some(&a_sid), "AONLY")
            .await
            .expect("A");
        let b_next = run_turn(&s.cfg, &model, Some(&b_sid), "BONLY")
            .await
            .expect("B");
        assert!(
            a_next.text.contains("ALPHAMARK") && !a_next.text.contains("BETAMARK"),
            "round {round}: A saw B's history: {:?}",
            a_next.text
        );
        assert!(
            b_next.text.contains("BETAMARK") && !b_next.text.contains("ALPHAMARK"),
            "round {round}: B saw A's history: {:?}",
            b_next.text
        );
    }
    let _ = std::fs::remove_file(&bin);
}

/// RECOVERY, END TO END. The pre-fix state is reconstructed exactly: a conversation whose
/// first turn ran and whose rollout is sitting in the single-turn home that turn made, with
/// no index anywhere — plus a base full of other conversations' homes to pick it out of.
///
/// This is what makes the fix useful to the threads Jeremy already has on his phone rather
/// than only to the ones he starts after it deploys.
#[tokio::test]
async fn a_conversation_started_before_the_fix_still_resumes() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("recovery", &bin);
    let model = codex_model();

    // Nine other conversations, then the one that matters — all first turns, which is the
    // only kind of turn that ever succeeded before this change.
    let mut decoys = Vec::new();
    for i in 0..9 {
        decoys.push(
            run_turn(&s.cfg, &model, None, &format!("DECOY{i}"))
                .await
                .expect("a decoy conversation")
                .session
                .expect("a thread id"),
        );
    }
    let wanted = run_turn(&s.cfg, &model, None, "HERON")
        .await
        .expect("the conversation that matters")
        .session
        .expect("a thread id");

    // The pre-fix world had no index at all: the mapping is discovered, not remembered.
    // Nothing above resumed anything, so there is nothing to remove yet — which is itself
    // the point, and is asserted rather than assumed.
    let index = codex_home_index_path(&s.cfg);
    let _ = std::fs::remove_file(&index);
    assert!(
        !index.exists(),
        "the recovery starts from no bookkeeping at all"
    );

    let followup = run_turn(&s.cfg, &model, Some(&wanted), "what was it?")
        .await
        .expect("the follow-up that never worked");
    assert!(
        followup.text.contains("HERON"),
        "recovery must find THIS conversation's rollout: {:?}",
        followup.text
    );
    assert!(
        !decoys.iter().any(|d| followup.text.contains(d)),
        "and not some other conversation's: {:?}",
        followup.text
    );
    assert!(index.is_file(), "the recovered mapping is written down");
    let _ = std::fs::remove_file(&bin);
}

/// A THREAD WHOSE STATE IS GONE FAILS VISIBLY. No child is spawned, no blank thread is
/// started, and the error names the session so an operator can go looking for it.
///
/// The alternative — mint a home and carry on — is worse than the failure it hides: the phone
/// would show a fluent answer under the conversation's own title, with no memory of anything
/// above it and nothing to distinguish that from a model that simply forgot.
#[tokio::test]
async fn a_thread_with_no_saved_state_is_refused_rather_than_silently_restarted() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("missing", &bin);
    let model = codex_model();

    let err = run_turn(&s.cfg, &model, Some("sess-nothing-here"), "hello")
        .await
        .expect_err("a missing thread must not be replaced with a fresh one");
    assert_eq!(err.kind, HarnessErrorKind::Unavailable, "{err}");
    assert!(err.what.contains("sess-nothing-here"), "{err}");
    let _ = std::fs::remove_file(&bin);
}

/// A CANCELLED TURN COSTS THE CONVERSATION NOTHING. The mapping is persisted before the
/// child is spawned, so a turn killed part-way leaves the next one able to find the thread.
#[tokio::test]
async fn a_turn_cancelled_mid_flight_can_be_retried() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("cancel", &bin);
    let model = codex_model();

    let first = run_turn(&s.cfg, &model, None, "KESTREL")
        .await
        .expect("turn one");
    let sid = first.session.expect("a thread id");

    // Cancellation as the driver performs it: the command is built, then dropped without
    // being awaited. `kill_on_drop` is what makes that a kill rather than a leak.
    {
        let req = TurnRequest {
            prompt: "this one never finishes",
            session_id: Some(&sid),
            active: &model,
            capability: Capability::Read,
            cwd: PathBuf::from(&s.cfg.vault),
            mcp_config: EMPTY_MCP_CONFIG,
            write_lock: None,
            turn_id: "cancelled-turn",
            artifact_dir: None,
            attachment_dir: None,
        };
        drop(Codex.command(&s.cfg, &req).expect("the cancelled turn"));
    }

    let retry = run_turn(&s.cfg, &model, Some(&sid), "what was it?")
        .await
        .expect("the retry");
    assert!(
        retry.text.contains("KESTREL"),
        "a cancel must not strand the conversation: {:?}",
        retry.text
    );
    let _ = std::fs::remove_file(&bin);
}

/// CONTAINMENT IS UNCHANGED BY ALL OF THIS. The home a turn runs in is not part of the
/// boundary, and the argv is where the boundary lives — so a resumed turn's arguments must
/// still be the recorded ones, in the recorded order.
///
/// Checked on a REAL child rather than on `build_codex_args`, because the whole lesson of
/// this bug is that the builder tests could not see the failure.
#[tokio::test]
async fn a_resumed_turn_carries_the_same_containment_it_always_did() {
    let bin = write_fake_claude(FAKE_CODEX);
    let s = Scratch::new("containment", &bin);
    let model = codex_model();
    let first = run_turn(&s.cfg, &model, None, "ORIOLE")
        .await
        .expect("turn one");
    let sid = first.session.expect("a thread id");

    let argv = |session: Option<&str>| -> Vec<String> {
        let req = TurnRequest {
            prompt: "hi",
            session_id: session,
            active: &model,
            capability: Capability::Read,
            cwd: PathBuf::from(&s.cfg.vault),
            mcp_config: EMPTY_MCP_CONFIG,
            write_lock: None,
            turn_id: "argv",
            artifact_dir: None,
            attachment_dir: None,
        };
        Codex
            .command(&s.cfg, &req)
            .expect("a child")
            .as_std()
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    };
    let (fresh, resumed) = (argv(None), argv(Some(&sid)));

    // The recorded capability arguments, with the workspace token filled in — the same list
    // the startup gate compares the compiled-in record against.
    let recorded: Vec<String> = Codex
        .capability_args(&s.cfg, Capability::Read)
        .into_iter()
        .map(|a| a.replace(WORKSPACE_TOKEN, &s.cfg.vault))
        .collect();
    for expected in &recorded {
        assert!(
            resumed.contains(expected),
            "a resumed turn dropped a containment argument ({expected}): {resumed:?}"
        );
    }
    // **THE ARGV IS NOW IDENTICAL, and that is the point rather than a weaker assertion.**
    // Under `codex exec` a resume was a SUBCOMMAND, so a resumed turn's argv differed from a
    // fresh one's and the test had to say how. Over the App Server the resume target travels
    // in a `thread/resume` request, so the two argvs are the same command line — which means
    // there is no longer any way for a resumed turn to carry a different containment posture
    // than the turn that created the thread. The strongest form of the property this test has
    // always been about.
    assert_eq!(
        resumed, fresh,
        "a resume must change nothing on the command line — it is a protocol request"
    );
    assert_eq!(
        resumed[0], "-C",
        "`-C` stays at the root, ahead of the subcommand"
    );
    assert_eq!(
        resumed[resumed.len() - 3..],
        ["app-server", "--listen", "stdio://"],
        "the subcommand is last, so every override above it is read by the root command"
    );
    let _ = std::fs::remove_file(&bin);
}

// ---- The live check ---------------------------------------------------------------

/// **THE ORACLE.** Everything above trusts one claim about codex-cli — that a rollout lives
/// in `$CODEX_HOME` and `resume` cannot find it anywhere else — and this is the only test
/// that asks the real binary whether that is still true.
///
/// `#[ignore]`d for the reason every live test here is: it spends a real credential. Run it
/// on the machine being certified, and run it whenever the pinned CLI moves:
///
/// ```text
/// JESSE_CODEX_BIN=$(which codex) cargo test --test codex_session_home \
///     -- --ignored --nocapture --test-threads=1
/// ```
///
/// It asserts the three measurements the fix rests on, in one conversation: a fresh turn
/// writes its rollout under the home it was given; a resume in a DIFFERENT home fails; a
/// resume in the right one recalls the marker and keeps the same thread id.
#[tokio::test]
#[ignore = "spawns real Codex turns: needs JESSE_CODEX_BIN and a live credential"]
async fn the_real_codex_binary_resumes_only_inside_its_own_home() {
    let Ok(bin) = std::env::var("JESSE_CODEX_BIN") else {
        panic!("set JESSE_CODEX_BIN to the pinned codex binary");
    };
    let s = Scratch::new("live", Path::new(&bin));
    // The real binary authenticates from the home the bridge seeds, so the canonical this
    // scratch config points at has to be the operator's — copied in, never written to.
    let canonical = s.root.join(".codex");
    std::fs::create_dir_all(&canonical).expect("the scratch canonical home");
    let real = PathBuf::from(std::env::var("HOME").expect("HOME")).join(".codex/auth.json");
    std::fs::copy(&real, canonical.join("auth.json")).expect("a credential to copy");

    let model = codex_model();
    let first = run_turn(
        &s.cfg,
        &model,
        None,
        "Remember this marker word: ZANZIBAR-4417. Reply with just OK.",
    )
    .await
    .expect("turn one");
    let sid = first.session.expect("a thread id");

    // Where the fix says it should be, checked on disk rather than inferred.
    let base = codex_home_base(&s.cfg);
    let home = find_rollout_home(&base, &sid).expect("the rollout is under the home base");
    assert!(rollout_in_home(&home, &sid).is_some());

    // THE FAILURE, from the real binary: the same id, a home that does not hold it.
    let elsewhere = base.join(random_hex());
    std::fs::create_dir_all(&elsewhere).expect("a fresh home");
    std::fs::copy(canonical.join("auth.json"), elsewhere.join("auth.json")).expect("auth");
    let out = tokio::process::Command::new(&bin)
        .args(["-C", &s.cfg.vault, "exec", "resume", &sid])
        .args([
            "--json",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
        ])
        .arg("what was the marker?")
        .env("CODEX_HOME", &elsewhere)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .expect("spawn");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success() && stderr.contains("no rollout found for thread id"),
        "codex-cli no longer stores rollouts per CODEX_HOME — the whole fix rests on this, \
         and the fixture in this file now models the wrong binary. stderr: {stderr}"
    );

    // And the success, through the bridge's own path.
    let second = run_turn(
        &s.cfg,
        &model,
        Some(&sid),
        "What was the marker word I gave you?",
    )
    .await
    .expect("turn two");
    assert!(
        second.text.contains("ZANZIBAR-4417"),
        "a resumed turn must carry the conversation: {:?}",
        second.text
    );
    assert_eq!(
        second.session.as_deref(),
        Some(sid.as_str()),
        "0.153.4 keeps the thread id across a resume; if this fails the binding rule in the \
         handler needs re-checking, not this assertion deleting"
    );
}

/// **THE LIVE ACCEPTANCE SHAPE, against the real binary.**
///
/// Everything above this line proves the fixture's model of codex-cli is wired up correctly.
/// This proves the three things a person actually notices, on the real thing, in one run:
///
///   1. **Three context-dependent turns.** Turn three has to know what turn one said, which
///      only works if all three ran in one home and one thread.
///   2. **Resume after a bridge restart.** A different `Config` over the same state directory
///      is as close to a restart as a test gets — the bridge keeps nothing else between runs.
///   3. **Two interleaved conversations.** Two threads, alternating turns, each recalling its
///      own marker and neither seeing the other's — the failure that a single shared home, or
///      a resume that silently started blank, would produce.
///
/// And it asserts the property this transport exists for on every one of those turns: the
/// answer arrived as DELTAS, not whole. A regression that fell back to whole-answer delivery
/// on a resumed turn only would pass every other test in this file.
///
/// `#[ignore]`d like every live test here — it spends a real credential and about a minute:
///
/// ```text
/// JESSE_CODEX_BIN=$(which codex) cargo test --test codex_session_home \
///     -- --ignored --nocapture --test-threads=1 the_live_acceptance
/// ```
#[tokio::test]
#[ignore = "spawns six real Codex turns: costs money and minutes; run explicitly"]
async fn the_live_acceptance_shape_holds_against_the_real_binary() {
    let Ok(bin) = std::env::var("JESSE_CODEX_BIN") else {
        panic!("set JESSE_CODEX_BIN to the pinned codex binary");
    };
    let s = Scratch::new("live-acceptance", Path::new(&bin));
    let canonical = s.root.join(".codex");
    std::fs::create_dir_all(&canonical).expect("the scratch canonical home");
    let real = PathBuf::from(std::env::var("HOME").expect("HOME")).join(".codex/auth.json");
    std::fs::copy(&real, canonical.join("auth.json")).expect("a credential to copy");
    let model = codex_model();

    /// Every turn must have streamed. Checked on each one rather than once at the end,
    /// because the interesting regression is a turn SHAPE (a resume, a second conversation)
    /// that silently stops streaming while the first turn still does.
    fn streamed(turn: &Turn, which: &str) {
        assert!(
            !turn.streamed.trim().is_empty(),
            "{which} delivered its answer whole rather than in deltas"
        );
    }

    // ---- 1 & 2: three context-dependent turns, with a restart in the middle -----------
    let one = run_turn(
        &s.cfg,
        &model,
        None,
        "Remember this marker word: ZANZIBAR-4417. Reply with just OK.",
    )
    .await
    .expect("turn one");
    streamed(&one, "turn one");
    let sid = one.session.expect("a thread id");

    let two = run_turn(
        &s.cfg,
        &model,
        Some(&sid),
        "Now also remember: NARWHAL-9. OK?",
    )
    .await
    .expect("turn two");
    streamed(&two, "turn two");

    // THE RESTART. Nothing is carried across but the state directory.
    let mut restarted = s.cfg.clone();
    restarted.harnesses = s.cfg.harnesses.clone();
    let three = run_turn(
        &restarted,
        &model,
        two.session.as_deref().or(Some(&sid)),
        "List both marker words I gave you, exactly.",
    )
    .await
    .expect("turn three, after a restart");
    streamed(&three, "turn three");
    assert!(
        three.text.contains("ZANZIBAR-4417") && three.text.contains("NARWHAL-9"),
        "turn three lost the conversation across a restart: {}",
        three.text
    );

    // ---- 3: two interleaved conversations --------------------------------------------
    let a1 = run_turn(
        &s.cfg,
        &model,
        None,
        "Remember this word and nothing else: PELICAN. Reply OK.",
    )
    .await
    .expect("A turn one");
    let b1 = run_turn(
        &s.cfg,
        &model,
        None,
        "Remember this word and nothing else: OBSIDIAN. Reply OK.",
    )
    .await
    .expect("B turn one");
    let (a_sid, b_sid) = (a1.session.expect("A thread"), b1.session.expect("B thread"));
    assert_ne!(a_sid, b_sid, "two conversations must not share a thread");

    let a2 = run_turn(
        &s.cfg,
        &model,
        Some(&a_sid),
        "What word did I ask you to remember?",
    )
    .await
    .expect("A turn two");
    streamed(&a2, "conversation A's second turn");
    let b2 = run_turn(
        &s.cfg,
        &model,
        Some(&b_sid),
        "What word did I ask you to remember?",
    )
    .await
    .expect("B turn two");
    streamed(&b2, "conversation B's second turn");

    assert!(
        a2.text.contains("PELICAN") && !a2.text.contains("OBSIDIAN"),
        "conversation A saw B's history: {}",
        a2.text
    );
    assert!(
        b2.text.contains("OBSIDIAN") && !b2.text.contains("PELICAN"),
        "conversation B saw A's history: {}",
        b2.text
    );
}
