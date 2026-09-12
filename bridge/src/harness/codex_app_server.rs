//! **THE CODEX APP SERVER TRANSPORT** — the JSON-RPC conversation that replaced
//! `codex exec --json`, and the reason a Codex reply now grows on the phone instead of
//! landing whole.
//!
//! # Why this exists
//!
//! `codex exec --json` emits ITEMS, never deltas. Re-measured against codex-cli 0.153.4 on
//! 2026-09-06, a one-sentence turn produced exactly four events — `thread.started`,
//! `turn.started`, `item.completed` carrying the entire `agent_message`, `turn.completed` —
//! and there is no flag that changes it (`codex exec --help` on 0.153.4 offers `--json`,
//! `-o/--output-last-message` and nothing else that touches granularity). So the old harness
//! was not buffering the answer anywhere: **the answer genuinely did not exist in pieces**,
//! and `Codex::streams_text` returning `false` was an honest report of that.
//!
//! `codex app-server` is the same binary speaking a different protocol, and that protocol
//! DOES carry the pieces. The same prompt over the App Server produced 17
//! `item/agentMessage/delta` notifications, the first ~0.7s after the item opened and ~0.75s
//! before the turn completed. That gap is the whole feature.
//!
//! # The shape of the exchange
//!
//! Line-delimited JSON-RPC 2.0 over the child's stdin/stdout, three kinds of message on the
//! way back and they are NOT interchangeable:
//!
//!   * **Responses** — carry the `id` of a request this side sent. Correlated, and the only
//!     thing a `send_request` await ever resolves on.
//!   * **Notifications** — no `id`. The turn's whole event stream is here.
//!   * **Server requests** — a `method` AND an `id`, sent BY the server, expecting a reply
//!     from us. Approvals arrive this way. Ignoring one hangs the turn; auto-answering one
//!     "yes" would hand the model a boundary override. See [`answer_server_request`].
//!
//! The turn itself is `initialize` → `initialized` → (`thread/start` | `thread/resume`) →
//! `turn/start` → notifications until `turn/completed`.
//!
//! # What is deliberately NOT here
//!
//! No daemon, no shared server, no socket. One `codex app-server --listen stdio://` child
//! per turn, spawned by [`crate::Codex::command`] with the same per-turn `CODEX_HOME`, the
//! same `-c` containment overrides and the same `kill_on_drop` the `exec` child had — so the
//! isolation argument the harness rests on is unchanged, and a cancelled turn is still a
//! killed process rather than a message nobody is left to send.

use crate::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdin, ChildStdout};

/// What this client calls itself in `initialize`. Codex folds it into the `userAgent` it
/// sends upstream, so it is a real identifier rather than decoration: it is how a turn this
/// bridge ran is distinguishable from one the desktop app ran.
const CLIENT_NAME: &str = "jesse-bridge";

/// A cap on how much of one JSON-RPC line is worth reading. The App Server can send a very
/// large `turn/completed` (it inlines every item of the turn), and a runaway line must not be
/// able to grow this process without bound. Lines past the cap are dropped with the turn
/// still running — a dropped `turn/completed` becomes the "no terminal event" fallback,
/// which is a visible failure rather than a silent truncation.
const MAX_LINE_BYTES: usize = 32 * 1024 * 1024;

/// The driver: one instance per spawn attempt, holding only what has to survive between
/// notifications of the SAME turn.
///
/// A `Default` unit-ish struct rather than something built from the request, because
/// everything the exchange needs about the turn arrives in [`TurnDriveCtx`] — which keeps
/// this constructible by [`crate::Codex::reader`] without a config in hand, exactly as
/// `CodexParser::default()` was.
#[derive(Default)]
pub struct CodexAppServerDriver;

impl TurnDriver for CodexAppServerDriver {
    fn drive<'a>(
        &'a mut self,
        stdin: ChildStdin,
        stdout: ChildStdout,
        ctx: TurnDriveCtx<'a>,
    ) -> Pin<Box<dyn Future<Output = ClaudeOutcome> + Send + 'a>> {
        Box::pin(async move {
            let mut conn = Connection::new(stdin, stdout);
            match run_turn(&mut conn, &ctx).await {
                Ok(outcome) => outcome,
                Err(e) => e.into_outcome(),
            }
        })
    }
}

// ---- Failure vocabulary ----------------------------------------------------------

/// Why the exchange stopped early. Separated from [`ClaudeOutcome`] only so the happy path
/// can use `?`; every variant reduces to one at the boundary and nothing else reads it.
enum Stop {
    /// The pipe closed, the JSON did not parse, or the protocol said something this client
    /// cannot act on. Always fatal: there is no half-alive App Server to keep talking to.
    Protocol(String),
    /// The server answered a request with a JSON-RPC error, or sent a terminal `error`
    /// notification. Classified through [`crate::codex_failure`], so a dead credential is
    /// still `Fatal` with the operator remedy rather than a generic bad gateway.
    Turn(String),
}

impl Stop {
    fn into_outcome(self) -> ClaudeOutcome {
        match self {
            Stop::Protocol(m) => ClaudeOutcome::Fatal {
                message: format!("codex app server: {m}"),
            },
            Stop::Turn(m) => codex_failure(m),
        }
    }
}

type Step<T> = Result<T, Stop>;

// ---- The connection --------------------------------------------------------------

/// One child's stdio, framed as JSON-RPC.
///
/// Requests and notifications go out on stdin; everything comes back on stdout. The read
/// side is a single cursor rather than a background task ON PURPOSE: there is exactly one
/// consumer (this turn), and a spawned reader would have to be cancelled on every early
/// return and would outlive a dropped driver — which is precisely the leak the drop-is-cancel
/// contract on [`TurnDriver`] exists to avoid.
struct Connection {
    stdin: ChildStdin,
    lines: tokio::io::Lines<BufReader<ChildStdout>>,
    next_id: i64,
    /// Every stdout line, verbatim, when someone asked for them. `None` on a real turn: the
    /// bridge has no use for the raw text and keeping it would grow with the turn.
    ///
    /// The containment battery is the one caller that does want it — it SCORES the child's
    /// own words (what it tried, what the exit code was) rather than the bridge's reading of
    /// them, which is the whole reason the battery is trusted. See [`drive_probe_turn`].
    transcript: Option<String>,
}

/// One message read off the child, already sorted into the three kinds the protocol has.
enum Incoming {
    Response {
        id: i64,
        result: Value,
    },
    Error {
        id: i64,
        message: String,
    },
    Notification {
        method: String,
        params: Value,
    },
    ServerRequest {
        id: Value,
        method: String,
        params: Value,
    },
}

impl Connection {
    fn new(stdin: ChildStdin, stdout: ChildStdout) -> Self {
        Self {
            stdin,
            lines: BufReader::new(stdout).lines(),
            next_id: 0,
            transcript: None,
        }
    }

