use crate::*;

// ---- The Claude Code harness ------------------------------------------------
//
// Everything specific to speaking with the `claude` CLI: the argument vectors, the
// containment flags a [`Capability`] maps to, the per-role env overrides, and the
// `stream-json` line parsing. Moved here verbatim from `claude.rs`, which keeps the parts
// that are NOT specific to Claude Code — the outcome vocabulary and the driver.
//
// The five spawn sites (main turn writes-on, main turn read-only, the vault-QA child, the
// diet children, the title one-shot) all funnel through [`ClaudeCode::command`], so their
// exact argv is stated once and pinned by `golden_argv_for_every_capability_call_site`.

/// The Claude Code harness: headless `claude -p --output-format stream-json` against the
/// vault. A unit struct — it holds no state, because it is a shared registry singleton
/// serving concurrent turns (per-turn state lives in [`ClaudeCodeParser`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClaudeCode;

impl ClaudeCode {
    /// Build one child `Command`: the least-privilege args ([`build_claude_args`]), the
    /// call site's cwd, piped stdio, `kill_on_drop`, and the active model's backend env
    /// ([`apply_main_env`], a NO-OP for the ambient default). INFALLIBLE — the CLI
    /// expresses every request shape the bridge makes, which is why nothing on this path
    /// constructs a [`HarnessError`]; [`Harness::build_turn`] just wraps this in `Ok`.
    ///
    /// It sets no other environment: the child inherits the bridge's process env unchanged.
    /// A per-ROLE override (title / diet / vault-QA / shadow) is layered by the caller on
    /// top, and a main turn never layers one — that is the isolation guarantee, proven by
    /// dedicated tests.
    pub fn command(&self, cfg: &Config, req: &TurnRequest<'_>) -> Command {
        let mut cmd = Command::new(&cfg.claude_bin);
        // The write lock's hooks, when this turn is one that can write the vault. A failure to
        // WRITE the settings file leaves `None`, and the caller's own gate (a turn is only
        // given `write_lock` when the broker is armed) means the turn then runs at one slot
        // rather than unlocked — see `install_write_lock_settings`.
        let settings = req
            .write_lock
            .and_then(|wl| install_write_lock_settings(cfg, wl));
        cmd.args(build_claude_args(
            cfg,
            req.prompt,
            req.session_id,
            req.capability,
            req.mcp_config,
            settings.as_deref(),
            req.attachment_dir,
        ))
        .current_dir(&req.cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true); // killed if the timeout fires or the task is dropped
        apply_main_env(&mut cmd, req.active);
        cmd
    }
}

impl Harness for ClaudeCode {
    fn id(&self) -> &'static str {
        CLAUDE_CODE_ID
    }

    /// True: with `--include-partial-messages` the visible answer arrives as token-level
    /// `text_delta`s, which is what the driver's streamed-text fallback rests on.
    fn streams_text(&self) -> bool {
        true
    }

    /// TRUE AT EVERY LEVEL. Claude Code's boundary is a named tool allowlist with path
    /// scopes, so each of the three is a posture it genuinely has and they are genuinely
    /// distinct: `Basic` is `--tools ""` (no toolset at all at the root), `Read` is a
    /// read-only root allowlist with `Read(./**)` scoping, `Write` is the configured lists
    /// with the full built-in toolset standing. "No tools at all" is a state this harness can
    /// be put in, which is what makes `Basic` real here and unreachable on Codex.
    fn expresses(&self, _capability: Capability) -> bool {
        true
    }

    /// THREE. Claude Code is the harness the bridge has run since the beginning, it installs
    /// the write-lock hooks, and it backs the ambient `opus` default every main turn uses.
    fn default_concurrency(&self) -> usize {
        3
    }

    /// TRUE. Verified live against claude 2.1.222: `PreToolUse` and `PostToolUse` both fire in
    /// a headless `-p` child under `--permission-mode default`, and a pre hook exiting 2 BLOCKS
    /// the tool call — the write never lands, the model reads the hook's stderr and reacts, and
    /// the denial is recorded in the result envelope's `permission_denials`. That last part is
    /// what makes the compare-and-swap refusal a recoverable outcome rather than a crash.
    fn supports_write_lock(&self) -> bool {
        true
    }

    /// Claude Code names its target directly: `tool_input.file_path`, already ABSOLUTE.
    ///
    /// The contrast with Codex is the whole reason this is a trait method — see
    /// [`Harness::hook_write_target`].
    fn hook_write_target(&self, payload: &HookPayload) -> WriteTarget {
        match payload.tool_name.as_str() {
            "Write" | "Edit" | "NotebookEdit" => payload
                .tool_input
                .get("file_path")
                .and_then(|v| v.as_str())
                .map(|p| WriteTarget::Path(resolve_lock_path(Path::new(p), &payload.cwd)))
                // A write tool whose payload carries no path is not a write we can name, and
                // "cannot name" means lock everything, never lock nothing.
                .unwrap_or(WriteTarget::Global),
            // A shell call gets a COMMAND STRING, not a path. Redirection, `sed -i`, `tee` and
            // the vault's own hooks all write through here, and parsing a conservative
            // allowlist of shapes out of a command string is precise and leaky. One global
            // lock is imprecise and sound.
            "Bash" | "BashOutput" | "KillShell" => WriteTarget::Global,
            // Everything the read-only matcher lets through, plus the MCP sets, which this
            // project records as read-only in its containment battery.
            "Read" | "Grep" | "Glob" | "WebFetch" | "WebSearch" | "TodoWrite" => WriteTarget::None,
            other if other.starts_with("mcp__") => WriteTarget::None,
            _ => WriteTarget::Global,
        }
    }

    /// `Read` names the file whose content becomes this conversation's compare-and-swap
    /// baseline. A file read through the SHELL (`cat`) records nothing — the named hole.
    fn hook_read_target(&self, payload: &HookPayload) -> Option<PathBuf> {
        (payload.tool_name == "Read")
            .then(|| payload.tool_input.get("file_path")?.as_str())
            .flatten()
            .map(|p| resolve_lock_path(Path::new(p), &payload.cwd))
    }

    fn capability_args(&self, cfg: &Config, capability: Capability) -> Vec<String> {
        claude_capability_args(cfg, capability)
    }

    /// qmd PLUS the self-hosted read-only Slack server.
    fn main_mcp_config(&self) -> &'static str {
        MAIN_CHILD_MCP_CONFIG
    }

    fn shipped_rows(&self) -> &'static [ContainmentRow] {
        &CLAUDE_CODE_SHIPPED_ROWS
    }

    /// `~/.claude/projects/<escaped-vault>` — the layout the session code used to hardcode.
    fn transcript_dir(&self, cfg: &Config) -> Option<PathBuf> {
        Some(vault_sessions_dir(&cfg.home, &cfg.vault))
    }

    fn build_turn(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        Ok(self.command(cfg, req))
    }

    fn attachment_support(&self) -> &'static AttachmentSupport {
        &CLAUDE_CODE_ATTACHMENTS
    }

    fn parser(&self) -> Box<dyn TurnParser> {
        Box::new(ClaudeCodeParser)
    }
}

/// Claude Code's per-turn parser: a STATELESS wrapper around [`parse_stream_line`], because
/// its terminal `result` line carries the answer, the session id and the usage all at once
/// — nothing has to be accumulated across lines to emit a complete `Done`. A harness whose
/// outcome IS assembled across lines keeps that state in its own parser; the driver makes a
/// fresh one per spawn attempt either way.
pub struct ClaudeCodeParser;

impl TurnParser for ClaudeCodeParser {
    fn on_line(&mut self, line: &str) -> StreamEvent {
        parse_stream_line(line)
    }
}

// ---- The five call sites' requests ------------------------------------------
//
// The cwd and MCP server set each site chose are stated ONCE here, so the runtime path
// (which goes through `Harness::build_turn`) and the named builders below (which the
// containment tests pin) can never drift apart. They live with this harness because the
// server set is expressed in the CLI's own `--mcp-config` format.

/// The MAIN turn's request: the vault as cwd (so `CLAUDE.md` auto-loads), the qmd-only MCP
/// set, the capability the active model's write permission implies, and `--resume` when the
/// caller resolved a session to continue.
pub fn main_turn_request<'a>(
    cfg: &'a Config,
    prompt: &'a str,
    session_id: Option<&'a str>,
    active: &'a ActiveModel,
    capability: Capability,
    mcp_config: &'a str,
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id,
        active,
        capability,
        cwd: PathBuf::from(&cfg.vault), // cwd = vault → CLAUDE.md auto-loads
        mcp_config,
        // Callers that CAN write the vault set this after the fact (`req.write_lock =
        // Some(&wl)`), so the common request builder stays a five-argument function.
        write_lock: None,
        // Set after the fact by the driver too, and for the same reason: only the handler
        // that decoded the attachments knows whether this turn has any and where they went.
        attachment_dir: None,
    }
}

// ---- `stream-json` parsing --------------------------------------------------

/// Classify a parsed terminal `result` object into the bridge's Ok/Retryable/Fatal outcome
/// — the single place that decides what a finished `claude` turn amounts to. Shared by
/// [`interpret_claude_output`] (whole-buffer `json` mode) and [`parse_stream_line`] (the
/// terminal `result` line of `stream-json` mode), so both modes classify identically. `raw`
/// is the original text to fall back to as the answer when a success envelope somehow lacks
/// a `result` field (only meaningful for the buffered path; `None` in streaming).
pub fn classify_result_value(v: &Value, raw: Option<&str>) -> ClaudeOutcome {
    let is_error = v.get("is_error").and_then(|e| e.as_bool()).unwrap_or(false);
    if is_error {
        let status = v.get("api_error_status").and_then(|s| s.as_u64());
        // `result` holds the human-readable cause; synthesize one if absent.
        let message = v
            .get("result")
            .and_then(|r| r.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| match status {
                Some(code) => format!("claude API error (status {code})"),
                None => "claude reported an error with no detail".to_string(),
            });
        return match status {
            // 5xx and 429 are transient upstream conditions (529 is >= 500).
            Some(code) if code >= 500 || code == 429 => ClaudeOutcome::Retryable {
                message,
                status: code,
            },
            _ => ClaudeOutcome::Fatal { message },
        };
    }
    // Success envelope — same extraction the bridge has always done.
    let result = v
        .get("result")
        .and_then(|r| r.as_str())
        .or(raw)
        .unwrap_or("")
        .trim()
        .to_string();
    let session_id = v
        .get("session_id")
        .and_then(|s| s.as_str())
        .map(|s| s.to_string());
    // The terminal `result` line carries a `usage` object on a successful turn; parse it
    // for the per-turn cost badge. A missing/oddly-shaped object → empty usage (cost $0),
    // never an error — the answer is authoritative regardless of whether usage parsed.
    let usage = v
        .get("usage")
        .and_then(|u| serde_json::from_value::<ShadowUsage>(u.clone()).ok())
        .unwrap_or_default();
    ClaudeOutcome::Ok {
        result,
        session_id,
        usage,
    }
}

/// Map a single NDJSON line from `stream-json` to a [`StreamEvent`]. Non-JSON or
/// unrecognized lines are `Ignore`d (the terminal classification still comes from the
/// `result` line, or from the no-result fallback if it never arrives). A pure mapping (no
/// I/O) so it's unit-testable against captured fixtures. See `bridge/README.md` for the
/// verified event schema.
pub fn parse_stream_line(line: &str) -> StreamEvent {
    let line = line.trim();
    if line.is_empty() {
        return StreamEvent::Ignore;
    }
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return StreamEvent::Ignore;
    };
    match v.get("type").and_then(|t| t.as_str()) {
        // The one terminal line — feeds the existing Ok/Retryable/Fatal logic.
        Some("result") => StreamEvent::Done(classify_result_value(&v, None)),
        // The `init` event, first line of the stream, carrying the session id this turn
        // runs under. It is the authoritative answer to "which session does this turn
        // belong to" and replaces inferring it from a directory diff. Any other `system`
        // subtype (`status`, …) carries nothing.
        Some("system") if v.get("subtype").and_then(|s| s.as_str()) == Some("init") => v
            .get("session_id")
            .and_then(|s| s.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|s| StreamEvent::SessionId(s.to_string()))
            .unwrap_or(StreamEvent::Ignore),
        // Token-level events (emitted under --include-partial-messages). The
        // visible answer streams as `text_delta`s inside a `text` content block;
        // tool use announces itself with a `tool_use` content-block start.
        Some("stream_event") => {
            let event = v.get("event");
            match event.and_then(|e| e.get("type")).and_then(|t| t.as_str()) {
                Some("content_block_delta") => {
                    let delta = event.and_then(|e| e.get("delta"));
                    let is_text = delta.and_then(|d| d.get("type")).and_then(|t| t.as_str())
                        == Some("text_delta");
                    match delta.and_then(|d| d.get("text")).and_then(|t| t.as_str()) {
                        Some(text) if is_text => StreamEvent::TextDelta(text.to_string()),
                        _ => StreamEvent::Ignore, // thinking/signature/input deltas
                    }
                }
                Some("content_block_start") => {
                    let block = event.and_then(|e| e.get("content_block"));
                    let is_tool = block.and_then(|b| b.get("type")).and_then(|t| t.as_str())
                        == Some("tool_use");
                    match block.and_then(|b| b.get("name")).and_then(|n| n.as_str()) {
                        // Never `refused`: Claude Code's boundary is a tool ALLOWLIST, so a
                        // call it will not permit produces no `tool_use` block to start.
                        // There is nothing here to mark refused, which is the difference
                        // from Codex — see `Harness::classify_stderr_line`.
                        Some(name) if is_tool => {
                            StreamEvent::ToolActivity(ToolActivity::used(name))
                        }
                        _ => StreamEvent::Ignore,
                    }
                }
                _ => StreamEvent::Ignore,
            }
        }
        _ => StreamEvent::Ignore,
    }
}

