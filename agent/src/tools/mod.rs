//! **The tool boundary** — what a turn may do, and the structure that makes anything else
//! unreachable rather than merely unattempted.
//!
//! ---- THE BOUNDARY STATEMENT ------------------------------------------------
//!
//! **A [`ToolSet`] is constructed at a [`Level`] and exposes ONLY the tools that level
//! permits. The loop dispatches BY EXACT NAME against that set's [`manifest`](ToolSet::manifest).
//! A name that is not in the manifest is [`ToolError::Refused`], recorded in the trace by
//! name, and forwarded NOWHERE.**
//!
//! That sentence is the whole design, and everything else in this module exists to make
//! it structurally true rather than a rule somebody remembers:
//!
//!   * A tool the level does not permit is not merely hidden from the manifest — it is
//!     not IN the built set, so [`ToolSet::get`] cannot return it. There is no code path
//!     from a model-generated name to an unexposed tool, because the object is not there.
//!   * [`ActionClass::ExternalWrite`] is exposed at NO level in Phase 1, and the builder
//!     has no way to say it: [`ExposedClass`] — the type [`ToolSetBuilder::add`] takes —
//!     has no such arm, so a call site that tried would not compile. See its doc for the
//!     one runtime check that backs this up and why it is needed.
//!   * A name miss is [`ToolError::Refused`], not [`ToolError::Failed`], and the two are
//!     distinguishable in the trace forever after. A refusal is the boundary WORKING; a
//!     failure is the boundary not being the thing that happened. Collapsing them would
//!     make "the boundary held 40 times today" and "a tool broke 40 times today" the same
//!     line in a log.
//!
//! THE REJECTED ALTERNATIVE was the obvious one: build one full tool set and check the
//! level inside `call`. It is the same behaviour on the happy path and it is much worse,
//! for two reasons. The model is SHOWN every tool (the manifest is derived from the set),
//! so a read-only turn spends its whole turn being invited to write and refused; and the
//! check lives in each tool rather than in one place, so a tool added later inherits no
//! boundary at all. Filtering at construction makes the manifest and the dispatch table
//! the same object, which is the only arrangement in which they cannot disagree.
//!
//! ---- WHAT A TOOL RESULT IS ALLOWED TO BE -----------------------------------
//!
//! Nothing here frames anything. A [`ToolOk`] carries [`ResultBlock`]s, and every one of
//! them reaches the model through exactly one function, [`crate::framing::frame_tool_result`].
//! That separation is deliberate: a tool that framed its own output would be a tool that
//! could choose not to.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::provider::{BoxFuture, ToolSpec};
use crate::scope::{check_schema_for_scope_arguments, Scope, ScopeShapedArgument};

pub mod fixture;
pub mod vault;

// ===========================================================================
// The vocabulary
// ===========================================================================

/// What a tool DOES to the world, which is the only property a level grants against.
///
/// Not "how dangerous is it" — a scale nobody can calibrate — but a small closed set of
/// effects, each of which a reader can check a tool against by looking at what it calls.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionClass {
    /// Reads state and returns it. Changes nothing, and sends nothing off the host.
    Read,
    /// Changes the vault — the owner's own documents, under the host's control.
    VaultWrite,
    /// Changes state on a THIRD PARTY: sends a message, files a ticket, moves money.
    /// Exposed at no level in Phase 1; see the module docs.
    ExternalWrite,
    /// A read that sends CALLER-AUTHORED BYTES off the host — a web fetch, a search query,
    /// a DNS lookup with an attacker-chosen label.
    ///
    /// NAMED SEPARATELY FROM `Read` ON PURPOSE, and this is the distinction the injection
    /// threat model turns on. A tool result is untrusted text that reaches a model which
    /// then chooses the next tool call; the danger is not that it reads something, it is
    /// that a directive hidden in one document can make the model put the CONTENTS of
    /// another into a URL. That is the exfiltration channel, and it is invisible if egress
    /// is filed under "read". Framing ([`crate::framing`]) is the mitigation for the
    /// instruction half; this class is what lets a future policy see the other half
    /// without re-auditing every tool.
    ///
    /// It is granted at [`Level::Read`] today, because a read-only assistant that cannot
    /// look anything up is not the product. The point of the separate name is that
    /// withdrawing it later is a one-line policy change rather than an archaeology
    /// project.
    Egress,
}

