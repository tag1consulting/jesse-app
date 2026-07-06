//! Agent-emitted **directives** — a structured back-channel from the sandboxed
//! agent's reply to the app, carried on the terminal result.
//!
//! A directive is the **final non-empty line** of a reply, exactly one line, in a
//! fixed generic form:
//!
//! ```text
//! JESSE_<NAME> v<N> {json}
//! ```
//!
//! The agent uses it to *ask the app for something it can only get on-device* —
//! for now, Apple Health context it wasn't given this turn
//! (`JESSE_NEEDS_HEALTH v1`). The planned dietary write-back adds
//! `JESSE_MEAL_LOG v1` on this same extractor, so the recognizer is a small
//! **registry** (a `match` on `(name, version)`), not one-off plumbing.
//!
//! **Trust.** A directive originates from the agent's OUTPUT, which is
//! attacker-influenceable (prompt injection into the vault, a crafted request).
//! So the app validates every request it produces against a fixed whitelist and
//! caps before acting on it — a prompt-injected agent can at worst ask for
//! whitelisted health aggregates the user already agreed to share. This module is
//! the bridge half of that discipline: it validates the payload here too (defense
//! in depth) and only attaches a directive that parses AND passes the contract.
//!
//! **Correctness invariant.** Extraction only ever affects token cost / prompt
//! hygiene — never the answer. A line that does not cleanly match a KNOWN
//! directive is left **in the reply text, visible** (a loud contract failure),
//! and no field is attached; the reply the user sees is never silently mangled.

use crate::*;
use serde::{Deserialize, Serialize};

/// Outer ceiling on ANY directive candidate line, checked BEFORE the registry is
/// consulted. A final line longer than this is never treated as a directive — it
/// passes through untouched and visible (logged), so a runaway/garbled line can
/// never be parsed as a command or balloon the wire. Sized to the **largest**
/// per-directive contract (`JESSE_MEAL_LOG`, 8 KiB); a directive with a tighter
/// contract (`JESSE_NEEDS_HEALTH`) enforces its own smaller cap in its registry
/// arm, so raising this ceiling never loosens an existing directive's bound.
pub const MAX_DIRECTIVE_LINE_BYTES: usize = 8 * 1024;

/// Per-directive line cap for `JESSE_NEEDS_HEALTH` — its payload is small (≤ 4
/// metrics + a two-value `sections` set), so it keeps the original tight 2 KiB
/// bound even though the generic ceiling is now larger.
pub const MAX_NEEDS_HEALTH_LINE_BYTES: usize = 2 * 1024;

/// Per-directive line cap for `JESSE_MEAL_LOG` — a reply may log several meals,
/// so it gets the full 8 KiB contract bound (equal to the generic ceiling).
pub const MAX_MEAL_LOG_LINE_BYTES: usize = 8 * 1024;

/// Max meals one `JESSE_MEAL_LOG v1` directive may carry. Over this the whole
/// block is treated as malformed (passthrough + log), never partially logged.
pub const MAX_MEALS: usize = 10;

/// The optional macro fields a meal may carry, and the only keys (besides the
/// required `id`/`consumedAt`/`name`) allowed on a meal object. A typo'd or extra
/// key is a loud failure, mirroring the needs-health payload's unknown-key check.
const MEAL_FIELDS: &[&str] = &["id", "consumedAt", "name", "kcal", "protein_g", "carbs_g", "fat_g"];

/// Sections a `JESSE_NEEDS_HEALTH` directive may request (the phone-assembled
/// two-section health block). Kept in sync with the app's formatter.
pub const NEEDS_HEALTH_SECTIONS: &[&str] = &["daily", "workouts"];

/// Whitelisted metric identifiers a `JESSE_NEEDS_HEALTH` directive may request a
/// windowed series for. **Kept in exact sync with the app's `RequestableMetric`
/// enum** (PR 2): the app rejects anything off this list, and the bridge rejects
/// it here too, so a prompt-injected agent can only ever ask for these
/// device-health aggregates the user already opted into sharing.
pub const NEEDS_HEALTH_METRICS: &[&str] = &[
    "restingHeartRate",
    "heartRate",
    "heartRateVariabilitySDNN",
    "stepCount",
    "activeEnergyBurned",
    "bodyMass",
    "sleepAnalysis",
    "vo2Max",
    "workouts",
];

/// Max number of metric requests one directive may carry.
pub const MAX_NEEDS_HEALTH_METRICS: usize = 4;

