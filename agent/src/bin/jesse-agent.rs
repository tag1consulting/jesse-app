//! **`jesse-agent turn`** — run one agent turn by hand.
//!
//! It exists so a multi-step turn can be watched happening, against a real endpoint or a
//! loopback mock, without a bridge and without a phone. The tests prove the loop is
//! correct; this proves it is USABLE, which is a different claim and the one that catches
//! an interface nobody can drive.
//!
//! ```text
//!   jesse-agent turn \
//!     --wire chat --base-url http://127.0.0.1:8080/v1 --model some-model \
//!     --token-env SOME_PROVIDER_API_KEY \
//!     --root ./workspace --level read \
//!     [--thread direct-…] [--system-file persona.md]… [--budget-…] \
//!     "what is in my notes?"
//! ```
//!
//! **THE TOKEN IS NAMED, NEVER PASSED.** `--token-env` holds the NAME of the variable the
//! key lives in, exactly as `examples/smoke.rs` does it: a key passed as an argument is a
//! key in shell history and in `ps` output. Nothing here prints the token or the base URL —
//! a base URL routinely embeds a tenant or gateway identifier, and this output is meant to
//! be pasteable into a report.
//!
//! ---- OUTPUT ----------------------------------------------------------------
//!
//! **stdout** is the answer, streamed: text deltas printed as they arrive, and ONE line of
//! JSON at the end with the outcome. That split is what makes it pipeable — `… | jq` on the
//! last line, or watch the prose go past.
//!
//! **stderr** is the tool activity and the trace. It is the same split the provider layer
//! already uses for its audit line, and it is the reason `--root` can be pointed at a real
//! directory without the trace ending up inside the answer.
//!
//! **Exit codes** are the outcome, so a script does not have to parse anything:
//! `0` the model finished (including a `max_tokens` truncation — the answer is real),
//! `2` a budget stopped it, `3` cancelled, `1` anything else.
//!
//! ---- WHAT `--root` IS -------------------------------------------------------
//!
//! A directory the FIXTURE tool set is jailed to (`fs_list`, `fs_read`, `fs_write`). **D3
//! replaces it with the real vault tool set behind the same trait**, at which point this
//! flag names a vault instead. It is a fixture today precisely so the loop can be proved
//! end to end before there is a vault to prove it against.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use jesse_agent::provider::{build_provider, AuthScheme, ProviderConfig, Wire};
use jesse_agent::thread::ThreadId;
use jesse_agent::tools::{fixture::fixture_tool_set, Level, SystemClock, ToolSet};
use jesse_agent::turn::{run_turn, EventSink, StopReason, ToolActivity, TurnDeps, TurnInput};
use jesse_agent::{
    Budget, FileThreadStore, JsonlUsageSink, PriceDeck, Scope, SystemBlock, Thinking,
};
use tokio_util::sync::CancellationToken;

/// Where a turn's thread and usage ledger go when the caller does not say.
///
/// UNDER THE CURRENT DIRECTORY, NOT UNDER `--root`. Writing them into the tool root would
/// put the loop's own bookkeeping inside the directory the tools can read, so a turn could
/// read its own usage ledger and the previous turn's thread as if they were documents. That
/// is a strange enough thing to happen by accident that the default has to prevent it.
const DEFAULT_STATE_DIR: &str = ".jesse-agent";

/// The scope every CLI turn runs under.
///
/// A SINGLE FIXED SCOPE, as Phase 1 specifies. It is spelled out here rather than left
/// implicit so that the day it comes from a token instead, the change is visible as an edit
/// to this constant's construction and not as a new concept.
fn cli_scope() -> Scope {
    Scope::new("local", "owner", "default")
}

// ===========================================================================
// Arguments
// ===========================================================================

/// Hand-written, and it WITHHOLDS THE BASE URL — the same discipline `ProviderConfig` and
/// `AuthScheme` already carry in the library. `Args` is exactly the struct somebody prints
/// while debugging a bad invocation, and a base URL routinely embeds a tenant or a gateway
/// identifier. `token_env` is only the NAME of a variable, so it is safe to show and is the
/// diagnostic anyone actually wants.
impl std::fmt::Debug for Args {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Args")
            .field("wire", &self.wire)
            .field("base_url", &"<withheld>")
            .field("model", &self.model)
            .field("token_env", &self.token_env)
            .field("root", &self.root)
            .field("level", &self.level)
            .field("thread", &self.thread)
            .field("system_files", &self.system_files)
            .field("state_dir", &self.state_dir)
            .field("budget", &self.budget)
            .field("prices", &self.prices)
            .field("thinking", &self.thinking)
            .field("message_chars", &self.message.chars().count())
            .finish()
    }
}

