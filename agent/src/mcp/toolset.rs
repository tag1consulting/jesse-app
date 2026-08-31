//! **The MCP tool set** — a connected server's granted tools, as ordinary [`Tool`]s in an
//! ordinary [`ToolSet`], and the composite that puts them beside the vault's.
//!
//! ---- THE GRANT IS THE BOUNDARY, AND IT IS A LIST OF NAMES ------------------
//!
//! [`ServerGrant::tools`] is a `Vec<String>`. There is no pattern, no prefix, no `*`, and no
//! "everything the server advertises" — **the type has no way to express a wildcard**, which
//! is the same move [`crate::tools::ExposedClass`] makes for external writes: a call site
//! that wanted one could not write it.
//!
//! What gets exposed is the INTERSECTION of what the server advertises and what the grant
//! names:
//!
//!   * granted **and** advertised → a [`Tool`] named `mcp__<server>__<tool>`;
//!   * granted, **not** advertised → nothing, plus a WARNING naming it — a grant that has
//!     stopped matching is a config error, and silence would make it look like a policy;
//!   * advertised, **not** granted → nothing at all. It is not in the manifest, so it is not
//!     in the dispatch table, so a call to it is [`ToolError::Refused`] by the same exact-name
//!     dispatch that refuses `Bash`. The battery proves the stronger half of this out of band:
//!     the fake server records that no `tools/call` ever arrived for it.
//!
//! ---- WHY THE NAME IS `mcp__<server>__<tool>` --------------------------------
//!
//! Because that vocabulary already exists in this project and is already load-bearing. The
//! bridge's allowlist grants `mcp__qmd__query`, its activity labels render it, its
//! `hook_write_target` classifies anything starting `mcp__` as a non-write, and its
//! containment records are full of it. A second spelling here would mean two vocabularies for
//! one concept and a translation layer between them.
//!
//! It also gives a structural property worth stating: **an MCP server cannot shadow a vault
//! tool.** A server advertising `vault_read` is exposed as `mcp__probe__vault_read`, so
//! `vault_read` still resolves to the jailed store tool and nothing else. The composite's
//! collision check is therefore not there to stop that — it cannot happen — it is there for
//! the one collision the prefix DOES admit, which is two grants whose composed names are
//! equal because `__` appears inside a server or tool name (`a` + `b__c` and `a__b` + `c`).
//! That is a real ambiguity, it is refused at build time, and the battery covers it.
//!
//! ---- WHAT A SERVER'S RESULT IS ---------------------------------------------
//!
//! Untrusted text, exactly like a vault document's body. It goes back through
//! [`crate::framing::frame_tool_result`] like every other tool result, and because the tool
//! is NAMED `mcp__<server>__<tool>`, the frame's header carries the server's name — so the
//! model is told which server's bytes it is reading, inside a frame that says they are data.
//! Nothing here frames anything itself, for the reason the tool module gives: a tool that
//! framed its own output would be a tool that could choose not to.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::mcp::client::{McpClient, McpError};
use crate::provider::{BoxFuture, ToolSpec};
use crate::scope::Scope;
use crate::tools::{
    usable_tool_name, ActionClass, ExposedClass, Level, ResultBlock, StaticToolSet, Tool,
    ToolContext, ToolError, ToolOk, ToolResult, ToolSet, ToolSetBuilder, ToolSetError,
};

/// How long one `tools/call` may take before the server is dropped for the turn.
///
/// Thirty seconds: long enough for a search server to read an index off a cold disk, short
/// enough that a wedged server costs one tool call rather than the turn. The turn's own wall
/// budget is above this and is what actually bounds the turn.
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// How long `initialize` may take. Wider than a call, because a first start pays for a
/// runtime's boot — `npx` fetching a package, a Python interpreter importing.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(60);

