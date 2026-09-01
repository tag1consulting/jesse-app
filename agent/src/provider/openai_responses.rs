//! **The OpenAI Responses adapter** — `POST {base_url}/responses`, `stream: true`,
//! `store: false`.
//!
//! THE THIRD ADAPTER, AND THE ONE WRITTEN AFTER THE TRAIT SETTLED. The first two were
//! written together and could have agreed with each other by construction; this one was
//! written against a wire with a different shape — stateful by default, carrying ITEMS
//! rather than messages, reporting a status rather than a finish reason — to find out
//! whether [`super::Provider`] is a real abstraction or two adapters wearing one hat.
//! Every place the trait leaked is written down in `agent/LEAKS.md`, refuted or fixed.
//!
//! ---- WHAT IS DIFFERENT ABOUT THIS WIRE, in the order it bites --------------
//!
//!   * **It is STATEFUL BY DEFAULT.** `store` defaults to `true`, and a stored response can
//!     be continued with `previous_response_id` instead of re-sending the conversation.
//!     This adapter sends `store: false` on every request and never sends
//!     `previous_response_id`. See [`OpenAiResponses::body`] for why, in privacy terms.
//!   * **The prompt is a list of ITEMS, not a list of messages.** A tool call and its
//!     result are TOP-LEVEL items (`function_call`, `function_call_output`), siblings of a
//!     message rather than content inside one.
//!   * **A tool call has TWO ids.** The item id (`fc_…`) is what the stream's deltas are
//!     keyed by; the `call_id` (`call_…`) is what a result must be addressed to. The
//!     neutral model has one id, and this adapter resolves the difference — see
//!     [`ResponsesDecoder`].
//!   * **There is no `finish_reason`.** The response carries a STATUS (`completed`,
//!     `incomplete`, `failed`) and, when incomplete, a reason. "The model wants a tool
//!     called" is not reported at all: it is derived from whether the output contained a
//!     `function_call` item. See [`ResponsesDecoder::completion_stop_reason`].
//!   * **Usage is never opt-in.** Unlike the Chat wire, where the terminal usage chunk has
//!     to be asked for with `stream_options`, `response.completed` always carries `usage`
//!     — and it carries MORE of it: a cache-WRITE count and a reasoning-token count, both
//!     of which the Chat wire has no field for.
//!
//! Everything else — the client, the retry policy, redaction, the audit line, the SSE
//! framer — is [`super::http`]'s, unchanged and unforked, which is the property that makes
//! "all three adapters behave identically" a claim the conformance suite can check.

use std::collections::HashMap;

use serde_json::{json, Map, Value};
use tokio_util::sync::CancellationToken;

use super::http::{self, EventStream, SseDecoder};
use super::{
    BoxFuture, Capabilities, ContentBlock, Event, Message, Provider, ProviderConfig, ProviderError,
    ReasoningOrigin, Request, Role, StopReason, Thinking, ToolResultContent, Usage, Wire,
};

/// The path appended to `base_url`.
///
/// `base_url` is the API ROOT — the segment BEFORE `/responses`, e.g.
/// `https://api.openai.com/v1`. That is the same convention the bridge's Codex harness
/// already documents for this surface (`jesse.example.toml`: "NOTE THE `/v1` ON base_url"),
/// and it is deliberately NOT the Messages convention, where the base is a bare host and
/// the adapter appends `/v1/messages`. The wire decides; the config note says so out loud
/// because swapping the two yields a model that is armed, correct-looking and permanently
/// unreachable.
const RESPONSES_PATH: &str = "/responses";

/// The `reasoning.effort` value for each neutral [`Thinking`] level.
///
/// The SAME three strings the Chat wire's `reasoning_effort` takes, which is not a
/// coincidence: both are OpenAI's enumerated effort, and it is why [`Thinking`] is an
/// enumeration rather than a token budget. `Off` sends no `reasoning` object at all —
/// the schema does have an `effort: "none"`, but omitting the field is what every host
/// serving this surface accepts, and a value only OpenAI's own models take would be a
/// worse default than silence.
fn reasoning_effort(level: Thinking) -> Option<&'static str> {
    match level {
        Thinking::Off => None,
        Thinking::Low => Some("low"),
        Thinking::Medium => Some("medium"),
        Thinking::High => Some("high"),
    }
}

/// The OpenAI Responses wire.
pub struct OpenAiResponses {
    cfg: ProviderConfig,
    client: reqwest::Client,
}

impl OpenAiResponses {
    pub fn new(cfg: ProviderConfig) -> Self {
        let client = http::build_client(&cfg);
        OpenAiResponses { cfg, client }
    }

