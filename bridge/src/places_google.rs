//! The `places` server's second provider: Google Places API (New).
//!
//! # What this is for, and what it is not
//!
//! [`crate::places`] answers "what is near me and is it open right now" out of OpenStreetMap.
//! OSM gives opening hours WHERE A MAPPER HAS RECORDED THEM — on the shipped Fountainbridge
//! sample that was 6 of 15 cafés — and it gives ratings NEVER, because the data model has no
//! field for one. This provider supplies both, at the cost of an API key and a per-request
//! bill.
//!
//! **It sits behind the same two tool names and adds none.** `places_search` and
//! `place_details` are unchanged, `DEFAULT_ALLOWED_TOOLS` is unchanged, `MAIN_CHILD_MCP_CONFIG`
//! is unchanged — so `Harness::capability_args` produces the same argv, so
//! [`crate::levelgate::validate_toolset_argv`] still finds strict equality with the recorded
//! `toolset_args`, so the committed containment record still speaks for the deployment. That
//! is the whole reason the tool names were made provider-agnostic in 0.100.0, and it is why
//! this change costs no live battery re-run. A third tool would have cost one.
//!
//! # No caller-authored string reaches Google either
//!
//! This is the property the `places` server was built around and it is NOT relaxed here.
//!
//! Google's obvious entry point for a free-text query is **Text Search**
//! (`places:searchText`), which takes a `textQuery` — exactly the egress channel this server
//! exists not to have, out of a child that also reads attacker-authored message bodies. So
//! Text Search is not used and is not reachable. What is used is **Nearby Search**
//! (`places:searchNearby`), whose entire request body is a coordinate, a radius, a result
//! count and a list of place types — and the types come from
//! [`crate::places::Category::google_types`], the same closed compile-time table that already
//! chooses the OSM tag filters. The caller's free text is applied to the RESPONSE on this
//! side, exactly as it is for OSM.
//!
//! The one caller-supplied string that reaches Google is a place id, and it reaches one only
//! after [`validate_google_place_id`] has held it to `^[A-Za-z0-9_-]{1,255}$`.
//!
//! # Caching: what Google's terms actually permit, which is almost nothing
//!
//! Google Maps Platform Terms of Service **§3.2.3(b) (No Caching)**: *"Customer will not cache
//! Google Maps Content except as expressly permitted under the Maps Service Specific Terms."*
//! The Maps Service Specific Terms then permit, for this API, exactly two things:
//!
//!   * **§14.3 (Places API (Legacy and New) — Caching)**: *"Customer may temporarily cache
//!     latitude and longitude values from the Places API for up to 30 consecutive calendar
//!     days, after which Customer must delete the cached latitude and longitude values."*
//!   * **§3 (ID Caching)**: place ids may be cached — the Places policy page puts it as *"the
//!     place ID ... is exempt from the caching restrictions. You can therefore store place ID
//!     values indefinitely."*
//!
//! Nothing else. Not names, not addresses, not ratings, and **not opening hours** — the two
//! fields that are the entire reason this provider exists. §3.2.3(a)(iii) reinforces it from
//! the other side by naming *"copy and save business names, addresses, or user reviews"* as
//! prohibited scraping.
//!
//! So **this provider caches nothing**, and that is a deliberate refusal rather than an
//! omission. [`crate::places::PlacesClient::fetch`] — the five-minute response cache the OSM
//! path uses — is not on this path at all. The two things the terms DO permit (ids,
//! coordinates) are the two things whose reuse would save no money here: a cached id still
//! needs a billed Place Details call to turn back into hours and a rating, which costs more
//! than the search that produced it.
//!
//! The consequence is stated plainly rather than engineered around: **every Google-served tool
//! call is a billed call**, and the only thing standing between a runaway loop and a bill is
//! [`CallLedger`] below. That is why the budget is enforced server-side, defaults low, and
//! fails CLOSED.
//!
//! # Field masks, because the mask is the price
//!
//! The Places API bills per request by the **highest SKU any field in the mask belongs to** —
//! Google's own wording: *"You are then billed at the highest SKU applicable to your request.
//! That means if you select fields in both the Essentials and the Pro SKUs, you are billed
//! based on the Pro SKU."* Asking for everything turns a Pro lookup into an
//! Enterprise + Atmosphere one.
//!
//! `rating`, `userRatingCount` and `regularOpeningHours` are all **Enterprise**, so this tool
//! contract cannot be served below Enterprise — that is the floor, not a choice. What IS a
//! choice is not going above it: [`GOOGLE_SEARCH_FIELD_MASK`] and [`GOOGLE_DETAILS_FIELD_MASK`]
//! name the minimum set the contract needs and nothing else. In particular `photos` and the
//! whole service/amenity block are **Enterprise + Atmosphere** and are never requested.
//!
//! **The dearer mask is now reachable, and only by asking.** [`crate::places::DetailLevel::Rich`]
//! selects [`GOOGLE_SEARCH_FIELD_MASK_RICH`] / [`GOOGLE_DETAILS_FIELD_MASK_RICH`], which add
//! `reviews` and `editorialSummary` — Enterprise + Atmosphere, so the whole call is billed
//! there. Nothing about the default moved: with no `detail` argument the masks above are what
//! goes out, byte for byte. What keeps a loop of rich calls from being expensive is a SECOND
//! ceiling, [`DEFAULT_GOOGLE_MAX_RICH_CALLS`], counted over the same window as the first and
//! tripping ten times sooner.
//!
//! # Review text carries obligations a rating does not
//!
//! The Places API policy page attaches named requirements to displaying reviews that it does
//! not attach to a rating: *"You must always credit the author when displaying photos or
//! reviews"*, and *"For each photo and review, end-users must always have access to view the
//! individual source photo or review on Google Maps using the provided `googleMapsUri`."*
//! [`review_json`] meets both on this side — every returned review carries its author's name,
//! profile link and avatar URI and its own `source_url`, and a review arriving without either
//! is DROPPED rather than passed on unshowable. Its ordering notice
//! (*"Include a clear notice that describes how reviews are being ordered and filtered"*)
//! travels with the array as [`REVIEWS_NOTICE`], which is only honest because nothing here
//! reorders, filters or truncates the text.
//!
//! None of that relaxes the caching position below: review text is Google Maps Content like
//! any other, this provider caches none of it, and §3.2.3(a)(iii) naming *"copy and save
//! business names, addresses, or user reviews"* as prohibited scraping applies to what a TURN
//! does with the text afterwards — an operator boundary, stated in SECURITY.md, not something
//! this server can enforce.
//!
//! # Attribution
//!
//! Service Specific Terms §14.1 permits using Places content without a Google map, and §14.2
//! forbids using it WITH a non-Google map — this server renders no map at all, so both are
//! satisfied. What is required is attribution, so every Google-served record carries an
//! `attribution` string and passes through the provider's own `attributions` array untouched
//! when one is present.

use std::path::PathBuf;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;

use crate::places::{
    fold_name, haversine_m, hours_json_from, DetailLevel, Interval, OpeningHours, Provider, Zone,
};

/// The Places API (New) base URL. Overridable so a test can point it at a loopback listener;
/// there is no other reason to move it.
pub const DEFAULT_GOOGLE_BASE_URL: &str = "https://places.googleapis.com/v1";

/// The search field mask — see the module docs on why a mask is a price.
///
/// `places.rating` / `places.userRatingCount` / `places.regularOpeningHours` put this at the
/// **Enterprise** SKU, which is the floor for this tool contract. Everything else here is
/// Essentials or Pro and therefore free of charge given that floor; nothing here is
/// Enterprise + Atmosphere.
///
/// `places.attributions` is Essentials and is requested because the terms require the
/// provider's own attributions to be carried, not because the tool needs it.
pub const GOOGLE_SEARCH_FIELD_MASK: &str = "places.id,places.displayName,\
     places.formattedAddress,places.location,places.primaryType,places.rating,\
     places.userRatingCount,places.regularOpeningHours,places.nationalPhoneNumber,\
     places.websiteUri,places.attributions";

/// The Place Details field mask.
///
/// **Not `places.`-prefixed**, unlike [`GOOGLE_SEARCH_FIELD_MASK`]: Place Details returns one
/// `Place` at the top level rather than a `places` array, and a prefixed mask is rejected.
/// Same field set, so a record from either call maps through the same code.
pub const GOOGLE_DETAILS_FIELD_MASK: &str = "id,displayName,formattedAddress,location,\
     primaryType,rating,userRatingCount,regularOpeningHours,nationalPhoneNumber,websiteUri,\
     attributions";

/// The search mask a caller gets by asking for [`crate::places::DetailLevel::Rich`].
///
/// # What was added, and what was deliberately not
///
/// [`GOOGLE_SEARCH_FIELD_MASK`] plus exactly two fields, both **Enterprise + Atmosphere**,
/// which is what makes this call materially dearer than the standard one and why it has its
/// own ceiling:
///
///   * `reviews` — the thing that was actually missing. A rating says a place is well liked;
///     it cannot say *why*, and "is this the shop that does made-to-measure" is only ever
///     answered by the text.
///   * `editorialSummary` — one sentence of the provider's own prose, present on notable
///     places and absent on most small ones. It costs nothing extra given `reviews` is
///     already in the mask (the tier is set by the dearest field, not by the count), so it is
///     the one field in the whole Atmosphere family that is genuinely free here.
///
/// **`photos` is not here, and neither is the service/amenity block** (`servesBeer`,
/// `outdoorSeating`, `goodForChildren`, `paymentOptions`, …). Not because they are dear —
/// given `reviews` they would be free on the same reasoning `editorialSummary` is — but
/// because no caller has asked for them. `photos` returns URIs that a text tool cannot
/// render, and the amenity block is thirty booleans that would land in every rich response
/// whether or not the question was about beer. Every field in a mask is permanent cost in
/// context even when it is not permanent cost in money; the bar is a caller need, and these
/// have none yet.
pub const GOOGLE_SEARCH_FIELD_MASK_RICH: &str = concat!(
    "places.id,places.displayName,places.formattedAddress,places.location,places.primaryType,",
    "places.rating,places.userRatingCount,places.regularOpeningHours,",
    "places.nationalPhoneNumber,places.websiteUri,places.attributions,",
    "places.reviews,places.editorialSummary"
);

/// The Place Details mask at [`crate::places::DetailLevel::Rich`]. Same two additions as
/// [`GOOGLE_SEARCH_FIELD_MASK_RICH`], and unprefixed for the reason
/// [`GOOGLE_DETAILS_FIELD_MASK`] states.
pub const GOOGLE_DETAILS_FIELD_MASK_RICH: &str = concat!(
    "id,displayName,formattedAddress,location,primaryType,rating,userRatingCount,",
    "regularOpeningHours,nationalPhoneNumber,websiteUri,attributions,",
    "reviews,editorialSummary"
);

/// The search mask for a detail level. One function so no call site can pick a mask that
/// disagrees with the tier it reserved against the budget.
pub fn google_search_field_mask(detail: DetailLevel) -> &'static str {
    match detail {
        DetailLevel::Standard => GOOGLE_SEARCH_FIELD_MASK,
        DetailLevel::Rich => GOOGLE_SEARCH_FIELD_MASK_RICH,
    }
}

/// The Place Details mask for a detail level.
pub fn google_details_field_mask(detail: DetailLevel) -> &'static str {
    match detail {
        DetailLevel::Standard => GOOGLE_DETAILS_FIELD_MASK,
        DetailLevel::Rich => GOOGLE_DETAILS_FIELD_MASK_RICH,
    }
}

/// Nearby Search's own ceiling on results per call: *"Must be between 1 and 20 (default)
/// inclusive."* A caller asking for more gets 20 and a response that says how many it got.
pub const GOOGLE_MAX_RESULTS: usize = 20;

/// Calls allowed per window before the budget trips, when `JESSE_PLACES_GOOGLE_MAX_CALLS`
/// is unset.
///
/// **This is a spend limit, not a rate limit, and it is sized against a bill rather than
/// against a workload.** 200 Enterprise-SKU calls is a small enough number that a loop which
/// gets past it is visible in the ledger the same day, and a large enough number that ordinary
/// use never sees it: the child asks this question a handful of times a day.
pub const DEFAULT_GOOGLE_MAX_CALLS: u32 = 200;

