use crate::*;

// ---- Config (env-driven) --------------------------------------------------

// Hard upper bound on any single turn, regardless of JESSE_TIMEOUT. A request
// cannot pin a `claude` child (and a concurrency permit) for longer than this.
// Raised to 2h so a long agent turn (a big refactor, a deep vault sweep) can run
// to completion; the per-request JESSE_TIMEOUT (default 1h) still applies under it.
pub const HARD_TIMEOUT_CEILING: u64 = 7200;

// How long a finished-but-unretrieved reply is held before TTL eviction. Raised
// to 24h so a reply that completes while the phone is away (suspended, off the
// tailnet) is still there when it re-checks. The clock for a completed job only
// starts at FIRST successful retrieval (see `DEFAULT_RETRIEVAL_GRACE_SECS`); an
// unfetched reply gets the full window.
pub const DEFAULT_JOB_TTL_SECS: u64 = 86_400;

// Once a completed reply has been fetched at least once, it's kept only this much
// longer (a short grace so an immediate re-poll still succeeds) rather than for
// the full TTL — a fetched reply shouldn't linger for a day. This is the old
// pre-24h window, repurposed as the post-fetch grace.
pub const DEFAULT_RETRIEVAL_GRACE_SECS: u64 = 600;

// Default depth of the turn wait queue in front of the concurrency semaphore
// (env `JESSE_MAX_QUEUED`). When a permit isn't free, up to this many turns may
// WAIT for one; beyond it, load is shed with 429. Floor 0 (0 → no queue: an
// unavailable permit sheds immediately, the pre-queue behavior).
pub const DEFAULT_MAX_QUEUED: usize = 4;

// Age, in days, past which the session GC sweep reclaims a vault-project Claude
// Code session (env `JESSE_SESSION_TTL_DAYS`). Resuming a session touches its
// jsonl mtime, so the sweep never reclaims an actively-used thread — only the
// orphans (a swipe-delete whose remote delete never reached the bridge, and
// everything deleted locally before the delete-on-thread-delete flow existed).
// 90 days is a generous floor well past any realistic active-thread gap.
pub const DEFAULT_SESSION_TTL_DAYS: u64 = 90;

// Hard timeout (seconds) for the contained read-only vault-QA child. Tighter
// than a turn: the child reads a handful of vault files (Read/Grep/Glob, and the
// qmd MCP search when configured) and answers from them — a bounded lookup, not
// an agent turn. On overrun the ladder degrades to the hosted turn (rung 2). A
// const, not env-tunable: it bounds a latency-sensitive local answer, not an
// operator-managed workload, mirroring `TITLE_TIMEOUT_SECS`.
//
// Raised 25 → 60 after the vaultqa-v1 bake-off (2026-07-14) measured the winning
// oss backend's lookups at 10–42 s WALL: a 25 s ceiling would have timed out most
// real lookups (rung-2 fall-throughs) despite the model answering correctly. 60 s
// clears the measured 42 s max with headroom while still bounding the child well
// under a full turn.
pub const VAULTQA_TIMEOUT_SECS: u64 = 60;

// Hard timeout (seconds) for the EMERGENCY vault-QA child (Piece 4). Looser than
// the routine `VAULTQA_TIMEOUT_SECS` because there is no ladder rung below it: when
// hosted is unavailable the emergency answer is the only answer, so it is worth
// waiting longer for a best-effort local reply than to fail fast. A const, not
// env-tunable, for the same reason the routine timeout is.
pub const EMERGENCY_TIMEOUT_SECS: u64 = 120;

// Short, fixed timeout for the stateless title endpoint (`POST /jesse/title`).
// Much tighter than a turn's JESSE_TIMEOUT (default 3600s) because a title is
// interactive UI latency, not a full agent turn: on overrun the app just
// degrades to its own derived title. Deliberately a const, not env-tunable — it
// bounds a UX nicety, not an operator-managed workload.
pub const TITLE_TIMEOUT_SECS: u64 = 20;

// Captured agent stdout is truncated to this many bytes before parsing so one
// pathological run can't balloon the bridge's memory. The JSON envelope the
// bridge cares about is kilobytes; multiple MB is already pathological.
pub const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

// ---- Attachment caps (env-overridable defaults) ---------------------------
//
// Attachments are decoded from base64 in the request body, validated by
// magic-byte sniff against a MIME whitelist, written to a per-request scratch
// dir the headless agent reads, then deleted when the turn ends. These cap the
// new file-input attack surface; keep them in sync with SECURITY.md.

// Max attachments accepted on a single turn.
pub const DEFAULT_MAX_ATTACHMENTS: usize = 4;
// Max decoded size of any one attachment.
pub const DEFAULT_MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
// Max decoded size of all attachments on a turn combined.
pub const DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES: usize = 20 * 1024 * 1024;

// Least-privilege default tool allowlist for the headless agent. Scoped to what
// the vault's Ask/Tell workflows actually need: file read/write/search, the
// read-only QMD vault-search MCP tools, and a few scoped shell verbs (git for
// vault history, mv/ls/cat/find for file wrangling). Bare `Bash` is deliberately
// absent — only the `Bash(<verb>:*)` scopes below are allowed. Override with
// JESSE_ALLOWED_TOOLS. Keep in sync with the table in SECURITY.md.
//
// The `Bash(date:*)` / `Bash(cal:*)` scopes back up the per-turn clock header
// (see `prompt::clock_line`) for on-demand relative date math and alternate
// formats — both are pure computation with no side effect reachable as a
// non-privileged user (`date -s` needs root and simply fails; `cal` only prints).
// The `Bash(head:*)` / `Bash(tail:*)` / `Bash(wc:*)` scopes are strictly
// read-only, no writes and no network — they round out the existing read set
// (`cat`, `ls`, `find`, plus `Grep`/`Glob`) so the agent can inspect the large
// diet CSVs and logs without slurping a whole file. None of the five can write,
// send, or reach the network, so the action surface is unchanged.
//
// The three `Bash(node todo-list/<script>.js:*)` scopes let a food/exercise/
// weigh-in log REGENERATE the dashboard cache (`diet-today.js`) from the CSV
// source of truth and re-run its two guards — the per-item-log step the vault's
// Diet-Logging-Flow prescribes. Without them the agent could append the CSV row
// but not rebuild the cache, leaving `diet-today.js` stale (the 2026-06-27
// phantom-banana bug). They are pinned to the THREE exact script paths, NOT
// `Bash(node:*)` — a bare `node` scope would allow `node -e "<arbitrary JS>"`,
// i.e. arbitrary code execution from a phone request. cwd is the vault (see
// `run_claude`), so the relative paths resolve there.
//
// `Skill(diet-logging)` lets the agent auto-invoke the vault's `diet-logging`
// skill (`.claude/skills/diet-logging/SKILL.md`) on a food/exercise/weigh-in
// mention. The Skill tool only LOADS instruction text — it executes nothing
// itself; every real action the skill prescribes still flows through the
// already-scoped `Read`/`Write`/`Edit` and the three `Bash(node todo-list/*.js:*)`
// scripts above, so the action surface is unchanged. It is pinned to the SINGLE
// named skill, NOT a bare `Skill` (which would let any future vault skill run
// from a phone request) — the narrowest scope the CLI accepts
// (verified against claude 2.1.195). cwd is the vault, so the skill is discovered
// from `.claude/skills/` there.
pub const DEFAULT_ALLOWED_TOOLS: &str = "Read,Write,Edit,Grep,Glob,\
mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status,\
Skill(diet-logging),\
Bash(git:*),Bash(mv:*),Bash(ls:*),Bash(cat:*),Bash(find:*),\
Bash(date:*),Bash(cal:*),Bash(head:*),Bash(tail:*),Bash(wc:*),\
Bash(node todo-list/generate-diet-today.js:*),\
Bash(node todo-list/validate-diet-today.js:*),\
Bash(node todo-list/verify-diet-consistency.js:*)";

// Defense-in-depth: tools that must never run from the bridge even if they slip
// into the allowlist. WebFetch is the SSRF / data-exfiltration surface the
// Ask/Tell workflows don't need. Override with JESSE_DISALLOWED_TOOLS.
//
// Bare `Bash` is deliberately NOT here. Listing it removes the entire Bash tool
// class — which shadows EVERY scoped `Bash(<verb>:*)` grant in the allowlist
// above (git for code review, the three node diet-cache scripts, date/cal for the
// clock header, the read-only inspection verbs). Verified on the Studio
// (claude 2.1.199, 2026-07-04): with `Bash` denied, even `Bash(date:*)` reports
// "no Bash tool" — the scoped grants become dead. Unscoped Bash is still blocked
// WITHOUT this entry: under `--permission-mode default` a Bash command matching
// no scoped allow entry raises a permission prompt, which a headless (`-p`) phone
// turn cannot answer, so it is denied. Default-deny + the scoped allowlist is the
// real least-privilege boundary; denying the tool class only breaks the scoped
// grants (and silently broke diet-logging + the clock verbs until this fix).
pub const DEFAULT_DISALLOWED_TOOLS: &str = "WebFetch";

