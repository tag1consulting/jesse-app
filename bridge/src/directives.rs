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

/// Max meals one `JESSE_MEAL_LOG` directive may carry. Over this the whole
/// block is treated as malformed (passthrough + log), never partially logged.
pub const MAX_MEALS: usize = 10;

/// Max ids one `JESSE_MEAL_LOG v2` directive (or one `POST /jesse/meal-corrections`
/// batch) may `retract`. Over this the whole block is malformed (passthrough + log),
/// mirroring the `meals` cap — a retract batch is never partially applied.
pub const MAX_RETRACT: usize = 10;

/// The optional macro fields a meal may carry, and the only keys (besides the
/// required `id`/`consumedAt`/`name`) allowed on a meal object. A typo'd or extra
/// key is a loud failure, mirroring the needs-health payload's unknown-key check.
/// The NON-nutrient keys a meal object may carry. The nutrient keys come from the ONE
/// nutrient table ([`dietlog::NUTRIENT_COLUMNS`]) via [`is_meal_field`], so this file
/// keeps no second list of them — and a nutrient with no wire field (omega-3, which
/// has no HealthKit EPA/DHA quantity) stays an UNKNOWN key here by construction.
const MEAL_CORE_FIELDS: &[&str] = &[
    "id",
    "consumedAt",
    "name",
    "kcal",
    "protein_g",
    "carbs_g",
    "fat_g",
];

/// Whether `key` is an allowed meal-object field: a core field, or the wire key of a
/// nutrient that HAS a wire field.
fn is_meal_field(key: &str) -> bool {
    MEAL_CORE_FIELDS.contains(&key)
        || dietlog::NUTRIENT_COLUMNS
            .iter()
            .any(|c| c.wire == Some(key))
}

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fiber_g: Option<f64>,
    /// The four micronutrients, each pre-summed by the bridge over ONLY the meal's
    /// items that carried a known value — absent when none did (`None` serializes as
    /// an omitted key, never `Some(0)`). Wire names match the app's `JesseMeal`
    /// decoder exactly: `sodium_mg`/`potassium_mg` in mg, `satfat_g`/`sugar_g` in g.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sodium_mg: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub satfat_g: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sugar_g: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub potassium_mg: Option<f64>,
    /// The two newest HealthKit-bound micros, same pre-summed / omit-when-unknown
    /// discipline. `calcium_mg`/`magnesium_mg` are milligrams. Omega-3 has no HealthKit
    /// type, so there is deliberately no `omega3_mg` field here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calcium_mg: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub magnesium_mg: Option<f64>,
}

/// The parsed payload of a `JESSE_MEAL_LOG` directive, plus the corrections-queue
/// delivery envelope. Under **v1** it is exactly `meals` (a non-empty, capped array
/// the app inserts). Under **v2** it gains `retract` (ids whose Health entries the app
/// deletes and tombstones) and, when this block was assembled at delivery from the
/// persisted corrections queue, `corrections_seq` (the highest queued batch seq the
/// app must ack so the bridge can prune). The two v2 fields are additive and
/// `skip_serializing_if`-omitted, so a v1 delivery is byte-for-byte today's wire and an
/// old app build simply ignores keys it does not know.
///
/// **v2 semantics are field-agnostic over the nutrient set** ([`Meal`]): upsert and
/// rewrite are defined over every nutrient field present on the meal, never a frozen
/// list, so a future nutrient is an additive optional field, not a v3.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MealLog {
    pub meals: Vec<Meal>,
    /// v2: ids the source deleted — the app removes their Health entry and tombstones
    /// the id. Empty (and omitted on the wire) for a v1 block. Capped at [`MAX_RETRACT`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retract: Vec<String>,
    /// Delivery-only: the highest corrections-queue batch seq merged into this payload.
    /// `None` (omitted) for a block extracted purely from a turn's reply; `Some(seq)`
    /// once queued batches were merged in, so the app knows which seq to ack.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corrections_seq: Option<u64>,
}

