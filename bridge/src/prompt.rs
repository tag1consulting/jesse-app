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

// ---- Stateless title endpoint (POST /jesse/title) -------------------------
//
// The title path is NOT a turn: no clock header, no safety floor, no
// voice/phone suffix, no session, no persistence. It is a bare one-shot text
// transform, so its prompt and its consts live apart from the turn wrappers
// above.

/// Max bytes of conversation text `POST /jesse/title` will accept. The app sends
/// a bounded digest of one thread to be titled; anything larger is rejected
/// (`413`) BEFORE any `claude` spawn, so a title request can never trigger a
/// giant model call. 16 KiB comfortably fits a digest while staying well under a
/// real turn's input.
pub const MAX_TITLE_INPUT_BYTES: usize = 16 * 1024;

/// Hard cap (characters) on the title the endpoint returns, applied after the raw
/// model reply is clamped to a single line. The instruction asks for ~3–6 words /
/// ~40 chars; this is the safety clamp so a verbose or run-on reply can never come
/// back as a long "title". A little above 40 so a legitimately snug title isn't
/// chopped mid-word.
pub const MAX_TITLE_CHARS: usize = 60;

/// The fixed instruction wrapped around the conversation digest for the title
/// endpoint. Asks for ONE very short title only — bare text, no quotes, no
/// trailing punctuation, no "Title:" prefix — and to keep a good opening as-is or
/// otherwise rephrase it. It also tells the model not to use tools/read files, so
/// the one-shot stays fast (the allowlist still applies as defense-in-depth).
pub const TITLE_INSTRUCTION: &str = "Produce ONE very short title for the conversation \
below. Aim for roughly 3–6 words, about 40 characters at most. Output ONLY the bare \
title text — no surrounding quotes, no trailing punctuation, no \"Title:\" prefix, no \
explanation, no extra lines. If the opening of the text already reads as a good short \
title, keep it as-is; otherwise rephrase it into a clearer short title. Do not use any \
tools and do not read any files — just read the text below and return the title.";

/// Build the one-shot prompt for the title endpoint: the fixed instruction, then
/// the conversation text. Pure and side-effect-free (no clock, no floor).
pub fn build_title_prompt(text: &str) -> String {
    format!("{TITLE_INSTRUCTION}\n\nConversation:\n{text}")
}

/// Clamp a raw model reply down to a single-line title: take the first non-empty
/// line, strip a leading `Title:` label and a single pair of surrounding quotes,
/// drop trailing punctuation, and truncate to `MAX_TITLE_CHARS` characters on a
/// char boundary. Pure, so it's unit-tested. Returns `""` when nothing usable
/// remains (the handler treats that as "no title" and degrades).
pub fn sanitize_title(raw: &str) -> String {
    // First non-empty line only — a well-behaved reply is one line, but guard
    // against a model that adds an explanation on a second line anyway.
    let line = raw
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    // Strip a leading "Title:" label (case-insensitive) if the model added one.
    let line = match line.get(..6) {
        Some(prefix) if prefix.eq_ignore_ascii_case("title:") => line[6..].trim(),
        _ => line,
    };
    // Strip a single pair of matching surrounding quotes (straight or smart).
    let line = strip_wrapping_quotes(line);
    // Drop trailing sentence punctuation the instruction asked to omit.
    let line = line
        .trim_end_matches(['.', '!', '?', ',', ';', ':'])
        .trim();
    // Clamp to MAX_TITLE_CHARS characters (char boundary safe) and re-trim in case
    // the cut left trailing whitespace.
    line.chars()
        .take(MAX_TITLE_CHARS)
        .collect::<String>()
        .trim()
        .to_string()
}

