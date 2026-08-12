use crate::*;
use chrono::{Local, Offset, TimeZone};

// ---- The built-in scheduler --------------------------------------------------
//
// Recurring agent turns fire from THIS always-on service. No desktop app has to be
// open, no GUI account has to be signed in, no external cron or launchd job is
// involved. The jobs this replaces lived in a desktop scheduler that stopped firing
// and was not noticed for a month; every design decision below is aimed at that.
//
// THE FOUR PROPERTIES, and where each is enforced:
//
//   NO TWO SCHEDULED TURNS OVERLAP. `turn_lock` — a scheduler-owned semaphore of ONE,
//     independent of the request concurrency limit — is held for a whole chain run. A
//     second chain's head that comes due meanwhile WAITS on it rather than starting.
//     This is what keeps two turns off the same working tree, so it is never relaxed
//     for throughput.
//
//   CHAINS, NOT SPACED CLOCK TIMES. A link starts only once its predecessor's turn has
//     fully completed and its result is in the job store. Estimates of how long a turn
//     takes rot; completion does not.
//
//   NOTHING IS SILENT. Every due occurrence ends as ran, failed or skipped; a skip
//     always carries a reason; each of those is logged at info, recorded in
//     `<state_dir>/schedule.json`, readable at `GET /jesse/schedule`, and (by default)
//     pushed to the phone.
//
//   A MISCONFIGURATION DOES NOT TAKE THE SERVICE DOWN. Validation happens in
//     [`crate::schedule`]; a bad entry is disabled individually and its neighbours still
//     run. Only a duplicate id or an `after` cycle refuses the boot, because both make
//     the operator's intent unknowable.
//
// A scheduled turn goes through [`crate::handlers::start_turn`] — the same path a phone
// request takes — so it gets a job id, the same retry and failure classification, the
// same live stream, and is retrievable at `GET /jesse/result/{id}`.

/// How often the scheduler wakes. Short and fixed: the resolution of a `"HH:MM"` job is
/// a minute, so a tick well inside that keeps the worst-case start delay under the
/// precision anyone declared. It is not a timer per job — one task, one interval, and
/// the state file decides what is due.
pub const SCHEDULER_TICK: Duration = Duration::from_secs(20);

/// How long a scheduled turn waits for a free model slot before SKIPPING.
///
/// A scheduled turn must never starve an interactive one. If the request concurrency
/// limit is saturated by client turns, this waits briefly and then gives up — because
/// queueing indefinitely behind a person who is actively using the bridge is exactly how
/// a "morning routine" ends up starting at noon. The skip is recorded and pushed.
pub const SCHEDULED_SLOT_WAIT: Duration = Duration::from_secs(60);

/// How often the chain runner re-probes for a free slot and for its turn's terminal state.
const SCHEDULED_POLL: Duration = Duration::from_millis(250);

/// Slack added to a turn's own run limit when waiting for it to reach a terminal state.
/// The driver retries a transient up to three times under that limit, so the bound here
/// is `3 × limit + slack`; it is a backstop against a job that never lands (which
/// `TurnGuard` already makes near-impossible), not the mechanism that ends a turn.
const TERMINAL_WAIT_SLACK: Duration = Duration::from_secs(300);

/// The scheduler's runtime state: the validated schedule, the persisted record, the
/// one-turn-at-a-time lock, and which chains are in flight.
pub struct Scheduler {
    pub schedule: Arc<Schedule>,
    pub state: Arc<ScheduleStateStore>,
    /// AT MOST ONE scheduled turn at any moment, across every chain. Deliberately NOT
    /// the request concurrency semaphore: that one exists to bound load and is sized by
    /// the operator, while this one exists to keep two agents off one working tree and
    /// is always exactly one.
    turn_lock: Arc<Semaphore>,
    /// The head ids of chains currently running — the single-flight set. Keyed on the
    /// HEAD because `after` gives every job at most one predecessor, so a job belongs to
    /// exactly one chain: guarding the head guards every member.
    running: Mutex<Vec<String>>,
    /// When this process started. The anchor for a head with no persisted record, so a
    /// first-ever boot resolves its next fire forward from now rather than "catching up"
    /// a history it never had.
    boot_ms: u64,
    /// How long a scheduled turn waits for a free model slot before skipping, rather than
    /// queueing behind an interactive one. [`SCHEDULED_SLOT_WAIT`] in production.
    slot_wait: Duration,
}

/// Releases a chain's single-flight claim however the run ends — including a panic.
struct FlightGuard {
    sched: Arc<Scheduler>,
    head: String,
}

impl Drop for FlightGuard {
    fn drop(&mut self) {
        let mut running = self.sched.running.lock_ok();
        running.retain(|id| id != &self.head);
    }
}

