# `jesse-agent`

The provider-neutral agent layer: one request/response model, one streaming event
vocabulary, per-wire adapters, and **the tool-calling turn loop that runs on top of them**.

* **D1** built the provider layer — `Request`, `Event`, `Provider`, and the
  `AnthropicMessages` / `OpenAiChat` adapters.
* **D2** built the loop — `turn::run_turn`, the tool boundary, the thread store, budgets,
  framing, and the usage ledger seam.

No dependency on `bridge/` in either direction.

## The boundary statement

Three sentences, and everything in `src/tools/`, `src/scope.rs` and `src/loop.rs` exists to
make them structurally true rather than rules somebody remembers:

1. **Dispatch is by exact manifest name.** A name the tool set does not resolve is
   `ToolError::Refused("tool not granted")`, recorded in the trace by name, and forwarded
   nowhere — no fuzzy match, no fallback, no shell.
2. **Scope never comes from arguments.** A tenant, a user and a workspace are passed to
   every tool by the caller. A schema that declares one is refused at manifest-build time.
3. **External writes are exposed at no level.** `ToolSetBuilder::add` takes an
   `ExposedClass`, which has no `ExternalWrite` arm, so there is no expression a call site
   can write that adds one.

## Layering

```
  ┌────────────────────────────────────────────────────────────┐
  │  turn::run_turn — the loop                                 │
  │  decides · calls tools · frames results · projects to the  │
  │  bridge's two mid-turn events                              │
  │                                                            │
  │  tools  scope  thread  budget  framing  usage              │
  ├────────────────────────────────────────────────────────────┤
  │  provider::{Request, Event, Provider, Usage, ProviderError}│  the neutral vocabulary
  ├──────────────────────────┬─────────────────────────────────┤
  │  provider::anthropic     │  provider::openai_chat          │  every wire string
  │  AnthropicMessages       │  OpenAiChat                     │  lives here
  ├──────────────────────────┴─────────────────────────────────┤
  │  provider::http                                            │
  │  one client · retries · redaction · audit line · SSE frames│
  ├────────────────────────────────────────────────────────────┤
  │  provider::config — plain values; NOTHING reads the env    │
  └────────────────────────────────────────────────────────────┘
```

### What each layer owes

| Layer | Owns | Must never |
|---|---|---|
| `turn` (loop.rs) | The loop, the trace, and the projection to the bridge's two mid-turn events. | Learn anything about a wire, or let a tool result reach the model unframed. |
| `tools` | The boundary: a set built AT a level, dispatch by exact name. | Check a level at call time — filtering happens once, at construction. |
| `framing` | Every tool result the model sees. | Filter or rewrite content. It says what the text *is*; it never decides what it *means*. |
| `thread` | The conversation, in the neutral model, stored as delivered. | Re-derive a frame on load — a stored thread must not change when the framing code does. |
| `budget` | The ceilings. | Check anything mid-call. The tokens are already bought. |
| `usage` | One record per provider call. | Fail a call. A full disk must not break the product. |
| `provider` (mod.rs) | The neutral types. `Request`, `Event`, `Usage`, `StopReason`, `ProviderError`, `Capabilities`, `Wire`. | Name a vendor or an HTTP status. |
| adapters | The request body, and an `SseDecoder` that turns frames into events. | Retry, time, redact or audit — those are shared, and duplicating them is how two wires quietly stop agreeing. |
| `http` | Client, retry policy, backoff, redaction, the audit line, SSE framing, `EventStream`. | Learn one wire's schema. (The one header that looks like an exception — `anthropic-version` — is set by the adapter, in its own copy of the config.) |
| `config` | Resolved values, per-host defaults, quirks. | Read `std::env`. The caller resolves. |

## The loop's lifecycle

```
  load thread ──► append the user's message ──┐
                                              │
   ┌──────────────────────────────────────────┘
   ▼
  check every budget ceiling ─── over? ──► stop, with the answer so far
   │
  build the request: system blocks (cacheable) · the thread · the MANIFEST
   │
  stream ─── TextDelta ──────────► the sink, as it arrives
   │     └── ToolUse* ───────────► collected
   │
  record ONE usage record ──────► the ledger seam
  append the assistant message ─► the thread
   │
  stop_reason?
   ├── end_turn / max_tokens / stop_sequence ──► done
   └── tool_use ──► dispatch (manifest order) ──► ToolActivity to the sink
                    frame every result ─────────► append as tool_result blocks
                    └──────────────────────────── iterate
```

