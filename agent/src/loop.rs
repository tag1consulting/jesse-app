//! **The agent loop** — send, read, call tools, splice, send again.
//!
//! (The file is `loop.rs`; the module is `turn`, because `loop` is a Rust keyword. See the
//! `#[path]` attribute in `lib.rs`.)
//!
//! ---- THE LIFECYCLE ----------------------------------------------------------
//!
//! ```text
//!   load thread ──► append the user's message ──┐
//!                                               │
//!    ┌──────────────────────────────────────────┘
//!    ▼
//!   check every budget ceiling ─── over? ──► stop, with the answer so far
//!    │
//!   build the request: system blocks (cacheable) · the thread · the MANIFEST
//!    │
//!   stream ─── TextDelta ──────────► the sink, as it arrives
//!    │     └── ToolUse* ───────────► collected
//!    │
//!   record ONE usage record ──────► the ledger seam
//!   append the assistant message ─► the thread
//!    │
//!   stop_reason?
//!    ├── end_turn / max_tokens / stop_sequence ──► done
//!    └── tool_use ──► dispatch (manifest order) ──► ToolActivity to the sink
//!                     frame every result ─────────► append as tool_result blocks
//!                     └──────────────────────── iterate
//! ```
//!
//! ---- THE FOUR PROPERTIES THIS FILE IS RESPONSIBLE FOR -----------------------
//!
//! 1. **Dispatch is by exact manifest name.** A name the [`ToolSet`] does not resolve is
//!    [`ToolError::Refused`], recorded in the trace by name, and forwarded NOWHERE — not to
//!    another tool, not to a fallback, not to a shell. See [`ToolSet`]'s module docs for
//!    why the manifest and the dispatch table are one object.
//! 2. **Every tool result the model sees is framed**, by [`crate::framing::frame_tool_result`],
//!    and the framed bytes are what goes into the thread.
//! 3. **Every provider call leaves exactly one usage record**, including the ones that
//!    failed. See [`crate::usage`].
//! 4. **The trace is content-free**: per tool, a name, a class, a duration and one of three
//!    outcomes. The same discipline `bridge/src/turntrace.rs` documents and tests for its
//!    timing log.
//!
//! ---- WHAT THE SINK SEES AND WHY IT IS SO LITTLE -----------------------------
//!
//! [`EventSink`] has two methods, and that is not an oversight: it is the bridge's mid-turn
//! contract (`bridge/src/harness/mod.rs`) — a text delta and a coarse tool-activity hint —
//! reproduced exactly. The provider layer's [`Event`] is deliberately richer because the
//! LOOP is its consumer and the loop needs tool names, arguments and token counts to do its
//! job. What reaches a client is this projection, and it is a filter rather than a
//! translation: `TextDelta` means what `StreamEvent::TextDelta` means, and a
//! [`ToolActivity`]'s name is the same name.
//!
//! Tool INPUTS, tool RESULTS, token counts and per-tool timings are not sink events. Each
//! of them would carry vault content to a phone screen, which is the decision the bridge
//! already recorded and this layer has no business relitigating.

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::Poll;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::budget::{Budget, Ceiling, PriceDeck, Spend};
use crate::framing::{frame_tool_error, frame_tool_result};
use crate::provider::{
    BoxFuture, ContentBlock, Event, Message, Provider, ProviderError, Request, Role, Sampling,
    StopReason as WireStop, SystemBlock, Thinking, TokenUsage, ToolSpec, Usage,
};
use crate::scope::Scope;
use crate::thread::{ThreadError, ThreadId, ThreadStore};
use crate::tools::{ActionClass, Clock, ToolContext, ToolError, ToolOutcome, ToolResult, ToolSet};
use crate::usage::{Phase, UsageRecord, UsageSink};

// ===========================================================================
// The sink
// ===========================================================================

/// A tool call started. Name only.
///
/// `refused` IS THE STRUCTURAL REFUSAL AND ONLY THAT. It is emitted at dispatch time, and
/// at dispatch time the only refusal that has happened is "this name is not in the
/// manifest" — a tool that runs and then refuses (a path outside its jail, say) has not
/// refused yet. Waiting for the outcome would make this a post-hoc event rather than a
/// mid-turn hint, which is the opposite of what a client shows a spinner for. The
/// after-the-fact truth lives in the [`TurnTrace`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolActivity {
    pub name: String,
    pub refused: bool,
}

/// Where mid-turn events go. See the module docs for why there are only two.
pub trait EventSink: Send + Sync {
    fn on_text_delta(&self, delta: &str);
    fn on_tool_activity(&self, activity: ToolActivity);
}

/// A sink that drops everything — a turn nobody is watching.
#[derive(Debug, Default)]
pub struct NullEventSink;

