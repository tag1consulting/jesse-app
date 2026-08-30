//! **The Anthropic Messages adapter** — `POST {base_url}/v1/messages`, `stream: true`.
//!
//! Every Anthropic-shaped string in this crate lives in this file. The bodies are built
//! with `serde_json` and sent as strings, and the headers are the ones
//! `bridge/src/health.rs` and `bridge/src/vision.rs` already send, because those two are
//! this repository's working prior art for this exact surface.

use serde_json::{json, Map, Value};
use tokio_util::sync::CancellationToken;

use super::http::{self, EventStream, SseDecoder};
use super::{
    BoxFuture, Capabilities, ContentBlock, Event, Message, Provider, ProviderConfig, ProviderError,
    Request, Role, StopReason, Thinking, ToolResultContent, Usage, Wire,
};

/// The API version header, pinned to the value the bridge sends today.
///
/// The SAME string `health.rs:523` and `vision.rs:438` both send. It is pinned rather than
/// configurable on purpose: this header selects a request/response SCHEMA, so changing it
/// changes what the parser below must accept. When it moves, it moves here and in the
/// bridge together, with the parser reviewed against the new schema — not per deployment
/// via an env var that would let a config change silently alter what the code is parsing.
pub const ANTHROPIC_VERSION: &str = "2023-06-01";

/// The path appended to `base_url`.
const MESSAGES_PATH: &str = "/v1/messages";

/// The token budget each neutral [`Thinking`] level maps to.
///
/// THE MAPPING, and the reasoning for the numbers:
///   * `Off`    → no `thinking` field at all. Not `budget_tokens: 0`, which the API
///     rejects — "off" has to be the field's absence.
///   * `Low`    → 1024, which is the API's MINIMUM. Anything smaller is refused, so the
///     lowest level that exists is the lowest level that is legal.
///   * `Medium` → 4096. Room for a few hundred words of reasoning; the level a tool-using
///     turn wants by default.
///   * `High`   → 16384. Deep enough for multi-step planning without being open-ended.
///
/// The numbers are round powers of two rather than tuned values, and nothing here claims
/// they are optimal — they are a documented, checkable table, which is the property that
/// matters when the alternative is each call site inventing its own.
///
/// CLAMPED BELOW `max_output_tokens`: the API requires `budget_tokens < max_tokens`,
/// because the budget is drawn FROM the output allowance rather than added to it. A
/// caller asking for `High` with a 512-token cap gets a budget of 511 rather than a `400`.
pub fn thinking_budget_tokens(level: Thinking, max_output_tokens: u32) -> Option<u32> {
    let want = match level {
        Thinking::Off => return None,
        Thinking::Low => 1024,
        Thinking::Medium => 4096,
        Thinking::High => 16384,
    };
    Some(want.min(max_output_tokens.saturating_sub(1)).max(1))
}

/// The Anthropic Messages wire.
pub struct AnthropicMessages {
    cfg: ProviderConfig,
    client: reqwest::Client,
}