/// Allowed `window_days` range (inclusive) for a metric request.
pub const NEEDS_HEALTH_WINDOW_DAYS: std::ops::RangeInclusive<u64> = 1..=31;

/// One windowed-metric request inside a `JESSE_NEEDS_HEALTH` directive.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetricRequest {
    pub metric: String,
    pub window_days: u32,
}

/// The parsed payload of a `JESSE_NEEDS_HEALTH v1` directive: which sections
/// and/or whitelisted windowed metrics the agent needs to answer this turn. At
/// least one of `sections`/`metrics` is non-empty (enforced at parse time).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NeedsHealth {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sections: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub metrics: Vec<MetricRequest>,
}

/// One logged meal inside a `JESSE_MEAL_LOG v1` directive. `id` is the stable
/// idempotency key (date + meal slot) the app dedupes on; `consumed_at` is ISO
/// 8601 with offset (the *meal* time, not the log time); each macro is optional
/// and, per the contract, **omitted when unknown — never null-padded**, so
/// `None` serializes as an ABSENT key, not `null`. The wire names match the
/// contract exactly (`consumedAt` is camelCase; the macros keep their `_g`
/// suffixes) so the app decodes `directives.meal_log` symmetrically.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Meal {
    pub id: String,
    #[serde(rename = "consumedAt")]
    pub consumed_at: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kcal: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protein_g: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub carbs_g: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fat_g: Option<f64>,
}

/// The parsed payload of a `JESSE_MEAL_LOG v1` directive: one or more meals the
/// app writes to Apple Health (the bridge only extracts; the app is the writer).
/// `meals` is non-empty and capped at [`MAX_MEALS`], both enforced at parse time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MealLog {
    pub meals: Vec<Meal>,
}

/// The structured `directives` object attached to a terminal result. One
/// optional field per known directive type; more are added as the registry
/// grows. All-`None` never occurs — a `Directives` is attached only when at
/// least one directive was recognized.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Directives {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs_health: Option<NeedsHealth>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meal_log: Option<MealLog>,
}

/// Serialize an optional `Directives` to the wire value used by BOTH the poll
/// result JSON and the SSE `done` frame, so the two paths are byte-consistent.
/// `None` → JSON `null` (the app treats null/absent identically).
pub fn directives_to_value(directives: &Option<Directives>) -> Value {
    match directives {
        Some(d) => serde_json::to_value(d).unwrap_or(Value::Null),
        None => Value::Null,
    }
}

/// Map a finished turn's outcome through directive extraction. On success, the
/// reply's final directive line (if any known one) is stripped from the text and
/// the parsed value is returned alongside it; on failure the outcome is passed
/// through unchanged. This is the single seam the handler calls between
/// `run_claude_streaming` and `jobs.complete`, so the extracted directives land
/// in `JobState::Done` and flow identically to the poll result and the SSE
/// `done` frame.
pub fn apply_directives(
    outcome: Result<(String, Option<String>), ApiError>,
) -> Result<(String, Option<String>, Option<Directives>), ApiError> {
    outcome.map(|(response, session_id)| {
        let (stripped, directives) = extract_directives(&response);
        (stripped, session_id, directives)
    })
}

