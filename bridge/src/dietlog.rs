//! The **local diet-logging pipeline** — the trusted-Rust path a food/exercise/
//! weigh-in "Tell" takes when a local diet-extract backend is configured
//! (`cfg.diet_backend` is `Some`; see [`config::resolve_diet_backend`]). It replaces
//! the hosted agent turn for the narrow, high-volume diet-logging case with a
//! cheaper, deterministic pipeline while keeping every safety property:
//!
//!   1. **Extract** — a stateless, toolless local child ([`claude::run_diet_extract`])
//!      parses the raw utterance into structured, PER-ITEM JSON entries.
//!   2. **Verify** — a hosted, ambient one-shot ([`claude::run_diet_verify`]) checks
//!      every entry (probation mode: blocking, 100%) before anything is written.
//!   3. **Append** — trusted Rust writes the verified rows RFC-4180-style to the
//!      correct `diet-logs/*.csv`, runs the three pinned node scripts, and commits.
//!   4. **Mirror** — the `JESSE_MEAL_LOG v1` directive is DERIVED by the bridge from
//!      the appended food rows: the turn's rows are GROUPED by (date, meal slot, time)
//!      into one mirror meal per group, each carrying the SAME deterministic id the
//!      hosted logging skill computes for those rows (`<date>-<slot lowercased>-<HHMM>`,
//!      recomputable from the CSV alone), with every nutrient summed in trusted Rust
//!      over the group's rows that carry a KNOWN value. Reusing the existing
//!      [`Meal`]/[`MealLog`] structs, the app decodes it unchanged. Model-side
//!      aggregation stays impossible by construction (the bridge sums, never the model),
//!      and because each id matches the hosted contract, a later correction or
//!      retraction routed through the hosted path targets the exact same Health entry.
//!
//! **Insert-only by design.** The local path logs NEW consumption only; it never
//! amends, moves, or retracts an already-logged entry. A correction turn is classified
//! `no_loggable_content` at extract and routed to the hosted turn (rung 2), whose
//! logging skill owns the correction contract — the deterministic per-meal ids above
//! are exactly what let that hosted correction find the mirror's Health entry.
//!
//! Every failure lands on a well-defined [`DietRung`]: rungs 1–4 fall through to the
//! hosted turn (a log is never lost and never double-appended — the append is atomic
//! per turn), rung 5 keeps the committed CSV but omits the mirror. The whole module
//! is dormant unless the env triple is set (the kill switch), so nothing here changes
//! runtime behavior until an operator opts in.
//!
//! Almost everything here is pure and unit-tested; the async orchestrator
//! ([`run_diet_pipeline`]) is a thin sequencer over the tested stages.

use crate::*;

// ---- Bounds ---------------------------------------------------------------

/// Max entries one extract may carry. Aligned with [`directives::MAX_MEALS`] so a
/// per-item mirror can never exceed the directive cap by construction.
pub const MAX_DIET_ENTRIES: usize = MAX_MEALS;

/// Extract timeout (seconds). Tighter than a turn but looser than a title: the
/// local model must parse a multi-item utterance into structured JSON, which is a
/// heavier ask than a one-line title but far lighter than an agent turn. 60s gives
/// a slow local backend headroom while still bounding the child; on overrun the
/// pipeline degrades to the hosted turn (ladder rung 2).
pub const DIET_EXTRACT_TIMEOUT_SECS: u64 = 60;

/// Verify timeout (seconds). The hosted verify is a bounded judgment call over the
/// utterance + candidate entries — no tools, no files — so it is quick; 30s bounds
/// an upstream blip, on overrun the pipeline degrades to the hosted turn (rung 3).
pub const DIET_VERIFY_TIMEOUT_SECS: u64 = 30;

// ---- Canonical CSV headers (single source of truth) -----------------------
//
// These header consts are the ONE definition of each log's column contract. BOTH
// the append path (the row builders below target exactly these columns, in order)
// AND the extract prompt (which inlines them verbatim) consume them, so the prompt
// can never describe a schema the writer doesn't produce. `prompt_contract_matches_
// append_schema` is the drift guard that enforces this (the parity mitigation).

pub const FOOD_LOG_HEADER: &str =
    "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g,Sodium_mg,SatFat_g,Sugar_g,Potassium_mg,Calcium_mg,Omega3_mg,Magnesium_mg";
pub const EXERCISE_LOG_HEADER: &str =
    "Date,Type,Description,Distance_km,Duration,Pace_min_per_km,Elevation_m,Avg_HR,Cadence,Calories,Plan_Source,Notes,Start_Time";
pub const WEIGHT_LOG_HEADER: &str =
    "Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes";

// ---- Extracted entry schema -----------------------------------------------

/// One extracted food ITEM (never an aggregated meal). Macros are per-item; unknown
/// macros are `None` (omitted from the CSV, never zero-padded).
///
/// Serde derives (added for the emergency diet queue, [`dietqueue`]) let a validated
/// entry round-trip through the pending-verify file with FULL fidelity — the queue
/// must replay the exact entry, including fields (`unit`, `notes`) that the lossy
/// `entries_to_json` verify shape drops. The derives are additive; no existing
/// serialization uses them.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct FoodEntry {
    pub name: String,
    pub meal: String, // Breakfast | Lunch | Dinner | Snack
    // `HH:MM` — the clock time the item was eaten, but ONLY when the utterance
    // stated one explicitly ("lunch at 12"). The toolless extract child has no
    // clock, so an unstated time is `None`; the bridge fills it with the turn's
    // received-at wall clock at append ([`stamp_missing_food_times`]). An explicit
    // stated time always wins. The model must never invent a time.
    pub time: Option<String>,
    pub amount: Option<String>,
    pub unit: Option<String>,
    pub kcal: Option<f64>,
    pub protein_g: Option<f64>,
    pub carbs_g: Option<f64>,
    pub fat_g: Option<f64>,
    pub fiber_g: Option<f64>,
    // The four micronutrients — same unknown-is-not-zero discipline as the macros:
    // `None` means the message/label never established a value (blank CSV cell, omitted
    // on the wire), never `Some(0.0)`. `sodium_mg`/`potassium_mg` are milligrams;
    // `satfat_g`/`sugar_g` are grams.
    pub sodium_mg: Option<f64>,
    pub satfat_g: Option<f64>,
    pub sugar_g: Option<f64>,
    pub potassium_mg: Option<f64>,
    // The three newest micronutrients — same unknown-is-not-zero discipline. `calcium_mg`
    // and `magnesium_mg` are milligrams; `omega3_mg` is marine long-chain EPA+DHA in
    // milligrams (never plant ALA). `None` is a blank CSV cell / omitted wire field,
    // never `Some(0.0)`.
    pub calcium_mg: Option<f64>,
    pub omega3_mg: Option<f64>,
    pub magnesium_mg: Option<f64>,
    pub notes: Option<String>,
}

/// One extracted exercise session.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ExerciseEntry {
    pub activity: String,
    pub time: Option<String>, // Start_Time HH:MM
    pub description: Option<String>,
    pub distance_km: Option<f64>,
    pub duration: Option<String>,
    pub pace: Option<String>,
    pub avg_hr: Option<f64>,
    pub calories: Option<f64>,
    pub notes: Option<String>,
}

/// One extracted weigh-in reading.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WeightEntry {
    pub weight_lbs: f64,
    pub weight_kg: Option<f64>,
    pub body_fat_pct: Option<f64>,
    pub muscle_mass_lbs: Option<f64>,
    pub notes: Option<String>,
}

/// A single extracted entry — one per ITEM, never an aggregate.
///
/// Internally tagged (`kind`) for the queue's serde round-trip; none of the entry
/// structs carry a `kind` field of their own, so the tag is unambiguous.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum DietEntry {
    Food(FoodEntry),
    Exercise(ExerciseEntry),
    Weight(WeightEntry),
}

/// The whole parsed extract child output: a per-item `entries` array plus the
/// `no_loggable_content` gate-false-positive flag.
#[derive(Debug, Clone, PartialEq)]
pub struct DietExtract {
    pub no_loggable_content: bool,
    pub entries: Vec<DietEntry>,
}

// ---- Anti-aggregation ------------------------------------------------------

/// Whether a food `name` looks like an AGGREGATE of several foods rather than a
/// single item. Per the 2026-07-13 schema decision the extract must emit one entry
/// PER ITEM, so an aggregated name is a validation-time rejection (the verifier is
/// the semantic backstop for meal-total macros). Heuristic: strip parenthetical
/// qualifiers — `Salmon sockeye (Fiorfiore, canned)` is one item whose comma lives
/// inside the brand note — then flag a comma or a conjunction token (` and `,
/// ` + `, ` & `, ` with `) in what remains (`Eggs and toast`, `Rice, chicken`).
pub fn name_is_aggregated(name: &str) -> bool {
    let bare = strip_parens(name).to_lowercase();
    bare.contains(',')
        || bare.contains(" and ")
        || bare.contains(" + ")
        || bare.contains('&')
        || bare.contains(" with ")
}

