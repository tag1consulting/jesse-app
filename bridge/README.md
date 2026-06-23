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
| `JESSE_BIND` | `127.0.0.1` | Interface to bind — set to tailnet IP |
| `JESSE_PORT` | `8765` | Port |
| `JESSE_TIMEOUT` | `1800` | Hard ceiling per request (seconds). `0` = unlimited (no timeout — rely on the client's Cancel button) |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary |

The server refuses to start if `JESSE_TOKEN` is unset, the vault isn't a
directory, or the `claude` binary can't be found.

## Hardening past the PoC

- Swap `--permission-mode acceptEdits` for a scoped `--allowedTools` allowlist.
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
