//! The **diet gate** — the loose, deliberately-permissive classifier that decides
//! whether a "Tell" turn should attempt the local diet-logging pipeline
//! ([`dietlog::run_diet_pipeline`]) before falling back to the hosted agent turn.
//!
//! By design the gate is LOOSE and both error directions are safe:
//!   * a **false negative** (a diet log the gate misses) just takes today's hosted
//!     path — the same behavior as before this feature;
//!   * a **false positive** (a non-diet Tell the gate catches) runs the extract
//!     child, which returns `no_loggable_content`, and the pipeline falls through to
//!     the hosted path (ladder rung 2).
//!
//! So the gate only needs to be roughly right. It fires on `mode == tell` plus a
//! keyword match over the raw message covering food/meal/exercise/weight vocabulary.
//! The shipped baseline is ENGLISH-only and generic; a deployment adds its own
//! vocabulary (another language, personal food names) via `[persona]
//! diet_keywords_extra` in `jesse.local.toml`, merged into the gate at load — so no
//! personal or non-English term lives in tracked source. Whole-token matching (not
//! substring) avoids catching `escalate` for `ate` or `weather` for `eat`.
//!
//! The whole gate is inert unless a diet backend is configured — [`should_try_local_diet`]
//! ANDs in `cfg.diet_backend.is_some()`, which is the kill switch: unset the triple
//! and every Tell takes the hosted path, byte-for-byte as today.

use crate::*;

/// Diet-intent keywords (whole tokens, lowercased) — the ENGLISH-ONLY generic
/// baseline for food, meals, exercise, and weigh-ins. Deliberately broad — a false
/// positive is a safe, cheap fall-through — but not so broad it catches every
/// message (generic words like "had"/"today" are left out on purpose). Any
/// non-English or personal vocabulary is supplied per-deployment via
/// `persona.diet_keywords_extra` and merged in [`diet_intent`], never hardcoded here.
const DIET_KEYWORDS: &[&str] = &[
    // logging verbs / nouns (EN)
    "log",
    "logged",
    "logging",
    // "track" is as common an English logging verb as "log" and was missing:
    // across 203 real turns it accounted for 8 of the 16 logging turns the gate
    // failed to catch — the bare imperative with a weight-and-food object, e.g.
    // "track 30g of walnuts" — each of which silently took the hosted path
    // instead of the local ladder.
    //
    // The BARE imperative only — deliberately not "tracked"/"tracking". Every one
    // of those 36 real diet uses is "track"; the inflected forms overwhelmingly
    // appear in non-diet senses (asking how long something has been tracked, or
    // saying a past turn tracked something wrong), and since the vault-QA gate
    // yields to diet intent
    // (vaultqagate.rs:164), matching them would hijack ordinary vault questions.
    "track",
    "ate",
    "eat",
    "eating",
    "eaten",
    "drank",
    "drink",
    "drinking",
    "food",
    "meal",
    "meals",
    "snack",
    "snacked",
    "breakfast",
    "lunch",
    "dinner",
    "brunch",
    // macros / calories (EN)
    "calorie",
    "calories",
    "kcal",
    "cal",
    "cals",
    "protein",
    "carbs",
    "carb",
    "fat",
    "fats",
    "fiber",
    "fibre",
    "macros",
    // exercise (EN)
    "ran",
    "run",
    "running",
    "jog",
    "jogged",
    "walk",
    "walked",
    "walking",
    "swim",
    "swam",
    "swimming",
    "bike",
    "biked",
    "biking",
    "ride",
    "rode",
    "cycle",
    "cycling",
    "cycled",
    "hike",
    "hiked",
    "hiking",
    "workout",
    "lift",
    "lifted",
    "lifting",
    "gym",
    "strength",
    "cardio",
    // weigh-ins (EN)
    "weigh",
    "weighed",
    "weighing",
    "weight",
    "lbs",
    "kg",
    // common logged foods/drinks (EN)
    "banana",
    "coffee",
    "espresso",
    "eggs",
    "egg",
    "yogurt",
    "oatmeal",
    "salad",
    "shake",
];