impl fmt::Display for ActionClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ActionClass::Read => "read",
            ActionClass::VaultWrite => "vault_write",
            ActionClass::ExternalWrite => "external_write",
            ActionClass::Egress => "egress",
        })
    }
}

/// How much a turn is trusted with — the SAME ORDERED CUMULATIVE VOCABULARY as the
/// bridge's `harness::Capability` (`Basic` < `Read` < `Write`), declared here because
/// this crate does not depend on the bridge in either direction.
///
/// D4 maps the two, and the mapping is meant to be the identity. Declaring a second,
/// differently-shaped vocabulary — "none / readonly / full", say — would make that mapping
/// a table somebody has to keep true, and a level that means slightly different things on
/// the two sides of a boundary is how a `Read` turn ends up with a write tool.
///
/// `PartialOrd`/`Ord` are derived and the ordering is load bearing: `Level::Read >=
/// Level::Basic` is what "cumulative" means, and [`turn_level`](Level::permits) reads that
/// way. The bridge derives the same for the same reason (`active.level.min(Capability::Write)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    /// No tools at all. Text in, text out — the same meaning the bridge's `Basic` has.
    Basic,
    /// Reads and lookups: [`ActionClass::Read`] and [`ActionClass::Egress`].
    Read,
    /// The above plus [`ActionClass::VaultWrite`].
    Write,
}

impl Level {
    /// Whether a tool of `class` may be EXPOSED at this level.
    ///
    /// Written as an exhaustive match with no wildcard, for the reason
    /// `ProviderError::is_retryable` is: a new [`ActionClass`] must fail to compile here so
    /// that whoever adds it decides which levels grant it, rather than inheriting a
    /// catch-all's answer. A catch-all defaulting to `false` would be safe and silent,
    /// which is the wrong pair — the decision should be loud.
    pub fn permits(self, class: ActionClass) -> bool {
        match (self, class) {
            (Level::Basic, _) => false,
            (Level::Read, ActionClass::Read | ActionClass::Egress) => true,
            (Level::Read, ActionClass::VaultWrite | ActionClass::ExternalWrite) => false,
            (Level::Write, ActionClass::Read | ActionClass::Egress | ActionClass::VaultWrite) => {
                true
            }
            // Phase 1: nothing is trusted with a third party's state. This arm is the
            // policy, and it is here rather than in a config file so that changing it is
            // a code change with a reviewer.
            (Level::Write, ActionClass::ExternalWrite) => false,
        }
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Level::Basic => "basic",
            Level::Read => "read",
            Level::Write => "write",
        })
    }
}

impl std::str::FromStr for Level {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "basic" => Ok(Level::Basic),
            "read" => Ok(Level::Read),
            "write" => Ok(Level::Write),
            other => Err(format!("{other:?} is not one of: basic, read, write")),
        }
    }
}

// ===========================================================================
// The clock
// ===========================================================================

/// Wall-clock time for records, and MONOTONIC time since the turn began for budgets.
///
/// TWO METHODS BECAUSE THEY ANSWER DIFFERENT QUESTIONS, and conflating them is a real bug
/// rather than a tidiness point: a usage record needs a timestamp somebody can correlate
/// with a provider dashboard (wall clock, which can step backwards over an NTP correction),
/// while a wall-time BUDGET must never be defeated by the clock stepping (monotonic).
///
/// [`Clock::since_start`] is relative to the clock's OWN construction, which is what makes
/// a turn's elapsed time a property of an object the caller creates rather than a `start:
/// Instant` threaded through every function. It also makes the wall budget testable:
/// [`TestClock`] lets a test say "pretend nine minutes passed" without sleeping for nine
/// minutes, which is the only way that ceiling gets a test at all.
pub trait Clock: Send + Sync {
    /// Wall-clock now, for timestamps.
    fn now(&self) -> SystemTime;
    /// Monotonic time since this clock was created, for budgets and per-tool timings.
    fn since_start(&self) -> Duration;
}

/// The real clock. Construct one per turn.
#[derive(Debug)]
pub struct SystemClock {
    started: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        SystemClock {
            started: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        SystemClock::new()
    }
}

impl Clock for SystemClock {
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }

    fn since_start(&self) -> Duration {
        self.started.elapsed()
    }
}

