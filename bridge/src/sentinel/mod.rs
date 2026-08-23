// The crate prelude, exactly as every other module pulls it — and the submodules below
// reach it through `use super::*` rather than repeating this line, which is also how they
// see each other. That is the one place the sentinel differs from the rest of the bridge:
// its names are namespaced under `sentinel::` instead of flattened into the crate root (see
// the note beside `pub mod sentinel;` in `lib.rs`), so `super` is the shared namespace here.
use crate::*;
use chrono::{Local, SecondsFormat};

mod http;
mod probes;
mod state;
mod verbs;
mod watchdog;

pub use http::*;
pub use probes::*;
pub use state::*;
pub use verbs::*;
pub use watchdog::*;

// ---- THE SENTINEL: a model-free operator process ------------------------------
//
// The bridge cannot restart itself, and `launchctl`, `cargo` and `xcodebuild` are
// permanently refused to a model turn because each is a write-then-execute escape out of
// the containment record. So when the bridge wedges, the only repair is an ssh session on
// the host — which is exactly what is unavailable to someone holding a phone.
//
// This is the second process. It has NO model, NO free text, and a FIXED verb table: every
// route below is a named operation with named arguments, and the only string that reaches
// the bridge from a caller is a `[[schedule]]` id that was first validated against the
// bridge's own schedule. It is not a tool the agent can call and it is not reachable from a
// turn; it listens on its own port, with its own token, and the two tokens are disjoint on
// purpose (see `refuse_shared_token`).
//
// What it can do: read state (`GET /sentinel/status`), restart the five launchd jobs this
// deployment runs, reload the bridge's plist environment, clear a stale git index lock,
// prune the artifact store, and proxy the scheduler's two control verbs. What it cannot do:
// read the vault, run a model, or accept a command that is not in the table.
//
// The watchdog is the half that works when nobody is looking: one 60 s tick that notices the
// bridge is down, the autocommit is stuck, the lock is stale, the disk is full, the tailnet
// is offline, `qmd` is broken, or nothing has fired all night — and either fixes it once or
// pushes to the phone, never both without saying so.

/// The default port. 8766, one above the bridge's 8765, so a deployment that names neither
/// still puts them side by side.
pub const DEFAULT_SENTINEL_PORT: u16 = 8766;

/// Every probe's ceiling. `GET /sentinel/status` runs its probes CONCURRENTLY and each is
/// wrapped in this, so the whole document answers in about this long no matter which
/// subsystem is wedged — a hung `launchctl` degrades one field to `unknown` rather than
/// hanging the one request an operator has.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a restart verb waits for the bridge to answer `/health` again before reporting
/// `healthy: false`. The verb still reports `restarted: true` — the kickstart happened;
/// what did not happen is the bridge coming back inside the window.
pub const HEALTH_POLL_TIMEOUT: Duration = Duration::from_secs(60);

/// The ceiling on a restart verb as a whole (kickstart + poll). The spec's 90 s: the 60 s
/// poll plus room for a `bootout`/`bootstrap` pair that is slower than a `kickstart`.
pub const RESTART_TIMEOUT: Duration = Duration::from_secs(90);

/// The watchdog's tick.
pub const WATCHDOG_TICK: Duration = Duration::from_secs(60);

/// Verbs allowed per minute, across all callers. A verb is an operator pressing a button,
/// not a poll loop; ten a minute is generous for that and small enough that a stuck client
/// cannot kickstart the bridge in a circle.
pub const VERB_RATE_PER_MIN: u32 = 10;

/// The five launchd jobs this deployment runs, as the sentinel's own vocabulary. The URL
/// says `bridge`, not a reverse-DNS label: the label is deployment configuration (see
/// [`SentinelConfig::labels`]), the SLOT is what the verb table is written in terms of.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum ServiceSlot {
    Bridge,
    Autocommit,
    LockReaper,
    QmdUpdate,
    Miniserve,
}

/// Every slot, in the order `GET /sentinel/status` reports them.
pub const SERVICE_SLOTS: [ServiceSlot; 5] = [
    ServiceSlot::Bridge,
    ServiceSlot::Autocommit,
    ServiceSlot::LockReaper,
    ServiceSlot::QmdUpdate,
    ServiceSlot::Miniserve,
];