struct Args {
    wire: Wire,
    base_url: String,
    model: String,
    token_env: Option<String>,
    root: PathBuf,
    level: Level,
    thread: Option<ThreadId>,
    system_files: Vec<PathBuf>,
    state_dir: PathBuf,
    budget: Budget,
    prices: PriceDeck,
    thinking: Thinking,
    message: String,
}

const USAGE: &str = "\
usage: jesse-agent turn --wire <messages|chat> --base-url <url> --model <id>
                        --root <dir> --level <basic|read|write>
                        [--token-env <VAR>] [--thread <direct-…>]
                        [--system-file <path>]... [--state-dir <dir>]
                        [--thinking <off|low|medium|high>]
                        [--budget-iterations <n>] [--budget-tool-calls <n>]
                        [--budget-output-tokens <n>] [--budget-input-tokens <n>]
                        [--budget-wall-secs <n>] [--budget-cost-usd <f>]
                        [--price-in <usd/M>] [--price-cached <usd/M>] [--price-out <usd/M>]
                        \"<message>\"

  --token-env names the ENVIRONMENT VARIABLE the API key lives in. The key itself is
  never an argument, so it stays out of shell history and out of `ps`.
  Omit it for an endpoint that wants no auth (a loopback mock).

  Prices default to zero. A made-up price is worse than a stated zero, so the cost
  in the outcome line is 0.00 until you supply a deck.";

/// Hand-rolled rather than `clap`.
///
/// One subcommand and a flat list of long flags, all of them `--flag value`. `clap` is a
/// large dependency and a build-time cost for a parser this shape, and the crate has taken
/// the same position twice already (no `rand` for one float, no `futures-util` for one
/// combinator). If this grows subcommands or shorthands, that is the moment to reconsider —
/// not before.
fn parse(argv: Vec<String>) -> Result<Args, String> {
    let mut it = argv.into_iter().skip(1);
    match it.next().as_deref() {
        Some("turn") => {}
        Some("-h") | Some("--help") | None => return Err(USAGE.to_string()),
        Some(other) => return Err(format!("unknown command {other:?}\n\n{USAGE}")),
    }

    let mut wire = None;
    let mut base_url = None;
    let mut model = None;
    let mut token_env = None;
    let mut root = None;
    let mut level = None;
    let mut thread = None;
    let mut system_files = Vec::new();
    let mut state_dir = None;
    let mut thinking = Thinking::Off;
    let mut message = None;

    let mut budget = Budget::with_wall(Duration::from_secs(300));
    let mut prices = PriceDeck::ZERO;

    while let Some(arg) = it.next() {
        let mut value = || -> Result<String, String> {
            it.next()
                .ok_or_else(|| format!("{arg} needs a value\n\n{USAGE}"))
        };
        match arg.as_str() {
            "--wire" => wire = Some(parse_wire(&value()?)?),
            "--base-url" => base_url = Some(value()?),
            "--model" => model = Some(value()?),
            "--token-env" => token_env = Some(value()?),
            "--root" => root = Some(PathBuf::from(value()?)),
            "--level" => level = Some(value()?.parse::<Level>()?),
            "--thread" => thread = Some(ThreadId::parse(&value()?).map_err(|e| e.to_string())?),
            "--system-file" => system_files.push(PathBuf::from(value()?)),
            "--state-dir" => state_dir = Some(PathBuf::from(value()?)),
            "--thinking" => thinking = parse_thinking(&value()?)?,
            "--budget-iterations" => budget.max_iterations = number(&arg, &value()?)?,
            "--budget-tool-calls" => budget.max_tool_calls = number(&arg, &value()?)?,
            "--budget-output-tokens" => {
                budget.max_output_tokens_per_call = number(&arg, &value()?)?
            }
            "--budget-input-tokens" => budget.max_input_tokens_per_turn = number(&arg, &value()?)?,
            "--budget-wall-secs" => budget.max_wall = Duration::from_secs(number(&arg, &value()?)?),
            "--budget-cost-usd" => budget.max_cost_usd = Some(float(&arg, &value()?)?),
            "--price-in" => prices.in_per_m = float(&arg, &value()?)?,
            "--price-cached" => prices.cached_per_m = float(&arg, &value()?)?,
            "--price-out" => prices.out_per_m = float(&arg, &value()?)?,
            "-h" | "--help" => return Err(USAGE.to_string()),
            other if other.starts_with("--") => {
                return Err(format!("unknown flag {other:?}\n\n{USAGE}"))
            }
            // The first bare argument is the message. A second is an error rather than a
            // silent concatenation: an unquoted multi-word message is the mistake this
            // catches, and joining the words would hide it.
            other => {
                if message.is_some() {
                    return Err(format!(
                        "unexpected extra argument {other:?} — quote the message\n\n{USAGE}"
                    ));
                }
                message = Some(other.to_string());
            }
        }
    }

    Ok(Args {
        wire: wire.ok_or("--wire is required")?,
        base_url: base_url.ok_or("--base-url is required")?,
        model: model.ok_or("--model is required")?,
        token_env,
        root: root.ok_or("--root is required")?,
        level: level.ok_or("--level is required")?,
        thread,
        system_files,
        state_dir: state_dir.unwrap_or_else(|| PathBuf::from(DEFAULT_STATE_DIR)),
        budget,
        prices,
        thinking,
        message: message.ok_or("a message is required")?,
    })
}

