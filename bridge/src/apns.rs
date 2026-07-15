use crate::*;

// ---- Push notifications (APNs) — optional, off unless JESSE_APNS_* is set ---
//
// Disabled-by-default contract: with the JESSE_APNS_* vars unset, `AppState.apns`
// is `None` and every push path is a no-op, so the bridge behaves exactly as it
// did before. When configured, a backgrounded turn the phone flagged via
// `POST /jesse/notify/{job_id}` fires a single APNs alert when it completes, so
// the phone can wake and re-attach. A push failure is always logged and swallowed
// — it must never fail the turn or its stored result.

/// The registered APNs device token for the single user. One current token is
/// enough; a re-register overwrites it (idempotent upsert). Persisted to
/// `<state_dir>/device.json` (0600) so it survives a restart, mirroring the job
/// store. Only the token is written — never the bearer token or any other secret.
pub struct DeviceStore {
    token: Mutex<Option<String>>,
    path: Option<PathBuf>,
}

impl DeviceStore {
    pub fn new(path: Option<PathBuf>) -> Self {
        let token = path.as_deref().and_then(load_device_token);
        DeviceStore {
            token: Mutex::new(token),
            path,
        }
    }

    /// Idempotent upsert of the current device token (overwrites any prior one),
    /// persisting it when a state dir is configured.
    pub fn set(&self, token: String) {
        *self.token.lock_ok() = Some(token.clone());
        if let Some(path) = &self.path {
            persist_device_token(path, &token);
        }
    }

    /// Clear the stored device token and persist the cleared state (M4). Called
    /// when APNs reports the token is dead (HTTP 410): the phone must re-register
    /// before any further push, and a dead token must stop being retried on every
    /// completion. Persisting the cleared state means the token stays gone across
    /// a restart, too.
    pub fn clear(&self) {
        *self.token.lock_ok() = None;
        if let Some(path) = &self.path {
            persist_device_token(path, "");
        }
    }

    pub fn get(&self) -> Option<String> {
        self.token.lock_ok().clone()
    }
}

