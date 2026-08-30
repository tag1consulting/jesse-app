//! **The provider conformance suite.**
//!
//! ONE TABLE, ALL THREE ADAPTERS, THROUGH `&dyn Provider`. Every case in [`cases`] is run
//! against the Anthropic Messages adapter, the OpenAI Chat adapter and the OpenAI
//! Responses adapter, and the shared expectation — the event sequence, the error class,
//! the usage arithmetic — is asserted identically on all three. That structure is the
//! point of the file, not a convenience: a per-adapter test file lets a behaviour drift
//! between wires and calls it "the OpenAI one works differently", which is exactly the
//! divergence the neutral layer exists to prevent. Here a divergence is a failing row.
//!
//! **THE THIRD WIRE IS THE FALSIFICATION.** Two adapters written together can agree with
//! each other by construction. The Responses adapter was written after the trait had
//! settled, against a wire with a different shape — stateful by default, carrying items
//! rather than messages, reporting a status rather than a finish reason — and every case
//! below was made to pass on it with NO change to the trait's request or event types
//! except one (`Usage::reasoning_tokens`). What that cost, and what was refused, is in
//! `agent/LEAKS.md`.
//!
//! Wire-SPECIFIC expectations have one home: `expect_body`, which receives the wire and
//! the exact JSON the mock received. So "cacheable produces `cache_control` on Messages
//! and nothing on the two OpenAI wires" is one row asserting all three halves, rather than
//! three tests that could each be deleted without the others noticing.
//!
//! NO NETWORK. Each case binds a real loopback socket and speaks HTTP/1.1 by hand — the
//! same approach `bridge/tests/integration.rs` takes for its mock `/v1/messages` helper,
//! and for the same reason: `reqwest` needs a URL, and a real socket exercises the whole
//! path (headers, chunked delivery, connection close) that an injected fake would skip.
//!
//! The mock is hand-rolled rather than `axum`-based because three of these cases need
//! control an HTTP framework deliberately hides: delivering one SSE frame across three
//! writes, holding a response open forever, and OBSERVING that the client closed the
//! connection.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jesse_agent::provider::{
    build_provider, AuthScheme, ContentBlock, Event, Message, Provider, ProviderConfig,
    ProviderError, Quirks, Request, Role, Sampling, StopReason, SystemBlock, Thinking, ToolSpec,
    Wire,
};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_util::sync::CancellationToken;

// ===========================================================================
// The mock server
// ===========================================================================

/// One scripted HTTP response.
#[derive(Clone)]
struct Reply {
    status: u16,
    headers: Vec<(String, String)>,
    /// The body, delivered as a sequence of writes. Several chunks prove the framer
    /// reassembles across TCP boundaries.
    chunks: Vec<String>,
    /// Write the chunks, then hold the connection open forever instead of closing it.
    /// The cancellation case needs a stream that will not end on its own.
    hold_open: bool,
}

impl Reply {
    /// A `200` SSE response delivered in one write.
    fn sse(body: impl Into<String>) -> Self {
        Reply {
            status: 200,
            headers: vec![("content-type".into(), "text/event-stream".into())],
            chunks: vec![body.into()],
            hold_open: false,
        }
    }

    /// A `200` SSE response delivered as several writes.
    fn sse_chunks(chunks: Vec<String>) -> Self {
        Reply {
            status: 200,
            headers: vec![("content-type".into(), "text/event-stream".into())],
            chunks,
            hold_open: false,
        }
    }

    /// A non-200 with a short JSON body.
    fn status(status: u16, body: impl Into<String>) -> Self {
        Reply {
            status,
            headers: vec![("content-type".into(), "application/json".into())],
            chunks: vec![body.into()],
            hold_open: false,
        }
    }

    fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    fn holding_open(mut self) -> Self {
        self.hold_open = true;
        self
    }
}

/// What the mock saw.
#[derive(Debug, Clone)]
struct Recorded {
    path: String,
    headers: HashMap<String, String>,
    body: Value,
}

struct Mock {
    base_url: String,
    seen: Arc<Mutex<Vec<Recorded>>>,
    /// Set once a held-open connection observed the client hanging up. This is how the
    /// cancellation case proves the socket actually closed rather than merely that the
    /// caller stopped reading.
    client_closed: Arc<AtomicBool>,
}

impl Mock {
    /// Serve `replies` in order, one per connection.
    ///
    /// ONE REQUEST PER CONNECTION, and every response carries `Connection: close`. That is
    /// what makes the retry case observable: a retried attempt arrives as a NEW
    /// connection, so counting connections counts attempts. It also lets an SSE body be
    /// framed by end-of-stream, with no chunked-transfer encoder to write by hand.
    async fn start(replies: Vec<Reply>) -> Mock {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client_closed = Arc::new(AtomicBool::new(false));

        let seen_task = seen.clone();
        let closed_task = client_closed.clone();
        tokio::spawn(async move {
            let mut replies = replies.into_iter();
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                // The LAST scripted reply is reused if more connections arrive than were
                // scripted, so an unexpected extra attempt shows up as an assertion
                // failure on the recorded request count rather than as a hang.
                let reply = replies.next();
                let seen = seen_task.clone();
                let closed = closed_task.clone();
                tokio::spawn(async move {
                    let _ = serve_one(stream, reply, seen, closed).await;
                });
            }
        });

        Mock {
            base_url: format!("http://{addr}"),
            seen,
            client_closed,
        }
    }

    fn requests(&self) -> Vec<Recorded> {
        self.seen.lock().unwrap().clone()
    }
}

