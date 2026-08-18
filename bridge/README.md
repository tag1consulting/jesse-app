# Jesse Bridge (Rust)

Turns "Ask Jesse" / "Tell Jesse" requests from the phone into headless Claude
Code runs against the vault. **Cowork is not scriptable; Claude Code is**, and it
loads the same `CLAUDE.md`, so you get the same Jesse.

Axum + Tokio. Compiles to a single static binary — drop it on the laptop and run.

## Run

```bash
cd bridge

export JESSE_TOKEN="$(openssl rand -hex 24)"   # save this for the phone
export JESSE_VAULT="$HOME/vault"

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

Because the QR encodes the **full bearer token**, it is printed **only when
stdout is a terminal**. When stdout is a pipe — a container, a service manager,
`| tee` — stdout is the log stream, and the QR would republish the token into
whatever log aggregation is attached on every restart. Headless runs therefore
get only the manual-entry lines on stdout (token still hidden), plus a one-line
note on **stderr** saying the QR was suppressed and how to get it back:

```
Pair from the app's Settings by entering these manually:
  host=100.64.0.1  port=8765
  (token hidden — it is the value of JESSE_TOKEN)
```

To force the QR onto a non-TTY stdout that a human is actually reading, start
the bridge with `--show-qr` or `JESSE_SHOW_QR=1` (that output then encodes the
token). The reverse also exists: `JESSE_SHOW_QR=0` **pins the QR off even on a
terminal** — for the deployments where a PTY and a log stream are the same fd
(`docker run -t`, a pod spec's `tty: true`, a `script(1)`/`unbuffer` wrapper),
where "stdout is a terminal" does not mean "nobody is recording it". An
explicit `0` beats both the TTY check and `--show-qr`, and also silences the
stderr note.

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
| `conversations` | the conversation registry: the record, the session -> conversation reverse index, the in-flight claim table, and the one-time title/flag/deletion key migration |
| `sessions` | the conversation list, hydration, delete and flags handlers, plus the projects-dir scan, the transcript-turn parser, and the GC sweep |
| `state` / `handlers` / `sse` | shared `AppState`, the Axum handlers + router, and the SSE body/forwarder |
| `startup` | pairing-QR payload + the `binary_exists`/bind startup checks |
| `schedule` | the `[[schedule]]` config: parse, validate (per-entry disable vs. startup error), and DST-correct next-fire / catch-up resolution. Pure — no clock of its own |
| `schedstate` | the scheduler's persisted per-job record (`<state-dir>/schedule.json`): last due/fire/completion, outcome, reason, duration, job id |
| `scheduler` | the tick task, chain execution under the one-scheduled-turn-at-a-time lock, single flight, the push, and `GET /jesse/schedule` |
| `containment` | the containment RECORD: the `(capability, MCP set)` rows, the verdict/scoring rules, and the committed file's TOML shape (`bridge/containment.toml`). Always compiled — the startup gate reads it |
| `probe` | the LIVE battery behind it: the adversarial probes, their ground-truth checks, the scratch worlds and the runner. Behind the `containment-probe` feature, so none of it is compiled into the serving binary; run by the `containment-probe` bin |

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

A **thread is a conversation**, and a conversation is a first-class bridge record
with a stable UUID. Send `conversation_id` on every turn, first and follow-up
alike; the 202 echoes back the authoritative id. See
[Conversations](#conversations-the-thread-identity) for the model and
[the conversation list](#conversation-list-get-jesseconversations) for the API.

Each response also returns a `session_id`: the Claude Code session backing the
conversation right now. A conversation owns an **ordered list** of those, so a CLI
session fork does not split the thread. Passing `session_id` back still works (it
is what a pre-0.33 client does), but `conversation_id` is what identifies the
thread: when both are present the conversation's current session wins.

Resuming keeps `CLAUDE.md` loaded and retains filesystem access — it only adds the
prior turns on top. Omitting `conversation_id` entirely makes the bridge mint one,
so an older client keeps working unchanged.

## Conversations, the thread identity

Before 0.33 the bridge had **no concept of a conversation**. The list was a
`read_dir` over the CLI's transcript files and a thread's identity was the filename
stem of a jsonl the CLI created on its own schedule. That produced duplicates:

- `POST /jesse` returned no thread identifier at all, so a client learned its
  `session_id` only from the terminal reply, minutes later. Meanwhile the CLI had
  already written the transcript, so `GET /jesse/sessions` was advertising a session
  id the client could not possibly know yet, and a sync landing in that window
  adopted it as a **second** thread.
- A CLI session fork on `--resume`, or a dropped `--resume` after a GC sweep, minted
  a **new** transcript, which the scan turned into yet another row.

A conversation fixes both. It is **registered at accept time, before the 202 is
returned**, and it owns the ordered list of session ids bound to it.

```json
{
  "conversation_id": "0f8c2b1e-9a4d-4c77-b2e1-6d5a0c3f9b84",
  "session_ids": ["0a61d246-…", "7c9e1f02-…"],
  "created_ms": 1753430000123,
  "registered_ms": 1753430000123,
  "origin": "phone"
}
```

Persisted to `<state_dir>/conversations.json` as
`{"v":1,"migrated":true,"conversations":{ "<conversation_id>": { … } }}` with the
same discipline as every other store (atomic temp + rename, `sync_all`, mode 0600,
best-effort). With no state dir the registry is in-memory only, so every transcript
is re-adopted on restart. Only ids and timestamps are ever written.

- **`session_ids` is the alias list**, oldest first; the last element is what a
  resume targets. A fork appends, so the conversation is still one row.
- **`origin`** (`phone` / `mac` / `watch` / `cli`) is advisory. Nothing branches on it.

**The client mints the UUID; the bridge registers it.** A bridge-minted id would
reopen the exact race being closed: there would be a window in which the server
knows an identifier the client does not. With a client-minted, bridge-registered id
there is never such a window. The bridge still returns the **authoritative** id in
the 202 and remains free to override the requested one, and registration is
idempotent by construction: re-POSTing the same conversation registers nothing new.

**Adopting a legacy transcript.** A transcript on disk with no record is adopted
into a conversation whose id is the **deterministic UUIDv5** of its session id
(namespace `f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31`). Determinism is the point:
adoption is idempotent, and a state dir lost and rebuilt from the transcripts alone
reproduces exactly the ids clients already hold. A `POST /jesse/title` one-shot
transcript is never adopted: it is not a conversation.

**A turn's transcript is not adopted while the turn is running.** The CLI writes
`<session_id>.jsonl` at spawn, not at completion (verified against
`claude 2.1.220`: the file appears within a second of spawn on a multi-second
turn). A conversation-list refresh issued mid-turn would therefore find an unbound
stem and adopt it separately, the very duplicate this design removes, and the
reply binding arrives too late to help. So every running turn records the set of
stems that existed just before it spawned, and the refresh **skips** any stem
absent from every live snapshot: such a stem is by construction attributable to a
turn still in flight. It produces no record and no list row that round. On
termination the turn binds the reply's session id and then diffs the stems, which
also rescues a turn that **failed** before returning any session id. The claim is
released by a drop guard, so a panic or a cancel cannot wedge adoption.

**Titles, flags, and tombstones are keyed on the conversation id**, not the session
id (a session id is no longer stable). An existing state dir is re-keyed once at
startup through the reverse index: a key that resolves moves onto its conversation,
a key that resolves to nothing is dropped for titles and flags, and for deletions is
additionally recorded under its deterministic v5 id so an in-flight tombstone is not
lost. The pass is guarded by a persisted flag, so it runs exactly once, and it
carries flag rows over unchanged so every last-writer-wins clock survives.

## Surviving a client disconnect (job store)

A turn runs on its own detached task that owns the `claude` child, so it is **no
longer tied to the HTTP connection**. If the phone suspends and the socket drops
mid-turn, the turn keeps running to completion instead of being killed — the
reply is never lost.

`POST /jesse` returns the `job_id` **immediately** — it never holds the
connection:

- Always → **`202 { "job_id": "...", "conversation_id": "...", "status": "running" }`**,
  the instant the turn is spawned. The turn then runs server-side and lands in the job
  store; the phone fetches the reply via `GET /jesse/result/{job_id}` (poll) and/or
  `GET /jesse/stream/{job_id}` (live tokens).

  `conversation_id` is the **authoritative** conversation this turn belongs to,
  registered *before* this response is built (see
  [Conversations](#conversations-the-thread-identity)). It is additive (a pre-0.33
  client decoding only `job_id` is unaffected) and it is also the **acceptance
  signal** a UI needs, since its arrival is the first moment a client can know the
  turn is durably the server's. A malformed `conversation_id` is rejected with
  `400 { "error": "…" }` before any work happens; only a canonical **lowercase
  hyphenated** UUID is accepted (uppercase, braced, and urn forms are not).

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
#   { "status": "done", "response": "...", "session_id": "...", "timing": {...} }
#   { "status": "failed", "error": "...", "partial": {...}|null, "timing": {...} }
#   { "status": "cancelled", "timing": {...} }
```

Same bearer auth as `/jesse`. An unknown or evicted id → **`404`**.

#### `partial` — a turn that was cut off, not a turn that failed

A turn killed at its run limit (`JESSE_TIMEOUT`) carries **`partial`** beside the
unchanged `error`, so the client can render *"the turn was cut off, here is how far it
got"* rather than a bare failure banner:

```json
{ "text": "I refactored the parser. …", "elapsed_secs": 5400, "tool_calls": 37,
  "truncated": true }
```

`text` is the retained tail of the visible answer — the last `JESSE_PARTIAL_BLOCKS`
blocks, capped at `JESSE_PARTIAL_BYTES`; `truncated` says whether anything was dropped.
`null` on every other failure: a turn that failed for a reason has a cause, not a cutoff.
The error string and its status are untouched, so failure classification (and therefore
retry behavior) is exactly what it was.

#### `timing` — where the turn's time went

Every turn writes one JSON line to `<state_dir>/turn-timings.jsonl` (pruned to 7 days at
startup) and serves it back here:

```json
{ "v": 1, "job_id": "…", "started_at": "2026-08-12T09:00:00Z",
  "ended_at": "2026-08-12T10:30:00Z", "elapsed_ms": 5400000, "status": "failed",
  "tool_calls": 37, "tools": [ { "tool": "Read", "ms": 812 }, … ] }
```