/// Remove balanced `(...)` groups from a string (one level; these names never nest).
fn strip_parens(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut depth = 0usize;
    for c in s.chars() {
        match c {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

// ---- Extract parsing + validation ------------------------------------------

/// Parse + validate the extract child's JSON into a [`DietExtract`]. Enforces the
/// per-item schema: a top-level object with an `entries` array (each entry a
/// `{kind, ...}` object) and a boolean `no_loggable_content`. A food entry with an
/// aggregated name ([`name_is_aggregated`]) is rejected. Any macro present must be a
/// finite, non-negative number. Returns `Err(reason)` for anything off-contract; the
/// pipeline maps that to ladder rung 2 (fall through to the hosted turn).
/// If `s` (expected already trimmed) is ENTIRELY wrapped in one markdown code fence,
/// return the interior; otherwise return `s` unchanged. A wrapper is an opening line of
/// three-or-more backticks with an optional language tag (` ```json `), the payload on
/// its own line(s), and a closing line of only backticks (≥ the opening count). Only the
/// OUTERMOST full wrapper is stripped, so backticks INSIDE a JSON string value are never
/// touched, and a payload that is not fully fence-wrapped (e.g. prose then a fence, or a
/// fence with no closing line) is returned verbatim. Through the production CLI child the
/// model fences its JSON on some turns; the parser strips exactly this before json.loads.
pub fn strip_code_fence(s: &str) -> &str {
    // Opening fence: leading run of >=3 backticks, then an optional tag with no backticks.
    let open_ticks = s.chars().take_while(|&c| c == '`').count();
    if open_ticks < 3 {
        return s;
    }
    let Some(first_nl) = s.find('\n') else {
        return s; // single line — no interior to strip
    };
    let open_tag = &s[open_ticks..first_nl];
    if open_tag.contains('`') {
        return s; // not a clean opening fence line
    }
    // The closing fence is the LAST non-empty line: a run of only backticks (>= opening).
    let after = s[first_nl + 1..].trim_end_matches(['\n', '\r', ' ', '\t']);
    let (interior, close_line) = match after.rfind('\n') {
        Some(nl) => (&after[..nl], &after[nl + 1..]),
        None => ("", after), // opening fence then only a closing line → empty interior
    };
    let close_ok = {
        let n = close_line.chars().take_while(|&c| c == '`').count();
        n >= open_ticks && close_line.chars().all(|c| c == '`')
    };
    if close_ok {
        interior
    } else {
        s // not fully fence-wrapped — leave it exactly as-is
    }
}

pub fn parse_diet_entries(json: &str) -> Result<DietExtract, String> {
    let value: Value = serde_json::from_str(strip_code_fence(json.trim()))
        .map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;
    for key in obj.keys() {
        if key != "entries" && key != "no_loggable_content" {
            return Err(format!("unknown top-level field {key:?}"));
        }
    }
    let no_loggable_content = match obj.get("no_loggable_content") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err("`no_loggable_content` is not a boolean".into()),
    };
    let empty = Vec::new();
    let items: &Vec<Value> = match obj.get("entries") {
        None | Some(Value::Null) => &empty,
        Some(Value::Array(a)) => a,
        Some(_) => return Err("`entries` is not an array".into()),
    };
    if items.len() > MAX_DIET_ENTRIES {
        return Err(format!(
            "`entries` has {} entries, cap is {MAX_DIET_ENTRIES}",
            items.len()
        ));
    }
    let mut entries = Vec::with_capacity(items.len());
    for item in items {
        entries.push(parse_one_entry(item)?);
    }
    Ok(DietExtract {
        no_loggable_content,
        entries,
    })
}

fn parse_one_entry(item: &Value) -> Result<DietEntry, String> {
    let m = item.as_object().ok_or("entry is not an object")?;
    let kind = m
        .get("kind")
        .and_then(|v| v.as_str())
        .ok_or("entry missing string `kind`")?;
    match kind {
        "food" => Ok(DietEntry::Food(parse_food(m)?)),
        "exercise" => Ok(DietEntry::Exercise(parse_exercise(m)?)),
        "weight" => Ok(DietEntry::Weight(parse_weight(m)?)),
        other => Err(format!("unknown entry kind {other:?}")),
    }
}

/// A required, non-empty string field.
fn req_str(m: &serde_json::Map<String, Value>, key: &str) -> Result<String, String> {
    let s = m
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("entry missing string `{key}`"))?;
    if s.trim().is_empty() {
        return Err(format!("entry `{key}` is empty"));
    }
    Ok(s.trim().to_string())
}

/// An optional string field (absent/blank → None).
fn opt_str_field(m: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    m.get(key)
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// An optional macro/number: absent → None; present → a finite, non-negative number
/// (an explicit `null` is a violation — this strict form is what the hosted VERIFY
/// verdict parser uses, so verify-gate behavior is unchanged). The EXTRACT parsers use
/// the null/empty-tolerant [`opt_extract_num_field`] instead (Fix 2).
fn opt_num_field(m: &serde_json::Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    match m.get(key) {
        None => Ok(None),
        Some(v) => {
            let n = v
                .as_f64()
                .ok_or_else(|| format!("`{key}` is not a number"))?;
            if !n.is_finite() {
                return Err(format!("`{key}` is not finite"));
            }
            if n < 0.0 {
                return Err(format!("`{key}` is negative"));
            }
            Ok(Some(n))
        }
    }
}

/// An optional EXTRACT-child macro/number, tolerant of the child's two ways of saying
/// "unknown". The prompt tells the model to OMIT an unknown macro, but it commonly nulls
/// it (or emits an empty string) instead — so JSON `null` and an empty/blank string are
/// BOTH treated as absent (None), the same as an omitted key. A literal `0` is a
/// measured zero (`Some(0.0)`), never absent; a negative, non-finite, or
/// non-numeric-non-empty value is still a schema violation. Scoped to the extract
/// parsers so the verify verdict path ([`opt_num_field`]) stays strict/unchanged.
fn opt_extract_num_field(
    m: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<f64>, String> {
    match m.get(key) {
        // Omitted, JSON null, or an empty/blank string → absent.
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
        _ => opt_num_field(m, key),
    }
}

const FOOD_KEYS: &[&str] = &[
    "kind",
    "name",
    "meal",
    "time",
    "amount",
    "unit",
    "kcal",
    "protein_g",
    "carbs_g",
    "fat_g",
    "fiber_g",
    "sodium_mg",
    "satfat_g",
    "sugar_g",
    "potassium_mg",
    "calcium_mg",
    "omega3_mg",
    "magnesium_mg",
    "notes",
];

fn parse_food(m: &serde_json::Map<String, Value>) -> Result<FoodEntry, String> {
    for k in m.keys() {
        if !FOOD_KEYS.contains(&k.as_str()) {
            return Err(format!("unknown food field {k:?}"));
        }
    }
    let name = req_str(m, "name")?;
    if name_is_aggregated(&name) {
        return Err(format!(
            "food entry name {name:?} spans multiple items — the schema requires ONE entry per item"
        ));
    }
    Ok(FoodEntry {
        name,
        meal: req_str(m, "meal")?,
        // Optional: the bridge owns the received-at fallback (see the field docs).
        time: opt_str_field(m, "time"),
        amount: opt_str_field(m, "amount"),
        unit: opt_str_field(m, "unit"),
        kcal: opt_extract_num_field(m, "kcal")?,
        protein_g: opt_extract_num_field(m, "protein_g")?,
        carbs_g: opt_extract_num_field(m, "carbs_g")?,
        fat_g: opt_extract_num_field(m, "fat_g")?,
        fiber_g: opt_extract_num_field(m, "fiber_g")?,
        sodium_mg: opt_extract_num_field(m, "sodium_mg")?,
        satfat_g: opt_extract_num_field(m, "satfat_g")?,
        sugar_g: opt_extract_num_field(m, "sugar_g")?,
        potassium_mg: opt_extract_num_field(m, "potassium_mg")?,
        calcium_mg: opt_extract_num_field(m, "calcium_mg")?,
        omega3_mg: opt_extract_num_field(m, "omega3_mg")?,
        magnesium_mg: opt_extract_num_field(m, "magnesium_mg")?,
        notes: opt_str_field(m, "notes"),
    })
}

const EXERCISE_KEYS: &[&str] = &[
    "kind",
    "activity",
    "time",
    "description",
    "distance_km",
    "duration",
    "pace",
    "avg_hr",
    "calories",
    "notes",
];

fn parse_exercise(m: &serde_json::Map<String, Value>) -> Result<ExerciseEntry, String> {
    for k in m.keys() {
        if !EXERCISE_KEYS.contains(&k.as_str()) {
            return Err(format!("unknown exercise field {k:?}"));
        }
    }
    Ok(ExerciseEntry {
        activity: req_str(m, "activity")?,
        time: opt_str_field(m, "time"),
        description: opt_str_field(m, "description"),
        distance_km: opt_extract_num_field(m, "distance_km")?,
        duration: opt_str_field(m, "duration"),
        pace: opt_str_field(m, "pace"),
        avg_hr: opt_extract_num_field(m, "avg_hr")?,
        calories: opt_extract_num_field(m, "calories")?,
        notes: opt_str_field(m, "notes"),
    })
}

const WEIGHT_KEYS: &[&str] = &[
    "kind",
    "weight_lbs",
    "weight_kg",
    "body_fat_pct",
    "muscle_mass_lbs",
    "notes",
];

fn parse_weight(m: &serde_json::Map<String, Value>) -> Result<WeightEntry, String> {
    for k in m.keys() {
        if !WEIGHT_KEYS.contains(&k.as_str()) {
            return Err(format!("unknown weight field {k:?}"));
        }
    }
    let lbs = opt_extract_num_field(m, "weight_lbs")?;
    let kg = opt_extract_num_field(m, "weight_kg")?;
    // weight-log.csv keys on a parseable Weight_lbs, so a weigh-in MUST resolve one:
    // prefer the reported lbs, else derive from kg (1 kg = 2.20462 lb).
    let weight_lbs = match (lbs, kg) {
        (Some(l), _) => l,
        (None, Some(k)) => (k * 2.20462 * 10.0).round() / 10.0,
        (None, None) => return Err("weight entry has neither weight_lbs nor weight_kg".into()),
    };
    Ok(WeightEntry {
        weight_lbs,
        weight_kg: kg,
        body_fat_pct: opt_extract_num_field(m, "body_fat_pct")?,
        muscle_mass_lbs: opt_extract_num_field(m, "muscle_mass_lbs")?,
        notes: opt_str_field(m, "notes"),
    })
}

// ---- Verify: verdicts + tolerance ------------------------------------------

/// The per-item tolerance band. An entry's candidate macro is OUT OF BAND versus the
/// verifier's estimate when it differs by MORE than the larger of a relative 20% and
/// an absolute 75 kcal — so a small absolute gap on a small item passes even if it
/// exceeds 20%, and a large item is held to the tighter 20%. A difference exactly
/// equal to the threshold is in band (the spec says "more than").
pub fn kcal_out_of_band(candidate: f64, reference: f64) -> bool {
    let tolerance = (0.20 * reference.abs()).max(75.0);
    (candidate - reference).abs() > tolerance
}

/// One verifier verdict for one candidate entry.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    Approve,
    Correct,
    Reject,
}

/// A parsed per-entry verdict: the verdict plus any corrected macro values the
/// verifier supplied (only meaningful for `Correct`).
#[derive(Debug, Clone, PartialEq)]
pub struct EntryVerdict {
    pub verdict: Verdict,
    pub kcal: Option<f64>,
    pub protein_g: Option<f64>,
    pub carbs_g: Option<f64>,
    pub fat_g: Option<f64>,
    pub fiber_g: Option<f64>,
    pub reason: Option<String>,
}

/// Parse the verify child's JSON into one verdict per entry (order-aligned with the
/// candidates). Requires exactly `n_entries` verdicts. `Err` → the pipeline can't
/// confirm the write, so it falls through to the hosted turn (rung 3).
pub fn parse_verify_verdicts(json: &str, n_entries: usize) -> Result<Vec<EntryVerdict>, String> {
    let value: Value =
        serde_json::from_str(json.trim()).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = value.as_object().ok_or("payload is not a JSON object")?;
    let items = obj
        .get("verdicts")
        .and_then(|v| v.as_array())
        .ok_or("missing `verdicts` array")?;
    if items.len() != n_entries {
        return Err(format!(
            "expected {n_entries} verdict(s), got {}",
            items.len()
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let m = item.as_object().ok_or("verdict is not an object")?;
        let verdict = match m.get("verdict").and_then(|v| v.as_str()) {
            Some("approve") => Verdict::Approve,
            Some("correct") => Verdict::Correct,
            Some("reject") => Verdict::Reject,
            _ => return Err("verdict must be approve|correct|reject".into()),
        };
        out.push(EntryVerdict {
            verdict,
            kcal: opt_num_field(m, "kcal")?,
            protein_g: opt_num_field(m, "protein_g")?,
            carbs_g: opt_num_field(m, "carbs_g")?,
            fat_g: opt_num_field(m, "fat_g")?,
            fiber_g: opt_num_field(m, "fiber_g")?,
            reason: opt_str_field(m, "reason"),
        })
    }
    Ok(out)
}

/// Apply a verdict to a candidate entry (probation semantics — every entry gated).
/// `Some(entry)` = keep/use these (possibly corrected) macros (safe to write);
/// `None` = a structural problem (a reject, or a non-trivially-safe correction) → the
/// turn falls through to the hosted path (rung 3). Cases:
///   * `Reject` → `None`.
///   * `Approve` → keep the candidate, UNLESS the verifier's own kcal estimate is out
///     of band ([`kcal_out_of_band`]); a contradictory approve is treated as a
///     correction so we never write numbers the verifier itself disputes.
///   * `Correct` → apply the corrected macros IF trivially safe (same item, only
///     numbers change, every corrected value finite/non-negative); else `None`.
///
/// Only FOOD carries macros to correct; an exercise/weight entry is kept on approve
/// and falls through on correct/reject (we don't auto-correct those in v1).
pub fn resolve_verdict(entry: &DietEntry, v: &EntryVerdict) -> Option<DietEntry> {
    if v.verdict == Verdict::Reject {
        return None;
    }
    match entry {
        DietEntry::Food(f) => resolve_food_verdict(f, v),
        // Non-food: approve keeps it; a correction we can't trivially apply → hosted.
        _ if v.verdict == Verdict::Approve => Some(entry.clone()),
        _ => None,
    }
}

fn resolve_food_verdict(f: &FoodEntry, v: &EntryVerdict) -> Option<DietEntry> {
    let needs_correction = match v.verdict {
        Verdict::Correct => true,
        // An "approve" whose kcal estimate disagrees with the candidate is really a
        // correction; only a true agreement is kept as-is.
        Verdict::Approve => match (f.kcal, v.kcal) {
            (Some(cand), Some(refv)) => kcal_out_of_band(cand, refv),
            _ => false,
        },
        Verdict::Reject => unreachable!("reject handled in resolve_verdict"),
    };
    if !needs_correction {
        return Some(DietEntry::Food(f.clone()));
    }
    // Trivially safe correction: same item, macros replaced with the verifier's
    // (finite, non-negative) numbers. `apply` re-validates each corrected value.
    let apply = |orig: Option<f64>, corrected: Option<f64>| -> Result<Option<f64>, ()> {
        match corrected {
            Some(n) if n.is_finite() && n >= 0.0 => Ok(Some(n)),
            Some(_) => Err(()), // a bad corrected value is not trivially safe
            None => Ok(orig),   // verifier didn't touch this macro → keep candidate's
        }
    };
    let corrected = FoodEntry {
        kcal: apply(f.kcal, v.kcal).ok()?,
        protein_g: apply(f.protein_g, v.protein_g).ok()?,
        carbs_g: apply(f.carbs_g, v.carbs_g).ok()?,
        fat_g: apply(f.fat_g, v.fat_g).ok()?,
        fiber_g: apply(f.fiber_g, v.fiber_g).ok()?,
        ..f.clone()
    };
    Some(DietEntry::Food(corrected))
}

// ---- CSV row builders ------------------------------------------------------

/// RFC-4180-quote a field: wrap in double quotes and double any embedded quote when
/// the value contains a comma, a quote, or a newline; otherwise return it verbatim.
pub fn csv_field(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// A number cell: blank when absent, else the shortest round-trip form (`105`,
/// `4.5`, `1.3`) — matching how the vault's own rows and generator render macros.
fn num_cell(n: Option<f64>) -> String {
    match n {
        Some(v) => format!("{v}"),
        None => String::new(),
    }
}

/// Build one `food-log.csv` row for a verified food item at `date`. Follows the
/// vault fill convention: `Unit` defaults to `serving`, `Cal_per_100g`/`Grams` are
/// left BLANK, and the absolute macros go into `Calories,Protein_g,Fat_g,Carbs_g`
/// (+ `Fiber_g`). `Meal_Type` mirrors `Meal`.
pub fn food_row(e: &FoodEntry, date: &str) -> String {
    let cols = [
        date.to_string(),
        csv_field(&e.meal),
        csv_field(&e.name),
        csv_field(e.amount.as_deref().unwrap_or("")),
        csv_field(e.unit.as_deref().unwrap_or("serving")),
        String::new(), // Cal_per_100g — blank by convention
        String::new(), // Grams — blank by convention
        num_cell(e.kcal),
        num_cell(e.protein_g),
        num_cell(e.fat_g),
        num_cell(e.carbs_g),
        csv_field(e.notes.as_deref().unwrap_or("")),
        csv_field(e.time.as_deref().unwrap_or("")),
        csv_field(&e.meal), // Meal_Type mirrors Meal
        num_cell(e.fiber_g),
        num_cell(e.sodium_mg),    // Sodium_mg — blank when unknown, never 0
        num_cell(e.satfat_g),     // SatFat_g
        num_cell(e.sugar_g),      // Sugar_g
        num_cell(e.potassium_mg), // Potassium_mg
        num_cell(e.calcium_mg),   // Calcium_mg — blank when unknown, never 0
        num_cell(e.omega3_mg),    // Omega3_mg  (marine EPA+DHA only)
        num_cell(e.magnesium_mg), // Magnesium_mg
    ];
    cols.join(",")
}

/// Build one `exercise-log.csv` row for a verified exercise session at `date`.
pub fn exercise_row(e: &ExerciseEntry, date: &str) -> String {
    let cols = [
        date.to_string(),
        csv_field(&e.activity),
        csv_field(e.description.as_deref().unwrap_or("")),
        num_cell(e.distance_km),
        csv_field(e.duration.as_deref().unwrap_or("")),
        csv_field(e.pace.as_deref().unwrap_or("")),
        String::new(), // Elevation_m
        num_cell(e.avg_hr),
        String::new(), // Cadence
        num_cell(e.calories),
        String::new(), // Plan_Source
        csv_field(e.notes.as_deref().unwrap_or("")),
        csv_field(e.time.as_deref().unwrap_or("")),
    ];
    cols.join(",")
}

/// Build one `weight-log.csv` row for a verified weigh-in at `date`. `Phase` is left
/// blank (the pipeline doesn't infer it); `BodyFat_pct`/`MuscleMass_lbs` blank when
/// unmeasured (the honest "not measured" signal, never `0`).
pub fn weight_row(e: &WeightEntry, date: &str) -> String {
    let cols = [
        date.to_string(),
        num_cell(Some(e.weight_lbs)),
        num_cell(e.weight_kg),
        String::new(), // Phase
        num_cell(e.body_fat_pct),
        num_cell(e.muscle_mass_lbs),
        csv_field(e.notes.as_deref().unwrap_or("")),
    ];
    cols.join(",")
}

// ---- Mirror: appended food rows → JESSE_MEAL_LOG directive ------------------

/// Slugify a meal label for a mirror id: lowercase, non-alphanumerics → `-`.
fn meal_slug(meal: &str) -> String {
    let mut out = String::with_capacity(meal.len());
    for c in meal.trim().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_string()
}

/// Sum a group's values for one nutrient, honoring the unknown-is-not-zero contract:
/// a `None` row contributes NOTHING, and a group in which no row carries the value
/// sums to `None` (the field is omitted on the wire, never a summed `Some(0)`). A
/// group with at least one known value sums those, so a partially-known nutrient
/// mirrors the sum of the rows that stated it.
fn sum_known(vals: impl Iterator<Item = Option<f64>>) -> Option<f64> {
    let mut acc: Option<f64> = None;
    for v in vals.flatten() {
        acc = Some(acc.unwrap_or(0.0) + v);
    }
    acc
}

/// Build the DERIVED [`MealLog`] mirror from the verified food entries. The turn's
/// rows are GROUPED by (date, meal slot, `HHMM`) — one mirror meal per group — so each
/// meal carries the SAME deterministic id the hosted logging skill computes for the
/// same rows: `<date>-<slot lowercased>-<HHMM>` (e.g. `2026-07-04-lunch-1230`), with
/// no positional seq. That id is recomputable from the CSV row data alone, which is the
/// property that lets a later hosted correction or retraction target the exact Health
/// entry this mirror created (app-side upserts are version-agnostic).
///
/// Every nutrient is summed in trusted Rust over the group's rows via [`sum_known`]
/// (unknown-is-not-zero: a `None` row contributes nothing; an all-`None` group omits
/// the field). Aggregation is done by the bridge, never the model, so the aggregation
/// failure mode stays impossible by construction. There is no `omega3` field on the
/// meal wire (no HealthKit EPA+DHA type), so nothing is summed for it.
///
/// Returns `Ok(None)` when there are no food rows (a valid exercise/weigh-in-only turn
/// — no mirror to emit), and `Err` when the GROUP count exceeds [`MAX_MEALS`] (the
/// caller maps that to rung 5: keep the committed CSV, omit the mirror).
pub fn build_meal_log_from_food_rows(
    rows: &[FoodEntry],
    date: &str,
    offset: &str,
) -> Result<Option<MealLog>, String> {
    if rows.is_empty() {
        return Ok(None);
    }

    // Group the turn's rows by (meal slot, HHMM), preserving first-appearance order so
    // the mirror is deterministic. The grouping KEY is the same (slug, HHMM) the id is
    // built from, so two rows that would compute the same id always land in one group —
    // ids are unique across meals by construction.
    struct Group<'a> {
        slug: String,
        hhmm: String,
        // The first row's raw `time`/`meal` drive the group's consumed-at + display
        // label; every row in the group shares the same (slug, HHMM).
        time: String,
        meal_label: String,
        rows: Vec<&'a FoodEntry>,
    }
    let mut groups: Vec<Group> = Vec::new();
    for r in rows {
        // By the time a row reaches the mirror the pipeline has stamped any missing
        // time (received-at), so `time` is Some; default defensively. `hhmm` is the
        // digits of the clock time — the SAME fallback the id has always used.
        let time = r.time.as_deref().unwrap_or("");
        let hhmm: String = time.chars().filter(|c| c.is_ascii_digit()).collect();
        let slug = meal_slug(&r.meal);
        match groups.iter_mut().find(|g| g.slug == slug && g.hhmm == hhmm) {
            Some(g) => g.rows.push(r),
            None => groups.push(Group {
                slug,
                hhmm,
                time: time.to_string(),
                meal_label: r.meal.clone(),
                rows: vec![r],
            }),
        }
    }
    if groups.len() > MAX_MEALS {
        return Err(format!(
            "{} meals exceeds the {MAX_MEALS}-meal mirror cap",
            groups.len()
        ));
    }
    let meals = groups
        .iter()
        .map(|g| {
            let names: Vec<&str> = g.rows.iter().map(|r| r.name.as_str()).collect();
            Meal {
                // The deterministic hosted-contract id: `<date>-<slug>-<HHMM>`, no seq.
                id: format!("{date}-{}-{}", g.slug, g.hhmm),
                consumed_at: format!("{date}T{}:00{offset}", g.time),
                name: format!("{}: {}", g.meal_label, names.join(", ")),
                // Macros summed over the group in trusted Rust (unknown-is-not-zero).
                kcal: sum_known(g.rows.iter().map(|r| r.kcal)),
                protein_g: sum_known(g.rows.iter().map(|r| r.protein_g)),
                carbs_g: sum_known(g.rows.iter().map(|r| r.carbs_g)),
                fat_g: sum_known(g.rows.iter().map(|r| r.fat_g)),
                fiber_g: sum_known(g.rows.iter().map(|r| r.fiber_g)),
                // Micronutrients summed the same way: only the rows that stated a value
                // contribute, and a group where none did omits the field (never Some(0)).
                sodium_mg: sum_known(g.rows.iter().map(|r| r.sodium_mg)),
                satfat_g: sum_known(g.rows.iter().map(|r| r.satfat_g)),
                sugar_g: sum_known(g.rows.iter().map(|r| r.sugar_g)),
                potassium_mg: sum_known(g.rows.iter().map(|r| r.potassium_mg)),
                // Only the HealthKit-bound micros carry onto the Meal wire. Calcium and
                // magnesium have HealthKit types; omega-3 does NOT (there is no EPA/DHA
                // HealthKit quantity — `dietaryFatPolyunsaturated` includes ALA, so it is
                // wrong), so there is no `omega3` Meal field and nothing to mirror for it.
                calcium_mg: sum_known(g.rows.iter().map(|r| r.calcium_mg)),
                magnesium_mg: sum_known(g.rows.iter().map(|r| r.magnesium_mg)),
            }
        })
        .collect();
    // The derived mirror is an insert-only v1-shaped block: it never retracts (the local
    // route re-derives the whole day) and carries no corrections_seq (it is not assembled
    // from the persisted corrections queue). Both v2 fields stay empty/None here.
    Ok(Some(MealLog {
        meals,
        retract: Vec::new(),
        corrections_seq: None,
    }))
}

// ---- Deterministic ASCII dashboard (rendered from the CSVs) -----------------

/// The day's macro totals, summed from the food rows.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MacroTotals {
    pub kcal: f64,
    pub protein_g: f64,
    pub carbs_g: f64,
    pub fat_g: f64,
    pub fiber_g: f64,
}

/// The day's targets, read from `daily-targets.csv` (all optional — a day with no
/// targets row renders totals without bars).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DietTargets {
    pub cal: Option<f64>,
    pub protein: Option<f64>,
    pub carbs: Option<f64>,
    pub fat: Option<f64>,
    pub fiber: Option<f64>,
}

/// Sum `food-log.csv` into the day's macro totals for `date` — the source of truth
/// the dashboard renders from (the whole day, not just this turn's rows). Columns
/// are addressed by header NAME; a blank `Calories` is derived from
/// `Cal_per_100g × Grams / 100` (the generator's own rule); blank macros count as 0.
/// A row that fails to parse is skipped, never fatal.
pub fn sum_food_csv_for_date(food_csv: &str, date: &str) -> MacroTotals {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(food_csv.as_bytes());
    let idx: HashMap<String, usize> = match rdr.headers() {
        Ok(h) => h
            .iter()
            .enumerate()
            .map(|(i, s)| (s.trim().to_string(), i))
            .collect(),
        Err(_) => return MacroTotals::default(),
    };
    let cell = |rec: &csv::StringRecord, name: &str| -> String {
        idx.get(name)
            .and_then(|&j| rec.get(j))
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let num = |s: &str| s.parse::<f64>().unwrap_or(0.0);
    let mut t = MacroTotals::default();
    for rec in rdr.records().flatten() {
        if cell(&rec, "Date") != date {
            continue;
        }
        // Calories: explicit, else Cal_per_100g × Grams / 100.
        let kcal = match cell(&rec, "Calories").parse::<f64>() {
            Ok(c) => c,
            Err(_) => {
                match (
                    cell(&rec, "Cal_per_100g").parse::<f64>(),
                    cell(&rec, "Grams").parse::<f64>(),
                ) {
                    (Ok(cp), Ok(g)) => (cp * g / 100.0).round(),
                    _ => 0.0,
                }
            }
        };
        t.kcal += kcal;
        t.protein_g += num(&cell(&rec, "Protein_g"));
        t.carbs_g += num(&cell(&rec, "Carbs_g"));
        t.fat_g += num(&cell(&rec, "Fat_g"));
        t.fiber_g += num(&cell(&rec, "Fiber_g"));
    }
    t
}

/// Sum the per-item food entries into the day's macro totals (missing macros → 0).
pub fn sum_food_macros(rows: &[FoodEntry]) -> MacroTotals {
    let mut t = MacroTotals::default();
    for r in rows {
        t.kcal += r.kcal.unwrap_or(0.0);
        t.protein_g += r.protein_g.unwrap_or(0.0);
        t.carbs_g += r.carbs_g.unwrap_or(0.0);
        t.fat_g += r.fat_g.unwrap_or(0.0);
        t.fiber_g += r.fiber_g.unwrap_or(0.0);
    }
    t
}

/// Read `daily-targets.csv` content and return the targets for `date` (all `None`
/// when there's no matching row). Columns are addressed by header NAME, never by
/// position, mirroring [`diet::header_index`]'s discipline.
pub fn targets_for_date(targets_csv: &str, date: &str) -> DietTargets {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(targets_csv.as_bytes());
    let idx: HashMap<String, usize> = match rdr.headers() {
        Ok(h) => h
            .iter()
            .enumerate()
            .map(|(i, s)| (s.trim().to_string(), i))
            .collect(),
        Err(_) => return DietTargets::default(),
    };
    let get = |rec: &csv::StringRecord, name: &str| -> Option<f64> {
        idx.get(name)
            .and_then(|&j| rec.get(j))
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .and_then(|s| s.parse::<f64>().ok())
    };
    for rec in rdr.records().flatten() {
        let d = idx
            .get("Date")
            .and_then(|&j| rec.get(j))
            .unwrap_or("")
            .trim();
        if d == date {
            return DietTargets {
                cal: get(&rec, "Cal_Target"),
                protein: get(&rec, "Protein_Target_g"),
                carbs: get(&rec, "Carb_Target_g"),
                fat: get(&rec, "Fat_Target_g"),
                fiber: get(&rec, "Fiber_Target_g"),
            };
        }
    }
    DietTargets::default()
}

const BAR_WIDTH: usize = 20;

/// A 20-char bar filled proportionally to `pct` (0–100+, clamped to 100 for fill),
/// with a single color emoji per the metric's goal type. `filled` uses `⬜` for the
/// empty remainder.
fn bar(pct: f64, color: &str) -> String {
    let filled = ((pct / 100.0) * BAR_WIDTH as f64)
        .round()
        .clamp(0.0, BAR_WIDTH as f64) as usize;
    let mut s = String::new();
    for _ in 0..filled {
        s.push_str(color);
    }
    for _ in 0..(BAR_WIDTH - filled) {
        s.push('⬜');
    }
    s
}

/// Color for a FLOOR metric (protein, carbs, fiber): red <50%, yellow 50–79%,
/// green ≥80%.
fn floor_color(pct: f64) -> &'static str {
    if pct < 50.0 {
        "🟥"
    } else if pct < 80.0 {
        "🟨"
    } else {
        "🟩"
    }
}

/// Color for the CALORIE ceiling: green 0–79%, yellow 80–100%, red >100%.
fn ceiling_color(pct: f64) -> &'static str {
    if pct <= 79.0 {
        "🟩"
    } else if pct <= 100.0 {
        "🟨"
    } else {
        "🟥"
    }
}

/// Color for the FAT window (50g floor, 65g soft cap, 70g hard): red too-low/too-high,
/// yellow 65–70g, green 50–65g.
fn fat_color(grams: f64) -> &'static str {
    if !(50.0..=70.0).contains(&grams) {
        "🟥"
    } else if grams > 65.0 {
        "🟨"
    } else {
        "🟩"
    }
}

