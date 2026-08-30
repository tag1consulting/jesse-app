//! **THE ARGV FIXTURE: PROOF THAT THE TRAIT SPLIT MOVED NOTHING.**
//!
//! `bridge/tests/fixtures/argv-before-split.json` was generated on `main`, BEFORE the
//! `Harness`/`SpawnedHarness`/`InProcessHarness` split, and committed unchanged. This test
//! rebuilds the same children through the same builders on the post-split code and asserts
//! byte equality against it.
//!
//! **Why a committed fixture rather than an in-repo comparison.** The golden argv tests in
//! `harness/claude_code.rs` already pin what the CLI is handed, and they are excellent —
//! but they live in the same commit as the change, so a refactor that moved a flag and
//! updated the golden in the same breath would pass them. A fixture generated on the parent
//! commit cannot be rationalised: it is what the shipped bridge actually spawned, and the
//! only way to make this test green is to not have changed anything.
//!
//! **What is captured, and what is deliberately not.** The full argv, the working
//! directory, and the NAMES of the environment variables each child carries — never their
//! VALUES. A Codex provider turn carries its API key in the environment (that is the whole
//! point of `CODEX_PROVIDER_KEY_ENV`: the argv names the variable, the value never reaches
//! a process listing), and a fixture that recorded env values would write a secret into the
//! repository the first time somebody regenerated it on a configured host. The ambient
//! children here carry no secret at all, which is exactly why the rule has to be in the
//! capture function rather than in a reviewer's head.
//!
//! **Two kinds of argument, and why one of them is hashed.** Most arguments are stored
//! verbatim, because a fixture a reviewer cannot read is a fixture nobody reviews. An
//! argument that is LONG or carries a URL is stored as its SHA-256 instead, and that is not
//! squeamishness: both harnesses' main-turn argv embeds the MCP server set, which names the
//! Home Assistant endpoint by address. `scripts/ci-guards.sh` refuses personal
//! infrastructure in tracked files and exempts exactly ONE line in the whole tree for that
//! address — the source const it genuinely has to live in — so a fixture repeating it six
//! more times would either fail the guard or force the exemption wider, and a JSON file
//! cannot carry the per-line marker in any case.
//!
//! **Hashing costs nothing this test needs.** A digest is exact: one byte moves anywhere in
//! that argument and the hex changes, which is the entire claim being made. What it costs is
//! the shape of a failure message, and the reader gets that back from the arguments around
//! it — the flag that introduces a hashed value is right beside it, verbatim.
//!
//! **The config is fixed, not `test_config()`'s.** `test_config()` points the vault at
//! `std::env::temp_dir()`, which is `/var/folders/…` on macOS and `/tmp` on Linux, and the
//! vault path appears verbatim in both harnesses' argv (Claude Code's `Read(./**)` scope,
//! Codex's `-C` and its `writable_roots`). A fixture built on that would be a fixture that
//! only ever passes on the machine that wrote it.
//!
//! To regenerate — which should only ever happen alongside a DELIBERATE argv change, in the
//! same commit as its changelog entry: `JESSE_ARGV_FIXTURE_WRITE=1 cargo test --test
//! argv_split_fixture`.
mod common;

use jesse_bridge::*;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

/// A FIXED turn id. `TurnRequest` gained one when the direct harness landed; it reaches no
/// argv, no env var and no file on either spawned harness, which is exactly what this fixture
/// proves by still matching the pre-split capture byte for byte.
const TURN_ID: &str = "fixture-turn";

/// The fixture path, relative to the crate root.
fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/argv-before-split.json")
}

