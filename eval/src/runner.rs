//! The `run` subcommand: prepare each task's workspace, hand it to a [`Driver`],
//! evaluate assertions, and write `results.json` + `scorecard.md`.
//!
//! **NOTHING HERE KNOWS HOW A TASK IS EXECUTED.** Workspace preparation, scoring,
//! aggregation and the scorecard are the same for every driver; the driver is a
//! `Box<dyn Driver>` this module never inspects beyond its id, wire and model. That
//! split is what lets `compare` put two runs side by side and mean it.

use crate::assertions::{eval_all, AssertionResult};
use crate::driver::{Driver, PreparedWorkspace};
use crate::suite::{Suite, Task, Workspace};
use crate::transcript::{Transcript, Usage};
use jesse_agent::PriceDeck;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use tokio_util::sync::CancellationToken;

/// Configuration for a run.
pub struct RunConfig {
    /// What actually runs each task.
    pub driver: Box<dyn Driver>,
    /// The price deck the per-task cost is computed with. `ZERO` by default, and a stated
    /// zero is honest where a plausible made-up rate is not.
    pub prices: PriceDeck,
    pub out_dir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenRecord {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
}

impl TokenRecord {
    /// Total tokens, for a comparison that wants one number.
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_creation
    }
}

impl From<&Usage> for TokenRecord {
    fn from(u: &Usage) -> Self {
        TokenRecord {
            input: u.input_tokens,
            output: u.output_tokens,
            cache_read: u.cache_read_input_tokens,
            cache_creation: u.cache_creation_input_tokens,
        }
    }
}

/// The dollar cost of a token record under a deck.
fn cost_of(t: &TokenRecord, prices: &PriceDeck) -> f64 {
    ((t.input + t.cache_creation) as f64 * prices.in_per_m
        + t.cache_read as f64 * prices.cached_per_m
        + t.output as f64 * prices.out_per_m)
        / 1_000_000.0
}

/// One task's full result record (serialized into `results.json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResult {
    pub id: String,
    pub class: String,
    pub workspace: String,
    pub judged: bool,
    pub rubric: Option<String>,
    pub passed: bool,
    pub completed: bool,
    pub wall_ms: u64,
    /// Harness-measured time to first text delta.
    pub measured_ttft_ms: Option<u64>,
    /// Model-reported time to first token (from the result line).
    pub result_ttft_ms: Option<u64>,
    pub tool_calls: u32,
    /// The name of every tool call, in dispatch order.
    #[serde(default)]
    pub tool_names: Vec<String>,
    pub tokens: Option<TokenRecord>,
    /// The run's dollar cost under the run's price deck. `0.0` with the default deck.
    #[serde(default)]
    pub cost_usd: f64,
    pub final_answer: Option<String>,
    pub assertions: Vec<AssertionResult>,
    pub transcript_path: String,
    /// Harness-level error (spawn failure, timeout, mock miss). Not a model miss.
    pub error: Option<String>,
}

/// Top-level `results.json` document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunReport {
    pub suite: String,
    /// Which driver ran it. `claude-cli` for every run recorded before D7 — absent from
    /// those files, and defaulted here so an old results dir still loads.
    #[serde(default = "legacy_driver")]
    pub driver: String,
    /// The wire, when the driver has one of its own.
    #[serde(default)]
    pub wire: Option<String>,
    /// The search index that answered, when the driver owns one. Absent from every run
    /// recorded before D12, which is why it defaults rather than being required.
    #[serde(default)]
    pub index: Option<String>,
    pub endpoint: Option<String>,
    pub model: Option<String>,
    pub mock: bool,
    pub tasks: Vec<TaskResult>,
}

fn legacy_driver() -> String {
    "claude-cli".to_string()
}

/// Populate a fresh workspace for a fixture task; return the dir to run in.
/// For vault tasks, returns the real vault path and writes nothing.
fn prepare_workspace(task: &Task, temp_root: &Path) -> Result<PreparedWorkspace, String> {
    let dir = match task.workspace {
        Workspace::VaultReadonly => crate::suite::vault_dir(),
        Workspace::Fixture => {
            let dir = temp_root.join(&task.id);
            std::fs::create_dir_all(&dir)
                .map_err(|e| format!("could not create fixture dir: {e}"))?;
            for (rel, content) in &task.fixture_files {
                let full = dir.join(rel);
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| format!("could not create {}: {e}", parent.display()))?;
                }
                std::fs::write(&full, content)
                    .map_err(|e| format!("could not write fixture {rel}: {e}"))?;
            }
            dir
        }
    };
    Ok(PreparedWorkspace {
        kind: task.workspace,
        dir,
    })
}

