use crate::*;

// ---- The startup gate: config cannot grant what containment has not proven ----
//
// This is what makes the committed containment record a GATE rather than documentation.
// The record says which (capability, MCP server set) postures were probed live against the
// pinned binary and what happened. This refuses to START when the running config asks for a
// posture the record cannot vouch for.
//
// # Why it fails closed, loudly, at boot
//
// The models deserializer IGNORES unknown keys, so a key that silently stops being read is
// a silent security downgrade — a deploy that wrote `default_writes = true` would quietly
// become a read-only model, and one that typo'd `level = "wrote"` would quietly become
// `Read`. Every check here therefore produces an ERROR naming the model id, never a warning
// and never a fallback. An absent or unparseable record is likewise fatal rather than
// permissive: "we could not check" must never read as "it is fine".
//
// # What it does NOT do
//
// It computes no ceilings and grants nothing. After it passes, the config is trusted and
// the effective grant is the two-line rule in [`crate::routing`]. There is no runtime
// arithmetic anywhere.

/// The committed containment record, embedded at COMPILE time.
///
/// Embedded rather than read from disk on purpose: the record a build was gated against is
/// a property of the BINARY, so a deploy cannot be pointed at a friendlier file, and a
/// record that stopped parsing breaks the build rather than a boot. This is the
/// `include_str!` `bridge/tests/containment.rs` refers to.
pub const CONTAINMENT_RECORD: &str = include_str!("../containment.toml");

/// The env vars the per-role backends used, deleted along with the roles they configured.
///
/// Each named a MODEL for one call site, which is what `offload_order` replaces. They are
/// checked at startup because a deploy that still exports them is running a launch
/// environment whose author believes it is steering routing, and it is not — a silent
/// no-op is the worst outcome available, so it is an error naming the key that replaced
/// them.
///
/// `JESSE_DIET_PROBATION` is here too: level-gated verification supersedes it (see
/// [`skips_verification`]), so it is not a flag that moved, it is a flag that no longer
/// has a meaning.
///
/// Deliberately NOT in this list, because they are not role backends: `JESSE_DIET_MICRO_COMPLETE`
/// (extraction output shape), `JESSE_VAULTQA_MCP_CONFIG` and `JESSE_MAIN_MCP_CONFIG` (the MCP
/// server set of a call site, which prompt 1 left outside the capability), and `JESSE_SHADOW_*`
/// (a comparison against an unnamed counterpart means nothing).
pub const REMOVED_ROLE_ENV_VARS: &[&str] = &[
    "JESSE_TITLE_BASE_URL",
    "JESSE_TITLE_AUTH_TOKEN",
    "JESSE_TITLE_MODEL",
    "JESSE_DIET_BASE_URL",
    "JESSE_DIET_AUTH_TOKEN",
    "JESSE_DIET_MODEL",
    "JESSE_VAULTQA_BASE_URL",
    "JESSE_VAULTQA_AUTH_TOKEN",
    "JESSE_VAULTQA_MODEL",
    "JESSE_DIET_PROBATION",
];

/// The highest level a harness has a PASSING battery for in the record, or `None` when it
/// has none at all.
///
/// Two rules decide what "passing" means, and both are load-bearing.
///
/// **Every MCP set recorded at a level must pass.** The record keys a row on (capability,
/// MCP server set) because `Read` names two containments the bridge actually spawns. A
/// level granted here can be spawned with either of them, so a level with one passing row
/// and one failing row has not passed.
///
/// **Passing keys on the HARD GATES alone, never on the known-open baselines.** After the
/// path-scoping work the `Write` row still records an open network route and a process that
/// can outlive a turn. A gate that blocked startup on those would make `Write` ungrantable
/// forever — and would turn into steady pressure to stop recording open baselines at all,
/// which would cost the project the one file that says what is actually open.
///
/// It is a CONTIGUOUS PREFIX, not the highest level that happens to be green, because
/// [`Capability`] is cumulative: `Write` implies `Read` implies `Basic`. A model granted
/// `Write` backs a main turn at `Write` AND can serve a routed `Read` job, which spawns the
/// `read` posture — so a green `write` row above a failing `read` row vouches for nothing.
/// The walk therefore stops at the first level that did not pass, and a level with no
/// recorded rows at all stops it too: "not probed" is not "fine".
pub fn highest_passing_level(record: &BatteryResults, harness: &str) -> Option<Capability> {
    if record.harness != harness {
        return None;
    }
    let mut best: Option<Capability> = None;
    for cap in [Capability::Basic, Capability::Read, Capability::Write] {
        let label = capability_label(cap);
        let rows: Vec<&RowResult> = record
            .rows
            .iter()
            .filter(|r| r.capability == label)
            .collect();
        if rows.is_empty() {
            break; // nothing probed here, so nothing at or above it can be vouched for
        }
        // EVERY recorded MCP set at this level, and only the hard gates within each.
        let all_pass = rows.iter().all(|row| {
            row.probes
                .iter()
                .filter(|p| p.class == ProbeClass::HardGate.label())
                .all(|p| p.status == "pass")
        });
        if !all_pass {
            break;
        }
        best = Some(cap);
    }
    best
}