    async fn write(&mut self, msg: &Value) -> Step<()> {
        let mut line = serde_json::to_string(msg)
            .map_err(|e| Stop::Protocol(format!("could not encode a request ({e})")))?;
        line.push('\n');
        self.stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| Stop::Protocol(format!("could not write to the child ({e})")))?;
        self.stdin
            .flush()
            .await
            .map_err(|e| Stop::Protocol(format!("could not flush the child's stdin ({e})")))
    }

    /// Send a request and return its id. The response is claimed later by
    /// [`Self::await_response`], because notifications for the SAME turn arrive interleaved
    /// with it and must not be dropped while waiting.
    async fn request(&mut self, method: &str, params: Value) -> Step<i64> {
        self.next_id += 1;
        let id = self.next_id;
        // A method that takes no parameters gets NO `params` key, not a null one — see
        // [`read_account_rate_limits`] for the method that needs it.
        let msg = if params.is_null() {
            json!({"jsonrpc": "2.0", "id": id, "method": method})
        } else {
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        };
        self.write(&msg).await?;
        Ok(id)
    }

    async fn notify(&mut self, method: &str, params: Value) -> Step<()> {
        self.write(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    async fn respond(&mut self, id: Value, result: Value) -> Step<()> {
        self.write(&json!({"jsonrpc": "2.0", "id": id, "result": result}))
            .await
    }

    /// Read the next message, or `None` at clean EOF.
    ///
    /// **A NOTIFICATION SPLIT ACROSS READS IS NOT A CASE THIS HAS TO HANDLE, and that is a
    /// property of the framing rather than an assumption.** `Lines` yields only on a newline,
    /// so a partial line is buffered until the rest arrives; what it cannot do is bound its
    /// buffer, which is what [`MAX_LINE_BYTES`] is for.
    async fn next(&mut self) -> Step<Option<Incoming>> {
        loop {
            let line = self
                .lines
                .next_line()
                .await
                .map_err(|e| Stop::Protocol(format!("could not read the child ({e})")))?;
            let Some(line) = line else { return Ok(None) };
            let line = line.trim();
            if line.is_empty() || line.len() > MAX_LINE_BYTES {
                continue;
            }
            if let Some(t) = self.transcript.as_mut() {
                t.push_str(line);
                t.push('\n');
            }
            // Non-JSON on stdout is a banner or a stray log line, not a protocol violation.
            let Ok(v) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let method = v.get("method").and_then(Value::as_str);
            let id = v.get("id").cloned();
            return Ok(Some(match (method, id) {
                (Some(m), Some(id)) => Incoming::ServerRequest {
                    id,
                    method: m.to_string(),
                    params: v.get("params").cloned().unwrap_or(Value::Null),
                },
                (Some(m), None) => Incoming::Notification {
                    method: m.to_string(),
                    params: v.get("params").cloned().unwrap_or(Value::Null),
                },
                (None, Some(id)) => {
                    let id = id.as_i64().unwrap_or(-1);
                    match v.get("error") {
                        Some(err) => Incoming::Error {
                            id,
                            message: rpc_error_message(err),
                        },
                        None => Incoming::Response {
                            id,
                            result: v.get("result").cloned().unwrap_or(Value::Null),
                        },
                    }
                }
                // No method and no id is not a JSON-RPC message at all.
                (None, None) => continue,
            }));
        }
    }
}

/// Flatten a JSON-RPC `error` object into one operator-facing line, keeping the `message`
/// (which is where an upstream HTTP status lands, and therefore what
/// [`crate::codex_failure`] matches an auth failure on) and appending `data` only when it is
/// a string.
fn rpc_error_message(err: &Value) -> String {
    let msg = err
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the app server reported an error");
    match err.get("data").and_then(Value::as_str) {
        Some(d) if !d.is_empty() => format!("{msg}: {d}"),
        _ => msg.to_string(),
    }
}

// ---- The turn --------------------------------------------------------------------

/// Accumulated turn state. Everything here exists because a value arrives in one
/// notification and is needed in another.
#[derive(Default)]
struct TurnState {
    /// Which agent-message items are the VISIBLE ANSWER, keyed by item id.
    ///
    /// `item/agentMessage/delta` carries no phase — only `itemId` — so the phase has to be
    /// remembered from the `item/started` that opened it. Absent from the map means "not an
    /// agent message", which is not the same as "unknown phase" and must not be treated as
    /// one; see [`Phase`].
    phases: HashMap<String, Phase>,
    /// The text streamed for the item currently believed to be the answer, so a `completed`
    /// item that AGREES with the deltas can be recognised as agreement rather than as a
    /// second copy.
    streamed: String,
    /// The authoritative answer: the last completed answer-phase agent message. LAST ONE
    /// WINS, exactly as the `exec` parser's did, and for the same reason — a turn may emit
    /// several, and the final one is the reply.
    message: Option<String>,
    /// The thread this turn runs in, reported to the bridge the moment it is known.
    thread_id: Option<String>,
    /// The turn id, needed to address a `turn/interrupt` and to ignore notifications
    /// belonging to a turn this driver did not start.
    turn_id: Option<String>,
    /// Token counts from the last `thread/tokenUsage/updated`, which is where the App Server
    /// reports what the `exec` stream reported on `turn.completed`.
    usage: ShadowUsage,
    /// The last non-terminal `error` notification's text, kept only as a fallback cause —
    /// same role, same reasoning, as the `exec` parser's `last_error`.
    last_error: Option<String>,
}

/// What an agent-message item is FOR, as this bridge treats it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    /// `phase: "final_answer"`, or absent. **Absent counts as the answer**, and that is the
    /// compatibility behaviour the protocol's own schema asks for: "providers do not emit
    /// this consistently, so callers must treat `None` as phase unknown and keep
    /// compatibility behavior for legacy models". Treating unknown as commentary would make
    /// a model that never sets the field produce an empty reply.
    Answer,
    /// `phase: "commentary"` — the mid-turn preamble ("I'll create hello.txt…"), which this
    /// bridge has never shown and does not start showing now. Its deltas are dropped and its
    /// completed text never becomes the reply, which is byte-for-byte what the `exec`
    /// parser's last-one-wins accumulation did to it.
    Commentary,
}

impl Phase {
    fn of(item: &Value) -> Self {
        match item.get("phase").and_then(Value::as_str) {
            Some("commentary") => Phase::Commentary,
            _ => Phase::Answer,
        }
    }
}