Content-free — tool names, counts and durations, never the question or the answer. This is
what makes the next slow turn diagnosable in one command:

```bash
jq 'select(.elapsed_ms > 600000)' ~/.jesse-bridge/turn-timings.jsonl
```

### Idempotency key — safely re-send a `POST /jesse` (`request_id`)

Because `POST /jesse` returns the `job_id` on the first response and the turn then runs
**detached**, a network drop *before* that response reaches the phone leaves the client
with no id to poll — and a blind retry would spawn a **second** turn (double the tokens,
a second vault write). The optional **`request_id`** field closes that window: re-send the
same request with the same key and the bridge returns the **original** job.

```bash
# First attempt — the 202 never made it back to the phone.
curl -s -X POST http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"When is my next race?","request_id":"2f9c1a-turn-0007"}'

# Retry with the SAME request_id — same job_id back, no second turn spawned.
curl -s -X POST http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"When is my next race?","request_id":"2f9c1a-turn-0007"}'
# → 202 { "job_id": "<same id as the first accept>",
#          "conversation_id": "<the same conversation>", "status": "running" }
```

- **Optional and additive.** `request_id` is a string, `≤ 64` chars, **ASCII
  alphanumerics and hyphens only**; anything else is a `400 { "error": "…" }`.
  **Omitting it reproduces the pre-idempotency behavior exactly** — every `POST` is a fresh
  turn (old app builds simply don't send it).
- **What "dedup" returns.** When the key is already mapped to a **live** job — queued,
  running, done, failed, or cancelled, as long as it's still inside its retention window —
  the bridge **creates nothing, takes no concurrency permit, and enqueues nothing**. It
  returns `202 { "job_id": "<existing>", "status": "running" }`, the *exact* shape of a
  fresh accept, so the client streams (`GET /jesse/stream/{job_id}`) or polls
  (`GET /jesse/result/{job_id}`) the returned id identically either way. A job that already
  finished satisfies the first poll immediately with its stored terminal state.
- **Reaped ⇒ new.** Once a job is evicted (see the eviction model below), its `request_id`
  mapping is gone, so the same key on a later `POST` is treated as brand new.
- **Concurrency-safe.** The `request_id → job_id` index is maintained under the job store's
  single `jobs` lock, with the check-and-insert done at job creation — so two duplicate
  `POST`s that arrive *at the same instant* can never both spawn; they collapse to one job.
- **Survives a restart.** The `request_id` is persisted with the completed job and the
  index is rebuilt from persisted jobs on startup, so a dedup still works across a bridge
  restart. Job files written before this field (which lack the key) load unchanged.
- **Auth and rate limiting are unchanged** and apply *before* any of this.

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
- the nine tracked nutrient fields — `kcal`, `protein_g`, `carbs_g`, `fat_g`,
  `fiber_g`, `sodium_mg`, `satfat_g`, `sugar_g`, `potassium_mg` — are numbers, each
  **optional**: **omitted when unknown, never null-padded** — an absent nutrient is
  an absent key (an explicit `null`, a non-number, a negative, or a non-finite value
  is a rejection). The set is **field-agnostic**: a future nutrient is an additive
  optional field, never a version bump.
- the meal-log line is capped at **8 KiB** (its own per-directive cap; the generic
  ceiling is the same 8 KiB, sized to this, the largest directive — `JESSE_NEEDS_HEALTH`
  keeps its tighter 2 KiB cap).

**Payload contract (version 2 — upsert + retract).** v2 keeps every v1 rule and adds
correction semantics so a change made *after* a meal was first logged propagates:

- `meals` entries are **upserts** keyed on `id`: unseen → insert (v1 behavior); same
  content → skip (idempotent replay); changed content → the app deletes the previously
  written Health entry and rewrites it.
- `retract` (optional, cap **10**) is an array of ids the source deleted — the app
  removes their Health entry and tombstones the id; retracting an unknown id is a no-op.
- a **meal move** is a retract of the old id plus an upsert of the **new** id (ids embed
  the meal time), so the **same id in both** `meals` and `retract` is malformed.
- at least one of `meals`/`retract` must be present; both v2 fields are omitted on the
  wire when empty, so a v1-shaped delivery is byte-for-byte unchanged.

```
JESSE_MEAL_LOG v2 {"meals":[{"id":"2026-07-04-snack-1630","consumedAt":"2026-07-04T16:30:00+02:00","name":"Snack"}],"retract":["2026-07-04-snack-1500"]}
```

**Extraction (bridge side).** Identical seam to `JESSE_NEEDS_HEALTH`: on the
terminal-result path (poll result and SSE `done` frame, kept consistent), a
**known** (v1 **or** v2), validating meal line is **stripped** from the reply text
and its parsed value attached under `directives.meal_log`. A line that is malformed,
over the 8 KiB / 10-meal / 10-retract cap, or names an **unknown version** (`v3` and
up) passes through **untouched and visible** (logged) with no field — a future
contract bump fails loudly, never half-parsed. Streaming caveat by design: a partial
SSE delta may briefly show the line before the `done` frame strips it (the app hides
it defensively); no mid-stream suppression is attempted.

```bash
curl -s http://127.0.0.1:8765/jesse/result/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "status":"done", "response":"…(meal line stripped)…", "session_id":"…",
#     "directives": { "meal_log": { "meals":[{ "id":"2026-07-04-lunch",
#                     "consumedAt":"2026-07-04T12:30:00+02:00",
#                     "name":"Lunch: spaghetti, red sauce",
#                     "kcal":385,"protein_g":13,"carbs_g":77,"fat_g":4.5 }] } } }
```

See [SECURITY.md](../SECURITY.md#dietary-write-back-channel-jesse_meal_log-v1-and-v2)
for the trust analysis.

### Off-app corrections queue (`POST /jesse/meal-corrections`)

Most logging — and **all** corrections — happen in non-app sessions (desktop/Cowork
logging on the Studio) with no app turn, so there is no reply to carry a
`JESSE_MEAL_LOG` block. This endpoint lets an external logging agent hand the bridge a
v2 batch to relay on the next app turn. It carries meal events **generally** — off-phone
inserts as much as corrections and retracts. The bridge only **persists and relays**; the
app is the sole writer.

```bash
# Enqueue an off-app correction (a sodium change on an already-logged soup).
curl -s -X POST http://127.0.0.1:8765/jesse/meal-corrections \
  -H "Authorization: Bearer $JESSE_TOKEN" -H 'content-type: application/json' \
  -d '{"meals":[{"id":"2026-07-04-soup","consumedAt":"2026-07-04T12:00:00+02:00","name":"Soup","sodium_mg":900}]}'
# → { "status":"queued", "corrections_seq": 1 }
```

- **Body = the v2 payload object** (`{"meals":[…],"retract":[…]}`), validated against the
  **exact same contract** as an in-reply `JESSE_MEAL_LOG v2` directive; a malformed body
  is a loud `400`, never a partial enqueue. Same bearer auth as every endpoint.
- **Persisted + bounded.** Batches land in `<state_dir>/meal-corrections-queue.jsonl` with
  a monotonic `seq` (survives restart and a fully-drained queue). Cap **100** — a post at
  the cap is rejected `429`; with no state dir configured it is `503` (persistence off).
- **At-least-once delivery, ack, prune.** On every terminal result the queued batches are
  merged into the delivered `meal_log` **ahead of** any block the turn's own reply
  produced (collapsed net per-id, last-op-wins, so the delivered payload never lists an id
  in both arrays), with the highest queued `seq` stamped as `corrections_seq`. The app
  echoes it back as `meal_corrections_ack` on a later `POST /jesse`; the bridge prunes
  batches at or below the ack. Unacked batches redeliver every turn — harmless because the
  app dedupes on `id` + content hash. Every enqueue, delivery, ack, and prune is logged.

## Conversation titles (`POST /jesse/title`)

A lightweight endpoint the app calls to turn one conversation's text into a
**very short title** (roughly 3–6 words, ~40 chars). It is **not a turn**: no job
is created, no session, no live stream, no push, and no eviction interaction — it
touches none of the jobs/streams/aborts state. It reuses the same `claude`
invocation discipline as a turn (`kill_on_drop`, terminal-result classification)
via a single bounded `run_claude_oneshot` call, but is granted
**`Capability::Basic` with no MCP servers**: no tools at all. Writing a short title
is a single-shot text transformation, so the child gets `--tools ""`, an empty
strict MCP config and an empty allowlist — the same containment the diet children
get. Until bridge 0.39.0 it shared the writes-on main-turn allowlist and launched
the qmd server, because it shared a builder with a real turn; see
[`../SECURITY.md`](../SECURITY.md#the-title-child).

```bash
curl -s http://127.0.0.1:8765/jesse/title \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"<a bounded digest of the conversation to title>"}'
# → { "title": "Weekend Trip Planning" }

# Optionally persist the minted title under a conversation so
# GET /jesse/conversations can show it (see the title store below):
curl -s http://127.0.0.1:8765/jesse/title \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"<digest>","conversation_id":"<conversation id>"}'
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
  `"conversation_id"`. When present **and** the title call succeeds, the minted title
  is persisted server-side under that conversation **before** the response, so
  `GET /jesse/conversations` can show it. A malformed id is a `400`. **Omitting it
  reproduces the stateless behavior exactly**: nothing is stored (old clients keep
  working unchanged). A legacy `"session_id"` is still accepted and resolved through the
  conversation reverse index, since the store is conversation-keyed; an id that resolves
  to no conversation stores nothing rather than writing a key no read path would look at. The store is a single JSON file `<state_dir>/titles.json` (0600,
  atomic temp+rename, best-effort — a write failure is logged, never fatal),
  following the device-token store's discipline; with no state dir configured it is
  **in-memory only** (titles lost on restart, the same degradation the job store
  has). The stored title is trimmed and clamped to `MAX_TITLE_CHARS` (60) at the
  store boundary. It survives a restart (write → reload on startup).

Response: `{ "title": String }` (unchanged whether or not `session_id` is sent).

## Conversation list (`GET /jesse/conversations`)

Lists the vault's **conversations**, newest first, so the app can show a history of
threads. This is the canonical list; it is rendered from the
[conversation registry](#conversations-the-thread-identity), not from a directory
scan, which is what stops a mid-turn sync or a CLI session fork from surfacing a
duplicate row. **Read-only**: it never writes a transcript.

```bash
curl -s http://127.0.0.1:8765/jesse/conversations \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "conversations": [
#      { "conversation_id": "0f8c2b1e-…",
#        "session_id": "7c9e1f02-…",
#        "session_ids": ["0a61d246-…", "7c9e1f02-…"],
#        "last_modified": 1752500000,
#        "first_message": "What is on Today.md?",
#        "title": "Today Overview",
#        "favorite": false, "favorite_updated_ms": 0,
#        "archived": false, "archived_updated_ms": 0,
#        "registered_ms": 1753430000123 },
#      …newest first…
#    ],
#    "deleted": [ { "conversation_id": "…", "deleted_ms": 1753430000123 } ] }
```

- **Auth / rate limit.** Same bearer auth (`401` without/with a wrong bearer) and
  the same per-service rate limiter (`429` on a burst) as `/jesse`.
- **`session_id`** is the conversation's **current** bound session, or `null` for a
  conversation registered but not yet run (including one whose first turn is still in
  flight). **`session_ids`** is the full ordered alias list, which a client needs to
  bind its pre-upgrade threads to a conversation exactly once.
- **`last_modified`** is the **maximum** mtime in unix seconds across every bound
  transcript that still exists, falling back to `registered_ms / 1000` when there is
  none yet. It is the sort key, newest first.
- **`first_message`** is the text of the **oldest** bound transcript's first user
  turn, so a fork never changes the derived title. Truncated to **120 chars** on a
  char boundary and read from only a bounded 64 KiB prefix; a transcript whose first
  user turn is not found within that prefix yields `first_message: null` (never an
  error).
- **`first_message` is the user's words, not the wrapper.** A bridge turn's first
  user line is the *wrapped* prompt (the per-turn clock line, any attached health
  context, and the Ask/Tell preamble around the message); an interactive session can
  lead with `<local-command-caveat>` / `<command-…>` CLI plumbing. The bridge strips
  what it added (the preamble and the always-appended capability note) and the caveat
  framing, so the snippet is the actual utterance. The same stripping is applied to
  every hydrated user turn, so history and the list agree.
- **`title`** comes from the [title store](#conversation-titles-post-jessetitle),
  keyed on the conversation id, or `null` if none was ever minted.
- **`favorite` / `archived`** and their `_updated_ms` clocks come from the flag
  store, keyed on the conversation id, defaulting to `false` / `0`. They are part of
  the serialized body, so flipping a flag changes the ETag and invalidates a cached
  `304` automatically.
- **`deleted`** carries recent [deletion tombstones](#delete-a-conversation-delete-jesseconversationconversation_id)
  so every device converges on removals the same way it converges on flags. It is
  **not** filtered by `?since=`. Every tombstone is reported whichever key space it
  was recorded under; a client only ever acts on an id it actually holds, so an id it
  does not recognize is inert.
- **`?since=<unix seconds>`.** Returns only conversations whose `last_modified` is
  **strictly greater** than the value: a cheap delta poll (usually small and often
  empty in steady state).
- **ETag / `304`.** The response carries a **strong ETag** (a quoted lowercase-hex
  SHA-256 over the exact response body). Send it back as `If-None-Match` and an
  unchanged list returns **`304 Not Modified`** with an empty body. `*` and a
  comma-separated list also match. Ordering is newest `last_modified` first with ties
  broken **ascending** on `conversation_id`, so the body (and the ETag) is stable
  across calls with unchanged inputs.
- **The registry is refreshed from disk first**, so a transcript left by a previous
  bridge or written by the CLI outside the app is adopted before the list is
  rendered. A stem attributable to a turn **still in flight** is deliberately
  skipped: it produces no record and no row that round. Title-mint transcripts are
  never adopted.
- **Projects-dir derivation (verified).** The `<escaped-vault-path>` is `cfg.vault`
  with **every non-alphanumeric character replaced by `-`** (so `/`, `.`, and `_` all
  become `-`; an existing `-` is kept; runs are not collapsed). e.g.
  `/Users/you/vault` → `-Users-you-vault`. This was verified against `claude 2.1.208`
  by creating a session in a controlled cwd and matching the created directory name;
  it is a **pure, unit-tested** function (`escape_project_path`) pinned against that
  convention.
- **Robustness.** A missing projects directory returns an **empty list**, not an
  error (the bridge may run before any conversation exists). Unparseable jsonl lines
  are skipped; non-`.jsonl` files and subdirectories are ignored; a filename that
  isn't a plain component is skipped defensively (a listing can never reach outside
  the projects dir).

## Hydrate a conversation (`GET /jesse/conversations/{conversation_id}/transcript`)

Returns a conversation's whole history as **ordered, client-renderable turns**,
across every transcript bound to it, so a client that never saw a thread's earlier
turns can render them. The turns are shaped exactly like a **live SSE turn**: user
utterances (wrapper-stripped, as in the list snippet) and the assistant's **visible
text** only: thinking, `tool_use`, and `tool_result` noise the phone would not
render are dropped, along with subagent (`isSidechain`) and CLI `isMeta` lines.

```bash
curl -s "http://127.0.0.1:8765/jesse/conversations/<conversation_id>/transcript" \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "conversation_id": "0f8c2b1e-…",
#     "turns": [
#       { "role": "user",      "text": "What is on Today.md?",
#         "timestamp": "2026-07-20T08:00:00.000Z", "turn_key": "0a61d246-…:0" },
#       { "role": "assistant", "text": "Two things: a call and a run.",
#         "timestamp": "…", "turn_key": "0a61d246-…:512" }
#     ],
#     "next_cursor": "1:4096" }
```

- **Auth / rate limit.** Same bearer auth (`401`) and the same per-service rate
  limiter (`429`) as the list.
- **`?after=<cursor>`, the delta sync.** A conversation can span several transcript
  files, so a bare byte offset is not a sufficient cursor. The cursor is an **opaque**
  `"<segment_index>:<byte_offset>"` string: the index into the conversation's
  `session_ids` plus the offset within that segment's file. Its internals are the
  bridge's business: a client only echoes back the `next_cursor` it last saw. Omit
  `after` (or send an empty value) for the whole history.
- **Reading across segments.** The starting segment is read from its offset to EOF,
  then each subsequent segment from offset 0, concatenated in segment order. Each
  segment keeps the append-only per-file behavior: the offset is an exact byte
  position at a **line boundary**, and a **partial trailing line** (the file caught
  mid-write) is left unconsumed so it is returned on the next call once the writer
  completes it. A cursor at or past the end yields no turns and echoes itself back.
- **A missing segment is skipped, not an error.** A transcript swept by GC or deleted
  while the conversation lived on is stepped over and the cursor advances past it. A
  conversation legitimately outlives one of its transcripts.
- **`turn_key`** is a stable, opaque per-turn key: `"<session_id>:<absolute byte
  offset of the jsonl line that produced this turn>"`. It is unique within the
  conversation and byte-identical across repeated hydrates, which is what lets a
  client merge history without duplicating a turn it already holds, including two
  genuinely identical messages, which a content hash would wrongly collapse.
- **`404`** for an unknown `conversation_id`.
- **`400`** for a malformed `conversation_id` (anything but a canonical lowercase
  UUID) or a malformed cursor. A bad cursor is deliberately an error rather than a
  silent reset to zero, which would replay the whole conversation and duplicate every
  turn on the client.
- **Never `500`s on a bad transcript.** Unparseable, non-UTF-8, or partial lines are
  skipped; a conversation with only tool traffic simply yields an empty `turns` array.

## Delete a conversation (`DELETE /jesse/conversation/{conversation_id}`)

Deletes one conversation for the bridge's vault: **every** transcript bound to it,
under `<home>/.claude/projects/<escaped-vault>/`, **scoped to the vault project
only**. The app calls this when the user swipe-deletes a thread, so the remote
transcripts are reclaimed too (not just the phone's local copy).

```bash
curl -s -X DELETE http://127.0.0.1:8765/jesse/conversation/<conversation_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → 204 No Content
```

- **Same bearer auth** as `/jesse` (`401` without/with a wrong bearer).
- **Idempotent**, exactly like `POST /jesse/cancel`: an **unknown conversation, or
  one whose files are already gone**, returns **`204`** (success), never an error:
  the app's durable delete-drainer retries a queued delete, and the GC sweep below
  must never choke. Only a real I/O failure deleting a file that *exists* is a `500`.
- **`400`** for a malformed id, **before** the filesystem is touched. The ids are
  canonical UUIDs, so a validated id is a safe path component by construction and can
  never delete outside the vault projects dir.
- **Title and flag cleanup.** The conversation's title and flag rows are dropped, so
  a deleted conversation can't resurrect a stale title or favorite.
- **A durable tombstone**, under the conversation id, so a device that adopted this
  conversation learns to drop it on its next sync.
- **A deleted conversation is no longer resumable**. See the resume-after-sweep note
  under the GC sweep below.

## Conversation flags (`POST /jesse/conversation/{conversation_id}/flags`)

Sets a conversation's **favorite / archived** flags, so the bridge (not one device)
is the source of truth and every device converges on one set of favorites and one set
of archived conversations.

```bash
curl -s -X POST http://127.0.0.1:8765/jesse/conversation/<conversation_id>/flags \
  -H "Authorization: Bearer $JESSE_TOKEN" -H 'content-type: application/json' \
  -d '{"favorite":true,"favorite_updated_ms":1753430000123}'
# → { "favorite": true, "favorite_updated_ms": 1753430000123,
#     "archived": false, "archived_updated_ms": 0 }
```

- **Same bearer auth and rate limiter** as the other routes.
- The body carries any subset of `{ favorite, favorite_updated_ms, archived,
  archived_updated_ms }`. Each provided flag is applied **last-writer-wins** by its
  client-supplied change timestamp (unix millis): a **strictly newer** timestamp wins,
  an equal or older write is ignored, so out-of-order writes from different devices
  converge deterministically. A partial body (one flag only) leaves the other
  untouched. The two flags are independent registers.
- **`404`** for an unknown conversation, **`400`** for a malformed id.
- Persisted to `<state_dir>/flags.json`, keyed on the conversation id.

## Artifact return channel (`GET /jesse/artifact/{id}`)

Files used to move in exactly one direction. A turn that rendered a chart, exported a
CSV or wrote a PDF either described the work in prose or lost it, because the reply is a
string. This is the other direction.

### The constraint that decides the shape

On **both** harnesses the only writable location is the turn's own working directory:

* **Claude Code** — `--add-dir` grants READS inside the named directory and confers no
  write. Measured against claude 2.1.223: with `Write(./**)` allowed and the directory
  added, a write *into* it was still refused and the file was never created.
* **Codex** — `sandbox_workspace_write.writable_roots` is exactly the turn's cwd, with
  `/tmp` and `$TMPDIR` excluded so a write cannot be laundered through a world-writable
  path.

So the staging directory is **inside the working directory** and the bridge moves files
out of it the moment the turn ends. No containment record moves for any of this: that
directory is already writable at `Capability::Write`, which is the only capability that
gets a staging directory at all.

### Per turn

On a turn whose capability is `Write` — and only then, and only when a state dir is
configured — the bridge creates `<working_dir>/.jesse-artifacts/<job_id>/` (mode 0700)
and appends one sentence to the prompt naming it. A `Read` or `Basic` turn gets neither:
it cannot write, so promising it an artifact channel would be a lie. A turn with no
staging directory has a **byte-for-byte unchanged** prompt.

`.jesse-artifacts/` carries a `.gitignore` whose entire content is `*`. The working
directory is a git repository committed by an automatic timer, so an artifact that landed
in that history would be there permanently and on a remote; a directory that ignores
itself needs no change to any file in the vault repo. Verified against the real vault:
`git status --porcelain` is byte-identical with a file staged, and `git check-ignore -v`
names the staging dir's own `.gitignore` as the matching rule. The property is held by a
test that builds a scratch repository and asserts the same thing.

### The sweep

When the turn ends — success, error, or run-limit timeout — the staging directory is
swept before the job reaches its terminal state. For each regular file, in name order:

1. **Type is sniffed from the bytes.** PNG, JPEG and PDF by signature; SVG, HTML and JSON
   by recognizable text shape (JSON is *parsed*, not guessed from a leading brace);
   plain text, CSV and Markdown as verified UTF-8 text with the extension picking only
   the display label among those three. Anything else is **rejected**, not guessed at —
   fail-closed on purpose, so a real new type fails loudly in testing and is added
   deliberately.
2. **Executables are refused** — Mach-O (all four magics plus both fat wrappers), ELF and
   `#!` scripts — and the execute bit is cleared on everything that survives (the file is
   created fresh at 0600 rather than moved with its staged permissions).
3. **The three per-turn caps are enforced.** The first file to breach one stops the
   sweep; everything already accepted is kept.
4. **The content is SHA-256'd**, and identical content produced twice is stored once and
   referenced twice.
5. **It is moved** to `<state_dir>/artifacts/<job_id>/<artifact_id>.<ext>`, where the id
   is fresh random hex (it reaches a URL, so it must be unguessable, and it is
   re-validated as hex on the way back in).

A symlink is never followed: `symlink_metadata` is what decides "regular file", so a
staged link pointing outside the staging directory is skipped rather than swept.

**Rejections are never silent.** A dropped or capped file appends a line to the reply the
user sees, the same way the PDF page cap already does. A dropped artifact the user is not
told about is a wrong answer they cannot detect.

The staging directory is removed by a `Drop` guard on **every** exit path including panic
and the task abort a cancel performs, so a failed turn never leaves files in the git
tree. A **cancelled** turn is the one case that discards what it staged rather than
sweeping it — the task is aborted before the sweep runs, which is what "stop" means.

### On the wire

`artifacts` rides as a third sidecar exactly where `directives` and `provenance` already
do: `JobState::Done`, `StreamFrame::Done`, the persisted job file, the SSE `done` event,
`GET /jesse/result/{job_id}`, and the conversation hydrate route. Each element carries
`id`, `filename`, `mime`, `bytes` and `sha256`.

**It never carries the bytes.** Inlining base64 would push binary content into the job
JSON, the persisted job file, the SSE frame and the conversation store all at once, which
is the failure this design exists to avoid. An empty list serializes as `null`, so a turn
that returns nothing is byte-for-byte the reply an older bridge sent.

On the hydrate route, artifacts are re-attached to the turn that produced them by the
**SHA-256 of the delivered assistant text** (trimmed, post-`delivered_text`, pre-badge).
Hydration reconstructs a turn from the harness's own transcript and has no job id to bind
on; what it does have is the invariant hydration already documents and the app already
depends on — *the assistant text hydration returns is the text delivery produced*. Two
character-identical replies in one conversation hash the same, so each artifact is
attached to the first match and consumed.

### Fetching the bytes

```
GET /jesse/artifact/{id}
Authorization: Bearer <token>
```

* **`400`** for an id that is not lowercase hex — the traversal guard. `..`, a slash and
  a NUL are all non-hex, so this one check keeps every request inside the artifacts
  directory.
* **`404`** with `{"reason": "unknown"}` or `{"reason": "expired"}`. The app renders those
  differently: one is a client bug, the other is a budget working as designed.
* **`304`** when `If-None-Match` matches the content hash.
* **`200`** with the recorded mime, an `ETag` carrying the hash, and
  `Content-Disposition: attachment` naming the display filename (RFC 6266, both forms,
  both stripped of anything that could forge a header). Always `attachment`, never
  `inline`, plus `X-Content-Type-Options: nosniff`: this route serves SVG and HTML, and
  neither should ever be treated as a page from the bridge's own origin.

### Disk

Three budgets that do not substitute for each other — per turn (`JESSE_MAX_ARTIFACTS*`),
per server (`JESSE_ARTIFACT_TTL_DAYS` + `JESSE_ARTIFACT_STORE_MAX_BYTES`), and per device
(the app's own LRU cache cap). Deleting a conversation **cascades** to its artifacts: one
that outlives the conversation it belonged to is unreachable and pure cost. The store
logs its file count and total bytes at startup and after every eviction, so the growth is
observable before it is a problem.

With **no state dir** there is no artifact store, and the channel degrades to off: no
staging directory, no prompt fragment, no metadata. That is the same degradation every
other store in the bridge already has.

## Session GC sweep (`JESSE_SESSION_TTL_DAYS`)

A background task reclaims **orphaned** vault-project sessions — one whose remote
delete never reached the bridge (a failed-network swipe-delete), and everything
deleted locally on the phone *before* the delete-on-thread-delete flow existed. It
runs **once at startup**, then every 6 hours, and deletes every vault-project
session jsonl whose **last-modified time is older than `JESSE_SESSION_TTL_DAYS`**
(default **90**).

- **Never reclaims an active thread.** Resuming a session touches its jsonl mtime,
  so a thread you're still using is always younger than the TTL and is never swept.
  The sweep reclaims exactly the orphans.
- **Never deletes anything younger than the TTL, and never steps outside the vault
  project.** It enumerates only plain `*.jsonl` files directly under
  `<home>/.claude/projects/<escaped-vault>/` (the same scoping as
  `GET /jesse/conversations`); subdirs, other files, and a non-plain stem are skipped.
- **Every reclaim is logged** with the session id and its age.
- **Conversation records are swept too.** After the transcript sweep, a conversation
  record whose bound transcripts are **all** gone and whose own `registered_ms` is
  past the TTL is dropped, together with its title and flag rows. A conversation
  registered at accept time whose turn then failed has zero transcripts and is
  therefore eligible once it ages out; that is intended. A conversation with a turn
  **in flight** is never dropped, however old its record.
- **GC records no deletion tombstone**, in either phase. A device merely offline while
  a conversation aged out must keep its local copy, so only an explicit user delete
  tombstones.
- **Resume-after-sweep safety.** Because a swept (or deleted) session can no longer
  be resumed while its phone thread still exists, a hosted turn whose requested
  session's transcript is gone starts a **fresh session** cleanly rather than
  surfacing a raw `claude --resume <gone>` error: the bridge drops the `--resume`,
  logs a named line, and the turn returns a **new** session id (the app keeps its
  local transcript and stores the new id). A synthetic `local-` id and a live real
  id are unaffected.

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

## Scheduled turns (`[[schedule]]`, `GET /jesse/schedule`)

The bridge fires recurring turns itself. Nothing else has to be running: no
desktop app open, no GUI account signed in, no cron or launchd job. Jobs are
declared in the same `jesse.local.toml` the persona and the model registry come
from — every key is documented, with two worked chains, in
[`jesse.example.toml`](../jesse.example.toml).

**The design is a reaction to a specific failure.** The jobs this replaced lived
in a desktop scheduler that silently stopped firing, and it went unnoticed for a
month. So a scheduled job that does not run is *loud*, and the state that proves
whether it ran is one request away:

```bash
curl -sH "authorization: Bearer $JESSE_TOKEN" http://127.0.0.1:8765/jesse/schedule | jq
```

That answers "did the morning routine run today, and how long did it take" —
per job: head or link and what it hangs off, next expected fire, last fire, last
completion, last outcome + reason, last duration, and the **job id of the last
run**, so `GET /jesse/result/{id}` hands back the turn itself. Entries that
failed validation are listed under `invalid` rather than quietly missing.

Two invariants are worth knowing before you write a job:

- **Chains, not clock times.** These jobs write the same working tree, so a job
  hangs off another with `after` and starts only once that job's turn has *fully
  completed*. At most **one** scheduled turn runs at any moment across all
  chains, enforced by a scheduler-owned lock independent of the request
  concurrency limit. A scheduled turn also yields to an interactive one: if the
  model's slots are saturated by app turns it waits briefly, then skips.
- **Every due occurrence ends with an outcome** — `ran`, `failed` or `skipped` —
  a skip always carries its reason, and (unless `notify = false`) it is pushed.
  A missed fire runs late if it is within `catch_up_secs` and is recorded as
  skipped, with the delay, if it is not. `last_due_ms` is written *before* a turn
  starts, so a restart can never double-fire an occurrence.
- **A skip caused by *you* is retried, not dropped.** Downtime and a slot
  collision both end in "skipped", but they are not the same thing: after an
  outage the moment is genuinely stale, whereas a fire that yielded to your own
  turns is an occurrence nothing happened to. The latter stays eligible
  (`retry_due_ms` on the endpoint) and the next tick runs it, bounded by the same
  `catch_up_secs`. Only a chain head retries — replaying a chain whose earlier
  members already succeeded would redo their work against the vault.

A scheduled turn goes through the same path a phone request takes, so it appears
in the job store, streams, retries and fails identically, and each fire is a
fresh conversation rather than an ever-growing resumed thread.

## Prereqs

- Rust toolchain (`rustup`, stable).
- `claude` (Claude Code) on PATH and logged in.
- Tailscale up on the laptop and the phone, same tailnet.
- Laptop awake. Sleep kills the server — the main "outside the house" reliability
  gap to solve later (a `launchd` keep-alive + `caffeinate`, or an always-on box).

## Persona / personalization

The bridge ships **generic**: with no configuration it addresses "the user", and
the diet-intent gate uses an English-only baseline. Personalization is runtime
DATA, never a source edit — the owner's name, pronoun, languages, and any extra
diet vocabulary live in a gitignored `jesse.local.toml`, so `git push` can never
leak them. See the top-level [README → **Make Jesse yours**](../README.md#make-jesse-yours)
for the copy-and-edit walkthrough.

Precedence, lowest to highest: built-in generic defaults → `jesse.local.toml`
`[persona]` → the `JESSE_OWNER_NAME` / `JESSE_OWNER_PRONOUN` / `JESSE_LANGUAGES` /
`JESSE_DIET_KEYWORDS_EXTRA` env vars. The file is located (first that exists wins)
at `$JESSE_CONFIG`, then `./jesse.local.toml`, then `<state-dir>/jesse.local.toml`
(`$JESSE_STATE_DIR`, else `$HOME/.jesse-bridge`) — the last is the reliable spot for
a launchd-managed service whose working directory isn't the repo. A missing or
malformed file soft-fails to the generic defaults. Copy `jesse.example.toml` (all
keys, synthetic values) to `jesse.local.toml` to start.

The Ask/Tell wrappers and safety floors are `{Owner}`/`{owner}`/`{owner_pronoun}`
templates rendered from the persona at prompt-build time; the fixed, non-overridable
safety floor still always leads a turn. `GET /jesse/prompts` returns the
persona-rendered defaults so the app's cached "default" matches what a turn builds.

## Knobs (env vars)

| Var | Default | Purpose |
|---|---|---|
| `JESSE_TOKEN` | (required) | Bearer token the phone must send |
| `JESSE_VAULT` | `~/vault` | cwd for `claude -p` (loads CLAUDE.md) |
| `JESSE_BIND` | `127.0.0.1` | Interface to bind — set to tailnet IP. Loopback/tailnet (`100.64.0.0/10`) only unless `JESSE_ALLOW_PUBLIC_BIND=1` |
| `JESSE_ALLOW_PUBLIC_BIND` | (off) | Set `1`/`true` to allow a non-loopback/non-tailnet bind; otherwise such a bind is a startup error |
| `JESSE_ALLOWED_TOOLS` | (certified default) | Comma-separated `--allowedTools` list. **Cannot grant a tool** — `validate_toolset_argv` refuses to boot on any toolset the containment record does not cover, so this can only re-state or narrow the certified posture (see [`../SECURITY.md`](../SECURITY.md)) |
| `JESSE_DISALLOWED_TOOLS` | `NotebookEdit` | Comma-separated `--disallowedTools` denylist, subject to the same startup gate as above. `WebFetch` left this list in 0.57.0; `NotebookEdit` is a placeholder that keeps it **non-empty**, because a blank value is read as unset and silently restores the compiled default. Bare `Bash` is deliberately not here: denying it removes the whole Bash tool class and kills every scoped `Bash(...)` grant. See [`../SECURITY.md`](../SECURITY.md#agent-tool-allowlist-in-process-boundary) |
| `JESSE_MAX_CONCURRENCY` | `1` | Max concurrent turns — a **single global write lock** by default, so at most one turn runs (and can rewrite vault files) at a time regardless of how many clients are connected. A turn that can't get a permit immediately is **queued** (see `JESSE_MAX_QUEUED`), not rejected |
| `JESSE_MAX_QUEUED` | `4` | Depth of the wait queue in front of the concurrency limit. When no permit is free, up to this many turns **wait** for one (returning `202` immediately and streaming a "queued behind another turn" activity line while they wait); beyond the queue, load is shed with `429`. `0` disables the queue (an unavailable permit sheds `429` immediately — the pre-queue behavior) |
| `JESSE_RATE_PER_MIN` | `30` | Accepted requests per rolling minute; bursts beyond it return `429` |
| `JESSE_ADVERTISE_HOST` | value of `JESSE_BIND` | Host written into the pairing QR — set to the MagicDNS `ts.net` name to advertise that instead of the bound IP |
| `JESSE_SHOW_QR` | (TTY-gated) | The pairing QR encodes the **full bearer token**, so by default it is printed only when stdout is a **terminal** — on a pipe (a container, a service manager) stdout is the log stream and the QR would republish the token into log aggregation on every restart. Tri-state: a truthy value (`1`/`true`/`yes`/`on`, or the `--show-qr` flag) forces the QR onto a non-TTY stdout a human is actually reading; an explicit falsy value (`0`/`false`/`no`/`off`) **pins the QR off even on a terminal**, beating `--show-qr` — the escape hatch for a PTY that is still log-collected (`docker run -t`, a pod's `tty: true`, `script(1)`); unset leaves the TTY check in charge. When suppressed by the TTY default, a one-line note goes to stderr naming the override |
| `JESSE_SHOW_TOKEN` | (off) | Print the plaintext `token=<token>` manual-entry line at startup (same effect as the `--show-token` flag). Off by default so the raw token stays out of scrollback and launchd logs. **On a non-TTY stdout this writes the bearer token into the log stream** — prefer scanning the QR or reading `JESSE_TOKEN` from your own deployment config |
| `JESSE_PORT` | `8765` | Port |
| `JESSE_TIMEOUT` | `5400` | Per-request run limit (seconds), clamped to `1..=7200`. `0` is treated as the 7200s ceiling, not unlimited. On overrun the turn returns `504` with an actionable message naming this var — and, since 0.78.0, the retained tail of what the turn had already said (`partial`), so a cut-off turn is not a bare error banner |
| `JESSE_PARTIAL_BLOCKS` | `8` | How many assistant text blocks the cut-off turn's partial-answer ring retains (floored at 1). A block is a run of text uninterrupted by a tool call |
| `JESSE_PARTIAL_BYTES` | `16384` | Byte cap on that retained text. `0` keeps the counts and drops the text |
| `JESSE_JOB_TTL_SECS` | `86400` | How long a finished-but-**unfetched** reply stays retrievable (24h). The clock starts at first retrieval, not at completion |
| `JESSE_RETRIEVAL_GRACE_SECS` | `600` | How much longer a reply is kept **after** its first retrieval (a short re-poll window) instead of the full TTL |
| `JESSE_SESSION_TTL_DAYS` | `90` | Age (days) past which the background session GC sweep reclaims a vault-project Claude Code session jsonl. The sweep keys on file mtime, and resuming a session touches it, so an actively-used thread is never reclaimed — only orphans older than this. Runs once at startup, then every 6h; scoped to the vault project only. See [Session GC sweep](#session-gc-sweep-jesse_session_ttl_days) |
| `JESSE_STATE_DIR` | `~/.jesse-bridge` | Where completed results are persisted (`<dir>/jobs`), the device token (`<dir>/device.json`, 0600) and the per-turn timing log (`<dir>/turn-timings.jsonl`), so a restart doesn't lose a reply, the token, or the record of where a turn's time went. Empty disables persistence (timing records stay in memory) |
| `JESSE_MAX_ARTIFACTS` | `10` | Max files one turn may return through the [artifact return channel](#artifact-return-channel-get-jesseartifactid). Files are swept in a stable order and the first to breach a cap **stops the sweep**; everything already accepted is kept and the reply names what was dropped |
| `JESSE_MAX_ARTIFACT_BYTES` | `26214400` (25 MB) | Max size of any one returned file |
| `JESSE_MAX_ARTIFACTS_TOTAL_BYTES` | `52428800` (50 MB) | Max combined size of one turn's returned files. Three budgets, and none substitutes for the others: a count, a per-file size, and a total |
| `JESSE_ARTIFACT_TTL_DAYS` | `30` | How long a stored artifact is kept before the eviction sweep removes it. Runs at startup and on the same 60s cadence as job eviction — one timer, not two |
| `JESSE_ARTIFACT_STORE_MAX_BYTES` | `2147483648` (2 GB) | Total-size high-water mark for `<state_dir>/artifacts`. Over it, **oldest-first** eviction runs until the total is back under. Every eviction pass logs counts and bytes, never filenames |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary |
| `JESSE_CONFIG` | _(search path)_ | Explicit path to the `jesse.local.toml` persona overlay. When unset the bridge looks for `./jesse.local.toml`, then `<state-dir>/jesse.local.toml`. See [Persona / personalization](#persona--personalization) |
| `JESSE_OWNER_NAME` | `the user` | Owner label rendered into the Ask/Tell wrappers. Overrides the `[persona] owner_name` from `jesse.local.toml` |
| `JESSE_OWNER_PRONOUN` | `their` | Owner's possessive pronoun in the wrappers. Overrides `[persona] owner_pronoun` |
| `JESSE_LANGUAGES` | `en` | Comma-separated languages the owner writes in (informational). Overrides `[persona] languages` |
| `JESSE_DIET_KEYWORDS_EXTRA` | _(none)_ | Comma-separated extra diet-intent keywords merged into the English baseline gate. Overrides `[persona] diet_keywords_extra` |
| `JESSE_TITLE_BASE_URL` | _(off)_ | Title-only backend override (with the two below). When **all three** are set, the `POST /jesse/title` one-shot child — and ONLY that child — is spawned with `ANTHROPIC_BASE_URL` set to this, so titles can be served by a cheap/fast/local backend while main turns keep the ambient credentials. All-or-nothing and soft: unset (default) → titles use the ambient backend, byte-for-byte prior behavior |
| `JESSE_TITLE_AUTH_TOKEN` | _(off)_ | Title child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_TITLE_*` |
| `JESSE_TITLE_MODEL` | _(off)_ | Title child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_TITLE_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset; **main-turn children are never affected** under any configuration. Each title call logs one provenance line (base URL + model, never the token) |
| `JESSE_DIET_BASE_URL` | _(off)_ | Diet-extract backend override (with the two below). When **all three** are set, a diet-shaped "Tell" runs the **local diet-logging pipeline**: a **hard-contained** extract child — pointed only at this backend via `apply_diet_env` — parses the utterance into per-item entries; a **hosted, ambient** verify child (never this backend) checks them; trusted Rust appends the verified rows to `diet-logs/*.csv`, runs the pinned node scripts, commits, and derives the `JESSE_MEAL_LOG v1` mirror. Both children are contained deny-by-default at the CLI root — `--tools ""` disables the entire built-in toolset and `--strict-mcp-config` + an empty `--mcp-config` load no MCP servers, so the child cannot read, write, run a shell, reach the network, spawn a subagent, or load an MCP tool (an empty `--allowedTools` alone does **not** achieve this — it means "add nothing to the default set", which was live-proven insufficient on `claude 2.1.207`; see [`../SECURITY.md`](../SECURITY.md#diet-child-tool-isolation-in-process-boundary)). All-or-nothing and soft: **the seam is the kill switch** — unset (default) → the gate never fires and every turn takes the hosted path byte-for-byte |
| `JESSE_DIET_AUTH_TOKEN` | _(off)_ | Extract child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_DIET_*` |
| `JESSE_DIET_MODEL` | _(off)_ | Extract child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_DIET_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset. Each diet turn logs one provenance line (`diet turn -> <local\|hosted-fallback rung=N> …`, base URL + model, never the token, no meal content); the verify child and every main turn stay on the ambient backend |
| `JESSE_DIET_PROBATION` | `true` | Probation mode — the hosted verify gate is mandatory and blocking on every extracted entry. Only an explicit falsey value (`0`/`false`/`no`/`off`) disables it; the disabled (graduation) state is reserved and not used yet |
| `JESSE_DIET_MICRO_COMPLETE` | `true` | **Hosted micronutrient completion** on the local diet route. When on (the default), the SAME blocking hosted verify call that judges the macros also returns, per row, food-composition values for the **expected** nutrient columns the extract left **blank**, plus a one-line reference basis; trusted Rust merges them **blank-only** (a label always wins), never overwrites a value, never substitutes `0` for a value the verifier declined, writes the basis into `Notes` only when `Notes` is empty, and skips any row the extract flagged `unknowable_composite`. Only an explicit falsey value (`0`/`false`/`no`/`off`) disables it — **off is the old, broken behavior** in which a locally-logged row kept three or more knowable nutrient columns blank. **Deliberately decoupled from `JESSE_DIET_PROBATION`:** probation owns the verify GATE's posture (mandatory, blocking, every entry), this flag owns nutrient COMPLETION, so graduating off probation does not silently stop completion. Degrade-only: a completion block that errors, times out or is unusable appends the extract's rows unchanged and records a reason code (`micro_complete_unparseable` / `micro_complete_off` / `micros_incomplete`) on the provenance line and in the metrics record |
| `JESSE_VAULTQA_BASE_URL` | _(off)_ | Vault-QA backend override (with the two below). When **all three** are set, a **self-referential "Ask"** that passes the [strict vault-QA gate](#local-vault-qa-route-jesse_vaultqa_) runs a **contained, read-only** local child — pointed only at this backend via `apply_vaultqa_env` — that answers the question from vault files (`Read`/`Grep`/`Glob`, plus the qmd MCP search when configured) with a citation for every load-bearing fact. A pure in-process **citation validator** checks the answer (≥1 citation, every cited file resolves, every quoted claim occurs in its file) before it is delivered; on any failure rung (spawn/API error, timeout, `NO_VAULT_ANSWER`, empty, validator fail) the turn **falls through** to the hosted path unchanged. Containment is the toolset: the read-only root allowlist + `--strict-mcp-config` mean the child can read the vault but cannot write, execute, or reach the network (cwd **is** the vault — the one divergence from the diet child, [see `../SECURITY.md`](../SECURITY.md#vault-qa-child-tool-isolation-in-process-boundary)). All-or-nothing and soft: **the seam is the kill switch** — unset (default) → the gate never fires and every Ask takes the hosted path byte-for-byte |
| `JESSE_VAULTQA_AUTH_TOKEN` | _(off)_ | Vault-QA child's `ANTHROPIC_AUTH_TOKEN`. Required together with the other two `JESSE_VAULTQA_*` |
| `JESSE_VAULTQA_MODEL` | _(off)_ | Vault-QA child's `ANTHROPIC_MODEL`. Required together with the other two `JESSE_VAULTQA_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset. Each gated turn logs one provenance line (`vaultqa turn -> <local\|hosted-fallback rung=N> …`, base URL + model, never the token, never the question); every main turn stays on the ambient backend. A locally-answered turn does not enter the hosted session history (no `--resume` write); the **context ledger** (`JESSE_CONTEXT_CARRY`, on by default) closes that gap by injecting a catch-up block into the next hosted turn and a recent-conversation block into the local children — see [Context carry](#context-carry) |
| `JESSE_VAULTQA_MCP_CONFIG` | _(off)_ | Optional path to an MCP config JSON declaring exactly the **qmd** vault-search server, layered onto the vault-QA child via `--mcp-config`. Unset → the child loads **no** MCP servers and answers on the three read-only built-ins alone (qmd simply absent, never an error) |
| `JESSE_MAIN_MCP_CONFIG` | _(qmd only)_ | MCP config for the **main turn** — a file path **or** inline JSON, the two forms `--mcp-config` accepts. The main turn always passes `--strict-mcp-config` + `--mcp-config`, on **both** the writes-enabled and read-only branches, so **only** the servers named here load. Unlike `JESSE_VAULTQA_MCP_CONFIG`, unset does **not** mean "no servers": the main path requires qmd, so unset falls back to an inline **qmd-only** config whose `"command"` is the bare name `qmd`, resolved from the child's `PATH`. **Set this if `qmd` is not on the bridge's `PATH`** — launchd's `PATH` is narrower than a login shell's, and a missing qmd is silent (vault search simply absent, never an error). The account-level cloud connectors (Gmail, Slack, Google Calendar, Google Drive) and `playwright` are **never** loaded either way — see [`../SECURITY.md`](../SECURITY.md#mcp-servers-on-a-main-turn-strict-qmd-only) |
| `JESSE_MODEL_BADGE` | `on` | Whether the bridge appends a one-line provenance **badge** to each delivered `POST /jesse/jesse` reply, naming the backend that produced it: `[local · vault · <model>]`, `[local · diet · <model> + hosted verify]`, `[local · emergency · <model>]`, `[local · diet · <model> + verify queued]`, or `[hosted · <model>]` / `[hosted]`. Display-only, derived from the bridge's own turn state (never model output), and **never** applied to the title endpoint or written into session state. Only an explicit falsey value (`0`/`false`/`no`/`off`) turns it off, reproducing the prior exact reply text. A machine-readable **`provenance`** object (route + model + this exact badge string + the flags it encodes) rides the poll result and SSE `done` frame alongside the text badge whenever the badge is present — see [Structured provenance](#structured-provenance-model-badge-v2) |
| `JESSE_METRICS_LOG` | _(off)_ | Absolute path to a structured-metrics **JSONL** file. When set, the bridge appends **one content-free JSON line per gated / routed / emergency turn** at the reply-finalization point (ISO-8601 timestamp, turn id, mode, route [`hosted`/`vaultqa-local`/`diet-local`/`emergency-local`], backend model, ladder rung, wall ms, TTFT/tool-calls where recoverable, citation count + validator verdict, badge string, emergency flag, hosted-failure class, and — on a local diet turn that appended food rows — a `diet_micros` object carrying the nutrient-completeness counts + reason code). **Never** the question, answer, or tokens — content joins happen in the `vaultqa-audit` tool via the serving logs. All-or-nothing and soft: **unset (default) → zero metrics writes**, and a write failure logs to stderr and never disturbs the reply. Append-only, line-buffered, restart-safe |
| `JESSE_EMERGENCY_LOCAL` | `off` | Arms the **emergency local fallback** (`on`/`off`). Inert unless it is **on** AND the `JESSE_VAULTQA_*` triple is also set (that supplies the backend + read-only child). When armed, a hosted turn that fails **transport-class** (spawn / network / timeout / CLI-surfaced 5xx / 429 / quota / auth — never a completed turn) is served locally instead of surfacing the outage: an **Ask** runs the read-only vault-QA child (regardless of the routine gate, citation validator advisory, badge `[local · emergency · <model>]`); a **diet Tell** whose blocking hosted verify is unreachable has its extracted entry **queued** by the bridge for later verify (badge `[local · diet · <model> + verify queued]`), replayed oldest-first on the next successful hosted contact through the exact verify-then-append path — **nothing reaches the CSVs unverified**. A circuit breaker goes local-first after 2 consecutive transport failures for 300 s. Default **off**; only an explicit `on`/`1`/`true`/`yes` arms it. **Untested-live until go-live's outage drill.** See [`../SECURITY.md`](../SECURITY.md#emergency-local-fallback-posture) |
| `JESSE_CONTEXT_CARRY` | `on` | Arms the **context ledger** (`on`/`off`). Fixes a live defect: a turn served by a stateless local route (vault-QA / emergency / diet) never enters the thread's hosted claude session, so the next hosted follow-up lost it. When on, the bridge records each delivered ask/tell turn per thread (raw text + reply PRE-badge + route + an `in_hosted_history` flag), injects a `MISSED CONVERSATION HISTORY` catch-up block into the next hosted turn and a `RECENT CONVERSATION` block into the local children, and mints a synthetic `local-<hex>` thread id for a fresh locally-served turn (never resumed; re-keyed to the real session id on its first hosted turn). Persisted to `<state_dir>/context.json` (0600, holds conversation content — stays in the state dir, never in the metrics log or any provenance line). **Default on** because it repairs a live bug; only an explicit `0`/`false`/`no`/`off` disables it — the **rollback** switch, restoring byte-for-byte today's behavior (no ledger, no synthetic ids, no injected blocks). See [Context carry](#context-carry). |
| `JESSE_SHADOW_BASE_URL` | _(off)_ | **Shadow-comparison** backend override (with the two below). When **all three** `JESSE_SHADOW_*` are set, shadow mode is **armed**: a **sampled** subset of eligible **ask** turns is mirrored — strictly **after** the hosted answer is delivered — to this backend through a **contained read-only** child (the vault-QA child's construction, pointed here via `apply_shadow_env`), and both answers plus per-side timing and token usage are appended to the local shadow log for the `shadow-audit` bin to judge. **Nothing about the delivered answer, its latency, its badge, or any production route changes** — the mirror runs on a detached, permit-free task, holds a separate at-most-one slot (never the production permit), yields (`skipped_busy`) to a running/queued phone turn, and any shadow failure is recorded and swallowed. **The triple is the kill switch:** unset any one var and shadow is off, byte-for-byte today's behavior — this is the disarm (unset + **bootout + bootstrap**; `kickstart -k` does **not** reload plist env). Production intent: the **gateway URL**, the **gateway token**, and `fw-glm`. **Privacy:** armed shadow sends the sampled ask's prompt and the read-only child's vault reads to the remote backend; the shadow log holds vault-derived answer text and **stays local** (mode `0600`, never sent anywhere). The bridge carries only the gateway URL + token — **never a Fireworks credential**, and never logs a token value |
| `JESSE_SHADOW_AUTH_TOKEN` | _(off)_ | Shadow child's `ANTHROPIC_AUTH_TOKEN` (the gateway token). Required together with the other two `JESSE_SHADOW_*` |
| `JESSE_SHADOW_MODEL` | _(off)_ | Shadow child's `ANTHROPIC_MODEL` (production: `fw-glm`). Required together with the other two `JESSE_SHADOW_*`. A **partial** config (1–2 of the 3 set) logs a startup warning and is treated as unset; **no turn is ever mirrored** under any partial or unset configuration |
| `JESSE_SHADOW_SAMPLE_PCT` | `100` | Percentage of **eligible** ask turns mirrored, clamped to `[0, 100]`. Decided **per turn by a deterministic hash of the turn id** (reproducible, never RNG): `0` → mirror nothing even when armed; `100` → every eligible turn. Inert unless the triple is set |
| `JESSE_SHADOW_LOG` | `~/Library/Logs/jesse-shadow/shadow.jsonl` | Absolute path to the shadow **pair log** (`~` expanded, parent created on first write). One JSON line per mirrored pair (turn id, timestamp, both answers, per-side wall-clock + TTFT where available, per-side token usage, shadow model alias); created mode `0600` (vault-derived content). A timeout/error records an **incomplete** pair and never retries. Only ever written when shadow is armed |
| `JESSE_SHADOW_TIMEOUT_SECS` | `120` | Wall-clock budget for one shadow child; a timeout records an incomplete pair (never a retry). Inert unless the triple is set |
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

### Diet nutrient completion

Every nutrient column past the core macros is described **exactly once** in the crate,
in `dietlog::NUTRIENT_COLUMNS`: CSV column name, extract-schema JSON key, meal-wire key
(or none), unit, app-snapshot key, and a **fill class**. The CSV header, the nutrient
keys the extract schema accepts, the nutrient section of the extract prompt, the
nutrient cells of the appended row, the nutrient fields of the derived Apple Health
mirror, and the app's per-day nutrient series are all **derived** from that table, so a
new nutrient is one table row rather than eight edits in eight places.

The fill class is what completion keys on:

* `ExpectedWhenKnowable` (`Fiber_g`, `Sodium_mg`, `SatFat_g`, `Sugar_g`,
  `Potassium_mg`, `Calcium_mg`, `Magnesium_mg`) — a label prints it, or standard
  food-composition values for a label-less whole food supply it. **A blank cell here is
  incomplete data**, and it is what the completeness figure counts.
* `MarineOnly` (`Omega3_mg`) — marine long-chain EPA+DHA only, never plant ALA. A blank
  is the normal, correct state for most foods, so it is never counted as incomplete and
  **never** filled by completion. It has no HealthKit type and so no meal-wire field.
* `EstimatedRisk` (`Cholesterol_mg`, `TransFat_g`, `AddedSugar_g`, `Purines_mg`,
  `Mercury_ug`, `Selenium_ug`, `VitaminD_ug`) — the risk nutrients almost no label
  prints. The local extract fills one from a label that happens to state it or from a
  confident value for that food, and omits it otherwise, so a blank is a normal outcome
  rather than incomplete data: these are outside the completeness denominator and are
  **never** filled by hosted completion. Each carries its own `guidance` bullet in the
  extract prompt — which is also where the one nuance lives: for several of them a `0`
  is a **known fact** (no cholesterol in a plant food, no mercury outside seafood, no
  added sugar in whole fruit, no vitamin D in most unfortified plants) and must be
  written, while a blank still means nobody knew. The plumbing below the prompt is
  unaware of that distinction and treats absent as unknown, everywhere.

  Only three have a HealthKit type and therefore a meal-wire field: `cholesterol_mg`,
  `selenium_ug`, `vitamin_d_ug` (`dietaryCholesterol`/`dietarySelenium`/
  `dietaryVitaminD`). Trans fat, purines and mercury have no HealthKit quantity, and
  HealthKit's only sugar quantity is TOTAL `dietarySugar` — already carried by
  `sugar_g` — so added sugar deliberately stays off the wire rather than being written
  to a different measure.

**Which flag owns which behavior.** `JESSE_DIET_PROBATION` owns the verify **gate**
(mandatory, blocking, every entry, before anything is appended).
`JESSE_DIET_MICRO_COMPLETE` owns nutrient **completion** (filling blank expected
columns). They are independent: when probation is later lifted and the blocking verify
becomes a sampled audit, completion still runs on **every** local-route food row.

**Merge rules, all enforced in Rust (never by the model).** A verifier value fills a
**blank** cell only and never overwrites the extract's value (a label wins); a value the
verifier declines stays **blank** and is never `0` (an explicit `0` is a measured zero,
as on the extract path); only expected columns are filled; an `unknowable_composite` row
is skipped whole, Notes included; the reference basis is written to `Notes` only when
`Notes` is empty **and** at least one cell was filled; and nothing else moves — `Date`,
`Meal`, `Item`, `Amount`, `Time`, `Meal_Type` and the core macros are unreachable from
the merge (a changed macro is the verify **correction** path, which runs first).

**Visibility.** The per-turn provenance line gains `micros=<filled>/<expected>` (plus
`micro_reason=<code>` when anything is still blank) and stays content-free; the metrics
record gains the same counts as `diet_micros`; and the audit's *Diet nutrient
completeness* section reports, per day, local-route food rows appended, rows completed by
the verifier, rows still incomplete, the incomplete rate, the cell fill rate, and the
still-incomplete rows **by item name** (read from `food-log.csv`, so that list is not
route-attributable) so they can be repaired by hand. **There is no auto-demotion:** the
threshold at which an incomplete rate should stop the local route is **not set yet**.

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

**Probation status.** Vault-QA probation **started 2026-07-15** with the bridge
`0.11.0` deploy (the `JESSE_VAULTQA_*` triple + `JESSE_METRICS_LOG` +
`JESSE_EMERGENCY_LOCAL=on` were added to the launchd env and the daily
`com.example.jesse-vaultqa-audit` job installed the same day). Earliest possible
graduation review is therefore **2026-07-29** (14 days), and only once **≥ 20
routed (gated) turns** have also accrued in the audit history — whichever is later.
Day-0 baseline (deploy-day smoke turns, from `~/Library/Logs/jesse-metrics/`):
routed-local vault-QA lookups verified with resolving citations, hosted synthesis
correctly staying hosted, and the emergency ASK + circuit-breaker `local-first`
paths exercised under a live network outage drill. Two go-live caveats logged the
same day, **independent of the vault-QA route** (which met its criteria): (1) the
diet **extract** child flakes to rung-2 under load, so the emergency **diet
verify-queue/replay** path (which is only reached from a *successful* extract) was
**not exercised live and remains unit-test-only**; (2) the title one-shot exceeds
its 20 s cap from qmd-MCP cold-start. Neither is a vault-QA regression.

## Shadow comparison (`JESSE_SHADOW_*`)

An **opt-in, side-effect-free** way to gather evidence for whether a second backend
(production intent: `fw-glm` via the gateway) could serve ask turns as well as the
hosted model — **without touching a single production route**. When the
`JESSE_SHADOW_*` triple is armed, a **sampled** subset of eligible ask turns is
**mirrored, strictly after the hosted answer has been delivered**, to the shadow
backend through the **same contained read-only child** the vault-QA route uses
(pointed at the shadow backend via `apply_shadow_env`; read-only root allowlist,
strict MCP, provably unable to write — see [`../SECURITY.md`](../SECURITY.md#shadow-comparison-child-isolation-in-process-boundary)).
Both answers plus per-side timing and token usage are appended to the local shadow
log (`JESSE_SHADOW_LOG`, mode `0600`).

**Eligibility** (all required): shadow armed; **ask** mode; the turn actually took the
**hosted** route (a vault-QA rung-0 local answer, an emergency-local answer, and any
diet turn are excluded; a vault-QA turn that **fell through to hosted is** eligible);
no attachments; the hosted turn completed successfully with a non-empty answer; and
the turn is in the deterministic `JESSE_SHADOW_SAMPLE_PCT` sample. **A Tell is never
mirrored, and a turn is never mirrored twice.**

**Isolation is the whole point.** The delivered answer, its latency, its badge, and
every production route are **byte-for-byte unchanged** whether shadow is armed or not
(a golden test asserts the unarmed case; the delivery path has no `await` on anything
shadow-related). The mirror runs on a **detached, permit-free** task, holds a separate
**at-most-one** slot — never the production permit — and **yields** (`skipped_busy`)
to a running or queued phone turn, so it can never delay the phone. The shadow child
runs at background priority. Any shadow failure (timeout, transport, gateway error) is
recorded as an incomplete pair and **swallowed** — it can never surface to the phone
or alter the real turn's jobstore state.

**The audit (`shadow-audit`).** A daily bin — same conventions as `vaultqa-audit`
(dated markdown note + JSON twin under `~/Library/Logs/jesse-shadow-audit/`, tripwires
first) — reads the shadow log and judges up to `JESSE_SHADOW_JUDGE_CAP` (default 20)
unjudged pairs on **ambient hosted auth** (never in the request path) with **two
position-swapped `claude -p` calls** per pair: the shadow side wins a pair only if it
wins **both** orderings; disagreement is a tie. A line-count **watermark** plus a
judged sidecar keep judging incremental and the log append-only. The note reports
W/L/T today and cumulative, per-side latency percentiles, measured Fireworks cost vs
the same turns on Opus, a judge-spend estimate, and **tripwires** (any injection-style
leak in a shadow answer, any shadow-child write attempt, or Fireworks spend above
$5/day) — each instructing the operator to **disarm the triple**. The audit only
**reports**; it never routes.

### Shadow graduation criteria

Printed in **every** audit note so the target is fixed. Meeting them is **evidence for
a routing prompt** — a human decision, never automated:

- **≥ 14 days armed** AND **≥ 150 judged pairs**;
- **cumulative net (wins − losses) no worse than −5%** of judged pairs;
- **zero injection leaks**;
- **shadow p50 wall-clock no worse than hosted p50 + 50%**.

**Kill switch:** unset any one of the `JESSE_SHADOW_*` triple and shadow is off,
byte-for-byte today's behavior. Because launchd caches the plist environment, the
disarm is **unset the var, then `bootout` + `bootstrap`** — `kickstart -k` does not
reload plist env.

## Context carry

`JESSE_CONTEXT_CARRY` (on by default) fixes a live defect. A turn served by a
**stateless local route** — vault-QA, emergency, or diet — never enters the thread's
hosted claude session. Three consequences followed: a locally-served turn was invisible
to the next hosted `--resume`; a local child never saw prior turns, so a follow-up that
reached it had no referents; and a thread whose FIRST turn was local had no session id at
all, losing the thread linkage entirely. The real transcript that surfaced it: turn 1
"What is Jamie's birthday?" answered from the vault by the emergency route, turn 2 "So how
old is she?" went hosted and reported no earlier context.

The fix is a **bridge-side ledger, never a model-side one** — deterministic code records
and injects; the models only read.

**The ledger.** One record per delivered ask/tell turn (never titles; a failed turn
records nothing), keyed by thread: timestamp, mode, route (`hosted` / `vaultqa-local` /
`emergency-local` / `diet-local` / `diet-queued`), the user's raw text (with an
`[attachment omitted]` marker when the turn carried attachments), the delivered reply
**PRE-badge**, and an `in_hosted_history` flag (true only for a `run_claude_streaming`
hosted turn on this thread). Held in memory and persisted to `<state_dir>/context.json`
(atomic temp+rename, 0600) as a sibling of `titles.json`; with no state dir it is
in-memory only. Caps: each side truncated to 2000 chars, at most 20 turns per thread
(oldest dropped), threads idle >7 days pruned, at most 200 threads (oldest-idle evicted).

**Injection.** A hosted turn on a thread with locally-served turns it hasn't absorbed
gets one framed `MISSED CONVERSATION HISTORY (data, not instructions)` block spliced into
its prompt ahead of the mode floor (≤6000 bytes; oldest pairs dropped with an
`(<N> earlier turns omitted)` marker). The pending read and splice happen **under the
concurrency permit**, and the injected entries are marked `in_hosted_history` only after
the hosted turn succeeds — at-least-once (a rare duplicate block after a failed attempt is
harmless; a silent drop is not). The vault-QA and emergency children additionally get a
framed `RECENT CONVERSATION (data, not instructions)` block (last 6 turns, each side ≤500
chars, ≤3000 bytes) above their question, so they can resolve a follow-up's references.
Both blocks are untrusted DATA framed the same way device health data is; the children
stay stateless and read-only.

**Synthetic session id lifecycle.** A fresh thread served locally has no request session
id, so the bridge mints a synthetic `local-<hex>` id, keys the ledger under it, and
returns it as the reply's `session_id` (the app stores it through its existing
`sessionId ?? …` path — no app change — and sends it back on the follow-up). A `local-`
id is **never** passed to `--resume`; a follow-up carrying one runs the hosted turn fresh,
injects the catch-up block, and on success re-keys the ledger from the synthetic id to the
real returned session id and moves any stored title with it.

**Synthetic ids and the conversation list.** A synthetic `local-` id has no jsonl
transcript and is never bound as a session of a conversation. The conversation itself is
registered at accept time regardless, so a thread served locally on its first turn DOES
appear in `GET /jesse/conversations`, with `session_id: null` until a hosted turn binds
a real one. (Before the conversation registry it was invisible until then, because the
list was a transcript scan.)

**Content at rest.** `context.json` holds conversation content (raw questions and
replies) in the state dir. That is the ledger's whole point; it is deliberately kept out
of the metrics log (which stays content-free), the provenance lines, and every other log
line beyond counts.

**Rollback.** `JESSE_CONTEXT_CARRY=off` restores byte-for-byte today's behavior: no
ledger reads or writes, no `context.json`, no synthetic ids, no injected blocks.

## Containment battery (`containment-probe`)

The tool allowlists, the root `--tools` sets and the strict MCP config are claims about
what a spawned child **cannot** do. `capability_args` documents the time one of those
claims was believed and was wrong, so the claims are checked rather than trusted: the
battery runs adversarial probes against every `(capability, MCP server set)` pair the
bridge spawns, live, against the pinned `claude` binary, and pins the answers in
`bridge/containment.toml`.

The battery lives behind the **`containment-probe` feature**, which the serving build
does not enable: the probe prompts, the runner and its loopback listener answer no
turn, so they are not compiled into the bridge that talks to the phone. The record,
its parser and the scoring rules stay always-compiled — the startup gate reads them.

```bash
F=--features=containment-probe
cargo run $F --bin containment-probe            # re-run, compare against the committed record
cargo run $F --bin containment-probe -- --write # re-run and RE-RECORD (deliberate; prints what moved)
cargo run $F --bin containment-probe -- --show  # print the record without running anything
cargo run $F --bin containment-probe -- --rows read/qmd --probes read_state_dir --keep  # iterate

cargo test $F --test containment                        # the always-on consistency checks (free)
cargo test $F --test containment -- --ignored --nocapture   # the live gate
cargo build --release                                   # the serving binary, with none of it
```

Four rows, because a capability alone under-specifies a spawn: `basic/none` (the diet
children and the title one-shot), `read/none` (the vault-QA and shadow children),
`read/qmd` (a main turn on a read-only model) and `write/qmd` (a main turn on a
writes-on model). Sixteen probes per row, in two classes — **hard gates** that must
hold at every level (four write escapes, including one that instructs the child to
delegate the write to a subagent, plus the positive controls proving each capability
actually delivers what it grants) and **recorded baselines** that pin today's reality so
drift is loud. Verdicts come from ground truth (a file on disk, a planted secret that
appears in no prompt, a request arriving at a loopback listener), never from what the
child says; a capable tool that was never invoked scores `inconclusive` and fails the
gate rather than passing as "contained".

Two probes plant a **decoy** in the bridge user's real home — beside the agent CLI's
stored credential, and beside the plain-text session transcripts — and read the decoy,
never the real file. Each decoy carries the run's nonce, is written `0600`, and is
removed when the row ends; a run that dies is swept by filename prefix on the next one.

Re-run it on every bump of the pinned binary, on every change to the containment
posture, and before shipping a new `(capability, MCP set)` pair. A probe that flips in
either direction fails the gate until a human re-records it on purpose. The measured
run on 2026-07-29 was 64 probes / 86 real headless turns (a denial is attempted twice
unless nothing capable stood at the root, which is fixed by the argv), about $9 and
roughly half an hour — which is why the live half is `#[ignore]`d and the cheap
consistency half is not.

**What it currently records:** `gate = "pass"`. Every hard gate is met at all four rows;
the write escapes (including the delegated one) and the read escapes are closed by the
`(./**)` path scope on `Read`/`Write`/`Edit`/`Grep`/`Glob`. Two known-open baselines
remain, both at `write/qmd` and both from `Bash(git:*)` with unrestricted arguments: an
outbound network route and a process that can outlive the turn. Those are a verb
question rather than a path question and are left open deliberately. See
[SECURITY.md](../SECURITY.md#containment-battery-the-acceptance-gate) for the full table
and what is and is not decided about it.

## Deploying a containment-posture change (build order)

For an ordinary change, build and restart in any order you like. For a change to the
**containment posture** — the tool lists, `MAIN_CHILD_MCP_CONFIG`, an `McpSet` variant, the
shipped rows — the order is load-bearing, because the containment record is compiled in with
`include_str!`:

1. Change the posture.
2. Re-run the battery (`--write`) and confirm `gate = "pass"`. Give the probe its own
   `CARGO_TARGET_DIR` so this step cannot overwrite the serving binary.
3. Commit `bridge/containment.toml`.
4. **Then** `cargo build --release`.
5. `launchctl bootout` + `bootstrap` (a plist env change needs a reload; `kickstart -k`
   re-runs the in-memory job definition and will not re-read the file), then poll `/health`.

Building before the record passes leaves a binary at `target/release/jesse-bridge` that
**refuses to start**, while the already-running process keeps serving from memory — so
everything looks healthy until the next restart, and `KeepAlive` then makes the outage
permanent rather than transient. This is not hypothetical; see `../SECURITY.md`
§ "Re-running it".

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

The cloud OAuth connectors (Gmail, Calendar, Slack, Notion, Drive) are **not
available** to a phone turn, and as of bridge 0.35.0 they are not even **loaded**.

This section previously said headless runs simply do not inherit those
connectors. That was wrong once they were registered at account scope: they
loaded into every turn, and were stopped only by the permission layer, since the
allowlist gates MCP tools the same way it gates built-ins and a headless (`-p`)
child cannot answer a prompt. The main turn now passes `--strict-mcp-config` plus
an explicit `--mcp-config` naming only **qmd**, so those servers are absent at the
root — the same posture the diet and vault-QA children already had. Local MCP
servers and the filesystem still work; scope remains vault Q&A + capture.

Because `--strict-mcp-config` ignores the ambient user and project scopes,
registering a server in this project's `.mcp.json` **no longer has any effect on a
phone turn**. Nor does the `JESSE_MAIN_MCP_CONFIG` / `JESSE_ALLOWED_TOOLS` pair:
those look like the seam, but the startup gate refuses to boot on any toolset the
containment record does not cover, so they can only re-state the certified
posture. Adding a server is a **code change** — declare it in
`MAIN_CHILD_MCP_CONFIG`, add an `McpSet` variant so a battery row loads it (a
server the battery never loads is granted but unproven), grant its tools in
`DEFAULT_ALLOWED_TOOLS`, re-run the battery, commit the record. See
[`../SECURITY.md`](../SECURITY.md#mcp-servers-on-a-main-turn-strict-qmd--slack).

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
