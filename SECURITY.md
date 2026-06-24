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

Default allowlist (`JESSE_ALLOWED_TOOLS` to override):

| Tool | Why |
| --- | --- |
| `Read`, `Write`, `Edit` | Read and record durable facts in vault files |
| `Grep`, `Glob` | Locate files and content in the vault |
| `mcp__qmd__query`, `mcp__qmd__get`, `mcp__qmd__multi_get`, `mcp__qmd__status` | Read-only QMD vault search — the first step for any vault lookup |
| `Bash(git:*)` | Vault history / status |
| `Bash(mv:*)`, `Bash(ls:*)`, `Bash(cat:*)`, `Bash(find:*)` | Scoped file wrangling |

Default denylist (`JESSE_DISALLOWED_TOOLS` to override) — denied even if they
reach the allowlist:

| Tool | Why |
| --- | --- |
| `Bash` (unscoped) | Arbitrary shell execution |
| `WebFetch` | SSRF / data-exfiltration surface the workflows don't need |

Note that only the scoped `Bash(<verb>:*)` forms are granted; bare `Bash` is
both absent from the allowlist and explicitly denied.

**The allowlist is the only in-process boundary, and it is not a sandbox.** A
permitted tool can still do damage within its scope (e.g. `Bash(git:*)` can run
arbitrary `git` subcommands, `Write` can overwrite vault files). Treat it as
least-privilege within the vault, not as containment of a hostile agent.

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

## Reporting

This is a single-user personal bridge; there is no formal disclosure process.
Raise concerns directly with the maintainer.
