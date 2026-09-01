//! `jesse-eval` — an offline eval harness for the Jesse assistant.
//!
//! Three subcommands:
//!
//! * `run` — execute a task suite through a [`driver`] (the `claude` CLI, or the
//!   in-process agent loop) against an endpoint or a local mock, and score it.
//! * `judge` — pairwise LLM-as-judge comparison of a candidate run against a
//!   baseline run, over both answer orderings.
//! * `compare` — mechanical, model-free comparison of two runs of the SAME suite:
//!   per-class pass rates, latency, tool calls, usage and cost, side by side.

mod assertions;
mod compare;
mod driver;
mod judge;
mod mapping;
mod mock;
mod runner;
mod suite;
mod transcript;

use clap::{Parser, Subcommand, ValueEnum};
use jesse_agent::{PersonaPack, PriceDeck, Thinking, Wire};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "jesse-eval",
    about = "Offline eval harness for the Jesse assistant"
)]
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
    /// Compare two runs of the same suite, mechanically and with no model.
    Compare(CompareArgs),
    /// Print the tool-name mapping table the `direct` driver applies to `allowed_tools`.
    Tools,
}

/// Which runner executes each task. See `eval/README.md` and `src/driver/`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum DriverKind {
    /// Spawn `claude -p` per task. The default, and unchanged by the driver seam.
    ClaudeCli,
    /// Run `jesse_agent::run_turn` in this process, over the vault tool set.
    Direct,
}

/// Which search index a `direct` run answers `vault_search` with.
///
/// **THE POINT OF THE FLAG IS THAT THE BRIDGE HAS A CHOICE HERE AND THE EVAL DID NOT.**
/// `bridge/src/harness/direct.rs` selects `qmd` whenever `[direct] qmd = true` and a
/// collection is named, and grep otherwise; this driver hardcoded grep, so an eval run could
/// never measure the configuration a deployment with a large vault actually runs. `grep`
/// stays the default because CI has no `qmd` binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum IndexArg {
    Grep,
    Qmd,
}

/// The provider wire the direct driver speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum WireArg {
    Messages,
    Chat,
    Responses,
}

impl From<WireArg> for Wire {
    fn from(w: WireArg) -> Wire {
        match w {
            WireArg::Messages => Wire::Messages,
            WireArg::Chat => Wire::Chat,
            WireArg::Responses => Wire::Responses,
        }
    }
}

#[derive(Parser)]
struct RunArgs {
    /// Which runner executes each task.
    #[arg(long, value_enum, default_value_t = DriverKind::ClaudeCli)]
    driver: DriverKind,
    /// The endpoint: `ANTHROPIC_BASE_URL` for the CLI child, the base URL for `direct`.
    /// Omit for ambient auth (CLI) or with `--mock` (direct).
    #[arg(long)]
    endpoint: Option<String>,
    /// The model id. Omit for the endpoint default.
    #[arg(long)]
    model: Option<String>,
    /// The wire the `direct` driver speaks. Ignored by `claude-cli`.
    #[arg(long, value_enum, default_value_t = WireArg::Messages)]
    wire: WireArg,
    /// `ANTHROPIC_AUTH_TOKEN` for the CLI child (only used with --endpoint).
    #[arg(long, default_value = "jesse-eval-local")]
    auth_token: String,
    /// The NAME of the environment variable holding the API key, for the `direct` driver.
    ///
    /// THE NAME, NEVER THE KEY. A key passed as a flag is a key in shell history and in
    /// `ps` output; this binary has no way to accept one.
    #[arg(long, default_value = "JESSE_EVAL_TOKEN_ENV")]
    token_env: String,
    /// Suite JSON file.
    #[arg(long)]
    suite: PathBuf,
    /// Output directory.
    #[arg(long)]
    out: PathBuf,
    /// Replay a fixture instead of calling anything.
    ///
    /// The FORMAT DEPENDS ON THE DRIVER: `claude-cli` takes canned stream-json NDJSON (and
    /// a `files` map standing in for tool side effects); `direct` takes a scripted-provider
    /// fixture and runs the real tools over the real workspace. See `eval/README.md`.
    #[arg(long)]
    mock: Option<PathBuf>,
    /// Path to the `claude` binary.
    #[arg(long, default_value = "claude")]
    claude_bin: String,
    /// The index a `direct` run searches with. Ignored by `claude-cli`.
    #[arg(long, value_enum, default_value_t = IndexArg::Grep)]
    index: IndexArg,
    /// The qmd COLLECTION whose documents map onto the workspace root.
    ///
    /// REQUIRED with `--index qmd` and deliberately never guessed, for the reason
    /// `jesse_agent::index::QmdConfig` gives: qmd reports a hit as `qmd://<collection>/<path>`
    /// and stripping the wrong prefix produces ids that resolve to the wrong documents.
    #[arg(long)]
    qmd_collection: Option<String>,
    /// Where the qmd collection's ROOT sits inside the workspace, when the two are not the
    /// same directory (a vault indexed at `<workspace>/vault`, say). Omit when they coincide.
    ///
    /// Wrong or missing where it is needed, every hit resolves to a path the store does not
    /// have and is dropped — a run that scores as though the vault were empty.
    #[arg(long)]
    qmd_collection_prefix: Option<String>,
    /// Path to the `qmd` binary. Omit to resolve the bare name on `PATH`.
    #[arg(long)]
    qmd_bin: Option<PathBuf>,
    /// Per-task wall-clock timeout, seconds.
    #[arg(long, default_value_t = 600)]
    timeout_secs: u64,
    /// USD per million input tokens, for the reported cost. Zero by default: a stated zero
    /// is honest where a plausible made-up rate is not.
    #[arg(long, default_value_t = 0.0)]
    price_in: f64,
    /// USD per million cache-read tokens.
    #[arg(long, default_value_t = 0.0)]
    price_cached: f64,
    /// USD per million output tokens.
    #[arg(long, default_value_t = 0.0)]
    price_out: f64,
}

