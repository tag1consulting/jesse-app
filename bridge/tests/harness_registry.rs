//! A registry with TWO harnesses, the second of which keeps no transcripts on disk.
//!
//! Only `claude-code` ships, so this is the test that proves the seam actually holds the
//! shape the trait promises: a harness whose `transcript_dir` is `None` is skipped by the
//! unowned-transcript scan, skipped by the GC sweep, and skipped by the resume existence
//! check — while its conversations still live in the registry, still list, still resolve a
//! resume, and hydrate to an EMPTY history with a `200` rather than an error.
mod common;
use axum::http::StatusCode;
use common::*;
use jesse_bridge::*;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Command;
use tower::ServiceExt;

/// A second harness for the test: it delivers its answer whole rather than as token-level
/// deltas, and it keeps NO transcripts the bridge can read — its thread state is its own
/// business, which is the shape a thread-id-based agent (Codex) actually has.
struct NoTranscriptHarness;

impl Harness for NoTranscriptHarness {
    fn id(&self) -> &'static str {
        "test-no-transcript"
    }
    fn streams_text(&self) -> bool {
        false
    }
    fn expresses(&self, _capability: Capability) -> bool {
        true
    }
    fn capability_args(&self, _cfg: &Config, _capability: Capability) -> Vec<String> {
        Vec::new()
    }
    fn transcript_dir(&self, _cfg: &Config) -> Option<PathBuf> {
        None
    }
    fn build_turn(&self, _cfg: &Config, _req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        // Nothing in this test spawns it; refusing rather than returning a half-meant
        // command is exactly what `HarnessError` is for.
        Err(HarnessError::unsupported(
            "test-no-transcript",
            "spawning a child",
        ))
    }
    fn parser(&self) -> Box<dyn TurnParser> {
        Box::new(NoTranscriptParser)
    }
}

/// The CONTROL for the one above: the same test double, except it declares a transcript
/// directory. It exists so the survival of a stray file under `NoTranscriptHarness` is
/// proven to be the `None` doing the work, not an accident of where the file sits.
struct FixedDirHarness(PathBuf);

impl Harness for FixedDirHarness {
    fn id(&self) -> &'static str {
        "test-fixed-dir"
    }
    fn streams_text(&self) -> bool {
        true
    }
    fn expresses(&self, _capability: Capability) -> bool {
        true
    }
    fn capability_args(&self, _cfg: &Config, _capability: Capability) -> Vec<String> {
        Vec::new()
    }
    fn transcript_dir(&self, _cfg: &Config) -> Option<PathBuf> {
        Some(self.0.clone())
    }
    fn build_turn(&self, _cfg: &Config, _req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        Err(HarnessError::unsupported("test-fixed-dir", "spawning a child"))
    }
    fn parser(&self) -> Box<dyn TurnParser> {
        Box::new(NoTranscriptParser)
    }
}

/// Its parser ignores everything: neither test double is ever driven here.
struct NoTranscriptParser;
impl TurnParser for NoTranscriptParser {
    fn on_line(&mut self, _line: &str) -> StreamEvent {
        StreamEvent::Ignore
    }
}

const CID_TRANSCRIPTLESS: &str = "99999999-8888-4777-8666-555555555555";

/// A home + vault + the claude-code projects dir, plus a SECOND directory standing in for
/// the one a transcript-bearing second harness would have owned. The fake harness returns
/// `None`, so nothing must ever look in it.
fn two_harness_fixture() -> (PathBuf, String, PathBuf, PathBuf) {
    let home = std::env::temp_dir().join(format!("jesse-home-{}", random_hex()));
    let vault_dir = std::env::temp_dir().join(format!("jesse-vault-{}", random_hex()));
    std::fs::create_dir_all(&vault_dir).unwrap();
    let vault = vault_dir.to_string_lossy().into_owned();
    let claude_dir = home
        .join(".claude")
        .join("projects")
        .join(escape_project_path(&vault));
    std::fs::create_dir_all(&claude_dir).unwrap();
    let other_dir = home.join(".test-no-transcript").join("threads");
    std::fs::create_dir_all(&other_dir).unwrap();
    (home, vault, claude_dir, other_dir)
}

fn two_harness_config(home: &std::path::Path, vault: &str) -> Config {
    Config {
        home: home.to_string_lossy().into_owned(),
        vault: vault.to_string(),
        state_dir: None,
        session_ttl_days: 90,
        harnesses: Arc::new(HarnessRegistry::new(vec![Box::new(NoTranscriptHarness)])),
        ..test_config()
    }
}

fn write_transcript(dir: &std::path::Path, stem: &str, question: &str) {
    std::fs::write(
        dir.join(format!("{stem}.jsonl")),
        format!("{{\"type\":\"user\",\"message\":{{\"content\":\"{question}\"}}}}\n"),
    )
    .unwrap();
}