/// Calls at [`DetailLevel::Rich`] allowed per window, when `JESSE_PLACES_GOOGLE_MAX_RICH_CALLS`
/// is unset.
///
/// # Why a second, much lower ceiling rather than a weight on the first
///
/// A weighted counter would be arithmetic that has to be right: pick the weight from a price
/// ratio that changes when Google changes it, and a shared pool then lets an accidental rich
/// loop eat the ordinary allowance on its way to tripping. A separate counter needs no ratio
/// and cannot be spent by the wrong kind of call.
///
/// **Twenty, against two hundred, is the point.** An accidental loop of rich calls trips ten
/// times sooner than the ordinary budget would let it, so the failure is visible the same
/// hour rather than the same day — and a rich call is not a thing ordinary use does a hundred
/// times: it is asked once, about one place, when a rating was not enough. A rich call ALSO
/// counts against [`DEFAULT_GOOGLE_MAX_CALLS`], because it is still a call; the two ceilings
/// are an AND, never an either/or.
pub const DEFAULT_GOOGLE_MAX_RICH_CALLS: u32 = 20;

/// The budget window in seconds, when `JESSE_PLACES_GOOGLE_WINDOW_SECS` is unset. A rolling
/// 24 hours — rolling rather than calendar-daily so a loop at 23:55 cannot spend two days'
/// allowance in ten minutes.
pub const DEFAULT_GOOGLE_WINDOW_SECS: u64 = 86_400;

/// The ledger's filename inside the bridge's state directory.
pub const DEFAULT_GOOGLE_LEDGER_FILE: &str = "places-google-calls.log";

/// Longest place id accepted. Google's ids are opaque and have no documented maximum; this is
/// a sanity bound on a string that reaches a URL path, not a claim about their format.
const MAX_PLACE_ID_LEN: usize = 255;

/// Rewrite the ledger rather than appending once it holds this many lines. Keeps a file that
/// is read on every call from growing without bound while leaving plenty of expired history
/// visible to a human reading it.
const LEDGER_REWRITE_LINES: usize = 4_000;

// ---------------------------------------------------------------------------------------
// The key
// ---------------------------------------------------------------------------------------

/// The API key, in a wrapper whose `Debug` does not print it.
///
/// [`crate::places::PlacesConfig`] derives `Debug` and this server's failures are reported to a
/// turn as text. A key that can be `{:?}`-ed is a key that eventually appears in a tool result,
/// a log line or a bug report; a newtype that cannot be formatted is the cheapest way to make
/// that impossible rather than merely unlikely.
#[derive(Clone)]
pub struct ApiKey(String);

impl ApiKey {
    pub fn new(raw: impl Into<String>) -> Self {
        Self(raw.into())
    }
    /// The only way to read it back. Used at exactly one call site: the request header.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for ApiKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ApiKey(<redacted>)")
    }
}

// ---------------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------------

/// Everything the Google provider needs. Its presence in
/// [`crate::places::PlacesConfig::google`] is what "a key is configured" means.
#[derive(Clone, Debug)]
pub struct GoogleConfig {
    pub api_key: ApiKey,
    /// Base URL with no trailing slash.
    pub base_url: String,
    /// See [`DEFAULT_GOOGLE_MAX_CALLS`].
    pub max_calls: u32,
    /// See [`DEFAULT_GOOGLE_MAX_RICH_CALLS`]. Counted over the same window, against the
    /// subset of calls made at [`DetailLevel::Rich`].
    pub rich_max_calls: u32,
    /// See [`DEFAULT_GOOGLE_WINDOW_SECS`].
    pub window: Duration,
    /// Where the call ledger lives. `None` means no writable location could be resolved,
    /// which **disables the provider** — see [`CallLedger::reserve`].
    pub ledger: Option<PathBuf>,
}

impl GoogleConfig {
    /// Read the environment. `None` — and therefore no Google provider at all — when
    /// `JESSE_PLACES_GOOGLE_API_KEY` is unset or blank.
    ///
    /// The key is read from the ENVIRONMENT and from nowhere else: not from a config file in
    /// the vault (which the child can write), not from a tool argument, and not from argv
    /// (which the containment record commits verbatim). It is placed there by the bridge's
    /// launchd plist, the same way the Home Assistant token is.
    pub fn from_env() -> Option<Self> {
        let key = non_empty("JESSE_PLACES_GOOGLE_API_KEY")?;
        Some(Self {
            api_key: ApiKey::new(key),
            base_url: non_empty("JESSE_PLACES_GOOGLE_BASE_URL")
                .map(|s| s.trim_end_matches('/').to_string())
                .unwrap_or_else(|| DEFAULT_GOOGLE_BASE_URL.to_string()),
            max_calls: non_empty("JESSE_PLACES_GOOGLE_MAX_CALLS")
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(DEFAULT_GOOGLE_MAX_CALLS),
            rich_max_calls: non_empty("JESSE_PLACES_GOOGLE_MAX_RICH_CALLS")
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(DEFAULT_GOOGLE_MAX_RICH_CALLS),
            window: non_empty("JESSE_PLACES_GOOGLE_WINDOW_SECS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or_else(|| Duration::from_secs(DEFAULT_GOOGLE_WINDOW_SECS)),
            ledger: resolve_ledger_path(),
        })
    }
}

/// `JESSE_PLACES_GOOGLE_LEDGER`, else `<JESSE_STATE_DIR>/places-google-calls.log`, else
/// `$HOME/.jesse-bridge/places-google-calls.log` — the same two-step the bridge's own
/// `state_dir` default uses, so the ledger lands beside `jobs/` and `artifacts/` rather than
/// in a third place a reader has to be told about.
///
/// `None` when neither resolves, which switches the provider off rather than spending
/// unmetered.
fn resolve_ledger_path() -> Option<PathBuf> {
    if let Some(explicit) = non_empty("JESSE_PLACES_GOOGLE_LEDGER") {
        return Some(PathBuf::from(explicit));
    }
    let dir = non_empty("JESSE_STATE_DIR")
        .or_else(|| non_empty("HOME").map(|h| format!("{h}/.jesse-bridge")))?;
    Some(PathBuf::from(dir).join(DEFAULT_GOOGLE_LEDGER_FILE))
}

fn non_empty(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty())
}

// ---------------------------------------------------------------------------------------
// The budget
// ---------------------------------------------------------------------------------------

/// What the budget looked like after a reservation, reported to the caller on every response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BudgetState {
    pub used: u32,
    pub limit: u32,
    pub window_seconds: u64,
    /// Calls in the window made at [`DetailLevel::Rich`]. A subset of `used`, never a second pool.
    pub rich_used: u32,
    /// See [`DEFAULT_GOOGLE_MAX_RICH_CALLS`].
    pub rich_limit: u32,
}

impl BudgetState {
    /// The ordinary budget, in **exactly the three keys 0.104.0 emitted and with exactly the
    /// same values**. The rich counters are a SIBLING object rather than two more keys in
    /// here, so a caller — or a test — reading `budget` sees no change from a change that was
    /// supposed to leave the default alone. See [`BudgetState::rich_as_json`].
    pub fn as_json(&self) -> Value {
        json!({
            "used": self.used,
            "limit": self.limit,
            "window_seconds": self.window_seconds,
        })
    }

    /// The second ceiling, reported alongside the first whenever there is a paid provider to
    /// have one — not only on rich calls. An operator asking "did something loop overnight"
    /// should not have to make a rich call to find out.
    pub fn rich_as_json(&self) -> Value {
        json!({
            "used": self.rich_used,
            "limit": self.rich_limit,
            "window_seconds": self.window_seconds,
        })
    }
}

/// The spend guard, and the audit log, as one file.
///
/// # Why it is a file and not a counter
///
/// `jesse-places-mcp` is spawned **per turn**, as a child of the harness child. An in-process
/// counter would therefore reset every time the conversation asked a question, which bounds a
/// runaway loop inside one turn and bounds nothing at all across a day — the shape that
/// actually produces a bill. The ledger is on disk so the budget survives the process, and it
/// is plain text with one line per billed call so that "is something looping?" is answerable
/// with `wc -l` rather than with a tool.
///
/// # It fails CLOSED, in both directions
///
/// A reservation is taken BEFORE the request goes out, not after it succeeds: a request that
/// reaches Google and comes back 4xx may still have been billed, and a guard that only counts
/// successes is a guard a failing loop walks straight through.
///
/// And if the ledger cannot be read or written — no writable state directory, a permissions
/// problem, a full disk — the provider is REFUSED and the call falls back to OpenStreetMap.
/// "We could not check the budget" must never read as "the budget is fine"; the fallback keeps
/// the tool working, and the response says why it happened.
///
/// # What it deliberately does not do
///
/// It does not lock the file across processes. Two turns running concurrently can each read
/// the same count and each reserve, so the effective ceiling is `limit + (concurrent callers -
/// 1)`. An `flock` would close that, at the cost of a blocking syscall on a path that must
/// never hang a turn; being one or two calls over a 200-call ceiling is not the failure this
/// guards against.
pub struct CallLedger {
    path: Option<PathBuf>,
    limit: u32,
    /// The second ceiling, over the rich subset of the same window. See
    /// [`DEFAULT_GOOGLE_MAX_RICH_CALLS`].
    rich_limit: u32,
    window: Duration,
    /// Serialises this process's own read-then-append, so two tool calls in one turn cannot
    /// both observe the same count.
    gate: Mutex<()>,
}

impl CallLedger {
    pub fn new(cfg: &GoogleConfig) -> Self {
        Self {
            path: cfg.ledger.clone(),
            limit: cfg.max_calls,
            rich_limit: cfg.rich_max_calls,
            window: cfg.window,
            gate: Mutex::new(()),
        }
    }

    /// Count the calls inside the rolling window and, if there is room, write the line for the
    /// call about to be made.
    ///
    /// `Ok(state)` means the call may proceed and has already been counted. `Err(reason)` is a
    /// sentence for the caller to put in `provider_fallback_reason` — it names the ceiling and
    /// the window, because "the budget tripped" without the numbers is not actionable.
    ///
    /// `detail` decides BOTH which ceiling the call is held to and which tier the ledger line
    /// records. A rich call is checked against both ceilings and counts against both: it is a
    /// dearer call, not a different pool.
    pub async fn reserve(&self, tool: &str, detail: DetailLevel) -> Result<BudgetState, String> {
        let _gate = self.gate.lock().await;
        let Some(path) = self.path.as_ref() else {
            return Err(
                "no writable location could be resolved for the request ledger, so the \
                 per-request-billed provider cannot be metered and is refused; set \
                 JESSE_PLACES_GOOGLE_LEDGER or JESSE_STATE_DIR"
                    .to_string(),
            );
        };
        let now = Utc::now();
        let kept = self.read_window(path, now).map_err(|e| {
            format!(
                "the request ledger at {} could not be read, so the per-request-billed \
                 provider cannot be metered and is refused ({e})",
                path.display()
            )
        })?;
        let used = kept.in_window as u32;
        let rich_used = kept.rich_in_window as u32;
        if used >= self.limit {
            return Err(format!(
                "the request budget for the preferred provider is spent: {used} of {} calls \
                 in the last {} seconds. It refills as the window rolls forward; raise it with \
                 JESSE_PLACES_GOOGLE_MAX_CALLS if this is expected traffic rather than a loop",
                self.limit,
                self.window.as_secs()
            ));
        }
        // THE SECOND CEILING, AND IT TRIPS INDEPENDENTLY. A rich call is billed at a dearer
        // tier, so a loop of them spends far more than the same number of ordinary calls;
        // this is the number that makes such a loop visible while the ordinary budget still
        // has nine tenths of its room left. The refusal names the ceiling it hit and says
        // that the cheap answer is still available, because it is — the caller can drop back
        // to `standard` and get an answer rather than nothing.
        if detail.is_rich() && rich_used >= self.rich_limit {
            return Err(format!(
                "the request budget for the richer field set is spent: {rich_used} of {} such \
                 calls in the last {} seconds (the ordinary budget is untouched at {used} of \
                 {}). Ask again without the richer field set for the cheaper answer, or raise \
                 it with JESSE_PLACES_GOOGLE_MAX_RICH_CALLS if this is expected traffic \
                 rather than a loop",
                self.rich_limit,
                self.window.as_secs(),
                self.limit,
            ));
        }
        let state = BudgetState {
            used: used + 1,
            limit: self.limit,
            window_seconds: self.window.as_secs(),
            rich_used: rich_used + u32::from(detail.is_rich()),
            rich_limit: self.rich_limit,
        };
        // The tier column is what [`CallLedger::read_window`] reads back to tell the two
        // ceilings apart, so it is the tier and not a label. A standard line is byte-identical
        // to the one 0.104.0 wrote; a rich line carries a fifth column naming the second
        // count, because a reader asking "what tripped" should not have to tally the file.
        let line = if detail.is_rich() {
            format!(
                "{}\t{}\t{}\t{}/{}\trich={}/{}\n",
                now.to_rfc3339(),
                tool,
                detail.cost_tier(),
                state.used,
                state.limit,
                state.rich_used,
                state.rich_limit,
            )
        } else {
            format!(
                "{}\t{}\t{}\t{}/{}\n",
                now.to_rfc3339(),
                tool,
                detail.cost_tier(),
                state.used,
                state.limit
            )
        };
        self.append(path, line, kept).map_err(|e| {
            format!(
                "the request ledger at {} could not be written, so the per-request-billed \
                 provider cannot be metered and is refused ({e})",
                path.display()
            )
        })?;
        Ok(state)
    }