#[derive(Clone)]
pub struct Config {
    pub token: String,
    pub vault: String,
    // The bridge user's HOME, resolved ONCE at startup. Claude Code's session
    // transcripts live under `<home>/.claude/projects/…`, so every session-path
    // lookup (`sessions_dir`, `session_transcript_exists`, the GC sweep) reads THIS
    // rather than the process env at call time. HOME never changes during a run, so
    // this is behavior-identical in production; capturing it makes the session paths
    // deterministic and testable without mutating a process-global.
    pub home: String,
    pub bind: String,
    pub port: u16,
    pub claude_bin: String,
    pub timeout_secs: u64,
    // Comma-separated tool allowlist passed to `claude --allowedTools`.
    pub allowed_tools: String,
    // Comma-separated tool denylist passed to `claude --disallowedTools`.
    pub disallowed_tools: String,
    // Max concurrent turns. Defaults to 1 — a single global write lock, so at
    // most one turn runs (and can rewrite vault files) at a time regardless of how
    // many clients are connected. A request that can't get a permit immediately is
    // QUEUED (up to `max_queued`) rather than rejected; beyond the queue, 429.
    pub max_concurrency: usize,
    // Depth of the wait queue in front of the concurrency semaphore. When no
    // permit is free, up to this many turns may wait for one; beyond it, load is
    // shed with 429 (the pre-queue behavior). Floor 0 → no queue.
    pub max_queued: usize,
    // Per-service rate ceiling (requests accepted per rolling minute). Bursts
    // beyond this are rejected with 429.
    pub rate_per_min: u32,
    // How long a completed/failed job stays retrievable before TTL eviction when
    // it has NEVER been fetched. The clock starts at first retrieval, not at
    // completion, so an unfetched reply survives the full window.
    pub job_ttl_secs: u64,
    // Once a completed job has been fetched once, how much longer it's kept (a
    // short grace so a re-poll still works) instead of the full TTL.
    pub retrieval_grace_secs: u64,
    // Age, in DAYS, past which the background session GC sweep reclaims a
    // vault-project Claude Code session jsonl (env `JESSE_SESSION_TTL_DAYS`,
    // default `DEFAULT_SESSION_TTL_DAYS` = 90). The sweep keys on file mtime, and
    // resuming a session touches its mtime, so a session younger than this is
    // NEVER deleted — only orphaned transcripts older than the TTL are reclaimed.
    pub session_ttl_days: u64,
    // Directory under which completed job results are persisted (one JSON file
    // per job, under `<state_dir>/jobs`) so a bridge restart / laptop reboot
    // doesn't lose a finished-but-unretrieved reply. None disables persistence
    // (in-memory only). Defaults to `$HOME/.jesse-bridge`. Only the finished
    // result + metadata is written — never the bearer token or any secret.
    pub state_dir: Option<String>,
    // Attachment caps (see the DEFAULT_MAX_ATTACHMENT* consts). Decoded sizes.
    pub max_attachments: usize,
    pub max_attachment_bytes: usize,
    pub max_attachments_total_bytes: usize,
    // Base directory for per-request attachment scratch dirs. None → the system
    // temp dir. Set JESSE_SCRATCH_DIR to point this at a sandbox-mounted path if
    // the bridge is ever confined so it can't read the system temp dir.
    pub scratch_dir: Option<String>,
    // Optional title-endpoint backend override: `Some((base_url, auth_token,
    // model))` only when ALL THREE of JESSE_TITLE_BASE_URL / JESSE_TITLE_AUTH_TOKEN
    // / JESSE_TITLE_MODEL are set (see `resolve_title_backend` for the all-or-
    // nothing rule). When `Some`, the `POST /jesse/title` one-shot child — and
    // ONLY that child — gets ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN /
    // ANTHROPIC_MODEL set to these values, so a title can be served by a cheap,
    // fast local backend while main turns keep using the ambient credentials.
    // `None` → titles use the ambient backend, byte-for-byte today's behavior.
    pub title_backend: Option<(String, String, String)>,
    // Optional local diet-extract backend override: `Some((base_url, auth_token,
    // model))` only when ALL THREE of JESSE_DIET_BASE_URL / JESSE_DIET_AUTH_TOKEN /
    // JESSE_DIET_MODEL are set (see `resolve_diet_backend` — same all-or-nothing
    // rule as the title backend). When `Some`, the diet-logging pipeline's stateless
    // EXTRACT child — and only that child — gets ANTHROPIC_BASE_URL /
    // ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL set to these values, so a food/exercise/
    // weigh-in utterance can be parsed by a cheap local model while every main turn
    // and the hosted verify child keep using the ambient credentials.
    //
    // THE KILL SWITCH IS THIS SEAM ITSELF: leave the triple unset (the default) and
    // `diet_backend` is `None`, so the gate in `handlers::jesse` never fires and every
    // diet turn reverts BYTE-FOR-BYTE to today's hosted `run_claude_streaming` path —
    // no redeploy, no code change. `None` is the safe, shipped-today behavior.
    pub diet_backend: Option<(String, String, String)>,
    // Whether the local diet pipeline runs in PROBATION mode (env
    // `JESSE_DIET_PROBATION`, default TRUE). In probation the hosted verify gate is
    // mandatory and blocking on every extracted entry. `false` is a future
    // graduation state (flip blocking-verify to sampled-audit) and is NOT used yet —
    // it exists so graduation later needs no change to the extract child or the
    // append path. Independent of `diet_backend`: it tunes the pipeline's verify
    // posture, not whether the pipeline is active.
    pub diet_probation: bool,
    // Optional local vault-QA backend override: `Some((base_url, auth_token,
    // model))` only when ALL THREE of JESSE_VAULTQA_BASE_URL / JESSE_VAULTQA_AUTH_TOKEN
    // / JESSE_VAULTQA_MODEL are set (see `resolve_vaultqa_backend` — same all-or-
    // nothing rule as the diet backend). When `Some`, a self-referential "Ask" that
    // passes the strict vault-QA gate runs the CONTAINED, READ-ONLY vault-QA child —
    // and only that child — pointed at these values via `apply_vaultqa_env`, so a
    // vault lookup can be answered locally while every main turn and the diet/title
    // children keep their own credentials.
    //
    // THE KILL SWITCH IS THIS SEAM ITSELF: leave the triple unset (the default) and
    // `vaultqa_backend` is `None`, so the gate in `handlers::jesse` never fires and
    // every Ask reverts BYTE-FOR-BYTE to today's hosted `run_claude_streaming` path —
    // no redeploy, no code change. `None` is the safe, shipped-today behavior.
    pub vaultqa_backend: Option<(String, String, String)>,
    // Optional path to an MCP config JSON declaring exactly the qmd vault-search
    // server, layered onto the vault-QA child via `--mcp-config` (env
    // `JESSE_VAULTQA_MCP_CONFIG`). When unset the child loads NO MCP servers (the
    // empty-servers const) and runs on the three read-only built-ins alone — qmd is
    // simply absent, never an error. Only the vault-QA child ever reads this.
    pub vaultqa_mcp_config: Option<String>,
    // Whether the bridge appends a one-line provenance BADGE to each delivered
    // `POST /jesse/jesse` reply (env `JESSE_MODEL_BADGE`, default TRUE). Display
    // only: it names which backend produced the delivered text (`[local · vault · …]`,
    // `[local · diet · … + hosted verify]`, `[hosted · …]`) and is derived from the
    // bridge's own turn state, never from model output. `off` reproduces today's
    // exact reply text. Never applies to the title endpoint.
    pub model_badge: bool,
    // Optional absolute path to a structured-metrics JSONL file (env
    // `JESSE_METRICS_LOG`; see [`metrics`]). `None` (unset, the default) → ZERO metrics
    // writes: the metrics path is dormant, same soft-failure semantics as the other
    // envs. When `Some`, the bridge appends one JSON line per gated/routed/emergency
    // turn at the reply-finalization point the badge uses. Content-free (never the
    // question, answer, or tokens). A write failure logs to stderr and never disturbs
    // the reply.
    pub metrics_log: Option<String>,
    // Whether the EMERGENCY local fallback is armed (env `JESSE_EMERGENCY_LOCAL` =
    // `on|off`, default OFF). When on AND the vault-QA triple is also set (which
    // supplies the backend + read-only child), a hosted turn that fails TRANSPORT-class
    // (spawn/network/timeout/5xx/429/quota/auth — never a completed turn) is answered
    // best-effort by the local read-only child (Ask) or queued for later verify (diet
    // Tell) instead of surfacing the outage. Inert unless BOTH this flag and the
    // vault-QA backend are set; unset → every path is byte-for-byte today's behavior.
    pub emergency_local: bool,
    // Whether the bridge-side CONTEXT LEDGER is active (env `JESSE_CONTEXT_CARRY` =
    // `on|off`, DEFAULT ON). It fixes a live defect: a locally served turn never
    // entered the thread's hosted session, so the next hosted follow-up lost the
    // earlier turn. On → the ledger records each delivered ask/tell turn, injects a
    // catch-up block into the next hosted turn and a recent-conversation block into
    // the local children, and mints a synthetic thread id for a fresh locally-served
    // turn. Off is the ROLLBACK: byte-for-byte today's behavior — no ledger reads or
    // writes, no `context.json`, no synthetic ids, no injected blocks. Default ON
    // follows the badge's default-on precedent because this repairs a live bug.
    pub context_carry: bool,
    // Opt-in SHADOW-comparison backend override (env `JESSE_SHADOW_*`, same
    // all-or-nothing `Option<(base_url, auth_token, model)>` triple as the vault-QA
    // backend). When `Some`, a SAMPLED subset of eligible ask turns is mirrored —
    // AFTER the hosted answer is delivered — to this backend through a contained
    // read-only child, and both answers plus timing/usage are appended to the local
    // shadow log for offline judging. Nothing about the delivered answer, its
    // latency, its badge, or any production route changes. THE TRIPLE IS THE KILL
    // SWITCH: unset any one var → `None` → not a single turn is mirrored,
    // byte-for-byte today's behavior. The production intent is the gateway URL, the
    // gateway token, and the `fw-glm` model alias (the bridge never carries a
    // Fireworks credential — only the gateway URL + token). See [`shadow`].
    pub shadow_backend: Option<(String, String, String)>,
    // Percentage of ELIGIBLE ask turns mirrored to the shadow backend (env
    // `JESSE_SHADOW_SAMPLE_PCT`, default 100, clamped to `[0, 100]`). The decision is
    // per turn via a DETERMINISTIC hash of the turn id (`shadow_sampled`), so it is
    // reproducible and never an RNG. 0 → nothing is mirrored even when armed; 100 →
    // every eligible turn. Inert unless `shadow_backend` is set.
    pub shadow_sample_pct: u8,
    // Absolute path to the shadow pair log (env `JESSE_SHADOW_LOG`, default
    // `~/Library/Logs/jesse-shadow/shadow.jsonl`, `~` expanded, parent created on
    // first write). One JSON line per mirrored pair; created mode 0600 (it holds
    // vault-derived answer text — it stays local and the bridge never sends it
    // anywhere). Inert unless `shadow_backend` is set.
    pub shadow_log: String,
    // Wall-clock budget for one shadow child (env `JESSE_SHADOW_TIMEOUT_SECS`,
    // default 120). A timeout records an INCOMPLETE pair and never retries. Inert
    // unless `shadow_backend` is set.
    pub shadow_timeout_secs: u64,
    // The resolved personalization: owner name/pronoun, languages, and extra diet
    // vocabulary. Loaded from generic built-in defaults → `jesse.local.toml`
    // `[persona]` → environment (see [`Persona::load`]). A fresh clone with no
    // local file resolves to the generic default ("the user"), so no personal fact
    // is ever compiled in — personalization is pure runtime DATA.
    pub persona: Persona,
    // The set of models the CONVERSATION (main turn + its subagents) can be switched
    // onto, built once from `JESSE_MODEL_*` env at startup (see [`ModelRegistry`]).
    // Always holds the ambient `opus` default; `glm-5.2` / `kimi-k3` / `local` are
    // present-but-unavailable until their triples resolve. Distinct from the cheap-role
    // offload backends above, which the switch never touches. Holds no persisted secret
    // — the ACTIVE selection lives in the `ModelStore` (ids + booleans only).
    pub model_registry: ModelRegistry,
}

impl Config {
    /// Resolve the base directory under which per-request scratch dirs are
    /// created: `JESSE_SCRATCH_DIR` if set, else the system temp dir.
    pub fn scratch_base(&self) -> PathBuf {
        self.scratch_dir
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
    }

    /// The directory under which per-job result files are written, or `None`
    /// when persistence is disabled. `<state_dir>/jobs` keeps the job store's
    /// files in their own subdir so the state dir can hold other things later.
    pub fn jobs_dir(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("jobs"))
    }

    /// The file the registered APNs device token is persisted to (sibling of the
    /// `jobs/` dir), or `None` when persistence is disabled. One file, one token.
    pub fn device_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("device.json"))
    }

    /// The file the server-side session titles are persisted to (sibling of the
    /// `jobs/` dir and `device.json`), or `None` when persistence is disabled —
    /// then titles are in-memory only, the same degradation the job store has.
    pub fn titles_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("titles.json"))
    }

    /// The file the per-session favorite / archived flags are persisted to (a
    /// sibling of `titles.json`), or `None` when persistence is disabled (then the
    /// flags are in-memory only), the same degradation the job/title/device stores
    /// have. Holds only the two booleans and their change timestamps, never a secret.
    pub fn flags_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("flags.json"))
    }

    /// The file the global model selection is persisted to (a sibling of `flags.json`),
    /// or `None` when persistence is disabled (then the selection is in-memory only and
    /// resets to `opus` on restart), the same degradation the job / title / device / flag
    /// stores have. Holds only the active id and per-model write booleans, never a secret.
    pub fn model_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("model.json"))
    }

    /// The file the per-session deletion tombstones are persisted to (a sibling of
    /// `flags.json`), or `None` when persistence is disabled (then tombstones are
    /// in-memory only), the same degradation the job / title / device / flag stores
    /// have. Holds only a session_id and the unix-millis delete time, never a secret.
    pub fn deletions_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("deletions.json"))
    }

    /// The file the context ledger is persisted to (a sibling of `titles.json`),
    /// or `None` when persistence is disabled — then the ledger is in-memory only,
    /// the same degradation the job/title/device stores have. Holds conversation
    /// content (the ledger's whole point), so it stays in the state dir and never
    /// reaches the metrics log, provenance, or any other log line.
    pub fn context_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("context.json"))
    }
}

/// Clamp a requested per-turn timeout into a sane, bounded range. `0` is treated
/// as "use the ceiling" rather than "unlimited" so no request can pin a child
/// forever; any value is capped at `HARD_TIMEOUT_CEILING` and floored at 1s.
/// The only "unlimited" affordance lives in `run_claude` behind
/// `#[cfg(debug_assertions)]` and is never reachable in a release build.
pub fn clamp_timeout_secs(raw: u64) -> u64 {
    if raw == 0 {
        return HARD_TIMEOUT_CEILING;
    }
    raw.clamp(1, HARD_TIMEOUT_CEILING)
}

