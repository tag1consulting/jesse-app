//! **The persona pack** — personality as DATA, above the model.
//!
//! A long prose system prompt is not portable. The same paragraph makes one model chatty
//! and another terse, and the only way to find out is to ship it; when the backend is
//! swapped the assistant's voice changes with it, silently. So the personality this crate
//! carries is not prose. It is a [`PersonaPack`]: a small set of named parameters, a list
//! of banned patterns, a handful of writing samples, and one free-text field the owner
//! writes in their own words. The prose is GENERATED from the pack, by
//! [`render`](render::render), in one fixed vocabulary, and the same pack renders to the
//! same sentences on every wire.
//!
//! Three parts, three files:
//!
//! | Module | Responsible for |
//! |---|---|
//! | this one | The pack: the fields, their defaults, and their serialisation. |
//! | [`mod@render`] | Pack → the persona portion of a system prefix, as [`SystemBlock`]s. |
//! | [`mod@check`] | Generated text → a content-free [`StyleReport`], and what to do about it. |
//!
//! **Voice is a CHECKED property here, not an obeyed instruction.** The rendered blocks ask
//! the model for a voice; [`check()`] then reads what came back and says whether
//! it complied. An instruction a model ignored is invisible; a report is not.
//!
//! **The free text is never trusted.** It is the owner's own words about how they want to be
//! spoken to, carried verbatim into the prefix because paraphrasing it would defeat the
//! point — and checked exactly like everything else, because a sentence in it that asks for
//! banned vocabulary does not change what the checker counts.
//!
//! [`SystemBlock`]: crate::provider::SystemBlock

pub mod check;
pub mod render;

pub use check::{
    apply, check, regeneration_request, Applied, Hit, StylePolicy, StyleReport, DEFAULT_ATTEMPTS,
};
pub use render::{render, render_placeholders, Placeholder};

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// The pack schema version stamped into [`PersonaPack::version`].
///
/// It exists so a pack written by an older build can be told apart on sight, before anything
/// tries to read a field that did not exist when it was written. Bump it when a field's
/// MEANING changes; adding an optional field with a default does not need it, because serde
/// already fills that in.
pub const PACK_VERSION: u32 = 1;

/// The default assistant name — the product's own, and the one the bridge's identity line
/// has always rendered.
pub const DEFAULT_ASSISTANT_NAME: &str = "Jesse";

/// The generic default owner label. A fresh install addresses "the user" and names nobody.
pub const DEFAULT_OWNER_NAME: &str = "the user";

/// The generic default possessive pronoun; "{owner_pronoun} vault" reads as "their vault".
pub const DEFAULT_OWNER_PRONOUN: &str = "their";

/// The generic default language list.
pub const DEFAULT_LANGUAGE: &str = "en";

/// The total byte cap on [`PersonaPack::writing_samples`].
///
/// 16 KiB — roughly four screens of prose, or four thousand tokens on every single turn.
/// Samples are the most expensive thing in the pack (they are carried verbatim, on every
/// request, forever) and the most tempting to over-supply, so the cap is enforced by the
/// pack itself rather than left to whoever writes the loader. Beyond about this much, a
/// model is imitating an anthology rather than a voice.
pub const WRITING_SAMPLES_BYTE_CAP: usize = 16 * 1024;

// ===========================================================================
// The pack
// ===========================================================================