/// The whole exchange, from handshake to terminal outcome.
async fn run_turn(conn: &mut Connection, ctx: &TurnDriveCtx<'_>) -> Step<ClaudeOutcome> {
    // ---- Handshake. Nothing else may be sent until the response comes back: the server
    // rejects a request that arrives before `initialize` is handled ("Initialize should be
    // handled before initialized request dispatch"), so this one await is not optional.
    let id = conn
        .request(
            "initialize",
            json!({"clientInfo": {"name": CLIENT_NAME, "version": env!("CARGO_PKG_VERSION")}}),
        )
        .await?;
    let mut state = TurnState::default();
    let hello = await_response(conn, ctx, &mut state, id).await?;
    conn.notify("initialized", json!({})).await?;

    // THE WRITE LOCK'S HOOKS, TRUSTED — before any thread exists, because a hook that is not
    // trusted before the turn starts is a hook that does not run during it.
    let home = hello
        .get("codexHome")
        .and_then(Value::as_str)
        .map(PathBuf::from);
    if let Some(home) = home {
        grant_own_hook_trust(conn, ctx, &mut state, &home).await?;
    }

    // ---- The thread. A resume target that is not a synthetic ledger id means this
    // conversation already has a Codex thread, and it lives in THIS turn's `CODEX_HOME`
    // (resolved by `codex_home_for_turn` before the child was spawned). A blank thread is
    // never silently substituted for a resume that fails — the error is returned, which is
    // the same rule `codex_home_for_turn` enforces one layer up when the rollout is missing
    // altogether.
    let resume = ctx
        .req
        .session_id
        .filter(|sid| !is_synthetic_session_id(sid));
    let thread = match resume {
        Some(sid) => {
            let id = conn
                .request(
                    "thread/resume",
                    json!({
                        "threadId": sid,
                        "cwd": ctx.req.cwd.display().to_string(),
                        // Hydrating the whole history back into this process is pure waste:
                        // the thread's items are already in the child, and the App Server
                        // deprecates full hydration for paginated threads.
                        "excludeTurns": true,
                    }),
                )
                .await?;
            await_response(conn, ctx, &mut state, id).await?
        }
        None => {
            let id = conn
                .request(
                    "thread/start",
                    json!({"cwd": ctx.req.cwd.display().to_string()}),
                )
                .await?;
            await_response(conn, ctx, &mut state, id).await?
        }
    };
    let thread_id = thread
        .get("thread")
        .and_then(|t| t.get("id"))
        .and_then(Value::as_str)
        .ok_or_else(|| Stop::Protocol("the thread response named no thread id".to_string()))?
        .to_string();
    // BEFORE the turn runs, and this is the whole reason `on_session` is a callback rather
    // than a field of the outcome: a turn that dies mid-flight has still bound its thread,
    // and on a harness with no transcript on disk that binding is the only record there is.
    note_session(ctx, &mut state, &thread_id);

    // ---- The turn.
    let id = conn
        .request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": [{"type": "text", "text": ctx.req.prompt}],
            }),
        )
        .await?;
    let started = await_response(conn, ctx, &mut state, id).await?;
    if let Some(tid) = started
        .get("turn")
        .and_then(|t| t.get("id"))
        .and_then(Value::as_str)
    {
        state.turn_id = Some(tid.to_string());
    }

    // ---- The event stream, until a terminal.
    loop {
        let Some(msg) = conn.next().await? else {
            // Clean EOF with no terminal event. NOT dressed up as a success: the driver's
            // `resolve_stream_outcome` gets a `None` terminal and decides, exactly as it does
            // when the line path reaches EOF without a `Done`.
            return Err(Stop::Protocol(
                "the child exited before the turn completed".to_string(),
            ));
        };
        match handle(conn, ctx, &mut state, msg).await? {
            Some(outcome) => return Ok(outcome),
            None => continue,
        }
    }
}

/// Pump messages until the response to `id` arrives, handling everything else on the way.
///
/// **The pump is what makes correlation safe.** A naive "read one line and expect the
/// response" loses every notification the server sends while the request is in flight — and
/// `thread/start` alone emits `thread/started` and one `mcpServer/startupStatus/updated` per
/// server BEFORE its own response. Those carry the mid-turn events, so dropping them drops
/// the feature.
async fn await_response(
    conn: &mut Connection,
    ctx: &TurnDriveCtx<'_>,
    state: &mut TurnState,
    id: i64,
) -> Step<Value> {
    loop {
        let Some(msg) = conn.next().await? else {
            return Err(Stop::Protocol(
                "the child exited before answering".to_string(),
            ));
        };
        match msg {
            Incoming::Response {
                id: reply_to,
                result,
            } if reply_to == id => return Ok(result),
            Incoming::Error {
                id: reply_to,
                message,
            } if reply_to == id => return Err(Stop::Turn(message)),
            other => {
                // A terminal arriving while a request is in flight is a protocol the client
                // does not understand: nothing this side sends can be answered by a turn that
                // has already ended. Surfaced rather than swallowed.
                if handle(conn, ctx, state, other).await?.is_some() {
                    return Err(Stop::Protocol(
                        "the turn ended before the app server answered a pending request"
                            .to_string(),
                    ));
                }
            }
        }
    }
}

/// One message, dispatched. `Some(outcome)` ends the turn; `None` continues it.
async fn handle(
    conn: &mut Connection,
    ctx: &TurnDriveCtx<'_>,
    state: &mut TurnState,
    msg: Incoming,
) -> Step<Option<ClaudeOutcome>> {
    match msg {
        // A response or error for a request nobody is waiting on. There is no such request
        // in this exchange, so it is noise rather than a fault.
        Incoming::Response { .. } | Incoming::Error { .. } => Ok(None),
        Incoming::ServerRequest { id, method, params } => {
            let result = answer_server_request(&method, &params);
            conn.respond(id, result).await?;
            Ok(None)
        }
        Incoming::Notification { method, params } => Ok(notification(ctx, state, &method, &params)),
    }
}

/// **EVERY SERVER REQUEST IS ANSWERED, AND EVERY APPROVAL IS DENIED.**
///
/// Two separate obligations, and both are load-bearing.
///
/// ANSWERING: the App Server blocks the turn on an unanswered request. `codex exec` never
/// asked, because `approval_policy="never"` made a sandbox denial terminal there; the same
/// override is on this child's argv and is still the primary control, so an approval request
/// arriving at all is already off the expected path. It is answered anyway, because a turn
/// that hangs until the driver's timeout is strictly worse than one that is told no.
///
/// DENYING: the approval prompt is the escalation route AROUND the sandbox. A client that
/// auto-approves has converted "the boundary says no" into "the boundary asks, and the bridge
/// says yes", which is the boundary not existing. So every approval shape answers with its
/// own spelling of no, and an UNRECOGNISED request answers with a JSON-RPC-shaped refusal
/// rather than an empty object — a future request kind the bridge has never seen must not be
/// able to mean "granted" by default.
///
/// The one request that is not an approval is `account/chatgptAuthTokens/refresh`, and it is
/// refused for a different reason: this bridge does not hold the refresh flow, the credential
/// in the per-turn home does. Refusing it makes an expired login fail loudly instead of
/// silently minting a token nothing recorded.
fn answer_server_request(method: &str, _params: &Value) -> Value {
    match method {
        // The exec-approval family. All three take the same decision vocabulary.
        "execCommandApproval"
        | "applyPatchApproval"
        | "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval" => json!({"decision": "denied"}),
        // Permission escalation (a broader grant for the rest of the turn).
        "item/permissions/requestApproval" => json!({"decision": "denied"}),
        // An MCP server asking the user something. There is no user on a headless turn.
        "mcpServer/elicitation/request" => json!({"action": "decline"}),
        // A tool asking the user for input, same reasoning.
        "item/tool/requestUserInput" => json!({"cancelled": true}),
        _ => json!({
            "error": {
                "code": -32601,
                "message": format!(
                    "{CLIENT_NAME} does not grant `{method}`: this turn is headless and its \
                     containment posture is set on the command line, not negotiated"
                ),
            }
        }),
    }
}

