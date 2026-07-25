//! **Vault-QA audit aggregation** (Piece 5, the pure core) — the tested, I/O-free
//! aggregation the `vaultqa-audit` bin renders into its daily note. Given a day's slice
//! of [`metrics::MetricsRecord`] lines (selected by TIMESTAMP, never a line-count
//! watermark) it computes the routed share, per-rung fallback rates, latency
//! percentiles, validator failures, emergency activations by failure class, and the
//! queued-diet count; and, given the queue's backlog age + any content-join findings,
//! the tripwires. The bin owns the I/O (reading the log + serving logs, re-validating
//! citations, the sampled hosted re-answer); this module owns the arithmetic so it can
//! be unit-tested on fixture JSONL without touching disk or a model.

use crate::*;

/// Local routes (tokens stayed on-device / were served locally).
fn is_local_route(r: MetricsRoute) -> bool {
    matches!(
        r,
        MetricsRoute::VaultqaLocal | MetricsRoute::DietLocal | MetricsRoute::EmergencyLocal
    )
}

/// The aggregated day. Every field derives ONLY from the content-free metrics lines.
#[derive(Debug, Clone, PartialEq)]
pub struct AuditAgg {
    /// Total metrics lines in the slice (each is a gated/routed/emergency turn).
    pub total: usize,
    /// Turns served locally (routed share numerator).
    pub routed_local: usize,
    /// Turns that fell through to hosted.
    pub hosted_fallback: usize,
    /// Per-rung fall-through counts (rung 0 = local success).
    pub rung_counts: std::collections::BTreeMap<u8, usize>,
    /// Per-route counts (by the kebab route string).
    pub route_counts: std::collections::BTreeMap<String, usize>,
    /// Wall p50 / p95 (ms) over the slice.
    pub latency_p50_ms: u64,
    pub latency_p95_ms: u64,
    /// Validator verdicts that were not `ok` (`fail` / `advisory-fail`).
    pub validator_failures: usize,
    /// Emergency activations, and a breakdown by hosted-failure class.
    pub emergency_activations: usize,
    pub emergency_by_class: std::collections::BTreeMap<String, usize>,
    /// Diet entries queued for later verify (badge carries `verify queued`).
    pub diet_queued: usize,
    /// Diet rung-2 fall-throughs broken down by machine-readable reason code (e.g.
    /// `schema_fail:time`, `malformed_json`, `no_loggable`). Only a diet rung-2 turn
    /// carries a `diet_reason`, so this counts exactly the rung-2 diet emissions.
    pub rung2_by_reason: std::collections::BTreeMap<String, usize>,
    /// Diet turns identifiable in the content-free log: local successes (route
    /// `diet-local`) plus rung-2 fall-throughs (those carrying a `diet_reason`). The
    /// denominator for the two diet rung-2 rates. Rung-3/4 diet fall-throughs share the
    /// hosted route with no diet marker and are not separately attributable here — a
    /// documented v1 limitation (the reason taxonomy is rung-2-only by design).
    pub diet_identifiable: usize,
    /// Nutrient completeness over the day's LOCAL-route diet turns (see
    /// [`MicroCompleteness`]).
    pub micros: MicroCompleteness,
}

/// The day's nutrient-completeness tally over local-route food rows, summed from the
/// per-turn [`metrics::DietMicros`] objects. This is the reporting half of "make
/// incompleteness visible": before it existed, a row logged locally with three blank
/// knowable nutrient columns looked exactly like a complete one.
///
/// NO auto-demotion is computed here — the numbers are reported and the threshold at
/// which an incomplete rate should stop the local route is NOT SET YET (a human call
/// against accumulated audit history, like probation itself).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MicroCompleteness {
    /// Local-route food rows appended over the day.
    pub food_rows: usize,
    /// Of those, the rows completion applies to (composites excluded).
    pub eligible_rows: usize,
    /// Rows the hosted completion filled at least one blank nutrient cell on.
    pub rows_completed: usize,
    /// Rows still carrying at least one blank expected nutrient column.
    pub rows_incomplete: usize,
    /// Expected nutrient cells filled / expected in total.
    pub filled: usize,
    pub expected: usize,
    /// Per-turn reason codes for a still-incomplete turn (`micros_incomplete`,
    /// `micro_complete_unparseable`, `micro_complete_off`).
    pub by_reason: std::collections::BTreeMap<String, usize>,
}