`run_turn` returns a `TurnOutcome`, never a `Result`. A failed turn still has a thread id, a
partial answer, a bill and a trace, and every one of those is something the caller must
handle; a `Result` would let it `?` past all of it.

### What reaches a client

The loop owns the **projection** down to the bridge's mid-turn contract
(`bridge/src/harness/mod.rs`): exactly a text delta and a coarse tool-activity hint.
`EventSink` has those two methods and no others. `Event` is deliberately richer because the
LOOP is its consumer; tool inputs, tool results, token counts and per-tool timings are not
sink events, because each would carry vault content to a phone screen.

`ToolActivity::refused` is the STRUCTURAL refusal only — it is emitted at dispatch time,
when the only refusal that has happened is "this name is not in the manifest". A tool that
runs and then refuses is recorded in the trace, not in a mid-turn event.

### Dispatch order and parallelism

A batch is dispatched in **manifest order**, with the model's own order breaking ties. A
fixed key makes a turn reproducible, which is most of what makes a failing turn diagnosable.

**Parallel only when every requested tool is `Read`.** The reason is ordering, not danger: a
write and a read of the same document in one batch have no defined order, and the model,
which asked for both in one breath, has no way to say which it meant. Reads commute.
`Egress` is not `Read` for this purpose — two requests leaving the host in an order nobody
chose is worse than two requests leaving slowly.

## Levels and action classes

`Level` is the same ordered cumulative vocabulary as the bridge's `harness::Capability`
(`Basic` < `Read` < `Write`), declared here because this crate does not depend on the
bridge. D4 maps the two, and the mapping is meant to be the identity.

| `ActionClass` | Basic | Read | Write |
|---|:--:|:--:|:--:|
| `Read` — reads state, changes nothing | | ✅ | ✅ |
| `Egress` — a read that sends caller-authored bytes off the host | | ✅ | ✅ |
| `VaultWrite` — changes the owner's own documents | | | ✅ |
| `ExternalWrite` — changes a third party's state | | | |

`Egress` is named separately from `Read` because it is the **exfiltration channel the
injection threat model cares about**. The danger of a tool result is not that something was
read; it is that a directive hidden in one document can make the model put the contents of
another into a URL. Framing is the mitigation for the instruction half; this class is what
lets a future policy see the other half without re-auditing every tool. It is granted at
`Read` today — a read-only assistant that cannot look anything up is not the product — and
the point of the separate name is that withdrawing it later is a one-line policy change.

`ExternalWrite` is granted at **no level in Phase 1**, and the type makes that a
compile-time fact rather than a runtime check. See the boundary statement above.

## Framing tool results

Every tool result the model sees goes through **one function**,
`framing::frame_tool_result`, which is the fourth instance in this repository of a discipline
the bridge already applies three times: `context.rs` frames injected history, `prompt.rs`
frames device blocks through one `frame_device_context` seam, and `vision.rs` splices
transcriptions into tag-neutralised `<attachment_view>` elements.

It does four mechanical things and no more:

1. **Says what the text is** — a header naming the tool, and a sentence stating that what
   follows is data returned by a tool, not instructions, and that a directive inside it must
   not be acted on.
2. **Strips ASCII controls except newline.**
3. **Neutralises the frame's own closing token**, walking characters (never bytes) so a
   codepoint next to a forged tag cannot be split. Unlike the bridge's version it copies the
   matched run through from the original, so the casing survives and the only change is one
   inserted space.
4. **Caps the body at 24 000 bytes**, truncating on a char boundary with a visible marker
   that states the untruncated size.

It is **not a filter**. An injection line comes through byte-identical and inert; deciding
that a tool result is malicious and silently returning something else is undecidable and
would make a tool that lies about what it read.

Structured results are pretty-printed inside the frame. Images cannot go inside a text frame
and ride alongside it as their own content blocks, with the frame stating how many follow.

## Budgets

**Every ceiling is checked BEFORE a provider call, never during one.** The tokens are bought
the moment the request is accepted, so aborting mid-call saves nothing and throws away
output that was paid for.

