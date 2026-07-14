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

/// Run the SHIPPED `vaultqa-v1` suite through a mock via `--mock` and return the
/// parsed `results.json` tasks. Uses `include_str!` so the suite and mock under
/// test are the committed artifacts, not copies.
fn run_vaultqa_mock(mock_json: &str) -> serde_json::Value {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("vaultqa-v1.json");
    let mock_path = tmp.path().join("mock.json");
    let out = tmp.path().join("out");
    fs::write(&suite_path, include_str!("../suites/vaultqa-v1.json")).unwrap();
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
fn vaultqa_v1_good_mock_passes_every_task() {
    let results = run_vaultqa_mock(include_str!("../suites/validation/mock-good.json"));
    let tasks = results["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 10, "vaultqa-v1 has 10 tasks");
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
fn vaultqa_v1_bad_mock_fails_intended_assertions() {
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
        "vq-negative-absent bad answer must fail the absence-ack and the 38217 exclusion; fired: {neg:?}"
    );
    // Numeric target: capturing the 204 start weight is out of band.
    assert!(
        fired("vq-weight-target").contains(&"number_in_range".to_string()),
        "vq-weight-target bad answer (204 lbs) must fail number_in_range"
    );
}
