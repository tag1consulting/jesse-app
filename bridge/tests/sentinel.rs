//! The sentinel, end to end over loopback.
//!
//! Two stand-ins do all the work here, and both are deliberate:
//!
//!   * A FAKE BRIDGE — a real axum server on 127.0.0.1 that answers `/health` and
//!     `/jesse/schedule` and gates them with the bridge's OWN [`check_auth`]. That is what
//!     makes the token-disjointness test worth something: the sentinel's token is refused by
//!     the same function every real bridge route calls, not by a mock that agrees with the
//!     test.
//!
//!   * A FAKE `launchctl` — a shell script that appends its argv to a file and exits. The
//!     verbs and the watchdog are only reachable through `launchctl`, and the one thing worth
//!     asserting about them is exactly which service targets they addressed and how many
//!     times. A recording shim answers that; a mocked-out Rust seam would only assert that
//!     the code called the seam.
//!
//! Nothing here touches a real launchd domain, a real tailnet, or the real vault.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use jesse_bridge::check_auth;
use jesse_bridge::sentinel::{
    sentinel_app, tick, Bins, Sentinel, SentinelConfig, ServiceSlot, DEFAULT_SENTINEL_PORT,
    MAX_KICKSTARTS_PER_HOUR, SERVICE_SLOTS,
};
use serde_json::{json, Value};

const BRIDGE_TOKEN: &str = "bridge-token-aaaaaaaaaaaaaaaa";
const SENTINEL_TOKEN: &str = "sentinel-token-bbbbbbbbbbbbbb";

// ---- Scratch ------------------------------------------------------------------------

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!(
            "jesse-sentinel-it-{name}-{}",
            jesse_bridge::random_hex()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }
    fn path(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Write an executable `/bin/sh` script that records its argv (one line per invocation) into
/// `record`, then exits with `code`. `sleep_secs` makes it hang, for the timeout test.
///
/// Plain POSIX shell: CI's `/bin/sh` is dash, so nothing bash-only appears here.
fn shim(path: &Path, record: &Path, code: i32, sleep_secs: u32) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let body = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n{}exit {code}\n",
        record.display(),
        if sleep_secs > 0 {
            format!("sleep {sleep_secs}\n")
        } else {
            String::new()
        }
    );
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_path_buf()
}

fn recorded(record: &Path) -> Vec<String> {
    std::fs::read_to_string(record)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect()
}

// ---- The fake bridge ------------------------------------------------------------------

#[derive(Clone)]
struct FakeBridge {
    schedule: Value,
    fired: Arc<std::sync::Mutex<Vec<String>>>,
}

async fn fake_health(
    State(_): State<FakeBridge>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, String)> {
    // THE REAL FUNCTION. Every bridge route calls exactly this, so a token refused here is a
    // token refused by the bridge.
    check_auth(&headers, BRIDGE_TOKEN)?;
    Ok(Json(json!({ "ok": true, "version": "0.93.0-fake" })))
}

async fn fake_schedule(
    State(fb): State<FakeBridge>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, String)> {
    check_auth(&headers, BRIDGE_TOKEN)?;
    Ok(Json(fb.schedule.clone()))
}

async fn fake_fire(
    State(fb): State<FakeBridge>,
    axum::extract::Path(id): axum::extract::Path<String>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, String)> {
    check_auth(&headers, BRIDGE_TOKEN)?;
    fb.fired.lock().unwrap().push(id.clone());
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({ "chain": [id], "started_ms": 1 })),
    ))
}

/// Start the fake bridge on an ephemeral loopback port. Returns its base URL and the shared
/// record of what it was asked to fire.
async fn start_fake_bridge(schedule: Value) -> (String, Arc<std::sync::Mutex<Vec<String>>>) {
    let fired = Arc::new(std::sync::Mutex::new(Vec::new()));
    let state = FakeBridge {
        schedule,
        fired: fired.clone(),
    };
    let app = Router::new()
        .route("/health", get(fake_health))
        .route("/jesse/schedule", get(fake_schedule))
        .route("/jesse/schedule/:id/fire", post(fake_fire))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (format!("http://{addr}"), fired)
}

// ---- Config -----------------------------------------------------------------------------

/// A sentinel wired entirely to the scratch directory. Every external binary is `None` unless
/// a test hands it a shim, so no test can accidentally reach the real host.
fn config(sc: &Scratch, bridge_url: &str) -> SentinelConfig {
    let mut labels = std::collections::HashMap::new();
    for slot in SERVICE_SLOTS {
        labels.insert(slot, format!("com.example.test-{}", slot.slug()));
    }
    SentinelConfig {
        bind: "127.0.0.1".to_string(),
        port: DEFAULT_SENTINEL_PORT,
        token: SENTINEL_TOKEN.to_string(),
        bridge_token: Some(BRIDGE_TOKEN.to_string()),
        bridge_url: bridge_url.to_string(),
        state_dir: sc.path("state"),
        bridge_plist: None,
        uid: 501,
        labels,
        bins: Bins::default(),
        child_path: None,
        vault_repo: sc.path("vault"),
        bridge_state_dir: sc.path("bridge-state"),
        autocommit_log: None,
        ledger: sc.path("ledger.jsonl"),
        device_json: sc.path("device.json"),
        deploy_clone: sc.path("deploy/jesse-app"),
        bin_dir: sc.path("bin"),
        github_token: None,
        // Nothing listens here, so a test that forgot to point at the fake API fails loudly
        // rather than asking the real GitHub about a real commit.
        github_api: "http://127.0.0.1:1".to_string(),
        github_repo: "example/example".to_string(),
        ci_job: "bridge".to_string(),
        deploy_health_timeout: Duration::from_secs(90),
    }
}