    /// The budget as it stands, without reserving. Used to report `budget` on a response that
    /// did not reach the provider (no matching category, say) so the number is always visible.
    pub async fn peek(&self) -> Option<BudgetState> {
        let _gate = self.gate.lock().await;
        let path = self.path.as_ref()?;
        let kept = self.read_window(path, Utc::now()).ok()?;
        Some(BudgetState {
            used: kept.in_window as u32,
            limit: self.limit,
            window_seconds: self.window.as_secs(),
            rich_used: kept.rich_in_window as u32,
            rich_limit: self.rich_limit,
        })
    }

    fn read_window(&self, path: &PathBuf, now: DateTime<Utc>) -> std::io::Result<Window> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(e),
        };
        let cutoff = now - chrono::Duration::from_std(self.window).unwrap_or(chrono::Duration::MAX);
        let mut in_window = 0usize;
        let mut rich_in_window = 0usize;
        let mut total = 0usize;
        let mut fresh = String::new();
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            total += 1;
            // A line whose timestamp does not parse is COUNTED AS IN-WINDOW rather than
            // skipped. The alternative lets a corrupted or truncated ledger read as "nothing
            // has been spent", which is the one wrong answer that costs money.
            let stamp = line.split('\t').next().unwrap_or("");
            let inside = match DateTime::parse_from_rfc3339(stamp) {
                Ok(t) => t.with_timezone(&Utc) >= cutoff,
                Err(_) => true,
            };
            if inside {
                in_window += 1;
                // Same rule one column over, and for the same reason: a line whose tier
                // column is MISSING OR UNREADABLE counts against the RICH ceiling too. A
                // damaged ledger must not read as "none of this was the expensive kind" —
                // that is the wrong answer that costs the most money. A line written by
                // 0.104.0 carries `enterprise` here and is correctly not counted.
                let tier = line.split('\t').nth(2);
                if tier.is_none_or(|t| t == DetailLevel::Rich.cost_tier()) {
                    rich_in_window += 1;
                }
                fresh.push_str(line);
                fresh.push('\n');
            }
        }
        Ok(Window {
            in_window,
            rich_in_window,
            total,
            fresh,
        })
    }

    fn append(&self, path: &PathBuf, line: String, window: Window) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        if window.total > LEDGER_REWRITE_LINES {
            // Rewrite through a sibling temp file so a crash mid-write cannot leave a
            // half-ledger that reads as "nothing spent".
            let tmp = path.with_extension("log.tmp");
            std::fs::write(&tmp, format!("{}{line}", window.fresh))?;
            std::fs::rename(&tmp, path)?;
            return Ok(());
        }
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        f.write_all(line.as_bytes())
    }
}

struct Window {
    in_window: usize,
    /// The subset of `in_window` whose tier column says the dearer mask was used.
    rich_in_window: usize,
    total: usize,
    /// The in-window lines, for the rewrite path.
    fresh: String,
}

// ---------------------------------------------------------------------------------------
// The wire
// ---------------------------------------------------------------------------------------

/// Validate a Google place id.
///
/// **This is the only caller-supplied string that reaches Google**, and it reaches one only
/// after passing here. Google's ids are opaque base64url-ish tokens, so the accepted alphabet
/// is exactly that: `A-Z a-z 0-9 _ -`. Nothing in that set is meaningful in a URL path, which
/// is where the value goes, so there is nothing to escape — same property, and the same
/// reasoning, as [`crate::places::parse_place_id`].
pub fn validate_google_place_id(id: &str) -> Result<&str, String> {
    let id = id.trim();
    if id.is_empty() || id.len() > MAX_PLACE_ID_LEN {
        return Err(format!(
            "malformed place id: expected 1 to {MAX_PLACE_ID_LEN} characters of \
             [A-Za-z0-9_-], got {} ",
            id.len()
        ));
    }
    if !id
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err(
            "malformed place id: only letters, digits, underscore and hyphen are accepted"
                .to_string(),
        );
    }
    Ok(id)
}

/// The Google provider: a budget, a config, and two request shapes.
///
/// It borrows the caller's [`reqwest::Client`] rather than building its own — the shared one
/// already carries the timeout, and a second connection pool for two request shapes buys
/// nothing. What it does NOT share is [`crate::places::PlacesClient`]'s rate gate or its
/// response cache: the gate exists for Nominatim's one-request-per-second client policy, which
/// says nothing about this API, and the cache is forbidden here (see the module docs).
pub struct GoogleProvider {
    pub cfg: GoogleConfig,
    pub ledger: CallLedger,
}

impl GoogleProvider {
    pub fn new(cfg: GoogleConfig) -> Self {
        let ledger = CallLedger::new(&cfg);
        Self { cfg, ledger }
    }

