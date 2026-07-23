//! **Per-model health probing** — an optional, non-blocking, mock-testable subsystem
//! (the same shape as the APNs push path and the shadow slot): for each CONFIGURED
//! non-ambient model in the registry, a background task probes reachability on an
//! interval and caches a small content-free status the endpoints read to gate selection.
//!
//! Contract, mirroring the other optional subsystems:
//!   * it NEVER blocks a turn — probing runs on its own detached task(s), and a turn only
//!     ever READS the cached [`HealthStore`];
//!   * it NEVER crashes the bridge and NEVER logs a token — a probe failure is recorded as
//!     a coarse error class (`timeout` / `connect` / `transport` / `http-5xx`), never the
//!     token, the URL, or any response body;
//!   * it is ENTIRELY ABSENT for an opus-only deploy — with no configured non-ambient
//!     model there are no probe targets, so [`spawn_health_prober`] starts nothing.
//!
//! The ambient `opus` default is healthy BY CONSTRUCTION (it is the local Claude Code
//! auth): it is never a probe target and [`model_health`] reports it healthy without a
//! store entry.
//!
//! Selectability (what the endpoints and the apps gate on) is `configured` (backend/token
//! resolved) AND `healthy` (the last probe passed). A configured non-ambient model is
//! seeded OPTIMISTICALLY healthy at startup ([`HealthStore::seeded`]) — it behaves exactly
//! like today's `configured ⇒ available` until a probe actually FAILS, at which point it is
//! demoted to unhealthy — so arming a model never regresses to "briefly unselectable", and
//! "unhealthy" only ever means an observed failure.
//!
//! The prober is proven by the mock probe + the injected clock in the tests below (no real
//! network in CI); no live provider is contacted here.

use crate::*;

/// Default probe cadence: a minimal request every 60 s, overridable per model.
pub const DEFAULT_HEALTH_INTERVAL_SECS: u64 = 60;
/// Default per-probe wall-clock budget: short (3 s) so a hung backend is quickly seen down.
pub const DEFAULT_HEALTH_TIMEOUT_SECS: u64 = 3;
/// Default probe endpoint on the model's Anthropic surface: a tiny `/v1/messages` call.
pub const DEFAULT_HEALTH_PATH: &str = "/v1/messages";

/// One model's probe cadence + endpoint. Built from a declarative entry's optional
/// `health = { path, interval_secs, timeout_secs }` (each field defaulted independently),
/// or the defaults for an env-triple model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthConfig {
    pub path: String,
    pub interval_secs: u64,
    pub timeout_secs: u64,
}

impl Default for HealthConfig {
    fn default() -> Self {
        HealthConfig {
            path: DEFAULT_HEALTH_PATH.to_string(),
            interval_secs: DEFAULT_HEALTH_INTERVAL_SECS,
            timeout_secs: DEFAULT_HEALTH_TIMEOUT_SECS,
        }
    }
}

/// A model's last-known reachability, cached by the prober. Content-free: booleans, a
/// wall-clock stamp, a latency, and a COARSE error class — never a token or response text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthStatus {
    pub healthy: bool,
    /// Unix-millis wall clock of the last probe (or the optimistic seed, stamped `0`).
    pub checked_at_ms: u64,
    /// Round-trip latency of the last probe, absent for the optimistic seed.
    pub latency_ms: Option<u64>,
    /// Coarse class of the last failure (`timeout` / `connect` / `transport` / `http-5xx`),
    /// or `None` on a passing probe. NEVER the token, URL, or body.
    pub last_error_class: Option<String>,
}

impl HealthStatus {
    /// The optimistic startup seed for a freshly-configured model: healthy, no probe yet.
    fn seed() -> Self {
        HealthStatus {
            healthy: true,
            checked_at_ms: 0,
            latency_ms: None,
            last_error_class: None,
        }
    }
}

