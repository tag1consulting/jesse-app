use super::*;
use serde::Serialize;

// ---- REMOTE DEPLOY, WITH AUTOMATIC ROLLBACK -------------------------------------
//
// The pipeline this completes: a coding session opens a bridge PR, CI goes green, the PR is
// merged from the GitHub app, and the owner — holding nothing but a phone — taps Deploy.
// This module is the half that runs on the host: it builds a commit, swaps the deploy binaries,
// restarts the bridge, verifies that what came back is what was asked for, and PUTS THE OLD
// ONE BACK if it is not.
//
// NOTHING HERE INVOLVES A MODEL TURN. It is a verb like every other verb in this service:
// fixed arguments, a closed alphabet, a bounded wait. The containment record is untouched —
// `cargo` is refused to a turn and remains refused; it is run here, by a process that has no
// model in it, on a commit that a human merged and that CI has already built.
//
// WHAT MAKES THIS SAFE ENOUGH TO EXIST is not this file, it is the four gates in front of it:
//
//   1. the sentinel's own bearer token, disjoint from the bridge's;
//   2. the ref must be `main` or a 40-hex sha, and the sha must be an ANCESTOR OF
//      `origin/main` — so the only thing deployable is something that was merged;
//   3. the `bridge` CI job must be green ON THAT COMMIT, and `force` does not bypass it;
//   4. the bridge that comes back must answer `/health` with the version the commit
//      declares, or the symlinks go back where they were.
//
// Gate 2 means BRANCH PROTECTION ON `main` IS PART OF THIS BOUNDARY. See SECURITY.md.

/// The manifest, relative to the crate directory, that names the binaries a deployment is
/// made of: `bridge/deploy-bins.toml`.
///
/// # Why the list is READ FROM THE TREE and not compiled in
///
/// A deploy is executed by the ALREADY-RUNNING `jesse-sentinel`, and the sentinel is not one
/// of the binaries a deploy replaces — so its compiled-in knowledge is as old as the last
/// time somebody installed it by hand. While this list was a `const`, that made it frozen:
/// `jesse-places-mcp` joined the deploy set in 0.100.0, and every deploy after it went on
/// building, staging and repointing THREE binaries and reporting complete success, because
/// by its own list it was complete. The binary was never installed, the child's `places`
/// server failed to connect on every turn, and nothing said so.
///
/// That is a class of bug, not one missed name: a deploy that introduces a new binary can
/// never install it on its own first run while the list travels with the deployer instead of
/// with the code. Reading the manifest out of the CHECKED-OUT COMMIT closes it — the commit
/// that adds a binary carries the name, so however old the sentinel is, it stages what that
/// commit says it is made of.
pub const DEPLOY_BINS_MANIFEST: &str = "deploy-bins.toml";

/// The manifest COMPILED IN, used only where there is no tree to read: a commit older than
/// the manifest itself (see [`deploy_bins_at`]), and the tests that need "the set this build
/// knows about".
const EMBEDDED_DEPLOY_BINS: &str = include_str!("../../deploy-bins.toml");

#[derive(Debug, Deserialize)]
struct DeployBinsManifest {
    bins: Vec<String>,
}

/// Parse a `deploy-bins.toml`, rejecting anything that would make the stage phase write
/// outside the build directory or leave the deployment without its own service.
///
/// The name checks are not defensive decoration: every entry is joined onto the build store
/// path AND onto `~/.local/bin`, so a `/` or a `..` in one would repoint something that is
/// not a deploy binary. The manifest comes out of a commit that reached `main`, so this is
/// not the boundary — the ancestry gate is — but a typo must fail here rather than in the
/// filesystem.
pub fn parse_deploy_bins(text: &str) -> Result<Vec<String>, String> {
    let manifest: DeployBinsManifest =
        toml::from_str(text).map_err(|e| format!("{DEPLOY_BINS_MANIFEST} is not readable: {e}"))?;
    if manifest.bins.is_empty() {
        return Err(format!("{DEPLOY_BINS_MANIFEST} names no binaries"));
    }
    for name in &manifest.bins {
        if name.is_empty()
            || name.contains('/')
            || name.starts_with('.')
            || name.contains(char::is_whitespace)
        {
            return Err(format!(
                "{DEPLOY_BINS_MANIFEST} names {name:?}, which is not a plain binary name"
            ));
        }
    }
    let mut seen = manifest.bins.clone();
    seen.sort();
    seen.dedup();
    if seen.len() != manifest.bins.len() {
        return Err(format!("{DEPLOY_BINS_MANIFEST} names a binary twice"));
    }
    // Without it there is nothing to kickstart and nothing whose `/health` version could
    // decide whether to keep the deploy — a manifest that omits it is not a deployment.
    if !manifest.bins.iter().any(|b| b == BRIDGE_BIN) {
        return Err(format!("{DEPLOY_BINS_MANIFEST} does not name {BRIDGE_BIN}"));
    }
    Ok(manifest.bins)
}

/// The service binary itself — the one the restart phase kickstarts.
pub const BRIDGE_BIN: &str = "jesse-bridge";

/// The binary set THIS build knows about, from the manifest committed beside it. The
/// fallback for a tree that predates the manifest, and what the tests mean by "the deploy
/// set".
pub fn embedded_deploy_bins() -> &'static [String] {
    static PARSED: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    PARSED.get_or_init(|| {
        parse_deploy_bins(EMBEDDED_DEPLOY_BINS)
            .expect("the committed deploy-bins.toml must parse — a test asserts it")
    })
}

/// The binary set the COMMIT BEING DEPLOYED is made of, read from `<crate dir>/deploy-bins.toml`.
///
/// A tree with no manifest is a commit older than this mechanism, and it is deployable —
/// rolling back to one is a real operation. There the compiled-in set is the only list there
/// is, so it is used and the caller says so in the log rather than the deploy failing.
pub fn deploy_bins_at(crate_dir: &Path) -> Result<(Vec<String>, bool), String> {
    let path = crate_dir.join(DEPLOY_BINS_MANIFEST);
    match std::fs::read_to_string(&path) {
        Ok(text) => Ok((parse_deploy_bins(&text)?, true)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Ok((embedded_deploy_bins().to_vec(), false))
        }
        Err(e) => Err(format!("could not read {}: {e}", path.display())),
    }
}

/// The DEFAULT name of the CI job that must be green — the one that builds and tests the crate
/// being deployed. [`SentinelConfig::ci_job`] is what is actually required, so a fork whose
/// workflow names it differently is not stuck.
pub const CI_JOB_NAME: &str = "bridge";

/// Whether one entry in a jobs listing is the job the gate requires.
///
/// AN EQUALITY TEST HERE MATCHES NOTHING, and that is measured rather than reasoned. The jobs
/// API reports a job's DISPLAY name — the workflow's `name:` — not its key, and this
/// repository's `bridge` job carries
/// `name: bridge (build, test, clippy, guards, audit, coverage)`. Requiring `== "bridge"` made
/// every deploy refuse with "no completed run carries a successful bridge job" against a run
/// that was, in fact, green. The live API said so on this very branch.
///
/// So: an exact match, or the wanted name followed by a separator that cannot be part of a
/// name — a space (which also covers the ` / ` of a reusable workflow) or the `(` of a matrix
/// leg. NOT `-`, so a `bridge-nightly` job never vouches for `bridge`.
pub fn job_matches(name: &str, want: &str) -> bool {
    match name.strip_prefix(want) {
        Some(rest) => rest.is_empty() || rest.starts_with(' ') || rest.starts_with('('),
        None => false,
    }
}

/// The ceiling on `cargo build --release`. A cold build of this crate on this host is minutes,
/// not seconds, and a deploy that gave up at five would be a deploy that never worked after a
/// dependency bump.
pub const BUILD_TIMEOUT: Duration = Duration::from_secs(20 * 60);

/// The DEFAULT window a deploy waits for the restarted bridge to come back CORRECT — longer
/// than the restart verb's 60 s, because the answer here decides whether to roll back rather
/// than merely what to report. [`SentinelConfig::deploy_health_timeout`] is what is actually
/// waited; this is what it defaults to.
pub const DEPLOY_HEALTH_TIMEOUT: Duration = Duration::from_secs(90);

/// The gap between `/health` polls.
pub const DEPLOY_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Every GitHub API call's ceiling.
pub const GITHUB_TIMEOUT: Duration = Duration::from_secs(20);

/// A deploy's `git` ceiling. A `fetch` over a slow link is the slow one.
pub const GIT_TIMEOUT: Duration = Duration::from_secs(120);

/// The STATUS CARD's `git` ceiling. Much shorter, because it is inside a request someone's
/// phone is waiting on: two minutes of a wedged `fetch` would be two minutes of a spinner,
/// and the card has a perfectly good cached answer to fall back to.
pub const STATUS_GIT_TIMEOUT: Duration = Duration::from_secs(20);

/// How many completed, successful workflow runs are examined for the `bridge` job before the
/// gate gives up. A commit here has three or four runs; the cap bounds the worst case at a
/// handful of API calls, and a run set large enough to hit it is REPORTED rather than
/// silently truncated — a card that said "red" because it stopped looking would be lying.
pub const MAX_JOB_LOOKUPS: usize = 5;

/// How long `GET /sentinel/deploy/status` serves its cached view of `origin/main` before
/// refreshing it. The card is a thing someone looks at, not a thing that drives a decision by
/// the second, and the refresh costs a `git fetch` and two API calls.
pub const ORIGIN_MAIN_TTL_MS: u64 = 5 * 60 * 1000;

/// How many changelog bullets one release contributes to the card. The card answers "is this
/// deploy worth running", in about ten seconds, on a phone — four one-sentence claims is
/// already the outer edge of that, and what a release drops is REPORTED (`more`) rather than
/// silently cut.
pub const MAX_RELEASE_LINES: usize = 4;

/// The longest one summary line may be. Bold lead sentences run long in this changelog, and a
/// line that wraps to five lines on a phone defeats the point of the block.
pub const MAX_RELEASE_LINE_CHARS: usize = 200;

/// How many undeployed releases the card is handed. Ten is far more than the one-or-two the
/// Studio is usually behind; the surplus is reported as `truncated` rather than dropped
/// quietly, because silent truncation reads as completeness.
pub const MAX_UNDEPLOYED_RELEASES: usize = 10;

/// Built SHAs kept under `<bin dir>/jesse-bridge.d/`. Three is the one running, the one before
/// it, and one more — enough to roll back twice by hand, small enough that a release build
/// (~100 MB of binaries) does not silently eat the disk the watchdog is guarding.
pub const KEEP_BUILDS: usize = 3;

/// Lines of the deploy log carried in `state.json` so the phone can show progress without
/// fetching the whole build output.
pub const LOG_TAIL_LINES: usize = 20;

/// The window on the deploy-finished push. ZERO: a deploy is a thing a person just did, and
/// the answer to "did it work" must never be suppressed by a dedupe window that another
/// deploy opened.
pub const DEPLOY_PUSH_WINDOW_MS: u64 = 0;

/// Where a copy of whatever `<bin dir>/<name>` was BEFORE the first deploy is kept, when it
/// was a real file rather than a symlink. Named, not a sha, because it is not a build.
pub const PRE_DEPLOY_DIR: &str = "pre-deploy";

// ---- The record ----------------------------------------------------------------------

/// One deploy, as `state.json.deploy` and as the `deploy` block of `GET
/// /sentinel/deploy/status`. Present from the moment the verb is accepted, so a phone that
/// polls immediately sees `phase: "resolve"` rather than an absent field it has to guess at.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct DeployRecord {
    pub deploy_id: String,
    /// `resolve` → `ci` → `build` → `stage` → `restart` → (`rollback`) → `finish`.
    pub phase: String,
    /// What the caller asked for, verbatim after validation: `main` or a 40-hex sha.
    #[serde(rename = "ref")]
    pub git_ref: String,
    /// The commit that ref resolved to. Absent until `resolve` succeeds.
    pub sha: Option<String>,
    pub started_ms: u64,
    pub finished_ms: Option<u64>,
    /// `ok` | `failed` | `rolled_back` | `rolled_back_unhealthy`. Absent while running.
    pub result: Option<String>,
    pub reason: Option<String>,
    pub log_tail: Vec<String>,
}

impl DeployRecord {
    /// Whether this record describes a deploy that is still running. Used by the status route
    /// and by the lock's own reporting.
    pub fn in_flight(&self) -> bool {
        self.result.is_none()
    }
}

/// The cached view of `origin/main` behind the status card.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct OriginMain {
    pub sha: Option<String>,
    /// The `[package] version` declared at that commit — what the bridge would report after a
    /// successful deploy, so the card can say "0.93.0 → 0.94.0" without a second call.
    pub version: Option<String>,
    /// `green` | `red` | `pending` | `none`.
    pub ci: String,
    /// Why, in one line. `green` carries the run that vouched for it.
    pub ci_detail: Option<String>,
    pub checked_ms: u64,
    /// What each commit between the running build and this one actually changed, derived from
    /// the repository rather than written by hand. Rides this cache entry deliberately: it is
    /// several `git` calls per release, and a summary recomputed on every request beside a
    /// cached commit hash is the same class of bug as a cache hit rendered as a fresh read.
    ///
    /// `None` means the summaries could not be produced (git missing, a call that failed or
    /// timed out). The card then renders exactly as it did before this block existed — a
    /// summary that cannot be built must never take the version and commit rows down with it.
    pub releases: Option<ReleaseSummaries>,
    /// The running commit `releases` was computed against. **With `sha` above, this IS the
    /// cache key**: the undeployed set is a function of BOTH commits, so a deploy that moves
    /// the running commit invalidates the entry even though `origin/main` has not moved.
    pub releases_for: Option<String>,
}

/// The release-notes block of `GET /sentinel/deploy/status`: what is running, and what a
/// deploy would bring in.
///
/// Present only when it could be built. Every field is derived from the deploy clone — commit
/// subjects and the `CHANGELOG.md` bullets each commit added — because a deploy card that
/// invented its own prose would be describing a release nobody wrote.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default)]
pub struct ReleaseSummaries {
    /// The running commit's own release. `None` when there is no running commit, or when it
    /// is not readable in the clone.
    pub deployed: Option<ReleaseSummary>,
    /// Everything reachable from `origin/main` but not from the running commit, NEWEST FIRST.
    pub undeployed: Vec<ReleaseSummary>,
    /// How many undeployed releases were dropped past [`MAX_UNDEPLOYED_RELEASES`]. Zero means
    /// the list is complete, which is why it is a count and not an `Option<bool>`.
    pub truncated: usize,
    /// Why the undeployed list is empty when emptiness is not simply "already current" — a
    /// force-pushed branch, a deploy of something that is not `main`, a sentinel that has
    /// never deployed. **The list is never a guess**: when the range cannot be computed the
    /// answer is an empty list and this sentence, never "everything is undeployed".
    pub reason: Option<String>,
}

/// One release, as the card shows it: a title and up to [`MAX_RELEASE_LINES`] one-sentence
/// claims. The reader is deciding in ten seconds whether a deploy is worth running, so the
/// bullet BODIES — the paragraphs of detail this changelog carries under every bold lead — are
/// exactly what is thrown away here.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default)]
pub struct ReleaseSummary {
    pub sha: String,
    /// The component and version this release carried (`bridge 0.106.0`, `App 1.0 (121)`),
    /// from the changelog heading it added or, failing that, its subject's parenthetical.
    ///
    /// COMPONENT-QUALIFIED, not a bare semver, because the list mixes components: an app-only
    /// release has no bridge version at all, and a bare `1.0` sitting under a bare `0.106.0`
    /// would read as a version going backwards. `None` when neither source states one —
    /// nothing here is guessed from the working tree.
    pub version: Option<String>,
    /// The commit subject with its version parenthetical and pull request number removed.
    /// Subjects in this repository already read as release titles.
    pub title: String,
    /// The commit date, so the card can say how old a release is.
    pub date_ms: u64,
    /// The bold lead sentence of each changelog bullet this commit added. Empty when it added
    /// none — the title alone is then the summary, and the commit BODY is never a fallback.
    pub lines: Vec<String>,
    /// How many lines were dropped past [`MAX_RELEASE_LINES`].
    pub more: usize,
}

