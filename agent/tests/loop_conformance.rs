//! **The loop conformance suite** — one three-step turn, run four ways.
//!
//! THE CLAIM THIS FILE EXISTS TO MAKE: `run_turn` completes the same tool-calling turn on
//! the Anthropic Messages adapter, on the OpenAI Chat adapter, on the OpenAI Responses
//! adapter and on the scripted provider, and **the thread it leaves behind is identical in
//! all four**. That is the property the neutral model was built for, and it is the only
//! test that can fail if the loop ever learns something about a wire.
//!
//! The fourth way was added in D8 and it earns its place beyond arithmetic: the Responses
//! wire is the one where a tool call has two ids, so a multi-iteration turn is the only
//! thing that can prove the adapter round-trips the right one. See `responses_script`.
//!
//! The turn is a genuine three-iteration one over the fixture tool set: list a directory,
//! read the file it found, answer. Two tool calls, three provider calls, and a thread that
//! ends up six messages long (question, ask, result, ask, result, answer).
//!
//! NO NETWORK. The three adapter runs bind a real loopback socket and speak HTTP/1.1 by hand,
//! the same approach `tests/provider_conformance.rs` and `bridge/tests/integration.rs` take.
//! The mock here is a smaller relative of that one — it serves a QUEUE of scripted replies,
//! one per connection, because a three-iteration turn is three sequential calls and this is
//! the only property those calls need from it. The larger mock's chunk-splitting,
//! hold-open and connection-close-observing machinery belongs to the tests that assert on
//! the wire; asserting on it again here would be testing D1 through D2.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use jesse_agent::provider::scripted::{ScriptedProvider, Step};
use jesse_agent::provider::{
    build_provider, AuthScheme, ContentBlock, Message, Provider, ProviderConfig, Role, ToolSpec,
    Usage, Wire,
};
use jesse_agent::thread::ThreadStore;
use jesse_agent::tools::{fixture::fixture_tool_set, Level, SystemClock, ToolSet};
use jesse_agent::turn::{run_turn, CollectingSink, StopReason, TurnDeps, TurnInput};
use jesse_agent::{
    Budget, MemoryThreadStore, MemoryUsageSink, PriceDeck, Scope, SystemBlock, Thinking,
};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_util::sync::CancellationToken;

// ===========================================================================
// The workspace the fixture tools see
// ===========================================================================

/// A throwaway directory holding one note, so `fs_list` then `fs_read` is a real two-step
/// lookup rather than a tool call with a predetermined answer.
struct Workspace(std::path::PathBuf);