impl ServiceSlot {
    /// The URL path segment and the `services` key.
    pub fn slug(self) -> &'static str {
        match self {
            ServiceSlot::Bridge => "bridge",
            ServiceSlot::Autocommit => "autocommit",
            ServiceSlot::LockReaper => "lock-reaper",
            ServiceSlot::QmdUpdate => "qmd-update",
            ServiceSlot::Miniserve => "miniserve",
        }
    }

    /// Parse the `{service}` path segment. Unknown → `None` → 404, so the verb table is
    /// closed: there is no way to name a launchd label the configuration did not name.
    pub fn from_slug(s: &str) -> Option<ServiceSlot> {
        SERVICE_SLOTS.into_iter().find(|slot| slot.slug() == s)
    }

    /// The env var that names this slot's launchd label.
    pub fn label_env(self) -> &'static str {
        match self {
            ServiceSlot::Bridge => "JESSE_SENTINEL_LABEL_BRIDGE",
            ServiceSlot::Autocommit => "JESSE_SENTINEL_LABEL_AUTOCOMMIT",
            ServiceSlot::LockReaper => "JESSE_SENTINEL_LABEL_LOCK_REAPER",
            ServiceSlot::QmdUpdate => "JESSE_SENTINEL_LABEL_QMD_UPDATE",
            ServiceSlot::Miniserve => "JESSE_SENTINEL_LABEL_MINISERVE",
        }
    }

    /// The label used when the deployment names none.
    ///
    /// FOUR OF THE FIVE ARE PLACEHOLDERS ON PURPOSE. A launchd label in someone's own
    /// reverse-DNS namespace is personal infrastructure, and `scripts/ci-guards.sh` refuses
    /// it in a tracked file — correctly, because a default that happened to match one
    /// machine would silently do nothing on every other one. So the defaults sit in the
    /// documented `com.example.` namespace and [`SentinelConfig::placeholder_labels`]
    /// reports any that survived, loudly, at startup. `com.qmd.update` is the exception: it
    /// is the QMD tool's own published label, not anyone's.
    pub fn default_label(self) -> &'static str {
        match self {
            ServiceSlot::Bridge => "com.example.jesse-bridge",
            ServiceSlot::Autocommit => "com.example.jesse-autocommit",
            ServiceSlot::LockReaper => "com.example.jesse-lock-reaper",
            ServiceSlot::QmdUpdate => "com.qmd.update",
            ServiceSlot::Miniserve => "com.example.miniserve-diet-dashboard",
        }
    }
}

/// Every external command the sentinel runs, resolved to an ABSOLUTE path once at startup.
///
/// Resolved once rather than per call for two reasons. A verb that shells out to whatever
/// `launchctl` happens to be first on `PATH` at the moment it is pressed is not a fixed
/// verb; and a test needs to substitute a shim, which `JESSE_SENTINEL_<NAME>_BIN` does
/// without the test having to own the process `PATH`.
///
/// A binary that cannot be resolved is `None`, NOT a startup refusal: an operator process
/// that will not boot because one auxiliary tool is missing is the failure mode this whole
/// service exists to prevent. The probes and verbs that need it report the absence by name.
#[derive(Clone, Debug, Default)]
pub struct Bins {
    pub launchctl: Option<PathBuf>,
    pub tailscale: Option<PathBuf>,
    pub git: Option<PathBuf>,
    pub df: Option<PathBuf>,
    pub pgrep: Option<PathBuf>,
    pub qmd: Option<PathBuf>,
    pub node: Option<PathBuf>,
}

