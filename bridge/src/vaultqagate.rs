//! The **vault-QA gate** — the STRICT, deliberately-tight classifier that decides
//! whether an "Ask" turn should attempt the contained, read-only local vault-QA
//! child ([`vaultqa::run_vaultqa_pipeline`]) before falling back to the hosted
//! agent turn.
//!
//! Unlike the diet gate ([`dietgate`]), this one is TIGHT on purpose. The error
//! directions are NOT symmetric:
//!   * a **false negative** (a vault-answerable question the gate misses) is free —
//!     the hosted turn answers it exactly as today;
//!   * a **false positive** (a turn the gate catches but the vault can't answer, or
//!     that wanted an action) risks delivering a user-facing LOCAL answer. The
//!     ladder + the `NO_VAULT_ANSWER` escape ([`vaultqa`]) catch most of those, but
//!     the gate stays tight so they rarely arise in the first place.
//!
//! So the gate fires only for a message that is unmistakably a *self-referential
//! question about the user's own data* and is not action-shaped, not web-shaped,
//! not diet-shaped (diet keeps precedence), carries no attachment/image, and holds
//! no URL. The whole gate is inert unless a vault-QA backend is configured —
//! [`should_try_local_vaultqa`] ANDs in `cfg.vaultqa_backend.is_some()`, the kill
//! switch: unset the triple and every Ask takes the hosted path, byte-for-byte.

use crate::*;

/// STRONG (wh-) interrogative openers — unambiguous question words that count
/// wherever they appear. A bare `how` is intentionally NOT here — only the
/// `how much` / `how many` / `how long` bigrams qualify, so "how are you" doesn't
/// trip the gate.
const STRONG_INTERROGATIVES: &[&str] = &["what", "which", "when", "where", "who"];

/// WEAK (auxiliary) interrogatives — question words ONLY in subject-auxiliary
/// inversion (`did I…`, `is my…`, `have we…`). They form a question only when
/// immediately followed by a self-reference, so requiring that adjacency keeps them
/// in the allowlist (per the spec's token list) without firing on the many
/// statements that use them mid-sentence ("my flight IS at noon", "I DO yoga").
const WEAK_INTERROGATIVES: &[&str] = &["did", "do", "have", "am", "is"];

/// The `how <x>` bigrams that count as interrogatives (a quantity/duration ask).
const HOW_BIGRAMS: &[&str] = &["much", "many", "long"];

/// First-person / possessive tokens — the "about the user's own data" signal that,
/// together with an interrogative, is the allowlist.
const SELF_REFS: &[&str] = &["my", "i", "me", "mine", "we", "our"];

/// Action verbs — a "Tell"-shaped ask that wants work done, not a lookup. Their
/// presence excludes the turn (it belongs on the hosted path that can act).
const ACT_VERBS: &[&str] = &[
    "log", "add", "draft", "write", "send", "reply", "update", "schedule", "remind", "create",
    "fix", "buy",
];

/// Web-shaped verbs — the answer lives on the internet, not the vault, so the local
/// read-only child cannot serve it. Excluded.
const WEB_VERBS: &[&str] = &["search", "research", "browse", "fetch", "news", "weather"];

/// SYNTHESIS-shaped verbs (gate v2, Piece 1) — a question that wants judgment,
/// advice, comparison, or a plan, not a fact lookup. The vaultqa-v1 bake-off showed
/// the hosted model winning EVERY judged synthesis pair while both locals scored
/// 100% on lookups, so a synthesis-shaped Ask belongs on the hosted path. The error
/// directions stay asymmetric: excluding one of these is FREE (hosted answers it
/// exactly as today), whereas letting it through would route a synthesis question to
/// a lookup-only local model and deliver a WORSE user-facing answer. The `should I` /
/// `what should` bigrams are matched separately (they are phrases, not single tokens).
const SYNTHESIS_VERBS: &[&str] = &[
    "advise",
    "advice",
    "suggest",
    "recommend",
    "review",
    "summarize",
    "summary",
    "compare",
    "analyze",
    "plan",
    "brainstorm",
    "improve",
    "rank",
];

