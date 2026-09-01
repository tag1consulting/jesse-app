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
//!
//! **D11 changed the invocation twice, and both changes are load-bearing.**
//!
//! *The persona* (F2). A task carrying a `persona` pack now has it rendered by the SAME
//! [`render_persona`] the direct driver calls, on the same wire, and handed to the child as
//! `--append-system-prompt`. Before this the pack was never read here at all: the CLI child
//! was graded by `style_clean` against rules it had never been shown, while the direct model
//! had been. That is a structural bias in the direct driver's favour on every
//! `style-adherence` task, and it is why D9's baseline scored 0/3 there.
//!
//! *The empty MCP world* (F3). The spawn passes `--strict-mcp-config` with an explicit empty
//! `--mcp-config`, so the child sees ZERO MCP servers whatever the host's user settings
//! define. Before this a `product-v1` baseline score depended on which machine ran it: in
//! D9 the child asked for permission to use a note-search MCP tool the suite never granted
//! and produced no answer at all, and another task's answer volunteered a fact about the
//! host's real document collection. Runs from before D11 are therefore not comparable with
//! runs after it; `eval/README.md` says so beside the tracked artifacts.

use super::{BoxFuture, Driver, PreparedWorkspace, TaskRun};
use crate::mock::MockFile;
use crate::suite::Task;
use crate::transcript;
use jesse_agent::{SystemBlock, Wire};
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

/// The child's MCP world: nothing.
///
/// An inline JSON config declaring no servers, paired with `--strict-mcp-config` so the CLI
/// uses ONLY this and ignores every other MCP configuration it would otherwise find. Both
/// halves are needed: the strict flag on its own has no config to be strict about.
const EMPTY_MCP_CONFIG: &str = r#"{"mcpServers":{}}"#;