impl Bins {
    /// Resolve every command from the environment, then `PATH`, then the well-known
    /// locations. Reports `(bins, missing)` so the caller can warn about the gaps.
    pub fn resolve() -> (Bins, Vec<&'static str>) {
        let bins = Bins {
            launchctl: resolve_bin("launchctl", &["/bin/launchctl"]),
            // Tailscale on a Mac ships inside the app bundle and is NOT on a launchd job's
            // PATH; the CLI symlink is a thing the user may or may not have made.
            tailscale: resolve_bin(
                "tailscale",
                &["/Applications/Tailscale.app/Contents/MacOS/Tailscale"],
            ),
            git: resolve_bin("git", &["/usr/bin/git"]),
            df: resolve_bin("df", &["/bin/df"]),
            pgrep: resolve_bin("pgrep", &["/usr/bin/pgrep"]),
            qmd: resolve_bin("qmd", &["/opt/homebrew/bin/qmd", "/usr/local/bin/qmd"]),
            node: resolve_bin("node", &[]),
        };
        let mut missing = Vec::new();
        for (name, found) in [
            ("launchctl", bins.launchctl.is_some()),
            ("tailscale", bins.tailscale.is_some()),
            ("git", bins.git.is_some()),
            ("df", bins.df.is_some()),
            ("pgrep", bins.pgrep.is_some()),
            ("qmd", bins.qmd.is_some()),
            ("node", bins.node.is_some()),
        ] {
            if !found {
                missing.push(name);
            }
        }
        (bins, missing)
    }
}

/// The env override that pins one command's path: `launchctl` → `JESSE_SENTINEL_LAUNCHCTL_BIN`.
pub fn bin_env_name(name: &str) -> String {
    format!("JESSE_SENTINEL_{}_BIN", name.to_ascii_uppercase())
}

/// Resolve one external command to an absolute, executable path.
///
/// Order: the `JESSE_SENTINEL_<NAME>_BIN` override (honoured verbatim, so a test shim need
/// not be on `PATH`), then each `PATH` entry, then the `fallbacks` — the locations a macOS
/// deployment has the binary in when a launchd job's minimal `PATH` does not.
pub fn resolve_bin(name: &str, fallbacks: &[&str]) -> Option<PathBuf> {
    if let Some(pinned) = env_string(&bin_env_name(name)) {
        return binary_exists(&pinned).then(|| PathBuf::from(pinned));
    }
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':').filter(|d| !d.is_empty()) {
            let candidate = Path::new(dir).join(name);
            if binary_exists(&candidate.to_string_lossy()) {
                return Some(candidate);
            }
        }
    }
    fallbacks
        .iter()
        .find(|c| binary_exists(c))
        .map(PathBuf::from)
}

/// Everything the sentinel was configured with, read once at startup.
pub struct SentinelConfig {
    pub bind: String,
    pub port: u16,
    /// The sentinel's OWN bearer token. Never logged, never echoed, never in the audit line.
    pub token: String,
    /// The BRIDGE's token, for the proxied reads and the two proxy verbs. Absent means the
    /// bridge half of `/sentinel/status` reports only what an unauthenticated probe sees,
    /// and the proxy verbs refuse.
    pub bridge_token: Option<String>,
    /// e.g. `http://127.0.0.1:8765`, no trailing slash.
    pub bridge_url: String,
    pub state_dir: PathBuf,
    /// The bridge's LaunchAgent plist, needed by `bootout`/`bootstrap` — the only way a
    /// plist env change takes effect (`kickstart -k` re-execs with the OLD environment).
    pub bridge_plist: Option<PathBuf>,
    pub uid: u32,
    pub labels: HashMap<ServiceSlot, String>,
    pub bins: Bins,
    /// A copy of the BRIDGE CHILD's `PATH`, so `qmd status` is probed with the same node on
    /// it that a turn would reach. `qmd` is a native-addon Node program and fails with
    /// `ERR_DLOPEN_FAILED` under a mismatched Node ABI, which is invisible unless the probe
    /// runs with the child's own `PATH`.
    pub child_path: Option<String>,
    /// The vault git repo (`~/jesse`).
    pub vault_repo: PathBuf,
    /// The bridge's state dir (`~/.jesse-bridge`).
    pub bridge_state_dir: PathBuf,
    /// The autocommit job's log, whose last `PUBLISHED:` / `UNPUBLISHED:` line is the only
    /// record of whether the vault is reaching its remote.
    pub autocommit_log: Option<PathBuf>,
    /// The scheduler's fire ledger.
    pub ledger: PathBuf,
    /// The bridge's registered device token file. READ-ONLY here: the sentinel pushes to
    /// whatever device the bridge has paired and never registers, clears or rewrites one.
    pub device_json: PathBuf,
}