| Ceiling | Default | How it is checked |
|---|---|---|
| `max_iterations` | 24 | against completed calls |
| `max_tool_calls` | 40 | against dispatched calls |
| `max_output_tokens_per_call` | 8192 | a **cap** on the request, not a stop condition |
| `max_input_tokens_per_turn` | 400 000 | against spend **plus a prediction** |
| `max_wall` | *(from the caller)* | against `Clock::since_start` |
| `max_cost_usd` | `None` | against spend **plus a prediction** |

The two predicted ceilings use the **previous call's own figure** as the prediction, which is
sound because a turn's message list only grows: each iteration appends the assistant message
and its tool results and re-sends the whole thread, so the next prompt is at least as large
and at least as expensive. That makes them bounds the loop stops *before* crossing rather
than ones it notices after. It is deliberately conservative — a turn can stop one iteration
earlier than a perfect oracle would, which is the right direction for a spend limit to be
wrong in.

`max_wall` has no default because only the caller knows what it is waiting for: a phone
spinner and an overnight batch are three orders of magnitude apart.

`PriceDeck` has the **same field names as `bridge/src/config.rs`'s**, so D4 adopts it rather
than defining a second deck. Cache writes are priced at the input rate — an approximation
(the real figure is ~1.25×) taken so this type stays the bridge's deck; a fourth rate belongs
in whichever change adds it on both sides at once.

## The usage record

**No code path that spends money exists without a record here.** Every provider call
produces exactly one `UsageRecord`, including calls that failed — a call that streamed and
then errored is billed by every host in this deployment. A retried call is ONE call: the
attempt count rides in the record and the latency is what the caller actually waited.

This is the seam the product's **per-user ledger and budget enforcement grow from**. The
record carries the scope ids for exactly that reason: keyed on turn id it is an audit trail,
keyed on tenant it is a bill.

```json
{
  "v": 1,
  "ts": "2026-08-30T11:07:38Z",
  "turn_id": "cli-75225",
  "conversation_id": "direct-cc9b4065-…",
  "tenant": "local", "user": "owner", "workspace": "default",
  "wire": "messages", "model": "mock-model",
  "provider_request_id": "msg_call_1",
  "input_tokens": 1240, "output_tokens": 18,
  "cost_usd": 0.00399,
  "latency_ms": 1,
  "stop_reason": "tool_use",
  "attempt": 1,
  "phase": "main"
}
```

Optional counts are omitted when the wire did not report one: `None` and `0` are different
and are kept different. `phase` is `main` for the turn's first call and `tool_followup` for
every call after tool results were spliced in — two arms rather than an iteration index,
because the question it answers ("how much of the bill is the tool loop") is a `grep` with
the label and a grouping query without it.

**Content-free**: counts, ids, a model name, a latency, a stop reason. No prompt, no answer,
no tool arguments, no tool results, and no tool names. `JsonlUsageSink` writes mode-0600
lines and absorbs its own failures, complaining once — a full disk must not break the
product, and a line per failure would flood the log that explains it.

## Threads

`ThreadStore` is a small synchronous trait with two implementations: `FileThreadStore`
(one append-only JSONL per thread plus a temp-and-rename metadata file, mode 0600, fsync on
append) and `MemoryThreadStore`.

Thread ids are `direct-<uuid v4>`. The prefix cannot collide with the bridge's synthetic
`local-` ids or with a bare CLI session id, and it names where the thread came from.
`ThreadId`'s inner string is private and the only constructors are `generate` and a
validating `parse` — because the id is a **filename**, so an id containing `..` would be a
path traversal handed to the store by whatever passed `--thread`.

**Tool result content is stored as delivered — framed.** Re-deriving the frame on load would
make a stored thread's meaning depend on the version of the code that read it, so improving
the framing would silently rewrite history. An audit log that changes when you improve the
code is not an audit log.

## The trace

Content-free by construction: per tool a name, an `ActionClass`, a duration and one of three
outcomes (`ok` / `refused` / `failed`). There is nowhere to put an argument or a result. Same
property `bridge/src/turntrace.rs` documents and tests for its timing log, arrived at the
same way — by there being no field that could hold content.

**`refused` and `failed` are not folded together.** A refusal is the boundary working,
possibly under attack; a failure is the boundary not being what happened. They look the same
to the model and are opposite to an operator.

