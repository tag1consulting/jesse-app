use crate::*;

// ---- Per-model concurrency slots + a global ceiling --------------------------
//
// Until 0.60.0 the bridge ran exactly ONE turn at a time across every client and every
// model: a single `Semaphore` sized from `max_concurrency` (default 1), with a bounded queue
// in front of it and a 429 beyond that. The comment above that key said what it was really
// for — "a single global write lock, at most one turn may rewrite vault files at a time" —
// which is the honest admission that the concurrency limit was standing in for a lock the
// bridge did not have. Now it has one ([`crate::writelock`]), so the limit can do its own job.
//
// TWO STRUCTURES, BOTH NEEDED:
//
//   * PER-MODEL SLOTS, keyed on model id. This is what was actually asked for: every enabled
//     model serves at least one thread, and some serve more.
//   * A GLOBAL CEILING across all models. Without it, six configured models at three slots
//     each would put eighteen agent children on one machine.
//
// NOTHING HERE BRANCHES ON A HARNESS ID. The harness is consulted exactly once, at startup,
// for a default ([`Harness::default_concurrency`]) and for a safety cap
// ([`Harness::supports_write_lock`]). After that a slot count is a number in a table, and the
// gates cannot tell one harness from another. That is the property that makes a third harness
// an implementation rather than a rewrite.
//
// THE QUEUES ARE PER MODEL, and that is load-bearing rather than incidental: a busy Claude
// queue must not shed a Codex turn that has a free slot. Stated generally, no harness's
// saturation may shed another harness's admissible turn. Because each model owns its own
// [`QueueGate`], that falls out of the structure instead of resting on a check somewhere.

/// Default total turns in flight across every model (`[concurrency].total`, env
/// `JESSE_MAX_TURNS`).
///
/// Deliberately modest rather than sized to the machine. The Mac Studio this runs on has 32
/// cores and 512 GB, and a measured Claude Code child is ~400 MB — six children is three
/// orders of magnitude inside what the hardware notices. The number is low because the vault
/// write lock is NEW, and a low ceiling bounds the blast radius of a bug in it. Raise it once
/// the lock has run for a while; the machine is not the constraint.
pub const DEFAULT_TOTAL_CEILING: usize = 6;

/// The slot counts an operator asked for, before they are checked against the registry.
#[derive(Debug, Clone, Default)]
pub struct ConcurrencySettings {
    /// `[concurrency].total`.
    pub total: Option<usize>,
    /// Every other key in `[concurrency]`, by model id.
    pub per_model: HashMap<String, usize>,
    /// A value parsed from the DEPRECATED `JESSE_MAX_CONCURRENCY`, kept separate so the
    /// remap can be announced rather than silently applied.
    pub legacy_max_concurrency: Option<usize>,
    /// `[concurrency]` keys whose value was not a non-negative integer. Carried rather than
    /// dropped so the startup gate can refuse them BY NAME instead of silently ignoring a key
    /// an operator believed was doing something.
    pub invalid: Vec<String>,
}

impl ConcurrencySettings {
    /// Give every named model `n` slots and set the ceiling to `n`.
    ///
    /// For fixtures that want one specific concurrency posture, and it is the honest
    /// translation of the pre-0.60.0 `max_concurrency: n`: back then one number bounded
    /// everything, so reproducing it means setting BOTH the per-model count and the ceiling.
    /// Setting only the ceiling would leave each model on its harness default and change what
    /// a queueing test is actually testing.
    pub fn uniform(n: usize, models: &[&str]) -> Self {
        ConcurrencySettings {
            total: Some(n),
            per_model: models.iter().map(|m| ((*m).to_string(), n)).collect(),
            ..Default::default()
        }
    }
}

/// The resolved plan: what each model actually gets, and the ceiling over all of them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotPlan {
    pub total: usize,
    pub per_model: HashMap<String, usize>,
}

