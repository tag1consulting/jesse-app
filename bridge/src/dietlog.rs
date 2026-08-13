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
use std::sync::LazyLock;

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

// ---- The nutrient column table (ONE definition of every nutrient column) ----
//
// Every nutrient column past the core macros is described here EXACTLY ONCE: its
// `food-log.csv` column name, its extract-schema JSON key, its meal-wire key (or
// none), its unit, its app-snapshot key, and its FILL CLASS. Everything downstream
// is DERIVED from this table — the CSV header ([`food_log_header`]), the keys the
// extract schema accepts ([`parse_food`], [`diet_extract_schema`]), the nutrient
// section of the extract prompt ([`build_diet_extract_prompt`]), the nutrient cells
// of the appended row ([`food_row`]), the nutrient fields of the derived Apple
// Health mirror ([`build_meal_log_from_food_rows`]), and the per-day nutrient
// aggregates the app snapshot reads ([`diet::nutrient_cols`]).
//
// Adding a nutrient is therefore ONE table row, not eight edits in eight places —
// and `synthetic_nutrient_flows_through_header_schema_and_prompt` proves nothing
// downstream is hardcoded past this table.

/// How a nutrient column is expected to be FILLED — the distinction the completion
/// path and the extract prompt both key on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FillClass {
    /// Expected on every row whose food is knowable: a label prints it, or standard
    /// food-composition values for a label-less whole food supply it. A blank cell
    /// here is INCOMPLETE data (what the Phase-4 completeness figure counts), not a
    /// meaningful "this food has none".
    ExpectedWhenKnowable,
    /// Present only in marine foods (and small amounts in eggs/dairy). A blank cell
    /// is the NORMAL, correct state for everything else, so it is never counted as
    /// incomplete and never filled by hosted completion.
    MarineOnly,
    /// A RISK nutrient almost no label prints (trans fat outside the US, added sugar,
    /// purines, mercury): fillable only from a label that happens to state it or from a
    /// confident class-based estimate, so a blank cell is a normal outcome rather than
    /// incomplete data. Never counted by the completeness figure and never filled by
    /// hosted completion — the per-nutrient guidance on the table row is what teaches
    /// the extract child when a REAL 0 is the answer (mercury in non-seafood, added
    /// sugar in whole fruit) and when to omit.
    EstimatedRisk,
}

/// One nutrient column, described once. `getter`/`setter` are the field accessors on
/// [`FoodEntry`] and `wire_setter` the one on [`Meal`], so a table row owns its own
/// plumbing and no downstream match/list repeats the name.
#[derive(Clone, Copy)]
pub struct NutrientCol {
    /// The `food-log.csv` column name.
    pub csv: &'static str,
    /// The extract-schema JSON key (also the completion key on a verify verdict).
    pub key: &'static str,
    /// The `JESSE_MEAL_LOG` meal-wire key, or `None` when the nutrient has no
    /// HealthKit type and so never rides the wire (omega-3: there is no EPA/DHA
    /// HealthKit quantity).
    pub wire: Option<&'static str>,
    /// The short key the app's diet snapshot uses (`GET /jesse/diet`).
    pub app_key: &'static str,
    /// `mg`, `g` or `ug` — stated in the prompt so the child cannot mix units.
    pub unit: &'static str,
    /// Whether a blank cell means "incomplete" or "correctly absent".
    pub fill: FillClass,
    /// This nutrient's OWN bullet in the extract prompt's NUTRIENTS section, when the
    /// class paragraphs don't say enough: where the value comes from, and — for the
    /// risk nutrients — when `0` is a KNOWN fact rather than an absence. `None` for a
    /// nutrient the class paragraphs already cover (the label/whole-food micros).
    /// Rendered as `- \`key\` (unit): <guidance>` in table order.
    pub guidance: Option<&'static str>,
    getter: fn(&FoodEntry) -> Option<f64>,
    setter: fn(&mut FoodEntry, Option<f64>),
    wire_setter: Option<fn(&mut Meal, Option<f64>)>,
}

impl NutrientCol {
    /// This nutrient's value on a food entry.
    pub fn get(&self, f: &FoodEntry) -> Option<f64> {
        (self.getter)(f)
    }
    /// Set this nutrient's value on a food entry.
    pub fn set(&self, f: &mut FoodEntry, v: Option<f64>) {
        (self.setter)(f, v)
    }
    /// Set this nutrient's summed value on a mirror meal (no-op when the nutrient
    /// has no wire field).
    pub fn set_wire(&self, m: &mut Meal, v: Option<f64>) {
        if let Some(set) = self.wire_setter {
            set(m, v)
        }
    }
    /// Whether a blank cell for this nutrient counts as incomplete data.
    pub fn expected(&self) -> bool {
        self.fill == FillClass::ExpectedWhenKnowable
    }
}

impl std::fmt::Debug for NutrientCol {
    // Hand-written: `fn` pointers have no useful Debug, and the table's identity is
    // its names + class.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NutrientCol")
            .field("csv", &self.csv)
            .field("key", &self.key)
            .field("wire", &self.wire)
            .field("app_key", &self.app_key)
            .field("unit", &self.unit)
            .field("fill", &self.fill)
            .finish()
    }
}

/// The nutrient columns, in CSV order.
///
///   * Seven are [`FillClass::ExpectedWhenKnowable`] — the label/whole-food micros the
///     completeness figure and hosted completion are defined over.
///   * Omega-3 alone is [`FillClass::MarineOnly`] (marine EPA+DHA, never plant ALA).
///   * The seven newest are [`FillClass::EstimatedRisk`] — the risk nutrients almost no
///     label prints. Each carries its own `guidance` bullet, because for several of them
///     a `0` is a KNOWN fact (cholesterol in any plant food, mercury outside seafood,
///     added sugar in whole fruit) rather than the "did not know" a blank means.
///
/// Five nutrients have no meal-wire field — omega-3, trans fat, added sugar, purines
/// and mercury have no HealthKit type (HealthKit carries only TOTAL `dietarySugar`, so
/// an added-sugar sum would be written to the wrong quantity).
pub const NUTRIENT_COLUMNS: &[NutrientCol] = &[
    NutrientCol {
        csv: "Fiber_g",
        key: "fiber_g",
        wire: Some("fiber_g"),
        app_key: "fiber",
        unit: "g",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.fiber_g,
        setter: |f, v| f.fiber_g = v,
        wire_setter: Some(|m, v| m.fiber_g = v),
    },
    NutrientCol {
        csv: "Sodium_mg",
        key: "sodium_mg",
        wire: Some("sodium_mg"),
        app_key: "na",
        unit: "mg",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.sodium_mg,
        setter: |f, v| f.sodium_mg = v,
        wire_setter: Some(|m, v| m.sodium_mg = v),
    },
    NutrientCol {
        csv: "SatFat_g",
        key: "satfat_g",
        wire: Some("satfat_g"),
        app_key: "satf",
        unit: "g",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.satfat_g,
        setter: |f, v| f.satfat_g = v,
        wire_setter: Some(|m, v| m.satfat_g = v),
    },
    NutrientCol {
        csv: "Sugar_g",
        key: "sugar_g",
        wire: Some("sugar_g"),
        app_key: "sug",
        unit: "g",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.sugar_g,
        setter: |f, v| f.sugar_g = v,
        wire_setter: Some(|m, v| m.sugar_g = v),
    },
    NutrientCol {
        csv: "Potassium_mg",
        key: "potassium_mg",
        wire: Some("potassium_mg"),
        app_key: "k",
        unit: "mg",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.potassium_mg,
        setter: |f, v| f.potassium_mg = v,
        wire_setter: Some(|m, v| m.potassium_mg = v),
    },
    NutrientCol {
        csv: "Calcium_mg",
        key: "calcium_mg",
        wire: Some("calcium_mg"),
        app_key: "ca",
        unit: "mg",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.calcium_mg,
        setter: |f, v| f.calcium_mg = v,
        wire_setter: Some(|m, v| m.calcium_mg = v),
    },
    NutrientCol {
        csv: "Omega3_mg",
        key: "omega3_mg",
        // No HealthKit EPA+DHA quantity (`dietaryFatPolyunsaturated` includes plant
        // ALA, so it would be wrong), hence no meal-wire field.
        wire: None,
        app_key: "o3",
        unit: "mg",
        fill: FillClass::MarineOnly,
        guidance: Some(
            "marine long-chain omega-3 (EPA+DHA) ONLY: fish, shellfish, roe, and the \
small amounts in eggs and dairy. NEVER the plant ALA in walnuts, flax, chia or \
vegetable oils. OMIT the key for a plant-ALA-only food.",
        ),
        getter: |f| f.omega3_mg,
        setter: |f, v| f.omega3_mg = v,
        wire_setter: None,
    },
    NutrientCol {
        csv: "Magnesium_mg",
        key: "magnesium_mg",
        wire: Some("magnesium_mg"),
        app_key: "mg",
        unit: "mg",
        fill: FillClass::ExpectedWhenKnowable,
        guidance: None,
        getter: |f| f.magnesium_mg,
        setter: |f, v| f.magnesium_mg = v,
        wire_setter: Some(|m, v| m.magnesium_mg = v),
    },
    NutrientCol {
        csv: "Cholesterol_mg",
        key: "cholesterol_mg",
        // HealthKit `dietaryCholesterol`.
        wire: Some("cholesterol_mg"),
        app_key: "chol",
        unit: "mg",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "dietary cholesterol. Write 0 for ALL plant foods — fruit, vegetables, \
grains, legumes, nuts, seeds, oils: that 0 is a KNOWN fact, not an absence. Animal \
foods carry it (egg yolk, offal and shellfish most), so fill it from the label or from \
standard composition values, scaled to the amount logged.",
        ),
        getter: |f| f.cholesterol_mg,
        setter: |f, v| f.cholesterol_mg = v,
        wire_setter: Some(|m, v| m.cholesterol_mg = v),
    },
    NutrientCol {
        csv: "TransFat_g",
        key: "trans_fat_g",
        // No HealthKit trans-fat quantity.
        wire: None,
        app_key: "tfat",
        unit: "g",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "industrial AND natural trans fat. Write 0 for whole unprocessed plant \
foods (a known fact). Ruminant dairy and beef carry small natural amounts — about 2-5% \
of their fat. When the ingredient list shows partially hydrogenated oil, ESTIMATE \
rather than omitting: that is the case the column exists for.",
        ),
        getter: |f| f.trans_fat_g,
        setter: |f, v| f.trans_fat_g = v,
        wire_setter: None,
    },
    NutrientCol {
        csv: "AddedSugar_g",
        key: "added_sugar_g",
        // HealthKit has only TOTAL `dietarySugar` (already mirrored by `sugar_g`);
        // writing added sugar there would corrupt the total, hence no wire field.
        wire: None,
        app_key: "asug",
        unit: "g",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "FREE/ADDED sugars only — never the intrinsic sugar in whole fruit, \
vegetables or plain milk (that is `sugar_g`). Write 0 for an unprocessed whole food: a \
banana has 0 added sugar, a known fact, even though its `sugar_g` is high. Juice, \
concentrate, honey and syrup COUNT as added.",
        ),
        getter: |f| f.added_sugar_g,
        setter: |f, v| f.added_sugar_g = v,
        wire_setter: None,
    },
    NutrientCol {
        csv: "Purines_mg",
        key: "purines_mg",
        // No HealthKit purine quantity.
        wire: None,
        app_key: "pur",
        unit: "mg",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "total purines, a CLASS-BASED estimate from published purine tables \
(offal very high; anchovies, sardines and mussels high; other meat and fish moderate; \
legumes and some vegetables low-moderate), scaled to the grams logged. Near 0 for \
fruit, dairy, eggs and refined grains.",
        ),
        getter: |f| f.purines_mg,
        setter: |f, v| f.purines_mg = v,
        wire_setter: None,
    },
    NutrientCol {
        csv: "Mercury_ug",
        key: "mercury_ug",
        // No HealthKit mercury quantity.
        wire: None,
        app_key: "hg",
        unit: "ug",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "methylmercury, from the FDA mean for the NAMED species, scaled to the \
grams logged (swordfish, shark and king mackerel highest; tuna moderate and varying by \
kind; salmon, sardines, shrimp and scallops very low). Write 0 for any non-seafood — a \
known fact. Do NOT guess for an unnamed generic \"fish\": OMIT the key instead.",
        ),
        getter: |f| f.mercury_ug,
        setter: |f, v| f.mercury_ug = v,
        wire_setter: None,
    },
    NutrientCol {
        csv: "Selenium_ug",
        key: "selenium_ug",
        // HealthKit `dietarySelenium`.
        wire: Some("selenium_ug"),
        app_key: "se",
        unit: "ug",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "selenium. Brazil nuts are the extreme — about 68-91 ug in ONE nut, so \
scale carefully. Seafood, offal and eggs are good sources; plant foods vary with soil \
selenium by an ORDER OF MAGNITUDE, so treat a plant value as approximate.",
        ),
        getter: |f| f.selenium_ug,
        setter: |f, v| f.selenium_ug = v,
        wire_setter: Some(|m, v| m.selenium_ug = v),
    },
    NutrientCol {
        csv: "VitaminD_ug",
        key: "vitamin_d_ug",
        // HealthKit `dietaryVitaminD`.
        wire: Some("vitamin_d_ug"),
        app_key: "vd",
        unit: "ug",
        fill: FillClass::EstimatedRisk,
        guidance: Some(
            "vitamin D in MICROGRAMS, never IU: a label in IU must be DIVIDED BY 40 \
(400 IU = 10 ug). Oily fish, egg yolk, liver and fortified milk or cereal carry it. \
Write 0 for most unfortified plant foods — a known fact.",
        ),
        getter: |f| f.vitamin_d_ug,
        setter: |f, v| f.vitamin_d_ug = v,
        wire_setter: Some(|m, v| m.vitamin_d_ug = v),
    },
];

/// How many nutrient columns a row is EXPECTED to carry (the denominator of the
/// completeness figure): every [`FillClass::ExpectedWhenKnowable`] column.
pub fn expected_nutrient_count() -> usize {
    NUTRIENT_COLUMNS.iter().filter(|c| c.expected()).count()
}