## The CLI

```
cargo run -p jesse-agent --bin jesse-agent -- turn \
  --wire chat --base-url http://127.0.0.1:8080/v1 --model some-model \
  --token-env SOME_PROVIDER_API_KEY \
  --root ./workspace --level read \
  [--thread direct-…] [--system-file persona.md]... \
  [--budget-iterations N] [--budget-tool-calls N] [--budget-output-tokens N] \
  [--budget-input-tokens N] [--budget-wall-secs N] [--budget-cost-usd F] \
  [--price-in F] [--price-cached F] [--price-out F] \
  "your message"
```

`--token-env` names the **variable** the key lives in; the key is never an argument, so it
stays out of shell history and `ps`. Nothing prints the token or the base URL.

stdout is the answer, streamed, then one JSON line with the outcome. stderr is the tool
activity and the trace. Exit codes: `0` finished (a `max_tokens` truncation included — the
answer is real), `2` a budget stopped it, `3` cancelled, `1` anything else. Ctrl-C cancels
the **turn**, not the process, so the partial answer, the thread append and the usage records
all still happen.

`--root` selects the **fixture** tool set (`fs_list`, `fs_read`, `fs_write`, jailed to the
root with symlink resolution and `..` refused). **D3 replaces it with the real vault tool set
behind the same trait.**

## Invariants

These are the properties the conformance suite exists to hold, and the ones to re-check
before changing anything here.

### 1. Usage arithmetic — `input_tokens` EXCLUDES cache reads

`input_tokens`, `cache_read_tokens` and `cache_write_tokens` are **disjoint**; the prompt
total is their sum. This is the convention `bridge/src/shadow.rs` already documents for
`ShadowUsage`, restated identically here so `impl From<Usage> for TokenUsage` is a rename
and not a recalculation.

Only one wire gives it away free:

| Wire | Reports | Adapter does |
|---|---|---|
| Messages | `input_tokens` already excluding `cache_read_input_tokens` | takes both verbatim |
| Chat | `prompt_tokens` **inclusive** of `prompt_tokens_details.cached_tokens` | `input_tokens = prompt_tokens - cached_tokens` |

Get this wrong and every cached turn is billed twice — once at the input rate and once at
the cache-read rate — and the error reads as "caching made things more expensive".

`TokenUsage` is shaped **exactly** like `ShadowUsage`'s four fields, with the same names
and the same serde attributes, so D4 adopts it as `pub type ShadowUsage =
jesse_agent::TokenUsage;` rather than defining the shape twice.

### 2. No vocabulary leak above the provider layer

No adapter-specific type or string appears outside `src/provider/`. A caller names `Wire`,
never a vendor; reads `Event`, never an SSE frame; handles `ProviderError`, never an HTTP
status. `build_provider` is the single place `Wire` maps onto a concrete adapter.

`Wire::Responses` is declared and unimplemented: constructing it returns
`ConfigError::UnimplementedWire` — a typed error, never a panic, and never a silent
fallback to `Wire::Chat`.

### 3. Redaction — nothing logs a token, a URL, or a body

* Every provider-supplied string is passed through `http::redact` before entering a
  `ProviderError`, then capped at 200 chars (redact first, *then* truncate — the other
  order leaves the first 200 characters of a credential in the log).
* `AuthScheme` and `ProviderConfig` have a hand-written `Debug` that prints
  `Bearer(<redacted>)`. A derived one would print the key at exactly the moment someone is
  debugging a 401 and about to paste the output somewhere.
* The audit line carries token counts, a latency, a stop reason and an attempt count.
  Never the URL, never a body, never model output.

### 4. Retry rules

| Class | Retried | Why |
|---|---|---|
| `RateLimited { retry_after }` | ✅, honouring `retry-after` | the provider said when |
| `Overloaded` (503 / 529 / any 5xx) | ✅ | server-side and transient |
| `Transport`, `Timeout` | ✅ | the call never landed |
| `Auth` (401/403) | ❌ | a bad key does not improve |
| `NotFound` (404) | ❌ | the model is not served here |
| `BadRequest` (other 4xx) | ❌ | the request is what is wrong |
| `Cancelled` | ❌ | the caller asked to stop |
| `Protocol` | ❌ | a host that speaks it wrongly does so twice |

