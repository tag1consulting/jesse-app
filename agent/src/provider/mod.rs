//! **The provider-neutral model** — one request shape, one response vocabulary, and the
//! [`Provider`] trait every wire adapter implements.
//!
//! THE LAYERING RULE, and it is the one thing this module exists to enforce: nothing
//! above this layer ever names a wire. No `anthropic`, no `openai`, no `content_block_delta`,
//! no `finish_reason`, no `cache_control` — those strings live in the adapter modules
//! ([`anthropic`], [`openai_chat`], [`openai_responses`]) and nowhere else in the tree. A caller builds a
//! [`Request`], gets a stream of [`Event`], and cannot tell which wire served it except
//! by asking [`Provider::wire`]. D2's loop is written against this vocabulary alone,
//! which is what made the third adapter a new FILE rather than a new branch in the loop.
//! D8's whole job was to find out whether that held against a wire the trait was not
//! shaped around; it did, and everywhere it strained is written down in `agent/LEAKS.md`.
//!
//! WHY A NEUTRAL MODEL AT ALL, rather than passing Anthropic-shaped JSON around and
//! translating at the edge (which is what `bridge/src/vision.rs` does today, with its
//! Anthropic-shape-first / OpenAI-shape-fallback parser). That works for a one-shot
//! helper call whose whole result is a string. It does not survive tool use: the moment
//! the loop has to read tool calls back out, decide, and send results in, "Anthropic
//! shape plus a fallback" becomes two loops wearing one name. The neutral model is the
//! decision to pay that translation cost once, in two adapters, instead of at every
//! branch of the loop.
//!
//! ---- RELATIONSHIP TO THE BRIDGE'S MID-TURN EVENT CONTRACT --------------------
//!
//! `bridge/src/harness/mod.rs` states that the bridge's mid-turn vocabulary is exactly
//! two things — a text delta and a coarse tool-activity hint — and that tool INPUTS, tool
//! RESULTS, token counts and per-tool timing are deliberately NOT mid-turn events,
//! because all of them would reach a phone screen carrying vault content.
//!
//! [`Event`] here is RICHER than that contract, and the difference is not a widening of
//! it. These events are consumed by the agent loop (D2), which is the thing that DECIDES;
//! it needs the tool name, the accumulated arguments and the token counts to do its job.
//! What the loop then forwards to a client is still the harness contract's two events,
//! and that projection is the loop's responsibility, not this layer's. The vocabulary is
//! kept deliberately compatible — `TextDelta` means what `StreamEvent::TextDelta` means,
//! and `ToolUseStart.name` is the same name a `ToolActivity` would carry — so that
//! projection is a filter and never a translation.

use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

pub mod anthropic;
pub mod config;
pub mod http;
pub mod openai_chat;
pub mod openai_responses;

/// A `Provider` that plays a fixed script instead of speaking HTTP.
///
/// COMPILED ONLY UNDER `cfg(test)` OR THE `scripted` FEATURE, never in a release build. A
/// fake provider in the shipped library would be a `Provider` a caller could reach by
/// accident, and one whose whole job is to return answers nobody generated.
#[cfg(any(test, feature = "scripted"))]
pub mod scripted;

pub use anthropic::AnthropicMessages;
pub use config::{AuthScheme, ProviderConfig, Quirks, Retries, Timeouts};
pub use http::{CallAudit, EventStream};
pub use openai_chat::OpenAiChat;
pub use openai_responses::OpenAiResponses;

// ===========================================================================
// The request
// ===========================================================================

/// One text block of the system prefix, with the caching flag that decides whether the
/// adapter marks it as a cache breakpoint on wires that have prompt caching.
///
/// The prefix is an ORDERED LIST rather than one string because caching is positional:
/// a cache breakpoint covers everything before it, so "the stable half of the system
/// prompt" and "today's date" have to be separable blocks or the whole prefix is
/// invalidated daily. Flattening to a single string with a marker was rejected — it
/// pushes the same structure into the string and makes every adapter re-parse it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SystemBlock {
    pub text: String,
    /// Mark this block as a caching breakpoint where the wire supports it. On a wire with
    /// no prompt caching this is inert — never an error, so the same [`Request`] is valid
    /// on every wire (see [`Capabilities::prompt_caching`]).
    pub cacheable: bool,
}

impl SystemBlock {
    /// A block that is not a cache breakpoint.
    pub fn plain(text: impl Into<String>) -> Self {
        SystemBlock {
            text: text.into(),
            cacheable: false,
        }
    }

    /// A block that IS a cache breakpoint on wires that have caching.
    pub fn cacheable(text: impl Into<String>) -> Self {
        SystemBlock {
            text: text.into(),
            cacheable: true,
        }
    }
}

/// Who authored a message. There is no `system` role here on purpose: the system prefix
/// is [`Request::system`], a separate ordered list, because that is what the Anthropic
/// wire is shaped like and because it is the only shape in which a cache breakpoint has
/// a well-defined meaning. The OpenAI adapter folds it back into a leading `system`
/// message; that fold is a wire detail and lives in the adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
}