/// Interpret one `claude -p --output-format json` run. `claude` can exit non-zero while
/// still writing a JSON envelope whose `is_error` / `api_error_status` carry the real cause
/// (e.g. a transient upstream 500), so parse stdout regardless of exit status and key off
/// that — falling back to exit status + stderr only when stdout isn't JSON.
///
/// Still reached from the driver's `resolve_stream_outcome`, which uses it for the
/// no-`result`-line-and-no-text case so that genuine failure keeps carrying the child's
/// stderr verbatim.
///
/// `harness` NAMES THE CHILD THAT ACTUALLY FAILED and is threaded in rather than hardcoded,
/// because that shared driver path reaches this for EVERY harness. With the label baked in,
/// a Codex child that died on a clap usage error reported "claude failed" next to a `codex
/// exec resume` usage string, and the operator could not tell whether the app had silently
/// switched models. Pass the caller's own `Harness::id`.
///
/// The label is presentation ONLY. `failclass::classify_hosted_failure` keys on the stderr
/// and stdout content carried in this message and never on the harness word, so renaming a
/// harness cannot change how its failures are classified or retried.
pub fn interpret_claude_output(
    harness: &str,
    stdout: &str,
    stderr: &str,
    exit_success: bool,
) -> ClaudeOutcome {
    if let Ok(v) = serde_json::from_str::<Value>(stdout) {
        // The parsed envelope is the `result` object; classify it the one way,
        // shared with the streaming parser's terminal `result` line.
        return classify_result_value(&v, Some(stdout));
    }

    // stdout wasn't JSON. On a clean exit, treat it as the raw answer (the
    // bridge's long-standing fallback). On a failure, surface stderr AND stdout
    // so a non-JSON failure is never reported blank again.
    if exit_success {
        ClaudeOutcome::Ok {
            result: stdout.trim().to_string(),
            session_id: None,
            usage: ShadowUsage::default(),
        }
    } else {
        let err = truncate_chars(stderr.trim(), 500);
        let out = truncate_chars(stdout.trim(), 500);
        ClaudeOutcome::Fatal {
            message: format!("{harness} failed (no JSON envelope) — stderr: {err} | stdout: {out}"),
        }
    }
}

// ---- MCP server sets --------------------------------------------------------

/// The MCP server set for a MAIN turn, used when `JESSE_MAIN_MCP_CONFIG` is unset:
/// exactly the **qmd** vault-search server and nothing else. Passed as `--mcp-config`
/// alongside `--strict-mcp-config`, so the account-level cloud connectors (Gmail,
/// Slack, Google Calendar, Google Drive) and `playwright` are never LOADED on a phone
/// turn rather than merely refused at the permission layer.
///
/// `"command": "qmd"` is resolved from the child's `PATH`, mirroring how `claude_bin`
/// defaults to the bare name `"claude"` with the absolute path supplied by env
/// (`JESSE_CLAUDE_BIN`) in production. If `qmd` is not on the bridge's `PATH`, set
/// `JESSE_MAIN_MCP_CONFIG` to a config naming the absolute interpreter + script path;
/// no user-specific path is baked into this source.
///
/// qmd and slack are declared. `playwright` is deliberately EXCLUDED: no main-path feature
/// references it (verified — zero references under `bridge/` and zero in the vault's
/// `CLAUDE.md` / skills), and it is the exact server a prior "fetch" probe drove to a
/// live network fetch out of a child that was supposed to be contained.
///
/// `slack` is a SELF-HOSTED read-only Slack server (npm `slack-mcp-server`), not the
/// account-level claude.ai Slack connector — that one is still never loaded. It is declared
/// here rather than supplied through `JESSE_MAIN_MCP_CONFIG` on purpose: the containment
/// battery probes the SHIPPED consts, so a server reached only through the env override
/// would be granted in the allowlist but never exercised by any probe. Its token arrives
/// separately, by environment inheritance (`SLACK_MCP_XOXP_TOKEN`), so no secret is baked
/// in here. `SLACK_MCP_ADD_MESSAGE_TOOL` and its siblings are deliberately never set:
/// without them the server does not even register `conversations_add_message`.
pub const MAIN_CHILD_MCP_CONFIG: &str = r#"{"mcpServers":{"qmd":{"type":"stdio","command":"qmd","args":["mcp"]},"slack":{"type":"stdio","command":"npx","args":["-y","slack-mcp-server@latest","--transport","stdio"]}}}"#;

/// The qmd server ALONE — the main turn's server set before slack was added (bridge 0.57.0).
/// No shipped spawn site uses it today; it is retained because [`McpSet::Qmd`] still names a
/// posture a deployment can express, and because dropping it would silently re-point that
/// label at a set containing slack.
pub const QMD_ONLY_MCP_CONFIG: &str =
    r#"{"mcpServers":{"qmd":{"type":"stdio","command":"qmd","args":["mcp"]}}}"#;

/// An EMPTY MCP server set, passed as `--mcp-config` alongside `--strict-mcp-config` so
/// the child loads NO MCP servers at all. `--strict-mcp-config` tells the CLI to use only
/// servers declared here; this declares none — so every `mcp__*` tool, and anything
/// `ToolSearch` could load from a server, is absent at the root rather than denied by
/// name. (The vulnerability report saw a "fetch" probe reach
/// `mcp__playwright__browser_navigate` and make a live network fetch under the old
/// posture; strict empty MCP closes that at the source.)
pub const EMPTY_MCP_CONFIG: &str = r#"{"mcpServers":{}}"#;

/// The ROOT MCP boundary every spawn site carries: load ONLY the servers named in
/// `config`. Deliberately separate from [`Harness::capability_args`] — the server set is a per
/// call site choice, not something a capability implies (see [`TurnRequest::mcp_config`]).
/// The main turn REQUIRES qmd ([`MAIN_CHILD_MCP_CONFIG`]) while the vault-QA child degrades
/// to no servers ([`EMPTY_MCP_CONFIG`]), and folding that into `Read` would silently take
/// vault search away from a read-only turn.
///
/// `--mcp-config` accepts a file PATH or inline JSON, so an env override supplies either
/// and the fallback consts are inline JSON. Live-verified on claude 2.1.220 (2026-07-27):
/// without `--strict-mcp-config` the CLI also discovers the ambient user/project scopes,
/// and an MCP tool that IS in `--allowedTools` is approved automatically while the same
/// tool omitted fails with "requested permissions … but you haven't granted it yet" —
/// refused-at-the-prompt, which is a weaker boundary than never loaded.
pub fn mcp_args(config: &str) -> Vec<String> {
    vec![
        "--strict-mcp-config".to_string(),
        "--mcp-config".to_string(),
        config.to_string(),
    ]
}

/// The MCP server set for a MAIN turn (and the title one-shot, which shares its builder):
/// `JESSE_MAIN_MCP_CONFIG` when set, else **the spawning harness's own** shipped set —
/// qmd+slack for Claude Code, qmd alone for Codex. It takes the harness rather than
/// reaching for a single global const precisely so that adding a server to one harness
/// cannot silently change another's posture; see [`Harness::main_mcp_config`].
pub fn main_mcp_config<'a>(cfg: &'a Config, harness: &dyn Harness) -> &'a str {
    cfg.main_mcp_config
        .as_deref()
        .unwrap_or_else(|| harness.main_mcp_config())
}

/// The MCP server set for the vault-QA child (and the shadow child, which shares its
/// builder): `JESSE_VAULTQA_MCP_CONFIG` when set, else NO servers.
pub fn vaultqa_mcp_config(cfg: &Config) -> &str {
    cfg.vaultqa_mcp_config.as_deref().unwrap_or(EMPTY_MCP_CONFIG)
}

// ---- Capability → containment flags -----------------------------------------

/// The ROOT toolset (`--tools`) for a [`Capability::Read`] child: exactly the three
/// read-only built-ins — file read and the two search tools. Nothing that can write,
/// execute, or reach the network exists at the root, so those classes are absent rather
/// than permission-gated.
///
/// TOOL NAMES ONLY, no path scope. `--tools` decides which tools EXIST at the root; the
/// path boundary is expressed in the `--allowedTools` grant below, which is where the CLI
/// reads a scope from. Writing `Read(./**)` here would name no known tool.
pub const READ_ROOT_TOOLS: &str = "Read,Grep,Glob";

/// The `--allowedTools` grant for a [`Capability::Read`] child: the three read-only
/// built-ins, PATH-SCOPED to the child's working directory, plus the four read-only qmd
/// MCP search tools (present only when the site's MCP config supplies the qmd server;
/// absent otherwise, and then simply never invoked). The web fetch and web search tools are
/// deliberately NOT granted here — widening the read surface to the network is a separate
/// decision with a security consequence.
///
/// The `(./**)` scope is the same boundary, and the same hand-checked mechanism, as the
/// writes-on allowlist's — see [`DEFAULT_ALLOWED_TOOLS`] for why it is relative and why
/// `Grep` and `Glob` are scoped alongside `Read`. It matters MORE here than at `Write`:
/// both `Read` rows back children that run unattended (the vault-QA child, the shadow
/// child), and an unscoped read there reaches every file the bridge user can read.
/// Both sites that spawn a `Read` child run it in the vault, so `./**` IS the vault.
pub const READ_ALLOWED_TOOLS: &str = "Read(./**),Grep(./**),Glob(./**),\
mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status";

/// Tools DENIED to EVERY [`Capability::Read`] child as belt-and-suspenders BEHIND the real
/// boundary (the [`READ_ROOT_TOOLS`] root allowlist + strict MCP). It names every mutation
/// / execution / network / orchestration class so a CLI change that widened the root set
/// would still hit the denylist. `Skill` is named because a skill loads instruction text
/// whose actions write (the `diet-logging` skill is exactly that). Enumerated denial is
/// fragile by nature — it breaks SILENTLY on a tool rename or addition, exactly as
/// [`BASIC_DISALLOWED_TOOLS`] documents — so the root allowlist is the guarantee and this
/// is defense-in-depth.
///
/// # This tightens the vault-QA child, and why the variance had to go
///
/// The read-only main turn already denied `Skill`; the vault-QA (and shadow) child did
/// not. That difference was undocumented and had no reason behind it — the two sites
/// arrived at their lists separately, and the child's simply predated the main turn's. A
/// capability that means two different things at two call sites is not a boundary, it is a
/// coincidence, so both now take the stricter list.
///
/// What it actually changes for the child is defense-in-depth only, and saying otherwise
/// would overstate it: behind `--tools "Read,Grep,Glob"` the `Skill` tool does not exist
/// at the root either way, so the child could not have loaded a skill before this change
/// and cannot now. Live-probed on claude 2.1.220 rather than assumed. The value is that
/// the denylist now survives a CLI change that widened the root set, at BOTH Read sites
/// rather than one.
pub const READ_DISALLOWED_TOOLS: &str =
    "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite,Skill";

/// Tools DENIED to a [`Capability::Basic`] child, as belt-and-suspenders BEHIND the real
/// boundary (`--tools ""`, see [`Harness::capability_args`]). Beyond the mutation / execution /
/// network classes it also names the read/search built-ins and the orchestration tools
/// that an empty-`--allowedTools` posture left reachable: `Glob`, `Grep`, `Read`,
/// `ToolSearch`, `Workflow`, `Agent`, `TodoWrite`, plus `Skill` (loads skill instruction
/// text). `WebSearch` is here too.
///
/// KNOWN WEAKNESS — enumerated denial is fragile: it names tools, so it breaks SILENTLY
/// whenever the CLI renames a tool, splits one, or adds a new one. The live proof of that
/// fragility is right here — the vulnerability report's list also named `LS` and
/// `NotebookRead`, but claude 2.1.207 has no such tools (verified: it warns `Permission
/// deny rule "LS" matches no known tool`; directory listing and notebook reads fold into
/// `Glob`/`Read`, which ARE denied). Naming a phantom tool is a no-op that also spams
/// stderr on every child, so they are omitted here. Because this list cannot be trusted
/// to stay complete across CLI versions, the actual guarantee is `--tools ""` (removes
/// the whole built-in toolset at the root) + strict empty MCP, and the acceptance gate is
/// the live probe battery re-run against the pinned CLI on every change to this posture.
pub const BASIC_DISALLOWED_TOOLS: &str =
    "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Glob,Grep,Read,ToolSearch,Workflow,Agent,TodoWrite,Skill";