pub fn load_device_token(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("token")
        .and_then(|t| t.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

/// Write the device token atomically (temp + rename), 0600 — same discipline as
/// `persist_job`. Best-effort: a failure is logged, never fatal.
pub fn persist_device_token(path: &Path, token: &str) {
    let value = json!({ "v": 1, "token": token });
    let tmp = path.with_extension("json.tmp");
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist device token: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

/// Job ids the phone asked to be notified about on completion. A flag is consumed
/// (removed) only when a push is actually fired, so a still-running flagged job
/// keeps its flag until the real completion. In-memory only — a running job isn't
/// persisted, so a flag for one need not be either.
pub struct NotifyFlags {
    inner: Mutex<std::collections::HashSet<String>>,
}

impl NotifyFlags {
    pub fn new() -> Self {
        NotifyFlags {
            inner: Mutex::new(std::collections::HashSet::new()),
        }
    }
    pub fn insert(&self, id: &str) {
        self.inner.lock_ok().insert(id.to_string());
    }
    /// Remove the flag and report whether it was present. Atomic, so a concurrent
    /// completion and notify-endpoint can't both take it.
    pub fn take(&self, id: &str) -> bool {
        self.inner.lock_ok().remove(id)
    }
}

impl Default for NotifyFlags {
    fn default() -> Self {
        Self::new()
    }
}

/// Static APNs settings derived from the environment. The `.p8` key is loaded
/// separately (see `build_apns`) into `ApnsClient.pkcs8_der`.
#[derive(Clone)]
pub struct ApnsConfig {
    pub key_id: String,
    pub team_id: String,
    /// The app's bundle id, sent as `apns-topic`.
    pub topic: String,
    /// `api.push.apple.com` (production) or `api.sandbox.push.apple.com` (default).
    pub host: String,
}

impl ApnsConfig {
    /// Read the APNs settings from the environment. Returns `(key_path, cfg)` only
    /// when KEY_PATH, KEY_ID, TEAM_ID and TOPIC are all set; otherwise `None`
    /// (push disabled). A partial config logs a one-line warning so a typo isn't
    /// silent. `JESSE_APNS_ENV` selects the host and defaults to `sandbox`, since
    /// an Xcode "Run to device" build uses the development APS environment.
    pub fn from_env() -> Option<(String, ApnsConfig)> {
        let key_path = env_string("JESSE_APNS_KEY_PATH");
        let key_id = env_string("JESSE_APNS_KEY_ID");
        let team_id = env_string("JESSE_APNS_TEAM_ID");
        let topic = env_string("JESSE_APNS_TOPIC");
        match (key_path, key_id, team_id, topic) {
            (Some(kp), Some(ki), Some(ti), Some(tp)) => {
                let env = env_string("JESSE_APNS_ENV").unwrap_or_else(|| "sandbox".to_string());
                let host = match env.to_ascii_lowercase().as_str() {
                    "production" | "prod" => "api.push.apple.com",
                    _ => "api.sandbox.push.apple.com",
                }
                .to_string();
                Some((
                    kp,
                    ApnsConfig {
                        key_id: ki,
                        team_id: ti,
                        topic: tp,
                        host,
                    },
                ))
            }
            (kp, ki, ti, tp) => {
                if kp.is_some() || ki.is_some() || ti.is_some() || tp.is_some() {
                    eprintln!(
                        "warning: JESSE_APNS_* is partially set — push disabled. Set \
                         JESSE_APNS_KEY_PATH, JESSE_APNS_KEY_ID, JESSE_APNS_TEAM_ID and \
                         JESSE_APNS_TOPIC together."
                    );
                }
                None
            }
        }
    }
}

/// One APNs HTTP/2 request. Kept behind a trait so the completion→push logic is
/// unit-testable without hitting Apple (the real impl is reqwest; tests record).
pub struct ApnsRequest {
    pub host: String,
    /// `/3/device/<device-token>`.
    pub path: String,
    pub jwt: String,
    pub topic: String,
    pub payload: Vec<u8>,
}

/// The mockable seam for the actual network call. `Ok(status)` for ANY completed
/// HTTP exchange (the status code, 2xx or not — so the caller can distinguish a
/// 410 "dead token" from other failures, M4), `Err` only for a transport-level
/// failure (no HTTP response at all). The caller (`ApnsClient::push`) interprets
/// the status; a non-2xx is never silently dropped.
pub trait ApnsTransport: Send + Sync {
    fn post(&self, req: ApnsRequest) -> Pin<Box<dyn Future<Output = Result<u16, String>> + Send>>;
}

/// Production transport: an HTTP/2 POST to APNs over rustls.
pub struct ReqwestApns {
    client: reqwest::Client,
}

impl ApnsTransport for ReqwestApns {
    fn post(&self, req: ApnsRequest) -> Pin<Box<dyn Future<Output = Result<u16, String>> + Send>> {
        let client = self.client.clone();
        Box::pin(async move {
            let url = format!("https://{}{}", req.host, req.path);
            let resp = client
                .post(url)
                .header("authorization", format!("bearer {}", req.jwt))
                .header("apns-topic", req.topic)
                .header("apns-push-type", "alert")
                .header("content-type", "application/json")
                .body(req.payload)
                .send()
                .await
                .map_err(|e| format!("apns request error: {e}"))?;
            // Return the status for ANY completed response — including non-2xx —
            // so `push` can act on a 410 (dead token) vs a transient error.
            Ok(resp.status().as_u16())
        })
    }
}

/// Outcome of an APNs push attempt, as interpreted from the transport's status.
/// Lets the caller clear a dead token on `DeadToken` (410) while swallowing every
/// other failure (M4).
pub enum PushOutcome {
    /// 2xx — the alert was accepted by APNs.
    Sent,
    /// 410 — APNs reports the device token is no longer valid. Clear it.
    DeadToken,
    /// Any other non-2xx status or a transport error. Logged and swallowed; the
    /// token is left in place (the failure may be transient).
    Failed(String),
}

/// How long a minted APNs JWT is reused before re-signing. Apple accepts a token
/// for up to 60 minutes; refresh a little early.
pub const APNS_JWT_TTL: Duration = Duration::from_secs(50 * 60);

/// The configured APNs client: static settings, the ES256 signing key, a cached
/// JWT, and the (mockable) transport.
pub struct ApnsClient {
    pub cfg: ApnsConfig,
    /// PKCS#8 DER of the ES256 signing key (decoded from the `.p8` PEM at startup).
    pub pkcs8_der: Vec<u8>,
    /// Cached `(jwt, minted_at)`, reused for `APNS_JWT_TTL`.
    pub jwt_cache: Mutex<Option<(String, Instant)>>,
    pub transport: Arc<dyn ApnsTransport>,
}

impl ApnsClient {
    /// The current auth JWT, minting (and caching) a fresh one when the cache is
    /// empty or older than `APNS_JWT_TTL`.
    ///
    /// The check and the mint happen under a SINGLE lock acquisition, so two
    /// concurrent pushes can't both observe a miss, both mint, and both write
    /// (the old check-then-drop-then-mint-then-write TOCTOU — which, because
    /// ECDSA signatures are randomized, produced two *different* tokens and threw
    /// away a valid mint). The loser blocks on the lock, then finds the winner's
    /// fresh token already cached and returns it. Minting is a sub-millisecond
    /// CPU signature, so holding the (non-async) mutex across it is cheap.
    pub fn jwt(&self) -> Result<String, String> {
        let mut g = self.jwt_cache.lock_ok();
        if let Some((tok, at)) = g.as_ref() {
            if at.elapsed() < APNS_JWT_TTL {
                return Ok(tok.clone());
            }
        }
        let iat = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        let tok = mint_apns_jwt(&self.pkcs8_der, &self.cfg.key_id, &self.cfg.team_id, iat)?;
        *g = Some((tok.clone(), Instant::now()));
        Ok(tok)
    }

    /// Send a completion alert for `job_id` to `device_token`. Maps the APNs
    /// status to a `PushOutcome`: 2xx → `Sent`, 410 → `DeadToken` (caller clears
    /// the token), anything else (other non-2xx, JWT-mint failure, transport
    /// error) → `Failed` (swallowed). Never errors out of band.
    pub async fn push(&self, device_token: &str, job_id: &str) -> PushOutcome {
        let jwt = match self.jwt() {
            Ok(j) => j,
            Err(e) => return PushOutcome::Failed(format!("apns jwt: {e}")),
        };
        let req = ApnsRequest {
            host: self.cfg.host.clone(),
            path: format!("/3/device/{device_token}"),
            jwt,
            topic: self.cfg.topic.clone(),
            payload: build_apns_payload(job_id),
        };
        match self.transport.post(req).await {
            Ok(status) if (200..300).contains(&status) => PushOutcome::Sent,
            // 410 Gone — APNs's signal that the device token is permanently dead.
            Ok(410) => PushOutcome::DeadToken,
            Ok(status) => PushOutcome::Failed(format!("apns status {status}")),
            Err(e) => PushOutcome::Failed(e),
        }
    }
}

/// URL-safe base64 without padding — the JWS encoding for the JWT's three parts.
pub fn base64url_nopad(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[n as usize & 63] as char);
        }
    }
    out
}

