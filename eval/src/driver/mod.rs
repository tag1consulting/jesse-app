//! **The driver seam** — what actually runs a task.
//!
//! Everything else in this harness is driver-independent and stays that way: a suite is a
//! list of tasks, a workspace is a directory, an assertion reads a [`Transcript`] and a
//! file, the scorecard aggregates results and `judge` compares two answers. The only thing
//! that knows how a task is EXECUTED is a [`Driver`], and there are two of them:
//!
//! | Driver | `--driver` | What it runs |
//! |---|---|---|
//! | [`ClaudeCliDriver`] | `claude-cli` (default) | `claude -p` as a child process, exactly as before this seam existed. |
//! | [`DirectDriver`] | `direct` | `jesse_agent::run_turn` in this process, over the vault tool set. |
//!
//! **WHY A SEAM AND NOT A SECOND HARNESS.** The suites, the assertions, the scorecard and
//! the judge are the reusable asset here; the runner is the replaceable part. A second
//! binary for the owned loop would have meant two copies of every suite and a comparison
//! nobody could trust, because "the direct loop scores 14/17" only means something against
//! the same seventeen tasks scored by the same engine.
//!
//! **THE CLI DRIVER IS A MOVE, NOT A REWRITE.** Its code, its flags, its `--mock` format
//! and its transcript parsing are what they were; `eval/tests/integration.rs` proves it
//! without being edited for the move.
//!
//! ---- ONE TRANSCRIPT MODEL ---------------------------------------------------
//!
//! Both drivers produce [`crate::transcript::Transcript`], and both produce it the same
//! way: NDJSON lines in the CLI's stream-json shape, run through
//! [`crate::transcript::parse`]. The direct driver does not have such lines to begin with —
//! it renders them from the loop's tool trace and outcome — and doing it that way rather
//! than filling the struct in by hand buys a real property: the transcript persisted to
//! `<out>/transcripts/<id>.ndjson` reparses to exactly the transcript that was scored.

pub mod claude_cli;
pub mod direct;

use crate::suite::{Task, Workspace};
use crate::transcript::{Transcript, Usage};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use tokio_util::sync::CancellationToken;

pub use claude_cli::ClaudeCliDriver;
pub use direct::DirectDriver;

/// A future returned by a `dyn`-dispatched driver method.
///
/// The trait method is spelled `-> BoxFuture<…>` rather than `async fn` for one reason: a
/// trait with an `async fn` is not object safe, and the whole point of this trait is that
/// `--driver` picks one at runtime. This is the same shape `jesse_agent::provider` uses for
/// the same reason.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;

/// A task's workspace, prepared and located.
///
/// The suite's [`Workspace`] says WHICH KIND; this says which kind and WHERE, because a
/// driver needs the directory and a `vault-readonly` driver needs to know that is what it
/// is looking at.
#[derive(Debug, Clone)]
pub struct PreparedWorkspace {
    pub kind: Workspace,
    pub dir: PathBuf,
}

/// Everything one task's execution produced, before assertions.
///
/// `error` is not in the design note's field list and is here anyway: a harness failure (a
/// child that would not spawn, a fixture with no script for this task, a level the driver
/// refuses) is not a model miss, and folding it into "no answer" would score it as one. The
/// runner reads it and refuses to record a pass.
pub struct TaskRun {
    /// The normalised transcript — the same model for every driver.
    pub transcript: Transcript,
    /// The final answer, or empty when there was none.
    pub answer: String,
    /// Token usage, or the zero vector when the driver reported none.
    pub usage: Usage,
    pub wall_ms: u64,
    /// Harness-measured time to the first visible text.
    pub ttft_ms: Option<u64>,
    pub tool_calls: usize,
    pub tool_names: Vec<String>,
    pub completed: bool,
    /// The raw transcript lines, persisted verbatim to `<out>/transcripts/<id>.ndjson`.
    pub lines: Vec<String>,
    /// A harness error. `None` on a clean run, whatever the model said.
    pub error: Option<String>,
}

impl TaskRun {
    /// A run that never happened, carrying the reason.
    pub fn failed(reason: impl Into<String>) -> TaskRun {
        TaskRun {
            transcript: Transcript::default(),
            answer: String::new(),
            usage: Usage::default(),
            wall_ms: 0,
            ttft_ms: None,
            tool_calls: 0,
            tool_names: Vec::new(),
            completed: false,
            lines: Vec::new(),
            error: Some(reason.into()),
        }
    }

    /// Build a run from its raw lines by PARSING them, so what is scored is what is stored.
    pub fn from_lines(lines: Vec<String>, wall_ms: u64, ttft_ms: Option<u64>) -> TaskRun {
        let transcript = crate::transcript::parse(&lines);
        TaskRun {
            answer: transcript.final_answer.clone().unwrap_or_default(),
            usage: transcript.usage.clone().unwrap_or_default(),
            tool_calls: transcript.tool_calls as usize,
            tool_names: transcript.tool_names.clone(),
            completed: transcript.completed,
            transcript,
            wall_ms,
            ttft_ms,
            lines,
            error: None,
        }
    }
}

/// How a task is executed.
pub trait Driver {
    /// The driver's id, as `--driver` spells it and as `results.json` records it.
    fn id(&self) -> &'static str;

    /// The endpoint this driver targets, for the scorecard header. Never a token.
    fn endpoint(&self) -> Option<String> {
        None
    }

    /// The wire, for the scorecard header. `None` for a driver that has no wire of its own
    /// — the CLI child picks its own, and reporting a guess would be worse than reporting
    /// nothing.
    fn wire(&self) -> Option<String> {
        None
    }

    /// The model, for the scorecard header.
    fn model(&self) -> Option<String> {
        None
    }

    /// Whether this run is replaying a fixture rather than calling anything.
    fn is_mock(&self) -> bool;

    /// Run one task in an already-prepared workspace.
    ///
    /// Returns a [`TaskRun`] rather than a `Result` for the same reason the agent loop
    /// returns a `TurnOutcome`: a failed task still has a wall time, a transcript and a
    /// reason, and every one of those belongs in the results file.
    fn run_task<'a>(
        &'a self,
        task: &'a Task,
        workspace: &'a PreparedWorkspace,
        cancel: CancellationToken,
    ) -> BoxFuture<'a, TaskRun>;
}
