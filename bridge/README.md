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
reachable; the `ts.net` name has DNS quirks — see `STATUS.md`). To put the
MagicDNS hostname in the QR instead, set `JESSE_ADVERTISE_HOST`:

```bash
export JESSE_ADVERTISE_HOST="build-host.tailnet.ts.net"
```

A clean `cargo build --release` is the gate — if it doesn't compile, it isn't done.

## Test from the laptop

```bash
curl -s http://127.0.0.1:8765/health

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

`POST /jesse` waits up to a short **grace window** (`JESSE_GRACE_SECS`, default
`10s`) for the turn:

- Done within grace → **`200`** with the usual `{ mode, response, session_id }`
  **plus** a `job_id` (additive; existing callers ignore it).
- Still running at grace expiry → **`202 { "job_id": "...", "status": "running" }`**.
  The turn keeps running server-side.

Fetch the result later by id:

```bash
curl -s http://127.0.0.1:8765/jesse/result/<job_id> \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "status": "running" }
#   { "status": "done", "response": "...", "session_id": "..." }
#   { "status": "failed", "error": "..." }
```

Same bearer auth as `/jesse`. An unknown or evicted id → **`404`**. Completed and
failed jobs are evicted on a TTL (`JESSE_JOB_TTL_SECS`, default `600s`) so the
in-memory store can't grow unbounded. The store is in-memory only: a bridge
restart drops in-flight jobs. That's acceptable for a single-user bridge; the
escalation path, if cross-restart durability is ever needed, is a disk- or
queue-backed store.

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

**`GET /jesse/prompts`** — returns the current built-in wrappers, the exact const
strings `build_prompt` applies for a fresh turn, so the app's "default" matches
what the bridge would use. Same bearer auth as `/jesse`.

```bash
curl -s http://127.0.0.1:8765/jesse/prompts \
  -H "Authorization: Bearer $JESSE_TOKEN"
# → { "ask": "<default ask wrapper>", "tell": "<default tell wrapper>" }
```

**`POST /jesse` with an optional `"instructions"` field** — when present and
non-empty, it replaces the **active mode's** wrapper for that one request; when
absent or blank, the built-in const is used exactly as before (so omitting the
field reproduces today's behavior byte-for-byte). The bridge still appends its
own voice/phone-format suffix regardless of the override, so it always owns
output formatting.

```bash
curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"What is on Today.md?","instructions":"Answer in one line. Question: "}'
```

The design is deliberately stateless: the bridge never stores a custom wrapper.
The app persists the user's edits and sends `instructions` only when a mode is
actually customized; an empty field always means "use the bridge default" and the
field is omitted. The standing CLAUDE.md invariant — "Ask" forbids *action* he
didn't request, never *writing* a durable fact — lives in the default Ask wrapper
the app seeds its editor from, and the app surfaces it as helper text so a
customized wrapper preserves it.

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
| `JESSE_TIMEOUT` | `1800` | Hard ceiling per request (seconds), clamped to `1..=3600`. `0` is treated as the 3600s ceiling, not unlimited |
| `JESSE_GRACE_SECS` | `10` | How long `POST /jesse` holds the connection for the inline fast path before returning `202` and letting the client poll `GET /jesse/result/{job_id}` |
| `JESSE_JOB_TTL_SECS` | `600` | How long a completed/failed job stays retrievable before TTL eviction |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary |

The server refuses to start if `JESSE_TOKEN` is unset, the vault isn't a
directory, the `claude` binary can't be found, or `JESSE_BIND` is an unsafe
address without the override.

## Hardening past the PoC

- Put it behind `tailscale serve` for real TLS + a stable hostname.
- Add `--resume`/`--session-id` plumbing if you want richer thread control.
- Stream with `--output-format stream-json` for live token output.

## Connector caveat

Headless Claude Code does **not** inherit Cowork's OAuth connectors (Gmail,
Calendar, Slack, Notion, Drive). Local MCP servers (QMD, Home Assistant, etc.)
and the filesystem **do** work. PoC scope = vault Q&A + capture, which is fine.
To use the cloud connectors here, register them in this project's `.mcp.json`.

## Note

`_removed-python/` holds the original Python prototype, kept only because this
sandbox can't delete files on the mounted volume. Delete it when you relocate the
project — it is not part of the build.