/// Read an env var as a trimmed, non-empty string, or `None`. This is the single
/// definition of "a string env var is set" — trimmed and empty-filtered — so all
/// string-valued config fields treat a blank/whitespace value identically (fall
/// back to their default). It removes the old inconsistency where some fields
/// (`JESSE_ALLOWED_TOOLS`, `JESSE_STATE_DIR`, …) filtered empty and others
/// (`JESSE_VAULT`, `JESSE_BIND`, …) accepted a blank value verbatim.
pub fn env_string(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Parse an env var into `T`, falling back to `default` when it's unset or
/// doesn't parse. Replaces the dozen hand-rolled
/// `env::var(..).ok().and_then(parse).unwrap_or(default)` chains. (The two
/// `>= 1`-floored fields keep their explicit predicate below — `env_parse` has
/// no notion of a validity floor, and folding a parsed `0` to `1` instead of the
/// default would change behavior.)
pub fn env_parse<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

/// Resolve the optional title-endpoint backend override from its three
/// env-derived parts. Returns `Some((base_url, auth_token, model))` ONLY when all
/// three are present; any partial combination (one or two set) resolves to `None`
/// so titles fall back to the ambient backend — the "partial config is treated as
/// unset" rule. On a partial config it logs one warning at startup so a
/// half-configured deploy is visible rather than silently half-redirecting. Pure
/// except for that warning; the `Some`/`None` result is what encodes the rule.
pub fn resolve_title_backend(
    base_url: Option<String>,
    auth_token: Option<String>,
    model: Option<String>,
) -> Option<(String, String, String)> {
    match (base_url, auth_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        (b, t, m) => {
            let set = b.is_some() as u8 + t.is_some() as u8 + m.is_some() as u8;
            if set > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_TITLE_* config ({set}/3 set) — the \
                     title-backend override needs ALL of JESSE_TITLE_BASE_URL, \
                     JESSE_TITLE_AUTH_TOKEN, JESSE_TITLE_MODEL; treating as unset \
                     (titles use the ambient backend)."
                );
            }
            None
        }
    }
}

/// Resolve the optional local diet-extract backend override from its three
/// env-derived parts. Identical all-or-nothing rule as [`resolve_title_backend`]:
/// returns `Some((base_url, auth_token, model))` ONLY when all three are present;
/// any partial combination resolves to `None` (the diet pipeline stays dormant and
/// diet turns keep using the ambient/hosted path). A partial config logs one
/// startup warning so a half-configured deploy is visible rather than silently
/// half-active. Pure except for that warning.
pub fn resolve_diet_backend(
    base_url: Option<String>,
    auth_token: Option<String>,
    model: Option<String>,
) -> Option<(String, String, String)> {
    match (base_url, auth_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        (b, t, m) => {
            let set = b.is_some() as u8 + t.is_some() as u8 + m.is_some() as u8;
            if set > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_DIET_* config ({set}/3 set) — the \
                     local diet-extract backend needs ALL of JESSE_DIET_BASE_URL, \
                     JESSE_DIET_AUTH_TOKEN, JESSE_DIET_MODEL; treating as unset (diet \
                     turns use the hosted path)."
                );
            }
            None
        }
    }
}

/// Resolve the optional local vault-QA backend override from its three env-derived
/// parts. Identical all-or-nothing rule as [`resolve_diet_backend`] /
/// [`resolve_title_backend`]: returns `Some((base_url, auth_token, model))` ONLY
/// when all three are present; any partial combination resolves to `None` (the
/// vault-QA route stays inert and Asks keep taking the hosted path). A partial
/// config logs one startup warning so a half-configured deploy is visible rather
/// than silently half-active. Pure except for that warning.
pub fn resolve_vaultqa_backend(
    base_url: Option<String>,
    auth_token: Option<String>,
    model: Option<String>,
) -> Option<(String, String, String)> {
    match (base_url, auth_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        (b, t, m) => {
            let set = b.is_some() as u8 + t.is_some() as u8 + m.is_some() as u8;
            if set > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_VAULTQA_* config ({set}/3 set) — the \
                     local vault-QA backend needs ALL of JESSE_VAULTQA_BASE_URL, \
                     JESSE_VAULTQA_AUTH_TOKEN, JESSE_VAULTQA_MODEL; treating as unset (Asks \
                     use the hosted path)."
                );
            }
            None
        }
    }
}

/// Resolve the optional SHADOW-comparison backend override from its three
/// env-derived parts. Identical all-or-nothing rule as [`resolve_vaultqa_backend`]:
/// returns `Some((base_url, auth_token, model))` ONLY when all three are present;
/// any partial combination resolves to `None` (shadow mode stays disarmed and no
/// ask turn is ever mirrored). A partial config logs one startup warning so a
/// half-configured deploy is visible rather than silently half-active. Pure except
/// for that warning. THE TRIPLE IS THE KILL SWITCH: unset any one var and shadow is
/// off, byte-for-byte today's behavior (unset all three → silent). The production
/// intent is the gateway URL, the gateway token, and the `fw-glm` model alias.
pub fn resolve_shadow_backend(
    base_url: Option<String>,
    auth_token: Option<String>,
    model: Option<String>,
) -> Option<(String, String, String)> {
    match (base_url, auth_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        (b, t, m) => {
            let set = b.is_some() as u8 + t.is_some() as u8 + m.is_some() as u8;
            if set > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_SHADOW_* config ({set}/3 set) — shadow \
                     comparison needs ALL of JESSE_SHADOW_BASE_URL, JESSE_SHADOW_AUTH_TOKEN, \
                     JESSE_SHADOW_MODEL; treating as unset (no turn is mirrored)."
                );
            }
            None
        }
    }
}

/// Clamp a shadow sample percentage into `[0, 100]`. Unset/unparseable falls back
/// to the caller's default (100 = mirror every eligible turn); an out-of-range value
/// saturates to the nearest bound rather than disabling sampling.
pub fn clamp_sample_pct(raw: u64) -> u8 {
    raw.min(100) as u8
}

/// Expand a leading `~` / `~/` in a path to `home` (the crate keeps `HOME` in
/// `Config.home`, captured once at startup — there is no other tilde expansion in
/// the crate, so this is the single definition). A bare `~` becomes `home`; `~/x`
/// becomes `home/x`. Any other shape (absolute path, `~user`, empty home) is
/// returned unchanged, so an already-absolute `JESSE_SHADOW_LOG` is untouched.
pub fn expand_tilde(raw: &str, home: &str) -> String {
    if home.is_empty() {
        return raw.to_string();
    }
    if raw == "~" {
        return home.to_string();
    }
    match raw.strip_prefix("~/") {
        Some(rest) => format!("{home}/{rest}"),
        None => raw.to_string(),
    }
}

/// Parse `JESSE_MODEL_BADGE` into the `model_badge` flag. Default TRUE: only an
/// explicit `off` / `0` / `false` / `no` disables the badge; anything else
/// (including unset or a bare `on`) keeps it on. Mirrors the `JESSE_DIET_PROBATION`
/// truthiness rule so operators reason about one convention.
pub fn resolve_model_badge() -> bool {
    std::env::var("JESSE_MODEL_BADGE")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no" || v == "off")
        })
        .unwrap_or(true)
}

/// Parse `JESSE_EMERGENCY_LOCAL` into the `emergency_local` flag. Default FALSE
/// (the opposite of `JESSE_MODEL_BADGE`/`JESSE_DIET_PROBATION`): the emergency
/// fallback is an availability lever that changes what a hosted OUTAGE does, so it
/// stays OFF unless an operator EXPLICITLY opts in with a truthy value. Only
/// `on`/`1`/`true`/`yes` enable it; unset, blank, `off`, or an unrecognized value
/// all leave it off, so a fat-fingered value can never silently arm it.
pub fn resolve_emergency_local() -> bool {
    std::env::var("JESSE_EMERGENCY_LOCAL")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            v == "on" || v == "1" || v == "true" || v == "yes"
        })
        .unwrap_or(false)
}

/// Parse `JESSE_CONTEXT_CARRY` into the `context_carry` flag. Default TRUE (mirrors
/// [`resolve_model_badge`]): only an explicit `off`/`0`/`false`/`no` disables it. This
/// repairs a live defect, so the off switch is the ROLLBACK, not the default — the same
/// default-on precedent the badge follows, and the opposite of `resolve_emergency_local`
/// (which defaults OFF because it changes what a hosted outage does).
pub fn resolve_context_carry() -> bool {
    std::env::var("JESSE_CONTEXT_CARRY")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no" || v == "off")
        })
        .unwrap_or(true)
}

// ---- Model registry (the global model switch) -----------------------------
//
// The registry is the set of MODELS the conversation itself (the main turn and the
// subagents it spawns) can be switched onto, chosen from the phone or the Mac. It is
// entirely distinct from the cheap-role offload backends (`JESSE_TITLE_*`,
// `JESSE_DIET_*`, `JESSE_VAULTQA_*`, `JESSE_SHADOW_*`) above: those keep serving their
// own roles regardless of which model the conversation is switched to. Like every
// backend triple in this file, a registry entry's credentials come ONLY from the
// launch env (`JESSE_MODEL_*`) — no secret is compiled in, and nothing here is ever
// persisted (the `ModelStore` holds only ids and booleans).

/// A per-1,000,000-token price deck: input / cache-read / output dollars per million
/// tokens. The per-turn cost badge multiplies a turn's `usage` vector by the ACTIVE
/// model's deck (the same arithmetic the shadow audit uses — see [`ShadowUsage`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PriceDeck {
    pub in_per_m: f64,
    pub cached_per_m: f64,
    pub out_per_m: f64,
}

impl PriceDeck {
    /// A free model (the `local` entry): every turn costs `$0.00`.
    pub const ZERO: PriceDeck = PriceDeck {
        in_per_m: 0.0,
        cached_per_m: 0.0,
        out_per_m: 0.0,
    };
}

/// How a selectable model's backend is applied to the MAIN turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelKind {
    /// The default (`opus`): NO `ANTHROPIC_*` overrides — the main turn inherits the
    /// ambient process env, byte-for-byte today's behavior (the isolation property).
    Ambient,
    /// A hosted backend reached over the Anthropic `/v1/messages` surface (GLM, Kimi).
    Hosted,
    /// An Anthropic-compatible LOCAL endpoint.
    Local,
}

/// One selectable model in the registry. Built from the built-in ambient default, the
/// `JESSE_MODEL_*` env triples, and the declarative `[[models]]` config; holds no secret
/// beyond what the env supplied (the token lives ONLY inside `backend`, resolved from a
/// named env var, and is never serialized to a client or to `model.json`).
#[derive(Debug, Clone)]
pub struct RegistryModel {
    /// The stable id the store + endpoints key on (`opus`, `glm-5.2`, `kimi-k3`, `local`,
    /// or any declarative id).
    pub id: String,
    /// The human label shown in the app's switcher.
    pub label: String,
    pub kind: ModelKind,
    /// `(base_url, auth_token, model_id)` — the same all-or-nothing triple shape as the
    /// role backends. `None` for the ambient entry (it applies nothing) AND for a
    /// hosted/local entry whose triple did not fully resolve (then `configured` is false).
    pub backend: Option<(String, String, String)>,
    /// The subagent model id the switch propagates via `CLAUDE_CODE_SUBAGENT_MODEL` (default
    /// = the backend's `model_id`; a declarative entry may override it). `None` for the
    /// ambient entry and any unconfigured entry.
    pub subagent_model: Option<String>,
    /// Whether this entry's backend/token RESOLVED (a selectable model must also be HEALTHY —
    /// see [`model_health`]). Ambient is always configured; a hosted/local entry is
    /// configured IFF its triple resolved (its token env var was set).
    pub configured: bool,
    /// The write permission a freshly-registered model gets before any explicit opt-in.
    /// Ambient (`opus`) is always `true` (writes-on); every non-ambient entry defaults
    /// `false` — read-only until writes are enabled per model.
    pub default_writes: bool,
    /// The price deck for the per-turn cost badge.
    pub price: PriceDeck,
    /// The health-probe cadence + endpoint for this model (unused for the ambient entry,
    /// which is healthy by construction and never probed).
    pub health: HealthConfig,
}

/// The set of models the conversation can be switched onto. Ordered as presented to the
/// app (default first). Built once at startup from env; read-only thereafter.
#[derive(Debug, Clone)]
pub struct ModelRegistry {
    pub models: Vec<RegistryModel>,
}

/// The id of the default, always-available model. Selecting it reproduces today's
/// behavior byte-for-byte (no overrides, normal allowlist, writes-on).
pub const DEFAULT_MODEL_ID: &str = "opus";

impl ModelRegistry {
    /// Look up an entry by id.
    pub fn get(&self, id: &str) -> Option<&RegistryModel> {
        self.models.iter().find(|m| m.id == id)
    }

    /// The default (ambient) entry — always present, so this never panics in practice;
    /// falls back to a synthesized ambient opus if somehow absent.
    pub fn default_model(&self) -> &RegistryModel {
        self.get(DEFAULT_MODEL_ID)
            .unwrap_or_else(|| &self.models[0])
    }

    /// Whether `id` names an entry that exists AND is CONFIGURED (its backend/token
    /// resolved). Selectability additionally requires the model to be HEALTHY at the moment
    /// of selection — the endpoint layer combines this with the live [`HealthStore`] (see
    /// [`model_health`]); this alone cannot know the dynamic health state.
    pub fn is_configured(&self, id: &str) -> bool {
        self.get(id).map(|m| m.configured).unwrap_or(false)
    }