`ProviderError::is_retryable` is an exhaustive match with **no wildcard**, so a new arm
fails to compile until someone decides.

**A retry may only happen before the caller has seen an event.** Every attempt is inside
`Provider::stream`'s future, before `EventStream` exists; a failure after that surfaces as
`Event::Error` for D2 to decide about with the partial answer in hand. Replaying a stream
whose prefix the caller already consumed would hand it a duplicate it cannot identify.

Backoff is full jitter — `uniform(0, min(max, base · 2^(n-1)))` — except when
`retry-after` is present, which is obeyed un-jittered and capped at `max_backoff`.

### 5. The classification mirrors `bridge/src/health.rs`

`health.rs`'s prober predicts whether a real call would work, so a status it calls fatal
and a real call calls retryable would make a green health light meaningless. 401/403, 404,
5xx and the three transport classes map the same on both sides. They diverge on the
remaining 4xx **on purpose**: the prober tolerates them (it asks "is this endpoint alive"),
this layer does not (it asks "did this call produce tokens").

### 6. Tool arguments are validated, never silently empty

Fragments are accumulated per block and parsed as JSON when the block closes. A block whose
arguments do not parse is `ProviderError::Protocol` **naming the tool** — never a
`ToolUseEnd` with `{}`, which would send the loop off to call a tool with no arguments,
a plausible-looking call that does the wrong thing. An *empty* argument string is the one
exception and is not a violation: a no-argument tool legitimately streams nothing.

## Quirks

Per-host toggles, each documented in `config.rs` with the host that motivated it. All are
negative capabilities ("this host rejects the extra field"), and all default **off** —
conservative, because the failure modes are not symmetric: an unsent optional field costs
a little quality, an unaccepted field costs the whole call.

| Quirk | Default | Motivating host |
|---|---|---|
| `reasoning_effort_supported` | on for `api.openai.com`, else off | `api.fireworks.ai` rejects the unknown field |
| `multiple_system_messages` | off **everywhere**, OpenAI included | vLLM-style and Fireworks-hosted chat templates accept only one system message; concatenation works on all of them |
| `strict_tools_supported` | on for `api.openai.com`, else off | hosts that imitate the chat schema reject `function.strict` |

When a quirk drops something the caller asked for, one note goes to stderr. Never silent —
a caller that set `strict` believed the arguments would be schema-constrained.

## Testing

```
cargo test -p jesse-agent --all-targets   # unit tests + both conformance suites
cargo clippy -p jesse-agent --all-targets -- -D warnings
cargo fmt -p jesse-agent --check
```

`tests/loop_conformance.rs` runs **one three-step tool turn three ways** — the Messages
adapter over a loopback socket, the Chat adapter over a loopback socket, and the scripted
provider with no wire at all — and asserts the thread each leaves is **identical**. That is
the property the neutral model was built for, and it is the only test that can fail if the
loop ever learns something about a wire.

`tests/loop_behaviour.rs` is what the loop does when the answer is not "keep going":
refusal, every budget ceiling, cancellation between tools, dispatch ordering and
parallelism, and the usage ledger. These use `provider::scripted`, because none of those
properties is a property of a wire and expressing "the model now asks for a fourth tool
call" as hand-written SSE in two dialects would test the adapters through the loop.

`provider::scripted` is compiled only under `cfg(test)` or the `scripted` feature. The
crate takes a **dev-dependency on itself** with that feature on, which is how an integration
test (which links the library without `cfg(test)`) can see it. `cargo build` is unaffected —
dev-dependencies are not built — so a release build contains no `Provider` that fabricates
answers.

`tests/provider_conformance.rs` runs **one table of cases against both adapters through
`&dyn Provider`**. That structure is the point: a per-adapter test file lets a behaviour
drift between wires and calls it "the OpenAI one works differently". Here a divergence is a
failing row. Wire-specific expectations live in one `expect_body` hook per case, so
"cacheable produces `cache_control` on Messages and nothing on Chat" is one row asserting
both halves.

No network: each case binds a real loopback socket and speaks HTTP/1.1 by hand, the same
approach `bridge/tests/integration.rs` takes for its mock helper. The mock is hand-rolled
rather than `axum`-based because three cases need control a framework hides — delivering
one frame across three writes, holding a response open forever, and *observing* that the
client closed the connection.