/// One server, and exactly what it is allowed to expose.
///
/// **THE `env` MAP IS THE CHILD'S WHOLE ENVIRONMENT**, values already resolved by the caller.
/// This crate reads nothing out of its own process environment and nothing off disk, so what
/// a server can see is one table a reviewer can read. A caller that forwards no `PATH` must
/// give an absolute `command`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerGrant {
    /// The server's name in tool names and records (`qmd`). Must be usable in a tool name.
    pub name: String,
    /// The program to run. A bare name is resolved against the `PATH` in `env`.
    pub command: String,
    pub args: Vec<String>,
    /// The child's environment, complete. Names to VALUES; see the type doc.
    pub env: BTreeMap<String, String>,
    /// The tools that may be exposed, BY NAME. No wildcard is expressible.
    pub tools: Vec<String>,
    /// The class every granted tool takes unless `per_tool_class` overrides it.
    pub action_class_default: ActionClass,
    /// Per-tool overrides, keyed by the tool's name ON THE SERVER (not the `mcp__…` name).
    pub per_tool_class: HashMap<String, ActionClass>,
}

impl ServerGrant {
    /// A grant of `tools` at one class, which is the common shape.
    pub fn new(
        name: impl Into<String>,
        command: impl Into<String>,
        tools: impl IntoIterator<Item = impl Into<String>>,
        class: ActionClass,
    ) -> ServerGrant {
        ServerGrant {
            name: name.into(),
            command: command.into(),
            args: Vec::new(),
            env: BTreeMap::new(),
            tools: tools.into_iter().map(Into::into).collect(),
            action_class_default: class,
            per_tool_class: HashMap::new(),
        }
    }

    pub fn with_args(mut self, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }

    pub fn with_env(mut self, env: BTreeMap<String, String>) -> Self {
        self.env = env;
        self
    }

    /// The class this grant gives one of the server's tools.
    pub fn class_for(&self, tool: &str) -> ActionClass {
        self.per_tool_class
            .get(tool)
            .copied()
            .unwrap_or(self.action_class_default)
    }

    /// The `mcp__<server>__<tool>` names this grant would expose if the server advertised
    /// every one of them, SORTED. **This is what a containment record commits**: the grant,
    /// not the live intersection, because the record has to describe what a deployment is
    /// permitted to reach rather than what happened to be running when it was written.
    pub fn granted_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .tools
            .iter()
            .map(|t| tool_name(&self.name, t))
            .collect();
        names.sort();
        names.dedup();
        names
    }
}

/// The `mcp__<server>__<tool>` name, in one place.
pub fn tool_name(server: &str, tool: &str) -> String {
    format!("mcp__{server}__{tool}")
}

/// Everything about a set of grants that is checkable BEFORE a process is started.
///
/// Separate from [`McpToolSet::connect`] (which calls it first) so a HOST CAN CHECK ITS
/// CONFIG AT STARTUP rather than on the first turn that needs a server. A grant that could
/// never expose a tool is a config error, and a config error found at boot is one an operator
/// is present for; the same error found on a turn is a failure a user is present for.
pub fn validate_grants(grants: &[ServerGrant]) -> Result<(), McpSetError> {
    let mut seen: Vec<&str> = Vec::new();
    for g in grants {
        if seen.contains(&g.name.as_str()) {
            return Err(McpSetError::DuplicateServer(g.name.clone()));
        }
        seen.push(&g.name);
        if g.tools.is_empty() {
            return Err(McpSetError::EmptyGrant(g.name.clone()));
        }
        for t in &g.tools {
            let composed = tool_name(&g.name, t);
            if !usable_tool_name(&composed) {
                return Err(McpSetError::UnusableName {
                    server: g.name.clone(),
                    tool: t.clone(),
                    composed,
                });
            }
            if g.class_for(t) == ActionClass::ExternalWrite {
                return Err(McpSetError::ExternalWrite {
                    server: g.name.clone(),
                    tool: t.clone(),
                });
            }
        }
    }
    Ok(())
}

