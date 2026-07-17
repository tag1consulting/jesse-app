use crate::*;

mod streams;
pub use streams::{StreamFrame, StreamRegistry};

// ---- Job store — keeps a turn alive past the client connection ------------
//
// The phone may suspend (socket drops) mid-turn. The turn runs on its own
// detached task and lands its result here, keyed by an opaque job id, so a
// later GET /jesse/result/{job_id} can fetch it.
//
// Eviction model (so a reply that finishes while the phone is away isn't lost):
//   * A completed-but-NEVER-fetched reply is held for the full `ttl` (24h by
//     default) — the clock starts at completion only because it's never been
//     retrieved.
//   * Once a reply has been fetched at least once, the clock restarts and it's
//     kept only `retrieval_grace` longer (a short window so an immediate re-poll
//     still works), then evicted.
//   * Running jobs are never evicted.
//
// Completed results are also PERSISTED to disk (one JSON file per job under
// `<state_dir>/jobs`) and reloaded on startup, so a bridge restart / laptop
// reboot doesn't lose a finished reply. Only the finished result + metadata is
// written — never the bearer token or any secret. Persistence is disabled when
// `jobs_dir` is None (in-memory only).

#[derive(Clone)]
pub enum JobState {
    Running,
    Done {
        response: String,
        session_id: Option<String>,
        // Structured directives the agent emitted on its final line (e.g.
        // `needs_health`), stripped from `response` by the extractor. Carried on
        // the terminal state so BOTH the poll result and the SSE `done` frame
        // surface the same value. `None` for the overwhelming majority of turns.
        directives: Option<Directives>,
        // Structured, display-only provenance (which backend produced the text +
        // the badge/flags it encodes), carried on the terminal state so BOTH the
        // poll result and the SSE `done` frame surface the same value. Present
        // exactly when the text badge is appended; `None` when badges are off, on a
        // persisted reply from before this field, or on an empty/error turn.
        provenance: Option<Provenance>,
    },
    Failed {
        error: String,
    },
    // The client asked to stop the turn (`POST /jesse/cancel/{id}`). The running
    // task was aborted — dropping its `Child` (kill_on_drop) kills `claude` and
    // frees the concurrency permit. A distinct terminal state (not `Failed`) so
    // the phone can render "Cancelled" rather than an error.
    Cancelled,
}

/// Result of a `JobStore::cancel`, used only to log what the cancel did. Every
/// arm is a success on the wire — cancel is idempotent.
pub enum CancelOutcome {
    /// The job was running and has now been aborted + marked `Cancelled`.
    Cancelled,
    /// The job had already reached a terminal state; left untouched.
    AlreadyTerminal,
    /// No job with this id (never created, or already evicted).
    Unknown,
}

pub struct Job {
    pub state: JobState,
    // Set (wall-clock) when the job reaches a terminal state. SystemTime, not
    // Instant, so it can be persisted and compared after a restart.
    pub completed_at: Option<SystemTime>,
    // Set (wall-clock) at the FIRST successful retrieval of a terminal result.
    // Once set, eviction switches from the full TTL to the short post-fetch grace.
    pub first_retrieved_at: Option<SystemTime>,
    // The idempotency key this turn was created with, or `None` for a turn with no
    // `request_id`. Persisted with the job and used to prune the reverse dedup index
    // (`JobsInner::request_index`) when the job is reaped, so the index can never
    // outlive its job.
    pub request_id: Option<String>,
}

/// The jobs map plus the `request_id → job_id` dedup index, behind ONE lock so a
/// check-and-insert at job creation is atomic against a concurrent duplicate POST
/// and the index can never point at a job the same critical section didn't create.
#[derive(Default)]
pub struct JobsInner {
    pub jobs: HashMap<String, Job>,
    // Reverse index for POST /jesse idempotency: an incoming `request_id` maps to the
    // job_id already serving it. Only jobs created WITH a `request_id` appear here.
    // Rebuilt from persisted jobs at startup; every job removal (eviction) also
    // removes its entry, so a mapping can never outlive its job.
    pub request_index: HashMap<String, String>,
}

/// The outcome of creating a job under an optional idempotency key: either a fresh
/// job was created, or an identical live `request_id` was already mapped — in which
/// case the caller must spawn nothing and hand back the existing id.
pub enum CreateOutcome {
    Created(String),
    Duplicate(String),
}

pub struct JobStore {
    pub jobs: Mutex<JobsInner>,
    // Abort handle for each RUNNING job's spawned turn task, keyed by job id.
    // `POST /jesse/cancel/{id}` looks the handle up and aborts it — dropping the
    // task's `Child` (kill_on_drop) kills `claude` and frees the concurrency
    // permit. An entry exists only while the job runs: `complete`/`cancel` remove
    // it on the terminal transition, so the map never holds a finished job.
    //
    // Lock discipline: this mutex, `jobs`, and `streams` are never held
    // simultaneously — each method takes one, releases it, then takes another —
    // so there is no lock ordering between them and no deadlock.
    aborts: Mutex<HashMap<String, AbortHandle>>,
    // Live-stream state for each RUNNING job (broadcast sender + accumulated
    // text), keyed by job id. Mirrors `aborts`: created when the turn is
    // registered, removed on the terminal transition. Its own `Mutex` lives
    // *inside* `StreamRegistry` (private there), so the "never held while `jobs`
    // or `aborts` is held" discipline is now a structural module boundary, not a
    // comment — the store can only reach streams via one-lock-at-a-time methods.
    streams: StreamRegistry,
    // How long an unfetched completed job is held.
    ttl: Duration,
    // How long a completed job is kept after its first retrieval.
    retrieval_grace: Duration,
    // Where completed results are persisted. The store computes the serialized
    // snapshot under the `jobs` lock, releases the lock, then hands it here —
    // so the blocking disk write never holds `jobs` (H2). `NoopPersister` for an
    // in-memory-only run.
    persister: Arc<dyn Persister>,
}

// Monotonic counter guarantees per-process uniqueness; the random high half
// (a fresh OS-seeded RandomState per id) makes the id opaque. The endpoint is
// bearer-auth gated, so the id is not itself a security boundary.
pub static JOB_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn new_job_id() -> String {
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let r = std::collections::hash_map::RandomState::new().hash_one(n);
    format!("{r:016x}{n:016x}")
}

/// Whether a terminal job should be evicted, given how long ago it completed and
/// (if ever) was first retrieved. Pure so it can be tested against a fixed clock
/// rather than the wall clock: never-fetched → evict once `ttl` has passed since
/// completion; fetched → evict once `retrieval_grace` has passed since that fetch.
pub fn job_is_evictable(
    age_since_complete: Duration,
    age_since_first_retrieval: Option<Duration>,
    ttl: Duration,
    retrieval_grace: Duration,
) -> bool {
    match age_since_first_retrieval {
        Some(since_fetch) => since_fetch >= retrieval_grace,
        None => age_since_complete >= ttl,
    }
}