impl AnthropicMessages {
    pub fn new(mut cfg: ProviderConfig) -> Self {
        // `anthropic-version` is added HERE, to the adapter's own copy of the config,
        // rather than by the shared caller in `http::start_call`. The shared path is
        // wire-agnostic by design and must not learn one wire's mandatory header; and
        // requiring every caller to remember it in `extra_headers` would make a forgotten
        // header a runtime 400 rather than something the adapter simply guarantees.
        //
        // A caller that set it explicitly WINS — a gateway pinned to a different schema
        // version is a real deployment, and silently sending two conflicting values would
        // be worse than either choice.
        if !cfg
            .extra_headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("anthropic-version"))
        {
            cfg.extra_headers
                .push(("anthropic-version".into(), ANTHROPIC_VERSION.into()));
        }
        let client = http::build_client(&cfg);
        AnthropicMessages { cfg, client }
    }

    /// The request body. Public within the crate so the conformance suite can assert on
    /// the exact JSON without a socket, in addition to asserting on what the mock received.
    pub(crate) fn body(&self, req: &Request) -> Value {
        let mut body = Map::new();
        body.insert("model".into(), json!(self.cfg.model));
        body.insert("stream".into(), json!(true));
        body.insert("max_tokens".into(), json!(req.sampling.max_output_tokens));

        // ---- System prefix -------------------------------------------------
        //
        // Always the ARRAY form, even for a single block, because `cache_control` is a
        // property of a block and the string form has nowhere to put it. The array form is
        // accepted for every request, so there is no case where the string form is needed.
        if !req.system.is_empty() {
            let blocks: Vec<Value> = req
                .system
                .iter()
                .map(|b| {
                    let mut o = Map::new();
                    o.insert("type".into(), json!("text"));
                    o.insert("text".into(), json!(b.text));
                    if b.cacheable {
                        o.insert("cache_control".into(), json!({"type": "ephemeral"}));
                    }
                    Value::Object(o)
                })
                .collect();
            body.insert("system".into(), Value::Array(blocks));
        }

        body.insert(
            "messages".into(),
            Value::Array(req.messages.iter().map(encode_message).collect()),
        );

        // ---- Tools ---------------------------------------------------------
        //
        // The cache breakpoint goes on the LAST tool when any system block is cacheable.
        // A breakpoint covers everything BEFORE it, and the wire orders the prompt as
        // tools-then-system-then-messages — so marking the last tool is what actually puts
        // the whole tool manifest inside the cached prefix. Marking each tool individually
        // was rejected: breakpoints are a scarce per-request resource, and every one spent
        // on a tool is one unavailable to the conversation.
        //
        // `strict` is NOT sent. It is an OpenAI structured-outputs field with no Messages
        // equivalent, and this wire rejects unknown keys inside a tool object. The flag is
        // honoured on the wire that has it and is inert here — which is why
        // `ToolSpec::strict` documents itself as a request rather than a guarantee.
        if !req.tools.is_empty() {
            let any_cacheable = req.system.iter().any(|b| b.cacheable);
            let last = req.tools.len() - 1;
            let tools: Vec<Value> = req
                .tools
                .iter()
                .enumerate()
                .map(|(i, t)| {
                    let mut o = Map::new();
                    o.insert("name".into(), json!(t.name));
                    o.insert("description".into(), json!(t.description));
                    o.insert("input_schema".into(), t.input_schema.clone());
                    if any_cacheable && i == last {
                        o.insert("cache_control".into(), json!({"type": "ephemeral"}));
                    }
                    Value::Object(o)
                })
                .collect();
            body.insert("tools".into(), Value::Array(tools));
        }

        if !req.sampling.stop_sequences.is_empty() {
            body.insert("stop_sequences".into(), json!(req.sampling.stop_sequences));
        }

        // ---- Thinking ------------------------------------------------------
        match thinking_budget_tokens(req.thinking, req.sampling.max_output_tokens) {
            Some(budget) => {
                body.insert(
                    "thinking".into(),
                    json!({"type": "enabled", "budget_tokens": budget}),
                );
                // TEMPERATURE IS DROPPED WHEN THINKING IS ON, deliberately. The API
                // rejects a non-default `temperature` alongside extended thinking, so
                // sending both turns a request that asked for two things into a request
                // that gets neither. Honouring the thinking budget is the right side of
                // that trade: the caller asked for reasoning depth explicitly, whereas a
                // temperature is nearly always inherited from a default. One note is
                // logged so it is not silent.
                if req.sampling.temperature.is_some() {
                    eprintln!(
                        "jesse-agent: note wire=messages tag={:?} dropped temperature \
                         (the Messages API rejects it alongside extended thinking)",
                        req.request_tag
                    );
                }
            }
            None => {
                if let Some(t) = req.sampling.temperature {
                    body.insert("temperature".into(), json!(t));
                }
            }
        }

        Value::Object(body)
    }
}

/// Encode one neutral message.
fn encode_message(m: &Message) -> Value {
    json!({
        "role": match m.role { Role::User => "user", Role::Assistant => "assistant" },
        "content": m.content.iter().map(encode_block).collect::<Vec<_>>(),
    })
}

/// Encode one neutral content block.
fn encode_block(b: &ContentBlock) -> Value {
    match b {
        ContentBlock::Text(t) => json!({"type": "text", "text": t}),
        ContentBlock::Image {
            media_type,
            data_base64,
        } => json!({
            "type": "image",
            "source": {"type": "base64", "media_type": media_type, "data": data_base64},
        }),
        ContentBlock::ToolUse {
            id,
            name,
            arguments,
        } => json!({"type": "tool_use", "id": id, "name": name, "input": arguments}),
        ContentBlock::ToolResult {
            id,
            content,
            is_error,
        } => {
            let content = match content {
                ToolResultContent::Text(t) => json!(t),
                ToolResultContent::Blocks(bs) => {
                    Value::Array(bs.iter().map(encode_block).collect())
                }
            };
            json!({
                "type": "tool_result",
                "tool_use_id": id,
                "content": content,
                "is_error": is_error,
            })
        }
    }
}

