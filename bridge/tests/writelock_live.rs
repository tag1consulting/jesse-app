//! The vault write lock, proven LIVE against this machine's pinned agent binaries.
//!
//! `#[ignore]`d like every other test that spawns a real agent turn: these cost money and
//! minutes and need a live credential. Run them on the machine being certified:
//!
//! ```text
//! JESSE_CODEX_BIN=$(which codex) JESSE_CLAUDE_BIN=$(which claude) \
//!     cargo test --test writelock_live -- --ignored --nocapture --test-threads=1
//! ```
//!
//! # What these prove that the unit tests cannot
//!
//! `writelock.rs`'s own tests drive the broker directly. They prove the LOCK is correct; they
//! say nothing about whether a real child can ever reach it. The whole design rests on one
//! measured claim — **a Codex child's hook subprocess is not sandboxed, so it can talk to a
//! socket the child itself could never write** — and a claim like that has to be re-provable
//! on demand, against the real sandbox flags, or it is folklore.
//!
//! So `a_codex_child_acquires_the_lock_under_its_own_sandbox` runs a real `Write`-level Codex
//! turn built by the REAL harness (`Codex::build_turn`, the real `codex_capability_args`, the
//! real per-turn `CODEX_HOME`), and asserts the broker actually saw a lock request arrive.
//! If someone later moves the socket, or narrows `writable_roots`, or drops the trust flag,
//! this test is what fails — and it fails for the right reason.
//!
//! # Ground truth is what the BROKER recorded, never what the child says
//!
//! Same rule as the containment battery: a child that reports "I took the lock" and a child
//! whose hook silently never ran are indistinguishable until you look at the other side. Every
//! assertion below reads the broker's own record.

mod common;
use common::*;
use jesse_bridge::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// A scratch vault plus a SIBLING state dir — the layout that makes the reachability claim
/// falsifiable. The socket goes in the state dir, which is outside `writable_roots`, so a
/// child that could only reach its own writable root would fail these tests.
struct Scratch {
    root: PathBuf,
    vault: PathBuf,
    state: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Scratch {
        // SHORT on purpose. The broker socket lives under `state/`, and a unix socket path is
        // capped at ~104 bytes — the sandbox-y temp dirs a CI runner hands out blow straight
        // through that, and the resulting error names neither the path nor the cause.
        let root = PathBuf::from("/tmp").join(format!(
            "jwl-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(0)
        ));
        let vault = root.join("vault");
        let state = root.join("state");
        std::fs::create_dir_all(&vault).unwrap();
        std::fs::create_dir_all(&state).unwrap();
        Scratch { root, vault, state }
    }

