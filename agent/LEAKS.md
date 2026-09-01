# `LEAKS.md` — where the provider trait strained against a third wire

**What this file is.** D1 wrote two wire adapters *together*. Two adapters written together
can agree with each other by construction: whatever the author of the first one assumed, the
author of the second one assumed too, and the conformance suite records the agreement as if
it were a property of the abstraction. D8 wrote a third — the **OpenAI Responses** adapter —
after the trait had settled, against a wire with a genuinely different shape, and every place
the trait strained is written down here rather than quietly patched.

**The rule this file follows.** A row below is a LEAK only if a conformance case *cannot pass
without a change to the neutral types*. Anything the adapter can absorb on its own is not a
leak, however awkward — absorbing wire differences is the adapter's entire job. Where a
candidate was refuted, the refutation is recorded with its evidence, because "we considered
it and it was not real" is a more useful record than silence.

**Scoreboard.**

| | |
|---|---|
| Conformance cases run against three adapters | **15** (13 inherited, 2 added), plus **5** D13 cases the table's one-request-per-case shape cannot express |
| Cases that needed a trait change to pass | **1** |
| Additive trait changes made | **1** (`Usage::reasoning_tokens`) |
| Non-additive changes made | **1** (`ContentBlock::Reasoning`) |
| Recommendations left for Jeremy | **0** |
| Candidates examined and refuted | **4** (L1, L2, L3, L6) |

---

## L4 — the usage type had no home for reasoning tokens · **CONFIRMED · additive · MADE**

**The case.** `interleaved items with reasoning` (conformance case 15). The Responses wire's
`response.completed` carries
`usage.output_tokens_details.reasoning_tokens`; the neutral `Usage` had four counts and none
of them could hold it. The number was decoded and dropped on the floor.

**The wire shape that caused it.** This wire reports an output BREAKDOWN, which neither other
wire does. The Messages wire reports thinking tokens inside `output_tokens` with no split;
the Chat wire has no equivalent field at all.

**The smallest trait change.** One `Option<u64>` field on `Usage`:

```rust
pub reasoning_tokens: Option<u64>,
```

**Additive?** Yes. `Usage` derives `Default`, the field is `Option`, no existing field changed
meaning, and `From<Usage> for TokenUsage` — the conversion the bridge's on-disk metrics shape
depends on — drops it, so nothing already written to disk changes. Six struct literals in the
tree gained `reasoning_tokens: None`; no call site changed behaviour.

**Made, and why it was worth making.** The alternative was to leave it dropped, and the
argument against dropping is operational rather than aesthetic: "how much of this turn's bill
was thinking" is the first question a reasoning model raises the moment it is deployed on a
budget, the wire answers it, and a caller cannot re-derive it from anything else in the
vector. It reaches `UsageRecord` too (optional, omitted when absent, schema version unchanged
at `1`), because a count that reaches no durable record is a count nobody can answer a
question with.

**The one thing to be careful of, documented at every site.** `reasoning_tokens` is a
**SUBSET of `output_tokens`**, not a fifth disjoint count. The other three obey "the parts sum
to the prompt total"; this one deliberately does not, because reasoning tokens *are* output
tokens — generated, billed at the output rate, already inside `output_tokens` on every wire
that reports them. `PriceDeck::cost_usd` therefore has no term for it and says so in a
comment, since a zero-rate term is a term somebody later "fixes".

---

## L5 — no neutral block can carry an opaque reasoning item across a tool-use turn · **CONFIRMED · NOT additive in effect · MADE (D13)**

**The case.** None in the suite, because it cannot be written without the change. It is a
multi-iteration turn with a reasoning model: the loop calls, the model thinks and asks for a
tool, the loop dispatches and calls again — and on the second call the model's own previous
reasoning is gone.

**The wire shape that caused it.** The Responses API is stateful by default. With
`store: true` the provider keeps the reasoning items and replays them; this adapter sends
`store: false` on every request (see `openai_responses::OpenAiResponses::body` for the privacy
argument, which is not up for revision). The wire's documented mechanism for a **stateless**
multi-turn is `include: ["reasoning.encrypted_content"]` on the request plus echoing the
opaque reasoning item back in `input` on the next call — the OpenAPI schema says so in as many
words: *"enables reasoning items to be used in multi-turn conversations when using the
Responses API statelessly (like when the `store` parameter is set to `false`…)"*.

The neutral model has no `ContentBlock` that can carry an opaque provider-minted blob, so
there is nothing for the loop to store and nothing to send back.