/// One notification. `Some(outcome)` is terminal.
fn notification(
    ctx: &TurnDriveCtx<'_>,
    state: &mut TurnState,
    method: &str,
    params: &Value,
) -> Option<ClaudeOutcome> {
    match method {
        // Corroborates the thread id the `thread/start` response already gave. Recorded
        // again because `SpawnedSessions::record` is idempotent and because a future protocol
        // change that moves the id here alone must not silently lose it.
        "thread/started" => {
            if let Some(id) = params
                .get("thread")
                .and_then(|t| t.get("id"))
                .and_then(Value::as_str)
            {
                let id = id.to_string();
                note_session(ctx, state, &id);
            }
            None
        }

        // THE FEATURE. A chunk of an agent message — but only the ANSWER's chunks reach the
        // client. See [`Phase`].
        "item/agentMessage/delta" => {
            let item = params.get("itemId").and_then(Value::as_str)?;
            let delta = params.get("delta").and_then(Value::as_str)?;
            if state.phases.get(item) != Some(&Phase::Answer) {
                return None;
            }
            state.streamed.push_str(delta);
            ctx.sink.text_delta(delta);
            None
        }

        "item/started" => {
            let item = params.get("item")?;
            match item.get("type").and_then(Value::as_str).unwrap_or_default() {
                "agentMessage" => {
                    let id = item.get("id").and_then(Value::as_str)?;
                    state.phases.insert(id.to_string(), Phase::of(item));
                }
                // The mid-turn activity feed, in the same one vocabulary the line path used.
                "commandExecution" => ctx.sink.tool_activity(ToolActivity::used("Bash")),
                "fileChange" => ctx.sink.tool_activity(ToolActivity::used("Edit")),
                "mcpToolCall" => {
                    let server = item.get("server").and_then(Value::as_str).unwrap_or("mcp");
                    let tool = item.get("tool").and_then(Value::as_str).unwrap_or_default();
                    ctx.sink
                        .tool_activity(ToolActivity::used(format!("mcp__{server}__{tool}")));
                }
                _ => {}
            }
            None
        }

        // THE AUTHORITATIVE TEXT. A completed answer item's `text` is the final state of that
        // item, and it REPLACES what the deltas accumulated rather than appending to it —
        // which is what keeps a final item that differs from the deltas (a provider that
        // reflows, redacts or normalises its own message) from being delivered twice.
        //
        // The streamed buffer is reset with it so the NEXT answer item starts clean; a turn
        // with two answer items delivers the last, exactly as before.
        "item/completed" => {
            let item = params.get("item")?;
            if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                return None;
            }
            if Phase::of(item) == Phase::Commentary {
                return None;
            }
            if let Some(text) = item.get("text").and_then(Value::as_str) {
                state.message = Some(text.to_string());
                state.streamed.clear();
            }
            None
        }

        "thread/tokenUsage/updated" => {
            if let Some(total) = params.get("tokenUsage").and_then(|u| u.get("total")) {
                state.usage = app_server_usage(total);
            }
            None
        }

        // THE ACCOUNT'S STANDING, for free: a turn on the ChatGPT login is told its rate limits
        // as they move, in the shape `account/rateLimits/read` answers with. Sparse by the
        // protocol's own contract ("nullable metadata missing from an update does not clear a
        // previously observed value"), so it reaches the store as a patch, never a snapshot. A
        // model on its own provider key does not spend the ChatGPT account, and its report is
        // dropped.
        "account/rateLimits/updated" => {
            if let Some(rate_limits) = params.get("rateLimits").filter(|r| r.is_object()) {
                if quota_scope_for_active(ctx.req.active) == Some(QuotaScopeId::CodexChatgpt) {
                    ctx.sink.quota(
                        QuotaScopeId::CodexChatgpt,
                        codex_rate_limits_patch(rate_limits),
                    );
                }
            }
            None
        }

        // NOT TERMINAL WHEN THE SERVER SAYS IT WILL RETRY, and the distinction is the same
        // one the `exec` parser drew from experience: Codex narrates its internal reconnects
        // as errors, and ending the turn on the first one abandons a child with attempts
        // left and reports "Reconnecting… 2/5" as the cause. A `willRetry: false` error is a
        // real terminal and is treated as one.
        "error" => {
            let message = params
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string);
            if params.get("willRetry").and_then(Value::as_bool) == Some(false) {
                return Some(codex_failure(
                    message
                        .or_else(|| state.last_error.clone())
                        .unwrap_or_else(|| "codex reported a turn failure".to_string()),
                ));
            }
            if let Some(m) = message {
                state.last_error = Some(m);
            }
            None
        }

        "turn/completed" => {
            let turn = params.get("turn")?;
            // Ignore a turn this driver did not start. One child serves one turn today, so
            // this cannot fire — but a future that reuses a child must not deliver another
            // turn's answer, and the guard is one comparison.
            if let (Some(mine), Some(theirs)) = (
                state.turn_id.as_deref(),
                turn.get("id").and_then(Value::as_str),
            ) {
                if mine != theirs {
                    return None;
                }
            }
            match turn.get("status").and_then(Value::as_str) {
                // A turn that FAILED must never be delivered as a success carrying whatever
                // text happened to stream before it died. `turn.error` is the cause; the
                // partial text stays where it already is (the job's stream accumulator and
                // the trace), which is what leaves it visibly incomplete.
                Some("failed") => Some(codex_failure(
                    turn.get("error")
                        .and_then(|e| e.get("message"))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| state.last_error.clone())
                        .unwrap_or_else(|| "codex reported a turn failure".to_string()),
                )),
                // An INTERRUPTED turn is a turn somebody stopped. Nothing in this bridge
                // sends `turn/interrupt` (a cancel kills the child), so reaching this means
                // the server stopped it, and reporting it as a clean success would claim an
                // answer nobody finished.
                Some("interrupted") => Some(ClaudeOutcome::Fatal {
                    message: "codex interrupted the turn before it completed".to_string(),
                }),
                _ => Some(ClaudeOutcome::Ok {
                    // The completed item's text when there was one; otherwise the deltas
                    // this turn actually streamed. The second arm is the same safety net
                    // `resolve_stream_outcome` provides one layer up, applied here too so
                    // the outcome is complete on its own — which is what
                    // `TurnOutcome::text`'s contract asks of every harness.
                    result: state
                        .message
                        .clone()
                        .filter(|m| !m.trim().is_empty())
                        .unwrap_or_else(|| state.streamed.clone()),
                    session_id: state.thread_id.clone(),
                    usage: state.usage.clone(),
                }),
            }
        }

        _ => None,
    }
}

/// Record the thread id once, on the bridge's side and on this turn's state.
fn note_session(ctx: &TurnDriveCtx<'_>, state: &mut TurnState, id: &str) {
    if state.thread_id.as_deref() == Some(id) {
        return;
    }
    state.thread_id = Some(id.to_string());
    (ctx.on_session)(id);
}

