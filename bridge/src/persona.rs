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
//!
//! ---- D6: THE PERSONA PACK ----------------------------------------------------
//!
//! The four fields above are the whole of what the bridge could personalize for as long as
//! personality lived in prose wrappers. It now carries a [`PersonaPack`] as well
//! ([`Persona::pack`]) — the agent crate's parameterised personality, rendered per wire by
//! `jesse_agent::persona::render` and CHECKED after the fact by
//! `jesse_agent::persona::check`.
//!
//! **THE FOUR LEGACY KEYS ARE THE PACK'S OWNER FIELDS.** `owner_name`, `owner_pronoun` and
//! `languages` are resolved exactly as they always were, through exactly the same
//! precedence, and then COPIED onto the pack. An existing `jesse.local.toml` therefore loads
//! to the same rendered placeholders it did before this module knew what a pack was, and a
//! test asserts precisely that. The new keys are additive and every one of them is optional.
//!
//! **THE TWO FILE-BACKED KEYS SOFT-FAIL LINE BY LINE.** `banned_patterns_file` is read in the
//! `draft-lint` format (one pattern per line, `#` comments); a line that will not compile is
//! ONE startup warning naming the line number, and the pack proceeds with the rest.
//! `writing_samples_dir` loads `.md` files oldest-first by name up to the pack's byte cap.
//! Neither path defaults to anything: a deployment that wants the vault's own list points at
//! it in the config file, and a fresh clone has neither.

use crate::*;
use jesse_agent::persona::{
    parse_pattern_file, render_placeholders, Pattern, PersonaPack, StylePolicy, WritingSample,
    WRITING_SAMPLES_BYTE_CAP,
};

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
    /// **The persona pack** — everything above plus the assistant's own identity, the style
    /// and formatting parameters, the banned patterns, the writing samples, the free text and
    /// the accumulated corrections.
    ///
    /// Its `owner` fields are kept EQUAL to the three legacy fields above by
    /// [`Persona::sync_pack_owner`], which every construction path runs. Two places that
    /// could disagree about the owner's name is exactly the bug the single-pass renderer
    /// exists to prevent, arrived at from the config side instead.
    pub pack: PersonaPack,
    /// What to do about a reply the style checker flags. `annotate` by default: check and
    /// report, deliver the model's own text, and never spend a second turn without being
    /// told to. See `jesse_agent::persona::StylePolicy`.
    pub style_policy: StylePolicy,
}

impl Default for Persona {
    fn default() -> Self {
        Persona {
            owner_name: DEFAULT_OWNER_NAME.to_string(),
            owner_pronoun: DEFAULT_OWNER_PRONOUN.to_string(),
            languages: vec![DEFAULT_LANGUAGE.to_string()],
            diet_keywords_extra: Vec::new(),
            pack: PersonaPack::default(),
            style_policy: StylePolicy::default(),
        }
    }
}

impl Persona {
    /// Substitute the persona placeholders in a template:
    ///   * `{Owner}` → the owner name with its first letter capitalized (sentence
    ///     starts — `"the user"` → `"The user"`, a real name is unchanged);
    ///   * `{owner}` → the owner name verbatim (mid-sentence);
    ///   * `{owner_pronoun}` → the possessive pronoun;
    ///   * `{assistant}` → the assistant's own name (D6; `"Jesse"` by default).
    ///
    /// **THE VALUES COME FROM THE PACK, THE SCANNER STAYS HERE.** D6 moved the four
    /// substitutions into `jesse_agent::persona::render_placeholders`, which returns them
    /// longest-name-first; it did NOT move this loop, because this loop is the thing whose
    /// doc comment below explains a real bug it prevents, and a scanner that lived in two
    /// crates for a release would be two scanners. The pack feeds the one that exists.
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
        // Longest first, so a shorter placeholder can never shadow a longer one that starts
        // with it — `render_placeholders` sorts them that way and says so, which is what
        // keeps the property true now that there are four rather than three.
        let placeholders = render_placeholders(&self.pack);
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