/// One startup rejection: what is wrong, and which model it is wrong for.
#[derive(Debug, Clone, PartialEq)]
pub struct ConfigError {
    /// The model id the problem belongs to, when it has one.
    pub model: Option<String>,
    pub message: String,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.model {
            Some(id) => write!(f, "model '{id}': {}", self.message),
            None => write!(f, "{}", self.message),
        }
    }
}

impl ConfigError {
    fn for_model(id: &str, message: impl Into<String>) -> Self {
        ConfigError {
            model: Some(id.to_string()),
            message: message.into(),
        }
    }
    fn global(message: impl Into<String>) -> Self {
        ConfigError {
            model: None,
            message: message.into(),
        }
    }
}

/// Validate the whole model configuration against the embedded containment record. An empty
/// result means the bridge may start.
///
/// `declared` is the raw `[[models]]` array as parsed (needed for the removed-key check,
/// which asks whether a key was PRESENT — something the built registry can no longer say).
pub fn validate_model_config(
    cfg: &Config,
    declared: &[ModelToml],
    record_text: &str,
) -> Vec<ConfigError> {
    let mut errors = Vec::new();

    // 1. A `default_writes` key anywhere in the models array. Removed, and silently ignored
    //    by the deserializer if we did not look for it — which is the whole reason to look.
    for m in declared {
        if m.default_writes.is_some() {
            let id = m.id.as_deref().unwrap_or("<unnamed>");
            errors.push(ConfigError::for_model(
                id,
                "`default_writes` has been removed; use `level` instead (\"basic\", \"read\" \
                 or \"write\"). Levels live in the bridge config and are not settable from a \
                 client, so the per-model writes toggle is gone with it.",
            ));
        }
        // A `level` that does not parse: refused rather than defaulted, because defaulting a
        // typo to Read is a silent downgrade and defaulting it to Write is worse.
        if let Some(raw) = m.level.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            if parse_capability(raw).is_none() {
                let id = m.id.as_deref().unwrap_or("<unnamed>");
                errors.push(ConfigError::for_model(
                    id,
                    format!("unknown level '{raw}' (expected \"basic\", \"read\" or \"write\")"),
                ));
            }
        }
    }

    // 4. The record itself, FIRST among the checks that depend on it: absent or unparseable
    //    fails closed rather than falling back to permissive.
    let record = match parse_results(record_text) {
        Ok(r) => r,
        Err(e) => {
            errors.push(ConfigError::global(format!(
                "the containment record does not parse ({e}). It is embedded at compile time \
                 and is what says which postures were probed; without it nothing can be \
                 granted, so the bridge refuses to start rather than assuming a posture."
            )));
            return errors;
        }
    };
    if record.rows.is_empty() {
        errors.push(ConfigError::global(
            "the containment record has no rows — nothing has been probed, so no level can \
             be granted.".to_string(),
        ));
        return errors;
    }

    for m in &cfg.model_registry.models {
        // 2. An unregistered harness id.
        if !KNOWN_HARNESS_IDS.contains(&m.harness.as_str()) {
            errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "unknown harness '{}' (registered: {}). A harness id that names nothing \
                     is refused rather than falling back to '{CLAUDE_CODE_ID}' — running a \
                     model under a harness its author did not choose is worse than not \
                     starting.",
                    m.harness,
                    KNOWN_HARNESS_IDS.join(", ")
                ),
            ));
            continue; // the level check below would be meaningless against no harness
        }

        // 3. A level the model's harness has no passing battery row for.
        match highest_passing_level(&record, &m.harness) {
            Some(highest) if m.level <= highest => {}
            Some(highest) => errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "level '{}' is above what harness '{}' has a passing containment battery \
                     for — the record's highest passing level is '{}'. Re-run the battery and \
                     commit a passing row for '{}', or lower this model's level.",
                    capability_label(m.level),
                    m.harness,
                    capability_label(highest),
                    capability_label(m.level),
                ),
            )),
            None => errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "harness '{}' has no passing containment battery row at any level in the \
                     committed record (which was taken against harness '{}'). A (harness, \
                     level) pair with no passing row is not a combination this project ships.",
                    m.harness, record.harness
                ),
            )),
        }
    }

    // 5. A removed role-backend env var still set in the environment.
    for var in REMOVED_ROLE_ENV_VARS {
        if std::env::var(var).map(|v| !v.trim().is_empty()).unwrap_or(false) {
            errors.push(ConfigError::global(format!(
                "{var} is set, but the per-role backends were removed. One ordered \
                 `offload_order` list in the config file replaces all of them; a job now \
                 states the capability it requires and the walk picks the first configured, \
                 healthy model at or above it. Unset {var}."
            )));
        }
    }

    // 6. The posture the record speaks for versus the posture this deployment would run.
    errors.extend(validate_toolset_argv(cfg, &record));

    errors
}