/// What one job's turn produced, as the chain runner sees it.
struct RunResult {
    outcome: Outcome,
    reason: String,
    job_id: Option<String>,
    duration_ms: Option<u64>,
    /// This skip was TRANSIENT — the bridge was momentarily busy, nothing about the
    /// occurrence went stale — so the occurrence stays eligible and a later tick may
    /// retry it. See [`retry_should_arm`].
    transient: bool,
}

impl RunResult {
    fn skipped(reason: impl Into<String>) -> Self {
        RunResult {
            outcome: Outcome::Skipped,
            reason: reason.into(),
            job_id: None,
            duration_ms: None,
            transient: false,
        }
    }

    /// A skip the next tick should retry (the slot table was saturated by client turns).
    fn transient(reason: impl Into<String>) -> Self {
        RunResult {
            transient: true,
            ..RunResult::skipped(reason)
        }
    }

    fn failed(reason: impl Into<String>) -> Self {
        RunResult {
            outcome: Outcome::Failed,
            reason: reason.into(),
            job_id: None,
            duration_ms: None,
            transient: false,
        }
    }
}

/// Whether a finished job re-arms its occurrence for a retry on a later tick.
///
/// TWO CONDITIONS, and the second is the one that keeps this safe.
///
/// It must be a TRANSIENT skip: the bridge was busy for a moment, so nothing about the
/// occurrence is stale and the only cost of retrying is a few seconds' delay.
///
/// And it must be the chain HEAD. A retry re-runs the WHOLE chain, and re-running a
/// chain whose earlier members already succeeded would re-apply their work against the
/// vault. A head that was skipped ran nothing — every link behind it cascade-skipped —
/// so replaying from the head is replaying nothing. A link skipped mid-chain is
/// therefore recorded and pushed, but not retried; resuming a chain from its middle
/// needs per-member progress state this deliberately does not keep.
fn retry_should_arm(job: &ScheduleJob, result: &RunResult) -> bool {
    result.transient && job.is_head()
}

impl Scheduler {
    /// Build the scheduler over a validated schedule and the state file path (`None`
    /// keeps the record in memory only — see the warning in [`spawn_scheduler`]).
    pub fn new(schedule: Arc<Schedule>, state_file: Option<PathBuf>) -> Arc<Self> {
        Self::new_with(schedule, state_file, SCHEDULED_SLOT_WAIT)
    }

    /// [`new`](Self::new) with an explicit slot-starvation patience. The shipped value is
    /// [`SCHEDULED_SLOT_WAIT`]; a shorter one lets a test prove the yield-to-a-client
    /// behavior without spending a minute waiting for it.
    pub fn new_with(
        schedule: Arc<Schedule>,
        state_file: Option<PathBuf>,
        slot_wait: Duration,
    ) -> Arc<Self> {
        Arc::new(Scheduler {
            schedule,
            state: Arc::new(ScheduleStateStore::new(state_file)),
            turn_lock: Arc::new(Semaphore::new(1)),
            running: Mutex::new(Vec::new()),
            boot_ms: system_time_to_ms(SystemTime::now()),
            slot_wait,
        })
    }

    /// Whether any job is configured at all. A deploy with no `[[schedule]]` never
    /// starts the tick task, so the whole feature is absent rather than idling.
    pub fn is_configured(&self) -> bool {
        !self.schedule.jobs.is_empty()
    }

    /// Whether this chain is running right now.
    pub fn is_running(&self, head: &str) -> bool {
        self.running.lock_ok().iter().any(|id| id == head)
    }

    /// The occurrence anchor for a head: the last occurrence it processed, or this
    /// process's boot time when it has never come due.
    fn anchor_for(&self, id: &str) -> u64 {
        self.state.get(id).last_due_ms.unwrap_or(self.boot_ms)
    }

    /// The next fire a head is waiting for, for the observability endpoint. `None` for a
    /// link, a disabled job, or an unresolvable one.
    pub fn next_fire_for(&self, job: &ScheduleJob) -> Option<u64> {
        if !job.enabled || !job.is_head() {
            return None;
        }
        job.next_fire_ms(&Local, self.anchor_for(&job.id))
    }

