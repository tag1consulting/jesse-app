use super::*;

// ---- The verb table ---------------------------------------------------------------
//
// Everything that CHANGES the host lives here, and the shape is the same every time: a fixed
// operation with named arguments, a bounded wait, and a JSON answer that says what happened.
// There is no verb that takes a command, a path, or a shell string — the only caller-supplied
// value that reaches any external process is a `[[schedule]]` id, and it is checked against
// the bridge's own schedule before it is forwarded.
//
// Every verb here assumes its caller has already passed the bearer check, the rate limiter
// and the single-flight lock (see `http.rs`), and that its outcome will be audited.

/// How long the unlock verb requires an `index.lock` to have been sitting there. Below this
/// the lock is presumed live: git takes and releases it in milliseconds, and the vault has a
/// dedicated reaper on a 180 s interval for the rest.
pub const LOCK_MIN_AGE_SECS: u64 = 180;

/// Artifact directories older than this are what the prune verb deletes.
pub const ARTIFACT_PRUNE_DAYS: u64 = 7;

/// The outcome of a verb: the JSON body and the HTTP status.
pub type VerbResult = Result<(StatusCode, Value), (StatusCode, Value)>;

/// Poll the bridge's `/health` until it answers or the window closes.
///
/// Returns `(healthy, version)`. A restart that does not come back inside the window is
/// reported as `healthy: false` and NOT as a failed restart: the kickstart happened, and
/// conflating "I could not restart it" with "I restarted it and it did not come back" would
/// send an operator looking in the wrong place.
async fn poll_health(sen: &Sentinel, window: Duration) -> (bool, Option<String>) {
    let deadline = Instant::now() + window;
    loop {
        if let Ok((status, body)) = sen.bridge_get("/health", Duration::from_secs(3)).await {
            if (200..300).contains(&status) {
                let version = body
                    .get("version")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                return (true, version);
            }
        }
        if Instant::now() >= deadline {
            return (false, None);
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// `POST /sentinel/restart/{service}` — `launchctl kickstart -k gui/<uid>/<label>`.
///
/// `-k` kills the running instance first, which is what makes this a restart rather than a
/// "start it if it is not running". For the BRIDGE the verb then polls `/health`, because
/// "the kickstart returned 0" and "the bridge is answering again" are different claims and
/// only the second one is what the operator wanted to know.
pub async fn verb_restart(sen: &Sentinel, slot: ServiceSlot) -> VerbResult {
    let target = sen.cfg.target(slot);
    let res = run_cmd(
        sen.cfg.bins.launchctl.as_ref(),
        &["kickstart", "-k", &target],
        &[],
        RESTART_TIMEOUT,
    )
    .await;
    if !res.ok() {
        return Err((
            StatusCode::BAD_GATEWAY,
            json!({
                "service": slot.slug(),
                "label": sen.cfg.label(slot),
                "restarted": false,
                "error": res.summary(),
            }),
        ));
    }
    let mut body = json!({
        "service": slot.slug(),
        "label": sen.cfg.label(slot),
        "restarted": true,
    });
    if slot == ServiceSlot::Bridge {
        let (healthy, version) = poll_health(sen, HEALTH_POLL_TIMEOUT).await;
        body["healthy"] = json!(healthy);
        body["version"] = json!(version);
    }
    Ok((StatusCode::OK, body))
}

/// `POST /sentinel/bridge/reload-env` — `bootout` then `bootstrap`, then the health poll.
///
/// THIS IS THE ONLY WAY A PLIST ENVIRONMENT CHANGE TAKES EFFECT. `kickstart -k` re-execs the
/// job inside its existing launchd service record, so it comes back with the OLD
/// `EnvironmentVariables` — a fact that has cost this deployment a debugging session more
/// than once. Tearing the record down and bootstrapping it again is what makes launchd
/// re-read the file.
///
/// The `bootout` is allowed to fail: a job that is not currently loaded boots out with a
/// non-zero status, and refusing to bootstrap in that case would leave the bridge down when
/// the whole point of the verb is to bring it up on a new environment. The `bootstrap` is
/// the step whose failure matters.
pub async fn verb_reload_env(sen: &Sentinel) -> VerbResult {
    let Some(plist) = sen.cfg.bridge_plist.clone() else {
        return Err((
            StatusCode::PRECONDITION_FAILED,
            json!({
                "error": "JESSE_SENTINEL_BRIDGE_PLIST is not set, so there is no file to \
                          bootstrap the bridge from",
            }),
        ));
    };
    if !plist.is_file() {
        return Err((
            StatusCode::PRECONDITION_FAILED,
            json!({ "error": format!("bridge plist not found: {}", plist.display()) }),
        ));
    }
    let target = sen.cfg.target(ServiceSlot::Bridge);
    let domain = format!("gui/{}", sen.cfg.uid);
    let plist_arg = plist.to_string_lossy().to_string();

    let out = run_cmd(
        sen.cfg.bins.launchctl.as_ref(),
        &["bootout", &target],
        &[],
        RESTART_TIMEOUT,
    )
    .await;
    let booted_out = out.ok();
    let boot_in = run_cmd(
        sen.cfg.bins.launchctl.as_ref(),
        &["bootstrap", &domain, &plist_arg],
        &[],
        RESTART_TIMEOUT,
    )
    .await;
    if !boot_in.ok() {
        return Err((
            StatusCode::BAD_GATEWAY,
            json!({
                "booted_out": booted_out,
                "bootstrapped": false,
                "plist": plist_arg,
                // The bootout's own summary is carried even when it "failed", because
                // "was not loaded" is the usual reason and it explains the sequence.
                "bootout": out.summary(),
                "error": boot_in.summary(),
            }),
        ));
    }
    let (healthy, version) = poll_health(sen, HEALTH_POLL_TIMEOUT).await;
    Ok((
        StatusCode::OK,
        json!({
            "booted_out": booted_out,
            "bootstrapped": true,
            "plist": plist_arg,
            "healthy": healthy,
            "version": version,
        }),
    ))
}

/// `POST /sentinel/git/unlock` — remove a STALE `.git/index.lock`, then kick the autocommit.
///
/// Two conditions, both required, because deleting a LIVE index lock corrupts whatever git
/// is holding it: the file must be older than [`LOCK_MIN_AGE_SECS`], and `pgrep -u <uid> -x
/// git` must find no git process at all. Either condition failing is a 409 that says which
/// one — a refusal an operator can act on beats a silent no-op every time.
///
/// `pgrep` exiting 1 means "no match", which is the case we want; any OTHER failure (the
/// binary is missing, it timed out) is treated as "cannot prove no git is running" and
/// refuses. Deleting the lock on the strength of a probe that did not work is exactly the
/// shortcut that turns a stuck commit into a broken repository.
pub async fn verb_git_unlock(sen: &Sentinel) -> VerbResult {
    let lock = sen.cfg.index_lock();
    let Some(age) = file_age_secs(&lock) else {
        return Err((
            StatusCode::CONFLICT,
            json!({ "removed": false, "reason": "no index.lock present", "lock": lock.to_string_lossy() }),
        ));
    };
    if age < LOCK_MIN_AGE_SECS {
        return Err((
            StatusCode::CONFLICT,
            json!({
                "removed": false,
                "reason": format!("index.lock is {age}s old — under the {LOCK_MIN_AGE_SECS}s \
                                   floor, so it is presumed live"),
                "age_secs": age,
            }),
        ));
    }
    let uid = sen.cfg.uid.to_string();
    let pg = run_cmd(
        sen.cfg.bins.pgrep.as_ref(),
        &["-u", &uid, "-x", "git"],
        &[],
        PROBE_TIMEOUT,
    )
    .await;
    match pg.code {
        // 1 == no process matched. This is the only outcome that permits the delete.
        Some(1) => {}
        Some(0) => {
            return Err((
                StatusCode::CONFLICT,
                json!({
                    "removed": false,
                    "reason": "a git process is running for this user — the lock is live",
                    "pids": pg.stdout.split_whitespace().collect::<Vec<_>>(),
                    "age_secs": age,
                }),
            ))
        }
        _ => {
            return Err((
                StatusCode::CONFLICT,
                json!({
                    "removed": false,
                    "reason": format!("could not prove no git process is running ({}) — \
                                       refusing to remove a lock that may be live", pg.summary()),
                    "age_secs": age,
                }),
            ))
        }
    }
    if let Err(e) = std::fs::remove_file(&lock) {
        return Err((
            StatusCode::BAD_GATEWAY,
            json!({ "removed": false, "reason": format!("could not remove {}: {e}", lock.display()) }),
        ));
    }
    // The autocommit runs every 15 minutes; kicking it means the vault publishes now rather
    // than at the next interval, which is the difference the operator pressed the button for.
    let kick = run_cmd(
        sen.cfg.bins.launchctl.as_ref(),
        &["kickstart", "-k", &sen.cfg.target(ServiceSlot::Autocommit)],
        &[],
        RESTART_TIMEOUT,
    )
    .await;
    sen.state.lock_ok().last_unlock_ms = Some(now_ms());
    sen.persist_state();
    Ok((
        StatusCode::OK,
        json!({
            "removed": true,
            "age_secs": age,
            "lock": lock.to_string_lossy(),
            "autocommit_kickstarted": kick.ok(),
            "autocommit_error": (!kick.ok()).then(|| kick.summary()),
        }),
    ))
}

/// `POST /sentinel/artifacts/prune` — delete artifact directories older than seven days.
///
/// Scoped to the IMMEDIATE children of `<bridge state dir>/artifacts` and to directories:
/// the store's layout is one directory per artifact, and a verb that recursed into arbitrary
/// depth or deleted loose files would be a delete-by-pattern rather than a fixed operation.
/// A symlink is skipped outright — following one out of the store is the one way this verb
/// could delete something that is not an artifact.
pub async fn verb_prune_artifacts(sen: &Sentinel) -> VerbResult {
    let root = sen.cfg.artifacts_dir();
    let cutoff = Duration::from_secs(ARTIFACT_PRUNE_DAYS * 24 * 3600);
    let entries = match std::fs::read_dir(&root) {
        Ok(e) => e,
        Err(e) => {
            return Err((
                StatusCode::PRECONDITION_FAILED,
                json!({ "error": format!("cannot read {}: {e}", root.display()) }),
            ))
        }
    };
    let mut freed = 0u64;
    let mut removed = Vec::new();
    let mut errors = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        // `symlink_metadata` does not follow the link, so a symlink is seen as a symlink and
        // skipped rather than resolved to whatever it points at.
        let Ok(md) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !md.is_dir() {
            continue;
        }
        let Ok(modified) = md.modified() else {
            continue;
        };
        let Ok(age) = SystemTime::now().duration_since(modified) else {
            continue;
        };
        if age < cutoff {
            continue;
        }
        let (bytes, _, _) = dir_size(&path, MAX_WALK_ENTRIES);
        match std::fs::remove_dir_all(&path) {
            Ok(()) => {
                freed += bytes;
                removed.push(entry.file_name().to_string_lossy().to_string());
            }
            Err(e) => errors.push(format!("{}: {e}", path.display())),
        }
    }
    Ok((
        StatusCode::OK,
        json!({
            "root": root.to_string_lossy(),
            "older_than_days": ARTIFACT_PRUNE_DAYS,
            "removed": removed.len(),
            "removed_ids": removed,
            "bytes_freed": freed,
            "errors": errors,
        }),
    ))
}

/// The two proxy verbs, named so the audit line and the route table agree.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum JobVerb {
    Fire,
    Enable,
}

impl JobVerb {
    pub fn path(self, id: &str) -> String {
        match self {
            JobVerb::Fire => format!("/jesse/schedule/{id}/fire"),
            JobVerb::Enable => format!("/jesse/schedule/{id}/enable"),
        }
    }
}

/// Whether `id` is safe to place in a URL path at all.
///
/// This runs BEFORE the schedule is consulted, and it exists so a hostile id cannot reach the
/// bridge's router as `../../something` even in the window where the schedule lookup is
/// unavailable. The bridge's own ids are config-file identifiers; this is the same alphabet
/// the bridge already validates request ids against.
pub fn validate_schedule_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `POST /sentinel/jobs/{id}/fire` and `/enable` — forward to the bridge's own control verbs.
///
/// THE ID IS VALIDATED AGAINST THE LIVE SCHEDULE FIRST, and nothing else from the request
/// reaches the bridge except the parsed body of the verb's own shape. That is the whole
/// containment story for the proxy: the sentinel cannot be used to reach an endpoint of the
/// bridge that is not one of these two, with an argument that is not a schedule id the bridge
/// already knows.
pub async fn verb_job(sen: &Sentinel, verb: JobVerb, id: &str, body: Value) -> VerbResult {
    if !validate_schedule_id(id) {
        return Err((
            StatusCode::BAD_REQUEST,
            json!({ "error": "a schedule id is 1-64 chars of [A-Za-z0-9_-]" }),
        ));
    }
    let (status, schedule) = sen
        .bridge_get("/jesse/schedule", PROBE_TIMEOUT)
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                json!({ "error": format!("could not read the bridge's schedule: {e}") }),
            )
        })?;
    if !(200..300).contains(&status) {
        return Err((
            StatusCode::BAD_GATEWAY,
            json!({ "error": format!("bridge /jesse/schedule returned {status}") }),
        ));
    }
    let known = schedule
        .get("jobs")
        .and_then(Value::as_array)
        .map(|jobs| {
            jobs.iter()
                .any(|j| j.get("id").and_then(Value::as_str) == Some(id))
        })
        .unwrap_or(false);
    if !known {
        return Err((
            StatusCode::NOT_FOUND,
            json!({ "error": format!("no [[schedule]] entry with id {id:?}") }),
        ));
    }
    let (status, reply) = sen
        .bridge_post(&verb.path(id), &body, RESTART_TIMEOUT)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, json!({ "error": e })))?;
    let code = StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY);
    let out = json!({ "bridge_status": status, "bridge_body": reply });
    // The bridge's own status is passed through: a 409 "that chain is already running" is
    // the answer, and rewriting it to 200 would hide it.
    if code.is_success() {
        Ok((code, out))
    } else {
        Err((code, out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_id_alphabet_is_closed() {
        assert!(validate_schedule_id("nightly"));
        assert!(validate_schedule_id("morning-routine_2"));
        assert!(validate_schedule_id(&"a".repeat(64)));
        assert!(!validate_schedule_id(""));
        assert!(!validate_schedule_id(&"a".repeat(65)));
        // The shapes that would matter if this ever reached a URL or a shell.
        assert!(!validate_schedule_id("../../etc/passwd"));
        assert!(!validate_schedule_id("a/b"));
        assert!(!validate_schedule_id("a b"));
        assert!(!validate_schedule_id("a?x=1"));
        assert!(!validate_schedule_id("café"));
    }

    #[test]
    fn job_verb_paths_are_the_bridge_routes() {
        assert_eq!(
            JobVerb::Fire.path("nightly"),
            "/jesse/schedule/nightly/fire"
        );
        assert_eq!(
            JobVerb::Enable.path("nightly"),
            "/jesse/schedule/nightly/enable"
        );
    }
}