    /// A persona built from the four legacy fields alone, with the pack derived from them.
    ///
    /// The constructor tests and callers use instead of a struct literal, so that the
    /// pack-owner invariant holds by construction rather than by everyone remembering.
    pub fn from_legacy(
        owner_name: impl Into<String>,
        owner_pronoun: impl Into<String>,
        languages: Vec<String>,
        diet_keywords_extra: Vec<String>,
    ) -> Self {
        let mut p = Persona {
            owner_name: owner_name.into(),
            owner_pronoun: owner_pronoun.into(),
            languages,
            diet_keywords_extra,
            ..Persona::default()
        };
        p.sync_pack_owner();
        p
    }

    /// Copy the resolved legacy fields onto the pack.
    ///
    /// Called at the END of every construction path, after the file and the environment have
    /// had their say, so the pack the renderer reads and the fields the rest of the bridge
    /// reads can never name two different owners. The direction is one way on purpose:
    /// `owner_name` is the key an operator has been setting since the first release, and a
    /// pack field that could silently win over it is how an upgrade changes somebody's
    /// prompts without them touching their config.
    pub(crate) fn sync_pack_owner(&mut self) {
        self.pack.owner.name = self.owner_name.clone();
        self.pack.owner.pronoun = self.owner_pronoun.clone();
        self.pack.languages = self.languages.clone();
    }

    /// Load the persona: generic defaults → `jesse.local.toml` `[persona]` → env.
    /// `home` is the captured `Config.home` (used to resolve the state-dir config
    /// location). Never fails: a missing file is the default, a malformed file logs
    /// one warning and falls back to the default.
    ///
    /// The D6 pack keys are read from the same table in the same pass, and every one of them
    /// soft-fails the same way the rest of this module does: a value that does not parse is
    /// one stderr warning naming the key and the value, and the default stands.
    pub fn load(home: &str) -> Self {
        let mut p = Persona::default();
        if let Some(t) = load_local_persona(home) {
            p.apply_pack_toml(&t, home);
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
        // LAST, after the file and the environment: the pack's owner is whatever the
        // precedence chain settled on, never a third opinion.
        p.sync_pack_owner();
        p
    }

    /// Overlay the D6 `[persona]` keys onto the pack. Every key optional, every bad value one
    /// warning and a default.
    fn apply_pack_toml(&mut self, t: &PersonaToml, home: &str) {
        if let Some(v) = trimmed_nonempty(t.assistant_name.clone()) {
            self.pack.assistant.name = v;
        }
        self.pack.assistant.self_description = trimmed_nonempty(t.assistant_description.clone());
        if let Some(v) = parse_key("address_style", t.address_style.as_deref()) {
            self.pack.owner.address_style = v;
        }
        if let Some(st) = &t.style {
            let s = &mut self.pack.style;
            set_param(&mut s.formality, "style.formality", st.formality.as_deref());
            set_param(&mut s.humor, "style.humor", st.humor.as_deref());
            set_param(&mut s.verbosity, "style.verbosity", st.verbosity.as_deref());
            set_param(&mut s.emoji, "style.emoji", st.emoji.as_deref());
            set_param(&mut s.hedging, "style.hedging", st.hedging.as_deref());
            set_param(&mut s.questions, "style.questions", st.questions.as_deref());
        }
        if let Some(ft) = &t.formatting {
            let f = &mut self.pack.formatting;
            set_param(&mut f.lists, "formatting.lists", ft.lists.as_deref());
            set_param(
                &mut f.headings,
                "formatting.headings",
                ft.headings.as_deref(),
            );
            set_param(&mut f.dashes, "formatting.dashes", ft.dashes.as_deref());
        }
        if let Some(path) = trimmed_nonempty(t.banned_patterns_file.clone()) {
            self.pack.banned_patterns = load_banned_patterns(&expand_tilde(&path, home));
        }
        if let Some(dir) = trimmed_nonempty(t.writing_samples_dir.clone()) {
            for sample in load_writing_samples(&expand_tilde(&dir, home)) {
                if !self.pack.push_writing_sample(sample) {
                    eprintln!(
                        "jesse-bridge: WARNING writing_samples_dir {dir} exceeds the {WRITING_SAMPLES_BYTE_CAP}-byte cap; \
                         the samples past it were not loaded."
                    );
                    break;
                }
            }
        }
        self.pack.free_text = trimmed_nonempty(t.free_text.clone());
        if let Some(v) = parse_key("style_policy", t.style_policy.as_deref()) {
            self.style_policy = v;
        }
    }
}

/// Parse one optional `[persona]` value, warning by KEY and value when it will not parse.
///
/// `None` (absent, blank, or unparseable) means "leave the default alone" — the same
/// soft-fail every other key in this module has, so one mistyped word never takes a
/// deployment's whole persona down with it.
fn parse_key<T: std::str::FromStr<Err = String>>(key: &str, raw: Option<&str>) -> Option<T> {
    let raw = raw.map(str::trim).filter(|s| !s.is_empty())?;
    match raw.parse::<T>() {
        Ok(v) => Some(v),
        Err(e) => {
            eprintln!("jesse-bridge: WARNING [persona] {key}: {e}; using the default.");
            None
        }
    }
}

/// [`parse_key`] straight onto a field.
fn set_param<T: std::str::FromStr<Err = String>>(field: &mut T, key: &str, raw: Option<&str>) {
    if let Some(v) = parse_key(key, raw) {
        *field = v;
    }
}

/// Read a `draft-lint`-format banned-pattern file.
///
/// **A LINE THAT WILL NOT COMPILE IS A WARNING, NOT A FAILURE.** One warning per bad line,
/// naming the line number and what was wrong, and the pack takes every line that did parse.
/// Refusing the whole file would mean one typo silently disarming every rule in it, which is
/// the failure mode a checker can least afford: it looks exactly like a model that complied.
/// An unreadable file is one warning and an empty list.
fn load_banned_patterns(path: &str) -> Vec<Pattern> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "jesse-bridge: WARNING could not read banned_patterns_file {path} ({e}); \
                 no banned patterns are loaded."
            );
            return Vec::new();
        }
    };
    let (patterns, warnings) = parse_pattern_file(&text);
    for w in &warnings {
        eprintln!("jesse-bridge: WARNING banned_patterns_file {path} {w}");
    }
    patterns
}

