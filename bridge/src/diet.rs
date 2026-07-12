//! `GET /jesse/diet` — read the vault's generated diet data files and return one
//! normalized JSON snapshot the app's Health tab renders natively.
//!
//! The vault agent regenerates these files (`diet-today.js` on every log; the
//! others each morning and on weigh-ins); the bridge only READS them. The three
//! `.js` files are data-only JS literals of the form
//!
//! ```text
//! // one or more leading comment lines
//! window.DIET_TODAY = { … };
//! ```
//!
//! — not strict JSON (unquoted keys, single quotes, trailing commas, embedded
//! HTML in strings), so [`extract_js_literal`] strips the comment lines and the
//! `window.X =` / `;` wrapper and hands the literal to `json5`. `weight-log.csv`
//! is RFC 4180 with quoted commas in its Notes column, parsed with the `csv`
//! crate ([`parse_weight_csv`]) — never `split(',')`.
//!
//! Per-section isolation mirrors the browser dashboard: a file that is missing or
//! unparseable becomes `null` and appends a line to `errors` rather than failing
//! the whole endpoint. The one exception is `diet-today.js` — the screen is
//! pointless without it, so its absence/parse-failure is the only `503`.

use crate::*;
use std::collections::BTreeSet;

/// Format a `SystemTime` as an RFC 3339 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
/// std only — reuses `prompt::civil_from_days` for the calendar math, the same
/// algorithm the per-turn clock header uses. A pre-epoch time (should never
/// happen for a file mtime or `now`) clamps to the epoch rather than panicking.
pub fn rfc3339_utc(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

/// Extract the data literal from one of the vault's `window.X = <literal>;` files
/// and parse it with `json5`. Pure and unit-testable.
///
/// Strategy (deliberately simple, no JS parser): drop every full-line `//`
/// comment, find the FIRST `=` (the assignment), take everything after it up to
/// the FINAL `;` (the statement terminator — a `;` inside a string can only come
/// earlier than the trailing one), and parse the trimmed literal as JSON5. json5
/// tolerates unquoted keys, single/double quotes, trailing commas, and comments,
/// so no quote-rewriting or entity-decoding is needed — embedded `<strong>` /
/// `&mdash;` are ordinary string bytes.
pub fn extract_js_literal(content: &str) -> Result<Value, String> {
    // Drop full-line `//` comments so a `=` or `;` inside a comment can't be
    // mistaken for the assignment or terminator. Only leading whole-line comments
    // occur in these files; a `//` inside the literal is inside a string.
    let stripped: String = content
        .lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");

    let eq = stripped
        .find('=')
        .ok_or_else(|| "no `=` assignment found".to_string())?;
    let after = &stripped[eq + 1..];
    // Up to the final `;`; tolerate a missing terminator (take the whole tail).
    let literal = match after.rfind(';') {
        Some(p) => &after[..p],
        None => after,
    }
    .trim();
    if literal.is_empty() {
        return Err("empty literal after `=`".to_string());
    }
    json5::from_str::<Value>(literal).map_err(|e| format!("json5 parse error: {e}"))
}

/// Read a file and extract its JS literal. IO and parse failures both surface as
/// a human-readable string for the `errors` array.
fn load_js_section(path: &Path) -> Result<Value, String> {
    let content =
        std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    extract_js_literal(&content)
}

/// `PROPOSED_DIET` with an empty (or absent) `ideas` list is treated the same as
/// no proposal at all — the browser dashboard hides an empty meal-ideas section,
/// so the app should see `null`, not an empty shell.
fn normalize_proposed(v: Value) -> Option<Value> {
    let has_ideas = v
        .get("ideas")
        .and_then(|i| i.as_array())
        .map(|a| !a.is_empty())
        .unwrap_or(false);
    has_ideas.then_some(v)
}

/// Map `weight-log.csv` (RFC 4180, header
/// `Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes`) to the
/// `weightSeries` array in file (chronological) order. Returns the rows plus a
/// list of human-readable problems (never fails the whole file): a row is skipped
/// when the `csv` reader rejects it (bad quoting / wrong field count), its Date is
/// blank, or its Weight_lbs doesn't parse. Blank optional cells become `null`; a
/// non-blank-but-unparseable optional numeric also becomes `null` rather than
/// dropping the row. Pure and unit-testable.
pub fn parse_weight_csv(content: &str) -> (Vec<Value>, Vec<String>) {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(false)
        .from_reader(content.as_bytes());

    let mut rows = Vec::new();
    let mut skipped: Vec<usize> = Vec::new();

    // Optional f64 cell → JSON number or null (blank or unparseable → null).
    let opt_f = |cell: Option<&str>| -> Value {
        match cell.map(str::trim).filter(|s| !s.is_empty()) {
            Some(s) => s.parse::<f64>().map(|f| json!(f)).unwrap_or(Value::Null),
            None => Value::Null,
        }
    };
    // Optional string cell → JSON string or null.
    let opt_s = |cell: Option<&str>| -> Value {
        match cell.map(str::trim).filter(|s| !s.is_empty()) {
            Some(s) => json!(s),
            None => Value::Null,
        }
    };

    for (i, rec) in rdr.records().enumerate() {
        // Data rows start at file line 2 (line 1 is the header).
        let line_no = i + 2;
        let rec = match rec {
            Ok(r) => r,
            Err(_) => {
                skipped.push(line_no);
                continue;
            }
        };
        let date = rec.get(0).unwrap_or("").trim();
        let lbs = match rec.get(1).map(str::trim).unwrap_or("").parse::<f64>() {
            Ok(v) if !date.is_empty() => v,
            _ => {
                skipped.push(line_no);
                continue;
            }
        };
        rows.push(json!({
            "date": date,
            "lbs": lbs,
            "kg": opt_f(rec.get(2)),
            "phase": opt_s(rec.get(3)),
            "bf": opt_f(rec.get(4)),
            "leanLbs": opt_f(rec.get(5)),
            "notes": opt_s(rec.get(6)),
        }));
    }

    let mut errors = Vec::new();
    if !skipped.is_empty() {
        let list = skipped
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        errors.push(format!(
            "{} unparseable row(s) skipped (line{} {list})",
            skipped.len(),
            if skipped.len() == 1 { "" } else { "s" }
        ));
    }
    (rows, errors)
}

// ---- Day history: date validation, CSV reconstruction, availableDays --------
//
// The Health tab can page back through earlier days. Two tiers:
//   * ARCHIVED — `<vault>/diet-logs/days/<date>.js`, an exact copy of that day's
//     final `diet-today.js`; parsed with the SAME `extract_js_literal` and served
//     as the `today` section at full fidelity (targets, dayStyle, engine judgment).
//   * RECONSTRUCTED — for a date with no archive, rebuilt from the append-only CSVs
//     (`food-log.csv`, `exercise-log.csv`, `weight-log.csv`). Meals/exercise/weight
//     are real logged data; targets and dayStyle were never recorded per day, so
//     they are null and the app renders WITHOUT judgment colors.
//
// All of the below is pure and unit-tested from synthetic fixtures — never a copy
// of the real vault (personal data).

/// Strictly validate a `YYYY-MM-DD` date and return `(y, m, d)` on success. Any
/// other shape — wrong length, non-digit, missing zero-pad, out-of-range month/day
/// — returns `None`. Does not check days-per-month (a 400 gate, not a calendar).
pub fn valid_iso_date(s: &str) -> Option<(i64, i64, i64)> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    if !s[0..4].bytes().all(|c| c.is_ascii_digit())
        || !s[5..7].bytes().all(|c| c.is_ascii_digit())
        || !s[8..10].bytes().all(|c| c.is_ascii_digit())
    {
        return None;
    }
    let y = s[0..4].parse::<i64>().ok()?;
    let m = s[5..7].parse::<i64>().ok()?;
    let d = s[8..10].parse::<i64>().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some((y, m, d))
}