/// [`SystemBlock`]s as one string, blocks separated by a blank line.
///
/// This is the join [`jesse_agent::render_persona`] documents as producing byte-identical
/// text on all three wires, which is what lets one `--append-system-prompt` string stand in
/// for the direct driver's block list.
fn join_blocks(blocks: &[SystemBlock]) -> String {
    blocks
        .iter()
        .map(|b| b.text.as_str())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// The persona text this driver prepends for `task`, or `None` when the task names no pack.
///
/// ONE PACK, ONE RENDERER, ONE WIRE. The direct driver renders the task's pack with
/// [`jesse_agent::render_persona`]; so does this, on [`Wire::Messages`] — the wire this path
/// actually runs on — and the result is handed to the child verbatim. A task with no pack
/// gets nothing appended, which keeps every pre-D7 suite's invocation unchanged.
fn persona_prefix(task: &Task) -> Option<String> {
    task.persona
        .as_ref()
        .map(|pack| join_blocks(&super::direct::persona_blocks(pack, Wire::Messages)))
}

/// The child's full argument vector, as a pure function of the task.
///
/// Extracted from the spawn so a test can assert what the child is actually given —
/// D11's F3 was a missing pair of flags that nothing in the suite could have caught.
/// `--allowedTools` stays LAST because its value is variadic: anything placed after it
/// would have to start with `--` to avoid being swallowed as another tool name.
fn argv_for(task: &Task) -> Vec<String> {
    let mut argv: Vec<String> = vec![
        "-p".into(),
        prompt_for(task),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        "--include-partial-messages".into(),
        "--permission-mode".into(),
        "default".into(),
        "--mcp-config".into(),
        EMPTY_MCP_CONFIG.into(),
        "--strict-mcp-config".into(),
    ];
    if let Some(prefix) = persona_prefix(task) {
        argv.push("--append-system-prompt".into());
        argv.push(prefix);
    }
    argv.push("--allowedTools".into());
    argv.push(task.allowed_tools_csv());
    argv
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
    cmd.args(argv_for(task))
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
        task_json(serde_json::json!({
            "id": "t", "class": "c", "prompt": "the prompt",
            "workspace": "fixture",
            "system": system,
            "assertions": []
        }))
    }

    /// One task, loaded through the real suite parser so the `persona` field under test is
    /// the one a shipped suite would produce.
    fn task_json(t: serde_json::Value) -> Task {
        let suite = Suite::from_json(
            serde_json::json!({"name": "t", "tasks": [t]})
                .to_string()
                .as_bytes(),
        )
        .expect("parses");
        assert_eq!(suite.tasks[0].workspace, Workspace::Fixture);
        suite.tasks[0].clone()
    }

    /// A task carrying a pack shaped like `product-v1`'s `style-adherence` tasks.
    fn styled_task() -> Task {
        task_json(serde_json::json!({
            "id": "st", "class": "style-adherence", "prompt": "the prompt",
            "workspace": "fixture",
            "allowed_tools": ["Read", "Grep"],
            "assertions": [{"type": "style_clean"}],
            "persona": {
                "languages": ["en"],
                "banned_patterns": ["\\bdelve\\b"],
                "free_text": "Write the way I would write it: plain sentences, no filler.",
                "assistant": {"name": "Jesse"},
                "owner": {"name": "Alex", "pronoun": "their", "address_style": "by_name"},
                "style": {"verbosity": "terse", "emoji": "never"},
                "formatting": {"lists": "avoid", "headings": "avoid", "dashes": "forbidden"}
            }
        }))
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

    // ---- F2: one pack, both drivers -------------------------------------------------

    /// THE BYTE-IDENTITY CLAIM, asserted rather than documented.
    ///
    /// `eval/README.md` promises the task's pack is rendered into the system prefix by BOTH
    /// drivers so the rules an answer is written under and the rules it is graded against
    /// cannot drift. Before D11 that sentence was false here. This compares the exact string
    /// this driver hands the child with the exact bytes the direct driver prepends, for the
    /// same pack, on every wire the direct driver can run — `render_persona`'s own contract
    /// is that the joined text does not vary by wire, so any wire the direct run picks
    /// produces the same prefix this one sends.
    #[test]
    fn both_drivers_prepend_the_same_persona_bytes() {
        let t = styled_task();
        let pack = t.persona.clone().expect("the task carries a pack");
        let cli = persona_prefix(&t).expect("a task with a pack gets a prefix");
        assert!(!cli.is_empty(), "an empty prefix would pass vacuously");
        for wire in [Wire::Messages, Wire::Chat, Wire::Responses] {
            let direct = join_blocks(&super::super::direct::persona_blocks(&pack, wire));
            assert_eq!(
                cli, direct,
                "the two drivers must prepend the same bytes on {wire:?}"
            );
        }
    }

    #[test]
    fn the_persona_reaches_the_child_as_append_system_prompt() {
        let argv = argv_for(&styled_task());
        let i = argv
            .iter()
            .position(|a| a == "--append-system-prompt")
            .expect("the flag is on the argv");
        let sent = &argv[i + 1];
        assert_eq!(
            sent,
            &persona_prefix(&styled_task()).unwrap(),
            "the flag's value is the rendered pack, verbatim"
        );
        assert!(sent.contains("Jesse"), "identity section reached the child");
    }

    #[test]
    fn a_task_with_no_pack_appends_no_system_prompt() {
        // Every suite that shipped before D7 is in this case, and its invocation must not
        // change: no pack, no flag, no new bytes.
        let argv = argv_for(&task(&[]));
        assert!(
            !argv.iter().any(|a| a == "--append-system-prompt"),
            "{argv:?}"
        );
    }

    // ---- F3: an empty MCP world, structurally ---------------------------------------

    /// THE ARGV PROOF. The child is given an explicit empty server set AND told to use only
    /// it, so the host's user settings cannot bleed in. Both flags, adjacent, with the
    /// config's value between them, and `--allowedTools` still last so its variadic value
    /// swallows nothing.
    #[test]
    fn the_child_is_spawned_with_an_empty_strict_mcp_world() {
        let argv = argv_for(&task(&[]));
        let i = argv
            .iter()
            .position(|a| a == "--mcp-config")
            .expect("--mcp-config is on the argv");
        assert_eq!(argv[i + 1], EMPTY_MCP_CONFIG);
        assert_eq!(argv[i + 2], "--strict-mcp-config");

        let parsed: serde_json::Value = serde_json::from_str(EMPTY_MCP_CONFIG).unwrap();
        assert!(
            parsed["mcpServers"].as_object().unwrap().is_empty(),
            "the config must declare no servers at all"
        );
        assert_eq!(
            argv[argv.len() - 2],
            "--allowedTools",
            "the variadic flag stays last: {argv:?}"
        );
    }

    #[test]
    fn the_prompt_is_still_the_first_thing_the_child_is_given() {
        let argv = argv_for(&task(&["first"]));
        assert_eq!(argv[0], "-p");
        assert_eq!(argv[1], "first\n\nthe prompt");
    }
}
