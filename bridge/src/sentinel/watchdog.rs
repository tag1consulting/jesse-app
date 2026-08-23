use super::*;

// ---- The watchdog ------------------------------------------------------------------
//
// One task, one 60 s tick, seven rules. This is the half of the sentinel that works when
// nobody is looking, and every rule here was written to the same two constraints:
//
//   * FIX AT MOST ONE CLASS OF THING, AND SAY SO. The watchdog restarts a dead bridge,
//     clears a provably-stale lock, prunes an over-full artifact store, and brings the
//     tailnet back up. It does NOT resolve a git conflict, does not touch the vault's
//     contents, and does not repair `qmd` — those need a decision, and a process with no
//     model has no business making one. For those it pushes and stops.
//
//   * NEVER LOOP. Every automatic action is bounded: the bridge restart by a rolling-hour
//     budget, `tailscale up` by once per outage, and every alert by a per-kind dedupe
//     window. A watchdog that can restart something forever is a worse outage than the one
//     it is responding to.
//
// The state behind all of that is persisted after every tick (see `state.rs`), so a sentinel
// that is itself restarted does not forget that it had already given up.
//
// EVERY MUTATING ACTION HERE TAKES `verb_lock`, the same single-flight permit the HTTP verbs
// take. The probes do not — they are reads, and holding the lock across a five-second probe
// would make the watchdog block every operator button for a second at a time. What must never
// overlap is two things CHANGING the host at once.

/// Autocommit must be stuck for this long before it is worth waking someone. Runs are 15
/// minutes apart and a single `UNPUBLISHED:` is ordinary (nothing to push, a momentary
/// network blip); two hours of them is a vault that is no longer reaching its remote.
pub const AUTOCOMMIT_STUCK_MS: u64 = 2 * HOUR_MS;

/// …and once told, not again for half a day.
pub const AUTOCOMMIT_PUSH_WINDOW_MS: u64 = 12 * HOUR_MS;

/// The watchdog's own staleness floor for `index.lock`, well above the unlock verb's 180 s:
/// the vault has a dedicated reaper on a 180 s interval, so anything the watchdog acts on
/// has already survived several of its passes.
pub const LOCK_STALE_MS: u64 = 10 * 60 * 1000;

/// A tailnet blip is not an outage. Five minutes offline is.
pub const TAILSCALE_DOWN_MS: u64 = 5 * 60 * 1000;

/// `qmd` failing is a search index that is quietly wrong; it needs a human and a Node
/// version, and there is nothing to gain from saying so more than once a day.
pub const QMD_PUSH_WINDOW_MS: u64 = 24 * HOUR_MS;

/// The overnight chain is the longest gap between two ordinary fires, so 26 hours is "a
/// whole day has passed and the scheduler produced nothing" with room for a late run.
pub const SILENCE_MS: u64 = 26 * HOUR_MS;

/// …reported at most once a day, because the condition it describes persists.
pub const SILENCE_PUSH_WINDOW_MS: u64 = 24 * HOUR_MS;

/// The APNs payload for one sentinel alert.
///
/// Deliberately NOT `build_apns_payload`: that one carries a `job_id` and deep-links the tap
/// into a finished turn, and a sentinel alert has no turn behind it. The `sentinel.kind`
/// field is the machine-readable half, so the app can route "the bridge is down" differently
/// from "the disk is full" without parsing English.
pub fn build_sentinel_payload(kind: AlertKind, body: &str) -> Vec<u8> {
    // A lock screen shows a line, not a paragraph, and APNs caps the payload at 4 KB. The
    // text is also the only field here that could carry a command's stderr, so it is
    // stripped of control characters on the way out.
    let body: String = body
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_PUSH_REASON_CHARS)
        .collect();
    json!({
        "aps": {
            "alert": { "title": "Jesse sentinel", "body": body },
            "sound": "default"
        },
        "sentinel": { "kind": kind.key() }
    })
    .to_string()
    .into_bytes()
}

