//! `containment-probe` — the containment battery, as a merge gate.
//!
//! [`jesse_bridge::claude_capability_args`] records what this codebase learned the hard way: an empty
//! `--allowedTools` was believed to mean "no tools", and a live probe against the pinned CLI
//! disproved it. The conclusion drawn there is the rule this binary enforces — enumerated
//! denial is not a boundary, and the acceptance gate is a live probe battery re-run against
//! the pinned binary on every change.
//!
//! Run it two ways:
//!
//! ```text
//! cargo run --bin containment-probe            # re-run the battery, compare to the record
//! cargo run --bin containment-probe -- --write # re-run and RE-RECORD bridge/containment.toml
//! cargo run --bin containment-probe -- --show  # print the committed record, run nothing
//! ```
//!
//! The default form is the gate: it fails (exit 1) when a probe drifts from the committed
//! record in EITHER direction, when a hard gate is not met, or when a probe could not be
//! concluded from. `--write` is the deliberate human act of re-recording a drift on purpose —
//! it is not something CI does.
//!
//! Re-run it on every bump of the pinned agent binary, on every change to the containment
//! posture (the capability→flags mapping, the tool lists, the MCP server sets), and before
//! shipping a new (capability, MCP server set) pair. Each probe is a real headless turn, so a
//! full run costs real money and a few minutes of wall clock; that is the price of a boundary
//! that is proven rather than assumed.

use jesse_bridge::{
    compare_results, export_mcp_server_env, parse_results, render_results, run_battery,
    BatteryOptions, Config, ContainmentRow, Harness, McpSet,
};

/// The committed record. Resolved against the crate root at COMPILE time so the binary always
/// means this repo's file no matter where it is run from — and so the next step (embedding the
/// record with `include_str!` and validating config against it at startup) names one path.
const RESULTS_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/containment.toml");
const CODEX_RESULTS_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/containment-codex.toml");

/// The record file for a harness. ONE FILE PER HARNESS, because a containment verdict
/// describes a (harness, capability, MCP set) triple: nothing recorded for one harness says
/// anything about another, and a single file with a `harness` field could only ever describe
/// the last one probed.
fn results_path(harness: &str) -> &'static str {
    match harness {
        jesse_bridge::CODEX_ID => CODEX_RESULTS_PATH,
        _ => RESULTS_PATH,
    }
}

fn usage() -> ! {
    eprintln!(
        "containment-probe — run the live containment battery against the pinned agent binary\n\
         \n\
         USAGE:\n\
         \x20 containment-probe                 run the battery and compare it to the record\n\
         \x20 containment-probe --write         run the battery and RE-RECORD the results file\n\
         \x20 containment-probe --show          print the committed record without running\n\
         \n\
         OPTIONS:\n\
         \x20 --rows <a/b,...>   only these rows (e.g. read/qmd,write/qmd). Never with --write.\n\
         \x20 --probes <id,...>  only these probes. Never with --write.\n\
         \x20 --timeout <secs>   per-probe timeout (default 300)\n\
         \x20 --keep             keep the scratch trees for inspection\n\
         \x20 --harness <id>     which harness to probe (claude-code | codex)\n\
         \x20 --model <id>       probe AS this registry model (default: the ambient one)\n"
    );
    std::process::exit(2)
}

