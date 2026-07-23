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
    // Server-side session_id -> favorite/archived flags store (persisted to
    // `<state_dir>/flags.json` when a state dir is configured; in-memory otherwise).
    // The bridge is the source of truth for these two flags so every device (iPhone,
    // Mac) converges on one set of favorites and archived conversations. Read into
    // `GET /jesse/sessions` and written by `POST /jesse/session/{id}/flags`.
    pub flags: Arc<FlagStore>,
    // Server-side session_id -> deletion tombstone store (persisted to
    // `<state_dir>/deletions.json` when a state dir is configured; in-memory
    // otherwise). Records a durable tombstone when (and only when) a client
    // explicitly deletes a session, exposed as the `deleted` array on
    // `GET /jesse/sessions` so every device converges on removals the same way it
    // converges on favorite/archived flags. Age-based GC never records here.
    pub deletions: Arc<DeletionStore>,
    // Server-side GLOBAL model selection (the model switch): the active model id and the
    // per-model write overrides, persisted to `<state_dir>/model.json` (in-memory when no
    // state dir). The bridge is the source of truth so iPhone and Mac converge on ONE
    // choice of which model backs the conversation. Read into `GET /jesse/models`,
    // written by `POST /jesse/model` and `POST /jesse/model/{id}/writes`. Holds only ids
    // and booleans — never a token (credentials live in `cfg.model_registry`, from env).
    pub models: Arc<ModelStore>,
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
    // AT-MOST-ONE guard for the opt-in shadow-comparison child (JESSE_SHADOW_*). A
    // permit of ONE, entirely separate from `sem` (the production permit), so a
    // background shadow mirror can never occupy or delay a phone turn's slot. A
    // shadow run `try_acquire`s this (never `.await`); if it's taken, that turn is
    // simply not mirrored (no backlog — the sample is large enough). Always present;
    // inert unless `cfg.shadow_backend` is set. See [`shadow`].
    pub shadow_slot: Arc<Semaphore>,
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
        let flags_file = cfg.flags_file();
        let model_file = cfg.model_file();
        let deletions_file = cfg.deletions_file();
        let deletion_retention_ms = deletion_retention_ms(cfg.session_ttl_days);
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
            flags: Arc::new(FlagStore::new(flags_file)),
            models: Arc::new(ModelStore::new(model_file)),
            deletions: Arc::new(DeletionStore::new(deletions_file, deletion_retention_ms)),
            devices: Arc::new(DeviceStore::new(device_file)),
            notify: Arc::new(NotifyFlags::new()),
            apns: None,
            breaker: Arc::new(CircuitBreaker::new()),
            meal_corrections,
            context: Arc::new(ContextLedger::new(context_file, context_enabled)),
            // One shadow child at a time; separate from the production permit.
            shadow_slot: Arc::new(Semaphore::new(1)),
        }
    }

    /// Resolve the model that should back THIS turn from the persisted selection + the
    /// registry: the active id, its `ANTHROPIC_*` env (None for ambient), the subagent
    /// model, and its EFFECTIVE write permission. Ambient (`opus`) is always writes-on; a
    /// non-ambient model's writes come from its `ModelStore` override, else its registry
    /// `default_writes` (OFF in Phase 1). A stored active id that is unknown or no longer
    /// available degrades to the always-available default rather than stranding the turn.
    pub fn resolve_active_model(&self) -> ActiveModel {
        let id = self.models.active();
        let registry = &self.cfg.model_registry;
        let m = match registry.get(&id) {
            Some(m) if m.available => m,
            _ => registry.default_model(),
        };
        let writes_allowed = matches!(m.kind, ModelKind::Ambient)
            || self
                .models
                .writes_override(&m.id)
                .unwrap_or(m.default_writes);
        ActiveModel {
            id: m.id.clone(),
            kind: m.kind,
            env: m.backend.clone(),
            subagent_model: m.backend.as_ref().map(|(_, _, model)| model.clone()),
            writes_allowed,
            price: m.price,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    /// An AppState whose registry offers opus + an available glm-5.2 (read-only default).
    fn state_with_glm() -> AppState {
        let registry = ModelRegistry {
            models: vec![
                RegistryModel {
                    id: "opus".into(),
                    label: "Claude Opus".into(),
                    kind: ModelKind::Ambient,
                    backend: None,
                    available: true,
                    default_writes: true,
                    price: PriceDeck::ZERO,
                },
                RegistryModel {
                    id: "glm-5.2".into(),
                    label: "GLM 5.2".into(),
                    kind: ModelKind::Hosted,
                    backend: Some(("http://fw".into(), "fw-tok".into(), "glm-model".into())),
                    available: true,
                    default_writes: false,
                    price: PriceDeck::ZERO,
                },
            ],
        };
        AppState::new(Config {
            model_registry: registry,
            ..test_config()
        })
    }

    #[test]
    fn resolve_defaults_to_ambient_opus_writes_on() {
        let st = test_state();
        let a = st.resolve_active_model();
        assert_eq!(a.id, "opus");
        assert!(a.env.is_none(), "opus is ambient — no ANTHROPIC_* env");
        assert!(a.writes_allowed, "opus is always writes-on");
    }

    #[test]
    fn resolve_glm_applies_env_and_is_read_only_by_default() {
        let st = state_with_glm();
        st.models.set_active("glm-5.2");
        let a = st.resolve_active_model();
        assert_eq!(a.id, "glm-5.2");
        assert_eq!(
            a.env,
            Some(("http://fw".into(), "fw-tok".into(), "glm-model".into()))
        );
        assert_eq!(a.subagent_model.as_deref(), Some("glm-model"));
        assert!(!a.writes_allowed, "a non-ambient model is read-only until opted in");
    }

    #[test]
    fn resolve_glm_honors_a_writes_override() {
        let st = state_with_glm();
        st.models.set_active("glm-5.2");
        st.models.set_writes("glm-5.2", true);
        assert!(st.resolve_active_model().writes_allowed, "override enables writes");
    }

    #[test]
    fn resolve_falls_back_to_opus_when_the_stored_active_is_unavailable() {
        // A stale selection (a model that became unavailable, or an unknown id) must never
        // strand the conversation; the turn degrades to the always-available default.
        let st = state_with_glm();
        st.models.set_active("kimi-k3"); // not in this registry
        let a = st.resolve_active_model();
        assert_eq!(a.id, "opus", "unknown/unavailable active degrades to opus");
        assert!(a.env.is_none());
    }
}
