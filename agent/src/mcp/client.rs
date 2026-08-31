//! **The stdio MCP client** — one child process, one request at a time, newline-delimited
//! JSON-RPC 2.0, and a hard rule about what a misbehaving server may cost a turn.
//!
//! ---- THE SUBSET THIS SPEAKS, AND WHAT IT DELIBERATELY DOES NOT --------------
//!
//! Three requests and one notification, in this order: `initialize`,
//! `notifications/initialized`, `tools/list` (following `nextCursor` while the server
//! pages), and `tools/call`. That is the whole client.
//!
//! **NO SAMPLING, NO RESOURCES, NO PROMPTS, NO ELICITATION, NO ROOTS, NO LOGGING, NO
//! SUBSCRIPTIONS, NO PROGRESS, NO CANCELLATION NOTIFICATIONS**, and the omission is a
//! posture rather than a backlog. Each of those is a channel a server can open TOWARDS the
//! host: sampling asks the host to run an inference the server chose the prompt for,
//! elicitation asks the host to put the server's question to a human, and roots hands the
//! server a filesystem map. This client declares an EMPTY `capabilities` object, so a
//! conforming server may not use any of them, and it answers nothing but its own replies —
//! a request arriving from the server is a protocol violation on a client that advertised
//! no capability to serve it, and it is treated as one.
//!
//! Resources and prompts are omitted for a smaller reason: they are read channels the tool
//! boundary does not cover. A resource is content a turn could pull in without a
//! [`crate::tools::Tool`] ever appearing in the manifest, so exposing them would put text
//! into a turn through a door the manifest does not describe. When there is a reason to
//! read a resource it will be through a tool, which is a thing the record can name.
//!
//! ---- WHAT A MISBEHAVING SERVER COSTS --------------------------------------
//!
//! **A protocol violation kills the connection for the rest of the turn**, and every later
//! call to that server answers [`McpError::Dead`] without touching the pipe. The rejected
//! alternative was to resynchronise — skip the bad line and read the next one — which is
//! how a client ends up matching a reply to the wrong request. There is no id to trust once
//! the framing is in doubt, and a tool result attributed to the wrong call is worse than a
//! failed call by a wide margin.
//!
//! **A timeout is a protocol violation for the same reason.** The request was written; the
//! answer may still arrive later and would then be read as the answer to a LATER request. A
//! spec-conforming client would send `notifications/cancelled` and keep the connection; this
//! one does not, because keeping it means keeping a stream whose next line has an unknown
//! meaning. The turn continues without that server — which is the property that matters, and
//! the one the battery probes.
//!
//! ---- ONE REQUEST AT A TIME ------------------------------------------------
//!
//! The connection sits behind a [`tokio::sync::Mutex`], so two concurrent tool calls against
//! the SAME server serialise. JSON-RPC ids would allow interleaving and this client does not
//! do it: the reader would have to demultiplex replies to waiters, which is a second piece of
//! state that can disagree with the first. Different servers do not contend at all — each has
//! its own child and its own lock — and the loop's parallel dispatch is across servers far
//! more often than within one.

use std::collections::BTreeMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::{timeout_at, Instant};

/// The protocol version this client asks for.
///
/// A DATED STRING, not a semver triple, because that is what the protocol uses. The server
/// answers with a version of its own choosing (the spec's negotiation rule), and this client
/// ACCEPTS whatever it answers as long as it is a non-empty string — see
/// [`McpClient::connect`] for why refusing an unfamiliar one would be worse.
pub const PROTOCOL_VERSION: &str = "2025-06-18";

/// What this client tells a server it is. No version of the host, no hostname, no path:
/// a server logs this line and a server's log is not a place to put deployment facts.
pub const CLIENT_NAME: &str = "jesse-agent";

/// How many `tools/list` pages will be followed before the server is called out of spec.
///
/// A server that returns a `nextCursor` forever is not paginating, it is looping, and a
/// client that followed it would hang at construction rather than at call time — the one
/// place a hang is hardest to attribute. Twenty pages is far past any real server.
pub const MAX_LIST_PAGES: usize = 20;

/// Lines of the server's stderr kept for an operator, and the cap on each.
///
/// The ring exists so a server that failed to start can be explained; it is NOT a channel
/// into a turn. Nothing here reaches the model, and the TRACE takes the COUNT
/// ([`McpClient::stderr_lines`]) rather than the text, on the same rule that keeps
/// [`crate::turn::TurnTrace`] content-free.
pub const STDERR_RING_LINES: usize = 20;
/// Bytes kept from one stderr line. A server that writes a 2 MB stack trace on every call
/// should not be able to grow this process's memory through the diagnostic channel.
pub const STDERR_LINE_MAX_BYTES: usize = 300;