/// The per-model health cache. Cheaply shared behind an `Arc` in `AppState`; the prober
/// writes it and the endpoints read it. Holds ids → status only, never a secret.
pub struct HealthStore {
    statuses: Mutex<HashMap<String, HealthStatus>>,
}

impl Default for HealthStore {
    fn default() -> Self {
        HealthStore {
            statuses: Mutex::new(HashMap::new()),
        }
    }
}

impl HealthStore {
    pub fn new() -> Self {
        HealthStore::default()
    }

    /// Build a store seeded with an OPTIMISTIC healthy status for every configured
    /// non-ambient model, so a configured model is selectable from startup (as today) and
    /// is only demoted to unhealthy by an observed probe failure. Ambient `opus` is never
    /// seeded (it is healthy by construction — see [`model_health`]).
    pub fn seeded(registry: &ModelRegistry) -> Self {
        let mut statuses = HashMap::new();
        for m in &registry.models {
            if !matches!(m.kind, ModelKind::Ambient) && m.configured {
                statuses.insert(m.id.clone(), HealthStatus::seed());
            }
        }
        HealthStore {
            statuses: Mutex::new(statuses),
        }
    }

    /// The cached status for a model id, or `None` when it has never been seeded/probed.
    pub fn get(&self, id: &str) -> Option<HealthStatus> {
        self.statuses.lock_ok().get(id).cloned()
    }

    /// Record a model's latest probe status (overwrites any prior).
    pub fn set(&self, id: &str, status: HealthStatus) {
        self.statuses.lock_ok().insert(id.to_string(), status);
    }
}

/// The three distinguishable states the apps render, resolved from a registry entry + the
/// live health cache: `configured` (backend/token resolved), `healthy` (last probe passed),
/// and `available` = configured AND healthy. The ambient `opus` is always configured +
/// healthy (no probe). The raw `status` rides along for the endpoint's `last_checked_ms` /
/// `latency_ms`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelHealth {
    pub configured: bool,
    pub healthy: bool,
    pub status: Option<HealthStatus>,
}

impl ModelHealth {
    /// Selectable = configured AND healthy. This is what `POST /jesse/model` and the app
    /// switchers gate on, and what the endpoint emits as `available`.
    pub fn available(&self) -> bool {
        self.configured && self.healthy
    }
}

/// Resolve a registry model's health state against the cache. Ambient `opus` is healthy by
/// construction (never probed). A configured non-ambient model is healthy iff its last
/// probe passed (before the first probe it carries the optimistic seed). An unconfigured
/// model (no token/triple, e.g. `kimi-k3` until armed) is never healthy.
pub fn model_health(m: &RegistryModel, health: &HealthStore) -> ModelHealth {
    if matches!(m.kind, ModelKind::Ambient) {
        return ModelHealth {
            configured: true,
            healthy: true,
            status: None,
        };
    }
    let status = health.get(&m.id);
    let healthy = m.configured && status.as_ref().map(|s| s.healthy).unwrap_or(false);
    ModelHealth {
        configured: m.configured,
        healthy,
        status,
    }
}

// ---- The probe seam (mockable, like `ApnsTransport`) ----------------------

/// One model the prober watches: its id, resolved backend triple, and probe cadence.
#[derive(Debug, Clone)]
pub struct ProbeTarget {
    pub id: String,
    pub base_url: String,
    pub auth_token: String,
    pub model: String,
    pub health: HealthConfig,
}

/// The outcome of one probe attempt. Content-free — never a token or response body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeOutcome {
    pub ok: bool,
    pub latency_ms: u64,
    pub error_class: Option<String>,
}

/// The mockable network seam (exactly the [`ApnsTransport`] shape): the real impl is
/// reqwest; tests inject a canned probe so CI never hits the network.
pub trait HealthProbe: Send + Sync {
    fn probe(&self, target: &ProbeTarget) -> Pin<Box<dyn Future<Output = ProbeOutcome> + Send>>;
}