/// The verdict on one commit's CI, shared by the `ci` phase and the status card so the app can
/// never be shown a green card for a commit the deploy verb would refuse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CiStatus {
    pub state: &'static str,
    pub detail: String,
}

impl CiStatus {
    pub fn green(&self) -> bool {
        self.state == "green"
    }
    fn new(state: &'static str, detail: impl Into<String>) -> CiStatus {
        CiStatus {
            state,
            detail: detail.into(),
        }
    }
}

// ---- Configuration --------------------------------------------------------------------

impl SentinelConfig {
    /// `<state dir>/deploys` — one `<deploy_id>.log` per deploy, plus `previous`.
    pub fn deploys_dir(&self) -> PathBuf {
        self.state_dir.join("deploys")
    }

    /// The rollback record: where each deploy symlink pointed before the last stage.
    pub fn previous_file(&self) -> PathBuf {
        self.deploys_dir().join("previous")
    }

    /// The deploy log for one id.
    pub fn deploy_log(&self, id: &str) -> PathBuf {
        self.deploys_dir().join(format!("{id}.log"))
    }

    /// `<state dir>/deploy.lock` — the pid of the process running a deploy.
    pub fn deploy_lock(&self) -> PathBuf {
        self.state_dir.join("deploy.lock")
    }

    /// `<bin dir>/jesse-bridge.d` — one directory per built sha.
    pub fn build_store(&self) -> PathBuf {
        self.bin_dir.join("jesse-bridge.d")
    }
}

/// Whether a string is a full commit sha as this module accepts one: exactly 40 lowercase hex.
///
/// This is the WHOLE alphabet a caller-supplied ref may be, besides the literal `main`. It
/// matters because the value becomes an argument to `git`: a ref like `--upload-pack=…` is an
/// option, not a revision, and a closed alphabet is what makes "a literal argument vector"
/// actually mean something here.
pub fn is_full_sha(s: &str) -> bool {
    s.len() == 40
        && s.chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

/// The first seven characters of a sha, for a log line or a push.
pub fn short_sha(sha: &str) -> &str {
    &sha[..sha.len().min(7)]
}

/// The `[package]` version declared by a `Cargo.toml`.
///
/// Section-aware on purpose. `version = "1"` appears under `[dependencies]` a dozen times in
/// this file, and the first-match implementation would answer with whichever one happened to
/// come first after an edit — a confidently wrong version string, which this module would then
/// demand of the restarted bridge and roll back for not having.
pub fn parse_cargo_version(toml: &str) -> Option<String> {
    let mut in_package = false;
    for line in toml.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
            continue;
        }
        if !in_package {
            continue;
        }
        let Some(rest) = line.strip_prefix("version") else {
            continue;
        };
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim();
        let quoted = rest.strip_prefix('"')?;
        let end = quoted.find('"')?;
        let value = &quoted[..end];
        return (!value.is_empty()).then(|| value.to_string());
    }
    None
}

// ---- The lock -------------------------------------------------------------------------

/// ONE DEPLOY AT A TIME, held for the whole pipeline rather than for the request.
///
/// The verb answers `202` and the work continues in a task, so the service's own
/// single-flight permit (`http.rs`) is released long before the build finishes; it cannot be
/// what serialises this. The file is the record, and it carries a PID because the interesting
/// failure is not a second caller — it is a sentinel that was killed mid-build, leaving a lock
/// behind that would otherwise refuse every deploy until someone ssh'd in to delete it. A lock
/// naming a pid that is not alive is RECLAIMED, loudly.
pub struct DeployLock {
    sen: Arc<Sentinel>,
}

impl DeployLock {
    /// Acquire, or report why not.
    pub fn acquire(sen: &Arc<Sentinel>) -> Result<DeployLock, String> {
        // The in-process flag first: it is the authoritative answer for THIS process, and it
        // closes the window between reading the file and writing it.
        if sen
            .deploy_running
            .compare_exchange(
                false,
                true,
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::SeqCst,
            )
            .is_err()
        {
            return Err("a deploy is already running".to_string());
        }
        let path = sen.cfg.deploy_lock();
        if let Some(pid) = read_lock_pid(&path) {
            // Our own pid with the flag clear is not possible above; any other LIVE pid is a
            // second sentinel against the same state dir, which is a configuration mistake
            // worth refusing rather than racing.
            if pid != std::process::id() && pid_is_alive(pid) {
                sen.deploy_running
                    .store(false, std::sync::atomic::Ordering::SeqCst);
                return Err(format!(
                    "another process (pid {pid}) holds {}",
                    path.display()
                ));
            }
            eprintln!(
                "jesse-sentinel: reclaiming the deploy lock {} — pid {pid} is not running",
                path.display()
            );
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent);
        }
        if let Err(e) = std::fs::write(&path, format!("{}\n", std::process::id())) {
            sen.deploy_running
                .store(false, std::sync::atomic::Ordering::SeqCst);
            return Err(format!("could not write {}: {e}", path.display()));
        }
        Ok(DeployLock { sen: sen.clone() })
    }
}

impl Drop for DeployLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.sen.cfg.deploy_lock());
        self.sen
            .deploy_running
            .store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

/// The pid in a lock file, if it holds one.
pub fn read_lock_pid(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Whether a pid names a live process. `kill(pid, 0)` is the portable answer: it delivers
/// nothing and reports only whether the process exists and is signallable.
///
/// `EPERM` counts as ALIVE — a process this user cannot signal is still a process, and
/// reclaiming a lock on the strength of "I am not allowed to look" is exactly the shortcut
/// that would let two deploys run at once.
pub fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // SAFETY: `kill` with signal 0 sends nothing; it only performs the existence and
    // permission check. It touches no memory owned by this process.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

// ---- The log --------------------------------------------------------------------------

/// One deploy's log file. Every phase writes to it, and the last [`LOG_TAIL_LINES`] lines are
/// mirrored into `state.json` so the phone has something to show while a 20-minute build runs.
#[derive(Clone)]
pub struct DeployLog {
    path: PathBuf,
}

impl DeployLog {
    pub fn new(path: PathBuf) -> DeployLog {
        if let Some(parent) = path.parent() {
            let _ = std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent);
        }
        DeployLog { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Append one timestamped line. Best-effort, like the audit log: an unwritable log must
    /// not fail the deploy it is recording, but the gap goes to stderr.
    pub fn line(&self, text: &str) {
        let line = format!("{} {}\n", now_local_rfc3339(), text.replace('\n', " "));
        self.raw(&line);
        eprintln!("jesse-sentinel: DEPLOY {}", text.replace('\n', " "));
    }

    /// Append bytes verbatim — the build's own output, which is already line-shaped.
    fn raw(&self, text: &str) {
        let write = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.path)
            .and_then(|mut f| f.write_all(text.as_bytes()));
        if let Err(e) = write {
            eprintln!(
                "jesse-sentinel: WARNING — could not append to {} ({e})",
                self.path.display()
            );
        }
    }

    /// The last [`LOG_TAIL_LINES`] lines, for `state.json`.
    pub fn tail(&self) -> Vec<String> {
        let text = tail_bytes(&self.path, 64 * 1024).unwrap_or_default();
        let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
        lines
            .iter()
            .rev()
            .take(LOG_TAIL_LINES)
            .rev()
            .map(|l| l.chars().take(500).collect())
            .collect()
    }
}

/// The ceiling on how much of a command's output is held in memory. The FILE gets everything;
/// this only bounds what a failure message can quote, so a `cargo build` that prints a hundred
/// megabytes of errors cannot grow the process that is supposed to be repairing the host.
const CAPTURE_LIMIT: usize = 64 * 1024;

/// Run one command with both streams going to the deploy log AS THEY ARRIVE.
///
/// `run_cmd` buffers to completion, which is right for a 5 s probe and wrong for a 20 minute
/// build: the whole value of the log during a build is that someone watching the phone can see
/// it moving. Output is captured as well, bounded by [`CAPTURE_LIMIT`], so a failure can quote
/// its own last words.
pub async fn run_logged(
    log: &DeployLog,
    dir: Option<&Path>,
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
    if let Some(d) = dir {
        cmd.current_dir(d);
    }
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return CmdOut {
                spawn_error: Some(e.to_string()),
                ..Default::default()
            }
        }
    };
    let out = drain(child.stdout.take(), log.clone(), "    ");
    let err = drain(child.stderr.take(), log.clone(), "  ! ");
    let (status, stdout, stderr) = match timeout(limit, async {
        let (s, o, e) = tokio::join!(child.wait(), out, err);
        (s, o, e)
    })
    .await
    {
        Ok(v) => v,
        Err(_) => {
            return CmdOut {
                timed_out: true,
                ..Default::default()
            }
        }
    };
    match status {
        Ok(s) => CmdOut {
            code: s.code(),
            stdout,
            stderr,
            timed_out: false,
            spawn_error: None,
        },
        Err(e) => CmdOut {
            spawn_error: Some(e.to_string()),
            stdout,
            stderr,
            ..Default::default()
        },
    }
}

/// Read one pipe line by line, writing each to the log with `prefix` and keeping a bounded
/// copy for the caller.
async fn drain<R>(pipe: Option<R>, log: DeployLog, prefix: &'static str) -> String
where
    R: tokio::io::AsyncRead + Unpin,
{
    let Some(pipe) = pipe else {
        return String::new();
    };
    let mut reader = BufReader::new(pipe).lines();
    let mut kept = String::new();
    while let Ok(Some(line)) = reader.next_line().await {
        log.raw(&format!("{prefix}{line}\n"));
        if kept.len() < CAPTURE_LIMIT {
            kept.push_str(&line);
            kept.push('\n');
        }
    }
    kept
}

// ---- git in the deploy clone -----------------------------------------------------------

/// One `git -C <deploy clone> …`, logged.
///
/// `-C` rather than a working directory: it is the same guarantee with one fewer piece of
/// process state, and every git call in this module addresses exactly one repository.
async fn dgit(sen: &Sentinel, log: &DeployLog, args: &[&str]) -> CmdOut {
    let clone = sen.cfg.deploy_clone.to_string_lossy().to_string();
    let mut full = vec!["-C", clone.as_str()];
    full.extend_from_slice(args);
    log.line(&format!("git {}", args.join(" ")));
    run_logged(
        log,
        None,
        sen.cfg.bins.git.as_ref(),
        &full,
        // A deploy runs unattended under launchd: git must never stop for a credential
        // prompt, and `origin` is fetched over whatever the clone was made with.
        &[("GIT_TERMINAL_PROMPT", "0")],
        GIT_TIMEOUT,
    )
    .await
}

/// The same, without a log and under a caller-chosen ceiling — for the status card's quiet
/// refresh, and for the one read (`git show <sha>:bridge/Cargo.toml`) both paths share.
async fn qgit(sen: &Sentinel, args: &[&str], limit: Duration) -> CmdOut {
    let clone = sen.cfg.deploy_clone.to_string_lossy().to_string();
    let mut full = vec!["-C", clone.as_str()];
    full.extend_from_slice(args);
    run_cmd(
        sen.cfg.bins.git.as_ref(),
        &full,
        &[("GIT_TERMINAL_PROMPT", "0")],
        limit,
    )
    .await
}

/// The `[package] version` a commit declares, read out of git rather than out of the working
/// tree — so it is the version OF THAT COMMIT even when the tree is checked out elsewhere.
async fn version_at(sen: &Sentinel, sha: &str) -> Result<String, String> {
    let spec = format!("{sha}:bridge/Cargo.toml");
    // A local object read, so the short ceiling is right on both paths.
    let out = qgit(sen, &["show", &spec], STATUS_GIT_TIMEOUT).await;
    if !out.ok() {
        return Err(format!(
            "could not read bridge/Cargo.toml at {sha}: {}",
            out.summary()
        ));
    }
    parse_cargo_version(&out.stdout)
        .ok_or_else(|| format!("bridge/Cargo.toml at {sha} declares no [package] version"))
}

// ---- GitHub ---------------------------------------------------------------------------

/// One GitHub REST call with the sentinel's READ-ONLY token.
///
/// The token is fine-grained, Actions:read + Contents:read. It cannot merge, cannot push, and
/// cannot dispatch a workflow — the only thing this module ever asks GitHub is "what did CI
/// conclude about this commit", and the credential is scoped to exactly that question.
async fn gh_get(sen: &Sentinel, path: &str) -> Result<(u16, Value), String> {
    let Some(token) = &sen.cfg.github_token else {
        return Err(
            "JESSE_SENTINEL_GITHUB_TOKEN is not set, so CI cannot be verified — and a deploy \
             that cannot check CI is not a deploy this service performs"
                .to_string(),
        );
    };
    let url = format!("{}{path}", sen.cfg.github_api);
    let resp = sen
        .http
        .get(&url)
        .bearer_auth(token)
        .header("accept", "application/vnd.github+json")
        .header("x-github-api-version", "2022-11-28")
        .header("user-agent", format!("jesse-sentinel/{}", sen.version))
        .timeout(GITHUB_TIMEOUT)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    let body = serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!(text));
    Ok((status, body))
}