#[tokio::main]
async fn main() {
    // THE BATTERY MUST SPAWN CHILDREN IN THE SAME ENVIRONMENT THE BRIDGE DOES, or it records
    // a posture that was never actually probed. Without this the MCP servers that read a
    // credential — Google, GitHub, Fastmail, UniFi — start, find nothing, and register ZERO
    // tools; the run then looks clean while proving nothing about the servers it names, and
    // the resulting record would vouch for a set the child never really loaded. Same call,
    // same reason, as `main.rs`.
    export_mcp_server_env();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut opts = BatteryOptions::default();
    let mut write = false;
    let mut show = false;
    // Resolved AFTER `Config::from_env()` below, because the registry it names lives there.
    let mut model_id: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--write" => write = true,
            "--show" => show = true,
            "--keep" => opts.keep_scratch = true,
            "--harness" => {
                i += 1;
                opts.harness = args.get(i).cloned().unwrap_or_else(|| usage());
            }
            "--model" => {
                i += 1;
                model_id = Some(args.get(i).cloned().unwrap_or_else(|| usage()));
            }
            "--rows" => {
                i += 1;
                let list = args.get(i).cloned().unwrap_or_else(|| usage());
                opts.rows = list.split(',').map(parse_row).collect();
            }
            "--probes" => {
                i += 1;
                let list = args.get(i).cloned().unwrap_or_else(|| usage());
                opts.probes = Some(list.split(',').map(|s| s.trim().to_string()).collect());
            }
            "--timeout" => {
                i += 1;
                opts.timeout_secs = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| usage());
            }
            "-h" | "--help" => usage(),
            other => {
                eprintln!("containment-probe: unknown argument {other}");
                usage()
            }
        }
        i += 1;
    }

    let results_path = results_path(&opts.harness);
    let recorded_text = std::fs::read_to_string(results_path).ok();

    if show {
        match recorded_text {
            Some(text) => print_record(&text),
            None => {
                eprintln!("containment-probe: no record at {results_path}");
                std::process::exit(1);
            }
        }
        return;
    }

    // A partial run cannot be a record: a file missing rows or probes reads as a battery that
    // covered everything and found nothing, which is the exact lie this gate exists to stop.
    let shipped_row_count = match opts.harness.as_str() {
        jesse_bridge::CODEX_ID => jesse_bridge::Codex.shipped_rows().len(),
        _ => jesse_bridge::ClaudeCode.shipped_rows().len(),
    };
    if write && (opts.probes.is_some() || opts.rows.len() != shipped_row_count) {
        eprintln!(
            "containment-probe: --write records the WHOLE battery. Drop --rows/--probes, or \
             drop --write."
        );
        std::process::exit(2);
    }

    let cfg = Config::from_env();

    // Resolve `--model` against the SAME registry the serving bridge builds, and demand it be
    // CONFIGURED. An unarmed entry has no credential to give the child, so every probe would
    // come back inconclusive and the run would record a battery that proved nothing — the
    // exact lie the `--write` guard above exists to stop, arriving by a different door.
    if let Some(id) = &model_id {
        let Some(m) = cfg.model_registry.get(id) else {
            eprintln!(
                "containment-probe: unknown model '{id}' — it must be a registered entry \
                 (a [[models]] block or a JESSE_MODEL_* triple)."
            );
            std::process::exit(2);
        };
        if !m.configured {
            eprintln!(
                "containment-probe: model '{id}' is registered but NOT configured (its token \
                 env var is unset), so every probe would run without a credential and prove \
                 nothing. Arm it and re-run."
            );
            std::process::exit(2);
        }
        if m.harness != opts.harness {
            eprintln!(
                "containment-probe: model '{id}' runs on harness '{}' but this run probes \
                 '{}' — a record must be written by a model the harness actually serves.",
                m.harness, opts.harness
            );
            std::process::exit(2);
        }
        opts.model = Some(jesse_bridge::ActiveModel::from_registry(m));
    }

    let bin = if opts.harness == jesse_bridge::CODEX_ID {
        &cfg.codex_bin
    } else {
        &cfg.claude_bin
    };
    eprintln!(
        "containment-probe: {} rows x {} probes against {} ({}) [harness {}, model {}]",
        opts.rows.len(),
        opts.probes
            .as_ref()
            .map(|p| p.len())
            .unwrap_or(jesse_bridge::PROBES.len()),
        bin,
        jesse_bridge::probe_binary_version(bin),
        opts.harness,
        opts.model
            .as_ref()
            .map(|m| m.id.as_str())
            .unwrap_or("the ambient default"),
    );

    let outcome = match run_battery(&cfg, &opts).await {
        Ok(o) => o,
        Err(e) => {
            eprintln!("containment-probe: the battery could not run: {e}");
            std::process::exit(1);
        }
    };
    let fresh = &outcome.results;
    eprintln!(
        "\ncontainment-probe: run finished — gate {}, ${:.2} spent{}",
        fresh.gate,
        outcome.cost_usd,
        if opts.keep_scratch {
            format!(", scratch kept at {}", outcome.scratch.display())
        } else {
            String::new()
        }
    );

    // The findings, always printed, whatever the mode: a run that scrolled past is a run
    // nobody read.
    let failures = fresh.hard_gate_failures();
    let open = fresh.known_open();
    if !failures.is_empty() {
        eprintln!("\nHARD GATES NOT MET ({}):", failures.len());
        for f in &failures {
            eprintln!("  ✗ {f}");
        }
    }
    if !open.is_empty() {
        eprintln!("\nKNOWN-OPEN BASELINES ({}):", open.len());
        for o in &open {
            eprintln!("  ! {o}");
        }
    }

    if write {
        // A fresh run knows what the boundary did; it cannot know who agreed to ship it.
        // Carry the committed acceptances across, or `--write` would erase the decision
        // record at exactly the moment an operator most needs to read it.
        let mut fresh = fresh.clone();
        // Re-recording is a deliberate act, so say what it is about to change. A silent
        // overwrite is how a posture regression gets committed as "the new baseline" without
        // anyone deciding that it should be.
        if let Some(prev) = recorded_text.as_deref().and_then(|t| parse_results(t).ok()) {
            fresh.accepted = prev.accepted.clone();
            let drift = compare_results(&prev, &fresh);
            if drift.is_empty() {
                eprintln!(
                    "\ncontainment-probe: re-recording — nothing moved since {} (this run \
                     CONFIRMS the previous one).",
                    prev.recorded
                );
            } else {
                eprintln!("\nRE-RECORDING, {} probe(s) moved:", drift.len());
                for d in &drift {
                    eprintln!("  ~ {d}");
                }
            }
        }
        // Which of the open doors has nobody signed for? "We accepted the read opens" must
        // not quietly come to mean "we accepted everything the battery found".
        let unsigned = fresh.unaccepted_known_open();
        if !unsigned.is_empty() {
            eprintln!(
                "\nKNOWN-OPEN AND UNACCEPTED ({}) — no [[accepted]] entry covers these:",
                unsigned.len()
            );
            for u in &unsigned {
                eprintln!("  ! {u}");
            }
        }
        // An acceptance that outlived its finding is not an error — the door may simply have
        // closed — but it must not be left to imply a risk nobody is carrying any more.
        let stale = fresh.stale_acceptances();
        if !stale.is_empty() {
            eprintln!(
                "\nSTALE ACCEPTANCES ({}) — remove them on purpose:",
                stale.len()
            );
            for s in &stale {
                eprintln!("  ~ {s}");
            }
        }
        let text = render_results(&fresh);
        if let Err(e) = std::fs::write(results_path, &text) {
            eprintln!("containment-probe: could not write {results_path}: {e}");
            std::process::exit(1);
        }
        eprintln!("\ncontainment-probe: recorded {results_path}");
        if !failures.is_empty() {
            eprintln!(
                "containment-probe: the record says gate = fail — {} hard gate(s) are not met. \
                 Recording the truth is right; shipping this pair is a decision.",
                failures.len()
            );
            std::process::exit(1);
        }
        return;
    }

    // Gate mode: drift against the record, plus the record's own health.
    let Some(text) = recorded_text else {
        eprintln!(
            "\ncontainment-probe: no record at {results_path} — nothing to compare against. \
             Re-run with --write to record this battery."
        );
        std::process::exit(1);
    };
    let recorded = match parse_results(&text) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("containment-probe: {results_path} does not parse: {e}");
            std::process::exit(1);
        }
    };
    if recorded.binary_version != fresh.binary_version {
        eprintln!(
            "\ncontainment-probe: the record was taken against {} and this is {} — the battery \
             is re-run on every binary version bump.",
            recorded.binary_version, fresh.binary_version
        );
    }
    // Said out loud for the same reason as the binary version: the turn-behavior half of a
    // row is model-dependent, so comparing a K3 run against an ambient-probed record is
    // comparing two different questions. Not a failure by itself — the drift list below is
    // still the verdict — but a reader must not have to infer it.
    if recorded.model != fresh.model {
        let name = |m: &Option<String>| m.clone().unwrap_or_else(|| "the ambient default".into());
        eprintln!(
            "\ncontainment-probe: the record was probed by {} and this run by {} — the OS \
             boundary is model-independent, but which tools a child TRIED is not.",
            name(&recorded.model),
            name(&fresh.model)
        );
    }
    let drift = compare_results(&recorded, fresh);
    if !drift.is_empty() {
        eprintln!("\nBASELINE DRIFT ({}):", drift.len());
        for d in &drift {
            eprintln!("  ~ {d}");
        }
        eprintln!(
            "\ncontainment-probe: FAIL — a probe moved. A flip in either direction fails the \
             gate until a human re-records it on purpose (--write)."
        );
        std::process::exit(1);
    }
    if !failures.is_empty() {
        eprintln!(
            "\ncontainment-probe: FAIL — {} hard gate(s) not met.",
            failures.len()
        );
        std::process::exit(1);
    }
    eprintln!("\ncontainment-probe: PASS — hard gates green, baselines match the record.");
}