    /// ONE PASS over the heads. Anything due is claimed and its chain is spawned; the
    /// returned handles are the chains started by THIS pass (production drops them —
    /// dropping a `JoinHandle` detaches, it does not cancel — while tests await them, so
    /// the suite never races the wall clock).
    pub fn tick(self: &Arc<Self>, st: &AppState, now_ms: u64) -> Vec<tokio::task::JoinHandle<()>> {
        let mut started = Vec::new();
        for head in self.schedule.heads() {
            if !head.enabled {
                continue; // off means off — not "due and skipped" every 20 seconds.
            }
            let anchor = self.anchor_for(&head.id);
            let fresh = due_occurrence(&Local, head, anchor, now_ms);
            // A PENDING RETRY: the previous attempt was skipped because the bridge was
            // momentarily busy, so this occurrence never became stale. It takes
            // precedence over nothing — a genuinely NEWER occurrence supersedes it (only
            // reachable with a catch-up window wider than the gap between fires), and
            // that supersession is recorded rather than silently dropped.
            let retry = self.state.get(&head.id).retry_due_ms;
            let due = match (retry, fresh) {
                (Some(retry_ms), Some(f)) if f.due_ms > retry_ms => {
                    let reason = format!(
                        "superseded by the {} occurrence before its retry could run",
                        human_ms(f.due_ms.saturating_sub(retry_ms))
                    );
                    self.finish_job(st, head, Outcome::Skipped, &reason, None, None, false);
                    f
                }
                (Some(retry_ms), _) => DueFire {
                    due_ms: retry_ms,
                    lateness_ms: now_ms.saturating_sub(retry_ms),
                    missed_earlier: 0,
                },
                (None, Some(f)) => f,
                (None, None) => continue,
            };
            // Claim it FIRST, before anything can fail: a claimed occurrence never comes
            // due again, so a crash between here and the outcome cannot replay the turn.
            // This also clears the pending retry — the attempt below supersedes it, and
            // re-arms only if it too is skipped transiently.
            self.state.claim(&head.id, due.due_ms);

            if due.missed_earlier > 0 {
                eprintln!(
                    "jesse-bridge: schedule MISSED id={} — {} earlier occurrence(s) went by \
                     unprocessed; acting on the most recent one only",
                    head.id, due.missed_earlier
                );
            }

            // SINGLE FLIGHT. A chain from a previous day still running when its head
            // comes due again is skipped and recorded — never queued, because queueing
            // would eventually run two of them back to back at the wrong time of day.
            if self.is_running(&head.id) {
                let reason = "a previous run of this chain is still in progress".to_string();
                self.finish_job(st, head, Outcome::Skipped, &reason, None, None, false);
                continue;
            }

            // Past the catch-up window: skip, loudly, naming how late it was.
            let catch_up_ms = head.catch_up_secs.saturating_mul(1000);
            if due.lateness_ms > catch_up_ms {
                let reason = format!(
                    "missed by {} (catch_up_secs = {}s)",
                    human_ms(due.lateness_ms),
                    head.catch_up_secs
                );
                self.finish_job(st, head, Outcome::Skipped, &reason, None, None, false);
                // The rest of the chain never ran either — say so, once per link.
                self.skip_rest_of_chain(st, &head.id, &head.id, Outcome::Skipped);
                continue;
            }

            self.running.lock_ok().push(head.id.clone());
            let sched = self.clone();
            let st2 = st.clone();
            let head_id = head.id.clone();
            started.push(tokio::spawn(async move {
                run_chain(sched, st2, head_id, due).await;
            }));
        }
        started
    }

    /// Record + log + push one job's outcome. `cascaded` marks a skip CAUSED by an
    /// earlier job in the same chain run: those are recorded but not pushed, so a chain
    /// that breaks pushes once for the break rather than once per skipped link.
    #[allow(clippy::too_many_arguments)]
    fn finish_job(
        &self,
        st: &AppState,
        job: &ScheduleJob,
        outcome: Outcome,
        reason: &str,
        job_id: Option<&str>,
        duration_ms: Option<u64>,
        cascaded: bool,
    ) {
        let now = system_time_to_ms(SystemTime::now());
        self.state
            .finished(&job.id, outcome, reason, now, duration_ms);
        eprintln!(
            "jesse-bridge: schedule DONE id={} outcome={}{}{}{}",
            job.id,
            outcome.label(),
            duration_ms
                .map(|d| format!(" duration_ms={d}"))
                .unwrap_or_default(),
            job_id.map(|j| format!(" job={j}")).unwrap_or_default(),
            if reason.is_empty() {
                String::new()
            } else {
                format!(" reason={reason:?}")
            },
        );
        if should_push(job, outcome, reason, cascaded) {
            let st = st.clone();
            let id = job.id.clone();
            let reason = reason.to_string();
            let job_id = job_id.map(str::to_string);
            // Detached: the record is already written, so a slow or failing APNs round
            // trip must not hold up the next link in the chain.
            tokio::spawn(async move {
                push_schedule_outcome(&st, &id, outcome, &reason, job_id.as_deref()).await;
            });
        }
    }

