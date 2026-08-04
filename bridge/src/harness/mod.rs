use crate::*;

mod claude_code;
pub use claude_code::*;

mod codex;
pub use codex::*;

// ---- The agent program, behind a trait --------------------------------------
//
// The bridge spawns a child agent program, reads its stdout, and turns what comes back
// into a turn. Two halves of that were always separable and are now named:
//
//   * HARNESS-SPECIFIC — how to build the child's `Command`, and how to read one line of
//     its output. Claude Code's version lives in [`claude_code`].
//   * NOT HARNESS-SPECIFIC — the driver: spawn, read stdout line by line, stop at the
//     terminal result, bounded reap, resolve the outcome, retry a transient failure up to
//     three attempts with a stream reset between them. That stays in [`crate::claude`] and
//     calls through `&dyn Harness`.
//
// ---- THE MID-TURN EVENT CONTRACT --------------------------------------------
//
// WHAT A HARNESS OWES BETWEEN "I STARTED" AND "I FINISHED". Written here rather than
// left implicit because Codex is the FIRST harness whose answer arrives whole, and there
// is no second one to check the shape against — so the shape is stated, not inferred from
// the one implementation that has it.
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
// happened. So the contract consumes stderr, via [`Harness::classify_stderr_line`], and
// the cost is that ONE harness's stderr is load-bearing rather than log noise. Claude Code
// takes the `None` default and is byte-for-byte unaffected.
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

/// One agent program the bridge knows how to spawn.
///
/// An implementation is a SHARED SINGLETON living in the [`HarnessRegistry`] and serving
/// concurrent turns, so it holds no per-turn state — which is exactly why parsing is a
/// separate per-turn object ([`Harness::parser`]) rather than a method here.
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

    /// Whether this harness drives its model over an **OpenAI-style** API surface
    /// (`/v1/responses`) rather than Anthropic's `/v1/messages`.
    ///
    /// The one thing [`ModelKind::OpenAi`] needs to know about a harness, and it lives here
    /// for the same reason [`Harness::expresses`] does: it is a fact about what the harness
    /// CAN do, and the alternative was [`validate_model_config`] hardcoding a harness id,
    /// which puts a per-harness fact in the one file that is supposed to ask rather than
    /// know.
    ///
    /// The default is `false` — a harness speaks Anthropic unless it says otherwise, which is
    /// what every harness did before Codex gained a provider seam. The gate reads it in ONE
    /// direction: an `openai`-kind model on a harness that answers `false` is refused. The
    /// converse is legitimate and must stay so — a Codex model on its own OAuth login is
    /// `hosted`, names no provider, and is exactly the deployed posture.
    fn speaks_openai_backend(&self) -> bool {
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
    fn capability_args(&self, cfg: &Config, capability: Capability) -> Vec<String>;

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

    /// Build the child `Command` for one turn — argv, cwd, stdio, env — or refuse.
    fn build_turn(&self, cfg: &Config, req: &TurnRequest<'_>) -> Result<Command, HarnessError>;

    /// A FRESH parser for one spawn attempt. The driver creates one per attempt, so a retry
    /// never sees the previous attempt's half-accumulated state.
    fn parser(&self) -> Box<dyn TurnParser>;

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

    /// An OWNED classifier for one spawn's stderr, mirroring [`Harness::parser`] and for the
    /// same structural reason: stderr must be drained by a task that OUTLIVES the borrow of
    /// the registry, so the driver cannot hold a `&dyn Harness` across it.
    ///
    /// Implementations are unit structs, so this is a boxed copy of nothing. Override it only
    /// if a harness ever needs per-spawn stderr state — and read the note on
    /// [`Harness::classify_stderr_line`] about why none does today.
    fn stderr_classifier(&self) -> Box<dyn StderrClassifier> {
        Box::new(NoStderrSignals)
    }
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
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Basic,
        cwd: PathBuf::from(&cfg.vault),
        mcp_config: EMPTY_MCP_CONFIG,
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
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Basic,
        cwd: cfg.scratch_base(), // neutral cwd → no vault CLAUDE.md auto-load
        mcp_config: EMPTY_MCP_CONFIG,
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
) -> TurnRequest<'a> {
    TurnRequest {
        prompt,
        session_id: None,
        active: ambient,
        capability: Capability::Read,
        cwd: PathBuf::from(&cfg.vault),
        mcp_config: vaultqa_mcp_config(cfg),
    }
}

/// Every harness this build knows how to construct, by id — the registry's vocabulary.
///
/// A model naming an id absent from here is a startup ERROR rather than a silent fallback
/// to Claude Code: quietly running a Codex-configured model under a different harness is
/// exactly the sort of "it worked, differently" that a config surface must not do.
pub const KNOWN_HARNESS_IDS: &[&str] = &[CLAUDE_CODE_ID, CODEX_ID];

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
        _ => None,
    }
}

/// The default binary name for a harness, resolved from `PATH` when its env var is unset.
pub fn harness_default_bin(id: &str) -> Option<&'static str> {
    match id {
        CLAUDE_CODE_ID => Some("claude"),
        CODEX_ID => Some("codex"),
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
        self.get(&model.harness).unwrap_or_else(|| self.fallback_harness())
    }

    /// The harness that serves one routed job, from the pick the routing rule made.
    ///
    /// COUPLED WITH [`RoutedPick::harness`]: the pick names a harness id and this resolves
    /// it, so a routed child is built by the same harness the routing log line named. If
    /// these two ever disagree the log stops describing what ran.
    pub fn serving_pick(&self, pick: &RoutedPick) -> &dyn Harness {
        self.get(&pick.harness).unwrap_or_else(|| self.fallback_harness())
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