pub fn system_time_to_ms(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn ms_to_system_time(ms: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(ms)
}

/// The on-disk JSON for a completed job, or `None` for a still-running one (which
/// is never persisted — there's no result yet). Carries only the finished result
/// and timing metadata; never any secret.
pub fn job_to_value(id: &str, job: &Job) -> Option<Value> {
    let completed_at = job.completed_at?;
    let (status, response, session_id, directives, provenance, error) = match &job.state {
        JobState::Done {
            response,
            session_id,
            directives,
            provenance,
        } => (
            "done",
            Some(response.clone()),
            session_id.clone(),
            directives_to_value(directives),
            provenance_to_value(provenance),
            None,
        ),
        JobState::Failed { error } => (
            "failed",
            None,
            None,
            Value::Null,
            Value::Null,
            Some(error.clone()),
        ),
        JobState::Cancelled => ("cancelled", None, None, Value::Null, Value::Null, None),
        JobState::Running => return None,
    };
    Some(json!({
        "v": 1,
        "job_id": id,
        "status": status,
        "response": response,
        "session_id": session_id,
        "directives": directives,
        "provenance": provenance,
        "error": error,
        "completed_at_ms": system_time_to_ms(completed_at),
        "first_retrieved_at_ms": job.first_retrieved_at.map(system_time_to_ms),
        // The idempotency key, so a POST /jesse dedup mapping survives a restart
        // (the index is rebuilt from these on load). Absent/null on a turn with no
        // request_id and on any persisted file written before this field existed.
        "request_id": job.request_id,
    }))
}

/// Parse a persisted job file back into `(id, Job)`. Returns `None` for anything
/// malformed or not a recognized terminal status (the caller deletes such files).
pub fn value_to_job(v: &Value) -> Option<(String, Job)> {
    let id = v.get("job_id")?.as_str()?.to_string();
    let state = match v.get("status")?.as_str()? {
        "done" => JobState::Done {
            response: v
                .get("response")
                .and_then(|r| r.as_str())
                .unwrap_or("")
                .to_string(),
            session_id: v
                .get("session_id")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string()),
            // Absent/null/malformed persisted directives → None (a persisted
            // reply from before this field, or a plain turn, has no directive).
            directives: v
                .get("directives")
                .filter(|d| !d.is_null())
                .and_then(|d| serde_json::from_value(d.clone()).ok()),
            // Absent/null/malformed persisted provenance → None (a persisted reply
            // from before this field, or a badges-off turn, has none). A restart
            // then serves the reply with its badge still in the text — the app's
            // no-provenance fallback shows it verbatim, exactly as an old client.
            provenance: v
                .get("provenance")
                .filter(|p| !p.is_null())
                .and_then(|p| serde_json::from_value(p.clone()).ok()),
        },
        "failed" => JobState::Failed {
            error: v
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Jesse couldn't complete that.")
                .to_string(),
        },
        "cancelled" => JobState::Cancelled,
        _ => return None,
    };
    let completed_at = Some(
        v.get("completed_at_ms")
            .and_then(|m| m.as_u64())
            .map(ms_to_system_time)
            .unwrap_or_else(SystemTime::now),
    );
    let first_retrieved_at = v
        .get("first_retrieved_at_ms")
        .and_then(|m| m.as_u64())
        .map(ms_to_system_time);
    // Absent/null/non-string request_id → None. Every job file written before this
    // field existed simply lacks the key and loads with no idempotency mapping.
    let request_id = v
        .get("request_id")
        .and_then(|r| r.as_str())
        .map(|s| s.to_string());
    Some((
        id,
        Job {
            state,
            completed_at,
            first_retrieved_at,
            request_id,
        },
    ))
}

/// Write a job's already-serialized result `Value` to its file atomically
/// (temp + rename), 0600. Takes the serialized snapshot, NOT a `&Job` or the
/// `JobStore` — so persistence never touches the `jobs` lock and a slow disk
/// can't serialize the whole bridge (H2). The serialized value is computed by
/// the caller under the lock, then this blocking write runs after the lock is
/// released. Best-effort: a failure is logged, never fatal.
pub fn write_job_value(dir: &Path, id: &str, value: &Value) {
    let final_path = dir.join(format!("{id}.json"));
    let tmp_path = dir.join(format!("{id}.json.tmp"));
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp_path)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp_path, &final_path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist job {id}: {e}");
        let _ = std::fs::remove_file(&tmp_path);
    }
}

pub fn remove_job_file(dir: &Path, id: &str) {
    let _ = std::fs::remove_file(dir.join(format!("{id}.json")));
}

/// The persistence sink for completed jobs.
///
/// The `JobStore` mutates in-memory state under its `jobs` lock and, still under
/// that lock, ENQUEUES a `write`/`remove` here — an O(1), non-blocking hand-off.
/// The blocking disk work (`fsync`, `unlink`) runs on a dedicated worker thread,
/// entirely OFF the `jobs` lock (H2/H3): a slow disk can never serialize the
/// bridge behind that lock. Enqueuing under the lock also keeps disk ops in the
/// SAME order as the in-memory transitions, so a stale `write` can never resurrect
/// a file a later `remove` already deleted (the eviction race). `write`/`remove`
/// take only the id and the already-serialized `Value` — never the `Job` or the
/// lock — so a test can drive them while holding the `jobs` lock. Best-effort:
/// every op is fire-and-forget and must never panic.
pub trait Persister: Send + Sync {
    /// Whether persistence is on. When `false`, the store skips even serializing
    /// the snapshot — an in-memory-only run pays nothing.
    fn enabled(&self) -> bool;
    /// Enqueue a completed job's serialized `Value` for the worker to persist.
    fn write(&self, id: &str, value: Value);
    /// Enqueue a job's file for the worker to delete.
    fn remove(&self, id: &str);
    /// Block until the worker has processed every op enqueued before this call.
    /// Used by tests for deterministic assertions; a no-op when there's no worker.
    fn flush(&self) {}
}

/// In-memory-only run: persistence disabled, every op a no-op.
pub struct NoopPersister;
impl Persister for NoopPersister {
    fn enabled(&self) -> bool {
        false
    }
    fn write(&self, _id: &str, _value: Value) {}
    fn remove(&self, _id: &str) {}
}

/// One unit of work for the persistence worker thread.
pub enum PersistOp {
    Write(String, Value),
    Remove(String),
    /// Round-trip barrier: the worker replies once it reaches this op, so a
    /// caller can wait for everything before it to have been written/removed.
    Flush(std::sync::mpsc::SyncSender<()>),
}

/// The production sink: a single worker thread that owns `dir` and serially
/// applies `write`/`remove` ops off an unbounded channel. `write`/`remove`/`flush`
/// only enqueue (instant); the worker does the blocking I/O. The worker exits
/// when the store (and thus the `Sender`) is dropped.
pub struct DiskPersister {
    tx: std::sync::mpsc::Sender<PersistOp>,
}

impl DiskPersister {
    pub fn new(dir: PathBuf) -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<PersistOp>();
        // A plain OS thread (not a Tokio task) so the blocking `fsync`/`unlink`
        // never occupies an async worker, and so the store works in non-async
        // tests too. Named for observability; a spawn failure is fatal only here.
        std::thread::Builder::new()
            .name("jesse-persist".to_string())
            .spawn(move || {
                while let Ok(op) = rx.recv() {
                    match op {
                        PersistOp::Write(id, value) => write_job_value(&dir, &id, &value),
                        PersistOp::Remove(id) => remove_job_file(&dir, &id),
                        PersistOp::Flush(reply) => {
                            let _ = reply.send(());
                        }
                    }
                }
            })
            .expect("spawn persistence worker thread");
        DiskPersister { tx }
    }
}