    /// Record every job hanging off `from` as skipped because `breaker` broke the chain.
    /// Used when a chain cannot start at all (the head was skipped): there is no
    /// predecessor outcome to consult per link, and `after_on = "any"` does not apply —
    /// it means "run even if the previous job failed", not "run even if the scheduler
    /// never got to this chain".
    fn skip_rest_of_chain(&self, st: &AppState, from: &str, breaker: &str, cause: Outcome) {
        for id in self.schedule.chain(from).into_iter().skip(1) {
            let Some(job) = self.schedule.get(&id) else {
                continue;
            };
            let reason = format!("{breaker:?} {} — the chain never ran", cause.label());
            self.finish_job(st, job, Outcome::Skipped, &reason, None, None, true);
        }
    }
}

/// Whether an outcome earns a push.
///
/// Silence is never the default: a run that ran, failed, or was skipped for a reason the
/// operator did not ask for all push. The two exclusions are deliberate and are the
/// difference between an alert that gets read and one that gets muted:
///
///   * a CASCADED skip — the chain already pushed once for the break that caused it;
///   * a skip the CONFIG asked for — a `days` filter that excludes today, or a disabled
///     entry. "Your Monday-only job did not run on Tuesday" six times a week is how a
///     notification channel becomes noise, and this feature exists because a channel
///     nobody reads is how the original failure went unnoticed for a month.
fn should_push(job: &ScheduleJob, outcome: Outcome, reason: &str, cascaded: bool) -> bool {
    if !job.notify {
        return false;
    }
    if cascaded {
        return false;
    }
    if outcome == Outcome::Skipped && (reason == CALENDAR_SKIP || reason == DISABLED_SKIP) {
        return false;
    }
    true
}

/// The reason text for a link the `days` filter excluded today. Compared by value in
/// [`should_push`], so it is a const rather than a formatted string.
const CALENDAR_SKIP: &str = "not scheduled on this weekday";
/// The reason text for a link that is `enabled = false`.
const DISABLED_SKIP: &str = "disabled";

/// Run one chain: the head and everything behind it, strictly sequentially, under the
/// scheduler's one-turn-at-a-time lock.
async fn run_chain(sched: Arc<Scheduler>, st: AppState, head_id: String, due: DueFire) {
    let _flight = FlightGuard {
        sched: sched.clone(),
        head: head_id.clone(),
    };
    let Some(head) = sched.schedule.get(&head_id) else {
        return;
    };

    // THE GLOBAL SERIALIZATION POINT. Held for the WHOLE chain, so a second chain whose
    // head comes due meanwhile waits here instead of starting — which is the property
    // that keeps two agents off the same working tree. The wait is bounded by what is
    // left of this head's catch-up window: a chain that is still queued when its window
    // expires is skipped and recorded, never started hours late.
    let now = system_time_to_ms(SystemTime::now());
    let deadline_ms = due.due_ms + head.catch_up_secs.saturating_mul(1000);
    let wait = Duration::from_millis(deadline_ms.saturating_sub(now));
    let permit = match timeout(wait, sched.turn_lock.clone().acquire_owned()).await {
        Ok(Ok(p)) => p,
        Ok(Err(_)) => return, // the semaphore is never closed
        Err(_) => {
            let reason = format!(
                "waited {} for another scheduled chain to finish and the catch-up window \
                 expired (catch_up_secs = {}s)",
                human_ms(wait.as_millis() as u64),
                head.catch_up_secs
            );
            sched.finish_job(&st, head, Outcome::Skipped, &reason, None, None, false);
            sched.skip_rest_of_chain(&st, &head_id, &head_id, Outcome::Skipped);
            return;
        }
    };

    // Every member's outcome, so each link can consult ITS OWN predecessor, and the id
    // of whatever broke the chain, so a cascaded skip names the original cause rather
    // than the link immediately above it.
    let mut outcomes: HashMap<String, Outcome> = HashMap::new();
    let mut broken_by: HashMap<String, String> = HashMap::new();

    for id in sched.schedule.chain(&head_id) {
        let Some(job) = sched.schedule.get(&id) else {
            continue;
        };
        let mut cascaded = false;

        // 1. The predecessor gate.
        let gate = match job.after() {
            None => None,
            Some(parent) => {
                let parent_outcome = outcomes.get(parent).copied().unwrap_or(Outcome::Skipped);
                if job.after_on() == AfterOn::Success && !parent_outcome.is_success() {
                    let breaker = broken_by
                        .get(parent)
                        .cloned()
                        .unwrap_or_else(|| parent.to_string());
                    cascaded = true;
                    broken_by.insert(id.clone(), breaker.clone());
                    Some(format!("{breaker:?} {}", parent_outcome.label()))
                } else {
                    None
                }
            }
        };

        // 2. This entry's own gates: disabled, and the weekday filter (which applies to
        //    links as much as to heads — a Monday-only job on a daily chain is the
        //    reason `days` is not a head-only key).
        let now_ms = system_time_to_ms(SystemTime::now());
        let result = if let Some(reason) = gate {
            RunResult::skipped(reason)
        } else if !job.enabled {
            broken_by.insert(id.clone(), id.clone());
            RunResult::skipped(DISABLED_SKIP)
        } else if !local_weekday(&Local, now_ms)
            .map(|w| job.days.contains(w))
            .unwrap_or(true)
        {
            broken_by.insert(id.clone(), id.clone());
            RunResult::skipped(CALENDAR_SKIP)
        } else {
            run_one(&sched, &st, job).await
        };

        outcomes.insert(id.clone(), result.outcome);
        if !result.outcome.is_success() && !broken_by.contains_key(&id) {
            broken_by.insert(id.clone(), id.clone());
        }
        sched.finish_job(
            &st,
            job,
            result.outcome,
            &result.reason,
            result.job_id.as_deref(),
            result.duration_ms,
            cascaded,
        );
        // A TRANSIENT skip of the HEAD leaves this occurrence eligible: the next tick
        // retries it, for as long as it is still inside the catch-up window. A slot
        // collision with a person using the bridge should cost minutes, not the day's
        // run. See [`retry_should_arm`] for why only the head re-arms.
        if retry_should_arm(job, &result) {
            sched.state.arm_retry(&id, due.due_ms);
            eprintln!(
                "jesse-bridge: schedule RETRY-ARMED id={} due_ms={} — still eligible for {}",
                id,
                due.due_ms,
                human_ms(
                    (due.due_ms + job.catch_up_secs.saturating_mul(1000))
                        .saturating_sub(system_time_to_ms(SystemTime::now()))
                ),
            );
        }
    }
    drop(permit);
}

