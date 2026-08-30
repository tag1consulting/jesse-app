//! **Persona** — the single personalization surface for the bridge. Every
//! personal fact (the owner's name, possessive pronoun, spoken languages, and any
//! extra diet-logging vocabulary) is runtime DATA loaded here, never a value
//! hardcoded into tracked source.
//!
//! Precedence, lowest to highest:
//!   1. the generic built-in [`Persona::default`] — owner "the user", pronoun
//!      "their", English only, no extra diet keywords;
//!   2. an optional, gitignored `jesse.local.toml` `[persona]` table (see
//!      [`local_config_path`] for the search order);
//!   3. environment variables (`JESSE_OWNER_NAME`, `JESSE_OWNER_PRONOUN`,
//!      `JESSE_LANGUAGES`, `JESSE_DIET_KEYWORDS_EXTRA`).
//!
//! A fresh clone with no local file and no env reads generically: the assistant
//! addresses "the user" and the diet gate ships an English-only baseline. The
//! original author's setup is reproduced by DATA alone (a `jesse.local.toml`),
//! never by editing this file — so `git push` can never leak it.

use crate::*;

/// The generic default owner label rendered into the prompt wrappers when nothing
/// is configured. A fresh clone addresses "the user".
pub const DEFAULT_OWNER_NAME: &str = "the user";
/// The generic default possessive pronoun. "{owner_pronoun} phone" reads as "their
/// phone"; set it to "his"/"her"/… in a local config to match the owner.
pub const DEFAULT_OWNER_PRONOUN: &str = "their";
/// The generic default language set (English only), stored for documentation/forward
/// use; the shipped diet gate baseline is English and everything else is opt-in data.
pub const DEFAULT_LANGUAGE: &str = "en";

/// The resolved persona for a running bridge. Cheap to clone (a handful of small
/// strings); carried on [`Config`] and read at prompt-build and diet-gate time.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Persona {
    /// How the assistant refers to the owner in the prompt wrappers. Default
    /// `"the user"`; a personalization sets it to a real name.
    pub owner_name: String,
    /// The owner's POSSESSIVE pronoun ("their"/"his"/"her"/…), rendered where the
    /// wrappers say "{owner_pronoun} phone" / "{owner_pronoun} permission".
    pub owner_pronoun: String,
    /// The languages the owner writes in (informational; e.g. `["en", "it"]`).
    /// Not injected into any prompt — declaring it does not change turn behavior —
    /// it documents the deployment and pairs with `diet_keywords_extra`.
    pub languages: Vec<String>,
    /// Extra diet-intent keywords merged into the English baseline gate at load
    /// (lowercased whole tokens). This is where a non-English or personal food
    /// vocabulary lives, so the tracked gate stays an English-only baseline.
    pub diet_keywords_extra: Vec<String>,
}

impl Default for Persona {
    fn default() -> Self {
        Persona {
            owner_name: DEFAULT_OWNER_NAME.to_string(),
            owner_pronoun: DEFAULT_OWNER_PRONOUN.to_string(),
            languages: vec![DEFAULT_LANGUAGE.to_string()],
            diet_keywords_extra: Vec::new(),
        }
    }
}