    fn config(&self) -> Config {
        let mut cfg = test_config();
        cfg.vault = self.vault.to_string_lossy().into_owned();
        cfg.state_dir = Some(self.state.to_string_lossy().into_owned());
        cfg.timeout_secs = 300;
        if let Ok(b) = std::env::var("JESSE_CODEX_BIN") {
            cfg.codex_bin = b;
        }
        if let Ok(b) = std::env::var("JESSE_CLAUDE_BIN") {
            cfg.claude_bin = b;
        }
        cfg.harnesses = Arc::new(HarnessRegistry::for_models(
            KNOWN_HARNESS_IDS.iter().copied(),
        ));
        cfg
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// The `jesse-hook` helper built alongside this test binary.
///
/// `target/debug/deps/<test>` → `target/debug/jesse-hook`. Resolved here rather than through
/// `resolve_hook_helper` because that one looks beside the RUNNING binary, which for a test is
/// the test itself in `deps/`.
fn helper() -> PathBuf {
    let exe = std::env::current_exe().expect("the test binary");
    let debug_dir = exe.parent().and_then(|p| p.parent()).expect("target/debug");
    let p = debug_dir.join("jesse-hook");
    assert!(
        p.is_file(),
        "jesse-hook is not built at {} — run `cargo build --bins` first",
        p.display()
    );
    p
}

/// A broker that also COUNTS the requests it served, so a test can assert that a hook actually
/// reached it rather than inferring it from the turn's prose.
struct CountingBroker {
    broker: Arc<LockBroker>,
    pre: Arc<AtomicUsize>,
}

/// Start a broker on the scratch state dir's socket. Returns the handle plus the counter.
fn start_broker(cfg: &Config) -> (CountingBroker, PathBuf) {
    let path = cfg.writelock_socket().expect("a state dir");
    let listener = bind_broker(&path).expect("bind the broker socket");
    let broker = Arc::new(LockBroker::new());
    let pre = Arc::new(AtomicUsize::new(0));
    // The real `serve_broker` plus a counting tee: the test needs to know a request ARRIVED,
    // which the lock table alone cannot show once the lock has been released again.
    tokio::spawn(serve_broker_counting(listener, broker.clone(), pre.clone()));
    (CountingBroker { broker, pre }, path)
}

/// `serve_broker`, with a counter on the pre-hook path.
async fn serve_broker_counting(
    listener: tokio::net::UnixListener,
    broker: Arc<LockBroker>,
    pre: Arc<AtomicUsize>,
) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let (broker, pre) = (broker.clone(), pre.clone());
        tokio::spawn(async move {
            let (r, mut w) = stream.into_split();
            let mut lines = BufReader::new(r).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(req) = serde_json::from_str::<HookRequest>(&line) else {
                    continue;
                };
                if matches!(req, HookRequest::Pre { .. }) {
                    pre.fetch_add(1, Ordering::SeqCst);
                }
                let resp = broker.handle(req).await;
                let mut out = serde_json::to_string(&resp).unwrap();
                out.push('\n');
                let _ = w.write_all(out.as_bytes()).await;
                let _ = w.flush().await;
            }
        });
    }
}

fn write_model(harness: &str) -> ActiveModel {
    let mut m = ActiveModel::ambient();
    m.harness = harness.to_string();
    m.level = Capability::Write;
    m
}

async fn turn(
    cfg: &Config,
    prompt: &str,
    jid: &str,
    model: &ActiveModel,
    wl: Option<&WriteLockChild>,
) -> Result<String, ApiError> {
    let jobs = Arc::new(JobStore::new(
        std::time::Duration::from_secs(cfg.job_ttl_secs),
        std::time::Duration::from_secs(cfg.retrieval_grace_secs),
        None,
    ));
    jobs.stream_register(jid);
    let spawned = SpawnedSessions::new();
    let harness = cfg.harnesses.serving(model);
    let out = run_claude_streaming(
        cfg,
        prompt,
        None,
        &jobs,
        jid,
        model,
        harness,
        &spawned,
        wl,
        None,
        None,
        &TurnTrace::from_cfg(cfg),
    )
    .await;
    jobs.stream_finish(jid, StreamFrame::Cancelled);
    out.map(|(text, _s, _u)| text)
}

