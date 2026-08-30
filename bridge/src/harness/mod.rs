use crate::*;

mod claude_code;
pub use claude_code::*;

mod codex;
pub use codex::*;

mod direct;
pub use direct::*;

// ---- The agent program, behind three traits ---------------------------------
//
// An agent program answers a turn. HOW it is reached is a second question, and until now
// there was only one answer: spawn a child, read its stdout. That assumption was spread
// across one trait, so every method on it silently meant "…of the child process". Three
// traits now say which half of that a method belongs to:
//
//   * [`Harness`] — IDENTITY AND POLICY. Everything true of a harness whether or not a
//     process is involved: its id, whether it streams, which capabilities it expresses,
//     its containment flags and shipped rows, its transcript layout, its attachment
//     support, its default concurrency, whether it can take the vault write lock, and
//     which API wire it drives a model over. Every harness implements this one.
//   * [`SpawnedHarness`] — everything that only means something for a CHILD PROCESS:
//     building the `Command`, parsing a line of its stdout, its main MCP server set,
//     classifying a line of its stderr, and reading its hook payloads.
//   * [`InProcessHarness`] — the other runner shape: a harness that answers the turn
//     inside this process, with no child at all. Nothing implements it yet; its contract
//     is written down so D5 implements a shape that was decided rather than discovered.
//
// [`Harness::runner`] is the ONE branch: it returns a [`Runner`] naming which of the two
// shapes this harness is, and the driver in [`crate::claude`] branches on it exactly once.
// Every other call site that needs a spawned-only method asks the same question and
// handles the in-process case explicitly — never with a silent default, because a silent
// default here means spawning nothing and reporting success.
//
// NOT HARNESS-SPECIFIC either way — the driver: for a spawned harness, spawn, read stdout
// line by line, stop at the terminal result, bounded reap, resolve the outcome, retry a
// transient failure up to three attempts with a stream reset between them; for an
// in-process one, await its future. That stays in [`crate::claude`] and calls through
// `&dyn Harness`.
//
// ---- THE MID-TURN EVENT CONTRACT --------------------------------------------
//
// WHAT A HARNESS OWES BETWEEN "I STARTED" AND "I FINISHED". Written here rather than
// left implicit because Codex is the FIRST harness whose answer arrives whole, and there
// is no second one to check the shape against — so the shape is stated, not inferred from
// the one implementation that has it.
//
// **THE CONTRACT IS IDENTICAL FOR BOTH RUNNER SHAPES.** A [`SpawnedHarness`] delivers these
// events by returning them from its [`TurnParser`] as it reads the child's stdout; an
// [`InProcessHarness`] delivers exactly the same two, in the same vocabulary, by calling
// [`TurnSink`]. Same events, same meanings, same prohibitions — the runner shape decides
// how they travel, never what may travel. That is the whole reason the contract is written
// here, above both traits, rather than in the one that happens to exist first: an
// in-process harness that invented a third mid-turn event, or smuggled a tool RESULT into
// an activity name, would be breaking the same rule a spawned one would.
//
// The bridge's mid-turn vocabulary is exactly TWO things, and a harness emits some mixture
// of them per turn:
//
//   * [`StreamEvent::TextDelta`] — a chunk of the visible answer. A harness emits these
//     only if [`Harness::streams_text`] is true. Codex's is FALSE and that is not a defect
//     to route around: its `--json` stream carries no token-level delta for the visible
//     answer at all, only whole items.
//   * [`StreamEvent::ToolActivity`] — a coarse "the child is doing X" hint. Named in ONE
//     vocabulary across harnesses (`Bash`, `Edit`, `Read`, `mcp__<server>__<tool>`), so
//     the clients' one `activityLabel` switch serves both. Carries a `refused` bit; see
//     [`ToolActivity`].
//
// A WHOLE-ANSWER HARNESS THEREFORE OWES TOOL ACTIVITY, and owes it as its ONLY mid-turn
// signal. A streaming harness's activity line is a garnish — deltas are already arriving,
// so a missed activity event costs nothing. On a whole-answer harness the activity line is
// the entire difference between a turn the user can see working and a turn that is
// indistinguishable from one that has silently hung. The spinner (keyed off
// `ModelInfo.streamsText`) says "this model replies all at once"; the activity line is the
// only thing that says what it is doing while it does.
//
// Concretely, for Codex, between `thread.started` and `turn.completed`:
//   * `item.started` with a `command_execution` item  → `Bash`
//   * `item.started` with a `file_change` item        → `Edit`
//   * `item.started` with an `mcp_tool_call` item     → `mcp__<server>__<tool>`
//   * a `codex_core::tools` line ON STDERR            → the same, with `refused` set
//   * `item.completed` with an `agent_message` item   → accumulated, NOT emitted mid-turn
//
// THE LAST TWO ARE THE ONES A NEXT READER WILL GET WRONG. The agent_message is not a
// mid-turn event even though it arrives mid-turn: Codex emits a short preamble message
// before it starts calling tools, and delivering that as the answer is a bug the parser
// already guards against (last one wins). And the refusal is not on stdout at all — see
// below.
//
// STDERR IS PART OF THE CONTRACT, AND THAT WAS A DECISION. A sandbox-refused native tool
// call emits NO item event on Codex's `--json` stream: no `item.started`, no
// `item.completed`, no error item. The only trace is a `codex_core::tools` line on stderr.
// The alternative — declaring that refused tool calls are simply invisible — was rejected
// because on a READ-ONLY harness a refusal is not an edge case: it is the boundary doing
// its job, on a turn the model expected to be able to write. A user watching a turn work
// around a boundary they were never shown has been told something false about what
// happened. So the contract consumes stderr, via [`SpawnedHarness::classify_stderr_line`],
// and the cost is that ONE harness's stderr is load-bearing rather than log noise. Claude
// Code takes the `None` default and is byte-for-byte unaffected. An in-process harness has
// no stderr at all, which is exactly why that method is on the spawned trait and not on
// the shared one.
//
// WHAT IS STILL NOT IN THE CONTRACT, deliberately: tool RESULTS, tool INPUTS, token
// counts, and any per-tool timing. All of them would reach a phone screen, all of them
// carry vault content or the model's guesses about it, and none of them is needed to
// answer "is this turn alive". A harness must not smuggle them into an activity name.
//
// TWO harnesses are registered, and the serving one is chosen by the MODEL — see
// [`HarnessRegistry::serving`]. `claude-code` remains unconditionally constructible and is
// the fallback for every path with no model in hand; that is the ambient assumption the
// registry always carried, kept rather than widened.

/// What a child agent is allowed to do, as ONE ordered vocabulary shared by every place
/// the bridge spawns one. Ordered and CUMULATIVE: `Write` implies `Read` implies `Basic`,
/// so the derived `PartialOrd` is meaningful — `a >= b` reads "a is at least as capable as
/// b" and is the right comparison wherever two capabilities meet.
///
/// Today the enum has ONE use: naming what a child is GRANTED, which each harness maps to
/// the containment flags that enforce it (for Claude Code, [`claude_capability_args`]). The
/// ordering is derived now anyway, because a capability is a general statement about
/// ability rather than a per-call-site flag: a second use (a model declaring the CEILING it
/// may be trusted with, taken against the grant) speaks the same vocabulary and needs the
/// comparison.
///
/// There is deliberately NO `Off` variant. A model is disabled by removing its registry
/// entry or unsetting its token env var — the configured-but-unarmed state the registry
/// already understands. "Must not run at all" is the absence of a model, not a containment
/// posture a spawned child could be given.
///
/// A capability covers the TOOLSET only. Two things a spawn site chooses independently are
/// deliberately NOT implied by it, and both ride in the [`TurnRequest`] instead:
///   * The **MCP server set**. The main turn requires qmd; the vault-QA child degrades to
///     no servers. Making that a property of `Read` would silently take vault search away
///     from a read-only turn — see [`TurnRequest::mcp_config`].
///   * The **working directory**. The `Basic` diet children run in the neutral scratch base
///     so the large vault `CLAUDE.md` cannot auto-load; the `Basic` title child runs in the
///     vault. Both are intentional, so do not unify them.
///
/// ---- THE AGENT CRATE'S `Level` IS THIS ENUM ---------------------------------
///
/// `agent/` (the provider-neutral agent layer, `jesse_agent`) declares its own
/// `tools::Level` with the same three names in the same order, because that crate does not
/// depend on the bridge in either direction and cannot re-export this one. D5 is where the
/// bridge adopts it; until then the mapping is written down here rather than left for
/// whoever writes the `From` impls to derive from two doc comments in different crates:
///
/// | `harness::Capability` | `jesse_agent::tools::Level` | means                        |
/// |-----------------------|-----------------------------|------------------------------|
/// | `Basic`               | `Level::Basic`              | no tools at all              |
/// | `Read`                | `Level::Read`               | reads and lookups, no writes |
/// | `Write`               | `Level::Write`              | the above plus vault writes  |
///
/// **THE MAPPING IS THE IDENTITY, AND THAT IS A DECISION, NOT A COINCIDENCE.** The agent
/// crate's own doc comment says the same thing from the other side: declaring a second,
/// differently-shaped vocabulary ("none / readonly / full") would make the mapping a table
/// somebody has to keep true, and a level that means slightly different things on two sides
/// of a boundary is how a `Read` turn ends up holding a write tool. Both enums derive
/// `Ord` and both orderings are load-bearing in the same way.
///
/// So when the dependency lands, the two `From` impls are three arms each and neither is
/// allowed to reorder, rename or collapse anything.
/// `the_capability_vocabulary_is_the_agent_crates_level_vocabulary` pins this side of it
/// today and asserts the other side under the `agent-vocabulary` feature, which is what
/// turns a comment into a build failure the moment the dependency exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Capability {
    /// No tools. Text in, text out.
    ///
    /// This names what the CHILD IS DOING, and nothing else. A `Basic` child is a
    /// single-shot text transformation: parse an utterance into JSON, check that JSON, write
    /// a short title. It is granted nothing because it needs nothing — it returns text, and
    /// the BRIDGE validates that text and does any writing.
    ///
    /// Whether a given harness can actually EXPRESS that as a posture is a separate question
    /// with a separate answer, and it is [`Harness::expresses`]. This doc comment used to end
    /// "that holds whatever model or harness serves the child", which was false: Codex's
    /// containment lever is an OS sandbox mode rather than a tool allowlist, there is no key
    /// that removes its shell, and so its weakest posture is byte-identical to `Read`. A
    /// level is not portable across harnesses merely because the enum is.
    Basic,
    /// Read and search. No writes, no exec.
    Read,
    /// May change the vault.
    Write,
}

