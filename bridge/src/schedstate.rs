use crate::*;

// ---- The scheduler's persisted record ---------------------------------------
//
// One JSON file, `<state_dir>/schedule.json`, mapping a `[[schedule]]` id to what
// happened the last time it came due. It exists for two reasons, and the second is the
// whole point of the feature:
//
//   1. A RESTART MUST NOT DOUBLE FIRE. `last_due_ms` is the scheduled occurrence the job
//      last processed; the next fire is resolved strictly after it, so a bridge that
//      restarts at 02:31 does not run the 02:30 job again. Written when the occurrence is
//      CLAIMED, before any turn starts, so a crash mid-turn still cannot replay it.
//
//   2. A JOB THAT DID NOT RUN MUST SAY SO. Every due occurrence ends with an outcome —
//      ran, failed or skipped — and a skip always carries the reason. That record is what
//      `GET /jesse/schedule` reads, so "did the morning routine run today, and how long
//      did it take" is one authenticated request instead of an archaeology session over
//      file timestamps.
//
// Same discipline as the other small stores here (titles, flags, device): atomic
// temp+rename, mode 0600, best-effort — a write failure is logged, never fatal — and
// in-memory only when no state dir is configured. It holds ids, timestamps and reason
// strings; never a prompt, never a reply, never a secret.

/// How a scheduled occurrence ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    /// The turn ran and finished successfully.
    Ran,
    /// The turn ran and failed — or could not be started at all (an unreadable
    /// `prompt_file`, a rejected request). `reason` says which.
    Failed,
    /// No turn ran. `reason` ALWAYS says why: the catch-up window had expired, a previous
    /// run of the same id was still going, the chain's predecessor broke it, the day was
    /// not in `days`, or the job is disabled.
    Skipped,
}

impl Outcome {
    /// The wire/label form, as stored and as reported by the endpoint.
    pub fn label(self) -> &'static str {
        match self {
            Outcome::Ran => "ran",
            Outcome::Failed => "failed",
            Outcome::Skipped => "skipped",
        }
    }

    /// Whether this outcome lets an `after_on = "success"` chain continue.
    pub fn is_success(self) -> bool {
        matches!(self, Outcome::Ran)
    }

    fn parse(raw: &str) -> Option<Outcome> {
        match raw {
            "ran" => Some(Outcome::Ran),
            "failed" => Some(Outcome::Failed),
            "skipped" => Some(Outcome::Skipped),
            _ => None,
        }
    }
}

/// The persisted record for one schedule id. Every field is `#[serde(default)]` so a
/// file written by an older (or newer) bridge loads cleanly — a missing field is simply
/// "never happened" rather than a parse failure that would lose the whole schedule's
/// history.
#[derive(serde::Serialize, serde::Deserialize, Clone, Default, Debug, PartialEq)]
pub struct JobRecord {
    /// The scheduled occurrence this job last processed, unix millis. THE ANTI-DOUBLE-FIRE
    /// FIELD: the next fire is resolved strictly after it. Stamped for a skipped
    /// occurrence too — a skip is a decision about that occurrence, so it must not be
    /// reconsidered on the next tick.
    #[serde(default)]
    pub last_due_ms: Option<u64>,
    /// When a turn actually STARTED, unix millis. `None` when the last occurrence was
    /// skipped (nothing fired).
    #[serde(default)]
    pub last_fire_ms: Option<u64>,
    /// When the last occurrence reached its outcome, unix millis.
    #[serde(default)]
    pub last_completion_ms: Option<u64>,
    /// `"ran"` | `"failed"` | `"skipped"`; empty before the job has ever come due.
    #[serde(default)]
    pub last_outcome: String,
    /// Why, for a skip or a failure. Empty on a clean run.
    #[serde(default)]
    pub last_reason: String,
    /// Wall-clock duration of the last turn, milliseconds. `None` when nothing ran.
    #[serde(default)]
    pub last_duration_ms: Option<u64>,
    /// The job id of the last turn, so the turn itself can be fetched from
    /// `GET /jesse/result/{id}` (and so a push can deep-link to it). `None` when nothing
    /// ran.
    #[serde(default)]
    pub last_job_id: Option<String>,
    /// AN OCCURRENCE THAT IS STILL ELIGIBLE TO RUN, unix millis — set when a fire was
    /// skipped for a TRANSIENT reason that will very likely be gone in seconds (today:
    /// the model's slots were saturated by client turns).
    ///
    /// It exists because those two situations are not the same thing, even though both
    /// end in "skipped":
    ///
    ///   * the host was asleep at 02:30 — the moment is gone, and whether to run late is
    ///     exactly what `catch_up_secs` decides;
    ///   * someone was mid-conversation with Jesse for ninety seconds — nothing about the
    ///     occurrence is stale, the bridge was simply busy, and dropping the run until
    ///     tomorrow costs a day for a collision that cost seconds.
    ///
    /// So a transient skip re-arms here and the next tick retries the SAME occurrence,
    /// for as long as it stays inside the head's `catch_up_secs`. `last_due_ms` is left
    /// alone throughout — the anti-double-fire anchor is never rolled backwards.
    #[serde(default)]
    pub retry_due_ms: Option<u64>,
}