fn pct_of(intake: f64, target: f64) -> f64 {
    if target > 0.0 {
        intake / target * 100.0
    } else {
        0.0
    }
}

/// Render the deterministic ASCII dashboard for `date` from the day's totals and
/// targets. When a target is present the metric renders a colored 20-char bar with
/// its goal marker; when absent it renders the plain total. Calories round to whole
/// numbers; macro grams render as their raw value. The child never writes this — it
/// is derived here from the CSVs.
pub fn render_diet_dashboard(date: &str, totals: &MacroTotals, targets: &DietTargets) -> String {
    let mut out = format!("=== Diet — {date} ===\n\n");

    // Calories — a ceiling metric (round to whole numbers, like the generator).
    match targets.cal {
        Some(t) => {
            let pct = pct_of(totals.kcal, t);
            out.push_str(&format!(
                "Cal      ≤ {}   {} {} / {}  ({:.0}%)\n",
                t.round() as i64,
                bar(pct, ceiling_color(pct)),
                totals.kcal.round() as i64,
                t.round() as i64,
                pct
            ));
        }
        None => out.push_str(&format!(
            "Cal          {} kcal\n",
            totals.kcal.round() as i64
        )),
    }

    // Floor metrics: protein, carbs, fiber.
    for (label, intake, target) in [
        ("Protein", totals.protein_g, targets.protein),
        ("Carbs", totals.carbs_g, targets.carbs),
        ("Fiber", totals.fiber_g, targets.fiber),
    ] {
        match target {
            Some(t) => {
                let pct = pct_of(intake, t);
                out.push_str(&format!(
                    "{label:<8} ≥ {}    {} {} / {}g  ({:.0}%)\n",
                    fmt_g(t),
                    bar(pct, floor_color(pct)),
                    fmt_g(intake),
                    fmt_g(t),
                    pct
                ));
            }
            None => out.push_str(&format!("{label:<8}     {}g\n", fmt_g(intake))),
        }
    }

    // Fat — a window metric (colors red when too LOW as well as too high).
    match targets.fat {
        Some(t) => {
            let pct = pct_of(totals.fat_g, t);
            out.push_str(&format!(
                "Fat      ↕ 50–65 {} {} / {}g  ({:.0}%)\n",
                bar(pct, fat_color(totals.fat_g)),
                fmt_g(totals.fat_g),
                fmt_g(t),
                pct
            ));
        }
        None => out.push_str(&format!("Fat          {}g\n", fmt_g(totals.fat_g))),
    }

    out
}

/// Render a gram value like the vault does: whole numbers without a trailing `.0`,
/// one decimal otherwise.
fn fmt_g(n: f64) -> String {
    format!("{n}")
}

// ---- Atomic append + rollback ----------------------------------------------

/// A snapshot of the log files touched by an append, so the whole turn can be rolled
/// back atomically (restore prior content, or delete a file that didn't exist).
pub struct AppendSnapshot {
    restores: Vec<(PathBuf, Option<String>)>,
}

impl AppendSnapshot {
    /// Restore every touched file to its pre-append content (rung 4 rollback): a
    /// file that existed is rewritten to its snapshot; one that didn't is removed.
    /// Best-effort — a restore error is logged, never propagated (we're already on a
    /// failure path and about to fall through to the hosted turn).
    pub fn rollback(&self) {
        for (path, orig) in &self.restores {
            let r = match orig {
                Some(content) => std::fs::write(path, content),
                None => std::fs::remove_file(path),
            };
            if let Err(e) = r {
                eprintln!(
                    "jesse-bridge: diet rollback failed for {}: {e}",
                    path.display()
                );
            }
        }
    }
}

/// Append one file's rows, preserving the single-trailing-newline convention.
fn appended_content(original: &str, rows: &[String]) -> String {
    let mut out = original.to_string();
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    for row in rows {
        out.push_str(row);
        out.push('\n');
    }
    out
}

/// Atomically append the built rows to their CSVs under `logs_dir`. Reads each
/// target's prior content into the returned snapshot BEFORE writing, so any failure
/// mid-way (or a later hook failure) can roll the whole turn back with no partial
/// rows left behind. Returns the snapshot on success (for rung-4 rollback or normal
/// completion), or `Err` (already rolled back) on the first write failure.
pub fn append_rows_atomic(
    logs_dir: &Path,
    food: &[String],
    exercise: &[String],
    weight: &[String],
) -> Result<AppendSnapshot, String> {
    let targets: [(&str, &[String]); 3] = [
        ("food-log.csv", food),
        ("exercise-log.csv", exercise),
        ("weight-log.csv", weight),
    ];
    let mut snapshot = AppendSnapshot {
        restores: Vec::new(),
    };
    for (name, rows) in targets {
        if rows.is_empty() {
            continue;
        }
        let path = logs_dir.join(name);
        let original = match std::fs::read_to_string(&path) {
            Ok(c) => Some(c),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => {
                snapshot.rollback();
                return Err(format!("cannot read {}: {e}", path.display()));
            }
        };
        let new_content = appended_content(original.as_deref().unwrap_or(""), rows);
        // Snapshot BEFORE writing so a rollback restores this file too.
        snapshot.restores.push((path.clone(), original));
        if let Err(e) = std::fs::write(&path, new_content) {
            snapshot.rollback();
            return Err(format!("cannot write {}: {e}", path.display()));
        }
    }
    Ok(snapshot)
}

// ---- Node hooks + git commit -----------------------------------------------

/// Run the three pinned node scripts (generate → validate → verify) in the vault, in
/// order. Any non-zero exit (or spawn failure) is an `Err` the caller maps to rung 4
/// (rollback, no commit, hosted turn). These are the SAME scripts the vault's
/// PostToolUse hook runs on the agent path; on the local pipeline there is no agent
/// Edit to trigger that hook, so the bridge runs them itself.
pub async fn run_diet_hooks(vault: &Path) -> Result<(), String> {
    for script in [
        "todo-list/generate-diet-today.js",
        "todo-list/validate-diet-today.js",
        "todo-list/verify-diet-consistency.js",
    ] {
        let out = Command::new("node")
            .arg(script)
            .current_dir(vault)
            .output()
            .await
            .map_err(|e| format!("failed to run node {script}: {e}"))?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(format!(
                "node {script} failed: {}",
                truncate_chars(stderr.trim(), 300)
            ));
        }
    }
    Ok(())
}

/// Commit the log change (one commit per log event, matching today's convention).
/// Stages the diet-logs + regenerated cache and commits; a git failure is an `Err`.
pub async fn commit_diet_logs(vault: &Path, date: &str, hhmm: &str) -> Result<(), String> {
    let add = Command::new("git")
        .args(["add", "diet-logs", "todo-list/diet-today.js"])
        .current_dir(vault)
        .output()
        .await
        .map_err(|e| format!("git add failed: {e}"))?;
    if !add.status.success() {
        return Err(format!(
            "git add failed: {}",
            truncate_chars(&String::from_utf8_lossy(&add.stderr), 200)
        ));
    }
    let msg = format!("diet: log {date} {hhmm}");
    let commit = Command::new("git")
        .args(["commit", "-m", &msg])
        .current_dir(vault)
        .output()
        .await
        .map_err(|e| format!("git commit failed: {e}"))?;
    if !commit.status.success() {
        return Err(format!(
            "git commit failed: {}",
            truncate_chars(&String::from_utf8_lossy(&commit.stderr), 200)
        ));
    }
    Ok(())
}

// ---- Local clock helpers (impure edges) ------------------------------------

/// Today's local date `YYYY-MM-DD` via `date +%F`, falling back to a std-only UTC
/// computation so it is never absent. The zone is the host's, matching the vault's
/// per-log convention.
pub fn local_today() -> String {
    if let Some(d) = std::process::Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%F")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
    {
        let d = d.trim();
        if valid_iso_date(d).is_some() {
            return d.to_string();
        }
    }
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    format!("{y:04}-{m:02}-{d:02}")
}