impl MicroCompleteness {
    /// The share of eligible local-route rows still missing at least one expected
    /// nutrient column, in [0.0, 1.0]; 0 when there were no eligible rows.
    pub fn incomplete_rate(&self) -> f64 {
        if self.eligible_rows == 0 {
            0.0
        } else {
            self.rows_incomplete as f64 / self.eligible_rows as f64
        }
    }

    /// The share of expected nutrient CELLS that are filled, in [0.0, 1.0]; 1.0 when
    /// nothing was expected (nothing missing).
    pub fn cell_fill_rate(&self) -> f64 {
        if self.expected < 1 {
            1.0
        } else {
            self.filled as f64 / self.expected as f64
        }
    }
}

impl AuditAgg {
    /// Routed share of gated turns in [0.0, 1.0]; 0 when there were no turns.
    pub fn routed_share(&self) -> f64 {
        if self.total == 0 {
            0.0
        } else {
            self.routed_local as f64 / self.total as f64
        }
    }

    /// Total diet rung-2 fall-throughs (sum over the reason breakdown).
    pub fn rung2_total(&self) -> usize {
        self.rung2_by_reason.values().sum()
    }

    /// Rung-2 turns that were a CORRECT rejection of a non-loggable turn (`no_loggable`)
    /// — the loose keyword gate let them into the pipeline; they are not failures.
    pub fn rung2_no_loggable(&self) -> usize {
        self.rung2_by_reason
            .get("no_loggable")
            .copied()
            .unwrap_or(0)
    }

    /// Rung-2 turns that were genuine pipeline FAILURES (everything but `no_loggable`).
    pub fn rung2_failures(&self) -> usize {
        self.rung2_total() - self.rung2_no_loggable()
    }

    /// The RAW rung-2 fall-through rate over identifiable diet turns, in [0.0, 1.0].
    pub fn diet_rung2_raw_rate(&self) -> f64 {
        if self.diet_identifiable == 0 {
            0.0
        } else {
            self.rung2_total() as f64 / self.diet_identifiable as f64
        }
    }

    /// The FAILURE-ONLY rate — the raw rate with `no_loggable` (correct rejections)
    /// excluded from the numerator. This is the rate the graduation bar should watch.
    pub fn diet_rung2_failure_rate(&self) -> f64 {
        if self.diet_identifiable == 0 {
            0.0
        } else {
            self.rung2_failures() as f64 / self.diet_identifiable as f64
        }
    }
}

/// One still-incomplete food row, named so it can be repaired BY HAND. The metrics log
/// is content-free (counts only), so the item names come from `food-log.csv` itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IncompleteFoodRow {
    pub meal: String,
    pub item: String,
    pub time: String,
    /// The EXPECTED nutrient columns this row leaves blank, by CSV column name.
    pub missing: Vec<&'static str>,
}

/// Find the food rows for `date` that still leave an EXPECTED nutrient column blank,
/// reading `food-log.csv` by header NAME (the log is ragged and column order has
/// drifted; a short legacy row simply reads its trailing columns as blank).
///
/// Read-only and I/O-free (the caller supplies the file body).
///
/// **Attribution caveat:** the CSV records no route, so this lists every incomplete row
/// for the day — local-route and hosted alike. The per-route COUNTS come from the
/// metrics lines ([`MicroCompleteness`]); this list is the hand-repair worklist.
pub fn incomplete_food_rows(food_csv: &str, date: &str) -> Vec<IncompleteFoodRow> {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(food_csv.as_bytes());
    let idx: std::collections::HashMap<String, usize> = match rdr.headers() {
        Ok(h) => h
            .iter()
            .enumerate()
            .map(|(i, name)| (name.trim().to_string(), i))
            .collect(),
        Err(_) => return Vec::new(),
    };
    let cell = |rec: &csv::StringRecord, name: &str| -> String {
        idx.get(name)
            .and_then(|&j| rec.get(j))
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let mut out = Vec::new();
    for rec in rdr.records().flatten() {
        if cell(&rec, "Date") != date {
            continue;
        }
        // Blank / unparseable → the column is UNKNOWN, which is exactly what
        // "incomplete" means here.
        let missing: Vec<&'static str> = dietlog::NUTRIENT_COLUMNS
            .iter()
            .filter(|c| c.expected())
            .filter(|c| cell(&rec, c.csv).parse::<f64>().is_err())
            .map(|c| c.csv)
            .collect();
        if missing.is_empty() {
            continue;
        }
        out.push(IncompleteFoodRow {
            meal: cell(&rec, "Meal"),
            item: cell(&rec, "Item"),
            time: cell(&rec, "Time"),
            missing,
        });
    }
    out
}

/// Parse a metrics-log body into records, skipping blank/malformed lines (a corrupt
/// line never sinks the audit).
pub fn parse_metrics_lines(body: &str) -> Vec<MetricsRecord> {
    body.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<MetricsRecord>(l).ok())
        .collect()
}

