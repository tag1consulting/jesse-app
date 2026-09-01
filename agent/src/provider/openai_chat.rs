//! **The OpenAI Chat Completions adapter** — `POST {base_url}/chat/completions`,
//! `stream: true`.
//!
//! Every OpenAI-shaped string in this crate lives in this file. This is the wire with the
//! most HOSTS behind it — `api.openai.com`, Fireworks, a local gateway, a vLLM server —
//! and correspondingly the most [`Quirks`](super::Quirks): the schema is imitated widely
//! and completely only in one place.

use serde_json::{json, Map, Value};
use tokio_util::sync::CancellationToken;

use super::http::{self, EventStream, SseDecoder};
use super::{
    BoxFuture, Capabilities, ContentBlock, Event, Message, Provider, ProviderConfig, ProviderError,
    Request, Role, StopReason, Thinking, ToolResultContent, Usage, Wire,
};

/// The path appended to `base_url`.
const CHAT_PATH: &str = "/chat/completions";

/// The sentinel that ends this wire's stream.
const DONE_SENTINEL: &str = "[DONE]";

/// The `reasoning_effort` value for each neutral [`Thinking`] level.
///
/// A straight name-for-name mapping, because this wire's parameter is already an
/// enumerated effort rather than a budget — which is exactly why [`Thinking`] is an
/// enumeration and not a token count (see its doc). `Off` sends nothing.
fn reasoning_effort(level: Thinking) -> Option<&'static str> {
    match level {
        Thinking::Off => None,
        Thinking::Low => Some("low"),
        Thinking::Medium => Some("medium"),
        Thinking::High => Some("high"),
    }
}

/// The OpenAI Chat Completions wire.
pub struct OpenAiChat {
    cfg: ProviderConfig,
    client: reqwest::Client,
}

impl OpenAiChat {
    pub fn new(cfg: ProviderConfig) -> Self {
        let client = http::build_client(&cfg);
        OpenAiChat { cfg, client }
    }

    /// The request body.
    pub(crate) fn body(&self, req: &Request) -> Value {
        let mut body = Map::new();
        body.insert("model".into(), json!(self.cfg.model));
        body.insert("stream".into(), json!(true));
        // WITHOUT THIS, THERE IS NO USAGE AT ALL on a streamed Chat call: the terminal
        // usage chunk is opt-in on this wire, and its absence is silent. A turn that
        // reported no tokens would be a turn the cost model cannot price, so this is not
        // optional and is not configurable.
        body.insert("stream_options".into(), json!({"include_usage": true}));
        body.insert(
            "max_completion_tokens".into(),
            json!(req.sampling.max_output_tokens),
        );

        // ---- Messages ------------------------------------------------------
        let mut messages: Vec<Value> = Vec::new();

        // THE SYSTEM PREFIX IS CONCATENATED INTO ONE LEADING `system` MESSAGE by default.
        // This wire has no per-block cache control, so the block structure carries no
        // information here — and several hosts accept only one system message (see
        // `Quirks::multiple_system_messages`). Joining with a blank line preserves the
        // block boundaries a reader would expect without inventing a delimiter.
        if !req.system.is_empty() {
            if self.cfg.quirks.multiple_system_messages {
                for b in &req.system {
                    messages.push(json!({"role": "system", "content": b.text}));
                }
            } else {
                let joined = req
                    .system
                    .iter()
                    .map(|b| b.text.as_str())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                messages.push(json!({"role": "system", "content": joined}));
            }
        }

        for m in &req.messages {
            encode_message(m, &mut messages);
        }
        body.insert("messages".into(), Value::Array(messages));

        // ---- Tools ---------------------------------------------------------
        //
        // NO CACHE CONTROL ANYWHERE on this wire. Caching here is automatic and
        // server-side; there is no breakpoint to place, so `SystemBlock::cacheable` is
        // inert. It is inert rather than an error because the same neutral `Request` has
        // to be valid on every wire — see `Capabilities::prompt_caching` for how a caller
        // asks whether it did anything.
        if !req.tools.is_empty() {
            let tools: Vec<Value> = req
                .tools
                .iter()
                .map(|t| {
                    let mut f = Map::new();
                    f.insert("name".into(), json!(t.name));
                    f.insert("description".into(), json!(t.description));
                    f.insert("parameters".into(), t.input_schema.clone());
                    if t.strict {
                        if self.cfg.quirks.strict_tools_supported {
                            f.insert("strict".into(), json!(true));
                        } else {
                            eprintln!(
                                "jesse-agent: note wire=chat tag={:?} dropped strict on tool \
                                 {:?} (host is not configured as supporting it)",
                                req.request_tag, t.name
                            );
                        }
                    }
                    json!({"type": "function", "function": Value::Object(f)})
                })
                .collect();
            body.insert("tools".into(), Value::Array(tools));
        }

        if let Some(t) = req.sampling.temperature {
            body.insert("temperature".into(), json!(t));
        }
        if !req.sampling.stop_sequences.is_empty() {
            body.insert("stop".into(), json!(req.sampling.stop_sequences));
        }

        // ---- Thinking ------------------------------------------------------
        if let Some(effort) = reasoning_effort(req.thinking) {
            if self.cfg.quirks.reasoning_effort_supported {
                body.insert("reasoning_effort".into(), json!(effort));
            } else {
                // LOGGED, NEVER SILENT. A caller that asked for thinking and got none has
                // been given a materially different answer than it requested; the note is
                // what makes that discoverable without a packet capture.
                eprintln!(
                    "jesse-agent: note wire=chat tag={:?} dropped reasoning_effort={effort} \
                     (host is not configured as supporting it)",
                    req.request_tag
                );
            }
        }

        Value::Object(body)
    }
}

