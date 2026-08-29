# `jesse-agent`

The provider-neutral agent layer. **D1 (this crate today) is the provider layer only:**
one request/response model, one streaming event vocabulary, and the adapters that speak
it to a real endpoint. There is no agent loop yet — D2 adds it on top of exactly what
`provider` exposes.

No dependency on `bridge/` in either direction.

## Layering

```
  ┌────────────────────────────────────────────────────────────┐
  │  D2: the loop            (not in this crate yet)           │
  │  decides · calls tools · projects to the bridge's two      │
  │  mid-turn events                                           │
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
| `provider` (mod.rs) | The neutral types. `Request`, `Event`, `Usage`, `StopReason`, `ProviderError`, `Capabilities`, `Wire`. | Name a vendor or an HTTP status. |
| adapters | The request body, and an `SseDecoder` that turns frames into events. | Retry, time, redact or audit — those are shared, and duplicating them is how two wires quietly stop agreeing. |
| `http` | Client, retry policy, backoff, redaction, the audit line, SSE framing, `EventStream`. | Learn one wire's schema. (The one header that looks like an exception — `anthropic-version` — is set by the adapter, in its own copy of the config.) |
| `config` | Resolved values, per-host defaults, quirks. | Read `std::env`. The caller resolves. |

### What D2 adds

The loop: send, read events, execute the tool calls it sees, append `ToolResult` blocks,
send again, stop when `StopReason` is not `ToolUse`. It also owns the **projection** down
to the bridge's mid-turn contract (`bridge/src/harness/mod.rs`): exactly a text delta and
a coarse tool-activity hint. `Event` is deliberately richer than that contract because the
loop is the consumer; what reaches a phone screen is the loop's filter, not this layer's.

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
cargo test -p jesse-agent            # unit tests + the conformance suite
cargo clippy -p jesse-agent --all-targets -- -D warnings
cargo fmt -p jesse-agent --check
```

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

### The live smoke

`examples/smoke.rs` is an example, not a test, so `cargo test` never runs it and CI only
compiles it. It exists because the conformance mock agrees with whatever this code
believes; only a live endpoint can disagree.

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
