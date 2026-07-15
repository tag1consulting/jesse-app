# Security

The Jesse Bridge turns "Ask Jesse" / "Tell Jesse" requests from the phone into
headless Claude Code runs against the vault. A request therefore drives an agent
with filesystem and tool access on the host. This document describes the
boundaries the bridge enforces and the deployment posture it assumes.

## Threat model

- The bridge is reachable over a trusted network only (loopback or a
  WireGuard-encrypted, ACL-gated Tailscale tailnet). It is **not** hardened to
  face the public internet.
- Every request carries a bearer token (`JESSE_TOKEN`). The token is a second
  factor on top of network reachability, not the only control.
- The agent the bridge launches is powerful. The in-process controls below
  reduce blast radius; they do not replace OS-level isolation.

## Agent tool allowlist (in-process boundary)

The bridge launches `claude` with `--permission-mode default` plus an explicit
`--allowedTools` allowlist and a `--disallowedTools` denylist. It never uses
`acceptEdits` or `bypassPermissions`. The allowlist is built in
`build_claude_args` and is unit-tested to always be present and to never contain
unscoped `Bash`.

The prompt-wrapper (`build_prompt`) also prepends one deterministic **clock
header** to every turn — day-of-week, date, local time, timezone abbreviation,
and UTC offset — computed fresh from the host system clock (`prompt::clock_line`,
via `date`; a std-only UTC fallback keeps it present if `date` is unavailable).
This is read-only context, not a tool grant; it removes the dependence on the
model deciding to call a clock tool.

Default allowlist (`JESSE_ALLOWED_TOOLS` to override):