impl Persister for DiskPersister {
    fn enabled(&self) -> bool {
        true
    }
    fn write(&self, id: &str, value: Value) {
        let _ = self.tx.send(PersistOp::Write(id.to_string(), value));
    }
    fn remove(&self, id: &str) {
        let _ = self.tx.send(PersistOp::Remove(id.to_string()));
    }
    fn flush(&self) {
        let (reply_tx, reply_rx) = std::sync::mpsc::sync_channel(0);
        if self.tx.send(PersistOp::Flush(reply_tx)).is_ok() {
            // FIFO: when this returns, every op enqueued before it is done.
            let _ = reply_rx.recv();
        }
    }
}

/// Load persisted jobs from `dir`, dropping (and deleting) any that are already
/// past eviction or unparseable. Returns the survivors to seed the in-memory map.
pub fn load_persisted_jobs(
    dir: &Path,
    ttl: Duration,
    retrieval_grace: Duration,
) -> Vec<(String, Job)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let parsed = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|v| value_to_job(&v));
        let Some((id, job)) = parsed else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        let age_complete = job
            .completed_at
            .map(|t| now.duration_since(t).unwrap_or_default())
            .unwrap_or_default();
        let age_retrieved = job
            .first_retrieved_at
            .map(|t| now.duration_since(t).unwrap_or_default());
        if job_is_evictable(age_complete, age_retrieved, ttl, retrieval_grace) {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        out.push((id, job));
    }
    out
}