/// Extract a recognized directive from a reply's final non-empty line.
///
/// Returns `(text, directives)`:
/// - a KNOWN directive that parses and validates → the line is stripped from the
///   text (trailing whitespace trimmed) and its parsed value is returned;
/// - anything else → the text is returned **unchanged** and `directives` is
///   `None`. That covers a normal reply (no directive line), a directive-shaped
///   line with an unknown name/version (passed through visible — a loud contract
///   failure), a malformed line, an over-cap line, and a known directive whose
///   payload fails the contract. Every non-strip path that looked like a
///   directive is logged, so a contract break is visible rather than silent.
///
/// Exactly one directive line is recognized per reply — the final non-empty one.
/// Pure (aside from `eprintln!` diagnostics), so it is unit-tested directly.
pub fn extract_directives(reply: &str) -> (String, Option<Directives>) {
    // The candidate is the last non-empty line. `trim_end` drops any trailing
    // blank lines so the directive can sit under trailing newlines.
    let trimmed_reply = reply.trim_end();
    let last_line = match trimmed_reply.rsplit('\n').next() {
        Some(l) => l.trim(),
        None => return (reply.to_string(), None),
    };

    // Fast path: only a `JESSE_`-prefixed final line is ever a directive
    // candidate. A normal reply is returned untouched with no logging.
    if !last_line.starts_with("JESSE_") {
        return (reply.to_string(), None);
    }

    // Over-cap: a directive-shaped final line that is too long is not parsed —
    // pass it through visible and log (loud failure over silent loss).
    if last_line.len() > MAX_DIRECTIVE_LINE_BYTES {
        eprintln!(
            "directive: final line looks like a directive but exceeds the \
             {MAX_DIRECTIVE_LINE_BYTES}-byte cap — passing through untouched"
        );
        return (reply.to_string(), None);
    }

    // Shape: `JESSE_<NAME> v<N> {json}`.
    let Some((name, version, json)) = parse_directive_shape(last_line) else {
        eprintln!(
            "directive: final line starts with JESSE_ but is not a valid \
             `JESSE_<NAME> v<N> {{json}}` directive — passing through untouched"
        );
        return (reply.to_string(), None);
    };

    // Registry: exactly the known (name, version) pairs are recognized. Unknown
    // names or versions pass through untouched and VISIBLE — a loud contract
    // failure the operator/agent can see, never a silent strip. Each arm enforces
    // its OWN per-directive line cap (checked before its payload parse), so a
    // directive's contract owns its bound; the generic ceiling above is only the
    // outer DoS guard sized to the largest directive.
    match (name, version) {
        ("JESSE_NEEDS_HEALTH", 1) => {
            if last_line.len() > MAX_NEEDS_HEALTH_LINE_BYTES {
                eprintln!(
                    "directive: JESSE_NEEDS_HEALTH v1 exceeds its \
                     {MAX_NEEDS_HEALTH_LINE_BYTES}-byte cap — passing through untouched"
                );
                return (reply.to_string(), None);
            }
            match parse_needs_health(json) {
                Ok(needs_health) => {
                    let directives = Directives {
                        needs_health: Some(needs_health),
                        meal_log: None,
                    };
                    (strip_final_line(reply), Some(directives))
                }
                Err(reason) => {
                    eprintln!(
                        "directive: JESSE_NEEDS_HEALTH v1 payload rejected ({reason}) — \
                         passing through untouched"
                    );
                    (reply.to_string(), None)
                }
            }
        }
        ("JESSE_MEAL_LOG", 1) => {
            if last_line.len() > MAX_MEAL_LOG_LINE_BYTES {
                eprintln!(
                    "directive: JESSE_MEAL_LOG v1 exceeds its \
                     {MAX_MEAL_LOG_LINE_BYTES}-byte cap — passing through untouched"
                );
                return (reply.to_string(), None);
            }
            match parse_meal_log(json) {
                Ok(meal_log) => {
                    let directives = Directives {
                        needs_health: None,
                        meal_log: Some(meal_log),
                    };
                    (strip_final_line(reply), Some(directives))
                }
                Err(reason) => {
                    eprintln!(
                        "directive: JESSE_MEAL_LOG v1 payload rejected ({reason}) — \
                         passing through untouched"
                    );
                    (reply.to_string(), None)
                }
            }
        }
        _ => {
            eprintln!(
                "directive: unknown directive `{name} v{version}` — passing through \
                 untouched (visible contract failure)"
            );
            (reply.to_string(), None)
        }
    }
}

/// Split a candidate line into `(name, version, json)` if it matches
/// `JESSE_<NAME> v<N> {json…}`. The version token is `v` followed by digits; the
/// remainder must begin with `{`. Returns `None` for anything off-shape.
fn parse_directive_shape(line: &str) -> Option<(&str, u32, &str)> {
    let mut parts = line.splitn(3, ' ');
    let name = parts.next()?;
    let version_token = parts.next()?;
    let json = parts.next()?.trim();
    if !name.starts_with("JESSE_") {
        return None;
    }
    let version: u32 = version_token.strip_prefix('v')?.parse().ok()?;
    if !json.starts_with('{') {
        return None;
    }
    Some((name, version, json))
}

/// Remove the final non-empty line (the directive) from a reply, trimming any
/// trailing whitespace left behind. For a `JESSE_NEEDS_HEALTH` turn the reply is
/// the directive line alone, so this yields `""` — an empty answer the app does
/// not persist (it retries with the data attached instead).
fn strip_final_line(reply: &str) -> String {
    let trimmed_reply = reply.trim_end();
    match trimmed_reply.rfind('\n') {
        Some(nl) => trimmed_reply[..nl].trim_end().to_string(),
        None => String::new(),
    }
}

