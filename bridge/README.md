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

On startup the bridge prints a **pairing QR** plus a manual-entry fallback. The
plaintext token line is **hidden by default** so the raw token stays out of
scrollback and launchd logs:

```
█▀▀▀▀▀█  …  █▀▀▀▀▀█
…  (terminal QR)  …
Pair by scanning the QR above, or enter manually:
  host=100.64.0.1  port=8765
  (token hidden — it's encoded in the QR above; pass --show-token or set JESSE_SHOW_TOKEN=1 to also print it)
```

Open the app's **Settings → Scan to pair**, scan that QR, and host/port/token
fill in automatically — no more typing the token by hand on every restart. The
QR encodes `jesse://pair?host=…&port=…&token=…`, so scanning pairs without the
plaintext line. To also print `token=<token>` for manual entry, start the bridge
with `--show-token` or `JESSE_SHOW_TOKEN=1` (that output then contains the token).

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

## Diet snapshot (`GET /jesse/diet`)

**`GET /jesse/diet`** — reads the vault's generated diet data files and returns one
normalized JSON snapshot for the app's **Health** tab. Same bearer auth as
`/jesse`. The vault agent regenerates these files (`diet-today.js` on every
food/exercise/weigh-in log; the rest each morning and on weigh-ins) — the bridge
only reads them; it never writes here.

```bash
curl -s http://127.0.0.1:8765/jesse/diet \
  -H "Authorization: Bearer $JESSE_TOKEN"
```

Files read, all under `$JESSE_VAULT`:

| Path | Section | Required? |
|---|---|---|
| `todo-list/diet-today.js` | `today` | **required** (its absence is the only 503) |
| `todo-list/diet-progress.js` | `progress` | expected |
| `todo-list/diet-coach-notes.js` | `coach` | expected |
| `todo-list/proposed-diet-today.js` | `proposed` | optional (frequently absent) |
| `diet-logs/weight-log.csv` | `weightSeries` | expected |

The three `.js` files (and the optional one) are **data-only JS literals** — zero
or more leading `//` comment lines, then one `window.<NAME> = <object-or-array>;`
statement. They are JS, not strict JSON: unquoted keys, single/double quotes,
trailing commas, and embedded HTML/entities inside strings (coach notes carry
`<strong>` and `&mdash;`). The bridge strips the comment lines and the
`window.X =` / `;` wrapper and parses the literal with the `json5` crate — no
hand-rolled JS parser and no quote-rewriting. `weight-log.csv` is RFC 4180 (header
`Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes`, with quoted
commas in the Notes field) and is parsed with the `csv` crate, never `split(',')`.

**Per-section isolation** (a mirror of the browser dashboard's per-section
try/catch): a file that is missing or fails to parse becomes `null` and appends a
short human-readable string to the `errors` array — it does **not** fail the
endpoint. The endpoint returns:

- **`200`** whenever `diet-today.js` parsed (other sections independently `null`).
- **`503`** (with a JSON error body) only when `diet-today.js` itself is
  missing/unparseable — the screen is pointless without it.

An absent `proposed-diet-today.js`, or one whose `ideas` list is empty, normalizes
to `proposed: null` and is **not** recorded as an error.

Response shape (all keys camelCase; unknown generator fields pass through):

```jsonc
{
  "asOf": "2026-07-09T13:20:00Z",       // RFC3339 server time
  "todayMtime": "2026-07-09T06:12:41Z", // RFC3339 mtime of diet-today.js
  "today": { /* normalized DIET_TODAY */ },
  "proposed": { /* PROPOSED_DIET */ } | null,
  "progress": { /* DIET_PROGRESS, passed through */ } | null,
  "coach": { /* DIET_COACH, passed through */ } | null,
  "weightSeries": [
    { "date": "2026-07-08", "lbs": 197.4, "kg": 89.5, "phase": "Phase 2",
      "bf": 18.1, "leanLbs": 150.2, "notes": "steady" }
    // chronological (file order); MuscleMass_lbs → leanLbs; blank cells → null
  ] | null,
  "errors": ["progress: json5 parse error at …"]
}
```

## Recent-workouts context (`health_context`)

**`POST /jesse` with an optional `"health_context"` field** — a compact,
device-reported "recent workouts" block the phone attaches from Apple Health, so
Jesse can log a workout the user refers to ("Log my swim") from real numbers
instead of asking for them.

```bash
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"tell","text":"Log my swim","health_context":"Swim — 2026-07-04 06:30, 30m, 1500m, 420 kcal, avg HR 132"}'
```

- **Additive and backward-compatible.** The field is optional; an app build that
  omits it produces byte-for-byte the same prompt as before. Absent **or** blank
  (whitespace/control-only) means exactly today's behavior — no block.