impl EventSink for NullEventSink {
    fn on_text_delta(&self, _delta: &str) {}
    fn on_tool_activity(&self, _activity: ToolActivity) {}
}

/// A sink that keeps what it saw, for tests and for the CLI's stderr echo.
#[derive(Debug, Default)]
pub struct CollectingSink {
    inner: std::sync::Mutex<(String, Vec<ToolActivity>)>,
}

impl CollectingSink {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every text delta, concatenated in arrival order.
    pub fn text(&self) -> String {
        self.inner.lock().map(|g| g.0.clone()).unwrap_or_default()
    }

    pub fn activities(&self) -> Vec<ToolActivity> {
        self.inner.lock().map(|g| g.1.clone()).unwrap_or_default()
    }
}

impl EventSink for CollectingSink {
    fn on_text_delta(&self, delta: &str) {
        if let Ok(mut g) = self.inner.lock() {
            g.0.push_str(delta);
        }
    }

    fn on_tool_activity(&self, activity: ToolActivity) {
        if let Ok(mut g) = self.inner.lock() {
            g.1.push(activity);
        }
    }
}

// ===========================================================================
// The trace
// ===========================================================================

/// One tool call, as the trace records it.
///
/// **CONTENT-FREE BY CONSTRUCTION.** There is nowhere here to put an argument or a result:
/// the name is a manifest key, the class is an enum, the duration is a number and the
/// outcome is one of three words. That is the same property `bridge/src/turntrace.rs`
/// documents for `ToolCallTiming`, arrived at the same way — by there being no field that
/// could hold content, rather than by a rule about what to put in one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolTrace {
    pub name: String,
    pub class: ActionClass,
    pub ms: u64,
    pub outcome: ToolOutcome,
}

/// What a turn did, without saying anything about what it was about.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnTrace {
    /// Provider calls made.
    pub iterations: u32,
    /// One entry per tool call, in dispatch order.
    pub tools: Vec<ToolTrace>,
}

impl TurnTrace {
    /// How many calls a boundary refused. The number an operator watches: it rising is the
    /// system working, possibly under attack, and it is the reason
    /// [`ToolOutcome::Refused`] is not folded into [`ToolOutcome::Failed`].
    pub fn refusals(&self) -> usize {
        self.tools
            .iter()
            .filter(|t| t.outcome == ToolOutcome::Refused)
            .count()
    }
}

// ===========================================================================
// Stopping
// ===========================================================================

/// Why a turn ended.
///
/// Named `StopReason` inside this module, as the design note spells it, even though
/// [`crate::provider::StopReason`] exists: they answer different questions and the crate
/// root re-exports this one as `TurnStopReason` so a caller can hold both. The wire's says
/// why one CALL stopped generating; this says why the TURN stopped, which is the same thing
/// only in the trivial case.
#[derive(Debug, Clone, PartialEq)]
pub enum StopReason {
    /// The model finished.
    EndTurn,
    /// The last call hit its output cap. The answer is TRUNCATED, and the turn stops rather
    /// than continuing: another iteration would ask the model to continue a sentence it
    /// cannot see the end of, which produces a plausible seam rather than a longer answer.
    MaxTokens,
    /// A stop sequence matched.
    StopSequence,
    /// A budget ceiling would have been exceeded by the next call.
    Budget(Ceiling),
    /// The cancellation token fired.
    Cancelled,
    /// A provider call failed.
    Provider(ProviderError),
    /// The thread store failed. Fatal to the turn: without a thread there is no
    /// conversation to append to, and continuing would produce an answer that vanishes.
    Store(String),
    /// Anything else, carried verbatim — including a wire stop reason nobody anticipated.
    Other(String),
}

impl StopReason {
    /// A short, content-free label for a log or the usage record.
    pub fn label(&self) -> String {
        match self {
            StopReason::EndTurn => "end_turn".into(),
            StopReason::MaxTokens => "max_tokens".into(),
            StopReason::StopSequence => "stop_sequence".into(),
            StopReason::Budget(c) => format!("budget:{c}"),
            StopReason::Cancelled => "cancelled".into(),
            StopReason::Provider(e) => format!("provider:{}", e.class()),
            StopReason::Store(_) => "store".into(),
            StopReason::Other(_) => "other".into(),
        }
    }
}

impl std::fmt::Display for StopReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StopReason::Provider(e) => write!(f, "provider error: {e}"),
            StopReason::Store(m) => write!(f, "thread store: {m}"),
            StopReason::Other(m) => write!(f, "{m}"),
            other => f.write_str(&other.label()),
        }
    }
}

// ===========================================================================
// Input, dependencies, outcome
// ===========================================================================