/// Send one alert, if its dedupe window has elapsed. Returns whether anything was sent.
///
/// The device token is re-read from the BRIDGE's `device.json` on every push rather than
/// cached: the phone re-registers on foreground, and a sentinel holding a token from three
/// weeks ago would be pushing into the void on precisely the trip this exists for. The file
/// is read-only here — a 410 is logged, never written back, because the bridge owns that
/// record and clearing it from two processes is how it gets lost.
pub async fn push_alert(sen: &Sentinel, kind: AlertKind, window_ms: u64, body: &str) -> bool {
    let now = now_ms();
    if !sen.state.lock_ok().allow_push(kind, now, window_ms) {
        return false;
    }
    // The dedupe was recorded above, so persist it even if the send fails: a push that
    // cannot be delivered must not retry every 60 seconds.
    sen.persist_state();
    let Some(apns) = sen.apns.as_deref() else {
        eprintln!(
            "jesse-sentinel: ALERT {} — {body} (push is not configured, nothing sent)",
            kind.key()
        );
        return false;
    };
    let Some(token) = load_device_token(&sen.cfg.device_json) else {
        eprintln!(
            "jesse-sentinel: ALERT {} — {body} (no device registered with the bridge, \
             nothing sent)",
            kind.key()
        );
        return false;
    };
    match apns
        .push_payload(&token, build_sentinel_payload(kind, body))
        .await
    {
        PushOutcome::Sent => {
            eprintln!("jesse-sentinel: ALERT {} sent — {body}", kind.key());
            true
        }
        PushOutcome::DeadToken => {
            eprintln!(
                "jesse-sentinel: ALERT {} — the bridge's device token is dead (410). NOT \
                 cleared here: device.json belongs to the bridge, which clears it on its own \
                 next push. The phone must re-register.",
                kind.key()
            );
            false
        }
        PushOutcome::Failed(e) => {
            eprintln!(
                "jesse-sentinel: ALERT {} failed: {e} — swallowed",
                kind.key()
            );
            false
        }
    }
}

/// RULE 1 — the bridge is not answering.
///
/// Three consecutive misses (three minutes) before the first kickstart, and at most five
/// kickstarts in a rolling hour. Past that the watchdog STOPS and says so: a bridge that has
/// died five times in an hour is not going to be fixed by a sixth restart, and continuing
/// would overwrite the crash it is dying from with a fresh boot every twelve minutes.
///
/// The misses counter resets on every kickstart, so the next one is three ticks away rather
/// than immediate; the budget is a ROLLING hour, so once the oldest attempt ages out the
/// watchdog is free to try again — which is what "retry once per hour" means here.
async fn check_bridge(sen: &Arc<Sentinel>, now: u64) {
    let probe = timed("bridge", probe_bridge(sen)).await;
    if probe.state == ProbeState::Ok {
        let mut st = sen.state.lock_ok();
        if st.bridge_gave_up_ms.is_some() {
            eprintln!("jesse-sentinel: watchdog — the bridge is answering again");
        }
        st.bridge_misses = 0;
        st.bridge_gave_up_ms = None;
        st.bridge_last_error = None;
        // A recovered bridge re-arms the alert: the NEXT outage must be reported even if
        // this one was reported an hour ago.
        st.last_push_ms.remove(AlertKind::BridgeDown.key());
        return;
    }
    let error = probe
        .error
        .clone()
        .unwrap_or_else(|| "unreachable".to_string());
    let (should_kickstart, spent) = {
        let mut st = sen.state.lock_ok();
        st.bridge_misses = st.bridge_misses.saturating_add(1);
        st.bridge_last_error = Some(error.clone());
        st.prune_kickstarts(now);
        let due = st.bridge_misses >= BRIDGE_MISSES_BEFORE_KICKSTART;
        let spent = st.budget_spent(now);
        if due && !spent {
            st.bridge_misses = 0;
            st.note_kickstart(now);
        }
        if due && spent && st.bridge_gave_up_ms.is_none() {
            st.bridge_gave_up_ms = Some(now);
        }
        (due && !spent, spent)
    };
    if should_kickstart {
        let target = sen.cfg.target(ServiceSlot::Bridge);
        // SINGLE FLIGHT, the same lock the HTTP verbs take. An operator pressing
        // `restart/bridge` while the watchdog is mid-kickstart is exactly the double
        // restart that lock exists to prevent, and a watchdog that ignored it would be the
        // one caller able to cause it. It WAITS rather than skipping: a tick that arrives
        // during a 90 s `reload-env` should act after it, not decide the bridge is fine.
        let _permit = sen.verb_lock.lock().await;
        let out = run_cmd(
            sen.cfg.bins.launchctl.as_ref(),
            &["kickstart", "-k", &target],
            &[],
            RESTART_TIMEOUT,
        )
        .await;
        sen.audit(
            "watchdog",
            "restart/bridge",
            &format!(
                "{} (after {BRIDGE_MISSES_BEFORE_KICKSTART} missed health checks: {error})",
                out.summary()
            ),
        );
        sen.persist_state();
        return;
    }
    if spent {
        let body = format!(
            "bridge keeps dying, stopped restarting it; last error {}",
            error
        );
        push_alert(sen, AlertKind::BridgeDown, HOUR_MS, &body).await;
    }
}

