//! The `run` subcommand: execute each task against an endpoint (or a mock),
//! capture metrics, evaluate assertions, and write `results.json` + `scorecard.md`.

use crate::assertions::{eval_all, AssertionResult};
use crate::mock::MockFile;
use crate::suite::{Suite, Task, Workspace};
use crate::transcript::{self, Transcript, Usage};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// Configuration for a run.
pub struct RunConfig {
    pub claude_bin: String,
    /// `ANTHROPIC_BASE_URL` for the child. `None` = ambient (this machine's auth).
    pub endpoint: Option<String>,
    /// `ANTHROPIC_MODEL` for the child. `None` = the endpoint's default model.
    pub model: Option<String>,
    /// `ANTHROPIC_AUTH_TOKEN` for the child. Only used when `endpoint` is set.
    pub auth_token: String,
    /// If set, replay canned NDJSON instead of spawning `claude`.
    pub mock: Option<MockFile>,
    /// Per-task wall-clock timeout.
    pub timeout: Duration,
    pub out_dir: PathBuf,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenRecord {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
}

impl From<&Usage> for TokenRecord {
    fn from(u: &Usage) -> Self {
        TokenRecord {
            input: u.input_tokens,
            output: u.output_tokens,
            cache_read: u.cache_read_input_tokens,
            cache_creation: u.cache_creation_input_tokens,
        }
    }
}

/// One task's full result record (serialized into `results.json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResult {
    pub id: String,
    pub class: String,
    pub workspace: String,
    pub judged: bool,
    pub rubric: Option<String>,
    pub passed: bool,
    pub completed: bool,
    pub wall_ms: u64,
    /// Harness-measured time to first text delta.
    pub measured_ttft_ms: Option<u64>,
    /// Model-reported time to first token (from the result line).
    pub result_ttft_ms: Option<u64>,
    pub tool_calls: u32,
    pub tokens: Option<TokenRecord>,
    pub final_answer: Option<String>,
    pub assertions: Vec<AssertionResult>,
    pub transcript_path: String,
    /// Harness-level error (spawn failure, timeout, mock miss). Not a model miss.
    pub error: Option<String>,
}

/// Top-level `results.json` document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunReport {
    pub suite: String,
    pub endpoint: Option<String>,
    pub model: Option<String>,
    pub mock: bool,
    pub tasks: Vec<TaskResult>,
}

/// Populate a fresh workspace for a fixture task; return the dir to run in.
/// For vault tasks, returns the real vault path and writes nothing.
fn prepare_workspace(
    task: &Task,
    temp_root: &Path,
) -> Result<PathBuf, String> {
    match task.workspace {
        Workspace::VaultReadonly => Ok(crate::suite::vault_dir()),
        Workspace::Fixture => {
            let dir = temp_root.join(&task.id);
            std::fs::create_dir_all(&dir)
                .map_err(|e| format!("could not create fixture dir: {e}"))?;
            for (rel, content) in &task.fixture_files {
                let full = dir.join(rel);
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| format!("could not create {}: {e}", parent.display()))?;
                }
                std::fs::write(&full, content)
                    .map_err(|e| format!("could not write fixture {rel}: {e}"))?;
            }
            Ok(dir)
        }
    }
}

/// Spawn `claude` for one task and stream its stdout, timestamping the first
/// text delta and enforcing the wall-clock timeout.
fn spawn_claude(task: &Task, cwd: &Path, cfg: &RunConfig) -> RawCapture {
    let mut cmd = Command::new(&cfg.claude_bin);
    cmd.arg("-p")
        .arg(&task.prompt)
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
            return RawCapture {
                lines: vec![],
                wall_ms: 0,
                measured_ttft_ms: None,
                ok: false,
                diagnostic: format!("failed to spawn '{}': {e}", cfg.claude_bin),
            }
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
                    if tx.send((reader_start.elapsed().as_millis() as u64, l)).is_err() {
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
            .map(|s| s.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into()))
            .unwrap_or_else(|_| "unknown".into());
        let tail: String = stderr_text.lines().rev().take(8).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
        diagnostic = format!("claude exited {code}; stderr tail:\n{tail}");
    }

    RawCapture {
        lines,
        wall_ms,
        measured_ttft_ms,
        ok,
        diagnostic,
    }
}