/// The capability a MAIN turn is granted for the model backing it: **the minimum of the
/// model's level and [`Capability::Write`]**.
///
/// Half of the effective grant rule (the other half is [`RoutedJob::required`], which
/// governs work the user did not choose a model for). The level is a CEILING and this is
/// where it is taken against what a main turn needs: a `Write` model backing a conversation
/// gets `Write`, a `Read` model gets the read-only posture, and a `Basic` model gets `Basic`
/// — it can answer, with no tools, which is what its level says it may be trusted with.
///
/// The `min` is not decoration. A main turn never needs more than `Write`, so if a level
/// above `Write` is ever added this stays correct without being revisited. The boundary is
/// the toolset, not the prompt.
pub fn turn_capability(active: &ActiveModel) -> Capability {
    active.level.min(Capability::Write)
}

/// Everything a harness needs to build ONE child invocation. Exactly the inputs the
/// pre-trait argument builder took, plus the two things its call sites used to pass
/// separately to the `Command` after the fact.
///
/// The `cwd` and the `mcp_config` are here because both are CALL SITE policy, not harness
/// policy: the diet children run in a neutral scratch dir while the title child runs in the
/// vault, and the main path requires the qmd server while the vault-QA child degrades to
/// none. A harness reads them; it does not choose them.
pub struct TurnRequest<'a> {
    /// The whole prompt, already built and wrapped by the caller.
    pub prompt: &'a str,
    /// The thread to continue, when there is one. A harness that cannot resume (or one
    /// whose caller resolved the id away) simply starts fresh; the bridge re-keys its
    /// ledger from whatever id comes back.
    pub session_id: Option<&'a str>,
    /// The model backing this child: its `ANTHROPIC_*` backend triple, subagent model and
    /// price deck. [`ActiveModel::ambient`] for a child that inherits the process env (the
    /// caller then layers its own per-role override, e.g. `apply_diet_env`).
    pub active: &'a ActiveModel,
    /// What this child is GRANTED — the toolset boundary, and nothing else. See
    /// [`Capability`].
    pub capability: Capability,
    /// Where the child runs. Per call site: the vault (so `CLAUDE.md` auto-loads) for a
    /// turn, the title child and the vault-QA child; the neutral scratch base for the diet
    /// children, which must NOT auto-load the vault `CLAUDE.md`.
    pub cwd: PathBuf,
    /// The MCP server set this child may load, in the harness's own config format.
    ///
    /// **Capability governs the toolset; the request governs the servers.** They are two
    /// axes and collapsing them is the obvious-looking simplification that silently removes
    /// vault search: a `Read` child with qmd loaded (the main turn) and a `Read` child with
    /// no servers at all (the vault-QA child) are both legitimate, so the server set can be
    /// a property of neither the capability nor the harness. A harness with no MCP concept
    /// at all is exactly what [`HarnessError`] is for; Claude Code is not that harness, so
    /// nothing on this path constructs one — it consumes this field.
    pub mcp_config: &'a str,
    /// When set, this child must be spawned with the vault write lock's hooks installed,
    /// pointed at the broker named here.
    ///
    /// `None` for every child that cannot write the vault (the `Basic` diet and title
    /// one-shots, the read-only vault-QA child), because a lock on a turn that cannot write
    /// is pure overhead. `Some` for a write-level main turn whenever the broker is armed.
    ///
    /// The INSTALLATION is per harness and lives in [`Harness::build_turn`] — a settings file
    /// for Claude Code, a `hooks.json` in the per-turn home for Codex — which is why this is
    /// a request field the harness reads rather than argv the bridge assembles.
    pub write_lock: Option<&'a WriteLockChild>,
    /// **THE TURN'S OWN ID** — the bridge's job id.
    ///
    /// Spawned harnesses do not read it: a child is identified by its process and its session,
    /// and the bridge already correlates those. An IN-PROCESS harness has neither, so this is
    /// the key its usage records, its trace and its write locks are all filed under — which is
    /// what lets a usage line be matched to a turn timing record afterwards.
    ///
    /// It is on the REQUEST rather than derived inside the harness because only the caller
    /// knows it: a routed job and a main turn are both turns, and both already have a job id
    /// the rest of the bridge uses.
    pub turn_id: &'a str,
    /// The per-job artifact staging directory, when this turn may produce files.
    ///
    /// `None` for every turn below [`Capability::Write`] and for every deployment with the
    /// artifact channel off. Distinct from `attachment_dir` in both direction and lifetime:
    /// attachments come IN and are swept with the request, artifacts go OUT and are swept by
    /// the job when the turn ends.
    ///
    /// Spawned harnesses learn about it through the PROMPT (`artifact_prompt_suffix` names the
    /// directory to the model) and need nothing on their argv, which is why this field is
    /// additive for them — no child's command line changes because it exists. An in-process
    /// harness hands the path to the tool that writes there.
    pub artifact_dir: Option<&'a Path>,
    /// The per-request scratch directory this turn's decoded attachments were written to.
    ///
    /// CALL SITE POLICY, exactly like `cwd`: the bridge decided where to write the files, so
    /// the bridge is what knows the path. A harness reads it and decides what, if anything,
    /// its CLI must be told — Claude Code needs the directory added to the child's read
    /// scope, Codex's OS sandbox already leaves reads broad and needs nothing.
    ///
    /// `None` for every ordinary turn, which is nearly all of them: no attachments at all, or
    /// attachments that the VISION HELPER reads instead of the child. Those two routes are
    /// mutually exclusive and the gate is in `handlers` — when the helper serves the turn no
    /// scratch dir is written at all, so there is no directory to name here.
    pub attachment_dir: Option<&'a Path>,
}

/// Everything a child needs to talk to the write-lock broker.
///
/// Every field is baked into the hook COMMAND STRING the bridge writes into that child's
/// per-turn hook config, rather than passed through the environment. That is deliberate: it
/// costs nothing (the bridge is already writing a per-turn file) and it removes an assumption
/// about env inheritance through whatever process tree each CLI uses to run a hook.
pub struct WriteLockChild {
    /// The broker's unix socket, under the state dir.
    pub socket: PathBuf,
    /// This TURN's key — the job id. What [`crate::LockBroker::release_turn`] releases.
    pub turn: String,
    /// This CONVERSATION's id, which keys the compare-and-swap read baselines. Not the
    /// harness's own session id: a Codex turn gets a fresh `CODEX_HOME` every turn, so a
    /// baseline keyed on the harness's own state would not survive a resume.
    pub conversation: String,
    /// The `jesse-hook` helper binary, resolved once at startup.
    pub helper: PathBuf,
}

impl WriteLockChild {
    /// The hook command string for one event, as this harness's hook config will carry it.
    pub fn command(&self, harness: &str, event: &str) -> String {
        format!(
            "{} --harness {} --event {} --socket {} --turn {} --conversation {}",
            shell_quote(&self.helper.display().to_string()),
            harness,
            event,
            shell_quote(&self.socket.display().to_string()),
            shell_quote(&self.turn),
            shell_quote(&self.conversation),
        )
    }
}

/// Resolve a path from a hook payload into THE one key a lock is taken on.
///
/// Absolute-ise against the payload's `cwd`, then canonicalize so symlinks collapse. Both
/// halves are load-bearing and they close different holes:
///
///   * A Claude Code child names `/vault/notes/a.md` while a Codex child names `notes/a.md`
///     relative to the same cwd. Two spellings, one file — and without the join they would
///     take two different locks and protect nothing.
///   * The vault is reachable through at least one symlinked path on this host, and
///     `/tmp` is itself a symlink to `/private/tmp` on macOS. Canonicalizing collapses those
///     too.
///
/// A path that does not exist yet (the common case: a file being CREATED) cannot be
/// canonicalized, so its existing parent is canonicalized and the file name re-joined. That
/// keeps a create and a later overwrite of the same file on the same key.
pub fn resolve_lock_path(path: &Path, cwd: &str) -> PathBuf {
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(cwd).join(path)
    };
    if let Ok(real) = joined.canonicalize() {
        return real;
    }
    match (joined.parent(), joined.file_name()) {
        (Some(parent), Some(name)) => match parent.canonicalize() {
            Ok(real_parent) => real_parent.join(name),
            Err(_) => joined,
        },
        _ => joined,
    }
}