/// Run ONE scheduled job's turn: resolve the prompt, wait (briefly) for a model slot,
/// submit it on the client turn path, and wait for it to land in the job store.
async fn run_one(sched: &Arc<Scheduler>, st: &AppState, job: &ScheduleJob) -> RunResult {
    // The prompt is resolved HERE, at fire time — `prompt_file` is never cached at
    // startup, so editing a prompt needs no restart. An unreadable file is a failed run
    // carrying that reason, not a panic and not an empty turn.
    let prompt = match job.prompt.load(Path::new(&st.cfg.vault)) {
        Ok(p) => p,
        Err(e) => return RunResult::failed(e),
    };

    // A SCHEDULED TURN MUST NEVER STARVE AN INTERACTIVE ONE. If the model's slots are
    // saturated by client turns, wait briefly and then skip rather than queue behind a
    // person who is using the bridge right now.
    let model = st.resolve_active_model().id;
    let waited = Instant::now();
    while st.slots.free_for(&model) == 0 || st.slots.ceiling_free() == 0 {
        if waited.elapsed() >= sched.slot_wait {
            // TRANSIENT: nothing about this occurrence went stale, the bridge was simply
            // busy serving a person. Recorded and pushed like any skip, but the
            // occurrence stays eligible so a later tick can still run it.
            return RunResult::transient(format!(
                "model {model:?} was saturated by client turns for {}s — a scheduled turn \
                 yields to an interactive one rather than queueing, and will retry while \
                 it is still inside catch_up_secs",
                sched.slot_wait.as_secs()
            ));
        }
        tokio::time::sleep(SCHEDULED_POLL).await;
    }

    let started = Instant::now();
    let start_ms = system_time_to_ms(SystemTime::now());
    let req = JesseRequest::scheduled(&job.mode, prompt);
    // A REJECTION HERE IS A FAILURE, NOT A SKIP — and the line between the two is
    // whose decision it was. The slot wait above is the SCHEDULER deciding to stand
    // down, which is a skip. Everything below is the turn path refusing a turn the
    // scheduler asked it to run (the rate limiter shedding a 429, an unusable
    // request): nothing the operator chose, so it breaks the chain and pushes.
    let job_id = match start_turn(st, req, job.timeout_secs).await {
        Ok(TurnStart::Accepted { job_id, .. }) => job_id,
        Ok(TurnStart::Invalid { status, message }) => {
            return RunResult::failed(format!("turn rejected ({status}): {message}"))
        }
        Err((status, message)) => {
            return RunResult::failed(format!("turn rejected ({status}): {message}"))
        }
    };
    sched.state.started(&job.id, start_ms, &job_id);
    eprintln!(
        "jesse-bridge: schedule FIRE id={} job={} mode={} model={} prompt={}",
        job.id,
        job_id,
        job.mode,
        model,
        job.prompt.label()
    );

    // Wait for the turn to LAND IN THE JOB STORE — which is what "the predecessor has
    // fully completed" means for the next link. The bound is the turn's own run limit
    // across its retries plus slack; `TurnGuard` drives every turn terminal, so reaching
    // it means something is wrong, not that a turn is merely slow.
    let limit = job
        .timeout_secs
        .map(clamp_timeout_secs)
        .unwrap_or(st.cfg.timeout_secs);
    let limit = if limit == 0 {
        HARD_TIMEOUT_CEILING
    } else {
        limit
    };
    let bound = Duration::from_secs(limit.saturating_mul(3)) + TERMINAL_WAIT_SLACK;
    loop {
        match st.jobs.get(&job_id) {
            Some(JobState::Done { .. }) => {
                return RunResult {
                    outcome: Outcome::Ran,
                    reason: String::new(),
                    job_id: Some(job_id),
                    duration_ms: Some(started.elapsed().as_millis() as u64),
                    transient: false,
                }
            }
            Some(JobState::Failed { error, .. }) => {
                return RunResult {
                    outcome: Outcome::Failed,
                    reason: error,
                    job_id: Some(job_id),
                    duration_ms: Some(started.elapsed().as_millis() as u64),
                    transient: false,
                }
            }
            Some(JobState::Cancelled) => {
                return RunResult {
                    outcome: Outcome::Failed,
                    reason: "the turn was cancelled".to_string(),
                    job_id: Some(job_id),
                    duration_ms: Some(started.elapsed().as_millis() as u64),
                    transient: false,
                }
            }
            // Running, or evicted out from under us (only possible for an absurdly long
            // run against a tiny TTL) — keep waiting until the bound.
            Some(JobState::Running) | None => {}
        }
        if started.elapsed() > bound {
            return RunResult {
                outcome: Outcome::Failed,
                reason: format!(
                    "the turn did not reach a terminal state within {}s",
                    bound.as_secs()
                ),
                job_id: Some(job_id),
                duration_ms: Some(started.elapsed().as_millis() as u64),
                transient: false,
            };
        }
        tokio::time::sleep(SCHEDULED_POLL).await;
    }
}