/// Everything the product knows about how this assistant should talk, in one serialisable
/// value.
///
/// EVERY FIELD HAS A DEFAULT, and `PersonaPack::default()` is a complete, usable, generic
/// assistant: named [`DEFAULT_ASSISTANT_NAME`], addressing "the user", with
/// [`Dashes::Forbidden`] and an empty banned-pattern list. Nothing has to be configured for
/// the pack to render.
///
/// **FIELD ORDER IS LOAD-BEARING FOR TOML.** A TOML document may not put a bare value after
/// a table, so the scalars and the arrays-of-scalars come first, then the sub-tables, then
/// the arrays-of-tables. Serde emits fields in declaration order, so this ordering is what
/// makes `toml::to_string(&pack)` produce a document that parses back. The logical reading
/// order is the one the doc comments give.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PersonaPack {
    /// The schema version this pack was written at. See [`PACK_VERSION`].
    pub version: u32,
    /// The languages the owner writes in, most-used first (`["en", "it"]`). Rendered into
    /// the identity block, so the assistant knows it may be addressed in any of them.
    pub languages: Vec<String>,
    /// The vocabulary this assistant must not use, as compiled patterns plus the source
    /// line each came from. EMPTY by default: a shipped list of banned words would be one
    /// deployment's taste baked into everybody's build.
    pub banned_patterns: Vec<Pattern>,
    /// The owner's own words about how they want the assistant to behave, carried VERBATIM
    /// into the last persona block.
    ///
    /// Never trusted and always checked: it is the one field whose content the owner writes
    /// as prose rather than as parameters, so it is exactly where an instruction that
    /// contradicts the style parameters would arrive. The renderer frames it as the owner
    /// speaking; the checker treats the output that follows it like any other output.
    pub free_text: Option<String>,
    /// Who the assistant is.
    pub assistant: AssistantIdentity,
    /// Who it is talking to.
    pub owner: OwnerIdentity,
    /// The voice parameters, rendered as short imperative rules.
    pub style: StyleParams,
    /// The output-shape parameters, rendered as short imperative rules.
    pub formatting: FormattingParams,
    /// Examples of the owner's voice, framed as DATA to imitate rather than rules to
    /// follow. Total size bounded by [`WRITING_SAMPLES_BYTE_CAP`].
    pub writing_samples: Vec<WritingSample>,
    /// The accumulated corrections — the "always put the time in the subject line" rules the
    /// product's correction loop writes when the owner tells the assistant it got something
    /// wrong.
    ///
    /// EMPTY IN PHASE 1, and present anyway. The field and its rendering exist now so that
    /// the loop which writes them lands as a writer against a shape that is already rendered
    /// and already tested, rather than as a writer plus a reader plus a prompt change.
    pub corrections: Vec<Correction>,
}

impl Default for PersonaPack {
    fn default() -> Self {
        PersonaPack {
            version: PACK_VERSION,
            languages: vec![DEFAULT_LANGUAGE.to_string()],
            banned_patterns: Vec::new(),
            free_text: None,
            assistant: AssistantIdentity::default(),
            owner: OwnerIdentity::default(),
            style: StyleParams::default(),
            formatting: FormattingParams::default(),
            writing_samples: Vec::new(),
            corrections: Vec::new(),
        }
    }
}

impl PersonaPack {
    /// The bytes the writing samples currently occupy (their text only — the frame the
    /// renderer wraps them in is generated and does not count against the owner's budget).
    pub fn writing_sample_bytes(&self) -> usize {
        self.writing_samples.iter().map(|s| s.text.len()).sum()
    }

    /// Append a writing sample if it fits inside [`WRITING_SAMPLES_BYTE_CAP`].
    ///
    /// Returns `false` and keeps the pack unchanged when it does not. A sample is accepted
    /// or refused WHOLE rather than truncated: half a sample is a sample of a voice that
    /// stops mid-sentence, which is a worse example than none.
    pub fn push_writing_sample(&mut self, sample: WritingSample) -> bool {
        if self.writing_sample_bytes() + sample.text.len() > WRITING_SAMPLES_BYTE_CAP {
            return false;
        }
        self.writing_samples.push(sample);
        true
    }

    /// The pack with the two CONTENT fields removed — the writing samples and the free text.
    ///
    /// What is left is a description of how the assistant is configured to talk; what is
    /// taken out is the owner's own prose. That distinction is what makes this the shape a
    /// read endpoint may return: "what your assistant knows about how to talk to you" is a
    /// settings screen, not a document viewer.
    pub fn without_content(&self) -> PersonaPack {
        PersonaPack {
            writing_samples: Vec::new(),
            free_text: None,
            ..self.clone()
        }
    }
}