/// The content of a tool result: plain text, or structured blocks (an image a tool
/// returned, say). Two arms rather than always-blocks because text is the overwhelmingly
/// common case and both wires have a cheaper encoding for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolResultContent {
    Text(String),
    Blocks(Vec<ContentBlock>),
}

/// One block of message content.
///
/// `ToolUse` carries its arguments as a parsed [`serde_json::Value`], not as the raw
/// fragment string the wire delivered. The loop re-sends a tool call it read back in the
/// previous turn, and re-sending an unparsed fragment would mean the loop's copy of the
/// conversation could hold something no adapter can serialise. Arguments are validated
/// as JSON when the streaming block closes (see [`ProviderError::Protocol`]), so by the
/// time a `ToolUse` block exists it is known to be well-formed.
/// ADJACENTLY TAGGED (`kind` + `value`), NOT INTERNALLY TAGGED, and the difference is not
/// cosmetic: **serde cannot serialise a newtype variant holding a string under an internal
/// tag at all.** `#[serde(tag = "kind")]` compiles here and then fails at RUNTIME with
/// "cannot serialize tagged newtype variant ContentBlock::Text containing a string" — so a
/// `ContentBlock::Text` could be constructed, matched and sent on either wire (the adapters
/// build their JSON by hand) but never written to disk. D1 never serialised one, so the
/// derive was never exercised and the defect was invisible; D2's thread store serialises
/// every message of every turn and hit it on its first append.
///
/// Adjacent tagging is the smallest fix that keeps the type's shape: every variant
/// round-trips, including the two struct variants, and no call site changes. Rewriting
/// `Text(String)` as `Text { text: String }` would also have worked and was rejected — it
/// changes the constructor at every call site in the crate and in the conformance suite,
/// to buy a marginally flatter JSON shape nothing reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ContentBlock {
    Text(String),
    /// An image, as base64 bytes plus its media type (`image/png`, `image/jpeg`, …).
    ///
    /// Base64 rather than raw bytes because BOTH wires carry it as base64 in JSON — the
    /// Anthropic wire as `source.data`, the OpenAI wire inside a `data:` URL — so
    /// carrying `Vec<u8>` here would mean encoding on every send with no other benefit.
    Image {
        media_type: String,
        data_base64: String,
    },
    ToolUse {
        id: String,
        name: String,
        arguments: serde_json::Value,
    },
    ToolResult {
        /// The id of the [`ContentBlock::ToolUse`] this answers.
        id: String,
        content: ToolResultContent,
        /// The tool failed. Both wires have a first-class representation for this, and
        /// signalling it in the text ("Error: …") instead was rejected: the model treats
        /// a flagged error differently from a string that happens to start with "Error".
        is_error: bool,
    },
    /// **A PROVIDER-MINTED REASONING ARTEFACT, OPAQUE TO THIS LAYER.**
    ///
    /// D13, implementing `LEAKS.md` L5. Two wires require a reasoning model's own previous
    /// reasoning to come back on the next request of the same turn, or the chain is lost the
    /// moment the loop dispatches a tool:
    ///
    /// * **Messages** returns `thinking` blocks carrying a `signature`, and its documentation
    ///   is explicit that the assistant turn must be echoed *complete and unmodified* — that
    ///   rebuilding the message, or filtering out a `redacted_thinking` block, is a `400`.
    /// * **Responses**, which this crate always drives with `store: false`, returns
    ///   `reasoning` items carrying `encrypted_content`, to be echoed in the next `input`.
    ///
    /// **NOTHING IN THIS CRATE LOOKS INSIDE `opaque`.** It is the block exactly as it
    /// arrived, held as its own JSON value so "echo it back verbatim" is the trivial
    /// operation rather than a re-serialisation that has to be got right. It is not text, it
    /// is not content, and it is not shown to anyone: it renders as nothing, counts as
    /// nothing, reaches no transcript, and is dropped at the end of the turn rather than
    /// persisted (see `crate::r#loop`).
    Reasoning {
        /// The provider's own id for the item, where the wire gives one — `rs_…` on
        /// Responses. `None` on Messages, whose thinking blocks carry no id.
        id: Option<String>,
        /// Who minted it. The guard, not decoration: an adapter handed a block minted by a
        /// different wire or a different model refuses the request as
        /// [`ProviderError::Protocol`] before any bytes go out, because an opaque artefact
        /// is meaningful only to the exact model that produced it and replaying one across
        /// a model switch is a `400` at best.
        minted_by: ReasoningOrigin,
        /// The artefact, verbatim.
        opaque: serde_json::Value,
    },
}

/// Which wire and model minted a [`ContentBlock::Reasoning`].
///
/// Enough to refuse a cross-provider replay and nothing more. The model is a `String`
/// because that is what the provider config carries and what a `400` would name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasoningOrigin {
    pub wire: Wire,
    pub model: String,
}