impl SentinelConfig {
    /// The launchd label configured for a slot.
    pub fn label(&self, slot: ServiceSlot) -> &str {
        self.labels
            .get(&slot)
            .map(String::as_str)
            .unwrap_or_else(|| slot.default_label())
    }

    /// `gui/<uid>/<label>` — the launchd service target every verb and probe addresses.
    pub fn target(&self, slot: ServiceSlot) -> String {
        format!("gui/{}/{}", self.uid, self.label(slot))
    }

    /// Slots still carrying the documented placeholder label, so startup can say which
    /// restart verbs are wired to nothing. Named rather than counted: "three of five" tells
    /// an operator nothing they can act on.
    pub fn placeholder_labels(&self) -> Vec<(ServiceSlot, String)> {
        SERVICE_SLOTS
            .into_iter()
            .filter(|s| self.label(*s).starts_with("com.example."))
            .map(|s| (s, self.label(s).to_string()))
            .collect()
    }

    /// `<state_dir>/state.json` — the watchdog's memory across restarts.
    pub fn state_file(&self) -> PathBuf {
        self.state_dir.join("state.json")
    }

    /// `<state_dir>/sentinel.log` — the verb audit trail.
    pub fn audit_file(&self) -> PathBuf {
        self.state_dir.join("sentinel.log")
    }

    /// `<bridge_state_dir>/artifacts` — what the prune verb walks.
    pub fn artifacts_dir(&self) -> PathBuf {
        self.bridge_state_dir.join("artifacts")
    }

    /// `<vault_repo>/.git/index.lock` — what the unlock verb removes.
    pub fn index_lock(&self) -> PathBuf {
        self.vault_repo.join(".git/index.lock")
    }

