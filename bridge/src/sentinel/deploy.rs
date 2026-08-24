use super::*;
use serde::Serialize;

// ---- REMOTE DEPLOY, WITH AUTOMATIC ROLLBACK -------------------------------------
//
// The pipeline this completes: a coding session opens a bridge PR, CI goes green, the PR is
// merged from the GitHub app, and the owner — holding nothing but a phone — taps Deploy.
// This module is the half that runs on the host: it builds a commit, swaps three binaries,
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

/// The three binaries a bridge deployment is made of. They MOVE TOGETHER: `jesse-hook` is
/// exec'd by the agent child and `jesse-build-mcp` is an MCP server the child speaks to, so a
/// bridge from one commit running against a hook from another is a combination nobody tested.
pub const DEPLOY_BINS: [&str; 3] = ["jesse-bridge", "jesse-hook", "jesse-build-mcp"];

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

    /// The rollback record: where each of the three symlinks pointed before the last stage.
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
/// A map rather than a single path because the three binaries are staged independently and a
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

/// Capture all three, as one `previous` map.
pub fn capture_previous(bin_dir: &Path, store: &Path) -> Result<Previous, String> {
    let mut prev = Previous::new();
    for name in DEPLOY_BINS {
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

/// Put the three names back where `previous` says they were.
///
/// Every name is attempted even after one fails: a rollback that stopped at the first error
/// would leave the deployment in a state that is neither the old one nor the new one, which is
/// the single worst outcome available here. The errors are collected and reported together.
pub fn restore_previous(bin_dir: &Path, prev: &Previous) -> Vec<String> {
    let mut errors = Vec::new();
    for name in DEPLOY_BINS {
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
pub fn prune_builds(bin_dir: &Path, store: &Path, prev: &Previous, keep: usize) -> Vec<String> {
    let mut protected: Vec<PathBuf> = Vec::new();
    for name in DEPLOY_BINS {
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

/// PHASE 3 — check the commit out and build the three binaries.
async fn phase_build(sen: &Sentinel, log: &DeployLog, sha: &str) -> Result<(), String> {
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
    log.line(&format!(
        "cargo build --release --locked (in {}, up to {} min)",
        crate_dir.display(),
        BUILD_TIMEOUT.as_secs() / 60
    ));
    let out = run_logged(
        log,
        Some(&crate_dir),
        sen.cfg.bins.cargo.as_ref(),
        &[
            "build",
            "--release",
            "--locked",
            "--bin",
            "jesse-bridge",
            "--bin",
            "jesse-hook",
            "--bin",
            "jesse-build-mcp",
        ],
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
    Ok(())
}

/// PHASE 4 — copy the three binaries into the store and repoint the three symlinks.
///
/// Returns the `previous` map, which is what a rollback is written in terms of.
async fn phase_stage(sen: &Sentinel, log: &DeployLog, sha: &str) -> Result<Previous, String> {
    let store = sen.cfg.build_store();
    let dest = store.join(sha);
    std::fs::create_dir_all(&dest)
        .map_err(|e| format!("could not create {}: {e}", dest.display()))?;
    let built = sen.cfg.deploy_clone.join("bridge/target/release");
    for name in DEPLOY_BINS {
        let src = built.join(name);
        let dst = dest.join(name);
        std::fs::copy(&src, &dst)
            .map_err(|e| format!("could not copy {} to {}: {e}", src.display(), dst.display()))?;
        set_executable(&dst)?;
        log.line(&format!("staged {}", dst.display()));
    }

    // BEFORE anything is repointed, and persisted before anything is repointed: a sentinel
    // killed between the swap and this write would have no way back.
    let prev = capture_previous(&sen.cfg.bin_dir, &store)?;
    write_previous(&sen.cfg.previous_file(), &prev)?;
    log.line(&format!(
        "previous: {}",
        serde_json::to_string(&prev).unwrap_or_default()
    ));

    for name in DEPLOY_BINS {
        if let Err(e) = repoint(&sen.cfg.bin_dir, name, &dest.join(name)) {
            // A half-swapped `~/.local/bin` is neither the old deployment nor the new one,
            // which is the worst state available here — so undo what did land before
            // reporting. Nothing has been restarted yet, so this is a plain failure rather
            // than a rollback.
            let undo = restore_previous(&sen.cfg.bin_dir, &prev);
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
async fn phase_rollback(sen: &Arc<Sentinel>, log: &DeployLog, prev: &Previous, why: &str) {
    enter_phase(sen, log, "rollback");
    log.line(&format!("rolling back because: {why}"));
    let errors = restore_previous(&sen.cfg.bin_dir, prev);
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
    if let Err(e) = phase_build(&sen, &log, &sha).await {
        return finish_deploy(&sen, &log, "failed", &e).await;
    }

    enter_phase(&sen, &log, "stage");
    let prev = match phase_stage(&sen, &log, &sha).await {
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
        return phase_rollback(&sen, &log, &prev, &why).await;
    }

    enter_phase(&sen, &log, "finish");
    let pruned = prune_builds(&sen.cfg.bin_dir, &sen.cfg.build_store(), &prev, KEEP_BUILDS);
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
    json!({
        "deploy": deploy,
        "running": { "version": running_version, "sha": running_sha },
        "origin_main": origin_main_view(sen).await,
    })
}

/// The cached-or-refreshed view of `origin/main`.
async fn origin_main_view(sen: &Arc<Sentinel>) -> Value {
    let cached = sen.state.lock_ok().origin_main.clone();
    let now = now_ms();
    if let Some(c) = &cached {
        if now.saturating_sub(c.checked_ms) < ORIGIN_MAIN_TTL_MS {
            return json!(c);
        }
    }
    // A deploy owns the clone while it runs — it leaves a detached head in it and a `cargo`
    // process inside it — so the refresh stands aside rather than fetching underneath a build.
    if sen.deploy_running.load(std::sync::atomic::Ordering::SeqCst) {
        return stale_view(
            cached,
            "a deploy is in flight, so origin/main was not re-read",
        );
    }
    // One refresh at a time. A second caller arriving mid-refresh gets the cache rather than a
    // second `git fetch` in the same clone.
    let Ok(_permit) = sen.origin_refresh.try_lock() else {
        return cached.map(|c| json!(c)).unwrap_or_else(|| {
            stale_view(None, "origin/main is being read now; nothing cached yet")
        });
    };
    match read_origin_main(sen).await {
        Ok(fresh) => {
            sen.state.lock_ok().origin_main = Some(fresh.clone());
            sen.persist_state();
            json!(fresh)
        }
        Err(e) => stale_view(cached, &e),
    }
}

/// A failed or skipped refresh: the cached answer, marked `stale`, or an empty one that says
/// why. NEVER a silently old value — a card that cannot tell "green five minutes ago" from
/// "green, checked just now" is a card that will eventually offer a deploy of a commit whose
/// CI has since gone red.
fn stale_view(cached: Option<OriginMain>, why: &str) -> Value {
    let mut v = match cached {
        Some(c) => json!(c),
        None => json!(OriginMain {
            ci: "none".to_string(),
            ..Default::default()
        }),
    };
    v["stale"] = json!(true);
    v["stale_reason"] = json!(why);
    v
}

/// Read `origin/main` and its CI, for the card.
async fn read_origin_main(sen: &Sentinel) -> Result<OriginMain, String> {
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
    let ci = check_ci(sen, &sha).await?;
    Ok(OriginMain {
        sha: Some(sha),
        version,
        ci: ci.state.to_string(),
        ci_detail: Some(ci.detail),
        checked_ms: now_ms(),
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

        let prev = capture_previous(&bin, &store).unwrap();
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
        let again = capture_previous(&bin, &store).unwrap();
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
        for name in DEPLOY_BINS {
            touch_exec(&a.join(name));
            touch_exec(&b.join(name));
        }
        std::fs::create_dir_all(&bin).unwrap();
        for name in DEPLOY_BINS {
            repoint(&bin, name, &a.join(name)).unwrap();
        }
        let prev = capture_previous(&bin, &dir.join("store")).unwrap();
        for name in DEPLOY_BINS {
            repoint(&bin, name, &b.join(name)).unwrap();
            assert_eq!(std::fs::read_link(bin.join(name)).unwrap(), b.join(name));
        }
        // The old targets are untouched: the rename replaced the LINK, and never wrote
        // through it into the directory it pointed at.
        for name in DEPLOY_BINS {
            assert!(a.join(name).is_file());
        }
        assert!(restore_previous(&bin, &prev).is_empty());
        for name in DEPLOY_BINS {
            assert_eq!(std::fs::read_link(bin.join(name)).unwrap(), a.join(name));
        }
        // A name with no `previous` entry is REMOVED, not left pointing at this deploy's
        // build: leaving it would install a binary the operator never had.
        let empty = Previous::new();
        assert!(restore_previous(&bin, &empty).is_empty());
        for name in DEPLOY_BINS {
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
            for name in DEPLOY_BINS {
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
        for name in DEPLOY_BINS {
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

        let removed = prune_builds(&bin, &store, &prev, KEEP_BUILDS);
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
        for name in DEPLOY_BINS {
            let _ = std::fs::remove_file(bin.join(name));
        }
        let removed = prune_builds(&bin, &store, &Previous::new(), KEEP_BUILDS);
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