/// Header-name → column-index map for a CSV. The vault's logs address columns by
/// name (their order has drifted over time), so we never index by position.
fn header_index(headers: &csv::StringRecord) -> HashMap<String, usize> {
    headers
        .iter()
        .enumerate()
        .map(|(i, h)| (h.trim().to_string(), i))
        .collect()
}

/// Minutes-since-midnight sort key for an `HH:MM` string; a missing/unparseable
/// time returns -1 so it sorts FIRST (the generator's convention, mirrored in the
/// app's `DietSemantics.minutesOfDay`).
fn minutes_of_day(time: Option<&str>) -> i64 {
    let Some(t) = time else { return -1 };
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() == 2 {
        if let (Ok(h), Ok(m)) = (parts[0].parse::<i64>(), parts[1].parse::<i64>()) {
            if (0..24).contains(&h) && (0..60).contains(&m) {
                return h * 60 + m;
            }
        }
    }
    -1
}

/// The set of dates in a log CSV (the `Date` column), skipping blanks and
/// malformed dates. `flexible(true)` so one bad row can't stop date collection.
pub fn csv_dates(content: &str) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(content.as_bytes());
    let di = match rdr.headers() {
        Ok(h) => header_index(h).get("Date").copied(),
        Err(_) => return set,
    };
    let Some(di) = di else { return set };
    for rec in rdr.records().flatten() {
        let d = rec.get(di).map(str::trim).unwrap_or("");
        if valid_iso_date(d).is_some() {
            set.insert(d.to_string());
        }
    }
    set
}

/// The set of archived dates: `YYYY-MM-DD.js` filenames under `days/`. A missing
/// directory is not an error — it's simply no archives.
pub fn archive_dates(days_dir: &Path) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    if let Ok(rd) = std::fs::read_dir(days_dir) {
        for entry in rd.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if let Some(stem) = name.strip_suffix(".js") {
                    if valid_iso_date(stem).is_some() {
                        set.insert(stem.to_string());
                    }
                }
            }
        }
    }
    set
}

/// One human-readable summary line for the malformed rows a section skipped.
fn summarize_broken(section: &str, broken: &[usize]) -> String {
    let list = broken
        .iter()
        .map(|n| n.to_string())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "{section}: {} unparseable row(s) skipped (line{} {list})",
        broken.len(),
        if broken.len() == 1 { "" } else { "s" }
    )
}

/// A meal item's `amount` field. Blank Amount → null. When Unit is non-blank and
/// Amount is a bare number, join them (`"1"` + `"ea"` → `"1 ea"`); otherwise the
/// Amount already carries its own unit text (`"1 medium (~118g)"`) and is used
/// verbatim.
fn build_amount(amount: &str, unit: &str) -> Value {
    if amount.is_empty() {
        return Value::Null;
    }
    if !unit.is_empty() && amount.parse::<f64>().is_ok() {
        json!(format!("{amount} {unit}"))
    } else {
        json!(amount)
    }
}

/// A meal item's calories: `Calories` when it parses; else `Cal_per_100g × Grams /
/// 100` rounded when both parse; else `None` (the caller records one error and
/// uses 0).
fn derive_cal(calories: &str, cal_per_100g: &str, grams: &str) -> Option<f64> {
    if let Ok(c) = calories.parse::<f64>() {
        return Some(c);
    }
    if let (Ok(cp), Ok(g)) = (cal_per_100g.parse::<f64>(), grams.parse::<f64>()) {
        return Some((cp * g / 100.0).round());
    }
    None
}

/// A blank optional numeric cell → 0 (early rows predate fiber tracking, etc.).
fn num_or_zero(s: &str) -> f64 {
    s.parse::<f64>().unwrap_or(0.0)
}