/// A tool set could not be built from a set of grants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpSetError {
    /// Two grants named the same server. Fatal rather than last-wins, for the reason a
    /// duplicate tool name is: the name is the key, and picking one silently is how the
    /// wrong server answers.
    DuplicateServer(String),
    /// A grant names no tools at all. Refused rather than treated as "none", because a
    /// server that exposes nothing is a spawn that costs a process for no reason, and the
    /// far likelier reading of an empty list is a config mistake.
    EmptyGrant(String),
    /// The composed `mcp__<server>__<tool>` name is not one both wires accept.
    UnusableName {
        server: String,
        tool: String,
        composed: String,
    },
    /// A grant asked for [`ActionClass::ExternalWrite`], which is exposed at no level.
    ExternalWrite { server: String, tool: String },
    /// The server could not be reached at all. NOT fatal to a turn — see
    /// [`McpToolSet::connect`], which turns this into a warning — fatal only to a caller that
    /// asked for a set of exactly these servers.
    Unreachable { server: String, error: McpError },
    /// The tool set builder refused what the server advertised: a schema that is not an
    /// object, an argument named after part of the scope, a duplicate name.
    Refused(ToolSetError),
}

impl fmt::Display for McpSetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            McpSetError::DuplicateServer(s) => write!(f, "two MCP grants name the server {s:?}"),
            McpSetError::EmptyGrant(s) => {
                write!(
                    f,
                    "the MCP grant for {s:?} names no tools, so it can expose nothing"
                )
            }
            McpSetError::UnusableName {
                server,
                tool,
                composed,
            } => write!(
                f,
                "{server}/{tool} composes to {composed:?}, which is not a usable tool name \
                 (1-64 chars of [A-Za-z0-9_-])"
            ),
            McpSetError::ExternalWrite { server, tool } => write!(
                f,
                "{server}/{tool} is granted as external_write, which is exposed at no level"
            ),
            McpSetError::Unreachable { server, error } => {
                write!(f, "the MCP server {server:?} could not be used: {error}")
            }
            McpSetError::Refused(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for McpSetError {}

/// What connecting produced, beside the set itself.
///
/// Warnings rather than errors on purpose: every one of them NARROWS what a turn can do, and
/// a turn that can do less is never the emergency. They are named so an operator can see a
/// grant that has stopped matching instead of guessing why a model never used a tool.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct McpReport {
    /// One line per connected server: name, protocol version, tools exposed of tools granted.
    pub servers: Vec<String>,
    /// Grants that matched nothing, servers that would not start, tools that were dropped.
    pub warnings: Vec<String>,
}

/// The granted tools of one or more connected MCP servers, as a [`ToolSet`].
///
/// **BUILT ON [`ToolSetBuilder`], deliberately.** Every structural check the vault set gets
/// applies here unchanged and for free: the level filter, the class-mismatch check, the
/// unusable-name check, the non-object-schema check, and the scope-shaped-argument check —
/// which is worth its own sentence, because it means a server advertising a `tenant_id`
/// argument fails the BUILD rather than being handed a scope-shaped hole at call time.
pub struct McpToolSet {
    inner: StaticToolSet,
    report: McpReport,
    /// Kept so the servers live exactly as long as the set does, and are killed with it.
    clients: Vec<Arc<McpClient>>,
}

impl fmt::Debug for McpToolSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("McpToolSet")
            .field("inner", &self.inner)
            .field("servers", &self.report.servers)
            .field("warnings", &self.report.warnings)
            .finish()
    }
}