    /// The opus-only registry: the single always-available ambient default and nothing
    /// else. The test fixture and any deploy with no `JESSE_MODEL_*` env resolve to
    /// exactly this, so an unconfigured bridge behaves byte-for-byte as before.
    pub fn opus_only() -> Self {
        ModelRegistry {
            models: vec![opus_entry()],
        }
    }

    /// Build the registry by MERGING three sources, later overriding earlier BY ID:
    ///   1. the built-in ambient `opus` (always present, never configurable — a declarative
    ///      or env entry that tries to redefine it is refused);
    ///   2. the `JESSE_MODEL_GLM_*` / `JESSE_MODEL_KIMI_*` / `JESSE_MODEL_LOCAL_*` env triples,
    ///      preserved with the SAME ids, defaults, and prices as before so nothing deployed
    ///      breaks;
    ///   3. the declarative `[[models]]` array from the bridge config file (the same TOML the
    ///      persona loads from — see [`load_local_models`]).
    ///
    /// With NO model config (no `JESSE_MODEL_*`, no `[[models]]`) this is exactly the
    /// opus-only registry, so an unconfigured bridge is byte-for-byte today's behavior.
    /// `home` is the captured `Config.home`, used to locate the config file.
    pub fn from_env(home: &str) -> Self {
        // Source 1: the built-in ambient default, first (the app presents default-first).
        let mut models: Vec<RegistryModel> = vec![opus_entry()];

        // Source 2: the preserved env triples (same ids/defaults/prices as before).
        upsert_model(&mut models, glm_env_entry());
        upsert_model(&mut models, kimi_env_entry());
        upsert_model(&mut models, local_env_entry());

        // Source 3: the declarative `[[models]]` entries (later overrides earlier by id).
        for decl in load_local_models(home) {
            if let Some(m) = registry_model_from_toml(&decl) {
                upsert_model(&mut models, m);
            }
        }

        ModelRegistry { models }
    }
}

/// Insert `m` into the list, REPLACING any existing entry with the same id IN PLACE (stable
/// order, default-first preserved) or appending it when new. The ambient `opus` default is
/// protected: an entry that tries to take its id is refused with a warning, so `opus` stays
/// byte-for-byte the built-in. This is what makes the three-source merge "later overrides
/// earlier by id" while keeping the always-present ambient default untouchable.
fn upsert_model(models: &mut Vec<RegistryModel>, m: RegistryModel) {
    if m.id == DEFAULT_MODEL_ID || matches!(m.kind, ModelKind::Ambient) {
        eprintln!(
            "jesse-bridge: WARNING model '{}' would redefine the built-in ambient default \
             ('{DEFAULT_MODEL_ID}'); ignoring it — the ambient default is never configurable.",
            m.id
        );
        return;
    }
    if let Some(existing) = models.iter_mut().find(|e| e.id == m.id) {
        *existing = m;
    } else {
        models.push(m);
    }
}

/// The `glm-5.2` env-triple entry (hosted on Fireworks' Anthropic surface). base + model
/// DEFAULT; only the token must be supplied, so an operator arms GLM with a single secret
/// env var.
fn glm_env_entry() -> RegistryModel {
    let backend = resolve_model_backend(
        "glm-5.2",
        env_string("JESSE_MODEL_GLM_BASE_URL"),
        env_string("JESSE_MODEL_GLM_AUTH_TOKEN"),
        env_string("JESSE_MODEL_GLM_MODEL"),
        Some("https://api.fireworks.ai/inference"),
        Some("accounts/fireworks/models/glm-5p2"),
    );
    RegistryModel {
        id: "glm-5.2".to_string(),
        label: "GLM 5.2".to_string(),
        kind: ModelKind::Hosted,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        default_writes: false,
        price: PriceDeck {
            in_per_m: FW_IN_PER_M,
            cached_per_m: FW_CACHED_PER_M,
            out_per_m: FW_OUT_PER_M,
        },
        health: HealthConfig::default(),
    }
}

/// The `kimi-k3` env-triple entry. NO defaults — Fireworks does not yet serve Kimi K3, so
/// with no `JESSE_MODEL_KIMI_*` set it ships UNCONFIGURED and a selection attempt is
/// rejected. When a live slug appears the operator supplies all three vars (and a real price
/// deck via env) to arm it.
fn kimi_env_entry() -> RegistryModel {
    let backend = resolve_model_backend(
        "kimi-k3",
        env_string("JESSE_MODEL_KIMI_BASE_URL"),
        env_string("JESSE_MODEL_KIMI_AUTH_TOKEN"),
        env_string("JESSE_MODEL_KIMI_MODEL"),
        None,
        None,
    );
    RegistryModel {
        id: "kimi-k3".to_string(),
        label: "Kimi K3".to_string(),
        kind: ModelKind::Hosted,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        default_writes: false,
        // Placeholder until a live Fireworks slug + published pricing exist; overridable
        // from env so arming Kimi later needs no code change.
        price: model_price_from_env("JESSE_MODEL_KIMI", PriceDeck::ZERO),
        health: HealthConfig::default(),
    }
}

/// The `local` env-triple entry: an Anthropic-compatible local endpoint. NO defaults — all
/// three vars required. Free (price deck 0/0/0), so every local turn badges `$0.00`.
fn local_env_entry() -> RegistryModel {
    let backend = resolve_model_backend(
        "local",
        env_string("JESSE_MODEL_LOCAL_BASE_URL"),
        env_string("JESSE_MODEL_LOCAL_AUTH_TOKEN"),
        env_string("JESSE_MODEL_LOCAL_MODEL"),
        None,
        None,
    );
    RegistryModel {
        id: "local".to_string(),
        label: "Local".to_string(),
        kind: ModelKind::Local,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        default_writes: false,
        price: PriceDeck::ZERO,
        health: HealthConfig::default(),
    }
}

/// The registry model resolved for ONE turn, plus its effective write permission — the
/// exact inputs the main-turn command builder ([`build_claude_command`]) needs. Built by
/// the handler from the registry + the [`ModelStore`] (see `AppState::resolve_active_model`).
#[derive(Debug, Clone, PartialEq)]
pub struct ActiveModel {
    /// The active model id (`opus`, `glm-5.2`, `local`, …). Names the badge.
    pub id: String,
    pub kind: ModelKind,
    /// The `ANTHROPIC_*` triple to apply to the MAIN turn, or `None` for the ambient
    /// default (apply nothing — the isolation property). NEVER a per-ROLE backend.
    pub env: Option<(String, String, String)>,
    /// The subagent model id (== the triple's model) so the subagents the main turn
    /// spawns follow the switch via `CLAUDE_CODE_SUBAGENT_MODEL`. `None` for ambient.
    pub subagent_model: Option<String>,
    /// Whether this turn may WRITE. `false` → the read-only allowlist (the Phase 1
    /// default for every non-ambient model). Ambient (`opus`) is always `true`.
    pub writes_allowed: bool,
    /// The price deck for the per-turn cost badge.
    pub price: PriceDeck,
}

impl ActiveModel {
    /// The ambient default (`opus`): no env overrides, writes-on. A turn built with this
    /// is byte-for-byte today's behavior — the value the title one-shot and any
    /// no-switch caller pass so nothing about their command changes.
    pub fn ambient() -> Self {
        ActiveModel {
            id: DEFAULT_MODEL_ID.to_string(),
            kind: ModelKind::Ambient,
            env: None,
            subagent_model: None,
            writes_allowed: true,
            price: PriceDeck {
                in_per_m: OPUS_IN_PER_M,
                cached_per_m: OPUS_CACHED_PER_M,
                out_per_m: OPUS_OUT_PER_M,
            },
        }
    }

    /// Whether this active model applies `ANTHROPIC_*` overrides to the main turn (i.e.
    /// it is a hosted/local backend, not the ambient default).
    pub fn is_non_ambient(&self) -> bool {
        self.env.is_some()
    }
}

/// The always-present ambient default entry.
fn opus_entry() -> RegistryModel {
    RegistryModel {
        id: DEFAULT_MODEL_ID.to_string(),
        label: "Claude Opus".to_string(),
        kind: ModelKind::Ambient,
        backend: None,
        subagent_model: None,
        configured: true,
        default_writes: true,
        price: PriceDeck {
            in_per_m: OPUS_IN_PER_M,
            cached_per_m: OPUS_CACHED_PER_M,
            out_per_m: OPUS_OUT_PER_M,
        },
        health: HealthConfig::default(),
    }
}

// ---- Declarative `[[models]]` config (source 3) ---------------------------
//
// A `[[models]]` array in the bridge config file (the same TOML the persona loads from)
// declares a model with a pure config edit plus one env var for its token — no Rust change.
// Every field is optional at the parse layer so a partial/typo'd entry is SKIPPED with a
// warning rather than failing the whole file (which would also drop the persona); the
// required fields (`id`, `kind`, `base_url`, `model`) are validated in code.

/// The optional `price = { in_per_m, cached_per_m, out_per_m }` sub-table (each field
/// defaults to 0.0 → a free model unless priced).
#[derive(Deserialize, Debug, Default, Clone)]
pub struct PriceToml {
    pub in_per_m: Option<f64>,
    pub cached_per_m: Option<f64>,
    pub out_per_m: Option<f64>,
}

/// The optional `health = { path, interval_secs, timeout_secs }` sub-table (each field
/// defaults independently — see [`HealthConfig`]).
#[derive(Deserialize, Debug, Default, Clone)]
pub struct HealthToml {
    pub path: Option<String>,
    pub interval_secs: Option<u64>,
    pub timeout_secs: Option<u64>,
}

/// One `[[models]]` entry. `auth_token_env` is the NAME of the env var holding the token —
/// NEVER the token itself; it is resolved from the process env at startup and a missing/
/// unset var yields a configured-but-unarmed (present, not selectable) model.
#[derive(Deserialize, Debug, Default, Clone)]
pub struct ModelToml {
    pub id: Option<String>,
    pub label: Option<String>,
    /// `hosted` | `local` (`ambient` is reserved for the built-in opus and refused).
    pub kind: Option<String>,
    pub base_url: Option<String>,
    pub model: Option<String>,
    pub subagent_model: Option<String>,
    pub auth_token_env: Option<String>,
    pub default_writes: Option<bool>,
    pub price: Option<PriceToml>,
    pub health: Option<HealthToml>,
}

/// Parse a declarative `kind` string into a [`ModelKind`]. Only `hosted` / `local` are
/// valid; `ambient` (and anything else) is refused so a declarative entry can never claim
/// the ambient contract.
fn parse_declared_kind(kind: &str) -> Option<ModelKind> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "hosted" => Some(ModelKind::Hosted),
        "local" => Some(ModelKind::Local),
        _ => None,
    }
}

/// Resolve a declared model's token from its `auth_token_env` var NAME. `Some(token)` only
/// when the field is present AND that env var is set to a non-blank value; otherwise `None`
/// (the model is configured-but-unarmed — present in the list, not selectable). The token
/// value is NEVER logged.
fn resolve_declared_token(auth_token_env: Option<&str>) -> Option<String> {
    auth_token_env
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .and_then(env_string)
}

