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

## Make Jesse yours

A fresh clone is fully generic: with no configuration the assistant addresses
"the user", the vault defaults to `~/vault`, and the diet-intent gate uses an
English-only vocabulary. **All personalization is runtime data in gitignored
files — never an edit to tracked source — so `git push` can never leak it.**

Every local file has a committed `*.example` twin; copy it and edit the copy:

1. **Name, pronoun, languages, vocabulary** — copy the persona template and edit
   your copy:
   ```bash
   cp jesse.example.toml jesse.local.toml
   # set owner_name, owner_pronoun, languages, and any diet_keywords_extra
   ```
   The bridge reads `jesse.local.toml` last, over the built-in defaults;
   environment variables (`JESSE_OWNER_NAME`, `JESSE_OWNER_PRONOUN`,
   `JESSE_LANGUAGES`, `JESSE_DIET_KEYWORDS_EXTRA`) override the file. It is found
   (first that exists wins) at `$JESSE_CONFIG`, then `./jesse.local.toml`, then
   `<state-dir>/jesse.local.toml` (`$JESSE_STATE_DIR`, else `$HOME/.jesse-bridge`) —
   the last is the reliable spot for a launchd-managed service whose working
   directory isn't the repo.

2. **Point at your vault** — `export JESSE_VAULT=/path/to/your/vault` (defaults to
   `~/vault`).

3. **Local CI-guard denylist (optional)** — to have the pre-push checks catch your
   real name/hostnames/IPs if they ever slip into a tracked file:
   ```bash
   cp scripts/ci-guards.local.sh.example scripts/ci-guards.local.sh
   # add your real identifiers to EXTRA_DENY
   ```
   `scripts/ci-guards.sh` sources it when present. Org CI won't have the file —
   that's expected; the generic guard still runs everywhere.

4. **Your own eval suite (optional)** — copy the generic template into `local/` and
   pin it to your real vault:
   ```bash
   cp eval/suites/vaultqa-example.json eval/suites/local/vaultqa-mine.json
   ```
   See [`eval/suites/README.md`](eval/suites/README.md).

Every instance path above — `jesse.local.toml`, `scripts/ci-guards.local.sh`, and
everything under `eval/suites/local/` — is **gitignored by design**, so personal
data can't be committed or pushed. The bridge's own persona config is documented
in [`bridge/README.md`](bridge/README.md).

---

## Repository layout

| Path | What |
|---|---|
| `bridge/` | Rust bridge service. See [`bridge/README.md`](bridge/README.md) for the full HTTP contract, endpoints, and env knobs. |
| `Jesse/` | Xcode project for the iOS app (`Jesse` app target + `JesseTests`). |

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
  (file read/write/search **path-scoped to the vault**, read-only vault search,
  and scoped `git`/`mv`/`ls`/`cat`/`find`), with unscoped shell denied. Read-only
  web access (`WebSearch`, `WebFetch`) and read-only Slack are granted; `WebFetch`
  was denied until bridge 0.57.0 and the risk of releasing it is recorded in
  [SECURITY.md](SECURITY.md). The path scope is checked by a live probe battery rather than assumed:
  a child cannot read or write outside the vault, while the `git` scope's
  network reach is a known-open finding recorded in `bridge/containment.toml`.
  It can read and modify files in the vault ("Tell Jesse" is how capture works). Point
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
  can't exhaust the host: `JESSE_MAX_CONCURRENCY` (default 1 — a single global
  write lock, so one turn rewrites the vault at a time), `JESSE_RATE_PER_MIN`
  (default 30), and a hard 7200s timeout ceiling. A turn that can't get a permit
  is **queued** (up to `JESSE_MAX_QUEUED`, default 4); only load beyond the queue
  is shed with `429`. Set `JESSE_MAX_QUEUED=0` to restore immediate-`429`
  shedding.
