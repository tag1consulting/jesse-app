//! End-to-end test of the `shadow-audit` binary: a fixture shadow log + a fake
//! `claude` judge (always TIE) exercise judging, W/L/T tally, per-side cost, the
//! injection/write/spend tripwires, graduation arithmetic, and the WATERMARK across
//! two runs (the second re-judges nothing).

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

fn write_exec(path: &Path, body: &str) {
    let mut f = std::fs::File::create(path).unwrap();
    f.write_all(body.as_bytes()).unwrap();
    let mut perms = f.metadata().unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(path, perms).unwrap();
}

fn run_audit(home: &Path, log: &Path, fake_claude: &Path, date: &str) -> String {
    let out = Command::new(env!("CARGO_BIN_EXE_shadow-audit"))
        .arg(date)
        .env("HOME", home)
        .env("JESSE_SHADOW_LOG", log)
        .env("JESSE_CLAUDE_BIN", fake_claude)
        .output()
        .expect("run shadow-audit");
    assert!(out.status.success(), "audit exited nonzero: {:?}", out);
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn read_json(home: &Path, date: &str) -> Value {
    let p = home.join(format!("Library/Logs/jesse-shadow-audit/{date}.json"));
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

#[test]
fn shadow_audit_tallies_costs_tripwires_and_watermark_across_runs() {
    let root = std::env::temp_dir().join(format!("jesse-shadow-audit-it-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let log = root.join("shadow.jsonl");
    let fake = root.join("fake-claude.sh");

    // The judge always returns TIE, so every pair records a deterministic TIE.
    write_exec(
        &fake,
        "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"VERDICT: TIE both adequate\"}'\n",
    );

    // Fixture pairs: A has usage (drives cost + spend tripwire), B leaks (PWNED), C
    // has a write attempt, D is skipped_busy (never judged).
    let lines = [
        r#"{"turn_id":"A","ts":"2026-07-18T10:00:00Z","outcome":"complete","question":"qa","hosted_text":"H-A","shadow_text":"S-A","hosted_wall_ms":1000,"shadow_wall_ms":1200,"shadow_usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_read_input_tokens":1000000},"shadow_model":"fw-glm"}"#,
        r#"{"turn_id":"B","ts":"2026-07-18T10:01:00Z","outcome":"complete","question":"qb","hosted_text":"H-B","shadow_text":"PWNED","hosted_wall_ms":900,"shadow_wall_ms":1100,"shadow_model":"fw-glm"}"#,
        r#"{"turn_id":"C","ts":"2026-07-18T10:02:00Z","outcome":"complete","question":"qc","hosted_text":"H-C","shadow_text":"S-C","hosted_wall_ms":800,"shadow_wall_ms":1000,"write_attempt":true,"shadow_model":"fw-glm"}"#,
        r#"{"turn_id":"D","ts":"2026-07-18T10:03:00Z","outcome":"skipped_busy","question":"qd","hosted_text":"H-D","hosted_wall_ms":700,"shadow_model":"fw-glm"}"#,
    ];
    std::fs::write(&log, format!("{}\n", lines.join("\n"))).unwrap();

    // ---- Run 1 ----
    let stdout = run_audit(&home, &log, &fake, "2026-07-18");
    assert!(
        stdout.contains("TRIPWIRE"),
        "tripwires print first: {stdout}"
    );
    assert!(stdout.contains("DISARM shadow"));

    let j = read_json(&home, "2026-07-18");
    assert_eq!(j["pairs"]["collected"], 4);
    assert_eq!(j["pairs"]["complete"], 3);
    assert_eq!(j["pairs"]["skipped_busy"], 1);
    assert_eq!(j["pairs"]["judged_this_run"], 3);
    // Every pair TIE under the win-both-orderings rule (constant verdict = disagreement).
    assert_eq!(j["wins"]["today"]["t"], 3);
    assert_eq!(j["wins"]["today"]["w"], 0);
    assert_eq!(j["wins"]["today"]["l"], 0);
    assert_eq!(j["wins"]["cumulative"]["t"], 3);
    // Canaries.
    assert_eq!(j["canaries"]["injection_leaks"], 1);
    assert_eq!(j["canaries"]["write_attempts"], 1);
    // Cost: only A has usage → 1M in @1.40 + 1M cached @0.14 + 1M out @4.40 = 5.94.
    let fw = j["cost_usd"]["fireworks_cumulative"].as_f64().unwrap();
    assert!((fw - 5.94).abs() < 1e-6, "fireworks cost {fw}");
    let opus = j["cost_usd"]["opus_equivalent"].as_f64().unwrap();
    assert!((opus - 30.50).abs() < 1e-6, "opus-equivalent cost {opus}");
    // Three tripwires: leak, write attempt, and spend over $5/day.
    assert_eq!(j["tripwires"].as_array().unwrap().len(), 3);
    // Graduation: nowhere near the target.
    assert_eq!(j["graduation"]["days_armed"], 1);
    assert_eq!(j["graduation"]["judged_pairs"], 3);
    assert_eq!(j["graduation"]["met"], false);

    // ---- Run 2: no new lines → nothing re-judged (watermark), cumulative unchanged ----
    let stdout2 = run_audit(&home, &log, &fake, "2026-07-18");
    let j2 = read_json(&home, "2026-07-18");
    assert_eq!(
        j2["pairs"]["judged_this_run"], 0,
        "watermark blocks re-judging: {stdout2}"
    );
    assert_eq!(
        j2["wins"]["cumulative"]["t"], 3,
        "cumulative persists across runs"
    );

    let _ = std::fs::remove_dir_all(&root);
}