impl ReasoningOrigin {
    pub fn new(wire: Wire, model: impl Into<String>) -> Self {
        ReasoningOrigin {
            wire,
            model: model.into(),
        }
    }

    /// Refuse anything this (wire, model) did not mint.
    ///
    /// **BEFORE ANY BYTES GO OUT.** The failure this prevents is a `400` on the SECOND
    /// iteration of a turn — the worst place to discover it, which `LEAKS.md` L5 named as
    /// one of the three costs of making this change.
    pub fn check(&self, wire: Wire, model: &str) -> Result<(), ProviderError> {
        if self.wire == wire && self.model == model {
            return Ok(());
        }
        Err(ProviderError::Protocol(format!(
            "a reasoning block minted by {:?}/{} was handed to {:?}/{}; an opaque reasoning \
             artefact is meaningful only to the model that produced it",
            self.wire, self.model, wire, model
        )))
    }
}

/// One message in the conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: Vec<ContentBlock>,
}

impl Message {
    /// A single-text-block user message — the common case, spelled short.
    pub fn user(text: impl Into<String>) -> Self {
        Message {
            role: Role::User,
            content: vec![ContentBlock::Text(text.into())],
        }
    }

    /// A single-text-block assistant message.
    pub fn assistant(text: impl Into<String>) -> Self {
        Message {
            role: Role::Assistant,
            content: vec![ContentBlock::Text(text.into())],
        }
    }
}

/// One tool the model may call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// JSON Schema for the arguments object.
    pub input_schema: serde_json::Value,
    /// Ask the wire to CONSTRAIN generation to the schema rather than merely describe it.
    ///
    /// Honoured only where the host supports it ([`Quirks::strict_tools_supported`]);
    /// dropped with a logged note elsewhere. It is a request, never a guarantee — a tool
    /// call's arguments are validated as JSON on arrival regardless, because `strict`
    /// being on is not evidence that this particular host implemented it.
    pub strict: bool,
}

/// Sampling parameters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sampling {
    /// The cap on generated tokens. Required — not `Option` — because both wires require
    /// it (the Anthropic wire rejects a request without `max_tokens`) and a defaulted
    /// value that differs per adapter would be exactly the kind of silent per-wire
    /// divergence this layer exists to prevent.
    pub max_output_tokens: u32,
    /// `f64`, not `f32`, and the reason is what reaches the wire. `serde_json` renders
    /// `0.7f32` as `0.699999988079071` — the exact value of the nearest `f32` — so a
    /// caller writing `Some(0.7)` would send a number no human put there, and a host that
    /// validates temperature against a short list of steps can reject it. `f64` round-trips
    /// a decimal literal, which is the only form anyone actually writes.
    pub temperature: Option<f64>,
    pub stop_sequences: Vec<String>,
}

impl Default for Sampling {
    fn default() -> Self {
        Sampling {
            max_output_tokens: 1024,
            temperature: None,
            stop_sequences: Vec::new(),
        }
    }
}

/// How much room the model gets to think before answering, expressed in four
/// provider-neutral levels rather than a token count.
///
/// A NEUTRAL LEVEL, NOT A BUDGET, and that is the decision worth recording. The two wires
/// do not express this in the same units and cannot be made to: the Anthropic wire takes
/// a token budget, the OpenAI wire takes an enumerated effort. A neutral `budget_tokens:
/// u32` would have to be invented back into an effort string for OpenAI (by a threshold
/// nobody can justify), and a neutral effort maps onto a token budget by a table an
/// adapter can state and a reader can check. So the neutral type is the coarser one, and
/// each adapter documents its own mapping — see [`anthropic::thinking_budget_tokens`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Thinking {
    #[default]
    Off,
    Low,
    Medium,
    High,
}

/// A request, independent of wire.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    /// The system prefix, in order.
    pub system: Vec<SystemBlock>,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolSpec>,
    pub sampling: Sampling,
    pub thinking: Thinking,
    /// This request could be served by a batch API instead of a live call.
    ///
    /// NO ADAPTER ACTS ON THIS YET, and every adapter must accept it. It is here now
    /// rather than added later because it is a property of the REQUEST — the caller knows
    /// whether it is willing to wait; an adapter never can — and retrofitting a field
    /// that every call site has to revisit is the expensive kind of change. Adapters
    /// ignore it; none of them may reject a request for carrying it.
    pub batch_eligible: bool,
    /// An opaque caller-chosen label for logs. Appears in the audit line
    /// ([`CallAudit::request_tag`]) so a call can be traced without correlating on
    /// anything that carries content. Never sent to the provider.
    pub request_tag: String,
}

impl Default for Request {
    fn default() -> Self {
        Request {
            system: Vec::new(),
            messages: Vec::new(),
            tools: Vec::new(),
            sampling: Sampling::default(),
            thinking: Thinking::Off,
            batch_eligible: false,
            request_tag: String::new(),
        }
    }
}