**THIS IS NOT A RESPONSES-ONLY GAP**, which is the part worth reading twice. The Anthropic
Messages wire has the same requirement in a different spelling: a `thinking` block carries a
`signature`, and extended thinking with tool use requires the signed block to be echoed back
on the following call. Both existing adapters have this gap. It went unnoticed for two
adapters because nothing in the suite exercised thinking *and* tool use *and* a second
iteration together — which is precisely the value of writing a third adapter: it did not
create the hole, it revealed one that was already there.

**The smallest trait change.**

```rust
pub enum ContentBlock {
    …
    /// A provider-minted reasoning artefact, opaque to this layer, echoed back verbatim.
    Reasoning { id: String, opaque: String },
}
```

**Additive?** *In the type, yes. In effect, no*, and the distinction is why this is a
recommendation rather than a commit:

* Every `match` on `ContentBlock` in three adapters, the loop, the framing layer and the
  thread store stops compiling, and each one needs a **decision**, not a `_ => {}`.
* It changes what the thread store writes to disk. An encrypted chain-of-thought blob,
  persisted at mode 0600 next to the conversation, is a new class of stored data — larger than
  the messages it accompanies, unreadable by the owner, and useless to anyone but the provider
  that minted it. Whether that belongs in a vault-adjacent thread file is a **product
  decision**, not an adapter one.
* It needs a request-side companion (`include: […]` here, nothing on Messages, a different
  thing again on the next wire), and getting the pairing wrong yields a `400` on the *second*
  iteration of a turn — the worst place to discover it.

**Current behaviour, stated because it is real and it is a cost.** A reasoning model on this
wire re-derives some thinking it already did across a tool loop. The turn is correct and safe;
it is slower and marginally more expensive than one that could echo. Everything about that is
in `openai_responses::OpenAiResponses::body`'s doc comment so nobody rediscovers it as a bug.

**Recommendation.** Do this as its own change, on all three adapters at once, with the thread
store's retention question answered first. It is not a Phase 1 blocker: no model this
repository deploys today runs high-effort reasoning through a long tool loop.

### MADE, in D13. What it cost.

Taken as its own change, on all three adapters at once, and the retention question answered
first because the answer decided the shape of everything else.

**The variant, as built.** L5's sketch plus one field it did not have:

```rust
Reasoning {
    id: Option<String>,          // `rs_…` on Responses; None on Messages, which has none
    minted_by: ReasoningOrigin,  // { wire, model } — the guard
    opaque: serde_json::Value,   // the block exactly as it arrived
}
```

`opaque` is a `Value` rather than a `String` because "echo it back verbatim" is then the
trivial operation instead of a re-serialisation that has to be got right, and because both
wires want a JSON object back, not a quoted string. `minted_by` is the addition:
`ReasoningOrigin::check` refuses a block minted by another wire or another model as a
`Protocol` error **before any bytes go out**, which is what stops a model switch mid-thread
from turning into a `400` on the second iteration of a turn.

**The retention answer: it is never persisted.** Reasoning blocks ride the in-memory
conversation so the next request of the same turn echoes them, and `append_all` strips them
from the copy that goes to the thread store. Two reasons, both written where the drop
happens: the blob is unreplayable across the model switches threads survive, and nothing
durable should hold what the owner cannot read. That answers the "new class of stored data"
objection above by not storing it.

**The match sites the compiler surfaced, and what each decided.** Four, plus one in an
example:

| Site | Decision |
|---|---|
| `provider/anthropic.rs` `encode_block` | **Echo verbatim**, after the origin check. The block that arrived is the value that goes back out; the wire documents that rebuilding it, or filtering a `redacted_thinking` block out of it, is a `400`. |
| `provider/openai_responses.rs` `encode_message` | **Echo verbatim**, after the origin check, pushed as a top-level `input` item rather than a content part — which is the shape this wire takes — and ahead of the message it belongs to. |
| `provider/openai_chat.rs` `encode_message` | **Skip silently.** The documented absence case: this wire mints nothing to echo, so there is nothing a following request could carry and nothing omitting one could break. |
| `loop.rs` `build_user_message` | **Named in the drop log.** A caller cannot mint one — reasoning blocks come from an adapter decoding a response — so the arm is unreachable; it is named rather than lumped in with the others so the line stays honest if one ever arrives. |
| `examples/smoke.rs` | **Size and origin, never the payload.** A diagnostic run must not print a provider's encrypted chain of thought to a terminal. |

Three more sites did not stop compiling and were checked rather than assumed: `framing.rs`
renders only `Text` from a tool result's blocks (`_ => None`), so a reasoning block
contributes no printable text; `persona::check` takes a `&str` and cannot be handed a block
at all; and the eval assertions read a transcript's final answer, which is built from
`TextDelta` events. A test asserts the text is byte-identical with and without the block.