impl JobStore {
    /// Build the store, creating the persistence dir (0700) and loading any jobs
    /// left from a previous run when `jobs_dir` is set. A dir that can't be
    /// created disables persistence for the run (the disk sink is dropped).
    pub fn new(ttl: Duration, retrieval_grace: Duration, jobs_dir: Option<PathBuf>) -> Self {
        let mut jobs = HashMap::new();
        let mut persister: Arc<dyn Persister> = Arc::new(NoopPersister);
        if let Some(dir) = jobs_dir {
            if let Err(e) = std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&dir)
            {
                eprintln!(
                    "warning: could not create job state dir {}: {e} — persistence disabled this run",
                    dir.display()
                );
            } else {
                for (id, job) in load_persisted_jobs(&dir, ttl, retrieval_grace) {
                    jobs.insert(id, job);
                }
                persister = Arc::new(DiskPersister::new(dir));
            }
        }
        Self::with_persister(ttl, retrieval_grace, persister, jobs)
    }

    /// Build a store over an explicit persister and pre-seeded job map. Lets a
    /// test inject a probe sink (e.g. to prove `complete` persists off the lock)
    /// while sharing the rest of the wiring with `new`. The `request_id → job_id`
    /// dedup index is rebuilt here from the seeded jobs, so a persisted mapping is
    /// live again the instant the store loads (startup index rebuild).
    pub fn with_persister(
        ttl: Duration,
        retrieval_grace: Duration,
        persister: Arc<dyn Persister>,
        jobs: HashMap<String, Job>,
    ) -> Self {
        let mut request_index = HashMap::new();
        for (id, job) in &jobs {
            if let Some(rid) = &job.request_id {
                request_index.insert(rid.clone(), id.clone());
            }
        }
        JobStore {
            jobs: Mutex::new(JobsInner {
                jobs,
                request_index,
            }),
            aborts: Mutex::new(HashMap::new()),
            streams: StreamRegistry::new(),
            ttl,
            retrieval_grace,
            persister,
        }
    }

    /// Register a new running job and return its opaque id. Running jobs are not
    /// persisted (no result yet). For a turn with no idempotency key.
    pub fn create(&self) -> String {
        match self.create_with_request_id(None) {
            CreateOutcome::Created(id) => id,
            // Unreachable with `None` (no request_id can ever be already-mapped),
            // but returning the id keeps the signature total.
            CreateOutcome::Duplicate(id) => id,
        }
    }

    /// Register a new running job under an optional idempotency key, atomically.
    /// When `request_id` is `Some` and already maps to a job still present in the
    /// store, NO job is created and [`CreateOutcome::Duplicate`] carries the existing
    /// id — so two concurrent POSTs with the same `request_id` can never both spawn
    /// (the check-and-insert happens under the one `jobs` lock). Otherwise a fresh
    /// running job is inserted (and its `request_id` indexed) and its id returned.
    pub fn create_with_request_id(&self, request_id: Option<String>) -> CreateOutcome {
        let mut guard = self.jobs.lock_ok();
        if let Some(rid) = &request_id {
            // Only dedup to a mapping whose job still exists — a reaped job's entry
            // is pruned on eviction, but guard against a stale mapping defensively.
            if let Some(existing) = guard.request_index.get(rid).cloned() {
                if guard.jobs.contains_key(&existing) {
                    return CreateOutcome::Duplicate(existing);
                }
            }
        }
        let id = new_job_id();
        guard.jobs.insert(
            id.clone(),
            Job {
                state: JobState::Running,
                completed_at: None,
                first_retrieved_at: None,
                request_id: request_id.clone(),
            },
        );
        if let Some(rid) = request_id {
            guard.request_index.insert(rid, id.clone());
        }
        CreateOutcome::Created(id)
    }

    /// The job_id currently serving `request_id`, if one is mapped and its job is
    /// still present (queued, running, or a terminal result within its retention
    /// window). `None` when the key is unknown or its job has been reaped — in which
    /// case the caller treats the POST as brand new. Cheap read on the request hot
    /// path so an ordinary duplicate is short-circuited before any permit/work.
    pub fn dedup_lookup(&self, request_id: &str) -> Option<String> {
        let guard = self.jobs.lock_ok();
        let id = guard.request_index.get(request_id)?;
        if guard.jobs.contains_key(id) {
            Some(id.clone())
        } else {
            None
        }
    }

    /// Land a turn's outcome onto its job and persist the result. A Fatal/io
    /// error becomes Failed (still retrievable, so the phone sees the cause).
    ///
    /// Terminal states are write-once: the outcome is recorded only if the job is
    /// still `Running`. This keeps a turn that finishes in the same instant the
    /// client cancels from clobbering the `Cancelled` state that `cancel` already
    /// wrote (and vice-versa — whichever wins the lock first sticks).
    ///
    /// The in-memory transition happens under the `jobs` lock; the serialized
    /// snapshot is taken and ENQUEUED for the persistence worker under that lock
    /// too (an O(1) hand-off). The blocking disk write runs on the worker, off the
    /// lock (H2), so a slow disk can't stall every other request — while enqueuing
    /// under the lock keeps disk ops ordered against eviction's `remove`.
    pub fn complete(
        &self,
        id: &str,
        outcome: Result<(String, Option<String>, Option<Directives>), ApiError>,
    ) {
        self.complete_with_provenance(id, outcome, None);
    }

    /// Land a turn's outcome AND its structured provenance onto the job. Identical
    /// to [`complete`](Self::complete) in every other respect (write-once, persisted,
    /// off-lock disk write); the provenance rides on `JobState::Done` so BOTH the poll
    /// result and the SSE `done` frame surface the same value — mirroring `directives`.
    /// `None` on an error/cancelled outcome or when badges are off.
    pub fn complete_with_provenance(
        &self,
        id: &str,
        outcome: Result<(String, Option<String>, Option<Directives>), ApiError>,
        provenance: Option<Provenance>,
    ) {
        // The turn is over — drop its abort handle so the map can't leak. Done in
        // its own statement so the `aborts` lock is released before taking `jobs`.
        self.aborts.lock_ok().remove(id);
        let state = match outcome {
            Ok((response, session_id, directives)) => JobState::Done {
                response,
                session_id,
                directives,
                provenance,
            },
            Err((_code, error)) => JobState::Failed { error },
        };
        let mut guard = self.jobs.lock_ok();
        let Some(job) = guard.jobs.get_mut(id) else {
            return;
        };
        if !matches!(job.state, JobState::Running) {
            return; // already terminal (e.g. cancelled) — don't clobber it
        }
        job.state = state;
        job.completed_at = Some(SystemTime::now());
        self.persist_under_lock(id, job);
    }

    /// Enqueue a job's serialized snapshot for the persistence worker. Called
    /// while the `jobs` lock is held (so disk ops stay ordered), but only ENQUEUES
    /// — the blocking write happens on the worker thread, never under the lock.
    pub fn persist_under_lock(&self, id: &str, job: &Job) {
        if self.persister.enabled() {
            if let Some(value) = job_to_value(id, job) {
                self.persister.write(id, value);
            }
        }
    }

    /// Block until the persistence worker has flushed every op enqueued so far.
    /// For deterministic tests around the disk; a no-op when persistence is off.
    pub fn flush_persistence(&self) {
        self.persister.flush();
    }

    /// Record the abort handle for a running job's turn task so `cancel` can reach
    /// it. Called once, right after the turn is spawned.
    pub fn set_abort(&self, id: &str, handle: AbortHandle) {
        self.aborts.lock_ok().insert(id.to_string(), handle);
    }

    // ---- Live stream (SSE) -------------------------------------------------
    //
    // Thin delegators to `StreamRegistry`, which owns the streams `Mutex`
    // privately. Each underlying method takes ONLY the streams lock and never
    // holds `jobs`/`aborts` at the same time — now enforced by the module
    // boundary (the store has no access to the raw map or its guard), not by a
    // comment. See `jobstore::streams`.

    /// Open a live stream for a job, right after `create` and before the turn is
    /// spawned, so a subscriber arriving immediately finds the entry.
    pub fn stream_register(&self, id: &str) {
        self.streams.register(id);
    }

    /// Append a text delta to the accumulator and broadcast it live.
    pub fn stream_push_delta(&self, id: &str, delta: &str) {
        self.streams.push_delta(id, delta);
    }

    /// Record the latest tool-activity hint and broadcast it.
    pub fn stream_push_activity(&self, id: &str, name: &str) {
        self.streams.push_activity(id, name);
    }

    /// Clear the accumulated text before a retry re-runs the whole prompt.
    pub fn stream_reset(&self, id: &str) {
        self.streams.reset(id);
    }

    /// Subscribe to a running job's stream (text-so-far, activity, receiver).
    pub fn stream_subscribe(
        &self,
        id: &str,
    ) -> Option<(String, Option<String>, broadcast::Receiver<StreamFrame>)> {
        self.streams.subscribe(id)
    }

    /// The full accumulated text for a job, if its stream is still live.
    pub fn stream_snapshot(&self, id: &str) -> Option<String> {
        self.streams.snapshot(id)
    }

    /// Close a job's stream with a terminal frame and remove the entry.
    pub fn stream_finish(&self, id: &str, frame: StreamFrame) {
        self.streams.finish(id, frame);
    }

    /// Close a job's live stream with the terminal frame matching its CURRENT
    /// (post-`complete`/`cancel`) state, so the emitted frame and the stored
    /// result always agree. `stream_finish` is write-once, so calling this after
    /// a cancel already emitted `Cancelled` is a no-op. Used by the turn task's
    /// normal completion path and by `TurnGuard` (so a panicked turn still drives
    /// a terminal frame, never a permanent Running).
    pub fn emit_terminal_frame(&self, id: &str) {
        match self.get(id) {
            Some(JobState::Done {
                response,
                session_id,
                directives,
                provenance,
            }) => self.stream_finish(
                id,
                StreamFrame::Done {
                    response,
                    session_id,
                    directives,
                    provenance,
                },
            ),
            Some(JobState::Failed { error }) => self.stream_finish(id, StreamFrame::Error(error)),
            Some(JobState::Cancelled) => self.stream_finish(id, StreamFrame::Cancelled),
            // Still Running or gone — nothing terminal to emit.
            _ => {}
        }
    }

    /// Cancel a running turn by id. Aborts its task (drop → `kill_on_drop` kills
    /// `claude` and frees the concurrency permit) and marks the job `Cancelled`.
    /// Idempotent and race-safe: an unknown id, or a job already terminal (done,
    /// failed, or cancelled), is left untouched — the transition only fires from
    /// `Running`. Returns the outcome purely for logging.
    pub fn cancel(&self, id: &str) -> CancelOutcome {
        // Write the `Cancelled` transition FIRST, then abort the task. Order
        // matters: the aborted turn task's `TurnGuard` runs on drop and would mark
        // the job `Failed` if it still saw `Running` — so the terminal state must
        // be in place before the abort that triggers that drop. `complete` is
        // write-once, so the guard then no-ops and `Cancelled` always wins (M2).
        let outcome = {
            let mut guard = self.jobs.lock_ok();
            match guard.jobs.get_mut(id) {
                None => CancelOutcome::Unknown,
                Some(job) if matches!(job.state, JobState::Running) => {
                    job.state = JobState::Cancelled;
                    job.completed_at = Some(SystemTime::now());
                    self.persist_under_lock(id, job); // enqueue under lock
                    CancelOutcome::Cancelled
                }
                Some(_) => CancelOutcome::AlreadyTerminal,
            }
        }; // jobs lock released here, before aborting / touching `streams`
           // Now fire the abort handle (drop → `kill_on_drop` kills `claude` and frees
           // the permit); removing it also prevents a leak. Taken on its own lock,
           // never overlapping `jobs`.
        if let Some(handle) = self.aborts.lock_ok().remove(id) {
            handle.abort();
        }
        // We won the transition to Cancelled — close any live stream with a clean
        // `cancelled` frame. (For AlreadyTerminal/Unknown the turn task's own
        // terminal frame already fired, or there was never a stream.)
        if matches!(outcome, CancelOutcome::Cancelled) {
            self.stream_finish(id, StreamFrame::Cancelled);
        }
        outcome
    }

    pub fn get(&self, id: &str) -> Option<JobState> {
        self.jobs.lock_ok().jobs.get(id).map(|j| j.state.clone())
    }

    /// Fetch a job's state and, if this is the first retrieval of a terminal
    /// result, stamp `first_retrieved_at` (starting the short post-fetch grace)
    /// and persist that so the grace survives a restart. Running fetches don't
    /// start the clock. This is what `GET /jesse/result` uses.
    pub fn get_retrieving(&self, id: &str) -> Option<JobState> {
        let mut guard = self.jobs.lock_ok();
        let job = guard.jobs.get_mut(id)?;
        let state = job.state.clone();
        let is_terminal = !matches!(job.state, JobState::Running);
        if is_terminal && job.first_retrieved_at.is_none() {
            job.first_retrieved_at = Some(SystemTime::now());
            // Enqueue the updated snapshot under the lock (H2: the worker does the
            // blocking write). Enqueuing here, under the same lock eviction takes,
            // keeps this write ordered BEFORE any later `remove` for this id — so a
            // first-retrieval write can never resurrect a file eviction deletes.
            self.persist_under_lock(id, job);
        }
        Some(state)
    }

    /// Drop (and delete the files of) completed jobs past their eviction point.
    /// Running jobs are kept. See `job_is_evictable` for the predicate.
    ///
    /// The `retain` runs under the `jobs` lock but does NO blocking file I/O: it
    /// only ENQUEUES a `remove` per evicted id (H3) — the worker thread does the
    /// unlink off the lock, so a slow disk can't hold `jobs` and stall every
    /// concurrent request. Enqueuing under the lock keeps the unlink ordered after
    /// any prior write for the same id. Runs on a periodic background task (see
    /// `spawn_eviction_task`), no longer on the request hot path.
    pub fn evict_expired(&self) {
        let now = SystemTime::now();
        let ttl = self.ttl;
        let retrieval_grace = self.retrieval_grace;
        let mut guard = self.jobs.lock_ok();
        let inner = &mut *guard;
        inner.jobs.retain(|id, j| {
            let Some(completed) = j.completed_at else {
                return true; // running — never evict
            };
            let age_complete = now.duration_since(completed).unwrap_or_default();
            let age_retrieved = j
                .first_retrieved_at
                .map(|t| now.duration_since(t).unwrap_or_default());
            let evict = job_is_evictable(age_complete, age_retrieved, ttl, retrieval_grace);
            if evict {
                self.persister.remove(id); // enqueue unlink under lock (worker unlinks)
                                           // Prune the dedup mapping in the SAME critical section, so a
                                           // reaped job's `request_id` can never resolve to a gone job —
                                           // a later POST with that key is then correctly treated as new.
                if let Some(rid) = &j.request_id {
                    inner.request_index.remove(rid);
                }
            }
            !evict
        });
    }
}

