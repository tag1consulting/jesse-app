use super::*;

// ---- The probes ----------------------------------------------------------------
//
// `GET /sentinel/status` is ONE document assembled from independent probes, and the word
// that matters is independent: the request must answer even when a subsystem is wedged,
// because a wedged subsystem is precisely when someone is reading it. So every probe is
// wrapped in [`PROBE_TIMEOUT`], they all run concurrently, and a probe that does not finish
// degrades to `unknown` — a stated absence of knowledge — rather than failing the call or
// reporting a cheerful default.
//
// The parsers are pure functions over the text these tools emit, tested from fixtures. That
// split is deliberate: the interesting failures here are format failures ("last exit code =
// (never exited)" is not an integer), and a test that has to spawn `launchctl` to find them
// is a test nobody runs.

/// What a probe learned. Three states, not two: `Unknown` is what a timeout produces and it
/// must never be confused with `Failed`. "The disk is not full" and "I could not find out
/// whether the disk is full" lead to different actions.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ProbeState {
    Ok,
    Failed,
    Unknown,
}

impl ProbeState {
    pub fn label(self) -> &'static str {
        match self {
            ProbeState::Ok => "ok",
            ProbeState::Failed => "failed",
            ProbeState::Unknown => "unknown",
        }
    }
}

/// One probe's report.
#[derive(Clone, Debug)]
pub struct Probe {
    pub state: ProbeState,
    pub detail: Value,
    pub error: Option<String>,
}

impl Probe {
    pub fn ok(detail: Value) -> Probe {
        Probe {
            state: ProbeState::Ok,
            detail,
            error: None,
        }
    }

    /// `ok`, but with something worth saying in the `error` field anyway — a state that is
    /// not a fault but is not silence either (an artifact store that does not exist yet, a
    /// ledger the scheduler has not written for the first time). The alternative is a green
    /// row with no explanation, which reads as "checked and fine" for a thing that was not
    /// checked at all.
    pub fn ok_with_note(detail: Value, note: impl Into<String>) -> Probe {
        Probe {
            state: ProbeState::Ok,
            detail,
            error: Some(note.into()),
        }
    }

    pub fn failed(detail: Value, error: impl Into<String>) -> Probe {
        Probe {
            state: ProbeState::Failed,
            detail,
            error: Some(error.into()),
        }
    }

    pub fn unknown(error: impl Into<String>) -> Probe {
        Probe {
            state: ProbeState::Unknown,
            detail: Value::Null,
            error: Some(error.into()),
        }
    }

    /// The wire shape. `ok` is a TRISTATE — `true`, `false`, or `null` for unknown — and
    /// `state` spells the same thing for a reader who would otherwise have to know that a
    /// missing `ok` is different from a false one.
    pub fn to_json(&self) -> Value {
        json!({
            "ok": match self.state {
                ProbeState::Ok => Value::Bool(true),
                ProbeState::Failed => Value::Bool(false),
                ProbeState::Unknown => Value::Null,
            },
            "state": self.state.label(),
            "detail": self.detail,
            "error": self.error,
        })
    }
}

/// Run one probe under the standard ceiling, degrading to `unknown` when it overruns.
pub async fn timed(name: &str, fut: impl Future<Output = Probe>) -> Probe {
    timed_within(name, PROBE_TIMEOUT, fut).await
}

/// [`timed`] with the ceiling named. Separate so a test can assert the degradation in
/// milliseconds instead of spending the real five seconds to watch it happen.
pub async fn timed_within(name: &str, limit: Duration, fut: impl Future<Output = Probe>) -> Probe {
    match timeout(limit, fut).await {
        Ok(p) => p,
        Err(_) => Probe::unknown(format!("{name} probe did not finish within {limit:?}")),
    }
}

// ---- launchd -------------------------------------------------------------------

/// The four fields worth having out of `launchctl print`. Everything else in that output is
/// either constant, enormous, or about mach ports.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ServiceInfo {
    /// `running`, `waiting`, `not running`, … — launchd's own word for it.
    pub state: Option<String>,
    pub pid: Option<i64>,
    /// `None` when launchd says `(never exited)`, which is NOT the same as 0.
    pub last_exit_code: Option<i64>,
    pub runs: Option<i64>,
}

impl ServiceInfo {
    pub fn to_json(&self) -> Value {
        json!({
            "state": self.state,
            "pid": self.pid,
            "last_exit_code": self.last_exit_code,
            "runs": self.runs,
        })
    }
}