// ===========================================================================
// The response: usage
// ===========================================================================

/// Token usage for one call, plus the provider's own request id when it exposes one.
///
/// THE INVARIANT, and it is the whole reason this type is defined rather than passed
/// through per wire: **`input_tokens` EXCLUDES cache reads.** `cache_read_tokens` is a
/// separate, non-overlapping count, and the total prompt size is
/// `input_tokens + cache_read_tokens + cache_write_tokens`.
///
/// This is the invariant `bridge/src/shadow.rs` already documents for [`ShadowUsage`]'s
/// four fields ("Anthropic-shape `input_tokens` already EXCLUDES cache reads"), and it
/// is stated identically here so the [`From<Usage>`](TokenUsage) conversion is a rename
/// and not a recalculation. It holds on both wires, but only ONE of them gives it away
/// for free: the Anthropic wire reports the three counts already disjoint, while the
/// OpenAI wire reports `prompt_tokens` INCLUSIVE of its cached tokens, so
/// [`openai_chat`] subtracts. A caller that summed these fields without the invariant
/// would over-count every cached OpenAI turn and price it wrong, which is precisely the
/// bug the shadow audit's cost model would have surfaced months later as "GLM got more
/// expensive".
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Usage {
    /// Prompt tokens billed at the input rate, EXCLUDING cache reads.
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    /// Prompt tokens served from cache, billed at the (cheaper) cache-read rate.
    pub cache_read_tokens: Option<u64>,
    /// Prompt tokens written INTO the cache, billed at (or above) the input rate.
    /// `None` on wires that do not report it — the OpenAI Chat wire has no equivalent
    /// field, which is a genuine absence and not a zero. The Messages and Responses wires
    /// both report one.
    pub cache_write_tokens: Option<u64>,
    /// Output tokens the model spent thinking, when the wire reports a breakdown.
    ///
    /// **A SUBSET OF `output_tokens`, NOT A FOURTH DISJOINT COUNT**, and it is the one
    /// field here that breaks the sum-to-the-total rule the other three obey. That is not
    /// an inconsistency to be tidied away: reasoning tokens ARE output tokens — generated,
    /// billed at the output rate, already inside `output_tokens` on every wire that
    /// reports them. Subtracting them out would understate the output bill by exactly the
    /// thinking, so nothing prices this field and [`crate::budget::PriceDeck::cost_usd`]
    /// deliberately ignores it.
    ///
    /// ADDED IN D8, and it is the ONE additive trait change the third adapter forced. The
    /// Responses wire reports `usage.output_tokens_details.reasoning_tokens` and the
    /// neutral model had nowhere to put it, so the question "how much of this turn's bill
    /// was thinking" — the operational question a reasoning model raises the moment it is
    /// deployed — could be answered on the wire and not by a caller. `None` on the two
    /// wires that report no breakdown, which is a genuine absence: a `Some(0)` would claim
    /// the host measured zero thinking.
    pub reasoning_tokens: Option<u64>,
    /// The provider's own id for this request, when the wire exposes one, for correlating
    /// with a provider-side dashboard. Never a token, never a URL.
    pub provider_request_id: Option<String>,
}

/// A usage vector shaped EXACTLY like `bridge/src/shadow.rs`'s `ShadowUsage`: the same
/// four optional fields, the same names, the same serde attributes.
///
/// It exists so D4 can adopt it with a type alias instead of defining the shape a second
/// time. Two definitions of a token vector is how the invariant above gets restated
/// slightly differently in one of them and quietly stops holding; a `pub type ShadowUsage
/// = jesse_agent::TokenUsage;` cannot drift.
///
/// The field NAMES are the bridge's, not [`Usage`]'s, deliberately: they are the names
/// already on disk in the metrics log and in `ShadowUsage`'s serialised form, and
/// renaming them would invalidate that history for a cosmetic gain. So the neutral type
/// reads well for new code and this one stays wire-compatible with what exists.
///
/// [`Usage::provider_request_id`] is dropped by the conversion. That is not a loss:
/// `ShadowUsage` is the COST vector and a request id has no price. Widening the bridge's
/// on-disk shape to carry one was rejected as out of scope for D1.
///
/// [`Usage::reasoning_tokens`] is dropped for the SAME reason, restated because it is the
/// newer field and the temptation is the other way. It has no price — it is already inside
/// `output_tokens`, which this type carries — so adding it here would widen a shape the
/// bridge's metrics history is already written in, to record a number that changes no cost.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<u64>,
}

impl From<Usage> for TokenUsage {
    /// A pure rename. Every adapter has already normalised its wire's arithmetic to the
    /// invariant documented on [`Usage`], so there is nothing left to compute here — and
    /// if there were, it would belong in the adapter, where the wire's own convention is
    /// known, not in a conversion that cannot tell the wires apart.
    fn from(u: Usage) -> Self {
        TokenUsage {
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            cache_read_input_tokens: u.cache_read_tokens,
            cache_creation_input_tokens: u.cache_write_tokens,
        }
    }
}

