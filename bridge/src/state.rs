use crate::*;

/// Shared, cheaply-clonable handler state: read-only config, the job store, the
/// concurrency semaphore, and the rate limiter.
#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub jobs: Arc<JobStore>,
    // Bounds concurrent turns (C3). A permit is held for the life of a turn.
    pub sem: Arc<Semaphore>,
    // Bounds the wait QUEUE in front of `sem` and issues admission decisions:
    // run-now, queue-and-wait, or shed (429). Wraps the same `sem`.
    pub queue: Arc<QueueGate>,
    // Per-service request rate ceiling (C3).
    pub limiter: Arc<RateLimiter>,
    // Server-side session_id → title store (persisted to `<state_dir>/titles.json`
    // when a state dir is configured; in-memory otherwise). Filled by
    // `POST /jesse/title` and read by `GET /jesse/sessions`.
    pub titles: Arc<TitleStore>,
    // The registered APNs device token (single user). Always present so device
    // registration works even when push is off; persisted to the state dir.
    pub devices: Arc<DeviceStore>,
    // Job ids the phone asked to be pushed on completion. In-memory only: a
    // running job isn't persisted, so neither is its notify flag.
    pub notify: Arc<NotifyFlags>,
    // APNs client — `Some` only when JESSE_APNS_* is fully configured AND the key
    // loaded. `None` → push disabled and the bridge behaves exactly as before.
    // Set by `main`; `AppState::new` leaves it `None` so tests never touch env
    // or the network (a test that exercises push installs its own mock client).
    pub apns: Option<Arc<ApnsClient>>,
    // Circuit breaker for the emergency local fallback (Piece 4): shared across turns
    // so consecutive transport-class hosted failures can trip it. Inert unless the
    // emergency fallback is armed — `handlers::jesse` only consults it then, so with
    // emergency off it never changes a turn's behavior.
    pub breaker: Arc<CircuitBreaker>,
    // Persisted meal-corrections queue (JESSE_MEAL_LOG v2): off-app meal events posted
    // to `POST /jesse/meal-corrections` land here and are merged into the `meal_log`
    // delivered on every terminal result, so corrections made in non-app sessions still
    // reach Apple Health. Persisted to `<state_dir>/meal-corrections-queue.jsonl`;
    // unavailable (delivery a no-op, enqueue errors loudly) when no state dir is set.
    pub meal_corrections: Arc<MealCorrectionsQueue>,
    // The context ledger (context carry): records each delivered turn per thread and
    // feeds a catch-up block into the next hosted turn + a recent-conversation block
    // into the local children, so a locally-served turn is not lost to a later hosted
    // follow-up. Persisted to `<state_dir>/context.json`. Inert (a total no-op) unless
    // `cfg.context_carry` is on — with carry off every path is byte-for-byte today's.
    pub context: Arc<ContextLedger>,
}

impl AppState {
    /// Build shared state from a config, sizing the semaphore and rate limiter
    /// from it. Used by both `main` and the tests so they exercise the same
    /// wiring. Push (`apns`) is left `None` here — `main` installs the real client
    /// after this, and tests that need it set their own mock.
    pub fn new(cfg: Config) -> Self {
        let job_ttl = Duration::from_secs(cfg.job_ttl_secs);
        let retrieval_grace = Duration::from_secs(cfg.retrieval_grace_secs);
        let jobs_dir = cfg.jobs_dir();
        let device_file = cfg.device_file();
        let titles_file = cfg.titles_file();
        let context_file = cfg.context_file();
        let context_enabled = cfg.context_carry;
        let meal_corrections = Arc::new(MealCorrectionsQueue::from_cfg(&cfg));
        let sem = Arc::new(Semaphore::new(cfg.max_concurrency.max(1)));
        let queue = QueueGate::new(sem.clone(), cfg.max_queued);
        let limiter = Arc::new(RateLimiter::new(cfg.rate_per_min));
        AppState {
            cfg: Arc::new(cfg),
            jobs: Arc::new(JobStore::new(job_ttl, retrieval_grace, jobs_dir)),
            sem,
            queue,
            limiter,
            titles: Arc::new(TitleStore::new(titles_file)),
            devices: Arc::new(DeviceStore::new(device_file)),
            notify: Arc::new(NotifyFlags::new()),
            apns: None,
            breaker: Arc::new(CircuitBreaker::new()),
            meal_corrections,
            context: Arc::new(ContextLedger::new(context_file, context_enabled)),
        }
    }

    /// The `~/.claude/projects/<escaped-vault>` directory this bridge's vault
    /// sessions live in. Uses the HOME captured once in `Config` (see `cfg.home`);
    /// an unknown HOME yields a path that simply won't exist (→ empty session
    /// list), never an error.
    pub fn sessions_dir(&self) -> PathBuf {
        vault_sessions_dir(&self.cfg.home, &self.cfg.vault)
    }
}
