//! Suite + task schema and the load-bearing vault-readonly allowlist check.
//!
//! A suite is a JSON file (see `eval/README.md` for the documented schema and a
//! full example task). Tasks are hermetic: a `fixture` task runs in a fresh temp
//! dir populated from its inline `fixture_files`; a `vault-readonly` task runs
//! against the real vault (`$JESSE_VAULT`, else `~/vault`) and MUST be restricted
//! to read tools only — enforced by [`Task::validate`].

use jesse_agent::{Level, PersonaPack};
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
    /// The real vault (`$JESSE_VAULT`, else `~/vault`), read-only. Allowlist is hard-capped
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
    /// A numeric value — capture group 1 of `pattern`, parsed as an f64 — must
    /// fall within the inclusive band `[min, max]`. When `path` is set the value
    /// is captured from that workspace file; otherwise from the final answer.
    /// This is the mechanical macro-band check (e.g. logged Calories in range),
    /// replacing brittle regex-alternation of every acceptable number.
    NumberInRange {
        #[serde(default)]
        path: Option<String>,
        pattern: String,
        min: f64,
        max: f64,
    },
    /// Two numbers must agree within `tolerance`: capture group 1 of
    /// `file_pattern` from the workspace file at `path`, and capture group 1 of
    /// `answer_pattern` from the final answer. Passes iff both parse and their
    /// absolute difference is `<= tolerance` (default `0.0` = exact). This is the
    /// mirror-vs-CSV consistency check — the emitted `JESSE_MEAL_LOG` macro must
    /// equal the appended row's macro.
    NumbersConsistent {
        path: String,
        file_pattern: String,
        answer_pattern: String,
        #[serde(default)]
        tolerance: f64,
    },
    /// A terminal `result` line must have arrived at all.
    Completed,
    /// The final answer must break NOTHING in the task's [`PersonaPack`] — the style
    /// checker (`jesse_agent::persona::check`) reports at most `max_hits` findings.
    ///
    /// The pack comes from the TASK, not from the assertion, so the prose the model was
    /// asked to write in and the rules it is graded against cannot drift apart: one pack is
    /// rendered into the system prefix and handed to the checker. A task with no `persona`
    /// fails this assertion with a message saying so rather than passing vacuously.
    StyleClean {
        /// Findings tolerated. `0` — the default — is the useful setting; a non-zero
        /// ceiling is for a task deliberately grading "mostly clean".
        #[serde(default)]
        max_hits: usize,
    },
    /// Every one of these tool names must appear in the transcript's tool calls.
    ToolsInclude { names: Vec<String> },
    /// NONE of these tool names may appear in the transcript's tool calls.
    ToolsExclude { names: Vec<String> },
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
    ///
    /// These are the CLI's names, and they stay the CLI's names: the direct driver maps
    /// them onto its own manifest by the table in `eval/README.md` rather than the suite
    /// carrying two allowlists that could disagree.
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    /// How much the turn is trusted with, for a driver that has levels.
    ///
    /// `None` takes the default from the workspace — `read` for `vault-readonly`, `write`
    /// for `fixture` — which is what the two workspaces already mean. Spelling it out is
    /// for the task that wants LESS than its workspace's default (a refusal task granted
    /// only `read`), and `vault-readonly` + `write` is refused by [`Task::validate`]
    /// alongside the tool allowlist, for the same reason.
    #[serde(default)]
    pub level: Option<Level>,
    /// Extra system-prefix text, as fixture blocks, ahead of the persona.
    ///
    /// The direct driver passes these as [`jesse_agent::SystemBlock`]s. The CLI takes no
    /// system prefix on the flags this harness uses, so its driver prepends the same text
    /// to the prompt — the model sees the same instructions either way, which is what makes
    /// a suite carrying `system` runnable on both drivers.
    #[serde(default)]
    pub system: Vec<String>,
    /// The persona this task's answer is written under AND graded against.
    ///
    /// ONE pack, two uses: the direct driver renders it into the system prefix with
    /// `jesse_agent::render_persona`, and the `style_clean` assertion checks the answer
    /// against the same value. A suite that carried the rendered prose in `system` and the
    /// rules in the assertion would be carrying the same pack twice, in two spellings.
    #[serde(default)]
    pub persona: Option<PersonaPack>,
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

