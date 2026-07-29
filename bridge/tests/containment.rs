//! The containment battery as a MERGE GATE.
//!
//! Two halves, deliberately split by cost:
//!
//!   * The always-on half reads the COMMITTED record (`bridge/containment.toml`) and asserts
//!     it is complete and self-consistent: every (capability, MCP server set) pair the bridge
//!     spawns has a row, every row carries every probe, and no probe is recorded in a state
//!     the scoring rules could not have produced. This costs nothing and runs in CI, so a new
//!     row or a new probe cannot be added without recording it — the failure mode where a
//!     file that covered nine tenths of the postures reads as though it covered all of them.
//!
//!   * The `#[ignore]`d half RUNS the battery live against the pinned agent binary and
//!     compares it to the record. That is the real gate, and it is opt-in because each probe
//!     is a real headless turn: it costs money and minutes.
//!
//!         cargo test --test containment -- --ignored --nocapture
//!
//! Re-run the live half on every bump of the pinned binary and on every change to the
//! containment posture. A probe that flips in EITHER direction fails until a human
//! re-records it on purpose (`cargo run --bin containment-probe -- --write`).

use jesse_bridge::*;

/// The committed record, embedded at COMPILE time — the same mechanism the startup gate uses,
/// exercised here so a record that stopped parsing breaks the build rather than a deploy.
const RECORD: &str = include_str!("../containment.toml");

fn record() -> BatteryResults {
    parse_results(RECORD).expect("the committed containment record must parse")
}

#[test]
fn the_record_covers_every_row_the_bridge_actually_spawns() {
    let r = record();
    assert_eq!(r.harness, CLAUDE_CODE_ID);
    assert_eq!(
        r.rows.len(),
        SHIPPED_ROWS.len(),
        "every (capability, MCP set) pair the bridge spawns needs its own row — a level \
         passes only when every MCP set recorded at that level passes"
    );
    for row in SHIPPED_ROWS {
        let rec = r
            .row(capability_label(row.capability), row.mcp.label())
            .unwrap_or_else(|| panic!("no recorded row for {}", row.label()));
        assert_eq!(
            rec.toolset_args,
            capability_args(&probe_config(), row.capability),
            "{}: the recorded toolset argv must be the one the shipped builder produces — a \
             row that describes a posture nothing spawns gates nothing",
            row.label()
        );
    }
}

#[test]
fn every_row_records_every_probe() {
    let r = record();
    for row in &r.rows {
        for p in PROBES {
            let rec = row
                .probe(p.id)
                .unwrap_or_else(|| panic!("{}: probe {} was never recorded", row.label(), p.id));
            assert_eq!(
                rec.class,
                p.class.label(),
                "{}: {} class",
                row.label(),
                p.id
            );
        }
        assert_eq!(
            row.probes.len(),
            PROBES.len(),
            "{}: the record carries a probe this build does not define",
            row.label()
        );
    }
}

#[test]
fn no_probe_is_recorded_in_a_state_the_scoring_rules_could_not_produce() {
    let r = record();
    for row in &r.rows {
        let key = ContainmentRow {
            capability: parse_capability(&row.capability).expect("a known capability"),
            mcp: McpSet::parse(&row.mcp_set).expect("a known MCP set"),
        };
        for p in PROBES {
            let rec = row.probe(p.id).expect("present, per the test above");
            let verdict = rec.verdict_enum().expect("a known verdict");
            // Re-score the recorded verdict from scratch. The status and the required-verdict
            // in the file must be exactly what this build's rules say they are, so a
            // hand-edited "pass" cannot survive.
            let rescored = score_probe(p, &key, verdict, rec.evidence.clone());
            assert_eq!(
                rescored.status,
                rec.status,
                "{}: {} is recorded {} but scores as {}",
                row.label(),
                p.id,
                rec.status,
                rescored.status
            );
            assert_eq!(rescored.required, rec.required, "{}: {}", row.label(), p.id);
            assert_ne!(
                verdict,
                ProbeVerdict::Inconclusive,
                "{}: {} was recorded inconclusive — nothing was proven, so it must be re-run",
                row.label(),
                p.id
            );
        }
        let failing = row.probes.iter().any(|p| p.is_failing());
        assert_eq!(
            row.status == "failing",
            failing,
            "{}: row status must follow its probes",
            row.label()
        );
    }
    assert_eq!(
        r.gate == "fail",
        r.rows.iter().any(|row| row.status == "failing"),
        "the top-level gate must follow the rows"
    );
}

/// A row whose hard gates are not met is NOT a combination this project ships. The record is
/// allowed to say so — that is the point of recording the truth — but the fact must be
/// visible here rather than buried in a file nobody reads, so this test names the failures
/// and the known-open findings in its output.
#[test]
fn the_record_states_its_failures_and_its_known_open_findings_out_loud() {
    let r = record();
    let failures = r.hard_gate_failures();
    let open = r.known_open();
    eprintln!(
        "containment record ({} @ {}, taken {}): gate {}",
        r.harness, r.binary_version, r.recorded, r.gate
    );
    for f in &failures {
        eprintln!("  HARD GATE NOT MET: {f}");
    }
    for o in &open {
        eprintln!("  known-open: {o}");
    }
    // The known-open set is never empty on the Write row: the writes-on allowlist grants
    // `Bash(git:*)` with unrestricted arguments, which reaches the network and leaves a
    // process behind. If that ever becomes empty, the posture changed and the record needs
    // re-taking rather than quiet acceptance.
    assert!(
        !open.is_empty(),
        "no known-open baselines at all — either the posture tightened (re-record) or the \
         battery stopped probing"
    );
}

/// The live gate. Ignored by default: every probe is a real headless turn.
#[tokio::test]
#[ignore = "spawns real agent turns — costs money and minutes; run explicitly"]
async fn the_battery_still_matches_the_record() {
    let recorded = record();
    let cfg = probe_config();
    let fresh = run_battery(&cfg, &BatteryOptions::default())
        .await
        .expect("the battery must run");
    eprintln!(
        "battery: gate {}, ${:.2} spent",
        fresh.results.gate, fresh.cost_usd
    );
    if recorded.binary_version != fresh.results.binary_version {
        eprintln!(
            "NOTE: recorded against {}, ran against {} — the battery is re-run on every \
             binary version bump.",
            recorded.binary_version, fresh.results.binary_version
        );
    }
    let drift = compare_results(&recorded, &fresh.results);
    assert!(
        drift.is_empty(),
        "a probe moved since the record was taken; re-record it on purpose if that was \
         intended:\n  {}",
        drift.join("\n  ")
    );
    assert_eq!(
        fresh.results.hard_gate_failures(),
        recorded.hard_gate_failures(),
        "the set of unmet hard gates changed"
    );
}

/// The config the battery probes with: whatever this host supplies for the binary path, and
/// the SHIPPED toolset posture (`run_battery` forces that itself; this is here so the
/// always-on test above compares against the same thing).
fn probe_config() -> Config {
    let mut cfg = Config::from_env();
    cfg.allowed_tools = DEFAULT_ALLOWED_TOOLS.to_string();
    cfg.disallowed_tools = DEFAULT_DISALLOWED_TOOLS.to_string();
    cfg
}