impl Workspace {
    fn new(tag: &str) -> Workspace {
        let root = std::env::temp_dir().join(format!(
            "jesse-agent-loop-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("notes")).unwrap();
        std::fs::write(root.join("notes/a.md"), "the answer is 42").unwrap();
        Workspace(std::fs::canonicalize(&root).unwrap())
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

// ===========================================================================
// The mock
// ===========================================================================

/// What the mock saw.
#[derive(Debug, Clone)]
struct Recorded {
    path: String,
    body: Value,
}

/// Serves `replies` in order, one per connection, each with `connection: close`.
///
/// One request per connection is what makes a three-call turn observable as three
/// recordings in order, and it lets an SSE body be framed by end-of-stream with no chunked
/// encoder to write by hand.
struct Mock {
    base_url: String,
    seen: Arc<Mutex<Vec<Recorded>>>,
}

impl Mock {
    async fn start(replies: Vec<String>) -> Mock {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let seen_task = seen.clone();
        tokio::spawn(async move {
            let mut replies = replies.into_iter();
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let reply = replies.next();
                let seen = seen_task.clone();
                tokio::spawn(async move {
                    let _ = serve_one(stream, reply, seen).await;
                });
            }
        });
        Mock {
            base_url: format!("http://{addr}"),
            seen,
        }
    }

    fn requests(&self) -> Vec<Recorded> {
        self.seen.lock().unwrap().clone()
    }
}

async fn serve_one(
    mut stream: TcpStream,
    reply: Option<String>,
    seen: Arc<Mutex<Vec<Recorded>>>,
) -> std::io::Result<()> {
    let mut buf = Vec::new();
    let head_end = loop {
        let mut b = [0u8; 8192];
        let n = stream.read(&mut b).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&b[..n]);
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break p + 4;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let path = lines
        .next()
        .unwrap_or_default()
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
    let len: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut body = buf[head_end..].to_vec();
    while body.len() < len {
        let mut b = [0u8; 8192];
        let n = stream.read(&mut b).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&b[..n]);
    }
    seen.lock().unwrap().push(Recorded {
        path,
        body: serde_json::from_slice(&body).unwrap_or(Value::Null),
    });

    let Some(reply) = reply else {
        // An UNSCRIPTED call — the loop made one more than the case expected. A 500 makes
        // that a failed assertion on the outcome rather than a hang.
        stream
            .write_all(b"HTTP/1.1 500 X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
            .await?;
        return Ok(());
    };
    stream
        .write_all(
            b"HTTP/1.1 200 X\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
        )
        .await?;
    stream.write_all(reply.as_bytes()).await?;
    stream.flush().await
}

fn frame(payload: &str) -> String {
    format!("data: {payload}\n\n")
}

// ===========================================================================
// The three-step script, in four dialects
// ===========================================================================

const LIST_ARGS: &str = r#"{\"path\":\".\"}"#;
const READ_ARGS: &str = r#"{\"path\":\"notes/a.md\"}"#;
const ANSWER: &str = "The answer is 42.";

/// The Anthropic Messages SSE for the three calls, in order.
fn messages_script() -> Vec<String> {
    let tool_call = |id: &str, name: &str, args: &str, input: u32| {
        [
            frame(&format!(
                r#"{{"type":"message_start","message":{{"id":"msg_{id}","usage":{{"input_tokens":{input},"output_tokens":0}}}}}}"#
            )),
            frame(&format!(
                r#"{{"type":"content_block_start","index":0,"content_block":{{"type":"tool_use","id":"{id}","name":"{name}"}}}}"#
            )),
            frame(&format!(
                r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"input_json_delta","partial_json":"{args}"}}}}"#
            )),
            frame(r#"{"type":"content_block_stop","index":0}"#),
            frame(
                r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}"#,
            ),
            frame(r#"{"type":"message_stop"}"#),
        ]
        .concat()
    };
    vec![
        tool_call("call_1", "fs_list", LIST_ARGS, 100),
        tool_call("call_2", "fs_read", READ_ARGS, 200),
        [
            frame(
                r#"{"type":"message_start","message":{"id":"msg_3","usage":{"input_tokens":300,"output_tokens":0}}}"#,
            ),
            frame(r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            frame(&format!(
                r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{ANSWER}"}}}}"#
            )),
            frame(r#"{"type":"content_block_stop","index":0}"#),
            frame(
                r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}"#,
            ),
            frame(r#"{"type":"message_stop"}"#),
        ]
        .concat(),
    ]
}

/// The OpenAI Chat SSE for the same three calls.
fn chat_script() -> Vec<String> {
    let tool_call = |id: &str, name: &str, args: &str, input: u32| {
        [
            frame(&format!(
                r#"{{"id":"cc_{id}","choices":[{{"index":0,"delta":{{"tool_calls":[{{"index":0,"id":"{id}","type":"function","function":{{"name":"{name}","arguments":"{args}"}}}}]}}}}]}}"#
            )),
            frame(&format!(
                r#"{{"id":"cc_{id}","choices":[{{"index":0,"delta":{{}},"finish_reason":"tool_calls"}}]}}"#
            )),
            frame(&format!(
                r#"{{"id":"cc_{id}","choices":[],"usage":{{"prompt_tokens":{input},"completion_tokens":10}}}}"#
            )),
            "data: [DONE]\n\n".to_string(),
        ]
        .concat()
    };
    vec![
        tool_call("call_1", "fs_list", LIST_ARGS, 100),
        tool_call("call_2", "fs_read", READ_ARGS, 200),
        [
            frame(&format!(
                r#"{{"id":"cc_3","choices":[{{"index":0,"delta":{{"role":"assistant","content":"{ANSWER}"}}}}]}}"#
            )),
            frame(r#"{"id":"cc_3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
            frame(r#"{"id":"cc_3","choices":[],"usage":{"prompt_tokens":300,"completion_tokens":10}}"#),
            "data: [DONE]\n\n".to_string(),
        ]
        .concat(),
    ]
}

/// The OpenAI Responses SSE for the same three calls.
///
/// THE ONE THAT EXERCISES THE SEND PATH, which is why it is worth having here as well as in
/// `tests/provider_conformance.rs`. This wire gives a tool call TWO ids — an item id the
/// stream's deltas are keyed by, and a `call_id` a result must be addressed to — and only
/// a multi-iteration turn can prove the adapter round-trips the right one: the loop takes
/// the id from `ToolUseStart`, stores it, and sends it back as
/// `function_call_output.call_id` on the NEXT call. So the fixtures deliberately mint an
/// item id (`fc_…`) that is not the call id, and
/// `the_responses_wire_addresses_a_tool_result_by_call_id` reads what the mock received.
fn responses_script() -> Vec<String> {
    let tool_call = |id: &str, name: &str, args: &str, input: u32| {
        [
            frame(&format!(
                r#"{{"type":"response.created","response":{{"id":"resp_{id}","status":"in_progress"}}}}"#
            )),
            frame(&format!(
                r#"{{"type":"response.output_item.added","output_index":0,"item":{{"type":"function_call","id":"fc_{id}","call_id":"{id}","name":"{name}","arguments":""}}}}"#
            )),
            frame(&format!(
                r#"{{"type":"response.function_call_arguments.delta","item_id":"fc_{id}","output_index":0,"delta":"{args}"}}"#
            )),
            frame(&format!(
                r#"{{"type":"response.function_call_arguments.done","item_id":"fc_{id}","output_index":0,"arguments":"{args}"}}"#
            )),
            frame(&format!(
                r#"{{"type":"response.completed","response":{{"id":"resp_{id}","status":"completed","usage":{{"input_tokens":{input},"output_tokens":10}}}}}}"#
            )),
        ]
        .concat()
    };
    vec![
        tool_call("call_1", "fs_list", LIST_ARGS, 100),
        tool_call("call_2", "fs_read", READ_ARGS, 200),
        [
            frame(
                r#"{"type":"response.created","response":{"id":"resp_3","status":"in_progress"}}"#,
            ),
            frame(
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_3","role":"assistant","content":[]}}"#,
            ),
            frame(&format!(
                r#"{{"type":"response.output_text.delta","item_id":"msg_3","output_index":0,"content_index":0,"delta":"{ANSWER}"}}"#
            )),
            frame(
                r#"{"type":"response.completed","response":{"id":"resp_3","status":"completed","usage":{"input_tokens":300,"output_tokens":10}}}"#,
            ),
        ]
        .concat(),
    ]
}

/// The same three calls as `Event` sequences — no wire at all.
fn scripted_steps() -> Vec<Step> {
    let usage = |input: u64| Usage {
        input_tokens: Some(input),
        output_tokens: Some(10),
        cache_read_tokens: None,
        cache_write_tokens: None,
        reasoning_tokens: None,
        provider_request_id: None,
    };
    vec![
        Step::tool_call("call_1", "fs_list", json!({"path": "."}), usage(100)),
        Step::tool_call(
            "call_2",
            "fs_read",
            json!({"path": "notes/a.md"}),
            usage(200),
        ),
        Step::text(ANSWER, usage(300)),
    ]
}

// ===========================================================================
// Running one turn
// ===========================================================================

fn scope() -> Scope {
    Scope::new("acme", "jeremy", "default")
}

fn budget() -> Budget {
    Budget::with_wall(Duration::from_secs(30))
}

fn input(tools: Arc<dyn ToolSet>) -> TurnInput {
    TurnInput {
        scope: scope(),
        turn_id: "turn-1".into(),
        thread_id: None,
        system: vec![SystemBlock::plain("You are a careful assistant.")],
        user_text: "What is the answer, according to my notes?".into(),
        user_images: Vec::new(),
        budget: budget(),
        prices: PriceDeck {
            in_per_m: 3.0,
            cached_per_m: 0.3,
            out_per_m: 15.0,
        },
        thinking: Thinking::Off,
        tools,
        artifact_dir: None,
    }
}

/// One turn, and everything it left behind.
struct Ran {
    outcome: jesse_agent::TurnOutcome,
    messages: Vec<Message>,
    usage_records: Vec<jesse_agent::UsageRecord>,
    sink_text: String,
    activities: Vec<jesse_agent::ToolActivity>,
}

async fn run(provider: &dyn Provider, workspace: &Workspace, level: Level) -> Ran {
    let tools: Arc<dyn ToolSet> =
        Arc::new(fixture_tool_set(workspace.path(), level).expect("fixture tool set"));
    let threads = MemoryThreadStore::new();
    let usage = MemoryUsageSink::new();
    let sink = CollectingSink::new();
    let deps = TurnDeps {
        provider,
        threads: &threads,
        usage: &usage,
        clock: Arc::new(SystemClock::new()),
    };
    let outcome = run_turn(input(tools), &deps, &sink, CancellationToken::new()).await;
    let messages = threads.load(&outcome.thread_id).unwrap().messages;
    Ran {
        outcome,
        messages,
        usage_records: usage.records(),
        sink_text: sink.text(),
        activities: sink.activities(),
    }
}

async fn run_over_wire(wire: Wire, replies: Vec<String>, workspace: &Workspace) -> (Ran, Mock) {
    let mock = Mock::start(replies).await;
    let cfg = ProviderConfig::new(wire, &mock.base_url, "test-model", AuthScheme::None);
    let provider = build_provider(cfg).expect("adapter exists");
    let ran = run(provider.as_ref(), workspace, Level::Read).await;
    (ran, mock)
}

// ===========================================================================
// The assertions every provider must satisfy
// ===========================================================================

/// The thread a completed three-step turn must leave, in the neutral model.
///
/// Written out in full rather than spot-checked, because "identical on three providers" is
/// only a claim if the thing being compared is the whole thing. The tool RESULT text is not
/// spelled out here — it is what the fixture tools produced, framed — so the two ids and
/// the framing header are checked instead and the results are compared BETWEEN providers.
fn assert_thread_shape(what: &str, messages: &[Message]) {
    assert_eq!(messages.len(), 6, "{what}: six messages");

    // 1. the user's question
    assert_eq!(messages[0].role, Role::User);
    assert_eq!(
        messages[0].content,
        vec![ContentBlock::Text(
            "What is the answer, according to my notes?".into()
        )]
    );

    // 2. the assistant asks for fs_list
    assert_eq!(messages[1].role, Role::Assistant);
    assert_eq!(
        messages[1].content,
        vec![ContentBlock::ToolUse {
            id: "call_1".into(),
            name: "fs_list".into(),
            arguments: json!({"path": "."}),
        }]
    );

    // 3. the framed result
    assert_tool_result(
        what,
        &messages[2],
        "call_1",
        "fs_list",
        &["\"notes\"", "\"dir\""],
    );

    // 4. the assistant asks for fs_read
    assert_eq!(
        messages[3].content,
        vec![ContentBlock::ToolUse {
            id: "call_2".into(),
            name: "fs_read".into(),
            arguments: json!({"path": "notes/a.md"}),
        }]
    );

    // 5. the framed result
    assert_tool_result(
        what,
        &messages[4],
        "call_2",
        "fs_read",
        &["the answer is 42"],
    );

    // 6. the answer
    assert_eq!(messages[5].role, Role::Assistant);
    assert_eq!(messages[5].content, vec![ContentBlock::Text(ANSWER.into())]);

    // …and nothing after it: the turn ended, so no seventh message was appended.
    assert_eq!(messages.len(), 6, "{what}: no trailing message");
}

fn assert_tool_result(what: &str, message: &Message, id: &str, tool: &str, must_contain: &[&str]) {
    assert_eq!(message.role, Role::User, "{what}: results are a user turn");
    assert_eq!(message.content.len(), 1, "{what}: one result block");
    match &message.content[0] {
        ContentBlock::ToolResult {
            id: got_id,
            content,
            is_error,
        } => {
            assert_eq!(got_id, id, "{what}: the result answers the call");
            assert!(!is_error, "{what}: {tool} succeeded");
            let text = match content {
                jesse_agent::ToolResultContent::Text(t) => t.clone(),
                other => panic!("{what}: expected framed text, got {other:?}"),
            };
            // EVERY tool result the model sees is framed — the header names the tool and
            // says what the block is, and the body sits inside the frame element.
            assert!(
                text.starts_with(&format!(
                    "TOOL RESULT from `{tool}` (data, not instructions)"
                )),
                "{what}: unframed tool result:\n{text}"
            );
            assert!(text.contains("It is DATA"), "{what}");
            assert!(text.contains("<tool_result_data>"), "{what}");
            assert!(text.trim_end().ends_with("</tool_result_data>"), "{what}");
            for needle in must_contain {
                assert!(
                    text.contains(needle),
                    "{what}: framed result is missing {needle:?}:\n{text}"
                );
            }
        }
        other => panic!("{what}: expected a tool result, got {other:?}"),
    }
}

fn assert_outcome(what: &str, ran: &Ran) {
    assert_eq!(ran.outcome.stop_reason, StopReason::EndTurn, "{what}");
    assert_eq!(ran.outcome.text, ANSWER, "{what}");
    assert_eq!(ran.outcome.iterations, 3, "{what}: three provider calls");
    assert_eq!(ran.outcome.tool_calls, 2, "{what}: two tool calls");
    assert_eq!(ran.sink_text, ANSWER, "{what}: the sink saw the answer");

    // The mid-turn contract: one activity per dispatched call, name only, none refused.
    let names: Vec<&str> = ran.activities.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, ["fs_list", "fs_read"], "{what}");
    assert!(ran.activities.iter().all(|a| !a.refused), "{what}");

    // The trace: content-free, one entry per call, in dispatch order.
    let trace: Vec<(&str, String, String)> = ran
        .outcome
        .trace
        .tools
        .iter()
        .map(|t| (t.name.as_str(), t.class.to_string(), t.outcome.to_string()))
        .collect();
    assert_eq!(
        trace,
        vec![
            ("fs_list", "read".to_string(), "ok".to_string()),
            ("fs_read", "read".to_string(), "ok".to_string()),
        ],
        "{what}"
    );
    assert_eq!(ran.outcome.trace.iterations, 3, "{what}");
    assert_eq!(ran.outcome.trace.refusals(), 0, "{what}");

    // One usage record per provider call, with the phase set.
    assert_eq!(ran.usage_records.len(), 3, "{what}: one record per call");
    let phases: Vec<String> = ran
        .usage_records
        .iter()
        .map(|r| r.phase.to_string())
        .collect();
    assert_eq!(
        phases,
        ["main", "tool_followup", "tool_followup"],
        "{what}: the first call is the main one"
    );
    for r in &ran.usage_records {
        assert_eq!(r.turn_id, "turn-1", "{what}");
        assert_eq!(r.tenant, "acme", "{what}");
        assert_eq!(r.user, "jeremy", "{what}");
        assert_eq!(r.workspace, "default", "{what}");
        assert_eq!(
            r.conversation_id,
            ran.outcome.thread_id.to_string(),
            "{what}"
        );
    }
    assert_eq!(
        ran.usage_records
            .iter()
            .map(|r| r.input_tokens.unwrap_or(0))
            .collect::<Vec<_>>(),
        [100, 200, 300],
        "{what}"
    );

    // 600 input + 30 output on the deck above.
    let expected = (600.0 * 3.0 + 30.0 * 15.0) / 1_000_000.0;
    assert!(
        (ran.outcome.cost_usd - expected).abs() < 1e-12,
        "{what}: cost {} != {expected}",
        ran.outcome.cost_usd
    );
    assert_eq!(ran.outcome.usage.input_tokens, Some(600), "{what}");
    assert_eq!(ran.outcome.usage.output_tokens, Some(30), "{what}");
}

// ===========================================================================
// The tests
// ===========================================================================

#[tokio::test]
async fn a_three_step_turn_is_identical_on_every_adapter_and_the_scripted_provider() {
    let ws = Workspace::new("identical");

    let (messages_run, messages_mock) = run_over_wire(Wire::Messages, messages_script(), &ws).await;
    let (chat_run, chat_mock) = run_over_wire(Wire::Chat, chat_script(), &ws).await;
    let (responses_run, responses_mock) =
        run_over_wire(Wire::Responses, responses_script(), &ws).await;
    let scripted = ScriptedProvider::new(Wire::Chat, "test-model", scripted_steps());
    let scripted_run = run(&scripted, &ws, Level::Read).await;

    for (what, ran) in [
        ("messages", &messages_run),
        ("chat", &chat_run),
        ("responses", &responses_run),
        ("scripted", &scripted_run),
    ] {
        assert_thread_shape(what, &ran.messages);
        assert_outcome(what, ran);
    }

    // THE CLAIM. Not "each is right" but "all four are the same object" — the thread is
    // byte-identical across the three wires and the wireless provider, which is what makes
    // a conversation portable between them.
    assert_eq!(
        messages_run.messages, chat_run.messages,
        "the Messages and Chat wires produced different threads"
    );
    assert_eq!(
        chat_run.messages, responses_run.messages,
        "the Responses wire produced a different thread"
    );
    assert_eq!(
        responses_run.messages, scripted_run.messages,
        "a wire changed the thread relative to the scripted provider"
    );

    // Each adapter made exactly three calls, to its own path.
    assert_eq!(messages_mock.requests().len(), 3);
    assert!(messages_mock
        .requests()
        .iter()
        .all(|r| r.path == "/v1/messages"));
    assert_eq!(chat_mock.requests().len(), 3);
    assert!(chat_mock
        .requests()
        .iter()
        .all(|r| r.path == "/chat/completions"));
    assert_eq!(responses_mock.requests().len(), 3);
    assert!(responses_mock
        .requests()
        .iter()
        .all(|r| r.path == "/responses"));
}

/// The Responses wire's two ids, checked from the far side of the socket.
///
/// The fixture streams a call whose ITEM id is `fc_call_1` and whose `call_id` is `call_1`.
/// If the adapter emitted the item id as the neutral id, the loop would store it, send it
/// back, and every tool result would address an item the provider has no pairing for —
/// producing a turn that looks perfectly formed and in which the model never sees a single
/// tool result. So the assertion is on the LAST request's body, where the whole
/// round trip has already happened.
#[tokio::test]
async fn the_responses_wire_addresses_a_tool_result_by_call_id() {
    let ws = Workspace::new("callid");
    let (_, mock) = run_over_wire(Wire::Responses, responses_script(), &ws).await;
    let requests = mock.requests();
    let last = &requests[2].body;
    let input = last["input"].as_array().expect("the items are re-sent");

    let calls: Vec<&str> = input
        .iter()
        .filter(|i| i["type"] == "function_call")
        .map(|i| i["call_id"].as_str().unwrap())
        .collect();
    let outputs: Vec<&str> = input
        .iter()
        .filter(|i| i["type"] == "function_call_output")
        .map(|i| i["call_id"].as_str().unwrap())
        .collect();
    assert_eq!(calls, ["call_1", "call_2"], "the calls go back by call_id");
    assert_eq!(outputs, ["call_1", "call_2"], "so do their results");
    assert!(
        !serde_json::to_string(last).unwrap().contains("fc_call_1"),
        "the provider's ITEM id must never leave the adapter: {last}"
    );

    // …and the privacy posture holds on every iteration of a multi-call turn, not just the
    // first: a `store: true` on the third request would keep the whole tool loop.
    for (i, r) in requests.iter().enumerate() {
        assert_eq!(r.body["store"], json!(false), "request {i}");
        assert!(r.body.get("previous_response_id").is_none(), "request {i}");
    }
}

#[tokio::test]
async fn a_tool_above_the_granted_level_is_absent_from_the_manifest_the_provider_received() {
    let ws = Workspace::new("manifest");

    // The claim is asserted FROM THE REQUEST BODY, not from the tool set: what matters is
    // what the model was shown, and only the request body knows that.
    let (_, mock) = run_over_wire(Wire::Messages, messages_script(), &ws).await;
    let body = &mock.requests()[0].body;
    let names: Vec<&str> = body["tools"]
        .as_array()
        .expect("the manifest is sent")
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        ["fs_list", "fs_read"],
        "a Read-level turn must be shown exactly the Read tools"
    );
    assert!(
        !serde_json::to_string(body).unwrap().contains("fs_write"),
        "the write tool must not appear ANYWHERE in the request a Read turn sends"
    );

    // And on the Chat wire, whose manifest lives at a different path in the body.
    let (_, chat_mock) = run_over_wire(Wire::Chat, chat_script(), &ws).await;
    let chat_requests = chat_mock.requests();
    let chat_names: Vec<&str> = chat_requests[0].body["tools"]
        .as_array()
        .expect("the manifest is sent")
        .iter()
        .map(|t| t["function"]["name"].as_str().unwrap())
        .collect();
    assert_eq!(chat_names, ["fs_list", "fs_read"]);

    // And on the Responses wire, where the manifest is flat again — a third path in the
    // body for the same neutral manifest, which is the point of asserting on all three.
    let (_, responses_mock) = run_over_wire(Wire::Responses, responses_script(), &ws).await;
    let responses_requests = responses_mock.requests();
    let responses_names: Vec<&str> = responses_requests[0].body["tools"]
        .as_array()
        .expect("the manifest is sent")
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(responses_names, ["fs_list", "fs_read"]);
    assert!(
        !serde_json::to_string(&responses_requests[0].body)
            .unwrap()
            .contains("fs_write"),
        "the write tool must not appear ANYWHERE in the request a Read turn sends"
    );

    // The manifest is IDENTICAL on every iteration — a set of tools that changed under the
    // model mid-turn would make dispatch depend on timing.
    let all: Vec<Value> = mock
        .requests()
        .iter()
        .map(|r| r.body["tools"].clone())
        .collect();
    assert_eq!(all[0], all[1]);
    assert_eq!(all[1], all[2]);
}

#[tokio::test]
async fn a_write_level_turn_is_shown_the_write_tool_and_a_read_level_one_is_not() {
    let ws = Workspace::new("levels");
    let read = fixture_tool_set(ws.path(), Level::Read).unwrap();
    let write = fixture_tool_set(ws.path(), Level::Write).unwrap();
    let basic = fixture_tool_set(ws.path(), Level::Basic).unwrap();

    let names = |set: &jesse_agent::StaticToolSet| -> Vec<String> {
        set.manifest()
            .into_iter()
            .map(|t: ToolSpec| t.name)
            .collect()
    };
    assert_eq!(names(&basic), Vec::<String>::new());
    assert_eq!(names(&read), ["fs_list", "fs_read"]);
    assert_eq!(names(&write), ["fs_list", "fs_read", "fs_write"]);

    // Withheld tools are named — so "the model was never offered a write tool" is legible
    // rather than being inferred from silence.
    assert_eq!(read.withheld(), ["fs_write"]);
    assert!(write.withheld().is_empty());
}

#[tokio::test]
async fn the_system_prefix_is_sent_with_a_cache_breakpoint() {
    let ws = Workspace::new("cache");
    let (_, mock) = run_over_wire(Wire::Messages, messages_script(), &ws).await;
    let body = &mock.requests()[0].body;
    assert_eq!(
        body["system"][0]["text"], "You are a careful assistant.",
        "the caller's block, unedited"
    );
    assert_eq!(
        body["system"][0]["cache_control"]["type"], "ephemeral",
        "an unmarked prefix gets a breakpoint — it is about to be re-sent three times"
    );
}