// ---- WHAT A MODEL BELOW `Write` CAN CAUSE THROUGH THIS CHANNEL ----------------
//
// The bridge parses a directive off the FINAL LINE of a reply and acts on it itself, so
// this channel is not covered by the model's `level`: a model granted no write TOOLS can
// still reach these effects by emitting text. That is deliberate (a level describes what
// the MODEL may touch, not what the bridge may do with validated output), and the decision
// to leave it ungated should be taken against the actual list rather than the category.
//
// THE LIST IS EXACTLY TWO DIRECTIVES, AND NEITHER WRITES THE VAULT.
//
// 1. `JESSE_NEEDS_HEALTH` → [`NeedsHealth`]. Effect: the reply carries a request for health
//    context, and the APP answers it by including that context on a subsequent turn.
//    Mutation caused: NONE, on either side. It moves data toward the model, which is a
//    disclosure question (the app decides what it sends), not a write.
//
// 2. `JESSE_MEAL_LOG` → [`MealLog`]. Effect: the APP writes the named meals into Apple
//    Health, and (v2 `retract`) deletes previously written Health entries by id. Mutation
//    caused: HealthKit entries on the user's device. Still NOT a vault write — nothing in
//    the bridge appends a CSV, touches a note, or runs a vault script off a directive. The
//    vault-side diet path is the separate extract/verify pipeline, which is gated on the
//    extracting model's level (see `routing::skips_verification`) and never reads a
//    directive.
//
// WHAT STANDS BETWEEN THE MODEL'S OUTPUT AND EACH EFFECT, in order:
//
//   * SHAPE. Only the last non-empty line is a candidate, and only if it starts with
//     `JESSE_`. Anything else is returned untouched with no parsing at all.
//   * SIZE. A directive-shaped line over [`MAX_DIRECTIVE_LINE_BYTES`] is passed through
//     VISIBLE and logged rather than parsed — loud failure over silent loss.
//   * PARSE. The payload must be valid JSON of the declared shape. A failure is passthrough
//     plus a log; a half-parsed directive is never applied.
//   * UNKNOWN KEYS ARE FATAL, per object. A typo'd or extra key rejects the WHOLE block
//     rather than being ignored, so a model cannot smuggle a field past the contract.
//   * CAPS. [`MAX_MEALS`] meals and [`MAX_RETRACT`] retractions per block; over either, the
//     whole block is malformed and NOTHING is applied — never a partial batch.
//   * FIELD VALIDATION. `id`, `consumedAt` and `name` must each be present, a string, and
//     non-empty after trimming; every present macro must be a finite non-negative number.
//     `consumedAt` is checked here only for presence — the APP parses the ISO-8601 offset
//     strictly before writing, so the bridge's check is defense in depth rather than the
//     authority on date shape.
//   * IDEMPOTENCY. `id` is a stable key (date + meal slot) the app dedupes on, so a repeated
//     directive converges rather than duplicating.
//
// THE RESIDUAL EXPOSURE, stated plainly: a model at any level can cause well-formed,
// capped, deduplicated HEALTH entries to be written or retracted on the phone by emitting
// a final line. It cannot exceed ten per turn, cannot invent a field, and cannot reach the
// vault. Whether that warrants gating by level is a decision for whoever owns the
// deployment; this comment exists so the decision is taken against the list above.

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

/// What a reply's final line turned out to be. Decided ONCE, by
/// [`classify_final_line`], so the two readers of a reply — delivery
/// ([`extract_directives`]) and hydration ([`delivered_text`]) — cannot disagree
/// about what counts as a directive.
enum FinalLine {
    /// Not a directive candidate at all: a normal reply. Text is untouched, and
    /// nothing is logged (this is the overwhelmingly common case).
    Plain,
    /// Directive-SHAPED but not honored, carrying the diagnostic to log. The text
    /// is passed through untouched and VISIBLE — a loud contract failure, never a
    /// silent strip. Only delivery logs it; hydration re-reads the same reply on
    /// every poll and would otherwise repeat the diagnostic forever.
    Unhonored(String),
    /// A known directive that parsed and validated: the line is stripped.
    Honored(Directives),
}

/// Classify a reply's final non-empty line. Pure — no logging, no allocation of
/// the reply — so both the delivery path and the hydration path can ask the same
/// question and get the same answer.
///
/// Exactly one directive line is recognized per reply: the final non-empty one.
fn classify_final_line(reply: &str) -> FinalLine {
    // The candidate is the last non-empty line. `trim_end` drops any trailing
    // blank lines so the directive can sit under trailing newlines.
    let trimmed_reply = reply.trim_end();
    let last_line = match trimmed_reply.rsplit('\n').next() {
        Some(l) => l.trim(),
        None => return FinalLine::Plain,
    };

    // Fast path: only a `JESSE_`-prefixed final line is ever a directive
    // candidate. A normal reply is returned untouched with no logging.
    if !last_line.starts_with("JESSE_") {
        return FinalLine::Plain;
    }

    // Over-cap: a directive-shaped final line that is too long is not parsed —
    // pass it through visible (loud failure over silent loss).
    if last_line.len() > MAX_DIRECTIVE_LINE_BYTES {
        return FinalLine::Unhonored(format!(
            "final line looks like a directive but exceeds the \
             {MAX_DIRECTIVE_LINE_BYTES}-byte cap — passing through untouched"
        ));
    }

    // Shape: `JESSE_<NAME> v<N> {json}`.
    let Some((name, version, json)) = parse_directive_shape(last_line) else {
        return FinalLine::Unhonored(
            "final line starts with JESSE_ but is not a valid \
             `JESSE_<NAME> v<N> {json}` directive — passing through untouched"
                .to_string(),
        );
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
                return FinalLine::Unhonored(format!(
                    "JESSE_NEEDS_HEALTH v1 exceeds its \
                     {MAX_NEEDS_HEALTH_LINE_BYTES}-byte cap — passing through untouched"
                ));
            }
            match parse_needs_health(json) {
                Ok(needs_health) => FinalLine::Honored(Directives {
                    needs_health: Some(needs_health),
                    meal_log: None,
                }),
                Err(reason) => FinalLine::Unhonored(format!(
                    "JESSE_NEEDS_HEALTH v1 payload rejected ({reason}) — \
                     passing through untouched"
                )),
            }
        }
        ("JESSE_MEAL_LOG", ver @ (1 | 2)) => {
            if last_line.len() > MAX_MEAL_LOG_LINE_BYTES {
                return FinalLine::Unhonored(format!(
                    "JESSE_MEAL_LOG v{ver} exceeds its \
                     {MAX_MEAL_LOG_LINE_BYTES}-byte cap — passing through untouched"
                ));
            }
            // v1: `meals` only (retract is an unknown key → malformed). v2: `meals`
            // upserts plus optional `retract`. Both share one 8 KiB cap and the same
            // per-meal validation; the version only selects which top-level shape is legal.
            let parsed = if ver == 1 {
                parse_meal_log_v1(json)
            } else {
                parse_meal_log_v2(json)
            };
            match parsed {
                Ok(meal_log) => FinalLine::Honored(Directives {
                    needs_health: None,
                    meal_log: Some(meal_log),
                }),
                Err(reason) => FinalLine::Unhonored(format!(
                    "JESSE_MEAL_LOG v{ver} payload rejected ({reason}) — \
                     passing through untouched"
                )),
            }
        }
        _ => FinalLine::Unhonored(format!(
            "unknown directive `{name} v{version}` — passing through \
             untouched (visible contract failure)"
        )),
    }
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
    match classify_final_line(reply) {
        FinalLine::Plain => (reply.to_string(), None),
        FinalLine::Unhonored(reason) => {
            eprintln!("directive: {reason}");
            (reply.to_string(), None)
        }
        FinalLine::Honored(directives) => (strip_final_line(reply), Some(directives)),
    }
}