/// Everything one turn is about.
pub struct TurnInput {
    /// Whom the turn acts for. Constructed once, here, by the caller.
    pub scope: Scope,
    /// The turn's own id: the correlation key across the usage records, the trace and the
    /// tool context. Caller-chosen so it can be the bridge's job id.
    pub turn_id: String,
    /// The conversation to continue, or `None` to start one.
    pub thread_id: Option<ThreadId>,
    /// The system prefix, ALREADY ASSEMBLED. The caller owns persona and manual assembly;
    /// D5's persona renderer produces these blocks. The loop never edits their text; the one
    /// FLAG it may set is a cache breakpoint on the last block when the caller set none, and
    /// the private `prepare_system` documents why.
    pub system: Vec<SystemBlock>,
    /// The user's message.
    pub user_text: String,
    /// Images attached to the user's message. `ContentBlock::Image` values; anything else
    /// here is dropped with a note, because a caller passing a `ToolResult` as a user
    /// attachment is a bug that should be visible rather than a message the wire rejects.
    pub user_images: Vec<ContentBlock>,
    pub budget: Budget,
    pub prices: PriceDeck,
    pub thinking: Thinking,
    /// What the turn may do. Built at a [`crate::tools::Level`]; see [`ToolSet`].
    pub tools: Arc<dyn ToolSet>,
    /// The per-job artifact staging directory, or `None` to leave the channel off.
    ///
    /// The LOOP does not create, sweep or even look inside it — it hands the path to
    /// [`ToolContext`] and nothing more. Creating it here would make the loop responsible
    /// for a lifecycle that belongs to whoever owns the job: `bridge/src/artifacts.rs`
    /// creates the directory before the turn runs and sweeps it after.
    pub artifact_dir: Option<std::path::PathBuf>,
}

/// The collaborators a turn borrows.
pub struct TurnDeps<'a> {
    pub provider: &'a dyn Provider,
    pub threads: &'a dyn ThreadStore,
    pub usage: &'a dyn UsageSink,
    /// The turn's clock. Created at the start of the turn — [`Clock::since_start`] is what
    /// the wall budget and the per-tool timings are measured on.
    pub clock: Arc<dyn Clock>,
}

/// What a turn produced.
#[derive(Debug, Clone, PartialEq)]
pub struct TurnOutcome {
    pub thread_id: ThreadId,
    /// Every visible text delta of the turn, concatenated — including the narration around
    /// intermediate tool calls, because that is what the user watched stream past. The last
    /// message alone would silently drop it.
    pub text: String,
    pub stop_reason: StopReason,
    /// The turn's aggregate token vector, in the shape `bridge/src/shadow.rs` already uses.
    pub usage: TokenUsage,
    pub cost_usd: f64,
    pub iterations: u32,
    pub tool_calls: usize,
    pub trace: TurnTrace,
}

// ===========================================================================
// The loop
// ===========================================================================

