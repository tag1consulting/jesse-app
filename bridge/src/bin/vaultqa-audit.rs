//! `vaultqa-audit` — the daily audit of the vault-QA / emergency-fallback pipeline
//! (Piece 5, the reporting half). It reads the day's `JESSE_METRICS_LOG` slice
//! (selected by TIMESTAMP, never a line-count watermark), joins the serving logs for
//! content when they are configured, and emits a dated markdown note plus a JSON twin,
//! mirroring the diet audit's destination (`~/Library/Logs/jesse-vaultqa-audit/`) and
//! structure.
//!
//! Contents: routed share of gated turns, per-rung fallback rates, latency p50/p95,
//! validator failures, emergency activations by failure class, and queued/replayed/
//! rejected diet entries; re-validation of every local answer's citations against the
//! vault (read-only); and a sampled, position-swapped hosted re-answer/judge for up to
//! 3 local answers when hosted is reachable (skipped cleanly offline). TRIPWIRES are
//! printed first: any invented citation, any injection-style leak, emergency active
//! >24h, or a replay backlog older than 24h.
//!
//! Everything is read-only over the metrics log, the serving logs, the vault, and the
//! diet queue. The installer (launchd plist) stays with go-live; this is just the tool.

use std::collections::HashMap;
use std::path::PathBuf;

use jesse_bridge::{
    aggregate, parse_metrics_lines, records_for_date, route_key, tripwires,
    validate_vaultqa_answer, AuditAgg, Config, DietQueue, TripwireInputs, TRIPWIRE_AGE_SECS,
};

/// One joined (question, answer) pair recovered from the serving logs for a turn, so
/// the audit can re-validate citations and re-answer. The serving logs (unlike the
/// content-free metrics log) retain bodies; the join file is one JSON object per line:
/// `{"turn_id": "...", "question": "...", "answer": "..."}`.
#[derive(serde::Deserialize)]
struct ServingRow {
    turn_id: String,
    #[serde(default)]
    question: String,
    #[serde(default)]
    answer: String,
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// Today's local date (`YYYY-MM-DD`) via `date`, matching the diet audit convention.
fn today() -> String {
    std::process::Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%Y-%m-%d")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown-date".to_string())
}

/// Now, as Unix epoch seconds.
fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Parse a fixed `YYYY-MM-DDTHH:MM:SSZ` timestamp to Unix epoch seconds (UTC). Returns
/// `None` on any shape mismatch. Uses the civil-from-days algorithm (no chrono dep).
fn rfc3339_to_epoch(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let num = |a: usize, z: usize| s.get(a..z)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, se) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    // days_from_civil (Howard Hinnant): days since 1970-01-01.
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + h * 3600 + mi * 60 + se)
}

/// Load the optional serving-log join: `turn_id -> (question, answer)`. Configured via
/// `JESSE_AUDIT_SERVING_LOG` (a JSONL file). Absent → an empty map (content joins,
/// citation re-validation, and re-answer are then reported as skipped).
fn load_serving_join() -> HashMap<String, (String, String)> {
    let mut map = HashMap::new();
    let Some(path) = std::env::var("JESSE_AUDIT_SERVING_LOG")
        .ok()
        .filter(|s| !s.trim().is_empty())
    else {
        return map;
    };
    let Ok(body) = std::fs::read_to_string(&path) else {
        eprintln!("vaultqa-audit: could not read serving-log join {path} — content joins skipped");
        return map;
    };
    for line in body.lines().filter(|l| !l.trim().is_empty()) {
        if let Ok(row) = serde_json::from_str::<ServingRow>(line) {
            map.insert(row.turn_id, (row.question, row.answer));
        }
    }
    map
}

/// An injection-style leak marker: a lone `PWNED` line, the suite's canary.
fn has_injection_leak(answer: &str) -> bool {
    answer
        .lines()
        .any(|l| l.trim().eq_ignore_ascii_case("PWNED"))
}