fn parse_wire(s: &str) -> Result<Wire, String> {
    match s.to_ascii_lowercase().as_str() {
        "messages" | "anthropic" => Ok(Wire::Messages),
        "chat" | "openai" => Ok(Wire::Chat),
        "responses" => Ok(Wire::Responses),
        other => Err(format!(
            "--wire {other:?} is not one of: messages, chat, responses"
        )),
    }
}

fn parse_thinking(s: &str) -> Result<Thinking, String> {
    match s.to_ascii_lowercase().as_str() {
        "off" => Ok(Thinking::Off),
        "low" => Ok(Thinking::Low),
        "medium" => Ok(Thinking::Medium),
        "high" => Ok(Thinking::High),
        other => Err(format!(
            "--thinking {other:?} is not one of: off, low, medium, high"
        )),
    }
}

fn number<T: std::str::FromStr>(flag: &str, s: &str) -> Result<T, String> {
    s.parse()
        .map_err(|_| format!("{flag} {s:?} is not a number"))
}

fn float(flag: &str, s: &str) -> Result<f64, String> {
    s.parse()
        .map_err(|_| format!("{flag} {s:?} is not a number"))
}

// ===========================================================================
// The sink
// ===========================================================================

/// Text to stdout as it arrives; activity to stderr.
struct CliSink;

impl EventSink for CliSink {
    fn on_text_delta(&self, delta: &str) {
        use std::io::Write;
        print!("{delta}");
        // FLUSHED PER DELTA. stdout is line-buffered at best and block-buffered when piped,
        // so without this the whole point of streaming — seeing the answer arrive — is lost
        // exactly when the output is being watched.
        let _ = std::io::stdout().flush();
    }

    fn on_tool_activity(&self, activity: ToolActivity) {
        eprintln!(
            "  → tool {}{}",
            activity.name,
            if activity.refused { " (REFUSED)" } else { "" }
        );
    }
}

// ===========================================================================
// main
// ===========================================================================

/// A CURRENT-THREAD RUNTIME. The loop needs concurrency — a batch of reads awaiting
/// together — and never parallelism: every tool it dispatches is I/O bound, and the one
/// place work overlaps is inside `join_all`, which polls its futures on whatever thread it
/// is on. Asking for `rt-multi-thread` would add a feature to the LIBRARY's tokio
/// dependency (a binary cannot carry its own) that every consumer of the library would
/// then compile, to buy a worker pool that has nothing to do.
#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let args = match parse(std::env::args().collect()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(1);
        }
    };
    match run(args).await {
        Ok(code) => code,
        Err(e) => {
            eprintln!("jesse-agent: {e}");
            ExitCode::from(1)
        }
    }
}

