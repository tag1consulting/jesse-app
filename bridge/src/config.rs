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
Bash(node todo-list/generate-diet-today.js:*),\
Bash(node todo-list/validate-diet-today.js:*),\
Bash(node todo-list/verify-diet-consistency.js:*)";

// Defense-in-depth: tools that must never run from the bridge even if they slip
// into the allowlist. Unscoped Bash (arbitrary shell) and WebFetch (SSRF / data
// exfiltration surface the Ask/Tell workflows don't need). Override with
// JESSE_DISALLOWED_TOOLS.
pub const DEFAULT_DISALLOWED_TOOLS: &str = "Bash,WebFetch";

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
    // Max concurrent turns. A request that can't get a permit immediately is
    // rejected with 429 rather than queued unboundedly.
    pub max_concurrency: usize,
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
            max_concurrency: std::env::var("JESSE_MAX_CONCURRENCY")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(2),
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
    fn scratch_base_defaults_to_temp_and_honors_override() {
        let mut cfg = test_config();
        cfg.scratch_dir = None;
        assert_eq!(cfg.scratch_base(), std::env::temp_dir());
        cfg.scratch_dir = Some("/var/jesse-scratch".to_string());
        assert_eq!(cfg.scratch_base(), PathBuf::from("/var/jesse-scratch"));
    }
}