/// **The test the whole rendezvous decision rests on.**
///
/// A real `Write`-level Codex child, built by the real harness with the real sandbox flags,
/// must be able to reach a broker socket that lives OUTSIDE its `writable_roots`. If the hook
/// subprocess were sandboxed like the child, this fails — and the design would have needed a
/// `writable_roots` widening, a re-cut containment record and a human acceptance.
#[tokio::test]
#[ignore = "spawns a real Codex turn: costs money, needs a live credential"]
async fn a_codex_child_acquires_the_lock_under_its_own_sandbox() {
    let s = Scratch::new("codex-sandbox");
    let cfg = s.config();
    let (cb, socket) = start_broker(&cfg);

    // The socket is outside the vault — the child's ONLY writable root.
    assert!(
        !socket.starts_with(&s.vault),
        "the socket must be outside writable_roots or this test proves nothing: {}",
        socket.display()
    );

    let wl = WriteLockChild {
        socket: socket.clone(),
        turn: "job-codex-1".to_string(),
        conversation: "conv-codex".to_string(),
        helper: helper(),
    };
    let model = write_model(CODEX_ID);
    let text = turn(
        &cfg,
        "Create a file named locked.md in the current directory containing exactly the word banana. Then stop.",
        "job-codex-1",
        &model,
        Some(&wl),
    )
    .await
    .expect("the Codex turn should complete");
    eprintln!("codex said: {text}");

    // GROUND TRUTH #1: the write landed (a lock that blocks everything is not a lock).
    let written = s.vault.join("locked.md");
    assert!(
        written.is_file(),
        "the Write-level child must still be able to write its own vault"
    );

    // GROUND TRUTH #2 — the claim under test: the child's hook REACHED the broker, across the
    // sandbox boundary, with no widening of writable_roots.
    assert!(
        cb.pre.load(Ordering::SeqCst) > 0,
        "no PreToolUse hook ever reached the broker. Either the hook subprocess is now \
         sandboxed (the measurement this design rests on has changed), or hooks.json is not \
         being written, or --dangerously-bypass-hook-trust was dropped and codex is SILENTLY \
         skipping the hooks — which is the failure mode that looks exactly like success."
    );

    // GROUND TRUTH #3: the turn ended, so it holds nothing.
    cb.broker.release_turn("job-codex-1");
    assert_eq!(cb.broker.held_count(), 0);
}

/// THE CONTROL for the test above: the identical turn, same scratch, same prompt, with the
/// write lock switched OFF.
///
/// It exists because a live whole-answer Codex turn intermittently ends with no final
/// `agent_message`, which the driver reports as `502 empty result` — and the first question
/// anyone will ask when they see that is "did the write lock cause it?". Without a control
/// that question is unanswerable and the honest answer is a shrug. With one, a single run of
/// both tells you: if this one flakes too, the write lock is not implicated.
///
/// MEASURED 2026-08-05 on codex-cli 0.146.0, and the answer is that the write lock is NOT
/// implicated:
///
///   * this control, with the lock OFF: **5 passed / 1 failed out of 6**, the failure being
///     exactly `502 empty result`;
///   * the locked test above: 3 failures across ~11 runs — the same rate, the same failure;
///   * the CLI alone, with real hooks and a fresh per-turn `CODEX_HOME` but no bridge:
///     **4 / 4 clean**, a final `agent_message` every time.
///
/// So a live whole-answer Codex turn through this driver sometimes ends with no final
/// `agent_message`, at roughly one run in five, with or without hooks. That is a pre-existing
/// property worth fixing on its own (the driver could treat a completed turn that produced a
/// `file_change` but no message as a success with an empty answer rather than a 502), and it
/// is deliberately NOT fixed here: it is not this change's bug, and quietly widening the
/// driver's success condition inside a concurrency change is how an unrelated regression
/// gets attributed to the wrong commit.
#[tokio::test]
#[ignore = "spawns a real Codex turn: the control for the test above"]
async fn a_codex_turn_without_the_write_lock_is_the_control() {
    let s = Scratch::new("codex-control");
    let cfg = s.config();
    let model = write_model(CODEX_ID);
    let text = turn(
        &cfg,
        "Create a file named locked.md in the current directory containing exactly the word banana. Then stop.",
        "job-codex-control",
        &model,
        None, // <- the only difference
    )
    .await
    .expect("the Codex turn should complete");
    eprintln!("codex (control) said: {text}");
    assert!(s.vault.join("locked.md").is_file());
}

