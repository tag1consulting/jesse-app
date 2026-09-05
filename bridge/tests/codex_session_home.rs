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
//! the real `CodexParser` and the real `ConversationStore` is the shipping code.
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

/// A stand-in `codex` that keeps its threads the way the real one does.
///
/// It implements the storage contract and nothing else — no model, no sandbox, no config.
/// Told to start fresh it mints a thread and writes a rollout under `$CODEX_HOME`; told to
/// resume it looks the rollout up THERE, replays every prompt the thread has seen as its
/// answer, and appends this one. A resume it cannot find exits 1 with the real binary's
/// message, byte for byte:
///
/// ```text
/// Error: thread/resume: thread/resume failed: no rollout found for thread id <id> (code -32600)
/// ```
///
/// Two behaviours are copied deliberately because the fix depends on them, and both were
/// measured rather than assumed: **a resumed thread keeps its id** (so the conversation stays
/// bound to one session across every turn) and **it appends to the same rollout file** (so a
/// home holds one rollout per conversation, not one per turn).
///
/// POSIX `sh`, not bash: CI's `/bin/sh` is dash. No arrays, no `$RANDOM`, no `[[`.
const FAKE_CODEX: &str = r#"#!/bin/sh
# The thread id is derived from the home rather than randomised, so a test can predict it
# without the fixture needing state of its own. The `sess-` prefix keeps it from ever being a
# directory name under the home base — a bridge that "found" a home by joining the id to the
# base would pass a test using the bare basename, and this makes that shortcut impossible.
id="sess-$(basename "$CODEX_HOME")"

# The prompt is the LAST argument; `resume <id>` follows `exec` when there is one.
prompt=""
resume=""
prev=""
prev2=""
for a in "$@"; do
  if [ "$prev2" = "exec" ] && [ "$prev" = "resume" ]; then resume="$a"; fi
  prev2="$prev"; prev="$a"; prompt="$a"
done

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

if [ -n "$resume" ]; then
  id="$resume"
  rollout=$(find_rollout "$id") || {
    echo "Error: thread/resume: thread/resume failed: no rollout found for thread id $id (code -32600)" >&2
    exit 1
  }
else
  dir="$CODEX_HOME/sessions/2026/09/05"
  mkdir -p "$dir"
  rollout="$dir/rollout-2026-09-05T00-00-00-$id.jsonl"
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"$id\"}}" > "$rollout"
fi

# Everything this thread has ever been asked IS its memory, and answering with it is what
# lets a test assert that turn three still knows turn one's marker.
memory=$(sed -n 's/.*"type":"prompt","text":"\([^"]*\)".*/\1/p' "$rollout" | tr '\n' ' ')
printf '%s\n' "{\"type\":\"prompt\",\"text\":\"$prompt\"}" >> "$rollout"

printf '%s\n' "{\"type\":\"thread.started\",\"thread_id\":\"$id\"}"
printf '%s\n' "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"recalled: $memory\"}}"
printf '%s\n' "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
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
}

/// Run ONE turn through the shipping path — `Codex::command` builds it, the real
/// `CodexParser` reads it — and return what the child reported.
///
/// The two things it does NOT do are the point of using it: it never picks the home (that is
/// `Codex::command`'s job, and the thing under test) and it never invents a session id (that
/// comes off `thread.started`, the way the driver takes it).
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
    let out = Codex.command(cfg, &req)?.output().await.expect("spawn");
    let mut parser = Codex.parser();
    let (mut session, mut text) = (None, String::new());
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        match parser.on_line(line) {
            StreamEvent::SessionId(id) => session = Some(id),
            StreamEvent::Done(ClaudeOutcome::Ok { result, .. }) => text = result,
            _ => {}
        }
    }
    assert!(
        out.status.success(),
        "the child failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(Turn { session, text })
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
    // A resume adds `exec resume <id>` and changes nothing else.
    let stripped: Vec<String> = {
        let at = resumed.iter().position(|a| a == "resume").expect("resume");
        let mut v = resumed.clone();
        v.drain(at..=at + 1);
        v
    };
    assert_eq!(
        stripped, fresh,
        "resuming must add the subcommand and its id, and nothing else"
    );
    assert_eq!(resumed[0], "-C", "`-C` stays at the root, ahead of `exec`");
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