/// The env var overriding one model's slots, e.g. `JESSE_MODEL_CODEX_WRITE_CONCURRENCY`.
///
/// Ids are upper-cased with `-` and `.` folded to `_`, so `codex-write` → `CODEX_WRITE` and
/// `glm-5.2` → `GLM_5_2`.
pub fn model_concurrency_env(id: &str) -> String {
    let sanitized: String = id
        .to_ascii_uppercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    format!("JESSE_MODEL_{sanitized}_CONCURRENCY")
}

/// Resolve the slot plan, or return every problem with it.
///
/// Errors rather than warnings, and they join the SAME startup gate that refuses an unknown
/// harness id — a misspelled `[concurrency]` key that silently did nothing would be a config
/// surface that lies about what it did. The `[concurrency]` table can afford to be strict
/// where the `[[models]]` deserializer cannot: that one deliberately ignores unknown keys so
/// a forward-looking example file parses (which is why `default_writes` has to be kept as a
/// field just to refuse it), whereas this table's whole key space is model ids and an id that
/// is not in the registry is unambiguously a mistake.
pub fn resolve_slot_plan(
    registry: &ModelRegistry,
    harnesses: &HarnessRegistry,
    settings: &ConcurrencySettings,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<SlotPlan, Vec<String>> {
    let mut errors = Vec::new();
    let mut per_model = HashMap::new();

    for id in &settings.invalid {
        errors.push(format!(
            "[concurrency] gives '{id}' a value that is not a whole number of slots"
        ));
    }

    // Every `[concurrency]` key must name a model the registry actually has.
    for id in settings.per_model.keys() {
        if registry.get(id).is_none() {
            errors.push(format!(
                "[concurrency] names '{id}', which is not a configured model. Known models: {}",
                known_ids(registry)
            ));
        }
    }

    for m in registry.models.iter() {
        let harness = harnesses.get(&m.harness);
        // 1. env override, 2. `[concurrency]` entry, 3. the HARNESS's declared default.
        let requested = env(&model_concurrency_env(&m.id))
            .and_then(|s| s.trim().parse::<usize>().ok())
            .or_else(|| settings.per_model.get(&m.id).copied())
            .unwrap_or_else(|| harness.map(|h| h.default_concurrency()).unwrap_or(1));

        if requested == 0 {
            errors.push(format!(
                "model '{}' is configured with 0 concurrency slots; a model is disabled by \
                 removing it, not by giving it zero slots",
                m.id
            ));
            continue;
        }

        // THE FAIL-SAFE CAP, and the reason `supports_write_lock` defaults to false.
        //
        // A harness that cannot participate in the vault write lock may not run two
        // write-level turns at once, whatever the config says. Adding a third harness that
        // implements nothing must produce a THROTTLED bridge, never an unlocked vault — so
        // this clamps rather than erroring, and says so out loud.
        let write_level = m.level >= Capability::Write;
        let locks = harness.map(|h| h.supports_write_lock()).unwrap_or(false);
        let granted = if write_level && !locks && requested > 1 {
            eprintln!(
                "jesse-bridge: model '{}' asked for {} slots but its harness ({}) declares no \
                 vault write lock; capping at 1 write-level turn.",
                m.id, requested, m.harness
            );
            1
        } else {
            requested
        };
        per_model.insert(m.id.clone(), granted);
    }

    // The ceiling: an explicit env override, then the file, then the DEPRECATED key, then the
    // default.
    let total = env("JESSE_MAX_TURNS")
        .and_then(|s| s.trim().parse::<usize>().ok())
        .filter(|n| *n >= 1)
        .or(settings.total)
        .or(settings.legacy_max_concurrency)
        .unwrap_or(DEFAULT_TOTAL_CEILING)
        .max(1);

    if !errors.is_empty() {
        return Err(errors);
    }
    Ok(SlotPlan { total, per_model })
}

fn known_ids(registry: &ModelRegistry) -> String {
    let mut ids: Vec<&str> = registry.models.iter().map(|m| m.id.as_str()).collect();
    ids.sort_unstable();
    ids.join(", ")
}

/// One lock per conversation, so two turns of one thread never run at once.
///
/// **This is not optional and it is independent of the slot count.** Two turns of one
/// conversation resume the same underlying session — Claude Code by `--resume <id>`, Codex by
/// `codex exec resume <id>`, each with the same synthetic `local-<hex>` exclusion — so the
/// second would resume a transcript the first is still writing. The hazard is identical in
/// shape on both harnesses, which is exactly why this is ONE bridge-level lock in front of the
/// model gate rather than anything per harness.
///
/// A second turn QUEUES rather than being rejected. The phone routinely fires a second message
/// before the first reply lands, and turning that into an error would be a worse experience
/// than a spinner that says what it is waiting for.
#[derive(Default)]
pub struct ConversationLocks {
    locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl ConversationLocks {
    /// The lock for one conversation, creating it on first use.
    pub fn get(&self, conversation: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.locks
            .lock_ok()
            .entry(conversation.to_string())
            .or_default()
            .clone()
    }

    /// Whether a turn of this conversation is running right now — the difference between
    /// "you are waiting for a slot" and "you are waiting for your own previous message",
    /// which is the one wait distinction a user can actually act on.
    pub fn is_busy(&self, conversation: &str) -> bool {
        self.locks
            .lock_ok()
            .get(conversation)
            .map(|m| m.try_lock().is_err())
            .unwrap_or(false)
    }

    /// Drop the entry for a conversation nobody is using, so the map does not grow forever.
    pub fn retire(&self, conversation: &str) {
        let mut g = self.locks.lock_ok();
        if let Some(m) = g.get(conversation) {
            // Only when nothing holds it — a live waiter still needs the same object.
            if Arc::strong_count(m) == 1 && m.try_lock().is_ok() {
                g.remove(conversation);
            }
        }
    }
}

/// What the phone shows while a turn waits for its own conversation's previous turn.
pub const CONVERSATION_WAIT_ACTIVITY: &str = "waiting for the previous message in this thread";

/// Locate the `jesse-hook` helper: beside the running binary, which is where cargo and the
/// deploy script both put it.
///
/// `None` disarms the write lock, and disarming is SAFE rather than convenient: without a
/// helper no turn is handed a [`WriteLockChild`], and `resolve_slot_plan` has already capped
/// every write-level model at one slot for any harness that cannot lock. A bridge that cannot
/// find its own helper runs like 0.59.0 did, not like an unlocked 0.60.0.
pub fn resolve_hook_helper() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let candidate = exe.parent()?.join("jesse-hook");
    candidate.is_file().then_some(candidate)
}

/// Why a turn is waiting. Three distinct causes, and the phone is told about two of them —
/// see [`WaitReason::hint`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitReason {
    /// Every slot for this model is busy.
    ModelBusy,
    /// The model has a free slot but the global ceiling is reached.
    CeilingReached,
}