/// Encode one neutral message, appending one or more wire messages.
///
/// ONE NEUTRAL MESSAGE CAN BECOME SEVERAL. This wire puts each tool result in its OWN
/// `role: "tool"` message, whereas the neutral model (following the Messages shape)
/// carries them as blocks of one user message. That fan-out is why this takes a sink
/// rather than returning a value.
fn encode_message(m: &Message, out: &mut Vec<Value>) {
    // Tool results first: they must precede any other content of the same turn, because
    // this wire pairs them positionally with the assistant `tool_calls` message before it.
    for b in &m.content {
        if let ContentBlock::ToolResult {
            id,
            content,
            is_error,
        } = b
        {
            let text = match content {
                ToolResultContent::Text(t) => t.clone(),
                // Blocks are flattened to text: `role: "tool"` messages take a string
                // content on this wire, so a tool that returned an image cannot be
                // represented faithfully here. A placeholder is emitted rather than
                // dropping the block silently, so the model is told something was there.
                ToolResultContent::Blocks(bs) => bs
                    .iter()
                    .map(|b| match b {
                        ContentBlock::Text(t) => t.clone(),
                        ContentBlock::Image { media_type, .. } => {
                            format!("[{media_type} omitted: this wire's tool results are text]")
                        }
                        _ => String::new(),
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            };
            // `is_error` has no field on this wire. Prefixing is the only representation
            // available, and saying nothing was rejected: the model would read a failure
            // as a successful result.
            let text = if *is_error {
                format!("Error: {text}")
            } else {
                text
            };
            out.push(json!({"role": "tool", "tool_call_id": id, "content": text}));
        }
    }

    let mut parts: Vec<Value> = Vec::new();
    let mut tool_calls: Vec<Value> = Vec::new();
    for b in &m.content {
        match b {
            ContentBlock::Text(t) => parts.push(json!({"type": "text", "text": t})),
            ContentBlock::Image {
                media_type,
                data_base64,
            } => parts.push(json!({
                "type": "image_url",
                // A data URL, which is how this wire carries inline bytes. The neutral
                // model stores base64 precisely because both wires want it that way.
                "image_url": {"url": format!("data:{media_type};base64,{data_base64}")},
            })),
            ContentBlock::ToolUse {
                id,
                name,
                arguments,
            } => tool_calls.push(json!({
                "id": id,
                "type": "function",
                // Arguments go back as a STRING on this wire, not an object — the same
                // shape they arrive in. `to_string` on the parsed value round-trips it.
                "function": {"name": name, "arguments": arguments.to_string()},
            })),
            ContentBlock::ToolResult { .. } => {}
            // THE ABSENCE CASE, AND SKIPPING IS THE CORRECT BEHAVIOUR. This wire has no
            // reasoning artefact to echo: Chat Completions returns no signed thinking block
            // and no encrypted reasoning item, so there is nothing here that a following
            // request could carry and nothing that omitting one could break. A reasoning
            // block reaching this adapter came from a turn that ran on another wire, and the
            // right response to it is to send the message without it rather than to refuse a
            // request this wire can serve perfectly well. This adapter never MINTS one
            // either, so in a turn that stayed on this wire the arm is unreachable.
            ContentBlock::Reasoning { .. } => {}
        }
    }

    if parts.is_empty() && tool_calls.is_empty() {
        return;
    }

    let role = match m.role {
        Role::User => "user",
        Role::Assistant => "assistant",
    };
    let mut msg = Map::new();
    msg.insert("role".into(), json!(role));
    if !parts.is_empty() {
        msg.insert("content".into(), Value::Array(parts));
    }
    if !tool_calls.is_empty() {
        msg.insert("tool_calls".into(), Value::Array(tool_calls));
    }
    out.push(Value::Object(msg));
}

impl Provider for OpenAiChat {
    fn wire(&self) -> Wire {
        Wire::Chat
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            tool_use: true,
            streaming: true,
            vision: true,
            // NO PROMPT CACHING the caller can control. Hosts on this wire cache
            // automatically or not at all; either way there is no breakpoint to place, so
            // reporting `true` would tell a caller it can influence something it cannot.
            prompt_caching: false,
            // Only where the host takes `reasoning_effort` — the capability tracks the
            // quirk, so a caller reading this gets the answer for THIS deployment rather
            // than for the schema in the abstract.
            thinking: self.cfg.quirks.reasoning_effort_supported,
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
                CHAT_PATH,
                body,
                &req.request_tag,
                || Box::new(ChatDecoder::default()),
                cancel,
            )
            .await
        })
    }
}

