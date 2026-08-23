use super::*;
use axum::extract::ConnectInfo;
use std::net::SocketAddr;

// ---- The routes -------------------------------------------------------------------
//
// THE WHOLE SURFACE, and it is deliberately short enough to read in one screen. One read
// route and eight mutating ones, every one of them a named operation. There is no route
// that takes a command, a path, a label or a shell string.
//
// Every mutating route passes three gates in the same order, and the order matters:
//   1. the bearer token, constant-time, using the bridge's own `check_auth`;
//   2. the rate limiter, ten a minute — a verb is a button press, not a poll;
//   3. SINGLE FLIGHT, one mutating verb at a time across the whole service.
// …and then the outcome is audited, whatever it was.

/// Build the router.
pub fn sentinel_app(sen: Arc<Sentinel>) -> Router {
    Router::new()
        .route("/sentinel/status", get(status))
        .route("/sentinel/restart/:service", post(restart))
        .route("/sentinel/bridge/reload-env", post(reload_env))
        .route("/sentinel/git/unlock", post(git_unlock))
        .route("/sentinel/artifacts/prune", post(prune_artifacts))
        .route("/sentinel/jobs/:id/fire", post(job_fire))
        .route("/sentinel/jobs/:id/enable", post(job_enable))
        // P5 fills these in. They are declared NOW, answering 501, so the app and the
        // installer can be written against the final route table and a client can tell
        // "this sentinel is too old" from "that is not a route".
        .route("/sentinel/deploy/status", get(deploy_unimplemented))
        .route("/sentinel/deploy", post(deploy_unimplemented))
        // A small ceiling: the only bodies here are `{"force":true}` and
        // `{"enabled":false,"until":"…"}`.
        .layer(DefaultBodyLimit::max(8 * 1024))
        .with_state(sen)
}

/// The caller's address for the audit line, or `-` when the server was mounted without
/// `ConnectInfo` (which is how the unit tests drive the router).
fn caller(addr: Option<&ConnectInfo<SocketAddr>>) -> String {
    addr.map(|c| c.0.ip().to_string())
        .unwrap_or_else(|| "-".to_string())
}

/// `GET /sentinel/status`. Bearer-gated like everything else — the document names launchd
/// labels, paths, tailnet addresses and the bridge's health detail, all of which are
/// operator information.
///
/// NOT rate-limited and NOT single-flighted: it changes nothing, and the one moment someone
/// hammers refresh is the moment the bridge is down. Its cost is bounded by the probe
/// timeouts instead.
async fn status(
    State(sen): State<Arc<Sentinel>>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &sen.cfg.token)?;
    Ok(Json(status_document(&sen).await))
}

/// The three gates every mutating verb passes, and the single-flight permit it must hold
/// for the duration. Returns the permit so the caller cannot accidentally release it early.
async fn admit_verb<'a>(
    sen: &'a Sentinel,
    headers: &HeaderMap,
) -> Result<tokio::sync::MutexGuard<'a, ()>, (StatusCode, Json<Value>)> {
    check_auth(headers, &sen.cfg.token).map_err(|(s, m)| (s, Json(json!({ "error": m }))))?;
    if !sen.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({
                "error": format!("rate limit exceeded ({VERB_RATE_PER_MIN} verbs per minute)")
            })),
        ));
    }
    sen.verb_lock.try_lock().map_err(|_| {
        (
            StatusCode::CONFLICT,
            Json(json!({
                "error": "another sentinel verb is already running — this service runs one \
                          at a time on purpose"
            })),
        )
    })
}

/// Run a verb behind the gates and audit whatever it returned.
async fn guarded(
    sen: &Arc<Sentinel>,
    headers: &HeaderMap,
    who: &str,
    name: &str,
    run: impl Future<Output = VerbResult>,
) -> (StatusCode, Json<Value>) {
    let _permit = match admit_verb(sen, headers).await {
        Ok(p) => p,
        Err((status, body)) => {
            // A refused verb is audited too: "someone pressed this and was rate-limited"
            // is exactly the kind of thing that is invisible otherwise. An UNAUTHENTICATED
            // attempt is audited as well, and carries no token — only that it happened.
            sen.audit(who, name, &format!("refused {}", status.as_u16()));
            return (status, body);
        }
    };
    match run.await {
        Ok((status, body)) => {
            sen.audit(who, name, &format!("ok {}", status.as_u16()));
            (status, Json(body))
        }
        Err((status, body)) => {
            let reason = body
                .get("error")
                .or_else(|| body.get("reason"))
                .and_then(Value::as_str)
                .unwrap_or("failed");
            sen.audit(who, name, &format!("{} {reason}", status.as_u16()));
            (status, Json(body))
        }
    }
}

