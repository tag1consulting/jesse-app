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

/// `GET /jesse/diet` — assemble the diet snapshot from the vault's data files.
/// Same bearer auth as every other endpoint. Returns `200` whenever
/// `diet-today.js` parsed (other sections independently null + an `errors` entry
/// on failure), or `503` with a JSON error body when `diet-today.js` itself is
/// missing/unparseable.
pub async fn jesse_diet(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    let todo = Path::new(&st.cfg.vault).join("todo-list");
    let logs = Path::new(&st.cfg.vault).join("diet-logs");
    let mut errors: Vec<String> = Vec::new();

    // `today` is REQUIRED. Its absence/parse-failure is the only 503 — the screen
    // is pointless without it. Its mtime drives the app's "updated HH:MM" stamp.
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
    let today_mtime = std::fs::metadata(&today_path)
        .and_then(|m| m.modified())
        .ok()
        .map(rfc3339_utc);

    // Each remaining section is isolated: a failure is null + one `errors` line.
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

    // `proposed-diet-today.js` is OPTIONAL and frequently absent: a missing file
    // is NOT an error (proposed = null, nothing appended). A present-but-broken
    // file IS an error. An empty `ideas` list normalizes to null.
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

    // weight-log.csv → weightSeries. Present-but-empty is a Some([]); a missing
    // file is null + an error (it's an expected file).
    let weight_path = logs.join("weight-log.csv");
    let weight_series = match std::fs::read_to_string(&weight_path) {
        Ok(content) => {
            let (rows, errs) = parse_weight_csv(&content);
            for e in errs {
                errors.push(format!("weightSeries: {e}"));
            }
            Some(Value::Array(rows))
        }
        Err(e) => {
            errors.push(format!(
                "weightSeries: cannot read {}: {e}",
                weight_path.display()
            ));
            None
        }
    };

    Ok(Json(json!({
        "asOf": rfc3339_utc(SystemTime::now()),
        "todayMtime": today_mtime,
        "today": today,
        "proposed": proposed,
        "progress": progress,
        "coach": coach,
        "weightSeries": weight_series,
        "errors": errors,
    }))
    .into_response())
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
}
