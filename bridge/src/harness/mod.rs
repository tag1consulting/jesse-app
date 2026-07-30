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
// One harness is registered today (`claude-code`) and nothing selects another; the point
// of the seam is that a second one is a new file rather than a second copy of the driver.

/// What a child agent is allowed to do, as ONE ordered vocabulary shared by every place
/// the bridge spawns one. Ordered and CUMULATIVE: `Write` implies `Read` implies `Basic`,
/// so the derived `PartialOrd` is meaningful — `a >= b` reads "a is at least as capable as
/// b" and is the right comparison wherever two capabilities meet.
///
/// Today the enum has ONE use: naming what a child is GRANTED, which each harness maps to
/// the containment flags that enforce it (for Claude Code, [`capability_args`]). The
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
    /// This names what the CHILD is doing and carries no assumption about the model behind
    /// it. A `Basic` child is a single-shot text transformation: parse an utterance into
    /// JSON, check that JSON, write a short title. It is granted nothing because it needs
    /// nothing — it returns text, and the BRIDGE validates that text and does any writing.
    /// That holds whatever model or harness serves the child.
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

/// Every harness this build knows how to construct, by id — the registry's vocabulary.
///
/// A model naming an id absent from here is a startup ERROR rather than a silent fallback
/// to Claude Code: quietly running a Codex-configured model under a different harness is
/// exactly the sort of "it worked, differently" that a config surface must not do.
pub const KNOWN_HARNESS_IDS: &[&str] = &[CLAUDE_CODE_ID];

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
        _ => None,
    }
}

/// The default binary name for a harness, resolved from `PATH` when its env var is unset.
pub fn harness_default_bin(id: &str) -> Option<&'static str> {
    match id {
        CLAUDE_CODE_ID => Some("claude"),
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
    /// [`HarnessRegistry::turn_harness`] can never come up empty.
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

    /// The harness that serves a turn. `claude-code` — nothing selects another today, and
    /// there is no config or wire field that could.
    pub fn turn_harness(&self) -> &dyn Harness {
        // `new` always registers it; the fallback keeps this total rather than panicking if
        // that invariant is ever broken.
        self.get(CLAUDE_CODE_ID).unwrap_or(&ClaudeCode)
    }

    /// Every registered harness in a STABLE order: the turn harness first, then the rest by
    /// id. Stable so a sweep, an adoption pass and a log line are reproducible.
    pub fn ordered(&self) -> Vec<&dyn Harness> {
        let turn = self.turn_harness();
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
        assert_eq!(reg.turn_harness().id(), CLAUDE_CODE_ID);
        assert!(reg.get("codex").is_none());
        assert!(
            reg.turn_harness().streams_text(),
            "Claude Code streams token-level deltas"
        );
    }

    #[test]
    fn the_claude_code_transcript_dir_is_the_vault_projects_dir() {
        let mut cfg = test_config();
        cfg.home = "/home/bob".to_string();
        cfg.vault = "/vault/notes".to_string();
        assert_eq!(
            cfg.harnesses.turn_harness().transcript_dir(&cfg),
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

    /// EVERY REGISTERED HARNESS STREAMS — and this test exists to fail the day one does not.
    ///
    /// `streams_text` is plumbed end to end: the harness derives it, `GET /jesse/models`
    /// exposes it per model, the clients decode it, and the iOS client now RENDERS the
    /// whole-answer case — a turn on a non-streaming model shows a spinner rather than the
    /// empty bubble it used to show until the terminal event landed.
    ///
    /// So the spinner is no longer what's missing. What is still missing is TOOL ACTIVITY:
    /// there is no live view of what a whole-answer harness is doing mid-turn, because
    /// nothing yet defines what event stream such a harness emits. That contract cannot be
    /// designed honestly without a real non-streaming harness to pin it against — inventing
    /// it here would force the first real one to match a guess made without it.
    ///
    /// If you are reading this because the assertion failed: you registered a harness that
    /// does not stream. The spinner will render its turns, so this is no longer about an
    /// empty bubble. What you owe first is a decision about the event stream your harness
    /// emits mid-turn, and the client-side tool-activity rendering that consumes it. Make
    /// that decision deliberately, with the harness in hand, rather than relaxing this test.
    ///
    /// Same pattern, and the same reason, as `the_record_carries_no_absolute_host_paths` in
    /// `levelgate`: an assumption the code depends on should break the build, not the user.
    #[test]
    fn every_registered_harness_streams_until_a_client_can_render_one_that_does_not() {
        let reg = HarnessRegistry::new(Vec::new());
        for h in reg.ordered() {
            assert!(
                h.streams_text(),
                "harness '{}' does not stream. Its turns will render the spinner keyed off \
                 `ModelInfo.streamsText`, but there is still no tool-activity view for a \
                 whole-answer turn, and no definition of the mid-turn event stream one \
                 emits — decide that with the harness in hand before registering it",
                h.id()
            );
        }
        // …and the vocabulary the registry validates against is covered by the same rule, so
        // a harness added to KNOWN_HARNESS_IDS but not yet constructible cannot slip past.
        for id in KNOWN_HARNESS_IDS {
            match reg.get(id) {
                Some(h) => assert!(h.streams_text(), "{id} does not stream"),
                None => panic!(
                    "'{id}' is a known harness id with no registry entry — `for_models` must \
                     be able to construct every id the validator accepts"
                ),
            }
        }
    }

}