/// Decode a PKCS#8 `.p8` PEM into its DER bytes: strip the `-----BEGIN/END-----`
/// armor, then base64-decode the body (reusing the bridge's whitespace-tolerant
/// decoder).
pub fn pkcs8_der_from_pem(pem: &str) -> Result<Vec<u8>, String> {
    let body: String = pem
        .lines()
        .filter(|l| !l.trim_start().starts_with("-----"))
        .collect();
    if body.trim().is_empty() {
        return Err("empty PEM body".to_string());
    }
    base64_decode(&body).map_err(|e| e.to_string())
}

/// Sign an APNs auth JWT (ES256): header `{alg:ES256, kid}`, claims `{iss, iat}`,
/// signed with the `.p8` key. ring's `_FIXED_` variant emits the raw R||S
/// signature JWS requires (not DER). Pure given (key, ids, iat) so it's testable.
pub fn mint_apns_jwt(
    pkcs8_der: &[u8],
    key_id: &str,
    team_id: &str,
    iat: u64,
) -> Result<String, String> {
    let header = json!({ "alg": "ES256", "kid": key_id });
    let claims = json!({ "iss": team_id, "iat": iat });
    let signing_input = format!(
        "{}.{}",
        base64url_nopad(header.to_string().as_bytes()),
        base64url_nopad(claims.to_string().as_bytes())
    );
    let rng = ring::rand::SystemRandom::new();
    let key = ring::signature::EcdsaKeyPair::from_pkcs8(
        &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        pkcs8_der,
        &rng,
    )
    .map_err(|_| "invalid APNs signing key (.p8)".to_string())?;
    let sig = key
        .sign(&rng, signing_input.as_bytes())
        .map_err(|_| "APNs JWT signing failed".to_string())?;
    Ok(format!("{signing_input}.{}", base64url_nopad(sig.as_ref())))
}