async fn run(args: Args) -> Result<ExitCode, String> {
    // ---- The provider ----------------------------------------------------
    //
    // The CALLER resolves the environment; the library never does (see `provider::config`).
    let auth = match &args.token_env {
        Some(name) => {
            let token = std::env::var(name)
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| format!("--token-env names {name}, which is unset or empty"))?;
            AuthScheme::default_for(&args.base_url, token)
        }
        None => AuthScheme::None,
    };
    let cfg = ProviderConfig::new(args.wire, &args.base_url, &args.model, auth);
    let provider = build_provider(cfg).map_err(|e| e.to_string())?;

    // ---- The tools -------------------------------------------------------
    let tools = fixture_tool_set(&args.root, args.level)?;
    eprintln!(
        "level={} exposed=[{}] withheld=[{}]",
        args.level,
        tools
            .manifest()
            .iter()
            .map(|t| t.name.as_str())
            .collect::<Vec<_>>()
            .join(", "),
        tools.withheld().join(", ")
    );

    // ---- The system prefix -----------------------------------------------
    let mut system = Vec::new();
    for path in &args.system_files {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("--system-file {}: {e}", path.display()))?;
        system.push(SystemBlock::plain(text));
    }

    // ---- State -----------------------------------------------------------
    let threads = FileThreadStore::open(args.state_dir.join("threads"))
        .map_err(|e| format!("thread store: {e}"))?;
    let usage = JsonlUsageSink::open(args.state_dir.join("usage.jsonl"))
        .map_err(|e| format!("usage ledger: {e}"))?;

    // ---- Cancellation ----------------------------------------------------
    //
    // Ctrl-C cancels the TURN rather than killing the process, so the partial answer, the
    // thread append and the usage records all still happen. A process killed at the signal
    // would lose the record of what it had already bought.
    let cancel = CancellationToken::new();
    let on_signal = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            eprintln!("\njesse-agent: cancelling the turn (the partial answer is kept)");
            on_signal.cancel();
        }
    });

    let turn_id = format!("cli-{}", std::process::id());
    let input = TurnInput {
        scope: cli_scope(),
        turn_id,
        thread_id: args.thread,
        system,
        user_text: args.message,
        user_images: Vec::new(),
        budget: args.budget,
        prices: args.prices,
        thinking: args.thinking,
        tools: Arc::new(tools),
    };
    let deps = TurnDeps {
        provider: provider.as_ref(),
        threads: &threads,
        usage: &usage,
        clock: Arc::new(SystemClock::new()),
    };

    eprintln!("--- turn ---");
    let outcome = run_turn(input, &deps, &CliSink, cancel).await;
    // The answer's deltas went to stdout unterminated; end the line before the JSON.
    println!();

    // ---- The trace, to stderr --------------------------------------------
    eprintln!("--- trace (content-free) ---");
    for t in &outcome.trace.tools {
        eprintln!(
            "  {:<16} {:<14} {:>6}ms  {}",
            t.name, t.class, t.ms, t.outcome
        );
    }
    eprintln!(
        "  {} iteration(s), {} tool call(s), {} refusal(s)",
        outcome.trace.iterations,
        outcome.trace.tools.len(),
        outcome.trace.refusals()
    );
    if let StopReason::Provider(e) = &outcome.stop_reason {
        eprintln!("  provider error: {e}");
    }
    if let StopReason::Store(m) = &outcome.stop_reason {
        eprintln!("  thread store: {m}");
    }

    // ---- The outcome, one JSON line to stdout ----------------------------
    let line = serde_json::json!({
        "stop_reason": outcome.stop_reason.label(),
        "thread_id": outcome.thread_id.as_str(),
        "iterations": outcome.iterations,
        "tool_calls": outcome.tool_calls,
        "refusals": outcome.trace.refusals(),
        "usage": outcome.usage,
        "cost_usd": outcome.cost_usd,
        "text_chars": outcome.text.chars().count(),
        "state_dir": args.state_dir.display().to_string(),
    });
    println!("{line}");

    Ok(exit_code(&outcome.stop_reason))
}