// ===========================================================================
// SSE decoding
// ===========================================================================

/// A tool call being accumulated, keyed by the wire's `tool_calls[].index`.
#[derive(Debug, Default)]
struct PartialCall {
    id: String,
    name: String,
    args: String,
    /// `ToolUseStart` has been emitted for this index.
    started: bool,
}

/// Parses the Chat Completions event stream.
///
/// TOOL CALLS ARE KEYED BY `index`, NOT BY `id`, and that is forced by the wire: only the
/// first fragment of a call carries `id` and `name`, and every later fragment identifies
/// itself by `index` alone. Keying on `id` would mean dropping every continuation.
#[derive(Default)]
struct ChatDecoder {
    calls: std::collections::BTreeMap<u64, PartialCall>,
    usage: Usage,
    stop_reason: Option<StopReason>,
    /// `[DONE]` seen — the terminator this wire owes.
    terminated: bool,
    /// Tool calls have been closed out (at the first `finish_reason`).
    flushed: bool,
    done: bool,
}

impl ChatDecoder {
    fn push_terminal(&mut self, out: &mut Vec<Event>, ev: Event) {
        if !self.done {
            self.done = true;
            out.push(ev);
        }
    }

    /// Close every accumulated tool call, validating its arguments.
    ///
    /// Returns `false` when a call's arguments did not parse, having pushed the
    /// [`ProviderError::Protocol`] naming the tool.
    fn flush_tool_calls(&mut self, out: &mut Vec<Event>) -> bool {
        if self.flushed {
            return true;
        }
        self.flushed = true;
        let calls = std::mem::take(&mut self.calls);
        for (_, c) in calls {
            if !c.started {
                continue;
            }
            // Same rule as the Messages adapter: an empty argument string is a
            // no-argument call, anything else must parse, and a failure names the tool
            // rather than passing `{}` on to the loop.
            let text = if c.args.trim().is_empty() {
                "{}"
            } else {
                &c.args
            };
            if let Err(e) = serde_json::from_str::<Value>(text) {
                self.push_terminal(
                    out,
                    Event::Error(ProviderError::Protocol(format!(
                        "tool {:?} (id {}) closed with arguments that are not valid JSON: {e}",
                        c.name, c.id
                    ))),
                );
                return false;
            }
            out.push(Event::ToolUseEnd { id: c.id });
        }
        true
    }
}