/// The assistant text the USER ends up seeing for a reply, derived from the raw
/// model output. The one place that answer is defined.
///
/// Delivery and hydration are two views of the same reply and the app binds a
/// delivered turn to its hydrated twin by exact text equality
/// (`TranscriptMerge.matchKey` is role + trimmed text and nothing else). So any
/// transformation applied on one path and not the other splits one turn into two
/// bubbles. Two transformations are in that class:
///
/// - the **directive line**, stripped on delivery by [`extract_directives`];
/// - a **`SPOKEN:` line**, which the bridge asks for on voice turns (see
///   `prompt.rs`) and every client drops from the body via `JesseReply.displayText`.
///
/// Both are emitted by the model, so both are in the transcript, and hydration has
/// to remove them to land on the same string. The model badge is deliberately NOT
/// handled here: the bridge appends it AFTER the model, so it never reaches the
/// transcript, and the client strips it from the delivered copy — net zero on both
/// sides already.
///
/// Kept byte-compatible with `displayText`: lines are matched case-insensitively
/// after leading horizontal whitespace, and the result is trimmed.
pub fn delivered_text(raw: &str) -> String {
    // Reuse the ONE definition of what counts as a directive. Classification is
    // silent here on purpose: hydration re-reads every historical reply on every
    // poll, so logging an unhonored directive from this path would repeat that
    // diagnostic for the life of the conversation. Delivery already logged it once.
    let stripped = match classify_final_line(raw) {
        FinalLine::Honored(_) => strip_final_line(raw),
        FinalLine::Plain | FinalLine::Unhonored(_) => raw.to_string(),
    };
    strip_spoken_lines(&stripped)
}

/// The `SPOKEN:` marker, matched case-insensitively. Mirrors
/// `JesseReply.displayText`'s `marker`.
const SPOKEN_MARKER: &str = "SPOKEN:";

/// Drop every `SPOKEN:` line, mirroring `JesseReply.displayText`: split on `\n`
/// keeping empty lines, filter, rejoin, then trim the ends.
fn strip_spoken_lines(text: &str) -> String {
    text.split('\n')
        .filter(|line| !is_spoken_line(line))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// Whether a line is a `SPOKEN:` line, matching the client's test: leading
/// HORIZONTAL whitespace ignored, then a case-insensitive `SPOKEN:` prefix.
fn is_spoken_line(line: &str) -> bool {
    // `get(..n)` yields None for a short line AND for an index that would split a
    // multi-byte char, so it is the whole bounds check.
    line.trim_start_matches(is_horizontal_whitespace)
        .get(..SPOKEN_MARKER.len())
        .is_some_and(|head| head.eq_ignore_ascii_case(SPOKEN_MARKER))
}

/// Swift's `CharacterSet.whitespaces` — tab plus the Unicode space separators —
/// and deliberately NOT Rust's `char::is_whitespace`, which also covers CR, form
/// feed, vertical tab and NEL. Matching the client's set is what keeps this
/// function's output equal to `displayText`'s on the same input.
fn is_horizontal_whitespace(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}'))
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
/// `name`, plus any of the optional numeric nutrients. Any violation is an
/// `Err(reason)` the caller logs and passes through — a bad block never becomes a
/// partial or wrong meal write (visible failure over silent data loss). A `retract`
/// key is not part of v1, so it lands in the unknown-key check → malformed passthrough.
fn parse_meal_log_v1(json: &str) -> Result<MealLog, String> {
    let value: Value = serde_json::from_str(json).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;

    // Reject unknown top-level keys so a typo (e.g. "meal") — or a v2-only `retract`
    // key on a v1 line — is a loud failure rather than silently logging nothing.
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
        return Err(format!(
            "`meals` has {} entries, cap is {MAX_MEALS}",
            items.len()
        ));
    }

    let mut meals = Vec::with_capacity(items.len());
    for item in items {
        meals.push(parse_meal(item)?);
    }
    Ok(MealLog {
        meals,
        retract: Vec::new(),
        corrections_seq: None,
    })
}