/// Parse + validate the JSON payload of a `JESSE_NEEDS_HEALTH v1` directive
/// against the contract: `sections` ⊆ {daily, workouts}; `metrics` a list (cap
/// [`MAX_NEEDS_HEALTH_METRICS`]) of `{metric, window_days}` with `metric` on the
/// [`NEEDS_HEALTH_METRICS`] whitelist and `window_days` an integer in
/// [`NEEDS_HEALTH_WINDOW_DAYS`]; at least one of sections/metrics present. Any
/// violation is an `Err(reason)` the caller logs and passes through — a bad
/// directive never becomes a partial or wrong request.
fn parse_needs_health(json: &str) -> Result<NeedsHealth, String> {
    let value: Value = serde_json::from_str(json).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;

    // Reject unknown keys so a typo'd field (e.g. "section") is a loud failure
    // rather than silently dropping the request.
    for key in obj.keys() {
        if key != "sections" && key != "metrics" {
            return Err(format!("unknown field {key:?}"));
        }
    }

    let sections = match obj.get("sections") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let s = item.as_str().ok_or("section entry is not a string")?;
                if !NEEDS_HEALTH_SECTIONS.contains(&s) {
                    return Err(format!("unknown section {s:?}"));
                }
                out.push(s.to_string());
            }
            out
        }
        Some(_) => return Err("`sections` is not an array".into()),
    };

    let metrics = match obj.get("metrics") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            if items.len() > MAX_NEEDS_HEALTH_METRICS {
                return Err(format!(
                    "`metrics` has {} entries, cap is {MAX_NEEDS_HEALTH_METRICS}",
                    items.len()
                ));
            }
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let m = item.as_object().ok_or("metric entry is not an object")?;
                for key in m.keys() {
                    if key != "metric" && key != "window_days" {
                        return Err(format!("unknown metric field {key:?}"));
                    }
                }
                let metric = m
                    .get("metric")
                    .and_then(|x| x.as_str())
                    .ok_or("metric entry missing string `metric`")?;
                if !NEEDS_HEALTH_METRICS.contains(&metric) {
                    return Err(format!("unknown metric {metric:?}"));
                }
                // as_u64 rejects negatives and non-integer floats (e.g. 14.5),
                // so a window is always a whole positive count.
                let window = m
                    .get("window_days")
                    .and_then(|x| x.as_u64())
                    .ok_or("metric entry missing integer `window_days`")?;
                if !NEEDS_HEALTH_WINDOW_DAYS.contains(&window) {
                    return Err(format!(
                        "window_days {window} out of range {}..={}",
                        NEEDS_HEALTH_WINDOW_DAYS.start(),
                        NEEDS_HEALTH_WINDOW_DAYS.end()
                    ));
                }
                out.push(MetricRequest {
                    metric: metric.to_string(),
                    window_days: window as u32,
                });
            }
            out
        }
        Some(_) => return Err("`metrics` is not an array".into()),
    };

    if sections.is_empty() && metrics.is_empty() {
        return Err("at least one of `sections`/`metrics` must be present".into());
    }
    Ok(NeedsHealth { sections, metrics })
}

/// Parse + validate the JSON payload of a `JESSE_MEAL_LOG v1` directive against
/// the contract: a single `meals` key holding a **non-empty** array (cap
/// [`MAX_MEALS`]) of meal objects, each with a non-empty `id`, `consumedAt`, and
/// `name`, plus any of the optional numeric macros. Any violation is an
/// `Err(reason)` the caller logs and passes through — a bad block never becomes a
/// partial or wrong meal write (visible failure over silent data loss).
fn parse_meal_log(json: &str) -> Result<MealLog, String> {
    let value: Value = serde_json::from_str(json).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;

    // Reject unknown top-level keys so a typo (e.g. "meal") is a loud failure
    // rather than silently logging nothing.
    for key in obj.keys() {
        if key != "meals" {
            return Err(format!("unknown field {key:?}"));
        }
    }

    let items = match obj.get("meals") {
        Some(Value::Array(items)) => items,
        None | Some(Value::Null) => return Err("missing `meals` array".into()),
        Some(_) => return Err("`meals` is not an array".into()),
    };
    if items.is_empty() {
        return Err("`meals` is empty".into());
    }
    if items.len() > MAX_MEALS {
        return Err(format!("`meals` has {} entries, cap is {MAX_MEALS}", items.len()));
    }

    let mut meals = Vec::with_capacity(items.len());
    for item in items {
        meals.push(parse_meal(item)?);
    }
    Ok(MealLog { meals })
}