/// Anything that can go wrong between this client and one server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpError {
    /// The child could not be started at all: no such command, no permission, no pipes.
    Spawn(String),
    /// The server broke the protocol, or the pipe did. **The connection is dead afterwards.**
    Protocol(String),
    /// The server did not answer in time. **The connection is dead afterwards** — see the
    /// module docs for why a timeout is not recoverable here.
    Timeout(Duration),
    /// A call was made after the connection died. Carries the original cause.
    Dead(String),
    /// A well-formed JSON-RPC error response. **This is the server WORKING**: it framed a
    /// reply, gave it the right id, and said no. It does not kill the connection.
    Rpc { code: i64, message: String },
}

impl std::fmt::Display for McpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            McpError::Spawn(m) => write!(f, "could not start the server: {m}"),
            McpError::Protocol(m) => write!(f, "the server broke the protocol: {m}"),
            McpError::Timeout(d) => write!(
                f,
                "the server did not answer within {}s and was dropped for this turn",
                d.as_secs_f32()
            ),
            McpError::Dead(why) => write!(f, "the server was dropped earlier this turn ({why})"),
            McpError::Rpc { code, message } => write!(f, "server error {code}: {message}"),
        }
    }
}

impl std::error::Error for McpError {}

/// One tool as a server advertises it.
///
/// The fields this client reads and nothing else. `annotations` is deliberately ABSENT: the
/// specification says a client must treat annotations as untrusted unless the server is
/// trusted, and this project decides what a tool may do from its GRANT (see
/// [`crate::mcp::ServerGrant`]), never from something the server said about itself. A
/// `readOnlyHint` that a grant disagreed with would be a value with no possible use — and
/// this repository has already measured such hints to be unreliable across six servers.
#[derive(Debug, Clone, PartialEq)]
pub struct AdvertisedTool {
    pub name: String,
    pub description: String,
    /// `inputSchema`, or `{"type":"object"}` when the server sent none.
    pub input_schema: Value,
}

/// One `tools/call` result, in the shape the tool layer maps to [`crate::tools::ResultBlock`]s.
#[derive(Debug, Clone, PartialEq)]
pub struct CallOutcome {
    /// The `content` array, untouched. Interpreting it is [`crate::mcp::toolset`]'s job.
    pub content: Vec<Value>,
    /// `structuredContent`, when the server sent it.
    pub structured: Option<Value>,
    /// The server's own `isError` flag — a TOOL failure, not a protocol one.
    pub is_error: bool,
}

/// What this client counted on a server's stderr. Numbers only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StderrCounts {
    pub lines: u64,
    pub bytes: u64,
}

#[derive(Debug, Default)]
struct StderrSink {
    counts: Mutex<StderrCounts>,
    ring: Mutex<std::collections::VecDeque<String>>,
}

/// The live half of a connection. `None` in [`McpClient`] once the server is dead.
struct Connection {
    child: Child,
    stdin: ChildStdin,
    stdout: Lines<BufReader<ChildStdout>>,
}

/// A connected MCP server, over stdio.
///
/// Construct with [`McpClient::connect`]. Dropping it closes the child's stdin and kills the
/// child — a server that ignores the closed pipe must not outlive the turn that started it.
pub struct McpClient {
    /// The server's configured name (`qmd`), used in errors and in tool names.
    name: String,
    /// The protocol version the SERVER answered with.
    server_protocol: String,
    /// `name` and `version` from the server's `serverInfo`, for a startup line.
    server_info: String,
    per_call: Duration,
    next_id: AtomicU64,
    stderr: Arc<StderrSink>,
    conn: tokio::sync::Mutex<Option<Connection>>,
    /// Why the connection died, once it has. Set exactly once.
    death: Mutex<Option<String>>,
}

impl std::fmt::Debug for McpClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpClient")
            .field("name", &self.name)
            .field("protocol", &self.server_protocol)
            .field("server", &self.server_info)
            .field("dead", &self.death_reason())
            .finish_non_exhaustive()
    }
}

