//! `jesse-eval` — an offline eval harness for the Jesse assistant.
//!
//! Two subcommands:
//!   * `run`   — execute a task suite against a Claude-compatible endpoint (or a
//!               local mock) and score it.
//!   * `judge` — pairwise LLM-as-judge comparison of a candidate run against a
//!               baseline run, over both answer orderings.

mod assertions;
mod judge;
mod mock;
mod runner;
mod suite;
mod transcript;

use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

#[derive(Parser)]
#[command(name = "jesse-eval", about = "Offline eval harness for the Jesse assistant")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Run a suite and write results.json + scorecard.md.
    Run(RunArgs),
    /// Judge a candidate run against a baseline run.
    Judge(JudgeArgs),
}

#[derive(Parser)]
struct RunArgs {
    /// `ANTHROPIC_BASE_URL` for the child process. Omit for ambient auth.
    #[arg(long)]
    endpoint: Option<String>,
    /// `ANTHROPIC_MODEL` for the child process. Omit for the endpoint default.
    #[arg(long)]
    model: Option<String>,
    /// `ANTHROPIC_AUTH_TOKEN` for the child (only used with --endpoint).
    #[arg(long, default_value = "jesse-eval-local")]
    auth_token: String,
    /// Suite JSON file.
    #[arg(long)]
    suite: PathBuf,
    /// Output directory.
    #[arg(long)]
    out: PathBuf,
    /// Replay canned NDJSON from this mock file instead of spawning `claude`.
    #[arg(long)]
    mock: Option<PathBuf>,
    /// Path to the `claude` binary.
    #[arg(long, default_value = "claude")]
    claude_bin: String,
    /// Per-task wall-clock timeout, seconds.
    #[arg(long, default_value_t = 600)]
    timeout_secs: u64,
}

#[derive(Parser)]
struct JudgeArgs {
    /// Baseline results directory (contains results.json).
    #[arg(long)]
    baseline: PathBuf,
    /// Candidate results directory (contains results.json).
    #[arg(long)]
    candidate: PathBuf,
    /// Output directory.
    #[arg(long)]
    out: PathBuf,
    /// Path to the `claude` binary.
    #[arg(long, default_value = "claude")]
    claude_bin: String,
    /// Per-call wall-clock timeout, seconds.
    #[arg(long, default_value_t = 300)]
    timeout_secs: u64,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Commands::Run(a) => match do_run(a) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("jesse-eval run: {e}");
                ExitCode::FAILURE
            }
        },
        Commands::Judge(a) => match do_judge(a) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("jesse-eval judge: {e}");
                ExitCode::FAILURE
            }
        },
    }
}

fn do_run(a: RunArgs) -> Result<(), String> {
    let bytes = std::fs::read(&a.suite)
        .map_err(|e| format!("could not read suite {}: {e}", a.suite.display()))?;
    let suite = suite::Suite::from_json(&bytes)?;

    let mock = match &a.mock {
        Some(p) => {
            let mb = std::fs::read(p)
                .map_err(|e| format!("could not read mock {}: {e}", p.display()))?;
            Some(mock::MockFile::from_json(&mb)?)
        }
        None => None,
    };

    let cfg = runner::RunConfig {
        claude_bin: a.claude_bin,
        endpoint: a.endpoint,
        model: a.model,
        auth_token: a.auth_token,
        mock,
        timeout: Duration::from_secs(a.timeout_secs),
        out_dir: a.out.clone(),
    };

    let report = runner::run_suite(&suite, &cfg)?;

    // Echo the scorecard and a one-line summary to stdout.
    print!("{}", runner::scorecard(&report));
    let passed = report.tasks.iter().filter(|t| t.passed).count();
    let errored: Vec<&str> = report
        .tasks
        .iter()
        .filter(|t| t.error.is_some())
        .map(|t| t.id.as_str())
        .collect();
    println!(
        "\n{}/{} tasks passed. Results in {}",
        passed,
        report.tasks.len(),
        a.out.display()
    );
    if !errored.is_empty() {
        eprintln!("harness errors in: {}", errored.join(", "));
    }
    Ok(())
}

fn do_judge(a: JudgeArgs) -> Result<(), String> {
    let report = judge::judge(
        &a.baseline,
        &a.candidate,
        &a.out,
        &a.claude_bin,
        Duration::from_secs(a.timeout_secs),
    )?;
    println!(
        "Judged {} task(s): candidate {}, baseline {}, ties {}. Output in {}",
        report.tasks.len(),
        report.candidate_wins,
        report.baseline_wins,
        report.ties,
        a.out.display()
    );
    Ok(())
}
