//! **`jesse-agent`** — the provider-neutral agent layer.
//!
//! D1 (this step) is the PROVIDER LAYER only: one request/response model, one streaming
//! event vocabulary, and the adapters that speak it to a real endpoint. There is no agent
//! loop here yet — D2 adds it, on top of exactly what [`provider`] exposes.
//!
//! ```text
//!     ┌──────────────────────────────────────────────┐
//!     │  D2: the loop  (not in this crate yet)       │  decides, calls tools,
//!     │                                              │  projects to the bridge's
//!     │                                              │  two mid-turn events
//!     ├──────────────────────────────────────────────┤
//!     │  provider::{Request, Event, Provider}        │  ← the neutral vocabulary
//!     ├───────────────────────┬──────────────────────┤
//!     │  AnthropicMessages    │  OpenAiChat          │  ← every wire string lives here
//!     ├───────────────────────┴──────────────────────┤
//!     │  provider::http  — client, retries, redaction,│
//!     │                    audit line, SSE framing    │
//!     └──────────────────────────────────────────────┘
//! ```
//!
//! THE RULE THIS CRATE IS BUILT AROUND: no adapter-specific type or string appears
//! outside `src/provider/`. A caller names [`Wire`], never a vendor; reads [`Event`],
//! never an SSE frame; and handles [`ProviderError`], never an HTTP status. See
//! `README.md` for the invariants and for the checklist D7 follows to add a third adapter.
//!
//! NO DEPENDENCY ON THE BRIDGE, in either direction. [`TokenUsage`] is shaped exactly like
//! `bridge/src/shadow.rs`'s `ShadowUsage` so D4 can adopt it as a type alias rather than
//! defining the same four fields a second time.
//!
//! ---- D2: THE LOOP -----------------------------------------------------------
//!
//! D2 filled the top box in. [`turn::run_turn`] is the loop; everything else added in this
//! step exists because the loop needs it, and each has one property it is responsible for:
//!
//! | Module | Responsible for |
//! |---|---|
//! | [`tools`] | The boundary. A set is built AT a [`tools::Level`] and exposes only what that level permits; dispatch is by exact manifest name. |
//! | [`scope`] | Whom a turn acts for. Passed to every tool by the caller, never read from a model's arguments. |
//! | [`framing`] | Every tool result the model sees, framed as data by ONE function. |
//! | [`thread`] | The conversation, in the neutral model, stored as delivered. |
//! | [`budget`] | The ceilings, checked BEFORE each provider call and never during one. |
//! | [`usage`] | One record per provider call. The seam the per-user ledger grows from. |
//! | [`turn`] | The loop itself, and the content-free trace it produces. |
//!
//! The boundary statement, in one place: **dispatch is by exact manifest name; scope never
//! comes from arguments; external writes are exposed at no level.**

pub mod budget;
pub mod framing;
pub mod provider;
pub mod scope;
pub mod thread;
pub mod timestamp;
pub mod tools;
pub mod usage;

/// The agent loop.
///
/// The file is `src/loop.rs`, as the design note names it; the MODULE is `turn`, because
/// `loop` is a Rust keyword and `crate::r#loop::run_turn` is not a path anyone should have
/// to write. `#[path]` keeps the filename the design note's and the module path a
/// readable one, rather than making the reader choose which of the two to give up.
#[path = "loop.rs"]
pub mod turn;

pub use provider::{
    build_provider, AnthropicMessages, AuthScheme, Capabilities, ConfigError, ContentBlock, Event,
    Message, OpenAiChat, Provider, ProviderConfig, ProviderError, Quirks, Request, Retries, Role,
    Sampling, StopReason, SystemBlock, Thinking, Timeouts, TokenUsage, ToolResultContent, ToolSpec,
    Usage, Wire,
};

pub use budget::{Budget, Ceiling, PriceDeck};
pub use framing::frame_tool_result;
pub use scope::{Scope, TenantId, UserId, WorkspaceId};
pub use thread::{FileThreadStore, MemoryThreadStore, Thread, ThreadId, ThreadStore};
pub use tools::{
    ActionClass, Clock, ExposedClass, Level, ResultBlock, StaticToolSet, SystemClock, Tool,
    ToolContext, ToolError, ToolOk, ToolOutcome, ToolResult, ToolSet, ToolSetBuilder,
};
pub use usage::{JsonlUsageSink, MemoryUsageSink, Phase, UsageRecord, UsageSink};

/// The loop's stop reason, re-exported under a distinct name.
///
/// `provider::StopReason` is already exported at this root and says why one CALL stopped
/// generating; this says why the TURN stopped. Two types named `StopReason` in one
/// namespace would force every caller to disambiguate at the import, so the one whose name
/// is less obvious from context is the one that gets qualified.
pub use turn::StopReason as TurnStopReason;
pub use turn::{
    run_turn, EventSink, NullEventSink, ToolActivity, TurnDeps, TurnInput, TurnOutcome, TurnTrace,
};