// ===========================================================================
// The response: events
// ===========================================================================

/// Why generation stopped, normalised across wires.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    /// The model finished its answer.
    EndTurn,
    /// The model wants one or more tools called. This is the arm D2's loop continues on.
    ToolUse,
    /// `max_output_tokens` was reached. The answer is TRUNCATED.
    MaxTokens,
    /// One of `stop_sequences` matched.
    StopSequence,
    /// Anything a wire reports that does not map onto the four above, carried verbatim
    /// (`content_filter`, a host-specific string, …). An arm rather than an error because
    /// a stop reason nobody anticipated is still a completed call, and the loop should be
    /// able to log it and stop rather than treat it as a protocol violation.
    Other(String),
}

/// One event from a streaming call.
///
/// ORDERING GUARANTEES, which D2's loop may rely on and every adapter must provide:
///   * `ToolUseStart{id}` precedes every `ToolUseArgsDelta{id}`, which precede
///     `ToolUseEnd{id}`. Ids are unique within a call.
///   * `ToolUseEnd` is emitted ONLY after the accumulated arguments parsed as JSON. A
///     block whose arguments do not parse yields [`ProviderError::Protocol`] instead —
///     never a `ToolUseEnd` with an empty argument object.
///   * At most one `Usage` and at most one `Done`, with `Usage` first when both occur.
///   * `Done` or `Error` is the LAST event; exactly one of them ends every stream.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A chunk of the visible answer.
    TextDelta(String),
    ToolUseStart {
        id: String,
        name: String,
    },
    /// A fragment of the tool's argument JSON. Fragments are delivered as the wire framed
    /// them and are NOT individually parseable — only their concatenation is.
    ToolUseArgsDelta {
        id: String,
        json_fragment: String,
    },
    ToolUseEnd {
        id: String,
    },
    /// A chunk of the model's reasoning, delivered ONLY when the wire exposes it.
    ///
    /// NEVER REQUIRED, and a consumer must not treat its absence as a failure: most hosts
    /// do not stream reasoning at all, and some stream an encrypted blob that is not text.
    /// A loop that needs thinking to make progress is a loop that breaks on every other
    /// host, so this is strictly a display/telemetry signal.
    ThinkingDelta(String),
    /// **A COMPLETE PROVIDER-MINTED REASONING ARTEFACT**, for the loop to echo back on the
    /// next request of the same turn. D13; see [`ContentBlock::Reasoning`].
    ///
    /// Distinct from [`Event::ThinkingDelta`], and the distinction is the whole point.
    /// A `ThinkingDelta` is a fragment of readable text for a spinner — display and
    /// telemetry, never required, and on most hosts absent. This is the opaque artefact the
    /// wire will want back, is not text, and is never shown to anyone. A wire that streams
    /// visible reasoning may emit both; a wire that streams neither is not failing.
    Reasoning {
        id: Option<String>,
        minted_by: ReasoningOrigin,
        opaque: serde_json::Value,
    },
    Usage(Usage),
    Done {
        stop_reason: StopReason,
    },
    /// The call failed. Terminal — no further events follow.
    ///
    /// A failure that happens BEFORE the stream is handed to the caller surfaces as
    /// `Err(ProviderError)` from [`Provider::stream`] instead; that is the boundary the
    /// retry policy is defined against (see [`http`]).
    Error(ProviderError),
}

// ===========================================================================
// Errors
// ===========================================================================

/// A provider call's failure, classified.
///
/// THE CLASSIFICATION MIRRORS `bridge/src/health.rs`'s `classify_probe_status`, and
/// keeping the two consistent is deliberate: the health prober's whole job is to predict
/// whether a real call would work, so a status it calls fatal and a real call calls
/// retryable would make a green light mean nothing. Concretely, the shared rules are
///
///   * `401` / `403` → [`Auth`](ProviderError::Auth); the prober's `unauthorized`. Fatal
///     on both sides, because a bad key does not get better by being asked again.
///   * `404` → [`NotFound`](ProviderError::NotFound); the prober's `unknown-model`. The
///     model or path is not served HERE — also fatal, also for the same reason.
///   * `>= 500` → [`Overloaded`](ProviderError::Overloaded) / retryable; the prober's
///     `http-5xx`.
///   * timeout / connect / other transport → [`Timeout`](ProviderError::Timeout) and
///     [`Transport`](ProviderError::Transport), matching the prober's `timeout` /
///     `connect` / `transport` classes one for one.
///
/// WHERE THEY DIVERGE, and why. The prober tolerates every OTHER 4xx as healthy — a
/// deliberate decision recorded in `health.rs`, on the grounds that a gateway's body
/// quirk or a transient 429 must not blank a model out of the picker. A real call cannot
/// be so relaxed: a `400` here IS the call failing, so it is
/// [`BadRequest`](ProviderError::BadRequest) and fatal, and `429` is
/// [`RateLimited`](ProviderError::RateLimited) and retryable. The prober is asking "is
/// this endpoint alive"; this type is answering "did this call produce tokens". Both
/// treatments of `429` are right for their own question.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    /// `401` / `403`. NEVER retried.
    Auth,
    /// `404` — the model or the path is not served at this base URL. NEVER retried.
    NotFound,
    /// `429`. Retried, honouring `retry_after` when the response carried one.
    RateLimited { retry_after: Option<Duration> },
    /// `529` (Anthropic's own overload status) or `503`. Retried.
    Overloaded,
    /// A `4xx` the provider explained, carrying the provider's message with anything
    /// key-shaped stripped ([`http::redact`]) and the whole thing length-capped.
    /// NEVER retried — the request is what is wrong, so re-sending it cannot help.
    BadRequest(String),
    /// Connect / DNS / TLS / socket failure. Retried.
    Transport,
    /// The call did not produce response headers inside the configured budget. Retried.
    Timeout,
    /// The [`CancellationToken`] fired. NEVER retried — the caller asked to stop.
    Cancelled,
    /// The stream violated its own contract: it ended with no terminal event, it closed a
    /// tool block whose accumulated arguments were not valid JSON, it delivered a delta
    /// for a block it never opened. NEVER retried — a host that speaks the protocol
    /// wrongly speaks it wrongly twice, and retrying hides it.
    Protocol(String),
}