/// Age a file far past any TTL (mtime at the epoch), so the sweep would reclaim it if it
/// ever looked.
fn make_ancient(path: &std::path::Path) {
    std::fs::File::open(path)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH)
        .unwrap();
}

#[test]
fn the_registry_holds_both_and_only_the_transcript_bearing_one_contributes_a_dir() {
    let (home, vault, claude_dir, _other) = two_harness_fixture();
    let cfg = two_harness_config(&home, &vault);

    assert_eq!(
        cfg.harnesses.ids(),
        vec![CLAUDE_CODE_ID, "test-no-transcript"],
        "the turn harness sorts first, then the rest by id"
    );
    assert_eq!(
        cfg.harnesses.fallback_harness().id(),
        CLAUDE_CODE_ID,
        "registering a second harness does not change which one serves turns"
    );
    // Only claude-code contributes a directory; the other keeps none.
    assert_eq!(cfg.harnesses.transcript_dirs(&cfg), vec![claude_dir]);
    let other = cfg.harnesses.get("test-no-transcript").expect("registered");
    assert!(other.transcript_dir(&cfg).is_none());
    assert!(!other.streams_text(), "it answers whole, not in deltas");
    // And it refuses a request it cannot express rather than downgrading it.
    let ambient = ActiveModel::ambient();
    let err = other
        .build_turn(&cfg, &title_child_request(&cfg, "hi", &ambient))
        .expect_err("this harness refuses");
    assert_eq!(ApiError::from(err).0, StatusCode::INTERNAL_SERVER_ERROR);

    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn a_transcriptless_harness_is_skipped_by_the_scan_and_the_sweep_but_still_converses() {
    let (home, vault, claude_dir, other_dir) = two_harness_fixture();

    // One transcript in each directory, both ancient. Only the claude-code one is in a
    // directory any harness admits to owning.
    write_transcript(&claude_dir, "claude-orphan", "adopt me");
    make_ancient(&claude_dir.join("claude-orphan.jsonl"));
    write_transcript(&other_dir, "other-orphan", "do not touch me");
    make_ancient(&other_dir.join("other-orphan.jsonl"));

    let cfg = two_harness_config(&home, &vault);
    let st = AppState::new(cfg.clone());

    // ---- The scan skips it -------------------------------------------------
    // Neither stray becomes a conversation any more: the bridge adopts nothing it did not
    // start. What still differs is WHICH directory the startup scan visited at all, and
    // the report memo is the witness — a stem reported once is never reported again, so a
    // second call returns nothing for the dir that was scanned and the stem for the dir
    // that was not.
    assert!(
        st.conversations
            .conversation_for_session("claude-orphan")
            .is_none(),
        "a stray in a declared dir is scanned, but never adopted"
    );
    assert!(
        st.conversations
            .conversation_for_session("other-orphan")
            .is_none(),
        "and a transcript-less harness contributes no directory to scan at all"
    );
    assert_eq!(
        report_unowned_transcripts(&claude_dir, &st.conversations),
        vec![],
        "claude-code's dir was already scanned at startup, so its stray is not re-reported"
    );
    assert_eq!(
        report_unowned_transcripts(&other_dir, &st.conversations),
        vec![("other-orphan".to_string(), UnownedReason::NotOurs)],
        "the other dir was never scanned, so its stray is being seen for the first time"
    );

    // A conversation belonging to that harness, registered the way any turn registers one.
    // Its thread id names no file anywhere — that is the whole point.
    st.conversations.register(
        CID_TRANSCRIPTLESS,
        Some("phone"),
        system_time_to_ms(std::time::SystemTime::now()),
    );
    st.conversations
        .bind_session(CID_TRANSCRIPTLESS, "thread-b-1");

    // ---- The sweep skips it ------------------------------------------------
    run_session_gc(&st.cfg, &st.conversations, &st.titles, &st.flags);
    assert!(
        !claude_dir.join("claude-orphan.jsonl").exists(),
        "the sweep still reclaims an aged-out transcript in a directory a harness owns"
    );
    assert!(
        other_dir.join("other-orphan.jsonl").exists(),
        "the sweep must never touch a directory no harness declares"
    );
    assert!(
        st.conversations.get(CID_TRANSCRIPTLESS).is_some(),
        "a freshly registered conversation survives the sweep, transcripts or not"
    );

    // ---- Its conversations still list --------------------------------------
    let resp = app(st.clone())
        .oneshot(conversations_request(Some("Bearer test-token"), None, None))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    let listed = body["conversations"]
        .as_array()
        .expect("a conversations array")
        .iter()
        .find(|c| c["conversation_id"] == CID_TRANSCRIPTLESS)
        .expect("the transcript-less conversation is listed like any other");
    assert_eq!(listed["session_id"], "thread-b-1");
    assert_eq!(
        listed["first_message"],
        Value::Null,
        "no transcript on disk → no snippet, and that is not an error"
    );
    assert!(
        listed["last_modified"].as_u64().unwrap_or(0) > 0,
        "it is dated from registered_ms, since there is no mtime to read"
    );

    // ---- It still resumes --------------------------------------------------
    let harness = st
        .cfg
        .harnesses
        .get("test-no-transcript")
        .expect("registered");
    let requested = resolve_conversation_resume(&st.conversations, CID_TRANSCRIPTLESS, None);
    assert_eq!(requested.as_deref(), Some("thread-b-1"));
    assert_eq!(
        resolve_resume_session_for_harness(&st.cfg, harness, requested.as_deref()),
        Some("thread-b-1"),
        "there is no file whose absence could justify dropping the resume"
    );
    // Under the transcript-BEARING harness the same id has no transcript, so the existing
    // resume-after-sweep safety still drops it to a fresh run. Both behaviors, one check.
    assert_eq!(
        resolve_resume_session(&st.cfg, requested.as_deref()),
        None,
        "claude-code still falls to a fresh session when the transcript is gone"
    );

    // ---- It hydrates to an empty history, with a 200 -----------------------
    let resp = app(st.clone())
        .oneshot(conversation_hydrate_request(
            Some("Bearer test-token"),
            CID_TRANSCRIPTLESS,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a conversation with no transcript on disk hydrates empty, never an error"
    );
    let body: Value = serde_json::from_str(&body_string(resp).await).unwrap();
    assert_eq!(body["conversation_id"], CID_TRANSCRIPTLESS);
    assert_eq!(
        body["turns"].as_array().map(Vec::len),
        Some(0),
        "no server-side history: the app's local transcript is the user-visible record"
    );
    assert!(
        body["next_cursor"].is_string(),
        "and the cursor still round-trips so a later poll is a cheap no-op"
    );

    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&vault);
}

/// The control. The very same stray, in the very same directory, under a harness that
/// DECLARES that directory: now it is scanned at startup and reclaimed by the sweep. So the
/// file's survival in the test above is the `None` doing the work.
#[tokio::test]
async fn the_same_stray_is_scanned_and_swept_once_a_harness_declares_its_directory() {
    let (home, vault, _claude_dir, other_dir) = two_harness_fixture();
    write_transcript(&other_dir, "other-orphan", "adopt me after all");
    make_ancient(&other_dir.join("other-orphan.jsonl"));

    let cfg = Config {
        harnesses: Arc::new(HarnessRegistry::new(vec![Box::new(FixedDirHarness(
            other_dir.clone(),
        ))])),
        ..two_harness_config(&home, &vault)
    };
    let st = AppState::new(cfg);
    assert!(
        st.conversations
            .conversation_for_session("other-orphan")
            .is_none(),
        "a declared directory is scanned, but a stray in it is still never adopted"
    );
    assert_eq!(
        report_unowned_transcripts(&other_dir, &st.conversations),
        vec![],
        "a declared directory IS scanned at startup — its stray was already reported"
    );
    run_session_gc(&st.cfg, &st.conversations, &st.titles, &st.flags);
    assert!(
        !other_dir.join("other-orphan.jsonl").exists(),
        "and IS swept once it ages out"
    );

    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&vault);
}

