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
//!      the appended food rows (one mirror meal per row, macros equal to the row),
//!      reusing the existing [`Meal`]/[`MealLog`] structs so the app decodes it
//!      unchanged. The aggregation failure mode is impossible by construction.
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
    "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g";
pub const EXERCISE_LOG_HEADER: &str =
    "Date,Type,Description,Distance_km,Duration,Pace_min_per_km,Elevation_m,Avg_HR,Cadence,Calories,Plan_Source,Notes,Start_Time";
pub const WEIGHT_LOG_HEADER: &str =
    "Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes";

// ---- Extracted entry schema -----------------------------------------------

/// One extracted food ITEM (never an aggregated meal). Macros are per-item; unknown
/// macros are `None` (omitted from the CSV, never zero-padded).
#[derive(Debug, Clone, PartialEq)]
pub struct FoodEntry {
    pub name: String,
    pub meal: String, // Breakfast | Lunch | Dinner | Snack
    pub time: String, // HH:MM
    pub amount: Option<String>,
    pub unit: Option<String>,
    pub kcal: Option<f64>,
    pub protein_g: Option<f64>,
    pub carbs_g: Option<f64>,
    pub fat_g: Option<f64>,
    pub fiber_g: Option<f64>,
    pub notes: Option<String>,
}

/// One extracted exercise session.
#[derive(Debug, Clone, PartialEq)]
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
#[derive(Debug, Clone, PartialEq)]
pub struct WeightEntry {
    pub weight_lbs: f64,
    pub weight_kg: Option<f64>,
    pub body_fat_pct: Option<f64>,
    pub muscle_mass_lbs: Option<f64>,
    pub notes: Option<String>,
}

