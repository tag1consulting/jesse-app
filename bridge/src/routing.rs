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
/// THIS IS ONE IMPERFECT PROXY SUBSTITUTED FOR ANOTHER, NOT A CLAIM THAT THEY ARE THE SAME
/// PROPERTY. A model can be trusted with the vault and still be sloppy at parsing a sentence
/// about lunch; trustworthiness and extraction accuracy are different things, and using the
/// first to decide the second is a deliberate approximation. It is a better proxy than the
/// one it replaces (which asked where the process was running rather than anything about the
/// model), it is visible in config rather than implied by deployment, and when it turns out
/// to be wrong the fix is a `level` edit rather than a code change.
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
///
/// **`m.level >= required` is not sufficient on its own, and treating it as sufficient was a
/// live bug rather than a hypothetical.** A level is a ceiling the OPERATOR set; whether the
/// candidate's harness can hand the job's child the posture the job requires is a property of
/// the HARNESS, and is [`Harness::expresses`]. `RoutedJob::Title` requires `Basic` — pure text
/// in, text out, granted nothing because it needs nothing — and a Codex model configured at
/// `Read` satisfies `>= Basic` at every rung of this walk. Codex has no posture below
/// `read-only`, so that title child would have been spawned with a shell and the whole
/// filesystem, for a job whose entire definition is that it needs neither. `DietExtract` is
/// the same shape.
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
        if !harness_expresses(cfg, &m.harness, required) {
            continue;
        }
        if !model_health(m, health).available() {
            continue;
        }
        return Some(m);
    }
    None
}

