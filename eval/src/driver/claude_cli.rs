//! **The `claude-cli` driver** — `claude -p` as a child process.
//!
//! MOVED, NOT REWRITTEN. The spawn, the flags, the stderr drain, the per-line arrival
//! timestamps, the timeout, the mock replay and the diagnostics are the code that was in
//! `runner.rs` before the driver seam existed, and `eval/tests/integration.rs` proves it by
//! passing unedited.
//!
//! The one ADDITION is `system`: the flags this harness uses give `claude` no system prefix,
//! so a task carrying `system` blocks has them prepended to the prompt, separated by a blank
//! line. A task without `system` — which is every task in every suite that shipped before
//! D7 — produces a byte-identical invocation to the one this code always made.

use super::{BoxFuture, Driver, PreparedWorkspace, TaskRun};
use crate::mock::MockFile;
use crate::suite::Task;
use crate::transcript;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

/// Runs each task by spawning the `claude` CLI.
pub struct ClaudeCliDriver {
    pub claude_bin: String,
    /// `ANTHROPIC_BASE_URL` for the child. `None` = ambient (this machine's auth).
    pub endpoint: Option<String>,
    /// `ANTHROPIC_MODEL` for the child. `None` = the endpoint's default model.
    pub model: Option<String>,
    /// `ANTHROPIC_AUTH_TOKEN` for the child. Only used when `endpoint` is set.
    pub auth_token: String,
    /// If set, replay canned NDJSON instead of spawning `claude`.
    ///
    /// **THE MOCK BELONGS TO THE DRIVER**, not to the harness. It fakes what a CLI child
    /// would have printed, which is a statement about this driver's child and about nothing
    /// else; the direct driver's mock is a different file in a different format for exactly
    /// that reason.
    pub mock: Option<MockFile>,
    /// Per-task wall-clock timeout.
    pub timeout: Duration,
}

impl Driver for ClaudeCliDriver {
    fn id(&self) -> &'static str {
        "claude-cli"
    }

    fn endpoint(&self) -> Option<String> {
        self.endpoint.clone()
    }

    fn model(&self) -> Option<String> {
        self.model.clone()
    }

    fn is_mock(&self) -> bool {
        self.mock.is_some()
    }

    fn run_task<'a>(
        &'a self,
        task: &'a Task,
        workspace: &'a PreparedWorkspace,
        _cancel: CancellationToken,
    ) -> BoxFuture<'a, TaskRun> {
        Box::pin(async move {
            match &self.mock {
                Some(m) => replay_mock(task, &workspace.dir, m),
                None => spawn_claude(task, &workspace.dir, self),
            }
        })
    }
}

/// The prompt as the child receives it: the system blocks, then the task's prompt.
///
/// A task with no `system` gets its prompt back unchanged, which is what keeps every
/// pre-D7 suite's invocation byte-identical.
fn prompt_for(task: &Task) -> String {
    if task.system.is_empty() {
        return task.prompt.clone();
    }
    let mut out = task.system.join("\n\n");
    out.push_str("\n\n");
    out.push_str(&task.prompt);
    out
}

/// Raw output of one task's execution, before parsing.
struct RawCapture {
    lines: Vec<String>,
    wall_ms: u64,
    /// Harness-measured time to first streamed text delta.
    measured_ttft_ms: Option<u64>,
    /// The child exited cleanly (or, in mock mode, always true).
    ok: bool,
    /// Diagnostic detail (stderr tail, timeout note) — empty on success.
    diagnostic: String,
}

impl From<RawCapture> for TaskRun {
    fn from(c: RawCapture) -> TaskRun {
        let mut run = TaskRun::from_lines(c.lines, c.wall_ms, c.measured_ttft_ms);
        if !c.ok {
            run.error = Some(c.diagnostic);
        }
        run
    }
}