/// Build a [`RegistryModel`] from one declarative `[[models]]` entry, or `None` (with a
/// warning) when a required field is missing or `kind` is invalid. The backend resolves to
/// `Some(triple)` — and `configured` to true — ONLY when the named token env var is set;
/// otherwise the entry is present-but-unarmed (`configured = false`), the same treatment an
/// unresolved env triple gets. No token is ever written back into the entry the endpoints
/// serialize — it lives solely inside `backend`.
pub fn registry_model_from_toml(t: &ModelToml) -> Option<RegistryModel> {
    let id = t.id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let (id, kind_str, base_url, model) = match (
        id,
        t.kind.as_deref().map(str::trim).filter(|s| !s.is_empty()),
        t.base_url.as_deref().map(str::trim).filter(|s| !s.is_empty()),
        t.model.as_deref().map(str::trim).filter(|s| !s.is_empty()),
    ) {
        (Some(id), Some(k), Some(b), Some(m)) => (id, k, b, m),
        _ => {
            eprintln!(
                "jesse-bridge: WARNING a declarative [[models]] entry (id {:?}) is missing a \
                 required field (id, kind, base_url, model are all required); ignoring it.",
                t.id
            );
            return None;
        }
    };
    let Some(kind) = parse_declared_kind(kind_str) else {
        eprintln!(
            "jesse-bridge: WARNING declarative model '{id}' has invalid kind '{kind_str}' \
             (must be 'hosted' or 'local'; 'ambient' is reserved); ignoring it."
        );
        return None;
    };
    let token = resolve_declared_token(t.auth_token_env.as_deref());
    if token.is_none() {
        // Present-but-unarmed: log ONCE so a half-configured model is visible, then ship it
        // unconfigured (in the list, not selectable) — never the token, only the var name.
        match t.auth_token_env.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            Some(var) => eprintln!(
                "jesse-bridge: model '{id}' is configured-but-unarmed — its auth_token_env \
                 '{var}' is unset; it appears in the list but is not selectable until armed."
            ),
            None => eprintln!(
                "jesse-bridge: model '{id}' has no auth_token_env — it appears in the list but \
                 is not selectable until an auth_token_env naming a set var is supplied."
            ),
        }
    }
    let configured = token.is_some();
    let backend = token.map(|tok| (base_url.to_string(), tok, model.to_string()));
    let subagent_model = t
        .subagent_model
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        // Default the subagent model to the main model — but only when configured, so an
        // unarmed entry carries no backend-derived value (mirrors the env triples).
        .or_else(|| configured.then(|| model.to_string()));
    let price = t
        .price
        .as_ref()
        .map(|p| PriceDeck {
            in_per_m: p.in_per_m.unwrap_or(0.0),
            cached_per_m: p.cached_per_m.unwrap_or(0.0),
            out_per_m: p.out_per_m.unwrap_or(0.0),
        })
        .unwrap_or(PriceDeck::ZERO);
    let health = t
        .health
        .as_ref()
        .map(|h| HealthConfig {
            path: h
                .path
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or(DEFAULT_HEALTH_PATH)
                .to_string(),
            interval_secs: h.interval_secs.filter(|n| *n > 0).unwrap_or(DEFAULT_HEALTH_INTERVAL_SECS),
            timeout_secs: h.timeout_secs.filter(|n| *n > 0).unwrap_or(DEFAULT_HEALTH_TIMEOUT_SECS),
        })
        .unwrap_or_default();
    Some(RegistryModel {
        id: id.to_string(),
        label: t
            .label
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(id)
            .to_string(),
        kind,
        backend,
        subagent_model,
        configured,
        default_writes: t.default_writes.unwrap_or(false),
        price,
        health,
    })
}

/// Resolve a registry model's `(base_url, auth_token, model)` triple from its env parts,
/// layering the optional defaults for base/model UNDER the env values. All-or-nothing,
/// mirroring [`resolve_vaultqa_backend`]: returns `Some` only when all three resolve
/// (env or default), else `None` (the model is UNAVAILABLE — never a partial config). A
/// partial ENV config (some `JESSE_MODEL_<X>_*` set but the triple still incomplete)
/// logs one startup warning; a model left entirely unset resolves to `None` silently.
pub fn resolve_model_backend(
    id: &str,
    env_base: Option<String>,
    env_token: Option<String>,
    env_model: Option<String>,
    default_base: Option<&str>,
    default_model: Option<&str>,
) -> Option<(String, String, String)> {
    let env_count = env_base.is_some() as u8 + env_token.is_some() as u8 + env_model.is_some() as u8;
    let base = env_base.or_else(|| default_base.map(str::to_string));
    let model = env_model.or_else(|| default_model.map(str::to_string));
    match (base, env_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        _ => {
            if env_count > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_MODEL_* config for '{id}' \
                     ({env_count} env var(s) set) — a selectable model needs base_url + \
                     auth_token + model_id (base/model may default); treating '{id}' as \
                     UNAVAILABLE."
                );
            }
            None
        }
    }
}

/// Read an optional per-model price deck from `<prefix>_PRICE_IN` / `_PRICE_CACHED` /
/// `_PRICE_OUT` (dollars per 1M tokens). Any missing/unparseable field falls back to the
/// same field of `default`, so a fully-unset prefix yields `default` unchanged.
pub fn model_price_from_env(prefix: &str, default: PriceDeck) -> PriceDeck {
    PriceDeck {
        in_per_m: env_parse(&format!("{prefix}_PRICE_IN"), default.in_per_m),
        cached_per_m: env_parse(&format!("{prefix}_PRICE_CACHED"), default.cached_per_m),
        out_per_m: env_parse(&format!("{prefix}_PRICE_OUT"), default.out_per_m),
    }
}