/// Run ONE probe of a target and record its status under `now_ms`. This is the whole prober
/// body per tick — factored out so the tests drive it directly with a mock probe and an
/// injected clock (the spawned loop just calls it on each interval tick). Never blocks a
/// turn; never panics.
pub async fn probe_and_record(
    target: &ProbeTarget,
    probe: &dyn HealthProbe,
    store: &HealthStore,
    now_ms: u64,
) {
    let outcome = probe.probe(target).await;
    store.set(
        &target.id,
        HealthStatus {
            healthy: outcome.ok,
            checked_at_ms: now_ms,
            latency_ms: Some(outcome.latency_ms),
            last_error_class: outcome.error_class,
        },
    );
}

/// The configured non-ambient models the prober watches. An ambient or unconfigured entry
/// (no resolved backend) is skipped, so an opus-only deploy yields an empty list and the
/// prober starts nothing.
pub fn probe_targets(registry: &ModelRegistry) -> Vec<ProbeTarget> {
    registry
        .models
        .iter()
        .filter_map(|m| {
            if matches!(m.kind, ModelKind::Ambient) {
                return None;
            }
            let (base_url, auth_token, model) = m.backend.clone()?;
            Some(ProbeTarget {
                id: m.id.clone(),
                base_url,
                auth_token,
                model,
                health: m.health.clone(),
            })
        })
        .collect()
}

/// Current unix-millis wall clock (0 on a clock error — the prober never fails on it).
fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Join a backend base url and a probe path into one URL (`base` + `/` + `path`), tolerating
/// a trailing slash on the base and a leading slash on the path.
pub fn join_url(base: &str, path: &str) -> String {
    format!("{}/{}", base.trim_end_matches('/'), path.trim_start_matches('/'))
}

/// Wire the PRODUCTION prober from app state: build the reqwest probe and the configured
/// non-ambient targets, then spawn one background task per target. A no-op for an opus-only
/// deploy (no targets → nothing spawned), so the health path is entirely absent there.
/// Called once from `main` after `AppState` is built; tests never call this (they drive
/// [`probe_and_record`] with a mock probe instead).
pub fn start_health_prober(health: Arc<HealthStore>, registry: &ModelRegistry) {
    let targets = probe_targets(registry);
    if targets.is_empty() {
        return;
    }
    let probe: Arc<dyn HealthProbe> = Arc::new(ReqwestProbe::new());
    spawn_health_prober(health, probe, targets);
}

/// Spawn the background prober: ONE detached task per configured non-ambient model, each
/// ticking on its own `health.interval_secs` (the first tick fires immediately, so a fresh
/// deploy is probed at startup). A no-op when there are no targets (an opus-only deploy),
/// so the health path is entirely absent then. `probe` is the shared network seam.
pub fn spawn_health_prober(store: Arc<HealthStore>, probe: Arc<dyn HealthProbe>, targets: Vec<ProbeTarget>) {
    for target in targets {
        let store = store.clone();
        let probe = probe.clone();
        tokio::spawn(async move {
            let mut tick =
                tokio::time::interval(Duration::from_secs(target.health.interval_secs.max(1)));
            // Fire the first tick immediately (probe at startup), then every interval; a
            // missed deadline is skipped, not burst — cadence isn't correctness.
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tick.tick().await;
                probe_and_record(&target, probe.as_ref(), &store, now_unix_ms()).await;
            }
        });
    }
}

// ---- The production reqwest probe -----------------------------------------

/// Production probe: a tiny `POST <base_url><health.path>` with a 1-token cap on the model's
/// Anthropic surface, bounded by `health.timeout_secs`. Reachable-and-not-erroring (any HTTP
/// status < 500) is HEALTHY — a reachability check tolerates a 4xx from header/body quirks
/// on a gateway; a timeout, a transport/DNS/connect error, or a 5xx is UNHEALTHY. NEVER logs
/// the token, the URL, or the response body — only a coarse error class reaches the store.
pub struct ReqwestProbe {
    client: reqwest::Client,
}