/// Parse + validate the JSON payload of a `JESSE_MEAL_LOG v2` directive:
/// `{"meals":[…],"retract":[…]}`. Delegates the shape to [`parse_meal_batch_v2`]
/// (shared byte-for-byte with the `POST /jesse/meal-corrections` endpoint) and wraps
/// the result in a [`MealLog`] with no `corrections_seq` (that is stamped only at
/// delivery, when queued batches are merged in).
fn parse_meal_log_v2(json: &str) -> Result<MealLog, String> {
    let value: Value = serde_json::from_str(json).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;
    let (meals, retract) = parse_meal_batch_v2(obj)?;
    Ok(MealLog {
        meals,
        retract,
        corrections_seq: None,
    })
}

/// Parse + validate the **v2 meal-batch shape** shared by the `JESSE_MEAL_LOG v2`
/// directive and the `POST /jesse/meal-corrections` endpoint body:
///
/// - `meals` (optional; default empty) — upserts, cap [`MAX_MEALS`], each validated
///   exactly as v1 ([`parse_meal`]: required strings + finite non-negative nutrients).
/// - `retract` (optional; default empty) — ids the source deleted, cap [`MAX_RETRACT`],
///   each a non-empty string.
/// - **At least one** of `meals`/`retract` must be non-empty (an empty batch is nothing
///   to do → malformed).
/// - **No id may appear in both** arrays in one batch — a meal move arrives as a retract
///   of the old id plus an upsert of the NEW id, so a collision is malformed
///   (passthrough + log), never applied.
///
/// Unknown top-level keys are rejected (loud failure over a silent drop). Returned as a
/// tuple so the endpoint can enqueue it and the directive path can wrap it in a
/// [`MealLog`]; the validation is defined once here.
pub fn parse_meal_batch_v2(
    obj: &serde_json::Map<String, Value>,
) -> Result<(Vec<Meal>, Vec<String>), String> {
    for key in obj.keys() {
        if key != "meals" && key != "retract" {
            return Err(format!("unknown field {key:?}"));
        }
    }

    let meals = match obj.get("meals") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            if items.len() > MAX_MEALS {
                return Err(format!(
                    "`meals` has {} entries, cap is {MAX_MEALS}",
                    items.len()
                ));
            }
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                out.push(parse_meal(item)?);
            }
            out
        }
        Some(_) => return Err("`meals` is not an array".into()),
    };

    let retract = match obj.get("retract") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => {
            if items.len() > MAX_RETRACT {
                return Err(format!(
                    "`retract` has {} entries, cap is {MAX_RETRACT}",
                    items.len()
                ));
            }
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let s = item
                    .as_str()
                    .ok_or("retract entry is not a string")?
                    .to_string();
                if s.trim().is_empty() {
                    return Err("retract entry is empty".into());
                }
                out.push(s);
            }
            out
        }
        Some(_) => return Err("`retract` is not an array".into()),
    };

    if meals.is_empty() && retract.is_empty() {
        return Err("at least one of `meals`/`retract` must be present".into());
    }

    // A meal move is retract-old + upsert-new; the SAME id in both arrays is malformed.
    for m in &meals {
        if retract.iter().any(|r| r == &m.id) {
            return Err(format!(
                "id {:?} appears in both `meals` and `retract`",
                m.id
            ));
        }
    }

    Ok((meals, retract))
}