/// Read one request, record it, write the scripted reply.
async fn serve_one(
    mut stream: TcpStream,
    reply: Option<Reply>,
    seen: Arc<Mutex<Vec<Recorded>>>,
    client_closed: Arc<AtomicBool>,
) -> std::io::Result<()> {
    // ---- Read the head -----------------------------------------------------
    let mut buf = Vec::new();
    let head_end = loop {
        let mut b = [0u8; 4096];
        let n = stream.read(&mut b).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&b[..n]);
        if let Some(p) = find_subslice(&buf, b"\r\n\r\n") {
            break p + 4;
        }
    };

    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_string();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    // ---- Read the body -----------------------------------------------------
    let len: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut body = buf[head_end..].to_vec();
    while body.len() < len {
        let mut b = [0u8; 4096];
        let n = stream.read(&mut b).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&b[..n]);
    }
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);

    seen.lock().unwrap().push(Recorded {
        path,
        headers,
        body,
    });

    // ---- Write the reply ---------------------------------------------------
    let Some(reply) = reply else {
        stream
            .write_all(b"HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
            .await?;
        return Ok(());
    };

    let mut head = format!("HTTP/1.1 {} X\r\nconnection: close\r\n", reply.status);
    for (k, v) in &reply.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    // No `content-length` and no chunked encoding: the body is delimited by the close,
    // which `connection: close` makes legal and which is how a real SSE stream ends.
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    for chunk in &reply.chunks {
        stream.write_all(chunk.as_bytes()).await?;
        stream.flush().await?;
        // A beat between writes so the client genuinely sees separate reads — otherwise
        // the kernel coalesces them and the "arrives in three fragments" case proves
        // nothing about the framer.
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    if reply.hold_open {
        // Block on the socket until the peer goes away, then record that it did.
        let mut b = [0u8; 1024];
        loop {
            match stream.read(&mut b).await {
                Ok(0) | Err(_) => {
                    client_closed.store(true, Ordering::SeqCst);
                    return Ok(());
                }
                Ok(_) => continue,
            }
        }
    }
    Ok(())
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ===========================================================================
// SSE fixture helpers
// ===========================================================================

/// Frame one JSON payload as an SSE event.
fn frame(payload: &str) -> String {
    format!("data: {payload}\n\n")
}

/// Frame a list of payloads.
fn frames(payloads: &[&str]) -> String {
    payloads.iter().map(|p| frame(p)).collect()
}

/// Frame a list of payloads the way the **Responses** wire frames them: an `event:` line
/// naming the type, then the `data:` line whose JSON repeats it.
///
/// The name is read out of the payload's own `type` rather than passed in, so a fixture
/// cannot drift into an envelope that disagrees with its content — and so this helper
/// exercises the thing worth exercising, which is that `http::SseFramer` READS PAST the
/// `event:` line. That is the framer's stated design (one framer for a wire that sends an
/// event name, a wire that sends none, and now a wire that sends one for every frame), and
/// until this adapter existed only one half of it was covered by a fixture.
fn typed_frames(payloads: &[&str]) -> String {
    payloads
        .iter()
        .map(|p| {
            let kind: Value = serde_json::from_str(p).expect("fixture is JSON");
            let kind = kind
                .get("type")
                .and_then(Value::as_str)
                .expect("every Responses frame names its type");
            format!("event: {kind}\ndata: {p}\n\n")
        })
        .collect()
}

/// One Responses frame, as its own write.
fn typed_frame(payload: &str) -> String {
    typed_frames(&[payload])
}

// ===========================================================================
// The case table
// ===========================================================================

/// What a case expects the mock to serve on each wire.
struct Script {
    messages: Vec<Reply>,
    chat: Vec<Reply>,
    responses: Vec<Reply>,
}

struct Case {
    name: &'static str,
    /// The quirks the provider is built with, on both wires.
    quirks: Quirks,
    request: fn() -> Request,
    script: fn() -> Script,
    /// Asserted identically for both adapters.
    expect_events: fn(&str, Wire, &[Event]),
    /// Asserted on the exact body the mock received, per wire.
    expect_body: fn(&str, Wire, &Value),
    /// Asserted on everything the mock recorded, per wire (attempt counts, headers).
    expect_requests: fn(&str, Wire, &[Recorded]),
    /// Cancel the call after this long, if set.
    cancel_after: Option<Duration>,
}

/// The default per-case hooks, so a case only spells out what it cares about.
fn no_body_check(_: &str, _: Wire, _: &Value) {}
fn no_request_check(_: &str, _: Wire, _: &[Recorded]) {}

fn base_request() -> Request {
    Request {
        messages: vec![Message::user("hello")],
        sampling: Sampling {
            max_output_tokens: 256,
            ..Default::default()
        },
        request_tag: "conformance".into(),
        ..Default::default()
    }
}

/// Every event a case asserts on, with the terminal one last.
fn text_of(events: &[Event]) -> String {
    events
        .iter()
        .filter_map(|e| match e {
            Event::TextDelta(t) => Some(t.as_str()),
            _ => None,
        })
        .collect()
}

fn usage_of(events: &[Event]) -> Option<jesse_agent::Usage> {
    events.iter().find_map(|e| match e {
        Event::Usage(u) => Some(u.clone()),
        _ => None,
    })
}

fn terminal_error(events: &[Event]) -> Option<ProviderError> {
    match events.last() {
        Some(Event::Error(e)) => Some(e.clone()),
        _ => None,
    }
}

fn cases() -> Vec<Case> {
    vec![
        // ---- 1. A plain text answer ------------------------------------------------
        Case {
            name: "plain text answer",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":9,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello, "}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world."}}"#,
                    r#"{"type":"content_block_stop","index":0}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
                    r#"{"type":"message_stop"}"#,
                ]))],
                chat: vec![Reply::sse(
                    frames(&[
                        r#"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello, "}}]}"#,
                        r#"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"world."}}]}"#,
                        r#"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                        r#"{"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":4}}"#,
                    ]) + "data: [DONE]\n\n",
                )],
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress"}}"#,
                    r#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}"#,
                    r#"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello, "}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"world."}"#,
                    r#"{"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Hello, world."}]}}"#,
                    r#"{"type":"response.completed","sequence_number":6,"response":{"id":"resp_1","status":"completed","usage":{"input_tokens":9,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":4,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":13}}}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                assert_eq!(text_of(events), "Hello, world.", "{name} on {wire}");
                assert!(
                    matches!(
                        events.last(),
                        Some(Event::Done {
                            stop_reason: StopReason::EndTurn
                        })
                    ),
                    "{name} on {wire}: expected Done/EndTurn, got {:?}",
                    events.last()
                );
                let u = usage_of(events).unwrap_or_else(|| panic!("{name} on {wire}: no usage"));
                assert_eq!(u.input_tokens, Some(9), "{name} on {wire}");
                assert_eq!(u.output_tokens, Some(4), "{name} on {wire}");
                assert!(
                    u.provider_request_id.is_some(),
                    "{name} on {wire}: the provider's request id is captured"
                );
            },
            expect_body: |name, wire, body| {
                // Streaming is requested on both wires, always.
                assert_eq!(body.get("stream"), Some(&json!(true)), "{name} on {wire}");
                assert_eq!(
                    body.get("model"),
                    Some(&json!("test-model")),
                    "{name} on {wire}"
                );
                match wire {
                    Wire::Messages => {
                        assert_eq!(body.get("max_tokens"), Some(&json!(256)));
                        assert_eq!(
                            body.pointer("/messages/0/content/0/text"),
                            Some(&json!("hello"))
                        );
                    }
                    Wire::Chat => {
                        assert_eq!(body.get("max_completion_tokens"), Some(&json!(256)));
                        // Usage is opt-in on this wire and must always be asked for.
                        assert_eq!(
                            body.pointer("/stream_options/include_usage"),
                            Some(&json!(true))
                        );
                    }
                    Wire::Responses => {
                        assert_eq!(body.get("max_output_tokens"), Some(&json!(256)));
                        // A third field name for the same neutral cap, which is most of
                        // why the cap is neutral. Usage needs no opt-in here.
                        assert!(body.get("stream_options").is_none());
                        assert_eq!(
                            body.pointer("/input/0/content/0/text"),
                            Some(&json!("hello"))
                        );
                        assert_eq!(
                            body.pointer("/input/0/content/0/type"),
                            Some(&json!("input_text"))
                        );
                    }
                }
            },
            expect_requests: |name, wire, reqs| {
                assert_eq!(reqs.len(), 1, "{name} on {wire}: exactly one attempt");
                let path = match wire {
                    Wire::Messages => "/v1/messages",
                    Wire::Chat => "/chat/completions",
                    Wire::Responses => "/responses",
                };
                assert_eq!(reqs[0].path, path, "{name} on {wire}");
                // The bearer is sent, and the mock is the only place it is ever visible.
                assert!(
                    reqs[0].headers.contains_key("authorization"),
                    "{name} on {wire}: auth header present"
                );
                if wire == Wire::Messages {
                    assert_eq!(
                        reqs[0].headers.get("anthropic-version").map(String::as_str),
                        Some("2023-06-01"),
                        "{name}: the pinned API version, same as the bridge sends"
                    );
                }
            },
            cancel_after: None,
        },
        // ---- 2. One tool call, arguments in three fragments -------------------------
        Case {
            name: "one tool call in three fragments",
            quirks: Quirks::default(),
            request: || Request {
                tools: vec![ToolSpec {
                    name: "add".into(),
                    description: "add two numbers".into(),
                    input_schema: json!({"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}),
                    strict: false,
                }],
                ..base_request()
            },
            script: || Script {
                messages: vec![Reply::sse_chunks(vec![
                    frame(
                        r#"{"type":"message_start","message":{"id":"msg_2","usage":{"input_tokens":20,"output_tokens":0}}}"#,
                    ),
                    frame(
                        r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"add"}}"#,
                    ),
                    frame(
                        r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#,
                    ),
                    frame(
                        r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"2,\"b\":"}}"#,
                    ),
                    frame(
                        r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"2}"}}"#,
                    ),
                    frame(r#"{"type":"content_block_stop","index":0}"#),
                    frame(
                        r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#,
                    ),
                    frame(r#"{"type":"message_stop"}"#),
                ])],
                chat: vec![Reply::sse_chunks(vec![
                    frame(
                        r#"{"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"add","arguments":"{\"a\":"}}]}}]}"#,
                    ),
                    frame(
                        r#"{"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"2,\"b\":"}}]}}]}"#,
                    ),
                    frame(
                        r#"{"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"2}"}}]}}]}"#,
                    ),
                    frame(
                        r#"{"id":"chatcmpl-2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                    ),
                    frame(
                        r#"{"id":"chatcmpl-2","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":12}}"#,
                    ),
                    "data: [DONE]\n\n".to_string(),
                ])],
                // Delivered as separate writes for the same reason the other two are: the
                // "arrives in three fragments" property is about the framer reassembling
                // across TCP boundaries, and one write proves nothing about it.
                responses: vec![Reply::sse_chunks(vec![
                    typed_frame(
                        r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_2","status":"in_progress"}}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":""}}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"fc_1","output_index":0,"delta":"{\"a\":"}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.function_call_arguments.delta","sequence_number":3,"item_id":"fc_1","output_index":0,"delta":"2,\"b\":"}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.function_call_arguments.delta","sequence_number":4,"item_id":"fc_1","output_index":0,"delta":"2}"}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.function_call_arguments.done","sequence_number":5,"item_id":"fc_1","output_index":0,"arguments":"{\"a\":2,\"b\":2}"}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":"{\"a\":2,\"b\":2}"}}"#,
                    ),
                    typed_frame(
                        r#"{"type":"response.completed","sequence_number":7,"response":{"id":"resp_2","status":"completed","usage":{"input_tokens":20,"output_tokens":12}}}"#,
                    ),
                ])],
            },
            expect_events: |name, wire, events| {
                let starts: Vec<&Event> = events
                    .iter()
                    .filter(|e| matches!(e, Event::ToolUseStart { .. }))
                    .collect();
                assert_eq!(starts.len(), 1, "{name} on {wire}: one tool call");
                let (id, tool_name) = match starts[0] {
                    Event::ToolUseStart { id, name } => (id.clone(), name.clone()),
                    _ => unreachable!(),
                };
                assert_eq!(tool_name, "add", "{name} on {wire}");

                let frags: Vec<String> = events
                    .iter()
                    .filter_map(|e| match e {
                        Event::ToolUseArgsDelta {
                            id: fid,
                            json_fragment,
                        } => {
                            assert_eq!(*fid, id, "{name} on {wire}: fragments carry the call id");
                            Some(json_fragment.clone())
                        }
                        _ => None,
                    })
                    .collect();
                assert_eq!(
                    frags.len(),
                    3,
                    "{name} on {wire}: three fragments as framed"
                );
                // Individually unparseable, jointly valid — the contract the docs state.
                assert!(serde_json::from_str::<Value>(&frags[0]).is_err());
                assert_eq!(
                    serde_json::from_str::<Value>(&frags.concat()).unwrap(),
                    json!({"a": 2, "b": 2}),
                    "{name} on {wire}"
                );
                assert!(
                    events
                        .iter()
                        .any(|e| matches!(e, Event::ToolUseEnd { id: eid } if *eid == id)),
                    "{name} on {wire}: the block closed"
                );
                assert!(
                    matches!(
                        events.last(),
                        Some(Event::Done {
                            stop_reason: StopReason::ToolUse
                        })
                    ),
                    "{name} on {wire}: stop reason is ToolUse, got {:?}",
                    events.last()
                );
            },
            expect_body: |name, wire, body| match wire {
                Wire::Messages => {
                    assert_eq!(body.pointer("/tools/0/name"), Some(&json!("add")), "{name}");
                    assert!(body.pointer("/tools/0/input_schema").is_some(), "{name}");
                }
                Wire::Chat => {
                    assert_eq!(
                        body.pointer("/tools/0/type"),
                        Some(&json!("function")),
                        "{name}"
                    );
                    assert_eq!(
                        body.pointer("/tools/0/function/name"),
                        Some(&json!("add")),
                        "{name}"
                    );
                    assert!(
                        body.pointer("/tools/0/function/parameters").is_some(),
                        "{name}"
                    );
                }
                Wire::Responses => {
                    // FLAT, not nested under a `function` object — the same three fields
                    // in a different arrangement, which is the whole reason the neutral
                    // `ToolSpec` exists.
                    assert_eq!(
                        body.pointer("/tools/0/type"),
                        Some(&json!("function")),
                        "{name}"
                    );
                    assert_eq!(body.pointer("/tools/0/name"), Some(&json!("add")), "{name}");
                    assert!(body.pointer("/tools/0/parameters").is_some(), "{name}");
                    assert!(
                        body.pointer("/tools/0/function").is_none(),
                        "{name}: no `function` wrapper on this wire"
                    );
                    // `strict` is REQUIRED by this wire's tool schema, so it is present
                    // even though the case did not ask for it — see `openai_responses`.
                    assert_eq!(
                        body.pointer("/tools/0/strict"),
                        Some(&json!(false)),
                        "{name}"
                    );
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 3. Two parallel tool calls ---------------------------------------------
        Case {
            name: "two parallel tool calls",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_3","usage":{"input_tokens":30,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_a","name":"weather"}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Rome\"}"}}"#,
                    r#"{"type":"content_block_stop","index":0}"#,
                    r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_b","name":"time"}}"#,
                    r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"tz\":\"UTC\"}"}}"#,
                    r#"{"type":"content_block_stop","index":1}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#,
                    r#"{"type":"message_stop"}"#,
                ]))],
                chat: vec![Reply::sse(
                    frames(&[
                        r#"{"id":"chatcmpl-3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"weather","arguments":"{\"city\":"}},{"index":1,"id":"call_b","function":{"name":"time","arguments":"{\"tz\":"}}]}}]}"#,
                        r#"{"id":"chatcmpl-3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Rome\"}"}},{"index":1,"function":{"arguments":"\"UTC\"}"}}]}}]}"#,
                        r#"{"id":"chatcmpl-3","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                        r#"{"id":"chatcmpl-3","choices":[],"usage":{"prompt_tokens":30,"completion_tokens":20}}"#,
                    ]) + "data: [DONE]\n\n",
                )],
                // On this wire the two calls are two ITEMS, and their argument deltas are
                // deliberately INTERLEAVED here — `fc_a`, `fc_b`, `fc_a`, `fc_b`. That is
                // the shape the neutral event model was doubted over (see LEAKS.md L1):
                // it needs no ordering key, because every fragment already carries the id
                // of the call it belongs to.
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_3","status":"in_progress"}}"#,
                    r#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"weather","arguments":""}}"#,
                    r#"{"type":"response.output_item.added","sequence_number":2,"output_index":1,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"time","arguments":""}}"#,
                    r#"{"type":"response.function_call_arguments.delta","sequence_number":3,"item_id":"fc_a","output_index":0,"delta":"{\"city\":"}"#,
                    r#"{"type":"response.function_call_arguments.delta","sequence_number":4,"item_id":"fc_b","output_index":1,"delta":"{\"tz\":"}"#,
                    r#"{"type":"response.function_call_arguments.delta","sequence_number":5,"item_id":"fc_a","output_index":0,"delta":"\"Rome\"}"}"#,
                    r#"{"type":"response.function_call_arguments.delta","sequence_number":6,"item_id":"fc_b","output_index":1,"delta":"\"UTC\"}"}"#,
                    r#"{"type":"response.function_call_arguments.done","sequence_number":7,"item_id":"fc_a","output_index":0,"arguments":"{\"city\":\"Rome\"}"}"#,
                    r#"{"type":"response.function_call_arguments.done","sequence_number":8,"item_id":"fc_b","output_index":1,"arguments":"{\"tz\":\"UTC\"}"}"#,
                    r#"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_3","status":"completed","usage":{"input_tokens":30,"output_tokens":20}}}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                let mut names: Vec<String> = events
                    .iter()
                    .filter_map(|e| match e {
                        Event::ToolUseStart { name, .. } => Some(name.clone()),
                        _ => None,
                    })
                    .collect();
                names.sort();
                assert_eq!(names, vec!["time", "weather"], "{name} on {wire}");

                // Each call's fragments must be attributable to ITS OWN id — the property
                // that breaks first if an adapter keys accumulation wrongly.
                let mut per_id: HashMap<String, String> = HashMap::new();
                for e in events {
                    if let Event::ToolUseArgsDelta { id, json_fragment } = e {
                        per_id
                            .entry(id.clone())
                            .or_default()
                            .push_str(json_fragment);
                    }
                }
                assert_eq!(per_id.len(), 2, "{name} on {wire}: two distinct call ids");
                let mut parsed: Vec<Value> = per_id
                    .values()
                    .map(|s| {
                        serde_json::from_str(s)
                            .unwrap_or_else(|e| panic!("{name} on {wire}: {s:?} {e}"))
                    })
                    .collect();
                parsed.sort_by_key(|v| v.to_string());
                assert_eq!(
                    parsed,
                    vec![json!({"city": "Rome"}), json!({"tz": "UTC"})],
                    "{name} on {wire}"
                );

                let ends = events
                    .iter()
                    .filter(|e| matches!(e, Event::ToolUseEnd { .. }))
                    .count();
                assert_eq!(ends, 2, "{name} on {wire}: both blocks closed");
            },
            expect_body: no_body_check,
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 4. max_tokens stop ------------------------------------------------------
        Case {
            name: "max_tokens stop",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_4","usage":{"input_tokens":5,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"trunca"}}"#,
                    r#"{"type":"content_block_stop","index":0}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":256}}"#,
                    r#"{"type":"message_stop"}"#,
                ]))],
                chat: vec![Reply::sse(
                    frames(&[
                        r#"{"id":"chatcmpl-4","choices":[{"index":0,"delta":{"content":"trunca"}}]}"#,
                        r#"{"id":"chatcmpl-4","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
                        r#"{"id":"chatcmpl-4","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":256}}"#,
                    ]) + "data: [DONE]\n\n",
                )],
                // A THIRD SPELLING of the same fact: not a finish reason at all, but a
                // response STATUS plus a reason for the incompleteness.
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_4","status":"in_progress"}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"trunca"}"#,
                    r#"{"type":"response.incomplete","sequence_number":2,"response":{"id":"resp_4","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":5,"output_tokens":256}}}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                assert_eq!(text_of(events), "trunca", "{name} on {wire}");
                assert!(
                    matches!(
                        events.last(),
                        Some(Event::Done {
                            stop_reason: StopReason::MaxTokens
                        })
                    ),
                    "{name} on {wire}: `length`/`max_tokens` both normalise to MaxTokens, got {:?}",
                    events.last()
                );
            },
            expect_body: no_body_check,
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 5. 429 then 200: retry, retry-after honoured ---------------------------
        Case {
            name: "429 then 200",
            quirks: Quirks::default(),
            request: base_request,
            script: || {
                let retry =
                    Reply::status(429, r#"{"error":"slow down"}"#).header("retry-after", "1");
                Script {
                    messages: vec![
                        retry.clone(),
                        Reply::sse(frames(&[
                            r#"{"type":"message_start","message":{"id":"msg_5","usage":{"input_tokens":3,"output_tokens":0}}}"#,
                            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
                            r#"{"type":"content_block_stop","index":0}"#,
                            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
                            r#"{"type":"message_stop"}"#,
                        ])),
                    ],
                    chat: vec![
                        retry.clone(),
                        Reply::sse(
                            frames(&[
                                r#"{"id":"chatcmpl-5","choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
                                r#"{"id":"chatcmpl-5","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                                r#"{"id":"chatcmpl-5","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
                            ]) + "data: [DONE]\n\n",
                        ),
                    ],
                    responses: vec![
                        retry,
                        Reply::sse(typed_frames(&[
                            r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_5","status":"in_progress"}}"#,
                            r#"{"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"ok"}"#,
                            r#"{"type":"response.completed","sequence_number":2,"response":{"id":"resp_5","status":"completed","usage":{"input_tokens":3,"output_tokens":1}}}"#,
                        ])),
                    ],
                }
            },
            expect_events: |name, wire, events| {
                // The retry is INVISIBLE to the caller: a clean answer, no error event.
                assert_eq!(text_of(events), "ok", "{name} on {wire}");
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
                assert!(
                    !events.iter().any(|e| matches!(e, Event::Error(_))),
                    "{name} on {wire}: a successful retry surfaces no error"
                );
            },
            expect_body: no_body_check,
            expect_requests: |name, wire, reqs| {
                assert_eq!(
                    reqs.len(),
                    2,
                    "{name} on {wire}: exactly one retry, no more"
                );
                // The retried body is byte-identical — a retry re-sends, it does not rebuild.
                assert_eq!(reqs[0].body, reqs[1].body, "{name} on {wire}");
            },
            cancel_after: None,
        },
        // ---- 6. 401: no retry, Auth --------------------------------------------------
        Case {
            name: "401 is fatal",
            quirks: Quirks::default(),
            request: base_request,
            script: || {
                let unauthorized = Reply::status(401, r#"{"error":{"message":"invalid key"}}"#);
                Script {
                    messages: vec![unauthorized.clone()],
                    chat: vec![unauthorized.clone()],
                    responses: vec![unauthorized],
                }
            },
            // A 401 fails BEFORE a stream exists, so the harness synthesises a single
            // `Error` event from the `Err` return — see `run_case`.
            expect_events: |name, wire, events| {
                assert_eq!(
                    terminal_error(events),
                    Some(ProviderError::Auth),
                    "{name} on {wire}"
                );
            },
            expect_body: no_body_check,
            expect_requests: |name, wire, reqs| {
                assert_eq!(
                    reqs.len(),
                    1,
                    "{name} on {wire}: a bad key is never retried"
                );
            },
            cancel_after: None,
        },
        // ---- 7. A stream that ends with no terminal event ---------------------------
        Case {
            name: "truncated stream is a Protocol error",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                // Both bodies stop after a text delta: no `message_stop`, no `[DONE]`.
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_7","usage":{"input_tokens":1,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half an ans"}}"#,
                ]))],
                chat: vec![Reply::sse(frames(&[
                    r#"{"id":"chatcmpl-7","choices":[{"index":0,"delta":{"content":"half an ans"}}]}"#,
                ]))],
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_7","status":"in_progress"}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"half an ans"}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                // The partial answer is still delivered — the loop gets to keep what it saw.
                assert_eq!(text_of(events), "half an ans", "{name} on {wire}");
                match terminal_error(events) {
                    Some(ProviderError::Protocol(_)) => {}
                    other => panic!("{name} on {wire}: expected Protocol, got {other:?}"),
                }
                assert!(
                    !events.iter().any(|e| matches!(e, Event::Done { .. })),
                    "{name} on {wire}: a truncated stream never reports Done"
                );
            },
            expect_body: no_body_check,
            expect_requests: |name, wire, reqs| {
                assert_eq!(
                    reqs.len(),
                    1,
                    "{name} on {wire}: a Protocol failure is never retried"
                );
            },
            cancel_after: None,
        },
        // ---- 8. Cancellation mid-stream ---------------------------------------------
        Case {
            name: "cancellation mid-stream",
            quirks: Quirks::default(),
            request: base_request,
            script: || {
                Script {
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_8","usage":{"input_tokens":1,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"still going"}}"#,
                ]))
                .holding_open()],
                chat: vec![Reply::sse(frames(&[
                    r#"{"id":"chatcmpl-8","choices":[{"index":0,"delta":{"content":"still going"}}]}"#,
                ]))
                .holding_open()],
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_8","status":"in_progress"}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"still going"}"#,
                ]))
                .holding_open()],
            }
            },
            expect_events: |name, wire, events| {
                assert_eq!(text_of(events), "still going", "{name} on {wire}");
                assert_eq!(
                    terminal_error(events),
                    Some(ProviderError::Cancelled),
                    "{name} on {wire}"
                );
            },
            expect_body: no_body_check,
            expect_requests: no_request_check,
            cancel_after: Some(Duration::from_millis(150)),
        },
        // ---- 9. Usage arithmetic, including the cached subtraction ------------------
        Case {
            name: "usage arithmetic with cached tokens",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                // The SAME underlying truth on both wires: 1000 prompt tokens of which 900
                // were served from cache. The wires report it differently on purpose —
                // Messages reports the two disjoint, Chat reports the total inclusive —
                // and the neutral vector must come out identical.
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_9","usage":{"input_tokens":100,"cache_read_input_tokens":900,"output_tokens":0}}}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":11}}"#,
                    r#"{"type":"message_stop"}"#,
                ]))],
                chat: vec![Reply::sse(
                    frames(&[
                        r#"{"id":"chatcmpl-9","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                        r#"{"id":"chatcmpl-9","choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":11,"prompt_tokens_details":{"cached_tokens":900}}}"#,
                    ]) + "data: [DONE]\n\n",
                )],
                // Reported inclusive here too, under a third set of field names — and the
                // details object is deliberately PARTIAL (no `cache_write_tokens`), which
                // is what a host that reports only what it measures sends.
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.completed","sequence_number":0,"response":{"id":"resp_9","status":"completed","usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":900},"output_tokens":11,"total_tokens":1011}}}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                let u = usage_of(events).unwrap_or_else(|| panic!("{name} on {wire}: no usage"));
                // THE INVARIANT: input_tokens EXCLUDES cache reads, on both wires.
                assert_eq!(u.input_tokens, Some(100), "{name} on {wire}");
                assert_eq!(u.cache_read_tokens, Some(900), "{name} on {wire}");
                assert_eq!(u.output_tokens, Some(11), "{name} on {wire}");
                assert_eq!(
                    u.input_tokens.unwrap() + u.cache_read_tokens.unwrap(),
                    1000,
                    "{name} on {wire}: the parts sum back to the prompt total"
                );
                // …and it survives the conversion to the bridge's shape.
                let t: jesse_agent::TokenUsage = u.into();
                assert_eq!(t.input_tokens, Some(100), "{name} on {wire}");
                assert_eq!(t.cache_read_input_tokens, Some(900), "{name} on {wire}");
            },
            expect_body: no_body_check,
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 10. A cacheable system block -------------------------------------------
        Case {
            name: "cacheable system block",
            quirks: Quirks::default(),
            request: || Request {
                system: vec![
                    SystemBlock::cacheable("the stable prefix"),
                    SystemBlock::plain("today is Tuesday"),
                ],
                tools: vec![ToolSpec {
                    name: "add".into(),
                    description: "d".into(),
                    input_schema: json!({"type": "object"}),
                    strict: false,
                }],
                ..base_request()
            },
            script: simple_end_turn_script,
            expect_events: |name, wire, events| {
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
            },
            expect_body: |name, wire, body| match wire {
                Wire::Messages => {
                    assert_eq!(
                        body.pointer("/system/0/cache_control/type"),
                        Some(&json!("ephemeral")),
                        "{name}: the cacheable block is a breakpoint"
                    );
                    assert!(
                        body.pointer("/system/1/cache_control").is_none(),
                        "{name}: the plain block is not"
                    );
                    assert_eq!(
                        body.pointer("/tools/0/cache_control/type"),
                        Some(&json!("ephemeral")),
                        "{name}: the last tool carries the breakpoint too"
                    );
                }
                Wire::Chat => {
                    assert!(
                        !body.to_string().contains("cache_control"),
                        "{name}: NOTHING cache-shaped may reach a wire without caching"
                    );
                    // The blocks are folded into one leading system message instead.
                    assert_eq!(body.pointer("/messages/0/role"), Some(&json!("system")));
                    assert_eq!(
                        body.pointer("/messages/0/content"),
                        Some(&json!("the stable prefix\n\ntoday is Tuesday"))
                    );
                }
                Wire::Responses => {
                    assert!(
                        !body.to_string().contains("cache_control"),
                        "{name}: NOTHING cache-shaped may reach a wire without a reachable \
                         breakpoint"
                    );
                    // Folded into `instructions` — one string, BYTE-IDENTICAL to the join
                    // the Chat adapter performs, which is what makes a persona pack render
                    // to the same sentences on both OpenAI surfaces.
                    assert_eq!(
                        body.get("instructions"),
                        Some(&json!("the stable prefix\n\ntoday is Tuesday")),
                        "{name}"
                    );
                    // And no tool carries a breakpoint either: this wire has one, on input
                    // content parts, and `instructions` cannot reach it. See
                    // `openai_responses::OpenAiResponses::body`.
                    assert!(body.pointer("/tools/0/cache_control").is_none(), "{name}");
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 11. An image block ------------------------------------------------------
        Case {
            name: "image block",
            quirks: Quirks::default(),
            request: || Request {
                messages: vec![Message {
                    role: Role::User,
                    content: vec![
                        ContentBlock::Image {
                            media_type: "image/png".into(),
                            data_base64: "QUJDRA==".into(),
                        },
                        ContentBlock::Text("what is this?".into()),
                    ],
                }],
                ..base_request()
            },
            script: simple_end_turn_script,
            expect_events: |name, wire, events| {
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
            },
            expect_body: |name, wire, body| match wire {
                Wire::Messages => {
                    assert_eq!(
                        body.pointer("/messages/0/content/0/source/media_type"),
                        Some(&json!("image/png")),
                        "{name}"
                    );
                    assert_eq!(
                        body.pointer("/messages/0/content/0/source/data"),
                        Some(&json!("QUJDRA==")),
                        "{name}: the base64 bytes are sent verbatim"
                    );
                }
                Wire::Chat => {
                    assert_eq!(
                        body.pointer("/messages/0/content/0/image_url/url"),
                        Some(&json!("data:image/png;base64,QUJDRA==")),
                        "{name}: the same bytes, as a data URL"
                    );
                }
                Wire::Responses => {
                    // The same data URL as Chat, but the URL is the field's whole value
                    // rather than an object with a `url` in it — and `detail` is present
                    // because this wire's schema requires it.
                    assert_eq!(
                        body.pointer("/input/0/content/0/image_url"),
                        Some(&json!("data:image/png;base64,QUJDRA==")),
                        "{name}"
                    );
                    assert_eq!(
                        body.pointer("/input/0/content/0/type"),
                        Some(&json!("input_image")),
                        "{name}"
                    );
                    assert_eq!(
                        body.pointer("/input/0/content/1/text"),
                        Some(&json!("what is this?")),
                        "{name}: the text block keeps its position after the image"
                    );
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 12. thinking = high, quirk OFF -----------------------------------------
        Case {
            name: "thinking high with the reasoning-effort quirk off",
            quirks: Quirks::default(),
            request: || Request {
                thinking: Thinking::High,
                ..base_request()
            },
            script: simple_end_turn_script,
            expect_events: |name, wire, events| {
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
            },
            expect_body: |name, wire, body| match wire {
                Wire::Messages => {
                    // The Messages wire has no quirk gate: thinking is native here.
                    assert_eq!(
                        body.pointer("/thinking/type"),
                        Some(&json!("enabled")),
                        "{name}"
                    );
                    // High is 16384, clamped below max_output_tokens (256) → 255.
                    assert_eq!(
                        body.pointer("/thinking/budget_tokens"),
                        Some(&json!(255)),
                        "{name}: clamped below max_tokens as the API requires"
                    );
                }
                Wire::Chat => {
                    assert!(
                        body.get("reasoning_effort").is_none(),
                        "{name}: dropped when the host is not configured for it"
                    );
                }
                Wire::Responses => {
                    assert!(
                        body.get("reasoning").is_none(),
                        "{name}: same quirk, same drop, a different field name"
                    );
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 13. thinking = high, quirk ON ------------------------------------------
        Case {
            name: "thinking high with the reasoning-effort quirk on",
            quirks: Quirks {
                reasoning_effort_supported: true,
                ..Quirks::default()
            },
            request: || Request {
                thinking: Thinking::High,
                sampling: Sampling {
                    max_output_tokens: 65536,
                    ..Default::default()
                },
                ..base_request()
            },
            script: simple_end_turn_script,
            expect_events: |name, wire, events| {
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
            },
            expect_body: |name, wire, body| match wire {
                Wire::Messages => {
                    assert_eq!(
                        body.pointer("/thinking/budget_tokens"),
                        Some(&json!(16384)),
                        "{name}: the documented High budget, unclamped at a large cap"
                    );
                    // The quirk is a Chat-wire concept and must not leak onto this one.
                    assert!(body.get("reasoning_effort").is_none(), "{name}");
                }
                Wire::Chat => {
                    assert_eq!(
                        body.get("reasoning_effort"),
                        Some(&json!("high")),
                        "{name}: sent once the host is configured for it"
                    );
                    assert!(body.get("thinking").is_none(), "{name}");
                }
                Wire::Responses => {
                    assert_eq!(
                        body.pointer("/reasoning/effort"),
                        Some(&json!("high")),
                        "{name}: the same enumerated effort, nested under `reasoning`"
                    );
                    // NO SUMMARY IS REQUESTED. A reasoning summary is generated text and
                    // is billed as output tokens, so asking for one on every call would
                    // spend a caller's money on a display signal. The decoder reads one
                    // when a host sends it anyway — case 15 proves that half.
                    assert!(body.pointer("/reasoning/summary").is_none(), "{name}");
                    assert!(body.get("thinking").is_none(), "{name}");
                    assert!(body.get("reasoning_effort").is_none(), "{name}");
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 14. `store` is a Responses concept and must not leak onto the others ----
        //
        // The row that pins D8's privacy decision. `store` DEFAULTS TO TRUE on the
        // Responses wire, so an absent field there is not equivalent to a false one — and
        // on the other two wires the concept does not exist at all, so the field appearing
        // would mean an adapter had learned a neighbouring wire's vocabulary.
        Case {
            name: "store is off and no response is ever continued",
            quirks: Quirks::default(),
            request: base_request,
            script: simple_end_turn_script,
            expect_events: |name, wire, events| {
                assert!(
                    matches!(events.last(), Some(Event::Done { .. })),
                    "{name} on {wire}"
                );
            },
            expect_body: |name, wire, body| {
                assert!(
                    body.get("previous_response_id").is_none(),
                    "{name} on {wire}: no wire may continue a provider-held conversation"
                );
                match wire {
                    Wire::Messages | Wire::Chat => assert!(
                        body.get("store").is_none(),
                        "{name} on {wire}: a Responses field has no business here"
                    ),
                    Wire::Responses => assert_eq!(
                        body.get("store"),
                        Some(&json!(false)),
                        "{name}: the loop owns the thread; the provider keeps no copy"
                    ),
                }
            },
            expect_requests: no_request_check,
            cancel_after: None,
        },
        // ---- 15. Interleaved items, and a reasoning stream --------------------------
        //
        // TWO CANDIDATE LEAKS IN ONE ROW, both refuted here rather than asserted away.
        //
        //   * "The event model needs a per-item ordering key, because Responses can
        //     interleave items." It does not: the stream is ordered, text deltas
        //     concatenate in arrival order, and every tool fragment already carries the id
        //     of the call it belongs to. This row emits text, then a tool call, then MORE
        //     text — on all three wires, because all three can do it — and asserts the
        //     text comes out in one piece and in order.
        //   * "Thinking has to be requested to be received." It does not: no wire is asked
        //     for reasoning here (the quirk is off, so nothing is sent), and all three
        //     deliver `ThinkingDelta` when the host volunteers one.
        Case {
            name: "interleaved items with reasoning",
            quirks: Quirks::default(),
            request: base_request,
            script: || Script {
                messages: vec![Reply::sse(frames(&[
                    r#"{"type":"message_start","message":{"id":"msg_15","usage":{"input_tokens":8,"output_tokens":0}}}"#,
                    r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                    r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"mulling"}}"#,
                    r#"{"type":"content_block_stop","index":0}"#,
                    r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"before "}}"#,
                    r#"{"type":"content_block_stop","index":1}"#,
                    r#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_i","name":"look"}}"#,
                    r#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
                    r#"{"type":"content_block_stop","index":2}"#,
                    r#"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
                    r#"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"after"}}"#,
                    r#"{"type":"content_block_stop","index":3}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
                    r#"{"type":"message_stop"}"#,
                ]))],
                chat: vec![Reply::sse(
                    frames(&[
                        r#"{"id":"chatcmpl-15","choices":[{"index":0,"delta":{"reasoning_content":"mulling"}}]}"#,
                        r#"{"id":"chatcmpl-15","choices":[{"index":0,"delta":{"content":"before "}}]}"#,
                        r#"{"id":"chatcmpl-15","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_i","function":{"name":"look","arguments":"{}"}}]}}]}"#,
                        r#"{"id":"chatcmpl-15","choices":[{"index":0,"delta":{"content":"after"}}]}"#,
                        r#"{"id":"chatcmpl-15","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                        r#"{"id":"chatcmpl-15","choices":[],"usage":{"prompt_tokens":8,"completion_tokens":9}}"#,
                    ]) + "data: [DONE]\n\n",
                )],
                responses: vec![Reply::sse(typed_frames(&[
                    r#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_15","status":"in_progress"}}"#,
                    r#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}"#,
                    r#"{"type":"response.reasoning_summary_text.delta","sequence_number":2,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":"mulling"}"#,
                    r#"{"type":"response.output_item.added","sequence_number":3,"output_index":1,"item":{"type":"message","id":"msg_a","role":"assistant","content":[]}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_a","output_index":1,"content_index":0,"delta":"before "}"#,
                    r#"{"type":"response.output_item.added","sequence_number":5,"output_index":2,"item":{"type":"function_call","id":"fc_i","call_id":"call_i","name":"look","arguments":""}}"#,
                    r#"{"type":"response.function_call_arguments.delta","sequence_number":6,"item_id":"fc_i","output_index":2,"delta":"{}"}"#,
                    r#"{"type":"response.function_call_arguments.done","sequence_number":7,"item_id":"fc_i","output_index":2,"arguments":"{}"}"#,
                    r#"{"type":"response.output_item.added","sequence_number":8,"output_index":3,"item":{"type":"message","id":"msg_b","role":"assistant","content":[]}}"#,
                    r#"{"type":"response.output_text.delta","sequence_number":9,"item_id":"msg_b","output_index":3,"content_index":0,"delta":"after"}"#,
                    r#"{"type":"response.completed","sequence_number":10,"response":{"id":"resp_15","status":"completed","usage":{"input_tokens":8,"output_tokens":9,"output_tokens_details":{"reasoning_tokens":4}}}}"#,
                ]))],
            },
            expect_events: |name, wire, events| {
                // Text from two separate items, on either side of a tool call, arrives in
                // ORDER and concatenates — with no ordering key anywhere in `Event`.
                assert_eq!(text_of(events), "before after", "{name} on {wire}");
                let thinking: String = events
                    .iter()
                    .filter_map(|e| match e {
                        Event::ThinkingDelta(t) => Some(t.as_str()),
                        _ => None,
                    })
                    .collect();
                assert_eq!(
                    thinking, "mulling",
                    "{name} on {wire}: reasoning is delivered where a host volunteers it"
                );
                // The call is identified by whatever id ITS OWN wire minted — `toolu_…`,
                // `call_…`, `call_…` from a `fc_…` item — so the assertion is that the
                // start and the end agree, not that the id looks like anything.
                let started: Vec<(String, String)> = events
                    .iter()
                    .filter_map(|e| match e {
                        Event::ToolUseStart { id, name } => Some((id.clone(), name.clone())),
                        _ => None,
                    })
                    .collect();
                assert_eq!(started.len(), 1, "{name} on {wire}: one interleaved call");
                assert_eq!(started[0].1, "look", "{name} on {wire}");
                let call_id = started[0].0.clone();
                assert!(
                    events
                        .iter()
                        .any(|e| matches!(e, Event::ToolUseEnd { id } if *id == call_id)),
                    "{name} on {wire}: the interleaved tool call still closes"
                );
                assert!(
                    matches!(
                        events.last(),
                        Some(Event::Done {
                            stop_reason: StopReason::ToolUse
                        })
                    ),
                    "{name} on {wire}: got {:?}",
                    events.last()
                );

                // ---- The one place the three wires genuinely report different AMOUNTS
                // of detail about the same call, which is why `Usage::reasoning_tokens`
                // exists. Asserted here rather than in `expect_body` because it is a
                // property of the neutral RESPONSE vector, not of the request.
                let u = usage_of(events).unwrap_or_else(|| panic!("{name} on {wire}: no usage"));
                match wire {
                    Wire::Responses => assert_eq!(
                        u.reasoning_tokens,
                        Some(4),
                        "{name}: this wire reports an output breakdown, and it survives"
                    ),
                    Wire::Messages | Wire::Chat => assert_eq!(
                        u.reasoning_tokens, None,
                        "{name} on {wire}: no breakdown reported is an ABSENCE, not a zero"
                    ),
                }
                // On every wire the reasoning is INSIDE the output count, never beside it.
                assert_eq!(u.output_tokens, Some(9), "{name} on {wire}");
            },
            expect_body: no_body_check,
            expect_requests: no_request_check,
            cancel_after: None,
        },
    ]
}

/// A minimal successful stream on both wires, for cases whose subject is the REQUEST.
fn simple_end_turn_script() -> Script {
    Script {
        messages: vec![Reply::sse(frames(&[
            r#"{"type":"message_start","message":{"id":"msg_x","usage":{"input_tokens":1,"output_tokens":0}}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            r#"{"type":"message_stop"}"#,
        ]))],
        chat: vec![Reply::sse(
            frames(&[
                r#"{"id":"chatcmpl-x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                r#"{"id":"chatcmpl-x","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#,
            ]) + "data: [DONE]\n\n",
        )],
        responses: vec![Reply::sse(typed_frames(&[
            r#"{"type":"response.completed","sequence_number":0,"response":{"id":"resp_x","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ]))],
    }
}

// ===========================================================================
// The runner
// ===========================================================================

/// Run one case against one wire, THROUGH THE TRAIT OBJECT.
async fn run_case(case: &Case, wire: Wire) {
    let script = (case.script)();
    let replies = match wire {
        Wire::Messages => script.messages,
        Wire::Chat => script.chat,
        Wire::Responses => script.responses,
    };
    let mock = Mock::start(replies).await;

    let mut cfg = ProviderConfig::new(
        wire,
        &mock.base_url,
        "test-model",
        AuthScheme::Bearer("mock-token-not-a-real-credential".into()),
    );
    cfg.quirks = case.quirks.clone();
    // Short backoff so the retry case does not spend a real second waiting; the
    // `retry-after` the mock sends is 1s and IS honoured, which the elapsed-time
    // assertion below checks.
    cfg.retries.base_backoff = Duration::from_millis(10);

    // THE TRAIT OBJECT. Nothing below this line names an adapter type.
    let provider: Box<dyn Provider> = build_provider(cfg).expect("adapter exists");
    assert_eq!(provider.wire(), wire);

    let req = (case.request)();
    let cancel = CancellationToken::new();
    if let Some(after) = case.cancel_after {
        let token = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            token.cancel();
        });
    }

    let started = Instant::now();
    let mut events: Vec<Event> = Vec::new();
    match provider.stream(&req, cancel).await {
        Ok(mut stream) => {
            while let Some(ev) = stream.recv().await {
                events.push(ev);
            }
            // The audit record is filled in by the time the stream ends.
            let audit = stream
                .audit()
                .get()
                .unwrap_or_else(|| panic!("{}: no audit record on {wire}", case.name));
            assert_eq!(audit.wire, wire, "{}", case.name);
            assert_eq!(audit.model, "test-model", "{}", case.name);
            assert_eq!(audit.request_tag, req.request_tag, "{}", case.name);
            assert!(
                audit.attempt >= 1,
                "{}: the audit counts attempts on {wire}",
                case.name
            );
            let line = audit.render();
            assert!(
                !line.contains("mock-token-not-a-real-credential"),
                "{}: the audit line leaked the token on {wire}: {line}",
                case.name
            );
            assert!(
                !line.contains(&mock.base_url),
                "{}: the audit line leaked the URL on {wire}: {line}",
                case.name
            );
            // The 429 case asserts the retry was counted here, where the stream exists.
            if case.name == "429 then 200" {
                assert_eq!(
                    audit.attempt, 2,
                    "{}: the audit line counts the retried attempt on {wire}",
                    case.name
                );
                assert!(
                    line.contains("attempt=2"),
                    "{}: rendered attempt on {wire}: {line}",
                    case.name
                );
                assert!(
                    started.elapsed() >= Duration::from_secs(1),
                    "{}: retry-after=1 was honoured on {wire} (waited {:?})",
                    case.name,
                    started.elapsed()
                );
            }
        }
        Err(e) => {
            // A failure before the stream existed. Presented to the shared expectation as
            // a single terminal `Error` event so one `expect_events` covers both shapes —
            // which is the caller's experience anyway: the call ended with this error.
            events.push(Event::Error(e));
        }
    }

    (case.expect_events)(case.name, wire, &events);

    let seen = mock.requests();
    assert!(
        !seen.is_empty(),
        "{}: the mock received nothing on {wire}",
        case.name
    );
    (case.expect_body)(case.name, wire, &seen[0].body);
    (case.expect_requests)(case.name, wire, &seen);

    if case.cancel_after.is_some() {
        // The connection must actually be gone — a cancelled call that leaves the socket
        // open is a call the provider keeps generating (and billing) for.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !mock.client_closed.load(Ordering::SeqCst) && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(
            mock.client_closed.load(Ordering::SeqCst),
            "{}: the mock never saw the connection close on {wire}",
            case.name
        );
    }
}

/// EVERY CASE, ON EVERY ADAPTER. One test so a divergence is one failure with the wire
/// named, rather than a green suite for one wire and a red one for another.
#[tokio::test(flavor = "multi_thread")]
async fn every_case_behaves_identically_on_every_adapter() {
    for case in cases() {
        for wire in [Wire::Messages, Wire::Chat, Wire::Responses] {
            run_case(&case, wire).await;
        }
    }
}

/// Every declared wire has an adapter, and each reports the wire it was asked for.
///
/// THE REPLACEMENT FOR `the_responses_wire_refuses_to_construct`, which asserted the
/// refusal that was correct while the adapter did not exist. What survives from it is the
/// property that actually mattered — a wire the enum declares is never silently served by
/// a NEIGHBOURING adapter, which for `Responses` would mean posting a Chat body at a
/// Responses endpoint — and that is what `p.wire() == w` checks here.
#[test]
fn every_declared_wire_builds_and_serves_itself() {
    for w in [Wire::Messages, Wire::Chat, Wire::Responses] {
        let cfg = ProviderConfig::new(w, "http://127.0.0.1:1/v1", "m", AuthScheme::None);
        let p = build_provider(cfg).unwrap_or_else(|e| panic!("{w} has no adapter: {e}"));
        assert_eq!(p.wire(), w);
    }
}

/// The adapters agree on the parts of [`jesse_agent::Capabilities`] that are true of the
/// wire itself, and differ only where the wires genuinely differ.
#[test]
fn capabilities_differ_only_where_the_wires_do() {
    let mk = |wire: Wire| {
        build_provider(ProviderConfig::new(
            wire,
            "http://127.0.0.1:1/v1",
            "m",
            AuthScheme::None,
        ))
        .unwrap()
        .capabilities()
    };
    let messages = mk(Wire::Messages);
    let chat = mk(Wire::Chat);
    let responses = mk(Wire::Responses);
    for (wire, c) in [
        ("messages", &messages),
        ("chat", &chat),
        ("responses", &responses),
    ] {
        assert!(c.tool_use, "{wire}");
        assert!(c.streaming, "{wire}");
        assert!(c.vision, "{wire}");
        assert!(c.parallel_tool_calls, "{wire}");
    }
    // Caller-controllable prompt caching exists on ONE wire, and that asymmetry is the
    // reason the flag exists. The two OpenAI wires answer `false` for DIFFERENT reasons —
    // Chat has no breakpoint at all, Responses has one this adapter's `instructions`
    // mapping cannot reach — and the flag deliberately does not distinguish them, because
    // the question it answers ("can the caller influence caching") has the same answer.
    assert!(messages.prompt_caching);
    assert!(!chat.prompt_caching);
    assert!(!responses.prompt_caching);
    // Thinking tracks the QUIRK on both OpenAI wires, and is native on Messages.
    assert!(messages.thinking);
    assert!(!chat.thinking);
    assert!(!responses.thinking);
}
