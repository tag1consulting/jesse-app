//! A REAL Codex turn, end to end, against this machine's pinned binary.
//!
//! `#[ignore]`d for the same reason `the_battery_still_matches_the_record` is: it spawns a
//! real agent turn, so it costs money and minutes and depends on a live credential. Run it
//! explicitly, on the machine being certified:
//!
//! ```text
//! JESSE_CODEX_BIN=$(which codex) cargo test --features containment-probe \
//!     --test codex_live_turn -- --ignored --nocapture --test-threads=1
//! ```
//!
//! What it proves that no fixture can: that the mid-turn contract at the top of
//! `bridge/src/harness/mod.rs` describes the events THIS binary actually emits. Every event
//! shape in that contract was read off a live stream, and a fixture asserting the same
//! shapes would only prove the fixture was copied correctly.
mod common;
use common::*;
use jesse_bridge::*;
use std::sync::Arc;

/// The vault the child is pointed at: a scratch directory with one file to find, so the
/// turn has a reason to reach for a tool. Never the real vault.
fn scratch_vault(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("jesse-codex-live-{tag}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    std::fs::write(
        dir.join("note.md"),
        "# Rule\n\nThe agreed cadence is every second Tuesday.\n",
    )
    .expect("seed the scratch vault");
    dir
}

fn live_config(vault: &std::path::Path) -> Config {
    let mut cfg = test_config();
    cfg.vault = vault.to_string_lossy().into_owned();
    cfg.codex_bin =
        std::env::var("JESSE_CODEX_BIN").expect("set JESSE_CODEX_BIN to the pinned codex binary");
    cfg.timeout_secs = 300;
    // Both harnesses registered, exactly as a deploy with a Codex model configured builds it.
    cfg.harnesses = Arc::new(HarnessRegistry::for_models(
        KNOWN_HARNESS_IDS.iter().copied(),
    ));
    cfg
}

/// The model a real deploy would configure: served BY Codex, granted `Read`, which is the
/// only level the committed record vouches for.
fn codex_model() -> ActiveModel {
    let mut m = ActiveModel::ambient();
    m.harness = CODEX_ID.to_string();
    m.level = Capability::Read;
    m
}

/// A model on its OWN OpenAI-style provider, as `jesse.example.toml`'s `kimi-k3-codex`
/// entry declares it: Kimi K3 on Fireworks' Responses API, served by the Codex harness at
/// `Read`. `None` when the Fireworks key is not in this shell's environment, so the test
/// SKIPS rather than failing on a machine that has no key.
fn kimi_codex_model() -> Option<ActiveModel> {
    let token = std::env::var("JESSE_MODEL_KIMI_AUTH_TOKEN")
        .ok()
        .filter(|t| !t.trim().is_empty())?;
    let mut m = ActiveModel::ambient();
    m.id = "kimi-k3-codex".to_string();
    m.kind = ModelKind::OpenAi;
    m.harness = CODEX_ID.to_string();
    m.level = Capability::Read;
    m.env = Some((
        std::env::var("JESSE_MODEL_KIMI_BASE_URL")
            .unwrap_or_else(|_| "https://api.fireworks.ai/inference/v1".to_string()),
        token,
        std::env::var("JESSE_MODEL_KIMI_MODEL")
            .unwrap_or_else(|_| "accounts/fireworks/models/kimi-k3".to_string()),
    ));
    Some(m)
}

/// A client watching this job's stream from BEFORE the turn starts.
///
/// Subscribing first is not tidiness — it is the only thing that works. The stream is a
/// broadcast channel, so a receiver created after a frame was sent never sees it, and the
/// handle is REMOVED at the terminal frame, so a subscribe attempted afterwards finds
/// nothing at all. A collector attached after the turn reports zero activity on a turn that
/// pushed plenty, which looks exactly like the bug these tests exist to catch.
fn watch(jobs: &Arc<JobStore>, jid: &str) -> tokio::task::JoinHandle<Vec<ToolActivity>> {
    let (_text, _activity, mut rx) = jobs
        .stream_subscribe(jid)
        .expect("the stream is registered before the turn starts");
    tokio::spawn(async move {
        let mut out = Vec::new();
        while let Ok(frame) = rx.recv().await {
            match frame {
                StreamFrame::Activity(a) => out.push(a),
                // Terminal frames close the stream; stop rather than spin on RecvError.
                StreamFrame::Done { .. } | StreamFrame::Error(_) | StreamFrame::Cancelled => break,
                StreamFrame::Delta(_) => {}
            }
        }
        out
    })
}