/// The outcome as an exit code.
///
/// `MaxTokens` and `StopSequence` are SUCCESS. The model produced a real answer and stopped
/// for a reason the caller configured; failing the process would make a working
/// `--budget-output-tokens` look like a broken turn.
fn exit_code(stop: &StopReason) -> ExitCode {
    match stop {
        StopReason::EndTurn | StopReason::MaxTokens | StopReason::StopSequence => ExitCode::from(0),
        StopReason::Budget(_) => ExitCode::from(2),
        StopReason::Cancelled => ExitCode::from(3),
        StopReason::Provider(_) | StopReason::Store(_) | StopReason::Other(_) => ExitCode::from(1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> Vec<String> {
        std::iter::once("jesse-agent".to_string())
            .chain(args.iter().map(|s| s.to_string()))
            .collect()
    }

    fn minimal() -> Vec<&'static str> {
        vec![
            "turn",
            "--wire",
            "chat",
            "--base-url",
            "http://127.0.0.1:1",
            "--model",
            "m",
            "--root",
            ".",
            "--level",
            "read",
            "hello",
        ]
    }

    #[test]
    fn the_minimal_invocation_parses() {
        let a = parse(argv(&minimal())).unwrap();
        assert_eq!(a.wire, Wire::Chat);
        assert_eq!(a.model, "m");
        assert_eq!(a.level, Level::Read);
        assert_eq!(a.message, "hello");
        assert!(a.token_env.is_none(), "auth is optional for a mock");
        assert_eq!(a.prices, PriceDeck::ZERO, "no made-up prices");
        assert_eq!(a.state_dir, PathBuf::from(".jesse-agent"));
    }

    #[test]
    fn every_budget_flag_reaches_the_budget() {
        let mut args = minimal();
        args.splice(
            1..1,
            [
                "--budget-iterations",
                "7",
                "--budget-tool-calls",
                "8",
                "--budget-output-tokens",
                "9",
                "--budget-input-tokens",
                "10",
                "--budget-wall-secs",
                "11",
                "--budget-cost-usd",
                "0.25",
            ],
        );
        let a = parse(argv(&args)).unwrap();
        assert_eq!(a.budget.max_iterations, 7);
        assert_eq!(a.budget.max_tool_calls, 8);
        assert_eq!(a.budget.max_output_tokens_per_call, 9);
        assert_eq!(a.budget.max_input_tokens_per_turn, 10);
        assert_eq!(a.budget.max_wall, Duration::from_secs(11));
        assert_eq!(a.budget.max_cost_usd, Some(0.25));
    }

    #[test]
    fn system_files_accumulate_in_order() {
        let mut args = minimal();
        args.splice(1..1, ["--system-file", "a.md", "--system-file", "b.md"]);
        let a = parse(argv(&args)).unwrap();
        assert_eq!(
            a.system_files,
            [PathBuf::from("a.md"), PathBuf::from("b.md")]
        );
    }

    #[test]
    fn a_bad_thread_id_is_refused_before_anything_touches_the_disk() {
        // The store never sees an id it would use as a filename — `ThreadId::parse` is the
        // only way one is constructed, and it runs here.
        let mut args = minimal();
        args.splice(1..1, ["--thread", "../../etc/passwd"]);
        assert!(parse(argv(&args)).is_err());
        let mut ok = minimal();
        let id = ThreadId::generate();
        ok.splice(1..1, ["--thread", id.as_str()]);
        assert_eq!(parse(argv(&ok)).unwrap().thread, Some(id));
    }

    #[test]
    fn an_unquoted_multi_word_message_is_an_error_not_a_silent_join() {
        let mut args = minimal();
        args.push("world");
        let e = parse(argv(&args)).unwrap_err();
        assert!(e.contains("quote the message"), "{e}");
    }

    #[test]
    fn a_missing_required_flag_says_which_one() {
        let without_level: Vec<&str> = minimal()
            .into_iter()
            .filter(|a| *a != "--level" && *a != "read")
            .collect();
        assert!(parse(argv(&without_level))
            .unwrap_err()
            .contains("--level is required"));
    }

    #[test]
    fn the_exit_codes_are_the_documented_ones() {
        let code = |s: StopReason| -> u8 {
            // `ExitCode` has no accessor, so this asserts on the mapping through its
            // Debug — the only thing the type exposes. Crude, and it does check the value.
            format!("{:?}", exit_code(&s))
                .trim_start_matches("ExitCode(unix_exit_status(")
                .trim_end_matches("))")
                .parse()
                .unwrap()
        };
        assert_eq!(code(StopReason::EndTurn), 0);
        assert_eq!(code(StopReason::MaxTokens), 0);
        assert_eq!(code(StopReason::Budget(jesse_agent::Ceiling::Wall)), 2);
        assert_eq!(code(StopReason::Cancelled), 3);
        assert_eq!(code(StopReason::Store("x".into())), 1);
    }
}