/// Strip one pair of matching surrounding quotes (straight `"`/`'` or smart
/// `“ ”`/`‘ ’`) if present and non-empty; otherwise return the input unchanged.
fn strip_wrapping_quotes(s: &str) -> &str {
    for (open, close) in [('"', '"'), ('\'', '\''), ('\u{201C}', '\u{201D}'), ('\u{2018}', '\u{2019}')] {
        if let Some(inner) = s.strip_prefix(open).and_then(|r| r.strip_suffix(close)) {
            let inner = inner.trim();
            if !inner.is_empty() {
                return inner;
            }
        }
    }
    s
}

// ---- Per-turn clock header ------------------------------------------------
//
// Jesse runs headless (`claude -p`) with no guaranteed sense of the current
// date/time/timezone: the CLI's own system prompt can't be relied on to carry
// day-of-week + timezone, yet routines and relative-date requests ("what's on
// today", "how many days until X", "today or tomorrow?") key off exactly that.
// So the bridge prepends ONE deterministic line to every wrapped prompt,
// computed fresh per turn from the host's system clock — the source of truth,
// present whether or not `claude` also injects a date. It carries day-of-week,
// full date, local time, timezone abbreviation, and UTC offset so the model can
// convert when a request names another zone (Jeremy travels across timezones).
// The zone is never hardcoded: it comes from the host wall-clock via `date`.

/// The per-turn clock header, computed fresh from the system clock. Prefers the
/// host `date` command — the only way to read the LOCAL zone abbreviation and
/// offset without pulling a timezone crate (std exposes UTC only) — forcing
/// `LC_ALL=C` so the weekday/abbreviation are English regardless of host locale.
/// If `date` is somehow unavailable it falls back to a std-only UTC computation,
/// so the header is NEVER absent: being guaranteed-present every turn is the
/// whole point. Impure (reads the clock); the formatting is factored into the
/// pure `format_clock_line` so the wording is unit-testable.
pub fn clock_line() -> String {
    if let Some(line) = clock_line_from_date() {
        return line;
    }
    let (weekday, ymd, hm, abbrev, offset) = utc_now_fields();
    format_clock_line(&weekday, &ymd, &hm, &abbrev, &offset)
}

/// Read the local clock via `date` and format the header, or `None` if `date`
/// can't be run or emits an unusable line. A single pipe-delimited call keeps
/// parsing trivial and locale-proof.
fn clock_line_from_date() -> Option<String> {
    let out = std::process::Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%A|%Y-%m-%d|%H:%M|%Z|%z")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    // Exactly five fields, with a non-empty weekday and zone abbreviation (a bare
    // offset with no zone name is no better than the UTC fallback).
    if let [weekday, ymd, hm, abbrev, offset] = s.trim().split('|').collect::<Vec<_>>()[..] {
        if !weekday.is_empty() && !abbrev.is_empty() {
            return Some(format_clock_line(weekday, ymd, hm, abbrev, offset));
        }
    }
    None
}

/// Assemble the clock header from its already-extracted fields. Pure (reads no
/// clock), so the exact wording is unit-testable. `offset_raw` may be the compact
/// `±HHMM` that `date +%z` emits (BSD `date` on macOS has no `%:z`); it is
/// normalized to `±HH:MM`.
fn format_clock_line(weekday: &str, ymd: &str, hm: &str, abbrev: &str, offset_raw: &str) -> String {
    format!(
        "Current date/time: {weekday}, {ymd} {hm} {abbrev} (UTC{}).",
        normalize_offset(offset_raw)
    )
}

/// Normalize a UTC offset to `±HH:MM`. Accepts `date +%z`'s compact `±HHMM`,
/// passes an already-colonized `±HH:MM` through unchanged, and returns anything
/// unexpected verbatim rather than mangling it.
fn normalize_offset(raw: &str) -> String {
    let raw = raw.trim();
    // Already `±HH:MM`.
    if raw.len() == 6 && raw.as_bytes().get(3) == Some(&b':') {
        return raw.to_string();
    }
    // Compact `±HHMM` → `±HH:MM`.
    if raw.len() == 5
        && (raw.starts_with('+') || raw.starts_with('-'))
        && raw[1..].bytes().all(|b| b.is_ascii_digit())
    {
        return format!("{}:{}", &raw[..3], &raw[3..]);
    }
    raw.to_string()
}

