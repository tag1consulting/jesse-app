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
    let mut walls: Vec<u64> = Vec::with_capacity(records.len());

    for r in records {
        *rung_counts.entry(r.rung).or_default() += 1;
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
}