/// RULE 2 — the vault is no longer reaching its remote.
///
/// NEVER RESOLVES A CONFLICT. A conflicted autocommit means two versions of a note exist and
/// only the owner knows which one is right; the single worst thing a model-free process could
/// do here is pick one. It reports, and it reports rarely.
async fn check_autocommit(sen: &Arc<Sentinel>, now: u64) {
    let Some(log) = sen.cfg.autocommit_log.clone() else {
        return;
    };
    let Ok(text) = tail_bytes(&log, TAIL_WINDOW_BYTES) else {
        return;
    };
    let Some(last) = parse_autocommit_tail(&text) else {
        return;
    };
    if last.published {
        let mut st = sen.state.lock_ok();
        st.autocommit_bad_since_ms = None;
        st.last_push_ms.remove(AlertKind::Autocommit.key());
        return;
    }
    let stuck_for = {
        let mut st = sen.state.lock_ok();
        let since = *st.autocommit_bad_since_ms.get_or_insert(now);
        now.saturating_sub(since)
    };
    sen.persist_state();
    if stuck_for >= AUTOCOMMIT_STUCK_MS {
        let body = format!(
            "the vault has not published for {}h — {}",
            stuck_for / HOUR_MS,
            last.line
        );
        push_alert(sen, AlertKind::Autocommit, AUTOCOMMIT_PUSH_WINDOW_MS, &body).await;
    }
}

/// RULE 3 — a stale `.git/index.lock`.
///
/// Runs the SAME verb an operator would press, so there is one implementation of "is this
/// lock safe to remove" and it refuses on a live git process either way. A recurrence inside
/// the hour is pushed: one stale lock is the reaper being slow, two in an hour is something
/// leaving locks behind and no amount of clearing will fix that.
async fn check_lock(sen: &Arc<Sentinel>, now: u64) {
    let Some(age) = file_age_secs(&sen.cfg.index_lock()) else {
        return;
    };
    if age * 1000 < LOCK_STALE_MS {
        return;
    }
    let previous = sen.state.lock_ok().last_unlock_ms;
    let result = {
        let _permit = sen.verb_lock.lock().await;
        verb_git_unlock(sen).await
    };
    let recurrence = previous.is_some_and(|t| now.saturating_sub(t) < HOUR_MS);
    match result {
        Ok(_) => {
            sen.audit("watchdog", "git/unlock", &format!("removed (age {age}s)"));
            if recurrence {
                push_alert(
                    sen,
                    AlertKind::Lock,
                    HOUR_MS,
                    "a stale git index.lock came back within the hour — something is leaving \
                     locks behind in the vault",
                )
                .await;
            }
        }
        Err((_, body)) => {
            // A refusal is the verb working: a live git process holds the lock, and the next
            // tick will look again.
            let reason = body
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("refused");
            sen.audit("watchdog", "git/unlock", &format!("refused: {reason}"));
        }
    }
}