/// Read the writing samples from a directory: `*.md`, sorted by name (oldest first, which is
/// what a dated file name gives), each one's title taken from its first markdown heading and
/// falling back to its file stem.
///
/// The byte cap is the PACK's, enforced by [`PersonaPack::push_writing_sample`] at the call
/// site above rather than here, so there is one place that decides what fits.
fn load_writing_samples(dir: &str) -> Vec<WritingSample> {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            eprintln!(
                "jesse-bridge: WARNING could not read writing_samples_dir {dir} ({e}); \
                 no writing samples are loaded."
            );
            return Vec::new();
        }
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_file())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.to_ascii_lowercase().ends_with(".md"))
        .collect();
    names.sort();
    let mut out = Vec::new();
    for name in names {
        let Ok(text) = std::fs::read_to_string(Path::new(dir).join(&name)) else {
            eprintln!("jesse-bridge: WARNING writing sample {name} could not be read; skipped.");
            continue;
        };
        if text.trim().is_empty() {
            continue;
        }
        let title = first_heading(&text).unwrap_or_else(|| {
            name.trim_end_matches(".md")
                .trim_end_matches(".MD")
                .to_string()
        });
        out.push(WritingSample {
            title,
            text: text.trim().to_string(),
            source: Some(name),
        });
    }
    out
}

/// The text of the first ATX heading in a markdown document, or `None`.
fn first_heading(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .find(|l| l.starts_with('#'))
        .map(|l| l.trim_start_matches('#').trim().to_string())
        .filter(|t| !t.is_empty())
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
    // ---- D6: the pack keys. Every one optional, every one additive. ------------------
    /// What the assistant is called. Default `"Jesse"`.
    assistant_name: Option<String>,
    /// One sentence about what this assistant is for. Rendered only when set.
    assistant_description: Option<String>,
    /// `by_name` | `neutral` | `formal`.
    address_style: Option<String>,
    /// The `[persona.style]` sub-table.
    style: Option<StyleToml>,
    /// The `[persona.formatting]` sub-table.
    formatting: Option<FormattingToml>,
    /// A path to a banned-pattern list in the `draft-lint` format. `~` expands.
    banned_patterns_file: Option<String>,
    /// A directory of `.md` writing samples. `~` expands.
    writing_samples_dir: Option<String>,
    /// The owner's own words about how they want the assistant to behave.
    free_text: Option<String>,
    /// `off` | `annotate` | `regenerate` | `regenerate:<n>`.
    style_policy: Option<String>,
}