/// The delete route is the fourth reader of the transcript surface, and it must stay
/// idempotent for a conversation whose harness wrote no files at all.
#[tokio::test]
async fn deleting_a_transcriptless_conversation_is_a_clean_204() {
    let (home, vault, _claude_dir, _other_dir) = two_harness_fixture();
    let st = AppState::new(two_harness_config(&home, &vault));
    st.conversations.register(
        CID_TRANSCRIPTLESS,
        Some("phone"),
        system_time_to_ms(std::time::SystemTime::now()),
    );
    st.conversations
        .bind_session(CID_TRANSCRIPTLESS, "thread-b-1");

    let resp = app(st.clone())
        .oneshot(conversation_delete_request(
            Some("Bearer test-token"),
            CID_TRANSCRIPTLESS,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(st.conversations.get(CID_TRANSCRIPTLESS).is_none());

    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&vault);
}

/// Nothing above changes what the shipped, one-harness bridge does: the registry a real
/// deploy builds holds exactly `claude-code`, and it owns exactly the projects dir the
/// session code used to hardcode.
#[test]
fn the_shipped_registry_is_unchanged_by_any_of_this() {
    let cfg = Config {
        home: "/home/bob".to_string(),
        vault: "/vault/notes".to_string(),
        ..test_config()
    };
    assert_eq!(cfg.harnesses.ids(), vec![CLAUDE_CODE_ID]);
    assert_eq!(
        cfg.harnesses.transcript_dirs(&cfg),
        vec![PathBuf::from("/home/bob/.claude/projects/-vault-notes")]
    );
}

/// A CODEX CONVERSATION RESUMES ACROSS THREE TURNS, end to end through the same pieces a
/// real turn uses: the parser reads the thread id off the child's stream, the driver's
/// `SpawnedSessions` records it, the conversation store binds it, the next turn resolves it
/// back out, and the argv builder turns it into `codex exec resume <id>`.
///
/// **Three turns rather than two, because two cannot catch the bug this guards.** Turn 2
/// proves a resume happens at all. Turn 3 proves the conversation tracks the id FORWARD: a
/// resumed Codex turn reports a NEW thread id (the thread forks, exactly as a resumed Claude
/// Code session gets a fresh transcript stem), and a store that kept binding the first one
/// would resume turn 1's thread forever while every turn appeared to succeed. Nothing about
/// that failure is visible from the outside — the answers would just quietly lose the middle
/// of the conversation.
///
/// This is the whole safety net for Codex resume. `transcript_dir` is `None`, so there is no
/// file on disk to fall back to and `resolve_resume_session_for_harness` deliberately skips
/// its existence check: the bound id IS the record.
#[test]
fn a_codex_conversation_resumes_across_three_turns() {
    let cfg = test_config();
    let conversations = ConversationStore::new(None);
    const CID: &str = "conv-codex-resume";
    conversations.register(CID, None, 1_000);

    // Each turn's child reports its own thread id, and a resumed thread reports a new one.
    let threads = ["th_aaa", "th_bbb", "th_ccc"];
    let mut resumed: Vec<Option<String>> = Vec::new();

    for (turn, thread) in threads.iter().enumerate() {
        // What this turn will resume, resolved the way the handler resolves it: the
        // conversation's bound session leads, and the request carries nothing.
        let sid = resolve_conversation_resume(&conversations, CID, None);
        let sid = resolve_resume_session_for_harness(&cfg, &Codex, sid.as_deref())
            .map(str::to_string);
        resumed.push(sid.clone());

        // The argv the harness would actually spawn.
        let argv = build_codex_args(
            "what did I say?",
            sid.as_deref(),
            Capability::Read,
            std::path::Path::new("/vault/notes"),
            &[],
        );
        match &sid {
            None => assert!(
                !argv.contains(&"resume".to_string()),
                "turn {turn} has nothing to resume and must not pass `resume`"
            ),
            Some(id) => {
                let at = argv.iter().position(|a| a == "resume").unwrap_or_else(|| {
                    panic!("turn {turn} should have resumed {id}, argv: {argv:?}")
                });
                assert_eq!(argv[at - 1], "exec", "`resume` is a subcommand of `exec`");
                assert_eq!(&argv[at + 1], id, "resume must name the bound thread");
            }
        }

        // Now run this turn's stream through the real parser and the real driver-side
        // recorder, and bind what it reported — the `spawned.ids()` path in the handler.
        let spawned = SpawnedSessions::new();
        let mut parser = Codex.parser();
        let mut done = None;
        for line in [
            format!(r#"{{"type":"thread.started","thread_id":"{thread}"}}"#),
            r#"{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}"#
                .to_string(),
            r#"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}"#
                .to_string(),
        ] {
            match parser.on_line(&line) {
                StreamEvent::SessionId(id) => spawned.record(&id),
                StreamEvent::Done(o) => done = Some(o),
                _ => {}
            }
        }
        assert!(matches!(done, Some(ClaudeOutcome::Ok { .. })), "turn {turn} ok");
        assert_eq!(
            spawned.ids(),
            vec![thread.to_string()],
            "turn {turn}: the id must reach the driver from `thread.started`, not only from \
             the terminal event — a turn that dies mid-flight still owns its thread"
        );
        for id in spawned.ids() {
            conversations.bind_session(CID, &id);
        }
    }

    assert_eq!(
        resumed,
        vec![None, Some("th_aaa".to_string()), Some("th_bbb".to_string())],
        "turn 1 starts fresh; turn 2 resumes turn 1's thread; turn 3 resumes turn 2's — the \
         conversation follows the fork rather than pinning the first id"
    );
    assert_eq!(
        conversations.get(CID).map(|c| c.session_ids),
        Some(threads.iter().map(|s| s.to_string()).collect::<Vec<_>>()),
        "every thread the conversation ever ran stays an alias, newest current"
    );
}
