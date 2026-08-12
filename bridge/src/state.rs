use crate::*;

/// Shared, cheaply-clonable handler state: read-only config, the job store, the
/// concurrency semaphore, and the rate limiter.
#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub jobs: Arc<JobStore>,
    // PER-MODEL slots plus the global ceiling, and the per-model wait queues in front of
    // them. Replaces the single global semaphore + queue this used to be; see `slots`.
    pub slots: Arc<SlotTable>,
    // The vault write lock's broker. Locks are taken by a child's hooks and released by the
    // post hook, by the TURN ENDING (which only this process knows), or by timeout.
    pub broker: Arc<LockBroker>,
    // The `jesse-hook` helper the children's hooks invoke, resolved once at startup.
    // `None` disarms the write lock — every write-level model is then capped at one slot.
    pub hook_helper: Option<PathBuf>,
    // One lock per CONVERSATION, held for the whole turn. Two turns of one conversation
    // resume the same underlying session, so the second would resume a transcript the first
    // is still writing. Bridge-level and harness-independent: both harnesses resume.
    pub conversation_locks: Arc<ConversationLocks>,
    // Per-service request rate ceiling (C3).
    pub limiter: Arc<RateLimiter>,
    // The conversation registry: the bridge's own notion of a thread, keyed on a stable
    // UUID registered at accept time (before `POST /jesse` returns its 202) and owning
    // the ORDERED list of Claude session ids bound to it. Persisted to
    // `<state_dir>/conversations.json`; in-memory otherwise. Every other per-thread
    // store below is keyed on a conversation id, and `GET /jesse/conversations` is
    // rendered from this rather than from a directory scan, which is what stops a
    // mid-turn sync or a CLI session fork from surfacing a duplicate thread.
    pub conversations: Arc<ConversationStore>,
    // Server-side conversation_id → title store (persisted to `<state_dir>/titles.json`
    // when a state dir is configured; in-memory otherwise). Filled by
    // `POST /jesse/title` and read by `GET /jesse/conversations`.
    pub titles: Arc<TitleStore>,
    // Server-side conversation_id -> favorite/archived flags store (persisted to
    // `<state_dir>/flags.json` when a state dir is configured; in-memory otherwise).
    // The bridge is the source of truth for these two flags so every device (iPhone,
    // Mac) converges on one set of favorites and archived conversations. Read into
    // `GET /jesse/conversations` and written by
    // `POST /jesse/conversation/{id}/flags`.
    pub flags: Arc<FlagStore>,
    // Server-side deletion tombstone store (persisted to `<state_dir>/deletions.json`
    // when a state dir is configured; in-memory otherwise). Records a durable tombstone
    // when (and only when) a client explicitly deletes a conversation, exposed as the
    // `deleted` array on `GET /jesse/conversations` so every device converges on
    // removals the same way it converges on favorite/archived flags. Age-based GC never
    // records here. Keyed on the conversation id.
    pub deletions: Arc<DeletionStore>,
    // Server-side GLOBAL model selection (the model switch): the active model id and the
    // per-model write overrides, persisted to `<state_dir>/model.json` (in-memory when no
    // state dir). The bridge is the source of truth so iPhone and Mac converge on ONE
    // choice of which model backs the conversation. Read into `GET /jesse/models`,
    // written by `POST /jesse/model` and `POST /jesse/model/{id}/writes`. Holds only ids
    // and booleans — never a token (credentials live in `cfg.model_registry`, from env).
    pub models: Arc<ModelStore>,
    // Per-model HEALTH cache (the health prober): the last-known reachability of each
    // configured non-ambient model, written by the background prober and read by
    // `GET /jesse/models` + `POST /jesse/model` to gate selection (available = configured
    // AND healthy). Seeded OPTIMISTICALLY healthy for configured models at startup so a
    // configured model is selectable as today until a probe actually fails. Ambient `opus`
    // is never here (healthy by construction). Empty + inert for an opus-only deploy — the
    // prober (spawned in `main`) starts nothing then.
    pub health: Arc<HealthStore>,
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
    // The per-turn timing log: start/end/status/tool-call timings for every turn,
    // appended one JSON line per turn to `<state_dir>/turn-timings.jsonl` (in-memory only
    // with no state dir) and pruned to 7 days at startup. Read by
    // `GET /jesse/result/{id}` under `timing`. This is the record that makes the next
    // slow turn diagnosable in one command rather than an hour of forensics — see
    // [`crate::turntrace`].
    pub timings: Arc<TurnTimingLog>,
    // AT-MOST-ONE guard for the opt-in shadow-comparison child (JESSE_SHADOW_*). A
    // permit of ONE, entirely separate from `sem` (the production permit), so a
    // background shadow mirror can never occupy or delay a phone turn's slot. A
    // shadow run `try_acquire`s this (never `.await`); if it's taken, that turn is
    // simply not mirrored (no backlog — the sample is large enough). Always present;
    // inert unless `cfg.shadow_backend` is set. See [`shadow`].
    pub shadow_slot: Arc<Semaphore>,
    // THE BUILT-IN SCHEDULER: the validated `[[schedule]]` jobs, their persisted
    // last-run record, the one-scheduled-turn-at-a-time lock, and which chains are in
    // flight. Always present so `GET /jesse/schedule` answers on every deploy (with an
    // empty job list where nothing is configured); the tick task is spawned by `main`
    // only when at least one job exists, so an unscheduled bridge runs no extra task.
    // See [`scheduler`].
    pub scheduler: Arc<Scheduler>,
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
        let conversations_file = cfg.conversations_file();
        let model_file = cfg.model_file();
        let deletions_file = cfg.deletions_file();
        let deletion_retention_ms = deletion_retention_ms(cfg.session_ttl_days);
        let context_file = cfg.context_file();
        let context_enabled = cfg.context_carry;
        let meal_corrections = Arc::new(MealCorrectionsQueue::from_cfg(&cfg));
        // Loads the timing log and PRUNES it to the 7-day retention window — the startup
        // half of the per-turn timing record. In-memory only when no state dir is set.
        let timings = Arc::new(TurnTimingLog::from_cfg(&cfg));
        // `main` has already run the startup gate, so a plan is guaranteed to resolve here.
        // The fallback is the SAFE one rather than a panic: one slot per model reproduces the
        // pre-0.60.0 single-writer posture.
        let plan = cfg.slot_plan().unwrap_or_else(|_| SlotPlan {
            total: 1,
            per_model: cfg
                .model_registry
                .models
                .iter()
                .map(|m| (m.id.clone(), 1))
                .collect(),
        });
        let slots = Arc::new(SlotTable::new(&plan, cfg.max_queued));
        let scheduler = Scheduler::new(cfg.schedule.clone(), cfg.schedule_file());
        let hook_helper = resolve_hook_helper();
        let limiter = Arc::new(RateLimiter::new(cfg.rate_per_min));
        // Seed the health cache from the registry (configured non-ambient models → optimistic
        // healthy). The live prober is spawned separately in `main` so tests never touch the
        // network — they get the seeded cache and can inject explicit statuses.
        let health = Arc::new(HealthStore::seeded(&cfg.model_registry));
        let st = AppState {
            cfg: Arc::new(cfg),
            jobs: Arc::new(JobStore::new(job_ttl, retrieval_grace, jobs_dir)),
            slots,
            broker: Arc::new(LockBroker::new()),
            hook_helper,
            conversation_locks: Arc::new(ConversationLocks::default()),
            limiter,
            conversations: Arc::new(ConversationStore::new(conversations_file)),
            titles: Arc::new(TitleStore::new(titles_file)),
            flags: Arc::new(FlagStore::new(flags_file)),
            models: Arc::new(ModelStore::new(model_file)),
            health,
            deletions: Arc::new(DeletionStore::new(deletions_file, deletion_retention_ms)),
            devices: Arc::new(DeviceStore::new(device_file)),
            notify: Arc::new(NotifyFlags::new()),
            apns: None,
            breaker: Arc::new(CircuitBreaker::new()),
            meal_corrections,
            context: Arc::new(ContextLedger::new(context_file, context_enabled)),
            timings,
            // One shadow child at a time; separate from the production permit.
            shadow_slot: Arc::new(Semaphore::new(1)),
            scheduler,
        };
        st.bootstrap_conversations();
        st
    }

    /// Reconcile the persisted stores at construction, once.
    ///
    /// 1. Scan the projects dirs and LOG the transcripts with no conversation record,
    ///    adopting none of them. Those dirs are keyed only on the cwd, so every `claude`
    ///    run with that cwd writes into them; a transcript the bridge did not start is
    ///    not the bridge's to list. The reverse index therefore comes purely from the
    ///    persisted records, which is where the sessions the bridge actually started
    ///    already are.
    /// 2. Re-key the title, flag, and deletion stores off session ids and onto
    ///    conversation ids through that index, ONCE per state dir (the flag is persisted
    ///    in `conversations.json`).
    ///
    /// Nothing here can fail loudly: a missing projects dir reports nothing, and with no
    /// state dir configured the whole registry is in-memory so the migration is a no-op
    /// against empty stores.
    fn bootstrap_conversations(&self) {
        let unowned: Vec<String> = self
            .transcript_dirs()
            .iter()
            .flat_map(|dir| report_unowned_transcripts(dir, &self.conversations))
            .map(|(stem, _)| stem)
            .collect();
        if !unowned.is_empty() {
            eprintln!(
                "jesse-bridge: {} transcript(s) in the projects dir(s) have no conversation \
                 record; left alone (not started by this bridge)",
                unowned.len()
            );
        }
        if self.conversations.migration_done() {
            return;
        }
        let counts = migrate_keys_to_conversations(
            &self.conversations,
            &self.titles,
            &self.flags,
            &self.deletions,
        );
        self.conversations.mark_migration_done();
        if counts != MigrationCounts::default() {
            eprintln!(
                "jesse-bridge: conversation key migration: titles moved={} dropped={}, \
                 flags moved={} dropped={}, deletions converted={}",
                counts.titles_moved,
                counts.titles_dropped,
                counts.flags_moved,
                counts.flags_dropped,
                counts.deletions_moved
            );
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
        // Degrade to the always-available default only when the stored active id is unknown
        // or its backend is NOT CONFIGURED — NOT merely unhealthy. A currently-unhealthy
        // active model stays active (per the no-auto-switch rule): its next turn surfaces the
        // failure through the existing retry/emergency path rather than silently switching.
        let m = match registry.get(&id) {
            Some(m) if m.configured => m,
            _ => registry.default_model(),
        };
        self.active_model_for(m)
    }

    /// Resolve a PER-TURN model selection (the request's optional `model` field) to an
    /// `ActiveModel`, validating it EXACTLY as `POST /jesse/model` does: an unknown id is a
    /// `400`, an unconfigured OR unhealthy id is a `409`, and `opus` is always allowed
    /// (healthy by construction). Unlike [`resolve_active_model`] this NEVER degrades a bad id
    /// to the default — a per-turn selection the bridge cannot honor is rejected so the turn
    /// never starts on the wrong model — and it does NOT touch the stored `active`: a per-turn
    /// choice backs only that one turn, so another device's `GET /jesse/models` is unaffected.
    /// The write posture is unchanged: a non-ambient model runs read-only unless writes are
    /// enabled for it (via its `ModelStore` override / registry default).
    pub fn resolve_requested_model(&self, id: &str) -> Result<ActiveModel, ApiError> {
        let id = id.trim();
        match self.cfg.model_registry.get(id) {
            Some(m) => {
                let h = model_health(m, &self.health);
                if h.available() {
                    Ok(self.active_model_for(m))
                } else if !h.configured {
                    Err((
                        StatusCode::CONFLICT,
                        format!("model '{id}' is not configured"),
                    ))
                } else {
                    Err((
                        StatusCode::CONFLICT,
                        format!("model '{id}' is unhealthy (last probe failed)"),
                    ))
                }
            }
            None => Err((StatusCode::BAD_REQUEST, format!("unknown model '{id}'"))),
        }
    }

    /// Build the `ActiveModel` for a resolved registry entry: its `ANTHROPIC_*` env, subagent
    /// model, price deck, harness and LEVEL. Shared by the stored-default resolution and the
    /// per-turn selection so both produce a byte-identical `ActiveModel` for a given model.
    ///
    /// The level comes from the registry (i.e. from config) and nowhere else. It used to be
    /// a per-model boolean the phone could set through `POST /jesse/model/{id}/writes`; that
    /// endpoint and its persisted override are gone, because what a model may touch is a
    /// containment decision the startup gate validates against the containment record, not a
    /// switch on a device.
    ///
    /// The mapping itself lives on [`ActiveModel::from_registry`] so the containment battery
    /// can build the same value without an app state behind it; this stays as the name the
    /// turn path calls, and carries the doc about WHERE the level comes from.
    fn active_model_for(&self, m: &RegistryModel) -> ActiveModel {
        ActiveModel::from_registry(m)
    }

    /// Every transcript directory this bridge's registered harnesses own — the whole disk
    /// surface the conversation store reads (adoption, the GC sweep, the list's mtime and
    /// snippet lookups, hydration, delete). For the shipped `claude-code`-only registry
    /// that is exactly one entry, `~/.claude/projects/<escaped-vault>`, built from the HOME
    /// captured once in `Config`; an unknown HOME yields a path that simply won't exist (→
    /// an empty conversation list), never an error. A harness that keeps no transcripts
    /// contributes nothing, so an empty result is legitimate rather than a fault.
    pub fn transcript_dirs(&self) -> Vec<PathBuf> {
        self.cfg.harnesses.transcript_dirs(&self.cfg)
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
                    subagent_model: None,
                    configured: true,
                    level: Capability::Write,
                    harness: CLAUDE_CODE_ID.to_string(),
                    price: PriceDeck::ZERO,
                    health: HealthConfig::default(),
                    vision: Vec::new(),
                    vision_complementary: false,
                },
                RegistryModel {
                    id: "glm-5.2".into(),
                    label: "GLM 5.2".into(),
                    kind: ModelKind::Hosted,
                    backend: Some(("http://fw".into(), "fw-tok".into(), "glm-model".into())),
                    subagent_model: Some("glm-model".into()),
                    configured: true,
                    level: Capability::Read,
                    harness: CLAUDE_CODE_ID.to_string(),
                    price: PriceDeck::ZERO,
                    health: HealthConfig::default(),
                    vision: Vec::new(),
                    vision_complementary: false,
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
        assert!(a.writes_allowed(), "opus is always writes-on");
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
        assert!(
            !a.writes_allowed(),
            "a non-ambient model is read-only by default"
        );
    }

    /// The level now decides, and it comes from config — there is no per-model override to
    /// honor, because `POST /jesse/model/{id}/writes` and its persisted map are gone.
    #[test]
    fn a_models_level_comes_from_the_registry_not_from_a_client() {
        let st = state_with_glm();
        st.models.set_active("glm-5.2");
        let active = st.resolve_active_model();
        assert_eq!(active.id, "glm-5.2");
        assert!(
            !active.writes_allowed(),
            "a model declared at Read cannot be raised to Write from a device"
        );
        assert_eq!(turn_capability(&active), Capability::Read);
    }

    #[test]
    fn resolve_falls_back_to_opus_when_the_stored_active_is_unavailable() {
        // A stale selection (a model that became unavailable, or an unknown id) must never
        // strand the conversation; the turn degrades to the always-available default.
        let st = state_with_glm();
        st.models.set_active("test-absent"); // a synthetic id, deliberately not in this registry
        let a = st.resolve_active_model();
        assert_eq!(a.id, "opus", "unknown/unavailable active degrades to opus");
        assert!(a.env.is_none());
    }
}