/// A config whose every argv-visible value is FIXED, so the capture is identical on every
/// machine. `state_dir` is a real temp directory because Codex's builder creates a per-turn
/// `CODEX_HOME` under it — that path is an env VALUE, so it is never captured.
fn fixture_config() -> Config {
    let mut cfg = common::test_config();
    cfg.home = "/home/tester".to_string();
    cfg.vault = "/vault".to_string();
    cfg.scratch_dir = Some("/scratch".to_string());
    let state = std::env::temp_dir().join(format!("jesse-argv-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&state).expect("state dir");
    cfg.state_dir = Some(state.to_string_lossy().into_owned());
    // BOTH harnesses, so the fixture covers both. `for_models` is the same door the real
    // registry goes through, so this exercises the constructors that actually ship.
    cfg.harnesses = std::sync::Arc::new(HarnessRegistry::for_models(
        KNOWN_HARNESS_IDS.iter().copied(),
    ));
    cfg
}

/// One argument as the fixture stores it: verbatim, or its SHA-256 when it is long or
/// carries a URL. See the module comment for why the second case exists.
///
/// The rule is deliberately about the ARGUMENT's shape rather than about its content: a
/// content test ("does this look like an address") would have to be kept in step with the
/// guard's denylist, and would go quietly stale the day a new server is added to the set.
/// Long-or-URL catches the MCP config blob and every `-c mcp_servers.*.url=` override
/// without knowing anything about what is inside them.
fn arg_repr(a: &str) -> String {
    if a.len() > 120 || a.contains("://") {
        format!("sha256:{}", sha256_hex(a.as_bytes()))
    } else {
        a.to_string()
    }
}

/// Argv, cwd, and env KEYS — never env values. See the module comment.
fn capture(cmd: &Command) -> Value {
    let argv: Vec<String> = cmd
        .as_std()
        .get_args()
        .map(|s| arg_repr(&s.to_string_lossy()))
        .collect();
    let mut env_keys: Vec<String> = cmd
        .as_std()
        .get_envs()
        .map(|(k, _)| k.to_string_lossy().into_owned())
        .collect();
    env_keys.sort();
    let cwd = cmd
        .as_std()
        .get_current_dir()
        .map(|p| p.display().to_string());
    json!({ "argv": argv, "env_keys": env_keys, "cwd": cwd })
}

/// Every `TurnRequest` builder, for every registered harness.
///
/// The three routed-job builders live in `harness/mod.rs` (their contract is the JOB's, not
/// any harness's); `main_turn_request` lives with the Claude Code harness but is the request
/// every main turn is built from, and it is covered at both capabilities and both resume
/// shapes because `--resume` / `exec resume` is the one place a Codex argv has already
/// broken once.
fn rows() -> Value {
    let cfg = fixture_config();
    let ambient = ActiveModel::ambient();
    let mut out = serde_json::Map::new();
    for id in KNOWN_HARNESS_IDS {
        let harness = cfg.harnesses.get(id).expect("registered");
        // THE ONE MECHANICAL DIFFERENCE ACROSS THE SPLIT, and the reason this file's
        // generator half was rewritten while the fixture was not: building a child is now
        // reached through `runner()`. Everything below it is untouched.
        //
        // AN IN-PROCESS HARNESS IS SKIPPED, and the fixture is still exactly as strong. What
        // it pins is that the two harnesses which existed before the split still build
        // byte-identical children; a harness added afterwards that spawns nothing has no argv
        // to have changed and could not appear in a capture taken before it existed. Skipping
        // is checked rather than assumed — a spawned harness added later WOULD have to be
        // captured, and would fail the key comparison below until it was.
        let Runner::Spawned(spawned) = harness.runner() else {
            continue;
        };
        let mcp = main_mcp_config(&cfg, spawned);
        let cases: Vec<(&str, TurnRequest<'_>)> = vec![
            (
                "title",
                title_child_request(&cfg, "PROMPT", &ambient, TURN_ID),
            ),
            (
                "diet",
                diet_child_request(&cfg, "PROMPT", &ambient, TURN_ID),
            ),
            (
                "vaultqa",
                vaultqa_child_request(&cfg, "PROMPT", &ambient, TURN_ID),
            ),
            (
                "main-write",
                main_turn_request(
                    &cfg,
                    "PROMPT",
                    None,
                    &ambient,
                    Capability::Write,
                    mcp,
                    TURN_ID,
                ),
            ),
            (
                "main-write-resume",
                main_turn_request(
                    &cfg,
                    "PROMPT",
                    Some("sess-1"),
                    &ambient,
                    Capability::Write,
                    mcp,
                    TURN_ID,
                ),
            ),
            (
                "main-read",
                main_turn_request(
                    &cfg,
                    "PROMPT",
                    None,
                    &ambient,
                    Capability::Read,
                    mcp,
                    TURN_ID,
                ),
            ),
        ];
        let mut per = serde_json::Map::new();
        for (label, req) in cases {
            let cmd = spawned.build_turn(&cfg, &req).expect("a child");
            per.insert(label.to_string(), capture(&cmd));
        }
        out.insert((*id).to_string(), Value::Object(per));
    }
    Value::Object(out)
}

#[test]
fn every_turn_request_builds_the_same_child_it_did_before_the_trait_split() {
    let now = rows();
    if std::env::var("JESSE_ARGV_FIXTURE_WRITE").is_ok() {
        let text = serde_json::to_string_pretty(&now).unwrap() + "\n";
        std::fs::write(fixture_path(), text).expect("write the fixture");
        return;
    }
    let before: Value = serde_json::from_str(
        &std::fs::read_to_string(fixture_path()).expect("the committed pre-split fixture"),
    )
    .expect("the fixture is JSON");

    // Compared per row rather than as one blob, so a failure names the harness and the call
    // site that moved instead of dumping two 600-line documents at the reader.
    let before_map = before.as_object().expect("an object");
    let now_map = now.as_object().expect("an object");
    assert_eq!(
        before_map.keys().collect::<Vec<_>>(),
        now_map.keys().collect::<Vec<_>>(),
        "the set of harnesses changed"
    );
    for (harness, rows) in before_map {
        let rows = rows.as_object().expect("an object");
        let mine = now_map[harness].as_object().expect("an object");
        assert_eq!(
            rows.keys().collect::<Vec<_>>(),
            mine.keys().collect::<Vec<_>>(),
            "{harness}: the set of call sites changed"
        );
        for (site, expected) in rows {
            assert_eq!(
                &mine[site], expected,
                "{harness}/{site}: this child is not the one the pre-split bridge spawned"
            );
        }
    }
}