/// `[persona.style]`. Values stay UNTYPED here for the same reason `[concurrency]`'s do: a
/// mistyped word must be reportable by name, and a typed field would fail the parse of the
/// whole overlay file and take the schedule and the model registry down with the persona.
#[derive(Deserialize, Default)]
struct StyleToml {
    formality: Option<String>,
    humor: Option<String>,
    verbosity: Option<String>,
    emoji: Option<String>,
    hedging: Option<String>,
    questions: Option<String>,
}

/// `[persona.formatting]`. Untyped for the same reason as [`StyleToml`].
#[derive(Deserialize, Default)]
struct FormattingToml {
    lists: Option<String>,
    headings: Option<String>,
    dashes: Option<String>,
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
    use jesse_agent::persona::{
        AddressStyle, Dashes, Emoji, Formality, Headings, Hedging, Humor, Lists, Questions,
        Verbosity,
    };

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
        let p = Persona::from_legacy("Alex", "her", vec!["en".into(), "es".into()], vec![]);
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
        let p = Persona::from_legacy("{owner_pronoun}", "her", vec!["en".into()], vec![]);
        assert_eq!(p.render("{Owner} asks."), "{owner_pronoun} asks.");
        assert_eq!(p.render("{owner} asks."), "{owner_pronoun} asks.");
        // The genuine pronoun placeholder still renders — only the SUBSTITUTED text is
        // out of scope for further substitution.
        assert_eq!(
            p.render("{owner} on {owner_pronoun} phone"),
            "{owner_pronoun} on her phone"
        );

        // The other direction: a pronoun that spells the name placeholder.
        let q = Persona::from_legacy("Alex", "{Owner}", vec!["en".into()], vec![]);
        assert_eq!(q.render("{owner_pronoun} phone"), "{Owner} phone");

