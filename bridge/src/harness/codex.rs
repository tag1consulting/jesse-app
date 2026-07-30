use crate::*;

// ---- The Codex harness --------------------------------------------------------
//
// Everything specific to speaking with OpenAI's `codex` CLI: the per-turn home, the
// argument vector, the containment mapping a [`Capability`] turns into, and the JSONL
// event parsing. The driver in [`crate::claude`] is unchanged and calls through
// `&dyn Harness` exactly as it does for Claude Code.
//
// # How this harness differs from Claude Code, and why it matters
//
// Claude Code is configured by PROCESS ENVIRONMENT on the child, so per-invocation
// isolation is free. Codex is configured from `$CODEX_HOME/config.toml` plus `-c`
// command-line overrides, so isolation has to be built rather than assumed. It is built
// from three things, all verified live against the pinned binary (see the spike record in
// `bridge/containment.toml` and the CHANGELOG):
//
//   * a PER-TURN `CODEX_HOME` ([`codex_turn_home`]), so no two turns share a mutable file;
//   * `--ignore-user-config`, so an operator's `~/.codex/config.toml` cannot widen the
//     posture this harness chose (auth still resolves through `CODEX_HOME`, which is
//     documented behaviour of the flag and is why the per-turn home is seeded with a
//     credential copy);
//   * `-c key=value` overrides for everything this harness actually decides.
//
// Verified 2026-07-30 on codex-cli 0.146.0: two concurrent turns with different
// per-turn homes and different configs each answered from their OWN config, neither home
// acquired the other's state, and a `CODEX_HOME`-scoped turn wrote ZERO files under the
// canonical `~/.codex`.
//
// # The credential lives in the per-turn home ON PURPOSE
//
// The bridge runs Codex off a subscription OAuth login, the same posture Claude Code runs
// under, so a per-turn home has to be seeded with a copy of the canonical `auth.json` or the
// child cannot authenticate at all. That is a DELIBERATE choice, not an oversight, and it
// has one consequence worth naming: the `read_agent_credential` probe's decoy is reachable
// in principle, so the recorded verdict for it describes a real credential surface rather
// than a boundary that arrived for free.
//
// It also has a refresh consequence, verified live rather than assumed. Codex refreshes when
// the access token's JWT `exp` has passed (a 240-hour lifetime; backdating `last_refresh`
// alone does NOT trigger a refresh). When a per-turn copy refreshes, the refresh token
// ROTATES and the copy is then discarded with the turn — so the canonical is left holding
// the PREDECESSOR token. Measured: the predecessor is still accepted, two concurrent turns
// refreshing independently each got a distinct new token without invalidating each other,
// and the canonical served a live turn afterwards. Isolation therefore holds across refresh.
//
// KNOWN DEPENDENCY, recorded rather than relied on silently: that rests on the auth server
// tolerating predecessor reuse, which is observed behaviour and not a documented contract.
// Because every per-turn refresh is thrown away, the canonical credential never advances on
// its own. Keeping it fresh is an operator concern (a periodic direct `codex` use, or a
// re-login), NOT something the turn path does — writing a refreshed token back would
// reintroduce exactly the shared mutable file the per-turn home exists to remove.

/// The id of the Codex harness: the registry key, and the value a model's `harness` config
/// key names to run under it.
pub const CODEX_ID: &str = "codex";

/// The Codex harness: headless `codex exec --json` against the vault. A unit struct for
/// the same reason [`ClaudeCode`] is one — it is a shared registry singleton serving
/// concurrent turns, so all per-turn state lives in [`CodexParser`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Codex;

// ---- Capability → sandbox + execution policy -----------------------------------