/// Single-quote one argument for a hook command string.
///
/// Both CLIs take a hook as a COMMAND STRING run through a shell, so a path with a space in
/// it would otherwise split into two arguments. None of these values contain a quote today
/// (they are a binary path, a state-dir path and two uuids), but the state dir is operator
/// configurable and a bridge that mangles its own lock wiring on a path with a space would
/// fail in the least debuggable way available.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// A harness refusing a request it cannot express, rather than quietly downgrading it.
/// The point is the refusal: a harness with no MCP concept, or no way to resume a thread,
/// must say so and let the turn fail visibly instead of silently spawning a child with a
/// weaker boundary than the caller asked for.
///
/// Nothing on the Claude Code path constructs one (the CLI expresses every request shape
/// the bridge makes), so today this type exists for the next harness.
#[derive(Debug, Clone, PartialEq)]
pub struct HarnessError {
    /// The harness that refused, by [`Harness::id`].
    pub harness: &'static str,
    /// What it could not express, in operator-facing words.
    pub what: String,
}

impl HarnessError {
    /// Refuse a request: `what` names the thing the harness cannot express (e.g. "an MCP
    /// server set" or "resuming a thread"), not the flag it would have passed.
    pub fn unsupported(harness: &'static str, what: impl Into<String>) -> Self {
        HarnessError {
            harness,
            what: what.into(),
        }
    }
}

impl std::fmt::Display for HarnessError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the {} harness cannot express {}",
            self.harness, self.what
        )
    }
}

impl std::error::Error for HarnessError {}

/// A refusal is a bridge-side failure, not an upstream one: the caller asked for something
/// the configured harness cannot do, which is a deployment/wiring fault.
impl From<HarnessError> for ApiError {
    fn from(e: HarnessError) -> ApiError {
        (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
    }
}

/// One agent program the bridge knows how to run: its IDENTITY AND ITS POLICY.
///
/// An implementation is a SHARED SINGLETON living in the [`HarnessRegistry`] and serving
/// concurrent turns, so it holds no per-turn state — which is exactly why parsing is a
/// separate per-turn object ([`SpawnedHarness::parser`]) rather than a method here.
///
/// **THIS TRAIT SAYS WHAT A HARNESS IS, NEVER HOW IT IS REACHED.** Everything on it is true
/// of a harness whether or not a process is involved. The methods that only mean something
/// for a child process live on [`SpawnedHarness`]; the ones that only mean something for a
/// harness answering inside this process live on [`InProcessHarness`]; and
/// [`Harness::runner`] is the single question that says which of the two a given harness
/// is. That split is the whole point: before it, every consumer of a `&dyn Harness` could
/// reach `build_turn` and none of them had to think about whether a child existed.
pub trait Harness: Send + Sync {
    /// Stable id, and the registry key. `claude-code` for the one implementation today.
    fn id(&self) -> &'static str;

    /// Whether this harness delivers its answer as token-level deltas as they are produced
    /// (true) rather than whole, in one terminal event (false).
    ///
    /// The one flag, because it is the only one anything reads: the driver's streamed-text
    /// safety net (an answer that reached the client live must not be erased by a success
    /// envelope whose result field came back empty) only makes sense for a harness that
    /// streams. A whole-answer harness has no such net and must not be given a phantom one
    /// — its terminal outcome has to be complete on its own.
    ///
    /// True for either runner shape. An in-process harness that streams pushes
    /// [`TurnSink::text_delta`] as its tokens arrive; the driver's safety net then covers it
    /// exactly as it covers a spawned one.
    fn streams_text(&self) -> bool;

    /// Whether this harness can actually express this capability, as a posture distinct from
    /// the ones below it. NOT whether we would like it to.
    ///
    /// A harness is configured by what it CAN do. [`Capability`] is one vocabulary shared by
    /// every spawn site, but the LEVERS behind it are per harness: a named tool allowlist for
    /// Claude Code, an OS sandbox mode for Codex. A level whose lever a harness does not have
    /// is not a level that harness fails — it is a level that harness does not HAVE, and the
    /// difference matters to an operator, who has something to go fix in the first case and
    /// nothing to go fix in the second.
    ///
    /// Two consumers read this and no third place may assume anything:
    ///   * the startup gate ([`validate_model_config`]), which refuses a model configured at
    ///     a level its harness cannot express;
    ///   * [`crate::routing::pick_offload_model`], which must not hand a routed job to a
    ///     harness that cannot give the job's child the posture the job requires.
    ///
    /// A declaration is not taken on trust: `the_containment_records_agree_with_what_each_harness_declares`
    /// holds every embedded record against it, so a harness claiming a level its record has
    /// no passing row for — or disclaiming one its record passes — is a BUILD failure. That
    /// is what keeps this from becoming a wish list of its own.
    fn expresses(&self, capability: Capability) -> bool;

    /// Whether this harness can drive a model over `wire` — the API surface a request/response
    /// is spoken on. Replaces `speaks_openai_backend`, whose single boolean could name only
    /// one alternative to Anthropic's and could not say which.
    ///
    /// It lives here for the reason [`Harness::expresses`] does: it is a fact about what the
    /// harness CAN do, and the alternative was [`validate_model_config`] hardcoding a harness
    /// id, which puts a per-harness fact in the one file that is supposed to ask rather than
    /// know.
    ///
    /// **The asymmetry the old boolean encoded is preserved, and it is the part to keep.**
    /// Claude Code answers [`Wire::Messages`] and nothing else: it drives its child over
    /// Anthropic's `/v1/messages`, and handing it a base URL that answers only
    /// `/v1/responses` produces a model the picker shows as healthy whose every turn 404s.
    /// Codex answers BOTH `Responses` and `Messages`, and the second is not sloppiness: a
    /// Codex model on its own subscription OAuth login names no provider at all, is declared
    /// `hosted`, and is exactly the deployed posture. The gate reads this in ONE direction —
    /// a model whose wire its harness does not support is refused — so the hosted-login case
    /// must keep answering true or the deployed configuration stops booting.
    ///
    /// [`Wire::Chat`] is supported by NO harness today, deliberately: it is the wire the
    /// OpenAI health probe speaks (see [`DEFAULT_OPENAI_HEALTH_PATH`]) and a wire the agent
    /// layer speaks, but nothing here drives a TURN over it. A model that declares it is
    /// refused at startup naming the harness, which is the honest answer.
    ///
    /// There is no default. A new harness must state which wires it drives, because the
    /// safe-looking default ("Messages only") is a claim about a transport nobody checked.
    fn supports_wire(&self, wire: Wire) -> bool;

    /// How many turns of a model on THIS harness may run at once, absent any config.
    ///
    /// A DEFAULT DECLARED BY THE HARNESS, not a per-harness test in the config loader. The
    /// alternative — `if harness == "codex" { 3 }` somewhere in `slots.rs` — puts a
    /// per-harness fact in the one file that is supposed to ask rather than know, and makes
    /// the third harness a config-loader edit instead of an implementation.
    ///
    /// The default is `1`: a harness that declares nothing gets one thread, which is
    /// throttled but never unsafe. Overridable per model (`[concurrency]`, or
    /// `JESSE_MODEL_<ID>_CONCURRENCY`) — this is only where the number comes from when
    /// nobody said otherwise.
    fn default_concurrency(&self) -> usize {
        1
    }

    /// Whether this harness can participate in the bridge's vault write lock
    /// ([`crate::writelock`]).
    ///
    /// **The default is `false`, and that is the whole safety property.** Slot accounting is
    /// harness-independent, but the write-lock MECHANISM is not: Claude Code installs hooks
    /// through a settings file, Codex through `$CODEX_HOME/hooks.json` plus a trust flag, and
    /// a third harness will do something else again. A harness that has not implemented it
    /// must not be handed concurrent write-level turns just because the config asked — so
    /// [`resolve_slot_plan`] caps such a harness at ONE write-level slot.
    ///
    /// Adding a third harness that implements nothing therefore produces a THROTTLED bridge,
    /// never an unlocked vault. `every_known_harness_declares_write_lock_support` holds every
    /// id in [`KNOWN_HARNESS_IDS`] against this so the question cannot be skipped.
    ///
    /// **AN IN-PROCESS HARNESS ANSWERING `true` IS MAKING A DIFFERENT PROMISE**, and it is
    /// the one thing about this method the split changes. The hook machinery is spawned-only
    /// by construction: [`WriteLockChild`] describes a hook COMMAND STRING for a child
    /// process, and it is installed by [`SpawnedHarness::build_turn`], which an in-process
    /// harness does not have. So an in-process harness answering `true` is promising that it
    /// takes the lock through [`crate::LockBroker`] DIRECTLY, in this process, around every
    /// write it performs — which is what D5's agent loop does, and which is strictly simpler
    /// than the hook round trip because there is no process boundary to cross. An in-process
    /// harness that has not done that answers `false`, and [`resolve_slot_plan`]'s cap then
    /// applies to it exactly as it applies to a spawned harness that has not: one
    /// write-level turn at a time. Nothing about the fail-safe changed shape.
    fn supports_write_lock(&self) -> bool {
        false
    }