/// Map a [`Capability`] to CLAUDE CODE's toolset argument vector. Reached through
/// [`Harness::capability_args`], which is how every consumer asks — a free function here and
/// [`codex_capability_args`] there, each a pure statement of one harness's flags that can be
/// unit-tested without a registry. The MCP server set ([`mcp_args`]), the working directory,
/// and any env override stay with the caller.
///
/// This argv is host-independent as written: every path scope is cwd-relative (`Read(./**)`),
/// so no [`WORKSPACE_TOKEN`] appears in it. That is a property of Claude Code's scopes, not a
/// rule this function follows — the rule is that a host-varying scope must be tokenised, and
/// this harness happens to have none.
///
/// # Why these exact flags
///
/// [`Capability::Basic`] does not mean "empty `--allowedTools`". Live validation against
/// the pinned CLI (claude 2.1.207) on 2026-07-13 DISPROVED that assumption: an empty
/// `--allowedTools` means "add nothing to the default set", not "allow nothing". A
/// headless `-p` child still reached read/search built-ins (a "run ls" probe executed
/// `Glob`), loaded MCP servers on demand via `ToolSearch` (a "fetch" probe drove
/// `mcp__playwright__browser_navigate` to a live network fetch), and reached `Workflow` —
/// none of which raise the permission prompt a headless child cannot answer. Only `Write`
/// was actually contained. So the boundary is built at the ROOT, deny-by-default, not by
/// enumeration: `--tools ""` disables the ENTIRE built-in toolset (control-tested:
/// dropping it alone lets the "run ls" probe execute `Glob` again), with an empty
/// `--allowedTools` and [`BASIC_DISALLOWED_TOOLS`] as belt-and-suspenders behind it.
///
/// [`Capability::Read`] is the same shape with a read-only root ALLOWLIST
/// ([`READ_ROOT_TOOLS`]) instead of an empty root set, the [`READ_ALLOWED_TOOLS`] grant,
/// and the read denylist behind it.
///
/// [`Capability::Write`] passes the configured `--allowedTools` / `--disallowedTools` and
/// NO root `--tools` flag, which is exactly today's writes-on main-turn posture.
///
/// Rejected alternatives (for `Basic`, and by extension `Read`):
///   * Enumerated denylist only — rejected: it breaks silently on any CLI tool
///     rename/addition, and this very CLI already omits `LS`/`NotebookRead` from its tool
///     namespace, so a name-based list cannot be trusted to stay complete. `--tools`
///     sidesteps the namespace entirely.
///   * `--bare` / `--safe-mode` — rejected: both alter auth resolution (`--bare` forces
///     `ANTHROPIC_API_KEY`/`apiKeyHelper` and never reads OAuth/keychain), which would
///     break the ambient-credential verify child. Containment must not change which
///     backend a child talks to.
///   * A single-turn cap for defense-in-depth — UNAVAILABLE: claude 2.1.207 exposes no
///     `--max-turns` flag (verified via `--help`). The children are single-shot by
///     construction, but the CLI offers no turn bound to enforce it. (`--max-budget-usd`
///     exists but bounds cost, not agentic turns, and is not a containment control.)
pub fn claude_capability_args(cfg: &Config, capability: Capability) -> Vec<String> {
    match capability {
        Capability::Basic => vec![
            // ROOT boundary: disable the entire built-in toolset (deny-by-default).
            "--tools".to_string(),
            String::new(),
            // Belt-and-suspenders behind the root flag above and strict MCP.
            "--allowedTools".to_string(),
            String::new(),
            "--disallowedTools".to_string(),
            BASIC_DISALLOWED_TOOLS.to_string(),
        ],
        Capability::Read => vec![
            // ROOT boundary: a read-only root allowlist (not an empty set) — the child
            // may read, nothing more.
            "--tools".to_string(),
            READ_ROOT_TOOLS.to_string(),
            "--allowedTools".to_string(),
            READ_ALLOWED_TOOLS.to_string(),
            "--disallowedTools".to_string(),
            READ_DISALLOWED_TOOLS.to_string(),
        ],
        Capability::Write => {
            // Today's exact writes-on posture: the configured lists, and NO root
            // `--tools` flag (so the full built-in toolset stands at the root).
            let mut args = vec!["--allowedTools".to_string(), cfg.allowed_tools.clone()];
            if !cfg.disallowed_tools.trim().is_empty() {
                args.push("--disallowedTools".to_string());
                args.push(cfg.disallowed_tools.clone());
            }
            args
        }
    }
}

/// WHAT CLAUDE CODE'S `Read` TOOL TAKES, measured against claude 2.1.223 with the file in
/// an `--add-dir` directory. Each type was handed over and the model asked to report what it
/// saw; every one below came back as content, not as bytes:
///
/// * `png`, `jpg`, `gif` — transcribed the text printed in the image exactly.
/// * `webp` — described a photograph correctly (a pink water lily on still water).
/// * `pdf` — reported the page's text, and reached for `Read` UNPROMPTED to do it.
///
/// `heic` is deliberately ABSENT: a `.heic` holding valid image bytes came back as raw
/// binary rather than as an image, silently, with no permission denial involved. The bridge
/// transcodes it to JPEG before the path is named.
///
/// The instruction names `Read` and says no shell is needed. The measured behaviour on this
/// version was already to use `Read` for a PDF unprompted — the earlier note that an
/// unprompted PDF went to `Bash` did not reproduce on 2.1.223, in two samples. The sentence
/// stays because it is one clause, because the allowlist refuses every `pdftotext`-shaped
/// command it could otherwise try, and because saying so costs nothing on a turn that was
/// going to do the right thing anyway.
pub static CLAUDE_CODE_ATTACHMENTS: AttachmentSupport = AttachmentSupport {
    native: &["png", "jpg", "gif", "webp", "pdf"],
    instruction: "read them with the Read tool as needed to answer. The Read tool takes \
                  images and PDFs directly; no shell command is needed and none will work.",
};

// ---- Argument vectors --------------------------------------------------------

/// Build the argument vector for one `claude` invocation (everything after the
/// binary name). Pure and side-effect-free so it can be unit-tested without
/// spawning a process. Enforces the C1 least-privilege boundary:
///   * `--permission-mode default` (never `acceptEdits`/`bypassPermissions`)
///   * an explicit `--allowedTools` list (always present)
///   * a `--disallowedTools` denylist as defense-in-depth
///   * `--strict-mcp-config` + an explicit `--mcp-config` (always present) so ONLY the
///     servers named there load — see [`mcp_args`] and [`MAIN_CHILD_MCP_CONFIG`]
///
/// A `session_id` adds `--resume <id>` to continue a thread. An `attachment_dir` adds
/// `--add-dir` for that one directory, so this turn's attachments are inside the child's
/// read scope; see the comment at the push site for what that grant does and does not
/// confer. Both are `None` on an ordinary turn, which is then byte-identical to before.
///
/// `capability` names what this child is granted and [`Harness::capability_args`] turns it into
/// the toolset flags; `mcp_config` names the servers it may load. A main turn derives its
/// capability from the active model via [`turn_capability`] and passes
/// [`main_mcp_config`]; the title one-shot passes its own. The boundary is the TOOLSET,
/// not the prompt.
pub fn build_claude_args(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
    capability: Capability,
    mcp_config: &str,
    write_lock_settings: Option<&Path>,
    attachment_dir: Option<&Path>,
) -> Vec<String> {
    let mut args = vec![
        "-p".to_string(),
        prompt.to_string(),
        // Stream the turn as NDJSON so the bridge can read tokens as they arrive
        // and forward them live. `--verbose` is REQUIRED by `claude` whenever
        // `-p`/`--print` is combined with `--output-format stream-json` (it errors
        // out otherwise). `--include-partial-messages` upgrades the stream from
        // whole-message events to token-level `text_delta`s for true live output.
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
        // Default permission mode: tools are gated by the allow/deny lists
        // below rather than auto-accepted. Never acceptEdits/bypassPermissions.
        "--permission-mode".to_string(),
        "default".to_string(),
        // SETTINGS SCOPES: user + project, never `local`. `--settings` (below) is ADDITIVE to
        // these rather than a replacement — verified against claude 2.1.222 by running a
        // project-scope hook and a `--settings` hook together and observing BOTH fire — which
        // is what lets the bridge install its write-lock hooks without displacing the vault's
        // own diet-regeneration and draft-guard hooks.
        //
        // The child's cwd is the vault, so Claude Code performs settings discovery there and
        // ANY permission entry it finds is a grant the containment record and the startup
        // gate cannot see. On 2026-08-05 the battery — once its probe world was made faithful
        // — caught `.claude/settings.local.json` granting `Read(//Users/user/**)` (the
        // operator's whole home, redacted here to the documented placeholder), which
        // let a `read`-level child read the agent-credential decoy and session transcripts in
        // the real home. That file also carried arbitrary-execution grants
        // (`Bash(/opt/homebrew/bin/node *)`, `Bash(env -i … sh -c ' *)`, `Bash(brew install *)`).
        //
        // `local` is excluded because it is the untracked, personal, fast-growing scope — the
        // one a desktop session appends to with "yes, don't ask again" and nobody reviews.
        // `project` is KEPT because the vault's `settings.json` carries the diet-regeneration
        // and draft-guard hooks, which earn their keep daily and are not permission grants.
        // Verified against claude 2.1.222 that the split works: with `user,project` a
        // project-scope grant still applies and a local-scope grant is refused.
        //
        // This is a floor, not the boundary: `project` can still grant, which is why its
        // `permissions` block is asserted empty at startup (see `settings_permission_drift`).
        "--setting-sources".to_string(),
        "user,project".to_string(),
    ];
    // THIS TURN'S ATTACHMENT DIRECTORY, and only when this turn has one.
    //
    // WHY IT IS NEEDED. The allowlist scopes reads to `Read(./**)` — cwd-relative, and the
    // cwd is the vault — while attachments are written under the system temp dir by
    // `ScratchDir`. So the path the prompt tells the model to read is outside the only
    // directory the model may read, the Read call becomes a permission REQUEST, and a
    // headless `-p` child has nobody to answer it. Verified against claude 2.1.223: the
    // denial lands in the result envelope's `permission_denials` naming the Read call, and
    // the model narrates "I can't read that path" — Jeremy's report exactly.
    //
    // WHAT THE FLAG DOES AND DOES NOT DO, both re-verified on 2.1.223:
    //   * It grants READS inside this one directory, for this one turn. It confers NO
    //     write: with `Write(./**)` allowed and the directory added, a write INTO the added
    //     directory was still refused (denial recorded, file never created).
    //   * Its scope holds. A file sitting BESIDE the added directory was still refused.
    // It is a per-turn read grant over a directory that exists for seconds and is removed
    // by `ScratchDir`'s `Drop`, not a standing widening of the allowlist.
    //
    // BOTH SYMLINK SPELLINGS. On macOS `std::env::temp_dir()` yields `/var/folders/…`, whose
    // realpath is `/private/var/folders/…`, and the failing turn shows the model trying
    // both. 2.1.223 resolves symlinks when matching, so either spelling alone was enough in
    // both directions when measured — but the flag is variadic and a second value is free,
    // so both are passed rather than resting the fix on a matching rule that is not part of
    // the CLI's contract.
    //
    // IT GOES HERE, NOT IN `claude_capability_args`. `validate_toolset_argv` compares a
    // harness's `capability_args` against the recorded `toolset_args` by STRICT EQUALITY, so
    // a per-turn absolute host path in there would fail the startup gate on every machine
    // except the one that recorded it. Emitted here, no containment record moves on either
    // harness. Placed before `--settings`/`--mcp-config` so a FLAG always follows it and its
    // variadic argument list can never swallow the next value.
    if let Some(dir) = attachment_dir {
        args.push("--add-dir".to_string());
        args.push(dir.display().to_string());
        // The realpath too, when it differs — see the symlink note above.
        if let Ok(real) = dir.canonicalize() {
            if real != dir {
                args.push(real.display().to_string());
            }
        }
    }
    // THE VAULT WRITE LOCK'S HOOKS, on a write-capable turn only.
    //
    // A bridge-OWNED settings file, outside the vault, rather than hooks added to the vault's
    // own `.claude/settings.json`. The deciding argument is self-disarming: the vault's
    // settings file lives inside the tree a write-level child can edit, so a child could
    // switch off the very hook that locks it. This file is in the state dir, which no child
    // can reach. It is the same reasoning 0.58.0 used to drop the `local` scope, one step on.
    if let Some(path) = write_lock_settings {
        args.push("--settings".to_string());
        args.push(path.display().to_string());
    }
    // ROOT MCP boundary, then the capability's toolset. Every spawn site assembles in
    // this order, which is what lets one builder serve all of them.
    args.extend(mcp_args(mcp_config));
    args.extend(claude_capability_args(cfg, capability));
    if let Some(sid) = session_id {
        // A synthetic `local-<hex>` id (context carry) names a bridge-minted ledger
        // thread with NO real claude session, so it must NEVER be resumed — the CLI
        // would error on an unknown session id. The hosted turn runs FRESH; on success
        // the caller re-keys the ledger from the synthetic id to the real returned id
        // and injects the catch-up block so the missed turns are not lost. A no-op for
        // every real id (and when carry is off, no synthetic id ever exists).
        if !is_synthetic_session_id(sid) {
            args.push("--resume".to_string());
            args.push(sid.to_string());
        }
    }
    args
}