/// Compare the toolset argv this config would actually produce against the one each row was
/// PROBED with, by STRICT EQUALITY.
///
/// This is the piece that makes the record a real gate rather than documentation: config
/// cannot grant what containment has not proven, and it cannot quietly probe one posture and
/// serve another. A deployment whose allowlist has been widened by an environment variable
/// (`JESSE_ALLOWED_TOOLS`) is running a posture the record cannot speak for.
///
/// **No normalization layer, deliberately.** The recorded argv is host-independent today —
/// the path scopes are cwd-relative (`Read(./**)`), so nothing in it varies by deployment —
/// and it must stay that way. If an absolute host path ever lands in the record, this
/// assertion should fail LOUDLY on every other machine rather than silently normalize the
/// difference away. `the_record_carries_no_absolute_host_paths` catches that at commit time
/// so the failure never has to be discovered at boot on someone else's machine.
pub fn validate_toolset_argv(cfg: &Config, record: &BatteryResults) -> Vec<ConfigError> {
    let mut errors = Vec::new();
    for row in &record.rows {
        let Some(cap) = parse_capability(&row.capability) else {
            errors.push(ConfigError::global(format!(
                "the containment record has a row with unknown capability '{}'",
                row.capability
            )));
            continue;
        };
        let running = capability_args(cfg, cap);
        if running != row.toolset_args {
            errors.push(ConfigError::global(format!(
                "the toolset this deployment would run at '{}' is not the one the containment \
                 record was taken with, so the record cannot speak for it.\n  recorded: {:?}\n  \
                 running: {:?}\nThe usual cause is JESSE_ALLOWED_TOOLS / JESSE_DISALLOWED_TOOLS \
                 widening the allowlist. Unset them, or re-run the battery against this posture \
                 and commit the record.",
                row.label(),
                row.toolset_args,
                running,
            )));
        }
    }
    errors
}