/// Whether the harness backing a candidate can express the posture a routed job needs.
///
/// A harness this build cannot construct answers `false`: it could not serve the job at all,
/// so skipping it is the same answer arrived at earlier. Such a model is separately refused
/// at startup by [`validate_model_config`], so in a running bridge this is never the reason a
/// candidate is skipped — it is here so the walk stays total without asserting.
fn harness_expresses(cfg: &Config, harness: &str, required: Capability) -> bool {
    cfg.harnesses
        .get(harness)
        .map(|h| h.expresses(required))
        .unwrap_or(false)
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
        // The same two questions as the walk above, for the same reason: the level is the
        // operator's ceiling, and whether the harness HAS the posture is the harness's to
        // say. A conversation running on a harness with no `Basic` must not serve a `Basic`
        // job just because the conversation's own level clears the bar.
        if active.level >= required
            && harness_expresses(cfg, &active.harness, required)
            && exclude != Some(active.id.as_str())
        {
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

    /// A `Read`-level Codex model at the front of the walk, with a registry that can
    /// construct Codex. Codex is not registered in the shipped build yet; the walk's rule has
    /// to be right BEFORE it is, or registration is the moment the bug goes live.
    fn cfg_with_codex_first() -> Config {
        let mut m = model("codex-mini", Capability::Read);
        m.harness = CODEX_ID.to_string();
        let mut cfg = cfg_with(vec![m, model("local-oss", Capability::Read)], &[
            "codex-mini",
            "local-oss",
        ]);
        cfg.harnesses = Arc::new(HarnessRegistry::new(vec![Box::new(Codex)]));
        cfg
    }

    /// THE BUG THIS CHECK EXISTS FOR, stated as a test rather than as a comment.
    ///
    /// `Title` requires `Basic` — text in, text out, granted nothing because it needs
    /// nothing. A Codex model configured at `Read` clears `>= Basic`, so on level alone it
    /// wins the walk; and because Codex has no posture below `read-only`, that title child
    /// would be spawned with a shell and the whole filesystem. `DietExtract` is the same
    /// shape. The next candidate — a harness that HAS `Basic` — must serve them instead.
    #[test]
    fn a_harness_without_basic_never_wins_the_walk_for_a_basic_job() {
        let cfg = cfg_with_codex_first();
        let health = all_healthy(&cfg);
        for job in [RoutedJob::Title, RoutedJob::DietExtract] {
            assert_eq!(job.required(), Capability::Basic, "precondition for {job:?}");
            let picked = pick_offload_model(&cfg, &health, job.required(), None)
                .expect("the next candidate serves it");
            assert_eq!(
                picked.id, "local-oss",
                "{job:?} went to a harness with no `basic` posture"
            );
            assert_eq!(route_job(&cfg, &health, job, None, None).id, "local-oss");
        }
    }

    /// …and the same model is not blacklisted, only skipped where it has nothing to offer:
    /// at a level Codex DOES express it wins the walk exactly as any other candidate would.
    #[test]
    fn a_harness_without_basic_still_wins_the_walk_at_a_level_it_expresses() {
        let cfg = cfg_with_codex_first();
        let health = all_healthy(&cfg);
        let picked = pick_offload_model(&cfg, &health, Capability::Read, None)
            .expect("read is a posture codex has");
        assert_eq!(picked.id, "codex-mini");
    }

    /// The conversation rung asks the same two questions as the walk. A conversation running
    /// on a harness with no `Basic` must not serve a `Basic` job just because its own level
    /// clears the bar — it would spawn the same over-granted child by a different route.
    #[test]
    fn the_conversation_rung_also_reads_the_declaration() {
        let mut cfg = cfg_with_codex_first();
        cfg.offload_order.clear(); // no walk candidate: the conversation is the next rung
        let health = all_healthy(&cfg);
        let mut active = ActiveModel::ambient();
        active.id = "codex-mini".to_string();
        active.harness = CODEX_ID.to_string();
        active.level = Capability::Read;
        let pick = route_job(&cfg, &health, RoutedJob::Title, Some(&active), None);
        assert_eq!(
            pick.id, DEFAULT_MODEL_ID,
            "a Basic job fell through to ambient rather than to a harness with no Basic"
        );
        // The same conversation model DOES serve a job at a level it expresses.
        let pick = route_job(&cfg, &health, RoutedJob::VaultQa, Some(&active), None);
        assert_eq!(pick.id, "codex-mini");
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

    /// THE GOLDEN CASE, stated as one test: with NONE of the three keys set, model
    /// selection and every serving path behave exactly as before this prompt.
    ///
    /// Each assertion pins one thing the three keys could have changed silently:
    /// which model a routed job lands on, what env its child carries, whether the local
    /// routes arm at all, and what the main turn is granted.
    #[test]
    fn with_none_of_the_three_keys_set_nothing_changes() {
        let cfg = test_config(); // no `level`, no `harness`, no `offload_order`
        assert!(cfg.offload_order.is_empty(), "no offload_order by default");
        let health = HealthStore::seeded(&cfg.model_registry);

        // 1. Every routed job lands on ambient, which applies no backend env — exactly
        //    what each role call site did when its override was unset.
        for job in [
            RoutedJob::Title,
            RoutedJob::DietExtract,
            RoutedJob::DietVerify,
            RoutedJob::VaultQa,
        ] {
            let pick = route_job(&cfg, &health, job, None, None);
            assert_eq!(pick.id, DEFAULT_MODEL_ID, "{job:?} routes to ambient");
            assert!(pick.backend.is_none(), "{job:?} applies no env");
            assert_eq!(pick.harness, CLAUDE_CODE_ID);
        }

        // 2. The local routes stay DORMANT, so every Tell and Ask takes the hosted path —
        //    the kill switch an unset role triple used to be.
        assert!(!has_offload_candidate(&cfg, &health, RoutedJob::DietExtract));
        assert!(!has_offload_candidate(&cfg, &health, RoutedJob::VaultQa));
        assert!(!should_try_local_diet(&cfg, &health, "tell", "logged a banana"));
        assert!(!should_try_local_vaultqa(&cfg, &health, "ask", "what is my vo2 max", false));
        assert!(!emergency_armed(&cfg, &health), "emergency needs a candidate too");

        // 3. The ambient default still backs a conversation at Write, so a main turn is
        //    granted exactly what it was.
        let ambient = ActiveModel::ambient();
        assert_eq!(turn_capability(&ambient), Capability::Write);
        assert!(ambient.writes_allowed());

        // 4. A model declared with no `level` is Read — it can answer, and cannot change
        //    the vault.
        assert_eq!(DEFAULT_MODEL_LEVEL, Capability::Read);
    }

    /// A MAIN TURN NEVER ROUTES AWAY FROM ITS SELECTED MODEL, even when that model is
    /// unhealthy and a perfectly good candidate sits in `offload_order`.
    ///
    /// This is the boundary the routing rule must not cross: answering as a silently
    /// different model is worse than surfacing the failure. The test drives the real
    /// resolution path rather than asserting on a comment.
    #[test]
    fn a_main_turn_never_routes_away_from_its_model_even_when_unhealthy() {
        let cfg = cfg_with(
            vec![
                model("glm", Capability::Write),
                model("healthy-spare", Capability::Write),
            ],
            &["healthy-spare"],
        );
        let health = all_healthy(&cfg);
        mark_unhealthy(&health, "glm");

        // A routed job DOES fall through to the spare — that is the point of the walk.
        let pick = route_job(&cfg, &health, RoutedJob::Title, None, None);
        assert_eq!(pick.id, "healthy-spare");

        // The conversation's model does NOT: resolution keeps an unhealthy but configured
        // model active, and the turn fails visibly rather than answering as someone else.
        let st = AppState::new(cfg);
        st.models.set_active("glm");
        let active = st.resolve_active_model();
        assert_eq!(
            active.id, "glm",
            "an unhealthy conversation model stays selected; the walk must not adopt it"
        );
    }

}