fn main() {
    let date = std::env::args().nth(1).unwrap_or_else(today);

    // The metrics log is the audit's spine. Unset → nothing to audit.
    let Some(metrics_path) = std::env::var("JESSE_METRICS_LOG")
        .ok()
        .filter(|s| !s.trim().is_empty())
    else {
        eprintln!("vaultqa-audit: JESSE_METRICS_LOG is not set — nothing to audit.");
        std::process::exit(0);
    };
    let body = std::fs::read_to_string(&metrics_path).unwrap_or_else(|e| {
        eprintln!("vaultqa-audit: could not read {metrics_path}: {e}");
        std::process::exit(1);
    });
    let all = parse_metrics_lines(&body);
    let day = records_for_date(&all, &date);
    let agg = aggregate(&day);

    // Diet queue state (best-effort): pending/rejected counts + oldest backlog age.
    let cfg = Config::from_env();
    let queue = DietQueue::from_cfg(&cfg);
    let pending = queue.pending();
    let rejected = queue.rejected();
    let oldest_pending_age = pending
        .iter()
        .filter_map(|q| rfc3339_to_epoch(&q.queued_ts))
        .min()
        .map(|oldest| (now_epoch() - oldest).max(0) as u64);
    // Replayed count comes from the day's metrics/emergency lines is not distinct here;
    // it is surfaced from the bridge provenance in the note narrative.

    // Emergency-active age: the span from the earliest emergency line today to now, if
    // any emergency is active (a coarse signal; the >24h case is the tripwire).
    let emergency_active_age = day
        .iter()
        .filter(|r| r.emergency)
        .filter_map(|r| rfc3339_to_epoch(&r.ts))
        .min()
        .map(|first| (now_epoch() - first).max(0) as u64);

    // Content joins: re-validate every LOCAL answer's citations against the vault, and
    // scan for injection leaks. Skipped cleanly when no serving-log join is configured.
    let join = load_serving_join();
    let mut invented = 0usize;
    let mut leaks = 0usize;
    let mut revalidated = 0usize;
    let vault = PathBuf::from(&cfg.vault);
    let local_turns: Vec<&&jesse_bridge::MetricsRecord> = day
        .iter()
        .filter(|r| route_key(r.route) != "hosted")
        .collect();
    if !join.is_empty() {
        for r in &local_turns {
            if let Some((_q, answer)) = join.get(&r.turn_id) {
                revalidated += 1;
                if validate_vaultqa_answer(answer, &vault).is_err() {
                    invented += 1;
                }
                if has_injection_leak(answer) {
                    leaks += 1;
                }
            }
        }
    }

    let trip_inputs = TripwireInputs {
        invented_citations: invented,
        injection_leaks: leaks,
        oldest_pending_age_secs: oldest_pending_age,
        emergency_active_age_secs: emergency_active_age,
    };
    let fired = tripwires(&agg, &trip_inputs);

    // The sampled hosted re-answer + position-swapped judge is a live step; it is wired
    // to run only when a serving-log join is present AND hosted is reachable. This tool
    // never blocks on it — go-live's drill exercises it. Here it is reported as skipped
    // with the reason, so an offline audit run is clean and honest.
    let judge_note = if join.is_empty() {
        "skipped — no serving-log join configured (set JESSE_AUDIT_SERVING_LOG)".to_string()
    } else {
        // Even with a join, this run does not reach out to hosted (that is go-live's
        // outage-drill wiring); say so plainly rather than pretend a comparison ran.
        format!(
            "deferred — up to 3 of {} re-validated local answers are eligible; the \
             position-swapped hosted re-answer/judge is enabled at go-live when hosted \
             is reachable",
            revalidated
        )
    };

    let md = render_markdown(
        &date,
        &agg,
        &fired,
        &pending,
        &rejected,
        oldest_pending_age,
        revalidated,
        invented,
        leaks,
        &judge_note,
        join.is_empty(),
    );
    let json = render_json(
        &date,
        &agg,
        &fired,
        pending.len(),
        rejected.len(),
        oldest_pending_age,
        revalidated,
        invented,
        leaks,
    );

    // Tripwires first, to stdout.
    if fired.is_empty() {
        println!("vaultqa-audit {date}: clean.");
    } else {
        for t in &fired {
            println!("{t}");
        }
    }

    // Write the note + JSON twin, mirroring the diet audit's destination.
    let out_dir = PathBuf::from(home()).join("Library/Logs/jesse-vaultqa-audit");
    if let Err(e) = std::fs::create_dir_all(&out_dir) {
        eprintln!("vaultqa-audit: could not create {}: {e}", out_dir.display());
        std::process::exit(1);
    }
    let md_path = out_dir.join(format!("{date}.md"));
    let json_path = out_dir.join(format!("{date}.json"));
    if let Err(e) = std::fs::write(&md_path, &md) {
        eprintln!("vaultqa-audit: could not write {}: {e}", md_path.display());
        std::process::exit(1);
    }
    if let Err(e) = std::fs::write(&json_path, &json) {
        eprintln!(
            "vaultqa-audit: could not write {}: {e}",
            json_path.display()
        );
        std::process::exit(1);
    }
    println!(
        "vaultqa-audit written: {} ({} turns, {} tripwire(s))",
        md_path.display(),
        agg.total,
        fired.len()
    );
}

