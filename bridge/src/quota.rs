//! **LIVE USAGE AND QUOTA** — how much of each billing account behind the model picker is
//! left, captured for free from turns where a harness already says so and fetched on demand
//! otherwise.
//!
//! # Quota belongs to an ACCOUNT, not a model
//!
//! Three accounts bill the models this bridge offers, and each registry model maps to at most
//! one of them ([`quota_scope_for`]):
//!
//!   * `claude-subscription` — every `claude-code` model on the bridge's own login (`Ambient`
//!     or `Subscription`). Source: the Claude OAuth usage endpoint, plus the
//!     `rate_limit_event` line the `claude` child writes during a turn.
//!   * `codex-chatgpt` — every `codex` model that authenticates from the ChatGPT login (not
//!     `ModelKind::OpenAi`, which brings its own provider key). Source: the Codex App Server's
//!     `account/rateLimits/read`, plus the `account/rateLimits/updated` notification a turn
//!     already carries.
//!   * `fireworks` — every model whose backend host is `api.fireworks.ai`. Source: the
//!     Fireworks billing usage endpoint, month to date. Fireworks exposes no balance, so this
//!     scope shows spend and never remaining credit.
//!
//! A `Local` model, and any model on another host, maps to nothing and shows nothing.
//!
//! # No timer, ever
//!
//! The store is refreshed in exactly two ways: PASSIVELY, when a turn that already ran reports
//! something ([`QuotaStore::merge_sparse`]), and ON DEMAND, inside `GET /jesse/usage`, when a
//! scope's snapshot is older than its TTL ([`QuotaStore::ensure_fresh`]). Nothing here spawns
//! a background task. The health prober is a separate concern and still never asks the
//! subscription login anything.
//!
//! # What never leaves this module
//!
//! A token. The Claude OAuth token is read from the login keychain (read only, through the
//! `security` CLI) or `~/.claude/.credentials.json`, used for one request and dropped; the
//! Codex login is never read beyond its `auth_mode` field and is used only by the child the
//! bridge spawns against it. Neither is ever refreshed, rewritten or copied: the `claude` and
//! `codex` children own their logins. Failures are logged as a content free CLASS
//! ([`QuotaError::class`]), exactly the way `health.rs` classifies a probe, never a body.

use crate::*;
use serde::Serialize;
use std::collections::BTreeMap;
use std::sync::OnceLock;
use tokio::sync::Mutex as AsyncMutex;

// ---- Constants ---------------------------------------------------------------------

/// How long a Claude subscription snapshot is fresh before `GET /jesse/usage` refetches it.
pub const CLAUDE_QUOTA_TTL_SECS: u64 = 120;
/// How long a ChatGPT (Codex) snapshot is fresh.
pub const CODEX_QUOTA_TTL_SECS: u64 = 120;
/// How long a Fireworks spend snapshot is fresh. Longer, because billing usage is aggregated
/// daily upstream and a tighter cadence would only re-read the same buckets.
pub const FIREWORKS_QUOTA_TTL_SECS: u64 = 600;
/// A `?force=1` refetch still waits this long since the last one, so a Refresh button hammered
/// by hand cannot turn into a provider poll.
pub const QUOTA_FORCE_FLOOR_SECS: u64 = 20;
/// The least time a scope refuses to refetch after the provider answered 429, whatever its
/// `Retry-After` said.
pub const QUOTA_RATE_LIMIT_FLOOR_SECS: u64 = 300;
/// A window at or above this percentage puts the scope in its warning state.
pub const QUOTA_WARNING_PERCENT: f64 = 90.0;

/// Per-provider request budgets. Every fetch runs concurrently with the others, so the usage
/// route answers within the largest of these.
pub const CLAUDE_FETCH_TIMEOUT_SECS: u64 = 10;
pub const CODEX_FETCH_TIMEOUT_SECS: u64 = 15;
pub const FIREWORKS_FETCH_TIMEOUT_SECS: u64 = 10;
/// The keychain read's own budget. A keychain that prompts or hangs is a `NotLoggedIn` class
/// error once this runs out, never a stuck request.
const KEYCHAIN_TIMEOUT_SECS: u64 = 5;
/// After the Codex exchange, how long the child gets to exit on its closed stdin before it is
/// killed.
const CODEX_EXIT_GRACE_SECS: u64 = 2;

/// The generic-password service Claude Code keeps its login under.
pub const CLAUDE_CREDENTIALS_SERVICE: &str = "Claude Code-credentials";
pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";
/// The scope the usage endpoint requires. A login with `user:inference` alone gets a 403.
const CLAUDE_PROFILE_SCOPE: &str = "user:profile";
/// The host a backend must be on to bill the Fireworks account.
pub const FIREWORKS_HOST: &str = "api.fireworks.ai";
const FIREWORKS_API_BASE: &str = "https://api.fireworks.ai";

/// What the Fireworks scope says when no account id is configured. No request is made.
pub const FIREWORKS_SPEND_NOT_CONFIGURED: &str = "spend not configured (set fireworks_account_id)";
/// What the Claude scope says when the stored OAuth token has expired. The bridge never
/// refreshes it; the next Claude turn does, and the snapshot recovers on the fetch after it.
pub const CLAUDE_LOGIN_EXPIRED: &str = "login expired, refreshes on the next Claude turn";

// ---- Scopes -----------------------------------------------------------------------

/// The account a model bills to. See the module note for the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum QuotaScopeId {
    #[serde(rename = "claude-subscription")]
    ClaudeSubscription,
    #[serde(rename = "codex-chatgpt")]
    CodexChatgpt,
    #[serde(rename = "fireworks")]
    Fireworks,
}

impl QuotaScopeId {
    pub const ALL: [QuotaScopeId; 3] = [
        QuotaScopeId::ClaudeSubscription,
        QuotaScopeId::CodexChatgpt,
        QuotaScopeId::Fireworks,
    ];

    /// The wire id, the same string serde writes.
    pub fn as_str(self) -> &'static str {
        match self {
            QuotaScopeId::ClaudeSubscription => "claude-subscription",
            QuotaScopeId::CodexChatgpt => "codex-chatgpt",
            QuotaScopeId::Fireworks => "fireworks",
        }
    }

    /// The account's name as the Settings card titles it.
    pub fn label(self) -> &'static str {
        match self {
            QuotaScopeId::ClaudeSubscription => "Claude subscription",
            QuotaScopeId::CodexChatgpt => "ChatGPT subscription",
            QuotaScopeId::Fireworks => "Fireworks",
        }
    }

    pub fn default_ttl_secs(self) -> u64 {
        match self {
            QuotaScopeId::ClaudeSubscription => CLAUDE_QUOTA_TTL_SECS,
            QuotaScopeId::CodexChatgpt => CODEX_QUOTA_TTL_SECS,
            QuotaScopeId::Fireworks => FIREWORKS_QUOTA_TTL_SECS,
        }
    }

    pub fn fetch_timeout(self) -> Duration {
        Duration::from_secs(match self {
            QuotaScopeId::ClaudeSubscription => CLAUDE_FETCH_TIMEOUT_SECS,
            QuotaScopeId::CodexChatgpt => CODEX_FETCH_TIMEOUT_SECS,
            QuotaScopeId::Fireworks => FIREWORKS_FETCH_TIMEOUT_SECS,
        })
    }
}

impl std::fmt::Display for QuotaScopeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The scope a registry model bills to, or `None`. See the module note.
pub fn quota_scope_for(model: &RegistryModel) -> Option<QuotaScopeId> {
    scope_for_parts(model.kind, &model.harness, model.backend.as_ref())
}

/// The same mapping for the model a turn is running on, which is an [`ActiveModel`] by then.
pub fn quota_scope_for_active(active: &ActiveModel) -> Option<QuotaScopeId> {
    scope_for_parts(active.kind, &active.harness, active.env.as_ref())
}

/// The table, in the order it is decided.
///
/// The login scopes come before the host rule on purpose. The deployed `codex` entries are
/// `kind = "hosted"` with a backend URL that exists only for the health probe — the harness
/// still authenticates them from the ChatGPT login, because [`codex_provider_args`] repoints a
/// Codex turn only for `ModelKind::OpenAi`. So a Codex model bills ChatGPT whatever URL it
/// declares, and only an `OpenAi` model's URL says whose account it spends.
fn scope_for_parts(
    kind: ModelKind,
    harness: &str,
    backend: Option<&(String, String, String)>,
) -> Option<QuotaScopeId> {
    if matches!(kind, ModelKind::Local) {
        return None;
    }
    if harness == CLAUDE_CODE_ID && matches!(kind, ModelKind::Ambient | ModelKind::Subscription) {
        return Some(QuotaScopeId::ClaudeSubscription);
    }
    if harness == CODEX_ID && !matches!(kind, ModelKind::OpenAi) {
        return Some(QuotaScopeId::CodexChatgpt);
    }
    let host = backend
        .and_then(|(url, _, _)| reqwest::Url::parse(url).ok())
        .and_then(|u| u.host_str().map(str::to_ascii_lowercase));
    (host.as_deref() == Some(FIREWORKS_HOST)).then_some(QuotaScopeId::Fireworks)
}

/// Every scope at least one CONFIGURED model maps to, with those models' ids in registry
/// order. This is exactly the set `GET /jesse/usage` reports on and refreshes.
pub fn quota_scope_models(cfg: &Config) -> BTreeMap<QuotaScopeId, Vec<String>> {
    let mut out: BTreeMap<QuotaScopeId, Vec<String>> = BTreeMap::new();
    for m in cfg.model_registry.models.iter().filter(|m| m.configured) {
        if let Some(scope) = quota_scope_for(m) {
            out.entry(scope).or_default().push(m.id.clone());
        }
    }
    out
}

// ---- Settings ---------------------------------------------------------------------

/// `[quota]` as written in `jesse.local.toml`.
#[derive(Deserialize, Debug, Default, Clone)]
pub struct QuotaToml {
    pub fireworks_account_id: Option<String>,
}

