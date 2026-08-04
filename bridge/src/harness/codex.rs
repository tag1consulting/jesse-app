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

// ---- The provider seam: a non-OpenAI model on an OpenAI-style endpoint ------------
//
// Codex is an OPENAI-STYLE AGENT LOOP, not OpenAI's agent loop, and this is the whole of the
// difference. Everything above assumes the bridge's own subscription login and OpenAI's own
// endpoint; everything here is what a model reaches instead when it names one.
//
// WHY THIS IS RUST AND NOT CONFIG. Before this, a Codex model's `base_url`, `model` and
// `auth_token_env` were INERT: auth came from `~/.codex/auth.json`, the endpoint came with
// it, and `base_url` existed only so the startup health probe had something to POST at. The
// deployed `codex` entry says exactly that in a comment. So pointing Codex at Kimi could not
// be a config edit — there was no code that read those fields on the turn path at all. What
// this adds is the READING of them, once; adding the NEXT OpenAI-style model is a config edit
// plus one env var for its token, which is the rule the whole effort runs on.
//
// NO FOURTH CONFIG KEY. The three fields that were inert become load-bearing, selected by the
// kind the entry already declares ([`ModelKind::OpenAi`]). `base_url` becomes the provider's
// API ROOT, `model` becomes the slug the child asks for, and `auth_token_env` names where the
// bridge reads the key — as it already did for every other model.

/// The provider id the bridge writes its own provider definition under. Bridge-owned, so it
/// cannot collide with a provider an operator defined: `--ignore-user-config` means the child
/// starts from no `config.toml` at all and this is the only provider it has ever heard of.
pub const CODEX_PROVIDER_ID: &str = "jesse";

/// The environment variable the child reads its provider API key from.
///
/// **This is why the key is not in the argv**, and that is the point of the name existing at
/// all rather than the harness passing the token as a `-c` value. A `-c` override is a
/// command-line ARGUMENT: it is visible in `ps` to every process on the host, it lands in a
/// crash dump, and Codex echoes its own effective config into its logs. Codex's providers
/// take an `env_key` naming a variable precisely so the secret travels out of band, and the
/// harness sets that variable on the child.
///
/// A FIXED, bridge-owned name rather than the model's own `auth_token_env`: the harness is
/// handed a resolved TOKEN by the registry, not the name of the variable it came from, and
/// inventing a way to thread the name through would buy nothing — the child needs a variable
/// with the key in it, not a particular spelling of one.
pub const CODEX_PROVIDER_KEY_ENV: &str = "JESSE_CODEX_PROVIDER_KEY";

/// The wire protocol the provider is declared with.
///
/// **`responses`, and there is no longer a choice.** codex-cli 0.146.0 REMOVED
/// `wire_api = "chat"` — it is a hard config error naming its own removal ("`wire_api =
/// \"chat\"` is no longer supported"), verified against the pinned binary. So an
/// OpenAI-style provider is reachable through this harness only if it serves the
/// **Responses API**; a provider that offers `/v1/chat/completions` and nothing else cannot
/// be driven by this harness at all, whatever the config says. Fireworks serves
/// `/inference/v1/responses` (verified live, 2026-08-04), which is what makes Kimi reachable.
///
/// Not a config key, deliberately: with one accepted value a key would only let an operator
/// choose the value that fails.
const CODEX_WIRE_API: &str = "responses";