/// A clock a test drives by hand: a fixed wall time, and an elapsed value it sets.
///
/// `pub` rather than `#[cfg(test)]` because the integration tests and the eval driver both
/// live outside the library and need it. It is inert unless constructed.
#[derive(Debug)]
pub struct TestClock {
    now: SystemTime,
    elapsed: std::sync::Mutex<Duration>,
}

impl TestClock {
    /// A clock reading `now` with zero elapsed.
    pub fn new(now: SystemTime) -> Self {
        TestClock {
            now,
            elapsed: std::sync::Mutex::new(Duration::ZERO),
        }
    }

    /// Fixed at the Unix epoch plus `secs`, so a record's timestamp is a constant a test
    /// can assert on exactly.
    pub fn at_epoch_plus(secs: u64) -> Self {
        TestClock::new(SystemTime::UNIX_EPOCH + Duration::from_secs(secs))
    }

    /// Move the monotonic hand forward.
    pub fn advance(&self, by: Duration) {
        if let Ok(mut g) = self.elapsed.lock() {
            *g += by;
        }
    }
}

impl Clock for TestClock {
    fn now(&self) -> SystemTime {
        self.now
    }

    fn since_start(&self) -> Duration {
        self.elapsed.lock().map(|g| *g).unwrap_or(Duration::ZERO)
    }
}

// ===========================================================================
// What a tool is called with, and what it returns
// ===========================================================================

/// The context ONE tool call receives, alongside the [`Scope`].
///
/// Carries no configuration and no capabilities — a tool's ability to act comes from having
/// been constructed and exposed, never from something it reads out of this struct. What is
/// here is what a tool needs in order to be a good citizen of a turn it does not own: who to
/// attribute work to, how to notice it should stop, what time it is, and the one directory
/// a turn is allowed to create files in.
///
/// **PER CALL, NOT PER TURN**, since D3. It was per turn in D2, and [`ToolContext::call_id`]
/// is what changed that: a write takes a lock, and a lock is attributed to the CALL that
/// holds it so a wedged one can be traced to the thing that wedged it (see
/// [`crate::store::guard`]). Building one per call costs three string clones against a tool
/// call that is about to touch a disk or a network.
pub struct ToolContext {
    /// This turn's id. The same value the usage records and the trace carry.
    pub turn_id: String,
    /// The conversation (thread) this turn belongs to.
    pub conversation_id: String,
    /// THIS call's id — the provider's `tool_use` id. Used to attribute a write lock.
    pub call_id: String,
    /// Fires when the turn is cancelled. A long-running tool MUST select on it; a short
    /// one may ignore it, because the loop also checks it between calls.
    pub cancel: CancellationToken,
    /// The turn's clock. `Arc` because tools may run concurrently (see the loop's parallel
    /// dispatch rule) and each needs its own handle to the same clock.
    pub clock: Arc<dyn Clock>,
    /// The per-job artifact staging directory, when the caller set one up.
    ///
    /// **THE ONLY PLACE A TURN MAY CREATE A FILE THAT IS NOT A DOCUMENT**, matching what
    /// `bridge/src/artifacts.rs` already establishes: a per-job directory inside the working
    /// directory, carrying a `.gitignore` of `*`, swept when the turn ends. `None` means the
    /// channel is off, and the artifact tool then REFUSES rather than inventing a location —
    /// a tool that picked its own directory would be writing somewhere nothing sweeps.
    pub artifact_dir: Option<std::path::PathBuf>,
}

impl fmt::Debug for ToolContext {
    /// Hand-written because `Arc<dyn Clock>` has no `Debug` bound, and because a derived
    /// one would be the wrong shape anyway: what a reader wants here is the ids.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ToolContext")
            .field("turn_id", &self.turn_id)
            .field("conversation_id", &self.conversation_id)
            .field("call_id", &self.call_id)
            .field("cancelled", &self.cancel.is_cancelled())
            .field("artifact_dir", &self.artifact_dir)
            .finish_non_exhaustive()
    }
}

/// One piece of what a tool produced.
///
/// [`ResultBlock::Json`] is a separate arm from [`ResultBlock::Text`] rather than a tool
/// serialising its own object, so that the framing layer can pretty-print it INSIDE the
/// frame. A model reads `{\n  "a": 1\n}` more reliably than a 4 KB single line, and the
/// decision about how to render it belongs where the frame is built, not in forty tools.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResultBlock {
    Text(String),
    Json(Value),
    /// An image the tool produced (a chart, a rendered page). Base64, for the reason
    /// `ContentBlock::Image` documents: both wires carry it that way.
    Image {
        media_type: String,
        data_base64: String,
    },
}

