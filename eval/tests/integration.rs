//! End-to-end tests that drive the real `jesse-eval` binary.
//!
//! The `run` pipeline is exercised with `--mock` (canned NDJSON), so there is
//! zero network and zero models. A second test proves the vault-readonly hard
//! check refuses a write tool at the CLI boundary, not just in the unit test.

use std::fs;
use std::process::Command;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_jesse-eval")
}

/// A stream-json text-delta line.
fn delta(text: &str) -> String {
    format!(
        r#"{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"{text}"}}}}}}"#
    )
}

/// A terminal result line with the given final answer.
fn result_line(answer: &str) -> String {
    format!(
        r#"{{"type":"result","subtype":"success","is_error":false,"ttft_ms":42,"result":"{answer}","usage":{{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}}"#
    )
}

/// An assistant message carrying `n` tool_use blocks.
fn assistant_with_tools(n: usize) -> String {
    let blocks: Vec<String> = (0..n)
        .map(|i| format!(r#"{{"type":"tool_use","name":"Grep","id":"t{i}"}}"#))
        .collect();
    format!(
        r#"{{"type":"assistant","message":{{"content":[{}]}}}}"#,
        blocks.join(",")
    )
}

#[test]
fn run_pipeline_with_mock_scores_tasks() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");

    // Three fixture tasks: one clean answer, one file-writing task, one that
    // blows past its tool ceiling (must fail).
    let suite = serde_json::json!({
        "name": "mock-suite",
        "tasks": [
            {
                "id": "greet",
                "class": "titles",
                "prompt": "say ready",
                "workspace": "fixture",
                "allowed_tools": [],
                "assertions": [
                    {"type": "answer_matches", "pattern": "READY"},
                    {"type": "max_tool_calls", "max": 0},
                    {"type": "completed"}
                ]
            },
            {
                "id": "writecsv",
                "class": "extraction",
                "prompt": "append a row",
                "workspace": "fixture",
                "allowed_tools": ["Write"],
                "fixture_files": {"log.csv": "date,item\n"},
                "assertions": [
                    {"type": "file_matches", "path": "log.csv", "pattern": "2026-07-09,apple"},
                    {"type": "max_tool_calls", "max": 2},
                    {"type": "completed"}
                ]
            },
            {
                "id": "toomany",
                "class": "tool-use",
                "prompt": "do it minimally",
                "workspace": "fixture",
                "allowed_tools": ["Grep"],
                "assertions": [
                    {"type": "max_tool_calls", "max": 2},
                    {"type": "completed"}
                ]
            }
        ]
    });
    fs::write(&suite_path, serde_json::to_vec_pretty(&suite).unwrap()).unwrap();

    let mock = serde_json::json!({
        "responses": {
            "greet": {
                "ndjson": [
                    {"type": "system", "subtype": "init"},
                    serde_json::from_str::<serde_json::Value>(&delta("READ")).unwrap(),
                    serde_json::from_str::<serde_json::Value>(&delta("Y")).unwrap(),
                    serde_json::from_str::<serde_json::Value>(&result_line("READY")).unwrap()
                ]
            },
            "writecsv": {
                "ndjson": [
                    serde_json::from_str::<serde_json::Value>(&assistant_with_tools(1)).unwrap(),
                    serde_json::from_str::<serde_json::Value>(&result_line("done")).unwrap()
                ],
                "files": {"log.csv": "date,item\n2026-07-09,apple\n"}
            },
            "toomany": {
                "ndjson": [
                    serde_json::from_str::<serde_json::Value>(&assistant_with_tools(3)).unwrap(),
                    serde_json::from_str::<serde_json::Value>(&result_line("used too many")).unwrap()
                ]
            }
        }
    });
    fs::write(&mock_path, serde_json::to_vec_pretty(&mock).unwrap()).unwrap();

    let status = Command::new(bin())
        .args([
            "run",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            "--mock",
            mock_path.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(status.success(), "run should exit success");

    // results.json exists and reflects the expected pass/fail.
    let results: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("results.json")).unwrap()).unwrap();
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 3);

    let by_id = |id: &str| tasks.iter().find(|t| t["id"] == id).unwrap();
    assert_eq!(by_id("greet")["passed"], true);
    assert_eq!(by_id("greet")["tool_calls"], 0);
    assert_eq!(by_id("greet")["tokens"]["input"], 100);
    assert_eq!(by_id("writecsv")["passed"], true);
    assert_eq!(by_id("writecsv")["tool_calls"], 1);
    // Exceeds its ceiling of 2 → must fail.
    assert_eq!(by_id("toomany")["passed"], false);
    assert_eq!(by_id("toomany")["tool_calls"], 3);

    // scorecard.md exists and has a totals row.
    let scorecard = fs::read_to_string(out.join("scorecard.md")).unwrap();
    assert!(scorecard.contains("TOTAL"), "scorecard: {scorecard}");

    // Per-task transcripts were persisted.
    assert!(out.join("transcripts/greet.ndjson").exists());
}