    /// The containment flags this harness turns a [`Capability`] into: the whole boundary,
    /// in this harness's own flag vocabulary.
    ///
    /// On the trait rather than free-standing because the record is per harness and every row
    /// in it must be compared against the argv ITS OWN harness would produce. When this lived
    /// as one function, [`validate_toolset_argv`] compared every row of every record against
    /// Claude Code's flags — which is correct exactly while one harness exists and silently
    /// wrong the moment a second record loads.
    ///
    /// **A host-varying scope is named by [`WORKSPACE_TOKEN`], never by an absolute path.**
    /// The recorded argv has to be identical on every machine or the startup comparison
    /// cannot be strict equality; the token is substituted for the turn's real working
    /// directory when the child is built, which is the only place that knows it.
    ///
    /// It stays on the SHARED trait rather than moving to [`SpawnedHarness`] even though the
    /// word "argv" is in its name: what it describes is the BOUNDARY, the startup gate reads
    /// it for every registered harness, and an in-process harness has a boundary too — it
    /// just spells it as the tool set it hands its loop rather than as flags. A harness with
    /// no argv to give returns the strings that name its posture; what must not happen is a
    /// harness with no entry here, because that is a harness whose record vouches for
    /// nothing.
    fn capability_args(&self, cfg: &Config, capability: Capability) -> Vec<String>;

    /// Every (capability, MCP set) pair THIS harness actually spawns, and therefore every
    /// row its record must carry.
    ///
    /// PER HARNESS for the same reason as [`SpawnedHarness::main_mcp_config`], of which this
    /// is the direct consequence: the rows a battery must probe follow from the server sets
    /// the harness spawns. A shared list forced every harness to be re-recorded whenever
    /// any one of them gained a server.
    fn shipped_rows(&self) -> &'static [ContainmentRow];

    /// Where this harness keeps its transcripts on disk, if it keeps any.
    ///
    /// `None` means it keeps none in a layout the bridge can read — its thread state is its
    /// own business. Such a harness is SKIPPED by conversation adoption, by the GC sweep,
    /// and by the resume existence check (there is no file whose absence could justify
    /// dropping a `--resume`), and its conversations live in the registry like every other
    /// conversation.
    ///
    /// That works because `GET /jesse/conversations` is already rendered from the PERSISTED
    /// conversation registry rather than from a directory scan; the directory is only how
    /// mtimes, first-message snippets and unregistered strays are discovered. Do not
    /// reintroduce the assumption that a conversation is a file.
    ///
    /// Hydration is the third leg and it does read jsonl off disk, so the degradation is
    /// explicit: `GET /jesse/conversations/{id}/transcript` for a conversation whose bound
    /// transcripts are not on disk returns `200` with an EMPTY turn list, never an error.
    /// For a transcript-less harness that means a new device — or a reinstalled app — sees
    /// the conversation in the list with no server-side history; the app's own local
    /// transcript remains the user-visible record, and the context ledger still feeds
    /// catch-up into the next turn. Accepted deliberately: hydrating from the ledger is real
    /// machinery for a rare case and is not built.
    fn transcript_dir(&self, cfg: &Config) -> Option<PathBuf>;

    /// HOW THIS HARNESS'S MODEL GETS AT AN ATTACHMENT: the tool to tell it to use, and the
    /// on-disk types that tool can actually take.
    ///
    /// A trait method rather than a constant the handler switches on, for the same reason
    /// `capability_args` is one: the two answers differ in BOTH halves and the halves must
    /// not drift apart. Claude Code reads files with `Read`, which takes images and PDFs
    /// directly; Codex has no `Read` at all and reaches pixels through `view_image`, which
    /// takes images and not PDFs. A single fragment naming the wrong tool sends the model
    /// hunting for something it does not have, and a single format list would either
    /// rasterize PDFs nobody needed rasterized or hand Codex one it cannot open.
    ///
    /// The bridge converts anything outside `native` before naming a path — see
    /// [`prepare_attachments_for_harness`].
    fn attachment_support(&self) -> &'static AttachmentSupport;

    /// The turns of one of THIS harness's threads, for
    /// `GET /jesse/conversations/{id}/transcript`.
    ///
    /// **The default is `None`, meaning "ask the transcript directory instead"** — which is
    /// what every harness did before this method existed, and what the two spawned harnesses
    /// still do. The hydration path reads [`Harness::transcript_dir`], finds the session's
    /// jsonl file and shapes its lines; a harness that keeps such files needs nothing here.
    ///
    /// It exists for the harness that keeps its history somewhere the directory scan cannot
    /// see. D4 recorded that such a harness returns an EMPTY turn list, accepted deliberately
    /// because hydrating from the context ledger would be real machinery for a rare case.
    /// That reasoning held while the only transcript-less harness (Codex) genuinely had no
    /// readable history. It stops holding for `direct`, which keeps a complete thread log in
    /// its own store — so rather than degrade, it answers here.
    ///
    /// The two rules an implementation owes, both of which exist because this is the one place
    /// stored history becomes something a phone renders:
    ///   * the user text is un-wrapped through [`strip_prompt_wrapper`], so the transcript
    ///     shows what was typed rather than the bridge's assembled prompt;
    ///   * TOOL MESSAGES ARE NOT RENDERED. The phone has never shown a tool call or its
    ///     result, and a harness whose tool results are vault content must not be the one that
    ///     starts.
    fn hydrate(&self, _cfg: &Config, _session_id: &str) -> Option<Vec<HydratedTurn>> {
        None
    }

