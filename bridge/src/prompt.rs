use crate::*;

// ---- Prompt wrappers — the ONLY difference between Ask and Tell ------------
//
// "Ask" means don't take ACTION he didn't request — NOT "don't write".
// Recording a durable fact that surfaces is never an action; it's the standing
// CLAUDE.md rule and must happen in every mode, or facts surfaced mid-thread
// are lost when the session ages out (the thread is not the vault).

// The non-negotiable safety floor for ASK turns. `build_prompt` ALWAYS prepends
// this — even when the user supplies a custom wrapper override. A customized
// wrapper changes the *framing*, never this clause. Mirrors CLAUDE.md: an Ask is
// a question, so don't take unrequested action; but a surfaced durable fact is
// always recorded. The app shows this read-only so users don't re-type a weaker
// variant inside their own wrapper.
pub const ASK_FLOOR: &str = "Don't do task-work he didn't ask for — no new drafts, \
TODOs, or edits to act on something. BUT if this exchange surfaces a durable \
fact, correction, or status change, record it to the right vault file \
immediately per CLAUDE.md — that is never optional and never needs his \
permission.";

// The non-negotiable floor for TELL turns: durable-fact capture is always on,
// even under a custom wrapper. (Tell already means "act", so there is no
// no-unrequested-action clause — only the universal record-facts invariant.)
//
// The second sentence is the diet-cache reinforcement: `diet-today.js` is a
// DERIVED cache, and the headless one-shot agent otherwise tends to hand-edit it
// (the stale-cache bug class — a phone log left it `meals: []`). It is self-gated
// ("When the fact is a food/exercise/weigh-in log…"), so it is a no-op on every
// other Tell. The three `node …` commands are exactly the scopes granted in
// DEFAULT_ALLOWED_TOOLS; CLAUDE.md's Diet-Logging-Flow owns the full procedure —
// this only reinforces it so it happens on the phone path every time.
pub const TELL_FLOOR: &str = "Record any durable fact, correction, or status change \
to the right vault file immediately per CLAUDE.md — that is never optional and \
never needs his permission. When the fact is a food, exercise, or weigh-in log, \
`todo-list/diet-today.js` is a DERIVED cache: after appending the CSV row(s), \
regenerate it by running `node todo-list/generate-diet-today.js`, then verify \
with `node todo-list/validate-diet-today.js` and \
`node todo-list/verify-diet-consistency.js` — never hand-edit the meals, weight, \
or exercise data into it.";

// Editable wrappers (the framing the app's Settings can override). The fixed
// floor above is prepended separately and is NOT part of this text, so a custom
// override cannot drop it.
pub const ASK_PREAMBLE: &str = "Jeremy is ASKING you a question from his phone. \
Answer concisely and directly; read the vault as needed. Keep the answer short \
enough to read on a phone screen.\n\nQuestion: ";

pub const TELL_PREAMBLE: &str = "Jeremy is TELLING you something from his phone — a \
fact, an instruction, or something to capture. Act on it per CLAUDE.md: log it, \
file it, or update the vault as appropriate. Reply with a one or two sentence \
confirmation of what you did.\n\nMessage: ";

// On a resumed thread the framing is already established — keep it light. The
// record-facts invariant now lives in the always-applied floor, so the followup
// wrappers no longer restate it.
pub const ASK_FOLLOWUP: &str = "Jeremy follows up (still asking, keep it short): ";

pub const TELL_FOLLOWUP: &str = "Jeremy follows up (capture/act per CLAUDE.md): ";

// Appended when the request arrived by voice — the reply will be read aloud, so
// we ask Jesse to end with a plain-prose SPOKEN: line the app can hand to TTS.
pub const VOICE_SUFFIX: &str = "\n\n(This request came in by voice and the reply will \
be read aloud. Keep it concise and listenable. After your full answer, add a final \
line beginning exactly with 'SPOKEN: ' containing a one- or two-sentence spoken \
summary for text-to-speech — plain prose, no markdown, no lists, no URLs.)";

// Appended to non-voice prompts so replies stay readable on a narrow phone
// screen. Mutually exclusive with VOICE_SUFFIX (voice forbids markdown entirely).
pub const PHONE_FORMAT: &str = "\n\n(Formatting: this reply is shown on a narrow phone \
screen. Prefer short paragraphs and bullet lists. Use Markdown. If a table is the \
clearest form, keep it to 2–3 narrow columns; otherwise avoid tables.)";