impl McpClient {
    /// Start a server, negotiate, and return a client ready for [`McpClient::list_tools`].
    ///
    /// `env` IS THE CHILD'S WHOLE ENVIRONMENT. The child is started with `env_clear()` and
    /// exactly these variables — this crate reads nothing out of its own process environment
    /// and nothing off disk, so what a server can see is a decision the CALLER made and can
    /// be read off one config table. That is the opposite of how the CLI harnesses launch
    /// their servers, where the child inherits the bridge's whole environment and therefore
    /// every credential in it.
    ///
    /// A consequence worth stating: a bare-name `command` is resolved against the `PATH` in
    /// THIS map, so a caller that forwards no `PATH` must give an absolute command. The
    /// bridge forwards a fixed, named short list; see `bridge/src/harness/direct.rs`.
    ///
    /// **THE SERVER'S PROTOCOL VERSION IS ACCEPTED, NOT MATCHED.** The negotiation rule is
    /// that the server answers with a version it supports, which may not be the requested
    /// one, and a client that refused anything unfamiliar would break on the next dated
    /// release for no gain: this client uses three requests whose shapes have been stable
    /// across every published version. What IS required is that the field is present and is a
    /// non-empty string — a server that omits it is not answering an `initialize`.
    pub async fn connect(
        name: &str,
        command: &str,
        args: &[String],
        env: &BTreeMap<String, String>,
        per_call: Duration,
        connect_timeout: Duration,
    ) -> Result<McpClient, McpError> {
        let mut cmd = Command::new(command);
        cmd.args(args)
            .env_clear()
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // The child must not share this process's controlling terminal or its signal
            // fate beyond the kill on drop; `kill_on_drop` is what makes the Drop impl below
            // effective even when the future is cancelled mid-call.
            .kill_on_drop(true);
        let mut child = cmd.spawn().map_err(|e| McpError::Spawn(e.to_string()))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| McpError::Spawn("no stdin pipe".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| McpError::Spawn("no stdout pipe".into()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| McpError::Spawn("no stderr pipe".into()))?;

        // stderr is DRAINED, always. A server whose stderr nobody reads blocks on a full pipe
        // and then looks like a hang at `tools/call` — the failure this task exists to prevent
        // is a diagnostic channel wedging the thing it was supposed to explain.
        let sink = Arc::new(StderrSink::default());
        let sink_task = sink.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(mut c) = sink_task.counts.lock() {
                    c.lines += 1;
                    c.bytes += line.len() as u64;
                }
                if let Ok(mut ring) = sink_task.ring.lock() {
                    if ring.len() == STDERR_RING_LINES {
                        ring.pop_front();
                    }
                    ring.push_back(clip(&line, STDERR_LINE_MAX_BYTES));
                }
            }
        });

        let mut client = McpClient {
            name: name.to_string(),
            server_protocol: String::new(),
            server_info: String::new(),
            per_call,
            next_id: AtomicU64::new(1),
            stderr: sink,
            conn: tokio::sync::Mutex::new(Some(Connection {
                child,
                stdin,
                stdout: BufReader::new(stdout).lines(),
            })),
            death: Mutex::new(None),
        };

        let result = client
            .request_with_timeout(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    // EMPTY, AND THAT IS THE DECLARATION: no sampling, no roots, no
                    // elicitation. A conforming server may not ask this client for any of
                    // them, and a non-conforming one gets a protocol error.
                    "capabilities": {},
                    "clientInfo": {"name": CLIENT_NAME, "version": env!("CARGO_PKG_VERSION")},
                }),
                connect_timeout,
            )
            .await?;

        let protocol = result
            .get("protocolVersion")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                McpError::Protocol("the initialize result named no protocolVersion".into())
            })?
            .to_string();
        let info = result
            .get("serverInfo")
            .map(|i| {
                format!(
                    "{} {}",
                    i.get("name").and_then(|v| v.as_str()).unwrap_or("unnamed"),
                    i.get("version").and_then(|v| v.as_str()).unwrap_or("?"),
                )
            })
            .unwrap_or_else(|| "unnamed ?".to_string());

        // A server that declares no `tools` capability has nothing this client wants. Said
        // plainly at construction rather than discovered as an empty `tools/list`, which
        // reads like a grant problem and is not one.
        if result
            .get("capabilities")
            .and_then(|c| c.get("tools"))
            .is_none()
        {
            client
                .die("the server declares no `tools` capability, so it can expose nothing here")
                .await;
            return Err(McpError::Protocol(
                "the server declares no `tools` capability".into(),
            ));
        }

        client
            .notify("notifications/initialized", json!({}))
            .await?;

        // Assigned rather than built with a functional update: this type has a [`Drop`] impl,
        // so `..client` would be a partial move the compiler refuses.
        client.server_protocol = protocol;
        client.server_info = info;
        Ok(client)
    }

    /// The configured server name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The protocol version the server answered `initialize` with.
    pub fn server_protocol(&self) -> &str {
        &self.server_protocol
    }

    /// `<name> <version>` from the server's `serverInfo`. UNTRUSTED TEXT: it is a startup
    /// log line, never part of a tool description or anything a model reads.
    pub fn server_info(&self) -> &str {
        &self.server_info
    }

    /// How many lines the server has written to stderr, and how many bytes. **The trace takes
    /// these numbers; it never takes the text.**
    pub fn stderr_lines(&self) -> StderrCounts {
        self.stderr.counts.lock().map(|c| *c).unwrap_or_default()
    }

    /// The last few stderr lines, clipped. For an OPERATOR message about a server that would
    /// not start — never for a model, and never for the trace.
    pub fn stderr_tail(&self) -> Vec<String> {
        self.stderr
            .ring
            .lock()
            .map(|r| r.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Why this connection died, or `None` while it is alive.
    pub fn death_reason(&self) -> Option<String> {
        self.death.lock().ok().and_then(|d| d.clone())
    }

    /// Every tool the server advertises, following `nextCursor` while it pages.
    pub async fn list_tools(&self) -> Result<Vec<AdvertisedTool>, McpError> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        for page in 0..MAX_LIST_PAGES {
            let params = match &cursor {
                Some(c) => json!({"cursor": c}),
                None => json!({}),
            };
            let result = self.request("tools/list", params).await?;
            let tools = result
                .get("tools")
                .and_then(|v| v.as_array())
                .ok_or_else(|| {
                    McpError::Protocol(format!(
                        "the tools/list result on page {page} has no `tools` array"
                    ))
                })?
                .clone();
            for t in tools {
                let Some(name) = t.get("name").and_then(|v| v.as_str()) else {
                    self.die("a tools/list entry has no `name`").await;
                    return Err(McpError::Protocol(
                        "a tools/list entry has no `name`".into(),
                    ));
                };
                out.push(AdvertisedTool {
                    name: name.to_string(),
                    description: t
                        .get("description")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    // A missing schema becomes the empty object schema rather than an error:
                    // both wires require SOME object here, and a server that documents no
                    // arguments is a real and common shape.
                    input_schema: t
                        .get("inputSchema")
                        .filter(|s| s.is_object())
                        .cloned()
                        .unwrap_or_else(|| json!({"type": "object"})),
                });
            }
            match result.get("nextCursor").and_then(|v| v.as_str()) {
                Some(next) if !next.is_empty() => cursor = Some(next.to_string()),
                _ => return Ok(out),
            }
        }
        self.die("tools/list paged past the page limit without finishing")
            .await;
        Err(McpError::Protocol(format!(
            "tools/list returned a nextCursor on all {MAX_LIST_PAGES} pages"
        )))
    }

    /// Call one tool by the name the SERVER knows it under (never the `mcp__…` name).
    pub async fn call_tool(&self, tool: &str, arguments: Value) -> Result<CallOutcome, McpError> {
        let result = self
            .request("tools/call", json!({"name": tool, "arguments": arguments}))
            .await?;
        Ok(CallOutcome {
            content: result
                .get("content")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default(),
            structured: result.get("structuredContent").cloned(),
            is_error: result
                .get("isError")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        })
    }

    /// Shut the server down: close its stdin (the spec's stdio shutdown) and kill it.
    ///
    /// Called by [`Drop`], and callable directly by a caller that wants the child gone before
    /// the value is. Idempotent.
    pub async fn shutdown(&self) {
        self.die("the turn ended").await;
    }

    // ---- The wire ---------------------------------------------------------

    async fn request(&self, method: &str, params: Value) -> Result<Value, McpError> {
        self.request_with_timeout(method, params, self.per_call)
            .await
    }

    /// One request/response exchange, under a deadline.
    ///
    /// The deadline covers the WHOLE exchange, not one read: a server that emits a
    /// notification every second would otherwise reset a per-read timer forever.
    async fn request_with_timeout(
        &self,
        method: &str,
        params: Value,
        budget: Duration,
    ) -> Result<Value, McpError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let line = serde_json::to_string(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        }))
        .map_err(|e| McpError::Protocol(format!("could not serialise a {method} request: {e}")))?;

        let mut guard = self.conn.lock().await;
        if guard.is_none() {
            drop(guard);
            return Err(McpError::Dead(
                self.death_reason().unwrap_or_else(|| "unknown".into()),
            ));
        }
        // The exchange borrows the connection; the KILL borrows the slot the connection is
        // in. Doing both inside one scope is a borrow conflict, so the exchange runs first,
        // returns, and only then is the slot emptied — which also makes "every fatal error
        // kills the connection" one rule in one place rather than six call sites.
        let outcome = {
            let conn = guard.as_mut().expect("checked just above");
            exchange(conn, id, &line, budget, method).await
        };
        match outcome {
            Ok(v) => Ok(v),
            // A well-formed refusal is the server WORKING. Nothing is killed.
            Err(e @ McpError::Rpc { .. }) => Err(e),
            Err(e) => {
                self.kill_locked(&mut guard, &e.to_string()).await;
                Err(e)
            }
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<(), McpError> {
        let line = serde_json::to_string(&json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }))
        .map_err(|e| McpError::Protocol(format!("could not serialise {method}: {e}")))?;
        let deadline = Instant::now() + self.per_call;
        let mut guard = self.conn.lock().await;
        if guard.is_none() {
            drop(guard);
            return Err(McpError::Dead(
                self.death_reason().unwrap_or_else(|| "unknown".into()),
            ));
        }
        let written = {
            let conn = guard.as_mut().expect("checked just above");
            write_line(&mut conn.stdin, &line, deadline).await
        };
        if let Err(e) = written {
            self.kill_locked(&mut guard, &e.to_string()).await;
            return Err(e);
        }
        Ok(())
    }

    async fn die(&self, why: &str) {
        let mut guard = self.conn.lock().await;
        self.kill_locked(&mut guard, why).await;
    }

    /// Drop the connection and record why. The FIRST reason wins, because the first one is
    /// the cause and everything after it is a consequence.
    async fn kill_locked(&self, guard: &mut Option<Connection>, why: &str) {
        if let Ok(mut d) = self.death.lock() {
            if d.is_none() {
                *d = Some(why.to_string());
            }
        }
        if let Some(mut conn) = guard.take() {
            // The spec's stdio shutdown, then the kill. Closing stdin is what lets a
            // well-behaved server exit on its own; the kill is what stops one that does not.
            drop(conn.stdin);
            let _ = conn.child.start_kill();
        }
    }
}

