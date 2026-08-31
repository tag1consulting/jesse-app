//! **MCP over stdio** — a second source of [`crate::tools::Tool`]s, under the same boundary
//! as the first.
//!
//! ---- WHY THIS IS IN THE CRATE AT ALL ---------------------------------------
//!
//! The product's answer to connectors is typed tools it owns, and the product's answer to a
//! user-supplied server is a Companion running on the user's own hardware. Neither of those
//! is MCP-in-the-agent. Two things are:
//!
//!   * **The Companion IS an MCP client** talking to servers on someone's own machine, so the
//!     mechanism is needed either way and is better built once, here, where the tool boundary
//!     already lives.
//!   * **On a personal deployment it closes the capability gap today.** The `direct` harness
//!     has the vault and nothing else while a claude-code turn has sixteen servers; a granted
//!     `qmd` alone is the difference between a model that can search a vault properly and one
//!     that greps it.
//!
//! ---- THE POSTURE, IN FOUR SENTENCES ----------------------------------------
//!
//! Every server is listed. Every granted tool is named individually. Nothing is granted by
//! wildcard, and the config type has no way to express one. The record changes when the grant
//! changes — `capability_args` on the `direct` harness carries the sorted granted names, and
//! the startup gate compares it to the committed record by strict equality.
//!
//! That is the same posture `bridge/src/config.rs` applies to the CLI harnesses' sixteen
//! servers, restated for a client this crate owns. Two things here are STRICTER than that
//! path, and both are worth naming because they were choices:
//!
//!   * **The child's environment is exactly what the caller passes.** [`McpClient::connect`]
//!     calls `env_clear()`. The CLI harnesses hand their MCP children the bridge's whole
//!     environment, which carries every credential the bridge holds.
//!   * **The client speaks four messages and declares no capabilities**, so a server may not
//!     ask this host to run an inference (sampling) or to put a question to a person
//!     (elicitation), and cannot hand a turn content through a channel the manifest does not
//!     describe (resources).
//!
//! ---- WHAT IS NOT HERE ------------------------------------------------------
//!
//! HTTP transport, OAuth, server-initiated anything, tool-list-change notifications, and
//! resource or prompt support. The set is stdio-only because that is what a server on the
//! owner's own machine is, and because an HTTP server needs a credential story
//! (`Authorization` headers, refresh, rotation) that this step deliberately does not open.

pub mod client;
pub mod toolset;

pub use client::{
    AdvertisedTool, CallOutcome, McpClient, McpError, StderrCounts, CLIENT_NAME, PROTOCOL_VERSION,
};
pub use toolset::{
    tool_name, validate_grants, CompositeError, CompositeToolSet, McpReport, McpSetError,
    McpToolSet, ServerGrant, DEFAULT_CALL_TIMEOUT, DEFAULT_CONNECT_TIMEOUT,
};