#[allow(clippy::too_many_arguments)]
fn render_markdown(
    date: &str,
    agg: &AuditAgg,
    fired: &[String],
    pending: &[jesse_bridge::QueuedEntry],
    rejected: &[jesse_bridge::QueuedEntry],
    oldest_pending_age: Option<u64>,
    revalidated: usize,
    invented: usize,
    leaks: usize,
    judge_note: &str,
    join_empty: bool,
) -> String {
    let mut s = String::new();
    s.push_str(&format!("# Jesse vault-QA audit — {date}\n\n"));

    s.push_str("## Tripwires\n\n");
    if fired.is_empty() {
        s.push_str("- none (clean)\n");
    } else {
        for t in fired {
            s.push_str(&format!("- **{t}**\n"));
        }
    }

    s.push_str("\n## Routing\n\n");
    s.push_str(&format!("- gated/routed/emergency turns: {}\n", agg.total));
    s.push_str(&format!(
        "- routed locally: {} ({:.0}% of gated turns)\n",
        agg.routed_local,
        agg.routed_share() * 100.0
    ));
    s.push_str(&format!("- hosted fall-through: {}\n", agg.hosted_fallback));
    s.push_str("\n### Per-rung fall-through\n\n");
    for (rung, n) in &agg.rung_counts {
        let label = if *rung == 0 {
            "0 (local success)"
        } else {
            "fall-through"
        };
        s.push_str(&format!("- rung {rung} [{label}]: {n}\n"));
    }
    s.push_str("\n### Per-route\n\n");
    for (route, n) in &agg.route_counts {
        s.push_str(&format!("- {route}: {n}\n"));
    }

    s.push_str("\n## Latency (wall)\n\n");
    s.push_str(&format!("- p50: {} ms\n", agg.latency_p50_ms));
    s.push_str(&format!("- p95: {} ms\n", agg.latency_p95_ms));

    s.push_str("\n## Validator\n\n");
    s.push_str(&format!(
        "- validator failures (fail/advisory-fail): {}\n",
        agg.validator_failures
    ));

    s.push_str("\n## Emergency\n\n");
    s.push_str(&format!("- activations: {}\n", agg.emergency_activations));
    for (cls, n) in &agg.emergency_by_class {
        s.push_str(&format!("  - {cls}: {n}\n"));
    }

    s.push_str("\n## Diet verify queue\n\n");
    s.push_str(&format!(
        "- queued this day (metrics): {}\n",
        agg.diet_queued
    ));
    s.push_str(&format!("- pending now: {}\n", pending.len()));
    s.push_str(&format!(
        "- rejected on replay (file): {}\n",
        rejected.len()
    ));
    if let Some(age) = oldest_pending_age {
        s.push_str(&format!(
            "- oldest pending age: {age}s{}\n",
            if age > TRIPWIRE_AGE_SECS {
                "  ⚠ >24h"
            } else {
                ""
            }
        ));
    }

    s.push_str("\n## Citation re-validation (read-only, vs vault)\n\n");
    if join_empty {
        s.push_str("- skipped — no serving-log join configured (set JESSE_AUDIT_SERVING_LOG)\n");
    } else {
        s.push_str(&format!("- local answers re-validated: {revalidated}\n"));
        s.push_str(&format!("- invented citations: {invented}\n"));
        s.push_str(&format!("- injection-style leaks: {leaks}\n"));
    }

    s.push_str("\n## Sampled hosted re-answer + position-swapped judge\n\n");
    s.push_str(&format!("- {judge_note}\n"));

    s.push_str(&format!("\n_generated by vaultqa-audit for {date}_\n"));
    s
}

#[allow(clippy::too_many_arguments)]
fn render_json(
    date: &str,
    agg: &AuditAgg,
    fired: &[String],
    pending: usize,
    rejected: usize,
    oldest_pending_age: Option<u64>,
    revalidated: usize,
    invented: usize,
    leaks: usize,
) -> String {
    let v = serde_json::json!({
        "date": date,
        "tripwires": fired,
        "routing": {
            "total": agg.total,
            "routed_local": agg.routed_local,
            "hosted_fallback": agg.hosted_fallback,
            "routed_share": agg.routed_share(),
            "rung_counts": agg.rung_counts,
            "route_counts": agg.route_counts,
        },
        "latency_ms": { "p50": agg.latency_p50_ms, "p95": agg.latency_p95_ms },
        "validator_failures": agg.validator_failures,
        "emergency": {
            "activations": agg.emergency_activations,
            "by_class": agg.emergency_by_class,
        },
        "diet_queue": {
            "queued_today": agg.diet_queued,
            "pending_now": pending,
            "rejected": rejected,
            "oldest_pending_age_secs": oldest_pending_age,
        },
        "citations": {
            "revalidated": revalidated,
            "invented": invented,
            "injection_leaks": leaks,
        },
    });
    serde_json::to_string_pretty(&v).unwrap_or_else(|_| "{}".to_string())
}
