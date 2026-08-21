//! `jesse-build-mcp` — the bridge's build capability, spoken as MCP over stdio.
//!
//! # Why a binary rather than a route on the bridge's HTTP server
//!
//! The logic lives in [`jesse_bridge::buildsvc`] — this file is a transport and nothing else.
//! It is a separate stdio binary because that is the shape every other server in the set
//! already has, and because the alternative pins the posture to one machine: the containment
//! record commits the `--mcp-config` argv VERBATIM and compares it by strict equality at boot,
//! so an HTTP entry would have to name a host and port, which differs per deployment. A
//! `"command": "jesse-build-mcp"` entry is a BARE NAME resolved from the child's `PATH`,
//! exactly like `qmd`, `whatsapp-mcp` and the rest, and reads identically everywhere.
//!
//! # The one property that matters
//!
//! **Every tool advertises an EMPTY argument object and this server ignores `arguments`
//! entirely.** There is no path, no scheme, no configuration and no free tail for a caller to
//! reach — the difference between this and the `Bash(cargo:*)` grant it replaces is not that
//! the string is narrower, but that there is no string. `tools/call` dispatches a NAME onto a
//! closed enum; anything that is not one of those names is an error, never a command.

use jesse_bridge::{run_build_op, BuildOp, Config};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// The MCP protocol version this server falls back to when a client does not name one.
/// When the client DOES name one it is echoed back, which is what the spec asks for and what
/// keeps this working across the versions the two harnesses speak.
const FALLBACK_PROTOCOL_VERSION: &str = "2024-11-05";

#[tokio::main]
async fn main() {
    let cfg = Config::from_env();
    let vault = cfg.vault.clone();
    let home = cfg.home.clone();

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    let mut stdout = tokio::io::stdout();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let req: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            // A malformed line is not fatal: answering with a parse error and staying up is
            // strictly better than dropping the connection and taking the capability out for
            // the rest of the turn.
            Err(e) => {
                let err = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": {"code": -32700, "message": format!("parse error: {e}")}
                });
                let _ = write_line(&mut stdout, &err).await;
                continue;
            }
        };

        let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let id = req.get("id").cloned();

        // A NOTIFICATION (no `id`) must never be answered. Replying to one is a protocol
        // violation that some clients treat as a fatal desync rather than ignoring.
        let Some(id) = id else {
            continue;
        };

        let response = match method {
            "initialize" => {
                let version = req
                    .get("params")
                    .and_then(|p| p.get("protocolVersion"))
                    .and_then(|v| v.as_str())
                    .unwrap_or(FALLBACK_PROTOCOL_VERSION)
                    .to_string();
                ok(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": {"tools": {}},
                        "serverInfo": {
                            "name": "jesse-build-mcp",
                            "version": env!("CARGO_PKG_VERSION"),
                        }
                    }),
                )
            }
            "ping" => ok(id, json!({})),
            "tools/list" => ok(id, json!({"tools": tool_list()})),
            "tools/call" => {
                let name = req
                    .get("params")
                    .and_then(|p| p.get("name"))
                    .and_then(|n| n.as_str())
                    .unwrap_or("");
                match BuildOp::parse(name) {
                    Some(op) => {
                        // NOTE what is NOT read here: `params.arguments`. The tools take no
                        // arguments, so nothing a caller sends can influence the command line.
                        let outcome = run_build_op(op, &vault, &home).await;
                        ok(
                            id,
                            json!({
                                "content": [{"type": "text", "text": outcome.render()}],
                                "isError": !outcome.passed,
                            }),
                        )
                    }
                    None => err(id, -32602, format!("unknown tool: {name}")),
                }
            }
            other => err(id, -32601, format!("unknown method: {other}")),
        };

        if write_line(&mut stdout, &response).await.is_err() {
            break; // the client is gone
        }
    }
}

/// The advertised tools.
///
/// `inputSchema` is an object with NO properties and `additionalProperties: false` — the
/// machine-readable statement of the property this whole design rests on. It is built from
/// [`BuildOp::ALL`], so a new operation cannot be added without appearing here.
fn tool_list() -> Vec<Value> {
    BuildOp::ALL
        .into_iter()
        .map(|op| {
            json!({
                "name": op.tool_name(),
                "description": op.description(),
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false,
                },
            })
        })
        .collect()
}

fn ok(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn err(id: Value, code: i64, message: String) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

async fn write_line<W>(w: &mut W, v: &Value) -> std::io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    let mut s = serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string());
    s.push('\n');
    w.write_all(s.as_bytes()).await?;
    w.flush().await
}