/// Parse `launchctl print gui/<uid>/<label>`.
///
/// The output is an indented `key = value` block with nested `{ … }` sub-blocks. Only the
/// TOP-LEVEL keys are wanted: a nested `endpoints = { … pid = … }` must not be mistaken for
/// the job's pid, so depth is tracked and anything deeper than the outer service dictionary
/// is skipped. `last exit code = (never exited)` is the field that has no integer form, and
/// it is reported as absent rather than as zero — "it has never exited" and "it exited
/// cleanly" are opposite facts about a `KeepAlive` job.
pub fn parse_launchctl_print(text: &str) -> ServiceInfo {
    let mut info = ServiceInfo::default();
    let mut depth: i32 = 0;
    for raw in text.lines() {
        let line = raw.trim();
        // Depth is counted AFTER reading the line's key, so `arguments = {` is seen at the
        // level it is declared and its contents at one deeper.
        let opens = line.matches('{').count() as i32;
        let closes = line.matches('}').count() as i32;
        let at_top = depth == 1;
        depth += opens - closes;
        if !at_top {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        match key {
            "state" => info.state = Some(value.to_string()),
            "pid" => info.pid = value.parse().ok(),
            "runs" => info.runs = value.parse().ok(),
            "last exit code" => info.last_exit_code = value.parse().ok(),
            _ => {}
        }
    }
    info
}

/// One `launchctl print` per configured label, sequentially — five 5 ms calls, and running
/// them concurrently would only add task overhead. A label that is not loaded exits
/// non-zero, which is reported as a `not-loaded` state rather than an error: a miniserve
/// that was never installed is a fact about the deployment, not a fault in the sentinel.
pub async fn probe_services(sen: &Sentinel) -> Probe {
    let mut out = serde_json::Map::new();
    let mut any_failed = false;
    for slot in SERVICE_SLOTS {
        let target = sen.cfg.target(slot);
        let res = run_cmd(
            sen.cfg.bins.launchctl.as_ref(),
            &["print", &target],
            &[],
            PROBE_TIMEOUT,
        )
        .await;
        // A launchctl we could not run, or that hung, makes the WHOLE probe `unknown`
        // rather than painting five services as "not loaded" on no evidence.
        if res.unrunnable() {
            return Probe::unknown(format!("launchctl print {target}: {}", res.summary()));
        }
        let mut row = if res.ok() {
            parse_launchctl_print(&res.stdout).to_json()
        } else {
            any_failed = true;
            json!({
                "state": "not-loaded",
                "pid": Value::Null,
                "last_exit_code": Value::Null,
                "runs": Value::Null,
                "error": res.summary(),
            })
        };
        // The label is on every row: the slug is the sentinel's vocabulary, the label is
        // what an operator would type into `launchctl` themselves.
        row["label"] = json!(sen.cfg.label(slot));
        out.insert(slot.slug().to_string(), row);
    }
    let detail = Value::Object(out);
    if any_failed {
        Probe::failed(detail, "one or more services are not loaded")
    } else {
        Probe::ok(detail)
    }
}

// ---- The bridge ------------------------------------------------------------------

/// `GET /health` on the bridge, with the bearer token so the operator detail (version, the
/// drift arrays, the active profile) comes back rather than the bare liveness answer.
pub async fn probe_bridge(sen: &Sentinel) -> Probe {
    let started = Instant::now();
    match sen.bridge_get("/health", PROBE_TIMEOUT).await {
        Ok((status, body)) => {
            let latency = started.elapsed().as_millis() as u64;
            let detail = json!({
                "reachable": true,
                "status": status,
                "latency_ms": latency,
                "health": body,
            });
            if (200..300).contains(&status) {
                Probe::ok(detail)
            } else {
                Probe::failed(detail, format!("bridge /health returned {status}"))
            }
        }
        Err(e) => Probe::failed(
            json!({ "reachable": false, "latency_ms": Value::Null, "health": Value::Null }),
            e,
        ),
    }
}

/// The bridge's `GET /jesse/schedule`, verbatim. Proxied rather than re-derived: the
/// sentinel has no schedule of its own and must never grow one.
pub async fn probe_schedule(sen: &Sentinel) -> Probe {
    match sen.bridge_get("/jesse/schedule", PROBE_TIMEOUT).await {
        Ok((status, body)) if (200..300).contains(&status) => Probe::ok(body),
        Ok((status, body)) => {
            Probe::failed(body, format!("bridge /jesse/schedule returned {status}"))
        }
        Err(e) => Probe::failed(Value::Null, e),
    }
}

// ---- Tailscale ---------------------------------------------------------------------

/// `Self.Online`, `Self.TailscaleIPs`, `Self.DNSName` out of `tailscale status --json`.
pub fn parse_tailscale_status(text: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("unparseable JSON: {e}"))?;
    let me = v
        .get("Self")
        .ok_or_else(|| "no Self object in tailscale status".to_string())?;
    let ips: Vec<Value> = me
        .get("TailscaleIPs")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(json!({
        "online": me.get("Online").and_then(Value::as_bool).unwrap_or(false),
        "ips": ips,
        // Trailing dot and all, exactly as tailscale reports it — normalising it here would
        // make the field disagree with what `tailscale status` prints on the host.
        "dns_name": me.get("DNSName").and_then(Value::as_str),
    }))
}