impl McpToolSet {
    /// Connect every grant, list its tools, and expose the intersection at `level`.
    ///
    /// **A SERVER THAT WILL NOT START IS A WARNING, NOT A FAILURE**, and the direction is what
    /// makes that safe: the turn then has FEWER tools than the grant allows, never more. The
    /// containment record commits the grant, so the live set is always a subset of what was
    /// recorded, and a turn is not lost because a search index was being rebuilt.
    ///
    /// **AT [`Level::Basic`] NOTHING IS CONNECTED AT ALL.** No class is permitted there, so
    /// every server would be started and then filtered to nothing — and the `direct` harness's
    /// claim that `basic` spawns no child process would quietly stop being true. The check is
    /// first for exactly that reason.
    pub async fn connect(
        grants: &[ServerGrant],
        level: Level,
        call_timeout: Duration,
        connect_timeout: Duration,
    ) -> Result<McpToolSet, McpSetError> {
        let mut report = McpReport::default();
        if level == Level::Basic || grants.is_empty() {
            return Ok(McpToolSet {
                inner: crate::tools::no_tools(),
                report,
                clients: Vec::new(),
            });
        }

        validate_grants(grants)?;

        let mut builder = ToolSetBuilder::new(level);
        let mut clients = Vec::new();
        for g in grants {
            let client = match McpClient::connect(
                &g.name,
                &g.command,
                &g.args,
                &g.env,
                call_timeout,
                connect_timeout,
            )
            .await
            {
                Ok(c) => Arc::new(c),
                Err(error) => {
                    report.warnings.push(format!(
                        "MCP server '{}' did not start ({error}); its {} granted tool(s) are \
                         absent from this turn",
                        g.name,
                        g.tools.len()
                    ));
                    continue;
                }
            };
            let advertised = match client.list_tools().await {
                Ok(list) => list,
                Err(error) => {
                    report.warnings.push(format!(
                        "MCP server '{}' would not list its tools ({error}); its {} granted \
                         tool(s) are absent from this turn",
                        g.name,
                        g.tools.len()
                    ));
                    continue;
                }
            };

            let mut exposed = 0usize;
            for want in &g.tools {
                let Some(found) = advertised.iter().find(|a| &a.name == want) else {
                    // A GRANT THAT MATCHES NOTHING IS NAMED. Silence here would read as a
                    // policy decision ("we chose not to expose it") when it is a stale config
                    // or a renamed tool.
                    report.warnings.push(format!(
                        "MCP server '{}' does not advertise the granted tool '{want}'",
                        g.name
                    ));
                    continue;
                };
                let class = g.class_for(want);
                builder = builder.add(
                    exposed_class(class).expect("external_write was refused above"),
                    Arc::new(McpTool {
                        name: tool_name(&g.name, want),
                        remote: want.clone(),
                        // The DESCRIPTION IS THE SERVER'S and it is untrusted text that
                        // reaches the model. It is not sanitised here: a description is
                        // shown to the model as part of the manifest on every wire, exactly
                        // as the server wrote it, and pretending otherwise by trimming a few
                        // characters would be theatre. What bounds it is the grant — a
                        // server nobody granted a tool on contributes no descriptions at all.
                        description: found.description.clone(),
                        schema: found.input_schema.clone(),
                        class,
                        client: client.clone(),
                    }) as Arc<dyn Tool>,
                );
                exposed += 1;
            }

            report.servers.push(format!(
                "{} ({}, protocol {}): {exposed} of {} granted tool(s) exposed, {} advertised",
                g.name,
                client.server_info(),
                client.server_protocol(),
                g.tools.len(),
                advertised.len()
            ));
            clients.push(client);
        }

        let inner = builder.build().map_err(McpSetError::Refused)?;
        Ok(McpToolSet {
            inner,
            report,
            clients,
        })
    }

    /// What connecting found: one line per server, plus every warning.
    pub fn report(&self) -> &McpReport {
        &self.report
    }

    /// Per-server stderr counts, for the trace. **Numbers only** — see
    /// [`crate::mcp::client::McpClient::stderr_lines`].
    pub fn stderr_counts(&self) -> Vec<(String, crate::mcp::client::StderrCounts)> {
        self.clients
            .iter()
            .map(|c| (c.name().to_string(), c.stderr_lines()))
            .collect()
    }

    /// Close every server. Called by the caller when the turn ends; [`Drop`] on the clients is
    /// the backstop.
    pub async fn shutdown(&self) {
        for c in &self.clients {
            c.shutdown().await;
        }
    }
}