impl Persona {
    /// Substitute the persona placeholders in a template:
    ///   * `{Owner}` → the owner name with its first letter capitalized (sentence
    ///     starts — `"the user"` → `"The user"`, a real name is unchanged);
    ///   * `{owner}` → the owner name verbatim (mid-sentence);
    ///   * `{owner_pronoun}` → the possessive pronoun.
    ///
    /// A template with no placeholders is returned unchanged. This is the ONLY
    /// substitution machinery — the wrappers stay plain strings, not `format!` call
    /// sites — and it renders the app-authored prompt BODY as well as the bridge's own
    /// wrappers (see [`prompt::build_prompt_at`], the single call site).
    ///
    /// SINGLE PASS, and that is a correctness property rather than a performance one.
    /// This used to be three chained `str::replace` calls, which rescan the output of
    /// the previous call: an owner name of `"{owner_pronoun}"` was substituted for
    /// `{Owner}` and then the third pass expanded the result again, so a value could
    /// reach the agent as a DIFFERENT persona field. The scanner below copies each
    /// substituted value straight to the output and resumes AFTER it, so a rendered
    /// value is never itself scanned — whatever a name contains, braces included, is
    /// what the agent reads. An unmatched `{` is literal and is copied through.
    pub fn render(&self, template: &str) -> String {
        // Longest first, so a shorter placeholder can never shadow a longer one that
        // starts with it. (None of the three does today; the ordering keeps that true
        // if a fourth is ever added.)
        let owner_capitalized = capitalize_first(&self.owner_name);
        let placeholders: [(&str, &str); 3] = [
            ("{owner_pronoun}", self.owner_pronoun.as_str()),
            ("{Owner}", owner_capitalized.as_str()),
            ("{owner}", self.owner_name.as_str()),
        ];
        let mut out = String::with_capacity(template.len());
        let mut rest = template;
        while let Some(open) = rest.find('{') {
            out.push_str(&rest[..open]);
            rest = &rest[open..];
            match placeholders.iter().find(|(name, _)| rest.starts_with(name)) {
                Some((name, value)) => {
                    out.push_str(value);
                    rest = &rest[name.len()..];
                }
                // Not a placeholder: emit the brace and carry on from the next byte, so
                // a literal `{` in prose (or in an item's markdown) survives untouched.
                None => {
                    out.push('{');
                    rest = &rest[1..];
                }
            }
        }
        out.push_str(rest);
        out
    }

    /// Load the persona: generic defaults → `jesse.local.toml` `[persona]` → env.
    /// `home` is the captured `Config.home` (used to resolve the state-dir config
    /// location). Never fails: a missing file is the default, a malformed file logs
    /// one warning and falls back to the default.
    pub fn load(home: &str) -> Self {
        let mut p = Persona::default();
        if let Some(t) = load_local_persona(home) {
            if let Some(v) = trimmed_nonempty(t.owner_name) {
                p.owner_name = v;
            }
            if let Some(v) = trimmed_nonempty(t.owner_pronoun) {
                p.owner_pronoun = v;
            }
            if let Some(langs) = t.languages {
                let langs = clean_list(langs);
                if !langs.is_empty() {
                    p.languages = langs;
                }
            }
            if let Some(kws) = t.diet_keywords_extra {
                p.diet_keywords_extra = clean_keywords(kws);
            }
        }
        // Env overrides (highest precedence). Same trim/empty-filter semantics as
        // every other string field via `env_string`.
        if let Some(v) = env_string("JESSE_OWNER_NAME") {
            p.owner_name = v;
        }
        if let Some(v) = env_string("JESSE_OWNER_PRONOUN") {
            p.owner_pronoun = v;
        }
        if let Some(v) = env_string("JESSE_LANGUAGES") {
            let langs = clean_list(split_csv(&v));
            if !langs.is_empty() {
                p.languages = langs;
            }
        }
        if let Some(v) = env_string("JESSE_DIET_KEYWORDS_EXTRA") {
            p.diet_keywords_extra = clean_keywords(split_csv(&v));
        }
        p
    }
}