/// The APNs payload for a finished turn: a short alert plus the `job_id` so the
/// tap routes to the right thread and re-attaches.
pub fn build_apns_payload(job_id: &str) -> Vec<u8> {
    json!({
        "aps": {
            "alert": { "title": "Jesse", "body": "Jesse finished" },
            "sound": "default"
        },
        "job_id": job_id
    })
    .to_string()
    .into_bytes()
}

/// Whether a flagged, terminal job should fire a push: only a `Done` or `Failed`
/// turn (a `Cancelled` turn means the user is present and chose to stop). Pure.
pub fn job_state_is_pushable(state: &JobState) -> bool {
    matches!(state, JobState::Done { .. } | JobState::Failed { .. })
}

/// Fire a completion push iff this job is flagged "notify on complete", has
/// reached a pushable terminal state, push is configured, and a device token is
/// registered. The flag is consumed only when a push is actually attempted (so a
/// still-running flagged job keeps it for the real completion), and `take` is
/// atomic so a concurrent completion + notify-endpoint can't double-push.
///
/// Every failure — push not configured, no token, APNs 4xx/5xx, a bad key — is
/// logged and swallowed: a push must NEVER fail the turn or disturb its stored
/// result. Called both at job completion and from the notify endpoint (to close
/// the race where the turn finished before the flag arrived).
pub async fn notify_if_complete(
    apns: Option<&ApnsClient>,
    devices: &DeviceStore,
    notify: &NotifyFlags,
    jobs: &JobStore,
    job_id: &str,
) {
    let Some(apns) = apns else { return };
    match jobs.get(job_id) {
        Some(state) if job_state_is_pushable(&state) => {}
        _ => return, // running / cancelled / gone — nothing to push (yet)
    }
    if !notify.take(job_id) {
        return; // not flagged, or another path already pushed
    }
    let Some(token) = devices.get() else {
        eprintln!("push: job {job_id} flagged but no device registered — skipping");
        return;
    };
    match apns.push(&token, job_id).await {
        PushOutcome::Sent => eprintln!("push: completion alert sent for job {job_id}"),
        PushOutcome::DeadToken => {
            // APNs reports the token is dead (410). Clear it so it isn't retried
            // on every future completion; the phone must re-register (M4).
            devices.clear();
            eprintln!("push: device token rejected (410 dead) for job {job_id} — cleared");
        }
        PushOutcome::Failed(e) => {
            eprintln!("push: APNs send failed for job {job_id}: {e} — swallowed")
        }
    }
}