**The request-side companions, which L5 warned were the easy thing to get wrong.**
Responses sends `include: ["reasoning.encrypted_content"]`; Messages sends nothing extra but
now accumulates `signature_delta`, which the decoder previously discarded as "ignored, not
fatal" — the signature is precisely what the wire validates when the block comes back.

**The cases that could not be written before.** Five, all against loopback mocks: Messages
echoes a signed thinking block verbatim and in position; Messages echoes a
`redacted_thinking` block untouched; Responses echoes the encrypted item verbatim as a
top-level `input` item and asks for it on the first request; Chat carries no reasoning
artefact anywhere in the second request; and a foreign block is refused on both echoing
wires with nothing sent.

---

## L1 — "the event model needs a per-item ordering key" · **REFUTED**

**The candidate.** The Responses wire can interleave output items — a message, then a
function call, then another message — and `Event` has no field naming which item a delta
belongs to. Surely text from two items would come out scrambled.

**Why it is not real, and the evidence.** The stream is ordered, and every event that could be
ambiguous already carries its own key:

* `TextDelta` needs no key. Deltas arrive in generation order and the loop concatenates them,
  so two message items separated by a tool call produce one correctly ordered string.
* `ToolUseArgsDelta` carries `id`, so interleaved argument fragments from two concurrent calls
  are attributable without any positional information.

Conformance case 15 (`interleaved items with reasoning`) asserts exactly this, **on all three
wires**, because all three can interleave: the fixture emits text, a tool call and more text,
and the case asserts the text comes out as `"before after"` and the tool call still closes.
Case 3 (`two parallel tool calls`) makes the Responses fixture interleave two calls'
argument deltas explicitly — `fc_a`, `fc_b`, `fc_a`, `fc_b` — and asserts each call's
fragments reassemble into its own object.

**Note.** Every Responses event carries a monotonic `sequence_number`, so the wire *does*
offer an ordering key. It is not surfaced, because SSE is already ordered and a key nobody
needs is a field every adapter has to synthesise.

---

## L2 — "`tool_result` needs an `is_error` representation on this wire" · **REFUTED**

**The candidate.** A `function_call_output` item carries a `call_id` and an `output` string
and nothing else. There is no error flag, so `ContentBlock::ToolResult { is_error }` cannot be
expressed.

**Why it is not a trait leak.** The neutral model already carries the fact; the wire is what
cannot represent it. That is a wire limitation, and degrading it is the adapter's job — which
the Chat adapter has been doing since D1 with the identical `Error: ` prefix, for the reason
`ContentBlock::ToolResult` documents (a model reads an unflagged failure as a successful
result). Adding a trait field here would be adding a field to describe what the *wire* lacks.

**Where it is checked.**
`openai_responses::tests::a_failed_tool_result_says_so_in_the_only_field_this_wire_has`,
alongside the Chat adapter's test of the same name.

---

## L3 — "the request needs a way to express *do not store*" · **REFUTED**

**The candidate.** `store` defaults to **`true`** on this wire. Something has to turn it off,
so perhaps `Request` needs a `store: bool`, or `Quirks` a toggle.

**Why it is not real.** A knob whose only defensible value is one value is not a knob. The
loop owns the thread; the provider must not keep a second copy of a conversation carrying the
owner's vault; and `store: false` is the reversible direction (it costs a re-send the loop
performs anyway, where storing costs a copy that cannot be un-made). A `Request` field or a
quirk would be a way for a future config edit to turn that property off without anyone
deciding to.

So it is a **constant in the adapter**, and `previous_response_id` is never sent for the same
reason plus one: it would mean the model's context was assembled from state the loop cannot
see, which is the property `thread.rs` exists to deny.

**Where it is checked.** Conformance case 14 (`store is off and no response is ever
continued`) asserts `store == false` on Responses and asserts the field is **absent** on the
other two — a Responses concept appearing in a Messages body would mean an adapter had learned
a neighbouring wire's vocabulary. `loop_conformance`'s
`the_responses_wire_addresses_a_tool_result_by_call_id` re-checks it on **every** request of a
three-call turn, because a `store: true` on the third request would retain the whole tool loop.

---

## L6 — `Sampling::stop_sequences` cannot be honoured on this wire · **REFUTED as a trait leak**

**The finding.** The Responses request has no `stop` parameter. Not renamed — absent. Verified
against the published OpenAPI schema: `ModelResponseProperties` is `metadata`, `top_logprobs`,
`temperature`, `top_p`, `user`; `ResponseProperties` adds `previous_response_id`, `model`,
`background`, `max_tool_calls`, `text`, `tools`, `tool_choice`, `prompt`. There is no stop
list anywhere in the create-response body.

