//! A registry with TWO harnesses, the second of which keeps no transcripts on disk.
//!
//! Only `claude-code` ships, so this is the test that proves the seam actually holds the
//! shape the trait promises: a harness whose `transcript_dir` is `None` is skipped by
//! conversation adoption, skipped by the GC sweep, and skipped by the resume existence
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
        cfg.harnesses.turn_harness().id(),
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
async fn a_transcriptless_harness_is_skipped_by_adoption_and_the_sweep_but_still_converses() {
    let (home, vault, claude_dir, other_dir) = two_harness_fixture();

    // One transcript in each directory, both ancient. Only the claude-code one is in a
    // directory any harness admits to owning.
    write_transcript(&claude_dir, "claude-orphan", "adopt me");
    make_ancient(&claude_dir.join("claude-orphan.jsonl"));
    write_transcript(&other_dir, "other-orphan", "do not touch me");
    make_ancient(&other_dir.join("other-orphan.jsonl"));

    let cfg = two_harness_config(&home, &vault);
    let st = AppState::new(cfg.clone());

    // ---- Adoption skips it -------------------------------------------------
    // Startup adoption scanned claude-code's dir and adopted its stray; the other dir was
    // never scanned, so its stray produced no conversation.
    assert!(
        st.conversations
            .conversation_for_session("claude-orphan")
            .is_some(),
        "the transcript-bearing harness's stray is adopted, as before"
    );
    assert!(
        st.conversations
            .conversation_for_session("other-orphan")
            .is_none(),
        "a transcript-less harness contributes no directory, so nothing is adopted from it"
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
/// DECLARES that directory: now it is adopted at startup and reclaimed by the sweep. So the
/// file's survival in the test above is the `None` doing the work.
#[tokio::test]
async fn the_same_stray_is_adopted_and_swept_once_a_harness_declares_its_directory() {
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
            .is_some(),
        "a declared directory IS scanned by adoption"
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