async fn restart(
    State(sen): State<Arc<Sentinel>>,
    UrlPath(service): UrlPath<String>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    let who = caller(connect.as_ref());
    let Some(slot) = ServiceSlot::from_slug(&service) else {
        // Audited by SLUG, never echoed back verbatim into the log line beyond the closed
        // set check — the 404 body names the five that exist, which is the useful answer.
        sen.audit(&who, "restart/?", "404 unknown service");
        return (
            StatusCode::NOT_FOUND,
            Json(json!({
                "error": "unknown service",
                "services": SERVICE_SLOTS.map(|s| s.slug()),
            })),
        );
    };
    let name = format!("restart/{}", slot.slug());
    guarded(&sen, &headers, &who, &name, verb_restart(&sen, slot)).await
}

async fn reload_env(
    State(sen): State<Arc<Sentinel>>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    let who = caller(connect.as_ref());
    guarded(
        &sen,
        &headers,
        &who,
        "bridge/reload-env",
        verb_reload_env(&sen),
    )
    .await
}

async fn git_unlock(
    State(sen): State<Arc<Sentinel>>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    let who = caller(connect.as_ref());
    guarded(&sen, &headers, &who, "git/unlock", verb_git_unlock(&sen)).await
}

async fn prune_artifacts(
    State(sen): State<Arc<Sentinel>>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    let who = caller(connect.as_ref());
    guarded(
        &sen,
        &headers,
        &who,
        "artifacts/prune",
        verb_prune_artifacts(&sen),
    )
    .await
}

async fn job_fire(
    State(sen): State<Arc<Sentinel>>,
    UrlPath(id): UrlPath<String>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    body: Option<Json<Value>>,
) -> (StatusCode, Json<Value>) {
    job(sen, JobVerb::Fire, id, connect, headers, body).await
}

async fn job_enable(
    State(sen): State<Arc<Sentinel>>,
    UrlPath(id): UrlPath<String>,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    body: Option<Json<Value>>,
) -> (StatusCode, Json<Value>) {
    job(sen, JobVerb::Enable, id, connect, headers, body).await
}

async fn job(
    sen: Arc<Sentinel>,
    verb: JobVerb,
    id: String,
    connect: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    body: Option<Json<Value>>,
) -> (StatusCode, Json<Value>) {
    let who = caller(connect.as_ref());
    let body = body.map(|Json(v)| v).unwrap_or_else(|| json!({}));
    // The id reaches the audit line only after the alphabet check, so a hostile value cannot
    // write control characters or a fake line into the log.
    let name = if validate_schedule_id(&id) {
        format!("jobs/{id}/{}", verb_slug(verb))
    } else {
        format!("jobs/?/{}", verb_slug(verb))
    };
    guarded(&sen, &headers, &who, &name, verb_job(&sen, verb, &id, body)).await
}

fn verb_slug(v: JobVerb) -> &'static str {
    match v {
        JobVerb::Fire => "fire",
        JobVerb::Enable => "enable",
    }
}