/// A blank string cell → null, otherwise the trimmed string.
fn opt_str(s: &str) -> Value {
    if s.is_empty() {
        Value::Null
    } else {
        json!(s)
    }
}

/// A blank/unparseable numeric cell → null, otherwise the number.
fn opt_num(s: &str) -> Value {
    s.parse::<f64>().map(|f| json!(f)).unwrap_or(Value::Null)
}

/// Reconstruct a day's meals from `food-log.csv` for `date`. Rows are grouped into
/// meals keyed by `(Meal, Time)` (blank Time groups by Meal alone) preserving
/// first-seen order, then sorted chronologically (null time first). A structurally
/// broken row is skipped and counted once into `errors`; an item with no derivable
/// calories gets `cal = 0` and one `errors` note. Pure and unit-testable.
pub fn reconstruct_meals(content: &str, date: &str) -> (Vec<Value>, Vec<String>) {
    let mut errors: Vec<String> = Vec::new();
    // `flexible(true)`: the append-only log is legitimately ragged — early rows
    // predate later columns (Fiber_g, Meal_Type), so they have fewer fields. A
    // short row is NOT malformed; its missing trailing cells read blank (→ 0/null).
    // Columns are addressed by header NAME, never by position.
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(content.as_bytes());
    let idx = match rdr.headers() {
        Ok(h) => header_index(h),
        Err(_) => return (vec![], vec!["meals: food-log.csv header unreadable".into()]),
    };
    let col = |rec: &csv::StringRecord, name: &str| -> String {
        idx.get(name)
            .and_then(|&j| rec.get(j))
            .unwrap_or("")
            .trim()
            .to_string()
    };

    // (Meal, Time) groups in first-seen order.
    let mut groups: Vec<(String, Option<String>, Vec<Value>)> = Vec::new();
    let mut broken: Vec<usize> = Vec::new();
    for (i, rec) in rdr.records().enumerate() {
        let line_no = i + 2; // data rows start at file line 2
        let rec = match rec {
            Ok(r) => r,
            Err(_) => {
                broken.push(line_no);
                continue;
            }
        };
        if col(&rec, "Date") != date {
            continue;
        }
        // A row torn so badly it has no item name can't become a meal item — skip
        // and count it (the contract's "row that fails to parse").
        if col(&rec, "Item").is_empty() {
            broken.push(line_no);
            continue;
        }
        let meal = col(&rec, "Meal");
        let time = {
            let t = col(&rec, "Time");
            if t.is_empty() {
                None
            } else {
                Some(t)
            }
        };
        let item_name = col(&rec, "Item");
        let amount = build_amount(&col(&rec, "Amount"), &col(&rec, "Unit"));
        let cal = match derive_cal(
            &col(&rec, "Calories"),
            &col(&rec, "Cal_per_100g"),
            &col(&rec, "Grams"),
        ) {
            Some(c) => c,
            None => {
                errors.push(format!("meals: '{item_name}' has no calories (line {line_no})"));
                0.0
            }
        };
        let item = json!({
            "item": item_name,
            "amount": amount,
            "cal": cal,
            "p": num_or_zero(&col(&rec, "Protein_g")),
            "f": num_or_zero(&col(&rec, "Fat_g")),
            "c": num_or_zero(&col(&rec, "Carbs_g")),
            "fiber": num_or_zero(&col(&rec, "Fiber_g")),
        });
        if let Some(g) = groups.iter_mut().find(|g| g.0 == meal && g.1 == time) {
            g.2.push(item);
        } else {
            groups.push((meal, time, vec![item]));
        }
    }
    if !broken.is_empty() {
        errors.push(summarize_broken("meals", &broken));
    }
    // Stable sort by time (null first). Rust's sort_by_key is stable, so groups at
    // the same time keep first-seen order.
    groups.sort_by_key(|g| minutes_of_day(g.1.as_deref()));
    let meals = groups
        .into_iter()
        .map(|(name, time, items)| {
            json!({
                "name": name,
                "time": time.map(Value::from).unwrap_or(Value::Null),
                "items": items,
            })
        })
        .collect();
    (meals, errors)
}

/// Reconstruct a day's exercise from `exercise-log.csv` for `date`, mapped to the
/// exercise shape and sorted by `Start_Time` (null first). A structurally broken
/// row is skipped and counted once into `errors`. Pure and unit-testable.
pub fn reconstruct_exercise(content: &str, date: &str) -> (Vec<Value>, Vec<String>) {
    let mut errors: Vec<String> = Vec::new();
    // `flexible(true)` for the same append-only raggedness reason as meals; columns
    // by header name.
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(content.as_bytes());
    let idx = match rdr.headers() {
        Ok(h) => header_index(h),
        Err(_) => return (vec![], vec!["exercise: exercise-log.csv header unreadable".into()]),
    };
    let col = |rec: &csv::StringRecord, name: &str| -> String {
        idx.get(name)
            .and_then(|&j| rec.get(j))
            .unwrap_or("")
            .trim()
            .to_string()
    };

    let mut rows: Vec<(i64, Value)> = Vec::new();
    let mut broken: Vec<usize> = Vec::new();
    for (i, rec) in rdr.records().enumerate() {
        let line_no = i + 2;
        let rec = match rec {
            Ok(r) => r,
            Err(_) => {
                broken.push(line_no);
                continue;
            }
        };
        if col(&rec, "Date") != date {
            continue;
        }
        // A row with no exercise type can't become a session — skip and count it.
        if col(&rec, "Type").is_empty() {
            broken.push(line_no);
            continue;
        }
        let time = {
            let t = col(&rec, "Start_Time");
            if t.is_empty() {
                None
            } else {
                Some(t)
            }
        };
        let dist = col(&rec, "Distance_km");
        let (distance, unit) = match dist.parse::<f64>() {
            Ok(km) => (json!(km), json!("km")),
            Err(_) => (Value::Null, Value::Null),
        };
        let val = json!({
            "type": col(&rec, "Type"),
            "time": time.clone().map(Value::from).unwrap_or(Value::Null),
            "desc": opt_str(&col(&rec, "Description")),
            "distance": distance,
            "unit": unit,
            "duration": opt_str(&col(&rec, "Duration")),
            "pace": opt_str(&col(&rec, "Pace_min_per_km")),
            "avgHR": opt_num(&col(&rec, "Avg_HR")),
            "calories": opt_num(&col(&rec, "Calories")),
        });
        rows.push((minutes_of_day(time.as_deref()), val));
    }
    if !broken.is_empty() {
        errors.push(summarize_broken("exercise", &broken));
    }
    rows.sort_by_key(|(k, _)| *k);
    (rows.into_iter().map(|(_, v)| v).collect(), errors)
}