    /// Read the whole configuration from the environment.
    ///
    /// Returns `Err` only for the two things that cannot be defaulted or degraded: no token,
    /// and a token shared with the bridge. Everything else has a default and, where the
    /// default is a placeholder, a startup warning that names it.
    pub fn from_env() -> Result<SentinelConfig, String> {
        let home = env_string("HOME").unwrap_or_else(|| ".".to_string());
        let home = PathBuf::from(home);
        let token = env_string("JESSE_SENTINEL_TOKEN")
            .ok_or_else(|| "JESSE_SENTINEL_TOKEN is not set".to_string())?;
        let bridge_token = env_string("JESSE_TOKEN");
        refuse_shared_token(&token, bridge_token.as_deref())?;

        let mut labels = HashMap::new();
        for slot in SERVICE_SLOTS {
            let label =
                env_string(slot.label_env()).unwrap_or_else(|| slot.default_label().to_string());
            labels.insert(slot, label);
        }
        let (bins, _) = Bins::resolve();
        let vault_repo = env_string("JESSE_SENTINEL_VAULT_REPO")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("jesse"));
        let bridge_state_dir = env_string("JESSE_SENTINEL_BRIDGE_STATE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".jesse-bridge"));
        let bridge_plist = env_string("JESSE_SENTINEL_BRIDGE_PLIST").map(PathBuf::from);
        let autocommit_log = env_string("JESSE_SENTINEL_AUTOCOMMIT_LOG")
            .map(PathBuf::from)
            .or_else(|| {
                // Not configured: derive it from the autocommit job's own plist, which is
                // where the answer actually lives. `~/Library/LaunchAgents/<label>.plist`
                // is the user-domain convention every job here follows.
                let label = labels.get(&ServiceSlot::Autocommit)?;
                let plist = home.join(format!("Library/LaunchAgents/{label}.plist"));
                let xml = std::fs::read_to_string(plist).ok()?;
                parse_plist_string_key(&xml, "StandardOutPath").map(PathBuf::from)
            });

        Ok(SentinelConfig {
            bind: env_string("JESSE_SENTINEL_BIND").unwrap_or_else(|| "127.0.0.1".to_string()),
            port: env_parse("JESSE_SENTINEL_PORT", DEFAULT_SENTINEL_PORT),
            token,
            bridge_token,
            bridge_url: env_string("JESSE_SENTINEL_BRIDGE_URL")
                .unwrap_or_else(|| "http://127.0.0.1:8765".to_string())
                .trim_end_matches('/')
                .to_string(),
            state_dir: env_string("JESSE_SENTINEL_STATE_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".jesse-sentinel")),
            bridge_plist,
            uid: current_uid(),
            labels,
            bins,
            child_path: env_string("JESSE_SENTINEL_CHILD_PATH"),
            ledger: env_string("JESSE_SENTINEL_LEDGER")
                .map(PathBuf::from)
                .unwrap_or_else(|| vault_repo.join("vault/Inbox/scheduled-jobs-ledger.jsonl")),
            device_json: bridge_state_dir.join("device.json"),
            vault_repo,
            bridge_state_dir,
            autocommit_log,
        })
    }
}

/// The two tokens must be DISJOINT.
///
/// This is not hygiene, it is the boundary. The bridge's token buys a model turn against the
/// vault; the sentinel's buys `launchctl kickstart` and (from P5) a binary replacement.
/// Making them the same value means a phone that has been paired with the bridge — or any
/// leak of the bridge token, which travels on every single request the app makes — also
/// holds the operator process. They are separate ports and separate services precisely so
/// that one can be revoked without the other, and an equal value silently undoes that.
pub fn refuse_shared_token(sentinel: &str, bridge: Option<&str>) -> Result<(), String> {
    match bridge {
        Some(b) if b == sentinel => Err("JESSE_SENTINEL_TOKEN is equal to JESSE_TOKEN — the \
             sentinel's token must be disjoint from the bridge's, or a leak of either one \
             grants both. Generate a second value: openssl rand -hex 24"
            .to_string()),
        _ => Ok(()),
    }
}

/// The invoking user's uid, for the `gui/<uid>` launchd domain.
pub fn current_uid() -> u32 {
    // SAFETY: `getuid` takes no arguments, cannot fail, and touches no memory the caller
    // owns. It is the one syscall that answers "which gui/<uid> domain are we in", and the
    // launchd targets are unusable without it.
    unsafe { libc::getuid() }
}

/// Pull one `<key>NAME</key><string>VALUE</string>` pair out of a LaunchAgent plist.
///
/// A whole plist parser would be a dependency for ONE string. This reads the XML form
/// launchd's own tooling writes: find the `<key>`, and take the element IMMEDIATELY after it.
///
/// Immediately is the whole correctness condition. "The next `<string>` anywhere after the
/// key" is the obvious implementation and it is wrong: `StartInterval` is an `<integer>`, so
/// that version answers a query for it with the log path three keys further down — a
/// confidently wrong value, which is worse than no value. A key whose value is not a
/// `<string>`, a binary plist, or any shape this does not recognise all yield `None`, and the
/// caller falls back to its own default.
pub fn parse_plist_string_key(xml: &str, key: &str) -> Option<String> {
    // The closing tag is part of the needle, so `Program` does not match `ProgramArguments`.
    let needle = format!("<key>{key}</key>");
    let after = xml[xml.find(&needle)? + needle.len()..].trim_start();
    let body = after.strip_prefix("<string>")?;
    let close = body.find("</string>")?;
    let value = body[..close].trim();
    (!value.is_empty()).then(|| unescape_xml(value))
}

/// The five predefined XML entities, which a path with an `&` in it will carry.
fn unescape_xml(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        // Last, so an escaped `&amp;lt;` does not become `<`.
        .replace("&amp;", "&")
}

/// One external command's result. `timed_out` is distinguished from a non-zero exit because
/// they mean opposite things to a probe: a timeout is `unknown` (we learned nothing), a
/// non-zero exit is a fact.
#[derive(Debug, Default)]
pub struct CmdOut {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
    /// The command could not be spawned at all (missing binary, EPERM).
    pub spawn_error: Option<String>,
}

impl CmdOut {
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }

