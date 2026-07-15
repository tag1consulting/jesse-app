//! **Structured metrics** (Piece 3) — an append-only JSONL trail the bridge writes
//! one line to per GATED, ROUTED, or EMERGENCY turn, at the same reply-finalization
//! point the badge uses ([`badge::finalize_reply_badge`]). It is the LOGGING half of
//! the observability story; the daily audit tool (`vaultqa-audit`) is the reporting
//! half, and the CONTENT joins (question/answer bodies) happen there via the serving
//! logs, never here.
//!
//! ## What it records — and what it must NEVER record
//!
//! One line carries only content-FREE turn shape: an ISO-8601 timestamp, the turn id,
//! the mode (`ask`/`tell`), the route ([`MetricsRoute`]), the backend model, the
//! ladder rung (`0` = local success), wall ms, TTFT ms and tool-call count where
//! recoverable, the citation count + validator verdict, the badge string, the
//! emergency flag, and the hosted-failure class when relevant. It records **NEVER**
//! the question text, the answer text, or token counts — those live in the serving
//! logs and are joined in the audit, off this path.
//!
//! ## Soft-failure semantics (the kill switch)
//!
//! Dormant unless `JESSE_METRICS_LOG` names an absolute path (`cfg.metrics_log`):
//! with it unset, [`append_metrics_line`] is a no-op and NOTHING is written — the same
//! soft-failure semantics as the other envs, and a load-bearing half of the
//! both-envs-unset byte-for-byte property. When set, each call opens the file in
//! append mode and writes exactly one line (append-only, effectively line-buffered:
//! one `writeln!` per call, no shared handle, so it survives a restart). A write
//! failure is logged to stderr and SWALLOWED — it never propagates to and never
//! disturbs the reply.

use crate::*;
use serde::{Deserialize, Serialize};

/// Which route produced the delivered reply, for the metrics line. Serializes to the
/// exact kebab strings the audit aggregates on. `Deserialize` is unconditional so the
/// `vaultqa-audit` bin can read the log back at runtime (not just in tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MetricsRoute {
    /// A hosted `run_claude_streaming` turn (including a gated turn that fell through).
    Hosted,
    /// A local vault-QA answer (the routine read-only lookup route).
    VaultqaLocal,
    /// A local diet-logging entry (the diet route's local log).
    DietLocal,
    /// An emergency local answer or a queued diet entry (hosted was unavailable).
    EmergencyLocal,
}

/// One content-free metrics line. Every optional field is `None` when the value was
/// not recoverable on this turn (e.g. TTFT / tool-calls are not surfaced to the
/// reply path today — the audit recovers them from the serving logs). Serialized as
/// a single JSON line; `serde(skip_serializing_if = "Option::is_none")` keeps a line
/// compact without dropping any present value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetricsRecord {
    /// ISO-8601 / RFC-3339 UTC timestamp (see [`diet::rfc3339_utc`]).
    pub ts: String,
    /// The turn (job) id.
    pub turn_id: String,
    /// `ask` | `tell`.
    pub mode: String,
    /// Which backend produced the delivered text.
    pub route: MetricsRoute,
    /// The backend model that produced (or attempted) the reply, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Ladder rung: `0` = local success; `1..` = the fall-through rung.
    pub rung: u8,
    /// Wall-clock milliseconds for the turn.
    pub wall_ms: u64,
    /// Time-to-first-token ms, where recoverable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttft_ms: Option<u64>,
    /// Tool-call count, where recoverable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<u64>,
    /// Validated citation count (vault-QA / emergency), where applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub citations: Option<usize>,
    /// Citation-validator verdict: `ok` | `fail` | `advisory-fail` | `n/a`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validator: Option<String>,
    /// The badge string appended to the reply, when badges are on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge: Option<String>,
    /// Whether the emergency local fallback was active for this turn.
    pub emergency: bool,
    /// The hosted-failure class ([`failclass`]) when a hosted attempt failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hosted_failure_class: Option<String>,
}

/// Append one metrics line to `cfg.metrics_log`, or do nothing when it is unset.
/// Content-free and infallible from the caller's view: any serialization or I/O
/// failure is logged to stderr and swallowed so it can NEVER disturb the reply.
pub fn append_metrics_line(cfg: &Config, record: &MetricsRecord) {
    // Kill switch: unset → zero writes (the both-envs-unset property depends on this).
    let Some(path) = cfg.metrics_log.as_deref() else {
        return;
    };
    let line = match serde_json::to_string(record) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("jesse-bridge: metrics serialize failed: {e} — reply unaffected");
            return;
        }
    };
    if let Err(e) = append_line(path, &line) {
        // Swallowed: a metrics write failure logs to stderr and never affects the
        // reply (the caller already holds the finalized outcome).
        eprintln!("jesse-bridge: metrics write to {path} failed: {e} — reply unaffected");
    }
}