/// The `-c` overrides that point a Codex turn at a model's OWN provider, or `None` for the
/// subscription-OAuth posture (which is every Codex turn that came before this).
///
/// `None` — meaning "change nothing" — for anything but a [`ModelKind::OpenAi`] model with a
/// resolved backend, and both halves of that condition matter. The kind is what distinguishes
/// the two postures: the DEPLOYED `codex` entry is `kind = "hosted"` and armed with a token
/// env var (it has to be, or it would not be selectable), so keying off "has a backend" alone
/// would have silently repointed a running production model at its own health-probe URL. And
/// an unarmed entry has no key to give the child, so it falls through to the OAuth path and
/// fails with Codex's own "not logged in" rather than with a provider missing its key.
///
/// THE TOKEN IS NOT IN THE RETURNED ARGV. Only the NAME [`CODEX_PROVIDER_KEY_ENV`] is; the
/// value is put on the child's environment by [`Codex::command`]. Anything that logs, records
/// or compares this argv — and the containment record does exactly that — is therefore safe
/// to write down. See the pinning test.
pub fn codex_provider_args(active: &ActiveModel) -> Option<Vec<String>> {
    if !matches!(active.kind, ModelKind::OpenAi) {
        return None;
    }
    let (base_url, _token, model) = active.env.as_ref()?;
    let p = CODEX_PROVIDER_ID;
    Some(vec![
        "-c".to_string(),
        format!("model_providers.{p}.name={}", toml_string(p)),
        "-c".to_string(),
        format!("model_providers.{p}.base_url={}", toml_string(base_url)),
        "-c".to_string(),
        format!("model_providers.{p}.wire_api={}", toml_string(CODEX_WIRE_API)),
        "-c".to_string(),
        format!(
            "model_providers.{p}.env_key={}",
            toml_string(CODEX_PROVIDER_KEY_ENV)
        ),
        "-c".to_string(),
        format!("model_provider={}", toml_string(p)),
        "-c".to_string(),
        format!("model={}", toml_string(model)),
    ])
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

/// Build a fresh per-turn `CODEX_HOME`, seeded with a COPY of the canonical credential when
/// `seed_credential` is set.
///
/// This is the mechanism the whole isolation argument rests on, so it does exactly two
/// things and nothing else: make a directory nothing else writes to, and put a copy of
/// `auth.json` in it. It never writes a `config.toml` — the posture travels on the command
/// line, where it cannot be edited by anything between turns.
///
/// A missing canonical credential is NOT an error here: the directory is still made, the
/// child still spawns, and it fails with Codex's own "not logged in" message, which is a far
/// better operator signal than this function inventing one.
///
/// # `seed_credential = false`, and why it NARROWS the posture
///
/// A model on its own provider ([`codex_provider_args`]) authenticates from
/// [`CODEX_PROVIDER_KEY_ENV`] and never reads `auth.json`, so copying the subscription
/// credential into its home would put a live OAuth token — for a DIFFERENT provider — inside
/// the reach of a turn that has no use for it. The read surface documented at the top of this
/// file (`read_agent_credential`'s decoy is reachable in principle, because the credential is
/// deliberately in the per-turn home) is therefore ABSENT on this path rather than accepted:
/// there is nothing in the home to read. Verified live — every provider turn in this change's
/// evidence ran with an empty per-turn home and authenticated fine.
///
/// This only ever removes a file from the child's reach, so no containment row it was probed
/// against can be widened by it.
pub fn codex_turn_home(cfg: &Config, seed_credential: bool) -> std::io::Result<PathBuf> {
    let base = codex_home_base(cfg);
    std::fs::create_dir_all(&base)?;
    let dir = base.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&dir)?;
    let auth = codex_canonical_home(cfg).join("auth.json");
    if seed_credential && auth.is_file() {
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
    provider_args: &[String],
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
    // AFTER the containment flags, so a provider definition is visibly not part of the
    // boundary — and empty for every turn on the subscription login, which is what keeps
    // that turn's argv byte-for-byte what it was.
    args.extend_from_slice(provider_args);

    // The prompt is positional and LAST, so nothing after it can be read as a flag.
    args.push(prompt.to_string());
    args
}

impl Codex {
    /// Build one child `Command`: a fresh per-turn `CODEX_HOME`, the capability's sandbox
    /// posture, the translated MCP set, the model's own provider (if it names one), piped
    /// stdio and `kill_on_drop`.
    pub fn command(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError> {
        let mcp = codex_mcp_args(CODEX_ID, req.mcp_config)?;
        // `None` for the subscription-OAuth posture, which is every turn that came before
        // this and still the deployed one. See [`codex_provider_args`].
        let provider = codex_provider_args(req.active);
        // A provider turn authenticates from the environment, so it gets a home with NO
        // credential in it at all — see [`codex_turn_home`].
        let home = codex_turn_home(cfg, provider.is_none()).map_err(|e| {
            HarnessError::unsupported(CODEX_ID, format!("a per-turn home directory ({e})"))
        })?;
        let mut cmd = Command::new(&cfg.codex_bin);
        cmd.args(build_codex_args(
            req.prompt,
            req.session_id,
            req.capability,
            &req.cwd,
            &mcp,
            provider.as_deref().unwrap_or_default(),
        ))
        .current_dir(&req.cwd)
        .env("CODEX_HOME", &home)
        // CLOSED, and this is load-bearing rather than tidiness. `codex exec` reads STDIN
        // and appends what it finds to the prompt — it announces "Reading additional input
        // from stdin..." and blocks until EOF. Inheriting the bridge's stdin therefore makes
        // every Codex turn hang until the driver's timeout kills it, unless the parent's
        // stdin happens to be at EOF already.
        //
        // Under launchd it happens to be `/dev/null`, so the deployed bridge got away with
        // it; run the same binary from a terminal, from a test harness, or under any
        // supervisor that hands it a pipe, and every turn takes the full timeout and returns
        // a 504. Observed exactly that: the same live turn passed in 19s with stdin at EOF
        // and timed out at 300s with a pipe on it.
        //
        // Null rather than piped-and-dropped so there is no closing to forget, and set HERE
        // rather than at the call sites because it is a property of this CLI. Claude Code
        // takes its prompt as an argument and never reads stdin, which is why it has no
        // equivalent line and does not need one.
        //
        // NO UNIT TEST GUARDS THIS, and that is a limitation rather than an oversight.
        // `std::process::Command` exposes no getter for a configured stdin, and a spawn-based
        // test would inherit `cargo test`'s stdin, which is already at EOF — so it would pass
        // with this line and without it. That is precisely how the bug survived to be found
        // live. The regression cover is `tests/codex_live_turn.rs`, which took the full 300s
        // timeout before this line and ~15s after; it is `#[ignore]`d, so re-run it on the
        // machine being certified whenever this spawn changes.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
        // The provider's API key, OUT OF BAND. The argv above names the variable; this puts
        // the value in it, on this child only, so the secret never reaches a process listing,
        // a log, or the recorded argv. See [`CODEX_PROVIDER_KEY_ENV`].
        if provider.is_some() {
            if let Some((_, token, _)) = req.active.env.as_ref() {
                cmd.env(CODEX_PROVIDER_KEY_ENV, token);
            }
        }
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

    /// TRUE: Codex speaks the OpenAI Responses API, so a [`ModelKind::OpenAi`] model may name
    /// it. That does not make every Codex model an OpenAI-kind one — the subscription-OAuth
    /// posture is `hosted` and names no provider; see [`codex_provider_args`].
    fn speaks_openai_backend(&self) -> bool {
        true
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

    /// The half of a Codex turn that never reaches the event stream.
    ///
    /// A sandbox-refused native tool call emits NO item event — no `item.started`, no
    /// `item.completed`, no error item. Its only trace is a `codex_core::tools` line here. A
    /// turn where the model tried to write and was refused therefore renders, on stdout alone,
    /// as a turn where nothing happened; the user sees a spinner, then an answer that quietly
    /// worked around a boundary they were never shown.
    ///
    /// The auth arm is corroboration rather than the primary signal — [`codex_failure`] catches
    /// the same 401 on the terminal `turn.failed` — and it earns its place because the two
    /// channels do not always both arrive. A child killed at the driver's timeout has written
    /// its stderr and no `turn.failed` at all.
    fn classify_stderr_line(&self, line: &str) -> Option<StderrSignal> {
        if let Some((tool, _msg)) = codex_refused_tool(line) {
            // The message is DELIBERATELY dropped: it carries the path or command the child
            // tried, and this signal reaches the user's screen. What they need is that a tool
            // call was refused, not which file the model was curious about.
            return Some(StderrSignal::ToolRefused {
                activity: ToolActivity::refused(tool),
            });
        }
        if line.contains("codex_api::endpoint") && is_auth_failure(line) {
            return Some(StderrSignal::AuthFailed {
                detail: one_line_trimmed(line, 200),
            });
        }
        None
    }

    fn stderr_classifier(&self) -> Box<dyn StderrClassifier> {
        Box::new(Codex)
    }
}

impl StderrClassifier for Codex {
    fn classify(&self, line: &str) -> Option<StderrSignal> {
        Harness::classify_stderr_line(self, line)
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
    /// The last `error` event's text, kept only as a fallback cause for a `turn.failed` that
    /// carried none. See the `error` arm: these events are retry narration, not terminals.
    last_error: Option<String>,
}

/// Classify a terminal Codex failure message.
///
/// **An expired or revoked credential is not an upstream blip, and must not be retried like
/// one.** The bridge runs Codex off a subscription OAuth login whose per-turn copy can fail
/// to refresh; when it does, every Codex turn fails the same way at the same instant and
/// stays failing, because a daemon has no interactive `codex login` to fall back on. Three
/// driver attempts against dead credentials produce three identical 401s and a turn that took
/// three times as long to say so.
///
/// So a 401/403 is `Fatal` with an operator-facing message naming the remedy, and everything
/// else keeps the classification it had. `Retryable` is deliberately NOT returned for the
/// auth case even though the driver would honour it — the point is to stop retrying.
///
/// COUPLED WITH [`Codex::classify_stderr_line`], which recognises the SAME failure on the
/// other channel. Both exist because the failure is visible on both and the bridge must not
/// depend on which one arrives first: stdout carries it as a `turn.failed` message, stderr as
/// a `codex_api::endpoint` line. Change the recognised statuses in one and change them in the
/// other.
fn codex_failure(message: String) -> ClaudeOutcome {
    if is_auth_failure(&message) {
        return ClaudeOutcome::Fatal {
            message: auth_failure_message(CODEX_ID, &one_line_trimmed(&message, 200)),
        };
    }
    ClaudeOutcome::Fatal { message }
}

/// Whether a Codex failure message names an authentication failure.
///
/// Matched on the HTTP status rather than on prose, because the prose around it is a moving
/// target (it carried a `cf-ray` and a `request id` on 0.145.0) while the status is the
/// contract. Both statuses mean the same thing for a daemon: no credential the child holds
/// will work, and no amount of retrying changes that.
fn is_auth_failure(message: &str) -> bool {
    message.contains("401 Unauthorized") || message.contains("403 Forbidden")
}

/// One line, trimmed to `max` chars — for folding a child's own words into a bridge message
/// without letting a multi-line log blow up an error string.
fn one_line_trimmed(s: &str, max: usize) -> String {
    let flat: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    flat.chars().take(max).collect()
}

/// A stderr line reporting a native tool call the sandbox REFUSED, as `(tool, message)`.
///
/// `None` for every other line. The match is on the `codex_core::tools` target plus an
/// `error=` field, which is the shape a rejected tool call takes; the tool is named in the
/// bridge's own vocabulary (a patch is how Codex writes a file, so it is `Write`) rather than
/// in Codex's, so one activity vocabulary serves both harnesses.
///
/// COUPLED WITH [`crate::parse_codex_trace`], which reads the same lines to score the
/// containment battery. They must agree about what a refusal LOOKS LIKE or the battery will
/// record an attempt the turn path renders as nothing having happened — the exact asymmetry
/// this function was extracted to remove. One matcher, two callers.
pub fn codex_refused_tool(line: &str) -> Option<(&'static str, &str)> {
    let idx = line.find("error=")?;
    if !line.contains("codex_core::tools") {
        return None;
    }
    let msg = line[idx + "error=".len()..].trim();
    let tool = if msg.starts_with("patch") { "Write" } else { "Bash" };
    Some((tool, msg))
}

impl TurnParser for CodexParser {
    fn on_line(&mut self, line: &str) -> StreamEvent {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            // Codex prints a couple of non-JSON banner lines before the stream proper.
            return StreamEvent::Ignore;
        };
        match v.get("type").and_then(|t| t.as_str()).unwrap_or_default() {
            // Reported to the driver as well as remembered, and the reporting is the part
            // that matters. `turn.completed` carries the thread id too, but it only arrives
            // on SUCCESS — a turn that dies mid-flight would bind nothing, and the next turn
            // on that conversation would silently start a fresh Codex thread instead of
            // resuming. `thread.started` is the FIRST event of the stream, so a turn that
            // fails has still said which thread it owns. This is the same reason Claude Code
            // reports its id from `system`/`init` rather than from the terminal line; see
            // [`StreamEvent::SessionId`].
            //
            // Codex has no transcript on disk, so this id is the WHOLE record of the thread:
            // `resolve_resume_session_for_harness` skips the existence check for a harness
            // with no transcript dir, and there is nothing else to recover it from.
            "thread.started" => match v.get("thread_id").and_then(|t| t.as_str()) {
                Some(id) => {
                    self.thread_id = Some(id.to_string());
                    StreamEvent::SessionId(id.to_string())
                }
                None => StreamEvent::Ignore,
            },
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
                        StreamEvent::ToolActivity(ToolActivity::used("Bash"))
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
                        StreamEvent::ToolActivity(ToolActivity::used(format!(
                            "mcp__{server}__{tool}"
                        )))
                    }
                    "file_change" if v["type"] == "item.started" => {
                        StreamEvent::ToolActivity(ToolActivity::used("Edit"))
                    }
                    _ => StreamEvent::Ignore,
                }
            }
            "turn.completed" => StreamEvent::Done(ClaudeOutcome::Ok {
                result: self.message.clone().unwrap_or_default(),
                session_id: self.thread_id.clone(),
                usage: codex_usage(v.get("usage")),
            }),
            // NOT TERMINAL, and treating it as terminal was a live bug rather than a
            // hypothetical. Codex emits `error` as RETRY NARRATION while it reconnects
            // internally — verified on 0.145.0, where one dead credential produced six of
            // them ("Reconnecting... 2/5" … "5/5", then a bare one) before the real terminal
            // event. Ending the turn on the first one abandoned a child that still had four
            // attempts left, and reported "Reconnecting... 2/5" as the failure cause, which
            // names the retry rather than the fault.
            //
            // `turn.failed` is the terminal event and it carries the final message. So this
            // arm REMEMBERS the last error text and emits nothing; the terminal arm below
            // uses it only if `turn.failed` somehow carried none.
            "error" => {
                if let Some(m) = v.get("message").and_then(|m| m.as_str()) {
                    self.last_error = Some(m.to_string());
                }
                StreamEvent::Ignore
            }
            "turn.failed" => {
                let message = v
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .map(str::to_string)
                    .or_else(|| self.last_error.clone())
                    .unwrap_or_else(|| "codex reported a turn failure".to_string());
                StreamEvent::Done(codex_failure(message))
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

    // ---- The provider seam ---------------------------------------------------------

    /// A model on its OWN OpenAI-style provider, as a deploy would declare it.
    fn openai_model(base_url: &str, model: &str, token: &str) -> ActiveModel {
        let mut m = ActiveModel::ambient();
        m.id = "kimi-k3-codex".to_string();
        m.kind = ModelKind::OpenAi;
        m.harness = CODEX_ID.to_string();
        m.level = Capability::Read;
        m.env = Some((base_url.to_string(), token.to_string(), model.to_string()));
        m
    }

    /// A `Config` whose codex homes land in a scratch directory rather than the operator's
    /// real state dir — these tests BUILD children, and building one makes a home. Returns
    /// the directory so the test can remove it.
    fn scratch_config(tag: &str) -> (Config, PathBuf) {
        let dir = std::env::temp_dir().join(format!("jesse-codex-{tag}-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let mut cfg = test_config();
        cfg.state_dir = Some(dir.to_string_lossy().into_owned());
        (cfg, dir)
    }

    /// THE WHOLE SEAM, in one assertion set: the three fields that were inert become the
    /// provider, the wire, and the slug — and **the token is not among them**.
    ///
    /// The last clause is the one worth failing a build over. A `-c` override is a command
    /// line argument, visible in `ps` to every process on the host; the key travels in the
    /// environment and the argv carries only the NAME of the variable. Everything that logs
    /// or records an argv depends on that being true.
    #[test]
    fn an_openai_model_names_its_provider_and_never_its_token() {
        let m = openai_model(
            "https://api.example/inference/v1",
            "accounts/example/models/k3",
            "sk-super-secret",
        );
        let args = codex_provider_args(&m).expect("an openai-kind model names a provider");
        let joined = args.join(" ");

        assert!(joined.contains("model_provider=\"jesse\""), "{joined}");
        assert!(
            joined.contains("model_providers.jesse.base_url=\"https://api.example/inference/v1\""),
            "{joined}"
        );
        assert!(
            joined.contains("model_providers.jesse.wire_api=\"responses\""),
            "codex-cli 0.146.0 removed `chat`; `responses` is the only wire left: {joined}"
        );
        assert!(
            joined.contains("model_providers.jesse.env_key=\"JESSE_CODEX_PROVIDER_KEY\""),
            "{joined}"
        );
        assert!(
            joined.contains("model=\"accounts/example/models/k3\""),
            "the slug is load-bearing now, not inert: {joined}"
        );
        assert!(
            !joined.contains("sk-super-secret"),
            "THE TOKEN REACHED THE ARGV, where `ps` can read it: {joined}"
        );
    }

    /// THE DEPLOYED POSTURE IS UNTOUCHED, and this is the test that says so.
    ///
    /// The live `codex` entry is `kind = "hosted"` and IS armed with a token env var — it has
    /// to be, or the registry would not call it configured and the picker would not offer it.
    /// So "does this model have a resolved backend?" is true for it, and keying the seam off
    /// that alone would have silently repointed a running production model at its own
    /// health-probe URL. The kind is the discriminator; this pins that it is.
    #[test]
    fn an_armed_oauth_codex_model_gets_no_provider_at_all() {
        for kind in [ModelKind::Hosted, ModelKind::Local, ModelKind::Ambient] {
            let mut m = openai_model("http://127.0.0.1:9100", "gpt-5-codex", "tok");
            m.kind = kind;
            assert_eq!(
                codex_provider_args(&m),
                None,
                "{kind:?} is an Anthropic-surface kind and must keep the OAuth posture"
            );
        }
        // …and an OpenAI-kind entry whose token env var was never set has no key to give the
        // child, so it falls through to OAuth and fails with Codex's own "not logged in"
        // rather than with a provider missing its key.
        let mut unarmed = openai_model("https://api.example/v1", "m", "t");
        unarmed.env = None;
        assert_eq!(codex_provider_args(&unarmed), None);
    }

    /// The argv of a turn on the subscription login is BYTE-FOR-BYTE what it was: an empty
    /// provider list appends nothing. The seam is additive or it is a regression.
    #[test]
    fn the_oauth_argv_is_unchanged_by_the_seam() {
        let plain = build_codex_args("hi", None, Capability::Read, Path::new("/v"), &[], &[]);
        assert!(
            !plain.iter().any(|a| a.contains("model_provider")),
            "{plain:?}"
        );
        assert_eq!(plain.last().map(String::as_str), Some("hi"));
    }

    /// The provider overrides land BEFORE the prompt — the prompt is positional and must stay
    /// last, or a `-c` after it is read as the prompt and the real prompt as a stray argument.
    #[test]
    fn the_prompt_stays_last_behind_the_provider_overrides() {
        let m = openai_model("https://api.example/v1", "slug", "tok");
        let provider = codex_provider_args(&m).expect("a provider");
        let args = build_codex_args(
            "what is the cadence?",
            None,
            Capability::Read,
            Path::new("/v"),
            &[],
            &provider,
        );
        assert_eq!(args.last().map(String::as_str), Some("what is the cadence?"));
        let last_c = args.iter().rposition(|a| a == "-c").expect("a -c override");
        assert!(last_c < args.len() - 1, "{args:?}");
    }

    /// The key travels in the ENVIRONMENT of the child, and the per-turn home a provider turn
    /// gets holds NO credential — there is nothing in it to read.
    ///
    /// The second half is the containment half. The read surface this harness accepts
    /// (`read_agent_credential`'s decoy is reachable because the OAuth copy is deliberately in
    /// the home) is ABSENT on the provider path rather than tolerated there.
    #[test]
    fn a_provider_turn_carries_the_key_in_the_env_and_no_credential_on_disk() {
        let (cfg, dir) = scratch_config("provider-env");
        let m = openai_model("https://api.example/v1", "slug", "sk-super-secret");
        let req = TurnRequest {
            prompt: "hi",
            session_id: None,
            active: &m,
            capability: Capability::Read,
            cwd: std::env::temp_dir(),
            mcp_config: EMPTY_MCP_CONFIG,
        };
        let cmd = Codex.build_turn(&cfg, &req).expect("a provider child");

        let env: std::collections::HashMap<String, String> = cmd
            .as_std()
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect();
        assert_eq!(
            env.get(CODEX_PROVIDER_KEY_ENV).map(String::as_str),
            Some("sk-super-secret"),
            "the child must be able to authenticate: {:?}",
            env.keys().collect::<Vec<_>>()
        );

        let home = PathBuf::from(env.get("CODEX_HOME").expect("a per-turn home"));
        assert!(home.is_dir(), "the home is made even with no credential in it");
        assert!(
            !home.join("auth.json").exists(),
            "a provider turn authenticates from the environment; copying the subscription \
             credential into its home would put a live OAuth token for a DIFFERENT provider \
             inside a turn that has no use for it"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- The mid-turn event contract ----------------------------------------------

    /// A refused native tool call reaches the ACTIVITY channel, not the failure channel, and
    /// carries no trace of what the child was reaching for.
    ///
    /// The redaction is the load-bearing half. The child's own error line names the path it
    /// tried to write, and this value is broadcast to a phone; a vault path is exactly the
    /// sort of thing a prompt-injected turn would like to see echoed back on screen.
    #[test]
    fn a_sandbox_refusal_becomes_redacted_tool_activity() {
        let line = "2026-08-03T09:12:01Z ERROR codex_core::tools::router: \
                    error=patch rejected: writing is blocked by read-only sandbox \
                    (/vault/notes/private/salary.md)";
        let Some(StderrSignal::ToolRefused { activity }) = Codex.classify_stderr_line(line)
        else {
            panic!("a codex_core::tools error line is a refusal");
        };
        assert_eq!(activity, ToolActivity::refused("Write"));
        assert!(
            !activity.name.contains("salary") && !activity.name.contains('/'),
            "the refusal must not carry the path the child tried: {activity:?}"
        );
    }

    /// A shell refusal is a `Bash`, and ordinary log noise is nothing. The second half is
    /// what keeps the activity line honest — a classifier that fired on every stderr line
    /// would turn Codex's startup banner into a stream of phantom tool calls.
    #[test]
    fn only_a_tools_error_line_is_a_refusal() {
        let shell = "ERROR codex_core::tools::router: error=command rejected by sandbox";
        assert_eq!(
            Codex.classify_stderr_line(shell),
            Some(StderrSignal::ToolRefused {
                activity: ToolActivity::refused("Bash")
            })
        );
        for noise in [
            "INFO codex_core::config: loaded 0 user config files",
            "DEBUG codex_core::tools::router: dispatching shell",
            "ERROR codex_exec::event: error=something else entirely",
            "",
        ] {
            assert_eq!(
                Codex.classify_stderr_line(noise),
                None,
                "not a refusal: {noise:?}"
            );
        }
    }

    /// Claude Code keeps the `None` default, so registering a harness whose stderr IS
    /// load-bearing changed nothing about the harness whose stderr is not.
    #[test]
    fn claude_code_reads_nothing_off_stderr() {
        for line in [
            "ERROR codex_core::tools::router: error=patch rejected",
            "some claude stderr",
        ] {
            assert_eq!(ClaudeCode.classify_stderr_line(line), None);
        }
    }

    /// The item events a whole-answer turn emits between `thread.started` and
    /// `turn.completed`, in the ONE vocabulary both harnesses share — this is the contract
    /// at the top of `harness/mod.rs`, pinned.
    #[test]
    fn mid_turn_items_map_onto_the_shared_activity_vocabulary() {
        let mut p = CodexParser::default();
        let cases = [
            (
                r#"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#,
                ToolActivity::used("Bash"),
            ),
            (
                r#"{"type":"item.started","item":{"type":"file_change","path":"/x"}}"#,
                ToolActivity::used("Edit"),
            ),
            (
                r#"{"type":"item.started","item":{"type":"mcp_tool_call","server":"qmd","tool":"query"}}"#,
                ToolActivity::used("mcp__qmd__query"),
            ),
        ];
        for (line, want) in cases {
            match p.on_line(line) {
                StreamEvent::ToolActivity(a) => assert_eq!(a, want),
                other => panic!("{line} should be activity, got {other:?}"),
            }
        }
        // `item.completed` is the SAME item finishing. Emitting activity again would double
        // every tool call on screen, so only `item.started` counts.
        assert!(matches!(
            p.on_line(r#"{"type":"item.completed","item":{"type":"command_execution"}}"#),
            StreamEvent::Ignore
        ));
        // The answer accumulates; it is not a mid-turn event even though it arrives mid-turn.
        assert!(matches!(
            p.on_line(r#"{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}"#),
            StreamEvent::Ignore
        ));
    }

    // ---- Credential failure -------------------------------------------------------

    /// A dead daemon credential is `Fatal` with an operator-facing message, NOT `Retryable`.
    ///
    /// Retrying is the wrong reflex and the expensive one: there is no interactive
    /// `codex login` on a bridge host, so three attempts produce three identical 401s and a
    /// turn that took three times as long to say the same thing.
    #[test]
    fn a_dead_credential_is_fatal_and_names_the_remedy() {
        let mut p = CodexParser::default();
        let out = p.on_line(
            r#"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: token expired"}}"#,
        );
        let StreamEvent::Done(ClaudeOutcome::Fatal { message }) = out else {
            panic!("401 must be Fatal, not Retryable — got {out:?}");
        };
        assert!(message.contains(CODEX_ID), "names the harness: {message}");
        assert!(
            message.contains("re-authenticate"),
            "names the remedy: {message}"
        );
        assert!(
            message.contains("other harnesses are unaffected"),
            "says the blast radius is one harness, not the bridge: {message}"
        );
    }

    /// The same failure on the other channel, worded identically. The two exist because a
    /// child killed at the driver's timeout has written its stderr and no `turn.failed`.
    #[test]
    fn the_same_401_is_recognised_on_stderr() {
        let line = "ERROR codex_api::endpoint: request failed: 401 Unauthorized (cf-ray abc)";
        let Some(StderrSignal::AuthFailed { detail }) = Codex.classify_stderr_line(line) else {
            panic!("a 401 on codex_api::endpoint is an auth failure");
        };
        assert!(detail.contains("401 Unauthorized"));
        // Both channels reach the operator through one wording.
        assert_eq!(
            auth_failure_message(CODEX_ID, &detail),
            auth_failure_message(CODEX_ID, &detail)
        );
    }

    /// An ordinary upstream failure keeps its own message: the auth arm must not swallow
    /// everything that failed.
    #[test]
    fn an_ordinary_failure_is_not_dressed_up_as_an_auth_failure() {
        let mut p = CodexParser::default();
        let out = p.on_line(r#"{"type":"turn.failed","error":{"message":"model overloaded"}}"#);
        let StreamEvent::Done(ClaudeOutcome::Fatal { message }) = out else {
            panic!("got {out:?}");
        };
        assert_eq!(message, "model overloaded");
    }

    /// `error` is RETRY NARRATION, not a terminal event — treating it as terminal abandoned a
    /// child that still had attempts left and reported "Reconnecting… 2/5" as the cause.
    #[test]
    fn error_events_are_narration_and_the_last_one_is_only_a_fallback_cause() {
        let mut p = CodexParser::default();
        for n in 2..=5 {
            assert!(
                matches!(
                    p.on_line(&format!(
                        r#"{{"type":"error","message":"Reconnecting... {n}/5"}}"#
                    )),
                    StreamEvent::Ignore
                ),
                "an error event must not end the turn"
            );
        }
        // A `turn.failed` carrying no message of its own falls back to the last narration.
        let StreamEvent::Done(ClaudeOutcome::Fatal { message }) =
            p.on_line(r#"{"type":"turn.failed"}"#)
        else {
            panic!("turn.failed is terminal");
        };
        assert_eq!(message, "Reconnecting... 5/5");
    }

}