impl ProviderError {
    /// Whether the retry policy may re-send this call. See [`http`] for the rest of the
    /// policy (attempt cap, backoff, and the rule that a retry may only happen BEFORE the
    /// first event reached the caller).
    ///
    /// Written as an exhaustive match with no wildcard ON PURPOSE: a new arm added to
    /// [`ProviderError`] must fail to compile here, so the person adding it decides
    /// whether it is retryable instead of inheriting `false` from a catch-all.
    pub fn is_retryable(&self) -> bool {
        match self {
            ProviderError::RateLimited { .. }
            | ProviderError::Overloaded
            | ProviderError::Transport
            | ProviderError::Timeout => true,
            ProviderError::Auth
            | ProviderError::NotFound
            | ProviderError::BadRequest(_)
            | ProviderError::Cancelled
            | ProviderError::Protocol(_) => false,
        }
    }

    /// A coarse, content-free class name for the audit line — the same vocabulary
    /// `health.rs` records in `HealthStatus::last_error_class`. Never carries the
    /// provider's message (which, though redacted, is still their text).
    pub fn class(&self) -> &'static str {
        match self {
            ProviderError::Auth => "unauthorized",
            ProviderError::NotFound => "unknown-model",
            ProviderError::RateLimited { .. } => "rate-limited",
            ProviderError::Overloaded => "overloaded",
            ProviderError::BadRequest(_) => "bad-request",
            ProviderError::Transport => "transport",
            ProviderError::Timeout => "timeout",
            ProviderError::Cancelled => "cancelled",
            ProviderError::Protocol(_) => "protocol",
        }
    }
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProviderError::Auth => write!(f, "unauthorized"),
            ProviderError::NotFound => write!(f, "model or path not served"),
            ProviderError::RateLimited { retry_after } => match retry_after {
                Some(d) => write!(f, "rate limited (retry after {}s)", d.as_secs()),
                None => write!(f, "rate limited"),
            },
            ProviderError::Overloaded => write!(f, "provider overloaded"),
            ProviderError::BadRequest(m) => write!(f, "bad request: {m}"),
            ProviderError::Transport => write!(f, "transport error"),
            ProviderError::Timeout => write!(f, "timed out"),
            ProviderError::Cancelled => write!(f, "cancelled"),
            ProviderError::Protocol(m) => write!(f, "protocol violation: {m}"),
        }
    }
}

impl std::error::Error for ProviderError {}