/// Run a whole suite. Returns the report (also written to `out_dir`).
///
/// SYNCHRONOUS on the outside and `block_on` inside: the harness runs one task at a time on
/// purpose (a latency number measured while three other tasks share the machine is not a
/// latency number), so a current-thread runtime driving one turn is the whole concurrency
/// story. The runtime exists because the agent loop is async, not because anything here is.
pub fn run_suite(suite: &Suite, cfg: &RunConfig) -> Result<RunReport, String> {
    std::fs::create_dir_all(&cfg.out_dir).map_err(|e| format!("could not create out dir: {e}"))?;
    let transcripts_dir = cfg.out_dir.join("transcripts");
    std::fs::create_dir_all(&transcripts_dir)
        .map_err(|e| format!("could not create transcripts dir: {e}"))?;
    let answers_dir = cfg.out_dir.join("answers");
    std::fs::create_dir_all(&answers_dir)
        .map_err(|e| format!("could not create answers dir: {e}"))?;

    // Fixture workspaces live under one temp root for the whole run.
    let temp_root = tempfile::Builder::new()
        .prefix("jesse-eval-")
        .tempdir()
        .map_err(|e| format!("could not create temp root: {e}"))?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("could not start the runtime: {e}"))?;

    let mut results = Vec::new();
    for task in &suite.tasks {
        // Load-bearing: refuse a vault task with a non-read tool before running.
        task.validate()?;

        let workspace = prepare_workspace(task, temp_root.path())?;
        let run = runtime.block_on(
            cfg.driver
                .run_task(task, &workspace, CancellationToken::new()),
        );

        // Persist the raw transcript.
        let transcript_rel = format!("transcripts/{}.ndjson", task.id);
        let _ = std::fs::write(cfg.out_dir.join(&transcript_rel), run.lines.join("\n"));

        let parsed: &Transcript = &run.transcript;

        // Judged tasks: save the final answer as an artifact for `judge`.
        if task.judged && !run.answer.is_empty() {
            let _ = std::fs::write(answers_dir.join(format!("{}.txt", task.id)), &run.answer);
        }

        let (passed, assertion_results) = eval_all(
            &task.assertions,
            parsed,
            &workspace.dir,
            task.persona.as_ref(),
        );
        // A harness error (couldn't even run) is not a legitimate pass.
        let passed = passed && run.error.is_none();
        let tokens = TokenRecord::from(&run.usage);
        let cost_usd = cost_of(&tokens, &cfg.prices);

        results.push(TaskResult {
            id: task.id.clone(),
            class: task.class.clone(),
            workspace: format!("{:?}", task.workspace).to_lowercase(),
            judged: task.judged,
            rubric: task.rubric.clone(),
            passed,
            completed: run.completed,
            wall_ms: run.wall_ms,
            measured_ttft_ms: run.ttft_ms,
            result_ttft_ms: parsed.result_ttft_ms,
            tool_calls: run.tool_calls as u32,
            tool_names: run.tool_names.clone(),
            tokens: Some(tokens),
            cost_usd,
            final_answer: parsed.final_answer.clone(),
            assertions: assertion_results,
            transcript_path: transcript_rel,
            error: run.error.clone(),
        });
    }

    let report = RunReport {
        suite: suite.name.clone(),
        driver: cfg.driver.id().to_string(),
        wire: cfg.driver.wire(),
        index: cfg.driver.index(),
        endpoint: cfg.driver.endpoint(),
        model: cfg.driver.model(),
        mock: cfg.driver.is_mock(),
        tasks: results,
    };

    std::fs::write(
        cfg.out_dir.join("results.json"),
        serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("could not write results.json: {e}"))?;

    std::fs::write(cfg.out_dir.join("scorecard.md"), scorecard(&report))
        .map_err(|e| format!("could not write scorecard.md: {e}"))?;

    Ok(report)
}