/// Generate `FromStr` for one parameter enum from the same spellings its serde attribute
/// uses.
///
/// The spellings exist twice — once for serde, once here — and the macro is what keeps that
/// from being twice to EDIT: a config file spells a parameter as a bare word (`formality =
/// "low"`), so a loader needs a fallible string parse that can name the valid values in its
/// warning, and serde's derive gives a `Deserializer` rather than a `FromStr`. Hand-writing
/// ten of these was the alternative.
macro_rules! param_from_str {
    ($t:ident { $($s:literal => $v:ident),+ $(,)? }) => {
        impl std::str::FromStr for $t {
            type Err = String;

            fn from_str(raw: &str) -> Result<Self, Self::Err> {
                match raw.trim().to_ascii_lowercase().as_str() {
                    $($s => Ok($t::$v),)+
                    other => Err(format!(
                        "`{other}` is not a valid {} (one of: {})",
                        stringify!($t),
                        [$($s),+].join(", ")
                    )),
                }
            }
        }
    };
}

param_from_str!(AddressStyle { "by_name" => ByName, "neutral" => Neutral, "formal" => Formal });
param_from_str!(Formality { "low" => Low, "medium" => Medium, "high" => High });
param_from_str!(Humor { "none" => None, "light" => Light, "dry" => Dry, "frequent" => Frequent });
param_from_str!(Verbosity { "terse" => Terse, "normal" => Normal, "long" => Long });
param_from_str!(Emoji { "never" => Never, "sparingly" => Sparingly, "freely" => Freely });
param_from_str!(Hedging { "minimal" => Minimal, "normal" => Normal });
param_from_str!(Questions {
    "ask_before_assuming" => AskBeforeAssuming,
    "assume_and_state" => AssumeAndState,
});
param_from_str!(Lists { "avoid" => Avoid, "when_asked" => WhenAsked, "freely" => Freely });
param_from_str!(Headings { "avoid" => Avoid, "when_long" => WhenLong, "freely" => Freely });
param_from_str!(Dashes { "forbidden" => Forbidden, "allowed" => Allowed });

/// Who the assistant is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AssistantIdentity {
    /// Its name. The product asks for this during onboarding; it is rendered into the
    /// identity block and fed to the `{assistant}` placeholder.
    pub name: String,
    /// One sentence the owner wrote about what this assistant is for. `None` renders
    /// nothing at all rather than a generic filler sentence — an assistant described as "a
    /// helpful assistant" is described as nothing.
    pub self_description: Option<String>,
}

impl Default for AssistantIdentity {
    fn default() -> Self {
        AssistantIdentity {
            name: DEFAULT_ASSISTANT_NAME.to_string(),
            self_description: None,
        }
    }
}

/// Who the assistant is talking to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct OwnerIdentity {
    /// How the assistant refers to the owner. Default `"the user"`.
    pub name: String,
    /// The owner's POSSESSIVE pronoun (`"their"` / `"his"` / `"her"` / …).
    pub pronoun: String,
    /// How directly the assistant addresses them.
    pub address_style: AddressStyle,
}

impl Default for OwnerIdentity {
    fn default() -> Self {
        OwnerIdentity {
            name: DEFAULT_OWNER_NAME.to_string(),
            pronoun: DEFAULT_OWNER_PRONOUN.to_string(),
            address_style: AddressStyle::default(),
        }
    }
}

/// How the assistant addresses the owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AddressStyle {
    /// Use their name where it reads naturally. The default: a named assistant talking to a
    /// named person is what the onboarding produces.
    #[default]
    ByName,
    /// Say "you"; never use their name. For an owner who finds being named repeatedly by
    /// software uncomfortable.
    Neutral,
    /// Keep the register formal and impersonal — no name, no first person plural.
    Formal,
}