    /// The request body.
    ///
    /// ---- `store: false`, ON EVERY REQUEST, AND WHY IT IS NOT CONFIGURABLE -----
    ///
    /// This wire's `store` defaults to **`true`**: unless a request says otherwise, the
    /// provider KEEPS the response — prompt, tool calls and answer — server-side, for
    /// later retrieval by id. That default is fine for the product this API was designed
    /// for and wrong for this one, for three reasons that all point the same way:
    ///
    ///   * **The loop owns the thread.** `thread.rs` already stores the conversation, on
    ///     this machine, mode 0600. A provider-side copy is a SECOND copy of the same
    ///     conversation, in a place the owner cannot enumerate, cannot diff against theirs
    ///     and cannot delete from the loop. Two systems of record for one conversation is
    ///     how "the assistant forgot" and "the assistant remembered something it should
    ///     not have" become the same bug.
    ///   * **The content is a vault.** The turns this crate serves carry the owner's own
    ///     documents — that is the entire point of `tools::vault`. The visibility rules
    ///     the store enforces (cold documents refused, excluded documents absent) are
    ///     enforced at read time, on this host; nothing about them survives into a
    ///     provider's retention. Storing the transcript would move vault content into a
    ///     retention policy the owner never agreed to and cannot inspect.
    ///   * **It is the reversible direction.** `store: false` costs a re-send of the
    ///     prompt each iteration, which the loop does anyway — it re-sends the whole
    ///     thread every turn by construction. Storing costs a copy that cannot be
    ///     un-made.
    ///
    /// So it is a constant, not a [`super::Quirks`] toggle and not a [`Request`] field. A
    /// knob whose only defensible value is one value is not a knob; it is a way for a
    /// future config edit to turn the property off without anyone deciding to.
    ///
    /// **`previous_response_id` is never sent, for the same reason and one more.** It is
    /// the *use* of the stored copy, so it cannot work with `store: false` anyway; and
    /// even where it could, it would mean the model's context was assembled from state the
    /// loop cannot see, which is the property `thread.rs` exists to deny.
    ///
    /// **WHAT THIS USED TO COST, AND NO LONGER DOES.** `store: false` means there is no
    /// server-side copy of the reasoning to replay, so until D13 a reasoning model
    /// re-derived its own thinking on every iteration of a tool loop — the wire's stateless
    /// mechanism needs a block that can carry an opaque artefact, and the neutral model had
    /// none. That was `LEAKS.md` L5, and it is now MADE: this request sends
    /// `include: ["reasoning.encrypted_content"]`, the decoder captures each finished
    /// `reasoning` item into [`ContentBlock::Reasoning`], and `encode_message` echoes it
    /// back in `input`. `store: false` is unchanged and is not up for revision — the
    /// continuity comes from the loop carrying the item, not from the provider keeping it.
    pub(crate) fn body(&self, req: &Request) -> Result<Value, ProviderError> {
        let mut body = Map::new();
        body.insert("model".into(), json!(self.cfg.model));
        body.insert("stream".into(), json!(true));
        // The whole privacy posture of this adapter, in one line. See the doc above.
        body.insert("store".into(), json!(false));
        // REASONING CONTINUITY, STATELESSLY. With `store: false` the provider keeps nothing
        // to replay, so the encrypted reasoning items have to come back to us in order to
        // go back out on the next iteration of a turn. Current documentation says the items
        // carry `encrypted_content` by default under `store: false` and that this `include`
        // value is accepted for backward compatibility rather than required — it is sent
        // anyway, because a host that predates that change needs it and one that follows it
        // accepts it, and the failure it prevents is a silent loss of continuity rather
        // than an error anyone would see.
        body.insert("include".into(), json!(["reasoning.encrypted_content"]));
        body.insert(
            "max_output_tokens".into(),
            json!(req.sampling.max_output_tokens),
        );

        // ---- The system prefix -> `instructions` ---------------------------
        //
        // Concatenated in order, joined with a blank line — the same fold the Chat adapter
        // performs, and byte-identical to it, so a persona pack renders to the same
        // sentences on both OpenAI surfaces (`persona::render` asserts that property).
        //
        // `instructions` IS A STRING, which is what makes `SystemBlock::cacheable` inert
        // here: it has nowhere to put a breakpoint. Worth recording precisely because this
        // wire is NOT like the Chat wire in that respect — it does have an explicit
        // breakpoint mechanism (`prompt_cache_breakpoint` on an input content part), it is
        // simply not reachable from a field that is one string. Moving the prefix into a
        // leading `system` message item to reach it would trade a documented, checked
        // property (identical rendering across wires) for a caching gain nobody has
        // measured, so it is not done, and `capabilities().prompt_caching` says `false`
        // rather than claiming a control the caller does not have.
        if !req.system.is_empty() {
            let joined = req
                .system
                .iter()
                .map(|b| b.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            body.insert("instructions".into(), json!(joined));
        }

        // ---- The conversation -> `input` items -----------------------------
        let mut input: Vec<Value> = Vec::new();
        for m in &req.messages {
            encode_message(m, &mut input, &self.cfg.model)?;
        }
        body.insert("input".into(), Value::Array(input));

        // ---- Tools ---------------------------------------------------------
        //
        // FLAT, not nested under a `function` object the way the Chat wire nests them.
        //
        // `strict` IS ALWAYS PRESENT, and that is a genuine difference from the Chat
        // adapter rather than an oversight. This wire's function-tool schema lists
        // `strict` as REQUIRED (alongside `type`, `name` and `parameters`), so omitting it
        // — which is what the Chat adapter does on a host that rejects it — is not an
        // option on the wire's own host. The quirk therefore governs the VALUE rather than
        // the presence: a caller's `true` survives only where the host is configured as
        // supporting it, and is otherwise sent as `false` with one logged note, so a
        // caller that believed its arguments would be schema-constrained finds out.
        if !req.tools.is_empty() {
            let tools: Vec<Value> = req
                .tools
                .iter()
                .map(|t| {
                    let strict = if t.strict && !self.cfg.quirks.strict_tools_supported {
                        eprintln!(
                            "jesse-agent: note wire=responses tag={:?} dropped strict on tool \
                             {:?} (host is not configured as supporting it)",
                            req.request_tag, t.name
                        );
                        false
                    } else {
                        t.strict
                    };
                    json!({
                        "type": "function",
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.input_schema,
                        "strict": strict,
                    })
                })
                .collect();
            body.insert("tools".into(), Value::Array(tools));
        }

        if let Some(t) = req.sampling.temperature {
            body.insert("temperature".into(), json!(t));
        }

        // ---- Stop sequences: THIS WIRE HAS NONE ----------------------------
        //
        // The Responses request has no `stop` parameter — not renamed, absent. So a
        // `Request` carrying stop sequences is legal (the neutral model must be valid on
        // every wire) and cannot be honoured here. Dropped with one note, exactly as a
        // quirk drops a field, because a caller that set a stop sequence and got an answer
        // that ran past it has been given something materially different from what it
        // asked for. `StopReason::StopSequence` is therefore unreachable on this wire.
        if !req.sampling.stop_sequences.is_empty() {
            eprintln!(
                "jesse-agent: note wire=responses tag={:?} dropped {} stop sequence(s) \
                 (this wire has no stop parameter)",
                req.request_tag,
                req.sampling.stop_sequences.len()
            );
        }

        // ---- Thinking ------------------------------------------------------
        if let Some(effort) = reasoning_effort(req.thinking) {
            if self.cfg.quirks.reasoning_effort_supported {
                // No `summary` is requested. A reasoning summary is GENERATED text and is
                // billed as output tokens, so asking for one on every call would spend a
                // caller's money on a display signal it never asked for. The decoder reads
                // `response.reasoning_summary_text.delta` when a host sends one anyway —
                // receiving is free, requesting is not.
                body.insert("reasoning".into(), json!({"effort": effort}));
            } else {
                eprintln!(
                    "jesse-agent: note wire=responses tag={:?} dropped reasoning effort={effort} \
                     (host is not configured as supporting it)",
                    req.request_tag
                );
            }
        }

        Ok(Value::Object(body))
    }
}

/// Encode one neutral message, appending one or more input ITEMS.
///
/// ONE NEUTRAL MESSAGE BECOMES SEVERAL ITEMS, and more so than on the Chat wire: a tool
/// call and a tool result are both TOP-LEVEL items here, siblings of a message rather than
/// content inside one. So an assistant message that said something and then called two
/// tools becomes three items, and the following user message carrying two results becomes
/// two more.
///
/// ORDER MATTERS AND IS POSITIONAL. A `function_call_output` is paired with the
/// `function_call` before it by `call_id`, but the wire still rejects an output that
/// precedes its call, so results are emitted FIRST within their own message — the same
/// hoist the Chat adapter performs, for the same reason: the neutral model carries the
/// results as blocks of the user message that follows the assistant's calls.
fn encode_message(m: &Message, out: &mut Vec<Value>, model: &str) -> Result<(), ProviderError> {
    for b in &m.content {
        if let ContentBlock::ToolResult {
            id,
            content,
            is_error,
        } = b
        {
            let text = match content {
                ToolResultContent::Text(t) => t.clone(),
                // `output` is a STRING on this wire, so a tool that returned an image
                // cannot be represented faithfully. A placeholder is emitted rather than
                // the block being dropped silently, so the model is told something was
                // there — identical to the Chat adapter's degradation.
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
            // `is_error` has no field on this wire either — `function_call_output` carries
            // a `call_id` and an `output` string and nothing else. Prefixing is the only
            // representation available, and saying nothing was rejected for the reason
            // `ContentBlock::ToolResult` documents: the model reads a failure as a
            // successful result.
            let text = if *is_error {
                format!("Error: {text}")
            } else {
                text
            };
            out.push(json!({
                "type": "function_call_output",
                // THE `call_id`, NOT THE ITEM ID. The decoder emits `call_id` as the
                // neutral id precisely so this line can be written without a lookup — see
                // `ResponsesDecoder`.
                "call_id": id,
                "output": text,
            }));
        }
    }

    // Text and images first, then the tool calls, so an assistant turn reads in the order
    // it was generated.
    let mut parts: Vec<Value> = Vec::new();
    let mut text_only = String::new();
    let mut calls: Vec<Value> = Vec::new();
    for b in &m.content {
        match b {
            ContentBlock::Text(t) => {
                if !text_only.is_empty() {
                    text_only.push('\n');
                }
                text_only.push_str(t);
                parts.push(json!({"type": "input_text", "text": t}));
            }
            ContentBlock::Image {
                media_type,
                data_base64,
            } => parts.push(json!({
                "type": "input_image",
                // A data URL, the same encoding the Chat wire takes. `detail` is sent
                // explicitly because this wire's schema lists it as required; `auto` is
                // the documented default and is what "the caller has no opinion" means.
                "image_url": format!("data:{media_type};base64,{data_base64}"),
                "detail": "auto",
            })),
            ContentBlock::ToolUse {
                id,
                name,
                arguments,
            } => calls.push(json!({
                "type": "function_call",
                "call_id": id,
                "name": name,
                // A STRING on this wire, as on Chat, and the same round trip: the neutral
                // model holds the parsed value, `to_string` renders it back.
                "arguments": arguments.to_string(),
                // NO `id` FIELD. A `function_call` item may carry the provider's own item
                // id, and sending one back would reference an item the provider has no
                // record of — `store: false` means there is nothing to reference. The
                // `call_id` is what pairs a call with its output, and it is the only id
                // this adapter round-trips.
            })),
            ContentBlock::ToolResult { .. } => {}
            // ECHOED BACK VERBATIM, AND FIRST. This wire's stateless multi-turn mechanism
            // is exactly this: with `store: false` there is no server-side copy of the
            // reasoning to replay, so the reasoning items from the previous response's
            // `output` must be carried back in `input` or the chain is lost the moment a
            // tool is dispatched. The item goes back as it arrived — `id` and
            // `encrypted_content` included — because nothing here understands its contents
            // well enough to rebuild it.
            //
            // It is pushed to `out` DIRECTLY rather than into `parts`: a reasoning item is a
            // top-level input item beside `message` and `function_call`, not a content part
            // inside a message. Pushing it here also keeps it ahead of the message and the
            // calls in this turn, which is the order it was generated in.
            ContentBlock::Reasoning {
                minted_by, opaque, ..
            } => {
                minted_by.check(Wire::Responses, model)?;
                out.push(opaque.clone());
            }
        }
    }

    if !parts.is_empty() {
        match m.role {
            // The user turn takes the CONTENT-PART LIST, which is the only form that can
            // carry an image.
            Role::User => out.push(json!({
                "type": "message",
                "role": "user",
                "content": parts,
            })),
            // The assistant turn takes a PLAIN STRING, deliberately. The part list an
            // assistant message takes on this wire is the OUTPUT shape (`output_text`,
            // with annotations and a status), not the input shape used above, and mixing
            // the two is precisely where a host rejects a request. The simple-message form
            // accepts a string for any role, so the assistant's own text goes back the way
            // every SDK sends it. An image in an assistant message would be lost here —
            // nothing in this crate ever produces one (the model returns text and tool
            // calls), and inventing a representation for a case that cannot arise would be
            // untested code on the send path.
            Role::Assistant => out.push(json!({
                "type": "message",
                "role": "assistant",
                "content": text_only,
            })),
        }
    }
    out.extend(calls);
    Ok(())
}

impl Provider for OpenAiResponses {
    fn wire(&self) -> Wire {
        Wire::Responses
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            tool_use: true,
            streaming: true,
            vision: true,
            // FALSE, and for a different reason than on the Chat wire. There, caching is
            // automatic and there is no breakpoint to place anywhere. Here a breakpoint
            // exists but is not reachable from the mapping this adapter uses — the system
            // prefix goes into `instructions`, which is one string. Either way the answer
            // to "can the caller influence caching" is no, which is the question the flag
            // asks; see `body` for the rest.
            prompt_caching: false,
            // Tracks the quirk, not the schema — the same rule the Chat adapter follows,
            // and for the same reason: `reasoning` is accepted by reasoning models and
            // rejected by everything else, so this answers for THIS deployment.
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
            let body = self.body(req)?.to_string();
            let model_for_decoder = self.cfg.model.clone();
            http::start_call(
                &self.cfg,
                &self.client,
                RESPONSES_PATH,
                body,
                &req.request_tag,
                || Box::new(ResponsesDecoder::new(&model_for_decoder)),
                cancel,
            )
            .await
        })
    }
}