    /// `places:searchNearby`. Returns the parsed response body and the budget after the call.
    ///
    /// `types` is a slice of `'static` strings from the closed category table; `lat`, `lon`,
    /// `radius` and `max` are numbers this crate has already range-checked. **There is no
    /// parameter here a caller can author.**
    // Eight, and each one is a distinct number the request needs. Bundling them into a
    // struct would move the same values behind a name that says nothing the parameter names
    // do not — the same call the OpenStreetMap half already made for `osm_hits`.
    #[allow(clippy::too_many_arguments)]
    pub async fn search_nearby(
        &self,
        http: &reqwest::Client,
        types: &[&'static str],
        lat: f64,
        lon: f64,
        radius: u32,
        max: usize,
        detail: DetailLevel,
    ) -> Result<(Value, BudgetState), String> {
        let budget = self.ledger.reserve("places_search", detail).await?;
        let mut body = json!({
            "maxResultCount": max.clamp(1, GOOGLE_MAX_RESULTS),
            "rankPreference": "DISTANCE",
            "locationRestriction": {
                "circle": {
                    "center": {"latitude": lat, "longitude": lon},
                    "radius": f64::from(radius),
                }
            },
        });
        // An EMPTY type list is sent as no `includedTypes` at all, which is Nearby Search's
        // "every type" — the counterpart of this server's broad OSM fallback tag set, and the
        // right answer for a query naming no category this table knows.
        if !types.is_empty() {
            body["includedTypes"] = json!(types);
        }
        let url = format!("{}/places:searchNearby", self.cfg.base_url);
        // Serialised here rather than through reqwest's `json` feature, which this crate does
        // not enable — the OpenStreetMap path posts its body the same way, for the same
        // reason: one fewer optional feature in a dependency graph `cargo audit` gates.
        let text = self
            .send(
                http.post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(body.to_string()),
                google_search_field_mask(detail),
                "places_search",
            )
            .await?;
        let parsed: Value = serde_json::from_str(&text)
            .map_err(|e| format!("the preferred provider returned unreadable JSON: {e}"))?;
        Ok((parsed, budget))
    }

    /// `places/{id}`. `id` must already have passed [`validate_google_place_id`].
    pub async fn details(
        &self,
        http: &reqwest::Client,
        id: &str,
        detail: DetailLevel,
    ) -> Result<(Value, BudgetState), String> {
        let id = validate_google_place_id(id)?;
        let budget = self.ledger.reserve("place_details", detail).await?;
        let url = format!("{}/places/{id}", self.cfg.base_url);
        let text = self
            .send(
                http.get(&url),
                google_details_field_mask(detail),
                "place_details",
            )
            .await?;
        let parsed: Value = serde_json::from_str(&text)
            .map_err(|e| format!("the preferred provider returned unreadable JSON: {e}"))?;
        Ok((parsed, budget))
    }

    /// One request: key header, field mask header, send, classify.
    ///
    /// The key goes in `X-Goog-Api-Key` and is read through [`ApiKey::expose`] here and
    /// nowhere else in the crate.
    async fn send(
        &self,
        req: reqwest::RequestBuilder,
        field_mask: &str,
        tool: &str,
    ) -> Result<String, String> {
        let resp = req
            .header("X-Goog-Api-Key", self.cfg.api_key.expose())
            .header("X-Goog-FieldMask", field_mask)
            .send()
            .await
            .map_err(|e| format!("the request to the preferred provider failed: {e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("reading the preferred provider's response failed: {e}"))?;
        // The ledger line is already written — see `reserve` — so the outcome goes to stderr,
        // where the harness collects this server's diagnostics. It carries no response content
        // and no key: a status, a tool name and a length.
        eprintln!(
            "jesse-places-mcp: preferred provider {tool} -> HTTP {} ({} bytes); the call is \
             already recorded in the request ledger",
            status.as_u16(),
            text.len(),
        );
        if status.is_success() {
            return Ok(text);
        }
        Err(describe_google_failure(status.as_u16(), &text))
    }
}

/// Turn a failed Google status into something a turn — and a person reading a log — can act
/// on, WITHOUT echoing the body.
///
/// The body is dropped rather than snipped, which is the opposite of the OSM path's
/// [`crate::places::describe_http_failure`], and deliberately: Google's error envelope repeats
/// request parameters back, and a 400 caused by a malformed key can quote it. There is no
/// value in the body worth the risk that one day it contains the key.
pub fn describe_google_failure(status: u16, body: &str) -> String {
    let advice = match status {
        400 => {
            "the preferred provider rejected the request as malformed; this is a defect in \
             this server rather than something a caller can fix"
        }
        401 | 403 => {
            "the preferred provider refused the credential — the key is missing, expired, or \
             restricted away from this API"
        }
        429 => "the preferred provider is rate-limiting or the project's quota is spent",
        s if s >= 500 => "the preferred provider failed",
        _ => "the preferred provider refused the request",
    };
    // The reason phrase Google puts in `error.status` is a fixed enum (`PERMISSION_DENIED`,
    // `RESOURCE_EXHAUSTED`, …), so it is safe to pass through where the message is not.
    let code = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.get("error")
                .and_then(|e| e.get("status"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|s| s.bytes().all(|b| b.is_ascii_uppercase() || b == b'_'));
    match code {
        Some(c) => format!("HTTP {status}: {advice} ({c})"),
        None => format!("HTTP {status}: {advice}"),
    }
}

// ---------------------------------------------------------------------------------------
// Mapping into the shared shape
// ---------------------------------------------------------------------------------------

/// Google's `regularOpeningHours`, mapped onto [`OpeningHours`].
///
/// # Why this exists rather than a second hours shape
///
/// Google returns hours as `periods` (a list of open/close instants, each a weekday plus a
/// clock time) and OSM returns them as a string in its own grammar. If those two reached a
/// caller as two shapes, every consumer would have to branch on the provider to read hours —
/// which is exactly the coupling the provider-agnostic tool names exist to prevent. So this
/// lands on the SAME [`OpeningHours`] the OSM parser produces, and both are rendered by the
/// same [`hours_json_from`].
///
/// # The day numbering, which is off by one between the two
///
/// Google's `day` is **0 = Sunday**; this crate's index is **0 = Monday**, matching
/// `chrono::Weekday::num_days_from_monday`. Every mapping goes through [`google_day_index`].
///
/// # Overnight
///
/// A period whose close falls on the next day is emitted as ONE interval on the opening day
/// with `end <= start`, which is precisely what [`Interval::crosses_midnight`] means and what
/// the OSM parser produces for `Fr 20:00-02:00`. A period longer than 24 hours cannot be said
/// that way, so it is split across the days it covers instead.
pub fn hours_from_google(periods: &[Value]) -> Result<OpeningHours, String> {
    let mut out = OpeningHours::default();
    if periods.is_empty() {
        return Err("the provider returned opening hours with no periods in them".to_string());
    }
    // A single open at the provider's week-zero instant with NO close is its way of saying
    // "always open". That convention is checked rather than assumed: any OTHER never-closing
    // period is a shape this function does not read, and treating it as `24/7` would report a
    // venue as open at 04:00 on the strength of a field nobody verified.
    if periods.len() == 1 && periods[0].get("close").is_none() {
        let at = periods[0]
            .get("open")
            .and_then(absolute_minute)
            .ok_or_else(|| "the only opening-hours period has an unreadable instant".to_string())?;
        if at != google_day_index(0) as u32 * 1440 {
            return Err(
                "the only opening-hours period never closes but does not start at the \
                 provider's always-open instant; refusing to guess what that means"
                    .to_string(),
            );
        }
        out.always_open = true;
        for d in 0..7 {
            out.days[d] = vec![Interval {
                start: 0,
                end: 1440,
            }];
        }
        return Ok(out);
    }
    for (i, p) in periods.iter().enumerate() {
        let open = p
            .get("open")
            .ok_or_else(|| format!("opening-hours period {i} has no opening instant"))?;
        let Some(close) = p.get("close") else {
            return Err(format!(
                "opening-hours period {i} never closes, but it is not the only period; \
                 refusing to guess what that means"
            ));
        };
        let open_abs = absolute_minute(open)
            .ok_or_else(|| format!("opening-hours period {i} has an unreadable opening instant"))?;
        let close_abs = absolute_minute(close)
            .ok_or_else(|| format!("opening-hours period {i} has an unreadable closing instant"))?;
        let close_abs = if close_abs <= open_abs {
            close_abs + 7 * 1440
        } else {
            close_abs
        };
        for (day, iv) in spread(open_abs, close_abs) {
            if !out.days[day].contains(&iv) {
                out.days[day].push(iv);
            }
        }
    }
    for d in out.days.iter_mut() {
        d.sort_by_key(|iv| iv.start);
    }
    Ok(out)
}

/// Minutes since Monday 00:00, from a `{day, hour, minute}` instant.
fn absolute_minute(v: &Value) -> Option<u32> {
    let day = v.get("day").and_then(Value::as_u64).unwrap_or(0);
    let hour = v.get("hour").and_then(Value::as_u64).unwrap_or(0);
    let minute = v.get("minute").and_then(Value::as_u64).unwrap_or(0);
    if day > 6 || hour > 23 || minute > 59 {
        return None;
    }
    let day = google_day_index(day as usize);
    Some((day as u32) * 1440 + (hour as u32) * 60 + minute as u32)
}

/// Google's 0 = Sunday to this crate's 0 = Monday.
pub fn google_day_index(day: usize) -> usize {
    (day + 6) % 7
}

/// One open→close span as per-day intervals.
///
/// Up to 24 hours long it stays a SINGLE interval on the opening day, so an overnight span is
/// expressed the way the OSM parser expresses it. Longer than that it is split at each
/// midnight it crosses, because a single `Interval` cannot say "48 hours".
fn spread(open_abs: u32, close_abs: u32) -> Vec<(usize, Interval)> {
    let day = ((open_abs / 1440) % 7) as usize;
    if close_abs - open_abs <= 1440 {
        return vec![(
            day,
            Interval {
                start: (open_abs % 1440) as u16,
                end: (close_abs % 1440) as u16,
            },
        )];
    }
    let mut out = Vec::new();
    let mut cursor = open_abs;
    while cursor < close_abs {
        let day = ((cursor / 1440) % 7) as usize;
        let day_start = (cursor / 1440) * 1440;
        let day_end = day_start + 1440;
        let seg_end = close_abs.min(day_end);
        out.push((
            day,
            Interval {
                start: (cursor - day_start) as u16,
                end: (seg_end - day_start) as u16,
            },
        ));
        cursor = seg_end;
    }
    out
}

/// The provider's own hours text, kept verbatim.
///
/// Google gives no single `opening_hours` string; it gives `weekdayDescriptions`, one
/// human-readable line per weekday, in the response's language. Those lines are joined with a
/// newline and NOTHING ELSE is done to them — no reformatting, and above all no rewriting into
/// OSM's grammar, which would be this server inventing a source string and putting a provider's
/// name on it. When the provider sends no descriptions the raw field falls back to the verbatim
/// JSON of what it did send, so `opening_hours_raw` is never absent while `opening_hours` is
/// present.
fn google_hours_raw(hours: &Value) -> String {
    let lines: Vec<&str> = hours
        .get("weekdayDescriptions")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if lines.is_empty() {
        return hours.to_string();
    }
    lines.join("\n")
}

/// Build one place record from a Google `Place`.
///
/// **Every optional field is OMITTED when the provider did not send it**, on exactly the terms
/// [`crate::places::place_json`] states for OSM: a null in `phone` reads as "this place has no
/// phone", which is a claim the data does not support.
///
/// `dist_m` is `NAN` for `place_details`, which names a place rather than a search centre.
pub(crate) fn google_place_json(place: &Value, dist_m: f64, zone: &Zone) -> Value {
    let mut out = Map::new();
    let id = place.get("id").and_then(Value::as_str).unwrap_or("");
    // The id a caller hands back to `place_details`. The prefix is a ROUTING KEY, not a label:
    // `place_details` has to know which service an id belongs to before it can look it up, and
    // an opaque token carries nothing that says so. OSM ids keep their existing
    // `node|way|relation/<n>` form unchanged.
    out.insert("id".to_string(), json!(format!("google/{id}")));
    out.insert(
        "provider".to_string(),
        json!(Provider::GooglePlaces.label()),
    );
    out.insert(
        "name".to_string(),
        json!(place
            .get("displayName")
            .and_then(|d| d.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("")),
    );
    if let Some(loc) = place.get("location") {
        if let (Some(lat), Some(lon)) = (
            loc.get("latitude").and_then(Value::as_f64),
            loc.get("longitude").and_then(Value::as_f64),
        ) {
            out.insert(
                "coordinates".to_string(),
                json!({"latitude": lat, "longitude": lon}),
            );
        }
    }
    if dist_m.is_finite() {
        out.insert("distance_m".to_string(), json!(dist_m.round() as i64));
    }
    if let Some(t) = place.get("primaryType").and_then(Value::as_str) {
        out.insert("category".to_string(), json!(t));
    }
    if let Some(a) = place.get("formattedAddress").and_then(Value::as_str) {
        out.insert("address".to_string(), json!(a));
        out.insert("address_source".to_string(), json!("provider"));
    }
    if let Some(p) = place.get("nationalPhoneNumber").and_then(Value::as_str) {
        out.insert("phone".to_string(), json!(p));
    }
    if let Some(w) = place.get("websiteUri").and_then(Value::as_str) {
        out.insert("website".to_string(), json!(w));
    }

    // THE TWO RATING FIELDS. Both, or neither.
    //
    // A rating with no count is not usable information — 5.0 from one person and 4.6 from
    // eleven thousand are not the same claim, and a caller shown only the number cannot tell
    // them apart. So a record carrying one without the other emits NEITHER, on the same terms
    // the OSM path emits no `rating` key at all.
    if let (Some(rating), Some(count)) = (
        place.get("rating").and_then(Value::as_f64),
        place.get("userRatingCount").and_then(Value::as_u64),
    ) {
        out.insert("rating".to_string(), json!(rating));
        out.insert("rating_count".to_string(), json!(count));
    }

    // THE TWO HOURS FIELDS. Both, or neither — and rendered by the same function the OSM path
    // uses, so the two providers cannot drift into two shapes.
    if let Some(hours) = place.get("regularOpeningHours") {
        let raw = google_hours_raw(hours);
        let periods: Vec<Value> = hours
            .get("periods")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        out.insert("opening_hours_raw".to_string(), json!(raw));
        out.insert(
            "opening_hours".to_string(),
            hours_json_from(hours_from_google(&periods), zone),
        );
    }

    // THE RICHER FIELDS, WHICH ARRIVE ONLY WHEN THE RICHER MASK ASKED FOR THEM.
    //
    // Driven by PRESENCE rather than by a flag passed down here, on exactly the terms every
    // other optional field in this function is: the mask is what decides whether they are in
    // the response, and a second switch here could only ever disagree with it.
    if let Some(s) = place
        .get("editorialSummary")
        .and_then(|e| e.get("text"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        out.insert("editorial_summary".to_string(), json!(s));
    }
    if let Some(raw) = place.get("reviews").and_then(Value::as_array) {
        let mut kept = Vec::new();
        let mut withheld = 0usize;
        for r in raw {
            match review_json(r) {
                Some(v) => kept.push(v),
                None => withheld += 1,
            }
        }
        if !kept.is_empty() {
            out.insert("reviews".to_string(), json!(kept));
            out.insert("reviews_notice".to_string(), json!(REVIEWS_NOTICE));
        }
        // NO SILENT DROP. A review that cannot be shown within the provider's terms is not
        // returned (see [`review_json`]), and the count of those is reported rather than
        // quietly absorbed — otherwise "three reviews" and "three of five reviews" read
        // identically.
        if withheld > 0 {
            out.insert("reviews_withheld".to_string(), json!(withheld));
        }
    }

    // Attribution, which the terms require and the tool therefore carries. The constant names
    // the source; the array is whatever third-party credit the provider attached, passed
    // through untouched.
    out.insert("attribution".to_string(), json!(GOOGLE_ATTRIBUTION));
    if let Some(a) = place
        .get("attributions")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty())
    {
        out.insert("attributions".to_string(), json!(a));
    }
    Value::Object(out)
}

/// One review, mapped — or `None` when it cannot be returned within the provider's terms.
///
/// # Review text is not a rating, and the difference is a set of obligations
///
/// A rating is a number this server may print with a `Google Maps` credit. Review text comes
/// with named requirements on the Places API policy page, and they are met HERE rather than
/// left to the caller, because the caller is a language model that will summarise whatever it
/// is handed:
///
///   * *"You must always credit the author when displaying photos or reviews. Each photo and
///     review includes an author attribution (author's avatar image, name, and profile
///     link)."* — so `author` carries the name, the profile link and the avatar URI, exactly
///     as they arrived.
///   * *"For each photo and review, end-users must always have access to view the individual
///     source photo or review on Google Maps using the provided `googleMapsUri`."* — so
///     `source_url` is carried on every review.
///   * *"When displaying reviews of places in France and French territories, the Places API
///     returns a `visitDate` … which must be displayed alongside the content."* — carried
///     whenever the provider sends one, which is the only case in which it is required.
///   * *"Displaying the relative publish date … increases user trust"* and *"You and your
///     end-users can report content … using the `flagContentUri`"* are recommendations rather
///     than requirements; both are carried anyway, because they cost nothing once the review
///     is in hand and a caller cannot add them later.
///
/// **A review with no author attribution or no source link is DROPPED.** Those two are
/// requirements, not fields — a review returned without them is one the caller cannot legally
/// show, and handing it over anyway would put the obligation somewhere it cannot be met. This
/// has not been observed in a live response; it is the shape of the check that matters.
///
/// # What is NOT done to the text
///
/// Nothing. It is not truncated, not summarised, not reordered and not filtered — the array
/// keeps the provider's own order, which its policy page says is by relevance, and
/// [`REVIEWS_NOTICE`] says so on the record. Editing it here would make the notice a lie and
/// would also be this server creating content out of the provider's content.
fn review_json(r: &Value) -> Option<Value> {
    let author = r.get("authorAttribution")?;
    let author_name = author
        .get("displayName")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;
    let source_url = r
        .get("googleMapsUri")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;

    let mut out = Map::new();
    let mut credit = Map::new();
    credit.insert("name".to_string(), json!(author_name));
    for (from, to) in [("uri", "profile_url"), ("photoUri", "avatar_url")] {
        if let Some(v) = author
            .get(from)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            credit.insert(to.to_string(), json!(v));
        }
    }
    out.insert("author".to_string(), Value::Object(credit));
    out.insert("source_url".to_string(), json!(source_url));

    if let Some(v) = r.get("rating").and_then(Value::as_f64) {
        out.insert("rating".to_string(), json!(v));
    }
    // The localized text, and — when the provider translated it — the original alongside, so
    // a caller can meet the *"Make end users aware when a review has been translated from its
    // original language"* recommendation instead of presenting a translation as the author's
    // own words.
    let text = r
        .get("text")
        .and_then(|t| t.get("text"))
        .and_then(Value::as_str);
    let original = r
        .get("originalText")
        .and_then(|t| t.get("text"))
        .and_then(Value::as_str);
    if let Some(t) = text.filter(|s| !s.is_empty()) {
        out.insert("text".to_string(), json!(t));
    }
    if let Some(o) = original.filter(|s| !s.is_empty()) {
        if Some(o) != text {
            out.insert("original_text".to_string(), json!(o));
            out.insert("translated".to_string(), json!(true));
        }
    }
    for (from, to) in [
        ("relativePublishTimeDescription", "published"),
        ("publishTime", "published_at"),
        ("flagContentUri", "report_url"),
    ] {
        if let Some(v) = r
            .get(from)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            out.insert(to.to_string(), json!(v));
        }
    }
    // Required alongside the content for places in France and French territories, and sent
    // only there — so it is passed through verbatim wherever it appears rather than reformatted
    // into a string this server invented.
    if let Some(d) = r.get("visitDate") {
        out.insert("visit_date".to_string(), d.clone());
    }
    Some(Value::Object(out))
}

/// The notice that has to travel with review text, in the provider's own terms.
///
/// Its policy page requires *"a clear notice that describes how reviews are being ordered and
/// filtered including any search criteria applied"* and states *"By default, reviews are
/// ordered by relevance"*; it also asks that end users be informed that *"Reviews aren't
/// verified by Google, but Google checks for and removes fake content when it's identified."*
///
/// This server applies no ordering and no filtering of its own, so the honest notice is that
/// it applied none — which is only true because [`google_place_json`] keeps the array as it
/// arrived. It is a VALUE and not a field name, so naming the source in it breaks nothing;
/// [`GOOGLE_ATTRIBUTION`] is the same shape of thing.
pub const REVIEWS_NOTICE: &str = "These reviews are in the order the source returned them, \
     which is by relevance rather than by date; none were filtered, reordered, edited or \
     truncated here, and they are a selection rather than every review of this place. Reviews \
     are not verified by Google, which removes fake content when it identifies it. If any of \
     this text is shown to a person, credit its author and give access to `source_url`.";

/// The attribution string carried on every record from this provider.
///
/// The Places policy page: *"Attribution should take the form of the Google Maps logo whenever
/// possible. In cases where space is limited, the text Google Maps is acceptable."* A JSON tool
/// result has no room for a logo, so it carries the text.
pub const GOOGLE_ATTRIBUTION: &str = "Google Maps";

/// Does this record's name match the caller's name terms? Same folding, same rule, and the
/// same reasoning as the OSM side — the free text is applied HERE, to the response, and never
/// on the wire.
pub fn google_name_hit(place: &Value, terms: &[String]) -> bool {
    if terms.is_empty() {
        return true;
    }
    let name = fold_name(
        place
            .get("displayName")
            .and_then(|d| d.get("text"))
            .and_then(Value::as_str)
            .unwrap_or(""),
    );
    terms.iter().any(|t| name.contains(t))
}

/// Great-circle distance from the search centre, computed here because Nearby Search does not
/// return one.
pub fn google_distance(place: &Value, lat: f64, lon: f64) -> Option<f64> {
    let loc = place.get("location")?;
    Some(haversine_m(
        lat,
        lon,
        loc.get("latitude").and_then(Value::as_f64)?,
        loc.get("longitude").and_then(Value::as_f64)?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::places::{parse_opening_hours, PlacesConfig, Zone};

    fn zone() -> Zone {
        Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        }
    }

    fn cfg_with(dir: &std::path::Path, limit: u32, window_secs: u64) -> GoogleConfig {
        GoogleConfig {
            api_key: ApiKey::new("not-a-real-key"),
            base_url: "http://127.0.0.1:1".to_string(),
            max_calls: limit,
            // The rich ceiling is deliberately NOT `limit` here: several tests spend the
            // ordinary budget to the cap, and a rich ceiling that moved with it could not
            // then be shown to trip on its own.
            rich_max_calls: limit,
            window: Duration::from_secs(window_secs),
            ledger: Some(dir.join("calls.log")),
        }
    }

    /// A scratch directory that removes itself. `std::env::temp_dir` plus the test name keeps
    /// two tests in one binary off each other's ledger.
    struct Scratch(std::path::PathBuf);
    impl Scratch {
        fn new(tag: &str) -> Self {
            let p = std::env::temp_dir().join(format!("jesse-places-google-{tag}"));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).expect("scratch");
            Self(p)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    // ---- the key ------------------------------------------------------------------

    /// The key must not be printable. `PlacesConfig` derives `Debug` and tool failures are
    /// returned to a turn as text, so a key that can be `{:?}`-ed is a key that eventually
    /// lands in one.
    #[test]
    fn the_api_key_cannot_be_printed() {
        let key = ApiKey::new("SUPER-SECRET-VALUE");
        let debug = format!("{key:?}");
        assert!(
            !debug.contains("SUPER-SECRET-VALUE"),
            "the key leaked through Debug: {debug}"
        );
        let cfg = cfg_with(std::path::Path::new("/nowhere"), 1, 1);
        let via_config = format!("{cfg:?}");
        assert!(
            !via_config.contains("not-a-real-key"),
            "the key leaked through the config's Debug: {via_config}"
        );
        // And it is still readable where it has to be.
        assert_eq!(key.expose(), "SUPER-SECRET-VALUE");
    }

    /// The default `PlacesConfig` must never pick a key up from the ambient environment: a
    /// unit test that built one would then spend real money on a real API.
    #[test]
    fn the_default_config_configures_no_paid_provider() {
        assert!(PlacesConfig::default().google.is_none());
    }

    // ---- the place id, the only caller string that reaches this API ------------------

    #[test]
    fn place_ids_are_validated_before_they_reach_a_wire() {
        assert_eq!(
            validate_google_place_id("ChIJN1t_tDeuEmsRUsoyG83frY4"),
            Ok("ChIJN1t_tDeuEmsRUsoyG83frY4")
        );
        assert_eq!(
            validate_google_place_id("  abc-DEF_123  "),
            Ok("abc-DEF_123")
        );
        for hostile in [
            "",
            "../../secrets",
            "abc/def",
            "abc?fields=*",
            "abc#frag",
            "abc def",
            "abc%2Fdef",
            "ChIJ..;DROP",
            "\u{202e}abc",
        ] {
            assert!(
                validate_google_place_id(hostile).is_err(),
                "{hostile:?} must not reach a URL path"
            );
        }
        assert!(validate_google_place_id(&"a".repeat(256)).is_err());
        assert!(validate_google_place_id(&"a".repeat(255)).is_ok());
    }

    // ---- hours -----------------------------------------------------------------------

    fn period(od: u64, oh: u64, om: u64, cd: u64, ch: u64, cm: u64) -> Value {
        json!({
            "open": {"day": od, "hour": oh, "minute": om},
            "close": {"day": cd, "hour": ch, "minute": cm},
        })
    }

    #[test]
    fn a_weekday_period_lands_on_the_right_weekday() {
        // Google day 1 is Monday; this crate's index 0 is Monday.
        let h = hours_from_google(&[period(1, 9, 0, 1, 17, 0)]).unwrap();
        assert_eq!(
            h.days[0],
            vec![Interval {
                start: 9 * 60,
                end: 17 * 60
            }]
        );
        for d in 1..7 {
            assert!(h.days[d].is_empty(), "day {d} should be closed");
        }
        assert!(h.open_at(0, 10 * 60));
        assert!(!h.open_at(0, 18 * 60));
    }

    /// Google day 0 is SUNDAY and this crate's day 0 is MONDAY. An off-by-one here is the kind
    /// of defect that reports a shop as shut on the one day it is open.
    #[test]
    fn sunday_is_the_provider_zero_and_this_crate_six() {
        assert_eq!(google_day_index(0), 6, "provider Sunday is index 6 here");
        assert_eq!(google_day_index(1), 0, "provider Monday is index 0 here");
        assert_eq!(google_day_index(6), 5, "provider Saturday is index 5 here");
        let h = hours_from_google(&[period(0, 10, 0, 0, 16, 0)]).unwrap();
        assert_eq!(
            h.days[6],
            vec![Interval {
                start: 600,
                end: 960
            }],
            "a Sunday period must land on Sunday"
        );
    }

    /// A Friday-night close at 02:00 on Saturday is ONE interval on Friday that crosses
    /// midnight — the same way the OpenStreetMap parser says `Fr 20:00-02:00`. If the two
    /// disagreed here, `open_now` at 00:30 would depend on who answered.
    #[test]
    fn an_overnight_period_is_one_crossing_interval_not_two() {
        let h = hours_from_google(&[period(5, 20, 0, 6, 2, 0)]).unwrap();
        assert_eq!(
            h.days[4],
            vec![Interval {
                start: 20 * 60,
                end: 2 * 60
            }],
            "Friday 20:00 -> 02:00 belongs to Friday"
        );
        assert!(h.days[5].is_empty(), "and not also to Saturday");
        assert!(h.days[4][0].crosses_midnight());
        assert!(h.open_at(5, 30), "00:30 on Saturday is inside Friday night");
        assert!(!h.open_at(5, 10 * 60), "10:00 on Saturday is not");
    }

    /// The week-end wrap: provider Saturday (6) closing on provider Sunday (0) goes backwards
    /// in the provider's own numbering and must still come out as six hours, not six days.
    #[test]
    fn a_saturday_into_sunday_period_wraps_the_week_correctly() {
        let h = hours_from_google(&[period(6, 20, 0, 0, 2, 0)]).unwrap();
        assert_eq!(
            h.days[5],
            vec![Interval {
                start: 20 * 60,
                end: 2 * 60
            }]
        );
        assert!(h.open_at(6, 60), "01:00 on Sunday is inside Saturday night");
    }

    #[test]
    fn a_single_open_with_no_close_is_always_open() {
        let h = hours_from_google(&[json!({"open": {"day": 0, "hour": 0, "minute": 0}})]).unwrap();
        assert!(h.always_open);
        for d in 0..7 {
            assert_eq!(
                h.days[d],
                vec![Interval {
                    start: 0,
                    end: 1440
                }]
            );
        }
        assert!(h.open_at(3, 3 * 60));
    }

    /// Longer than a day cannot be said as one interval, so it is split at each midnight it
    /// crosses rather than silently truncated to 24 hours.
    #[test]
    fn a_period_longer_than_a_day_is_split_across_the_days_it_covers() {
        // Provider Friday 09:00 to provider Sunday 17:00.
        let h = hours_from_google(&[period(5, 9, 0, 0, 17, 0)]).unwrap();
        assert_eq!(
            h.days[4],
            vec![Interval {
                start: 9 * 60,
                end: 1440
            }],
            "Friday from 09:00 to midnight"
        );
        assert_eq!(
            h.days[5],
            vec![Interval {
                start: 0,
                end: 1440
            }],
            "Saturday all day"
        );
        assert_eq!(
            h.days[6],
            vec![Interval {
                start: 0,
                end: 17 * 60
            }],
            "Sunday until 17:00"
        );
        assert!(h.open_at(5, 12 * 60));
        assert!(!h.open_at(6, 18 * 60));
    }

    /// **The parser refuses rather than guessing**, on the same terms as the OpenStreetMap
    /// one: a confident wrong answer is worse than a stated failure.
    #[test]
    fn unreadable_periods_fail_rather_than_guess() {
        assert!(hours_from_google(&[]).is_err(), "no periods at all");
        assert!(
            hours_from_google(&[json!({"close": {"day": 1, "hour": 9, "minute": 0}})]).is_err(),
            "a close with no open"
        );
        assert!(
            hours_from_google(&[period(9, 9, 0, 1, 17, 0)]).is_err(),
            "a weekday out of range"
        );
        assert!(
            hours_from_google(&[period(1, 25, 0, 1, 17, 0)]).is_err(),
            "an hour out of range"
        );
        assert!(
            hours_from_google(&[
                json!({"open": {"day": 1, "hour": 0, "minute": 0}}),
                period(2, 9, 0, 2, 17, 0),
            ])
            .is_err(),
            "a never-closing period alongside others"
        );
    }

    /// The raw field is the provider's OWN lines, joined and nothing else. It is not rewritten
    /// into the other source's grammar — that would be this server inventing a source string.
    #[test]
    fn the_raw_hours_field_is_the_providers_own_text() {
        let hours = json!({
            "weekdayDescriptions": ["Monday: 9:00 AM – 5:00 PM", "Tuesday: Closed"],
            "periods": [],
        });
        assert_eq!(
            google_hours_raw(&hours),
            "Monday: 9:00 AM – 5:00 PM\nTuesday: Closed"
        );
        // No descriptions: the raw field is still present, carrying what did arrive.
        let bare = json!({"periods": [{"open": {"day": 1}}]});
        assert_eq!(google_hours_raw(&bare), bare.to_string());
    }

    // ---- the record ------------------------------------------------------------------

    fn a_place() -> Value {
        json!({
            "id": "ChIJexample",
            "displayName": {"text": "Loudon's", "languageCode": "en"},
            "formattedAddress": "94B Fountainbridge, Edinburgh EH3 9QA, UK",
            "location": {"latitude": 55.9436, "longitude": -3.2082},
            "primaryType": "cafe",
            "rating": 4.4,
            "userRatingCount": 2183,
            "nationalPhoneNumber": "0131 228 9111",
            "websiteUri": "https://example.invalid/",
            "regularOpeningHours": {
                "weekdayDescriptions": ["Monday: 8:00 AM – 5:00 PM"],
                "periods": [period(1, 8, 0, 1, 17, 0)],
            },
        })
    }

    #[test]
    fn a_record_names_its_own_source_and_prefixes_its_id() {
        let p = google_place_json(&a_place(), 11.0, &zone());
        assert_eq!(p["provider"], json!("google_places"));
        assert_eq!(
            p["id"],
            json!("google/ChIJexample"),
            "the id must route back to the source that can resolve it"
        );
        assert_eq!(p["name"], json!("Loudon's"));
        assert_eq!(p["distance_m"], json!(11));
        assert_eq!(p["address_source"], json!("provider"));
        assert_eq!(p["attribution"], json!(GOOGLE_ATTRIBUTION));
    }

    /// **A rating and its count travel together or not at all.** 5.0 from one person and 4.6
    /// from eleven thousand are not the same claim, and a caller shown only the number cannot
    /// tell them apart.
    #[test]
    fn a_rating_without_its_count_is_not_emitted() {
        let p = google_place_json(&a_place(), 1.0, &zone());
        assert_eq!(p["rating"], json!(4.4));
        assert_eq!(p["rating_count"], json!(2183));

        let mut half = a_place();
        half.as_object_mut().unwrap().remove("userRatingCount");
        let p = google_place_json(&half, 1.0, &zone());
        assert!(p.get("rating").is_none(), "a bare rating must not appear");
        assert!(p.get("rating_count").is_none());

        let mut other_half = a_place();
        other_half.as_object_mut().unwrap().remove("rating");
        let p = google_place_json(&other_half, 1.0, &zone());
        assert!(p.get("rating").is_none());
        assert!(p.get("rating_count").is_none(), "nor a bare count");
    }

    /// Absent fields are OMITTED, never emitted empty — the same rule the other source's
    /// builder states, because a null in `phone` reads as "this place has no phone".
    #[test]
    fn absent_fields_are_omitted_rather_than_nulled() {
        let bare = json!({
            "id": "ChIJbare",
            "displayName": {"text": "Bare"},
            "location": {"latitude": 1.0, "longitude": 2.0},
        });
        let p = google_place_json(&bare, f64::NAN, &zone());
        for absent in [
            "phone",
            "website",
            "address",
            "address_source",
            "category",
            "rating",
            "rating_count",
            "opening_hours",
            "opening_hours_raw",
            "distance_m",
        ] {
            assert!(p.get(absent).is_none(), "{absent} must be omitted");
        }
        // What must always be there: the id, the name, and the source that said it.
        assert_eq!(p["provider"], json!("google_places"));
        assert_eq!(p["id"], json!("google/ChIJbare"));
    }

    /// Both hours fields, or neither — the shape this server has kept since its first version.
    #[test]
    fn the_two_hours_fields_arrive_together() {
        let p = google_place_json(&a_place(), 1.0, &zone());
        assert_eq!(
            p["opening_hours_raw"],
            json!("Monday: 8:00 AM – 5:00 PM"),
            "the provider's own line, verbatim"
        );
        assert_eq!(p["opening_hours"]["parsed"], json!(true));
        assert_eq!(
            p["opening_hours"]["weekdays"]["monday"],
            json!([{"start": "08:00", "end": "17:00", "crosses_midnight": false}])
        );

        let mut none = a_place();
        none.as_object_mut().unwrap().remove("regularOpeningHours");
        let p = google_place_json(&none, 1.0, &zone());
        assert!(p.get("opening_hours").is_none());
        assert!(p.get("opening_hours_raw").is_none());
    }

    /// Unreadable hours produce `parsed: false` and `open_now: null`, WITH the raw value still
    /// in hand — never `open_now: false`, which is indistinguishable from "closed right now".
    #[test]
    fn unreadable_hours_leave_open_now_null_and_keep_the_raw_value() {
        let mut broken = a_place();
        broken["regularOpeningHours"]["periods"] = json!([{"open": {"day": 99}}]);
        let p = google_place_json(&broken, 1.0, &zone());
        assert_eq!(p["opening_hours"]["parsed"], json!(false));
        assert_eq!(p["opening_hours"]["open_now"], Value::Null);
        assert!(p["opening_hours"]["reason"].is_string());
        assert!(p.get("opening_hours_raw").is_some());
    }

    /// The two sources describe hours completely differently and must still render IDENTICALLY.
    #[test]
    fn both_sources_render_the_same_hours_into_the_same_shape() {
        let z = zone();
        let from_osm = crate::places::hours_json_from(
            parse_opening_hours("Mo-Fr 09:00-17:30; Sa 10:00-16:00"),
            &z,
        );
        let from_google = crate::places::hours_json_from(
            hours_from_google(&[
                period(1, 9, 0, 1, 17, 30),
                period(2, 9, 0, 2, 17, 30),
                period(3, 9, 0, 3, 17, 30),
                period(4, 9, 0, 4, 17, 30),
                period(5, 9, 0, 5, 17, 30),
                period(6, 10, 0, 6, 16, 0),
            ]),
            &z,
        );
        let keys = |v: &Value| {
            let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
            k.sort();
            k
        };
        assert_eq!(
            keys(&from_osm),
            keys(&from_google),
            "the two sources must emit the same field set"
        );
        assert_eq!(
            from_osm["weekdays"], from_google["weekdays"],
            "and the same per-weekday intervals for the same real-world hours"
        );
        assert_eq!(from_osm["open_now"], from_google["open_now"]);
        assert_eq!(from_osm["always_open"], from_google["always_open"]);

        // The failure shape has to match too, or a caller learns to branch on it.
        let osm_bad = crate::places::hours_json_from(parse_opening_hours("by appointment"), &z);
        let google_bad = crate::places::hours_json_from(hours_from_google(&[]), &z);
        assert_eq!(keys(&osm_bad), keys(&google_bad));
        assert_eq!(osm_bad["parsed"], json!(false));
        assert_eq!(google_bad["parsed"], json!(false));
        assert_eq!(osm_bad["open_now"], Value::Null);
        assert_eq!(google_bad["open_now"], Value::Null);
    }

    // ---- the budget --------------------------------------------------------------------

    #[tokio::test]
    async fn the_budget_allows_up_to_the_cap_and_then_refuses() {
        let sc = Scratch::new("budget-cap");
        let ledger = CallLedger::new(&cfg_with(&sc.0, 3, 3600));
        for expected in 1..=3 {
            let state = ledger
                .reserve("places_search", DetailLevel::Standard)
                .await
                .expect("under the cap");
            assert_eq!(state.used, expected);
            assert_eq!(state.limit, 3);
            assert_eq!(state.window_seconds, 3600);
        }
        let refused = ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .unwrap_err();
        assert!(
            refused.contains("3 of 3") && refused.contains("3600"),
            "the refusal must name the ceiling and the window: {refused}"
        );
        assert_eq!(ledger.peek().await.map(|s| s.used), Some(3));
    }

    /// The ledger is the audit log as well as the guard: one line per billed call, readable
    /// without a tool, and carrying NO response content.
    #[tokio::test]
    async fn every_reserved_call_writes_one_readable_line() {
        let sc = Scratch::new("budget-lines");
        let cfg = cfg_with(&sc.0, 10, 3600);
        let ledger = CallLedger::new(&cfg);
        ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .unwrap();
        ledger
            .reserve("place_details", DetailLevel::Standard)
            .await
            .unwrap();
        let text = std::fs::read_to_string(cfg.ledger.as_ref().unwrap()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2, "one line per billed call: {text:?}");
        assert!(lines[0].contains("places_search") && lines[0].contains("1/10"));
        assert!(lines[1].contains("place_details") && lines[1].contains("2/10"));
        for line in &lines {
            let stamp = line.split('\t').next().unwrap();
            DateTime::parse_from_rfc3339(stamp).expect("every line starts with a timestamp");
        }
    }

    /// The window ROLLS: a line older than it no longer counts, so the budget refills without
    /// anything having to reset it.
    #[tokio::test]
    async fn calls_outside_the_window_stop_counting() {
        let sc = Scratch::new("budget-window");
        let cfg = cfg_with(&sc.0, 2, 3600);
        let old = (Utc::now() - chrono::Duration::hours(4)).to_rfc3339();
        std::fs::write(
            cfg.ledger.as_ref().unwrap(),
            format!(
                "{old}\tplaces_search\tenterprise\t1/2\n{old}\tplaces_search\tenterprise\t2/2\n"
            ),
        )
        .unwrap();
        let ledger = CallLedger::new(&cfg);
        assert_eq!(ledger.peek().await.map(|s| s.used), Some(0));
        assert!(ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .is_ok());
    }

    /// **A ledger that cannot be read or written REFUSES the paid provider.** "We could not
    /// check the budget" must never read as "the budget is fine", because the thing that is
    /// unchecked here is money.
    #[tokio::test]
    async fn an_unusable_ledger_refuses_the_paid_provider_rather_than_spending_blind() {
        let sc = Scratch::new("budget-unusable");
        // A DIRECTORY where the ledger file should be: reading it is an error, and so is
        // writing it.
        let path = sc.0.join("calls.log");
        std::fs::create_dir_all(&path).unwrap();
        let mut cfg = cfg_with(&sc.0, 10, 3600);
        cfg.ledger = Some(path);
        let refused = CallLedger::new(&cfg)
            .reserve("places_search", DetailLevel::Standard)
            .await
            .unwrap_err();
        assert!(
            refused.contains("cannot be metered and is refused"),
            "an unusable ledger must fail closed: {refused}"
        );

        // And no resolvable path at all does the same.
        let mut none = cfg_with(&sc.0, 10, 3600);
        none.ledger = None;
        let refused = CallLedger::new(&none)
            .reserve("places_search", DetailLevel::Standard)
            .await
            .unwrap_err();
        assert!(
            refused.contains("cannot be metered and is refused"),
            "{refused}"
        );
    }

    /// A corrupt or truncated line counts AS SPENT rather than being skipped. Skipping it
    /// would let a damaged ledger read as "nothing has been spent", which is the one wrong
    /// answer here that costs money.
    #[tokio::test]
    async fn an_unparseable_ledger_line_counts_against_the_budget() {
        let sc = Scratch::new("budget-corrupt");
        let cfg = cfg_with(&sc.0, 2, 3600);
        std::fs::write(cfg.ledger.as_ref().unwrap(), "garbage\n\u{fffd}\u{fffd}\n").unwrap();
        let ledger = CallLedger::new(&cfg);
        assert_eq!(ledger.peek().await.map(|s| s.used), Some(2));
        assert!(ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .is_err());
    }

    // ---- failures -----------------------------------------------------------------------

    /// The provider's error BODY is never echoed. Its envelope repeats request parameters
    /// back, and a request carrying a key in the wrong place could see it quoted.
    #[test]
    fn a_failure_is_classified_without_echoing_the_body() {
        let body = r#"{"error":{"code":403,"status":"PERMISSION_DENIED",
            "message":"API key not valid. key=AIza-THE-ACTUAL-SECRET"}}"#;
        let said = describe_google_failure(403, body);
        assert!(!said.contains("AIza-THE-ACTUAL-SECRET"), "{said}");
        assert!(!said.contains("API key not valid"), "{said}");
        assert!(
            said.contains("PERMISSION_DENIED"),
            "the fixed code is useful: {said}"
        );
        assert!(said.contains("restricted away from this API"), "{said}");

        assert!(describe_google_failure(429, "{}").contains("quota"));
        assert!(describe_google_failure(503, "").contains("failed"));
        // A "status" that is not the fixed enum shape is dropped rather than passed through.
        let injected = describe_google_failure(400, r#"{"error":{"status":"look at ../../etc"}}"#);
        assert_eq!(injected, "HTTP 400: the preferred provider rejected the request as malformed; this is a defect in this server rather than something a caller can fix");
    }

    // ---- the field masks ------------------------------------------------------------------

    /// **The mask is the price.** These two constants are what stop a cheap lookup being
    /// billed at the most expensive tier, so the expensive field families are asserted absent
    /// rather than merely left out.
    #[test]
    fn the_field_masks_ask_for_the_contract_and_nothing_dearer() {
        for mask in [GOOGLE_SEARCH_FIELD_MASK, GOOGLE_DETAILS_FIELD_MASK] {
            assert!(
                !mask.contains(' '),
                "a mask with a space in it is rejected: {mask:?}"
            );
            for dear in [
                "reviews",
                "photos",
                "editorialSummary",
                "generativeSummary",
                "accessibilityOptions",
                "priceRange",
                "servesBeer",
                "currentOpeningHours",
            ] {
                assert!(
                    !mask.contains(dear),
                    "{dear} is a dearer tier than this contract needs: {mask}"
                );
            }
            for needed in [
                "rating",
                "userRatingCount",
                "regularOpeningHours",
                "attributions",
            ] {
                assert!(
                    mask.contains(needed),
                    "{needed} is part of the contract: {mask}"
                );
            }
        }
        // Search masks are `places.`-prefixed and Details masks are not; swapping them is a
        // 400 from the provider rather than a compile error, so it is asserted here.
        assert!(GOOGLE_SEARCH_FIELD_MASK.starts_with("places."));
        assert!(!GOOGLE_DETAILS_FIELD_MASK.contains("places."));
    }

    /// **ALL FOUR MASKS ARE PINNED TO THEIR LITERAL BYTES, and that is the whole point of
    /// this test.** A mask is a price: adding one field to one of these strings can move a
    /// call from Enterprise to Enterprise + Atmosphere, or add prose to every response
    /// forever. Asserting the field families are absent (the test above) catches the four
    /// families somebody thought to name; asserting the exact string catches EVERY addition,
    /// including the one nobody thought of.
    ///
    /// So an edit that adds a field has to come here and change a test whose failure message
    /// says what that field costs. That is the intended cost of adding one, not an obstacle
    /// to be routed around by relaxing the comparison.
    #[test]
    fn the_four_masks_are_pinned_byte_for_byte_because_each_one_is_a_price() {
        // THE TWO DEFAULT MASKS, UNCHANGED SINCE 0.104.0. If either of these two assertions
        // fails, the DEFAULT cost of this tool has moved — every call, not just the ones that
        // asked for more. That is a different and much larger decision than adding a field to
        // the opt-in masks below, and it needs its own justification in the pull request.
        assert_eq!(
            GOOGLE_SEARCH_FIELD_MASK,
            "places.id,places.displayName,places.formattedAddress,places.location,\
             places.primaryType,places.rating,places.userRatingCount,\
             places.regularOpeningHours,places.nationalPhoneNumber,places.websiteUri,\
             places.attributions",
            "the DEFAULT search mask moved: every ordinary call's price and payload just \
             changed. Enterprise is the floor this contract needs (rating, userRatingCount, \
             regularOpeningHours); anything added here is paid for on every call forever"
        );
        assert_eq!(
            GOOGLE_DETAILS_FIELD_MASK,
            "id,displayName,formattedAddress,location,primaryType,rating,userRatingCount,\
             regularOpeningHours,nationalPhoneNumber,websiteUri,attributions",
            "the DEFAULT details mask moved: see the message above, and note that this one \
             is unprefixed because Place Details rejects a `places.`-prefixed mask"
        );

        // THE TWO OPT-IN MASKS: the defaults plus exactly two fields.
        assert_eq!(
            GOOGLE_SEARCH_FIELD_MASK_RICH,
            format!("{GOOGLE_SEARCH_FIELD_MASK},places.reviews,places.editorialSummary"),
            "the rich search mask is the standard one plus `reviews` and `editorialSummary` \
             and nothing else. Both are Enterprise + Atmosphere, which is what makes this \
             call materially dearer than a standard one; `photos` and the service/amenity \
             block are the same tier and are excluded for want of a caller need, not for \
             want of money"
        );
        assert_eq!(
            GOOGLE_DETAILS_FIELD_MASK_RICH,
            format!("{GOOGLE_DETAILS_FIELD_MASK},reviews,editorialSummary"),
            "the rich details mask is the standard one plus the same two fields"
        );

        // The prefix rule holds on the rich masks too — a prefixed details mask is a 400 from
        // the provider rather than a compile error.
        assert!(GOOGLE_SEARCH_FIELD_MASK_RICH.starts_with("places."));
        assert!(!GOOGLE_DETAILS_FIELD_MASK_RICH.contains("places."));
        for mask in [
            GOOGLE_SEARCH_FIELD_MASK_RICH,
            GOOGLE_DETAILS_FIELD_MASK_RICH,
        ] {
            assert!(!mask.contains(' '), "a mask with a space in it is rejected");
            // The Atmosphere fields NOT bought, each of which would be free of extra money
            // given `reviews` and would still cost context on every rich response.
            for unwanted in [
                "photos",
                "generativeSummary",
                "reviewSummary",
                "accessibilityOptions",
                "paymentOptions",
                "parkingOptions",
                "priceRange",
                "servesBeer",
                "outdoorSeating",
                "goodForChildren",
                "currentOpeningHours",
            ] {
                assert!(
                    !mask.contains(unwanted),
                    "{unwanted} is not in this contract: {mask}"
                );
            }
        }

        // And the selector cannot disagree with the constants.
        assert_eq!(
            google_search_field_mask(DetailLevel::Standard),
            GOOGLE_SEARCH_FIELD_MASK
        );
        assert_eq!(
            google_search_field_mask(DetailLevel::Rich),
            GOOGLE_SEARCH_FIELD_MASK_RICH
        );
        assert_eq!(
            google_details_field_mask(DetailLevel::Standard),
            GOOGLE_DETAILS_FIELD_MASK
        );
        assert_eq!(
            google_details_field_mask(DetailLevel::Rich),
            GOOGLE_DETAILS_FIELD_MASK_RICH
        );
    }

    // ---- the second ceiling ---------------------------------------------------------------

    /// **The rich ceiling trips on its own, long before the ordinary one.** That is the
    /// property that makes an accidental loop of dear calls visible the same hour: here the
    /// ordinary budget still has 17 of 20 calls left when the rich one is spent.
    #[tokio::test]
    async fn the_rich_ceiling_trips_independently_of_the_ordinary_one() {
        let sc = Scratch::new("rich-cap");
        let mut cfg = cfg_with(&sc.0, 20, 3600);
        cfg.rich_max_calls = 3;
        let ledger = CallLedger::new(&cfg);

        for expected in 1..=3 {
            let state = ledger
                .reserve("places_search", DetailLevel::Rich)
                .await
                .expect("under the rich cap");
            assert_eq!(state.rich_used, expected);
            assert_eq!(state.used, expected, "a rich call is still a call");
            assert_eq!(state.rich_limit, 3);
            assert_eq!(state.limit, 20);
        }

        let refused = ledger
            .reserve("places_search", DetailLevel::Rich)
            .await
            .unwrap_err();
        assert!(
            refused.contains("3 of 3"),
            "the refusal names the ceiling it hit: {refused}"
        );
        assert!(
            refused.contains("richer field set"),
            "and says WHICH ceiling: {refused}"
        );
        assert!(
            refused.contains("3 of 20"),
            "and that the ordinary budget is untouched: {refused}"
        );
        assert!(
            refused.contains("JESSE_PLACES_GOOGLE_MAX_RICH_CALLS"),
            "and how to raise it: {refused}"
        );

        // AND THE CHEAP ANSWER IS STILL AVAILABLE. A spent rich budget must not take the tool
        // out; it takes the expensive half of it out.
        let after = ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .expect("a standard call is unaffected by a spent rich budget");
        assert_eq!(after.used, 4);
        assert_eq!(after.rich_used, 3, "and did not add to the rich count");
    }

    /// The two ceilings are an AND: a spent ORDINARY budget stops a rich call too, because a
    /// rich call is still a call.
    #[tokio::test]
    async fn a_spent_ordinary_budget_also_stops_a_rich_call() {
        let sc = Scratch::new("rich-under-ordinary");
        let mut cfg = cfg_with(&sc.0, 2, 3600);
        cfg.rich_max_calls = 50;
        let ledger = CallLedger::new(&cfg);
        for _ in 0..2 {
            ledger
                .reserve("places_search", DetailLevel::Standard)
                .await
                .unwrap();
        }
        let refused = ledger
            .reserve("places_search", DetailLevel::Rich)
            .await
            .unwrap_err();
        assert!(
            refused.contains("2 of 2") && !refused.contains("richer field set"),
            "the ordinary ceiling is what refused it: {refused}"
        );
    }

    /// **The ledger tells the two kinds of call apart, and a standard line is byte-identical
    /// to the one 0.104.0 wrote.** The tier column is what `read_window` reads back, so this
    /// is the format the second ceiling actually depends on rather than a cosmetic log line.
    #[tokio::test]
    async fn the_ledger_records_the_tier_and_leaves_a_standard_line_unchanged() {
        let sc = Scratch::new("rich-lines");
        let mut cfg = cfg_with(&sc.0, 10, 3600);
        cfg.rich_max_calls = 4;
        let ledger = CallLedger::new(&cfg);
        ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .unwrap();
        ledger
            .reserve("place_details", DetailLevel::Rich)
            .await
            .unwrap();

        let text = std::fs::read_to_string(cfg.ledger.as_ref().unwrap()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2, "{text}");

        // The standard line: four columns, tier `enterprise`, exactly as before.
        let std_cols: Vec<&str> = lines[0].split('\t').collect();
        assert_eq!(std_cols.len(), 4, "{:?}", lines[0]);
        assert_eq!(std_cols[1], "places_search");
        assert_eq!(std_cols[2], "enterprise");
        assert_eq!(std_cols[3], "1/10");

        // The rich line: the dearer tier, and a fifth column naming the second count so a
        // person reading the file can see what tripped without tallying it.
        let rich_cols: Vec<&str> = lines[1].split('\t').collect();
        assert_eq!(rich_cols.len(), 5, "{:?}", lines[1]);
        assert_eq!(rich_cols[1], "place_details");
        assert_eq!(rich_cols[2], "enterprise_atmosphere");
        assert_eq!(rich_cols[3], "2/10", "a rich call counts against BOTH");
        assert_eq!(rich_cols[4], "rich=1/4");

        assert_eq!(
            ledger.peek().await.map(|s| (s.used, s.rich_used)),
            Some((2, 1))
        );
    }

    /// A ledger written by 0.104.0 reads back correctly: those lines are `enterprise`, so
    /// none of them counts against the rich ceiling. An upgrade must not arrive with the
    /// rich budget already spent.
    #[tokio::test]
    async fn lines_written_before_this_change_do_not_count_as_rich() {
        let sc = Scratch::new("rich-legacy");
        let mut cfg = cfg_with(&sc.0, 200, 3600);
        cfg.rich_max_calls = 2;
        let now = Utc::now().to_rfc3339();
        std::fs::write(
            cfg.ledger.as_ref().unwrap(),
            format!(
                "{now}\tplaces_search\tenterprise\t1/200\n\
                 {now}\tplaces_search\tenterprise\t2/200\n\
                 {now}\tplace_details\tenterprise\t3/200\n"
            ),
        )
        .unwrap();
        let ledger = CallLedger::new(&cfg);
        assert_eq!(
            ledger.peek().await.map(|s| (s.used, s.rich_used)),
            Some((3, 0)),
            "three ordinary calls, none of them rich"
        );
        assert!(ledger
            .reserve("places_search", DetailLevel::Rich)
            .await
            .is_ok());
    }

    /// A line whose TIER column is missing or unreadable counts against the rich ceiling as
    /// well as the ordinary one — the same fail-closed rule the timestamp column already has,
    /// one column over. A damaged ledger reading as "none of this was the expensive kind" is
    /// the wrong answer that costs the most money.
    #[tokio::test]
    async fn an_unreadable_tier_column_counts_against_the_rich_ceiling() {
        let sc = Scratch::new("rich-corrupt");
        let mut cfg = cfg_with(&sc.0, 200, 3600);
        cfg.rich_max_calls = 2;
        std::fs::write(cfg.ledger.as_ref().unwrap(), "garbage\ngarbage\n").unwrap();
        let ledger = CallLedger::new(&cfg);
        assert_eq!(
            ledger.peek().await.map(|s| (s.used, s.rich_used)),
            Some((2, 2))
        );
        assert!(
            ledger
                .reserve("places_search", DetailLevel::Rich)
                .await
                .is_err(),
            "a damaged ledger must not read as 'no dear calls have been made'"
        );
        // The ordinary budget still has room, so the cheap answer still works.
        assert!(ledger
            .reserve("places_search", DetailLevel::Standard)
            .await
            .is_ok());
    }

    /// The `budget` object a response carries keeps EXACTLY the three keys and values it
    /// carried in 0.104.0; the rich counters are a sibling object. A caller or a test reading
    /// `budget` must see no change from a change that was supposed to leave the default alone.
    #[test]
    fn the_ordinary_budget_object_is_unchanged_and_the_rich_one_is_a_sibling() {
        let b = BudgetState {
            used: 4,
            limit: 200,
            window_seconds: 86_400,
            rich_used: 1,
            rich_limit: 20,
        };
        assert_eq!(
            b.as_json(),
            json!({"used": 4, "limit": 200, "window_seconds": 86400}),
            "no key was added to the object 0.104.0 emitted"
        );
        assert_eq!(
            b.rich_as_json(),
            json!({"used": 1, "limit": 20, "window_seconds": 86400})
        );
    }

    // ---- reviews ---------------------------------------------------------------------------

    /// A review as the provider actually sends one, taken from a live response.
    fn a_review() -> Value {
        json!({
            "name": "places/ChIJexample/reviews/Ci9DQUlR",
            "relativePublishTimeDescription": "a month ago",
            "rating": 5,
            "text": {"text": "Treated us very well.", "languageCode": "en"},
            "originalText": {"text": "Treated us very well.", "languageCode": "en"},
            "authorAttribution": {
                "displayName": "A Reviewer",
                "uri": "https://www.google.com/maps/contrib/1/reviews",
                "photoUri": "https://lh3.googleusercontent.com/a/x=s128",
            },
            "publishTime": "2026-07-04T13:57:43.708815105Z",
            "flagContentUri": "https://www.google.com/local/content/rap/report?postId=x",
            "googleMapsUri": "https://www.google.com/maps/reviews/data=!4m6",
        })
    }

    fn a_rich_place() -> Value {
        let mut p = a_place();
        p["editorialSummary"] =
            json!({"text": "A long-established kiltmaker.", "languageCode": "en"});
        p["reviews"] = json!([a_review()]);
        p
    }

    /// **Every returned review carries the two things the provider's policy REQUIRES to
    /// display it**: its author, and a link to the review on Google Maps. Those are
    /// obligations rather than fields, which is why they are met here rather than left to a
    /// caller that will summarise whatever it is handed.
    #[test]
    fn a_review_carries_its_author_and_its_source_link() {
        let p = google_place_json(&a_rich_place(), 1.0, &zone());
        let r = &p["reviews"][0];
        assert_eq!(r["author"]["name"], json!("A Reviewer"));
        assert_eq!(
            r["author"]["profile_url"],
            json!("https://www.google.com/maps/contrib/1/reviews")
        );
        assert_eq!(
            r["author"]["avatar_url"],
            json!("https://lh3.googleusercontent.com/a/x=s128")
        );
        assert_eq!(
            r["source_url"],
            json!("https://www.google.com/maps/reviews/data=!4m6"),
            "end users must be able to reach the review on Google Maps"
        );
        assert_eq!(r["rating"], json!(5.0));
        assert_eq!(r["text"], json!("Treated us very well."));
        assert_eq!(r["published"], json!("a month ago"));
        assert_eq!(r["published_at"], json!("2026-07-04T13:57:43.708815105Z"));
        assert!(r["report_url"].is_string(), "the flag link is carried too");
        // Not translated, so no `original_text` and no `translated` flag — the two fields
        // were identical.
        assert!(r.get("original_text").is_none());
        assert!(r.get("translated").is_none());

        // The ordering notice travels with the array, because the policy requires one and it
        // is only true while nothing here reorders or filters.
        assert_eq!(p["reviews_notice"], json!(REVIEWS_NOTICE));
        assert!(p.get("reviews_withheld").is_none());
        assert_eq!(
            p["editorial_summary"],
            json!("A long-established kiltmaker.")
        );
    }

    /// **A review that cannot be displayed within the terms is not returned, and the count of
    /// those is reported rather than silently absorbed.** Author attribution and a source link
    /// are requirements; handing over a review missing either would put an obligation
    /// somewhere it cannot be met.
    #[test]
    fn a_review_that_cannot_be_credited_is_withheld_and_counted() {
        let mut place = a_rich_place();
        let no_author = {
            let mut r = a_review();
            r.as_object_mut().unwrap().remove("authorAttribution");
            r
        };
        let no_link = {
            let mut r = a_review();
            r.as_object_mut().unwrap().remove("googleMapsUri");
            r
        };
        place["reviews"] = json!([a_review(), no_author, no_link]);

        let p = google_place_json(&place, 1.0, &zone());
        assert_eq!(
            p["reviews"].as_array().map(Vec::len),
            Some(1),
            "only the showable one survives"
        );
        assert_eq!(
            p["reviews_withheld"],
            json!(2),
            "and the caller is told how many did not — 'one review' and 'one of three \
             reviews' are different claims"
        );

        // All of them unshowable: no array at all, and no notice about an array that is not
        // there — but still the count.
        place["reviews"] = json!([no_author]);
        let p = google_place_json(&place, 1.0, &zone());
        assert!(p.get("reviews").is_none());
        assert!(p.get("reviews_notice").is_none());
        assert_eq!(p["reviews_withheld"], json!(1));
    }

    /// The array keeps the order it arrived in and nothing is edited — which is the only
    /// thing that makes [`REVIEWS_NOTICE`] a true statement rather than a formality.
    #[test]
    fn reviews_keep_the_order_and_the_text_they_arrived_with() {
        let mut place = a_rich_place();
        let mut second = a_review();
        second["text"]["text"] = json!("Second in, second out.");
        second["rating"] = json!(3);
        let mut third = a_review();
        third["text"]["text"] = json!("Third.");
        third["rating"] = json!(1);
        place["reviews"] = json!([a_review(), second, third]);

        let p = google_place_json(&place, 1.0, &zone());
        let texts: Vec<&str> = p["reviews"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["text"].as_str().unwrap())
            .collect();
        assert_eq!(
            texts,
            vec!["Treated us very well.", "Second in, second out.", "Third."],
            "no reordering, no ranking by rating, no truncation"
        );
        assert!(
            REVIEWS_NOTICE.contains("order the source returned them"),
            "and the notice says so: {REVIEWS_NOTICE}"
        );
    }

    /// A translated review carries the original alongside, so a caller can say it was
    /// translated instead of presenting Google's rendering as the author's own words.
    #[test]
    fn a_translated_review_carries_the_original_text_too() {
        let mut place = a_rich_place();
        let mut r = a_review();
        r["text"] = json!({"text": "Excellent service.", "languageCode": "en"});
        r["originalText"] = json!({"text": "Servizio eccellente.", "languageCode": "it"});
        place["reviews"] = json!([r]);
        let p = google_place_json(&place, 1.0, &zone());
        assert_eq!(p["reviews"][0]["text"], json!("Excellent service."));
        assert_eq!(
            p["reviews"][0]["original_text"],
            json!("Servizio eccellente.")
        );
        assert_eq!(p["reviews"][0]["translated"], json!(true));
    }

    /// `visitDate` is required alongside the content for places in France, and is sent only
    /// there — so it is passed through verbatim wherever it appears.
    #[test]
    fn a_visit_date_is_passed_through_when_the_provider_sends_one() {
        let mut place = a_rich_place();
        let mut r = a_review();
        r["visitDate"] = json!({"year": 2026, "month": 6});
        place["reviews"] = json!([r]);
        let p = google_place_json(&place, 1.0, &zone());
        assert_eq!(
            p["reviews"][0]["visit_date"],
            json!({"year": 2026, "month": 6})
        );
    }

    /// **A standard response carries no review keys at all** — not an empty array, not a
    /// null. The mask did not ask for them, so the record must not imply the place has none.
    #[test]
    fn a_standard_record_carries_no_review_keys_whatsoever() {
        let p = google_place_json(&a_place(), 1.0, &zone());
        for absent in [
            "reviews",
            "reviews_notice",
            "reviews_withheld",
            "editorial_summary",
        ] {
            assert!(p.get(absent).is_none(), "{absent} must be omitted");
        }
        // And the fields the standard contract does carry are untouched by any of this.
        assert_eq!(p["rating"], json!(4.4));
        assert_eq!(p["rating_count"], json!(2183));
        assert_eq!(p["provider"], json!("google_places"));
    }

    /// A place with the rich mask but genuinely no reviews emits no `reviews` key either —
    /// which is why `detail` is reported on the envelope. The record alone cannot say "I
    /// asked and there are none"; the envelope can.
    #[test]
    fn a_rich_record_for_a_place_with_no_reviews_emits_no_empty_array() {
        let mut place = a_rich_place();
        place["reviews"] = json!([]);
        place.as_object_mut().unwrap().remove("editorialSummary");
        let p = google_place_json(&place, 1.0, &zone());
        assert!(p.get("reviews").is_none(), "never an empty array");
        assert!(p.get("reviews_withheld").is_none());
        assert!(p.get("editorial_summary").is_none());
    }
}