/// Map the App Server's `tokenUsage.total` onto the bridge's Anthropic-shaped
/// [`ShadowUsage`].
///
/// SAME CORRECTION AS [`crate::codex_usage`], which this replaces on the App Server path, and
/// for the same reason: Codex reports `inputTokens` as the TOTAL prompt with
/// `cachedInputTokens` a SUBSET of it, while `ShadowUsage::cost` assumes the Anthropic
/// convention where the two are added. Feeding the numbers through unchanged bills every
/// cached token twice. The only difference from the `exec` mapping is the key spelling —
/// `exec` sent snake_case, the App Server sends camelCase — which is exactly the kind of
/// silent zero this note exists to stop someone reintroducing.
fn app_server_usage(total: &Value) -> ShadowUsage {
    let n = |k: &str| total.get(k).and_then(Value::as_u64);
    let cached = n("cachedInputTokens");
    ShadowUsage {
        input_tokens: n("inputTokens").map(|t| t.saturating_sub(cached.unwrap_or(0))),
        cache_read_input_tokens: cached,
        cache_creation_input_tokens: n("cacheWriteInputTokens"),
        output_tokens: match (n("outputTokens"), n("reasoningOutputTokens")) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0) + b.unwrap_or(0)),
        },
    }
}

// ---- The containment battery's entry point ---------------------------------------

/// Run one turn over an App Server child and hand back **every stdout line it wrote**, plus
/// whether the turn reached a terminal event.
///
/// # Why this is not the driver
///
/// The containment battery scores a child by reading what the CHILD said — which command it
/// ran, what exit code came back, whether the kernel refused it — rather than by reading the
/// bridge's interpretation of it. That is deliberate and it is what makes the record worth
/// anything: a bridge that mis-parses a refusal would otherwise score its own bug as a
/// boundary holding. So the battery wants raw text, and [`TurnDriver::drive`] returns a
/// [`ClaudeOutcome`].
///
/// # Why it is not a second client either
///
/// It shares [`Connection`], the handshake, the thread and turn requests, and — the part that
/// would matter most if it drifted — [`answer_server_request`], so the battery's child is
/// offered exactly the same approvals a real turn's child is, and is refused them the same
/// way. A battery that auto-approved would certify a boundary nothing in production has.
///
/// Under `codex exec` this had no equivalent: the battery spawned the child and read its
/// stdout to EOF, because the argv was the whole request. An App Server child that is never
/// spoken to sits waiting for `initialize` until the battery's timeout and scores every probe
/// `inconclusive` — which is how this function came to exist.
pub async fn drive_probe_turn(
    stdin: ChildStdin,
    stdout: ChildStdout,
    prompt: &str,
    cwd: &Path,
) -> (String, bool) {
    let mut conn = Connection::new(stdin, stdout);
    conn.transcript = Some(String::new());
    let completed = probe_exchange(&mut conn, prompt, cwd).await.is_ok();
    (conn.transcript.unwrap_or_default(), completed)
}

/// The exchange itself, split out so the transcript survives an early return.
async fn probe_exchange(conn: &mut Connection, prompt: &str, cwd: &Path) -> Step<()> {
    let id = conn
        .request(
            "initialize",
            json!({"clientInfo": {"name": CLIENT_NAME, "version": env!("CARGO_PKG_VERSION")}}),
        )
        .await?;
    probe_await(conn, id).await?;
    conn.notify("initialized", json!({})).await?;

    let id = conn
        .request("thread/start", json!({"cwd": cwd.display().to_string()}))
        .await?;
    let thread = probe_await(conn, id).await?;
    let thread_id = thread
        .get("thread")
        .and_then(|t| t.get("id"))
        .and_then(Value::as_str)
        .ok_or_else(|| Stop::Protocol("the thread response named no thread id".to_string()))?
        .to_string();

    let id = conn
        .request(
            "turn/start",
            json!({"threadId": thread_id, "input": [{"type": "text", "text": prompt}]}),
        )
        .await?;
    probe_await(conn, id).await?;

    loop {
        let Some(msg) = conn.next().await? else {
            return Err(Stop::Protocol("the child exited early".to_string()));
        };
        match msg {
            Incoming::ServerRequest { id, method, params } => {
                let result = answer_server_request(&method, &params);
                conn.respond(id, result).await?;
            }
            Incoming::Notification { method, .. } if method == "turn/completed" => return Ok(()),
            _ => {}
        }
    }
}

async fn probe_await(conn: &mut Connection, id: i64) -> Step<Value> {
    loop {
        let Some(msg) = conn.next().await? else {
            return Err(Stop::Protocol("the child exited early".to_string()));
        };
        match msg {
            Incoming::Response {
                id: reply_to,
                result,
            } if reply_to == id => return Ok(result),
            Incoming::Error {
                id: reply_to,
                message,
            } if reply_to == id => return Err(Stop::Turn(message)),
            Incoming::ServerRequest { id, method, params } => {
                let result = answer_server_request(&method, &params);
                conn.respond(id, result).await?;
            }
            _ => {}
        }
    }
}

// ---- The account's rate limits, and nothing else ---------------------------------

/// Ask an App Server child for the ChatGPT account's rate limits — the whole exchange behind
/// the `codex-chatgpt` quota scope (see [`crate::quota::fetch_codex`]).
///
/// `initialize`, `initialized`, `account/rateLimits/read`, and stop: no `thread/start`, no
/// `turn/start`, no model call, so nothing here is a turn the containment record has to speak
/// for. It shares [`Connection`], the handshake and — through [`probe_await`] —
/// [`answer_server_request`], so a server request arriving mid-exchange is refused exactly as a
/// turn refuses it.
///
/// **THE METHOD TAKES NO PARAMS ON THE PINNED BINARY.** Measured against codex-cli 0.153.4 on
/// 2026-09-12: `{"excludeResetCreditDetails": true}` is answered with `-32600 Invalid request:
/// invalid type: map, expected unit`, and a request with no `params` key is answered with the
/// limits. So none is sent.
///
/// Returns the result object, or the server's error text for the caller to CLASSIFY — never to
/// log, since it can carry account detail. Consumes the pipes: when this returns, the child's
/// stdin is closed, which is its cue to exit.
pub async fn read_account_rate_limits(
    stdin: ChildStdin,
    stdout: ChildStdout,
) -> Result<Value, String> {
    let mut conn = Connection::new(stdin, stdout);
    rate_limits_exchange(&mut conn)
        .await
        .map_err(|stop| match stop {
            Stop::Protocol(m) | Stop::Turn(m) => m,
        })
}

async fn rate_limits_exchange(conn: &mut Connection) -> Step<Value> {
    let id = conn
        .request(
            "initialize",
            json!({"clientInfo": {"name": CLIENT_NAME, "version": env!("CARGO_PKG_VERSION")}}),
        )
        .await?;
    probe_await(conn, id).await?;
    conn.notify("initialized", json!({})).await?;
    let id = conn.request("account/rateLimits/read", Value::Null).await?;
    probe_await(conn, id).await
}

// ---- The write lock's hooks, trusted rather than bypassed -------------------------