pub async fn probe_tailscale(sen: &Sentinel) -> Probe {
    let res = run_cmd(
        sen.cfg.bins.tailscale.as_ref(),
        &["status", "--json"],
        &[],
        PROBE_TIMEOUT,
    )
    .await;
    // A tailscale we could not RUN is `unknown`, not offline. The watchdog acts on this
    // probe — it runs `tailscale up` — and "the binary is not installed" or "the call hung"
    // must never be read as an outage, because the action would then fire forever against a
    // condition that does not exist.
    if res.spawn_error.is_some() || res.timed_out {
        return Probe::unknown(res.summary());
    }
    if !res.ok() {
        return Probe::failed(Value::Null, res.summary());
    }
    match parse_tailscale_status(&res.stdout) {
        // EXIT 0 IS NOT ENOUGH. The macOS CLI lives inside the app bundle and, when it cannot
        // reach the GUI's state (a sandbox/HOME mismatch, the app not running), prints
        // "The Tailscale GUI failed to start: …" on STDOUT and exits ZERO. So the parse is
        // the real check, and its error carries what actually came back — "unparseable JSON
        // at line 1" alone would send an operator hunting for a JSON bug that is not there.
        Err(e) => Probe::failed(
            Value::Null,
            match res.stdout.lines().map(str::trim).find(|l| !l.is_empty()) {
                Some(first) => format!(
                    "{e} — tailscale said: {}",
                    first.chars().take(200).collect::<String>()
                ),
                None => format!("{e} — tailscale printed nothing"),
            },
        ),
        Ok(detail) => {
            let online = detail
                .get("online")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if online {
                Probe::ok(detail)
            } else {
                Probe::failed(detail, "this node is offline on the tailnet")
            }
        }
    }
}

// ---- Disk ----------------------------------------------------------------------------

/// Free and total bytes from `df -k <path>`.
///
/// `-k` fixes the block size at 1024, so the numbers do not depend on `BLOCKSIZE` in the
/// environment. The data row is the LAST non-header line.
///
/// The columns are NOT read by index. A filesystem name can contain a space — macOS's
/// `map auto_home` is the one every Mac has — and an index-based read of such a row parses
/// the second half of the NAME as the block count. So the row is scanned for the first run of
/// three consecutive integers, which is `1024-blocks Used Available` wherever the name ends.
pub fn parse_df_k(text: &str) -> Option<(u64, u64)> {
    let row = text
        .lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty() && !l.starts_with("Filesystem"))?;
    let f: Vec<&str> = row.split_whitespace().collect();
    let nums = |i: usize| -> Option<(u64, u64, u64)> {
        Some((
            f.get(i)?.parse().ok()?,
            f.get(i + 1)?.parse().ok()?,
            f.get(i + 2)?.parse().ok()?,
        ))
    };
    let (total, _used, avail) = (0..f.len()).find_map(nums)?;
    Some((avail * 1024, total * 1024))
}

/// Total bytes under a directory tree, and how many files that was.
///
/// Bounded by `max_entries` so a pathological store cannot turn a status request into a
/// filesystem walk that outlives its own timeout; `complete` says whether the number is the
/// whole answer. Symlinks are not followed (`symlink_metadata`), so a link into the vault
/// cannot make the artifact store look enormous — or be walked at all.
pub fn dir_size(root: &Path, max_entries: usize) -> (u64, usize, bool) {
    let mut bytes = 0u64;
    let mut files = 0usize;
    let mut stack = vec![root.to_path_buf()];
    let mut seen = 0usize;
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            seen += 1;
            if seen > max_entries {
                return (bytes, files, false);
            }
            let Ok(md) = entry.metadata() else { continue };
            if md.is_dir() {
                stack.push(entry.path());
            } else if md.is_file() {
                bytes += md.len();
                files += 1;
            }
        }
    }
    (bytes, files, true)
}

/// How many directory entries the artifact walk visits before giving up and saying so.
pub const MAX_WALK_ENTRIES: usize = 50_000;

/// Ten gigabytes: the watchdog's free-space floor, and the threshold this probe reports
/// against so the status page and the watchdog cannot disagree.
pub const DISK_FLOOR_BYTES: u64 = 10 * 1024 * 1024 * 1024;

pub async fn probe_disk(sen: &Sentinel) -> Probe {
    let mut volumes = Vec::new();
    let mut min_free: Option<u64> = None;
    let mut errors = Vec::new();
    for path in [&sen.cfg.vault_repo, &sen.cfg.bridge_state_dir] {
        let p = path.to_string_lossy().to_string();
        let res = run_cmd(sen.cfg.bins.df.as_ref(), &["-k", &p], &[], PROBE_TIMEOUT).await;
        if res.unrunnable() {
            return Probe::unknown(format!("df -k {p}: {}", res.summary()));
        }
        match res.ok().then(|| parse_df_k(&res.stdout)).flatten() {
            Some((free, total)) => {
                min_free = Some(min_free.map_or(free, |m: u64| m.min(free)));
                volumes.push(json!({ "path": p, "free_bytes": free, "total_bytes": total }));
            }
            None => {
                errors.push(format!("df {p}: {}", res.summary()));
                volumes.push(
                    json!({ "path": p, "free_bytes": Value::Null, "total_bytes": Value::Null }),
                );
            }
        }
    }
    let (artifact_bytes, artifact_files, complete) =
        dir_size(&sen.cfg.artifacts_dir(), MAX_WALK_ENTRIES);
    let detail = json!({
        "volumes": volumes,
        "free_bytes_min": min_free,
        "floor_bytes": DISK_FLOOR_BYTES,
        "artifacts_bytes": artifact_bytes,
        "artifacts_files": artifact_files,
        // A partial walk must say so rather than under-report the store as small.
        "artifacts_complete": complete,
    });
    if !errors.is_empty() {
        return Probe::failed(detail, errors.join("; "));
    }
    match min_free {
        Some(free) if free < DISK_FLOOR_BYTES => Probe::failed(
            detail,
            format!(
                "only {} MB free — under the {} GB floor",
                free / (1024 * 1024),
                DISK_FLOOR_BYTES / (1024 * 1024 * 1024)
            ),
        ),
        _ => Probe::ok(detail),
    }
}

