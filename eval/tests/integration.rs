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