/// Run one turn to completion.
///
/// Returns a [`TurnOutcome`] rather than a `Result`, always. A turn that failed still has
/// a thread id, a partial answer, a bill and a trace, and every one of those is something
/// the caller must handle — a `Result` would let a caller `?` its way past all of it. The
/// failure is in [`TurnOutcome::stop_reason`], where it cannot be discarded by accident.
pub async fn run_turn(
    input: TurnInput,
    deps: &TurnDeps<'_>,
    sink: &dyn EventSink,
    cancel: CancellationToken,
) -> TurnOutcome {
    let TurnInput {
        scope,
        turn_id,
        thread_id,
        system,
        user_text,
        user_images,
        budget,
        prices,
        thinking,
        tools,
        artifact_dir,
    } = input;

    let clock = deps.clock.clone();
    let mut trace = TurnTrace::default();
    let mut spend = Spend::default();
    let mut answer = String::new();

    // ---- The thread ------------------------------------------------------
    let thread_id = match thread_id {
        Some(id) => id,
        None => match deps.threads.create() {
            Ok(id) => id,
            Err(e) => return store_failure(ThreadId::generate(), e, trace, spend, prices),
        },
    };
    let mut messages = match deps.threads.load(&thread_id) {
        Ok(t) => t.messages,
        Err(e) => return store_failure(thread_id, e, trace, spend, prices),
    };

    // ---- The user's message ----------------------------------------------
    let user = build_user_message(&user_text, user_images);
    if let Err(e) = deps.threads.append(&thread_id, std::slice::from_ref(&user)) {
        return store_failure(thread_id, e, trace, spend, prices);
    }
    messages.push(user);

    // ---- The invariants for the whole turn -------------------------------
    //
    // The manifest is derived ONCE and re-sent unchanged on every iteration. A manifest
    // rebuilt per call would let the set of tools change under the model mid-turn, so a
    // tool_use the model emitted against iteration 3's manifest could be dispatched
    // against iteration 4's — which is a boundary that depends on timing.
    let manifest: Vec<ToolSpec> = tools.manifest();
    let system = prepare_system(system);
    // The turn-scoped half of every call's context. `call_id` is filled in per call — see
    // `ToolContext`, which became per-call in D3 so a write lock can be attributed to the
    // call holding it.
    let ctx = TurnContext {
        turn_id: turn_id.clone(),
        conversation_id: thread_id.to_string(),
        cancel: cancel.clone(),
        clock: clock.clone(),
        artifact_dir: artifact_dir.clone(),
    };

    let stop = loop {
        // ---- Before the call, never during one ---------------------------
        if cancel.is_cancelled() {
            break StopReason::Cancelled;
        }
        if let Some(ceiling) = spend.check(&budget, clock.since_start()) {
            break StopReason::Budget(ceiling);
        }

        let phase = if spend.iterations == 0 {
            Phase::Main
        } else {
            Phase::ToolFollowup
        };
        let request = Request {
            system: system.clone(),
            messages: messages.clone(),
            tools: manifest.clone(),
            sampling: Sampling {
                // The per-call ceiling is a CAP, applied here — see `budget`'s module docs.
                max_output_tokens: budget.max_output_tokens_per_call,
                // Sampling beyond the output cap is not exposed on `TurnInput` yet. It has
                // no caller: the bridge sets neither, and a knob with no caller is a knob
                // whose default nobody has reason to believe. Adding it is one field.
                temperature: None,
                stop_sequences: Vec::new(),
            },
            thinking,
            batch_eligible: false,
            // Never sent to the provider; it appears in the audit line. The turn id is the
            // right value because it is the key everything else about this turn is under.
            request_tag: turn_id.clone(),
        };

        let call_started = clock.since_start();
        let outcome = run_one_call(deps.provider, &request, sink, &cancel).await;
        let latency_ms = duration_ms(clock.since_start().saturating_sub(call_started));

        // ---- One record per call, success or not -------------------------
        //
        // Emitted BEFORE the branch on what happened, so there is no arm of the match that
        // can return without having recorded. See `usage`'s module docs for why a failed
        // call is still a billed call.
        let usage = outcome.usage.clone().unwrap_or_default();
        deps.usage.record(
            UsageRecord {
                turn_id: turn_id.clone(),
                conversation_id: thread_id.to_string(),
                wire: deps.provider.wire(),
                model: outcome.model.clone(),
                provider_request_id: usage.provider_request_id.clone(),
                input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens,
                cache_read_tokens: usage.cache_read_tokens,
                cache_write_tokens: usage.cache_write_tokens,
                cost_usd: prices.cost_usd(&usage),
                latency_ms: outcome.latency_ms.unwrap_or(latency_ms),
                stop_reason: outcome.stop_label(),
                attempt: outcome.attempt,
                phase,
                ..UsageRecord::at(clock.now())
            }
            .with_scope(&scope),
        );
        spend.record_call(&usage, &prices);
        trace.iterations = spend.iterations;
        answer.push_str(&outcome.text);

        // ---- The assistant's message goes into the thread ----------------
        //
        // Even when the call errored mid-stream: the model said what it said, the tokens
        // were bought, and a resumed thread that omitted it would ask the model to produce
        // an answer it has already partly produced.
        if !outcome.content.is_empty() {
            if let Err(e) = append_all(
                deps.threads,
                &thread_id,
                &mut messages,
                vec![Message {
                    role: Role::Assistant,
                    content: outcome.content.clone(),
                }],
            ) {
                break StopReason::Store(e.to_string());
            }
        }

        if let Some(error) = outcome.error {
            break match error {
                ProviderError::Cancelled => StopReason::Cancelled,
                other => StopReason::Provider(other),
            };
        }

        match outcome.stop_reason {
            Some(WireStop::EndTurn) | None => break StopReason::EndTurn,
            Some(WireStop::MaxTokens) => break StopReason::MaxTokens,
            Some(WireStop::StopSequence) => break StopReason::StopSequence,
            Some(WireStop::Other(s)) => break StopReason::Other(s),
            Some(WireStop::ToolUse) => {}
        }

        if outcome.tool_uses.is_empty() {
            // A wire that says `tool_use` and asks for nothing. Continuing would re-send an
            // identical request and get the same answer, forever — an iteration ceiling
            // would eventually stop it, expensively, with a stop reason that named the
            // budget rather than the bug.
            break StopReason::Other("the wire reported tool_use with no tool calls".into());
        }

        // ---- Dispatch ----------------------------------------------------
        let dispatched = dispatch(
            &tools,
            &outcome.tool_uses,
            &manifest,
            &scope,
            &ctx,
            sink,
            &clock,
            &cancel,
        )
        .await;
        spend.tool_calls += dispatched.len() as u32;
        for d in &dispatched {
            trace.tools.push(d.trace.clone());
        }

        let results = Message {
            role: Role::User,
            content: dispatched.into_iter().map(|d| d.block).collect(),
        };
        if let Err(e) = append_all(deps.threads, &thread_id, &mut messages, vec![results]) {
            break StopReason::Store(e.to_string());
        }

        if cancel.is_cancelled() {
            break StopReason::Cancelled;
        }
    };

    TurnOutcome {
        thread_id,
        text: answer,
        stop_reason: stop,
        usage: TokenUsage {
            input_tokens: Some(spend.input_tokens),
            output_tokens: Some(spend.output_tokens),
            cache_read_input_tokens: Some(spend.cache_read_tokens),
            cache_creation_input_tokens: Some(spend.cache_write_tokens),
        },
        cost_usd: spend.cost_usd,
        iterations: spend.iterations,
        tool_calls: trace.tools.len(),
        trace,
    }
}