#[derive(Parser)]
struct CompareArgs {
    /// Baseline results directory (contains results.json).
    #[arg(long)]
    a: PathBuf,
    /// Candidate results directory (contains results.json).
    #[arg(long)]
    b: PathBuf,
    /// Output directory for compare.md and compare.json.
    #[arg(long)]
    out: PathBuf,
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
        Commands::Tools => {
            print!("{}", mapping::render_table_markdown());
            ExitCode::SUCCESS
        }
        Commands::Compare(a) => match do_compare(a) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("jesse-eval compare: {e}");
                ExitCode::FAILURE
            }
        },
    }
}

fn do_run(a: RunArgs) -> Result<(), String> {
    let bytes = std::fs::read(&a.suite)
        .map_err(|e| format!("could not read suite {}: {e}", a.suite.display()))?;
    let suite = suite::Suite::from_json(&bytes)?;

    let mock_bytes = match &a.mock {
        Some(p) => Some(
            std::fs::read(p).map_err(|e| format!("could not read mock {}: {e}", p.display()))?,
        ),
        None => None,
    };
    let timeout = Duration::from_secs(a.timeout_secs);

    // ONE PLACE PICKS THE DRIVER, and it is the only place in this binary that knows there
    // is more than one.
    let driver: Box<dyn driver::Driver> = match a.driver {
        DriverKind::ClaudeCli => Box::new(driver::ClaudeCliDriver {
            claude_bin: a.claude_bin,
            endpoint: a.endpoint,
            model: a.model,
            auth_token: a.auth_token,
            mock: match &mock_bytes {
                Some(b) => Some(mock::MockFile::from_json(b)?),
                None => None,
            },
            timeout,
        }),
        DriverKind::Direct => {
            let mock = match &mock_bytes {
                Some(b) => {
                    // Parsed once here to fail loudly on a malformed fixture before any
                    // task runs; the raw value is what the driver keeps, because
                    // `{{hash:…}}` can only be resolved against a workspace that does not
                    // exist yet.
                    jesse_agent::provider::scripted::ScriptFixture::from_json(b)?;
                    Some(
                        serde_json::from_slice::<serde_json::Value>(b)
                            .map_err(|e| format!("invalid mock JSON: {e}"))?,
                    )
                }
                None => None,
            };
            // REFUSED AT THE BOUNDARY, not defaulted. `--index qmd` without a collection
            // would silently search with the wrong prefix stripped and report hits that
            // resolve to nothing, which reads as "the vault does not contain it".
            let index = match a.index {
                IndexArg::Grep => driver::EvalIndex::Grep,
                IndexArg::Qmd => driver::EvalIndex::Qmd {
                    collection: a.qmd_collection.clone().ok_or(
                        "--index qmd needs --qmd-collection; the collection name cannot be \
                         guessed from the workspace path",
                    )?,
                    collection_prefix: a.qmd_collection_prefix.clone().unwrap_or_default(),
                    binary: a.qmd_bin.clone(),
                },
            };
            Box::new(driver::DirectDriver {
                index,
                base_url: a.endpoint,
                wire: a.wire.into(),
                model: a.model,
                token_env: Some(a.token_env),
                mock,
                timeout,
                prices: PriceDeck {
                    in_per_m: a.price_in,
                    cached_per_m: a.price_cached,
                    out_per_m: a.price_out,
                },
                persona: PersonaPack::default(),
                thinking: Thinking::Off,
            })
        }
    };

    let cfg = runner::RunConfig {
        driver,
        prices: PriceDeck {
            in_per_m: a.price_in,
            cached_per_m: a.price_cached,
            out_per_m: a.price_out,
        },
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

fn do_compare(a: CompareArgs) -> Result<(), String> {
    let report = compare::compare(&a.a, &a.b, &a.out)?;
    print!("{}", compare::render(&report));
    println!("\nWritten to {}", a.out.display());
    Ok(())
}