impl WaitReason {
    /// What the phone shows under the spinner.
    ///
    /// BOTH slot reasons collapse to one hint on purpose. A user can act on "another message
    /// in this thread is still running" — they know they sent two. They cannot act on the
    /// difference between "this model is busy" and "the bridge is at its ceiling", and
    /// showing them a distinction they cannot use is noise. The distinction IS kept in the
    /// log, where an operator debugging a stuck queue needs it.
    pub fn hint(&self, model: &str) -> String {
        match self {
            WaitReason::ModelBusy | WaitReason::CeilingReached => {
                format!("waiting for a free {model} slot")
            }
        }
    }
}

/// Both permits a running turn holds, for the whole turn.
pub struct TurnPermits {
    _model: OwnedSemaphorePermit,
    _ceiling: OwnedSemaphorePermit,
}

/// A turn's admission decision.
pub enum TurnAdmission {
    /// The model slot is in hand. `ceiling` is `None` when the global ceiling was full — the
    /// task awaits it, still holding the model slot (see the ordering note on [`SlotTable`]).
    Ready {
        model: OwnedSemaphorePermit,
        ceiling: Option<OwnedSemaphorePermit>,
        reason: Option<WaitReason>,
    },
    /// No model slot; the model's own wait queue had room.
    Queued { ticket: QueueTicket },
}