async fn call(app: Router, method: &str, path: &str, token: Option<&str>) -> (u16, Value) {
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;
    let mut req = Request::builder().method(method).uri(path);
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let resp = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
    let status = resp.status().as_u16();
    let bytes = axum::body::to_bytes(resp.into_body(), 1 << 22)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

// ---- The tests ----------------------------------------------------------------------------

/// THE WATCHDOG'S CENTRAL RULE, end to end: three missed health checks buy one kickstart, and
/// the budget stops it at more than five in an hour.
///
/// Driven by calling `tick` directly rather than by waiting out sixty-second sleeps. The rule
/// is stated in TICKS ("three consecutive ticks"), so counting ticks tests exactly what was
/// specified, and the rolling-hour window is real wall-clock time that a test running in
/// seconds cannot fall out of.
#[tokio::test]
async fn watchdog_kickstarts_after_three_misses_then_gives_up() {
    let sc = Scratch::new("watchdog");
    let record = sc.path("launchctl.log");
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 0);

    // A bridge URL nothing is listening on: every /health is a connection refusal, which is
    // the outage this rule exists for.
    let mut cfg = config(&sc, "http://127.0.0.1:1");
    cfg.bins.launchctl = Some(launchctl);
    let expected_target = format!("kickstart -k gui/501/{}", cfg.label(ServiceSlot::Bridge));
    let sen = Sentinel::new(cfg, None);

    // Two misses buy nothing at all — the three-tick floor is what keeps one dropped
    // connection from restarting the bridge.
    tick(&sen).await;
    tick(&sen).await;
    assert!(
        recorded(&record).is_empty(),
        "two missed checks must not restart anything: {:?}",
        recorded(&record)
    );
    assert_eq!(sen.state.lock().unwrap().bridge_misses, 2);

    // The third buys exactly one.
    tick(&sen).await;
    assert_eq!(recorded(&record).len(), 1);
    assert_eq!(recorded(&record)[0], expected_target);
    // …and the counter resets, so the next one is three ticks away rather than immediate.
    assert_eq!(sen.state.lock().unwrap().bridge_misses, 0);

    // Six kickstarts is 18 ticks. The sixth is what spends the budget (strictly MORE than
    // five in the hour), so run to there and then keep going.
    for _ in 3..18 {
        tick(&sen).await;
    }
    assert_eq!(
        recorded(&record).len(),
        MAX_KICKSTARTS_PER_HOUR + 1,
        "one kickstart per three misses, up to and including the one that spends the budget"
    );
    assert!(
        sen.state.lock().unwrap().bridge_gave_up_ms.is_none(),
        "the budget is not spent until MORE than five have happened in the hour"
    );

    // Everything past that point restarts nothing, however long the bridge stays down.
    for _ in 0..12 {
        tick(&sen).await;
    }
    assert_eq!(
        recorded(&record).len(),
        MAX_KICKSTARTS_PER_HOUR + 1,
        "the watchdog must STOP: a bridge that died six times in an hour is not fixed by a \
         seventh restart"
    );
    let st = sen.state.lock().unwrap();
    assert!(st.bridge_gave_up_ms.is_some(), "the give-up is recorded");
    assert!(
        st.bridge_last_error.is_some(),
        "and so is the error the alert has to name"
    );
    drop(st);

    // The give-up survives the sentinel's own restart: a fresh process reading state.json
    // must not start kickstarting again from zero.
    let reloaded = Sentinel::new(config(&sc, "http://127.0.0.1:1"), None);
    let st = reloaded.state.lock().unwrap();
    assert!(st.bridge_gave_up_ms.is_some());
    assert_eq!(st.kickstarts.len(), MAX_KICKSTARTS_PER_HOUR + 1);
}

/// The watchdog takes the SAME single-flight permit the HTTP verbs take.
///
/// Without this, the watchdog is the one caller able to run a second mutating verb while an
/// operator's is in flight — an automatic `kickstart -k` landing in the middle of a hand-run
/// `reload-env` is exactly the double restart the lock exists to prevent.
#[tokio::test]
async fn the_watchdog_waits_for_an_operator_verb_in_flight() {
    let sc = Scratch::new("singleflight");
    let record = sc.path("launchctl.log");
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 0);
    let mut cfg = config(&sc, "http://127.0.0.1:1");
    cfg.bins.launchctl = Some(launchctl);
    let sen = Sentinel::new(cfg, None);

    // Two misses, so the next tick is the one that would kickstart.
    tick(&sen).await;
    tick(&sen).await;
    assert!(recorded(&record).is_empty());

    // Hold the permit, as a long-running operator verb would.
    let held = sen.verb_lock.lock().await;
    let bg = tokio::spawn({
        let sen = sen.clone();
        async move { tick(&sen).await }
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(
        recorded(&record).is_empty(),
        "the watchdog must not restart anything while a verb holds the permit: {:?}",
        recorded(&record)
    );

    // Released — and the tick then does exactly the one thing it was waiting to do.
    drop(held);
    bg.await.unwrap();
    assert_eq!(recorded(&record).len(), 1, "{:?}", recorded(&record));
}

/// A healthy bridge is never restarted, and a bridge that RECOVERS clears the give-up.
#[tokio::test]
async fn watchdog_leaves_a_healthy_bridge_alone() {
    let sc = Scratch::new("healthy");
    let record = sc.path("launchctl.log");
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 0);
    let (url, _) = start_fake_bridge(json!({ "jobs": [] })).await;

    let mut cfg = config(&sc, &url);
    cfg.bins.launchctl = Some(launchctl);
    let sen = Sentinel::new(cfg, None);
    for _ in 0..6 {
        tick(&sen).await;
    }
    assert!(
        recorded(&record).is_empty(),
        "a bridge answering /health must never be kickstarted: {:?}",
        recorded(&record)
    );
    assert_eq!(sen.state.lock().unwrap().bridge_misses, 0);
}

/// THE TOKEN BOUNDARY, in both directions.
#[tokio::test]
async fn the_two_tokens_are_disjoint_in_both_directions() {
    let sc = Scratch::new("tokens");
    let (url, _) = start_fake_bridge(json!({ "jobs": [] })).await;
    let sen = Sentinel::new(config(&sc, &url), None);

    // The BRIDGE's token buys nothing on the sentinel. This is the direction that matters
    // most: the bridge token travels on every request the phone makes, so if it also opened
    // `launchctl kickstart` a single leak would hand over the machine.
    let (status, _) = call(
        sentinel_app(sen.clone()),
        "GET",
        "/sentinel/status",
        Some(BRIDGE_TOKEN),
    )
    .await;
    assert_eq!(status, 401);

    // And the SENTINEL's token buys nothing on the bridge — checked against the bridge's own
    // `check_auth`, over a real socket.
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{url}/health"))
        .bearer_auth(SENTINEL_TOKEN)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);

    // Each one works on its own service, so the test is not vacuously passing on a broken
    // fixture.
    let (status, _) = call(
        sentinel_app(sen.clone()),
        "GET",
        "/sentinel/status",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 200);
    let resp = client
        .get(format!("{url}/health"))
        .bearer_auth(BRIDGE_TOKEN)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

