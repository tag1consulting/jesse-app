//! Crate-internal test helpers shared by the per-module `#[cfg(test)]`
//! suites. Not compiled into the library proper.
#![cfg(test)]
use crate::*;

pub(crate) static ENV_LOCK: Mutex<()> = Mutex::new(());
pub(crate) fn test_config() -> Config {
    Config {
        offload_order: Vec::new(),
        token: "test-token".to_string(),
        // Captured HOME for session-path lookups; tests that exercise session
        // paths override `home`/`vault` explicitly (no global-env mutation).
        home: std::env::var("HOME").unwrap_or_default(),
        // Any existing directory works — most tests never reach run_claude.
        vault: std::env::temp_dir().to_string_lossy().into_owned(),
        bind: "127.0.0.1".to_string(),
        port: 8765,
        claude_bin: "claude".to_string(),
        codex_bin: "codex".to_string(),
        timeout_secs: 1800,
        partial_blocks: DEFAULT_PARTIAL_BLOCKS,
        partial_bytes: DEFAULT_PARTIAL_BYTES,
        allowed_tools: DEFAULT_ALLOWED_TOOLS.to_string(),
        disallowed_tools: DEFAULT_DISALLOWED_TOOLS.to_string(),
        concurrency: ConcurrencySettings::uniform(2, &["opus"]),
        max_queued: DEFAULT_MAX_QUEUED,
        rate_per_min: 30,
        job_ttl_secs: 600,
        retrieval_grace_secs: 600,
        session_ttl_days: DEFAULT_SESSION_TTL_DAYS,
        // No on-disk persistence in tests by default — keeps cargo test off
        // the real $HOME. The persistence tests build a store with a temp dir.
        state_dir: None,
        max_attachments: DEFAULT_MAX_ATTACHMENTS,
        max_attachment_bytes: DEFAULT_MAX_ATTACHMENT_BYTES,
        max_attachments_total_bytes: DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
        // Shipped artifact caps in the fixture: the cap tests override the one they
        // exercise, so a default that differs from production would only hide drift.
        max_artifacts: DEFAULT_MAX_ARTIFACTS,
        max_artifact_bytes: DEFAULT_MAX_ARTIFACT_BYTES,
        max_artifacts_total_bytes: DEFAULT_MAX_ARTIFACTS_TOTAL_BYTES,
        artifact_ttl_days: DEFAULT_ARTIFACT_TTL_DAYS,
        artifact_store_max_bytes: DEFAULT_ARTIFACT_STORE_MAX_BYTES,
        scratch_dir: None,
        // No title-backend override by default — tests that need one set it
        // explicitly, mirroring an unconfigured (ambient-backend) deploy.
        // No diet-extract backend override by default — the pipeline is dormant
        // (kill switch), so tests exercise today's hosted path unless they set it.
        // Probation on by default, matching from_env's default.
        diet_micro_complete: true,
        // No vault-QA backend override by default — the route is inert (kill
        // switch), so tests exercise today's hosted Ask path unless they set it.
        vaultqa_mcp_config: None,
        // No main-path MCP override in the fixture — the main turn falls back to the
        // qmd-only inline const, matching from_env's default.
        main_mcp_config: None,
        // Badge OFF in the fixture so a turn's stored reply is byte-for-byte the
        // model text — the many exact-`response` assertions predate the badge and
        // must not have to account for it. Badge behavior is covered by dedicated
        // tests that enable it explicitly (the shipped `from_env` default is ON).
        model_badge: false,
        // No metrics log and emergency OFF in the fixture — both dormant, matching
        // an unconfigured deploy. The both-unset safety property depends on this
        // default: every existing path is byte-for-byte unchanged. Tests that
        // exercise metrics/emergency set these explicitly.
        metrics_log: None,
        emergency_local: false,
        // Context carry OFF in the fixture (like the badge/emergency defaults): the
        // many exact-`response`/`session_id` assertions predate it and must be
        // byte-for-byte unaffected. Carry behavior is covered by dedicated tests that
        // enable it explicitly (the shipped `from_env` default is ON).
        context_carry: false,
        // Shadow comparison DISARMED in the fixture (kill switch): no backend triple,
        // so no ask turn is ever mirrored and every path is byte-for-byte today's.
        // Tests that exercise shadow set `shadow_backend`/`shadow_log` explicitly.
        shadow_backend: None,
        shadow_sample_pct: 100,
        shadow_log: std::env::temp_dir()
            .join("jesse-shadow-test.jsonl")
            .to_string_lossy()
            .into_owned(),
        shadow_timeout_secs: 120,
        // No scheduled jobs in the fixture: the tick task is never started and the
        // scheduler is inert, so every existing test is byte-for-byte unaffected. Tests
        // that exercise the scheduler build their own `Schedule`.
        schedule: Arc::new(Schedule::default()),
        // Generic default persona (owner "the user"): the fresh-clone identity, so
        // every existing prompt/gate assertion is byte-for-byte the generic form.
        // Tests that exercise a named owner or extra diet vocab set this explicitly.
        persona: Persona::default(),
        // Opus-only registry in the fixture: the single always-available ambient
        // default, so a turn that doesn't opt into the switch is byte-for-byte today's
        // behavior. Tests that exercise a hosted/local model build their own registry.
        model_registry: ModelRegistry::opus_only(),
        vision: VisionConfig::default(),
        // The shipped harness registry: `claude-code` only, exactly as `from_env` builds
        // it. A test that needs a second harness constructs its own `HarnessRegistry`.
        harnesses: Arc::new(HarnessRegistry::claude_code_only()),
        // No `[direct]` table in the fixture: the direct harness is not registered here, so
        // every setting is inert and every existing turn assertion is unaffected.
        direct: DirectSettings::default(),
    }
}
pub(crate) fn test_state() -> AppState {
    AppState::new(test_config())
}
pub(crate) fn temp_jobs_dir() -> PathBuf {
    std::env::temp_dir().join(format!("jesse-jobs-{}", random_hex()))
}