/// Turn a [`Capability`] into Codex's containment flags, and DOCUMENT WHAT EACH LEVEL DOES
/// AND DOES NOT PREVENT. Read this before changing a single flag.
///
/// # The lever is not a tool allowlist, because Codex has none
///
/// Claude Code's containment is a named tool allowlist: the bridge can hand it a root
/// toolset, path-scope a grant, and remove a capability by removing a tool. **Codex has no
/// such surface.** Verified against 0.146.0 with `--strict-config` as an oracle (it rejects
/// an unknown `-c` field by name): `tools.web_search` exists, and `tools.shell` does NOT —
/// nor does any other key that would remove the shell. The shell is not an optional tool on
/// this harness; it is the harness. Codex reaches for it for everything, including reads: a
/// live turn asked only to read a file ran ``/bin/zsh -lc "sed -n '1p' AGENTS.md"``.
///
/// So there is no file-surface / shell-surface asymmetry to exploit here, and the remedy
/// that closed Claude Code's read escapes — a path-scoped tool grant — HAS NO ANALOGUE.
/// The only levers are the sandbox and the execution policy, and this function is the
/// complete statement of how they are set.
///
/// # What each level sets, and what it leaves open
///
/// ## `Write` — `sandbox_mode = "workspace-write"`
/// Writes are permitted inside the workspace roots and denied everywhere else by the
/// OPERATING SYSTEM (Seatbelt on macOS, Landlock/seccomp on Linux), not by a tool refusing.
/// `writable_roots` is set to exactly the turn's cwd, and `/tmp` and `$TMPDIR` are excluded
/// so a write cannot be laundered through a world-writable directory.
/// * PREVENTS: writing outside the workspace, by any route, including a shell command —
///   the kernel refuses, so a delegated or scripted write fails the same way a direct one does.
/// * DOES NOT PREVENT: reading anything the bridge user can read (see below), or modifying
///   anything inside the workspace, which at this level is the point.
///
/// ## `Read` — `sandbox_mode = "read-only"`
/// No writes anywhere, enforced by the same OS layer.
/// * PREVENTS: every write, everywhere, including into the workspace.
/// * DOES NOT PREVENT: **reads of anything the bridge user can read.** A read-only sandbox
///   is read-ONLY, not read-SCOPED: there is no `readable_roots`. The child can `cat` any
///   file the bridge process could, which includes the vault, the bridge's state directory,
///   and the canonical `~/.codex`. This is recorded as a set of `known_open` baselines
///   rather than wished away, and it is the single largest difference from the Claude Code
///   posture, where reads ARE path-scoped.
///
/// ### The read surface is ACCEPTED, and by whom
///
/// Owner decision, 2026-07-30: this harness is trusted to read to the same degree Claude
/// Code is, because reading is what both are asked to do. The six `known_open` read
/// baselines are therefore a RECORDED PROPERTY of the Codex posture and not a defect
/// awaiting a fix, and `Read` ships on that basis.
///
/// Recorded here rather than left implicit because the two harnesses now differ in a way a
/// future reader would otherwise read as an oversight: Claude Code's reads are path-scoped
/// and Codex's are not, and the gap is not closable with the mechanism that closed it there
/// (a scope is a property of a named tool grant; Codex has no named tools). The decision is
/// to accept the wider surface, not to have missed it. If that trust ever changes, the lever
/// is the SANDBOX — there is no allowlist to tighten — and the battery has to be re-run.
///
/// ## `Basic` — NOT REACHABLE, and this function says so by returning the `Read` posture
/// `Basic` means "no tools at all: text in, text out". On Codex that cannot be expressed.
/// There is no lever that removes the shell, so the weakest posture Codex has is
/// byte-identical to `Read`. A `Basic` grant here would therefore be a LIE — it would name a
/// containment the harness does not implement — so this function deliberately maps `Basic`
/// to the same flags as `Read` and the battery is left to record the truth: at `basic/none`
/// the positive controls `read_vault_file` and `search_vault` are REQUIRED to be denied, the
/// child reads anyway, and the row fails its hard gates.
///
/// That failure is the design working. The startup gate holds config to the levels whose
/// battery passed, so a Codex model simply cannot be granted `Basic`, and no further code is
/// needed to enforce it. Do not "fix" this by inventing a prompt-level restriction: the
/// boundary is the toolset, and a prompt is not a boundary.
///
/// # Approval policy, and why it is `never`
///
/// Codex's default is `OnRequest`: on a sandbox denial it ASKS. A headless child cannot be
/// answered, so an asking child hangs until the turn times out — which the battery would
/// score `inconclusive`, and which a real turn would experience as a stall. `never` makes
/// the denial terminal and visible instead. It does NOT widen anything: it is the answer to
/// "what happens when the sandbox says no", and the answer is "fail", not "escalate".
///
/// The one thing it must never become is `--dangerously-bypass-approvals-and-sandbox`,
/// which removes the sandbox entirely. Nothing here constructs that flag.
pub fn codex_capability_args(capability: Capability) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    match capability {
        // See the doc comment: `Basic` is UNREACHABLE on this harness and deliberately
        // falls through to the `Read` posture rather than claiming a containment Codex
        // cannot implement. `Codex::expresses` is what says so out loud; this arm exists so
        // that a caller who asks anyway gets the strictest posture Codex HAS rather than a
        // panic or a wider one.
        Capability::Basic | Capability::Read => {
            args.push("-c".to_string());
            args.push("sandbox_mode=\"read-only\"".to_string());
        }
        Capability::Write => {
            args.push("-c".to_string());
            args.push("sandbox_mode=\"workspace-write\"".to_string());
            // Exactly the turn's cwd, and nothing else, is writable — named by
            // [`WORKSPACE_TOKEN`] rather than by the path, and filled in by
            // [`fill_workspace`] when the child is built. The record therefore commits a
            // scope that is identical on every machine, which is what lets the startup
            // comparison stay strict equality.
            args.push("-c".to_string());
            args.push(format!(
                "sandbox_workspace_write.writable_roots=[\"{WORKSPACE_TOKEN}\"]"
            ));
            // A world-writable directory is a laundering route for a write that then gets
            // read back in, so both are excluded from the writable set.
            args.push("-c".to_string());
            args.push("sandbox_workspace_write.exclude_tmpdir_env_var=true".to_string());
            args.push("-c".to_string());
            args.push("sandbox_workspace_write.exclude_slash_tmp=true".to_string());
            // The workspace-write sandbox permits network egress unless told otherwise.
            // The bridge's children have no business reaching the network directly.
            args.push("-c".to_string());
            args.push("sandbox_workspace_write.network_access=false".to_string());
        }
    }

    // At EVERY level: a sandbox denial is terminal, never an approval prompt a headless
    // child cannot answer. See the doc comment.
    args.push("-c".to_string());
    args.push("approval_policy=\"never\"".to_string());

    // The model's own web-search tool is a network egress route that bypasses the sandbox
    // entirely (the request is made by the API side, not the child), so it is off at every
    // level. This is the one genuine tool toggle Codex exposes.
    args.push("-c".to_string());
    args.push("tools.web_search=false".to_string());

    args
}

