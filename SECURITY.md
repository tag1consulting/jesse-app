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

- **Concurrency** — `JESSE_MAX_CONCURRENCY` (default 2) caps in-flight turns; a
  request that can't get a permit immediately gets `429`, never an unbounded
  queue.
- **Rate** — `JESSE_RATE_PER_MIN` (default 30) caps accepted requests per
  rolling minute; bursts beyond it get `429`.
- **Timeout ceiling** — every turn is bounded by `HARD_TIMEOUT_CEILING` (3600s).
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