/// Render the per-class + totals scorecard.
pub fn scorecard(report: &RunReport) -> String {
    struct Agg {
        n: u32,
        passed: u32,
        latency_sum: u64,
        tool_sum: u64,
    }
    let mut by_class: BTreeMap<String, Agg> = BTreeMap::new();
    let mut total = Agg {
        n: 0,
        passed: 0,
        latency_sum: 0,
        tool_sum: 0,
    };
    for t in &report.tasks {
        let a = by_class.entry(t.class.clone()).or_insert(Agg {
            n: 0,
            passed: 0,
            latency_sum: 0,
            tool_sum: 0,
        });
        for agg in [a, &mut total] {
            agg.n += 1;
            if t.passed {
                agg.passed += 1;
            }
            agg.latency_sum += t.wall_ms;
            agg.tool_sum += t.tool_calls as u64;
        }
    }

    let mut out = String::new();
    out.push_str(&format!("# Scorecard — {}\n\n", report.suite));
    let target = match (&report.endpoint, &report.model) {
        (Some(e), Some(m)) => format!("endpoint `{e}`, model `{m}`"),
        (Some(e), None) => format!("endpoint `{e}`, default model"),
        (None, _) if report.mock => "mock (canned responses)".to_string(),
        (None, _) => "ambient auth + default model".to_string(),
    };
    // THE HEADER NAMES THE RUNNER, not only the endpoint. Two runs of one suite that differ
    // only in which driver produced them are the comparison this harness now exists to
    // make, and a scorecard that did not say which is which would be unreadable a week later.
    out.push_str(&format!(
        "Driver: `{}` · wire: {} · model: {} · index: {}\n\n",
        report.driver,
        report.wire.as_deref().unwrap_or("n/a"),
        report.model.as_deref().unwrap_or("default"),
        report.index.as_deref().unwrap_or("n/a"),
    ));
    out.push_str(&format!("Target: {target}\n\n"));
    out.push_str("| Class | Pass rate | Mean latency | Mean tool calls |\n");
    out.push_str("|---|---|---|---|\n");
    for (class, a) in &by_class {
        out.push_str(&format!(
            "| {} | {}/{} ({:.0}%) | {} ms | {:.1} |\n",
            class,
            a.passed,
            a.n,
            100.0 * a.passed as f64 / a.n as f64,
            a.latency_sum / a.n as u64,
            a.tool_sum as f64 / a.n as f64,
        ));
    }
    if total.n > 0 {
        out.push_str(&format!(
            "| **TOTAL** | **{}/{} ({:.0}%)** | **{} ms** | **{:.1}** |\n",
            total.passed,
            total.n,
            100.0 * total.passed as f64 / total.n as f64,
            total.latency_sum / total.n as u64,
            total.tool_sum as f64 / total.n as f64,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(cost: f64) -> TaskResult {
        TaskResult {
            id: "t".into(),
            class: "c".into(),
            workspace: "fixture".into(),
            judged: false,
            rubric: None,
            passed: true,
            completed: true,
            wall_ms: 10,
            measured_ttft_ms: None,
            result_ttft_ms: None,
            tool_calls: 0,
            tool_names: vec![],
            tokens: None,
            cost_usd: cost,
            final_answer: None,
            assertions: vec![],
            transcript_path: "x".into(),
            error: None,
        }
    }

    #[test]
    fn the_scorecard_header_names_the_driver_wire_and_model() {
        let report = RunReport {
            suite: "s".into(),
            driver: "direct".into(),
            wire: Some("chat".into()),
            index: Some("grep".into()),
            endpoint: Some("http://example".into()),
            model: Some("m".into()),
            mock: false,
            tasks: vec![record(0.0)],
        };
        let card = scorecard(&report);
        assert!(card.contains("Driver: `direct`"), "{card}");
        assert!(card.contains("wire: chat"), "{card}");
        assert!(card.contains("model: m"), "{card}");
    }

    #[test]
    fn a_results_file_without_a_driver_field_loads_as_the_cli() {
        let json = serde_json::json!({
            "suite": "s", "endpoint": null, "model": null, "mock": true, "tasks": []
        });
        let report: RunReport = serde_json::from_value(json).expect("legacy results parse");
        assert_eq!(report.driver, "claude-cli");
        assert_eq!(report.wire, None);
    }

    #[test]
    fn cost_uses_the_deck_and_is_zero_by_default() {
        let t = TokenRecord {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_creation: 0,
        };
        assert_eq!(cost_of(&t, &PriceDeck::ZERO), 0.0);
        let deck = PriceDeck {
            in_per_m: 3.0,
            cached_per_m: 0.3,
            out_per_m: 15.0,
        };
        assert!((cost_of(&t, &deck) - 18.3).abs() < 1e-9);
    }
}