// ---- Canonical CSV headers (single source of truth) -----------------------
//
// These headers are the ONE definition of each log's column contract. BOTH the
// append path (the row builders below target exactly these columns, in order) AND
// the extract prompt (which inlines them verbatim) consume them, so the prompt can
// never describe a schema the writer doesn't produce. `prompt_contract_matches_
// append_schema` is the drift guard that enforces this (the parity mitigation).
//
// The food header's nutrient tail is DERIVED from [`NUTRIENT_COLUMNS`]; only the 14
// core columns are spelled out here.

/// The 14 core `food-log.csv` columns, in order, ahead of the nutrient tail.
const FOOD_LOG_CORE_COLUMNS: &[&str] = &[
    "Date",
    "Meal",
    "Item",
    "Amount",
    "Unit",
    "Cal_per_100g",
    "Grams",
    "Calories",
    "Protein_g",
    "Fat_g",
    "Carbs_g",
    "Notes",
    "Time",
    "Meal_Type",
];

/// Build the food header for an arbitrary nutrient table (the parameterized form the
/// synthetic-ninth-nutrient test drives; production calls [`food_log_header`]).
fn build_food_log_header(cols: &[NutrientCol]) -> String {
    FOOD_LOG_CORE_COLUMNS
        .iter()
        .copied()
        .chain(cols.iter().map(|c| c.csv))
        .collect::<Vec<_>>()
        .join(",")
}

static FOOD_LOG_HEADER_CELL: LazyLock<String> =
    LazyLock::new(|| build_food_log_header(NUTRIENT_COLUMNS));

/// The canonical `food-log.csv` header line: the 14 core columns plus one column per
/// [`NUTRIENT_COLUMNS`] entry, in table order.
pub fn food_log_header() -> &'static str {
    &FOOD_LOG_HEADER_CELL
}

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
    // The seven RISK nutrients ([`FillClass::EstimatedRisk`]) — the same
    // unknown-is-not-zero discipline, with one nuance the extract PROMPT (never this
    // plumbing) encodes: for several of them a real `Some(0.0)` is a KNOWN fact —
    // cholesterol in any plant food, mercury outside seafood, added sugar in whole
    // fruit, vitamin D in most unfortified plants. `None` still means the message and
    // the label established nothing: a blank CSV cell and an omitted wire field.
    // `cholesterol_mg`/`purines_mg` are milligrams, `trans_fat_g`/`added_sugar_g`
    // grams, `mercury_ug`/`selenium_ug`/`vitamin_d_ug` MICROgrams.
    pub cholesterol_mg: Option<f64>,
    pub trans_fat_g: Option<f64>,
    pub added_sugar_g: Option<f64>,
    pub purines_mg: Option<f64>,
    pub mercury_ug: Option<f64>,
    pub selenium_ug: Option<f64>,
    pub vitamin_d_ug: Option<f64>,
    pub notes: Option<String>,
    /// The extract child's "I cannot identify this composite" signal: an unnamed
    /// restaurant dish, an unknown sauce — something whose nutrients cannot be looked
    /// up from a label OR from food-composition values for a named whole food. Such a
    /// row still OMITS unknown nutrients (never guesses), and this flag tells the
    /// hosted micronutrient completion pass and the completeness figure to skip it
    /// rather than chase numbers nobody can know. Defaults to `false` (a plain named
    /// food), and `#[serde(default)]` keeps the queue's persisted entries readable
    /// across the upgrade.
    #[serde(default)]
    pub unknowable_composite: bool,
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
// `Food` is the big variant (one `Option<f64>` per nutrient column, and the table keeps
// growing), so clippy flags the size gap. Boxing it would buy nothing here: a turn holds
// at most [`MAX_DIET_ENTRIES`] of these in one short-lived Vec, and the indirection would
// cost a pointer chase on every nutrient read in exchange for a few hundred bytes that
// never leave the stack of one request.
#[allow(clippy::large_enum_variant)]
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

/// The non-nutrient keys a food entry may carry; the nutrient keys come from
/// [`NUTRIENT_COLUMNS`] (see [`is_food_key`]) so there is no second list of them.
const FOOD_CORE_KEYS: &[&str] = &[
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
    "unknowable_composite",
    "notes",
];

/// Whether `k` is a key the food schema accepts: a core key or a nutrient key from
/// the table. Every nutrient key is therefore accepted by construction.
fn is_food_key(k: &str) -> bool {
    FOOD_CORE_KEYS.contains(&k) || NUTRIENT_COLUMNS.iter().any(|c| c.key == k)
}

/// An optional boolean flag: absent or `null` → `false`; a real boolean is taken as
/// given. Any non-boolean value is a schema violation (the child must not send a
/// string "true").
fn opt_bool_field(m: &serde_json::Map<String, Value>, key: &str) -> Result<bool, String> {
    match m.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
        Some(_) => Err(format!("`{key}` is not a boolean")),
    }
}

fn parse_food(m: &serde_json::Map<String, Value>) -> Result<FoodEntry, String> {
    for k in m.keys() {
        if !is_food_key(k) {
            return Err(format!("unknown food field {k:?}"));
        }
    }
    let name = req_str(m, "name")?;
    if name_is_aggregated(&name) {
        return Err(format!(
            "food entry name {name:?} spans multiple items — the schema requires ONE entry per item"
        ));
    }
    let mut f = FoodEntry {
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
        // Every nutrient is read from the table below, so none is named twice here.
        fiber_g: None,
        sodium_mg: None,
        satfat_g: None,
        sugar_g: None,
        potassium_mg: None,
        calcium_mg: None,
        omega3_mg: None,
        magnesium_mg: None,
        cholesterol_mg: None,
        trans_fat_g: None,
        added_sugar_g: None,
        purines_mg: None,
        mercury_ug: None,
        selenium_ug: None,
        vitamin_d_ug: None,
        notes: opt_str_field(m, "notes"),
        unknowable_composite: opt_bool_field(m, "unknowable_composite")?,
    };
    for c in NUTRIENT_COLUMNS {
        c.set(&mut f, opt_extract_num_field(m, c.key)?);
    }
    Ok(f)
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
/// verifier supplied (only meaningful for `Correct`), plus the optional
/// micronutrient completion for the row.
#[derive(Debug, Clone, PartialEq)]
pub struct EntryVerdict {
    pub verdict: Verdict,
    pub kcal: Option<f64>,
    pub protein_g: Option<f64>,
    pub carbs_g: Option<f64>,
    pub fat_g: Option<f64>,
    pub fiber_g: Option<f64>,
    pub reason: Option<String>,
    /// The hosted completion for this row: food-composition values for the EXPECTED
    /// nutrient columns the extract left blank. Default/empty when the verifier
    /// supplied none — completion is additive, so an old-shaped verdict (no `micros`
    /// key) parses exactly as before and simply completes nothing.
    pub completion: MicroCompletion,
}

/// The verifier's micronutrient completion for ONE row: values keyed by nutrient
/// schema key plus the one-line reference basis it used. `malformed` records that the
/// verifier DID send a completion block but it was unusable (not an object, a
/// non-numeric / negative / non-finite value) — the block is then dropped whole (no
/// partial trust) and the turn records the degrade reason. The merge rules live in
/// [`complete_food_micros`], never in the model.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MicroCompletion {
    /// Nutrient schema key → value, already validated finite and non-negative.
    pub values: std::collections::BTreeMap<String, f64>,
    /// One line naming the food-composition basis and the scaling used, e.g.
    /// `USDA SR Legacy 09040 banana raw, scaled to 118 g edible`.
    pub basis: Option<String>,
    /// The verifier sent a completion block that could not be used.
    pub malformed: bool,
}

impl MicroCompletion {
    /// Whether the verifier supplied nothing usable for this row.
    pub fn is_empty(&self) -> bool {
        self.values.is_empty() && self.basis.is_none()
    }
}

/// Parse one verdict's optional `micros` / `reference_basis` completion block.
/// Tolerant by design (completion is a degrade-only enhancement): an absent or null
/// block yields the default, and anything unusable sets `malformed` and yields NO
/// values rather than failing the verdict — the row is then appended exactly as the
/// extract produced it.
fn parse_completion(m: &serde_json::Map<String, Value>) -> MicroCompletion {
    let mut out = MicroCompletion {
        basis: opt_str_field(m, "reference_basis").map(|s| sanitize_basis(&s)),
        ..Default::default()
    };
    let raw = match m.get("micros") {
        None | Some(Value::Null) => return out,
        Some(v) => v,
    };
    let Some(obj) = raw.as_object() else {
        out.malformed = true;
        return out;
    };
    for (k, v) in obj {
        // A null/blank is the verifier DECLINING this nutrient — normal, not malformed:
        // the cell stays blank (never 0).
        match v {
            Value::Null => continue,
            Value::String(s) if s.trim().is_empty() => continue,
            _ => {}
        }
        match v.as_f64() {
            Some(n) if n.is_finite() && n >= 0.0 => {
                out.values.insert(k.clone(), n);
            }
            // One unusable value discredits the whole block: drop it all, no partial
            // trust in numbers we cannot validate.
            _ => {
                out.values.clear();
                out.malformed = true;
                return out;
            }
        }
    }
    out
}

/// Squeeze a reference-basis string into ONE safe CSV note: collapse every run of
/// whitespace (including the CR/LF that a bare newline in a CSV cell would smuggle
/// in) to a single space, trim, and cap the length. The Notes cell is still
/// RFC-4180-quoted by [`csv_field`]; this keeps the cell one readable line.
fn sanitize_basis(s: &str) -> String {
    const MAX_BASIS_CHARS: usize = 180;
    let one_line = s.split_whitespace().collect::<Vec<_>>().join(" ");
    match one_line.char_indices().nth(MAX_BASIS_CHARS) {
        Some((i, _)) => one_line[..i].trim_end().to_string(),
        None => one_line,
    }
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
            // Degrade-only: a bad completion block never fails the verdict (see
            // `parse_completion`), it just completes nothing and is recorded.
            completion: parse_completion(m),
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
        unknowable_composite: false,
        kcal: apply(f.kcal, v.kcal).ok()?,
        protein_g: apply(f.protein_g, v.protein_g).ok()?,
        carbs_g: apply(f.carbs_g, v.carbs_g).ok()?,
        fat_g: apply(f.fat_g, v.fat_g).ok()?,
        fiber_g: apply(f.fiber_g, v.fiber_g).ok()?,
        ..f.clone()
    };
    Some(DietEntry::Food(corrected))
}

// ---- Micronutrient completion (merge rules live HERE, not in the model) ----

/// Merge one row's hosted completion into the entry and report how many blank cells
/// it filled. EVERY merge rule is enforced here in trusted Rust, so a verifier that
/// returns more than it should cannot widen the change:
///
///   * **Blank only.** A value fills a cell that is `None`; it NEVER overwrites a
///     value the extract produced. A nutrition label therefore always wins.
///   * **Never 0 for a declined value.** A nutrient the verifier omitted (or nulled,
///     or sent unusably — see [`parse_completion`]) stays BLANK. Only an explicit,
///     finite, non-negative number is written; an explicit `0` is a measured zero
///     (plain meat really has 0 fiber), exactly as on the extract path.
///   * **Expected columns only.** [`FillClass::MarineOnly`] (omega-3) is never
///     completed — a blank there is the correct state for most foods — so a value
///     the verifier volunteers for it is ignored.
///   * **Composites are skipped whole.** An `unknowable_composite` row is left
///     untouched, including its Notes.
///   * **Notes only when empty.** The reference basis is written to Notes ONLY when
///     Notes is empty AND at least one cell was actually filled; existing note text
///     is never overwritten and nothing is appended to an uncompleted row.
///   * **Nothing else moves.** Only nutrient fields and (conditionally) Notes are
///     touched here: name, meal, time, amount, unit and the core macros are not
///     reachable from this function. A changed macro is the verify CORRECTION path
///     ([`resolve_verdict`]), which has already run by the time this does.
pub fn complete_food_micros(f: &mut FoodEntry, c: &MicroCompletion) -> usize {
    // A composite nobody can identify is not chased.
    if f.unknowable_composite {
        return 0;
    }
    let mut filled = 0;
    for col in NUTRIENT_COLUMNS.iter().filter(|c| c.expected()) {
        // Blank only — a value the extract produced (from a label) always wins.
        if col.get(f).is_some() {
            continue;
        }
        // Declined → stays blank. `parse_completion` has already rejected
        // non-finite/negative values, and re-checking here keeps this function safe
        // for any caller.
        match c.values.get(col.key) {
            Some(&v) if v.is_finite() && v >= 0.0 => {
                col.set(f, Some(v));
                filled += 1;
            }
            _ => {}
        }
    }
    // The basis rides in Notes only when this row was actually completed and its
    // Notes cell is empty.
    if filled > 0 {
        let notes_empty = f
            .notes
            .as_deref()
            .map(|n| n.trim().is_empty())
            .unwrap_or(true);
        if notes_empty {
            // Sanitized HERE as well as at parse time: the merge is the trusted layer,
            // and a bare CR/newline in a CSV cell is exactly the defect that once broke
            // the food log's own header line.
            let basis = c
                .basis
                .as_deref()
                .map(sanitize_basis)
                .filter(|b| !b.is_empty());
            if let Some(basis) = basis {
                f.notes = Some(basis);
            }
        }
    }
    filled
}

/// The EXPECTED nutrient columns still blank on this row, by CSV column name — what
/// the audit prints per item so an incomplete row can be repaired by hand. An
/// `unknowable_composite` row reports nothing missing (it is excluded by design).
pub fn missing_expected_nutrients(f: &FoodEntry) -> Vec<&'static str> {
    if f.unknowable_composite {
        return Vec::new();
    }
    NUTRIENT_COLUMNS
        .iter()
        .filter(|c| c.expected() && c.get(f).is_none())
        .map(|c| c.csv)
        .collect()
}