/// RULE 4 — the disk is filling.
///
/// Prune first, re-measure, and only then wake anyone: the artifact store is the one thing
/// on this box that grows without bound and is safe to delete, so a disk alert that could
/// have been solved by a prune is an alert nobody needed.
async fn check_disk(sen: &Arc<Sentinel>, _now: u64) {
    let before = timed("disk", probe_disk(sen)).await;
    if before.state != ProbeState::Failed {
        return;
    }
    let free_before = before.detail.get("free_bytes_min").and_then(Value::as_u64);
    // Only the free-space failure is actionable here; a `df` that would not run is reported
    // by the status page, not fixed by deleting things.
    if free_before.is_none_or(|f| f >= DISK_FLOOR_BYTES) {
        return;
    }
    let pruned = {
        let _permit = sen.verb_lock.lock().await;
        verb_prune_artifacts(sen).await
    };
    let freed = match &pruned {
        Ok((_, body)) => body.get("bytes_freed").and_then(Value::as_u64).unwrap_or(0),
        Err(_) => 0,
    };
    sen.audit(
        "watchdog",
        "artifacts/prune",
        &format!("freed {} MB", freed / (1024 * 1024)),
    );
    let after = timed("disk", probe_disk(sen)).await;
    let free_after = after.detail.get("free_bytes_min").and_then(Value::as_u64);
    if free_after.is_none_or(|f| f < DISK_FLOOR_BYTES) {
        let body = format!(
            "disk is low — {} MB free after pruning {} MB of artifacts",
            free_after.unwrap_or(0) / (1024 * 1024),
            freed / (1024 * 1024)
        );
        push_alert(sen, AlertKind::Disk, HOUR_MS, &body).await;
    }
}

/// RULE 5 — the tailnet is offline.
///
/// `tailscale up` ONCE per outage. Repeating it would neither help nor be free: on a Mac it
/// can raise an interactive login flow, and a background process re-triggering that every
/// minute is worse than being offline.
async fn check_tailscale(sen: &Arc<Sentinel>, now: u64) {
    let probe = timed("tailscale", probe_tailscale(sen)).await;
    let online = probe
        .detail
        .get("online")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if online {
        let mut st = sen.state.lock_ok();
        st.tailscale_down_since_ms = None;
        st.tailscale_up_ms = None;
        st.last_push_ms.remove(AlertKind::Tailscale.key());
        return;
    }
    // `unknown` (the probe timed out, or tailscale is not installed) is NOT an outage.
    // Running `tailscale up` because a probe hung would be acting on nothing.
    if probe.state == ProbeState::Unknown {
        return;
    }
    let (down_for, already_tried) = {
        let mut st = sen.state.lock_ok();
        let since = *st.tailscale_down_since_ms.get_or_insert(now);
        (now.saturating_sub(since), st.tailscale_up_ms.is_some())
    };
    sen.persist_state();
    if down_for < TAILSCALE_DOWN_MS || already_tried {
        return;
    }
    let out = {
        let _permit = sen.verb_lock.lock().await;
        run_cmd(
            sen.cfg.bins.tailscale.as_ref(),
            &["up"],
            &[],
            RESTART_TIMEOUT,
        )
        .await
    };
    sen.state.lock_ok().tailscale_up_ms = Some(now);
    sen.persist_state();
    sen.audit("watchdog", "tailscale/up", &out.summary());
    let body = format!(
        "the tailnet has been offline for {} min — ran `tailscale up` ({})",
        down_for / 60_000,
        out.summary()
    );
    push_alert(sen, AlertKind::Tailscale, HOUR_MS, &body).await;
}

/// RULE 6 — `qmd` is broken.
///
/// NO AUTO-FIX, by design. The failure this catches is a Node ABI mismatch
/// (`ERR_DLOPEN_FAILED`), whose repair is choosing a Node version — a decision, on a machine
/// where two of them are installed for good reasons. The alert names the first line of
/// stderr, which is the whole diagnosis.
async fn check_qmd(sen: &Arc<Sentinel>, _now: u64) {
    let probe = timed("qmd", probe_qmd(sen)).await;
    if probe.state != ProbeState::Failed {
        return;
    }
    let detail = probe
        .detail
        .get("first_stderr_line")
        .and_then(Value::as_str)
        .unwrap_or("no stderr");
    let body = format!("qmd status is failing — {detail}");
    push_alert(sen, AlertKind::Qmd, QMD_PUSH_WINDOW_MS, &body).await;
}