        // And a name that would recurse forever under any rescanning scheme.
        let r = Persona::from_legacy("{owner}", "their", vec!["en".into()], vec![]);
        assert_eq!(r.render("{owner} and {owner}"), "{owner} and {owner}");
    }

    /// Braces that are not one of the three placeholders are prose, not syntax — an
    /// item's markdown, a code snippet, a JSON blob the user pasted. They survive
    /// byte for byte, including a lone `{` at the very end of the text.
    #[test]
    fn render_passes_unknown_braces_through_unchanged() {
        let p = Persona::from_legacy("Alex", "her", vec!["en".into()], vec![]);
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

    // ---- D6: the pack --------------------------------------------------------

    /// **THE COMPATIBILITY ASSERTION.** A `jesse.local.toml` written before the pack existed
    /// renders exactly the placeholders it always did, because the four legacy keys ARE the
    /// pack's owner fields and nothing else in the pack touches them.
    #[test]
    fn a_legacy_persona_file_renders_the_same_placeholders_as_before() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-legacy-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            "[persona]\nowner_name = \"Alex Example\"\nowner_pronoun = \"her\"\nlanguages = [\"en\", \"es\"]\n",
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let loaded = Persona::load("");
        // Byte for byte what a pre-pack build rendered from the same file.
        let template = "{Owner} asks from {owner_pronoun} phone; {owner} waits.";
        assert_eq!(
            loaded.render(template),
            "Alex Example asks from her phone; Alex Example waits."
        );
        // And the pack agrees with the legacy fields rather than holding a second opinion.
        assert_eq!(loaded.pack.owner.name, "Alex Example");
        assert_eq!(loaded.pack.owner.pronoun, "her");
        assert_eq!(
            loaded.pack.languages,
            vec!["en".to_string(), "es".to_string()]
        );
        // Nothing else was configured, so the rest of the pack is the shipped default.
        assert_eq!(loaded.pack.assistant.name, "Jesse");
        assert!(loaded.pack.banned_patterns.is_empty());
        assert_eq!(loaded.style_policy, StylePolicy::Annotate);

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The `{assistant}` placeholder is fed from the pack, and the scanner that renders it is
    /// the same single-pass one the other three go through.
    #[test]
    fn the_assistant_placeholder_renders_from_the_pack() {
        let mut p = Persona::default();
        assert_eq!(p.render("Hello, {assistant}."), "Hello, Jesse.");
        p.pack.assistant.name = "Ada".into();
        assert_eq!(p.render("Hello, {assistant}."), "Hello, Ada.");
        // A value that spells another placeholder is still never re-expanded.
        p.pack.assistant.name = "{owner}".into();
        assert_eq!(p.render("{assistant} and {owner}"), "{owner} and the user");
    }

    #[test]
    fn every_new_pack_key_loads_from_the_persona_table() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-pack-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("patterns.txt"),
            "# fixture\n\n\\bdelve\\b\n\\btapestry\\b\n",
        )
        .unwrap();
        let samples = dir.join("samples");
        std::fs::create_dir_all(&samples).unwrap();
        std::fs::write(
            samples.join("2026-01-02-second.md"),
            "# The second one\n\nWritten later.\n",
        )
        .unwrap();
        std::fs::write(samples.join("2026-01-01-first.md"), "No heading here.\n").unwrap();
        std::fs::write(samples.join("notes.txt"), "not markdown, not loaded").unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            format!(
                r#"
[persona]
owner_name = "Alex Example"
assistant_name = "Ada"
assistant_description = "a research assistant"
address_style = "neutral"
banned_patterns_file = "{patterns}"
writing_samples_dir = "{samples}"
free_text = "  Answer the question I asked.  "
style_policy = "regenerate:2"

[persona.style]
formality = "low"
humor = "dry"
verbosity = "terse"
emoji = "sparingly"
hedging = "minimal"
questions = "assume_and_state"

[persona.formatting]
lists = "avoid"
headings = "freely"
dashes = "allowed"
"#,
                patterns = dir.join("patterns.txt").display(),
                samples = samples.display(),
            ),
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let p = Persona::load("");
        assert_eq!(p.pack.assistant.name, "Ada");
        assert_eq!(
            p.pack.assistant.self_description.as_deref(),
            Some("a research assistant")
        );
        assert_eq!(p.pack.owner.address_style, AddressStyle::Neutral);
        assert_eq!(p.pack.style.formality, Formality::Low);
        assert_eq!(p.pack.style.humor, Humor::Dry);
        assert_eq!(p.pack.style.verbosity, Verbosity::Terse);
        assert_eq!(p.pack.style.emoji, Emoji::Sparingly);
        assert_eq!(p.pack.style.hedging, Hedging::Minimal);
        assert_eq!(p.pack.style.questions, Questions::AssumeAndState);
        assert_eq!(p.pack.formatting.lists, Lists::Avoid);
        assert_eq!(p.pack.formatting.headings, Headings::Freely);
        assert_eq!(p.pack.formatting.dashes, Dashes::Allowed);
        assert_eq!(p.style_policy, StylePolicy::Regenerate { max_attempts: 2 });
        // The free text is trimmed but otherwise verbatim.
        assert_eq!(
            p.pack.free_text.as_deref(),
            Some("Answer the question I asked.")
        );
        // Patterns, comments and blanks skipped.
        assert_eq!(
            p.pack
                .banned_patterns
                .iter()
                .map(|x| x.source())
                .collect::<Vec<_>>(),
            vec!["\\bdelve\\b", "\\btapestry\\b"]
        );
        // Samples: `.md` only, sorted by name (oldest first), source recorded, title from the
        // first heading with the file stem as the fallback.
        assert_eq!(p.pack.writing_samples.len(), 2);
        assert_eq!(
            p.pack.writing_samples[0].source.as_deref(),
            Some("2026-01-01-first.md")
        );
        assert_eq!(p.pack.writing_samples[0].title, "2026-01-01-first");
        assert_eq!(p.pack.writing_samples[1].title, "The second one");

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A patterns file with a line that will not compile keeps every line that DID, because
    /// one typo silently disarming a whole banned list is the failure a checker can least
    /// afford: it looks exactly like a model that complied.
    #[test]
    fn a_malformed_patterns_file_keeps_what_parsed() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-badpat-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("patterns.txt"),
            "\\bdelve\\b\n[unclosed\n\\btapestry\\b\n",
        )
        .unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            format!(
                "[persona]\nbanned_patterns_file = \"{}\"\n",
                dir.join("patterns.txt").display()
            ),
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let p = Persona::load("");
        assert_eq!(
            p.pack
                .banned_patterns
                .iter()
                .map(|x| x.source())
                .collect::<Vec<_>>(),
            vec!["\\bdelve\\b", "\\btapestry\\b"],
            "the bad line is dropped and warned about; the good ones survive"
        );

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A mistyped parameter value warns and leaves the default, rather than failing the parse
    /// of the whole overlay file and taking the schedule and the model registry down with it.
    #[test]
    fn a_mistyped_parameter_value_leaves_the_default() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let dir = std::env::temp_dir().join(format!("jesse-persona-typo-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            "[persona]\nowner_name = \"Alex\"\nstyle_policy = \"shout\"\n\n[persona.formatting]\ndashes = \"banned\"\n",
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let p = Persona::load("");
        assert_eq!(p.owner_name, "Alex", "the rest of the table still loaded");
        assert_eq!(p.style_policy, StylePolicy::Annotate);
        assert_eq!(p.pack.formatting.dashes, Dashes::Forbidden);

        std::env::remove_var("JESSE_CONFIG");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A missing patterns file or samples directory is a warning and an empty list, never a
    /// startup failure.
    #[test]
    fn missing_pack_files_are_warnings_not_failures() {
        assert!(load_banned_patterns("/nonexistent/patterns.txt").is_empty());
        assert!(load_writing_samples("/nonexistent/samples").is_empty());
    }

    /// **The shipped example config must load through the real loader.**
    /// `jesse.example.toml` documents every key an operator copies into their own file, so a
    /// key documented with a value the loader rejects is a broken instruction shipped in the
    /// repository. A mistyped parameter falls back silently to its default by design (see
    /// [`parse_key`]), which is exactly why the example needs a test rather than a read.
    #[test]
    fn the_shipped_example_config_loads() {
        let _g = ENV_LOCK.lock_ok();
        for k in ["JESSE_CONFIG", "JESSE_OWNER_NAME", "JESSE_STATE_DIR"] {
            std::env::remove_var(k);
        }
        let example = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("bridge/ has a parent")
            .join("jesse.example.toml");
        std::env::set_var("JESSE_CONFIG", &example);
        let p = Persona::load("");
        std::env::remove_var("JESSE_CONFIG");

        // The four legacy keys, as the file documents them.
        assert_eq!(p.owner_name, "Alex Example");
        assert_eq!(p.owner_pronoun, "their");
        assert_eq!(p.languages, vec!["en".to_string(), "es".to_string()]);
        assert!(!p.diet_keywords_extra.is_empty());
        // The D6 keys, as the file documents them. Each of these would be the DEFAULT if the
        // example spelled its value wrong, so every one is asserted against what the file says
        // rather than against the default.
        assert_eq!(p.pack.assistant.name, "Jesse");
        assert!(p.pack.assistant.self_description.is_some());
        assert_eq!(p.pack.owner.address_style, AddressStyle::ByName);
        assert_eq!(p.style_policy, StylePolicy::Annotate);
        assert!(p.pack.free_text.is_some());
        assert_eq!(p.pack.style.formality, Formality::Medium);
        assert_eq!(p.pack.style.humor, Humor::Light);
        assert_eq!(p.pack.style.verbosity, Verbosity::Normal);
        assert_eq!(p.pack.style.emoji, Emoji::Never);
        assert_eq!(p.pack.style.hedging, Hedging::Normal);
        assert_eq!(p.pack.style.questions, Questions::AskBeforeAssuming);
        assert_eq!(p.pack.formatting.lists, Lists::WhenAsked);
        assert_eq!(p.pack.formatting.headings, Headings::WhenLong);
        assert_eq!(p.pack.formatting.dashes, Dashes::Forbidden);
        // The two file-backed keys are COMMENTED OUT in the example (neither defaults to the
        // vault), so a fresh copy loads with no patterns and no samples.
        assert!(p.pack.banned_patterns.is_empty());
        assert!(p.pack.writing_samples.is_empty());
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