impl SseDecoder for ChatDecoder {
    fn on_frame(&mut self, data: &str, out: &mut Vec<Event>) {
        if self.done {
            return;
        }
        let data = data.trim();
        if data.is_empty() {
            return;
        }

        if data == DONE_SENTINEL {
            self.terminated = true;
            if !self.flush_tool_calls(out) {
                return;
            }
            out.push(Event::Usage(self.usage.clone()));
            match self.stop_reason.clone() {
                Some(stop_reason) => self.push_terminal(out, Event::Done { stop_reason }),
                // `[DONE]` with no `finish_reason` anywhere means the wire never said why
                // it stopped. Unlike the Messages adapter's equivalent case, this one IS
                // a protocol violation: `finish_reason` is mandatory on the final chunk of
                // every choice, so its absence means the stream was cut, not that a field
                // was omitted.
                None => self.push_terminal(
                    out,
                    Event::Error(ProviderError::Protocol(
                        "stream ended with [DONE] but no finish_reason".into(),
                    )),
                ),
            }
            return;
        }

        let v: Value = match serde_json::from_str(data) {
            Ok(v) => v,
            Err(e) => {
                return self.push_terminal(
                    out,
                    Event::Error(ProviderError::Protocol(format!("chunk was not JSON: {e}"))),
                )
            }
        };

        // An in-band error object on a 200 response — several hosts on this wire report
        // mid-stream failures this way rather than by closing the connection.
        if let Some(message) = v.pointer("/error/message").and_then(Value::as_str) {
            return self.push_terminal(
                out,
                Event::Error(ProviderError::BadRequest(http::redact(message))),
            );
        }

        if self.usage.provider_request_id.is_none() {
            if let Some(id) = v.get("id").and_then(Value::as_str) {
                self.usage.provider_request_id = Some(id.to_string());
            }
        }

        // The terminal usage chunk carries `usage` with an empty `choices` array.
        if let Some(u) = v.get("usage").filter(|u| !u.is_null()) {
            apply_usage(&mut self.usage, u);
        }

        let Some(choices) = v.get("choices").and_then(Value::as_array) else {
            return;
        };
        for choice in choices {
            if let Some(text) = choice
                .pointer("/delta/content")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                out.push(Event::TextDelta(text.to_string()));
            }

            // Some hosts on this wire stream reasoning as `delta.reasoning_content`.
            // Delivered when present, never required — see `Event::ThinkingDelta`.
            if let Some(text) = choice
                .pointer("/delta/reasoning_content")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                out.push(Event::ThinkingDelta(text.to_string()));
            }

            if let Some(calls) = choice
                .pointer("/delta/tool_calls")
                .and_then(Value::as_array)
            {
                for c in calls {
                    // A missing `index` means a single call on a host that omits it;
                    // defaulting to 0 keeps those hosts working rather than dropping the
                    // call, and a host that omits the index cannot be streaming two.
                    let index = c.get("index").and_then(Value::as_u64).unwrap_or(0);
                    let entry = self.calls.entry(index).or_default();
                    if let Some(id) = c.get("id").and_then(Value::as_str) {
                        if !id.is_empty() {
                            entry.id = id.to_string();
                        }
                    }
                    if let Some(name) = c.pointer("/function/name").and_then(Value::as_str) {
                        if !name.is_empty() {
                            entry.name = name.to_string();
                        }
                    }
                    // `ToolUseStart` fires as soon as BOTH an id and a name are known —
                    // not on the first fragment, because a host may send `id` and
                    // `function.name` in separate chunks and the neutral event promises
                    // both.
                    if !entry.started && !entry.id.is_empty() && !entry.name.is_empty() {
                        entry.started = true;
                        out.push(Event::ToolUseStart {
                            id: entry.id.clone(),
                            name: entry.name.clone(),
                        });
                    }
                    if let Some(frag) = c
                        .pointer("/function/arguments")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                    {
                        entry.args.push_str(frag);
                        if entry.started {
                            out.push(Event::ToolUseArgsDelta {
                                id: entry.id.clone(),
                                json_fragment: frag.to_string(),
                            });
                        }
                    }
                }
            }