/// RULE 7 — nothing has fired.
///
/// The one rule that watches for an ABSENCE, and the reason it exists: every other alarm
/// here fires when something goes wrong, and a scheduler that has quietly stopped producing
/// occurrences goes wrong by producing nothing at all. An empty ledger counts as silence
/// only once the sentinel has been up long enough to have seen a fire — a freshly installed
/// sentinel must not announce that nothing has run in 26 hours.
async fn check_silence(sen: &Arc<Sentinel>, now: u64) {
    let Ok(text) = tail_bytes(&sen.cfg.ledger, TAIL_WINDOW_BYTES) else {
        return;
    };
    let lines = parse_ledger_tail(&text, LEDGER_TAIL_LINES.max(200));
    let Some(last) = last_fired_ms(&lines) else {
        return;
    };
    let quiet = now.saturating_sub(last);
    if quiet < SILENCE_MS {
        return;
    }
    let body = format!("no scheduled job has fired in {} h", quiet / HOUR_MS);
    push_alert(sen, AlertKind::Silence, SILENCE_PUSH_WINDOW_MS, &body).await;
}

/// ONE tick. Public so the integration test can drive the watchdog deterministically rather
/// than waiting out sixty-second sleeps — the rules are stated over ticks, so a test that
/// counts ticks is testing exactly what was specified.
pub async fn tick(sen: &Arc<Sentinel>) {
    let now = now_ms();
    check_bridge(sen, now).await;
    check_autocommit(sen, now).await;
    check_lock(sen, now).await;
    check_disk(sen, now).await;
    check_tailscale(sen, now).await;
    check_qmd(sen, now).await;
    check_silence(sen, now).await;
    sen.state.lock_ok().last_tick_ms = Some(now);
    sen.persist_state();
}

/// The watchdog task. One tick, then sleep — never a fixed-rate timer, so a tick that took
/// forty seconds does not immediately start another.
pub fn spawn_watchdog(sen: Arc<Sentinel>) {
    tokio::spawn(async move {
        loop {
            tick(&sen).await;
            tokio::time::sleep(WATCHDOG_TICK).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentinel_payload_is_the_documented_shape() {
        let bytes = build_sentinel_payload(AlertKind::BridgeDown, "bridge keeps dying");
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["aps"]["alert"]["title"], json!("Jesse sentinel"));
        assert_eq!(v["aps"]["alert"]["body"], json!("bridge keeps dying"));
        assert_eq!(v["aps"]["sound"], json!("default"));
        assert_eq!(v["sentinel"]["kind"], json!("bridge-down"));
        // No `job_id`: a sentinel alert has no turn to deep-link into, and a client that
        // saw one would try to open a thread that does not exist.
        assert!(v.get("job_id").is_none());
    }

    #[test]
    fn payload_strips_control_characters_and_bounds_the_body() {
        // The body can carry a command's stderr, which reaches a lock screen.
        let bytes = build_sentinel_payload(AlertKind::Qmd, "boom\n\u{7}tail\r\nmore");
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["aps"]["alert"]["body"], json!("boomtailmore"));
        let long = build_sentinel_payload(AlertKind::Disk, &"x".repeat(1000));
        let v: Value = serde_json::from_slice(&long).unwrap();
        assert_eq!(
            v["aps"]["alert"]["body"].as_str().unwrap().len(),
            MAX_PUSH_REASON_CHARS
        );
    }

    #[test]
    fn every_alert_kind_renders_its_key() {
        for kind in ALERT_KINDS {
            let v: Value = serde_json::from_slice(&build_sentinel_payload(kind, "x")).unwrap();
            assert_eq!(v["sentinel"]["kind"], json!(kind.key()));
        }
    }
}
