//! `jesse-rules` — generate, check and roll back the shared instruction bundle.
//!
//! The maintenance CLI over `jesse_bridge::rules`. It carries no policy of its own: every
//! path, section, budget and enforceable parameter comes from the manifest at the source
//! root, and this binary only reads it, renders from it, and refuses when something is wrong.
//!
//! ```text
//!   jesse-rules check     [--root DIR]                       what is wrong, all of it
//!   jesse-rules generate  [--root DIR] [--dry-run] [--adopt] [--force] [--socket S]
//!   jesse-rules show      [--root DIR] [--harness ID]        the document that would be written
//!   jesse-rules preflight [--root DIR] --harness ID          exactly what a turn would verify
//!   jesse-rules rollback  [--root DIR] [--socket S]          restore the previous generation
//! ```
//!
//! `--root` defaults to `$JESSE_RULES_ROOT`; `--socket` defaults to
//! `$JESSE_STATE_DIR/writelock.sock` when that directory is set. A missing socket is not an
//! error: it means the bridge is not running, so there is no turn to serialise against.
//!
//! # Exit codes
//!
//! `0` clean, `1` the root has problems (or a publication was refused), `2` the command line
//! or the environment was wrong. Distinct because CI reads them: a `1` means go fix the
//! vault, a `2` means go fix the invocation.

use std::path::{Path, PathBuf};

use jesse_bridge::rules::{
    check, preflight, publish, render_for, rollback, Bundle, PublishOptions, RuleError,
};

const USAGE: &str = "\
jesse-rules — the shared instruction bundle

  jesse-rules check     [--root DIR]
  jesse-rules generate  [--root DIR] [--dry-run] [--adopt] [--force] [--socket PATH]
  jesse-rules show      [--root DIR] [--harness ID]
  jesse-rules preflight [--root DIR] --harness ID
  jesse-rules rollback  [--root DIR] [--socket PATH]

  --root      the rules source root (default: $JESSE_RULES_ROOT)
  --socket    the bridge write-lock broker socket
              (default: $JESSE_STATE_DIR/writelock.sock, when set)
  --dry-run   render and compare, write nothing
  --adopt     replace an entry document that was never generated (the migration switch)
  --force     replace an entry document that was changed by hand since it was generated

Exit: 0 clean, 1 problems found or publication refused, 2 bad invocation.";

struct Args {
    command: String,
    root: Option<PathBuf>,
    harness: Option<String>,
    socket: Option<PathBuf>,
    dry_run: bool,
    adopt: bool,
    force: bool,
}

fn parse() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let command = it.next().ok_or_else(|| "no command".to_string())?;
    let mut a = Args {
        command,
        root: std::env::var("JESSE_RULES_ROOT").ok().map(PathBuf::from),
        harness: None,
        socket: std::env::var("JESSE_STATE_DIR")
            .ok()
            .map(|d| PathBuf::from(d).join("writelock.sock")),
        dry_run: false,
        adopt: false,
        force: false,
    };
    while let Some(flag) = it.next() {
        let mut val = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--root" => a.root = Some(PathBuf::from(val()?)),
            "--harness" => a.harness = Some(val()?),
            "--socket" => a.socket = Some(PathBuf::from(val()?)),
            "--dry-run" => a.dry_run = true,
            "--adopt" => a.adopt = true,
            "--force" => a.force = true,
            "-h" | "--help" => return Err("help".to_string()),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(a)
}