// ===========================================================================
// One provider call
// ===========================================================================

/// What reading one call's stream produced.
#[derive(Debug, Default)]
struct CallOutcome {
    /// The assistant message's blocks, in the order the model produced them.
    content: Vec<ContentBlock>,
    /// The visible text of this call.
    text: String,
    /// The tool calls the model asked for, in the order it asked.
    tool_uses: Vec<ToolUseRequest>,
    usage: Option<Usage>,
    stop_reason: Option<WireStop>,
    error: Option<ProviderError>,
    model: String,
    /// From the provider's own audit record, which measures the whole call INCLUDING its
    /// retries. `None` when the call failed before the stream existed, where D1 does not
    /// surface an audit — the loop's own measurement is used then.
    latency_ms: Option<u64>,
    attempt: u32,
}

impl CallOutcome {
    fn stop_label(&self) -> String {
        match (&self.error, &self.stop_reason) {
            (Some(e), _) => e.class().to_string(),
            (None, Some(WireStop::EndTurn)) => "end_turn".into(),
            (None, Some(WireStop::ToolUse)) => "tool_use".into(),
            (None, Some(WireStop::MaxTokens)) => "max_tokens".into(),
            (None, Some(WireStop::StopSequence)) => "stop_sequence".into(),
            (None, Some(WireStop::Other(s))) => format!("other:{s}"),
            (None, None) => "none".into(),
        }
    }
}

/// One tool call the model asked for.
#[derive(Debug, Clone, PartialEq)]
struct ToolUseRequest {
    id: String,
    name: String,
    arguments: Value,
}

/// Make one call and read its stream to the end.
async fn run_one_call(
    provider: &dyn Provider,
    request: &Request,
    sink: &dyn EventSink,
    cancel: &CancellationToken,
) -> CallOutcome {
    let mut out = CallOutcome {
        attempt: 1,
        ..Default::default()
    };

    let mut stream = match provider.stream(request, cancel.clone()).await {
        Ok(s) => s,
        Err(e) => {
            out.error = Some(e);
            return out;
        }
    };
    let audit = stream.audit();

    // Text blocks and tool blocks interleave, and the ORDER IS PRESERVED: a run of text
    // deltas becomes one text block, and a tool block closes it. Coalescing all text into
    // a single leading block would re-order what the model said relative to what it did,
    // which a resumed thread then replays wrongly.
    let mut pending_text = String::new();
    let mut open_args: BTreeMap<String, (String, String)> = BTreeMap::new(); // id -> (name, json)

    while let Some(event) = stream.recv().await {
        match event {
            Event::TextDelta(delta) => {
                sink.on_text_delta(&delta);
                out.text.push_str(&delta);
                pending_text.push_str(&delta);
            }
            // Never forwarded to the sink. Most hosts do not stream reasoning at all and
            // some stream an encrypted blob; a client that rendered it would show nothing
            // on three hosts out of four and something unreadable on the fourth.
            Event::ThinkingDelta(_) => {}
            Event::ToolUseStart { id, name } => {
                if !pending_text.is_empty() {
                    out.content
                        .push(ContentBlock::Text(std::mem::take(&mut pending_text)));
                }
                open_args.insert(id, (name, String::new()));
            }
            Event::ToolUseArgsDelta { id, json_fragment } => {
                if let Some((_, buf)) = open_args.get_mut(&id) {
                    buf.push_str(&json_fragment);
                }
            }
            Event::ToolUseEnd { id } => {
                if let Some((name, buf)) = open_args.remove(&id) {
                    // D1 guarantees `ToolUseEnd` only after the accumulated arguments
                    // parsed, so this parse cannot fail for a conforming adapter. It is
                    // still handled rather than unwrapped: an empty argument string is the
                    // documented legal case for a no-argument tool, and a panic here would
                    // take down a turn on the one input that is allowed to look wrong.
                    let arguments = if buf.trim().is_empty() {
                        Value::Object(Default::default())
                    } else {
                        match serde_json::from_str(&buf) {
                            Ok(v) => v,
                            Err(e) => {
                                out.error = Some(ProviderError::Protocol(format!(
                                    "tool {name:?} closed with unparseable arguments: {e}"
                                )));
                                break;
                            }
                        }
                    };
                    out.content.push(ContentBlock::ToolUse {
                        id: id.clone(),
                        name: name.clone(),
                        arguments: arguments.clone(),
                    });
                    out.tool_uses.push(ToolUseRequest {
                        id,
                        name,
                        arguments,
                    });
                }
            }
            Event::Usage(u) => out.usage = Some(u),
            Event::Done { stop_reason } => out.stop_reason = Some(stop_reason),
            Event::Error(e) => {
                out.error = Some(e);
                break;
            }
        }
    }
    if !pending_text.is_empty() {
        out.content.push(ContentBlock::Text(pending_text));
    }

    if let Some(a) = audit.get() {
        out.model = a.model;
        out.latency_ms = Some(a.latency_ms);
        out.attempt = a.attempt;
        if out.usage.is_none() {
            out.usage = a.usage;
        }
    }
    out
}