/// A provider could not be CONSTRUCTED from this configuration.
///
/// Separate from [`ProviderError`], which is about a call that was made. Construction
/// failures are the caller's configuration being wrong, and they are reported as a typed
/// error rather than a panic because the base URL and wire come from operator config at
/// runtime — a `panic!` there takes the process down for a typo in a TOML file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// The wire is declared but has no adapter yet.
    ///
    /// **NO WIRE IS IN THIS STATE TODAY.** D8 implemented [`Wire::Responses`], the last
    /// declared-and-unimplemented one, so [`build_provider`] currently cannot return this.
    ///
    /// KEPT ANYWAY, and deliberately, because the sequence it exists for is the one the
    /// enum is designed around: a wire is DECLARED first (so every `match` on [`Wire`]
    /// gains its arm while the shape is still cheap to change) and implemented after. The
    /// gap between those two commits is exactly when constructing a provider must be a
    /// typed refusal rather than a panic or a silent fallback to a neighbouring wire.
    /// Deleting the variant now would mean the next wire's declaration commit has to
    /// re-invent it, or — much more likely — skip the refusal and fall back.
    UnimplementedWire(Wire),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::UnimplementedWire(w) => {
                write!(f, "no adapter for the {w} wire yet")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

// ===========================================================================
// The trait
// ===========================================================================

/// Which HTTP contract a provider speaks.
///
/// The wire is a property of the ENDPOINT, not of the vendor. `api.openai.com`,
/// `api.fireworks.ai` and a local vLLM all speak [`Wire::Chat`]; a gateway can front an
/// OpenAI-family model on an Anthropic surface and then it speaks [`Wire::Messages`].
/// Naming this after the vendor was rejected for exactly that reason — it would have made
/// "which adapter" a question about branding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Wire {
    /// Anthropic Messages: `POST {base_url}/v1/messages`.
    Messages,
    /// OpenAI Chat Completions: `POST {base_url}/chat/completions`.
    Chat,
    /// OpenAI Responses: `POST {base_url}/responses`, where `base_url` is the API ROOT
    /// (e.g. `https://api.openai.com/v1`) — the segment BEFORE `/responses`, unlike
    /// [`Wire::Messages`], where the base is a bare host.
    ///
    /// DECLARED IN D1, IMPLEMENTED IN D8 by [`openai_responses`]. It was named a step
    /// ahead of its adapter because it already mattered — `codex-cli` speaks only this
    /// wire — so anything the enum's shape forced (a third arm in every match) was
    /// discovered while the shape was still cheap to change. That decision is what made
    /// the adapter a new file and not a new branch anywhere else.
    Responses,
}

impl fmt::Display for Wire {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Wire::Messages => "messages",
            Wire::Chat => "chat",
            Wire::Responses => "responses",
        })
    }
}

/// What a provider can do. Read by the caller BEFORE building a request, so an
/// unsupported feature is a decision the caller makes rather than a 400 it discovers.
///
/// Every field is a static property of the adapter-plus-configuration, not a probe: this
/// never makes a network call. A host that claims a capability its model lacks is a
/// configuration error, and no amount of introspection here would catch it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capabilities {
    pub tool_use: bool,
    pub streaming: bool,
    pub vision: bool,
    pub prompt_caching: bool,
    pub thinking: bool,
    pub parallel_tool_calls: bool,
    /// The model's context window, when the caller configured one. `None` means "not
    /// declared" — never "unlimited". Nothing on either wire reports this, so it can only
    /// ever come from configuration.
    pub max_context_tokens: Option<u32>,
}

/// A boxed future, the shape every `async` method on [`Provider`] returns.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// One wire adapter.
///
/// `stream` RETURNS A BOXED FUTURE rather than being an `async fn`, and that is a
/// deliberate cost. `async fn` in a trait is stable, but it is not dyn-safe, and the whole
/// point of this trait is to be used as `&dyn Provider`: the conformance suite drives one
/// table of cases across both adapters through a trait object precisely so a behaviour
/// that differs between them fails the suite instead of being papered over in a
/// per-adapter test. Generic dispatch would have made that table impossible to write
/// once. `bridge/src/health.rs`'s `HealthProbe::probe` is the same shape for the same
/// reason, so this is the repository's existing answer to this question, not a new one.
pub trait Provider: Send + Sync {
    fn wire(&self) -> Wire;

    fn capabilities(&self) -> Capabilities;

    /// Start a streaming call.
    ///
    /// The returned future resolves once the response HEADERS are in and the status is
    /// good; retries (see [`http`]) all happen inside it, before any event has reached
    /// the caller. After it resolves, failures arrive as [`Event::Error`] on the stream.
    ///
    /// `cancel` firing at any point ends the stream with [`ProviderError::Cancelled`] and
    /// drops the connection.
    fn stream<'a>(
        &'a self,
        req: &'a Request,
        cancel: CancellationToken,
    ) -> BoxFuture<'a, Result<EventStream, ProviderError>>;
}