/// Select the records whose ISO-8601 timestamp falls on `date` (`YYYY-MM-DD`). This is
/// the TIMESTAMP watermark — the day's slice is defined by the `ts` prefix, not by a
/// fragile line-count offset (the diet audit's workaround, deliberately not cloned).
pub fn records_for_date<'a>(records: &'a [MetricsRecord], date: &str) -> Vec<&'a MetricsRecord> {
    records.iter().filter(|r| r.ts.starts_with(date)).collect()
}

/// Nearest-rank percentile (`p` in [0,100]) over a slice of ms; 0 for an empty slice.
pub fn percentile_ms(values: &[u64], p: u8) -> u64 {
    if values.is_empty() {
        return 0;
    }
    let mut v = values.to_vec();
    v.sort_unstable();
    // Nearest-rank: rank = ceil(p/100 * n), 1-indexed, clamped to [1, n].
    let n = v.len();
    let rank = (((p as f64 / 100.0) * n as f64).ceil() as usize).clamp(1, n);
    v[rank - 1]
}

/// Aggregate a day's records into an [`AuditAgg`].
pub fn aggregate(records: &[&MetricsRecord]) -> AuditAgg {
    use std::collections::BTreeMap;
    let mut rung_counts: BTreeMap<u8, usize> = BTreeMap::new();
    let mut route_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut emergency_by_class: BTreeMap<String, usize> = BTreeMap::new();
    let mut routed_local = 0;
    let mut hosted_fallback = 0;
    let mut validator_failures = 0;
    let mut emergency_activations = 0;
    let mut diet_queued = 0;
    let mut rung2_by_reason: BTreeMap<String, usize> = BTreeMap::new();
    let mut diet_identifiable = 0;
    let mut micros = MicroCompleteness::default();
    let mut walls: Vec<u64> = Vec::with_capacity(records.len());

    for r in records {
        *rung_counts.entry(r.rung).or_default() += 1;
        // Diet turns identifiable in the content-free log: local successes plus rung-2
        // fall-throughs (the latter carry a machine-readable reason).
        if r.route == MetricsRoute::DietLocal {
            diet_identifiable += 1;
        }
        if let Some(reason) = &r.diet_reason {
            *rung2_by_reason.entry(reason.clone()).or_default() += 1;
            diet_identifiable += 1;
        }
        // Nutrient completeness, summed over the local diet turns that appended rows.
        if let Some(m) = &r.diet_micros {
            micros.food_rows += m.food_rows;
            micros.eligible_rows += m.eligible_rows;
            micros.rows_completed += m.rows_completed;
            micros.rows_incomplete += m.rows_incomplete;
            micros.filled += m.filled;
            micros.expected += m.expected;
            if let Some(reason) = &m.reason {
                *micros.by_reason.entry(reason.clone()).or_default() += 1;
            }
        }
        *route_counts
            .entry(route_key(r.route).to_string())
            .or_default() += 1;
        if is_local_route(r.route) {
            routed_local += 1;
        } else {
            hosted_fallback += 1;
        }
        if matches!(r.validator.as_deref(), Some("fail") | Some("advisory-fail")) {
            validator_failures += 1;
        }
        if r.emergency {
            emergency_activations += 1;
            if let Some(cls) = &r.hosted_failure_class {
                *emergency_by_class.entry(cls.clone()).or_default() += 1;
            }
        }
        if r.badge
            .as_deref()
            .is_some_and(|b| b.contains("verify queued"))
        {
            diet_queued += 1;
        }
        walls.push(r.wall_ms);
    }

    AuditAgg {
        total: records.len(),
        routed_local,
        hosted_fallback,
        rung_counts,
        route_counts,
        latency_p50_ms: percentile_ms(&walls, 50),
        latency_p95_ms: percentile_ms(&walls, 95),
        validator_failures,
        emergency_activations,
        emergency_by_class,
        diet_queued,
        rung2_by_reason,
        diet_identifiable,
        micros,
    }
}