/// The unlock verb's two refusals, which are the whole safety of it.
#[tokio::test]
async fn unlock_refuses_a_young_lock_and_a_live_git() {
    let sc = Scratch::new("unlock");
    let (url, _) = start_fake_bridge(json!({ "jobs": [] })).await;
    let git_dir = sc.path("vault/.git");
    std::fs::create_dir_all(&git_dir).unwrap();
    let lock = git_dir.join("index.lock");

    let record = sc.path("shims.log");
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 0);
    // pgrep exiting 0 means "a git process matched" — the lock is live.
    let pgrep_live = shim(&sc.path("pgrep-live"), &record, 0, 0);
    // pgrep exiting 1 means "no match", the only outcome that permits the delete.
    let pgrep_none = shim(&sc.path("pgrep-none"), &record, 1, 0);

    // 1) NO LOCK AT ALL — a 409 that says so, rather than a cheerful 200 for work not done.
    let mut cfg = config(&sc, &url);
    cfg.bins.launchctl = Some(launchctl.clone());
    cfg.bins.pgrep = Some(pgrep_none.clone());
    let sen = Sentinel::new(cfg, None);
    let (status, body) = call(
        sentinel_app(sen.clone()),
        "POST",
        "/sentinel/git/unlock",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 409);
    assert_eq!(body["removed"], json!(false));
    assert!(body["reason"].as_str().unwrap().contains("no index.lock"));

    // 2) A YOUNG LOCK — freshly created, so it is presumed live and must survive.
    std::fs::write(&lock, b"").unwrap();
    let (status, body) = call(
        sentinel_app(sen.clone()),
        "POST",
        "/sentinel/git/unlock",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 409);
    assert!(
        body["reason"].as_str().unwrap().contains("presumed live"),
        "{body}"
    );
    assert!(lock.exists(), "a young lock must NOT be deleted");

    // 3) AN OLD LOCK, BUT GIT IS RUNNING. Backdate the file past the floor and let pgrep
    //    report a match: deleting the lock now would corrupt whatever git is holding it.
    backdate(&lock, Duration::from_secs(3600));
    let mut cfg = config(&sc, &url);
    cfg.bins.launchctl = Some(launchctl.clone());
    cfg.bins.pgrep = Some(pgrep_live);
    let sen_live = Sentinel::new(cfg, None);
    let (status, body) = call(
        sentinel_app(sen_live),
        "POST",
        "/sentinel/git/unlock",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 409);
    assert!(
        body["reason"]
            .as_str()
            .unwrap()
            .contains("git process is running"),
        "{body}"
    );
    assert!(
        lock.exists(),
        "a lock held by a live git must NOT be deleted"
    );

    // 4) OLD, AND NO GIT — the one case that removes it, and it kicks the autocommit after.
    let (status, body) = call(
        sentinel_app(sen.clone()),
        "POST",
        "/sentinel/git/unlock",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["removed"], json!(true));
    assert!(!lock.exists());
    assert!(
        recorded(&record)
            .iter()
            .any(|l| l.starts_with("kickstart -k gui/501/com.example.test-autocommit")),
        "the autocommit is kicked so the vault publishes now: {:?}",
        recorded(&record)
    );
}

/// Set a file's mtime `ago` in the past, so an age-based rule can be tested without waiting.
fn backdate(path: &Path, ago: Duration) {
    let when = std::time::SystemTime::now() - ago;
    let f = std::fs::File::options().write(true).open(path).unwrap();
    f.set_modified(when).unwrap();
}

/// A proxy verb forwards only ids the bridge itself knows.
#[tokio::test]
async fn proxy_verbs_reject_an_id_the_schedule_does_not_have() {
    let sc = Scratch::new("proxy");
    let (url, fired) = start_fake_bridge(json!({
        "jobs": [ { "id": "nightly" }, { "id": "morning-routine" } ]
    }))
    .await;
    let sen = Sentinel::new(config(&sc, &url), None);

    // An id that is not in the schedule is a 404 from the SENTINEL, and the bridge is never
    // asked to fire anything.
    let (status, body) = call(
        sentinel_app(sen.clone()),
        "POST",
        "/sentinel/jobs/not-a-job/fire",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 404);
    assert!(body["error"].as_str().unwrap().contains("not-a-job"));
    assert!(fired.lock().unwrap().is_empty());

    // An id outside the alphabet never even reaches the schedule lookup.
    let (status, _) = call(
        sentinel_app(sen.clone()),
        "POST",
        "/sentinel/jobs/..%2Fhealth/fire",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 400);
    assert!(fired.lock().unwrap().is_empty());

    // A real id is forwarded, and the bridge's own 202 is passed through rather than
    // rewritten.
    let (status, body) = call(
        sentinel_app(sen),
        "POST",
        "/sentinel/jobs/nightly/fire",
        Some(SENTINEL_TOKEN),
    )
    .await;
    assert_eq!(status, 202, "{body}");
    assert_eq!(body["bridge_status"], json!(202));
    assert_eq!(*fired.lock().unwrap(), vec!["nightly".to_string()]);
}

/// `GET /sentinel/status` answers even when a probe is wedged.
#[tokio::test]
async fn status_degrades_a_hung_probe_to_unknown_and_still_answers() {
    let sc = Scratch::new("hung");
    let record = sc.path("launchctl.log");
    // A `launchctl` that never returns. The services probe is the one that shells out five
    // times, so this is the worst case for the whole document.
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 300);
    let (url, _) = start_fake_bridge(json!({ "jobs": [] })).await;
    let mut cfg = config(&sc, &url);
    cfg.bins.launchctl = Some(launchctl);
    let sen = Sentinel::new(cfg, None);

    let started = Instant::now();
    let (status, body) = call(
        sentinel_app(sen),
        "GET",
        "/sentinel/status",
        Some(SENTINEL_TOKEN),
    )
    .await;
    let took = started.elapsed();
    assert_eq!(status, 200);
    // The hung subsystem costs ONE `unknown` field…
    assert_eq!(body["services"]["ok"], Value::Null);
    assert_eq!(body["services"]["state"], json!("unknown"));
    // …and everything else still answers, which is the point of running them concurrently.
    assert_eq!(body["bridge"]["ok"], json!(true));
    assert_eq!(
        body["bridge"]["detail"]["health"]["version"],
        json!("0.93.0-fake")
    );
    assert_eq!(
        body["sentinel"]["version"],
        json!(env!("CARGO_PKG_VERSION"))
    );
    // The whole document lands in about one probe timeout, not five of them in series.
    assert!(
        took < Duration::from_secs(15),
        "status took {took:?} — a wedged probe must not hang the one request an operator has"
    );
}