/// Parse + validate one meal object. Enforces the required string fields, rejects
/// unknown keys, and validates each present macro as a finite non-negative
/// number. `consumedAt` is checked only for presence/non-emptiness here — the app
/// parses the ISO-8601 offset strictly before writing, so this is defense in
/// depth, not the authority on date shape (the bridge has no date library).
fn parse_meal(item: &Value) -> Result<Meal, String> {
    let m = item.as_object().ok_or("meal entry is not an object")?;
    for key in m.keys() {
        if !MEAL_FIELDS.contains(&key.as_str()) {
            return Err(format!("unknown meal field {key:?}"));
        }
    }
    Ok(Meal {
        id: required_nonempty_str(m, "id")?,
        consumed_at: required_nonempty_str(m, "consumedAt")?,
        name: required_nonempty_str(m, "name")?,
        kcal: optional_macro(m, "kcal")?,
        protein_g: optional_macro(m, "protein_g")?,
        carbs_g: optional_macro(m, "carbs_g")?,
        fat_g: optional_macro(m, "fat_g")?,
    })
}

/// A required meal string field: present, a JSON string, and non-empty after
/// trimming. Anything else (absent, wrong type, blank) is a loud rejection.
fn required_nonempty_str(m: &serde_json::Map<String, Value>, key: &str) -> Result<String, String> {
    let s = m
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("meal entry missing string `{key}`"))?;
    if s.trim().is_empty() {
        return Err(format!("meal `{key}` is empty"));
    }
    Ok(s.to_string())
}