/// Build the adapter for a configuration's wire.
///
/// The one place that maps [`Wire`] onto a concrete adapter, so a caller never names an
/// adapter type and a new wire adds an arm HERE rather than at every call site. D8 adding
/// the third arm and touching nothing else is the check on that claim.
///
/// It still returns a `Result` though every declared wire now builds: the error arm is the
/// contract for the window between declaring a wire and implementing it, which is a window
/// this enum is deliberately designed to have. See [`ConfigError::UnimplementedWire`].
pub fn build_provider(cfg: ProviderConfig) -> Result<Box<dyn Provider>, ConfigError> {
    match cfg.wire {
        Wire::Messages => Ok(Box::new(AnthropicMessages::new(cfg))),
        Wire::Chat => Ok(Box::new(OpenAiChat::new(cfg))),
        Wire::Responses => Ok(Box::new(OpenAiResponses::new(cfg))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_converts_to_the_shadow_shape_without_recomputing() {
        let u = Usage {
            input_tokens: Some(100),
            output_tokens: Some(20),
            cache_read_tokens: Some(900),
            cache_write_tokens: Some(7),
            reasoning_tokens: Some(11),
            provider_request_id: Some("req_x".into()),
        };
        let t: TokenUsage = u.into();
        // A rename, field for field — no arithmetic, and in particular the cache read is
        // NOT folded back into input_tokens.
        assert_eq!(t.input_tokens, Some(100));
        assert_eq!(t.output_tokens, Some(20));
        assert_eq!(t.cache_read_input_tokens, Some(900));
        assert_eq!(t.cache_creation_input_tokens, Some(7));
        // The reasoning count is DROPPED, and the output count is untouched by it: those
        // 11 tokens are already inside the 20, so folding them in would bill them twice
        // and subtracting them out would bill them never.
        assert_eq!(t.output_tokens, Some(20));
    }

    #[test]
    fn token_usage_serialises_exactly_like_shadow_usage() {
        // `ShadowUsage` skips `None` fields, so a default vector is `{}` and a partial one
        // carries only what it has. D4 aliases this type; if that stopped being true the
        // bridge's on-disk metrics shape would change silently.
        let empty = serde_json::to_string(&TokenUsage::default()).unwrap();
        assert_eq!(empty, "{}");
        let partial = TokenUsage {
            input_tokens: Some(5),
            ..Default::default()
        };
        assert_eq!(
            serde_json::to_string(&partial).unwrap(),
            r#"{"input_tokens":5}"#
        );
        // …and it reads back a document written by the bridge today.
        let from_disk: TokenUsage = serde_json::from_str(
            r#"{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}"#,
        )
        .unwrap();
        assert_eq!(from_disk.cache_creation_input_tokens, Some(4));
    }

    #[test]
    fn every_content_block_variant_round_trips_through_serde() {
        // The regression guard for the defect the adjacent tag fixes. `Text` and the two
        // struct variants all compiled under an internal tag and then failed at runtime,
        // which no test caught because nothing in D1 serialised one.
        let blocks = vec![
            ContentBlock::Text("hello".into()),
            ContentBlock::Image {
                media_type: "image/png".into(),
                data_base64: "AAAA".into(),
            },
            ContentBlock::ToolUse {
                id: "call_1".into(),
                name: "fs_read".into(),
                arguments: serde_json::json!({"path": "a.md"}),
            },
            ContentBlock::ToolResult {
                id: "call_1".into(),
                content: ToolResultContent::Text("framed".into()),
                is_error: false,
            },
            ContentBlock::ToolResult {
                id: "call_2".into(),
                content: ToolResultContent::Blocks(vec![ContentBlock::Text("nested".into())]),
                is_error: true,
            },
        ];
        for block in &blocks {
            let json = serde_json::to_string(block).expect("every variant serialises");
            let back: ContentBlock = serde_json::from_str(&json).expect("and reads back");
            assert_eq!(&back, block, "round trip differed for {json}");
        }
        // And a whole message, which is what the thread store actually writes.
        let message = Message {
            role: Role::Assistant,
            content: blocks,
        };
        let json = serde_json::to_string(&message).unwrap();
        assert_eq!(serde_json::from_str::<Message>(&json).unwrap(), message);
    }

    #[test]
    fn retryability_matches_the_documented_policy() {
        assert!(ProviderError::RateLimited { retry_after: None }.is_retryable());
        assert!(ProviderError::Overloaded.is_retryable());
        assert!(ProviderError::Transport.is_retryable());
        assert!(ProviderError::Timeout.is_retryable());
        assert!(!ProviderError::Auth.is_retryable());
        assert!(!ProviderError::NotFound.is_retryable());
        assert!(!ProviderError::BadRequest("x".into()).is_retryable());
        assert!(!ProviderError::Cancelled.is_retryable());
        assert!(!ProviderError::Protocol("x".into()).is_retryable());
    }

    #[test]
    fn every_declared_wire_builds_and_reports_itself() {
        // The replacement for D1's `the_responses_wire_is_a_typed_error_not_a_panic`. That
        // test asserted the REFUSAL, which was the contract while the adapter did not
        // exist; asserting it now would pin the gap open. What survives from it is the
        // property that mattered — a wire the enum declares is never silently served by a
        // neighbouring adapter — and it is checked here by `p.wire() == w`.
        for w in [Wire::Messages, Wire::Chat, Wire::Responses] {
            let cfg = ProviderConfig::new(w, "http://127.0.0.1:1", "m", AuthScheme::None);
            let p = build_provider(cfg).expect("every declared wire has an adapter");
            assert_eq!(p.wire(), w);
        }
    }

    #[test]
    fn an_unimplemented_wire_is_still_a_typed_error_rather_than_a_panic() {
        // No wire is in that state today, so this asserts on the TYPE that expresses it:
        // it displays as a refusal naming the wire, never a fallback and never a panic.
        // The next declared-before-implemented wire inherits a checked contract instead of
        // re-deciding one.
        let e = ConfigError::UnimplementedWire(Wire::Responses);
        assert_eq!(e.to_string(), "no adapter for the responses wire yet");
    }
}