/// Every restart verb addresses the CONFIGURED label for its slot, and nothing else.
#[tokio::test]
async fn each_restart_verb_targets_its_own_label() {
    let sc = Scratch::new("restart");
    let record = sc.path("launchctl.log");
    let launchctl = shim(&sc.path("launchctl"), &record, 0, 0);
    // A bridge URL nothing answers, so the bridge restart's health poll fails fast rather
    // than waiting out its window… which it would do for 60 s. Only the non-bridge slots are
    // exercised here for that reason; the bridge's own path is covered by the watchdog test.
    let mut cfg = config(&sc, "http://127.0.0.1:1");
    cfg.bins.launchctl = Some(launchctl);
    let labels: Vec<(ServiceSlot, String)> = SERVICE_SLOTS
        .into_iter()
        .filter(|s| *s != ServiceSlot::Bridge)
        .map(|s| (s, cfg.label(s).to_string()))
        .collect();
    let sen = Sentinel::new(cfg, None);

    for (slot, label) in &labels {
        let (status, body) = call(
            sentinel_app(sen.clone()),
            "POST",
            &format!("/sentinel/restart/{}", slot.slug()),
            Some(SENTINEL_TOKEN),
        )
        .await;
        assert_eq!(status, 200, "{} → {body}", slot.slug());
        assert_eq!(body["label"], json!(label));
        // A non-bridge restart makes no health claim: there is nothing to poll.
        assert_eq!(body["healthy"], Value::Null);
    }
    let lines = recorded(&record);
    assert_eq!(lines.len(), labels.len());
    for (_, label) in &labels {
        assert!(
            lines.contains(&format!("kickstart -k gui/501/{label}")),
            "no kickstart for {label} in {lines:?}"
        );
    }
    // The audit trail records every one of them, and carries no token.
    let audit = std::fs::read_to_string(sc.path("state/sentinel.log")).unwrap();
    for (slot, _) in &labels {
        assert!(
            audit.contains(&format!("restart/{}", slot.slug())),
            "{audit}"
        );
    }
    assert!(!audit.contains(SENTINEL_TOKEN), "{audit}");
    assert!(!audit.contains(BRIDGE_TOKEN), "{audit}");
}

// ---- The deploy pipeline ================================================================
//
// Four stand-ins, and between them nothing in this section touches a real launchd domain, a
// real GitHub, a real toolchain, or the real `~/.local/bin`:
//
//   * A REAL GIT REPOSITORY — a bare "origin" and a clone of it, built in the scratch
//     directory by actually running `git`. The ancestry rule is the safety property of this
//     whole feature ("only something merged into main is deployable"), and the only way to
//     test it honestly is to hand `git merge-base --is-ancestor` a commit that genuinely is
//     not on main. A mocked git would test the mock.
//
//   * A FAKE GITHUB API — an axum server on loopback answering the two endpoints the CI gate
//     reads, scripted per commit. `JESSE_SENTINEL_GITHUB_API` exists for exactly this.
//
//   * A `cargo` SHIM — a shell script that writes the three "binaries" into
//     `bridge/target/release/`, each one a script that prints a chosen version. That makes
//     the symlink chain executable end to end: the test runs `<bin dir>/jesse-bridge` and
//     sees which build it lands on.
//
//   * A FAKE BRIDGE WITH SCRIPTED HEALTH, keyed on how many times the `launchctl` shim has
//     been called. That is what lets one test say "after the deploy's restart it comes back
//     as the new version" and another say "it comes back as the old one, and after the
//     rollback's restart it does not come back at all".

use jesse_bridge::sentinel::{
    check_ci, is_full_sha, prune_builds, resolve_bin, DeployRecord, Previous, DEPLOY_BINS,
    KEEP_BUILDS,
};

/// The version the `cargo` shim's binaries print, and the version the fake bridge reports
/// after a successful restart.
const NEW_VERSION: &str = "0.94.0";
const OLD_VERSION: &str = "0.93.0";

// ---- git --------------------------------------------------------------------------------

/// Run a real `git`, isolated from whatever is in the developer's `~/.gitconfig` — a global
/// `commit.gpgsign` or `init.defaultBranch` would otherwise make this suite pass or fail
/// depending on whose laptop it is.
fn git_at(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .expect("git must be installed to run the deploy tests");
    assert!(
        out.status.success(),
        "git {args:?} in {} failed: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn write_manifest(work: &Path, version: &str) {
    let dir = work.join("bridge");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("Cargo.toml"),
        format!("[package]\nname = \"jesse-bridge\"\nversion = \"{version}\"\n\n[dependencies]\naxum = \"0.7\"\n"),
    )
    .unwrap();
}

/// A bare origin with `main` (two commits) and an unmerged `side` branch, plus a clone of it.
/// Returns `(clone, main head sha, side sha)`.
fn make_repo(sc: &Scratch) -> (PathBuf, String, String) {
    let origin = sc.path("origin.git");
    let work = sc.path("work");
    let clone = sc.path("deploy/jesse-app");
    std::fs::create_dir_all(&origin).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    std::fs::create_dir_all(clone.parent().unwrap()).unwrap();

    git_at(&origin, &["init", "--bare", "--initial-branch=main", "."]);
    git_at(&work, &["init", "--initial-branch=main", "."]);

    write_manifest(&work, OLD_VERSION);
    git_at(&work, &["add", "bridge/Cargo.toml"]);
    git_at(&work, &["commit", "-m", "base"]);

    // A commit that was pushed but NEVER MERGED. This is the one the ancestry gate must
    // refuse, and it is a real commit on a real branch rather than an invented sha.
    git_at(&work, &["checkout", "-b", "side"]);
    write_manifest(&work, "9.9.9");
    git_at(&work, &["commit", "-am", "unmerged work"]);
    let side = git_at(&work, &["rev-parse", "HEAD"]);

    git_at(&work, &["checkout", "main"]);
    write_manifest(&work, NEW_VERSION);
    git_at(&work, &["commit", "-am", "the release"]);
    let head = git_at(&work, &["rev-parse", "HEAD"]);

    git_at(
        &work,
        &["remote", "add", "origin", &origin.to_string_lossy()],
    );
    git_at(&work, &["push", "-q", "origin", "main", "side"]);
    git_at(
        &sc.0,
        &[
            "clone",
            "-q",
            &origin.to_string_lossy(),
            &clone.to_string_lossy(),
        ],
    );
    (clone, head, side)
}

// ---- The fake GitHub --------------------------------------------------------------------

/// What CI says about one commit, in the four shapes the gate has to tell apart — plus the
/// fifth that looks green and is not: a workflow that succeeded without running our job.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ci {
    Green,
    Red,
    Pending,
    Absent,
    SuccessWithoutBridgeJob,
}

type GhScript = Arc<std::sync::Mutex<std::collections::HashMap<String, Ci>>>;

