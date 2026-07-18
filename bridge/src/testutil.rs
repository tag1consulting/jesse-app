//! Crate-internal test helpers shared by the per-module `#[cfg(test)]`
//! suites. Not compiled into the library proper.
#![cfg(test)]
use crate::*;

pub(crate) static ENV_LOCK: Mutex<()> = Mutex::new(());
pub(crate) fn test_config() -> Config {
    Config {
        token: "test-token".to_string(),
        // Captured HOME for session-path lookups; tests that exercise session
        // paths override `home`/`vault` explicitly (no global-env mutation).
        home: std::env::var("HOME").unwrap_or_default(),
        // Any existing directory works — most tests never reach run_claude.
        vault: std::env::temp_dir().to_string_lossy().into_owned(),
        bind: "127.0.0.1".to_string(),
        port: 8765,
        claude_bin: "claude".to_string(),
        timeout_secs: 1800,
        allowed_tools: DEFAULT_ALLOWED_TOOLS.to_string(),
        disallowed_tools: DEFAULT_DISALLOWED_TOOLS.to_string(),
        max_concurrency: 2,
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
        scratch_dir: None,
        // No title-backend override by default — tests that need one set it
        // explicitly, mirroring an unconfigured (ambient-backend) deploy.
        title_backend: None,
        // No diet-extract backend override by default — the pipeline is dormant
        // (kill switch), so tests exercise today's hosted path unless they set it.
        diet_backend: None,
        // Probation on by default, matching from_env's default.
        diet_probation: true,
        // No vault-QA backend override by default — the route is inert (kill
        // switch), so tests exercise today's hosted Ask path unless they set it.
        vaultqa_backend: None,
        vaultqa_mcp_config: None,
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
    }
}
pub(crate) fn test_state() -> AppState {
    AppState::new(test_config())
}
pub(crate) fn temp_jobs_dir() -> PathBuf {
    std::env::temp_dir().join(format!("jesse-jobs-{}", random_hex()))
}
