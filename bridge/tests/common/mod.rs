//! Shared helpers for the integration (`app()` router) test target.
#![allow(dead_code)]
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use jesse_bridge::*;
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use tower::ServiceExt; // ServiceExt::oneshot

pub fn test_config() -> Config {
    Config {
        token: "test-token".to_string(),
        // Captured HOME for session-path lookups; tests that exercise session
        // paths override `home`/`vault` explicitly (no global-env mutation).
        home: std::env::var("HOME").unwrap_or_default(),
        // Any existing directory works — most tests never reach run_claude.
        vault: std::env::temp_dir().to_string_lossy().into_owned(),
        bind: "127.0.0.1".to_string(),
        port: 8765,
        claude_bin: "claude".to_string(),
        timeout_secs: 1800,
        allowed_tools: DEFAULT_ALLOWED_TOOLS.to_string(),
        disallowed_tools: DEFAULT_DISALLOWED_TOOLS.to_string(),
        max_concurrency: 2,
        max_queued: DEFAULT_MAX_QUEUED,
        rate_per_min: 30,
        job_ttl_secs: 600,
        retrieval_grace_secs: 600,
        session_ttl_days: DEFAULT_SESSION_TTL_DAYS,
        // No on-disk persistence in tests by default — keeps cargo test off
        // the real $HOME. The persistence tests build a store with a temp dir.
        state_dir: None,
        max_attachments: DEFAULT_MAX_ATTACHMENTS,
        max_attachment_bytes: DEFAULT_MAX_ATTACHMENT_BYTES,
        max_attachments_total_bytes: DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
        scratch_dir: None,
        // No title-backend override in tests — ambient-backend behavior.
        title_backend: None,
        // No diet-extract backend override in tests — the pipeline is dormant
        // (kill switch), so the integration router exercises today's hosted path.
        diet_backend: None,
        diet_probation: true,
        // No vault-QA backend override in tests — the route is inert (kill switch),
        // so the integration router exercises today's hosted Ask path.
        vaultqa_backend: None,
        vaultqa_mcp_config: None,
        // Badge off in the fixture: the exact-`response` turn assertions predate it
        // (the shipped default is on; badge behavior is tested with it enabled).
        model_badge: false,
        // No metrics log and emergency OFF in the fixture — both dormant, matching
        // an unconfigured deploy (the both-unset byte-for-byte property).
        metrics_log: None,
        emergency_local: false,
        // Context carry OFF in the fixture (like the badge/emergency defaults): the
        // exact-`response`/`session_id` turn assertions predate it. Carry behavior is
        // covered by dedicated tests that enable it (the shipped default is ON).
        context_carry: false,
        // Shadow comparison disarmed in the fixture (kill switch): no backend triple,
        // so the integration router mirrors nothing and every path is byte-for-byte
        // today's. Tests that exercise shadow set `shadow_backend`/`shadow_log`.
        shadow_backend: None,
        shadow_sample_pct: 100,
        shadow_log: std::env::temp_dir()
            .join("jesse-shadow-itest.jsonl")
            .to_string_lossy()
            .into_owned(),
        shadow_timeout_secs: 120,
        // Generic default persona (owner "the user") — the fresh-clone identity.
        persona: Persona::default(),
        // Opus-only registry: the ambient default, so the integration router runs
        // byte-for-byte today's turn unless a test builds its own registry.
        model_registry: ModelRegistry::opus_only(),
    }
}
pub fn test_state() -> AppState {
    AppState::new(test_config())
}
pub async fn body_string(resp: axum::response::Response) -> String {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}
pub fn jesse_request(auth: Option<&str>, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
/// Fire `POST /jesse/cancel/{id}` with the given (optional) auth header.
pub fn cancel_request(auth: Option<&str>, job_id: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri(format!("/jesse/cancel/{job_id}"));
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
pub fn session_delete_request(auth: Option<&str>, session_id: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("DELETE")
        .uri(format!("/jesse/session/{session_id}"));
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
/// `POST /jesse/session/{id}/flags` with the given (optional) auth header and body.
pub fn session_flags_request(auth: Option<&str>, session_id: &str, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri(format!("/jesse/session/{session_id}/flags"))
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
/// `GET /jesse/models` with the given (optional) auth header.
pub fn models_request(auth: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method("GET").uri("/jesse/models");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
/// `POST /jesse/model` with the given (optional) auth header and body.
pub fn set_model_request(auth: Option<&str>, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse/model")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
/// `POST /jesse/model/{id}/writes` with the given (optional) auth header and body.
pub fn set_model_writes_request(auth: Option<&str>, id: &str, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri(format!("/jesse/model/{id}/writes"))
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
pub fn stream_request(auth: Option<&str>, job_id: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("GET")
        .uri(format!("/jesse/stream/{job_id}"));
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
pub fn device_request(auth: Option<&str>, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse/device")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
pub fn title_request(auth: Option<&str>, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse/title")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
/// `POST /jesse/meal-corrections` with the given (optional) auth header and v2 body.
pub fn meal_corrections_request(auth: Option<&str>, json: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/jesse/meal-corrections")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::from(json.to_string())).unwrap()
}
/// `GET /jesse/sessions` with optional auth, `?since=`, and `If-None-Match`.
pub fn sessions_request(
    auth: Option<&str>,
    since: Option<u64>,
    if_none_match: Option<&str>,
) -> Request<Body> {
    let uri = match since {
        Some(s) => format!("/jesse/sessions?since={s}"),
        None => "/jesse/sessions".to_string(),
    };
    let mut b = Request::builder().method("GET").uri(uri);
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    if let Some(inm) = if_none_match {
        b = b.header("if-none-match", inm);
    }
    b.body(Body::empty()).unwrap()
}
/// `GET /jesse/sessions/{id}` (transcript hydration) with optional auth and `?after=`.
pub fn hydrate_request(auth: Option<&str>, session_id: &str, after: Option<u64>) -> Request<Body> {
    let uri = match after {
        Some(a) => format!("/jesse/sessions/{session_id}?after={a}"),
        None => format!("/jesse/sessions/{session_id}"),
    };
    let mut b = Request::builder().method("GET").uri(uri);
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
pub fn diet_request(auth: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method("GET").uri("/jesse/diet");
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
/// `GET /jesse/diet?date=<date>` — the paged-history request.
pub fn diet_request_date(auth: Option<&str>, date: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("GET")
        .uri(format!("/jesse/diet?date={date}"));
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
/// Create a throwaway vault dir with `todo-list/` and `diet-logs/`
/// subdirectories and return its path. Caller writes fixture files into it and
/// removes it when done. Realistic-but-invented data only — never a copy of
/// the real personal vault.
pub fn make_diet_vault() -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("jesse-vault-{}", random_hex()));
    std::fs::create_dir_all(root.join("todo-list")).unwrap();
    std::fs::create_dir_all(root.join("diet-logs")).unwrap();
    root
}
pub fn write_vault_file(root: &std::path::Path, rel: &str, contents: &str) {
    std::fs::write(root.join(rel), contents).unwrap();
}
pub fn notify_request(auth: Option<&str>, job_id: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri(format!("/jesse/notify/{job_id}"));
    if let Some(a) = auth {
        b = b.header("authorization", a);
    }
    b.body(Body::empty()).unwrap()
}
pub async fn result_status(app_state: &AppState, job_id: &str) -> Value {
    let resp = app(app_state.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/jesse/result/{job_id}"))
                .header("authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    serde_json::from_str(&body_string(resp).await).unwrap()
}
pub fn write_fake_claude(script: &str) -> std::path::PathBuf {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    let n = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    // A pid+counter name keeps parallel test runs from colliding.
    let path =
        std::env::temp_dir().join(format!("jesse-fake-claude-{}-{}.sh", std::process::id(), n));
    let mut f = std::fs::File::create(&path).unwrap();
    f.write_all(script.as_bytes()).unwrap();
    let mut perms = f.metadata().unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).unwrap();
    path
}
pub fn pid_alive(pid: i32) -> bool {
    // `kill -0` probes for the process without signalling it.
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
/// A recording transport: captures every request and returns a fixed result.
/// `fail` simulates a transport error (`Err`); `status` overrides the returned
/// HTTP status (0 → 200), so a test can drive a 410 dead-token response.
#[derive(Clone, Default)]
pub struct MockApns {
    pub calls: Arc<Mutex<Vec<ApnsRequest>>>,
    pub fail: bool,
    pub status: u16,
}
impl ApnsTransport for MockApns {
    fn post(&self, req: ApnsRequest) -> Pin<Box<dyn Future<Output = Result<u16, String>> + Send>> {
        let calls = self.calls.clone();
        let fail = self.fail;
        let status = if self.status == 0 { 200 } else { self.status };
        Box::pin(async move {
            calls.lock_ok().push(req);
            if fail {
                Err("mock apns failure".to_string())
            } else {
                Ok(status)
            }
        })
    }
}
/// Generate a throwaway ES256 key in-process (no committed key material) and
/// wrap it in an `ApnsClient` over the given transport.
pub fn test_apns(transport: Arc<dyn ApnsTransport>) -> Arc<ApnsClient> {
    let rng = ring::rand::SystemRandom::new();
    let doc = ring::signature::EcdsaKeyPair::generate_pkcs8(
        &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        &rng,
    )
    .unwrap();
    Arc::new(ApnsClient {
        cfg: ApnsConfig {
            key_id: "KEYID12345".to_string(),
            team_id: "TEAMID6789".to_string(),
            topic: "com.tag1.Jesse".to_string(),
            host: "api.sandbox.push.apple.com".to_string(),
        },
        pkcs8_der: doc.as_ref().to_vec(),
        jwt_cache: Mutex::new(None),
        transport,
    })
}
/// A standalone base64 *encoder* used only by the tests, so the decoder is
/// exercised against an independent implementation rather than itself.
pub fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(T[(b0 >> 2) as usize] as char);
        out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 {
            T[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(b2 & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}
pub const PNG_BYTES: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
pub const JPEG_BYTES: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F'];
pub const PDF_BYTES: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";
pub const GIF_BYTES: &[u8] = b"GIF89a\x01\x00\x01\x00\x00\x00\x00";
pub const WEBP_BYTES: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";
pub const HEIC_BYTES: &[u8] = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00";
pub fn attachment_json(mime: &str, bytes: &[u8]) -> String {
    format!(
        r#"{{"filename":"x","mime":"{mime}","data_base64":"{}"}}"#,
        b64(bytes)
    )
}
