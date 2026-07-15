//! Jesse Bridge — a tiny HTTP server that turns "Ask Jesse" / "Tell Jesse"
//! requests from the phone into headless Claude Code (`claude -p`) runs against
//! the vault. Cowork is not scriptable; Claude Code is, and it loads the same
//! CLAUDE.md, so you get the same "Jesse" brain.
//!
//! Run:
//!     export JESSE_TOKEN="$(openssl rand -hex 24)"
//!     export JESSE_VAULT="$HOME/devel/tag1/jesse"
//!     export JESSE_BIND="$(tailscale ip -4 | head -1)"   # or 127.0.0.1 to test
//!     cargo run --release
//!
//! Security model: bind to loopback or the Tailscale/CGNAT interface only. The
//! tailnet is WireGuard-encrypted and ACL-gated; the bearer token is a second
//! factor. The headless agent runs under an explicit tool allowlist (see
//! `build_claude_args`); that allowlist is the only in-process boundary — real
//! isolation (dedicated low-privilege user, OS sandbox) is a deployment concern
//! documented in SECURITY.md.
//!
//! ## Module map
//!
//! `main.rs` is wiring only. The logic is split along the sections the file grew:
//! [`config`] (env-driven config), [`prompt`] (Ask/Tell wrappers + `build_prompt`),
//! [`auth`] (constant-time bearer check), [`bind`] (bind safety), [`ratelimit`]
//! (token bucket), [`jobstore`] (the turn-survives-disconnect job store, with the
//! live-stream state isolated in [`jobstore::streams`]), [`claude`] (spawn + parse
//! the `stream-json` turn), [`attachments`] (decode/sniff/scratch), [`apns`] (the
//! optional push path), [`state`] (shared `AppState`), [`handlers`]/[`sse`] (the
//! Axum routes), and [`startup`] (pairing QR + binary/bind checks).

// ---- Shared prelude -------------------------------------------------------
//
// The original bridge was one file, so every item saw every other by bare name.
// The split preserves that: these `pub(crate) use`s re-export the std/external
// names, and each module does `use crate::*;` to pull the same flat namespace
// (its own siblings via the `pub use module::*` below, plus these). Glob imports
// are exempt from the unused-import lint, so a module pays nothing for names it
// doesn't touch.
pub(crate) use std::collections::HashMap;
pub(crate) use std::future::Future;
pub(crate) use std::hash::BuildHasher;
pub(crate) use std::io::Write;
pub(crate) use std::net::IpAddr;
pub(crate) use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
pub(crate) use std::path::{Path, PathBuf};
pub(crate) use std::pin::Pin;
pub(crate) use std::process::Stdio;
pub(crate) use std::sync::atomic::{AtomicU64, Ordering};
pub(crate) use std::sync::{Arc, Mutex};
pub(crate) use std::task::{Context as TaskContext, Poll};
pub(crate) use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(crate) use axum::{
    extract::{DefaultBodyLimit, Path as UrlPath, Query, State},
    http::{HeaderMap, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
pub(crate) use futures_core::Stream;
pub(crate) use serde::Deserialize;
pub(crate) use serde_json::{json, Value};
pub(crate) use subtle::ConstantTimeEq;
pub(crate) use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
pub(crate) use tokio::process::Command;
pub(crate) use tokio::sync::{broadcast, mpsc, OwnedSemaphorePermit, Semaphore};
pub(crate) use tokio::task::AbortHandle;
pub(crate) use tokio::time::timeout;

// ---- Modules --------------------------------------------------------------

mod apns;
mod attachments;
mod audit;
mod auth;
mod backend_call;
mod badge;
mod bind;
mod breaker;
mod citations;
mod claude;
mod config;
mod context;
mod diet;
mod dietgate;
mod dietlog;
mod dietqueue;
mod directives;
mod emergency;
mod failclass;
mod handlers;
mod jobstore;
mod metrics;
mod prompt;
mod queue;
mod ratelimit;
mod sessions;
mod sse;
mod startup;
mod state;
mod titlestore;
mod util;
mod vaultqa;
mod vaultqagate;

// Flat internal namespace: every module's items reachable crate-wide by bare
// name (so `use crate::*` in each module works exactly like the old single file).
pub use apns::*;
pub use attachments::*;
pub use audit::*;
pub use auth::*;
pub use backend_call::*;
pub use badge::*;
pub use bind::*;
pub use breaker::*;
pub use citations::*;
pub use claude::*;
pub use config::*;
pub use context::*;
pub use diet::*;
pub use dietgate::*;
pub use dietlog::*;
pub use dietqueue::*;
pub use directives::*;
pub use emergency::*;
pub use failclass::*;
pub use handlers::*;
pub use jobstore::*;
pub use metrics::*;
pub use prompt::*;
pub use queue::*;
pub use ratelimit::*;
pub use sessions::*;
pub use sse::*;
pub use startup::*;
pub use state::*;
pub use titlestore::*;
pub use util::*;
pub use vaultqa::*;
pub use vaultqagate::*;

#[cfg(test)]
mod testutil;
