//! Canned stream-json responses for `--mock`, so CI can exercise the whole run
//! pipeline (workspace setup → transcript → parse → assert → scorecard) with
//! zero network and zero models.
//!
//! A mock file maps task id → a canned response. Each response supplies the raw
//! NDJSON objects the harness would otherwise have read from `claude`'s stdout,
//! and optionally a set of files to drop into the task workspace to stand in for
//! tool side effects (so file assertions can be exercised too).

use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize)]
pub struct MockFile {
    pub responses: BTreeMap<String, MockResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MockResponse {
    /// Raw stream-json objects, emitted in order as NDJSON lines.
    pub ndjson: Vec<serde_json::Value>,
    /// Files written into the workspace before assertions run (relative paths),
    /// standing in for what the model's tools would have written.
    #[serde(default)]
    pub files: BTreeMap<String, String>,
}

impl MockFile {
    pub fn from_json(bytes: &[u8]) -> Result<MockFile, String> {
        serde_json::from_slice(bytes).map_err(|e| format!("invalid mock JSON: {e}"))
    }

    /// The NDJSON lines for a task, as strings, or `None` if the task is absent.
    pub fn lines_for(&self, task_id: &str) -> Option<Vec<String>> {
        self.responses
            .get(task_id)
            .map(|r| r.ndjson.iter().map(|v| v.to_string()).collect())
    }
}