### The examples

`examples/smoke.rs` is a live smoke: an example, not a test, so `cargo test` never runs it
and CI only compiles it. It exists because the conformance mock agrees with whatever this
code believes; only a live endpoint can disagree.

`examples/manifest.rs` prints the manifest a fixture tool set produces at each level, for a
person to read. What it shows is asserted properly in `tests/loop_conformance.rs`.

```
JESSE_AGENT_WIRE=chat \
JESSE_AGENT_BASE_URL=https://…/v1 \
JESSE_AGENT_MODEL=… \
JESSE_AGENT_TOKEN_ENV=SOME_PROVIDER_API_KEY \
cargo run -p jesse-agent --example smoke
```

`JESSE_AGENT_TOKEN_ENV` holds the **name** of the variable the key lives in — the key
itself is never a value passed on a command line, so it stays out of shell history and
`ps`. The program prints neither the token nor the base URL.

## Adding a third adapter — the D7 checklist

Written now, so D7 checks a list rather than guessing. `Wire::Responses` is the next one.

1. **Add the arm to `build_provider`.** It is the only place `Wire` maps to an adapter.
   Removing `ConfigError::UnimplementedWire` for that wire is the signal the work is done.
2. **New file under `src/provider/`.** Every string of the new schema lives in it and
   nowhere else. If a wire word has to appear in `http.rs` or `mod.rs`, the design is wrong
   — take the detour through `SseDecoder` instead.
3. **Implement `Provider`:** `wire()`, `capabilities()` (report what *this deployment* can
   do, not what the schema defines — see `OpenAiChat::capabilities`, whose `thinking`
   tracks the quirk), and `stream()`, which builds a body string and calls
   `http::start_call`. Do not open a `reqwest::Client`, do not retry, do not time, do not
   log — those are shared, and a second copy is how the wires stop agreeing.
4. **Implement `SseDecoder`:** `on_frame` and `on_eof`. Push errors as `Event::Error`
   rather than returning them, so text already received still reaches the caller.
5. **Honour the event ordering guarantees** on `Event`: `ToolUseStart` → `ToolUseArgsDelta*`
   → `ToolUseEnd`; at most one `Usage` and one `Done`, `Usage` first; exactly one of `Done`
   or `Error` last.
6. **Normalise usage to the invariant.** Work out whether the wire's prompt count includes
   its cached count, and subtract if it does. Document the arithmetic where you do it.
   Leave a count `None` if the wire does not report it — `None` and `0` mean different
   things to a cost model.
7. **`on_eof` must fail loudly.** A stream that ended without the wire's terminator is
   `Protocol`, not a `Done` with a guessed stop reason.
8. **Validate tool arguments at block close**, naming the tool on failure. See invariant 6.
9. **Map the stop reasons** onto `StopReason`, with `Other(String)` for anything unmapped —
   an unanticipated stop reason is still a completed call.
10. **Add quirks, not branches**, for host differences, each documented with the host that
    motivated it and defaulting to the conservative posture.
11. **Add nothing to the case table — just run it.** Extend `run_case`'s wire list and the
    `Script` struct with the new wire, then make all existing rows pass. A row that cannot
    pass is either a genuine wire difference (put it in `expect_body`) or a bug.
12. **Check the audit line and `Debug` output** carry no token, URL or body for the new
    adapter, and that any new secret-bearing config field has a hand-written `Debug`.

## Known external issue (not a defect in this crate)

The local Anthropic-shaped gateway at `~/jesse-gateway/gateway.py` rejects requests from
this crate with `400 invalid JSON request`, while byte-identical requests from `curl`
succeed. Cause: it copies client headers into `up_headers` **preserving their case**, then
assigns `up_headers["Content-Length"]`. A client sending a lowercase `content-length` —
which `reqwest`/`hyper` always does, and which RFC 7230 explicitly permits — leaves two
Content-Length headers on the upstream request, and the stale one truncates the body the
gateway just grew by injecting its identity notice. `curl` capitalises, so it overwrites
cleanly and never shows the bug. The fix belongs in that gateway (normalise header names
before assigning), not here; the D1 live smoke reached `ds4` directly instead.
