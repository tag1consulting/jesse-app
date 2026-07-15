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

// Hard timeout (seconds) for the contained read-only vault-QA child. Tighter
// than a turn: the child reads a handful of vault files (Read/Grep/Glob, and the
// qmd MCP search when configured) and answers from them — a bounded lookup, not
// an agent turn. On overrun the ladder degrades to the hosted turn (rung 2). A
// const, not env-tunable: it bounds a latency-sensitive local answer, not an
// operator-managed workload, mirroring `TITLE_TIMEOUT_SECS`.
pub const VAULTQA_TIMEOUT_SECS: u64 = 25;

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

impl Config {
    pub fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        Config {
            token: env_string("JESSE_TOKEN").unwrap_or_default(),
            vault: env_string("JESSE_VAULT")
                .unwrap_or_else(|| format!("{home}/devel/tag1/jesse")),
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
                assert_eq!(cfg.state_dir.as_deref(), Some(format!("{home}/.jesse-bridge").as_str()));
                assert_eq!(cfg.jobs_dir(), Some(PathBuf::from(format!("{home}/.jesse-bridge/jobs"))));
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
        assert_eq!(clamp_timeout_secs(HARD_TIMEOUT_CEILING + 10), HARD_TIMEOUT_CEILING);
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
        assert_eq!(cfg.vaultqa_mcp_config.as_deref(), Some("/etc/jesse/qmd.json"));

        // Drop one → partial → None (treated as unset); a blank value counts as unset.
        std::env::remove_var("JESSE_VAULTQA_AUTH_TOKEN");
        assert_eq!(Config::from_env().vaultqa_backend, None);
        std::env::set_var("JESSE_VAULTQA_AUTH_TOKEN", "   ");
        assert_eq!(Config::from_env().vaultqa_backend, None);

        // Badge: only an explicit falsey value flips it off.
        for falsey in ["0", "false", "no", "off", "OFF", " Off "] {
            std::env::set_var("JESSE_MODEL_BADGE", falsey);
            assert!(!Config::from_env().model_badge, "explicit {falsey:?} disables the badge");
        }
        for truthy in ["1", "true", "yes", "on", "anything-else"] {
            std::env::set_var("JESSE_MODEL_BADGE", truthy);
            assert!(Config::from_env().model_badge, "{truthy:?} keeps the badge on");
        }

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
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
}