/// Push one scheduled run's outcome, the same way a completed detached turn pushes: same
/// APNs client, same device token, and the turn's `job_id` when there is one so the tap
/// opens the finished turn. Every failure is logged and swallowed — a push must never
/// disturb the record, which is already written.
pub async fn push_schedule_outcome(
    st: &AppState,
    schedule_id: &str,
    outcome: Outcome,
    reason: &str,
    job_id: Option<&str>,
) {
    let Some(apns) = st.apns.as_deref() else {
        // Not a silent drop: the operator asked to be told, and push is not configured.
        eprintln!(
            "jesse-bridge: schedule PUSH id={schedule_id} outcome={} — push is not configured \
             (JESSE_APNS_*), nothing sent",
            outcome.label()
        );
        return;
    };
    let Some(token) = st.devices.get() else {
        eprintln!(
            "jesse-bridge: schedule PUSH id={schedule_id} outcome={} — no device registered, \
             nothing sent",
            outcome.label()
        );
        return;
    };
    let payload = build_scheduled_payload(schedule_id, outcome.label(), reason, job_id);
    match apns.push_payload(&token, payload).await {
        PushOutcome::Sent => eprintln!(
            "jesse-bridge: schedule PUSH id={schedule_id} outcome={} sent",
            outcome.label()
        ),
        PushOutcome::DeadToken => {
            st.devices.clear();
            eprintln!(
                "jesse-bridge: schedule PUSH id={schedule_id} — device token rejected (410 \
                 dead) — cleared"
            );
        }
        PushOutcome::Failed(e) => {
            eprintln!("jesse-bridge: schedule PUSH id={schedule_id} failed: {e} — swallowed")
        }
    }
}

/// A duration as a short human string ("45s", "12m 30s", "3h 5m"). Used in the reasons a
/// skip carries, which a person reads on a lock screen.
pub fn human_ms(ms: u64) -> String {
    let secs = ms / 1000;
    if secs < 60 {
        return format!("{secs}s");
    }
    let (m, s) = (secs / 60, secs % 60);
    if m < 60 {
        return format!("{m}m {s}s");
    }
    format!("{}h {}m", m / 60, m % 60)
}