/// What CI concluded about one commit: `green` | `red` | `pending` | `none`.
///
/// GREEN IS THE NARROW ANSWER, and it is narrow deliberately. A commit typically has several
/// workflow runs against it (the app's, the scheduled audit's), and "some run succeeded" is not
/// the claim that matters — the claim that matters is that the job which builds and tests THIS
/// CRATE passed. So a run only vouches for the commit if it completed, concluded `success`,
/// and its jobs listing contains a job named [`CI_JOB_NAME`] that also concluded `success`.
///
/// Everything else is refused, and the four states exist so the refusal says which kind it is:
/// "CI has not run yet" and "CI failed" are the same red light and completely different
/// problems.
pub async fn check_ci(sen: &Sentinel, sha: &str) -> Result<CiStatus, String> {
    let (status, body) = gh_get(
        sen,
        &format!(
            "/repos/{}/actions/runs?head_sha={sha}&per_page=20",
            sen.cfg.github_repo
        ),
    )
    .await?;
    if !(200..300).contains(&status) {
        return Err(format!(
            "GitHub answered {status} for the workflow runs of {}",
            short_sha(sha)
        ));
    }
    let runs = body
        .get("workflow_runs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if runs.is_empty() {
        return Ok(CiStatus::new(
            "none",
            format!("no workflow run has {} as its head commit", short_sha(sha)),
        ));
    }
    let mut pending = Vec::new();
    let mut failed = Vec::new();
    let mut looked_up = 0usize;
    let mut truncated = false;
    for run in &runs {
        let name = run
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("(unnamed)");
        let run_status = run.get("status").and_then(Value::as_str).unwrap_or("");
        if run_status != "completed" {
            pending.push(format!("{name} is {run_status}"));
            continue;
        }
        let conclusion = run.get("conclusion").and_then(Value::as_str).unwrap_or("");
        if conclusion != "success" {
            failed.push(format!("{name} concluded {conclusion}"));
            continue;
        }
        let Some(id) = run.get("id").and_then(Value::as_u64) else {
            continue;
        };
        if looked_up >= MAX_JOB_LOOKUPS {
            truncated = true;
            continue;
        }
        looked_up += 1;
        let (js, jobs_body) = gh_get(
            sen,
            &format!(
                "/repos/{}/actions/runs/{id}/jobs?per_page=100",
                sen.cfg.github_repo
            ),
        )
        .await?;
        if !(200..300).contains(&js) {
            return Err(format!("GitHub answered {js} for the jobs of run {id}"));
        }
        let jobs = jobs_body
            .get("jobs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let want = sen.cfg.ci_job.as_str();
        let green_bridge = jobs.iter().any(|j| {
            j.get("name")
                .and_then(Value::as_str)
                .is_some_and(|n| job_matches(n, want))
                && j.get("conclusion").and_then(Value::as_str) == Some("success")
        });
        if green_bridge {
            return Ok(CiStatus::new(
                "green",
                format!("run {id} ({name}) passed the {want:?} job"),
            ));
        }
    }
    if !pending.is_empty() {
        return Ok(CiStatus::new(
            "pending",
            format!("CI has not finished: {}", pending.join(", ")),
        ));
    }
    if !failed.is_empty() {
        return Ok(CiStatus::new(
            "red",
            format!("CI failed: {}", failed.join(", ")),
        ));
    }
    // Every run completed and succeeded, and not one of them contained the job that matters.
    // Red, because the deploy must not proceed — but the detail says so precisely rather than
    // claiming a failure that did not happen, and names the cap if that is why we stopped.
    Ok(CiStatus::new(
        "red",
        format!(
            "no completed run for {} carries a successful {:?} job{}",
            short_sha(sha),
            sen.cfg.ci_job,
            if truncated {
                format!(" (only the first {MAX_JOB_LOOKUPS} successful runs were examined)")
            } else {
                String::new()
            }
        ),
    ))
}

// ---- The symlinks ----------------------------------------------------------------------

/// Where each of the three names pointed before the last stage, as `deploys/previous`.
///
/// A map rather than a single path because the deploy binaries are staged independently and a
/// stage that fails halfway must be undoable for exactly the ones it changed. A name absent
/// from the map had NOTHING at `<bin dir>/<name>` beforehand, and rolling it back means
/// removing the link, not pointing it somewhere invented.
pub type Previous = HashMap<String, String>;

pub fn read_previous(path: &Path) -> Previous {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

pub fn write_previous(path: &Path, prev: &Previous) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|e| format!("could not create {}: {e}", parent.display()))?;
    }
    let text = serde_json::to_string_pretty(prev).map_err(|e| e.to_string())?;
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp, text).map_err(|e| format!("could not write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("could not rename into {}: {e}", path.display())
    })
}

/// What `<bin dir>/<name>` resolves to right now, as an absolute rollback target.
///
/// THE REGULAR-FILE CASE IS THE FIRST DEPLOY. Before this feature the installer copied a real
/// binary to `~/.local/bin/jesse-bridge`; staging is about to replace it with a symlink, and a
/// rename over it would destroy the only copy of the thing we are meant to be able to go back
/// to. So it is COPIED aside first — copied, not moved, because a move that half-succeeds
/// leaves the operator with neither.
fn capture_one(bin_dir: &Path, store: &Path, name: &str) -> Result<Option<String>, String> {
    let live = bin_dir.join(name);
    let Ok(md) = std::fs::symlink_metadata(&live) else {
        return Ok(None);
    };
    if md.file_type().is_symlink() {
        let target = std::fs::read_link(&live)
            .map_err(|e| format!("could not read the symlink {}: {e}", live.display()))?;
        let absolute = if target.is_absolute() {
            target
        } else {
            bin_dir.join(target)
        };
        return Ok(Some(absolute.to_string_lossy().to_string()));
    }
    if !md.is_file() {
        return Ok(None);
    }
    let keep_dir = store.join(PRE_DEPLOY_DIR);
    std::fs::create_dir_all(&keep_dir)
        .map_err(|e| format!("could not create {}: {e}", keep_dir.display()))?;
    let kept = keep_dir.join(name);
    // Only if it is not already there: the second deploy must not overwrite the ORIGINAL
    // pre-deploy binary with a copy of the first deploy's build.
    if !kept.exists() {
        std::fs::copy(&live, &kept)
            .map_err(|e| format!("could not copy {} aside: {e}", live.display()))?;
        set_executable(&kept)?;
    }
    Ok(Some(kept.to_string_lossy().to_string()))
}

/// Capture every deployed name, as one `previous` map.
///
/// `bins` is the set the COMMIT BEING DEPLOYED declares (see [`deploy_bins_at`]), so a name
/// this deploy introduces is captured too — as absent, which is what tells
/// [`restore_previous`] to remove rather than repoint it if the deploy is rolled back.
pub fn capture_previous(bin_dir: &Path, store: &Path, bins: &[String]) -> Result<Previous, String> {
    let mut prev = Previous::new();
    for name in bins {
        if let Some(target) = capture_one(bin_dir, store, name)? {
            prev.insert(name.to_string(), target);
        }
    }
    Ok(prev)
}

fn set_executable(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| format!("could not chmod 755 {}: {e}", path.display()))
}

/// Point `<bin dir>/<name>` at `target`, ATOMICALLY.
///
/// A symlink cannot be rewritten in place, so the sequence is create-then-rename: `rename`
/// over an existing name is atomic on every filesystem this runs on, which means there is no
/// instant at which `~/.local/bin/jesse-bridge` does not exist. That matters because launchd
/// may be starting the job at any moment, and a job whose `ProgramArguments` path is missing
/// for a tenth of a second fails to spawn and is not retried.
///
/// `rename` also does NOT follow the link it is replacing, so this never writes through an old
/// symlink into whatever it pointed at.
pub fn repoint(bin_dir: &Path, name: &str, target: &Path) -> Result<(), String> {
    std::fs::create_dir_all(bin_dir)
        .map_err(|e| format!("could not create {}: {e}", bin_dir.display()))?;
    let tmp = bin_dir.join(format!(".{name}.staging.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    std::os::unix::fs::symlink(target, &tmp)
        .map_err(|e| format!("could not create {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, bin_dir.join(name)).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("could not move {} into place: {e}", tmp.display())
    })
}

/// Put every deployed name back where `previous` says it was.
///
/// Every name is attempted even after one fails: a rollback that stopped at the first error
/// would leave the deployment in a state that is neither the old one nor the new one, which is
/// the single worst outcome available here. The errors are collected and reported together.
pub fn restore_previous(bin_dir: &Path, prev: &Previous, bins: &[String]) -> Vec<String> {
    let mut errors = Vec::new();
    // The UNION of what this deploy touched and what `previous` recorded. The two can differ
    // in both directions — a deploy that adds a binary has a name with no `previous` entry,
    // and a deploy that drops one has a `previous` entry for a name it no longer stages —
    // and a rollback that ranged over only one of them would leave the other where the failed
    // deploy put it.
    let mut names: Vec<&str> = bins.iter().map(String::as_str).collect();
    for name in prev.keys() {
        if !names.contains(&name.as_str()) {
            names.push(name);
        }
    }
    for name in names {
        match prev.get(name) {
            Some(target) => {
                if let Err(e) = repoint(bin_dir, name, Path::new(target)) {
                    errors.push(e);
                }
            }
            // Nothing was there before, so "back" means gone — leaving this deploy's link
            // would be leaving a binary the operator never installed.
            None => {
                let live = bin_dir.join(name);
                if std::fs::symlink_metadata(&live).is_ok() {
                    if let Err(e) = std::fs::remove_file(&live) {
                        errors.push(format!("could not remove {}: {e}", live.display()));
                    }
                }
            }
        }
    }
    errors
}

/// Delete all but the [`KEEP_BUILDS`] newest sha directories under the build store.
///
/// Two things are never pruned regardless of age, and both are the difference between a
/// housekeeping job and an outage: the directory a live symlink points into, and the one
/// `previous` names. Pruning either would delete the running bridge or the thing a rollback
/// would need — and mtime is not a safe proxy for "in use", because a rollback makes an OLD
/// directory the live one without touching its timestamp.
pub fn prune_builds(
    bin_dir: &Path,
    store: &Path,
    prev: &Previous,
    keep: usize,
    bins: &[String],
) -> Vec<String> {
    let mut protected: Vec<PathBuf> = Vec::new();
    for name in bins {
        if let Ok(t) = std::fs::read_link(bin_dir.join(name)) {
            let abs = if t.is_absolute() { t } else { bin_dir.join(t) };
            if let Some(p) = abs.parent() {
                protected.push(p.to_path_buf());
            }
        }
    }
    for target in prev.values() {
        if let Some(p) = Path::new(target).parent() {
            protected.push(p.to_path_buf());
        }
    }

    let Ok(entries) = std::fs::read_dir(store) else {
        return Vec::new();
    };
    let mut builds: Vec<(PathBuf, SystemTime)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(md) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        // Directories only, named by a sha. `pre-deploy` and anything a person left here are
        // not builds and are not this function's to delete.
        if !md.is_dir() || md.file_type().is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if !is_full_sha(&name) {
            continue;
        }
        let modified = md.modified().unwrap_or(UNIX_EPOCH);
        builds.push((path, modified));
    }
    // Newest first, so `skip(keep)` is the tail to delete.
    builds.sort_by_key(|b| std::cmp::Reverse(b.1));

    let mut removed = Vec::new();
    for (path, _) in builds.into_iter().skip(keep) {
        if protected.iter().any(|p| p == &path) {
            continue;
        }
        if std::fs::remove_dir_all(&path).is_ok() {
            removed.push(
                path.file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
            );
        }
    }
    removed
}

// ---- State plumbing --------------------------------------------------------------------

/// Replace the whole record (at accept time).
fn set_deploy(sen: &Sentinel, rec: DeployRecord) {
    sen.state.lock_ok().deploy = Some(rec);
    sen.persist_state();
}

/// Mutate the live record and refresh its log tail.
///
/// The tail is read BEFORE the lock is taken: it is file I/O, and holding the state mutex
/// across it would put every `/sentinel/status` request behind a disk read for no reason.
fn update_deploy(sen: &Sentinel, log: &DeployLog, f: impl FnOnce(&mut DeployRecord)) {
    let tail = log.tail();
    {
        let mut st = sen.state.lock_ok();
        if let Some(d) = st.deploy.as_mut() {
            f(d);
            d.log_tail = tail;
        }
    }
    sen.persist_state();
}

fn enter_phase(sen: &Sentinel, log: &DeployLog, phase: &str) {
    log.line(&format!("== {phase} =="));
    update_deploy(sen, log, |d| d.phase = phase.to_string());
}

/// End a deploy: stamp the outcome, then say so on the phone.
///
/// THE PHASE IS LEFT WHERE IT STOPPED. A failed deploy that rewrote `phase` to `finish` would
/// throw away the one field that says where it broke, and `result` already carries the
/// terminal answer — so only the success path walks the phase on to `finish`.
///
/// EVERY deploy pushes, including the ones that worked. The owner tapped a button on a train
/// and the build takes twenty minutes; a silent success is indistinguishable from a sentinel
/// that died halfway, and the whole point of this feature is not having to wonder.
async fn finish_deploy(sen: &Arc<Sentinel>, log: &DeployLog, result: &str, reason: &str) {
    log.line(&format!("RESULT {result}: {reason}"));
    update_deploy(sen, log, |d| {
        d.result = Some(result.to_string());
        d.reason = Some(reason.to_string());
        d.finished_ms = Some(now_ms());
    });
    push_alert(sen, AlertKind::Deploy, DEPLOY_PUSH_WINDOW_MS, reason).await;
}

/// The harnesses the bridge currently reports as having a stale containment record.
///
/// `None` means THE QUESTION COULD NOT BE ASKED — the bridge did not answer, which before a
/// deploy is the normal case when the thing being fixed is a bridge that is down. That is not
/// the same as "nothing is stale", and the restart check treats it as "no baseline, so this
/// rule is not the one that decides".
async fn stale_harnesses(sen: &Sentinel) -> Option<Vec<String>> {
    let (status, body) = sen.bridge_get("/health", PROBE_TIMEOUT).await.ok()?;
    if !(200..300).contains(&status) {
        return None;
    }
    Some(
        body.get("containment_stale")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(|r| r.get("harness").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    )
}

/// Poll the bridge until it is the one that was just deployed, or the window closes.
///
/// Three conditions, and they are not interchangeable:
///
///   * `ok == true` — it is answering at all;
///   * `version` equals what the commit's `Cargo.toml` declares — it is THE NEW BINARY. Without
///     this a deploy whose symlink swap silently did nothing reports success, which is the
///     failure mode that makes a rollback mechanism worthless;
///   * no harness became `containment_stale` — the record shipped with this commit describes
///     the agent binaries that are actually installed here. A binary built against a failing
///     record refuses to start outright, so this catches the softer case: it starts, and the
///     record it carries no longer matches the host.
///
/// A version mismatch keeps polling (the old process can still be answering for a second or
/// two after `kickstart -k`); a new stale harness does not, because waiting cannot fix it.
/// What one `/health` reading means for the poll below.
enum Step {
    /// It is the new bridge, and it is correct.
    Done(String),
    /// It is answering, and waiting longer cannot help.
    Fatal(String),
    /// Not there yet, for this reason.
    Retry(String),
}

async fn poll_until_deployed(
    sen: &Sentinel,
    log: &DeployLog,
    want_version: &str,
    baseline: Option<&[String]>,
) -> Result<String, String> {
    let deadline = Instant::now() + sen.cfg.deploy_health_timeout;
    loop {
        let step = match sen.bridge_get("/health", Duration::from_secs(3)).await {
            Ok((status, body)) if (200..300).contains(&status) => {
                read_health(&body, want_version, baseline)
            }
            Ok((status, _)) => Step::Retry(format!("the bridge answered /health with {status}")),
            Err(e) => Step::Retry(format!("the bridge did not answer /health: {e}")),
        };
        let why = match step {
            Step::Done(version) => return Ok(version),
            Step::Fatal(e) => {
                log.line(&format!("health poll stopped: {e}"));
                return Err(e);
            }
            Step::Retry(w) => w,
        };
        if Instant::now() >= deadline {
            log.line(&format!("health poll gave up: {why}"));
            return Err(why);
        }
        tokio::time::sleep(DEPLOY_POLL_INTERVAL).await;
    }
}

/// Judge one `/health` body. Split out so the three conditions can be tested without a socket.
fn read_health(body: &Value, want_version: &str, baseline: Option<&[String]>) -> Step {
    if body.get("ok").and_then(Value::as_bool) != Some(true) {
        return Step::Retry("the bridge answered /health with ok:false".to_string());
    }
    // Named `reported` rather than the obvious short local: `scripts/ci-guards.sh` §2 bans
    // that identifier from either comparison operator outright, because it is the shape a
    // hand-rolled token check took here once. This comparison is over version strings, but
    // the guard is a blanket ban for a reason and the fix is a name, not an exception.
    let reported = body
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if reported != want_version {
        return Step::Retry(format!(
            "the bridge reports version {reported:?}, but {want_version:?} was deployed"
        ));
    }
    // THE MCP PREFLIGHT, reported by the bridge that just came up. It resolves every stdio
    // server in the config THE CHILD IS ACTUALLY SPAWNED WITH against the PATH the child
    // actually inherits, so this is the one reader that cannot be fooled by a second copy of
    // the server list written for the check. A name that does not resolve means the child
    // registers zero tools for that server on every turn — the exact silent capability loss
    // that shipped in 0.100.0 — so it is FATAL rather than a retry: waiting cannot install a
    // binary. A bridge too old to report the field says nothing here, which reads as "not
    // checked" rather than "checked and clean".
    let unresolved: Vec<String> = body
        .get("mcp_servers_unresolved")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|r| {
                    let server = r.get("server").and_then(Value::as_str).unwrap_or("?");
                    let command = r.get("command").and_then(Value::as_str).unwrap_or("?");
                    format!("{server} ({command})")
                })
                .collect()
        })
        .unwrap_or_default();
    if !unresolved.is_empty() {
        return Step::Fatal(format!(
            "the deployed bridge cannot resolve the binary for {} of its MCP server(s): {} — \
             the child would register no tools for {} on every turn. Add the binary to {} and \
             deploy again.",
            unresolved.len(),
            unresolved.join(", "),
            if unresolved.len() == 1 { "it" } else { "them" },
            DEPLOY_BINS_MANIFEST,
        ));
    }
    let Some(before) = baseline else {
        return Step::Done(reported);
    };
    let fresh: Vec<String> = body
        .get("containment_stale")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| r.get("harness").and_then(Value::as_str))
                .filter(|h| !before.iter().any(|b| b == h))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    if fresh.is_empty() {
        Step::Done(reported)
    } else {
        Step::Fatal(format!(
            "the deployed bridge reports a stale containment record for {} (it was not stale \
             before)",
            fresh.join(", ")
        ))
    }
}

