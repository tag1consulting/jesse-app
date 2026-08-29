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

pub mod provider;

pub use provider::{
    build_provider, AnthropicMessages, AuthScheme, Capabilities, ConfigError, ContentBlock, Event,
    Message, OpenAiChat, Provider, ProviderConfig, ProviderError, Quirks, Request, Retries, Role,
    Sampling, StopReason, SystemBlock, Thinking, Timeouts, TokenUsage, ToolResultContent, ToolSpec,
    Usage, Wire,
};