async fn gh_runs(
    State(script): State<GhScript>,
    axum::extract::Query(q): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Json<Value> {
    let sha = q.get("head_sha").cloned().unwrap_or_default();
    let ci = script
        .lock()
        .unwrap()
        .get(&sha)
        .copied()
        .unwrap_or(Ci::Absent);
    let runs = match ci {
        Ci::Absent => json!([]),
        Ci::Pending => json!([{"id": 30, "name": "CI", "status": "queued", "conclusion": null}]),
        Ci::Red => {
            json!([{"id": 20, "name": "CI", "status": "completed", "conclusion": "failure"}])
        }
        // The green case carries a second, still-running workflow beside the one that
        // passed: a commit normally has several, and "some other workflow has not finished"
        // must not hold up a deploy whose own job is green.
        Ci::Green => json!([
            {"id": 10, "name": "CI", "status": "completed", "conclusion": "success"},
            {"id": 11, "name": "ios-ci", "status": "in_progress", "conclusion": null},
        ]),
        Ci::SuccessWithoutBridgeJob => {
            json!([{"id": 40, "name": "ios-ci", "status": "completed", "conclusion": "success"}])
        }
    };
    Json(json!({ "total_count": runs.as_array().unwrap().len(), "workflow_runs": runs }))
}

async fn gh_jobs(
    axum::extract::Path((_, _, id)): axum::extract::Path<(String, String, u64)>,
) -> Json<Value> {
    let jobs = match id {
        // THE DISPLAY NAME, exactly as this repository's own CI reports it. The gate matches
        // jobs by display name, not by workflow key, and a fixture that said plain "bridge"
        // would have let the equality-test bug through.
        10 => json!([
            {"name": "ios-app", "conclusion": "success"},
            {"name": "bridge (build, test, clippy, guards, audit, coverage)",
             "conclusion": "success"},
        ]),
        // A run that succeeded overall without the job that builds this crate.
        40 => json!([{"name": "ios-app", "conclusion": "success"}]),
        _ => json!([]),
    };
    Json(json!({ "total_count": jobs.as_array().unwrap().len(), "jobs": jobs }))
}

async fn start_fake_github(script: GhScript) -> String {
    let app = Router::new()
        .route("/repos/:owner/:repo/actions/runs", get(gh_runs))
        .route("/repos/:owner/:repo/actions/runs/:id/jobs", get(gh_jobs))
        .with_state(script);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

// ---- The fake bridge, scripted per restart -----------------------------------------------

/// One scripted `/health` answer.
#[derive(Clone)]
struct Health {
    up: bool,
    version: String,
    stale: Vec<String>,
}

impl Health {
    fn up(version: &str) -> Health {
        Health {
            up: true,
            version: version.to_string(),
            stale: Vec::new(),
        }
    }
    fn down() -> Health {
        Health {
            up: false,
            version: String::new(),
            stale: Vec::new(),
        }
    }
    fn stale(version: &str, harness: &str) -> Health {
        Health {
            up: true,
            version: version.to_string(),
            stale: vec![harness.to_string()],
        }
    }
}

#[derive(Clone)]
struct Scripted {
    /// The `launchctl` shim's record. Its LINE COUNT is the restart generation, which is what
    /// makes "before the deploy", "after the deploy's kickstart" and "after the rollback's
    /// kickstart" three different answers without the test having to time anything.
    record: PathBuf,
    states: Arc<Vec<Health>>,
    schedule: Value,
}

async fn scripted_health(
    State(st): State<Scripted>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, String)> {
    check_auth(&headers, BRIDGE_TOKEN)?;
    let generation = std::fs::read_to_string(&st.record)
        .map(|t| t.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0);
    let answer = st.states[generation.min(st.states.len() - 1)].clone();
    if !answer.up {
        return Ok((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false })),
        ));
    }
    let mut body = json!({ "ok": true, "version": answer.version });
    if !answer.stale.is_empty() {
        body["containment_stale"] = json!(answer
            .stale
            .iter()
            .map(|h| json!({ "harness": h, "recorded": "1.0", "installed": "2.0" }))
            .collect::<Vec<_>>());
    }
    Ok((StatusCode::OK, Json(body)))
}

async fn scripted_schedule(
    State(st): State<Scripted>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, String)> {
    check_auth(&headers, BRIDGE_TOKEN)?;
    Ok(Json(st.schedule.clone()))
}

async fn start_scripted_bridge(st: Scripted) -> String {
    let app = Router::new()
        .route("/health", get(scripted_health))
        .route("/jesse/schedule", get(scripted_schedule))
        .with_state(st);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

// ---- The cargo shim ----------------------------------------------------------------------

/// A `cargo` that writes the three release binaries, each one a script printing `version`.
///
/// Plain POSIX shell — CI's `/bin/sh` is dash — and it runs with the working directory the
/// build phase sets, so `target/release` lands inside the clone's `bridge/` exactly where the
/// stage phase looks for it.
fn cargo_shim(path: &Path, record: &Path, version: &str, code: i32) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let body = format!(
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\" >> '{}'\n\
         mkdir -p target/release\n\
         for b in {}; do\n\
         \tprintf '#!/bin/sh\\necho {version}\\n' > \"target/release/$b\"\n\
         \tchmod 755 \"target/release/$b\"\n\
         done\n\
         exit {code}\n",
        record.display(),
        DEPLOY_BINS.join(" "),
    );
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_path_buf()
}

// ---- The world ---------------------------------------------------------------------------

struct World {
    clone: PathBuf,
    bin_dir: PathBuf,
    launchctl_record: PathBuf,
    head: String,
    side: String,
    gh: GhScript,
}

/// Everything wired together: a real repo, a fake GitHub, a fake bridge scripted with
/// `states`, and shims for `launchctl` and `cargo`.
async fn deploy_world(
    sc: &Scratch,
    states: Vec<Health>,
    schedule: Value,
    ci: Ci,
) -> (World, Arc<Sentinel>) {
    let (clone, head, side) = make_repo(sc);
    let launchctl_record = sc.path("launchctl.log");
    let launchctl = shim(&sc.path("launchctl"), &launchctl_record, 0, 0);
    let cargo = cargo_shim(&sc.path("cargo"), &sc.path("cargo.log"), NEW_VERSION, 0);

    let gh: GhScript = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    gh.lock().unwrap().insert(head.clone(), ci);
    let gh_url = start_fake_github(gh.clone()).await;

    let bridge_url = start_scripted_bridge(Scripted {
        record: launchctl_record.clone(),
        states: Arc::new(states),
        schedule,
    })
    .await;

    let mut cfg = config(sc, &bridge_url);
    cfg.deploy_clone = clone.clone();
    cfg.bin_dir = sc.path("bin");
    cfg.github_token = Some("read-only-test-token".to_string());
    cfg.github_api = gh_url;
    cfg.github_repo = "example/example".to_string();
    // Four seconds rather than ninety: the rollback tests deliberately let this window close,
    // twice, and the rule under test is "the version did not match", not "we waited".
    cfg.deploy_health_timeout = Duration::from_secs(4);
    cfg.bins.git = resolve_bin("git", &["/usr/bin/git"]);
    cfg.bins.launchctl = Some(launchctl);
    cfg.bins.cargo = Some(cargo);
    let bin_dir = cfg.bin_dir.clone();
    std::fs::create_dir_all(&bin_dir).unwrap();
    let sen = Sentinel::new(cfg, None);
    (
        World {
            clone,
            bin_dir,
            launchctl_record,
            head,
            side,
            gh,
        },
        sen,
    )
}