/// Spawn `claude` for one task and stream its stdout, timestamping the first
/// text delta and enforcing the wall-clock timeout.
fn spawn_claude(task: &Task, cwd: &Path, cfg: &ClaudeCliDriver) -> TaskRun {
    let mut cmd = Command::new(&cfg.claude_bin);
    cmd.arg("-p")
        .arg(prompt_for(task))
        .arg("--output-format")
        .arg("stream-json")
        .arg("--verbose")
        .arg("--include-partial-messages")
        .arg("--permission-mode")
        .arg("default")
        .arg("--allowedTools")
        .arg(task.allowed_tools_csv())
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Env overrides live ON THE CHILD ONLY — never on the harness process.
    if let Some(ep) = &cfg.endpoint {
        cmd.env("ANTHROPIC_BASE_URL", ep);
        cmd.env("ANTHROPIC_AUTH_TOKEN", &cfg.auth_token);
    }
    if let Some(m) = &cfg.model {
        cmd.env("ANTHROPIC_MODEL", m);
    }

    let start = Instant::now();
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return TaskRun::failed(format!("failed to spawn '{}': {e}", cfg.claude_bin));
        }
    };

    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");

    // Drain stderr on its own thread so a chatty child can't deadlock the pipe.
    let err_handle = thread::spawn(move || {
        let mut s = String::new();
        let _ = BufReader::new(stderr).read_to_string(&mut s);
        s
    });

    // Read stdout on its own thread, tagging each line with its arrival time.
    let (tx, rx) = mpsc::channel::<(u64, String)>();
    let reader_start = start;
    let out_handle = thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            match line {
                Ok(l) => {
                    if tx
                        .send((reader_start.elapsed().as_millis() as u64, l))
                        .is_err()
                    {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let mut lines = Vec::new();
    let mut measured_ttft_ms = None;
    let mut timed_out = false;
    loop {
        let remaining = match cfg.timeout.checked_sub(start.elapsed()) {
            Some(r) => r,
            None => {
                timed_out = true;
                break;
            }
        };
        match rx.recv_timeout(remaining) {
            Ok((ms, line)) => {
                if measured_ttft_ms.is_none() && transcript::is_text_delta(&line) {
                    measured_ttft_ms = Some(ms);
                }
                lines.push(line);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                timed_out = true;
                break;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break, // reader finished
        }
    }

    if timed_out {
        let _ = child.kill();
    }
    let status = child.wait();
    let _ = out_handle.join();
    let stderr_text = err_handle.join().unwrap_or_default();
    let wall_ms = start.elapsed().as_millis() as u64;

    let ok = !timed_out && status.as_ref().map(|s| s.success()).unwrap_or(false);
    let mut diagnostic = String::new();
    if timed_out {
        diagnostic = format!("timed out after {}s", cfg.timeout.as_secs());
    } else if !ok {
        let code = status
            .map(|s| {
                s.code()
                    .map(|c| c.to_string())
                    .unwrap_or_else(|| "signal".into())
            })
            .unwrap_or_else(|_| "unknown".into());
        let tail: String = stderr_text
            .lines()
            .rev()
            .take(8)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join("\n");
        diagnostic = format!("claude exited {code}; stderr tail:\n{tail}");
    }

    RawCapture {
        lines,
        wall_ms,
        measured_ttft_ms,
        ok,
        diagnostic,
    }
    .into()
}

/// Replay a canned response for one task in mock mode, writing any side-effect
/// files into the workspace.
fn replay_mock(task: &Task, cwd: &Path, mock: &MockFile) -> TaskRun {
    let start = Instant::now();
    let lines = match mock.lines_for(&task.id) {
        Some(l) => l,
        None => return TaskRun::failed(format!("no mock response for task '{}'", task.id)),
    };
    // Side-effect files stand in for what the model's tools would have written.
    if let Some(resp) = mock.responses.get(&task.id) {
        for (rel, content) in &resp.files {
            let full = cwd.join(rel);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&full, content) {
                return TaskRun::failed(format!("mock could not write {rel}: {e}"));
            }
        }
    }
    let measured_ttft_ms = lines
        .iter()
        .position(|l| transcript::is_text_delta(l))
        .map(|_| start.elapsed().as_millis() as u64);
    RawCapture {
        lines,
        wall_ms: start.elapsed().as_millis() as u64,
        measured_ttft_ms,
        ok: true,
        diagnostic: String::new(),
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::suite::{Suite, Workspace};

    fn task(system: &[&str]) -> Task {
        let suite = Suite::from_json(
            serde_json::json!({
                "name": "t",
                "tasks": [{
                    "id": "t", "class": "c", "prompt": "the prompt",
                    "workspace": "fixture",
                    "system": system,
                    "assertions": []
                }]
            })
            .to_string()
            .as_bytes(),
        )
        .expect("parses");
        assert_eq!(suite.tasks[0].workspace, Workspace::Fixture);
        suite.tasks[0].clone()
    }

    #[test]
    fn a_task_without_system_hands_the_prompt_over_unchanged() {
        assert_eq!(prompt_for(&task(&[])), "the prompt");
    }

    #[test]
    fn system_blocks_are_prepended_in_order() {
        assert_eq!(
            prompt_for(&task(&["first", "second"])),
            "first\n\nsecond\n\nthe prompt"
        );
    }
}