// ===========================================================================
// SSE decoding
// ===========================================================================

/// A tool call being accumulated, keyed by the wire's ITEM id.
#[derive(Debug, Default)]
struct PartialCall {
    /// The `call_id` — the id the neutral events carry and a result is addressed to.
    call_id: String,
    name: String,
    args: String,
    /// `ToolUseEnd` has been emitted for this item.
    closed: bool,
}

/// Parses the Responses event stream.
///
/// ---- THE TWO IDS, which is the thing to understand before editing this ----
///
/// A tool call on this wire has an **item id** (`fc_…`, what
/// `response.function_call_arguments.delta` is keyed by) and a **`call_id`** (`call_…`,
/// what a `function_call_output` must be addressed to). Only
/// `response.output_item.added` carries both.
///
/// The decoder keys its own map by the ITEM id, because that is what the deltas identify
/// themselves with, and emits the **`call_id`** in every neutral event, because that is
/// what the loop will send back. Emitting the item id instead would produce a turn that
/// looks perfect until the tool result is rejected as addressing nothing.
///
/// A delta for an item that was never `added` is a [`ProviderError::Protocol`] — the same
/// rule the other two adapters apply to a delta for a block they never opened. It cannot
/// be recovered from: without the `added` event there is no `call_id` and no tool name, so
/// there is nothing to emit.
struct ResponsesDecoder {
    /// Who is minting the reasoning items this decoder emits. See `MessagesDecoder`.
    origin: ReasoningOrigin,
    calls: HashMap<String, PartialCall>,
    usage: Usage,
    /// Any `function_call` item was produced — this wire's only evidence that the model
    /// wants a tool called.
    saw_function_call: bool,
    /// A terminal response event (`completed` / `incomplete` / `failed`) was seen.
    terminated: bool,
    /// A terminal EVENT has been pushed; suppress anything after it.
    done: bool,
}