/// URL scheme / host markers. Any of these substrings (case-folded) means the
/// message references a URL, which a vault lookup cannot answer — excluded.
const URL_MARKERS: &[&str] = &["http://", "https://", "www.", "://"];

/// Bare-domain TLDs used to catch a URL written without a scheme (`bank.com`).
const URL_TLDS: &[&str] = &[
    "com", "org", "net", "io", "dev", "ai", "co", "app", "xyz", "gov", "edu",
];

/// Tokenize into lowercased alphanumeric words (unicode-aware), preserving order so
/// the `how <x>` bigram can be detected. Whole-token matching, never substring.
fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect()
}

/// Whether the raw message references a URL: a scheme/`www.` marker, or a bare
/// `label.tld` token whose suffix is a known TLD.
fn contains_url(text: &str) -> bool {
    let lower = text.to_lowercase();
    if URL_MARKERS.iter().any(|m| lower.contains(m)) {
        return true;
    }
    // Bare domain (no scheme): a whitespace-delimited token `something.tld`.
    lower.split_whitespace().any(|tok| {
        // Trim surrounding punctuation so `bank.com,` still matches.
        let tok = tok.trim_matches(|c: char| !c.is_alphanumeric());
        match tok.rsplit_once('.') {
            Some((label, tld)) => {
                !label.is_empty()
                    && label.chars().all(|c| c.is_alphanumeric() || c == '.')
                    && URL_TLDS.contains(&tld)
            }
            None => false,
        }
    })
}

/// Whether the message contains an interrogative opener: a strong wh-word anywhere,
/// a `how much/many/long` bigram, or a weak auxiliary in inversion (immediately
/// followed by a self-reference).
fn has_interrogative(toks: &[String]) -> bool {
    if toks
        .iter()
        .any(|t| STRONG_INTERROGATIVES.contains(&t.as_str()))
    {
        return true;
    }
    if toks
        .windows(2)
        .any(|w| w[0] == "how" && HOW_BIGRAMS.contains(&w[1].as_str()))
    {
        return true;
    }
    // Weak auxiliary + self-reference (subject-auxiliary inversion), e.g. "did I",
    // "is my", "have we" — the only form in which these read as a question.
    toks.windows(2)
        .any(|w| WEAK_INTERROGATIVES.contains(&w[0].as_str()) && SELF_REFS.contains(&w[1].as_str()))
}

/// The strict question allowlist + exclusions, over the RAW message (pure, so it is
/// table-tested). Fires only when ALL hold:
///   * an interrogative opener is present, AND
///   * a self-reference token is present ("about my own data"), AND
///   * no act verb (log/add/draft/…), no web verb (search/browse/news/…), no
///     SYNTHESIS verb (advise/suggest/recommend/review/compare/plan/… or the
///     `should I` / `what should` bigrams — gate v2, Piece 1), and
///   * the message is not diet-gate-shaped (diet keeps precedence —
///     [`dietgate::diet_intent`]), and
///   * the message holds no URL.
///
/// A false negative here is free (the hosted turn answers as today); a false
/// positive delivers a user-facing LOCAL answer, so this stays tight and the ladder
/// + the `NO_VAULT_ANSWER` escape carry the rest.
pub fn vaultqa_question_gate(text: &str) -> bool {
    if contains_url(text) {
        return false;
    }
    // Diet keeps precedence: anything diet-gate-shaped is never a vault-QA turn.
    // Uses the ENGLISH baseline only (empty extras): the vault-QA gate additionally
    // requires an English interrogative + self-reference, which a non-English diet
    // ask can't satisfy anyway, so the deployment's extra vocabulary is not needed
    // here — the Tell-path diet gate ([`should_try_local_diet`]) honors it in full.
    if diet_intent(text, &[]) {
        return false;
    }
    let toks = words(text);
    // Exclusions first (act/web verbs) — cheap and decisive.
    if toks.iter().any(|t| ACT_VERBS.contains(&t.as_str())) {
        return false;
    }
    if toks.iter().any(|t| WEB_VERBS.contains(&t.as_str())) {
        return false;
    }
    // "look up" is a two-word web verb the single-token pass above misses.
    if toks.windows(2).any(|w| w[0] == "look" && w[1] == "up") {
        return false;
    }
    // Gate v2 (Piece 1): synthesis-shaped asks belong on the hosted path — a
    // single synthesis verb, or the `should I` / `what should` bigrams, excludes.
    if toks.iter().any(|t| SYNTHESIS_VERBS.contains(&t.as_str())) {
        return false;
    }
    if toks
        .windows(2)
        .any(|w| (w[0] == "should" && w[1] == "i") || (w[0] == "what" && w[1] == "should"))
    {
        return false;
    }
    // Allowlist: an interrogative AND a self-reference, both present.
    has_interrogative(&toks) && toks.iter().any(|t| SELF_REFS.contains(&t.as_str()))
}