/// P5's two routes, declared and refusing. Bearer-gated so an unauthenticated caller cannot
/// even learn that a deploy surface exists here.
async fn deploy_unimplemented(
    State(sen): State<Arc<Sentinel>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    if let Err((status, message)) = check_auth(&headers, &sen.cfg.token) {
        return (status, Json(json!({ "error": message })));
    }
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({ "error": "deploy not built yet" })),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sentinel::tests::test_config;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    /// A sentinel wired to nothing: no launchctl, no bridge, a scratch state dir. Enough to
    /// exercise the gates, which is what these tests are about.
    fn wired(dir: &Path) -> Arc<Sentinel> {
        let mut labels = HashMap::new();
        for slot in SERVICE_SLOTS {
            labels.insert(slot, slot.default_label().to_string());
        }
        let mut cfg = test_config(labels);
        cfg.state_dir = dir.to_path_buf();
        // A port nothing listens on, so every bridge call fails fast rather than reaching a
        // real bridge that might be running on this machine.
        cfg.bridge_url = "http://127.0.0.1:1".to_string();
        Sentinel::new(cfg, None)
    }

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("jesse-sentinel-http-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    async fn call(app: Router, method: &str, path: &str, token: Option<&str>) -> (u16, Value) {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(t) = token {
            req = req.header("authorization", format!("Bearer {t}"));
        }
        let resp = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        let status = resp.status().as_u16();
        let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
            .await
            .unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, body)
    }

    #[tokio::test]
    async fn every_route_refuses_the_wrong_token() {
        let dir = scratch();
        let sen = wired(&dir);
        for (method, path) in [
            ("GET", "/sentinel/status"),
            ("POST", "/sentinel/restart/bridge"),
            ("POST", "/sentinel/bridge/reload-env"),
            ("POST", "/sentinel/git/unlock"),
            ("POST", "/sentinel/artifacts/prune"),
            ("POST", "/sentinel/jobs/nightly/fire"),
            ("POST", "/sentinel/jobs/nightly/enable"),
            ("GET", "/sentinel/deploy/status"),
            ("POST", "/sentinel/deploy"),
        ] {
            // THE BRIDGE'S TOKEN IS NOT THE SENTINEL'S. `test_config` sets them to different
            // values, and presenting the bridge's must be a 401 on every single route —
            // that disjointness is the boundary between "can ask a question of the vault"
            // and "can restart the machine's services".
            let (status, _) = call(
                sentinel_app(sen.clone()),
                method,
                path,
                Some("bridge-token"),
            )
            .await;
            assert_eq!(status, 401, "{method} {path} accepted the bridge's token");
            let (status, _) = call(sentinel_app(sen.clone()), method, path, None).await;
            assert_eq!(status, 401, "{method} {path} accepted no token");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn restart_rejects_a_service_that_is_not_in_the_table() {
        let dir = scratch();
        let sen = wired(&dir);
        let (status, body) = call(
            sentinel_app(sen.clone()),
            "POST",
            "/sentinel/restart/com.example.something-else",
            Some("sentinel-token"),
        )
        .await;
        assert_eq!(status, 404);
        // The answer names the closed set, so a caller learns the vocabulary rather than
        // guessing at labels.
        assert_eq!(
            body["services"],
            json!([
                "bridge",
                "autocommit",
                "lock-reaper",
                "qmd-update",
                "miniserve"
            ])
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn deploy_is_declared_and_refuses_until_p5() {
        let dir = scratch();
        let sen = wired(&dir);
        for (method, path) in [
            ("GET", "/sentinel/deploy/status"),
            ("POST", "/sentinel/deploy"),
        ] {
            let (status, body) = call(
                sentinel_app(sen.clone()),
                method,
                path,
                Some("sentinel-token"),
            )
            .await;
            assert_eq!(status, 501, "{method} {path}");
            assert_eq!(body, json!({ "error": "deploy not built yet" }));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn the_verb_rate_limit_sheds_the_eleventh() {
        let dir = scratch();
        let sen = wired(&dir);
        // `git/unlock` with no repository present is a fast, harmless 409 — it consumes a
        // token and touches nothing, which is exactly what this needs.
        let mut statuses = Vec::new();
        for _ in 0..(VERB_RATE_PER_MIN + 1) {
            let (status, _) = call(
                sentinel_app(sen.clone()),
                "POST",
                "/sentinel/git/unlock",
                Some("sentinel-token"),
            )
            .await;
            statuses.push(status);
        }
        assert!(
            statuses
                .iter()
                .take(VERB_RATE_PER_MIN as usize)
                .all(|s| *s != 429),
            "the first {VERB_RATE_PER_MIN} must not be shed: {statuses:?}"
        );
        assert_eq!(
            *statuses.last().unwrap(),
            429,
            "the eleventh verb in a minute must be shed: {statuses:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_verb_is_audited_with_no_token_in_the_line() {
        let dir = scratch();
        let sen = wired(&dir);
        let _ = call(
            sentinel_app(sen.clone()),
            "POST",
            "/sentinel/git/unlock",
            Some("sentinel-token"),
        )
        .await;
        // A refused (401) attempt must be recorded too.
        let _ = call(
            sentinel_app(sen.clone()),
            "POST",
            "/sentinel/git/unlock",
            Some("wrong"),
        )
        .await;
        let log = std::fs::read_to_string(sen.cfg.audit_file()).unwrap();
        assert!(log.contains("git/unlock"), "{log}");
        assert!(log.contains("refused 401"), "{log}");
        // THE AUDIT TRAIL MUST NEVER CARRY A SECRET. Neither the presented value nor the
        // configured one may appear, or the log becomes the thing worth stealing.
        assert!(!log.contains("sentinel-token"), "{log}");
        assert!(!log.contains("bridge-token"), "{log}");
        assert!(!log.contains("wrong"), "{log}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_proxy_verb_refuses_an_id_outside_the_alphabet_without_calling_the_bridge() {
        let dir = scratch();
        let sen = wired(&dir);
        // A traversal-shaped id is refused by the alphabet check FIRST, so it never becomes
        // part of a URL. (Axum decodes `%2F`, so this arrives as a single path segment.)
        let (status, body) = call(
            sentinel_app(sen.clone()),
            "POST",
            "/sentinel/jobs/..%2F..%2Fjesse%2Fmodels/fire",
            Some("sentinel-token"),
        )
        .await;
        assert_eq!(status, 400);
        assert!(
            body["error"].as_str().unwrap().contains("A-Za-z0-9_-"),
            "{body}"
        );
        // The audit line must not carry the rejected id verbatim.
        let log = std::fs::read_to_string(sen.cfg.audit_file()).unwrap();
        assert!(log.contains("jobs/?/fire"), "{log}");
        assert!(!log.contains("jesse/models"), "{log}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