/// Replay a canned response for one task in mock mode, writing any side-effect
/// files into the workspace.
fn replay_mock(task: &Task, cwd: &Path, mock: &MockFile) -> RawCapture {
    let start = Instant::now();
    let lines = match mock.lines_for(&task.id) {
        Some(l) => l,
        None => {
            return RawCapture {
                lines: vec![],
                wall_ms: 0,
                measured_ttft_ms: None,
                ok: false,
                diagnostic: format!("no mock response for task '{}'", task.id),
            }
        }
    };
    // Side-effect files stand in for what the model's tools would have written.
    if let Some(resp) = mock.responses.get(&task.id) {
        for (rel, content) in &resp.files {
            let full = cwd.join(rel);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&full, content) {
                return RawCapture {
                    lines: vec![],
                    wall_ms: 0,
                    measured_ttft_ms: None,
                    ok: false,
                    diagnostic: format!("mock could not write {rel}: {e}"),
                };
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
}

/// Run a whole suite. Returns the report (also written to `out_dir`).
pub fn run_suite(suite: &Suite, cfg: &RunConfig) -> Result<RunReport, String> {
    std::fs::create_dir_all(&cfg.out_dir)
        .map_err(|e| format!("could not create out dir: {e}"))?;
    let transcripts_dir = cfg.out_dir.join("transcripts");
    std::fs::create_dir_all(&transcripts_dir)
        .map_err(|e| format!("could not create transcripts dir: {e}"))?;
    let answers_dir = cfg.out_dir.join("answers");
    std::fs::create_dir_all(&answers_dir)
        .map_err(|e| format!("could not create answers dir: {e}"))?;

    // Fixture workspaces live under one temp root for the whole run.
    let temp_root = tempfile::Builder::new()
        .prefix("jesse-eval-")
        .tempdir()
        .map_err(|e| format!("could not create temp root: {e}"))?;

    let mut results = Vec::new();
    for task in &suite.tasks {
        // Load-bearing: refuse a vault task with a non-read tool before running.
        task.validate()?;

        let cwd = prepare_workspace(task, temp_root.path())?;

        let capture = match &cfg.mock {
            Some(m) => replay_mock(task, &cwd, m),
            None => spawn_claude(task, &cwd, cfg),
        };

        // Persist the raw transcript.
        let transcript_rel = format!("transcripts/{}.ndjson", task.id);
        let _ = std::fs::write(cfg.out_dir.join(&transcript_rel), capture.lines.join("\n"));

        let parsed: Transcript = transcript::parse(&capture.lines);

        // Judged tasks: save the final answer as an artifact for `judge`.
        if task.judged {
            if let Some(ans) = &parsed.final_answer {
                let _ = std::fs::write(answers_dir.join(format!("{}.txt", task.id)), ans);
            }
        }

        let (passed, assertion_results) = eval_all(&task.assertions, &parsed, &cwd);
        // A harness error (couldn't even run) is not a legitimate pass.
        let error = if capture.ok {
            None
        } else {
            Some(capture.diagnostic.clone())
        };
        let passed = passed && error.is_none();

        results.push(TaskResult {
            id: task.id.clone(),
            class: task.class.clone(),
            workspace: format!("{:?}", task.workspace).to_lowercase(),
            judged: task.judged,
            rubric: task.rubric.clone(),
            passed,
            completed: parsed.completed,
            wall_ms: capture.wall_ms,
            measured_ttft_ms: capture.measured_ttft_ms,
            result_ttft_ms: parsed.result_ttft_ms,
            tool_calls: parsed.tool_calls,
            tokens: parsed.usage.as_ref().map(TokenRecord::from),
            final_answer: parsed.final_answer.clone(),
            assertions: assertion_results,
            transcript_path: transcript_rel,
            error,
        });
    }

    let report = RunReport {
        suite: suite.name.clone(),
        endpoint: cfg.endpoint.clone(),
        model: cfg.model.clone(),
        mock: cfg.mock.is_some(),
        tasks: results,
    };

    std::fs::write(
        cfg.out_dir.join("results.json"),
        serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("could not write results.json: {e}"))?;

    std::fs::write(cfg.out_dir.join("scorecard.md"), scorecard(&report))
        .map_err(|e| format!("could not write scorecard.md: {e}"))?;

    Ok(report)
}

/// Render the per-class + totals scorecard.
pub fn scorecard(report: &RunReport) -> String {
    struct Agg {
        n: u32,
        passed: u32,
        latency_sum: u64,
        tool_sum: u64,
    }
    let mut by_class: BTreeMap<String, Agg> = BTreeMap::new();
    let mut total = Agg {
        n: 0,
        passed: 0,
        latency_sum: 0,
        tool_sum: 0,
    };
    for t in &report.tasks {
        let a = by_class.entry(t.class.clone()).or_insert(Agg {
            n: 0,
            passed: 0,
            latency_sum: 0,
            tool_sum: 0,
        });
        for agg in [a, &mut total] {
            agg.n += 1;
            if t.passed {
                agg.passed += 1;
            }
            agg.latency_sum += t.wall_ms;
            agg.tool_sum += t.tool_calls as u64;
        }
    }

    let mut out = String::new();
    out.push_str(&format!("# Scorecard — {}\n\n", report.suite));
    let target = match (&report.endpoint, &report.model) {
        (Some(e), Some(m)) => format!("endpoint `{e}`, model `{m}`"),
        (Some(e), None) => format!("endpoint `{e}`, default model"),
        (None, _) if report.mock => "mock (canned NDJSON)".to_string(),
        (None, _) => "ambient auth + default model".to_string(),
    };
    out.push_str(&format!("Target: {target}\n\n"));
    out.push_str("| Class | Pass rate | Mean latency | Mean tool calls |\n");
    out.push_str("|---|---|---|---|\n");
    for (class, a) in &by_class {
        out.push_str(&format!(
            "| {} | {}/{} ({:.0}%) | {} ms | {:.1} |\n",
            class,
            a.passed,
            a.n,
            100.0 * a.passed as f64 / a.n as f64,
            a.latency_sum / a.n as u64,
            a.tool_sum as f64 / a.n as f64,
        ));
    }
    if total.n > 0 {
        out.push_str(&format!(
            "| **TOTAL** | **{}/{} ({:.0}%)** | **{} ms** | **{:.1}** |\n",
            total.passed,
            total.n,
            100.0 * total.passed as f64 / total.n as f64,
            total.latency_sum / total.n as u64,
            total.tool_sum as f64 / total.n as f64,
        ));
    }
    out
}