// ===========================================================================
// Dispatch
// ===========================================================================

/// The turn-scoped half of a [`ToolContext`], cloned into a per-call one at dispatch.
///
/// It exists because `ToolContext` is per CALL and all but one of its fields are per TURN.
/// Rebuilding the whole thing from the loop's locals at each call site would mean the day a
/// field is added, one of those sites is missed.
#[derive(Clone)]
struct TurnContext {
    turn_id: String,
    conversation_id: String,
    cancel: CancellationToken,
    clock: Arc<dyn Clock>,
    artifact_dir: Option<std::path::PathBuf>,
}

impl TurnContext {
    fn for_call(&self, call_id: &str) -> ToolContext {
        ToolContext {
            turn_id: self.turn_id.clone(),
            conversation_id: self.conversation_id.clone(),
            call_id: call_id.to_string(),
            cancel: self.cancel.clone(),
            clock: self.clock.clone(),
            artifact_dir: self.artifact_dir.clone(),
        }
    }
}

/// One dispatched tool call: what goes into the thread, and what goes into the trace.
struct Dispatched {
    block: ContentBlock,
    trace: ToolTrace,
}

/// Dispatch a batch of tool calls and frame every result.
#[allow(clippy::too_many_arguments)]
async fn dispatch(
    tools: &Arc<dyn ToolSet>,
    requested: &[ToolUseRequest],
    manifest: &[ToolSpec],
    scope: &Scope,
    ctx: &TurnContext,
    sink: &dyn EventSink,
    clock: &Arc<dyn Clock>,
    cancel: &CancellationToken,
) -> Vec<Dispatched> {
    // ---- Order ------------------------------------------------------------
    //
    // MANIFEST ORDER, with the model's own order breaking ties (a stable sort). The model
    // may emit a parallel batch in any order it likes and the same batch can arrive
    // differently ordered on two runs of the same prompt; sorting by a fixed key makes a
    // turn reproducible, and reproducibility is most of what makes a failing turn
    // diagnosable. A name not in the manifest sorts last, which is where a refusal belongs.
    let position = |name: &str| {
        manifest
            .iter()
            .position(|t| t.name == name)
            .unwrap_or(usize::MAX)
    };
    let mut order: Vec<usize> = (0..requested.len()).collect();
    order.sort_by_key(|i| position(&requested[*i].name));

    // ---- Activity, at dispatch time ---------------------------------------
    for i in &order {
        let name = &requested[*i].name;
        sink.on_tool_activity(ToolActivity {
            name: name.clone(),
            refused: tools.get(name).is_none(),
        });
    }

    // ---- Parallel or sequential -------------------------------------------
    //
    // PARALLEL ONLY WHEN EVERY REQUESTED TOOL IS `Read`. The reason is ordering, not
    // safety in the abstract: a write and a read of the same document in one batch have no
    // defined order, so running them concurrently makes the answer depend on which future
    // the executor polled first — and the model, which asked for both in one breath, has
    // no way to express which it meant. Reads commute with each other, so a batch of them
    // has the same result in any order and may as well be concurrent.
    //
    // `Egress` is NOT `Read` for this purpose, deliberately. An egress call is a read that
    // sends bytes off the host, and two of them racing is two requests leaving in an order
    // nobody chose. It is cheap to run them one at a time and it makes the sequence in a
    // network log match the sequence in the trace.
    let all_reads = requested.iter().all(|r| {
        tools
            .get(&r.name)
            .is_some_and(|t| t.action_class() == ActionClass::Read)
    });

    let mut out: Vec<Option<Dispatched>> = (0..requested.len()).map(|_| None).collect();

    if all_reads && requested.len() > 1 {
        let futures: Vec<BoxFuture<'_, (usize, Dispatched)>> = order
            .iter()
            .map(|i| {
                let i = *i;
                let r = &requested[i];
                Box::pin(async move { (i, call_one(tools, r, scope, ctx, clock).await) })
                    as BoxFuture<'_, (usize, Dispatched)>
            })
            .collect();
        for (i, d) in join_all(futures).await {
            out[i] = Some(d);
        }
    } else {
        for i in &order {
            let r = &requested[*i];
            // Checked BETWEEN tool calls, per the cancellation contract. A tool already
            // running is not interrupted here — it holds the token itself and may select
            // on it; interrupting it from outside would leave a half-finished write with
            // nothing recording that it happened.
            if cancel.is_cancelled() {
                out[*i] = Some(not_run(r));
                continue;
            }
            out[*i] = Some(call_one(tools, r, scope, ctx, clock).await);
        }
    }

    // Re-emitted in DISPATCH order rather than the model's, so the thread's tool_result
    // blocks read in the order the trace lists them.
    order.into_iter().filter_map(|i| out[i].take()).collect()
}