impl ResponsesDecoder {
    fn new(model: &str) -> Self {
        ResponsesDecoder {
            origin: ReasoningOrigin::new(Wire::Responses, model),
            calls: Default::default(),
            usage: Default::default(),
            saw_function_call: false,
            terminated: false,
            done: false,
        }
    }

    fn push_terminal(&mut self, out: &mut Vec<Event>, ev: Event) {
        if !self.done {
            self.done = true;
            out.push(ev);
        }
    }

    /// Close one accumulated call: validate its arguments and emit `ToolUseEnd`.
    ///
    /// `explicit` is the `arguments` string a `…arguments.done` event carried, which is
    /// preferred over the accumulated fragments when the accumulation is empty — a host
    /// that sends the whole argument object once, on `done`, with no deltas, is serving a
    /// legal stream and must not be treated as a call with no arguments.
    ///
    /// Returns `false` when the arguments did not parse, having pushed the
    /// [`ProviderError::Protocol`] that names the tool.
    fn close_call(&mut self, item_id: &str, explicit: Option<&str>, out: &mut Vec<Event>) -> bool {
        let Some(call) = self.calls.get_mut(item_id) else {
            self.push_terminal(
                out,
                Event::Error(ProviderError::Protocol(format!(
                    "tool call item {item_id:?} was closed but never added"
                ))),
            );
            return false;
        };
        if call.closed {
            return true;
        }
        call.closed = true;
        if call.args.trim().is_empty() {
            if let Some(explicit) = explicit {
                call.args = explicit.to_string();
            }
        }
        // The same rule as both other adapters: an empty argument string is a no-argument
        // call, anything else must parse, and a failure names the tool rather than passing
        // `{}` on to the loop.
        let text = if call.args.trim().is_empty() {
            "{}"
        } else {
            &call.args
        };
        if let Err(e) = serde_json::from_str::<Value>(text) {
            let (name, id) = (call.name.clone(), call.call_id.clone());
            self.push_terminal(
                out,
                Event::Error(ProviderError::Protocol(format!(
                    "tool {name:?} (id {id}) closed with arguments that are not valid JSON: {e}"
                ))),
            );
            return false;
        }
        out.push(Event::ToolUseEnd {
            id: call.call_id.clone(),
        });
        true
    }