    /// The command did not RUN — it could not be spawned, or it hung and was killed.
    ///
    /// This is the line between `failed` and `unknown` for every probe, and the distinction
    /// is not pedantic: "launchctl says the job is not loaded" is a fact about the host,
    /// while "launchctl is missing" or "launchctl hung" is a fact about the probe. Reporting
    /// the second as the first would put a red row on the status page describing a service
    /// that may be perfectly fine.
    pub fn unrunnable(&self) -> bool {
        self.timed_out || self.spawn_error.is_some()
    }

    /// The first non-empty line of stderr, which is what a probe reports rather than a
    /// whole stack of node frames.
    pub fn first_stderr_line(&self) -> Option<String> {
        self.stderr
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(|l| l.chars().take(300).collect())
    }

    /// A one-line description for an audit entry or an error field.
    pub fn summary(&self) -> String {
        if let Some(e) = &self.spawn_error {
            return format!("could not run: {e}");
        }
        if self.timed_out {
            return "timed out".to_string();
        }
        match self.code {
            Some(0) => "ok".to_string(),
            Some(c) => match self.first_stderr_line() {
                Some(l) => format!("exit {c}: {l}"),
                None => format!("exit {c}"),
            },
            None => "killed by signal".to_string(),
        }
    }
}

/// Run one external command to completion under `limit`, capturing both streams.
///
/// `env` REPLACES nothing — it is layered onto the inherited environment — except that
/// `PATH` is overridden when the caller passes one, which is exactly what the `qmd` probe
/// needs to reproduce the bridge child's resolution.
///
/// A timeout kills the child (`kill_on_drop`), so a wedged `launchctl` cannot outlive the
/// request that started it.
pub async fn run_cmd(
    bin: Option<&PathBuf>,
    args: &[&str],
    env: &[(&str, &str)],
    limit: Duration,
) -> CmdOut {
    let Some(bin) = bin else {
        return CmdOut {
            spawn_error: Some("binary not found on this host".to_string()),
            ..Default::default()
        };
    };
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for (k, v) in env {
        cmd.env(k, v);
    }
    let Ok(finished) = timeout(limit, cmd.output()).await else {
        return CmdOut {
            timed_out: true,
            ..Default::default()
        };
    };
    match finished {
        Ok(o) => CmdOut {
            code: o.status.code(),
            stdout: String::from_utf8_lossy(&o.stdout).to_string(),
            stderr: String::from_utf8_lossy(&o.stderr).to_string(),
            timed_out: false,
            spawn_error: None,
        },
        Err(e) => CmdOut {
            spawn_error: Some(e.to_string()),
            ..Default::default()
        },
    }
}

/// Local wall-clock, seconds precision — the same stamp the scheduler's ledger uses, so a
/// sentinel audit line and a ledger line can be read side by side.
pub fn now_local_rfc3339() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Secs, false)
}

/// Milliseconds since the epoch.
pub fn now_ms() -> u64 {
    system_time_to_ms(SystemTime::now())
}

/// The whole running service: configuration, the watchdog's persisted state, the two
/// admission gates, and the shared HTTP client.
pub struct Sentinel {
    pub cfg: Arc<SentinelConfig>,
    pub started: Instant,
    pub version: &'static str,
    pub state: Mutex<WatchState>,
    pub limiter: RateLimiter,
    /// SINGLE FLIGHT over every mutating verb. Two concurrent `kickstart`s of the same job,
    /// or a prune racing a restart, are not operations anyone asked for; the loser gets 409
    /// and can press the button again.
    pub verb_lock: tokio::sync::Mutex<()>,
    pub http: reqwest::Client,
    pub apns: Option<Arc<ApnsClient>>,
}

impl Sentinel {
    pub fn new(cfg: SentinelConfig, apns: Option<Arc<ApnsClient>>) -> Arc<Sentinel> {
        let state = WatchState::load(&cfg.state_file());
        Arc::new(Sentinel {
            started: Instant::now(),
            version: env!("CARGO_PKG_VERSION"),
            state: Mutex::new(state),
            limiter: RateLimiter::new(VERB_RATE_PER_MIN),
            verb_lock: tokio::sync::Mutex::new(()),
            // No global timeout on the client: each call sets its own, because a 5 s probe
            // and a 60 s health poll are the same client.
            http: reqwest::Client::builder()
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
            apns,
            cfg: Arc::new(cfg),
        })
    }

