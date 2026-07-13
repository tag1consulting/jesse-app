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
//! keyword match over the raw message covering food/meal/exercise/weight vocabulary
//! in the English and Italian forms Jeremy actually uses. Whole-token matching (not
//! substring) avoids catching `escalate` for `ate` or `weather` for `eat`.
//!
//! The whole gate is inert unless a diet backend is configured — [`should_try_local_diet`]
//! ANDs in `cfg.diet_backend.is_some()`, which is the kill switch: unset the triple
//! and every Tell takes the hosted path, byte-for-byte as today.

use crate::*;

/// Diet-intent keywords (whole tokens, lowercased). English + the Italian terms
/// Jeremy uses for food, meals, exercise, and weigh-ins. Deliberately broad — a
/// false positive is a safe, cheap fall-through — but not so broad it catches every
/// message (generic words like "had"/"today" are left out on purpose).
const DIET_KEYWORDS: &[&str] = &[
    // logging verbs / nouns (EN)
    "log", "logged", "logging",
    "ate", "eat", "eating", "eaten", "drank", "drink", "drinking",
    "food", "meal", "meals", "snack", "snacked",
    "breakfast", "lunch", "dinner", "brunch",
    // macros / calories (EN)
    "calorie", "calories", "kcal", "cal", "cals", "protein", "carbs", "carb",
    "fat", "fats", "fiber", "fibre", "macros",
    // exercise (EN)
    "ran", "run", "running", "jog", "jogged", "walk", "walked", "walking",
    "swim", "swam", "swimming", "bike", "biked", "biking", "ride", "rode",
    "cycle", "cycling", "cycled", "hike", "hiked", "hiking", "workout",
    "lift", "lifted", "lifting", "gym", "strength", "cardio",
    // weigh-ins (EN)
    "weigh", "weighed", "weighing", "weight", "lbs", "kg",
    // common logged foods/drinks (EN)
    "banana", "coffee", "espresso", "eggs", "egg", "yogurt", "oatmeal",
    "salad", "shake",
    // Italian — food / meals
    "mangiato", "mangiare", "mangio", "bevuto", "bere", "bevo",
    "colazione", "pranzo", "cena", "spuntino", "merenda", "cibo", "pasto",
    // Italian — macros
    "proteine", "carboidrati", "grassi", "fibre", "calorie",
    // Italian — exercise
    "corsa", "corso", "camminata", "camminato", "nuotato", "nuoto",
    "bici", "bicicletta", "palestra", "allenamento",
    // Italian — weigh-ins / common foods
    "peso", "pesato", "pesare", "caffè", "caffe", "acqua",
    "uova", "uovo", "pane", "insalata", "banane",
];

/// Whether the message shows diet-logging intent: any whole token matches the
/// [`DIET_KEYWORDS`] set. Whole-token (not substring) so `escalate` never matches
/// `ate`. Loose by design — a false positive is a safe, cheap fall-through.
pub fn diet_intent(text: &str) -> bool {
    tokens(text).iter().any(|t| DIET_KEYWORDS.contains(&t.as_str()))
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
/// diet intent. `mode` is normalized (trim + lowercase) defensively, though the
/// handler already lowercases it.
pub fn diet_gate_matches(mode: &str, text: &str) -> bool {
    mode.trim().eq_ignore_ascii_case("tell") && diet_intent(text)
}

/// The handler-boundary decision, INCLUDING the kill switch: attempt the local diet
/// pipeline only when a diet backend is configured AND the gate fires. With no
/// backend this is always `false`, so every Tell takes today's hosted path
/// byte-for-byte — the seam is the kill switch.
pub fn should_try_local_diet(cfg: &Config, mode: &str, text: &str) -> bool {
    cfg.diet_backend.is_some() && diet_gate_matches(mode, text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    // Real utterance shapes Jeremy logs (EN + IT).
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
        // Italian
        "ho mangiato una banana a colazione",
        "corsa di 8km stamattina",
        "pesato 90 kg stamattina",
        "caffè e pane a colazione",
        "pranzo: insalata e uova",
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

    #[test]
    fn gate_fires_on_real_diet_utterances() {
        for u in HITS {
            assert!(diet_intent(u), "should detect diet intent: {u:?}");
        }
    }

    #[test]
    fn gate_ignores_non_diet_tells() {
        for u in MISSES {
            assert!(!diet_intent(u), "should NOT detect diet intent: {u:?}");
        }
    }

    #[test]
    fn whole_token_matching_avoids_substring_false_positives() {
        // 'ate' is a keyword, but 'escalate'/'plate'/'later' contain it and must not
        // match; likewise 'eat' inside 'weather'/'theater'.
        assert!(!diet_intent("please escalate this and update later"));
        assert!(!diet_intent("the theater weather was fine"));
        // The bare keyword as its own word does match.
        assert!(diet_intent("I ate lunch"));
    }

    #[test]
    fn gate_requires_tell_mode() {
        assert!(diet_gate_matches("tell", "logged a banana"));
        assert!(diet_gate_matches("TELL", "logged a banana"));
        // Ask never fires the diet gate, even on a diet-shaped message.
        assert!(!diet_gate_matches("ask", "logged a banana"));
        // A non-diet Tell doesn't fire.
        assert!(!diet_gate_matches("tell", "summarize the notes"));
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
    }
}