/// Drives a turn's job to a terminal state if the turn body doesn't reach its
/// own clean completion — i.e. it PANICS (or the task is otherwise dropped while
/// the job is still Running). Without this, a panic in the spawned turn body
/// (M2) would leave the job stuck `Running` forever: `complete` is never called,
/// the stream never gets a terminal frame, and eviction skips running jobs — so
/// the phone's spinner never resolves.
///
/// Held across the turn body and `disarm()`ed once the body has driven the job
/// terminal itself. On `Drop` while still armed it marks the job `Failed`
/// (write-once: a no-op if a cancel already won the transition) and emits the
/// matching terminal stream frame. Cancel writes `Cancelled` BEFORE aborting the
/// task (see `JobStore::cancel`), so the guard always observes a terminal state
/// for a cancelled turn and leaves it untouched.
pub struct TurnGuard {
    jobs: Arc<JobStore>,
    id: String,
    armed: bool,
}

impl TurnGuard {
    pub fn new(jobs: Arc<JobStore>, id: String) -> Self {
        TurnGuard {
            jobs,
            id,
            armed: true,
        }
    }

    /// Disarm after the turn body has itself driven the job terminal — the normal
    /// path already emitted the right frame, so `Drop` must do nothing.
    pub fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TurnGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        // The body didn't complete cleanly (panic / unexpected drop). Force a
        // terminal state so the job can't be stranded Running and the stream
        // always gets a terminal frame. Both calls are write-once / no-op when a
        // terminal state already landed (e.g. a racing cancel).
        self.jobs.complete(
            &self.id,
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "Jesse hit an internal error and couldn't finish that.".to_string(),
            )),
        );
        self.jobs.emit_terminal_frame(&self.id);
    }
}

/// How often the background sweep evicts expired jobs. Eviction was moved off
/// the request hot path (H3); this periodic task is the sole driver in the
/// running server. A minute is fine — TTLs are in the hundreds-to-tens-of-
/// thousands of seconds, so a job lingers at most ~60s past its window.
pub const EVICTION_INTERVAL: Duration = Duration::from_secs(60);