/// The one harness-binary check: consulted only for harnesses some configured model
/// actually references, so a config full of Codex models never demands a Claude binary.
///
/// Absence is reported by the caller (startup) rather than being fatal here, because the
/// ambient default's binary is checked by the existing startup probe and this must not
/// duplicate its message.
pub fn harnesses_in_use(cfg: &Config) -> Vec<String> {
    let mut ids: Vec<String> = cfg
        .model_registry
        .models
        .iter()
        .filter(|m| m.configured)
        .map(|m| m.harness.clone())
        // Ambient still exists, so its harness is always in use.
        .chain(std::iter::once(CLAUDE_CODE_ID.to_string()))
        .collect();
    ids.sort();
    ids.dedup();
    ids
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    fn record() -> BatteryResults {
        parse_results(CONTAINMENT_RECORD).expect("the committed record must parse")
    }

    /// A config whose registry holds exactly one declared model.
    fn cfg_with_model(id: &str, harness: &str, level: Capability) -> Config {
        let mut cfg = test_config();
        let mut models = cfg.model_registry.models.clone();
        models.push(RegistryModel {
            id: id.to_string(),
            label: id.to_string(),
            kind: ModelKind::Local,
            backend: Some(("http://x".into(), "tok".into(), "m".into())),
            subagent_model: None,
            configured: true,
            level,
            harness: harness.to_string(),
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: Vec::new(),
            vision_complementary: false,
        });
        cfg.model_registry = ModelRegistry { models };
        cfg
    }

    #[test]
    fn the_committed_record_grants_write_to_claude_code() {
        // The record ships with every hard gate met at all four rows, so the built-in
        // harness may be granted up to Write. If this ever fails, the record regressed and
        // the ambient default itself would stop being grantable.
        assert_eq!(
            highest_passing_level(&record(), CLAUDE_CODE_ID),
            Some(Capability::Write)
        );
        assert_eq!(highest_passing_level(&record(), "codex"), None);
    }

    #[test]
    fn a_clean_config_starts() {
        let cfg = test_config();
        let errors = validate_model_config(&cfg, &[], CONTAINMENT_RECORD);
        assert!(errors.is_empty(), "{errors:?}");
    }

    #[test]
    fn a_leftover_default_writes_is_refused_and_names_level() {
        let decl = vec![ModelToml {
            id: Some("glm-5.2".to_string()),
            default_writes: Some(true),
            ..ModelToml::default()
        }];
        let errors = validate_model_config(&test_config(), &decl, CONTAINMENT_RECORD);
        let e = errors.first().expect("a leftover default_writes must be refused");
        assert_eq!(e.model.as_deref(), Some("glm-5.2"));
        assert!(e.message.contains("`level`"), "{e}");
        assert!(e.to_string().starts_with("model 'glm-5.2'"), "{e}");
    }

    #[test]
    fn an_unparseable_level_is_refused_rather_than_defaulted() {
        let decl = vec![ModelToml {
            id: Some("glm-5.2".to_string()),
            level: Some("wrote".to_string()),
            ..ModelToml::default()
        }];
        let errors = validate_model_config(&test_config(), &decl, CONTAINMENT_RECORD);
        assert!(
            errors.iter().any(|e| e.message.contains("unknown level 'wrote'")),
            "{errors:?}"
        );
    }

    #[test]
    fn an_unregistered_harness_is_refused_and_names_the_model() {
        let cfg = cfg_with_model("codex-mini", "codex", Capability::Read);
        let errors = validate_model_config(&cfg, &[], CONTAINMENT_RECORD);
        let e = errors
            .iter()
            .find(|e| e.model.as_deref() == Some("codex-mini"))
            .expect("an unknown harness must be refused");
        assert!(e.message.contains("unknown harness 'codex'"), "{e}");
        assert!(e.message.contains(CLAUDE_CODE_ID), "{e}");
    }

    #[test]
    fn a_level_above_the_harnesss_battery_is_refused_and_names_the_highest_that_passed() {
        // Doctored record: the write row fails, so Write is ungrantable and Read is the
        // highest that passed.
        let mut r = record();
        for row in r.rows.iter_mut().filter(|r| r.capability == "write") {
            row.status = "failing".to_string();
            if let Some(p) = row
                .probes
                .iter_mut()
                .find(|p| p.class == ProbeClass::HardGate.label())
            {
                p.status = "failing".to_string();
            }
        }
        let text = render_results(&r);
        assert_eq!(
            highest_passing_level(&parse_results(&text).unwrap(), CLAUDE_CODE_ID),
            Some(Capability::Read)
        );
        let cfg = cfg_with_model("bold", CLAUDE_CODE_ID, Capability::Write);
        let errors = validate_model_config(&cfg, &[], &text);
        let e = errors
            .iter()
            .find(|e| e.model.as_deref() == Some("bold"))
            .expect("a level above the battery must be refused");
        assert!(e.message.contains("highest passing level is 'read'"), "{e}");
    }

    #[test]
    fn a_level_passes_only_when_every_mcp_set_at_that_level_passed() {
        // One of the two `read` rows fails: `read` is then not a passing level even though
        // the other row is green. A level granted here can be spawned with either set.
        let mut r = record();
        let row = r
            .rows
            .iter_mut()
            .find(|r| r.capability == "read" && r.mcp_set == "none")
            .expect("the read/none row");
        row.status = "failing".to_string();
        row.probes
            .iter_mut()
            .find(|p| p.class == ProbeClass::HardGate.label())
            .expect("a hard gate")
            .status = "failing".to_string();
        let text = render_results(&r);
        let parsed = parse_results(&text).unwrap();
        assert_eq!(
            highest_passing_level(&parsed, CLAUDE_CODE_ID),
            Some(Capability::Basic),
            "one failing MCP set at `read` disqualifies the level"
        );
    }

    #[test]
    fn a_known_open_baseline_never_blocks_a_level() {
        // The Write row records an open network route and a process that outlives the turn.
        // Passing keys on the hard gates alone, or Write would be ungrantable forever.
        let r = record();
        let write_row = r.row("write", "qmd").expect("the write row");
        assert!(
            write_row.probes.iter().any(|p| p.status == "known_open"),
            "precondition: the Write row has known-open baselines"
        );
        assert_eq!(
            highest_passing_level(&r, CLAUDE_CODE_ID),
            Some(Capability::Write)
        );
    }

    #[test]
    fn a_record_that_does_not_parse_fails_closed() {
        let errors = validate_model_config(&test_config(), &[], "this is not toml {{{");
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(errors[0].message.contains("does not parse"), "{errors:?}");
        // …and a foreign schema is the same failure, not a permissive read.
        let bumped = CONTAINMENT_RECORD.replace("schema = 1", "schema = 99");
        let errors = validate_model_config(&test_config(), &[], &bumped);
        assert!(!errors.is_empty());
    }

    #[test]
    fn a_widened_allowlist_is_refused_with_the_difference() {
        // The assertion that catches a drifting DEPLOYMENT rather than a drifting posture:
        // an env var widened the allowlist, so the record cannot speak for what would run.
        let mut cfg = test_config();
        cfg.allowed_tools = format!("{DEFAULT_ALLOWED_TOOLS},Bash");
        let errors = validate_toolset_argv(&cfg, &record());
        let e = errors.first().expect("a widened allowlist must be refused");
        assert!(e.message.contains("recorded:"), "{e}");
        assert!(e.message.contains("running:"), "{e}");
        assert!(e.message.contains("JESSE_ALLOWED_TOOLS"), "{e}");
    }

    #[test]
    fn the_shipped_posture_matches_the_record_exactly() {
        // Strict equality, no normalization: the shipped defaults ARE what was probed.
        let errors = validate_toolset_argv(&test_config(), &record());
        assert!(errors.is_empty(), "{errors:?}");
    }

    /// The record commits the exact argv it probed, and the startup assertion above compares
    /// it by strict equality with no normalization layer. That only works while the argv is
    /// host-independent. A `Read(//Users/someone/vault/**)` would make every OTHER deployment
    /// fail at boot — so this catches it at commit time instead.
    #[test]
    fn the_record_carries_no_absolute_host_paths() {
        let r = record();
        for row in &r.rows {
            for arg in &row.toolset_args {
                for bad in ["/Users/", "/home/", "/private/var/", "$HOME"] {
                    assert!(
                        !arg.contains(bad),
                        "{}: recorded toolset argv contains an absolute host path ({bad}): \
                         {arg:?}. The startup assertion compares this by strict equality with \
                         no normalization, so a host path here fails every other deployment \
                         at boot. Keep the scopes cwd-relative.",
                        row.label()
                    );
                }
            }
        }
    }

    #[test]
    fn a_removed_role_env_var_still_set_is_refused_and_names_offload_order() {
        let var = "JESSE_VAULTQA_MODEL";
        std::env::set_var(var, "local-oss");
        let errors = validate_model_config(&test_config(), &[], CONTAINMENT_RECORD);
        std::env::remove_var(var);
        let e = errors
            .iter()
            .find(|e| e.message.contains(var))
            .expect("a removed role env var must be refused");
        assert!(e.message.contains("offload_order"), "{e}");
        assert!(e.model.is_none(), "it belongs to no single model");
    }

    #[test]
    fn every_removed_role_var_is_checked_and_the_kept_ones_are_not() {
        for var in REMOVED_ROLE_ENV_VARS {
            assert!(var.starts_with("JESSE_"), "{var}");
        }
        // The four that stay: they name an output shape or an MCP server set, not a model.
        for kept in [
            "JESSE_DIET_MICRO_COMPLETE",
            "JESSE_VAULTQA_MCP_CONFIG",
            "JESSE_MAIN_MCP_CONFIG",
            "JESSE_SHADOW_MODEL",
        ] {
            assert!(
                !REMOVED_ROLE_ENV_VARS.contains(&kept),
                "{kept} is not a role backend and must keep working"
            );
        }
    }

    #[test]
    fn the_harnesses_in_use_always_include_the_ambient_default() {
        let cfg = cfg_with_model("codex-mini", "codex", Capability::Read);
        let ids = harnesses_in_use(&cfg);
        assert!(ids.contains(&CLAUDE_CODE_ID.to_string()));
        assert!(ids.contains(&"codex".to_string()));
    }
}