/// The same claim for Claude Code, whose hooks arrive through the bridge-owned `--settings`
/// file rather than a `hooks.json`.
#[tokio::test]
#[ignore = "spawns a real Claude Code turn"]
async fn a_claude_child_acquires_the_lock_through_the_bridge_owned_settings() {
    let s = Scratch::new("claude-settings");
    let cfg = s.config();
    let (cb, socket) = start_broker(&cfg);

    let wl = WriteLockChild {
        socket,
        turn: "job-claude-1".to_string(),
        conversation: "conv-claude".to_string(),
        helper: helper(),
    };
    let model = write_model(CLAUDE_CODE_ID);
    let text = turn(
        &cfg,
        "Create a file named locked.md in the current directory containing exactly the word banana. Then stop.",
        "job-claude-1",
        &model,
        Some(&wl),
    )
    .await
    .expect("the Claude turn should complete");
    eprintln!("claude said: {text}");

    assert!(s.vault.join("locked.md").is_file(), "the write must land");
    assert!(
        cb.pre.load(Ordering::SeqCst) > 0,
        "no PreToolUse hook reached the broker — the bridge-owned --settings file is not being \
         written, or --settings stopped being additive to the project scope"
    );
}

/// THE EXACT ARGV DELTA the write lock adds, per harness, pinned so it cannot grow quietly.
///
/// This is the test that keeps the containment story honest. The committed records pin
/// `capability_args` — the sandbox mode, the writable roots, the tool lists — and this change
/// does not touch that function on either harness. What it DOES add is two flags further out
/// in the argv, and "further out in the argv" is not the same as "not a containment change".
/// So the delta is asserted here, exactly, in both directions: nothing is added when the lock
/// is off, and precisely one known thing is added when it is on.
///
/// If someone later adds a third flag behind the write lock, this fails and they have to
/// decide, deliberately, whether the containment record still speaks for the child.
///
/// # THE OPEN GAP THIS TEST IS STANDING IN FOR — tag1consulting/jesse-app#66
///
/// This asserts that the recorded posture still MATCHES what the gate compares. It does NOT
/// establish that the hooked child was ever probed, and it was not: `probe.rs` builds every
/// battery child with `write_lock: None`, so both committed records describe the UNHOOKED
/// shape. Re-cutting them as they stand would re-probe the old posture and prove nothing about
/// the write lock.
///
/// That is a deliberate decision recorded in the 0.60.0 CHANGELOG, not an oversight — and it
/// is the exception to this project's standing rule that a posture the record has not probed
/// is not a posture we ship. **Issue #66 is how it gets closed.** If you are here because you
/// changed something behind the write lock, read that issue before deciding this test is
/// enough.
#[test]
fn the_write_lock_adds_exactly_one_known_flag_per_harness() {
    let s = Scratch::new("argv");
    let cfg = s.config();

    // ---- Codex ----------------------------------------------------------------
    let plain = build_codex_args(
        "hi",
        None,
        Capability::Write,
        &s.vault,
        &[],
        &[],
        &[],
        false,
    );
    let locked = build_codex_args("hi", None, Capability::Write, &s.vault, &[], &[], &[], true);
    let added: Vec<&String> = locked.iter().filter(|a| !plain.contains(a)).collect();
    assert_eq!(
        added,
        vec![&"--dangerously-bypass-hook-trust".to_string()],
        "the Codex write lock must add EXACTLY the trust-bypass flag and nothing else"
    );
    // And the containment-bearing flags are untouched in both.
    for flag in [
        "sandbox_mode=\"workspace-write\"",
        "sandbox_workspace_write.exclude_tmpdir_env_var=true",
        "sandbox_workspace_write.exclude_slash_tmp=true",
        "sandbox_workspace_write.network_access=false",
        "approval_policy=\"never\"",
    ] {
        assert!(plain.iter().any(|a| a == flag), "control: {flag}");
        assert!(
            locked.iter().any(|a| a == flag),
            "the write lock must not disturb {flag}"
        );
    }
    assert!(
        !locked
            .iter()
            .any(|a| a.contains("dangerously-bypass-approvals-and-sandbox")),
        "the trust bypass must never be confused with the sandbox bypass"
    );

    // ---- Claude Code ----------------------------------------------------------
    let plain = build_claude_args(
        &cfg,
        "hi",
        None,
        Capability::Write,
        EMPTY_MCP_CONFIG,
        None,
        None,
    );
    let settings = PathBuf::from("/some/state/dir/claude-settings/job-1.json");
    let locked = build_claude_args(
        &cfg,
        "hi",
        None,
        Capability::Write,
        EMPTY_MCP_CONFIG,
        Some(&settings),
        // no attachments on this turn
        None,
    );
    let added: Vec<&String> = locked.iter().filter(|a| !plain.contains(a)).collect();
    assert_eq!(
        added,
        vec![&"--settings".to_string(), &settings.display().to_string()],
        "the Claude Code write lock must add EXACTLY --settings <path>"
    );
    // The settings file is in the STATE dir, never in the vault — a child-writable settings
    // file is a lock the child can switch off.
    assert!(
        !settings.starts_with(&s.vault),
        "the bridge-owned settings file must never live where a child can edit it"
    );
    assert!(
        plain
            .windows(2)
            .any(|w| w[0] == "--setting-sources" && w[1] == "user,project"),
        "control: the scope flag is still there"
    );
    assert!(
        locked
            .windows(2)
            .any(|w| w[0] == "--setting-sources" && w[1] == "user,project"),
        "--settings is ADDITIVE to the scopes, so the vault's own hooks keep working"
    );
}