    /// **WHICH RUNNER SHAPE THIS HARNESS IS** — the one branch, asked once per call site.
    ///
    /// Returning a borrow of `self` under one of two trait objects, rather than a boolean
    /// plus a downcast, is what makes the branch total: the arm that says "spawned" is
    /// handed the `&dyn SpawnedHarness` it needs, and the arm that says "in process" cannot
    /// reach `build_turn` at all. A call site that only knows how to spawn must still write
    /// the other arm, and what it writes there is a visible refusal rather than a silent
    /// default — see [`crate::claude::run_claude_streaming`] for the shape.
    ///
    /// Constant per harness. Nothing about a turn changes the answer, so a call site may ask
    /// it as often as it likes.
    fn runner(&self) -> Runner<'_>;
}

/// Which of the two runner shapes a [`Harness`] is, carrying the borrow that shape needs.
///
/// An ENUM rather than two optional accessors (`as_spawned() -> Option<…>`), because the
/// enum is what makes a `match` exhaustive: adding a third shape becomes a compile error at
/// every call site, which is exactly the review this change exists to force. Two optional
/// accessors would let a new shape land with every existing site silently taking its
/// `None` path.
pub enum Runner<'a> {
    /// The harness answers a turn by spawning a CHILD PROCESS and reading its stdout.
    Spawned(&'a dyn SpawnedHarness),
    /// The harness answers a turn INSIDE THIS PROCESS, with no child at all.
    InProcess(&'a dyn InProcessHarness),
}

/// A [`Harness`] that answers a turn by spawning a child process — everything that only
/// means something once there IS a child.
///
/// Every method here was on `Harness` before the split and moved verbatim. They belong
/// together because they are all about the same object: `build_turn` makes the child,
/// `parser` reads its stdout, `classify_stderr_line`/`stderr_classifier` read its stderr,
/// `main_mcp_config` names the servers it launches, and the two hook methods read the
/// payloads its hooks send back. Not one of them has a meaning for a harness with no child.
///
/// Reached only through [`Runner::Spawned`], so a call site that holds one has already
/// said what it does when there is no child to spawn.
///
/// `Harness` is a SUPERTRAIT: a spawned harness is a harness, and the driver that holds one
/// still needs its id (to name a failure), its `streams_text` (to decide whether the
/// streamed-text safety net applies) and the rest. Threading the same object through two
/// parameters would have been the alternative, and it invites the two to disagree.
pub trait SpawnedHarness: Harness {
    /// Build the child `Command` for one turn — argv, cwd, stdio, env — or refuse.
    fn build_turn(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError>;

    /// A FRESH parser for one spawn attempt. The driver creates one per attempt, so a retry
    /// never sees the previous attempt's half-accumulated state.
    fn parser(&self) -> Box<dyn TurnParser>;

    /// The MCP server set a MAIN turn of THIS harness spawns when no override is set.
    ///
    /// PER HARNESS, because the postures genuinely differ: Claude Code's main turn loads
    /// qmd plus the read-only Slack server, Codex's loads qmd alone. Sharing one const
    /// meant adding a server to one harness silently changed the other's posture — and
    /// since the containment record is keyed by MCP set, that would have invalidated a
    /// record and orphaned its human `[[accepted]]` signatures as a side effect of a
    /// change that had nothing to do with it.
    fn main_mcp_config(&self) -> &'static str;

    /// Classify one line of the child's STDERR. `None` for the overwhelming majority of
    /// lines, which are log noise.
    ///
    /// **This exists because a harness's stdout stream is not necessarily the whole story,
    /// and for Codex it demonstrably is not.** A sandbox-rejected native tool call emits NO
    /// item event on the `--json` stream at all — the only trace is a line on stderr. A turn
    /// where the child tried something and was refused would otherwise render as a turn where
    /// nothing happened, and a turn whose credentials are dead would render as a generic
    /// upstream error. Both are recoverable only by reading stderr.
    ///
    /// `&self` and stateless BY CONSTRUCTION, unlike [`TurnParser`]: stderr is drained by a
    /// SEPARATE concurrent task (it has to be, or a chatty stderr deadlocks the stdout pipe),
    /// so it cannot borrow the per-turn parser mutably. A signal that genuinely needed
    /// cross-line accumulation would need the two channels merged first, and nothing needs
    /// that yet — say so here rather than discovering it in a driver rewrite.
    ///
    /// The default is `None` for every line: Claude Code's stderr carries nothing the bridge
    /// acts on (its refusals and its auth failures both arrive as `stream-json` events), so it
    /// takes the default and its behaviour is byte-for-byte unchanged.
    fn classify_stderr_line(&self, _line: &str) -> Option<StderrSignal> {
        None
    }

    /// An OWNED classifier for one spawn's stderr, mirroring [`SpawnedHarness::parser`] and
    /// for the same structural reason: stderr must be drained by a task that OUTLIVES the
    /// borrow of the registry, so the driver cannot hold a `&dyn SpawnedHarness` across it.
    ///
    /// Implementations are unit structs, so this is a boxed copy of nothing. Override it only
    /// if a harness ever needs per-spawn stderr state — and read the note on
    /// [`SpawnedHarness::classify_stderr_line`] about why none does today.
    fn stderr_classifier(&self) -> Box<dyn StderrClassifier> {
        Box::new(NoStderrSignals)
    }

    /// Parse one of THIS harness's hook payloads into the write it is about to perform.
    ///
    /// Per harness because the payloads genuinely differ, measured against the pinned
    /// binaries on 2026-08-05:
    ///
    ///   * Claude Code hands over a STRUCTURED absolute path:
    ///     `tool_name: "Write"`, `tool_input: {"file_path": "/abs/path", "content": …}`.
    ///   * Codex hands over NO path field at all: `tool_name: "apply_patch"`, `tool_input:
    ///     {"command": "*** Begin Patch\n*** Add File: hello.txt\n+…"}` — the target is
    ///     inside patch envelope syntax and is RELATIVE to the payload's `cwd`.
    ///
    /// Those are exactly the two spellings of one file that must collapse to one lock key, so
    /// every implementation returns a FULLY RESOLVED ABSOLUTE PATH (symlinks resolved) or
    /// [`WriteTarget::Global`]. A harness that returns a cwd-relative path for one child and
    /// an absolute one for another has built two locks over one file and protected nothing.
    ///
    /// The default is [`WriteTarget::Global`] for anything a harness does not recognise:
    /// unknown means "lock everything", never "lock nothing".
    ///
    /// SPAWNED-ONLY because a hook payload is a thing a CHILD sends back. An in-process
    /// harness has no hooks to read; it takes its locks through the broker directly. See
    /// [`Harness::supports_write_lock`].
    fn hook_write_target(&self, _payload: &HookPayload) -> WriteTarget {
        WriteTarget::Global
    }

    /// The file a hook payload says this call READ, whose content becomes the conversation's
    /// compare-and-swap baseline. `None` when the call read nothing nameable.
    ///
    /// The default is `None`, which is the SAFE default here and the opposite of
    /// [`SpawnedHarness::hook_write_target`]'s: recording no baseline means the
    /// compare-and-swap has nothing to compare and the write is allowed (the named hole),
    /// whereas recording a WRONG baseline would refuse legitimate writes forever. A harness
    /// that cannot name what it read should say nothing rather than guess.
    fn hook_read_target(&self, _payload: &HookPayload) -> Option<PathBuf> {
        None
    }
}

/// Where an [`InProcessHarness`] sends the two mid-turn events, and the ONLY way its text
/// reaches the client before the turn ends.
///
/// The counterpart of [`TurnParser`] for the other runner shape, and deliberately narrower
/// than one: a parser MAPS a line the child already wrote, so it can afford a `StreamEvent`
/// with an `Ignore` variant and a `Done` variant. A sink is CALLED by a harness that has
/// decided to say something, so the only two things it may say are the two the mid-turn
/// contract at the top of this module names. There is no `Done` here and there must not be
/// one: the terminal outcome is the future's return value, so a harness cannot deliver two
/// different terminal answers.
///
/// `&self`, not `&mut self`, because a harness will hand this to whatever concurrency its
/// loop uses (a provider reader task, a batch of tool calls awaiting together) and a
/// `&mut` sink would force it to serialise through a lock it does not otherwise need. The
/// driver's implementation forwards into the job store, which is already `Send + Sync` and
/// already takes concurrent pushes from the stderr task today.
pub trait TurnSink: Send + Sync {
    /// A chunk of the visible answer, exactly as [`StreamEvent::TextDelta`] means it.
    ///
    /// Emitted only by a harness whose [`Harness::streams_text`] is true. **This is the only
    /// way text reaches the client mid-turn**, and the harness owes the rest of the contract
    /// with it: everything sent here must also appear in [`TurnOutcome::text`], and text
    /// already sent must never be sent again (see [`InProcessHarness::run_turn`] on retries).
    fn text_delta(&self, delta: &str);

    /// A coarse "the harness is doing X" hint, exactly as [`StreamEvent::ToolActivity`] means
    /// it — same one vocabulary across harnesses, same `refused` bit, and the same
    /// prohibition on tool RESULTS, tool INPUTS, token counts and per-tool timing.
    fn tool_activity(&self, activity: ToolActivity);

    /// The post-generation style check's verdict for this turn (D6), reported ONCE, after the
    /// answer is final.
    ///
    /// Not a mid-turn event and not part of the two-event contract above: it says nothing
    /// about progress and it arrives after the last delta. It is on this trait rather than on
    /// [`TurnOutcome`] because it is PROVENANCE — the driver reduces the outcome to a `Done`
    /// frame and hands nothing else to the badge, whereas the trace this sink already feeds is
    /// exactly the content-free per-turn channel the badge reads. Widening the outcome would
    /// have put a field on the one path every harness takes for a thing one harness produces.
    ///
    /// DEFAULTED TO A NO-OP, so a harness that runs no check and a sink that reports nowhere
    /// are both silent by writing nothing. See [`StyleVerdict`], which is two integers.
    fn style_verdict(&self, _verdict: StyleVerdict) {}
}

/// What an in-process turn hands back when it succeeds: exactly what the driver needs to
/// build a `Done` frame today, and nothing else.
///
/// Four fields because the driver's success path reads four things off a
/// [`ClaudeOutcome::Ok`] and its own accounting, and every one of them has to come from
/// somewhere. It is deliberately NOT `ClaudeOutcome`: that type carries `Retryable`, which
/// an in-process harness must never return (it owns its own retries — see
/// [`InProcessHarness::run_turn`]), and modelling a variant the contract forbids is how a
/// caller ends up handling it "just in case".
pub struct TurnOutcome {
    /// The final, complete answer text. Complete on its own even for a streaming harness:
    /// the driver's streamed-text safety net is a fallback for an empty terminal answer, not
    /// a licence to return one.
    pub text: String,
    /// The session this turn ran under, to re-key the conversation's ledger with. `None`
    /// keeps whatever key the conversation already has.
    ///
    /// **It must never start with `local-`.** That prefix names a SYNTHETIC id the bridge
    /// mints for a thread with no harness-side session behind it, and both resume builders
    /// filter it out before passing a resume target down (`is_synthetic_session_id`). A
    /// harness that returned one would be handing back an id that can never be resumed and
    /// that the bridge would then dutifully store as the conversation's current session.
    pub session_id: Option<String>,
    /// Token usage for the per-turn cost badge, in the shape the badge already multiplies by
    /// the active model's price deck. `ShadowUsage::default()` (all-`None`) when the harness
    /// has no counts — the badge renders nothing rather than a zero.
    pub usage: ShadowUsage,
    /// How many tool calls this turn made — the harness's OWN authoritative total, counting
    /// refused calls, which is what the spawned arm's activity events already amount to.
    ///
    /// It exists because the driver's count is otherwise derived from mid-turn activity, and
    /// activity is a garnish rather than a guarantee on a streaming harness. The driver
    /// reconciles the two with [`TurnTrace::note_tool_calls`], which takes the LARGER of the
    /// two — a harness cannot lower a count of calls the driver watched happen.
    pub tool_calls: usize,
}

/// Why an in-process turn did not produce a [`TurnOutcome`].
///
/// TWO variants, and the absence of a third is the contract. There is no `Retryable`: a
/// transient upstream failure is the harness's own business to retry inside the turn (see
/// [`InProcessHarness::run_turn`]), because the driver's retry re-runs the WHOLE prompt and
/// an in-process harness that already streamed half an answer cannot survive that. What
/// crosses this boundary is a decision, never a maybe.
pub enum TurnFailure {
    /// The turn failed and will not succeed on a re-run of the same prompt. `message` is
    /// operator-facing and carries no credential material; the driver surfaces it as the
    /// turn's error exactly as it surfaces a [`ClaudeOutcome::Fatal`].
    Fatal { message: String },
    /// The turn ended because its cancellation token fired. Distinguished from `Fatal`
    /// because a cancelled turn is not a failed one: the driver resolves it to the job
    /// store's `Cancelled`, which is the state the client already renders for a cancel.
    Cancelled,
}

/// A [`Harness`] that answers a turn INSIDE THIS PROCESS — no child, no pipes, no reap.
///
/// **NOTHING IMPLEMENTS THIS YET.** It is written now because the trait split is only worth
/// doing if the shape on the other side of it is decided rather than discovered, and D5 is
/// what implements it (the `agent/` crate's loop, adopted behind this trait). Everything
/// below is the contract D5 must satisfy; a reader adding a second in-process harness later
/// reads exactly this.
///
/// `Harness` is a SUPERTRAIT for the same reason it is on [`SpawnedHarness`]: the driver
/// holding one still asks it for its id and whether it streams.
pub trait InProcessHarness: Harness {
    /// Run one whole turn and return its outcome.
    ///
    /// ## The sink is the only mid-turn channel
    ///
    /// `sink` receives exactly the two events the mid-turn contract at the top of this
    /// module names, and **it is the ONLY way text reaches the client before this future
    /// resolves**. There is no second channel, no partial return, and no side door through
    /// the job store: a harness that wants a token on the user's screen calls
    /// [`TurnSink::text_delta`]. The same contract binds it as binds a spawned harness's
    /// parser — same vocabulary, same `refused` bit, same prohibition on tool results,
    /// tool inputs, token counts and per-tool timing.
    ///
    /// ## Retries are the harness's, and text is never re-delivered
    ///
    /// **This harness owns retrying a transient failure WITHIN the turn.** The driver's
    /// three-attempt retry belongs to the spawned arm and does not run here, for a concrete
    /// reason: that retry re-runs the whole prompt and calls `stream_reset` to discard the
    /// discarded attempt's text, which works because a killed child has said nothing that
    /// survives. An in-process harness holds its own conversation state and its own partial
    /// answer, so a driver-level re-run would either duplicate work the harness already did
    /// or throw away state only the harness can see.
    ///
    /// The obligation that comes with owning the retry: **text already delivered through the
    /// sink must never be delivered again.** A harness that retries after streaming a
    /// partial answer must resume from where it stopped, or reset its own visible state
    /// before it starts over — it must not simply re-send from the beginning, because the
    /// client appends deltas and would render the answer twice.
    ///
    /// ## Cancellation ends the future promptly and leaves the thread resumable
    ///
    /// `cancel` fires when the turn is cancelled or times out. The future must **end
    /// promptly** — abandoning an in-flight upstream request rather than waiting for it, on
    /// the same order of promptness the spawned arm gets from killing a child — and must
    /// return [`TurnFailure::Cancelled`] rather than a `Fatal` dressed up as one.
    ///
    /// It must also leave the **thread resumable**: whatever state the next turn would
    /// resume from has to be consistent at the moment the future returns. A half-written
    /// thread append, a tool result recorded with no matching call, or a lock still held is
    /// a cancelled turn that has broken the conversation rather than ended it. This is the
    /// clause with no equivalent on the spawned side — a killed child's state is its own
    /// problem — and it is the one most likely to be got wrong.
    ///
    /// ## The outcome
    ///
    /// A [`TurnOutcome`] on success, carrying the four things the driver needs to build a
    /// `Done` frame. `TurnOutcome::session_id` must never start with `local-`; see the field.
    ///
    /// ## Why a boxed future rather than `async fn`
    ///
    /// The trait is used as `&dyn InProcessHarness` (that is the whole point of
    /// [`Runner::InProcess`]), and an `async fn` in a trait is not dyn-compatible. The
    /// explicit `Pin<Box<dyn Future + Send>>` is the shape that is, and `Send` is required
    /// because the driver runs this inside a `tokio::spawn`ed turn task.
    fn run_turn<'a>(
        &'a self,
        cfg: &'a Config,
        req: &'a TurnRequest<'a>,
        sink: &'a dyn TurnSink,
        cancel: CancellationToken,
    ) -> Pin<Box<dyn Future<Output = Result<TurnOutcome, TurnFailure>> + Send + 'a>>;
}

/// What the operator is told when a harness's daemon credential is dead, in ONE place so both
/// channels that can detect it say the same thing.
///
/// The wording is deliberate on three points, and they are the whole reason this is not an
/// inline `format!`. It names the HARNESS, because only that harness's turns are affected and
/// a user staring at a failed turn should not conclude the bridge is down. It names the
/// REMEDY and where to run it, because the fix is a shell command on the bridge host and
/// nothing the phone can do. And it says the failure is total rather than intermittent, so
/// nobody spends an evening retrying.
pub fn auth_failure_message(harness: &str, detail: &str) -> String {
    format!(
        "{harness} could not authenticate ({detail}). The bridge's {harness} login has expired \
         or been revoked, so every {harness} turn will fail until an operator re-authenticates \
         on the bridge host. Turns on other harnesses are unaffected."
    )
}

/// The owned, `Send` half of [`Harness::classify_stderr_line`] — see
/// [`Harness::stderr_classifier`].
pub trait StderrClassifier: Send {
    fn classify(&self, line: &str) -> Option<StderrSignal>;
}

/// The classifier for a harness whose stderr carries nothing the bridge acts on. The default,
/// and what Claude Code uses.
pub struct NoStderrSignals;

impl StderrClassifier for NoStderrSignals {
    fn classify(&self, _line: &str) -> Option<StderrSignal> {
        None
    }
}

/// Something the bridge must act on that arrived on STDERR rather than the event stream.
///
/// Two variants because there are exactly two things a turn does differently, and adding a
/// third means deciding what the turn does about it first. This is not a log level.
#[derive(Debug, Clone, PartialEq)]
pub enum StderrSignal {
    /// A tool call the child attempted and the containment boundary refused.
    ///
    /// Surfaced as ordinary tool ACTIVITY, not as a failure: the boundary working is not the
    /// turn failing, and the model routinely tries something, is refused, and answers anyway.
    /// What it must not be is INVISIBLE — see [`Harness::classify_stderr_line`].
    ToolRefused {
        /// The same coarse activity a successful call produces, with `refused` set. Never
        /// the raw log line: those carry paths and command text.
        activity: ToolActivity,
    },
    /// The child could not authenticate, so no turn on this harness can succeed until an
    /// operator intervenes.
    ///
    /// Distinguished from an ordinary upstream error ON PURPOSE, and that distinction is the
    /// whole point of the variant. A daemon has no interactive login path, so this failure
    /// takes EVERY turn on the harness down at once and stays down — it is not a blip worth
    /// retrying, and a retry loop against dead credentials just burns the turn budget three
    /// times before saying the same thing.
    AuthFailed {
        /// The child's own words, truncated, with no credential material in it.
        detail: String,
    },
}

/// The per-turn line parser: fed every line of the child's stdout, in order.
///
/// An OBJECT, not a `fn parse_line(&self, line: &str)` on the harness, and deliberately so.
/// The harness is a shared singleton serving concurrent turns, so it cannot hold per-turn
/// state; and a stateless per-line function cannot express a harness whose terminal outcome
/// is ASSEMBLED ACROSS LINES. Claude Code is the easy case — its result line carries the
/// answer, the session id and the usage all at once, so its parser is a stateless wrapper
/// around [`parse_stream_line`]. Codex is the case this shape exists for: the thread id
/// arrives in an early event, the message in a later one, the usage in the terminal one,
/// and only a parser that accumulates across lines can emit a complete `Done`.
pub trait TurnParser: Send {
    /// Map one line of the child's stdout to what the bridge does about it, accumulating
    /// whatever this harness needs to build its terminal outcome.
    fn on_line(&mut self, line: &str) -> StreamEvent;
}

/// The id of the built-in harness: the one the ambient default runs under, and the one
/// that serves every turn today.
pub const CLAUDE_CODE_ID: &str = "claude-code";

/// The placeholder standing for the turn's own working directory inside a containment argv.
///
/// It exists so the committed record can name a host-varying scope WITHOUT naming a host
/// path. `Harness::capability_args` emits it, the record therefore carries it, and the
/// harness substitutes the real directory when it builds the child — the one place that
/// knows which directory this turn runs in.
///
/// The alternative was normalizing at compare time, and it is worse: the comparison in
/// [`validate_toolset_argv`] would stop being strict equality and would start quietly
/// tolerating differences nobody chose. With a token, the comparison stays literal, and an
/// untokenised absolute path in the record is still a loud boot failure on every machine but
/// the one that recorded it — which is exactly the failure
/// `the_record_carries_no_absolute_host_paths` exists to prevent at commit time instead.
pub const WORKSPACE_TOKEN: &str = "${WORKSPACE}";

// ---- The routed jobs' child requests ----------------------------------------
//
// WHAT A JOB NEEDS, not what a harness does — which is why these live here and not in
// [`claude_code`], where they used to sit back when Claude Code was the only harness that
// could serve them.
//
// Each one states a JOB's contract: the capability the job needs, the MCP servers it may
// load, and the directory it runs in. None of that varies by harness, and it must not: the
// title job needs no tools because writing a title needs no tools, whichever program runs
// it. The serving harness is chosen by [`HarnessRegistry::serving_pick`] and turns the same
// request into its own argv via [`Harness::build_turn`].
//
// THE HARDCODED CAPABILITIES ARE THE POINT, not a leftover. A job's capability is its
// contract, so it is fixed here; whether a candidate's HARNESS can express that posture is a
// separate question, asked by [`Harness::expresses`] in `pick_offload_model` before a
// candidate can win the walk. That split is load-bearing: a Codex model configured at `Read`
// satisfies `>= Basic`, and Codex has no posture below `read-only`, so without the second
// check a title child — a job whose entire definition is that it needs nothing — would be
// spawned with a shell and the whole filesystem.
//
// `mcp_config` is the bridge's canonical `{"mcpServers":{…}}` shape rather than any one
// harness's format: Claude Code passes it through as `--mcp-config`, and `codex_mcp_args`
// translates it into `-c` overrides.

/// The TITLE one-shot's request: [`Capability::Basic`] with NO MCP servers, ambient model,
/// no session. cwd stays the vault — a per-call-site choice the capability says nothing
/// about, and with `--tools ""` the child cannot read anything there anyway.
pub fn title_child_request<'a>(
    cfg: &'a Config,
    prompt: &'a str,
    ambient: &'a ActiveModel,
    turn_id: &'a str,
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Basic,
        cwd: PathBuf::from(&cfg.vault),
        mcp_config: EMPTY_MCP_CONFIG,
        write_lock: None,
        turn_id,
        // A routed one-shot produces no files: its whole output is the text it returns.
        artifact_dir: None,
        // A single-shot child never carries an attachment.
        attachment_dir: None,
    }
}