/// **GRANT TRUST TO THE HOOKS FILE THIS BRIDGE WROTE, AND TO NOTHING ELSE.**
///
/// # Why this exists at all
///
/// Codex LOADS `$CODEX_HOME/hooks.json` — `hooks/list` reports the bridge's two entries
/// `enabled: true` — and then declines to RUN them, because an untrusted hooks file is
/// skipped **silently**: no notification, no stderr line, and the write lands unlocked. A
/// bridge that believes it is locking the vault and is not is the exact failure the whole
/// write-lock mechanism exists to prevent, and it is the failure mode that looks identical to
/// success.
///
/// Under `codex exec` the answer was `--dangerously-bypass-hook-trust`. The App Server does
/// not define it, and `-c bypass_hook_trust=true` is not a stand-in — measured on 0.153.4,
/// `hooks/list` still answered `trustStatus: "untrusted"` with that override on the argv, and
/// the live write-lock certification still saw no hook reach the broker.
///
/// # Why what replaces it is STRONGER than what it replaces
///
/// The flag bypassed review of whatever the file happened to say. This records a trust entry
/// keyed by the hook's own identity and **pinned to its content hash**, which Codex computes
/// and reports: change the file and the hash no longer matches, and the hook goes back to
/// untrusted. So the thing being trusted is not "hooks files in general" but "this exact
/// file, with these exact commands" — which is the file this process wrote, seconds ago, into
/// a directory nothing else reaches.
///
/// # The scope, stated narrowly
///
/// Only hooks whose `sourcePath` is `<codexHome>/hooks.json` are granted anything, and
/// `codexHome` comes from the server's own `initialize` response rather than from this side's
/// idea of where it pointed the child. A hook from any other source — a plugin, a project
/// file, an operator's home — is left exactly as untrusted as it was found. A turn with no
/// hooks file writes nothing at all.
///
/// A failure to grant is NOT fatal: a read turn has no hooks to trust, and a write turn whose
/// grant failed will fail its lock check loudly rather than silently, which is what
/// `writelock_live` certifies. Returning an error here would turn a hook-less turn into a
/// dead one.
async fn grant_own_hook_trust(
    conn: &mut Connection,
    ctx: &TurnDriveCtx<'_>,
    state: &mut TurnState,
    home: &Path,
) -> Step<()> {
    let ours = home.join(CODEX_HOOKS_FILE);
    if !ours.is_file() {
        return Ok(());
    }
    let id = conn
        .request(
            "hooks/list",
            json!({"cwds": [ctx.req.cwd.display().to_string()]}),
        )
        .await?;
    let listed = await_response(conn, ctx, state, id).await?;

    let mut edits = Vec::new();
    for entry in listed
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        for hook in entry
            .get("hooks")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let source = hook.get("sourcePath").and_then(Value::as_str);
            if source.map(Path::new) != Some(ours.as_path()) {
                continue;
            }
            let (Some(key), Some(hash)) = (
                hook.get("key").and_then(Value::as_str),
                hook.get("currentHash").and_then(Value::as_str),
            ) else {
                continue;
            };
            edits.push(json!({
                // The key is a path and carries `.` and `"`, so it is a QUOTED TOML key
                // rather than a bare dotted one. Written the way Codex's own client writes
                // it — `hooks.state."<key>"` — because that is where Codex reads it back from.
                "keyPath": format!("hooks.state.{}", toml_quoted_key(key)),
                "mergeStrategy": "upsert",
                "value": {"enabled": true, "trusted_hash": hash},
            }));
        }
    }
    if edits.is_empty() {
        return Ok(());
    }
    let id = conn
        .request("config/batchWrite", json!({"edits": edits}))
        .await?;
    // Written into the per-turn `CODEX_HOME`'s own `config.toml` (the default target), which
    // is the file `assert_no_user_config` expects to find exactly this in and nothing else.
    await_response(conn, ctx, state, id).await?;
    Ok(())
}

