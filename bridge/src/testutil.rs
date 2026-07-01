//! Crate-internal test helpers shared by the per-module `#[cfg(test)]`
//! suites. Not compiled into the library proper.
#![cfg(test)]
use crate::*;

    pub(crate) static ENV_LOCK: Mutex<()> = Mutex::new(());
    pub(crate) fn test_config() -> Config {
        Config {
            token: "test-token".to_string(),
            // Any existing directory works — most tests never reach run_claude.
            vault: std::env::temp_dir().to_string_lossy().into_owned(),
            bind: "127.0.0.1".to_string(),
            port: 8765,
            claude_bin: "claude".to_string(),
            timeout_secs: 1800,
            allowed_tools: DEFAULT_ALLOWED_TOOLS.to_string(),
            disallowed_tools: DEFAULT_DISALLOWED_TOOLS.to_string(),
            max_concurrency: 2,
            rate_per_min: 30,
            job_ttl_secs: 600,
            retrieval_grace_secs: 600,
            // No on-disk persistence in tests by default — keeps cargo test off
            // the real $HOME. The persistence tests build a store with a temp dir.
            state_dir: None,
            max_attachments: DEFAULT_MAX_ATTACHMENTS,
            max_attachment_bytes: DEFAULT_MAX_ATTACHMENT_BYTES,
            max_attachments_total_bytes: DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
            scratch_dir: None,
        }
    }
    pub(crate) fn test_state() -> AppState {
        AppState::new(test_config())
    }
    pub(crate) fn temp_jobs_dir() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-jobs-{}", random_hex()))
    }
