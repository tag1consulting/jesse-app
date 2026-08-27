//! `jesse-places-mcp` — the bridge's places capability, spoken as MCP over stdio.
//!
//! # Why a binary rather than a route on the bridge's HTTP server
//!
//! The logic lives in [`jesse_bridge::places`] — this file is a transport and nothing else,
//! for exactly the reason `jesse-build-mcp` is: the containment record commits the
//! `--mcp-config` argv VERBATIM and compares it by strict equality at boot, so an HTTP entry
//! would have to name a host and port, which differs per deployment. A
//! `"command": "jesse-places-mcp"` entry is a BARE NAME resolved from the child's `PATH`,
//! exactly like `qmd`, `whatsapp-mcp` and the rest, and reads identically everywhere.
//!
//! # How this differs from `jesse-build-mcp`, deliberately
//!
//! That server's whole design is that its tools take an EMPTY argument object, because it runs
//! code and there must be no string to narrow. These tools DO take arguments — a query, a
//! coordinate, a radius — and could not do their job otherwise.
//!
//! What replaces "no arguments" as the safety property here is that **no argument reaches a
//! remote service as text**. The free-text query is resolved against a closed compile-time
//! category table and then used to filter the response on this side; the only caller-supplied
//! string that leaves the host is a place id, and it leaves only after being validated as
//! `^(node|way|relation)/[0-9]+$`. See the module docs in `places.rs` for why that matters in
//! a child that also reads attacker-authored message bodies.

use jesse_bridge::{run_places_tool, PlacesClient, PlacesConfig, PlacesTool};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// The MCP protocol version this server falls back to when a client does not name one.
/// When the client DOES name one it is echoed back, which is what the spec asks for and what
/// keeps this working across the versions the two harnesses speak.
const FALLBACK_PROTOCOL_VERSION: &str = "2024-11-05";

#[tokio::main]
async fn main() {
    let client = match PlacesClient::new(PlacesConfig::from_env()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("jesse-places-mcp: {e}");
            std::process::exit(1);
        }
    };

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
                            "name": "jesse-places-mcp",
                            "version": env!("CARGO_PKG_VERSION"),
                        }
                    }),
                )
            }
            "ping" => ok(id, json!({})),
            "tools/list" => ok(id, json!({"tools": tool_list()})),
            "tools/call" => {
                let params = req.get("params");
                let name = params
                    .and_then(|p| p.get("name"))
                    .and_then(|n| n.as_str())
                    .unwrap_or("");
                let args = params
                    .and_then(|p| p.get("arguments"))
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                match PlacesTool::parse(name) {
                    Some(tool) => match run_places_tool(&client, tool, &args).await {
                        Ok(v) => ok(
                            id,
                            json!({
                                "content": [{
                                    "type": "text",
                                    "text": serde_json::to_string_pretty(&v)
                                        .unwrap_or_else(|_| v.to_string()),
                                }],
                                "isError": false,
                            }),
                        ),
                        // A FAILURE IS REPORTED AS A FAILURE. The alternative — returning an
                        // empty result set when the backend is down or rate-limiting — reads
                        // to a turn as "there is nothing near you", which is a wrong answer
                        // rather than a missing one.
                        Err(e) => ok(
                            id,
                            json!({
                                "content": [{"type": "text", "text": e}],
                                "isError": true,
                            }),
                        ),
                    },
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

/// The advertised tools, built from [`PlacesTool::ALL`] so a new one cannot be added to the
/// enum without appearing here.
fn tool_list() -> Vec<Value> {
    PlacesTool::ALL
        .into_iter()
        .map(|t| {
            json!({
                "name": t.tool_name(),
                "description": t.description(),
                "inputSchema": t.input_schema(),
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