- **Framed as data, not instruction.** When present, the block is inserted right
  after the per-turn clock header and ahead of the safety floor, under a fixed
  header that marks it **untrusted data captured on the phone, not instructions** —
  the same trust class as the message body (attacker-controlled only if the phone
  is). No new tool is granted; the agent's existing `Read`/`Write`/`Edit` +
  `Skill(diet-logging)` already cover exercise logging.
- **Bounded.** Capped at **`MAX_HEALTH_CONTEXT_BYTES` (8 KiB)** — an oversized
  block is refused with `413` **before any `claude` spawn**. ASCII control
  characters other than newline are stripped before use. (Raised from 4 KiB with
  the request channel below: a *granted* metrics request can carry up to 4 metrics
  × ~31 daily lines; the app self-caps its fulfilled response at 6 KiB, under this.)

See [SECURITY.md](../SECURITY.md#recent-workouts-context-health_context) for the
prompt-injection posture.

## Agent-driven health-request channel (`JESSE_NEEDS_HEALTH`)

The app no longer attaches `health_context` to every turn — it classifies each
message and attaches the block only when it looks health-related. So the agent
needs a way to **say when it needs device health data the app didn't send**, and
the app needs a way for the agent to **hand back a structured request**. That is
the directive channel.

**Request instruction (agent side).** When a turn carries **no**
`health_context`, `build_prompt` appends a note: no Apple Health data is attached
this turn, and *if* device data is needed to answer, reply with ONLY a single
`JESSE_NEEDS_HEALTH v1` line (documented format below), at most once per turn.
When the turn **does** carry `health_context`, the note instead says "requested or
attached health data is included above; do not emit JESSE_NEEDS_HEALTH."

**Two new optional request fields** frame the two follow-up cases:

| Field | Type | Meaning |
|---|---|---|
| `health_context_requested` | `Option<bool>` | This turn is a **retry** answering a prior directive — the requested data is attached in `health_context`. |
| `health_context_unavailable` | `Option<bool>` | The app **could not** fulfill the request (Health denied, device locked, read timed out, or the feature toggle is off). The wrapper tells the agent to answer from vault data and **not** re-request, so the channel can't loop. |

**Directive contract (generic, version 1).** A directive is the **final non-empty
line** of a reply, exactly one line:

```
JESSE_<NAME> v<N> {json}
```

This release defines `JESSE_NEEDS_HEALTH v1`; a planned dietary write-back adds
`JESSE_MEAL_LOG v1` on the same extractor. The needs-health payload:

```
JESSE_NEEDS_HEALTH v1 {"sections":["daily","workouts"],"metrics":[{"metric":"restingHeartRate","window_days":14}]}
```

- `sections` (subset of `daily`, `workouts`) and `metrics` are each optional, but
  **at least one** must be present.
- each `metric` is on a fixed whitelist (`restingHeartRate`, `heartRate`,
  `heartRateVariabilitySDNN`, `stepCount`, `activeEnergyBurned`, `bodyMass`,
  `sleepAnalysis`, `vo2Max`, `workouts`), with an integer `window_days` of 1–31;
  the metrics array is capped at 4.
- the directive line is capped at 2 KiB.

**Extraction (bridge side).** On the terminal-result path (poll result and SSE
`done` frame, kept consistent), when the final non-empty line matches a **known**
directive and its payload validates, the bridge **strips the line** from the reply
text and attaches the parsed value under a structured `directives` object on the
result: `{ "needs_health": { ... } }`. The `directives` field is surfaced on both
`GET /jesse/result` and the SSE `done` frame, and persisted with the job. A line
that is malformed, over the line cap, or names an **unknown directive name /
version** passes through **untouched and visible** (a loud contract failure,
logged) with no field — a wrong classification only ever costs a slower answer,
never a wrong one. The recognizer is a small **registry**, so new directive types
are a table entry, not new plumbing.

```bash
curl -s http://127.0.0.1:8765/jesse/result/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "status":"done", "response":"…(sentinel line stripped)…", "session_id":"…",
#     "directives": { "needs_health": { "sections":["daily"],
#                     "metrics":[{"metric":"restingHeartRate","window_days":14}] } } }
```

See [SECURITY.md](../SECURITY.md#agent-directive-channel-jesse_needs_health) for
the trust analysis.

### Structured provenance (model-badge v2)

Alongside the text [model badge](#env) (see `JESSE_MODEL_BADGE`), a delivered reply
carries a machine-readable **`provenance`** object on the **same terminal-result path**
as `directives` — surfaced identically on `GET /jesse/result` and the SSE `done` frame,
and persisted with the job — so a client can render native UI instead of string-parsing
the badge out of the reply text:

```bash
# → { "status":"done", "response":"…answer, badge stripped by the client…", "session_id":"…",
#     "provenance": { "route":"emergency-local", "model":"local-oss",
#                     "badge":"[local · emergency · local-oss]",
#                     "flags":{ "hosted_verify":false, "verify_queued":false,
#                               "citations_unverified":true } } }
```

- `route` — `hosted` | `vaultqa-local` | `diet-local` | `emergency-local` (the same route
  vocabulary as the metrics line).
- `model` — the backend model that produced the reply (`null` on a bare `[hosted]`).
- `badge` — the exact badge string, **byte-identical** to what is appended to `response`,
  so a client strips it by matching this string.
- `flags` — `hosted_verify`, `verify_queued`, and `citations_unverified` — exactly what the
  badge (and, for the last, the prepended `⚠️ citations unverified` warning) encode.

It is built at the **same finalization seam** as the badge and is present **exactly when**
the badge is appended: `null` when `JESSE_MODEL_BADGE` is off, on an empty directive-only
reply, and on every error/cancel — so an older client that ignores it still reads the same
trailing badge in the text (the fallback). The **metrics line and `vaultqa-audit` schema
are unaffected.** The exact strings are pinned by a shared fixture
(`bridge/tests/fixtures/provenance.json`) that both the bridge and the iOS app tests read.

## Dietary write-back channel (`JESSE_MEAL_LOG`)

The **write-direction sibling** of `JESSE_NEEDS_HEALTH`, on the **same extractor
and registry**. When the agent logs a meal into the vault, it ends the reply with
one machine-readable line the app turns into an Apple Health food entry:

```
JESSE_MEAL_LOG v1 {"meals":[{"id":"2026-07-04-lunch","consumedAt":"2026-07-04T12:30:00+02:00","name":"Lunch: spaghetti, red sauce","kcal":385,"protein_g":13,"carbs_g":77,"fat_g":4.5}]}
```

**Payload contract (version 1).**

- `meals` is a **non-empty** array, capped at **10** meals (a reply may log
  several); over the cap the whole block is malformed.
- each meal requires a non-empty `id`, `consumedAt`, and `name`:
  - `id` is the stable per-meal idempotency key (date + meal slot) — the app
    dedupes on it, so a re-poll or re-opened thread never double-writes.
  - `consumedAt` is ISO 8601 **with offset**, the *meal* time (not the log time).
    The bridge checks only presence; the app parses the offset strictly before
    writing (the bridge has no date library — defense in depth, not the authority).
- `kcal`, `protein_g`, `carbs_g`, `fat_g` are numbers, each **optional**:
  **omitted when unknown, never null-padded** — an absent macro is an absent key
  (an explicit `null`, a non-number, a negative, or a non-finite value is a
  rejection).
- the meal-log line is capped at **8 KiB** (its own per-directive cap; the generic
  ceiling is the same 8 KiB, sized to this, the largest directive — `JESSE_NEEDS_HEALTH`
  keeps its tighter 2 KiB cap).

**Extraction (bridge side).** Identical seam to `JESSE_NEEDS_HEALTH`: on the
terminal-result path (poll result and SSE `done` frame, kept consistent), a
**known**, validating meal line is **stripped** from the reply text and its parsed
value attached under `directives.meal_log`. A line that is malformed, over the 8
KiB or 10-meal cap, or names an **unknown version** (`v2…`) passes through
**untouched and visible** (logged) with no field — a future contract bump fails
loudly, never half-parsed. Streaming caveat by design: a partial SSE delta may
briefly show the line before the `done` frame strips it (the app hides it
defensively); no mid-stream suppression is attempted.

```bash
curl -s http://127.0.0.1:8765/jesse/result/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "status":"done", "response":"…(meal line stripped)…", "session_id":"…",
#     "directives": { "meal_log": { "meals":[{ "id":"2026-07-04-lunch",
#                     "consumedAt":"2026-07-04T12:30:00+02:00",
#                     "name":"Lunch: spaghetti, red sauce",
#                     "kcal":385,"protein_g":13,"carbs_g":77,"fat_g":4.5 }] } } }
```

See [SECURITY.md](../SECURITY.md#dietary-write-back-channel-jesse_meal_log) for
the trust analysis.

## Conversation titles (`POST /jesse/title`)

A lightweight endpoint the app calls to turn one conversation's text into a
**very short title** (roughly 3–6 words, ~40 chars). It is **not a turn**: no job
is created, no session, no live stream, no push, and no eviction interaction — it
touches none of the jobs/streams/aborts state. It reuses the same `claude`
invocation discipline as a turn (same `build_claude_args` allow/deny tool posture,
`kill_on_drop`, and terminal-result classification) via a single bounded
`run_claude_oneshot` call.

```bash
curl -s http://127.0.0.1:8765/jesse/title \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"<a bounded digest of the conversation to title>"}'
# → { "title": "Weekend Trip Planning" }

# Optionally persist the minted title under a session so GET /jesse/sessions can
# show it (see the title store below):
curl -s http://127.0.0.1:8765/jesse/title \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"<digest>","session_id":"<claude session id>"}'
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
- **Optional server-side title store.** The body accepts an optional
  `"session_id"`. When present **and** the title call succeeds, the minted title is
  persisted server-side under that session_id **before** the response, so
  `GET /jesse/sessions` can show it. **Omitting `session_id` reproduces today's
  stateless behavior exactly** — nothing is stored (old clients keep working
  unchanged). The store is a single JSON file `<state_dir>/titles.json` (0600,
  atomic temp+rename, best-effort — a write failure is logged, never fatal),
  following the device-token store's discipline; with no state dir configured it is
  **in-memory only** (titles lost on restart, the same degradation the job store
  has). The stored title is trimmed and clamped to `MAX_TITLE_CHARS` (60) at the
  store boundary. It survives a restart (write → reload on startup).

Response: `{ "title": String }` (unchanged whether or not `session_id` is sent).

## Session list (`GET /jesse/sessions`)

Lists the vault's Claude Code **sessions** (threads), newest first, so the app can
show a history of conversations. Threads are Claude Code sessions: each session's
transcript is a `<session_id>.jsonl` file under
`~/.claude/projects/<escaped-vault-path>/`. This endpoint enumerates those files
for the bridge's vault. **Read-only** — it never writes a session file.

```bash
curl -s http://127.0.0.1:8765/jesse/sessions \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "sessions": [
#      { "session_id": "0a61d246-…", "last_modified": 1752500000,
#        "first_message": "What is on Today.md?", "title": "Today Overview" },
#      …newest first…
#    ] }
```

- **Auth / rate limit.** Same bearer auth (`401` without/with a wrong bearer) and
  the same per-service rate limiter (`429` on a burst) as `/jesse`.
- **Fields.** `session_id` is the jsonl filename stem. `last_modified` is the
  file's mtime in unix seconds (the sort key, newest first). `first_message` is the
  text of the session's **first user turn**, truncated to **120 chars** on a char
  boundary — read from only a bounded 64 KiB prefix of the file; a session whose
  first user turn isn't found within that prefix gets `first_message: null` (never
  an error). `title` comes from the [title store](#conversation-titles-post-jessetitle),
  or `null` if none was ever minted for that session.
- **Projects-dir derivation (verified).** The `<escaped-vault-path>` is
  `cfg.vault` with **every non-alphanumeric character replaced by `-`** (so `/`,
  `.`, and `_` all become `-`; an existing `-` is kept; runs are not collapsed).
  e.g. `/Users/you/devel/tag1/jesse` → `-Users-you-devel-tag1-jesse`. This was
  verified against `claude 2.1.208` by creating a session in a controlled cwd and
  matching the created directory name; it is a **pure, unit-tested** function
  (`escape_project_path`) pinned against that convention.
- **`?since=<unix seconds>`.** Returns only sessions with mtime **strictly
  greater** than the value — a cheap delta poll (usually small and often empty in
  steady state).
- **ETag / `304`.** The response carries a **strong ETag** (a quoted SHA-256 over
  the exact response body). Send it back as `If-None-Match` and an unchanged list
  returns **`304 Not Modified`** with an empty body. `*` also matches.
- **Robustness.** A missing projects directory returns an **empty list**, not an
  error (the bridge may run before any session exists). Unparseable jsonl lines are
  skipped; non-`.jsonl` files and subdirectories are ignored; a filename that isn't
  a plain component is skipped defensively (a listing can never reach outside the
  projects dir).

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
| `JESSE_DISALLOWED_TOOLS` | `WebFetch` | Comma-separated `--disallowedTools` denylist. **Only `WebFetch`** — bare `Bash` is deliberately not here: denying it removes the whole Bash tool class and kills every scoped `Bash(...)` grant; unscoped Bash is still blocked by default-deny. See [`../SECURITY.md`](../SECURITY.md#agent-tool-allowlist-in-process-boundary) |
| `JESSE_MAX_CONCURRENCY` | `1` | Max concurrent turns — a **single global write lock** by default, so at most one turn runs (and can rewrite vault files) at a time regardless of how many clients are connected. A turn that can't get a permit immediately is **queued** (see `JESSE_MAX_QUEUED`), not rejected |
| `JESSE_MAX_QUEUED` | `4` | Depth of the wait queue in front of the concurrency limit. When no permit is free, up to this many turns **wait** for one (returning `202` immediately and streaming a "queued behind another turn" activity line while they wait); beyond the queue, load is shed with `429`. `0` disables the queue (an unavailable permit sheds `429` immediately — the pre-queue behavior) |
| `JESSE_RATE_PER_MIN` | `30` | Accepted requests per rolling minute; bursts beyond it return `429` |
| `JESSE_ADVERTISE_HOST` | value of `JESSE_BIND` | Host written into the pairing QR — set to the MagicDNS `ts.net` name to advertise that instead of the bound IP |
| `JESSE_PORT` | `8765` | Port |
| `JESSE_TIMEOUT` | `3600` | Per-request run limit (seconds), clamped to `1..=7200`. `0` is treated as the 7200s ceiling, not unlimited. On overrun the turn returns `504` with an actionable message naming this var |
| `JESSE_JOB_TTL_SECS` | `86400` | How long a finished-but-**unfetched** reply stays retrievable (24h). The clock starts at first retrieval, not at completion |
| `JESSE_RETRIEVAL_GRACE_SECS` | `600` | How much longer a reply is kept **after** its first retrieval (a short re-poll window) instead of the full TTL |
| `JESSE_STATE_DIR` | `~/.jesse-bridge` | Where completed results are persisted (`<dir>/jobs`) and the device token (`<dir>/device.json`, 0600), so a restart doesn't lose a reply or the token. Empty disables persistence |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary |
| `JESSE_TITLE_BASE_URL` | _(off)_ | Title-only backend override (with the two below). When **all three** are set, the `POST /jesse/title` one-shot child — and ONLY that child — is spawned with `ANTHROPIC_BASE_URL` set to this, so titles can be served by a cheap/fast/local backend while main turns keep the ambient credentials. All-or-nothing and soft: unset (default) → titles use the ambient backend, byte-for-byte prior behavior |
| `JESSE_TITLE_AUTH_TOKEN` | _(off)_ | Title child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_TITLE_*` |
| `JESSE_TITLE_MODEL` | _(off)_ | Title child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_TITLE_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset; **main-turn children are never affected** under any configuration. Each title call logs one provenance line (base URL + model, never the token) |
| `JESSE_DIET_BASE_URL` | _(off)_ | Diet-extract backend override (with the two below). When **all three** are set, a diet-shaped "Tell" runs the **local diet-logging pipeline**: a **hard-contained** extract child — pointed only at this backend via `apply_diet_env` — parses the utterance into per-item entries; a **hosted, ambient** verify child (never this backend) checks them; trusted Rust appends the verified rows to `diet-logs/*.csv`, runs the pinned node scripts, commits, and derives the `JESSE_MEAL_LOG v1` mirror. Both children are contained deny-by-default at the CLI root — `--tools ""` disables the entire built-in toolset and `--strict-mcp-config` + an empty `--mcp-config` load no MCP servers, so the child cannot read, write, run a shell, reach the network, spawn a subagent, or load an MCP tool (an empty `--allowedTools` alone does **not** achieve this — it means "add nothing to the default set", which was live-proven insufficient on `claude 2.1.207`; see [`../SECURITY.md`](../SECURITY.md#diet-child-tool-isolation-in-process-boundary)). All-or-nothing and soft: **the seam is the kill switch** — unset (default) → the gate never fires and every turn takes the hosted path byte-for-byte |
| `JESSE_DIET_AUTH_TOKEN` | _(off)_ | Extract child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_DIET_*` |
| `JESSE_DIET_MODEL` | _(off)_ | Extract child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_DIET_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset. Each diet turn logs one provenance line (`diet turn -> <local\|hosted-fallback rung=N> …`, base URL + model, never the token, no meal content); the verify child and every main turn stay on the ambient backend |
| `JESSE_DIET_PROBATION` | `true` | Probation mode — the hosted verify gate is mandatory and blocking on every extracted entry. Only an explicit falsey value (`0`/`false`/`no`/`off`) disables it; the disabled (graduation) state is reserved and not used yet |
| `JESSE_VAULTQA_BASE_URL` | _(off)_ | Vault-QA backend override (with the two below). When **all three** are set, a **self-referential "Ask"** that passes the [strict vault-QA gate](#local-vault-qa-route-jesse_vaultqa_) runs a **contained, read-only** local child — pointed only at this backend via `apply_vaultqa_env` — that answers the question from vault files (`Read`/`Grep`/`Glob`, plus the qmd MCP search when configured) with a citation for every load-bearing fact. A pure in-process **citation validator** checks the answer (≥1 citation, every cited file resolves, every quoted claim occurs in its file) before it is delivered; on any failure rung (spawn/API error, timeout, `NO_VAULT_ANSWER`, empty, validator fail) the turn **falls through** to the hosted path unchanged. Containment is the toolset: the read-only root allowlist + `--strict-mcp-config` mean the child can read the vault but cannot write, execute, or reach the network (cwd **is** the vault — the one divergence from the diet child, [see `../SECURITY.md`](../SECURITY.md#vault-qa-child-tool-isolation-in-process-boundary)). All-or-nothing and soft: **the seam is the kill switch** — unset (default) → the gate never fires and every Ask takes the hosted path byte-for-byte |
| `JESSE_VAULTQA_AUTH_TOKEN` | _(off)_ | Vault-QA child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_VAULTQA_*` |
| `JESSE_VAULTQA_MODEL` | _(off)_ | Vault-QA child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_VAULTQA_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset. Each gated turn logs one provenance line (`vaultqa turn -> <local\|hosted-fallback rung=N> …`, base URL + model, never the token, never the question); every main turn stays on the ambient backend. **Known tradeoff:** a locally-answered turn never enters the hosted session history (no `--resume` write), so a later hosted follow-up won't know it happened — the strict gate keeps conversational follow-ups hosted for exactly this reason |
| `JESSE_VAULTQA_MCP_CONFIG` | _(off)_ | Optional path to an MCP config JSON declaring exactly the **qmd** vault-search server, layered onto the vault-QA child via `--mcp-config`. Unset → the child loads **no** MCP servers and answers on the three read-only built-ins alone (qmd simply absent, never an error) |
| `JESSE_MODEL_BADGE` | `on` | Whether the bridge appends a one-line provenance **badge** to each delivered `POST /jesse/jesse` reply, naming the backend that produced it: `[local · vault · <model>]`, `[local · diet · <model> + hosted verify]`, `[local · emergency · <model>]`, `[local · diet · <model> + verify queued]`, or `[hosted · <model>]` / `[hosted]`. Display-only, derived from the bridge's own turn state (never model output), and **never** applied to the title endpoint or written into session state. Only an explicit falsey value (`0`/`false`/`no`/`off`) turns it off, reproducing the prior exact reply text. A machine-readable **`provenance`** object (route + model + this exact badge string + the flags it encodes) rides the poll result and SSE `done` frame alongside the text badge whenever the badge is present — see [Structured provenance](#structured-provenance-model-badge-v2) |
| `JESSE_METRICS_LOG` | _(off)_ | Absolute path to a structured-metrics **JSONL** file. When set, the bridge appends **one content-free JSON line per gated / routed / emergency turn** at the reply-finalization point (ISO-8601 timestamp, turn id, mode, route [`hosted`/`vaultqa-local`/`diet-local`/`emergency-local`], backend model, ladder rung, wall ms, TTFT/tool-calls where recoverable, citation count + validator verdict, badge string, emergency flag, hosted-failure class). **Never** the question, answer, or tokens — content joins happen in the `vaultqa-audit` tool via the serving logs. All-or-nothing and soft: **unset (default) → zero metrics writes**, and a write failure logs to stderr and never disturbs the reply. Append-only, line-buffered, restart-safe |
| `JESSE_EMERGENCY_LOCAL` | `off` | Arms the **emergency local fallback** (`on`/`off`). Inert unless it is **on** AND the `JESSE_VAULTQA_*` triple is also set (that supplies the backend + read-only child). When armed, a hosted turn that fails **transport-class** (spawn / network / timeout / CLI-surfaced 5xx / 429 / quota / auth — never a completed turn) is served locally instead of surfacing the outage: an **Ask** runs the read-only vault-QA child (regardless of the routine gate, citation validator advisory, badge `[local · emergency · <model>]`); a **diet Tell** whose blocking hosted verify is unreachable has its extracted entry **queued** by the bridge for later verify (badge `[local · diet · <model> + verify queued]`), replayed oldest-first on the next successful hosted contact through the exact verify-then-append path — **nothing reaches the CSVs unverified**. A circuit breaker goes local-first after 2 consecutive transport failures for 300 s. Default **off**; only an explicit `on`/`1`/`true`/`yes` arms it. **Untested-live until go-live's outage drill.** See [`../SECURITY.md`](../SECURITY.md#emergency-local-fallback-posture) |
| `JESSE_APNS_KEY_PATH` | _(off)_ | Path to the APNs auth key `.p8`. Set (with the three below) to enable push; unset → push disabled, behavior unchanged. See [Push notifications](#push-notifications-apns--optional-off-by-default) |
| `JESSE_APNS_KEY_ID` | _(off)_ | APNs Key ID (10 chars) |
| `JESSE_APNS_TEAM_ID` | _(off)_ | Apple Developer Team ID (10 chars; the JWT `iss`) |
| `JESSE_APNS_TOPIC` | _(off)_ | App bundle id, sent as `apns-topic` (e.g. `com.tag1.Jesse`) |
| `JESSE_APNS_ENV` | `sandbox` | APNs host: `sandbox` (development builds) or `production` (TestFlight/App Store) |

The server refuses to start if `JESSE_TOKEN` is unset, the vault isn't a
directory, the `claude` binary can't be found, or `JESSE_BIND` is an unsafe
address without the override.

### Diet pipeline probation

`JESSE_DIET_PROBATION` defaults to `true` and **stays on** through go-live. In
probation the hosted verify gate is mandatory and blocking on every extracted
entry, and the daily diet audit
(`com.example.jesse-diet-audit` → `~/Library/Logs/jesse-diet-audit/YYYY-MM-DD.txt`)
records every `diet turn ->` provenance line, the local/hosted-fallback split by
rung, the verify verdicts, any rollback events, and a re-derivation drift check of
the day's dashboard totals against `diet-logs/food-log.csv`.

**Probation may be lifted only when ALL of these hold** — this is a **human
decision made against the accumulated audit history, never automated**:

- **≥ 14 consecutive days** of the pipeline running in production, **and**
- **≥ 30 local-path entries** actually logged over that window, **and**
- **zero rung-4 failures** — no append/hook (`generate` / `validate` /
  `verify-diet-consistency`) failure that forced a rollback, **and**
- **zero structural corrections that had to fall through** — no turn where a
  verify `correct`/`reject` verdict could not be applied safely and the entry
  dropped to the hosted path, **and**
- a **rung-2/3 fallback rate under 5%** (extract failures / `no_loggable_content`
  / verify-unavailable / verify-rejected, as a fraction of gated diet turns), **and**
- the **daily audits have been reviewed** across the whole window, not merely
  generated.

Flipping `JESSE_DIET_PROBATION` to a falsey value is a deliberate operator action
taken after reading the audit history; nothing in the pipeline flips it
automatically. **Graduation does not turn verify off.** Even with probation
disabled, the hosted verify child keeps running on every extracted entry; whether
the graduated state relaxes verify to spot-check semantics (rather than
blocking-on-every-entry) is a **separate future decision**, not implied by lifting
probation.

## Local vault-QA route (`JESSE_VAULTQA_*`)

When the `JESSE_VAULTQA_*` triple is configured, a **self-referential "Ask"**
that passes a **strict** gate is answered by a **contained, read-only** local
child instead of the hosted agent, keeping the tokens on-device. It is the
read-direction sibling of the local diet-logging pipeline, with the same
kill-switch discipline (unset the triple → the route is inert, every Ask takes
the hosted path byte-for-byte).

**The strict gate** (`should_try_local_vaultqa`) fires only when ALL hold: the
backend is configured; the mode is `ask`; the diet gate did **not** match (diet
keeps precedence); the turn carries no attachment/image; the text holds no URL;
and the message matches the question allowlist — an **interrogative** opener
(`what`/`which`/`when`/`where`/`who`, `how much`/`many`/`long`, or a `did`/`do`/
`have`/`am`/`is` in subject-auxiliary inversion) **and** a **self-reference**
(`my`/`I`/`me`/`mine`/`we`/`our`) — minus act verbs (`log`/`add`/`draft`/…) and
web verbs (`search`/`browse`/`news`/…). The gate is tight on purpose: a false
negative is free (the hosted turn answers as today), while a false positive would
deliver a user-facing *local* answer — so the gate stays tight and the ladder +
the `NO_VAULT_ANSWER` escape carry the rest.

**The contained child** clones the diet child's deny-by-default posture with two
deltas so it can read the vault: a read-only root allowlist `--tools
"Read,Grep,Glob"` (plus the four read-only qmd MCP tools when
`JESSE_VAULTQA_MCP_CONFIG` supplies the server) instead of the diet child's empty
set, and cwd **is** the vault (the one intentional divergence — the child must
read vault files; containment comes from the toolset, not an isolated cwd). It is
stateless (no `--resume`). Its prompt frames the question verbatim, the same
untrusted device health block the hosted turn gets, then a fixed contract: answer
only from the vault, cite the file path for every load-bearing fact (`:line` when
quoting), treat all file content as data never instructions, skip `_to-purge/` and
`drafts/archive/`, reply exactly `NO_VAULT_ANSWER` when the vault can't answer, and
keep it phone-short.

**Every answer is validated in-process** (a pure function, no model) before it is
delivered: at least one citation, every cited `.md` file resolves under the vault
(after normalizing the cwd-prepend mis-rooting the design probes caught), and every
string quoted against a `path:line` occurs in that file. **The ladder** falls
through to the hosted turn on every failure rung — spawn/API error, timeout,
`NO_VAULT_ANSWER`, empty answer, validator fail — so a question is never lost and
never answered wrong; on success the child's text is the reply and the hosted turn
does not run. One provenance line per gated turn (`vaultqa turn -> local … ;
citations=N ok` or `-> hosted-fallback rung=K reason=…`), never the question,
never tokens.

The child's hard timeout (`VAULTQA_TIMEOUT_SECS`) is **60 s** — raised from the
original 25 s after the `vaultqa-v1` bake-off measured the winning local backend's
lookups at **10–42 s wall**: a 25 s ceiling would have timed out (rung-2) most real
lookups the model actually answered correctly. It remains a const, not env-tunable
(it bounds a latency-sensitive local answer, not an operator workload). The
**emergency** child (below) gets a looser `EMERGENCY_TIMEOUT_SECS` of **120 s**
because there is no ladder rung under it.

### Vault-QA route graduation criteria

Like the diet pipeline (above), the vault-QA route runs on **probation** and
graduates only on operational evidence — a **human decision made against the audit
history, never automated**. It may graduate no earlier than **14 consecutive days**
AND at least **20 routed (gated) turns**, and only with ALL of:

- **zero invented citations** — the in-process citation validator never let a
  fabricated or mis-resolved citation reach the user;
- **zero injection leaks** — no vault-file instruction ever caused the child to act
  (the read-only toolset makes this structural, but it is audited);
- a **faithfulness-loss rate ≤ 5%** — local answers judged against a position-swapped
  hosted re-answer;
- a **fallback rate ≤ 25%** — a higher rate means the gate/child pair isn't earning
  its keep and the route should stay hosted.

Graduation itself, the daily audit installer (`com.example.jesse-vaultqa-audit`, on
the diet audit pattern), and probation operation are owned by the go-live process,
not this code.

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

## Code review (git checkouts under `Code/`)

The agent can review source from a phone request like *"review
https://github.com/owner/repo, focus on the auth path."* It clones/fetches the
repo, then reads/searches/diffs it.

- **Where checkouts land:** `Code/<host>/<owner>/<repo>`, derived purely from the
  clone URL — lowercase the host, strip a trailing `.git`, treat
  `git@host:owner/repo` like `https://host/owner/repo`, drop any port. e.g.
  `https://github.com/tag1consulting/jesse-app` →
  `Code/github.com/tag1consulting/jesse-app`;
  `git@gitlab.com:group/sub/repo.git` → `Code/gitlab.com/group/sub/repo`. A
  `Code/README.md` index tracks repo → local path → remote URL.
- **`Code/` is gitignored** in the vault, so checkouts never enter the vault repo
  or its 15-minute autocommit.
- **No new tool grant was needed.** `Bash(git:*)` already covers
  clone/fetch/log/diff/show; `Read`/`Grep`/`Glob` reach the checkout because it is
  under the vault cwd (no `--add-dir`). The only bridge change that *enabled* this
  was dropping bare `Bash` from the denylist (it had been disabling the whole Bash
  tool class — see the knob above and `SECURITY.md`).
- **Review-only.** The agent may clone/fetch and read; it must **never `git push`
  and never edit checked-out code**. This is a standing instruction the bridge
  prepends to every turn (`prompt::REVIEW_CAPABILITY`), not a sandbox — see
  [`../SECURITY.md`](../SECURITY.md#code-review-checkouts-review-only).
- **Access & TOFU.** Uses the host's existing credentials, so private
  access-configured repos work. A first headless clone from a brand-new SSH host
  can fail the unknown-host prompt — pre-seed `known_hosts` or use the HTTPS URL
  (GitHub and epyc are already trusted).

## CHANGELOG

- **Agent-driven directive channel + classify-then-attach health context (bridge
  0.3.0).** Health context is no longer attached to every turn — the app
  classifies each message and attaches the block only when relevant, and the agent
  can now **ask** for device health data it wasn't given. Two halves:
  - **Generic directive extraction.** The final non-empty line of a reply may be a
    directive `JESSE_<NAME> v<N> {json}`. A small registry recognizes known
    directives (this release: `JESSE_NEEDS_HEALTH v1`); a recognized, validating
    directive is **stripped** from the reply and its parsed value attached under a
    structured `directives` object, surfaced identically on the poll result and the
    SSE `done` frame and persisted with the job. Malformed / over-cap (2 KiB line)
    / unknown-name / unknown-version lines pass through **visible** with no field
    (loud contract failure). See "Agent-driven health-request channel" above and
    `SECURITY.md`.
  - **Request instruction + new fields.** When a turn carries no `health_context`,
    the wrapper tells the agent how to emit a `JESSE_NEEDS_HEALTH` request; when it
    does, it says not to. New optional request fields `health_context_requested`
    (a retry answering a prior directive) and `health_context_unavailable` (the app
    couldn't fulfill it — answer from vault, don't re-request) frame the follow-up
    turns. `MAX_HEALTH_CONTEXT_BYTES` rose **4 KiB → 8 KiB** to fit a granted
    metrics request. All additive and backward-compatible.

- **Optional `health_context` on `POST /jesse` (bridge 0.2.0).** A turn may carry
  a compact device-reported "recent workouts" block (from the phone's Apple
  Health) so the agent can log a referenced workout from real numbers. Framed as
  **untrusted device DATA, not instruction**, inserted after the clock header and
  ahead of the safety floor; capped at `MAX_HEALTH_CONTEXT_BYTES` (4 KiB) with an
  oversized block refused `413` before any spawn, and ASCII control chars (except
  newline) stripped. Optional and backward-compatible — omitting it reproduces
  today's prompt byte-for-byte. No new agent tool is granted. See the
  "Recent-workouts context" section above and `SECURITY.md`.

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