/// Replace [`WORKSPACE_TOKEN`] with the turn's real working directory, TOML-quoted.
///
/// The token is written into the argv already surrounded by its quotes
/// (`writable_roots=["${WORKSPACE}"]`) so the recorded row reads like the override it
/// becomes; substitution therefore swaps the quoted token for a freshly quoted path rather
/// than swapping the bare token inside quotes it did not escape. A cwd containing a `"` or a
/// `\` would otherwise change the meaning of the whole override.
fn fill_workspace(args: Vec<String>, cwd: &Path) -> Vec<String> {
    let quoted_token = format!("\"{WORKSPACE_TOKEN}\"");
    let real = toml_string(&cwd.display().to_string());
    args.into_iter()
        .map(|a| a.replace(&quoted_token, &real))
        .collect()
}

/// Quote a string as a TOML basic string, for a `-c key=value` override whose value is a
/// path. `-c` parses the value as TOML and falls back to a literal, so a path containing a
/// `"` or `\` would otherwise change the meaning of the override.
fn toml_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

// ---- The MCP server set, translated ---------------------------------------------

/// Translate the bridge's MCP server set — expressed in Claude Code's `{"mcpServers":{…}}`
/// JSON, which is the format [`TurnRequest::mcp_config`] carries — into Codex's
/// `-c mcp_servers.<name>.command=…` overrides.
///
/// A TRANSLATION rather than a second source of truth: the bridge has one MCP vocabulary and
/// each harness expresses it in its own config language. An entry this harness cannot
/// express is a [`HarnessError`], never a silent drop — a child spawned without the vault
/// search it was promised would answer from nothing and look like a bad model.
///
/// Verified live (0.146.0): with qmd configured this way the tools ARE surfaced and ARE
/// preferred — a turn asked a vault question with no mention of MCP went straight to
/// `qmd.query` / `qmd.get` and never touched the shell. The earlier report that Codex
/// "ignored its MCP tools and shelled out to the qmd CLI" was a configuration failure, not a
/// model preference.
pub fn codex_mcp_args(harness: &'static str, mcp_config: &str) -> Result<Vec<String>, HarnessError> {
    let parsed: serde_json::Value = serde_json::from_str(mcp_config).map_err(|e| {
        HarnessError::unsupported(harness, format!("an MCP server set it could not parse ({e})"))
    })?;
    let Some(servers) = parsed.get("mcpServers").and_then(|v| v.as_object()) else {
        return Err(HarnessError::unsupported(
            harness,
            "an MCP server set with no `mcpServers` object",
        ));
    };

    let mut args = Vec::new();
    for (name, spec) in servers {
        // Only stdio servers are expressible. The bridge ships exactly one server (qmd,
        // stdio), so anything else is a config the bridge does not make today — and it
        // must refuse rather than spawn a child missing a server it was told to load.
        let kind = spec.get("type").and_then(|v| v.as_str()).unwrap_or("stdio");
        if kind != "stdio" {
            return Err(HarnessError::unsupported(
                harness,
                format!("a `{kind}` MCP server (`{name}`); only stdio servers are supported"),
            ));
        }
        let Some(command) = spec.get("command").and_then(|v| v.as_str()) else {
            return Err(HarnessError::unsupported(
                harness,
                format!("an MCP server (`{name}`) with no `command`"),
            ));
        };
        args.push("-c".to_string());
        args.push(format!(
            "mcp_servers.{name}.command={}",
            toml_string(command)
        ));
        if let Some(list) = spec.get("args").and_then(|v| v.as_array()) {
            let rendered: Vec<String> = list
                .iter()
                .filter_map(|a| a.as_str())
                .map(toml_string)
                .collect();
            args.push("-c".to_string());
            args.push(format!(
                "mcp_servers.{name}.args=[{}]",
                rendered.join(", ")
            ));
        }
    }
    Ok(args)
}