/// The kebab route key (for the per-route table).
pub fn route_key(r: MetricsRoute) -> &'static str {
    match r {
        MetricsRoute::Hosted => "hosted",
        MetricsRoute::VaultqaLocal => "vaultqa-local",
        MetricsRoute::DietLocal => "diet-local",
        MetricsRoute::EmergencyLocal => "emergency-local",
    }
}

/// Inputs to the tripwire computation that come from OUTSIDE the metrics log (the bin's
/// content-join + queue reads). Kept separate so the tripwire logic stays pure/tested.
#[derive(Debug, Clone, Default)]
pub struct TripwireInputs {
    /// Local answers whose citations FAILED re-validation against the vault (invented).
    pub invented_citations: usize,
    /// Answers that leaked an injection-style marker (e.g. a `PWNED` line).
    pub injection_leaks: usize,
    /// Age (secs) of the oldest still-pending queued diet entry, if any.
    pub oldest_pending_age_secs: Option<u64>,
    /// How long emergency has been continuously active (secs), if it is active.
    pub emergency_active_age_secs: Option<u64>,
}

/// 24 hours in seconds — the tripwire threshold for a stuck queue / stuck emergency.
pub const TRIPWIRE_AGE_SECS: u64 = 24 * 3600;

/// Compute the ordered list of FIRED tripwire lines (printed first in the note). Empty
/// when clean. Pure over the agg + the external inputs.
pub fn tripwires(agg: &AuditAgg, inp: &TripwireInputs) -> Vec<String> {
    let mut out = Vec::new();
    if inp.invented_citations > 0 {
        out.push(format!(
            "TRIPWIRE: {} local answer(s) cited a file/quote that failed re-validation (invented citation)",
            inp.invented_citations
        ));
    }
    if inp.injection_leaks > 0 {
        out.push(format!(
            "TRIPWIRE: {} answer(s) leaked an injection-style marker",
            inp.injection_leaks
        ));
    }
    if inp
        .emergency_active_age_secs
        .is_some_and(|a| a > TRIPWIRE_AGE_SECS)
    {
        out.push(format!(
            "TRIPWIRE: emergency mode has been active for more than 24h ({}s)",
            inp.emergency_active_age_secs.unwrap()
        ));
    }
    if inp
        .oldest_pending_age_secs
        .is_some_and(|a| a > TRIPWIRE_AGE_SECS)
    {
        out.push(format!(
            "TRIPWIRE: diet verify-replay backlog older than 24h ({}s) — hosted may be stuck down",
            inp.oldest_pending_age_secs.unwrap()
        ));
    }
    // A same-day emergency signal is worth surfacing even under 24h (informational,
    // not a tripwire) — but only the >24h case is a tripwire, per the spec.
    let _ = agg;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // A fixture day of metrics JSONL — the exact shape the bridge writes.
    const FIXTURE: &str = concat!(
        r#"{"ts":"2026-07-15T08:00:00Z","turn_id":"a","mode":"ask","route":"vaultqa-local","model":"local-oss","rung":0,"wall_ms":12000,"citations":1,"validator":"ok","badge":"[local · vault · local-oss]","emergency":false}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:05:00Z","turn_id":"b","mode":"ask","route":"hosted","model":"claude","rung":3,"wall_ms":20000,"badge":"[hosted · claude]","emergency":false}"#,
        "\n",
        r#"{"ts":"2026-07-15T09:00:00Z","turn_id":"c","mode":"ask","route":"emergency-local","model":"local-oss","rung":0,"wall_ms":40000,"validator":"advisory-fail","badge":"[local · emergency · local-oss]","emergency":true,"hosted_failure_class":"network"}"#,
        "\n",
        r#"{"ts":"2026-07-15T10:00:00Z","turn_id":"d","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"badge":"[local · diet · local-diet + hosted verify]","emergency":false}"#,
        "\n",
        r#"{"ts":"2026-07-15T11:00:00Z","turn_id":"e","mode":"tell","route":"emergency-local","model":"local-diet","rung":0,"wall_ms":6000,"badge":"[local · diet · local-diet + verify queued]","emergency":true,"hosted_failure_class":"timeout"}"#,
        "\n",
        // A record from a DIFFERENT day — must be excluded by the timestamp watermark.
        r#"{"ts":"2026-07-14T23:59:00Z","turn_id":"old","mode":"ask","route":"hosted","rung":2,"wall_ms":99000,"emergency":false}"#,
        "\n",
        // A malformed line — must be skipped, never sink the audit.
        "not json at all",
    );

    fn day() -> Vec<MetricsRecord> {
        parse_metrics_lines(FIXTURE)
    }

    #[test]
    fn timestamp_watermark_selects_only_the_target_day() {
        let all = day();
        assert_eq!(
            all.len(),
            6,
            "malformed line skipped, 6 valid records parsed"
        );
        let today = records_for_date(&all, "2026-07-15");
        assert_eq!(today.len(), 5, "the 2026-07-14 record is excluded by ts");
        assert!(today.iter().all(|r| r.ts.starts_with("2026-07-15")));
    }

    #[test]
    fn aggregate_computes_routed_share_rungs_latency_and_emergency() {
        let all = day();
        let today = records_for_date(&all, "2026-07-15");
        let agg = aggregate(&today);
        assert_eq!(agg.total, 5);
        // Local routes: a (vaultqa), c (emergency), d (diet), e (emergency) = 4; hosted: b = 1.
        assert_eq!(agg.routed_local, 4);
        assert_eq!(agg.hosted_fallback, 1);
        assert!((agg.routed_share() - 0.8).abs() < 1e-9);
        // Rungs: four rung-0, one rung-3.
        assert_eq!(agg.rung_counts.get(&0), Some(&4));
        assert_eq!(agg.rung_counts.get(&3), Some(&1));
        // Validator failures: c's advisory-fail = 1.
        assert_eq!(agg.validator_failures, 1);
        // Emergency: c (network) + e (timeout).
        assert_eq!(agg.emergency_activations, 2);
        assert_eq!(agg.emergency_by_class.get("network"), Some(&1));
        assert_eq!(agg.emergency_by_class.get("timeout"), Some(&1));
        // Queued diet: e's badge carries "verify queued".
        assert_eq!(agg.diet_queued, 1);
        // Latency p50/p95 over [12000,20000,40000,8000,6000] sorted [6000,8000,12000,20000,40000].
        assert_eq!(agg.latency_p50_ms, 12000);
        assert_eq!(agg.latency_p95_ms, 40000);
    }

    // A day of DIET metrics lines: local successes (route diet-local), rung-2
    // fall-throughs each carrying a machine-readable `diet_reason`, including two
    // `no_loggable` correct rejections that must be excluded from the failure rate.
    const DIET_DAY: &str = concat!(
        r#"{"ts":"2026-07-15T08:00:00Z","turn_id":"d1","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"emergency":false}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:10:00Z","turn_id":"d2","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"emergency":false}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:20:00Z","turn_id":"r1","mode":"tell","route":"hosted","model":"claude","rung":2,"wall_ms":9000,"emergency":false,"diet_reason":"schema_fail:time"}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:21:00Z","turn_id":"r2","mode":"tell","route":"hosted","model":"claude","rung":2,"wall_ms":9000,"emergency":false,"diet_reason":"schema_fail:time"}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:22:00Z","turn_id":"r3","mode":"tell","route":"hosted","model":"claude","rung":2,"wall_ms":9000,"emergency":false,"diet_reason":"malformed_json"}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:23:00Z","turn_id":"r4","mode":"tell","route":"hosted","model":"claude","rung":2,"wall_ms":9000,"emergency":false,"diet_reason":"no_loggable"}"#,
        "\n",
        r#"{"ts":"2026-07-15T08:24:00Z","turn_id":"r5","mode":"tell","route":"hosted","model":"claude","rung":2,"wall_ms":9000,"emergency":false,"diet_reason":"no_loggable"}"#,
    );

    #[test]
    fn aggregate_counts_rung2_by_reason_and_reports_two_rates() {
        let all = parse_metrics_lines(DIET_DAY);
        let today = records_for_date(&all, "2026-07-15");
        let agg = aggregate(&today);
        // Reason breakdown: 2 schema_fail:time, 1 malformed_json, 2 no_loggable.
        assert_eq!(agg.rung2_by_reason.get("schema_fail:time"), Some(&2));
        assert_eq!(agg.rung2_by_reason.get("malformed_json"), Some(&1));
        assert_eq!(agg.rung2_by_reason.get("no_loggable"), Some(&2));
        assert_eq!(agg.rung2_total(), 5, "five rung-2 diet turns");
        assert_eq!(agg.rung2_no_loggable(), 2, "two correct rejections");
        assert_eq!(agg.rung2_failures(), 3, "three genuine failures");
        // Identifiable diet turns = 2 local successes + 5 rung-2 = 7.
        assert_eq!(agg.diet_identifiable, 7);
        // Raw rate counts every rung-2; failure-only excludes no_loggable.
        assert!((agg.diet_rung2_raw_rate() - 5.0 / 7.0).abs() < 1e-9);
        assert!((agg.diet_rung2_failure_rate() - 3.0 / 7.0).abs() < 1e-9);
        assert!(
            agg.diet_rung2_failure_rate() < agg.diet_rung2_raw_rate(),
            "excluding no_loggable lowers the rate"
        );
    }

    #[test]
    fn percentile_nearest_rank_edges() {
        assert_eq!(percentile_ms(&[], 50), 0);
        assert_eq!(percentile_ms(&[5], 50), 5);
        assert_eq!(percentile_ms(&[5], 95), 5);
        let v = vec![10, 20, 30, 40];
        assert_eq!(percentile_ms(&v, 50), 20); // ceil(0.5*4)=2 → v[1]=20
        assert_eq!(percentile_ms(&v, 100), 40);
    }

    #[test]
    fn tripwires_fire_on_invention_leak_and_stale_queue_or_emergency() {
        let all = day();
        let today = records_for_date(&all, "2026-07-15");
        let agg = aggregate(&today);
        // Clean inputs → no tripwires.
        assert!(tripwires(&agg, &TripwireInputs::default()).is_empty());
        // Each tripwire fires independently.
        let inp = TripwireInputs {
            invented_citations: 1,
            injection_leaks: 2,
            oldest_pending_age_secs: Some(TRIPWIRE_AGE_SECS + 1),
            emergency_active_age_secs: Some(TRIPWIRE_AGE_SECS + 1),
        };
        let fired = tripwires(&agg, &inp);
        assert_eq!(fired.len(), 4, "all four tripwires fire: {fired:?}");
        assert!(fired[0].contains("invented citation"));
        assert!(fired[1].contains("injection-style"));
        // Just under 24h → the age tripwires do NOT fire.
        let inp2 = TripwireInputs {
            oldest_pending_age_secs: Some(TRIPWIRE_AGE_SECS - 1),
            emergency_active_age_secs: Some(TRIPWIRE_AGE_SECS - 1),
            ..Default::default()
        };
        assert!(
            tripwires(&agg, &inp2).is_empty(),
            "under-24h ages are not tripwires"
        );
    }
    // ---- Nutrient completeness ---------------------------------------------

    /// A day of DIET metrics lines carrying the nutrient-completeness object: one fully
    /// complete local turn, one partially complete turn, and one turn whose completion
    /// block was unusable.
    const MICRO_LINES: &str = concat!(
        r#"{"ts":"2026-07-25T08:00:00Z","turn_id":"m1","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"emergency":false,"diet_micros":{"food_rows":1,"eligible_rows":1,"rows_completed":1,"rows_incomplete":0,"filled":7,"expected":7}}"#,
        "\n",
        r#"{"ts":"2026-07-25T09:00:00Z","turn_id":"m2","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"emergency":false,"diet_micros":{"food_rows":3,"eligible_rows":2,"rows_completed":2,"rows_incomplete":1,"filled":13,"expected":14,"reason":"micros_incomplete"}}"#,
        "\n",
        r#"{"ts":"2026-07-25T10:00:00Z","turn_id":"m3","mode":"tell","route":"diet-local","model":"local-diet","rung":0,"wall_ms":8000,"emergency":false,"diet_micros":{"food_rows":1,"eligible_rows":1,"rows_completed":0,"rows_incomplete":1,"filled":0,"expected":7,"reason":"micro_complete_unparseable"}}"#,
        "\n",
        r#"{"ts":"2026-07-25T11:00:00Z","turn_id":"m4","mode":"ask","route":"hosted","model":"claude","rung":0,"wall_ms":9000,"emergency":false}"#,
        "\n",
    );

    #[test]
    fn aggregate_sums_nutrient_completeness_and_reason_codes() {
        let all = parse_metrics_lines(MICRO_LINES);
        assert_eq!(
            all.len(),
            4,
            "all four lines parse (the object is optional)"
        );
        let day = records_for_date(&all, "2026-07-25");
        let m = aggregate(&day).micros;
        assert_eq!(m.food_rows, 5, "1 + 3 + 1 food rows");
        assert_eq!(m.eligible_rows, 4, "the composite row is excluded upstream");
        assert_eq!(m.rows_completed, 3);
        assert_eq!(m.rows_incomplete, 2);
        assert_eq!((m.filled, m.expected), (20, 28));
        assert_eq!(m.incomplete_rate(), 0.5, "2 of 4 eligible rows");
        assert!((m.cell_fill_rate() - 20.0 / 28.0).abs() < 1e-9);
        assert_eq!(m.by_reason.get("micros_incomplete"), Some(&1));
        assert_eq!(m.by_reason.get("micro_complete_unparseable"), Some(&1));
        // A hosted turn contributes nothing (no diet_micros object).
        assert_eq!(m.by_reason.len(), 2);
    }

    #[test]
    fn a_day_with_no_diet_turns_reports_empty_completeness() {
        let all = parse_metrics_lines(FIXTURE);
        let day = records_for_date(&all, "2026-07-15");
        let m = aggregate(&day).micros;
        assert_eq!(m.food_rows, 0);
        assert_eq!(m.incomplete_rate(), 0.0, "no eligible rows → 0, not NaN");
        assert_eq!(
            m.cell_fill_rate(),
            1.0,
            "nothing expected → nothing missing"
        );
        assert!(m.by_reason.is_empty());
    }

    #[test]
    fn incomplete_food_rows_names_the_rows_to_repair_by_hand() {
        // Row 1: complete (all seven expected columns).            → not listed
        // Row 2: potassium + calcium blank.                        → listed
        // Row 3: a ragged legacy row that stops before the tail.    → listed
        // Row 4: complete but on ANOTHER date.                     → not listed
        let csv = format!(
            "{h}\n\
             2026-07-25,Snack,Banana,1,serving,,,105,1.3,0.4,27,basis,10:40,Snack,3.1,1,0.1,14.4,422,6,,32\n\
             2026-07-25,Lunch,Soup,1,bowl,,,220,8,6,30,,12:00,Lunch,7,600,1.5,4,,,,20\n\
             2026-07-25,Breakfast,Eggs,3,ea,,,210,18,15,1,\n\
             2026-07-24,Snack,Banana,1,serving,,,105,1.3,0.4,27,,10:40,Snack,3.1,1,0.1,14.4,422,6,,32\n",
            h = dietlog::food_log_header()
        );
        let rows = incomplete_food_rows(&csv, "2026-07-25");
        assert_eq!(rows.len(), 2, "two incomplete rows for the date: {rows:?}");
        assert_eq!(rows[0].item, "Soup");
        assert_eq!(rows[0].meal, "Lunch");
        assert_eq!(rows[0].time, "12:00");
        assert_eq!(rows[0].missing, vec!["Potassium_mg", "Calcium_mg"]);
        assert_eq!(rows[1].item, "Eggs");
        assert_eq!(
            rows[1].missing,
            vec![
                "Fiber_g",
                "Sodium_mg",
                "SatFat_g",
                "Sugar_g",
                "Potassium_mg",
                "Calcium_mg",
                "Magnesium_mg"
            ],
            "a short legacy row is missing the whole tail"
        );
        // Omega-3 is MarineOnly, so a blank there is never reported as missing.
        for r in &rows {
            assert!(!r.missing.contains(&"Omega3_mg"));
        }
        // An empty / header-only log yields nothing rather than erroring.
        assert!(incomplete_food_rows("", "2026-07-25").is_empty());
        assert!(
            incomplete_food_rows(&format!("{}\n", dietlog::food_log_header()), "2026-07-25")
                .is_empty()
        );
    }
}
