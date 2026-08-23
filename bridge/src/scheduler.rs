use crate::*;
use chrono::{
    DateTime, Datelike, FixedOffset, Local, LocalResult, NaiveDate, NaiveDateTime, Offset,
    TimeZone, Timelike, Weekday,
};

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

// ---- The scheduler's clock ---------------------------------------------------
//
// EVERYTHING WITH A CALENDAR IN IT GOES THROUGH ONE OBJECT, and the reason is that a
// scheduler that reads `Local::now()` at each of a dozen call sites has a dozen different
// answers to "what day is it" over the life of one chain. That is not hypothetical: a
// chain is ONE occurrence — the 03:30 run — but its last member may not start until hours
// later, and asking the wall clock again when the chain reaches that member is what let a
// link be judged against a day the occurrence was never scheduled for. The occurrence's
// instant is now carried into every decision, and the ZONE it is read in is this one
// object's, not `Local`'s, so a test can pin both.

/// The zone the scheduler interprets `"HH:MM"`, `days` and `{date}` in.
///
/// A hand-rolled two-arm `TimeZone` rather than `chrono_tz::Tz`, because `chrono-tz` is a
/// DEV-dependency here: it bundles a whole tz database, and the serving binary has no
/// business carrying one when the host's zone is what production actually wants. `Host` is
/// `chrono::Local` — the OS's zone, which under launchd is whatever `TZ` says
/// (`Europe/Rome` in this deployment). `Fixed` is what a test injects.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchedulerZone {
    /// The host's zone, read from the OS. Production, always.
    Host,
    /// A fixed UTC offset — deterministic, and enough to pin a date and a weekday.
    Fixed(FixedOffset),
    /// A named zone from the bundled tz table. Unit tests only; see the note above for
    /// why this is not a production arm.
    #[cfg(test)]
    Named(chrono_tz::Tz),
}

impl SchedulerZone {
    /// A fixed-offset zone from whole hours east of UTC, for fixtures.
    pub fn hours_east(h: i32) -> SchedulerZone {
        SchedulerZone::Fixed(FixedOffset::east_opt(h * 3600).expect("a representable offset"))
    }
}

impl TimeZone for SchedulerZone {
    // Both arms already resolve to a fixed offset for any given instant, which is exactly
    // what `Local` uses too — so the enum needs no offset type of its own.
    type Offset = FixedOffset;

    fn from_offset(offset: &FixedOffset) -> Self {
        SchedulerZone::Fixed(*offset)
    }

    fn offset_from_local_date(&self, local: &NaiveDate) -> LocalResult<FixedOffset> {
        match self {
            SchedulerZone::Host => Local.offset_from_local_date(local).map(|o| o.fix()),
            SchedulerZone::Fixed(f) => f.offset_from_local_date(local),
            #[cfg(test)]
            SchedulerZone::Named(t) => t.offset_from_local_date(local).map(|o| o.fix()),
        }
    }

    fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> LocalResult<FixedOffset> {
        match self {
            SchedulerZone::Host => Local.offset_from_local_datetime(local).map(|o| o.fix()),
            SchedulerZone::Fixed(f) => f.offset_from_local_datetime(local),
            #[cfg(test)]
            SchedulerZone::Named(t) => t.offset_from_local_datetime(local).map(|o| o.fix()),
        }
    }

    fn offset_from_utc_date(&self, utc: &NaiveDate) -> FixedOffset {
        match self {
            SchedulerZone::Host => Local.offset_from_utc_date(utc).fix(),
            SchedulerZone::Fixed(f) => f.offset_from_utc_date(utc),
            #[cfg(test)]
            SchedulerZone::Named(t) => t.offset_from_utc_date(utc).fix(),
        }
    }

    fn offset_from_utc_datetime(&self, utc: &NaiveDateTime) -> FixedOffset {
        match self {
            SchedulerZone::Host => Local.offset_from_utc_datetime(utc).fix(),
            SchedulerZone::Fixed(f) => f.offset_from_utc_datetime(utc),
            #[cfg(test)]
            SchedulerZone::Named(t) => t.offset_from_utc_datetime(utc).fix(),
        }
    }
}

/// The scheduler's source of "what time is it" and "in what zone".
///
/// Owned by [`Scheduler`] and threaded through every calendar decision. Production builds
/// [`SchedulerClock::host`]; a test pins both halves. P2 replaces the zone's SOURCE (an
/// away profile may declare a different one) — the seam is here so that change is one
/// constructor, not a sweep over every call site.
#[derive(Clone, Debug)]
pub struct SchedulerClock {
    zone: SchedulerZone,
    /// A frozen instant, or `None` for the system clock. Tests only.
    fixed_now_ms: Option<u64>,
}

impl SchedulerClock {
    /// Production: the host's zone and the system clock.
    pub fn host() -> Self {
        SchedulerClock {
            zone: SchedulerZone::Host,
            fixed_now_ms: None,
        }
    }

    /// A clock in `zone` that still reads the system clock.
    pub fn in_zone(zone: SchedulerZone) -> Self {
        SchedulerClock {
            zone,
            fixed_now_ms: None,
        }
    }

    /// A clock frozen at `now_ms` in `zone`.
    pub fn frozen(zone: SchedulerZone, now_ms: u64) -> Self {
        SchedulerClock {
            zone,
            fixed_now_ms: Some(now_ms),
        }
    }

    /// The current instant, unix millis.
    pub fn now_ms(&self) -> u64 {
        self.fixed_now_ms
            .unwrap_or_else(|| system_time_to_ms(SystemTime::now()))
    }

    /// The zone every `"HH:MM"`, `days` and `{date}` is resolved in.
    pub fn tz(&self) -> &SchedulerZone {
        &self.zone
    }

    /// The zone's IANA name, for `GET /jesse/schedule`.
    ///
    /// A reader has to be able to tell whether `"03:30"` means what they think it does, and
    /// a bare UTC offset does not answer that — `+02:00` is Rome in August and something
    /// else entirely in January. `iana-time-zone` is what `chrono`'s `clock` feature
    /// already uses to find the host zone, so naming it directly adds no compiled code.
    pub fn tz_name(&self) -> String {
        match &self.zone {
            SchedulerZone::Host => {
                iana_time_zone::get_timezone().unwrap_or_else(|_| self.utc_offset())
            }
            SchedulerZone::Fixed(_) => self.utc_offset(),
            #[cfg(test)]
            SchedulerZone::Named(t) => t.name().to_string(),
        }
    }

    /// The zone's CURRENT UTC offset as `"+02:00"` — the fallback when no IANA name is
    /// available, and the honest answer for a fixed-offset zone (which has no name).
    pub fn utc_offset(&self) -> String {
        self.zone
            .timestamp_millis_opt(self.now_ms() as i64)
            .single()
            .map(|t| t.offset().fix().to_string())
            .unwrap_or_else(|| "+00:00".to_string())
    }

    /// The local weekday at `ms`, or `None` for an unrepresentable instant.
    pub fn weekday_at(&self, ms: u64) -> Option<Weekday> {
        local_weekday(&self.zone, ms)
    }

    /// Expand the `expect_output` tokens against `ms` — `{date}` (`YYYY-MM-DD`), `{year}`,
    /// `{month}`, `{day}`, all in this zone. An unrepresentable instant leaves the pattern
    /// alone, which then simply matches nothing rather than matching everything.
    pub fn expand_tokens(&self, pattern: &str, ms: u64) -> String {
        let Some(t) = DateTime::from_timestamp_millis(ms as i64) else {
            return pattern.to_string();
        };
        let d = t.with_timezone(&self.zone);
        pattern
            .replace(
                "{date}",
                &format!("{:04}-{:02}-{:02}", d.year(), d.month(), d.day()),
            )
            .replace("{year}", &format!("{:04}", d.year()))
            .replace("{month}", &format!("{:02}", d.month()))
            .replace("{day}", &format!("{:02}", d.day()))
    }

    /// `ms` as a short local `"Fri 03:30"`, for the boot table.
    pub fn short_local(&self, ms: u64) -> String {
        let Some(t) = DateTime::from_timestamp_millis(ms as i64) else {
            return "?".to_string();
        };
        let d = t.with_timezone(&self.zone);
        format!(
            "{} {:04}-{:02}-{:02} {:02}:{:02}",
            weekday_abbrev(d.weekday()),
            d.year(),
            d.month(),
            d.day(),
            d.hour(),
            d.minute()
        )
    }
}

/// The three-letter weekday name the config and the boot table both use.
fn weekday_abbrev(w: Weekday) -> &'static str {
    match w {
        Weekday::Mon => "mon",
        Weekday::Tue => "tue",
        Weekday::Wed => "wed",
        Weekday::Thu => "thu",
        Weekday::Fri => "fri",
        Weekday::Sat => "sat",
        Weekday::Sun => "sun",
    }
}

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
    /// THE LIVE SCHEDULE, swappable. Behind a lock rather than a plain field because
    /// `POST /jesse/schedule/reload` and the tick's mtime watch both replace it wholesale
    /// while chains may be running against the old one — and a chain that started under
    /// one schedule must finish under it, which is exactly what handing each run its own
    /// `Arc` gives. Read it with [`Scheduler::schedule`].
    schedule: Mutex<Arc<Schedule>>,
    pub state: Arc<ScheduleStateStore>,
    /// The one source of "what time is it, in what zone" — see [`SchedulerClock`].
    pub clock: SchedulerClock,
    /// The config file the schedule was loaded from and the mtime it had when it was, so
    /// the tick can notice an edit. `None` when no config file was found at boot (nothing
    /// to watch, so nothing reloads).
    reload: Mutex<Option<ReloadWatch>>,
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

/// What the tick needs to notice that the config file changed under it.
#[derive(Clone, Debug)]
struct ReloadWatch {
    path: PathBuf,
    /// The file's mtime, as unix millis, when the current schedule was loaded from it.
    /// `None` when the file could not be stat'ed — a file that appears later then reads as
    /// a change, which is the direction that costs nothing.
    mtime_ms: Option<u64>,
}

