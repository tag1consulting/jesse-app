# Jesse Bridge (Rust)

Turns "Ask Jesse" / "Tell Jesse" requests from the phone into headless Claude
Code runs against the vault. **Cowork is not scriptable; Claude Code is**, and it
loads the same `CLAUDE.md`, so you get the same Jesse.

Axum + Tokio. Compiles to a single static binary — drop it on the laptop and run.

## Run

```bash
cd Code/jesse-mobile/bridge

export JESSE_TOKEN="$(openssl rand -hex 24)"   # save this for the phone
export JESSE_VAULT="$HOME/devel/tag1/jesse"

# Bind to the tailnet IP so the phone can reach it. Find it with:
#   tailscale ip -4
export JESSE_BIND="$(tailscale ip -4 | head -1)"   # or 127.0.0.1 for local test

cargo run --release
```

On startup the bridge prints a **pairing QR** plus a plaintext fallback line:

```
█▀▀▀▀▀█  …  █▀▀▀▀▀█
…  (terminal QR)  …
Pair by scanning the QR above, or enter manually:
  host=100.64.0.1  port=8765  token=<token>
```

Open the app's **Settings → Scan to pair**, scan that QR, and host/port/token
fill in automatically — no more typing the token by hand on every restart. The
QR encodes `jesse://pair?host=…&port=…&token=…`. Manual entry of the printed
values still works as a fallback.

The advertised host defaults to `JESSE_BIND` (the tailnet IP, which is reliably
reachable; the `ts.net` name can have DNS quirks). To put the MagicDNS hostname
in the QR instead, set `JESSE_ADVERTISE_HOST`:

```bash
export JESSE_ADVERTISE_HOST="your-host.tailnet.ts.net"
```

A clean `cargo build --release` is the gate — if it doesn't compile, it isn't done.

## Source layout

The crate is a small library (`src/lib.rs`) plus a wiring-only binary
(`src/main.rs`). The library is split along the sections the code grew into, so a
change lives in one focused module:

| Module | What it owns |
| --- | --- |
| `config` | `Config`, `from_env`, `clamp_timeout_secs`, the `env_string`/`env_parse` helpers, and the default consts |
| `prompt` | the Ask/Tell wrapper + floor consts, `build_prompt`, and the per-turn `clock_line` header prepended to every turn |
| `auth` | `check_auth` (constant-time bearer compare) and the `ApiError` alias |
| `bind` | `is_bind_allowed` / `env_truthy` (bind safety) |
| `ratelimit` | the token-bucket `RateLimiter` |
| `jobstore` | the turn-survives-disconnect job store, persistence worker, eviction, `TurnGuard`; **live-stream state is isolated in `jobstore::streams`** as `StreamRegistry` — its broadcast map is a private field, so the "never hold the `streams`, `jobs`, and `aborts` locks at once" invariant is a module boundary, not a comment |
| `claude` | `build_claude_args` + `run_claude_streaming` and the `stream-json` parsing/classification (`parse_stream_line`, `classify_result_value`, `resolve_stream_outcome`) |
| `attachments` | base64 decode + length helpers, magic-byte sniff, per-request `ScratchDir`, validation |
| `apns` | the optional push path (device store, JWT minting, transport, completion→push decision) |
| `state` / `handlers` / `sse` | shared `AppState`, the Axum handlers + router, and the SSE body/forwarder |
| `startup` | pairing-QR payload + the `binary_exists`/bind startup checks |

Unit tests live in each module's `#[cfg(test)]`; the `app()`-router tests are a
`tests/` integration target. `scripts/ci-guards.sh` scans **all** `bridge/src`
sources, so the security guards apply across every module.

## Test from the laptop

```bash
# Liveness: 200 {"ok":true}, unauthenticated. The vault + claude binary paths are
# operator detail and are returned ONLY to an authenticated caller (bearer token),
# so an unauthenticated probe learns nothing but "the bridge is up".
curl -s http://127.0.0.1:8765/health
curl -s http://127.0.0.1:8765/health -H "Authorization: Bearer $JESSE_TOKEN"

# Fresh ask — response includes a session_id.
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"What is on Today.md?"}'

# Follow up — pass the session_id back to continue the same thread.
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"Just the first one — when is it due?","session_id":"<id-from-above>"}'
```

## Threads / followups

Each response returns a `session_id`. Omit it (or send `null`) for a fresh
session — the default, so every Ask re-reads the vault. Pass it back to
**continue the thread**, which is what clarification followups need (the question
Jesse asked and your half-answer are conversation state, not vault facts).
Resuming keeps `CLAUDE.md` loaded and retains filesystem access — it only adds the
prior turns on top.

## Surviving a client disconnect (job store)

A turn runs on its own detached task that owns the `claude` child, so it is **no
longer tied to the HTTP connection**. If the phone suspends and the socket drops
mid-turn, the turn keeps running to completion instead of being killed — the
reply is never lost.

`POST /jesse` returns the `job_id` **immediately** — it never holds the
connection:

- Always → **`202 { "job_id": "...", "status": "running" }`**, the instant the
  turn is spawned. The turn then runs server-side and lands in the job store; the
  phone fetches the reply via `GET /jesse/result/{job_id}` (poll) and/or
  `GET /jesse/stream/{job_id}` (live tokens).