/// The voice parameters. Each renders to exactly one short imperative sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct StyleParams {
    /// How formal the register is.
    pub formality: Formality,
    /// How much humour is welcome.
    pub humor: Humor,
    /// How long an answer should be by default.
    pub verbosity: Verbosity,
    /// Whether emoji may appear.
    pub emoji: Emoji,
    /// How much qualifying language ("it seems", "you may want to consider") is acceptable.
    pub hedging: Hedging,
    /// What to do when the request is ambiguous.
    pub questions: Questions,
}

impl Default for StyleParams {
    fn default() -> Self {
        StyleParams {
            formality: Formality::Medium,
            humor: Humor::Light,
            verbosity: Verbosity::Normal,
            emoji: Emoji::Never,
            hedging: Hedging::Normal,
            questions: Questions::AskBeforeAssuming,
        }
    }
}

/// How formal the register is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Formality {
    /// Plain and colloquial.
    Low,
    /// Plain, but not chatty.
    Medium,
    /// Precise and professional.
    High,
}

/// How much humour is welcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Humor {
    /// None at all.
    None,
    /// Occasional and light.
    Light,
    /// Dry and understated.
    Dry,
    /// Frequent.
    Frequent,
}

/// How long an answer should be by default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verbosity {
    /// As few words as carry the answer.
    Terse,
    /// A short paragraph or two.
    Normal,
    /// Room to explain the reasoning.
    Long,
}

/// Whether emoji may appear.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Emoji {
    /// Never.
    Never,
    /// Rarely, and never decoratively.
    Sparingly,
    /// Freely.
    Freely,
}

/// How much qualifying language is acceptable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Hedging {
    /// State the answer; say "I do not know" instead of qualifying one you do not have.
    Minimal,
    /// Qualify where the uncertainty is real.
    Normal,
}

/// What to do when the request is ambiguous.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Questions {
    /// Ask one clarifying question before acting on a guess.
    AskBeforeAssuming,
    /// Act on the most likely reading and say which one was taken.
    AssumeAndState,
}

/// The output-shape parameters. Each renders to exactly one short imperative sentence, and
/// each of the three is also CHECKABLE — see [`mod@check`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct FormattingParams {
    /// Whether bullet lists may be used.
    pub lists: Lists,
    /// Whether markdown headings may be used.
    pub headings: Headings,
    /// Whether dashes may be used.
    pub dashes: Dashes,
}

impl Default for FormattingParams {
    fn default() -> Self {
        FormattingParams {
            lists: Lists::WhenAsked,
            headings: Headings::WhenLong,
            // FORBIDDEN BY DEFAULT, and it is the one default that takes a side. Every dash
            // variant is the single most reliable machine-writing tell there is, it is
            // trivially checkable, and a reader who wants dashes back turns one key on.
            dashes: Dashes::Forbidden,
        }
    }
}

/// Whether bullet lists may be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lists {
    /// Write prose; never bullet an answer.
    Avoid,
    /// Only when the answer is genuinely a list, or the owner asked for one.
    WhenAsked,
    /// Whenever they help.
    Freely,
}

/// Whether markdown headings may be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Headings {
    /// Never.
    Avoid,
    /// Only in a long answer that genuinely has sections.
    WhenLong,
    /// Whenever they help.
    Freely,
}

/// Whether dashes may be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dashes {
    /// No em dash, no en dash, no double hyphen. Checked.
    Forbidden,
    /// Allowed, and not checked.
    Allowed,
}

/// One example of the owner's voice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WritingSample {
    /// A short label for the sample, shown to the model so it can tell one from another.
    pub title: String,
    /// The sample itself, carried verbatim.
    pub text: String,
    /// Where it came from (a file name, a URL), for the owner's benefit. `None` when the
    /// sample was typed in rather than loaded.
    pub source: Option<String>,
}

/// One accumulated correction — a rule the owner taught the assistant after it got
/// something wrong.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Correction {
    /// The rule, in the imperative ("always put the time in the subject line").
    pub rule: String,
    /// When it was added, as an RFC3339 timestamp. A STRING rather than a date type: it is
    /// displayed and ordered, never arithmetic, and a string keeps the pack readable in
    /// both TOML and JSON without a date dependency.
    pub added_at: String,
    /// What produced it (a conversation id, an onboarding screen). `None` when unknown.
    pub source: Option<String>,
}