/// Construct the APNs client from the environment, or `None` when push is
/// disabled (vars unset) or the key can't be loaded. A bad key is logged and
/// disables push — never fatal, since push is best-effort and must not block
/// startup or change the no-APNs behavior.
pub fn build_apns() -> Option<Arc<ApnsClient>> {
    let (key_path, cfg) = ApnsConfig::from_env()?;
    let pem = match std::fs::read_to_string(&key_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!(
                "warning: could not read JESSE_APNS_KEY_PATH ({key_path}): {e} — push disabled"
            );
            return None;
        }
    };
    let der = match pkcs8_der_from_pem(&pem) {
        Ok(d) => d,
        Err(e) => {
            eprintln!(
                "warning: JESSE_APNS_KEY_PATH is not a valid PKCS#8 .p8 ({e}) — push disabled"
            );
            return None;
        }
    };
    // Validate the key parses as an ES256 signing key now, so a bad key surfaces
    // at startup rather than silently on the first push.
    let rng = ring::rand::SystemRandom::new();
    if ring::signature::EcdsaKeyPair::from_pkcs8(
        &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        &der,
        &rng,
    )
    .is_err()
    {
        eprintln!("warning: JESSE_APNS_KEY_PATH did not parse as an ES256 key — push disabled");
        return None;
    }
    let client = match reqwest::Client::builder().build() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("warning: could not build APNs HTTP client: {e} — push disabled");
            return None;
        }
    };
    eprintln!("APNs push enabled (host {}, topic {})", cfg.host, cfg.topic);
    Some(Arc::new(ApnsClient {
        cfg,
        pkcs8_der: der,
        jwt_cache: Mutex::new(None),
        transport: Arc::new(ReqwestApns { client }),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    /// A recording transport: captures every request and returns a fixed result.
    /// `fail` simulates a transport error (`Err`); `status` overrides the returned
    /// HTTP status (0 → 200), so a test can drive a 410 dead-token response.
    #[derive(Clone, Default)]
    struct MockApns {
        calls: Arc<Mutex<Vec<ApnsRequest>>>,
        fail: bool,
        status: u16,
    }
    impl ApnsTransport for MockApns {
        fn post(
            &self,
            req: ApnsRequest,
        ) -> Pin<Box<dyn Future<Output = Result<u16, String>> + Send>> {
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
    fn test_apns(transport: Arc<dyn ApnsTransport>) -> Arc<ApnsClient> {
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
    /// URL-safe-base64 (no pad) decode, for inspecting a minted JWT's parts.
    fn b64url_decode(s: &str) -> Vec<u8> {
        let mut t = s.replace('-', "+").replace('_', "/");
        while !t.len().is_multiple_of(4) {
            t.push('=');
        }
        base64_decode(&t).unwrap()
    }
    #[test]
    fn apns_jwt_header_claims_and_signature_shape() {
        let rng = ring::rand::SystemRandom::new();
        let doc = ring::signature::EcdsaKeyPair::generate_pkcs8(
            &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &rng,
        )
        .unwrap();
        let der = doc.as_ref();
        let jwt = mint_apns_jwt(der, "ABC123DEFG", "TEAMID1234", 1_700_000_000).unwrap();

        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "a JWT is header.claims.signature");

        let header: Value = serde_json::from_slice(&b64url_decode(parts[0])).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "ABC123DEFG");

        let claims: Value = serde_json::from_slice(&b64url_decode(parts[1])).unwrap();
        assert_eq!(claims["iss"], "TEAMID1234");
        assert_eq!(claims["iat"], 1_700_000_000);

        // ES256 over P-256 is a fixed 64-byte R||S signature (what JWS requires).
        let sig = b64url_decode(parts[2]);
        assert_eq!(sig.len(), 64);

        // And it actually verifies against the key's public half.
        let keypair = ring::signature::EcdsaKeyPair::from_pkcs8(
            &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            der,
            &rng,
        )
        .unwrap();
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        use ring::signature::KeyPair as _; // brings `public_key()` into scope
        ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            keypair.public_key().as_ref(),
        )
        .verify(signing_input.as_bytes(), &sig)
        .expect("minted JWT must verify under its own public key");
    }
    #[test]
    fn apns_payload_has_alert_and_job_id() {
        let payload = build_apns_payload("job-xyz");
        let v: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(v["aps"]["alert"]["title"], "Jesse");
        assert_eq!(v["aps"]["alert"]["body"], "Jesse finished");
        assert_eq!(v["aps"]["sound"], "default");
        assert_eq!(v["job_id"], "job-xyz");
    }
    #[test]
    fn pushable_only_for_done_or_failed() {
        assert!(job_state_is_pushable(&JobState::Done {
            response: "x".into(),
            session_id: None,
            directives: None,
            provenance: None
        }));
        assert!(job_state_is_pushable(&JobState::Failed {
            error: "x".into()
        }));
        assert!(!job_state_is_pushable(&JobState::Cancelled));
        assert!(!job_state_is_pushable(&JobState::Running));
    }
    #[tokio::test]
    async fn completed_flagged_with_token_pushes() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("abc123devicetoken".to_string());

        let id = st.jobs.create();
        st.jobs.complete(
            &id,
            Ok(("the answer".to_string(), Some("sess-1".to_string()), None)),
        );
        st.notify.insert(&id);

        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        let calls = mock.calls.lock_ok();
        assert_eq!(calls.len(), 1, "a flagged, completed turn pushes once");
        let req = &calls[0];
        assert!(
            req.path.contains("abc123devicetoken"),
            "path targets the token"
        );
        assert_eq!(req.topic, "com.tag1.Jesse");
        assert_eq!(req.jwt.split('.').count(), 3, "carries a JWT");
        assert!(
            String::from_utf8_lossy(&req.payload).contains(&id),
            "payload carries job_id"
        );
    }
    #[tokio::test]
    async fn completed_but_not_flagged_does_not_push() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("abc123devicetoken".to_string());

        let id = st.jobs.create();
        st.jobs
            .complete(&id, Ok(("the answer".to_string(), None, None)));
        // No notify.insert — the turn finished in the foreground.

        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        assert_eq!(mock.calls.lock_ok().len(), 0, "unflagged turn never pushes");
    }
    #[tokio::test]
    async fn flagged_but_no_token_does_not_push() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        // No device registered.
        let id = st.jobs.create();
        st.jobs.complete(&id, Ok(("a".to_string(), None, None)));
        st.notify.insert(&id);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        assert_eq!(mock.calls.lock_ok().len(), 0, "no token → no push");
    }
    #[tokio::test]
    async fn cancelled_flagged_job_does_not_push() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("tok".to_string());
        let id = st.jobs.create();
        st.jobs.stream_register(&id);
        assert!(matches!(st.jobs.cancel(&id), CancelOutcome::Cancelled));
        st.notify.insert(&id);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        assert_eq!(
            mock.calls.lock_ok().len(),
            0,
            "a cancelled turn isn't pushed"
        );
    }
    #[tokio::test]
    async fn push_failure_does_not_disturb_stored_result() {
        // The mock fails the send; the job result must be untouched and the flag
        // consumed (so it can't push twice). A push problem never breaks a turn.
        let mock = MockApns {
            fail: true,
            ..Default::default()
        };
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("tok".to_string());

        let id = st.jobs.create();
        st.jobs.complete(
            &id,
            Ok((
                "durable answer".to_string(),
                Some("sess-9".to_string()),
                None,
            )),
        );
        st.notify.insert(&id);

        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        assert_eq!(mock.calls.lock_ok().len(), 1, "the send was attempted");
        match st.jobs.get(&id) {
            Some(JobState::Done {
                response,
                session_id,
                ..
            }) => {
                assert_eq!(
                    response, "durable answer",
                    "result intact after a push failure"
                );
                assert_eq!(session_id.as_deref(), Some("sess-9"));
            }
            other => panic!("job must stay Done, got {:?}", other.map(|_| ())),
        }
    }
    #[tokio::test]
    async fn push_disabled_is_a_noop() {
        // apns = None (the default): even a flagged, token-present completion does
        // nothing — the bridge behaves exactly as before push existed.
        let st = test_state();
        assert!(st.apns.is_none());
        st.devices.set("tok".to_string());
        let id = st.jobs.create();
        st.jobs.complete(&id, Ok(("a".to_string(), None, None)));
        st.notify.insert(&id);
        // Just must not panic; there's no transport to record against.
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        // The flag is left intact (nothing consumed it) — harmless.
        assert!(st.notify.take(&id));
    }
    #[tokio::test]
    async fn notify_running_then_completion_pushes_once() {
        // The normal sequence: phone flags a still-running job (no push yet, flag
        // retained), the turn later completes and the completion path pushes once.
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("tok".to_string());

        let id = st.jobs.create(); // Running
        st.notify.insert(&id);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        assert_eq!(
            mock.calls.lock_ok().len(),
            0,
            "a running job isn't pushed yet"
        );

        st.jobs
            .complete(&id, Ok(("done now".to_string(), None, None)));
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;
        assert_eq!(
            mock.calls.lock_ok().len(),
            1,
            "completion pushes exactly once"
        );
    }
    #[test]
    fn device_token_survives_restart() {
        let dir = temp_jobs_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("device.json");
        {
            let store = DeviceStore::new(Some(path.clone()));
            store.set("persisted-token".to_string());
        }
        let restarted = DeviceStore::new(Some(path.clone()));
        assert_eq!(restarted.get().as_deref(), Some("persisted-token"));
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[tokio::test]
    async fn dead_token_410_is_cleared() {
        let mock = MockApns {
            status: 410,
            ..Default::default()
        };
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("deadtoken".to_string());

        let id = st.jobs.create();
        st.jobs.complete(&id, Ok(("x".into(), None, None)));
        st.notify.insert(&id);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        assert_eq!(mock.calls.lock_ok().len(), 1, "the push was attempted");
        assert!(
            st.devices.get().is_none(),
            "a 410 must clear the dead device token so it isn't retried forever"
        );
    }
    #[tokio::test]
    async fn non_410_push_error_keeps_token() {
        let mock = MockApns {
            status: 503,
            ..Default::default()
        };
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("livetoken".to_string());

        let id = st.jobs.create();
        st.jobs.complete(&id, Ok(("x".into(), None, None)));
        st.notify.insert(&id);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        assert_eq!(
            st.devices.get().as_deref(),
            Some("livetoken"),
            "a transient (non-410) failure must NOT clear the token"
        );
    }
    #[test]
    fn device_clear_persists_across_restart() {
        let dir = temp_jobs_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("device.json");
        let store = DeviceStore::new(Some(path.clone()));
        store.set("tok".to_string());
        store.clear();
        assert!(store.get().is_none(), "clear empties the in-memory token");
        let restarted = DeviceStore::new(Some(path.clone()));
        assert!(
            restarted.get().is_none(),
            "the cleared token stays cleared across a restart"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn concurrent_jwt_mints_a_single_token() {
        // Race many callers against a cold cache. The single-lock check-and-mint
        // means exactly one thread mints and every other returns that same cached
        // token — so the set of returned tokens has size one. Under the old
        // check-then-drop-then-mint TOCTOU, two callers could each mint, and
        // because ECDSA signatures are randomized those tokens differ, so the set
        // would contain more than one value.
        let client = test_apns(Arc::new(MockApns::default()));
        let mut handles = Vec::new();
        for _ in 0..8 {
            let c = client.clone();
            handles.push(std::thread::spawn(move || c.jwt().unwrap()));
        }
        let toks: Vec<String> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        assert!(
            toks.windows(2).all(|w| w[0] == w[1]),
            "all concurrent jwt() callers must return one token, got distinct values: {toks:?}"
        );
    }

    #[test]
    fn apns_jwt_signature_rejects_tampering() {
        // The positive case (a minted JWT verifies under its own public key) is in
        // `apns_jwt_header_claims_and_signature_shape`. Here the complementary
        // check: tampering with either the signature or the signed payload must
        // make ring's ES256 verify FAIL — proving that test verifies for real, not
        // vacuously.
        let rng = ring::rand::SystemRandom::new();
        let doc = ring::signature::EcdsaKeyPair::generate_pkcs8(
            &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &rng,
        )
        .unwrap();
        let der = doc.as_ref();
        let jwt = mint_apns_jwt(der, "KEYID12345", "TEAMID6789", 1_700_000_000).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();

        let keypair = ring::signature::EcdsaKeyPair::from_pkcs8(
            &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            der,
            &rng,
        )
        .unwrap();
        use ring::signature::KeyPair as _;
        let pubkey = ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            keypair.public_key().as_ref(),
        );
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let good_sig = b64url_decode(parts[2]);

        // Sanity: the untampered signature verifies.
        assert!(pubkey.verify(signing_input.as_bytes(), &good_sig).is_ok());

        // Flip one bit of the signature → verification fails.
        let mut bad_sig = good_sig.clone();
        bad_sig[0] ^= 0x01;
        assert!(
            pubkey.verify(signing_input.as_bytes(), &bad_sig).is_err(),
            "a tampered signature must not verify"
        );

        // Tamper the signed payload → the original signature no longer matches.
        let tampered_input = format!("{signing_input}TAMPER");
        assert!(
            pubkey.verify(tampered_input.as_bytes(), &good_sig).is_err(),
            "a tampered payload must not verify under the original signature"
        );
    }
}