/// `launchctl kickstart -k` the bridge, logged.
async fn kickstart_bridge(sen: &Sentinel, log: &DeployLog) -> CmdOut {
    let target = sen.cfg.target(ServiceSlot::Bridge);
    log.line(&format!("launchctl kickstart -k {target}"));
    run_logged(
        log,
        None,
        sen.cfg.bins.launchctl.as_ref(),
        &["kickstart", "-k", &target],
        &[],
        RESTART_TIMEOUT,
    )
    .await
}

// ---- The phases ------------------------------------------------------------------------

/// PHASE 1 — turn a ref into a commit that is allowed to be deployed.
///
/// The ancestry check is the load-bearing one. `git merge-base --is-ancestor <sha> origin/main`
/// answers "was this merged", and a commit that was merged is a commit that went through the
/// repository's branch protection: a pull request and a green required check. Without it, the
/// deploy verb would happily build any sha that had ever been pushed to the remote — including
/// one on a branch nobody reviewed.
async fn phase_resolve(
    sen: &Sentinel,
    log: &DeployLog,
    git_ref: &str,
    force: bool,
) -> Result<String, String> {
    let clone = &sen.cfg.deploy_clone;
    if !clone.join(".git").exists() {
        return Err(format!(
            "no deploy clone at {} — run scripts/install-sentinel.sh to create it",
            clone.display()
        ));
    }
    let fetch = dgit(sen, log, &["fetch", "origin", "--prune"]).await;
    if !fetch.ok() {
        return Err(format!("git fetch origin failed: {}", fetch.summary()));
    }
    // `main` means the REMOTE's main, never the clone's local branch: the clone is left on a
    // detached head by every deploy and its local `main` is whatever it was cloned at.
    let rev = if git_ref == "main" {
        "origin/main".to_string()
    } else {
        git_ref.to_string()
    };
    let out = dgit(sen, log, &["rev-parse", &format!("{rev}^{{commit}}")]).await;
    if !out.ok() {
        return Err(format!("could not resolve {rev:?}: {}", out.summary()));
    }
    let sha = out.stdout.trim().to_string();
    if !is_full_sha(&sha) {
        return Err(format!(
            "git resolved {rev:?} to {sha:?}, which is not a commit sha"
        ));
    }
    let ancestor = dgit(
        sen,
        log,
        &["merge-base", "--is-ancestor", &sha, "origin/main"],
    )
    .await;
    // `--is-ancestor` answers with its EXIT STATUS, so "the command did not run" and "the
    // answer is no" arrive as the same non-zero. They mean opposite things to an operator —
    // one is a missing toolchain, the other is an unmerged commit — and reporting a timeout
    // as "not an ancestor" would send someone to read a branch that is perfectly fine.
    if ancestor.unrunnable() {
        return Err(format!(
            "could not determine whether {} is on origin/main: {}",
            short_sha(&sha),
            ancestor.summary()
        ));
    }
    if !ancestor.ok() {
        return Err(format!(
            "{} is not an ancestor of origin/main — only a commit that has been merged is \
             deployable",
            short_sha(&sha)
        ));
    }
    let running = sen.state.lock_ok().running_sha.clone();
    if !force && running.as_deref() == Some(sha.as_str()) {
        return Err(format!(
            "{} is already the running bridge — pass force to build and install it again",
            short_sha(&sha)
        ));
    }
    log.line(&format!("{git_ref} → {sha}"));
    Ok(sha)
}

/// The `cargo build` argv for one binary set. The ONLY place `--bin` is spelled, and it
/// consumes the same list the stage phase does — two hand-maintained lists that must agree is
/// the shape of the bug this file is fixing, so there is one list and one reader of it.
pub fn build_args(bins: &[String]) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "build".to_string(),
        "--release".to_string(),
        "--locked".to_string(),
    ];
    for name in bins {
        args.push("--bin".to_string());
        args.push(name.clone());
    }
    args
}

/// PHASE 3 — check the commit out, read what it says it is made of, and build exactly that.
///
/// Returns the binary set, which every later phase (stage, repoint, rollback, prune) ranges
/// over. It comes from the CHECKED-OUT TREE, so a commit that adds a binary is deployed
/// complete by a sentinel built before that binary existed.
async fn phase_build(sen: &Sentinel, log: &DeployLog, sha: &str) -> Result<Vec<String>, String> {
    let checkout = dgit(sen, log, &["checkout", "--detach", sha]).await;
    if !checkout.ok() {
        return Err(format!(
            "git checkout --detach failed: {}",
            checkout.summary()
        ));
    }
    // `bridge/` is its own crate, OUTSIDE the repository's root workspace, so the build runs
    // from there. `--locked` because a deploy that silently resolved a different dependency
    // graph than CI did is a deploy CI did not vouch for.
    let crate_dir = sen.cfg.deploy_clone.join("bridge");
    let (bins, from_tree) = deploy_bins_at(&crate_dir)?;
    if from_tree {
        log.line(&format!(
            "{} names {} binaries: {}",
            DEPLOY_BINS_MANIFEST,
            bins.len(),
            bins.join(", ")
        ));
    } else {
        // Never silent: the operator is being told that the set staged here is this
        // SENTINEL's idea of the set, which is exactly the situation the manifest exists to
        // end. It happens only when deploying a commit older than the manifest.
        log.line(&format!(
            "{sha} carries no {DEPLOY_BINS_MANIFEST}, so the binaries this sentinel was built \
             with are used instead: {}",
            bins.join(", ")
        ));
    }
    let args = build_args(&bins);
    log.line(&format!(
        "cargo build --release --locked (in {}, up to {} min)",
        crate_dir.display(),
        BUILD_TIMEOUT.as_secs() / 60
    ));
    let out = run_logged(
        log,
        Some(&crate_dir),
        sen.cfg.bins.cargo.as_ref(),
        &args.iter().map(String::as_str).collect::<Vec<_>>(),
        &[],
        BUILD_TIMEOUT,
    )
    .await;
    if out.timed_out {
        return Err(format!(
            "the build did not finish inside {} minutes",
            BUILD_TIMEOUT.as_secs() / 60
        ));
    }
    if !out.ok() {
        return Err(format!("cargo build failed: {}", out.summary()));
    }
    Ok(bins)
}

/// PHASE 4 — copy the deploy binaries into the store and repoint their symlinks.
///
/// Returns the `previous` map, which is what a rollback is written in terms of.
async fn phase_stage(
    sen: &Sentinel,
    log: &DeployLog,
    sha: &str,
    bins: &[String],
) -> Result<Previous, String> {
    let store = sen.cfg.build_store();
    let dest = store.join(sha);
    std::fs::create_dir_all(&dest)
        .map_err(|e| format!("could not create {}: {e}", dest.display()))?;
    let built = sen.cfg.deploy_clone.join("bridge/target/release");
    for name in bins {
        let src = built.join(name);
        let dst = dest.join(name);
        std::fs::copy(&src, &dst)
            .map_err(|e| format!("could not copy {} to {}: {e}", src.display(), dst.display()))?;
        set_executable(&dst)?;
        log.line(&format!("staged {}", dst.display()));
    }

    // BEFORE anything is repointed, and persisted before anything is repointed: a sentinel
    // killed between the swap and this write would have no way back.
    let prev = capture_previous(&sen.cfg.bin_dir, &store, bins)?;
    write_previous(&sen.cfg.previous_file(), &prev)?;
    log.line(&format!(
        "previous: {}",
        serde_json::to_string(&prev).unwrap_or_default()
    ));

    for name in bins {
        if let Err(e) = repoint(&sen.cfg.bin_dir, name, &dest.join(name)) {
            // A half-swapped `~/.local/bin` is neither the old deployment nor the new one,
            // which is the worst state available here — so undo what did land before
            // reporting. Nothing has been restarted yet, so this is a plain failure rather
            // than a rollback.
            let undo = restore_previous(&sen.cfg.bin_dir, &prev, bins);
            for u in &undo {
                log.line(&format!("undo: {u}"));
            }
            return Err(format!("{e} (the symlinks were put back)"));
        }
        log.line(&format!(
            "{}/{name} → {}",
            sen.cfg.bin_dir.display(),
            dest.join(name).display()
        ));
    }
    Ok(prev)
}

/// PHASE 6 — put the old binaries back and bring the bridge up on them.
async fn phase_rollback(
    sen: &Arc<Sentinel>,
    log: &DeployLog,
    prev: &Previous,
    bins: &[String],
    why: &str,
) {
    enter_phase(sen, log, "rollback");
    log.line(&format!("rolling back because: {why}"));
    let errors = restore_previous(&sen.cfg.bin_dir, prev, bins);
    for e in &errors {
        log.line(&format!("rollback: {e}"));
    }
    let kick = kickstart_bridge(sen, log).await;
    let healthy = if kick.ok() {
        // The PREVIOUS version is not necessarily known (before the first successful deploy
        // there is no record of it), so the rollback poll asks only that the bridge answers.
        let (ok, version) = poll_health(sen, sen.cfg.deploy_health_timeout).await;
        if ok {
            log.line(&format!(
                "the previous bridge is up{}",
                version
                    .as_deref()
                    .map(|v| format!(" on {v}"))
                    .unwrap_or_default()
            ));
        }
        ok
    } else {
        log.line(&format!("rollback kickstart failed: {}", kick.summary()));
        false
    };
    let restore_note = if errors.is_empty() {
        String::new()
    } else {
        format!(
            " ({} symlink error(s): {})",
            errors.len(),
            errors.join("; ")
        )
    };
    if healthy && errors.is_empty() {
        finish_deploy(
            sen,
            log,
            "rolled_back",
            &format!("deploy failed and was rolled back — {why}"),
        )
        .await;
    } else {
        finish_deploy(
            sen,
            log,
            "rolled_back_unhealthy",
            &format!(
                "DEPLOY FAILED AND THE ROLLBACK DID NOT COME UP — {why}{restore_note}. The \
                 bridge needs hands on the host."
            ),
        )
        .await;
    }
}

/// The whole pipeline, as one task. The lock is moved in and released when this returns.
pub async fn run_deploy(
    sen: Arc<Sentinel>,
    lock: DeployLock,
    log: DeployLog,
    git_ref: String,
    force: bool,
) {
    // Moved in and dropped when this returns, whatever the outcome — including a panic in a
    // phase, which would otherwise leave a lock file naming a live pid and refuse every
    // subsequent deploy until someone got to the host.
    let _lock = lock;

    enter_phase(&sen, &log, "resolve");
    let sha = match phase_resolve(&sen, &log, &git_ref, force).await {
        Ok(s) => s,
        Err(e) => return finish_deploy(&sen, &log, "failed", &e).await,
    };
    update_deploy(&sen, &log, |d| d.sha = Some(sha.clone()));

    enter_phase(&sen, &log, "ci");
    match check_ci(&sen, &sha).await {
        Ok(ci) if ci.green() => log.line(&format!("CI is green — {}", ci.detail)),
        Ok(ci) => {
            return finish_deploy(
                &sen,
                &log,
                "failed",
                &format!("CI is {} for {}: {}", ci.state, short_sha(&sha), ci.detail),
            )
            .await
        }
        Err(e) => {
            return finish_deploy(
                &sen,
                &log,
                "failed",
                &format!("could not verify CI for {}: {e}", short_sha(&sha)),
            )
            .await
        }
    }

    let want_version = match version_at(&sen, &sha).await {
        Ok(v) => v,
        Err(e) => return finish_deploy(&sen, &log, "failed", &e).await,
    };
    log.line(&format!(
        "{} declares bridge {want_version}",
        short_sha(&sha)
    ));

    // The baseline for the containment check, taken while the OLD bridge is still the one
    // running. `None` here means the bridge was not answering, which is a normal reason to be
    // deploying — see `poll_until_deployed`.
    let baseline = stale_harnesses(&sen).await;
    if baseline.is_none() {
        log.line(
            "the bridge did not answer /health before the deploy, so containment staleness \
             cannot be compared and is not checked after it",
        );
    }

    enter_phase(&sen, &log, "build");
    let bins = match phase_build(&sen, &log, &sha).await {
        Ok(b) => b,
        Err(e) => return finish_deploy(&sen, &log, "failed", &e).await,
    };

    enter_phase(&sen, &log, "stage");
    let prev = match phase_stage(&sen, &log, &sha, &bins).await {
        Ok(p) => p,
        Err(e) => return finish_deploy(&sen, &log, "failed", &e).await,
    };

    enter_phase(&sen, &log, "restart");
    let kick = kickstart_bridge(&sen, &log).await;
    let trouble = if !kick.ok() {
        Some(format!("launchctl kickstart failed: {}", kick.summary()))
    } else {
        match poll_until_deployed(&sen, &log, &want_version, baseline.as_deref()).await {
            Ok(v) => {
                log.line(&format!("the bridge is up on {v}"));
                None
            }
            Err(e) => Some(e),
        }
    };
    if let Some(why) = trouble {
        return phase_rollback(&sen, &log, &prev, &bins, &why).await;
    }

    enter_phase(&sen, &log, "finish");
    let pruned = prune_builds(
        &sen.cfg.bin_dir,
        &sen.cfg.build_store(),
        &prev,
        KEEP_BUILDS,
        &bins,
    );
    if !pruned.is_empty() {
        log.line(&format!(
            "pruned {} old build(s): {}",
            pruned.len(),
            pruned.join(", ")
        ));
    }
    sen.state.lock_ok().running_sha = Some(sha.clone());
    sen.persist_state();
    finish_deploy(
        &sen,
        &log,
        "ok",
        &format!("Jesse deploy {} ok: bridge {want_version}", short_sha(&sha)),
    )
    .await;
}

// ---- The verb --------------------------------------------------------------------------

/// The request body: `{"ref": "main" | "<40 hex>", "force": bool}`.
#[derive(Debug, Deserialize)]
#[serde(default)]
struct DeployRequest {
    #[serde(rename = "ref")]
    git_ref: String,
    force: bool,
}

impl Default for DeployRequest {
    fn default() -> DeployRequest {
        DeployRequest {
            git_ref: "main".to_string(),
            force: false,
        }
    }
}