/// Read a file's mtime as unix millis, or `None` if it cannot be stat'ed.
fn mtime_ms(path: &Path) -> Option<u64> {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .map(system_time_to_ms)
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

    /// [`new`](Self::new) plus the append-only fire ledger. This is what production
    /// builds; the plain constructor stays ledger-free so the tests write one file, not
    /// two. See [`Config::schedule_ledger_file`] for why the ledger exists at all.
    pub fn new_with_ledger(
        schedule: Arc<Schedule>,
        state_file: Option<PathBuf>,
        ledger_file: Option<PathBuf>,
    ) -> Arc<Self> {
        let sched = Self::new_with(schedule, state_file, SCHEDULED_SLOT_WAIT);
        // The store is behind an Arc by the time `new_with` returns, so the ledger is
        // attached by rebuilding that one field rather than mutating through the Arc.
        Arc::new(Scheduler {
            schedule: Mutex::new(sched.schedule()),
            state: Arc::new(
                ScheduleStateStore::new(sched.state.file_path()).with_ledger(ledger_file),
            ),
            clock: sched.clock.clone(),
            reload: Mutex::new(None),
            turn_lock: sched.turn_lock.clone(),
            running: Mutex::new(Vec::new()),
            boot_ms: sched.boot_ms,
            slot_wait: sched.slot_wait,
        })
    }

    /// [`new`](Self::new) with an explicit slot-starvation patience. The shipped value is
    /// [`SCHEDULED_SLOT_WAIT`]; a shorter one lets a test prove the yield-to-a-client
    /// behavior without spending a minute waiting for it.
    pub fn new_with(
        schedule: Arc<Schedule>,
        state_file: Option<PathBuf>,
        slot_wait: Duration,
    ) -> Arc<Self> {
        let clock = SchedulerClock::host();
        Arc::new(Scheduler {
            schedule: Mutex::new(schedule),
            state: Arc::new(ScheduleStateStore::new(state_file)),
            boot_ms: clock.now_ms(),
            clock,
            reload: Mutex::new(None),
            turn_lock: Arc::new(Semaphore::new(1)),
            running: Mutex::new(Vec::new()),
            slot_wait,
        })
    }

    /// Point this scheduler at the config file it was loaded from, so the tick can notice
    /// an edit. Called once by `spawn_scheduler`; a scheduler with no watch never reloads.
    pub fn watch_config(&self, path: Option<PathBuf>) {
        *self.reload.lock_ok() = path.map(|p| {
            let mtime_ms = mtime_ms(&p);
            ReloadWatch { path: p, mtime_ms }
        });
    }

    /// THE LIVE SCHEDULE. Cloned out of the lock rather than borrowed through it, so a
    /// caller holds a consistent snapshot for as long as it needs one and a concurrent
    /// reload never invalidates a chain mid-run.
    pub fn schedule(&self) -> Arc<Schedule> {
        self.schedule.lock_ok().clone()
    }

    /// Whether any job is configured at all. A deploy with no `[[schedule]]` never
    /// starts the tick task, so the whole feature is absent rather than idling.
    pub fn is_configured(&self) -> bool {
        !self.schedule().jobs.is_empty()
    }

    /// Whether this chain is running right now.
    pub fn is_running(&self, head: &str) -> bool {
        self.running.lock_ok().iter().any(|id| id == head)
    }

    /// The HEAD of the chain `id` belongs to — `id` itself for a head, else the entry
    /// reached by walking `after` upwards. `None` if `id` is not in the schedule.
    ///
    /// The single-flight set is keyed on the head, so every question about "is this job's
    /// chain busy" has to come through here rather than through the job's own id.
    pub fn head_of(&self, schedule: &Schedule, id: &str) -> Option<String> {
        let mut cur = schedule.get(id)?;
        // `after` gives each node at most one predecessor and cycles are refused at
        // startup, so this terminates; the bound is belt-and-braces against a schedule
        // built by hand in a test.
        for _ in 0..schedule.jobs.len().saturating_add(1) {
            match cur.after() {
                None => return Some(cur.id.clone()),
                Some(parent) => cur = schedule.get(parent)?,
            }
        }
        None
    }

    /// Whether any chain containing `id` is running.
    pub fn chain_is_running(&self, schedule: &Schedule, id: &str) -> bool {
        self.head_of(schedule, id)
            .map(|h| self.is_running(&h))
            .unwrap_or(false)
    }

    /// This job's EFFECTIVE enabled state: the runtime override while it is live, else the
    /// config file's `enabled`. See [`EnableOverride`].
    pub fn effective_enabled(&self, job: &ScheduleJob, now_ms: u64) -> bool {
        match self.state.get(&job.id).r#override {
            Some(ov) if ov.active_at(now_ms) => ov.enabled,
            _ => job.enabled,
        }
    }

    /// The occurrence anchor for a head: the last occurrence it processed, or this
    /// process's boot time when it has never come due.
    fn anchor_for(&self, id: &str) -> u64 {
        self.state.get(id).last_due_ms.unwrap_or(self.boot_ms)
    }

    /// The next fire a head is waiting for, for the observability endpoint. `None` for a
    /// link, a disabled job, or an unresolvable one.
    pub fn next_fire_for(&self, job: &ScheduleJob) -> Option<u64> {
        if !self.effective_enabled(job, self.clock.now_ms()) || !job.is_head() {
            return None;
        }
        job.next_fire_ms(self.clock.tz(), self.anchor_for(&job.id))
    }

    /// ONE PASS over the heads. Anything due is claimed and its chain is spawned; the
    /// returned handles are the chains started by THIS pass (production drops them —
    /// dropping a `JoinHandle` detaches, it does not cancel — while tests await them, so
    /// the suite never races the wall clock).
    pub fn tick(self: &Arc<Self>, st: &AppState, now_ms: u64) -> Vec<tokio::task::JoinHandle<()>> {
        // THE CONFIG WATCH, before anything is judged due. A reload that added, removed or
        // re-timed a head must take effect on THIS pass rather than one tick later, so an
        // edit made a few seconds before a fire is honoured rather than missed by 20s.
        self.reload_if_config_changed(st, now_ms);
        let schedule = self.schedule();
        let mut started = Vec::new();
        for head in schedule.heads() {
            if !self.effective_enabled(head, now_ms) {
                continue; // off means off — not "due and skipped" every 20 seconds.
            }
            let anchor = self.anchor_for(&head.id);
            let fresh = due_occurrence(self.clock.tz(), head, anchor, now_ms);
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
            let run = ChainRun::scheduled(head.id.clone(), due);
            let schedule = schedule.clone();
            started.push(tokio::spawn(async move {
                run_chain(sched, st2, schedule, run).await;
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
        // THE STREAK, which is a different alert from the outcome above and deliberately
        // separate. A nightly "failed" push that arrives every night is a push that stops
        // being read; "this is the third night in a row" is the one that gets acted on, and
        // it is sent at a WIDENING cadence so a job left broken keeps saying so without
        // becoming the noise it was meant to cut through.
        let streak = self.state.get(&job.id).consecutive_failures;
        if job.is_head() && job.notify && ESCALATE_AT.contains(&streak) {
            let st = st.clone();
            let id = job.id.clone();
            let reason = reason.to_string();
            tokio::spawn(async move {
                push_schedule_escalation(&st, &id, streak, &reason).await;
            });
        }
    }

    /// Record every job hanging off `from` as skipped because `breaker` broke the chain.
    /// Used when a chain cannot start at all (the head was skipped): there is no
    /// predecessor outcome to consult per link, and `after_on = "any"` does not apply —
    /// it means "run even if the previous job failed", not "run even if the scheduler
    /// never got to this chain".
    fn skip_rest_of_chain(&self, st: &AppState, from: &str, breaker: &str, cause: Outcome) {
        let schedule = self.schedule();
        for id in schedule.chain(from).into_iter().skip(1) {
            let Some(job) = schedule.get(&id) else {
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
    if outcome == Outcome::Skipped
        && (reason == CALENDAR_SKIP || reason == DISABLED_SKIP || reason == OUTPUT_FRESH_SKIP)
    {
        return false;
    }
    true
}

/// The consecutive-failure counts that send an escalation push, and nothing between them.
///
/// WIDENING, NOT REPEATING. Three is where a streak stops being bad luck; after that the
/// gaps double, so a job someone has decided not to fix yet keeps a place in the record
/// without training its reader to swipe the alert away. The list is exhaustive on purpose —
/// past 24 the counter keeps climbing and the endpoint keeps reporting it, but nothing
/// further is pushed, because a person who has ignored four of these does not need a fifth.
const ESCALATE_AT: [u32; 4] = [3, 6, 12, 24];

/// The reason text for a link the `days` filter excluded today. Compared by value in
/// [`should_push`], so it is a const rather than a formatted string.
pub const CALENDAR_SKIP: &str = "not scheduled on this weekday";
/// The reason text for a link that is `enabled = false`, in the config or through the
/// runtime override. Both produce the same skip on purpose: a disabled member breaking an
/// `after_on = "success"` chain is the documented meaning of disabling one, and an
/// override that behaved differently from the config key would be a second, silent
/// semantics for the same word.
pub const DISABLED_SKIP: &str = "disabled";

/// The reason text for a fire skipped because the job's `expect_output` is ALREADY FRESH —
/// something at or after this occurrence's instant already matches its contract.
///
/// Not pushed, for the same reason a `days` skip is not: it is the config working. It is
/// what makes the fire endpoint safe to lean on and what makes a catch-up run after an
/// outage idempotent — the chain that already wrote tonight's note does not write it twice.
pub const OUTPUT_FRESH_SKIP: &str = "output fresh";

/// ONE CHAIN RUN — everything the members are judged against, decided before the first of
/// them starts.
///
/// It exists because a chain is ONE OCCURRENCE and the run may outlive the minute it was
/// scheduled for. Every instant a member consults is captured here, at the top, rather than
/// re-read from the wall clock when the chain happens to reach that member.
pub struct ChainRun {
    /// The chain HEAD — the single-flight key, whatever member the run starts at.
    head: String,
    /// The member the run STARTS at. The head for a scheduled fire; an operator may start
    /// mid-chain.
    start_at: String,
    /// The occurrence being acted on: what the catch-up window is measured from and what a
    /// transient retry re-arms.
    due: DueFire,
    /// THE INSTANT EVERY MEMBER'S `days` FILTER IS EVALUATED AT.
    ///
    /// THIS IS THE FRIDAY BUG. It used to be `SystemTime::now()`, read afresh as the chain
    /// reached each member — so a chain that started at 23:50 judged its last link against
    /// tomorrow, and any link whose `days` named the occurrence's day was skipped as "not
    /// scheduled on this weekday" on precisely the day it was scheduled for. A chain is one
    /// occurrence, so the occurrence's instant is what the calendar sees.
    calendar_ms: u64,
    /// The instant the `expect_output` contract is written for: what `{date}` expands from
    /// and what a match's mtime is compared against to decide the output is already fresh.
    contract_ms: u64,
    /// `Some` when a person asked for this run through `POST /jesse/schedule/{id}/fire`.
    operator: Option<OperatorFire>,
}

/// The two things that differ about an operator-initiated run.
pub struct OperatorFire {
    /// Ignore the `expect_output` freshness gate — "run it again anyway".
    force: bool,
}

/// The ledger/record reason a member carries when a person asked for the run.
pub const OPERATOR_FIRE_REASON: &str = "fired by operator";

impl ChainRun {
    /// The ordinary case: the clock came due for a head.
    fn scheduled(head: String, due: DueFire) -> ChainRun {
        ChainRun {
            start_at: head.clone(),
            head,
            calendar_ms: due.due_ms,
            contract_ms: due.due_ms,
            due,
            operator: None,
        }
    }

    /// Whether this run was asked for by a person.
    fn is_operator(&self) -> bool {
        self.operator.is_some()
    }

    /// Whether the `expect_output` freshness gate applies to this run.
    fn honors_freshness(&self) -> bool {
        !self.operator.as_ref().map(|o| o.force).unwrap_or(false)
    }
}

/// What happens to one chain member, decided WITHOUT running anything.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MemberDecision {
    /// Its turn is submitted.
    Run,
    /// It is recorded as skipped, with this reason.
    Skip {
        reason: String,
        /// Caused by an earlier member of the same run — recorded, but not pushed, so a
        /// broken chain alerts once rather than once per link.
        cascaded: bool,
        /// The id to record as having broken the chain for everything behind this member.
        breaker: String,
    },
}

/// THE PER-MEMBER GATE, pure.
///
/// Every reason a chain member does not run, in the order they are checked, decided from
/// values rather than from the clock or the filesystem — which is what lets the whole
/// production chain be walked in a unit test against a fixed instant. `run_chain` is the
/// only caller; the output-contract gate is the one check that stays there, because it
/// reads mtimes.
///
/// `outcomes` and `broken_by` are what the members before this one produced IN THIS RUN.
/// `start_at` is the member the run began at: its predecessor did not run in this run and
/// must not be judged as though it had failed — an operator who asked for one link by name
/// asked for that link, not for a cascade skip naming a job nobody ran.
pub fn member_decision(
    job: &ScheduleJob,
    outcomes: &HashMap<String, Outcome>,
    broken_by: &HashMap<String, String>,
    start_at: &str,
    enabled: bool,
    weekday: Option<Weekday>,
) -> MemberDecision {
    // 1. The predecessor gate — skipped for the member the run starts at.
    if job.id != start_at {
        if let Some(parent) = job.after() {
            let parent_outcome = outcomes.get(parent).copied().unwrap_or(Outcome::Skipped);
            if job.after_on() == AfterOn::Success && !parent_outcome.is_success() {
                let breaker = broken_by
                    .get(parent)
                    .cloned()
                    .unwrap_or_else(|| parent.to_string());
                return MemberDecision::Skip {
                    reason: format!("{breaker:?} {}", parent_outcome.label()),
                    cascaded: true,
                    breaker,
                };
            }
        }
    }
    // 2. Disabled — in the config or by a live override.
    if !enabled {
        return MemberDecision::Skip {
            reason: DISABLED_SKIP.to_string(),
            cascaded: false,
            breaker: job.id.clone(),
        };
    }
    // 3. The weekday filter, which applies to links as much as to heads — a Monday-only
    //    job on a daily chain is the reason `days` is not a head-only key. An
    //    unrepresentable instant lets the job run rather than silently dropping it.
    if !weekday.map(|w| job.days.contains(w)).unwrap_or(true) {
        return MemberDecision::Skip {
            reason: CALENDAR_SKIP.to_string(),
            cascaded: false,
            breaker: job.id.clone(),
        };
    }
    MemberDecision::Run
}

/// Run one chain: the member it starts at and everything behind that, strictly
/// sequentially, under the scheduler's one-turn-at-a-time lock.
async fn run_chain(sched: Arc<Scheduler>, st: AppState, schedule: Arc<Schedule>, run: ChainRun) {
    let head_id = run.head.clone();
    let due = run.due;
    let _flight = FlightGuard {
        sched: sched.clone(),
        head: head_id.clone(),
    };
    let Some(head) = schedule.get(&head_id) else {
        return;
    };

    // THE GLOBAL SERIALIZATION POINT. Held for the WHOLE chain, so a second chain whose
    // head comes due meanwhile waits here instead of starting — which is the property
    // that keeps two agents off the same working tree. The wait is bounded by what is
    // left of this head's catch-up window: a chain that is still queued when its window
    // expires is skipped and recorded, never started hours late.
    let now = sched.clock.now_ms();
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

    // THE CALENDAR INSTANT IS READ ONCE, HERE, and it is the OCCURRENCE's — not the wall
    // clock at the moment the chain reaches each member. See `ChainRun::calendar_ms`.
    let weekday = sched.clock.weekday_at(run.calendar_ms);

    for id in schedule.chain(&run.start_at) {
        let Some(job) = schedule.get(&id) else {
            continue;
        };
        let enabled = sched.effective_enabled(job, sched.clock.now_ms());
        let decision = member_decision(job, &outcomes, &broken_by, &run.start_at, enabled, weekday);
        let mut cascaded = false;
        let result = match decision {
            MemberDecision::Skip {
                reason,
                cascaded: c,
                breaker,
            } => {
                cascaded = c;
                broken_by.insert(id.clone(), breaker);
                RunResult::skipped(reason)
            }
            // 4. The OUTPUT CONTRACT, checked here rather than in the pure gate because it
            //    is the one that reads the disk: a job whose declared output is already at
            //    or after this occurrence's instant has nothing to do.
            MemberDecision::Run => match output_already_fresh(&sched, &st, job, &run) {
                Some(path) => {
                    broken_by.insert(id.clone(), id.clone());
                    eprintln!(
                        "jesse-bridge: schedule FRESH id={} — {} already matches this \
                         occurrence's contract; not re-running",
                        job.id, path
                    );
                    sched.state.set_output_path(&job.id, Some(path));
                    RunResult::skipped(OUTPUT_FRESH_SKIP)
                }
                None => run_one(&sched, &st, job, &run).await,
            },
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
        if !run.is_operator() && retry_should_arm(job, &result) {
            sched.state.arm_retry(&id, due.due_ms);
            eprintln!(
                "jesse-bridge: schedule RETRY-ARMED id={} due_ms={} — still eligible for {}",
                id,
                due.due_ms,
                human_ms(
                    (due.due_ms + job.catch_up_secs.saturating_mul(1000))
                        .saturating_sub(sched.clock.now_ms())
                ),
            );
        }
    }
    drop(permit);
}

/// Run ONE scheduled job's turn: resolve the prompt, wait (briefly) for a model slot,
/// submit it on the client turn path, and wait for it to land in the job store.
async fn run_one(
    sched: &Arc<Scheduler>,
    st: &AppState,
    job: &ScheduleJob,
    run: &ChainRun,
) -> RunResult {
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
    //
    // The slot wait is measured against the model this turn will ACTUALLY run on, which a
    // per-job `model` may make different from the globally active one. Waiting on the
    // active model's slots for a turn that will not use them would be waiting on the wrong
    // queue — and the whole point of the wait is not to contend with a person.
    let model = match job.model.as_deref() {
        Some(id) => match st.resolve_requested_model(id) {
            Ok(m) => m.id,
            // A per-job model validated at LOAD can still be unavailable at FIRE time (its
            // backend went unhealthy). That is a failure, not a silent fallback onto a
            // different model: the operator named this one.
            Err((status, message)) => {
                return RunResult::failed(format!(
                    "model {id:?} is unavailable ({status}): {message}"
                ))
            }
        },
        None => st.resolve_active_model().id,
    };
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
    let req = JesseRequest::scheduled(&job.mode, prompt, job.model.clone());
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
                // THE OUTPUT CONTRACT, on the way out. The turn finished cleanly; whether
                // the job DID ITS WORK is a separate question, and one only the job's own
                // declaration can answer. A job with no `expect_output` skips all of this
                // and is `ran`, exactly as before.
                let (outcome, reason) = match verify_output(sched, st, job, run, start_ms) {
                    OutputVerdict::NoContract => (Outcome::Ran, String::new()),
                    OutputVerdict::Satisfied(path) => {
                        sched.state.set_output_path(&job.id, Some(path));
                        (Outcome::Ran, String::new())
                    }
                    OutputVerdict::Missing(patterns) => {
                        sched.state.set_output_path(&job.id, None);
                        (
                            Outcome::FiredNoOutput,
                            format!(
                                "the turn completed but wrote nothing matching {patterns} \
                                 at or after this fire"
                            ),
                        )
                    }
                };
                let reason = if run.is_operator() && outcome == Outcome::Ran {
                    OPERATOR_FIRE_REASON.to_string()
                } else {
                    reason
                };
                return RunResult {
                    outcome,
                    reason,
                    job_id: Some(job_id),
                    duration_ms: Some(started.elapsed().as_millis() as u64),
                    transient: false,
                };
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

// ---- The output contract (`expect_output`) -----------------------------------
//
// A scheduled turn that returns cleanly and writes nothing is recorded as `ran`. That is
// true about the turn and useless about the job: `overnight-vault-lint` exists to produce
// a note, and a night without the note is a night the routine did not happen, however
// tidily the child exited. A job that DECLARES what it writes closes the gap from both
// ends — a fire whose output is already there is skipped instead of redone, and a fire
// that produced nothing is [`Outcome::FiredNoOutput`] instead of `ran`.
//
// THE MATCHER IS DELIBERATELY SMALL. No glob crate is in this lock file and one is not
// worth adding for this: the patterns are operator-written note paths, so `*` and `?`
// WITHIN one path segment over a directory listing is the whole requirement. `**` is not
// supported, and saying so is better than half-supporting it.

/// What the post-fire contract check concluded.
enum OutputVerdict {
    /// The job declared no `expect_output`.
    NoContract,
    /// A match exists whose mtime is at or after this fire — the vault-relative path.
    Satisfied(String),
    /// Nothing matched. Carries the patterns, for the reason string.
    Missing(String),
}

/// The directory `expect_output` patterns resolve under: the vault's NOTES directory,
/// `<vault>/vault/`, never the repo root — the same hop `schedule_ledger_file` makes, and
/// the reason a pattern is written `Inbox/…` rather than `vault/Inbox/…`.
fn output_root(st: &AppState) -> Option<PathBuf> {
    (!st.cfg.vault.is_empty())
        .then(|| PathBuf::from(&st.cfg.vault).join(crate::config::VAULT_SUBDIR))
}

/// Every existing file matching `pattern` under `root`, with its mtime.
///
/// Walks the pattern one path segment at a time over real directory listings. A segment
/// with no wildcard is joined without a listing (so the common all-literal pattern costs
/// one `stat`); a segment with one lists its parent and filters. Traversal was refused at
/// validation, and the result is checked against `root` again here — a symlinked directory
/// inside the vault could otherwise carry a match outside it.
fn glob_matches(root: &Path, pattern: &str) -> Vec<(PathBuf, u64)> {
    let mut frontier = vec![root.to_path_buf()];
    for segment in pattern.split('/').filter(|s| !s.is_empty() && *s != ".") {
        let mut next = Vec::new();
        if segment.contains('*') || segment.contains('?') {
            for dir in &frontier {
                let Ok(entries) = std::fs::read_dir(dir) else {
                    continue;
                };
                for e in entries.flatten() {
                    let name = e.file_name();
                    let Some(name) = name.to_str() else { continue };
                    if segment_matches(segment, name) {
                        next.push(e.path());
                    }
                }
            }
        } else {
            for dir in &frontier {
                let candidate = dir.join(segment);
                if candidate.exists() {
                    next.push(candidate);
                }
            }
        }
        frontier = next;
        if frontier.is_empty() {
            return Vec::new();
        }
    }
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    frontier
        .into_iter()
        .filter(|p| p.is_file())
        .filter(|p| {
            p.canonicalize()
                .map(|c| c.starts_with(&root))
                .unwrap_or(false)
        })
        .filter_map(|p| {
            let m = std::fs::metadata(&p).ok()?.modified().ok()?;
            Some((p, system_time_to_ms(m)))
        })
        .collect()
}

/// Whether one path SEGMENT matches one pattern segment. `*` matches any run of
/// characters (never a `/` — segments do not contain one), `?` matches exactly one.
/// Iterative with backtracking on the last `*`, so a pathological pattern cannot blow the
/// stack or the clock.
fn segment_matches(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    let (mut pi, mut ni) = (0usize, 0usize);
    let (mut star, mut resume) = (None, 0usize);
    // A wildcard never crosses a path separator. The caller only ever feeds this one
    // directory entry at a time (which cannot contain one), so this is the invariant being
    // ENFORCED rather than assumed — a matcher that would swallow a `/` is one `read_dir`
    // away from a pattern reaching further than it was written to.
    let sep = |c: char| c == '/';
    while ni < n.len() {
        if pi < p.len() && ((p[pi] == '?' && !sep(n[ni])) || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            resume = ni;
            pi += 1;
        } else if let Some(sp) = star {
            // Backtrack: let the last `*` swallow one more character — unless that
            // character is a separator, which no wildcard may cross.
            if sep(n[resume]) {
                return false;
            }
            pi = sp + 1;
            resume += 1;
            ni = resume;
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|c| *c == '*')
}

/// The best match for one job's contract at `ms`: the newest file matching any pattern
/// whose mtime is at or after `since_ms`, as a path relative to the vault's notes dir.
fn newest_match_since(
    sched: &Scheduler,
    st: &AppState,
    job: &ScheduleJob,
    token_ms: u64,
    since_ms: u64,
) -> Option<String> {
    let root = output_root(st)?;
    let mut best: Option<(String, u64)> = None;
    for pattern in &job.expect_output {
        let expanded = sched.clock.expand_tokens(pattern, token_ms);
        for (path, mtime) in glob_matches(&root, &expanded) {
            if mtime < since_ms {
                continue;
            }
            let rel = path
                .strip_prefix(&root)
                .unwrap_or(&path)
                .display()
                .to_string();
            if best.as_ref().map(|(_, m)| mtime > *m).unwrap_or(true) {
                best = Some((rel, mtime));
            }
        }
    }
    best.map(|(p, _)| p)
}

/// BEFORE the fire: is this occurrence's output already there?
///
/// Compared against the occurrence's own instant, so a catch-up run of last night's chain
/// after a morning restart does not rewrite a note that was already written — and so an
/// operator `fire` at 09:00 sees that 03:30 already produced today's file. `None` means
/// nothing matches and the job should run.
fn output_already_fresh(
    sched: &Scheduler,
    st: &AppState,
    job: &ScheduleJob,
    run: &ChainRun,
) -> Option<String> {
    if job.expect_output.is_empty() || !run.honors_freshness() {
        return None;
    }
    newest_match_since(sched, st, job, run.contract_ms, run.contract_ms)
}

/// AFTER the fire: did the turn actually write what the job says it writes?
///
/// Measured from `fire_ms` — when THIS turn started — rather than from the occurrence, so a
/// job that runs late still has to produce something new, and yesterday's file cannot
/// satisfy today's contract.
fn verify_output(
    sched: &Scheduler,
    st: &AppState,
    job: &ScheduleJob,
    run: &ChainRun,
    fire_ms: u64,
) -> OutputVerdict {
    if job.expect_output.is_empty() {
        return OutputVerdict::NoContract;
    }
    match newest_match_since(sched, st, job, run.contract_ms, fire_ms) {
        Some(p) => OutputVerdict::Satisfied(p),
        None => OutputVerdict::Missing(
            job.expect_output
                .iter()
                .map(|p| sched.clock.expand_tokens(p, run.contract_ms))
                .collect::<Vec<_>>()
                .join(", "),
        ),
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

/// Push the CONSECUTIVE-FAILURE escalation. Same client, same swallow-every-error
/// discipline as [`push_schedule_outcome`] — the record is already written.
pub async fn push_schedule_escalation(st: &AppState, schedule_id: &str, streak: u32, reason: &str) {
    push_alert(
        st,
        schedule_id,
        build_escalation_payload(schedule_id, streak, reason),
        &format!("escalation streak={streak}"),
    )
    .await;
}

/// Push the CONFIG RELOAD FAILURE. The old schedule keeps running, which is the safe
/// behaviour and also the silent one — nothing else would tell anyone the file they just
/// edited is not the file the bridge is using.
pub async fn push_reload_failure(st: &AppState, error: &str) {
    push_alert(
        st,
        "(schedule)",
        build_reload_failure_payload(error),
        "config reload failed",
    )
    .await;
}

/// Send one already-built alert payload, logging and swallowing every failure.
async fn push_alert(st: &AppState, schedule_id: &str, payload: Vec<u8>, what: &str) {
    let Some(apns) = st.apns.as_deref() else {
        eprintln!(
            "jesse-bridge: schedule PUSH id={schedule_id} {what} — push is not configured \
             (JESSE_APNS_*), nothing sent"
        );
        return;
    };
    let Some(token) = st.devices.get() else {
        eprintln!(
            "jesse-bridge: schedule PUSH id={schedule_id} {what} — no device registered, \
             nothing sent"
        );
        return;
    };
    match apns.push_payload(&token, payload).await {
        PushOutcome::Sent => {
            eprintln!("jesse-bridge: schedule PUSH id={schedule_id} {what} sent")
        }
        PushOutcome::DeadToken => {
            st.devices.clear();
            eprintln!(
                "jesse-bridge: schedule PUSH id={schedule_id} {what} — device token rejected \
                 (410 dead) — cleared"
            );
        }
        PushOutcome::Failed(e) => {
            eprintln!("jesse-bridge: schedule PUSH id={schedule_id} {what} failed: {e} — swallowed")
        }
    }
}

// ---- The boot table ----------------------------------------------------------

/// ONE LINE PER JOB, heads and links alike.
///
/// THIS IS THE LINE THAT WOULD HAVE CAUGHT THE FRIDAY BUG. The old boot output printed only
/// HEADS, so a `days` key on a LINK — the key that decides whether the second, third and
/// fourth job of a chain run tonight — appeared nowhere at all: not in the log, not at
/// startup, nowhere but the file itself. A misplaced key must be VISIBLE, so every entry
/// gets a row and every row carries its resolved days by name.
pub fn boot_table(sched: &Scheduler) -> Vec<String> {
    let schedule = sched.schedule();
    let mut rows = vec![format!(
        "{:<28} {:<5} {:<26} {:<28} {:<21} {}",
        "id", "kind", "trigger", "days", "next fire", "enabled"
    )];
    for job in &schedule.jobs {
        let trigger = match job.at_label() {
            Some(at) => format!("at {at}"),
            None => format!(
                "after {} ({})",
                job.after().unwrap_or_default(),
                job.after_on().label()
            ),
        };
        let next = sched
            .next_fire_for(job)
            .map(|ms| sched.clock.short_local(ms))
            .unwrap_or_else(|| "-".to_string());
        let enabled = sched.effective_enabled(job, sched.clock.now_ms());
        rows.push(format!(
            "{:<28} {:<5} {:<26} {:<28} {:<21} {}{}{}",
            job.id,
            if job.is_head() { "head" } else { "link" },
            trigger,
            job.days.names().join(","),
            next,
            enabled,
            job.promoted_from
                .as_deref()
                .map(|p| format!("  promoted-from={p}"))
                .unwrap_or_default(),
            job.model
                .as_deref()
                .map(|m| format!("  model={m}"))
                .unwrap_or_default(),
        ));
    }
    rows
}

/// Print the boot table, prefixed so it is greppable in a log that carries everything else
/// this service says.
fn print_boot_table(sched: &Scheduler) {
    for row in boot_table(sched) {
        eprintln!("jesse-bridge: schedule | {row}");
    }
}

// ---- Hot reload --------------------------------------------------------------

/// What one reload attempt concluded.
pub struct ReloadOutcome {
    /// Whether the live schedule was replaced.
    pub reloaded: bool,
    /// Why not, when it was not. Empty on success.
    pub errors: Vec<String>,
}

impl Scheduler {
    /// Reload the schedule from the watched config file if its mtime changed. Called at the
    /// top of every tick; a no-op when nothing is watched or nothing changed.
    fn reload_if_config_changed(self: &Arc<Self>, st: &AppState, now_ms: u64) {
        let changed = {
            let watch = self.reload.lock_ok();
            match watch.as_ref() {
                None => None,
                Some(w) => {
                    let current = mtime_ms(&w.path);
                    (current != w.mtime_ms).then(|| (w.path.clone(), current))
                }
            }
        };
        let Some((path, current)) = changed else {
            return;
        };
        eprintln!(
            "jesse-bridge: schedule RELOAD — {} changed on disk",
            path.display()
        );
        // The mtime is recorded whatever the outcome: a file that fails to validate must
        // not be re-read (and re-pushed about) every 20 seconds until it is fixed.
        if let Some(w) = self.reload.lock_ok().as_mut() {
            w.mtime_ms = current;
        }
        let outcome = self.reload_now(st, now_ms);
        if !outcome.reloaded {
            let first = outcome
                .errors
                .first()
                .cloned()
                .unwrap_or_else(|| "unknown error".to_string());
            let st = st.clone();
            tokio::spawn(async move { push_reload_failure(&st, &first).await });
        }
    }

    /// RELOAD THE `[[schedule]]` ARRAY AND NOTHING ELSE.
    ///
    /// Only the schedule is re-read. Every other setting — the token, the vault, the model
    /// registry, the concurrency plan — stays exactly as it was booted, because those are
    /// wired into a running server (sockets, semaphores, spawned children) in ways a swap
    /// cannot honestly reproduce, and half-reloading a process is worse than not reloading
    /// it. What this buys is the thing an operator actually edits: a job's time, its days,
    /// a new job, a retired one.
    ///
    /// A file that does not validate KEEPS THE OLD SCHEDULE. The alternative — swapping in
    /// a degraded schedule — would mean a typo silently retires jobs, which is the exact
    /// class of failure the whole feature exists to end.
    pub fn reload_now(self: &Arc<Self>, st: &AppState, now_ms: u64) -> ReloadOutcome {
        let Some(path) = self.reload.lock_ok().as_ref().map(|w| w.path.clone()) else {
            return ReloadOutcome {
                reloaded: false,
                errors: vec![
                    "no config file was loaded at boot, so there is nothing to reload".to_string(),
                ],
            };
        };
        let raw = match load_schedule_from(&path) {
            Ok(raw) => raw,
            Err(e) => {
                return ReloadOutcome {
                    reloaded: false,
                    errors: vec![e],
                }
            }
        };
        let model_ids: Vec<String> = st
            .cfg
            .model_registry
            .models
            .iter()
            .map(|m| m.id.clone())
            .collect();
        let vault = PathBuf::from(&st.cfg.vault);
        let next = validate_schedule_with(
            &raw,
            &ValidationContext {
                vault: (!st.cfg.vault.is_empty()).then_some(vault.as_path()),
                model_ids: Some(&model_ids),
            },
        );
        if next.is_fatal() {
            return ReloadOutcome {
                reloaded: false,
                errors: next.fatal.clone(),
            };
        }

        // ANCHOR THE NEW HEADS. A head the old schedule did not have has no record, so its
        // anchor would fall back to this PROCESS's boot — and a job added at 14:00 whose
        // time is 10:00 would resolve 10:00 today as a missed occurrence and record a skip
        // for a job one second old. Anchoring it at the reload makes it behave exactly like
        // a head present at a fresh boot: next fire forward from now. A head that HAS a
        // record keeps it, which is what "keep JobRecords by id" means.
        for head in next.heads() {
            self.state.anchor_if_absent(&head.id, now_ms);
        }

        *self.schedule.lock_ok() = Arc::new(next);
        let schedule = self.schedule();
        self.state.ledger_event(
            "(schedule)",
            "reloaded",
            &format!(
                "{} job(s), {} disabled by validation, from {}",
                schedule.jobs.len(),
                schedule.invalid.len(),
                path.display()
            ),
            now_ms,
        );
        for entry in &schedule.invalid {
            eprintln!(
                "jesse-bridge: WARNING — [[schedule]] entry {:?} is DISABLED: {}. The rest \
                 of the schedule still runs.",
                entry.id, entry.reason
            );
        }
        print_boot_table(self);
        ReloadOutcome {
            reloaded: true,
            errors: Vec::new(),
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
    // The file the schedule came from, so the tick can notice an edit. Resolved by exactly
    // the same search order the config used at boot, so the watch and the load can never
    // disagree about which file is authoritative.
    sched.watch_config(loaded_config_path(&st.cfg.home));
    let schedule = sched.schedule();
    for entry in &schedule.invalid {
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
    for job in &schedule.jobs {
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
    for job in schedule.heads() {
        if !sched.effective_enabled(job, sched.clock.now_ms()) {
            continue;
        }
        eprintln!(
            "jesse-bridge: schedule ARMED id={} at={} days={} chain=[{}] catch_up_secs={}",
            job.id,
            job.at_label().unwrap_or_default(),
            if job.days.is_all() {
                "all".to_string()
            } else {
                job.days.names().join(",")
            },
            schedule.chain(&job.id).join(" -> "),
            job.catch_up_secs,
        );
    }
    // And the per-JOB table, which the ARMED lines above cannot replace: they name heads
    // only, so a `days` key on a link — the key that decides whether the rest of a chain
    // runs tonight — had no representation anywhere. See [`boot_table`].
    eprintln!(
        "jesse-bridge: schedule TABLE — {} job(s), zone {} ({})",
        schedule.jobs.len(),
        sched.clock.tz_name(),
        sched.clock.utc_offset(),
    );
    print_boot_table(&sched);
    tokio::spawn(async move {
        loop {
            let sched = st.scheduler.clone();
            let now = sched.clock.now_ms();
            sched.tick(&st, now);
            tokio::time::sleep(SCHEDULER_TICK).await;
        }
    });
}

// ---- `GET /jesse/schedule` ---------------------------------------------------

/// One job's row.
fn schedule_row(sched: &Scheduler, schedule: &Schedule, job: &ScheduleJob) -> Value {
    let rec = sched.state.get(&job.id);
    let now = sched.clock.now_ms();
    json!({
        "id": job.id,
        // The EFFECTIVE state — the runtime override while it is live, else the config's.
        // `enabled_config` keeps the file's own answer beside it, so "why is this off"
        // never needs the file to be read.
        "enabled": sched.effective_enabled(job, now),
        "enabled_config": job.enabled,
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
        "running": sched.chain_is_running(schedule, &job.id),
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
        // HOW MANY TIMES IN A ROW IT HAS NOT DELIVERED. `last_outcome` says last night
        // failed; only this says it was the sixth night running.
        "consecutive_failures": rec.consecutive_failures,
        // The output contract as declared (never expanded — the tokens are part of what
        // the operator wrote), and the match that last satisfied it.
        "expect_output": job.expect_output,
        "last_output_path": rec.last_output_path,
        // The per-job model, or null for "whatever is globally active".
        "model": job.model,
        // Set when this entry was promoted into a missing head's clock slot.
        "promoted_from": job.promoted_from,
        // The runtime enable override, if one is set — including an EXPIRED one, because
        // "it was disabled until Sunday and Sunday has passed" is a thing someone asks.
        "override": rec.r#override.as_ref().map(|ov| json!({
            "enabled": ov.enabled,
            "until_ms": ov.until_ms,
            "set_ms": ov.set_ms,
            "active": ov.active_at(now),
        })),
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
    Ok(Json(schedule_snapshot(&st)))
}

/// The whole `GET /jesse/schedule` body. Shared with the control endpoints, which all
/// answer with the same shape so a client never has to reconcile two views of a job.
fn schedule_snapshot(st: &AppState) -> Value {
    let sched = &st.scheduler;
    let schedule = sched.schedule();
    let rows: Vec<Value> = schedule
        .jobs
        .iter()
        .map(|j| schedule_row(sched, &schedule, j))
        .collect();
    let invalid: Vec<Value> = schedule
        .invalid
        .iter()
        .map(|e| json!({ "id": e.id, "reason": e.reason }))
        .collect();
    json!({
        "now_ms": sched.clock.now_ms(),
        // THE ZONE, BY NAME. Every "HH:MM", every `days`, every `{date}` is resolved in it,
        // and a UTC offset alone cannot answer the question this field exists for: "+02:00"
        // is Rome in August and something else in January.
        "tz": sched.clock.tz_name(),
        // Kept beside it (and unchanged in shape) so nothing that already read it breaks.
        "utc_offset": sched.clock.utc_offset(),
        "persistent": sched.state.is_persistent(),
        "jobs": rows,
        // Entries disabled individually by validation, so a typo is VISIBLE here rather
        // than merely absent from the list above.
        "invalid": invalid,
    })
}

// ---- The runtime control endpoints -------------------------------------------
//
// Three POSTs, all bearer-gated and all counted by the same 30-per-minute limiter as every
// other accepted request. They exist because everything else here answers questions and
// nothing acted on the answers: seeing "failed" at 07:00 and being able to do nothing about
// it until 03:30 tomorrow is most of the reason a broken job stays broken.

/// The shared preamble: same bearer auth and same rate limiter as `/jesse`.
fn admit(st: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    check_auth(headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    Ok(())
}

/// `POST /jesse/schedule/{id}/fire` — run the chain from `{id}` now.
#[derive(Deserialize, Default)]
pub struct FireBody {
    /// Ignore the `expect_output` freshness gate. Without it, a job whose output already
    /// matches this occurrence is skipped — which is what makes the endpoint safe to press
    /// twice, and `force` is how you say you meant it.
    #[serde(default)]
    pub force: bool,
}

/// `POST /jesse/schedule/{id}/fire` — run `{id}` and everything chained behind it, right
/// now, on the same path a due occurrence takes.
///
/// The gates are the ones a scheduled run gets, with two deliberate differences. The
/// calendar is evaluated at NOW rather than at an occurrence (there is no occurrence — a
/// person asked), and the member NAMED does not consult its predecessor: it never ran in
/// this run, and refusing to fire the job someone asked for because a job nobody ran did
/// not succeed would make the endpoint useless for exactly the mid-chain repair it is for.
/// Everything BEHIND the named member is gated normally.
pub async fn jesse_schedule_fire(
    State(st): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    body: Option<Json<FireBody>>,
) -> Result<Response, ApiError> {
    admit(&st, &headers)?;
    let force = body.map(|Json(b)| b.force).unwrap_or(false);
    let sched = st.scheduler.clone();
    let schedule = sched.schedule();
    if schedule.get(&id).is_none() {
        return Err((
            StatusCode::NOT_FOUND,
            format!("no [[schedule]] entry with id {id:?}"),
        ));
    }
    let Some(head) = sched.head_of(&schedule, &id) else {
        return Err((
            StatusCode::NOT_FOUND,
            format!("no [[schedule]] entry with id {id:?}"),
        ));
    };
    // SINGLE FLIGHT, on the head — a chain already running would otherwise get a second
    // agent on the same working tree, which is the one thing this whole feature refuses.
    if sched.is_running(&head) {
        return Err((
            StatusCode::CONFLICT,
            format!("the chain headed by {head:?} is already running"),
        ));
    }

    let now = sched.clock.now_ms();
    let chain = schedule.chain(&id);
    let run = ChainRun {
        head: head.clone(),
        start_at: id.clone(),
        due: DueFire {
            due_ms: now,
            lateness_ms: 0,
            missed_earlier: 0,
        },
        // A person asked, now — so "is it scheduled today" is a question about today.
        calendar_ms: now,
        // The CONTRACT, though, belongs to the chain's own occurrence: firing the overnight
        // chain by hand at 09:00 must see that 03:30 already wrote today's note, or `force`
        // would be the only usable mode of this endpoint.
        contract_ms: sched.contract_anchor(&head, now),
        operator: Some(OperatorFire { force }),
    };
    sched.running.lock_ok().push(head.clone());
    eprintln!(
        "jesse-bridge: schedule OPERATOR-FIRE id={id} head={head} force={force} chain=[{}]",
        chain.join(" -> ")
    );
    let st2 = st.clone();
    tokio::spawn(async move {
        run_chain(sched, st2, schedule, run).await;
    });
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({ "chain": chain, "started_ms": now })),
    )
        .into_response())
}

/// `POST /jesse/schedule/{id}/enable`.
#[derive(Deserialize)]
pub struct EnableBody {
    pub enabled: bool,
    /// When the override stops applying, RFC 3339. `null` (or absent) means "until it is
    /// changed" — allowed, but the expiring form is the one to reach for: a disabled job is
    /// silent by design, so an override nobody remembers is a job that never runs again.
    #[serde(default)]
    pub until: Option<String>,
}

/// `POST /jesse/schedule/{id}/enable` — turn one job on or off at runtime, optionally
/// until a deadline. Returns the job's row.
///
/// An override that disables a member skips it with exactly the reason a config
/// `enabled = false` does, so it breaks an `after_on = "success"` chain the same way. That
/// equivalence is the point: one word, one meaning, whichever place it is set in.
pub async fn jesse_schedule_enable(
    State(st): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    Json(body): Json<EnableBody>,
) -> Result<Json<Value>, ApiError> {
    admit(&st, &headers)?;
    let sched = &st.scheduler;
    let schedule = sched.schedule();
    let Some(job) = schedule.get(&id) else {
        return Err((
            StatusCode::NOT_FOUND,
            format!("no [[schedule]] entry with id {id:?}"),
        ));
    };
    let until_ms = match body
        .until
        .as_deref()
        .map(str::trim)
        .filter(|u| !u.is_empty())
    {
        None => None,
        Some(raw) => Some(
            DateTime::parse_from_rfc3339(raw)
                .map_err(|e| {
                    (
                        StatusCode::BAD_REQUEST,
                        format!("`until` must be an RFC 3339 instant: {e}"),
                    )
                })?
                .timestamp_millis()
                .max(0) as u64,
        ),
    };
    let now = sched.clock.now_ms();
    sched.state.set_override(
        &id,
        Some(EnableOverride {
            enabled: body.enabled,
            until_ms,
            set_ms: now,
        }),
    );
    eprintln!(
        "jesse-bridge: schedule OVERRIDE id={id} enabled={} until={}",
        body.enabled,
        until_ms
            .map(|u| sched.clock.short_local(u))
            .unwrap_or_else(|| "(none)".to_string())
    );
    Ok(Json(schedule_row(sched, &schedule, job)))
}

/// `POST /jesse/schedule/reload` — re-read the `[[schedule]]` array from the config file
/// the bridge loaded at boot, on demand.
///
/// The same swap the tick performs when it notices an mtime change; this is the version you
/// can watch the result of. A file that does not validate leaves the running schedule
/// exactly as it was and says why.
pub async fn jesse_schedule_reload(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admit(&st, &headers)?;
    let sched = st.scheduler.clone();
    let now = sched.clock.now_ms();
    // Re-stamp the watch either way, so a hand reload and the tick's watch agree about
    // what has been seen and a failed file is not re-reported every 20 seconds.
    if let Some(w) = sched.reload.lock_ok().as_mut() {
        w.mtime_ms = mtime_ms(&w.path);
    }
    let outcome = sched.reload_now(&st, now);
    Ok(Json(json!({
        "reloaded": outcome.reloaded,
        "errors": outcome.errors,
        "schedule": schedule_snapshot(&st),
    })))
}

impl Scheduler {
    /// The instant an OPERATOR fire measures a chain's output contract against: the head's
    /// most recent scheduled occurrence, or now when it has never come due. See the note on
    /// `ChainRun::contract_ms`.
    fn contract_anchor(&self, head: &str, now_ms: u64) -> u64 {
        self.state.get(head).last_due_ms.unwrap_or(now_ms)
    }
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

#[cfg(test)]
mod calendar_tests {
    use super::*;
    use chrono_tz::Europe::Rome;

    /// The sixteen `[[schedule]]` blocks as they stand in production, verbatim but for the
    /// prompt paths (pointed at a temp tree so the missing-prompt promotion is not in play
    /// — that is a different test). This is the fixture the Friday reproduction runs on;
    /// it is copied rather than summarized so a divergence between the live file and what
    /// this suite believes about it is a diff, not an argument.
    const PRODUCTION_SCHEDULE: &str = r#"
[[schedule]]
id = "overnight-vault-lint"
at = "03:30"
prompt_file = "PROMPTS/overnight-vault-lint.md"
catch_up_secs = 10800

[[schedule]]
id = "overnight-currency"
after = "overnight-vault-lint"
after_on = "any"
prompt_file = "PROMPTS/overnight-currency.md"

[[schedule]]
id = "overnight-philosophy"
after = "overnight-currency"
after_on = "any"
prompt_file = "PROMPTS/overnight-philosophy.md"

[[schedule]]
id = "overnight-cheatsheets"
after = "overnight-philosophy"
after_on = "any"
days = ["mon"]
prompt_file = "PROMPTS/overnight-cheatsheets.md"

[[schedule]]
id = "overnight-tag1-status"
after = "overnight-philosophy"
after_on = "any"
days = ["fri"]
prompt_file = "PROMPTS/overnight-tag1-status.md"

[[schedule]]
id = "overnight-diet-analysis"
after = "overnight-philosophy"
after_on = "any"
days = ["sun"]
prompt_file = "PROMPTS/overnight-diet-analysis.md"

[[schedule]]
id = "morning-health-audit"
at = "06:05"
prompt_file = "PROMPTS/morning-health-audit.md"
catch_up_secs = 7200

[[schedule]]
id = "morning-weigh-in"
after = "morning-health-audit"
after_on = "any"
prompt_file = "PROMPTS/morning-weigh-in.md"

[[schedule]]
id = "morning-start-of-day"
after = "morning-weigh-in"
after_on = "any"
prompt_file = "PROMPTS/morning-start-of-day.md"

[[schedule]]
id = "archive-box-0100"
at = "01:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-0400"
at = "04:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-0700"
at = "07:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-1000"
at = "10:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-1300"
at = "13:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-1600"
at = "16:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-1900"
at = "19:00"
prompt_file = "PROMPTS/archive-box.md"

[[schedule]]
id = "archive-box-2200"
at = "22:00"
prompt_file = "PROMPTS/archive-box.md"
"#;

    /// The whole `[[schedule]]` table, parsed as the bridge parses it.
    fn parse(toml_text: &str) -> Vec<ScheduleToml> {
        #[derive(serde::Deserialize)]
        struct Wrapper {
            #[serde(default)]
            schedule: Vec<ScheduleToml>,
        }
        toml::from_str::<Wrapper>(toml_text)
            .expect("the fixture must parse")
            .schedule
    }

    fn production() -> Schedule {
        let s = validate_schedule(&parse(PRODUCTION_SCHEDULE));
        assert!(s.fatal.is_empty(), "{:?}", s.fatal);
        assert!(s.invalid.is_empty(), "{:?}", s.invalid);
        s
    }

    /// An instant in `Europe/Rome`, as the scheduler's zone resolves it.
    fn rome(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> u64 {
        SchedulerZone::Named(Rome)
            .with_ymd_and_hms(y, mo, d, h, mi, 0)
            .single()
            .expect("an unambiguous fixture instant")
            .timestamp_millis() as u64
    }

    /// Walk one chain's per-member gates for a fixed occurrence, exactly as `run_chain`
    /// does, and return each member's decision in execution order. Nothing here touches a
    /// clock, a socket or a disk: the occurrence is a parameter, which is the whole point.
    fn walk(
        schedule: &Schedule,
        clock: &SchedulerClock,
        head: &str,
        calendar_ms: u64,
    ) -> Vec<(String, MemberDecision)> {
        let weekday = clock.weekday_at(calendar_ms);
        let mut outcomes: HashMap<String, Outcome> = HashMap::new();
        let mut broken_by: HashMap<String, String> = HashMap::new();
        let mut out = Vec::new();
        for id in schedule.chain(head) {
            let job = schedule.get(&id).expect("a chain member exists");
            let decision = member_decision(job, &outcomes, &broken_by, head, job.enabled, weekday);
            // A member that runs is assumed to succeed — the fake turn that "completes
            // instantly"; a skipped one records its breaker, so the links behind it are
            // judged the way the real run would judge them.
            match &decision {
                MemberDecision::Run => {
                    outcomes.insert(id.clone(), Outcome::Ran);
                }
                MemberDecision::Skip { breaker, .. } => {
                    outcomes.insert(id.clone(), Outcome::Skipped);
                    broken_by.insert(id.clone(), breaker.clone());
                }
            }
            out.push((id, decision));
        }
        out
    }

    fn ran(walked: &[(String, MemberDecision)], id: &str) -> bool {
        walked
            .iter()
            .find(|(i, _)| i == id)
            .map(|(_, d)| *d == MemberDecision::Run)
            .unwrap_or_else(|| panic!("{id} is not in the chain"))
    }

    fn skip_reason(walked: &[(String, MemberDecision)], id: &str) -> String {
        walked
            .iter()
            .find(|(i, _)| i == id)
            .and_then(|(_, d)| match d {
                MemberDecision::Skip { reason, .. } => Some(reason.clone()),
                MemberDecision::Run => None,
            })
            .unwrap_or_else(|| panic!("{id} was expected to skip"))
    }

    /// THE FRIDAY REPRODUCTION, 2026-08-21.
    ///
    /// The ledger for that morning recorded `overnight-currency` and `overnight-philosophy`
    /// as `day-skipped`, "not scheduled on this weekday", although neither carries a `days`
    /// key at all. This walks the real production chain at the real occurrence — 03:30
    /// Europe/Rome on a Friday — and pins what the calendar is allowed to conclude about
    /// each member: only `overnight-tag1-status` is the Friday-only one, the two
    /// unrestricted links run, and the Monday and Sunday members are the only skips.
    #[test]
    fn the_friday_overnight_chain_runs_currency_and_philosophy() {
        let schedule = production();
        let friday = rome(2026, 8, 21, 3, 30);
        let clock = SchedulerClock::frozen(SchedulerZone::Named(Rome), friday);
        assert_eq!(
            clock.weekday_at(friday),
            Some(Weekday::Fri),
            "the fixture instant must actually be a Friday in Rome"
        );

        let walked = walk(&schedule, &clock, "overnight-vault-lint", friday);
        assert_eq!(
            walked.iter().map(|(i, _)| i.as_str()).collect::<Vec<_>>(),
            vec![
                "overnight-vault-lint",
                "overnight-currency",
                "overnight-philosophy",
                "overnight-cheatsheets",
                "overnight-tag1-status",
                "overnight-diet-analysis",
            ],
            "the chain's execution order is config order, depth first"
        );

        assert!(ran(&walked, "overnight-vault-lint"));
        assert!(
            ran(&walked, "overnight-currency"),
            "overnight-currency has no `days` key — nothing may day-skip it"
        );
        assert!(
            ran(&walked, "overnight-philosophy"),
            "overnight-philosophy has no `days` key — nothing may day-skip it"
        );
        assert!(
            ran(&walked, "overnight-tag1-status"),
            "tag1-status is the Friday member and this is Friday"
        );
        assert_eq!(skip_reason(&walked, "overnight-cheatsheets"), CALENDAR_SKIP);
        assert_eq!(
            skip_reason(&walked, "overnight-diet-analysis"),
            CALENDAR_SKIP
        );

        // And the converse, so the fixture is proved to have teeth: on the Thursday the
        // Friday-only member is the one that skips and the other two still run.
        let thursday = rome(2026, 8, 20, 3, 30);
        let clock = SchedulerClock::frozen(SchedulerZone::Named(Rome), thursday);
        let walked = walk(&schedule, &clock, "overnight-vault-lint", thursday);
        assert!(ran(&walked, "overnight-currency"));
        assert!(ran(&walked, "overnight-philosophy"));
        assert_eq!(skip_reason(&walked, "overnight-tag1-status"), CALENDAR_SKIP);
    }

    /// THE DEFECT ITSELF: a chain is ONE occurrence, and its calendar is the occurrence's.
    ///
    /// `run_chain` used to read `SystemTime::now()` as it reached each member, so a chain
    /// whose earlier members ran long enough to cross local midnight judged its later ones
    /// against the NEXT day — and skipped, as "not scheduled on this weekday", precisely the
    /// member whose `days` named the day it was scheduled for. Fails against the old
    /// behaviour (the second assertion below is what the old code produced) and passes
    /// against the fix.
    #[test]
    fn a_chain_that_crosses_midnight_is_still_judged_by_its_own_occurrence() {
        let raw = parse(
            r#"
[[schedule]]
id = "late-head"
at = "23:40"
prompt = "go"

[[schedule]]
id = "friday-link"
after = "late-head"
after_on = "any"
days = ["fri"]
prompt = "go"
"#,
        );
        let schedule = validate_schedule(&raw);
        assert!(schedule.fatal.is_empty());

        let occurrence = rome(2026, 8, 21, 23, 40); // Friday 23:40
        let clock = SchedulerClock::frozen(SchedulerZone::Named(Rome), occurrence);
        let walked = walk(&schedule, &clock, "late-head", occurrence);
        assert!(
            ran(&walked, "friday-link"),
            "the occurrence is Friday, so the Friday-only link belongs to this run"
        );

        // What the old code did: re-read the clock once the chain reached the link, which
        // by then is Saturday. Same schedule, same run — a different answer, and the wrong
        // one. This is the exact shape of the ledger line that started this.
        let past_midnight = rome(2026, 8, 22, 0, 15);
        let walked_wrong = walk(&schedule, &clock, "late-head", past_midnight);
        assert_eq!(
            skip_reason(&walked_wrong, "friday-link"),
            CALENDAR_SKIP,
            "judging the link at 'now' instead of at the occurrence is what produced the \
             spurious day-skip"
        );
    }

    /// The member the run STARTS at does not consult a predecessor that never ran — the
    /// property `POST /jesse/schedule/{id}/fire` rests on for a mid-chain repair.
    #[test]
    fn a_run_that_starts_mid_chain_does_not_cascade_from_a_job_nobody_ran() {
        let raw = parse(
            r#"
[[schedule]]
id = "head"
at = "03:30"
prompt = "go"

[[schedule]]
id = "strict-link"
after = "head"
prompt = "go"

[[schedule]]
id = "tail"
after = "strict-link"
prompt = "go"
"#,
        );
        let schedule = validate_schedule(&raw);
        let at = rome(2026, 8, 21, 9, 0);
        let clock = SchedulerClock::frozen(SchedulerZone::Named(Rome), at);

        // Started at the strict link: it runs (nobody asked about `head`), and the tail
        // behind it is gated normally on the link's own outcome.
        let walked = walk(&schedule, &clock, "strict-link", at);
        assert!(ran(&walked, "strict-link"));
        assert!(ran(&walked, "tail"));
        assert_eq!(
            walked.iter().map(|(i, _)| i.as_str()).collect::<Vec<_>>(),
            vec!["strict-link", "tail"],
            "an operator fire runs the named member and everything after it, nothing before"
        );
    }
}

#[cfg(test)]
mod output_tests {
    use super::*;
    use chrono_tz::Europe::Rome;

    fn rome_clock(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> (SchedulerClock, u64) {
        let ms = SchedulerZone::Named(Rome)
            .with_ymd_and_hms(y, mo, d, h, mi, 0)
            .single()
            .unwrap()
            .timestamp_millis() as u64;
        (SchedulerClock::frozen(SchedulerZone::Named(Rome), ms), ms)
    }

    // ---- token expansion -----------------------------------------------------

    /// Tokens expand from the OCCURRENCE in the SCHEDULER'S ZONE, not from UTC and not
    /// from "now". The 03:30 Rome fire on 21 August is 01:30 UTC — a naive UTC expansion
    /// gets the same date here, so the case that proves it is the one either side of local
    /// midnight, where UTC and Rome disagree about the day.
    #[test]
    fn output_tokens_expand_from_the_occurrence_in_the_schedulers_zone() {
        let (clock, ms) = rome_clock(2026, 8, 21, 3, 30);
        assert_eq!(
            clock.expand_tokens("Inbox/{date}-vault-lint.md", ms),
            "Inbox/2026-08-21-vault-lint.md"
        );
        assert_eq!(
            clock.expand_tokens("reports/{year}/{month}/{day}.md", ms),
            "reports/2026/08/21.md"
        );

        // 00:30 Rome on the 22nd is 22:30 UTC on the 21st. The occurrence's own zone is
        // what decides, so this is the 22nd.
        let (clock, ms) = rome_clock(2026, 8, 22, 0, 30);
        assert_eq!(
            clock.expand_tokens("Inbox/{date}.md", ms),
            "Inbox/2026-08-22.md"
        );

        // A pattern with no tokens is returned untouched.
        assert_eq!(clock.expand_tokens("Inbox/fixed.md", ms), "Inbox/fixed.md");
    }

    // ---- the segment matcher -------------------------------------------------

    #[test]
    fn the_segment_matcher_handles_stars_and_question_marks() {
        assert!(segment_matches("*.md", "2026-08-21-lint.md"));
        assert!(segment_matches("2026-*-lint.md", "2026-08-21-lint.md"));
        assert!(segment_matches("*", "anything"));
        assert!(segment_matches("*lint*", "a-lint-b"));
        assert!(segment_matches("????-??-??.md", "2026-08-21.md"));
        assert!(segment_matches("exact.md", "exact.md"));

        assert!(!segment_matches("*.md", "notes.txt"));
        assert!(!segment_matches("???.md", "abcd.md"));
        assert!(!segment_matches("exact.md", "exact.md.bak"));
        // A `*` never crosses a path separator — segments are matched one at a time, so a
        // name containing one simply is not the name being matched.
        assert!(!segment_matches("*.md", "sub/file.md"));
    }

    // ---- the glob over a real tree -------------------------------------------

    fn temp_root() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-glob-{}", random_hex()));
        std::fs::create_dir_all(d.join("Inbox")).unwrap();
        std::fs::create_dir_all(d.join("reports/2026/08")).unwrap();
        d
    }

    #[test]
    fn the_glob_matches_literal_and_wildcard_segments_and_stays_inside_the_root() {
        let root = temp_root();
        std::fs::write(root.join("Inbox/2026-08-21-vault-lint.md"), "x").unwrap();
        std::fs::write(root.join("Inbox/unrelated.txt"), "x").unwrap();
        std::fs::write(root.join("reports/2026/08/summary.md"), "x").unwrap();

        let hit = glob_matches(&root, "Inbox/2026-08-21-vault-lint.md");
        assert_eq!(hit.len(), 1, "an all-literal pattern needs no listing");

        let hits = glob_matches(&root, "Inbox/*.md");
        assert_eq!(hits.len(), 1, "the .txt is not a .md");

        let hits = glob_matches(&root, "reports/2026/08/*.md");
        assert_eq!(hits.len(), 1, "a nested literal path walks");

        assert!(
            glob_matches(&root, "Inbox/never-written.md").is_empty(),
            "a pattern that matches nothing is empty, never an error"
        );
        // A directory is not an output.
        assert!(glob_matches(&root, "Inbox").is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    // ---- the escalation cadence ----------------------------------------------

    /// 3, 6, 12, 24 and nothing else. A streak that keeps climbing keeps being REPORTED
    /// by the endpoint; it stops being PUSHED, because a person who has ignored four of
    /// these does not need a fifth.
    #[test]
    fn the_escalation_pushes_at_three_six_twelve_and_twenty_four_only() {
        let pushed: Vec<u32> = (0..=30).filter(|n| ESCALATE_AT.contains(n)).collect();
        assert_eq!(pushed, vec![3, 6, 12, 24]);
        for quiet in [0, 1, 2, 4, 5, 7, 11, 13, 23, 25, 30] {
            assert!(!ESCALATE_AT.contains(&quiet), "{quiet} must not push");
        }
    }

    /// The counter itself: incremented by a failure and by a fire that produced no output,
    /// reset by a success, and untouched by a skip.
    #[test]
    fn the_failure_streak_counts_failures_and_empty_fires_but_not_skips() {
        let s = ScheduleStateStore::new(None);
        s.finished("nightly", Outcome::Failed, "boom", 1, None);
        assert_eq!(s.get("nightly").consecutive_failures, 1);
        s.finished(
            "nightly",
            Outcome::FiredNoOutput,
            "nothing written",
            2,
            Some(1),
        );
        assert_eq!(s.get("nightly").consecutive_failures, 2);

        // A skip is a decision not to run, not a run that went wrong.
        s.finished("nightly", Outcome::Skipped, CALENDAR_SKIP, 3, None);
        assert_eq!(
            s.get("nightly").consecutive_failures,
            2,
            "a Monday-only job must not bank a failure every other day of the week"
        );

        s.finished("nightly", Outcome::Ran, "", 4, Some(1));
        assert_eq!(s.get("nightly").consecutive_failures, 0);
    }

    /// `fired-no-output` is not a success, so it breaks an `after_on = "success"` chain —
    /// which is the whole point of not folding it into `ran`.
    #[test]
    fn a_fire_with_no_output_is_not_a_success() {
        assert!(!Outcome::FiredNoOutput.is_success());
        assert_eq!(Outcome::FiredNoOutput.label(), "fired-no-output");
        // And it survives a round trip through the persisted record.
        let s = ScheduleStateStore::new(None);
        s.finished("x", Outcome::FiredNoOutput, "nothing", 1, Some(1));
        assert_eq!(s.get("x").outcome(), Some(Outcome::FiredNoOutput));
    }

    /// A fresh-output skip is as quiet as a `days` skip: it is the config working. A
    /// `fired-no-output` is as loud as a failure, because it is one.
    #[test]
    fn a_fresh_output_skip_is_quiet_and_an_empty_fire_is_loud() {
        let j = validate_schedule(&[ScheduleToml {
            id: Some("lint".into()),
            at: Some("03:30".into()),
            prompt: Some("go".into()),
            ..Default::default()
        }])
        .jobs
        .remove(0);
        assert!(!should_push(&j, Outcome::Skipped, OUTPUT_FRESH_SKIP, false));
        assert!(should_push(
            &j,
            Outcome::FiredNoOutput,
            "wrote nothing",
            false
        ));
    }

    // ---- the enable override -------------------------------------------------

    /// The override outranks the config while it is live and expires on its own — because
    /// a disabled job is silent by design, so one nobody remembers is a job that never
    /// runs again.
    #[test]
    fn an_enable_override_applies_until_it_expires() {
        let ov = EnableOverride {
            enabled: false,
            until_ms: Some(2_000),
            set_ms: 1_000,
        };
        assert!(ov.active_at(1_500));
        assert!(!ov.active_at(2_000), "the deadline itself is past it");
        assert!(!ov.active_at(9_999));

        // No deadline means "until it is changed".
        let standing = EnableOverride {
            enabled: false,
            until_ms: None,
            set_ms: 1_000,
        };
        assert!(standing.active_at(u64::MAX));
    }

    /// And it survives a restart, which is the reason it is persisted at all: "off until
    /// Sunday" is a statement that has to outlive the restart that will certainly happen
    /// in between.
    #[test]
    fn an_enable_override_survives_a_store_reload() {
        let path = std::env::temp_dir().join(format!("jesse-ov-{}/schedule.json", random_hex()));
        {
            let s = ScheduleStateStore::new(Some(path.clone()));
            s.claim("nightly", 1_000);
            s.set_override(
                "nightly",
                Some(EnableOverride {
                    enabled: false,
                    until_ms: Some(1_700_000_000_000),
                    set_ms: 1_000,
                }),
            );
        }
        let s = ScheduleStateStore::new(Some(path.clone()));
        let ov = s.get("nightly").r#override.expect("the override persists");
        assert!(!ov.enabled);
        assert_eq!(ov.until_ms, Some(1_700_000_000_000));
        assert_eq!(
            s.get("nightly").last_due_ms,
            Some(1_000),
            "and it does not disturb the anti-double-fire anchor"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A record written before this release has no `consecutive_failures`, no
    /// `last_output_path` and no `override`, and must load as "never happened" rather than
    /// costing the whole file's history.
    #[test]
    fn an_older_record_loads_with_the_new_fields_defaulted() {
        let path = std::env::temp_dir().join(format!("jesse-old-{}/schedule.json", random_hex()));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"v":1,"jobs":{"nightly":{"last_due_ms":42,"last_outcome":"ran"}}}"#,
        )
        .unwrap();
        let rec = ScheduleStateStore::new(Some(path.clone())).get("nightly");
        assert_eq!(rec.last_due_ms, Some(42));
        assert_eq!(rec.consecutive_failures, 0);
        assert_eq!(rec.last_output_path, None);
        assert_eq!(rec.r#override, None);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    // ---- the boot table ------------------------------------------------------

    /// ONE ROW PER JOB, links included, each carrying its resolved days by name. The old
    /// boot output named heads only, which is exactly why a `days` key on a link — the key
    /// that decides whether the rest of a chain runs tonight — was invisible.
    #[test]
    fn the_boot_table_gives_every_job_a_row_with_its_resolved_days() {
        let schedule = validate_schedule(&[
            ScheduleToml {
                id: Some("overnight-vault-lint".into()),
                at: Some("03:30".into()),
                prompt: Some("go".into()),
                catch_up_secs: Some(10_800),
                ..Default::default()
            },
            ScheduleToml {
                id: Some("overnight-currency".into()),
                after: Some("overnight-vault-lint".into()),
                after_on: Some("any".into()),
                prompt: Some("go".into()),
                ..Default::default()
            },
            ScheduleToml {
                id: Some("overnight-tag1-status".into()),
                after: Some("overnight-currency".into()),
                after_on: Some("any".into()),
                days: Some(vec!["fri".into()]),
                prompt: Some("go".into()),
                ..Default::default()
            },
        ]);
        let sched = Scheduler::new(Arc::new(schedule), None);
        let rows = boot_table(&sched);

        assert_eq!(rows.len(), 4, "a header and one row per job: {rows:#?}");
        assert!(rows[0].starts_with("id"));

        let row = |id: &str| {
            rows.iter()
                .find(|r| r.starts_with(id))
                .unwrap_or_else(|| panic!("no row for {id}: {rows:#?}"))
                .clone()
        };
        let head = row("overnight-vault-lint");
        assert!(head.contains("head") && head.contains("at 03:30"), "{head}");
        assert!(
            head.contains("mon,tue,wed,thu,fri,sat,sun"),
            "an unrestricted job still names every day: {head}"
        );

        let link = row("overnight-currency");
        assert!(link.contains("link"), "{link}");
        assert!(
            link.contains("after overnight-vault-lint (any)"),
            "a link names what it hangs off and on what: {link}"
        );

        let friday = row("overnight-tag1-status");
        assert!(
            friday.contains(" fri "),
            "THE LINE THAT WOULD HAVE CAUGHT THE FRIDAY BUG — a link's days, by name: \
             {friday}"
        );
    }
}