/// A stateless DIET child's request (extract or verify): [`Capability::Basic`] with no MCP
/// servers, and the neutral scratch base as cwd so the large vault `CLAUDE.md` cannot
/// auto-load (the extract/verify contract is inlined in the prompt). That cwd is a
/// deliberate per-call-site choice, NOT something `Basic` implies — the title one-shot is
/// also `Basic` and runs in the vault — so leave it alone.
pub fn diet_child_request<'a>(
    cfg: &'a Config,
    prompt: &'a str,
    ambient: &'a ActiveModel,
    turn_id: &'a str,
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Basic,
        cwd: cfg.scratch_base(), // neutral cwd → no vault CLAUDE.md auto-load
        mcp_config: EMPTY_MCP_CONFIG,
        write_lock: None,
        turn_id,
        // A routed one-shot produces no files: its whole output is the text it returns.
        artifact_dir: None,
        // A single-shot child never carries an attachment.
        attachment_dir: None,
    }
}

/// The read-only VAULT-QA child's request (shared with the shadow child):
/// [`Capability::Read`] and the child's own MCP server set (`JESSE_VAULTQA_MCP_CONFIG`,
/// else NO servers). THE ONE INTENTIONAL DIVERGENCE from the diet child is the cwd: the
/// vault, because the child must read vault files to answer. Containment therefore comes
/// from the TOOLSET, not from an isolated cwd. Never resumes (the child is stateless).
pub fn vaultqa_child_request<'a>(
    cfg: &'a Config,
    prompt: &'a str,
    ambient: &'a ActiveModel,
    turn_id: &'a str,
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Read,
        cwd: PathBuf::from(&cfg.vault),
        mcp_config: vaultqa_mcp_config(cfg),
        write_lock: None,
        turn_id,
        // A routed one-shot produces no files: its whole output is the text it returns.
        artifact_dir: None,
        // A single-shot child never carries an attachment.
        attachment_dir: None,
    }
}

