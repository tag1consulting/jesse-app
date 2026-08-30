//! The containment battery as a MERGE GATE.
//!
//! This target requires the `containment-probe` feature, because it reads the probe TABLE
//! (`PROBES`) to check the record against — and that table, with the runner and the probe
//! prompts, is compiled out of the serving binary. CI runs `cargo test --features
//! containment-probe`, so the always-on half below still gates every merge; a bare
//! `cargo test` skips this file entirely.
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
//! re-records it on purpose (`cargo run --features containment-probe --bin
//! containment-probe -- --write`).

use jesse_bridge::*;

/// EVERY committed record, embedded at COMPILE time so a record that stopped parsing breaks
/// the build rather than a deploy — the same set `levelgate.rs` embeds and gates against.
///
/// It ranges over the whole set rather than over `containment.toml` alone, because a file
/// that checked one harness's record while a second one shipped unchecked would read as
/// though it checked them all. That is the exact failure mode the always-on half exists to
/// prevent one row at a time; a harness is just a bigger unit of the same mistake.
fn records() -> Vec<(&'static str, BatteryResults)> {
    CONTAINMENT_RECORDS
        .iter()
        .map(|(id, text)| {
            (
                *id,
                parse_results(text)
                    .unwrap_or_else(|e| panic!("the committed record for {id} must parse: {e}")),
            )
        })
        .collect()
}

/// The harness that owns a record. Built directly rather than taken from a shipped registry,
/// because a record must be checkable BEFORE its harness is registered — that ordering is the
/// whole point of recording a battery first.
fn harness_for(id: &str) -> Box<dyn Harness> {
    match id {
        CODEX_ID => Box::new(Codex),
        CLAUDE_CODE_ID => Box::new(ClaudeCode),
        DIRECT_ID => Box::new(Direct),
        other => panic!("no harness for embedded record '{other}'"),
    }
}

/// **THE SPAWNED RECORDS ONLY.** Three of the tests below hold a record against `PROBES` —
/// the bridge's own list of adversarial probes — and that list describes escapes attempted by
/// a CHILD PROCESS: reading a parent directory, writing outside the sandbox, reaching the
/// bridge's state dir, exfiltrating an env token.
///
/// The `direct` record is produced by a different battery, in the agent crate, over a
/// different surface: its 90 probes are typed tool calls (`read-traversal`,
/// `write-through-symlinked-dir`, `fetch-file-scheme`, `tool-Bash`), and it has no shell for
/// most of `PROBES` to even describe an attempt against. Holding it against this list would
/// not be a stricter test — it would be a category error that could only be satisfied by
/// inventing probe ids nobody ran.
///
/// What DOES check that record is `the_record_covers_every_row_the_bridge_actually_spawns`
/// (below, which runs for every record including this one), `validate_toolset_argv` against
/// the manifest, `the_containment_records_agree_with_what_each_harness_declares` in
/// `levelgate`, and the agent crate's own battery — which fails on an inconclusive probe, so
/// a summary with a probe missing cannot be written in the first place.
fn spawned_records() -> Vec<(&'static str, BatteryResults)> {
    records()
        .into_iter()
        .filter(|(id, _)| *id != DIRECT_ID)
        .collect()
}

#[test]
fn the_record_covers_every_row_the_bridge_actually_spawns() {
    for (id, r) in records() {
        let harness = harness_for(id);
        assert_eq!(
            r.harness, id,
            "a record embedded under the wrong harness id"
        );
        assert_eq!(
            r.rows.len(),
            harness.shipped_rows().len(),
            "{id}: every (capability, MCP set) pair THIS harness spawns needs its own row — a \
             level passes only when every MCP set recorded at that level passes"
        );
        for row in harness.shipped_rows().iter().copied() {
            let rec = r
                .row(capability_label(row.capability), row.mcp.label())
                .unwrap_or_else(|| panic!("{id}: no recorded row for {}", row.label()));
            assert_eq!(
                rec.toolset_args,
                harness.capability_args(&probe_config(), row.capability),
                "{id} {}: the recorded toolset argv must be the one THIS harness's builder \
                 produces — a row that describes a posture nothing spawns gates nothing",
                row.label()
            );
        }
    }
}