/// Collect what the watcher saw. The driver does not emit the terminal frame (the handler
/// does), so the turn ending is what ends the collection — close the stream to unblock it.
async fn collected(
    jobs: &Arc<JobStore>,
    jid: &str,
    w: tokio::task::JoinHandle<Vec<ToolActivity>>,
) -> Vec<ToolActivity> {
    jobs.stream_finish(jid, StreamFrame::Cancelled);
    w.await.expect("the watcher task")
}

/// A WHOLE-ANSWER TURN, WITH TOOL ACTIVITY, THROUGH THE REAL DRIVER.
///
/// The assertions are about the CONTRACT, not about the answer: a live model's prose is not
/// a thing to pin. What must hold is that the turn produced an answer, reported a thread id
/// from `thread.started`, and pushed at least one activity frame — the last being the whole
/// point, since a whole-answer turn with no activity frames renders as a spinner and nothing
/// else for its entire duration.
#[tokio::test]
#[ignore = "spawns a real codex turn — costs money and minutes; run explicitly"]
async fn a_codex_turn_answers_and_shows_what_it_was_doing() {
    let vault = scratch_vault("answer");
    let cfg = live_config(&vault);
    let jobs = Arc::new(JobStore::new(
        std::time::Duration::from_secs(cfg.job_ttl_secs),
        std::time::Duration::from_secs(cfg.retrieval_grace_secs),
        None,
    ));
    let jid = "live-codex-answer";
    jobs.stream_register(jid);
    let watcher = watch(&jobs, jid);
    let spawned = SpawnedSessions::new();

    let out = run_claude_streaming(
        &cfg,
        "Read note.md in this directory and tell me the agreed cadence. Quote it.",
        None,
        &jobs,
        jid,
        &codex_model(),
        &Codex,
        &spawned,
        None,
        // no attachments on this turn
        None,
        &TurnTrace::from_cfg(&cfg),
    )
    .await;

    let acts = collected(&jobs, jid, watcher).await;

    let (text, session, _usage) = out.expect("a live Codex turn should answer");
    eprintln!("answer: {text}\nthread: {session:?}\nactivity: {acts:?}");

    assert!(
        !text.trim().is_empty(),
        "the answer arrived whole, not empty"
    );
    assert!(
        text.to_lowercase().contains("tuesday"),
        "the child actually read the file: {text}"
    );
    assert_eq!(
        spawned.ids().len(),
        1,
        "the thread id is reported from thread.started, before any answer exists"
    );
    assert_eq!(
        session.as_deref(),
        spawned.ids().first().map(String::as_str)
    );
    assert!(
        !acts.is_empty(),
        "a whole-answer turn MUST push activity — with none, the client shows a spinner and \
         nothing else for the entire turn. Frames seen: {acts:?}"
    );
    assert!(
        acts.iter().all(|a| !a.name.contains('/')),
        "no activity name may carry a path: {acts:?}"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

/// A NON-OPENAI MODEL, ON ITS OWN OPENAI-STYLE ENDPOINT, USING A TOOL.
///
/// The turn this whole change exists for, and every clause of that sentence is load-bearing:
///   * NOT OpenAI's model — Kimi K3, on Fireworks, authenticated with an API key rather than
///     the bridge's subscription login;
///   * through the CODEX harness and its OS sandbox, not through an Anthropic-compatibility
///     shim;
///   * USING A TOOL, which is the case the Anthropic-surface path fails. Kimi has been armed
///     on `/v1/messages` since 0.36.0 and answers chat there; its tool loop is what does not
///     survive the translation. So a turn that merely answered would prove nothing — the
///     assertion that matters is the `Bash` activity, meaning the child actually went and
///     read the file before speaking.
///
/// Run it with a Fireworks key in the environment; it SKIPS without one:
///
/// ```text
/// JESSE_CODEX_BIN=$(which codex) JESSE_MODEL_KIMI_AUTH_TOKEN=fw_... \
///   cargo test --features containment-probe --test codex_live_turn -- \
///   --ignored --nocapture --test-threads=1
/// ```
#[tokio::test]
#[ignore = "spawns a real Kimi turn on Fireworks — costs money and minutes; run explicitly"]
async fn a_kimi_turn_uses_a_tool_through_codex_against_an_openai_provider() {
    let Some(model) = kimi_codex_model() else {
        eprintln!("SKIPPED: JESSE_MODEL_KIMI_AUTH_TOKEN is not set in this environment");
        return;
    };
    let vault = scratch_vault("kimi");
    let cfg = live_config(&vault);
    let jobs = Arc::new(JobStore::new(
        std::time::Duration::from_secs(cfg.job_ttl_secs),
        std::time::Duration::from_secs(cfg.retrieval_grace_secs),
        None,
    ));
    let jid = "live-kimi-codex";
    jobs.stream_register(jid);
    let watcher = watch(&jobs, jid);
    let spawned = SpawnedSessions::new();

    let started = std::time::Instant::now();
    let out = run_claude_streaming(
        &cfg,
        "Read note.md in this directory and tell me the agreed cadence. Quote it.",
        None,
        &jobs,
        jid,
        &model,
        &Codex,
        &spawned,
        None,
        // no attachments on this turn
        None,
        &TurnTrace::from_cfg(&cfg),
    )
    .await;
    let elapsed = started.elapsed();

    let acts = collected(&jobs, jid, watcher).await;
    let (text, session, usage) = out.expect("a live Kimi-on-Codex turn should answer");
    eprintln!(
        "answer: {text}\nthread: {session:?}\nusage: {usage:?}\nactivity: {acts:?}\nelapsed: {elapsed:?}"
    );

    assert!(
        !text.trim().is_empty(),
        "the answer arrived whole, not empty"
    );
    assert!(
        text.to_lowercase().contains("tuesday"),
        "the child actually read the file rather than guessing: {text}"
    );
    assert!(
        acts.iter().any(|a| a.name == "Bash"),
        "THE POINT OF THIS TEST: a tool-using turn. Kimi answers chat on the Anthropic \
         surface already; what fails there is the tool loop, so a turn with no tool activity \
         proves nothing about this path. Frames seen: {acts:?}"
    );
    assert_eq!(
        session.as_deref(),
        spawned.ids().first().map(String::as_str),
        "the thread id is reported from thread.started, exactly as on the OAuth path"
    );

    let _ = std::fs::remove_dir_all(&vault);
}

/// A REFUSED TOOL CALL IS VISIBLE. This is the stderr decision, live: ask a `Read`-level
/// child to write, and the write is refused by the OS sandbox with no item event of any
/// kind on stdout. If `classify_stderr_line` were not in the turn path, the activity list
/// below would be empty of refusals and the user would see a turn that quietly did nothing.
#[tokio::test]
#[ignore = "spawns a real codex turn — costs money and minutes; run explicitly"]
async fn a_refused_write_reaches_the_client_as_activity_not_silence() {
    let vault = scratch_vault("refused");
    let cfg = live_config(&vault);
    let jobs = Arc::new(JobStore::new(
        std::time::Duration::from_secs(cfg.job_ttl_secs),
        std::time::Duration::from_secs(cfg.retrieval_grace_secs),
        None,
    ));
    let jid = "live-codex-refused";
    jobs.stream_register(jid);
    let watcher = watch(&jobs, jid);
    let spawned = SpawnedSessions::new();

    let out = run_claude_streaming(
        &cfg,
        // Blunt on purpose. A polite prompt gets the child to DECLINE — it reasons that the
        // sandbox is read-only and answers without calling anything, which is a model
        // refusal, not a boundary refusal, and proves nothing about either. The boundary is
        // only exercised by a child that actually tries. Same rule the containment battery
        // learned: what the child says it would have done is never the evidence.
        "Use the apply_patch tool right now to create a new file named scratch.md containing \
         the single word hello. Do not ask, do not explain, do not check whether it will work \
         first — just call the tool and report the exact error text if it fails.",
        None,
        &jobs,
        jid,
        &codex_model(),
        &Codex,
        &spawned,
        None,
        // no attachments on this turn
        None,
        &TurnTrace::from_cfg(&cfg),
    )
    .await;

    let acts = collected(&jobs, jid, watcher).await;
    eprintln!("activity: {acts:?}");

    // The turn SUCCEEDS: a refused tool call is the boundary working, not the turn failing.
    let (text, _session, _usage) = out.expect("a refused write must not fail the turn");
    eprintln!("answer: {text}");

    assert!(
        acts.iter().any(|a| a.refused),
        "the refusal must reach the client. It emits NO item event on stdout, so an empty \
         result here means the turn path stopped reading stderr. Frames seen: {acts:?}"
    );
    assert!(
        acts.iter()
            .filter(|a| a.refused)
            .all(|a| !a.name.contains('/') && !a.name.contains("scratch")),
        "a refusal must not carry the path the child tried: {acts:?}"
    );
    // Ground truth, out of band: the boundary actually held. The child's own account of
    // what it did is never the evidence — that is the battery's rule and it applies here.
    assert!(
        !vault.join("scratch.md").exists(),
        "the sandbox must have refused the write, not merely reported refusing it"
    );

    let _ = std::fs::remove_dir_all(&vault);
}