// ---- The per-turn home ----------------------------------------------------------

/// Where this harness keeps its per-turn `CODEX_HOME` directories: one subdirectory per
/// spawn, under the bridge's state directory so they are cleaned with it.
pub fn codex_home_base(cfg: &Config) -> PathBuf {
    cfg.state_dir
        .as_deref()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(&cfg.home).join(".jesse-bridge"))
        .join("codex-homes")
}

/// The canonical `CODEX_HOME` the bridge's own login lives in — `$CODEX_HOME` when the
/// operator set one, else `~/.codex`, which is where `codex login` writes.
pub fn codex_canonical_home(cfg: &Config) -> PathBuf {
    std::env::var("CODEX_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(&cfg.home).join(".codex"))
}

/// Build a fresh per-turn `CODEX_HOME`, seeded with a COPY of the canonical credential.
///
/// This is the mechanism the whole isolation argument rests on, so it does exactly two
/// things and nothing else: make a directory nothing else writes to, and put a copy of
/// `auth.json` in it. It never writes a `config.toml` — the posture travels on the command
/// line, where it cannot be edited by anything between turns.
///
/// A missing canonical credential is NOT an error here: the directory is still made, the
/// child still spawns, and it fails with Codex's own "not logged in" message, which is a far
/// better operator signal than this function inventing one.
pub fn codex_turn_home(cfg: &Config) -> std::io::Result<PathBuf> {
    let base = codex_home_base(cfg);
    std::fs::create_dir_all(&base)?;
    let dir = base.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&dir)?;
    let auth = codex_canonical_home(cfg).join("auth.json");
    if auth.is_file() {
        let dest = dir.join("auth.json");
        std::fs::copy(&auth, &dest)?;
        // The copy carries a live OAuth credential; keep it owner-only, matching the mode
        // `codex login` writes the canonical with.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o600));
        }
    }
    Ok(dir)
}

// ---- The argument vector ---------------------------------------------------------