/// Uppercase the first character of `s` (leaving the rest untouched), so a
/// lowercase generic label reads correctly at a sentence start. A real name is
/// already capitalized, so this is a no-op on it.
fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// `Some(trimmed)` when the value is present and non-blank, else `None` — so a
/// blank TOML value counts as unset (matching `env_string`'s convention).
fn trimmed_nonempty(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// Split a comma-separated env value into parts (trim/empty handled by the caller).
fn split_csv(s: &str) -> Vec<String> {
    s.split(',').map(|p| p.to_string()).collect()
}

/// Trim, drop blanks. Order-preserving.
fn clean_list(items: Vec<String>) -> Vec<String> {
    items
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Trim, lowercase, drop blanks, dedupe — the shape the diet gate matches on
/// (whole lowercased tokens). Order-preserving on first occurrence.
fn clean_keywords(items: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    items
        .into_iter()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty() && seen.insert(s.clone()))
        .collect()
}

/// The `[persona]` table as it appears in `jesse.local.toml`. Every field is
/// optional so a partial file overlays only the keys it sets.
#[derive(Deserialize, Default)]
struct PersonaToml {
    owner_name: Option<String>,
    owner_pronoun: Option<String>,
    languages: Option<Vec<String>>,
    diet_keywords_extra: Option<Vec<String>>,
}

/// The whole local overlay file. `[persona]` supplies the personalization; the declarative
/// `[[models]]` array supplies the global model switch's registry (source 3 — see
/// [`ModelRegistry::from_env`]). Unknown keys are ignored so the example file can document
/// forward-looking sections.
#[derive(Deserialize, Default)]
struct LocalConfig {
    persona: Option<PersonaToml>,
    #[serde(default)]
    models: Vec<ModelToml>,
    /// The ordered candidate list for routed jobs (`offload_order = ["local", "glm-5.2"]`).
    /// Absent → empty → every routed job goes to ambient, as before the key existed.
    #[serde(default)]
    offload_order: Vec<String>,
    /// Per-model concurrency slots plus the global ceiling (`[concurrency]`).
    ///
    /// A TABLE KEYED BY MODEL ID rather than a `concurrency` key on each `[[models]]` entry,
    /// and the reason is coverage: five of the seven models in the deployed registry — the
    /// built-in ambient `opus` and the four env-triple models — have no `[[models]]` entry to
    /// hang a key on. A per-entry key would be unreachable for most of the registry and would
    /// need a second mechanism for `opus` anyway.
    ///
    /// Values stay untyped here so a bad one can be reported precisely, naming the model,
    /// instead of failing the whole overlay file (which would silently take the persona and
    /// the model registry down with it).
    #[serde(default)]
    concurrency: HashMap<String, toml::Value>,
    /// The built-in scheduler's `[[schedule]]` entries (see [`crate::schedule`]).
    ///
    /// Kept RAW here — every field optional, unknown keys captured — so a mistyped entry
    /// reaches the validator, which disables that one entry by name, instead of failing
    /// the parse of this whole file and silently taking the persona and the model
    /// registry down with it.
    #[serde(default)]
    schedule: Vec<ScheduleToml>,
    /// The optional top-level `[direct]` table: the vault settings every `direct` turn runs
    /// under. A table rather than per-model keys because it describes the VAULT, not a model
    /// — every direct model on this deployment reads the same documents with the same
    /// exclusions and the same cold list, and per-model copies would be a way for two models
    /// to disagree about which documents exist.
    #[serde(default)]
    direct: Option<DirectToml>,
    /// The optional top-level `[profile]` table — today just `on_return`. A table rather
    /// than a key on an entry because it is a statement about the schedule as a whole; see
    /// [`crate::schedule::ProfileToml`].
    #[serde(default)]
    profile: Option<ProfileToml>,
}

/// Resolve the local overlay file, first existing wins:
///   1. `$JESSE_CONFIG` (an explicit file path — full operator control);
///   2. `./jesse.local.toml` (repo root / cwd — a fresh clone, `cargo run`);
///   3. `<state-dir>/jesse.local.toml` — `$JESSE_STATE_DIR` if set, else
///      `$HOME/.jesse-bridge` — the reliable spot for a launchd-managed service
///      whose cwd is not the repo.
///
/// Returns `None` when no candidate exists (the generic-default path).
pub fn local_config_path(home: &str) -> Option<PathBuf> {
    if let Some(explicit) = env_string("JESSE_CONFIG") {
        let p = PathBuf::from(explicit);
        if p.is_file() {
            return Some(p);
        }
    }
    let cwd = PathBuf::from("jesse.local.toml");
    if cwd.is_file() {
        return Some(cwd);
    }
    let state_dir = env_string("JESSE_STATE_DIR")
        .or_else(|| (!home.is_empty()).then(|| format!("{home}/.jesse-bridge")));
    if let Some(dir) = state_dir {
        let p = PathBuf::from(dir).join("jesse.local.toml");
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// Read + parse the `[persona]` table from the resolved overlay file. Soft-fails:
/// a read or parse error logs one stderr warning and yields `None` (defaults),
/// never aborting startup.
fn load_local_persona(home: &str) -> Option<PersonaToml> {
    load_local_config(home).and_then(|c| c.persona)
}

/// Read + parse the declarative `[[models]]` array from the SAME overlay file the persona
/// loads from (same search order, same soft-fail: a missing/malformed file yields an empty
/// list and the registry falls back to the env triples + built-in opus). Each entry is
/// validated in [`registry_model_from_toml`], so a partial entry is skipped there, not here.
/// The `[direct]` table as written, every field optional.
#[derive(Deserialize, Debug, Default, Clone)]
pub struct DirectToml {
    pub exclude: Option<Vec<String>>,
    pub cold_prefixes: Option<Vec<String>>,
    pub fetch_allow: Option<Vec<String>>,
    pub qmd: Option<bool>,
    pub qmd_collection: Option<String>,
    pub max_iterations: Option<u32>,
    pub max_tool_calls: Option<u32>,
}

/// Read the `[direct]` table from the overlay file, defaulted.
///
/// An ABSENT table is the shipped default and it is deliberately conservative: no extra
/// exclusions beyond the agent crate's own `ALWAYS_EXCLUDED`, no cold prefixes, **no fetch
/// allowlist at all** (so `fetch_url` is present in the manifest at `Read` and refuses every
/// URL), and the built-in grep index. A deployment that configures nothing gets a direct
/// harness that can read and search its vault and reach nothing outside it.
pub fn load_direct_settings(home: &str) -> DirectSettings {
    let mut out = DirectSettings::default();
    let Some(t) = load_local_config(home).and_then(|c| c.direct) else {
        return out;
    };
    if let Some(v) = t.exclude {
        out.exclude = clean_list(v);
    }
    if let Some(v) = t.cold_prefixes {
        out.cold_prefixes = clean_list(v);
    }
    if let Some(v) = t.fetch_allow {
        out.fetch_allow = clean_list(v);
    }
    out.qmd = t.qmd.unwrap_or(false);
    out.qmd_collection = trimmed_nonempty(t.qmd_collection);
    // Zero is refused rather than honoured: a budget of zero iterations is a turn that cannot
    // answer, and an operator who typed it meant something else.
    out.max_iterations = t.max_iterations.filter(|n| *n > 0);
    out.max_tool_calls = t.max_tool_calls.filter(|n| *n > 0);
    out
}

pub fn load_local_models(home: &str) -> Vec<ModelToml> {
    load_local_config(home)
        .map(|c| c.models)
        .unwrap_or_default()
}

/// Read the `[concurrency]` table from the same overlay file.
///
/// `total` is lifted out; every other key is a model id. A value that is not a positive
/// integer is left for [`resolve_slot_plan`] to reject BY NAME — see the note on the field.
pub fn load_concurrency(home: &str) -> ConcurrencySettings {
    let mut out = ConcurrencySettings::default();
    let Some(cfg) = load_local_config(home) else {
        return out;
    };
    for (k, v) in cfg.concurrency {
        let n = v.as_integer().filter(|n| *n >= 0).map(|n| n as usize);
        if k == "total" {
            out.total = n;
            continue;
        }
        match n {
            Some(n) => {
                out.per_model.insert(k, n);
            }
            None => out.invalid.push(k),
        }
    }
    out
}

/// Read the `[[schedule]]` array from the same overlay file (same search order, same
/// soft-fail: a missing or malformed file yields an empty schedule and the bridge runs
/// with no scheduled jobs at all). Validation is [`validate_schedule`]'s job, not this
/// one's — a partial entry is reported there, by name.
pub fn load_schedule(home: &str) -> Vec<ScheduleToml> {
    load_local_config(home)
        .map(|c| c.schedule)
        .unwrap_or_default()
}

/// Read the optional top-level `[profile]` table from the same overlay file (same search
/// order, same soft-fail). Absent → `None` → no return chain, which is every deploy that
/// has not asked for one.
pub fn load_profile_table(home: &str) -> Option<ProfileToml> {
    load_local_config(home).and_then(|c| c.profile)
}

/// The overlay file the bridge actually loaded, or `None` when there is none.
///
/// Public so the scheduler can WATCH the same file the config was read from — the watch and
/// the load resolving the path independently is how they would come to disagree about which
/// file is authoritative, so there is one resolver and both go through it.
pub fn loaded_config_path(home: &str) -> Option<PathBuf> {
    local_config_path(home)
}

/// Read the `[[schedule]]` array AND the `[profile]` table from ONE NAMED FILE, reporting a
/// parse failure instead of swallowing it.
///
/// Both together, in one read, because a reload swaps both: `on_return` names a schedule
/// entry, so reading the two from separate parses of a file that may have changed between
/// them is how they would come to disagree about which entries exist.
///
/// The boot loader ([`load_schedule`]) soft-fails to an empty list on purpose: a malformed
/// overlay must not stop the service from starting. A RELOAD needs the opposite — an empty
/// list and an unparseable file look identical from the outside, and swapping "no jobs" in
/// for "I could not read your file" would silently retire the whole schedule on a typo.
pub fn load_schedule_from(path: &Path) -> Result<(Vec<ScheduleToml>, Option<ProfileToml>), String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("could not read {}: {e}", path.display()))?;
    toml::from_str::<LocalConfig>(&text)
        .map(|c| (c.schedule, c.profile))
        .map_err(|e| format!("could not parse {}: {e}", path.display()))
}

/// Read the `offload_order` list from the same overlay file, blank ids dropped. Absent or
/// malformed → empty, which routes every routed job to ambient.
pub fn load_offload_order(home: &str) -> Vec<String> {
    load_local_config(home)
        .map(|c| {
            c.offload_order
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Read + parse the whole local overlay file once. Soft-fails: a read or parse error logs
/// one stderr warning and yields `None` (the callers then use their defaults), never
/// aborting startup. Shared by the persona and the declarative-model loaders so the file is
/// found by the one search order and a malformed file degrades both consistently.
fn load_local_config(home: &str) -> Option<LocalConfig> {
    let path = local_config_path(home)?;
    match std::fs::read_to_string(&path) {
        Ok(s) => match toml::from_str::<LocalConfig>(&s) {
            Ok(cfg) => Some(cfg),
            Err(e) => {
                eprintln!(
                    "jesse-bridge: WARNING could not parse {} ({e}); using generic defaults.",
                    path.display()
                );
                None
            }
        },
        Err(e) => {
            eprintln!(
                "jesse-bridge: WARNING could not read {} ({e}); using generic defaults.",
                path.display()
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn default_is_generic() {
        let p = Persona::default();
        assert_eq!(p.owner_name, "the user");
        assert_eq!(p.owner_pronoun, "their");
        assert_eq!(p.languages, vec!["en".to_string()]);
        assert!(p.diet_keywords_extra.is_empty());
    }

    #[test]
    fn render_substitutes_all_placeholders() {
        let p = Persona {
            owner_name: "Alex".into(),
            owner_pronoun: "her".into(),
            languages: vec!["en".into(), "es".into()],
            diet_keywords_extra: vec![],
        };
        assert_eq!(
            p.render("{Owner} asks from {owner_pronoun} phone; {owner} waits."),
            "Alex asks from her phone; Alex waits."
        );
    }

    #[test]
    fn render_capitalizes_generic_owner_at_sentence_start() {
        // The default lowercase label reads correctly where a template leads with it.
        let p = Persona::default();
        assert_eq!(
            p.render("{Owner} is ASKING from {owner_pronoun} phone."),
            "The user is ASKING from their phone."
        );
        // A no-placeholder override (an app-supplied wrapper) is untouched.
        assert_eq!(
            p.render("Custom wrapper, no tokens."),
            "Custom wrapper, no tokens."
        );
    }

    /// A rendered VALUE is never scanned again. An owner whose configured name is
    /// itself a placeholder used to come out as a different persona field entirely:
    /// the chained-`replace` implementation substituted `{Owner}` → `{owner_pronoun}`
    /// and then the pronoun pass expanded that, so the agent was told the owner is
    /// called "her". One pass over the template fixes it by construction.
    #[test]
    fn render_never_re_expands_a_substituted_value() {
        let p = Persona {
            owner_name: "{owner_pronoun}".into(),
            owner_pronoun: "her".into(),
            languages: vec!["en".into()],
            diet_keywords_extra: vec![],
        };
        assert_eq!(p.render("{Owner} asks."), "{owner_pronoun} asks.");
        assert_eq!(p.render("{owner} asks."), "{owner_pronoun} asks.");
        // The genuine pronoun placeholder still renders — only the SUBSTITUTED text is
        // out of scope for further substitution.
        assert_eq!(
            p.render("{owner} on {owner_pronoun} phone"),
            "{owner_pronoun} on her phone"
        );

        // The other direction: a pronoun that spells the name placeholder.
        let q = Persona {
            owner_name: "Alex".into(),
            owner_pronoun: "{Owner}".into(),
            languages: vec!["en".into()],
            diet_keywords_extra: vec![],
        };
        assert_eq!(q.render("{owner_pronoun} phone"), "{Owner} phone");

        // And a name that would recurse forever under any rescanning scheme.
        let r = Persona {
            owner_name: "{owner}".into(),
            owner_pronoun: "their".into(),
            languages: vec!["en".into()],
            diet_keywords_extra: vec![],
        };
        assert_eq!(r.render("{owner} and {owner}"), "{owner} and {owner}");
    }

    /// Braces that are not one of the three placeholders are prose, not syntax — an
    /// item's markdown, a code snippet, a JSON blob the user pasted. They survive
    /// byte for byte, including a lone `{` at the very end of the text.
    #[test]
    fn render_passes_unknown_braces_through_unchanged() {
        let p = Persona {
            owner_name: "Alex".into(),
            owner_pronoun: "her".into(),
            languages: vec!["en".into()],
            diet_keywords_extra: vec![],
        };
        for template in [
            "{}",
            "{ owner }",
            "{OWNER}",
            "{owner_name}",
            "{{owner}}",
            "fn f() { g(); }",
            "trailing brace {",
            "{owner_pronounX}",
        ] {
            let expected = template
                .replace("{owner}", "Alex")
                .replace("{owner_pronoun}", "her");
            assert_eq!(p.render(template), expected, "template: {template:?}");
        }
        // `{{owner}}` is a literal brace around a real placeholder, not an escape.
        assert_eq!(p.render("{{owner}}"), "{Alex}");
    }

    #[test]
    fn clean_keywords_trims_lowercases_dedupes() {
        let got = clean_keywords(vec![
            "  Colazione ".into(),
            "PRANZO".into(),
            "colazione".into(), // dup after lowercasing
            "".into(),
        ]);
        assert_eq!(got, vec!["colazione".to_string(), "pranzo".to_string()]);
    }

    #[test]
    fn load_env_overrides_defaults() {
        let _g = ENV_LOCK.lock_ok();
        for k in [
            "JESSE_CONFIG",
            "JESSE_OWNER_NAME",
            "JESSE_OWNER_PRONOUN",
            "JESSE_LANGUAGES",
            "JESSE_DIET_KEYWORDS_EXTRA",
        ] {
            std::env::remove_var(k);
        }
        // Point the config search at a non-existent explicit path so no ambient
        // ./jesse.local.toml or ~/.jesse-bridge file bleeds into the test.
        std::env::set_var("JESSE_CONFIG", "/nonexistent/jesse.local.toml");
        std::env::set_var("JESSE_OWNER_NAME", "  Alex Example  ");
        std::env::set_var("JESSE_OWNER_PRONOUN", "they");
        std::env::set_var("JESSE_LANGUAGES", "en, es ,");
        std::env::set_var("JESSE_DIET_KEYWORDS_EXTRA", "Tacos, tacos, ELOTE");

        let p = Persona::load("");
        assert_eq!(p.owner_name, "Alex Example");
        assert_eq!(p.owner_pronoun, "they");
        assert_eq!(p.languages, vec!["en".to_string(), "es".to_string()]);
        assert_eq!(
            p.diet_keywords_extra,
            vec!["tacos".to_string(), "elote".to_string()]
        );

        for k in [
            "JESSE_CONFIG",
            "JESSE_OWNER_NAME",
            "JESSE_OWNER_PRONOUN",
            "JESSE_LANGUAGES",
            "JESSE_DIET_KEYWORDS_EXTRA",
        ] {
            std::env::remove_var(k);
        }
    }

    #[test]
    fn load_reads_toml_then_env_wins() {
        let _g = ENV_LOCK.lock_ok();
        for k in [
            "JESSE_CONFIG",
            "JESSE_OWNER_NAME",
            "JESSE_OWNER_PRONOUN",
            "JESSE_LANGUAGES",
            "JESSE_DIET_KEYWORDS_EXTRA",
            "JESSE_STATE_DIR",
        ] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            r#"
[persona]
owner_name = "Alex Example"
owner_pronoun = "her"
languages = ["en", "es"]
diet_keywords_extra = ["tacos", "elote"]
"#,
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let p = Persona::load("");
        assert_eq!(p.owner_name, "Alex Example");
        assert_eq!(p.owner_pronoun, "her");
        assert_eq!(p.languages, vec!["en".to_string(), "es".to_string()]);
        assert_eq!(
            p.diet_keywords_extra,
            vec!["tacos".to_string(), "elote".to_string()]
        );

        // Env overrides the TOML value for the same key.
        std::env::set_var("JESSE_OWNER_NAME", "Override Name");
        let p2 = Persona::load("");
        assert_eq!(p2.owner_name, "Override Name");
        assert_eq!(p2.owner_pronoun, "her"); // still from TOML

        std::env::remove_var("JESSE_CONFIG");
        std::env::remove_var("JESSE_OWNER_NAME");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The `[[schedule]]` array reaches the validator through the real TOML reader —
    /// including the `extra` catch-all, which is what turns a mistyped key into a named,
    /// individually-disabled entry instead of a key that silently does nothing.
    #[test]
    fn load_reads_the_schedule_array_including_a_mistyped_key() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-schedule-cfg-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            r#"
[persona]
owner_name = "Alex Example"

[[schedule]]
id = "overnight"
at = "02:30"
prompt_file = "prompts/overnight.md"
days = ["mon", "tue", "wed", "thu", "fri"]
catch_up_secs = 7200

[[schedule]]
id = "overnight-report"
after = "overnight"
after_on = "any"
prompt = "Summarise what the overnight pass changed."
mode = "tell"
timeout_secs = 900
notify = false

[[schedule]]
id = "typo"
at = "06:00"
prompt = "x"
catchup_secs = 60
"#,
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let raw = load_schedule("");
        assert_eq!(raw.len(), 3);
        let s = validate_schedule(&raw);
        assert!(s.fatal.is_empty(), "{:?}", s.fatal);

        // The two good entries survive, with every field carried through.
        assert_eq!(s.jobs.len(), 2);
        let head = s.get("overnight").unwrap();
        assert_eq!(head.at_label().as_deref(), Some("02:30"));
        assert_eq!(head.days.names(), vec!["mon", "tue", "wed", "thu", "fri"]);
        assert_eq!(head.catch_up_secs, 7200);
        assert_eq!(head.mode, "tell"); // the acting default
        assert!(head.notify);
        let link = s.get("overnight-report").unwrap();
        assert_eq!(link.after(), Some("overnight"));
        assert_eq!(link.after_on(), AfterOn::Any);
        assert_eq!(link.timeout_secs, Some(900));
        assert!(!link.notify);
        assert_eq!(s.chain("overnight"), vec!["overnight", "overnight-report"]);

        // The mistyped key disables ONLY its own entry, and says which key it was.
        assert_eq!(s.invalid.len(), 1);
        assert_eq!(s.invalid[0].id, "typo");
        assert!(s.invalid[0].reason.contains("catchup_secs"));

        // And the rest of the overlay file still loaded.
        assert_eq!(Persona::load("").owner_name, "Alex Example");

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file with NO `[[schedule]]` is a bridge with no scheduled jobs — not an error,
    /// and not a tick task.
    #[test]
    fn an_absent_schedule_array_is_an_empty_schedule() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_CONFIG", "/nonexistent/jesse.local.toml");
        assert!(load_schedule("").is_empty());
        let s = validate_schedule(&[]);
        assert!(s.jobs.is_empty() && s.invalid.is_empty() && !s.is_fatal());
        std::env::remove_var("JESSE_CONFIG");
    }

    #[test]
    fn malformed_toml_falls_back_to_defaults() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-bad-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(&file, "this is not = valid toml [[[").unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        // Soft-fail: a malformed file does not abort; we get generic defaults.
        let p = Persona::load("");
        assert_eq!(p, Persona::default());

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
