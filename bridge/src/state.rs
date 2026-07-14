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
        }
    }

    /// The `~/.claude/projects/<escaped-vault>` directory this bridge's vault
    /// sessions live in. Reads HOME at call time; an unknown HOME yields a path
    /// that simply won't exist (→ empty session list), never an error.
    pub fn sessions_dir(&self) -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_default();
        vault_sessions_dir(&home, &self.cfg.vault)
    }
}