/// Resolve one name and run it, or refuse it.
async fn call_one(
    tools: &Arc<dyn ToolSet>,
    request: &ToolUseRequest,
    scope: &Scope,
    ctx: &TurnContext,
    clock: &Arc<dyn Clock>,
) -> Dispatched {
    let started = clock.since_start();

    let Some(tool) = tools.get(&request.name) else {
        // ---- THE STRUCTURAL BOUNDARY ------------------------------------
        //
        // The name is not in the manifest. It is refused, it is traced BY NAME, and it is
        // forwarded nowhere: no fuzzy match against a similar tool, no fallback handler,
        // no shell. The class recorded is `Read`, because there is no tool and therefore
        // no class — and `Read` is the one that claims the least.
        let error = ToolError::Refused("tool not granted".into());
        let (content, _) = frame_tool_error(&request.name, &error);
        return Dispatched {
            block: ContentBlock::ToolResult {
                id: request.id.clone(),
                content,
                is_error: true,
            },
            trace: ToolTrace {
                name: request.name.clone(),
                class: ActionClass::Read,
                ms: duration_ms(clock.since_start().saturating_sub(started)),
                outcome: ToolOutcome::Refused,
            },
        };
    };

    let class = tool.action_class();
    // The per-call context: the turn's fields plus THIS call's id, which is what a write
    // lock is attributed to.
    let call_ctx = ctx.for_call(&request.id);
    let result: ToolResult = tool.call(scope, request.arguments.clone(), &call_ctx).await;
    let ms = duration_ms(clock.since_start().saturating_sub(started));

    let (content, is_error, outcome) = match &result {
        Ok(ok) => {
            let (content, _) = frame_tool_result(&request.name, &ok.content);
            (content, false, ToolOutcome::Ok)
        }
        Err(e) => {
            let (content, _) = frame_tool_error(&request.name, e);
            (content, true, e.outcome())
        }
    };

    Dispatched {
        block: ContentBlock::ToolResult {
            id: request.id.clone(),
            content,
            is_error,
        },
        trace: ToolTrace {
            name: request.name.clone(),
            class,
            ms,
            outcome,
        },
    }
}

/// A tool call the turn was cancelled before reaching.
///
/// **A PLACEHOLDER RESULT IS APPENDED ANYWAY**, and that is the decision. Both wires
/// require every `tool_use` block to be answered by a `tool_result` in the next message; a
/// thread holding an unanswered one is a thread that cannot be resumed on any wire. The
/// rejected alternative was to drop the unanswered `tool_use` blocks from the assistant
/// message — which rewrites what the model actually said, and the thread's whole job is to
/// replay exactly what the model saw.
///
/// It traces as `Failed`, not `Refused`. A cancellation is the call failing to complete,
/// not a boundary declining it, and folding it into the refusal count would corrupt the one
/// number an operator reads as "the boundary held".
fn not_run(request: &ToolUseRequest) -> Dispatched {
    let error = ToolError::Failed("not run: the turn was cancelled before this tool ran".into());
    let (content, _) = frame_tool_error(&request.name, &error);
    Dispatched {
        block: ContentBlock::ToolResult {
            id: request.id.clone(),
            content,
            is_error: true,
        },
        trace: ToolTrace {
            name: request.name.clone(),
            class: ActionClass::Read,
            ms: 0,
            outcome: ToolOutcome::Failed,
        },
    }
}

// ===========================================================================
// Helpers
// ===========================================================================