fn main() {
    let args = match parse() {
        Ok(a) => a,
        Err(e) => {
            if e != "help" {
                eprintln!("jesse-rules: {e}\n");
            }
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    };
    let Some(root) = args.root.clone() else {
        eprintln!("jesse-rules: no --root and no JESSE_RULES_ROOT\n\n{USAGE}");
        std::process::exit(2);
    };
    if !root.is_dir() {
        eprintln!("jesse-rules: {} is not a directory", root.display());
        std::process::exit(2);
    }

    let code = match args.command.as_str() {
        "check" => cmd_check(&root),
        "generate" => cmd_generate(&root, &args),
        "show" => cmd_show(&root, args.harness.as_deref()),
        "preflight" => match args.harness.as_deref() {
            Some(h) => cmd_preflight(&root, h),
            None => {
                eprintln!("jesse-rules preflight: --harness is required");
                2
            }
        },
        "rollback" => cmd_rollback(&root, socket(&args)),
        other => {
            eprintln!("jesse-rules: unknown command {other}\n\n{USAGE}");
            2
        }
    };
    std::process::exit(code);
}

/// A socket only when it actually exists: an absent one means no bridge, not a failure.
fn socket(args: &Args) -> Option<&Path> {
    args.socket.as_deref().filter(|p| p.exists())
}

fn cmd_check(root: &Path) -> i32 {
    let r = check(root);
    if let Some(d) = &r.digest {
        println!("digest  {d}");
    }
    for (h, bytes, max) in &r.sizes {
        let pct = if *max > 0 { bytes * 100 / max } else { 0 };
        println!("size    {h}: {bytes} bytes of {max} ({pct}%)");
    }
    if r.problems.is_empty() {
        println!("ok      {} verifies clean", r.root.display());
        return 0;
    }
    for p in &r.problems {
        println!("PROBLEM {p}");
    }
    println!("{} problem(s)", r.problems.len());
    1
}

fn cmd_generate(root: &Path, args: &Args) -> i32 {
    let opts = PublishOptions {
        dry_run: args.dry_run,
        force: args.force,
        adopt: args.adopt,
        lock_socket: socket(args).map(|p| p.to_path_buf()),
    };
    match publish(root, &opts) {
        Ok(r) => {
            println!("digest  {}", r.digest);
            println!("core    {}", r.core_digest);
            for (h, bytes, max) in &r.sizes {
                println!("size    {h}: {bytes} bytes of {max}");
            }
            for w in &r.written {
                println!("{} {w}", if r.dry_run { "would-write" } else { "wrote " });
            }
            for u in &r.unchanged {
                println!("unchanged  {u}");
            }
            if let Some(p) = &r.previous {
                println!("previous   {}", p.display());
            }
            if r.written.is_empty() && !r.dry_run {
                println!("ok      already up to date");
            }
            0
        }
        Err(e) => {
            eprintln!("jesse-rules generate: {e}");
            if matches!(e, RuleError::ManuallyChanged { .. }) {
                eprintln!(
                    "\nCompare the two before deciding. `jesse-rules show --harness <id>` \
                     prints what would replace it."
                );
            }
            1
        }
    }
}

fn cmd_show(root: &Path, harness: Option<&str>) -> i32 {
    let canon = match jesse_bridge::rules::canonical_root(root) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("jesse-rules show: {e}");
            return 2;
        }
    };
    let bundle: Bundle = match jesse_bridge::rules::build_bundle(&canon) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("jesse-rules show: {e}");
            return 1;
        }
    };
    let ids: Vec<String> = bundle.manifest.outputs.keys().cloned().collect();
    let wanted = match harness {
        Some(h) => vec![h.to_string()],
        None => ids.clone(),
    };
    for h in wanted {
        match render_for(&bundle, &h) {
            Ok(text) => {
                if harness.is_none() {
                    println!("===== {h} =====");
                }
                print!("{text}");
            }
            Err(e) => {
                eprintln!("jesse-rules show: {e}");
                return 1;
            }
        }
    }
    0
}

fn cmd_preflight(root: &Path, harness: &str) -> i32 {
    match preflight(root, harness) {
        Ok(p) => {
            println!("{}", p.log_line());
            println!("document   {} (harness {})", p.document, p.document_harness);
            println!("core rules {}", p.core_rules.join(", "));
            println!("task rules {}", p.task_rules.join(", "));
            for e in &p.enforce {
                println!("enforced   {}", e.canonical());
            }
            0
        }
        Err(e) => {
            eprintln!("jesse-rules preflight: {e}");
            1
        }
    }
}

fn cmd_rollback(root: &Path, socket: Option<&Path>) -> i32 {
    match rollback(root, socket) {
        Ok(files) => {
            for f in files {
                println!("restored {f}");
            }
            0
        }
        Err(e) => {
            eprintln!("jesse-rules rollback: {e}");
            1
        }
    }
}