#[test]
fn every_row_records_every_probe() {
    for (id, r) in spawned_records() {
        for row in &r.rows {
            for p in PROBES {
                let rec = row.probe(p.id).unwrap_or_else(|| {
                    panic!("{id} {}: probe {} was never recorded", row.label(), p.id)
                });
                assert_eq!(
                    rec.class,
                    p.class.label(),
                    "{id} {}: {} class",
                    row.label(),
                    p.id
                );
            }
            assert_eq!(
                row.probes.len(),
                PROBES.len(),
                "{id} {}: the record carries a probe this build does not define",
                row.label()
            );
        }
    }
}

#[test]
fn no_probe_is_recorded_in_a_state_the_scoring_rules_could_not_produce() {
    for (id, r) in spawned_records() {
        for row in &r.rows {
            let key = ContainmentRow {
                capability: parse_capability(&row.capability).expect("a known capability"),
                mcp: McpSet::parse(&row.mcp_set).expect("a known MCP set"),
            };
            for p in PROBES {
                let rec = row.probe(p.id).expect("present, per the test above");
                let verdict = rec.verdict_enum().expect("a known verdict");
                // Re-score the recorded verdict from scratch. The status and the
                // required-verdict in the file must be exactly what this build's rules say
                // they are, so a hand-edited "pass" cannot survive.
                let rescored = score_probe(p.id, p.class, &key, verdict, rec.evidence.clone());
                assert_eq!(
                    rescored.status,
                    rec.status,
                    "{id} {}: {} is recorded {} but scores as {}",
                    row.label(),
                    p.id,
                    rec.status,
                    rescored.status
                );
                assert_eq!(
                    rescored.required,
                    rec.required,
                    "{id} {}: {}",
                    row.label(),
                    p.id
                );
                assert_ne!(
                    verdict,
                    ProbeVerdict::Inconclusive,
                    "{id} {}: {} was recorded inconclusive — nothing was proven, so it must \
                     be re-run",
                    row.label(),
                    p.id
                );
            }
            let failing = row.probes.iter().any(|p| p.is_failing());
            assert_eq!(
                row.status == "failing",
                failing,
                "{id} {}: row status must follow its probes",
                row.label()
            );
        }
        assert_eq!(
            r.gate == "fail",
            r.rows.iter().any(|row| row.status == "failing"),
            "{id}: the top-level gate must follow the rows"
        );
    }
}

/// Every committed record is BYTE-IDENTICAL to what the writer would emit for it.
///
/// The record is machine-generated and its header carries the paragraphs an operator needs at
/// 2am, so the header lives in `render_results` rather than in the file. That only stays true
/// if the two cannot drift: without this, a hand-edited record would keep its stale header
/// until the next `--write`, and — worse — a hand-edited VERDICT could hide behind reformatted
/// whitespace. Round-tripping is also what makes a deliberate header change safe to apply to
/// the committed files by re-rendering them, which is how the `${WORKSPACE}` and `gate`
/// paragraphs got there.
#[test]
fn every_committed_record_is_exactly_what_the_writer_emits() {
    for (id, text) in CONTAINMENT_RECORDS {
        let r = parse_results(text).expect("parses");
        assert_eq!(
            &render_results(&r),
            text,
            "{id}: the committed record is not byte-identical to what `render_results` \
             produces — re-render it rather than hand-editing"
        );
    }
}

/// A row whose hard gates are not met is NOT a combination this project ships. The record is
/// allowed to say so — that is the point of recording the truth — but the fact must be
/// visible here rather than buried in a file nobody reads, so this test names the failures
/// and the known-open findings in its output.
#[test]
fn the_record_states_its_failures_and_its_known_open_findings_out_loud() {
    for (id, r) in spawned_records() {
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
            "{id}: no known-open baselines at all — either the posture tightened (re-record) \
             or the battery stopped probing"
        );
    }
}

/// The live gate. Ignored by default: every probe is a real headless turn.
#[tokio::test]
#[ignore = "spawns real agent turns — costs money and minutes; run explicitly"]
async fn the_battery_still_matches_the_record() {
    let recorded = parse_results(containment_record(CLAUDE_CODE_ID).expect("embedded")).unwrap();
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