impl ToolSet for McpToolSet {
    fn manifest(&self) -> Vec<ToolSpec> {
        self.inner.manifest()
    }
    fn get(&self, name: &str) -> Option<&dyn Tool> {
        self.inner.get(name)
    }
    fn max_level(&self) -> Level {
        self.inner.max_level()
    }
}

/// [`ActionClass`] as the class a set may be BUILT with, or `None` for the one arm that has
/// no builder equivalent.
fn exposed_class(class: ActionClass) -> Option<ExposedClass> {
    match class {
        ActionClass::Read => Some(ExposedClass::Read),
        ActionClass::VaultWrite => Some(ExposedClass::VaultWrite),
        ActionClass::Egress => Some(ExposedClass::Egress),
        // Exposed at no level; refused before a process is started.
        ActionClass::ExternalWrite => None,
    }
}

/// One granted tool on one connected server.
struct McpTool {
    name: String,
    /// The name the SERVER knows it by. The `mcp__` prefix never goes over the wire.
    remote: String,
    description: String,
    schema: Value,
    class: ActionClass,
    client: Arc<McpClient>,
}

impl Tool for McpTool {
    fn name(&self) -> &str {
        &self.name
    }

    fn description(&self) -> &str {
        &self.description
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
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            // THE SCOPE IS NOT SENT. An MCP server has no notion of this product's tenants and
            // could not enforce one; sending it would put an identifier into a third party's
            // logs and buy nothing. What bounds a server is the grant and the credentials the
            // caller put in its environment.
            //
            // Arguments are forwarded AS THE MODEL WROTE THEM, validated by the server against
            // the schema the server itself published. Re-validating here would mean carrying a
            // JSON Schema implementation to second-guess the only party that knows the rule.
            // What is checked is the shape: a non-object is refused before it is sent, because
            // `arguments` is an object on the wire and a bare string would be a malformed
            // request this client should not make.
            if !args.is_null() && !args.is_object() {
                return Err(ToolError::InvalidArgs(
                    "arguments must be a JSON object".into(),
                ));
            }
            let args = if args.is_null() { json!({}) } else { args };

            tokio::select! {
                biased;
                // Cancellation wins the race when both are ready: a cancelled turn should
                // not spend another moment on a server's answer nobody will read.
                _ = ctx.cancel.cancelled() => Err(ToolError::Failed(
                    "not run: the turn was cancelled".into(),
                )),
                out = self.client.call_tool(&self.remote, args) => match out {
                    Ok(outcome) => {
                        let content = blocks_from_result(&outcome.content, outcome.structured.as_ref());
                        if outcome.is_error {
                            // The SERVER'S OWN failure flag. `Failed`, never `Refused`: a
                            // refusal in this project's vocabulary is a boundary of OURS
                            // holding, and counting a remote error as one would inflate the
                            // single number an operator reads as "the boundary held".
                            return Err(ToolError::Failed(error_text(&content)));
                        }
                        Ok(ToolOk {
                            content,
                            // FIXED STRING, as the type requires: a `String` here could carry
                            // the server's answer into a trace whose whole property is that it
                            // holds no content.
                            summary_for_trace: "mcp tool result",
                        })
                    }
                    Err(e @ McpError::Rpc { .. }) => Err(ToolError::Failed(e.to_string())),
                    Err(e) => Err(ToolError::Failed(e.to_string())),
                },
            }
        })
    }
}

/// One MCP `content` array as this crate's result blocks.
///
/// **NOTHING IS DROPPED.** Text and images map onto their own arms; every other block type the
/// protocol defines — audio, resource links, embedded resources, and anything a later version
/// adds — is carried through as a JSON block. A client that silently discarded what it did not
/// recognise would give a model a truncated answer that looks complete, which is worse than an
/// unfamiliar object it can read.
fn blocks_from_result(content: &[Value], structured: Option<&Value>) -> Vec<ResultBlock> {
    let mut out = Vec::new();
    for block in content {
        match block.get("type").and_then(|v| v.as_str()) {
            Some("text") => out.push(ResultBlock::Text(
                block
                    .get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
            )),
            Some("image") => {
                let media_type = block
                    .get("mimeType")
                    .and_then(|v| v.as_str())
                    .unwrap_or("image/png")
                    .to_string();
                let data_base64 = block
                    .get("data")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                if data_base64.is_empty() {
                    out.push(ResultBlock::Json(block.clone()));
                } else {
                    out.push(ResultBlock::Image {
                        media_type,
                        data_base64,
                    });
                }
            }
            _ => out.push(ResultBlock::Json(block.clone())),
        }
    }
    if let Some(s) = structured {
        out.push(ResultBlock::Json(s.clone()));
    }
    out
}