| Tool | Why |
| --- | --- |
| `Read`, `Write`, `Edit` | Read and record durable facts in vault files |
| `Grep`, `Glob` | Locate files and content in the vault |
| `mcp__qmd__query`, `mcp__qmd__get`, `mcp__qmd__multi_get`, `mcp__qmd__status` | Read-only QMD vault search — the first step for any vault lookup |
| `Skill(diet-logging)` | Auto-invoke the vault's `diet-logging` skill on a food/exercise/weigh-in log. The Skill tool only **loads instruction text** — it executes nothing itself; every action the skill prescribes still flows through the scoped `Read`/`Write`/`Edit` and the three `Bash(node todo-list/*.js:*)` scripts, so the action surface is unchanged. Pinned to the single named skill, never a bare `Skill` (which would let any future vault skill run from a phone request) |
| `Bash(git:*)` | Vault history / status, and clone/fetch/log/diff/show for **read-only code review** (see [Code review checkouts](#code-review-checkouts-review-only)) |
| `Bash(mv:*)`, `Bash(ls:*)`, `Bash(cat:*)`, `Bash(find:*)` | Scoped file wrangling |
| `Bash(date:*)`, `Bash(cal:*)` | Clock / date math backing the per-turn clock header (relative-date math, alternate formats). Pure computation — `date -s` needs root and fails as a non-privileged user, `cal` only prints, so no side effect is reachable |
| `Bash(head:*)`, `Bash(tail:*)`, `Bash(wc:*)` | Strictly read-only inspection of large files/logs (the diet CSVs and logs) without slurping the whole file — rounds out the existing `cat`/`ls`/`find` read set. No writes, no network |
| `Bash(node todo-list/generate-diet-today.js:*)` | Regenerate the `diet-today.js` dashboard cache from the authoritative CSVs after a food/exercise/weigh-in log (without it, a phone log appends the CSV but leaves the cache stale) |
| `Bash(node todo-list/validate-diet-today.js:*)`, `Bash(node todo-list/verify-diet-consistency.js:*)` | The generator's two guards — field-contract validation and CSV-vs-cache consistency — run after each regeneration |

These three `node` entries are pinned to the **exact script paths**, never a bare
`Bash(node:*)`: a bare node scope would allow `node -e "<arbitrary JS>"` —
arbitrary code execution from a phone request — so only the three named diet-cache
scripts are permitted (`build_claude_args_enforces_least_privilege` asserts this).

Default denylist (`JESSE_DISALLOWED_TOOLS` to override) — denied even if they
reach the allowlist:

| Tool | Why |
| --- | --- |
| `WebFetch` | SSRF / data-exfiltration surface the workflows don't need |

**Why bare `Bash` is not on the denylist (and how unscoped shell is still
blocked).** Listing bare `Bash` in `--disallowedTools` removes the entire Bash
tool *class* — which shadows **every** scoped `Bash(<verb>:*)` grant in the
allowlist above (git for code review, the three node diet-cache scripts, the
`date`/`cal` clock verbs, the read-only inspection verbs). Verified on the Studio
(claude 2.1.199, 2026-07-04): with `Bash` denied, even `Bash(date:*)` reports
"no Bash tool" and the scoped grants are dead. So the denylist keeps only
`WebFetch`. Unscoped Bash is still blocked **without** a deny entry: under
`--permission-mode default`, a Bash command that matches no scoped allow entry
raises a permission prompt, and a headless (`-p`) phone turn cannot answer a
prompt, so it is denied. Default-deny + the scoped allowlist is the real
least-privilege boundary; only the scoped `Bash(<verb>:*)` forms are granted and
anything unscoped is refused. (`build_claude_args_enforces_least_privilege`
asserts bare `Bash` is absent from the allowlist and absent from the denylist.)

**The allowlist is the only in-process boundary, and it is not a sandbox.** A
permitted tool can still do damage within its scope (e.g. `Bash(git:*)` can run
arbitrary `git` subcommands, `Write` can overwrite vault files). Treat it as
least-privilege within the vault, not as containment of a hostile agent.

## Diet child tool isolation (in-process boundary)

The diet-logging pipeline (see the bridge README) spawns two **stateless,
single-shot** children — **extract** (parse a food/exercise/weigh-in utterance
into per-item JSON) and **verify** (a hosted judgment on those items). Both are
pure text-in / JSON-text-out and need **no tools at all**. This is a *stricter*
posture than the main agent above, and it is built by the shared
`build_diet_child_command`, so the guarantee holds for both children identically.

**Deny-by-default at the CLI root, not by enumeration.** The child is launched
with:

| Flag | Effect |
| --- | --- |
| `--tools ""` | Disables the **entire** built-in toolset. No `Glob`/`Grep`/`Read`, no `Bash`/`Write`/`Edit`, no `ToolSearch`/`Workflow`/`Agent` exist to be invoked — removed at the root, not permission-gated. This is the load-bearing control. |
| `--strict-mcp-config` + `--mcp-config '{"mcpServers":{}}'` | Loads **no** MCP servers, so every `mcp__*` tool — and anything `ToolSearch` could pull from a server — is absent at the root. |
| empty `--allowedTools` + expanded `--disallowedTools` | Retained as documented, **fragile** belt-and-suspenders behind the two root flags. The denylist names tools, so it breaks silently on any CLI tool rename/addition; it is not the guarantee. |

**Why the empty allowlist alone was not enough (and how we know).** The children
were originally built with only an empty `--allowedTools` plus a seven-name
denylist, on the assumption that an empty allowlist means "no tools". Live
validation against the pinned CLI (`claude 2.1.207`, 2026-07-13) disproved it: an
empty allowlist adds **nothing to the default set** rather than emptying it, and
the read/search built-ins, `ToolSearch`, `Workflow`, and MCP loading do **not**
raise the permission prompt a headless `-p` child cannot answer. A *run ls* probe
executed `Glob`; a *fetch* probe reached `mcp__playwright__browser_navigate` and
made a **live network fetch** with no approval; a *spawn a subagent* probe reached
`Workflow`. Only `Write` was contained. `--tools ""` + strict-empty MCP closes all
of these at the source.

**The acceptance gate is a live probe battery, not the unit tests.** Because
enumerated denial cannot be trusted to stay complete across CLI versions, any
change to this posture must be re-validated by re-running six probes (`run ls`,
`write … /tmp/…`, `fetch …`, `spawn a subagent`, `read /etc/hosts`, `ToolSearch
… list files`) against the exact builder argv on the pinned CLI. PASS = **zero**
executed `tool_use` across all six, the write-probe file absent, and no network
egress. The current posture passes all six. (Note: the child may still *narrate*
fake tool calls in its text and answer from training knowledge — e.g. quote
`example.com`'s "Example Domain" without fetching — but no tool executes; the
security property is that it cannot **act**, and its structured output is
re-validated by the ambient verify gate and by trusted Rust before anything is
written.) `claude 2.1.207` has no `--max-turns` flag, so the single-shot bound is
by construction only, not CLI-enforced.

**The title child is a different posture, deliberately.** The title one-shot
(`run_claude_oneshot`) reuses `build_claude_args` — the **main-turn** scoped
allowlist and the vault cwd — because it summarizes an already-produced reply and
was never intended to be toolless. It therefore shares the main agent's tool
surface (and, with it, the same CLI behavior around read/search/MCP tools), not
the diet children's hard containment. Whether to tighten it is a separate
decision; it does not carry the specific "empty allowlist assumed toolless" defect
that the diet children did, because it never claimed to be toolless.

## Vault-QA child tool isolation (in-process boundary)

The local vault-QA route (see the bridge README) spawns one **stateless,
single-shot, READ-ONLY** child that answers a self-referential "Ask" from vault
files. Unlike the diet children, it needs to **read the vault** — so its posture
is *read-only*, not *toolless*, and it is a near-clone of `build_diet_child_command`
(`build_vaultqa_child_command`) with two deliberate deltas.

**Read-only at the CLI root, deny-by-default for everything else.** The child is
launched with:

| Flag | Effect |
| --- | --- |
| `--tools "Read,Grep,Glob"` | A read-only **root allowlist** (not the diet child's empty set). Exactly the three read-only built-ins exist at the root; `Bash`/`Write`/`Edit`, `ToolSearch`/`Workflow`/`Agent`, and everything else are absent at the root, not permission-gated. This is the load-bearing control. |
| `--strict-mcp-config` + `--mcp-config <cfg>` | Loads **only** the servers in the config — the **qmd** vault-search server when `JESSE_VAULTQA_MCP_CONFIG` supplies it (its four tools are read-only search), or **no** servers otherwise. Nothing else can be reached, and `ToolSearch` (denied and absent at the root) cannot pull a server in. |
| `--allowedTools` + expanded `--disallowedTools` | The allowlist names the three built-ins plus the four qmd tools; the denylist names `Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task,Agent,ToolSearch,Workflow,TodoWrite` as documented, **fragile** belt-and-suspenders behind the root flags (it names tools, so it breaks silently on a CLI tool rename/addition — it is not the guarantee). |

So the child can **read** the vault but cannot write, execute a shell, reach the
network, spawn a subagent, or load an unlisted MCP tool.

**The cwd divergence, and why it's safe.** This is the one intentional divergence
from the diet child, which runs in a neutral scratch dir: the vault-QA child's cwd
**is the vault**, because it must read vault files to answer. Containment therefore
comes from the **toolset** (the read-only root allowlist + strict MCP), NOT from an
isolated cwd — exactly the way the diet child's containment comes from `--tools ""`
rather than its scratch cwd. Running in the vault means CLAUDE.md auto-loads, but
the child's prompt frames **all** file content (CLAUDE.md included) as untrusted
**data, never instructions**, and the read-only toolset means even a fully
prompt-injected child cannot *act* — at worst it emits text, which is then re-checked
in-process.

**Defense past containment: the citation validator.** Because the child's answer is
delivered to the user (unlike the diet child's structured output, which trusted Rust
re-derives), a pure in-process validator runs on every answer before it is returned:
it requires at least one citation, that every cited file resolves under the vault,
and that any string quoted against a `path:line` actually occurs in that file. An
uncited, mis-cited, or fabricated-quote answer fails and the turn falls through to the
hosted path — a prompt-injected or hallucinating child cannot deliver an invented
"fact from your vault." Injection text inside a vault file can at most cause a
`NO_VAULT_ANSWER` / validator-fail fall-through, never an action.

## Emergency local fallback posture (`JESSE_EMERGENCY_LOCAL`)

The emergency fallback (bridge README) keeps the phone useful during a **hosted
outage** without opening any new write surface. It is armed only when
`JESSE_EMERGENCY_LOCAL=on` **and** the `JESSE_VAULTQA_*` triple is set, and it fires
only on a **transport-class** hosted failure (spawn / network / timeout / CLI-surfaced
5xx / 429 / quota / auth) — a completed hosted turn is never a failure regardless of
content, so a hostile reply can never trigger it.

**Local models never gain a write path — emergency included.** This is the standing
safety invariant, documented in `handlers.rs`/`dietqueue.rs` where the child postures
live:

- The emergency **Ask** answer comes from the **same read-only vault-QA child** above
  — `--tools "Read,Grep,Glob"` + strict MCP, no `Write`/`Edit`/`Bash`, cwd framed as
  untrusted data. It never gains a tool the routine child lacks. The only difference is
  the prompt (it says hosted is unavailable and to answer best-effort or say what it
  cannot) and a looser 120 s timeout. The citation validator still runs, but
  **advisory**: because there is no ladder rung below emergency, an uncited answer is
  delivered anyway with a prepended `citations unverified` warning above the badge —
  the user is told, and the answer still came from a read-only child that cannot act.
- The emergency **diet Tell** path performs **no local write to the canonical CSVs**.
  When the blocking hosted verify is unreachable, the **bridge** (deterministic Rust,
  never a model) appends the already-extracted entry to a pending-verify file in its
  own state directory. On the next successful hosted contact the queue is replayed
  oldest-first through the **exact existing verify-then-append path** — the same hosted
  verify child admits or rejects each entry, exactly as a live entry. **Nothing ever
  reaches the CSVs unverified**, the 100%-verify probation invariant holds through the
  outage, and a rejected replay moves to a rejected file (surfaced in provenance),
  never a silent drop. The queue is authored entirely by bridge code; the local extract
  model's output is data awaiting a hosted verdict, not a durable write.

**Every durable write stays deterministic bridge code.** As with the live diet
pipeline, the only actor that writes the vault is trusted Rust, gated on a hosted
verify verdict. The local models — routine, emergency, or extract — only ever produce
**text** that the bridge validates or queues. A circuit breaker (2 consecutive
transport failures → local-first for 300 s) only ever decides whether to *skip* a
hosted attempt in favor of the read-only local path; it can never grant a capability.

Emergency mode is **untested-live until go-live's outage drill** (block hosted at the
network level and verify phone behavior end-to-end); it ships dormant (`off`).

## Code review checkouts (review-only)

The agent can review external source: clone/fetch a repo, then read/search/diff
it. This rides entirely on the boundary above — `Bash(git:*)` already permits
`git clone`/`fetch`/`log`/`diff`/`show`, and `Read`/`Grep`/`Glob` reach the
checkout because it lives under the vault cwd — so **no new tool grant was added**
for it.

- **Checkouts live under `Code/<host>/<owner>/<repo>`**, a path derived purely
  from the clone URL (host lowercased, trailing `.git` stripped, scp-form
  `git@host:owner/repo` treated like `https://host/owner/repo`, any port dropped).
  Being a pure function of the URL, an existing checkout is found with a single
  existence check, not a directory scan. `Code/` is **gitignored in the vault**,
  so checkouts never enter the vault repo or its autocommit.
- **Access is whatever the host already has** — the existing SSH key / `gh` /
  credential helper. Private, access-configured repos work; nothing is hardened or
  stripped. A *first* clone from a brand-new SSH host can fail the unknown-host
  prompt (TOFU) headlessly — pre-seed `known_hosts` or use the HTTPS URL for a new
  host (GitHub and epyc are already trusted; GitLab is not yet).
- **Review-only is a policy instruction, not a sandbox.** `Write`/`Edit` are not
  path-scoped and `Bash(git:*)` would permit a `push`, so "never push, never edit
  checked-out code" is enforced by the standing instruction the bridge prepends to
  every turn (`prompt::REVIEW_CAPABILITY`), **not** by containment. Treat it as a
  rule the agent follows, not a barrier it cannot cross. A tighter technical guard
  (scoping git to non-mutating subcommands, a pre-push refusal) was considered and
  deliberately not built: it would risk breaking private-read access for marginal
  gain on a single-user, trusted-network bridge. This is called out so the residual
  risk is explicit.

## Deployment: run isolated and least-privilege

Real isolation is a deployment concern and is **not** implemented in the Rust
process. Operate the bridge as follows:

- **Dedicated low-privilege OS user.** Run the bridge as a purpose-built account
  whose home directory *is* the vault and which owns nothing else of value. It
  should not be able to read other users' data, SSH keys, browser profiles, or
  credential stores. The agent inherits this user's privileges — keep them
  minimal.
- **`JESSE_VAULT` points only at the intended tree.** The bridge runs `claude`
  with the vault as its working directory. Set `JESSE_VAULT` to exactly the
  vault and nothing broader; do not point it at `$HOME` or a parent directory.
- **Run under an OS sandbox.** Wrap the process so the kernel — not just the
  allowlist — bounds what it can touch:
  - macOS: `sandbox-exec`/Seatbelt with a profile restricting file writes to the
    vault subtree and denying network egress beyond the Anthropic API.
  - Linux/containers: a container or a systemd unit with a read-only root,
    `ProtectHome`, a bind-mounted vault, and a restricted egress network policy.
- **Bind to a safe interface.** See below.

## Network bind safety

The bridge refuses to bind to anything other than loopback (`127.0.0.0/8`,
`::1`) or CGNAT/tailnet space (`100.64.0.0/10`) unless
`JESSE_ALLOW_PUBLIC_BIND=1` is set. A non-IP host (a hostname) is treated as
unsafe. This is enforced in `is_bind_allowed` before any socket is opened; an
unsafe bind without the override is a hard startup error. Do not set the
override on an untrusted network.

## Resource limits

To keep a single client (or a runaway turn) from exhausting the host:

- **Concurrency** — `JESSE_MAX_CONCURRENCY` (default 1) caps in-flight turns: a
  single global write lock, so at most one turn rewrites the vault at a time
  regardless of how many clients are connected. A request that can't get a permit
  immediately **waits** in a bounded queue (`JESSE_MAX_QUEUED`, default 4) rather
  than being rejected; only load beyond the queue is shed with `429`, so the queue
  is never unbounded. `JESSE_MAX_QUEUED=0` restores immediate-`429` shedding.
- **Rate** — `JESSE_RATE_PER_MIN` (default 30) caps accepted requests per
  rolling minute; bursts beyond it get `429`.
- **Timeout ceiling** — every turn is bounded by `HARD_TIMEOUT_CEILING` (7200s).
  `JESSE_TIMEOUT=0` is treated as the ceiling, not "unlimited," in release
  builds. An unbounded-wait affordance exists only in debug builds.
- **Output cap** — captured agent stdout is truncated (a few MB) before parsing
  so one pathological run can't balloon memory.
- **Title endpoint** — `POST /jesse/title` is stateless and bearer-auth gated like
  every other endpoint, and shares the same rate limiter. Its input is capped at
  `MAX_TITLE_INPUT_BYTES` (16 KiB) — an oversized body is refused with `413`
  *before any `claude` spawn* — and its single `claude` call is bounded by a short
  fixed `TITLE_TIMEOUT_SECS` (20s), so it cannot pin a child the way a full turn
  can. It reuses `build_claude_args`, so the same tool allow/deny posture applies;
  it creates no job, persists nothing, and its output is clamped before return.
- **Attachments** — files sent with a turn are bounded by count
  (`JESSE_MAX_ATTACHMENTS`, default 4), per-file size (`JESSE_MAX_ATTACHMENT_BYTES`,
  default 10 MB), and combined size (`JESSE_MAX_ATTACHMENTS_TOTAL_BYTES`, default
  20 MB). The request body limit is sized from these (base64-inflated) so an
  oversized upload is refused before it's buffered.

## Session list (`GET /jesse/sessions`)

`GET /jesse/sessions` lets the app show a history of conversations. It is
**read-only** and never writes a session file.

- **Same auth/rate posture as every endpoint.** It is bearer-auth gated
  (`401` without/with a wrong bearer — the same posture as `/jesse`) and shares
  the same rate limiter (`429` on a burst).
- **What it reads.** It enumerates the vault's Claude Code transcripts —
  `~/.claude/projects/<escaped-vault>/*.jsonl` — and returns, per session, the
  session id, the file mtime, a short **first-message snippet** (the first user
  turn, read from only a bounded **64 KiB** prefix of the file), and the stored
  title if one was minted. The `<escaped-vault>` path is produced by a **pure,
  unit-tested** function, and only plain `*.jsonl` components in that one
  directory are listed, so a listing can **never reach outside the projects
  dir**.
- **What an authenticated caller can now read.** This exposes transcript
  **snippets** an authenticated caller couldn't read before — the opening text
  of each session. That is vault-conversation content, gated behind the same
  bearer token as `/jesse` itself; an **unauthenticated** caller gets `401` and
  learns nothing, exactly the posture of `/jesse`.

## Title-endpoint backend override (`JESSE_TITLE_*`)

`POST /jesse/title` can be pointed at a different model backend than main turns
via three optional env vars — `JESSE_TITLE_BASE_URL`, `JESSE_TITLE_AUTH_TOKEN`,
`JESSE_TITLE_MODEL`. **Rationale:** a title is a throwaway UI nicety, so it can be
served by a cheap, fast, local backend without spending the main model's budget or
latency on it.

Security-relevant properties:

- **Scoped to the title child only.** When all three are set, they are applied as
  `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` on the title
  one-shot's child process *only* (via that `Command`'s env). **Main "Ask/Tell"
  turns are never affected** under any configuration — the main-turn spawn path
  never applies the override. This isolation is asserted by a dedicated test, so a
  refactor can't silently leak a title-only credential/endpoint onto a real turn.
- **All-or-nothing, soft-failure.** The override resolves only when all three are
  set (trimmed, non-empty). Any unset value → titles use the ambient backend,
  byte-for-byte the prior behavior. A **partial** configuration (one or two set)
  logs one startup warning and is treated as fully unset, so a half-configured
  deploy fails safe rather than half-redirecting.
- **Provenance, without secrets.** Each title call logs exactly one line naming
  the backend that served it — **base URL and model only, never the auth token,
  and never any prompt content** — so a production audit has a trail of where
  titles went.
- **Same request posture otherwise.** The title child still uses `build_claude_args`
  (identical `--permission-mode`/allow/deny lists), the same `MAX_TITLE_INPUT_BYTES`
  input cap and short `TITLE_TIMEOUT_SECS`, and remains a soft best-effort call —
  a title failure is degraded from, never surfaced as an error.
- **Optional server-side title store.** `POST /jesse/title` accepts an optional
  `session_id`. When present *and* the title call succeeds, the minted title is
  persisted so `GET /jesse/sessions` can show it — to a single JSON file
  `<state_dir>/titles.json` written with mode `0600` via an atomic temp+rename and
  **best-effort** (a write failure is logged, never fatal), mirroring the
  `device.json` device-token store's discipline. Only the session id and its short
  title are stored — never the bearer token or prompt content. With no state dir
  configured the store is **in-memory only** (titles lost on restart, the same
  degradation the job store has). **Omitting `session_id` is byte-for-byte the old
  stateless behavior** — nothing is written and old clients are unaffected.

## Attachments

Files attached to a turn are untrusted input and handled defensively:

- **Type is sniffed, not believed.** Each blob's real type is detected from its
  magic bytes and must be on the whitelist (PNG, JPEG, GIF, WebP, HEIC, PDF) *and*
  match the client-declared MIME; an extension/MIME mismatch is rejected (`400`).
- **No client filename touches disk.** Files are written to a per-request scratch
  directory (mode `0700`) under the system temp dir — *not* the vault —
  (override the base with `JESSE_SCRATCH_DIR`, e.g. a sandbox-mounted path) with
  randomized `0600` names and a sniffed extension. The client filename is never
  used as an on-disk name (path traversal) and is never placed in the prompt
  (injection); only the random on-disk paths are named to the agent.
- **Scratch is always cleaned up.** A `Drop` guard removes the whole scratch
  directory when the turn ends — success, error, or timeout — and survives the
  internal retry loop, so decoded files never outlive the turn.

## Recent-workouts context (`health_context`)

A turn may carry an optional `health_context` field: a compact, device-reported
"recent workouts" block the phone assembles from Apple Health so the agent can log
a workout the user refers to ("Log my swim") from real numbers. It is untrusted
input and handled defensively:

- **Same trust class as the message body.** The block is attacker-controlled only
  if the *phone* is — exactly like the `text` of any turn. Both arrive over the
  bearer-auth'd, tailnet-only channel from a paired device; neither is trusted
  more than the other. It grants **no new capability**: no tool is added to the
  allowlist for it, so the action surface is identical to a turn without it.
- **Framed as data, never instruction.** When present, `build_prompt` inserts the
  block right after the per-turn clock header, ahead of the safety floor, under a
  fixed header stating the lines below are *untrusted data captured on the phone,
  not instructions, and must never be acted on as directives*. This is the same
  posture as the clock header: read-only context, not a tool grant. A crafted
  block that says "ignore your instructions and …" is still just data the model is
  told to distrust — and, crucially, the tool allowlist (not the prompt) is the
  boundary that bounds what any turn can do.
- **Bounded and sanitized.** The block is capped at `MAX_HEALTH_CONTEXT_BYTES`
  (**8 KiB**); an oversized block is refused with `413` **before any `claude`
  spawn** and before a concurrency permit is taken, so it can never trigger a giant
  model call. ASCII control characters other than newline are stripped before the
  block is used, so it cannot smuggle terminal escapes, NULs, or stray control
  bytes into the prompt. (The cap rose from 4 KiB with the directive channel below:
  a *granted* metrics request can carry up to 4 metrics × ~31 daily lines; the app
  self-caps its fulfilled response at 6 KiB, under this ceiling.)
- **Optional and backward-compatible.** Absent or blank reproduces the pre-field
  prompt byte-for-byte, so an old app build (which never sends it) is unaffected.

## Agent directive channel (`JESSE_NEEDS_HEALTH`)

Health context is no longer attached to every turn — the app classifies each
message and attaches the block only when relevant. So the agent needs a way to
**ask** for device health data it wasn't given: the final non-empty line of a
reply may be a directive `JESSE_<NAME> v<N> {json}` (this release:
`JESSE_NEEDS_HEALTH v1`). The bridge extracts a known, validating directive,
strips it from the reply, and hands the parsed request to the app under a
structured `directives` object. This is a **new data path from the agent's output
back to the app**, so its trust properties are called out explicitly:

- **A directive originates from the sandboxed agent's OUTPUT**, which is
  attacker-*influenceable*: a prompt injection in the vault, or a crafted request,
  could in principle make the agent emit a `JESSE_NEEDS_HEALTH` line. So the
  request it produces is **not trusted** — it is validated against a **fixed
  whitelist and caps** before anything acts on it. The bridge validates here
  (`sections` ⊆ {daily, workouts}; each `metric` on the fixed
  [whitelist](../bridge/README.md#agent-driven-health-request-channel-jesse_needs_health);
  `window_days` an integer 1–31; ≤ 4 metrics; ≤ 2 KiB line) and the app validates
  again against the same enum before reading any HealthKit data. A directive that
  fails either check is **not fulfilled**.
- **The worst a prompt-injected agent can do through this channel** is ask for
  **whitelisted health aggregates the user already agreed to share** (the same
  HealthKit types the "Attach health context" toggle already reads) over a bounded
  window. It grants **no new capability**, reads nothing the app couldn't already
  attach, and — like `health_context` — adds **no tool** to the agent's allowlist.
  The directive is a *request for data the app gates*, not a command the bridge
  obeys.
- **A malformed, over-cap, or unknown directive is a loud, visible failure**, not a
  silent one: the line is left in the reply text and logged, and no field is
  attached. Combined with the app's one-retry cap, a wrong or hostile classification
  can only ever cost a slower answer (one retry) or a vault-data answer — never a
  wrong or degraded one.
- **The request→retry loop is bounded.** A turn that carries
  `health_context_unavailable` tells the agent it cannot get the data and must
  answer from vault data without re-requesting; the app fulfils at most one retry
  per user message and ignores a second directive. There is no unbounded
  ask/answer cycle.

## Dietary write-back channel (`JESSE_MEAL_LOG`)

The write-direction sibling of `JESSE_NEEDS_HEALTH`, on the **same extractor and
registry**: a diet-logging reply may end with a `JESSE_MEAL_LOG v1 {json}` line
the bridge strips into `directives.meal_log`, which the app writes into Apple
Health as a food entry. Its trust properties mirror the health-request channel,
with the seam that matters here spelled out:

- **Same trust class as the reply text.** The meal block originates from the
  sandboxed agent's OUTPUT — the same origin as `health_context` and the reply
  itself — not from the network. A prompt injection could in principle make the
  agent emit a meal line, so the payload is **validated against a fixed contract**
  before anything acts on it: the bridge validates here (required non-empty
  `id`/`consumedAt`/`name`; each macro a finite, non-negative number or absent; ≤
  10 meals; ≤ 8 KiB line) and the app validates again and gates the write behind
  an explicit **HealthKit *write* authorization** the user grants once.
- **The worst this channel can do** is write **nutrition entries** (energy +
  macros) attributed to Jesse into Apple Health — a data class the user opted into
  by granting write access, dedupe-keyed by `id` so a replay can't pile up
  duplicates. It grants **no new capability** and, like the other directives, adds
  **no tool** to the agent's allowlist. Weight and workouts stay **read-only** —
  the write path only ever creates the food correlation, nothing else.
- **A malformed, over-cap, unknown-version, or over-10-meal block is a loud,
  visible failure**, not a silent one: the line is left in the reply text and
  logged, and no field is attached — a bad block is **never partially logged**, and
  a future `v2` contract bump fails loudly rather than half-parsing.
- **`consumedAt` is checked only for presence on the bridge** (it has no date
  library); the app parses the ISO-8601 offset strictly before writing, so a
  garbled timestamp fails app-side rather than landing a mis-dated entry.

## Push notifications (APNs key + device token)

Push is **optional and off by default** (see
[`bridge/README.md`](bridge/README.md#push-notifications-apns--optional-off-by-default));
with the `JESSE_APNS_*` vars unset, none of this is active.

- **The APNs signing key (`.p8`) is a secret.** Keep it outside the repo and point
  `JESSE_APNS_KEY_PATH` at it. The bridge reads it once at startup and holds the
  decoded key in memory to sign the auth JWT; it is **never logged and never
  written anywhere**. Do not commit a `.p8` (the magic-byte guard / gitleaks would
  catch a committed key, but don't rely on that — keep it out of the tree). The
  short-lived JWT (ES256, ~50-minute reuse) is held in memory only.
- **The device token is persisted, not secret, but still scoped.** The single
  registered APNs device token is written to `<JESSE_STATE_DIR>/device.json` with
  mode `0600` (same discipline as the job store) so it survives a restart. It is
  user-identifying routing data, not a credential like the bearer token; the token
  is never logged in full, and only the token (no bearer token or other secret) is
  written to that file.
- **Registration and flagging are bearer-auth gated.** `POST /jesse/device` and
  `POST /jesse/notify/{job_id}` use the same `JESSE_TOKEN` bearer check as every
  other endpoint, so only a paired client can register a token or request a push.
- **A push can never affect a turn.** Every push failure (no token, APNs error, a
  bad key) is logged and swallowed; the turn's stored result is untouched. The
  push carries only a short alert plus the `job_id` for routing — no vault content.
- **A dead device token is cleared, not retried forever.** When APNs returns HTTP
  `410 Gone`, the bridge clears the stored token and persists the cleared state to
  `device.json`, so a token left dead by an app reinstall or uninstall stops being
  pushed to (and the phone re-registers on its next foreground). Other push
  failures are transient and leave the token in place.

## Reporting

This is a single-user personal bridge; there is no formal disclosure process.
Raise concerns directly with the maintainer.