/// The turn's nutrient completeness as `(filled, expected)` over the food rows that
/// completion applies to. `unknowable_composite` rows are excluded from BOTH numbers
/// (they are not incomplete data), so a turn of only composites reports `0/0`.
pub fn nutrient_completeness(rows: &[FoodEntry]) -> (usize, usize) {
    let per_row = expected_nutrient_count();
    let eligible: Vec<&FoodEntry> = rows.iter().filter(|r| !r.unknowable_composite).collect();
    let expected = eligible.len() * per_row;
    let filled = eligible
        .iter()
        .map(|r| {
            NUTRIENT_COLUMNS
                .iter()
                .filter(|c| c.expected() && c.get(r).is_some())
                .count()
        })
        .sum();
    (filled, expected)
}

/// Why a turn still carries a blank EXPECTED nutrient column, as one content-free
/// code for the provenance line and the metrics record. Emitted ONLY when at least
/// one expected column is blank after the completion pass; a fully complete turn
/// carries no reason at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicroReason {
    /// The verifier sent an unusable completion block (dropped whole; rows appended
    /// exactly as extracted).
    Unparseable,
    /// Completion is switched off (`JESSE_DIET_MICRO_COMPLETE` falsey) — the old
    /// behavior, so blanks are expected.
    Disabled,
    /// Completion ran and the verifier simply declined some columns.
    Incomplete,
}

impl MicroReason {
    /// The machine-readable code (content-free).
    pub fn code(self) -> &'static str {
        match self {
            MicroReason::Unparseable => "micro_complete_unparseable",
            MicroReason::Disabled => "micro_complete_off",
            MicroReason::Incomplete => "micros_incomplete",
        }
    }
}

/// Decide the turn's micro reason code from the completeness figure and how the
/// completion pass went. `None` when every expected column on every eligible row is
/// filled (nothing to report), otherwise the most specific cause.
pub fn micro_reason(
    filled: usize,
    expected: usize,
    enabled: bool,
    any_malformed: bool,
) -> Option<MicroReason> {
    if expected < 1 || filled >= expected {
        return None;
    }
    Some(if any_malformed {
        MicroReason::Unparseable
    } else if !enabled {
        MicroReason::Disabled
    } else {
        MicroReason::Incomplete
    })
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
    // The 14 core cells, then one nutrient cell per NUTRIENT_COLUMNS entry IN TABLE
    // ORDER — the same order `food_log_header()` names them, so the two cannot drift.
    // Every nutrient cell is blank when unknown, never 0.
    let mut cols = vec![
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
    ];
    cols.extend(NUTRIENT_COLUMNS.iter().map(|c| num_cell(c.get(e))));
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
            let mut meal = Meal {
                // The deterministic hosted-contract id: `<date>-<slug>-<HHMM>`, no seq.
                id: format!("{date}-{}-{}", g.slug, g.hhmm),
                consumed_at: format!("{date}T{}:00{offset}", g.time),
                name: format!("{}: {}", g.meal_label, names.join(", ")),
                // Macros summed over the group in trusted Rust (unknown-is-not-zero).
                kcal: sum_known(g.rows.iter().map(|r| r.kcal)),
                protein_g: sum_known(g.rows.iter().map(|r| r.protein_g)),
                carbs_g: sum_known(g.rows.iter().map(|r| r.carbs_g)),
                fat_g: sum_known(g.rows.iter().map(|r| r.fat_g)),
                // Every nutrient field is filled from the table below — including
                // `fiber_g`, so no nutrient name is repeated here.
                fiber_g: None,
                sodium_mg: None,
                satfat_g: None,
                sugar_g: None,
                potassium_mg: None,
                calcium_mg: None,
                magnesium_mg: None,
                cholesterol_mg: None,
                selenium_ug: None,
                vitamin_d_ug: None,
            };
            // Nutrients summed the same way, driven by the table: only the rows that
            // stated a value contribute, and a group where none did omits the field
            // (never Some(0)). A nutrient with no wire field (omega-3, which has no
            // HealthKit EPA+DHA type) has no setter, so nothing is mirrored for it.
            for c in NUTRIENT_COLUMNS {
                c.set_wire(&mut meal, sum_known(g.rows.iter().map(|r| c.get(r))));
            }
            meal
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

/// Fat window edges (grams), mirroring the app's `DietSemantics`: hormonal floor,
/// working cap. The 70g hard cap is a firmer line the wording notes but the bar
/// doesn't need its own edge for.
const FAT_FLOOR_G: f64 = 50.0;
const FAT_CAP_G: f64 = 65.0;

/// A 20-char progress bar filled proportionally to `pct` (0–100+, clamped to 100).
/// Deliberately MONOCHROME — a single meaning, "how far along", carried by one fill
/// glyph. The old pass/fail color emoji made one color mean three different things
/// across rows (too-low on a floor, too-high on a ceiling, both on the fat window);
/// the status now lives in the trailing words, so the bar can stay neutral.
fn progress_bar(pct: f64) -> String {
    let filled = ((pct / 100.0) * BAR_WIDTH as f64)
        .round()
        .clamp(0.0, BAR_WIDTH as f64) as usize;
    let mut s = String::new();
    for _ in 0..filled {
        s.push('█');
    }
    for _ in 0..(BAR_WIDTH - filled) {
        s.push('░');
    }
    s
}

/// The kind status word for a FLOOR metric — action-first and never punitive, mirroring
/// the app's `floorRemaining`. Reached: "there — nice"; short: "Xg to go".
fn floor_word(intake: f64, target: f64) -> String {
    if intake >= target {
        "there — nice".to_string()
    } else {
        format!("{}g to go", fmt_g((target - intake).round()))
    }
}

/// The kind status word for the CALORIE ceiling, mirroring `ceilingRemaining`: headroom
/// framed as room, not a limit — "room for X" / "right on target" / "X over".
fn ceiling_word(intake: f64, target: f64) -> String {
    if intake < target {
        format!("room for {}", fmt_g((target - intake).round()))
    } else if intake > target {
        format!("{} over", fmt_g((intake - target).round()))
    } else {
        "right on target".to_string()
    }
}

/// The kind status word for the FAT window, mirroring `fatWindowRemaining`: direction in
/// words, no "cap" language — "Xg to the 50g floor" / "in range" / "Xg above the range".
fn fat_word(grams: f64) -> String {
    if grams < FAT_FLOOR_G {
        format!("{}g to the 50g floor", fmt_g((FAT_FLOOR_G - grams).round()))
    } else if grams <= FAT_CAP_G {
        "in range".to_string()
    } else {
        format!("{}g above the range", fmt_g((grams - FAT_CAP_G).round()))
    }
}

fn pct_of(intake: f64, target: f64) -> f64 {
    if target > 0.0 {
        intake / target * 100.0
    } else {
        0.0
    }
}

/// The plain summary line that LEADS the dashboard — "how am I doing / what would help
/// next" — the same supportive-coach opening the app's Health tab uses. Deterministic and
/// gentle: it names the one or two floors most worth topping up, flags calories only when
/// genuinely over, and otherwise says the day's on track. Empty string when there are no
/// targets to judge against (the bars render as plain totals then).
fn summary_line(totals: &MacroTotals, targets: &DietTargets) -> String {
    // Genuinely-short floors (below 80% of target — the app's "basically there" cutoff),
    // worst-first, named for the "what would help next" line.
    let mut shorts: Vec<(&str, f64)> = Vec::new();
    for (label, intake, target) in [
        ("protein", totals.protein_g, targets.protein),
        ("carbs", totals.carbs_g, targets.carbs),
        ("fiber", totals.fiber_g, targets.fiber),
    ] {
        if let Some(t) = target {
            if t > 0.0 && intake < 0.8 * t {
                shorts.push((label, (t - intake) / t));
            }
        }
    }
    // Fat below its 50g floor is a floor-like concern too.
    if targets.fat.is_some() && totals.fat_g < FAT_FLOOR_G {
        shorts.push(("fat", (FAT_FLOOR_G - totals.fat_g) / FAT_FLOOR_G));
    }
    shorts.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let calories_over = matches!(targets.cal, Some(t) if t > 0.0 && totals.kcal > t);

    if calories_over {
        return "A little over on calories today — easy to ease back tomorrow.".to_string();
    }
    match shorts.len() {
        0 if targets.cal.is_some() || targets.protein.is_some() => {
            "You're on track — nicely balanced.".to_string()
        }
        0 => String::new(),
        1 => format!(
            "Coming together. A bit more {} rounds out the day.",
            shorts[0].0
        ),
        _ => format!(
            "Coming together. Some {} and some {} rounds out the day.",
            shorts[0].0, shorts[1].0
        ),
    }
}

/// Render the deterministic ASCII dashboard for `date` from the day's totals and targets.
/// A plain-language summary leads; then one row per metric — its goal glyph for direction
/// (≤ ceiling, ≥ floor, ↕ window), a neutral progress bar, the numbers, and a kind status
/// word. Color no longer carries meaning (the words do), so the same green that meant
/// "too low" on a floor and "too high" on a ceiling is gone. When a target is absent the
/// metric renders its plain total. The child never writes this — it is derived from the
/// CSVs, and it tells the same story as the app's Health tab.
pub fn render_diet_dashboard(date: &str, totals: &MacroTotals, targets: &DietTargets) -> String {
    let mut out = format!("=== Diet — {date} ===\n\n");

    let summary = summary_line(totals, targets);
    if !summary.is_empty() {
        out.push_str(&summary);
        out.push_str("\n\n");
    }

    // Calories — a ceiling metric (round to whole numbers, like the generator).
    match targets.cal {
        Some(t) => {
            let pct = pct_of(totals.kcal, t);
            out.push_str(&format!(
                "Cal      ≤ {}   {}  {} / {}   {}\n",
                t.round() as i64,
                progress_bar(pct),
                totals.kcal.round() as i64,
                t.round() as i64,
                ceiling_word(totals.kcal, t),
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
                    "{label:<8} ≥ {}   {}  {} / {}g   {}\n",
                    fmt_g(t),
                    progress_bar(pct),
                    fmt_g(intake),
                    fmt_g(t),
                    floor_word(intake, t),
                ));
            }
            None => out.push_str(&format!("{label:<8}     {}g\n", fmt_g(intake))),
        }
    }

    // Fat — a window metric. Direction (too low vs too high) is in the words, never color.
    match targets.fat {
        Some(t) => {
            let pct = pct_of(totals.fat_g, t);
            out.push_str(&format!(
                "Fat      ↕ 50–65 {}  {} / {}g   {}\n",
                progress_bar(pct),
                fmt_g(totals.fat_g),
                fmt_g(t),
                fat_word(totals.fat_g),
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
        "vault/generate-diet-today.js",
        "vault/validate-diet-today.js",
        "vault/verify-diet-consistency.js",
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
        .args(["add", "diet-logs", "vault/diet-today.js"])
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
/// derived, the turn's nutrient completeness as `filled/expected` (plus the
/// [`MicroReason`] code when any expected column is still blank), and — on a rung-2
/// fall-through — the machine-readable [`Rung2Reason`] code.
///
/// Still strictly content-free: counts, codes, a base URL and a model name; never
/// meal text and never a token.
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
    micros: Option<(usize, usize, Option<MicroReason>)>,
) -> String {
    let disposition = if local {
        "local".to_string()
    } else {
        format!("hosted-fallback rung={}", rung.unwrap_or(0))
    };
    let mirror = if mirror_derived { "derived" } else { "omitted" };
    // The machine-readable rung-2 reason rides after the disposition (content-free).
    let reason = reason.map(|r| format!(" reason={r}")).unwrap_or_default();
    // Nutrient completeness, `filled/expected` over the turn's eligible food rows.
    // Omitted entirely on a turn that appended no eligible food row.
    let micros = micros
        .map(|(filled, expected, why)| {
            let why = why
                .map(|w| format!(" micro_reason={}", w.code()))
                .unwrap_or_default();
            format!(" micros={filled}/{expected}{why}")
        })
        .unwrap_or_default();
    format!(
        "jesse-bridge: diet turn -> {disposition}{reason} extract base_url={base_url} model={model}; \
         verify verdict={verify}; rows={rows} mirror={mirror}{micros}"
    )
}

// ---- Prompts ---------------------------------------------------------------

/// Build the JSON schema the extract child must return, for an arbitrary nutrient
/// table (the parameterized form the synthetic-ninth-nutrient test drives;
/// production calls [`diet_extract_schema`]). The food entry's nutrient keys come
/// from the table, so a new nutrient column appears in the schema automatically.
fn build_extract_schema(cols: &[NutrientCol]) -> String {
    let nutrients = cols
        .iter()
        .map(|c| format!("\"{}\": <number, {}>", c.key, c.unit))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        r#"{{
  "no_loggable_content": <boolean: true if the message logs nothing NEW to eat/drink, no workout, no weight — OR if it AMENDS/corrects/moves/deletes something already logged instead of reporting new consumption; in either case return an empty entries array>,
  "entries": [
    {{ "kind": "food", "name": "<ONE food item, never a combined meal>", "meal": "Breakfast|Lunch|Dinner|Snack", "time": "<HH:MM ONLY if the message states a clock time, else null/omit — never invent one>", "amount": "<e.g. 1 medium (~118g)>", "unit": "serving", "kcal": <number>, "protein_g": <number>, "carbs_g": <number>, "fat_g": <number>, {nutrients}, "unknowable_composite": <boolean, optional, default false: true ONLY for a composite you cannot identify>, "notes": "<optional>" }},
    {{ "kind": "exercise", "activity": "Run|Walk|Swim|Strength/Weights|...", "time": "<HH:MM ONLY if stated, else null/omit>", "description": "<optional>", "distance_km": <number>, "duration": "<e.g. 56:58>", "pace": "<e.g. 7:07>", "avg_hr": <number>, "calories": <number>, "notes": "<optional>" }},
    {{ "kind": "weight", "weight_lbs": <number>, "weight_kg": <number>, "body_fat_pct": <number>, "muscle_mass_lbs": <number>, "notes": "<optional>" }}
  ]
}}"#
    )
}

static DIET_EXTRACT_SCHEMA_CELL: LazyLock<String> =
    LazyLock::new(|| build_extract_schema(NUTRIENT_COLUMNS));

/// The JSON schema the extract child must return — a per-item `entries` array plus
/// `no_loggable_content`. Derived from [`NUTRIENT_COLUMNS`] so the prompt, the report
/// and the validator share one source. See [`parse_diet_entries`] for the enforcing
/// validator.
pub fn diet_extract_schema() -> &'static str {
    &DIET_EXTRACT_SCHEMA_CELL
}