impl Config {
    pub fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        Config {
            token: env_string("JESSE_TOKEN").unwrap_or_default(),
            // Capture HOME once — session-path lookups read `cfg.home`, not the env.
            home: home.clone(),
            vault: env_string("JESSE_VAULT").unwrap_or_else(|| format!("{home}/vault")),
            bind: env_string("JESSE_BIND").unwrap_or_else(|| "127.0.0.1".to_string()),
            port: env_parse("JESSE_PORT", 8765),
            claude_bin: env_string("JESSE_CLAUDE_BIN").unwrap_or_else(|| "claude".to_string()),
            // 1h default; clamped to [1, HARD_TIMEOUT_CEILING].
            timeout_secs: clamp_timeout_secs(env_parse("JESSE_TIMEOUT", 3600)),
            allowed_tools: env_string("JESSE_ALLOWED_TOOLS")
                .unwrap_or_else(|| DEFAULT_ALLOWED_TOOLS.to_string()),
            disallowed_tools: env_string("JESSE_DISALLOWED_TOOLS")
                .unwrap_or_else(|| DEFAULT_DISALLOWED_TOOLS.to_string()),
            // `>= 1` floor: a parsed 0 falls back to the default (not to a 1-clamp),
            // the long-standing behavior — so kept explicit, not via `env_parse`.
            // Default 1 (single-writer): protects vault files from concurrent
            // rewrites by multiple clients — one turn runs anywhere at a time.
            max_concurrency: std::env::var("JESSE_MAX_CONCURRENCY")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(1),
            // Wait-queue depth; floor 0 (0 → no queue). A parsed value is honored
            // as-is; unset/unparseable → DEFAULT_MAX_QUEUED.
            max_queued: env_parse("JESSE_MAX_QUEUED", DEFAULT_MAX_QUEUED),
            rate_per_min: std::env::var("JESSE_RATE_PER_MIN")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(30),
            job_ttl_secs: env_parse("JESSE_JOB_TTL_SECS", DEFAULT_JOB_TTL_SECS),
            retrieval_grace_secs: env_parse(
                "JESSE_RETRIEVAL_GRACE_SECS",
                DEFAULT_RETRIEVAL_GRACE_SECS,
            ),
            session_ttl_days: env_parse("JESSE_SESSION_TTL_DAYS", DEFAULT_SESSION_TTL_DAYS),
            state_dir: env_string("JESSE_STATE_DIR").or_else(|| {
                // Default: a dotdir under HOME. Empty HOME → no default
                // (persistence off) rather than writing to a bare "/.jesse-bridge".
                (!home.is_empty()).then(|| format!("{home}/.jesse-bridge"))
            }),
            max_attachments: env_parse("JESSE_MAX_ATTACHMENTS", DEFAULT_MAX_ATTACHMENTS),
            max_attachment_bytes: env_parse(
                "JESSE_MAX_ATTACHMENT_BYTES",
                DEFAULT_MAX_ATTACHMENT_BYTES,
            ),
            max_attachments_total_bytes: env_parse(
                "JESSE_MAX_ATTACHMENTS_TOTAL_BYTES",
                DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
            ),
            scratch_dir: env_string("JESSE_SCRATCH_DIR"),
            // All-or-nothing title-backend override. Uses the same `env_string`
            // (trimmed, empty-filtered) semantics as every other string field, so
            // a blank value counts as unset. Partial config logs a warning and
            // resolves to None (see `resolve_title_backend`).
            title_backend: resolve_title_backend(
                env_string("JESSE_TITLE_BASE_URL"),
                env_string("JESSE_TITLE_AUTH_TOKEN"),
                env_string("JESSE_TITLE_MODEL"),
            ),
            // All-or-nothing local diet-extract backend override, same `env_string`
            // (trimmed, empty-filtered) semantics as every other string field. Partial
            // config logs one warning and resolves to None (see `resolve_diet_backend`).
            // Unset (the default) → None → the diet pipeline is dormant and every diet
            // turn takes today's hosted path (the kill switch).
            diet_backend: resolve_diet_backend(
                env_string("JESSE_DIET_BASE_URL"),
                env_string("JESSE_DIET_AUTH_TOKEN"),
                env_string("JESSE_DIET_MODEL"),
            ),
            // Probation defaults to TRUE: the verify gate is mandatory unless an
            // operator explicitly opts out with a falsey JESSE_DIET_PROBATION. Only an
            // explicit false/0/no/off flips it; anything else (including unset) is true.
            diet_probation: std::env::var("JESSE_DIET_PROBATION")
                .ok()
                .map(|v| {
                    let v = v.trim().to_ascii_lowercase();
                    !(v == "0" || v == "false" || v == "no" || v == "off")
                })
                .unwrap_or(true),
            // All-or-nothing local vault-QA backend override, same `env_string`
            // (trimmed, empty-filtered) semantics as every other string field. Partial
            // config logs one warning and resolves to None (see `resolve_vaultqa_backend`).
            // Unset (the default) → None → the vault-QA route is inert and every Ask takes
            // today's hosted path (the kill switch).
            vaultqa_backend: resolve_vaultqa_backend(
                env_string("JESSE_VAULTQA_BASE_URL"),
                env_string("JESSE_VAULTQA_AUTH_TOKEN"),
                env_string("JESSE_VAULTQA_MODEL"),
            ),
            // Optional MCP config path for the vault-QA child (the qmd server). Unset →
            // None → the child runs the read-only built-ins only, qmd absent.
            vaultqa_mcp_config: env_string("JESSE_VAULTQA_MCP_CONFIG"),
            // Provenance badge on delivered replies; default on (see `resolve_model_badge`).
            model_badge: resolve_model_badge(),
            // Structured-metrics log path. Same `env_string` (trimmed, empty-filtered)
            // semantics — a blank value counts as unset → None → zero metrics writes.
            metrics_log: env_string("JESSE_METRICS_LOG"),
            // Emergency local fallback arm; default OFF (see `resolve_emergency_local`).
            emergency_local: resolve_emergency_local(),
            // Context ledger (context carry); default ON (see `resolve_context_carry`).
            context_carry: resolve_context_carry(),
            // All-or-nothing SHADOW-comparison backend override, same `env_string`
            // (trimmed, empty-filtered) semantics as every other string field. Partial
            // config logs one warning and resolves to None (see `resolve_shadow_backend`).
            // Unset (the default) → None → shadow mode is disarmed and not a single ask
            // turn is mirrored (the kill switch).
            shadow_backend: resolve_shadow_backend(
                env_string("JESSE_SHADOW_BASE_URL"),
                env_string("JESSE_SHADOW_AUTH_TOKEN"),
                env_string("JESSE_SHADOW_MODEL"),
            ),
            // Sample percentage of eligible ask turns to mirror; default 100, clamped
            // to [0, 100]. An unset/unparseable value keeps the 100 default.
            shadow_sample_pct: clamp_sample_pct(env_parse("JESSE_SHADOW_SAMPLE_PCT", 100)),
            // Shadow pair log; `~` expanded against the captured HOME, default under
            // `~/Library/Logs/jesse-shadow/`. Only ever written when shadow is armed.
            shadow_log: expand_tilde(
                &env_string("JESSE_SHADOW_LOG")
                    .unwrap_or_else(|| "~/Library/Logs/jesse-shadow/shadow.jsonl".to_string()),
                &home,
            ),
            // Shadow child wall-clock budget; default 120s. A timeout logs an
            // incomplete pair and never retries.
            shadow_timeout_secs: env_parse("JESSE_SHADOW_TIMEOUT_SECS", 120),
            // Personalization overlay: generic defaults → jesse.local.toml → env.
            // Resolved once at startup against the captured HOME (used to find the
            // state-dir config location for a launchd service outside the repo).
            persona: Persona::load(&home),
            // The selectable-model registry, MERGED from the built-in ambient opus, the
            // JESSE_MODEL_* env triples, and the declarative `[[models]]` config file (see
            // ModelRegistry::from_env). Always includes the ambient opus default; the other
            // entries are unconfigured (present, not selectable) until their token resolves.
            model_registry: ModelRegistry::from_env(&home),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn env_string_trims_and_filters_empty() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_ENV_STRING", "  hi  ");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING").as_deref(), Some("hi"));
        // A blank/whitespace value is treated as unset — the consistency the fix
        // establishes across every string field.
        std::env::set_var("JESSE_TEST_ENV_STRING", "   ");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING"), None);
        std::env::remove_var("JESSE_TEST_ENV_STRING");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING"), None);
    }

    #[test]
    fn env_parse_falls_back_on_unset_or_unparseable() {
        let _g = ENV_LOCK.lock_ok();
        std::env::remove_var("JESSE_TEST_ENV_PARSE");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 7);
        std::env::set_var("JESSE_TEST_ENV_PARSE", "42");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 42);
        std::env::set_var("JESSE_TEST_ENV_PARSE", "not-a-number");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 7);
        std::env::remove_var("JESSE_TEST_ENV_PARSE");
    }

    #[test]
    fn resolve_model_backend_all_or_nothing_with_defaults() {
        // GLM-shape: base + model DEFAULT, only the token supplied → available.
        let glm = resolve_model_backend(
            "glm-5.2",
            None,
            Some("tok".into()),
            None,
            Some("https://api.fireworks.ai/inference"),
            Some("accounts/fireworks/models/glm-5p2"),
        );
        assert_eq!(
            glm,
            Some((
                "https://api.fireworks.ai/inference".into(),
                "tok".into(),
                "accounts/fireworks/models/glm-5p2".into()
            )),
            "token-only arms a defaulted hosted model"
        );
        // No token → unavailable, even though base/model default.
        assert_eq!(
            resolve_model_backend(
                "glm-5.2",
                None,
                None,
                None,
                Some("https://api.fireworks.ai/inference"),
                Some("accounts/fireworks/models/glm-5p2"),
            ),
            None,
            "no token → unavailable"
        );
        // No defaults (kimi/local): all three required.
        assert_eq!(
            resolve_model_backend("local", Some("http://l".into()), Some("t".into()), None, None, None),
            None,
            "a partial no-default triple is unavailable, never partial"
        );
        assert_eq!(
            resolve_model_backend(
                "local",
                Some("http://l".into()),
                Some("t".into()),
                Some("m".into()),
                None,
                None
            ),
            Some(("http://l".into(), "t".into(), "m".into())),
        );
    }

    #[test]
    fn opus_only_registry_is_just_the_ambient_default() {
        let r = ModelRegistry::opus_only();
        assert_eq!(r.models.len(), 1);
        let opus = r.default_model();
        assert_eq!(opus.id, "opus");
        assert!(matches!(opus.kind, ModelKind::Ambient));
        assert!(opus.configured && opus.default_writes);
        assert!(!r.is_configured("glm-5.2"), "an absent model is not configured");
    }

    #[test]
    fn config_from_env_defaults() {
        let _guard = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = [
            "JESSE_TOKEN",
            "JESSE_VAULT",
            "JESSE_BIND",
            "JESSE_PORT",
            "JESSE_CLAUDE_BIN",
            "JESSE_TIMEOUT",
            "JESSE_MAX_CONCURRENCY",
            "JESSE_MAX_QUEUED",
            "JESSE_JOB_TTL_SECS",
            "JESSE_RETRIEVAL_GRACE_SECS",
            "JESSE_STATE_DIR",
            "JESSE_MAX_ATTACHMENTS",
            "JESSE_MAX_ATTACHMENT_BYTES",
            "JESSE_MAX_ATTACHMENTS_TOTAL_BYTES",
            "JESSE_SCRATCH_DIR",
        ]
        .iter()
        .map(|k| (*k, std::env::var(k).ok()))
        .collect();
        for (k, _) in &saved {
            std::env::remove_var(k);
        }

        let cfg = Config::from_env();
        assert_eq!(cfg.token, "");
        assert_eq!(cfg.bind, "127.0.0.1");
        assert_eq!(cfg.port, 8765);
        assert_eq!(cfg.claude_bin, "claude");
        assert_eq!(cfg.timeout_secs, 3600);
        // Single-writer default: one turn runs at a time; a burst of up to
        // DEFAULT_MAX_QUEUED waits behind it rather than being rejected.
        assert_eq!(cfg.max_concurrency, 1);
        assert_eq!(cfg.max_queued, DEFAULT_MAX_QUEUED);
        // Eviction defaults: 24h hold for an unfetched reply, short post-fetch grace.
        assert_eq!(cfg.job_ttl_secs, DEFAULT_JOB_TTL_SECS);
        assert_eq!(cfg.retrieval_grace_secs, DEFAULT_RETRIEVAL_GRACE_SECS);
        // No JESSE_STATE_DIR → persistence defaults to a dotdir under HOME (when
        // HOME is set), with job files under `<state_dir>/jobs`.
        match std::env::var("HOME").ok().filter(|h| !h.is_empty()) {
            Some(home) => {
                assert_eq!(
                    cfg.state_dir.as_deref(),
                    Some(format!("{home}/.jesse-bridge").as_str())
                );
                assert_eq!(
                    cfg.jobs_dir(),
                    Some(PathBuf::from(format!("{home}/.jesse-bridge/jobs")))
                );
            }
            None => {
                assert_eq!(cfg.state_dir, None);
                assert_eq!(cfg.jobs_dir(), None);
            }
        }
        assert_eq!(cfg.max_attachments, DEFAULT_MAX_ATTACHMENTS);
        assert_eq!(cfg.max_attachment_bytes, DEFAULT_MAX_ATTACHMENT_BYTES);
        assert_eq!(
            cfg.max_attachments_total_bytes,
            DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES
        );
        // No JESSE_SCRATCH_DIR → scratch base falls back to the system temp dir.
        assert_eq!(cfg.scratch_dir, None);
        assert_eq!(cfg.scratch_base(), std::env::temp_dir());

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
    #[test]
    fn timeout_clamp_treats_zero_as_ceiling() {
        // 0 means "ceiling", never unlimited.
        assert_eq!(clamp_timeout_secs(0), HARD_TIMEOUT_CEILING);
        // Over-ceiling is capped; in-range is unchanged; 1 is the floor.
        assert_eq!(
            clamp_timeout_secs(HARD_TIMEOUT_CEILING + 10),
            HARD_TIMEOUT_CEILING
        );
        assert_eq!(clamp_timeout_secs(1800), 1800);
        assert_eq!(clamp_timeout_secs(1), 1);
    }
    #[test]
    fn config_zero_timeout_clamps_to_ceiling() {
        let _guard = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_TIMEOUT").ok();
        std::env::set_var("JESSE_TIMEOUT", "0");
        let cfg = Config::from_env();
        assert_eq!(cfg.timeout_secs, HARD_TIMEOUT_CEILING);
        match saved {
            Some(v) => std::env::set_var("JESSE_TIMEOUT", v),
            None => std::env::remove_var("JESSE_TIMEOUT"),
        }
    }
    #[test]
    fn title_backend_resolves_only_when_all_three_present() {
        // All-or-nothing: the override resolves ONLY when base_url, auth_token,
        // AND model are all set. This is the load-bearing "partial config is
        // treated as unset" rule — any missing part falls back to the ambient
        // backend so a half-configured deploy never silently half-redirects.
        let full = resolve_title_backend(
            Some("http://127.0.0.1:9100".into()),
            Some("dummy-tok".into()),
            Some("local-title".into()),
        );
        assert_eq!(
            full,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "dummy-tok".to_string(),
                "local-title".to_string(),
            ))
        );
        // Every partial combination (1 or 2 of 3 set) resolves to None.
        let s = || Some("x".to_string());
        let partials = [
            (s(), s(), None),
            (s(), None, s()),
            (None, s(), s()),
            (s(), None, None),
            (None, s(), None),
            (None, None, s()),
            (None, None, None),
        ];
        for (b, t, m) in partials {
            assert_eq!(
                resolve_title_backend(b, t, m),
                None,
                "partial title config must resolve to None (treated as unset)"
            );
        }
    }

    #[test]
    fn config_from_env_title_backend_all_or_nothing() {
        let _g = ENV_LOCK.lock_ok();
        let keys = [
            "JESSE_TITLE_BASE_URL",
            "JESSE_TITLE_AUTH_TOKEN",
            "JESSE_TITLE_MODEL",
        ];
        let saved: Vec<(&str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in &keys {
            std::env::remove_var(k);
        }

        // Unset by default → no override.
        assert_eq!(Config::from_env().title_backend, None);

        // All three set → the config carries the resolved triple.
        std::env::set_var("JESSE_TITLE_BASE_URL", "http://127.0.0.1:9100");
        std::env::set_var("JESSE_TITLE_AUTH_TOKEN", "dsv4-local-dummy");
        std::env::set_var("JESSE_TITLE_MODEL", "local-title");
        assert_eq!(
            Config::from_env().title_backend,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "dsv4-local-dummy".to_string(),
                "local-title".to_string(),
            ))
        );

        // Drop one → partial → None (treated as unset).
        std::env::remove_var("JESSE_TITLE_AUTH_TOKEN");
        assert_eq!(Config::from_env().title_backend, None);

        // A blank/whitespace value counts as unset (env_string semantics), so a
        // set-but-empty var is still a partial config → None.
        std::env::set_var("JESSE_TITLE_AUTH_TOKEN", "   ");
        assert_eq!(Config::from_env().title_backend, None);

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn diet_backend_resolves_only_when_all_three_present() {
        // All-or-nothing, mirroring the title backend: the diet-extract override
        // resolves ONLY when base_url, auth_token, AND model are all set. Any missing
        // part falls back to None so the pipeline stays dormant (the kill switch).
        let full = resolve_diet_backend(
            Some("http://127.0.0.1:9100".into()),
            Some("dummy-tok".into()),
            Some("local-diet".into()),
        );
        assert_eq!(
            full,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "dummy-tok".to_string(),
                "local-diet".to_string(),
            ))
        );
        // Every partial combination (1 or 2 of 3 set) resolves to None.
        let s = || Some("x".to_string());
        let partials = [
            (s(), s(), None),
            (s(), None, s()),
            (None, s(), s()),
            (s(), None, None),
            (None, s(), None),
            (None, None, s()),
            (None, None, None),
        ];
        for (b, t, m) in partials {
            assert_eq!(
                resolve_diet_backend(b, t, m),
                None,
                "partial diet config must resolve to None (treated as unset)"
            );
        }
    }

    #[test]
    fn config_from_env_diet_backend_all_or_nothing_and_probation_default_true() {
        let _g = ENV_LOCK.lock_ok();
        let keys = [
            "JESSE_DIET_BASE_URL",
            "JESSE_DIET_AUTH_TOKEN",
            "JESSE_DIET_MODEL",
            "JESSE_DIET_PROBATION",
        ];
        let saved: Vec<(&str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in &keys {
            std::env::remove_var(k);
        }

        // Unset by default → no override, and probation defaults to TRUE.
        let cfg = Config::from_env();
        assert_eq!(cfg.diet_backend, None);
        assert!(cfg.diet_probation, "probation must default to true");

        // All three set → the config carries the resolved triple.
        std::env::set_var("JESSE_DIET_BASE_URL", "http://127.0.0.1:9100");
        std::env::set_var("JESSE_DIET_AUTH_TOKEN", "dsv4-diet-dummy");
        std::env::set_var("JESSE_DIET_MODEL", "local-diet");
        assert_eq!(
            Config::from_env().diet_backend,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "dsv4-diet-dummy".to_string(),
                "local-diet".to_string(),
            ))
        );

        // Drop one → partial → None (treated as unset).
        std::env::remove_var("JESSE_DIET_AUTH_TOKEN");
        assert_eq!(Config::from_env().diet_backend, None);

        // A blank/whitespace value counts as unset (env_string semantics).
        std::env::set_var("JESSE_DIET_AUTH_TOKEN", "   ");
        assert_eq!(Config::from_env().diet_backend, None);

        // Probation: only an explicit falsey value flips it to false.
        for falsey in ["0", "false", "no", "off", "FALSE", " Off "] {
            std::env::set_var("JESSE_DIET_PROBATION", falsey);
            assert!(
                !Config::from_env().diet_probation,
                "explicit {falsey:?} must disable probation"
            );
        }
        for truthy in ["1", "true", "yes", "on", "anything-else"] {
            std::env::set_var("JESSE_DIET_PROBATION", truthy);
            assert!(
                Config::from_env().diet_probation,
                "{truthy:?} must keep probation on"
            );
        }

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn vaultqa_backend_resolves_only_when_all_three_present() {
        // All-or-nothing, mirroring the diet/title backends: the vault-QA override
        // resolves ONLY when base_url, auth_token, AND model are all set. Any missing
        // part falls back to None so the route stays inert (the kill switch).
        let full = resolve_vaultqa_backend(
            Some("http://127.0.0.1:9100".into()),
            Some("dummy-tok".into()),
            Some("local-vaultqa".into()),
        );
        assert_eq!(
            full,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "dummy-tok".to_string(),
                "local-vaultqa".to_string(),
            ))
        );
        // Every partial combination (1 or 2 of 3 set) resolves to None.
        let s = || Some("x".to_string());
        let partials = [
            (s(), s(), None),
            (s(), None, s()),
            (None, s(), s()),
            (s(), None, None),
            (None, s(), None),
            (None, None, s()),
            (None, None, None),
        ];
        for (b, t, m) in partials {
            assert_eq!(
                resolve_vaultqa_backend(b, t, m),
                None,
                "partial vault-QA config must resolve to None (treated as unset)"
            );
        }
    }

    #[test]
    fn config_from_env_vaultqa_backend_all_or_nothing_and_mcp_and_badge() {
        let _g = ENV_LOCK.lock_ok();
        let keys = [
            "JESSE_VAULTQA_BASE_URL",
            "JESSE_VAULTQA_AUTH_TOKEN",
            "JESSE_VAULTQA_MODEL",
            "JESSE_VAULTQA_MCP_CONFIG",
            "JESSE_MODEL_BADGE",
        ];
        let saved: Vec<(&str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in &keys {
            std::env::remove_var(k);
        }

        // Unset by default → no override, MCP config absent, badge ON.
        let cfg = Config::from_env();
        assert_eq!(cfg.vaultqa_backend, None);
        assert_eq!(cfg.vaultqa_mcp_config, None);
        assert!(cfg.model_badge, "badge must default to on");

        // All three set → the config carries the resolved triple; MCP path honored.
        std::env::set_var("JESSE_VAULTQA_BASE_URL", "http://127.0.0.1:9100");
        std::env::set_var("JESSE_VAULTQA_AUTH_TOKEN", "vaultqa-dummy-tok");
        std::env::set_var("JESSE_VAULTQA_MODEL", "local-vaultqa");
        std::env::set_var("JESSE_VAULTQA_MCP_CONFIG", "/etc/jesse/qmd.json");
        let cfg = Config::from_env();
        assert_eq!(
            cfg.vaultqa_backend,
            Some((
                "http://127.0.0.1:9100".to_string(),
                "vaultqa-dummy-tok".to_string(),
                "local-vaultqa".to_string(),
            ))
        );
        assert_eq!(
            cfg.vaultqa_mcp_config.as_deref(),
            Some("/etc/jesse/qmd.json")
        );

        // Drop one → partial → None (treated as unset); a blank value counts as unset.
        std::env::remove_var("JESSE_VAULTQA_AUTH_TOKEN");
        assert_eq!(Config::from_env().vaultqa_backend, None);
        std::env::set_var("JESSE_VAULTQA_AUTH_TOKEN", "   ");
        assert_eq!(Config::from_env().vaultqa_backend, None);

        // Badge: only an explicit falsey value flips it off.
        for falsey in ["0", "false", "no", "off", "OFF", " Off "] {
            std::env::set_var("JESSE_MODEL_BADGE", falsey);
            assert!(
                !Config::from_env().model_badge,
                "explicit {falsey:?} disables the badge"
            );
        }
        for truthy in ["1", "true", "yes", "on", "anything-else"] {
            std::env::set_var("JESSE_MODEL_BADGE", truthy);
            assert!(
                Config::from_env().model_badge,
                "{truthy:?} keeps the badge on"
            );
        }

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn shadow_backend_resolves_only_when_all_three_present() {
        let full = resolve_shadow_backend(
            Some("https://gw.example".into()),
            Some("gw-tok".into()),
            Some("fw-glm".into()),
        );
        assert_eq!(
            full,
            Some((
                "https://gw.example".to_string(),
                "gw-tok".to_string(),
                "fw-glm".to_string(),
            ))
        );
        // Every partial combination (1 or 2 of 3 set) resolves to None — the kill
        // switch: unset any one var and not a single turn is mirrored.
        let s = || Some("x".to_string());
        let partials = [
            (s(), s(), None),
            (s(), None, s()),
            (None, s(), s()),
            (s(), None, None),
            (None, s(), None),
            (None, None, s()),
            (None, None, None),
        ];
        for (b, t, m) in partials {
            assert_eq!(
                resolve_shadow_backend(b, t, m),
                None,
                "partial shadow config must resolve to None (treated as unset)"
            );
        }
    }

    #[test]
    fn shadow_sample_pct_clamps_to_0_100() {
        assert_eq!(clamp_sample_pct(0), 0);
        assert_eq!(clamp_sample_pct(50), 50);
        assert_eq!(clamp_sample_pct(100), 100);
        // Over-range saturates to 100 rather than disabling sampling.
        assert_eq!(clamp_sample_pct(101), 100);
        assert_eq!(clamp_sample_pct(1_000_000), 100);
    }

    #[test]
    fn expand_tilde_expands_leading_home_only() {
        assert_eq!(expand_tilde("~", "/Users/j"), "/Users/j");
        assert_eq!(
            expand_tilde("~/Library/Logs/x.jsonl", "/Users/j"),
            "/Users/j/Library/Logs/x.jsonl"
        );
        // An already-absolute path is untouched, as is a `~user` form.
        assert_eq!(expand_tilde("/var/log/x", "/Users/j"), "/var/log/x");
        assert_eq!(expand_tilde("~bob/x", "/Users/j"), "~bob/x");
        // Empty HOME leaves the value verbatim (no bare-"/…" default).
        assert_eq!(expand_tilde("~/x", ""), "~/x");
    }

    #[test]
    fn config_from_env_shadow_all_or_nothing_and_knobs() {
        let _g = ENV_LOCK.lock_ok();
        let keys = [
            "JESSE_SHADOW_BASE_URL",
            "JESSE_SHADOW_AUTH_TOKEN",
            "JESSE_SHADOW_MODEL",
            "JESSE_SHADOW_SAMPLE_PCT",
            "JESSE_SHADOW_LOG",
            "JESSE_SHADOW_TIMEOUT_SECS",
        ];
        let saved: Vec<(&str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in &keys {
            std::env::remove_var(k);
        }

        // Unset by default → disarmed; knobs take their defaults.
        let cfg = Config::from_env();
        assert_eq!(cfg.shadow_backend, None);
        assert_eq!(cfg.shadow_sample_pct, 100);
        assert_eq!(cfg.shadow_timeout_secs, 120);
        assert!(
            cfg.shadow_log
                .ends_with("/Library/Logs/jesse-shadow/shadow.jsonl"),
            "default shadow log path expanded under HOME: {}",
            cfg.shadow_log
        );
        assert!(!cfg.shadow_log.starts_with('~'), "the ~ must be expanded");

        // All three set → armed triple; knobs honored + clamped.
        std::env::set_var("JESSE_SHADOW_BASE_URL", "https://gw.example");
        std::env::set_var("JESSE_SHADOW_AUTH_TOKEN", "gw-tok");
        std::env::set_var("JESSE_SHADOW_MODEL", "fw-glm");
        std::env::set_var("JESSE_SHADOW_SAMPLE_PCT", "250"); // clamps to 100
        std::env::set_var("JESSE_SHADOW_TIMEOUT_SECS", "45");
        std::env::set_var("JESSE_SHADOW_LOG", "/tmp/jesse-shadow-test/shadow.jsonl");
        let cfg = Config::from_env();
        assert_eq!(
            cfg.shadow_backend,
            Some((
                "https://gw.example".to_string(),
                "gw-tok".to_string(),
                "fw-glm".to_string(),
            ))
        );
        assert_eq!(cfg.shadow_sample_pct, 100);
        assert_eq!(cfg.shadow_timeout_secs, 45);
        assert_eq!(cfg.shadow_log, "/tmp/jesse-shadow-test/shadow.jsonl");

        // Drop one → partial → None (treated as unset); a blank counts as unset.
        std::env::remove_var("JESSE_SHADOW_MODEL");
        assert_eq!(Config::from_env().shadow_backend, None);
        std::env::set_var("JESSE_SHADOW_MODEL", "   ");
        assert_eq!(Config::from_env().shadow_backend, None);

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn session_ttl_days_defaults_to_90_and_honors_env() {
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_SESSION_TTL_DAYS").ok();
        std::env::remove_var("JESSE_SESSION_TTL_DAYS");
        assert_eq!(
            Config::from_env().session_ttl_days,
            DEFAULT_SESSION_TTL_DAYS
        );
        assert_eq!(DEFAULT_SESSION_TTL_DAYS, 90);
        std::env::set_var("JESSE_SESSION_TTL_DAYS", "30");
        assert_eq!(Config::from_env().session_ttl_days, 30);
        // Unparseable falls back to the default.
        std::env::set_var("JESSE_SESSION_TTL_DAYS", "nope");
        assert_eq!(
            Config::from_env().session_ttl_days,
            DEFAULT_SESSION_TTL_DAYS
        );
        match saved {
            Some(v) => std::env::set_var("JESSE_SESSION_TTL_DAYS", v),
            None => std::env::remove_var("JESSE_SESSION_TTL_DAYS"),
        }
    }

    #[test]
    fn max_queued_honors_env_including_explicit_zero() {
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_MAX_QUEUED").ok();
        // Explicit 0 is honored (floor 0 → no queue), not folded to the default.
        std::env::set_var("JESSE_MAX_QUEUED", "0");
        assert_eq!(Config::from_env().max_queued, 0);
        std::env::set_var("JESSE_MAX_QUEUED", "9");
        assert_eq!(Config::from_env().max_queued, 9);
        // Unparseable falls back to the default.
        std::env::set_var("JESSE_MAX_QUEUED", "nope");
        assert_eq!(Config::from_env().max_queued, DEFAULT_MAX_QUEUED);
        match saved {
            Some(v) => std::env::set_var("JESSE_MAX_QUEUED", v),
            None => std::env::remove_var("JESSE_MAX_QUEUED"),
        }
    }

    #[test]
    fn scratch_base_defaults_to_temp_and_honors_override() {
        let mut cfg = test_config();
        cfg.scratch_dir = None;
        assert_eq!(cfg.scratch_base(), std::env::temp_dir());
        cfg.scratch_dir = Some("/var/jesse-scratch".to_string());
        assert_eq!(cfg.scratch_base(), PathBuf::from("/var/jesse-scratch"));
    }

    #[test]
    fn vaultqa_timeout_raised_to_cover_the_measured_oss_lookup_range() {
        // Piece 2: 25 → 60. The vaultqa-v1 bake-off measured oss lookups at 10–42 s
        // wall; a 25 s ceiling would have starved most real lookups (rung-2 timeouts).
        // 60 s clears the measured 42 s max with headroom. Emergency's best-effort rung
        // gets a looser 120 s (no ladder below it).
        assert_eq!(VAULTQA_TIMEOUT_SECS, 60);
        // Must clear the measured 42 s oss lookup max (a `let` binding keeps clippy from
        // folding the const comparison to a trivially-true assert).
        let measured_oss_max_secs = 42u64;
        assert!(
            VAULTQA_TIMEOUT_SECS >= measured_oss_max_secs,
            "must clear the measured oss max"
        );
        assert_eq!(EMERGENCY_TIMEOUT_SECS, 120);
    }

    #[test]
    fn metrics_log_resolves_from_env_and_is_none_when_unset() {
        // Piece 3: JESSE_METRICS_LOG = an absolute file path; unset → None (dormant,
        // zero metrics writes), same soft-failure semantics as the other envs. A blank
        // value counts as unset via the shared `env_string` rule.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_METRICS_LOG").ok();
        std::env::remove_var("JESSE_METRICS_LOG");
        assert_eq!(Config::from_env().metrics_log, None);
        std::env::set_var("JESSE_METRICS_LOG", "/var/log/jesse/metrics.jsonl");
        assert_eq!(
            Config::from_env().metrics_log.as_deref(),
            Some("/var/log/jesse/metrics.jsonl")
        );
        std::env::set_var("JESSE_METRICS_LOG", "   ");
        assert_eq!(
            Config::from_env().metrics_log,
            None,
            "blank counts as unset"
        );
        match saved {
            Some(v) => std::env::set_var("JESSE_METRICS_LOG", v),
            None => std::env::remove_var("JESSE_METRICS_LOG"),
        }
    }

    #[test]
    fn emergency_local_defaults_off_and_only_on_enables() {
        // Piece 4: JESSE_EMERGENCY_LOCAL = on|off, default OFF. Unlike the badge/
        // probation truthiness rule (default on), this defaults OFF — only an explicit
        // truthy value enables it, so a half-configured deploy stays inert.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_EMERGENCY_LOCAL").ok();
        std::env::remove_var("JESSE_EMERGENCY_LOCAL");
        assert!(!Config::from_env().emergency_local, "default off");
        for truthy in ["on", "1", "true", "yes", "ON", " On "] {
            std::env::set_var("JESSE_EMERGENCY_LOCAL", truthy);
            assert!(
                Config::from_env().emergency_local,
                "explicit {truthy:?} enables"
            );
        }
        for falsey in ["off", "0", "false", "no", "", "  ", "garbage"] {
            std::env::set_var("JESSE_EMERGENCY_LOCAL", falsey);
            assert!(
                !Config::from_env().emergency_local,
                "{falsey:?} leaves emergency off"
            );
        }
        match saved {
            Some(v) => std::env::set_var("JESSE_EMERGENCY_LOCAL", v),
            None => std::env::remove_var("JESSE_EMERGENCY_LOCAL"),
        }
    }

    #[test]
    fn context_carry_defaults_on_and_only_explicit_falsey_disables() {
        // Context carry fixes a live defect, so it defaults ON (the badge/probation
        // truthiness rule): only an explicit off/0/false/no flips it off — the
        // rollback switch. Unset or any other value keeps it on.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_CONTEXT_CARRY").ok();
        std::env::remove_var("JESSE_CONTEXT_CARRY");
        assert!(Config::from_env().context_carry, "default on");
        for falsey in ["0", "false", "no", "off", "OFF", " Off "] {
            std::env::set_var("JESSE_CONTEXT_CARRY", falsey);
            assert!(
                !Config::from_env().context_carry,
                "explicit {falsey:?} disables (rollback)"
            );
        }
        for truthy in ["1", "true", "yes", "on", "anything-else"] {
            std::env::set_var("JESSE_CONTEXT_CARRY", truthy);
            assert!(
                Config::from_env().context_carry,
                "{truthy:?} keeps carry on"
            );
        }
        // The persistence path is a sibling of titles.json, and None with no state dir.
        let mut cfg = Config::from_env();
        cfg.state_dir = Some("/var/jesse".to_string());
        assert_eq!(
            cfg.context_file(),
            Some(PathBuf::from("/var/jesse/context.json"))
        );
        cfg.state_dir = None;
        assert_eq!(cfg.context_file(), None);
        match saved {
            Some(v) => std::env::set_var("JESSE_CONTEXT_CARRY", v),
            None => std::env::remove_var("JESSE_CONTEXT_CARRY"),
        }
    }

    // ---- Declarative `[[models]]` config + the three-source merge (Part B) -------

    /// A minimal declarative model entry with the four required fields; `token_env` names the
    /// (optional) auth-token env var. Every other field defaults.
    fn model_toml(id: &str, kind: &str, token_env: Option<&str>) -> ModelToml {
        ModelToml {
            id: Some(id.into()),
            kind: Some(kind.into()),
            base_url: Some("https://gw.example/inference".into()),
            model: Some("provider/model".into()),
            auth_token_env: token_env.map(str::to_string),
            ..Default::default()
        }
    }

    /// The nine `JESSE_MODEL_*` env-triple vars, cleared so a test's registry is deterministic.
    const MODEL_ENV_VARS: [&str; 9] = [
        "JESSE_MODEL_GLM_BASE_URL",
        "JESSE_MODEL_GLM_AUTH_TOKEN",
        "JESSE_MODEL_GLM_MODEL",
        "JESSE_MODEL_KIMI_BASE_URL",
        "JESSE_MODEL_KIMI_AUTH_TOKEN",
        "JESSE_MODEL_KIMI_MODEL",
        "JESSE_MODEL_LOCAL_BASE_URL",
        "JESSE_MODEL_LOCAL_AUTH_TOKEN",
        "JESSE_MODEL_LOCAL_MODEL",
    ];

    #[test]
    fn declarative_model_arms_only_when_its_token_env_is_set() {
        // auth_token_env is the NAME of a var; the token is resolved from the process env at
        // build time. A set var arms the model (configured, backend resolved, subagent model
        // defaulting to the main model). An unset var (or none at all) yields a
        // configured-but-unarmed entry — present in the list, not selectable.
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_DECL_TOKEN", "sk-abc");
        let armed =
            registry_model_from_toml(&model_toml("fireworks", "hosted", Some("JESSE_TEST_DECL_TOKEN")))
                .expect("a full entry parses");
        assert!(armed.configured, "a set token env arms the model");
        assert_eq!(
            armed.backend,
            Some((
                "https://gw.example/inference".into(),
                "sk-abc".into(),
                "provider/model".into()
            ))
        );
        assert_eq!(armed.subagent_model.as_deref(), Some("provider/model"));
        assert!(matches!(armed.kind, ModelKind::Hosted));
        assert!(!armed.default_writes, "non-ambient defaults read-only");

        std::env::remove_var("JESSE_TEST_DECL_TOKEN");
        let unarmed =
            registry_model_from_toml(&model_toml("fireworks", "hosted", Some("JESSE_TEST_DECL_TOKEN")))
                .expect("still parses, just unarmed");
        assert!(!unarmed.configured, "an unset token env → unarmed");
        assert!(unarmed.backend.is_none(), "no backend without a token");
        assert!(unarmed.subagent_model.is_none(), "no backend-derived subagent model");

        let no_env = registry_model_from_toml(&model_toml("fireworks", "hosted", None)).unwrap();
        assert!(!no_env.configured, "no auth_token_env at all → unarmed");
    }

    #[test]
    fn declarative_model_parses_price_subagent_and_health_overrides() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_DECL_TOKEN2", "tok");
        let t = ModelToml {
            id: Some("codex".into()),
            label: Some("Codex".into()),
            kind: Some("local".into()),
            base_url: Some("http://127.0.0.1:8900".into()),
            model: Some("gpt-5-codex".into()),
            subagent_model: Some("gpt-5-mini".into()),
            auth_token_env: Some("JESSE_TEST_DECL_TOKEN2".into()),
            default_writes: Some(true),
            price: Some(PriceToml {
                in_per_m: Some(2.0),
                cached_per_m: Some(0.2),
                out_per_m: Some(8.0),
            }),
            health: Some(HealthToml {
                path: Some("/v1/messages".into()),
                interval_secs: Some(30),
                timeout_secs: Some(2),
            }),
        };
        let m = registry_model_from_toml(&t).unwrap();
        assert!(matches!(m.kind, ModelKind::Local));
        assert_eq!(m.label, "Codex");
        assert_eq!(m.subagent_model.as_deref(), Some("gpt-5-mini"), "explicit subagent override");
        assert!(m.default_writes, "declarative default_writes honored");
        assert_eq!(m.price.out_per_m, 8.0);
        assert_eq!(m.health.interval_secs, 30);
        assert_eq!(m.health.timeout_secs, 2);
        std::env::remove_var("JESSE_TEST_DECL_TOKEN2");
    }

    #[test]
    fn declarative_model_rejects_missing_fields_and_reserved_kind() {
        // A missing required field → the entry is skipped (None), never a partial model.
        let mut missing_model = model_toml("x", "hosted", Some("V"));
        missing_model.model = None;
        assert!(registry_model_from_toml(&missing_model).is_none());
        // `ambient` is reserved for the built-in opus; an unknown kind is invalid too.
        assert!(registry_model_from_toml(&model_toml("x", "ambient", Some("V"))).is_none());
        assert!(registry_model_from_toml(&model_toml("x", "banana", Some("V"))).is_none());
    }

    #[test]
    fn upsert_replaces_by_id_in_place_and_protects_the_ambient_default() {
        // The merge primitive: later overrides earlier BY ID (in place, stable order), a new
        // id appends, and the ambient `opus` is never replaceable.
        let mut models = vec![opus_entry(), glm_env_entry()]; // glm unconfigured (no env)
        let mut decl_glm = model_toml("glm-5.2", "hosted", None);
        decl_glm.label = Some("Declared GLM".into());
        upsert_model(&mut models, registry_model_from_toml(&decl_glm).unwrap());
        assert_eq!(models.len(), 2, "same id replaces in place, not appends");
        assert_eq!(models[1].id, "glm-5.2");
        assert_eq!(models[1].label, "Declared GLM", "later source wins by id");

        upsert_model(&mut models, registry_model_from_toml(&model_toml("fw", "hosted", None)).unwrap());
        assert_eq!(models.len(), 3, "a new id appends");

        // An entry that tries to redefine opus is refused; opus stays the built-in ambient.
        let fake_opus = registry_model_from_toml(&model_toml("opus", "hosted", None)).unwrap();
        upsert_model(&mut models, fake_opus);
        assert_eq!(models.iter().filter(|m| m.id == "opus").count(), 1);
        assert!(matches!(models[0].kind, ModelKind::Ambient), "opus stays ambient");
    }

    #[test]
    fn from_env_with_no_model_config_is_todays_behavior_opus_only_selectable() {
        // With no JESSE_MODEL_* and no [[models]], the ONLY selectable (configured) model is
        // opus — byte-for-byte today: opus present + configured, and the preserved env-triple
        // placeholders (glm/kimi/local) present but UNCONFIGURED (not selectable). No
        // declarative entry appears.
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(["JESSE_CONFIG", "JESSE_STATE_DIR"].iter())
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        std::env::set_var("JESSE_CONFIG", "/nonexistent/jesse.local.toml");

        let r = ModelRegistry::from_env("");
        assert_eq!(r.models[0].id, "opus");
        assert!(matches!(r.models[0].kind, ModelKind::Ambient));
        assert!(r.is_configured("opus"), "opus is the only configured model");
        for id in ["glm-5.2", "kimi-k3", "local"] {
            let m = r.get(id).unwrap_or_else(|| panic!("{id} preserved as a placeholder"));
            assert!(!m.configured, "{id} is present but not configured with no env");
        }
        assert_eq!(r.models.len(), 4, "no declarative entries appear with no config");

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn from_env_merges_a_declarative_models_file_and_overrides_env_by_id() {
        // Source 3: a [[models]] file. An armed declarative entry becomes configured; an
        // unarmed one (missing token var) is present-but-unconfigured; and a declarative entry
        // with an env-triple's id OVERRIDES it (later source wins).
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(["JESSE_CONFIG", "JESSE_STATE_DIR"].iter())
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        // Arm the env glm so we can prove the declarative override REPLACES it.
        std::env::set_var("JESSE_MODEL_GLM_AUTH_TOKEN", "env-glm-tok");
        std::env::set_var("JESSE_TEST_FW_TOKEN", "sk-fw");

        let dir = std::env::temp_dir().join(format!("jesse-decl-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            r#"
[[models]]
id = "fireworks"
label = "Fireworks GLM"
kind = "hosted"
base_url = "https://gw.example/inference"
model = "accounts/fireworks/models/glm"
auth_token_env = "JESSE_TEST_FW_TOKEN"
price = { in_per_m = 1.4, cached_per_m = 0.14, out_per_m = 4.4 }
health = { interval_secs = 30, timeout_secs = 2 }

[[models]]
id = "codex"
kind = "hosted"
base_url = "http://127.0.0.1:8900"
model = "gpt-5-codex"
auth_token_env = "JESSE_TEST_MISSING_TOKEN"

[[models]]
id = "glm-5.2"
label = "Override GLM"
kind = "hosted"
base_url = "http://override"
model = "override-model"
auth_token_env = "JESSE_TEST_FW_TOKEN"
"#,
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let r = ModelRegistry::from_env("");
        assert_eq!(r.models[0].id, "opus", "opus stays first");

        // Armed declarative model → configured, price + health parsed, token held only in backend.
        let fw = r.get("fireworks").expect("fireworks appears");
        assert!(fw.configured);
        assert_eq!(fw.backend.as_ref().unwrap().1, "sk-fw");
        assert_eq!(fw.price.out_per_m, 4.4);
        assert_eq!(fw.health.interval_secs, 30);
        assert_eq!(fw.health.timeout_secs, 2);

        // Unarmed declarative model (missing token var) → present but not configured.
        let codex = r.get("codex").expect("codex appears");
        assert!(!codex.configured);
        assert!(codex.backend.is_none());

        // Declarative glm-5.2 OVERRODE the env glm (later source wins), exactly one entry.
        let glm = r.get("glm-5.2").unwrap();
        assert_eq!(glm.label, "Override GLM");
        assert_eq!(glm.backend.as_ref().unwrap().0, "http://override");
        assert_eq!(r.models.iter().filter(|m| m.id == "glm-5.2").count(), 1);

        std::env::remove_var("JESSE_TEST_FW_TOKEN");
        let _ = std::fs::remove_dir_all(&dir);
        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
}