// ---- Git and the autocommit --------------------------------------------------------

/// The last status line the autocommit job wrote, e.g.
/// `2026-08-23 18:36 PUBLISHED: 315d6788 on origin`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutocommitLine {
    pub line: String,
    /// True for `PUBLISHED:`, false for `UNPUBLISHED:` or anything carrying `CONFLICT`.
    pub published: bool,
}

/// Find the LAST line that is a run's final status.
///
/// The log carries a status line per run and whatever the run printed on the way there, so
/// "the last line" is the wrong question — a run that printed a warning after its status
/// would answer it wrongly. `CONFLICT` counts as unpublished wherever it appears on such a
/// line, because a conflicted autocommit is exactly the state that must never read as fine.
pub fn parse_autocommit_tail(text: &str) -> Option<AutocommitLine> {
    text.lines()
        .map(str::trim)
        .rfind(|l| l.contains("PUBLISHED:") || l.contains("CONFLICT"))
        .map(|l| AutocommitLine {
            line: l.chars().take(300).collect(),
            // `UNPUBLISHED:` contains `PUBLISHED:` as a substring, so the negative test
            // comes first — the reverse would report every failure as a success.
            published: !l.contains("UNPUBLISHED:") && !l.contains("CONFLICT"),
        })
}

/// Read the last `max_bytes` of a file as text, so tailing a log or a ledger never loads a
/// hundred megabytes to answer a question about twenty lines. The first (probably partial)
/// line of the window is dropped by the callers, which take whole lines from the end.
pub fn tail_bytes(path: &Path, max_bytes: u64) -> Result<String, String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let len = f.metadata().map_err(|e| e.to_string())?.len();
    let from = len.saturating_sub(max_bytes);
    if from > 0 {
        f.seek(SeekFrom::Start(from)).map_err(|e| e.to_string())?;
    }
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&buf).to_string();
    // A window that started mid-line: drop the fragment so no caller parses half a record.
    Ok(if from > 0 {
        match text.find('\n') {
            Some(i) => text[i + 1..].to_string(),
            None => String::new(),
        }
    } else {
        text
    })
}

/// The tail window for a log or ledger. 256 KB is thousands of lines of either.
pub const TAIL_WINDOW_BYTES: u64 = 256 * 1024;

/// Age in seconds of a file, or `None` when it does not exist.
pub fn file_age_secs(path: &Path) -> Option<u64> {
    let md = std::fs::metadata(path).ok()?;
    let modified = md.modified().ok()?;
    Some(
        SystemTime::now()
            .duration_since(modified)
            .map(|d| d.as_secs())
            // A file stamped in the future is age zero, not an error.
            .unwrap_or(0),
    )
}

/// One `git -C <repo>` invocation, trimmed.
async fn git(sen: &Sentinel, args: &[&str]) -> CmdOut {
    let repo = sen.cfg.vault_repo.to_string_lossy().to_string();
    let mut full = vec!["-C", repo.as_str()];
    full.extend_from_slice(args);
    run_cmd(sen.cfg.bins.git.as_ref(), &full, &[], PROBE_TIMEOUT).await
}

/// `behind`/`ahead` from `git rev-list --left-right --count @{upstream}...HEAD`, whose
/// output is `<behind>\t<ahead>`. A branch with no upstream fails the command, which is a
/// fact worth reporting rather than two zeroes.
pub fn parse_ahead_behind(text: &str) -> Option<(u64, u64)> {
    let mut f = text.split_whitespace();
    let behind: u64 = f.next()?.parse().ok()?;
    let ahead: u64 = f.next()?.parse().ok()?;
    Some((ahead, behind))
}