/// Parse + validate one meal object. Enforces the required string fields, rejects
/// unknown keys, and validates each present macro as a finite non-negative
/// number. `consumedAt` is checked only for presence/non-emptiness here — the app
/// parses the ISO-8601 offset strictly before writing, so this is defense in
/// depth, not the authority on date shape (the bridge has no date library).
fn parse_meal(item: &Value) -> Result<Meal, String> {
    let m = item.as_object().ok_or("meal entry is not an object")?;
    for key in m.keys() {
        if !is_meal_field(key.as_str()) {
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
        fiber_g: optional_macro(m, "fiber_g")?,
        sodium_mg: optional_macro(m, "sodium_mg")?,
        satfat_g: optional_macro(m, "satfat_g")?,
        sugar_g: optional_macro(m, "sugar_g")?,
        potassium_mg: optional_macro(m, "potassium_mg")?,
        calcium_mg: optional_macro(m, "calcium_mg")?,
        magnesium_mg: optional_macro(m, "magnesium_mg")?,
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
        let reply =
            "JESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}\nBut actually here is your answer.";
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
            "JESSE_NEEDS_HEALTH v1 not-json",                // remainder not an object
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
        assert_eq!(
            v["needs_health"]["metrics"][0]["metric"],
            "restingHeartRate"
        );
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
                    fiber_g: Some(6.0),
                    sodium_mg: Some(410.0),
                    satfat_g: None,
                    sugar_g: None,
                    potassium_mg: None,
                    calcium_mg: Some(60.0),
                    magnesium_mg: None,
                }],
                retract: Vec::new(),
                corrections_seq: None,
            }),
        };
        let v = directives_to_value(&Some(d));
        assert!(v.get("needs_health").is_none());
        let meal = &v["meal_log"]["meals"][0];
        assert_eq!(meal["id"], "2026-07-04-lunch");
        assert_eq!(meal["consumedAt"], "2026-07-04T12:30:00+02:00");
        assert_eq!(meal["kcal"], 385.0);
        assert_eq!(meal["fat_g"], 4.5);
        assert_eq!(meal["fiber_g"], 6.0);
        assert_eq!(
            meal["sodium_mg"], 410.0,
            "known micronutrient under its wire key"
        );
        assert_eq!(meal["calcium_mg"], 60.0, "known calcium under its wire key");
        assert!(
            meal.get("protein_g").is_none(),
            "absent macro omitted, not null"
        );
        assert!(meal.get("carbs_g").is_none());
        assert!(
            meal.get("satfat_g").is_none()
                && meal.get("sugar_g").is_none()
                && meal.get("potassium_mg").is_none()
                && meal.get("magnesium_mg").is_none(),
            "absent micronutrients omitted, not null"
        );
    }

    #[test]
    fn meal_log_parses_all_four_micronutrients() {
        // A meal carrying the wire micronutrients (the four originals plus the two
        // HealthKit-bound newcomers calcium_mg/magnesium_mg) decodes each (a measured-
        // zero sugar included), and an absent one is None — never 0.
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"Prosciutto\",\
            \"sodium_mg\":900,\"satfat_g\":2.5,\"sugar_g\":0,\"potassium_mg\":180,\"calcium_mg\":8,\"magnesium_mg\":20}]}";
        let m = meal_log(reply).unwrap().meals.remove(0);
        assert_eq!(m.sodium_mg, Some(900.0));
        assert_eq!(m.satfat_g, Some(2.5));
        assert_eq!(
            m.sugar_g,
            Some(0.0),
            "zero is a valid measured micronutrient"
        );
        assert_eq!(m.potassium_mg, Some(180.0));
        assert_eq!(m.calcium_mg, Some(8.0));
        assert_eq!(m.magnesium_mg, Some(20.0));

        // Subset present: the omitted ones stay None.
        let reply2 = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"calcium_mg\":150}]}";
        let m2 = meal_log(reply2).unwrap().meals.remove(0);
        assert_eq!(m2.calcium_mg, Some(150.0));
        assert!(
            m2.sodium_mg.is_none()
                && m2.satfat_g.is_none()
                && m2.sugar_g.is_none()
                && m2.potassium_mg.is_none()
                && m2.magnesium_mg.is_none()
        );

        // v2 accepts them identically (same parse_meal path).
        let v2 = "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"calcium_mg\":40,\"magnesium_mg\":12}],\"retract\":[\"old\"]}";
        let mv2 = meal_log(v2).unwrap().meals.remove(0);
        assert_eq!(mv2.calcium_mg, Some(40.0));
        assert_eq!(mv2.magnesium_mg, Some(12.0));

        // Omega-3 has NO HealthKit type, so `omega3_mg` is NOT a meal wire field: it is
        // an unknown key → the whole block is malformed and passes through visible.
        let o3 = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"omega3_mg\":50}]}";
        assert!(
            meal_log(o3).is_none(),
            "omega3_mg is not a meal field — rejected as an unknown key"
        );
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
    fn delivered_text_strips_a_directive_and_leaves_a_plain_reply_alone() {
        // The directive half is the SAME decision `extract_directives` makes — one
        // classifier, so the two can never disagree about what a directive is.
        assert_eq!(
            delivered_text("answer\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}"),
            "answer"
        );
        // A plain reply is untouched (beyond the trim).
        assert_eq!(delivered_text("just an answer"), "just an answer");
        // A directive-SHAPED line the registry does not know stays visible, matching
        // delivery's loud-failure behavior.
        let unknown = "answer\nJESSE_NOPE v1 {\"a\":1}";
        assert_eq!(delivered_text(unknown), unknown);
    }

    #[test]
    fn delivered_text_drops_spoken_lines_the_way_the_client_does() {
        // The client matches `SPOKEN:` case-insensitively, after leading horizontal
        // whitespace, and does not require a space after the colon. Mirror all three,
        // or a voice turn hydrates to text the app never rendered.
        assert_eq!(delivered_text("body\nSPOKEN: said aloud"), "body");
        assert_eq!(delivered_text("body\n  spoken: said aloud"), "body");
        assert_eq!(delivered_text("body\n\tSpOkEn:tight"), "body");
        // A SPOKEN: line is dropped wherever it sits, not only last.
        assert_eq!(delivered_text("SPOKEN: aloud\nbody"), "body");
        // A mention of the word mid-line is NOT a SPOKEN line.
        let prose = "he had spoken: quietly";
        assert_eq!(delivered_text(prose), prose);
        // Both transformations at once, directive last.
        assert_eq!(
            delivered_text(
                "body\nSPOKEN: aloud\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}"
            ),
            "body"
        );
        // A reply that is nothing but a directive collapses to empty — the app never
        // persists a turn for it, so hydration must not invent one.
        assert_eq!(
            delivered_text("JESSE_NEEDS_HEALTH v1 {\"sections\":[\"daily\"]}"),
            ""
        );
    }

    #[test]
    fn delivered_text_does_not_change_what_delivery_sends() {
        // `delivered_text` must NOT be wired into the delivery path: the bridge ships
        // the SPOKEN: line so the app and the watch have something to read aloud
        // (`JesseReply.spokenText`), and only the client drops it from the body.
        let raw = "body\nSPOKEN: aloud";
        let (delivered, _, _) = apply_directives(Ok((raw.to_string(), None))).unwrap();
        assert_eq!(
            delivered, raw,
            "delivery keeps SPOKEN: — dropping it here would silence voice"
        );
        assert_eq!(delivered_text(raw), "body", "hydration drops it");
    }

    #[test]
    fn needs_health_line_over_its_2kib_cap_passes_through() {
        // A needs_health line that is otherwise VALID (every section is
        // whitelisted, no unknown fields) but exceeds the per-directive 2 KiB cap
        // must pass through visible — the per-arm cap fires BEFORE the payload
        // parse, so it is never stripped despite parsing cleanly. This proves the
        // cap is enforced per-directive, not by the (now 8 KiB) generic ceiling.
        let many = std::iter::repeat_n("\"daily\"", 400)
            .collect::<Vec<_>>()
            .join(",");
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
            \"kcal\":385,\"protein_g\":13,\"carbs_g\":77,\"fat_g\":4.5,\"fiber_g\":6}]}";
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
        assert_eq!(m.fiber_g, Some(6.0));
    }

    #[test]
    fn meal_log_missing_optional_macros_ok() {
        // Only the three required fields — every macro omitted → all None.
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"Apple\"}]}";
        let m = meal_log(reply).unwrap().meals.remove(0);
        assert_eq!(m.name, "Apple");
        assert!(
            m.kcal.is_none()
                && m.protein_g.is_none()
                && m.carbs_g.is_none()
                && m.fat_g.is_none()
                && m.fiber_g.is_none()
        );
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
        let reply = "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":0,\"fat_g\":0.5,\"fiber_g\":0}]}";
        let m = meal_log(reply).unwrap().meals.remove(0);
        assert_eq!(m.kcal, Some(0.0), "zero is a valid non-negative macro");
        assert_eq!(m.fat_g, Some(0.5));
        assert_eq!(
            m.fiber_g,
            Some(0.0),
            "zero fiber is a valid non-negative macro"
        );
    }

    #[test]
    fn meal_log_v2_meals_only_is_parsed_and_stripped() {
        // v2 with only `meals` (no retract) parses like v1 — retract stays empty and
        // is omitted on the wire; corrections_seq is None (not a delivery-merged block).
        let reply = "Logged.\nJESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\
            \"name\":\"n\",\"kcal\":410,\"sodium_mg\":620}]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, "Logged.");
        let ml = directives.unwrap().meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].sodium_mg, Some(620.0));
        assert!(ml.retract.is_empty());
        assert_eq!(ml.corrections_seq, None);
    }

    #[test]
    fn meal_log_v2_with_retract_is_parsed() {
        // A meal move: retract the old id, upsert the new id, in one block.
        let reply = "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"2026-07-04-snack-1630\",\
            \"consumedAt\":\"2026-07-04T16:30:00+02:00\",\"name\":\"Snack\"}],\
            \"retract\":[\"2026-07-04-snack-1500\"]}";
        let ml = meal_log(reply).unwrap();
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].id, "2026-07-04-snack-1630");
        assert_eq!(ml.retract, vec!["2026-07-04-snack-1500"]);
    }

    #[test]
    fn meal_log_v2_retract_only_is_parsed() {
        // A pure source-side deletion: no upsert, just a retract. Valid under v2.
        let reply = "JESSE_MEAL_LOG v2 {\"retract\":[\"2026-07-04-snack-1630\"]}";
        let ml = meal_log(reply).unwrap();
        assert!(ml.meals.is_empty());
        assert_eq!(ml.retract, vec!["2026-07-04-snack-1630"]);
    }

    #[test]
    fn meal_log_v2_retract_serializes_and_absent_is_omitted() {
        // A v2 block with a retract round-trips the key; a v1/no-retract block omits it.
        let with = meal_log("JESSE_MEAL_LOG v2 {\"retract\":[\"x\"]}").unwrap();
        let v = serde_json::to_value(&with).unwrap();
        assert_eq!(v["retract"][0], "x");
        assert!(v.get("meals").is_some());
        // corrections_seq is delivery-only → omitted when None.
        assert!(v.get("corrections_seq").is_none());

        let without = meal_log(
            "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}]}",
        )
        .unwrap();
        let v2 = serde_json::to_value(&without).unwrap();
        assert!(v2.get("retract").is_none(), "empty retract omitted, not []");
    }

    #[test]
    fn meal_log_v3_and_up_passes_through_visible() {
        // An UNKNOWN version (v3 and up) of a known directive → passthrough (a future
        // bump fails loud and stays visible, never silently stripped).
        for reply in [
            "JESSE_MEAL_LOG v3 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}]}",
            "JESSE_MEAL_LOG v10 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}]}",
        ] {
            let (text, directives) = extract_directives(reply);
            assert_eq!(
                text, reply,
                "unknown meal_log version stays visible: {reply:?}"
            );
            assert!(directives.is_none());
        }
    }

    #[test]
    fn meal_log_v1_rejects_a_retract_key() {
        // `retract` is v2-only; on a v1 line it is an unknown top-level field → malformed.
        let reply =
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}],\
            \"retract\":[\"b\"]}";
        let (text, directives) = extract_directives(reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn meal_log_v2_malformed_payloads_pass_through_visible() {
        for reply in [
            // empty batch: neither meals nor retract
            "JESSE_MEAL_LOG v2 {}",
            "JESSE_MEAL_LOG v2 {\"meals\":[],\"retract\":[]}",
            // retract not an array
            "JESSE_MEAL_LOG v2 {\"retract\":\"x\"}",
            // retract entry not a string
            "JESSE_MEAL_LOG v2 {\"retract\":[5]}",
            // retract entry blank
            "JESSE_MEAL_LOG v2 {\"retract\":[\"  \"]}",
            // same id in both meals and retract (a move must use DIFFERENT ids)
            "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}],\"retract\":[\"a\"]}",
            // unknown top-level field
            "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\"}],\"note\":1}",
            // a bad meal inside a v2 block still fails the whole block
            "JESSE_MEAL_LOG v2 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":-1}]}",
        ] {
            let (text, directives) = extract_directives(reply);
            assert_eq!(text, reply, "malformed v2 meal_log stays visible: {reply:?}");
            assert!(directives.is_none(), "no field for malformed v2: {reply:?}");
        }
    }

    #[test]
    fn meal_log_v2_over_retract_cap_passes_through_visible() {
        let ids = std::iter::repeat_n("\"x\"", MAX_RETRACT + 1)
            .collect::<Vec<_>>()
            .join(",");
        let reply = format!("JESSE_MEAL_LOG v2 {{\"retract\":[{ids}]}}");
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn parse_meal_batch_v2_is_shared_with_the_endpoint_shape() {
        // The endpoint calls parse_meal_batch_v2 directly on a decoded object; prove the
        // same validation the directive uses holds there (meals+retract, caps, collision).
        let obj = serde_json::json!({
            "meals": [{"id":"new","consumedAt":"t","name":"n","sodium_mg":900}],
            "retract": ["old"],
        });
        let (meals, retract) = parse_meal_batch_v2(obj.as_object().unwrap()).unwrap();
        assert_eq!(meals.len(), 1);
        assert_eq!(meals[0].sodium_mg, Some(900.0));
        assert_eq!(retract, vec!["old"]);
        // collision rejected
        let bad = serde_json::json!({
            "meals": [{"id":"a","consumedAt":"t","name":"n"}],
            "retract": ["a"],
        });
        assert!(parse_meal_batch_v2(bad.as_object().unwrap()).is_err());
        // empty rejected
        let empty = serde_json::json!({});
        assert!(parse_meal_batch_v2(empty.as_object().unwrap()).is_err());
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
            // unknown meal field (a schema key like sodium_mg/calcium_mg would now parse,
            // but omega3_mg has no HealthKit type so it stays unknown → malformed)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"added_sugar_g\":5}]}",
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"omega3_mg\":50}]}",
            // negative micronutrient
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"sodium_mg\":-5}]}",
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"calcium_mg\":-5}]}",
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"magnesium_mg\":-1}]}",
            // micronutrient explicitly null (contract says omit, never null-pad)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"calcium_mg\":null}]}",
            // non-finite micronutrient (JSON has no NaN, but an out-of-f64-range literal is not finite)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"potassium_mg\":1e400}]}",
            // micronutrient not a number
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"satfat_g\":\"salty\"}]}",
            // micronutrient explicitly null (contract says omit, never null-pad)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"sugar_g\":null}]}",
            // macro not a number
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":\"lots\"}]}",
            // macro explicitly null (contract says omit, never null-pad)
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":null}]}",
            // negative macro
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"kcal\":-5}]}",
            // fiber not a number
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"fiber_g\":\"lots\"}]}",
            // negative fiber
            "JESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"a\",\"consumedAt\":\"t\",\"name\":\"n\",\"fiber_g\":-1}]}",
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
        let meals = std::iter::repeat_n(one, MAX_MEALS + 1)
            .collect::<Vec<_>>()
            .join(",");
        let reply = format!("JESSE_MEAL_LOG v1 {{\"meals\":[{meals}]}}");
        let (text, directives) = extract_directives(&reply);
        assert_eq!(text, reply);
        assert!(directives.is_none());
    }

    #[test]
    fn meal_log_at_meals_cap_is_accepted() {
        let one = "{\"id\":\"x\",\"consumedAt\":\"t\",\"name\":\"n\"}";
        let meals = std::iter::repeat_n(one, MAX_MEALS)
            .collect::<Vec<_>>()
            .join(",");
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

    // ---- Exhaustiveness over the directive registry -------------------------
    //
    // `Directives` is a struct of optional fields, not an enum, so nothing in the
    // language forces a new directive to be wired up end to end. These three
    // constructs restore that force:
    //
    //   1. `fields_set` destructures `Directives` EXHAUSTIVELY (no `..`), so
    //      adding a field breaks this build until the field is accounted for;
    //   2. `DirectiveField::label` matches EXHAUSTIVELY, so adding a variant
    //      breaks this build until it is named;
    //   3. `REGISTRY` mirrors the `match (name, version)` arms in
    //      `extract_directives`, and the tests below assert the two directions of
    //      coverage — every registry entry populates exactly its own field, and
    //      every field is reachable from some registry entry.
    //
    // Net effect: a directive that is declared but not recognized (a field with no
    // registry arm), or recognized but not declared, cannot land silently.

    /// Test-side mirror of one field of [`Directives`].
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum DirectiveField {
        NeedsHealth,
        MealLog,
    }

    impl DirectiveField {
        /// Every field, for the reachability direction below. Kept honest by
        /// `label`'s exhaustive match: a new variant cannot be added without
        /// touching this impl block.
        const ALL: &'static [DirectiveField] = &[Self::NeedsHealth, Self::MealLog];

        /// The wire field name. The match is exhaustive on purpose — a new
        /// `DirectiveField` variant stops compiling here until it is named.
        fn label(self) -> &'static str {
            match self {
                Self::NeedsHealth => "needs_health",
                Self::MealLog => "meal_log",
            }
        }
    }

    /// Which fields a `Directives` has set.
    ///
    /// The destructure is EXHAUSTIVE (no `..`) BY DESIGN: adding a field to
    /// `Directives` fails to compile here, which is the whole point — the new
    /// directive must then be added to `DirectiveField` and to `REGISTRY`, and the
    /// coverage tests below will not pass until it is genuinely recognized.
    fn fields_set(d: &Directives) -> Vec<DirectiveField> {
        let Directives {
            needs_health,
            meal_log,
        } = d;
        let mut set = Vec::new();
        if needs_health.is_some() {
            set.push(DirectiveField::NeedsHealth);
        }
        if meal_log.is_some() {
            set.push(DirectiveField::MealLog);
        }
        set
    }

    /// Every `(name, version)` pair the registry recognizes, with a MINIMAL payload
    /// that satisfies that directive's contract and the field it must populate. A
    /// new arm in `extract_directives` belongs here; the tests below fail if the
    /// two fall out of step.
    const REGISTRY: &[(&str, u32, &str, DirectiveField)] = &[
        (
            "JESSE_NEEDS_HEALTH",
            1,
            r#"{"sections":["daily"]}"#,
            DirectiveField::NeedsHealth,
        ),
        (
            "JESSE_MEAL_LOG",
            1,
            r#"{"meals":[{"id":"a","consumedAt":"t","name":"n"}]}"#,
            DirectiveField::MealLog,
        ),
        (
            "JESSE_MEAL_LOG",
            2,
            r#"{"meals":[{"id":"a","consumedAt":"t","name":"n"}]}"#,
            DirectiveField::MealLog,
        ),
    ];

    #[test]
    fn every_registry_entry_populates_exactly_its_own_field() {
        for (name, version, payload, expected) in REGISTRY {
            let reply = format!("prose\n\n{name} v{version} {payload}");
            let (text, directives) = extract_directives(&reply);
            assert_eq!(
                text, "prose",
                "{name} v{version} must strip its directive line"
            );
            let directives =
                directives.unwrap_or_else(|| panic!("{name} v{version} must attach a directive"));
            assert_eq!(
                fields_set(&directives),
                vec![*expected],
                "{name} v{version} must populate exactly `{}` and no other field",
                expected.label()
            );
        }
    }

    #[test]
    fn every_directives_field_is_reachable_from_the_registry() {
        // The other direction: a field declared on `Directives` that no registry
        // arm can ever populate is dead wire surface, not a directive.
        for field in DirectiveField::ALL {
            let reached = REGISTRY.iter().any(|(name, version, payload, f)| {
                f == field
                    && matches!(
                        extract_directives(&format!("{name} v{version} {payload}")).1,
                        Some(ref d) if fields_set(d).contains(field)
                    )
            });
            assert!(
                reached,
                "no registry entry populates `{}` — a directive field with no \
                 recognizer is unreachable by any reply",
                field.label()
            );
        }
    }

    #[test]
    fn a_directive_never_populates_more_than_one_field() {
        // The module contract: exactly one directive line is recognized per reply,
        // so a `Directives` carries exactly one field. Guards a future arm that
        // sets two fields from one line.
        for (name, version, payload, _) in REGISTRY {
            let directives = extract_directives(&format!("{name} v{version} {payload}"))
                .1
                .unwrap_or_else(|| panic!("{name} v{version} must attach a directive"));
            assert_eq!(
                fields_set(&directives).len(),
                1,
                "{name} v{version} set more than one directive field"
            );
        }
    }
}