impl ReqwestProbe {
    pub fn new() -> Self {
        // Fall back to the default client if a builder ever fails (mirrors `build_apns`).
        let client = reqwest::Client::builder().build().unwrap_or_default();
        ReqwestProbe { client }
    }
}

impl Default for ReqwestProbe {
    fn default() -> Self {
        ReqwestProbe::new()
    }
}

impl HealthProbe for ReqwestProbe {
    fn probe(&self, target: &ProbeTarget) -> Pin<Box<dyn Future<Output = ProbeOutcome> + Send>> {
        let client = self.client.clone();
        let url = join_url(&target.base_url, &target.health.path);
        let token = target.auth_token.clone();
        let timeout_secs = target.health.timeout_secs.max(1);
        // A minimal Anthropic `/v1/messages` body with a 1-token cap. Built as a string so
        // reqwest's `json` feature isn't required (the crate pulls only rustls + http2).
        let body = json!({
            "model": target.model,
            "max_tokens": 1,
            "messages": [{ "role": "user", "content": "ping" }],
        })
        .to_string();
        Box::pin(async move {
            let started = Instant::now();
            let res = client
                .post(&url)
                .timeout(Duration::from_secs(timeout_secs))
                .header("content-type", "application/json")
                .header("anthropic-version", "2023-06-01")
                .header("authorization", format!("Bearer {token}"))
                .body(body)
                .send()
                .await;
            let latency_ms = started.elapsed().as_millis() as u64;
            match res {
                Ok(resp) => {
                    let status = resp.status().as_u16();
                    if status < 500 {
                        ProbeOutcome {
                            ok: true,
                            latency_ms,
                            error_class: None,
                        }
                    } else {
                        ProbeOutcome {
                            ok: false,
                            latency_ms,
                            error_class: Some("http-5xx".to_string()),
                        }
                    }
                }
                Err(e) => {
                    let class = if e.is_timeout() {
                        "timeout"
                    } else if e.is_connect() {
                        "connect"
                    } else {
                        "transport"
                    };
                    ProbeOutcome {
                        ok: false,
                        latency_ms,
                        error_class: Some(class.to_string()),
                    }
                }
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A canned probe: returns a fixed outcome and counts how many times it was called, so a
    /// test drives the prober with NO real network.
    struct MockProbe {
        outcome: ProbeOutcome,
        calls: AtomicUsize,
    }

    impl MockProbe {
        fn new(ok: bool, latency_ms: u64, error_class: Option<&str>) -> Self {
            MockProbe {
                outcome: ProbeOutcome {
                    ok,
                    latency_ms,
                    error_class: error_class.map(str::to_string),
                },
                calls: AtomicUsize::new(0),
            }
        }
    }

    impl HealthProbe for MockProbe {
        fn probe(&self, _t: &ProbeTarget) -> Pin<Box<dyn Future<Output = ProbeOutcome> + Send>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let outcome = self.outcome.clone();
            Box::pin(async move { outcome })
        }
    }

    fn target(id: &str) -> ProbeTarget {
        ProbeTarget {
            id: id.to_string(),
            base_url: "http://backend".to_string(),
            auth_token: "secret-token".to_string(),
            model: "m".to_string(),
            health: HealthConfig::default(),
        }
    }

    #[test]
    fn health_config_defaults() {
        let h = HealthConfig::default();
        assert_eq!(h.path, "/v1/messages");
        assert_eq!(h.interval_secs, 60);
        assert_eq!(h.timeout_secs, 3);
    }

    #[test]
    fn join_url_tolerates_slashes() {
        assert_eq!(
            join_url("https://api.example/inference", "/v1/messages"),
            "https://api.example/inference/v1/messages"
        );
        assert_eq!(
            join_url("https://api.example/inference/", "v1/messages"),
            "https://api.example/inference/v1/messages"
        );
    }

    #[tokio::test]
    async fn a_passing_probe_records_healthy_with_the_injected_clock() {
        let store = HealthStore::new();
        let probe = MockProbe::new(true, 42, None);
        probe_and_record(&target("glm-5.2"), &probe, &store, 1_700_000_000_000).await;
        let s = store.get("glm-5.2").expect("status recorded");
        assert!(s.healthy);
        assert_eq!(s.checked_at_ms, 1_700_000_000_000, "the injected clock is stamped");
        assert_eq!(s.latency_ms, Some(42));
        assert_eq!(s.last_error_class, None);
        assert_eq!(probe.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_failing_probe_records_unhealthy_with_a_coarse_error_class() {
        let store = HealthStore::new();
        let probe = MockProbe::new(false, 3000, Some("timeout"));
        probe_and_record(&target("glm-5.2"), &probe, &store, 9_000).await;
        let s = store.get("glm-5.2").expect("status recorded");
        assert!(!s.healthy);
        assert_eq!(s.last_error_class.as_deref(), Some("timeout"));
        // A later PASSING probe flips it back healthy and clears the error class.
        let ok = MockProbe::new(true, 30, None);
        probe_and_record(&target("glm-5.2"), &ok, &store, 10_000).await;
        let s = store.get("glm-5.2").expect("status recorded");
        assert!(s.healthy);
        assert_eq!(s.last_error_class, None);
        assert_eq!(s.checked_at_ms, 10_000);
    }

    #[test]
    fn ambient_opus_is_healthy_by_construction_without_a_probe() {
        // An empty store + the opus-only registry: opus resolves configured+healthy with no
        // entry, and it is never a probe target.
        let registry = ModelRegistry::opus_only();
        let store = HealthStore::seeded(&registry);
        let opus = registry.get("opus").unwrap();
        let h = model_health(opus, &store);
        assert!(h.configured && h.healthy && h.available());
        assert!(probe_targets(&registry).is_empty(), "opus is never probed");
    }

    #[test]
    fn seeded_store_makes_a_configured_model_optimistically_available() {
        // A configured non-ambient model is selectable from startup (seeded healthy) and is
        // demoted only by an observed failure.
        let glm = RegistryModel {
            id: "glm-5.2".into(),
            label: "GLM".into(),
            kind: ModelKind::Hosted,
            backend: Some(("http://b".into(), "t".into(), "m".into())),
            configured: true,
            default_writes: false,
            price: PriceDeck::ZERO,
            subagent_model: Some("m".into()),
            health: HealthConfig::default(),
        };
        let registry = ModelRegistry {
            models: vec![glm.clone()],
        };
        let store = HealthStore::seeded(&registry);
        assert!(model_health(&glm, &store).available(), "seeded configured → available");

        // A failed probe demotes it: configured but not healthy → not available.
        store.set(
            "glm-5.2",
            HealthStatus {
                healthy: false,
                checked_at_ms: 5,
                latency_ms: Some(3000),
                last_error_class: Some("timeout".into()),
            },
        );
        let h = model_health(&glm, &store);
        assert!(h.configured && !h.healthy && !h.available());
    }

    #[test]
    fn an_unconfigured_model_is_never_available() {
        let kimi = RegistryModel {
            id: "kimi-k3".into(),
            label: "Kimi".into(),
            kind: ModelKind::Hosted,
            backend: None,
            configured: false,
            default_writes: false,
            price: PriceDeck::ZERO,
            subagent_model: None,
            health: HealthConfig::default(),
        };
        let registry = ModelRegistry {
            models: vec![kimi.clone()],
        };
        // Not seeded (unconfigured), so even in a seeded store it is unconfigured+unhealthy.
        let store = HealthStore::seeded(&registry);
        let h = model_health(&kimi, &store);
        assert!(!h.configured && !h.healthy && !h.available());
        assert!(probe_targets(&registry).is_empty(), "an unconfigured model is not probed");
    }
}