**Why it needs no trait change.** The neutral model is supposed to be valid on every wire —
that is stated on `SystemBlock::cacheable` and on `Request::batch_eligible` — so a request
carrying stop sequences must be *accepted* here and simply cannot be honoured. That is the
same shape as a dropped quirk, and it gets the same treatment: dropped with **one logged
note**, never silently, because a caller that set a stop sequence and got an answer running
past it has been given something materially different from what it asked for.

**Consequence, recorded so nobody hunts for it.** `StopReason::StopSequence` is unreachable on
this wire.

**Where it is checked.**
`openai_responses::tests::stop_sequences_are_dropped_because_this_wire_has_no_stop_parameter`,
which also asserts the string is not smuggled into some other field.

---

## Things that are not leaks but are worth knowing

These cost the adapter work and cost the trait nothing. They are here because the next person
to read this wire's code will wonder about each of them.

| Wire fact | What the adapter does |
|---|---|
| **A tool call has two ids** — an item id (`fc_…`) the stream's deltas are keyed by, and a `call_id` (`call_…`) a result must be addressed to. Only `response.output_item.added` carries both. | Keys its own map by the ITEM id and emits the **`call_id`** in every neutral event, because that is what the loop sends back. Emitting the item id would produce a turn that looks perfect until every tool result addresses nothing. Checked end to end by `loop_conformance::the_responses_wire_addresses_a_tool_result_by_call_id`. |
| **There is no `finish_reason`.** A response has a STATUS (`completed` / `incomplete` / `failed`), and "the model wants a tool called" is not a status — it is `completed`, exactly like a plain answer. | Derives `StopReason::ToolUse` from whether a `function_call` item appeared. Mapping `completed` straight to `EndTurn` would yield a well-formed turn in which the loop never dispatched the tool, and nothing would report an error. |
| **`strict` is REQUIRED on a function tool** by this wire's schema, where the Chat wire treats it as optional. | Always emits the key; the `strict_tools_supported` quirk governs the VALUE rather than the presence, and dropping a caller's `true` still logs one note. |
| **Usage is never opt-in**, unlike Chat, where the terminal usage chunk must be requested with `stream_options`. | Sends no `stream_options`; case 1 asserts its absence. |
| **`input_tokens_details` carries `cache_write_tokens`** as well as `cached_tokens` — a count the Chat wire has no field for at all. | Subtracts **both** from the prompt total, so the three neutral counts stay disjoint and sum back to it. See the caveat below. |
| **`max_output_tokens` has a documented minimum of 16.** | Not enforced here: the neutral `Sampling` default is 1024 and a caller asking for less gets the host's own `400`, which names the field. Clamping silently would hide a caller's mistake. |
| **This wire HAS an explicit prompt-cache breakpoint** (`prompt_cache_breakpoint` on an input content part) — unlike Chat, where caching is automatic and there is nothing to place. | Not reachable from this adapter's mapping: the system prefix goes to `instructions`, which is one string. `capabilities().prompt_caching` answers `false` rather than claiming a control the caller does not have. Reaching it would mean moving the prefix into a leading `system` message item, trading the checked property that a persona renders byte-identically across wires for a caching gain nobody has measured. |

---

## What could not be confirmed

The load-bearing facts were checked against the **published OpenAI OpenAPI schema**
(`openai/openai-openapi`, `openapi.yaml`, `info.version: 2.3.0`), fetched on this machine. The
documentation site itself answers `403` to a non-browser client, so the schema is the source
throughout. Every request field, item shape, streaming event name, usage field and enum quoted
in this file and in the adapter is present there.

**One thing is inferred rather than stated: whether `cache_write_tokens` is a SUBSET of
`input_tokens`.** The schema documents `input_tokens_details` as *"a detailed breakdown of the
input tokens"*, and `cached_tokens` is unambiguously a subset under that wording, so the same
reading is applied to its sibling. The adapter therefore subtracts both. If a host instead
reports the two as siblings of the total, this adapter's `input_tokens` would be low by the
cache-write count; saturating subtraction keeps the figure non-negative either way, and the
arithmetic is in one function (`openai_responses::apply_usage`) with this note attached to it.
A live call against a host that actually writes to cache would settle it in one reading.

**The live smoke did not run.** `examples/smoke.rs` is gated off in CI by construction (it is
an example, not a test) and needs a key for a Responses-serving endpoint in the environment.
No such variable was set in this session's environment, and the ground rules forbid looking
for keys in files, so the mock is the evidence: three adapters, one table, fifteen cases, plus
a four-way loop conformance turn over real loopback sockets. What that does not buy is stated
plainly — a mock agrees with whatever this code believes, and only a live endpoint can
disagree.