/// Per-model slots plus the global ceiling.
///
/// # Acquisition order, and why it is model-then-ceiling
///
/// A turn needs a model permit AND a ceiling permit, and both are taken in ONE fixed order
/// everywhere: **model slot first, then the global ceiling**. A fixed order is what rules out
/// deadlock; WHICH order is decided by starvation.
///
/// Taking the ceiling first would mean a turn could sit on scarce shared ceiling capacity
/// while parked on its own model's slot — capacity a DIFFERENT model could have used. Taking
/// the model slot first means a turn parked on the ceiling is only holding a slot that its
/// own model's other turns are competing for, and those turns are blocked either way.
///
/// The full bridge-wide order, outermost first, is:
///
/// ```text
/// conversation lock → model slot → global ceiling → per-file write lock → global git lock
/// ```
pub struct SlotTable {
    /// One gate per model, each over that model's own semaphore. Per-model queues are what
    /// stop a saturated harness shedding another harness's admissible turn.
    models: HashMap<String, Arc<QueueGate>>,
    ceiling: Arc<Semaphore>,
    limits: HashMap<String, usize>,
    total: usize,
}

impl SlotTable {
    pub fn new(plan: &SlotPlan, max_queued: usize) -> Self {
        let models = plan
            .per_model
            .iter()
            .map(|(id, n)| {
                let sem = Arc::new(Semaphore::new(*n));
                (id.clone(), QueueGate::new(sem, max_queued))
            })
            .collect();
        SlotTable {
            models,
            ceiling: Arc::new(Semaphore::new(plan.total.max(1))),
            limits: plan.per_model.clone(),
            total: plan.total.max(1),
        }
    }

    /// This model's configured slot count, for logging.
    pub fn limit_for(&self, model: &str) -> usize {
        self.limits.get(model).copied().unwrap_or(1)
    }

    pub fn total(&self) -> usize {
        self.total
    }

    /// Turns of this model currently waiting for a slot.
    pub fn waiting_for(&self, model: &str) -> usize {
        self.models.get(model).map(|g| g.waiting()).unwrap_or(0)
    }

    /// Free slots right now, for the admission log line.
    pub fn free_for(&self, model: &str) -> usize {
        self.models.get(model).map(|g| g.available()).unwrap_or(0)
    }

    pub fn ceiling_free(&self) -> usize {
        self.ceiling.available_permits()
    }

    /// Is ANY live turn running or waiting, on any model?
    ///
    /// The shadow comparison path's yield check. It must stay STRICTLY BEHIND live turns, and
    /// raising concurrency must not let shadow work consume the new slots — so this asks about
    /// the whole table rather than one model, and the shadow child runs only when the bridge
    /// is completely idle. Before 0.60.0 this was "the one global permit is free and nobody is
    /// queued"; the generalisation keeps the same meaning against N models.
    pub fn production_busy(&self) -> bool {
        self.ceiling.available_permits() < self.total
            || self.models.values().any(|g| g.waiting() > 0)
    }