/// Build the user's message: the text, then any image blocks.
///
/// A turn with no text and no images still produces a message with an empty text block,
/// because both wires reject a message whose content array is empty and the resulting `400`
/// names nothing a caller could act on.
fn build_user_message(text: &str, images: Vec<ContentBlock>) -> Message {
    let mut content: Vec<ContentBlock> = Vec::new();
    if !text.is_empty() {
        content.push(ContentBlock::Text(text.to_string()));
    }
    for block in images {
        match block {
            image @ ContentBlock::Image { .. } => content.push(image),
            other => eprintln!(
                "jesse-agent: note dropped a non-image block from user_images ({})",
                match other {
                    ContentBlock::Text(_) => "text",
                    ContentBlock::ToolUse { .. } => "tool_use",
                    ContentBlock::ToolResult { .. } => "tool_result",
                    ContentBlock::Image { .. } => unreachable!(),
                }
            ),
        }
    }
    if content.is_empty() {
        content.push(ContentBlock::Text(String::new()));
    }
    Message {
        role: Role::User,
        content,
    }
}

/// The system prefix, with a cache breakpoint if the caller did not set one.
///
/// THE LOOP MARKS THE LAST BLOCK CACHEABLE ONLY WHEN NO BLOCK IS MARKED. It never clears a
/// flag and never moves one, because a caller who set a breakpoint has decided where the
/// stable/volatile boundary is and knows something this function does not.
///
/// The default exists because the loop knows something the CALLER does not: this prefix is
/// about to be re-sent up to `max_iterations` times within seconds. An unmarked prefix is
/// therefore paid for in full on every iteration of every turn, which on the Anthropic wire
/// is roughly a ten-fold difference on the largest part of the prompt. The rejected
/// alternative — leaving it entirely to the caller — is correct in principle and produces a
/// silent, permanent overcharge in practice, because the caller assembling a persona has no
/// reason to be thinking about a loop's iteration count.
fn prepare_system(mut system: Vec<SystemBlock>) -> Vec<SystemBlock> {
    if !system.is_empty() && !system.iter().any(|b| b.cacheable) {
        if let Some(last) = system.last_mut() {
            last.cacheable = true;
        }
    }
    system
}

/// Append to the store and to the in-memory conversation together, so the two cannot
/// diverge. If the store refuses, the in-memory copy is NOT advanced — a turn continuing
/// with messages the thread does not have would produce an answer that vanishes on resume.
fn append_all(
    store: &dyn ThreadStore,
    id: &ThreadId,
    messages: &mut Vec<Message>,
    new: Vec<Message>,
) -> Result<(), ThreadError> {
    store.append(id, &new)?;
    messages.extend(new);
    Ok(())
}

fn duration_ms(d: Duration) -> u64 {
    d.as_millis().min(u128::from(u64::MAX)) as u64
}

/// The outcome for a turn that could not reach its thread.
fn store_failure(
    thread_id: ThreadId,
    e: ThreadError,
    trace: TurnTrace,
    spend: Spend,
    _prices: PriceDeck,
) -> TurnOutcome {
    TurnOutcome {
        thread_id,
        text: String::new(),
        stop_reason: StopReason::Store(e.to_string()),
        usage: TokenUsage::default(),
        cost_usd: spend.cost_usd,
        iterations: spend.iterations,
        tool_calls: 0,
        trace,
    }
}

/// Await every future concurrently and return their results in input order.
///
/// HAND-ROLLED RATHER THAN `futures-util`, and the reason is the crate's existing stance:
/// D1 took `futures-core` for the `Stream` TRAIT and explicitly no combinators. Pulling in
/// `futures-util` — a large crate — for one `join_all` would reverse that decision for a
/// function this short. It is also the whole of what is needed: there is no select, no
/// buffering, no stream adaptor anywhere in this loop.
///
/// It re-polls every still-pending future on each wake, which is O(n) wakeups rather than
/// the O(1) a waker-per-future implementation achieves. For a tool batch — single digits —
/// that is not a cost worth a dependency, and the comment is here so that if a batch ever
/// gets large this is a known place to look rather than a surprise.
async fn join_all<T>(futures: Vec<BoxFuture<'_, T>>) -> Vec<T> {
    let mut pending: Vec<Option<BoxFuture<'_, T>>> = futures.into_iter().map(Some).collect();
    let mut done: Vec<Option<T>> = pending.iter().map(|_| None).collect();
    std::future::poll_fn(move |cx| {
        let mut all_ready = true;
        for (slot, result) in pending.iter_mut().zip(done.iter_mut()) {
            if let Some(f) = slot {
                match Pin::new(f).poll(cx) {
                    Poll::Ready(v) => {
                        *result = Some(v);
                        *slot = None;
                    }
                    Poll::Pending => all_ready = false,
                }
            }
        }
        if all_ready {
            Poll::Ready(
                std::mem::take(&mut done)
                    .into_iter()
                    .map(|v| v.expect("every future resolved"))
                    .collect(),
            )
        } else {
            Poll::Pending
        }
    })
    .await
}
