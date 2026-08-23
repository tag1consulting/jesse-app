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

/// The deploy surface P5 fills in is declared and refuses, under the same auth.
#[tokio::test]
async fn deploy_routes_answer_501_until_p5() {
    let sc = Scratch::new("deploy");
    let (url, _) = start_fake_bridge(json!({ "jobs": [] })).await;
    let sen = Sentinel::new(config(&sc, &url), None);
    for (method, path) in [
        ("GET", "/sentinel/deploy/status"),
        ("POST", "/sentinel/deploy"),
    ] {
        let (status, body) = call(
            sentinel_app(sen.clone()),
            method,
            path,
            Some(SENTINEL_TOKEN),
        )
        .await;
        assert_eq!(status, 501, "{method} {path}");
        assert_eq!(body, json!({ "error": "deploy not built yet" }));
    }
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
