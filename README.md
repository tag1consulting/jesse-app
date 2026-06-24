# Jesse

Ask and update your Obsidian-style "vault" from your iPhone, in natural language,
by driving headless [Claude Code](https://claude.com/claude-code) against it on
your laptop. Two pieces:

- **`bridge/`** — a small Rust (Axum + Tokio) HTTP service that runs on the
  laptop. It turns each request into a `claude -p` run in the vault directory and
  returns the answer. Single static binary.
- **`Jesse/`** — the SwiftUI iOS app. Conversation threads, "Ask Jesse" (read)
  and "Tell Jesse" (capture) modes, Markdown rendering, optional spoken replies,
  and Siri shortcuts.

The phone reaches the laptop over [Tailscale](https://tailscale.com), so nothing
is exposed to the public internet.

```
iPhone (Jesse app)  ──HTTP over Tailscale──▶  Laptop (jesse-bridge)  ──▶  claude -p  ──▶  vault/
        ▲                                                                                   │
        └───────────────────────────  answer / session_id  ◀────────────────────────────────┘
```

> Status: working proof of concept for a **single trusted user on their own
> tailnet**. Read [Security model](#security-model) before exposing it to anyone
> else.

---

## Repository layout

| Path | What |
|---|---|
| `bridge/` | Rust bridge service. See [`bridge/README.md`](bridge/README.md) for the full HTTP contract, endpoints, and env knobs. |
| `Jesse/` | Xcode project for the iOS app (`Jesse` app target + `JesseTests`). |
| `STATUS.md` | Running build/test log and design notes. |

---

## Prerequisites

**Laptop (bridge):**

- macOS or Linux with the **Rust** toolchain (`rustup`, stable). Verify: `cargo --version`.
- **Claude Code** (`claude`) installed, on `PATH`, and **logged in** as the user who
  will run the bridge. Verify: `claude --version` and run `claude` once interactively
  to confirm it is authenticated.
- A **vault** directory — any folder Claude Code should operate in. It usually
  contains a `CLAUDE.md` so Claude behaves like "Jesse." It does **not** need to be
  a git repo.
- **Tailscale** installed and `up`, with **MagicDNS enabled** (see the ATS note
  below for why the hostname matters).

**Phone + build machine (app):**

- A **Mac with Xcode** new enough to target **iOS 26.5** (this project's deployment
  target — see [Known installation problems](#known-installation-problems)).
- An **iPhone running iOS 26.5 or newer**, signed into Tailscale on the **same
  tailnet** as the laptop.
- An **Apple Developer account** (a free Apple ID works for personal on-device
  installs, with the 7-day limit noted below).

---

## Security model

Read this before pairing a second device or running the bridge anywhere shared.

- **One bearer token is the only authentication.** Every request must send
  `Authorization: Bearer <token>`. Anyone who has the token *and* is on your
  tailnet can read and write your vault. Treat it like a password.
- **The bridge runs Claude Code under an explicit tool allowlist inside your
  vault** — `--permission-mode default` plus a scoped `--allowedTools` list
  (file read/write/search, read-only vault search, and scoped `git`/`mv`/`ls`/
  `cat`/`find`), with unscoped shell and `WebFetch` denied. It can read and
  modify files in the vault ("Tell Jesse" is how capture works). Point
  `JESSE_VAULT` only at a directory you are comfortable letting it change, and
  only pair people you trust on your tailnet. The allowlist is the only
  in-process boundary; see [SECURITY.md](SECURITY.md) for the deployment posture
  it assumes (dedicated low-privilege user, OS sandbox).
- **Transport is plain HTTP, but confined to the Tailscale tailnet** — a private,
  WireGuard-encrypted network. The traffic is not on the public internet. The iOS
  app's App Transport Security exception is **scoped to `ts.net`**, not a blanket
  `NSAllowsArbitraryLoads`.
- **The bridge refuses to bind anything but loopback or tailnet/CGNAT space**
  (`127.0.0.0/8`, `::1`, `100.64.0.0/10`) — an unsafe bind is a hard startup
  error unless you set `JESSE_ALLOW_PUBLIC_BIND=1`. It will not answer on your
  home Wi-Fi or any other interface by default.
- **Concurrency, request rate, and per-turn time are bounded** so one client
  can't exhaust the host: `JESSE_MAX_CONCURRENCY` (default 2),
  `JESSE_RATE_PER_MIN` (default 30), and a hard 3600s timeout ceiling. Excess
  load is shed with `429`.
- **The token is never logged by the bridge** and is stored on the phone in the
  **iOS Keychain** (not plaintext `UserDefaults`).

### Do not commit or share secrets

- **Never put a real `JESSE_TOKEN` in a file you commit** — not in this README,
  scripts, CI, or `STATUS.md`. Pass it through the environment at runtime
  (examples below generate a fresh one and never echo a literal).
- **The startup pairing QR — and the plaintext `token=…` line printed beside it —
  contains the token.** Do not screenshot, paste, or screen-share that terminal
  output. Anyone who can read it can drive your vault.
- **To rotate the token**, restart the bridge with a new `JESSE_TOKEN` and
  re-pair the phone (Settings → Scan to pair). The old token stops working
  immediately.
- Your tailnet IP and MagicDNS hostname are environment-specific. The examples
  below use placeholders — substitute your own; there's no need to publish them.

---

## 1. Run the bridge (laptop)

```bash
cd bridge

# Generate a token and keep it ONLY in this shell's environment.
# (Do not paste the resulting value into any committed file.)
export JESSE_TOKEN="$(openssl rand -hex 24)"

# The folder Claude Code should work in.
export JESSE_VAULT="$HOME/path/to/your/vault"

# Bind to the tailnet interface so the phone can reach it.
export JESSE_BIND="$(tailscale ip -4 | head -1)"   # or 127.0.0.1 for a local-only test

# IMPORTANT: advertise the MagicDNS hostname in the pairing QR, not the raw IP,
# so the app's ts.net ATS exception applies. Find yours with:  tailscale status
export JESSE_ADVERTISE_HOST="<your-laptop>.<your-tailnet>.ts.net"

cargo run --release
```

On startup the bridge prints a **pairing QR** and a plaintext fallback:

```
█▀▀▀▀▀█  …  █▀▀▀▀▀█
…  (terminal QR)  …
Pair by scanning the QR above, or enter manually:
  host=<your-laptop>.<your-tailnet>.ts.net  port=8765  token=<token>
```

The QR encodes `jesse://pair?host=…&port=…&token=…`. (Reminder: this output
contains your token — keep it on-screen only.)

Sanity-check it from the laptop before touching the phone:

```bash
curl -s http://127.0.0.1:8765/health
# → {"ok":true,"vault":"…","claude":"claude"}

curl -s http://127.0.0.1:8765/jesse \
  -H "Authorization: Bearer $JESSE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ask","text":"What is on Today.md?"}'
```

### Bridge configuration knobs

Full table in [`bridge/README.md`](bridge/README.md#knobs-env-vars). Most-used:

| Var | Default | Purpose |
|---|---|---|
| `JESSE_TOKEN` | **required** | Bearer token the phone must send. The server refuses to start without it. |
| `JESSE_VAULT` | `~/devel/tag1/jesse` | Working directory for `claude -p`. Must be an existing directory. |
| `JESSE_BIND` | `127.0.0.1` | Interface to bind. Set to the tailnet IP for phone access. Loopback/tailnet only unless `JESSE_ALLOW_PUBLIC_BIND=1`. |
| `JESSE_ALLOW_PUBLIC_BIND` | _(off)_ | Set to `1` to allow binding a non-loopback/non-tailnet address. Off by default; an unsafe bind is otherwise a startup error. |
| `JESSE_ALLOWED_TOOLS` | _(scoped default)_ | Comma-separated `--allowedTools` list for the agent. See [SECURITY.md](SECURITY.md). |
| `JESSE_DISALLOWED_TOOLS` | `Bash,WebFetch` | Comma-separated `--disallowedTools` denylist (defense-in-depth). |
| `JESSE_MAX_CONCURRENCY` | `2` | Max concurrent turns; excess returns `429`. |
| `JESSE_RATE_PER_MIN` | `30` | Accepted requests per rolling minute; bursts beyond it return `429`. |
| `JESSE_ADVERTISE_HOST` | value of `JESSE_BIND` | Host written into the pairing QR. **Set to your `ts.net` MagicDNS name** (see ATS note). |
| `JESSE_PORT` | `8765` | Port. |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary. Use an absolute path if it isn't on the bridge's `PATH`. |

The bridge **refuses to start** if `JESSE_TOKEN` is unset, `JESSE_VAULT` isn't a
directory, the `claude` binary can't be found, or `JESSE_BIND` is an unsafe
address without the override — each with a one-line message
and exit code 1.

### Keep the laptop awake

The bridge dies when the laptop sleeps. For an "away from the desk" session, keep
it running under `caffeinate`:

```bash
caffeinate -s cargo run --release
```

---

## 2. Build and install the app (Xcode)

1. Open `Jesse/Jesse.xcodeproj` in Xcode.
2. Select the **Jesse** target → **Signing & Capabilities**:
   - Set **Team** to *your* Apple Developer team. The project ships with a
     placeholder team and `com.tag1.Jesse` bundle identifier that will **not**
     sign for you — change the bundle identifier to something unique (e.g.
     `com.yourname.Jesse`) and let Xcode manage signing automatically.
3. Plug in your iPhone (or use a wireless-paired device), select it as the run
   destination.
4. **Run** (⌘R). Accept the camera permission prompt when you first open the
   pairing scanner.

To run the unit tests (54 of them) from the command line:

```bash
cd Jesse
xcodebuild test -scheme Jesse \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

(Adjust the simulator name to one your Xcode has installed.)

---

## 3. Pair the phone with the bridge

1. With the bridge running, open the app → **Settings** (gear) → **Scan to pair**.
2. Point the camera at the QR in the bridge's terminal. Host, port, and token
   fill in automatically. Tap **Save**.
3. Manual entry is the fallback: type the `host`, `port`, and `token` from the
   printed line into the Settings fields.

Use the **MagicDNS hostname** (`…ts.net`) as the host, not the raw `100.x` IP —
see the ATS note in [Known installation problems](#known-installation-problems).

---

## Using Jesse

- **Ask Jesse** — a read-style question ("What's on Today?"). Claude re-reads the
  vault each fresh thread.
- **Tell Jesse** — capture something ("Note that the roof guy comes Thursday").
  This **writes** to the vault.
- **Threads / follow-ups** — staying in a conversation continues its Claude
  session, so follow-up questions keep context. Starting a new thread is a fresh
  session.
- **Cancel** — long turns (past the bridge's ~10s grace window) keep running on
  the laptop and the app polls for the result. Cancel returns the thread to idle
  immediately and discards the in-flight result.
- **Backgrounding** — if you background the app mid-turn, the bridge keeps the
  turn alive; the reply re-attaches when you reopen the app.
- **Voice / Siri** — "Ask Jesse…" and "Tell Jesse…" Siri phrases route into a new
  thread and read the reply aloud (on-device text-to-speech).

---

## Known installation problems

These are the things most likely to bite during setup, roughly in order:

1. **App Transport Security blocks the raw tailnet IP.** The app's ATS exception
   covers the `ts.net` domain only. If you pair using the raw `100.x` IP, iOS
   blocks the cleartext HTTP load and every request fails. **Fix:** enable
   MagicDNS in Tailscale and set `JESSE_ADVERTISE_HOST` to your laptop's
   `…ts.net` hostname so the QR (and the app) use the hostname. (An IP literal
   can't be expressed as an ATS domain exception; the hostname route is the clean
   one.)

2. **iOS 26.5 deployment target.** The project targets iOS 26.5, so you need a
   matching recent Xcode and an iPhone on iOS 26.5+. Older devices won't install
   it. To support an older OS, lower `IPHONEOS_DEPLOYMENT_TARGET` in the project
   and re-test.

3. **Signing fails out of the box.** The committed project uses a specific Apple
   Developer **Team** and the `com.tag1.Jesse` bundle ID. You must set your own
   team and a unique bundle identifier, or Xcode reports a provisioning error.

4. **Free Apple ID app expiry / "Untrusted Developer."** Apps signed with a free
   (personal-team) Apple ID expire after **7 days** and must be re-installed from
   Xcode. On first launch you may also need **Settings → General → VPN & Device
   Management → trust your developer certificate**.

5. **`claude` not found by the bridge.** The bridge spawns `claude`. If it isn't
   on the `PATH` of the shell/process that launches the bridge (GUI-launched
   terminals can differ), startup fails with "claude binary not found." **Fix:**
   set `JESSE_CLAUDE_BIN` to the absolute path (`which claude`).

6. **`claude` not logged in.** The bridge runs Claude Code non-interactively; if
   it isn't authenticated, runs fail. Run `claude` once interactively first.

7. **Tailscale not up / wrong tailnet.** `tailscale ip -4` must return an address,
   the phone must be on the **same tailnet**, and `JESSE_BIND` must be that
   interface (otherwise the bind itself fails). Confirm both ends with
   `tailscale status`.

8. **Bind address vs. firewall.** The bridge binds the tailnet IP only. A local
   `curl http://127.0.0.1:8765/health` works only if you bound `127.0.0.1` or the
   loopback path is allowed; test the tailnet address from the phone's browser
   (`http://<host>.<tailnet>.ts.net:8765/health`) if pairing seems stuck.

9. **Laptop sleeps → server dies.** Mid-session sleep kills the bridge and any
   in-flight jobs (the job store is in-memory). Run under `caffeinate` for
   away-from-desk use.

10. **Cloud connectors aren't available.** Headless Claude Code does **not**
    inherit Cowork's OAuth connectors (Gmail, Calendar, Slack, Notion, Drive).
    The filesystem and local MCP servers work. To use cloud connectors, register
    them in the project's `.mcp.json`. (See `bridge/README.md`.)

---

## Development

- **Bridge:** `cd bridge && cargo build --release` (and `cargo test`, `cargo clippy
  -- -D warnings`). A clean release build is the gate.
- **App:** `xcodebuild build` / `xcodebuild test` with the `Jesse` scheme. Keep the
  test suite green and the build warning-free.
- See `STATUS.md` for the running log of what was built, tested, and decided.