    /// Decide whether this turn runs now, waits, or is shed.
    ///
    /// `None` sheds with 429. A model with no entry in the table (which the startup gate
    /// makes impossible for a configured model) is refused rather than silently given an
    /// unbounded slot.
    pub fn admit(&self, model: &str, conversation_busy: bool) -> Option<TurnAdmission> {
        let gate = self.models.get(model)?;
        // A turn whose own conversation is still running MUST NOT take a model slot here and
        // then park on the conversation lock — see `QueueGate::admit_queued_only`.
        let decision = if conversation_busy {
            gate.admit_queued_only()?
        } else {
            gate.admit()?
        };
        match decision {
            Admission::Ready(model_permit) => {
                // Model slot in hand; try the ceiling without blocking the request path.
                let ceiling = self.ceiling.clone().try_acquire_owned().ok();
                let reason = ceiling.is_none().then_some(WaitReason::CeilingReached);
                Some(TurnAdmission::Ready {
                    model: model_permit,
                    ceiling,
                    reason,
                })
            }
            Admission::Queued(ticket) => Some(TurnAdmission::Queued { ticket }),
        }
    }

    /// Await the global ceiling, having already taken the model slot.
    pub async fn acquire_ceiling(&self) -> OwnedSemaphorePermit {
        self.ceiling
            .clone()
            .acquire_owned()
            .await
            .expect("the ceiling semaphore is never closed")
    }