/// Start the scheduler's tick task, or explain why there is nothing to start.
///
/// The task runs for the life of the process. It is spawned by `main` after the router is
/// built, so a scheduled turn takes exactly the path a client turn takes.
pub fn spawn_scheduler(st: AppState) {
    let sched = st.scheduler.clone();
    for entry in &sched.schedule.invalid {
        eprintln!(
            "jesse-bridge: WARNING — [[schedule]] entry {:?} is DISABLED: {}. The rest of \
             the schedule still runs.",
            entry.id, entry.reason
        );
    }
    if !sched.is_configured() {
        return;
    }
    if !sched.state.is_persistent() {
        eprintln!(
            "jesse-bridge: WARNING — no state dir, so the schedule's record is IN MEMORY \
             ONLY: a restart loses every last-run time and cannot catch up a missed fire. \
             Set JESSE_STATE_DIR."
        );
    }
    // A prompt_file that does not exist YET is legitimate (it may be written before the
    // first fire), so this is a warning and never a disablement — but a typo caught at
    // deploy time beats one caught at 03:00.
    for job in &sched.schedule.jobs {
        if let PromptSource::File(p) = &job.prompt {
            let path = if p.is_absolute() {
                p.clone()
            } else {
                Path::new(&st.cfg.vault).join(p)
            };
            if !path.is_file() {
                eprintln!(
                    "jesse-bridge: WARNING — [[schedule]] {:?} names prompt_file {} , which \
                     does not exist right now. It is read at FIRE time; if it is still \
                     missing then, that run fails with this reason.",
                    job.id,
                    path.display()
                );
            }
        }
    }
    for job in sched.schedule.heads().filter(|j| j.enabled) {
        eprintln!(
            "jesse-bridge: schedule ARMED id={} at={} days={} chain=[{}] catch_up_secs={}",
            job.id,
            job.at_label().unwrap_or_default(),
            if job.days.is_all() {
                "all".to_string()
            } else {
                job.days.names().join(",")
            },
            sched.schedule.chain(&job.id).join(" -> "),
            job.catch_up_secs,
        );
    }
    tokio::spawn(async move {
        loop {
            let sched = st.scheduler.clone();
            sched.tick(&st, system_time_to_ms(SystemTime::now()));
            tokio::time::sleep(SCHEDULER_TICK).await;
        }
    });
}

// ---- `GET /jesse/schedule` ---------------------------------------------------

/// One job's row.
fn schedule_row(sched: &Scheduler, job: &ScheduleJob) -> Value {
    let rec = sched.state.get(&job.id);
    json!({
        "id": job.id,
        "enabled": job.enabled,
        // "head" | "link", and what a link hangs off — the two questions someone asks
        // first when a chain did not produce what they expected.
        "kind": if job.is_head() { "head" } else { "link" },
        "after": job.after(),
        "after_on": job.after().map(|_| job.after_on().label()),
        "at": job.at_label(),
        "days": job.days.names(),
        "mode": job.mode,
        "prompt": job.prompt.label(),
        "notify": job.notify,
        "timeout_secs": job.timeout_secs,
        "catch_up_secs": job.is_head().then_some(job.catch_up_secs),
        "running": sched.is_running(&job.id) || sched.schedule
            .heads()
            .any(|h| sched.is_running(&h.id) && sched.schedule.chain(&h.id).contains(&job.id)),
        "next_fire_ms": sched.next_fire_for(job),
        // An occurrence that was skipped because the bridge was momentarily busy and is
        // STILL ELIGIBLE: the next tick retries it while it is inside `catch_up_secs`.
        // Present here so "it said skipped — is it coming back?" is answerable from the
        // same request as everything else.
        "retry_due_ms": rec.retry_due_ms,
        "last_fire_ms": rec.last_fire_ms,
        "last_completion_ms": rec.last_completion_ms,
        "last_outcome": (!rec.last_outcome.is_empty()).then_some(rec.last_outcome.clone()),
        "last_reason": (!rec.last_reason.is_empty()).then_some(rec.last_reason.clone()),
        "last_duration_ms": rec.last_duration_ms,
        // The job id of the last run, so the turn itself can be fetched from
        // GET /jesse/result/{id} — this is what makes "and how long did it take, and
        // what did it say" answerable without touching the disk.
        "last_job_id": rec.last_job_id,
    })
}