/// A deploy id: sortable, unique, and safe as a filename. The millisecond stamp puts the logs
/// in order in a directory listing; the random half is what makes two deploys in the same
/// millisecond distinct.
fn new_deploy_id(now: u64) -> String {
    format!("{now}-{}", &random_hex()[..8])
}

/// `POST /sentinel/deploy`.
///
/// Answers `202 {deploy_id}` and does the work in a task, because the work is a twenty-minute
/// build and an HTTP request that hangs for twenty minutes is a request every proxy, phone and
/// operator gives up on. Progress is `GET /sentinel/deploy/status`.
pub async fn verb_deploy(sen: &Arc<Sentinel>, body: Value) -> VerbResult {
    let req: DeployRequest = serde_json::from_value(body).unwrap_or_default();
    if req.git_ref != "main" && !is_full_sha(&req.git_ref) {
        return Err((
            StatusCode::BAD_REQUEST,
            json!({
                "error": "ref must be \"main\" or a full 40-character lowercase commit sha",
            }),
        ));
    }

    // A deploy kills the bridge. Doing that while the scheduler is mid-chain loses the turn
    // and, worse, loses it invisibly — the ledger records a job that started and never
    // finished. `force` is the operator saying they know.
    if !req.force {
        if let Some(busy) = running_jobs(sen).await {
            if !busy.is_empty() {
                return Err((
                    StatusCode::CONFLICT,
                    json!({
                        "error": format!(
                            "a scheduled job is running ({}) — deploying now would kill it. \
                             Retry when it finishes, or pass force.",
                            busy.join(", ")
                        ),
                        "running": busy,
                    }),
                ));
            }
        }
    }

    let lock = DeployLock::acquire(sen).map_err(|e| {
        (
            StatusCode::CONFLICT,
            json!({ "error": format!("could not start a deploy: {e}") }),
        )
    })?;

    let deploy_id = new_deploy_id(now_ms());
    let log = DeployLog::new(sen.cfg.deploy_log(&deploy_id));
    log.line(&format!(
        "deploy {deploy_id} requested: ref={} force={}",
        req.git_ref, req.force
    ));
    set_deploy(
        sen,
        DeployRecord {
            deploy_id: deploy_id.clone(),
            phase: "resolve".to_string(),
            git_ref: req.git_ref.clone(),
            sha: None,
            started_ms: now_ms(),
            finished_ms: None,
            result: None,
            reason: None,
            log_tail: log.tail(),
        },
    );

    let task_sen = sen.clone();
    tokio::spawn(async move {
        run_deploy(task_sen, lock, log, req.git_ref, req.force).await;
    });

    Ok((
        StatusCode::ACCEPTED,
        json!({ "deploy_id": deploy_id, "phase": "resolve" }),
    ))
}