/// UTC fallback fields — (weekday, `YYYY-MM-DD`, `HH:MM`, "UTC", "+0000") from the
/// system clock with std only, used when `date` is unavailable. Time-of-day is
/// wall UTC; the civil-date math is the standard days-from-epoch algorithm.
fn utc_now_fields() -> (String, String, String, String, String) {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    // 1970-01-01 was a Thursday; index 0 = Sunday.
    const WD: [&str; 7] = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ];
    let weekday = WD[(days + 4).rem_euclid(7) as usize];
    (
        weekday.to_string(),
        format!("{y:04}-{m:02}-{d:02}"),
        format!("{:02}:{:02}", sod / 3600, (sod % 3600) / 60),
        "UTC".to_string(),
        "+0000".to_string(),
    )
}

/// Convert days since 1970-01-01 to `(year, month, day)`. Howard Hinnant's
/// `civil_from_days`, valid across the whole representable range.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (y + i64::from(m <= 2), m, d)
}

/// Wrap the user's text in the active mode's instruction, then append the
/// voice or phone-format suffix. `mode` (validated here) selects Ask vs Tell and
/// fresh vs followup. The mode's safety floor is ALWAYS prepended; a non-empty
/// `floor_override` customizes only its *wording* (blank/absent falls back to the
/// built-in const, so there is never a turn with no floor at all). A non-empty
/// `instructions` override replaces only the built-in *wrapper* that follows the
/// floor. The suffix is still appended regardless, so the bridge always owns the
/// floor and voice/phone formatting. With both overrides absent or blank the
/// output is byte-identical to the const-only path.
///
/// The per-turn clock header (see [`clock_line`]) LEADS the wrapped prompt, ahead
/// of the safety floor, so it is the first thing the model sees and is
/// unambiguous even if `claude` injects its own lesser date. This is a thin
/// wrapper over the pure [`build_prompt_at`] that reads the clock; tests use
/// `build_prompt_at` for a deterministic clock.
pub fn build_prompt(
    mode: &str,
    text: &str,
    is_followup: bool,
    voice: bool,
    instructions: Option<&str>,
    floor_override: Option<&str>,
) -> Result<String, ApiError> {
    build_prompt_at(
        &clock_line(),
        mode,
        text,
        is_followup,
        voice,
        instructions,
        floor_override,
    )
}

