//! `jesse-inbound-mcp` — the bridge's inbound-document capability, spoken as MCP over stdio.
//!
//! # Why a binary rather than a route on the bridge's HTTP server
//!
//! The logic lives in [`jesse_bridge::inbound`] — this file is a transport and nothing else,
//! for exactly the reason `jesse-places-mcp` and `jesse-build-mcp` are: the containment
//! record commits the `--mcp-config` argv VERBATIM and compares it by strict equality at
//! boot, so an HTTP entry would have to name a host and port, which differs per deployment.
//! A `"command": "jesse-inbound-mcp"` entry is a BARE NAME resolved from the child's `PATH`,
//! exactly like `qmd` and the rest, and reads identically everywhere.
//!
//! # Why the FETCHING lives here and not in the child's own allowlist
//!
//! The child's MCP servers already advertise two attachment-download tools
//! (`mcp__whatsapp__download_media`, `mcp__google__get_gmail_attachment_content`) and both
//! are deliberately UNGRANTED, because both write fetched bytes to a path of their own
//! choosing on a host where the same child holds a vault write grant. A test fails the build
//! if the first ever appears in a granted set.
//!
//! This server is how that decision survives contact with the feature. It performs the same
//! downloads — the WhatsApp one through the very REST endpoint `download_media` itself calls
//! — and can write to exactly one directory, the staging directory under the workspace. What
//! the child gains is a path it may READ. What it does not gain is anywhere to put bytes.
//!
//! # It reads no credential of its own
//!
//! `JMAP_TOKEN`, `JMAP_SESSION_URL` and `WORKSPACE_MCP_CREDENTIALS_DIR` are already in the
//! bridge's process environment, put there by `export_mcp_server_env` for the Fastmail and
//! Google servers, and this process inherits them like every other MCP child. No new secret,
//! no new store, nothing added to the plist.

use jesse_bridge::{
    attachment_support_for, resolve_vision_config, run_inbound_tool, InboundClient, InboundConfig,
    InboundTool, CLAUDE_CODE_ID,
};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// The MCP protocol version this server falls back to when a client does not name one.
/// When the client DOES name one it is echoed back, which is what the spec asks for and what
/// keeps this working across the versions the harnesses speak.
const FALLBACK_PROTOCOL_VERSION: &str = "2024-11-05";

#[tokio::main]
async fn main() {
    let client = match InboundClient::new(InboundConfig::from_env()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("jesse-inbound-mcp: {e}");
            std::process::exit(1);
        }
    };
    let vision = resolve_vision_config();
    // WHICH HARNESS'S `Read` A STAGED FILE IS PREPARED FOR. This server ships in Claude
    // Code's MCP set only, so that is the default; the variable exists so a deployment that
    // ever loads it elsewhere converts correctly rather than handing a Codex child a PDF its
    // `view_image` cannot open.
    let harness_id =
        std::env::var("JESSE_INBOUND_HARNESS").unwrap_or_else(|_| CLAUDE_CODE_ID.to_string());
    let support = attachment_support_for(&harness_id);

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
                            "name": "jesse-inbound-mcp",
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
                match InboundTool::parse(name) {
                    Some(tool) => {
                        match run_inbound_tool(&client, &vision, support, tool, &args).await {
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
                            // A FAILURE IS REPORTED AS A FAILURE, and this is the one that
                            // matters most on this server. An empty or vague result here
                            // reads to a turn as "there was nothing to read", and the model
                            // then answers from the surrounding message text as though it
                            // had opened the document. Every error string this returns names
                            // the channel, what failed, and says plainly that nothing was
                            // read.
                            Err(e) => ok(
                                id,
                                json!({
                                    "content": [{"type": "text", "text": e}],
                                    "isError": true,
                                }),
                            ),
                        }
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

/// The advertised tools, built from [`InboundTool::ALL`] so a new one cannot be added to the
/// enum without appearing here.
fn tool_list() -> Vec<Value> {
    InboundTool::ALL
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