/// Build the argument vector for one `codex` invocation (everything after the binary name).
/// Pure and side-effect-free so it can be unit-tested without spawning a process — the one
/// side effect this harness has (the per-turn home) is [`codex_turn_home`]'s, and is passed
/// in here as an already-created path.
pub fn build_codex_args(
    prompt: &str,
    session_id: Option<&str>,
    capability: Capability,
    cwd: &Path,
    mcp_args: &[String],
) -> Vec<String> {
    let mut args = vec!["exec".to_string()];

    // Resume BEFORE the prompt: `codex exec resume <id> <prompt>` is a subcommand, not a
    // flag. A synthetic `local-<hex>` id names a bridge-minted ledger thread with no real
    // Codex thread behind it and must never be resumed — the same rule, and the same
    // reason, as the Claude Code builder's.
    let resume = session_id.filter(|sid| !is_synthetic_session_id(sid));
    if let Some(sid) = resume {
        args.push("resume".to_string());
        args.push(sid.to_string());
    }

    // JSONL events on stdout: the only output format that carries the thread id, the tool
    // activity and the usage as separate machine-readable events.
    args.push("--json".to_string());
    // The bridge's cwd is a vault, not necessarily a git repo, and Codex otherwise refuses
    // to run outside one.
    args.push("--skip-git-repo-check".to_string());
    // The operator's own `$CODEX_HOME/config.toml` must not be able to widen the posture
    // this harness chose. Auth still resolves through CODEX_HOME, which is why the per-turn
    // home is seeded with a credential copy.
    args.push("--ignore-user-config".to_string());
    // Project-level `.rules` execpolicy files live in the vault and are not the bridge's
    // containment surface; the sandbox is. Loading them would let vault CONTENT influence
    // what the child may execute.
    args.push("--ignore-rules".to_string());
    args.push("-C".to_string());
    args.push(cwd.display().to_string());

    args.extend(fill_workspace(codex_capability_args(capability), cwd));
    args.extend_from_slice(mcp_args);

    // The prompt is positional and LAST, so nothing after it can be read as a flag.
    args.push(prompt.to_string());
    args
}

impl Codex {
    /// Build one child `Command`: a fresh per-turn `CODEX_HOME`, the capability's sandbox
    /// posture, the translated MCP set, piped stdio and `kill_on_drop`.
    pub fn command(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        let mcp = codex_mcp_args(CODEX_ID, req.mcp_config)?;
        let home = codex_turn_home(cfg).map_err(|e| {
            HarnessError::unsupported(CODEX_ID, format!("a per-turn home directory ({e})"))
        })?;
        let mut cmd = Command::new(&cfg.codex_bin);
        cmd.args(build_codex_args(
            req.prompt,
            req.session_id,
            req.capability,
            &req.cwd,
            &mcp,
        ))
        .current_dir(&req.cwd)
        .env("CODEX_HOME", &home)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
        Ok(cmd)
    }
}

impl Harness for Codex {
    fn id(&self) -> &'static str {
        CODEX_ID
    }

    /// FALSE: Codex delivers its answer whole, in one `item.completed` event carrying an
    /// `agent_message`. There is no partial-message option — the `--json` stream has no
    /// token-level delta for the visible answer at all, only whole items.
    fn streams_text(&self) -> bool {
        false
    }

    /// FALSE at `Basic`, true at `Read` and `Write`.
    ///
    /// `Basic` means "no tools at all: text in, text out", and on this harness there is no
    /// lever that produces it. The containment surface is an OS sandbox MODE, not a tool
    /// allowlist, and the shell is not an optional tool — it is the harness. Verified against
    /// codex-cli 0.146.0 with `--strict-config` as an oracle (it rejects an unknown `-c`
    /// field BY NAME): `tools.web_search` exists and is accepted, `tools.shell` is rejected
    /// as unknown, and no other key removes the shell. So Codex's weakest posture is
    /// `sandbox_mode="read-only"`, which is byte-identical to its `Read` posture.
    ///
    /// **`Basic` is therefore not a level Codex FAILS, it is a level Codex does not HAVE.**
    /// The distinction is the whole reason this method exists rather than a startup check
    /// reading the record: a failing row says "go fix the posture", and there is nothing here
    /// to fix short of a different CLI. Refusing at config time with "cannot express" tells
    /// an operator the truth; refusing with "failed a gate" sends them looking for a flag
    /// that does not exist.
    ///
    /// Do not be tempted to express it in the prompt instead. The boundary is the toolset,
    /// and a prompt is not a boundary.
    fn expresses(&self, capability: Capability) -> bool {
        capability > Capability::Basic
    }

    /// The argv WITH [`WORKSPACE_TOKEN`] still in it — this is the recorded, host-independent
    /// form the startup gate compares against. [`build_codex_args`] fills the token in when
    /// it builds a real child, because only a spawn knows its own working directory.
    fn capability_args(&self, _cfg: &Config, capability: Capability) -> Vec<String> {
        codex_capability_args(capability)
    }

    /// `None`: Codex keeps its threads privately, in a layout the bridge does not read.
    ///
    /// The consequences are the ones [`Harness::transcript_dir`] already specifies, and they
    /// are accepted rather than worked around: adoption, the GC sweep and the resume
    /// existence check all skip this harness, and hydration returns an EMPTY turn list. So a
    /// Codex conversation on a freshly restored device LISTS but has no server-side history.
    /// The app's own local transcript remains the user-visible record and the context ledger
    /// still feeds catch-up into the next turn.
    fn transcript_dir(&self, _cfg: &Config) -> Option<PathBuf> {
        None
    }

    fn build_turn(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        self.command(cfg, req)
    }

    fn parser(&self) -> Box<dyn TurnParser> {
        Box::new(CodexParser::default())
    }
}