/// The single `weight-log.csv` row matching `date`, in the today-weight shape
/// `{ lbs, kg, bf, mm, notes }` (`mm` from `MuscleMass_lbs`/`leanLbs`), or `None`
/// when there's no weigh-in that exact date. Reuses [`parse_weight_csv`].
pub fn weight_for_date(content: &str, date: &str) -> Option<Value> {
    let (rows, _) = parse_weight_csv(content);
    rows.into_iter()
        .find(|r| r["date"] == json!(date))
        .map(|r| {
            json!({
                "lbs": r["lbs"],
                "kg": r["kg"],
                "bf": r["bf"],
                "mm": r["leanLbs"],
                "notes": r["notes"],
            })
        })
}

/// Reconstruct the `today` section for a past `date` from the CSVs: real meals,
/// exercise, and weigh-in; `dayStyle`/`dayType`/`targets` null (never recorded per
/// day). Returns the section plus any reconstruction errors.
fn reconstruct_day(
    date: &str,
    food: Option<&str>,
    exercise: Option<&str>,
    weight: Option<&str>,
) -> (Value, Vec<String>) {
    let mut errors: Vec<String> = Vec::new();
    let (meals, me) = food.map(|c| reconstruct_meals(c, date)).unwrap_or_default();
    errors.extend(me);
    let (ex, ee) = exercise
        .map(|c| reconstruct_exercise(c, date))
        .unwrap_or_default();
    errors.extend(ee);
    let weight = weight
        .and_then(|c| weight_for_date(c, date))
        .unwrap_or(Value::Null);
    let today = json!({
        "date": date,
        "dayStyle": Value::Null,
        "dayType": Value::Null,
        "weight": weight,
        "exercise": ex,
        "meals": meals,
        "targets": Value::Null,
    });
    (today, errors)
}

/// A JSON error response with the given status (400/404/503).
fn json_error(status: StatusCode, msg: String) -> Response {
    (status, Json(json!({ "error": msg }))).into_response()
}