/// `GET /jesse/schedule` — every configured job, what it is, and what happened the last
/// time it came due. Same bearer auth as `/jesse`.
///
/// THE POINT OF THIS ENDPOINT: "did the morning routine run today, and how long did it
/// take" must be answerable in ONE request. The failure being fixed was invisible for a
/// month because answering it meant reading file timestamps, which nobody did.
///
/// It reports ids, times, outcomes and reasons — never a prompt's text and never a
/// reply's text (`last_job_id` links to those, under the same auth).
pub async fn jesse_schedule(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    let sched = &st.scheduler;
    let rows: Vec<Value> = sched
        .schedule
        .jobs
        .iter()
        .map(|j| schedule_row(sched, j))
        .collect();
    let invalid: Vec<Value> = sched
        .schedule
        .invalid
        .iter()
        .map(|e| json!({ "id": e.id, "reason": e.reason }))
        .collect();
    Ok(Json(json!({
        "now_ms": system_time_to_ms(SystemTime::now()),
        // The zone the "HH:MM" times are interpreted in, as its current UTC offset — so
        // a reader can tell at a glance whether "02:30" means what they think it does.
        "utc_offset": Local.timestamp_millis_opt(0).single()
            .map(|t| t.offset().fix().to_string()),
        "persistent": sched.state.is_persistent(),
        "jobs": rows,
        // Entries disabled individually by validation, so a typo is VISIBLE here rather
        // than merely absent from the list above.
        "invalid": invalid,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_ms_reads_like_a_sentence() {
        assert_eq!(human_ms(0), "0s");
        assert_eq!(human_ms(45_000), "45s");
        assert_eq!(human_ms(90_000), "1m 30s");
        assert_eq!(human_ms(3_600_000), "1h 0m");
        assert_eq!(human_ms(11_100_000), "3h 5m");
    }

    fn job(id: &str, notify: bool) -> ScheduleJob {
        let s = validate_schedule(&[ScheduleToml {
            id: Some(id.to_string()),
            at: Some("02:30".to_string()),
            prompt: Some("go".to_string()),
            notify: Some(notify),
            ..Default::default()
        }]);
        s.jobs.into_iter().next().unwrap()
    }

    #[test]
    fn a_ran_or_failed_run_always_pushes() {
        let j = job("nightly", true);
        assert!(should_push(&j, Outcome::Ran, "", false));
        assert!(should_push(&j, Outcome::Failed, "boom", false));
    }

    #[test]
    fn a_chain_break_pushes_once_not_once_per_skipped_link() {
        let j = job("nightly", true);
        // The break itself pushes…
        assert!(should_push(&j, Outcome::Failed, "boom", false));
        // …and every link skipped BECAUSE of it does not.
        assert!(!should_push(
            &j,
            Outcome::Skipped,
            "\"nightly\" failed",
            true
        ));
    }

    #[test]
    fn an_unexpected_skip_pushes_but_a_configured_one_does_not() {
        let j = job("nightly", true);
        assert!(
            should_push(
                &j,
                Outcome::Skipped,
                "missed by 3h 5m (catch_up_secs = 3600s)",
                false
            ),
            "a skip the operator did not ask for is exactly what must be loud"
        );
        assert!(!should_push(&j, Outcome::Skipped, CALENDAR_SKIP, false));
        assert!(!should_push(&j, Outcome::Skipped, DISABLED_SKIP, false));
    }

    /// A link is deliberately NOT retried — re-running a chain would re-apply the work of
    /// members that already succeeded. This is the rule that keeps the retry safe.
    #[test]
    fn only_a_transient_skip_of_the_head_re_arms() {
        let s = validate_schedule(&[
            ScheduleToml {
                id: Some("head".into()),
                at: Some("02:30".into()),
                prompt: Some("go".into()),
                ..Default::default()
            },
            ScheduleToml {
                id: Some("link".into()),
                after: Some("head".into()),
                prompt: Some("go".into()),
                ..Default::default()
            },
        ]);
        let head = s.get("head").unwrap();
        let link = s.get("link").unwrap();

        let transient = RunResult::transient("saturated");
        assert!(retry_should_arm(head, &transient), "the head re-arms");
        assert!(
            !retry_should_arm(link, &transient),
            "a link must NOT re-arm — a retry replays the whole chain"
        );

        // And no other outcome re-arms, whatever it is.
        for r in [
            RunResult::skipped("missed by 3h (catch_up_secs = 3600s)"),
            RunResult::skipped(CALENDAR_SKIP),
            RunResult::skipped(DISABLED_SKIP),
            RunResult::failed("boom"),
        ] {
            assert!(
                !retry_should_arm(head, &r),
                "only a transient skip re-arms, not {:?}",
                r.reason
            );
        }
    }

    #[test]
    fn notify_false_silences_every_outcome() {
        let j = job("quiet", false);
        for (o, r) in [
            (Outcome::Ran, ""),
            (Outcome::Failed, "boom"),
            (Outcome::Skipped, "late"),
        ] {
            assert!(!should_push(&j, o, r, false));
        }
    }
}