// ===========================================================================
// Patterns
// ===========================================================================

/// One banned pattern: the compiled regex, and the source line it was written as.
///
/// BOTH, and the source line is the important half. The compiled regex is what matches; the
/// source is what a [`Hit`] names, what a regeneration request lists, and what an operator
/// recognises in their own file. A report that named a `Regex`'s `Display` would be naming
/// a normalisation of what they wrote.
///
/// Matching is CASE-INSENSITIVE by construction — the pattern is compiled with the `(?i)`
/// flag set through [`regex::RegexBuilder`], not by lowercasing the text, so a pattern that
/// itself contains a case-sensitive assertion still behaves as its author wrote it.
#[derive(Debug, Clone)]
pub struct Pattern {
    source: String,
    regex: regex::Regex,
}

impl Pattern {
    /// Compile one pattern line. The line is stored exactly as given, whitespace included at
    /// the ends only if the caller left it there.
    pub fn new(source: impl Into<String>) -> Result<Pattern, PatternError> {
        let source = source.into();
        let regex = regex::RegexBuilder::new(&source)
            .case_insensitive(true)
            .build()
            .map_err(|e| PatternError {
                source: source.clone(),
                message: first_line(&e.to_string()),
            })?;
        Ok(Pattern { source, regex })
    }

    /// The line the pattern was written as.
    pub fn source(&self) -> &str {
        &self.source
    }

    /// The compiled regex.
    pub fn regex(&self) -> &regex::Regex {
        &self.regex
    }
}

/// Two patterns are equal when their SOURCE lines are. A compiled `Regex` has no equality
/// of its own, and two patterns written the same way are the same rule.
impl PartialEq for Pattern {
    fn eq(&self, other: &Self) -> bool {
        self.source == other.source
    }
}

impl Eq for Pattern {}

/// A pattern serialises as its source STRING — the same one line the owner wrote — so a
/// pack round-trips through TOML and JSON as a plain array of strings.
impl Serialize for Pattern {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.source)
    }
}

impl<'de> Deserialize<'de> for Pattern {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Pattern, D::Error> {
        let s = String::deserialize(d)?;
        Pattern::new(s).map_err(|e| D::Error::custom(e.to_string()))
    }
}

/// A pattern line that would not compile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatternError {
    /// The line as written.
    pub source: String,
    /// Why it would not compile, as one line.
    pub message: String,
}

impl std::fmt::Display for PatternError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "pattern `{}` is not a valid regex: {}",
            self.source, self.message
        )
    }
}

impl std::error::Error for PatternError {}

/// The first line of a multi-line error, so a warning naming a bad pattern stays one line.
fn first_line(s: &str) -> String {
    s.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("invalid regex")
        .to_string()
}

// ===========================================================================
// The draft-lint file format
// ===========================================================================

/// One pattern line that failed to compile, with the 1-based line number it was on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatternFileWarning {
    /// The 1-based line number in the file.
    pub line: usize,
    /// What was wrong.
    pub error: PatternError,
}

impl std::fmt::Display for PatternFileWarning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}: {}", self.line, self.error)
    }
}