    /// Bundle both permits so a turn holds them for its whole life.
    pub fn permits(model: OwnedSemaphorePermit, ceiling: OwnedSemaphorePermit) -> TurnPermits {
        TurnPermits {
            _model: model,
            _ceiling: ceiling,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(total: usize, models: &[(&str, usize)]) -> SlotPlan {
        SlotPlan {
            total,
            per_model: models.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        }
    }

    #[test]
    fn a_model_at_its_limit_queues_while_another_model_runs_immediately() {
        let t = SlotTable::new(&plan(6, &[("opus", 1), ("codex-write", 2)]), 4);
        let _held = match t.admit("opus", false) {
            Some(TurnAdmission::Ready { model, .. }) => model,
            _ => panic!("the first opus turn must run"),
        };
        // opus is at its limit → the next opus turn queues …
        assert!(
            matches!(t.admit("opus", false), Some(TurnAdmission::Queued { .. })),
            "a model at its slot limit must queue"
        );
        // … while a DIFFERENT model with a free slot runs immediately.
        assert!(
            matches!(
                t.admit("codex-write", false),
                Some(TurnAdmission::Ready { .. })
            ),
            "a different model with a free slot must not be blocked"
        );
    }

    #[test]
    fn a_saturated_harness_does_not_shed_the_other_harnesss_turn() {
        // One slot each, queue depth 1: saturate the claude-code model completely (slot +
        // queue full, so IT would shed) and check the codex model is untouched.
        let t = SlotTable::new(&plan(6, &[("opus", 1), ("codex-write", 1)]), 1);
        let _run = t.admit("opus", false).unwrap();
        let _queued = match t.admit("opus", false) {
            Some(TurnAdmission::Queued { ticket }) => ticket,
            _ => panic!("second opus turn should queue"),
        };
        assert!(
            t.admit("opus", false).is_none(),
            "opus is saturated and sheds"
        );
        assert!(
            matches!(
                t.admit("codex-write", false),
                Some(TurnAdmission::Ready { .. })
            ),
            "a saturated harness must NOT shed an admissible turn on the other harness"
        );
    }

    #[test]
    fn the_global_ceiling_counts_turns_across_harnesses() {
        // Two models on different harnesses, 2 slots each, but a ceiling of 2 overall.
        let t = SlotTable::new(&plan(2, &[("opus", 2), ("codex-write", 2)]), 4);
        let a = t.admit("opus", false).unwrap();
        let b = t.admit("codex-write", false).unwrap();
        for adm in [&a, &b] {
            assert!(
                matches!(
                    adm,
                    TurnAdmission::Ready {
                        ceiling: Some(_),
                        ..
                    }
                ),
                "the first two turns are under the ceiling"
            );
        }
        // A third turn still has a MODEL slot but the ceiling — counted across harnesses —
        // is reached, so it must wait rather than run.
        match t.admit("opus", false) {
            Some(TurnAdmission::Ready {
                ceiling, reason, ..
            }) => {
                assert!(ceiling.is_none(), "the ceiling must be exhausted");
                assert_eq!(reason, Some(WaitReason::CeilingReached));
            }
            _ => panic!("a free model slot admits Ready, pending the ceiling"),
        }
    }

    #[test]
    fn a_cancelled_queued_turn_frees_its_slot_and_spawns_nothing() {
        let t = SlotTable::new(&plan(6, &[("opus", 1)]), 2);
        let _held = t.admit("opus", false).unwrap();
        let ticket = match t.admit("opus", false) {
            Some(TurnAdmission::Queued { ticket }) => ticket,
            _ => panic!("queued"),
        };
        assert_eq!(t.waiting_for("opus"), 1);
        drop(ticket); // the cancel path: the task is aborted before it ever spawns a child
        assert_eq!(
            t.waiting_for("opus"),
            0,
            "a cancelled queued turn frees its slot"
        );
    }

    #[test]
    fn an_unknown_model_is_refused_not_given_an_unbounded_slot() {
        let t = SlotTable::new(&plan(6, &[("opus", 1)]), 4);
        assert!(t.admit("no-such-model", false).is_none());
    }

    // ---- The conversation lock ------------------------------------------------

    /// Both harnesses resume the same underlying session, so the hazard is identical in shape
    /// and the lock is ONE bridge-level thing. Parameterised over the two harnesses' models so
    /// the claude-code and codex cases are both covered by construction rather than by two
    /// copies of the same assertion.
    #[tokio::test]
    async fn two_turns_in_one_conversation_never_run_concurrently_on_either_harness() {
        for model in ["opus", "codex-write"] {
            // Slots deliberately GENEROUS: this must hold whatever the slot count says.
            let t = SlotTable::new(&plan(6, &[("opus", 3), ("codex-write", 3)]), 4);
            let locks = ConversationLocks::default();
            let conv = format!("conv-on-{model}");

            let _first = locks
                .get(&conv)
                .try_lock_owned()
                .expect("first turn takes it");
            assert!(
                locks.is_busy(&conv),
                "a running turn marks the conversation busy"
            );
            // A second turn of the SAME conversation cannot take it …
            assert!(
                locks.get(&conv).try_lock_owned().is_err(),
                "{model}: a second turn of one conversation must not run concurrently"
            );
            // … and because the conversation is busy it is QUEUED rather than handed a slot,
            // so it cannot occupy a slot while parked (head-of-line blocking).
            assert!(
                matches!(t.admit(model, true), Some(TurnAdmission::Queued { .. })),
                "{model}: a busy conversation must queue, not take a slot"
            );
            assert_eq!(
                t.free_for(model),
                3,
                "{model}: a conversation-blocked turn must not consume a slot"
            );
        }
    }

    #[tokio::test]
    async fn a_different_conversation_is_never_blocked_by_a_busy_one() {
        let locks = ConversationLocks::default();
        let _held = locks.get("conv-a").try_lock_owned().unwrap();
        assert!(locks.is_busy("conv-a"));
        assert!(!locks.is_busy("conv-b"));
        assert!(locks.get("conv-b").try_lock_owned().is_ok());
    }

    /// The acquisition order is fixed everywhere — conversation → model → ceiling — so a
    /// contrived race between two models ON DIFFERENT HARNESSES cannot cycle.
    ///
    /// Both turns take their own model slot first and only then contend for the one shared
    /// resource (the ceiling). A cycle would need one turn holding the ceiling and waiting on
    /// a model slot while the other did the reverse, which the fixed order makes unstateable.
    #[tokio::test]
    async fn the_acquisition_order_cannot_deadlock_across_two_harnesses() {
        // One ceiling permit, one slot each, two harnesses.
        let t = Arc::new(SlotTable::new(
            &plan(1, &[("opus", 1), ("codex-write", 1)]),
            4,
        ));
        let a = t.admit("opus", false).unwrap();
        let b = t.admit("codex-write", false).unwrap();
        // Exactly one of them got the ceiling; the other holds only its model slot.
        let (with_ceiling, without) = match (&a, &b) {
            (
                TurnAdmission::Ready {
                    ceiling: Some(_), ..
                },
                TurnAdmission::Ready { ceiling: None, .. },
            ) => (a, b),
            (
                TurnAdmission::Ready { ceiling: None, .. },
                TurnAdmission::Ready {
                    ceiling: Some(_), ..
                },
            ) => (b, a),
            _ => panic!("with a ceiling of 1, exactly one of the two turns holds it"),
        };
        // The one without the ceiling parks on it. It must NOT be able to proceed while the
        // other holds it — and must proceed as soon as that one finishes.
        let t2 = t.clone();
        let waiter = tokio::spawn(async move {
            let _ = without;
            t2.acquire_ceiling().await
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !waiter.is_finished(),
            "the ceiling is held; the other turn must wait"
        );
        drop(with_ceiling); // the first turn ends, releasing model slot AND ceiling
        let got = timeout(Duration::from_secs(5), waiter).await;
        assert!(
            got.is_ok(),
            "releasing the ceiling must let the other harness's turn through — a deadlock here \
             would mean the fixed order was violated somewhere"
        );
    }

    // ---- The extension point ---------------------------------------------------

    /// EVERY id in `KNOWN_HARNESS_IDS` must carry an explicit write-lock declaration.
    ///
    /// Mirrors `every_known_harness_id_can_actually_be_constructed`: a new harness cannot be
    /// added without answering the question, because the answer is what decides whether it may
    /// serve concurrent write-level turns. The DEFAULT is `false`, so forgetting is safe — but
    /// forgetting silently is not, which is what this catches.
    #[test]
    fn every_known_harness_declares_write_lock_support() {
        let reg = HarnessRegistry::for_models(KNOWN_HARNESS_IDS.iter().copied());
        for id in KNOWN_HARNESS_IDS {
            let h = reg
                .get(id)
                .unwrap_or_else(|| panic!("{id} must be constructible"));
            // Both harnesses shipped today declare TRUE, having been verified live against
            // their pinned binaries. A third one answering `false` is legitimate — it is then
            // capped at one write-level slot by the test below — but it must ANSWER.
            assert!(
                h.supports_write_lock(),
                "{id} declares no write-lock support; if that is deliberate, say so here and \
                 accept the one-slot cap, but do not leave it to the default by accident"
            );
            assert!(
                h.default_concurrency() >= 1,
                "{id} must declare at least one slot"
            );
        }
    }

    /// A harness that declares NO write-lock support cannot be granted more than one
    /// write-level slot, whatever the config says.
    ///
    /// **This is the property that makes adding a third harness safe.** Someone who implements
    /// nothing gets a throttled bridge, never an unlocked vault.
    #[test]
    fn a_harness_without_a_write_lock_cannot_get_more_than_one_write_slot() {
        struct Silent;
        impl Harness for Silent {
            fn id(&self) -> &'static str {
                "silent"
            }
            fn streams_text(&self) -> bool {
                false
            }
            fn expresses(&self, _c: Capability) -> bool {
                true
            }
            // Declares a generous default and NO write lock — the exact shape of a harness
            // added by someone who did not read the trait docs.
            fn default_concurrency(&self) -> usize {
                8
            }
            fn capability_args(&self, _c: &Config, _cap: Capability) -> Vec<String> {
                Vec::new()
            }
            fn main_mcp_config(&self) -> &'static str {
                EMPTY_MCP_CONFIG
            }
            fn shipped_rows(&self) -> &'static [ContainmentRow] {
                &[]
            }
            fn transcript_dir(&self, _c: &Config) -> Option<PathBuf> {
                None
            }
            fn build_turn(
                &self,
                _c: &Config,
                _r: &TurnRequest<'_>,
            ) -> Result<Command, HarnessError> {
                Err(HarnessError::unsupported("silent", "a turn"))
            }
            fn attachment_support(&self) -> &'static AttachmentSupport {
                // This fixture never spawns, so it never shows anything to anyone.
                &CLAUDE_CODE_ATTACHMENTS
            }
            fn parser(&self) -> Box<dyn TurnParser> {
                unreachable!("never spawned in this test")
            }
        }
        assert!(
            !Silent.supports_write_lock(),
            "the DEFAULT must be false — that is the whole fail-safe"
        );