/// `GET /jesse/diet[?date=YYYY-MM-DD]` — assemble the diet snapshot from the
/// vault's data files. Same bearer auth as every other endpoint; strictly
/// read-only. With no `date` (or `date` == today's date) it returns the existing
/// today response plus the three additive history fields; with a past `date` it
/// serves the archived day (fidelity `archived`) or reconstructs it from the CSVs
/// (fidelity `reconstructed`). Returns `503` only when `diet-today.js` itself is
/// missing/unparseable; `400` on a malformed date; `404` for an unknown/future date.
pub async fn jesse_diet(
    State(st): State<AppState>,
    Query(q): Query<DietQuery>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    let todo = Path::new(&st.cfg.vault).join("todo-list");
    let logs = Path::new(&st.cfg.vault).join("diet-logs");
    let days_dir = logs.join("days");

    // Validate the optional date early: a malformed value is a 400 before any IO.
    let requested = match q.date.as_deref() {
        Some(d) => {
            if valid_iso_date(d).is_none() {
                return Ok(json_error(
                    StatusCode::BAD_REQUEST,
                    format!("invalid date '{d}'; expected YYYY-MM-DD"),
                ));
            }
            Some(d.to_string())
        }
        None => None,
    };

    // `today` is REQUIRED. Its absence/parse-failure is the only 503 — the screen
    // (and paging) is pointless without it; its date anchors today-detection and
    // the future check, its mtime the app's "updated HH:MM" stamp.
    let today_path = todo.join("diet-today.js");
    let today = match load_js_section(&today_path) {
        Ok(v) => v,
        Err(e) => {
            return Ok((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({
                    "error": format!("diet-today.js unavailable: {e}"),
                    "errors": [format!("today: {e}")],
                })),
            )
                .into_response());
        }
    };
    let today_date = today
        .get("date")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let today_mtime = std::fs::metadata(&today_path)
        .and_then(|m| m.modified())
        .ok()
        .map(rfc3339_utc);

    // Read the append-only logs once — reused for weightSeries, availableDays, and
    // (on a history request) reconstruction. Missing files are simply absent.
    let food_csv = std::fs::read_to_string(logs.join("food-log.csv")).ok();
    let exercise_csv = std::fs::read_to_string(logs.join("exercise-log.csv")).ok();
    let weight_path = logs.join("weight-log.csv");
    let weight_read = std::fs::read_to_string(&weight_path);

    // weightSeries: shared by today and history (the weight chart is inherently
    // historical). Present-but-empty → []; a missing file → null + one error.
    let (weight_series, weight_errors): (Value, Vec<String>) = match &weight_read {
        Ok(content) => {
            let (rows, errs) = parse_weight_csv(content);
            (
                Value::Array(rows),
                errs.into_iter()
                    .map(|e| format!("weightSeries: {e}"))
                    .collect(),
            )
        }
        Err(e) => (
            Value::Null,
            vec![format!("weightSeries: cannot read {}: {e}", weight_path.display())],
        ),
    };

    // availableDays: union of every date the app can page to, sorted + deduped.
    let mut days: BTreeSet<String> = BTreeSet::new();
    if !today_date.is_empty() {
        days.insert(today_date.clone());
    }
    if let Some(c) = &food_csv {
        days.extend(csv_dates(c));
    }
    if let Some(c) = &exercise_csv {
        days.extend(csv_dates(c));
    }
    if let Ok(c) = &weight_read {
        days.extend(csv_dates(c));
    }
    days.extend(archive_dates(&days_dir));
    let available: Vec<String> = days.iter().cloned().collect(); // BTreeSet is sorted ascending

    // ---- Today (no date, or date == today's date) --------------------------
    let is_today = requested.as_deref().is_none_or(|d| d == today_date);
    if is_today {
        let mut errors: Vec<String> = Vec::new();
        let mut section = |label: &str, path: &Path| -> Option<Value> {
            match load_js_section(path) {
                Ok(v) => Some(v),
                Err(e) => {
                    errors.push(format!("{label}: {e}"));
                    None
                }
            }
        };
        let progress = section("progress", &todo.join("diet-progress.js"));
        let coach = section("coach", &todo.join("diet-coach-notes.js"));

        // `proposed-diet-today.js` is OPTIONAL: a missing file is NOT an error.
        let proposed_path = todo.join("proposed-diet-today.js");
        let proposed = match std::fs::read_to_string(&proposed_path) {
            Ok(content) => match extract_js_literal(&content) {
                Ok(v) => normalize_proposed(v),
                Err(e) => {
                    errors.push(format!("proposed: {e}"));
                    None
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => {
                errors.push(format!("proposed: cannot read {}: {e}", proposed_path.display()));
                None
            }
        };
        errors.extend(weight_errors);

        return Ok(Json(json!({
            "asOf": rfc3339_utc(SystemTime::now()),
            "todayMtime": today_mtime,
            "today": today,
            "proposed": proposed,
            "progress": progress,
            "coach": coach,
            "weightSeries": weight_series,
            "errors": errors,
            "availableDays": available,
            "historical": false,
            "fidelity": "live",
        }))
        .into_response());
    }

    // ---- History (a past date) ---------------------------------------------
    let date = requested.expect("is_today handles the None case");
    // A future date, or a date with no data anywhere, is a 404.
    if date.as_str() > today_date.as_str() || !days.contains(&date) {
        return Ok(json_error(
            StatusCode::NOT_FOUND,
            format!("no diet data for {date}"),
        ));
    }

    // Archive wins over reconstruction: an exact copy of that day's final
    // diet-today.js, parsed with the SAME extractor and served at full fidelity.
    let archive_path = days_dir.join(format!("{date}.js"));
    let mut errors: Vec<String> = Vec::new();
    let (today_section, fidelity, hist_mtime) = match std::fs::read_to_string(&archive_path) {
        Ok(content) => match extract_js_literal(&content) {
            Ok(v) => {
                let mtime = std::fs::metadata(&archive_path)
                    .and_then(|m| m.modified())
                    .ok()
                    .map(rfc3339_utc);
                (v, "archived", mtime)
            }
            Err(e) => {
                // Archive present but broken: fall back to reconstruction, note it.
                errors.push(format!("archive: {e}"));
                let (recon, errs) = reconstruct_day(
                    &date,
                    food_csv.as_deref(),
                    exercise_csv.as_deref(),
                    weight_read.as_deref().ok(),
                );
                errors.extend(errs);
                (recon, "reconstructed", None)
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let (recon, errs) = reconstruct_day(
                &date,
                food_csv.as_deref(),
                exercise_csv.as_deref(),
                weight_read.as_deref().ok(),
            );
            errors.extend(errs);
            (recon, "reconstructed", None)
        }
        Err(e) => {
            errors.push(format!("archive: cannot read {}: {e}", archive_path.display()));
            let (recon, errs) = reconstruct_day(
                &date,
                food_csv.as_deref(),
                exercise_csv.as_deref(),
                weight_read.as_deref().ok(),
            );
            errors.extend(errs);
            (recon, "reconstructed", None)
        }
    };
    errors.extend(weight_errors);

    // Historical requests never carry proposed/progress/coach — those files
    // describe the CURRENT state, so attaching them to a past date would be wrong.
    Ok(Json(json!({
        "asOf": rfc3339_utc(SystemTime::now()),
        "todayMtime": hist_mtime,
        "today": today_section,
        "proposed": Value::Null,
        "progress": Value::Null,
        "coach": Value::Null,
        "weightSeries": weight_series,
        "errors": errors,
        "availableDays": available,
        "historical": true,
        "fidelity": fidelity,
    }))
    .into_response())
}

/// The optional `?date=YYYY-MM-DD` query parameter. Absent → today.
#[derive(Deserialize)]
pub struct DietQuery {
    pub date: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- extract_js_literal ------------------------------------------------

    #[test]
    fn extracts_object_with_unquoted_keys_single_quotes_trailing_comma() {
        let src = "// generated 2026-07-08\n// do not edit\n\
                   window.DIET_TODAY = {\n\
                     date: '2026-07-08',\n\
                     dayStyle: 'normal',\n\
                     targets: { calories: 2100, protein: 190, fat: 65, carbs: 210, },\n\
                   };\n";
        let v = extract_js_literal(src).expect("parses");
        assert_eq!(v["date"], "2026-07-08");
        assert_eq!(v["dayStyle"], "normal");
        assert_eq!(v["targets"]["protein"], 190);
        // Trailing comma tolerated by json5.
        assert_eq!(v["targets"]["carbs"], 210);
    }

    #[test]
    fn extracts_array_literal() {
        let src = "window.WEIGHTS = [ { d: 1 }, { d: 2 }, ];";
        let v = extract_js_literal(src).expect("parses array");
        assert_eq!(v.as_array().unwrap().len(), 2);
        assert_eq!(v[1]["d"], 2);
    }

    #[test]
    fn preserves_embedded_html_and_entities_in_strings() {
        // Coach notes carry <strong> and &mdash; — they must survive verbatim as
        // ordinary string content, not be decoded or stripped by the bridge.
        let src = "// coach\nwindow.DIET_COACH = { notes: [ '<strong>Nice</strong> work &mdash; keep going' ] };";
        let v = extract_js_literal(src).expect("parses");
        assert_eq!(
            v["notes"][0],
            "<strong>Nice</strong> work &mdash; keep going"
        );
    }

    #[test]
    fn semicolon_inside_a_string_does_not_truncate_the_literal() {
        // A `;` inside a string must not be mistaken for the terminator: rfind
        // takes the LAST `;`, which is the real statement terminator.
        let src = "window.X = { note: 'a; b; c', n: 5 };";
        let v = extract_js_literal(src).expect("parses");
        assert_eq!(v["note"], "a; b; c");
        assert_eq!(v["n"], 5);
    }

    #[test]
    fn tolerates_missing_terminating_semicolon() {
        let src = "window.X = { a: 1 }";
        let v = extract_js_literal(src).expect("parses without trailing ;");
        assert_eq!(v["a"], 1);
    }

    #[test]
    fn malformed_literal_is_an_error_not_a_panic() {
        let src = "window.X = { a: , b: }";
        assert!(extract_js_literal(src).is_err());
    }

    #[test]
    fn missing_assignment_is_an_error() {
        assert!(extract_js_literal("// just a comment\n").is_err());
    }

    // ---- parse_weight_csv --------------------------------------------------

    const HEADER: &str = "Date,Weight_lbs,Weight_kg,Phase,BodyFat_pct,MuscleMass_lbs,Notes";

    #[test]
    fn maps_rows_with_quoted_commas_and_blank_cells() {
        let csv = format!(
            "{HEADER}\n\
             2026-07-01,198.4,90.0,Phase 2,18.2,150.1,\"weighed after run, felt light\"\n\
             2026-07-02,197.8,,Phase 2,,,\n"
        );
        let (rows, errs) = parse_weight_csv(&csv);
        assert!(errs.is_empty(), "clean rows: {errs:?}");
        assert_eq!(rows.len(), 2);

        // Row 1: fully populated; the Notes quoted comma is preserved as one field.
        assert_eq!(rows[0]["date"], "2026-07-01");
        assert_eq!(rows[0]["lbs"], 198.4);
        assert_eq!(rows[0]["kg"], 90.0);
        assert_eq!(rows[0]["phase"], "Phase 2");
        assert_eq!(rows[0]["bf"], 18.2);
        assert_eq!(rows[0]["leanLbs"], 150.1);
        assert_eq!(rows[0]["notes"], "weighed after run, felt light");

        // Row 2: blank kg / bf / lean / notes → null; date + lbs kept.
        assert_eq!(rows[1]["lbs"], 197.8);
        assert!(rows[1]["kg"].is_null());
        assert!(rows[1]["bf"].is_null());
        assert!(rows[1]["leanLbs"].is_null());
        assert!(rows[1]["notes"].is_null());
        assert_eq!(rows[1]["phase"], "Phase 2");
    }

    #[test]
    fn preserves_chronological_file_order() {
        let csv = format!("{HEADER}\n2026-07-01,200,,,,,\n2026-07-02,199,,,,,\n2026-07-03,198,,,,,\n");
        let (rows, _) = parse_weight_csv(&csv);
        let dates: Vec<&str> = rows.iter().map(|r| r["date"].as_str().unwrap()).collect();
        assert_eq!(dates, ["2026-07-01", "2026-07-02", "2026-07-03"]);
    }

    #[test]
    fn skips_bad_rows_and_reports_line_numbers() {
        // Line 3 has a non-numeric weight; line 4 has a blank date. Both skipped,
        // both counted; the good rows survive.
        let csv = format!(
            "{HEADER}\n\
             2026-07-01,200,,,,,\n\
             2026-07-02,notanumber,,,,,\n\
             ,199,,,,,\n\
             2026-07-04,198,,,,,\n"
        );
        let (rows, errs) = parse_weight_csv(&csv);
        assert_eq!(rows.len(), 2, "only the two valid rows survive");
        assert_eq!(rows[0]["date"], "2026-07-01");
        assert_eq!(rows[1]["date"], "2026-07-04");
        assert_eq!(errs.len(), 1, "one summary error line");
        assert!(errs[0].contains('3') && errs[0].contains('4'), "names the bad lines: {errs:?}");
    }

    #[test]
    fn empty_file_body_yields_no_rows_no_errors() {
        let (rows, errs) = parse_weight_csv(&format!("{HEADER}\n"));
        assert!(rows.is_empty());
        assert!(errs.is_empty());
    }

    // ---- normalize_proposed ------------------------------------------------

    #[test]
    fn empty_ideas_normalizes_to_none() {
        let v = extract_js_literal("window.PROPOSED_DIET = { date: '2026-07-08', ideas: [] };").unwrap();
        assert!(normalize_proposed(v).is_none());
    }

    #[test]
    fn absent_ideas_normalizes_to_none() {
        let v = extract_js_literal("window.PROPOSED_DIET = { date: '2026-07-08' };").unwrap();
        assert!(normalize_proposed(v).is_none());
    }

    #[test]
    fn non_empty_ideas_is_kept() {
        let v = extract_js_literal(
            "window.PROPOSED_DIET = { ideas: [ { name: 'Snack', time: '~15:00', items: [] } ] };",
        )
        .unwrap();
        assert!(normalize_proposed(v).is_some());
    }

    // ---- rfc3339_utc -------------------------------------------------------

    #[test]
    fn formats_a_known_instant() {
        // 1_700_000_000 is the well-known Unix timestamp 2023-11-14T22:13:20Z.
        let t = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        assert_eq!(rfc3339_utc(t), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn formats_the_epoch() {
        assert_eq!(rfc3339_utc(UNIX_EPOCH), "1970-01-01T00:00:00Z");
    }

    // ---- valid_iso_date ----------------------------------------------------

    #[test]
    fn accepts_a_well_formed_date() {
        assert_eq!(valid_iso_date("2026-04-15"), Some((2026, 4, 15)));
    }

    #[test]
    fn rejects_malformed_dates() {
        for bad in [
            "2026-4-5",     // not zero-padded
            "2026-13-01",   // month out of range
            "2026-04-32",   // day out of range
            "2026/04/15",   // wrong separator
            "2026-04-15T",  // trailing char / wrong length
            "abcd-ef-gh",   // non-digit
            "",             // empty
            "2026-00-10",   // month 0
            "2026-04-00",   // day 0
        ] {
            assert!(valid_iso_date(bad).is_none(), "should reject {bad:?}");
        }
    }

    // ---- reconstruct_meals -------------------------------------------------

    const FOOD_HEADER: &str = "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g";

    #[test]
    fn groups_meals_by_meal_and_time_two_same_named_meals_stay_separate() {
        // Two Snack meals at different times must become two meal objects; a third
        // row shares the first Snack's (Meal, Time) and joins it.
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Snack,Apple,1,ea,,,95,0,0,25,,10:00,Snack,4\n\
             2026-04-15,Snack,Almonds,28,g,,,164,6,14,6,,15:30,Snack,3\n\
             2026-04-15,Snack,Grapes,1,cup,,,62,0,0,16,,10:00,Snack,1\n"
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-04-15");
        assert!(errs.is_empty(), "clean rows: {errs:?}");
        assert_eq!(meals.len(), 2, "two (Meal, Time) groups");
        assert_eq!(meals[0]["time"], "10:00");
        assert_eq!(meals[0]["items"].as_array().unwrap().len(), 2, "Apple + Grapes");
        assert_eq!(meals[1]["time"], "15:30");
        assert_eq!(meals[1]["items"][0]["item"], "Almonds");
    }

    #[test]
    fn legacy_row_blank_time_blank_fiber_and_calories_derived() {
        // A legacy row: blank Time (groups by Meal alone, sorts first), blank
        // Fiber_g → 0, blank Calories derived from Cal_per_100g × Grams.
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-03-30,Dinner,Rice,150,g,130,150,,3,0,28,,,Dinner,\n\
             2026-03-30,Breakfast,Toast,2,ea,,,180,6,2,32,,08:00,Breakfast,3\n"
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-03-30");
        assert!(errs.is_empty(), "derivation succeeds, no error: {errs:?}");
        // Null time sorts first.
        assert_eq!(meals[0]["name"], "Dinner");
        assert!(meals[0]["time"].is_null(), "blank Time → null, sorts first");
        let rice = &meals[0]["items"][0];
        assert_eq!(rice["cal"], 195.0, "130 * 150 / 100 = 195");
        assert_eq!(rice["fiber"], 0.0, "blank Fiber_g → 0");
        assert_eq!(rice["amount"], "150 g");
        assert_eq!(meals[1]["time"], "08:00");
    }

    #[test]
    fn quoted_commas_in_notes_do_not_break_the_row() {
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Lunch,Soup,1,bowl,,,220,8,6,30,\"homemade, with beans, and rice\",12:00,Lunch,7\n"
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-04-15");
        assert!(errs.is_empty());
        assert_eq!(meals.len(), 1);
        assert_eq!(meals[0]["items"][0]["item"], "Soup");
        assert_eq!(meals[0]["items"][0]["c"], 30.0, "Notes quoting didn't shift columns");
    }

    #[test]
    fn legacy_short_row_is_not_malformed_missing_trailing_cells_are_blank() {
        // The append-only log is legitimately ragged: an early row predates the
        // Fiber_g (and Meal_Type) columns, so it's SHORT. It must parse normally
        // with fiber → 0, NOT be counted as malformed.
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-03-30,Breakfast,Eggs,3,ea,,,210,18,15,1,\n" // 12 fields: no Time/Meal_Type/Fiber_g
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-03-30");
        assert!(errs.is_empty(), "a short legacy row is not an error: {errs:?}");
        assert_eq!(meals.len(), 1);
        assert!(meals[0]["time"].is_null(), "missing Time cell → null");
        assert_eq!(meals[0]["items"][0]["fiber"], 0.0, "missing Fiber_g cell → 0");
        assert_eq!(meals[0]["items"][0]["cal"], 210.0);
    }

    #[test]
    fn malformed_row_is_skipped_with_an_error_rest_of_day_parses() {
        // A row with no Item name can't become a meal item → skipped + counted; the
        // surrounding good rows still parse.
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Breakfast,Eggs,3,ea,,,210,18,15,1,,07:00,Breakfast,0\n\
             2026-04-15,Breakfast,,,,,,,,,,,07:00,Breakfast,\n\
             2026-04-15,Breakfast,Bacon,2,ea,,,90,6,7,0,,07:00,Breakfast,0\n"
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-04-15");
        assert_eq!(meals.len(), 1, "one Breakfast group");
        assert_eq!(meals[0]["items"].as_array().unwrap().len(), 2, "Eggs + Bacon survive");
        assert_eq!(errs.len(), 1, "one summary error");
        assert!(errs[0].contains('3'), "names the torn line number: {errs:?}");
    }

    #[test]
    fn item_with_no_derivable_calories_is_zero_with_one_error() {
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Snack,Mystery,1,ea,,,,0,0,0,,14:00,Snack,0\n"
        );
        let (meals, errs) = reconstruct_meals(&csv, "2026-04-15");
        assert_eq!(meals[0]["items"][0]["cal"], 0.0);
        assert_eq!(errs.len(), 1);
        assert!(errs[0].contains("Mystery"), "error names the item: {errs:?}");
    }

    #[test]
    fn amount_joins_bare_number_and_unit_but_keeps_unit_text_verbatim() {
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Lunch,Yogurt,1,cup,,,150,15,4,12,,12:00,Lunch,0\n\
             2026-04-15,Lunch,Apple,1 medium (~118g),,52,118,,0,0,25,,12:00,Lunch,4\n\
             2026-04-15,Lunch,Water,,,,,0,0,0,0,,12:00,Lunch,0\n"
        );
        let (meals, _) = reconstruct_meals(&csv, "2026-04-15");
        let items = meals[0]["items"].as_array().unwrap();
        assert_eq!(items[0]["amount"], "1 cup", "bare number + unit joined");
        assert_eq!(items[1]["amount"], "1 medium (~118g)", "unit text verbatim");
        assert!(items[2]["amount"].is_null(), "blank Amount → null");
    }

    // ---- reconstruct_exercise ----------------------------------------------

    const EX_HEADER: &str = "Date,Type,Description,Distance_km,Duration,Pace_min_per_km,Elevation_m,Avg_HR,Cadence,Calories,Plan_Source,Notes,Start_Time";

    #[test]
    fn reconstructs_exercise_maps_fields_and_sorts_by_time() {
        let csv = format!(
            "{EX_HEADER}\n\
             2026-04-15,strength,Evening lift,,0:45:00,,,110,,240,plan,\"push, pull\",18:00\n\
             2026-04-15,run,Morning run,8.0,56:58,7:07,45,142,168,520,plan,easy,06:30\n"
        );
        let (ex, errs) = reconstruct_exercise(&csv, "2026-04-15");
        assert!(errs.is_empty());
        assert_eq!(ex.len(), 2);
        // Sorted by Start_Time: run (06:30) before strength (18:00).
        assert_eq!(ex[0]["type"], "run");
        assert_eq!(ex[0]["distance"], 8.0);
        assert_eq!(ex[0]["unit"], "km");
        assert_eq!(ex[0]["duration"], "56:58", "duration passed through verbatim");
        assert_eq!(ex[0]["pace"], "7:07");
        assert_eq!(ex[0]["avgHR"], 142.0);
        assert_eq!(ex[1]["type"], "strength");
        assert!(ex[1]["distance"].is_null(), "blank distance → null");
        assert!(ex[1]["pace"].is_null(), "blank pace → null");
        assert_eq!(ex[1]["duration"], "0:45:00", "a different duration format, verbatim");
    }

    #[test]
    fn exercise_blank_start_time_sorts_first() {
        let csv = format!(
            "{EX_HEADER}\n\
             2026-04-15,run,Timed,5.0,25:00,5:00,,150,,300,,,07:00\n\
             2026-04-15,walk,Untimed,2.0,20:00,,,90,,80,,,\n"
        );
        let (ex, _) = reconstruct_exercise(&csv, "2026-04-15");
        assert_eq!(ex[0]["type"], "walk", "null time sorts first");
        assert!(ex[0]["time"].is_null());
        assert_eq!(ex[1]["type"], "run");
    }

    // ---- weight_for_date ---------------------------------------------------

    #[test]
    fn weight_for_date_maps_present_row_to_today_weight_shape() {
        let csv = format!(
            "{HEADER}\n\
             2026-07-06,198.6,90.1,Phase 2,18.4,150.0,\"weighed after run, felt light\"\n\
             2026-07-07,198.0,89.8,Phase 2,,,\n"
        );
        let w = weight_for_date(&csv, "2026-07-06").expect("row present");
        assert_eq!(w["lbs"], 198.6);
        assert_eq!(w["kg"], 90.1);
        assert_eq!(w["bf"], 18.4);
        assert_eq!(w["mm"], 150.0, "mm from MuscleMass_lbs");
        assert_eq!(w["notes"], "weighed after run, felt light");
    }

    #[test]
    fn weight_for_date_blank_optional_cells_are_null() {
        let csv = format!("{HEADER}\n2026-07-07,198.0,89.8,Phase 2,,,\n");
        let w = weight_for_date(&csv, "2026-07-07").expect("row present");
        assert_eq!(w["lbs"], 198.0);
        assert!(w["bf"].is_null());
        assert!(w["mm"].is_null());
        assert!(w["notes"].is_null());
    }

    #[test]
    fn weight_for_date_absent_is_none() {
        let csv = format!("{HEADER}\n2026-07-07,198.0,89.8,Phase 2,,,\n");
        assert!(weight_for_date(&csv, "2026-07-06").is_none(), "no row that date → None");
    }

    // ---- csv_dates / archive_dates -----------------------------------------

    #[test]
    fn csv_dates_collects_unique_valid_dates() {
        let csv = format!(
            "{FOOD_HEADER}\n\
             2026-04-15,Breakfast,A,1,ea,,,100,0,0,0,,07:00,Breakfast,0\n\
             2026-04-15,Lunch,B,1,ea,,,100,0,0,0,,12:00,Lunch,0\n\
             2026-04-16,Dinner,C,1,ea,,,100,0,0,0,,19:00,Dinner,0\n\
             bad-date,Snack,D,1,ea,,,100,0,0,0,,15:00,Snack,0\n"
        );
        let dates = csv_dates(&csv);
        assert_eq!(dates.len(), 2, "deduped, malformed date dropped");
        assert!(dates.contains("2026-04-15"));
        assert!(dates.contains("2026-04-16"));
    }

    #[test]
    fn archive_dates_missing_directory_is_empty_not_an_error() {
        let missing = std::env::temp_dir().join(format!("jesse-no-such-{}", std::process::id()));
        assert!(archive_dates(&missing).is_empty(), "absent days/ → no archives, no panic");
    }
}