            if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
                self.stop_reason = Some(map_finish_reason(reason));
                // Tool calls close HERE rather than at `[DONE]`: the choice is finished,
                // so no further fragments can arrive, and closing now means `ToolUseEnd`
                // precedes the usage chunk in the event order the docs promise.
                if !self.flush_tool_calls(out) {
                    return;
                }
            }
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
                    "stream ended without a [DONE] sentinel".into(),
                )),
            );
        }
    }
}

/// Apply this wire's `usage` object, NORMALISING IT to the invariant on [`Usage`].
///
/// THE SUBTRACTION, and why it has to happen here. This wire reports `prompt_tokens`
/// INCLUSIVE of `prompt_tokens_details.cached_tokens` — the cached tokens are a subset of
/// the prompt total, not a sibling of it. The Anthropic wire reports the two DISJOINT.
/// [`Usage`] documents the disjoint convention, so this adapter subtracts:
///
/// ```text
///     input_tokens      = prompt_tokens - cached_tokens
///     cache_read_tokens = cached_tokens
/// ```
///
/// Without it, a cached turn's prompt tokens would be counted twice — once at the input
/// rate and once at the cache-read rate — and every cost figure derived from it would be
/// wrong in the direction of "caching made things more expensive". Saturating subtraction
/// because a host reporting `cached > prompt` is reporting nonsense, and a panic on a
/// billing field is worse than a zero.
///
/// `cache_write_tokens` stays `None`: this wire has no equivalent field. That is a genuine
/// absence and not a zero, which is why the field is `Option` (see [`Usage`]).
fn apply_usage(usage: &mut Usage, v: &Value) {
    let prompt = v.get("prompt_tokens").and_then(Value::as_u64);
    let cached = v
        .pointer("/prompt_tokens_details/cached_tokens")
        .and_then(Value::as_u64);
    if let Some(p) = prompt {
        usage.input_tokens = Some(p.saturating_sub(cached.unwrap_or(0)));
    }
    if let Some(c) = cached {
        usage.cache_read_tokens = Some(c);
    }
    if let Some(n) = v.get("completion_tokens").and_then(Value::as_u64) {
        usage.output_tokens = Some(n);
    }
}