/// Whether the message shows diet-logging intent: any whole token matches the
/// English [`DIET_KEYWORDS`] baseline OR the per-deployment `extra` set (persona
/// `diet_keywords_extra`, already lowercased at config load). Whole-token (not
/// substring) so `escalate` never matches `ate`. Loose by design — a false positive
/// is a safe, cheap fall-through. `extra` is empty on a fresh clone, so the baseline
/// behavior is unchanged unless a local config adds vocabulary.
pub fn diet_intent(text: &str, extra: &[String]) -> bool {
    tokens(text).iter().any(|t| {
        DIET_KEYWORDS.contains(&t.as_str()) || extra.iter().any(|e| e == t)
    })
}

/// Tokenize into lowercased alphanumeric words (unicode-aware), so keyword matching
/// is whole-token, not substring. Kept private; [`diet_intent`] is the surface.
fn tokens(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect()
}

/// Whether the diet gate fires for this turn: `mode == tell` AND the message shows
/// diet intent (baseline + `extra`). `mode` is normalized (trim + lowercase)
/// defensively, though the handler already lowercases it.
pub fn diet_gate_matches(mode: &str, text: &str, extra: &[String]) -> bool {
    mode.trim().eq_ignore_ascii_case("tell") && diet_intent(text, extra)
}

