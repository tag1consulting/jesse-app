use crate::*;

// ---- Which model serves a job the user did not choose ------------------------
//
// ONE ordered list (`offload_order`) and ONE rule, replacing the four per-role backends
// (`JESSE_TITLE_*`, `JESSE_DIET_*`, `JESSE_VAULTQA_*`) that each named a model for one call
// site. Those said WHERE a job runs and, by implication, how much it was trusted; this says
// what a job REQUIRES and lets the config say which models can meet it.
//
// # The boundary this must never cross
//
// THIS GOVERNS ONLY WORK THE USER DID NOT CHOOSE A MODEL FOR. A main turn is not such work.
// The bridge deliberately does NOT auto-switch a conversation off an unhealthy model:
// answering as a silently different model is worse than surfacing the failure, so a main
// turn runs on the model the chip selected or it fails. Nothing here is reachable from the
// main-turn path, and [`AppState::resolve_active_model`] degrades only on an UNCONFIGURED
// id, never on an unhealthy one.
//
// That is the line a later change erodes by accident — "the conversation model is down,
// we already have a fallback list right here" is one line of code and a different product.
// If this rule ever needs to serve a main turn, that is a decision to take deliberately,
// not a reuse of a helper that happened to fit.
//
// # The effective grant rule, stated once so it cannot drift
//
//   * A ROUTED job runs at exactly the job's required capability ([`RoutedJob::required`]),
//     never at the serving model's level. A `Write` model serving a title gets `Basic`.
//   * A MAIN turn runs at the minimum of the model's level and `Write`
//     ([`turn_capability`]). A `Read` model backing a conversation gets the read-only
//     posture.
//
// The level is a CEILING; the job sets the actual grant beneath it. There is no runtime
// ceiling arithmetic beyond those two lines, and no startup check computes a grant — the
// startup gate only refuses to START with a config containment cannot vouch for.

/// A job the bridge runs on the user's behalf without the user having chosen a model for
/// it. Each one names the capability it REQUIRES, which is also the capability its child is
/// granted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutedJob {
    /// Naming a conversation. Text in, text out.
    Title,
    /// Turning an utterance into structured diet JSON. Text in, JSON text out — the BRIDGE
    /// validates and writes it, so the child needs nothing.
    DietExtract,
    /// Checking an extraction against the utterance before it reaches the CSVs.
    DietVerify,
    /// Answering a self-referential question from the vault.
    VaultQa,
}

impl RoutedJob {
    /// The capability this job needs, and is granted.
    ///
    /// `DietVerify` requires **Write**, which looks wrong until you see what it is for.
    /// `Write` is the same trust threshold at which verification is SKIPPED entirely (see
    /// [`skips_verification`]), so a verifier below it would be a model we do not trust to
    /// stand alone checking the work of one we do not trust to stand alone. Requiring
    /// `Write` of the verifier is what keeps the gate meaning something. It needs no write
    /// TOOLS — it returns a verdict as text — so this is the level bar, not a tool grant;
    /// the child still runs at exactly this capability, which is why the verify child's
    /// toolset is unchanged.
    pub fn required(&self) -> Capability {
        match self {
            RoutedJob::Title | RoutedJob::DietExtract => Capability::Basic,
            RoutedJob::VaultQa => Capability::Read,
            RoutedJob::DietVerify => Capability::Write,
        }
    }

    /// The operator-facing name used in the one log line each routed job emits.
    pub fn label(&self) -> &'static str {
        match self {
            RoutedJob::Title => "title",
            RoutedJob::DietExtract => "diet-extract",
            RoutedJob::DietVerify => "diet-verify",
            RoutedJob::VaultQa => "vault-qa",
        }
    }
}

/// Whether an extraction served by a model at this level SKIPS the verify step.
///
/// The extract-then-verify ladder used to encode "where a model runs tells you whether to
/// trust it" — a local backend was probationary, a hosted one was not. That is now stated
/// as a level: at `Write`, take the output; below it, verify.
///
/// This uses the level as a PROXY for extraction accuracy, deliberately, and they are not
/// the same property: a model can be trusted with the vault and still be sloppy at parsing
/// a sentence about lunch. It is a better proxy than the one it replaces (which asked where
/// the process was running), it is visible in config rather than implied by deployment, and
/// when it turns out to be wrong the fix is a `level` edit rather than a code change.
pub fn skips_verification(level: Capability) -> bool {
    level >= Capability::Write
}

/// One routed job's chosen model: what to log, and the backend triple to apply.
#[derive(Debug, Clone, PartialEq)]
pub struct RoutedPick {
    pub id: String,
    pub harness: String,
    pub level: Capability,
    /// The `(base_url, auth_token, model_id)` triple. Always `Some` for a picked
    /// non-ambient model (an unconfigured entry never wins the walk); `None` only for the
    /// ambient entry, which applies nothing.
    pub backend: Option<(String, String, String)>,
}