- **The token is never written to the bridge's request logs**, and it is stored
  on the phone in the **iOS Keychain** (not plaintext `UserDefaults`). One
  caveat, closed in bridge 0.77.0: before that version the startup pairing QR —
  which encodes the token — was printed to stdout unconditionally, so any
  log-collected stdout (a container, launchd's `StandardOutPath`, `| tee`)
  captured it on every restart. The QR is now printed only when stdout is a
  terminal. **If your logs ever captured the QR, rotate `JESSE_TOKEN`.**

### Do not commit or share secrets

- **Never put a real `JESSE_TOKEN` in a file you commit** — not in this README,
  scripts, CI, or any tracked file. Pass it through the environment at runtime
  (examples below generate a fresh one and never echo a literal).
- **The startup pairing QR contains the token.** Do not screenshot, paste, or
  screen-share that terminal output. Anyone who can read it can drive your vault.
  The plaintext `token=…` line is **hidden by default**, and since bridge 0.77.0
  the QR itself prints **only when stdout is a terminal**, so neither reaches a
  piped/collected stdout; pass `--show-token` or set `JESSE_SHOW_TOKEN=1` to also
  print the plaintext line (that output then contains the token), `--show-qr` /
  `JESSE_SHOW_QR=1` to force the QR onto a non-TTY stdout, or `JESSE_SHOW_QR=0`
  to pin the QR off even on a terminal (for a PTY that is still log-collected,
  e.g. `docker run -t`).
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

On startup in a terminal the bridge prints a **pairing QR** and a manual-entry
fallback. The plaintext token line is hidden by default:

```
█▀▀▀▀▀█  …  █▀▀▀▀▀█
…  (terminal QR)  …
Pair by scanning the QR above, or enter manually:
  host=<your-laptop>.<your-tailnet>.ts.net  port=8765
  (token hidden — it's encoded in the QR above; pass --show-token or set JESSE_SHOW_TOKEN=1 to also print it)
```

The QR encodes `jesse://pair?host=…&port=…&token=…`, so scanning still pairs
without the plaintext line. Run with `--show-token` (or `JESSE_SHOW_TOKEN=1`) to
print `token=<token>` for manual entry — but that output then contains your token,
so keep it on-screen only.

When stdout is **not** a terminal (a pipe, a container, a service manager) the
QR is suppressed, because there stdout is the log stream and the QR would write
the token into it on every restart — you get only the manual-entry lines, plus
a note on stderr naming the `--show-qr` / `JESSE_SHOW_QR` override. See the
`JESSE_SHOW_QR` row in [`bridge/README.md`](bridge/README.md#knobs-env-vars)
for the full tri-state behavior.

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
| `JESSE_VAULT` | `~/vault` | Working directory for `claude -p`. Must be an existing directory. |
| `JESSE_BIND` | `127.0.0.1` | Interface to bind. Set to the tailnet IP for phone access. Loopback/tailnet only unless `JESSE_ALLOW_PUBLIC_BIND=1`. |
| `JESSE_ALLOW_PUBLIC_BIND` | _(off)_ | Set to `1` to allow binding a non-loopback/non-tailnet address. Off by default; an unsafe bind is otherwise a startup error. |
| `JESSE_ALLOWED_TOOLS` | _(certified default)_ | Comma-separated `--allowedTools` list. **Cannot grant a tool** — the startup gate refuses any toolset the containment record does not cover, so this can only re-state or narrow the certified posture. Granting means editing `DEFAULT_ALLOWED_TOOLS` and re-running the battery. See [SECURITY.md](SECURITY.md). |
| `JESSE_DISALLOWED_TOOLS` | `NotebookEdit` | Comma-separated `--disallowedTools` denylist (defense-in-depth). Same gate applies as above. Bare `Bash` is deliberately absent — denying the class kills every scoped `Bash(<verb>:*)` grant. Never set it empty: a blank value is read as unset and silently restores the compiled default. See [SECURITY.md](SECURITY.md). |
| `JESSE_MAX_CONCURRENCY` | `1` | Max concurrent turns — a single global write lock by default, so one turn rewrites the vault at a time. A turn that can't get a permit is queued, not rejected. |
| `JESSE_MAX_QUEUED` | `4` | Depth of the wait queue in front of the concurrency limit; when no permit is free, up to this many turns wait for one, and only load beyond the queue returns `429`. `0` disables the queue (immediate `429`). |
| `JESSE_RATE_PER_MIN` | `30` | Accepted requests per rolling minute; bursts beyond it return `429`. |
| `JESSE_ADVERTISE_HOST` | value of `JESSE_BIND` | Host written into the pairing QR. **Set to your `ts.net` MagicDNS name** (see ATS note). |
| `JESSE_PORT` | `8765` | Port. |
| `JESSE_CLAUDE_BIN` | `claude` | Path to the `claude` binary. Use an absolute path if it isn't on the bridge's `PATH`. |
| `JESSE_TITLE_BASE_URL` | _(off)_ | With the two below, points **only** the `POST /jesse/title` one-shot at a different backend (e.g. a cheap local model) via that child's `ANTHROPIC_BASE_URL`. All three required together. |
| `JESSE_TITLE_AUTH_TOKEN` | _(off)_ | Auth token for the title backend (the title child's `ANTHROPIC_AUTH_TOKEN`). |
| `JESSE_TITLE_MODEL` | _(off)_ | Model id for the title backend (the title child's `ANTHROPIC_MODEL`). |
| `JESSE_DIET_BASE_URL` | _(off)_ | With the two below, enables the **local diet-logging pipeline**: a diet-shaped "Tell" (food/exercise/weigh-in) is parsed by a cheap local model (this backend) instead of a hosted agent turn, then verified, appended, and mirrored. All three required together. Unset → the pipeline is dormant and diet turns take the hosted path. |
| `JESSE_DIET_AUTH_TOKEN` | _(off)_ | Auth token for the diet-extract backend (the extract child's `ANTHROPIC_AUTH_TOKEN`). |
| `JESSE_DIET_MODEL` | _(off)_ | Model id for the diet-extract backend (the extract child's `ANTHROPIC_MODEL`). |
| `JESSE_DIET_PROBATION` | `true` | Probation mode: the hosted verify gate is mandatory and blocking on every extracted entry. Only an explicit falsey value disables it (a future graduation state, not used yet). |
| `JESSE_DIET_MICRO_COMPLETE` | `true` | Hosted micronutrient completion: the blocking verify call also fills the **blank** expected nutrient columns of a label-less whole food from food-composition values (blank-only merge, never overwriting a label, never writing `0` for a declined value). Only an explicit falsey value disables it — off is the old behavior that left knowable columns blank. Independent of `JESSE_DIET_PROBATION`: probation owns the verify gate, this owns completion. |

The three `JESSE_TITLE_*` vars are **all-or-nothing** and **soft**: set all three
to redirect titles only; leave any unset (the default) and titles use the ambient
backend, exactly as before. A partial set (one or two) logs a startup warning and
is ignored. **Main "Ask/Tell" turns are never affected** — the override touches
the title child alone.

The three `JESSE_DIET_*` vars are **all-or-nothing** the same way, and the **seam
is the kill switch**: with the triple unset (the default) the diet gate never fires,
so every "Tell" — diet-shaped or not — runs today's hosted agent turn *byte-for-byte*,
with no redeploy needed to disable the feature. When the triple is set, a diet-shaped
Tell runs the local pipeline: a **toolless** extract child (pointed only at this
backend) parses the utterance into per-item entries; a **hosted, ambient** verify
child (never this backend) checks every entry; trusted Rust appends the verified rows
to the vault's `diet-logs/*.csv`, runs the pinned regenerate/validate/verify scripts,
commits, and derives the `JESSE_MEAL_LOG v1` Apple-Health mirror from the appended
rows. Any failure at any stage falls back to the hosted turn (a log is never lost or
double-appended). **Main non-diet turns and the title child are never affected.**

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

(Adjust the simulator name to one your Xcode has installed.) To run everything CI
runs — JesseKit, iOS, watch and Mac, with the same flags and a resolved simulator
rather than a hardcoded name — use `scripts/local-ci-macos.sh` instead; see
[Development](#development).

Set `JESSE_MUTE=1` under the scheme's **Run > Environment Variables** to silence
spoken (text-to-speech) replies during development — no audio and no ducking of
other audio, without muting the Mac.

---

## 3. Pair the phone with the bridge

1. With the bridge running, open the app → **Settings** (gear) → **Scan to pair**.
2. Point the camera at the QR in the bridge's terminal. Host, port, and token
   fill in automatically. Tap **Save**.
3. Manual entry is the fallback: type the `host`, `port`, and `token` from the
   printed line into the Settings fields.

If the bridge is running a **sentinel**, its QR carries three extra keys
(`shost`, `sport`, `stoken`) and the same scan pairs both — the sentinel fields
appear under **Settings → Sentinel**, and you can fill them in by hand instead.
Those keys are **additive**: scanning a QR from a bridge with no sentinel pairs
the bridge and leaves a sentinel you already paired exactly where it is. A blank
sentinel is a supported state; everything except the Ops screen works the same
without one.

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
- **Cancel** — every turn runs on the laptop and the app polls (and streams) for
  the result by job id; the bridge hands that id back immediately. Cancel returns
  the thread to idle at once and discards the in-flight result.
- **Backgrounding** — a reply that finishes while the phone is in your pocket is
  **delivered then**, not when you next open the app. The bridge's push wakes Jesse
  for a few seconds, it fetches the reply and writes it into the conversation, and
  the notification you see on the lock screen is a notification about something
  that has already landed. Tapping it opens a thread that is already finished.
  Nothing is lost if the push never arrives — a periodic background refresh picks
  up anything still in flight, and reopening the app re-attaches exactly as before.
  The morning run's push also refreshes the day file and the health snapshot, so
  the Today tab is current the first time you look at it rather than after a spinner.
- **Voice / Siri** — "Ask Jesse…" and "Tell Jesse…" Siri phrases route into a new
  thread and read the reply aloud (on-device text-to-speech).
- **Ask about this (Health tab)** — long-press (iOS) or right-click (macOS) any card,
  row, chart or section on the Health tab and its sub-pages to open a chat that already
  holds exactly what was on screen: the meal and its foods, the nutrient row and what fed
  it, the trend and the point you were scrubbing. Each page also has an **Ask** button in
  its toolbar for the whole page ("what's good and what's bad about today?" works with
  nothing selected). The chat is the ordinary one; it opens on an empty composer and
  starts nothing until you send. Asking about the same thing twice in a day continues the
  same conversation. An ask never writes — no meal, weigh-in or workout is logged from
  one, and no routine is started.
- **Ops (Settings → Bridge ops)** — the laptop's health as cards with a green,
  amber, red, or grey dot: the bridge (version, latency, profile), the launchd
  services, Tailscale, disk and the artifact store, git (branch, ahead/behind,
  dirty, index lock, last autocommit), the QMD index, and the watchdog. Grey is
  **not** a shade of red — it means a probe did not finish, which is a different
  thing from a probe that failed. The actions below the cards each name the exact
  verb and launchd label before they run: restart the bridge, reload its
  environment, restart the autocommit / lock reaper / QMD index / dashboard
  server, unlock git, prune artifacts. A **Ledger** disclosure lists the last
  scheduler outcomes, and a **Deploy** card offers to build and swap in
  `origin/main` — enabled only when its commit differs from the running one *and*
  CI is green on that commit, then polling the phases with the build's log tail.
  The Ops screen needs a paired sentinel; without one it shows a single call to
  action explaining what a sentinel is.
- **Schedule (Ops → Schedule)** — every `[[schedule]]` entry grouped into its
  chain, the head first and its links indented beneath it. Each row carries the
  clock (or what it hangs off), the resolved days, the profiles it is in scope
  for, the next fire **in both your phone's zone and the bridge's**, the last
  outcome coloured, how long it took, a badge when it has failed several times
  running, and the output file it was contracted to produce. A toggle turns one
  job off — optionally until a date, which is the form to reach for, because a
  disabled job is silent and an override nobody remembers is a job that never
  runs again — and **Fire now** runs a chain immediately (refused while it is
  already running, with the bridge's own reason). **Reload config** re-reads the
  file, and entries the bridge rejected are listed in red at the bottom. The
  schedule is reachable with or without a sentinel: it is read from the bridge,
  and its two verbs go through the sentinel when one is paired and straight to
  the bridge when not.
- **Away mode (Settings → Away mode)** — tells the bridge you are somewhere else:
  a zone, a deadline (default a week out; the bridge refuses a period with no
  future end), and a short note that rides on every prompt. While it is in force
  the Chats list wears a thin "Away until …" banner and the Today header names
  the profile. **Back home** ends it early, which is also what runs the schedule's
  on-return job. Note that a period stays on record after it lapses, so the screen
  distinguishes "away until Sunday" from "was away until Sunday, and Sunday has
  passed".
- **Offline** — Today and Health keep the last thing the bridge sent them on disk,
  so both tabs still render after a cold launch with no network, behind a banner
  saying how old what you are reading is. Browsing works; **changing does not**.
  A checkbox, a move, a postpone, a Quick log, a Start new day or a Propagate is
  refused with a one-line notice, and **nothing is queued**: the day file is
  rewritten in full every morning, so a change held through an outage would replay
  against a document that has since moved on.

  Chats are the exception, and they now recover **by themselves**. Jesse watches the
  network, so the moment the phone is back on one it re-attaches to any turn still
  running on the laptop, re-sends anything waiting in the send outbox, and refreshes
  the two cached documents — no tab switch, no Re-check, no per-message Retry tap. A
  message that cannot be delivered is re-sent on a backoff (5s, 30s, 2min, 10min) and
  then, after five automatic tries, handed back to its per-message **Retry** button;
  re-sending is safe because every message carries an idempotency key the bridge
  dedups on, so a send that actually landed can never become two. Losing signal in
  the middle of a turn no longer ends in an error at all: Jesse waits for the network
  instead of blaming the laptop, because the turn is still running there regardless.
  **Re-check** is still on the screen — it is just no longer the only way back.

- **Frugal mode** — on cellular, and in Low Data Mode, Jesse spends fewer bytes: photos
  go out at 1280px, it checks for the reply less often, it reuses the health summary it
  already has rather than fetching a new one, and Settings stops re-polling the model
  list while it is open. A small leaf appears beside the composer's attach button while
  this is in force; tap it to see what is being saved and why. Nothing is ever refused —
  sending, replies, attachments and the day file all work exactly the same, they just
  cost less. **Settings → Data → "Frugal on cellular"** does the same on every network.

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
    The filesystem and local MCP servers work — Slack is reached this way, by a
    self-hosted read-only server rather than the connector. Adding another is a
    **code change, not configuration**: declare the server in
    `MAIN_CHILD_MCP_CONFIG`, add an `McpSet` variant so a battery row loads it,
    grant its tools in `DEFAULT_ALLOWED_TOOLS`, then re-run the containment
    battery and commit the record. Neither the project's `.mcp.json` (ignored —
    the main path passes `--strict-mcp-config`) nor the `JESSE_MAIN_MCP_CONFIG` /
    `JESSE_ALLOWED_TOOLS` environment overrides can grant a tool: the startup gate
    refuses to boot on any toolset the record does not cover. (See
    `bridge/README.md` and
    [`SECURITY.md`](SECURITY.md#mcp-servers-on-a-main-turn-strict-qmd--slack).)

---

## Development

- **Bridge:** `cd bridge && cargo build --release` (and `cargo test`, `cargo clippy
  -- -D warnings`, `cargo fmt --all --check`). A clean release build is the gate.
- **App:** run `scripts/local-ci-macos.sh` — see below.
- See `CHANGELOG.md` for the per-version record of what changed in each component.

### UI conventions

**Toolbar order.** On every screen the top-right toolbar is ordered by how often a
button gets used. The most-used action sits farthest right, closest to the thumb, and
less-used actions work inward toward the center. Frequency means expected taps per day
in normal use, not importance: a button that matters a lot but fires once a day is not a
frequent button. A heavy or hard-to-undo action never takes the rightmost slot even when
it is used often, because that slot is where a mis-tap lands, so it belongs to a cheap,
safe, repeatable action. The order is the same on iOS and macOS, and where one platform
has a button the other lacks, the remaining buttons keep their relative order. A new
toolbar button is inserted at its frequency position, never appended to whichever end is
convenient. In SwiftUI, declaration order within a `.toolbar` is left to right, so the
rightmost button is the one declared last.

### Where the checks run

The two halves of CI are gated in different places, on purpose.

| | Bridge (Rust) | App (Swift: JesseKit, iOS, watch, Mac) |
|---|---|---|
| Pre-merge gate | `ci.yml` on every PR (Linux) | `scripts/local-ci-macos.sh`, on **your Mac** |
| Enforced by | GitHub required check | the **pre-push hook** |
| Scheduled run | `audit.yml`, Mondays (CVEs) | `ios-ci.yml`, nightly against `main` |

GitHub's hosted macOS runners bill at **10x** the Linux rate, and the Swift job
is the expensive shape: four uncached `xcodebuild` builds and three booted
simulators. Running it per-PR was essentially this repo's entire Actions spend,
for a check that a Mac already on the desk runs for free. So it moved off the
per-PR path:

1. **Before pushing**, `scripts/local-ci-macos.sh` runs the same checks, in the
   same order, with the same flags: JesseKit `swift build`/`swift test`
   (warnings-as-errors), then iOS build + test, watch build + test, Mac build +
   test, then the "did every suite actually run a test?" assertion. It stops at
   the first failure and prints a PASS/FAIL summary.
2. **The pre-push hook runs it for you** and refuses the push on failure. Install
   once per clone: `scripts/install-hooks.sh`. It skips itself when the push
   touches neither `Jesse/` nor `JesseKit/`, so a bridge-only or docs-only push
   costs nothing.
3. **The nightly is the backstop, not the gate.** `ios-ci.yml` runs at 06:00 UTC
   against `main` and can also be dispatched by hand from the Actions tab. A
   cheap Linux `gate` job first asks whether any commit in the last 25 hours
   touched `Jesse/` or `JesseKit/`; if none did, the macOS runner never starts. A
   manual dispatch always runs regardless.

Escape hatches, both of which make the nightly your only verification:
`git push --no-verify` skips every pre-push check (including the version guard);
`JESSE_SKIP_MAC_CI=1 git push` skips only the Swift suite and keeps the version
guard. Use the second one when you already ran the script by hand.

**The trade this makes:** iOS breakage can reach `main` and sit there until the
next nightly. If that is ever unacceptable, the fix is a **self-hosted macOS
runner** (a Mac mini or spare Mac registered to the repo), which restores the
per-PR gate at zero GitHub minutes — not putting `pull_request:` back in
`ios-ci.yml`, which restores the bill along with it.