> **Why immediate, and not a grace hold?** An earlier design held the connection
> up to a `JESSE_GRACE_SECS` window so a fast turn could answer inline with a
> `200`. That delivered the `job_id` *late*: if the socket dropped during the
> hold (phone suspended, NAT/idle timeout), the turn was already running detached
> but the phone never received its id — so it could never poll the reply. The
> turn was **orphaned**. Returning the `job_id` up front shrinks that
> unrecoverable window from a multi-second hold to a single request/response
> round-trip. `JESSE_GRACE_SECS` and the inline-`200` path were **removed**
> (see the CHANGELOG note at the end of this file). There is no inline-reply path
> anymore — every turn is fetched by id.

Fetch the result later by id:

```bash
curl -s http://127.0.0.1:8765/jesse/result/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "status": "running" }
#   { "status": "done", "response": "...", "session_id": "..." }
#   { "status": "failed", "error": "..." }
#   { "status": "cancelled" }
```

Same bearer auth as `/jesse`. An unknown or evicted id → **`404`**.

### Cancel an in-flight turn

```bash
curl -s -X POST http://127.0.0.1:8765/jesse/cancel/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → 204 No Content
```

`POST /jesse/cancel/{job_id}` stops a running turn: it **aborts the turn's task**,
which drops the `claude` child (`kill_on_drop`) — killing the process so it stops
burning tokens on a reply nobody will read — and **frees the concurrency slot** the
turn held. The job moves to a terminal **`cancelled`** state, so a later
`GET /jesse/result/{job_id}` returns `{ "status": "cancelled" }` (a clean status,
not a `404`).

Same bearer auth as `/jesse`. **Idempotent:** an unknown id, an already-finished
job, or a repeat cancel all return **`204`**, never an error — the phone fires this
best-effort and may race the turn's own completion. A turn that finishes in the
same instant it's cancelled keeps whichever terminal state landed first (the stored
reply is never clobbered).

### Eviction model — a finished reply isn't lost while the phone is away

The clock for a completed job starts at its **first successful retrieval**, not at
completion:

- A finished reply that has **never been fetched** is held for the full
  **`JESSE_JOB_TTL_SECS`** (default **`86400`** = 24h). So a turn that completes
  while the phone is suspended or off the tailnet is still there when it re-checks.
- Once a reply has been **fetched at least once**, it's kept only
  **`JESSE_RETRIEVAL_GRACE_SECS`** longer (default **`600s`**) — a short window so
  an immediate re-poll still succeeds — then evicted. A fetched reply shouldn't
  linger for a day.
- **Running** jobs are never evicted.

Eviction runs on a **periodic background task** (every 60s), **not** on the
request hot path. An earlier version swept opportunistically at the top of
`/jesse`, `/jesse/result`, and `/jesse/stream`, which meant a sweep's file
unlinks happened **under the jobs lock on a request** — one slow disk could stall
every concurrent request. The sweep now (a) collects evictions under the lock but
performs the actual file unlinks off-lock on the persistence worker, and (b) runs
on its own timer task, so a request never waits on eviction.

### Persistence across a restart

Completed results are also **persisted to disk** — one JSON file per job under
**`<JESSE_STATE_DIR>/jobs`** (default `~/.jesse-bridge/jobs`) — and reloaded on
startup, so a bridge restart or laptop reboot while you're away does **not** lose a
finished-but-unretrieved reply. The same TTL/eviction applies to reloaded jobs
(anything already past its window is dropped, and its file deleted, on load).

Only the finished result and its timing metadata are written — **never** the bearer
token or any secret. Running jobs aren't persisted (there's no result yet). Set
`JESSE_STATE_DIR=` (empty) to disable persistence and run in-memory only.

**Persistence is off-lock and never blocks a request.** The job store mutates its
in-memory state under the `jobs` lock and, still under that lock, **enqueues** the
already-serialized snapshot to a dedicated **persistence worker thread** (an O(1)
hand-off). The blocking disk write (`fsync`) and the eviction unlinks run on that
worker, entirely off the `jobs` lock — so a slow disk can no longer serialize the
whole bridge behind a completion, a cancel, or a result poll. Enqueuing under the
lock also keeps disk ops in the **same order** as the in-memory transitions, so a
first-retrieval write can never resurrect a file a later eviction deleted.
Persistence remains **best-effort** (a write failure is logged, never fatal); the
in-memory store always serves the result for the process's lifetime regardless.

### App-side counterpart — a delivered reply is never silently dropped

The bridge holding the reply only helps if the app reliably *renders* it once
fetched. The app's `RunCoordinator.finish` upholds the matching invariant: after a
turn completes, the app is in **exactly one** of {reply shown, recoverable error +
Re-check shown} — "spinner stops, nothing shown, no error" is unreachable.

- **Root cause it fixes (2026-06-28).** `finish` previously re-fetched the thread
  by id (`fetchThread`) and wrapped the whole append-and-save in `if let thread =
  …`. When that fetch returned nil (the thread wasn't resolvable in the run's
  `ModelContext`), the body was skipped but `clearRun` still ran — dropping the
  reply with no turn and no error. `try? context.save()` and an empty `displayText`
  (appending a blank turn) were the two adjacent silent failures.