    /// The stop reason for a response that finished.
    ///
    /// THIS WIRE REPORTS NO `finish_reason`, and that is the single largest difference
    /// between decoding it and decoding the other two. What it reports is a status, and
    /// for an incomplete response a reason for the incompleteness. "The model wants a tool
    /// called" is not a status at all — it is `completed`, exactly like a plain answer —
    /// so the ToolUse arm is DERIVED from whether a `function_call` item appeared in the
    /// output. A decoder that mapped `completed` straight to `EndTurn` would return a
    /// perfectly formed turn in which the loop never dispatched the tool the model asked
    /// for, and nothing would report an error.
    fn completion_stop_reason(&self, response: &Value) -> StopReason {
        if let Some(reason) = response
            .pointer("/incomplete_details/reason")
            .and_then(Value::as_str)
        {
            return match reason {
                "max_output_tokens" => StopReason::MaxTokens,
                other => StopReason::Other(other.to_string()),
            };
        }
        if self.saw_function_call {
            StopReason::ToolUse
        } else {
            StopReason::EndTurn
        }
    }

    /// Emit the usage vector then the terminal `Done`, in the order [`Event`] promises.
    fn finish(&mut self, response: &Value, out: &mut Vec<Event>) {
        self.terminated = true;
        if let Some(u) = response.get("usage").filter(|u| !u.is_null()) {
            apply_usage(&mut self.usage, u);
        }
        if let Some(id) = response.get("id").and_then(Value::as_str) {
            self.usage.provider_request_id = Some(id.to_string());
        }
        let stop_reason = self.completion_stop_reason(response);
        out.push(Event::Usage(self.usage.clone()));
        self.push_terminal(out, Event::Done { stop_reason });
    }
}