/// Map this wire's `finish_reason` onto the neutral vocabulary.
fn map_finish_reason(s: &str) -> StopReason {
    match s {
        "stop" => StopReason::EndTurn,
        "tool_calls" | "function_call" => StopReason::ToolUse,
        "length" => StopReason::MaxTokens,
        other => StopReason::Other(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{AuthScheme, Quirks, Sampling, SystemBlock, ToolSpec};

    fn provider_with(quirks: Quirks) -> OpenAiChat {
        let mut cfg = ProviderConfig::new(
            Wire::Chat,
            "http://127.0.0.1:1",
            "test-model",
            AuthScheme::None,
        );
        cfg.quirks = quirks;
        OpenAiChat::new(cfg)
    }

    fn provider() -> OpenAiChat {
        provider_with(Quirks::default())
    }

    fn decode(frames: &[&str]) -> Vec<Event> {
        let mut d = ChatDecoder::default();
        let mut out = Vec::new();
        for f in frames {
            d.on_frame(f, &mut out);
        }
        d.on_eof(&mut out);
        out
    }

    #[test]
    fn usage_is_included_because_it_is_opt_in_on_this_wire() {
        let body = provider().body(&Request::default());
        assert_eq!(
            body.pointer("/stream_options/include_usage"),
            Some(&json!(true))
        );
    }

    #[test]
    fn the_system_prefix_becomes_one_leading_message_by_default() {
        let req = Request {
            system: vec![
                SystemBlock::cacheable("stable"),
                SystemBlock::plain("today"),
            ],
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = provider().body(&req);
        assert_eq!(body.pointer("/messages/0/role"), Some(&json!("system")));
        assert_eq!(
            body.pointer("/messages/0/content"),
            Some(&json!("stable\n\ntoday"))
        );
        assert_eq!(body.pointer("/messages/1/role"), Some(&json!("user")));
        // Nothing anywhere on this wire carries a cache breakpoint.
        assert!(
            !body.to_string().contains("cache_control"),
            "cache_control leaked onto the chat wire"
        );
    }

    #[test]
    fn the_multiple_system_messages_quirk_keeps_the_blocks_separate() {
        let p = provider_with(Quirks {
            multiple_system_messages: true,
            ..Default::default()
        });
        let req = Request {
            system: vec![SystemBlock::plain("a"), SystemBlock::plain("b")],
            ..Default::default()
        };
        let body = p.body(&req);
        assert_eq!(body.pointer("/messages/0/content"), Some(&json!("a")));
        assert_eq!(body.pointer("/messages/1/content"), Some(&json!("b")));
    }

    #[test]
    fn reasoning_effort_is_sent_only_when_the_quirk_is_on() {
        let req = Request {
            thinking: Thinking::High,
            ..Default::default()
        };
        let off = provider().body(&req);
        assert!(off.get("reasoning_effort").is_none());

        let on = provider_with(Quirks {
            reasoning_effort_supported: true,
            ..Default::default()
        })
        .body(&req);
        assert_eq!(on.get("reasoning_effort"), Some(&json!("high")));
    }

    #[test]
    fn strict_is_passed_through_only_when_the_quirk_is_on() {
        let req = Request {
            tools: vec![ToolSpec {
                name: "add".into(),
                description: "d".into(),
                input_schema: json!({"type": "object"}),
                strict: true,
            }],
            ..Default::default()
        };
        assert!(provider()
            .body(&req)
            .pointer("/tools/0/function/strict")
            .is_none());
        let on = provider_with(Quirks {
            strict_tools_supported: true,
            ..Default::default()
        })
        .body(&req);
        assert_eq!(on.pointer("/tools/0/function/strict"), Some(&json!(true)));
        // The schema goes in `parameters` on this wire, not `input_schema`.
        assert!(on.pointer("/tools/0/function/parameters").is_some());
    }

    #[test]
    fn thinking_capability_tracks_the_quirk_not_the_schema() {
        assert!(!provider().capabilities().thinking);
        assert!(
            provider_with(Quirks {
                reasoning_effort_supported: true,
                ..Default::default()
            })
            .capabilities()
            .thinking
        );
    }

    #[test]
    fn an_image_becomes_a_data_url() {
        let req = Request {
            messages: vec![Message {
                role: Role::User,
                content: vec![ContentBlock::Image {
                    media_type: "image/png".into(),
                    data_base64: "QUJD".into(),
                }],
            }],
            ..Default::default()
        };
        let body = provider().body(&req);
        assert_eq!(
            body.pointer("/messages/0/content/0/image_url/url"),
            Some(&json!("data:image/png;base64,QUJD"))
        );
    }

    #[test]
    fn a_tool_result_becomes_its_own_role_tool_message() {
        let req = Request {
            messages: vec![
                Message {
                    role: Role::Assistant,
                    content: vec![ContentBlock::ToolUse {
                        id: "call_1".into(),
                        name: "add".into(),
                        arguments: json!({"a": 1}),
                    }],
                },
                Message {
                    role: Role::User,
                    content: vec![ContentBlock::ToolResult {
                        id: "call_1".into(),
                        content: ToolResultContent::Text("2".into()),
                        is_error: false,
                    }],
                },
            ],
            ..Default::default()
        };
        let body = provider().body(&req);
        // Arguments go back as a STRING, which is the shape this wire sends and expects.
        assert_eq!(
            body.pointer("/messages/0/tool_calls/0/function/arguments"),
            Some(&json!(r#"{"a":1}"#))
        );
        assert_eq!(body.pointer("/messages/1/role"), Some(&json!("tool")));
        assert_eq!(
            body.pointer("/messages/1/tool_call_id"),
            Some(&json!("call_1"))
        );
    }

    #[test]
    fn a_failed_tool_result_says_so_in_the_only_field_this_wire_has() {
        let req = Request {
            messages: vec![Message {
                role: Role::User,
                content: vec![ContentBlock::ToolResult {
                    id: "call_1".into(),
                    content: ToolResultContent::Text("boom".into()),
                    is_error: true,
                }],
            }],
            ..Default::default()
        };
        let body = provider().body(&req);
        assert_eq!(
            body.pointer("/messages/0/content"),
            Some(&json!("Error: boom"))
        );
    }

    #[test]
    fn max_tokens_uses_the_current_field_name() {
        let req = Request {
            sampling: Sampling {
                max_output_tokens: 77,
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(
            provider().body(&req).get("max_completion_tokens"),
            Some(&json!(77))
        );
    }

    #[test]
    fn cached_tokens_are_subtracted_so_the_invariant_holds() {
        let events = decode(&[
            r#"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#,
            r#"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            r#"{"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":900}}}"#,
            DONE_SENTINEL,
        ]);
        let usage = events
            .iter()
            .find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            })
            .expect("usage emitted");
        // prompt_tokens (1000) INCLUDES cached (900); the neutral vector is disjoint.
        assert_eq!(usage.input_tokens, Some(100));
        assert_eq!(usage.cache_read_tokens, Some(900));
        assert_eq!(usage.output_tokens, Some(7));
        // A genuine absence, not a zero: this wire has no cache-write count.
        assert_eq!(usage.cache_write_tokens, None);
        assert_eq!(usage.provider_request_id.as_deref(), Some("chatcmpl-1"));
    }

    #[test]
    fn usage_without_a_cached_detail_leaves_prompt_tokens_alone() {
        let events = decode(&[
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            r#"{"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":3}}"#,
            DONE_SENTINEL,
        ]);
        let usage = events
            .iter()
            .find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(usage.input_tokens, Some(42));
        assert_eq!(usage.cache_read_tokens, None);
    }

    #[test]
    fn tool_call_fragments_accumulate_by_index() {
        let events = decode(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"add","arguments":"{\"a\":"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1,\"b\":"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"2}"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            DONE_SENTINEL,
        ]);
        assert!(matches!(
            events.first(),
            Some(Event::ToolUseStart { name, .. }) if name == "add"
        ));
        let frags: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                Event::ToolUseArgsDelta { json_fragment, .. } => Some(json_fragment.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(frags.len(), 3, "three fragments, delivered as framed");
        assert_eq!(frags.concat(), r#"{"a":1,"b":2}"#);
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::ToolUseEnd { id } if id == "call_1")));
    }

    #[test]
    fn a_tool_call_with_unparseable_arguments_is_a_protocol_error_naming_the_tool() {
        let events = decode(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"add","arguments":"{\"a\":"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            DONE_SENTINEL,
        ]);
        match events.last() {
            Some(Event::Error(ProviderError::Protocol(m))) => {
                assert!(m.contains("add"), "the tool is named: {m}");
            }
            other => panic!("expected a Protocol error, got {other:?}"),
        }
        assert!(!events.iter().any(|e| matches!(e, Event::ToolUseEnd { .. })));
    }

    #[test]
    fn a_stream_that_stops_before_done_is_a_protocol_error() {
        let events = decode(&[r#"{"choices":[{"index":0,"delta":{"content":"partial"}}]}"#]);
        assert!(matches!(
            events.last(),
            Some(Event::Error(ProviderError::Protocol(_)))
        ));
    }

    #[test]
    fn done_without_a_finish_reason_is_a_protocol_error() {
        let events = decode(&[
            r#"{"choices":[{"index":0,"delta":{"content":"hi"}}]}"#,
            DONE_SENTINEL,
        ]);
        assert!(matches!(
            events.last(),
            Some(Event::Error(ProviderError::Protocol(_)))
        ));
    }

    #[test]
    fn finish_reasons_map_onto_the_neutral_vocabulary() {
        for (wire, want) in [
            ("stop", StopReason::EndTurn),
            ("tool_calls", StopReason::ToolUse),
            ("function_call", StopReason::ToolUse),
            ("length", StopReason::MaxTokens),
            ("content_filter", StopReason::Other("content_filter".into())),
        ] {
            assert_eq!(map_finish_reason(wire), want);
        }
    }

    #[test]
    fn an_in_band_error_object_ends_the_stream() {
        let events = decode(&[r#"{"error":{"message":"model overloaded, try later"}}"#]);
        assert!(matches!(
            events.first(),
            Some(Event::Error(ProviderError::BadRequest(_)))
        ));
    }
}