/// Build the NUTRIENTS section of the extract prompt from a nutrient table.
///
/// This is the reversal of the original defect: the first contract told the child to
/// fill a nutrient only from a label "or a confident estimate" and to OMIT it
/// otherwise, and volunteered that potassium/calcium/magnesium are "usually absent
/// from labels so usually omitted". The child obeyed, so every locally-logged row
/// arrived with three or more knowable columns blank. The branches below tell it the
/// opposite for a food it can identify, while keeping the honest-omission rule for
/// the one case where nobody can know (an unidentifiable composite), for the one
/// nutrient that is genuinely absent from most foods (marine omega-3), and for the
/// [`FillClass::EstimatedRisk`] columns almost no label prints.
///
/// Each column may also carry its OWN bullet ([`NutrientCol::guidance`]) — where its
/// value comes from and, for the risk nutrients, when `0` is a KNOWN fact rather than
/// the "did not know" a blank means. That distinction lives HERE, in the prompt, never
/// in the plumbing: every stage below still treats absent as unknown and writes a
/// blank cell.
///
/// Worded for a small local model: short sentences, imperative, no hedging.
fn build_nutrient_rules(cols: &[NutrientCol]) -> String {
    let list =
        |f: FillClass| -> Vec<&NutrientCol> { cols.iter().filter(|c| c.fill == f).collect() };
    let expected = list(FillClass::ExpectedWhenKnowable);
    let expected_named = expected
        .iter()
        .map(|c| format!("`{}` ({})", c.key, c.unit))
        .collect::<Vec<_>>()
        .join(", ");
    let mut s = String::new();
    s.push_str(
        "NUTRIENTS (fill these — a blank column is missing data, not a zero):\n\
- EXPECTED on every food you can identify: ",
    );
    s.push_str(&expected_named);
    s.push_str(
        ". Fill EVERY one of them.\n\
- PACKAGED FOOD WITH A NUTRITION PANEL IN THE MESSAGE: use the panel. Scale it to \
the amount actually logged. If the label prints salt (\"sale\") in grams instead of \
sodium, then sodium_mg = salt_grams × 400. `sugar_g` is TOTAL sugars (\"di cui \
zuccheri\"), never added sugars. `satfat_g` is the saturated-fat line (\"di cui acidi \
grassi saturi\").\n\
- LABEL-LESS WHOLE FOOD — fruit, vegetables, eggs, plain meat, plain fish, plain \
nuts, plain grains, milk: fill every EXPECTED nutrient from standard food-composition \
values for that food, scaled to the EDIBLE grams logged. Exclude pit, peel, core, \
shell and bone. Do NOT leave a column blank because no label printed it. A banana, an \
egg, a chicken breast: you know these values. Write them.\n\
- SODIUM is the food's own intrinsic sodium, plus label salt, plus restaurant \
seasoning. Never add a \"probably salted it\" amount to a home-cooked item.\n",
    );
    // The risk columns: estimate-or-omit, stated ONCE for the class, then per-nutrient
    // below. Their `0` cases are the guidance bullets' job.
    let risk = list(FillClass::EstimatedRisk);
    if !risk.is_empty() {
        s.push_str("- ESTIMATE THESE, or omit them — ");
        s.push_str(
            &risk
                .iter()
                .map(|c| format!("`{}` ({})", c.key, c.unit))
                .collect::<Vec<_>>()
                .join(", "),
        );
        s.push_str(
            ": almost no label prints them. Fill one from a label that DOES state it, \
or from a confident value for that food; omit it when you cannot source either. Where \
a bullet below says to write 0, that 0 is a KNOWN fact about the food and you MUST \
write it — it is not a placeholder for \"I don't know\".\n",
        );
    }
    // Each column's own bullet, in table order.
    for c in cols.iter().filter(|c| c.guidance.is_some()) {
        s.push_str(&format!(
            "- `{}` ({}) is {}\n",
            c.key,
            c.unit,
            c.guidance.expect("filtered to Some")
        ));
    }
    s.push_str(
        "- A COMPOSITE YOU CANNOT IDENTIFY — an unnamed restaurant dish, an unknown \
sauce: still OMIT rather than guess, and set `\"unknowable_composite\": true` on that \
entry.\n\
- `0` means a real measured zero (plain meat has 0 fiber and 0 sugar). NEVER write 0 \
to mean \"I don't know\" — omit the key instead.\n",
    );
    s
}

static NUTRIENT_RULES_CELL: LazyLock<String> =
    LazyLock::new(|| build_nutrient_rules(NUTRIENT_COLUMNS));

/// The NUTRIENTS section of the extract prompt, derived from [`NUTRIENT_COLUMNS`].
pub fn diet_nutrient_rules() -> &'static str {
    &NUTRIENT_RULES_CELL
}

/// Build the stateless EXTRACT prompt: the CSV/macro contract (inlined from the same
/// header consts the append path targets — the parity source of truth), the per-item
/// anti-aggregation rule, the schema, and the JSON-only instruction. The raw
/// utterance is appended. The child holds no tools, so everything it needs is here.
pub fn build_diet_extract_prompt(utterance: &str, owner: &str) -> String {
    let food_header = food_log_header();
    let nutrient_rules = diet_nutrient_rules();
    let schema = diet_extract_schema();
    format!(
        "You extract structured diet-log entries from a short message {owner} sent from \
their phone. Return ONLY a single JSON object — no prose, no markdown, no code fence.\n\
\n\
CONTRACT (the vault's diet logs; you are parsing INTO these columns):\n\
- food-log.csv columns: {food_header}\n\
- exercise-log.csv columns: {EXERCISE_LOG_HEADER}\n\
- weight-log.csv columns: {WEIGHT_LOG_HEADER}\n\
- Macros are per-ITEM absolute grams/kcal. Omit any macro you don't know — NEVER \
guess and NEVER write 0 as a placeholder (0 means a real measured zero).\n\
{nutrient_rules}\
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
{schema}\n\
\n\
MESSAGE:\n{utterance}"
    )
}