/// The host's current UTC offset as `±HH:MM` via `date +%z`, falling back to
/// `+00:00`. Used to stamp mirror `consumedAt` timestamps.
pub fn local_offset() -> String {
    std::process::Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%z")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| normalize_offset_pub(s.trim()))
        .unwrap_or_else(|| "+00:00".to_string())
}

/// Local `HH:MM` via `date +%H:%M`, for the commit message timestamp. `pub(crate)`
/// so the emergency diet-queue replay ([`dietqueue`]) can stamp its own commit.
pub(crate) fn local_hhmm() -> String {
    std::process::Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%H:%M")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| s.len() == 5)
        .unwrap_or_else(|| "00:00".to_string())
}

/// Normalize a `date +%z` compact `±HHMM` to `±HH:MM` (colonized), passing an
/// already-colonized value through. Small local copy of `prompt::normalize_offset`
/// (that one is private to prompt).
fn normalize_offset_pub(raw: &str) -> String {
    let raw = raw.trim();
    if raw.len() == 6 && raw.as_bytes().get(3) == Some(&b':') {
        return raw.to_string();
    }
    if raw.len() == 5
        && (raw.starts_with('+') || raw.starts_with('-'))
        && raw[1..].bytes().all(|b| b.is_ascii_digit())
    {
        return format!("{}:{}", &raw[..3], &raw[3..]);
    }
    "+00:00".to_string()
}

// ---- Rung-2 reason codes ---------------------------------------------------

/// The machine-readable reason a diet turn fell to rung 2 (the extract/`Child` rung).
/// Every rung-2 emission carries one so the daily audit can tell a pipeline FAILURE
/// from a CORRECT rejection of a non-loggable turn (the loose keyword gate lets some
/// non-loggable turns in). The code is content-free — a fixed token plus, for a schema
/// failure, the offending SCHEMA FIELD name — never meal text and never the token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rung2Reason {
    /// The extract child errored, timed out, or could not be spawned.
    ChildError,
    /// The child's output was not valid JSON (after fence-stripping).
    MalformedJson,
    /// Valid JSON but off-contract; carries the failing schema field where known.
    SchemaFail(Option<String>),
    /// Parsed cleanly, `no_loggable_content` false, but the `entries` array was empty.
    EmptyEntries,
    /// The child set `no_loggable_content` — a CORRECT rejection, not a failure.
    NoLoggable,
}

impl Rung2Reason {
    /// The content-free reason code for the provenance line and metrics record, e.g.
    /// `child_error`, `malformed_json`, `schema_fail:time`, `empty_entries`,
    /// `no_loggable`. A schema failure appends the offending field after a colon.
    pub fn code(&self) -> String {
        match self {
            Rung2Reason::ChildError => "child_error".to_string(),
            Rung2Reason::MalformedJson => "malformed_json".to_string(),
            Rung2Reason::SchemaFail(Some(field)) => format!("schema_fail:{field}"),
            Rung2Reason::SchemaFail(None) => "schema_fail".to_string(),
            Rung2Reason::EmptyEntries => "empty_entries".to_string(),
            Rung2Reason::NoLoggable => "no_loggable".to_string(),
        }
    }

    /// Classify a [`parse_diet_entries`] error string. A serde failure is prefixed
    /// `invalid JSON:` (→ `MalformedJson`); anything else is a schema violation, and the
    /// first back-tick-delimited token in the message is the offending field (schema
    /// keys are back-ticked in the validator; a quoted value like a meal name is not, so
    /// no meal text can leak into the code).
    pub fn from_parse_error(msg: &str) -> Rung2Reason {
        if msg.starts_with("invalid JSON:") {
            Rung2Reason::MalformedJson
        } else {
            Rung2Reason::SchemaFail(schema_field(msg))
        }
    }
}

/// The first back-tick-delimited token in `msg` (the offending schema field), if any.
fn schema_field(msg: &str) -> Option<String> {
    let start = msg.find('`')? + 1;
    let rest = &msg[start..];
    let end = rest.find('`')?;
    Some(rest[..end].to_string())
}

// ---- Provenance ------------------------------------------------------------

/// One diet-turn provenance line (mirrors the title provenance line): local vs
/// hosted-fallback with the rung, the extract backend (base URL + model, NEVER the
/// token, no meal content), the verify verdict, the row count, whether a mirror was
/// derived, and — on a rung-2 fall-through — the machine-readable [`Rung2Reason`] code.
#[allow(clippy::too_many_arguments)] // a flat provenance line; a params struct would only obscure it
pub fn format_diet_provenance(
    local: bool,
    rung: Option<u8>,
    base_url: &str,
    model: &str,
    verify: &str,
    rows: usize,
    mirror_derived: bool,
    reason: Option<&str>,
) -> String {
    let disposition = if local {
        "local".to_string()
    } else {
        format!("hosted-fallback rung={}", rung.unwrap_or(0))
    };
    let mirror = if mirror_derived { "derived" } else { "omitted" };
    // The machine-readable rung-2 reason rides after the disposition (content-free).
    let reason = reason.map(|r| format!(" reason={r}")).unwrap_or_default();
    format!(
        "jesse-bridge: diet turn -> {disposition}{reason} extract base_url={base_url} model={model}; \
         verify verdict={verify}; rows={rows} mirror={mirror}"
    )
}

// ---- Prompts ---------------------------------------------------------------

/// The verbatim JSON schema the extract child must return — a per-item `entries`
/// array plus `no_loggable_content`. Kept as a const so the prompt and the report
/// share one source. See [`parse_diet_entries`] for the enforcing validator.
pub const DIET_EXTRACT_SCHEMA: &str = r#"{
  "no_loggable_content": <boolean: true if the message logs nothing NEW to eat/drink, no workout, no weight — OR if it AMENDS/corrects/moves/deletes something already logged instead of reporting new consumption; in either case return an empty entries array>,
  "entries": [
    { "kind": "food", "name": "<ONE food item, never a combined meal>", "meal": "Breakfast|Lunch|Dinner|Snack", "time": "<HH:MM ONLY if the message states a clock time, else null/omit — never invent one>", "amount": "<e.g. 1 medium (~118g)>", "unit": "serving", "kcal": <number>, "protein_g": <number>, "carbs_g": <number>, "fat_g": <number>, "fiber_g": <number>, "sodium_mg": <number>, "satfat_g": <number>, "sugar_g": <number>, "potassium_mg": <number>, "calcium_mg": <number>, "omega3_mg": <number>, "magnesium_mg": <number>, "notes": "<optional>" },
    { "kind": "exercise", "activity": "Run|Walk|Swim|Strength/Weights|...", "time": "<HH:MM ONLY if stated, else null/omit>", "description": "<optional>", "distance_km": <number>, "duration": "<e.g. 56:58>", "pace": "<e.g. 7:07>", "avg_hr": <number>, "calories": <number>, "notes": "<optional>" },
    { "kind": "weight", "weight_lbs": <number>, "weight_kg": <number>, "body_fat_pct": <number>, "muscle_mass_lbs": <number>, "notes": "<optional>" }
  ]
}"#;

/// Build the stateless EXTRACT prompt: the CSV/macro contract (inlined from the same
/// header consts the append path targets — the parity source of truth), the per-item
/// anti-aggregation rule, the schema, and the JSON-only instruction. The raw
/// utterance is appended. The child holds no tools, so everything it needs is here.
pub fn build_diet_extract_prompt(utterance: &str, owner: &str) -> String {
    format!(
        "You extract structured diet-log entries from a short message {owner} sent from \
their phone. Return ONLY a single JSON object — no prose, no markdown, no code fence.\n\
\n\
CONTRACT (the vault's diet logs; you are parsing INTO these columns):\n\
- food-log.csv columns: {FOOD_LOG_HEADER}\n\
- exercise-log.csv columns: {EXERCISE_LOG_HEADER}\n\
- weight-log.csv columns: {WEIGHT_LOG_HEADER}\n\
- Macros are per-ITEM absolute grams/kcal. Omit any macro you don't know — NEVER \
guess and NEVER write 0 as a placeholder (0 means a real measured zero).\n\
- MICRONUTRIENTS (`sodium_mg`, `satfat_g`, `sugar_g`, `potassium_mg`, `calcium_mg`, \
`omega3_mg`, `magnesium_mg`) follow the SAME rule: fill a value only from a nutrition \
label in the message or a confident estimate, otherwise OMIT the key entirely (never \
guess, never 0-as-placeholder). Units and conversions: `sodium_mg` is sodium in \
MILLIGRAMS — when an EU label prints salt (\"sale\") in grams instead of sodium, convert \
sodium_mg = salt_grams × 400. `satfat_g` is saturated fat in grams (the label's \"di cui \
acidi grassi saturi\"). `sugar_g` is TOTAL sugars in grams (\"di cui zuccheri\"), NEVER \
added sugars. `potassium_mg` is potassium in milligrams — optional on EU labels and \
usually absent, so usually omitted. `calcium_mg` is calcium in MILLIGRAMS and \
`magnesium_mg` is magnesium in milligrams — like potassium, both are usually absent on \
EU labels and so usually omitted, but a confident whole-food estimate is fine. \
`omega3_mg` is marine long-chain omega-3 (EPA+DHA) in MILLIGRAMS — count it ONLY for \
fish, shellfish, roe, and the small amounts in eggs/dairy; NEVER the plant ALA in \
walnuts, flax, chia, or vegetable oils, and OMIT it entirely for a plant-ALA-only food. \
Scale every label value to the amount actually logged when the serving differs.\n\
- `time` is the clock time the thing happened (HH:MM), but ONLY when the message \
states one (\"at 12:30\", \"this morning\" is NOT a clock time). You have NO clock and \
MUST NOT invent, guess, or infer a time — if the message gives no explicit clock time, \
set `time` to null or omit it, and the bridge stamps the real received-at time. `meal` \
is the meal slot that fits the stated hour, or your best slot from the wording when no \
time is given.\n\
\n\
PER-ITEM RULE (the 2026-07-13 schema decision — enforce it):\n\
- Emit ONE food entry PER DISTINCT FOOD, each with its OWN per-item macros. NEVER a \
single entry for a whole meal, and NEVER a meal-total set of macros. \"Eggs and \
toast\" is TWO food entries; a plate of pasta with sauce and cheese is three. A \
brand/qualifier in parentheses is part of one item's name (\"Salmon (canned)\").\n\
- One exercise entry per activity; one weight entry per reading.\n\
- If the message logs nothing loggable (no food/drink, no workout, no weight), set \
`no_loggable_content` to true and return an empty `entries` array.\n\
- CORRECTIONS ARE NOT NEW LOGS. If the message AMENDS, corrects, moves, or deletes \
something already logged — \"actually lunch was two bowls, ~700 kcal\", \"make that \
700 not 500\", \"delete the snack\", \"move breakfast to 9am\" — rather than reporting \
NEW consumption, set `no_loggable_content` to true and return an empty `entries` \
array. This local path logs NEW consumption ONLY; a correction is routed to the hosted \
path, which owns the correction contract. When you cannot tell a new item from an edit \
to an existing one, treat it as an amendment (omit it).\n\
\n\
SCHEMA (return exactly this shape):\n\
{DIET_EXTRACT_SCHEMA}\n\
\n\
MESSAGE:\n{utterance}"
    )
}

/// Build the hosted VERIFY prompt: the raw utterance plus the candidate entries, and
/// a per-entry approve/correct/reject instruction with the tolerance band spelled
/// out (differs by more than 20% OR 75 kcal per item). Returns a `verdicts` array,
/// one verdict per candidate, in order.
pub fn build_diet_verify_prompt(utterance: &str, candidates_json: &str, owner: &str) -> String {
    format!(
        "You are the VERIFY gate for a diet-logging pipeline. A cheap local model \
parsed {owner}'s message into candidate per-item entries. Check each one against the \
message before it is written to their logs. Return ONLY a JSON object — no prose.\n\
\n\
For EACH candidate, in order, emit one verdict:\n\
- \"approve\": the item and its macros are right (within tolerance).\n\
- \"correct\": the SAME item, but a macro is off — supply the corrected \
kcal/protein_g/carbs_g/fat_g/fiber_g you believe are right. Only correct numbers; \
never change what the item IS.\n\
- \"reject\": the entry is wrong in a way a number fix can't cure — it aggregates \
several foods, invents an item the message didn't mention, has the wrong item, or \
its macros are a whole-meal total rather than a per-item value.\n\
\n\
TOLERANCE: treat a macro as out of band (needs \"correct\") when your estimate \
differs from the candidate by MORE than the larger of 20% and 75 kcal per item; \
within that, \"approve\".\n\
\n\
SCHEMA:\n\
{{ \"verdicts\": [ {{ \"verdict\": \"approve|correct|reject\", \"kcal\": <num>, \
\"protein_g\": <num>, \"carbs_g\": <num>, \"fat_g\": <num>, \"fiber_g\": <num>, \
\"reason\": \"<short>\" }} ] }}\n\
\n\
MESSAGE:\n{utterance}\n\
\n\
CANDIDATES:\n{candidates_json}"
    )
}

/// Serialize validated entries back to the compact JSON the verify prompt embeds.
pub fn entries_to_json(entries: &[DietEntry]) -> String {
    let arr: Vec<Value> = entries.iter().map(entry_to_value).collect();
    serde_json::to_string(&json!({ "entries": arr }))
        .unwrap_or_else(|_| "{\"entries\":[]}".to_string())
}

fn entry_to_value(e: &DietEntry) -> Value {
    match e {
        DietEntry::Food(f) => json!({
            "kind": "food", "name": f.name, "meal": f.meal, "time": f.time,
            "amount": f.amount, "kcal": f.kcal, "protein_g": f.protein_g,
            "carbs_g": f.carbs_g, "fat_g": f.fat_g, "fiber_g": f.fiber_g,
        }),
        DietEntry::Exercise(x) => json!({
            "kind": "exercise", "activity": x.activity, "time": x.time,
            "distance_km": x.distance_km, "duration": x.duration, "calories": x.calories,
        }),
        DietEntry::Weight(w) => json!({
            "kind": "weight", "weight_lbs": w.weight_lbs, "weight_kg": w.weight_kg,
            "body_fat_pct": w.body_fat_pct, "muscle_mass_lbs": w.muscle_mass_lbs,
        }),
    }
}

// ---- Ladder + orchestrator -------------------------------------------------

/// The fallback ladder. Rungs 1–4 fall through to the hosted turn; rung 5 keeps the
/// committed CSV and omits the mirror. Numbered to match the design.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DietRung {
    /// 1 — gate unsure / `mode != tell`. (Decided in the handler; never reaches here.)
    GateOrMode = 1,
    /// 2 — extract child errored, timed out, returned malformed JSON, or
    ///     `no_loggable_content`.
    Child = 2,
    /// 3 — verify rejected, a correction wasn't trivially safe, or verify itself
    ///     couldn't produce verdicts.
    Verify = 3,
    /// 4 — append or a validate/verify hook failed (rolled back, no commit).
    Append = 4,
    /// 5 — mirror build failed after a good append (CSV stays committed).
    Mirror = 5,
}

impl DietRung {
    /// The rung number (for provenance + the metrics line), mirroring
    /// [`vaultqa::VaultqaRung::num`].
    pub fn num(self) -> u8 {
        self as u8
    }
}

/// The outcome of the local pipeline for one turn.
pub enum DietPipelineOutcome {
    /// Logged locally: the ASCII dashboard reply plus the derived directives (mirror).
    Logged {
        dashboard: String,
        directives: Directives,
    },
    /// Logged locally but the mirror was omitted (rung 5): CSV committed, no directive.
    LoggedNoMirror { dashboard: String },
    /// Fall through to the hosted turn at the given rung (2–4). `reason` carries the
    /// machine-readable [`Rung2Reason`] on a rung-2 fall-through (the only rung with a
    /// reason taxonomy); `None` for rungs 3–4.
    FallThrough {
        rung: DietRung,
        reason: Option<Rung2Reason>,
    },
    /// The blocking hosted VERIFY child could not be reached (it errored — the verify
    /// child is ambient/hosted, so this is a hosted-outage signal). Carries everything
    /// the emergency path needs to QUEUE the extracted entry for later verify
    /// ([`dietqueue`]). A non-emergency caller treats this EXACTLY like
    /// `FallThrough { rung: Verify }` — runs the hosted turn — so with emergency off the
    /// behavior is byte-for-byte unchanged. Nothing here is appended to the CSVs.
    VerifyUnavailable {
        err: ApiError,
        utterance: String,
        entries: Vec<DietEntry>,
        date: String,
        offset: String,
    },
}

