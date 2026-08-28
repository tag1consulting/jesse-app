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

/// The committed containment records, embedded at COMPILE time — ONE PER HARNESS.
///
/// Embedded rather than read from disk on purpose: the record a build was gated against is
/// a property of the BINARY, so a deploy cannot be pointed at a friendlier file, and a
/// record that stopped parsing breaks the build rather than a boot. This is the
/// `include_str!` `bridge/tests/containment.rs` refers to.
///
/// A SET rather than one file, because a containment verdict describes a (harness,
/// capability, MCP set) triple and nothing recorded for one harness says anything about
/// another. While this was a single `include_str!` with a single `harness` field there was no
/// path by which a second harness's record could ever be loaded: a Codex model was refused at
/// startup before its argv was compared to anything, and the refusal blamed the record's
/// harness field as though there were one record to blame.
///
/// A harness with no entry here is not a harness this build can vouch for at any level.
pub const CONTAINMENT_RECORDS: &[(&str, &str)] = &[
    (CLAUDE_CODE_ID, include_str!("../containment.toml")),
    (CODEX_ID, include_str!("../containment-codex.toml")),
];

/// The embedded record for one harness, or `None` when this build embeds none for it.
pub fn containment_record(harness: &str) -> Option<&'static str> {
    CONTAINMENT_RECORDS
        .iter()
        .find(|(id, _)| *id == harness)
        .map(|(_, text)| *text)
}

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
///
/// **The prefix runs over the levels this harness EXPRESSES, and skips the ones it does
/// not.** A level a harness does not have cannot be spawned, so a failing row for it says
/// nothing about the levels above — where a failing row for a level the harness DOES have
/// says everything. Without this the walk read Codex's ladder as broken at the bottom and
/// returned `None`, refusing a `read` model whose every `read` row passes, with a message
/// about a battery to re-run that would have changed nothing. That is the whole reason
/// [`Harness::expresses`] is a declaration and not an inference from the record: the record
/// cannot tell "failed" from "does not exist", and only the harness knows which it is.
pub fn highest_passing_level(record: &BatteryResults, harness: &dyn Harness) -> Option<Capability> {
    if record.harness != harness.id() {
        return None;
    }
    let mut best: Option<Capability> = None;
    for cap in [Capability::Basic, Capability::Read, Capability::Write] {
        if !harness.expresses(cap) {
            continue; // not a rung of this harness's ladder — see above
        }
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
///
/// `records` is the embedded set, one per harness ([`CONTAINMENT_RECORDS`]); each model is
/// held against the record for ITS OWN harness and against nothing else.
pub fn validate_model_config(
    cfg: &Config,
    declared: &[ModelToml],
    records: &[(&str, &str)],
) -> Vec<ConfigError> {
    validate_model_config_with_env(cfg, declared, records, &|var| std::env::var(var).ok())
}

/// [`validate_model_config`], with the environment step 5 reads supplied rather than read from
/// the process.
///
/// The seam exists for ONE reason and it is not configurability: `cargo test` runs a module's
/// tests as threads in a SINGLE process, so a test that set a removed role var for real set it
/// for every sibling test running beside it. The gate then reported a global error into some
/// other test's `errors` vec, and whichever test asserted `errors.is_empty()` failed with a
/// message about an env var it had never heard of. Serializing on the shared `ENV_LOCK` would
/// not have fixed it either: the mutating test and the READERS would both have to hold the
/// lock, so any future test added to this module without it silently reopens the race.
///
/// Production has exactly one caller and it passes the real environment. Nothing else should
/// call this to inject a fake env into a running bridge.
pub fn validate_model_config_with_env(
    cfg: &Config,
    declared: &[ModelToml],
    records: &[(&str, &str)],
    env: &dyn Fn(&str) -> Option<String>,
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

    // 4. The records themselves, FIRST among the checks that depend on them: absent or
    //    unparseable fails closed rather than falling back to permissive.
    let mut parsed: Vec<(&str, BatteryResults)> = Vec::new();
    for (harness, text) in records {
        let r = match parse_results(text) {
            Ok(r) => r,
            Err(e) => {
                errors.push(ConfigError::global(format!(
                    "the containment record for harness '{harness}' does not parse ({e}). It \
                     is embedded at compile time and is what says which postures were probed; \
                     without it nothing can be granted, so the bridge refuses to start rather \
                     than assuming a posture."
                )));
                return errors;
            }
        };
        if r.rows.is_empty() {
            errors.push(ConfigError::global(format!(
                "the containment record for harness '{harness}' has no rows — nothing has \
                 been probed, so no level can be granted."
            )));
            return errors;
        }
        // A record embedded under one harness that declares itself another is a build-time
        // mix-up whose whole effect would be to vouch for the wrong harness. Refuse rather
        // than trust either half of the disagreement.
        if r.harness != *harness {
            errors.push(ConfigError::global(format!(
                "the containment record embedded for harness '{harness}' declares itself \
                 '{}'. One of the two is wrong and neither can be trusted to say which.",
                r.harness
            )));
            return errors;
        }
        parsed.push((harness, r));
    }

    for m in &cfg.model_registry.models {
        // 2. A harness this build cannot construct. Asked of the REGISTRY rather than of
        //    `KNOWN_HARNESS_IDS`, because the registry is what would actually have to serve
        //    the model — the two agree by construction (`for_models` builds exactly the known
        //    ids) and asking the thing that does the work leaves one source of truth.
        let Some(harness) = cfg.harnesses.get(&m.harness) else {
            errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "unknown harness '{}' (registered: {}). A harness id that names nothing \
                     is refused rather than falling back to '{CLAUDE_CODE_ID}' — running a \
                     model under a harness its author did not choose is worse than not \
                     starting.",
                    m.harness,
                    cfg.harnesses.ids().join(", ")
                ),
            ));
            continue; // the level checks below would be meaningless against no harness
        };

        // 2b. A model whose BACKEND SURFACE the harness does not speak. `kind = "openai"`
        //     means the base_url answers `/v1/responses`, and a harness that speaks
        //     Anthropic's `/v1/messages` would hand its child that URL as
        //     `ANTHROPIC_BASE_URL` — producing a model the picker shows as healthy (its
        //     probe hits the OpenAI path and passes) whose every turn 404s. Refused here
        //     rather than left to fail per turn, and asked of the HARNESS rather than
        //     hardcoding an id, for the same reason item 3 asks `expresses`.
        if matches!(m.kind, ModelKind::OpenAi) && !harness.speaks_openai_backend() {
            errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "kind 'openai' names a backend on the OpenAI Responses surface, which \
                     harness '{}' does not speak — it drives its child over Anthropic's \
                     /v1/messages. Run this model under a harness that speaks the OpenAI \
                     surface (registered: {}), or declare it 'hosted'/'local' and point \
                     base_url at an Anthropic-surface endpoint.",
                    m.harness,
                    cfg.harnesses
                        .ordered()
                        .iter()
                        .filter(|h| h.speaks_openai_backend())
                        .map(|h| h.id())
                        .collect::<Vec<_>>()
                        .join(", "),
                ),
            ));
            continue;
        }

        // 3. A level the harness CANNOT EXPRESS. Checked before the record, and worded
        //    differently on purpose: this is not a gate the harness failed, it is a posture
        //    the harness does not have, so there is nothing to go fix and no battery to
        //    re-run. See [`Harness::expresses`].
        if !harness.expresses(m.level) {
            errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "harness '{}' cannot express level '{}' — it is not a posture this harness \
                     has, as distinct from one it failed a battery for. Nothing can be \
                     re-recorded to make it available; configure this model at a level the \
                     harness expresses, or run it under a different harness.",
                    m.harness,
                    capability_label(m.level),
                ),
            ));
            continue;
        }

        // 4. A level the model's harness has no passing battery row for, in its OWN record.
        let record = parsed
            .iter()
            .find(|(id, _)| *id == m.harness)
            .map(|(_, r)| r);
        match record.and_then(|r| highest_passing_level(r, harness)) {
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
            None if record.is_none() => errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "harness '{}' has NO containment record embedded in this build. Nothing \
                     was ever probed for it, so no level can be granted — record a battery \
                     for it and embed the file in `CONTAINMENT_RECORDS`.",
                    m.harness
                ),
            )),
            None => errors.push(ConfigError::for_model(
                &m.id,
                format!(
                    "harness '{}' has no passing containment battery row at any level in its \
                     committed record. A (harness, level) pair with no passing row is not a \
                     combination this project ships.",
                    m.harness
                ),
            )),
        }
    }

    // 5. A removed role-backend env var still set in the environment.
    for var in REMOVED_ROLE_ENV_VARS {
        if env(var).map(|v| !v.trim().is_empty()).unwrap_or(false) {
            errors.push(ConfigError::global(format!(
                "{var} is set, but the per-role backends were removed. One ordered \
                 `offload_order` list in the config file replaces all of them; a job now \
                 states the capability it requires and the walk picks the first configured, \
                 healthy model at or above it. Unset {var}."
            )));
        }
    }

    // 6. The posture each record speaks for versus the posture this deployment would run —
    //    every record against ITS OWN harness. A record whose harness this build cannot
    //    construct is skipped rather than compared against a stand-in: nothing can spawn that
    //    posture, so there is no deployment drift to detect, and comparing it against some
    //    other harness's flags would report a mismatch that means nothing.
    for (harness, record) in &parsed {
        if let Some(h) = cfg.harnesses.get(harness) {
            errors.extend(validate_toolset_argv(cfg, h, record));
        }
    }

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
/// **Each record is compared against ITS OWN harness's flags.** The argv is a statement in a
/// harness's private flag vocabulary — `--tools` / `--allowedTools` for Claude Code, `-c
/// sandbox_mode=…` for Codex — so a single global function would have reported every row of
/// the second record as drift, which is why [`Harness::capability_args`] is on the trait.
///
/// **No normalization layer, deliberately, and that survived an absolute scope entering the
/// record.** Codex's `Write` posture scopes writes to the turn's own working directory, which
/// is a different path on every machine and in every probe run. It is named by
/// [`WORKSPACE_TOKEN`] rather than substituted here: the harness emits the token, the record
/// commits the token, and the real directory is filled in only where a child is actually
/// spawned. So what the comparison means now is precisely what it meant before —
/// **strict equality over an argv whose host-varying scopes are named by token** — and an
/// untokenised absolute path is still a loud boot failure on every other machine.
///
/// # COUPLED WITH `the_record_carries_no_absolute_host_paths` — DO NOT RELAX ONE ALONE
///
/// Strict equality here is only viable BECAUSE that test forbids a host path in the record;
/// that test is only worth having BECAUSE the comparison here is strict. Relaxing either one
/// on its own produces a silent failure mode:
///   * add normalization here, keep the test → the normalization is dead code that hides the
///     next real drift;
///   * drop the test, keep strict equality → the first absolute path committed to the record
///     breaks every deployment except the one that recorded it, at BOOT, on someone else's
///     machine.
///
/// That test now runs over EVERY embedded record and carries the converse half too: a row
/// whose argv scopes a workspace must use the token. Both halves, or neither.
pub fn validate_toolset_argv(
    cfg: &Config,
    harness: &dyn Harness,
    record: &BatteryResults,
) -> Vec<ConfigError> {
    let mut errors = Vec::new();
    for row in &record.rows {
        let Some(cap) = parse_capability(&row.capability) else {
            errors.push(ConfigError::global(format!(
                "the containment record has a row with unknown capability '{}'",
                row.capability
            )));
            continue;
        };
        let running = harness.capability_args(cfg, cap);
        if running != row.toolset_args {
            errors.push(ConfigError::global(format!(
                "the toolset this deployment would run at '{}' on harness '{}' is not the one \
                 the containment record was taken with, so the record cannot speak for it.\n  \
                 recorded: {:?}\n  running: {:?}\n\
                 \nThe tool allowlist is NOT a config setting — it is a certified posture. \
                 JESSE_ALLOWED_TOOLS / JESSE_DISALLOWED_TOOLS can only ever RE-STATE what the \
                 battery already recorded; they cannot grant a tool. Setting them to anything \
                 else fails here, at boot, exactly as it just did.\n\
                 \nTo actually grant or remove a tool: edit DEFAULT_ALLOWED_TOOLS / \
                 DEFAULT_DISALLOWED_TOOLS in bridge/src/config.rs (and, for a new MCP server, \
                 MAIN_CHILD_MCP_CONFIG plus an McpSet variant so a row loads it), re-run \
                 `cargo run --bin containment-probe -- --write`, commit the updated \
                 bridge/containment.toml, rebuild, and restart. Budget ~30 minutes and a live \
                 API spend for the battery; it is not a config edit.\n\
                 \nTo get booting again right now: unset both variables and restart.",
                row.label(),
                harness.id(),
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
/// Permission entries found in the vault's PROJECT settings — grants the containment record
/// and the startup gate cannot see.
///
/// The child runs with `--setting-sources user,project`, so `.claude/settings.local.json` is
/// out of reach entirely. `project` is deliberately still loaded, because the vault's
/// `settings.json` carries the diet-regeneration and draft-guard hooks. That leaves exactly
/// one uncovered path: someone adds a `permissions.allow` entry to THAT file. This finds it.
///
/// Advisory, like [`detect_binary_drift`]: it warns and serves. A vault file is not a
/// deployment invariant, and refusing to boot because someone appended a `Bash(jq:*)` for
/// desktop work would make the bridge hostage to an editor. But it must never be SILENT —
/// silence is how `Bash(duckdb:*)` and `Bash(brew install duckdb)` reached every phone turn
/// unnoticed until 2026-08-05.
pub fn settings_permission_drift(cfg: &Config) -> Vec<String> {
    let path = std::path::Path::new(&cfg.vault)
        .join(".claude")
        .join("settings.json");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Vec::new();
    };
    // Every list is reported, not just `allow`: an `ask` entry a headless child cannot answer
    // is a denial, but a `deny` or a `defaultMode` here is still posture the record never saw.
    let mut found = Vec::new();
    for key in ["allow", "ask", "deny"] {
        if let Some(items) = v
            .get("permissions")
            .and_then(|p| p.get(key))
            .and_then(|a| a.as_array())
        {
            for item in items.iter().filter_map(|i| i.as_str()) {
                found.push(format!("{key}: {item}"));
            }
        }
    }
    found
}

/// The project-settings grants found at startup, for `/health` to report.
pub static SETTINGS_DRIFT: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();

/// One harness whose LIVE agent binary is not the one its containment record was taken with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinaryDrift {
    pub harness: String,
    /// `binary_version` from the committed record.
    pub recorded: String,
    /// What `<bin> --version` says right now.
    pub live: String,
}

/// The drift detected at startup, for `/health` to report without re-spawning a process.
pub static BINARY_DRIFT: std::sync::OnceLock<Vec<BinaryDrift>> = std::sync::OnceLock::new();

/// The child MCP servers whose command did not resolve on the child's `PATH` at startup, for
/// `/health` to report — and, through `/health`, for a deploy to roll back on. See
/// `crate::detect_unresolved_mcp_servers`.
pub static UNRESOLVED_MCP: std::sync::OnceLock<Vec<UnresolvedMcpServer>> =
    std::sync::OnceLock::new();

/// Compare each in-use harness's live agent binary against the version its record was taken
/// with. **Advisory: this WARNS, it never blocks startup.**
///
/// # Why this exists, and why it is not fatal
///
/// The record names `binary_version`, and until 0.58.0 nothing in the serving path read it —
/// only `containment-probe` compared it, i.e. only when you were already re-running the
/// battery. So a routine agent-CLI upgrade silently invalidated what the record described:
/// the gate kept passing, the file kept asserting a posture measured against a binary no
/// longer installed, and nothing anywhere said so. That is the failure mode with teeth here,
/// because the founding lesson of this whole system is that a CLI version CHANGED what an
/// empty `--allowedTools` meant.
///
/// It warns rather than refuses because the agent CLI can update itself. A hard block would
/// turn someone else's release into an outage on a morning nobody chose — strictly worse than
/// a stale record that is loudly announced. Staleness should be noisy, not fatal.
pub fn detect_binary_drift(cfg: &Config, records: &[(&str, &str)]) -> Vec<BinaryDrift> {
    let mut out = Vec::new();
    for id in harnesses_in_use(cfg) {
        let Some(record) = records
            .iter()
            .find(|(rid, _)| *rid == id)
            .and_then(|(_, text)| parse_results(text).ok())
        else {
            continue;
        };
        let Some(bin) = harness_bin_env(&id)
            .and_then(env_string)
            .or_else(|| harness_default_bin(&id).map(str::to_string))
        else {
            continue;
        };
        let live = std::process::Command::new(&bin)
            .arg("--version")
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        // An unreadable version is NOT reported as drift: "we could not check" would then be
        // indistinguishable from "it moved", and the startup binary check already reports a
        // missing binary in its own words.
        let Some(live) = live else { continue };
        if live != record.binary_version {
            out.push(BinaryDrift {
                harness: id,
                recorded: record.binary_version,
                live,
            });
        }
    }
    out
}

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

    /// The gate, held against a KNOWN-EMPTY environment. Every test here goes through this
    /// rather than [`validate_model_config`], and that is the structural half of the fix for
    /// the flake described on [`validate_model_config_with_env`]: step 5 of the gate reads the
    /// environment, so a test asserting `errors.is_empty()` against the real process env is
    /// asserting something about the machine it runs on. That made it fail for a sibling
    /// test's exported var, and it would equally fail for a developer with a leftover
    /// `JESSE_DIET_MODEL` in their shell — a dozen level assertions breaking with a message
    /// about an env var none of them mentions. Reading through a fixed empty env means no
    /// future env mutation anywhere in the process can reach these assertions.
    ///
    /// The one test that is ABOUT step 5 supplies its own env. What that leaves uncovered is
    /// `validate_model_config`'s one-line real-env closure, which is the point: it is the only
    /// part that cannot be tested without depending on the environment.
    fn validate(
        cfg: &Config,
        declared: &[ModelToml],
        records: &[(&str, &str)],
    ) -> Vec<ConfigError> {
        validate_model_config_with_env(cfg, declared, records, &|_| None)
    }

    fn record() -> BatteryResults {
        parse_results(claude_record()).expect("the committed record must parse")
    }

    fn claude_record() -> &'static str {
        containment_record(CLAUDE_CODE_ID).expect("claude-code has an embedded record")
    }

    /// Just Claude Code's record, as the embedded set is shaped. Enough for every test that
    /// says nothing about a second harness, and it keeps a doctored record from being held
    /// against a harness it was not doctored for.
    fn claude_only(text: &str) -> Vec<(&str, &str)> {
        vec![(CLAUDE_CODE_ID, text)]
    }

    /// As [`cfg_with_model`], but with a harness registry that can actually CONSTRUCT Codex.
    ///
    /// Codex is not in the shipped registry yet, and the checks it is subject to are exactly
    /// the ones that must be right BEFORE it is — so the tests build the registry the
    /// registration will produce rather than waiting for it. This is the same thing the
    /// battery does for the same reason.
    fn cfg_with_codex_model(id: &str, level: Capability) -> Config {
        let mut cfg = cfg_with_model(id, CODEX_ID, level);
        cfg.harnesses = Arc::new(HarnessRegistry::new(vec![Box::new(Codex)]));
        cfg
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
            highest_passing_level(&record(), &ClaudeCode),
            Some(Capability::Write)
        );
        assert_eq!(highest_passing_level(&record(), &Codex), None);
    }

    #[test]
    fn a_clean_config_starts() {
        let cfg = test_config();
        let errors = validate(&cfg, &[], &claude_only(claude_record()));
        assert!(errors.is_empty(), "{errors:?}");
    }

    #[test]
    fn a_leftover_default_writes_is_refused_and_names_level() {
        let decl = vec![ModelToml {
            id: Some("glm-5.2".to_string()),
            default_writes: Some(true),
            ..ModelToml::default()
        }];
        let errors = validate(&test_config(), &decl, &claude_only(claude_record()));
        let e = errors
            .first()
            .expect("a leftover default_writes must be refused");
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
        let errors = validate(&test_config(), &decl, &claude_only(claude_record()));
        assert!(
            errors
                .iter()
                .any(|e| e.message.contains("unknown level 'wrote'")),
            "{errors:?}"
        );
    }

    #[test]
    fn an_unregistered_harness_is_refused_and_names_the_model() {
        let cfg = cfg_with_model("codex-mini", "codex", Capability::Read);
        let errors = validate(&cfg, &[], &claude_only(claude_record()));
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
            highest_passing_level(&parse_results(&text).unwrap(), &ClaudeCode),
            Some(Capability::Read)
        );
        let cfg = cfg_with_model("bold", CLAUDE_CODE_ID, Capability::Write);
        let errors = validate(&cfg, &[], &claude_only(&text));
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
            highest_passing_level(&parsed, &ClaudeCode),
            Some(Capability::Basic),
            "one failing MCP set at `read` disqualifies the level"
        );
    }

    #[test]
    fn a_known_open_baseline_never_blocks_a_level() {
        // The Write row records an open network route and a process that outlives the turn.
        // Passing keys on the hard gates alone, or Write would be ungrantable forever.
        let r = record();
        // Derived from the harness rather than hardcoded: the claude-code write row is
        // `write/qmd+slack` since 0.57.0, and a literal label here would silently need
        // editing on every MCP-set change instead of following the harness that owns it.
        let write_label = ClaudeCode
            .shipped_rows()
            .iter()
            .find(|row| row.capability == Capability::Write)
            .expect("claude-code ships a write row")
            .mcp
            .label();
        let write_row = r.row("write", write_label).expect("the write row");
        assert!(
            write_row.probes.iter().any(|p| p.status == "known_open"),
            "precondition: the Write row has known-open baselines"
        );
        assert_eq!(
            highest_passing_level(&r, &ClaudeCode),
            Some(Capability::Write)
        );
    }

    #[test]
    fn a_record_that_does_not_parse_fails_closed() {
        let errors = validate(&test_config(), &[], &claude_only("this is not toml {{{"));
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(errors[0].message.contains("does not parse"), "{errors:?}");
        // …and a foreign schema is the same failure, not a permissive read.
        // Keyed off the constant, not a literal: this forgery silently became a no-op the
        // last time the schema was bumped, and the test passed anyway.
        let bumped = claude_record().replace(
            &format!("schema = {}", crate::containment::RESULTS_SCHEMA),
            "schema = 99",
        );
        assert!(
            bumped.contains("schema = 99"),
            "the forgery must have landed"
        );
        let errors = validate(&test_config(), &[], &claude_only(&bumped));
        assert!(!errors.is_empty());
    }

    #[test]
    fn a_widened_allowlist_is_refused_with_the_difference() {
        // The assertion that catches a drifting DEPLOYMENT rather than a drifting posture:
        // an env var widened the allowlist, so the record cannot speak for what would run.
        let mut cfg = test_config();
        cfg.allowed_tools = format!("{DEFAULT_ALLOWED_TOOLS},Bash");
        let errors = validate_toolset_argv(&cfg, &ClaudeCode, &record());
        let e = errors.first().expect("a widened allowlist must be refused");
        assert!(e.message.contains("recorded:"), "{e}");
        assert!(e.message.contains("running:"), "{e}");
        assert!(e.message.contains("JESSE_ALLOWED_TOOLS"), "{e}");
    }

    #[test]
    fn the_shipped_posture_matches_the_record_exactly() {
        // Strict equality, no normalization: the shipped defaults ARE what was probed. Every
        // embedded record against its own harness, because a comparison that only ever ran
        // against Claude Code's flags is the bug this became a set to fix.
        for (id, text) in CONTAINMENT_RECORDS {
            let r = parse_results(text).expect("parses");
            let h: Box<dyn Harness> = match *id {
                CODEX_ID => Box::new(Codex),
                _ => Box::new(ClaudeCode),
            };
            let errors = validate_toolset_argv(&test_config(), h.as_ref(), &r);
            assert!(errors.is_empty(), "{id}: {errors:?}");
        }
    }

    /// EVERY EMBEDDED RECORD AGREES WITH WHAT ITS HARNESS DECLARES. This is what stops
    /// [`Harness::expresses`] becoming a wish list of its own.
    ///
    /// Both directions, because each catches a different lie:
    ///   * a harness that CLAIMS a level must have a passing row for it — otherwise the
    ///     startup gate would let a model through on a declaration nothing probed;
    ///   * a harness that DISCLAIMS one must have no passing row for it — otherwise the
    ///     declaration is hiding a posture that demonstrably works, and the walk in
    ///     [`highest_passing_level`] is silently skipping a rung that exists.
    ///
    /// A declaration the record contradicts is a BUILD failure, in either direction.
    #[test]
    fn the_containment_records_agree_with_what_each_harness_declares() {
        for (id, text) in CONTAINMENT_RECORDS {
            let r = parse_results(text).expect("parses");
            let h: Box<dyn Harness> = match *id {
                CODEX_ID => Box::new(Codex),
                _ => Box::new(ClaudeCode),
            };
            for cap in [Capability::Basic, Capability::Read, Capability::Write] {
                let label = capability_label(cap);
                let rows: Vec<&RowResult> = r
                    .rows
                    .iter()
                    .filter(|row| row.capability == label)
                    .collect();
                let passing = !rows.is_empty()
                    && rows.iter().all(|row| {
                        row.probes
                            .iter()
                            .filter(|p| p.class == ProbeClass::HardGate.label())
                            .all(|p| p.status == "pass")
                    });
                assert_eq!(
                    h.expresses(cap),
                    passing,
                    "{id}: declares expresses({label}) = {} but its record's rows at that \
                     level {} pass. A declaration and its proof must agree in BOTH \
                     directions — fix whichever one is wrong, and never the test.",
                    h.expresses(cap),
                    if passing { "all" } else { "do not all" },
                );
            }
        }
    }

    /// Codex's ladder has no bottom rung, and the walk reads that from the declaration rather
    /// than from the failing `basic` row.
    #[test]
    fn a_harness_that_does_not_express_basic_is_still_granted_the_levels_it_passes() {
        let r = parse_results(containment_record(CODEX_ID).expect("embedded")).unwrap();
        assert!(
            r.row("basic", "none").expect("a basic row").status == "failing",
            "precondition: the record records what happens if `basic` is asked for anyway"
        );
        assert_eq!(
            highest_passing_level(&r, &Codex),
            Some(Capability::Write),
            "a failing row for a level the harness does not HAVE must not break the prefix"
        );
    }

    /// A model configured at a level its harness cannot express is refused, and the message
    /// says so — not "failed a gate", which would send an operator looking for a flag.
    #[test]
    fn a_level_the_harness_cannot_express_is_refused_in_those_words() {
        let cfg = cfg_with_codex_model("codex-mini", Capability::Basic);
        let errors = validate(&cfg, &[], CONTAINMENT_RECORDS);
        let e = errors
            .iter()
            .find(|e| e.model.as_deref() == Some("codex-mini"))
            .expect("basic on codex must be refused");
        assert!(e.message.contains("cannot express"), "{e}");
        assert!(!e.message.contains("passing containment battery"), "{e}");
        // …and the level it DOES express starts cleanly.
        let cfg = cfg_with_codex_model("codex-mini", Capability::Read);
        let errors = validate(&cfg, &[], CONTAINMENT_RECORDS);
        assert!(errors.is_empty(), "{errors:?}");
    }

    /// A MODEL ON A SURFACE ITS HARNESS DOES NOT SPEAK IS REFUSED AT STARTUP.
    ///
    /// The failure this prevents is the nastiest shape a model config has: `kind = "openai"`
    /// on the Claude Code harness passes its HEALTH PROBE (the probe posts at the OpenAI path
    /// and gets a 200), so the picker shows the model green — and then every turn 404s,
    /// because the child was handed an `ANTHROPIC_BASE_URL` that serves `/v1/responses` and
    /// nothing else. Green in the switcher, dead on arrival, with nothing tying the two
    /// together.
    #[test]
    fn an_openai_kind_model_is_refused_on_a_harness_that_speaks_anthropic() {
        let mut cfg = cfg_with_model("kimi-k3-codex", CLAUDE_CODE_ID, Capability::Read);
        cfg.harnesses = Arc::new(HarnessRegistry::new(vec![Box::new(Codex)]));
        if let Some(m) = cfg
            .model_registry
            .models
            .iter_mut()
            .find(|m| m.id == "kimi-k3-codex")
        {
            m.kind = ModelKind::OpenAi;
        }
        let errors = validate(&cfg, &[], CONTAINMENT_RECORDS);
        let e = errors
            .iter()
            .find(|e| e.model.as_deref() == Some("kimi-k3-codex"))
            .expect("an openai-kind model on claude-code must be refused");
        assert!(e.message.contains("does not speak"), "{e}");
        assert!(
            e.message.contains(CODEX_ID),
            "the message must name a harness that WOULD serve it: {e}"
        );

        // The same model on the harness that speaks the surface starts cleanly — the gate
        // refuses a pairing, not a kind.
        let mut ok = cfg_with_codex_model("kimi-k3-codex", Capability::Read);
        if let Some(m) = ok
            .model_registry
            .models
            .iter_mut()
            .find(|m| m.id == "kimi-k3-codex")
        {
            m.kind = ModelKind::OpenAi;
        }
        assert!(
            validate(&ok, &[], CONTAINMENT_RECORDS).is_empty(),
            "openai-kind on codex is exactly the pairing this change adds"
        );
    }

    /// A harness with no embedded record is a different fault from one whose record has no
    /// passing row, and the message must not blame "the record's harness" as though there
    /// were one record.
    #[test]
    fn a_harness_with_no_embedded_record_says_exactly_that() {
        let cfg = cfg_with_codex_model("codex-mini", Capability::Read);
        let claude_only = &CONTAINMENT_RECORDS[..1];
        let errors = validate(&cfg, &[], claude_only);
        let e = errors
            .iter()
            .find(|e| e.model.as_deref() == Some("codex-mini"))
            .expect("a harness with no record must be refused");
        assert!(e.message.contains("NO containment record"), "{e}");
    }

    /// A record embedded under one harness that declares itself another vouches for the wrong
    /// thing, so neither half is trusted.
    #[test]
    fn a_record_embedded_under_the_wrong_harness_is_refused() {
        let mismatched = &[(CODEX_ID, claude_record())][..];
        let errors = validate(&test_config(), &[], mismatched);
        assert!(
            errors.iter().any(|e| e.message.contains("declares itself")),
            "{errors:?}"
        );
    }

    /// The record commits the exact argv it probed, and [`validate_toolset_argv`] compares it
    /// by STRICT EQUALITY with no normalization layer. That only works while the argv is
    /// host-independent. A `Read(//Users/someuser/vault/**)` would make every OTHER deployment
    /// fail at boot — so this catches it at commit time instead.
    ///
    /// Two halves now, because an absolute scope genuinely had to enter the record: Codex
    /// scopes its writes to the turn's own working directory, which is a different path on
    /// every machine AND in every probe run. The forbid half keeps a real path out; the
    /// require half keeps the token in. A workspace-scoped row with NEITHER would pass a
    /// forbid-only test simply by being written some third way, and the comparison would go
    /// back to failing on someone else's machine.
    ///
    /// `/var/folders/`, `/tmp/` and `/private/` are named alongside the home directories
    /// because the probe scratch trees live there: the path this test first caught was
    /// `/var/folders/4n/…/write-qmd/vault`, a per-run temporary directory that could never
    /// equal a deployment's computed value even on the machine that recorded it.
    ///
    /// # COUPLED WITH `validate_toolset_argv` — DO NOT RELAX ONE ALONE
    ///
    /// These two are a pair: the strict comparison there is only viable because this test
    /// forbids a host path here, and this test is only worth having because that comparison
    /// is strict. See the "COUPLED WITH" block on [`validate_toolset_argv`] for what each
    /// half fails to catch on its own. Change both together or neither.
    #[test]
    fn the_record_carries_no_absolute_host_paths() {
        for (id, text) in CONTAINMENT_RECORDS {
            let r = parse_results(text).expect("parses");
            for row in &r.rows {
                for arg in &row.toolset_args {
                    for bad in [
                        "/Users/",
                        "/home/",
                        "/private/var/",
                        "/private/",
                        "/var/folders/",
                        "/tmp/",
                        "$HOME",
                    ] {
                        assert!(
                            !arg.contains(bad),
                            "{id} {}: recorded toolset argv contains an absolute host path \
                             ({bad}): {arg:?}. The startup assertion compares this by strict \
                             equality with no normalization, so a host path here fails every \
                             other deployment at boot. Keep the scopes cwd-relative, or name \
                             the workspace with {WORKSPACE_TOKEN}.",
                            row.label()
                        );
                    }
                    // The converse. A scope that varies by host must be NAMED, not omitted:
                    // the token is what lets the comparison stay strict.
                    if arg.contains("writable_roots") {
                        assert!(
                            arg.contains(WORKSPACE_TOKEN),
                            "{id} {}: {arg:?} scopes a writable root without naming it \
                             {WORKSPACE_TOKEN}. A workspace scope is host-varying by \
                             definition; if this row really does scope something fixed, say \
                             so here rather than leaving the two halves disagreeing.",
                            row.label()
                        );
                    }
                }
            }
        }
    }

    /// Through the `_with_env` seam, NOT by calling `std::env::set_var`: this module's other
    /// tests read the same environment through the same gate, and cargo runs them as threads
    /// in one process, so a real `set_var` here landed a global error in a sibling test's
    /// result and failed its `errors.is_empty()` assertion. See
    /// [`validate_model_config_with_env`]. A future test here must set env the same way.
    #[test]
    fn a_removed_role_env_var_still_set_is_refused_and_names_offload_order() {
        let var = "JESSE_VAULTQA_MODEL";
        let errors = validate_model_config_with_env(
            &test_config(),
            &[],
            &claude_only(claude_record()),
            &|v| (v == var).then(|| "local-oss".to_string()),
        );
        let e = errors
            .iter()
            .find(|e| e.message.contains(var))
            .expect("a removed role env var must be refused");
        assert!(e.message.contains("offload_order"), "{e}");
        assert!(e.model.is_none(), "it belongs to no single model");
    }

    /// A var that is set but EMPTY (or whitespace) is not a configured backend, so it must not
    /// refuse startup — the same distinction `from_env` draws everywhere else.
    #[test]
    fn a_removed_role_env_var_set_to_whitespace_is_not_refused() {
        let errors = validate_model_config_with_env(
            &test_config(),
            &[],
            &claude_only(claude_record()),
            &|_| Some("   ".to_string()),
        );
        assert!(errors.is_empty(), "{errors:?}");
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