/// Every harness this build knows how to construct, by id — the registry's vocabulary.
///
/// A model naming an id absent from here is a startup ERROR rather than a silent fallback
/// to Claude Code: quietly running a Codex-configured model under a different harness is
/// exactly the sort of "it worked, differently" that a config surface must not do.
pub const KNOWN_HARNESS_IDS: &[&str] = &[CLAUDE_CODE_ID, CODEX_ID, DIRECT_ID];

/// Look a harness up in a registry by a config-supplied id, for the read paths that hold a
/// `String` rather than a `&'static str`.
pub fn registry_harness<'a>(reg: &'a HarnessRegistry, id: &str) -> Option<&'a dyn Harness> {
    reg.get(id)
}

/// The env var naming a harness's binary, mirroring `JESSE_CLAUDE_BIN` for Claude Code:
/// one variable per harness, defaulting to a bare name found on `PATH`.
///
/// It is consulted — and its absence is only fatal — for a harness some configured model
/// actually references. A config full of Codex models must not demand a Claude binary for
/// the models it does not have, and the converse holds too.
pub fn harness_bin_env(id: &str) -> Option<&'static str> {
    match id {
        CLAUDE_CODE_ID => Some("JESSE_CLAUDE_BIN"),
        CODEX_ID => Some("JESSE_CODEX_BIN"),
        // `direct` HAS NO BINARY, and the `None` is the answer rather than an omission: it
        // runs the turn in this process, so there is nothing on `PATH` whose absence could be
        // fatal and nothing for an operator to point an env var at.
        DIRECT_ID => None,
        _ => None,
    }
}

/// The default binary name for a harness, resolved from `PATH` when its env var is unset.
pub fn harness_default_bin(id: &str) -> Option<&'static str> {
    match id {
        CLAUDE_CODE_ID => Some("claude"),
        CODEX_ID => Some("codex"),
        // See `harness_bin_env`: no binary.
        DIRECT_ID => None,
        _ => None,
    }
}

/// The harness registry: id → implementation, built ONCE at startup and read-only
/// afterwards, the same lifecycle (and the same "the default is built in and never
/// configurable") as [`ModelRegistry`]. Lives in [`Config`], so every path that already
/// carries a `&Config` can ask which harness serves it without a new argument.
pub struct HarnessRegistry {
    harnesses: HashMap<&'static str, Box<dyn Harness>>,
}

impl HarnessRegistry {
    /// Build the registry: the built-in [`ClaudeCode`] harness first, then any `extra`
    /// implementations, later overriding earlier BY ID. Claude Code is always present, so
    /// [`HarnessRegistry::fallback_harness`] can never come up empty.
    pub fn new(extra: Vec<Box<dyn Harness>>) -> Self {
        let mut harnesses: HashMap<&'static str, Box<dyn Harness>> = HashMap::new();
        harnesses.insert(ClaudeCode.id(), Box::new(ClaudeCode));
        for h in extra {
            harnesses.insert(h.id(), h);
        }
        HarnessRegistry { harnesses }
    }

    /// The shipped registry: exactly one harness, `claude-code`.
    pub fn claude_code_only() -> Self {
        HarnessRegistry::new(Vec::new())
    }

    /// Build the registry for a set of configured models: only the harnesses those models
    /// NAME, plus `claude-code`.
    ///
    /// Claude Code is unconditional because the ambient default still exists — it is the
    /// out-of-box conversation backend and the routing rule's final fallback, so it is the
    /// one harness that must be constructible whatever the config says. That is a KNOWN
    /// LIMITATION carried deliberately, not an assumption this effort adds: de-privileging
    /// ambient into an ordinary registry entry means solving auth, defaults and first-run,
    /// and is out of scope here. The rule until then is that no change may add a NEW
    /// assumption that ambient exists.
    ///
    /// Unknown ids are IGNORED here and refused by [`validate_model_config`], so the
    /// registry stays total and the error arrives once, from the validator, naming the
    /// model.
    pub fn for_models<'a>(named: impl IntoIterator<Item = &'a str>) -> Self {
        let mut extra: Vec<Box<dyn Harness>> = Vec::new();
        for id in named {
            match id {
                // Every non-built-in harness is constructed here as it is added. The match
                // is exhaustive over `KNOWN_HARNESS_IDS` minus the built-in.
                CLAUDE_CODE_ID => {}
                CODEX_ID => extra.push(Box::new(Codex)),
                DIRECT_ID => extra.push(Box::new(Direct)),
                _ => continue,
            }
        }
        // `new` always registers Claude Code first, so the ambient contract holds.
        HarnessRegistry::new(std::mem::take(&mut extra))
    }

    /// Look one up by id.
    pub fn get(&self, id: &str) -> Option<&dyn Harness> {
        self.harnesses.get(id).map(|h| h.as_ref())
    }

    /// The harness every unattributed path falls back to: `claude-code`.
    ///
    /// It is the FALLBACK, not "the harness that serves a turn" — that is
    /// [`HarnessRegistry::serving`], which reads the model. This one exists because Claude
    /// Code is the one harness always constructible (see [`HarnessRegistry::for_models`]),
    /// so a lookup that finds nothing has somewhere total to land.
    ///
    /// That is the SAME ambient assumption the registry already carried, kept rather than
    /// widened: nothing new depends on ambient because of harness selection, and the one
    /// place that did depend on it still does.
    pub fn fallback_harness(&self) -> &dyn Harness {
        // `new` always registers it; the fallback keeps this total rather than panicking if
        // that invariant is ever broken.
        self.get(CLAUDE_CODE_ID).unwrap_or(&ClaudeCode)
    }

    /// The harness that serves a child for `model` — **the model's own `harness` key**.
    ///
    /// This is the selection, and the model is the only thing that carries it: a turn runs
    /// under the harness its model was configured with, and a routed job runs under the
    /// harness of whichever candidate the walk picked. There is no separate harness config
    /// key and there must not be one — a model that named a harness it did not run under
    /// would make every containment record meaningless.
    ///
    /// An unregistered id falls back rather than failing, because it CANNOT happen in a
    /// running bridge and the totality is worth more than the assertion:
    /// [`validate_model_config`] refuses such a model at startup, naming it. Making this
    /// return `Option` would push that already-settled error onto every call site.
    pub fn serving(&self, model: &ActiveModel) -> &dyn Harness {
        self.get(&model.harness)
            .unwrap_or_else(|| self.fallback_harness())
    }

    /// The harness that serves one routed job, from the pick the routing rule made.
    ///
    /// COUPLED WITH [`RoutedPick::harness`]: the pick names a harness id and this resolves
    /// it, so a routed child is built by the same harness the routing log line named. If
    /// these two ever disagree the log stops describing what ran.
    pub fn serving_pick(&self, pick: &RoutedPick) -> &dyn Harness {
        self.get(&pick.harness)
            .unwrap_or_else(|| self.fallback_harness())
    }

    /// Every registered harness in a STABLE order: the turn harness first, then the rest by
    /// id. Stable so a sweep, an adoption pass and a log line are reproducible.
    pub fn ordered(&self) -> Vec<&dyn Harness> {
        let turn = self.fallback_harness();
        let mut ids: Vec<&'static str> = self
            .harnesses
            .keys()
            .copied()
            .filter(|id| *id != turn.id())
            .collect();
        ids.sort();
        let mut out: Vec<&dyn Harness> = vec![turn];
        out.extend(ids.into_iter().filter_map(|id| self.get(id)));
        out
    }

    /// The ids of every registered harness, in [`HarnessRegistry::ordered`] order.
    pub fn ids(&self) -> Vec<&'static str> {
        self.ordered().iter().map(|h| h.id()).collect()
    }

    /// Every registered harness's transcript directory, in [`HarnessRegistry::ordered`]
    /// order, SKIPPING the ones that keep none. This is the whole disk surface the
    /// conversation store reads: adoption, the GC sweep, the list's mtime/snippet lookups
    /// and hydration all range over exactly these directories, and an empty result is a
    /// bridge whose harnesses keep no transcripts (a legitimate shape, see
    /// [`Harness::transcript_dir`]).
    pub fn transcript_dirs(&self, cfg: &Config) -> Vec<PathBuf> {
        self.ordered()
            .into_iter()
            .filter_map(|h| h.transcript_dir(cfg))
            .collect()
    }
}

