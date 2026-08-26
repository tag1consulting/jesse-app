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
///
/// The temp file name is unique per write (pid + a process-wide counter), NOT a
/// fixed `device.json.tmp`. A shared temp path makes concurrent writers collide:
/// the phone re-registers on foreground, so two `POST /jesse/device` calls can
/// overlap, and with one temp path the loser's rename finds nothing (a spurious
/// ENOENT warning) while its still-open fd writes into the file the winner just
/// renamed into place — defeating the atomicity this function exists to provide.
/// Unique temp names give each writer its own file, so both renames are atomic
/// and the last one simply wins.
pub fn persist_device_token(path: &Path, token: &str) {
    if let Err(e) = try_persist_device_token(path, token) {
        eprintln!("warning: could not persist device token: {e}");
    }
}

/// The fallible body of [`persist_device_token`]. Separate so a test can assert the
/// no-collision contract directly: under concurrency EVERY write must succeed, which
/// is exactly what the shared temp path broke.
fn try_persist_device_token(path: &Path, token: &str) -> std::io::Result<()> {
    static WRITE_SEQ: AtomicU64 = AtomicU64::new(0);
    let value = json!({ "v": 1, "token": token });
    let seq = WRITE_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.tmp.{}.{seq}", std::process::id()));
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
    write().inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
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
                // Priority 10 = "deliver immediately". Every push this bridge sends is an
                // alert about something that has ALREADY happened — a turn that finished, a
                // scheduled run that failed — so there is nothing to gain from APNs holding
                // it back, and the `content-available` flag inside each payload is only
                // worth carrying if it arrives while the phone still cares.
                .header("apns-priority", "10")
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
    pub async fn push(
        &self,
        device_token: &str,
        job_id: &str,
        conversation_id: Option<&str>,
        artifacts: &[Artifact],
        summary: PushSummary<'_>,
    ) -> PushOutcome {
        self.push_payload(
            device_token,
            build_apns_payload(job_id, conversation_id, artifacts, summary),
        )
        .await
    }

    /// Send an already-built payload. The seam [`push`](Self::push) is written in terms
    /// of, so the scheduler's alert — which must NAME the job and its outcome, and may
    /// have no turn to deep-link to at all (a skipped run) — travels the identical
    /// client, JWT cache, topic and status interpretation rather than a second push path.
    pub async fn push_payload(&self, device_token: &str, payload: Vec<u8>) -> PushOutcome {
        let jwt = match self.jwt() {
            Ok(j) => j,
            Err(e) => return PushOutcome::Failed(format!("apns jwt: {e}")),
        };
        let req = ApnsRequest {
            host: self.cfg.host.clone(),
            path: format!("/3/device/{device_token}"),
            jwt,
            topic: self.cfg.topic.clone(),
            payload,
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

/// The APNs payload for a finished turn: a short alert plus the ids the tap routes on.
///
/// TWO routing keys, because `job_id` alone cannot answer the question. The app resolves
/// it through its in-flight map — the turns THIS DEVICE started and has not yet settled —
/// so a scheduled job (which the phone never started) and an already-settled turn (whose
/// entry the background delivery removed the moment it wrote the reply) both fall off the
/// end of it. `conversation_id` names the conversation itself, which the app can fetch,
/// or adopt from the bridge if it has never seen it.
///
/// It is additive and OMITTED when unknown, so an app build that predates it reads the
/// payload exactly as it always did.
///
/// It also carries `content-available: 1`, which is what lets the
/// phone fetch the reply while it is still in a pocket instead of only when the app is
/// next opened. The alert is unchanged by it: an alert push with `content-available: 1`
/// is still shown, and additionally wakes the app for a bounded background fetch.
///
/// A turn that returned files gets a compact `[2 files]` suffix rather than a list of
/// names: the summary is what the notification is FOR, and the names were only ever
/// standing in for it. The names survive in the fallback below, where there is no summary
/// to spend the space on.
///
/// The body is model-authored text landing on a lock screen, so it is sanitized rather
/// than interpolated — see [`push_summary_snippet`].
pub fn build_apns_payload(
    job_id: &str,
    conversation_id: Option<&str>,
    artifacts: &[Artifact],
    summary: PushSummary<'_>,
) -> Vec<u8> {
    let mut payload = json!({
        "aps": {
            "alert": { "title": "Jesse", "body": completion_body(summary, artifacts) },
            "sound": "default",
            "content-available": 1
        },
        "job_id": job_id
    });
    if let Some(cid) = conversation_id {
        payload["conversation_id"] = json!(cid);
    }
    payload.to_string().into_bytes()
}

/// What a completion push has to say about the turn it is reporting on: the reply the
/// person would have read, or the error that stopped it. Borrowed and `Copy` — the text
/// is already owned by the terminal job state this is read from.
#[derive(Clone, Copy)]
pub enum PushSummary<'a> {
    /// The RAW reply text off `JobState::Done`. Raw and not delivered on purpose: this
    /// type is the seam, and [`completion_body`] runs it through `delivered_text` so the
    /// notification and the chat bubble can never disagree about what the reply was.
    Reply(&'a str),
    /// The error off `JobState::Failed`.
    Failure(&'a str),
}

/// The alert body for a terminal turn: what it said, in its own words.
///
/// Two invariants, in this order:
///
/// 1. **Never blank.** A summary that sanitizes away to nothing (a reply that was one
///    code fence, an empty error) falls back to the artifact line this used to always
///    emit, so the worst case is exactly the old behaviour rather than a bodyless alert.
/// 2. **Never wrong about the outcome.** A failure says so first, and its blank-summary
///    fallback is "Jesse failed" and not the artifact line — "Jesse finished" on a turn
///    that failed is worse than useless, which is the same reason the scheduler's alert
///    always names its reason.
fn completion_body(summary: PushSummary<'_>, artifacts: &[Artifact]) -> String {
    let (text, prefix) = match summary {
        PushSummary::Reply(raw) => (delivered_text(raw), ""),
        PushSummary::Failure(error) => (error.to_string(), "Failed: "),
    };
    let snippet = push_summary_snippet(&text);
    if snippet.is_empty() {
        return match summary {
            PushSummary::Reply(_) => push_body(artifacts),
            PushSummary::Failure(_) => "Jesse failed".to_string(),
        };
    }
    format!("{prefix}{snippet}{}", artifact_suffix(artifacts))
}

/// How many returned filenames one alert names before it says "and N more".
pub const MAX_PUSH_ARTIFACT_NAMES: usize = 3;

/// Longest summary text carried into an alert body, matching [`MAX_PUSH_REASON_CHARS`]:
/// a lock screen shows two to four lines whatever is sent, and the tap opens the full
/// reply anyway.
pub const MAX_PUSH_SUMMARY_CHARS: usize = 180;

/// Turn model-authored text into ONE lock-screen line.
///
/// Four transformations, and the order between the first two matters:
///
/// * **Whitespace to spaces, then control characters dropped.** A newline is a word
///   break before it is a control character; filtering first would weld `"one\ntwo"`
///   into `"onetwo"`. Everything else non-printing goes, for the same reason the
///   artifact-name path has always stripped it — this string is the MODEL's and it
///   reaches a notification.
/// * **Whitespace runs collapsed**, so a wrapped paragraph reads as a sentence.
/// * **Leading Markdown decoration removed**, so a reply that opens `## Done` does not
///   put `##` on the lock screen.
/// * **Truncated on a word boundary** with an ellipsis, never mid-word.
///
/// Returns an empty string when nothing survives; callers must have a fallback.
pub fn push_summary_snippet(text: &str) -> String {
    let flattened: String = text
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .filter(|c| !c.is_control())
        .collect();
    let collapsed = flattened.split_whitespace().collect::<Vec<_>>().join(" ");
    let stripped = strip_leading_markdown(&collapsed);
    truncate_on_word_boundary(stripped, MAX_PUSH_SUMMARY_CHARS)
}

/// Drop the Markdown decoration a reply OPENS with — headings, fences, blockquote
/// markers, bullets, thematic breaks — repeatedly, since `"> ## Done"` is all three.
fn strip_leading_markdown(s: &str) -> &str {
    let mut rest = s.trim_start();
    while let Some(next) = strip_one_marker(rest) {
        let next = next.trim_start();
        if next.len() == rest.len() {
            break; // no progress — stop rather than spin
        }
        rest = next;
    }
    rest
}

/// One marker off the front, or `None` when the text does not open with one.
///
/// `-` and `*` are deliberately conditional: a bullet is followed by whitespace and a
/// thematic break is three or more, but `-5°C overnight` opens with a minus sign and
/// must keep it. Emphasis (`**Done**`) is left alone on purpose — stripping the opening
/// pair would leave the closing one dangling, which reads worse than both.
fn strip_one_marker(rest: &str) -> Option<&str> {
    let first = rest.chars().next()?;
    match first {
        // A run of these is decoration whatever follows it.
        '#' | '`' => Some(rest.trim_start_matches(first)),
        '>' => Some(&rest[1..]),
        '-' | '*' | '+' | '_' => {
            let run = rest.chars().take_while(|c| *c == first).count();
            let after = &rest[run..];
            let is_break = run >= 3;
            let is_bullet = run == 1 && (after.is_empty() || after.starts_with(' '));
            (is_break || is_bullet).then_some(after)
        }
        _ => None,
    }
}

/// Cut to at most `max` characters on a word boundary, appending an ellipsis. The
/// ellipsis is inside the budget, so the result never exceeds `max`. A single word
/// longer than the budget is cut mid-word — there is no boundary to find.
fn truncate_on_word_boundary(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let head: String = s.chars().take(max.saturating_sub(1)).collect();
    // `' '` is ASCII, so this byte index is always a char boundary.
    let cut = match head.rfind(' ') {
        Some(i) if i > 0 => &head[..i],
        _ => head.as_str(),
    };
    format!("{}…", cut.trim_end())
}

/// The compact file count appended to a summary: ` [1 file]`, ` [3 files]`, or nothing.
/// A count and not a list — the summary earns the space the names used to take.
fn artifact_suffix(artifacts: &[Artifact]) -> String {
    match artifacts.len() {
        0 => String::new(),
        1 => " [1 file]".to_string(),
        n => format!(" [{n} files]"),
    }
}

/// The alert body when there is no usable summary: the pre-summary behaviour, verbatim.
/// A push must never regress to blank, so this stays as the floor under
/// [`completion_body`] rather than being replaced by it.
fn push_body(artifacts: &[Artifact]) -> String {
    if artifacts.is_empty() {
        return "Jesse finished".to_string();
    }
    let names: Vec<String> = artifacts
        .iter()
        .take(MAX_PUSH_ARTIFACT_NAMES)
        .map(|a| {
            a.filename
                .chars()
                .filter(|c| !c.is_control())
                .take(60)
                .collect::<String>()
        })
        .filter(|n| !n.trim().is_empty())
        .collect();
    if names.is_empty() {
        return "Jesse finished".to_string();
    }
    let extra = artifacts.len().saturating_sub(names.len());
    if extra > 0 {
        format!("Jesse finished — {} and {extra} more", names.join(", "))
    } else {
        format!("Jesse finished — {}", names.join(", "))
    }
}

/// Longest reason text carried into a scheduled-run alert. APNs caps the payload at 4KB
/// and a lock-screen alert shows far less; a reason is a sentence, not a stack trace.
pub const MAX_PUSH_REASON_CHARS: usize = 180;

/// The snapshot documents a `prefetch` push asks the phone to refresh: the day file
/// (`GET /jesse/today`) and the diet snapshot (`GET /jesse/diet`). Named here, in the one
/// place the wire value is written, rather than spelled out at each use.
pub const PREFETCH_SNAPSHOTS: [&str; 2] = ["today", "diet"];

/// The default `JESSE_PUSH_PREFETCH_JOBS` list: the morning chain, which is the run that
/// rewrites the day file in full. Waking to a day the bridge rebuilt an hour ago is the
/// case this exists for.
pub const DEFAULT_PUSH_PREFETCH_JOBS: &str = "morning-start-of-day";

/// The schedule ids whose outcome push asks the phone to refresh its cached snapshots,
/// from `JESSE_PUSH_PREFETCH_JOBS` (comma list). Unset — the default — is the morning
/// chain alone; an explicitly blank value is a list of nothing, which turns the prefetch
/// hint off without turning the push off.
pub fn push_prefetch_jobs() -> Vec<String> {
    match std::env::var("JESSE_PUSH_PREFETCH_JOBS") {
        // An explicitly-set value is honoured verbatim, INCLUDING a blank one — that is
        // how the hint is disabled. `env_string` cannot express this: it folds a blank
        // value back to `None`, which here would mean "the default", the opposite.
        Ok(spec) => parse_prefetch_jobs(&spec),
        Err(_) => parse_prefetch_jobs(DEFAULT_PUSH_PREFETCH_JOBS),
    }
}

/// Parse the comma list. Items are trimmed and blanks dropped, so `"a,,b "` is `[a, b]`
/// and `""` is empty. Pure, so the matching rule is tested without the environment.
pub fn parse_prefetch_jobs(spec: &str) -> Vec<String> {
    spec.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Whether this schedule id's outcome push carries the prefetch hint. An exact match on
/// the id — never a prefix or a substring, because a schedule id is a name the operator
/// writes and `morning-start-of-day-dry-run` is a different job.
pub fn wants_prefetch(schedule_id: &str, jobs: &[String]) -> bool {
    jobs.iter().any(|j| j == schedule_id)
}

/// The APNs payload for a `[[schedule]]` run: the job's id and what happened to it, plus
/// the turn's `job_id` WHEN THERE IS ONE so the tap opens the finished turn exactly as a
/// completion push does. A skipped run has no turn, so it carries the alert alone.
///
/// The body always names the outcome, and a failure or skip always names its reason —
/// "Jesse finished" would be worse than useless for the failure this feature exists to
/// make visible. A CLEAN run has no reason to name, and for that case `summary` carries
/// what the turn actually reported: the body becomes the sanitized reply and the id and
/// outcome move into the title, so the morning chain says what it found rather than only
/// that it happened.
///
/// `prefetch` adds a top-level `prefetch` array naming the snapshots the phone should
/// refresh on arrival (see [`PREFETCH_SNAPSHOTS`]). It is a HINT and nothing more: the
/// push is identical without it, and a phone that does not understand the key ignores it.
/// It rides the outcome push rather than a second push because the run that rewrote the
/// day file is exactly the run whose completion the phone is already being told about.
pub fn build_scheduled_payload(
    schedule_id: &str,
    outcome: &str,
    reason: &str,
    job_id: Option<&str>,
    conversation_id: Option<&str>,
    prefetch: bool,
    summary: Option<&str>,
) -> Vec<u8> {
    let reason: String = reason.trim().chars().take(MAX_PUSH_REASON_CHARS).collect();
    // A REASON OUTRANKS THE SUMMARY, and it is only ever set on a run that failed, was
    // skipped, or produced no output. Those alerts exist to make the reason visible; the
    // summary would bury it under whatever the turn happened to say on its way down.
    // With no reason — a clean `ran`, which is the case worth reading — the summary
    // becomes the body and the id + outcome move up into the title.
    let snippet = match summary.filter(|_| reason.is_empty()) {
        Some(raw) => push_summary_snippet(&delivered_text(raw)),
        None => String::new(),
    };
    let (title, body) = if snippet.is_empty() {
        let body = if reason.is_empty() {
            format!("{schedule_id} {outcome}")
        } else {
            format!("{schedule_id} {outcome} — {reason}")
        };
        ("Jesse schedule".to_string(), body)
    } else {
        (format!("{schedule_id} {outcome}"), snippet)
    };
    let mut payload = json!({
        "aps": {
            "alert": { "title": title, "body": body },
            "sound": "default",
            "content-available": 1
        },
        "schedule_id": schedule_id,
        "outcome": outcome,
    });
    if let Some(id) = job_id {
        payload["job_id"] = json!(id);
    }
    // THE ONE ROUTING KEY THAT CAN WORK HERE. A scheduled turn is one the phone never
    // started, so it has no in-flight entry for its `job_id` and never will; naming the
    // conversation is what lets the tap open the run's own thread, adopting it first if
    // the phone has never seen it. Absent on a skipped run, which had no turn at all.
    if let Some(cid) = conversation_id {
        payload["conversation_id"] = json!(cid);
    }
    if prefetch {
        payload["prefetch"] = json!(PREFETCH_SNAPSHOTS);
    }
    payload.to_string().into_bytes()
}

/// The CONSECUTIVE-FAILURE escalation payload: "this is the third night running", which is
/// a different statement from "last night failed" and the one that gets acted on.
pub fn build_escalation_payload(schedule_id: &str, streak: u32, reason: &str) -> Vec<u8> {
    let reason: String = reason.trim().chars().take(MAX_PUSH_REASON_CHARS).collect();
    let body = if reason.is_empty() {
        format!("{schedule_id} failed {streak} times running")
    } else {
        format!("{schedule_id} failed {streak} times running, last: {reason}")
    };
    json!({
        "aps": {
            "alert": { "title": "Jesse schedule", "body": body },
            "sound": "default",
            "content-available": 1
        },
        "schedule_id": schedule_id,
        "outcome": "escalation",
        "consecutive_failures": streak,
    })
    .to_string()
    .into_bytes()
}

/// The CONFIG RELOAD FAILURE payload. The old schedule keeps running — which is the safe
/// behaviour and also the completely silent one, so this is the only thing that says the
/// file someone just edited is not the file the bridge is using.
pub fn build_reload_failure_payload(error: &str) -> Vec<u8> {
    let error: String = error.trim().chars().take(MAX_PUSH_REASON_CHARS).collect();
    json!({
        "aps": {
            "alert": {
                "title": "Jesse schedule",
                "body": format!("config reload failed: {error}")
            },
            "sound": "default",
            "content-available": 1
        },
        "outcome": "reload-failed",
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
    // WHAT THE TURN SAID, and the files it returned. Both read from the same terminal
    // state the pushability check reads, so the alert can never describe a different
    // state than the one that made it pushable. The reply text was always here — it is
    // carried on `Done` beside the artifacts — and was simply not being read.
    let (artifacts, text) = match jobs.get(job_id) {
        Some(state) if job_state_is_pushable(&state) => match state {
            JobState::Done {
                artifacts,
                response,
                ..
            } => (artifacts, Ok(response)),
            JobState::Failed { error, .. } => (Vec::new(), Err(error)),
            _ => (Vec::new(), Ok(String::new())),
        },
        _ => return, // running / cancelled / gone — nothing to push (yet)
    };
    let summary = match &text {
        Ok(response) => PushSummary::Reply(response),
        Err(error) => PushSummary::Failure(error),
    };
    // THE CONVERSATION THE TAP OPENS. Read off the JOB, not the in-flight conversation
    // table — that table's entry is released when the turn ends, which is exactly when
    // this runs. Reading it here rather than taking it as an argument is what lets BOTH
    // call sites carry it: the completion path and the notify endpoint, which is handed
    // nothing but a job id.
    let conversation_id = jobs.conversation_id(job_id);
    if !notify.take(job_id) {
        return; // not flagged, or another path already pushed
    }
    let Some(token) = devices.get() else {
        eprintln!("push: job {job_id} flagged but no device registered — skipping");
        return;
    };
    match apns
        .push(
            &token,
            job_id,
            conversation_id.as_deref(),
            &artifacts,
            summary,
        )
        .await
    {
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
    /// A body helper for the tests below: what the lock screen would show.
    fn body_of(payload: &[u8]) -> String {
        let v: Value = serde_json::from_slice(payload).unwrap();
        v["aps"]["alert"]["body"].as_str().unwrap().to_string()
    }
    #[test]
    fn apns_payload_has_alert_and_job_id() {
        let payload = build_apns_payload("job-xyz", None, &[], PushSummary::Reply(""));
        let v: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(v["aps"]["alert"]["title"], "Jesse");
        assert_eq!(v["aps"]["alert"]["body"], "Jesse finished");
        assert_eq!(v["aps"]["sound"], "default");
        assert_eq!(v["job_id"], "job-xyz");
    }

    /// THE POINT OF THE FEATURE: the body is what the turn said, not a fixed string.
    #[test]
    fn body_is_the_reply_not_a_fixed_string() {
        let body = body_of(&build_apns_payload(
            "j",
            None,
            &[],
            PushSummary::Reply("Rebooted the router; the study is back on the network."),
        ));
        assert_eq!(
            body,
            "Rebooted the router; the study is back on the network."
        );
        assert!(!body.starts_with("Jesse finished"));
    }

    /// A multi-line reply becomes ONE line, and a newline is a word break before it is a
    /// control character — collapsing it away would weld two words together.
    #[test]
    fn a_multi_line_reply_collapses_to_one_line() {
        let body = body_of(&build_apns_payload(
            "j",
            None,
            &[],
            PushSummary::Reply("Checked the vault.\n\nThree notes\tneed   titles."),
        ));
        assert_eq!(body, "Checked the vault. Three notes need titles.");
        assert!(!body.contains('\n') && !body.contains('\r'));
    }

    /// Model-authored text reaching a lock screen is stripped of control characters, the
    /// same rule the artifact-name path has always applied and for the same reason.
    #[test]
    fn control_characters_are_stripped_from_the_summary() {
        let body = body_of(&build_apns_payload(
            "j",
            None,
            &[],
            PushSummary::Reply("done\u{7}\u{0}: all\u{1b}[31m clear"),
        ));
        assert_eq!(body, "done: all[31m clear");
        assert!(!body.chars().any(|c| c.is_control()), "{body:?}");
    }

    /// A reply that OPENS with Markdown decoration does not put it on the lock screen.
    #[test]
    fn leading_markdown_decoration_is_stripped() {
        let cases = [
            (
                "## Done\n\nThe backup finished.",
                "Done The backup finished.",
            ),
            ("> ### Summary: two files", "Summary: two files"),
            ("- fixed the sync bug", "fixed the sync bug"),
            ("```\nls -la\n```", "ls -la ```"),
        ];
        for (raw, want) in cases {
            assert_eq!(
                body_of(&build_apns_payload("j", None, &[], PushSummary::Reply(raw))),
                want,
                "raw = {raw:?}"
            );
        }
        // A minus sign that opens a MEASUREMENT is not a bullet and is kept.
        assert_eq!(
            body_of(&build_apns_payload(
                "j",
                None,
                &[],
                PushSummary::Reply("-5°C overnight, so the pipes were lagged.")
            )),
            "-5°C overnight, so the pipes were lagged."
        );
    }

    /// Long text is cut on a WORD boundary with an ellipsis, and the ellipsis is inside
    /// the budget rather than pushing the body past it.
    #[test]
    fn a_long_reply_truncates_on_a_word_boundary() {
        let raw = "alpha ".repeat(80);
        let body = body_of(&build_apns_payload(
            "j",
            None,
            &[],
            PushSummary::Reply(&raw),
        ));
        assert!(body.chars().count() <= MAX_PUSH_SUMMARY_CHARS, "{body:?}");
        assert!(body.ends_with('…'), "{body:?}");
        assert!(
            body.trim_end_matches('…').ends_with("alpha"),
            "cut between words, never mid-word: {body:?}"
        );
    }

    /// THE BLANK-BODY REGRESSION. A reply that sanitizes away to nothing falls back to
    /// the pre-summary line verbatim — a push must never arrive with an empty body.
    #[test]
    fn a_summary_that_sanitizes_to_empty_falls_back() {
        for raw in ["", "   \n\t  ", "\u{7}\u{0}", "```", "## ", "---"] {
            assert_eq!(
                body_of(&build_apns_payload("j", None, &[], PushSummary::Reply(raw))),
                "Jesse finished",
                "raw = {raw:?}"
            );
        }
        // With files, the fallback is still the NAMES — that is what the space is for
        // when there is no summary to spend it on.
        let art = Artifact {
            id: random_hex(),
            filename: "chart.png".into(),
            mime: "image/png".into(),
            bytes: 1,
            sha256: "ff".into(),
        };
        assert_eq!(
            body_of(&build_apns_payload(
                "j",
                None,
                &[art],
                PushSummary::Reply("```")
            )),
            "Jesse finished — chart.png"
        );
    }

    /// The machine directives the person never sees are off the body too, because it is
    /// derived through the same `delivered_text` the chat bubble is.
    #[test]
    fn the_summary_is_the_delivered_text() {
        let raw = "The battery is low.\nSPOKEN: The battery is low.";
        assert_eq!(
            body_of(&build_apns_payload("j", None, &[], PushSummary::Reply(raw))),
            "The battery is low."
        );
    }

    /// A FAILED turn says so first, and never borrows "Jesse finished".
    #[test]
    fn a_failed_job_leads_with_failed() {
        assert_eq!(
            body_of(&build_apns_payload(
                "j",
                None,
                &[],
                PushSummary::Failure("claude exited 1: model overloaded")
            )),
            "Failed: claude exited 1: model overloaded"
        );
        // Even with nothing to say, it does not claim the turn finished.
        assert_eq!(
            body_of(&build_apns_payload(
                "j",
                None,
                &[],
                PushSummary::Failure("  ")
            )),
            "Jesse failed"
        );
    }
    /// THE SECOND ROUTING KEY. `job_id` alone cannot open a scheduled job's thread or an
    /// already-settled turn's — the app resolves it through the turns THIS DEVICE started
    /// and has not yet settled, and neither of those is in that map.
    #[test]
    fn the_payload_names_the_conversation_to_open() {
        let v: Value = serde_json::from_slice(&build_apns_payload(
            "job-xyz",
            Some("11111111-2222-3333-4444-555555555555"),
            &[],
            PushSummary::Reply("done"),
        ))
        .unwrap();
        assert_eq!(v["job_id"], "job-xyz");
        assert_eq!(
            v["conversation_id"], "11111111-2222-3333-4444-555555555555",
            "top-level, beside job_id"
        );
    }

    /// Absent, not null, when there is nothing to name. An app build that predates this
    /// key reads the payload exactly as it always did.
    #[test]
    fn an_unknown_conversation_is_omitted_entirely() {
        let v: Value = serde_json::from_slice(&build_apns_payload(
            "j",
            None,
            &[],
            PushSummary::Reply("done"),
        ))
        .unwrap();
        assert!(
            v.get("conversation_id").is_none(),
            "absent, never a null the app has to special-case: {v}"
        );
    }

    /// A SCHEDULED run's push is the one most worth tapping and the one that could never
    /// route: the phone never started the turn. Its conversation rides the same key.
    #[test]
    fn a_scheduled_payload_names_its_conversation() {
        let v: Value = serde_json::from_slice(&build_scheduled_payload(
            "morning-start-of-day",
            "ran",
            "",
            Some("j"),
            Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            false,
            None,
        ))
        .unwrap();
        assert_eq!(v["conversation_id"], "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");

        // A SKIPPED run never started a turn, so it has neither id to give.
        let skipped: Value = serde_json::from_slice(&build_scheduled_payload(
            "morning-start-of-day",
            "skipped",
            "already ran",
            None,
            None,
            false,
            None,
        ))
        .unwrap();
        assert!(skipped.get("job_id").is_none());
        assert!(skipped.get("conversation_id").is_none());
    }

    /// With NO summary to show, a turn that returned files still names them, and carries
    /// nothing else about them — no id, no size, no bytes. The list is bounded and
    /// control characters are stripped, because the filename is the MODEL's and this one
    /// reaches a notification.
    #[test]
    fn payload_names_returned_files_and_nothing_more() {
        let art = |name: &str| Artifact {
            id: random_hex(),
            filename: name.to_string(),
            mime: "image/png".into(),
            bytes: 1,
            sha256: "ff".into(),
        };
        let one = build_apns_payload("j", None, &[art("chart.png")], PushSummary::Reply(""));
        let v: Value = serde_json::from_slice(&one).unwrap();
        assert_eq!(v["aps"]["alert"]["body"], "Jesse finished — chart.png");
        // Nothing about the artifact rides the push except its name.
        let s = String::from_utf8(one).unwrap();
        assert!(!s.contains("sha256") && !s.contains("image/png") && !s.contains("bytes"));

        let many: Vec<Artifact> = (0..5).map(|i| art(&format!("f{i}.png"))).collect();
        let v: Value = serde_json::from_slice(&build_apns_payload(
            "j",
            None,
            &many,
            PushSummary::Reply(""),
        ))
        .unwrap();
        assert_eq!(
            v["aps"]["alert"]["body"], "Jesse finished — f0.png, f1.png, f2.png and 2 more",
            "the list is bounded so one turn cannot overrun a lock-screen alert"
        );

        // A crafted filename cannot forge extra lines in the alert.
        let v: Value = serde_json::from_slice(&build_apns_payload(
            "j",
            None,
            &[art("a\nb\rc.png")],
            PushSummary::Reply(""),
        ))
        .unwrap();
        let body = v["aps"]["alert"]["body"].as_str().unwrap();
        assert!(!body.contains('\n') && !body.contains('\r'), "{body:?}");

        // A name that sanitizes to nothing degrades to the plain line rather than a
        // dangling em dash.
        let v: Value = serde_json::from_slice(&build_apns_payload(
            "j",
            None,
            &[art("\u{7}")],
            PushSummary::Reply(""),
        ))
        .unwrap();
        assert_eq!(v["aps"]["alert"]["body"], "Jesse finished");
    }

    /// WITH a summary, the files become a count and the summary takes the space. The
    /// names are one tap away; what the turn said is not.
    #[test]
    fn files_become_a_count_when_there_is_a_summary() {
        let art = |name: &str| Artifact {
            id: random_hex(),
            filename: name.to_string(),
            mime: "image/png".into(),
            bytes: 1,
            sha256: "ff".into(),
        };
        let reply = PushSummary::Reply("Charted the week's weight and the trend line.");
        assert_eq!(
            body_of(&build_apns_payload("j", None, &[art("chart.png")], reply)),
            "Charted the week's weight and the trend line. [1 file]"
        );
        assert_eq!(
            body_of(&build_apns_payload(
                "j",
                None,
                &[art("chart.png"), art("table.csv")],
                reply
            )),
            "Charted the week's weight and the trend line. [2 files]"
        );
    }
    /// EVERY push the bridge sends carries `content-available: 1`, and it is inside `aps`
    /// (a top-level key of that name means nothing to iOS). This is the whole mechanism by
    /// which a reply reaches a phone in a pocket, so it is asserted on every builder rather
    /// than on the one that happened to be edited.
    #[test]
    fn every_payload_is_content_available() {
        let art = Artifact {
            id: random_hex(),
            filename: "chart.png".into(),
            mime: "image/png".into(),
            bytes: 1,
            sha256: "ff".into(),
        };
        let payloads = [
            build_apns_payload("j", None, &[], PushSummary::Reply("")),
            build_apns_payload("j", None, &[art], PushSummary::Reply("all done")),
            build_apns_payload("j", None, &[], PushSummary::Failure("boom")),
            build_scheduled_payload(
                "morning-start-of-day",
                "ok",
                "",
                Some("j"),
                None,
                false,
                None,
            ),
            build_scheduled_payload(
                "morning-start-of-day",
                "ok",
                "",
                None,
                None,
                true,
                Some("the day file is rebuilt"),
            ),
            build_escalation_payload("nightly", 3, "timed out"),
            build_reload_failure_payload("bad toml"),
        ];
        for payload in payloads {
            let v: Value = serde_json::from_slice(&payload).unwrap();
            assert_eq!(
                v["aps"]["content-available"], 1,
                "content-available must live INSIDE aps: {v}"
            );
            // The alert survives it — this is an alert push that ALSO wakes the app, not a
            // silent one. A silent push would be invisible on the lock screen, which is the
            // opposite of what every one of these is for.
            assert!(
                v["aps"]["alert"]["body"].is_string(),
                "still an alert push: {v}"
            );
        }
    }

    /// The prefetch hint: present, top-level, and exactly the two documents — only for a
    /// job the operator listed.
    #[test]
    fn scheduled_payload_carries_prefetch_only_when_asked() {
        let with: Value = serde_json::from_slice(&build_scheduled_payload(
            "m",
            "ok",
            "",
            Some("j"),
            None,
            true,
            None,
        ))
        .unwrap();
        assert_eq!(with["prefetch"], json!(["today", "diet"]));
        assert_eq!(with["job_id"], "j", "the deep link is unaffected");
        assert_eq!(with["schedule_id"], "m");

        let without: Value = serde_json::from_slice(&build_scheduled_payload(
            "m",
            "ok",
            "",
            Some("j"),
            None,
            false,
            None,
        ))
        .unwrap();
        assert!(
            without.get("prefetch").is_none(),
            "absent, not an empty array — a phone reading `prefetch` at all must not \
             refresh on a push that did not ask it to: {without}"
        );
        // Without the hint the payload is byte-for-byte what it was before this existed,
        // modulo the content-available flag asserted above.
        assert_eq!(without["aps"]["alert"]["title"], "Jesse schedule");
    }

    /// A skipped run has no turn and so no `job_id`, and can still carry the hint: the day
    /// file may have been rewritten by an earlier link of the same chain.
    #[test]
    fn prefetch_is_independent_of_the_deep_link() {
        let v: Value = serde_json::from_slice(&build_scheduled_payload(
            "m",
            "skipped",
            "already ran",
            None,
            None,
            true,
            None,
        ))
        .unwrap();
        assert!(v.get("job_id").is_none());
        assert_eq!(v["prefetch"], json!(["today", "diet"]));
    }

    /// A CLEAN scheduled run says what it reported. The id and outcome move into the
    /// title so the body is all summary — "morning-start-of-day ran" was true and told
    /// nobody anything.
    #[test]
    fn a_clean_scheduled_run_pushes_its_summary() {
        let v: Value = serde_json::from_slice(&build_scheduled_payload(
            "morning-start-of-day",
            "ran",
            "",
            Some("j"),
            Some("11111111-2222-3333-4444-555555555555"),
            false,
            Some("## Today\n\nTwo meetings, and the vault lint is clean."),
        ))
        .unwrap();
        assert_eq!(v["aps"]["alert"]["title"], "morning-start-of-day ran");
        assert_eq!(
            v["aps"]["alert"]["body"],
            "Today Two meetings, and the vault lint is clean."
        );
        assert_eq!(v["job_id"], "j", "the deep link is unaffected");
    }

    /// A REASON OUTRANKS THE SUMMARY. Every alert that carries one is about a failure, a
    /// skip or a missing output, and burying that under the turn's parting words is
    /// exactly the regression the reason exists to prevent.
    #[test]
    fn a_reason_still_wins_over_the_summary() {
        let v: Value = serde_json::from_slice(&build_scheduled_payload(
            "overnight-vault-lint",
            "fired-no-output",
            "the turn completed but wrote nothing matching Reports/*.md",
            Some("j"),
            None,
            false,
            Some("All good, nothing to report."),
        ))
        .unwrap();
        assert_eq!(v["aps"]["alert"]["title"], "Jesse schedule");
        assert_eq!(
            v["aps"]["alert"]["body"],
            "overnight-vault-lint fired-no-output — the turn completed but wrote nothing \
             matching Reports/*.md"
        );
    }

    /// A scheduled summary that sanitizes to nothing degrades to the line it always was,
    /// never to a blank body.
    #[test]
    fn an_empty_scheduled_summary_falls_back() {
        let v: Value = serde_json::from_slice(&build_scheduled_payload(
            "m",
            "ran",
            "",
            None,
            None,
            false,
            Some("```"),
        ))
        .unwrap();
        assert_eq!(v["aps"]["alert"]["title"], "Jesse schedule");
        assert_eq!(v["aps"]["alert"]["body"], "m ran");
    }

    /// The list is matched EXACTLY. A prefix match would fire on a differently-named job
    /// that merely starts the same way, which is a real shape for a dry-run twin.
    #[test]
    fn prefetch_matching_is_exact() {
        let jobs = parse_prefetch_jobs("morning-start-of-day, evening-wrap ,");
        assert_eq!(jobs, vec!["morning-start-of-day", "evening-wrap"]);
        assert!(wants_prefetch("morning-start-of-day", &jobs));
        assert!(wants_prefetch("evening-wrap", &jobs));
        assert!(!wants_prefetch("morning-start-of-day-dry-run", &jobs));
        assert!(!wants_prefetch("morning", &jobs));
        assert!(!wants_prefetch("", &jobs));
    }

    /// A blank spec is a list of NOTHING — the off switch for the hint — and the default
    /// spec is the morning chain. Both are checked on the pure parser rather than through
    /// the environment, which a parallel test run shares.
    #[test]
    fn blank_prefetch_spec_disables_the_hint() {
        assert!(parse_prefetch_jobs("").is_empty());
        assert!(parse_prefetch_jobs("   ,  ,").is_empty());
        assert!(!wants_prefetch(
            "morning-start-of-day",
            &parse_prefetch_jobs("")
        ));
        assert_eq!(
            parse_prefetch_jobs(DEFAULT_PUSH_PREFETCH_JOBS),
            vec!["morning-start-of-day"]
        );
    }

    #[test]
    fn pushable_only_for_done_or_failed() {
        assert!(job_state_is_pushable(&JobState::Done {
            response: "x".into(),
            session_id: None,
            directives: None,
            provenance: None,
            artifacts: Vec::new(),
        }));
        assert!(job_state_is_pushable(&JobState::Failed {
            error: "x".into(),
            partial: None
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
        // END TO END: the reply text was ALWAYS on the terminal state and was simply not
        // being read. This asserts it now reaches the wire.
        assert_eq!(
            body_of(&req.payload),
            "the answer",
            "the body is what the turn said"
        );
    }

    /// END TO END for the routing key: a conversation bound at job creation reaches the
    /// wire from `notify_if_complete`, which is handed NOTHING but a job id — the same
    /// shape the `POST /jesse/notify/{job_id}` race-closer calls it in.
    #[tokio::test]
    async fn the_push_carries_the_conversation_bound_at_creation() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("abc123devicetoken".to_string());

        let id = st.jobs.create();
        st.jobs
            .bind_conversation(&id, "11111111-2222-3333-4444-555555555555");
        st.jobs
            .complete(&id, Ok(("the answer".to_string(), None, None)));
        st.notify.insert(&id);

        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        {
            let calls = mock.calls.lock_ok();
            assert_eq!(calls.len(), 1);
            let v: Value = serde_json::from_slice(&calls[0].payload).unwrap();
            assert_eq!(v["conversation_id"], "11111111-2222-3333-4444-555555555555");
        }

        // And a job with no conversation still pushes — just without the key.
        let bare = st.jobs.create();
        st.jobs
            .complete(&bare, Ok(("no conversation".to_string(), None, None)));
        st.notify.insert(&bare);
        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &bare).await;
        let calls = mock.calls.lock_ok();
        let v: Value = serde_json::from_slice(&calls[1].payload).unwrap();
        assert!(v.get("conversation_id").is_none());
    }

    /// A FAILED flagged turn pushes its error, not "Jesse finished" — which is what it
    /// pushed before, on the state whose whole point is that something went wrong.
    #[tokio::test]
    async fn a_failed_flagged_turn_pushes_its_error() {
        let mock = MockApns::default();
        let mut st = test_state();
        st.apns = Some(test_apns(Arc::new(mock.clone())));
        st.devices.set("abc123devicetoken".to_string());

        let id = st.jobs.create();
        st.jobs.complete(
            &id,
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "claude exited 1: overloaded".to_string(),
            )),
        );
        st.notify.insert(&id);

        notify_if_complete(st.apns.as_deref(), &st.devices, &st.notify, &st.jobs, &id).await;

        let calls = mock.calls.lock_ok();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            body_of(&calls[0].payload),
            "Failed: claude exited 1: overloaded"
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
    fn concurrent_persists_never_collide_on_a_temp_file() {
        // The phone re-registers on foreground, so `set` calls overlap. With a
        // single shared `device.json.tmp` the losing writer's rename hit ENOENT and
        // its open fd wrote into the already-renamed file; unique temp names make
        // every writer atomic and the last one simply win. Assert the observable
        // contract: whatever the interleaving, the file always parses to one of the
        // tokens written, and no temp file is left behind.
        let dir = temp_jobs_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("device.json");

        // Overlap is forced with a barrier rather than bought with volume: every
        // write fsyncs, and a big fleet (8 x 50 was the first cut) starves the
        // deadline-based turn tests sharing a `cargo test --all-targets` run enough
        // to fail them. Releasing 4 threads simultaneously puts their writes inside
        // each other's open→rename window with only 4 x 4 writes total, which is
        // enough to fail against the shared-temp-path bug on every observed run.
        let gate = Arc::new(std::sync::Barrier::new(4));
        let threads: Vec<_> = (0..4)
            .map(|t| {
                let path = path.clone();
                let gate = Arc::clone(&gate);
                std::thread::spawn(move || {
                    gate.wait();
                    (0..4)
                        .filter_map(|i| {
                            try_persist_device_token(&path, &format!("token-{t}-{i}")).err()
                        })
                        .map(|e| e.to_string())
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        let errors: Vec<String> = threads
            .into_iter()
            .flat_map(|t| t.join().unwrap())
            .collect();
        assert!(
            errors.is_empty(),
            "every concurrent write must succeed; got {} failure(s): {:?}",
            errors.len(),
            &errors[..errors.len().min(3)]
        );

        let loaded = load_device_token(&path).expect("the file parses after the race");
        assert!(
            loaded.starts_with("token-"),
            "a torn write would leave something other than a whole token: {loaded:?}"
        );
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains(".tmp"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "every temp file must be renamed away, found: {leftovers:?}"
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