/// Parse a banned-pattern list in the `draft-lint` file format: one pattern per line, `#`
/// comments, blank lines ignored, everything else compiled case-insensitively.
///
/// **NEVER FAILS AS A WHOLE.** It returns the patterns that compiled AND a warning per line
/// that did not, because the alternative — refusing the file — means one typo silently
/// disarms every rule in it. The caller reports the warnings; the pack proceeds with the
/// lines that parsed.
///
/// The format is deliberately the one the `draft-lint` skill already uses, so an existing
/// list is pointed at rather than converted. A line is taken VERBATIM as a regex: leading
/// and trailing whitespace is trimmed (a trailing space in a word-boundary pattern is a
/// typo, never a rule), nothing else is rewritten.
pub fn parse_pattern_file(text: &str) -> (Vec<Pattern>, Vec<PatternFileWarning>) {
    let mut patterns = Vec::new();
    let mut warnings = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match Pattern::new(line) {
            Ok(p) => patterns.push(p),
            Err(error) => warnings.push(PatternFileWarning { line: i + 1, error }),
        }
    }
    (patterns, warnings)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_a_complete_generic_assistant() {
        let p = PersonaPack::default();
        assert_eq!(p.version, PACK_VERSION);
        assert_eq!(p.assistant.name, "Jesse");
        assert_eq!(p.owner.name, "the user");
        assert_eq!(p.owner.pronoun, "their");
        assert_eq!(p.formatting.dashes, Dashes::Forbidden);
        assert!(p.banned_patterns.is_empty());
        assert!(p.writing_samples.is_empty());
        assert!(p.corrections.is_empty());
        assert!(p.free_text.is_none());
    }

    #[test]
    fn pattern_file_keeps_what_parsed_and_warns_per_bad_line() {
        let (patterns, warnings) =
            parse_pattern_file("# a comment\n\n\\bdelve\\b\n[unclosed\n\\btapestry\\b\n   \n");
        assert_eq!(
            patterns.iter().map(Pattern::source).collect::<Vec<_>>(),
            vec!["\\bdelve\\b", "\\btapestry\\b"]
        );
        assert_eq!(warnings.len(), 1);
        assert_eq!(warnings[0].line, 4);
        assert_eq!(warnings[0].error.source, "[unclosed");
    }

    #[test]
    fn every_parameter_parses_from_the_spelling_its_config_uses() {
        use std::str::FromStr;
        assert_eq!(Formality::from_str(" HIGH "), Ok(Formality::High));
        assert_eq!(Humor::from_str("dry"), Ok(Humor::Dry));
        assert_eq!(Verbosity::from_str("terse"), Ok(Verbosity::Terse));
        assert_eq!(Emoji::from_str("sparingly"), Ok(Emoji::Sparingly));
        assert_eq!(Hedging::from_str("minimal"), Ok(Hedging::Minimal));
        assert_eq!(
            Questions::from_str("assume_and_state"),
            Ok(Questions::AssumeAndState)
        );
        assert_eq!(Lists::from_str("when_asked"), Ok(Lists::WhenAsked));
        assert_eq!(Headings::from_str("when_long"), Ok(Headings::WhenLong));
        assert_eq!(Dashes::from_str("forbidden"), Ok(Dashes::Forbidden));
        assert_eq!(AddressStyle::from_str("by_name"), Ok(AddressStyle::ByName));
        // A bad value names the valid ones rather than failing silently.
        let err = Dashes::from_str("banned").expect_err("refused");
        assert!(err.contains("forbidden, allowed"), "{err}");
    }

    /// The serde spelling and the `FromStr` spelling are the same word, on every parameter.
    #[test]
    fn the_serde_spelling_and_the_parsed_spelling_agree() {
        use std::str::FromStr;
        for (json, parsed) in [
            (r#""when_asked""#, Lists::WhenAsked),
            (r#""freely""#, Lists::Freely),
            (r#""avoid""#, Lists::Avoid),
        ] {
            let de: Lists = serde_json::from_str(json).expect("deserialises");
            assert_eq!(de, parsed);
            assert_eq!(Lists::from_str(json.trim_matches('"')), Ok(parsed));
        }
    }

    #[test]
    fn patterns_match_case_insensitively() {
        let p = Pattern::new("\\bdelve\\b").expect("compiles");
        assert!(p.regex().is_match("We Delve into it"));
        assert!(p.regex().is_match("delve"));
        assert!(!p.regex().is_match("delved"));
    }

    #[test]
    fn writing_samples_respect_the_byte_cap() {
        let mut p = PersonaPack::default();
        let big = WritingSample {
            title: "big".into(),
            text: "x".repeat(WRITING_SAMPLES_BYTE_CAP),
            source: None,
        };
        assert!(p.push_writing_sample(big));
        assert_eq!(p.writing_sample_bytes(), WRITING_SAMPLES_BYTE_CAP);
        let one_more = WritingSample {
            title: "one more".into(),
            text: "x".into(),
            source: None,
        };
        assert!(!p.push_writing_sample(one_more));
        assert_eq!(p.writing_samples.len(), 1);
    }

    #[test]
    fn without_content_drops_samples_and_free_text_and_nothing_else() {
        let mut p = fully_populated();
        let public = p.without_content();
        assert!(public.writing_samples.is_empty());
        assert!(public.free_text.is_none());
        // Everything else survives byte for byte.
        p.writing_samples.clear();
        p.free_text = None;
        assert_eq!(public, p);
    }

    #[test]
    fn round_trips_through_json() {
        let p = fully_populated();
        let json = serde_json::to_string(&p).expect("serialises");
        let back: PersonaPack = serde_json::from_str(&json).expect("deserialises");
        assert_eq!(back, p);
    }

    #[test]
    fn round_trips_through_toml() {
        let p = fully_populated();
        let text = toml::to_string(&p).expect("serialises");
        let back: PersonaPack = toml::from_str(&text).expect("deserialises");
        assert_eq!(back, p);
    }

    /// A pack written by the loader as a PARTIAL TOML table still loads: every field has a
    /// default, so a `[persona]` file that sets two keys is a complete pack.
    #[test]
    fn a_partial_document_fills_in_from_defaults() {
        let back: PersonaPack =
            toml::from_str("version = 1\n[owner]\nname = \"Alex\"\n").expect("deserialises");
        assert_eq!(back.owner.name, "Alex");
        assert_eq!(back.owner.pronoun, DEFAULT_OWNER_PRONOUN);
        assert_eq!(back.assistant.name, DEFAULT_ASSISTANT_NAME);
        assert_eq!(back.formatting.dashes, Dashes::Forbidden);
    }

    #[test]
    fn an_uncompilable_pattern_fails_deserialisation_by_name() {
        let err = serde_json::from_str::<PersonaPack>(r#"{"banned_patterns":["[unclosed"]}"#)
            .expect_err("refused");
        assert!(err.to_string().contains("[unclosed"), "{err}");
    }

    /// The fixture pack the render and check tests share: every field populated, and no
    /// text taken from anywhere but this file.
    pub(crate) fn fully_populated() -> PersonaPack {
        PersonaPack {
            version: PACK_VERSION,
            languages: vec!["en".into(), "it".into()],
            banned_patterns: vec![
                Pattern::new("\\bdelve\\b").unwrap(),
                Pattern::new("stands as a testament to").unwrap(),
            ],
            free_text: Some(
                "Answer the question I asked, not the one you wish I had asked.".into(),
            ),
            assistant: AssistantIdentity {
                name: "Ada".into(),
                self_description: Some("a research assistant for a working archive".into()),
            },
            owner: OwnerIdentity {
                name: "Alex Example".into(),
                pronoun: "their".into(),
                address_style: AddressStyle::ByName,
            },
            style: StyleParams {
                formality: Formality::Low,
                humor: Humor::Dry,
                verbosity: Verbosity::Terse,
                emoji: Emoji::Never,
                hedging: Hedging::Minimal,
                questions: Questions::AssumeAndState,
            },
            formatting: FormattingParams {
                lists: Lists::Avoid,
                headings: Headings::Avoid,
                dashes: Dashes::Forbidden,
            },
            writing_samples: vec![WritingSample {
                title: "A note about the archive".into(),
                text: "The archive is not a museum. Things in it get used, and the ones that \
                       stop being used get thrown away."
                    .into(),
                source: Some("fixture.md".into()),
            }],
            corrections: vec![Correction {
                rule: "always put the time in the subject line".into(),
                added_at: "2026-08-28T08:36:00Z".into(),
                source: Some("fixture".into()),
            }],
        }
    }
}