/// The vault working directory: `$JESSE_VAULT` when set, else `~/vault`. Mirrors
/// the bridge's `JESSE_VAULT` resolution so an eval points at the same vault the
/// bridge serves, with no personal absolute path committed (repo guard R5).
pub fn vault_dir() -> PathBuf {
    match std::env::var("JESSE_VAULT") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => home_dir().join("vault"),
    }
}

impl Task {
    /// The comma-joined `--allowedTools` value for this task.
    pub fn allowed_tools_csv(&self) -> String {
        self.allowed_tools.join(",")
    }

    /// The level this task runs at, defaulted from its workspace.
    ///
    /// `write` for a fixture (a hermetic temp dir, which is the point of one) and `read`
    /// for the vault (which is the whole posture of `vault-readonly`). Naming a level in
    /// the task overrides this, EXCEPT that `vault-readonly` + `write` is refused — see
    /// [`Task::validate`].
    pub fn level(&self) -> Level {
        self.level.unwrap_or(match self.workspace {
            Workspace::Fixture => Level::Write,
            Workspace::VaultReadonly => Level::Read,
        })
    }

    /// Load-bearing safety check. A `vault-readonly` task must declare only
    /// read tools and may not ask for `level: write`; any other tool (Write, Edit,
    /// any Bash, …) is refused so an eval run can never modify the vault. Also
    /// requires judged tasks to carry a rubric, and `style_clean` to have a pack to
    /// check against. Returns `Err` with a human-readable reason on any violation.
    pub fn validate(&self) -> Result<(), String> {
        if self.workspace == Workspace::VaultReadonly {
            // THE SAME REFUSAL, ONE RUNG UP. The allowlist below names the CLI's tools; a
            // level names what the DIRECT driver's tool set is built with, and a
            // `vault-readonly` task at `write` would be built with `vault_write` no matter
            // how empty its `allowed_tools` was. Both spellings of "this task may modify
            // the vault" are refused in the same place, before anything runs.
            if self.level == Some(Level::Write) {
                return Err(format!(
                    "task '{}' is vault-readonly but asks for level: write, \
                     which would build a tool set that can modify the vault",
                    self.id
                ));
            }
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
        if self.persona.is_none()
            && self
                .assertions
                .iter()
                .any(|a| matches!(a, Assertion::StyleClean { .. }))
        {
            return Err(format!(
                "task '{}' asserts style_clean but declares no `persona` pack to check against",
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
            level: None,
            system: vec![],
            persona: None,
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
        assert!(
            err.contains("Write"),
            "error should name the offending tool: {err}"
        );
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
    fn vault_refuses_write_level_even_with_an_empty_allowlist() {
        // The allowlist is empty and every tool in it would have been legal — the refusal
        // is the LEVEL, which is what the direct driver builds its tool set from.
        let mut t = task_with(Workspace::VaultReadonly, &[]);
        t.level = Some(Level::Write);
        let err = t.validate().unwrap_err();
        assert!(err.contains("level: write"), "got: {err}");
    }

    #[test]
    fn vault_allows_an_explicit_read_level() {
        let mut t = task_with(Workspace::VaultReadonly, &["Read"]);
        t.level = Some(Level::Read);
        assert!(t.validate().is_ok());
        t.level = Some(Level::Basic);
        assert!(t.validate().is_ok());
    }

    #[test]
    fn the_level_defaults_to_what_the_workspace_means() {
        assert_eq!(task_with(Workspace::Fixture, &[]).level(), Level::Write);
        assert_eq!(
            task_with(Workspace::VaultReadonly, &[]).level(),
            Level::Read
        );
    }

    #[test]
    fn style_clean_without_a_pack_is_refused_at_load() {
        let mut t = task_with(Workspace::Fixture, &[]);
        t.assertions = vec![Assertion::StyleClean { max_hits: 0 }];
        let err = t.validate().unwrap_err();
        assert!(err.contains("persona"), "got: {err}");
        t.persona = Some(PersonaPack::default());
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