/// A TOML basic-string key, for a hook key that is a filesystem path.
///
/// The same escaping [`crate::toml_string`] does, spelled again here rather than shared,
/// because that one is for a `-c key=value` VALUE and this is for a KEY inside a dotted path;
/// a future change to one has no business silently changing the other.
fn toml_quoted_key(key: &str) -> String {
    let mut out = String::with_capacity(key.len() + 2);
    out.push('"');
    for c in key.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    /// A sink that keeps everything it was handed, in order — the client's side of the
    /// mid-turn contract, made inspectable.
    #[derive(Default)]
    struct Recorder {
        text: std::sync::Mutex<String>,
        activity: std::sync::Mutex<Vec<String>>,
        quota: std::sync::Mutex<Vec<(QuotaScopeId, QuotaPatch)>>,
    }

    impl TurnSink for Recorder {
        fn text_delta(&self, delta: &str) {
            self.text.lock_ok().push_str(delta);
        }
        fn tool_activity(&self, activity: ToolActivity) {
            self.activity.lock_ok().push(activity.name);
        }
        fn quota(&self, scope: QuotaScopeId, patch: QuotaPatch) {
            self.quota.lock_ok().push((scope, patch));
        }
    }

    /// One turn's worth of scaffolding: a config, a request, a sink and a state, wired the way
    /// the driver wires them so the tests below exercise the real dispatch.
    struct Fixture {
        cfg: Config,
        model: ActiveModel,
        sink: Recorder,
        sessions: std::sync::Mutex<Vec<String>>,
        state: TurnState,
    }

    impl Fixture {
        fn new() -> Self {
            let mut model = ActiveModel::ambient();
            model.harness = CODEX_ID.to_string();
            Self {
                cfg: test_config(),
                model,
                sink: Recorder::default(),
                sessions: std::sync::Mutex::new(Vec::new()),
                state: TurnState::default(),
            }
        }

        /// Feed one notification through the real dispatch and return its terminal, if any.
        fn on(&mut self, method: &str, params: serde_json::Value) -> Option<ClaudeOutcome> {
            let req = TurnRequest {
                prompt: "hi",
                session_id: None,
                active: &self.model,
                capability: Capability::Read,
                cwd: std::path::PathBuf::from(&self.cfg.vault),
                mcp_config: EMPTY_MCP_CONFIG,
                write_lock: None,
                turn_id: "t1",
                artifact_dir: None,
                attachment_dir: None,
            };
            let on_session = |id: &str| self.sessions.lock_ok().push(id.to_string());
            let ctx = TurnDriveCtx {
                cfg: &self.cfg,
                req: &req,
                sink: &self.sink,
                on_session: &on_session,
            };
            notification(&ctx, &mut self.state, method, &params)
        }

        fn streamed(&self) -> String {
            self.sink.text.lock_ok().clone()
        }
    }

    fn answer_item(id: &str, text: &str) -> serde_json::Value {
        json!({"item": {"type": "agentMessage", "id": id, "text": text, "phase": "final_answer"}})
    }

    /// **THE FEATURE, AS A UNIT.** Deltas of a final-answer item reach the sink as they
    /// arrive, and the completed item is the authoritative text — not a second copy appended
    /// to what already streamed.
    #[test]
    fn deltas_reach_the_client_and_the_completed_item_replaces_them() {
        let mut f = Fixture::new();
        f.on("item/started", answer_item("m1", ""));
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "Hello, "}),
        );
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "world"}),
        );
        assert_eq!(f.streamed(), "Hello, world", "the client saw it arriving");

        f.on("item/completed", answer_item("m1", "Hello, world"));
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "completed"}}),
            )
            .expect("a terminal");
        let ClaudeOutcome::Ok { result, .. } = out else {
            panic!("a completed turn is Ok");
        };
        assert_eq!(
            result, "Hello, world",
            "the answer must be delivered ONCE — a driver that appended the completed item to \
             the accumulated deltas would return it twice"
        );
    }

    /// **A FINAL ITEM THAT DISAGREES WITH THE DELTAS WINS.** A provider that reflows,
    /// redacts or normalises its own message sends a `completed` item that is not the
    /// concatenation of what it streamed, and the completed item is the final state.
    #[test]
    fn a_completed_item_that_differs_from_the_deltas_is_authoritative() {
        let mut f = Fixture::new();
        f.on("item/started", answer_item("m1", ""));
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "the pass"}),
        );
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "word is hunter2"}),
        );
        f.on(
            "item/completed",
            answer_item("m1", "the password is [redacted]"),
        );
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "completed"}}),
            )
            .expect("a terminal");
        let ClaudeOutcome::Ok { result, .. } = out else {
            panic!("Ok");
        };
        assert_eq!(result, "the password is [redacted]");
    }

    /// **COMMENTARY IS NOT THE ANSWER, AND ITS DELTAS ARE NOT SHOWN.** Codex emits a short
    /// preamble as its own agent message before it starts calling tools; the bridge has never
    /// shown it and does not start now. Streaming it would put text on screen that the
    /// terminal answer then replaces.
    #[test]
    fn commentary_never_reaches_the_client_or_the_answer() {
        let mut f = Fixture::new();
        f.on(
            "item/started",
            json!({"item": {"type": "agentMessage", "id": "c1", "text": "", "phase": "commentary"}}),
        );
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "c1", "delta": "I'll look that up."}),
        );
        f.on(
            "item/completed",
            json!({"item": {"type": "agentMessage", "id": "c1", "text": "I'll look that up.", "phase": "commentary"}}),
        );
        assert_eq!(f.streamed(), "", "a preamble is not the visible answer");

        // …and then the real answer, interleaved with a tool call, arrives and IS shown.
        f.on(
            "item/started",
            json!({"item": {"type": "commandExecution", "id": "e1", "command": "ls"}}),
        );
        f.on("item/started", answer_item("m1", ""));
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "42"}),
        );
        f.on("item/completed", answer_item("m1", "42"));
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "completed"}}),
            )
            .expect("a terminal");
        let ClaudeOutcome::Ok { result, .. } = out else {
            panic!("Ok");
        };
        assert_eq!(result, "42");
        assert_eq!(f.streamed(), "42");
        assert_eq!(f.sink.activity.lock_ok().clone(), vec!["Bash".to_string()]);
    }

    /// **A PHASE THE PROTOCOL DID NOT SET IS THE ANSWER.** The schema says so in as many
    /// words — "callers must treat `None` as phase unknown and keep compatibility behavior
    /// for legacy models" — and treating unknown as commentary would make a model that never
    /// sets the field reply with nothing at all.
    #[test]
    fn an_agent_message_with_no_phase_is_treated_as_the_answer() {
        let mut f = Fixture::new();
        f.on(
            "item/started",
            json!({"item": {"type": "agentMessage", "id": "m1", "text": ""}}),
        );
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "legacy"}),
        );
        assert_eq!(f.streamed(), "legacy");
    }

    /// The mid-turn activity feed, in the ONE vocabulary both harnesses share — the contract
    /// at the top of `harness/mod.rs`, pinned against the App Server's item names.
    #[test]
    fn mid_turn_items_map_onto_the_shared_activity_vocabulary() {
        let mut f = Fixture::new();
        f.on(
            "item/started",
            json!({"item": {"type": "commandExecution", "id": "e", "command": "ls"}}),
        );
        f.on(
            "item/started",
            json!({"item": {"type": "fileChange", "id": "f"}}),
        );
        f.on(
            "item/started",
            json!({"item": {"type": "mcpToolCall", "id": "t", "server": "qmd", "tool": "query"}}),
        );
        assert_eq!(
            f.sink.activity.lock_ok().clone(),
            vec!["Bash", "Edit", "mcp__qmd__query"]
        );
        // `item/completed` is the SAME item finishing. Emitting activity again would double
        // every tool call on screen, so only `item/started` counts.
        f.on(
            "item/completed",
            json!({"item": {"type": "commandExecution", "id": "e", "status": "completed"}}),
        );
        assert_eq!(f.sink.activity.lock_ok().len(), 3);
    }

    /// The thread id is reported the MOMENT it is known and exactly once, so a turn that dies
    /// after it has still told the bridge what it owns.
    #[test]
    fn the_thread_is_named_once_however_often_it_is_repeated() {
        let mut f = Fixture::new();
        f.on("thread/started", json!({"thread": {"id": "th_1"}}));
        f.on("thread/started", json!({"thread": {"id": "th_1"}}));
        assert_eq!(f.sessions.lock_ok().clone(), vec!["th_1".to_string()]);
    }

    /// `error` is RETRY NARRATION while the server says it will retry — treating the first
    /// one as terminal abandoned a child that still had attempts left and reported
    /// "Reconnecting… 2/5" as the cause.
    #[test]
    fn a_retrying_error_is_narration_and_the_last_one_is_only_a_fallback_cause() {
        let mut f = Fixture::new();
        for n in 2..=5 {
            assert!(
                f.on(
                    "error",
                    json!({"error": {"message": format!("Reconnecting... {n}/5")}, "willRetry": true}),
                )
                .is_none(),
                "an error the server will retry must not end the turn"
            );
        }
        // A failed turn carrying no message of its own falls back to the last narration.
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "failed"}}),
            )
            .expect("a terminal");
        let ClaudeOutcome::Fatal { message } = out else {
            panic!("a failed turn is Fatal");
        };
        assert_eq!(message, "Reconnecting... 5/5");
    }

    /// **A FAILED TURN IS NOT A SUCCESS CARRYING WHATEVER STREAMED BEFORE IT DIED.** The
    /// partial text stays where it is — in the job's stream accumulator and the trace — which
    /// is what leaves it visibly incomplete instead of dressed up as an answer.
    #[test]
    fn a_failed_turn_never_delivers_the_partial_text_as_the_answer() {
        let mut f = Fixture::new();
        f.on("item/started", answer_item("m1", ""));
        f.on(
            "item/agentMessage/delta",
            json!({"itemId": "m1", "delta": "half an ans"}),
        );
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "failed",
                                "error": {"message": "upstream exploded"}}}),
            )
            .expect("a terminal");
        assert!(
            matches!(out, ClaudeOutcome::Fatal { ref message } if message == "upstream exploded"),
            "{out:?}"
        );
        assert_eq!(f.streamed(), "half an ans", "the client keeps what it saw");
    }

    /// An INTERRUPTED turn is a turn somebody stopped. Nothing in this bridge sends
    /// `turn/interrupt`, so reaching this means the server stopped it — and reporting that as
    /// a clean success would claim an answer nobody finished.
    #[test]
    fn an_interrupted_turn_is_not_reported_as_a_finished_one() {
        let mut f = Fixture::new();
        let out = f
            .on(
                "turn/completed",
                json!({"turn": {"id": "t", "items": [], "status": "interrupted"}}),
            )
            .expect("a terminal");
        assert!(matches!(out, ClaudeOutcome::Fatal { .. }), "{out:?}");
    }

    /// A dead daemon credential is `Fatal` with an operator-facing message, NOT `Retryable` —
    /// there is no interactive `codex login` on a bridge host, so three attempts produce
    /// three identical 401s and a turn that took three times as long to say the same thing.
    /// The classification is shared with the stderr channel through [`codex_failure`].
    #[test]
    fn a_dead_credential_is_fatal_and_names_the_remedy() {
        let out = Stop::Turn("unexpected status 401 Unauthorized: token expired".to_string())
            .into_outcome();
        let ClaudeOutcome::Fatal { message } = out else {
            panic!("401 must be Fatal, not Retryable");
        };
        assert!(message.contains(CODEX_ID), "names the harness: {message}");
        assert!(message.contains("re-authenticate"), "{message}");
        assert!(
            message.contains("other harnesses are unaffected"),
            "{message}"
        );
    }

    /// An ordinary upstream failure keeps its own message: the auth arm must not swallow
    /// everything that failed.
    #[test]
    fn an_ordinary_failure_is_not_dressed_up_as_an_auth_failure() {
        let ClaudeOutcome::Fatal { message } =
            Stop::Turn("model overloaded".to_string()).into_outcome()
        else {
            panic!("Fatal");
        };
        assert_eq!(message, "model overloaded");
    }

    /// **EVERY APPROVAL IS DENIED AND EVERY REQUEST IS ANSWERED.** The approval prompt is the
    /// escalation route AROUND the sandbox: a client that auto-approves has turned "the
    /// boundary says no" into "the boundary asks, and the bridge says yes". And an
    /// unrecognised request answers with a refusal rather than an empty object, so a request
    /// kind this bridge has never seen cannot come to mean "granted" by default.
    #[test]
    fn no_server_request_is_ever_granted() {
        let cfg = test_config();
        let mut model = ActiveModel::ambient();
        model.harness = CODEX_ID.to_string();
        let req = TurnRequest {
            prompt: "hi",
            session_id: None,
            active: &model,
            capability: Capability::Read,
            cwd: std::path::PathBuf::from(&cfg.vault),
            mcp_config: EMPTY_MCP_CONFIG,
            write_lock: None,
            turn_id: "t1",
            artifact_dir: None,
            attachment_dir: None,
        };
        let _ = (&cfg, &req);
        for method in [
            "execCommandApproval",
            "applyPatchApproval",
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
        ] {
            let r = answer_server_request(method, &Value::Null);
            assert_eq!(
                r.get("decision").and_then(Value::as_str),
                Some("denied"),
                "{method} was not denied: {r}"
            );
        }
        assert_eq!(
            answer_server_request("mcpServer/elicitation/request", &Value::Null)
                .get("action")
                .and_then(Value::as_str),
            Some("decline")
        );
        // The default arm: a refusal, never an empty success.
        let unknown = answer_server_request("someFutureApproval", &Value::Null);
        assert!(
            unknown.get("error").is_some(),
            "an unrecognised server request must not be answered with a grant: {unknown}"
        );
        // And the refusal for `account/chatgptAuthTokens/refresh`, which is not an approval
        // but is refused for its own reason: the credential in the per-turn home holds the
        // refresh flow, not this bridge.
        assert!(
            answer_server_request("account/chatgptAuthTokens/refresh", &Value::Null)
                .get("error")
                .is_some()
        );
    }

    /// The usage mapping's ONE correction, pinned: Codex reports `inputTokens` as the TOTAL
    /// prompt with `cachedInputTokens` a SUBSET of it, while `ShadowUsage::cost` adds the
    /// two. Passing the numbers through unchanged bills every cached token twice.
    #[test]
    fn cached_tokens_are_subtracted_out_of_the_input_count() {
        let u = app_server_usage(&json!({
            "inputTokens": 16093,
            "cachedInputTokens": 12160,
            "cacheWriteInputTokens": 0,
            "outputTokens": 25,
            "reasoningOutputTokens": 8
        }));
        assert_eq!(u.input_tokens, Some(3933));
        assert_eq!(u.cache_read_input_tokens, Some(12160));
        assert_eq!(
            u.output_tokens,
            Some(33),
            "reasoning is billed at the output rate"
        );
        // A future version that reports the counts the other way round must underflow to
        // zero rather than wrap to an astronomical bill.
        let flipped = app_server_usage(&json!({"inputTokens": 1, "cachedInputTokens": 9}));
        assert_eq!(flipped.input_tokens, Some(0));
    }

    /// A notification for a turn this driver did not start is ignored. One child serves one
    /// turn today, so it cannot fire — but a future that reuses a child must not deliver
    /// another turn's answer.
    #[test]
    fn a_notification_from_another_turn_is_ignored() {
        let mut f = Fixture::new();
        f.state.turn_id = Some("mine".to_string());
        assert!(f
            .on(
                "turn/completed",
                json!({"turn": {"id": "someone-elses", "items": [], "status": "completed"}}),
            )
            .is_none());
    }

    /// `account/rateLimits/updated` reaches the sink as a SPARSE patch for the ChatGPT scope —
    /// primary present, secondary null and therefore absent rather than zeroed — and ends
    /// nothing. A model on its own provider key reports nothing: it does not spend that
    /// account.
    #[test]
    fn a_rate_limits_notification_reaches_the_sink_as_a_chatgpt_patch() {
        let params = json!({"rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1789224359},
            "secondary": null,
            "planType": "pro"
        }});
        let mut f = Fixture::new();
        assert!(
            f.on("account/rateLimits/updated", params.clone()).is_none(),
            "not a terminal"
        );
        let got = f.sink.quota.lock_ok().clone();
        assert_eq!(got.len(), 1);
        let (scope, patch) = &got[0];
        assert_eq!(*scope, QuotaScopeId::CodexChatgpt);
        assert_eq!(patch.plan.as_deref(), Some("pro"));
        assert_eq!(
            patch.windows.len(),
            1,
            "a null secondary is absent, not a zero"
        );
        assert_eq!(patch.windows[0].id, "primary");
        assert_eq!(patch.windows[0].label.as_deref(), Some("5 hours"));
        assert_eq!(patch.windows[0].used_percent, Some(42.0));
        assert_eq!(patch.windows[0].resets_at_ms, Some(1_789_224_359_000));

        let mut provider = Fixture::new();
        provider.model.kind = ModelKind::OpenAi;
        provider.on("account/rateLimits/updated", params);
        assert!(provider.sink.quota.lock_ok().is_empty());
    }
}