impl RoutedPick {
    /// The one log line a routed job emits: which candidate served it, by model id and
    /// harness. No prompt content, ever — this is a routing record, not a transcript.
    pub fn log(&self, job: RoutedJob) {
        eprintln!(
            "jesse-bridge: {} → model '{}' (harness {}, level {})",
            job.label(),
            self.id,
            self.harness,
            capability_label(self.level)
        );
    }
}

/// Walk `offload_order` and take the FIRST model that is configured, healthy and at level
/// `required` or above. `None` when none qualifies — the caller then falls back to the
/// conversation's model, and failing that to ambient.
///
/// `exclude` drops one id from the walk. It exists for exactly one caller (diet verify
/// excluding the model that served the extraction) and is threaded here rather than filtered
/// afterwards, because "the next qualifying candidate" and "the first candidate, unless it
/// is the extractor, in which case nothing" are different rules and only the first is right.
///
/// Health is consulted, and this is the one place a routed job may switch models: a routed
/// job has no user-visible identity to betray, so silently using the next candidate is the
/// right behavior — the opposite of the main-turn rule at the top of this module.
pub fn pick_offload_model<'a>(
    cfg: &'a Config,
    health: &HealthStore,
    required: Capability,
    exclude: Option<&str>,
) -> Option<&'a RegistryModel> {
    for id in &cfg.offload_order {
        let Some(m) = cfg.model_registry.get(id) else {
            continue; // an id naming no registry entry: inert, warned about at startup
        };
        if exclude == Some(m.id.as_str()) {
            continue;
        }
        if m.level < required {
            continue;
        }
        if !model_health(m, health).available() {
            continue;
        }
        return Some(m);
    }
    None
}

/// Whether config named a model to OFFLOAD this job to — the walk yields a candidate.
///
/// This is the gate the local routes take: it replaces `cfg.<role>_backend.is_some()`, which
/// asked whether a role's env triple was set. Falling through to ambient is not "offloaded",
/// so a bridge with an empty `offload_order` takes the hosted path for every job exactly as
/// one with no role backends configured did.
pub fn has_offload_candidate(cfg: &Config, health: &HealthStore, job: RoutedJob) -> bool {
    pick_offload_model(cfg, health, job.required(), None).is_some()
}