impl JobRecord {
    /// The typed form of `last_outcome`, or `None` before the job has ever come due.
    pub fn outcome(&self) -> Option<Outcome> {
        Outcome::parse(&self.last_outcome)
    }
}

/// The whole persisted schedule state, keyed by schedule id.
pub struct ScheduleStateStore {
    path: Option<PathBuf>,
    map: Mutex<HashMap<String, JobRecord>>,
}

impl ScheduleStateStore {
    /// Build the store, loading any existing file. With `None` (no state dir configured)
    /// it is in-memory only — the same degradation the job/title/device stores have, and
    /// the operator is warned about it once at startup by the scheduler.
    pub fn new(path: Option<PathBuf>) -> Self {
        let map = path.as_deref().map(load_schedule_state).unwrap_or_default();
        ScheduleStateStore {
            path,
            map: Mutex::new(map),
        }
    }

    /// Whether this store survives a restart.
    pub fn is_persistent(&self) -> bool {
        self.path.is_some()
    }

    /// One job's record (a default — "never came due" — when there is none).
    pub fn get(&self, id: &str) -> JobRecord {
        self.map.lock_ok().get(id).cloned().unwrap_or_default()
    }

    /// Every record, for the observability endpoint.
    pub fn snapshot(&self) -> HashMap<String, JobRecord> {
        self.map.lock_ok().clone()
    }

    /// Mutate one job's record and persist the result. The snapshot is taken under the
    /// same lock as the mutation, so two concurrent updates can never write a file that
    /// reflects neither.
    pub fn update(&self, id: &str, f: impl FnOnce(&mut JobRecord)) {
        let snapshot = {
            let mut map = self.map.lock_ok();
            let rec = map.entry(id.to_string()).or_default();
            f(rec);
            map.clone()
        };
        if let Some(path) = &self.path {
            persist_schedule_state(path, &snapshot);
        }
    }

    /// CLAIM an occurrence: stamp `last_due_ms` before anything runs, so a crash or a
    /// restart between here and the turn's completion cannot replay it.
    ///
    /// Also clears any pending retry: this attempt supersedes it. If the attempt is
    /// itself skipped transiently, [`arm_retry`](Self::arm_retry) sets a fresh one.
    pub fn claim(&self, id: &str, due_ms: u64) {
        self.update(id, |r| {
            r.last_due_ms = Some(due_ms);
            r.retry_due_ms = None;
        });
    }

    /// Mark this occurrence still eligible after a TRANSIENT skip, so the next tick
    /// retries it. Deliberately does NOT touch `last_due_ms` — see the field's note.
    pub fn arm_retry(&self, id: &str, due_ms: u64) {
        self.update(id, |r| r.retry_due_ms = Some(due_ms));
    }