impl Provider for AnthropicMessages {
    fn wire(&self) -> Wire {
        Wire::Messages
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            tool_use: true,
            streaming: true,
            vision: true,
            prompt_caching: true,
            thinking: true,
            parallel_tool_calls: true,
            max_context_tokens: self.cfg.max_context_tokens,
        }
    }

    fn stream<'a>(
        &'a self,
        req: &'a Request,
        cancel: CancellationToken,
    ) -> BoxFuture<'a, Result<EventStream, ProviderError>> {
        Box::pin(async move {
            let body = self.body(req).to_string();
            http::start_call(
                &self.cfg,
                &self.client,
                MESSAGES_PATH,
                body,
                &req.request_tag,
                || Box::new(MessagesDecoder::default()),
                cancel,
            )
            .await
        })
    }
}

// ===========================================================================
// SSE decoding
// ===========================================================================

/// A content block currently open on the stream, keyed by the wire's block index.
#[derive(Debug)]
enum OpenBlock {
    Text,
    Thinking,
    /// A tool call, accumulating its argument fragments.
    ToolUse {
        id: String,
        name: String,
        args: String,
    },
}

/// Parses the Messages event stream.
///
/// The events consumed are `message_start`, `content_block_start`, `content_block_delta`
/// (`text_delta`, `input_json_delta`, `thinking_delta`), `content_block_stop`,
/// `message_delta`, `message_stop`, `error` and `ping`. Anything else is ignored rather
/// than rejected — the wire adds event types over time, and a decoder that refused unknown
/// ones would break on a schema addition that does not concern it.
#[derive(Default)]
struct MessagesDecoder {
    blocks: std::collections::BTreeMap<u64, OpenBlock>,
    usage: Usage,
    stop_reason: Option<StopReason>,
    /// `message_stop` seen — the terminator this wire owes.
    terminated: bool,
    /// A terminal event has already been pushed; suppress anything after it.
    done: bool,
}

impl MessagesDecoder {
    fn push_terminal(&mut self, out: &mut Vec<Event>, ev: Event) {
        if !self.done {
            self.done = true;
            out.push(ev);
        }
    }
}