/// Build the hosted VERIFY prompt: the raw utterance plus the candidate entries, and
/// a per-entry approve/correct/reject instruction with the tolerance band spelled
/// out (differs by more than 20% OR 75 kcal per item). Returns a `verdicts` array,
/// one verdict per candidate, in order.
pub fn build_diet_verify_prompt(
    utterance: &str,
    candidates_json: &str,
    owner: &str,
    complete_micros: bool,
) -> String {
    // The completion half of the contract, present ONLY when
    // `JESSE_DIET_MICRO_COMPLETE` is on. With it off the prompt is byte-for-byte the
    // macro-verdict prompt this pipeline has always sent.
    let (completion_task, completion_schema) = if complete_micros {
        (
            format!(
                "\nALSO COMPLETE THE NUTRIENTS. Each candidate carries the nutrient values \
the local model produced; a key that is ABSENT is a BLANK column in the log, not a \
zero. For each candidate you judge to be a LABEL-LESS WHOLE FOOD (fruit, vegetables, \
eggs, plain meat, plain fish, plain nuts, plain grains, milk), return in `micros` the \
values for the EXPECTED nutrient keys that candidate LEFT BLANK, from standard \
food-composition data for that food, scaled to the EDIBLE grams logged (pit, peel, \
core, shell and bone excluded). Rules:\n\
- EXPECTED keys: {expected}. Never return a value for a key the candidate already \
carries — a nutrition label wins and your value would be discarded anyway.\n\
- Omit a key you cannot source. An omitted key stays BLANK in the log. NEVER send 0 to \
mean \"unknown\"; send 0 only for a real measured zero (plain meat has 0 fiber).\n\
- Do NOT return `micros` for a candidate flagged `unknowable_composite`, for a \
packaged food whose label the message quoted, or for a dish you cannot identify.\n\
- `reference_basis`: ONE line naming the food-composition basis and the scaling you \
used, e.g. \"USDA SR Legacy banana raw, 89 kcal/100 g, scaled to 118 g edible\". It is \
written to the row's empty Notes cell.\n\
- Completion is SEPARATE from the verdict. It never changes the item, the meal, the \
time, the amount or any macro; correcting a macro is the `correct` verdict above.\n",
                expected = NUTRIENT_COLUMNS
                    .iter()
                    .filter(|c| c.expected())
                    .map(|c| format!("`{}` ({})", c.key, c.unit))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            ", \"micros\": {{ \"<nutrient key>\": <num>, ... }}, \
\"reference_basis\": \"<one line>\"",
        )
    } else {
        (String::new(), "")
    };
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
{completion_task}\
\n\
SCHEMA:\n\
{{ \"verdicts\": [ {{ \"verdict\": \"approve|correct|reject\", \"kcal\": <num>, \
\"protein_g\": <num>, \"carbs_g\": <num>, \"fat_g\": <num>, \"fiber_g\": <num>, \
\"reason\": \"<short>\"{completion_schema} }} ] }}\n\
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
        DietEntry::Food(f) => {
            let mut v = json!({
                "kind": "food", "name": f.name, "meal": f.meal, "time": f.time,
                "amount": f.amount, "kcal": f.kcal, "protein_g": f.protein_g,
                "carbs_g": f.carbs_g, "fat_g": f.fat_g,
            });
            let m = v.as_object_mut().expect("json! built an object");
            // Every nutrient the extract KNOWS rides along, and an unknown one is
            // OMITTED — that asymmetry is the completion contract's input: the verifier
            // fills exactly the keys it does not see. (Before completion this shape
            // carried only `fiber_g`, so the verifier could not tell blank from unsent.)
            for c in NUTRIENT_COLUMNS {
                if let Some(n) = c.get(f) {
                    m.insert(c.key.to_string(), json!(n));
                }
            }
            // Only sent when true, so the ordinary row's shape is unchanged.
            if f.unknowable_composite {
                m.insert("unknowable_composite".to_string(), json!(true));
            }
            v
        }
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

/// The nutrient-completeness accounting for ONE local-route turn — the numbers the
/// provenance line, the metrics record and the daily audit all report. Content-free
/// by construction (counts and a code, never an item name).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MicroStats {
    /// Food rows appended on this turn.
    pub food_rows: usize,
    /// Food rows completion applies to (`food_rows` minus `unknowable_composite`).
    pub eligible_rows: usize,
    /// Eligible rows where the hosted completion filled at least one blank cell.
    pub rows_completed: usize,
    /// Eligible rows that STILL carry at least one blank expected column.
    pub rows_incomplete: usize,
    /// Expected nutrient cells actually filled across the eligible rows.
    pub filled: usize,
    /// Expected nutrient cells across the eligible rows (`eligible_rows` ×
    /// [`expected_nutrient_count`]).
    pub expected: usize,
    /// Why anything is still blank ([`MicroReason`]); `None` when the turn is complete.
    pub reason: Option<MicroReason>,
}

impl MicroStats {
    /// Compute the turn's accounting from the appended food rows. `enabled` is the
    /// completion flag and `any_malformed` whether the verifier's completion block was
    /// unusable — together they explain a blank column.
    pub fn compute(
        rows: &[FoodEntry],
        rows_completed: usize,
        enabled: bool,
        any_malformed: bool,
    ) -> MicroStats {
        let (filled, expected) = nutrient_completeness(rows);
        let eligible: Vec<&FoodEntry> = rows.iter().filter(|r| !r.unknowable_composite).collect();
        MicroStats {
            food_rows: rows.len(),
            eligible_rows: eligible.len(),
            rows_completed,
            rows_incomplete: eligible
                .iter()
                .filter(|r| !missing_expected_nutrients(r).is_empty())
                .count(),
            filled,
            expected,
            reason: micro_reason(filled, expected, enabled, any_malformed),
        }
    }

    /// The `(filled, expected, reason)` triple the provenance line renders, or `None`
    /// when the turn appended no eligible food row (nothing to report).
    pub fn provenance(&self) -> Option<(usize, usize, Option<MicroReason>)> {
        (self.eligible_rows > 0).then_some((self.filled, self.expected, self.reason))
    }
}

/// The outcome of the local pipeline for one turn.
pub enum DietPipelineOutcome {
    /// Logged locally: the ASCII dashboard reply plus the derived directives (mirror).
    Logged {
        dashboard: String,
        directives: Directives,
        micros: MicroStats,
    },
    /// Logged locally but the mirror was omitted (rung 5): CSV committed, no directive.
    LoggedNoMirror {
        dashboard: String,
        micros: MicroStats,
    },
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
pub async fn run_diet_pipeline(
    cfg: &Config,
    health: &HealthStore,
    utterance: &str,
) -> DietPipelineOutcome {
    // Who extracts, per the routing rule at `Basic`.
    let extract_pick = route_job(cfg, health, RoutedJob::DietExtract, None, None);
    let (base_url, model) = match &extract_pick.backend {
        Some((b, _t, m)) => (b.clone(), m.clone()),
        None => (String::new(), extract_pick.id.clone()),
    };
    // The turn's received-at wall clock (`HH:MM`), captured as the pipeline receives
    // the turn. The bridge stamps this onto any food entry whose time the utterance
    // never stated (see [`stamp_missing_food_times`]); the model never invents a time.
    let received_hhmm = local_hhmm();
    // A fall-through provenance line: no rows were appended, so there is no nutrient
    // completeness to report (`micros` is omitted).
    let prov = |local: bool, rung: Option<u8>, verify: &str, rows: usize, mirror: bool| {
        eprintln!(
            "{}",
            format_diet_provenance(
                local, rung, &base_url, &model, verify, rows, mirror, None, None
            )
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
                None,
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
        &extract_pick,
    )
    .await
    {
        Ok(s) => s,
        // Log the child's own error before collapsing it into `child_error`. The
        // reason code alone cannot distinguish a model failure from an unreachable
        // backend, and this arm swallowing the message once hid a 14-hour local
        // gateway outage behind what looked like ordinary rung-2 flakiness. The
        // message is the child's status + text (no utterance content), so it is
        // safe to log under the same rules as the provenance line.
        Err((status, msg)) => {
            eprintln!("jesse-bridge: diet extract child failed: {status} {msg}");
            return fall_child(Rung2Reason::ChildError);
        }
    };
    let extract = match parse_diet_entries(&extract_raw) {
        Ok(e) if e.no_loggable_content => return fall_child(Rung2Reason::NoLoggable),
        Ok(e) if e.entries.is_empty() => return fall_child(Rung2Reason::EmptyEntries),
        Ok(e) => e,
        Err(msg) => return fall_child(Rung2Reason::from_parse_error(&msg)),
    };

    // Stage 2 — verify (probation: mandatory, blocking, 100%). The SAME call also
    // carries the micronutrient completion request when `JESSE_DIET_MICRO_COMPLETE`
    // is on (default): it already holds the raw utterance and the candidate rows, so
    // completion costs no extra round trip. The two behaviors stay independently
    // flagged — probation owns whether this verdict blocks the append, this flag owns
    // whether blank expected nutrient columns get filled.
    let complete_micros = cfg.diet_micro_complete;

    // WHETHER TO VERIFY AT ALL IS NOW THE EXTRACTOR'S LEVEL, not where it ran.
    //
    // The ladder used to encode "a local backend is probationary, a hosted one is not",
    // which asked where the process lived rather than what it was trusted with. At `Write`
    // the extraction is taken as-is; below it, it is verified.
    //
    // THIS IS ONE IMPERFECT PROXY SUBSTITUTED FOR ANOTHER, NOT A CLAIM THAT THEY ARE THE
    // SAME PROPERTY. A model trusted with the vault can still be sloppy at parsing a
    // sentence about lunch. The substitution is deliberate and the reasoning is on
    // `routing::skips_verification`; what makes it defensible is that it is visible in
    // config and correctable by a `level` edit rather than a code change.
    let verdicts: Vec<EntryVerdict> = if skips_verification(extract_pick.level) {
        eprintln!(
            "jesse-bridge: diet verify skipped — extraction served by '{}' at level {}",
            extract_pick.id,
            capability_label(extract_pick.level)
        );
        // Take the extraction as it stands: one approving verdict per row, carrying no
        // corrections and no completion. Downstream is byte-for-byte the "verifier approved
        // everything" path, so nothing else in the pipeline learns that a stage was skipped.
        extract
            .entries
            .iter()
            .map(|_| EntryVerdict {
                verdict: Verdict::Approve,
                kcal: None,
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                reason: None,
                completion: MicroCompletion::default(),
            })
            .collect()
    } else {
        // The verifier: the routing rule at `Write`, with the EXTRACTOR EXCLUDED so a model
        // can never verify its own extraction. Without that exclusion the first cheap model
        // in the list would do both, which silently deletes the property this gate exists to
        // provide. When nothing qualifies the walk falls through to ambient — the hosted
        // rung, exactly as the ladder degrades today.
        let verify_pick = route_job(
            cfg,
            health,
            RoutedJob::DietVerify,
            None,
            Some(&extract_pick.id),
        );
        let verify_raw = match run_diet_verify(
            cfg,
            &build_diet_verify_prompt(
                utterance,
                &entries_to_json(&extract.entries),
                &cfg.persona.owner_name,
                complete_micros,
            ),
            DIET_VERIFY_TIMEOUT_SECS,
            &verify_pick,
        )
        .await
        {
            Ok(s) => s,
            Err(e) => {
                // The verify child errored — surface it as VerifyUnavailable carrying the
                // extract so an emergency caller can queue it. A non-emergency caller maps
                // this straight back to a hosted fall-through (Verify rung).
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
        match parse_verify_verdicts(&verify_raw, extract.entries.len()) {
            Ok(v) => v,
            Err(_) => {
                prov(false, Some(3), "unavailable", extract.entries.len(), false);
                return DietPipelineOutcome::FallThrough {
                    rung: DietRung::Verify,
                    reason: None,
                };
            }
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

    // Stage 2b — micronutrient completion. Runs AFTER the correction pass (so a
    // corrected macro is already in place and a filled cell is never re-filled) and
    // BEFORE rows are built, so a completed value flows through the normal row +
    // mirror + dashboard path. Degrade-only: with the flag off, an errored/timed-out
    // verify (which never reaches here), or an unusable completion block, the rows are
    // appended EXACTLY as the extract produced them and the reason code records why.
    let mut any_micro_malformed = false;
    let mut rows_completed = 0usize;
    if complete_micros {
        for (entry, v) in verified.iter_mut().zip(verdicts.iter()) {
            if v.completion.malformed {
                any_micro_malformed = true;
            }
            if let DietEntry::Food(f) = entry {
                if complete_food_micros(f, &v.completion) > 0 {
                    rows_completed += 1;
                }
            }
        }
        if any_micro_malformed {
            eprintln!(
                "jesse-bridge: diet verify returned an unusable micronutrient completion block — \
                 rows appended as extracted"
            );
        }
    }

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

    // The turn's nutrient-completeness accounting over the rows just appended. Emitted
    // on the provenance line and threaded to the metrics record; the audit aggregates it.
    let micros = MicroStats::compute(&food, rows_completed, complete_micros, any_micro_malformed);
    // A local success line, now carrying `micros=<filled>/<expected>` (+ the reason code
    // when anything is still blank).
    let prov_local = |rung: Option<u8>, mirror: bool| {
        eprintln!(
            "{}",
            format_diet_provenance(
                true,
                rung,
                &base_url,
                &model,
                verify_word,
                verified.len(),
                mirror,
                None,
                micros.provenance(),
            )
        );
    };

    match build_meal_log_from_food_rows(&food, &date, &local_offset()) {
        Ok(Some(meal_log)) => {
            prov_local(None, true);
            DietPipelineOutcome::Logged {
                dashboard,
                directives: Directives {
                    needs_health: None,
                    meal_log: Some(meal_log),
                },
                micros,
            }
        }
        Ok(None) => {
            // No food rows (exercise/weigh-in-only): no mirror to emit — a normal
            // local success, not a failure.
            prov_local(None, false);
            DietPipelineOutcome::Logged {
                dashboard,
                directives: Directives {
                    needs_health: None,
                    meal_log: None,
                },
                micros,
            }
        }
        Err(e) => {
            // Mirror build failed AFTER a good append+commit (rung 5): keep the CSV,
            // omit the mirror (matches today's malformed-directive fail-safe).
            eprintln!("jesse-bridge: diet mirror build failed: {e}");
            prov_local(Some(5), false);
            DietPipelineOutcome::LoggedNoMirror { dashboard, micros }
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
    fn parses_food_risk_nutrients_all_some_or_none() {
        // The seven risk nutrients are optional in exactly the same way: all present, a
        // subset present, or none at all must all parse, and an omitted one is None —
        // NEVER 0. A written 0 (no mercury in a banana, no added sugar in whole fruit)
        // is a KNOWN fact and survives as Some(0.0).
        let json = r#"{"entries":[
            {"kind":"food","name":"Sardines","meal":"Dinner","time":"19:30","kcal":190,"cholesterol_mg":142,"trans_fat_g":0.1,"added_sugar_g":0,"purines_mg":345,"mercury_ug":13,"selenium_ug":53,"vitamin_d_ug":7},
            {"kind":"food","name":"Banana","meal":"Snack","time":"10:00","kcal":105,"cholesterol_mg":0,"added_sugar_g":0,"mercury_ug":0},
            {"kind":"food","name":"Soup","meal":"Lunch","time":"12:00","kcal":220}
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
        assert_eq!(foods[0].cholesterol_mg, Some(142.0));
        assert_eq!(foods[0].trans_fat_g, Some(0.1));
        assert_eq!(foods[0].added_sugar_g, Some(0.0), "measured zero");
        assert_eq!(foods[0].purines_mg, Some(345.0));
        assert_eq!(foods[0].mercury_ug, Some(13.0));
        assert_eq!(foods[0].selenium_ug, Some(53.0));
        assert_eq!(foods[0].vitamin_d_ug, Some(7.0));
        // A subset: the KNOWN zeros are kept as zeros, the unstated ones stay None.
        assert_eq!(
            foods[1].cholesterol_mg,
            Some(0.0),
            "0 in a plant food is a fact"
        );
        assert_eq!(
            foods[1].added_sugar_g,
            Some(0.0),
            "whole fruit: 0 added sugar"
        );
        assert_eq!(foods[1].mercury_ug, Some(0.0), "non-seafood: 0 mercury");
        assert_eq!(foods[1].trans_fat_g, None);
        assert_eq!(foods[1].purines_mg, None);
        assert_eq!(foods[1].selenium_ug, None);
        assert_eq!(foods[1].vitamin_d_ug, None);
        // None present — all seven absent, none defaulted to 0.
        assert!(
            foods[2].cholesterol_mg.is_none()
                && foods[2].trans_fat_g.is_none()
                && foods[2].added_sugar_g.is_none()
                && foods[2].purines_mg.is_none()
                && foods[2].mercury_ug.is_none()
                && foods[2].selenium_ug.is_none()
                && foods[2].vitamin_d_ug.is_none()
        );
    }

    #[test]
    fn parse_rejects_negative_or_non_finite_risk_nutrient() {
        // Each risk nutrient shares the finite/non-negative discipline of the macros.
        for key in [
            "cholesterol_mg",
            "trans_fat_g",
            "added_sugar_g",
            "purines_mg",
            "mercury_ug",
            "selenium_ug",
            "vitamin_d_ug",
        ] {
            let body = format!(
                r#"{{"entries":[{{"kind":"food","name":"n","meal":"Snack","time":"09:00","{key}":-1}}]}}"#
            );
            assert!(
                parse_diet_entries(&body).is_err(),
                "a negative {key} must be rejected"
            );
            // …while an explicit 0 and a normal value both parse.
            for good in ["0", "12.5"] {
                let body = format!(
                    r#"{{"entries":[{{"kind":"food","name":"n","meal":"Snack","time":"09:00","{key}":{good}}}]}}"#
                );
                assert!(parse_diet_entries(&body).is_ok(), "{key}={good} must parse");
            }
        }
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
        };
        let csv = format!("{}\n{}\n", food_log_header(), food_row(&e, "2026-07-13"));
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
        };
        let csv = format!("{}\n{}\n", food_log_header(), food_row(&e, "2026-07-13"));
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
                unknowable_composite: false,
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
                cholesterol_mg: None,
                trans_fat_g: None,
                added_sugar_g: None,
                purines_mg: None,
                mercury_ug: None,
                selenium_ug: None,
                vitamin_d_ug: None,
                notes: None,
            }),
            DietEntry::Food(FoodEntry {
                unknowable_composite: false,
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
                cholesterol_mg: None,
                trans_fat_g: None,
                added_sugar_g: None,
                purines_mg: None,
                mercury_ug: None,
                selenium_ug: None,
                vitamin_d_ug: None,
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
            // A still-unknown nutrient-SHAPED key must still fail loudly. `added_sugar_g`
            // used to serve as the example and is now a real schema key, so the example
            // moved to `iron_mg`, which is in no table row.
            r#"{"entries":[{"kind":"food","name":"n","meal":"Snack","time":"t","iron_mg":5}]}"#,
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
        })
    }
    fn verdict(v: Verdict, kcal: Option<f64>) -> EntryVerdict {
        EntryVerdict {
            completion: MicroCompletion::default(),
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
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
    fn correction_carries_risk_nutrients_through_untouched() {
        // The verifier corrects the five macros and NOTHING else, so the seven risk
        // columns ride the `..f.clone()` spread: a known mercury survives a kcal
        // correction, a known zero stays 0, and an absent one is not invented.
        let mut f = blank_food("Swordfish");
        f.kcal = Some(120.0);
        f.mercury_ug = Some(147.0);
        f.selenium_ug = Some(48.0);
        f.cholesterol_mg = Some(66.0);
        f.added_sugar_g = Some(0.0); // a KNOWN zero
        f.trans_fat_g = None; // never sourced
        f.purines_mg = None;
        f.vitamin_d_ug = None;
        let e = DietEntry::Food(f);
        match resolve_verdict(&e, &verdict(Verdict::Correct, Some(160.0))) {
            Some(DietEntry::Food(f)) => {
                assert_eq!(f.kcal, Some(160.0), "kcal corrected");
                assert_eq!(
                    f.mercury_ug,
                    Some(147.0),
                    "known mercury carried through untouched"
                );
                assert_eq!(f.selenium_ug, Some(48.0), "known selenium untouched");
                assert_eq!(f.cholesterol_mg, Some(66.0), "known cholesterol untouched");
                assert_eq!(f.added_sugar_g, Some(0.0), "a KNOWN zero stays 0");
                assert_eq!(f.trans_fat_g, None, "absent trans fat stays absent");
                assert_eq!(f.purines_mg, None, "absent purines stay absent");
                assert_eq!(f.vitamin_d_ug, None, "absent vitamin D stays absent");
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: Some("drained, with salt".into()),
        };
        let row = food_row(&e, "2026-07-13");
        // RFC-4180: the item's comma forces quoting; the row parses back to 29 fields.
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(
            rec.len(),
            food_log_header().split(',').count(),
            "29 columns"
        );
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
    fn food_row_places_every_risk_nutrient_in_its_own_cell() {
        // The whole 29-cell row, asserted literally: a nutrient written one column off
        // corrupts the log silently, so the placement is pinned rather than counted.
        // Known zeros (mercury in a plant food) render `0`; unknowns render blank.
        let mut e = blank_food("Salmon");
        e.notes = None;
        e.fiber_g = Some(0.0);
        e.sodium_mg = Some(340.0);
        e.satfat_g = Some(0.5);
        e.sugar_g = Some(0.0);
        e.potassium_mg = Some(420.0);
        e.calcium_mg = Some(15.0);
        e.omega3_mg = Some(1400.0);
        e.magnesium_mg = Some(29.0);
        e.cholesterol_mg = Some(63.0);
        e.trans_fat_g = Some(0.0); // whole unprocessed food → a KNOWN zero
        e.added_sugar_g = Some(0.0); // ditto: nothing was added
        e.purines_mg = Some(170.0);
        e.mercury_ug = Some(2.0);
        e.selenium_ug = None; // soil variance, not sourced → stays UNKNOWN
        e.vitamin_d_ug = Some(13.1);

        let cells: Vec<&str> = "2026-08-13,Snack,Salmon,1 medium (~118g),serving,,,105,1.3,\
0.4,27,,10:40,Snack,0,340,0.5,0,420,15,1400,29,63,0,0,170,2,,13.1"
            .split(',')
            .collect();
        assert_eq!(
            food_row(&e, "2026-08-13"),
            cells.join(","),
            "every cell in header order"
        );
        assert_eq!(cells.len(), food_log_header().split(',').count());
        // Spot-check the tail against the header by NAME, so a future reorder is caught.
        let header: Vec<&str> = food_log_header().split(',').collect();
        for (name, want) in [
            ("Cholesterol_mg", "63"),
            ("TransFat_g", "0"),
            ("AddedSugar_g", "0"),
            ("Purines_mg", "170"),
            ("Mercury_ug", "2"),
            ("Selenium_ug", ""),
            ("VitaminD_ug", "13.1"),
        ] {
            let i = header
                .iter()
                .position(|h| *h == name)
                .expect("column exists");
            assert_eq!(cells[i], want, "{name} cell");
        }
    }

    #[test]
    fn blank_risk_nutrient_round_trips_to_unknown_not_zero() {
        // Write → read: an unsourced risk nutrient is a blank cell that reads back as
        // JSON null, while a KNOWN zero on the same row reads back as 0. The two must
        // never converge, which is the entire point of the column.
        let mut e = blank_food("Banana");
        e.mercury_ug = Some(0.0); // non-seafood: a known fact
        e.added_sugar_g = Some(0.0); // whole fruit: a known fact
        e.selenium_ug = None; // not sourced: unknown
        e.purines_mg = None; // not sourced: unknown
        let csv = format!("{}\n{}\n", food_log_header(), food_row(&e, "2026-08-13"));
        let (meals, errors) = crate::diet::reconstruct_meals(&csv, "2026-08-13");
        assert!(errors.is_empty(), "clean row: {errors:?}");
        let item = &meals[0]["items"][0];
        assert_eq!(item["hg"], 0.0, "a KNOWN zero survives as 0");
        assert_eq!(item["asug"], 0.0, "a KNOWN zero survives as 0");
        assert!(item["se"].is_null(), "unsourced selenium reads back null");
        assert!(item["pur"].is_null(), "unsourced purines read back null");
        for key in ["chol", "tfat", "vd"] {
            assert!(item[key].is_null(), "{key} was never set → null");
        }
    }

    #[test]
    fn food_row_blank_macros_are_empty_cells() {
        let e = FoodEntry {
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
        };
        let row = food_row(&e, "2026-07-13");
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(
            rec.len(),
            food_log_header().split(',').count(),
            "29 columns"
        );
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
            p.contains(food_log_header()),
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
        };
        assert_eq!(
            count(&food_row(&f, "2026-07-13")),
            food_log_header().split(',').count()
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
        let p =
            build_diet_extract_prompt("actually lunch was two bowls, about 700 kcal", "the user");
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
            diet_extract_schema().contains("AMENDS/corrects/moves/deletes"),
            "schema no_loggable_content description must cover amendments"
        );
        assert!(
            p.contains(diet_extract_schema()),
            "the updated schema is inlined into the prompt"
        );
    }

    // ---- Mirror builder ----------------------------------------------------

    fn f(name: &str, meal: &str, time: &str, kcal: f64) -> FoodEntry {
        FoodEntry {
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
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
            unknowable_composite: false,
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
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
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
    fn mirror_sums_the_three_healthkit_bound_risk_nutrients_over_known_rows() {
        // Off-phone logging must mirror to Health too: the three HealthKit-bound risk
        // nutrients are summed per MEAL over the rows that KNOW them (a None row
        // contributes nothing), and a nutrient no row knows produces no wire field.
        // The four with no HealthKit type never reach the wire at all.
        let mut a = blank_food("Salmon");
        a.meal = "Dinner".into();
        a.time = Some("19:30".into());
        a.cholesterol_mg = Some(63.0);
        a.selenium_ug = Some(48.0);
        a.vitamin_d_ug = Some(13.1);
        a.mercury_ug = Some(2.0); // known on the row, but no HealthKit type
        a.purines_mg = Some(170.0);
        let mut b = blank_food("Rice");
        b.meal = "Dinner".into();
        b.time = Some("19:30".into());
        b.cholesterol_mg = Some(0.0); // a plant food: a KNOWN zero, and it must count
        b.selenium_ug = Some(11.0);
        b.vitamin_d_ug = None; // unknown → contributes nothing to the sum

        let ml = build_meal_log_from_food_rows(&[a, b], "2026-08-13", "+02:00")
            .unwrap()
            .unwrap();
        assert_eq!(ml.meals.len(), 1, "same slot + time → one mirror meal");
        let m = &ml.meals[0];
        assert_eq!(m.cholesterol_mg, Some(63.0), "63 + a known 0");
        assert_eq!(m.selenium_ug, Some(59.0), "48 + 11");
        assert_eq!(
            m.vitamin_d_ug,
            Some(13.1),
            "the unknown row contributes nothing, it does not zero the sum"
        );

        let v = directives_to_value(&Some(Directives {
            needs_health: None,
            meal_log: Some(ml),
        }));
        let meal = &v["meal_log"]["meals"][0];
        assert_eq!(meal["cholesterol_mg"], 63.0);
        assert_eq!(meal["selenium_ug"], 59.0);
        assert_eq!(meal["vitamin_d_ug"], 13.1);
        for key in ["trans_fat_g", "added_sugar_g", "purines_mg", "mercury_ug"] {
            assert!(
                meal.get(key).is_none(),
                "{key} has no HealthKit type → never a wire field"
            );
        }

        // A meal whose rows know NONE of the three omits all three keys — never a 0.
        let bare = build_meal_log_from_food_rows(&[blank_food("Water")], "2026-08-13", "+02:00")
            .unwrap()
            .unwrap();
        let m = &bare.meals[0];
        assert!(m.cholesterol_mg.is_none() && m.selenium_ug.is_none() && m.vitamin_d_ug.is_none());
        let v = directives_to_value(&Some(Directives {
            needs_health: None,
            meal_log: Some(bare),
        }));
        for key in ["cholesterol_mg", "selenium_ug", "vitamin_d_ug"] {
            assert!(
                v["meal_log"]["meals"][0].get(key).is_none(),
                "no known {key} → no wire field (never 0)"
            );
        }
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
            "{}\n\
             2026-07-13,Breakfast,Eggs,3,ea,,,210,18,15,1,,08:00,Breakfast,0\n\
             2026-07-13,Dinner,Rice,150,g,130,150,,3,0,28,,19:00,Dinner,\n\
             2026-07-12,Snack,Banana,1,ea,,,105,1,0,27,,10:00,Snack,3\n",
            food_log_header()
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
            "{}\n\
             2026-07-13,Breakfast,Eggs,3,ea,,,210,10,15,1,,08:00,Breakfast,0\n\
             2026-07-13,Snack,Banana,1,ea,,,105,10,0,27,,10:00,Snack,3\n",
            food_log_header()
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
        // Words-first, single-meaning: a neutral progress bar, never pass/fail color emoji.
        assert!(
            dash.contains('█') && !dash.contains("🟩") && !dash.contains("🟥"),
            "bars are monochrome, no color emoji: {dash}"
        );
        // Calories comfortably under the ceiling reads as room, not a grade.
        assert!(
            dash.contains("room for"),
            "calorie headroom framed kindly: {dash}"
        );
        // Floors far short read as "to go" — kind and action-first, never "need X".
        assert!(
            dash.contains("to go") && !dash.contains("need "),
            "floor shortfall is action-first: {dash}"
        );
        // A leading plain summary answers "how am I doing / what would help next".
        assert!(
            dash.contains("Coming together") || dash.contains("on track"),
            "a plain summary leads the dashboard: {dash}"
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
        std::fs::write(dir.join("food-log.csv"), format!("{}\n", food_log_header())).unwrap();
        let snap = append_rows_atomic(&dir, &["row-a".into(), "row-b".into()], &[], &[]).unwrap();
        let content = std::fs::read_to_string(dir.join("food-log.csv")).unwrap();
        assert_eq!(content, format!("{}\nrow-a\nrow-b\n", food_log_header()));
        // Rollback restores the pre-append content exactly.
        snap.rollback();
        assert_eq!(
            std::fs::read_to_string(dir.join("food-log.csv")).unwrap(),
            format!("{}\n", food_log_header())
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
            format_diet_provenance(true, None, "http://u", "m", "approved", 2, true, None, None),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=approved; rows=2 mirror=derived"
        );
        assert_eq!(
            format_diet_provenance(false, Some(3), "http://u", "m", "rejected", 1, false, None, None),
            "jesse-bridge: diet turn -> hosted-fallback rung=3 extract base_url=http://u model=m; verify verdict=rejected; rows=1 mirror=omitted"
        );
        // Rung 5: logged locally, mirror omitted.
        assert_eq!(
            format_diet_provenance(true, Some(5), "http://u", "m", "corrected", 11, false, None, None),
            "jesse-bridge: diet turn -> local extract base_url=http://u model=m; verify verdict=corrected; rows=11 mirror=omitted"
        );
        // Never prints a token.
        let line =
            format_diet_provenance(true, None, "http://u", "m", "approved", 1, true, None, None);
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
            None,
        );
        assert!(
            line.contains("reason=schema_fail:time"),
            "rung-2 provenance must carry the reason code: {line}"
        );
        assert!(!line.contains("token"), "still never carries a token");
        // A local success (no reason) is unchanged — no `reason=` fragment.
        let ok =
            format_diet_provenance(true, None, "http://u", "m", "approved", 1, true, None, None);
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

    // ---- The nutrient table drives header / schema / prompt / row / mirror -----

    /// A bare food entry with every nutrient blank — the starting point for the
    /// completion tests.
    fn blank_food(name: &str) -> FoodEntry {
        FoodEntry {
            name: name.into(),
            meal: "Snack".into(),
            time: Some("10:40".into()),
            amount: Some("1 medium (~118g)".into()),
            unit: Some("serving".into()),
            kcal: Some(105.0),
            protein_g: Some(1.3),
            carbs_g: Some(27.0),
            fat_g: Some(0.4),
            fiber_g: None,
            sodium_mg: None,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            omega3_mg: None,
            magnesium_mg: None,
            cholesterol_mg: None,
            trans_fat_g: None,
            added_sugar_g: None,
            purines_mg: None,
            mercury_ug: None,
            selenium_ug: None,
            vitamin_d_ug: None,
            notes: None,
            unknowable_composite: false,
        }
    }

    /// A completion carrying every EXPECTED nutrient (plausible banana values).
    fn banana_completion() -> MicroCompletion {
        let mut values = std::collections::BTreeMap::new();
        for (k, v) in [
            ("fiber_g", 3.1),
            ("sodium_mg", 1.0),
            ("satfat_g", 0.1),
            ("sugar_g", 14.4),
            ("potassium_mg", 422.0),
            ("calcium_mg", 6.0),
            ("magnesium_mg", 32.0),
        ] {
            values.insert(k.to_string(), v);
        }
        MicroCompletion {
            values,
            basis: Some("USDA SR Legacy 09040 banana raw, scaled to 118 g edible".into()),
            malformed: false,
        }
    }

    #[test]
    fn header_is_the_29_canonical_columns_in_table_order() {
        // The canonical contract, spelled out ONCE here so a reordering or rename in
        // the table is caught by a failing test rather than by a corrupted log.
        assert_eq!(
            food_log_header(),
            "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,\
Carbs_g,Notes,Time,Meal_Type,Fiber_g,Sodium_mg,SatFat_g,Sugar_g,Potassium_mg,\
Calcium_mg,Omega3_mg,Magnesium_mg,Cholesterol_mg,TransFat_g,AddedSugar_g,Purines_mg,\
Mercury_ug,Selenium_ug,VitaminD_ug"
        );
        assert_eq!(food_log_header().split(',').count(), 29, "29 columns");
        // The header and the row builder MUST agree on the count, or every appended row
        // is silently off by a column.
        assert_eq!(
            food_row(&blank_food("Banana"), "2026-08-13")
                .split(',')
                .count(),
            food_log_header().split(',').count(),
            "row builder and header agree at 29 cells"
        );
    }

    #[test]
    fn nutrient_table_and_extract_schema_agree_both_ways() {
        // Every table entry is accepted by the food-key validator...
        for c in NUTRIENT_COLUMNS {
            assert!(
                is_food_key(c.key),
                "table nutrient {:?} must be an accepted schema key",
                c.key
            );
            // ...and appears in the schema text the child is shown.
            assert!(
                diet_extract_schema().contains(&format!("\"{}\"", c.key)),
                "schema must name {:?}",
                c.key
            );
        }
        // ...and no nutrient key the schema text names is missing from the table: pull
        // the food line's keys back out and check every nutrient-ish one resolves.
        let food_line = diet_extract_schema()
            .lines()
            .find(|l| l.contains("\"kind\": \"food\""))
            .expect("schema carries a food line");
        for key in food_line
            .split('"')
            .filter(|t| t.ends_with("_g") || t.ends_with("_mg") || t.ends_with("_ug"))
        {
            let known = NUTRIENT_COLUMNS.iter().any(|c| c.key == key)
                || ["protein_g", "carbs_g", "fat_g"].contains(&key);
            assert!(known, "schema key {key:?} resolves to no table entry");
        }
        // The unit is stated for every nutrient, so the child cannot mix g, mg and ug.
        for c in NUTRIENT_COLUMNS {
            assert!(
                matches!(c.unit, "g" | "mg" | "ug"),
                "nutrient {:?} needs a real unit",
                c.key
            );
            // A key's suffix must match its unit — the mistake that would silently log
            // micrograms of vitamin D as milligrams.
            assert!(
                c.key.ends_with(&format!("_{}", c.unit)),
                "nutrient key {:?} must end in its unit {:?}",
                c.key,
                c.unit
            );
        }
    }

    #[test]
    fn generated_prompt_names_every_expected_nutrient_column() {
        let p = build_diet_extract_prompt("ate a banana", "the user");
        for c in NUTRIENT_COLUMNS.iter().filter(|c| c.expected()) {
            assert!(
                p.contains(c.key),
                "extract prompt must name expected nutrient {:?}",
                c.key
            );
            assert!(
                p.contains(c.csv),
                "prompt's inlined header must carry column {:?}",
                c.csv
            );
        }
    }

    #[test]
    fn food_row_emits_29_cells_with_nutrients_in_table_order() {
        // Give each nutrient a DISTINCT value, then assert cell N+14 is the table's
        // N-th nutrient — the row builder's order is the table's order, not a
        // hand-written sequence.
        let mut e = blank_food("Marker");
        for (i, c) in NUTRIENT_COLUMNS.iter().enumerate() {
            c.set(&mut e, Some((i + 1) as f64));
        }
        let row = food_row(&e, "2026-07-25");
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(rec.len(), 29, "29 cells");
        for (i, c) in NUTRIENT_COLUMNS.iter().enumerate() {
            assert_eq!(
                &rec[14 + i],
                &format!("{}", i + 1),
                "cell {} must be {:?}",
                14 + i,
                c.csv
            );
        }
    }

    #[test]
    fn synthetic_nutrient_flows_through_header_schema_and_prompt() {
        // The anti-hardcoding proof: ONE more table entry changes the header, the schema
        // AND the prompt together. Nothing downstream carries its own copy of the list.
        // The synthetic column must name a nutrient the real table does NOT carry, or it
        // would prove nothing about derivation.
        let synthetic = NutrientCol {
            csv: "Iodine_ug",
            key: "iodine_ug",
            wire: Some("iodine_ug"),
            app_key: "iod",
            unit: "ug",
            fill: FillClass::ExpectedWhenKnowable,
            guidance: None,
            // Accessors are irrelevant to the generated TEXT; reuse fiber's.
            getter: |f| f.fiber_g,
            setter: |f, v| f.fiber_g = v,
            wire_setter: Some(|m, v| m.fiber_g = v),
        };
        assert!(
            !NUTRIENT_COLUMNS.iter().any(|c| c.key == synthetic.key),
            "the synthetic nutrient must not be a real one"
        );
        let mut cols: Vec<NutrientCol> = NUTRIENT_COLUMNS.to_vec();
        cols.push(synthetic);

        let header = build_food_log_header(&cols);
        assert_eq!(
            header.split(',').count(),
            30,
            "one more nutrient extends the 29-column header"
        );
        assert!(
            header.ends_with(",Iodine_ug"),
            "appended in table order: {header}"
        );

        let schema = build_extract_schema(&cols);
        assert!(
            schema.contains("\"iodine_ug\": <number, ug>"),
            "schema gains the new key with its unit: {schema}"
        );

        let rules = build_nutrient_rules(&cols);
        assert!(
            rules.contains("`iodine_ug` (ug)"),
            "the prompt's EXPECTED list gains it: {rules}"
        );

        // A synthetic column with its OWN guidance renders its own bullet.
        let mut with_guidance = synthetic;
        with_guidance.guidance = Some("a synthetic bullet nobody else states.");
        let mut cols2: Vec<NutrientCol> = NUTRIENT_COLUMNS.to_vec();
        cols2.push(with_guidance);
        assert!(
            build_nutrient_rules(&cols2)
                .contains("- `iodine_ug` (ug) is a synthetic bullet nobody else states."),
            "per-nutrient guidance is rendered from the table, not hardcoded"
        );

        // And the production table is untouched by the test's local copy.
        assert_eq!(food_log_header().split(',').count(), 29);
    }

    // ---- Phase 2: the extract prompt now INSTRUCTS filling, not omission -----

    #[test]
    fn extract_prompt_states_the_risk_nutrient_rules() {
        // The risk columns are only as good as the guidance the child gets: the
        // estimate-or-omit rule for the class, and — for each — where the value comes
        // from and when a `0` is a KNOWN fact rather than a placeholder for unknown.
        let p = build_diet_extract_prompt("ate a tin of sardines", "the user");
        for fragment in [
            // The class rule.
            "ESTIMATE THESE, or omit them",
            "it is not a placeholder for \"I don't know\"",
            // Added sugar: free sugars only, 0 for whole food, juice counts.
            "FREE/ADDED sugars only",
            "never the intrinsic sugar in whole fruit",
            "a banana has 0 added sugar",
            "Juice, concentrate, honey and syrup COUNT as added",
            // Trans fat: 0 for whole plants, ruminant amounts, estimate on PHO.
            "Write 0 for whole unprocessed plant foods",
            "Ruminant dairy and beef carry small natural amounts",
            "partially hydrogenated oil, ESTIMATE rather than omitting",
            // Purines: class-based, scaled, near 0 for the light classes.
            "CLASS-BASED estimate from published purine tables",
            "Near 0 for fruit, dairy, eggs and refined grains",
            // Mercury: FDA means by species, 0 for non-seafood, no generic guess.
            "FDA mean for the NAMED species",
            "Write 0 for any non-seafood",
            "Do NOT guess for an unnamed generic \"fish\": OMIT the key instead",
            // Selenium: the Brazil-nut extreme and soil variance.
            "Brazil nuts are the extreme — about 68-91 ug in ONE nut",
            "ORDER OF MAGNITUDE",
            // Vitamin D: micrograms, IU ÷ 40.
            "vitamin D in MICROGRAMS, never IU",
            "DIVIDED BY 40 (400 IU = 10 ug)",
            // Cholesterol: 0 for plants.
            "Write 0 for ALL plant foods",
            // Everything is scaled to what was logged.
            "scaled to the amount logged",
            "scaled to the grams logged",
        ] {
            assert!(
                p.contains(fragment),
                "extract prompt must state: {fragment}"
            );
        }
        // The seven keys and their columns are both in the prompt (schema + header).
        for c in NUTRIENT_COLUMNS
            .iter()
            .filter(|c| c.fill == FillClass::EstimatedRisk)
        {
            assert!(p.contains(c.key), "prompt must name {:?}", c.key);
            assert!(p.contains(c.csv), "inlined header must carry {:?}", c.csv);
            assert!(
                c.guidance.is_some(),
                "every risk nutrient owns a guidance bullet: {:?}",
                c.key
            );
        }
    }

    #[test]
    fn extract_prompt_states_every_nutrient_branch() {
        let p = build_diet_extract_prompt("ate a banana", "the user");
        for fragment in [
            // Packaged food with a panel.
            "PACKAGED FOOD WITH A NUTRITION PANEL IN THE MESSAGE",
            "sodium_mg = salt_grams × 400",
            "TOTAL sugars",
            "saturated-fat line",
            // Label-less whole food.
            "LABEL-LESS WHOLE FOOD",
            "standard food-composition",
            "EDIBLE grams logged",
            "Exclude pit, peel, core, shell and bone",
            "Do NOT leave a column blank because no label printed it",
            // Marine omega-3.
            "marine long-chain omega-3 (EPA+DHA) ONLY",
            "NEVER the plant ALA in walnuts, flax, chia or vegetable oils",
            // Sodium scope.
            "intrinsic sodium, plus label salt, plus restaurant",
            "probably salted it",
            // Unidentifiable composite.
            "A COMPOSITE YOU CANNOT IDENTIFY",
            "\"unknowable_composite\": true",
            // Zero discipline.
            "NEVER write 0 to mean",
        ] {
            assert!(
                p.contains(fragment),
                "extract prompt must state: {fragment}"
            );
        }
    }

    #[test]
    fn extract_prompt_no_longer_instructs_omission_of_knowable_nutrients() {
        // The defect, asserted gone: the old contract said a nutrient came only from a
        // label "or a confident estimate" and that potassium/calcium/magnesium are
        // "usually absent" from labels so "usually omitted". The child obeyed.
        //
        // This guard is about the EXPECTED micros. The EstimatedRisk columns state their
        // own estimate-or-omit rule in their own words ("ESTIMATE THESE, or omit them"),
        // which is correct for nutrients no label prints — it must not be reworded back
        // into the phrases below.
        let p = build_diet_extract_prompt("ate a banana", "the user");
        for gone in [
            "usually absent",
            "usually omitted",
            "or a confident estimate",
            "otherwise OMIT the key entirely",
        ] {
            assert!(
                !p.contains(gone),
                "the omission instruction must be gone, still found: {gone}"
            );
        }
    }

    #[test]
    fn unknowable_composite_parses_and_defaults_false() {
        let json = r#"{"entries":[
          {"kind":"food","name":"House sauce","meal":"Dinner","kcal":90,"unknowable_composite":true},
          {"kind":"food","name":"Banana","meal":"Snack","kcal":105}
        ]}"#;
        let ex = parse_diet_entries(json).expect("parses");
        match (&ex.entries[0], &ex.entries[1]) {
            (DietEntry::Food(a), DietEntry::Food(b)) => {
                assert!(a.unknowable_composite, "explicit true is carried");
                assert!(!b.unknowable_composite, "absent → false, never unknown");
            }
            other => panic!("expected two food entries, got {other:?}"),
        }
        // A non-boolean is a schema violation (no string "true").
        assert!(
            parse_diet_entries(
                r#"{"entries":[{"kind":"food","name":"X","meal":"Snack","unknowable_composite":"yes"}]}"#
            )
            .is_err(),
            "a non-boolean flag must reject"
        );
    }

    // ---- Phase 3: verify-side completion contract ----------------------------

    #[test]
    fn verify_prompt_carries_the_completion_contract_only_when_enabled() {
        let on = build_diet_verify_prompt("ate a banana", "{}", "the user", true);
        assert!(on.contains("ALSO COMPLETE THE NUTRIENTS"));
        assert!(on.contains("\"micros\""), "schema gains the micros object");
        assert!(on.contains("reference_basis"));
        assert!(
            on.contains("NEVER send 0 to mean"),
            "the zero discipline is restated to the verifier"
        );
        for c in NUTRIENT_COLUMNS.iter().filter(|c| c.expected()) {
            assert!(on.contains(c.key), "completion must name {:?}", c.key);
        }
        assert!(
            !on.contains("`omega3_mg` (mg),"),
            "marine-only omega-3 is not in the EXPECTED completion list"
        );

        let off = build_diet_verify_prompt("ate a banana", "{}", "the user", false);
        assert!(
            !off.contains("ALSO COMPLETE THE NUTRIENTS") && !off.contains("reference_basis"),
            "with completion off the verify prompt is the macro-verdict prompt"
        );
        // The macro half is identical either way.
        assert!(on.contains("TOLERANCE:") && off.contains("TOLERANCE:"));
    }

    #[test]
    fn candidates_json_sends_known_nutrients_and_omits_blank_ones() {
        let mut f = blank_food("Salmon");
        f.sodium_mg = Some(340.0);
        f.omega3_mg = Some(1400.0);
        let json = entries_to_json(&[DietEntry::Food(f)]);
        assert!(
            json.contains("\"sodium_mg\":340"),
            "known nutrient rides: {json}"
        );
        assert!(json.contains("\"omega3_mg\":1400"));
        for blank in ["potassium_mg", "calcium_mg", "magnesium_mg", "fiber_g"] {
            assert!(
                !json.contains(blank),
                "a BLANK nutrient must be omitted (that is the completion input): {blank}"
            );
        }
    }

    #[test]
    fn verdict_parses_a_completion_block_and_tolerates_its_absence() {
        // Old shape (no micros): parses exactly as before, completing nothing.
        let old = parse_verify_verdicts(r#"{"verdicts":[{"verdict":"approve"}]}"#, 1).unwrap();
        assert!(old[0].completion.is_empty() && !old[0].completion.malformed);

        let with = parse_verify_verdicts(
            r#"{"verdicts":[{"verdict":"approve","micros":{"fiber_g":3.1,"potassium_mg":422},
                "reference_basis":"USDA banana raw, scaled to 118 g"}]}"#,
            1,
        )
        .unwrap();
        assert_eq!(with[0].completion.values.get("fiber_g"), Some(&3.1));
        assert_eq!(with[0].completion.values.get("potassium_mg"), Some(&422.0));
        assert!(with[0]
            .completion
            .basis
            .as_deref()
            .unwrap()
            .starts_with("USDA"));
        assert!(!with[0].completion.malformed);

        // A null/blank value is the verifier DECLINING — normal, not malformed.
        let declined = parse_verify_verdicts(
            r#"{"verdicts":[{"verdict":"approve","micros":{"fiber_g":null,"sugar_g":""}}]}"#,
            1,
        )
        .unwrap();
        assert!(declined[0].completion.values.is_empty());
        assert!(
            !declined[0].completion.malformed,
            "a decline is not malformed"
        );
    }

    #[test]
    fn unusable_completion_block_is_dropped_whole_and_flagged() {
        for bad in [
            r#"{"verdicts":[{"verdict":"approve","micros":"lots"}]}"#,
            r#"{"verdicts":[{"verdict":"approve","micros":{"fiber_g":3,"sodium_mg":-5}}]}"#,
            r#"{"verdicts":[{"verdict":"approve","micros":{"fiber_g":"three"}}]}"#,
        ] {
            let v = parse_verify_verdicts(bad, 1).expect("the VERDICT still parses");
            assert!(v[0].completion.malformed, "must be flagged: {bad}");
            assert!(
                v[0].completion.values.is_empty(),
                "no partial trust in an unusable block: {bad}"
            );
        }
    }

    // ---- Phase 3: the merge rules -------------------------------------------

    #[test]
    fn completion_fills_only_blank_cells_and_a_label_always_wins() {
        let mut e = blank_food("Banana");
        e.sugar_g = Some(12.0); // came off a label
        let filled = complete_food_micros(&mut e, &banana_completion());
        assert_eq!(
            e.sugar_g,
            Some(12.0),
            "the label value is NEVER overwritten"
        );
        assert_eq!(e.fiber_g, Some(3.1), "a blank cell is filled");
        assert_eq!(e.potassium_mg, Some(422.0));
        assert_eq!(e.calcium_mg, Some(6.0));
        assert_eq!(e.magnesium_mg, Some(32.0));
        assert_eq!(filled, 6, "six blanks filled, sugar left alone");
        assert!(missing_expected_nutrients(&e).is_empty(), "row is complete");
    }

    #[test]
    fn a_declined_nutrient_stays_blank_and_is_never_zero() {
        let mut e = blank_food("Banana");
        let mut c = banana_completion();
        c.values.remove("potassium_mg");
        c.values.remove("magnesium_mg");
        complete_food_micros(&mut e, &c);
        assert_eq!(e.potassium_mg, None, "declined → blank, NOT Some(0.0)");
        assert_eq!(e.magnesium_mg, None);
        assert_eq!(
            missing_expected_nutrients(&e),
            vec!["Potassium_mg", "Magnesium_mg"],
            "and it is REPORTED as missing"
        );
        // The blank reaches the CSV as an empty cell, never a 0.
        let row = food_row(&e, "2026-07-25");
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(&rec[18], "", "Potassium_mg blank, not 0");
        assert_eq!(&rec[21], "", "Magnesium_mg blank, not 0");
    }

    #[test]
    fn an_explicit_zero_from_the_verifier_is_a_measured_zero() {
        // Plain meat really has 0 fiber and 0 sugar; the honest value is 0, and the
        // prompt tells the verifier to omit rather than send 0 when it does not know.
        let mut e = blank_food("Chicken breast");
        let mut c = MicroCompletion::default();
        c.values.insert("fiber_g".into(), 0.0);
        c.values.insert("sugar_g".into(), 0.0);
        let filled = complete_food_micros(&mut e, &c);
        assert_eq!((e.fiber_g, e.sugar_g), (Some(0.0), Some(0.0)));
        assert_eq!(filled, 2);
    }

    #[test]
    fn completion_never_fills_the_marine_only_nutrient() {
        let mut e = blank_food("Walnuts");
        let mut c = banana_completion();
        c.values.insert("omega3_mg".into(), 2500.0); // plant ALA mistake
        complete_food_micros(&mut e, &c);
        assert_eq!(
            e.omega3_mg, None,
            "MarineOnly is never completed — a blank there is the correct state"
        );
        // ...and a blank omega-3 is not counted as incomplete.
        assert!(missing_expected_nutrients(&e).is_empty());
    }

    #[test]
    fn completion_and_completeness_ignore_the_risk_nutrients() {
        // The seven risk columns are EstimatedRisk, not ExpectedWhenKnowable: the local
        // extract fills them from its own guidance, and the hosted completion pass is
        // deliberately left as it was — it neither fills them nor counts a blank one as
        // incomplete, so the probation completeness figure keeps its old denominator.
        let mut e = blank_food("Banana");
        let mut c = banana_completion();
        for key in [
            "cholesterol_mg",
            "trans_fat_g",
            "added_sugar_g",
            "purines_mg",
            "mercury_ug",
            "selenium_ug",
            "vitamin_d_ug",
        ] {
            c.values.insert(key.into(), 1.0);
        }
        let filled = complete_food_micros(&mut e, &c);
        assert_eq!(
            filled,
            expected_nutrient_count(),
            "only the EXPECTED columns are completed"
        );
        assert!(
            NUTRIENT_COLUMNS
                .iter()
                .filter(|c| c.fill == FillClass::EstimatedRisk)
                .all(|c| c.get(&e).is_none()),
            "a value volunteered for a risk column is ignored, not written"
        );
        assert!(
            missing_expected_nutrients(&e).is_empty(),
            "blank risk columns are not incomplete data"
        );
        let (filled, expected) = nutrient_completeness(std::slice::from_ref(&e));
        assert_eq!((filled, expected), (7, 7), "the denominator is unchanged");
    }

    #[test]
    fn an_unknowable_composite_row_is_skipped_entirely() {
        let mut e = blank_food("House sauce");
        e.unknowable_composite = true;
        let filled = complete_food_micros(&mut e, &banana_completion());
        assert_eq!(filled, 0, "nothing is filled");
        assert_eq!(e.fiber_g, None);
        assert_eq!(e.notes, None, "and its Notes are untouched");
        assert!(
            missing_expected_nutrients(&e).is_empty(),
            "a composite is not counted as incomplete data"
        );
    }

    #[test]
    fn the_reference_basis_lands_in_notes_only_when_notes_is_empty() {
        // Empty Notes → the basis is written.
        let mut e = blank_food("Banana");
        complete_food_micros(&mut e, &banana_completion());
        assert_eq!(
            e.notes.as_deref(),
            Some("USDA SR Legacy 09040 banana raw, scaled to 118 g edible")
        );

        // Existing note text → never overwritten, even though cells were filled.
        let mut e2 = blank_food("Banana");
        e2.notes = Some("with peanut butter".into());
        let filled = complete_food_micros(&mut e2, &banana_completion());
        assert!(filled > 0, "cells were still completed");
        assert_eq!(e2.notes.as_deref(), Some("with peanut butter"));

        // Nothing filled (verifier declined everything) → nothing appended to Notes.
        let mut e3 = blank_food("Banana");
        e3.fiber_g = Some(3.0);
        e3.sodium_mg = Some(1.0);
        e3.satfat_g = Some(0.1);
        e3.sugar_g = Some(14.0);
        e3.potassium_mg = Some(422.0);
        e3.calcium_mg = Some(6.0);
        e3.magnesium_mg = Some(32.0);
        let c = MicroCompletion {
            values: std::collections::BTreeMap::new(),
            basis: Some("USDA something".into()),
            malformed: false,
        };
        assert_eq!(complete_food_micros(&mut e3, &c), 0);
        assert_eq!(e3.notes, None, "an uncompleted row gets no note");
    }

    #[test]
    fn completion_never_changes_identity_amount_time_or_a_core_macro() {
        let before = blank_food("Banana");
        let mut after = before.clone();
        // A completion that ALSO tries to move the identity fields cannot: they are not
        // reachable from the merge (only nutrient keys are honored).
        let mut c = banana_completion();
        c.values.insert("kcal".into(), 999.0);
        c.values.insert("protein_g".into(), 99.0);
        c.values.insert("carbs_g".into(), 99.0);
        c.values.insert("fat_g".into(), 99.0);
        complete_food_micros(&mut after, &c);
        assert_eq!(after.name, before.name);
        assert_eq!(after.meal, before.meal);
        assert_eq!(after.time, before.time);
        assert_eq!(after.amount, before.amount);
        assert_eq!(after.unit, before.unit);
        assert_eq!(after.kcal, before.kcal, "kcal untouched");
        assert_eq!(after.protein_g, before.protein_g);
        assert_eq!(after.carbs_g, before.carbs_g);
        assert_eq!(after.fat_g, before.fat_g);
    }

    #[test]
    fn a_malformed_completion_appends_the_rows_unchanged() {
        // The degrade path: an unusable block completes nothing, so the row is written
        // exactly as the extract produced it (and the turn is reported incomplete).
        let extracted = blank_food("Banana");
        let mut row = extracted.clone();
        let v = parse_verify_verdicts(
            r#"{"verdicts":[{"verdict":"approve","micros":{"fiber_g":"three"}}]}"#,
            1,
        )
        .unwrap();
        complete_food_micros(&mut row, &v[0].completion);
        assert_eq!(row, extracted, "byte-for-byte the extracted entry");
        let stats = MicroStats::compute(&[row], 0, true, v[0].completion.malformed);
        assert_eq!(stats.filled, 0);
        assert_eq!(stats.expected, 7);
        assert_eq!(stats.reason, Some(MicroReason::Unparseable));
        assert_eq!(stats.reason.unwrap().code(), "micro_complete_unparseable");
    }

    // ---- Phase 4: completeness accounting + provenance ----------------------

    #[test]
    fn completeness_counts_only_eligible_rows_and_reports_a_reason() {
        let mut complete = blank_food("Banana");
        complete_food_micros(&mut complete, &banana_completion());
        let mut partial = blank_food("Soup");
        let mut c = banana_completion();
        c.values.remove("calcium_mg");
        complete_food_micros(&mut partial, &c);
        let mut composite = blank_food("House sauce");
        composite.unknowable_composite = true;

        let rows = vec![complete, partial, composite];
        let stats = MicroStats::compute(&rows, 2, true, false);
        assert_eq!(stats.food_rows, 3);
        assert_eq!(stats.eligible_rows, 2, "the composite is excluded");
        assert_eq!(stats.expected, 14, "2 eligible rows × 7 expected columns");
        assert_eq!(stats.filled, 13);
        assert_eq!(stats.rows_completed, 2);
        assert_eq!(stats.rows_incomplete, 1);
        assert_eq!(stats.reason, Some(MicroReason::Incomplete));
        assert_eq!(
            stats.provenance(),
            Some((13, 14, Some(MicroReason::Incomplete)))
        );

        // A fully complete turn carries NO reason code.
        let mut all = blank_food("Banana");
        complete_food_micros(&mut all, &banana_completion());
        let clean = MicroStats::compute(&[all], 1, true, false);
        assert_eq!(clean.reason, None);
        assert_eq!(clean.provenance(), Some((7, 7, None)));

        // Completion disabled explains the blanks differently.
        let off = MicroStats::compute(&[blank_food("Banana")], 0, false, false);
        assert_eq!(off.reason, Some(MicroReason::Disabled));
        assert_eq!(off.reason.unwrap().code(), "micro_complete_off");

        // No eligible rows (exercise/weigh-in only, or an all-composite turn) → nothing
        // to report on the provenance line.
        let none = MicroStats::compute(&[], 0, true, false);
        assert_eq!(none.provenance(), None);
        assert_eq!(none.reason, None);
    }

    #[test]
    fn provenance_carries_completeness_and_stays_content_free() {
        let line = format_diet_provenance(
            true,
            None,
            "http://u",
            "m",
            "approved",
            2,
            true,
            None,
            Some((13, 14, Some(MicroReason::Incomplete))),
        );
        assert!(
            line.contains("micros=13/14"),
            "filled over expected: {line}"
        );
        assert!(line.contains("micro_reason=micros_incomplete"), "{line}");
        for forbidden in ["banana", "Banana", "token", "sk-"] {
            assert!(!line.contains(forbidden), "no meal text / token: {line}");
        }
        // A complete turn shows the figure with no reason fragment.
        let clean = format_diet_provenance(
            true,
            None,
            "http://u",
            "m",
            "approved",
            1,
            true,
            None,
            Some((7, 7, None)),
        );
        assert!(clean.contains("micros=7/7") && !clean.contains("micro_reason="));
        // A fall-through line omits the figure entirely (nothing was appended).
        let fell = format_diet_provenance(
            false,
            Some(3),
            "http://u",
            "m",
            "rejected",
            0,
            false,
            None,
            None,
        );
        assert!(!fell.contains("micros="), "{fell}");
    }

    #[test]
    fn a_reference_basis_is_squeezed_into_one_safe_csv_line() {
        // A multi-line / CR-carrying basis must not smuggle a bare CR into the CSV —
        // that is exactly the defect that broke the food log's header once.
        let mut e = blank_food("Banana");
        let mut c = banana_completion();
        c.basis = Some("USDA SR Legacy\r\n09040 banana raw,\r scaled to 118 g".into());
        complete_food_micros(&mut e, &c);
        let notes = e.notes.clone().unwrap();
        assert!(
            !notes.contains('\r') && !notes.contains('\n'),
            "one line: {notes:?}"
        );
        assert_eq!(notes, "USDA SR Legacy 09040 banana raw, scaled to 118 g");
        // The comma still forces RFC-4180 quoting, and the row keeps 29 fields.
        let row = food_row(&e, "2026-07-25");
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(false)
            .from_reader(row.as_bytes());
        let rec = rdr.records().next().unwrap().unwrap();
        assert_eq!(rec.len(), 29);
        assert_eq!(&rec[11], &notes, "Notes cell round-trips intact");
    }

    #[test]
    fn unknown_stays_unknown_end_to_end_including_the_derived_mirror() {
        // The round trip: a nutrient the verifier declined must read back as UNKNOWN at
        // every layer — blank CSV cell, JSON null in the read path, omitted meal-wire key
        // — and never as 0.
        let mut e = blank_food("Banana");
        let mut c = banana_completion();
        c.values.remove("potassium_mg");
        c.values.remove("calcium_mg");
        complete_food_micros(&mut e, &c);

        let csv = format!("{}\n{}\n", food_log_header(), food_row(&e, "2026-07-25"));
        // Read path (GET /jesse/diet): declined → null, filled → the number, never 0.
        let (meals, errs) = crate::diet::reconstruct_meals(&csv, "2026-07-25");
        assert!(errs.is_empty(), "{errs:?}");
        let item = &meals[0]["items"][0];
        assert!(item["k"].is_null(), "declined potassium reads null, not 0");
        assert!(item["ca"].is_null(), "declined calcium reads null, not 0");
        assert_eq!(item["mg"], 32.0, "a completed value reads back");
        assert!(item["o3"].is_null(), "marine-only, never completed → null");

        // Derived mirror: the declined nutrients are OMITTED from the wire.
        let log = build_meal_log_from_food_rows(&[e], "2026-07-25", "+02:00")
            .unwrap()
            .unwrap();
        let wire = serde_json::to_value(&log.meals[0]).unwrap();
        assert!(
            wire.get("potassium_mg").is_none(),
            "omitted, never 0: {wire}"
        );
        assert!(wire.get("calcium_mg").is_none());
        assert_eq!(wire["magnesium_mg"], 32.0);
        assert!(
            wire.get("omega3_mg").is_none(),
            "omega-3 has no HealthKit type and never rides the wire"
        );
        // Every wire nutrient key present comes from the table.
        for c in NUTRIENT_COLUMNS {
            match c.wire {
                None => assert!(wire.get(c.key).is_none()),
                Some(k) => assert!(
                    NUTRIENT_COLUMNS.iter().any(|t| t.wire == Some(k)),
                    "wire key {k} must be table-owned"
                ),
            }
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