- **Now:** the live `send` path appends to the `JesseThread` reference it already
  holds (no fetch, no nil risk). The by-id fetch is kept **only** for the
  resume/recheck path. If that fetch finds nothing, or the reply is empty, or the
  save throws, `finish` keeps the `job_id` retained and surfaces a distinct
  recoverable error (so the bridge's still-held reply is one **Re-check** away),
  rather than clearing into nothing. See `RunCoordinatorFinishTests`.

Two follow-on root causes in the same `finish`, fixed 2026-06-28:

- **A spoken-only reply was dropped as "empty."** The empty-reply guard keyed on
  `reply.displayText`, which strips the `SPOKEN:` line (see [Voice
  requests](#voice-requests)). A voice turn whose entire content was that one line
  therefore had an empty `displayText` and hit the Re-check path — so it both
  "showed empty" and "stayed silent," losing the answer. **Fix:** split "no content
  at all" from "content that lives only in the spoken line." When `displayText` is
  empty but `reply.spokenText` is non-empty, record a `jesse` turn whose text **is**
  the spoken line (so the transcript/history aren't blank) and speak it when
  `voice` is on — the same delivery as a normal reply. Only a *genuinely* empty
  reply (both `displayText` and `spokenText` empty) keeps the recoverable error +
  Re-check.
- **A re-entry of `finish` could double-append the reply.** A save failure retains
  `inFlight`, and Re-check / `resume` legitimately re-polls the same completed job
  and re-runs `finish` — which appended unconditionally, so the same reply could
  land twice. **Fix:** `JesseThread.lastDeliveredJobId` is an idempotency key.
  `finish` takes the `jobId` and, once the thread is resolved and **before**
  appending, returns early if `target.lastDeliveredJobId == jobId` — retrying only
  the persist (so a previously-failed save can now succeed) and clearing the run,
  never a second turn. A new delivery sets the key together with the append. On
  relaunch nothing is persisted, so the key is absent and Re-check/`resume`
  delivers exactly once. (`finish` also gained injected `speak`/`save` seams,
  mirroring the existing `makeClient`/`config` injection, so the tests can assert
  what was spoken and force a save failure deterministically.) The net invariant:
  a completing turn is always exactly one of {reply shown — on screen or spoken,
  recoverable error + Re-check}, with no duplicated turns and no silently-dropped
  voice reply. See the five `testVoiceOnlySpokenReply…`/`…SaveFailure…`/
  `…IdempotentDelivery…` cases in `RunCoordinatorFinishTests`.

## Live streaming (SSE)

A turn's reply streams to the phone token-by-token instead of arriving all at
once. This is **additive** — the 202 / poll / persist / resume path above is
unchanged and remains the authoritative completion path whenever a stream can't
be held (phone suspended, connection blip, an older client).

> **Client contract: streaming is display-only; the poll owns completion.** The
> app (`RunCoordinator.consume`) runs the SSE stream and the `GET /jesse/result`
> poll **concurrently from the start** — polling is *not* a fallback that waits
> for the stream to end. The stream only drives the live `partialText`/`activity`
> under the spinner; whichever source produces a terminal outcome first finishes
> the turn (exactly once), and the other is cancelled. This exists because of a
> real hang: a half-open stream (opened, then never a frame and never a close —
> phone suspended, NAT/idle timeout, a wedged proxy) never *ends*, so the old
> "stream, then fall back to poll once the stream finishes" logic blocked forever
> and the reply never landed. So: a stalled, erroring, or never-opening stream
> must never delay or block the reply — the poll resolves it regardless.

### How `claude` is run

The bridge runs the turn as:

```
claude -p <prompt> --output-format stream-json --verbose --include-partial-messages …
```

Verified facts about that output (run it yourself to confirm — it's `claude`'s
format, not ours):

- `--verbose` is **required**: `claude` errors with *"When using --print,
  --output-format=stream-json requires --verbose"* otherwise.
- Output is **NDJSON** — one JSON object per line. The bridge reads stdout **line
  by line** (`BufReader::lines`) as tokens arrive, rather than buffering the whole
  run with `wait_with_output()`.
- The lines the bridge cares about (everything else is ignored — `system`/init,
  `rate_limit_event`, message-envelope events, thinking/signature deltas, tool
  input deltas):
  - **Text delta** (the visible answer, token-level under
    `--include-partial-messages`):
    `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}`
    Thinking streams as `thinking_delta`/`signature_delta` and is deliberately
    **excluded** — only `text_delta` inside a `text` block is the answer.
  - **Tool use** (drives the activity hint):
    `{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read",…}}}`
  - **Terminal result** (the one line that decides the turn):
    `{"type":"result","is_error":false,"result":"…","session_id":"…"}` —
    `is_error` / `api_error_status` carry transient (5xx/429/529 → retry) vs fatal
    failures. This feeds the **same** `Ok`/`Retryable`/`Fatal` classification the
    buffered path always used (`classify_result_value`), so retry/timeout/
    3-attempt behavior is preserved. The classified `result` text is the
    **authoritative** answer **when it's non-empty**; when it isn't, the bridge
    falls back to the streamed text rather than delivering nothing (see
    [Captured result schema](#captured-result-schema-and-the-empty-reply-fix)).

`parse_stream_line` maps one NDJSON line to an internal `StreamEvent`
(`TextDelta` / `ToolActivity` / `Done` / `Ignore`) and is pure, so it's unit-tested
against captured fixtures.

> **Completion is driven by the `result` line, not stdout EOF.** The read loop
> **stops the instant it parses the terminal `result` line** rather than reading
> stdout to EOF. The stream-json contract emits exactly one terminal `result`
> line and it is the last meaningful line, so "the last result line wins" still
> holds. This matters because stdout EOF only arrives once `claude` **and every
> grandchild that inherited its stdout fd** (the MCP servers it launches — QMD,
> Home Assistant, …) close the pipe; a single lingering subprocess would
> otherwise keep the read blocked until the per-attempt timeout, pinning the job
> as Running (and the phone's spinner unresolved) long after the answer already
> arrived. Reaping the child and draining stderr afterward are **bounded
> cleanup** (a few-second `REAP_TIMEOUT` plus an explicit `start_kill`), so a
> child or grandchild that won't exit can never delay or block delivery — the
> answer is already authoritative once the `result` line is parsed. The
> no-`result` fallback (clean EOF with accumulated streamed text) is unchanged:
> it's reached only when stdout ends without a `Done` ever appearing.

### Captured result schema and the empty-reply fix

The verified shapes below were **captured from real `claude --output-format
stream-json --verbose --include-partial-messages` runs in the vault** (2026-06-27,
`claude` 2.1.195). They are committed as fixtures under
[`tests/fixtures/stream/`](tests/fixtures/stream/) and replayed by the
`real_*`/`*_falls_back_*`/`*_stays_fatal` tests through the **real**
`parse_stream_line` + `resolve_stream_outcome` — the exact path
`run_claude_streaming` takes — so this can't silently regress.

A healthy terminal `result` line carries the full answer plus a session id:

```json
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,
 "result":"This vault is …","session_id":"0a61d246-…","stop_reason":"end_turn"}
```

**`--include-partial-messages` does NOT empty `result`.** Verified by running the
same prompt with and without the flag: both terminal lines carry the full answer
(693 vs 838 chars); the flag only *adds* the token-level `text_delta` events
(10 vs 0). So the flag is kept — it's what gives live tokens, at no cost to the
authoritative `result`. (Decision: keep the flag **and** the accumulated-text
fallback; do not drop the flag.)

The failing shapes — what produced the **empty / lost reply** the user saw:

| Shape | `result` line | Streamed text? | Old behavior | New behavior |
|---|---|---|---|---|
| Empty-result success | `subtype:"success", is_error:false, result:""` | yes | `Ok{result:""}` → **empty bubble** | `Ok` with the streamed text (keeps `session_id`) |
| No result line at all | *(absent — clean exit after streaming)* | yes | unconditional **`Fatal`** → answer discarded | `Ok` with the streamed text |
| Genuine failure | *(absent)* | no | `Fatal` over stderr | **unchanged** — `Fatal` over stderr (never a blank `Ok`) |
| Error envelope, e.g. `error_max_turns` | `is_error:true, result:null` | yes (mid-turn narration) | `Fatal` | **unchanged** — stays `Fatal`; narration is not the answer |

The `error_max_turns` row is a real capture (`{"subtype":"error_max_turns",
"is_error":true,"result":null}` after the model streamed *"I have CLAUDE.md already
in context… but let me read both files…"*). It is deliberately **left as a
failure**: an error envelope must surface, and mid-turn narration must not
masquerade as a finished answer. The fallback only rescues turns that *succeeded*
(or exited cleanly with no envelope) yet carried no authoritative `result` text.

**Root cause.** The streaming path treated the terminal `result` line's `result`
field as the *only* source of the answer: an empty-but-`success` `result` was
returned verbatim as `Ok{result:""}` (an empty reply bubble), and a *missing*
`result` line was turned into an unconditional `Fatal` — in both cases **discarding
the answer the bridge had already accumulated token-by-token from the stream**. The
visible reply existed the whole time, in `JobStore`'s `StreamHandle`; it was just
never consulted at the decision point.

**Fix.** `resolve_stream_outcome(terminal, streamed, stderr)` is the single place
that decides a streamed turn's outcome. It prefers the authoritative `result`, but
when that text is empty/missing it falls back to `jobs.stream_snapshot(job_id)` (the
accumulated stream text) before ever returning empty. `Retryable` (5xx/429/529) and
real error envelopes (`is_error:true`) are untouched — they still retry / surface.
The one genuinely empty case (no `result` line **and** no streamed text) is a
`Fatal` carrying the stderr cause, **never** a silent `Ok{result:""}`. Verified
end-to-end against a running bridge (stub `claude` emitting each shape), not just in
unit tests.

### `GET /jesse/stream/:job_id`

Server-Sent Events for one turn. Same bearer auth as `/jesse`. Open it with the
`job_id` from `POST /jesse`.

```bash
curl -N http://127.0.0.1:8765/jesse/stream/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
```

Frames are `event:`/`data:` pairs; each `data:` is a one-line JSON object:

| `event:` | `data:` | Meaning |
|---|---|---|
| `reset` | `{"text":"…"}` | **Replace** the shown text with this. Sent first (replay of text-so-far) and to re-sync after a lag. |
| `delta` | `{"text":"…"}` | **Append** this chunk. |
| `activity` | `{"name":"Read"}` | Coarse tool-use hint ("reading the vault…"). |
| `done` | `{"response":"…","session_id":"…"}` | Terminal: final authoritative text + session id. |
| `error` | `{"error":"…"}` | Terminal: the turn failed. |
| `cancelled` | `{}` | Terminal: the turn was cancelled (`POST /jesse/cancel`). Surfaced cleanly, not as an error. |

- On subscribe to a **running** job: the accumulated text-so-far is replayed as a
  `reset` (so a phone that opens the stream a beat late, or reconnects after a
  blip, doesn't lose the beginning), then live frames follow.
- If the job is **already terminal** when the stream opens, the matching terminal
  frame is emitted immediately and the stream closes — including replaying full
  text + `done` for a finished turn, and `cancelled` for a cancelled one.
- Unknown / expired id → **404**.

`GET /jesse/result/:job_id` is untouched and remains the **poll fallback**.

### Design (broadcast + accumulate)

Each running job gets an in-memory `StreamHandle` on the `JobStore` — a
`tokio::sync::broadcast` sender plus the **text accumulated so far** and the last
activity hint. It mirrors the per-job `aborts` map from the cancel work, with the
same lock discipline: the `streams`, `jobs`, and `aborts` mutexes are **never held
simultaneously**. The accumulated buffer is **in-memory only** (for replay to a
late/reconnecting subscriber) and is **never persisted** — only the terminal
result persists, via `complete`. The handle is created when the turn is
registered and removed on the terminal transition.

Terminal frames are **write-once**, mirroring the job state: whichever of the
turn task (`done`/`error`) and `cancel` (`cancelled`) reaches `stream_finish`
first wins; the other no-ops. So a turn finishing in the same instant it's
cancelled can't emit a `done` over a `cancelled` (or vice-versa) — the frame and
the stored result always agree.

The SSE response body is a small `Stream` over a `tokio::sync::mpsc` receiver fed
by a per-subscriber forwarder task (only `futures_core::Stream` is named — already
in the dependency graph via axum, so no new compiled code). If a subscriber lags
the broadcast backlog, the forwarder re-sends the full accumulated text as a
`reset` rather than dropping deltas, so correctness never depends on the channel
capacity.

### When does the phone stream vs. poll?

`POST /jesse` always returns `202 {job_id, status:"running"}` immediately (it
never holds the connection). The phone then **streams** (`GET
/jesse/stream/{job_id}`) to render the reply live **and polls** (`GET
/jesse/result/{job_id}`) concurrently for the authoritative completion. The
`reset` frame replays anything produced before the phone subscribed, so nothing
is lost even though streaming starts a beat after the turn does. There is no
inline-reply fast path: every turn — fast or slow — is fetched by id.

## Voice requests

The `/jesse` body accepts an optional `"voice": true` flag. When set, the prompt
asks Jesse to end its reply with a final `SPOKEN: <one or two sentences>` line in
plain prose. The iOS app reads that line aloud (on-device TTS) and displays the
full answer with the `SPOKEN:` line stripped. Omitted/`false` → no change.

```bash
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"What is on Today.md?","voice":true}'
# → response ends with a line beginning "SPOKEN: "
```

## Custom prompt wrappers

Every turn wraps your text in a built-in **Ask** or **Tell** instruction before
Jesse sees it (the `mode` selects which). Two additive, **stateless** affordances
let the app customize that wrapper without the bridge holding any per-user state:

**`GET /jesse/prompts`** — returns the current built-in wrappers (the exact const
strings `build_prompt` applies for a fresh turn, so the app's "default" matches
what the bridge would use) plus the two fixed safety floors. Same bearer auth as
`/jesse`.

```bash
curl -s http://127.0.0.1:8765/jesse/prompts \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "ask": "<default ask wrapper>", "tell": "<default tell wrapper>",
#     "ask_floor": "<fixed ask safety floor>", "tell_floor": "<fixed tell floor>" }
```

**`POST /jesse` with optional `"instructions"` and `"floor_override"` fields** —
when present and non-empty, `instructions` replaces the **active mode's editable
wrapper** for that one request, and `floor_override` replaces the wording of the
**always-prepended safety floor**; when either is absent or blank, the built-in
const is used exactly as before (so omitting both reproduces today's behavior
byte-for-byte). The bridge still appends its own voice/phone-format suffix
regardless of the overrides, so it always owns output formatting.

```bash
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"What is on Today.md?","instructions":"Answer in one line. Question: "}'
```

**The safety floor is always prepended.** Each mode has a floor (`ask_floor` /
`tell_floor`) that `build_prompt` **always prepends** to every turn — fresh and
followup, voice and non-voice, with or without overrides. The Ask floor carries
the standing CLAUDE.md invariant ("Ask" forbids *action* he didn't request, never
*writing* a durable fact); the Tell floor carries the universal record-facts
invariant. `floor_override` only changes the floor's **wording**; a blank/absent
value falls back to the built-in const, so there is no way to send a turn with no
floor at all. The wrapper override customizes only the framing **between** the
floor and the user's text.

The design is deliberately stateless: the bridge never stores a custom wrapper or
floor. The app persists the user's edits and sends `instructions`/`floor_override`
only when a slot is actually customized; an empty field always means "use the
bridge default" and the field is omitted. In the app the floor is **unlockable** —
locked by default, editable only behind an explicit "not recommended" gate — so no
one reweakens it by accident.

## Conversation titles (`POST /jesse/title`)

A lightweight, **stateless** endpoint the app calls to turn one conversation's
text into a **very short title** (roughly 3–6 words, ~40 chars). It is **not a
turn**: no job is created, nothing is persisted, no session, no live stream, no
push, and no eviction interaction — it touches none of the jobs/streams/aborts
state. It reuses the same `claude` invocation discipline as a turn (same
`build_claude_args` allow/deny tool posture, `kill_on_drop`, and terminal-result
classification) via a single bounded `run_claude_oneshot` call.

```bash
curl -s http://127.0.0.1:8765/jesse/title \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"<a bounded digest of the conversation to title>"}'
# → { "title": "Weekend Trip Planning" }
```

- **Auth / rate limit.** Same bearer auth as `/jesse` (constant-time compare;
  `401` without/with a wrong bearer) and the same per-service rate limiter (`429`
  on a burst). Same bind/allowlist posture as every other endpoint.
- **Input cap.** The body is `{ "text": String }` — the app sends a bounded
  digest. Input is capped at **`MAX_TITLE_INPUT_BYTES` (16 KiB)**; anything larger
  is rejected with **`413`** *before any `claude` spawn*, so a title request can
  never trigger a giant model call. A blank body is `400`.
- **One short call.** Runs `claude -p` **once** with a fixed instruction to return
  one very short title (no quotes, no trailing punctuation, no `Title:` prefix) —
  keeping a good opening as-is or otherwise rephrasing it — and bounds it with a
  **short timeout (`TITLE_TIMEOUT_SECS`, 20s)**, tighter than a normal turn since
  this is interactive UI latency. The model output is clamped to a single line of
  at most **`MAX_TITLE_CHARS` (60)** characters before it's returned.
- **Degrade, never error.** On timeout or any failure the endpoint returns a clean
  non-2xx (`504`/`502`). **The app must treat "no title" as normal** and fall back
  to its existing derived title — it is never surfaced to the user as an error, and
  a title failure is never fatal to the bridge.

Response: `{ "title": String }`.

## Push notifications (APNs) — optional, off by default

The bridge can send the phone an **APNs alert when a backgrounded turn finishes**,
so you can leave the app mid-turn and get pinged when Jesse is done (tap the
notification to reopen the thread and load the reply). This is **fully optional and
disabled by default**: with the `JESSE_APNS_*` env vars unset, the bridge behaves
exactly as before and the app degrades to its existing foreground re-attach (open
the app and the reply is there).

### How it works

- **The phone registers its device token** with `POST /jesse/device` (bearer auth)
  on first authorization, on token change, and on each foreground. The bridge
  stores **one** current token (single user), persisted to
  `<JESSE_STATE_DIR>/device.json` (0600) so it survives a restart. Registration
  works even when push is disabled — the bridge just won't send.
- **The phone flags a turn for push only when it actually needs one.** When the
  app backgrounds with a turn still in flight, it calls
  `POST /jesse/notify/{job_id}` — *"I'm leaving, ping me."* (We chose this — the
  "real signal" option (a) — over a `notify: bool` on `POST /jesse`, because it
  pushes **only** for turns the user actually backgrounded on, never for turns that
  finished in the foreground.)
- **At completion**, if push is configured *and* a device token is registered *and*
  the job was flagged *and* it ended `done`/`failed` (not `cancelled`), the bridge
  sends one alert push carrying the `job_id` so the tap routes to the right thread.
  If the turn finished *before* the phone managed to flag it, the notify endpoint
  fires the push immediately, so the signal is never lost to that race.
- **A push failure never affects the turn.** No token, an APNs 4xx/5xx, a bad key —
  all are logged and swallowed; the reply is already stored and retrievable by
  poll/stream/resume regardless.
- **A dead device token (APNs `410`) is cleared.** When APNs returns HTTP `410
  Gone` — its signal that the registered token is permanently dead — the bridge
  **clears the stored token** (and persists the cleared state to `device.json`) so
  it isn't retried on every future completion. The phone must re-register
  (which it already does on each foreground). Any other failure (a transient
  5xx, a transport error) leaves the token in place to retry. Without this, a
  stale token after an app reinstall would be re-pushed forever.

The APNs auth JWT (ES256, signed with your `.p8`) is cached and reused for ~50
minutes (Apple allows up to 60) rather than re-signed per push.

### Endpoints

```bash
# Register / update this phone's APNs device token (idempotent upsert).
curl -s -X POST http://127.0.0.1:8765/jesse/device \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"token":"<hex device token>"}'
# → { "ok": true }

# Ask to be pushed when an in-flight turn completes (the app fires this on
# background). Idempotent and best-effort; flagging an unknown/finished job is
# harmless (a finished one pushes immediately).
curl -s -X POST http://127.0.0.1:8765/jesse/notify/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → 204 No Content
```

Both use the same bearer auth as `/jesse`; a missing/short token is `401`.

### Enabling it (env vars)

Set all four required vars (and the binary picks up the rest). If they're only
*partially* set, push stays disabled and the bridge logs a one-line warning.

| Var | Required | Purpose |
|---|---|---|
| `JESSE_APNS_KEY_PATH` | yes | Path to your APNs auth key `.p8` (PKCS#8). Read once at startup; never logged or committed. |
| `JESSE_APNS_KEY_ID` | yes | The key's 10-char Key ID (from the Apple Developer portal). |
| `JESSE_APNS_TEAM_ID` | yes | Your 10-char Apple Developer Team ID (the JWT `iss`). |
| `JESSE_APNS_TOPIC` | yes | The app's bundle id, sent as `apns-topic` (e.g. `com.tag1.Jesse`, or your own). |
| `JESSE_APNS_ENV` | no | `sandbox` (default) or `production`. Selects `api.sandbox.push.apple.com` vs `api.push.apple.com`. |

> **Which environment?** An Xcode "Run to device" (development) build uses the
> **development** APS environment → **`sandbox`** (the default here). A TestFlight /
> App Store build uses **production** → set `JESSE_APNS_ENV=production`. The token's
> environment must match the build's `aps-environment` entitlement, or APNs returns
> `BadDeviceToken`.

```bash
export JESSE_APNS_KEY_PATH="$HOME/secrets/AuthKey_ABCDE12345.p8"
export JESSE_APNS_KEY_ID="ABCDE12345"
export JESSE_APNS_TEAM_ID="C6RPS3BGXX"
export JESSE_APNS_TOPIC="com.tag1.Jesse"   # your app's bundle id
# export JESSE_APNS_ENV=production          # only for a TestFlight/App Store build
cargo run --release
# logs: "APNs push enabled (host api.sandbox.push.apple.com, topic com.tag1.Jesse)"
```

### Apple-side setup (one-time)

1. In the **Apple Developer** portal → **Certificates, Identifiers & Profiles → Keys**,
   create a key with **Apple Push Notifications service (APNs)** enabled. Download the
   `.p8` (you can only download it once) and note its **Key ID**. Your **Team ID** is
   on the membership page.
2. Enable **Push Notifications** for your App ID (the app project already ships the
   `aps-environment` entitlement; Xcode's automatic signing turns the capability on).
3. Put the `.p8` somewhere the bridge can read (outside the repo) and point
   `JESSE_APNS_KEY_PATH` at it. Set the four vars above and restart the bridge.

> End-to-end delivery can't be exercised in CI or the simulator — it needs a real
> device and a real APNs round-trip. The unit tests cover JWT signing, the payload
> shape, the completion→push decision, and that a push failure can't disturb a
> stored result, all without contacting Apple.

## Prereqs

- Rust toolchain (`rustup`, stable).
- `claude` (Claude Code) on PATH and logged in.
- Tailscale up on the laptop and the phone, same tailnet.
- Laptop awake. Sleep kills the server — the main "outside the house" reliability
  gap to solve later (a `launchd` keep-alive + `caffeinate`, or an always-on box).

## Knobs (env vars)

| Var | Default | Purpose |
|---|---|---|
| `JESSE_TOKEN` | (required) | Bearer token the phone must send |
| `JESSE_VAULT` | `~/devel/tag1/jesse` | cwd for `claude -p` (loads CLAUDE.md) |
| `JESSE_BIND` | `127.0.0.1` | Interface to bind — set to tailnet IP. Loopback/tailnet (`100.64.0.0/10`) only unless `JESSE_ALLOW_PUBLIC_BIND=1` |
| `JESSE_ALLOW_PUBLIC_BIND` | (off) | Set `1`/`true` to allow a non-loopback/non-tailnet bind; otherwise such a bind is a startup error |
| `JESSE_ALLOWED_TOOLS` | (scoped default) | Comma-separated `--allowedTools` list for the agent (see [`../SECURITY.md`](../SECURITY.md)) |
| `JESSE_DISALLOWED_TOOLS` | `Bash,WebFetch` | Comma-separated `--disallowedTools` denylist (defense-in-depth) |
| `JESSE_MAX_CONCURRENCY` | `2` | Max concurrent turns; excess returns `429` |
| `JESSE_RATE_PER_MIN` | `30` | Accepted requests per rolling minute; bursts beyond it return `429` |
| `JESSE_ADVERTISE_HOST` | value of `JESSE_BIND` | Host written into the pairing QR — set to the MagicDNS `ts.net` name to advertise that instead of the bound IP |
| `JESSE_PORT` | `8765` | Port |
| `JESSE_TIMEOUT` | `3600` | Per-request run limit (seconds), clamped to `1..=7200`. `0` is treated as the 7200s ceiling, not unlimited. On overrun the turn returns `504` with an actionable message naming this var |
| `JESSE_JOB_TTL_SECS` | `86400` | How long a finished-but-**unfetched** reply stays retrievable (24h). The clock starts at first retrieval, not at completion |
| `JESSE_RETRIEVAL_GRACE_SECS` | `600` | How much longer a reply is kept **after** its first retrieval (a short re-poll window) instead of the full TTL |
| `JESSE_STATE_DIR` | `~/.jesse-bridge` | Where completed results are persisted (`<dir>/jobs`) and the device token (`<dir>/device.json`, 0600), so a restart doesn't lose a reply or the token. Empty disables persistence |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary |
| `JESSE_APNS_KEY_PATH` | _(off)_ | Path to the APNs auth key `.p8`. Set (with the three below) to enable push; unset → push disabled, behavior unchanged. See [Push notifications](#push-notifications-apns--optional-off-by-default) |
| `JESSE_APNS_KEY_ID` | _(off)_ | APNs Key ID (10 chars) |
| `JESSE_APNS_TEAM_ID` | _(off)_ | Apple Developer Team ID (10 chars; the JWT `iss`) |
| `JESSE_APNS_TOPIC` | _(off)_ | App bundle id, sent as `apns-topic` (e.g. `com.tag1.Jesse`) |
| `JESSE_APNS_ENV` | `sandbox` | APNs host: `sandbox` (development builds) or `production` (TestFlight/App Store) |

The server refuses to start if `JESSE_TOKEN` is unset, the vault isn't a
directory, the `claude` binary can't be found, or `JESSE_BIND` is an unsafe
address without the override.

## Versioning

The **bridge** and the **app** are versioned **independently**:

- Bridge: `version` in `bridge/Cargo.toml` (SemVer). Surfaced at runtime — the
  startup banner (`Jesse Bridge v0.1.1 → …`) and `GET /health` (`"version"`,
  returned unconditionally, before the auth-gated fields).
- App: `MARKETING_VERSION (CURRENT_PROJECT_VERSION)` in the Xcode
  `project.pbxproj` (e.g. `1.0 (2)`). Shown in **Settings → Version**, next to the
  bridge version the app reads from `/health`.

**Every commit that touches a component bumps that component's version and adds a
`CHANGELOG.md` entry.** Pick the bump by change type: **patch** for a fix,
**minor** for a backward-compatible feature, **major** for a breaking change
(bridge); for the app, bump `CURRENT_PROJECT_VERSION` (build) every release and
`MARKETING_VERSION` for a user-facing version change.

This is **enforced**, not a convention:

- **Pre-push hook (the real gate).** `scripts/hooks/pre-push` runs
  `scripts/version-guard.sh` against the commits being pushed and **blocks the
  push** if a component changed without a version bump + CHANGELOG entry, printing
  exactly what to bump. Install it once per clone:

  ```bash
  scripts/install-hooks.sh   # sets core.hooksPath to scripts/hooks
  ```

  It depends only on git and the in-repo script — nothing outside the repo.

- **CI re-checks.** `scripts/ci-guards.sh` (run by the bridge CI job) calls the
  same `version-guard.sh`, so an un-bumped change can't merge even if the hook was
  never installed. The guard skips cleanly when there's no parent commit (initial
  commit / shallow checkout). The diff base is overridable via
  `VERSION_GUARD_BASE` (default `HEAD~1`).

## Hardening past the PoC

- Put it behind `tailscale serve` for real TLS + a stable hostname.
- Add `--resume`/`--session-id` plumbing if you want richer thread control.
- ~~Stream with `--output-format stream-json` for live token output.~~ Done — see
  [Live streaming (SSE)](#live-streaming-sse).

## Connector caveat

Headless Claude Code does **not** inherit Cowork's OAuth connectors (Gmail,
Calendar, Slack, Notion, Drive). Local MCP servers (QMD, Home Assistant, etc.)
and the filesystem **do** work. PoC scope = vault Q&A + capture, which is fine.
To use the cloud connectors here, register them in this project's `.mcp.json`.

## CHANGELOG

- **Concurrency & robustness hardening (job store, turn task, push).** A set of
  fixes so a slow disk, a wedged child, a panic, a poisoned lock, or a dead push
  token can't take the bridge down or strand a turn:
  - **Persistence is off the `jobs` lock.** `complete`/`cancel`/`get_retrieving`
    no longer `fsync` while holding the jobs mutex (which serialized every
    request behind one slow disk). They mutate in memory under the lock and
    enqueue the serialized snapshot to a dedicated persistence **worker thread**
    that does the blocking I/O off-lock, in order. (H2)
  - **Eviction moved off the request path** to a periodic background task, and
    its file unlinks run off-lock on the same worker (collected under the lock,
    unlinked after). No request waits on a sweep. (H3)
  - **A wedged child can't pin a turn.** The post-read `child.wait()` and stderr
    drain are bounded by `REAP_TIMEOUT`, so a `claude` that EOFs stdout but won't
    exit (a grandchild holding the pipe) frees its concurrency permit promptly on
    the already-authoritative `result` line. (H4)
  - **A panic in the turn body lands the job `Failed`** with a terminal stream
    frame, via a `TurnGuard` drop-guard — never a permanent `Running` with an
    unresolved spinner. The `.expect()`s on the child pipes became mapped errors.
    (M2)
  - **Lock poisoning is recovered, not propagated.** A `lock_ok` helper recovers
    a poisoned mutex's guard (the guarded maps are structurally valid), so one
    panicked turn can't cascade into a bridge-wide outage. (M3)
  - **The result body is capped in BYTES on a char boundary** (matching the byte
    cap the stream accumulator already used), not in characters — which for
    multibyte text could keep up to ~4× the intended 4 MB. (M1)
  - **A dead APNs token (`410`) is cleared** so it isn't retried forever. (M4)

- **Deliver the `job_id` immediately; never hold `POST /jesse`.** *Root cause:* the
  bridge held the POST connection up to a `JESSE_GRACE_SECS` grace window (default
  10s) so a fast turn could answer inline with a `200`. That delivered the
  `job_id` **too late** — if the socket dropped during the hold (phone suspended,
  NAT/idle timeout), the turn was already running on its detached task but the
  phone never received an id, so it could never poll the reply: an **orphaned
  turn** whose answer was produced and then lost. *Fix:* `POST /jesse` now returns
  `202 {job_id, status:"running"}` the instant the turn is spawned and never holds
  the connection. The phone persists the id up front, so any later drop is
  recoverable via poll/stream/resume; the unrecoverable window shrinks from a
  multi-second hold to a single request/response round-trip. `JESSE_GRACE_SECS`
  and the inline-`200` code path were **removed** (not hard-defaulted to 0). The
  `/jesse/result` and `/jesse/stream` contracts are unchanged.

- **App-side SSE parser fix (uncovered by the new integration tests).** The iOS
  client's stream parser used blank SSE lines as frame boundaries, but
  `URLSession.AsyncBytes.lines` *swallows blank lines* — so live deltas never
  rendered and the parser produced one garbled event at EOF. The parser now also
  dispatches a frame at each new `event:` line. This only affected the live,
  display-only token stream; the poll path (which owns completion) always
  delivered the reply, so no answer was ever lost to it.

## Note

`_removed-python/` holds the original Python prototype, kept only because this
sandbox can't delete files on the mounted volume. Delete it when you relocate the
project — it is not part of the build.