impl SseDecoder for MessagesDecoder {
    fn on_frame(&mut self, data: &str, out: &mut Vec<Event>) {
        if self.done {
            return;
        }
        let v: Value = match serde_json::from_str(data) {
            Ok(v) => v,
            Err(e) => {
                return self.push_terminal(
                    out,
                    Event::Error(ProviderError::Protocol(format!("frame was not JSON: {e}"))),
                )
            }
        };
        let kind = v.get("type").and_then(Value::as_str).unwrap_or("");
        match kind {
            "ping" => {}

            "message_start" => {
                if let Some(id) = v.pointer("/message/id").and_then(Value::as_str) {
                    self.usage.provider_request_id = Some(id.to_string());
                }
                // `message_start` carries the prompt-side counts; `message_delta` later
                // carries the cumulative output count. Both are merged into one `Usage`,
                // emitted once at `message_stop`.
                merge_usage(&mut self.usage, v.pointer("/message/usage"));
            }

            "content_block_start" => {
                let Some(index) = v.get("index").and_then(Value::as_u64) else {
                    return;
                };
                let block = v.get("content_block");
                match block.and_then(|b| b.get("type")).and_then(Value::as_str) {
                    Some("tool_use") => {
                        let id = block
                            .and_then(|b| b.get("id"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        let name = block
                            .and_then(|b| b.get("name"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        out.push(Event::ToolUseStart {
                            id: id.clone(),
                            name: name.clone(),
                        });
                        self.blocks.insert(
                            index,
                            OpenBlock::ToolUse {
                                id,
                                name,
                                args: String::new(),
                            },
                        );
                    }
                    Some("thinking") | Some("redacted_thinking") => {
                        self.blocks.insert(index, OpenBlock::Thinking);
                    }
                    _ => {
                        self.blocks.insert(index, OpenBlock::Text);
                    }
                }
            }

            "content_block_delta" => {
                let Some(index) = v.get("index").and_then(Value::as_u64) else {
                    return;
                };
                let delta = v.get("delta");
                let dtype = delta.and_then(|d| d.get("type")).and_then(Value::as_str);
                match dtype {
                    Some("text_delta") => {
                        if let Some(t) = delta.and_then(|d| d.get("text")).and_then(Value::as_str) {
                            out.push(Event::TextDelta(t.to_string()));
                        }
                    }
                    Some("thinking_delta") => {
                        if let Some(t) = delta
                            .and_then(|d| d.get("thinking"))
                            .and_then(Value::as_str)
                        {
                            out.push(Event::ThinkingDelta(t.to_string()));
                        }
                    }
                    Some("input_json_delta") => {
                        let frag = delta
                            .and_then(|d| d.get("partial_json"))
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        match self.blocks.get_mut(&index) {
                            Some(OpenBlock::ToolUse { id, args, .. }) => {
                                args.push_str(frag);
                                out.push(Event::ToolUseArgsDelta {
                                    id: id.clone(),
                                    json_fragment: frag.to_string(),
                                });
                            }
                            _ => {
                                self.push_terminal(
                                    out,
                                    Event::Error(ProviderError::Protocol(format!(
                                        "input_json_delta for block {index}, which is not an \
                                         open tool_use block"
                                    ))),
                                );
                            }
                        }
                    }
                    // `signature_delta` and any future delta type: ignored, not fatal.
                    _ => {}
                }
            }

            "content_block_stop" => {
                let Some(index) = v.get("index").and_then(Value::as_u64) else {
                    return;
                };
                if let Some(OpenBlock::ToolUse { id, name, args }) = self.blocks.remove(&index) {
                    // THE VALIDATION THAT MUST NOT BE SKIPPED. An accumulated argument
                    // string that does not parse is a Protocol error NAMING THE TOOL,
                    // never a silently-empty `{}`. Passing `{}` on instead would send
                    // the loop to call a tool with no arguments, which for most tools
                    // is a plausible-looking call that does the wrong thing — a far
                    // worse failure than a loud one.
                    //
                    // The empty string is the one exception, and it is not a
                    // violation: a no-argument tool legitimately streams no
                    // `input_json_delta` at all, and `{}` is what the wire means by it.
                    let text = if args.trim().is_empty() { "{}" } else { &args };
                    if let Err(e) = serde_json::from_str::<Value>(text) {
                        return self.push_terminal(
                            out,
                            Event::Error(ProviderError::Protocol(format!(
                                "tool {name:?} (id {id}) closed with arguments that are \
                                     not valid JSON: {e}"
                            ))),
                        );
                    }
                    out.push(Event::ToolUseEnd { id });
                }
            }

            "message_delta" => {
                if let Some(s) = v.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.stop_reason = Some(map_stop_reason(s));
                }
                merge_usage(&mut self.usage, v.get("usage"));
            }

            "message_stop" => {
                self.terminated = true;
                out.push(Event::Usage(self.usage.clone()));
                let stop_reason = self
                    .stop_reason
                    .clone()
                    // A `message_stop` with no `stop_reason` anywhere in the stream is
                    // out of contract, but it is a COMPLETED call, so it is reported as
                    // an unmapped stop reason rather than as a protocol failure that
                    // would discard a whole good answer.
                    .unwrap_or_else(|| StopReason::Other("unspecified".into()));
                self.push_terminal(out, Event::Done { stop_reason });
            }

            "error" => {
                let etype = v
                    .pointer("/error/type")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let message = v
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                // An in-band error names its own class; the status-code classifier never
                // sees these because the response was a 200.
                let err = match etype {
                    "overloaded_error" => ProviderError::Overloaded,
                    "rate_limit_error" => ProviderError::RateLimited { retry_after: None },
                    "authentication_error" | "permission_error" => ProviderError::Auth,
                    "not_found_error" => ProviderError::NotFound,
                    _ => ProviderError::BadRequest(http::redact(message)),
                };
                self.push_terminal(out, Event::Error(err));
            }

            _ => {}
        }
    }

    fn on_eof(&mut self, out: &mut Vec<Event>) {
        if self.done {
            return;
        }
        if !self.terminated {
            self.push_terminal(
                out,
                Event::Error(ProviderError::Protocol(
                    "stream ended without a message_stop".into(),
                )),
            );
        }
    }
}

/// Merge a wire `usage` object into the accumulating vector.
///
/// The counts arrive across two events and each is CUMULATIVE, so a present field
/// overwrites and an absent one leaves the previous value alone — `message_delta` reports
/// output tokens without repeating the prompt-side counts from `message_start`, and
/// treating that absence as zero would erase them.
///
/// `input_tokens` is taken VERBATIM. This wire already reports it excluding cache reads,
/// which is where [`Usage`]'s invariant comes from in the first place — there is nothing
/// to subtract here, and subtracting would double-count the discount.
fn merge_usage(usage: &mut Usage, v: Option<&Value>) {
    let Some(v) = v else { return };
    let get = |k: &str| v.get(k).and_then(Value::as_u64);
    if let Some(n) = get("input_tokens") {
        usage.input_tokens = Some(n);
    }
    if let Some(n) = get("output_tokens") {
        usage.output_tokens = Some(n);
    }
    if let Some(n) = get("cache_read_input_tokens") {
        usage.cache_read_tokens = Some(n);
    }
    if let Some(n) = get("cache_creation_input_tokens") {
        usage.cache_write_tokens = Some(n);
    }
}

/// Map this wire's `stop_reason` onto the neutral one.
fn map_stop_reason(s: &str) -> StopReason {
    match s {
        "end_turn" => StopReason::EndTurn,
        "tool_use" => StopReason::ToolUse,
        "max_tokens" => StopReason::MaxTokens,
        "stop_sequence" => StopReason::StopSequence,
        other => StopReason::Other(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{AuthScheme, Sampling, SystemBlock, ToolSpec};

    fn provider() -> AnthropicMessages {
        AnthropicMessages::new(ProviderConfig::new(
            Wire::Messages,
            "http://127.0.0.1:1",
            "test-model",
            AuthScheme::None,
        ))
    }

    fn decode(frames: &[&str]) -> Vec<Event> {
        let mut d = MessagesDecoder::default();
        let mut out = Vec::new();
        for f in frames {
            d.on_frame(f, &mut out);
        }
        d.on_eof(&mut out);
        out
    }

    #[test]
    fn thinking_levels_map_to_the_documented_budgets() {
        assert_eq!(thinking_budget_tokens(Thinking::Off, 4096), None);
        assert_eq!(thinking_budget_tokens(Thinking::Low, 4096), Some(1024));
        assert_eq!(thinking_budget_tokens(Thinking::Medium, 8192), Some(4096));
        assert_eq!(thinking_budget_tokens(Thinking::High, 65536), Some(16384));
    }

    #[test]
    fn a_thinking_budget_is_clamped_below_max_tokens() {
        // The API requires budget < max_tokens; a small cap must not produce a 400.
        assert_eq!(thinking_budget_tokens(Thinking::High, 512), Some(511));
        assert_eq!(thinking_budget_tokens(Thinking::Low, 1), Some(1));
    }

    #[test]
    fn temperature_is_dropped_when_thinking_is_on() {
        let p = provider();
        let req = Request {
            sampling: Sampling {
                max_output_tokens: 8192,
                temperature: Some(0.7),
                ..Default::default()
            },
            thinking: Thinking::Medium,
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = p.body(&req);
        assert_eq!(body.pointer("/thinking/budget_tokens"), Some(&json!(4096)));
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn temperature_survives_when_thinking_is_off() {
        let p = provider();
        let req = Request {
            sampling: Sampling {
                temperature: Some(0.7),
                ..Default::default()
            },
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = p.body(&req);
        assert_eq!(body.get("temperature"), Some(&json!(0.7)));
        assert!(body.get("thinking").is_none());
    }

    #[test]
    fn only_cacheable_system_blocks_get_a_cache_control() {
        let p = provider();
        let req = Request {
            system: vec![
                SystemBlock::cacheable("stable prefix"),
                SystemBlock::plain("today is Tuesday"),
            ],
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = p.body(&req);
        assert_eq!(
            body.pointer("/system/0/cache_control/type"),
            Some(&json!("ephemeral"))
        );
        assert!(body.pointer("/system/1/cache_control").is_none());
    }

    #[test]
    fn the_cache_breakpoint_lands_on_the_last_tool_only() {
        let p = provider();
        let tool = |n: &str| ToolSpec {
            name: n.into(),
            description: "d".into(),
            input_schema: json!({"type": "object"}),
            strict: true,
        };
        let req = Request {
            system: vec![SystemBlock::cacheable("prefix")],
            tools: vec![tool("a"), tool("b")],
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = p.body(&req);
        assert!(body.pointer("/tools/0/cache_control").is_none());
        assert_eq!(
            body.pointer("/tools/1/cache_control/type"),
            Some(&json!("ephemeral"))
        );
        // `strict` has no Messages equivalent and must not be smuggled onto the wire.
        assert!(body.pointer("/tools/0/strict").is_none());
        assert!(body.pointer("/tools/1/strict").is_none());
    }

    #[test]
    fn no_cacheable_system_block_means_no_tool_breakpoint_either() {
        let p = provider();
        let req = Request {
            system: vec![SystemBlock::plain("prefix")],
            tools: vec![ToolSpec {
                name: "a".into(),
                description: "d".into(),
                input_schema: json!({"type": "object"}),
                strict: false,
            }],
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        assert!(p.body(&req).pointer("/tools/0/cache_control").is_none());
    }

    #[test]
    fn a_tool_result_encodes_its_id_and_error_flag() {
        let p = provider();
        let req = Request {
            messages: vec![Message {
                role: Role::User,
                content: vec![ContentBlock::ToolResult {
                    id: "toolu_1".into(),
                    content: ToolResultContent::Text("boom".into()),
                    is_error: true,
                }],
            }],
            ..Default::default()
        };
        let body = p.body(&req);
        assert_eq!(
            body.pointer("/messages/0/content/0/tool_use_id"),
            Some(&json!("toolu_1"))
        );
        assert_eq!(
            body.pointer("/messages/0/content/0/is_error"),
            Some(&json!(true))
        );
    }

    #[test]
    fn input_tokens_are_taken_verbatim_because_they_already_exclude_cache_reads() {
        let events = decode(&[
            r#"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":5,"output_tokens":0}}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
            r#"{"type":"message_stop"}"#,
        ]);
        let usage = events
            .iter()
            .find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            })
            .expect("usage emitted");
        assert_eq!(usage.input_tokens, Some(10));
        assert_eq!(usage.cache_read_tokens, Some(900));
        assert_eq!(usage.cache_write_tokens, Some(5));
        // `message_delta` must not erase the prompt-side counts it does not repeat.
        assert_eq!(usage.output_tokens, Some(7));
        assert_eq!(usage.provider_request_id.as_deref(), Some("msg_1"));
    }

    #[test]
    fn a_tool_block_whose_arguments_are_not_json_is_a_protocol_error_naming_the_tool() {
        let events = decode(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"add"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
        ]);
        match events.last() {
            Some(Event::Error(ProviderError::Protocol(m))) => {
                assert!(m.contains("add"), "the tool is named: {m}");
                assert!(m.contains("toolu_1"));
            }
            other => panic!("expected a Protocol error, got {other:?}"),
        }
        // …and emphatically NOT a ToolUseEnd, which would let the loop call `add` with {}.
        assert!(!events.iter().any(|e| matches!(e, Event::ToolUseEnd { .. })));
    }

    #[test]
    fn a_no_argument_tool_closes_cleanly_as_an_empty_object() {
        let events = decode(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"now"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            r#"{"type":"message_stop"}"#,
        ]);
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::ToolUseEnd { id } if id == "toolu_1")));
    }

    #[test]
    fn an_arg_delta_for_an_unopened_block_is_a_protocol_error() {
        let events = decode(&[
            r#"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
        ]);
        assert!(matches!(
            events.first(),
            Some(Event::Error(ProviderError::Protocol(_)))
        ));
    }

    #[test]
    fn an_unknown_event_type_is_ignored_not_fatal() {
        let events = decode(&[
            r#"{"type":"some_future_event","whatever":1}"#,
            r#"{"type":"ping"}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            r#"{"type":"message_stop"}"#,
        ]);
        assert!(matches!(
            events.last(),
            Some(Event::Done {
                stop_reason: StopReason::EndTurn
            })
        ));
    }

    #[test]
    fn an_in_band_overloaded_error_maps_to_the_retryable_class() {
        let events =
            decode(&[r#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#]);
        assert_eq!(
            events.first(),
            Some(&Event::Error(ProviderError::Overloaded))
        );
    }

    #[test]
    fn stop_reasons_map_onto_the_neutral_vocabulary() {
        for (wire, want) in [
            ("end_turn", StopReason::EndTurn),
            ("tool_use", StopReason::ToolUse),
            ("max_tokens", StopReason::MaxTokens),
            ("stop_sequence", StopReason::StopSequence),
            ("refusal", StopReason::Other("refusal".into())),
        ] {
            assert_eq!(map_stop_reason(wire), want);
        }
    }
}