/// **The cross-harness case.** A claude-code write and a codex write to the SAME vault path
/// must serialize against each other, not merely each against their own kind.
///
/// Driven at the broker with the two harnesses' REAL payload shapes — Claude Code's absolute
/// `file_path` and Codex's relative-inside-`apply_patch` — because that is where the two
/// spellings either collapse to one key or silently do not. Spawning two live turns racing on
/// one file would test the same property far less deterministically.
#[tokio::test]
async fn a_claude_write_and_a_codex_write_to_one_path_serialize() {
    let s = Scratch::new("cross");
    let vault = s.vault.canonicalize().unwrap();
    let target = vault.join("shared.md");
    std::fs::write(&target, "original").unwrap();
    let cwd = vault.display().to_string();

    let claude = ClaudeCode.hook_write_target(&HookPayload {
        session_id: "s".into(),
        cwd: cwd.clone(),
        tool_name: "Write".into(),
        tool_use_id: "claude-call".into(),
        tool_input: serde_json::json!({
            "file_path": target.display().to_string(),
            "content": "from claude",
        }),
    });
    let codex = Codex.hook_write_target(&HookPayload {
        session_id: "s".into(),
        cwd,
        tool_name: "apply_patch".into(),
        tool_use_id: "codex-call".into(),
        tool_input: serde_json::json!({
            "command": "*** Begin Patch\n*** Update File: shared.md\n+from codex\n*** End Patch",
        }),
    });
    assert_eq!(
        claude, codex,
        "one file, one lock key, whichever harness names it"
    );

    // And that key actually serializes ACROSS the two harnesses at the broker.
    let broker = LockBroker::new();
    let key = match &claude {
        WriteTarget::Path(p) => p.display().to_string(),
        other => panic!("expected a named path, got {other:?}"),
    };
    let allowed = broker
        .handle(HookRequest::Pre {
            turn: "claude-turn".into(),
            conversation: "c".into(),
            tool_use_id: "claude-call".into(),
            target: Some(Some(key.clone())),
            git: false,
        })
        .await;
    assert!(allowed.allow, "the claude write takes the lock");

    // The codex turn, on the SAME resolved key, must not get it while claude holds it.
    let contended = tokio::time::timeout(
        std::time::Duration::from_millis(400),
        broker.handle(HookRequest::Pre {
            turn: "codex-turn".into(),
            conversation: "c".into(),
            tool_use_id: "codex-call".into(),
            target: Some(Some(key)),
            git: false,
        }),
    )
    .await;
    assert!(
        contended.is_err(),
        "a codex write must BLOCK on a lock a claude write holds — if this returns, the two \
         harnesses are not sharing a lock and the cross-harness hazard is open"
    );
}