/// The handler-boundary decision, INCLUDING the kill switch: attempt the local
/// vault-QA child only when a vault-QA backend is configured AND the turn is an
/// `ask` AND it carries no attachment/image payload AND the strict question gate
/// fires. With no backend this is always `false`, so every Ask takes today's hosted
/// path byte-for-byte — the seam is the kill switch. `has_attachment` is the
/// caller's `!req.attachments.is_empty()` (an image/file turn wants the multimodal
/// hosted agent, and the read-only child can't see the scratch files anyway).
pub fn should_try_local_vaultqa(
    cfg: &Config,
    mode: &str,
    text: &str,
    has_attachment: bool,
) -> bool {
    cfg.vaultqa_backend.is_some()
        && mode.trim().eq_ignore_ascii_case("ask")
        && !has_attachment
        && vaultqa_question_gate(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    // Self-referential questions the vault could answer — deliberately avoiding any
    // diet-keyword token (those belong to the diet gate) and any act/web/URL shape.
    const HITS: &[&str] = &[
        "what is my VO2 max lately",
        "when is my next dentist appointment",
        "how many days until my trip",
        "did I finish the Q3 report",
        "where do I keep the router password",
        "how long have I been tracking this project",
        "am I free on Friday",
        "which of my accounts has the annual fee",
        "who is my emergency contact",
    ];

    // Must NOT fire: no self-ref, no interrogative, act-shaped, web-shaped, URL, or
    // diet-shaped (diet precedence).
    const MISSES: &[&str] = &[
        // no self-reference
        "what is the capital of France",
        // interrogative-less
        "summarize the meeting notes",
        // bare "how" is not an interrogative here
        "how are you today",
        // act verbs
        "remind me to call Bob tomorrow",
        "update my notes about the project",
        "draft an email to the team",
        "log my run",
        // web verbs
        "search the web for the best router",
        "look up the news for me",
        "what's the weather where I am",
        // URL
        "what is my balance at www.bank.com",
        "did I bookmark https://example.com/page",
        // diet-shaped (diet keeps precedence)
        "how many calories have I logged today",
        "what did I eat for lunch",
    ];

    // Gate v2 (Piece 1): SYNTHESIS-shaped self-referential questions the gate must
    // now REFUSE. Each is a textbook interrogative + self-reference (so the v1 gate
    // fired on it) that also carries a synthesis token (advise/suggest/recommend/
    // review/compare/analyze/plan/rank/improve/"should I"/"what should"). Routing
    // these to a lookup-only local model delivers a worse answer than the hosted
    // agent; a false negative here is free (hosted answers as today), a false
    // positive is user-facing, so lookups-only stays tight. The last two are the
    // prompt's examples (also diet-shaped, so doubly excluded).
    const SYNTH_MISSES: &[&str] = &[
        "what should I focus on in my project",
        "which of my tasks should I prioritize",
        "what do you suggest for my weekend plans",
        "how many of my notes should I review first",
        "which of my accounts do you recommend I close",
        "what should I do about my overdue project",
        "review my recent diet entries and suggest fiber changes",
        "what should I eat before tomorrow's run",
    ];

    #[test]
    fn gate_v2_excludes_synthesis_shaped_questions() {
        for u in SYNTH_MISSES {
            assert!(
                !vaultqa_question_gate(u),
                "gate v2 must NOT fire on a synthesis-shaped question: {u:?}"
            );
        }
    }

    #[test]
    fn gate_v2_still_fires_on_plain_lookups() {
        // The v1 positives must still fire — the synthesis exclusion narrows the gate,
        // it does not close it. A shoe-size lookup (the prompt's canonical example, but
        // with the diet keyword "running" dropped — see the note below) still fires.
        assert!(vaultqa_question_gate("what size were my last shoes"));
        for u in HITS {
            assert!(
                vaultqa_question_gate(u),
                "plain lookup must still fire: {u:?}"
            );
        }
    }

    #[test]
    fn diet_precedence_owns_running_shoes_lookup_not_the_synthesis_exclusion() {
        // NOTE: the prompt's illustrative positive "what size were my last running
        // shoes" does NOT fire — but for a PRE-EXISTING reason, not gate v2: "running"
        // is a diet keyword, so diet_intent claims it and diet keeps precedence. This
        // pins that behavior so a future reader doesn't mistake it for the synthesis
        // exclusion. The diet-free form ("... my last shoes") fires (asserted above).
        assert!(diet_intent("what size were my last running shoes", &[]));
        assert!(!vaultqa_question_gate(
            "what size were my last running shoes"
        ));
    }

    #[test]
    fn gate_fires_on_self_referential_questions() {
        for u in HITS {
            assert!(
                vaultqa_question_gate(u),
                "should fire the vault-QA gate: {u:?}"
            );
        }
    }

    #[test]
    fn gate_rejects_non_questions_actions_web_url_and_diet() {
        for u in MISSES {
            assert!(
                !vaultqa_question_gate(u),
                "should NOT fire the vault-QA gate: {u:?}"
            );
        }
    }

    #[test]
    fn allowlist_requires_both_interrogative_and_self_reference() {
        // Interrogative but no self-ref → miss.
        assert!(!vaultqa_question_gate("what time does the store close"));
        // Self-ref but no interrogative → miss.
        assert!(!vaultqa_question_gate("my flight is at noon"));
        // Both present → hit.
        assert!(vaultqa_question_gate("what time is my flight"));
    }

    #[test]
    fn how_bigrams_qualify_but_bare_how_does_not() {
        assert!(vaultqa_question_gate("how much did I spend on my card"));
        assert!(vaultqa_question_gate("how long is my commute"));
        assert!(
            !vaultqa_question_gate("how do you feel"),
            "bare 'how' + no self-ref"
        );
    }

    #[test]
    fn url_forms_are_excluded() {
        assert!(contains_url("see https://example.com"));
        assert!(contains_url("go to www.bank.com now"));
        assert!(contains_url("visit bank.com for details"));
        assert!(contains_url("ssh me at host://x"));
        assert!(!contains_url("what is my vo2 max"));
        assert!(!contains_url("the meeting is at 3.30 pm"));
    }

    #[test]
    fn kill_switch_no_backend_never_tries_vaultqa() {
        // With no backend configured, should_try_local_vaultqa is always false even
        // for a textbook self-referential Ask — the kill switch.
        let mut cfg = test_config();
        assert!(cfg.vaultqa_backend.is_none());
        assert!(
            !should_try_local_vaultqa(&cfg, "ask", "what is my VO2 max", false),
            "no backend → never attempt the local vault-QA child (kill switch)"
        );
        // With a backend AND a qualifying Ask → attempt it.
        cfg.vaultqa_backend = Some(("http://u".into(), "tok".into(), "m".into()));
        assert!(should_try_local_vaultqa(
            &cfg,
            "ask",
            "what is my VO2 max",
            false
        ));
        // Tell mode never fires the vault-QA gate (diet owns Tell).
        assert!(!should_try_local_vaultqa(
            &cfg,
            "tell",
            "what is my VO2 max",
            false
        ));
        // An attachment/image turn is excluded (wants the multimodal hosted agent).
        assert!(!should_try_local_vaultqa(
            &cfg,
            "ask",
            "what is my VO2 max",
            true
        ));
        // A non-question Ask doesn't fire.
        assert!(!should_try_local_vaultqa(
            &cfg,
            "ask",
            "summarize the notes",
            false
        ));
    }
}