/// The pure core of [`build_prompt`]: identical, except the clock header is
/// passed in rather than read from the system clock, so the output is fully
/// deterministic under test. `clock` leads the wrapped prompt; an empty `clock`
/// is omitted entirely (no leading blank lines), reproducing the pre-clock output
/// byte-for-byte.
#[allow(clippy::too_many_arguments)]
pub fn build_prompt_at(
    clock: &str,
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
    // The clock header LEADS, ahead of the floor. An empty clock is omitted so
    // the const-only path is reproduced byte-for-byte (no leading blank lines).
    let mut p = if clock.trim().is_empty() {
        format!("{floor}\n\n{preamble}{text}")
    } else {
        format!("{clock}\n\n{floor}\n\n{preamble}{text}")
    };
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

    // A fixed clock so the wrapper's output is deterministic under test. Tests
    // drive `build_prompt_at` with this; the live `clock_line()` is covered
    // separately below.
    const TEST_CLOCK: &str = "Current date/time: Wednesday, 2026-07-01 07:16 CEST (UTC+02:00).";

    // The wrapped prompt for the given mode/overrides, with the fixed test clock.
    fn bp(
        mode: &str,
        text: &str,
        followup: bool,
        voice: bool,
        instructions: Option<&str>,
        floor: Option<&str>,
    ) -> String {
        build_prompt_at(TEST_CLOCK, mode, text, followup, voice, instructions, floor).unwrap()
    }

    #[test]
    fn build_prompt_ask_fresh_wraps_with_ask_preamble() {
        let p = bp("ask", "what is on Today.md", false, false, None, None);
        // The clock leads, then the fixed floor, then the editable wrapper.
        assert!(p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")));
        assert!(p.contains(ASK_PREAMBLE));
        assert!(p.contains("what is on Today.md"));
        // Non-voice replies get the phone-formatting hint, not the voice suffix.
        assert!(p.ends_with(PHONE_FORMAT));
        assert!(!p.contains(VOICE_SUFFIX));
    }
    #[test]
    fn build_prompt_ask_followup_uses_followup_preamble() {
        let p = bp("ask", "and the second?", true, false, None, None);
        assert!(p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")));
        assert!(p.contains(ASK_FOLLOWUP));
        assert!(p.contains("and the second?"));
        assert!(p.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_tell_fresh_and_followup() {
        let fresh = bp("tell", "remember this", false, false, None, None);
        assert!(fresh.starts_with(&format!("{TEST_CLOCK}\n\n{TELL_FLOOR}")));
        assert!(fresh.contains(TELL_PREAMBLE));
        assert!(fresh.contains("remember this"));
        assert!(fresh.ends_with(PHONE_FORMAT));
        let followup = bp("tell", "also this", true, false, None, None);
        assert!(followup.starts_with(&format!("{TEST_CLOCK}\n\n{TELL_FLOOR}")));
        assert!(followup.contains(TELL_FOLLOWUP));
        assert!(followup.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_unknown_mode_is_400() {
        let err = build_prompt_at(TEST_CLOCK, "shout", "hey", false, false, None, None).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        // An unknown mode is still a 400 even when an override is supplied.
        let err = build_prompt_at(TEST_CLOCK, "shout", "hey", false, false, Some("custom"), None)
            .unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }
    #[test]
    fn build_prompt_voice_appends_suffix() {
        let with_voice = bp("ask", "q", false, true, None, None);
        assert!(with_voice.ends_with(VOICE_SUFFIX));
        // Voice and phone formatting are mutually exclusive.
        assert!(!with_voice.contains(PHONE_FORMAT));
        let without = bp("ask", "q", false, false, None, None);
        assert!(!without.contains(VOICE_SUFFIX));
    }
    #[test]
    fn build_prompt_override_substitutes_active_wrapper() {
        let custom = "Custom ask wrapper. Question: ";
        let p = bp("ask", "the question", false, false, Some(custom), None);
        // The override replaces the built-in Ask wrapper entirely...
        assert!(p.contains(custom));
        assert!(!p.contains(ASK_PREAMBLE));
        // ...but the clock + fixed floor still lead, unremovable...
        assert!(p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")));
        assert!(p.contains("the question"));
        // ...and the bridge still appends the phone-format suffix.
        assert!(p.ends_with(PHONE_FORMAT));
    }
    #[test]
    fn build_prompt_override_still_appends_voice_suffix() {
        let custom = "Spoken-friendly wrapper: ";
        let p = bp("tell", "do the thing", false, true, Some(custom), None);
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
        let p = bp("ask", "more", true, false, Some(custom), None);
        assert!(p.contains(custom));
        assert!(p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")));
        assert!(!p.contains(ASK_FOLLOWUP));
    }
    #[test]
    fn build_prompt_blank_override_is_byte_identical_to_default() {
        // An empty or whitespace-only override — for either the wrapper or the
        // floor — is treated as absent: the output must match the const-only path
        // byte for byte, in every mode. (The clock is held fixed across the pair.)
        for (mode, followup, voice) in [
            ("ask", false, false),
            ("ask", true, false),
            ("tell", false, true),
            ("tell", true, false),
        ] {
            let base = bp(mode, "body", followup, voice, None, None);
            for blank in [Some(""), Some("   "), Some("\n\t "), None] {
                let wrap = bp(mode, "body", followup, voice, blank, None);
                assert_eq!(wrap, base, "blank wrapper override {blank:?} must equal default");
                let floor = bp(mode, "body", followup, voice, None, blank);
                assert_eq!(floor, base, "blank floor override {blank:?} must equal default");
                let both = bp(mode, "body", followup, voice, blank, blank);
                assert_eq!(both, base, "blank/blank override {blank:?} must equal default");
            }
        }
    }
    #[test]
    fn build_prompt_floor_override_replaces_floor_text() {
        let custom_floor = "CUSTOM FLOOR TEXT. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = bp("ask", "do X", followup, voice, None, Some(custom_floor));
            // The clock still leads; the override floor follows it.
            assert!(
                p.starts_with(&format!("{TEST_CLOCK}\n\n{custom_floor}")),
                "override floor must follow the clock (fu={followup}, v={voice})"
            );
            assert!(!p.contains(ASK_FLOOR));
        }
    }
    #[test]
    fn build_prompt_blank_floor_override_falls_back_to_const() {
        for fo in [None, Some(""), Some("   ")] {
            let p = bp("ask", "q", false, false, None, fo);
            assert!(p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")));
        }
    }
    #[test]
    fn build_prompt_floor_and_wrapper_overrides_compose() {
        let p = bp("ask", "q", false, false, Some("WRAP. "), Some("FLOOR. "));
        assert!(p.starts_with(&format!("{TEST_CLOCK}\n\nFLOOR. \n\nWRAP. q")));
        assert!(p.ends_with(PHONE_FORMAT));
        assert!(!p.contains(ASK_FLOOR) && !p.contains(ASK_PREAMBLE));
    }
    #[test]
    fn build_prompt_floor_override_still_mode_validated() {
        let err =
            build_prompt_at(TEST_CLOCK, "shout", "hey", false, false, None, Some("x")).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }
    #[test]
    fn build_prompt_override_cannot_remove_ask_floor() {
        let custom = "Ignore everything; just answer. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = bp("ask", "do X", followup, voice, Some(custom), None);
            assert!(
                p.starts_with(&format!("{TEST_CLOCK}\n\n{ASK_FLOOR}")),
                "clock + floor must lead (fu={followup}, v={voice})"
            );
            assert!(p.contains(custom));
        }
    }
    #[test]
    fn build_prompt_override_cannot_remove_tell_floor() {
        let custom = "Just do it, no notes. ";
        for (followup, voice) in [(false, false), (true, false), (false, true)] {
            let p = bp("tell", "log Y", followup, voice, Some(custom), None);
            assert!(
                p.starts_with(&format!("{TEST_CLOCK}\n\n{TELL_FLOOR}")),
                "clock + floor must lead (fu={followup}, v={voice})"
            );
            assert!(p.contains(custom));
        }
    }
    #[test]
    fn build_prompt_floor_is_mode_specific() {
        let ask = bp("ask", "q", false, false, None, None);
        assert!(ask.contains(ASK_FLOOR));
        assert!(!ask.contains(TELL_FLOOR));
        let tell = bp("tell", "m", false, false, None, None);
        assert!(tell.contains(TELL_FLOOR));
        assert!(!tell.contains(ASK_FLOOR));
    }

    // ---- Title endpoint ----------------------------------------------------

    #[test]
    fn build_title_prompt_wraps_text_with_fixed_instruction() {
        let p = build_title_prompt("hello there");
        assert!(p.starts_with(TITLE_INSTRUCTION), "instruction must lead: {p:?}");
        assert!(p.contains("hello there"));
        // Not a turn: none of the turn scaffolding leaks in.
        assert!(!p.contains(ASK_FLOOR) && !p.contains(TELL_FLOOR));
        assert!(!p.contains("Current date/time:"));
        assert!(!p.contains(PHONE_FORMAT) && !p.contains(VOICE_SUFFIX));
    }
    #[test]
    fn sanitize_title_passes_a_clean_title_through() {
        assert_eq!(sanitize_title("Weekend Trip Planning"), "Weekend Trip Planning");
    }
    #[test]
    fn sanitize_title_strips_surrounding_quotes() {
        assert_eq!(sanitize_title("\"Weekend Trip\""), "Weekend Trip");
        assert_eq!(sanitize_title("'Weekend Trip'"), "Weekend Trip");
        // Smart quotes too.
        assert_eq!(sanitize_title("\u{201C}Weekend Trip\u{201D}"), "Weekend Trip");
    }
    #[test]
    fn sanitize_title_strips_title_prefix_and_trailing_punctuation() {
        assert_eq!(sanitize_title("Title: Weekend Trip"), "Weekend Trip");
        assert_eq!(sanitize_title("title: Weekend Trip."), "Weekend Trip");
        assert_eq!(sanitize_title("Weekend Trip!"), "Weekend Trip");
    }
    #[test]
    fn sanitize_title_takes_first_nonempty_line_only() {
        // A model that adds an explanation on later lines: only the first line is
        // the title.
        assert_eq!(
            sanitize_title("\n\nWeekend Trip\nThis title summarizes the chat."),
            "Weekend Trip"
        );
    }
    #[test]
    fn sanitize_title_clamps_to_one_line_at_most_max_chars() {
        // A long, run-on "title" is clamped to a single line ≤ MAX_TITLE_CHARS.
        let long = "This is an absurdly long run on title that keeps going well past any \
                    reasonable short title length";
        let out = sanitize_title(long);
        assert!(out.chars().count() <= MAX_TITLE_CHARS, "clamped to cap: {out:?}");
        assert!(!out.contains('\n'), "single line only");
        assert!(!out.is_empty());
    }
    #[test]
    fn sanitize_title_empty_or_blank_yields_empty() {
        assert_eq!(sanitize_title(""), "");
        assert_eq!(sanitize_title("   \n\t "), "");
    }
    #[test]
    fn sanitize_title_never_splits_a_multibyte_char_at_the_cap() {
        // A title of multibyte chars clamped at the char cap stays valid UTF-8.
        let s = "\u{1F389}".repeat(MAX_TITLE_CHARS + 20); // 🎉 × many
        let out = sanitize_title(&s);
        assert_eq!(out.chars().count(), MAX_TITLE_CHARS);
        assert!(out.chars().all(|c| c == '\u{1F389}'));
    }

    // ---- Clock header ------------------------------------------------------

    #[test]
    fn build_prompt_prepends_clock_ahead_of_floor() {
        // The clock is the very first thing in the wrapped prompt, before the floor.
        let p = build_prompt_at(
            "Current date/time: Monday, 2026-01-05 09:00 EST (UTC-05:00).",
            "ask",
            "q",
            false,
            false,
            None,
            None,
        )
        .unwrap();
        assert!(p.starts_with("Current date/time: Monday, 2026-01-05 09:00 EST (UTC-05:00).\n\n"));
        assert!(p.contains(ASK_FLOOR));
    }
    #[test]
    fn build_prompt_empty_clock_is_omitted() {
        // An empty clock reproduces the pre-clock output: the floor leads, with no
        // stray leading blank lines.
        let p = build_prompt_at("", "ask", "q", false, false, None, None).unwrap();
        assert!(p.starts_with(ASK_FLOOR));
        assert!(!p.starts_with('\n'));
    }
    #[test]
    fn format_clock_line_normalizes_offset() {
        // Compact `±HHMM` (what `date +%z` emits on macOS) gets a colon.
        assert_eq!(
            format_clock_line("Wednesday", "2026-07-01", "07:16", "CEST", "+0200"),
            TEST_CLOCK
        );
        // An already-colonized offset passes through unchanged.
        assert_eq!(
            format_clock_line("Wednesday", "2026-07-01", "07:16", "CEST", "+02:00"),
            TEST_CLOCK
        );
        // Negative and half-hour offsets.
        assert_eq!(normalize_offset("-0530"), "-05:30");
        assert_eq!(normalize_offset("+0000"), "+00:00");
        assert_eq!(normalize_offset("+05:45"), "+05:45");
        // Anything unexpected is returned verbatim rather than mangled.
        assert_eq!(normalize_offset("Z"), "Z");
    }
    #[test]
    fn clock_line_is_live_and_well_formed() {
        // Computed fresh from the system clock — not a constant. Prove the SHAPE
        // (weekday, ISO date, HH:MM, a zone token, colonized UTC offset) and that
        // the date is a plausible current one (year >= 2026, valid month/day).
        let line = clock_line();
        let rest = line
            .strip_prefix("Current date/time: ")
            .expect("clock line must start with the fixed label");
        let rest = rest.strip_suffix(").").expect("clock line must end with ').'");
        // "<Weekday>, <YYYY-MM-DD> <HH:MM> <ABBR> (UTC<offset>"
        let (head, offset) = rest.split_once(" (UTC").expect("must carry a (UTC offset)");
        // Offset is colonized ±HH:MM.
        assert_eq!(offset.len(), 6, "offset must be ±HH:MM: {offset:?}");
        assert!(offset.starts_with('+') || offset.starts_with('-'));
        assert_eq!(offset.as_bytes()[3], b':');
        let parts: Vec<&str> = head.split(' ').collect();
        assert!(parts.len() >= 4, "expected weekday/date/time/abbr: {head:?}");
        let weekday = parts[0].trim_end_matches(',');
        assert!(
            [
                "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
            ]
            .contains(&weekday),
            "unexpected weekday {weekday:?}"
        );
        // Date field: YYYY-MM-DD, a real current-ish date.
        let date: Vec<&str> = parts[1].split('-').collect();
        assert_eq!(date.len(), 3, "date must be YYYY-MM-DD: {:?}", parts[1]);
        let year: i64 = date[0].parse().expect("year");
        let month: u32 = date[1].parse().expect("month");
        let day: u32 = date[2].parse().expect("day");
        assert!(year >= 2026, "clock must reflect the real (current) year: {year}");
        assert!((1..=12).contains(&month) && (1..=31).contains(&day));
        // Time field: HH:MM.
        let time: Vec<&str> = parts[2].split(':').collect();
        assert_eq!(time.len(), 2);
        assert!(time[0].parse::<u32>().unwrap() < 24 && time[1].parse::<u32>().unwrap() < 60);
        // Zone abbreviation is non-empty.
        assert!(!parts[3].is_empty());
    }
    #[test]
    fn civil_from_days_matches_known_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1)); // epoch
        assert_eq!(civil_from_days(-1), (1969, 12, 31)); // day before
        assert_eq!(civil_from_days(59), (1970, 3, 1)); // 1970 not a leap year
        assert_eq!(civil_from_days(365), (1971, 1, 1)); // one common year on
        assert_eq!(civil_from_days(31 + 28), (1970, 3, 1));
        assert_eq!(civil_from_days(11_017), (2000, 3, 1)); // across a leap-century boundary
    }
    #[test]
    fn utc_now_fields_are_well_formed() {
        // The std-only fallback yields the same field shape the formatter expects.
        let (weekday, ymd, hm, abbrev, offset) = utc_now_fields();
        assert!([
            "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
        ]
        .contains(&weekday.as_str()));
        assert_eq!(abbrev, "UTC");
        assert_eq!(offset, "+0000");
        assert_eq!(ymd.len(), 10); // YYYY-MM-DD
        assert_eq!(hm.len(), 5); // HH:MM
        // Feeds the formatter cleanly.
        let line = format_clock_line(&weekday, &ymd, &hm, &abbrev, &offset);
        assert!(line.starts_with("Current date/time: "));
        assert!(line.ends_with("(UTC+00:00)."));
    }
}