/// Resolve which model serves one routed job: the `offload_order` walk, then the
/// conversation's model, then ambient.
///
/// The three rungs are deliberate and ordered by how much the user chose them. The walk is
/// config's answer to "cheap models exist, use them for the chores". The conversation's
/// model is the nearest thing to an answer the user gave. Ambient is the floor that always
/// exists — and is the one assumption about ambient this effort keeps rather than adds (see
/// the module docs on [`crate::harness`]).
///
/// A rung is skipped when it cannot meet `required`, so a `Basic` conversation model does
/// not serve a `Read` job by accident.
pub fn route_job(
    cfg: &Config,
    health: &HealthStore,
    job: RoutedJob,
    conversation: Option<&ActiveModel>,
    exclude: Option<&str>,
) -> RoutedPick {
    let required = job.required();
    if let Some(m) = pick_offload_model(cfg, health, required, exclude) {
        let pick = RoutedPick {
            id: m.id.clone(),
            harness: m.harness.clone(),
            level: m.level,
            backend: m.backend.clone(),
        };
        pick.log(job);
        return pick;
    }
    if let Some(active) = conversation {
        if active.level >= required && exclude != Some(active.id.as_str()) {
            let pick = RoutedPick {
                id: active.id.clone(),
                harness: active.harness.clone(),
                level: active.level,
                backend: active.env.clone(),
            };
            pick.log(job);
            return pick;
        }
    }
    // Ambient: applies no backend env, so the child inherits the bridge's process env —
    // exactly what every role call site did before this rule existed when its override was
    // unset.
    let pick = RoutedPick {
        id: DEFAULT_MODEL_ID.to_string(),
        harness: CLAUDE_CODE_ID.to_string(),
        level: Capability::Write,
        backend: None,
    };
    pick.log(job);
    pick
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    /// A configured, healthy registry entry at `level`.
    fn model(id: &str, level: Capability) -> RegistryModel {
        RegistryModel {
            id: id.to_string(),
            label: id.to_string(),
            kind: ModelKind::Local,
            backend: Some((
                format!("http://{id}.invalid"),
                "tok".to_string(),
                format!("{id}-v1"),
            )),
            subagent_model: None,
            configured: true,
            level,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: Vec::new(),
            vision_complementary: false,
        }
    }

    fn cfg_with(models: Vec<RegistryModel>, order: &[&str]) -> Config {
        let mut cfg = test_config();
        let mut all = cfg.model_registry.models.clone(); // keeps the ambient entry
        all.extend(models);
        cfg.model_registry = ModelRegistry { models: all };
        cfg.offload_order = order.iter().map(|s| s.to_string()).collect();
        cfg
    }

    /// Every configured model in `cfg` seeded healthy — the startup state.
    fn all_healthy(cfg: &Config) -> HealthStore {
        HealthStore::seeded(&cfg.model_registry)
    }

    /// Mark one model unhealthy, as a failed probe would.
    fn mark_unhealthy(health: &HealthStore, id: &str) {
        health.set(
            id,
            HealthStatus {
                healthy: false,
                checked_at_ms: 1,
                latency_ms: None,
                last_error_class: Some("connect".to_string()),
            },
        );
    }

    #[test]
    fn the_walk_takes_the_first_qualifying_candidate() {
        let cfg = cfg_with(
            vec![model("local", Capability::Read), model("glm", Capability::Write)],
            &["local", "glm"],
        );
        let pick = pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Read, None)
            .expect("a candidate qualifies");
        assert_eq!(pick.id, "local", "first in the list wins");
    }

    #[test]
    fn a_model_below_the_required_level_is_skipped() {
        // A Basic model cannot serve a Read job — the walk moves on rather than downgrading
        // the job to what the cheap model can do.
        let cfg = cfg_with(
            vec![
                model("tiny", Capability::Basic),
                model("local", Capability::Read),
            ],
            &["tiny", "local"],
        );
        let pick = pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Read, None).unwrap();
        assert_eq!(pick.id, "local");
        // …and for a Basic job the same list picks the cheap one.
        let pick = pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Basic, None).unwrap();
        assert_eq!(pick.id, "tiny");
    }

    #[test]
    fn an_unconfigured_or_unknown_candidate_is_skipped() {
        let mut unarmed = model("unarmed", Capability::Write);
        unarmed.configured = false;
        unarmed.backend = None;
        let cfg = cfg_with(
            vec![unarmed, model("glm", Capability::Write)],
            &["nosuchmodel", "unarmed", "glm"],
        );
        let pick = pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Basic, None).unwrap();
        assert_eq!(pick.id, "glm");
    }

    #[test]
    fn an_unhealthy_first_candidate_falls_through_to_the_next() {
        let cfg = cfg_with(
            vec![model("local", Capability::Write), model("glm", Capability::Write)],
            &["local", "glm"],
        );
        let health = all_healthy(&cfg);
        mark_unhealthy(&health, "local");
        let pick = pick_offload_model(&cfg, &health, Capability::Basic, None).unwrap();
        assert_eq!(pick.id, "glm", "an unhealthy candidate is passed over");
    }

    #[test]
    fn the_excluded_model_never_wins_the_walk() {
        // The diet-verify rule: the model that served the extraction is out of the running,
        // so it cannot verify its own work.
        let cfg = cfg_with(
            vec![model("local", Capability::Write), model("glm", Capability::Write)],
            &["local", "glm"],
        );
        let pick = pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Write, Some("local")).unwrap();
        assert_eq!(pick.id, "glm");
        // With only the extractor qualifying, nothing does.
        let cfg = cfg_with(vec![model("local", Capability::Write)], &["local"]);
        assert!(
            pick_offload_model(&cfg, &all_healthy(&cfg), Capability::Write, Some("local")).is_none(),
            "a lone extractor cannot verify itself"
        );
    }

    #[test]
    fn an_empty_offload_order_routes_to_ambient() {
        // THE GOLDEN CASE: with none of the three keys set, every routed job lands on
        // ambient, which applies no backend env — exactly what each role call site did when
        // its override was unset.
        let cfg = cfg_with(Vec::new(), &[]);
        for job in [
            RoutedJob::Title,
            RoutedJob::DietExtract,
            RoutedJob::DietVerify,
            RoutedJob::VaultQa,
        ] {
            let pick = route_job(&cfg, &all_healthy(&cfg), job, None, None);
            assert_eq!(pick.id, DEFAULT_MODEL_ID);
            assert!(pick.backend.is_none(), "ambient applies nothing");
        }
    }

    #[test]
    fn the_conversation_model_is_the_middle_rung_and_must_also_meet_the_bar() {
        let cfg = cfg_with(Vec::new(), &[]);
        let mut convo = ActiveModel::ambient();
        convo.id = "glm".to_string();
        convo.level = Capability::Read;
        convo.env = Some(("http://glm".into(), "tok".into(), "glm-v1".into()));
        // A Read conversation model serves a Read job…
        let pick = route_job(&cfg, &all_healthy(&cfg), RoutedJob::VaultQa, Some(&convo), None);
        assert_eq!(pick.id, "glm");
        // …but not a Write one; that falls through to ambient.
        let pick = route_job(&cfg, &all_healthy(&cfg), RoutedJob::DietVerify, Some(&convo), None);
        assert_eq!(pick.id, DEFAULT_MODEL_ID);
    }

    #[test]
    fn diet_verify_requires_write_and_the_other_jobs_do_not() {
        assert_eq!(RoutedJob::DietVerify.required(), Capability::Write);
        assert_eq!(RoutedJob::VaultQa.required(), Capability::Read);
        assert_eq!(RoutedJob::Title.required(), Capability::Basic);
        assert_eq!(RoutedJob::DietExtract.required(), Capability::Basic);
    }

    #[test]
    fn verification_is_skipped_exactly_at_write() {
        assert!(skips_verification(Capability::Write));
        assert!(!skips_verification(Capability::Read));
        assert!(!skips_verification(Capability::Basic));
    }
}