/// The resolved quota settings.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct QuotaSettings {
    /// The operator's OWN Fireworks account slug — the one that owns the API key — which is
    /// not the `accounts/fireworks/...` owner in a model slug. `None` leaves the Fireworks
    /// scope reporting [`FIREWORKS_SPEND_NOT_CONFIGURED`] and calling nothing.
    pub fireworks_account_id: Option<String>,
    /// `JESSE_QUOTA_TTL_SECS`: one TTL for every scope, replacing the per-scope defaults.
    pub ttl_override_secs: Option<u64>,
}

impl QuotaSettings {
    /// Env wins over the file: `JESSE_FIREWORKS_ACCOUNT_ID`, then `[quota]`.
    pub fn from_env(toml: Option<QuotaToml>) -> Self {
        let fireworks_account_id = env_string("JESSE_FIREWORKS_ACCOUNT_ID")
            .or_else(|| toml.and_then(|t| t.fireworks_account_id))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        QuotaSettings {
            fireworks_account_id,
            ttl_override_secs: quota_ttl_override(),
        }
    }

    pub fn ttl_secs(&self, scope: QuotaScopeId) -> u64 {
        self.ttl_override_secs
            .unwrap_or_else(|| scope.default_ttl_secs())
    }
}

/// Pure core of [`quota_ttl_override`], in the same shape as the health interval override:
/// unset or blank is `Ok(None)`, a positive integer is floored at [`QUOTA_FORCE_FLOOR_SECS`],
/// zero or garbage is `Err(raw)` so the caller warns once and falls back.
fn parse_quota_ttl_override(raw: Option<&str>) -> Result<Option<u64>, String> {
    let Some(raw) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    match raw.parse::<u64>() {
        Ok(n) if n > 0 => Ok(Some(n.max(QUOTA_FORCE_FLOOR_SECS))),
        _ => Err(raw.to_string()),
    }
}

/// `JESSE_QUOTA_TTL_SECS`, read once at startup.
pub fn quota_ttl_override() -> Option<u64> {
    match parse_quota_ttl_override(std::env::var("JESSE_QUOTA_TTL_SECS").ok().as_deref()) {
        Ok(v) => v,
        Err(raw) => {
            eprintln!(
                "jesse-bridge: WARNING JESSE_QUOTA_TTL_SECS={raw:?} is not a positive integer; \
                 ignoring it (using the per-scope defaults)."
            );
            None
        }
    }
}

// ---- The snapshot -----------------------------------------------------------------

/// One limit window: the share of it used, and when it resets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaWindow {
    pub id: String,
    pub label: String,
    /// 0 to 100.
    pub used_percent: f64,
    pub resets_at_ms: Option<i64>,
    /// The provider's own word for the window's state when it gave one (`allowed`,
    /// `allowed_warning`, `rejected`), else `None`.
    pub status: Option<String>,
}

/// Month to date spend on a pay as you go account.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaSpend {
    pub month_to_date_usd: f64,
    /// Keyed by registry id where a bucket matched a model, else by the provider's own name.
    pub by_model_usd: BTreeMap<String, f64>,
    pub period_start_ms: i64,
    /// True when any bucket's dollar figure was computed from its token counts and the
    /// model's price deck, because the provider reported no cost for it. See
    /// [`parse_fireworks_usage`].
    #[serde(default)]
    pub estimated: bool,
}

/// Where a snapshot's latest data came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaSource {
    /// A provider call made by `GET /jesse/usage`.
    Fetched,
    /// A turn that already ran reported it.
    Turn,
}

/// One scope's last known state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaSnapshot {
    #[serde(rename = "id")]
    pub scope: QuotaScopeId,
    pub windows: Vec<QuotaWindow>,
    pub spend: Option<QuotaSpend>,
    pub plan: Option<String>,
    /// When the data in this snapshot was last updated, by either source.
    pub fetched_at_ms: i64,
    pub source: QuotaSource,
    /// The last failure's content free text, kept beside the last good data rather than
    /// replacing it.
    pub error: Option<String>,
    /// Any window at or above [`QUOTA_WARNING_PERCENT`], or any window `rejected`.
    pub warning: bool,
}

impl QuotaSnapshot {
    pub fn new(scope: QuotaScopeId, fetched_at_ms: i64, source: QuotaSource) -> Self {
        QuotaSnapshot {
            scope,
            windows: Vec::new(),
            spend: None,
            plan: None,
            fetched_at_ms,
            source,
            error: None,
            warning: false,
        }
    }

    fn refresh_warning(&mut self) {
        self.warning = self.windows.iter().any(|w| {
            w.used_percent >= QUOTA_WARNING_PERCENT || w.status.as_deref() == Some("rejected")
        });
    }

    /// **THE SPARSE MERGE.** A field absent from the patch never clears a stored value; a
    /// present one replaces it. That is the Codex notification contract verbatim ("nullable
    /// metadata missing from an update does not clear a previously observed value"), and it
    /// is what keeps a Claude `rate_limit_event` that carries only `status: "allowed"` from
    /// zeroing a percentage the last fetch knew.
    ///
    /// A window the snapshot has never seen is created only when the patch carries its
    /// percentage: inventing a 0 for a window nobody measured would be a number on screen
    /// that nothing reported.
    ///
    /// `fetched_at_ms` and `source` move on every merge.
    pub fn apply(&mut self, patch: QuotaPatch, source: QuotaSource, now_ms: i64) {
        for wp in patch.windows {
            match self.windows.iter_mut().find(|w| w.id == wp.id) {
                Some(w) => {
                    if let Some(label) = wp.label {
                        w.label = label;
                    }
                    if let Some(p) = wp.used_percent {
                        w.used_percent = p;
                    }
                    if let Some(r) = wp.resets_at_ms {
                        w.resets_at_ms = Some(r);
                    }
                    if let Some(s) = wp.status {
                        w.status = Some(s);
                    }
                }
                None => {
                    let Some(used_percent) = wp.used_percent else {
                        continue;
                    };
                    self.windows.push(QuotaWindow {
                        label: wp.label.unwrap_or_else(|| window_label(&wp.id)),
                        id: wp.id,
                        used_percent,
                        resets_at_ms: wp.resets_at_ms,
                        status: wp.status,
                    });
                }
            }
        }
        if let Some(plan) = patch.plan {
            self.plan = Some(plan);
        }
        if let Some(spend) = patch.spend {
            self.spend = Some(spend);
        }
        self.fetched_at_ms = now_ms;
        self.source = source;
        self.refresh_warning();
    }
}

/// A partial update: every field optional, so absence is distinguishable from a value.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QuotaPatch {
    pub windows: Vec<QuotaWindowPatch>,
    pub plan: Option<String>,
    pub spend: Option<QuotaSpend>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct QuotaWindowPatch {
    pub id: String,
    pub label: Option<String>,
    pub used_percent: Option<f64>,
    pub resets_at_ms: Option<i64>,
    pub status: Option<String>,
}

impl QuotaPatch {
    /// Fold one window's fields into the patch, merging into an entry with the same id.
    fn upsert(
        &mut self,
        id: &str,
        used_percent: Option<f64>,
        resets_at_ms: Option<i64>,
        status: Option<String>,
    ) {
        match self.windows.iter_mut().find(|w| w.id == id) {
            Some(w) => {
                w.used_percent = used_percent.or(w.used_percent);
                w.resets_at_ms = resets_at_ms.or(w.resets_at_ms);
                w.status = status.or(w.status.take());
            }
            None => self.windows.push(QuotaWindowPatch {
                id: id.to_string(),
                label: None,
                used_percent,
                resets_at_ms,
                status,
            }),
        }
    }
}

/// The label a window gets when nothing more specific named it.
pub fn window_label(id: &str) -> String {
    match id {
        "five_hour" => "5 hours".to_string(),
        "seven_day" => "7 days".to_string(),
        "extra_usage" => "extra usage".to_string(),
        other => match other.strip_prefix("seven_day_") {
            Some("opus") => "Opus".to_string(),
            Some("sonnet") => "Sonnet".to_string(),
            Some("oauth_apps") => "OAuth apps".to_string(),
            Some(rest) => capitalize(&rest.replace('_', " ")),
            None => other.replace('_', " "),
        },
    }
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(first) => first.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// A 0 to 1 fraction as a percentage, rounded to two decimals so `0.85` is `85.0` rather than
/// `85.00000000000001`.
fn fraction_to_percent(f: f64) -> f64 {
    (f * 10_000.0).round() / 100.0
}

/// What `GET /jesse/usage` returns per scope, and what rides a turn's provenance: the
/// snapshot, plus the scope's label, the models it covers and its TTL (so a client can say
/// `stale` without hardcoding the bridge's numbers).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaEntry {
    #[serde(flatten)]
    pub snapshot: QuotaSnapshot,
    pub label: String,
    pub models: Vec<String>,
    pub ttl_secs: u64,
}

// ---- Failure vocabulary -----------------------------------------------------------

/// Why a fetch produced no snapshot. Classes only: no variant carries a response body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QuotaError {
    NotLoggedIn,
    LoginExpired,
    /// The Claude login lacks `user:profile` (a 403 from the usage endpoint).
    ScopeMissing,
    /// A 403 from a provider whose key is valid for inference but not for usage.
    Forbidden,
    RateLimited {
        retry_after_secs: u64,
    },
    Http(u16),
    Timeout,
    Transport,
    Protocol,
    NotConfigured,
}

impl QuotaError {
    /// The log class, in the style of the health prober's error classes.
    pub fn class(&self) -> String {
        match self {
            QuotaError::NotLoggedIn => "not-logged-in".into(),
            QuotaError::LoginExpired => "login-expired".into(),
            QuotaError::ScopeMissing => "scope-missing".into(),
            QuotaError::Forbidden => "forbidden".into(),
            QuotaError::RateLimited { .. } => "rate-limited".into(),
            QuotaError::Http(code) => format!("http-{code}"),
            QuotaError::Timeout => "timeout".into(),
            QuotaError::Transport => "transport".into(),
            QuotaError::Protocol => "protocol".into(),
            QuotaError::NotConfigured => "not-configured".into(),
        }
    }

