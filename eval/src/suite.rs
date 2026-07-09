//! Suite + task schema and the load-bearing vault-readonly allowlist check.
//!
//! A suite is a JSON file (see `eval/README.md` for the documented schema and a
//! full example task). Tasks are hermetic: a `fixture` task runs in a fresh temp
//! dir populated from its inline `fixture_files`; a `vault-readonly` task runs
//! against the real vault (`~/devel/tag1/jesse`) and MUST be restricted to read
//! tools only — enforced by [`Task::validate`].

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// A full eval suite: a name plus an ordered list of tasks.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Suite {
    pub name: String,
    pub tasks: Vec<Task>,
}

/// Where a task runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Workspace {
    /// A fresh temp dir populated from `fixture_files` before the run. Hermetic.
    Fixture,
    /// The real vault at `~/devel/tag1/jesse`, read-only. Allowlist is hard-capped
    /// to read tools by [`Task::validate`] so an eval run can never mutate it.
    VaultReadonly,
}

/// One assertion. A task passes iff every assertion passes.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Assertion {
    /// Regex must match somewhere in the final answer.
    AnswerMatches { pattern: String },
    /// Regex must NOT match anywhere in the final answer.
    AnswerExcludes { pattern: String },
    /// A file in the task workspace must have exactly this content.
    FileEquals { path: String, content: String },
    /// Regex must match somewhere in a workspace file's content.
    FileMatches { path: String, pattern: String },
    /// Total tool-call count must be <= this ceiling.
    MaxToolCalls { max: u32 },
    /// A terminal `result` line must have arrived at all.
    Completed,
}

/// A single eval task.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Task {
    pub id: String,
    /// Task class, used to group the scorecard (e.g. `titles`, `extraction`).
    pub class: String,
    /// The prompt handed to `claude -p`.
    pub prompt: String,
    pub workspace: Workspace,
    /// Tools passed to `--allowedTools` (comma-joined). Empty = no tools.
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    /// For `fixture` workspaces: files written into the temp dir before the run.
    #[serde(default)]
    pub fixture_files: BTreeMap<String, String>,
    /// Judged tasks have their final answer saved as an artifact for `judge`.
    #[serde(default)]
    pub judged: bool,
    /// Grading rubric text, required for judged tasks; presented to the judge.
    #[serde(default)]
    pub rubric: Option<String>,
    pub assertions: Vec<Assertion>,
}

/// The only tools a `vault-readonly` task may use. Nothing that can write.
pub const VAULT_ALLOWED_TOOLS: &[&str] = &[
    "Read",
    "Grep",
    "Glob",
    "mcp__qmd__query",
    "mcp__qmd__get",
    "mcp__qmd__multi_get",
    "mcp__qmd__status",
];

/// Home directory from `$HOME`. Used to derive the vault path at runtime so no
/// personal absolute path is ever committed (repo guard R5).
pub fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".to_string()))
}

/// The vault working directory (`~/devel/tag1/jesse`).
pub fn vault_dir() -> PathBuf {
    home_dir().join("devel").join("tag1").join("jesse")
}

impl Task {
    /// The comma-joined `--allowedTools` value for this task.
    pub fn allowed_tools_csv(&self) -> String {
        self.allowed_tools.join(",")
    }

    /// Load-bearing safety check. A `vault-readonly` task must declare only
    /// read tools; any other tool (Write, Edit, any Bash, …) is refused so an
    /// eval run can never modify the vault. Also requires judged tasks to carry
    /// a rubric. Returns `Err` with a human-readable reason on any violation.
    pub fn validate(&self) -> Result<(), String> {
        if self.workspace == Workspace::VaultReadonly {
            for tool in &self.allowed_tools {
                if !VAULT_ALLOWED_TOOLS.contains(&tool.as_str()) {
                    return Err(format!(
                        "task '{}' is vault-readonly but its allowlist contains '{}', \
                         which is not a read-only tool. Allowed: {}",
                        self.id,
                        tool,
                        VAULT_ALLOWED_TOOLS.join(", ")
                    ));
                }
            }
        }
        if self.judged && self.rubric.as_deref().unwrap_or("").trim().is_empty() {
            return Err(format!(
                "task '{}' is judged but has no rubric text",
                self.id
            ));
        }
        Ok(())
    }
}

impl Suite {
    /// Parse a suite from JSON bytes and validate every task.
    pub fn from_json(bytes: &[u8]) -> Result<Suite, String> {
        let suite: Suite =
            serde_json::from_slice(bytes).map_err(|e| format!("invalid suite JSON: {e}"))?;
        for task in &suite.tasks {
            task.validate()?;
        }
        Ok(suite)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task_with(workspace: Workspace, tools: &[&str]) -> Task {
        Task {
            id: "t".into(),
            class: "c".into(),
            prompt: "p".into(),
            workspace,
            allowed_tools: tools.iter().map(|s| s.to_string()).collect(),
            fixture_files: BTreeMap::new(),
            judged: false,
            rubric: None,
            assertions: vec![],
        }
    }

    #[test]
    fn vault_allows_read_tools() {
        let t = task_with(
            Workspace::VaultReadonly,
            &["Read", "Grep", "Glob", "mcp__qmd__query", "mcp__qmd__get"],
        );
        assert!(t.validate().is_ok());
    }

    #[test]
    fn vault_refuses_write() {
        let t = task_with(Workspace::VaultReadonly, &["Read", "Write"]);
        let err = t.validate().unwrap_err();
        assert!(err.contains("Write"), "error should name the offending tool: {err}");
    }

    #[test]
    fn vault_refuses_edit() {
        let t = task_with(Workspace::VaultReadonly, &["Edit"]);
        assert!(t.validate().is_err());
    }

    #[test]
    fn vault_refuses_any_bash() {
        // Even a "harmless"-looking scoped Bash is refused: the check is an
        // allowlist, not a denylist.
        let t = task_with(Workspace::VaultReadonly, &["Read", "Bash(ls:*)"]);
        let err = t.validate().unwrap_err();
        assert!(err.contains("Bash(ls:*)"), "got: {err}");
    }

    #[test]
    fn fixture_allows_anything() {
        // Fixture workspaces are hermetic temp dirs, so any tool is fine there.
        let t = task_with(Workspace::Fixture, &["Write", "Edit", "Bash"]);
        assert!(t.validate().is_ok());
    }

    #[test]
    fn judged_requires_rubric() {
        let mut t = task_with(Workspace::Fixture, &[]);
        t.judged = true;
        assert!(t.validate().is_err());
        t.rubric = Some("grade for accuracy".into());
        assert!(t.validate().is_ok());
    }
}