/// One request written, and lines read until the matching reply. Every error it returns
/// except [`McpError::Rpc`] is fatal to the connection; the caller is what acts on that.
/// One request written, then lines read until the matching reply.
///
/// A free function taking the [`Connection`] rather than a method on [`McpClient`], and that
/// is what makes the borrows work: the exchange borrows the connection while the KILL borrows
/// the slot the connection sits in, so one scope cannot hold both. Every error returned here
/// except [`McpError::Rpc`] is fatal to the connection, and the CALLER is the single place
/// that acts on that.
async fn exchange(
    conn: &mut Connection,
    id: u64,
    line: &str,
    budget: Duration,
    method: &str,
) -> Result<Value, McpError> {
    // THE DEADLINE COVERS THE WHOLE EXCHANGE, not one read: a server that emitted a
    // notification every second would otherwise reset a per-read timer forever.
    let deadline = Instant::now() + budget;
    write_line(&mut conn.stdin, line, deadline).await?;
    loop {
        let next = match timeout_at(deadline, conn.stdout.next_line()).await {
            Err(_) => return Err(McpError::Timeout(budget)),
            Ok(Err(e)) => {
                return Err(McpError::Protocol(format!(
                    "could not read from the server: {e}"
                )))
            }
            Ok(Ok(None)) => {
                return Err(McpError::Protocol(format!(
                    "the server closed its output stream during {method}"
                )))
            }
            Ok(Ok(Some(line))) => line,
        };
        if next.trim().is_empty() {
            continue;
        }
        let msg: Value = serde_json::from_str(&next)
            .map_err(|e| McpError::Protocol(format!("a line on stdout is not JSON: {e}")))?;
        if msg.get("jsonrpc").and_then(|v| v.as_str()) != Some("2.0") {
            return Err(McpError::Protocol(
                "a message on stdout is not JSON-RPC 2.0".into(),
            ));
        }
        // A REQUEST FROM THE SERVER. This client advertised no capability that permits one,
        // so it is a violation rather than something to answer — answering would be
        // implementing sampling or elicitation by accident.
        if msg.get("method").is_some() && msg.get("id").is_some() {
            return Err(McpError::Protocol(format!(
                "the server sent a request ({}) to a client that advertised no capabilities",
                msg.get("method").and_then(|v| v.as_str()).unwrap_or("?")
            )));
        }
        // A notification. Ignored — this client subscribes to nothing — and it does NOT
        // reset the deadline, which is the point of the whole-exchange budget above.
        if msg.get("method").is_some() {
            continue;
        }
        match msg.get("id").and_then(|v| v.as_u64()) {
            Some(got) if got == id => {}
            // A reply to a request nobody is waiting for means this client's view of the
            // stream is wrong. There is no id left to trust, so the connection goes.
            other => {
                return Err(McpError::Protocol(format!(
                    "a reply carried id {other:?}, not the {id} that was sent"
                )))
            }
        }
        if let Some(err) = msg.get("error") {
            // A WELL-FORMED REFUSAL — the server framed a reply, gave it the right id, and
            // said no. The connection stays up.
            return Err(McpError::Rpc {
                code: err.get("code").and_then(|v| v.as_i64()).unwrap_or(0),
                message: err
                    .get("message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("(no message)")
                    .to_string(),
            });
        }
        return match msg.get("result") {
            Some(r) => Ok(r.clone()),
            None => Err(McpError::Protocol(format!(
                "the reply to {method} has neither result nor error"
            ))),
        };
    }
}

impl Drop for McpClient {
    /// **A SERVER NEVER OUTLIVES THE CLIENT THAT STARTED IT.**
    ///
    /// This runs synchronously and cannot take the async lock, so it relies on
    /// `kill_on_drop(true)` set at spawn: dropping the [`Child`] inside the mutex sends the
    /// kill. The explicit [`McpClient::shutdown`] is the graceful path (stdin closed first);
    /// this is the one that holds when a turn is cancelled and futures are dropped mid-call.
    fn drop(&mut self) {
        if let Ok(mut guard) = self.conn.try_lock() {
            if let Some(conn) = guard.take() {
                drop(conn);
            }
        }
    }
}

/// Write one framed line, under the same deadline the read half uses.
async fn write_line(stdin: &mut ChildStdin, line: &str, deadline: Instant) -> Result<(), McpError> {
    let mut buf = String::with_capacity(line.len() + 1);
    buf.push_str(line);
    buf.push('\n');
    match timeout_at(deadline, stdin.write_all(buf.as_bytes())).await {
        Err(_) => Err(McpError::Protocol(
            "the server stopped reading its stdin".into(),
        )),
        Ok(Err(e)) => Err(McpError::Protocol(format!(
            "could not write to the server: {e}"
        ))),
        Ok(Ok(())) => match timeout_at(deadline, stdin.flush()).await {
            Err(_) => Err(McpError::Protocol(
                "the server stopped reading its stdin".into(),
            )),
            Ok(Err(e)) => Err(McpError::Protocol(format!(
                "could not flush to the server: {e}"
            ))),
            Ok(Ok(())) => Ok(()),
        },
    }
}

/// Clip to a byte budget on a CHAR boundary, so a stderr line holding a multi-byte codepoint
/// at the cap does not panic the drain task.
fn clip(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let end = s
        .char_indices()
        .map(|(i, c)| i + c.len_utf8())
        .take_while(|e| *e <= max)
        .last()
        .unwrap_or(0);
    format!("{}…", &s[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipping_a_stderr_line_never_splits_a_codepoint() {
        assert_eq!(clip("hello", 10), "hello");
        // Four bytes each; a byte-wise cut at 5 would land inside the second one.
        let s = "🙂🙂";
        let out = clip(s, 5);
        assert_eq!(out, "🙂…");
    }

    #[test]
    fn every_error_says_what_happened_without_naming_a_credential() {
        let cases = [
            McpError::Spawn("no such file".into()),
            McpError::Protocol("bad line".into()),
            McpError::Timeout(Duration::from_secs(3)),
            McpError::Dead("earlier".into()),
            McpError::Rpc {
                code: -32602,
                message: "unknown tool".into(),
            },
        ];
        for e in cases {
            let text = e.to_string();
            assert!(!text.is_empty());
            assert!(!text.contains("Bearer"), "{text}");
        }
    }
}