/// The text of a server-reported tool error, for [`ToolError::Failed`].
fn error_text(blocks: &[ResultBlock]) -> String {
    let text: Vec<String> = blocks
        .iter()
        .map(|b| match b {
            ResultBlock::Text(t) => t.clone(),
            ResultBlock::Json(v) => v.to_string(),
            ResultBlock::Image { media_type, .. } => format!("[{media_type}]"),
        })
        .collect();
    let joined = text.join("\n");
    if joined.trim().is_empty() {
        "the server reported an error with no detail".to_string()
    } else {
        joined
    }
}

// ===========================================================================
// The composite
// ===========================================================================

/// Two or more tool sets as ONE, with every name checked against every other at build time.
///
/// The check is the whole reason this type exists rather than a `Vec<Arc<dyn ToolSet>>` and a
/// loop: [`ToolSet::get`] returning the FIRST match would make a duplicate name resolve to
/// whichever set happened to be listed first, which is the ambiguity that the tool set's own
/// `DuplicateName` error exists to refuse. Refusing at build time keeps "the manifest and the
/// dispatch table are the same object" true across sets as well as within one.
pub struct CompositeToolSet {
    level: Level,
    /// Manifest order: set order, and within a set that set's own order.
    order: Vec<String>,
    /// Name → which set owns it. Built once, so `get` is a lookup rather than a walk.
    owner: BTreeMap<String, usize>,
    sets: Vec<Arc<dyn ToolSet>>,
}

/// A composite could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompositeError {
    /// Two sets expose the same name.
    DuplicateName { name: String, sets: (usize, usize) },
    /// The sets were built at different levels. Refused rather than reconciled: a composite
    /// has ONE level, and picking the lower one silently would hide a caller's mistake while
    /// picking the higher one would state a permission no set actually applied.
    MixedLevels { expected: Level, found: Level },
}

impl fmt::Display for CompositeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CompositeError::DuplicateName { name, sets } => write!(
                f,
                "tool sets {} and {} both expose {name:?}; a composite cannot resolve it",
                sets.0, sets.1
            ),
            CompositeError::MixedLevels { expected, found } => write!(
                f,
                "a composite's sets must share one level; expected {expected}, found {found}"
            ),
        }
    }
}

impl std::error::Error for CompositeError {}

impl CompositeToolSet {
    /// Combine sets, in manifest order, refusing any name two of them share.
    pub fn new(sets: Vec<Arc<dyn ToolSet>>) -> Result<CompositeToolSet, CompositeError> {
        let level = sets.first().map(|s| s.max_level()).unwrap_or(Level::Basic);
        let mut order = Vec::new();
        let mut owner: BTreeMap<String, usize> = BTreeMap::new();
        for (i, set) in sets.iter().enumerate() {
            if set.max_level() != level {
                return Err(CompositeError::MixedLevels {
                    expected: level,
                    found: set.max_level(),
                });
            }
            for spec in set.manifest() {
                if let Some(prev) = owner.get(&spec.name) {
                    return Err(CompositeError::DuplicateName {
                        name: spec.name,
                        sets: (*prev, i),
                    });
                }
                owner.insert(spec.name.clone(), i);
                order.push(spec.name);
            }
        }
        Ok(CompositeToolSet {
            level,
            order,
            owner,
            sets,
        })
    }