impl SseDecoder for ResponsesDecoder {
    fn on_frame(&mut self, data: &str, out: &mut Vec<Event>) {
        if self.done {
            return;
        }
        let data = data.trim();
        if data.is_empty() {
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

        // The frame's OWN `type`, not the SSE `event:` line. This wire sends both and they
        // agree; `http::SseFramer` reads past the envelope on purpose, so that one framer
        // serves a wire that sends an event name and one that sends none. See its doc.
        let Some(kind) = v.get("type").and_then(Value::as_str) else {
            return;
        };

        match kind {
            // The request id, available from the first frame — earlier than either other
            // wire offers it, which is worth having when a call then fails.
            "response.created" | "response.in_progress" => {
                if self.usage.provider_request_id.is_none() {
                    if let Some(id) = v.pointer("/response/id").and_then(Value::as_str) {
                        self.usage.provider_request_id = Some(id.to_string());
                    }
                }
            }

            "response.output_item.added" => {
                let item = v.get("item").unwrap_or(&Value::Null);
                if item.get("type").and_then(Value::as_str) != Some("function_call") {
                    // `message` and `reasoning` items need no registration: their deltas
                    // carry everything the neutral events need.
                    return;
                }
                let call_id = item
                    .get("call_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let name = item
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                // The item id is what later deltas identify themselves by. A host that
                // omits it cannot be streaming a second call under the same key, so the
                // `call_id` stands in — and if both are missing the item is unusable.
                let item_id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or(&call_id)
                    .to_string();
                if call_id.is_empty() || name.is_empty() {
                    return self.push_terminal(
                        out,
                        Event::Error(ProviderError::Protocol(
                            "a function_call item arrived without a call_id or a name".into(),
                        )),
                    );
                }
                self.saw_function_call = true;
                let args = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                out.push(Event::ToolUseStart {
                    id: call_id.clone(),
                    name: name.clone(),
                });
                self.calls.insert(
                    item_id,
                    PartialCall {
                        call_id,
                        name,
                        args,
                        closed: false,
                    },
                );
            }

            "response.output_text.delta" => {
                if let Some(t) = v
                    .get("delta")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                {
                    out.push(Event::TextDelta(t.to_string()));
                }
            }

            // Delivered when a host sends one; never requested (see `body`), never
            // required. `Event::ThinkingDelta` is a display signal and a loop that needed
            // it would break on every host that does not emit it.
            "response.reasoning_summary_text.delta" => {
                if let Some(t) = v
                    .get("delta")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                {
                    out.push(Event::ThinkingDelta(t.to_string()));
                }
            }

            "response.function_call_arguments.delta" => {
                let item_id = v.get("item_id").and_then(Value::as_str).unwrap_or_default();
                let Some(frag) = v
                    .get("delta")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                else {
                    return;
                };
                let Some(call) = self.calls.get_mut(item_id) else {
                    return self.push_terminal(
                        out,
                        Event::Error(ProviderError::Protocol(format!(
                            "argument delta for tool call item {item_id:?}, which was never added"
                        ))),
                    );
                };
                call.args.push_str(frag);
                let id = call.call_id.clone();
                out.push(Event::ToolUseArgsDelta {
                    id,
                    json_fragment: frag.to_string(),
                });
            }

            "response.function_call_arguments.done" => {
                let item_id = v
                    .get("item_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let explicit = v
                    .get("arguments")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                self.close_call(&item_id, explicit.as_deref(), out);
            }

            // The BACKSTOP, not the normal path. `…arguments.done` closes a call first and
            // `close_call` is idempotent, so this only does work for a host that finishes
            // an item without sending the arguments-done event — which would otherwise
            // produce a stream with a `ToolUseStart` and no `ToolUseEnd`, i.e. a tool the
            // loop can see and cannot call.
            "response.output_item.done" => {
                let item = v.get("item").unwrap_or(&Value::Null);
                // THE REASONING ITEM, CAPTURED WHOLE AND CAPTURED HERE. `added` carries the
                // item before its `encrypted_content` exists; `done` carries the finished
                // item, which is the thing the next request has to echo. It is taken
                // verbatim — this adapter does not know what is inside it and must not
                // rebuild it from fields it believes are there.
                if item.get("type").and_then(Value::as_str) == Some("reasoning") {
                    out.push(Event::Reasoning {
                        id: item.get("id").and_then(Value::as_str).map(str::to_string),
                        minted_by: self.origin.clone(),
                        opaque: item.clone(),
                    });
                    return;
                }
                if item.get("type").and_then(Value::as_str) != Some("function_call") {
                    return;
                }
                let call_id = item
                    .get("call_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let item_id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or(call_id)
                    .to_string();
                let explicit = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                self.close_call(&item_id, explicit.as_deref(), out);
            }

            "response.completed" | "response.incomplete" => {
                let response = v.get("response").cloned().unwrap_or(Value::Null);
                self.finish(&response, out);
            }

            // A response that failed AFTER the headers were good. The message is the
            // provider's prose, so it is redacted on the way into the error like every
            // other provider-supplied string, and classified `BadRequest` — fatal, because
            // a failed response is the request having been refused, not the transport
            // having wobbled.
            "response.failed" => {
                self.terminated = true;
                let message = v
                    .pointer("/response/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("the response failed");
                self.push_terminal(
                    out,
                    Event::Error(ProviderError::BadRequest(http::redact(message))),
                );
            }

            "error" => {
                self.terminated = true;
                let message = v
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("the stream reported an error");
                self.push_terminal(
                    out,
                    Event::Error(ProviderError::BadRequest(http::redact(message))),
                );
            }

            // Everything else — `response.content_part.*`, `response.output_text.done`,
            // `response.reasoning_summary_part.*`, the built-in tool events — is ignored
            // rather than rejected. This wire adds event types continually and a decoder
            // that refused an unknown one would break on a schema addition that does not
            // concern it. Same rule the Messages decoder states.
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
                    "stream ended without a terminal response event".into(),
                )),
            );
        }
    }
}

/// Apply this wire's `usage` object, NORMALISING IT to the invariant on [`Usage`].
///
/// ---- THE ARITHMETIC ------------------------------------------------------
///
/// This wire reports `input_tokens` as the prompt TOTAL, with
/// `input_tokens_details` documented as "a detailed breakdown of the input tokens" —
/// i.e. `cached_tokens` and `cache_write_tokens` are SUBSETS of it, not siblings of it.
/// [`Usage`] wants the three DISJOINT, so both are subtracted:
///
/// ```text
///     input_tokens       = input_tokens - cached_tokens - cache_write_tokens
///     cache_read_tokens  = cached_tokens
///     cache_write_tokens = cache_write_tokens
/// ```
///
/// This is the Chat adapter's subtraction plus one term. The extra term matters because
/// this wire reports a cache-WRITE count and the Chat wire has no field for one: leaving
/// it inside `input_tokens` AND reporting it separately would count those tokens twice in
/// any caller that sums the vector, which is exactly the failure mode the invariant exists
/// to prevent.
///
/// **`reasoning_tokens` IS NOT SUBTRACTED FROM `output_tokens`**, and that asymmetry is
/// deliberate. `output_tokens_details.reasoning_tokens` is a breakdown of tokens that were
/// generated and are billed at the output rate; they are part of the output, not a
/// separate class of it. So [`Usage::reasoning_tokens`] is documented as a SUBSET of
/// `output_tokens` rather than a fourth disjoint count, and no price is computed from it.
/// Subtracting it would understate the output bill by exactly the thinking.
///
/// Saturating subtraction throughout: a host reporting details larger than the total is
/// reporting nonsense, and a panic on a billing field is worse than a zero.
fn apply_usage(usage: &mut Usage, v: &Value) {
    let total = v.get("input_tokens").and_then(Value::as_u64);
    let cached = v
        .pointer("/input_tokens_details/cached_tokens")
        .and_then(Value::as_u64);
    let written = v
        .pointer("/input_tokens_details/cache_write_tokens")
        .and_then(Value::as_u64);
    if let Some(t) = total {
        usage.input_tokens = Some(
            t.saturating_sub(cached.unwrap_or(0))
                .saturating_sub(written.unwrap_or(0)),
        );
    }
    if let Some(c) = cached {
        usage.cache_read_tokens = Some(c);
    }
    if let Some(w) = written {
        usage.cache_write_tokens = Some(w);
    }
    if let Some(n) = v.get("output_tokens").and_then(Value::as_u64) {
        usage.output_tokens = Some(n);
    }
    if let Some(n) = v
        .pointer("/output_tokens_details/reasoning_tokens")
        .and_then(Value::as_u64)
    {
        usage.reasoning_tokens = Some(n);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{AuthScheme, Quirks, Sampling, SystemBlock, ToolSpec};

    fn provider_with(quirks: Quirks) -> OpenAiResponses {
        let mut cfg = ProviderConfig::new(
            Wire::Responses,
            "http://127.0.0.1:1/v1",
            "test-model",
            AuthScheme::None,
        );
        cfg.quirks = quirks;
        OpenAiResponses::new(cfg)
    }

    fn provider() -> OpenAiResponses {
        provider_with(Quirks::default())
    }

    fn decode(frames: &[&str]) -> Vec<Event> {
        let mut d = ResponsesDecoder::new("test-model");
        let mut out = Vec::new();
        for f in frames {
            d.on_frame(f, &mut out);
        }
        d.on_eof(&mut out);
        out
    }

    #[test]
    fn store_is_off_and_no_response_is_ever_continued() {
        // The privacy property of this adapter, asserted on the body rather than on a
        // comment. `store` defaults to TRUE on this wire, so an absent field is not
        // equivalent and the test checks the value, not the absence.
        let body = provider().body(&Request::default()).unwrap();
        assert_eq!(body.get("store"), Some(&json!(false)));
        assert!(
            body.get("previous_response_id").is_none(),
            "the loop owns the thread; a stored response is never continued"
        );
        assert!(
            !body.to_string().contains("previous_response_id"),
            "not anywhere in the body: {body}"
        );
    }

    #[test]
    fn the_system_prefix_becomes_instructions_in_order() {
        let req = Request {
            system: vec![
                SystemBlock::cacheable("stable"),
                SystemBlock::plain("today"),
            ],
            messages: vec![Message::user("hi")],
            ..Default::default()
        };
        let body = provider().body(&req).unwrap();
        assert_eq!(body.get("instructions"), Some(&json!("stable\n\ntoday")));
        // The same join the Chat adapter performs, so a persona renders identically.
        assert!(
            !body.to_string().contains("cache_control"),
            "nothing cache-shaped reaches a wire without a reachable breakpoint"
        );
        assert_eq!(body.pointer("/input/0/role"), Some(&json!("user")));
        assert_eq!(
            body.pointer("/input/0/content/0/type"),
            Some(&json!("input_text"))
        );
    }

    #[test]
    fn reasoning_is_sent_only_when_the_quirk_is_on() {
        let req = Request {
            thinking: Thinking::High,
            ..Default::default()
        };
        assert!(provider().body(&req).unwrap().get("reasoning").is_none());
        let on = provider_with(Quirks {
            reasoning_effort_supported: true,
            ..Default::default()
        })
        .body(&req)
        .unwrap();
        assert_eq!(on.pointer("/reasoning/effort"), Some(&json!("high")));
        // No summary is requested: it is generated text and would be billed.
        assert!(on.pointer("/reasoning/summary").is_none());
    }

    #[test]
    fn strict_is_always_present_because_this_wires_schema_requires_it() {
        let req = Request {
            tools: vec![ToolSpec {
                name: "add".into(),
                description: "d".into(),
                input_schema: json!({"type": "object"}),
                strict: true,
            }],
            ..Default::default()
        };
        // Quirk off: the KEY is still there (the schema requires it), the VALUE is false.
        let off = provider().body(&req).unwrap();
        assert_eq!(off.pointer("/tools/0/strict"), Some(&json!(false)));
        // And the tool is FLAT — no `function` wrapper, unlike the Chat wire.
        assert_eq!(off.pointer("/tools/0/name"), Some(&json!("add")));
        assert_eq!(off.pointer("/tools/0/type"), Some(&json!("function")));
        assert!(off.pointer("/tools/0/function").is_none());

        let on = provider_with(Quirks {
            strict_tools_supported: true,
            ..Default::default()
        })
        .body(&req)
        .unwrap();
        assert_eq!(on.pointer("/tools/0/strict"), Some(&json!(true)));
    }

    #[test]
    fn stop_sequences_are_dropped_because_this_wire_has_no_stop_parameter() {
        let req = Request {
            sampling: Sampling {
                stop_sequences: vec!["STOP".into()],
                ..Default::default()
            },
            ..Default::default()
        };
        let body = provider().body(&req).unwrap();
        assert!(body.get("stop").is_none());
        assert!(body.get("stop_sequences").is_none());
        assert!(
            !body.to_string().contains("STOP"),
            "an unsupported field is dropped, never smuggled in elsewhere: {body}"
        );
    }

    #[test]
    fn a_tool_call_and_its_result_become_sibling_items() {
        let req = Request {
            messages: vec![
                Message {
                    role: Role::Assistant,
                    content: vec![
                        ContentBlock::Text("calling".into()),
                        ContentBlock::ToolUse {
                            id: "call_1".into(),
                            name: "add".into(),
                            arguments: json!({"a": 1}),
                        },
                    ],
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
        let body = provider().body(&req).unwrap();
        // The assistant's text is a STRING, not a part list — see `encode_message`.
        assert_eq!(body.pointer("/input/0/role"), Some(&json!("assistant")));
        assert_eq!(body.pointer("/input/0/content"), Some(&json!("calling")));
        // The call is its own TOP-LEVEL item, addressed by call_id, with no item id.
        assert_eq!(body.pointer("/input/1/type"), Some(&json!("function_call")));
        assert_eq!(body.pointer("/input/1/call_id"), Some(&json!("call_1")));
        assert_eq!(
            body.pointer("/input/1/arguments"),
            Some(&json!(r#"{"a":1}"#))
        );
        assert!(
            body.pointer("/input/1/id").is_none(),
            "no item id goes back: with store:false there is nothing to reference"
        );
        // So is the result.
        assert_eq!(
            body.pointer("/input/2/type"),
            Some(&json!("function_call_output"))
        );
        assert_eq!(body.pointer("/input/2/call_id"), Some(&json!("call_1")));
        assert_eq!(body.pointer("/input/2/output"), Some(&json!("2")));
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
        let body = provider().body(&req).unwrap();
        assert_eq!(body.pointer("/input/0/output"), Some(&json!("Error: boom")));
    }

    #[test]
    fn an_image_becomes_a_data_url_with_an_explicit_detail() {
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
        let body = provider().body(&req).unwrap();
        assert_eq!(
            body.pointer("/input/0/content/0/image_url"),
            Some(&json!("data:image/png;base64,QUJD"))
        );
        assert_eq!(
            body.pointer("/input/0/content/0/detail"),
            Some(&json!("auto")),
            "the schema lists detail as required"
        );
    }

    #[test]
    fn the_neutral_id_is_the_call_id_not_the_item_id() {
        // The property a turn silently fails on if it is got wrong: the loop sends the id
        // it was given back as a `function_call_output.call_id`, and only `call_…` pairs.
        let events = decode(&[
            r#"{"type":"response.created","response":{"id":"resp_1"}}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":""}}"#,
            r#"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"a\":1}"}"#,
            r#"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"a\":1}"}"#,
            r#"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":9,"output_tokens":4}}}"#,
        ]);
        for e in &events {
            match e {
                Event::ToolUseStart { id, .. }
                | Event::ToolUseArgsDelta { id, .. }
                | Event::ToolUseEnd { id } => {
                    assert_eq!(id, "call_1", "the item id must never reach a neutral event")
                }
                _ => {}
            }
        }
        assert!(events
            .iter()
            .any(|e| matches!(e, Event::ToolUseEnd { id } if id == "call_1")));
    }

    #[test]
    fn a_completed_response_carrying_a_function_call_stops_for_tool_use() {
        // This wire's `completed` status is the SAME for an answer and for a tool call;
        // the arm is derived from the output items. Getting this wrong yields a turn that
        // never dispatches the tool and reports no error.
        let events = decode(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":"{}"}}"#,
            r#"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}"#,
            r#"{"type":"response.completed","response":{"id":"resp_2","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ]);
        assert!(matches!(
            events.last(),
            Some(Event::Done {
                stop_reason: StopReason::ToolUse
            })
        ));
    }

    #[test]
    fn an_incomplete_response_maps_its_reason() {
        for (reason, want) in [
            ("max_output_tokens", StopReason::MaxTokens),
            ("content_filter", StopReason::Other("content_filter".into())),
        ] {
            let frame = format!(
                r#"{{"type":"response.incomplete","response":{{"id":"resp_3","status":"incomplete","incomplete_details":{{"reason":"{reason}"}},"usage":{{"input_tokens":1,"output_tokens":2}}}}}}"#
            );
            let events = decode(&[&frame]);
            assert_eq!(
                events.last(),
                Some(&Event::Done {
                    stop_reason: want.clone()
                }),
                "{reason}"
            );
        }
    }

    #[test]
    fn usage_subtracts_both_details_so_the_parts_sum_to_the_prompt_total() {
        let events = decode(&[
            r#"{"type":"response.completed","response":{"id":"resp_4","status":"completed","usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":900,"cache_write_tokens":50},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":7},"total_tokens":1011}}}"#,
        ]);
        let u = events
            .iter()
            .find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            })
            .expect("usage emitted");
        assert_eq!(u.input_tokens, Some(50));
        assert_eq!(u.cache_read_tokens, Some(900));
        // The count the Chat wire has no field for at all.
        assert_eq!(u.cache_write_tokens, Some(50));
        assert_eq!(
            u.input_tokens.unwrap() + u.cache_read_tokens.unwrap() + u.cache_write_tokens.unwrap(),
            1000,
            "the three disjoint counts sum back to the wire's prompt total"
        );
        // Reasoning tokens are a SUBSET of the output, not a fourth disjoint class.
        assert_eq!(u.output_tokens, Some(11));
        assert_eq!(u.reasoning_tokens, Some(7));
        assert_eq!(u.provider_request_id.as_deref(), Some("resp_4"));
    }

    #[test]
    fn usage_without_details_leaves_the_prompt_total_alone() {
        let events = decode(&[
            r#"{"type":"response.completed","response":{"id":"resp_5","status":"completed","usage":{"input_tokens":42,"output_tokens":3}}}"#,
        ]);
        let u = events
            .iter()
            .find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(u.input_tokens, Some(42));
        // Genuine absences, not zeroes.
        assert_eq!(u.cache_read_tokens, None);
        assert_eq!(u.cache_write_tokens, None);
        assert_eq!(u.reasoning_tokens, None);
    }

    #[test]
    fn a_tool_call_with_unparseable_arguments_is_a_protocol_error_naming_the_tool() {
        let events = decode(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":""}}"#,
            r#"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"a\":"}"#,
            r#"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"a\":"}"#,
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
    fn a_delta_for_an_item_that_was_never_added_is_a_protocol_error() {
        let events = decode(&[
            r#"{"type":"response.function_call_arguments.delta","item_id":"fc_ghost","delta":"{}"}"#,
        ]);
        match events.last() {
            Some(Event::Error(ProviderError::Protocol(m))) => {
                assert!(m.contains("fc_ghost"), "{m}")
            }
            other => panic!("expected a Protocol error, got {other:?}"),
        }
    }

    #[test]
    fn output_item_done_closes_a_call_the_arguments_done_event_never_closed() {
        // A host that finishes the item without sending `…arguments.done` would otherwise
        // leave a ToolUseStart with no ToolUseEnd — a tool the loop can see and not call.
        let events = decode(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":""}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add","arguments":"{\"a\":1}"}}"#,
            r#"{"type":"response.completed","response":{"id":"resp_6","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ]);
        let ends = events
            .iter()
            .filter(|e| matches!(e, Event::ToolUseEnd { .. }))
            .count();
        assert_eq!(ends, 1, "closed exactly once, not twice: {events:?}");
    }

    #[test]
    fn a_stream_that_stops_before_a_terminal_response_event_is_a_protocol_error() {
        let events =
            decode(&[r#"{"type":"response.output_text.delta","item_id":"msg_1","delta":"half"}"#]);
        assert_eq!(
            events.first(),
            Some(&Event::TextDelta("half".into())),
            "the partial answer still reaches the caller"
        );
        assert!(matches!(
            events.last(),
            Some(Event::Error(ProviderError::Protocol(_)))
        ));
    }

    #[test]
    fn an_in_band_error_event_ends_the_stream() {
        let events =
            decode(&[r#"{"type":"error","code":"server_error","message":"model overloaded"}"#]);
        assert!(matches!(
            events.first(),
            Some(Event::Error(ProviderError::BadRequest(_)))
        ));
    }

    #[test]
    fn a_failed_response_ends_the_stream() {
        let events = decode(&[
            r#"{"type":"response.failed","response":{"id":"resp_7","status":"failed","error":{"code":"x","message":"it failed"}}}"#,
        ]);
        match events.last() {
            Some(Event::Error(ProviderError::BadRequest(m))) => assert!(m.contains("it failed")),
            other => panic!("expected BadRequest, got {other:?}"),
        }
    }

    #[test]
    fn unknown_event_types_are_ignored_rather_than_rejected() {
        let events = decode(&[
            r#"{"type":"response.content_part.added","item_id":"msg_1","part":{"type":"output_text","text":""}}"#,
            r#"{"type":"response.some.future.event","whatever":1}"#,
            r#"{"type":"response.output_text.delta","item_id":"msg_1","delta":"hi"}"#,
            r#"{"type":"response.completed","response":{"id":"resp_8","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ]);
        assert!(matches!(
            events.last(),
            Some(Event::Done {
                stop_reason: StopReason::EndTurn
            })
        ));
    }
}