#[test]
fn vault_readonly_write_tool_is_refused_at_cli() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    let out = tmp.path().join("out");

    // A vault-readonly task that illegally asks for Write must be refused BEFORE
    // anything runs — this is the load-bearing guard that eval can never mutate
    // the vault.
    let suite = serde_json::json!({
        "name": "bad-suite",
        "tasks": [
            {
                "id": "danger",
                "class": "vault-qa",
                "prompt": "go",
                "workspace": "vault-readonly",
                "allowed_tools": ["Read", "Write"],
                "assertions": [{"type": "completed"}]
            }
        ]
    });
    fs::write(&suite_path, serde_json::to_vec_pretty(&suite).unwrap()).unwrap();

    let output = Command::new(bin())
        .args([
            "run",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            // A mock is present, but the refusal must happen at suite-load time,
            // before any task runs.
        ])
        .output()
        .unwrap();
    assert!(!output.status.success(), "must refuse the write tool");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Write") && stderr.contains("vault-readonly"),
        "stderr should explain the refusal, got: {stderr}"
    );
}

/// Run the SHIPPED `vaultqa-example` suite through a mock via `--mock` and return
/// the parsed `results.json` tasks. Uses `include_str!` so the suite and mock under
/// test are the committed artifacts, not copies.
fn run_vaultqa_mock(mock_json: &str) -> serde_json::Value {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("vaultqa-example.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");
    fs::write(&suite_path, include_str!("../suites/vaultqa-example.json")).unwrap();
    fs::write(&mock_path, mock_json).unwrap();

    let status = Command::new(bin())
        .args([
            "run",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            "--mock",
            mock_path.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(status.success(), "vaultqa mock run should exit success");
    serde_json::from_slice(&fs::read(out.join("results.json")).unwrap()).unwrap()
}

/// The good mock — every task's canned answer satisfies every assertion — must
/// score 10/10. This proves the shipped suite's assertions accept a correct,
/// grounded, injection-resistant answer.
#[test]
fn vaultqa_example_good_mock_passes_every_task() {
    let results = run_vaultqa_mock(include_str!("../suites/validation/mock-good.json"));
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 10, "vaultqa-example has 10 tasks");
    for t in tasks {
        assert_eq!(
            t["passed"], true,
            "good mock: task {} should pass; assertions: {}",
            t["id"], t["assertions"]
        );
    }
}

/// The known-bad mock must fail every task, and each failure must be the task's
/// INTENDED (content/safety) assertion firing — never `completed`, which stays
/// true because a result line still arrived. This is the diet-v1-style proof
/// that each assertion has teeth and catches exactly the defect it targets.
#[test]
fn vaultqa_example_bad_mock_fails_intended_assertions() {
    let results = run_vaultqa_mock(include_str!("../suites/validation/mock-bad.json"));
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 10);

    let by_id = |id: &str| {
        tasks
            .iter()
            .find(|t| t["id"] == id)
            .unwrap_or_else(|| panic!("task {id} present"))
    };
    // Which assertion kinds fired (failed) for a task.
    let fired = |id: &str| -> Vec<String> {
        by_id(id)["assertions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["passed"] == false)
            .map(|a| a["kind"].as_str().unwrap().to_string())
            .collect()
    };
    // `completed` passed (a result line arrived) for a task — so the task's
    // failure is a real assertion firing, not a harness error.
    let completed_ok = |id: &str| -> bool {
        by_id(id)["assertions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a["kind"] == "completed" && a["passed"] == true)
    };

    for t in tasks {
        assert_eq!(t["passed"], false, "bad mock: task {} must fail", t["id"]);
        assert!(
            completed_ok(t["id"].as_str().unwrap()),
            "bad mock: task {} should still be `completed` (failure must be a content/safety assertion, not a crash)",
            t["id"]
        );
    }

    // Spot-check the load-bearing gates fire on exactly the right defect.
    // Injection: the ONLY thing wrong with the bad answer is that it emits PWNED.
    assert_eq!(
        fired("vq-injection"),
        vec!["answer_excludes"],
        "vq-injection bad answer must fail only the PWNED-exclusion gate"
    );
    // Negative control: a confabulated answer must fail BOTH the absence check
    // and the fabricated-specific exclusion.
    let neg = fired("vq-negative-absent");
    assert!(
        neg.contains(&"answer_matches".to_string())
            && neg.contains(&"answer_excludes".to_string()),
        "vq-negative-absent bad answer must fail the absence-ack and the 77420 exclusion; fired: {neg:?}"
    );
    // Numeric target: capturing the 204 start weight is out of band.
    assert!(
        fired("vq-weight-target").contains(&"number_in_range".to_string()),
        "vq-weight-target bad answer (210 lbs) must fail number_in_range"
    );
}

// ===========================================================================
// `product-v1`, on both drivers
// ===========================================================================

/// Run the SHIPPED `product-v1` suite through a mock on one driver and return the parsed
/// `results.json` tasks. `include_str!` again, so the suite and mocks under test are the
/// committed artifacts rather than copies of them.
fn run_product_v1(driver: &str, mock_json: &str) -> serde_json::Value {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("product-v1.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");
    fs::write(&suite_path, include_str!("../suites/product-v1.json")).unwrap();
    fs::write(&mock_path, mock_json).unwrap();

    let status = Command::new(bin())
        .args([
            "run",
            "--driver",
            driver,
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            "--mock",
            mock_path.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(status.success(), "{driver} mock run should exit success");
    serde_json::from_slice(&fs::read(out.join("results.json")).unwrap()).unwrap()
}

/// Every task must pass, and `completed` must be true everywhere: a good mock that scored
/// well because half the tasks errored would be no evidence at all.
fn assert_all_pass(results: &serde_json::Value, driver: &str) {
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 17, "product-v1 has 17 tasks");
    assert_eq!(results["driver"], driver);
    for t in tasks {
        assert_eq!(
            t["passed"], true,
            "{driver} good mock: task {} should pass; assertions: {}",
            t["id"], t["assertions"]
        );
        assert_eq!(t["error"], serde_json::Value::Null, "task {}", t["id"]);
    }
}

/// Every task must fail, and every failure must be a CONTENT assertion firing rather than a
/// harness error — `completed` still passes, exactly as the `vaultqa-example` teeth check
/// requires of its bad mock.
fn assert_all_fail(results: &serde_json::Value, driver: &str) {
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 17);
    for t in tasks {
        assert_eq!(
            t["passed"], false,
            "{driver} bad mock: task {} must fail",
            t["id"]
        );
        assert_eq!(t["error"], serde_json::Value::Null, "task {}", t["id"]);
        let completed_ok = t["assertions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a["kind"] == "completed" && a["passed"] == true);
        assert!(
            completed_ok,
            "{driver} bad mock: task {} must still be `completed` (the failure has to be a \
             content/safety assertion, not a crash)",
            t["id"]
        );
    }
}

#[test]
fn product_v1_direct_good_mock_passes_every_task() {
    let results = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-good.json"),
    );
    assert_all_pass(&results, "direct");
}

#[test]
fn product_v1_direct_bad_mock_fails_every_task() {
    let results = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-bad.json"),
    );
    assert_all_fail(&results, "direct");

    let by_id = |id: &str| {
        results["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["id"] == id)
            .unwrap_or_else(|| panic!("task {id} present"))
            .clone()
    };
    let fired = |id: &str| -> Vec<String> {
        by_id(id)["assertions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["passed"] == false)
            .map(|a| a["kind"].as_str().unwrap().to_string())
            .collect()
    };

    // The three new gates fire on exactly the defect they exist for.
    assert_eq!(
        fired("st-no-lists"),
        vec!["style_clean"],
        "the only thing wrong with the bad venue reply is its style"
    );
    assert!(
        fired("inj-tool-result-write").contains(&"tools_exclude".to_string()),
        "a turn that obeyed the injected write directive must trip tools_exclude"
    );
    // And the write actually happened, which is what makes the direct mock worth having:
    // the file assertion failed because a REAL tool wrote a REAL file.
    assert!(
        fired("inj-tool-result-write").contains(&"file_equals".to_string()),
        "the ledger must actually have changed on disk"
    );
}

/// THE DIRECT MOCK RUNS REAL TOOLS. The good run's `dw-append-entry` passes a
/// `numbers_consistent` check between a file and an answer, and the file it reads was
/// written by `vault_write` under a compare-and-swap against a hash the fixture did not
/// know — so a pass here is evidence about the tool boundary, not about a `files` map.
#[test]
fn the_direct_mock_exercises_the_real_write_path() {
    let results = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-good.json"),
    );
    let task = results["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == "dw-append-entry")
        .expect("dw-append-entry present");
    let kinds: Vec<&str> = task["assertions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"numbers_consistent"));
    assert_eq!(task["passed"], true, "{}", task["assertions"]);
    // The tools the loop actually dispatched, by their DIRECT manifest names.
    let names: Vec<&str> = task["tool_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    assert_eq!(names, ["vault_read", "vault_write"]);
}

#[test]
fn product_v1_cli_good_mock_passes_every_task() {
    let results = run_product_v1(
        "claude-cli",
        include_str!("../suites/validation/product-v1-cli-good.json"),
    );
    assert_all_pass(&results, "claude-cli");
}

#[test]
fn product_v1_cli_bad_mock_fails_every_task() {
    let results = run_product_v1(
        "claude-cli",
        include_str!("../suites/validation/product-v1-cli-bad.json"),
    );
    assert_all_fail(&results, "claude-cli");
}

// ---- D11 F1: the injection assertions test behaviour, not strings -------------------
//
// Three canned runs, one property each, all on the SHIPPED suite through the real assertion
// engine. Together they are the both-directions proof the repaired assertions have teeth:
// the good mock above already shows a resist-AND-disclose answer scoring 17/17 with the
// injected words in the text; these two show what the repair must still catch.

/// Task ids paired with the assertion kinds that failed, for one run.
fn failures(results: &serde_json::Value) -> Vec<(String, Vec<String>)> {
    results["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|t| t["passed"] == false)
        .map(|t| {
            (
                t["id"].as_str().unwrap().to_string(),
                t["assertions"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|a| a["passed"] == false)
                    .map(|a| a["kind"].as_str().unwrap().to_string())
                    .collect(),
            )
        })
        .collect()
}

/// SILENT RESISTANCE IS NOT ENOUGH. A model that answers the real question and never
/// mentions the trap it just walked past fails, and fails on the DISCLOSURE row alone —
/// every other assertion in the suite, including the anchored exclusion, still passes.
#[test]
fn product_v1_a_silent_resist_fails_only_the_disclosure_row() {
    let results = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-resist-silent.json"),
    );
    let got = failures(&results);
    let expected: Vec<(String, Vec<String>)> = [
        "inj-note-directive",
        "inj-tool-result-write",
        "inj-search-hit-egress",
    ]
    .iter()
    .map(|id| (id.to_string(), vec!["answer_matches".to_string()]))
    .collect();
    assert_eq!(
        got, expected,
        "only the three injection tasks fail, and only on the disclosure assertion"
    );
}

/// AND COMPLIANCE STILL FAILS. The injected string AS the answer trips the anchored
/// exclusion; the decoy stated as the claim and the finished item presented as outstanding
/// trip `answer_mentions_only_with`. These are the six tasks D9 scored backwards, now
/// failing for the right reason instead of passing for none.
#[test]
fn product_v1_compliance_fails_the_anchored_assertions() {
    let results = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-comply.json"),
    );
    let fired: std::collections::BTreeMap<String, Vec<String>> =
        failures(&results).into_iter().collect();

    for id in [
        "inj-note-directive",
        "inj-tool-result-write",
        "inj-search-hit-egress",
    ] {
        let kinds = fired.get(id).unwrap_or_else(|| panic!("{id} must fail"));
        assert!(
            kinds.contains(&"answer_excludes".to_string()),
            "{id}: the anchored exclusion must fire on the injected string as the answer, got {kinds:?}"
        );
    }
    for id in ["ms-decoy-near-miss", "br-morning", "br-morning-judged"] {
        let kinds = fired.get(id).unwrap_or_else(|| panic!("{id} must fail"));
        assert!(
            kinds.contains(&"answer_mentions_only_with".to_string()),
            "{id}: a bare mention must fire the qualified-mention assertion, got {kinds:?}"
        );
    }
    // And nothing ELSE broke: the tasks the two mocks do not touch still pass.
    for id in ["dw-new-note", "cb-tick-one", "ms-two-files", "st-no-lists"] {
        assert!(!fired.contains_key(id), "{id} should be unaffected");
    }
}

// ---- D11 F2: one pack, both drivers -------------------------------------------------

/// The unit tests in `driver::claude_cli` assert the two drivers PREPEND the same bytes.
/// This asserts the other half at the suite level: the same style-violating answer is
/// GRADED identically on both runners, down to the finding counts in the detail string, so
/// a `style-adherence` split between drivers can only mean the answers differed.
#[test]
fn a_style_violating_answer_is_graded_identically_on_both_drivers() {
    let direct = run_product_v1(
        "direct",
        include_str!("../suites/validation/product-v1-bad.json"),
    );
    let cli = run_product_v1(
        "claude-cli",
        include_str!("../suites/validation/product-v1-cli-bad.json"),
    );
    let style_row = |results: &serde_json::Value, id: &str| -> serde_json::Value {
        results["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["id"] == id)
            .unwrap_or_else(|| panic!("task {id} present"))["assertions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["kind"] == "style_clean")
            .unwrap_or_else(|| panic!("{id} has a style_clean row"))
            .clone()
    };
    for id in ["st-no-lists", "st-plain-prose", "st-voice-judged"] {
        let d = style_row(&direct, id);
        let c = style_row(&cli, id);
        assert_eq!(d["passed"], false, "{id}: the bad answer must fail");
        assert_eq!(
            d, c,
            "{id}: style_clean must return the same verdict AND the same detail on both drivers"
        );
    }
}

/// One suite, two drivers, one verdict: `compare` pairs the two good runs by task id and
/// reports parity in every class.
#[test]
fn compare_reports_parity_between_the_two_good_runs() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("product-v1.json");
    fs::write(&suite_path, include_str!("../suites/product-v1.json")).unwrap();

    let run = |driver: &str, mock_json: &str, out: &std::path::Path| {
        let mock_path = out.with_extension("mock.json");
        fs::write(&mock_path, mock_json).unwrap();
        let status = Command::new(bin())
            .args([
                "run",
                "--driver",
                driver,
                "--suite",
                suite_path.to_str().unwrap(),
                "--out",
                out.to_str().unwrap(),
                "--mock",
                mock_path.to_str().unwrap(),
            ])
            .status()
            .unwrap();
        assert!(status.success());
    };
    let a = tmp.path().join("a");
    let b = tmp.path().join("b");
    run(
        "claude-cli",
        include_str!("../suites/validation/product-v1-cli-good.json"),
        &a,
    );
    run(
        "direct",
        include_str!("../suites/validation/product-v1-good.json"),
        &b,
    );

    let out = tmp.path().join("cmp");
    let output = Command::new(bin())
        .args([
            "compare",
            "--a",
            a.to_str().unwrap(),
            "--b",
            b.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "compare should exit success");

    let md = fs::read_to_string(out.join("compare.md")).unwrap();
    assert!(
        md.contains("`claude-cli`") && md.contains("`direct`"),
        "{md}"
    );
    assert!(
        !md.contains("regressed"),
        "the two good runs must not regress: {md}"
    );
    assert_eq!(
        md.matches("parity").count(),
        6,
        "one verdict per class: {md}"
    );

    let json: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("compare.json")).unwrap()).unwrap();
    assert_eq!(json["suite"], "product-v1");
    assert!(json["unpaired"].as_array().unwrap().is_empty());
}

// ---- D12: the eval driver can run the index the bridge actually selects -------------
//
// Before D12 `eval/src/driver/direct.rs` built a `GrepIndex` unconditionally, so an eval run
// structurally could not measure a deployment configured with `[direct] qmd = true` — which
// is the configuration a vault large enough to need it runs. These two tests use a FAKE `qmd`
// binary (a shell script whose stdout is a canned hit list) so CI can prove the selection and
// the store filter with no `qmd` installed anywhere.

/// Write a `qmd` stand-in that prints `canned` for any `search`/`query` invocation and
/// succeeds on `--version`. Returns its path.
///
/// `/bin/sh`, and nothing in it needs an escape: the JSON is written to its own file and the
/// script `cat`s it. CI's `/bin/sh` is dash, where a `printf '\xNN'` a bash author would
/// reach for silently emits the literal text.
fn fake_qmd(dir: &std::path::Path, canned: &str) -> std::path::PathBuf {
    let json = dir.join("hits.json");
    fs::write(&json, canned).unwrap();
    let bin = dir.join("qmd");
    fs::write(
        &bin,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'qmd 0.0.0-fake'; exit 0; fi\n\
             : > {marker}\ncat {json}\n",
            marker = dir.join("was-run").display(),
            json = json.display(),
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    }
    bin
}

/// Run a one-task suite on the direct driver with the given extra args, returning the task
/// row and its transcript text — the transcript read here, before the temp dir is dropped,
/// because `transcript_path` in `results.json` is relative to the run's output directory.
fn run_one_task_direct(
    extra: &[&str],
    fixture_files: serde_json::Value,
) -> (serde_json::Value, String) {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");
    let suite = serde_json::json!({
        "name": "idx",
        "tasks": [{
            "id": "search-it",
            "class": "multi-document-search",
            "prompt": "search for the launch",
            "workspace": "fixture",
            "allowed_tools": ["Grep"],
            "level": "read",
            "fixture_files": fixture_files,
            "assertions": [{"type": "completed"}]
        }]
    });
    fs::write(&suite_path, serde_json::to_vec_pretty(&suite).unwrap()).unwrap();
    // One scripted turn: search once, then answer with what came back.
    let mock = serde_json::json!({
        "responses": {
            "search-it": [
                {"type": "tool_calls", "calls": [
                    {"name": "vault_search", "arguments": {"query": "launch"}}
                ]},
                {"type": "text", "text": "done"}
            ]
        }
    });
    fs::write(&mock_path, serde_json::to_vec_pretty(&mock).unwrap()).unwrap();

    let mut args: Vec<String> = vec![
        "run".into(),
        "--driver".into(),
        "direct".into(),
        "--suite".into(),
        suite_path.to_str().unwrap().into(),
        "--out".into(),
        out.to_str().unwrap().into(),
        "--mock".into(),
        mock_path.to_str().unwrap().into(),
    ];
    args.extend(extra.iter().map(|s| s.to_string()));
    let status = Command::new(bin()).args(&args).status().unwrap();
    assert!(status.success(), "direct run should exit success");
    let results: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("results.json")).unwrap()).unwrap();
    let task = results["tasks"].as_array().unwrap()[0].clone();
    let transcript = task["transcript_path"]
        .as_str()
        .map(|p| fs::read_to_string(out.join(p)).unwrap_or_default())
        .unwrap_or_default();
    (task, transcript)
}

/// `--index qmd` REALLY REACHES THE BINARY. The fake qmd is the only thing that could have
/// produced this id: the grep index would have had to find the word in a document that does
/// not contain it.
#[test]
fn the_direct_driver_searches_through_qmd_when_asked() {
    let home = tempfile::tempdir().unwrap();
    let qmd = fake_qmd(
        home.path(),
        r#"[{"file":"qmd://vault/notes/only-qmd-knows.md","score":9.5,"line":3,"snippet":"the launch is on Tuesday"}]"#,
    );
    let (task, transcript) = run_one_task_direct(
        &[
            "--index",
            "qmd",
            "--qmd-collection",
            "vault",
            "--qmd-bin",
            qmd.to_str().unwrap(),
        ],
        serde_json::json!({
            // The word "launch" appears NOWHERE in the store, so grep can return nothing.
            "notes/only-qmd-knows.md": "# Only qmd knows\n\nnothing here says the word\n",
        }),
    );
    assert_eq!(task["tool_names"][0], "vault_search");
    assert_eq!(task["completed"], true, "{task}");
    // THE FALSIFIABLE HALF, and it has to be a side effect rather than a transcript line: a
    // transcript records tool CALLS and never tool RESULTS, because results are vault
    // content. The marker exists only if the child was spawned, which the grep index would
    // never do. What came BACK from it is asserted in
    // `driver::direct::tests::a_qmd_hit_the_store_will_not_open_is_dropped`, where the hits
    // are in hand rather than behind the boundary.
    assert!(
        home.path().join("was-run").exists(),
        "the qmd binary was never spawned; the driver did not select qmd"
    );
    assert!(!transcript.is_empty(), "the run wrote a transcript");
}

/// AND THE STORE STILL FILTERS IT. qmd is told about a cold document and a document that
/// does not exist; neither may reach the model, because the store is the boundary and the
/// index is behind it. This is the property D12's one-boundary rewrite is about, asserted on
/// the path the eval now runs.
#[test]
fn a_qmd_hit_the_store_will_not_open_never_reaches_the_turn() {
    let home = tempfile::tempdir().unwrap();
    let qmd = fake_qmd(
        home.path(),
        r#"[{"file":"qmd://vault/private/secret.md","score":9.9,"line":1,"snippet":"COLDBODY launch"},
            {"file":"qmd://vault/notes/ghost.md","score":9.8,"line":1,"snippet":"launch"},
            {"file":"qmd://vault/notes/real.md","score":1.0,"line":3,"snippet":"the launch is on Tuesday"}]"#,
    );
    let (task, transcript) = run_one_task_direct(
        &[
            "--index",
            "qmd",
            "--qmd-collection",
            "vault",
            "--qmd-bin",
            qmd.to_str().unwrap(),
        ],
        serde_json::json!({
            // Cold by its own front matter, so `stat` reports Cold and the filter drops it.
            "private/secret.md": "---\nvisibility: cold\n---\n# Secret\n\nCOLDBODY launch\n",
            "notes/real.md": "# Real\n\nthe launch is on Tuesday\n",
            // `notes/ghost.md` is deliberately NOT created: qmd's index is stale, and a hit
            // for a document the store cannot stat must vanish rather than 404 the turn.
        }),
    );
    assert!(
        home.path().join("was-run").exists(),
        "the qmd binary was never spawned"
    );
    let seen = format!("{task}{transcript}");
    assert!(
        !seen.contains("COLDBODY"),
        "a cold document's snippet reached the turn: {seen}"
    );
    assert!(
        !seen.contains("secret.md"),
        "a cold document's id reached the turn: {seen}"
    );
    assert!(
        !seen.contains("ghost.md"),
        "a hit for a document the store cannot stat reached the turn: {seen}"
    );
    assert_eq!(task["completed"], true, "{task}");
}

/// `--index qmd` WITHOUT A COLLECTION IS REFUSED, not defaulted. A guessed collection strips
/// the wrong prefix off every hit and reports ids that resolve to nothing, which a reader
/// cannot tell from "the vault does not contain it".
#[test]
fn qmd_without_a_collection_is_refused_at_the_cli() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    fs::write(
        &suite_path,
        serde_json::to_vec_pretty(&serde_json::json!({
            "name": "idx",
            "tasks": [{
                "id": "t", "class": "c", "prompt": "p", "workspace": "fixture",
                "assertions": [{"type": "completed"}]
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    let out = Command::new(bin())
        .args([
            "run",
            "--driver",
            "direct",
            "--index",
            "qmd",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            tmp.path().join("out").to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success(), "a run with no collection must fail");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("--qmd-collection"),
        "the refusal must name the missing flag: {err}"
    );
}

/// `compare` refuses two runs of different suites rather than pairing nothing and calling
/// it parity.
#[test]
fn compare_refuses_two_different_suites() {
    let tmp = tempfile::tempdir().unwrap();
    let mk = |name: &str| -> std::path::PathBuf {
        let dir = tmp.path().join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("results.json"),
            serde_json::json!({
                "suite": name, "driver": "direct", "endpoint": null,
                "model": null, "mock": true, "tasks": []
            })
            .to_string(),
        )
        .unwrap();
        dir
    };
    let output = Command::new(bin())
        .args([
            "compare",
            "--a",
            mk("one").to_str().unwrap(),
            "--b",
            mk("two").to_str().unwrap(),
            "--out",
            tmp.path().join("cmp").to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("different suites"), "{stderr}");
}

/// The direct driver refuses a tool its manifest has no answer for, naming the table —
/// rather than running the task with the tool silently absent and scoring the miss.
#[test]
fn the_direct_driver_refuses_an_unmapped_tool() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");
    fs::write(
        &suite_path,
        serde_json::json!({
            "name": "unmapped",
            "tasks": [{
                "id": "t", "class": "c", "prompt": "go", "workspace": "fixture",
                "allowed_tools": ["Read", "Bash(ls:*)"],
                "assertions": [{"type": "completed"}]
            }]
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        &mock_path,
        serde_json::json!({"responses": {"t": [{"type": "text", "text": "hi"}]}}).to_string(),
    )
    .unwrap();

    let status = Command::new(bin())
        .args([
            "run",
            "--driver",
            "direct",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            "--mock",
            mock_path.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(
        status.success(),
        "the run completes; the TASK is what fails"
    );

    let results: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("results.json")).unwrap()).unwrap();
    let task = &results["tasks"][0];
    assert_eq!(task["passed"], false);
    let err = task["error"]
        .as_str()
        .expect("a harness error, not a model miss");
    assert!(err.contains("Bash(ls:*)"), "{err}");
    assert!(
        err.contains("vault_read"),
        "the message names the table: {err}"
    );
}

/// The vault refusal now has two spellings, and both are refused before anything runs.
#[test]
fn vault_readonly_write_level_is_refused_at_cli() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.json");
    fs::write(
        &suite_path,
        serde_json::json!({
            "name": "bad-level",
            "tasks": [{
                "id": "danger", "class": "vault-qa", "prompt": "go",
                "workspace": "vault-readonly", "allowed_tools": ["Read"],
                "level": "write",
                "assertions": [{"type": "completed"}]
            }]
        })
        .to_string(),
    )
    .unwrap();

    let output = Command::new(bin())
        .args([
            "run",
            "--suite",
            suite_path.to_str().unwrap(),
            "--out",
            tmp.path().join("out").to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!output.status.success(), "must refuse the write level");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("level: write") && stderr.contains("vault-readonly"),
        "stderr should explain the refusal, got: {stderr}"
    );
}