/// Write this turn's bridge-owned settings file, carrying only the write-lock hooks, and
/// return its path.
///
/// One file per TURN, under `<state_dir>/claude-settings/`, removed when the turn ends. It
/// lives in the state dir for the reason given at the `--settings` push site: a file inside
/// the vault is a file a write-level child can edit, and a lock a child can switch off is not
/// a lock.
///
/// `None` on any IO failure, which drops the `--settings` flag. That degradation is safe
/// because of where the decision is made rather than anything here: a turn is only handed a
/// [`WriteLockChild`] when the broker is armed, and a model whose harness cannot lock is
/// already capped at one write-level slot — so a turn that fails to install its hooks runs
/// alone, not unlocked.
///
/// The matchers are the two halves of the mechanism. `PreToolUse` covers the tools that WRITE
/// (plus `Bash`, which writes through a command string this cannot parse); `PostToolUse` adds
/// `Read`, whose only job is to record the compare-and-swap baseline.
pub fn install_write_lock_settings(cfg: &Config, wl: &WriteLockChild) -> Option<PathBuf> {
    let dir = cfg.state_dir.as_deref().map(PathBuf::from)?.join("claude-settings");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{}.json", wl.turn));
    let doc = json!({
        "hooks": {
            "PreToolUse": [{
                "matcher": "Write|Edit|NotebookEdit|Bash",
                "hooks": [{ "type": "command", "command": wl.command(CLAUDE_CODE_ID, "pre") }],
            }],
            "PostToolUse": [{
                "matcher": "Write|Edit|NotebookEdit|Bash|Read",
                "hooks": [{ "type": "command", "command": wl.command(CLAUDE_CODE_ID, "post") }],
            }],
        }
    });
    std::fs::write(&path, serde_json::to_vec_pretty(&doc).ok()?).ok()?;
    Some(path)
}

/// Remove one turn's settings file. Best-effort: a leftover file is inert (it names a turn
/// that no longer exists), so a failure here is not worth failing a turn over.
pub fn remove_write_lock_settings(cfg: &Config, turn: &str) {
    if let Some(dir) = cfg.state_dir.as_deref() {
        let _ = std::fs::remove_file(PathBuf::from(dir).join("claude-settings").join(format!("{turn}.json")));
    }
}

/// Build the base `claude` child `Command` for a MAIN turn or a title one-shot. A thin
/// name over [`ClaudeCode::command`] with [`main_turn_request`], kept because the
/// containment and isolation tests are written against it.
pub fn build_claude_command(
    cfg: &Config,
    prompt: &str,
    session_id: Option<&str>,
    active: &ActiveModel,
    capability: Capability,
    mcp_config: &str,
) -> Command {
    ClaudeCode.command(
        cfg,
        &main_turn_request(cfg, prompt, session_id, active, capability, mcp_config),
    )
}

/// Build the base `Command` for a stateless diet CHILD (extract or verify): the same
/// `stream-json` + `--permission-mode default` posture as every other child, contained at
/// [`Capability::Basic`] with NO MCP servers — the extract and verify children are
/// single-shot, text-in / JSON-text-out, so they are granted nothing. Why `Basic` is built
/// the way it is (and what live validation disproved) is documented on [`Harness::capability_args`];
/// why the cwd is the neutral scratch base is on [`diet_child_request`]. Sets NO env
/// overrides (callers layer `apply_diet_env` for extract, nothing for the ambient verify).
pub fn build_diet_child_command(cfg: &Config, prompt: &str) -> Command {
    let ambient = ActiveModel::ambient();
    ClaudeCode.command(cfg, &diet_child_request(cfg, prompt, &ambient))
}

/// Build the base `Command` for the stateless, READ-ONLY vault-QA child: contained at
/// [`Capability::Read`] with the child's own MCP server set, in the vault. The child can
/// read the vault and answer a self-referential question from it but cannot write, execute,
/// or reach the network; the read-only root allowlist plus strict MCP are the boundary (see
/// [`Harness::capability_args`] and [`vaultqa_child_request`]). Sets NO env override (the caller
/// layers `apply_vaultqa_env`), and never passes `--resume`.
pub fn build_vaultqa_child_command(cfg: &Config, prompt: &str) -> Command {
    let ambient = ActiveModel::ambient();
    ClaudeCode.command(cfg, &vaultqa_child_request(cfg, prompt, &ambient))
}

// ---- Per-role backend env ----------------------------------------------------

/// Layer the ACTIVE model's backend onto the MAIN turn's `Command` — the global model
/// switch. For a non-ambient model it sets `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
/// / `ANTHROPIC_MODEL` so the main turn talks to that backend, AND
/// `CLAUDE_CODE_SUBAGENT_MODEL` to the same model id so the subagents the turn spawns
/// follow the switch too. For the ambient `opus` default (`active.env` is `None`) it is a
/// NO-OP: the main turn inherits the ambient process env unchanged — the isolation
/// property. Unlike `apply_title_env` / `apply_diet_env` / `apply_vaultqa_env` (which
/// carry a per-ROLE backend), this carries the CONVERSATION's chosen model; the two
/// never mix (a main turn never calls the role appliers, and vice versa).
pub fn apply_main_env(cmd: &mut Command, active: &ActiveModel) {
    if let Some((base_url, auth_token, model)) = &active.env {
        cmd.env("ANTHROPIC_BASE_URL", base_url)
            .env("ANTHROPIC_AUTH_TOKEN", auth_token)
            .env("ANTHROPIC_MODEL", model);
        if let Some(subagent) = &active.subagent_model {
            cmd.env("CLAUDE_CODE_SUBAGENT_MODEL", subagent);
        }
    }
}