/// A tool call that succeeded.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolOk {
    pub content: Vec<ResultBlock>,
    /// A FIXED string describing what this tool did, for the trace.
    ///
    /// `&'static str`, and that is the point rather than an inconvenience: a `String` here
    /// would let a tool put the document it just read into the trace, and the trace's whole
    /// property is that it is content-free (see [`crate::turn::TurnTrace`]). A type that
    /// cannot hold runtime data cannot leak runtime data.
    pub summary_for_trace: &'static str,
}

/// A tool call that did not succeed.
///
/// [`ToolError::Refused`] IS DISTINCT FROM [`ToolError::Failed`] AND MUST STAY THAT WAY.
/// A refusal is a boundary doing its job — a path outside the jail, a tool not in the
/// manifest, an argument the tool will not act on. A failure is the tool trying and not
/// managing. They look the same to the model (both come back as an error result) and they
/// are opposite to an operator: a rising refusal count is the system working, possibly
/// under attack; a rising failure count is the system broken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolError {
    /// The arguments did not match the schema, or could not be interpreted.
    InvalidArgs(String),
    /// A boundary said no. The message is shown to the model and must state WHAT was
    /// refused without restating the thing that was refused (a refused path is named, its
    /// contents are not — there are none).
    Refused(String),
    /// The thing asked for does not exist.
    NotFound,
    /// The tool tried and could not.
    Failed(String),
}

impl ToolError {
    /// The coarse outcome this error records in the trace.
    ///
    /// `InvalidArgs` and `NotFound` are `Failed`, not `Refused`, and the line is drawn at
    /// "did a boundary decide this". Bad arguments are the model getting it wrong and a
    /// missing file is the world's shape; neither is a policy holding, and counting them
    /// as refusals would inflate exactly the number an operator would want to trust.
    pub fn outcome(&self) -> ToolOutcome {
        match self {
            ToolError::Refused(_) => ToolOutcome::Refused,
            ToolError::InvalidArgs(_) | ToolError::NotFound | ToolError::Failed(_) => {
                ToolOutcome::Failed
            }
        }
    }

    /// The text the model sees for this error, inside the frame. Never a stack trace, never
    /// a path outside what the caller already knows.
    pub fn message(&self) -> String {
        match self {
            ToolError::InvalidArgs(m) => format!("invalid arguments: {m}"),
            ToolError::Refused(m) => format!("refused: {m}"),
            ToolError::NotFound => "not found".to_string(),
            ToolError::Failed(m) => format!("failed: {m}"),
        }
    }
}

impl fmt::Display for ToolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for ToolError {}

/// How a tool call came out, as the trace records it. Content-free by construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolOutcome {
    Ok,
    Refused,
    Failed,
}

impl fmt::Display for ToolOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ToolOutcome::Ok => "ok",
            ToolOutcome::Refused => "refused",
            ToolOutcome::Failed => "failed",
        })
    }
}

/// What one tool call produced.
pub type ToolResult = Result<ToolOk, ToolError>;

// ===========================================================================
// The traits
// ===========================================================================

/// One tool.
///
/// `call` RETURNS A BOXED FUTURE rather than being an `async fn`, for exactly the reason
/// `Provider::stream` does: `async fn` in a trait is stable but not dyn-safe, and this
/// trait's whole purpose is to be held as `&dyn Tool` in a name-keyed dispatch table. A
/// generic tool set could not be a `Vec` of different tools, which is the only shape a
/// tool set has.
pub trait Tool: Send + Sync {
    /// The name the model calls it by. Must be stable: it is the dispatch key, it appears
    /// in the trace, and changing it silently retires every reference in a stored thread.
    fn name(&self) -> &str;

    fn description(&self) -> &str;

    /// JSON Schema for the arguments object.
    ///
    /// Checked at manifest-build time for scope-shaped argument names — see
    /// [`crate::scope::check_schema_for_scope_arguments`].
    fn schema(&self) -> Value;

    fn action_class(&self) -> ActionClass;