/// Stamp every food entry that carries no explicitly-stated `time` with the turn's
/// received-at wall clock (`HH:MM`). The bridge — never the model — owns the fallback
/// time: the toolless extract child has no clock and returns a time ONLY when the
/// utterance states one, so an absent/blank time here means "not stated" and is filled
/// with `received_hhmm`. An explicitly-stated time is left untouched (it always wins).
/// Runs at APPEND, so the filled time flows through the normal row + mirror path and
/// leaves the derived dashboard/Apple-Health re-derivation unchanged.
pub fn stamp_missing_food_times(entries: &mut [DietEntry], received_hhmm: &str) {
    for e in entries.iter_mut() {
        if let DietEntry::Food(f) = e {
            let stated = f
                .time
                .as_deref()
                .map(str::trim)
                .is_some_and(|t| !t.is_empty());
            if !stated {
                f.time = Some(received_hhmm.to_string());
            }
        }
    }
}

/// Split validated entries by kind (used by both the orchestrator and its tests).
pub fn split_entries(
    entries: &[DietEntry],
) -> (Vec<FoodEntry>, Vec<ExerciseEntry>, Vec<WeightEntry>) {
    let mut food = Vec::new();
    let mut exercise = Vec::new();
    let mut weight = Vec::new();
    for e in entries {
        match e {
            DietEntry::Food(f) => food.push(f.clone()),
            DietEntry::Exercise(x) => exercise.push(x.clone()),
            DietEntry::Weight(w) => weight.push(w.clone()),
        }
    }
    (food, exercise, weight)
}