/// An optional macro: absent → `None`; present → must be a finite, non-negative
/// number (an explicit `null` is a violation, since the contract says omit
/// unknown rather than null-pad, and a negative or non-finite macro is nonsense).
fn optional_macro(m: &serde_json::Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    match m.get(key) {
        None => Ok(None),
        Some(v) => {
            let n = v
                .as_f64()
                .ok_or_else(|| format!("meal `{key}` is not a number"))?;
            if !n.is_finite() {
                return Err(format!("meal `{key}` is not finite"));
            }
            if n < 0.0 {
                return Err(format!("meal `{key}` is negative"));
            }
            Ok(Some(n))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn needs_health(reply: &str) -> Option<NeedsHealth> {
        extract_directives(reply).1.and_then(|d| d.needs_health)
    }

    #[test]
    fn absent_directive_leaves_text_untouched() {
        let reply = "Here is your answer.\n\nSecond paragraph.";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn empty_reply_is_untouched() {
        let (text, directives) = extract_directives("");
        assert_eq!(text, "");
        assert!(directives.is_none());
    }

    #[test]
    fn known_directive_is_parsed_and_stripped_sections() {
        let reply = "JESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\",\"workouts\"]}";
        let (text, directives) = extract_directives(reply);
        // The sentinel-only reply strips to empty.
        assert_eq!(text, "");
        let nh = directives.unwrap().needs_health.unwrap();
        assert_eq!(nh.sections, vec!["daily", "workouts"]);
        assert!(nh.metrics.is_empty());
    }

    #[test]
    fn known_directive_metrics_are_parsed() {
        let reply =
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"restingHeartRate\",\"window_days\":14}]}";
        let nh = needs_health(reply).unwrap();
        assert!(nh.sections.is_empty());
        assert_eq!(
            nh.metrics,
            vec![MetricRequest {
                metric: "restingHeartRate".into(),
                window_days: 14
            }]
        );
    }

    #[test]
    fn directive_strips_only_the_final_line_keeping_prose() {
        // A future directive type may follow real prose; only the final line goes.
        let reply = "Sure, here is what I found so far.\n\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, "Sure, here is what I found so far.");
        assert!(directives.unwrap().needs_health.is_some());
    }

    #[test]
    fn directive_under_trailing_newlines_still_recognized() {
        let reply = "JESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}\n\n";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, "");
        assert!(directives.is_some());
    }

    #[test]
    fn non_final_directive_line_is_not_recognized() {
        // Only the FINAL non-empty line is a directive; one mid-reply is prose.
        let reply = "JESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}\nBut actually here is your answer.";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn unknown_name_passes_through_visible() {
        // A name that is NOT in the registry (JESSE_NEEDS_HEALTH and JESSE_MEAL_LOG
        // are the known ones) stays visible in the text as a loud contract failure.
        let reply = "JESSE_FROBNICATE v1 {\"foo\":1}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply, "unknown directive stays visible in the text");
        assert!(directives.is_none());
    }

    #[test]
    fn unknown_version_passes_through_visible() {
        let reply = "JESSE_NEEDS_HEALTH v2 {\"sections\":[\"daily\"]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn malformed_shape_passes_through_visible() {
        for reply in [
            "JESSE_NEEDS_HEALTH {\"sections\":[\"daily\"]}", // no version token
            "JESSE_NEEDS_HEALTH v1 not-json",               // remainder not an object
            "JESSE_NEEDS_HEALTH vX {\"sections\":[\"daily\"]}", // non-numeric version
        ] {
            let (text, directives) = extract_directives(reply);
            assert_eq!(text, reply, "malformed directive stays visible: {reply:?}");
            assert!(directives.is_none(), "no field for malformed: {reply:?}");
        }
    }

    #[test]
    fn invalid_payload_passes_through_visible() {
        for reply in [
            // empty (neither sections nor metrics)
            "JESSE_NEEDS_HEALTH v1 {}",
            // unknown section
            "JESSE_NEEDS_HEALTH v1 {\"sections\":[\"weather\"]}",
            // unknown metric
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"bloodPressure\",\"window_days\":7}]}",
            // window out of range (low)
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"stepCount\",\"window_days\":0}]}",
            // window out of range (high)
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"stepCount\",\"window_days\":32}]}",
            // non-integer window
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[{\"metric\":\"stepCount\",\"window_days\":7.5}]}",
            // too many metrics (5 > cap 4)
            "JESSE_NEEDS_HEALTH v1 {\"metrics\":[\
             {\"metric\":\"stepCount\",\"window_days\":1},\
             {\"metric\":\"heartRate\",\"window_days\":1},\
             {\"metric\":\"bodyMass\",\"window_days\":1},\
             {\"metric\":\"vo2Max\",\"window_days\":1},\
             {\"metric\":\"restingHeartRate\",\"window_days\":1}]}",
            // unknown field
            "JESSE_NEEDS_HEALTH v1 {\"section\":[\"daily\"]}",
        ] {
            let (text, directives) = extract_directives(reply);
            assert_eq!(text, reply, "invalid payload stays visible: {reply:?}");
            assert!(directives.is_none(), "no field for invalid: {reply:?}");
        }
    }

    #[test]
    fn window_boundaries_are_accepted() {
        for window in [1u32, 31] {
            let reply = format!(
                "JESSE_NEEDS_HEALTH v1 {{\"metrics\":[{{\"metric\":\"stepCount\",\"window_days\":{window}}}]}}"
            );
            let nh = needs_health(&reply).expect("boundary window accepted");
            assert_eq!(nh.metrics[0].window_days, window);
        }
    }

    #[test]
    fn max_metrics_are_accepted_at_the_cap() {
        let reply = "JESSE_NEEDS_HEALTH v1 {\"metrics\":[\
             {\"metric\":\"stepCount\",\"window_days\":1},\
             {\"metric\":\"heartRate\",\"window_days\":1},\
             {\"metric\":\"bodyMass\",\"window_days\":1},\
             {\"metric\":\"vo2Max\",\"window_days\":1}]}";
        let nh = needs_health(reply).expect("exactly the cap is accepted");
        assert_eq!(nh.metrics.len(), MAX_NEEDS_HEALTH_METRICS);
    }

    #[test]
    fn over_cap_line_passes_through_visible() {
        // A directive-shaped final line over the byte cap is not parsed.
        let filler = "x".repeat(MAX_DIRECTIVE_LINE_BYTES);
        let reply = format!("JESSE_NEEDS_HEALTH v1 {{\"note\":\"{filler}\"}}");
        assert!(reply.len() > MAX_DIRECTIVE_LINE_BYTES);
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn all_whitelisted_metrics_are_accepted() {
        for metric in NEEDS_HEALTH_METRICS {
            let reply = format!(
                "JESSE_NEEDS_HEALTH v1 {{\"metrics\":[{{\"metric\":\"{metric}\",\"window_days\":7}}]}}"
            );
            let nh = needs_health(&reply).unwrap_or_else(|| panic!("metric {metric} must parse"));
            assert_eq!(nh.metrics[0].metric, *metric);
        }
    }

    #[test]
    fn directives_to_value_round_trips_and_nulls() {
        assert_eq!(directives_to_value(&None), Value::Null);
        let d = Directives {
            needs_health: Some(NeedsHealth {
                sections: vec!["daily".into()],
                metrics: vec![MetricRequest {
                    metric: "restingHeartRate".into(),
                    window_days: 14,
                }],
            }),
            meal_log: None,
        };
        let v = directives_to_value(&Some(d));
        assert_eq!(v["needs_health"]["sections"][0], "daily");
        assert_eq!(v["needs_health"]["metrics"][0]["metric"], "restingHeartRate");
        assert_eq!(v["needs_health"]["metrics"][0]["window_days"], 14);
        // needs_health-only Directives omit the meal_log key entirely.
        assert!(v.get("meal_log").is_none());
    }

    #[test]
    fn meal_log_directives_to_value_omits_absent_macros() {
        // A meal_log-only Directives serializes under `meal_log`, with the
        // needs_health key omitted and any absent macro left OFF the wire.
        let d = Directives {
            needs_health: None,
            meal_log: Some(MealLog {
                meals: vec![Meal {
                    id: "2026-07-04-lunch".into(),
                    consumed_at: "2026-07-04T12:30:00+02:00".into(),
                    name: "Lunch".into(),
                    kcal: Some(385.0),
                    protein_g: None,
                    carbs_g: None,
                    fat_g: Some(4.5),
                }],
            }),
        };
        let v = directives_to_value(&Some(d));
        assert!(v.get("needs_health").is_none());
        let meal = &v["meal_log"]["meals"][0];
        assert_eq!(meal["id"], "2026-07-04-lunch");
        assert_eq!(meal["consumedAt"], "2026-07-04T12:30:00+02:00");
        assert_eq!(meal["kcal"], 385.0);
        assert_eq!(meal["fat_g"], 4.5);
        assert!(meal.get("protein_g").is_none(), "absent macro omitted, not null");
        assert!(meal.get("carbs_g").is_none());
    }

    #[test]
    fn empty_vecs_are_omitted_on_the_wire() {
        // sections present, metrics empty → the `metrics` key is omitted.
        let d = Directives {
            needs_health: Some(NeedsHealth {
                sections: vec!["daily".into()],
                metrics: vec![],
            }),
            meal_log: None,
        };
        let v = directives_to_value(&Some(d));
        assert!(v["needs_health"].get("metrics").is_none());
        assert_eq!(v["needs_health"]["sections"][0], "daily");
    }

    #[test]
    fn apply_directives_threads_through_ok_and_err() {
        // Ok: strips + attaches.
        let ok = apply_directives(Ok((
            "answer\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}".into(),
            Some("sess-1".into()),
        )))
        .unwrap();
        assert_eq!(ok.0, "answer");
        assert_eq!(ok.1.as_deref(), Some("sess-1"));
        assert!(ok.2.unwrap().needs_health.is_some());
        // Err: passed through unchanged.
        let err = apply_directives(Err((StatusCode::BAD_GATEWAY, "boom".into())));
        assert!(err.is_err());
    }

    #[test]
    fn needs_health_line_over_its_2kib_cap_passes_through() {
        // A needs_health line that is otherwise VALID (every section is
        // whitelisted, no unknown fields) but exceeds the per-directive 2 KiB cap
        // must pass through visible — the per-arm cap fires BEFORE the payload
        // parse, so it is never stripped despite parsing cleanly. This proves the
        // cap is enforced per-directive, not by the (now 8 KiB) generic ceiling.
        let many = std::iter::repeat_n("\"daily\"", 400).collect::<Vec<_>>().join(",");
        let reply = format!("JESSE_NEEDS_HEALTH v1 {{\"sections\":[{many}]}}");
        assert!(
            reply.len() > MAX_NEEDS_HEALTH_LINE_BYTES && reply.len() < MAX_DIRECTIVE_LINE_BYTES,
            "line must sit between the needs_health cap and the generic ceiling"
        );
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    // ---- JESSE_MEAL_LOG v1 parser matrix -----------------------------------

    fn meal_log(reply: &str) -> Option<MealLog> {
        extract_directives(reply).1.and_then(|d| d.meal_log)
    }

    #[test]
    fn meal_log_full_meal_is_parsed_and_stripped() {
        let reply = "Logged.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"2026-07-04-lunch\",\
            \"consumedAt\":\"2026-07-04T12:30:00+02:00\",\"name\":\"Lunch: spaghetti, red sauce\",\
            \"kcal\":385,\"protein_g\":13,\"carbs_g\":77,\"fat_g\":4.5}]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, "Logged.", "the meal line is stripped, prose kept");
        let ml = directives.unwrap().meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1);
        let m = &ml.meals[0];
        assert_eq!(m.id, "2026-07-04-lunch");
        assert_eq!(m.consumed_at, "2026-07-04T12:30:00+02:00");
        assert_eq!(m.name, "Lunch: spaghetti, red sauce");
        assert_eq!(m.kcal, Some(385.0));
        assert_eq!(m.protein_g, Some(13.0));
        assert_eq!(m.carbs_g, Some(77.0));
        assert_eq!(m.fat_g, Some(4.5));
    }

    #[test]
    fn meal_log_missing_optional_macros_ok() {
        // Only the three required fields — every macro omitted → all None.
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"Apple\"}]}";
        let m = meal_log(reply).unwrap().meals.remove(0);
        assert_eq!(m.name, "Apple");
        assert!(m.kcal.is_none() && m.protein_g.is_none() && m.carbs_g.is_none() && m.fat_g.is_none());
    }

    #[test]
    fn meal_log_multi_meal_array_in_order() {
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[\
            {\"id\":\"b\",\"consumedAt\":\"t1\",\"name\":\"Oatmeal\",\"kcal\":300},\
            {\"id\":\"l\",\"consumedAt\":\"t2\",\"name\":\"Salad\",\"kcal\":250}]}";
        let ml = meal_log(reply).unwrap();
        assert_eq!(ml.meals.len(), 2);
        assert_eq!(ml.meals[0].id, "b");
        assert_eq!(ml.meals[1].id, "l");
    }

    #[test]
    fn meal_log_integer_and_float_macros_both_parse() {
        // JSON ints (385) and floats (4.5) both decode to f64.
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":0,\"fat_g\":0.5}]}";
        let m = meal_log(reply).unwrap().meals.remove(0);
        assert_eq!(m.kcal, Some(0.0), "zero is a valid non-negative macro");
        assert_eq!(m.fat_g, Some(0.5));
    }

    #[test]
    fn meal_log_v2_passes_through_visible() {
        // Unknown version of a known directive → passthrough (future bump fails loud).
        let reply = "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn meal_log_malformed_payloads_pass_through_visible() {
        for reply in [
            // not JSON
            "JESSE_MEAL_LOG v1 not-json",
            // missing meals key
            "JESSE_MEAL_LOG v1 {}",
            // meals not an array
            "JESSE_MEAL_LOG v1 {\"meals\":\"lunch\"}",
            // empty meals array
            "JESSE_MEAL_LOG v1 {\"meals\":[]}",
            // unknown top-level field
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}],\"extra\":1}",
            // meal entry not an object
            "JESSE_MEAL_LOG v1 {\"meals\":[\"lunch\"]}",
            // missing required id
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"consumedAt\":\"t\",\"name\":\"n\"}]}",
            // missing required consumedAt
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"name\":\"n\"}]}",
            // missing required name
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\"}]}",
            // empty (blank) required field
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"  \",\"consumedAt\":\"t\",\"name\":\"n\"}]}",
            // unknown meal field
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"sodium_mg\":5}]}",
            // macro not a number
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":\"lots\"}]}",
            // macro explicitly null (contract says omit, never null-pad)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":null}]}",
            // negative macro
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":-5}]}",
        ] {
            let (text, directives) = extract_directives(reply);
            assert_eq!(text, reply, "malformed meal_log stays visible: {reply:?}");
            assert!(directives.is_none(), "no field for malformed meal_log: {reply:?}");
        }
    }

    #[test]
    fn meal_log_over_meals_cap_passes_through_visible() {
        // MAX_MEALS + 1 entries → the whole block is malformed (never partial).
        let one = "{\"id\":\"x\",\"consumedAt\":\"t\",\"name\":\"n\"}";
        let meals = std::iter::repeat_n(one, MAX_MEALS + 1).collect::<Vec<_>>().join(",");
        let reply = format!("JESSE_MEAL_LOG v1 {{\"meals\":[{meals}]}}");
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn meal_log_at_meals_cap_is_accepted() {
        let one = "{\"id\":\"x\",\"consumedAt\":\"t\",\"name\":\"n\"}";
        let meals = std::iter::repeat_n(one, MAX_MEALS).collect::<Vec<_>>().join(",");
        let reply = format!("JESSE_MEAL_LOG v1 {{\"meals\":[{meals}]}}");
        let ml = meal_log(&reply).expect("exactly the cap is accepted");
        assert_eq!(ml.meals.len(), MAX_MEALS);
    }

    #[test]
    fn meal_log_over_its_8kib_line_cap_passes_through_visible() {
        // A valid-shaped meal line padded past the 8 KiB cap is not parsed.
        let long_name = "x".repeat(MAX_MEAL_LOG_LINE_BYTES);
        let reply = format!(
            "JESSE_MEAL_LOG v1 {{\"meals\":[{{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"{long_name}\"}}]}}"
        );
        assert!(reply.len() > MAX_MEAL_LOG_LINE_BYTES);
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }
}