    /// The user facing text the snapshot's `error` carries. No dash characters, ever: these
    /// strings reach a menu subtitle.
    pub fn message(&self) -> String {
        match self {
            QuotaError::NotLoggedIn => "not logged in".into(),
            QuotaError::LoginExpired => CLAUDE_LOGIN_EXPIRED.into(),
            QuotaError::ScopeMissing => "login lacks the user:profile scope".into(),
            QuotaError::Forbidden => "this key may not read usage".into(),
            QuotaError::RateLimited { .. } => "usage check rate limited, trying again later".into(),
            QuotaError::Http(code) => format!("usage check failed (HTTP {code})"),
            QuotaError::Timeout => "usage check timed out".into(),
            QuotaError::Transport => "could not reach the provider".into(),
            QuotaError::Protocol => "unexpected usage response".into(),
            QuotaError::NotConfigured => FIREWORKS_SPEND_NOT_CONFIGURED.into(),
        }
    }
}

fn transport_error(e: &reqwest::Error) -> QuotaError {
    if e.is_timeout() {
        QuotaError::Timeout
    } else {
        QuotaError::Transport
    }
}

// ---- The store --------------------------------------------------------------------

/// The decision the refresh rule makes, pure so its three clocks are testable.
///
/// A scope refetches when BOTH its data and its last attempt are older than the threshold —
/// the TTL, or [`QUOTA_FORCE_FLOOR_SECS`] under `?force=1` — and never inside a 429 backoff.
/// Checking the attempt as well as the data is what stops a scope whose provider is failing
/// from being re-asked on every Settings poll: a failure keeps the old data (so the data
/// clock says stale) but stamps the attempt.
pub fn needs_fetch(
    fetched_at_ms: Option<i64>,
    attempted_ms: Option<i64>,
    backoff_until_ms: Option<i64>,
    ttl_secs: u64,
    force: bool,
    now_ms: i64,
) -> bool {
    if backoff_until_ms.is_some_and(|until| now_ms < until) {
        return false;
    }
    let threshold_ms = (if force {
        QUOTA_FORCE_FLOOR_SECS.min(ttl_secs)
    } else {
        ttl_secs
    } as i64)
        * 1000;
    let old = |t: Option<i64>| t.is_none_or(|t| now_ms.saturating_sub(t) >= threshold_ms);
    old(fetched_at_ms) && old(attempted_ms)
}

#[derive(Default)]
struct StoreState {
    snapshots: HashMap<QuotaScopeId, QuotaSnapshot>,
    attempted_ms: HashMap<QuotaScopeId, i64>,
    backoff_until_ms: HashMap<QuotaScopeId, i64>,
}

/// One snapshot per scope, the per-scope single flight guard, and the fetch seam. Shared
/// behind an `Arc` in `AppState`, beside the health store.
pub struct QuotaStore {
    state: Mutex<StoreState>,
    /// One async lock per scope. Concurrent callers of a stale scope queue here, and the one
    /// that fetches leaves a fresh snapshot the others find on their re-check.
    flights: HashMap<QuotaScopeId, AsyncMutex<()>>,
    fetcher: Arc<dyn QuotaFetcher>,
}

impl Default for QuotaStore {
    fn default() -> Self {
        QuotaStore::new()
    }
}

impl QuotaStore {
    /// The production store: the live fetcher behind it, nothing fetched yet.
    pub fn new() -> Self {
        QuotaStore::with_fetcher(Arc::new(LiveQuotaFetcher::new()))
    }

    /// A store over any fetcher — the seam the tests drive with no network.
    pub fn with_fetcher(fetcher: Arc<dyn QuotaFetcher>) -> Self {
        QuotaStore {
            state: Mutex::new(StoreState::default()),
            flights: QuotaScopeId::ALL
                .iter()
                .map(|s| (*s, AsyncMutex::new(())))
                .collect(),
            fetcher,
        }
    }

    pub fn get(&self, scope: QuotaScopeId) -> Option<QuotaSnapshot> {
        self.state.lock_ok().snapshots.get(&scope).cloned()
    }

    /// The passive path: fold a partial report into the scope's snapshot. See
    /// [`QuotaSnapshot::apply`] for the rules.
    pub fn merge_sparse(
        &self,
        scope: QuotaScopeId,
        patch: QuotaPatch,
        source: QuotaSource,
        now_ms: i64,
    ) {
        let mut st = self.state.lock_ok();
        st.snapshots
            .entry(scope)
            .or_insert_with(|| QuotaSnapshot::new(scope, now_ms, source))
            .apply(patch, source, now_ms);
    }

    /// A complete fetched snapshot replaces what was there, error and all.
    pub fn replace(&self, mut snapshot: QuotaSnapshot) {
        snapshot.error = None;
        snapshot.refresh_warning();
        self.state
            .lock_ok()
            .snapshots
            .insert(snapshot.scope, snapshot);
    }

    /// A failure keeps the last good data and sets `error` beside it. A scope with no data
    /// yet gets an empty snapshot stamped with this attempt, so the card can say when it
    /// last tried.
    pub fn record_error(&self, scope: QuotaScopeId, message: &str, now_ms: i64) {
        let mut st = self.state.lock_ok();
        let snap = st
            .snapshots
            .entry(scope)
            .or_insert_with(|| QuotaSnapshot::new(scope, now_ms, QuotaSource::Fetched));
        snap.error = Some(message.to_string());
    }

    fn is_due(&self, scope: QuotaScopeId, cfg: &Config, force: bool, now_ms: i64) -> bool {
        let st = self.state.lock_ok();
        needs_fetch(
            st.snapshots.get(&scope).map(|s| s.fetched_at_ms),
            st.attempted_ms.get(&scope).copied(),
            st.backoff_until_ms.get(&scope).copied(),
            cfg.quota.ttl_secs(scope),
            force,
            now_ms,
        )
    }

    /// **THE ON DEMAND PATH**, and the only place a provider is called. A no-op unless the
    /// scope is due ([`needs_fetch`]); otherwise one fetch, shared by every concurrent
    /// caller, bounded by the scope's own timeout. Returns whether this call fetched.
    ///
    /// The Fireworks scope without an account id is decided here, BEFORE the fetcher: it
    /// records [`FIREWORKS_SPEND_NOT_CONFIGURED`] and the fetcher is never invoked.
    pub async fn ensure_fresh(
        &self,
        scope: QuotaScopeId,
        cfg: &Config,
        force: bool,
        now_ms: i64,
    ) -> bool {
        if !self.is_due(scope, cfg, force, now_ms) {
            return false;
        }
        let Some(flight) = self.flights.get(&scope) else {
            return false;
        };
        let _flight = flight.lock().await;
        // THE SINGLE FLIGHT. Whoever held the lock before this caller may have just fetched,
        // and a fresh snapshot is the answer this caller was waiting for.
        if !self.is_due(scope, cfg, force, now_ms) {
            return false;
        }
        self.state.lock_ok().attempted_ms.insert(scope, now_ms);
        if scope == QuotaScopeId::Fireworks && cfg.quota.fireworks_account_id.is_none() {
            self.record_error(scope, FIREWORKS_SPEND_NOT_CONFIGURED, now_ms);
            return false;
        }
        eprintln!("jesse-bridge: quota {scope}: provider request");
        let outcome = match timeout(scope.fetch_timeout(), self.fetcher.fetch(scope, cfg)).await {
            Ok(r) => r,
            Err(_) => Err(QuotaError::Timeout),
        };
        match outcome {
            Ok(mut snapshot) => {
                eprintln!("jesse-bridge: quota {scope}: ok");
                snapshot.scope = scope;
                snapshot.fetched_at_ms = now_ms;
                snapshot.source = QuotaSource::Fetched;
                self.replace(snapshot);
                true
            }
            Err(e) => {
                eprintln!("jesse-bridge: quota {scope}: {}", e.class());
                if let QuotaError::RateLimited { retry_after_secs } = e {
                    let wait = retry_after_secs.max(QUOTA_RATE_LIMIT_FLOOR_SECS) as i64;
                    self.state
                        .lock_ok()
                        .backoff_until_ms
                        .insert(scope, now_ms + wait * 1000);
                }
                self.record_error(scope, &e.message(), now_ms);
                false
            }
        }
    }

    /// One scope's wire entry, or `None` when no configured model maps to it.
    pub fn entry(&self, scope: QuotaScopeId, cfg: &Config) -> Option<QuotaEntry> {
        let models = quota_scope_models(cfg).remove(&scope)?;
        let snapshot = self
            .get(scope)
            .unwrap_or_else(|| QuotaSnapshot::new(scope, 0, QuotaSource::Fetched));
        Some(QuotaEntry {
            snapshot,
            label: scope.label().to_string(),
            models,
            ttl_secs: cfg.quota.ttl_secs(scope),
        })
    }

    /// Every configured scope's entry, in scope order.
    pub fn entries(&self, cfg: &Config) -> Vec<QuotaEntry> {
        quota_scope_models(cfg)
            .into_keys()
            .filter_map(|s| self.entry(s, cfg))
            .collect()
    }
}

/// Unix millis now, for the store's clocks.
pub fn quota_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ---- The fetch seam ---------------------------------------------------------------

/// The mockable network seam, the same shape as the health prober's [`HealthProbe`].
pub trait QuotaFetcher: Send + Sync {
    fn fetch<'a>(
        &'a self,
        scope: QuotaScopeId,
        cfg: &'a Config,
    ) -> Pin<Box<dyn Future<Output = Result<QuotaSnapshot, QuotaError>> + Send + 'a>>;
}

/// The production fetcher: one `reqwest::Client`, built the way `ReqwestProbe` builds its own.
pub struct LiveQuotaFetcher {
    client: reqwest::Client,
}

impl LiveQuotaFetcher {
    pub fn new() -> Self {
        LiveQuotaFetcher {
            client: reqwest::Client::builder().build().unwrap_or_default(),
        }
    }
}

impl Default for LiveQuotaFetcher {
    fn default() -> Self {
        LiveQuotaFetcher::new()
    }
}

impl QuotaFetcher for LiveQuotaFetcher {
    fn fetch<'a>(
        &'a self,
        scope: QuotaScopeId,
        cfg: &'a Config,
    ) -> Pin<Box<dyn Future<Output = Result<QuotaSnapshot, QuotaError>> + Send + 'a>> {
        Box::pin(async move {
            match scope {
                QuotaScopeId::ClaudeSubscription => fetch_claude(&self.client, cfg).await,
                QuotaScopeId::CodexChatgpt => fetch_codex(cfg).await,
                QuotaScopeId::Fireworks => fetch_fireworks(&self.client, cfg).await,
            }
        })
    }
}