        let mut registry = ModelRegistry::opus_only();
        // A WRITE-level model on the silent harness, asking for plenty of slots.
        let mut writer = registry.models[0].clone();
        writer.id = "silent-write".to_string();
        writer.harness = "silent".to_string();
        writer.level = Capability::Write;
        // …and a READ-level one, which is NOT capped: the cap is about vault writes.
        let mut reader = writer.clone();
        reader.id = "silent-read".to_string();
        reader.level = Capability::Read;
        registry.models.push(writer);
        registry.models.push(reader);

        let harnesses = HarnessRegistry::new(vec![Box::new(Silent)]);
        let settings = ConcurrencySettings {
            per_model: HashMap::from([
                ("silent-write".to_string(), 5),
                ("silent-read".to_string(), 5),
            ]),
            ..Default::default()
        };
        let plan = resolve_slot_plan(&registry, &harnesses, &settings, &|_| None)
            .expect("a capped plan still resolves — it clamps, it does not error");
        assert_eq!(
            plan.per_model.get("silent-write"),
            Some(&1),
            "a write-level model on a harness that cannot lock is capped at ONE slot"
        );
        assert_eq!(
            plan.per_model.get("silent-read"),
            Some(&5),
            "a read-level model is not capped — it cannot corrupt the vault"
        );
    }

    #[test]
    fn a_concurrency_key_naming_an_unknown_model_is_a_startup_error() {
        let registry = ModelRegistry::opus_only();
        let harnesses = HarnessRegistry::claude_code_only();
        let settings = ConcurrencySettings {
            per_model: HashMap::from([("opuss".to_string(), 2)]),
            ..Default::default()
        };
        let errors = resolve_slot_plan(&registry, &harnesses, &settings, &|_| None)
            .expect_err("a misspelled model id must not be silently ignored");
        assert!(
            errors.iter().any(|e| e.contains("opuss")),
            "the error must NAME the key: {errors:?}"
        );
    }

    #[test]
    fn the_deprecated_max_concurrency_becomes_the_ceiling() {
        let registry = ModelRegistry::opus_only();
        let harnesses = HarnessRegistry::claude_code_only();
        // An operator who deliberately set 1 must not silently get six turns in flight.
        let settings = ConcurrencySettings {
            legacy_max_concurrency: Some(1),
            ..Default::default()
        };
        let plan = resolve_slot_plan(&registry, &harnesses, &settings, &|_| None).unwrap();
        assert_eq!(
            plan.total, 1,
            "JESSE_MAX_CONCURRENCY=1 must still mean one turn at a time"
        );
        // With nothing set at all, the documented default.
        let plan = resolve_slot_plan(
            &registry,
            &harnesses,
            &ConcurrencySettings::default(),
            &|_| None,
        )
        .unwrap();
        assert_eq!(plan.total, DEFAULT_TOTAL_CEILING);
        assert_eq!(
            plan.per_model.get("opus"),
            Some(&3),
            "opus takes its HARNESS's declared default, like any other model"
        );
    }

    #[test]
    fn model_concurrency_env_folds_punctuation() {
        assert_eq!(
            model_concurrency_env("codex-write"),
            "JESSE_MODEL_CODEX_WRITE_CONCURRENCY"
        );
        assert_eq!(
            model_concurrency_env("glm-5.2"),
            "JESSE_MODEL_GLM_5_2_CONCURRENCY"
        );
    }
}