    /// Every exposed name, in manifest order.
    pub fn names(&self) -> &[String] {
        &self.order
    }
}

impl fmt::Debug for CompositeToolSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompositeToolSet")
            .field("level", &self.level)
            .field("exposed", &self.order)
            .finish()
    }
}

impl ToolSet for CompositeToolSet {
    fn manifest(&self) -> Vec<ToolSpec> {
        self.sets.iter().flat_map(|s| s.manifest()).collect()
    }

    /// EXACT MATCH, through the owner index built at construction. The index is what keeps
    /// this from being a first-match walk over sets whose order would then be load bearing.
    fn get(&self, name: &str) -> Option<&dyn Tool> {
        let i = *self.owner.get(name)?;
        self.sets[i].get(name)
    }

    fn max_level(&self) -> Level {
        self.level
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::ToolSetBuilder;

    struct Stub(&'static str);

    impl Tool for Stub {
        fn name(&self) -> &str {
            self.0
        }
        fn description(&self) -> &str {
            "stub"
        }
        fn schema(&self) -> Value {
            json!({"type": "object"})
        }
        fn action_class(&self) -> ActionClass {
            ActionClass::Read
        }
        fn call<'a>(
            &'a self,
            _scope: &'a Scope,
            _args: Value,
            _ctx: &'a ToolContext,
        ) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                Ok(ToolOk {
                    content: vec![ResultBlock::Text(self.0.into())],
                    summary_for_trace: "stub",
                })
            })
        }
    }

    fn set_of(level: Level, names: &[&'static str]) -> Arc<dyn ToolSet> {
        let mut b = ToolSetBuilder::new(level);
        for n in names {
            b = b.add(ExposedClass::Read, Arc::new(Stub(n)));
        }
        Arc::new(b.build().unwrap())
    }

    #[test]
    fn a_composite_exposes_every_set_and_dispatches_exactly() {
        let c = CompositeToolSet::new(vec![
            set_of(Level::Read, &["vault_read", "vault_list"]),
            set_of(Level::Read, &["mcp__qmd__query"]),
        ])
        .unwrap();
        let names: Vec<String> = c.manifest().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["vault_read", "vault_list", "mcp__qmd__query"]);
        assert!(c.get("mcp__qmd__query").is_some());
        assert!(c.get("vault_read").is_some());
        for near in ["mcp__qmd__quer", "MCP__QMD__QUERY", " vault_read", ""] {
            assert!(c.get(near).is_none(), "{near:?} must not resolve");
        }
    }

    #[test]
    fn a_composite_refuses_two_sets_that_share_a_name() {
        let err = CompositeToolSet::new(vec![
            set_of(Level::Read, &["vault_read"]),
            set_of(Level::Read, &["vault_read"]),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            CompositeError::DuplicateName {
                name: "vault_read".into(),
                sets: (0, 1)
            }
        );
    }

    #[test]
    fn a_composite_refuses_sets_built_at_different_levels() {
        let err = CompositeToolSet::new(vec![
            set_of(Level::Read, &["vault_read"]),
            set_of(Level::Write, &["mcp__x__y"]),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            CompositeError::MixedLevels {
                expected: Level::Read,
                found: Level::Write
            }
        );
    }

    /// The prefix is what makes a vault tool unshadowable, and this is the assertion of it:
    /// a server advertising `vault_read` composes to a DIFFERENT name, so the two coexist and
    /// `vault_read` still resolves to the vault's own tool.
    #[test]
    fn an_mcp_tool_named_after_a_vault_tool_cannot_shadow_it() {
        let g = ServerGrant::new("probe", "unused", ["vault_read"], ActionClass::Read);
        assert_eq!(g.granted_names(), ["mcp__probe__vault_read"]);
        let c = CompositeToolSet::new(vec![
            set_of(Level::Read, &["vault_read"]),
            set_of(Level::Read, &["mcp__probe__vault_read"]),
        ])
        .unwrap();
        assert!(c.get("vault_read").is_some());
        assert!(c.get("mcp__probe__vault_read").is_some());
    }

    /// The one collision the prefix DOES admit: `__` inside a server or tool name.
    #[test]
    fn two_grants_can_compose_to_one_name_and_that_is_the_collision_worth_checking() {
        let a = ServerGrant::new("a", "x", ["b__c"], ActionClass::Read);
        let b = ServerGrant::new("a__b", "x", ["c"], ActionClass::Read);
        assert_eq!(a.granted_names(), b.granted_names());
        assert_eq!(a.granted_names(), ["mcp__a__b__c"]);
    }

    #[test]
    fn per_tool_classes_override_the_default_and_the_grant_names_sort() {
        let mut g = ServerGrant::new(
            "qmd",
            "qmd",
            ["query", "get", "multi_get", "status"],
            ActionClass::Read,
        );
        g.per_tool_class.insert("query".into(), ActionClass::Egress);
        assert_eq!(g.class_for("query"), ActionClass::Egress);
        assert_eq!(g.class_for("get"), ActionClass::Read);
        assert_eq!(
            g.granted_names(),
            [
                "mcp__qmd__get",
                "mcp__qmd__multi_get",
                "mcp__qmd__query",
                "mcp__qmd__status"
            ]
        );
    }

    #[test]
    fn result_blocks_carry_everything_the_protocol_can_return() {
        let content = vec![
            json!({"type": "text", "text": "hello"}),
            json!({"type": "image", "mimeType": "image/png", "data": "AAAA"}),
            json!({"type": "resource_link", "uri": "file:///x", "name": "x"}),
        ];
        let structured = json!({"a": 1});
        let blocks = blocks_from_result(&content, Some(&structured));
        assert_eq!(blocks.len(), 4, "nothing is dropped: {blocks:?}");
        assert_eq!(blocks[0], ResultBlock::Text("hello".into()));
        assert!(matches!(blocks[1], ResultBlock::Image { .. }));
        assert!(matches!(blocks[2], ResultBlock::Json(_)));
        assert_eq!(blocks[3], ResultBlock::Json(structured));
    }

    #[test]
    fn the_checkable_half_of_a_grant_is_checkable_without_a_process() {
        let ok = ServerGrant::new("qmd", "qmd", ["query"], ActionClass::Read);
        assert!(validate_grants(std::slice::from_ref(&ok)).is_ok());

        assert_eq!(
            validate_grants(&[ok.clone(), ok.clone()]).unwrap_err(),
            McpSetError::DuplicateServer("qmd".into())
        );
        assert_eq!(
            validate_grants(&[ServerGrant::new(
                "empty",
                "x",
                Vec::<String>::new(),
                ActionClass::Read
            )])
            .unwrap_err(),
            McpSetError::EmptyGrant("empty".into())
        );
        // A composed name no wire accepts, caught before a process is started.
        let long = ServerGrant::new("s", "x", ["t".repeat(80)], ActionClass::Read);
        assert!(matches!(
            validate_grants(&[long]).unwrap_err(),
            McpSetError::UnusableName { .. }
        ));
        let spaced = ServerGrant::new("s", "x", ["has space"], ActionClass::Read);
        assert!(matches!(
            validate_grants(&[spaced]).unwrap_err(),
            McpSetError::UnusableName { .. }
        ));
        // Exposed at no level, so a grant naming it is refused rather than silently inert.
        let external = ServerGrant::new("s", "x", ["send"], ActionClass::ExternalWrite);
        assert_eq!(
            validate_grants(&[external]).unwrap_err(),
            McpSetError::ExternalWrite {
                server: "s".into(),
                tool: "send".into()
            }
        );
    }

    #[test]
    fn an_external_write_grant_has_no_builder_class() {
        assert!(exposed_class(ActionClass::ExternalWrite).is_none());
        for c in [
            ActionClass::Read,
            ActionClass::VaultWrite,
            ActionClass::Egress,
        ] {
            assert!(exposed_class(c).is_some());
        }
    }
}