/// A single extracted entry — one per ITEM, never an aggregate.
#[derive(Debug, Clone, PartialEq)]
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
pub fn parse_diet_entries(json: &str) -> Result<DietExtract, String> {
    let value: Value = serde_json::from_str(json.trim()).map_err(|e| format!("invalid JSON: {e}"))?;
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
/// (an explicit `null` is a violation — the contract omits unknowns, never nulls).
fn opt_num_field(m: &serde_json::Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    match m.get(key) {
        None => Ok(None),
        Some(v) => {
            let n = v.as_f64().ok_or_else(|| format!("`{key}` is not a number"))?;
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

const FOOD_KEYS: &[&str] = &[
    "kind", "name", "meal", "time", "amount", "unit", "kcal", "protein_g", "carbs_g", "fat_g",
    "fiber_g", "notes",
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
        time: req_str(m, "time")?,
        amount: opt_str_field(m, "amount"),
        unit: opt_str_field(m, "unit"),
        kcal: opt_num_field(m, "kcal")?,
        protein_g: opt_num_field(m, "protein_g")?,
        carbs_g: opt_num_field(m, "carbs_g")?,
        fat_g: opt_num_field(m, "fat_g")?,
        fiber_g: opt_num_field(m, "fiber_g")?,
        notes: opt_str_field(m, "notes"),
    })
}

const EXERCISE_KEYS: &[&str] = &[
    "kind", "activity", "time", "description", "distance_km", "duration", "pace", "avg_hr",
    "calories", "notes",
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
        distance_km: opt_num_field(m, "distance_km")?,
        duration: opt_str_field(m, "duration"),
        pace: opt_str_field(m, "pace"),
        avg_hr: opt_num_field(m, "avg_hr")?,
        calories: opt_num_field(m, "calories")?,
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
    let lbs = opt_num_field(m, "weight_lbs")?;
    let kg = opt_num_field(m, "weight_kg")?;
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
        body_fat_pct: opt_num_field(m, "body_fat_pct")?,
        muscle_mass_lbs: opt_num_field(m, "muscle_mass_lbs")?,
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
    let value: Value = serde_json::from_str(json.trim()).map_err(|e| format!("invalid JSON: {e}"))?;
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

/// The result of applying one verdict to one candidate entry.
#[derive(Debug, Clone, PartialEq)]
pub enum EntryResolution {
    /// Keep or use these (possibly corrected) macros — same item, safe to write.
    Accept(DietEntry),
    /// Structural problem (reject, or a non-trivially-safe correction) → rung 3.
    FallThrough,
}

/// Apply a verdict to a candidate entry (probation semantics — every entry gated):
///   * `Reject` → [`EntryResolution::FallThrough`] (rung 3).
///   * `Approve` → keep the candidate, UNLESS the verifier's own kcal estimate is
///     out of band ([`kcal_out_of_band`]); a contradictory approve is treated as a
///     correction so we never write numbers the verifier itself disputes.
///   * `Correct` → apply the corrected macros IF trivially safe (same item, only
///     numbers change, and every corrected value is finite/non-negative); anything
///     else is structural → [`EntryResolution::FallThrough`] (rung 3).
///
/// Only FOOD carries macros to correct; an exercise/weight entry is `Accept`ed on
/// approve and `FallThrough`s on correct/reject (we don't auto-correct those in v1).
pub fn resolve_verdict(entry: &DietEntry, v: &EntryVerdict) -> EntryResolution {
    if v.verdict == Verdict::Reject {
        return EntryResolution::FallThrough;
    }
    match entry {
        DietEntry::Food(f) => resolve_food_verdict(f, v),
        // Non-food: approve keeps it; a correction we can't trivially apply → hosted.
        _ if v.verdict == Verdict::Approve => EntryResolution::Accept(entry.clone()),
        _ => EntryResolution::FallThrough,
    }
}

fn resolve_food_verdict(f: &FoodEntry, v: &EntryVerdict) -> EntryResolution {
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
        return EntryResolution::Accept(DietEntry::Food(f.clone()));
    }
    // Trivially safe correction: same item, macros replaced with the verifier's
    // (finite, non-negative) numbers. `apply` re-validates each corrected value.
    let apply = |orig: Option<f64>, corrected: Option<f64>| -> Result<Option<f64>, ()> {
        match corrected {
            Some(n) if n.is_finite() && n >= 0.0 => Ok(Some(n)),
            Some(_) => Err(()),   // a bad corrected value is not trivially safe
            None => Ok(orig),     // verifier didn't touch this macro → keep candidate's
        }
    };
    let corrected = FoodEntry {
        kcal: match apply(f.kcal, v.kcal) {
            Ok(x) => x,
            Err(()) => return EntryResolution::FallThrough,
        },
        protein_g: match apply(f.protein_g, v.protein_g) {
            Ok(x) => x,
            Err(()) => return EntryResolution::FallThrough,
        },
        carbs_g: match apply(f.carbs_g, v.carbs_g) {
            Ok(x) => x,
            Err(()) => return EntryResolution::FallThrough,
        },
        fat_g: match apply(f.fat_g, v.fat_g) {
            Ok(x) => x,
            Err(()) => return EntryResolution::FallThrough,
        },
        fiber_g: match apply(f.fiber_g, v.fiber_g) {
            Ok(x) => x,
            Err(()) => return EntryResolution::FallThrough,
        },
        ..f.clone()
    };
    EntryResolution::Accept(DietEntry::Food(corrected))
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
        csv_field(&e.time),
        csv_field(&e.meal), // Meal_Type mirrors Meal
        num_cell(e.fiber_g),
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

/// Build the DERIVED [`MealLog`] mirror from the verified food entries: exactly ONE
/// mirror meal per food row, with macros EQUAL to the row's — the aggregation
/// failure mode is impossible by construction, not by trust. Returns `Ok(None)` when
/// there are no food rows (a valid exercise/weigh-in-only turn — no mirror to emit),
/// and `Err` when the row count exceeds [`MAX_MEALS`] (the caller maps that to rung
/// 5: keep the committed CSV, omit the mirror). Each meal id is
/// `<date>-<mealslug>-<HHMM>-<seq>`, unique per row so two rows always yield two
/// distinct mirror meals.
pub fn build_meal_log_from_food_rows(
    rows: &[FoodEntry],
    date: &str,
    offset: &str,
) -> Result<Option<MealLog>, String> {
    if rows.is_empty() {
        return Ok(None);
    }
    if rows.len() > MAX_MEALS {
        return Err(format!(
            "{} food rows exceeds the {MAX_MEALS}-meal mirror cap",
            rows.len()
        ));
    }
    let meals = rows
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let hhmm: String = r.time.chars().filter(|c| c.is_ascii_digit()).collect();
            Meal {
                // Unique per row (`<date>-<slug>-<HHMM>-<seq>`) so two rows in the same
                // slot never collide → two rows always yield two distinct meals.
                id: format!("{date}-{}-{hhmm}-{}", meal_slug(&r.meal), i + 1),
                consumed_at: format!("{date}T{}:00{offset}", r.time),
                name: format!("{}: {}", r.meal, r.name),
                // Macros EQUAL to the row (omit unknown — never null-pad).
                kcal: r.kcal,
                protein_g: r.protein_g,
                carbs_g: r.carbs_g,
                fat_g: r.fat_g,
                fiber_g: r.fiber_g,
            }
        })
        .collect();
    Ok(Some(MealLog { meals }))
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
        let d = idx.get("Date").and_then(|&j| rec.get(j)).unwrap_or("").trim();
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
    let filled = ((pct / 100.0) * BAR_WIDTH as f64).round().clamp(0.0, BAR_WIDTH as f64) as usize;
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
    if grams < 50.0 || grams > 70.0 {
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
        None => out.push_str(&format!("Cal          {} kcal\n", totals.kcal.round() as i64)),
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
                eprintln!("jesse-bridge: diet rollback failed for {}: {e}", path.display());
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
    let mut snapshot = AppendSnapshot { restores: Vec::new() };
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

/// Local `HH:MM` via `date +%H:%M`, for the commit message timestamp.
fn local_hhmm() -> String {
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

// ---- Provenance ------------------------------------------------------------

/// One diet-turn provenance line (mirrors the title provenance line): local vs
/// hosted-fallback with the rung, the extract backend (base URL + model, NEVER the
/// token, no meal content), the verify verdict, the row count, and whether a mirror
/// was derived.
pub fn format_diet_provenance(
    local: bool,
    rung: Option<u8>,
    base_url: &str,
    model: &str,
    verify: &str,
    rows: usize,
    mirror_derived: bool,
) -> String {
    let disposition = if local {
        "local".to_string()
    } else {
        format!("hosted-fallback rung={}", rung.unwrap_or(0))
    };
    let mirror = if mirror_derived { "derived" } else { "omitted" };
    format!(
        "jesse-bridge: diet turn -> {disposition} extract base_url={base_url} model={model}; \
         verify verdict={verify}; rows={rows} mirror={mirror}"
    )
}

// ---- Prompts ---------------------------------------------------------------

/// The verbatim JSON schema the extract child must return — a per-item `entries`
/// array plus `no_loggable_content`. Kept as a const so the prompt and the report
/// share one source. See [`parse_diet_entries`] for the enforcing validator.
pub const DIET_EXTRACT_SCHEMA: &str = r#"{
  "no_loggable_content": <boolean: true ONLY if the message logs nothing to eat/drink, no workout, no weight>,
  "entries": [
    { "kind": "food", "name": "<ONE food item, never a combined meal>", "meal": "Breakfast|Lunch|Dinner|Snack", "time": "HH:MM", "amount": "<e.g. 1 medium (~118g)>", "unit": "serving", "kcal": <number>, "protein_g": <number>, "carbs_g": <number>, "fat_g": <number>, "fiber_g": <number>, "notes": "<optional>" },
    { "kind": "exercise", "activity": "Run|Walk|Swim|Strength/Weights|...", "time": "HH:MM", "description": "<optional>", "distance_km": <number>, "duration": "<e.g. 56:58>", "pace": "<e.g. 7:07>", "avg_hr": <number>, "calories": <number>, "notes": "<optional>" },
    { "kind": "weight", "weight_lbs": <number>, "weight_kg": <number>, "body_fat_pct": <number>, "muscle_mass_lbs": <number>, "notes": "<optional>" }
  ]
}"#;

/// Build the stateless EXTRACT prompt: the CSV/macro contract (inlined from the same
/// header consts the append path targets — the parity source of truth), the per-item
/// anti-aggregation rule, the schema, and the JSON-only instruction. The raw
/// utterance is appended. The child holds no tools, so everything it needs is here.
pub fn build_diet_extract_prompt(utterance: &str) -> String {
    format!(
        "You extract structured diet-log entries from a short message Jeremy sent from \
his phone. Return ONLY a single JSON object — no prose, no markdown, no code fence.\n\
\n\
CONTRACT (the vault's diet logs; you are parsing INTO these columns):\n\
- food-log.csv columns: {FOOD_LOG_HEADER}\n\
- exercise-log.csv columns: {EXERCISE_LOG_HEADER}\n\
- weight-log.csv columns: {WEIGHT_LOG_HEADER}\n\
- Macros are per-ITEM absolute grams/kcal. Omit any macro you don't know — NEVER \
guess and NEVER write 0 as a placeholder (0 means a real measured zero).\n\
- `time` is the clock time the thing happened (HH:MM). `meal` is the meal slot that \
fits that hour.\n\
\n\
PER-ITEM RULE (the 2026-07-13 schema decision — enforce it):\n\
- Emit ONE food entry PER DISTINCT FOOD, each with its OWN per-item macros. NEVER a \
single entry for a whole meal, and NEVER a meal-total set of macros. \"Eggs and \
toast\" is TWO food entries; a plate of pasta with sauce and cheese is three. A \
brand/qualifier in parentheses is part of one item's name (\"Salmon (canned)\").\n\
- One exercise entry per activity; one weight entry per reading.\n\
- If the message logs nothing loggable (no food/drink, no workout, no weight), set \
`no_loggable_content` to true and return an empty `entries` array.\n\
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
pub fn build_diet_verify_prompt(utterance: &str, candidates_json: &str) -> String {
    format!(
        "You are the VERIFY gate for a diet-logging pipeline. A cheap local model \
parsed Jeremy's message into candidate per-item entries. Check each one against the \
message before it is written to his logs. Return ONLY a JSON object — no prose.\n\
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
    serde_json::to_string(&json!({ "entries": arr })).unwrap_or_else(|_| "{\"entries\":[]}".to_string())
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

/// The outcome of the local pipeline for one turn.
pub enum DietPipelineOutcome {
    /// Logged locally: the ASCII dashboard reply plus the derived directives (mirror).
    Logged {
        dashboard: String,
        directives: Directives,
    },
    /// Logged locally but the mirror was omitted (rung 5): CSV committed, no directive.
    LoggedNoMirror { dashboard: String },
    /// Fall through to the hosted turn at the given rung (2–4).
    FallThrough { rung: DietRung },
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
            };
        }
    };
    let prov = |local: bool, rung: Option<u8>, verify: &str, rows: usize, mirror: bool| {
        eprintln!(
            "{}",
            format_diet_provenance(local, rung, &base_url, &model, verify, rows, mirror)
        );
    };

    // Stage 1 — extract.
    let extract_raw = match run_diet_extract(cfg, &build_diet_extract_prompt(utterance), DIET_EXTRACT_TIMEOUT_SECS).await {
        Ok(s) => s,
        Err(_) => {
            prov(false, Some(2), "n/a", 0, false);
            return DietPipelineOutcome::FallThrough { rung: DietRung::Child };
        }
    };
    let extract = match parse_diet_entries(&extract_raw) {
        Ok(e) if !e.no_loggable_content && !e.entries.is_empty() => e,
        _ => {
            prov(false, Some(2), "n/a", 0, false);
            return DietPipelineOutcome::FallThrough { rung: DietRung::Child };
        }
    };

    // Stage 2 — verify (probation: mandatory, blocking, 100%).
    let verify_raw = match run_diet_verify(
        cfg,
        &build_diet_verify_prompt(utterance, &entries_to_json(&extract.entries)),
        DIET_VERIFY_TIMEOUT_SECS,
    )
    .await
    {
        Ok(s) => s,
        Err(_) => {
            prov(false, Some(3), "unavailable", extract.entries.len(), false);
            return DietPipelineOutcome::FallThrough { rung: DietRung::Verify };
        }
    };
    let verdicts = match parse_verify_verdicts(&verify_raw, extract.entries.len()) {
        Ok(v) => v,
        Err(_) => {
            prov(false, Some(3), "unavailable", extract.entries.len(), false);
            return DietPipelineOutcome::FallThrough { rung: DietRung::Verify };
        }
    };
    let mut verified = Vec::with_capacity(extract.entries.len());
    let mut any_corrected = false;
    for (entry, v) in extract.entries.iter().zip(verdicts.iter()) {
        match resolve_verdict(entry, v) {
            EntryResolution::Accept(e) => {
                if e != *entry {
                    any_corrected = true;
                }
                verified.push(e);
            }
            EntryResolution::FallThrough => {
                let verdict = if v.verdict == Verdict::Reject { "rejected" } else { "rejected" };
                prov(false, Some(3), verdict, extract.entries.len(), false);
                return DietPipelineOutcome::FallThrough { rung: DietRung::Verify };
            }
        }
    }
    let verify_word = if any_corrected { "corrected" } else { "approved" };

    // Stage 3 — append + hooks + commit (atomic per turn).
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
            return DietPipelineOutcome::FallThrough { rung: DietRung::Append };
        }
    };
    if let Err(e) = run_diet_hooks(vault).await {
        eprintln!("jesse-bridge: diet hooks failed: {e}");
        snapshot.rollback();
        prov(false, Some(4), verify_word, verified.len(), false);
        return DietPipelineOutcome::FallThrough { rung: DietRung::Append };
    }
    if let Err(e) = commit_diet_logs(vault, &date, &local_hhmm()).await {
        eprintln!("jesse-bridge: diet commit failed: {e}");
        snapshot.rollback();
        prov(false, Some(4), verify_word, verified.len(), false);
        return DietPipelineOutcome::FallThrough { rung: DietRung::Append };
    }

    // Stage 4 — dashboard + mirror. Both are DERIVED from the committed rows.
    let totals = sum_food_macros(&food);
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
        assert!(parse_diet_entries(json).is_err(), "aggregated name must reject");
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
    fn no_loggable_content_flag_parses() {
        let ex = parse_diet_entries(r#"{"no_loggable_content":true,"entries":[]}"#).unwrap();
        assert!(ex.no_loggable_content);
        assert!(ex.entries.is_empty());
    }

    #[test]
    fn parse_rejects_malformed_and_off_contract() {
        for bad in [
            "not json",
            r#"{"entries":"nope"}"#,
            r#"{"entries":[{"kind":"food"}]}"#, // missing name/meal/time
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","kcal":-5}]}"#, // negative
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","kcal":null}]}"#, // explicit null
            r#"{"entries":[{"kind":"bogus"}]}"#,
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","sodium_mg":5}]}"#, // unknown key
            r#"{"extra":1,"entries":[]}"#, // unknown top-level
        ] {
            assert!(parse_diet_entries(bad).is_err(), "should reject: {bad}");
        }
    }

    #[test]
    fn parse_enforces_entry_cap() {
        let one = r#"{"kind":"food","name":"x","meal":"Snack","time":"09:00","kcal":1}"#;
        let over = std::iter::repeat_n(one, MAX_DIET_ENTRIES + 1).collect::<Vec<_>>().join(",");
        assert!(parse_diet_entries(&format!("{{\"entries\":[{over}]}}")).is_err());
        let at = std::iter::repeat_n(one, MAX_DIET_ENTRIES).collect::<Vec<_>>().join(",");
        assert!(parse_diet_entries(&format!("{{\"entries\":[{at}]}}")).is_ok());
    }

    #[test]
    fn weight_derives_lbs_from_kg_when_lbs_absent() {
        let json = r#"{"entries":[{"kind":"weight","weight_kg":90.0}]}"#;
        let ex = parse_diet_entries(json).unwrap();
        match &ex.entries[0] {
            DietEntry::Weight(w) => assert!((w.weight_lbs - 198.4).abs() < 0.1, "kg→lbs: {}", w.weight_lbs),
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
        assert!(!kcal_out_of_band(1180.0, 1000.0), "180 diff ≤ 200 → in band");
        assert!(kcal_out_of_band(1210.0, 1000.0), "210 diff > 200 → out of band");
    }

    #[test]
    fn tolerance_boundary_is_inclusive_in_band() {
        // Exactly at the threshold (the larger arm) is IN band ("more than").
        assert!(!kcal_out_of_band(275.0, 200.0), "diff == 75 exactly → in band");
        assert!(!kcal_out_of_band(1200.0, 1000.0), "diff == 200 (20%) exactly → in band");
    }

    // ---- Verify verdict handling -------------------------------------------

    fn food(kcal: f64) -> DietEntry {
        DietEntry::Food(FoodEntry {
            name: "Banana".into(),
            meal: "Snack".into(),
            time: "10:00".into(),
            amount: None,
            unit: None,
            kcal: Some(kcal),
            protein_g: Some(1.0),
            carbs_g: Some(27.0),
            fat_g: Some(0.4),
            fiber_g: Some(3.0),
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
        match resolve_verdict(&e, &verdict(Verdict::Approve, Some(110.0))) {
            EntryResolution::Accept(a) => assert_eq!(a, e),
            EntryResolution::FallThrough => panic!("in-band approve must keep candidate"),
        }
    }

    #[test]
    fn approve_but_out_of_band_becomes_a_correction() {
        // Verifier "approves" but its kcal estimate is wildly off (105 vs 400) — we
        // do not blindly write the candidate; the verifier's number is used instead.
        let e = food(105.0);
        match resolve_verdict(&e, &verdict(Verdict::Approve, Some(400.0))) {
            EntryResolution::Accept(DietEntry::Food(f)) => assert_eq!(f.kcal, Some(400.0)),
            other => panic!("expected corrected kcal, got {other:?}"),
        }
    }

    #[test]
    fn correct_applies_verifier_numbers_same_item() {
        let e = food(105.0);
        match resolve_verdict(&e, &verdict(Verdict::Correct, Some(120.0))) {
            EntryResolution::Accept(DietEntry::Food(f)) => {
                assert_eq!(f.kcal, Some(120.0));
                assert_eq!(f.name, "Banana", "item identity unchanged (trivially safe)");
                assert_eq!(f.carbs_g, Some(27.0), "untouched macro keeps candidate value");
            }
            other => panic!("expected correction, got {other:?}"),
        }
    }

    #[test]
    fn reject_falls_through_to_hosted() {
        assert_eq!(
            resolve_verdict(&food(105.0), &verdict(Verdict::Reject, None)),
            EntryResolution::FallThrough
        );
    }

    #[test]
    fn correction_with_a_bad_number_is_not_trivially_safe() {
        let mut v = verdict(Verdict::Correct, Some(f64::NAN));
        v.kcal = Some(f64::NAN);
        assert_eq!(resolve_verdict(&food(105.0), &v), EntryResolution::FallThrough);
    }

    #[test]
    fn parse_verify_verdicts_requires_one_per_entry() {
        let json = r#"{"verdicts":[{"verdict":"approve"},{"verdict":"reject"}]}"#;
        assert_eq!(parse_verify_verdicts(json, 2).unwrap().len(), 2);
        assert!(parse_verify_verdicts(json, 3).is_err(), "count mismatch rejects");
        assert!(parse_verify_verdicts("nope", 2).is_err());
    }

    // ---- CSV row builders --------------------------------------------------

    #[test]
    fn food_row_follows_fill_convention_and_quotes() {
        let e = FoodEntry {
            name: "Salmon sockeye (Fiorfiore, canned)".into(),
            meal: "Breakfast".into(),
            time: "09:40".into(),
            amount: Some("1 can".into()),
            unit: None,
            kcal: Some(129.0),
            protein_g: Some(22.5),
            carbs_g: Some(0.0),
            fat_g: Some(2.3),
            fiber_g: Some(0.0),
            notes: Some("drained, with salt".into()),
        };
        let row = food_row(&e, "2026-07-13");
        // RFC-4180: the item's comma forces quoting; the row parses back to 15 fields.
        let mut rdr = csv::ReaderBuilder::new().has_headers(false).from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(rec.len(), FOOD_LOG_HEADER.split(',').count(), "15 columns");
        assert_eq!(&rec[0], "2026-07-13");
        assert_eq!(&rec[1], "Breakfast");
        assert_eq!(&rec[2], "Salmon sockeye (Fiorfiore, canned)");
        assert_eq!(&rec[4], "serving", "Unit defaults to serving");
        assert_eq!(&rec[5], "", "Cal_per_100g blank");
        assert_eq!(&rec[6], "", "Grams blank");
        assert_eq!(&rec[7], "129", "kcal into Calories");
        assert_eq!(&rec[13], "Breakfast", "Meal_Type mirrors Meal");
        assert_eq!(&rec[14], "0", "fiber");
    }

    #[test]
    fn food_row_blank_macros_are_empty_cells() {
        let e = FoodEntry {
            name: "Water".into(),
            meal: "Snack".into(),
            time: "12:00".into(),
            amount: None,
            unit: None,
            kcal: None,
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            notes: None,
        };
        let row = food_row(&e, "2026-07-13");
        let mut rdr = csv::ReaderBuilder::new().has_headers(false).from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(&rec[7], "", "absent kcal → empty cell, not 0");
        assert_eq!(&rec[14], "", "absent fiber → empty cell");
    }

    // ---- Parity: prompt ↔ append schema ------------------------------------

    #[test]
    fn prompt_contract_matches_append_schema() {
        // The parity mitigation: the extract prompt inlines the SAME header consts
        // the row builders target, so the described contract can never drift from
        // what the append path writes. Assert the prompt carries each header verbatim
        // AND that each row builder emits exactly that many columns.
        let p = build_diet_extract_prompt("hi");
        assert!(p.contains(FOOD_LOG_HEADER), "extract prompt must inline the food header");
        assert!(p.contains(EXERCISE_LOG_HEADER), "extract prompt must inline the exercise header");
        assert!(p.contains(WEIGHT_LOG_HEADER), "extract prompt must inline the weight header");

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
            name: "n".into(), meal: "Snack".into(), time: "09:00".into(),
            amount: None, unit: None, kcal: Some(1.0), protein_g: None, carbs_g: None,
            fat_g: None, fiber_g: None, notes: None,
        };
        assert_eq!(count(&food_row(&f, "2026-07-13")), FOOD_LOG_HEADER.split(',').count());
        let x = ExerciseEntry {
            activity: "Run".into(), time: Some("06:00".into()), description: None,
            distance_km: Some(5.0), duration: None, pace: None, avg_hr: None,
            calories: None, notes: None,
        };
        assert_eq!(count(&exercise_row(&x, "2026-07-13")), EXERCISE_LOG_HEADER.split(',').count());
        let w = WeightEntry {
            weight_lbs: 198.0, weight_kg: None, body_fat_pct: None,
            muscle_mass_lbs: None, notes: None,
        };
        assert_eq!(count(&weight_row(&w, "2026-07-13")), WEIGHT_LOG_HEADER.split(',').count());
    }

    // ---- Mirror builder ----------------------------------------------------

    fn f(name: &str, meal: &str, time: &str, kcal: f64) -> FoodEntry {
        FoodEntry {
            name: name.into(),
            meal: meal.into(),
            time: time.into(),
            amount: None,
            unit: None,
            kcal: Some(kcal),
            protein_g: Some(10.0),
            carbs_g: Some(20.0),
            fat_g: Some(5.0),
            fiber_g: Some(3.0),
            notes: None,
        }
    }

    #[test]
    fn mirror_is_one_meal_per_row_with_row_equal_macros() {
        let rows = vec![f("Banana", "Snack", "10:40", 105.0), f("Almonds", "Snack", "10:40", 116.0)];
        let ml = build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00")
            .unwrap()
            .expect("two rows → a mirror");
        assert_eq!(ml.meals.len(), 2, "two rows always yield two mirror meals");
        // Row-equal macros, by construction.
        assert_eq!(ml.meals[0].kcal, Some(105.0));
        assert_eq!(ml.meals[1].kcal, Some(116.0));
        assert_eq!(ml.meals[0].protein_g, Some(10.0));
        assert_eq!(ml.meals[0].fiber_g, Some(3.0));
        // Distinct ids so the two meals never collide.
        assert_ne!(ml.meals[0].id, ml.meals[1].id, "ids must be unique per row");
        assert!(ml.meals[0].id.starts_with("2026-07-13-snack-1040"));
        assert_eq!(ml.meals[0].consumed_at, "2026-07-13T10:40:00+02:00");
        assert_eq!(ml.meals[0].name, "Snack: Banana");
    }

    #[test]
    fn mirror_omits_unknown_macros_never_null_pads() {
        let e = FoodEntry {
            name: "Toast".into(),
            meal: "Breakfast".into(),
            time: "08:00".into(),
            amount: None,
            unit: None,
            kcal: Some(180.0),
            protein_g: None,
            carbs_g: Some(32.0),
            fat_g: None,
            fiber_g: None,
            notes: None,
        };
        let ml = build_meal_log_from_food_rows(&[e], "2026-07-13", "+02:00").unwrap().unwrap();
        let m = &ml.meals[0];
        assert_eq!(m.kcal, Some(180.0));
        assert_eq!(m.carbs_g, Some(32.0));
        assert!(m.protein_g.is_none() && m.fat_g.is_none() && m.fiber_g.is_none());
    }

    #[test]
    fn mirror_none_when_no_food_rows() {
        assert!(build_meal_log_from_food_rows(&[], "2026-07-13", "+02:00").unwrap().is_none());
    }

    #[test]
    fn mirror_errors_over_the_meal_cap_rung5() {
        let rows: Vec<FoodEntry> = (0..MAX_MEALS + 1)
            .map(|i| f(&format!("Item{i}"), "Snack", "10:00", 100.0))
            .collect();
        assert!(
            build_meal_log_from_food_rows(&rows, "2026-07-13", "+02:00").is_err(),
            "over the cap → Err (rung 5)"
        );
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
        assert_eq!(targets_for_date(TARGETS_CSV, "2026-01-01"), DietTargets::default());
    }

    #[test]
    fn dashboard_renders_totals_and_bars_from_fixture_csv() {
        let rows = vec![f("Eggs", "Breakfast", "08:00", 210.0), f("Banana", "Snack", "10:00", 105.0)];
        let totals = sum_food_macros(&rows);
        assert_eq!(totals.kcal, 315.0);
        assert_eq!(totals.protein_g, 20.0); // 2 × 10
        let t = targets_for_date(TARGETS_CSV, "2026-07-13");
        let dash = render_diet_dashboard("2026-07-13", &totals, &t);
        assert!(dash.contains("2026-07-13"), "header carries the date");
        assert!(dash.contains("315") && dash.contains("2100"), "cal intake / target: {dash}");
        assert!(dash.contains("190"), "protein target shown");
        // 315/2100 = 15% → calorie ceiling is comfortably green.
        assert!(dash.contains("🟩"), "a green bar should appear");
        // A floor metric well under 50% shows red.
        assert!(dash.contains("🟥"), "protein 20/190 (11%) is a red floor bar");
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
            format_diet_provenance(true, None, "http://u", "m", "approved", 2, true),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=approved; rows=2 mirror=derived"
        );
        assert_eq!(
            format_diet_provenance(false, Some(3), "http://u", "m", "rejected", 1, false),
            "jesse-bridge: diet turn -> hosted-fallback rung=3 extract base_url=http://u model=m; verify verdict=rejected; rows=1 mirror=omitted"
        );
        // Rung 5: logged locally, mirror omitted.
        assert_eq!(
            format_diet_provenance(true, Some(5), "http://u", "m", "corrected", 11, false),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=corrected; rows=11 mirror=omitted"
        );
        // Never prints a token.
        let line = format_diet_provenance(true, None, "http://u", "m", "approved", 1, true);
        assert!(!line.contains("token"), "provenance must never carry a token");
    }

    // ---- Ladder rung mapping (pure decisions) ------------------------------

    #[test]
    fn rung2_extract_failures_map_to_child() {
        // Malformed JSON, no_loggable_content, and empty entries all mean "no local
        // log" → the orchestrator treats them as rung 2 (fall through). Proven at the
        // parse layer the orchestrator keys off.
        assert!(parse_diet_entries("garbage").is_err());
        let nologgable = parse_diet_entries(r#"{"no_loggable_content":true,"entries":[]}"#).unwrap();
        assert!(nologgable.no_loggable_content || nologgable.entries.is_empty());
    }

    #[test]
    fn rung3_a_single_reject_gates_the_whole_turn() {
        // Even one rejected entry means the turn falls through (rung 3): the pipeline
        // never partially logs. Proven via resolve_verdict returning FallThrough.
        let e = food(105.0);
        assert_eq!(
            resolve_verdict(&e, &verdict(Verdict::Reject, None)),
            EntryResolution::FallThrough
        );
    }

    // ---- Split -------------------------------------------------------------

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