/// Start a deploy through the ROUTER, so the bearer check, the rate limiter and the audit
/// line are all in the path — a deploy driven by calling the verb directly would skip the
/// gates that make it safe.
async fn post_deploy(sen: &Arc<Sentinel>, body: Value) -> (u16, Value) {
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;
    let req = Request::builder()
        .method("POST")
        .uri("/sentinel/deploy")
        .header("authorization", format!("Bearer {SENTINEL_TOKEN}"))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap();
    let resp = sentinel_app(sen.clone()).oneshot(req).await.unwrap();
    let status = resp.status().as_u16();
    let bytes = axum::body::to_bytes(resp.into_body(), 1 << 22)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

/// Wait for the spawned pipeline to reach a terminal state.
async fn await_deploy(sen: &Arc<Sentinel>) -> DeployRecord {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let snapshot = sen.state.lock().unwrap().deploy.clone();
        if let Some(rec) = snapshot {
            if rec.result.is_some() {
                return rec;
            }
        }
        assert!(
            Instant::now() < deadline,
            "the deploy never finished: {:?}",
            sen.state.lock().unwrap().deploy
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Run the symlink at `<bin dir>/<name>` and return what it printed — the end-to-end proof
/// that the link resolves to the build this deploy staged.
fn run_link(bin_dir: &Path, name: &str) -> String {
    let out = std::process::Command::new(bin_dir.join(name))
        .output()
        .unwrap_or_else(|e| panic!("could not execute {}/{name}: {e}", bin_dir.display()));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn previous_map(sen: &Arc<Sentinel>) -> Previous {
    let text = std::fs::read_to_string(sen.cfg.previous_file()).unwrap_or_default();
    serde_json::from_str(&text).unwrap_or_default()
}

/// Seed `<bin dir>` with a deployment that is already there, so a rollback has somewhere to
/// go back to. Returns the directory the links point into.
fn seed_installed(bin_dir: &Path, version: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let old = bin_dir.parent().unwrap().join("already-installed");
    std::fs::create_dir_all(&old).unwrap();
    for name in DEPLOY_BINS {
        let p = old.join(name);
        std::fs::write(&p, format!("#!/bin/sh\necho {version}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        let link = bin_dir.join(name);
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&p, &link).unwrap();
    }
    old
}

// ---- The tests ---------------------------------------------------------------------------

/// THE ANCESTRY RULE, against a real unmerged commit.
///
/// This is the safety property the whole feature rests on: the sentinel can replace the bridge
/// binary, and what keeps that bounded is that the only thing it will build is a commit that
/// reached `main` — which, with branch protection, means a reviewed PR whose checks passed.
/// A commit that was merely pushed is refused, and the refusal happens BEFORE the CI call, so
/// an unmerged branch cannot even spend an API request.
#[tokio::test]
async fn an_unmerged_commit_is_refused_before_ci_is_consulted() {
    let sc = Scratch::new("deploy-ancestry");
    let (w, sen) = deploy_world(
        &sc,
        vec![Health::up(OLD_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    // The side commit is marked GREEN, so the only thing that can refuse it is ancestry.
    w.gh.lock().unwrap().insert(w.side.clone(), Ci::Green);

    let (status, body) = post_deploy(&sen, json!({ "ref": w.side })).await;
    assert_eq!(status, 202, "{body}");
    let rec = await_deploy(&sen).await;
    assert_eq!(rec.result.as_deref(), Some("failed"));
    assert_eq!(
        rec.phase, "resolve",
        "it must stop in resolve, not reach ci"
    );
    let reason = rec.reason.unwrap_or_default();
    assert!(reason.contains("not an ancestor"), "{reason}");
    // Nothing was built and nothing was restarted.
    assert!(!sen.cfg.build_store().exists());
    assert!(recorded(&w.launchctl_record).is_empty());
}

/// A ref that is neither `main` nor a full sha never reaches `git` at all.
#[tokio::test]
async fn a_ref_outside_the_alphabet_is_a_400() {
    let sc = Scratch::new("deploy-alphabet");
    let (_w, sen) = deploy_world(
        &sc,
        vec![Health::up(OLD_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    for bad in [
        "origin/main",
        "--upload-pack=/bin/sh",
        "main;id",
        "HEAD",
        "3dbea71",
    ] {
        let (status, body) = post_deploy(&sen, json!({ "ref": bad })).await;
        assert_eq!(status, 400, "{bad} was accepted: {body}");
    }
    // And no deploy was ever started, so the lock is free and state is untouched.
    assert!(sen.state.lock().unwrap().deploy.is_none());
    assert!(!sen.cfg.deploy_lock().exists());
}

/// RED, PENDING, ABSENT — and the fourth shape, a workflow that succeeded without running the
/// job that builds this crate. All four refuse, and each says which it was.
#[tokio::test]
async fn ci_that_is_not_green_refuses_and_names_the_kind() {
    for (ci, expect) in [
        (Ci::Red, "red"),
        (Ci::Pending, "pending"),
        (Ci::Absent, "none"),
        (Ci::SuccessWithoutBridgeJob, "red"),
    ] {
        let sc = Scratch::new("deploy-ci");
        let (w, sen) = deploy_world(
            &sc,
            vec![Health::up(OLD_VERSION)],
            json!({ "jobs": [] }),
            ci,
        )
        .await;
        let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
        assert_eq!(status, 202);
        let rec = await_deploy(&sen).await;
        assert_eq!(rec.result.as_deref(), Some("failed"), "{ci:?}");
        assert_eq!(rec.phase, "ci", "{ci:?} must stop in the ci phase");
        let reason = rec.reason.unwrap_or_default();
        assert!(reason.contains(expect), "{ci:?} → {reason}");
        // Resolve still happened, so the commit is known; the build never started.
        assert_eq!(rec.sha.as_deref(), Some(w.head.as_str()));
        assert!(!sen.cfg.build_store().exists(), "{ci:?} built something");
        // A commit with a green `bridge` job is still refused when the sha is not on main,
        // and one without it is refused even when its workflow passed — the two halves of
        // the gate are independent, and this is the half that catches a green-looking run.
        if ci == Ci::SuccessWithoutBridgeJob {
            let verdict = check_ci(&sen, &w.head).await.unwrap();
            assert_eq!(verdict.state, "red");
            assert!(verdict.detail.contains("bridge"), "{}", verdict.detail);
        }
    }
}

/// `force` is about the SCHEDULER, not about CI.
///
/// Two claims in one test, because they are the same claim from both sides: without `force` a
/// running chain is a `409` (a deploy kills the bridge, and a turn that dies mid-chain is lost
/// invisibly), and with `force` the deploy starts — and then still refuses, because CI is red.
/// There is no argument to this verb that installs a commit CI has not passed.
#[tokio::test]
async fn force_bypasses_a_running_chain_but_never_ci() {
    let sc = Scratch::new("deploy-force");
    let busy = json!({ "jobs": [
        { "id": "nightly", "running": true },
        { "id": "morning", "running": false },
    ]});
    let (_w, sen) = deploy_world(&sc, vec![Health::up(OLD_VERSION)], busy, Ci::Red).await;

    let (status, body) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["running"], json!(["nightly"]));
    assert!(
        sen.state.lock().unwrap().deploy.is_none(),
        "nothing started"
    );

    let (status, _) = post_deploy(&sen, json!({ "ref": "main", "force": true })).await;
    assert_eq!(status, 202, "force must get past the running chain");
    let rec = await_deploy(&sen).await;
    assert_eq!(rec.result.as_deref(), Some("failed"));
    assert_eq!(rec.phase, "ci", "force must NOT get past CI");
}

/// THE HAPPY PATH, end to end.
///
/// The assertions that matter are the ones about the filesystem and about `running_sha`,
/// because those are what a later deploy and a later rollback are written in terms of. The
/// symlink is EXECUTED rather than merely read: a link whose target is right and whose
/// permissions are wrong is a bridge that will not start, and reading the link would not
/// notice.
#[tokio::test]
async fn a_healthy_deploy_repoints_the_symlinks_and_records_the_sha() {
    let sc = Scratch::new("deploy-ok");
    let (w, sen) = deploy_world(
        &sc,
        // Generation 0 is the old bridge; after the deploy's one kickstart it is the new one.
        vec![Health::up(OLD_VERSION), Health::up(NEW_VERSION)],
        json!({ "jobs": [{ "id": "nightly", "running": false }] }),
        Ci::Green,
    )
    .await;
    let previously_installed = seed_installed(&w.bin_dir, OLD_VERSION);

    let (status, body) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202, "{body}");
    assert!(body["deploy_id"].is_string(), "{body}");

    let rec = await_deploy(&sen).await;
    assert_eq!(rec.result.as_deref(), Some("ok"), "{:?}", rec.reason);
    assert_eq!(rec.phase, "finish");
    assert_eq!(rec.sha.as_deref(), Some(w.head.as_str()));
    assert!(rec.reason.unwrap_or_default().contains(NEW_VERSION));
    assert!(
        !rec.log_tail.is_empty(),
        "the phone needs something to show"
    );

    // All three links point into this commit's build directory, and all three run.
    let built = sen.cfg.build_store().join(&w.head);
    for name in DEPLOY_BINS {
        assert_eq!(
            std::fs::read_link(w.bin_dir.join(name)).unwrap(),
            built.join(name),
            "{name}"
        );
        assert_eq!(run_link(&w.bin_dir, name), NEW_VERSION, "{name}");
    }
    // The rollback record names where they pointed BEFORE, which is the old install.
    let prev = previous_map(&sen);
    for name in DEPLOY_BINS {
        assert_eq!(
            prev.get(name).map(String::as_str),
            Some(previously_installed.join(name).to_string_lossy().as_ref()),
            "{name}"
        );
    }
    // The bridge was kickstarted exactly once, and the commit is recorded as running.
    assert_eq!(recorded(&w.launchctl_record).len(), 1);
    assert!(recorded(&w.launchctl_record)[0].contains("kickstart -k"));
    assert_eq!(
        sen.state.lock().unwrap().running_sha.as_deref(),
        Some(w.head.as_str())
    );
    // The lock is released, so the next deploy is not blocked by this one.
    assert!(!sen.cfg.deploy_lock().exists());

    // The status card now answers with all three halves, and the deploy button's two
    // conditions (`origin_main.sha != running.sha`, `ci == green`) can be evaluated from it.
    let card = jesse_bridge::sentinel::deploy_status_document(&sen).await;
    assert_eq!(card["running"]["sha"], json!(w.head));
    assert_eq!(card["running"]["version"], json!(NEW_VERSION));
    assert_eq!(card["origin_main"]["sha"], json!(w.head));
    assert_eq!(card["origin_main"]["ci"], json!("green"));
    assert_eq!(card["origin_main"]["version"], json!(NEW_VERSION));
    assert_eq!(card["deploy"]["result"], json!("ok"));

    // And the same commit is refused a second time without `force` — it is already running.
    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);
    let again = await_deploy(&sen).await;
    assert_eq!(again.result.as_deref(), Some("failed"));
    assert!(
        again
            .reason
            .unwrap_or_default()
            .contains("already the running bridge"),
        "a redeploy of the running commit must be refused without force"
    );
}

/// THE ROLLBACK. The bridge comes back on the OLD version — the symptom of a swap that
/// silently did nothing, and the reason the deploy checks a version rather than a heartbeat.
#[tokio::test]
async fn a_version_mismatch_rolls_back_to_the_previous_symlinks() {
    let sc = Scratch::new("deploy-rollback");
    let (w, sen) = deploy_world(
        &sc,
        // It never becomes the new version, however many times it is restarted.
        vec![Health::up(OLD_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    let previously_installed = seed_installed(&w.bin_dir, OLD_VERSION);

    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);
    let rec = await_deploy(&sen).await;
    assert_eq!(
        rec.result.as_deref(),
        Some("rolled_back"),
        "{:?}",
        rec.reason
    );
    assert_eq!(rec.phase, "rollback");
    let reason = rec.reason.unwrap_or_default();
    assert!(
        reason.contains("0.93.0") && reason.contains("0.94.0"),
        "{reason}"
    );

    // The links are back on the old install and still executable.
    for name in DEPLOY_BINS {
        assert_eq!(
            std::fs::read_link(w.bin_dir.join(name)).unwrap(),
            previously_installed.join(name),
            "{name} was left on the failed build"
        );
        assert_eq!(run_link(&w.bin_dir, name), OLD_VERSION, "{name}");
    }
    // Two kickstarts: the deploy's and the rollback's.
    assert_eq!(recorded(&w.launchctl_record).len(), 2);
    // A rolled-back deploy did NOT change what is running, so `running_sha` stays as it was —
    // which, before any successful deploy, is nothing. Claiming the sha here would make the
    // next deploy of that commit refuse itself as "already running".
    assert_eq!(sen.state.lock().unwrap().running_sha, None);
    // The build is still on disk: it is the evidence, and pruning it would delete the thing
    // someone now has to look at.
    assert!(sen.cfg.build_store().join(&w.head).is_dir());
}

/// A NEW stale containment record fails the deploy the same way a wrong version does — and it
/// fails it IMMEDIATELY, because no amount of waiting makes a record match the host.
#[tokio::test]
async fn a_newly_stale_containment_record_rolls_back() {
    let sc = Scratch::new("deploy-stale");
    let (w, sen) = deploy_world(
        &sc,
        vec![
            // Before: healthy, and `claude-code` is ALREADY stale.
            Health::stale(OLD_VERSION, "claude-code"),
            // After: the right version, but now `codex` is stale too.
            Health::stale(NEW_VERSION, "codex"),
        ],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    seed_installed(&w.bin_dir, OLD_VERSION);

    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);
    let rec = await_deploy(&sen).await;
    assert_eq!(
        rec.result.as_deref(),
        Some("rolled_back"),
        "{:?}",
        rec.reason
    );
    let reason = rec.reason.unwrap_or_default();
    assert!(
        reason.contains("containment") && reason.contains("codex"),
        "{reason}"
    );
    // `claude-code` was stale before, so it is not what failed the deploy.
    assert!(!reason.contains("claude-code"), "{reason}");
}

/// THE WORST CASE: the deploy failed AND the old binaries did not come back either. It gets its
/// own result, because it is the one outcome where nobody should be told the system is fine.
#[tokio::test]
async fn a_rollback_that_does_not_come_up_reports_rolled_back_unhealthy() {
    let sc = Scratch::new("deploy-unhealthy");
    let (w, sen) = deploy_world(
        &sc,
        vec![
            Health::up(OLD_VERSION), // before the deploy
            Health::up(OLD_VERSION), // after the deploy's kickstart: wrong version
            Health::down(),          // after the rollback's kickstart: nothing answers
        ],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    seed_installed(&w.bin_dir, OLD_VERSION);

    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);
    let rec = await_deploy(&sen).await;
    assert_eq!(
        rec.result.as_deref(),
        Some("rolled_back_unhealthy"),
        "{:?}",
        rec.reason
    );
    let reason = rec.reason.unwrap_or_default();
    assert!(reason.contains("hands on the host"), "{reason}");
    // The links were still put back, even though what they point at is not answering: the
    // rollback's job is to restore the previous deployment, and whether that deployment then
    // starts is a separate fact the result already carries.
    for name in DEPLOY_BINS {
        assert_eq!(run_link(&w.bin_dir, name), OLD_VERSION, "{name}");
    }
    assert_eq!(recorded(&w.launchctl_record).len(), 2);
}

/// A lock naming a DEAD pid is reclaimed; one naming a live process is not.
///
/// The dead case is the one that matters in practice — a sentinel killed mid-build leaves
/// exactly that behind, and without reclamation every later deploy would refuse until someone
/// reached the host, which is the situation this whole service exists to avoid.
#[tokio::test]
async fn a_stale_lock_from_a_dead_pid_is_reclaimed_and_a_live_one_is_not() {
    let sc = Scratch::new("deploy-lock");
    let (w, sen) = deploy_world(
        &sc,
        vec![Health::up(OLD_VERSION), Health::up(NEW_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    std::fs::create_dir_all(sen.cfg.deploy_lock().parent().unwrap()).unwrap();

    // pid 1 is alive and is not us. It cannot be signalled by this user either, and EPERM has
    // to read as "alive" — reclaiming on the strength of "I am not allowed to look" would let
    // two deploys run at once.
    std::fs::write(sen.cfg.deploy_lock(), "1\n").unwrap();
    let (status, body) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 409, "{body}");
    assert!(body["error"].as_str().unwrap().contains("pid 1"), "{body}");

    // A pid that has exited and been reaped.
    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", "exit 0"])
        .spawn()
        .unwrap();
    let dead = child.id();
    child.wait().unwrap();
    std::fs::write(sen.cfg.deploy_lock(), format!("{dead}\n")).unwrap();

    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202, "a lock held by a dead pid must be reclaimed");
    let rec = await_deploy(&sen).await;
    assert_eq!(rec.result.as_deref(), Some("ok"), "{:?}", rec.reason);
    assert_eq!(
        sen.state.lock().unwrap().running_sha.as_deref(),
        Some(w.head.as_str())
    );
    assert!(!sen.cfg.deploy_lock().exists(), "the lock is released");
}

/// A second deploy while one is running is refused — the single-flight permit is gone by then
/// (the verb answered `202` twenty minutes earlier), so this is the deploy lock's own job.
#[tokio::test]
async fn a_second_deploy_while_one_runs_is_refused() {
    let sc = Scratch::new("deploy-concurrent");
    let (_w, sen) = deploy_world(
        &sc,
        // Never becomes the new version, so the first deploy sits in its health window long
        // enough for the second request to arrive.
        vec![Health::up(OLD_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);

    // Wait until the pipeline is past `resolve` so it is unambiguously in flight.
    let deadline = Instant::now() + Duration::from_secs(30);
    while sen
        .state
        .lock()
        .unwrap()
        .deploy
        .as_ref()
        .map(|d| d.phase.clone())
        == Some("resolve".to_string())
    {
        assert!(Instant::now() < deadline, "the deploy never left resolve");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (status, body) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 409, "{body}");
    assert!(
        body["error"].as_str().unwrap().contains("already running"),
        "{body}"
    );
    let _ = await_deploy(&sen).await;
}

/// The build store is pruned to three, and a deploy that succeeds is what triggers it.
#[tokio::test]
async fn a_successful_deploy_prunes_the_store_to_three_builds() {
    let sc = Scratch::new("deploy-prune");
    let (w, sen) = deploy_world(
        &sc,
        vec![Health::up(OLD_VERSION), Health::up(NEW_VERSION)],
        json!({ "jobs": [] }),
        Ci::Green,
    )
    .await;
    seed_installed(&w.bin_dir, OLD_VERSION);
    // Four older builds already in the store, none of them in use.
    let store = sen.cfg.build_store();
    for i in 0..4 {
        let sha = format!("{i}").repeat(40)[..40].to_string();
        std::fs::create_dir_all(store.join(&sha)).unwrap();
        std::fs::write(store.join(&sha).join("jesse-bridge"), b"old").unwrap();
    }

    let (status, _) = post_deploy(&sen, json!({ "ref": "main" })).await;
    assert_eq!(status, 202);
    let rec = await_deploy(&sen).await;
    assert_eq!(rec.result.as_deref(), Some("ok"), "{:?}", rec.reason);

    let left: Vec<String> = std::fs::read_dir(&store)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| is_full_sha(n))
        .collect();
    assert_eq!(left.len(), KEEP_BUILDS, "kept {left:?}");
    assert!(
        left.contains(&w.head),
        "the build just deployed must survive"
    );
    // The pure function backing this is exercised in the unit tests; what this asserts is
    // that the finish phase actually calls it, with the live links protected.
    assert!(prune_builds(&w.bin_dir, &store, &previous_map(&sen), KEEP_BUILDS).is_empty());
    assert!(w.clone.join(".git").is_dir());
}
