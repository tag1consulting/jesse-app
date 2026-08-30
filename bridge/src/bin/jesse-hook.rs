//! `jesse-hook` — the vault write lock's hook helper.
//!
//! Spawned by an agent CLI as a `PreToolUse` / `PostToolUse` hook, once per tool call. Reads
//! the hook payload on stdin, asks the bridge's broker whether the write may proceed, and
//! answers in that CLI's own vocabulary.
//!
//! A SECOND BIN IN THE SAME CRATE, not a new dependency and not a shell script. It has to
//! parse two different harnesses' payload shapes and speak the broker's wire protocol, and
//! both of those are already library code — `Harness::hook_write_target` is the single
//! definition of "what does this payload write", shared with the bridge itself. A shell
//! script would have had to reimplement it twice, in the language least able to do it.
//!
//! # Refusing, in two dialects
//!
//! The two CLIs express a blocked tool call differently, and both were verified live:
//!
//!   * **Claude Code 2.1.222** — exit code 2 with the reason on STDERR. The write never
//!     lands, the model reads the reason and reacts, and the denial is recorded in the
//!     result envelope's `permission_denials`.
//!   * **codex-cli 0.146.0** — a `hookSpecificOutput` JSON object on STDOUT carrying
//!     `permissionDecision: "deny"`.
//!
//! # It fails CLOSED
//!
//! Every error path — an unreachable broker, an unparseable payload, a malformed reply —
//! DENIES. The alternative is a bridge that believes it is locking and is not, which on Codex
//! is a live hazard rather than a hypothetical: an untrusted hooks file is skipped silently.
//! A refused write is a recoverable annoyance; an unlocked concurrent write is a corrupted
//! vault.

use std::io::Read;

use jesse_bridge::{
    ask_broker_blocking, registry_harness, HarnessRegistry, HookPayload, HookRequest, Runner,
    WriteTarget, CLAUDE_CODE_ID, CODEX_ID,
};

struct Args {
    harness: String,
    event: String,
    socket: String,
    turn: String,
    conversation: String,
}

fn parse_args() -> Option<Args> {
    let mut harness = None;
    let mut event = None;
    let mut socket = None;
    let mut turn = None;
    let mut conversation = None;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut take = || it.next();
        match flag.as_str() {
            "--harness" => harness = take(),
            "--event" => event = take(),
            "--socket" => socket = take(),
            "--turn" => turn = take(),
            "--conversation" => conversation = take(),
            _ => return None,
        }
    }
    Some(Args {
        harness: harness?,
        event: event?,
        socket: socket?,
        turn: turn?,
        conversation: conversation?,
    })
}

/// Refuse this tool call, in the dialect the calling harness understands.
fn deny(harness: &str, reason: &str) -> ! {
    match harness {
        CODEX_ID => {
            // Codex reads a decision object off stdout.
            println!(
                "{}",
                serde_json::json!({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": reason,
                    }
                })
            );
            std::process::exit(0);
        }
        // Claude Code (and any harness that has not said otherwise): exit 2, reason on stderr.
        _ => {
            eprintln!("{reason}");
            std::process::exit(2);
        }
    }
}

/// Allow, saying nothing. Both CLIs treat a silent exit 0 as "proceed".
fn allow() -> ! {
    std::process::exit(0)
}

fn main() {
    let Some(args) = parse_args() else {
        // No harness known yet, so answer in the dialect that is safe for both: a non-zero
        // exit blocks on Claude Code, and Codex treats a hook error as a failure to allow.
        eprintln!("jesse-hook: bad arguments; refusing the tool call rather than allowing it");
        std::process::exit(2);
    };

    let mut raw = String::new();
    if std::io::stdin().read_to_string(&mut raw).is_err() {
        deny(&args.harness, "jesse-hook could not read the hook payload");
    }
    let payload: HookPayload = match serde_json::from_str(&raw) {
        Ok(p) => p,
        Err(e) => deny(
            &args.harness,
            &format!("jesse-hook could not parse the hook payload: {e}"),
        ),
    };

    // The harness is what knows how to read its own payload. `registry_harness` resolves the
    // id the bridge baked into this command line; an id this build cannot construct is a
    // wiring fault, and the safe answer to a wiring fault is to deny.
    let registry = HarnessRegistry::for_models([CLAUDE_CODE_ID, CODEX_ID]);
    let Some(harness) = registry_harness(&registry, &args.harness) else {
        deny(
            &args.harness,
            &format!("jesse-hook does not know the harness '{}'", args.harness),
        );
    };
    // A HOOK IS A CHILD PROCESS PHENOMENON. This binary exists because a spawned child calls
    // out to it; the payloads it parses are that child's, and the two methods that read them
    // live on `SpawnedHarness` for exactly that reason. An in-process harness has no hooks
    // and never invokes this binary — so reaching here under one is a wiring fault, and the
    // safe answer to a wiring fault is the same one every other unrecognised input gets:
    // deny, rather than allow an unlocked write on a guess.
    let Runner::Spawned(harness) = harness.runner() else {
        deny(
            &args.harness,
            &format!(
                "jesse-hook was invoked for harness '{}', which answers turns in process and \
                 installs no hooks; refusing the tool call rather than allowing it unlocked",
                args.harness
            ),
        );
    };

    let socket = std::path::PathBuf::from(&args.socket);

    let req = match args.event.as_str() {
        "pre" => {
            let target = match harness.hook_write_target(&payload) {
                // Not a write: no lock, no round trip to the broker at all. This is the arm
                // that keeps reads, searches and thinking entirely free of contention.
                WriteTarget::None => allow(),
                WriteTarget::Path(p) => Some(Some(p.display().to_string())),
                WriteTarget::Global => Some(None),
            };
            HookRequest::Pre {
                turn: args.turn.clone(),
                conversation: args.conversation.clone(),
                tool_use_id: payload.tool_use_id.clone(),
                target,
                // A write can trigger a vault hook that runs git, so a write-lock holder takes
                // the git lock too. Taken INSIDE the file lock, matching the bridge's one
                // total order.
                git: true,
            }
        }
        "post" => HookRequest::Post {
            turn: args.turn.clone(),
            conversation: args.conversation.clone(),
            tool_use_id: payload.tool_use_id.clone(),
            // What this call leaves the conversation looking at: the file it READ, or — and
            // this is the 0.82.0 fix — the file it just successfully WROTE.
            //
            // Both harnesses are fixed by this one expression, because both already implement
            // `hook_write_target` for the lock itself; nothing new has to learn either payload
            // shape. A `WriteTarget::Global` (a shell command, an unrecognised tool) names no
            // file, so it records nothing rather than guessing — the same conservative default
            // `hook_read_target` documents.
            baseline: harness
                .hook_read_target(&payload)
                .or_else(|| match harness.hook_write_target(&payload) {
                    WriteTarget::Path(p) => Some(p),
                    WriteTarget::Global | WriteTarget::None => None,
                })
                .map(|p| p.display().to_string()),
        },
        other => deny(
            &args.harness,
            &format!("jesse-hook: unknown event '{other}'"),
        ),
    };

    let resp = ask_broker_blocking(&socket, &req);

    // A POST never blocks a tool call: the tool has already run, and refusing after the fact
    // would only confuse the model about what happened.
    if matches!(req, HookRequest::Post { .. }) {
        allow();
    }
    if resp.allow {
        allow();
    }
    deny(
        &args.harness,
        &resp
            .reason
            .unwrap_or_else(|| "the vault write lock refused this write".to_string()),
    );
}
