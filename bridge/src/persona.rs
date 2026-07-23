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
    /// Substitute the persona placeholders in a wrapper/floor template:
    ///   * `{Owner}` → the owner name with its first letter capitalized (sentence
    ///     starts — `"the user"` → `"The user"`, a real name is unchanged);
    ///   * `{owner}` → the owner name verbatim (mid-sentence);
    ///   * `{owner_pronoun}` → the possessive pronoun.
    ///
    /// A template with no placeholders (an app-supplied override) is returned
    /// unchanged. This is the ONLY substitution machinery — the wrappers stay plain
    /// strings, not `format!` call sites.
    pub fn render(&self, template: &str) -> String {
        template
            .replace("{Owner}", &capitalize_first(&self.owner_name))
            .replace("{owner}", &self.owner_name)
            .replace("{owner_pronoun}", &self.owner_pronoun)
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
}

/// Resolve the local overlay file, first existing wins:
///   1. `$JESSE_CONFIG` (an explicit file path — full operator control);
///   2. `./jesse.local.toml` (repo root / cwd — a fresh clone, `cargo run`);
///   3. `<state-dir>/jesse.local.toml` — `$JESSE_STATE_DIR` if set, else
///      `$HOME/.jesse-bridge` — the reliable spot for a launchd-managed service
///      whose cwd is not the repo.
///
/// Returns `None` when no candidate exists (the generic-default path).
fn local_config_path(home: &str) -> Option<PathBuf> {
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
pub fn load_local_models(home: &str) -> Vec<ModelToml> {
    load_local_config(home).map(|c| c.models).unwrap_or_default()
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
        assert_eq!(p.render("Custom wrapper, no tokens."), "Custom wrapper, no tokens.");
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