/// Spawn the periodic eviction sweep. Runs on its own Tokio task for the life of
/// the process so a slow disk during a sweep can't touch a request. Replaces the
/// old opportunistic `evict_expired()` calls at the top of the request handlers.
pub fn spawn_eviction_task(jobs: Arc<JobStore>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(EVICTION_INTERVAL);
        // Skip the immediate first tick's burst on a missed deadline; correctness
        // doesn't depend on cadence, only that the sweep keeps running.
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            jobs.evict_expired();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    #[test]
    fn job_ids_are_unique() {
        let store = JobStore::new(Duration::from_secs(600), Duration::from_secs(600), None);
        let a = store.create();
        let b = store.create();
        assert_ne!(a, b);
        // Both start Running.
        assert!(matches!(store.get(&a), Some(JobState::Running)));
        assert!(matches!(store.get(&b), Some(JobState::Running)));
        // Unknown id is None.
        assert!(store.get("nope").is_none());
    }
    #[test]
    fn job_complete_records_done_and_failed() {
        let store = JobStore::new(Duration::from_secs(600), Duration::from_secs(600), None);
        let ok = store.create();
        store.complete(
            &ok,
            Ok(("hi".to_string(), Some("sess-1".to_string()), None)),
        );
        match store.get(&ok) {
            Some(JobState::Done {
                response,
                session_id,
                ..
            }) => {
                assert_eq!(response, "hi");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
            }
            other => panic!("expected Done, got {:?}", other.map(|_| ())),
        }

        let bad = store.create();
        store.complete(
            &bad,
            Err((StatusCode::BAD_GATEWAY, "upstream boom".to_string())),
        );
        match store.get(&bad) {
            Some(JobState::Failed { error }) => assert!(error.contains("boom")),
            other => panic!("expected Failed, got {:?}", other.map(|_| ())),
        }
    }
    #[tokio::test]
    async fn job_ttl_evicts_unfetched_after_ttl_keeps_running() {
        // ttl 50ms, retrieval grace long: an unfetched completed job ages out on
        // the ttl; a running job never evicts; a freshly completed one survives.
        let store = JobStore::new(Duration::from_millis(50), Duration::from_secs(600), None);
        let old = store.create();
        store.complete(&old, Ok(("done".to_string(), None, None)));
        let running = store.create(); // never completes — must survive eviction
                                      // Wait past the TTL, then complete a fresh one that must NOT be evicted.
        tokio::time::sleep(Duration::from_millis(80)).await;
        let fresh = store.create();
        store.complete(&fresh, Ok(("fresh".to_string(), None, None)));

        store.evict_expired();
        assert!(
            store.get(&old).is_none(),
            "stale unfetched completed job should evict on the ttl"
        );
        assert!(
            matches!(store.get(&running), Some(JobState::Running)),
            "running job must never evict"
        );
        assert!(
            matches!(store.get(&fresh), Some(JobState::Done { .. })),
            "recently completed job must survive"
        );
    }
    #[test]
    fn job_is_evictable_holds_unfetched_for_ttl_then_evicts() {
        let ttl = Duration::from_secs(86_400); // 24h
        let grace = Duration::from_secs(600);
        // Never fetched: held the FULL ttl. Well past the old 600s window it's
        // still alive — the regression this whole change exists to fix.
        assert!(!job_is_evictable(
            Duration::from_secs(700),
            None,
            ttl,
            grace
        ));
        assert!(!job_is_evictable(
            Duration::from_secs(86_399),
            None,
            ttl,
            grace
        ));
        // At/after the ttl it finally evicts.
        assert!(job_is_evictable(
            Duration::from_secs(86_400),
            None,
            ttl,
            grace
        ));
        assert!(job_is_evictable(
            Duration::from_secs(90_000),
            None,
            ttl,
            grace
        ));
    }
    #[test]
    fn job_is_evictable_uses_grace_after_first_fetch() {
        let ttl = Duration::from_secs(86_400);
        let grace = Duration::from_secs(600);
        // Once fetched, the clock is the SHORT grace since that fetch — even if
        // it completed a long time ago, a recent fetch keeps it for a re-poll.
        assert!(!job_is_evictable(
            Duration::from_secs(90_000),
            Some(Duration::from_secs(60)),
            ttl,
            grace
        ));
        assert!(!job_is_evictable(
            Duration::from_secs(90_000),
            Some(Duration::from_secs(599)),
            ttl,
            grace
        ));
        // Past the grace since the fetch → evict, regardless of completion age.
        assert!(job_is_evictable(
            Duration::from_secs(90_000),
            Some(Duration::from_secs(600)),
            ttl,
            grace
        ));
    }
    #[tokio::test]
    async fn fetched_job_evicts_after_retrieval_grace_unfetched_survives() {
        // Long ttl, tiny grace: a fetched job ages out on the grace; an unfetched
        // sibling survives because its (24h-ish) ttl clock hasn't elapsed.
        let store = JobStore::new(Duration::from_secs(86_400), Duration::from_millis(40), None);
        let fetched = store.create();
        store.complete(&fetched, Ok(("fetched".to_string(), None, None)));
        let unfetched = store.create();
        store.complete(&unfetched, Ok(("unfetched".to_string(), None, None)));

        // First retrieval starts the grace clock for `fetched` only.
        assert!(matches!(
            store.get_retrieving(&fetched),
            Some(JobState::Done { .. })
        ));
        // A re-poll within the grace still works.
        assert!(matches!(
            store.get_retrieving(&fetched),
            Some(JobState::Done { .. })
        ));

        tokio::time::sleep(Duration::from_millis(70)).await;
        store.evict_expired();
        assert!(
            store.get(&fetched).is_none(),
            "fetched job evicts once the post-fetch grace passes"
        );
        assert!(
            matches!(store.get(&unfetched), Some(JobState::Done { .. })),
            "an unfetched job must NOT evict on the short grace — it gets the full ttl"
        );
    }
    #[test]
    fn persisted_job_survives_simulated_restart() {
        let dir = temp_jobs_dir();
        let ttl = Duration::from_secs(86_400);
        let grace = Duration::from_secs(600);
        {
            let store = JobStore::new(ttl, grace, Some(dir.clone()));
            let id = store.create();
            store.complete(
                &id,
                Ok((
                    "persisted reply".to_string(),
                    Some("sess-9".to_string()),
                    None,
                )),
            );
            store.flush_persistence(); // wait for the off-lock worker to write

            // A new store over the SAME dir is the restart: it must reload the job.
            let restarted = JobStore::new(ttl, grace, Some(dir.clone()));
            match restarted.get(&id) {
                Some(JobState::Done {
                    response,
                    session_id,
                    ..
                }) => {
                    assert_eq!(response, "persisted reply");
                    assert_eq!(session_id.as_deref(), Some("sess-9"));
                }
                other => panic!("reloaded job should be Done, got {:?}", other.map(|_| ())),
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn persisted_failed_job_survives_restart() {
        let dir = temp_jobs_dir();
        let ttl = Duration::from_secs(86_400);
        let grace = Duration::from_secs(600);
        let id = {
            let store = JobStore::new(ttl, grace, Some(dir.clone()));
            let id = store.create();
            store.complete(
                &id,
                Err((StatusCode::GATEWAY_TIMEOUT, "run limit".to_string())),
            );
            store.flush_persistence(); // wait for the off-lock worker to write
            id
        };
        let restarted = JobStore::new(ttl, grace, Some(dir.clone()));
        match restarted.get(&id) {
            Some(JobState::Failed { error }) => assert!(error.contains("run limit")),
            other => panic!("reloaded job should be Failed, got {:?}", other.map(|_| ())),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn persisted_job_already_past_ttl_is_not_reloaded() {
        // A tiny ttl + no grace: by the time the "restart" store loads, the
        // unfetched job is already past its ttl, so it's dropped (and its file
        // deleted) on load rather than resurrected.
        let dir = temp_jobs_dir();
        let ttl = Duration::from_millis(1);
        let grace = Duration::from_millis(1);
        let id = {
            let store = JobStore::new(ttl, grace, Some(dir.clone()));
            let id = store.create();
            store.complete(&id, Ok(("stale".to_string(), None, None)));
            store.flush_persistence(); // wait for the off-lock worker to write
            id
        };
        std::thread::sleep(Duration::from_millis(10));
        let restarted = JobStore::new(ttl, grace, Some(dir.clone()));
        assert!(
            restarted.get(&id).is_none(),
            "a job already past ttl must not reload after restart"
        );
        assert!(
            !dir.join(format!("{id}.json")).exists(),
            "an expired job's file should be deleted on load"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// The state machine in isolation — no HTTP, no `claude`. Covers the
    /// transitions and the write-once invariant that keeps a racing `complete`
    /// from clobbering a `Cancelled` state (and vice-versa).
    #[test]
    fn job_store_cancel_transitions_are_terminal_and_race_safe() {
        let store = JobStore::new(Duration::from_secs(600), Duration::from_secs(600), None);

        // Unknown id → Unknown, no entry created.
        assert!(matches!(store.cancel("nope"), CancelOutcome::Unknown));
        assert!(store.get("nope").is_none());

        // Running → Cancelled, and the state sticks.
        let running = store.create();
        assert!(matches!(store.cancel(&running), CancelOutcome::Cancelled));
        assert!(matches!(store.get(&running), Some(JobState::Cancelled)));

        // Repeat cancel is idempotent (already terminal) and doesn't change it.
        assert!(matches!(
            store.cancel(&running),
            CancelOutcome::AlreadyTerminal
        ));
        assert!(matches!(store.get(&running), Some(JobState::Cancelled)));

        // A turn that completes AFTER a cancel must not overwrite Cancelled —
        // this is the late-completion race the write-once guard exists for.
        let raced = store.create();
        assert!(matches!(store.cancel(&raced), CancelOutcome::Cancelled));
        store.complete(&raced, Ok(("late reply".to_string(), None, None)));
        assert!(matches!(store.get(&raced), Some(JobState::Cancelled)));

        // Cancelling a job that already completed leaves the Done result intact.
        let done = store.create();
        store.complete(&done, Ok(("kept".to_string(), None, None)));
        assert!(matches!(
            store.cancel(&done),
            CancelOutcome::AlreadyTerminal
        ));
        assert!(matches!(store.get(&done), Some(JobState::Done { .. })));
    }
    #[test]
    fn poisoned_jobs_lock_is_recovered_not_propagated() {
        let store = Arc::new(JobStore::new(
            Duration::from_secs(600),
            Duration::from_secs(600),
            None,
        ));
        let id = store.create();

        // Poison the `jobs` mutex: panic while holding its guard on another thread.
        let s = store.clone();
        let poisoned = std::thread::spawn(move || {
            let _g = s.jobs.lock_ok();
            panic!("poison the jobs lock");
        })
        .join();
        assert!(
            poisoned.is_err(),
            "helper thread panicked, poisoning the lock"
        );

        // With `.lock().unwrap()` every subsequent access would panic, cascading
        // one failed turn into a bridge-wide outage. `lock_ok` recovers the guard.
        assert!(matches!(store.get(&id), Some(JobState::Running)));
        let id2 = store.create();
        assert!(matches!(store.get(&id2), Some(JobState::Running)));
        store.complete(&id, Ok(("after poison".into(), None, None)));
        assert!(matches!(store.get(&id), Some(JobState::Done { .. })));
    }
    #[test]
    fn persistence_takes_only_the_value_independent_of_the_jobs_lock() {
        // H2: the restructure makes persistence take ONLY the serialized snapshot
        // (`write_job_value(dir, id, &Value)`) — never a `&Job`, never the
        // `JobStore`, never the `jobs` lock. So a caller can hold the `jobs` lock
        // and the blocking write still proceeds, which is exactly why a slow disk
        // can no longer serialize the whole bridge behind that lock.
        let dir = temp_jobs_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let store = JobStore::new(
            Duration::from_secs(600),
            Duration::from_secs(600),
            Some(dir.clone()),
        );
        let id = store.create();
        {
            // Hold the jobs lock for the entire persist round-trip.
            let _held = store.jobs.lock_ok();
            let job = Job {
                state: JobState::Done {
                    response: "off-lock".into(),
                    session_id: Some("s".into()),
                    directives: None,
                    provenance: None,
                },
                completed_at: Some(SystemTime::now()),
                first_retrieved_at: None,
                request_id: None,
            };
            let value = job_to_value(&id, &job).expect("a terminal job serializes");
            // Completes here even though we hold the jobs lock.
            write_job_value(&dir, &id, &value);
        }
        assert!(
            dir.join(format!("{id}.json")).exists(),
            "persistence runs with only the serialized value, independent of the jobs lock"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn complete_persists_through_the_off_lock_worker() {
        // End-to-end: `complete` enqueues under the lock and the worker thread does
        // the blocking write off the lock. `flush_persistence` is the test barrier.
        let dir = temp_jobs_dir();
        let store = JobStore::new(
            Duration::from_secs(600),
            Duration::from_secs(600),
            Some(dir.clone()),
        );
        let id = store.create();
        store.complete(&id, Ok(("worker write".into(), None, None)));
        store.flush_persistence();
        assert!(
            dir.join(format!("{id}.json")).exists(),
            "the persistence worker wrote the completed job off the jobs lock"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn eviction_under_concurrent_load_no_deadlock_no_lost_jobs() {
        let dir = temp_jobs_dir();
        // Long ttl (unfetched survive), tiny grace (fetched expire fast).
        let store = Arc::new(JobStore::new(
            Duration::from_secs(86_400),
            Duration::from_millis(20),
            Some(dir.clone()),
        ));

        // Two jobs that must survive every sweep: a running one (never evicted)
        // and a completed-but-never-fetched one (held the full 24h ttl).
        let keep_running = store.create();
        let keep_unfetched = store.create();
        store.complete(&keep_unfetched, Ok(("keep".into(), None, None)));

        // Hammer create/complete/get/get_retrieving from many tasks WHILE eviction
        // sweeps concurrently — the concurrency test the suite was missing.
        let mut handles = Vec::new();
        for t in 0..4 {
            let s = store.clone();
            handles.push(tokio::spawn(async move {
                let mut ids = Vec::new();
                for i in 0..40 {
                    let id = s.create();
                    s.complete(&id, Ok((format!("r{t}-{i}"), None, None)));
                    let _ = s.get_retrieving(&id); // starts the 20ms grace clock
                    ids.push(id);
                    if i % 7 == 0 {
                        s.evict_expired();
                    }
                    tokio::task::yield_now().await;
                }
                ids
            }));
        }
        let s = store.clone();
        let evictor = tokio::spawn(async move {
            for _ in 0..40 {
                s.evict_expired();
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        });

        let mut all_ids = Vec::new();
        for h in handles {
            all_ids.extend(h.await.expect("worker must not panic or deadlock"));
        }
        evictor.await.expect("evictor must not deadlock");

        // Let the grace lapse for the last-created jobs, then one final sweep, and
        // flush the persistence worker so the file unlinks are observable.
        tokio::time::sleep(Duration::from_millis(60)).await;
        store.evict_expired();
        store.flush_persistence();

        assert!(
            matches!(store.get(&keep_running), Some(JobState::Running)),
            "a running job is never evicted"
        );
        assert!(
            matches!(store.get(&keep_unfetched), Some(JobState::Done { .. })),
            "an unfetched completed job survives on its long ttl"
        );
        for id in &all_ids {
            assert!(
                store.get(id).is_none(),
                "a fetched job past its grace must evict from memory"
            );
            assert!(
                !dir.join(format!("{id}.json")).exists(),
                "an evicted job's file must be unlinked (off-lock, in order after its write)"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[tokio::test]
    async fn panicking_turn_body_lands_failed_with_terminal_frame() {
        let st = test_state();

        // Control: a panicking body with NO guard strands the job Running — the
        // exact M2 bug (complete never called, eviction skips running jobs).
        let unguarded = st.jobs.create();
        let jobs0 = st.jobs.clone();
        let u = unguarded.clone();
        let _ = tokio::spawn(async move {
            let _hold = (jobs0, u);
            panic!("unguarded panic");
        })
        .await;
        assert!(
            matches!(st.jobs.get(&unguarded), Some(JobState::Running)),
            "without the guard a panicked turn stays stuck Running (the M2 bug)"
        );

        // With the guard (as wired into the real turn task), the same panic drives
        // the job to Failed and emits a terminal stream frame.
        let jid = st.jobs.create();
        st.jobs.stream_register(&jid);
        let (_text, _act, mut rx) = st.jobs.stream_subscribe(&jid).unwrap();
        let jobs = st.jobs.clone();
        let j = jid.clone();
        let h = tokio::spawn(async move {
            let _guard = TurnGuard::new(jobs, j);
            panic!("boom in the turn body");
        });
        assert!(h.await.is_err(), "the turn task panicked");

        assert!(
            matches!(st.jobs.get(&jid), Some(JobState::Failed { .. })),
            "a panicked turn body must land Failed, not stay Running"
        );
        let mut got_terminal_error = false;
        while let Ok(frame) = rx.try_recv() {
            if matches!(frame, StreamFrame::Error(_)) {
                got_terminal_error = true;
            }
        }
        assert!(
            got_terminal_error,
            "the stream must receive a terminal error frame, not stay silent"
        );
    }

    // ---- POST /jesse idempotency (request_id dedup) -----------------------

    #[test]
    fn create_with_request_id_dedups_a_live_mapping() {
        let store = JobStore::new(Duration::from_secs(600), Duration::from_secs(600), None);
        // First create under a key → a fresh job, indexed.
        let id = match store.create_with_request_id(Some("req-1".to_string())) {
            CreateOutcome::Created(id) => id,
            CreateOutcome::Duplicate(_) => panic!("first create must be Created"),
        };
        // A second create under the SAME key → Duplicate carrying the SAME id;
        // no new job was inserted (spawn nothing).
        match store.create_with_request_id(Some("req-1".to_string())) {
            CreateOutcome::Duplicate(existing) => assert_eq!(existing, id),
            CreateOutcome::Created(_) => {
                panic!("a live mapping must dedup, not create a second job")
            }
        }
        // The phase-1 hot-path lookup resolves the key to the same job.
        assert_eq!(store.dedup_lookup("req-1").as_deref(), Some(id.as_str()));
        // A DIFFERENT key is unrelated → a distinct job.
        let other = match store.create_with_request_id(Some("req-2".to_string())) {
            CreateOutcome::Created(id) => id,
            CreateOutcome::Duplicate(_) => panic!("a new key must create"),
        };
        assert_ne!(other, id);
        // An unknown key resolves to nothing.
        assert!(store.dedup_lookup("never-seen").is_none());
    }

    #[test]
    fn dedup_survives_completion_and_still_returns_the_finished_job() {
        // A key stays mapped after its job completes — a duplicate POST against a
        // finished job returns that job so the first poll gets the reply.
        let store = JobStore::new(Duration::from_secs(600), Duration::from_secs(600), None);
        let id = match store.create_with_request_id(Some("done-key".to_string())) {
            CreateOutcome::Created(id) => id,
            CreateOutcome::Duplicate(_) => unreachable!(),
        };
        store.complete(&id, Ok(("finished".to_string(), None, None)));
        assert_eq!(store.dedup_lookup("done-key").as_deref(), Some(id.as_str()));
        match store.create_with_request_id(Some("done-key".to_string())) {
            CreateOutcome::Duplicate(existing) => assert_eq!(existing, id),
            CreateOutcome::Created(_) => panic!("a completed job's key must still dedup"),
        }
    }

    #[test]
    fn reaped_mapping_is_treated_as_new_and_index_is_pruned() {
        // Tiny ttl, no grace: a completed job ages out, and eviction must also drop
        // its dedup mapping so the SAME key later creates a brand-new job.
        let store = JobStore::new(Duration::from_millis(1), Duration::from_millis(1), None);
        let id1 = match store.create_with_request_id(Some("reap-key".to_string())) {
            CreateOutcome::Created(id) => id,
            CreateOutcome::Duplicate(_) => unreachable!(),
        };
        store.complete(&id1, Ok(("gone soon".to_string(), None, None)));
        std::thread::sleep(Duration::from_millis(10));
        store.evict_expired();
        // The job is reaped AND its mapping pruned (index can't outlive the job).
        assert!(store.get(&id1).is_none(), "the job should have evicted");
        assert!(
            store.dedup_lookup("reap-key").is_none(),
            "a reaped job's mapping must be pruned, not dangle"
        );
        // The same key now creates a fresh job — treated as brand new.
        let id2 = match store.create_with_request_id(Some("reap-key".to_string())) {
            CreateOutcome::Created(id) => id,
            CreateOutcome::Duplicate(_) => panic!("a reaped mapping must be treated as new"),
        };
        assert_ne!(id2, id1);
    }

    #[test]
    fn job_value_roundtrips_request_id_and_tolerates_absence() {
        // A completed job with a request_id serializes it, and parses back with it.
        let job = Job {
            state: JobState::Done {
                response: "r".into(),
                session_id: None,
                directives: None,
                provenance: None,
            },
            completed_at: Some(SystemTime::now()),
            first_retrieved_at: None,
            request_id: Some("rid-abc".into()),
        };
        let v = job_to_value("id1", &job).expect("a terminal job serializes");
        assert_eq!(v["request_id"], "rid-abc");
        let (_, back) = value_to_job(&v).expect("round-trips");
        assert_eq!(back.request_id.as_deref(), Some("rid-abc"));

        // An OLD persisted file lacks the key entirely — it must still load, with
        // no idempotency mapping.
        let mut old = v.clone();
        old.as_object_mut().unwrap().remove("request_id");
        let (_, back_old) = value_to_job(&old).expect("a pre-field file still loads");
        assert!(
            back_old.request_id.is_none(),
            "a file without request_id loads with None, not an error"
        );
    }

    #[test]
    fn persisted_request_id_rebuilds_the_index_on_restart() {
        // A completed job's request_id survives a restart AND repopulates the dedup
        // index, so a duplicate POST after a bridge restart still returns it.
        let dir = temp_jobs_dir();
        let ttl = Duration::from_secs(86_400);
        let grace = Duration::from_secs(600);
        let id = {
            let store = JobStore::new(ttl, grace, Some(dir.clone()));
            let id = match store.create_with_request_id(Some("persist-key".to_string())) {
                CreateOutcome::Created(id) => id,
                CreateOutcome::Duplicate(_) => unreachable!(),
            };
            store.complete(&id, Ok(("persisted".to_string(), None, None)));
            store.flush_persistence();
            id
        };
        // Restart over the same dir: the index is rebuilt from the persisted job.
        let restarted = JobStore::new(ttl, grace, Some(dir.clone()));
        assert!(matches!(restarted.get(&id), Some(JobState::Done { .. })));
        assert_eq!(
            restarted.dedup_lookup("persist-key").as_deref(),
            Some(id.as_str()),
            "the dedup index must be rebuilt from persisted jobs at startup"
        );
        match restarted.create_with_request_id(Some("persist-key".to_string())) {
            CreateOutcome::Duplicate(existing) => assert_eq!(existing, id),
            CreateOutcome::Created(_) => {
                panic!("a persisted mapping must dedup after restart")
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn old_persisted_file_without_request_id_still_loads() {
        // A hand-authored pre-field file (no request_id key) must load cleanly on
        // startup and carry no mapping — the on-disk backward-compat guarantee.
        let dir = temp_jobs_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let id = "0000000000000000deadbeefdeadbeef";
        let old = json!({
            "v": 1,
            "job_id": id,
            "status": "done",
            "response": "legacy reply",
            "session_id": "sess-old",
            "directives": Value::Null,
            "provenance": Value::Null,
            "error": Value::Null,
            "completed_at_ms": system_time_to_ms(SystemTime::now()),
            "first_retrieved_at_ms": Value::Null,
            // NOTE: no "request_id" key — the pre-idempotency on-disk shape.
        });
        std::fs::write(dir.join(format!("{id}.json")), old.to_string()).unwrap();
        let store = JobStore::new(
            Duration::from_secs(86_400),
            Duration::from_secs(600),
            Some(dir.clone()),
        );
        match store.get(id) {
            Some(JobState::Done { response, .. }) => assert_eq!(response, "legacy reply"),
            other => panic!("old file must load as Done, got {:?}", other.map(|_| ())),
        }
        assert!(
            store.dedup_lookup("anything").is_none(),
            "an old file carries no dedup mapping"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