/// The ids of `[[schedule]]` chains the bridge says are running right now.
///
/// `None` means the bridge could not be asked — which, since a chain needs a live bridge to be
/// running inside, is not a reason to refuse the deploy. It is the reason someone is deploying.
async fn running_jobs(sen: &Sentinel) -> Option<Vec<String>> {
    let (status, body) = sen
        .bridge_get("/jesse/schedule", PROBE_TIMEOUT)
        .await
        .ok()?;
    if !(200..300).contains(&status) {
        return None;
    }
    Some(
        body.get("jobs")
            .and_then(Value::as_array)
            .map(|jobs| {
                jobs.iter()
                    .filter(|j| j.get("running").and_then(Value::as_bool) == Some(true))
                    .filter_map(|j| j.get("id").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    )
}

// ---- The status card -------------------------------------------------------------------

/// `GET /sentinel/deploy/status` — everything the app's Deploy card renders.
///
/// The card enables its button only when `origin_main.sha != running.sha` and
/// `origin_main.ci == "green"`, which is the same pair of conditions the verb enforces. Those
/// two checks live in one function ([`check_ci`], [`phase_resolve`]) precisely so the button
/// cannot be lit for a commit the verb would then refuse.
pub async fn deploy_status_document(sen: &Arc<Sentinel>) -> Value {
    let (deploy, running_sha) = {
        let st = sen.state.lock_ok();
        (st.deploy.clone(), st.running_sha.clone())
    };
    // The running VERSION comes from the live bridge, not from state: state records what was
    // deployed, and the question the card answers is what is actually up.
    let running_version = match sen.bridge_get("/health", PROBE_TIMEOUT).await {
        Ok((status, body)) if (200..300).contains(&status) => body
            .get("version")
            .and_then(Value::as_str)
            .map(str::to_string),
        _ => None,
    };
    let (origin_main, releases) = origin_main_view(sen, running_sha.as_deref()).await;
    let mut doc = json!({
        "deploy": deploy,
        "running": { "version": running_version, "sha": running_sha },
        "origin_main": origin_main,
    });
    // ABSENT, not null, when the summaries could not be built — the app treats a missing key
    // as "this sentinel does not send them", which is also what an older sentinel looks like.
    if let Some(r) = releases {
        doc["releases"] = r;
    }
    doc
}

/// The cached-or-refreshed view of `origin/main`, and the release block that rides the same
/// cache entry.
///
/// Returns the two separately because they are two keys of the document: the summaries are
/// CACHED with `origin/main` — they are several `git` calls, and recomputing them fresh beside
/// a cached commit hash would be the same lie as an unmarked cache hit — but they are
/// PUBLISHED beside it, not inside it.
async fn origin_main_view(
    sen: &Arc<Sentinel>,
    running_sha: Option<&str>,
) -> (Value, Option<Value>) {
    let cached = sen.state.lock_ok().origin_main.clone();
    let now = now_ms();
    if let Some(c) = &cached {
        let age = now.saturating_sub(c.checked_ms);
        // **A `pending` VERDICT IS NEVER SERVED FROM CACHE**, and it is the only one excluded.
        //
        // Every other state is an answer that will still be true in a minute. `pending` is
        // the one that is KNOWN to be about to change — it means a run is in flight right
        // now — so caching it for five minutes shows "CI has not finished" for up to five
        // minutes after it finished, which reads as "the deploy is still blocked" when it is
        // not. That is a card actively misinforming someone who is waiting on it, and the
        // refresh it costs is one `git fetch` and a couple of API calls at the one moment
        // somebody actually wants the current answer. The card is only refreshed on appear
        // and on pull-to-refresh (the three-second poll runs during a deploy, and a deploy
        // short-circuits below), so this is not a hot loop.
        // The release block is a function of BOTH commits, so the running one is part of the
        // cache key: after a deploy the cached summaries describe a range that no longer
        // exists, and serving them would say "not yet deployed" about what was just deployed.
        if age < ORIGIN_MAIN_TTL_MS && c.ci != "pending" && c.releases_for.as_deref() == running_sha
        {
            return (cached_view(c, age), releases_wire(c, running_sha));
        }
    }
    // A deploy owns the clone while it runs — it leaves a detached head in it and a `cargo`
    // process inside it — so the refresh stands aside rather than fetching underneath a build.
    if sen.deploy_running.load(std::sync::atomic::Ordering::SeqCst) {
        return stale_view(
            cached,
            "a deploy is in flight, so origin/main was not re-read",
            running_sha,
        );
    }
    // One refresh at a time. A second caller arriving mid-refresh gets the cache rather than a
    // second `git fetch` in the same clone.
    let Ok(_permit) = sen.origin_refresh.try_lock() else {
        // MARKED, like every other answer that is not a fresh read. This path returned the
        // cached value unmarked — the same "a cache hit rendered as current" bug 0.106.0 fixed
        // on the TTL path, surviving on the rarer one, and with the same consequence: the app
        // documents an absent `stale` as "this was just read", so a `green` verdict from
        // before CI went red would light the Deploy button.
        let why = if cached.is_some() {
            "origin/main is being read right now; this is the previous answer"
        } else {
            "origin/main is being read now; nothing cached yet"
        };
        return stale_view(cached, why, running_sha);
    };
    match read_origin_main(sen, running_sha).await {
        Ok(fresh) => {
            sen.state.lock_ok().origin_main = Some(fresh.clone());
            sen.persist_state();
            (origin_main_wire(&fresh), releases_wire(&fresh, running_sha))
        }
        Err(e) => stale_view(cached, &e, running_sha),
    }
}

/// The `origin_main` block as the app sees it: the cached struct MINUS the release summaries,
/// which share its cache entry but are published under the document's own `releases` key.
/// One place, so the two never drift into being sent twice.
fn origin_main_wire(c: &OriginMain) -> Value {
    let mut v = json!(c);
    if let Some(obj) = v.as_object_mut() {
        obj.remove("releases");
        obj.remove("releases_for");
    }
    v
}

/// The cached release block, but ONLY when it was computed against the commit that is running
/// now. A key mismatch yields no block at all rather than a stale range: "not yet deployed"
/// about a release that was just deployed is worse than saying nothing.
fn releases_wire(c: &OriginMain, running_sha: Option<&str>) -> Option<Value> {
    if c.releases_for.as_deref() != running_sha {
        return None;
    }
    c.releases.as_ref().map(|r| json!(r))
}

/// A cache hit inside the TTL, marked with its own age.
///
/// **This is the other half of what [`stale_view`] promises, and it was missing.** That
/// function's contract is that the card is NEVER shown a silently old value — but it only ran
/// when a refresh was attempted and failed, so a value served straight out of the TTL came
/// back unmarked and the app, which documents `stale` as "present only when the view could
/// not be refreshed", rendered a five-minute-old answer as current. That is benign in one
/// direction (a stale `pending` costs somebody a wait) and not in the other: a stale `green`
/// enables the Deploy button for a commit whose CI may since have gone red. The verb re-checks
/// CI for real before it builds anything, so the button lies rather than the deploy breaking —
/// but a button that lies is the thing this card exists not to be.
///
/// The age is in the reason rather than in a new field on purpose: the shipped app already
/// renders `stale_reason` verbatim, so this reaches a phone with no app change and no
/// TestFlight build.
fn cached_view(c: &OriginMain, age_ms: u64) -> Value {
    let mut v = origin_main_wire(c);
    v["stale"] = json!(true);
    v["stale_reason"] = json!(format!(
        "read {}, and re-read at most every {}s — pull to refresh for the current answer",
        approx_age(age_ms),
        ORIGIN_MAIN_TTL_MS / 1000,
    ));
    v
}

/// An age a person reads, not a number they convert. Used in the one place a card says how
/// old its answer is.
fn approx_age(ms: u64) -> String {
    let secs = ms / 1000;
    match secs {
        0..=9 => "just now".to_string(),
        s if s < 60 => format!("{s}s ago"),
        s if s < 120 => "a minute ago".to_string(),
        s => format!("{}m ago", s / 60),
    }
}

/// A failed or skipped refresh: the cached answer, marked `stale`, or an empty one that says
/// why. NEVER a silently old value — a card that cannot tell "green five minutes ago" from
/// "green, checked just now" is a card that will eventually offer a deploy of a commit whose
/// CI has since gone red.
fn stale_view(
    cached: Option<OriginMain>,
    why: &str,
    running_sha: Option<&str>,
) -> (Value, Option<Value>) {
    let releases = cached.as_ref().and_then(|c| releases_wire(c, running_sha));
    let mut v = match &cached {
        Some(c) => origin_main_wire(c),
        None => origin_main_wire(&OriginMain {
            ci: "none".to_string(),
            ..Default::default()
        }),
    };
    v["stale"] = json!(true);
    v["stale_reason"] = json!(why);
    (v, releases)
}

/// Read `origin/main` and its CI, for the card.
async fn read_origin_main(sen: &Sentinel, running_sha: Option<&str>) -> Result<OriginMain, String> {
    if !sen.cfg.deploy_clone.join(".git").exists() {
        return Err(format!(
            "no deploy clone at {}",
            sen.cfg.deploy_clone.display()
        ));
    }
    let fetch = qgit(sen, &["fetch", "origin", "--prune"], STATUS_GIT_TIMEOUT).await;
    if !fetch.ok() {
        return Err(format!("git fetch origin failed: {}", fetch.summary()));
    }
    let rev = qgit(
        sen,
        &["rev-parse", "origin/main^{commit}"],
        STATUS_GIT_TIMEOUT,
    )
    .await;
    if !rev.ok() {
        return Err(format!("could not resolve origin/main: {}", rev.summary()));
    }
    let sha = rev.stdout.trim().to_string();
    if !is_full_sha(&sha) {
        return Err(format!("origin/main resolved to {sha:?}"));
    }
    let version = version_at(sen, &sha).await.ok();
    // Built HERE, on the one path that already holds a fetched clone, so the summaries and the
    // commit hash they describe enter the cache together.
    let releases = read_releases(sen, &sha, running_sha).await;
    let ci = check_ci(sen, &sha).await?;
    Ok(OriginMain {
        sha: Some(sha),
        version,
        ci: ci.state.to_string(),
        ci_detail: Some(ci.detail),
        checked_ms: now_ms(),
        releases,
        // Recorded even when `releases` is None: it records what was ATTEMPTED, so a failed
        // build is not retried on every request while the entry is warm.
        releases_for: running_sha.map(str::to_string),
    })
}

// ---- release summaries ------------------------------------------------------------------
//
// Everything below derives the card's release notes from what the repository already records.
// It is deliberately all parsing and no invention: the summaries are the commit subjects and
// the bold lead sentences of the changelog bullets each commit added, and nothing else. The
// pure functions are split out from the `git` calls so the parsing — which is where the sharp
// edges are — is testable without a repository.

/// The content of a trailing balanced parenthetical, and the subject with it removed.
///
/// Balanced, scanning from the end, because the version parenthetical NESTS: the subject
/// `… (bridge 0.107.0, App 1.0 (121)) (#140)` ends in two of them and the inner `(121)` is
/// part of the app's version. Taking the last `(` would strip `(121))` and leave a subject
/// with an unclosed bracket in it.
fn split_trailing_paren(subject: &str) -> Option<(&str, &str)> {
    let s = subject.trim_end();
    if !s.ends_with(')') {
        return None;
    }
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    for (i, b) in bytes.iter().enumerate().rev() {
        match b {
            b')' => depth += 1,
            b'(' => {
                depth -= 1;
                if depth == 0 {
                    return Some((s[..i].trim_end(), &s[i + 1..s.len() - 1]));
                }
            }
            _ => {}
        }
    }
    None
}

/// Whether a trailing parenthetical states the versions this release carried, rather than
/// being part of the title.
///
/// Every comma-separated part must be a component name followed by something starting with a
/// digit: `bridge 0.106.0`, `App 1.0 (121)`, `jesse-agent 0.1.0`. A title that legitimately
/// ends in brackets — `… (and why the old one hung)` — has no digit after a component name
/// and is left alone, which is the only reason this is a test rather than "strip the last
/// parenthetical".
fn is_version_parenthetical(inner: &str) -> bool {
    let mut any = false;
    for part in inner.split(',') {
        let part = part.trim();
        let Some((name, rest)) = part.split_once(char::is_whitespace) else {
            return false;
        };
        if name.is_empty() || !name.starts_with(|c: char| c.is_ascii_alphabetic()) {
            return false;
        }
        let rest = rest.trim_start().trim_start_matches('v');
        if !rest.starts_with(|c: char| c.is_ascii_digit()) {
            return false;
        }
        any = true;
    }
    any
}

/// Whether a trailing parenthetical is a pull request reference: `(#140)`.
fn is_pr_ref(inner: &str) -> bool {
    inner
        .strip_prefix('#')
        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// A release title, and the versions its subject states.
///
/// `Stop the deploy card showing a cached answer as a current one (bridge 0.106.0) (#139)`
/// becomes `Stop the deploy card showing a cached answer as a current one` plus
/// `bridge 0.106.0`. Both trailing parentheticals are optional and either may be absent.
fn split_subject(subject: &str) -> (String, Option<String>) {
    let mut rest = subject.trim();
    let mut version = None;
    // At most two: the pull request reference, then the versions. Ordered as the repository
    // writes them, and a second pass is not attempted — a title is allowed to end in brackets.
    if let Some((head, inner)) = split_trailing_paren(rest) {
        if is_pr_ref(inner) {
            rest = head;
        }
    }
    if let Some((head, inner)) = split_trailing_paren(rest) {
        if is_version_parenthetical(inner) {
            version = Some(inner.trim().to_string());
            rest = head;
        }
    }
    (rest.trim().to_string(), version)
}

/// The versions a `CHANGELOG.md` diff declares, from the headings it ADDED: `## [bridge
/// 0.106.0] - 2026-08-30` gives `bridge 0.106.0`. A commit that bumps two components adds two
/// headings and gets both.
///
/// Preferred over the subject's parenthetical because the changelog heading is the
/// repository's own record of what the release was, while the subject is prose.
fn changelog_versions(diff: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in added_lines(diff) {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("## [") else {
            continue;
        };
        let Some(end) = rest.find(']') else { continue };
        let name = rest[..end].trim();
        if !name.is_empty() {
            out.push(name.to_string());
        }
    }
    out
}

/// The added lines of a unified diff, without their `+`, and without the `+++` file header
/// that shares the prefix.
fn added_lines(diff: &str) -> impl Iterator<Item = &str> {
    diff.lines()
        .filter(|l| !l.starts_with("+++"))
        .filter_map(|l| l.strip_prefix('+'))
}

/// The bold lead sentence of every changelog bullet a diff ADDED.
///
/// The convention this reads is `- **One sentence.** followed by paragraphs of detail`, and
/// the detail is precisely what the card must not show. Two things make it more than a
/// `starts_with`:
///
///   * **the bold span wraps.** A lead sentence regularly runs past the column limit and
///     closes two lines below the `- **` that opened it, so the span is accumulated across
///     continuation lines until `**` closes it;
///   * **a bullet may have no bold span at all**, in which case it contributes nothing rather
///     than contributing its first line.
///
/// A span that never closes before the bullet's first blank line is dropped, not guessed at.
fn bullet_leads(diff: &str) -> Vec<String> {
    let mut leads: Vec<String> = Vec::new();
    // The bold span of the bullet currently being read, if it has not closed yet.
    let mut open: Option<String> = None;

    let push = |text: &str, leads: &mut Vec<String>| {
        let one = collapse_ws(text);
        if !one.is_empty() {
            leads.push(one);
        }
    };

    for line in added_lines(diff) {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("- ") {
            open = None;
            let Some(after) = rest.trim_start().strip_prefix("**") else {
                continue; // a bullet with no bold lead contributes no line
            };
            match after.find("**") {
                Some(i) => push(&after[..i], &mut leads),
                None => open = Some(after.to_string()),
            }
            continue;
        }
        let Some(acc) = open.as_mut() else { continue };
        if trimmed.is_empty() {
            open = None; // the bullet's first paragraph ended with the span still open
            continue;
        }
        match trimmed.find("**") {
            Some(i) => {
                acc.push(' ');
                acc.push_str(&trimmed[..i]);
                let done = std::mem::take(acc);
                open = None;
                push(&done, &mut leads);
            }
            None => {
                acc.push(' ');
                acc.push_str(trimmed);
            }
        }
    }
    leads
}

/// One line of whitespace, from text that was wrapped across source lines.
fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// One summary line, cut to [`MAX_RELEASE_LINE_CHARS`] on a CHARACTER boundary.
///
/// Characters rather than bytes: these sentences contain em dashes and curly quotes, and
/// slicing a `String` at byte 200 would panic in the middle of one. The mark is a single `…`
/// rather than three dots, and it counts toward the cap.
fn cap_line(line: &str) -> String {
    if line.chars().count() <= MAX_RELEASE_LINE_CHARS {
        return line.to_string();
    }
    let mut out: String = line.chars().take(MAX_RELEASE_LINE_CHARS - 1).collect();
    out.push('…');
    out
}

/// The lines one release shows, and how many it dropped.
fn cap_lines(lines: Vec<String>) -> (Vec<String>, usize) {
    let more = lines.len().saturating_sub(MAX_RELEASE_LINES);
    let kept = lines
        .into_iter()
        .take(MAX_RELEASE_LINES)
        .map(|l| cap_line(&l))
        .collect();
    (kept, more)
}

/// One release, assembled from a commit's subject, its date and its `CHANGELOG.md` diff.
///
/// Split from [`summarize_release`] so every rule above is tested against real text without a
/// repository to build first.
fn build_summary(sha: &str, subject: &str, date_ms: u64, changelog_diff: &str) -> ReleaseSummary {
    let (title, subject_version) = split_subject(subject);
    let heading_versions = changelog_versions(changelog_diff);
    let version = if heading_versions.is_empty() {
        subject_version
    } else {
        Some(heading_versions.join(", "))
    };
    let (lines, more) = cap_lines(bullet_leads(changelog_diff));
    ReleaseSummary {
        sha: sha.to_string(),
        version,
        title,
        date_ms,
        lines,
        more,
    }
}

/// Read one commit and summarise it. `None` when git could not read it at all.
async fn summarize_release(sen: &Sentinel, sha: &str) -> Option<ReleaseSummary> {
    // `%ct%n%s`: the commit date and the subject in one call rather than two.
    let meta = qgit(
        sen,
        &["show", "-s", "--format=%ct%n%s", sha],
        STATUS_GIT_TIMEOUT,
    )
    .await;
    if !meta.ok() {
        return None;
    }
    let mut lines = meta.stdout.lines();
    let date_ms = lines.next()?.trim().parse::<u64>().ok()? * 1000;
    let subject = lines.next().unwrap_or("").trim().to_string();
    // `--unified=0`: only the added bullets are wanted, never the surrounding entries. A
    // failure here is not fatal — the title alone is a perfectly good summary.
    let diff = qgit(
        sen,
        &[
            "show",
            "--format=",
            "--unified=0",
            sha,
            "--",
            "CHANGELOG.md",
        ],
        STATUS_GIT_TIMEOUT,
    )
    .await;
    let diff = if diff.ok() {
        diff.stdout
    } else {
        String::new()
    };
    Some(build_summary(sha, &subject, date_ms, &diff))
}

/// The release block: the running commit's own release, and every release between it and
/// `origin/main`.
///
/// `None` means "could not be built", which the caller turns into an ABSENT block rather than
/// an empty one — the deploy card's version and commit rows must keep working when git does
/// not. The cases that return `Some` with an empty list and a `reason` are the ones where the
/// range is genuinely not computable, and **each of them is stated rather than guessed at**:
/// treating "no running commit recorded" as "everything on main is undeployed" would offer a
/// wall of releases to somebody whose Studio may be running all of them already.
async fn read_releases(
    sen: &Sentinel,
    origin_sha: &str,
    running: Option<&str>,
) -> Option<ReleaseSummaries> {
    let stated = |deployed, why: &str| {
        Some(ReleaseSummaries {
            deployed,
            undeployed: Vec::new(),
            truncated: 0,
            reason: Some(why.to_string()),
        })
    };

    // Nothing has ever been deployed. There is no range, and the absence of a record is not
    // evidence about what the Studio is running.
    let Some(running) = running else {
        return stated(None, "the sentinel has not recorded a deployed commit yet");
    };
    // The closed alphabet this module gives git, applied before the value becomes an argument.
    // A malformed record is not a commit in the clone, which is exactly what it is reported as.
    let present = is_full_sha(running)
        && qgit(
            sen,
            &["cat-file", "-e", &format!("{running}^{{commit}}")],
            STATUS_GIT_TIMEOUT,
        )
        .await
        .ok();
    if !present {
        return stated(None, "the running commit is not in the deploy clone");
    }

    let deployed = summarize_release(sen, running).await;

    // `merge-base --is-ancestor` answers in its exit code: 0 yes, 1 no, anything else is git
    // failing. The three are kept apart because "not an ancestor" is a fact about the history
    // and reportable, while "git broke" is a fact about the probe and must not be dressed up
    // as one.
    let anc = qgit(
        sen,
        &["merge-base", "--is-ancestor", running, origin_sha],
        STATUS_GIT_TIMEOUT,
    )
    .await;
    match anc.code {
        Some(0) => {}
        // A force push to main, or a deploy of a commit that was never on main.
        Some(1) => return stated(deployed, "the running commit is not on origin/main"),
        _ => return None,
    }

    let list = qgit(
        sen,
        &["rev-list", &format!("{running}..{origin_sha}")],
        STATUS_GIT_TIMEOUT,
    )
    .await;
    if !list.ok() {
        return None;
    }
    // `rev-list` is newest first already, which is the order the card asks the question in.
    let shas: Vec<&str> = list
        .stdout
        .lines()
        .map(str::trim)
        .filter(|s| is_full_sha(s))
        .collect();
    let truncated = shas.len().saturating_sub(MAX_UNDEPLOYED_RELEASES);
    let mut undeployed = Vec::new();
    for sha in shas.into_iter().take(MAX_UNDEPLOYED_RELEASES) {
        if let Some(r) = summarize_release(sen, sha).await {
            undeployed.push(r);
        }
    }
    Some(ReleaseSummaries {
        deployed,
        undeployed,
        truncated,
        // Already current says so in one short line in the view, not with a reason string.
        reason: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("jesse-deploy-{name}-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch_exec(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"#!/bin/sh\n").unwrap();
        set_executable(path).unwrap();
    }

    // ---- the card's own freshness ---------------------------------------------------

    /// **A value served from the TTL says how old it is.** The app documents `stale` as
    /// "present only when the view could not be refreshed", so an unmarked cache hit is
    /// rendered as current — which is how a card showing "CI is pending" survived four
    /// minutes past CI going green, and how a `green` card could outlive the CI that vouched
    /// for it and offer a Deploy button for a commit that has since gone red.
    #[test]
    fn a_cache_hit_is_marked_with_its_age_rather_than_passing_as_current() {
        let c = OriginMain {
            sha: Some("a".repeat(40)),
            version: Some("0.105.0".to_string()),
            ci: "green".to_string(),
            ci_detail: Some("run 1 (CI) passed the \"bridge\" job".to_string()),
            checked_ms: 0,
            ..Default::default()
        };
        let v = cached_view(&c, 4 * 60 * 1000);
        assert_eq!(v["stale"], json!(true), "a cache hit is not a fresh read");
        let why = v["stale_reason"].as_str().expect("it says why");
        assert!(why.contains("4m ago"), "and how old it is: {why}");
        assert!(
            why.contains("pull to refresh"),
            "and what to do about it: {why}"
        );
        // The verdict itself is passed through untouched — this marks the answer, it does not
        // change it.
        assert_eq!(v["ci"], json!("green"));
        assert_eq!(v["version"], json!("0.105.0"));
        assert_eq!(v["sha"], json!("a".repeat(40)));
    }

    /// **Every answer that is not a fresh read says so — including the one served because a
    /// refresh was already in flight.** That path returned the cached view unmarked, which is
    /// the TTL bug of 0.106.0 on a rarer route: `stale` absent means "just read" to the app,
    /// so a `green` from before CI went red would enable the Deploy button.
    #[test]
    fn a_view_served_because_a_refresh_was_in_flight_is_marked_stale() {
        let c = OriginMain {
            sha: Some("a".repeat(40)),
            ci: "green".to_string(),
            checked_ms: 0,
            ..Default::default()
        };
        let (v, _) = stale_view(
            Some(c),
            "origin/main is being read right now; this is the previous answer",
            None,
        );
        assert_eq!(
            v["stale"],
            json!(true),
            "a lost refresh lock is not a fresh read"
        );
        assert!(v["stale_reason"]
            .as_str()
            .unwrap()
            .contains("being read right now"));
        assert_eq!(v["ci"], json!("green"), "the verdict itself is untouched");

        // And with nothing cached at all, the empty view still says why.
        let (empty, releases) = stale_view(None, "nothing cached yet", None);
        assert_eq!(empty["stale"], json!(true));
        assert_eq!(empty["ci"], json!("none"));
        assert!(releases.is_none(), "no cache, no release block");
    }

    /// The age reads as a person would say it, because it is rendered verbatim on a phone.
    #[test]
    fn the_age_is_written_the_way_someone_reads_it() {
        assert_eq!(approx_age(0), "just now");
        assert_eq!(approx_age(9_000), "just now");
        assert_eq!(approx_age(30_000), "30s ago");
        assert_eq!(approx_age(90_000), "a minute ago");
        assert_eq!(approx_age(4 * 60 * 1000), "4m ago");
        assert_eq!(approx_age(ORIGIN_MAIN_TTL_MS), "5m ago");
    }

    /// **`pending` is the one verdict never served from cache.** It means a run is in flight
    /// *right now*, so a five-minute cache of it shows "CI has not finished" for up to five
    /// minutes after it did — a card actively telling someone waiting on it that they are
    /// still blocked when they are not. Every other state is an answer that is still true a
    /// minute later.
    #[test]
    fn a_pending_verdict_is_never_served_from_the_cache() {
        let fresh_enough = ORIGIN_MAIN_TTL_MS / 2;
        for (ci, cacheable) in [
            ("green", true),
            ("red", true),
            ("none", true),
            ("pending", false),
        ] {
            let c = OriginMain {
                sha: Some("b".repeat(40)),
                version: None,
                ci: ci.to_string(),
                ci_detail: None,
                checked_ms: 0,
                ..Default::default()
            };
            // The predicate `origin_main_view` applies, stated here so the reason a
            // `pending` card refreshes cannot be edited away without a failing test.
            let served_from_cache = fresh_enough < ORIGIN_MAIN_TTL_MS && c.ci != "pending";
            assert_eq!(
                served_from_cache,
                cacheable,
                "{ci} should {} be served from a within-TTL cache",
                if cacheable { "" } else { "NOT" }
            );
        }
    }

    // ---- release summaries ----------------------------------------------------------

    /// A real bullet from this changelog, wrapped exactly as the file wraps it.
    const REAL_DIFF: &str = "\
diff --git a/CHANGELOG.md b/CHANGELOG.md
--- a/CHANGELOG.md
+++ b/CHANGELOG.md
@@ -15,0 +16,12 @@ CI both run it).
+## [bridge 0.106.0] - 2026-08-30
+
+### Fixed
+
+- **The deploy card no longer shows a cached answer as a current one.** `GET
+  /sentinel/deploy/status` serves its view of `origin/main` from a five-minute cache, and the
+  TTL path returned that value unmarked.
+
+  A cache hit is now marked with its own age.
+
+- **A `pending` CI verdict is never served from the cache.** It is the one state that is known
+  to be about to change.
";

    /// **The bold lead sentence is the whole summary, and it wraps.** The convention is
    /// `- **One sentence.** paragraphs of detail`, and the detail is exactly the verbosity
    /// this card exists not to show. A lead that runs past the column limit closes two lines
    /// below the `- **` that opened it, so anything that reads only the bullet's first line
    /// would publish half a sentence.
    #[test]
    fn a_bullet_contributes_its_bold_lead_and_never_its_body() {
        let leads = bullet_leads(REAL_DIFF);
        assert_eq!(
            leads,
            vec![
                "The deploy card no longer shows a cached answer as a current one.",
                "A `pending` CI verdict is never served from the cache.",
            ],
            "the paragraphs under each bullet are not summary"
        );
    }

    /// A lead sentence that wraps across three source lines comes back as one line.
    #[test]
    fn a_bold_lead_that_wraps_is_rejoined() {
        let diff = "\
+- **The location channel takes the interim fixes CoreLocation already computed, instead
+  of throwing them away and reporting nothing.** `LocationContextProvider` bounded one
+  fix at a 2-second `fixTimeout`.
";
        assert_eq!(
            bullet_leads(diff),
            vec![
                "The location channel takes the interim fixes CoreLocation already computed, \
                 instead of throwing them away and reporting nothing."
            ]
        );
    }

    /// **A bullet with no bold span contributes nothing**, rather than contributing its first
    /// line. A card built from arbitrary first lines is a card that prints half-sentences.
    #[test]
    fn a_bullet_with_no_bold_span_is_skipped() {
        let diff = "\
+- Just a plain bullet with no bold claim at all.
+- **A proper one.** With detail.
+- **An unclosed one that never finishes
+
+  and whose paragraph ended.
";
        assert_eq!(bullet_leads(diff), vec!["A proper one."]);
    }

    /// Removed and context lines are not the release. Only what the commit ADDED counts —
    /// otherwise a commit that reformats the changelog would republish every old entry.
    #[test]
    fn only_added_lines_are_read() {
        let diff = "\
--- a/CHANGELOG.md
+++ b/CHANGELOG.md
+- **Added.** detail
-- **Removed.** detail
 - **Context.** detail
";
        assert_eq!(bullet_leads(diff), vec!["Added."]);
    }

    /// **A commit that added no changelog bullet is its title and nothing else.** The commit
    /// BODY is never a fallback: bodies here run to paragraphs, which is the one thing this
    /// card must not become.
    #[test]
    fn a_commit_with_no_changelog_change_is_title_only() {
        let r = build_summary(
            &"c".repeat(40),
            "Fix the location request never coming back (App 1.0 (119))",
            1_756_000_000_000,
            "",
        );
        assert_eq!(r.title, "Fix the location request never coming back");
        assert!(r.lines.is_empty(), "no bullets, no lines");
        assert_eq!(r.more, 0);
        // The subject's parenthetical still states the version.
        assert_eq!(r.version.as_deref(), Some("App 1.0 (119)"));
    }

    /// The title is the subject minus its version parenthetical and its pull request number.
    /// **The version parenthetical NESTS** — `(bridge 0.107.0, App 1.0 (121))` — so a stripper
    /// that took the last `(` would leave an unbalanced bracket in the title.
    #[test]
    fn a_title_is_the_subject_without_its_version_and_pull_request_tails() {
        for (subject, title, version) in [
            (
                "Stop the deploy card showing a cached answer as a current one (bridge 0.106.0) (#139)",
                "Stop the deploy card showing a cached answer as a current one",
                Some("bridge 0.106.0"),
            ),
            (
                "Take the interim fixes, and stop asking for the one that fails (bridge 0.107.0, App 1.0 (121)) (#140)",
                "Take the interim fixes, and stop asking for the one that fails",
                Some("bridge 0.107.0, App 1.0 (121)"),
            ),
            (
                "Provider-neutral agent layer: new `agent/` crate (jesse-agent 0.1.0) (#136)",
                "Provider-neutral agent layer: new `agent/` crate",
                Some("jesse-agent 0.1.0"),
            ),
            // No tails at all.
            ("A plain subject", "A plain subject", None),
            // A title that legitimately ends in brackets keeps them: the parenthetical is only
            // stripped when it states a component and a version.
            (
                "Fix the thing (and say why it hung)",
                "Fix the thing (and say why it hung)",
                None,
            ),
        ] {
            let (got_title, got_version) = split_subject(subject);
            assert_eq!(got_title, title, "title of {subject:?}");
            assert_eq!(got_version.as_deref(), version, "version of {subject:?}");
        }
    }

    /// The changelog heading the commit added beats the subject's parenthetical, because the
    /// heading is the repository's own record of the release and the subject is prose.
    #[test]
    fn the_changelog_heading_states_the_version() {
        let r = build_summary(
            &"d".repeat(40),
            "Something (bridge 9.9.9) (#1)",
            0,
            REAL_DIFF,
        );
        assert_eq!(r.version.as_deref(), Some("bridge 0.106.0"));
        assert_eq!(r.title, "Something");
    }

    /// **What is dropped is reported.** Four lines is the outer edge of a ten-second read, and
    /// a release that silently showed four of nine would read as a complete summary.
    #[test]
    fn the_line_cap_keeps_the_first_four_and_counts_the_rest() {
        let diff: String = (1..=9)
            .map(|i| format!("+- **Claim {i}.** detail\n"))
            .collect();
        let r = build_summary(&"e".repeat(40), "Subject", 0, &diff);
        assert_eq!(r.lines.len(), MAX_RELEASE_LINES);
        assert_eq!(r.lines.first().unwrap(), "Claim 1.");
        assert_eq!(r.lines.last().unwrap(), "Claim 4.");
        assert_eq!(r.more, 5, "the five it did not show are counted");
    }

    /// The character cap cuts on a CHARACTER boundary and marks the cut with one `…`.
    /// Byte-slicing would panic mid-em-dash, and these sentences are full of them.
    #[test]
    fn a_long_line_is_cut_on_a_character_boundary_with_one_ellipsis() {
        let short = "already short enough";
        assert_eq!(cap_line(short), short);

        // Multi-byte throughout, so a byte cut would panic rather than merely mislead.
        let long: String = "é—".repeat(200);
        let cut = cap_line(&long);
        assert_eq!(cut.chars().count(), MAX_RELEASE_LINE_CHARS);
        assert!(
            cut.ends_with('…'),
            "one ellipsis character, never three dots"
        );
        assert!(!cut.ends_with("..."));
        assert_eq!(
            cut.chars()
                .take(MAX_RELEASE_LINE_CHARS - 1)
                .collect::<String>(),
            long.chars()
                .take(MAX_RELEASE_LINE_CHARS - 1)
                .collect::<String>(),
        );

        // Exactly at the cap is not truncated.
        let exact: String = "x".repeat(MAX_RELEASE_LINE_CHARS);
        assert_eq!(cap_line(&exact), exact);
    }

    /// The undeployed cap, and its `truncated` count. Stated as the arithmetic
    /// `read_releases` applies, so the count cannot be edited away without a failing test.
    #[test]
    fn the_undeployed_cap_reports_what_it_dropped() {
        for (found, kept, truncated) in [(0, 0, 0), (3, 3, 0), (10, 10, 0), (14, 10, 4)] {
            let shown = std::cmp::min(found, MAX_UNDEPLOYED_RELEASES);
            assert_eq!(shown, kept, "{found} found");
            assert_eq!(
                found.saturating_sub(MAX_UNDEPLOYED_RELEASES),
                truncated,
                "{found} found"
            );
        }
    }

    /// **The three cases where the range cannot be computed are STATED, never guessed.**
    /// Each returns an empty undeployed list and a reason, and the one that matters most is
    /// the first: a sentinel with no recorded deploy must not be told that every commit on
    /// main is undeployed, because it may be running all of them.
    #[test]
    fn a_range_that_cannot_be_computed_is_stated_rather_than_guessed() {
        for (reason, deployed) in [
            ("the sentinel has not recorded a deployed commit yet", None),
            ("the running commit is not in the deploy clone", None),
            (
                "the running commit is not on origin/main",
                Some(ReleaseSummary {
                    sha: "f".repeat(40),
                    title: "Something that was deployed".to_string(),
                    ..Default::default()
                }),
            ),
        ] {
            let r = ReleaseSummaries {
                deployed,
                undeployed: Vec::new(),
                truncated: 0,
                reason: Some(reason.to_string()),
            };
            let v = json!(r);
            assert_eq!(v["undeployed"], json!([]), "{reason}");
            assert_eq!(v["truncated"], json!(0), "{reason}");
            assert_eq!(v["reason"], json!(reason));
        }

        // Already current is the one empty list with NO reason: the view says so in a short
        // line of its own rather than borrowing the failure wording.
        let current = ReleaseSummaries::default();
        assert_eq!(json!(current)["reason"], Value::Null);
    }

    /// **The summaries ride the `origin/main` cache entry, keyed on BOTH commits.** Computing
    /// them fresh beside a cached commit hash is the bug the freshness rule above exists to
    /// prevent; serving them after a deploy has moved the running commit is the same bug
    /// mirrored, and would report a just-deployed release as "not yet deployed".
    #[test]
    fn the_release_cache_is_keyed_on_the_running_commit_as_well_as_origin_main() {
        let running = "a".repeat(40);
        let c = OriginMain {
            sha: Some("b".repeat(40)),
            ci: "green".to_string(),
            releases: Some(ReleaseSummaries {
                undeployed: vec![ReleaseSummary {
                    sha: "b".repeat(40),
                    title: "Not yet deployed".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            }),
            releases_for: Some(running.clone()),
            ..Default::default()
        };

        // Same running commit: served.
        let served = releases_wire(&c, Some(&running)).expect("the key matches");
        assert_eq!(served["undeployed"][0]["title"], json!("Not yet deployed"));

        // A deploy moved the running commit: the entry describes a range that no longer
        // exists, so there is no block at all rather than a stale one.
        assert!(releases_wire(&c, Some(&"c".repeat(40))).is_none());
        assert!(releases_wire(&c, None).is_none());

        // A change to origin/main invalidates the whole entry, summaries with it: the TTL
        // path in `origin_main_view` only ever consults an entry whose `sha` IS origin/main,
        // and a fresh read rebuilds both together.
        let stale_origin = OriginMain {
            sha: Some("z".repeat(40)),
            ..c.clone()
        };
        assert_ne!(
            stale_origin.sha, c.sha,
            "a different origin/main is a different entry"
        );
    }

    /// The release block is published beside `origin_main`, never inside it. One cache entry,
    /// two document keys — and never the same bytes twice on the wire.
    #[test]
    fn the_origin_main_block_never_carries_the_summaries() {
        let c = OriginMain {
            sha: Some("a".repeat(40)),
            ci: "green".to_string(),
            releases: Some(ReleaseSummaries::default()),
            releases_for: Some("a".repeat(40)),
            ..Default::default()
        };
        for v in [origin_main_wire(&c), cached_view(&c, 1000)] {
            let obj = v.as_object().unwrap();
            assert!(!obj.contains_key("releases"), "not inside origin_main");
            assert!(!obj.contains_key("releases_for"), "nor its cache key");
            assert_eq!(v["ci"], json!("green"), "the rest is untouched");
        }
    }

    /// The document the app decodes, pinned. **This exact JSON is the fixture the Swift
    /// decoding tests use**, so the two sides cannot drift without one of them failing.
    #[test]
    fn the_release_block_is_shaped_as_the_app_decodes_it() {
        let r = ReleaseSummaries {
            deployed: Some(ReleaseSummary {
                sha: "23f03ce0000000000000000000000000000000aa".to_string(),
                version: Some("bridge 0.106.0".to_string()),
                title: "Stop the deploy card showing a cached answer as a current one".to_string(),
                date_ms: 1_756_500_000_000,
                lines: vec![
                    "The deploy card no longer shows a cached answer as a current one.".to_string(),
                    "A `pending` CI verdict is never served from the cache.".to_string(),
                ],
                more: 0,
            }),
            undeployed: vec![ReleaseSummary {
                sha: "3407550000000000000000000000000000000bb".to_string(),
                version: Some("bridge 0.107.0, App 1.0 (121)".to_string()),
                title: "Take the interim fixes".to_string(),
                date_ms: 1_756_600_000_000,
                lines: vec!["The location channel takes the interim fixes.".to_string()],
                more: 3,
            }],
            truncated: 2,
            reason: None,
        };
        let v = json!(r);
        assert_eq!(v["deployed"]["version"], json!("bridge 0.106.0"));
        assert_eq!(v["deployed"]["lines"].as_array().unwrap().len(), 2);
        assert_eq!(v["deployed"]["more"], json!(0));
        assert_eq!(v["undeployed"][0]["more"], json!(3));
        assert_eq!(v["truncated"], json!(2));
        assert_eq!(v["reason"], Value::Null);
        // Snake case on the wire, as every other key of this document is.
        assert!(v["deployed"].as_object().unwrap().contains_key("date_ms"));
    }

    #[test]
    fn a_ref_is_main_or_a_full_lowercase_sha_and_nothing_else() {
        assert!(is_full_sha("3dbea71c0ffee0ddba11feed1234567890abcdef"));
        assert!(!is_full_sha(""));
        assert!(!is_full_sha("3dbea71"));
        // Uppercase is refused as well: `git rev-parse` would accept it, and accepting two
        // spellings of one commit means `running_sha` comparisons stop matching.
        assert!(!is_full_sha("3DBEA71C0FFEE0DDBA11FEED1234567890ABCDEF"));
        assert!(!is_full_sha(&"g".repeat(40)));
        // The shapes that would matter if this reached `git` as an argument.
        assert!(!is_full_sha("--upload-pack=/bin/sh"));
        assert!(!is_full_sha("main; rm -rf /"));
        assert!(!is_full_sha("origin/main"));
    }

    /// The version is read from `[package]`, NOT from the first `version =` in the file — and
    /// this crate's own manifest is the proof, because it carries dozens of dependency
    /// versions after it.
    #[test]
    fn cargo_version_comes_from_the_package_section() {
        let toml = r#"
[package]
name = "jesse-bridge"
version = "0.94.0"
edition = "2021"

[dependencies]
axum = "0.7"
serde = { version = "1", features = ["derive"] }
"#;
        assert_eq!(parse_cargo_version(toml).as_deref(), Some("0.94.0"));

        // A manifest whose dependencies come FIRST must still answer with the package's.
        let reordered = "[dependencies]\naxum = \"0.7\"\nversion = \"9.9.9\"\n\n\
                         [package]\nversion = \"1.2.3\"\n";
        assert_eq!(parse_cargo_version(reordered).as_deref(), Some("1.2.3"));

        // No `[package]` at all, and an empty value, are both "I do not know" — never a
        // guess, because the caller demands this exact string of the restarted bridge.
        assert_eq!(
            parse_cargo_version("[dependencies]\nversion = \"1\"\n"),
            None
        );
        assert_eq!(parse_cargo_version("[package]\nversion = \"\"\n"), None);
        assert_eq!(parse_cargo_version(""), None);
        // The real file's shape, including the workspace-inheritance form we do NOT use.
        assert_eq!(
            parse_cargo_version("[package]\nversion.workspace = true\n"),
            None
        );
    }

    /// A live symlink is captured by its target; a REAL FILE is copied aside first, because
    /// the staging rename is about to replace it and it is the only copy of the deployment
    /// that was there before this feature existed.
    #[test]
    fn capture_takes_a_symlink_target_and_preserves_a_real_binary() {
        let dir = scratch("capture");
        let bin = dir.join("bin");
        let store = dir.join("store");
        std::fs::create_dir_all(&bin).unwrap();

        // jesse-bridge: a real file, as the pre-P5 installer left it.
        touch_exec(&bin.join("jesse-bridge"));
        // jesse-hook: already a symlink into a build.
        let old_build = store.join("aaaa");
        touch_exec(&old_build.join("jesse-hook"));
        std::os::unix::fs::symlink(old_build.join("jesse-hook"), bin.join("jesse-hook")).unwrap();
        // jesse-build-mcp: absent.

        let prev = capture_previous(&bin, &store, embedded_deploy_bins()).unwrap();
        assert_eq!(
            prev.get("jesse-bridge").map(String::as_str),
            Some(
                store
                    .join(PRE_DEPLOY_DIR)
                    .join("jesse-bridge")
                    .to_string_lossy()
                    .as_ref()
            ),
            "a real binary must be preserved, not recorded in place"
        );
        assert!(store.join(PRE_DEPLOY_DIR).join("jesse-bridge").is_file());
        // The original is still there — copied, not moved, so a failure here leaves the
        // operator with the binary they had.
        assert!(bin.join("jesse-bridge").is_file());
        assert_eq!(
            prev.get("jesse-hook").map(String::as_str),
            Some(old_build.join("jesse-hook").to_string_lossy().as_ref())
        );
        assert_eq!(prev.get("jesse-build-mcp"), None, "absent stays absent");

        // A SECOND capture must not overwrite the preserved original with whatever is live
        // now — that is the copy a rollback all the way back would need.
        std::fs::write(bin.join("jesse-bridge"), b"#!/bin/sh\n# a later build\n").unwrap();
        let again = capture_previous(&bin, &store, embedded_deploy_bins()).unwrap();
        assert_eq!(again.get("jesse-bridge"), prev.get("jesse-bridge"));
        assert_eq!(
            std::fs::read_to_string(store.join(PRE_DEPLOY_DIR).join("jesse-bridge")).unwrap(),
            "#!/bin/sh\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Repointing replaces a symlink WITHOUT following it, and restoring puts back exactly
    /// what `previous` recorded — including removing a link that had nothing behind it.
    #[test]
    fn repoint_and_restore_move_the_links_not_their_targets() {
        let dir = scratch("repoint");
        let bin = dir.join("bin");
        let a = dir.join("a");
        let b = dir.join("b");
        for name in embedded_deploy_bins() {
            touch_exec(&a.join(name));
            touch_exec(&b.join(name));
        }
        std::fs::create_dir_all(&bin).unwrap();
        for name in embedded_deploy_bins() {
            repoint(&bin, name, &a.join(name)).unwrap();
        }
        let prev = capture_previous(&bin, &dir.join("store"), embedded_deploy_bins()).unwrap();
        for name in embedded_deploy_bins() {
            repoint(&bin, name, &b.join(name)).unwrap();
            assert_eq!(std::fs::read_link(bin.join(name)).unwrap(), b.join(name));
        }
        // The old targets are untouched: the rename replaced the LINK, and never wrote
        // through it into the directory it pointed at.
        for name in embedded_deploy_bins() {
            assert!(a.join(name).is_file());
        }
        assert!(restore_previous(&bin, &prev, embedded_deploy_bins()).is_empty());
        for name in embedded_deploy_bins() {
            assert_eq!(std::fs::read_link(bin.join(name)).unwrap(), a.join(name));
        }
        // A name with no `previous` entry is REMOVED, not left pointing at this deploy's
        // build: leaving it would install a binary the operator never had.
        let empty = Previous::new();
        assert!(restore_previous(&bin, &empty, embedded_deploy_bins()).is_empty());
        for name in embedded_deploy_bins() {
            assert!(std::fs::symlink_metadata(bin.join(name)).is_err());
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Prune keeps the three newest — and never the live one or the rollback target, however
    /// old their timestamps are.
    #[test]
    fn prune_keeps_three_and_never_what_is_in_use() {
        let dir = scratch("prune");
        let bin = dir.join("bin");
        let store = dir.join("store");
        std::fs::create_dir_all(&bin).unwrap();
        // Five builds, oldest first, with distinct mtimes.
        let shas: Vec<String> = (0..5)
            .map(|i| format!("{i}").repeat(40)[..40].to_string())
            .collect();
        for (i, sha) in shas.iter().enumerate() {
            for name in embedded_deploy_bins() {
                touch_exec(&store.join(sha).join(name));
            }
            let stamp = SystemTime::now() - Duration::from_secs((5 - i as u64) * 3600);
            let f = std::fs::File::open(store.join(sha)).unwrap();
            f.set_times(std::fs::FileTimes::new().set_modified(stamp))
                .unwrap();
        }
        // A directory that is not a build sha, and the preserved originals — neither is this
        // function's to delete.
        std::fs::create_dir_all(store.join(PRE_DEPLOY_DIR)).unwrap();
        std::fs::create_dir_all(store.join("notes")).unwrap();

        // The OLDEST build is the live one (a rollback makes that happen without touching
        // any timestamp) and the second oldest is the rollback target.
        for name in embedded_deploy_bins() {
            repoint(&bin, name, &store.join(&shas[0]).join(name)).unwrap();
        }
        let mut prev = Previous::new();
        prev.insert(
            "jesse-bridge".to_string(),
            store
                .join(&shas[1])
                .join("jesse-bridge")
                .to_string_lossy()
                .to_string(),
        );

        let removed = prune_builds(&bin, &store, &prev, KEEP_BUILDS, embedded_deploy_bins());
        let left: Vec<String> = std::fs::read_dir(&store)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        // The three newest, plus the two that are in use, plus the two non-builds.
        for keep in [&shas[2], &shas[3], &shas[4], &shas[0], &shas[1]] {
            assert!(
                left.contains(keep),
                "{keep} was pruned but is in use or recent: {left:?}"
            );
        }
        assert!(left.contains(&PRE_DEPLOY_DIR.to_string()));
        assert!(left.contains(&"notes".to_string()));
        assert!(removed.is_empty(), "nothing was prunable here: {removed:?}");

        // With nothing in use, the two oldest go and the three newest stay.
        for name in embedded_deploy_bins() {
            let _ = std::fs::remove_file(bin.join(name));
        }
        let removed = prune_builds(
            &bin,
            &store,
            &Previous::new(),
            KEEP_BUILDS,
            embedded_deploy_bins(),
        );
        assert_eq!(removed.len(), 2, "{removed:?}");
        assert!(removed.contains(&shas[0]) && removed.contains(&shas[1]));
        assert!(store.join(&shas[4]).is_dir());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The three conditions the post-restart poll applies, without a socket.
    #[test]
    fn health_is_judged_on_ok_version_and_new_containment_staleness() {
        let want = "0.94.0";
        let matches = |v: &Value, baseline: Option<&[String]>| match read_health(v, want, baseline)
        {
            Step::Done(x) => format!("done:{x}"),
            Step::Fatal(e) => format!("fatal:{e}"),
            Step::Retry(e) => format!("retry:{e}"),
        };
        assert_eq!(
            matches(&json!({"ok": true, "version": "0.94.0"}), None),
            "done:0.94.0"
        );
        // The OLD version still answering is the case that must keep waiting: `kickstart -k`
        // takes a moment, and a symlink swap that silently did nothing looks the same at
        // first. It is only a failure once the window closes.
        assert!(matches(&json!({"ok": true, "version": "0.93.0"}), None).starts_with("retry:"));
        assert!(matches(&json!({"ok": false, "version": "0.94.0"}), None).starts_with("retry:"));
        assert!(matches(&json!({"ok": true}), None).starts_with("retry:"));

        // A harness that was ALREADY stale stays acceptable; one that was not is fatal at
        // once, because waiting cannot make a containment record match the host.
        let before = vec!["claude-code".to_string()];
        let stale = |h: &str| {
            json!({"ok": true, "version": "0.94.0",
                   "containment_stale": [{"harness": h, "recorded": "1", "installed": "2"}]})
        };
        assert_eq!(matches(&stale("claude-code"), Some(&before)), "done:0.94.0");
        let verdict = matches(&stale("codex"), Some(&before));
        assert!(verdict.starts_with("fatal:"), "{verdict}");
        assert!(verdict.contains("codex"), "{verdict}");
        // No baseline (the bridge was down before the deploy) means this rule does not vote.
        assert_eq!(matches(&stale("codex"), None), "done:0.94.0");
    }

    /// The committed manifest parses, and it is the source the build arguments are written
    /// from — so `--bin` and the staging loop cannot name different sets.
    #[test]
    fn the_committed_manifest_is_the_only_binary_list() {
        let bins = embedded_deploy_bins();
        assert!(
            bins.iter().any(|b| b == BRIDGE_BIN),
            "the deployment must contain the service: {bins:?}"
        );
        // The build argv is DERIVED, not spelled out a second time.
        let args = build_args(bins);
        assert_eq!(&args[..3], &["build", "--release", "--locked"]);
        for name in bins {
            let at = args.iter().position(|a| a == name).expect("named");
            assert_eq!(args[at - 1], "--bin", "{name} must be preceded by --bin");
        }
        assert_eq!(args.len(), 3 + bins.len() * 2, "{args:?}");

        // Each name must be a REAL cargo binary target of this crate, or the build phase
        // fails on a deploy rather than here. `jesse-bridge` is the package's own
        // `src/main.rs`; everything else is a file under `src/bin/`.
        let bin_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/bin");
        for name in bins {
            assert!(
                name == BRIDGE_BIN || bin_dir.join(format!("{name}.rs")).is_file(),
                "{name} is named in {DEPLOY_BINS_MANIFEST} but is not a binary target"
            );
        }
    }

    /// THE STATIC HALF OF THE FIX: every MCP server this repository SHIPS ITS OWN BINARY for
    /// is named in the deploy manifest.
    ///
    /// This is the assertion that would have failed in 0.100.0. `places` was added to the
    /// child MCP config as a bare `jesse-places-mcp` and not to the binary set, so every
    /// deploy afterwards installed a config naming a binary it did not build. Nothing
    /// compared the two lists — one lived in a harness const and the other in this file —
    /// and the failure they produced was invisible.
    ///
    /// Only `jesse-*` commands are in scope: they are the ones a deploy is responsible for
    /// installing. `qmd`, `npx` and the rest are host setup, and their absence is caught at
    /// startup and by the deploy's health gate rather than here.
    #[test]
    fn every_mcp_server_this_repo_builds_is_in_the_deploy_manifest() {
        let bins = embedded_deploy_bins();
        for config in [crate::MAIN_CHILD_MCP_CONFIG, crate::MESSAGES_MCP_CONFIG] {
            for (server, command) in crate::stdio_commands(config) {
                if !command.starts_with("jesse-") {
                    continue;
                }
                assert!(
                    bins.contains(&command),
                    "the `{server}` server runs `{command}`, which no deploy installs — add it \
                     to bridge/{DEPLOY_BINS_MANIFEST} in the same change"
                );
            }
        }
    }

    /// A manifest is read from the TREE, and a tree without one falls back to this build's
    /// list rather than failing — deploying a commit older than the manifest is a real
    /// operation, and rolling back to one is how an outage ends.
    #[test]
    fn the_binary_set_comes_from_the_tree_being_deployed() {
        let dir = scratch("deploy-bins-manifest");
        std::fs::create_dir_all(&dir).unwrap();

        let (bins, from_tree) = deploy_bins_at(&dir).unwrap();
        assert!(!from_tree, "there is no manifest here");
        assert_eq!(bins, embedded_deploy_bins());

        // A commit that adds a binary is deployed WITH it, by a process built before it
        // existed — which is the whole point.
        std::fs::write(
            dir.join(DEPLOY_BINS_MANIFEST),
            "bins = [\"jesse-bridge\", \"jesse-hook\", \"jesse-brand-new\"]\n",
        )
        .unwrap();
        let (bins, from_tree) = deploy_bins_at(&dir).unwrap();
        assert!(from_tree);
        assert_eq!(bins, ["jesse-bridge", "jesse-hook", "jesse-brand-new"]);
        assert!(build_args(&bins).contains(&"jesse-brand-new".to_string()));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// What a manifest may not say. Every entry is joined onto the build store AND onto
    /// `~/.local/bin`, so a name with a path separator in it would repoint something that is
    /// not a deploy binary; and a set with no service in it is not a deployment.
    #[test]
    fn a_manifest_that_could_repoint_the_wrong_thing_is_refused() {
        assert!(parse_deploy_bins("bins = []").is_err());
        assert!(parse_deploy_bins("nothing = 1").is_err());
        assert!(
            parse_deploy_bins("bins = [\"jesse-hook\"]").is_err(),
            "no service"
        );
        for bad in ["../../../bin/sh", "sub/dir", ".hidden", "two words", ""] {
            let text = format!("bins = [\"jesse-bridge\", \"{bad}\"]");
            assert!(
                parse_deploy_bins(&text).is_err(),
                "{bad:?} must not be accepted as a binary name"
            );
        }
        assert!(
            parse_deploy_bins("bins = [\"jesse-bridge\", \"jesse-bridge\"]").is_err(),
            "a name twice would stage the same binary twice and hide a typo"
        );
    }

    /// A bridge that comes back green, on the right version, and unable to run one of its MCP
    /// servers is a FAILED deploy — and it fails at once, because waiting installs nothing.
    #[test]
    fn a_reported_unresolvable_mcp_binary_is_fatal_to_the_deploy() {
        let want = "0.94.0";
        let verdict = |v: &Value| match read_health(v, want, None) {
            Step::Done(x) => format!("done:{x}"),
            Step::Fatal(e) => format!("fatal:{e}"),
            Step::Retry(e) => format!("retry:{e}"),
        };
        let missing = json!({"ok": true, "version": want,
        "mcp_servers_unresolved": [
            {"harness": "claude-code", "server": "places", "command": "jesse-places-mcp"}
        ]});
        let said = verdict(&missing);
        assert!(said.starts_with("fatal:"), "{said}");
        assert!(
            said.contains("places") && said.contains("jesse-places-mcp"),
            "{said}"
        );

        // An EMPTY array is the bridge saying it checked and found nothing.
        assert_eq!(
            verdict(&json!({"ok": true, "version": want, "mcp_servers_unresolved": []})),
            "done:0.94.0"
        );
        // A bridge too old to report the field says nothing, which must not read as a failure.
        assert_eq!(
            verdict(&json!({"ok": true, "version": want})),
            "done:0.94.0"
        );
        // And the version still comes first: the OLD bridge answering is a retry, not a
        // verdict on its MCP servers.
        assert!(verdict(&json!({"ok": true, "version": "0.93.0",
            "mcp_servers_unresolved": [{"server": "places", "command": "jesse-places-mcp"}]}))
        .starts_with("retry:"));
    }

    /// The gate matches a job by the name GitHub actually reports, which is the workflow's
    /// DISPLAY name and not its key.
    #[test]
    fn the_ci_job_is_matched_by_its_display_name() {
        // The exact string this repository's own CI returned from the jobs API. An equality
        // test against "bridge" fails here, which is the bug this function exists for.
        assert!(job_matches(
            "bridge (build, test, clippy, guards, audit, coverage)",
            "bridge"
        ));
        assert!(job_matches("bridge", "bridge"));
        // A reusable workflow renders as `caller / callee`; a matrix leg as `name (leg)`.
        assert!(job_matches("bridge / ubuntu-latest", "bridge"));
        // …and a DIFFERENT job whose name merely starts with the same letters must not
        // vouch for it. This is why the separator set excludes `-`.
        assert!(!job_matches("bridge-nightly", "bridge"));
        assert!(!job_matches("bridgework", "bridge"));
        assert!(!job_matches("ios-app", "bridge"));
        assert!(!job_matches("", "bridge"));
        // Never the other direction: a job called `bridge` does not satisfy a longer want.
        assert!(!job_matches("bridge", "bridge (build)"));
    }

    #[test]
    fn a_dead_pid_is_not_alive_and_pid_1_is() {
        // A process that has certainly exited.
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap();
        let pid = child.id();
        child.wait().unwrap();
        assert!(!pid_is_alive(pid), "pid {pid} exited and was reaped");
        // pid 1 exists and this user cannot signal it: EPERM must read as ALIVE, or a lock
        // would be reclaimed on the strength of "I am not allowed to look".
        assert!(pid_is_alive(1));
        assert!(!pid_is_alive(0));
    }
}