    pub fn uptime_secs(&self) -> u64 {
        self.started.elapsed().as_secs()
    }

    /// `GET` from the bridge with its bearer token, under `limit`.
    pub async fn bridge_get(&self, path: &str, limit: Duration) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.cfg.bridge_url);
        let mut req = self.http.get(&url).timeout(limit);
        if let Some(t) = &self.cfg.bridge_token {
            req = req.bearer_auth(t);
        }
        let resp = req.send().await.map_err(|e| e.to_string())?;
        let status = resp.status().as_u16();
        let text = resp.text().await.map_err(|e| e.to_string())?;
        let body = serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!(text));
        Ok((status, body))
    }

    /// `POST` to the bridge with its bearer token, under `limit`.
    pub async fn bridge_post(
        &self,
        path: &str,
        body: &Value,
        limit: Duration,
    ) -> Result<(u16, Value), String> {
        let Some(token) = &self.cfg.bridge_token else {
            return Err(
                "JESSE_TOKEN is not set in the sentinel's environment, so it cannot \
                        authenticate to the bridge"
                    .to_string(),
            );
        };
        let url = format!("{}{path}", self.cfg.bridge_url);
        // Serialized by hand rather than through reqwest's `json` feature: that feature
        // pulls serde_json into reqwest's own graph for a `to_vec` and a header this file
        // can write in two lines, and every dependency here is one more thing inside the
        // process that can restart the machine's services.
        let body = serde_json::to_vec(body).map_err(|e| e.to_string())?;
        let resp = self
            .http
            .post(&url)
            .bearer_auth(token)
            .header("content-type", "application/json")
            .body(body)
            .timeout(limit)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = resp.status().as_u16();
        let text = resp.text().await.map_err(|e| e.to_string())?;
        let parsed = serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!(text));
        Ok((status, parsed))
    }

    /// Append one line to the verb audit trail: when, from where, which verb, what happened.
    ///
    /// NEVER a token, and never a request body — the only caller-supplied value that reaches
    /// this file is a `[[schedule]]` id that was already validated against the bridge's own
    /// schedule. Best-effort: an unwritable log must not fail the verb it is recording, but
    /// it does get a line on stderr so the gap is visible in the launchd log.
    pub fn audit(&self, caller: &str, verb: &str, outcome: &str) {
        let line = format!(
            "{} {} {} {}\n",
            now_local_rfc3339(),
            caller,
            verb,
            outcome.replace('\n', " ")
        );
        let path = self.cfg.audit_file();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let write = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut f| f.write_all(line.as_bytes()));
        if let Err(e) = write {
            eprintln!(
                "jesse-sentinel: WARNING — could not append to the audit log {} ({e}); the \
                 verb still ran",
                path.display()
            );
        }
        // Also to stderr, which is the launchd log: the audit file is the record, this is
        // what someone tailing the service actually sees.
        eprintln!("jesse-sentinel: VERB {caller} {verb} {outcome}");
    }

    /// Persist the watchdog state. Called after every tick and after any verb that changes
    /// it, so a sentinel that is itself restarted does not forget it had already given up on
    /// a bridge that keeps dying.
    pub fn persist_state(&self) {
        let snapshot = self.state.lock_ok().clone();
        snapshot.persist(&self.cfg.state_file());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_slug_round_trips_and_rejects_unknown() {
        for slot in SERVICE_SLOTS {
            assert_eq!(ServiceSlot::from_slug(slot.slug()), Some(slot));
        }
        // The verb table is CLOSED: a path segment that is not one of the five names
        // nothing, so no caller can address a launchd label the config did not name.
        assert_eq!(ServiceSlot::from_slug("com.example.jesse-bridge"), None);
        assert_eq!(ServiceSlot::from_slug(""), None);
        assert_eq!(ServiceSlot::from_slug("Bridge"), None);
    }

    #[test]
    fn shared_token_is_refused() {
        assert!(refuse_shared_token("aaa", Some("bbb")).is_ok());
        assert!(refuse_shared_token("aaa", None).is_ok());
        let err = refuse_shared_token("same", Some("same")).unwrap_err();
        assert!(err.contains("disjoint"), "{err}");
    }

    #[test]
    fn plist_string_key_reads_the_log_path() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.jesse-autocommit</string>
	<key>StartInterval</key>
	<integer>900</integer>
	<key>StandardOutPath</key>
	<string>/Users/you/Library/Logs/jesse-autocommit.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/you/Library/Logs/jesse-autocommit.log</string>
</dict>
</plist>"#;
        assert_eq!(
            parse_plist_string_key(xml, "StandardOutPath").as_deref(),
            Some("/Users/you/Library/Logs/jesse-autocommit.log")
        );
        assert_eq!(
            parse_plist_string_key(xml, "Label").as_deref(),
            Some("com.example.jesse-autocommit")
        );
        // A key whose value is not a <string> must not be mis-read as the NEXT string in
        // the file — StartInterval is an <integer>, and returning the log path for it
        // would be worse than returning nothing.
        assert_eq!(parse_plist_string_key(xml, "StartInterval"), None);
        assert_eq!(parse_plist_string_key(xml, "Nope"), None);
        // Not XML at all (a binary plist) → None, and the caller keeps its default.
        assert_eq!(parse_plist_string_key("bplist00\u{0}\u{1}", "Label"), None);
    }

    #[test]
    fn plist_string_key_unescapes_entities() {
        let xml = "<key>Program</key><string>/opt/a&amp;b/run</string>";
        assert_eq!(
            parse_plist_string_key(xml, "Program").as_deref(),
            Some("/opt/a&b/run")
        );
    }

    #[test]
    fn cmd_out_summary_distinguishes_the_failure_modes() {
        let timed = CmdOut {
            timed_out: true,
            ..Default::default()
        };
        assert_eq!(timed.summary(), "timed out");
        let missing = CmdOut {
            spawn_error: Some("No such file".to_string()),
            ..Default::default()
        };
        assert!(missing.summary().starts_with("could not run"));
        let failed = CmdOut {
            code: Some(2),
            stderr: "\n  ERR_DLOPEN_FAILED: bad ABI\nmore\n".to_string(),
            ..Default::default()
        };
        assert_eq!(failed.summary(), "exit 2: ERR_DLOPEN_FAILED: bad ABI");
        assert!(CmdOut {
            code: Some(0),
            ..Default::default()
        }
        .ok());
    }

    #[test]
    fn placeholder_labels_are_named_not_counted() {
        let mut labels = HashMap::new();
        for slot in SERVICE_SLOTS {
            labels.insert(slot, slot.default_label().to_string());
        }
        labels.insert(ServiceSlot::Bridge, "com.tag1.jesse-bridge".to_string());
        let cfg = test_config(labels);
        let names: Vec<&str> = cfg
            .placeholder_labels()
            .iter()
            .map(|(s, _)| s.slug())
            .collect();
        // The configured one drops out; qmd-update's default is the tool's real label and
        // was never a placeholder.
        assert_eq!(names, vec!["autocommit", "lock-reaper", "miniserve"]);
        assert_eq!(
            cfg.target(ServiceSlot::Bridge),
            "gui/501/com.tag1.jesse-bridge"
        );
    }

    /// A config with no environment behind it, for the pure-function tests above.
    pub fn test_config(labels: HashMap<ServiceSlot, String>) -> SentinelConfig {
        SentinelConfig {
            bind: "127.0.0.1".to_string(),
            port: DEFAULT_SENTINEL_PORT,
            token: "sentinel-token".to_string(),
            bridge_token: Some("bridge-token".to_string()),
            bridge_url: "http://127.0.0.1:8765".to_string(),
            state_dir: PathBuf::from("/nonexistent/state"),
            bridge_plist: None,
            uid: 501,
            labels,
            bins: Bins::default(),
            child_path: None,
            vault_repo: PathBuf::from("/nonexistent/vault"),
            bridge_state_dir: PathBuf::from("/nonexistent/bridge-state"),
            autocommit_log: None,
            ledger: PathBuf::from("/nonexistent/ledger.jsonl"),
            device_json: PathBuf::from("/nonexistent/device.json"),
        }
    }
}