/// Run the local diet pipeline for one turn. Sequences the tested stages and returns
/// a [`DietPipelineOutcome`]; emits exactly one provenance line. The caller (the
/// spawned turn task in `handlers::jesse`) turns `Logged`/`LoggedNoMirror` into a
/// completed job and `FallThrough` into today's hosted `run_claude_streaming`.
///
/// `cfg.diet_backend` MUST be `Some` here (the handler gate guarantees it); the
/// extract child is pointed at that backend and the verify child stays ambient.
pub async fn run_diet_pipeline(cfg: &Config, utterance: &str) -> DietPipelineOutcome {
    let (base_url, model) = match &cfg.diet_backend {
        Some((b, _t, m)) => (b.clone(), m.clone()),
        // Defensive: never entered without a backend, but degrade rather than panic.
        None => {
            eprintln!("jesse-bridge: diet pipeline invoked with no backend — falling through");
            return DietPipelineOutcome::FallThrough {
                rung: DietRung::Child,
                reason: Some(Rung2Reason::ChildError),
            };
        }
    };
    // The turn's received-at wall clock (`HH:MM`), captured as the pipeline receives
    // the turn. The bridge stamps this onto any food entry whose time the utterance
    // never stated (see [`stamp_missing_food_times`]); the model never invents a time.
    let received_hhmm = local_hhmm();
    let prov = |local: bool, rung: Option<u8>, verify: &str, rows: usize, mirror: bool| {
        eprintln!(
            "{}",
            format_diet_provenance(local, rung, &base_url, &model, verify, rows, mirror, None)
        );
    };
    // Rung-2 (Child) fall-through: emit provenance WITH the machine-readable reason and
    // return it so the handler threads it into the metrics line. Every rung-2 cause is
    // distinguished here (the audit separates failures from correct rejections).
    let fall_child = |reason: Rung2Reason| {
        eprintln!(
            "{}",
            format_diet_provenance(
                false,
                Some(2),
                &base_url,
                &model,
                "n/a",
                0,
                false,
                Some(&reason.code()),
            )
        );
        DietPipelineOutcome::FallThrough {
            rung: DietRung::Child,
            reason: Some(reason),
        }
    };

    // Stage 1 — extract.
    let extract_raw = match run_diet_extract(
        cfg,
        &build_diet_extract_prompt(utterance, &cfg.persona.owner_name),
        DIET_EXTRACT_TIMEOUT_SECS,
    )
    .await
    {
        Ok(s) => s,
        Err(_) => return fall_child(Rung2Reason::ChildError),
    };
    let extract = match parse_diet_entries(&extract_raw) {
        Ok(e) if e.no_loggable_content => return fall_child(Rung2Reason::NoLoggable),
        Ok(e) if e.entries.is_empty() => return fall_child(Rung2Reason::EmptyEntries),
        Ok(e) => e,
        Err(msg) => return fall_child(Rung2Reason::from_parse_error(&msg)),
    };

    // Stage 2 — verify (probation: mandatory, blocking, 100%).
    let verify_raw = match run_diet_verify(
        cfg,
        &build_diet_verify_prompt(utterance, &entries_to_json(&extract.entries), &cfg.persona.owner_name),
        DIET_VERIFY_TIMEOUT_SECS,
    )
    .await
    {
        Ok(s) => s,
        Err(e) => {
            // The verify child (ambient/hosted) errored — surface it as VerifyUnavailable
            // carrying the extract so an emergency caller can queue it. A non-emergency
            // caller maps this straight back to a hosted fall-through (Verify rung), so
            // today's behavior is unchanged.
            prov(false, Some(3), "unavailable", extract.entries.len(), false);
            return DietPipelineOutcome::VerifyUnavailable {
                err: e,
                utterance: utterance.to_string(),
                entries: extract.entries,
                date: local_today(),
                offset: local_offset(),
            };
        }
    };
    let verdicts = match parse_verify_verdicts(&verify_raw, extract.entries.len()) {
        Ok(v) => v,
        Err(_) => {
            prov(false, Some(3), "unavailable", extract.entries.len(), false);
            return DietPipelineOutcome::FallThrough {
                rung: DietRung::Verify,
                reason: None,
            };
        }
    };
    let mut verified = Vec::with_capacity(extract.entries.len());
    let mut any_corrected = false;
    for (entry, v) in extract.entries.iter().zip(verdicts.iter()) {
        match resolve_verdict(entry, v) {
            Some(e) => {
                if e != *entry {
                    any_corrected = true;
                }
                verified.push(e);
            }
            None => {
                // Any verify-stage fall-through (a reject, or a correction that wasn't
                // trivially safe) is "rejected" for provenance — the turn is not logged.
                prov(false, Some(3), "rejected", extract.entries.len(), false);
                return DietPipelineOutcome::FallThrough {
                    rung: DietRung::Verify,
                    reason: None,
                };
            }
        }
    }
    let verify_word = if any_corrected {
        "corrected"
    } else {
        "approved"
    };

    // Stage 3 — append + hooks + commit (atomic per turn). Fill any unstated food
    // time with the turn's received-at wall clock BEFORE building rows, so the time
    // flows through the normal row + mirror path (bridge owns received-at).
    stamp_missing_food_times(&mut verified, &received_hhmm);
    let (food, exercise, weight) = split_entries(&verified);
    let date = local_today();
    let food_rows: Vec<String> = food.iter().map(|f| food_row(f, &date)).collect();
    let ex_rows: Vec<String> = exercise.iter().map(|x| exercise_row(x, &date)).collect();
    let wt_rows: Vec<String> = weight.iter().map(|w| weight_row(w, &date)).collect();
    let logs_dir = Path::new(&cfg.vault).join("diet-logs");
    let vault = Path::new(&cfg.vault);

    let snapshot = match append_rows_atomic(&logs_dir, &food_rows, &ex_rows, &wt_rows) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("jesse-bridge: diet append failed: {e}");
            prov(false, Some(4), verify_word, verified.len(), false);
            return DietPipelineOutcome::FallThrough {
                rung: DietRung::Append,
                reason: None,
            };
        }
    };
    if let Err(e) = run_diet_hooks(vault).await {
        eprintln!("jesse-bridge: diet hooks failed: {e}");
        snapshot.rollback();
        prov(false, Some(4), verify_word, verified.len(), false);
        return DietPipelineOutcome::FallThrough {
            rung: DietRung::Append,
            reason: None,
        };
    }
    if let Err(e) = commit_diet_logs(vault, &date, &local_hhmm()).await {
        eprintln!("jesse-bridge: diet commit failed: {e}");
        snapshot.rollback();
        prov(false, Some(4), verify_word, verified.len(), false);
        return DietPipelineOutcome::FallThrough {
            rung: DietRung::Append,
            reason: None,
        };
    }

    // Stage 4 — dashboard + mirror. Both are DERIVED from the committed CSVs: the
    // dashboard reflects the whole DAY's totals (re-read from food-log.csv), while
    // the mirror is per just-appended item.
    let totals = std::fs::read_to_string(logs_dir.join("food-log.csv"))
        .ok()
        .map(|c| sum_food_csv_for_date(&c, &date))
        .unwrap_or_else(|| sum_food_macros(&food));
    let targets = std::fs::read_to_string(logs_dir.join("daily-targets.csv"))
        .ok()
        .map(|c| targets_for_date(&c, &date))
        .unwrap_or_default();
    let dashboard = render_diet_dashboard(&date, &totals, &targets);

    match build_meal_log_from_food_rows(&food, &date, &local_offset()) {
        Ok(Some(meal_log)) => {
            prov(true, None, verify_word, verified.len(), true);
            DietPipelineOutcome::Logged {
                dashboard,
                directives: Directives {
                    needs_health: None,
                    meal_log: Some(meal_log),
                },
            }
        }
        Ok(None) => {
            // No food rows (exercise/weigh-in-only): no mirror to emit — a normal
            // local success, not a failure.
            prov(true, None, verify_word, verified.len(), false);
            DietPipelineOutcome::Logged {
                dashboard,
                directives: Directives {
                    needs_health: None,
                    meal_log: None,
                },
            }
        }
        Err(e) => {
            // Mirror build failed AFTER a good append+commit (rung 5): keep the CSV,
            // omit the mirror (matches today's malformed-directive fail-safe).
            eprintln!("jesse-bridge: diet mirror build failed: {e}");
            prov(true, Some(5), verify_word, verified.len(), false);
            DietPipelineOutcome::LoggedNoMirror { dashboard }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Anti-aggregation --------------------------------------------------

    #[test]
    fn single_item_names_are_not_aggregated() {
        for name in [
            "Banana",
            "Greek yogurt",
            "Salmon sockeye (Fiorfiore, canned)", // comma lives inside the brand note
            "Egg (whole, large)",
            "Almonds (20g)",
            "Tahini (Mighty Sesame Co)",
        ] {
            assert!(!name_is_aggregated(name), "single item flagged: {name:?}");
        }
    }

    #[test]
    fn multi_item_names_are_aggregated() {
        for name in [
            "Eggs and toast",
            "Rice, chicken",
            "Yogurt with granola",
            "Chicken + rice",
            "Toast & jam",
            "Pasta, sauce, and cheese",
        ] {
            assert!(name_is_aggregated(name), "aggregate not flagged: {name:?}");
        }
    }

    #[test]
    fn parse_rejects_an_aggregated_food_entry() {
        let json = r#"{"entries":[{"kind":"food","name":"Eggs and toast","meal":"Breakfast","time":"08:00","kcal":300}]}"#;
        assert!(
            parse_diet_entries(json).is_err(),
            "aggregated name must reject"
        );
    }

    // ---- Extract parsing ---------------------------------------------------

    #[test]
    fn parses_a_clean_per_item_extract() {
        let json = r#"{
          "no_loggable_content": false,
          "entries": [
            {"kind":"food","name":"Banana","meal":"Snack","time":"10:40","amount":"1 medium (~118g)","kcal":105,"protein_g":1.3,"carbs_g":27,"fat_g":0.4,"fiber_g":3},
            {"kind":"exercise","activity":"Run","time":"06:30","distance_km":8.0,"duration":"56:58","calories":520},
            {"kind":"weight","weight_lbs":198.4,"weight_kg":90.0,"body_fat_pct":18.2}
          ]
        }"#;
        let ex = parse_diet_entries(json).expect("parses");
        assert!(!ex.no_loggable_content);
        assert_eq!(ex.entries.len(), 3);
        match &ex.entries[0] {
            DietEntry::Food(f) => {
                assert_eq!(f.name, "Banana");
                assert_eq!(f.kcal, Some(105.0));
                assert_eq!(f.fiber_g, Some(3.0));
            }
            other => panic!("expected food, got {other:?}"),
        }
    }

    #[test]
    fn parses_food_micronutrients_all_some_or_none() {
        // All seven present, a subset present, and none present must ALL parse — each
        // micronutrient is optional and unknown-is-not-zero (absent → None).
        let json = r#"{"entries":[
            {"kind":"food","name":"Prosciutto","meal":"Lunch","time":"12:00","kcal":120,"sodium_mg":900,"satfat_g":2.5,"sugar_g":0,"potassium_mg":180,"calcium_mg":8,"omega3_mg":40,"magnesium_mg":20},
            {"kind":"food","name":"Cracker","meal":"Snack","time":"15:00","kcal":80,"sodium_mg":150,"sugar_g":1.2,"calcium_mg":12},
            {"kind":"food","name":"Banana","meal":"Snack","time":"10:00","kcal":105}
        ]}"#;
        let ex = parse_diet_entries(json).expect("all three parse");
        let foods: Vec<&FoodEntry> = ex
            .entries
            .iter()
            .filter_map(|e| match e {
                DietEntry::Food(f) => Some(f),
                _ => None,
            })
            .collect();
        // All seven present.
        assert_eq!(foods[0].sodium_mg, Some(900.0));
        assert_eq!(foods[0].satfat_g, Some(2.5));
        assert_eq!(foods[0].sugar_g, Some(0.0), "explicit measured zero");
        assert_eq!(foods[0].potassium_mg, Some(180.0));
        assert_eq!(foods[0].calcium_mg, Some(8.0));
        assert_eq!(foods[0].omega3_mg, Some(40.0));
        assert_eq!(foods[0].magnesium_mg, Some(20.0));
        // Subset present — the omitted ones stay None, not 0.
        assert_eq!(foods[1].sodium_mg, Some(150.0));
        assert_eq!(foods[1].sugar_g, Some(1.2));
        assert_eq!(foods[1].calcium_mg, Some(12.0));
        assert_eq!(foods[1].satfat_g, None);
        assert_eq!(foods[1].potassium_mg, None);
        assert_eq!(foods[1].omega3_mg, None);
        assert_eq!(foods[1].magnesium_mg, None);
        // None present — all seven absent.
        assert!(
            foods[2].sodium_mg.is_none()
                && foods[2].satfat_g.is_none()
                && foods[2].sugar_g.is_none()
                && foods[2].potassium_mg.is_none()
                && foods[2].calcium_mg.is_none()
                && foods[2].omega3_mg.is_none()
                && foods[2].magnesium_mg.is_none()
        );
    }

    #[test]
    fn parse_rejects_negative_micronutrient() {
        // A micronutrient shares the finite/non-negative discipline of the macros —
        // including the three newest ones.
        assert!(parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"09:00","sodium_mg":-5}]}"#
        )
        .is_err());
        assert!(parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"09:00","calcium_mg":-1}]}"#
        )
        .is_err());
        assert!(parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"09:00","omega3_mg":-1}]}"#
        )
        .is_err());
        assert!(parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"09:00","magnesium_mg":-1}]}"#
        )
        .is_err());
    }

    #[test]
    fn blank_micronutrient_round_trips_to_unknown_not_zero() {
        // End-to-end: a food entry with NO sodium builds a row whose Sodium_mg cell is
        // empty, and reading that row back through the shipped CSV reader yields JSON
        // null (unknown) for `na` — never 0.
        let e = FoodEntry {
            name: "Banana".into(),
            meal: "Snack".into(),
            time: Some("10:00".into()),
            amount: None,
            unit: None,
            kcal: Some(105.0),
            protein_g: Some(1.3),
            carbs_g: Some(27.0),
            fat_g: Some(0.4),
            fiber_g: Some(3.0),
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        };
        let csv = format!("{FOOD_LOG_HEADER}\n{}\n", food_row(&e, "2026-07-13"));
        let (meals, _errors) = crate::diet::reconstruct_meals(&csv, "2026-07-13");
        let item = &meals[0]["items"][0];
        assert!(
            item["na"].is_null(),
            "blank Sodium_mg reads back as null, not 0"
        );
        assert!(item["satf"].is_null(), "blank SatFat_g reads back as null");
        assert!(item["sug"].is_null(), "blank Sugar_g reads back as null");
        assert!(item["k"].is_null(), "blank Potassium_mg reads back as null");
        assert!(item["ca"].is_null(), "blank Calcium_mg reads back as null");
        assert!(item["o3"].is_null(), "blank Omega3_mg reads back as null");
        assert!(
            item["mg"].is_null(),
            "blank Magnesium_mg reads back as null"
        );
    }

    #[test]
    fn known_micronutrient_round_trips_through_the_reader() {
        // The mirror image: a KNOWN sodium survives the row build and reads back as its
        // number (proving the write column lands where the reader expects it).
        let e = FoodEntry {
            name: "Prosciutto".into(),
            meal: "Lunch".into(),
            time: Some("12:00".into()),
            amount: None,
            unit: None,
            kcal: Some(120.0),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sodium_mg: Some(900.0),
            satfat_g: Some(2.5),
            sugar_g: Some(0.0),
            potassium_mg: Some(180.0),
            calcium_mg: Some(8.0),
            omega3_mg: Some(40.0),
            magnesium_mg: Some(20.0),
            notes: None,
        };
        let csv = format!("{FOOD_LOG_HEADER}\n{}\n", food_row(&e, "2026-07-13"));
        let (meals, _errors) = crate::diet::reconstruct_meals(&csv, "2026-07-13");
        let item = &meals[0]["items"][0];
        assert_eq!(item["na"], 900.0);
        assert_eq!(item["satf"], 2.5);
        assert_eq!(item["sug"], 0.0, "measured-zero sugar reads back as 0");
        assert_eq!(item["k"], 180.0);
        assert_eq!(item["ca"], 8.0, "known calcium survives write→read");
        assert_eq!(item["o3"], 40.0, "known omega-3 survives write→read");
        assert_eq!(item["mg"], 20.0, "known magnesium survives write→read");
    }

    #[test]
    fn no_loggable_content_flag_parses() {
        let ex = parse_diet_entries(r#"{"no_loggable_content":true,"entries":[]}"#).unwrap();
        assert!(ex.no_loggable_content);
        assert!(ex.entries.is_empty());
    }

    #[test]
    fn missing_or_null_time_is_accepted_not_schema_failed() {
        // "ate 1 almond" — the utterance states no clock time. The toolless extract
        // child has no clock, so it omits (or nulls) `time`; the bridge owns the
        // received-at fallback at append. Requiring `time` here made this a
        // DETERMINISTIC rung-2 schema-fail (3/3 reruns in the 2026-07-15
        // investigation). The parser must ACCEPT an absent/null time.
        let omitted = r#"{"entries":[{"kind":"food","name":"almond","meal":"Snack"}]}"#;
        assert!(
            parse_diet_entries(omitted).is_ok(),
            "an omitted time must parse (bridge fills received-at), not schema-fail"
        );
        let null = r#"{"entries":[{"kind":"food","name":"almond","meal":"Snack","time":null}]}"#;
        assert!(
            parse_diet_entries(null).is_ok(),
            "a null time must parse (bridge fills received-at), not schema-fail"
        );
        // An omitted time parses to `None` (not stated) — never a fabricated value.
        match &parse_diet_entries(omitted).unwrap().entries[0] {
            DietEntry::Food(f) => assert_eq!(f.time, None, "unstated time stays None until append"),
            other => panic!("expected food, got {other:?}"),
        }
    }

    #[test]
    fn stamp_fills_only_unstated_food_times_with_received_at() {
        // The bridge owns received-at: a food entry with no stated time is stamped at
        // append; an explicitly-stated time always wins and is left untouched.
        let mut entries = vec![
            DietEntry::Food(FoodEntry {
                name: "almond".into(),
                meal: "Snack".into(),
                time: None, // unstated → should be filled
                amount: None,
                unit: None,
                kcal: Some(7.0),
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sodium_mg: None,
                satfat_g: None,
                sugar_g: None,
                potassium_mg: None,
                calcium_mg: None,
                omega3_mg: None,
                magnesium_mg: None,
                notes: None,
            }),
            DietEntry::Food(FoodEntry {
                name: "toast".into(),
                meal: "Breakfast".into(),
                time: Some("07:15".into()), // explicit → must be preserved
                amount: None,
                unit: None,
                kcal: Some(120.0),
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sodium_mg: None,
                satfat_g: None,
                sugar_g: None,
                potassium_mg: None,
                calcium_mg: None,
                omega3_mg: None,
                magnesium_mg: None,
                notes: None,
            }),
        ];
        stamp_missing_food_times(&mut entries, "17:44");
        match (&entries[0], &entries[1]) {
            (DietEntry::Food(a), DietEntry::Food(b)) => {
                assert_eq!(
                    a.time.as_deref(),
                    Some("17:44"),
                    "unstated time gets received-at"
                );
                assert_eq!(b.time.as_deref(), Some("07:15"), "stated time is preserved");
            }
            _ => panic!("expected two food entries"),
        }
    }

    #[test]
    fn unstated_time_flows_through_row_and_mirror_as_received_at() {
        // End to end at the append layer: an unstated-time item, once stamped, carries
        // received-at into BOTH the CSV Time column and the derived mirror `consumedAt`
        // — the normal row path, so dashboard re-derivation is unchanged by the fill.
        let mut entries = parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"almond","meal":"Snack","kcal":7}]}"#,
        )
        .unwrap()
        .entries;
        stamp_missing_food_times(&mut entries, "17:44");
        let (food, _, _) = split_entries(&entries);
        // CSV Time column (13th field) is the received-at time.
        let row = food_row(&food[0], "2026-07-16");
        assert_eq!(
            row.split(',').nth(12),
            Some("17:44"),
            "Time cell = received-at: {row}"
        );
        // Mirror consumedAt derives from the same filled time.
        let mirror = build_meal_log_from_food_rows(&food, "2026-07-16", "+00:00")
            .unwrap()
            .expect("a food row yields a mirror");
        assert_eq!(mirror.meals[0].consumed_at, "2026-07-16T17:44:00+00:00");
    }

    #[test]
    fn stated_time_is_preserved_end_to_end() {
        // "lunch at 12:30" — an explicit time survives parse → row → mirror untouched.
        let entries = parse_diet_entries(
            r#"{"entries":[{"kind":"food","name":"salad","meal":"Lunch","time":"12:30","kcal":250}]}"#,
        )
        .unwrap()
        .entries;
        // No stamping needed, but even if append runs it, the stated time wins.
        let mut e2 = entries.clone();
        stamp_missing_food_times(&mut e2, "17:44");
        let (food, _, _) = split_entries(&e2);
        let row = food_row(&food[0], "2026-07-16");
        assert_eq!(
            row.split(',').nth(12),
            Some("12:30"),
            "stated Time cell preserved: {row}"
        );
        let mirror = build_meal_log_from_food_rows(&food, "2026-07-16", "+00:00")
            .unwrap()
            .unwrap();
        assert_eq!(mirror.meals[0].consumed_at, "2026-07-16T12:30:00+00:00");
    }

    #[test]
    fn parse_rejects_malformed_and_off_contract() {
        for bad in [
            "not json",
            r#"{"entries":"nope"}"#,
            r#"{"entries":[{"kind":"food"}]}"#, // missing name/meal (time is now optional)
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","kcal":-5}]}"#, // negative
            r#"{"entries":[{"kind":"bogus"}]}"#,
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","added_sugar_g":5}]}"#, // still-unknown key (a schema field like sodium_mg/calcium_mg/omega3_mg now parses)
            r#"{"extra":1,"entries":[]}"#, // unknown top-level
        ] {
            assert!(parse_diet_entries(bad).is_err(), "should reject: {bad}");
        }
    }

    #[test]
    fn null_and_empty_optional_macros_are_absent_zero_is_measured() {
        // The prompt says "omit unknowns"; the model nulls them instead (or emits an
        // empty string). Both must mean ABSENT for an optional macro — the
        // null-is-a-violation rule was a top rung-2 cause (10/20 turns, with missing
        // time, in the 2026-07-15 investigation).
        let base = |body: &str| {
            format!(
                r#"{{"entries":[{{"kind":"food","name":"n","meal":"Snack","time":"09:00",{body}}}]}}"#
            )
        };
        for body in [r#""kcal":null"#, r#""kcal":"""#, r#""protein_g":null"#] {
            let ex = parse_diet_entries(&base(body))
                .unwrap_or_else(|e| panic!("{body} must parse: {e:?}"));
            match &ex.entries[0] {
                DietEntry::Food(f) => {
                    if body.contains("protein_g") {
                        assert_eq!(f.protein_g, None, "null protein_g is absent: {body}");
                    } else {
                        assert_eq!(f.kcal, None, "null/empty kcal is absent: {body}");
                    }
                }
                other => panic!("expected food, got {other:?}"),
            }
        }
        // A literal 0 remains a MEASURED zero, never absent.
        let z = parse_diet_entries(&base(r#""kcal":0"#)).unwrap();
        match &z.entries[0] {
            DietEntry::Food(f) => assert_eq!(f.kcal, Some(0.0), "0 is a measured zero, not absent"),
            other => panic!("expected food, got {other:?}"),
        }
        // Still strict: a negative or non-numeric value is a schema violation.
        assert!(
            parse_diet_entries(&base(r#""kcal":-5"#)).is_err(),
            "negative still rejected"
        );
        assert!(
            parse_diet_entries(&base(r#""kcal":"abc""#)).is_err(),
            "non-numeric string still rejected"
        );
    }

    #[test]
    fn verify_verdict_macro_parsing_stays_strict_on_null() {
        // The null/empty tolerance is EXTRACT-only. The hosted verify verdict parser
        // stays strict (a null macro is a violation → rung 3), so verify-gate behavior
        // is unchanged by Fix 2.
        assert!(
            parse_verify_verdicts(r#"{"verdicts":[{"verdict":"approve","kcal":null}]}"#, 1)
                .is_err(),
            "verify parsing must stay strict on a null macro"
        );
        // A well-formed verdict still parses.
        assert!(
            parse_verify_verdicts(r#"{"verdicts":[{"verdict":"approve","kcal":100}]}"#, 1).is_ok()
        );
    }

    #[test]
    fn fenced_json_payload_parses_after_fence_strip() {
        // Through the production CLI child shape the model fences its JSON in a markdown
        // code block on some turns (turns 4, 11, 13 of the 2026-07-15 investigation —
        // 3/20 rung-2 turns were "fenced malformed", off correct comprehension). A full
        // outer fence must be stripped before parsing.
        let tagged = "```json\n{\"entries\":[{\"kind\":\"food\",\"name\":\"almond\",\"meal\":\"Snack\",\"kcal\":7}]}\n```";
        let ex = parse_diet_entries(tagged)
            .unwrap_or_else(|e| panic!("fenced (```json) payload must parse: {e:?}"));
        assert_eq!(ex.entries.len(), 1, "fenced entry parses");
        // A bare ``` fence (no language tag), with surrounding whitespace, too.
        let bare = "\n```\n{\"no_loggable_content\":true,\"entries\":[]}\n```\n";
        assert!(
            parse_diet_entries(bare).unwrap().no_loggable_content,
            "bare-fenced payload must parse"
        );
    }

    #[test]
    fn strip_code_fence_only_unwraps_a_full_outer_fence() {
        // A full wrapper (tagged or bare) → interior returned.
        assert_eq!(strip_code_fence("```json\n{\"a\":1}\n```"), "{\"a\":1}");
        assert_eq!(strip_code_fence("```\n{\"a\":1}\n```"), "{\"a\":1}");
        // Unfenced payload → returned verbatim (the common case, no regression).
        assert_eq!(strip_code_fence("{\"a\":1}"), "{\"a\":1}");
        // A fence INSIDE a JSON string value must never be modified — the payload is
        // not itself fence-wrapped, so it passes through untouched.
        let inner = "{\"notes\":\"see ```code``` block\"}";
        assert_eq!(strip_code_fence(inner), inner);
        // Not fully wrapped: no closing fence line → left exactly as-is.
        assert_eq!(strip_code_fence("```json\n{\"a\":1}"), "```json\n{\"a\":1}");
        // Prose before the fence (payload does not START with the fence) → untouched.
        let trailing = "here you go:\n```json\n{\"a\":1}\n```";
        assert_eq!(strip_code_fence(trailing), trailing);
    }

    #[test]
    fn fence_inside_a_string_value_survives_parse() {
        // An unfenced payload whose Notes field legitimately contains backticks parses
        // with the backticks intact (the strip never runs on a non-wrapped payload).
        let json = r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"09:00","notes":"label reads ```200 kcal```"}]}"#;
        match &parse_diet_entries(json).unwrap().entries[0] {
            DietEntry::Food(f) => {
                assert_eq!(f.notes.as_deref(), Some("label reads ```200 kcal```"))
            }
            other => panic!("expected food, got {other:?}"),
        }
    }

    #[test]
    fn parse_enforces_entry_cap() {
        let one = r#"{"kind":"food","name":"x","meal":"Snack","time":"09:00","kcal":1}"#;
        let over = std::iter::repeat_n(one, MAX_DIET_ENTRIES + 1)
            .collect::<Vec<_>>()
            .join(",");
        assert!(parse_diet_entries(&format!("{{\"entries\":[{over}]}}")).is_err());
        let at = std::iter::repeat_n(one, MAX_DIET_ENTRIES)
            .collect::<Vec<_>>()
            .join(",");
        assert!(parse_diet_entries(&format!("{{\"entries\":[{at}]}}")).is_ok());
    }

    #[test]
    fn weight_derives_lbs_from_kg_when_lbs_absent() {
        let json = r#"{"entries":[{"kind":"weight","weight_kg":90.0}]}"#;
        let ex = parse_diet_entries(json).unwrap();
        match &ex.entries[0] {
            DietEntry::Weight(w) => assert!(
                (w.weight_lbs - 198.4).abs() < 0.1,
                "kg→lbs: {}",
                w.weight_lbs
            ),
            other => panic!("expected weight, got {other:?}"),
        }
    }

    // ---- Tolerance ---------------------------------------------------------

    #[test]
    fn tolerance_75kcal_arm_dominates_for_small_items() {
        // reference 200 → 20% = 40, so the 75 kcal absolute floor wins.
        assert!(!kcal_out_of_band(270.0, 200.0), "70 diff ≤ 75 → in band");
        assert!(kcal_out_of_band(280.0, 200.0), "80 diff > 75 → out of band");
    }

    #[test]
    fn tolerance_20pct_arm_dominates_for_large_items() {
        // reference 1000 → 20% = 200 > 75, so the relative arm wins.
        assert!(
            !kcal_out_of_band(1180.0, 1000.0),
            "180 diff ≤ 200 → in band"
        );
        assert!(
            kcal_out_of_band(1210.0, 1000.0),
            "210 diff > 200 → out of band"
        );
    }

    #[test]
    fn tolerance_boundary_is_inclusive_in_band() {
        // Exactly at the threshold (the larger arm) is IN band ("more than").
        assert!(
            !kcal_out_of_band(275.0, 200.0),
            "diff == 75 exactly → in band"
        );
        assert!(
            !kcal_out_of_band(1200.0, 1000.0),
            "diff == 200 (20%) exactly → in band"
        );
    }

    // ---- Verify verdict handling -------------------------------------------

    fn food(kcal: f64) -> DietEntry {
        DietEntry::Food(FoodEntry {
            name: "Banana".into(),
            meal: "Snack".into(),
            time: Some("10:00".into()),
            amount: None,
            unit: None,
            kcal: Some(kcal),
            protein_g: Some(1.0),
            carbs_g: Some(27.0),
            fat_g: Some(0.4),
            fiber_g: Some(3.0),
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        })
    }
    fn verdict(v: Verdict, kcal: Option<f64>) -> EntryVerdict {
        EntryVerdict {
            verdict: v,
            kcal,
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            reason: None,
        }
    }

    #[test]
    fn approve_in_band_keeps_the_candidate() {
        let e = food(105.0);
        assert_eq!(
            resolve_verdict(&e, &verdict(Verdict::Approve, Some(110.0))),
            Some(e),
            "in-band approve must keep candidate"
        );
    }

    #[test]
    fn approve_but_out_of_band_becomes_a_correction() {
        // Verifier "approves" but its kcal estimate is wildly off (105 vs 400) — we
        // do not blindly write the candidate; the verifier's number is used instead.
        let e = food(105.0);
        match resolve_verdict(&e, &verdict(Verdict::Approve, Some(400.0))) {
            Some(DietEntry::Food(f)) => assert_eq!(f.kcal, Some(400.0)),
            other => panic!("expected corrected kcal, got {other:?}"),
        }
    }

    #[test]
    fn correct_applies_verifier_numbers_same_item() {
        let e = food(105.0);
        match resolve_verdict(&e, &verdict(Verdict::Correct, Some(120.0))) {
            Some(DietEntry::Food(f)) => {
                assert_eq!(f.kcal, Some(120.0));
                assert_eq!(f.name, "Banana", "item identity unchanged (trivially safe)");
                assert_eq!(
                    f.carbs_g,
                    Some(27.0),
                    "untouched macro keeps candidate value"
                );
            }
            other => panic!("expected correction, got {other:?}"),
        }
    }

    #[test]
    fn correction_carries_micronutrients_through_untouched() {
        // The verifier only corrects the five macros; every micronutrient rides the
        // `..f.clone()` spread untouched. A kcal correction must not disturb a known
        // sodium/calcium value (nor invent one on an absent potassium/magnesium).
        let e = DietEntry::Food(FoodEntry {
            name: "Crackers".into(),
            meal: "Snack".into(),
            time: Some("15:00".into()),
            amount: None,
            unit: None,
            kcal: Some(100.0),
            protein_g: Some(2.0),
            carbs_g: Some(18.0),
            fat_g: Some(3.0),
            fiber_g: Some(1.0),
            sodium_mg: Some(230.0),
            satfat_g: Some(0.5),
            sugar_g: Some(0.0),
            potassium_mg: None,
            calcium_mg: Some(45.0),
            omega3_mg: Some(30.0),
            magnesium_mg: None,
            notes: None,
        });
        match resolve_verdict(&e, &verdict(Verdict::Correct, Some(140.0))) {
            Some(DietEntry::Food(f)) => {
                assert_eq!(f.kcal, Some(140.0), "kcal corrected");
                assert_eq!(f.sodium_mg, Some(230.0), "sodium carried through untouched");
                assert_eq!(f.satfat_g, Some(0.5), "satfat untouched");
                assert_eq!(f.sugar_g, Some(0.0), "measured-zero sugar preserved");
                assert_eq!(f.potassium_mg, None, "absent potassium stays absent");
                assert_eq!(
                    f.calcium_mg,
                    Some(45.0),
                    "known calcium carried through untouched"
                );
                assert_eq!(
                    f.omega3_mg,
                    Some(30.0),
                    "known omega-3 carried through untouched"
                );
                assert_eq!(f.magnesium_mg, None, "absent magnesium stays absent");
            }
            other => panic!("expected correction, got {other:?}"),
        }
    }

    #[test]
    fn reject_falls_through_to_hosted() {
        assert_eq!(
            resolve_verdict(&food(105.0), &verdict(Verdict::Reject, None)),
            None
        );
    }

    #[test]
    fn correction_with_a_bad_number_is_not_trivially_safe() {
        let mut v = verdict(Verdict::Correct, Some(f64::NAN));
        v.kcal = Some(f64::NAN);
        assert_eq!(resolve_verdict(&food(105.0), &v), None);
    }

    #[test]
    fn parse_verify_verdicts_requires_one_per_entry() {
        let json = r#"{"verdicts":[{"verdict":"approve"},{"verdict":"reject"}]}"#;
        assert_eq!(parse_verify_verdicts(json, 2).unwrap().len(), 2);
        assert!(
            parse_verify_verdicts(json, 3).is_err(),
            "count mismatch rejects"
        );
        assert!(parse_verify_verdicts("nope", 2).is_err());
    }

    // ---- CSV row builders --------------------------------------------------

    #[test]
    fn food_row_follows_fill_convention_and_quotes() {
        let e = FoodEntry {
            name: "Salmon sockeye (Fiorfiore, canned)".into(),
            meal: "Breakfast".into(),
            time: Some("09:40".into()),
            amount: Some("1 can".into()),
            unit: None,
            kcal: Some(129.0),
            protein_g: Some(22.5),
            carbs_g: Some(0.0),
            fat_g: Some(2.3),
            fiber_g: Some(0.0),
            sodium_mg: Some(340.0),
            satfat_g: Some(0.5),
            sugar_g: Some(0.0),      // a real measured zero, not "unknown"
            potassium_mg: None,      // absent on the label → blank cell, never 0
            calcium_mg: Some(15.0),  // canned salmon (with bones) carries some calcium
            omega3_mg: Some(1400.0), // marine EPA+DHA — a real fish source
            magnesium_mg: None,      // absent on the label → blank cell, never 0
            notes: Some("drained, with salt".into()),
        };
        let row = food_row(&e, "2026-07-13");
        // RFC-4180: the item's comma forces quoting; the row parses back to 22 fields.
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(rec.len(), FOOD_LOG_HEADER.split(',').count(), "22 columns");
        assert_eq!(&rec[0], "2026-07-13");
        assert_eq!(&rec[1], "Breakfast");
        assert_eq!(&rec[2], "Salmon sockeye (Fiorfiore, canned)");
        assert_eq!(&rec[4], "serving", "Unit defaults to serving");
        assert_eq!(&rec[5], "", "Cal_per_100g blank");
        assert_eq!(&rec[6], "", "Grams blank");
        assert_eq!(&rec[7], "129", "kcal into Calories");
        assert_eq!(&rec[13], "Breakfast", "Meal_Type mirrors Meal");
        assert_eq!(&rec[14], "0", "fiber");
        assert_eq!(&rec[15], "340", "sodium_mg");
        assert_eq!(&rec[16], "0.5", "satfat_g");
        assert_eq!(&rec[17], "0", "sugar_g measured zero renders 0, not blank");
        assert_eq!(&rec[18], "", "potassium_mg absent → blank cell, not 0");
        assert_eq!(&rec[19], "15", "calcium_mg into Calcium_mg");
        assert_eq!(&rec[20], "1400", "omega3_mg into Omega3_mg");
        assert_eq!(&rec[21], "", "magnesium_mg absent → blank cell, not 0");
    }

    #[test]
    fn food_row_blank_macros_are_empty_cells() {
        let e = FoodEntry {
            name: "Water".into(),
            meal: "Snack".into(),
            time: Some("12:00".into()),
            amount: None,
            unit: None,
            kcal: None,
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        };
        let row = food_row(&e, "2026-07-13");
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(rec.len(), FOOD_LOG_HEADER.split(',').count(), "22 columns");
        assert_eq!(&rec[7], "", "absent kcal → empty cell, not 0");
        assert_eq!(&rec[14], "", "absent fiber → empty cell");
        assert_eq!(&rec[15], "", "absent sodium → empty cell, not 0");
        assert_eq!(&rec[16], "", "absent satfat → empty cell");
        assert_eq!(&rec[17], "", "absent sugar → empty cell");
        assert_eq!(&rec[18], "", "absent potassium → empty cell");
        assert_eq!(&rec[19], "", "absent calcium → empty cell, not 0");
        assert_eq!(&rec[20], "", "absent omega-3 → empty cell, not 0");
        assert_eq!(&rec[21], "", "absent magnesium → empty cell, not 0");
    }

    // ---- Parity: prompt ↔ append schema ------------------------------------

    #[test]
    fn prompt_contract_matches_append_schema() {
        // The parity mitigation: the extract prompt inlines the SAME header consts
        // the row builders target, so the described contract can never drift from
        // what the append path writes. Assert the prompt carries each header verbatim
        // AND that each row builder emits exactly that many columns.
        let p = build_diet_extract_prompt("hi", "the user");
        assert!(
            p.contains(FOOD_LOG_HEADER),
            "extract prompt must inline the food header"
        );
        assert!(
            p.contains(EXERCISE_LOG_HEADER),
            "extract prompt must inline the exercise header"
        );
        assert!(
            p.contains(WEIGHT_LOG_HEADER),
            "extract prompt must inline the weight header"
        );

        let count = |row: &str| {
            csv::ReaderBuilder::new()
                .has_headers(false)
                .from_reader(row.as_bytes())
                .records()
                .next()
                .unwrap()
                .unwrap()
                .len()
        };
        let f = FoodEntry {
            name: "n".into(),
            meal: "Snack".into(),
            time: Some("09:00".into()),
            amount: None,
            unit: None,
            kcal: Some(1.0),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        };
        assert_eq!(
            count(&food_row(&f, "2026-07-13")),
            FOOD_LOG_HEADER.split(',').count()
        );
        let x = ExerciseEntry {
            activity: "Run".into(),
            time: Some("06:00".into()),
            description: None,
            distance_km: Some(5.0),
            duration: None,
            pace: None,
            avg_hr: None,
            calories: None,
            notes: None,
        };
        assert_eq!(
            count(&exercise_row(&x, "2026-07-13")),
            EXERCISE_LOG_HEADER.split(',').count()
        );
        let w = WeightEntry {
            weight_lbs: 198.0,
            weight_kg: None,
            body_fat_pct: None,
            muscle_mass_lbs: None,
            notes: None,
        };
        assert_eq!(
            count(&weight_row(&w, "2026-07-13")),
            WEIGHT_LOG_HEADER.split(',').count()
        );
    }

    #[test]
    fn extract_prompt_and_schema_state_the_amendment_rule() {
        // Defect 2: the local path is insert-only. The extract prompt must instruct the
        // child to classify a correction/amendment as `no_loggable_content` (routing it
        // to the hosted path), and the schema's `no_loggable_content` description must
        // say so too — so the child never re-logs a correction as a fresh entry.
        let p = build_diet_extract_prompt("actually lunch was two bowls, about 700 kcal", "the user");
        assert!(
            p.contains("CORRECTIONS ARE NOT NEW LOGS"),
            "extract prompt must carry the amendment rule"
        );
        assert!(
            p.contains("AMENDS, corrects, moves, or deletes"),
            "amendment rule must name the amend/correct/move/delete cases"
        );
        assert!(
            p.contains("logs NEW consumption ONLY"),
            "prompt must state the insert-only invariant"
        );
        // The schema's own `no_loggable_content` description is updated too (it is inlined
        // into the prompt via DIET_EXTRACT_SCHEMA).
        assert!(
            DIET_EXTRACT_SCHEMA.contains("AMENDS/corrects/moves/deletes"),
            "schema no_loggable_content description must cover amendments"
        );
        assert!(
            p.contains(DIET_EXTRACT_SCHEMA),
            "the updated schema is inlined into the prompt"
        );
    }

    // ---- Mirror builder ----------------------------------------------------

    fn f(name: &str, meal: &str, time: &str, kcal: f64) -> FoodEntry {
        FoodEntry {
            name: name.into(),
            meal: meal.into(),
            time: Some(time.into()),
            amount: None,
            unit: None,
            kcal: Some(kcal),
            protein_g: Some(10.0),
            carbs_g: Some(20.0),
            fat_g: Some(5.0),
            fiber_g: Some(3.0),
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        }
    }

    #[test]
    fn mirror_groups_same_slot_time_rows_into_one_summed_meal() {
        // Two rows in the SAME (slot, time) group collapse to ONE mirror meal whose
        // macros are the trusted-Rust sum of the rows — and whose id is the
        // deterministic hosted-contract id with NO positional seq.
        let rows = vec![
            f("Banana", "Snack", "10:40", 105.0),
            f("Almonds", "Snack", "10:40", 116.0),
        ];
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00")
            .unwrap()
            .expect("two rows → a mirror");
        assert_eq!(
            ml.meals.len(),
            1,
            "same slot+time rows group into one mirror meal"
        );
        let m = &ml.meals[0];
        // Summed macros over the group (f() sets protein 10, carbs 20, fat 5, fiber 3).
        assert_eq!(m.kcal, Some(221.0), "105 + 116");
        assert_eq!(m.protein_g, Some(20.0));
        assert_eq!(m.carbs_g, Some(40.0));
        assert_eq!(m.fat_g, Some(10.0));
        assert_eq!(m.fiber_g, Some(6.0));
        // Deterministic hosted-contract id — no `-<seq>` suffix.
        assert_eq!(m.id, "2026-07-13-snack-1040", "id has no positional seq");
        assert_eq!(m.consumed_at, "2026-07-13T10:40:00+02:00");
        assert_eq!(m.name, "Snack: Banana, Almonds");
    }

    #[test]
    fn mirror_keeps_different_slots_or_times_as_separate_meals() {
        // Different slot, OR same slot at a different time, stay distinct mirror meals,
        // each with its own deterministic id.
        let rows = vec![
            f("Banana", "Snack", "10:40", 105.0),
            f("Rice", "Lunch", "12:30", 200.0),
            f("Apple", "Snack", "15:00", 95.0), // same slot as row 0, different time
        ];
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00")
            .unwrap()
            .expect("three distinct groups → a mirror");
        assert_eq!(ml.meals.len(), 3, "three distinct (slot,time) groups");
        let ids: Vec<&str> = ml.meals.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "2026-07-13-snack-1040",
                "2026-07-13-lunch-1230",
                "2026-07-13-snack-1500",
            ],
            "one deterministic id per group, first-appearance order preserved"
        );
    }

    #[test]
    fn mirror_id_matches_the_hosted_contract_format_exactly() {
        // The exact id string a grouped meal gets MUST equal the hosted format
        // `<date>-<slot lowercased>-<HHMM>` (the example the contract documents).
        let rows = vec![f("Sandwich", "Lunch", "12:30", 450.0)];
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-04", "+02:00")
            .unwrap()
            .unwrap();
        assert_eq!(ml.meals[0].id, "2026-07-04-lunch-1230");
    }

    #[test]
    fn mirror_sums_micros_over_known_rows_and_omits_all_none_group() {
        // Micro sum discipline: within a group, a known value plus an unknown yields the
        // known value alone (unknown contributes nothing); a group where NO row carries
        // the micro serializes no key at all — same shape for fiber and every micro.
        let with = |ca: Option<f64>, fib: Option<f64>, na: Option<f64>| FoodEntry {
            name: "x".into(),
            meal: "Lunch".into(),
            time: Some("12:30".into()),
            amount: None,
            unit: None,
            kcal: Some(100.0),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: fib,
            sodium_mg: na,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: ca,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        };
        // One row carries calcium 100 / fiber 4 / sodium 300, the other carries none.
        let rows = vec![
            with(Some(100.0), Some(4.0), Some(300.0)),
            with(None, None, None),
        ];
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00")
            .unwrap()
            .unwrap();
        assert_eq!(ml.meals.len(), 1, "same slot+time → one meal");
        let m = &ml.meals[0];
        assert_eq!(
            m.calcium_mg,
            Some(100.0),
            "known + unknown = the known value"
        );
        assert_eq!(m.fiber_g, Some(4.0), "same discipline for fiber");
        assert_eq!(m.sodium_mg, Some(300.0), "same discipline for sodium");
        // Micros no row carried are omitted entirely (never a summed Some(0)).
        assert!(m.satfat_g.is_none() && m.sugar_g.is_none() && m.potassium_mg.is_none());
        assert!(m.magnesium_mg.is_none(), "all-None magnesium omitted");
        // And on the wire the all-None micros produce NO key.
        let v = directives_to_value(&Some(Directives {
            needs_health: None,
            meal_log: Some(ml),
        }));
        let meal = &v["meal_log"]["meals"][0];
        assert_eq!(meal["calcium_mg"], 100.0);
        assert!(
            meal.get("magnesium_mg").is_none(),
            "an all-None micro serializes no key"
        );
    }

    #[test]
    fn mirror_omits_unknown_macros_never_null_pads() {
        let e = FoodEntry {
            name: "Toast".into(),
            meal: "Breakfast".into(),
            time: Some("08:00".into()),
            amount: None,
            unit: None,
            kcal: Some(180.0),
            protein_g: None,
            carbs_g: Some(32.0),
            fat_g: None,
            fiber_g: None,
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            notes: None,
        };
        let ml = build_meal_log_from_food_rows(&[e], "2026-07-13", "+02:00")
            .unwrap()
            .unwrap();
        let m = &ml.meals[0];
        assert_eq!(m.kcal, Some(180.0));
        assert_eq!(m.carbs_g, Some(32.0));
        assert!(m.protein_g.is_none() && m.fat_g.is_none() && m.fiber_g.is_none());
    }

    #[test]
    fn mirror_carries_known_micronutrients_and_serializes_under_wire_keys() {
        // A row with known sodium/sugar/calcium mirrors those onto the meal and
        // serializes them under the EXACT wire keys the app decodes (`sodium_mg`,
        // `sugar_g`, `calcium_mg`); the ones the row didn't carry (satfat, potassium,
        // magnesium) produce NO wire field — never a 0. Omega-3 is NOT a Meal field at
        // all (no HealthKit type), so it never reaches the wire even when the row has it.
        let e = FoodEntry {
            name: "Prosciutto".into(),
            meal: "Lunch".into(),
            time: Some("12:30".into()),
            amount: None,
            unit: None,
            kcal: Some(120.0),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sodium_mg: Some(900.0),
            satfat_g: None,
            sugar_g: Some(0.0),
            potassium_mg: None,
            calcium_mg: Some(11.0),
            omega3_mg: Some(50.0), // known on the row, but has no Meal field to carry it
            magnesium_mg: None,
            notes: None,
        };
        let ml = build_meal_log_from_food_rows(&[e], "2026-07-13", "+02:00")
            .unwrap()
            .unwrap();
        let m = &ml.meals[0];
        assert_eq!(m.sodium_mg, Some(900.0));
        assert_eq!(
            m.sugar_g,
            Some(0.0),
            "measured-zero sugar carried, not dropped"
        );
        assert_eq!(
            m.calcium_mg,
            Some(11.0),
            "known calcium mirrored onto the meal"
        );
        assert!(m.satfat_g.is_none() && m.potassium_mg.is_none() && m.magnesium_mg.is_none());
        // Serialize the whole directive and check the wire keys the app expects.
        let v = directives_to_value(&Some(Directives {
            needs_health: None,
            meal_log: Some(ml),
        }));
        let meal = &v["meal_log"]["meals"][0];
        assert_eq!(meal["sodium_mg"], 900.0, "known sodium under `sodium_mg`");
        assert_eq!(
            meal["sugar_g"], 0.0,
            "known measured-zero sugar under `sugar_g`"
        );
        assert_eq!(meal["calcium_mg"], 11.0, "known calcium under `calcium_mg`");
        assert!(
            meal.get("satfat_g").is_none(),
            "no known satfat → no `satfat_g` field (never 0)"
        );
        assert!(
            meal.get("potassium_mg").is_none(),
            "no known potassium → no `potassium_mg` field"
        );
        assert!(
            meal.get("magnesium_mg").is_none(),
            "no known magnesium → no `magnesium_mg` field"
        );
        assert!(
            meal.get("omega3_mg").is_none(),
            "omega-3 is never a meal wire field (no HealthKit type)"
        );
    }

    #[test]
    fn mirror_none_when_no_food_rows() {
        assert!(build_meal_log_from_food_rows(&[], "2026-07-13", "+02:00")
            .unwrap()
            .is_none());
    }

    #[test]
    fn mirror_errors_over_the_meal_cap_rung5() {
        // The cap is on the number of MEALS (groups), enforced AFTER grouping. Give each
        // row a distinct time so it forms its own group → MAX_MEALS + 1 groups → Err.
        let rows: Vec<FoodEntry> = (0..MAX_MEALS + 1)
            .map(|i| f(&format!("Item{i}"), "Snack", &format!("10:{i:02}"), 100.0))
            .collect();
        assert!(
            build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00").is_err(),
            "more groups than the cap → Err (rung 5)"
        );
        // At the cap exactly (MAX_MEALS distinct groups) it still builds.
        let ok: Vec<FoodEntry> = (0..MAX_MEALS)
            .map(|i| f(&format!("Item{i}"), "Snack", &format!("10:{i:02}"), 100.0))
            .collect();
        assert_eq!(
            build_meal_log_from_food_rows(&ok, "2026-07-13", "+02:00")
                .unwrap()
                .unwrap()
                .meals
                .len(),
            MAX_MEALS,
            "exactly at the cap builds all meals"
        );
    }

    #[test]
    fn mirror_many_rows_one_group_stays_one_meal_under_the_cap() {
        // The grouping is what keeps the block under the caps: many items in one
        // (slot, time) collapse to a single meal, so a busy meal never trips the
        // 10-meal cap by item count.
        let rows: Vec<FoodEntry> = (0..MAX_MEALS + 5)
            .map(|i| f(&format!("Item{i}"), "Dinner", "19:00", 50.0))
            .collect();
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00")
            .unwrap()
            .expect("one group → one meal, well under the cap");
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].id, "2026-07-13-dinner-1900");
    }

    // ---- Dashboard ---------------------------------------------------------

    const TARGETS_CSV: &str = "Date,Mode,Cal_Target,Carb_Target_g,Protein_Target_g,Fat_Target_g,Exercise_Cal,Notes,Fiber_Target_g\n2026-07-13,Normal,2100,210,190,65,0,notes,38\n";

    #[test]
    fn targets_are_read_by_name_for_the_date() {
        let t = targets_for_date(TARGETS_CSV, "2026-07-13");
        assert_eq!(t.cal, Some(2100.0));
        assert_eq!(t.protein, Some(190.0));
        assert_eq!(t.carbs, Some(210.0));
        assert_eq!(t.fat, Some(65.0));
        assert_eq!(t.fiber, Some(38.0));
        // A date with no row → all None.
        assert_eq!(
            targets_for_date(TARGETS_CSV, "2026-01-01"),
            DietTargets::default()
        );
    }

    #[test]
    fn sums_the_days_food_macros_from_csv_deriving_blank_calories() {
        // A day with an explicit-Calories row and a legacy per-100g row (blank
        // Calories → derived), plus a row for a DIFFERENT day that must be excluded.
        let csv = format!(
            "{FOOD_LOG_HEADER}\n\
             2026-07-13,Breakfast,Eggs,3,ea,,,210,18,15,1,,08:00,Breakfast,0\n\
             2026-07-13,Dinner,Rice,150,g,130,150,,3,0,28,,19:00,Dinner,\n\
             2026-07-12,Snack,Banana,1,ea,,,105,1,0,27,,10:00,Snack,3\n"
        );
        let t = sum_food_csv_for_date(&csv, "2026-07-13");
        assert_eq!(
            t.kcal,
            210.0 + 195.0,
            "explicit 210 + derived 130*150/100=195"
        );
        assert_eq!(t.protein_g, 21.0); // 18 + 3
        assert_eq!(t.carbs_g, 29.0); // 1 + 28
        assert_eq!(t.fiber_g, 0.0, "blank fiber counts as 0");
    }

    #[test]
    fn dashboard_renders_totals_and_bars_from_fixture_csv() {
        // Render straight from a food-log.csv fixture — the source of truth.
        let csv = format!(
            "{FOOD_LOG_HEADER}\n\
             2026-07-13,Breakfast,Eggs,3,ea,,,210,10,15,1,,08:00,Breakfast,0\n\
             2026-07-13,Snack,Banana,1,ea,,,105,10,0,27,,10:00,Snack,3\n"
        );
        let totals = sum_food_csv_for_date(&csv, "2026-07-13");
        assert_eq!(totals.kcal, 315.0);
        assert_eq!(totals.protein_g, 20.0); // 10 + 10
        let t = targets_for_date(TARGETS_CSV, "2026-07-13");
        let dash = render_diet_dashboard("2026-07-13", &totals, &t);
        assert!(dash.contains("2026-07-13"), "header carries the date");
        assert!(
            dash.contains("315") && dash.contains("2100"),
            "cal intake / target: {dash}"
        );
        assert!(dash.contains("190"), "protein target shown");
        // 315/2100 = 15% → calorie ceiling is comfortably green.
        assert!(dash.contains("🟩"), "a green bar should appear");
        // A floor metric well under 50% shows red.
        assert!(
            dash.contains("🟥"),
            "protein 20/190 (11%) is a red floor bar"
        );
    }

    // ---- Atomic append + rollback ------------------------------------------

    fn temp_logs() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-diet-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn append_writes_rows_preserving_single_trailing_newline() {
        let dir = temp_logs();
        std::fs::write(dir.join("food-log.csv"), format!("{FOOD_LOG_HEADER}\n")).unwrap();
        let snap = append_rows_atomic(&dir, &["row-a".into(), "row-b".into()], &[], &[]).unwrap();
        let content = std::fs::read_to_string(dir.join("food-log.csv")).unwrap();
        assert_eq!(content, format!("{FOOD_LOG_HEADER}\nrow-a\nrow-b\n"));
        // Rollback restores the pre-append content exactly.
        snap.rollback();
        assert_eq!(
            std::fs::read_to_string(dir.join("food-log.csv")).unwrap(),
            format!("{FOOD_LOG_HEADER}\n")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_rolls_back_when_a_later_file_is_unwritable() {
        // food-log writes fine; weight-log can't be created because its parent (a
        // FILE, not a dir) makes the write fail → the whole append rolls back, so the
        // successful food append is undone (no partial rows).
        let dir = temp_logs();
        std::fs::write(dir.join("food-log.csv"), "hdr\n").unwrap();
        // Make weight-log.csv path unwritable: create it as a directory.
        std::fs::create_dir(dir.join("weight-log.csv")).unwrap();
        let r = append_rows_atomic(&dir, &["frow".into()], &[], &["wrow".into()]);
        assert!(r.is_err(), "unwritable weight-log must fail the append");
        assert_eq!(
            std::fs::read_to_string(dir.join("food-log.csv")).unwrap(),
            "hdr\n",
            "food append rolled back — no partial rows"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- Provenance --------------------------------------------------------

    #[test]
    fn provenance_local_and_fallback_and_no_mirror() {
        assert_eq!(
            format_diet_provenance(true, None, "http://u", "m", "approved", 2, true, None),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=approved; rows=2 mirror=derived"
        );
        assert_eq!(
            format_diet_provenance(false, Some(3), "http://u", "m", "rejected", 1, false, None),
            "jesse-bridge: diet turn -> hosted-fallback rung=3 extract base_url=http://u model=m; verify verdict=rejected; rows=1 mirror=omitted"
        );
        // Rung 5: logged locally, mirror omitted.
        assert_eq!(
            format_diet_provenance(true, Some(5), "http://u", "m", "corrected", 11, false, None),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=corrected; rows=11 mirror=omitted"
        );
        // Never prints a token.
        let line = format_diet_provenance(true, None, "http://u", "m", "approved", 1, true, None);
        assert!(
            !line.contains("token"),
            "provenance must never carry a token"
        );
    }

    #[test]
    fn provenance_rung2_carries_a_machine_readable_reason() {
        // Every rung-2 emission must carry a machine-readable reason so the daily audit
        // can tell a FAILURE from a correct rejection. It rides after the rung, is
        // content-free, and never appears on a non-rung-2 line.
        let line = format_diet_provenance(
            false,
            Some(2),
            "http://u",
            "m",
            "n/a",
            0,
            false,
            Some("schema_fail:time"),
        );
        assert!(
            line.contains("reason=schema_fail:time"),
            "rung-2 provenance must carry the reason code: {line}"
        );
        assert!(!line.contains("token"), "still never carries a token");
        // A local success (no reason) is unchanged — no `reason=` fragment.
        let ok = format_diet_provenance(true, None, "http://u", "m", "approved", 1, true, None);
        assert!(
            !ok.contains("reason="),
            "a non-rung-2 line has no reason: {ok}"
        );
    }

    #[test]
    fn rung2_reason_codes_are_content_free_and_name_the_field() {
        assert_eq!(Rung2Reason::ChildError.code(), "child_error");
        assert_eq!(Rung2Reason::MalformedJson.code(), "malformed_json");
        assert_eq!(Rung2Reason::EmptyEntries.code(), "empty_entries");
        assert_eq!(Rung2Reason::NoLoggable.code(), "no_loggable");
        assert_eq!(
            Rung2Reason::SchemaFail(Some("time".into())).code(),
            "schema_fail:time"
        );
        assert_eq!(Rung2Reason::SchemaFail(None).code(), "schema_fail");
        // Classification from a parse-error string: serde failures are malformed_json;
        // a validator message names its back-ticked field; a quoted meal name never
        // leaks into the code (it is not back-ticked).
        assert_eq!(
            Rung2Reason::from_parse_error("invalid JSON: expected value at line 1 column 1"),
            Rung2Reason::MalformedJson
        );
        assert_eq!(
            Rung2Reason::from_parse_error("entry missing string `time`"),
            Rung2Reason::SchemaFail(Some("time".into()))
        );
        assert_eq!(
            Rung2Reason::from_parse_error("`kcal` is negative"),
            Rung2Reason::SchemaFail(Some("kcal".into()))
        );
        // A quoted (not back-ticked) name yields no field — no meal text in the code.
        assert_eq!(
            Rung2Reason::from_parse_error(
                "food entry name \"Eggs and toast\" spans multiple items"
            ),
            Rung2Reason::SchemaFail(None)
        );
    }

    // ---- Ladder rung mapping (pure decisions) ------------------------------

    #[test]
    fn rung2_extract_failures_map_to_child() {
        // Malformed JSON, no_loggable_content, and empty entries all mean "no local
        // log" → the orchestrator treats them as rung 2 (fall through). Proven at the
        // parse layer the orchestrator keys off.
        assert!(parse_diet_entries("garbage").is_err());
        let nologgable =
            parse_diet_entries(r#"{"no_loggable_content":true,"entries":[]}"#).unwrap();
        assert!(nologgable.no_loggable_content || nologgable.entries.is_empty());
    }

    #[test]
    fn rung3_a_single_reject_gates_the_whole_turn() {
        // Even one rejected entry means the turn falls through (rung 3): the pipeline
        // never partially logs. Proven via resolve_verdict returning None.
        let e = food(105.0);
        assert_eq!(resolve_verdict(&e, &verdict(Verdict::Reject, None)), None);
    }

    // ---- Split -------------------------------------------------------------

    // ---- Orchestrator (async glue) -----------------------------------------

    #[tokio::test]
    async fn pipeline_falls_through_at_rung2_when_extract_child_cannot_spawn() {
        // End-to-end through the async orchestrator without any network: point the
        // extract child at a non-existent binary so the spawn fails → the pipeline
        // degrades to a rung-2 fall-through (today's hosted path), never a partial log.
        let mut cfg = crate::testutil::test_config();
        cfg.claude_bin = "/no/such/diet-extract-binary".to_string();
        cfg.diet_backend = Some((
            "http://127.0.0.1:9100".into(),
            "dsv4-diet-dummy".into(),
            "local-diet".into(),
        ));
        match run_diet_pipeline(&cfg, "logged a banana").await {
            DietPipelineOutcome::FallThrough { rung, reason } => {
                assert_eq!(rung, DietRung::Child);
                assert_eq!(
                    reason,
                    Some(Rung2Reason::ChildError),
                    "a failed extract spawn is a child_error"
                );
            }
            _ => panic!("a failed extract spawn must fall through at rung 2"),
        }
    }

    #[test]
    fn split_entries_groups_by_kind() {
        let ex = parse_diet_entries(
            r#"{"entries":[
              {"kind":"food","name":"Banana","meal":"Snack","time":"10:00","kcal":105},
              {"kind":"weight","weight_lbs":198.0},
              {"kind":"exercise","activity":"Run","distance_km":5.0}
            ]}"#,
        )
        .unwrap();
        let (food, exercise, weight) = split_entries(&ex.entries);
        assert_eq!(food.len(), 1);
        assert_eq!(exercise.len(), 1);
        assert_eq!(weight.len(), 1);
    }
}