// ---- The per-turn parser ----------------------------------------------------------

/// Codex's per-turn parser, and the reason [`TurnParser`] is an OBJECT rather than a
/// stateless function on the harness.
///
/// The terminal outcome is assembled from THREE different events, arriving in this order:
///   * `thread.started` — carries `thread_id`, the id `codex exec resume` accepts. Early.
///   * `item.completed` with `item.type == "agent_message"` — the visible answer, whole.
///   * `turn.completed` — carries `usage`, and is the LAST event of the turn.
///
/// Only a parser that accumulates across lines can emit a complete `Done`, which is what
/// this does: it holds the thread id and the latest agent message, and emits `Done` when
/// `turn.completed` arrives.
///
/// **The last `agent_message` wins, not the first.** Codex emits a short preamble message
/// ("I'll search the notes and quote the rule") as its own `agent_message` item BEFORE it
/// starts calling tools, then the real answer as another one at the end. Taking the first
/// would deliver the preamble as the answer — observed on every multi-step turn.
#[derive(Default)]
pub struct CodexParser {
    thread_id: Option<String>,
    message: Option<String>,
}

impl TurnParser for CodexParser {
    fn on_line(&mut self, line: &str) -> StreamEvent {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            // Codex prints a couple of non-JSON banner lines before the stream proper.
            return StreamEvent::Ignore;
        };
        match v.get("type").and_then(|t| t.as_str()).unwrap_or_default() {
            "thread.started" => {
                if let Some(id) = v.get("thread_id").and_then(|t| t.as_str()) {
                    self.thread_id = Some(id.to_string());
                }
                StreamEvent::Ignore
            }
            "item.started" | "item.completed" => {
                let item = v.get("item");
                let kind = item
                    .and_then(|i| i.get("type"))
                    .and_then(|t| t.as_str())
                    .unwrap_or_default();
                match kind {
                    "agent_message" => {
                        if let Some(text) = item.and_then(|i| i.get("text")).and_then(|t| t.as_str())
                        {
                            // Last one wins — see the struct doc.
                            self.message = Some(text.to_string());
                        }
                        StreamEvent::Ignore
                    }
                    // The mid-turn activity feed. A whole-answer harness shows nothing until
                    // the end unless these are surfaced, so they are the coarse activity
                    // hint the clients render beside the spinner.
                    "command_execution" if v["type"] == "item.started" => {
                        StreamEvent::ToolActivity {
                            name: "Bash".to_string(),
                        }
                    }
                    "mcp_tool_call" if v["type"] == "item.started" => {
                        let server = item
                            .and_then(|i| i.get("server"))
                            .and_then(|s| s.as_str())
                            .unwrap_or("mcp");
                        let tool = item
                            .and_then(|i| i.get("tool"))
                            .and_then(|s| s.as_str())
                            .unwrap_or_default();
                        StreamEvent::ToolActivity {
                            name: format!("mcp__{server}__{tool}"),
                        }
                    }
                    "file_change" if v["type"] == "item.started" => StreamEvent::ToolActivity {
                        name: "Edit".to_string(),
                    },
                    _ => StreamEvent::Ignore,
                }
            }
            "turn.completed" => StreamEvent::Done(ClaudeOutcome::Ok {
                result: self.message.clone().unwrap_or_default(),
                session_id: self.thread_id.clone(),
                usage: codex_usage(v.get("usage")),
            }),
            "turn.failed" | "error" => {
                let message = v
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .or_else(|| v.get("message").and_then(|m| m.as_str()))
                    .unwrap_or("codex reported a turn failure")
                    .to_string();
                StreamEvent::Done(ClaudeOutcome::Fatal { message })
            }
            _ => StreamEvent::Ignore,
        }
    }
}