impl Default for HarnessRegistry {
    fn default() -> Self {
        HarnessRegistry::claude_code_only()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn capability_ordering_is_cumulative() {
        // Write implies Read implies Basic, so `>=` reads "at least as capable as".
        assert!(Capability::Write > Capability::Read);
        assert!(Capability::Read > Capability::Basic);
        assert!(Capability::Write >= Capability::Write);
        assert!(Capability::Basic < Capability::Write);
    }

    #[test]
    fn turn_capability_follows_the_models_write_permission() {
        assert_eq!(
            turn_capability(&ActiveModel::ambient()),
            Capability::Write,
            "ambient opus is writes-on"
        );
        let mut off = ActiveModel::ambient();
        off.level = Capability::Read;
        assert_eq!(turn_capability(&off), Capability::Read);
    }

    #[test]
    fn the_shipped_registry_holds_exactly_claude_code() {
        let reg = HarnessRegistry::claude_code_only();
        assert_eq!(reg.ids(), vec![CLAUDE_CODE_ID]);
        assert_eq!(reg.fallback_harness().id(), CLAUDE_CODE_ID);
        assert!(reg.get("codex").is_none());
        assert!(
            reg.fallback_harness().streams_text(),
            "Claude Code streams token-level deltas"
        );
    }

    #[test]
    fn the_claude_code_transcript_dir_is_the_vault_projects_dir() {
        let mut cfg = test_config();
        cfg.home = "/home/bob".to_string();
        cfg.vault = "/vault/notes".to_string();
        assert_eq!(
            cfg.harnesses.fallback_harness().transcript_dir(&cfg),
            Some(PathBuf::from("/home/bob/.claude/projects/-vault-notes")),
            "the harness returns exactly the path the session code used to hardcode"
        );
        assert_eq!(cfg.harnesses.transcript_dirs(&cfg).len(), 1);
    }

    #[test]
    fn a_harness_error_names_the_harness_and_what_it_refused() {
        let e = HarnessError::unsupported("codex", "an MCP server set");
        assert_eq!(
            e.to_string(),
            "the codex harness cannot express an MCP server set"
        );
        let api: ApiError = e.into();
        assert_eq!(api.0, StatusCode::INTERNAL_SERVER_ERROR);
    }

    /// EVERY KNOWN HARNESS IS CONSTRUCTIBLE — the assumption that replaced
    /// `every_registered_harness_streams_until_a_client_can_render_one_that_does_not`.
    ///
    /// **What the old test held, and why it is gone.** It asserted that every registered
    /// harness had `streams_text() == true`, as a gate: registration must not land before a
    /// client could render a turn that delivers its answer whole. That was never a claim
    /// about harnesses — it was a claim about the CLIENTS, parked on the one file that
    /// would notice. Codex satisfies it now rather than evading it: the mid-turn event
    /// contract is written down at the top of this module, both clients render the tool
    /// activity it defines, and `WholeAnswerProgress` keeps a turn with no activity yet
    /// visibly alive. The gate was met, so the gate is retired. It was never relaxed — no
    /// commit weakened its assertion to get green.
    ///
    /// **What replaces it is narrower on purpose.** `streams_text` is now a property a
    /// harness may hold either way, so nothing about it is an invariant. What IS still an
    /// invariant is the one the old test carried in its second loop, and it outlives the
    /// first: `KNOWN_HARNESS_IDS` is the vocabulary [`validate_model_config`] accepts, and
    /// accepting an id [`HarnessRegistry::for_models`] cannot construct would let a model
    /// pass startup validation and then fall back to Claude Code at spawn time — running a
    /// Codex-configured model under a different harness, with a different containment
    /// record, and reporting success. The two lists must not drift apart.
    ///
    /// Same pattern, and the same reason, as `the_record_carries_no_absolute_host_paths` in
    /// `levelgate`: an assumption the code depends on should break the build, not the user.
    #[test]
    fn every_known_harness_id_can_actually_be_constructed() {
        // Built through the same door the validator's ids go through, so this exercises the
        // real `for_models` match rather than a hand-built registry that agrees by luck.
        let reg = HarnessRegistry::for_models(KNOWN_HARNESS_IDS.iter().copied());
        for id in KNOWN_HARNESS_IDS {
            let h = reg.get(id).unwrap_or_else(|| {
                panic!(
                    "'{id}' is a known harness id with no registry entry — `for_models` must \
                     be able to construct every id the validator accepts, or a model naming \
                     it passes startup and then silently runs under the fallback harness"
                )
            });
            assert_eq!(h.id(), *id, "the registry keyed '{id}' under another id");
        }
    }

    /// **THE TWO LEVEL VOCABULARIES ARE ONE VOCABULARY.** See the table on [`Capability`].
    ///
    /// The bridge's `Capability` and `jesse_agent::tools::Level` are declared separately
    /// because the two crates do not depend on each other, and D5's adoption is a pair of
    /// `From` impls that are only correct while the two agree on names AND on order — the
    /// order is what `Ord` means on both sides, so a swapped pair would silently make `Read`
    /// the most capable level.
    ///
    /// This half always runs and pins the bridge's side by NAME and by ORDER: the sort is on
    /// the derived `Ord`, so a reordered enum fails here even though the name set is
    /// unchanged.
    ///
    /// **The other half now runs.** It was gated behind an `agent-vocabulary` feature that
    /// enabled nothing, written before the dependency existed precisely so the check could
    /// not be forgotten. D5 adopted `jesse-agent`, so the gate is gone and the cross-crate
    /// comparison is unconditional — which is what it was written for. The two `From` impls
    /// it guards live in [`crate::agentmap`].
    #[test]
    fn the_capability_vocabulary_is_the_agent_crates_level_vocabulary() {
        let mut ours = [Capability::Write, Capability::Basic, Capability::Read];
        ours.sort();
        let names: Vec<String> = ours.iter().map(|c| format!("{c:?}")).collect();
        assert_eq!(
            names,
            ["Basic", "Read", "Write"],
            "the bridge's capability vocabulary changed; `jesse_agent::tools::Level` must \
             change with it, in the same order, or D5's mapping stops being the identity"
        );

        let mut theirs = [
            jesse_agent::tools::Level::Write,
            jesse_agent::tools::Level::Basic,
            jesse_agent::tools::Level::Read,
        ];
        theirs.sort();
        let their_names: Vec<String> = theirs.iter().map(|l| format!("{l:?}")).collect();
        assert_eq!(
            names, their_names,
            "the two level vocabularies have drifted — same names, same order, or the \
             `From<Capability> for Level` mapping is no longer the identity it is \
             documented to be"
        );
    }

    /// A whole-answer harness is registered, so the property the old streaming gate asserted
    /// is now false — and that is the point. Pinned rather than left implicit: the moment
    /// this fails, someone has made Codex claim to stream, and every client that keys a
    /// spinner off `ModelInfo.streamsText` starts waiting for deltas that never arrive.
    #[test]
    fn codex_is_registered_and_does_not_stream() {
        let reg = HarnessRegistry::for_models([CODEX_ID]);
        let codex = reg.get(CODEX_ID).expect("codex is registered");
        assert!(!codex.streams_text());
        assert!(
            reg.get(CLAUDE_CODE_ID).is_some_and(|h| h.streams_text()),
            "claude-code is still unconditionally registered and still streams"
        );
    }
}