    /// Run it.
    ///
    /// `scope` is BY REFERENCE and comes from the caller, never from `args`. `args` is the
    /// model's object, already parsed as JSON by the provider layer but otherwise
    /// unvalidated — a tool validates it against its own schema and returns
    /// [`ToolError::InvalidArgs`] rather than trusting it.
    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult>;
}

/// The tools one turn may use — the manifest the provider is shown, and the dispatch table
/// the loop resolves names against, as ONE object.
///
/// They are one object because two objects can disagree. A manifest built separately from
/// the dispatch table is a manifest that can advertise a tool the table cannot resolve
/// (the model calls it, the turn errors) or, far worse, a table that resolves a name the
/// manifest never advertised (the boundary is decoration). Deriving [`manifest`](ToolSet::manifest)
/// from the same map [`get`](ToolSet::get) reads makes both impossible.
pub trait ToolSet: Send + Sync {
    /// The provider-facing list, in a stable order.
    fn manifest(&self) -> Vec<ToolSpec>;

    /// Resolve a name to a tool. EXACT MATCH ONLY — no trimming, no case folding, no
    /// prefix matching. Every one of those would be a way for a generated name to reach a
    /// tool the manifest did not name, which is the one thing dispatch must not do.
    fn get(&self, name: &str) -> Option<&dyn Tool>;

    /// The level this set was built at. Reported in the trace and the CLI's outcome line;
    /// the loop never re-derives permission from it, because the set has already applied it.
    fn max_level(&self) -> Level;
}

// ===========================================================================
// The builder
// ===========================================================================

/// The action classes a Phase-1 tool set may be BUILT with.
///
/// **[`ActionClass::ExternalWrite`] HAS NO ARM HERE, AND THAT IS THE COMPILE-TIME FACT.**
/// [`ToolSetBuilder::add`] takes one of these, so there is no value a call site can write
/// that adds an external-write tool: not a wrong constant, not a runtime branch somebody
/// forgot — no expression at all. A `bool allow_external` parameter or a `debug_assert`
/// would both have been a check that exists only when someone runs the code that trips it.
///
/// The rejected alternative was a marker trait (`trait Exposable: Tool {}`) implemented for
/// the permitted tools. It reads well and proves nothing: `action_class` is a runtime
/// method, so a type could implement the marker and still return `ExternalWrite`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExposedClass {
    Read,
    VaultWrite,
    Egress,
}

impl From<ExposedClass> for ActionClass {
    fn from(e: ExposedClass) -> Self {
        match e {
            ExposedClass::Read => ActionClass::Read,
            ExposedClass::VaultWrite => ActionClass::VaultWrite,
            ExposedClass::Egress => ActionClass::Egress,
        }
    }
}

/// A tool set could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolSetError {
    /// Two tools claimed the same name. Fatal rather than last-wins: dispatch is by exact
    /// name, so two tools under one name means the boundary's dispatch key is ambiguous,
    /// and picking either silently is how the wrong one gets called.
    DuplicateName(String),
    /// The tool's own [`Tool::action_class`] disagrees with the [`ExposedClass`] it was
    /// added under.
    ///
    /// THE ONE RUNTIME CHECK, and it is what closes the loophole [`ExposedClass`] leaves
    /// open: a call site cannot NAME `ExternalWrite`, but it could add a tool as `Read`
    /// whose `action_class()` returns `ExternalWrite`, and the set would then hold an
    /// external-write tool at `Level::Read`. Comparing the two at build time makes the
    /// declaration and the tool agree or fail, which is the property the compile-time half
    /// alone cannot give.
    ClassMismatch {
        tool: String,
        declared: ActionClass,
        actual: ActionClass,
    },
    /// The tool's schema declares an argument that names part of the scope.
    ScopeShapedArgument {
        tool: String,
        error: ScopeShapedArgument,
    },
    /// The tool's schema is not a JSON object. Refused because a manifest entry whose
    /// `input_schema` is a bare string or `null` is a request every wire rejects, and
    /// discovering that on the first live turn is worse than at build time.
    SchemaNotAnObject(String),
    /// The tool's name is empty or holds characters no wire accepts. Both wires require a
    /// tool name matching roughly `[A-Za-z0-9_-]{1,64}`; a name outside it fails the call
    /// with a provider `400` that names nothing useful.
    UnusableName(String),
}