// ---- Claude: the OAuth usage endpoint ---------------------------------------------

/// The parts of the Claude login this module uses. Deliberately NOT `Debug`: the token must
/// not be one `{:?}` away from a log line.
struct ClaudeCredential {
    token: String,
    expires_at_ms: Option<i64>,
    scopes: Vec<String>,
    plan: Option<String>,
}

/// `claudeAiOauth` out of a credential document, or `None` when it has none. A keychain item
/// carrying only `mcpOAuth` is exactly that: no Claude login.
fn parse_claude_credential(doc: &Value) -> Option<ClaudeCredential> {
    let o = doc.get("claudeAiOauth")?;
    let token = o.get("accessToken")?.as_str()?.to_string();
    if token.is_empty() {
        return None;
    }
    Some(ClaudeCredential {
        token,
        expires_at_ms: o.get("expiresAt").and_then(Value::as_i64),
        scopes: o
            .get("scopes")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
        plan: o
            .get("subscriptionType")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

/// The checks that need no request: an expired token and a missing scope are both knowable
/// from the credential, and asking the endpoint to confirm them would only spend a call.
fn check_claude_credential(c: &ClaudeCredential, now_ms: i64) -> Result<(), QuotaError> {
    if c.expires_at_ms.is_some_and(|e| e <= now_ms) {
        return Err(QuotaError::LoginExpired);
    }
    if !c.scopes.is_empty() && !c.scopes.iter().any(|s| s == CLAUDE_PROFILE_SCOPE) {
        return Err(QuotaError::ScopeMissing);
    }
    Ok(())
}

/// The account name the keychain item is filed under: the login user.
fn login_user(cfg: &Config) -> Option<String> {
    ["USER", "LOGNAME"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|s| !s.trim().is_empty()))
        .or_else(|| {
            Path::new(&cfg.home)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
        })
}

/// Read the Claude login, READ ONLY, in the order Claude Code itself stores it.
///
/// 1. The login keychain's generic password `Claude Code-credentials` filed under the login
///    user, through the `security` CLI with a 5 second budget. The ACCOUNT MATTERS: measured
///    on the Studio 2026-09-12, the same service also holds items filed under other accounts
///    (`unknown`, and two `handoff-decryption-key-*`), and `security` without `-a` returned
///    the `unknown` one, whose token had expired 46 days earlier. The live login was the item
///    filed under the user name.
/// 2. `~/.claude/.credentials.json`, the file Claude Code uses where there is no keychain.
///
/// A prompt, a denial, a timeout or a missing item all fall through, and the end of the road
/// is `NotLoggedIn` — never a crash, never a hang.
async fn read_claude_credential(cfg: &Config) -> Result<ClaudeCredential, QuotaError> {
    if let Some(user) = login_user(cfg) {
        let mut cmd = Command::new("security");
        cmd.args([
            "find-generic-password",
            "-s",
            CLAUDE_CREDENTIALS_SERVICE,
            "-a",
            &user,
            "-w",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
        if let Ok(Ok(out)) = timeout(Duration::from_secs(KEYCHAIN_TIMEOUT_SECS), cmd.output()).await
        {
            if out.status.success() {
                if let Some(c) = serde_json::from_slice::<Value>(&out.stdout)
                    .ok()
                    .as_ref()
                    .and_then(parse_claude_credential)
                {
                    return Ok(c);
                }
            }
        }
    }
    let file = Path::new(&cfg.home)
        .join(".claude")
        .join(".credentials.json");
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .as_ref()
        .and_then(parse_claude_credential)
        .ok_or(QuotaError::NotLoggedIn)
}

/// The installed `claude` version, for the `User-Agent` the usage endpoint expects. Read once
/// per process from `cfg.claude_bin --version` (first token of `2.1.268 (Claude Code)`); a
/// failed read is not cached, so a later call can still succeed.
async fn claude_cli_version(cfg: &Config) -> String {
    static VERSION: OnceLock<String> = OnceLock::new();
    if let Some(v) = VERSION.get() {
        return v.clone();
    }
    let mut cmd = Command::new(&cfg.claude_bin);
    cmd.arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let read = timeout(Duration::from_secs(KEYCHAIN_TIMEOUT_SECS), cmd.output())
        .await
        .ok()
        .and_then(|r| r.ok())
        .filter(|o| o.status.success())
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split_whitespace()
                .next()
                .map(str::to_string)
        });
    match read {
        Some(v) => VERSION.get_or_init(|| v).clone(),
        None => "unknown".to_string(),
    }
}

/// Seconds a 429 asked for, from `Retry-After`, or 0 when it said nothing usable. The store
/// floors whatever this returns at [`QUOTA_RATE_LIMIT_FLOOR_SECS`].
fn retry_after_secs(headers: &reqwest::header::HeaderMap) -> u64 {
    headers
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0)
}

/// `GET https://api.anthropic.com/api/oauth/usage` with the bridge's own login.
pub async fn fetch_claude(
    client: &reqwest::Client,
    cfg: &Config,
) -> Result<QuotaSnapshot, QuotaError> {
    let now = quota_now_ms();
    let cred = read_claude_credential(cfg).await?;
    check_claude_credential(&cred, now)?;
    let version = claude_cli_version(cfg).await;
    let resp = client
        .get(CLAUDE_USAGE_URL)
        .timeout(Duration::from_secs(CLAUDE_FETCH_TIMEOUT_SECS))
        .header("authorization", format!("Bearer {}", cred.token))
        .header("anthropic-beta", CLAUDE_OAUTH_BETA)
        .header("accept", "application/json")
        .header("user-agent", format!("claude-code/{version}"))
        .send()
        .await
        .map_err(|e| transport_error(&e))?;
    let status = resp.status().as_u16();
    match status {
        200..=299 => {}
        401 => return Err(QuotaError::NotLoggedIn),
        403 => return Err(QuotaError::ScopeMissing),
        429 => {
            return Err(QuotaError::RateLimited {
                retry_after_secs: retry_after_secs(resp.headers()),
            })
        }
        code => return Err(QuotaError::Http(code)),
    }
    let body = resp.bytes().await.map_err(|e| transport_error(&e))?;
    let v: Value = serde_json::from_slice(&body).map_err(|_| QuotaError::Protocol)?;
    Ok(parse_claude_usage(&v, cred.plan, now))
}

/// Map a usage endpoint body onto the snapshot.
///
/// **`utilization` IS A 0 TO 100 PERCENTAGE on this endpoint**, observed live on 2026-09-12:
/// `five_hour.utilization` was `8.0` and `seven_day.utilization` `27.0`, and the same body's
/// `limits[].percent` read `8` and `27` for the same windows. It is used as is. (The
/// `rate_limit_event` a turn writes reports the SAME windows as 0 to 1 fractions — `0.08` and
/// `0.27` in the turn captured the same morning — which is why the two parsers convert
/// differently, and why neither guesses.)
///
/// Windows, in order: `five_hour` (`5 hours`), `seven_day` (`7 days`), every non-null
/// `seven_day_<x>` (labelled by the model it names), every ACTIVE `limits` entry scoped to a
/// model (labelled by its display name), and `extra_usage` when it is enabled. The unlabelled
/// codename objects the endpoint also returns (`nimbus_quill` and friends) are ignored: a
/// window nobody can name is not something to show.
pub fn parse_claude_usage(v: &Value, plan: Option<String>, now_ms: i64) -> QuotaSnapshot {
    let mut snap = QuotaSnapshot::new(
        QuotaScopeId::ClaudeSubscription,
        now_ms,
        QuotaSource::Fetched,
    );
    snap.plan = plan;
    let mut push = |id: String, label: String, obj: &Value| {
        let Some(used) = obj.get("utilization").and_then(Value::as_f64) else {
            return;
        };
        snap.windows.push(QuotaWindow {
            id,
            label,
            used_percent: used,
            resets_at_ms: obj
                .get("resets_at")
                .and_then(Value::as_str)
                .and_then(parse_iso8601_ms),
            status: None,
        });
    };
    for key in ["five_hour", "seven_day"] {
        if let Some(obj) = v.get(key).filter(|o| o.is_object()) {
            push(key.to_string(), window_label(key), obj);
        }
    }
    if let Some(map) = v.as_object() {
        for (key, obj) in map {
            if key.starts_with("seven_day_") && obj.is_object() {
                push(key.clone(), window_label(key), obj);
            }
        }
    }
    for limit in v
        .get("limits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if limit.get("is_active").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let Some(name) = limit
            .get("scope")
            .and_then(|s| s.get("model"))
            .and_then(|m| m.get("display_name"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        let kind = limit.get("kind").and_then(Value::as_str).unwrap_or("limit");
        let obj = json!({
            "utilization": limit.get("percent").and_then(Value::as_f64),
            "resets_at": limit.get("resets_at"),
        });
        let slug = name.to_ascii_lowercase().replace(' ', "_");
        push(format!("{kind}_{slug}"), name.to_string(), &obj);
    }
    if let Some(extra) = v
        .get("extra_usage")
        .filter(|e| e.get("is_enabled").and_then(Value::as_bool) == Some(true))
    {
        let computed = match (
            extra.get("used_credits").and_then(Value::as_f64),
            extra.get("monthly_limit").and_then(Value::as_f64),
        ) {
            (Some(used), Some(limit)) if limit > 0.0 => Some(used / limit * 100.0),
            _ => None,
        };
        if let Some(used) = extra
            .get("utilization")
            .and_then(Value::as_f64)
            .or(computed)
        {
            snap.windows.push(QuotaWindow {
                id: "extra_usage".to_string(),
                label: window_label("extra_usage"),
                used_percent: used,
                resets_at_ms: None,
                status: None,
            });
        }
    }
    snap.refresh_warning();
    snap
}

/// Unix millis from an ISO 8601 timestamp: `YYYY-MM-DDTHH:MM:SS`, an optional fraction, and
/// `Z`, `+HH:MM`, `-HH:MM` or nothing (read as UTC). The usage endpoint writes
/// `2026-09-12T11:30:00.965545+00:00`.
pub fn parse_iso8601_ms(raw: &str) -> Option<i64> {
    let s = raw.trim();
    let base_secs = parse_rfc3339_secs(s)?;
    let mut rest = s.get(19..)?;
    let mut millis = 0i64;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits = frac.chars().take_while(char::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        let first3 = &frac[..digits.min(3)];
        millis = format!("{first3:0<3}").parse().ok()?;
        rest = &frac[digits..];
    }
    let offset_secs = match rest {
        "" | "Z" | "z" => 0,
        r if r.len() == 6 && (r.starts_with('+') || r.starts_with('-')) && &r[3..4] == ":" => {
            let h: i64 = r[1..3].parse().ok()?;
            let m: i64 = r[4..6].parse().ok()?;
            let secs = h * 3600 + m * 60;
            if r.starts_with('-') {
                -secs
            } else {
                secs
            }
        }
        _ => return None,
    };
    Some((base_secs - offset_secs) * 1000 + millis)
}

// ---- Claude: the rate_limit_event a turn writes -----------------------------------

/// One `rate_limit_event` line's `rate_limit_info`, as the `claude` child writes it on a
/// subscription login (Claude Code 2.1.45 and later).
///
/// Only `status` is guaranteed. `utilization` (a 0 to 1 FRACTION) was documented as present
/// only on `allowed_warning` and `rejected`; `unifiedWindows` is what 2.1.268 actually wrote
/// on an ordinary `allowed` turn on 2026-09-12 — every window's fraction and reset, which is
/// why a turn can refresh the percentages for free rather than only flag a warning.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RateLimitEventInfo {
    /// `allowed`, `allowed_warning` or `rejected`.
    pub status: String,
    /// Unix seconds.
    pub resets_at: Option<i64>,
    /// `five_hour`, `seven_day`, …
    pub rate_limit_type: Option<String>,
    /// 0 to 1.
    pub utilization: Option<f64>,
    pub is_using_overage: Option<bool>,
    pub overage_status: Option<String>,
    pub overage_disabled_reason: Option<String>,
    /// `(window id, utilization 0 to 1, resets at unix seconds)`, from `unifiedWindows`.
    pub unified_windows: Vec<(String, Option<f64>, Option<i64>)>,
}

impl RateLimitEventInfo {
    /// Parse `rate_limit_info`, or `None` when it names no status.
    pub fn from_value(info: &Value) -> Option<Self> {
        let s = |k: &str| info.get(k).and_then(Value::as_str).map(str::to_string);
        Some(RateLimitEventInfo {
            status: s("status")?,
            resets_at: info.get("resetsAt").and_then(Value::as_i64),
            rate_limit_type: s("rateLimitType"),
            utilization: info.get("utilization").and_then(Value::as_f64),
            is_using_overage: info.get("isUsingOverage").and_then(Value::as_bool),
            overage_status: s("overageStatus"),
            overage_disabled_reason: s("overageDisabledReason"),
            unified_windows: info
                .get("unifiedWindows")
                .and_then(Value::as_object)
                .map(|m| {
                    m.iter()
                        .filter(|(_, w)| w.is_object())
                        .map(|(k, w)| {
                            (
                                k.clone(),
                                w.get("utilization").and_then(Value::as_f64),
                                w.get("resetsAt").and_then(Value::as_i64),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default(),
        })
    }

    /// The sparse patch this event is worth: every unified window's percentage and reset,
    /// then the typed window's percentage (when present), reset and status. A field the event
    /// did not carry stays absent, so the merge leaves it alone.
    pub fn to_patch(&self) -> QuotaPatch {
        let mut patch = QuotaPatch::default();
        for (id, utilization, resets_at) in &self.unified_windows {
            patch.upsert(
                id,
                utilization.map(fraction_to_percent),
                resets_at.map(|s| s * 1000),
                None,
            );
        }
        if let Some(kind) = &self.rate_limit_type {
            patch.upsert(
                kind,
                self.utilization.map(fraction_to_percent),
                self.resets_at.map(|s| s * 1000),
                Some(self.status.clone()),
            );
        }
        patch
    }
}

// ---- Codex: the App Server's rate limits ------------------------------------------

/// The label for a Codex window, from its length.
fn codex_window_label(id: &str, mins: Option<i64>) -> String {
    match mins {
        Some(300) => "5 hours".to_string(),
        Some(10080) => "7 days".to_string(),
        Some(n) => format!("{n} min"),
        None => id.to_string(),
    }
}

/// A `rateLimits` object — from the `account/rateLimits/read` response or an
/// `account/rateLimits/updated` notification, which share the shape — as a sparse patch.
/// `primary` and `secondary` become windows of those ids; a null one is simply absent.
/// `usedPercent` is an integer 0 to 100 and `resetsAt` Unix seconds.
pub fn codex_rate_limits_patch(rate_limits: &Value) -> QuotaPatch {
    let mut patch = QuotaPatch {
        plan: rate_limits
            .get("planType")
            .and_then(Value::as_str)
            .map(str::to_string),
        ..QuotaPatch::default()
    };
    for id in ["primary", "secondary"] {
        let Some(w) = rate_limits.get(id).filter(|w| w.is_object()) else {
            continue;
        };
        patch.windows.push(QuotaWindowPatch {
            id: id.to_string(),
            label: Some(codex_window_label(
                id,
                w.get("windowDurationMins").and_then(Value::as_i64),
            )),
            used_percent: w.get("usedPercent").and_then(Value::as_f64),
            resets_at_ms: w.get("resetsAt").and_then(Value::as_i64).map(|s| s * 1000),
            status: None,
        });
    }
    patch
}

/// Whether the canonical Codex home holds a ChatGPT login. Reads `auth.json` for its mode and
/// nothing else, and copies nothing: a missing file, an unreadable one, or an API key account
/// is `NotLoggedIn`.
pub fn codex_login_state(home: &Path) -> Result<(), QuotaError> {
    let raw = std::fs::read(home.join("auth.json")).map_err(|_| QuotaError::NotLoggedIn)?;
    let v: Value = serde_json::from_slice(&raw).map_err(|_| QuotaError::NotLoggedIn)?;
    let mode = v
        .get("auth_mode")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let has_tokens = v.get("tokens").is_some_and(Value::is_object);
    if mode.replace('_', "") == "apikey" || !has_tokens {
        return Err(QuotaError::NotLoggedIn);
    }
    Ok(())
}

/// Ask a fresh `codex app-server` for the ChatGPT account's rate limits.
///
/// The child runs against the CANONICAL home (`$CODEX_HOME` or `~/.codex`, where `codex login`
/// wrote), not a per-turn one, because this reads the account rather than running a turn: no
/// `thread/start`, no `turn/start`, no model call, and none of the containment overrides a
/// turn's argv carries — there is nothing for them to contain. The exchange is `initialize`,
/// `initialized`, `account/rateLimits/read`; then stdin closes, the child gets 2 seconds to
/// exit, and it is killed. The store bounds the whole call at 15 seconds, and a dropped
/// future kills the child too (`kill_on_drop`).
pub async fn fetch_codex(cfg: &Config) -> Result<QuotaSnapshot, QuotaError> {
    let home = codex_canonical_home(cfg);
    codex_login_state(&home)?;
    let mut child = Command::new(&cfg.codex_bin)
        .args(["app-server", "--listen", "stdio://"])
        .env("CODEX_HOME", &home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| QuotaError::Transport)?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Err(QuotaError::Protocol);
    };
    // Consumes stdin: when this returns the pipe is closed, which is the child's cue to exit.
    let result = read_account_rate_limits(stdin, stdout).await;
    if timeout(Duration::from_secs(CODEX_EXIT_GRACE_SECS), child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
    }
    let v = result.map_err(|message| {
        // Classified, never logged: the server's words can carry account detail.
        let m = message.to_ascii_lowercase();
        if m.contains("401") || m.contains("unauthorized") || m.contains("login") {
            QuotaError::NotLoggedIn
        } else {
            QuotaError::Protocol
        }
    })?;
    let rate_limits = v.get("rateLimits").ok_or(QuotaError::Protocol)?;
    let now = quota_now_ms();
    let mut snap = QuotaSnapshot::new(QuotaScopeId::CodexChatgpt, now, QuotaSource::Fetched);
    snap.apply(
        codex_rate_limits_patch(rate_limits),
        QuotaSource::Fetched,
        now,
    );
    Ok(snap)
}

// ---- Fireworks: month to date spend -----------------------------------------------

/// A Fireworks-scope model, reduced to what matching a billing bucket back to it needs.
#[derive(Debug, Clone)]
pub struct FireworksModelRef {
    pub id: String,
    pub slug: String,
    pub price: PriceDeck,
}

/// The configured Fireworks-scope models, in registry order.
fn fireworks_models(cfg: &Config) -> Vec<(FireworksModelRef, String)> {
    cfg.model_registry
        .models
        .iter()
        .filter(|m| m.configured && quota_scope_for(m) == Some(QuotaScopeId::Fireworks))
        .filter_map(|m| {
            let (_, token, slug) = m.backend.as_ref()?;
            Some((
                FireworksModelRef {
                    id: m.id.clone(),
                    slug: slug.clone(),
                    price: m.price,
                },
                token.clone(),
            ))
        })
        .collect()
}

/// The first instant of the current UTC month, in millis.
pub fn month_start_utc_ms(now_ms: i64) -> i64 {
    let (y, m, _) = civil_from_days(now_ms.div_euclid(86_400_000));
    civil_days((y, i64::from(m), 1)) * 86_400_000
}

fn rfc3339_from_ms(ms: i64) -> String {
    rfc3339_utc(UNIX_EPOCH + Duration::from_millis(ms.max(0) as u64))
}

/// An account slug is `[A-Za-z0-9_-]`; anything else never reaches a URL path.
fn valid_account_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `GET /v1/accounts/{account_id}/billingUsage` for the current UTC month, serverless only,
/// grouped by `model_name` (the parameter is `groupBy`, an exploded array, per
/// <https://docs.fireworks.ai/api-reference/get-billing-usage>, read 2026-09-12). The bearer
/// token is the first Fireworks-scope model's own key.
pub async fn fetch_fireworks(
    client: &reqwest::Client,
    cfg: &Config,
) -> Result<QuotaSnapshot, QuotaError> {
    let account = cfg
        .quota
        .fireworks_account_id
        .as_deref()
        .filter(|a| valid_account_id(a))
        .ok_or(QuotaError::NotConfigured)?;
    let models = fireworks_models(cfg);
    let token = models
        .first()
        .map(|(_, t)| t.clone())
        .ok_or(QuotaError::NotLoggedIn)?;
    let now = quota_now_ms();
    let start = month_start_utc_ms(now);
    let resp = client
        .get(format!(
            "{FIREWORKS_API_BASE}/v1/accounts/{account}/billingUsage"
        ))
        .query(&[
            ("startTime", rfc3339_from_ms(start)),
            ("endTime", rfc3339_from_ms(now)),
            ("usageType", "SERVERLESS".to_string()),
            ("groupBy", "model_name".to_string()),
        ])
        .timeout(Duration::from_secs(FIREWORKS_FETCH_TIMEOUT_SECS))
        .header("authorization", format!("Bearer {token}"))
        .header("accept", "application/json")
        .send()
        .await
        .map_err(|e| transport_error(&e))?;
    match resp.status().as_u16() {
        200..=299 => {}
        401 => return Err(QuotaError::NotLoggedIn),
        403 => return Err(QuotaError::Forbidden),
        429 => {
            return Err(QuotaError::RateLimited {
                retry_after_secs: retry_after_secs(resp.headers()),
            })
        }
        code => return Err(QuotaError::Http(code)),
    }
    let body = resp.bytes().await.map_err(|e| transport_error(&e))?;
    let v: Value = serde_json::from_slice(&body).map_err(|_| QuotaError::Protocol)?;
    let refs: Vec<FireworksModelRef> = models.into_iter().map(|(r, _)| r).collect();
    let mut snap = QuotaSnapshot::new(QuotaScopeId::Fireworks, now, QuotaSource::Fetched);
    snap.spend = Some(parse_fireworks_usage(&v, &refs, start));
    Ok(snap)
}

/// A number that may arrive as a JSON number or, for the int64 counts, a JSON string.
fn loose_f64(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Whether a billing bucket's model name is this registry slug: equal, or equal in its last
/// path segment (`accounts/fireworks/models/glm-5p3` against `glm-5p3`).
fn slug_matches(slug: &str, name: &str) -> bool {
    let last = |s: &str| s.rsplit('/').next().unwrap_or(s).to_ascii_lowercase();
    slug.eq_ignore_ascii_case(name) || last(slug) == last(name)
}

/// Sum `serverlessCosts[]` into month to date spend, keyed back to registry ids.
///
/// **`costNanoUsd` MAY BE ZERO FOR REAL SPEND.** The schema says so in as many words: "0 when
/// absent (not 'free'). Only huggingface currently stamps authoritative cost." A bucket whose
/// cost is zero while it carries tokens is therefore ESTIMATED from its token counts and the
/// matched model's price deck — uncached prompt at the input rate, cached at the cached rate,
/// completion at the output rate — and the spend is marked `estimated`, which the app renders
/// as "about". A bucket that matches no registry model keeps whatever cost it reported, under
/// its own name, so the total still adds up.
pub fn parse_fireworks_usage(
    v: &Value,
    models: &[FireworksModelRef],
    period_start_ms: i64,
) -> QuotaSpend {
    let mut spend = QuotaSpend {
        month_to_date_usd: 0.0,
        by_model_usd: BTreeMap::new(),
        period_start_ms,
        estimated: false,
    };
    for bucket in v
        .get("serverlessCosts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let name = bucket
            .get("group")
            .and_then(|g| g.get("model_name"))
            .and_then(Value::as_str)
            .or_else(|| bucket.get("modelName").and_then(Value::as_str))
            .unwrap_or("unknown");
        let matched = models.iter().find(|m| slug_matches(&m.slug, name));
        let mut usd = loose_f64(bucket.get("costNanoUsd")) / 1e9;
        if usd <= 0.0 {
            if let Some(m) = matched {
                let prompt = loose_f64(bucket.get("promptTokens"));
                let cached = loose_f64(bucket.get("cachedPromptTokens")).min(prompt);
                let completion = loose_f64(bucket.get("completionTokens"));
                let estimate = ((prompt - cached) * m.price.in_per_m
                    + cached * m.price.cached_per_m
                    + completion * m.price.out_per_m)
                    / 1e6;
                if estimate > 0.0 {
                    usd = estimate;
                    spend.estimated = true;
                }
            }
        }
        let key = matched.map_or_else(|| name.to_string(), |m| m.id.clone());
        *spend.by_model_usd.entry(key).or_insert(0.0) += usd;
        spend.month_to_date_usd += usd;
    }
    spend
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    use std::sync::atomic::AtomicUsize;

    const CLAUDE_FIXTURE: &str = include_str!("../tests/fixtures/quota/claude-usage.json");
    const CODEX_FIXTURE: &str = include_str!("../tests/fixtures/quota/codex-rate-limits.json");
    const FIREWORKS_FIXTURE: &str =
        include_str!("../tests/fixtures/quota/fireworks-billing-usage.synthetic.json");

    fn model(id: &str, kind: ModelKind, harness: &str, base: Option<&str>) -> RegistryModel {
        let mut m = ModelRegistry::opus_only().default_model().clone();
        m.id = id.to_string();
        m.label = id.to_string();
        m.kind = kind;
        m.harness = harness.to_string();
        m.backend = base.map(|b| {
            (
                b.to_string(),
                "tok".to_string(),
                format!("accounts/fireworks/models/{id}"),
            )
        });
        m.configured = true;
        m
    }

    fn cfg_with(models: Vec<RegistryModel>) -> Config {
        Config {
            model_registry: ModelRegistry { models },
            ..test_config()
        }
    }

    const FW: &str = "https://api.fireworks.ai/inference";

    /// Every row of the table, plus the two that map to nothing.
    #[test]
    fn every_model_maps_to_the_account_it_bills() {
        use ModelKind::*;
        let cases = [
            (
                model("opus", Ambient, CLAUDE_CODE_ID, None),
                Some(QuotaScopeId::ClaudeSubscription),
            ),
            (
                model("fable", Subscription, CLAUDE_CODE_ID, None),
                Some(QuotaScopeId::ClaudeSubscription),
            ),
            // The deployed Codex entries: hosted, a probe URL on the local gateway, and the
            // ChatGPT login behind them.
            (
                model("codex", Hosted, CODEX_ID, Some("http://127.0.0.1:9100")),
                Some(QuotaScopeId::CodexChatgpt),
            ),
            (
                model("glm", Hosted, CLAUDE_CODE_ID, Some(FW)),
                Some(QuotaScopeId::Fireworks),
            ),
            (
                model("kimi", Hosted, DIRECT_ID, Some(FW)),
                Some(QuotaScopeId::Fireworks),
            ),
            // An OpenAI-surface model on Fireworks spends the Fireworks account.
            (
                model(
                    "kimi-codex",
                    OpenAi,
                    CODEX_ID,
                    Some("https://api.fireworks.ai/inference/v1"),
                ),
                Some(QuotaScopeId::Fireworks),
            ),
            (
                model(
                    "local",
                    Local,
                    CLAUDE_CODE_ID,
                    Some("http://127.0.0.1:9100"),
                ),
                None,
            ),
            (
                model("gpt", OpenAi, CODEX_ID, Some("https://api.openai.com/v1")),
                None,
            ),
            (
                model(
                    "other",
                    Hosted,
                    CLAUDE_CODE_ID,
                    Some("https://example.com/v1"),
                ),
                None,
            ),
        ];
        for (m, want) in cases {
            assert_eq!(quota_scope_for(&m), want, "{}", m.id);
            assert_eq!(
                quota_scope_for_active(&ActiveModel::from_registry(&m)),
                want,
                "the running model maps the same way: {}",
                m.id
            );
        }
    }

    #[test]
    fn only_configured_models_list_a_scope() {
        let mut unarmed = model("qwen", ModelKind::Hosted, CLAUDE_CODE_ID, Some(FW));
        unarmed.configured = false;
        let cfg = cfg_with(vec![
            model("opus", ModelKind::Ambient, CLAUDE_CODE_ID, None),
            model("glm", ModelKind::Hosted, CLAUDE_CODE_ID, Some(FW)),
            unarmed,
        ]);
        let scopes = quota_scope_models(&cfg);
        assert_eq!(scopes[&QuotaScopeId::ClaudeSubscription], vec!["opus"]);
        assert_eq!(scopes[&QuotaScopeId::Fireworks], vec!["glm"]);
        assert!(!scopes.contains_key(&QuotaScopeId::CodexChatgpt));
    }

    fn snapshot_with(windows: &[(&str, f64)]) -> QuotaSnapshot {
        let mut s = QuotaSnapshot::new(QuotaScopeId::ClaudeSubscription, 1, QuotaSource::Fetched);
        for (id, pct) in windows {
            s.windows.push(QuotaWindow {
                id: id.to_string(),
                label: window_label(id),
                used_percent: *pct,
                resets_at_ms: Some(5),
                status: None,
            });
        }
        s
    }

    /// **CONSTRAINT 7.** An `allowed` event that says nothing else leaves a stored 41 percent
    /// exactly where it was.
    #[test]
    fn an_allowed_event_with_nothing_else_leaves_a_known_percentage_intact() {
        let store = QuotaStore::with_fetcher(Arc::new(CountingFetcher::default()));
        store.replace(snapshot_with(&[("seven_day", 41.0)]));
        let info = RateLimitEventInfo::from_value(&json!({
            "status": "allowed", "rateLimitType": "seven_day"
        }))
        .unwrap();
        store.merge_sparse(
            QuotaScopeId::ClaudeSubscription,
            info.to_patch(),
            QuotaSource::Turn,
            99,
        );
        let s = store.get(QuotaScopeId::ClaudeSubscription).unwrap();
        assert_eq!(s.windows[0].used_percent, 41.0, "absent never clears");
        assert_eq!(
            s.windows[0].resets_at_ms,
            Some(5),
            "nor does an absent reset"
        );
        assert_eq!(s.windows[0].status.as_deref(), Some("allowed"));
        assert_eq!(
            (s.fetched_at_ms, s.source),
            (99, QuotaSource::Turn),
            "stamps move"
        );
    }

    #[test]
    fn a_present_value_replaces_and_a_new_window_needs_a_percentage() {
        let mut s = snapshot_with(&[("five_hour", 10.0)]);
        s.apply(
            QuotaPatch {
                windows: vec![
                    QuotaWindowPatch {
                        id: "five_hour".into(),
                        used_percent: Some(92.5),
                        ..Default::default()
                    },
                    // Never measured: not invented.
                    QuotaWindowPatch {
                        id: "seven_day".into(),
                        status: Some("allowed".into()),
                        ..Default::default()
                    },
                ],
                plan: Some("max".into()),
                spend: None,
            },
            QuotaSource::Turn,
            7,
        );
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_percent, 92.5);
        assert_eq!(s.plan.as_deref(), Some("max"));
        assert!(s.warning, "92.5 is past the warning line");
        // A plan absent from a later patch stays.
        s.apply(QuotaPatch::default(), QuotaSource::Turn, 8);
        assert_eq!(s.plan.as_deref(), Some("max"));
    }

    #[test]
    fn warning_is_ninety_percent_or_a_rejected_window() {
        let mut s = snapshot_with(&[("five_hour", 89.9)]);
        s.refresh_warning();
        assert!(!s.warning);
        s.windows[0].used_percent = 90.0;
        s.refresh_warning();
        assert!(s.warning, "at 90 exactly");
        let mut r = snapshot_with(&[("five_hour", 3.0)]);
        r.windows[0].status = Some("rejected".into());
        r.refresh_warning();
        assert!(r.warning, "rejected at any percentage");
    }

    #[test]
    fn the_ttl_the_force_floor_and_the_backoff() {
        let ttl = CLAUDE_QUOTA_TTL_SECS;
        let s = 1000i64;
        // Nothing yet: due.
        assert!(needs_fetch(None, None, None, ttl, false, 10 * s));
        // Fresh data is not due, stale data is.
        assert!(!needs_fetch(Some(0), Some(0), None, ttl, false, 119 * s));
        assert!(needs_fetch(Some(0), Some(0), None, ttl, false, 120 * s));
        // Force: not before the floor, then due.
        assert!(!needs_fetch(Some(0), Some(0), None, ttl, true, 19 * s));
        assert!(needs_fetch(Some(0), Some(0), None, ttl, true, 20 * s));
        // A failed attempt 5 s ago holds off a retry even though the data is old.
        assert!(!needs_fetch(
            Some(0),
            Some(995 * s),
            None,
            ttl,
            false,
            1000 * s
        ));
        // Inside a 429 backoff nothing is due, forced or not.
        assert!(!needs_fetch(None, None, Some(50 * s), ttl, true, 49 * s));
        assert!(needs_fetch(None, None, Some(50 * s), ttl, true, 50 * s));
    }

    #[test]
    fn the_ttl_override_is_floored_and_bad_values_warn() {
        assert_eq!(parse_quota_ttl_override(None), Ok(None));
        assert_eq!(parse_quota_ttl_override(Some(" ")), Ok(None));
        assert_eq!(parse_quota_ttl_override(Some("300")), Ok(Some(300)));
        assert_eq!(
            parse_quota_ttl_override(Some("3")),
            Ok(Some(QUOTA_FORCE_FLOOR_SECS))
        );
        assert!(parse_quota_ttl_override(Some("0")).is_err());
        assert!(parse_quota_ttl_override(Some("soon")).is_err());
        let settings = QuotaSettings {
            fireworks_account_id: None,
            ttl_override_secs: Some(60),
        };
        for scope in QuotaScopeId::ALL {
            assert_eq!(settings.ttl_secs(scope), 60, "one value for every scope");
        }
        assert_eq!(
            QuotaSettings::default().ttl_secs(QuotaScopeId::Fireworks),
            FIREWORKS_QUOTA_TTL_SECS
        );
    }

    /// Counts fetches, and takes its time about each one so concurrent callers overlap.
    #[derive(Default)]
    struct CountingFetcher {
        calls: AtomicUsize,
        fail_with: Option<QuotaError>,
    }

    impl QuotaFetcher for CountingFetcher {
        fn fetch<'a>(
            &'a self,
            scope: QuotaScopeId,
            _cfg: &'a Config,
        ) -> Pin<Box<dyn Future<Output = Result<QuotaSnapshot, QuotaError>> + Send + 'a>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let fail = self.fail_with.clone();
            Box::pin(async move {
                tokio::time::sleep(Duration::from_millis(50)).await;
                if let Some(e) = fail {
                    return Err(e);
                }
                let mut s = QuotaSnapshot::new(scope, 0, QuotaSource::Fetched);
                s.windows.push(QuotaWindow {
                    id: "five_hour".into(),
                    label: "5 hours".into(),
                    used_percent: 23.0,
                    resets_at_ms: None,
                    status: None,
                });
                Ok(s)
            })
        }
    }

    fn claude_cfg() -> Config {
        cfg_with(vec![model(
            "opus",
            ModelKind::Ambient,
            CLAUDE_CODE_ID,
            None,
        )])
    }

    #[tokio::test]
    async fn two_concurrent_callers_share_one_fetch() {
        let fetcher = Arc::new(CountingFetcher::default());
        let store = Arc::new(QuotaStore::with_fetcher(fetcher.clone()));
        let cfg = claude_cfg();
        let scope = QuotaScopeId::ClaudeSubscription;
        let (a, b) = tokio::join!(
            store.ensure_fresh(scope, &cfg, false, 1_000),
            store.ensure_fresh(scope, &cfg, false, 1_000)
        );
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 1, "single flight");
        assert!(a ^ b, "exactly one of the two fetched");
        let s = store.get(scope).unwrap();
        assert_eq!(s.windows[0].used_percent, 23.0);
        assert_eq!(s.fetched_at_ms, 1_000);
        // Within the TTL: no second request.
        assert!(!store.ensure_fresh(scope, &cfg, false, 5_000).await);
        // Forced before the floor: still none. After it: exactly one.
        assert!(!store.ensure_fresh(scope, &cfg, true, 10_000).await);
        assert!(store.ensure_fresh(scope, &cfg, true, 21_000).await);
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn a_failure_keeps_the_last_snapshot_and_sets_the_error() {
        let scope = QuotaScopeId::ClaudeSubscription;
        let store = QuotaStore::with_fetcher(Arc::new(CountingFetcher {
            calls: AtomicUsize::new(0),
            fail_with: Some(QuotaError::LoginExpired),
        }));
        store.replace(snapshot_with(&[("five_hour", 12.0)]));
        let cfg = claude_cfg();
        assert!(!store.ensure_fresh(scope, &cfg, false, 1_000_000).await);
        let s = store.get(scope).unwrap();
        assert_eq!(s.windows[0].used_percent, 12.0, "last good data kept");
        assert_eq!(s.error.as_deref(), Some(CLAUDE_LOGIN_EXPIRED));
    }

    #[tokio::test]
    async fn a_429_holds_the_scope_off_for_at_least_five_minutes() {
        let scope = QuotaScopeId::ClaudeSubscription;
        let fetcher = Arc::new(CountingFetcher {
            calls: AtomicUsize::new(0),
            fail_with: Some(QuotaError::RateLimited {
                retry_after_secs: 10,
            }),
        });
        let store = QuotaStore::with_fetcher(fetcher.clone());
        let cfg = claude_cfg();
        store.ensure_fresh(scope, &cfg, false, 0).await;
        // Forced, and past both the floor and the 10 s the header asked for: still refused.
        assert!(!store.ensure_fresh(scope, &cfg, true, 299_000).await);
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 1);
        store.ensure_fresh(scope, &cfg, true, 300_000).await;
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 2);
    }

    /// Verification 5, offline: with no account id the scope says so and the fetcher is never
    /// invoked.
    #[tokio::test]
    async fn fireworks_without_an_account_id_calls_nothing() {
        let fetcher = Arc::new(CountingFetcher::default());
        let store = QuotaStore::with_fetcher(fetcher.clone());
        let cfg = cfg_with(vec![model(
            "glm",
            ModelKind::Hosted,
            CLAUDE_CODE_ID,
            Some(FW),
        )]);
        assert!(cfg.quota.fireworks_account_id.is_none());
        store
            .ensure_fresh(QuotaScopeId::Fireworks, &cfg, true, 1_000)
            .await;
        assert_eq!(fetcher.calls.load(Ordering::SeqCst), 0, "no request made");
        let entry = store.entry(QuotaScopeId::Fireworks, &cfg).unwrap();
        assert_eq!(
            entry.snapshot.error.as_deref(),
            Some(FIREWORKS_SPEND_NOT_CONFIGURED)
        );
        assert_eq!(entry.models, vec!["glm"]);
        assert_eq!(entry.ttl_secs, FIREWORKS_QUOTA_TTL_SECS);
    }

    /// The live body from 2026-09-12, redacted of nothing because it carries no identifier.
    #[test]
    fn the_claude_usage_body_maps_onto_windows_on_the_observed_scale() {
        let v: Value = serde_json::from_str(CLAUDE_FIXTURE).unwrap();
        let s = parse_claude_usage(&v, Some("max".into()), 42);
        let ids: Vec<&str> = s.windows.iter().map(|w| w.id.as_str()).collect();
        // The Fable scoped limit is `is_active: false`, the codename objects carry no name,
        // and every `seven_day_<x>` is null: none of them is a window.
        assert_eq!(ids, vec!["five_hour", "seven_day", "extra_usage"]);
        assert_eq!(s.windows[0].label, "5 hours");
        assert_eq!(s.windows[0].used_percent, 8.0, "0 to 100 on this endpoint");
        assert_eq!(s.windows[1].label, "7 days");
        assert_eq!(s.windows[1].used_percent, 27.0);
        assert_eq!(
            s.windows[0].resets_at_ms,
            parse_iso8601_ms("2026-09-12T11:30:00.965Z")
        );
        assert_eq!(s.windows[2].label, "extra usage");
        assert_eq!(s.windows[2].used_percent, 0.0, "used 0 of 87500");
        assert_eq!(s.plan.as_deref(), Some("max"));
        assert!(!s.warning);
    }

    #[test]
    fn an_active_model_scoped_limit_and_a_seven_day_model_window_are_their_own_windows() {
        let v = json!({
            "five_hour": {"utilization": 91.0, "resets_at": "2026-09-12T11:30:00Z"},
            "seven_day_opus": {"utilization": 12.0, "resets_at": null},
            "limits": [{"kind": "weekly_scoped", "percent": 10, "is_active": true,
                        "resets_at": "2026-09-14T03:00:00Z",
                        "scope": {"model": {"id": null, "display_name": "Fable"}}}],
            "extra_usage": {"is_enabled": false, "utilization": 50.0}
        });
        let s = parse_claude_usage(&v, None, 0);
        let got: Vec<(&str, &str, f64)> = s
            .windows
            .iter()
            .map(|w| (w.id.as_str(), w.label.as_str(), w.used_percent))
            .collect();
        assert_eq!(
            got,
            vec![
                ("five_hour", "5 hours", 91.0),
                ("seven_day_opus", "Opus", 12.0),
                ("weekly_scoped_fable", "Fable", 10.0),
            ]
        );
        assert!(s.warning, "91 percent");
    }

    #[test]
    fn iso8601_timestamps_parse_with_fraction_and_offset() {
        let base = parse_iso8601_ms("2026-09-12T11:30:00Z").unwrap();
        assert_eq!(
            base, 1_789_212_600_000,
            "the rate_limit_event's resetsAt, in ms"
        );
        assert_eq!(
            parse_iso8601_ms("2026-09-12T11:30:00.965545+00:00"),
            Some(base + 965)
        );
        assert_eq!(parse_iso8601_ms("2026-09-12T13:30:00+02:00"), Some(base));
        assert_eq!(
            parse_iso8601_ms("2026-09-12T06:30:00.5-05:00"),
            Some(base + 500)
        );
        assert_eq!(parse_iso8601_ms("2026-09-12T11:30:00"), Some(base));
        assert_eq!(parse_iso8601_ms("2026-09-12T11:30:00+0200"), None);
        assert_eq!(parse_iso8601_ms("soon"), None);
    }

    /// The live `account/rateLimits/read` result from 2026-09-12, account id and reset credit
    /// ids removed.
    #[test]
    fn the_codex_rate_limits_map_onto_labelled_windows() {
        let v: Value = serde_json::from_str(CODEX_FIXTURE).unwrap();
        let patch = codex_rate_limits_patch(&v["rateLimits"]);
        let mut s = QuotaSnapshot::new(QuotaScopeId::CodexChatgpt, 0, QuotaSource::Fetched);
        s.apply(patch, QuotaSource::Fetched, 3);
        assert_eq!(s.windows.len(), 1, "secondary is null, so absent");
        assert_eq!(s.windows[0].id, "primary");
        assert_eq!(s.windows[0].label, "7 days", "10080 minutes");
        assert_eq!(s.windows[0].used_percent, 0.0);
        assert_eq!(s.windows[0].resets_at_ms, Some(1_789_811_159_000));
        assert_eq!(s.plan.as_deref(), Some("pro"));
        // The other limit id's two windows label themselves from their lengths.
        let spark = codex_rate_limits_patch(&v["rateLimitsByLimitId"]["codex_bengalfox"]);
        let labels: Vec<_> = spark.windows.iter().map(|w| w.label.clone()).collect();
        assert_eq!(labels, vec![Some("5 hours".into()), Some("7 days".into())]);
        assert_eq!(codex_window_label("primary", Some(60)), "60 min");
    }

    #[test]
    fn a_codex_login_is_chatgpt_tokens_or_nothing() {
        let dir = std::env::temp_dir().join(format!("jesse-quota-codex-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(
            codex_login_state(&dir),
            Err(QuotaError::NotLoggedIn),
            "no auth.json"
        );
        let write = |body: Value| std::fs::write(dir.join("auth.json"), body.to_string()).unwrap();
        write(json!({"auth_mode": "apikey", "OPENAI_API_KEY": "k", "tokens": null}));
        assert_eq!(
            codex_login_state(&dir),
            Err(QuotaError::NotLoggedIn),
            "an API key account"
        );
        write(json!({"auth_mode": "chatgpt", "tokens": {"id_token": "x"}}));
        assert_eq!(codex_login_state(&dir), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn fw_ref(id: &str, slug: &str, price: PriceDeck) -> FireworksModelRef {
        FireworksModelRef {
            id: id.into(),
            slug: slug.into(),
            price,
        }
    }

    #[test]
    fn fireworks_spend_sums_by_registry_id_and_estimates_an_unstamped_bucket() {
        let v: Value = serde_json::from_str(FIREWORKS_FIXTURE).unwrap();
        let kimi_deck = PriceDeck {
            in_per_m: 3.0,
            cached_per_m: 0.3,
            cache_write_per_m: None,
            out_per_m: 15.0,
        };
        let models = [
            fw_ref("glm", "accounts/fireworks/models/glm-5p3", PriceDeck::ZERO),
            // A bare slug matches the bucket's full model name by its last segment.
            fw_ref("kimi", "kimi-k3", kimi_deck),
        ];
        let spend = parse_fireworks_usage(&v, &models, 11);
        let close = |a: f64, b: f64| (a - b).abs() < 1e-9;
        assert!(close(spend.by_model_usd["glm"], 1.052), "{spend:?}");
        // 100k prompt at 3.00 plus 10k completion at 15.00, per million.
        assert!(close(spend.by_model_usd["kimi"], 0.45), "{spend:?}");
        assert!(close(
            spend.by_model_usd["accounts/fireworks/models/some-other-model"],
            0.25
        ));
        assert!(close(spend.month_to_date_usd, 1.752));
        assert!(spend.estimated, "the kimi bucket reported no cost");
        assert_eq!(spend.period_start_ms, 11);
        let empty = parse_fireworks_usage(&json!({"serverlessCosts": []}), &models, 0);
        assert_eq!(empty.month_to_date_usd, 0.0, "a quiet month");
        assert!(!empty.estimated);
    }

    #[test]
    fn the_month_starts_at_midnight_utc_on_the_first() {
        let now = parse_iso8601_ms("2026-09-12T09:45:55Z").unwrap();
        assert_eq!(
            month_start_utc_ms(now),
            parse_iso8601_ms("2026-09-01T00:00:00Z").unwrap()
        );
        assert_eq!(
            rfc3339_from_ms(month_start_utc_ms(now)),
            "2026-09-01T00:00:00Z"
        );
        assert!(valid_account_id("my-team_1"));
        assert!(!valid_account_id("../x"));
        assert!(!valid_account_id(""));
    }

    #[test]
    fn a_credential_without_a_claude_login_or_past_its_expiry_is_refused_before_any_request() {
        assert!(
            parse_claude_credential(&json!({"mcpOAuth": {"x": {}}})).is_none(),
            "an mcpOAuth only item is no login"
        );
        let doc = |expires: i64, scopes: Value| {
            json!({"claudeAiOauth": {"accessToken": "t", "expiresAt": expires,
                                     "scopes": scopes, "subscriptionType": "max"}})
        };
        let ok = parse_claude_credential(&doc(2_000, json!(["user:inference", "user:profile"])))
            .unwrap();
        assert_eq!(ok.plan.as_deref(), Some("max"));
        assert!(check_claude_credential(&ok, 1_000).is_ok());
        assert_eq!(
            check_claude_credential(&ok, 2_000).err(),
            Some(QuotaError::LoginExpired)
        );
        let narrow = parse_claude_credential(&doc(2_000, json!(["user:inference"]))).unwrap();
        assert_eq!(
            check_claude_credential(&narrow, 1_000).err(),
            Some(QuotaError::ScopeMissing)
        );
    }

    /// Every string a scope can carry reaches a menu subtitle, and those carry no dashes.
    #[test]
    fn no_user_facing_quota_string_contains_a_dash() {
        let errors = [
            QuotaError::NotLoggedIn,
            QuotaError::LoginExpired,
            QuotaError::ScopeMissing,
            QuotaError::Forbidden,
            QuotaError::RateLimited {
                retry_after_secs: 1,
            },
            QuotaError::Http(503),
            QuotaError::Timeout,
            QuotaError::Transport,
            QuotaError::Protocol,
            QuotaError::NotConfigured,
        ];
        let mut strings: Vec<String> = errors.iter().map(QuotaError::message).collect();
        strings.extend(QuotaScopeId::ALL.iter().map(|s| s.label().to_string()));
        for id in [
            "five_hour",
            "seven_day",
            "extra_usage",
            "seven_day_oauth_apps",
        ] {
            strings.push(window_label(id));
        }
        strings.push(codex_window_label("primary", Some(45)));
        for s in strings {
            assert!(
                !s.contains([
                    '-', '\u{2010}', '\u{2011}', '\u{2012}', '\u{2013}', '\u{2014}', '\u{2015}',
                    '\u{2212}'
                ]),
                "{s:?}"
            );
        }
    }

    #[test]
    fn a_wire_entry_flattens_the_snapshot_beside_label_models_and_ttl() {
        let mut snap = snapshot_with(&[("five_hour", 23.0)]);
        snap.plan = Some("max".into());
        let entry = QuotaEntry {
            snapshot: snap,
            label: "Claude subscription".into(),
            models: vec!["opus".into(), "fable".into()],
            ttl_secs: 120,
        };
        let v = serde_json::to_value(&entry).unwrap();
        assert_eq!(v["id"], "claude-subscription");
        assert_eq!(v["source"], "fetched");
        assert_eq!(v["windows"][0]["used_percent"], 23.0);
        assert_eq!(v["models"], json!(["opus", "fable"]));
        assert_eq!(v["ttl_secs"], 120);
        assert!(v["spend"].is_null() && v["error"].is_null());
        let back: QuotaEntry = serde_json::from_value(v).unwrap();
        assert_eq!(back, entry, "round trips, so a persisted job keeps it");
    }
}