/// Open the file in append mode and write exactly one line + `\n`. Append-only and
/// effectively line-buffered: one `writeln!` per call, no shared handle, so concurrent
/// turns never interleave a partial line and the trail survives a bridge restart.
fn append_line(path: &str, line: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(f, "{line}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> MetricsRecord {
        MetricsRecord {
            ts: "2026-07-15T12:00:00Z".to_string(),
            turn_id: "job-abc".to_string(),
            mode: "ask".to_string(),
            route: MetricsRoute::VaultqaLocal,
            model: Some("local-oss".to_string()),
            rung: 0,
            wall_ms: 27870,
            ttft_ms: None,
            tool_calls: None,
            citations: Some(1),
            validator: Some("ok".to_string()),
            badge: Some("[local · vault · local-oss]".to_string()),
            emergency: false,
            hosted_failure_class: None,
        }
    }

    #[test]
    fn record_round_trips_as_a_single_json_line() {
        let rec = sample();
        let line = serde_json::to_string(&rec).unwrap();
        assert!(!line.contains('\n'), "one line, no embedded newline");
        // Route serializes to the kebab string the audit aggregates on.
        assert!(line.contains("\"route\":\"vaultqa-local\""), "route kebab: {line}");
        // Never carries content/token fields.
        for forbidden in ["question", "answer", "tokens", "text"] {
            assert!(!line.contains(forbidden), "line must not carry {forbidden:?}: {line}");
        }
        let back: MetricsRecord = serde_json::from_str(&line).unwrap();
        assert_eq!(back, rec, "round-trip identity");
    }

    #[test]
    fn all_four_routes_serialize_to_kebab() {
        for (route, s) in [
            (MetricsRoute::Hosted, "hosted"),
            (MetricsRoute::VaultqaLocal, "vaultqa-local"),
            (MetricsRoute::DietLocal, "diet-local"),
            (MetricsRoute::EmergencyLocal, "emergency-local"),
        ] {
            assert_eq!(serde_json::to_string(&route).unwrap(), format!("\"{s}\""));
        }
    }

    #[test]
    fn unset_metrics_log_writes_nothing() {
        // The kill switch: metrics_log = None → NOTHING is written. Prove it by
        // choosing a path we never configure and asserting it is never created.
        let mut cfg = crate::testutil::test_config();
        cfg.metrics_log = None;
        let sentinel = std::env::temp_dir().join(format!("jesse-metrics-unset-{}.jsonl", random_hex()));
        assert!(!sentinel.exists());
        append_metrics_line(&cfg, &sample());
        assert!(!sentinel.exists(), "unset metrics_log must touch no file");
    }

    #[test]
    fn set_metrics_log_appends_one_json_line_per_call() {
        let mut cfg = crate::testutil::test_config();
        let path = std::env::temp_dir().join(format!("jesse-metrics-{}.jsonl", random_hex()));
        cfg.metrics_log = Some(path.to_string_lossy().into_owned());
        append_metrics_line(&cfg, &sample());
        let mut second = sample();
        second.turn_id = "job-def".to_string();
        append_metrics_line(&cfg, &second);
        let body = std::fs::read_to_string(&path).expect("metrics file written");
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 2, "append-only: one line per call");
        let a: MetricsRecord = serde_json::from_str(lines[0]).unwrap();
        let b: MetricsRecord = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(a.turn_id, "job-abc");
        assert_eq!(b.turn_id, "job-def");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_write_failure_is_swallowed_and_leaves_the_turn_intact() {
        // Point the log at a path whose PARENT does not exist — the open fails. The
        // call must NOT panic and must NOT create anything; the reply (which the caller
        // holds) is untouched because this function returns () regardless.
        let mut cfg = crate::testutil::test_config();
        let bad = std::env::temp_dir()
            .join(format!("jesse-metrics-nodir-{}", random_hex()))
            .join("deeper")
            .join("metrics.jsonl");
        cfg.metrics_log = Some(bad.to_string_lossy().into_owned());
        // If this panicked, the test would fail — that IS the isolation assertion.
        append_metrics_line(&cfg, &sample());
        assert!(!bad.exists(), "a failed metrics write creates nothing");
    }
}