impl fmt::Display for ToolSetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ToolSetError::DuplicateName(n) => write!(f, "two tools are named {n:?}"),
            ToolSetError::ClassMismatch {
                tool,
                declared,
                actual,
            } => write!(f, "{tool:?} was added as {declared} but reports {actual}"),
            ToolSetError::ScopeShapedArgument { tool, error } => {
                write!(f, "{tool:?}: {error}")
            }
            ToolSetError::SchemaNotAnObject(n) => {
                write!(f, "{n:?}: schema() must be a JSON object")
            }
            ToolSetError::UnusableName(n) => write!(
                f,
                "{n:?} is not a usable tool name (1-64 chars of [A-Za-z0-9_-])"
            ),
        }
    }
}

impl std::error::Error for ToolSetError {}

/// Builds a [`StaticToolSet`] at a level.
///
/// The order tools are added is the MANIFEST ORDER, which the loop also dispatches a batch
/// in. That is a real guarantee rather than an accident of a hash map: a batch dispatched
/// in a stable order is a batch that reproduces, and reproducibility is most of what makes
/// a failing turn diagnosable.
pub struct ToolSetBuilder {
    level: Level,
    added: Vec<(ExposedClass, Arc<dyn Tool>)>,
}

impl ToolSetBuilder {
    pub fn new(level: Level) -> Self {
        ToolSetBuilder {
            level,
            added: Vec::new(),
        }
    }

    /// Add a tool, declaring the class it is expected to be.
    ///
    /// Adding a tool the level does not permit is NOT an error — it is how one set
    /// definition serves every level. The tool is simply not in the built set, and its
    /// name is recorded in [`StaticToolSet::withheld`] so an operator can see what a level
    /// cost rather than wondering why the model never used it.
    pub fn add(mut self, class: ExposedClass, tool: Arc<dyn Tool>) -> Self {
        self.added.push((class, tool));
        self
    }

    /// Validate everything, apply the level, and freeze.
    pub fn build(self) -> Result<StaticToolSet, ToolSetError> {
        let level = self.level;
        let mut order: Vec<String> = Vec::new();
        let mut tools: BTreeMap<String, Arc<dyn Tool>> = BTreeMap::new();
        let mut withheld: Vec<String> = Vec::new();
        let mut seen: Vec<String> = Vec::new();

        for (declared, tool) in self.added {
            let name = tool.name().to_string();

            if !usable_tool_name(&name) {
                return Err(ToolSetError::UnusableName(name));
            }
            if seen.iter().any(|n| n == &name) {
                return Err(ToolSetError::DuplicateName(name));
            }
            seen.push(name.clone());

            let declared: ActionClass = declared.into();
            let actual = tool.action_class();
            if declared != actual {
                return Err(ToolSetError::ClassMismatch {
                    tool: name,
                    declared,
                    actual,
                });
            }

            let schema = tool.schema();
            if !schema.is_object() {
                return Err(ToolSetError::SchemaNotAnObject(name));
            }
            if let Err(error) = check_schema_for_scope_arguments(&schema) {
                return Err(ToolSetError::ScopeShapedArgument { tool: name, error });
            }

            // The level is applied HERE, once, and a withheld tool never enters the map —
            // so `get` cannot return it and `manifest` cannot mention it. See the module
            // docs for why this is construction-time rather than call-time.
            if level.permits(actual) {
                order.push(name.clone());
                tools.insert(name, tool);
            } else {
                withheld.push(name);
            }
        }

        Ok(StaticToolSet {
            level,
            order,
            tools,
            withheld,
        })
    }
}

/// A tool name both wires accept. Deliberately narrower than either wire's own rule, since
/// the intersection is what has to hold.
fn usable_tool_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A frozen tool set: the manifest and the dispatch table, as one map.
pub struct StaticToolSet {
    level: Level,
    /// Insertion order of the EXPOSED tools; the manifest's order.
    order: Vec<String>,
    tools: BTreeMap<String, Arc<dyn Tool>>,
    withheld: Vec<String>,
}

impl StaticToolSet {
    /// The names of tools that were defined but are not exposed at this set's level.
    ///
    /// NAMES ONLY, and no way to reach the tool itself. It exists so an operator reading a
    /// turn can tell "the model never wrote because it was not offered a write tool" from
    /// "the model chose not to write", which are the same log line without it.
    pub fn withheld(&self) -> &[String] {
        &self.withheld
    }
}