/// Layer a ROUTED job's chosen backend onto its child `Command`.
///
/// One applier for all four routed jobs (title, diet extract, diet verify, vault QA),
/// replacing the three per-role ones that each read a different `JESSE_<ROLE>_*` triple
/// from config. The triple now comes from the routing rule's pick, so which model serves a
/// job is one ordered list rather than four independent env-var sets.
///
/// A no-op for an AMBIENT pick (`backend` is `None`): the child then inherits the bridge's
/// process env byte-for-byte, exactly what each role call site did when its override was
/// unset. Call this ONLY on a routed-job path — a main turn uses [`apply_main_env`] with the
/// conversation's model, and the two must never mix.
pub fn apply_routed_env(cmd: &mut Command, pick: &RoutedPick) {
    if let Some((base_url, auth_token, model)) = &pick.backend {
        cmd.env("ANTHROPIC_BASE_URL", base_url)
            .env("ANTHROPIC_AUTH_TOKEN", auth_token)
            .env("ANTHROPIC_MODEL", model);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn interpret_real_500_envelope_is_retryable() {
        // The observed cold-start failure: non-zero exit, real cause in stdout.
        let stdout = r#"{"type":"result","is_error":true,"api_error_status":500,"result":"API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment.","session_id":"sess-x"}"#;
        match interpret_claude_output(CLAUDE_CODE_ID, stdout, "", false) {
            ClaudeOutcome::Retryable { status, message } => {
                assert_eq!(status, 500);
                assert!(message.contains("500"));
            }
            other => panic!("expected Retryable, got {other:?}"),
        }
    }
    #[test]
    fn interpret_400_envelope_is_fatal() {
        let stdout = r#"{"is_error":true,"api_error_status":400,"result":"bad request"}"#;
        match interpret_claude_output(CLAUDE_CODE_ID, stdout, "", false) {
            ClaudeOutcome::Fatal { message } => assert!(message.contains("bad request")),
            other => panic!("expected Fatal, got {other:?}"),
        }
    }
    #[test]
    fn interpret_success_envelope_is_ok() {
        let stdout = r#"{"type":"result","is_error":false,"result":"OK","session_id":"sess-1"}"#;
        match interpret_claude_output(CLAUDE_CODE_ID, stdout, "", true) {
            ClaudeOutcome::Ok {
                result, session_id, ..
            } => {
                assert_eq!(result, "OK");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
            }
            other => panic!("expected Ok, got {other:?}"),
        }
    }
    #[test]
    fn interpret_non_json_success_is_raw_ok() {
        match interpret_claude_output(CLAUDE_CODE_ID, "  just plain text  ", "", true) {
            ClaudeOutcome::Ok {
                result, session_id, ..
            } => {
                assert_eq!(result, "just plain text");
                assert!(session_id.is_none());
            }
            other => panic!("expected Ok, got {other:?}"),
        }
    }
    #[test]
    fn interpret_non_json_failure_is_fatal_and_nonblank() {
        // The old bug: a non-JSON failure reported nothing. Now both streams show.
        match interpret_claude_output(CLAUDE_CODE_ID, "partial stdout", "stderr detail", false) {
            ClaudeOutcome::Fatal { message } => {
                assert!(!message.is_empty());
                assert!(message.contains("stderr detail"));
                assert!(message.contains("partial stdout"));
            }
            other => panic!("expected Fatal, got {other:?}"),
        }
    }
    #[test]
    fn parse_text_delta_is_extracted() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}},"session_id":"s"}"#;
        match parse_stream_line(line) {
            StreamEvent::TextDelta(t) => assert_eq!(t, "Hello "),
            other => panic!("expected TextDelta, got {other:?}"),
        }
    }
    #[test]
    fn parse_thinking_delta_is_ignored() {
        // Thinking streams as `thinking_delta`/`signature_delta`, never as the
        // visible answer — it must NOT be accumulated.
        let thinking = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}}"#;
        assert!(matches!(parse_stream_line(thinking), StreamEvent::Ignore));
        let sig = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}}"#;
        assert!(matches!(parse_stream_line(sig), StreamEvent::Ignore));
    }
    #[test]
    fn parse_tool_use_start_is_activity() {
        let line = r#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}}"#;
        match parse_stream_line(line) {
            StreamEvent::ToolActivity(a) => assert_eq!(a, ToolActivity::used("Read")),
            other => panic!("expected ToolActivity, got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_ok() {
        let line = r#"{"type":"result","subtype":"success","is_error":false,"result":"the answer","session_id":"sess-9"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Ok {
                result, session_id, ..
            }) => {
                assert_eq!(result, "the answer");
                assert_eq!(session_id.as_deref(), Some("sess-9"));
            }
            other => panic!("expected Done(Ok), got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_5xx_is_retryable() {
        let line = r#"{"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"overloaded"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Retryable { status, .. }) => assert_eq!(status, 529),
            other => panic!("expected Done(Retryable), got {other:?}"),
        }
    }
    #[test]
    fn parse_terminal_result_4xx_is_fatal() {
        let line =
            r#"{"type":"result","is_error":true,"api_error_status":400,"result":"bad request"}"#;
        match parse_stream_line(line) {
            StreamEvent::Done(ClaudeOutcome::Fatal { message }) => {
                assert!(message.contains("bad request"))
            }
            other => panic!("expected Done(Fatal), got {other:?}"),
        }
    }
    #[test]
    fn parse_non_json_and_noise_lines_are_ignored() {
        assert!(matches!(
            parse_stream_line("not json at all"),
            StreamEvent::Ignore
        ));
        assert!(matches!(parse_stream_line("   "), StreamEvent::Ignore));
        let rate = r#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#;
        assert!(matches!(parse_stream_line(rate), StreamEvent::Ignore));
        // A `system` event that is not `init` names no session.
        let status = r#"{"type":"system","subtype":"status","session_id":"s"}"#;
        assert!(matches!(parse_stream_line(status), StreamEvent::Ignore));
    }

    #[test]
    fn the_init_event_yields_the_session_id_the_cli_reported() {
        // Verified against claude 2.1.220: `system`/`init` is the FIRST line of the
        // stream and carries the session id, which names the transcript stem exactly.
        // This is the authoritative answer to "which session does this turn belong to".
        let init = r#"{"type":"system","subtype":"init","session_id":"a92c3087-9cc5-47e4-8a61-391ada0dec0d","cwd":"/v","tools":[]}"#;
        match parse_stream_line(init) {
            StreamEvent::SessionId(id) => {
                assert_eq!(id, "a92c3087-9cc5-47e4-8a61-391ada0dec0d")
            }
            other => panic!("expected SessionId, got {other:?}"),
        }
        // A malformed init (no id, or a blank one) must not manufacture a binding.
        let no_id = r#"{"type":"system","subtype":"init","cwd":"/v"}"#;
        assert!(matches!(parse_stream_line(no_id), StreamEvent::Ignore));
        let blank = r#"{"type":"system","subtype":"init","session_id":"  "}"#;
        assert!(matches!(parse_stream_line(blank), StreamEvent::Ignore));
    }

    /// The per-turn parser is a thin wrapper: the same line yields the same event, and a
    /// fresh parser per attempt carries nothing over (it holds no state to carry).
    #[test]
    fn the_claude_code_parser_matches_the_line_parser() {
        let mut parser = ClaudeCode.parser();
        let delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#;
        match parser.on_line(delta) {
            StreamEvent::TextDelta(t) => assert_eq!(t, "hi"),
            other => panic!("expected TextDelta, got {other:?}"),
        }
        let done = r#"{"type":"result","is_error":false,"result":"done","session_id":"s1"}"#;
        assert!(matches!(parser.on_line(done), StreamEvent::Done(_)));
        // A second parser (the next attempt) starts clean and behaves identically.
        let mut fresh = ClaudeCode.parser();
        assert!(matches!(fresh.on_line(done), StreamEvent::Done(_)));
    }

    #[test]
    fn build_claude_args_requests_partial_stream_json() {
        // The streaming contract: stream-json + the two flags `claude` requires
        // for token-level deltas under `-p`.
        let args = build_claude_args(
            &test_config(),
            "hi",
            None,
            Capability::Write,
            main_mcp_config(&test_config(), &ClaudeCode),
            None,
            None,
        );
        let pos = |needle: &str| args.iter().position(|a| a == needle);
        let of = pos("--output-format").expect("--output-format present");
        assert_eq!(args[of + 1], "stream-json");
        assert!(
            pos("--verbose").is_some(),
            "stream-json + -p requires --verbose"
        );
        assert!(
            pos("--include-partial-messages").is_some(),
            "token-level deltas require --include-partial-messages"
        );
    }
    #[test]
    fn build_claude_args_enforces_least_privilege() {
        let cfg = test_config();
        let args = build_claude_args(&cfg, "hello", None, Capability::Write, main_mcp_config(&cfg, &ClaudeCode), None, None);

        // --allowedTools is always present, with the configured list as its value.
        let idx = args
            .iter()
            .position(|a| a == "--allowedTools")
            .expect("--allowedTools must always be present");
        let allow = &args[idx + 1];
        assert_eq!(allow, &cfg.allowed_tools);

        // Permission mode is default — never an auto-accept / bypass mode.
        let pidx = args
            .iter()
            .position(|a| a == "--permission-mode")
            .expect("--permission-mode present");
        assert_eq!(args[pidx + 1], "default");

        // acceptEdits / bypassPermissions never appear anywhere in the args.
        for a in &args {
            assert!(
                !a.contains("acceptEdits"),
                "acceptEdits must not appear: {a}"
            );
            assert!(
                !a.contains("bypassPermissions"),
                "bypassPermissions must not appear: {a}"
            );
        }

        // Unscoped `Bash` is not in the allowlist — only scoped Bash(...) verbs.
        let tools: Vec<&str> = allow.split(',').map(|t| t.trim()).collect();
        assert!(
            !tools.contains(&"Bash"),
            "unscoped Bash must not be allowed: {tools:?}"
        );
        assert!(
            tools.iter().any(|t| t.starts_with("Bash(")),
            "expected scoped Bash(...) entries: {tools:?}"
        );

        // `node` is granted ONLY for the three named diet-cache scripts — never a
        // bare `Bash(node:*)`, which would permit `node -e "<arbitrary JS>"` (RCE
        // from a phone request). Pin both the presence of the scoped scripts and
        // the absence of any broader node scope.
        for script in [
            "Bash(node todo-list/generate-diet-today.js:*)",
            "Bash(node todo-list/validate-diet-today.js:*)",
            "Bash(node todo-list/verify-diet-consistency.js:*)",
        ] {
            assert!(
                tools.contains(&script),
                "expected scoped node script {script:?} in: {tools:?}"
            );
        }
        assert!(
            !tools
                .iter()
                .any(|t| *t == "Bash(node:*)" || *t == "Bash(node)"),
            "a bare node scope (arbitrary-JS RCE) must never be allowed: {tools:?}"
        );

        // The Skill tool is granted ONLY for the named `diet-logging` skill — never
        // a bare `Skill`, which would let any future vault skill run from a phone
        // request. The Skill tool loads instruction text only; real actions still
        // go through the scoped Read/Write/Edit + node scripts above.
        assert!(
            tools.contains(&"Skill(diet-logging)"),
            "expected scoped Skill(diet-logging) in: {tools:?}"
        );
        assert!(
            !tools.contains(&"Skill"),
            "a bare Skill scope (any-skill from a phone request) must never be allowed: {tools:?}"
        );

        // The scoped read-only helpers backing the clock header + file inspection
        // are present, and each is the `Bash(<verb>:*)` scoped form — never a bare
        // verb or unscoped Bash. These are read-only / pure-compute (no write, no
        // network), so they widen the read surface only.
        for verb in ["date", "cal", "head", "tail", "wc"] {
            assert!(
                tools.contains(&format!("Bash({verb}:*)").as_str()),
                "expected scoped Bash({verb}:*) in: {tools:?}"
            );
        }

        // Denylist posture: WebFetch is denied; bare `Bash` MUST NOT be.
        // Empirically (claude 2.1.199, verified on the Studio 2026-07-04) listing
        // bare `Bash` in --disallowedTools removes the entire Bash tool class,
        // shadowing EVERY scoped `Bash(<verb>:*)` allow entry above (git, node
        // diet scripts, date/cal, …) — they become unavailable, not merely the
        // unscoped form. Unscoped/unmatched Bash is already blocked without the
        // deny entry: under --permission-mode default a Bash command that matches
        // no scoped allow entry is denied (a phone request cannot answer the
        // permission prompt), so default-deny + the scoped allowlist is the real
        // boundary. Denying the class only breaks the scoped grants. So the
        // denylist drops bare Bash.
        //
        // WebFetch left this list in 0.57.0 (see DEFAULT_DISALLOWED_TOOLS). What
        // is asserted now is the property that outlives any particular entry: the
        // list must be NON-EMPTY. `env_string` treats a blank value as unset and
        // the field falls back to the compiled default, so an empty denylist does
        // not mean "deny nothing" — it silently means "deny whatever the default
        // says", which would re-arm the WebFetch deny and kill the capability with
        // no error. A non-empty list is the invariant; which tool holds the slot
        // is a posture decision the containment record signs off on.
        let didx = args
            .iter()
            .position(|a| a == "--disallowedTools")
            .expect("--disallowedTools present");
        let deny: Vec<&str> = args[didx + 1].split(',').map(|t| t.trim()).collect();
        assert!(
            !deny.is_empty() && deny.iter().any(|t| !t.is_empty()),
            "the denylist must never be empty — a blank value silently restores \
             DEFAULT_DISALLOWED_TOOLS: {deny:?}"
        );
        assert!(
            !deny.contains(&"Bash"),
            "bare Bash must NOT be in the denylist — it disables the whole Bash \
             tool class and kills every scoped Bash(...) grant: {deny:?}"
        );
    }
    /// The three env vars the title-backend override sets on the title child.
    const TITLE_ENV_KEYS: [&str; 3] = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
    ];

    /// Read the env OVERRIDES a `Command` carries (what `.env()` added), as a
    /// map. `get_envs()` yields only the explicit per-command overrides, not the
    /// inherited process env, so this sees exactly what the builder set.
    fn cmd_env_overrides(cmd: &Command) -> std::collections::HashMap<String, String> {
        cmd.as_std()
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect()
    }


    // ---- Diet extract/verify children --------------------------------------


    /// Extract the value following a flag in a Command's argv, or `None`.
    fn cmd_arg_value(cmd: &Command, flag: &str) -> Option<String> {
        let args: Vec<String> = cmd
            .as_std()
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        args.iter()
            .position(|a| a == flag)
            .map(|i| args[i + 1].clone())
    }

    /// True if a bare (valueless) flag appears anywhere in a Command's argv.
    fn cmd_has_flag(cmd: &Command, flag: &str) -> bool {
        cmd.as_std().get_args().any(|a| a.to_string_lossy() == flag)
    }

    /// A routed pick pointing at a local backend — the shape `apply_routed_env` layers.
    fn routed_pick(id: &str) -> RoutedPick {
        RoutedPick {
            id: id.to_string(),
            harness: CLAUDE_CODE_ID.to_string(),
            level: Capability::Basic,
            backend: Some((
                "http://127.0.0.1:9100".to_string(),
                "dsv4-diet-dummy".to_string(),
                format!("{id}-v1"),
            )),
        }
    }

    /// Both diet children — the AMBIENT one (a pick that applies nothing) and the
    /// ROUTED one (a pick carrying a backend triple) — are built by the one shared
    /// `build_diet_child_command`, so asserting the posture on the builder proves it for
    /// `run_diet_extract` AND `run_diet_verify` at once. This helper yields both command
    /// forms so every containment test below covers both.
    fn both_diet_child_commands() -> Vec<Command> {
        let ambient = build_diet_child_command(&test_config(), "hi");
        let mut routed = build_diet_child_command(&test_config(), "hi");
        apply_routed_env(&mut routed, &routed_pick("local-oss"));
        vec![ambient, routed]
    }

    /// The routed applier layers exactly the three `ANTHROPIC_*` vars for a pick that
    /// carries a backend, and NOTHING for an ambient pick — which is what makes an
    /// unconfigured `offload_order` byte-for-byte the old no-override behavior.
    #[test]
    fn the_routed_env_applier_is_all_three_vars_or_nothing() {
        let cfg = test_config();
        let mut routed = build_diet_child_command(&cfg, "hi");
        apply_routed_env(&mut routed, &routed_pick("local-oss"));
        let env = cmd_env_overrides(&routed);
        assert_eq!(
            env.get("ANTHROPIC_BASE_URL").map(String::as_str),
            Some("http://127.0.0.1:9100")
        );
        assert_eq!(
            env.get("ANTHROPIC_AUTH_TOKEN").map(String::as_str),
            Some("dsv4-diet-dummy")
        );
        assert_eq!(
            env.get("ANTHROPIC_MODEL").map(String::as_str),
            Some("local-oss-v1")
        );

        let mut ambient = build_diet_child_command(&cfg, "hi");
        apply_routed_env(
            &mut ambient,
            &RoutedPick {
                id: DEFAULT_MODEL_ID.to_string(),
                harness: CLAUDE_CODE_ID.to_string(),
                level: Capability::Write,
                backend: None,
            },
        );
        for k in TITLE_ENV_KEYS {
            assert!(
                !cmd_env_overrides(&ambient).contains_key(k),
                "an ambient pick must set {k} nowhere — the child inherits the process env"
            );
        }
    }

    /// THE MAIN-TURN ISOLATION PROPERTY, kept across the role-backend removal: a main-turn
    /// command carries none of the three `ANTHROPIC_*` overrides a routed job would layer.
    /// The main turn never calls `apply_routed_env`, and a routed job never calls
    /// `apply_main_env`.
    #[test]
    fn a_main_turn_command_never_carries_a_routed_jobs_backend() {
        let cfg = test_config();
        for sid in [None, Some("sess-1")] {
            let cmd = build_claude_command(
                &cfg,
                "do the thing",
                sid,
                &ActiveModel::ambient(),
                Capability::Write,
                main_mcp_config(&cfg, &ClaudeCode),
            );
            let env = cmd_env_overrides(&cmd);
            for k in TITLE_ENV_KEYS {
                assert!(
                    !env.contains_key(k),
                    "a main turn must never carry {k} from a routed job"
                );
            }
        }
    }

    #[test]
    fn diet_child_disables_all_builtin_tools_at_root() {
        // Deny-by-default at the tool-SET level: `--tools ""` removes every built-in
        // tool from the child's toolset at the root, so read/search built-ins (Glob,
        // Grep, Read, …), ToolSearch, Workflow and Agent do not exist to be invoked —
        // not merely permission-gated. This is the load-bearing containment flag
        // (live-proven: without it a "run ls" probe executes Glob).
        for cmd in both_diet_child_commands() {
            let tools = cmd_arg_value(&cmd, "--tools")
                .expect("--tools must be present (deny-by-default toolset)");
            assert_eq!(
                tools, "",
                "--tools must be EMPTY to disable all built-in tools"
            );
        }
    }

    #[test]
    fn diet_child_loads_no_mcp_servers() {
        // No MCP servers at the root: `--strict-mcp-config` tells the CLI to use ONLY
        // servers from `--mcp-config`, and that config declares an EMPTY server set —
        // so every `mcp__*` tool (and anything ToolSearch could load from a server) is
        // gone at the root, not denied by name.
        for cmd in both_diet_child_commands() {
            assert!(
                cmd_has_flag(&cmd, "--strict-mcp-config"),
                "--strict-mcp-config must be present so only --mcp-config servers load"
            );
            let mcp = cmd_arg_value(&cmd, "--mcp-config")
                .expect("--mcp-config must be present (empty server set)");
            let parsed: serde_json::Value =
                serde_json::from_str(&mcp).expect("--mcp-config value must be valid JSON");
            let servers = parsed.get("mcpServers").and_then(|v| v.as_object());
            assert!(
                servers.map(|m| m.is_empty()).unwrap_or(true),
                "the MCP config must declare NO servers: {mcp:?}"
            );
        }
    }

    /// Positional lookup over a plain arg VECTOR (`build_claude_args` returns one, not a
    /// `Command`), mirroring `cmd_arg_value`/`cmd_has_flag` for the diet/vault-QA children.
    fn arg_value(args: &[String], flag: &str) -> Option<String> {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1).cloned())
    }

    #[test]
    fn main_turn_loads_only_the_declared_mcp_servers() {
        // The MAIN path was the LAST child route without strict MCP config: the diet and
        // vault-QA children already carried it, so ordinary phone turns were the one
        // route still loading the ambient user/project MCP scopes — the account-level
        // cloud connectors (Gmail, Slack, Calendar, Drive) and playwright. Those
        // tools were refused, but only at the PERMISSION layer, which is a weaker
        // boundary than never loading them (and one a headless `-p` child can only fail
        // against, never answer). Asserted on BOTH branches `build_claude_args` can take
        // — writes-enabled (ambient opus) and read-only (a non-ambient model) — because
        // the flags are pushed before the branch and must never drift apart.
        let cfg = test_config();
        for (label, active) in [
            ("writes-enabled", ActiveModel::ambient()),
            ("read-only", glm_active()),
        ] {
            let args = build_claude_args(
                &cfg,
                "hi",
                None,
                turn_capability(&active),
                main_mcp_config(&cfg, &ClaudeCode),
                None,
                None,
            );
            assert!(
                args.iter().any(|a| a == "--strict-mcp-config"),
                "{label}: --strict-mcp-config must be present so ONLY --mcp-config servers load: {args:?}"
            );
            let mcp = arg_value(&args, "--mcp-config")
                .unwrap_or_else(|| panic!("{label}: --mcp-config must be present: {args:?}"));
            let parsed: serde_json::Value = serde_json::from_str(&mcp).unwrap_or_else(|e| {
                panic!("{label}: --mcp-config must be valid JSON ({e}): {mcp:?}")
            });
            let servers = parsed
                .get("mcpServers")
                .and_then(|v| v.as_object())
                .unwrap_or_else(|| {
                    panic!("{label}: --mcp-config must declare mcpServers: {mcp:?}")
                });

            // qmd is REQUIRED on the main path — unlike the vault-QA child, an unset
            // override must NOT degrade to the empty server set.
            assert!(
                servers.contains_key("qmd"),
                "{label}: the main path requires the qmd vault-search server: {mcp:?}"
            );
            // …plus the self-hosted read-only Slack server, since 0.57.0.
            assert!(
                servers.contains_key("slack"),
                "{label}: the main path declares the read-only slack server: {mcp:?}"
            );
            // …and NOTHING else. An exact count (rather than a denylist of server names)
            // is what makes re-adding ANY server — a cloud connector, playwright, or one
            // that does not exist yet — a deliberate, test-breaking act instead of a
            // silent widening. A name-based check would only catch the servers we
            // happened to think of, the same fragility documented for the denylists.
            // Raising this number is the test-breaking act; it must stay in lockstep
            // with a battery row that actually loads the new set.
            assert_eq!(
                servers.len(),
                2,
                "{label}: the main path must declare qmd and slack and nothing else: {mcp:?}"
            );
        }
    }

    #[test]
    fn main_turn_mcp_config_honors_the_env_override() {
        // Same resolution as the vault-QA child: `--mcp-config` accepts a file PATH or
        // inline JSON, so `JESSE_MAIN_MCP_CONFIG` supplies either verbatim. This is the
        // escape hatch for a host where `qmd` is not on the bridge's PATH (launchd's PATH
        // is narrower than a login shell's) — no user-specific path is baked into the
        // source. `--strict-mcp-config` still rides along.
        let mut cfg = test_config();
        cfg.main_mcp_config = Some("/etc/jesse/qmd.json".to_string());
        for active in [ActiveModel::ambient(), glm_active()] {
            let args = build_claude_args(
                &cfg,
                "hi",
                None,
                turn_capability(&active),
                main_mcp_config(&cfg, &ClaudeCode),
                None,
                None,
            );
            assert_eq!(
                arg_value(&args, "--mcp-config").as_deref(),
                Some("/etc/jesse/qmd.json"),
                "the env override must be passed through verbatim: {args:?}"
            );
            assert!(args.iter().any(|a| a == "--strict-mcp-config"));
        }
    }

    #[test]
    fn diet_child_denylist_covers_read_search_and_orchestration_classes() {
        // Belt-and-suspenders behind `--tools ""`: the enumerated denylist is expanded
        // past the original seven mutation/exec/network classes to also name the
        // read/search built-ins and the orchestration tools that the old empty-allowlist
        // posture left reachable (Glob, Grep, Read, ToolSearch, Workflow, Agent,
        // TodoWrite, Skill). Enumerated denial is fragile — it breaks silently when the
        // CLI renames or adds tools — which is exactly why `--tools ""` above is the
        // real guarantee and the live probe battery is the acceptance gate.
        for cmd in both_diet_child_commands() {
            let deny = cmd_arg_value(&cmd, "--disallowedTools").expect("--disallowedTools present");
            let names: Vec<&str> = deny.split(',').map(|t| t.trim()).collect();
            for class in [
                "Glob",
                "Grep",
                "Read",
                "ToolSearch",
                "Workflow",
                "Agent",
                "TodoWrite",
                "Skill",
            ] {
                assert!(
                    names.contains(&class),
                    "expanded denylist must name the {class} class: {names:?}"
                );
            }
        }
    }

    // ---- Vault-QA child ----------------------------------------------------


    // ---- The global model switch (main-turn model application) --------------

    /// A resolved non-ambient (GLM) active model for the switch tests, with an env triple
    /// DISTINCT from every role backend's so a leak is detectable.
    fn glm_active() -> ActiveModel {
        ActiveModel {
            id: "glm-5.2".to_string(),
            kind: ModelKind::Hosted,
            env: Some((
                "http://fireworks".to_string(),
                "fw-tok".to_string(),
                "glm-model".to_string(),
            )),
            subagent_model: Some("glm-model".to_string()),
            level: Capability::Read,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck::ZERO,
            vision: Vec::new(),
            vision_complementary: false,
        }
    }

    /// A cfg whose `offload_order` names a model for every routed job — the switch must
    /// never let a routed job's backend leak onto the main turn. (Before the role backends
    /// were replaced this fixture configured all three of them; the property it guards is
    /// the same one, now with a single list behind it.)
    fn cfg_with_all_role_backends() -> Config {
        let mut cfg = test_config();
        let mut models = cfg.model_registry.models.clone();
        models.push(RegistryModel {
            id: "local-oss".to_string(),
            label: "Local OSS".to_string(),
            kind: ModelKind::Local,
            backend: Some((
                "http://routed".to_string(),
                "routed-tok".to_string(),
                "routed-model".to_string(),
            )),
            subagent_model: None,
            configured: true,
            level: Capability::Read,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: Vec::new(),
            vision_complementary: false,
        });
        cfg.model_registry = ModelRegistry { models };
        cfg.offload_order = vec!["local-oss".to_string()];
        cfg
    }

    #[test]
    fn main_turn_with_active_opus_carries_no_anthropic_env() {
        // The updated isolation invariant, half one: with the DEFAULT (opus/ambient)
        // active, the main-turn command carries none of the three ANTHROPIC_* overrides
        // AND no subagent-model override — even when every role backend is configured.
        let cfg = cfg_with_all_role_backends();
        let opus = ActiveModel::ambient();
        for sid in [None, Some("sess-1")] {
            let cmd = build_claude_command(
                &cfg,
                "do the thing",
                sid,
                &opus,
                turn_capability(&opus),
                main_mcp_config(&cfg, &ClaudeCode),
            );
            let env = cmd_env_overrides(&cmd);
            for k in TITLE_ENV_KEYS {
                assert!(!env.contains_key(k), "opus main turn must NOT carry {k}");
            }
            assert!(
                !env.contains_key("CLAUDE_CODE_SUBAGENT_MODEL"),
                "opus main turn must NOT set a subagent model"
            );
        }
    }

    #[test]
    fn main_turn_with_active_glm_carries_exactly_the_glm_triple_and_subagent_model() {
        // The updated isolation invariant, half two: with a non-ambient model active, the
        // main-turn command carries EXACTLY that model's triple + subagent model, and NONE
        // of the title/diet/vault-QA role backends' distinct values leaks onto it.
        let cfg = cfg_with_all_role_backends();
        let active = glm_active();
        for sid in [None, Some("sess-1")] {
            let cmd = build_claude_command(
                &cfg,
                "do the thing",
                sid,
                &active,
                turn_capability(&active),
                main_mcp_config(&cfg, &ClaudeCode),
            );
            let env = cmd_env_overrides(&cmd);
            assert_eq!(
                env.get("ANTHROPIC_BASE_URL").map(String::as_str),
                Some("http://fireworks")
            );
            assert_eq!(
                env.get("ANTHROPIC_AUTH_TOKEN").map(String::as_str),
                Some("fw-tok")
            );
            assert_eq!(
                env.get("ANTHROPIC_MODEL").map(String::as_str),
                Some("glm-model")
            );
            // The subagents follow the switch.
            assert_eq!(
                env.get("CLAUDE_CODE_SUBAGENT_MODEL").map(String::as_str),
                Some("glm-model")
            );
            // No role backend's distinct value appears anywhere in the env overrides.
            for leaked in [
                "http://title",
                "title-tok",
                "title-model",
                "http://diet",
                "diet-tok",
                "diet-model",
                "http://vault",
                "vault-tok",
                "vault-model",
            ] {
                assert!(
                    !env.values().any(|v| v == leaked),
                    "role backend value {leaked:?} leaked onto the switched main turn"
                );
            }
        }
    }

    #[test]
    fn readonly_main_turn_allowlist_has_no_write_or_send_tools() {
        // A non-ambient READ-ONLY model (writes off) yields the contained boundary: a
        // read-only root allowlist and no Write/Edit/Bash/send tool anywhere. The boundary
        // is the allowlist, not the prompt.
        let cfg = test_config();
        let active = glm_active(); // writes_allowed = false
        let args = build_claude_args(
            &cfg,
            "read the vault",
            None,
            turn_capability(&active),
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        let val = |flag: &str| -> Option<String> {
            args.iter()
                .position(|a| a == flag)
                .map(|i| args[i + 1].clone())
        };
        // The read-only ROOT boundary is present.
        assert_eq!(val("--tools").as_deref(), Some("Read,Grep,Glob"));
        let allow = val("--allowedTools").expect("--allowedTools present");
        let tools: Vec<&str> = allow.split(',').map(|t| t.trim()).collect();
        assert!(
            tools.contains(&"Read(./**)"),
            "reads are allowed, and path-scoped to the working directory: {tools:?}"
        );
        assert!(
            !tools.contains(&"Read"),
            "a bare Read grant reaches every file the bridge user can read: {tools:?}"
        );
        // No write, edit, exec, or send tool is in the allowlist.
        for forbidden in ["Write", "Edit", "Bash", "WebFetch", "WebSearch"] {
            assert!(
                !tools
                    .iter()
                    .any(|t| *t == forbidden || t.starts_with(&format!("{forbidden}("))),
                "read-only allowlist must not grant {forbidden}: {tools:?}"
            );
        }
        // And no scoped Bash / node / Skill grant survives (they can write/exec).
        assert!(
            !tools
                .iter()
                .any(|t| t.starts_with("Bash(") || t.starts_with("Skill")),
            "read-only allowlist must drop the scoped Bash/Skill grants: {tools:?}"
        );
    }

    #[test]
    fn writes_on_non_ambient_model_uses_the_full_allowlist() {
        // Phase 2 shape: a non-ambient model WITH writes enabled uses the same full
        // allowlist opus does (byte-for-byte the configured list), not the read-only set.
        let cfg = test_config();
        let mut active = glm_active();
        active.level = Capability::Write;
        let args = build_claude_args(
            &cfg,
            "edit the vault",
            None,
            turn_capability(&active),
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        let allow = args
            .iter()
            .position(|a| a == "--allowedTools")
            .map(|i| args[i + 1].clone())
            .expect("--allowedTools present");
        assert_eq!(allow, cfg.allowed_tools, "writes-on → the full allowlist");
        // No read-only root boundary is added on the writes-on path.
        assert!(
            !args.iter().any(|a| a == "--tools"),
            "no read-only root boundary when writes-on"
        );
    }

    #[test]
    fn build_claude_args_resume_when_session() {
        let cfg = test_config();
        let args = build_claude_args(
            &cfg,
            "hi",
            Some("sess-42"),
            Capability::Write,
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        let ridx = args.iter().position(|a| a == "--resume").expect("--resume");
        assert_eq!(args[ridx + 1], "sess-42");
        // No --resume without a session id.
        let none = build_claude_args(&cfg, "hi", None, Capability::Write, main_mcp_config(&cfg, &ClaudeCode), None, None);
        assert!(!none.iter().any(|a| a == "--resume"));
    }
    #[test]
    fn build_claude_args_never_resumes_a_synthetic_local_id() {
        // Context carry: a `local-<hex>` thread id names a bridge-minted ledger thread
        // with NO real claude session behind it, so it must never reach --resume (the
        // CLI would error on an unknown session). The hosted turn runs fresh; the
        // caller re-keys the ledger from the synthetic id to the real returned id on
        // success. Proven directly on the argv the child is spawned with.
        let cfg = test_config();
        let synthetic = format!("local-{}", random_hex());
        let args = build_claude_args(
            &cfg,
            "hi",
            Some(&synthetic),
            Capability::Write,
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        assert!(
            !args.iter().any(|a| a == "--resume"),
            "a synthetic local- id must never produce --resume: {args:?}"
        );
        assert!(
            !args.iter().any(|a| a == &synthetic),
            "the synthetic id must not appear anywhere in argv: {args:?}"
        );
        // A real id still resumes, unchanged.
        let real = build_claude_args(
            &cfg,
            "hi",
            Some("real-sess-1"),
            Capability::Write,
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        let ridx = real.iter().position(|a| a == "--resume").expect("--resume");
        assert_eq!(real[ridx + 1], "real-sess-1");
    }

    // ---- Capability golden --------------------------------------------------

    /// The ten args every `claude` child starts with, turn or one-shot. `--setting-sources`
    /// is here rather than per-site: EVERY child runs with a cwd where settings discovery
    /// happens, so excluding the `local` scope is a floor, not a per-call-site choice.
    const GOLDEN_BASE: [&str; 10] = [
        "-p",
        "PROMPT",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--permission-mode",
        "default",
        "--setting-sources",
        "user,project",
    ];

    /// The MCP config the main path falls back to when `JESSE_MAIN_MCP_CONFIG` is unset —
    /// qmd plus the read-only slack server since 0.57.0. Spelled out rather than referencing
    /// [`MAIN_CHILD_MCP_CONFIG`] so the golden pins the literal a child is spawned with: a
    /// const-vs-const comparison would pass no matter what the const became.
    const GOLDEN_QMD_MCP: &str = r#"{"mcpServers":{"qmd":{"type":"stdio","command":"qmd","args":["mcp"]},"slack":{"type":"stdio","command":"npx","args":["-y","slack-mcp-server@latest","--transport","stdio"]}}}"#;
    const GOLDEN_EMPTY_MCP: &str = r#"{"mcpServers":{}}"#;

    /// The shared base plus a site's MCP + containment args — one full expected argv.
    fn golden(tail: &[&str]) -> Vec<String> {
        GOLDEN_BASE
            .iter()
            .chain(tail.iter())
            .map(|s| (*s).to_string())
            .collect()
    }

    /// A `Command`'s argv (everything after the binary name).
    fn cmd_argv(cmd: &Command) -> Vec<String> {
        cmd.as_std()
            .get_args()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn the_two_read_call_sites_are_now_identical_apart_from_their_mcp_set() {
        // The point of deleting the variance: `Read` means ONE thing, so neither site can
        // drift into being the lenient one. The MCP server set is deliberately still per
        // call site (the main path requires qmd, the vault-QA child degrades to none), so
        // the comparison is on the toolset the capability owns.
        let cfg = test_config();
        assert_eq!(
            claude_capability_args(&cfg, Capability::Read),
            vec![
                "--tools".to_string(),
                "Read,Grep,Glob".to_string(),
                "--allowedTools".to_string(),
                "Read(./**),Grep(./**),Glob(./**),mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status"
                    .to_string(),
                "--disallowedTools".to_string(),
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite,Skill"
                    .to_string(),
            ],
            "one Read posture, used verbatim by the main turn and the vault-QA child"
        );
        // And the vault-QA child really does carry it, `Skill` included.
        let child = cmd_argv(&build_vaultqa_child_command(&cfg, "PROMPT"));
        let deny = child
            .iter()
            .position(|a| a == "--disallowedTools")
            .map(|i| child[i + 1].clone())
            .expect("--disallowedTools present");
        assert!(
            deny.split(',').any(|t| t.trim() == "Skill"),
            "the vault-QA child must now deny Skill too: {deny:?}"
        );
    }

    /// A TURN WITH ATTACHMENTS ADDS THE DIRECTORY; A TURN WITHOUT IS BYTE IDENTICAL.
    ///
    /// The whole fix, stated as a difference: the ONLY thing an attachment adds to the child
    /// is a read grant over the one directory its own files are in. Everything else about
    /// the argv — permission mode, settings scopes, MCP boundary, toolset — is untouched, so
    /// the containment posture of an attachment-bearing turn is the posture of every other
    /// turn.
    #[test]
    fn attachment_turn_adds_its_scratch_dir_and_an_ordinary_turn_is_unchanged() {
        let cfg = test_config();
        let dir = std::env::temp_dir().join(format!("jesse-attach-{}", random_hex()));
        std::fs::create_dir(&dir).expect("scratch dir");

        let plain = build_claude_args(
            &cfg,
            "PROMPT",
            None,
            Capability::Write,
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            None,
        );
        let attached = build_claude_args(
            &cfg,
            "PROMPT",
            None,
            Capability::Write,
            main_mcp_config(&cfg, &ClaudeCode),
            None,
            Some(dir.as_path()),
        );

        // No attachments → not one byte moves. This is what keeps every ordinary turn, and
        // every containment argument written about it, exactly as it was.
        assert!(
            !plain.iter().any(|a| a == "--add-dir"),
            "a turn with no attachments must not carry the flag: {plain:?}"
        );

        // Attachments → the flag, naming the directory AS CREATED first.
        let at = attached
            .iter()
            .position(|a| a == "--add-dir")
            .expect("an attachment turn carries --add-dir");
        // The flag is variadic, so its values run until the next flag.
        let values = attached[at + 1..]
            .iter()
            .take_while(|a| !a.starts_with("--"))
            .count();
        assert_eq!(attached[at + 1], dir.display().to_string());

        // The SECOND spelling is conditional on the platform, and deliberately so. On macOS
        // — the deployment target, and where the reported bug happened —
        // `std::env::temp_dir()` is `/var/folders/…` whose realpath is
        // `/private/var/folders/…`, and the failing turn shows the model trying both. On a
        // Linux CI runner `/tmp` IS its own realpath, so there is no second spelling to pass
        // and emitting the same path twice would be noise. Asserting the platform's own
        // answer rather than macOS's keeps this test honest on both.
        let real = dir.canonicalize().expect("realpath");
        if real != dir {
            assert_eq!(values, 2, "a symlinked temp dir passes both spellings");
            assert_eq!(attached[at + 2], real.display().to_string());
        } else {
            assert_eq!(values, 1, "no distinct realpath means one value, not a duplicate");
        }

        // …and NOTHING else changed: strip the flag and its values and the two argvs are
        // equal.
        let mut stripped = attached.clone();
        stripped.drain(at..at + 1 + values);
        assert_eq!(
            stripped, plain,
            "an attachment must add the read grant and nothing else"
        );
        let _ = std::fs::remove_dir(&dir);
    }

    /// THE FLAG IS VARIADIC, SO A FLAG MUST FOLLOW IT.
    ///
    /// `--add-dir` takes one or more directories, so whatever comes next is swallowed as
    /// another directory unless it starts a new flag. Pinned at both spawn shapes an
    /// attachment turn can take — with the write lock's `--settings` file and without it —
    /// because those two put DIFFERENT flags next.
    #[test]
    fn add_dir_is_always_followed_by_another_flag() {
        let cfg = test_config();
        let dir = std::env::temp_dir().join(format!("jesse-attach-{}", random_hex()));
        std::fs::create_dir(&dir).expect("scratch dir");
        let settings = dir.join("settings.json");

        for (label, wl) in [("no write lock", None), ("write lock", Some(&settings))] {
            let args = build_claude_args(
                &cfg,
                "PROMPT",
                Some("sess-1"),
                Capability::Write,
                main_mcp_config(&cfg, &ClaudeCode),
                wl.map(|p| p.as_path()),
                Some(dir.as_path()),
            );
            let at = args.iter().position(|a| a == "--add-dir").expect(label);
            // The directory values run until the next flag (one or two of them, depending on
            // whether the temp dir has a distinct realpath — see the test above). What must
            // hold on every platform is that the list ENDS at a flag rather than at the end
            // of the argv: a trailing `--add-dir` would swallow whatever a later change
            // appended after it.
            let values = args[at + 1..]
                .iter()
                .take_while(|a| !a.starts_with("--"))
                .count();
            assert!(values >= 1, "{label}: --add-dir must name a directory: {args:?}");
            assert!(
                at + 1 + values < args.len(),
                "{label}: --add-dir's variadic list must be terminated by a following flag, \
                 but it runs to the end of the argv: {args:?}"
            );
            // And it lands ahead of the settings flag, where the comment says it does.
            if wl.is_some() {
                let s = args.iter().position(|a| a == "--settings").expect(label);
                assert!(at < s, "{label}: --add-dir must precede --settings");
            }
        }
        let _ = std::fs::remove_dir(&dir);
    }

    /// THE READ GRANT IS NOT PART OF THE CONTAINMENT RECORD, AND MUST NOT BECOME PART OF IT.
    ///
    /// `validate_toolset_argv` compares `Harness::capability_args` against the recorded
    /// `toolset_args` by STRICT EQUALITY. A per-turn absolute host path in there would fail
    /// the startup gate on every machine except the one that cut the record, so the flag
    /// lives in `build_claude_args` instead. This asserts the separation directly rather
    /// than trusting the call graph: no capability's args mention the flag or any temp path,
    /// at any level.
    #[test]
    fn the_attachment_grant_never_reaches_capability_args() {
        let cfg = test_config();
        for cap in [Capability::Basic, Capability::Read, Capability::Write] {
            let args = ClaudeCode.capability_args(&cfg, cap);
            assert!(
                !args.iter().any(|a| a == "--add-dir"),
                "{cap:?}: the containment argv must not carry the per-turn read grant: {args:?}"
            );
            assert_eq!(
                args,
                claude_capability_args(&cfg, cap),
                "{cap:?}: capability args must be byte-for-byte what the record compares"
            );
        }
    }

    /// THE GOLDEN. The exact argv each of the five spawn sites produces, captured from the
    /// four separate builders that preceded the single `claude_capability_args`. Every future
    /// posture change has to edit a literal here, which is the point: a containment change
    /// is never incidental.
    ///
    /// The `Write` allowlist/denylist are read from the fixture config because passing the
    /// CONFIGURED lists verbatim is exactly what `Write` means; their contents are pinned
    /// by `build_claude_args_enforces_least_privilege`.
    #[test]
    fn golden_argv_for_every_capability_call_site() {
        let cfg = test_config();
        let allow = cfg.allowed_tools.clone();
        let deny = cfg.disallowed_tools.clone();

        // 1. MAIN TURN, writes on → Write, qmd-only MCP. No root `--tools`.
        assert_eq!(
            build_claude_args(
                &cfg,
                "PROMPT",
                None,
                Capability::Write,
                main_mcp_config(&cfg, &ClaudeCode),
                None,
                None,
            ),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                GOLDEN_QMD_MCP,
                "--allowedTools",
                &allow,
                "--disallowedTools",
                &deny,
            ]),
            "main turn (writes on)"
        );

        // 2. MAIN TURN, writes off → Read, same qmd-only MCP. `Skill` denied.
        assert_eq!(
            build_claude_args(
                &cfg,
                "PROMPT",
                None,
                Capability::Read,
                main_mcp_config(&cfg, &ClaudeCode),
                None,
                None,
            ),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                GOLDEN_QMD_MCP,
                "--tools",
                "Read,Grep,Glob",
                "--allowedTools",
                "Read(./**),Grep(./**),Glob(./**),mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status",
                "--disallowedTools",
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite,Skill",
            ]),
            "main turn (writes off)"
        );

        // 3. VAULT-QA child (and the shadow child, which shares its builder) → Read, but
        //    its OWN MCP set: unset `JESSE_VAULTQA_MCP_CONFIG` → no servers, where the
        //    main path falls back to qmd. That divergence is deliberate and stays.
        //    The denylist is now the same at both Read sites.
        assert_eq!(
            cmd_argv(&build_vaultqa_child_command(&cfg, "PROMPT")),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                GOLDEN_EMPTY_MCP,
                "--tools",
                "Read,Grep,Glob",
                "--allowedTools",
                "Read(./**),Grep(./**),Glob(./**),mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status",
                "--disallowedTools",
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite,Skill",
            ]),
            "vault-QA child (no MCP config)"
        );

        // 3b. The same child with the qmd MCP config path set: passed through verbatim.
        let mut cfg_mcp = test_config();
        cfg_mcp.vaultqa_mcp_config = Some("/etc/jesse/qmd.json".to_string());
        assert_eq!(
            cmd_argv(&build_vaultqa_child_command(&cfg_mcp, "PROMPT")),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                "/etc/jesse/qmd.json",
                "--tools",
                "Read,Grep,Glob",
                "--allowedTools",
                "Read(./**),Grep(./**),Glob(./**),mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status",
                "--disallowedTools",
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite,Skill",
            ]),
            "vault-QA child (qmd MCP config)"
        );

        // 4. DIET children (extract + verify) → Basic. Empty root toolset, no MCP.
        assert_eq!(
            cmd_argv(&build_diet_child_command(&cfg, "PROMPT")),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                GOLDEN_EMPTY_MCP,
                "--tools",
                "",
                "--allowedTools",
                "",
                "--disallowedTools",
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Glob,Grep,Read,ToolSearch,Workflow,Agent,TodoWrite,Skill",
            ]),
            "diet extract/verify children"
        );

        // 5. TITLE one-shot → Basic with NO MCP servers. Writing a short title needs no
        //    tools and no vault search, so it is granted neither — the same posture as the
        //    diet children, differing only in the cwd each call site chose.
        assert_eq!(
            cmd_argv(&build_claude_command(
                &cfg,
                "PROMPT",
                None,
                &ActiveModel::ambient(),
                Capability::Basic,
                EMPTY_MCP_CONFIG
            )),
            golden(&[
                "--strict-mcp-config",
                "--mcp-config",
                GOLDEN_EMPTY_MCP,
                "--tools",
                "",
                "--allowedTools",
                "",
                "--disallowedTools",
                "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Glob,Grep,Read,ToolSearch,Workflow,Agent,TodoWrite,Skill",
            ]),
            "title one-shot"
        );
    }

    /// The trait route and the named builders are ONE construction, not two that happen to
    /// agree: `Harness::build_turn` is what the runtime calls, and the builders above are
    /// what the golden pins, so this asserts they produce the same argv, cwd and env at
    /// every one of the five sites. If they ever diverge, the golden stops proving anything
    /// about what actually spawns.
    #[test]
    fn build_turn_matches_the_named_builder_at_every_call_site() {
        let cfg = test_config();
        let ambient = ActiveModel::ambient();
        let harness = cfg.harnesses.fallback_harness();
        let same = |a: &Command, b: &Command, label: &str| {
            assert_eq!(cmd_argv(a), cmd_argv(b), "{label}: argv");
            assert_eq!(
                a.as_std().get_current_dir(),
                b.as_std().get_current_dir(),
                "{label}: cwd"
            );
            assert_eq!(cmd_env_overrides(a), cmd_env_overrides(b), "{label}: env");
        };
        for (capability, label) in [
            (Capability::Write, "main turn (writes on)"),
            (Capability::Read, "main turn (writes off)"),
        ] {
            let req = main_turn_request(
                &cfg,
                "PROMPT",
                Some("sess-1"),
                &ambient,
                capability,
                main_mcp_config(&cfg, &ClaudeCode),
            );
            same(
                &harness.build_turn(&cfg, &req).expect("claude never refuses"),
                &build_claude_command(
                    &cfg,
                    "PROMPT",
                    Some("sess-1"),
                    &ambient,
                    capability,
                    main_mcp_config(&cfg, &ClaudeCode),
                ),
                label,
            );
        }
        same(
            &harness
                .build_turn(&cfg, &diet_child_request(&cfg, "PROMPT", &ambient))
                .expect("claude never refuses"),
            &build_diet_child_command(&cfg, "PROMPT"),
            "diet child",
        );
        same(
            &harness
                .build_turn(&cfg, &vaultqa_child_request(&cfg, "PROMPT", &ambient))
                .expect("claude never refuses"),
            &build_vaultqa_child_command(&cfg, "PROMPT"),
            "vault-QA child",
        );
        same(
            &harness
                .build_turn(&cfg, &title_child_request(&cfg, "PROMPT", &ambient))
                .expect("claude never refuses"),
            &build_claude_command(
                &cfg,
                "PROMPT",
                None,
                &ambient,
                Capability::Basic,
                EMPTY_MCP_CONFIG,
            ),
            "title one-shot",
        );
    }

    /// The ONE way the collapse was not byte-identical, made explicit rather than buried.
    ///
    /// The CHILD sites emit the same flags with the same values in a different POSITION:
    /// they used to put `--tools` before the MCP pair, and now every site assembles in one
    /// order (base, MCP, toolset), which is what lets one builder serve all five. `claude`
    /// does not care about flag order, and this proves nothing was added, removed, or
    /// altered in value: the new vector is a permutation of the pre-collapse one.
    #[test]
    fn the_child_reorder_is_a_pure_permutation() {
        let cfg = test_config();
        // The pre-collapse DIET vector, captured from the builder the collapse replaced.
        //
        // The vault-QA child is deliberately NOT checked here any more: its denylist
        // gained `Skill` in this commit, so its argv is no longer value-identical to the
        // pre-collapse one and asserting a permutation would mean rewriting the captured
        // literal into a vector that never existed. That site's exact argv, before and
        // after, is pinned by the golden instead. The diet children changed position only,
        // which is what this test is for.
        let old_diet: Vec<String> = golden(&[
            "--tools",
            "",
            "--strict-mcp-config",
            "--mcp-config",
            GOLDEN_EMPTY_MCP,
            "--allowedTools",
            "",
            "--disallowedTools",
            "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Glob,Grep,Read,ToolSearch,Workflow,Agent,TodoWrite,Skill",
        ]);
        let new_diet = cmd_argv(&build_diet_child_command(&cfg, "PROMPT"));
        let sorted = |v: &[String]| {
            let mut v = v.to_vec();
            v.sort();
            v
        };
        assert_ne!(
            old_diet, new_diet,
            "this test is pointless if nothing moved"
        );
        assert_eq!(
            sorted(&old_diet),
            sorted(&new_diet),
            "the reorder must not add, drop or change any argument"
        );
    }

    #[test]
    fn diet_child_holds_no_tools() {
        // The diet children hold NO tools: an EMPTY --allowedTools, plus the
        // class-level denylist removing the mutation/exec/network tool classes.
        let cfg = test_config();
        let cmd = build_diet_child_command(&cfg, "hi");
        let allow = cmd_arg_value(&cmd, "--allowedTools").expect("--allowedTools present");
        assert_eq!(
            allow, "",
            "the diet child's allowlist must be EMPTY (no tools)"
        );
        let deny = cmd_arg_value(&cmd, "--disallowedTools").expect("--disallowedTools present");
        for class in ["Bash", "Write", "Edit", "WebFetch", "WebSearch", "Task"] {
            assert!(
                deny.split(',').any(|t| t.trim() == class),
                "denylist must remove the {class} class: {deny:?}"
            );
        }
    }

    #[test]
    fn vaultqa_child_is_read_only_at_the_root_with_no_resume_in_the_vault() {
        // The child's containment posture, asserted on the built argv:
        //   * `--tools "Read,Grep,Glob"` — a read-only ROOT allowlist (not empty).
        //   * `--strict-mcp-config` present so only --mcp-config servers load.
        //   * `--allowedTools` names the three built-ins plus the four qmd tools.
        //   * `--disallowedTools` names the mutation/exec/network/orchestration classes.
        //   * NO `--resume` (stateless), and cwd = the vault (the one divergence).
        let cfg = test_config();
        let cmd = build_vaultqa_child_command(&cfg, "answer me");

        let tools = cmd_arg_value(&cmd, "--tools").expect("--tools present");
        assert_eq!(tools, "Read,Grep,Glob", "read-only root allowlist");

        assert!(
            cmd_has_flag(&cmd, "--strict-mcp-config"),
            "--strict-mcp-config must be present"
        );
        // Unset MCP config → the shared empty-servers const (no servers).
        let mcp = cmd_arg_value(&cmd, "--mcp-config").expect("--mcp-config present");
        let parsed: serde_json::Value = serde_json::from_str(&mcp).expect("valid JSON");
        assert!(
            parsed
                .get("mcpServers")
                .and_then(|v| v.as_object())
                .map(|m| m.is_empty())
                .unwrap_or(true),
            "unset MCP config → no servers: {mcp:?}"
        );

        let allow = cmd_arg_value(&cmd, "--allowedTools").expect("--allowedTools present");
        let allowed: Vec<&str> = allow.split(',').map(|t| t.trim()).collect();
        for t in [
            // PATH-SCOPED, not bare: this child runs unattended in the vault, and an
            // unscoped read reaches every file the bridge user can read.
            "Read(./**)",
            "Grep(./**)",
            "Glob(./**)",
            "mcp__qmd__query",
            "mcp__qmd__get",
            "mcp__qmd__multi_get",
            "mcp__qmd__status",
        ] {
            assert!(allowed.contains(&t), "allowlist must name {t}: {allowed:?}");
        }
        for bare in ["Read", "Grep", "Glob"] {
            assert!(
                !allowed.contains(&bare),
                "an UNSCOPED {bare} grant would put the whole filesystem back in reach: \
                 {allowed:?}"
            );
        }
        // No mutation/exec built-in is granted.
        for t in ["Write", "Edit", "Bash"] {
            assert!(
                !allowed.contains(&t),
                "allowlist must NOT grant {t}: {allowed:?}"
            );
        }

        let deny = cmd_arg_value(&cmd, "--disallowedTools").expect("--disallowedTools present");
        let denied: Vec<&str> = deny.split(',').map(|t| t.trim()).collect();
        for class in [
            "Bash",
            "Write",
            "Edit",
            "NotebookEdit",
            "WebFetch",
            "WebSearch",
            "Task",
            "Agent",
            "ToolSearch",
            "Workflow",
            "TodoWrite",
        ] {
            assert!(
                denied.contains(&class),
                "denylist must name {class}: {denied:?}"
            );
        }

        // Stateless: never --resume.
        assert!(
            !cmd_has_flag(&cmd, "--resume"),
            "vault-QA child must not resume a session"
        );

        // cwd = the vault (the intentional divergence from the diet child's scratch cwd).
        assert_eq!(
            cmd.as_std().get_current_dir().map(|p| p.to_path_buf()),
            Some(std::path::PathBuf::from(&cfg.vault)),
            "vault-QA child cwd must be the vault"
        );
    }

    #[test]
    fn vaultqa_child_uses_mcp_config_path_when_set() {
        // When JESSE_VAULTQA_MCP_CONFIG is set, its PATH is passed straight to
        // --mcp-config (the CLI accepts a path or inline JSON), so the qmd server loads.
        let mut cfg = test_config();
        cfg.vaultqa_mcp_config = Some("/etc/jesse/qmd.json".to_string());
        let cmd = build_vaultqa_child_command(&cfg, "hi");
        assert_eq!(
            cmd_arg_value(&cmd, "--mcp-config").as_deref(),
            Some("/etc/jesse/qmd.json"),
            "the configured MCP config path must be passed verbatim"
        );
        assert!(cmd_has_flag(&cmd, "--strict-mcp-config"));
    }

}