    /// Drop a pending retry (its window closed, or a newer occurrence superseded it).
    pub fn clear_retry(&self, id: &str) {
        self.update(id, |r| r.retry_due_ms = None);
    }

    /// A turn started for this id.
    pub fn started(&self, id: &str, fire_ms: u64, job_id: &str) {
        self.update(id, |r| {
            r.last_fire_ms = Some(fire_ms);
            r.last_job_id = Some(job_id.to_string());
            r.last_completion_ms = None;
            r.last_duration_ms = None;
            r.last_outcome = String::new();
            r.last_reason = String::new();
        });
    }

    /// The occurrence reached its outcome. `duration_ms` is `None` for a skip (nothing
    /// ran to be timed).
    pub fn finished(
        &self,
        id: &str,
        outcome: Outcome,
        reason: &str,
        completion_ms: u64,
        duration_ms: Option<u64>,
    ) {
        self.update(id, |r| {
            r.last_outcome = outcome.label().to_string();
            r.last_reason = reason.to_string();
            r.last_completion_ms = Some(completion_ms);
            r.last_duration_ms = duration_ms;
            if outcome == Outcome::Skipped {
                // Nothing fired, so the fire/job fields must not keep pointing at an
                // older run and make a skip look like it produced a turn.
                r.last_fire_ms = None;
                r.last_job_id = None;
                r.last_duration_ms = None;
            }
        });
    }
}

/// Load the state map, tolerating corruption by returning what is parseable. An absent,
/// unreadable or garbage file yields an empty map — the schedule then behaves like a
/// first-ever boot (no catch-up, next fire resolved from now), which is the safe
/// degradation: it can under-run a job once, never double-run one.
pub fn load_schedule_state(path: &Path) -> HashMap<String, JobRecord> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    if let Some(obj) = value.get("jobs").and_then(|t| t.as_object()) {
        for (id, val) in obj {
            let id = id.trim();
            if id.is_empty() {
                continue;
            }
            if let Ok(rec) = serde_json::from_value::<JobRecord>(val.clone()) {
                out.insert(id.to_string(), rec);
            }
        }
    }
    out
}