impl fmt::Debug for StaticToolSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StaticToolSet")
            .field("level", &self.level)
            .field("exposed", &self.order)
            .field("withheld", &self.withheld)
            .finish()
    }
}

impl ToolSet for StaticToolSet {
    fn manifest(&self) -> Vec<ToolSpec> {
        self.order
            .iter()
            .filter_map(|n| self.tools.get(n))
            .map(|t| ToolSpec {
                name: t.name().to_string(),
                description: t.description().to_string(),
                input_schema: t.schema(),
                // `strict` is NOT set from here. It is a per-HOST structured-outputs
                // request (see `ToolSpec::strict` and `Quirks::strict_tools_supported`),
                // and a tool has no way to know which host it will be shown to. A caller
                // that wants it sets it on the request it builds.
                strict: false,
            })
            .collect()
    }

    fn get(&self, name: &str) -> Option<&dyn Tool> {
        self.tools.get(name).map(|t| t.as_ref())
    }

    fn max_level(&self) -> Level {
        self.level
    }
}

/// The empty tool set, at [`Level::Basic`]. What a text-in/text-out turn gets.
pub fn no_tools() -> StaticToolSet {
    ToolSetBuilder::new(Level::Basic)
        .build()
        .expect("a set with no tools cannot fail to build")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A tool whose class and schema a test chooses.
    struct Stub {
        name: &'static str,
        class: ActionClass,
        schema: Value,
    }

    impl Stub {
        fn new(name: &'static str, class: ActionClass) -> Self {
            Stub {
                name,
                class,
                schema: json!({"type": "object", "properties": {"q": {"type": "string"}}}),
            }
        }

        fn with_schema(mut self, schema: Value) -> Self {
            self.schema = schema;
            self
        }

        fn arc(self) -> Arc<dyn Tool> {
            Arc::new(self)
        }
    }

    impl Tool for Stub {
        fn name(&self) -> &str {
            self.name
        }
        fn description(&self) -> &str {
            "a stub"
        }
        fn schema(&self) -> Value {
            self.schema.clone()
        }
        fn action_class(&self) -> ActionClass {
            self.class
        }
        fn call<'a>(
            &'a self,
            _scope: &'a Scope,
            _args: Value,
            _ctx: &'a ToolContext,
        ) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                Ok(ToolOk {
                    content: vec![ResultBlock::Text("stub".into())],
                    summary_for_trace: "stub",
                })
            })
        }
    }

    fn three_tools(level: Level) -> StaticToolSet {
        ToolSetBuilder::new(level)
            .add(
                ExposedClass::Read,
                Stub::new("reader", ActionClass::Read).arc(),
            )
            .add(
                ExposedClass::Egress,
                Stub::new("fetcher", ActionClass::Egress).arc(),
            )
            .add(
                ExposedClass::VaultWrite,
                Stub::new("writer", ActionClass::VaultWrite).arc(),
            )
            .build()
            .unwrap()
    }

    #[test]
    fn the_level_decides_the_manifest_and_a_withheld_tool_is_not_in_the_set() {
        let basic = three_tools(Level::Basic);
        assert!(basic.manifest().is_empty());
        assert!(basic.get("reader").is_none(), "Basic exposes nothing");
        assert_eq!(basic.withheld(), ["reader", "fetcher", "writer"]);

        let read = three_tools(Level::Read);
        let names: Vec<String> = read.manifest().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["reader", "fetcher"], "Read exposes Read + Egress");
        // The structural claim: not merely absent from the manifest, absent from dispatch.
        assert!(read.get("writer").is_none());
        assert_eq!(read.withheld(), ["writer"]);

        let write = three_tools(Level::Write);
        let names: Vec<String> = write.manifest().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["reader", "fetcher", "writer"]);
        assert!(write.withheld().is_empty());
    }

    #[test]
    fn an_external_write_tool_is_exposed_at_no_level() {
        // It cannot be ADDED (there is no `ExposedClass::ExternalWrite` to name), so the
        // only way one reaches a builder is by lying about its class — which is the
        // ClassMismatch below. This asserts the policy the levels encode, so that a future
        // edit to `Level::permits` that granted it fails here.
        for level in [Level::Basic, Level::Read, Level::Write] {
            assert!(
                !level.permits(ActionClass::ExternalWrite),
                "{level} must not grant ExternalWrite in Phase 1"
            );
        }
    }

    #[test]
    fn a_tool_that_lies_about_its_class_fails_the_build() {
        // The loophole `ExposedClass` cannot close on its own: added as a read, reports an
        // external write. Without this check the set would hold it at `Level::Read`.
        let err = ToolSetBuilder::new(Level::Read)
            .add(
                ExposedClass::Read,
                Stub::new("sneaky", ActionClass::ExternalWrite).arc(),
            )
            .build()
            .unwrap_err();
        assert_eq!(
            err,
            ToolSetError::ClassMismatch {
                tool: "sneaky".into(),
                declared: ActionClass::Read,
                actual: ActionClass::ExternalWrite,
            }
        );
    }

    #[test]
    fn a_scope_shaped_argument_is_refused_at_build_time() {
        let err = ToolSetBuilder::new(Level::Read)
            .add(
                ExposedClass::Read,
                Stub::new("lookup", ActionClass::Read)
                    .with_schema(json!({
                        "type": "object",
                        "properties": {
                            "q": {"type": "string"},
                            "tenant_id": {"type": "string"}
                        }
                    }))
                    .arc(),
            )
            .build()
            .unwrap_err();
        match err {
            ToolSetError::ScopeShapedArgument { tool, error } => {
                assert_eq!(tool, "lookup");
                assert_eq!(error.argument, "tenant_id");
            }
            other => panic!("expected a scope-shaped-argument refusal, got {other}"),
        }
    }

    #[test]
    fn duplicate_names_and_unusable_names_fail_the_build() {
        let dup = ToolSetBuilder::new(Level::Read)
            .add(
                ExposedClass::Read,
                Stub::new("same", ActionClass::Read).arc(),
            )
            .add(
                ExposedClass::Read,
                Stub::new("same", ActionClass::Read).arc(),
            )
            .build()
            .unwrap_err();
        assert_eq!(dup, ToolSetError::DuplicateName("same".into()));

        let bad = ToolSetBuilder::new(Level::Read)
            .add(
                ExposedClass::Read,
                Stub::new("has space", ActionClass::Read).arc(),
            )
            .build()
            .unwrap_err();
        assert_eq!(bad, ToolSetError::UnusableName("has space".into()));
    }

    #[test]
    fn a_non_object_schema_fails_the_build() {
        let err = ToolSetBuilder::new(Level::Read)
            .add(
                ExposedClass::Read,
                Stub::new("bad", ActionClass::Read)
                    .with_schema(json!("a string"))
                    .arc(),
            )
            .build()
            .unwrap_err();
        assert_eq!(err, ToolSetError::SchemaNotAnObject("bad".into()));
    }

    #[test]
    fn dispatch_is_exact_and_nothing_near_a_name_resolves() {
        let set = three_tools(Level::Read);
        assert!(set.get("reader").is_some());
        for near in ["Reader", " reader", "reader ", "read", "readerx", ""] {
            assert!(
                set.get(near).is_none(),
                "{near:?} must not resolve — dispatch is exact"
            );
        }
    }

    #[test]
    fn levels_are_ordered_and_cumulative_like_the_bridges_capability() {
        assert!(Level::Basic < Level::Read && Level::Read < Level::Write);
        assert_eq!(Level::Read.min(Level::Write), Level::Read);
        for class in [ActionClass::Read, ActionClass::Egress] {
            assert!(Level::Read.permits(class) && Level::Write.permits(class));
        }
        assert!(!Level::Read.permits(ActionClass::VaultWrite));
        assert!(Level::Write.permits(ActionClass::VaultWrite));
    }

    #[test]
    fn refusal_and_failure_are_distinguishable_outcomes() {
        assert_eq!(
            ToolError::Refused("x".into()).outcome(),
            ToolOutcome::Refused
        );
        for e in [
            ToolError::Failed("x".into()),
            ToolError::NotFound,
            ToolError::InvalidArgs("x".into()),
        ] {
            assert_eq!(e.outcome(), ToolOutcome::Failed);
        }
    }

    #[test]
    fn the_test_clock_drives_elapsed_without_sleeping() {
        let c = TestClock::at_epoch_plus(1_756_000_000);
        assert_eq!(c.since_start(), Duration::ZERO);
        c.advance(Duration::from_secs(600));
        assert_eq!(c.since_start(), Duration::from_secs(600));
        assert_eq!(
            c.now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            1_756_000_000
        );
    }
}