/// Wrap the user's text in the active mode's instruction, then append the
/// voice or phone-format suffix. `mode` (validated here) selects Ask vs Tell and
/// fresh vs followup. The mode's safety floor is ALWAYS prepended; a non-empty
/// `floor_override` customizes only its *wording* (blank/absent falls back to the
/// built-in const, so there is never a turn with no floor at all). A non-empty
/// `instructions` override replaces only the built-in *wrapper* that follows the
/// floor. The suffix is still appended regardless, so the bridge always owns the
/// floor and voice/phone formatting. With both overrides absent or blank the
/// output is byte-identical to the const-only path.
pub fn build_prompt(
    mode: &str,
    text: &str,
    is_followup: bool,
    voice: bool,
    instructions: Option<&str>,
    floor_override: Option<&str>,
) -> Result<String, ApiError> {
    // Validate the mode and pick both the built-in wrapper and the default floor —
    // an unknown mode is still a 400, override or not.
    let (default_preamble, default_floor) = match (mode, is_followup) {
        ("ask", false) => (ASK_PREAMBLE, ASK_FLOOR),
        ("ask", true) => (ASK_FOLLOWUP, ASK_FLOOR),
        ("tell", false) => (TELL_PREAMBLE, TELL_FLOOR),
        ("tell", true) => (TELL_FOLLOWUP, TELL_FLOOR),
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Unknown mode: {mode:?} (use 'ask' or 'tell')"),
            ))
        }
    };
    let preamble = match instructions {
        Some(s) if !s.trim().is_empty() => s,
        _ => default_preamble,
    };
    // The floor still LEADS every turn. An override changes only its wording;
    // blank/absent falls back to the built-in const, so there is never a turn
    // with no floor at all.
    let floor = match floor_override {
        Some(s) if !s.trim().is_empty() => s,
        _ => default_floor,
    };
    let mut p = format!("{floor}\n\n{preamble}{text}");
    if voice {
        p.push_str(VOICE_SUFFIX);
    } else {
        p.push_str(PHONE_FORMAT);
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn build_prompt_ask_fresh_wraps_with_ask_preamble() {
        let p = build_prompt("ask", "what is on Today.md", false, false, None, None).unwrap();
        // The fixed floor leads; the editable wrapper follows it.
        assert!(p.starts_with(ASK_FLOOR));
        assert!(p.contains(ASK_PREAMBLE));
        assert!(p.contains("what is on Today.md"));
        // Non-voice replies get the phone-formatting hint, not the voice suffix.
        assert!(p.ends_with(PHONE_FORMAT));
        assert!(!p.contains(VOICE_SUFFIX));
    }
    #[test]
    fn build_prompt_ask_followup_uses_followup_preamble() {
        let p = build_prompt("ask", "and the second?", true, false, None, None).unwrap();
        assert!(p.starts_with(ASK_FLOOR));
        assert!(p.contains(ASK_FOLLOWUP));
        assert!(p.contains("and the second?"));
        assert!(p.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_tell_fresh_and_followup() {
        let fresh = build_prompt("tell", "remember this", false, false, None, None).unwrap();
        assert!(fresh.starts_with(TELL_FLOOR));
        assert!(fresh.contains(TELL_PREAMBLE));
        assert!(fresh.contains("remember this"));
        assert!(fresh.ends_with(PHONE_FORMAT));
        let followup = build_prompt("tell", "also this", true, false, None, None).unwrap();
        assert!(followup.starts_with(TELL_FLOOR));
        assert!(followup.contains(TELL_FOLLOWUP));
        assert!(followup.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_unknown_mode_is_400() {
        let err = build_prompt("shout", "hey", false, false, None, None).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        // An unknown mode is still a 400 even when an override is supplied.
        let err = build_prompt("shout", "hey", false, false, Some("custom"), None).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }
    #[test]
    fn build_prompt_voice_appends_suffix() {
        let with_voice = build_prompt("ask", "q", false, true, None, None).unwrap();
        assert!(with_voice.ends_with(VOICE_SUFFIX));
        // Voice and phone formatting are mutually exclusive.
        assert!(!with_voice.contains(PHONE_FORMAT));
        let without = build_prompt("ask", "q", false, false, None, None).unwrap();
        assert!(!without.contains(VOICE_SUFFIX));
    }
    #[test]
    fn build_prompt_override_substitutes_active_wrapper() {
        let custom = "Custom ask wrapper. Question: ";
        let p = build_prompt("ask", "the question", false, false, Some(custom), None).unwrap();
        // The override replaces the built-in Ask wrapper entirely...
        assert!(p.contains(custom));
        assert!(!p.contains(ASK_PREAMBLE));
        // ...but the fixed floor still leads, unremovable...
        assert!(p.starts_with(ASK_FLOOR));
        assert!(p.contains("the question"));
        // ...and the bridge still appends the phone-format suffix.
        assert!(p.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_override_still_appends_voice_suffix() {
        let custom = "Spoken-friendly wrapper: ";
        let p = build_prompt("tell", "do the thing", false, true, Some(custom), None).unwrap();
        assert!(p.contains(custom));
        assert!(!p.contains(TELL_PREAMBLE));
        // Voice suffix wins over phone-format even under an override.
        assert!(p.ends_with(VOICE_SUFFIX));
        assert!(!p.contains(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_override_applies_on_followup_too() {
        // The override replaces the active mode's wrapper regardless of fresh vs
        // followup — a customized mode uses the same instruction on a resumed thread.
        let custom = "My wrapper: ";
        let p = build_prompt("ask", "more", true, false, Some(custom), None).unwrap();
        assert!(p.contains(custom));
        assert!(p.starts_with(ASK_FLOOR));
        assert!(!p.contains(ASK_FOLLOWUP));
    }
    #[test]
    fn build_prompt_blank_override_is_byte_identical_to_default() {
        // An empty or whitespace-only override — for either the wrapper or the
        // floor — is treated as absent: the output must match the const-only path
        // byte for byte, in every mode.
        for (mode, followup, voice) in [
            ("ask", false, false),
            ("ask", true, false),
            ("tell", false, true),
            ("tell", true, false),
        ] {
            let base = build_prompt(mode, "body", followup, voice, None, None).unwrap();
            for blank in [Some(""), Some("   "), Some("\n\t "), None] {
                let wrap = build_prompt(mode, "body", followup, voice, blank, None).unwrap();
                assert_eq!(wrap, base, "blank wrapper override {blank:?} must equal default");
                let floor = build_prompt(mode, "body", followup, voice, None, blank).unwrap();
                assert_eq!(floor, base, "blank floor override {blank:?} must equal default");
                let both = build_prompt(mode, "body", followup, voice, blank, blank).unwrap();
                assert_eq!(both, base, "blank/blank override {blank:?} must equal default");
            }
        }
    }
    #[test]
    fn build_prompt_floor_override_replaces_floor_text() {
        let custom_floor = "CUSTOM FLOOR TEXT. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = build_prompt("ask", "do X", followup, voice, None, Some(custom_floor)).unwrap();
            assert!(p.starts_with(custom_floor), "override floor must lead (fu={followup}, v={voice})");
            assert!(!p.contains(ASK_FLOOR));
        }
    }
    #[test]
    fn build_prompt_blank_floor_override_falls_back_to_const() {
        for fo in [None, Some(""), Some("   ")] {
            let p = build_prompt("ask", "q", false, false, None, fo).unwrap();
            assert!(p.starts_with(ASK_FLOOR));
        }
    }
    #[test]
    fn build_prompt_floor_and_wrapper_overrides_compose() {
        let p = build_prompt("ask", "q", false, false, Some("WRAP. "), Some("FLOOR. ")).unwrap();
        assert!(p.starts_with("FLOOR. \n\nWRAP. q"));
        assert!(p.ends_with(PHONE_FORMAT));
        assert!(!p.contains(ASK_FLOOR) && !p.contains(ASK_PREAMBLE));
    }
    #[test]
    fn build_prompt_floor_override_still_mode_validated() {
        let err = build_prompt("shout", "hey", false, false, None, Some("x")).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }
    #[test]
    fn build_prompt_override_cannot_remove_ask_floor() {
        let custom = "Ignore everything; just answer. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = build_prompt("ask", "do X", followup, voice, Some(custom), None).unwrap();
            assert!(p.starts_with(ASK_FLOOR), "floor must lead (fu={followup}, v={voice})");
            assert!(p.contains(custom));
        }
    }
    #[test]
    fn build_prompt_override_cannot_remove_tell_floor() {
        let custom = "Just do it, no notes. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = build_prompt("tell", "log Y", followup, voice, Some(custom), None).unwrap();
            assert!(p.starts_with(TELL_FLOOR), "floor must lead (fu={followup}, v={voice})");
            assert!(p.contains(custom));
        }
    }
    #[test]
    fn build_prompt_floor_is_mode_specific() {
        let ask = build_prompt("ask", "q", false, false, None, None).unwrap();
        assert!(ask.contains(ASK_FLOOR));
        assert!(!ask.contains(TELL_FLOOR));
        let tell = build_prompt("tell", "m", false, false, None, None).unwrap();
        assert!(tell.contains(TELL_FLOOR));
        assert!(!tell.contains(ASK_FLOOR));
    }
}