fn parse_row(s: &str) -> ContainmentRow {
    let (cap, mcp) = s.trim().split_once('/').unwrap_or_else(|| {
        eprintln!("containment-probe: a row is <capability>/<mcp set>, e.g. read/qmd (got {s})");
        std::process::exit(2)
    });
    let (Some(capability), Some(mcp)) = (jesse_bridge::parse_capability(cap), McpSet::parse(mcp))
    else {
        eprintln!("containment-probe: unknown row {s}");
        std::process::exit(2)
    };
    ContainmentRow { capability, mcp }
}

/// Print the committed record as a table, for the human who wants to know where a pair stands
/// without spending five minutes and a few dollars finding out again.
fn print_record(text: &str) {
    let r = match parse_results(text) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("containment-probe: the committed record does not parse: {e}");
            std::process::exit(1);
        }
    };
    println!(
        "harness {} — binary {} — recorded {} — gate {}",
        r.harness, r.binary_version, r.recorded, r.gate
    );
    for row in &r.rows {
        println!("\n{} [{}]", row.label(), row.status);
        for p in &row.probes {
            // The record stores ids; what each id ATTEMPTS lives with the probe table, so
            // the human-readable form is joined here rather than duplicated 52 times in the
            // file.
            let what = jesse_bridge::PROBES
                .iter()
                .find(|probe| probe.id == p.id)
                .map(|probe| probe.summary)
                .unwrap_or("(no such probe in this build)");
            println!(
                "  {:<24} {:<10} {:<10} {}\n  {:<24} {}",
                p.id, p.verdict, p.status, what, "", p.evidence
            );
        }
    }
    let failures = r.hard_gate_failures();
    if !failures.is_empty() {
        println!("\nhard gates not met:");
        for f in failures {
            println!("  ✗ {f}");
        }
    }
    let open = r.known_open();
    if !open.is_empty() {
        println!("\nknown-open baselines:");
        for o in open {
            println!("  ! {o}");
        }
    }
}