/// Persist the state map atomically (temp + rename), mode 0600 — the same discipline as
/// `persist_flags`. Best-effort: a failure is logged, never fatal. The parent dir is
/// created if missing so the store works regardless of init order.
pub fn persist_schedule_state(path: &Path, jobs: &HashMap<String, JobRecord>) {
    let value = json!({ "v": 1, "jobs": jobs });
    // A pid+counter suffix rather than a fixed `.tmp`: two writers sharing one temp path
    // make the loser's rename hit ENOENT (the bug fixed for `device.json`).
    let tmp = path.with_extension(format!(
        "json.tmp.{}.{}",
        std::process::id(),
        JOB_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist schedule state: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_state_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-sched-{}/schedule.json", random_hex()))
    }

    #[test]
    fn in_memory_store_records_without_a_state_dir() {
        let s = ScheduleStateStore::new(None);
        assert!(!s.is_persistent());
        s.claim("nightly", 1000);
        s.started("nightly", 1005, "job-1");
        s.finished("nightly", Outcome::Ran, "", 2005, Some(1000));
        let rec = s.get("nightly");
        assert_eq!(rec.last_due_ms, Some(1000));
        assert_eq!(rec.last_fire_ms, Some(1005));
        assert_eq!(rec.last_job_id.as_deref(), Some("job-1"));
        assert_eq!(rec.outcome(), Some(Outcome::Ran));
        assert_eq!(rec.last_duration_ms, Some(1000));
    }

    #[test]
    fn a_skip_records_a_reason_and_no_turn() {
        let s = ScheduleStateStore::new(None);
        s.claim("nightly", 1000);
        s.started("nightly", 1005, "job-1");
        s.finished("nightly", Outcome::Ran, "", 2005, Some(1000));
        // The NEXT occurrence is skipped: it must not inherit the previous run's turn.
        s.claim("nightly", 90_000);
        s.finished(
            "nightly",
            Outcome::Skipped,
            "catch-up window expired",
            90_100,
            None,
        );
        let rec = s.get("nightly");
        assert_eq!(rec.outcome(), Some(Outcome::Skipped));
        assert_eq!(rec.last_reason, "catch-up window expired");
        assert_eq!(rec.last_fire_ms, None);
        assert_eq!(rec.last_job_id, None);
        assert_eq!(rec.last_duration_ms, None);
        assert_eq!(
            rec.last_due_ms,
            Some(90_000),
            "the occurrence is still claimed"
        );
    }

    #[test]
    fn a_retry_arms_clears_and_never_moves_the_anti_double_fire_anchor() {
        let s = ScheduleStateStore::new(None);
        s.claim("nightly", 1000);
        assert_eq!(s.get("nightly").retry_due_ms, None);

        // A transient skip re-arms the SAME occurrence…
        s.finished("nightly", Outcome::Skipped, "saturated", 1100, None);
        s.arm_retry("nightly", 1000);
        let rec = s.get("nightly");
        assert_eq!(rec.retry_due_ms, Some(1000));
        assert_eq!(
            rec.last_due_ms,
            Some(1000),
            "arming a retry must NOT roll the anchor backwards"
        );

        // …and claiming it again (the retry attempt) clears the pending retry, so a
        // successful attempt cannot leave one behind to fire a third time.
        s.claim("nightly", 1000);
        assert_eq!(s.get("nightly").retry_due_ms, None);
        assert_eq!(s.get("nightly").last_due_ms, Some(1000));

        // And it can be dropped outright when its window closes.
        s.arm_retry("nightly", 1000);
        s.clear_retry("nightly");
        assert_eq!(s.get("nightly").retry_due_ms, None);
    }

    #[test]
    fn state_survives_a_simulated_restart() {
        let path = temp_state_path();
        {
            let s = ScheduleStateStore::new(Some(path.clone()));
            assert!(s.is_persistent());
            s.claim("nightly", 1_700_000_000_000);
            s.started("nightly", 1_700_000_000_500, "job-9");
            s.finished("nightly", Outcome::Ran, "", 1_700_000_060_000, Some(59_500));
            s.claim("weekly", 1_700_000_100_000);
            s.finished(
                "weekly",
                Outcome::Skipped,
                "predecessor 'nightly' failed",
                1_700_000_100_100,
                None,
            );
            // A pending retry must survive the restart too, or a transient skip taken
            // moments before a restart would silently become a dropped occurrence.
            s.arm_retry("weekly", 1_700_000_100_000);
        }
        // A fresh store over the same file is the restart.
        let s = ScheduleStateStore::new(Some(path.clone()));
        let n = s.get("nightly");
        assert_eq!(n.last_due_ms, Some(1_700_000_000_000));
        assert_eq!(n.outcome(), Some(Outcome::Ran));
        assert_eq!(n.last_job_id.as_deref(), Some("job-9"));
        assert_eq!(n.last_duration_ms, Some(59_500));
        let w = s.get("weekly");
        assert_eq!(w.outcome(), Some(Outcome::Skipped));
        assert_eq!(w.last_reason, "predecessor 'nightly' failed");
        assert_eq!(
            w.retry_due_ms,
            Some(1_700_000_100_000),
            "a pending retry must survive a restart"
        );
        // An id that never came due reads as a blank record, not an error.
        assert_eq!(s.get("never"), JobRecord::default());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_degrades_to_empty_rather_than_failing() {
        let path = temp_state_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{ not json at all").unwrap();
        let s = ScheduleStateStore::new(Some(path.clone()));
        assert_eq!(s.snapshot().len(), 0);
        // And it recovers: a later write replaces the garbage.
        s.claim("nightly", 42);
        assert_eq!(
            ScheduleStateStore::new(Some(path.clone()))
                .get("nightly")
                .last_due_ms,
            Some(42)
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