/// The handler-boundary decision, INCLUDING the kill switch: attempt the local diet
/// pipeline only when a diet backend is configured AND the gate fires (over the
/// English baseline plus the deployment's `persona.diet_keywords_extra`). With no
/// backend this is always `false`, so every Tell takes today's hosted path
/// byte-for-byte — the seam is the kill switch.
pub fn should_try_local_diet(cfg: &Config, mode: &str, text: &str) -> bool {
    cfg.diet_backend.is_some()
        && diet_gate_matches(mode, text, &cfg.persona.diet_keywords_extra)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    // Synthetic, generic English diet utterances the baseline gate must catch.
    const HITS: &[&str] = &[
        "logged a banana",
        "I ate eggs and toast",
        "had 2 eggs for breakfast, about 200 kcal",
        "ran 8k this morning, avg HR 145",
        "went for a 5 mile walk",
        "weighed 189 this morning",
        "I'm 90 kg today",
        "swam 1500m at the pool",
        "protein shake after the gym",
        "coffee and oatmeal",
        "biked 20 miles and logged the calories",
        "salad and a yogurt for lunch",
        // "track" phrasings — the most common real logging verb in production and
        // the single biggest gate gap before it was added. Bare-noun objects here
        // on purpose: the verb alone must carry the match.
        "Track 30g of walnuts.",
        "Now track 85g of raw celery",
        "Track my recent exercise. I was clearing brush in the yard.",
    ];

    // Non-diet uses of the "track" family that must NOT be hijacked. The bare verb
    // is a diet keyword; its inflected forms are not, precisely so these keep
    // reaching the vault-QA path (which yields to diet intent).
    const TRACK_NON_DIET: &[&str] = &[
        "how long have I been tracking this project",
        "you tracked that number wrong earlier",
    ];

    // Non-diet Tells that must NOT fire the gate.
    const MISSES: &[&str] = &[
        "remind me to call Bob tomorrow",
        "summarize the meeting notes",
        "what's on my calendar today",
        "draft an email to the team about the release",
        "escalate the incident to on-call", // 'escalate' must not match 'ate'
        "the weather looks clear this weekend", // 'weather' must not match 'eat'
        "update the project status",
    ];

    // No extra vocabulary (a fresh clone) — the English baseline alone.
    const NO_EXTRA: &[String] = &[];

    #[test]
    fn gate_fires_on_real_diet_utterances() {
        for u in HITS {
            assert!(diet_intent(u, NO_EXTRA), "should detect diet intent: {u:?}");
        }
    }

    #[test]
    fn gate_ignores_non_diet_tells() {
        for u in MISSES {
            assert!(!diet_intent(u, NO_EXTRA), "should NOT detect diet intent: {u:?}");
        }
    }

    #[test]
    fn inflected_track_forms_stay_out_of_the_gate() {
        for u in TRACK_NON_DIET {
            assert!(
                !diet_intent(u, NO_EXTRA),
                "inflected 'track' must not claim a non-diet Tell (the vault-QA gate \
                 yields to diet intent, so this would hijack it): {u:?}"
            );
        }
    }

    #[test]
    fn whole_token_matching_avoids_substring_false_positives() {
        // 'ate' is a keyword, but 'escalate'/'plate'/'later' contain it and must not
        // match; likewise 'eat' inside 'weather'/'theater'.
        assert!(!diet_intent("please escalate this and update later", NO_EXTRA));
        assert!(!diet_intent("the theater weather was fine", NO_EXTRA));
        // The bare keyword as its own word does match.
        assert!(diet_intent("I ate lunch", NO_EXTRA));
    }

    #[test]
    fn extra_keywords_merge_into_the_gate() {
        // A deployment's `persona.diet_keywords_extra` extends the English baseline.
        // Non-English / personal vocabulary lives here as DATA, never in the const.
        let extra: Vec<String> = ["colazione", "pranzo", "tacos"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // Baseline misses these (they are not English keywords)…
        assert!(!diet_intent("pranzo veloce oggi", NO_EXTRA));
        assert!(!diet_intent("solo una colazione leggera", NO_EXTRA));
        // …but with the extras merged in, they fire (whole-token, case-insensitive).
        assert!(diet_intent("pranzo veloce oggi", &extra));
        assert!(diet_intent("solo una colazione leggera", &extra));
        assert!(!diet_intent("just Tacos please", NO_EXTRA)); // baseline misses it
        assert!(diet_intent("just Tacos please", &extra)); // extra catches it
        // A word not in baseline or extras still misses (whole-token, no substring).
        assert!(!diet_intent("pranzoni enormi", &extra)); // 'pranzoni' != 'pranzo'
    }

    #[test]
    fn gate_requires_tell_mode() {
        assert!(diet_gate_matches("tell", "logged a banana", NO_EXTRA));
        assert!(diet_gate_matches("TELL", "logged a banana", NO_EXTRA));
        // Ask never fires the diet gate, even on a diet-shaped message.
        assert!(!diet_gate_matches("ask", "logged a banana", NO_EXTRA));
        // A non-diet Tell doesn't fire.
        assert!(!diet_gate_matches("tell", "summarize the notes", NO_EXTRA));
    }

    #[test]
    fn kill_switch_no_backend_never_tries_local_diet() {
        // The whole point: with no diet backend configured, should_try_local_diet is
        // always false, so a diet-shaped Tell still takes the hosted path.
        let mut cfg = test_config();
        assert!(cfg.diet_backend.is_none());
        assert!(
            !should_try_local_diet(&cfg, "tell", "logged a banana"),
            "no backend → never attempt the local pipeline (kill switch)"
        );
        // With a backend AND a diet Tell → attempt it.
        cfg.diet_backend = Some(("http://u".into(), "tok".into(), "m".into()));
        assert!(should_try_local_diet(&cfg, "tell", "logged a banana"));
        // Backend set but Ask, or a non-diet Tell → don't attempt.
        assert!(!should_try_local_diet(&cfg, "ask", "logged a banana"));
        assert!(!should_try_local_diet(&cfg, "tell", "summarize the notes"));
        // A non-English utterance misses the English baseline…
        assert!(!should_try_local_diet(&cfg, "tell", "pranzo veloce oggi"));
        // …until the deployment supplies the vocabulary via persona (config data).
        cfg.persona.diet_keywords_extra = vec!["pranzo".into(), "colazione".into()];
        assert!(should_try_local_diet(&cfg, "tell", "pranzo veloce oggi"));
    }
}