pub async fn probe_git(sen: &Sentinel) -> Probe {
    let branch = git(sen, &["rev-parse", "--abbrev-ref", "HEAD"]).await;
    if branch.unrunnable() {
        return Probe::unknown(format!(
            "git in {}: {}",
            sen.cfg.vault_repo.display(),
            branch.summary()
        ));
    }
    if !branch.ok() {
        return Probe::failed(
            json!({ "repo": sen.cfg.vault_repo.to_string_lossy() }),
            format!(
                "git in {}: {}",
                sen.cfg.vault_repo.display(),
                branch.summary()
            ),
        );
    }
    let counts = git(
        sen,
        &["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
    )
    .await;
    let (ahead, behind) = counts
        .ok()
        .then(|| parse_ahead_behind(&counts.stdout))
        .flatten()
        .map(|(a, b)| (Some(a), Some(b)))
        .unwrap_or((None, None));
    let status = git(sen, &["status", "--porcelain"]).await;
    let conflicts = git(sen, &["diff", "--name-only", "--diff-filter=U"]).await;
    let conflict_files: Vec<&str> = conflicts
        .stdout
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let lock = sen.cfg.index_lock();
    let autocommit = sen
        .cfg
        .autocommit_log
        .as_ref()
        .map(|p| match tail_bytes(p, TAIL_WINDOW_BYTES) {
            Ok(text) => match parse_autocommit_tail(&text) {
                Some(l) => json!({ "line": l.line, "published": l.published }),
                None => json!({ "line": Value::Null, "published": Value::Null }),
            },
            Err(e) => json!({ "line": Value::Null, "published": Value::Null, "error": e }),
        })
        .unwrap_or(Value::Null);
    let detail = json!({
        "repo": sen.cfg.vault_repo.to_string_lossy(),
        "branch": branch.stdout.trim(),
        "ahead": ahead,
        "behind": behind,
        "dirty": !status.stdout.trim().is_empty(),
        "index_lock_age_secs": file_age_secs(&lock),
        "conflicts": conflict_files,
        "last_autocommit_line": autocommit,
    });
    // Conflicts are the one git state the sentinel treats as failed. Being ahead, behind or
    // dirty is normal for a vault the owner is writing into all day.
    if !conflict_files.is_empty() {
        return Probe::failed(
            detail,
            format!("{} conflicted path(s)", conflict_files.len()),
        );
    }
    Probe::ok(detail)
}

// ---- qmd ----------------------------------------------------------------------------

/// `qmd status` under the BRIDGE CHILD's `PATH`.
///
/// The `PATH` is the entire point. `qmd` is a Node program with a native addon, and under a
/// Node whose ABI does not match the one it was built against it dies with
/// `ERR_DLOPEN_FAILED` — so probing it with the sentinel's own `PATH` (or launchd's minimal
/// one) tests a resolution no turn ever performs and can report healthy while every turn's
/// search is broken. `JESSE_SENTINEL_CHILD_PATH` is documented as "copy the bridge plist's
/// PATH here", and the node that PATH resolves to is reported beside the result, because
/// that is the value an operator needs to see when the answer is a dlopen failure.
pub async fn probe_qmd(sen: &Sentinel) -> Probe {
    let env: Vec<(&str, &str)> = match &sen.cfg.child_path {
        Some(p) => vec![("PATH", p.as_str())],
        None => vec![],
    };
    let res = run_cmd(sen.cfg.bins.qmd.as_ref(), &["status"], &env, PROBE_TIMEOUT).await;
    if res.unrunnable() {
        return Probe::unknown(format!("qmd status: {}", res.summary()));
    }
    let node = run_cmd(
        sen.cfg.bins.node.as_ref(),
        &["--version"],
        &env,
        PROBE_TIMEOUT,
    )
    .await;
    let detail = json!({
        "exit_code": res.code,
        "first_stderr_line": res.first_stderr_line(),
        "child_path_set": sen.cfg.child_path.is_some(),
        "node_version": node.ok().then(|| node.stdout.trim().to_string()),
    });
    if res.ok() {
        Probe::ok(detail)
    } else {
        Probe::failed(detail, res.summary())
    }
}

// ---- The scheduler's ledger -----------------------------------------------------------

/// How many ledger lines `GET /sentinel/status` returns.
pub const LEDGER_TAIL_LINES: usize = 20;

/// The last `n` ledger lines, parsed. A line that is not JSON is kept as a raw string rather
/// than dropped: a ledger that has started emitting garbage is a thing to see, not to hide.
pub fn parse_ledger_tail(text: &str, n: usize) -> Vec<Value> {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    lines
        .iter()
        .skip(lines.len().saturating_sub(n))
        .map(|l| serde_json::from_str::<Value>(l).unwrap_or_else(|_| json!({ "raw": l })))
        .collect()
}

/// The most recent `at_ms` of any ledger line whose `outcome` is `fired`, which is the one
/// question the silence rule asks. `fired-no-output` deliberately does NOT count as silence:
/// the scheduler ran, and a job that produced nothing is a different alarm with its own
/// escalation inside the bridge.
pub fn last_fired_ms(lines: &[Value]) -> Option<u64> {
    lines
        .iter()
        .filter(|l| l.get("outcome").and_then(Value::as_str) == Some("fired"))
        .filter_map(|l| l.get("at_ms").and_then(Value::as_u64))
        .max()
}

pub async fn probe_ledger(sen: &Sentinel) -> Probe {
    match tail_bytes(&sen.cfg.ledger, TAIL_WINDOW_BYTES) {
        Ok(text) => Probe::ok(json!(parse_ledger_tail(&text, LEDGER_TAIL_LINES))),
        // AN ABSENT LEDGER IS NOT A FAULT. The scheduler creates it on the first occurrence
        // it records, so a bridge that has not reached one yet — a fresh deploy, a config
        // with no `[[schedule]]` entries — legitimately has no file. Reporting that red on
        // the status page would train the reader to ignore the row. Anything else (a
        // permission error, a directory where the file should be) IS a fault.
        Err(e) if !sen.cfg.ledger.exists() => Probe::ok_with_note(
            json!([]),
            format!("{} does not exist yet ({e})", sen.cfg.ledger.display()),
        ),
        Err(e) => Probe::failed(json!([]), format!("{}: {e}", sen.cfg.ledger.display())),
    }
}

// ---- The whole document ------------------------------------------------------------

/// Assemble `GET /sentinel/status`.
///
/// Every probe runs CONCURRENTLY and under its own ceiling, so the document's latency is the
/// slowest probe rather than their sum, and one wedged subsystem costs one `unknown` field.
pub async fn status_document(sen: &Sentinel) -> Value {
    let (bridge, services, tailscale, disk, git_p, qmd, ledger, schedule) = tokio::join!(
        timed("bridge", probe_bridge(sen)),
        timed("services", probe_services(sen)),
        timed("tailscale", probe_tailscale(sen)),
        timed("disk", probe_disk(sen)),
        timed("git", probe_git(sen)),
        timed("qmd", probe_qmd(sen)),
        timed("ledger", probe_ledger(sen)),
        timed("schedule", probe_schedule(sen)),
    );
    let now = now_ms();
    let watchdog = sen.state.lock_ok().report(now);
    json!({
        "sentinel": {
            "version": sen.version,
            "uptime_secs": sen.uptime_secs(),
            "now_ms": now,
            "watchdog": watchdog,
        },
        "bridge": bridge.to_json(),
        "services": services.to_json(),
        "tailscale": tailscale.to_json(),
        "disk": disk.to_json(),
        "git": git_p.to_json(),
        "qmd": qmd.to_json(),
        "ledger_tail": ledger.to_json(),
        "schedule": schedule.to_json(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A real `launchctl print` block, trimmed to the fields that matter and the nested
    /// blocks that used to break the parse.
    const LAUNCHCTL_RUNNING: &str = r#"gui/501/com.example.jesse-bridge = {
	active count = 4
	path = /Users/you/Library/LaunchAgents/com.example.jesse-bridge.plist
	type = LaunchAgent
	state = running

	program = /Users/you/.local/bin/jesse-bridge
	arguments = {
		/Users/you/.local/bin/jesse-bridge
		--serve
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	domain = gui/501 [100003]
	asid = 100003
	minimum runtime = 10
	exit timeout = 5
	runs = 7
	pid = 15818
	immediate reason = speculative
	forks = 0
	execs = 1
	last exit code = (never exited)

	endpoints = {
		"com.example.endpoint" = {
			port = 0xf9e3b
			active = 1
			pid = 99999
			runs = 4321
		}
	}

	spawn type = daemon (3)
}
"#;

    #[test]
    fn launchctl_print_reads_the_top_level_fields() {
        let info = parse_launchctl_print(LAUNCHCTL_RUNNING);
        assert_eq!(info.state.as_deref(), Some("running"));
        assert_eq!(info.runs, Some(7));
        // THE NESTED-BLOCK TRAP: `endpoints` carries its own `pid` and `runs`, further down
        // the file than the real ones. A line-order-only parser reports 99999.
        assert_eq!(info.pid, Some(15818));
        // `(never exited)` is not zero, and reporting it as zero would tell an operator a
        // KeepAlive job had exited cleanly when it has never exited at all.
        assert_eq!(info.last_exit_code, None);
    }

    #[test]
    fn launchctl_print_reads_a_stopped_job_with_an_exit_code() {
        let text = "gui/501/com.example.jesse-autocommit = {\n\
                    \tstate = not running\n\
                    \truns = 412\n\
                    \tlast exit code = 1\n\
                    }\n";
        let info = parse_launchctl_print(text);
        assert_eq!(info.state.as_deref(), Some("not running"));
        assert_eq!(info.last_exit_code, Some(1));
        assert_eq!(info.runs, Some(412));
        assert_eq!(info.pid, None, "a stopped job has no pid");
    }

    #[test]
    fn launchctl_print_of_nothing_is_all_absent() {
        // `Could not find service …` on stderr, empty stdout: every field absent, no panic.
        assert_eq!(parse_launchctl_print(""), ServiceInfo::default());
        assert_eq!(
            parse_launchctl_print("Could not find service \"x\" in domain for user gui: 501"),
            ServiceInfo::default()
        );
    }

    #[test]
    fn tailscale_status_reads_self() {
        let json_text = r#"{
          "BackendState": "Running",
          "Self": {
            "Online": true,
            "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
            "DNSName": "host.tailnet.ts.net."
          },
          "Peer": {}
        }"#;
        let v = parse_tailscale_status(json_text).unwrap();
        assert_eq!(v["online"], json!(true));
        assert_eq!(v["ips"], json!(["100.64.0.1", "fd7a:115c:a1e0::1"]));
        assert_eq!(v["dns_name"], json!("host.tailnet.ts.net."));
    }

    #[test]
    fn tailscale_status_offline_and_malformed() {
        let off = parse_tailscale_status(r#"{"Self":{"Online":false,"TailscaleIPs":[]}}"#).unwrap();
        assert_eq!(off["online"], json!(false));
        assert_eq!(off["dns_name"], Value::Null);
        // A missing `Online` key must read as offline, never as online-by-default.
        let bare = parse_tailscale_status(r#"{"Self":{}}"#).unwrap();
        assert_eq!(bare["online"], json!(false));
        assert!(parse_tailscale_status("not json").is_err());
        assert!(parse_tailscale_status(r#"{"Peer":{}}"#).is_err());
    }

    #[tokio::test]
    async fn tailscale_exit_zero_with_prose_is_a_failure_that_quotes_it() {
        // The shape measured on this host: the app-bundle CLI printed
        // "The Tailscale GUI failed to start: …" on STDOUT and exited 0.
        let out = "The Tailscale GUI failed to start: (Tailscale.CLIError error 3.)\n";
        let err = parse_tailscale_status(out).unwrap_err();
        assert!(err.contains("unparseable JSON"), "{err}");
        // …and the probe must carry the prose, not just "expected value at line 1 column 1",
        // which would send someone hunting for a JSON bug that is not there.
        let first = out.lines().next().unwrap();
        assert!(first.contains("GUI failed to start"));
    }

    #[test]
    fn df_k_reads_free_and_total() {
        let text = "Filesystem   1024-blocks      Used Available Capacity iused ifree %iused  Mounted on\n\
                    /dev/disk3s5  1942700360 900000000 1000000000    48%  1000 2000   1%   /System/Volumes/Data\n";
        let (free, total) = parse_df_k(text).unwrap();
        assert_eq!(free, 1_000_000_000 * 1024);
        assert_eq!(total, 1_942_700_360 * 1024);
    }

    #[test]
    fn df_k_survives_a_filesystem_name_with_a_space() {
        // `map auto_home` is on every Mac, and an index-based column read parses
        // "auto_home" as the block count and gives up.
        let spaced = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
                      map auto_home 0 0 0 100% /System/Volumes/Data/home\n";
        assert_eq!(parse_df_k(spaced), Some((0, 0)));
        let spaced_nonzero = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
                              my volume name 100 40 60 40% /Volumes/My Disk\n";
        assert_eq!(parse_df_k(spaced_nonzero), Some((60 * 1024, 100 * 1024)));
    }

    #[test]
    fn df_k_rejects_junk_rather_than_guessing() {
        assert_eq!(parse_df_k(""), None);
        // Header only (the path did not exist, df printed nothing else).
        assert_eq!(parse_df_k("Filesystem 1024-blocks Used Available\n"), None);
        assert_eq!(parse_df_k("garbage without numbers here now\n"), None);
        assert_eq!(parse_df_k("df: /nope: No such file or directory\n"), None);
    }

    #[test]
    fn autocommit_tail_finds_the_last_status_line() {
        let log = "2026-08-23 17:51 PUBLISHED: cffc8b9b on origin\n\
                   2026-08-23 18:06 UNPUBLISHED: nothing to push\n\
                   2026-08-23 18:21 PUBLISHED: 315d6788 on origin\n";
        let l = parse_autocommit_tail(log).unwrap();
        assert!(l.published);
        assert!(l.line.contains("315d6788"));
    }

    #[test]
    fn autocommit_unpublished_is_not_read_as_published() {
        // `UNPUBLISHED:` CONTAINS `PUBLISHED:`. A naive `contains("PUBLISHED:")` test
        // reports every stuck run as a success, which is the exact blindness this watches.
        let log = "2026-08-23 18:06 PUBLISHED: aaa on origin\n\
                   2026-08-23 18:21 UNPUBLISHED: push rejected\n";
        let l = parse_autocommit_tail(log).unwrap();
        assert!(!l.published, "UNPUBLISHED must not read as published");
        assert!(l.line.contains("push rejected"));
    }

    #[test]
    fn autocommit_conflict_counts_as_unpublished() {
        let log = "2026-08-23 18:21 PUBLISHED: aaa on origin\n\
                   2026-08-23 18:36 CONFLICT: vault/Inbox/Today.md\n";
        let l = parse_autocommit_tail(log).unwrap();
        assert!(!l.published);
        // Trailing chatter after the status line must not be mistaken for the status.
        let noisy = format!("{log}warning: gc ran long\n");
        assert!(!parse_autocommit_tail(&noisy).unwrap().published);
        assert!(parse_autocommit_tail("nothing here\n").is_none());
    }

    #[test]
    fn ahead_behind_parses_the_tab_separated_counts() {
        // `--left-right --count @{u}...HEAD` prints "<behind>\t<ahead>".
        assert_eq!(parse_ahead_behind("3\t7\n"), Some((7, 3)));
        assert_eq!(parse_ahead_behind("0\t0\n"), Some((0, 0)));
        assert_eq!(parse_ahead_behind(""), None);
        assert_eq!(parse_ahead_behind("fatal: no upstream\n"), None);
    }

    #[test]
    fn ledger_tail_keeps_the_last_n_and_never_drops_garbage() {
        let mut text = String::new();
        for i in 0..30 {
            text.push_str(&format!(
                r#"{{"at_ms":{},"job":"nightly","outcome":"fired"}}"#,
                1000 + i
            ));
            text.push('\n');
        }
        text.push_str("half a line, not json\n");
        let tail = parse_ledger_tail(&text, 20);
        assert_eq!(tail.len(), 20);
        // The unparseable final line is KEPT, as `{raw: …}` — a ledger emitting garbage is
        // something to see on the status page, not something to quietly filter out.
        assert_eq!(tail[19]["raw"], json!("half a line, not json"));
        assert_eq!(tail[0]["at_ms"], json!(1011));
        assert!(parse_ledger_tail("", 20).is_empty());
    }

    #[test]
    fn last_fired_ignores_every_other_outcome() {
        let lines = vec![
            json!({"at_ms": 500, "outcome": "fired"}),
            json!({"at_ms": 900, "outcome": "day-skipped"}),
            json!({"at_ms": 800, "outcome": "failed"}),
            json!({"at_ms": 950, "outcome": "fired-no-output"}),
            json!({"at_ms": 700, "outcome": "fired"}),
        ];
        // The newest `fired` is 700 — a later skip or failure is not a fire, and neither is
        // `fired-no-output`, which the bridge escalates on its own terms.
        assert_eq!(last_fired_ms(&lines), Some(700));
        assert_eq!(last_fired_ms(&[]), None);
        assert_eq!(
            last_fired_ms(&[json!({"outcome": "fired"})]),
            None,
            "a fired line with no timestamp cannot date the last fire"
        );
    }

    #[test]
    fn tail_bytes_drops_the_partial_first_line() {
        let dir = std::env::temp_dir().join(format!("jesse-sentinel-tail-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("log");
        std::fs::write(&path, "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n").unwrap();
        // A window that lands mid-line must not hand a caller half a record.
        let tail = tail_bytes(&path, 16).unwrap();
        assert_eq!(tail, "cccccccccc\n");
        // A window larger than the file returns all of it, first line intact.
        assert_eq!(
            tail_bytes(&path, 4096).unwrap(),
            "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n"
        );
        assert!(tail_bytes(&dir.join("nope"), 4096).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dir_size_sums_files_and_reports_a_truncated_walk() {
        let dir = std::env::temp_dir().join(format!("jesse-sentinel-walk-{}", random_hex()));
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        std::fs::write(dir.join("a/one"), b"12345").unwrap();
        std::fs::write(dir.join("a/b/two"), b"1234567890").unwrap();
        let (bytes, files, complete) = dir_size(&dir, MAX_WALK_ENTRIES);
        assert_eq!(bytes, 15);
        assert_eq!(files, 2);
        assert!(complete);
        // A cap short of the tree says so rather than under-reporting the store as small.
        let (_, _, complete) = dir_size(&dir, 1);
        assert!(!complete);
        // An absent directory is zero, not an error — a deploy with no artifact store yet.
        assert_eq!(dir_size(&dir.join("nope"), 10), (0, 0, true));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn probe_json_is_a_tristate() {
        assert_eq!(Probe::ok(json!({"a":1})).to_json()["ok"], json!(true));
        assert_eq!(
            Probe::failed(json!(null), "boom").to_json()["ok"],
            json!(false)
        );
        let u = Probe::unknown("timed out").to_json();
        // `null`, not `false`: "I could not find out" must never render as "it is broken".
        assert_eq!(u["ok"], Value::Null);
        assert_eq!(u["state"], json!("unknown"));
        assert_eq!(u["error"], json!("timed out"));
    }

    #[tokio::test]
    async fn timed_degrades_a_hung_probe_to_unknown() {
        let hung = async {
            tokio::time::sleep(Duration::from_secs(3600)).await;
            Probe::ok(json!("never"))
        };
        let p = timed_within("stuck", Duration::from_millis(20), hung).await;
        // A probe that never answers must render as `unknown`, not as a failure and
        // certainly not as a hung request.
        assert_eq!(p.state, ProbeState::Unknown);
        assert!(p.error.unwrap().contains("did not finish"));
        // A probe that answers inside its ceiling is untouched by the wrapper.
        let quick = timed_within("quick", Duration::from_secs(5), async {
            Probe::ok(json!(1))
        });
        assert_eq!(quick.await.state, ProbeState::Ok);
    }
}