/// Map Codex's `usage` object onto the bridge's [`ShadowUsage`], which is Anthropic-shaped.
///
/// The two shapes disagree on ONE point and it is the one that would silently inflate every
/// cost badge: Codex reports `input_tokens` as the TOTAL prompt, with `cached_input_tokens`
/// a SUBSET of it, while `ShadowUsage::cost` assumes the Anthropic convention where
/// `input_tokens` EXCLUDES cache reads and the two are added. Feeding Codex's numbers
/// through unchanged would bill every cached token twice — once at the input rate and once
/// at the cached rate.
///
/// So the cached count is SUBTRACTED out here, saturating at zero in case a future version
/// changes the convention (an underflow would otherwise wrap to an astronomical count).
///
/// `reasoning_output_tokens` is folded into `output_tokens` because it is billed at the
/// output rate and the badge has no separate slot for it.
fn codex_usage(usage: Option<&serde_json::Value>) -> ShadowUsage {
    let Some(u) = usage else {
        return ShadowUsage::default();
    };
    let n = |k: &str| u.get(k).and_then(|v| v.as_u64());
    let cached = n("cached_input_tokens");
    ShadowUsage {
        input_tokens: n("input_tokens").map(|t| t.saturating_sub(cached.unwrap_or(0))),
        cache_read_input_tokens: cached,
        cache_creation_input_tokens: n("cache_write_input_tokens"),
        output_tokens: match (n("output_tokens"), n("reasoning_output_tokens")) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0) + b.unwrap_or(0)),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    /// The recorded posture and the spawned posture are the SAME statement with one hole
    /// filled: the argv the gate compares carries the token, and the argv the child actually
    /// gets carries this turn's directory. If these two ever come from different code the
    /// record stops describing what runs, which is the whole failure the token exists to make
    /// impossible.
    #[test]
    fn the_workspace_token_is_recorded_and_filled_in_at_spawn() {
        let recorded = Codex.capability_args(&test_config(), Capability::Write);
        assert!(
            recorded
                .iter()
                .any(|a| a.contains("writable_roots") && a.contains(WORKSPACE_TOKEN)),
            "{recorded:?}"
        );
        let args = build_codex_args(
            "hi",
            None,
            Capability::Write,
            Path::new("/srv/vault notes"),
            &[],
        );
        assert!(
            args.iter()
                .any(|a| a == "sandbox_workspace_write.writable_roots=[\"/srv/vault notes\"]"),
            "{args:?}"
        );
        assert!(
            !args.iter().any(|a| a.contains(WORKSPACE_TOKEN)),
            "a token reached the child: {args:?}"
        );
    }

    /// A working directory containing a quote must not be able to reinterpret the whole `-c`
    /// override — the substitution quotes the path, it does not paste it.
    #[test]
    fn a_quote_in_the_working_directory_cannot_escape_the_override() {
        let args = build_codex_args(
            "hi",
            None,
            Capability::Write,
            Path::new("/srv/we\"ird"),
            &[],
        );
        let root = args
            .iter()
            .find(|a| a.starts_with("sandbox_workspace_write.writable_roots"))
            .expect("a writable-roots override");
        assert_eq!(
            root,
            "sandbox_workspace_write.writable_roots=[\"/srv/we\\\"ird\"]"
        );
    }

    /// `Basic` is not a posture Codex has, and asking for it anyway yields the STRICTEST one
    /// it does have rather than a wider one. Nothing in a running bridge asks — the startup
    /// gate and the routing walk both read `expresses` first — but a fallback that silently
    /// widened would be the worst possible answer to a call that should not happen.
    #[test]
    fn asking_for_a_posture_codex_lacks_yields_its_strictest_one() {
        assert!(!Codex.expresses(Capability::Basic));
        assert!(Codex.expresses(Capability::Read));
        assert!(Codex.expresses(Capability::Write));
        assert_eq!(
            codex_capability_args(Capability::Basic),
            codex_capability_args(Capability::Read)
        );
    }
}
